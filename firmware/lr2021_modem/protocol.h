// LR2021 Modem-Protokoll (Pi <-> ESP32)
//
// Jeder Rahmen auf der Leitung:   COBS( typ | seq | nutzdaten... | crc16_lo | crc16_hi ) 0x00
//   - COBS-kodiert, 0x00 trennt Rahmen. Damit kann der Empfänger sich jederzeit neu synchronisieren.
//   - CRC16-CCITT (Polynom 0x1021, Start 0xFFFF) über typ, seq und Nutzdaten.
//   - Alle Zahlen Little-Endian.
//
// Typen:
//   0x01..0x5F  Befehle vom Pi
//   0x81..0xDF  Antwort auf Befehl (= Befehl | 0x80), gleiche seq. Nutzdaten beginnen mit int16 status.
//   0xE0..0xEF  Ereignisse vom Modem (seq zählt eigenständig hoch)
#pragma once
#include <stdint.h>

#define PROTO_VERSION       1
#define PROTO_MAGIC         0x444D524CUL   // "LRMD"
#define MAX_PAYLOAD         300            // Nutzdaten ohne typ/seq/crc
#define MAX_FRAME           (MAX_PAYLOAD + 4)
#define MAX_ENCODED         (MAX_FRAME + MAX_FRAME / 254 + 2)

// Befehle
enum : uint8_t {
  CMD_PING          = 0x01,  // -> u32 magic, u8 proto
  CMD_GET_INFO      = 0x02,  // -> InfoBlock
  CMD_GET_CONFIG    = 0x03,  // -> u8 modem, LoraCfg|FskCfg, Limits, u8 autorx
  CMD_SET_LORA      = 0x10,  // LoraCfg
  CMD_SET_FSK       = 0x11,  // FskCfg
  CMD_SET_LIMITS    = 0x12,  // Limits
  CMD_SAVE          = 0x13,  // aktuelle Einstellungen als Startwerte speichern
  CMD_FACTORY       = 0x14,  // gespeicherte Werte löschen, Neustart
  CMD_SET_AUTORX    = 0x15,  // u8: nach dem Start sofort empfangen
  CMD_TX            = 0x20,  // u8 flags, u16 tx_id, daten  (flags bit0 = vorher Kanal prüfen / LBT)
  CMD_RX_START      = 0x21,  // dauerhaft empfangen
  CMD_STANDBY       = 0x22,
  CMD_SLEEP         = 0x23,
  CMD_CAD           = 0x24,  // -> u8 belegt
  CMD_GET_RSSI      = 0x25,  // -> i16 rssi*10 (nur im Empfang)
  CMD_GET_STATS     = 0x30,  // -> Stats
  CMD_RESET_STATS   = 0x31,
  CMD_RESET_RADIO   = 0x40,
  CMD_REBOOT        = 0x41,
};

// Ereignisse
enum : uint8_t {
  EVT_BOOT          = 0xE0,  // InfoBlock
  EVT_RX            = 0xE1,  // i16 rssi*10, i16 snr*10, i32 freq_err_hz, u8 flags(bit0 crc_fehler), u32 zeit_ms, daten
  EVT_TX_DONE       = 0xE2,  // u16 tx_id, i16 status, u32 sendezeit_us
  EVT_LOG           = 0xE4,  // u8 stufe (0 info, 1 warnung, 2 fehler), text
  EVT_ERROR         = 0xE5,  // i16 code, i16 radiolib_code
};

// Statuswerte in Antworten
enum : int16_t {
  ST_OK             = 0,
  ST_UNKNOWN_CMD    = -1,
  ST_BAD_LENGTH     = -2,
  ST_BAD_PARAM      = -3,
  ST_BUSY           = -4,    // TX-Warteschlange voll
  ST_TX_FORBIDDEN   = -5,    // Band zum Senden nicht freigegeben
  ST_POWER_LIMIT    = -6,
  ST_DUTY_LIMIT     = -7,
  ST_RADIO_ERROR    = -8,    // + i16 RadioLib-Fehlercode
  ST_WRONG_MODEM    = -9,
  ST_CHANNEL_BUSY   = -10,   // LBT: Kanal belegt
  ST_NOT_READY      = -11,   // Funkchip nicht initialisiert
  ST_TIMEOUT        = -12,
};

enum : uint8_t { MODEM_LORA = 1, MODEM_FSK = 2 };
enum : uint8_t { RS_OFF = 0, RS_STANDBY = 1, RS_RX = 2, RS_TX = 3, RS_SLEEP = 4 };

