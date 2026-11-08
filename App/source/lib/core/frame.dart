import 'dart:typed_data';

/// Rahmen der Modem-Firmware: COBS( typ | seq | daten | crc_lo | crc_hi ) 0x00
/// CRC16-CCITT, Polynom 0x1021, Start 0xFFFF.

int crc16(List<int> data, [int crc = 0xFFFF]) {
  for (final b in data) {
    crc ^= (b & 0xFF) << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

Uint8List cobsEncode(List<int> data) {
  final out = <int>[0];
  var codePos = 0;
  var code = 1;
  for (final b in data) {
    if (b == 0) {
      out[codePos] = code;
      codePos = out.length;
      code = 1;
      out.add(0);
    } else {
      out.add(b);
      code++;
      if (code == 0xFF) {
        out[codePos] = code;
        codePos = out.length;
        code = 1;
        out.add(0);
      }
    }
  }
  out[codePos] = code;
  return Uint8List.fromList(out);
}

Uint8List cobsDecode(List<int> data) {
  final out = <int>[];
  var i = 0;
  while (i < data.length) {
    final code = data[i];
    if (code == 0) throw const FormatException('COBS: Null im Rahmen');
    i++;
    final end = i + code - 1;
    if (end > data.length) throw const FormatException('COBS: Rahmen zu kurz');
    out.addAll(data.sublist(i, end));
    i = end;
    if (code != 0xFF && i < data.length) out.add(0);
  }
  return Uint8List.fromList(out);
}

class Frame {
  final int type;
  final int seq;
  final Uint8List payload;
  const Frame(this.type, this.seq, this.payload);
}

Uint8List buildFrame(int type, int seq, List<int> payload) {
  final raw = <int>[type & 0xFF, seq & 0xFF, ...payload];
  final c = crc16(raw);
  raw.add(c & 0xFF);
  raw.add((c >> 8) & 0xFF);
  final enc = cobsEncode(raw);
  return Uint8List.fromList([...enc, 0]);
}

Frame parseFrame(List<int> encoded) {
  final raw = cobsDecode(encoded);
  if (raw.length < 4) throw const FormatException('Rahmen zu kurz');
  final n = raw.length;
  final got = raw[n - 2] | (raw[n - 1] << 8);
  if (got != crc16(raw.sublist(0, n - 2))) throw const FormatException('CRC falsch');
  return Frame(raw[0], raw[1], Uint8List.fromList(raw.sublist(2, n - 2)));
}

/// Sammelt Bytes und liefert vollständige Rahmen. Text (z. B. Bootmeldungen des ESP32)
/// zwischen den Rahmen wird verworfen und als fehlerhafter Rahmen gezählt.
class FrameDecoder {
  final List<int> _buf = <int>[];
  int bad = 0;

  List<Frame> feed(List<int> chunk) {
    final out = <Frame>[];
    for (final b in chunk) {
      if (b == 0) {
        if (_buf.isNotEmpty) {
          try {
            out.add(parseFrame(_buf));
          } catch (_) {
            bad++;
          }
          _buf.clear();
        }
      } else {
        _buf.add(b);
        if (_buf.length > 1024) {
          _buf.clear();
          bad++;
        }
      }
    }
    return out;
  }
}
