import 'dart:convert';
import 'dart:typed_data';

import '../core/bytes.dart';
import 'aes.dart';
import 'pki.dart';
import 'protobuf.dart';
import '../i18n.dart';

/// Meshtastic über LoRa: 16-Byte-Kopf + AES-CTR-verschlüsseltes Data-protobuf.

const List<int> mtDefaultPsk = [
  0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59, 0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01
];
const int broadcastNum = 0xFFFFFFFF;

class Port {
  static const text = 1, position = 3, nodeinfo = 4, routing = 5, admin = 6, waypoint = 8,
      telemetry = 67, traceroute = 70, neighborinfo = 71, rangeTest = 66, storeForward = 65, mapReport = 73;
}

const portNames = <int, String>{
  0: 'Unbekannt', 1: 'Text', 2: 'Hardware', 3: 'Position', 4: 'Visitenkarte', 5: 'Routing',
  6: 'Admin', 7: 'Text (komprimiert)', 8: 'Wegpunkt', 9: 'Audio', 10: 'Sensor', 32: 'Antwort',
  33: 'IP-Tunnel', 34: 'Paxcounter', 64: 'Seriell', 65: 'Speichern+Weiterleiten', 66: 'Reichweitentest',
  67: 'Telemetrie', 68: 'ZPS', 70: 'Traceroute', 71: 'Nachbarn', 72: 'ATAK', 73: 'Kartenbericht',
  256: 'Privat',
};

const hwModels = <int, String>{
  0: 'unbekannt', 4: 'T-Beam', 9: 'RAK4631', 10: 'Heltec V2.1', 25: 'Station G1', 31: 'Station G2',
  39: 'DIY V1', 43: 'Heltec V3', 44: 'Heltec WSL V3', 48: 'Heltec Tracker', 49: 'Heltec Paper',
  50: 'T-Deck', 51: 'T-Watch S3', 63: 'XIAO S3', 64: 'T1000-E', 71: 'RAK11310', 88: 'WM1110',
  255: 'Eigenbau',
};

const routingErrors = <int, String>{
  0: 'OK', 1: 'keine Route', 2: 'falsche Antwort', 3: 'Zeitüberschreitung', 4: 'keine Schnittstelle',
  5: 'max. Wiederholungen', 6: 'kein Kanal', 7: 'zu groß', 8: 'keine Antwort', 9: 'Duty Cycle',
  32: 'ungültige Anfrage', 33: 'nicht autorisiert', 34: 'PKI fehlgeschlagen', 35: 'PKI: Schlüssel unbekannt',
};

/// Meshtastic-Modem-Voreinstellungen.
class MtPreset {
  final String name;
  final int sf;
  final int bwHz;
  final int cr;
  const MtPreset(this.name, this.sf, [this.bwHz = 250000, this.cr = 5]);
}

const mtPresets = <MtPreset>[
  MtPreset('LongFast', 11),
  MtPreset('MediumSlow', 10),
  MtPreset('MediumFast', 9),
  MtPreset('ShortSlow', 8),
  MtPreset('ShortFast', 7),
  MtPreset('LongModerate', 11, 125000, 8),
];

/// Meshtastic-Regionen, die die beiden Module können.
class MtRegion {
  final String name;
  final int startHz, endHz;
  const MtRegion(this.name, this.startHz, this.endHz);
}

const mtRegion868 = MtRegion('EU_868', 869400000, 869650000);
const mtRegion433 = MtRegion('EU_433', 433000000, 434000000);

int _djb2(String s) {
  var h = 5381;
  for (final c in utf8.encode(s)) {
    h = ((h << 5) + h + c) & 0xFFFFFFFF;
  }
  return h;
}

/// Frequenz wie in der Meshtastic-Firmware: Kanalplatz aus dem Hash des Kanalnamens.
int mtFrequency(MtRegion r, int bwHz, String channelName) {
  var n = (r.endHz - r.startHz) ~/ bwHz;
  if (n < 1) n = 1;
  final slot = _djb2(channelName) % n;
  return r.startHz + bwHz ~/ 2 + slot * bwHz;
}

Uint8List expandPsk(List<int> psk) {
  if (psk.isEmpty) return Uint8List(0);
  if (psk.length == 1) {
    if (psk[0] == 0) return Uint8List(0);
    final k = Uint8List.fromList(mtDefaultPsk);
    k[15] = (k[15] + psk[0] - 1) & 0xFF;
    return k;
  }
  if (psk.length < 16) return Uint8List(16)..setRange(0, psk.length, psk);
  if (psk.length > 16 && psk.length < 32) return Uint8List(32)..setRange(0, psk.length, psk);
  return Uint8List.fromList(psk.sublist(0, psk.length > 32 ? 32 : psk.length));
}

