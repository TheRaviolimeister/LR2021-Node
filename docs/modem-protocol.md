# Modem protocol (Pi ↔ ESP32), version 1

For your own programs (Python, C, Rust, Android via the Pi …). The reference implementation is
`host/lrmodem.py`, the firmware side is `firmware/lr2021_modem/protocol.h`.

## Line
- Pi UART: **500000 baud** (the Orange Pi H618 UART generates this rate exactly), 8N1, no flow control.
  USB socket “COM”: **115200 baud**.
- Both interfaces understand the same commands. Events are sent to both.

## Frame
```
COBS( type | seq | payload … | crc_lo | crc_hi )  0x00
```
- **COBS** encoded, every `0x00` ends a frame. After interference the receiver resynchronises at the
  next `0x00`.
- **CRC16-CCITT** (polynomial 0x1021, initial value 0xFFFF, not inverted) over type, seq and payload.
- All numbers **little-endian**, structures packed (no padding).
- Payload at most 300 bytes.

| type | Meaning |
|---|---|
| 0x01–0x5F | command from the Pi, `seq` freely chosen (0–255) |
| 0x81–0xDF | response = command \| 0x80, same `seq`. Payload starts with `int16 status` |
| 0xE0–0xEF | event from the modem, `seq` counts independently |

## Commands

| Command | Payload → | Response data (after status) |
|---|---|---|
| 0x01 PING | – | u32 magic `0x444D524C` ("LRMD"), u8 protocol |
| 0x02 GET_INFO | – | InfoBlock |
| 0x03 GET_CONFIG | – | u8 modem (1 LoRa, 2 FSK), LoraCfg or FskCfg, Limits, u8 autorx |
| 0x10 SET_LORA | LoraCfg | on status −8: i16 RadioLib code |
| 0x11 SET_FSK | FskCfg | as above |
| 0x12 SET_LIMITS | Limits | – |
| 0x13 SAVE | – | – (store settings as power-on defaults) |
| 0x14 FACTORY | – | – (erase stored settings, restart) |
| 0x15 SET_AUTORX | u8 0/1 | – |
| 0x20 TX | u8 flags (bit0 = LBT), u16 tx_id, 1–255 bytes data | – (packet queued, max. 8). Result arrives as EVT_TX_DONE |
| 0x21 RX_START | – | – receive continuously, also after every transmission |
| 0x22 STANDBY | – | – |
| 0x23 SLEEP | – | – (any later command wakes the chip) |
| 0x24 CAD | – | u8 busy (LoRa only) |
| 0x25 GET_RSSI | – | i16 RSSI × 10 (only while receiving) |
| 0x30 GET_STATS | – | Stats |
| 0x31 RESET_STATS | – | – |
| 0x40 RESET_RADIO | – | – (re-initialise the LR2021) |
| 0x41 REBOOT | – | – |

## Events

| type | Content |
|---|---|
| 0xE0 BOOT | InfoBlock, after every start |
| 0xE1 RX | i16 RSSI×10, i16 SNR×10, i32 frequency error Hz, u8 flags (bit0 CRC error), u32 time ms, then the data |
| 0xE2 TX_DONE | u16 tx_id, i16 status, u32 airtime µs |
| 0xE4 LOG | u8 level (0 info, 1 warning, 2 error), UTF-8 text |

## Structures

```
LoraCfg  (16 B): u32 freq_hz, u32 bw_hz, u8 sf (5–12), u8 cr (5–8 = 4/5–4/8), u8 sync,
                 i8 power_dbm, u16 preamble, u8 flags, u8 implicit_len
                 flags: bit0 CRC, bit1 IQ inverted, bit2 implicit header,
                        bit3 force LDRO on, bit4 force LDRO off (otherwise automatic)
                 bw_hz: 7800 10400 15600 20800 31250 41670 62500 83340 101000 125000 203125
                        250000 406250 500000 812500 1000000

FskCfg   (32 B): u32 freq_hz, u32 bitrate_bps, u32 fdev_hz, u32 rxbw_hz, i8 power_dbm,
                 u16 preamble_bits, u8 sync_len (0–8), u8 sync[8], u8 crc_len (0–2),
                 u8 flags (bit0 whitening, bit1 fixed length), u8 shaping (0 off, 1 BT0.3,
                 2 BT0.5, 3 BT0.7, 4 BT1.0), u8 fixed_len

Limits    (5 B): u8 allow_mask (bit0 sub-GHz, bit1 2.4 GHz), i8 max_pwr_subghz,
                 i8 max_pwr_24, u16 duty_permille (0 = off)

InfoBlock(31 B): u8 proto, u8 fw_major, u8 fw_minor, u8 fw_patch, char role ('A'/'B'),
                 u8 band_id (1 HF, 2 LF), u8 radio_ok, u8 radio_state (0 off, 1 standby,
                 2 receive, 3 transmit, 4 sleep), u8 modem, u32 uptime_ms, u32 chip_id,
                 i16 init_code, i16 temp×10, u16 vbat_mv, u32 subghz_min_hz, u32 subghz_max_hz

Stats    (36 B): u32 rx_ok, rx_crc_err, tx_ok, tx_fail, tx_rejected, airtime_total_ms,
                 airtime_hour_ms, link_bad_frames, cad_busy
```

## Status values
0 OK · −1 unknown command · −2 wrong length · −3 invalid parameter · −4 busy ·
−5 band not enabled for transmitting · −6 power above limit · −7 airtime limit ·
−8 radio chip error (+ RadioLib code) · −9 wrong modulation · −10 channel busy ·
−11 radio chip not ready · −12 timeout

## Frequency ranges
- ESP32 A (Core2021-HF): 850–930 MHz and 2400–2500 MHz
- ESP32 B (Core2021-LF): 410–510 MHz and 2400–2500 MHz
