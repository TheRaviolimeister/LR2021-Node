import 'dart:convert';
import 'dart:typed_data';

import '../core/modem.dart';
import '../mesh/meshtastic.dart';
import '../i18n.dart';

enum RadioMode { meshtastic, meshcore, lrfunk, manual }

String radioModeName(RadioMode m) => switch (m) {
      RadioMode.meshtastic => tr('Meshtastic'),
      RadioMode.meshcore => tr('MeshCore (mithören)'),
      RadioMode.lrfunk => tr('LR-Funk (eigener Kanal)'),
      RadioMode.manual => tr('Manuell'),
    };

RadioMode _modeFrom(Object? s, RadioMode def) {
  for (final m in RadioMode.values) {
    if (m.name == s) return m;
  }
  return def;
}

Map<String, dynamic> loraToJson(LoraCfg c) => {
      'f': c.freqHz,
      'bw': c.bwHz,
      'sf': c.sf,
      'cr': c.cr,
      'sync': c.sync,
      'pwr': c.powerDbm,
      'pre': c.preamble,
      'fl': c.flags,
    };

LoraCfg loraFromJson(Object? j, LoraCfg def) {
  if (j is! Map) return def;
  try {
    return LoraCfg(
      freqHz: j['f'] as int,
      bwHz: j['bw'] as int,
      sf: j['sf'] as int,
      cr: j['cr'] as int,
      sync: j['sync'] as int,
      powerDbm: j['pwr'] as int,
      preamble: j['pre'] as int,
      flags: j['fl'] as int? ?? 1,
    );
  } catch (_) {
    return def;
  }
}

class Settings {
  String longName = tr('LR2021 Prototyp');
  String shortName = 'LR21';
  String callsign = '';
  int myNum = 0;
  List<MtChannel> channels = [MtChannel('LongFast', 'AQ==')];
  int mtPreset = 0;
  int powerHf = 14;
  bool lbt = false;
  int nodeInfoHours = 3;
  int hopLimit = 3;
  bool sharePosition = false;
  double? lat, lon;
  int? alt;
  String piHost = '10.42.0.1';
  RadioMode modeA = RadioMode.meshtastic;
  RadioMode modeB = RadioMode.lrfunk;
  LoraCfg lrCfg = LoraCfg(freqHz: 433875000, bwHz: 125000, sf: 9, cr: 5, sync: 0x12, powerDbm: 10, preamble: 8);
  LoraCfg manualA = LoraCfg(freqHz: 869525000, bwHz: 125000, sf: 9, cr: 5, sync: 0x12, powerDbm: 10, preamble: 8);
  LoraCfg manualB = LoraCfg(freqHz: 433875000, bwHz: 125000, sf: 9, cr: 5, sync: 0x12, powerDbm: 10, preamble: 8);
  bool lrAutoAck = true;
  int lrBeaconMin = 0;
  int theme = 2; // 0 System, 1 hell, 2 dunkel
  String mapLayer = 'topo';
  bool mapOffline = false;
  bool sound = true;
  bool gpsFollow = false; // ältere Einstellung, wird in gpsSource übernommen
  bool relay = false; // ältere Einstellung, wird in mtRole übernommen
  String gpsSource = 'auto'; // aus | geraet | node | auto
  String mtRole = 'client'; // client | client_mute | router
  String rebroadcast = 'all'; // all | local | known | none
  int posIntervalMin = 30;
  int posPrecision = 32;
  int telemetryMin = 30;
  bool licensed = false;
  bool powerAuto = true;
  int powerLf = 10;
  double antGainHf = 2.15, antGainLf = 2.15;
  int freqCorrA = 0, freqCorrB = 0; // Hz
  int overrideFreqA = 0, overrideFreqB = 0; // Hz, 0 = automatisch
  bool autoConnect = true;
  String lastKindA = '', lastKindB = '', lastPortA = '', lastPortB = '';
  List<String> quickMsgs = [tr('OK 👍'), tr('Verstanden'), tr('Bin unterwegs'), tr('Wo bist du?'), tr('Brauche Hilfe'), tr('Ende, 73')];
  double? mapLat, mapLon, mapZoom;
  bool mapNames = true; // Knotennamen auf der Karte
  bool autoFreqCorr = true; // Frequenzkorrektur aus empfangenen Paketen nachführen
  bool compass = true; // Radar/Karte nach Gerät ausrichten (wenn Kompass vorhanden)
  String pkiPrivate = ''; // eigener privater Schlüssel (Base64) für Meshtastic-Direktnachrichten
  String nodeUser = 'root', nodePass = 'lr2021node'; // Anmeldung an der Node-Konsole (Node-Kabel)
  String navTarget = ''; // Ziel der Kompass-Navigation: 'node:<key>' oder 'wp:<id>'
  String lang = 'en'; // Sprache der Oberfläche: 'en' (Standard) oder 'de'
  bool autoUpdate = true; // beim Start nach neuen App-Versionen suchen
  String skipVersion = ''; // diese Version nicht mehr anbieten

