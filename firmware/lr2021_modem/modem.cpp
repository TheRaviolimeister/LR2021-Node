#include "modem.h"
#include "fe_calc.h"
#include <Preferences.h>
#include <stdarg.h>

Modem modem;

static SPIClass lrSpi(FSPI);
static LR2021 radio = new Module(PIN_LR_CS, PIN_LR_IRQ, PIN_LR_RST, PIN_LR_BUSY, lrSpi,
                                 SPISettings(LR_SPI_HZ, MSBFIRST, SPI_MODE0));
static volatile bool g_irq = false;

static void IRAM_ATTR onRadioIrq() { g_irq = true; }
static uint32_t g_cadTimeoutMs = CAD_TIMEOUT_MS;   // wird je nach LoRa-Einstellung verlängert
static uint32_t g_cadMinMs = 2;                     // frühestens dann per SPI nach "CAD fertig" fragen
static volatile bool g_txIgnorePin = false;         // IRQ-Pegel beim aktuellen Senden nicht mehr auswerten
static uint16_t g_txSpurious = 0;                   // Fehl-IRQs (ohne TX_DONE) beim aktuellen Senden
static const char* g_irqSrc = "ISR";                // woher das letzte Ereignis kam (für Meldungen)
// IRQ-Behandlung: Auf der IRQ-Leitung (DIO11 -> GPIO4/10) können während des Sendens kurze Störimpulse
// auftreten, bei denen im Chip kein Ereignis gesetzt ist. Deshalb zählt beim Senden nur ein echtes
// TX_DONE/TIMEOUT aus den IRQ-Flags des Chips; das Lesen der Flags per SPI stört das Senden nicht.
// Im Empfang wird der Status zusätzlich alle 50 ms per SPI abgefragt, damit kein Paket verloren geht.

// ---------------------------------------------------------------------------
// 868-MHz-Frontend (SE2435L): PA, LNA mit Bypass, Sende-/Empfangsumschalter.
// Betriebsarten (Datenblatt): Schlaf CSD=0 | Empfang/Senden über Bypass CSD=1 CPS=0 CTX=0 |
// Empfang mit LNA CSD=1 CPS=1 CTX=0 | Senden über PA CSD=1 CTX=1.
static bool g_fe = false;            // Frontend erkannt
static bool g_fePa = false;          // aktuelle Sendeleistung braucht den PA
static bool g_feLna = true;          // LNA im Empfang an
static uint8_t g_feMode = 0;         // 0 automatisch, 1 LNA an, 2 LNA aus
static int8_t g_feDrive = 0, g_feOut = 0, g_feLegal = 0;
static int16_t g_feNoiseOn10 = 0, g_feNoiseOff10 = 0;
static uint32_t g_feNextEval = 0;

// Kalibrierung des Frontends in 0,1 dB (Startwerte aus config.h, gemessene Werte im Flash, Schlüssel "fecal")
static const FeCalValues FE_CAL_DEFAULT = { FE_PA_GAIN_DB * 10, FE_FILTER_LOSS_DB * 10, FE_LNA_GAIN_DB * 10,
                                            FE_BYPASS_LOSS_DB * 10 };
static FeCalValues g_cal = FE_CAL_DEFAULT;
static bool g_calStored = false;      // Werte stammen aus dem Flash
static const uint16_t FE_CAL_MAGIC = 0x4346;   // "FC"
#pragma pack(push, 1)
struct FeCalPersist { uint16_t magic; FeCalValues v; };
#pragma pack(pop)

static bool calValid(const FeCalValues& c) {
  return c.pa10 >= FE_CAL_PA_MIN10 && c.pa10 <= FE_CAL_PA_MAX10 &&
         c.filt10 >= FE_CAL_FILT_MIN10 && c.filt10 <= FE_CAL_FILT_MAX10 &&
         c.lna10 >= FE_CAL_LNA_MIN10 && c.lna10 <= FE_CAL_LNA_MAX10 &&
         c.byp10 >= FE_CAL_BYP_MIN10 && c.byp10 <= FE_CAL_BYP_MAX10;
}
static bool calIsDefault(const FeCalValues& c) {
  return c.pa10 == FE_CAL_DEFAULT.pa10 && c.filt10 == FE_CAL_DEFAULT.filt10 &&
         c.lna10 == FE_CAL_DEFAULT.lna10 && c.byp10 == FE_CAL_DEFAULT.byp10;
}
static void fePins(uint8_t csd, uint8_t cps, uint8_t ctx) {
#if PIN_FE_CSD >= 0
  digitalWrite(PIN_FE_CTX, ctx);
  digitalWrite(PIN_FE_CPS, cps);
  digitalWrite(PIN_FE_CSD, csd);
#endif
}
static void feRx()    { if (g_fe) fePins(1, g_feLna ? 1 : 0, 0); }
static void feTx()    { if (g_fe) fePins(1, 0, g_fePa ? 1 : 0); }
static void feSleep() { if (g_fe) fePins(0, 0, 0); }

static bool feDetect() {
#if PIN_FE_CSD >= 0
  pinMode(PIN_FE_CSD, INPUT_PULLUP);
  delay(2);
  bool low = digitalRead(PIN_FE_CSD) == LOW;      // 10k nach GND auf der Trägerplatine
  if (!low) { pinMode(PIN_FE_CSD, INPUT); return false; }
  digitalWrite(PIN_FE_CSD, LOW);
  pinMode(PIN_FE_CSD, OUTPUT);
  pinMode(PIN_FE_CPS, OUTPUT);
  pinMode(PIN_FE_CTX, OUTPUT);
  fePins(0, 0, 0);
  return true;
#else
  return false;
#endif
}

// Gesetzliche Grenze an der Buchse (EU SRD, ERC/REC 70-03; ERP mit 0-dBd-Antenne = 2,15 dBi)
// Die App programmiert die Frequenz mit der Korrektur des Quarzfehlers des Moduls (gemessen, typ. +30 kHz);
// die tatsächlich gesendete Frequenz liegt um diesen Betrag tiefer. Deshalb gilt eine Toleranz von
// FE_FREQ_TOL_HZ (40 kHz = 46 ppm) an den Bandgrenzen.
static int8_t legalMaxDbm(uint32_t f, uint32_t bw) {
  uint32_t lo = f - bw / 2 + FE_FREQ_TOL_HZ, hi = f + bw / 2 - FE_FREQ_TOL_HZ;
  if (lo >= 869400000UL && hi <= 869650000UL) return 27;   // 500 mW ERP
  return 14;                                               // übrige 863–870 MHz: 25 mW ERP
}

// Empfangsverstärkung vor dem LR2021 (für RSSI an der Antenne)
static float feRxGainDb() {
  if (!g_fe) return 0.0f;
  return ((g_feLna ? g_cal.lna10 : -g_cal.byp10) - g_cal.filt10) / 10.0f;
}

// höchste einstellbare Sub-GHz-Leistung: mit Frontend an der Buchse, sonst am LR2021
static int8_t subGhzMax() { return g_fe ? FE_OUT_MAX_DBM : RADIOLIB_LR2021_LF_POUT_MAX; }

