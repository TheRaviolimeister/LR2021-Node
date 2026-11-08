import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/bytes.dart';
import '../core/demo.dart';
import '../core/modem.dart';
import '../core/node_serial.dart';
import '../core/regulatory.dart';
import '../core/transport.dart';
import '../core/updater.dart';
import '../geo/coords.dart' show toMgrs;
import '../geo/gps.dart';
import '../geo/nmea.dart';
import '../mesh/lr_file.dart';
import '../mesh/lr_radio.dart';
import '../mesh/meshcore.dart';
import '../mesh/meshtastic.dart';
import '../mesh/pki.dart';
import 'models.dart';
import '../i18n.dart';

/// Ein ESP32-Modem (A = HF 868, B = LF 433).
class ModemSlot {
  final String role;
  ModemSlot(this.role);

  TransportKind kind = TransportKind.usb;
  List<PortChoice> ports = [];
  PortChoice? port;
  ModemClient? client;
  ModemInfo? info;
  ModemConfig? config;
  Stats? stats;
  bool connecting = false;
  String? error;
  String status = tr('nicht verbunden');
  double? liveRssi;
  double? lastRxRssi;
  DateTime? lastRx, lastTx;
  bool transmitting = false;
  bool manualOff = false;
  Timer? _reconnect;
  final List<_TxJob> _queue = [];
  bool _txRunning = false;
  StreamSubscription<ModemEvent>? _sub;

  bool get connected => client != null && !client!.isClosed;
  String get band => role == 'A' ? tr('HF 868') : tr('LF 433');
  String get espName => 'ESP32 $role';
}

class _TxJob {
  final Uint8List data;
  final String what;
  final void Function(TxDoneEvent ev)? done;
  _TxJob(this.data, this.what, this.done);
}

class NodeApp extends ChangeNotifier {
  final Settings settings = Settings();
  final ModemSlot a = ModemSlot('A');
  final ModemSlot b = ModemSlot('B');
  final Map<String, Node> nodes = {};
  final List<Message> messages = [];
  final List<LogEntry> log = [];
  final Map<String, int> unread = {};
  final List<Waypoint> waypoints = [];
  final Map<int, (String, DateTime)> _traceReq = {};
  String? openChat;
  bool monitorPaused = false;
  String? debugLogPath;
  String? csvPath;
  IOSink? _csv;

  final Map<int, Message> _awaitAck = {}; // Meshtastic-Paket-ID -> eigene Nachricht
  final Map<int, Message> _awaitLrAck = {};
  final Map<String, DateTime> _seen = {};
  final Map<int, DateTime> _nodeInfoSent = {};
  final Random _rnd = Random.secure();
  SharedPreferences? _prefs;
  Timer? _saveTimer;
  Timer? _tick;
  IOSink? _dbg;
  DateTime _lastNodeInfo = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPosition = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastBeacon = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTelemetry = DateTime.now();
  bool rssiPolling = false;
  final DeviceGps gps = DeviceGps();
  double? gpsAccuracy;

  // ------------------------------------------------------------------ PKI (Direktnachrichten)
  Uint8List? _myPriv;
  Uint8List? myPublicKey;
  final Map<String, (String, Uint8List)> _shared = {}; // Knoten -> (Schlüssel-Base64, gemeinsamer Schlüssel)
  final Map<int, List<(Message, String)>> _keyWait = {}; // Ziel -> wartende Direktnachrichten

  void _initKeys() {
    try {
      if (settings.pkiPrivate.isNotEmpty) {
        final k = base64Decode(settings.pkiPrivate);
        if (k.length == 32) {
          _myPriv = clampPrivate(k);
          myPublicKey = pkiPublicFromPrivate(_myPriv!);
          return;
        }
      }
      final (priv, pub) = pkiNewKeyPair();
      _myPriv = priv;
      myPublicKey = pub;
      settings.pkiPrivate = base64Encode(priv);
      _scheduleSave();
      _log(tr('App'), LogKind.info, tr('Neues Schlüsselpaar für Meshtastic-Direktnachrichten erzeugt'));
    } catch (e) {
      _log(tr('App'), LogKind.err, tr('Schlüsselpaar fehlt'), '$e');
    }
  }

  /// Gemeinsamer Schlüssel mit einem Knoten (null = dessen öffentlicher Schlüssel unbekannt).
  Uint8List? sharedKeyFor(Node? n) {
    final pk = n?.pubKey, priv = _myPriv;
    if (n == null || pk == null || priv == null) return null;
    final b64 = base64Encode(pk);
    final c = _shared[n.key];
    if (c != null && c.$1 == b64) return c.$2;
    try {
      final k = pkiSharedKey(priv, pk);
      _shared[n.key] = (b64, k);
      return k;
    } catch (_) {
      return null;
    }
  }

  /// Ende-zu-Ende-Schlüssel für ein Paket an [dest] (null = Kanal-Verschlüsselung).
  Uint8List? _pkiFor(ModemSlot s, int dest) {
    if (dest == broadcastNum || hamMode(s)) return null; // Amateurfunk: keine Verschlüsselung
    return sharedKeyFor(nodes[nodeIdStr(dest)]);
  }

  /// Kurze Hinweise für die Oberfläche (z. B. „Visitenkarte von X erhalten“).
  final StreamController<String> _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;
  void notice(String text) => _notices.add(text);

  // ------------------------------------------------------------------ Ziel-Navigation (Kompass)
  /// Ziel setzen ('node:<key>' / 'wp:<id>', '' = keins) und das Radar öffnen.
  void setNavTarget(String t, {bool open = true}) {
    settings.navTarget = t;
    changed(save: true);
    if (open && t.isNotEmpty) {
      wantRadar = true;
      tabRequest.value = 2;
    }
  }

  bool wantRadar = false;

  /// Aktuelles Ziel: (Name, Breite, Länge) oder null.
  (String, double, double)? get navPoint {
    final t = settings.navTarget;
    if (t.startsWith('node:')) {
      final n = nodes[t.substring(5)];
      if (n != null && n.hasPos) return (n.display, n.lat!, n.lon!);
    } else if (t.startsWith('wp:')) {
      final id = int.tryParse(t.substring(3));
      final w = waypoints.where((w) => w.id == id).firstOrNull;
      if (w != null) return (w.name, w.lat, w.lon);
    }
    return null;
  }

  /// Wunsch an die Oberfläche, eine Seite zu öffnen (2 = Karte) und dort einen Knoten zu zeigen.
  final ValueNotifier<int?> tabRequest = ValueNotifier<int?>(null);
  String? mapFocus;
  void showOnMap(Node n) {
    mapFocus = n.key;
    tabRequest.value = 2;
  }

  /// Gemessene Frequenzabweichung empfangener Meshtastic-Pakete je Modul (Hz).
  final Map<String, List<int>> freqErr = {'A': [], 'B': []};
  final Map<String, String> corrInfo = {};

  /// Median der letzten Messungen (Hz) oder null, wenn zu wenige.
  double? freqErrAvg(ModemSlot s, {int minCount = 5}) {
    final l = freqErr[s.role]!;
    if (l.length < minCount) return null;
    final sorted = [...l]..sort();
    final h = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[h].toDouble() : (sorted[h - 1] + sorted[h]) / 2;
  }

  /// Gemessene Abweichung in die Frequenzkorrektur übernehmen. Gibt einen Text zurück.
  Future<String> applyFreqCorr(ModemSlot s, {bool auto = false}) async {
    final avg = freqErrAvg(s, minCount: auto ? 8 : 3);
    if (avg == null) return tr('Noch zu wenige Pakete gemessen.');
    final old = _corr(s);
    final neu = old + avg.round();
    if (s.role == 'A') {
      settings.freqCorrA = neu;
    } else {
      settings.freqCorrB = neu;
    }
    freqErr[s.role]!.clear();
    final txt = tr('Frequenzkorrektur {0}: {1} → {2} kHz{3}', [s.band, (old / 1000).toStringAsFixed(1), (neu / 1000).toStringAsFixed(1), auto ? ' (automatisch)' : '']);
    corrInfo[s.role] = '$txt · ${hhmmNow()}';
    _log(s.role, LogKind.info, txt, tr('gemessen {0} kHz', [(avg / 1000).toStringAsFixed(2)]));
    changed(save: true);
    if (s.connected) await applyMode(s);
    return txt;
  }

  void _trackFreqErr(ModemSlot s, RxEvent e) {
    if (e.snr < -7) return; // schwache Pakete messen ungenau
    final l = freqErr[s.role]!;
    l.add(e.freqErr);
    if (l.length > 20) l.removeAt(0);
    if (!settings.autoFreqCorr || s.transmitting) return;
    final avg = freqErrAvg(s, minCount: 8);
    // nur deutliche, stabile Abweichungen nachführen (LoRa verträgt ein paar kHz)
    if (avg != null && avg.abs() > 1500) unawaited(applyFreqCorr(s, auto: true));
  }

  List<ModemSlot> get slots => [a, b];
  ModemSlot slot(String role) => role == 'A' ? a : b;
  RadioMode modeOf(ModemSlot s) => s.role == 'A' ? settings.modeA : settings.modeB;