int channelHash(String name, List<int> psk) {
  var h = 0;
  for (final b in utf8.encode(name)) {
    h ^= b;
  }
  for (final b in expandPsk(psk)) {
    h ^= b;
  }
  return h & 0xFF;
}

class MtChannel {
  String name;
  String pskB64; // wie in der Meshtastic-App, „AQ==“ = Standardschlüssel
  MtChannel(this.name, this.pskB64);

  Uint8List get psk {
    try {
      return base64Decode(pskB64.trim());
    } catch (_) {
      return Uint8List(0);
    }
  }

  Uint8List get key => expandPsk(psk);
  int get hash => channelHash(name, psk);
  bool get encrypted => key.isNotEmpty;

  Map<String, dynamic> toJson() => {'name': name, 'psk': pskB64};
  static MtChannel fromJson(Map<String, dynamic> j) => MtChannel(j['name'] as String? ?? 'LongFast', j['psk'] as String? ?? 'AQ==');
}

class MtPacket {
  final int dest, from, id, flags, chash, nextHop, relay;
  final Uint8List enc;
  int? channelIndex;
  int? port;
  Uint8List payload = Uint8List(0);
  bool wantResponse = false;
  bool pki = false; // Ende-zu-Ende (PKI) entschlüsselt
  int requestId = 0, replyId = 0, emoji = 0;
  Map<String, dynamic> app = {};

  MtPacket(this.dest, this.from, this.id, this.flags, this.chash, this.nextHop, this.relay, this.enc);

  int get hopLimit => flags & 7;
  int get hopStart => flags >> 5;
  int get hopsAway => hopStart >= hopLimit ? hopStart - hopLimit : 0;
  bool get wantAck => (flags & 8) != 0;
  bool get viaMqtt => (flags & 16) != 0;
  bool get isBroadcast => dest == broadcastNum;
  bool get decoded => port != null;
  String get portName => port == null ? tr('verschlüsselt') : (portNames[port] != null ? tr(portNames[port]!) : tr('Port {0}', [port]));

  static MtPacket? parse(Uint8List raw) {
    if (raw.length < 16) return null;
    final r = Rd(raw);
    return MtPacket(r.u32(), r.u32(), r.u32(), r.u8(), r.u8(), r.u8(), r.u8(), r.rest());
  }

  /// Kanal-Hash 0 an eine Einzel-Adresse = Ende-zu-Ende (PKI) verschlüsselt.
  bool get looksPki => chash == 0 && !isBroadcast && enc.length > pkiOverhead;

  bool _parseData(Uint8List plain) {
    try {
      final f = pbParse(plain);
      final p = pbGet(f, 1);
      if (p == null || p.wt != 0) return false;
      port = p.value;
      payload = pbGet(f, 2)?.bytes ?? Uint8List(0);
      wantResponse = (pbGet(f, 3)?.value ?? 0) != 0;
      requestId = pbGet(f, 6)?.value ?? 0;
      replyId = pbGet(f, 7)?.value ?? 0;
      emoji = pbGet(f, 8)?.value ?? 0;
      app = decodeApp(port!, payload);
      return true;
    } catch (_) {
      port = null;
      return false;
    }
  }

  /// Mit den bekannten Kanälen entschlüsseln. true = gelungen.
  bool decrypt(List<MtChannel> channels) {
    for (var i = 0; i < channels.length; i++) {
      final ch = channels[i];
      if (ch.hash != chash) continue;
      final plain = ch.encrypted ? aesCtr(ch.key, _nonce(id, from), enc) : enc;
      if (_parseData(plain)) {
        channelIndex = i;
        return true;
      }
    }
    return false;
  }

  /// Ende-zu-Ende verschlüsselte Direktnachricht mit dem gemeinsamen Schlüssel öffnen.
  bool decryptPki(List<int> sharedKey) {
    final plain = pkiDecrypt(sharedKey, id, from, enc);
    if (plain == null || !_parseData(plain)) return false;
    pki = true;
    return true;
  }
}

Uint8List _nonce(int packetId, int from) {
  final w = Wr()
    ..u32(packetId)
    ..u32(0)
    ..u32(from)
    ..u32(0);
  return w.toBytes();
}