static const uint32_t PERSIST_MAGIC = 0x4C524D31;   // "LRM1"
#pragma pack(push, 1)
struct Persist {
  uint32_t magic;
  uint8_t  modem;
  LoraCfg  lora;
  FskCfg   fsk;
  Limits   lim;
  uint8_t  autorx;
};
#pragma pack(pop)

// ---------------------------------------------------------------------------
void Modem::log(uint8_t level, const char* fmt, ...) {
  char buf[160];
  buf[0] = level;
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf + 1, sizeof(buf) - 1, fmt, ap);
  va_end(ap);
  if (n < 0) return;
  if (n > (int)sizeof(buf) - 2) n = sizeof(buf) - 2;
  if (sink_) sink_(EVT_LOG, (const uint8_t*)buf, (uint16_t)(n + 1));
}

void Modem::led(uint8_t r, uint8_t g, uint8_t b) {
#if PIN_RGB_LED >= 0
  rgbLedWrite(PIN_RGB_LED, r, g, b);
#endif
}

// ---------------------------------------------------------------------------
void Modem::loadDefaults() {
  modem_ = MODEM_LORA;
  lora_.freq_hz = DEF_FREQ_HZ;
  lora_.bw_hz = DEF_BW_HZ;
  lora_.sf = DEF_SF;
  lora_.cr = DEF_CR;
  lora_.sync = DEF_SYNC;
  lora_.power_dbm = DEF_POWER_DBM;
  lora_.preamble = DEF_PREAMBLE;
  lora_.flags = 0x01;              // CRC an
  lora_.implicit_len = 0;

  fsk_.freq_hz = DEF_FREQ_HZ;
  fsk_.bitrate_bps = 50000;
  fsk_.fdev_hz = 25000;
  fsk_.rxbw_hz = 136400;
  fsk_.power_dbm = DEF_POWER_DBM;
  fsk_.preamble_bits = 32;
  fsk_.sync_len = 2;
  fsk_.sync[0] = 0x12; fsk_.sync[1] = 0xAD;
  fsk_.crc_len = 2;
  fsk_.flags = 0x01;               // Whitening an, variable Länge
  fsk_.shaping = 2;                // BT 0.5
  fsk_.fixed_len = 0;

  lim_.allow_mask = (DEF_ALLOW_SUBGHZ_TX ? 1 : 0) | (DEF_ALLOW_24_TX ? 2 : 0);
  lim_.max_pwr_subghz = g_fe ? FE_OUT_MAX_DBM : DEF_MAX_PWR_SUBGHZ;
  lim_.max_pwr_24 = DEF_MAX_PWR_24;
  lim_.duty_permille = DEF_DUTY_PERMILLE;
  autoRx_ = false;
}

void Modem::load() {
  loadDefaults();
  Preferences p;
  if (!p.begin("lrmodem", true)) return;
  Persist d;
  size_t n = p.getBytes("cfg", &d, sizeof(d));
  p.end();
  if (n != sizeof(d) || d.magic != PERSIST_MAGIC) return;
  if (d.modem != MODEM_LORA && d.modem != MODEM_FSK) return;
  modem_ = d.modem;
  lora_ = d.lora;
  fsk_ = d.fsk;
  lim_ = d.lim;
  autoRx_ = d.autorx != 0;
}

void Modem::save() {
  Persist d;
  d.magic = PERSIST_MAGIC;
  d.modem = modem_;
  d.lora = lora_;
  d.fsk = fsk_;
  d.lim = lim_;
  d.autorx = autoRx_ ? 1 : 0;
  Preferences p;
  if (p.begin("lrmodem", false)) {
    p.putBytes("cfg", &d, sizeof(d));
    p.end();
  }
}

void Modem::factoryReset() {
  Preferences p;
  if (p.begin("lrmodem", false)) {
    p.clear();
    p.end();
  }
}

// ---------------------------------------------------------------------------
void Modem::begin(EventSink sink) {
  sink_ = sink;
#if PIN_RGB_LED >= 0
  led(0, 0, LED_BRIGHTNESS);
#endif
  pinMode(PIN_LR_IRQ, INPUT);
  g_fe = feDetect();
  lrSpi.begin(PIN_LR_SCK, PIN_LR_MISO, PIN_LR_MOSI, -1);
  radio.tcxoVoltage = RadioLibTCXOVoltage_t::VoltageNone;   // Core2021 hat einen Quarz, keinen TCXO
  radio.irqDioNum = 11;                                     // DIO11 ist verdrahtet
  load();
  if (g_fe) {
    // gespeicherte Grenze aus der Zeit ohne Frontend (Chip-Maximum) auf das Frontend-Maximum heben
    if (lim_.max_pwr_subghz == DEF_MAX_PWR_SUBGHZ) lim_.max_pwr_subghz = FE_OUT_MAX_DBM;
    Preferences p;
    FeCalPersist cp;
    size_t cn = 0;
    if (p.begin("lrmodem", true)) {
      g_feMode = p.getUChar("fe", 0);
      if (p.isKey("fecal")) cn = p.getBytes("fecal", &cp, sizeof(cp));
      p.end();
    }
    if (g_feMode > 2) g_feMode = 0;
    g_feLna = (g_feMode != 2);
    g_cal = FE_CAL_DEFAULT;
    g_calStored = false;
    if (cn == sizeof(cp) && cp.magic == FE_CAL_MAGIC && calValid(cp.v)) { g_cal = cp.v; g_calStored = true; }
    g_feNextEval = millis() + 20000;
    feRx();
    log(0, "868-MHz-Frontend erkannt (PA bis %d dBm, LNA %s, Kalibrierung %s: PA %.1f, Filter %.1f, LNA %.1f, Bypass %.1f dB)",
        FE_OUT_MAX_DBM, g_feMode == 0 ? "automatisch" : g_feMode == 1 ? "an" : "aus",
        g_calStored ? "gespeichert" : "Werkswerte", g_cal.pa10 / 10.0, g_cal.filt10 / 10.0, g_cal.lna10 / 10.0,
        g_cal.byp10 / 10.0);
  }
  rxWanted_ = autoRx_;
  int16_t code = 0;
  int16_t st = applyConfig(&code);
  if (st != ST_OK) {
    log(2, "LR2021 Init fehlgeschlagen, RadioLib-Code %d", code);
    led(LED_BRIGHTNESS, 0, 0);
  } else {
    measureHealth();
    if (rxWanted_) startRx(&code);
  }
}

int16_t Modem::checkFreq(uint32_t f, bool* is24) const {
  if (f >= SUBGHZ_MIN_HZ && f <= SUBGHZ_MAX_HZ) { if (is24) *is24 = false; return ST_OK; }
  if (f >= HF24_MIN_HZ && f <= HF24_MAX_HZ)     { if (is24) *is24 = true;  return ST_OK; }
  return ST_BAD_PARAM;
}

