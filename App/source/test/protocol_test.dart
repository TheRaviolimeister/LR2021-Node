import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lr2021_app/core/bytes.dart';
import 'package:lr2021_app/core/frame.dart';
import 'package:lr2021_app/core/modem.dart';
import 'package:lr2021_app/mesh/aes.dart';
import 'package:lr2021_app/mesh/lr_radio.dart';
import 'package:lr2021_app/mesh/meshtastic.dart';

// Prüfwerte stammen aus der Python-Referenz (host/lrmodem.py, host/meshtastic.py).
void main() {
  test('AES-128 FIPS-197', () {
    final out = Aes(unhex('000102030405060708090a0b0c0d0e0f')).encryptBlock(unhex('00112233445566778899aabbccddeeff'));
    expect(hex(out), '69c4e0d86a7b0430d8cdb78070b4c55a');
  });

  test('Rahmen wie Python', () {
    final f = buildFrame(0x20, 7, [0, 1, 0, 0x00, 0x11, 0x00]);
    expect(hex(f), '03200702010102110301c900');
    final d = FrameDecoder().feed(f);
    expect(d.length, 1);
    expect(d.first.type, 0x20);
    expect(d.first.seq, 7);
    expect(hex(d.first.payload), '000100001100');
  });

  test('LoRa-Konfiguration 16 Byte', () {
    final c = LoraCfg(freqHz: 869525000, bwHz: 250000, sf: 11, cr: 5, sync: 0x2B, powerDbm: 14, preamble: 16);
    expect(c.encode().length, 16);
    final r = LoraCfg.read(Rd(c.encode()));
    expect(r.freqHz, 869525000);
    expect(r.sync, 0x2B);
    expect(c.airtimeMs(30).round(), inInclusiveRange(400, 500));
  });

  test('Meshtastic-Text bauen wie Python', () {
    final ch = MtChannel('LongFast', 'AQ==');
    expect(ch.hash, 8);
    final p = buildMtPacket(
        from: 0x4C528428, id: 0x12345678, channel: ch, port: Port.text, payload: utf8.encode('Hallo Mesh äö'), hopLimit: 3);
    expect(hex(p), 'ffffffff2884524c78563412630800283b7b55e06e3f71899e92af0efd8bc304395646');
  });

  test('Meshtastic-Visitenkarte bauen wie Python', () {
    final p = buildMtPacket(
        from: 0x4C528428,
        id: 0x0BADBEEF,
        channel: MtChannel('LongFast', 'AQ=='),
        port: Port.nodeinfo,
        payload: userPayload(0x4C528428, 'LR2021 Prototyp', 'LR21'));
    expect(hex(p),
        'ffffffff2884524cefbead0b630800286130c17422016b887b9729054a6ddc63a51624e4e6f0541933d3f92103dfba9806f1917c52ff494111');
  });

  test('Empfangenes Paket entschlüsseln', () {
    final raw = unhex('ffffffff96fcc8322eee9b5ae7080096bbf91f527bf36583d26d8d35bceb8ed644f5b230387fe782459be258b8b8f0f57ca2d76c0591818706b4afba34e5a7f52616fbf447c9e938690ac60126b422dc2907407749a4dc166d4319b871c894e6507ca0a147078cee6677aaf836814580f05a4d5c0ddb9063cf0b0b9e91b37f0a39879dac46380e6a4cf5bdb04ece76a0e96c5acb9c3c6d3e555a8d7b30a1e50a8ee32a8d1402567396');
    final p = MtPacket.parse(raw)!;
    expect(nodeIdStr(p.from), '!32c8fc96');
    expect(p.decrypt([MtChannel('LongFast', 'AQ==')]), isTrue);
    expect(p.port, Port.text);
    expect((p.app['text'] as String).endsWith(' Test'), isTrue);
  });

  test('LR-Funk hin und zurück', () {
    final b = LrPacket.build(LrType.text, 0x4C528428, 42, 'DO1ABC', 'Prototyp', utf8.encode('Hallo 70 cm'));
    final p = LrPacket.parse(Uint8List.fromList(b))!;
    expect(p.callsign, 'DO1ABC');
    expect(p.text, 'Hallo 70 cm');
    expect(p.id, 42);
  });

  test('Kanal-Link lesen und bauen', () {
    final l = parseChannelLink('https://meshtastic.org/e/#CgMSAQESBggBQANIAQ')!;
    expect(l.channels.length, 1);
    expect(l.channels.first.name, 'LongFast');
    expect(l.channels.first.pskB64, 'AQ==');
    final link = buildChannelLink([MtChannel('LongFast', 'AQ=='), MtChannel('Privat1', 'AAECAwQFBgcICQoLDA0ODw==')]);
    final back = parseChannelLink(link)!;
    expect(back.channels.map((c) => c.name).toList(), ['LongFast', 'Privat1']);
    expect(back.channels[1].pskB64, 'AAECAwQFBgcICQoLDA0ODw==');
  });
}
