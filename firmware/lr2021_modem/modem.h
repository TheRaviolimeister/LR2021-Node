// Funk-Steuerung: kapselt den LR2021 (RadioLib) als Zustandsautomat
#pragma once
#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>
#include "config.h"
#include "protocol.h"

// Rückmeldung an die Hauptschleife (Ereignisse an den Pi)
typedef void (*EventSink)(uint8_t type, const uint8_t* data, uint16_t len);

struct TxItem {
  uint16_t id;
  uint8_t  flags;
  uint8_t  len;
  uint8_t  tries;
  uint32_t notBefore;   // millis(), für LBT-Wartezeit
  uint8_t  data[RADIOLIB_LR2021_MAX_PACKET_LENGTH];
};

class Modem {
public:
  void begin(EventSink sink);
  void loop();

  // Befehle (geben ST_* zurück; radiolibCode wird bei ST_RADIO_ERROR gefüllt)
  int16_t setLora(const LoraCfg& c, int16_t* radiolibCode);
  int16_t setFsk(const FskCfg& c, int16_t* radiolibCode);
  int16_t setLimits(const Limits& l);
  int16_t queueTx(uint16_t id, uint8_t flags, const uint8_t* data, uint16_t len);
  int16_t startRx(int16_t* radiolibCode);
  int16_t standby();
  int16_t sleep();
  int16_t cad(uint8_t* busy, int16_t* radiolibCode);
  int16_t rssi(int16_t* rssi10);
  int16_t resetRadio(int16_t* radiolibCode);

  void fillInfo(InfoBlock& i);
  void fillStats(Stats& s);
  void resetStats();

  // gespeicherte Einstellungen
  void save();
  void factoryReset();
  void setAutoRx(bool on) { autoRx_ = on; }

  // aktuelle Werte (für GET_CONFIG)
  uint8_t modemType() const { return modem_; }
  const LoraCfg& lora() const { return lora_; }
  const FskCfg& fsk() const { return fsk_; }
  const Limits& limits() const { return lim_; }
  bool autoRx() const { return autoRx_; }
  uint8_t state() const { return rs_; }
  bool radioOk() const { return radioOk_; }

private:
  int16_t applyConfig(int16_t* radiolibCode);
  int16_t checkFreq(uint32_t f, bool* is24) const;
  int16_t checkTxAllowed(uint16_t len, uint32_t* toaUs);
  void startNextTx();
  void handleIrq();
  void handleRx();
  void finishTx(int16_t status);
  void wake();
  void drainRxFifo();
  void addAirtime(uint32_t ms);
  uint32_t airtimeLastHour();
  void loadDefaults();
  void load();
  void measureHealth();
  void log(uint8_t level, const char* fmt, ...);
  void led(uint8_t r, uint8_t g, uint8_t b);

  EventSink sink_ = nullptr;
  uint8_t modem_ = MODEM_LORA;
  LoraCfg lora_{};
  FskCfg fsk_{};
  Limits lim_{};
  bool autoRx_ = false;

  bool radioOk_ = false;
  int16_t initCode_ = 0;
  uint8_t rs_ = RS_OFF;
  bool rxWanted_ = false;       // nach TX wieder in den Empfang

  TxItem q_[TX_QUEUE_LEN];
  uint8_t qHead_ = 0, qCount_ = 0;
  TxItem cur_{};
  uint32_t txStart_ = 0, txToaUs_ = 0;

  uint16_t minuteAir_[60] = {0};   // Sendezeit in ms je Minute (Ringpuffer, 1 Stunde)
  uint32_t minuteStamp_ = 0;
  uint8_t minuteIdx_ = 0;

  Stats st_{};
  int16_t temp10_ = 0;
  uint16_t vbatMv_ = 0;
  uint32_t ledOffAt_ = 0;
};

extern Modem modem;