// Schnelltest vor RadioLib: Reset auslösen und prüfen, ob BUSY wieder LOW wird.
// Ohne diesen Test würde RadioLib bei defekter Leitung minutenlang auf BUSY warten.
static int16_t probeChip(uint8_t* busyDuringReset, uint32_t* bootMs) {
  pinMode(PIN_LR_BUSY, INPUT);
  pinMode(PIN_LR_RST, OUTPUT);
  digitalWrite(PIN_LR_RST, LOW);
  delay(5);
  *busyDuringReset = digitalRead(PIN_LR_BUSY);
  digitalWrite(PIN_LR_RST, HIGH);
  uint32_t t0 = millis();
  while (digitalRead(PIN_LR_BUSY) == HIGH) {
    if (millis() - t0 > 1000) { *bootMs = 1000; return RADIOLIB_ERR_SPI_CMD_TIMEOUT; }
    delay(1);
  }
  *bootMs = millis() - t0;
  return RADIOLIB_ERR_NONE;
}

// Der LR2021 kalibriert sein Empfangs-Frontend nur, wenn sich die Frequenz um mindestens 20 MHz ändert
// (RadioLib setFrequency). Nach dem Reset in applyConfig ist die Kalibrierung verloren, beim erneuten Setzen
// derselben Frequenz würde sie übersprungen -> Empfang unkalibriert (Chipfehler 0x0200). Deshalb hier über
// eine 30 MHz entfernte Frequenz erzwingen.
static int16_t forceFrontEndCal(uint32_t f) {
  auto valid = [](uint32_t x) {
    return (x >= 150000000UL && x <= 1090000000UL) || (x >= 1900000000UL && x <= 2200000000UL) ||
           (x >= 2400000000UL && x <= 2500000000UL);
  };
  uint32_t other = valid(f + 30000000UL) ? f + 30000000UL : f - 30000000UL;
  radio.setFrequency(other, true);          // nur umstellen, ohne Kalibrierung
  return radio.setFrequency(f, false);      // zurück: Abstand >= 20 MHz -> Kalibrierung für f
}

// Frontend: gewünschte Leistung an der Buchse -> LR2021-Pegel. Unter der kleinsten PA-Leistung
// (LR2021-Minimum + PA-Verstärkung - Filter, etwa 14 dBm) läuft das Senden über den Bypass;
// dort reicht der Pegel bis etwa 3 dBm (Wünsche zwischen 4 und 13 dBm werden mit diesen 3 dBm erfüllt,
// nie mit mehr). Die gesetzliche Grenze der Frequenz gilt immer.
int8_t Modem::txDrive(uint32_t f, uint32_t bw, int8_t outDbm) {
  bool is24 = f > 2000000000UL;
  if (!g_fe || is24) {
    int p = outDbm;
    if (!is24 && p > RADIOLIB_LR2021_LF_POUT_MAX) p = RADIOLIB_LR2021_LF_POUT_MAX;   // gespeichert mit Frontend
    g_fePa = false; g_feOut = (int8_t)p; g_feDrive = (int8_t)p;
    return (int8_t)p;
  }
  int out = outDbm;
  g_feLegal = legalMaxDbm(f, bw);
#if FE_LEGAL_CAP
  if (out > g_feLegal) {
    log(1, "Frontend: %d dBm bei %.3f MHz nicht erlaubt, sende mit %d dBm", out, f / 1e6, g_feLegal);
    out = g_feLegal;
  }
#endif
  if (out > FE_OUT_MAX_DBM) out = FE_OUT_MAX_DBM;
  // Rechnung mit der Kalibrierung (0,1 dB, siehe fe_calc.h); LR2021-Pegel nie über FE_DRIVE_MAX_DBM
  bool pa = false;
  int actual = 0;
  int d = feCalcDrive(out, g_cal, RADIOLIB_LR2021_LF_POUT_MIN, FE_DRIVE_MAX_DBM, &pa, &actual);
  g_fePa = pa;
  g_feDrive = (int8_t)d;
  g_feOut = (int8_t)actual;
  return g_feDrive;
}

int16_t Modem::applyConfig(int16_t* rc) {
  int16_t s;
  {
    uint8_t bdr = 0;
    uint32_t bootMs = 0;
    int16_t p = probeChip(&bdr, &bootMs);
    if (p != RADIOLIB_ERR_NONE) {
      log(2, "LR2021 BUSY (GPIO%d) bleibt HIGH nach Reset (RST=GPIO%d). BUSY-Leitung, RST-Leitung oder 3,3 V zum Modul pruefen.",
          PIN_LR_BUSY, PIN_LR_RST);
      initCode_ = p;
      if (rc) *rc = p;
      radioOk_ = false;
      rs_ = RS_OFF;
      return ST_RADIO_ERROR;
    }
    log(0, "LR2021 Reset ok: BUSY war %d waehrend Reset, nach %lu ms LOW", bdr, (unsigned long)bootMs);
  }
  radio.clearIrqAction();
  g_irq = false;
  // RadioLib beendet SPI, wenn der Chip nicht gefunden wurde -> hier immer mit unseren Pins starten
  lrSpi.begin(PIN_LR_SCK, PIN_LR_MISO, PIN_LR_MOSI, -1);
  if (modem_ == MODEM_FSK) {
    ConfigFSK_t c;
    c.frequency = fsk_.freq_hz;
    c.bitRate = fsk_.bitrate_bps;
    c.frequencyDeviation = fsk_.fdev_hz;
    c.receiverBandwidth = fsk_.rxbw_hz;
    c.power = txDrive(fsk_.freq_hz, fsk_.rxbw_hz, fsk_.power_dbm);
    c.preambleLength = fsk_.preamble_bits;
    s = radio.beginGFSK(c);
    if (s == RADIOLIB_ERR_NONE) s = forceFrontEndCal(fsk_.freq_hz);
    if (s == RADIOLIB_ERR_NONE) s = radio.setSyncWord((uint8_t*)fsk_.sync, fsk_.sync_len);
    if (s == RADIOLIB_ERR_NONE) s = radio.setCRC(fsk_.crc_len);
    if (s == RADIOLIB_ERR_NONE) s = radio.setWhitening(fsk_.flags & 0x01);
    if (s == RADIOLIB_ERR_NONE) {
      static const uint8_t sh[] = { RADIOLIB_SHAPING_NONE, RADIOLIB_SHAPING_0_3, RADIOLIB_SHAPING_0_5,
                                    RADIOLIB_SHAPING_0_7, RADIOLIB_SHAPING_1_0 };
      s = radio.setDataShaping(sh[fsk_.shaping <= 4 ? fsk_.shaping : 0]);
    }
    if (s == RADIOLIB_ERR_NONE) {
      s = (fsk_.flags & 0x02) ? radio.fixedPacketLengthMode(fsk_.fixed_len ? fsk_.fixed_len : 1)
                              : radio.variablePacketLengthMode(RADIOLIB_LR2021_MAX_PACKET_LENGTH);
    }
  } else {
    ConfigLoRa_t c;
    c.frequency = lora_.freq_hz;
    c.bandwidth = lora_.bw_hz;
    c.spreadingFactor = lora_.sf;
    c.codingRate = lora_.cr;
    c.syncWord = lora_.sync;
    c.power = txDrive(lora_.freq_hz, lora_.bw_hz, lora_.power_dbm);
    c.preambleLength = lora_.preamble;
    s = radio.begin(c);
    if (s == RADIOLIB_ERR_NONE) s = forceFrontEndCal(lora_.freq_hz);
    if (s == RADIOLIB_ERR_NONE) s = radio.setCRC((lora_.flags & 0x01) ? 2 : 0);
    if (s == RADIOLIB_ERR_NONE) s = radio.invertIQ(lora_.flags & 0x02);
    if (s == RADIOLIB_ERR_NONE) s = (lora_.flags & 0x04) ? radio.implicitHeader(lora_.implicit_len) : radio.explicitHeader();
    if (s == RADIOLIB_ERR_NONE) {
      if (lora_.flags & 0x08)      s = radio.forceLDRO(true);
      else if (lora_.flags & 0x10) s = radio.forceLDRO(false);
      else                         s = radio.autoLDRO();
    }
  }
  if (modem_ == MODEM_LORA && lora_.bw_hz) {
    uint32_t symUs = (uint32_t)(((uint64_t)1000000ULL << lora_.sf) / lora_.bw_hz);
    g_cadTimeoutMs = symUs * 8 / 1000 + 100;
    if (g_cadTimeoutMs < CAD_TIMEOUT_MS) g_cadTimeoutMs = CAD_TIMEOUT_MS;
    g_cadMinMs = symUs * 4 / 1000 + 2;      // CAD dauert einige Symbole – vorher nicht per SPI stören
  }
  initCode_ = s;
  if (rc) *rc = s;
  radioOk_ = (s == RADIOLIB_ERR_NONE);
  if (!radioOk_) { rs_ = RS_OFF; return ST_RADIO_ERROR; }
  radio.setIrqAction(onRadioIrq);
  rs_ = RS_STANDBY;
  return ST_OK;
}

