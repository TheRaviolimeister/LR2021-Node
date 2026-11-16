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
| 0x16 FE_GET | – | FeInfo (868 MHz front end of the carrier board; ESP32 A, firmware ≥ 1.1.0) |
| 0x17 FE_SET | u8 lna_mode (0 automatic, 1 on, 2 off, 0xFF unchanged), u8 flags (bit0 save, bit1 calibration back to factory values), optionally FeCal (firmware ≥ 1.2.0) | FeInfo; status −11 if there is no front end, −3 if a value is out of range, −4 while a packet is being transmitted |
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
| 0x50 OTA_BEGIN | u32 size, u8 sha256[32] (of the application image) | u16 max_chunk (256), u32 slot_size |
| 0x51 OTA_DATA | u32 offset, 1–256 bytes | u32 next_offset (also returned with status −3) |
| 0x52 OTA_END | – | – on success, then restart after 0.3 s; with −15/−16: i32 esp_err |
| 0x53 OTA_ABORT | – | – |

Commands 0x50–0x53 exist from firmware 1.2.0 on, see [Firmware update over the modem link](#firmware-update-over-the-modem-link).

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

FeInfo   (21 B): u8 present, u8 lna_mode (0 automatic, 1 on, 2 off), u8 lna_on, u8 pa (transmitting
                 via the PA), i16 noise_on×10, i16 noise_off×10 (noise floor at the antenna with and
                 without LNA, dBm; 0 = not measured yet), i8 out_dbm (power at the connector after the
                 legal limit), i8 legal_dbm, i8 drive_dbm (LR2021 level), i8 out_max_dbm,
                 from firmware 1.2.0: i16 pa_gain×10, i16 filter_loss×10, i16 lna_gain×10,
                 i16 bypass_loss×10 (calibration in use, dB), u8 cal_flags (bit0 differs from the factory
                 values, bit1 stored in flash). Firmware 1.1.0 sends only the first 12 bytes.

FeCal     (8 B): i16 pa_gain×10, i16 filter_loss×10, i16 lna_gain×10, i16 bypass_loss×10 (dB × 10);
                 −32768 (0x8000) = leave this value unchanged
```

### 868 MHz front end (carrier board)

With the front end (detected at start-up), `power_dbm` in LoraCfg/FskCfg and `max_pwr_subghz` in
Limits mean the power at the antenna connector, up to `out_max_dbm` (30). The firmware converts it
into the LR2021 level (PA from 14 dBm, bypass below) and never exceeds the legal limit of the
frequency (27 dBm in 869.40–869.65 MHz, otherwise 14 dBm). RSSI values (RX event, GET_RSSI) refer
to the antenna connector, the gain of the LNA and the loss of the filter are taken out.

**Calibration (firmware ≥ 1.2.0).** The conversion uses four values: PA gain (factory value 26 dB),
plug-in filter loss (3 dB; 0 without a filter module, pins 2–4 bridged), LNA gain (16 dB) and bypass
loss (2 dB). Measured values are sent with FE_SET (2 bytes + FeCal, resolution 0.1 dB) and stored in
flash with flags bit0. Allowed ranges: PA 15.0–32.0, filter 0.0–8.0, LNA 5.0–22.0, bypass 0.0–6.0 dB.
The LR2021 level is rounded down, so the power at the connector never exceeds the target (according
to the calibration), the LR2021 level never exceeds +8 dBm (input limit of the SE2435L) and the legal
limit of the frequency is always applied first. With the factory values the result is identical to
firmware 1.1.0. A changed calibration re-initialises the LR2021 with the new level (like SET_LORA);
`FACTORY` also removes it. Wrong values change the real output power – only enter measured values.

## Status values
0 OK · −1 unknown command · −2 wrong length · −3 invalid parameter · −4 busy ·
−5 band not enabled for transmitting · −6 power above limit · −7 airtime limit ·
−8 radio chip error (+ RadioLib code) · −9 wrong modulation · −10 channel busy ·
−11 radio chip not ready · −12 timeout · −13 invalid firmware image (not an ESP32-S3 application, too
large, older than 1.2.0 or without the LR2021-Modem identifier) · −14 firmware for the other modem (A/B) ·
−15 verification failed (SHA-256 or image check) · −16 flash error (+ i32 esp_err) · −17 no update started

## Frequency ranges
- ESP32 A (Core2021-HF): 850–930 MHz and 2400–2500 MHz
- ESP32 B (Core2021-LF): 410–510 MHz and 2400–2500 MHz

## Firmware update over the modem link

From firmware 1.2.0 both modems can be updated over the same line that carries the protocol (Pi UART
or USB), so the ESP32 on the carrier board never needs a USB cable for an update. The new application
is written into the free application slot of the flash; the running firmware stays untouched until the
new one has been checked completely.

1. **OTA_BEGIN** with the size and the SHA-256 of the *application image* (`lr2021_modem.ino.bin`, or
   the part of the complete image `LR2021-Modem-A.bin` that starts at 0x10000; `lrmodem.py` extracts it).
   The modem stops transmitting and receiving (queued packets are dropped with an EVT_TX_DONE status
   −11, a packet that is just being transmitted is finished first: status −4, try again), puts the
   868 MHz front end to sleep and shows a violet LED. Status −13 if the size does not fit the slot.
2. **OTA_DATA** blocks of up to 256 bytes, strictly in order, starting at offset 0. The first block must
   contain at least the 24-byte image header (0xE9, chip ESP32-S3). Wait for each response before
   sending the next block. The response carries the next expected offset. A block with the wrong
   offset is refused with −3 and that offset; repeating the last block (lost response) is
   acknowledged without writing it twice.
3. **OTA_END**: the modem reads the slot back and compares its SHA-256 with the one from OTA_BEGIN,
   checks the identifier `LRMODEM fw x.y.z role A|B` inside the image (other role → −14, version
   older than 1.2.0 or no identifier → −13), lets ESP-IDF verify the image, sets it as boot partition,
   answers and restarts 0.3 s later.
4. After the restart the new firmware sends EVT_BOOT. It confirms itself with the **first valid frame**
   it receives (for example GET_INFO). If no frame arrives within 120 s, or the new firmware crashes
   before that, the ESP32 starts the previous firmware again (rollback). Check the version with GET_INFO.

During an update only PING, GET_INFO, GET_CONFIG, FE_GET, GET_STATS, RESET_STATS, REBOOT and the OTA
commands are accepted (others: −4), and only from the interface that started it. Without data for 30 s
the update is dropped and the radio continues as before; OTA_ABORT does the same immediately. Do not
send anything else to the modem during the update: the line is used strictly request/response.
