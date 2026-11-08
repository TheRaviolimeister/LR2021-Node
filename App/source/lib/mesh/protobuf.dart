import 'dart:convert';
import 'dart:typed_data';

/// Minimaler protobuf-Leser/-Schreiber (reicht für Meshtastic).
class PbField {
  final int field;
  final int wt;
  final int value; // varint, fixed32
  final Uint8List bytes; // length-delimited, fixed64
  const PbField(this.field, this.wt, this.value, this.bytes);

  String get str => utf8.decode(bytes, allowMalformed: true);
  int get sfixed32 => value >= 0x80000000 ? value - 0x100000000 : value;
  double get f32 => (ByteData(4)..setUint32(0, value, Endian.little)).getFloat32(0, Endian.little);
  int get int32 => value >= 0x80000000 && value <= 0xFFFFFFFF ? value - 0x100000000 : value;
}

final Uint8List _empty = Uint8List(0);

List<PbField> pbParse(List<int> b) {
  final out = <PbField>[];
  var i = 0;
  int varint() {
    var v = 0, s = 0;
    while (true) {
      if (i >= b.length) throw const FormatException('protobuf zu kurz');
      final c = b[i++];
      v |= (c & 0x7F) << s;
      if ((c & 0x80) == 0) return v;
      s += 7;
      if (s > 63) throw const FormatException('varint zu lang');
    }
  }

  while (i < b.length) {
    final key = varint();
    final f = key >> 3, wt = key & 7;
    if (f == 0) throw const FormatException('Feld 0');
    switch (wt) {
      case 0:
        out.add(PbField(f, wt, varint(), _empty));
        break;
      case 1:
        if (i + 8 > b.length) throw const FormatException('protobuf zu kurz');
        out.add(PbField(f, wt, 0, Uint8List.fromList(b.sublist(i, i + 8))));
        i += 8;
        break;
      case 2:
        final n = varint();
        if (n < 0 || i + n > b.length) throw const FormatException('protobuf zu kurz');
        out.add(PbField(f, wt, 0, Uint8List.fromList(b.sublist(i, i + n))));
        i += n;
        break;
      case 5:
        if (i + 4 > b.length) throw const FormatException('protobuf zu kurz');
        final v = b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);
        out.add(PbField(f, wt, v, _empty));
        i += 4;
        break;
      default:
        throw FormatException('unbekannter protobuf-Typ $wt');
    }
  }
  return out;
}

PbField? pbGet(List<PbField> l, int field) {
  for (final f in l) {
    if (f.field == field) return f;
  }
  return null;
}

class PbWriter {
  final List<int> _b = <int>[];
  void _varint(int n) {
    while (true) {
      final b = n & 0x7F;
      n = n >>> 7;
      if (n == 0) {
        _b.add(b);
        return;
      }
      _b.add(b | 0x80);
    }
  }

  void varint(int field, int v) {
    _varint(field << 3);
    _varint(v);
  }

  void bytes(int field, List<int> data) {
    _varint(field << 3 | 2);
    _varint(data.length);
    _b.addAll(data);
  }

  void string(int field, String s) => bytes(field, utf8.encode(s));

  void fixed32(int field, int v) {
    _varint(field << 3 | 5);
    for (var i = 0; i < 4; i++) {
      _b.add((v >> (8 * i)) & 0xFF);
    }
  }

  void float32(int field, double v) {
    final bd = ByteData(4)..setFloat32(0, v, Endian.little);
    fixed32(field, bd.getUint32(0, Endian.little));
  }

  Uint8List toBytes() => Uint8List.fromList(_b);
}