void Modem::measureHealth() {
  if (!radioOk_ || (rs_ != RS_STANDBY)) return;
  float t = radio.getTemperature(RADIOLIB_LR2021_TEMP_SOURCE_VBE);
  float v = radio.getVoltage();
  temp10_ = (int16_t)(t * 10.0f);
  vbatMv_ = (uint16_t)(v * 1000.0f);
}

void Modem::wake() {
  if (rs_ == RS_SLEEP) {
    radio.standby();
    feRx();                                  // Frontend wieder an (sonst lauscht z. B. CAD ins Leere)
    rs_ = RS_STANDBY;
  }
}

// ---------------------------------------------------------------------------
// Befehle
int16_t Modem::setLora(const LoraCfg& c, int16_t* rc) {
  bool is24;
  if (checkFreq(c.freq_hz, &is24) != ST_OK) return ST_BAD_PARAM;
  if (c.sf < 5 || c.sf > 12 || c.cr < 5 || c.cr > 8) return ST_BAD_PARAM;
  if (is24 ? (c.power_dbm < RADIOLIB_LR2021_HF_POUT_MIN || c.power_dbm > RADIOLIB_LR2021_HF_POUT_MAX)
           : (c.power_dbm < RADIOLIB_LR2021_LF_POUT_MIN || c.power_dbm > subGhzMax())) return ST_POWER_LIMIT;
  if (c.preamble < 6) return ST_BAD_PARAM;
  if ((c.flags & 0x04) && c.implicit_len == 0) return ST_BAD_PARAM;
  if (rs_ == RS_TX) return ST_BUSY;
  LoraCfg oldL = lora_;
  uint8_t oldM = modem_;
  lora_ = c;
  modem_ = MODEM_LORA;
  int16_t st = applyConfig(rc);
  if (st != ST_OK) {               // ungültige Kombination: alte Werte zurück
    int16_t dummy;
    lora_ = oldL;
    modem_ = oldM;
    applyConfig(&dummy);
  }
  if (radioOk_ && rxWanted_) { int16_t d; startRx(&d); }
  return st;
}

int16_t Modem::setFsk(const FskCfg& c, int16_t* rc) {
  bool is24;
  if (checkFreq(c.freq_hz, &is24) != ST_OK) return ST_BAD_PARAM;
  if (c.sync_len < 1 || c.sync_len > 8 || c.crc_len > 2 || c.shaping > 4) return ST_BAD_PARAM;
  if (c.bitrate_bps < 600 || c.bitrate_bps > 2000000) return ST_BAD_PARAM;
  if (is24 ? (c.power_dbm < RADIOLIB_LR2021_HF_POUT_MIN || c.power_dbm > RADIOLIB_LR2021_HF_POUT_MAX)
           : (c.power_dbm < RADIOLIB_LR2021_LF_POUT_MIN || c.power_dbm > subGhzMax())) return ST_POWER_LIMIT;
  if ((c.flags & 0x02) && c.fixed_len == 0) return ST_BAD_PARAM;
  if (rs_ == RS_TX) return ST_BUSY;
  FskCfg oldF = fsk_;
  uint8_t oldM = modem_;
  fsk_ = c;
  modem_ = MODEM_FSK;
  int16_t st = applyConfig(rc);
  if (st != ST_OK) {
    int16_t dummy;
    fsk_ = oldF;
    modem_ = oldM;
    applyConfig(&dummy);
  }
  if (radioOk_ && rxWanted_) { int16_t d; startRx(&d); }
  return st;
}

int16_t Modem::setLimits(const Limits& l) {
  if (l.max_pwr_subghz > subGhzMax() || l.max_pwr_24 > RADIOLIB_LR2021_HF_POUT_MAX) return ST_BAD_PARAM;
  if (l.duty_permille > 1000) return ST_BAD_PARAM;
  lim_ = l;
  return ST_OK;
}

int16_t Modem::checkTxAllowed(uint16_t len, uint32_t* toaUs) {
  if (!radioOk_) return ST_NOT_READY;
  wake();                                       // Sendezeit-Berechnung braucht SPI
  bool is24 = false;
  uint32_t f = (modem_ == MODEM_FSK) ? fsk_.freq_hz : lora_.freq_hz;
  int8_t p = (modem_ == MODEM_FSK) ? fsk_.power_dbm : lora_.power_dbm;
  checkFreq(f, &is24);
  if (!(lim_.allow_mask & (is24 ? 0x02 : 0x01))) return ST_TX_FORBIDDEN;
  if (p > (is24 ? lim_.max_pwr_24 : lim_.max_pwr_subghz)) return ST_POWER_LIMIT;
  RadioLibTime_t t = radio.getTimeOnAir(len);
  if ((int64_t)t <= 0 || t > 60000000ULL) return ST_RADIO_ERROR;   // Fehlercode statt Zeit
  uint32_t toa = (uint32_t)t;
  if (toaUs) *toaUs = toa;
  if (lim_.duty_permille) {
    uint32_t budgetMs = (uint32_t)lim_.duty_permille * 3600UL;   // Promille von 3 600 000 ms
    if (airtimeLastHour() + toa / 1000 + 1 > budgetMs) return ST_DUTY_LIMIT;
  }
  return ST_OK;
}