#pragma pack(push, 1)
struct LoraCfg {
  uint32_t freq_hz;
  uint32_t bw_hz;          // 7800 … 1000000, gültige LoRa-Bandbreiten
  uint8_t  sf;             // 5 … 12
  uint8_t  cr;             // 5 … 8  (4/5 … 4/8)
  uint8_t  sync;           // LoRa-Syncword, z. B. 0x12 privat, 0x2B Meshtastic
  int8_t   power_dbm;
  uint16_t preamble;       // Symbole
  uint8_t  flags;          // bit0 CRC an, bit1 IQ invertiert, bit2 implizierter Header,
                           // bit3 LDRO erzwingen an, bit4 LDRO erzwingen aus
  uint8_t  implicit_len;   // Länge bei implizitem Header
};
struct FskCfg {
  uint32_t freq_hz;
  uint32_t bitrate_bps;
  uint32_t fdev_hz;
  uint32_t rxbw_hz;
  int8_t   power_dbm;
  uint16_t preamble_bits;
  uint8_t  sync_len;       // 0 … 8
  uint8_t  sync[8];
  uint8_t  crc_len;        // 0, 1 oder 2
  uint8_t  flags;          // bit0 Whitening, bit1 feste Länge (sonst variabel)
  uint8_t  shaping;        // 0 aus, 1 BT0.3, 2 BT0.5, 3 BT0.7, 4 BT1.0
  uint8_t  fixed_len;      // bei fester Länge
};
struct Limits {
  uint8_t  allow_mask;     // bit0 Sub-GHz senden, bit1 2,4 GHz senden
  int8_t   max_pwr_subghz;
  int8_t   max_pwr_24;
  uint16_t duty_permille;  // Sendezeit pro Stunde in Promille, 0 = aus
};
struct InfoBlock {
  uint8_t  proto;
  uint8_t  fw_major, fw_minor, fw_patch;
  char     role;           // 'A' oder 'B'
  uint8_t  band_id;        // 1 HF (868), 2 LF (433)
  uint8_t  radio_ok;       // 1 = LR2021 antwortet
  uint8_t  radio_state;    // RS_*
  uint8_t  modem;          // MODEM_*
  uint32_t uptime_ms;
  uint32_t chip_id;        // untere 32 Bit der MAC
  int16_t  init_code;      // RadioLib-Code der Initialisierung
  int16_t  temp_c10;       // Chiptemperatur * 10
  uint16_t vbat_mv;        // Versorgung am LR2021
  uint32_t subghz_min_hz, subghz_max_hz;
};
struct Stats {
  uint32_t rx_ok;
  uint32_t rx_crc_err;
  uint32_t tx_ok;
  uint32_t tx_fail;
  uint32_t tx_rejected;
  uint32_t airtime_total_ms;
  uint32_t airtime_hour_ms;
  uint32_t link_bad_frames;
  uint32_t cad_busy;
};
#pragma pack(pop)

// ---- Hilfsfunktionen (header-only, auch für native Tests nutzbar) ----
static inline uint16_t crc16_ccitt(const uint8_t* d, uint32_t n, uint16_t crc = 0xFFFF) {
  for (uint32_t i = 0; i < n; i++) {
    crc ^= (uint16_t)d[i] << 8;
    for (int b = 0; b < 8; b++) crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
  }
  return crc;
}

// COBS-Kodierung. out muss mindestens n + n/254 + 1 Bytes haben. Gibt Länge zurück (ohne 0x00).
static inline uint32_t cobs_encode(const uint8_t* in, uint32_t n, uint8_t* out) {
  uint32_t r = 0, w = 1, code_pos = 0;
  uint8_t code = 1;
  while (r < n) {
    if (in[r] == 0) {
      out[code_pos] = code; code_pos = w++; code = 1;
    } else {
      out[w++] = in[r]; code++;
      if (code == 0xFF) { out[code_pos] = code; code_pos = w++; code = 1; }
    }
    r++;
  }
  out[code_pos] = code;
  return w;
}

// COBS-Dekodierung. Gibt Länge zurück, 0 bei Fehler.
static inline uint32_t cobs_decode(const uint8_t* in, uint32_t n, uint8_t* out, uint32_t out_max) {
  uint32_t r = 0, w = 0;
  while (r < n) {
    uint8_t code = in[r++];
    if (code == 0) return 0;
    for (uint8_t i = 1; i < code; i++) {
      if (r >= n || w >= out_max) return 0;
      out[w++] = in[r++];
    }
    if (code != 0xFF && r < n) {
      if (w >= out_max) return 0;
      out[w++] = 0;
    }
  }
  return w;
}
