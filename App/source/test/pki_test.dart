import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lr2021_app/geo/compass.dart';
import 'package:lr2021_app/mesh/meshtastic.dart';
import 'package:lr2021_app/mesh/pki.dart';

Uint8List h(String s) {
  s = s.replaceAll(' ', '');
  return Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
}

String hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('X25519 nach RFC 7748 (Abschnitt 6.1)', () {
    final aPriv = h('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
    final bPriv = h('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb');
    final aPub = pkiPublicFromPrivate(aPriv);
    final bPub = pkiPublicFromPrivate(bPriv);
    expect(hx(aPub), '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
    expect(hx(bPub), 'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
    expect(hx(x25519(aPriv, bPub)), '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');
    expect(hx(x25519(bPriv, aPub)), '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');
  });

  test('AES-CCM nach RFC 3610 (Paket 1)', () {
    final key = h('C0C1C2C3C4C5C6C7C8C9CACBCCCDCECF');
    final nonce = h('00000003020100A0A1A2A3A4A5');
    final aad = h('0001020304050607');
    final plain = h('08090A0B0C0D0E0F101112131415161718191A1B1C1D1E');
    final (c, tag) = aesCcmEncrypt(key, nonce, plain, aad: aad);
    expect(hx(c), '588c979a61c663d2f066d0c2c0f989806d5f6b61dac384');
    expect(hx(tag), '17e8d12cfdf926e0');
    expect(aesCcmDecrypt(key, nonce, c, tag, aad: aad), plain);
    final bad = Uint8List.fromList(tag)..[0] ^= 1;
    expect(aesCcmDecrypt(key, nonce, c, bad, aad: aad), isNull);
  });

  test('Direktnachricht Ende-zu-Ende: bauen und lesen', () {
    final (aPriv, aPub) = pkiNewKeyPair();
    final (bPriv, bPub) = pkiNewKeyPair();
    final kA = pkiSharedKey(aPriv, bPub);
    final kB = pkiSharedKey(bPriv, aPub);
    expect(kA, kB);
    const from = 0x4C528428, to = 0x12345678;
    final raw = buildMtPacket(
      from: from,
      id: 0x1A2B3C4D,
      channel: MtChannel('LongFast', 'AQ=='),
      port: Port.text,
      payload: utf8.encode('Hallo DM'),
      dest: to,
      wantAck: true,
      pkiKey: kA,
    );
    expect(raw[13], 0); // Kanal-Hash 0 = PKI
    final p = MtPacket.parse(raw)!;
    expect(p.looksPki, isTrue);
    expect(p.decryptPki(kB), isTrue);
    expect(p.pki, isTrue);
    expect(p.port, Port.text);
    expect(p.app['text'], 'Hallo DM');
    // falscher Schlüssel
    final (cPriv, _) = pkiNewKeyPair();
    expect(MtPacket.parse(raw)!.decryptPki(pkiSharedKey(cPriv, aPub)), isFalse);
  });

  test('Visitenkarte enthält öffentlichen Schlüssel', () {
    final (_, pub) = pkiNewKeyPair();
    final d = decodeApp(Port.nodeinfo, userPayload(0x4C528428, 'Test', 'T', publicKey: pub));
    expect(d['pubkey'], pub);
  });

  test('Kompass: Richtung aus Schwerkraft und Magnetfeld', () {
    // flach, Oberkante nach Norden (Magnetfeld zeigt nach Norden und nach unten)
    expect(Compass.headingFrom([0, 0, 9.8], [0, 20, -40])!.$1, closeTo(0, 0.5));
    // flach, Oberkante nach Osten: Norden liegt dann links (-x)
    expect(Compass.headingFrom([0, 0, 9.8], [-20, 0, -40])!.$1, closeTo(90, 0.5));
    // aufrecht, Rückseite nach Norden
    expect(Compass.headingFrom([0, 9.8, 0], [0, -40, -20])!.$2, closeTo(0, 0.5));
  });
}