int16_t Modem::queueTx(uint16_t id, uint8_t flags, const uint8_t* data, uint16_t len) {
  if (len == 0 || len > RADIOLIB_LR2021_MAX_PACKET_LENGTH) return ST_BAD_LENGTH;
  if (suspended_) { st_.tx_rejected++; return ST_BUSY; }
  if (modem_ == MODEM_LORA && (lora_.flags & 0x04) && len != lora_.implicit_len) return ST_BAD_LENGTH;
  if (modem_ == MODEM_FSK && (fsk_.flags & 0x02) && len != fsk_.fixed_len) return ST_BAD_LENGTH;
  int16_t st = checkTxAllowed(len, nullptr);
  if (st != ST_OK) { st_.tx_rejected++; return st; }
  if (qCount_ >= TX_QUEUE_LEN) { st_.tx_rejected++; return ST_BUSY; }
  TxItem& it = q_[(qHead_ + qCount_) % TX_QUEUE_LEN];
  it.id = id;
  it.flags = flags;
  it.len = (uint8_t)len;
  it.tries = 0;
  it.notBefore = 0;
  memcpy(it.data, data, len);
  qCount_++;
  return ST_OK;
}

int16_t Modem::startRx(int16_t* rc) {
  if (!radioOk_) return ST_NOT_READY;
  if (suspended_) return ST_BUSY;
  rxWanted_ = true;
  if (rs_ == RS_TX) return ST_OK;          // nach dem Senden geht es automatisch in den Empfang
  if (rs_ == RS_RX) return ST_OK;          // läuft schon
  wake();
  radio.standby();                         // Empfang immer aus dem Standby starten
  feRx();
  drainRxFifo();
  g_irq = false;
  int16_t s = radio.startReceive();
  if (rc) *rc = s;
  if (s != RADIOLIB_ERR_NONE) { rs_ = RS_STANDBY; return ST_RADIO_ERROR; }
  rs_ = RS_RX;
  led(0, 0, LED_BRIGHTNESS / 3 + 1);
  return ST_OK;
}

int16_t Modem::standby() {
  rxWanted_ = false;
  if (!radioOk_) return ST_NOT_READY;
  if (rs_ == RS_TX) return ST_OK;          // Senden läuft zu Ende, danach Standby
  wake();
  radio.standby();
  g_irq = false;
  rs_ = RS_STANDBY;
  led(0, 0, 0);
  return ST_OK;
}

int16_t Modem::sleep() {
  if (!radioOk_) return ST_NOT_READY;
  if (rs_ == RS_TX || qCount_) return ST_BUSY;
  rxWanted_ = false;
  wake();
  radio.standby();
  radio.sleep();
  feSleep();
  g_irq = false;
  rs_ = RS_SLEEP;
  led(0, 0, 0);
  return ST_OK;
}

// Reste eines unterbrochenen Empfangs aus dem RX-FIFO entfernen
void Modem::drainRxFifo() {
  uint16_t lvl = 0;
  uint8_t dump[64];
  for (int i = 0; i < 8; i++) {
    if (radio.getRxFifoLevel(&lvl) != RADIOLIB_ERR_NONE || lvl == 0) return;
    radio.readRadioRxFifo(dump, lvl > sizeof(dump) ? sizeof(dump) : lvl);
  }
}

static int16_t doCad(uint8_t* busy, int16_t* rc) {
  g_irq = false;
  int16_t s = radio.startChannelScan();
  if (rc) *rc = s;
  if (s != RADIOLIB_ERR_NONE) return ST_RADIO_ERROR;
  uint32_t t0 = millis();
  // auf "CAD fertig" warten: IRQ-Leitung, SPI-Abfrage erst nach der Mindestdauer (siehe oben)
  uint32_t lastPoll = 0;
  for (;;) {
    if (digitalRead(PIN_LR_IRQ) == HIGH) break;
    if (millis() - t0 >= g_cadMinMs && millis() - lastPoll >= 5) {
      lastPoll = millis();
      if (radio.getIrqFlags() & (RADIOLIB_LR2021_IRQ_CAD_DONE | RADIOLIB_LR2021_IRQ_CAD_DETECTED)) break;
    }
    if (millis() - t0 > g_cadTimeoutMs) { radio.standby(); g_irq = false; return ST_TIMEOUT; }
    delay(1);
  }
  s = radio.getChannelScanResult();
  radio.standby();                          // nach CAD sauber in Standby (Fallback-Zustand stört sonst TX/RX)
  radio.clearIrqFlags(RADIOLIB_LR2021_IRQ_ALL);
  g_irq = false;
  if (rc) *rc = s;
  if (s == RADIOLIB_LORA_DETECTED) { *busy = 1; return ST_OK; }
  if (s == RADIOLIB_CHANNEL_FREE)  { *busy = 0; return ST_OK; }
  return ST_RADIO_ERROR;
}

int16_t Modem::cad(uint8_t* busy, int16_t* rc) {
  if (!radioOk_) return ST_NOT_READY;
  if (modem_ != MODEM_LORA) return ST_WRONG_MODEM;
  if (rs_ == RS_TX) return ST_BUSY;
  wake();
  if (rs_ == RS_RX) radio.standby();
  int16_t st = doCad(busy, rc);
  rs_ = RS_STANDBY;
  if (rxWanted_) { int16_t d; startRx(&d); }
  else radio.standby();
  return st;
}

int16_t Modem::rssi(int16_t* rssi10) {
  if (!radioOk_) return ST_NOT_READY;
  if (rs_ != RS_RX) return ST_NOT_READY;
  float r = radio.getRSSI(false, true) - feRxGainDb();     // bezogen auf die Antennenbuchse
  *rssi10 = (int16_t)(r * 10.0f);
  return ST_OK;
}

int16_t Modem::resetRadio(int16_t* rc) {
  if (rs_ == RS_TX) { st_.tx_fail++; finishTx(ST_NOT_READY); }
  feRx();
  while (qCount_) {                               // verworfene Pakete melden
    cur_ = q_[qHead_];
    qHead_ = (qHead_ + 1) % TX_QUEUE_LEN;
    qCount_--;
    txToaUs_ = 0;
    st_.tx_rejected++;
    finishTx(ST_NOT_READY);
  }
  rs_ = RS_OFF;
  int16_t st = applyConfig(rc);
  if (st == ST_OK) { measureHealth(); if (rxWanted_) { int16_t d; startRx(&d); } }
  return st;
}

// ---------------------------------------------------------------------------
// Sendezeit-Buchhaltung (1 Stunde gleitend, Minutenraster)
void Modem::addAirtime(uint32_t ms) {
  airtimeLastHour();                 // Ringpuffer aktualisieren
  uint32_t v = minuteAir_[minuteIdx_] + ms;
  minuteAir_[minuteIdx_] = v > 0xFFFF ? 0xFFFF : (uint16_t)v;
  st_.airtime_total_ms += ms;
}

uint32_t Modem::airtimeLastHour() {
  uint32_t nowMin = millis() / 60000UL;
  if (nowMin != minuteStamp_) {
    uint32_t steps = nowMin - minuteStamp_;
    if (steps > 60) steps = 60;
    for (uint32_t i = 0; i < steps; i++) {
      minuteIdx_ = (minuteIdx_ + 1) % 60;
      minuteAir_[minuteIdx_] = 0;
    }
    minuteStamp_ = nowMin;
  }
  uint32_t sum = 0;
  for (int i = 0; i < 60; i++) sum += minuteAir_[i];
  return sum;
}

