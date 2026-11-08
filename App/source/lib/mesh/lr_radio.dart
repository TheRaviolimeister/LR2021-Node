import 'dart:convert';
import 'dart:typed_data';

import '../core/bytes.dart';

/// Eigenes, einfaches Protokoll für den 70-cm-Kanal (unverschlüsselt, mit Rufzeichen –
/// im Amateurfunk ist Verschlüsselung nicht erlaubt).
///
///   'L' 'R' | ver=1 | typ (1 Text, 2 Bake, 3 Bestätigung, 4 Dateistück, 5 Datei-Bestätigung) | absender u32 | id u32
///   | rufz_len u8 | rufzeichen | name_len u8 | name | nutzdaten
const int lrVersion = 1;

class LrType {
  static const text = 1, beacon = 2, ack = 3, file = 4, fileAck = 5;
}

class LrPacket {
  final int type, from, id;
  final String callsign, name;
  final Uint8List body;
  LrPacket(this.type, this.from, this.id, this.callsign, this.name, this.body);

  String get text => utf8.decode(body, allowMalformed: true);
  int get ackFor => body.length >= 4 ? Rd(body).u32() : 0;

  static LrPacket? parse(Uint8List raw) {
    if (raw.length < 13 || raw[0] != 0x4C || raw[1] != 0x52 || raw[2] != lrVersion) return null;
    try {
      final r = Rd(raw, 3);
      final t = r.u8();
      final from = r.u32();
      final id = r.u32();
      final cl = r.u8();
      final call = utf8.decode(r.bytes(cl), allowMalformed: true);
      final nl = r.remaining > 0 ? r.u8() : 0;
      final name = utf8.decode(r.bytes(nl), allowMalformed: true);
      return LrPacket(t, from, id, call, name, r.rest());
    } catch (_) {
      return null;
    }
  }

  static Uint8List build(int type, int from, int id, String callsign, String name, List<int> body) {
    final c = utf8.encode(callsign);
    final n = utf8.encode(name);
    final w = Wr()
      ..u8(0x4C)
      ..u8(0x52)
      ..u8(lrVersion)
      ..u8(type)
      ..u32(from)
      ..u32(id)
      ..u8(c.length)
      ..add(c)
      ..u8(n.length)
      ..add(n)
      ..add(body);
    return w.toBytes();
  }
}
