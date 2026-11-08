import 'dart:typed_data';

/// AES-128/256, nur Verschlüsselung eines Blocks (für CTR reicht das).
final List<int> _sbox = _makeSbox();
const List<int> _rcon = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36, 0x6C, 0xD8, 0xAB, 0x4D];

int _rotl8(int x, int n) => ((x << n) | (x >> (8 - n))) & 0xFF;

List<int> _makeSbox() {
  final s = List<int>.filled(256, 0);
  var p = 1, q = 1;
  while (true) {
    p = (p ^ ((p << 1) & 0xFF) ^ ((p & 0x80) != 0 ? 0x1B : 0)) & 0xFF;
    q ^= q << 1;
    q ^= q << 2;
    q ^= q << 4;
    q &= 0xFF;
    if ((q & 0x80) != 0) q ^= 0x09;
    final x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4);
    s[p] = (x ^ 0x63) & 0xFF;
    if (p == 1) break;
  }
  s[0] = 0x63;
  return s;
}

int _xtime(int a) => (a & 0x80) != 0 ? ((a << 1) ^ 0x1B) & 0xFF : (a << 1) & 0xFF;

class Aes {
  late final int _nr;
  late final List<List<int>> _rk;

  Aes(List<int> key) {
    if (key.length != 16 && key.length != 32) {
      throw ArgumentError('AES-Schlüssel muss 16 oder 32 Byte lang sein');
    }
    final nk = key.length ~/ 4;
    _nr = nk + 6;
    final w = <List<int>>[for (var i = 0; i < nk; i++) key.sublist(4 * i, 4 * i + 4)];
    for (var i = nk; i < 4 * (_nr + 1); i++) {
      var t = List<int>.from(w[i - 1]);
      if (i % nk == 0) {
        t = [t[1], t[2], t[3], t[0]].map((b) => _sbox[b]).toList();
        t[0] ^= _rcon[i ~/ nk - 1];
      } else if (nk > 6 && i % nk == 4) {
        t = t.map((b) => _sbox[b]).toList();
      }
      w.add(List<int>.generate(4, (j) => w[i - nk][j] ^ t[j]));
    }
    _rk = List<List<int>>.generate(_nr + 1, (r) => [...w[4 * r], ...w[4 * r + 1], ...w[4 * r + 2], ...w[4 * r + 3]]);
  }

  Uint8List encryptBlock(List<int> block) {
    var s = List<int>.generate(16, (i) => block[i] ^ _rk[0][i]);
    for (var r = 1; r <= _nr; r++) {
      s = s.map((b) => _sbox[b]).toList();
      final sh = List<int>.generate(16, (i) => s[(i + 4 * (i % 4)) % 16]);
      s = sh;
      if (r != _nr) {
        final t = <int>[];
        for (var c = 0; c < 4; c++) {
          final a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3];
          final x = a0 ^ a1 ^ a2 ^ a3;
          t.add(a0 ^ x ^ _xtime(a0 ^ a1));
          t.add(a1 ^ x ^ _xtime(a1 ^ a2));
          t.add(a2 ^ x ^ _xtime(a2 ^ a3));
          t.add(a3 ^ x ^ _xtime(a3 ^ a0));
        }
        s = t;
      }
      final rk = _rk[r];
      s = List<int>.generate(16, (i) => s[i] ^ rk[i]);
    }
    return Uint8List.fromList(s);
  }
}

/// AES-CTR wie in Meshtastic (Zähler big-endian über alle 16 Byte).
Uint8List aesCtr(List<int> key, List<int> nonce, List<int> data) {
  final aes = Aes(key);
  final ctr = Uint8List.fromList(nonce);
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    final ks = aes.encryptBlock(ctr);
    for (var j = 0; j < 16 && i + j < data.length; j++) {
      out[i + j] = data[i + j] ^ ks[j];
    }
    for (var j = 15; j >= 0; j--) {
      ctr[j] = (ctr[j] + 1) & 0xFF;
      if (ctr[j] != 0) break;
    }
  }
  return out;
}