// ---------------------------------------------------------------------------
// Ablauf
void Modem::finishTx(int16_t status) {
  uint8_t ev[8];
  ev[0] = (uint8_t)cur_.id; ev[1] = (uint8_t)(cur_.id >> 8);
  ev[2] = (uint8_t)status;  ev[3] = (uint8_t)((uint16_t)status >> 8);
  memcpy(ev + 4, &txToaUs_, 4);
  if (sink_) sink_(EVT_TX_DONE, ev, sizeof(ev));
}

void Modem::startNextTx() {
  if (!qCount_ || rs_ == RS_TX || !radioOk_) return;
  TxItem& it = q_[qHead_];
  if (it.notBefore && (int32_t)(millis() - it.notBefore) < 0) return;

  uint32_t toa = 0;
  int16_t st = checkTxAllowed(it.len, &toa);
  if (st == ST_OK && (it.flags & 0x01) && modem_ == MODEM_LORA) {
    wake();
    if (rs_ == RS_RX) radio.standby();
    uint8_t busy = 0;
    int16_t rc;
    int16_t cs = doCad(&busy, &rc);
    rs_ = RS_STANDBY;
    if (cs != ST_OK) log(1, "LBT: Kanalprüfung fehlgeschlagen (%d/%d), sende trotzdem", cs, rc);
    if (cs == ST_OK && busy) {
      st_.cad_busy++;
      if (++it.tries < 6) {
        it.notBefore = millis() + (uint32_t)random(80, 400) * it.tries;
        if (rxWanted_) { int16_t d; startRx(&d); }
        return;
      }
      st = ST_CHANNEL_BUSY;
    }
  }

  cur_ = it;
  qHead_ = (qHead_ + 1) % TX_QUEUE_LEN;
  qCount_--;
  txToaUs_ = toa;

  if (st != ST_OK) {
    st_.tx_rejected++;
    finishTx(st);
    if (rxWanted_) { int16_t d; startRx(&d); }
    return;
  }
  wake();
  if (rs_ == RS_RX) radio.standby();             // aus dem Dauerempfang erst in Standby
  rs_ = RS_STANDBY;
  radio.clearTxBuffer();                         // Reste eines abgebrochenen Sendens entfernen
  g_irq = false;
  g_txIgnorePin = false;
  g_txSpurious = 0;
  bool is24 = ((modem_ == MODEM_FSK) ? fsk_.freq_hz : lora_.freq_hz) > 2000000000UL;
  if (!is24) feTx();                             // Frontend vor dem LR2021 auf Senden (PA oder Bypass)
  int16_t s = radio.startTransmit(cur_.data, cur_.len);
  if (s != RADIOLIB_ERR_NONE) {
    st_.tx_fail++;
    log(2, "startTransmit Fehler %d", s);
    feRx();
    rs_ = RS_STANDBY;
    finishTx(ST_RADIO_ERROR);
    if (rxWanted_) { int16_t d; startRx(&d); }
    return;
  }
  rs_ = RS_TX;
  txStart_ = millis();
  led(LED_BRIGHTNESS, 0, 0);
}

void Modem::handleRx() {
  static uint8_t buf[RADIOLIB_LR2021_MAX_PACKET_LENGTH];
  static uint32_t lastErrLog = 0, suppressed = 0;
  // Nur "Paket fertig" auswerten. Andere Meldungen (z. B. Header erkannt) quittieren,
  // sonst bleibt die IRQ-Leitung HIGH und die Schleife hängt.
  uint32_t irq = radio.getIrqFlags();
  if (!(irq & RADIOLIB_LR2021_IRQ_RX_DONE)) {
    radio.clearIrqFlags(irq ? irq : RADIOLIB_LR2021_IRQ_ALL);
    return;
  }
  size_t len = radio.getPacketLength();
  if (len == 0) {
    radio.clearIrqFlags(RADIOLIB_LR2021_IRQ_ALL);
    return;
  }
  if (len > sizeof(buf)) len = sizeof(buf);
  float rssi = radio.getRSSI(true) - feRxGainDb();          // bezogen auf die Antennenbuchse
  float snr = (modem_ == MODEM_LORA) ? radio.getSNR() : 0.0f;
  int32_t fe = (modem_ == MODEM_LORA) ? radio.getFrequencyError() : 0;
  int16_t s = radio.readData(buf, len);

  if (s == RADIOLIB_ERR_NONE || s == RADIOLIB_ERR_CRC_MISMATCH) {
    bool crcErr = (s == RADIOLIB_ERR_CRC_MISMATCH);
    if (crcErr) st_.rx_crc_err++; else st_.rx_ok++;
    uint8_t ev[13 + RADIOLIB_LR2021_MAX_PACKET_LENGTH];
    int16_t r10 = (int16_t)(rssi * 10.0f), s10 = (int16_t)(snr * 10.0f);
    uint32_t now = millis();
    memcpy(ev + 0, &r10, 2);
    memcpy(ev + 2, &s10, 2);
    memcpy(ev + 4, &fe, 4);
    ev[8] = crcErr ? 1 : 0;
    memcpy(ev + 9, &now, 4);
    memcpy(ev + 13, buf, len);
    if (sink_) sink_(EVT_RX, ev, (uint16_t)(13 + len));
    led(0, LED_BRIGHTNESS, 0);
    ledOffAt_ = millis() + 60;
  } else {
    radio.clearIrqFlags(RADIOLIB_LR2021_IRQ_ALL);
    if (s != RADIOLIB_ERR_RX_TIMEOUT) {
      if (millis() - lastErrLog > 2000) {        // höchstens alle 2 s eine Meldung
        log(1, "Empfangsfehler %d (%lu weitere unterdrückt)", s, (unsigned long)suppressed);
        lastErrLog = millis();
        suppressed = 0;
      } else {
        suppressed++;
      }
    }
  }
  // Dauerempfang läuft im Chip weiter (Timeout "unendlich"), kein Neustart nötig
  if (!rxWanted_) { radio.standby(); rs_ = RS_STANDBY; }
}

void Modem::handleIrq() {
  if (rs_ == RS_TX) {
    // Echte IRQ-Flags prüfen, bevor der Sender abgeschaltet wird.
    // Störimpulse ohne TX_DONE/TIMEOUT werden ignoriert (siehe Kommentar oben).
    uint32_t el = millis() - txStart_;
    uint32_t f = radio.getIrqFlags();
    if (f != 0xFFFFFFFFUL && !(f & (RADIOLIB_LR2021_IRQ_TX_DONE | RADIOLIB_LR2021_IRQ_TIMEOUT))) {
      if (g_txSpurious < 0xFFFF) g_txSpurious++;
      g_txIgnorePin = true;                      // Pegel-Abfrage für dieses Paket aus (Leitung hängt evtl. HIGH)
      return;                                    // Watchdog/SPI-Abfrage nach der Sendezeit fangen das Ende
    }
    uint16_t err = 0;
    radio.getErrors(&err);
    if (err || (f & RADIOLIB_LR2021_IRQ_TIMEOUT) || el + 50 < txToaUs_ / 1000)
      log(1, "TX-Ende nach %lu ms (berechnet %lu): Flags=0x%08lX Chipfehler=0x%04X, %u Fehl-IRQs, Quelle %s",
          (unsigned long)el, (unsigned long)(txToaUs_ / 1000), (unsigned long)f, err, g_txSpurious, g_irqSrc);
    else if (g_txSpurious)
      log(0, "TX ok nach %lu ms (berechnet %lu), %u Fehl-IRQs ignoriert",
          (unsigned long)el, (unsigned long)(txToaUs_ / 1000), g_txSpurious);
    radio.finishTransmit();
    feRx();
    rs_ = RS_STANDBY;
    st_.tx_ok++;
    addAirtime(txToaUs_ / 1000 + 1);
    finishTx(ST_OK);
    led(0, 0, 0);
    if (!qCount_ && rxWanted_) { int16_t d; startRx(&d); }
  } else if (rs_ == RS_RX) {
    handleRx();
  } else {
    // unerwarteter Interrupt (z. B. nach Standby) – Flags löschen
    if (rs_ != RS_SLEEP) radio.clearIrqFlags(0xFFFFFFFFUL);
  }
}

