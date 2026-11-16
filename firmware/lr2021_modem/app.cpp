// Hauptprogramm: nimmt Befehle vom Pi (UART1) und über USB (UART0) entgegen
#include <Arduino.h>
#include "config.h"
#include "protocol.h"
#include "link.h"
#include "modem.h"
#include "ota.h"
#include <esp_ota_ops.h>

#if defined(ARDUINO_USB_CDC_ON_BOOT) && ARDUINO_USB_CDC_ON_BOOT
#error "Bitte \"USB CDC On Boot: Disabled\" einstellen (Serial muss UART0 sein)"
#endif

static HostLink hostLink(Serial1);   // Orange Pi
static HostLink usbLink(Serial);     // USB-Buchse "COM" (zum Testen am PC)
static uint8_t evtSeq = 0;
// Kennung im Binary (z. B. mit "strings" prüfbar)
#define STR2(x) #x
#define STR(x) STR2(x)
static const char LRMODEM_ID[] =
  "LRMODEM fw " STR(FW_VERSION_MAJOR) "." STR(FW_VERSION_MINOR) "." STR(FW_VERSION_PATCH) " role " 
#if defined(MODEM_ROLE_A)
  "A (HF 868)";
#else
  "B (LF 433)";
#endif
static bool rebootPending = false;
static uint32_t rebootAt = 0;
static HostLink* otaLink = nullptr;  // Verbindung, über die das laufende Update kommt
static bool pendingVerify = false;   // erster Start nach einem Update: noch nicht bestätigt

// Rollback: Der Arduino-Kern soll eine neue Firmware nicht sofort beim Start als gültig markieren.
// Das geschieht hier erst, wenn ein gültiger Rahmen vom Pi/PC angekommen ist (Verbindung funktioniert).
// Kommt innerhalb von OTA_CONFIRM_MS keiner, startet der ESP32 wieder mit der vorherigen Firmware.
extern "C" bool verifyRollbackLater() { return true; }

// Ereignisse an alle Verbindungen
static void eventSink(uint8_t type, const uint8_t* data, uint16_t len) {
  uint8_t s = evtSeq++;
  hostLink.send(type, s, data, len);
  usbLink.send(type, s, data, len);
}

template <typename T>
static bool getStruct(const uint8_t* d, uint16_t len, T& out) {
  if (len != sizeof(T)) return false;
  memcpy(&out, d, sizeof(T));
  return true;
}

static void reply(HostLink& l, uint8_t cmd, uint8_t seq, int16_t st, const void* d = nullptr, uint16_t n = 0) {
  l.sendResponse(cmd, seq, st, d, n);
}

static void replyRadio(HostLink& l, uint8_t cmd, uint8_t seq, int16_t st, int16_t rc) {
  if (st == ST_RADIO_ERROR) reply(l, cmd, seq, st, &rc, 2);
  else reply(l, cmd, seq, st);
}

// nach einem fehlgeschlagenen/abgebrochenen Update den Funk wieder starten
static void otaCleanup() {
  if (!ota.active() && modem.suspended()) {
    modem.resume();
    otaLink = nullptr;
  }
}

// während eines Updates erlaubt: Abfragen, die den Funk nicht anfassen
static bool allowedDuringOta(uint8_t type) {
  switch (type) {
    case CMD_PING: case CMD_GET_INFO: case CMD_GET_CONFIG: case CMD_FE_GET: case CMD_GET_STATS:
    case CMD_RESET_STATS: case CMD_REBOOT:
    case CMD_OTA_BEGIN: case CMD_OTA_DATA: case CMD_OTA_END: case CMD_OTA_ABORT:
      return true;
    default:
      return false;
  }
}

