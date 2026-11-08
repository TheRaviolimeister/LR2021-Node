#include "link.h"

void HostLink::begin(uint32_t baud, int rxPin, int txPin) {
  port_.setRxBufferSize(2048);
  port_.setTxBufferSize(2048);
  if (rxPin >= 0) port_.begin(baud, SERIAL_8N1, rxPin, txPin);
  else port_.begin(baud);
}

void HostLink::poll(FrameHandler handler) {
  static uint8_t frame[MAX_FRAME];
  int budget = 512;                              // nicht ewig in einer Schleife hängen
  while (port_.available() && budget-- > 0) {
    uint8_t b = (uint8_t)port_.read();
    if (b != 0) {
      if (rxLen_ < sizeof(rx_)) rx_[rxLen_++] = b;
      else overflow_ = true;
      continue;
    }
    // Rahmenende
    if (rxLen_ == 0) continue;                   // leere Rahmen (z. B. Sync-Nullen) ignorieren
    uint32_t n = overflow_ ? 0 : cobs_decode(rx_, rxLen_, frame, sizeof(frame));
    rxLen_ = 0;
    overflow_ = false;
    if (n < 4) { bad_++; continue; }
    uint16_t crc = (uint16_t)frame[n - 2] | ((uint16_t)frame[n - 1] << 8);
    if (crc16_ccitt(frame, n - 2) != crc) { bad_++; continue; }
    lastRx_ = millis() | 1;
    handler(*this, frame[0], frame[1], frame + 2, (uint16_t)(n - 4));
  }
}

bool HostLink::send(uint8_t type, uint8_t seq, const uint8_t* data, uint16_t len) {
  static uint8_t raw[MAX_FRAME];
  static uint8_t enc[MAX_ENCODED];
  if (len > MAX_PAYLOAD) return false;
  raw[0] = type;
  raw[1] = seq;
  if (len) memcpy(raw + 2, data, len);
  uint16_t crc = crc16_ccitt(raw, len + 2);
  raw[len + 2] = (uint8_t)crc;
  raw[len + 3] = (uint8_t)(crc >> 8);
  uint32_t m = cobs_encode(raw, len + 4, enc);
  enc[m++] = 0;
  // nie blockieren: wenn der Puffer voll ist (z. B. niemand liest USB), Rahmen verwerfen
  if ((uint32_t)port_.availableForWrite() < m) return false;
  port_.write(enc, m);
  return true;
}

bool HostLink::sendResponse(uint8_t cmd, uint8_t seq, int16_t status, const void* data, uint16_t len) {
  uint8_t buf[MAX_PAYLOAD];
  if (len + 2 > MAX_PAYLOAD) len = MAX_PAYLOAD - 2;
  buf[0] = (uint8_t)status;
  buf[1] = (uint8_t)((uint16_t)status >> 8);
  if (len && data) memcpy(buf + 2, data, len);
  return send(cmd | 0x80, seq, buf, len + 2);
}