void Modem::loop() {
  if (!radioOk_) return;
  if (suspended_) { g_irq = false; return; }     // Firmware-Update: Funk ruht
  bool pending = g_irq;
  g_irqSrc = "ISR";
  // Absicherung, falls eine Flanke verpasst wurde: IRQ-Pin direkt prüfen
  if (!pending && (rs_ == RS_RX || (rs_ == RS_TX && !g_txIgnorePin)) && digitalRead(PIN_LR_IRQ) == HIGH) {
    pending = true;
    g_irqSrc = "Pin-Pegel";
  }
  // Zusätzliche Abfrage per SPI:
  //  - Empfang: Status alle 50 ms abfragen.
  //  - Senden: erst nach Ablauf der berechneten Sendezeit (vorher reicht die ISR; Störimpulse werden
  //    in handleIrq anhand der echten Flags aussortiert).
  static uint32_t lastPoll = 0;
  static bool irqWarned = false;
  bool txPollOk = (rs_ == RS_TX) && (millis() - txStart_ >= txToaUs_ / 1000 + 30);
  if (!pending && (rs_ == RS_RX || txPollOk) && millis() - lastPoll >= 50) {
    lastPoll = millis();
    uint32_t f = radio.getIrqFlags();
    if (f != 0xFFFFFFFFUL &&
        ((rs_ == RS_RX && (f & RADIOLIB_LR2021_IRQ_RX_DONE)) || (rs_ == RS_TX && (f & RADIOLIB_LR2021_IRQ_TX_DONE)))) {
      pending = true;
      g_irqSrc = "SPI-Abfrage";
      if (!irqWarned && digitalRead(PIN_LR_IRQ) == LOW) {   // nur einmal melden
        irqWarned = true;
        log(1, "IRQ-Leitung (DIO11 -> GPIO%d) meldete nichts, Ereignis per SPI erkannt.", PIN_LR_IRQ);
      }
    }
  }
  if (pending) {
    g_irq = false;
    handleIrq();
  }
  // TX-Watchdog
  if (rs_ == RS_TX) {
    uint32_t limit = (uint32_t)(txToaUs_ / 1000.0f * TX_TIMEOUT_MARGIN) + 250;
    if (millis() - txStart_ > limit) {
      radio.finishTransmit();
      feRx();
      rs_ = RS_STANDBY;
      st_.tx_fail++;
      log(2, "TX-Zeitüberschreitung (IRQ kam nicht)");
      finishTx(ST_TIMEOUT);
      if (rxWanted_) { int16_t d; startRx(&d); }
    }
  }
  if (rs_ != RS_TX) startNextTx();
  if (g_fe && g_feMode == 0 && rs_ == RS_RX && (int32_t)(millis() - g_feNextEval) >= 0) feEvaluate();
  if (ledOffAt_ && (int32_t)(millis() - ledOffAt_) >= 0) {
    ledOffAt_ = 0;
    if (rs_ == RS_RX) led(0, 0, LED_BRIGHTNESS / 3 + 1); else led(0, 0, 0);
  }
}

// ---------------------------------------------------------------------------
void Modem::fillInfo(InfoBlock& i) {
  measureHealth();
  memset(&i, 0, sizeof(i));
  i.proto = PROTO_VERSION;
  i.fw_major = FW_VERSION_MAJOR;
  i.fw_minor = FW_VERSION_MINOR;
  i.fw_patch = FW_VERSION_PATCH;
  i.role = MODEM_ROLE_CHAR;
  i.band_id = MODEM_BAND_ID;
  i.radio_ok = radioOk_ ? 1 : 0;
  i.radio_state = rs_;
  i.modem = modem_;
  i.uptime_ms = millis();
  i.chip_id = (uint32_t)(ESP.getEfuseMac() & 0xFFFFFFFFULL);
  i.init_code = initCode_;
  i.temp_c10 = temp10_;
  i.vbat_mv = vbatMv_;
  i.subghz_min_hz = SUBGHZ_MIN_HZ;
  i.subghz_max_hz = SUBGHZ_MAX_HZ;
}

// LNA-Automatik: Rauschboden abwechselnd mit und ohne LNA messen (Median aus 7 Paaren).
// Der Unterschied d beider Werte am LR2021 verrät, wer das Rauschen bestimmt:
//  - Empfänger rauscht selbst (ruhiger Standort): d ist deutlich kleiner als der Verstärkungsunterschied
//    G (LNA 16 dB gegen Bypass -2 dB = 18 dB). Der LNA bringt dann G - d dB mehr Empfindlichkeit -> an.
//  - Rauschen/Störungen von außen überwiegen (Stadt, Sender in der Nähe): d ~ G, der LNA bringt nichts,
//    macht den Empfänger aber übersteuerungsanfällig -> aus (wie das Abschalten des LNA bei der Station G3).
// Zusätzlich aus, wenn das Rauschen mit LNA am LR2021 über -80 dBm liegt (Übersteuerung droht).
void Modem::feEvaluate() {
  const int N = 7;
  g_feNextEval = millis() + FE_AUTO_PERIOD_MS;
  uint32_t f0 = radio.getIrqFlags();
  if (f0 != 0xFFFFFFFFUL && (f0 & (RADIOLIB_LR2021_IRQ_PREAMBLE_DETECTED | RADIOLIB_LR2021_IRQ_LORA_HEADER_VALID |
                                   RADIOLIB_LR2021_IRQ_RX_DONE))) {
    g_feNextEval = millis() + 5000;          // gerade kommt etwas an: später nochmal
    return;
  }
  bool lna0 = g_feLna;
  float on[N], off[N];
  for (int i = 0; i < N; i++) {
    g_feLna = true;  feRx(); delay(3); on[i] = radio.getRSSI(false, true);
    g_feLna = false; feRx(); delay(3); off[i] = radio.getRSSI(false, true);
  }
  g_feLna = lna0;
  feRx();
  uint32_t f1 = radio.getIrqFlags();
  if (f1 != 0xFFFFFFFFUL && (f1 & (RADIOLIB_LR2021_IRQ_PREAMBLE_DETECTED | RADIOLIB_LR2021_IRQ_RX_DONE))) {
    g_feNextEval = millis() + 5000;          // Paket während der Messung: Ergebnis verwerfen
    return;
  }
  auto median = [](float* a, int n) {
    for (int i = 1; i < n; i++) for (int j = i; j > 0 && a[j] < a[j - 1]; j--) { float t = a[j]; a[j] = a[j - 1]; a[j - 1] = t; }
    return a[n / 2];
  };
  float mOn = median(on, N), mOff = median(off, N);
  float d = mOn - mOff;
  const float G = (g_cal.lna10 + g_cal.byp10) / 10.0f;
  bool lna = g_feLna;
  if (mOn > -80.0f) lna = false;
  else if (d < G - 3.0f) lna = true;          // LNA bringt mehr als 3 dB
  else if (d > G - 1.0f) lna = false;         // LNA bringt weniger als 1 dB
  g_feNoiseOn10 = (int16_t)(mOn * 10.0f - (g_cal.lna10 - g_cal.filt10));
  g_feNoiseOff10 = (int16_t)(mOff * 10.0f + g_cal.byp10 + g_cal.filt10);
  if (lna != g_feLna) {
    g_feLna = lna;
    feRx();
    log(0, "Frontend: LNA %s (Rauschen am LR2021 mit LNA %.1f, ohne %.1f dBm, Gewinn durch LNA %.1f dB)",
        lna ? "an" : "aus", mOn, mOff, G - d);
  }
}

