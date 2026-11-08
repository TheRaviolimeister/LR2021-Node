import 'dart:convert';
import 'dart:typed_data';

import '../core/bytes.dart';

/// Datei- und Bildübertragung über LR-Funk (Typ 4 = Datenstück, Typ 5 = Empfangsbestätigung).
///
/// Datenstück (Nutzdaten eines LR-Pakets vom Typ 4):
///   xfer u32 | gesamtgröße u32 | index u16 | anzahl u16 | [nur Index 0: mime_len u8 | mime | name_len u8 | name] | daten
/// Bestätigung (Typ 5):
///   xfer u32 | fertig u8 | n u8 | fehlende Indizes u16 × n
/// Der Sender schickt alle Stücke, die Empfänger melden danach, was fehlt; nur das wird wiederholt.
class LrFileProto {
  static const chunkSize = 180;
  static const maxMissingPerAck = 90;
}

class FileChunk {
  final int xfer, size, index, count;
  final String? mime, name;
  final Uint8List data;
  FileChunk(this.xfer, this.size, this.index, this.count, this.data, {this.mime, this.name});

  static FileChunk? parse(Uint8List body) {
    try {
      final r = Rd(body);
      final xfer = r.u32(), size = r.u32(), idx = r.u16(), count = r.u16();
      if (count == 0 || idx >= count) return null;
      String? mime, name;
      if (idx == 0) {
        mime = utf8.decode(r.bytes(r.u8()), allowMalformed: true);
        name = utf8.decode(r.bytes(r.u8()), allowMalformed: true);
      }
      return FileChunk(xfer, size, idx, count, r.rest(), mime: mime, name: name);
    } catch (_) {
      return null;
    }
  }

  static Uint8List build(int xfer, int size, int idx, int count, List<int> data, {String mime = '', String name = ''}) {
    final w = Wr()
      ..u32(xfer)
      ..u32(size)
      ..u16(idx)
      ..u16(count);
    if (idx == 0) {
      final m = utf8.encode(mime.length > 40 ? mime.substring(0, 40) : mime);
      var n = utf8.encode(name);
      if (n.length > 60) n = n.sublist(n.length - 60);
      w
        ..u8(m.length)
        ..add(m)
        ..u8(n.length)
        ..add(n);
    }
    w.add(data);
    return w.toBytes();
  }

  /// Daten in Stücke teilen (Stück 0 ist kürzer, weil Name und Typ mitgehen).
  static List<Uint8List> split(Uint8List data, String mime, String name, int xfer) {
    final first = (LrFileProto.chunkSize - 2 - utf8.encode(mime).length - utf8.encode(name).length).clamp(40, LrFileProto.chunkSize);
    final pieces = <List<int>>[];
    pieces.add(data.sublist(0, data.length < first ? data.length : first));
    for (var o = pieces.first.length; o < data.length; o += LrFileProto.chunkSize) {
      pieces.add(data.sublist(o, o + LrFileProto.chunkSize > data.length ? data.length : o + LrFileProto.chunkSize));
    }
    final count = pieces.length;
    return [
      for (var i = 0; i < count; i++) build(xfer, data.length, i, count, pieces[i], mime: mime, name: name),
    ];
  }
}

class FileAck {
  final int xfer;
  final bool done;
  final List<int> missing;
  FileAck(this.xfer, this.done, this.missing);

  static FileAck? parse(Uint8List body) {
    try {
      final r = Rd(body);
      final xfer = r.u32();
      final done = r.u8() != 0;
      final n = r.u8();
      return FileAck(xfer, done, [for (var i = 0; i < n && r.remaining >= 2; i++) r.u16()]);
    } catch (_) {
      return null;
    }
  }

  static Uint8List build(int xfer, bool done, List<int> missing) {
    final m = missing.take(LrFileProto.maxMissingPerAck).toList();
    final w = Wr()
      ..u32(xfer)
      ..u8(done ? 1 : 0)
      ..u8(m.length);
    for (final i in m) {
      w.u16(i);
    }
    return w.toBytes();
  }
}

/// MIME-Typ aus dem Dateinamen.
String mimeFor(String name) {
  final e = name.toLowerCase().split('.').last;
  return switch (e) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'txt' => 'text/plain',
    'pdf' => 'application/pdf',
    'gpx' => 'application/gpx+xml',
    'json' => 'application/json',
    _ => 'application/octet-stream',
  };
}