static void handleFrame(HostLink& l, uint8_t type, uint8_t seq, const uint8_t* d, uint16_t len) {
  int16_t rc = 0;
  if (pendingVerify) {
    pendingVerify = false;
    esp_err_t e = esp_ota_mark_app_valid_cancel_rollback();
    modem.log(e == ESP_OK ? 0 : 1, "Neue Firmware bestaetigt (%s)", e == ESP_OK ? "ok" : esp_err_to_name(e));
  }
  if (type < 0x80 && ota.active() && !allowedDuringOta(type)) { reply(l, type, seq, ST_BUSY); return; }
  switch (type) {
    case CMD_PING: {
      uint8_t b[5];
      uint32_t m = PROTO_MAGIC;
      memcpy(b, &m, 4);
      b[4] = PROTO_VERSION;
      reply(l, type, seq, ST_OK, b, 5);
      break;
    }
    case CMD_GET_INFO: {
      InfoBlock i;
      modem.fillInfo(i);
      reply(l, type, seq, ST_OK, &i, sizeof(i));
      break;
    }
    case CMD_GET_CONFIG: {
      uint8_t b[1 + sizeof(FskCfg) + sizeof(Limits) + 1];
      uint16_t n = 0;
      b[n++] = modem.modemType();
      if (modem.modemType() == MODEM_FSK) { memcpy(b + n, &modem.fsk(), sizeof(FskCfg)); n += sizeof(FskCfg); }
      else { memcpy(b + n, &modem.lora(), sizeof(LoraCfg)); n += sizeof(LoraCfg); }
      memcpy(b + n, &modem.limits(), sizeof(Limits)); n += sizeof(Limits);
      b[n++] = modem.autoRx() ? 1 : 0;
      reply(l, type, seq, ST_OK, b, n);
      break;
    }
    case CMD_SET_LORA: {
      LoraCfg c;
      if (!getStruct(d, len, c)) { reply(l, type, seq, ST_BAD_LENGTH); break; }
      { int16_t st = modem.setLora(c, &rc); replyRadio(l, type, seq, st, rc); }
      break;
    }
    case CMD_SET_FSK: {
      FskCfg c;
      if (!getStruct(d, len, c)) { reply(l, type, seq, ST_BAD_LENGTH); break; }
      { int16_t st = modem.setFsk(c, &rc); replyRadio(l, type, seq, st, rc); }
      break;
    }
    case CMD_SET_LIMITS: {
      Limits c;
      if (!getStruct(d, len, c)) { reply(l, type, seq, ST_BAD_LENGTH); break; }
      reply(l, type, seq, modem.setLimits(c));
      break;
    }
    case CMD_SAVE:
      modem.save();
      reply(l, type, seq, ST_OK);
      break;
    case CMD_FACTORY:
      modem.factoryReset();
      reply(l, type, seq, ST_OK);
      rebootPending = true;
      rebootAt = millis() + 200;
      break;
    case CMD_SET_AUTORX:
      if (len != 1) { reply(l, type, seq, ST_BAD_LENGTH); break; }
      modem.setAutoRx(d[0] != 0);
      reply(l, type, seq, ST_OK);
      break;
    case CMD_FE_GET: {
      FeInfo f;
      modem.fillFe(f);
      reply(l, type, seq, ST_OK, &f, sizeof(f));
      break;
    }
    case CMD_FE_SET: {
      // 2 Bytes (mode, flags) wie in 1.1.0, optional dahinter FeCal (Kalibrierung)
      if (len != 2 && len != 2 + sizeof(FeCal)) { reply(l, type, seq, ST_BAD_LENGTH); break; }
      FeCal cal;
      if (len > 2) memcpy(&cal, d + 2, sizeof(cal));
      int16_t st = modem.setFe(d[0], d[1], len > 2 ? &cal : nullptr);
      FeInfo f;
      modem.fillFe(f);
      reply(l, type, seq, st, &f, sizeof(f));
      break;
    }
    case CMD_TX: {
      if (len < 4) { reply(l, type, seq, ST_BAD_LENGTH); break; }
      uint8_t flags = d[0];
      uint16_t id = (uint16_t)d[1] | ((uint16_t)d[2] << 8);
      reply(l, type, seq, modem.queueTx(id, flags, d + 3, len - 3));
      break;
    }
    case CMD_RX_START:
      { int16_t st = modem.startRx(&rc); replyRadio(l, type, seq, st, rc); }
      break;
    case CMD_STANDBY:
      reply(l, type, seq, modem.standby());
      break;
    case CMD_SLEEP:
      reply(l, type, seq, modem.sleep());
      break;
    case CMD_CAD: {
      uint8_t busy = 0;
      int16_t st = modem.cad(&busy, &rc);
      if (st == ST_OK) reply(l, type, seq, st, &busy, 1);
      else replyRadio(l, type, seq, st, rc);
      break;
    }
    case CMD_GET_RSSI: {
      int16_t r = 0;
      int16_t st = modem.rssi(&r);
      reply(l, type, seq, st, st == ST_OK ? &r : nullptr, st == ST_OK ? 2 : 0);
      break;
    }
    case CMD_GET_STATS: {
      Stats s;
      modem.fillStats(s);
      s.link_bad_frames = hostLink.badFrames() + usbLink.badFrames();
      reply(l, type, seq, ST_OK, &s, sizeof(s));
      break;
    }
    case CMD_RESET_STATS:
      modem.resetStats();
      reply(l, type, seq, ST_OK);
      break;
    case CMD_RESET_RADIO:
      { int16_t st = modem.resetRadio(&rc); replyRadio(l, type, seq, st, rc); }
      break;
    case CMD_REBOOT:
      ota.abort();
      reply(l, type, seq, ST_OK);
      rebootPending = true;
      rebootAt = millis() + 200;
      break;
    case CMD_OTA_BEGIN: {
      if (ota.active() && otaLink != &l) { reply(l, type, seq, ST_BUSY); break; }
      if (len != 36) { reply(l, type, seq, ST_BAD_LENGTH); break; }
      if (!ota.active()) {
        int16_t st = modem.suspend();             // Funk anhalten, Frontend schlafen legen
        if (st != ST_OK) { reply(l, type, seq, st); break; }
      }
      uint32_t slot = 0;
      int16_t st = ota.begin(d, len, &slot);
      uint8_t b[6];
      uint16_t mc = OTA_CHUNK_MAX;
      memcpy(b, &mc, 2);
      memcpy(b + 2, &slot, 4);
      if (st == ST_OK) {
        otaLink = &l;
        modem.log(0, "Firmware-Update: %lu Bytes in den App-Slot (%lu Bytes)", (unsigned long)ota.size(), (unsigned long)slot);
      }
      reply(l, type, seq, st, b, 6);
      otaCleanup();
      break;
    }
    case CMD_OTA_DATA: {
      if (ota.active() && otaLink != &l) { reply(l, type, seq, ST_BUSY); break; }
      uint32_t next = 0;
      int16_t st = ota.data(d, len, &next);
      reply(l, type, seq, st, &next, 4);
      if (st != ST_OK && !ota.active()) modem.log(2, "Firmware-Update abgebrochen (Status %d)", st);
      otaCleanup();
      break;
    }
    case CMD_OTA_END: {
      if (ota.active() && otaLink != &l) { reply(l, type, seq, ST_BUSY); break; }
      int32_t err = 0;
      int16_t st = ota.end(&err);
      if (st == ST_OK) {
        modem.log(0, "Firmware-Update geprueft, Neustart");
        reply(l, type, seq, st);
        rebootPending = true;
        rebootAt = millis() + 300;
      } else {
        if (st != ST_NO_SESSION) modem.log(2, "Firmware-Update fehlgeschlagen (Status %d, Fehler 0x%lX)", st, (unsigned long)err);
        if (st == ST_FLASH_ERROR || st == ST_VERIFY_FAILED) reply(l, type, seq, st, &err, 4);
        else reply(l, type, seq, st);
      }
      otaCleanup();
      break;
    }
    case CMD_OTA_ABORT:
      if (ota.active() && otaLink != &l) { reply(l, type, seq, ST_BUSY); break; }
      if (ota.active()) modem.log(1, "Firmware-Update abgebrochen");
      ota.abort();
      reply(l, type, seq, ST_OK);
      otaCleanup();
      break;
    default:
      // Antworten/Ereignisse, die zurückkommen, ignorieren; unbekannte Befehle melden
      if (type < 0x80) reply(l, type, seq, ST_UNKNOWN_CMD);
      break;
  }
}

