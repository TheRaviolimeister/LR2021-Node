import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'aes.dart';

/// Meshtastic-PKI (ab Firmware 2.5): Direktnachrichten sind Ende-zu-Ende verschlüsselt.
///   Schlüssel = SHA256(X25519(eigener privater Schlüssel, öffentlicher Schlüssel der Gegenstelle))
///   AES-256-CCM, Tag 8 Byte, Längenfeld L = 2 (Nonce 13 Byte), keine Zusatzdaten.
///   Nonce = Paket-ID (4, LE) | Zusatz-Nonce (4, LE) | Absender (4, LE) | 0
///   Nutzdaten auf Funk = Chiffrat | Tag (8) | Zusatz-Nonce (4, LE), Kanal-Hash im Kopf = 0.
/// Quelle: meshtastic/firmware src/mesh/CryptoEngine.cpp, aes-ccm.cpp, Router.cpp.
const pkiOverhead = 12;

// ---------------------------------------------------------------- X25519 (RFC 7748)
final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _a24 = BigInt.from(121665);

BigInt _decodeLE(List<int> b) {
  var r = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    r = (r << 8) | BigInt.from(b[i]);
  }
  return r;
}

Uint8List _encodeLE(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  final mask = BigInt.from(0xFF);
  for (var i = 0; i < 32; i++) {
    out[i] = (x & mask).toInt();
    x = x >> 8;
  }
  return out;
}

/// Privaten Schlüssel nach RFC 7748 „klemmen“.
Uint8List clampPrivate(List<int> k) {
  final c = Uint8List.fromList(k);
  c[0] &= 248;
  c[31] &= 127;
  c[31] |= 64;
  return c;
}

/// X25519(k, u) – Skalarmultiplikation auf Curve25519 (Montgomery-Leiter).
Uint8List x25519(List<int> scalar, List<int> uBytes) {
  final k = _decodeLE(clampPrivate(scalar));
  final ub = Uint8List.fromList(uBytes);
  ub[31] &= 127;
  final x1 = _decodeLE(ub) % _p;
  var x2 = BigInt.one, z2 = BigInt.zero, x3 = x1, z3 = BigInt.one;
  var swap = 0;
  for (var t = 254; t >= 0; t--) {
    final kt = ((k >> t) & BigInt.one).toInt();
    swap ^= kt;
    if (swap == 1) {
      final tx = x2;
      x2 = x3;
      x3 = tx;
      final tz = z2;
      z2 = z3;
      z3 = tz;
    }
    swap = kt;
    final a = (x2 + z2) % _p;
    final aa = (a * a) % _p;
    final b = (x2 - z2) % _p;
    final bb = (b * b) % _p;
    final e = (aa - bb) % _p;
    final c = (x3 + z3) % _p;
    final d = (x3 - z3) % _p;
    final da = (d * a) % _p;
    final cb = (c * b) % _p;
    final s1 = (da + cb) % _p;
    x3 = (s1 * s1) % _p;
    final s2 = (da - cb) % _p;
    z3 = (x1 * ((s2 * s2) % _p)) % _p;
    x2 = (aa * bb) % _p;
    z2 = (e * ((aa + (_a24 * e) % _p) % _p)) % _p;
  }
  if (swap == 1) {
    x2 = x3;
    z2 = z3;
  }
  final r = (x2 * z2.modPow(_p - BigInt.two, _p)) % _p;
  return _encodeLE(r);
}

final Uint8List _base = Uint8List(32)..[0] = 9;

/// Neues Schlüsselpaar (privat, öffentlich).
(Uint8List, Uint8List) pkiNewKeyPair() {
  final rnd = Random.secure();
  final priv = clampPrivate(List<int>.generate(32, (_) => rnd.nextInt(256)));
  return (priv, x25519(priv, _base));
}

Uint8List pkiPublicFromPrivate(List<int> priv) => x25519(priv, _base);

/// Gemeinsamer AES-Schlüssel mit einer Gegenstelle.
Uint8List pkiSharedKey(List<int> myPriv, List<int> peerPub) {
  final s = x25519(myPriv, peerPub);
  if (s.every((b) => b == 0)) throw ArgumentError('ungültiger öffentlicher Schlüssel');
  return Uint8List.fromList(crypto.sha256.convert(s).bytes);
}

// ---------------------------------------------------------------- AES-CCM (RFC 3610)
const _l = 2;

Uint8List _xor16(List<int> a, List<int> b) => Uint8List.fromList(List<int>.generate(16, (i) => a[i] ^ b[i]));

