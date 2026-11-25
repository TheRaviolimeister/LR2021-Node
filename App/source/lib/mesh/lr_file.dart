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
  static const chunkSize24 = 200; // auf dem 2,4-GHz-Kanal (Paket bleibt auch mit 12 Zeichen Rufzeichen unter 255 B)
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
  static List<Uint8List> split(Uint8List data, String mime, String name, int xfer, {int size = LrFileProto.chunkSize}) {
    final first = (size - 2 - utf8.encode(mime).length - utf8.encode(name).length).clamp(40, size);
    final pieces = <List<int>>[];
    pieces.add(data.sublist(0, data.length < first ? data.length : first));
    for (var o = pieces.first.length; o < data.length; o += size) {
      pieces.add(data.sublist(o, o + size > data.length ? data.length : o + size));
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
  final List<int> missing; // höchstens 90 Indizes
  final int total; // wie viele Teile insgesamt fehlen (ältere Versionen senden das nicht: dann = missing.length)
  FileAck(this.xfer, this.done, this.missing, [int? total]) : total = total ?? missing.length;

  static FileAck? parse(Uint8List body) {
    try {
      final r = Rd(body);
      final xfer = r.u32();
      final done = r.u8() != 0;
      final n = r.u8();
      final m = [for (var i = 0; i < n && r.remaining >= 2; i++) r.u16()];
      final total = r.remaining >= 2 ? r.u16() : m.length;
      return FileAck(xfer, done, m, total < m.length ? m.length : total);
    } catch (_) {
      return null;
    }
  }

  /// xfer u32 | fertig u8 | n u8 | Indizes u16 × n | insgesamt fehlend u16 (angehängt, ältere Empfänger ignorieren es)
  static Uint8List build(int xfer, bool done, List<int> missing) {
    final m = missing.take(LrFileProto.maxMissingPerAck).toList();
    final w = Wr()
      ..u32(xfer)
      ..u8(done ? 1 : 0)
      ..u8(m.length);
    for (final i in m) {
      w.u16(i);
    }
    w.u16(missing.length.clamp(0, 0xFFFF));
    return w.toBytes();
  }
}

/// Ankündigung (Typ 6, auf dem normalen LR-Kanal): die Datei [xfer] folgt gleich auf einem schnellen Kanal.
///   xfer u32 | frequenz u32 | bandbreite u32 | sf u8 | cr u8 | anzahl u16 | gesamtgröße u32
/// Empfänger mit eingeschaltetem 2,4-GHz-Dateikanal wechseln dorthin und kommen nach einigen Sekunden Ruhe zurück.
/// Kommt dort keine Bestätigung, sendet der Absender die Datei auf dem normalen Kanal.
class FileOffer {
  final int xfer, freqHz, bwHz, sf, cr, count, size;
  FileOffer(this.xfer, this.freqHz, this.bwHz, this.sf, this.cr, this.count, this.size);

  Uint8List build() => (Wr()
        ..u32(xfer)
        ..u32(freqHz)
        ..u32(bwHz)
        ..u8(sf)
        ..u8(cr)
        ..u16(count)
        ..u32(size))
      .toBytes();

  static FileOffer? parse(Uint8List body) {
    try {
      final r = Rd(body);
      return FileOffer(r.u32(), r.u32(), r.u32(), r.u8(), r.u8(), r.u16(), r.u32());
    } catch (_) {
      return null;
    }
  }
}

/// Ankündigung (Typ 7, auf dem normalen LR-Kanal, mehrmals vor der Übertragung):
///   xfer u32 | gesamtgröße u32 | anzahl u16 | sendezeit_s u16 | mime_len u8 | mime | name_len u8 | name
/// Empfänger legen die Übertragung schon an (und können fehlende Teile melden, auch wenn kein einziges Teil ankam)
/// und halten für die angekündigte Zeit ihre eigenen Sendungen auf diesem Kanal zurück.
class FileAnnounce {
  final int xfer, size, count, airtimeS;
  final String mime, name;
  FileAnnounce(this.xfer, this.size, this.count, this.airtimeS, this.mime, this.name);

  Uint8List build() {
    final m = utf8.encode(mime.length > 40 ? mime.substring(0, 40) : mime);
    var n = utf8.encode(name);
    if (n.length > 60) n = n.sublist(n.length - 60);
    return (Wr()
          ..u32(xfer)
          ..u32(size)
          ..u16(count)
          ..u16(airtimeS.clamp(0, 0xFFFF))
          ..u8(m.length)
          ..add(m)
          ..u8(n.length)
          ..add(n))
        .toBytes();
  }

  static FileAnnounce? parse(Uint8List body) {
    try {
      final r = Rd(body);
      final xfer = r.u32(), size = r.u32(), count = r.u16(), air = r.u16();
      if (count == 0) return null;
      final mime = utf8.decode(r.bytes(r.u8()), allowMalformed: true);
      final name = utf8.decode(r.bytes(r.u8()), allowMalformed: true);
      return FileAnnounce(xfer, size, count, air, mime, name);
    } catch (_) {
      return null;
    }
  }
}

/// Sender: wie lange noch nachgesendet wird. Solange die Empfänger weniger fehlende Teile melden als vorher, geht es
/// weiter (bis die Datei vollständig ist); erst wenn mehrere Runden hintereinander nichts besser wird, oder nach sehr
/// vielen Runden, wird aufgegeben.
class ResendPolicy {
  final int maxStall, maxRounds;
  int rounds = 0, stall = 0;
  int? best;
  ResendPolicy({this.maxStall = 4, this.maxRounds = 80});

  void reset() {
    rounds = 0;
    stall = 0;
    best = null;
  }

  /// Eine Runde mit [missing] fehlenden Teilen (Summe über alle Empfänger) – weiter nachsenden?
  bool next(int missing) {
    rounds++;
    if (best == null || missing < best!) {
      best = missing;
      stall = 0;
    } else {
      stall++;
    }
    return missing > 0 && stall < maxStall && rounds <= maxRounds;
  }
}

/// Kanal frei? Merkt sich das Grundrauschen (RSSI-Werte, solange der Kanal ruhig ist) und meldet „belegt“, wenn der
/// aktuelle Pegel deutlich darüber liegt – so werden auch Fremdsender erkannt, die kein LoRa sind (CAD sieht nur LoRa).
class ChannelWatch {
  final double marginDb;
  final List<double> _quiet = [];
  ChannelWatch({this.marginDb = 12});

  double? get floor {
    if (_quiet.isEmpty) return null;
    final s = [..._quiet]..sort();
    return s[(s.length * 0.2).floor().clamp(0, s.length - 1)];
  }

  /// Messwert einordnen; true = Kanal belegt.
  bool busy(double rssi) {
    final f = floor;
    // ohne Vorwissen gilt nur ein wirklich starkes Signal als belegt
    final isBusy = f != null ? rssi > f + marginDb : rssi > -85;
    if (!isBusy) {
      _quiet.add(rssi);
      if (_quiet.length > 40) _quiet.removeAt(0);
    }
    return isBusy;
  }
}

/// Sendereihenfolge, wenn jedes Teil zweimal gesendet wird: die zweite Kopie folgt [lag] Teile später (zeitversetzt,
/// damit ein kurzer Einbruch nicht beide trifft). Das letzte Teil geht nur einmal ganz am Ende raus – die Empfänger
/// melden sich erst danach mit fehlenden Teilen.
List<int> fileSendOrder(int n, {int lag = 8}) {
  if (n < 2) return [for (var i = 0; i < n; i++) i];
  final out = <int>[];
  for (var i = 0; i < n - 1; i++) {
    out.add(i);
    if (i >= lag) out.add(i - lag);
  }
  for (var i = (n - 1 - lag).clamp(0, n - 1); i < n - 1; i++) {
    out.add(i);
  }
  out.add(n - 1);
  return out;
}

/// MIME-Typ aus dem Dateinamen.
String mimeFor(String name) {
  final e = name.toLowerCase().split('.').last;
  return switch (e) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'heic' => 'image/heic',
    'm4a' || 'aac' => 'audio/mp4',
    'mp3' => 'audio/mpeg',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    'mp4' || 'm4v' => 'video/mp4',
    'mov' => 'video/quicktime',
    '3gp' => 'video/3gpp',
    'webm' => 'video/webm',
    'txt' => 'text/plain',
    'pdf' => 'application/pdf',
    'gpx' => 'application/gpx+xml',
    'json' => 'application/json',
    _ => 'application/octet-stream',
  };
}
