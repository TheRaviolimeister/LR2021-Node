#include "ota.h"
#include <esp_partition.h>
#include <mbedtls/sha256.h>
#include <stdio.h>

Ota ota;

// Aufbau des ESP-Programmkopfs (esp_image_header_t, 24 Bytes): [0] 0xE9, [12..13] chip_id, [23] hash_appended
static const uint8_t IMG_MAGIC = 0xE9;
static const uint16_t IMG_CHIP_ESP32S3 = 0x0009;
static const char ID_PATTERN[] = "LRMODEM fw ";
static const uint8_t ID_PATTERN_LEN = sizeof(ID_PATTERN) - 1;

int16_t Ota::begin(const uint8_t* d, uint16_t len, uint32_t* slotSize) {
  if (len != 4 + 32) return ST_BAD_LENGTH;
  abort();                                        // ein laufendes Update wird verworfen
  uint32_t size;
  memcpy(&size, d, 4);
  const esp_partition_t* p = esp_ota_get_next_update_partition(nullptr);
  if (!p) return ST_FLASH_ERROR;
  if (slotSize) *slotSize = p->size;
  if (size < 64 || size > p->size) return ST_IMAGE_INVALID;
  // Löschen geschieht abschnittsweise beim Schreiben (4-KB-Sektoren), damit die Schleife nie lange blockiert
  esp_err_t e = esp_ota_begin(p, OTA_WITH_SEQUENTIAL_WRITES, &handle_);
  if (e != ESP_OK) return ST_FLASH_ERROR;
  part_ = p;
  size_ = size;
  written_ = 0;
  lastLen_ = 0;
  memcpy(sha_, d + 4, 32);
  pm_ = 0;
  capturing_ = false;
  capLen_ = 0;
  idOwn_ = idOther_ = false;
  lastMs_ = millis();
  active_ = true;
  return ST_OK;
}

int16_t Ota::data(const uint8_t* d, uint16_t len, uint32_t* next) {
  if (next) *next = written_;
  if (!active_) return ST_NO_SESSION;
  if (len < 5 || len - 4 > OTA_CHUNK_MAX) return ST_BAD_LENGTH;
  uint32_t off;
  memcpy(&off, d, 4);
  uint16_t n = len - 4;
  const uint8_t* p = d + 4;
  lastMs_ = millis();
  if (off != written_) {
    // Wiederholung des letzten Blocks (Antwort ging verloren): schon geschrieben, nur bestätigen
    if (n == lastLen_ && written_ >= n && off == written_ - n) return ST_OK;
    return ST_BAD_PARAM;                          // Lücke oder falscher Offset: next nennt den erwarteten
  }
  if (written_ + n > size_) return ST_BAD_LENGTH;
  if (off == 0) {
    uint16_t chip = n >= 24 ? (uint16_t)(p[12] | (p[13] << 8)) : 0;
    if (n < 24 || p[0] != IMG_MAGIC || chip != IMG_CHIP_ESP32S3) {
      abort();
      return ST_IMAGE_INVALID;
    }
  }
  esp_err_t e = esp_ota_write(handle_, p, n);
  if (e != ESP_OK) {
    abort();
    return ST_FLASH_ERROR;
  }
  scan(p, n);
  written_ += n;
  lastLen_ = n;
  if (next) *next = written_;
  return ST_OK;
}

int16_t Ota::end(int32_t* espErr) {
  if (espErr) *espErr = 0;
  if (!active_) return ST_NO_SESSION;
  if (written_ != size_) { abort(); return ST_IMAGE_INVALID; }
  scanFinish();
  if (idOther_) { abort(); return ST_WRONG_ROLE; }
  if (!idOwn_) { abort(); return ST_IMAGE_INVALID; }  // Kennung fehlt oder Version zu alt

  // Prüfsumme über das, was tatsächlich im Flash steht
  static uint8_t buf[1024];
  uint8_t sum[32];
  mbedtls_sha256_context ctx;
  mbedtls_sha256_init(&ctx);
  mbedtls_sha256_starts(&ctx, 0);
  esp_err_t e = ESP_OK;
  for (uint32_t pos = 0; pos < size_; pos += sizeof(buf)) {
    uint32_t n = size_ - pos < sizeof(buf) ? size_ - pos : sizeof(buf);
    e = esp_partition_read(part_, pos, buf, n);
    if (e != ESP_OK) break;
    mbedtls_sha256_update(&ctx, buf, n);
    if ((pos & 0xFFFF) == 0) feedLoopWDT();
  }
  mbedtls_sha256_finish(&ctx, sum);
  mbedtls_sha256_free(&ctx);
  if (e != ESP_OK) { if (espErr) *espErr = e; abort(); return ST_FLASH_ERROR; }
  if (memcmp(sum, sha_, 32) != 0) { abort(); return ST_VERIFY_FAILED; }

  // esp_ota_end prüft das Programm (Kopf, Segmente, Prüfsumme, angehängter SHA-256) und gibt den Handle frei
  active_ = false;
  e = esp_ota_end(handle_);
  if (e != ESP_OK) {
    if (espErr) *espErr = e;
    return e == ESP_ERR_OTA_VALIDATE_FAILED ? ST_VERIFY_FAILED : ST_FLASH_ERROR;
  }
  e = esp_ota_set_boot_partition(part_);
  if (e != ESP_OK) {
    if (espErr) *espErr = e;
    return e == ESP_ERR_OTA_VALIDATE_FAILED ? ST_VERIFY_FAILED : ST_FLASH_ERROR;
  }
  return ST_OK;
}

void Ota::abort() {
  if (!active_) return;
  esp_ota_abort(handle_);
  active_ = false;
}

// Kennung im Programm suchen (Byte für Byte über alle Blöcke, unabhängig von Blockgrenzen).
// "LRMODEM fw " kommt nur am Anfang des Musters mit 'L' vor, daher genügt ein einfacher Neustart.
void Ota::scan(const uint8_t* p, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) {
    uint8_t c = p[i];
    if (capturing_) {
      if (c >= 0x20 && c < 0x7F && capLen_ < sizeof(cap_) - 1) { cap_[capLen_++] = (char)c; continue; }
      parseId();
    }
    if (c == (uint8_t)ID_PATTERN[pm_]) {
      if (++pm_ == ID_PATTERN_LEN) { pm_ = 0; capturing_ = true; capLen_ = 0; }
    } else {
      pm_ = (c == (uint8_t)ID_PATTERN[0]) ? 1 : 0;
    }
  }
}

void Ota::scanFinish() {
  if (capturing_) parseId();
}

void Ota::parseId() {
  capturing_ = false;
  cap_[capLen_] = 0;
  unsigned maj = 0, mi = 0, pat = 0;
  char role = 0;
  if (sscanf(cap_, "%u.%u.%u role %c", &maj, &mi, &pat, &role) != 4) return;   // z. B. das Suchmuster selbst
  if (role != 'A' && role != 'B') return;
  if (role != MODEM_ROLE_CHAR) { idOther_ = true; return; }
  if (maj < OTA_MIN_MAJOR || (maj == OTA_MIN_MAJOR && mi < OTA_MIN_MINOR)) return;   // zu alt: wird nicht angenommen
  idOwn_ = true;
}