Uint8List _cbcMac(Aes aes, List<int> nonce13, int m, List<int> aad, List<int> plain) {
  final b0 = Uint8List(16);
  b0[0] = (aad.isNotEmpty ? 0x40 : 0) | (((m - 2) ~/ 2) << 3) | (_l - 1);
  b0.setRange(1, 14, nonce13);
  b0[14] = (plain.length >> 8) & 0xFF;
  b0[15] = plain.length & 0xFF;
  var x = aes.encryptBlock(b0);
  if (aad.isNotEmpty) {
    final a = <int>[(aad.length >> 8) & 0xFF, aad.length & 0xFF, ...aad];
    while (a.length % 16 != 0) {
      a.add(0);
    }
    for (var i = 0; i < a.length; i += 16) {
      x = aes.encryptBlock(_xor16(x, a.sublist(i, i + 16)));
    }
  }
  for (var i = 0; i < plain.length; i += 16) {
    final blk = List<int>.filled(16, 0);
    for (var j = 0; j < 16 && i + j < plain.length; j++) {
      blk[j] = plain[i + j];
    }
    x = aes.encryptBlock(_xor16(x, blk));
  }
  return Uint8List.sublistView(x, 0, m);
}

Uint8List _ctrBlock(Aes aes, List<int> nonce13, int i) {
  final a = Uint8List(16);
  a[0] = _l - 1;
  a.setRange(1, 14, nonce13);
  a[14] = (i >> 8) & 0xFF;
  a[15] = i & 0xFF;
  return aes.encryptBlock(a);
}

Uint8List _ctr(Aes aes, List<int> nonce13, List<int> data) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    final ks = _ctrBlock(aes, nonce13, i ~/ 16 + 1);
    for (var j = 0; j < 16 && i + j < data.length; j++) {
      out[i + j] = data[i + j] ^ ks[j];
    }
  }
  return out;
}

/// CCM verschlüsseln: (Chiffrat, Tag).
(Uint8List, Uint8List) aesCcmEncrypt(List<int> key, List<int> nonce13, List<int> plain, {int m = 8, List<int> aad = const []}) {
  final aes = Aes(key);
  final t = _cbcMac(aes, nonce13, m, aad, plain);
  final s0 = _ctrBlock(aes, nonce13, 0);
  final tag = Uint8List.fromList(List<int>.generate(m, (i) => t[i] ^ s0[i]));
  return (_ctr(aes, nonce13, plain), tag);
}

/// CCM entschlüsseln und prüfen. null = Tag falsch.
Uint8List? aesCcmDecrypt(List<int> key, List<int> nonce13, List<int> cipher, List<int> tag, {List<int> aad = const []}) {
  final aes = Aes(key);
  final plain = _ctr(aes, nonce13, cipher);
  final t = _cbcMac(aes, nonce13, tag.length, aad, plain);
  final s0 = _ctrBlock(aes, nonce13, 0);
  var diff = 0;
  for (var i = 0; i < tag.length; i++) {
    diff |= (t[i] ^ s0[i]) ^ tag[i];
  }
  return diff == 0 ? plain : null;
}

// ---------------------------------------------------------------- Meshtastic-Rahmen
Uint8List _nonce(int packetId, int from, int extra) {
  final n = Uint8List(13);
  final bd = ByteData.sublistView(n);
  bd.setUint32(0, packetId & 0xFFFFFFFF, Endian.little);
  bd.setUint32(4, extra & 0xFFFFFFFF, Endian.little);
  bd.setUint32(8, from & 0xFFFFFFFF, Endian.little);
  return n;
}

/// Daten (protobuf „Data“) für eine Direktnachricht verschlüsseln.
Uint8List pkiEncrypt(List<int> sharedKey, int packetId, int from, List<int> data, {int? extraNonce}) {
  final extra = extraNonce ?? Random.secure().nextInt(0x7FFFFFFF);
  final (c, tag) = aesCcmEncrypt(sharedKey, _nonce(packetId, from, extra), data);
  final out = BytesBuilder()
    ..add(c)
    ..add(tag);
  final ex = Uint8List(4);
  ByteData.sublistView(ex).setUint32(0, extra & 0xFFFFFFFF, Endian.little);
  out.add(ex);
  return out.toBytes();
}

/// Direktnachricht entschlüsseln. null = nicht für diesen Schlüssel / beschädigt.
Uint8List? pkiDecrypt(List<int> sharedKey, int packetId, int from, List<int> enc) {
  if (enc.length <= pkiOverhead) return null;
  final n = enc.length - pkiOverhead;
  final extra = ByteData.sublistView(Uint8List.fromList(enc.sublist(n + 8, n + 12))).getUint32(0, Endian.little);
  return aesCcmDecrypt(sharedKey, _nonce(packetId, from, extra), enc.sublist(0, n), enc.sublist(n, n + 8));
}
