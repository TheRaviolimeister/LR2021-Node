#include "modem.h"
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
  lim_.max_pwr_subghz = DEF_MAX_PWR_SUBGHZ;
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
  lrSpi.begin(PIN_LR_SCK, PIN_LR_MISO, PIN_LR_MOSI, -1);
  radio.tcxoVoltage = RadioLibTCXOVoltage_t::VoltageNone;   // Core2021 hat einen Quarz, keinen TCXO
  radio.irqDioNum = 11;                                     // DIO11 ist verdrahtet
  load();
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
    c.power = fsk_.power_dbm;
    c.preambleLength = fsk_.preamble_bits;
    s = radio.beginGFSK(c);
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
    c.power = lora_.power_dbm;
    c.preambleLength = lora_.preamble;
    s = radio.begin(c);
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
           : (c.power_dbm < RADIOLIB_LR2021_LF_POUT_MIN || c.power_dbm > RADIOLIB_LR2021_LF_POUT_MAX)) return ST_POWER_LIMIT;
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
           : (c.power_dbm < RADIOLIB_LR2021_LF_POUT_MIN || c.power_dbm > RADIOLIB_LR2021_LF_POUT_MAX)) return ST_POWER_LIMIT;
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
  if (l.max_pwr_subghz > RADIOLIB_LR2021_LF_POUT_MAX || l.max_pwr_24 > RADIOLIB_LR2021_HF_POUT_MAX) return ST_BAD_PARAM;
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
  rxWanted_ = true;
  if (rs_ == RS_TX) return ST_OK;          // nach dem Senden geht es automatisch in den Empfang
  if (rs_ == RS_RX) return ST_OK;          // läuft schon
  wake();
  radio.standby();                         // Empfang immer aus dem Standby starten
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
  float r = radio.getRSSI(false, true);
  *rssi10 = (int16_t)(r * 10.0f);
  return ST_OK;
}

int16_t Modem::resetRadio(int16_t* rc) {
  if (rs_ == RS_TX) { st_.tx_fail++; finishTx(ST_NOT_READY); }
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
  int16_t s = radio.startTransmit(cur_.data, cur_.len);
  if (s != RADIOLIB_ERR_NONE) {
    st_.tx_fail++;
    log(2, "startTransmit Fehler %d", s);
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
  float rssi = radio.getRSSI(true);
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
      rs_ = RS_STANDBY;
      st_.tx_fail++;
      log(2, "TX-Zeitüberschreitung (IRQ kam nicht)");
      finishTx(ST_TIMEOUT);
      if (rxWanted_) { int16_t d; startRx(&d); }
    }
  }
  if (rs_ != RS_TX) startNextTx();
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

void Modem::fillStats(Stats& s) {
  st_.airtime_hour_ms = airtimeLastHour();
  s = st_;
}

void Modem::resetStats() {
  memset(&st_, 0, sizeof(st_));
}
