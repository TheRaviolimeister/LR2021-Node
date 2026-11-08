# Transmit power, licence, Meshtastic

- Default: the legal maximum (ERC/REC 70-03) for each frequency and bandwidth, minus antenna gain above
  2.15 dBi; chip maximum 22 dBm sub-GHz, 12 dBm at 2.4 GHz.
- 869.4–869.65 MHz: 27 dBm ERP → 22 dBm at the chip; other 868 MHz sub-bands 14 dBm;
  433.05–434.79 MHz: 10 dBm.
- Licence switch (callsign required): full power on 70 cm / 13 cm. There Meshtastic runs unencrypted
  (empty PSK, channel hash from the name only), with `is_licensed` and the callsign in the node info;
  only unencrypted packets are relayed there. 868 MHz always stays encrypted.
- Per module: antenna gain, frequency correction (kHz), fixed Meshtastic frequency.
- Meshtastic presets: LongFast, MediumSlow, MediumFast, ShortSlow, ShortFast, LongModerate.
  Roles: client / client mute / router. Rebroadcast: all / own channels / known nodes / none.
  Position every 5 min–3 h, precision via `precision_bits`. Telemetry off / 15 / 30 / 60 min.