  Map<String, dynamic> toJson() => {
        'long': longName,
        'short': shortName,
        'call': callsign,
        'num': myNum,
        'ch': channels.map((c) => c.toJson()).toList(),
        'preset': mtPreset,
        'pwrHf': powerHf,
        'lbt': lbt,
        'niH': nodeInfoHours,
        'hop': hopLimit,
        'pos': sharePosition,
        'lat': lat,
        'lon': lon,
        'alt': alt,
        'pi': piHost,
        'modeA': modeA.name,
        'modeB': modeB.name,
        'lr': loraToJson(lrCfg),
        'manA': loraToJson(manualA),
        'manB': loraToJson(manualB),
        'lrAck': lrAutoAck,
        'lrBeacon': lrBeaconMin,
        'theme': theme,
        'mapLayer': mapLayer,
        'mapOff': mapOffline,
        'sound': sound,
        'gpsSrc': gpsSource,
        'role': mtRole,
        'rebc': rebroadcast,
        'posInt': posIntervalMin,
        'posPrec': posPrecision,
        'telInt': telemetryMin,
        'lic': licensed,
        'pwrAuto': powerAuto,
        'pwrLf': powerLf,
        'gainHf': antGainHf,
        'gainLf': antGainLf,
        'corrA': freqCorrA,
        'corrB': freqCorrB,
        'ovrA': overrideFreqA,
        'ovrB': overrideFreqB,
        'autoCon': autoConnect,
        'lkA': lastKindA,
        'lkB': lastKindB,
        'lpA': lastPortA,
        'lpB': lastPortB,
        'quick': quickMsgs,
        'mapLat': mapLat,
        'mapLon': mapLon,
        'mapZoom': mapZoom,
        'mapNames': mapNames,
        'autoCorr': autoFreqCorr,
        'compass': compass,
        'pkiPriv': pkiPrivate,
        'nodeUser': nodeUser,
        'nodePass': nodePass,
        'nav': navTarget,
        'lang': lang,
        'autoUpd': autoUpdate,
        'skipVer': skipVersion,
      };

  void load(Map<String, dynamic> j) {
    longName = j['long'] as String? ?? longName;
    shortName = j['short'] as String? ?? shortName;
    callsign = j['call'] as String? ?? callsign;
    myNum = j['num'] as int? ?? myNum;
    final ch = j['ch'];
    if (ch is List && ch.isNotEmpty) {
      channels = ch.whereType<Map>().map((m) => MtChannel.fromJson(Map<String, dynamic>.from(m))).toList();
    }
    mtPreset = (j['preset'] as int? ?? 0).clamp(0, mtPresets.length - 1).toInt();
    powerHf = j['pwrHf'] as int? ?? powerHf;
    lbt = j['lbt'] as bool? ?? lbt;
    nodeInfoHours = j['niH'] as int? ?? nodeInfoHours;
    hopLimit = j['hop'] as int? ?? hopLimit;
    sharePosition = j['pos'] as bool? ?? false;
    lat = _d(j['lat']);
    lon = _d(j['lon']);
    alt = j['alt'] as int?;
    piHost = j['pi'] as String? ?? piHost;
    modeA = _modeFrom(j['modeA'], modeA);
    modeB = _modeFrom(j['modeB'], modeB);
    lrCfg = loraFromJson(j['lr'], lrCfg);
    manualA = loraFromJson(j['manA'], manualA);
    manualB = loraFromJson(j['manB'], manualB);
    lrAutoAck = j['lrAck'] as bool? ?? true;
    lrBeaconMin = j['lrBeacon'] as int? ?? 0;
    theme = j['theme'] as int? ?? 2;
    mapLayer = j['mapLayer'] as String? ?? mapLayer;
    mapOffline = j['mapOff'] as bool? ?? false;
    sound = j['sound'] as bool? ?? true;
    gpsFollow = j['gps'] as bool? ?? false;
    relay = j['relay'] as bool? ?? false;
    gpsSource = j['gpsSrc'] as String? ?? 'auto';
    mtRole = j['role'] as String? ?? 'client';
    rebroadcast = j['rebc'] as String? ?? 'all';
    posIntervalMin = j['posInt'] as int? ?? 30;
    posPrecision = j['posPrec'] as int? ?? 32;
    telemetryMin = j['telInt'] as int? ?? 30;
    licensed = j['lic'] as bool? ?? false;
    powerAuto = j['pwrAuto'] as bool? ?? true;
    powerLf = j['pwrLf'] as int? ?? 10;
    antGainHf = _d(j['gainHf']) ?? 2.15;
    antGainLf = _d(j['gainLf']) ?? 2.15;
    freqCorrA = j['corrA'] as int? ?? 0;
    freqCorrB = j['corrB'] as int? ?? 0;
    overrideFreqA = j['ovrA'] as int? ?? 0;
    overrideFreqB = j['ovrB'] as int? ?? 0;
    autoConnect = j['autoCon'] as bool? ?? true;
    lastKindA = j['lkA'] as String? ?? '';
    lastKindB = j['lkB'] as String? ?? '';
    lastPortA = j['lpA'] as String? ?? '';
    lastPortB = j['lpB'] as String? ?? '';
    final q = j['quick'];
    if (q is List) quickMsgs = q.whereType<String>().toList();
    mapLat = _d(j['mapLat']);
    mapLon = _d(j['mapLon']);
    mapZoom = _d(j['mapZoom']);
    mapNames = j['mapNames'] as bool? ?? true;
    autoFreqCorr = j['autoCorr'] as bool? ?? true;
    compass = j['compass'] as bool? ?? true;
    pkiPrivate = j['pkiPriv'] as String? ?? '';
    nodeUser = j['nodeUser'] as String? ?? 'root';
    nodePass = j['nodePass'] as String? ?? 'lr2021node';
    navTarget = j['nav'] as String? ?? '';
    lang = j['lang'] as String? ?? 'en';
    autoUpdate = j['autoUpd'] as bool? ?? true;
    skipVersion = j['skipVer'] as String? ?? '';
  }
}