/// Inhalt der wichtigsten Anwendungen lesbar machen.
Map<String, dynamic> decodeApp(int port, Uint8List p) {
  final d = <String, dynamic>{};
  try {
    if (port == Port.text) {
      d['text'] = utf8.decode(p, allowMalformed: true);
      return d;
    }
    final f = pbParse(p);
    switch (port) {
      case Port.nodeinfo:
        for (final x in f) {
          if (x.field == 1) d['id'] = x.str;
          if (x.field == 2) d['long'] = x.str;
          if (x.field == 3) d['short'] = x.str;
          if (x.field == 5) d['hw'] = x.value;
          if (x.field == 6) d['licensed'] = x.value != 0;
          if (x.field == 7) d['role'] = x.value;
          if (x.field == 8 && x.wt == 2) d['pubkey'] = x.bytes;
        }
        break;
      case Port.position:
        for (final x in f) {
          if (x.field == 1) d['lat'] = (x.wt == 5 ? x.sfixed32 : x.int32) / 1e7;
          if (x.field == 2) d['lon'] = (x.wt == 5 ? x.sfixed32 : x.int32) / 1e7;
          if (x.field == 3) d['alt'] = x.int32;
          if (x.field == 4) d['time'] = x.value;
          if (x.field == 14) d['sats'] = x.value;
        }
        break;
      case Port.telemetry:
        for (final x in f) {
          if (x.field == 2 && x.wt == 2) {
            for (final g in pbParse(x.bytes)) {
              if (g.field == 1) d['battery'] = g.value;
              if (g.field == 2) d['voltage'] = g.f32;
              if (g.field == 3) d['chUtil'] = g.f32;
              if (g.field == 4) d['airUtil'] = g.f32;
              if (g.field == 5) d['uptime'] = g.value;
            }
          } else if (x.field == 3 && x.wt == 2) {
            for (final g in pbParse(x.bytes)) {
              if (g.field == 1) d['temp'] = g.f32;
              if (g.field == 2) d['hum'] = g.f32;
              if (g.field == 3) d['press'] = g.f32;
            }
          }
        }
        break;
      case Port.waypoint:
        for (final x in f) {
          if (x.field == 1) d['id'] = x.value;
          if (x.field == 2) d['lat'] = (x.wt == 5 ? x.sfixed32 : x.int32) / 1e7;
          if (x.field == 3) d['lon'] = (x.wt == 5 ? x.sfixed32 : x.int32) / 1e7;
          if (x.field == 4) d['expire'] = x.value;
          if (x.field == 6) d['name'] = x.str;
          if (x.field == 7) d['desc'] = x.str;
          if (x.field == 8) d['icon'] = x.value;
        }
        break;
      case Port.routing:
        final e = pbGet(f, 3);
        if (e != null) d['error'] = e.value;
        if (pbGet(f, 1) != null) d['request'] = true;
        if (pbGet(f, 2) != null) d['reply'] = true;
        break;
      case Port.traceroute:
        final route = <int>[];
        for (final x in f) {
          if (x.field == 1) {
            if (x.wt == 2) {
              final r = Rd(x.bytes);
              while (r.remaining >= 4) {
                route.add(r.u32());
              }
            } else {
              route.add(x.value);
            }
          }
        }
        d['route'] = route;
        final back = <int>[];
        for (final x in f) {
          if (x.field == 3) {
            if (x.wt == 2) {
              final r = Rd(x.bytes);
              while (r.remaining >= 4) {
                back.add(r.u32());
              }
            } else {
              back.add(x.value);
            }
          }
        }
        d['back'] = back;
        break;
      default:
        d['felder'] = f.length;
    }
  } catch (e) {
    d['fehler'] = e.toString();
  }
  return d;
}

/// Kurze lesbare Zusammenfassung für den Monitor.
String describeApp(MtPacket p) {
  final a = p.app;
  switch (p.port) {
    case Port.text:
      return '»${a['text']}«';
    case Port.nodeinfo:
      return '${a['long'] ?? '?'} (${a['short'] ?? ''}) · ${hwModels[a['hw']] != null ? tr(hwModels[a['hw']]!) : a['hw'] ?? ''}';
    case Port.position:
      return a.containsKey('lat') ? '${(a['lat'] as double).toStringAsFixed(5)}, ${(a['lon'] as double).toStringAsFixed(5)}' : tr('ohne Position');
    case Port.telemetry:
      final parts = <String>[];
      if (a['battery'] != null) parts.add(tr('Akku {0} %', [a['battery']]));
      if (a['voltage'] != null) parts.add('${(a['voltage'] as double).toStringAsFixed(2)} V');
      if (a['chUtil'] != null) parts.add(tr('Kanal {0} %', [(a['chUtil'] as double).toStringAsFixed(1)]));
      if (a['temp'] != null) parts.add('${(a['temp'] as double).toStringAsFixed(1)} °C');
      return parts.join(' · ');
    case Port.waypoint:
      return tr('Wegpunkt »{0}«', [a['name'] ?? '']);
    case Port.traceroute:
      return tr('Route {0} Zwischenstationen', [(a['route'] as List?)?.length ?? 0]);
    case Port.routing:
      return tr('Antwort auf {0}: {1}', [p.requestId.toRadixString(16), (routingErrors[a['error']] != null ? tr(routingErrors[a['error']]!) : a['error'] ?? '-')]);
    default:
      return '';
  }
}

