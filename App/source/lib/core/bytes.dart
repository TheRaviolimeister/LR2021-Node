import 'dart:typed_data';

/// Little-Endian-Leser für die gepackten Strukturen der Modem-Firmware.
class Rd {
  final Uint8List d;
  final ByteData _b;
  int o;
  Rd(this.d, [this.o = 0]) : _b = ByteData.sublistView(d);

  int get remaining => d.length - o;
  int u8() => _b.getUint8(o++);
  int i8() => _b.getInt8(o++);
  int u16() {
    final v = _b.getUint16(o, Endian.little);
    o += 2;
    return v;
  }

  int i16() {
    final v = _b.getInt16(o, Endian.little);
    o += 2;
    return v;
  }

  int u32() {
    final v = _b.getUint32(o, Endian.little);
    o += 4;
    return v;
  }

  int i32() {
    final v = _b.getInt32(o, Endian.little);
    o += 4;
    return v;
  }

  double f32() {
    final v = _b.getFloat32(o, Endian.little);
    o += 4;
    return v;
  }

  Uint8List bytes(int n) {
    final v = Uint8List.fromList(d.sublist(o, o + n));
    o += n;
    return v;
  }

  Uint8List rest() => bytes(remaining);
}

/// Little-Endian-Schreiber.
class Wr {
  final List<int> _l = <int>[];
  void u8(int v) => _l.add(v & 0xFF);
  void i8(int v) => _l.add(v & 0xFF);
  void u16(int v) {
    _l.add(v & 0xFF);
    _l.add((v >> 8) & 0xFF);
  }

  void i16(int v) => u16(v & 0xFFFF);
  void u32(int v) {
    for (var i = 0; i < 4; i++) {
      _l.add((v >> (8 * i)) & 0xFF);
    }
  }

  void i32(int v) => u32(v & 0xFFFFFFFF);
  void f32(double v) {
    final b = ByteData(4)..setFloat32(0, v, Endian.little);
    _l.addAll(b.buffer.asUint8List());
  }

  void add(List<int> b) => _l.addAll(b);
  int get length => _l.length;
  Uint8List toBytes() => Uint8List.fromList(_l);
}

String hex(List<int> b, [String sep = '']) =>
    b.map((x) => (x & 0xFF).toRadixString(16).padLeft(2, '0')).join(sep);

Uint8List unhex(String s) {
  final c = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final out = Uint8List(c.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(c.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

String nodeIdStr(int n) => '!${(n & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';