/// Netz, über das ein Knoten gehört wurde.
enum Net { mt, mc, lr }

String netName(Net n) => switch (n) { Net.mt => tr('Meshtastic'), Net.mc => 'MeshCore', Net.lr => 'LR-Funk' };

class Node {
  final String key;
  final Net net;
  final int num;
  String longName = '';
  String shortName = '';
  String hw = '';
  DateTime lastHeard;
  double? rssi, snr;
  int? hops;
  double? lat, lon;
  int? alt;
  int? battery;
  double? voltage, chUtil;
  String via = '';
  int packets = 0;
  String route = '';
  final List<(DateTime, double)> history = []; // SNR-Verlauf (nur direkt gehört)
  int? rttMs;
  DateTime? routeAt;
  bool favorite = false;
  bool ignored = false;
  String role = '';
  double? temp;
  double? airUtil;
  int? uptimeS;
  DateTime? posAt, infoAt, telAt; // wann zuletzt Position / Visitenkarte / Telemetrie kam
  DateTime? askedInfo; // zuletzt Visitenkarte angefordert
  Uint8List? pubKey; // öffentlicher Schlüssel (Meshtastic-PKI)

  Node(this.key, this.net, this.num, this.lastHeard);

  String get display => longName.isNotEmpty ? longName : key;
  String get badge {
    if (shortName.isNotEmpty) return shortName;
    final k = key.replaceAll(RegExp(r'^(mc:|lr:|!)'), '');
    return k.length > 4 ? k.substring(k.length - 4) : k;
  }

  bool get hasPos => lat != null && lon != null && !(lat == 0 && lon == 0);

  Map<String, dynamic> toJson() => {
        'k': key,
        'n': net.name,
        'num': num,
        'l': longName,
        's': shortName,
        'hw': hw,
        't': lastHeard.millisecondsSinceEpoch,
        'rssi': rssi,
        'snr': snr,
        'hops': hops,
        'lat': lat,
        'lon': lon,
        'alt': alt,
        'bat': battery,
        'v': voltage,
        'cu': chUtil,
        'via': via,
        'p': packets,
        'route': route,
        'rtt': rttMs,
        'fav': favorite,
        'ign': ignored,
        'role': role,
        'temp': temp,
        'air': airUtil,
        'up': uptimeS,
        'posAt': posAt?.millisecondsSinceEpoch,
        'infoAt': infoAt?.millisecondsSinceEpoch,
        'telAt': telAt?.millisecondsSinceEpoch,
        'pk': pubKey == null ? null : base64Encode(pubKey!),
      };