// ---------------------------------------------------------------- Bauen
Uint8List buildMtPacket({
  required int from,
  required int id,
  required MtChannel channel,
  required int port,
  required List<int> payload,
  int dest = broadcastNum,
  int hopLimit = 3,
  bool wantAck = false,
  bool wantResponse = false,
  int requestId = 0,
  int replyId = 0,
  List<int>? pkiKey, // gemeinsamer Schlüssel -> Ende-zu-Ende verschlüsselt (Kanal-Hash 0)
}) {
  final w = PbWriter()
    ..varint(1, port)
    ..bytes(2, payload);
  if (wantResponse) w.varint(3, 1);
  if (requestId != 0) w.fixed32(6, requestId);
  if (replyId != 0) w.fixed32(7, replyId);
  final data = w.toBytes();
  if (data.length > (pkiKey != null ? 233 - pkiOverhead : 233)) throw ArgumentError(tr('Nutzdaten zu lang'));
  final enc = pkiKey != null
      ? pkiEncrypt(pkiKey, id, from, data)
      : (channel.encrypted ? aesCtr(channel.key, _nonce(id, from), data) : data);
  final hl = hopLimit & 7;
  final flags = hl | (wantAck ? 8 : 0) | (hl << 5);
  final h = Wr()
    ..u32(dest)
    ..u32(from)
    ..u32(id)
    ..u8(flags)
    ..u8(pkiKey != null ? 0 : channel.hash)
    ..u8(0)
    ..u8(from & 0xFF)
    ..add(enc);
  return h.toBytes();
}

Uint8List userPayload(int myNum, String longName, String shortName,
    {int hwModel = 255, bool licensed = false, int role = 0, List<int>? publicKey}) {
  String cut(String s, int max) {
    var b = utf8.encode(s);
    var t = s;
    while (b.length > max && t.isNotEmpty) {
      t = t.substring(0, t.length - 1);
      b = utf8.encode(t);
    }
    return t;
  }

  final w = PbWriter()
    ..string(1, nodeIdStr(myNum))
    ..string(2, cut(longName, 39))
    ..string(3, cut(shortName, 4))
    ..varint(5, hwModel);
  if (licensed) w.varint(6, 1);
  if (role != 0) w.varint(7, role);
  if (publicKey != null && publicKey.length == 32) w.bytes(8, publicKey);
  return w.toBytes();
}

/// [precisionBits] wie in Meshtastic: 32 = genau, 13 ≈ 3 km, 16 ≈ 360 m, 19 ≈ 45 m.
Uint8List positionPayload(double lat, double lon, {int? altM, int precisionBits = 32}) {
  int q(double v) {
    var i = (v * 1e7).round() & 0xFFFFFFFF;
    if (precisionBits > 0 && precisionBits < 32) {
      i = i & ((0xFFFFFFFF << (32 - precisionBits)) & 0xFFFFFFFF);
      i = (i + (1 << (31 - precisionBits))) & 0xFFFFFFFF;
    }
    return i;
  }

  final w = PbWriter()
    ..fixed32(1, q(lat))
    ..fixed32(2, q(lon));
  if (altM != null && precisionBits >= 32) w.varint(3, altM);
  w.fixed32(4, DateTime.now().millisecondsSinceEpoch ~/ 1000);
  if (precisionBits < 32) w.varint(23, precisionBits);
  return w.toBytes();
}

/// Eigene Gerätewerte (Meshtastic-Telemetrie): Sendezeit-Anteil und Laufzeit.
Uint8List deviceTelemetryPayload({double? voltage, int? batteryLevel, double? airUtilTx, double? chUtil, int? uptimeS}) {
  final dm = PbWriter();
  if (batteryLevel != null) dm.varint(1, batteryLevel);
  if (voltage != null) dm.float32(2, voltage);
  if (chUtil != null) dm.float32(3, chUtil);
  if (airUtilTx != null) dm.float32(4, airUtilTx);
  if (uptimeS != null) dm.varint(5, uptimeS);
  return (PbWriter()
        ..fixed32(1, DateTime.now().millisecondsSinceEpoch ~/ 1000)
        ..bytes(2, dm.toBytes()))
      .toBytes();
}