void Modem::fillFe(FeInfo& f) {
  memset(&f, 0, sizeof(f));
  f.present = g_fe ? 1 : 0;
  f.lna_mode = g_feMode;
  f.lna_on = (g_fe && g_feLna) ? 1 : 0;
  f.pa = g_fePa ? 1 : 0;
  f.noise_on10 = g_feNoiseOn10;
  f.noise_off10 = g_feNoiseOff10;
  f.out_dbm = g_feOut;
  f.legal_dbm = g_fe ? g_feLegal : 0;
  f.drive_dbm = g_feDrive;
  f.out_max_dbm = subGhzMax();
  f.pa_gain10 = g_cal.pa10;
  f.filter_loss10 = g_cal.filt10;
  f.lna_gain10 = g_cal.lna10;
  f.bypass_loss10 = g_cal.byp10;
  f.cal_flags = (calIsDefault(g_cal) ? 0 : 0x01) | (g_calStored ? 0x02 : 0);
}

int16_t Modem::setFe(uint8_t mode, uint8_t flags, const FeCal* cal) {
  // erst alles prüfen, dann ändern
  if (mode > 2 && mode != 0xFF) return ST_BAD_PARAM;
  bool save = flags & 0x01, reset = flags & 0x02;
  bool calGiven = reset;
  FeCalValues nc = reset ? FE_CAL_DEFAULT : g_cal;
  if (cal) {
    if (cal->pa_gain10 != FE_CAL_KEEP)     { nc.pa10 = cal->pa_gain10;       calGiven = true; }
    if (cal->filter_loss10 != FE_CAL_KEEP) { nc.filt10 = cal->filter_loss10; calGiven = true; }
    if (cal->lna_gain10 != FE_CAL_KEEP)    { nc.lna10 = cal->lna_gain10;     calGiven = true; }
    if (cal->bypass_loss10 != FE_CAL_KEEP) { nc.byp10 = cal->bypass_loss10;  calGiven = true; }
  }
  if (!calValid(nc)) return ST_BAD_PARAM;
  if (!g_fe) return ST_NOT_READY;
  if (suspended_) return ST_BUSY;                 // Firmware-Update läuft
  bool calChanged = memcmp(&nc, &g_cal, sizeof(nc)) != 0;
  if (calChanged && rs_ == RS_TX) return ST_BUSY;     // nicht während eines Pakets umrechnen

  if (mode != 0xFF) {
    g_feMode = mode;
    if (mode == 1) g_feLna = true;
    else if (mode == 2) g_feLna = false;
    else g_feNextEval = millis() + 1000;        // automatisch: gleich messen
    if (rs_ != RS_TX && rs_ != RS_SLEEP && !suspended_) feRx();
  }
  int16_t st = ST_OK;
  if (calChanged) {
    g_cal = nc;
    g_feNoiseOn10 = g_feNoiseOff10 = 0;        // alte Messung passt nicht mehr zur Kalibrierung
    log(0, "Frontend-Kalibrierung: PA %.1f, Filter %.1f, LNA %.1f, Bypass %.1f dB", nc.pa10 / 10.0,
        nc.filt10 / 10.0, nc.lna10 / 10.0, nc.byp10 / 10.0);
    st = reapplyPower();
  }
  if (save) {
    Preferences p;
    if (p.begin("lrmodem", false)) {
      if (mode != 0xFF) p.putUChar("fe", mode);
      if (calGiven) {
        if (calIsDefault(g_cal)) {
          if (p.isKey("fecal")) p.remove("fecal");
          g_calStored = false;
        } else {
          FeCalPersist cp;
          cp.magic = FE_CAL_MAGIC;
          cp.v = g_cal;
          g_calStored = p.putBytes("fecal", &cp, sizeof(cp)) == sizeof(cp);
        }
      }
      p.end();
    }
  }
  return st;
}

// Neue Kalibrierung wirksam machen: LR2021 mit dem neu berechneten Pegel einstellen (wie bei SET_LORA/SET_FSK)
int16_t Modem::reapplyPower() {
  if (!radioOk_) return ST_OK;                 // wird bei der nächsten Initialisierung übernommen (applyConfig)
  bool wasSleep = (rs_ == RS_SLEEP);
  int16_t rc = 0;
  int16_t st = applyConfig(&rc);
  if (st != ST_OK) return st;
  if (wasSleep && !rxWanted_ && !qCount_) {
    radio.sleep();
    feSleep();
    rs_ = RS_SLEEP;
  } else if (rxWanted_) {
    startRx(&rc);
  } else {
    feRx();
  }
  return ST_OK;
}

int16_t Modem::suspend() {
  if (rs_ == RS_TX) return ST_BUSY;             // laufendes Paket erst fertig senden lassen
  while (qCount_) {                             // wartende Pakete verwerfen und melden
    cur_ = q_[qHead_];
    qHead_ = (qHead_ + 1) % TX_QUEUE_LEN;
    qCount_--;
    txToaUs_ = 0;
    st_.tx_rejected++;
    finishTx(ST_NOT_READY);
  }
  if (radioOk_ && rs_ == RS_RX) {
    radio.standby();
    rs_ = RS_STANDBY;
  }
  g_irq = false;
  feSleep();
  suspended_ = true;
  led(LED_BRIGHTNESS, 0, LED_BRIGHTNESS);       // violett: Firmware-Update
  return ST_OK;
}

void Modem::resume() {
  if (!suspended_) return;
  suspended_ = false;
  led(0, 0, 0);
  if (!radioOk_ || rs_ == RS_SLEEP) return;     // Schlaf: Frontend bleibt aus (wie vor dem Update)
  feRx();
  if (rxWanted_) { int16_t d; startRx(&d); }
}

void Modem::fillStats(Stats& s) {
  st_.airtime_hour_ms = airtimeLastHour();
  s = st_;
}

void Modem::resetStats() {
  memset(&st_, 0, sizeof(st_));
}