  static Node? fromJson(Map<String, dynamic> j) {
    try {
      final net = Net.values.firstWhere((n) => n.name == j['n'], orElse: () => Net.mt);
      final n = Node(j['k'] as String, net, j['num'] as int, DateTime.fromMillisecondsSinceEpoch(j['t'] as int))
        ..longName = j['l'] as String? ?? ''
        ..shortName = j['s'] as String? ?? ''
        ..hw = j['hw'] as String? ?? ''
        ..rssi = _d(j['rssi'])
        ..snr = _d(j['snr'])
        ..hops = j['hops'] as int?
        ..lat = _d(j['lat'])
        ..lon = _d(j['lon'])
        ..alt = j['alt'] as int?
        ..battery = j['bat'] as int?
        ..voltage = _d(j['v'])
        ..chUtil = _d(j['cu'])
        ..via = j['via'] as String? ?? ''
        ..packets = j['p'] as int? ?? 0
        ..route = j['route'] as String? ?? ''
        ..rttMs = j['rtt'] as int?
        ..favorite = j['fav'] as bool? ?? false
        ..ignored = j['ign'] as bool? ?? false
        ..role = j['role'] as String? ?? ''
        ..temp = _d(j['temp'])
        ..airUtil = _d(j['air'])
        ..uptimeS = j['up'] as int?
        ..posAt = _t(j['posAt'])
        ..infoAt = _t(j['infoAt'])
        ..telAt = _t(j['telAt']);
      final pk = j['pk'];
      if (pk is String && pk.isNotEmpty) {
        try {
          final b = base64Decode(pk);
          if (b.length == 32) n.pubKey = b;
        } catch (_) {}
      }
      return n;
    } catch (_) {
      return null;
    }
  }
}

double? _d(Object? v) => v is num ? v.toDouble() : null;
DateTime? _t(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;

enum MsgStatus { pending, sent, relayed, acked, failed, received }

class Message {
  final String chat;
  final String from;
  String fromName;
  String text;
  final DateTime at;
  final bool mine;
  MsgStatus status;
  String info = '';
  double? rssi, snr;
  int? hops;
  final int pktId;
  String? file; // Pfad einer gesendeten/empfangenen Datei
  String? mime;
  int? fileSize;
  double progress = 0; // 0..1 während der Übertragung
  bool get isImage => (mime ?? '').startsWith('image/');

  Message({
    required this.chat,
    required this.from,
    required this.fromName,
    required this.text,
    required this.at,
    required this.mine,
    required this.status,
    required this.pktId,
    this.rssi,
    this.snr,
    this.hops,
  });

  Map<String, dynamic> toJson() => {
        'c': chat,
        'f': from,
        'fn': fromName,
        't': text,
        'at': at.millisecondsSinceEpoch,
        'm': mine,
        's': status.name,
        'i': info,
        'r': rssi,
        'sn': snr,
        'h': hops,
        'id': pktId,
        if (file != null) 'file': file,
        if (mime != null) 'mime': mime,
        if (fileSize != null) 'fsz': fileSize,
      };

  static Message? fromJson(Map<String, dynamic> j) {
    try {
      var st = MsgStatus.values.firstWhere((s) => s.name == j['s'], orElse: () => MsgStatus.received);
      if (st == MsgStatus.pending) st = MsgStatus.failed; // beim Beenden hängen geblieben
      return Message(
        chat: j['c'] as String,
        from: j['f'] as String,
        fromName: j['fn'] as String? ?? '',
        text: j['t'] as String,
        at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
        mine: j['m'] as bool? ?? false,
        status: st,
        pktId: j['id'] as int? ?? 0,
        rssi: (j['r'] as num?)?.toDouble(),
        snr: (j['sn'] as num?)?.toDouble(),
        hops: j['h'] as int?,
      )
        ..info = j['i'] as String? ?? ''
        ..file = j['file'] as String?
        ..mime = j['mime'] as String?
        ..fileSize = j['fsz'] as int?
        ..progress = j['file'] != null ? 1 : 0;
    } catch (_) {
      return null;
    }
  }
}

enum LogKind { rx, tx, log, warn, err, info }

class LogEntry {
  final DateTime at;
  final String slot;
  final LogKind kind;
  final String title;
  final String detail;
  LogEntry(this.slot, this.kind, this.title, [this.detail = '']) : at = DateTime.now();
}

class ChatInfo {
  final String id;
  final String title;
  final String subtitle;
  final Net net;
  ChatInfo(this.id, this.title, this.subtitle, this.net);
}

/// Wegpunkt (eigener oder über Meshtastic empfangen).
class Waypoint {
  final int id;
  String name;
  String description;
  double lat, lon;
  String from; // Knoten-ID oder „ich“
  DateTime at;
  int? expire; // Unix-Sekunden
  String icon;
  Waypoint({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.from,
    required this.at,
    this.description = '',
    this.expire,
    this.icon = '📍',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'n': name,
        'd': description,
        'lat': lat,
        'lon': lon,
        'f': from,
        'at': at.millisecondsSinceEpoch,
        'x': expire,
        'i': icon,
      };

  static Waypoint? fromJson(Map<String, dynamic> j) {
    try {
      return Waypoint(
        id: j['id'] as int,
        name: j['n'] as String? ?? '',
        description: j['d'] as String? ?? '',
        lat: _d(j['lat'])!,
        lon: _d(j['lon'])!,
        from: j['f'] as String? ?? '',
        at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
        expire: j['x'] as int?,
        icon: j['i'] as String? ?? '📍',
      );
    } catch (_) {
      return null;
    }
  }
}