/// Leere Anfrage nach Gerätewerten (Meshtastic antwortet mit seiner Telemetrie).
Uint8List telemetryRequestPayload() => (PbWriter()..bytes(2, const [])).toBytes();

/// Meshtastic-Rollen (User.role).
const mtRoleNames = <int, String>{
  0: 'Client',
  1: 'Client stumm',
  2: 'Router',
  3: 'Router + Client',
  4: 'Repeater',
  5: 'Tracker',
  6: 'Sensor',
  7: 'TAK',
  8: 'Client versteckt',
  9: 'Lost and Found',
  10: 'TAK-Tracker',
  11: 'Router spät',
  12: 'Client Basis',
};

Uint8List routingAckPayload([int error = 0]) => (PbWriter()..varint(3, error)).toBytes();

Uint8List waypointPayload({
  required int id,
  required double lat,
  required double lon,
  required String name,
  String description = '',
  int expire = 0,
  int icon = 0x1F4CD,
}) {
  final w = PbWriter()
    ..varint(1, id)
    ..fixed32(2, (lat * 1e7).round() & 0xFFFFFFFF)
    ..fixed32(3, (lon * 1e7).round() & 0xFFFFFFFF);
  if (expire != 0) w.varint(4, expire);
  w.string(6, name);
  if (description.isNotEmpty) w.string(7, description);
  w.fixed32(8, icon);
  return w.toBytes();
}

// ---------------------------------------------------------------- Kanal-Links
/// Modem-Voreinstellungen im Meshtastic-LoRaConfig (Enum) → Name für den Kanal-Hash.
const _presetEnumNames = <int, String>{
  0: 'LongFast', 1: 'LongSlow', 3: 'MediumSlow', 4: 'MediumFast', 5: 'ShortSlow', 6: 'ShortFast',
  7: 'LongModerate', 8: 'ShortTurbo',
};

class ChannelLink {
  final List<MtChannel> channels;
  final String? presetName;
  ChannelLink(this.channels, this.presetName);
}

/// Meshtastic-Kanal-Link (https://meshtastic.org/e/#…) lesen.
ChannelLink? parseChannelLink(String text) {
  var t = text.trim();
  final i = t.indexOf('#');
  if (i >= 0) t = t.substring(i + 1);
  t = t.split('?').first.replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  try {
    final bytes = base64Decode(t);
    final f = pbParse(bytes);
    String? preset;
    final lora = pbGet(f, 2);
    if (lora != null && lora.wt == 2) {
      final lf = pbParse(lora.bytes);
      final usePreset = pbGet(lf, 1)?.value ?? 1;
      final p = pbGet(lf, 2)?.value ?? 0;
      if (usePreset != 0) preset = _presetEnumNames[p];
    }
    final out = <MtChannel>[];
    for (final x in f.where((x) => x.field == 1 && x.wt == 2)) {
      final cs = pbParse(x.bytes);
      final psk = pbGet(cs, 2)?.bytes ?? Uint8List(0);
      var name = pbGet(cs, 3)?.str ?? '';
      if (name.isEmpty) name = preset ?? 'LongFast';
      out.add(MtChannel(name, base64Encode(psk)));
    }
    if (out.isEmpty) return null;
    return ChannelLink(out, preset);
  } catch (_) {
    return null;
  }
}

/// Eigene Kanäle als Meshtastic-Link (zum Teilen mit der Meshtastic-App).
String buildChannelLink(List<MtChannel> channels, {String preset = 'LongFast'}) {
  final w = PbWriter();
  for (var i = 0; i < channels.length; i++) {
    final c = channels[i];
    final cs = PbWriter()..bytes(2, c.psk);
    // Der Hauptkanal mit Standardnamen bleibt leer, wie in Meshtastic üblich
    if (!(i == 0 && c.name == preset)) cs.string(3, c.name);
    w.bytes(1, cs.toBytes());
  }
  final presetEnum = _presetEnumNames.entries.firstWhere((e) => e.value == preset, orElse: () => const MapEntry(0, 'LongFast')).key;
  final lora = PbWriter()
    ..varint(1, 1)
    ..varint(2, presetEnum)
    ..varint(7, 3) // Region EU_868
    ..varint(8, 3) // hop_limit
    ..varint(9, 1); // tx_enabled
  w.bytes(2, lora.toBytes());
  final b = base64Url.encode(w.toBytes()).replaceAll('=', '');
  return 'https://meshtastic.org/e/#$b';
}
