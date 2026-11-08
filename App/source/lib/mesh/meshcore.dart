import 'dart:convert';
import 'dart:typed_data';

import '../core/bytes.dart';
import '../i18n.dart';

/// MeshCore (nur Mithören): Kopf lesen und Knoten-Ankündigungen (ADVERT) auswerten.
const mcPayloadNames = <int, String>{
  0: 'Anfrage', 1: 'Antwort', 2: 'Direktnachricht', 3: 'Bestätigung', 4: 'Ankündigung',
  5: 'Gruppentext', 6: 'Gruppendaten', 7: 'Anonyme Anfrage', 8: 'Pfad', 9: 'Trace', 10: 'Multipart',
  15: 'Roh',
};
const mcNodeTypes = <int, String>{1: 'Chat', 2: 'Repeater', 3: 'Raum', 4: 'Sensor'};

class McPacket {
  final int header;
  final List<int> path;
  final Uint8List payload;
  McPacket(this.header, this.path, this.payload);

  int get routeType => header & 3;
  int get payloadType => (header >> 2) & 0x0F;
  int get version => header >> 6;
  String get typeName => (mcPayloadNames[payloadType] != null ? tr(mcPayloadNames[payloadType]!) : null) ?? tr('Typ {0}', [payloadType]);
  bool get isFlood => routeType == 0 || routeType == 1;

  static McPacket? parse(Uint8List raw) {
    try {
      final r = Rd(raw);
      final h = r.u8();
      final rt = h & 3;
      if (rt == 0 || rt == 3) r.bytes(4); // Transport-Codes
      final pl = r.u8();
      if (pl > 64 || pl > r.remaining) return null;
      final path = r.bytes(pl).toList();
      return McPacket(h, path, r.rest());
    } catch (_) {
      return null;
    }
  }
}

class McAdvert {
  final Uint8List pubKey;
  final int timestamp;
  final int nodeType;
  final double? lat, lon;
  final String name;
  McAdvert(this.pubKey, this.timestamp, this.nodeType, this.lat, this.lon, this.name);

  String get keyPrefix => hex(pubKey.sublist(0, 4));
  String get typeName => (mcNodeTypes[nodeType] != null ? tr(mcNodeTypes[nodeType]!) : null) ?? tr('Knoten');

  static McAdvert? parse(McPacket p) {
    if (p.payloadType != 4 || p.payload.length < 101) return null;
    try {
      final r = Rd(p.payload);
      final key = r.bytes(32);
      final ts = r.u32();
      r.bytes(64); // Signatur
      if (r.remaining < 1) return McAdvert(key, ts, 0, null, null, '');
      final flags = r.u8();
      double? lat, lon;
      if ((flags & 0x10) != 0 && r.remaining >= 8) {
        lat = r.i32() / 1e6;
        lon = r.i32() / 1e6;
      }
      if ((flags & 0x20) != 0 && r.remaining >= 2) r.u16();
      if ((flags & 0x40) != 0 && r.remaining >= 2) r.u16();
      var name = '';
      if ((flags & 0x80) != 0) {
        name = utf8.decode(r.rest(), allowMalformed: true).replaceAll('\u0000', '').trim();
      }
      return McAdvert(key, ts, flags & 0x0F, lat, lon, name);
    } catch (_) {
      return null;
    }
  }
}