  // ------------------------------------------------------------------ Start
  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final s = _prefs!.getString('settings');
      if (s != null) settings.load(jsonDecode(s) as Map<String, dynamic>);
      final n = _prefs!.getString('nodes');
      if (n != null) {
        for (final j in (jsonDecode(n) as List)) {
          final node = Node.fromJson(Map<String, dynamic>.from(j as Map));
          if (node != null) nodes[node.key] = node;
        }
      }
      final w = _prefs!.getString('waypoints');
      if (w != null) {
        for (final j in (jsonDecode(w) as List)) {
          final wp = Waypoint.fromJson(Map<String, dynamic>.from(j as Map));
          if (wp != null) waypoints.add(wp);
        }
      }
      final m = _prefs!.getString('messages');
      if (m != null) {
        for (final j in (jsonDecode(m) as List)) {
          final msg = Message.fromJson(Map<String, dynamic>.from(j as Map));
          if (msg != null) messages.add(msg);
        }
      }
    } catch (e) {
      _log(tr('App'), LogKind.err, tr('Gespeicherte Daten nicht lesbar'), '$e');
    }
    L.lang = settings.lang;
    purgeDemo(); // alte Demo-Daten aus früheren Versionen entfernen
    _initKeys();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final d = Directory('${dir.path}${Platform.pathSeparator}LR2021');
      await d.create(recursive: true);
      final f = File('${d.path}${Platform.pathSeparator}debug_log.txt');
      if (await f.exists() && await f.length() > 5 * 1024 * 1024) {
        await f.rename('${f.path}.alt');
      }
      _dbg = f.openWrite(mode: FileMode.append);
      debugLogPath = f.path;
      _dbg!.writeln(tr('==== App gestartet {0} ====', [DateTime.now().toIso8601String()]));
      final c = File('${d.path}${Platform.pathSeparator}empfang.csv');
      final neu = !await c.exists();
      _csv = c.openWrite(mode: FileMode.append);
      csvPath = c.path;
      if (neu) _csv!.writeln('zeit;modul;netz;knoten;name;rssi_dbm;snr_db;hops;knoten_lat;knoten_lon;eigene_lat;eigene_lon;entfernung_km');
    } catch (_) {}
    if (!Platform.isAndroid && !Platform.isIOS) {
      // Desktop: Anschlüsse gleich auflisten
      await refreshPorts(a);
      await refreshPorts(b);
    }
    if (settings.autoConnect) unawaited(_autoConnect());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    if (settings.gpsSource != 'aus') unawaited(setGpsSource(settings.gpsSource));
    if (settings.autoUpdate && Updater.supported) {
      Timer(const Duration(seconds: 6), () => unawaited(updater.check()));
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _saveTimer?.cancel();
    _dbg?.close();
    _csv?.close();
    _notices.close();
    tabRequest.dispose();
    super.dispose();
  }

  /// Sprache umschalten ('en' / 'de').
  void setLanguage(String lang) {
    settings.lang = lang;
    L.lang = lang;
    changed(save: true);
  }

  void changed({bool save = false}) {
    if (save) _scheduleSave();
    notifyListeners();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), saveNow);
  }

  // ------------------------------------------------------------------ Demo-Daten
  /// Knoten, die nur aus dem Demo-Modem stammen – werden nie gespeichert.
  final Set<String> _demoKeys = {};

  bool _isDemoKey(String key) {
    if (_demoKeys.contains(key)) return true;
    final n = nodes[key];
    if (n == null) return false;
    if (n.net == Net.mt && demoNodeNums.contains(n.num)) return true;
    if (n.net == Net.lr && demoLrCalls.contains(n.shortName)) return true;
    if (n.net == Net.mc && n.longName == demoMeshCoreName) return true;
    return false;
  }

  bool _isDemoMessage(Message m) => !m.mine && _isDemoKey(m.from);

  /// Alles aus der Demo entfernen (beim Start und wenn das Demo-Modem getrennt wird).
  void purgeDemo() {
    final keys = nodes.keys.where(_isDemoKey).toSet()..addAll(_demoKeys);
    if (keys.isEmpty) return;
    messages.removeWhere((m) => !m.mine && keys.contains(m.from));
    waypoints.removeWhere((w) => keys.contains(w.from));
    for (final k in keys) {
      nodes.remove(k);
    }
    _demoKeys.clear();
    _scheduleSave();
    notifyListeners();
  }

  Future<void> saveNow() async {
    final p = _prefs;
    if (p == null) return;
    try {
      await p.setString('settings', jsonEncode(settings.toJson()));
      await p.setString('waypoints', jsonEncode(waypoints.where((w) => !_isDemoKey(w.from)).map((w) => w.toJson()).toList()));
      await p.setString('nodes', jsonEncode(nodes.values.where((n) => !_isDemoKey(n.key)).map((n) => n.toJson()).toList()));
      final real = messages.where((m) => !_isDemoMessage(m)).toList();
      final keep = real.length > 2000 ? real.sublist(real.length - 2000) : real;
      await p.setString('messages', jsonEncode(keep.map((m) => m.toJson()).toList()));
    } catch (e) {
      _log(tr('App'), LogKind.err, tr('Speichern fehlgeschlagen'), '$e');
    }
  }

  // ------------------------------------------------------------------ Protokoll / Monitor
  void _log(String slot, LogKind kind, String title, [String detail = '']) {
    final e = LogEntry(slot, kind, title, detail);
    if (!monitorPaused) {
      log.add(e);
      if (log.length > 2000) log.removeRange(0, log.length - 2000);
    }
    final t = e.at.toIso8601String().substring(11, 23);
    _dbg?.writeln('$t [$slot] ${kind.name.toUpperCase()} $title${detail.isNotEmpty ? ' | $detail' : ''}');
  }

  void logInfo(String text) {
    _log(tr('App'), LogKind.info, text);
    notifyListeners();
  }

  void clearLog() {
    log.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------------ Verbinden
  Future<void> refreshPorts(ModemSlot s) async {
    try {
      s.ports = await listUsbPorts();
      if (s.kind == TransportKind.node) {
        // Node-Kabel: beide Modems über denselben CP2102
        if (s.port == null || !s.ports.any((p) => p.id == s.port!.id)) {
          s.port = s.ports.where((p) => p.cp210x).firstOrNull ?? s.ports.firstOrNull;
        }
      } else if (s.port == null || !s.ports.any((p) => p.id == s.port!.id)) {
        // ESP-Anschlüsse bevorzugen, B nimmt den zweiten
        final esp = s.ports.where((p) => p.looksLikeEsp && !p.cp210x).toList();
        final list = esp.isNotEmpty ? esp : s.ports;
        final other = s == a ? b.port : a.port;
        s.port = list.where((p) => p.id != other?.id).firstOrNull ?? list.firstOrNull;
      }
    } catch (e) {
      s.ports = [];
      s.error = tr('Anschlüsse nicht lesbar: {0}', [e]);
    }
    notifyListeners();
  }

  String _lastKind(ModemSlot s) => s.role == 'A' ? settings.lastKindA : settings.lastKindB;
  String _lastPort(ModemSlot s) => s.role == 'A' ? settings.lastPortA : settings.lastPortB;

  Future<void> _autoConnect() async {
    for (final s in slots) {
      final k = availableTransportKinds.where((x) => x.name == _lastKind(s)).firstOrNull;
      if (k == null) continue;
      s.kind = k;
      if (k == TransportKind.usb || k == TransportKind.node) {
        await refreshPorts(s);
        final p = s.ports.where((x) => x.id == _lastPort(s)).firstOrNull;
        if (p == null) continue;
        s.port = p;
      }
      await connect(s);
    }
  }

  void _scheduleReconnect(ModemSlot s) {
    if (s.manualOff || s.kind == TransportKind.demo || !settings.autoConnect) return;
    s._reconnect?.cancel();
    s._reconnect = Timer(const Duration(seconds: 5), () async {
      if (s.connected || s.connecting || s.manualOff) return;
      if (s.kind == TransportKind.usb || s.kind == TransportKind.node) {
        await refreshPorts(s);
        final p = s.ports.where((x) => x.id == _lastPort(s)).firstOrNull;
        if (p == null) {
          _scheduleReconnect(s);
          return;
        }
        s.port = p;
      }
      await connect(s);
      if (!s.connected) _scheduleReconnect(s);
    });
  }

  Future<void> connect(ModemSlot s) async {
    if (s.connecting) return;
    s.manualOff = false;
    s._reconnect?.cancel();
    await disconnect(s, quiet: true);
    s.connecting = true;
    s.error = null;
    s.status = tr('verbinde …');
    notifyListeners();
    try {
      late Transport t;
      switch (s.kind) {
        case TransportKind.usb:
          final p = s.port;
          if (p == null) throw Exception(tr('Kein Anschluss gewählt. ESP32 anstecken und „Suchen“ drücken.'));
          t = await openUsb(p);
          break;
        case TransportKind.node:
          final p = s.port;
          if (p == null) throw Exception(tr('Kein Anschluss gewählt. Kabel vom CP2102 (Node-Konsole) anstecken und „Suchen“ drücken.'));
          s.status = tr('melde mich an der Node an …');
          notifyListeners();
          NodeSerialLink.user = settings.nodeUser;
          NodeSerialLink.password = settings.nodePass;
          t = await NodeSerialLink.channel(p, s.role, log: (x) => _log(s.role, LogKind.info, x));
          break;
        case TransportKind.network:
          t = await TcpTransport.open(settings.piHost, s.role == 'A' ? 2021 : 2022);
          break;
        case TransportKind.demo:
          t = DemoTransport(s.role);
          break;
      }
      final c = ModemClient(t);
      s.client = c;
      s._sub = c.events.listen((e) => _onEvent(s, e));
      // Der ESP32 kann beim Öffnen neu starten – ein paar Mal versuchen
      var ok = false;
      for (var i = 0; i < 15 && !ok; i++) {
        try {
          ok = await c.ping();
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      if (!ok) throw Exception(tr('Modem antwortet nicht. Läuft die LR2021-Firmware auf diesem ESP32?'));
      final info = await c.info();
      s.info = info;
      if (info.role != s.role) {
        final other = slot(info.role);
        if (!other.connected) {
          // richtig einsortieren
          _moveClient(s, other);
          _log(info.role, LogKind.info, tr('Das ist {0} ({1}) – automatisch dort eingetragen', [other.espName, other.band]));
          s.connecting = false;
          s.status = tr('nicht verbunden');
          await _afterConnect(other);
          return;
        }
        throw Exception(tr('Hier ist {0} angeschlossen, nicht {1}.', [other.espName, s.espName]));
      }
      await _afterConnect(s);
    } catch (e) {
      s.error = e.toString().replaceFirst('Exception: ', '');
      s.status = tr('Fehler');
      _log(s.role, LogKind.err, tr('Verbinden fehlgeschlagen'), s.error!);
      await s.client?.close();
      await s._sub?.cancel();
      s.client = null;
    } finally {
      s.connecting = false;
      notifyListeners();
    }
  }

  void _moveClient(ModemSlot from, ModemSlot to) {
    to.client = from.client;
    to.info = from.info;
    to.kind = from.kind;
    to.port = from.port;
    from._sub?.cancel();
    to._sub = to.client!.events.listen((e) => _onEvent(to, e));
    from.client = null;
    from.info = null;
  }

  Future<void> _afterConnect(ModemSlot s) async {
    final info = s.info!;
    s.connecting = false;
    s.error = null;
    if (!info.radioOk) {
      s.error = tr('Funkchip meldet Fehler (Init-Code {0}). Lötstellen/Steckverbindung prüfen.', [info.initCode]);
    }
    if (info.role == 'A' && settings.myNum == 0) {
      settings.myNum = 0x4C520000 | (info.chipId & 0xFFFF);
      _scheduleSave();
    }
    if (s.role == 'A') {
      settings.lastKindA = s.kind.name;
      settings.lastPortA = s.port?.id ?? '';
    } else {
      settings.lastKindB = s.kind.name;
      settings.lastPortB = s.port?.id ?? '';
    }
    _scheduleSave();
    _log(s.role, LogKind.info, tr('Verbunden: Firmware {0}, {1}, Chip {2}', [info.firmware, info.bandName, info.chipHex]),
        tr('via {0}, Temp {1} °C', [s.client!.transport.label, info.tempC.toStringAsFixed(1)]));
    await applyMode(s);
    unawaited(refreshStats(s));
    if (s.kind == TransportKind.node) {
      // Node-Kabel: das andere Modem gleich mitverbinden und GPS darüber holen
      final o = s == a ? b : a;
      if (!o.connected && !o.connecting && !o.manualOff && (o.kind == TransportKind.node || o.kind == TransportKind.demo || _lastKind(o).isEmpty || o.kind == TransportKind.usb)) {
        o.kind = TransportKind.node;
        o.port = s.port;
        unawaited(connect(o));
      }
      _attachSerialGps();
    }
  }

  void _attachSerialGps() {
    final l = NodeSerialLink.active;
    if (l == null || (settings.gpsSource != 'node' && settings.gpsSource != 'auto')) return;
    unawaited(l.gpsOn(true));
    nodeGps.attachLines(l.gpsLines, (f) => _applyFix(f, tr('Node')));
  }

  Future<void> disconnect(ModemSlot s, {bool quiet = false}) async {
    if (!quiet) {
      s.manualOff = true;
      s._reconnect?.cancel();
    }
    if (s.kind == TransportKind.demo) purgeDemo();
    final c = s.client;
    await s._sub?.cancel();
    s._sub = null;
    s.client = null;
    s.config = null;
    s.liveRssi = null;
    s._queue.clear();
    s.transmitting = false;
    if (c != null) {
      try {
        await c.standby().timeout(const Duration(milliseconds: 500));
      } catch (_) {}
      await c.close();
      if (!quiet) _log(s.role, LogKind.info, tr('Getrennt'));
    }
    s.status = tr('nicht verbunden');
    notifyListeners();
  }

  // ------------------------------------------------------------------ Betriebsart
  int _corr(ModemSlot s) => s.role == 'A' ? settings.freqCorrA : settings.freqCorrB;
  int _override(ModemSlot s) => s.role == 'A' ? settings.overrideFreqA : settings.overrideFreqB;
  double antGain(ModemSlot s) => s.role == 'A' ? settings.antGainHf : settings.antGainLf;

  /// Grundeinstellung der Betriebsart (ohne Leistung und Frequenzkorrektur).
  LoraCfg baseCfg(ModemSlot s, RadioMode m) {
    switch (m) {
      case RadioMode.meshtastic:
        final p = mtPresets[settings.mtPreset];
        final region = s.role == 'A' ? mtRegion868 : mtRegion433;
        final name = settings.channels.isNotEmpty ? settings.channels.first.name : p.name;
        var f = mtFrequency(region, p.bwHz, name.isEmpty ? p.name : name);
        if (_override(s) != 0) f = _override(s);
        return LoraCfg(freqHz: f, bwHz: p.bwHz, sf: p.sf, cr: p.cr, sync: 0x2B, powerDbm: 0, preamble: 16);
      case RadioMode.meshcore:
        return LoraCfg(freqHz: 869618000, bwHz: 62500, sf: 8, cr: 8, sync: 0x12, powerDbm: 0, preamble: 8);
      case RadioMode.lrfunk:
        if (s.role == 'A') {
          return LoraCfg(freqHz: 869525000, bwHz: 125000, sf: 9, cr: 5, sync: 0x12, powerDbm: 0, preamble: 8);
        }
        return settings.lrCfg.copy();
      case RadioMode.manual:
        return (s.role == 'A' ? settings.manualA : settings.manualB).copy();
    }
  }

  /// Erlaubte Höchstleistung für die aktuelle Betriebsart dieses Moduls.
  PowerLimit limitFor(ModemSlot s, [RadioMode? mode]) {
    final c = baseCfg(s, mode ?? modeOf(s));
    return powerLimit(c.freqHz, bwHz: c.bwHz, licensed: settings.licensed, antennaGainDbi: antGain(s));
  }

  int manualPower(ModemSlot s) => s.role == 'A' ? settings.powerHf : settings.powerLf;

  void setManualPower(ModemSlot s, int dbm) {
    if (s.role == 'A') {
      settings.powerHf = dbm;
    } else {
      settings.powerLf = dbm;
    }
    changed(save: true);
  }

  /// Amateurfunk-Betrieb: Lizenz an und Frequenz im Amateurfunkband.
  /// Dann: volle Leistung, aber unverschlüsselt und mit Rufzeichen (wie Meshtastic „licensed“).
  bool hamMode(ModemSlot s) => settings.licensed && hamBandFor(baseCfg(s, modeOf(s)).freqHz) != null;

  LoraCfg cfgFor(ModemSlot s, RadioMode m) {
    final c = baseCfg(s, m);
    final lim = powerLimit(c.freqHz, bwHz: c.bwHz, licensed: settings.licensed, antennaGainDbi: antGain(s));
    final want = m == RadioMode.manual ? c.powerDbm : (settings.powerAuto ? lim.maxDbm : manualPower(s));
    c.powerDbm = lim.allowed ? (want > lim.maxDbm ? lim.maxDbm : want) : 0;
    c.freqHz += _corr(s);
    return c;
  }

  List<RadioMode> modesFor(ModemSlot s) => s.role == 'A'
      ? [RadioMode.meshtastic, RadioMode.meshcore, RadioMode.lrfunk, RadioMode.manual]
      : [RadioMode.lrfunk, RadioMode.meshtastic, RadioMode.manual];

  /// Kanal für Meshtastic auf diesem Modul (im Amateurfunk-Betrieb ohne Schlüssel).
  MtChannel mtChannel(ModemSlot s, [int index = 0]) {
    final ch = settings.channels[index < settings.channels.length ? index : 0];
    return hamMode(s) ? MtChannel(ch.name, 'AA==') : ch;
  }

  /// Kanäle zum Entschlüsseln: eigene plus dieselben unverschlüsselt (Funkamateure).
  List<MtChannel> get _rxChannels => [
        ...settings.channels,
        for (final c in settings.channels) MtChannel(c.name, 'AA=='),
      ];

  Future<void> setMode(ModemSlot s, RadioMode m) async {
    if (s.role == 'A') {
      settings.modeA = m;
    } else {
      settings.modeB = m;
    }
    _scheduleSave();
    notifyListeners();
    if (s.connected) await applyMode(s);
  }

  Future<String?> applyMode(ModemSlot s) async {
    final c = s.client;
    if (c == null) return tr('nicht verbunden');
    final m = modeOf(s);
    final cfg = cfgFor(s, m);
    try {
      s.status = tr('stelle ein …');
      notifyListeners();
      // Der LR2021 kalibriert sein Empfangs-Frontend nur bei einem Frequenzwechsel von mindestens 20 MHz.
      // Deshalb kurz auf eine 30 MHz entfernte Frequenz und zurück – sonst empfängt er unkalibriert (Fehler 0x0200).
      if (s.kind != TransportKind.demo) {
        final f = cfg.freqHz;
        final upper = f > 2000000000 ? 2500000000 : (s.info?.subMaxHz ?? f + 40000000);
        final shifted = cfg.copy()
          ..freqHz = f + (f + 31000000 <= upper ? 30000000 : -30000000)
          ..powerDbm = 0;
        try {
          await c.setLora(shifted);
        } catch (_) {}
      }
      await c.setLora(cfg);
      await c.rxStart();
      s.config = await c.config();
      s.status = tr('Empfang');
      final lim = limitFor(s, m);
      _log(s.role, LogKind.info, tr('{0}: {1}, {2} dBm{3}', [radioModeName(m), cfg.summary, cfg.powerDbm, hamMode(s) ? tr(', Amateurfunk (unverschlüsselt)') : '']),
          lim.reason);
      if (!lim.allowed) _log(s.role, LogKind.warn, tr('Senden hier nicht erlaubt: {0}', [lim.reason]));
      if (m == RadioMode.meshtastic) {
        Timer(const Duration(seconds: 2), () => sendNodeInfo(wantResponse: true));
      }
      notifyListeners();
      return null;
    } catch (e) {
      s.status = tr('Fehler');
      s.error = tr('Einstellen fehlgeschlagen: {0}', [e]);
      _log(s.role, LogKind.err, tr('Einstellen fehlgeschlagen'), '$e');
      notifyListeners();
      return '$e';
    }
  }

  Future<String?> run(ModemSlot s, String what, Future<void> Function(ModemClient c) f) async {
    final c = s.client;
    if (c == null) return tr('nicht verbunden');
    try {
      await f(c);
      _log(s.role, LogKind.info, what);
      try {
        s.config = await c.config();
      } catch (_) {}
      notifyListeners();
      return null;
    } catch (e) {
      _log(s.role, LogKind.err, '$what fehlgeschlagen', '$e');
      notifyListeners();
      return '$e';
    }
  }

  Future<void> refreshStats(ModemSlot s) async {
    final c = s.client;
    if (c == null) return;
    try {
      s.stats = await c.stats();
      s.info = await c.info();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _pollRssi(ModemSlot s) async {
    try {
      final v = await s.client!.rssi();
      s.liveRssi = v;
      notifyListeners();
    } catch (_) {}
  }

  int _tickCount = 0;
  void _onTick() {
    _tickCount++;
    for (final s in slots) {
      if (!s.connected) continue;
      if (rssiPolling && !s.transmitting) unawaited(_pollRssi(s));
      if (_tickCount % 15 == 0) unawaited(refreshStats(s));
    }
    final now = DateTime.now();
    final mt = _slotFor(RadioMode.meshtastic);
    if (mt != null) {
      if (settings.nodeInfoHours > 0 && now.difference(_lastNodeInfo).inMinutes >= settings.nodeInfoHours * 60) {
        sendNodeInfo();
      }
      if (settings.sharePosition && settings.lat != null && now.difference(_lastPosition).inMinutes >= settings.posIntervalMin) {
        sendPosition();
      }
      if (settings.telemetryMin > 0 && now.difference(_lastTelemetry).inMinutes >= settings.telemetryMin) {
        sendTelemetry();
      }
    }
    final lr = _slotFor(RadioMode.lrfunk);
    if (lr != null && settings.lrBeaconMin > 0 && now.difference(_lastBeacon).inMinutes >= settings.lrBeaconMin) {
      sendBeacon();
    }
    if (_tickCount % 60 == 0) {
      _seen.removeWhere((k, t) => now.difference(t).inMinutes > 30);
    }
  }

  // ------------------------------------------------------------------ Senden
  ModemSlot? _slotFor(RadioMode m) {
    if (modeOf(a) == m && a.connected) return a;
    if (modeOf(b) == m && b.connected) return b;
    return null;
  }

  ModemSlot? get meshtasticSlot => _slotFor(RadioMode.meshtastic);
  ModemSlot? get lrSlot => _slotFor(RadioMode.lrfunk);

  void _enqueue(ModemSlot s, Uint8List data, String what, [void Function(TxDoneEvent ev)? done]) {
    s._queue.add(_TxJob(data, what, done));
    _pump(s);
  }

  Future<void> _pump(ModemSlot s) async {
    if (s._txRunning) return;
    s._txRunning = true;
    try {
      while (s._queue.isNotEmpty && s.connected) {
        final job = s._queue.removeAt(0);
        s.transmitting = true;
        notifyListeners();
        _log(s.role, LogKind.tx, job.what, '${job.data.length} B  ${hex(job.data)}');
        TxDoneEvent ev;
        try {
          ev = await s.client!.txWait(job.data, lbt: settings.lbt);
        } catch (e) {
          ev = TxDoneEvent(0, e is ModemError ? e.status : -11, 0);
        }
        s.transmitting = false;
        s.lastTx = DateTime.now();
        if (ev.ok) {
          _log(s.role, LogKind.tx, tr('gesendet ({0} ms)', [(ev.airtimeUs / 1000).toStringAsFixed(0)]));
        } else {
          _log(s.role, LogKind.err, tr('Senden fehlgeschlagen: {0}', [statusText(ev.status)]));
        }
        job.done?.call(ev);
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      s._txRunning = false;
      s.transmitting = false;
    }
  }

  int _newId() => 1 + _rnd.nextInt(0x7FFFFFFE);

  String get myKey => nodeIdStr(settings.myNum);

  /// Text in einen Chat senden. Gibt eine Fehlermeldung zurück oder null.
  String? sendText(String chat, String text) {
    text = text.trim();
    if (text.isEmpty) return null;
    if (chat == 'lr') return _sendLr(text);
    final s = meshtasticSlot;
    if (s == null) return tr('Kein Funkmodul im Meshtastic-Betrieb verbunden (Funk → ESP32 A).');
    if (settings.myNum == 0) return tr('Eigene Knoten-ID fehlt – zuerst ESP32 A verbinden.');
    int dest = broadcastNum;
    var chIdx = 0;
    if (chat.startsWith('dm:')) {
      dest = int.parse(chat.substring(4), radix: 16);
    } else if (chat.startsWith('mt:')) {
      chIdx = int.tryParse(chat.substring(3)) ?? 0;
    }
    if (chIdx >= settings.channels.length) return tr('Kanal existiert nicht mehr.');
    final ch = mtChannel(s, chIdx);
    final dm = dest != broadcastNum;
    for (final part in _split(text, dm ? 180 : 200)) {
      final id = _newId();
      final msg = Message(
          chat: chat,
          from: myKey,
          fromName: settings.longName,
          text: part,
          at: DateTime.now(),
          mine: true,
          status: MsgStatus.pending,
          pktId: id);
      messages.add(msg);
      _awaitAck[id] = msg;
      if (dm && !hamMode(s) && _pkiFor(s, dest) == null) {
        // Meshtastic ab 2.5 nimmt Direktnachrichten nur Ende-zu-Ende verschlüsselt an:
        // erst die Visitenkarte (mit öffentlichem Schlüssel) holen, dann senden.
        msg.info = tr('warte auf Schlüssel der Gegenstelle …');
        _keyWait.putIfAbsent(dest, () => []).add((msg, part));
        final n = nodes[nodeIdStr(dest)];
        if (n != null) {
          requestNodeInfo(n);
        } else {
          sendNodeInfo(dest: dest, wantResponse: true);
        }
        Timer(const Duration(seconds: 90), () {
          final l = _keyWait[dest];
          if (l == null || !l.any((x) => x.$1 == msg)) return;
          l.removeWhere((x) => x.$1 == msg);
          if (l.isEmpty) _keyWait.remove(dest);
          msg.status = MsgStatus.failed;
          msg.info = tr('Schlüssel der Gegenstelle fehlt (Visitenkarte kam nicht)');
          _scheduleSave();
          notifyListeners();
        });
        continue;
      }
      _sendTextPacket(s, msg, part, dest, ch);
    }
    _scheduleSave();
    notifyListeners();
    return null;
  }

  void _sendTextPacket(ModemSlot s, Message msg, String part, int dest, MtChannel ch) {
    final dm = dest != broadcastNum;
    final key = dm ? _pkiFor(s, dest) : null;
    final pkt = buildMtPacket(
      from: settings.myNum,
      id: msg.pktId,
      channel: ch,
      port: Port.text,
      payload: utf8.encode(part),
      dest: dest,
      hopLimit: settings.hopLimit,
      wantAck: dm,
      pkiKey: key,
    );
    if (key != null) msg.info = tr('Ende-zu-Ende verschlüsselt');
    _enqueue(s, pkt, tr('Text → {0}{1}: »{2}«', [dm ? nodeIdStr(dest) : ch.name, key != null ? ' 🔒' : '', part]), (ev) {
      if (msg.status == MsgStatus.pending) {
        msg.status = ev.ok ? MsgStatus.sent : MsgStatus.failed;
        if (!ev.ok) msg.info = statusText(ev.status);
      }
      if (ev.ok) _retryLater(s, msg, pkt, 1);
      _scheduleSave();
    });
  }

  /// Schlüssel eines Knotens ist da: wartende Direktnachrichten senden.
  void _flushKeyWait(int dest) {
    final l = _keyWait.remove(dest);
    final s = meshtasticSlot;
    if (l == null) return;
    for (final (msg, part) in l) {
      if (s == null) {
        msg.status = MsgStatus.failed;
        msg.info = tr('Funkmodul getrennt');
        continue;
      }
      _sendTextPacket(s, msg, part, dest, mtChannel(s));
    }
    notifyListeners();
  }

  /// Wiederholen wie Meshtastic: ohne Bestätigung (Direktnachricht) bzw. ohne gehörte
  /// Weiterleitung (an alle) dasselbe Paket bis zu zweimal erneut senden. Empfänger
  /// erkennen die gleiche Paket-ID und zeigen die Nachricht nur einmal.
  void _retryLater(ModemSlot s, Message msg, Uint8List pkt, int attempt) {
    Timer(Duration(seconds: 15 + 5 * attempt), () {
      if (msg.status != MsgStatus.sent || !s.connected) return;
      if (attempt > 2) {
        if (msg.chat.startsWith('dm:')) {
          msg.status = MsgStatus.failed;
          msg.info = tr('keine Bestätigung');
          notifyListeners();
        }
        return;
      }
      msg.info = tr('Wiederholung {0}', [attempt]);
      _enqueue(s, pkt, tr('Wiederholung {0}: »{1}«', [attempt, msg.text]), (ev) {
        if (ev.ok) _retryLater(s, msg, pkt, attempt + 1);
      });
      notifyListeners();
    });
  }

  String? _sendLr(String text) {
    final s = lrSlot;
    if (s == null) return tr('Kein Funkmodul im LR-Funk-Betrieb verbunden (Funk → ESP32 B).');
    if (settings.callsign.trim().isEmpty) return tr('Bitte zuerst dein Rufzeichen in den Einstellungen eintragen.');
    final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
    for (final part in _split(text, 180)) {
      final id = _newId();
      final pkt = LrPacket.build(LrType.text, me, id, _cut(settings.callsign.trim().toUpperCase(), 12),
          _cut(settings.longName, 39), utf8.encode(part));
      final msg = Message(
          chat: 'lr',
          from: 'lr:${me.toRadixString(16).padLeft(8, '0')}',
          fromName: settings.callsign.toUpperCase(),
          text: part,
          at: DateTime.now(),
          mine: true,
          status: MsgStatus.pending,
          pktId: id);
      messages.add(msg);
      _awaitLrAck[id] = msg;
      _enqueue(s, pkt, tr('LR-Funk Text: »{0}«', [part]), (ev) {
        if (msg.status == MsgStatus.pending) {
          msg.status = ev.ok ? MsgStatus.sent : MsgStatus.failed;
          if (!ev.ok) msg.info = statusText(ev.status);
        }
        _scheduleSave();
      });
    }
    _scheduleSave();
    notifyListeners();
    return null;
  }

  // ------------------------------------------------------------------ Dateien und Bilder (LR-Funk)
  final Map<int, _OutXfer> _outX = {};
  final Map<String, _InXfer> _inX = {};
  final Set<String> _doneX = {};

  /// Geschätzte Sendezeit (s) für [bytes] Byte über LR-Funk.
  double? fileAirtimeS(int bytes) {
    final s = lrSlot;
    final cfg = s?.config?.lora;
    if (cfg == null) return null;
    final n = (bytes / LrFileProto.chunkSize).ceil();
    return n * (cfg.airtimeMs(LrFileProto.chunkSize + 30) + 200) / 1000;
  }

  /// Datei an alle im LR-Funk-Kanal senden. Gibt Fehlertext oder null zurück.
  String? sendFile(Uint8List data, String name, String mime, {String? localPath}) {
    final s = lrSlot;
    if (s == null) return tr('Kein Funkmodul im LR-Funk-Betrieb verbunden (Funk → ESP32 B).');
    if (settings.callsign.trim().isEmpty) return tr('Bitte zuerst dein Rufzeichen in den Einstellungen eintragen.');
    if (data.isEmpty) return tr('Die Datei ist leer.');
    if (data.length > 200 * 1024) return tr('Die Datei ist zu groß (höchstens 200 KB).');
    final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
    final xfer = _newId();
    final chunks = FileChunk.split(data, mime, name, xfer);
    final msg = Message(
        chat: 'lr',
        from: 'lr:${me.toRadixString(16).padLeft(8, '0')}',
        fromName: settings.callsign.toUpperCase(),
        text: name,
        at: DateTime.now(),
        mine: true,
        status: MsgStatus.pending,
        pktId: xfer)
      ..file = localPath
      ..mime = mime
      ..fileSize = data.length
      ..info = tr('{0} Teile', [chunks.length]);
    messages.add(msg);
    final x = _OutXfer(xfer, chunks, msg, s);
    _outX[xfer] = x;
    _sendChunks(x, [for (var i = 0; i < chunks.length; i++) i]);
    _scheduleSave();
    notifyListeners();
    return null;
  }

  void _sendChunks(_OutXfer x, List<int> idx) {
    final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
    final call = _cut(settings.callsign.trim().toUpperCase(), 12);
    var left = idx.length;
    for (final i in idx) {
      final pkt = LrPacket.build(LrType.file, me, _newId(), call, '', x.chunks[i]);
      _enqueue(x.slot, pkt, tr('Datei {0}: Teil {1}/{2}', [x.msg.text, i + 1, x.chunks.length]), (ev) {
        x.sent.add(i);
        x.msg.progress = x.sent.length / x.chunks.length * (x.round == 0 ? 1 : 1);
        if (!ev.ok) x.msg.info = statusText(ev.status);
        left--;
        if (left == 0) _awaitFileAck(x);
        notifyListeners();
      });
    }
    x.msg.status = MsgStatus.pending;
  }

  void _awaitFileAck(_OutXfer x) {
    x.timer?.cancel();
    x.msg.status = MsgStatus.sent;
    x.msg.info = tr('gesendet, warte auf Bestätigung …');
    x.timer = Timer(const Duration(seconds: 8), () {
      if (x.finished) return;
      if (x.probes >= 3) {
        x.finished = true;
        x.msg.info = x.ackedBy.isEmpty ? tr('keine Bestätigung') : tr('empfangen von {0}', [x.ackedBy.join(', ')]);
        _outX.remove(x.xfer);
        _scheduleSave();
        notifyListeners();
        return;
      }
      // Nachfragen: letztes Stück noch einmal senden, darauf antworten die Empfänger
      x.probes++;
      _sendChunks(x, [x.chunks.length - 1]);
    });
  }

  void _onFileAck(LrPacket p, String who) {
    final a = FileAck.parse(p.body);
    if (a == null) return;
    final x = _outX[a.xfer];
    if (x == null) return;
    if (a.done) {
      if (!x.ackedBy.contains(who)) x.ackedBy.add(who);
      x.msg.status = MsgStatus.acked;
      x.msg.progress = 1;
      x.msg.info = tr('empfangen von {0}', [x.ackedBy.join(', ')]);
      x.finished = true;
      x.timer?.cancel();
      _scheduleSave();
    } else if (a.missing.isNotEmpty && x.round < 8) {
      x.round++;
      x.timer?.cancel();
      x.msg.info = tr('{0} Teile fehlen bei {1} – sende erneut', [a.missing.length, who]);
      _sendChunks(x, a.missing.where((i) => i < x.chunks.length).toList());
    }
    notifyListeners();
  }

  void _onFileChunk(ModemSlot s, LrPacket p, String key, String who, RxEvent e) {
    final c = FileChunk.parse(p.body);
    if (c == null) return;
    final xkey = '$key:${c.xfer}';
    if (_doneX.contains(xkey)) {
      // schon komplett: erneut bestätigen (Sender hat die Bestätigung verpasst)
      if (c.index == c.count - 1) _sendFileAck(s, c.xfer, true, const []);
      return;
    }
    final x = _inX.putIfAbsent(xkey, () {
      final m = Message(
          chat: 'lr',
          from: key,
          fromName: who,
          text: tr('Datei wird empfangen …'),
          at: e.at,
          mine: false,
          status: MsgStatus.received,
          pktId: c.xfer,
          rssi: e.rssi,
          snr: e.snr,
          hops: 0)
        ..fileSize = c.size;
      messages.add(m);
      if (openChat != 'lr') unread['lr'] = (unread['lr'] ?? 0) + 1;
      return _InXfer(c.xfer, c.count, c.size, m);
    });
    if (c.index == 0) {
      x.name = c.name ?? '';
      x.mime = c.mime ?? '';
      x.msg.mime = x.mime;
    }
    x.parts[c.index] = c.data;
    x.msg.progress = x.parts.length / x.count;
    x.msg.info = tr('{0} von {1} Teilen', [x.parts.length, x.count]);
    x.timer?.cancel();
    if (x.parts.length == x.count) {
      unawaited(_finishIn(s, xkey, x));
      return;
    }
    // nach dem letzten Stück (oder 4 s Pause) melden, was fehlt
    x.timer = Timer(Duration(milliseconds: c.index == c.count - 1 ? 600 + _rnd.nextInt(900) : 4000), () {
      final miss = [for (var i = 0; i < x.count; i++) if (!x.parts.containsKey(i)) i];
      _sendFileAck(s, c.xfer, false, miss);
    });
    notifyListeners();
  }

  Future<void> _finishIn(ModemSlot s, String xkey, _InXfer x) async {
    _inX.remove(xkey);
    _doneX.add(xkey);
    final b = BytesBuilder();
    for (var i = 0; i < x.count; i++) {
      b.add(x.parts[i]!);
    }
    final data = b.toBytes();
    var name = x.name.isEmpty ? 'lr2021_${x.xfer.toRadixString(16)}' : x.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    try {
      final dir = await getApplicationDocumentsDirectory();
      final d = Directory('${dir.path}${Platform.pathSeparator}LR2021${Platform.pathSeparator}received');
      await d.create(recursive: true);
      var f = File('${d.path}${Platform.pathSeparator}$name');
      var k = 1;
      while (await f.exists()) {
        final dot = name.lastIndexOf('.');
        final n2 = dot > 0 ? '${name.substring(0, dot)}_$k${name.substring(dot)}' : '${name}_$k';
        f = File('${d.path}${Platform.pathSeparator}$n2');
        k++;
      }
      await f.writeAsBytes(data);
      x.msg.file = f.path;
    } catch (err) {
      _log('App', LogKind.err, tr('Datei konnte nicht gespeichert werden'), '$err');
    }
    x.msg
      ..text = x.name.isEmpty ? tr('Datei') : x.name
      ..mime = x.mime.isEmpty ? mimeFor(name) : x.mime
      ..progress = 1
      ..info = '';
    _log(s.role, LogKind.rx, tr('Datei von {0} empfangen: {1} ({2} B)', [x.msg.fromName, x.msg.text, data.length]));
    if (settings.sound) SystemSound.play(SystemSoundType.alert);
    _sendFileAck(s, x.xfer, true, const []);
    _scheduleSave();
    notifyListeners();
  }

  void _sendFileAck(ModemSlot s, int xfer, bool done, List<int> missing) {
    if (settings.callsign.trim().isEmpty) return; // ohne Rufzeichen wird im Amateurfunk nicht gesendet
    final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
    final pkt = LrPacket.build(LrType.fileAck, me, _newId(), _cut(settings.callsign.trim().toUpperCase(), 12), '',
        FileAck.build(xfer, done, missing));
    _enqueue(s, pkt, done ? tr('Datei bestätigt') : tr('Datei: {0} Teile fehlen', [missing.length]));
  }

  void sendBeacon() {
    final s = lrSlot;
    _lastBeacon = DateTime.now();
    if (s == null || settings.callsign.trim().isEmpty) return;
    final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
    final pkt = LrPacket.build(LrType.beacon, me, _newId(), _cut(settings.callsign.trim().toUpperCase(), 12),
        _cut(settings.longName, 39), const []);
    _enqueue(s, pkt, tr('LR-Funk Bake'));
  }

  List<ModemSlot> get meshtasticSlots => [for (final x in slots) if (x.connected && modeOf(x) == RadioMode.meshtastic) x];

  static const _roleIds = {'client': 0, 'client_mute': 1, 'router': 2};

  void sendNodeInfo({int dest = broadcastNum, bool wantResponse = false}) {
    _lastNodeInfo = DateTime.now();
    if (settings.myNum == 0) return;
    for (final s in meshtasticSlots) {
      final ham = hamMode(s);
      final call = settings.callsign.trim().toUpperCase();
      final long = ham && call.isNotEmpty ? _cut('$call ${settings.longName}', 39) : settings.longName;
      final pkt = buildMtPacket(
        from: settings.myNum,
        id: _newId(),
        channel: mtChannel(s),
        port: Port.nodeinfo,
        payload: userPayload(settings.myNum, long, settings.shortName,
            licensed: ham, role: _roleIds[settings.mtRole] ?? 0, publicKey: ham ? null : myPublicKey),
        dest: dest,
        hopLimit: settings.hopLimit,
        wantResponse: wantResponse,
      );
      _enqueue(s, pkt, tr('Visitenkarte → {0}', [dest == broadcastNum ? 'alle' : nodeIdStr(dest)]));
    }
  }

  void sendPosition({int dest = broadcastNum}) {
    if (dest == broadcastNum) _lastPosition = DateTime.now();
    final lat = settings.lat, lon = settings.lon;
    if (lat == null || lon == null || settings.myNum == 0) return;
    for (final s in meshtasticSlots) {
      final pkt = buildMtPacket(
        from: settings.myNum,
        id: _newId(),
        channel: mtChannel(s),
        port: Port.position,
        payload: positionPayload(lat, lon, altM: settings.alt, precisionBits: settings.posPrecision),
        dest: dest,
        hopLimit: settings.hopLimit,
      );
      _enqueue(s, pkt, tr('Position {0}, {1}{2}', [lat.toStringAsFixed(5), lon.toStringAsFixed(5), dest == broadcastNum ? '' : ' → ${nodeIdStr(dest)}']));
    }
  }

  /// Eigene Telemetrie (Sendezeit-Anteil, Laufzeit) wie ein Meshtastic-Gerät.
  void sendTelemetry({int dest = broadcastNum}) {
    if (dest == broadcastNum) _lastTelemetry = DateTime.now();
    if (settings.myNum == 0) return;
    for (final s in meshtasticSlots) {
      final st = s.stats;
      final up = s.info?.uptimeMs;
      final pkt = buildMtPacket(
        from: settings.myNum,
        id: _newId(),
        channel: mtChannel(s),
        port: Port.telemetry,
        payload: deviceTelemetryPayload(
          airUtilTx: st == null ? null : st.airtimeHourMs / 36000.0,
          uptimeS: up == null ? null : up ~/ 1000,
          batteryLevel: 101, // Netzbetrieb
        ),
        dest: dest,
        hopLimit: settings.hopLimit,
        pkiKey: _pkiFor(s, dest),
      );
      _enqueue(s, pkt, tr('Telemetrie{0}', [dest == broadcastNum ? '' : ' → ${nodeIdStr(dest)}']));
    }
  }

  /// Visitenkarte (Name, Kürzel, Gerät) eines Knotens anfordern.
  String? requestNodeInfo(Node n) {
    if (n.net != Net.mt) return tr('Nur für Meshtastic-Knoten.');
    if (meshtasticSlot == null) return tr('Kein Funkmodul im Meshtastic-Betrieb verbunden.');
    if (settings.myNum == 0) return tr('Eigene Knoten-ID fehlt.');
    n.askedInfo = DateTime.now();
    sendNodeInfo(dest: n.num, wantResponse: true);
    notifyListeners();
    return null;
  }

  /// Position eines Knotens anfordern (eigene Position geht mit, wenn Teilen an ist).
  String? requestPosition(Node n) {
    final s = meshtasticSlot;
    if (s == null) return tr('Kein Funkmodul im Meshtastic-Betrieb verbunden.');
    if (n.net != Net.mt) return tr('Nur für Meshtastic-Knoten.');
    if (settings.myNum == 0) return tr('Eigene Knoten-ID fehlt.');
    final lat = settings.lat, lon = settings.lon;
    final pkt = buildMtPacket(
      from: settings.myNum,
      id: _newId(),
      channel: mtChannel(s),
      port: Port.position,
      payload: settings.sharePosition && lat != null && lon != null
          ? positionPayload(lat, lon, altM: settings.alt, precisionBits: settings.posPrecision)
          : const <int>[],
      dest: n.num,
      hopLimit: settings.hopLimit,
      wantResponse: true,
    );
    _enqueue(s, pkt, tr('Position anfordern von {0}', [n.display]));
    return null;
  }

  /// Gerätewerte (Akku, Spannung, Kanalauslastung) eines Knotens anfordern.
  String? requestTelemetry(Node n) {
    final s = meshtasticSlot;
    if (s == null) return tr('Kein Funkmodul im Meshtastic-Betrieb verbunden.');
    if (n.net != Net.mt) return tr('Nur für Meshtastic-Knoten.');
    if (settings.myNum == 0) return tr('Eigene Knoten-ID fehlt.');
    final pkt = buildMtPacket(
      from: settings.myNum,
      id: _newId(),
      channel: mtChannel(s),
      port: Port.telemetry,
      payload: telemetryRequestPayload(),
      dest: n.num,
      hopLimit: settings.hopLimit,
      wantResponse: true,
      pkiKey: _pkiFor(s, n.num),
    );
    _enqueue(s, pkt, tr('Telemetrie anfordern von {0}', [n.display]));
    return null;
  }

  void setFavorite(Node n, bool v) {
    n.favorite = v;
    changed(save: true);
  }

  void setIgnored(Node n, bool v) {
    n.ignored = v;
    changed(save: true);
  }

  Future<String?> rawTx(ModemSlot s, Uint8List data) async {
    if (!s.connected) return tr('nicht verbunden');
    _enqueue(s, data, tr('Rohdaten ({0} B)', [data.length]));
    return null;
  }

  final NodeGps nodeGps = NodeGps();
  String gpsFrom = '';

  void _applyFix(GpsFix f, String from) {
    settings.lat = f.lat;
    settings.lon = f.lon;
    if (f.alt != null && f.alt != 0) settings.alt = f.alt!.round();
    gpsAccuracy = f.accuracy;
    gpsFrom = from;
    changed(save: true);
  }

  bool get _nodeFixFresh => nodeGps.lastFix != null && DateTime.now().difference(nodeGps.lastFix!).inSeconds < 30;

  /// GPS-Quelle anwenden: aus / geraet / node / auto (Node bevorzugt, sonst Gerät).
  Future<String?> setGpsSource(String src) async {
    settings.gpsSource = src;
    nodeGps.stop();
    await gps.stop();
    String? err;
    if (src == 'node' || src == 'auto') {
      if (NodeSerialLink.active != null) {
        _attachSerialGps();
      } else {
        nodeGps.start(settings.piHost, (f) => _applyFix(f, tr('Node')));
      }
    }
    if (src == 'geraet' || src == 'auto') {
      err = await gps.start((f) {
        if (src == 'auto' && _nodeFixFresh) return; // Node-GPS hat Vorrang
        _applyFix(f, tr('Gerät'));
      });
      if (err != null) _log(tr('App'), LogKind.warn, tr('Geräte-GPS: {0}', [err]));
      if (src == 'auto') err = null; // Node-GPS kann trotzdem liefern
    }
    changed(save: true);
    return err;
  }

  String get gpsStatus {
    switch (settings.gpsSource) {
      case 'aus':
        return 'aus';
      case 'geraet':
        return gps.running ? tr('Gerät{0}', [gpsAccuracy != null ? tr(' · ± {0} m', [gpsAccuracy!.toStringAsFixed(0)]) : '']) : (gps.error ?? tr('Gerät nicht verfügbar'));
      case 'node':
        return tr('Node: {0}', [nodeGps.status]);
      default:
        return _nodeFixFresh ? tr('Node: {0}', [nodeGps.status]) : (gps.running ? tr('Gerät (Node: {0})', [nodeGps.status]) : tr('Node: {0}', [nodeGps.status]));
    }
  }

  /// Einmalig orten. Gibt Fehlertext oder null zurück.
  Future<String?> locateOnce() async {
    final f = await gps.once();
    if (f == null) return gps.error ?? tr('Keine Position');
    _applyFix(f, tr('Gerät'));
    return null;
  }

  void setMyPosition(double lat, double lon) {
    settings.lat = lat;
    settings.lon = lon;
    changed(save: true);
  }

  Waypoint addWaypoint(double lat, double lon, String name, {String description = ''}) {
    final wp = Waypoint(id: _newId(), name: name, lat: lat, lon: lon, from: 'ich', at: DateTime.now(), description: description);
    waypoints.add(wp);
    changed(save: true);
    return wp;
  }

  void deleteWaypoint(Waypoint w) {
    waypoints.remove(w);
    changed(save: true);
  }

  /// Wegpunkt an alle im Meshtastic-Netz senden. Gibt Fehlertext oder null zurück.
  String? sendWaypoint(Waypoint w) {
    final s = meshtasticSlot;
    if (s == null) return tr('Kein Funkmodul im Meshtastic-Betrieb verbunden.');
    if (settings.myNum == 0) return tr('Eigene Knoten-ID fehlt.');
    final pkt = buildMtPacket(
      from: settings.myNum,
      id: _newId(),
      channel: mtChannel(s),
      port: Port.waypoint,
      payload: waypointPayload(id: w.id, lat: w.lat, lon: w.lon, name: _cut(w.name, 30), description: _cut(w.description, 100)),
      hopLimit: settings.hopLimit,
    );
    _enqueue(s, pkt, tr('Wegpunkt »{0}«', [w.name]));
    return null;
  }

  /// Route zu einem Knoten ermitteln (Meshtastic-Traceroute) und Laufzeit messen.
  String? traceroute(Node n) {
    final s = meshtasticSlot;
    if (s == null) return tr('Kein Funkmodul im Meshtastic-Betrieb verbunden.');
    if (n.net != Net.mt) return tr('Nur für Meshtastic-Knoten.');
    if (settings.myNum == 0) return tr('Eigene Knoten-ID fehlt.');
    final id = _newId();
    final pkt = buildMtPacket(
      from: settings.myNum,
      id: id,
      channel: mtChannel(s),
      port: Port.traceroute,
      payload: const [],
      dest: n.num,
      hopLimit: settings.hopLimit,
      wantResponse: true,
    );
    _traceReq[id] = (n.key, DateTime.now());
    n.route = tr('wird ermittelt …');
    _enqueue(s, pkt, tr('Route zu {0}', [n.display]), (ev) {
      final req = _traceReq[id];
      if (req != null) _traceReq[id] = (req.$1, DateTime.now()); // Laufzeit ab Sendeende
    });
    notifyListeners();
    return null;
  }

  String _nameOf(int num) => nodes[nodeIdStr(num)]?.display ?? nodeIdStr(num);

  static List<String> _split(String text, int maxBytes) {
    final out = <String>[];
    var rest = text;
    while (rest.isNotEmpty) {
      var n = rest.length;
      while (utf8.encode(rest.substring(0, n)).length > maxBytes) {
        n--;
      }
      // Surrogatpaare (Emoji) nicht zerschneiden
      if (n < rest.length && n > 0 && (rest.codeUnitAt(n - 1) & 0xFC00) == 0xD800) n--;
      out.add(rest.substring(0, n));
      rest = rest.substring(n);
    }
    return out;
  }

  static String _cut(String s, int maxBytes) {
    var t = s;
    while (utf8.encode(t).length > maxBytes && t.isNotEmpty) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  // ------------------------------------------------------------------ Empfang
  void _onEvent(ModemSlot s, ModemEvent e) {
    if (e is RxEvent) {
      s.lastRx = e.at;
      s.lastRxRssi = e.rssi;
      _onRx(s, e);
    } else if (e is LogEvent) {
      _log(s.role, e.level >= 2 ? LogKind.err : (e.level == 1 ? LogKind.warn : LogKind.log), e.text);
    } else if (e is BootEvent) {
      if (e.info != null) s.info = e.info;
      _log(s.role, LogKind.warn, tr('ESP32 hat neu gestartet – stelle Betriebsart wieder ein'));
      Timer(const Duration(milliseconds: 800), () => applyMode(s));
    } else if (e is ErrorEvent) {
      _log(s.role, LogKind.err, tr('Modem-Fehler {0}', [statusText(e.code)]), 'RadioLib ${e.radioCode}');
    } else if (e is DisconnectEvent) {
      final c = s.client;
      if (c != null) {
        s.error = e.reason;
        s.status = 'getrennt';
        _log(s.role, LogKind.err, tr('Verbindung verloren'), e.reason);
        s.client = null;
        s._queue.clear();
        s._sub?.cancel();
        s._sub = null;
        unawaited(c.close());
        _scheduleReconnect(s);
      }
    }
    notifyListeners();
  }

  String _sig(RxEvent e) =>
      tr('{0} dBm · SNR {1} · Δf {2} kHz', [e.rssi.toStringAsFixed(0), e.snr.toStringAsFixed(1), (e.freqErr / 1000).toStringAsFixed(1)]);

  void _onRx(ModemSlot s, RxEvent e) {
    if (e.crcError) {
      _log(s.role, LogKind.warn, tr('Paket mit CRC-Fehler ({0} B)', [e.data.length]), '${_sig(e)}  ${hex(e.data)}');
      return;
    }
    switch (modeOf(s)) {
      case RadioMode.meshtastic:
        _onMeshtastic(s, e);
        break;
      case RadioMode.meshcore:
        _onMeshCore(s, e);
        break;
      case RadioMode.lrfunk:
        _onLr(s, e);
        break;
      case RadioMode.manual:
        final t = String.fromCharCodes(e.data.where((c) => c >= 0x20 && c < 0x7F));
        _log(s.role, LogKind.rx, tr('Paket {0} B{1}', [e.data.length, t.length > 3 ? ' »$t«' : '']), '${_sig(e)}  ${hex(e.data)}');
        break;
    }
  }

  Node _node(String key, Net net, int num, ModemSlot s, RxEvent e, {int? hops}) {
    if (s.kind == TransportKind.demo) _demoKeys.add(key);
    final n = nodes.putIfAbsent(key, () => Node(key, net, num, e.at));
    n.lastHeard = e.at;
    n.packets++;
    n.via = s.band;
    if (hops == null || hops == 0) {
      n.rssi = e.rssi;
      n.snr = e.snr;
    }
    if (hops != null) n.hops = hops;
    if (hops == null || hops == 0) {
      n.history.add((e.at, e.snr));
      if (n.history.length > 60) n.history.removeAt(0);
    }
    _writeCsv(s, n, e, hops);
    return n;
  }

  void _writeCsv(ModemSlot s, Node n, RxEvent e, int? hops) {
    final c = _csv;
    if (c == null) return;
    final lat = settings.lat, lon = settings.lon;
    String f(double? v, [int d = 6]) => v == null ? '' : v.toStringAsFixed(d);
    final dist = (lat != null && lon != null && n.hasPos) ? geoDistance(lat, lon, n.lat!, n.lon!).$1 : null;
    final name = n.display.replaceAll(';', ',');
    c.writeln('${e.at.toIso8601String()};${s.band};${netName(n.net)};${n.key};$name;' '${e.rssi.toStringAsFixed(1)};${e.snr.toStringAsFixed(1)};${hops ?? ''};${f(n.lat)};${f(n.lon)};${f(lat)};${f(lon)};${f(dist, 3)}');
  }

  /// Notruf: Text mit Position an alle (Meshtastic, sonst LR-Funk) und Position hinterher.
  String? sendSos() {
    final lat = settings.lat, lon = settings.lon;
    final pos = (lat != null && lon != null) ? tr(' Position {0} ({1}, {2})', [toMgrs(lat, lon), lat.toStringAsFixed(5), lon.toStringAsFixed(5)]) : tr(' Position unbekannt');
    final text = tr('🆘 NOTRUF von {0}.{1}', [settings.longName, pos]);
    String? err;
    if (meshtasticSlot != null) {
      err = sendText('mt:0', text);
      if (err == null && lat != null) sendPosition();
    } else if (lrSlot != null) {
      err = sendText('lr', text);
    } else {
      err = tr('Kein Funkmodul verbunden.');
    }
    return err;
  }

  void _onMeshtastic(ModemSlot s, RxEvent e) {
    final p = MtPacket.parse(e.data);
    if (p == null) {
      _log(s.role, LogKind.rx, tr('Kein Meshtastic-Paket ({0} B)', [e.data.length]), '${_sig(e)}  ${hex(e.data)}');
      return;
    }
    final me = settings.myNum;
    // Eigenes Paket wurde weitergeleitet (die Frequenz des weiterleitenden Knotens taugt auch zum Messen)
    if (p.from == me && me != 0) {
      _trackFreqErr(s, e);
      final m = _awaitAck[p.id];
      if (m != null && (m.status == MsgStatus.sent || m.status == MsgStatus.pending)) {
        m.status = MsgStatus.relayed;
        m.info = tr('weitergeleitet von …{0}', [p.relay.toRadixString(16).padLeft(2, '0')]);
        _scheduleSave();
      }
      _log(s.role, LogKind.rx, tr('Eigenes Paket weitergeleitet von Knoten …{0}', [p.relay.toRadixString(16).padLeft(2, '0')]),
          _sig(e));
      return;
    }
    final dupKey = 'mt:${p.from}:${p.id}';
    final dup = _seen.containsKey(dupKey);
    _seen[dupKey] = e.at;
    final key = nodeIdStr(p.from);
    var ok = false;
    if (p.looksPki && p.dest == me && me != 0) {
      final sk = sharedKeyFor(nodes[key]);
      if (sk != null) {
        ok = p.decryptPki(sk);
        if (!ok) _log(s.role, LogKind.warn, tr('Direktnachricht von {0} nicht entschlüsselbar (Schlüssel geändert?)', [nodes[key]?.display ?? key]));
      } else {
        _log(s.role, LogKind.warn, tr('Verschlüsselte Direktnachricht von {0} – Schlüssel unbekannt, frage Visitenkarte an', [nodes[key]?.display ?? key]));
        final last = _nodeInfoAsked[p.from];
        if (last == null || e.at.difference(last).inMinutes >= 2) {
          _nodeInfoAsked[p.from] = e.at;
          Timer(Duration(milliseconds: 800 + _rnd.nextInt(1200)), () => sendNodeInfo(dest: p.from, wantResponse: true));
        }
      }
    }
    if (!ok) ok = p.decrypt(_rxChannels);
    final title = '${nodes[key]?.display ?? key} → ${p.isBroadcast ? 'alle' : (p.dest == me ? 'mich' : nodeIdStr(p.dest))}' ' · ${p.portName}${p.pki ? ' 🔒' : ''}${ok ? ' ${describeApp(p)}' : ''}${dup ? ' (Wiederholung)' : ''}';
    _log(s.role, LogKind.rx, title,
        tr('{0} · Hops {1}/{2} · Kanal-Hash {3} · ID {4}  {5}', [_sig(e), p.hopsAway, p.hopStart, p.chash, p.id.toRadixString(16), hex(e.data)]));
    if (dup) {
      final t = _pendingRelay.remove(dupKey);
      if (t != null) {
        t.cancel();
        relayCancelled++;
        _log(s.role, LogKind.info, tr('Weiterleiten unnötig – schon von …{0} gesendet', [p.relay.toRadixString(16).padLeft(2, '0')]));
      }
      return;
    }
    final rb = settings.rebroadcast;
    final mayRelay = settings.mtRole != 'client_mute' &&
        rb != 'none' &&
        (rb != 'local' || ok) &&
        (rb != 'known' || nodes.containsKey(key)) &&
        // im Amateurfunk-Betrieb nur unverschlüsselte Pakete weitergeben
        (!hamMode(s) || (ok && (p.channelIndex ?? 0) >= settings.channels.length));
    if (mayRelay && me != 0 && p.hopLimit > 0 && p.dest != me && !p.viaMqtt) _scheduleRelay(s, e, p, dupKey);
    final n = _node(key, Net.mt, p.from, s, e, hops: p.hopsAway);
    _trackFreqErr(s, e);
    if (!ok) return;
    final a = p.app;
    // Unbekannte Knoten: einmal nach der Visitenkarte fragen (wie die Meshtastic-Firmware)
    if (n.longName.isEmpty && p.port != Port.nodeinfo && (n.askedInfo == null || e.at.difference(n.askedInfo!).inHours >= 6)) {
      n.askedInfo = e.at;
      Timer(Duration(milliseconds: 1500 + _rnd.nextInt(2000)), () => sendNodeInfo(dest: p.from, wantResponse: true));
    }
    switch (p.port) {
      case Port.text:
        final chat = p.isBroadcast ? 'mt:${(p.channelIndex ?? 0) % settings.channels.length}' : (p.dest == me ? 'dm:$key' : null);
        if (chat == null) break; // DM an jemand anderen
        if (n.ignored) break; // ignorierter Knoten
        messages.add(Message(
          chat: chat,
          from: key,
          fromName: n.display,
          text: a['text'] as String? ?? '',
          at: e.at,
          mine: false,
          status: MsgStatus.received,
          pktId: p.id,
          rssi: e.rssi,
          snr: e.snr,
          hops: p.hopsAway,
        )..info = p.pki ? tr('Ende-zu-Ende verschlüsselt') : '');
        if (openChat != chat) unread[chat] = (unread[chat] ?? 0) + 1;
        if (settings.sound) SystemSound.play(SystemSoundType.alert);
        break;
      case Port.waypoint:
        if (a['lat'] is double && a['lon'] is double) {
          final id = a['id'] as int? ?? p.id;
          waypoints.removeWhere((w) => w.id == id);
          final exp = a['expire'] as int?;
          if (exp == null || exp == 0 || exp > DateTime.now().millisecondsSinceEpoch ~/ 1000) {
            final ic = a['icon'] as int?;
            waypoints.add(Waypoint(
              id: id,
              name: a['name'] as String? ?? tr('Wegpunkt'),
              description: a['desc'] as String? ?? '',
              lat: a['lat'] as double,
              lon: a['lon'] as double,
              from: key,
              at: e.at,
              expire: exp,
              icon: ic != null && ic > 0 ? String.fromCharCode(ic) : '📍',
            ));
          }
        }
        break;
      case Port.traceroute:
        if (p.dest == me && p.requestId != 0) {
          final req = _traceReq.remove(p.requestId);
          final target = req != null ? nodes[req.$1] : n;
          if (target != null) {
            final hin = [settings.shortName.isEmpty ? tr('Ich') : settings.shortName, ...((a['route'] as List?) ?? const []).cast<int>().map(_nameOf), target.display];
            final back = ((a['back'] as List?) ?? const []).cast<int>().map(_nameOf).toList();
            target.route = hin.join(' → ') + (back.isNotEmpty ? tr('  ·  zurück über {0}', [back.join(' → ')]) : '');
            target.rttMs = req != null ? e.at.difference(req.$2).inMilliseconds : null;
            target.routeAt = e.at;
            _log(s.role, LogKind.info, tr('Route zu {0}: {1}', [target.display, target.route]), target.rttMs != null ? tr('Laufzeit {0} ms', [target.rttMs]) : '');
            notice(tr('Route zu {0}: {1}', [target.display, target.route]));
          }
        }
        break;
      case Port.nodeinfo:
        if (a['long'] is String) n.longName = a['long'] as String;
        if (a['short'] is String) n.shortName = a['short'] as String;
        if (a['hw'] is int) n.hw = (hwModels[a['hw']] != null ? tr(hwModels[a['hw']]!) : null) ?? tr('Modell {0}', [a['hw']]);
        n.role = tr(mtRoleNames[a['role'] as int? ?? 0] ?? '');
        final pk = a['pubkey'];
        if (pk is Uint8List && pk.length == 32) {
          n.pubKey = Uint8List.fromList(pk);
          if (_keyWait.containsKey(p.from)) _flushKeyWait(p.from);
        }
        final asked = n.askedInfo;
        if (n.infoAt == null || (asked != null && e.at.difference(asked).inMinutes < 5)) {
          notice(tr('Visitenkarte von {0}{1} erhalten', [n.display, n.shortName.isNotEmpty ? ' (${n.shortName})' : '']));
        }
        n.infoAt = e.at;
        if (p.wantResponse && (p.dest == me || p.isBroadcast)) {
          final last = _nodeInfoSent[p.from];
          if (last == null || e.at.difference(last).inMinutes >= 10) {
            _nodeInfoSent[p.from] = e.at;
            Timer(Duration(milliseconds: 500 + _rnd.nextInt(1500)), () => sendNodeInfo(dest: p.from));
          }
        }
        break;
      case Port.position:
        if (a['lat'] is double && a['lon'] is double) {
          n.lat = a['lat'] as double;
          n.lon = a['lon'] as double;
          n.alt = a['alt'] as int?;
          if (n.posAt == null) notice(tr('Position von {0} erhalten', [n.display]));
          n.posAt = e.at;
        }
        // Positionsanfrage an uns: nur antworten, wenn Teilen eingeschaltet ist
        if (p.wantResponse && p.dest == me && settings.sharePosition && settings.lat != null) {
          Timer(Duration(milliseconds: 500 + _rnd.nextInt(1000)), () => sendPosition(dest: p.from));
        }
        break;
      case Port.telemetry:
        if (a['battery'] is int) n.battery = a['battery'] as int;
        if (a['voltage'] is double) n.voltage = a['voltage'] as double;
        if (a['chUtil'] is double) n.chUtil = a['chUtil'] as double;
        if (a['airUtil'] is double) n.airUtil = a['airUtil'] as double;
        if (a['uptime'] is int) n.uptimeS = a['uptime'] as int;
        if (a['temp'] is double) n.temp = a['temp'] as double;
        n.telAt = e.at;
        if (p.wantResponse && p.dest == me) {
          Timer(Duration(milliseconds: 500 + _rnd.nextInt(1000)), () => sendTelemetry(dest: p.from));
        }
        break;
      case Port.routing:
        if (p.dest == me && p.requestId != 0) {
          final m = _awaitAck[p.requestId];
          if (m != null) {
            final err = a['error'] as int? ?? 0;
            if (err == 0) {
              m.status = MsgStatus.acked;
              m.info = 'zugestellt';
            } else {
              m.status = MsgStatus.failed;
              m.info = (routingErrors[err] != null ? tr(routingErrors[err]!) : null) ?? tr('Fehler {0}', [err]);
            }
          }
        }
        break;
    }
    // Bestätigung für Direktnachrichten an uns
    if (p.dest == me && p.wantAck && p.port != Port.routing) {
      final ack = buildMtPacket(
        from: me,
        id: _newId(),
        channel: hamMode(s) ? mtChannel(s, (p.channelIndex ?? 0) % settings.channels.length) : _rxChannels[p.channelIndex ?? 0],
        port: Port.routing,
        payload: routingAckPayload(),
        dest: p.from,
        requestId: p.id,
        hopLimit: p.hopStart > 0 ? p.hopStart : settings.hopLimit,
        pkiKey: p.pki ? sharedKeyFor(n) : null,
      );
      _enqueue(s, ack, tr('Bestätigung → {0}{1}', [key, p.pki ? ' 🔒' : '']));
    }
    _scheduleSave();
  }

  final Map<int, DateTime> _nodeInfoAsked = {};
  final Map<String, Timer> _pendingRelay = {};
  int relayed = 0, relayCancelled = 0;

  /// Weiterleiten wie Meshtastic („managed flooding“): Wer schwach empfängt, sendet früher;
  /// hört man vorher schon eine Wiederholung, entfällt die eigene.
  void _scheduleRelay(ModemSlot s, RxEvent e, MtPacket p, String dupKey) {
    final cfg = s.config?.lora;
    final tSym = cfg == null ? 8.0 : (1 << cfg.sf) / cfg.bwHz * 1000.0;
    final slot = tSym * 2.5 + 2;
    final snr = e.snr.clamp(-20.0, 10.0);
    var cw = (3 + (snr + 20) / 30 * 5).round();
    if (settings.mtRole == 'router') cw = (cw - 2).clamp(1, 8).toInt(); // Router senden bevorzugt
    final delay = (_rnd.nextInt(1 << cw) * slot).round() + 100;
    final data = Uint8List.fromList(e.data);
    data[12] = (data[12] & 0xF8) | ((p.hopLimit - 1) & 7);
    data[15] = settings.myNum & 0xFF;
    _pendingRelay[dupKey] = Timer(Duration(milliseconds: delay), () {
      _pendingRelay.remove(dupKey);
      if (!s.connected) return;
      relayed++;
      _enqueue(s, data, tr('Weiterleitung von {0} (noch {1} Hops)', [nodeIdStr(p.from), p.hopLimit - 1]));
    });
  }

  void _onMeshCore(ModemSlot s, RxEvent e) {
    final p = McPacket.parse(e.data);
    if (p == null) {
      _log(s.role, LogKind.rx, tr('Kein MeshCore-Paket ({0} B)', [e.data.length]), '${_sig(e)}  ${hex(e.data)}');
      return;
    }
    final adv = McAdvert.parse(p);
    if (adv != null) {
      final key = 'mc:${adv.keyPrefix}';
      final dupKey = '$key:${adv.timestamp}';
      final dup = _seen.containsKey(dupKey);
      _seen[dupKey] = e.at;
      _log(s.role, LogKind.rx, tr('MeshCore {0} »{1}«{2}', [adv.typeName, adv.name, dup ? ' (Wiederholung)' : '']),
          tr('{0} · Pfad {1}  {2}', [_sig(e), p.path.length, hex(e.data)]));
      if (dup) return;
      final n = _node(key, Net.mc, int.parse(adv.keyPrefix, radix: 16), s, e, hops: p.path.length);
      if (adv.name.isNotEmpty) n.longName = adv.name;
      n.hw = adv.typeName;
      if (adv.lat != null && adv.lon != null && (adv.lat != 0 || adv.lon != 0)) {
        n.lat = adv.lat;
        n.lon = adv.lon;
      }
      _scheduleSave();
      return;
    }
    _log(s.role, LogKind.rx, tr('MeshCore {0} ({1}, Pfad {2})', [p.typeName, p.isFlood ? tr('Flood') : tr('Direkt'), p.path.length]),
        '${_sig(e)}  ${hex(e.data)}');
  }

  void _onLr(ModemSlot s, RxEvent e) {
    final p = LrPacket.parse(e.data);
    if (p == null) {
      final t = String.fromCharCodes(e.data.where((c) => c >= 0x20 && c < 0x7F));
      _log(s.role, LogKind.rx, tr('Fremdes Paket ({0} B){1}', [e.data.length, t.length > 3 ? ' »$t«' : '']), '${_sig(e)}  ${hex(e.data)}');
      return;
    }
    final key = 'lr:${p.from.toRadixString(16).padLeft(8, '0')}';
    final dupKey = '$key:${p.id}';
    if (_seen.containsKey(dupKey)) return;
    _seen[dupKey] = e.at;
    final n = _node(key, Net.lr, p.from, s, e, hops: 0);
    if (p.callsign.isNotEmpty) n.shortName = p.callsign;
    if (p.name.isNotEmpty) n.longName = '${p.callsign} · ${p.name}';
    final who = p.callsign.isNotEmpty ? p.callsign : key;
    switch (p.type) {
      case LrType.text:
        _log(s.role, LogKind.rx, '$who: »${p.text}«', _sig(e));
        messages.add(Message(
            chat: 'lr',
            from: key,
            fromName: who,
            text: p.text,
            at: e.at,
            mine: false,
            status: MsgStatus.received,
            pktId: p.id,
            rssi: e.rssi,
            snr: e.snr,
            hops: 0));
        if (openChat != 'lr') unread['lr'] = (unread['lr'] ?? 0) + 1;
        if (settings.sound) SystemSound.play(SystemSoundType.alert);
        if (settings.lrAutoAck && settings.callsign.trim().isNotEmpty) {
          final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
          final ack = LrPacket.build(LrType.ack, me, _newId(), _cut(settings.callsign.trim().toUpperCase(), 12),
              _cut(settings.longName, 39), (Wr()..u32(p.id)).toBytes());
          Timer(Duration(milliseconds: 300 + _rnd.nextInt(1200)), () => _enqueue(s, ack, tr('LR-Funk Bestätigung → {0}', [who])));
        }
        break;
      case LrType.ack:
        final m = _awaitLrAck[p.ackFor];
        _log(s.role, LogKind.rx, tr('{0} bestätigt Empfang', [who]), _sig(e));
        if (m != null) {
          m.status = MsgStatus.acked;
          final list = m.info.isEmpty ? <String>[] : m.info.replaceFirst(tr('empfangen von {0}', ['']), '').split(', ');
          if (!list.contains(who)) list.add(who);
          m.info = tr('empfangen von {0}', [list.join(', ')]);
        }
        break;
      case LrType.beacon:
        _log(s.role, LogKind.rx, tr('Bake von {0}', [who]), _sig(e));
        break;
      case LrType.file:
        _onFileChunk(s, p, key, who, e);
        break;
      case LrType.fileAck:
        _onFileAck(p, who);
        break;
    }
    _scheduleSave();
  }

  // ------------------------------------------------------------------ Chats
  List<ChatInfo> get chats {
    final out = <ChatInfo>[];
    for (var i = 0; i < settings.channels.length; i++) {
      final c = settings.channels[i];
      out.add(ChatInfo('mt:$i', c.name, tr('Meshtastic-Kanal · {0}', [mtPresets[settings.mtPreset].name]), Net.mt));
    }
    out.add(ChatInfo('lr', tr('LR-Funk 70 cm'), tr('eigener Kanal · {0} MHz', [(settings.lrCfg.freqHz / 1e6).toStringAsFixed(3)]), Net.lr));
    final dms = <String>{};
    for (final m in messages) {
      if (m.chat.startsWith('dm:')) dms.add(m.chat);
    }
    if (openChat != null && openChat!.startsWith('dm:')) dms.add(openChat!);
    for (final d in dms) {
      final key = d.substring(3);
      out.add(ChatInfo(d, nodes[key]?.display ?? key, tr('Direktnachricht · {0}', [key]), Net.mt));
    }
    return out;
  }

  List<Message> messagesOf(String chat) => messages.where((m) => m.chat == chat).toList();

  Message? lastMessage(String chat) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].chat == chat) return messages[i];
    }
    return null;
  }

  void markRead(String chat) {
    openChat = chat;
    if (unread.remove(chat) != null) notifyListeners();
  }

  int get unreadTotal => unread.values.fold(0, (a, b) => a + b);

  void deleteChat(String chat) {
    messages.removeWhere((m) => m.chat == chat);
    unread.remove(chat);
    changed(save: true);
  }

  void forgetNode(String key) {
    nodes.remove(key);
    changed(save: true);
  }

  Future<void> wipeAll() async {
    messages.clear();
    nodes.clear();
    unread.clear();
    log.clear();
    await saveNow();
    notifyListeners();
  }

  /// Entfernung (km) und Richtung (Grad) von der eigenen Position.
  (double, double)? distanceTo(Node n) {
    final lat1 = settings.lat, lon1 = settings.lon;
    if (lat1 == null || lon1 == null || !n.hasPos) return null;
    return geoDistance(lat1, lon1, n.lat!, n.lon!);
  }
}

String hhmmNow() {
  final t = DateTime.now();
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

(double, double) geoDistance(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final h = sin(dLat / 2) * sin(dLat / 2) + cos(rad(lat1)) * cos(rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  final dist = 2 * r * atan2(sqrt(h), sqrt(1 - h));
  final y = sin(dLon) * cos(rad(lat2));
  final x = cos(rad(lat1)) * sin(rad(lat2)) - sin(rad(lat1)) * cos(rad(lat2)) * cos(dLon);
  final brg = (atan2(y, x) * 180 / pi + 360) % 360;
  return (dist, brg);
}

class _OutXfer {
  final int xfer;
  final List<Uint8List> chunks;
  final Message msg;
  final ModemSlot slot;
  final Set<int> sent = {};
  final List<String> ackedBy = [];
  int round = 0, probes = 0;
  bool finished = false;
  Timer? timer;
  _OutXfer(this.xfer, this.chunks, this.msg, this.slot);
}

class _InXfer {
  final int xfer, count, size;
  final Message msg;
  final Map<int, Uint8List> parts = {};
  String name = '', mime = '';
  Timer? timer;
  _InXfer(this.xfer, this.count, this.size, this.msg);
}
