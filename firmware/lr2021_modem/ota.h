// Firmware-Update über die Modem-Verbindung (in den freien App-Slot, danach Neustart)
#pragma once
#include <Arduino.h>
#include <esp_ota_ops.h>
#include "config.h"
#include "protocol.h"

class Ota {
public:
  bool active() const { return active_; }
  // Befehle (geben ST_* zurück)
  int16_t begin(const uint8_t* d, uint16_t len, uint32_t* slotSize);
  int16_t data(const uint8_t* d, uint16_t len, uint32_t* next);
  int16_t end(int32_t* espErr);
  void abort();
  bool idle() const { return active_ && millis() - lastMs_ > OTA_IDLE_TIMEOUT_MS; }
  uint32_t written() const { return written_; }
  uint32_t size() const { return size_; }

private:
  void scan(const uint8_t* p, uint32_t n);
  void scanFinish();
  void parseId();

  bool active_ = false;
  esp_ota_handle_t handle_ = 0;
  const esp_partition_t* part_ = nullptr;
  uint32_t size_ = 0, written_ = 0, lastMs_ = 0;
  uint16_t lastLen_ = 0;
  uint8_t sha_[32] = {0};
  // Suche nach der Kennung "LRMODEM fw x.y.z role R" im empfangenen Programm
  uint8_t pm_ = 0;
  bool capturing_ = false;
  char cap_[33] = {0};
  uint8_t capLen_ = 0;
  bool idOwn_ = false, idOther_ = false;
};

extern Ota ota;
