// Rahmen-Verbindung über eine serielle Schnittstelle (COBS + CRC16)
#pragma once
#include <Arduino.h>
#include "protocol.h"

class HostLink {
public:
  typedef void (*FrameHandler)(HostLink& link, uint8_t type, uint8_t seq, const uint8_t* data, uint16_t len);

  HostLink(HardwareSerial& port) : port_(port) {}
  void begin(uint32_t baud, int rxPin, int txPin);
  void poll(FrameHandler handler);              // eingehende Bytes verarbeiten
  bool send(uint8_t type, uint8_t seq, const uint8_t* data, uint16_t len);
  bool sendResponse(uint8_t cmd, uint8_t seq, int16_t status, const void* data = nullptr, uint16_t len = 0);
  uint32_t badFrames() const { return bad_; }
  bool active() const { return lastRx_ != 0; } // hat schon mal einen gültigen Rahmen geschickt

private:
  HardwareSerial& port_;
  uint8_t rx_[MAX_ENCODED];
  uint16_t rxLen_ = 0;
  bool overflow_ = false;
  uint32_t bad_ = 0;
  uint32_t lastRx_ = 0;
};