void setup() {
  {
    const esp_partition_t* run = esp_ota_get_running_partition();
    esp_ota_img_states_t s;
    pendingVerify = run && esp_ota_get_state_partition(run, &s) == ESP_OK && s == ESP_OTA_IMG_PENDING_VERIFY;
  }
  usbLink.begin(USB_BAUD, -1, -1);
  hostLink.begin(HOST_BAUD, PIN_HOST_RX, PIN_HOST_TX);
  randomSeed(esp_random());
#ifdef LRMODEM_DIAG
  delay(1500);
  Serial.printf("\nDIAG %s\nDIAG Pins CS=%d IRQ=%d RST=%d BUSY=%d MISO=%d MOSI=%d SCK=%d\n", LRMODEM_ID,
                PIN_LR_CS, PIN_LR_IRQ, PIN_LR_RST, PIN_LR_BUSY, PIN_LR_MISO, PIN_LR_MOSI, PIN_LR_SCK);
  pinMode(PIN_LR_BUSY, INPUT);
  pinMode(PIN_LR_RST, OUTPUT);
  digitalWrite(PIN_LR_RST, LOW); delay(5);
  Serial.printf("DIAG RST low:  BUSY=%d IRQ=%d MISO=%d\n", digitalRead(PIN_LR_BUSY), digitalRead(PIN_LR_IRQ), digitalRead(PIN_LR_MISO));
  digitalWrite(PIN_LR_RST, HIGH);
  for (int t = 0; t <= 200; t += 20) {
    Serial.printf("DIAG +%3d ms: BUSY=%d\n", t, digitalRead(PIN_LR_BUSY));
    delay(20);
  }
  Serial.println("DIAG starte RadioLib ...");
#endif
  modem.begin(eventSink);
#ifdef LRMODEM_DIAG
  Serial.printf("\nDIAG RadioLib fertig, radio_ok=%d\n", modem.radioOk());
#endif            // kann bei Verdrahtungsfehlern einige Sekunden dauern
  InfoBlock i;
  modem.fillInfo(i);
  eventSink(EVT_BOOT, (const uint8_t*)&i, sizeof(i));
  uint8_t msg[64];
  msg[0] = 0;
  size_t n = strlen(LRMODEM_ID);
  if (n > sizeof(msg) - 1) n = sizeof(msg) - 1;
  memcpy(msg + 1, LRMODEM_ID, n);
  eventSink(EVT_LOG, msg, (uint16_t)(n + 1));
  {
    const esp_partition_t* run = esp_ota_get_running_partition();
    modem.log(0, "App-Slot %s%s", run ? run->label : "?", pendingVerify ? " (neu, wartet auf Bestaetigung)" : "");
  }
  enableLoopWDT();                   // ab hier: hängt die Schleife > 5 s, startet der ESP32 neu
}

void loop() {
  hostLink.poll(handleFrame);
  usbLink.poll(handleFrame);
  modem.loop();
  if (ota.idle()) {                  // Gegenstelle meldet sich nicht mehr: Update verwerfen, Funk wieder an
    ota.abort();
    modem.log(1, "Firmware-Update abgebrochen (keine Daten)");
    otaCleanup();
  }
  if (pendingVerify && millis() > OTA_CONFIRM_MS) {
    // neue Firmware hat keine Verbindung zustande gebracht -> zurück zur vorherigen
    pendingVerify = false;
    modem.log(2, "Neue Firmware nicht bestaetigt, zurueck zur vorherigen");
    Serial.flush();
    Serial1.flush();
    esp_ota_mark_app_invalid_rollback_and_reboot();   // kehrt nur bei Fehler zurück
  }
  if (rebootPending && (int32_t)(millis() - rebootAt) >= 0) {
    Serial.flush();
    Serial1.flush();
    ESP.restart();
  }
  delay(0);
}
