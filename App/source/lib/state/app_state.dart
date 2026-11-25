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
import '../core/node_box.dart';
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
  FeInfo? fe; // 868-MHz-Frontend (PA/LNA) der Trägerplatine, null = keins
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
  bool on24 = false; // gerade auf dem 2,4-GHz-Dateikanal
  bool send24 = false; // sendet selbst gerade eine Datei dort (dann steuert der Sender die Rückkehr)
  Timer? _back24;
  bool loud = false; // sendet gerade eine Datei mit der höchsten erlaubten Leistung
  DateTime? quietUntil; // fremde Dateiübertragung läuft: eigene Sendungen (außer Datei-Rückmeldungen) zurückhalten
  Timer? _quietTimer;
  final ChannelWatch watch = ChannelWatch(); // Grundrauschen, um laute Fremdsender zu erkennen
  LoraCfg? applied; // zuletzt eingestellte LoRa-Werte (bekommt das Postfach der Node)
  bool applying = false; // wird gerade eingestellt: Sendewarteschlange wartet

  bool get connected => client != null && !client!.isClosed;
  String get band => role == 'A' ? tr('HF 868') : tr('LF 433');
  String get espName => 'ESP32 $role';
}

class _TxJob {
  final Uint8List data;
  final String what;
  final void Function(TxDoneEvent ev)? done;
  final Future<void> Function()? action; // statt zu senden: z. B. umschalten (in der Reihenfolge der Warteschlange)
  final int gapMs; // Pause nach dem Senden
  final bool file; // gehört zu einer Dateiübertragung: Kanal vorher prüfen, wird nie zurückgehalten
  int busyTries = 0;
  _TxJob(this.data, this.what, this.done, {this.action, this.gapMs = 150, this.file = false});
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
    if (save) {
      _scheduleSave();
      _boxSettingsSoon();
    }
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
      if (s.kind == TransportKind.bluetooth) {
        // gekoppelte Geräte, Nodes zuerst; beide Modems über dieselbe Verbindung
        s.ports = await listBtNodes();
        if (s.port == null || !s.ports.any((p) => p.id == s.port!.id)) {
          s.port = s.ports.where((p) => p.cp210x).firstOrNull ?? s.ports.firstOrNull;
        }
        notifyListeners();
        return;
      }
      s.ports = await listUsbPorts();
      if (s.kind == TransportKind.node) {
        // Node-Kabel: beide Modems über dieselbe Konsole
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
      if (k == TransportKind.usb || k == TransportKind.node || k == TransportKind.bluetooth) {
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
      final o = s == a ? b : a;
      if (viaNode(s.kind) && o.kind == s.kind && o.port != null) {
        s.port = o.port; // über die Node: dieselbe Verbindung wie das andere Modem
      } else if (s.kind == TransportKind.usb || s.kind == TransportKind.node || s.kind == TransportKind.bluetooth) {
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
    // sofort sperren (vor dem ersten await): sonst startet ein zweiter Aufruf parallel und schließt den Kanal des ersten
    s.connecting = true;
    s.manualOff = false;
    s._reconnect?.cancel();
    await disconnect(s, quiet: true);
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
          if (p == null) throw Exception(tr('Kein Anschluss gewählt. USB-Kabel der Node-Konsole anstecken und „Suchen“ drücken.'));
          s.status = tr('melde mich an der Node an …');
          notifyListeners();
          NodeSerialLink.user = settings.nodeUser;
          NodeSerialLink.password = settings.nodePass;
          t = await NodeSerialLink.channel(p, s.role, log: (x) => _log(s.role, LogKind.info, x));
          break;
        case TransportKind.network:
          t = await TcpTransport.open(settings.piHost, s.role == 'A' ? 2021 : 2022);
          break;
        case TransportKind.bluetooth:
          final p = s.port;
          if (p == null) {
            throw Exception(tr('Keine Node gewählt. Die Node einmal in den Bluetooth-Einstellungen des Handys koppeln (LR2021-…), dann „Suchen“.'));
          }
          s.status = tr('verbinde per Bluetooth …');
          notifyListeners();
          t = await NodeSerialLink.channel(p, s.role, bluetooth: true, log: (x) => _log(s.role, LogKind.info, x));
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
      // über die Node: das andere Modem ist evtl. schon verbunden – gleich noch einmal versuchen
      if (viaNode(s.kind)) _scheduleReconnect(s);
    } finally {
      s.connecting = false;
      notifyListeners();
    }
  }

  /// Beide Modems hängen an derselben Node-Verbindung (Bluetooth, Netzwerk, Node-Kabel)?
  bool get sharedNode => viaNode(a.kind) && a.kind == b.kind;

  /// Verbindungsart für ein Modul wählen; über die Node gilt sie für beide (eine Verbindung, zwei Kanäle).
  void setKind(ModemSlot s, TransportKind k) {
    s.kind = k;
    if (viaNode(k)) {
      final o = s == a ? b : a;
      if (!o.connected) {
        o.kind = k;
        o.port = s.port;
      }
    }
    notifyListeners();
  }

  void setPort(ModemSlot s, PortChoice? p) {
    s.port = p;
    if (viaNode(s.kind)) {
      final o = s == a ? b : a;
      if (!o.connected && o.kind == s.kind) {
        o.ports = s.ports;
        o.port = p;
      }
    }
    notifyListeners();
  }

  /// Die Node verbinden: A und B über dieselbe Verbindung.
  Future<void> connectNode() async {
    b
      ..kind = a.kind
      ..port = a.port
      ..ports = a.ports;
    await connect(a);
    if (!b.connected && !b.connecting) await connect(b);
  }

  Future<void> disconnectNode() async {
    await disconnect(a);
    await disconnect(b);
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
    s.fe = info.role == 'A' ? await s.client!.fe() : null;
    if (s.fe != null) {
      _log(s.role, LogKind.info, tr('868-MHz-Endstufe erkannt (bis {0} dBm)', [s.fe!.outMaxDbm]));
    }
    await applyMode(s);
    unawaited(refreshStats(s));
    if (s.kind == TransportKind.node || s.kind == TransportKind.bluetooth) {
      // Node-Kabel / Bluetooth: das andere Modem gleich mitverbinden und GPS darüber holen
      final o = s == a ? b : a;
      if (!o.connected && !o.connecting && !o.manualOff &&
          (o.kind == s.kind || o.kind == TransportKind.demo || _lastKind(o).isEmpty || o.kind == TransportKind.usb || o.kind == TransportKind.node)) {
        o.kind = s.kind;
        o.port = s.port;
        unawaited(connect(o));
      }
      _attachSerialGps();
    }
    if (viaNode(s.kind)) unawaited(_connectBox(s));
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
      // über die Node bleibt das Modem auf Empfang – das Postfach hört weiter mit
      if (!viaNode(s.kind)) {
        try {
          await c.standby().timeout(const Duration(milliseconds: 500));
        } catch (_) {}
      }
      await c.close();
      if (!quiet) _log(s.role, LogKind.info, tr('Getrennt'));
      if (!slots.any((o) => o.connected && viaNode(o.kind))) unawaited(_closeBox());
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
    return powerLimit(c.freqHz, bwHz: c.bwHz, licensed: settings.licensed, antennaGainDbi: antGain(s), chipMaxSub: s.fe?.outMaxDbm);
  }

  /// LNA des Frontends: 0 automatisch, 1 an, 2 aus.
  Future<void> setFeMode(ModemSlot s, int mode) async {
    final c = s.client;
    if (c == null || s.fe == null) return;
    try {
      s.fe = await c.setFe(mode) ?? s.fe;
    } catch (e) {
      _log(s.role, LogKind.err, tr('LNA umschalten fehlgeschlagen'), '$e');
    }
    notifyListeners();
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
    final lim = powerLimit(c.freqHz, bwHz: c.bwHz, licensed: settings.licensed, antennaGainDbi: antGain(s), chipMaxSub: s.fe?.outMaxDbm);
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
    s.on24 = false;
    s.loud = false;
    s._back24?.cancel();
    s.applying = true; // solange nichts senden (sonst „beschäftigt“, und nie auf der Kalibrier-Hilfsfrequenz)
    // ein gerade laufendes Paket erst fertig werden lassen
    for (var i = 0; i < 40 && s.transmitting; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
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
      // „beschäftigt“ (sendet gerade, z. B. ein Paket der Node): kurz warten und noch einmal
      for (var i = 0;; i++) {
        try {
          await c.setLora(cfg);
          break;
        } on ModemError catch (e) {
          if (e.status != -4 || i >= 10) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      }
      await c.rxStart();
      s.config = await c.config();
      s.applied = cfg.copy();
      _boxSettingsSoon();
      s.status = tr('Empfang');
      final lim = limitFor(s, m);
      _log(s.role, LogKind.info, tr('{0}: {1}, {2} dBm{3}', [radioModeName(m), cfg.summary, cfg.powerDbm, hamMode(s) ? tr(', Amateurfunk (unverschlüsselt)') : '']),
          lim.reason);
      if (!lim.allowed) _log(s.role, LogKind.warn, tr('Senden hier nicht erlaubt: {0}', [lim.reason]));
      if (m == RadioMode.meshtastic) {
        Timer(const Duration(seconds: 2), () => sendNodeInfo(wantResponse: true));
      }
      s.error = null;
      notifyListeners();
      return null;
    } catch (e) {
      s.status = tr('Fehler');
      s.error = tr('Einstellen fehlgeschlagen: {0}', [e]);
      _log(s.role, LogKind.err, tr('Einstellen fehlgeschlagen'), '$e');
      notifyListeners();
      return '$e';
    } finally {
      s.applying = false;
      _pump(s);
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
      if (s.fe != null) s.fe = await c.fe() ?? s.fe;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _pollRssi(ModemSlot s) async {
    try {
      final v = await s.client!.rssi();
      s.liveRssi = v;
      s.watch.busy(v); // lernt dabei das Grundrauschen
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

  /// Nachgeholte Pakete (Zone #lrReplay) lösen nichts aus; im LR-Funk antwortet die Node selbst (Zone #lrMute),
  /// solange ihr Postfach das übernimmt. Gilt auch für Timer, die dort gestartet werden.
  static bool get _txMuted => Zone.current[#lrReplay] == true || Zone.current[#lrMute] == true;

  void _enqueue(ModemSlot s, Uint8List data, String what, [void Function(TxDoneEvent ev)? done, int gapMs = 150]) {
    if (_txMuted) return;
    s._queue.add(_TxJob(data, what, done, gapMs: gapMs));
    _pump(s);
  }

  void _enqueueAction(ModemSlot s, String what, Future<void> Function() f) {
    if (Zone.current[#lrReplay] == true) return;
    s._queue.add(_TxJob(Uint8List(0), what, null, action: f));
    _pump(s);
  }

  /// Paket einer Dateiübertragung (Teil, Ankündigung, Rückmeldung): Kanal wird vorher geprüft, und es wird auch
  /// gesendet, während eigene Sendungen wegen einer fremden Übertragung zurückgehalten werden.
  void _enqueueFile(ModemSlot s, Uint8List data, String what, [void Function(TxDoneEvent ev)? done, int gapMs = 150]) {
    if (_txMuted) return;
    s._queue.add(_TxJob(data, what, done, gapMs: gapMs, file: true));
    _pump(s);
  }

  bool _quiet(ModemSlot s) => s.quietUntil != null && DateTime.now().isBefore(s.quietUntil!);

  /// Eine fremde Datei wird gesendet: eigene Sendungen auf diesem Modul bis [until] zurückhalten (höchstens 30 min).
  void _holdFor(ModemSlot s, DateTime until) {
    final max = DateTime.now().add(const Duration(minutes: 30));
    if (until.isAfter(max)) until = max;
    if (s.quietUntil != null && s.quietUntil!.isAfter(until)) return;
    s.quietUntil = until;
    s._quietTimer?.cancel();
    s._quietTimer = Timer(until.difference(DateTime.now()) + const Duration(milliseconds: 50), () {
      if (!_quiet(s)) {
        s.quietUntil = null;
        _pump(s);
      }
    });
  }

  /// Vor einem Dateiteil: warten, solange jemand anderes laut auf dem Kanal sendet (Pegel deutlich über dem
  /// Grundrauschen). Höchstens [maxS] Sekunden, danach wird trotzdem gesendet.
  Future<void> _waitClear(ModemSlot s, {int maxS = 60}) async {
    final c = s.client;
    if (c == null || s.kind == TransportKind.demo || s.on24) return;
    final t0 = DateTime.now();
    var waited = false;
    while (DateTime.now().difference(t0).inSeconds < maxS) {
      double v;
      try {
        v = await c.rssi();
      } catch (_) {
        return;
      }
      s.liveRssi = v;
      if (!s.watch.busy(v)) {
        if (waited) _log(s.role, LogKind.info, tr('Kanal wieder frei – sende weiter'));
        return;
      }
      if (!waited) {
        waited = true;
        _log(s.role, LogKind.info,
            tr('Kanal belegt ({0} dBm, Rauschen {1} dBm) – warte, bis der andere Sender fertig ist',
                [v.toStringAsFixed(0), s.watch.floor?.toStringAsFixed(0) ?? '?']));
        notifyListeners();
      }
      await Future<void>.delayed(Duration(milliseconds: 250 + _rnd.nextInt(500)));
    }
    _log(s.role, LogKind.info, tr('Kanal seit {0} s belegt – sende trotzdem', [maxS]));
  }

  Future<void> _pump(ModemSlot s) async {
    if (s._txRunning) return;
    s._txRunning = true;
    try {
      while (s._queue.isNotEmpty && s.connected) {
        // die Node sucht gerade auf diesem Modul nach einer Frequenz, oder es wird gerade eingestellt: nichts senden
        if (scanRunning && scanJob?['role'] == s.role) break;
        if (s.applying && s._queue.first.action == null) break;
        var idx = 0;
        if (_quiet(s)) {
          // fremde Dateiübertragung: nur Dateipakete und Umschaltungen, der Rest wartet
          idx = s._queue.indexWhere((j) => j.file || j.action != null);
          if (idx < 0) break;
        }
        final job = s._queue.removeAt(idx);
        if (job.action != null) {
          try {
            await job.action!();
          } catch (e) {
            _log(s.role, LogKind.err, job.what, '$e');
          }
          continue;
        }
        final careful = job.file && settings.lrFileClear;
        if (careful) await _waitClear(s);
        if (!s.connected) break;
        s.transmitting = true;
        notifyListeners();
        _log(s.role, LogKind.tx, job.what, '${job.data.length} B  ${hex(job.data)}');
        TxDoneEvent ev;
        try {
          ev = await s.client!.txWait(job.data, lbt: settings.lbt || careful);
        } catch (e) {
          ev = TxDoneEvent(0, e is ModemError ? e.status : -11, 0);
        }
        if (job.file && ev.status == -10 && job.busyTries < 10) {
          // Kanal belegt (anderes LoRa-Signal): später noch einmal, nichts geht verloren
          job.busyTries++;
          s.transmitting = false;
          s._queue.insert(0, job);
          _log(s.role, LogKind.info, tr('Kanal belegt – {0} wird gleich wiederholt', [job.what]));
          await Future<void>.delayed(Duration(milliseconds: 1000 + _rnd.nextInt(2000)));
          continue;
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
        await Future<void>.delayed(Duration(milliseconds: job.gapMs));
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

  // ------------------------------------------------------------------ Postfach der Node
  /// Postfach der Node (lr2021d ab 1.2): speichert alles Empfangene, sendet Dateiaufträge auch ohne Handy weiter,
  /// sucht die ruhigste Frequenz.
  NodeBox? box;
  bool _boxOpening = false, boxSyncing = false;
  ScanResult? scanResult;
  Map<String, dynamic>? scanJob;
  final Map<String, Message> _boxJobMsg = {};
  Timer? _boxSetTimer;

  bool get boxActive => box != null && !box!.closed;
  bool get scanRunning => scanJob != null && scanJob!['finished'] == null;
  bool get canScan => boxActive && box!.caps.contains('scan');

  /// Übernimmt das Postfach die LR-Funk-Antworten (Bestätigungen, fehlende Teile) dieses Moduls?
  bool _boxHandlesLr(ModemSlot s) =>
      boxActive &&
      box!.caps.contains('lrfile') &&
      viaNode(s.kind) &&
      modeOf(s) == RadioMode.lrfunk &&
      settings.callsign.trim().isNotEmpty;

  Future<void> _connectBox(ModemSlot s) async {
    if (boxActive || _boxOpening) return;
    _boxOpening = true;
    NodeBox? nb;
    try {
      if (s.kind == TransportKind.network) {
        nb = await NodeBox.overTcp(settings.piHost);
      } else {
        final l = NodeSerialLink.active;
        if (l == null || !l.hasBox) {
          _log(tr('Node'), LogKind.info,
              tr('Die Node hat noch kein Postfach (lr2021d älter als 1.2). Nach dem Update empfängt und sendet sie auch ohne Handy.'));
          return;
        }
        nb = NodeBox.overLink(l);
      }
      nb.hello = await nb.call('hello');
      final mine = nb;
      box = mine;
      mine.events.listen(_onBoxEvent, onDone: () {
        if (identical(box, mine)) {
          box = null;
          notifyListeners();
        }
      });
      scanResult = ScanResult.from(mine.hello['scan']) ?? scanResult;
      for (final j in ((mine.hello['jobs'] as List?) ?? const [])) {
        _applyJob((j as Map).cast<String, dynamic>());
      }
      _log(tr('Node'), LogKind.info, tr('Postfach der Node {0} verbunden ({1})', [mine.nodeId, mine.via]));
      await _pushBoxSettings();
      await _syncBox();
    } catch (e) {
      if (nb != null && !identical(box, nb)) unawaited(nb.close());
      _log(tr('Node'), LogKind.warn, tr('Postfach der Node nicht erreichbar'), '$e');
    } finally {
      _boxOpening = false;
      notifyListeners();
    }
  }

  Future<void> _closeBox() async {
    final nb = box;
    box = null;
    scanJob = null;
    await nb?.close();
    notifyListeners();
  }

  void _boxSettingsSoon() {
    if (!boxActive) return;
    _boxSetTimer?.cancel();
    _boxSetTimer = Timer(const Duration(seconds: 1), () => unawaited(_pushBoxSettings()));
  }

  /// Was die Node braucht, um ohne Handy weiterzuarbeiten: Rufzeichen, Kennung, LR-Funk-Modul, Datei-Einstellungen,
  /// erlaubte Höchstleistung und die zuletzt eingestellten Funkwerte (für einen Neustart des ESP32).
  Future<void> _pushBoxSettings() async {
    final nb = box;
    if (nb == null || nb.closed) return;
    final loud = <String, int>{};
    final radio = <String, Map<String, dynamic>>{};
    for (final s in slots) {
      final c = s.applied;
      if (c != null && s.connected && viaNode(s.kind)) {
        radio[s.role] = {
          'freq_hz': c.freqHz,
          'bw_hz': c.bwHz,
          'sf': c.sf,
          'cr': c.cr,
          'sync': c.sync,
          'power': c.powerDbm,
          'preamble': c.preamble,
          'iq': (c.flags & 2) != 0,
        };
      }
      if (modeOf(s) == RadioMode.lrfunk && settings.lrFileLoud) {
        final lim = limitFor(s, RadioMode.lrfunk);
        if (lim.allowed) loud[s.role] = lim.maxDbm;
      }
    }
    final lrRole = modeOf(b) == RadioMode.lrfunk ? 'B' : (modeOf(a) == RadioMode.lrfunk ? 'A' : '');
    try {
      await nb.call('settings', {
        'settings': {
          'callsign': settings.callsign.trim().toUpperCase(),
          'name': _cut(settings.longName, 39),
          'num': settings.myNum,
          'lr_role': lrRole,
          'auto_ack': settings.lrAutoAck,
          'twice': settings.lrFileTwice,
          'clear': settings.lrFileClear,
          'loud_dbm': loud,
          'radio': radio,
        }
      });
    } catch (_) {}
  }

  /// Alles abholen, was die Node empfangen hat, seit die App zuletzt verbunden war – und wie live auswerten
  /// (nur ohne Antworten zu senden).
  Future<void> _syncBox() async {
    final nb = box;
    if (nb == null || boxSyncing) return;
    boxSyncing = true;
    notifyListeners();
    var n = 0;
    try {
      final id = nb.nodeId;
      var since = settings.boxCursor[id] ?? 0;
      final head = nb.hello['head'] as int? ?? 0;
      if (since > head) since = 0; // Speicher der Node wurde gelöscht
      while (true) {
        final r = await nb.call('sync', {'since': since, 'limit': 150}, const Duration(seconds: 40));
        for (final it in (r['items'] as List? ?? const [])) {
          if (_replay((it as Map).cast<String, dynamic>())) n++;
        }
        since = r['last'] as int? ?? since;
        settings.boxCursor[id] = since;
        if (r['more'] != true) break;
      }
      _scheduleSave();
      if (n > 0) {
        _log(tr('Node'), LogKind.info, tr('{0} Pakete von der Node nachgeholt', [n]));
        notice(tr('{0} Pakete von der Node nachgeholt', [n]));
      }
    } catch (e) {
      _log(tr('Node'), LogKind.warn, tr('Abgleich mit der Node unterbrochen'), '$e');
    } finally {
      boxSyncing = false;
      notifyListeners();
    }
  }

  bool _replay(Map<String, dynamic> it) {
    if (it['crc'] == true) return false;
    final s = slot(it['role'] as String? ?? 'B');
    final h = it['d'] as String? ?? '';
    final data = Uint8List(h.length ~/ 2);
    for (var i = 0; i < data.length; i++) {
      data[i] = int.parse(h.substring(2 * i, 2 * i + 2), radix: 16);
    }
    final e = RxEvent((it['rssi'] as num? ?? 0).toDouble(), (it['snr'] as num? ?? 0).toDouble(), (it['fe'] as num? ?? 0).toInt(),
        false, 0, data,
        at: DateTime.fromMillisecondsSinceEpoch(((it['t'] as num? ?? 0) * 1000).round()), replay: true);
    runZoned(() {
      try {
        _onRx(s, e);
      } catch (_) {}
    }, zoneValues: {#lrReplay: true});
    return true;
  }

  void _onBoxEvent(Map<String, dynamic> m) {
    switch (m['op']) {
      case 'cursor':
        // live Empfangenes kommt parallel über das Modem: Stand merken, damit es nicht noch einmal nachgeholt wird
        if (!boxSyncing) {
          final id = box?.nodeId ?? '';
          final last = m['last'] as int? ?? 0;
          if (last > (settings.boxCursor[id] ?? 0)) {
            settings.boxCursor[id] = last;
            _scheduleSave();
          }
        }
        return;
      case 'job':
        _applyJob((m['job'] as Map).cast<String, dynamic>());
        break;
      case 'scan':
        scanResult = ScanResult.from(m['result']) ?? scanResult;
        notice(tr('Frequenzsuche fertig'));
        break;
      case 'file':
        _log(tr('Node'), LogKind.rx, tr('Die Node hat eine Datei vollständig empfangen: {0} von {1}', [m['name'], m['who']]));
        break;
    }
    notifyListeners();
  }

  void _applyJob(Map<String, dynamic> j) {
    if (j['kind'] == 'scan') {
      final was = scanRunning;
      scanJob = j;
      if (was && !scanRunning) {
        for (final s in slots) {
          _pump(s);
        }
      }
      return;
    }
    if (j['kind'] != 'file') return;
    final xfer = j['xfer'] as int?;
    final msg = _boxJobMsg[j['id']] ?? messages.where((m) => m.mine && m.chat == 'lr' && m.pktId == xfer).lastOrNull;
    if (msg == null) return;
    _boxJobMsg[j['id'] as String] = msg;
    final acked = ((j['acked_by'] as List?) ?? const []).cast<String>();
    final miss = ((j['missing_by'] as Map?) ?? const {}).cast<String, dynamic>();
    final prog = (j['progress'] as num?)?.toDouble();
    if (prog != null && prog > 0) msg.progress = prog;
    switch (j['state'] as String? ?? '') {
      case 'fertig':
        msg
          ..status = MsgStatus.acked
          ..progress = 1
          ..info = miss.isEmpty
              ? tr('vollständig empfangen von {0}', [acked.join(', ')])
              : tr('vollständig bei {0}, unvollständig bei {1}', [acked.join(', '), miss.keys.join(', ')]);
        break;
      case 'unvollständig':
        msg
          ..status = MsgStatus.failed
          ..info = tr('unvollständig bei {0} – es wird nicht mehr besser, Übertragung beendet', [miss.keys.join(', ')]);
        break;
      case 'keine Antwort':
        msg
          ..status = MsgStatus.failed
          ..info = tr('keine Bestätigung');
        break;
      case 'abgebrochen':
        msg
          ..status = MsgStatus.failed
          ..info = tr('abgebrochen');
        break;
      case 'fehler':
        msg
          ..status = MsgStatus.failed
          ..info = tr('Node: {0}', [j['info']]);
        break;
      case 'wartet':
        msg
          ..status = MsgStatus.pending
          ..info = tr('auf der Node gespeichert – sie sendet auch weiter, wenn das Handy getrennt ist');
        break;
      case 'kündigt an':
        msg.info = tr('Node kündigt die Datei an …');
        break;
      case 'sendet':
        msg.info = tr('Node sendet …');
        break;
      case 'sendet nach':
        msg.info = tr('Runde {0}: {1} fehlende Teile werden nachgesendet', [j['round'], miss.values.fold<int>(0, (a, b) => a + (b as int))]);
        break;
      case 'wartet auf Antwort':
        msg
          ..status = MsgStatus.sent
          ..info = tr('gesendet, warte auf Bestätigung …');
        break;
    }
    _scheduleSave();
  }

  /// Datei an die Node übergeben: sie speichert sie und sendet sie selbst (auch wenn das Handy danach getrennt wird).
  String? _sendFileViaNode(ModemSlot s, Uint8List data, String name, String mime, int xfer, {String? localPath}) {
    final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
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
      ..info = tr('wird an die Node übergeben …');
    messages.add(msg);
    final lim = limitFor(s, RadioMode.lrfunk);
    final nb = box!;
    unawaited(() async {
      try {
        final r = await nb.call(
            'send_file',
            {
              'role': s.role,
              'name': name,
              'mime': mime,
              'data': base64Encode(data),
              'opts': {
                'xfer': xfer,
                'twice': settings.lrFileTwice,
                'announce': settings.lrFileLoud,
                'loud_dbm': settings.lrFileLoud && lim.allowed ? lim.maxDbm : null,
                'air_s': (fileAirtimeS(data.length) ?? 0).ceil(),
              },
            },
            const Duration(minutes: 5));
        final j = (r['job'] as Map).cast<String, dynamic>();
        _boxJobMsg[j['id'] as String] = msg;
        _applyJob(j);
      } catch (e) {
        msg
          ..status = MsgStatus.failed
          ..info = tr('Übergabe an die Node fehlgeschlagen: {0}', ['$e'.replaceFirst('Exception: ', '')]);
      }
      _scheduleSave();
      notifyListeners();
    }());
    _scheduleSave();
    notifyListeners();
    return null;
  }

  /// Frequenzsuche auf der Node starten (Modul B im LR-Funk-Betrieb). Gibt Fehlertext oder null zurück.
  Future<String?> startScan(double fromMhz, double toMhz, double minutes) async {
    final nb = box;
    if (nb == null || !canScan) return tr('Die Frequenzsuche braucht eine Verbindung über die Node (lr2021d 1.2 oder neuer).');
    if (modeOf(b) != RadioMode.lrfunk) return tr('Die Frequenzsuche braucht ESP32 B im LR-Funk-Betrieb.');
    try {
      final r = await nb.call('scan', {
        'role': 'B',
        'from_mhz': fromMhz,
        'to_mhz': toMhz,
        'bw_khz': settings.lrCfg.bwHz / 1000,
        'minutes': minutes,
      });
      scanJob = (r['job'] as Map).cast<String, dynamic>();
      notifyListeners();
      return null;
    } catch (e) {
      return '$e'.replaceFirst('Exception: ', '');
    }
  }

  Future<void> cancelScan() async {
    final id = scanJob?['id'];
    if (id == null) return;
    try {
      await box?.call('cancel', {'id': id});
    } catch (_) {}
  }

  /// LR-Funk-Frequenz übernehmen (z. B. aus der Frequenzsuche) und gleich einstellen.
  Future<void> setLrFrequency(double mhz) async {
    settings.lrCfg.freqHz = (mhz * 1e6).round();
    changed(save: true);
    if (modeOf(b) == RadioMode.lrfunk && b.connected) await applyMode(b);
  }

  // ------------------------------------------------------------------ Dateien und Bilder (LR-Funk)
  /// Größte Datei für LR-Funk (1 MB ≈ 5800 Teile; bei SF9/125 kHz rund eine Stunde Sendezeit).
  static const maxFileBytes = 1024 * 1024;
  final Map<int, _OutXfer> _outX = {};
  final Map<String, _InXfer> _inX = {};
  final Set<String> _doneX = {};

  /// Geschätzte Sendezeit (s) für [bytes] Byte über LR-Funk.
  double? fileAirtimeS(int bytes) {
    final s = lrSlot;
    final cfg = s?.config?.lora;
    if (cfg == null) return null;
    if (_fast24(s!)) {
      final c24 = file24Cfg(s);
      final n24 = (bytes / LrFileProto.chunkSize24).ceil();
      return 2 + n24 * (c24.airtimeMs(LrFileProto.chunkSize24 + 30) + 60) / 1000;
    }
    var n = (bytes / LrFileProto.chunkSize).ceil();
    if (settings.lrFileTwice) n = 2 * n - 1;
    return n * (cfg.airtimeMs(LrFileProto.chunkSize + 30) + 200) / 1000;
  }

  /// Datei an alle im LR-Funk-Kanal senden. Gibt Fehlertext oder null zurück.
  String? sendFile(Uint8List data, String name, String mime, {String? localPath}) {
    final s = lrSlot;
    if (s == null) return tr('Kein Funkmodul im LR-Funk-Betrieb verbunden (Funk → ESP32 B).');
    if (settings.callsign.trim().isEmpty) return tr('Bitte zuerst dein Rufzeichen in den Einstellungen eintragen.');
    if (data.isEmpty) return tr('Die Datei ist leer.');
    if (data.length > maxFileBytes) return tr('Die Datei ist zu groß (höchstens {0} KB).', [maxFileBytes ~/ 1024]);
    final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
    final xfer = _newId();
    final fast = _fast24(s);
    if (!fast && _boxHandlesLr(s)) return _sendFileViaNode(s, data, name, mime, xfer, localPath: localPath);
    final chunks = FileChunk.split(data, mime, name, xfer, size: fast ? LrFileProto.chunkSize24 : LrFileProto.chunkSize);
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
    if (settings.lrFileLoud) _announce(x, data.length, mime, name);
    if (fast) {
      // Ankündigung auf dem normalen Kanal, dann alles auf 2,4 GHz (einfach; Fehlendes kommt über die Rückmeldungen)
      final cfg = file24Cfg(s);
      x.fast = true;
      s.send24 = true;
      final offer = FileOffer(xfer, cfg.freqHz, cfg.bwHz, cfg.sf, cfg.cr, chunks.length, data.length).build();
      msg.info = tr('kündige die Übertragung auf 2,4 GHz an …');
      _enqueueFile(s, LrPacket.build(LrType.fileOffer, me, _newId(), _cut(settings.callsign.trim().toUpperCase(), 12), '', offer),
          tr('Datei {0}: Ankündigung 2,4 GHz', [name]));
      _enqueueAction(s, tr('Wechsel auf 2,4 GHz'), () async {
        await Future<void>.delayed(const Duration(milliseconds: 1200)); // Empfänger stellen in der Zeit um
        await _set24(s, cfg);
      });
      _sendChunks(x, [for (var i = 0; i < chunks.length; i++) i]);
    } else {
      _sendChunks(x, settings.lrFileTwice ? fileSendOrder(chunks.length) : [for (var i = 0; i < chunks.length; i++) i]);
    }
    _scheduleSave();
    notifyListeners();
    return null;
  }

  /// Vor der Datei: auf volle erlaubte Leistung, dann dreimal ankündigen (Name, Größe, Teile, Sendezeit).
  void _announce(_OutXfer x, int size, String mime, String name) {
    final s = x.slot;
    final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
    final call = _cut(settings.callsign.trim().toUpperCase(), 12);
    final air = (fileAirtimeS(size) ?? 0).ceil();
    _enqueueAction(s, tr('volle Leistung für die Datei'), () => _setLoud(s, true));
    final body = FileAnnounce(x.xfer, size, x.chunks.length, air, mime, name).build();
    x.msg.info = tr('kündige die Datei an …');
    for (var k = 1; k <= 3; k++) {
      _enqueueFile(s, LrPacket.build(LrType.fileAnnounce, me, _newId(), call, '', body),
          tr('Datei {0}: Ankündigung {1}/3', [name, k]), null, 700);
    }
  }

  /// LR-Funk-Modul für eine Datei auf die höchste erlaubte Leistung stellen bzw. zurück auf die eingestellte.
  Future<void> _setLoud(ModemSlot s, bool on) async {
    final c = s.client;
    if (c == null || s.kind == TransportKind.demo || s.on24 || modeOf(s) != RadioMode.lrfunk || on == s.loud) return;
    final cfg = cfgFor(s, RadioMode.lrfunk);
    if (on) {
      final lim = limitFor(s, RadioMode.lrfunk);
      if (!lim.allowed || cfg.powerDbm >= lim.maxDbm) return; // steht schon auf dem Maximum
      cfg.powerDbm = lim.maxDbm;
    }
    try {
      await c.setLora(cfg);
      await c.rxStart();
      s.loud = on;
      try {
        s.config = await c.config();
      } catch (_) {}
      _log(s.role, LogKind.info,
          on ? tr('Datei: volle erlaubte Leistung, {0} dBm', [cfg.powerDbm]) : tr('Datei fertig: zurück auf {0} dBm', [cfg.powerDbm]));
    } catch (e) {
      _log(s.role, LogKind.err, tr('Leistung umstellen fehlgeschlagen'), '$e');
    }
    notifyListeners();
  }

  /// Leistung zurück, wenn auf diesem Modul keine eigene Datei mehr läuft.
  void _loudOff(ModemSlot s) {
    if (_outX.values.any((o) => o.slot == s && !o.finished)) return;
    _enqueueAction(s, tr('Leistung zurück'), () => _setLoud(s, false));
  }

  void _sendChunks(_OutXfer x, List<int> idx) {
    final me = settings.myNum == 0 ? 0x4C520000 : settings.myNum;
    final call = _cut(settings.callsign.trim().toUpperCase(), 12);
    x.inFlight += idx.length;
    for (final i in idx) {
      final pkt = LrPacket.build(LrType.file, me, _newId(), call, '', x.chunks[i]);
      _enqueueFile(x.slot, pkt, tr('Datei {0}: Teil {1}/{2}', [x.msg.text, i + 1, x.chunks.length]), (ev) {
        x.sent.add(i);
        if (x.round == 0) x.msg.progress = x.sent.length / x.chunks.length;
        if (!ev.ok) x.msg.info = statusText(ev.status);
        x.inFlight--;
        if (x.inFlight == 0 && !x.finished) {
          // Runde gesendet: inzwischen gemeldete Lücken gleich nachschicken, sonst auf die Empfänger warten
          if (x.pending.isNotEmpty) {
            _resend(x);
          } else {
            _awaitFileAck(x);
          }
        }
        notifyListeners();
      }, x.fast ? 10 : 150);
    }
    x.msg.status = MsgStatus.pending;
  }

  /// Fehlende Teile (von allen Empfängern zusammen) noch einmal senden – so lange, bis alle vollständig sind oder
  /// mehrere Runden hintereinander nichts besser wird.
  void _resend(_OutXfer x) {
    final miss = x.pending.toList()..sort();
    x.pending.clear();
    if (miss.isEmpty || x.finished) return;
    final total = x.missingBy.values.fold<int>(0, (a, b) => a + b);
    if (!x.policy.next(total > 0 ? total : miss.length)) {
      x.msg.info = tr('unvollständig bei {0} – es wird nicht mehr besser, Übertragung beendet', [x.missingBy.keys.join(', ')]);
      _finishOut(x);
      return;
    }
    x.round++;
    x.probes = 0;
    x.msg.info = tr('Runde {0}: {1} fehlende Teile werden nachgesendet', [x.round, miss.length]);
    _sendChunks(x, miss);
  }

  void _awaitFileAck(_OutXfer x) {
    x.timer?.cancel();
    x.msg.status = MsgStatus.sent;
    if (x.ackedBy.isEmpty) x.msg.info = tr('gesendet, warte auf Bestätigung …');
    x.timer = Timer(Duration(seconds: x.fast ? 2 : 8 + x.probes * 2), () {
      if (x.finished || x.inFlight > 0) return;
      if (x.pending.isNotEmpty) {
        _resend(x);
        return;
      }
      if (x.probes >= 5 || (x.ackedBy.isNotEmpty && x.missingBy.isEmpty)) {
        _finishOut(x);
        return;
      }
      // Nachfragen: letztes Stück noch einmal senden, darauf antworten die Empfänger (fertig oder mit Lücken)
      x.probes++;
      _sendChunks(x, [x.chunks.length - 1]);
    });
  }

  /// Eigene Übertragung beenden (alle fertig, oder es antwortet niemand mehr). Sie bleibt noch 2 min bekannt:
  /// meldet sich ein Empfänger danach noch mit Lücken, geht es weiter.
  void _finishOut(_OutXfer x) {
    if (x.finished) return;
    x.finished = true;
    x.timer?.cancel();
    x.collect?.cancel();
    x.collect = null;
    final open = x.missingBy.keys.where((w) => !x.ackedBy.contains(w)).toList();
    if (x.ackedBy.isNotEmpty) {
      x.msg.status = MsgStatus.acked;
      x.msg.progress = 1;
      x.msg.info = open.isEmpty
          ? tr('vollständig empfangen von {0}', [x.ackedBy.join(', ')])
          : tr('vollständig bei {0}, unvollständig bei {1}', [x.ackedBy.join(', '), open.join(', ')]);
    } else if (open.isEmpty) {
      x.msg.info = tr('keine Bestätigung');
    }
    if (x.fast) {
      _endFast(x);
    } else {
      _loudOff(x.slot);
    }
    Timer(const Duration(minutes: 2), () {
      if (x.finished && identical(_outX[x.xfer], x)) _outX.remove(x.xfer);
    });
    _scheduleSave();
    notifyListeners();
  }

  void _onFileAck(LrPacket p, String who) {
    final a = FileAck.parse(p.body);
    if (a == null) return;
    final x = _outX[a.xfer];
    if (x == null) return;
    if (a.done) {
      if (!x.ackedBy.contains(who)) x.ackedBy.add(who);
      x.missingBy.remove(who);
      x.msg.status = MsgStatus.acked;
      x.msg.info = tr('vollständig empfangen von {0}', [x.ackedBy.join(', ')]);
      if (!x.finished && x.missingBy.isEmpty && x.pending.isEmpty && x.inFlight == 0) _finishOut(x);
      _scheduleSave();
    } else if (a.missing.isNotEmpty) {
      if (x.finished) {
        // meldet sich nach dem Ende noch mit Lücken: weitermachen (nicht auf dem 2,4-GHz-Kanal, der ist schon zu)
        if (x.fast) return;
        x.finished = false;
        x.policy.stall = 0;
        if (settings.lrFileLoud) _enqueueAction(x.slot, tr('volle Leistung für die Datei'), () => _setLoud(x.slot, true));
      }
      x.missingBy[who] = a.total;
      x.pending.addAll(a.missing.where((i) => i < x.chunks.length));
      x.timer?.cancel();
      x.msg.info = tr('{0} Teile fehlen bei {1} – sende erneut', [a.total, who]);
      // kurz sammeln, falls noch andere Empfänger melden; läuft gerade eine Runde, wird danach nachgeschickt
      if (x.inFlight == 0) {
        x.collect ??= Timer(Duration(milliseconds: x.fast ? 300 : 1500), () {
          x.collect = null;
          if (x.inFlight == 0) _resend(x);
        });
      }
    }
    notifyListeners();
  }

  /// 2,4-GHz-Dateikanal für dieses Modul benutzen? (Einstellung an, echtes Modem, nicht schon dort)
  bool _fast24(ModemSlot s) => settings.lrFile24 && s.kind != TransportKind.demo && !s.on24 && !s.send24;

  /// 2425 MHz liegt im ISM-Band und im 13-cm-Amateurfunkband; SF5 mit 812,5 kHz: ein 200-Byte-Teil braucht ~20 ms.
  static const file24Hz = 2425000000;
  LoraCfg file24Cfg(ModemSlot s) {
    final c = LoraCfg(freqHz: file24Hz, bwHz: 812500, sf: 5, cr: 5, sync: 0x12, powerDbm: 0, preamble: 12);
    final lim = powerLimit(c.freqHz, bwHz: c.bwHz, licensed: settings.licensed);
    c.powerDbm = lim.allowed ? lim.maxDbm : 0;
    return c;
  }

  /// Modul auf den 2,4-GHz-Dateikanal ([cfg]) bzw. zurück in seine Betriebsart (cfg == null).
  Future<void> _set24(ModemSlot s, LoraCfg? cfg) async {
    final c = s.client;
    if (c == null) return;
    if (cfg == null) {
      s._back24?.cancel();
      if (!s.on24) return;
      await applyMode(s);
      _log(s.role, LogKind.info, tr('zurück auf dem normalen LR-Kanal'));
      return;
    }
    final lim = s.config?.limits;
    if (lim == null || !lim.allow24 || lim.maxPwr24 < cfg.powerDbm) {
      await c.setLimits(Limits(
          allowMask: (lim?.allowMask ?? 1) | 2,
          maxPwrSub: lim?.maxPwrSub ?? chipMaxSubGhz,
          maxPwr24: chipMax24,
          dutyPermille: lim?.dutyPermille ?? 0));
    }
    // Quarzkorrektur gilt in ppm: auf 2,4 GHz entsprechend größer
    final base = baseCfg(s, modeOf(s)).freqHz;
    final t = cfg.copy()..freqHz = cfg.freqHz + (base > 0 ? (_corr(s) * cfg.freqHz / base).round() : 0);
    try {
      await c.setLora(t.copy()
        ..freqHz = t.freqHz + 30000000
        ..powerDbm = 0); // Frequenzsprung >= 20 MHz: Empfangsteil wird kalibriert
    } catch (_) {}
    await c.setLora(t);
    await c.rxStart();
    s.on24 = true;
    try {
      s.config = await c.config();
    } catch (_) {}
    _log(s.role, LogKind.info, tr('2,4-GHz-Dateikanal: {0}, {1} dBm', [t.summary, t.powerDbm]));
    notifyListeners();
  }

  /// Empfänger: nach [seconds] ohne Pakete auf 2,4 GHz zurück auf den normalen Kanal.
  void _touch24(ModemSlot s, {int seconds = 5}) {
    s._back24?.cancel();
    s._back24 = Timer(Duration(seconds: seconds), () {
      if (s.on24 && !s.send24) _enqueueAction(s, tr('zurück auf den normalen LR-Kanal'), () => _set24(s, null));
    });
  }

  /// Sender: Übertragung auf 2,4 GHz beendet – zurückschalten; hat dort niemand geantwortet, auf 70 cm senden.
  void _endFast(_OutXfer x) {
    final s = x.slot;
    _enqueueAction(s, tr('zurück auf den normalen LR-Kanal'), () async {
      s.send24 = false;
      await _set24(s, null);
    });
    if (x.ackedBy.isEmpty && !x.fallback) {
      x
        ..fallback = true
        ..fast = false
        ..finished = false
        ..round = 0
        ..probes = 0;
      x.sent.clear();
      x.pending.clear();
      x.missingBy.clear();
      x.policy.reset();
      _outX[x.xfer] = x;
      x.msg.info = tr('keine Antwort auf 2,4 GHz – sende auf 70 cm');
      if (settings.lrFileLoud) _enqueueAction(s, tr('volle Leistung für die Datei'), () => _setLoud(s, true));
      _sendChunks(x, settings.lrFileTwice ? fileSendOrder(x.chunks.length) : [for (var i = 0; i < x.chunks.length; i++) i]);
    }
  }

  void _onFileOffer(ModemSlot s, LrPacket p, String key, String who) {
    final o = FileOffer.parse(p.body);
    if (o == null || _doneX.contains('$key:${o.xfer}')) return;
    if (!settings.lrFile24 || s.kind == TransportKind.demo || s.send24) {
      _log(s.role, LogKind.rx, tr('{0} sendet eine Datei auf 2,4 GHz – der 2,4-GHz-Dateikanal ist hier aus', [who]));
      return;
    }
    if (o.freqHz < 2400000000 || o.freqHz > 2483500000 || !LoraCfg.bandwidths.contains(o.bwHz) || o.sf < 5 || o.sf > 12) {
      return;
    }
    final cfg = LoraCfg(freqHz: o.freqHz, bwHz: o.bwHz, sf: o.sf, cr: o.cr.clamp(5, 8), sync: 0x12, powerDbm: 0, preamble: 12);
    final lim = powerLimit(cfg.freqHz, bwHz: cfg.bwHz, licensed: settings.licensed);
    cfg.powerDbm = lim.allowed ? lim.maxDbm : 0;
    _log(s.role, LogKind.rx, tr('{0} sendet {1} Teile auf {2} MHz – wechsle dorthin', [who, o.count, (o.freqHz / 1e6).toStringAsFixed(1)]));
    _enqueueAction(s, tr('Wechsel auf 2,4 GHz'), () => _set24(s, cfg));
    _touch24(s, seconds: 8);
  }

  _InXfer _inFor(String xkey, String key, String who, RxEvent e, int xfer, int count, int size) {
    return _inX.putIfAbsent(xkey, () {
      final m = Message(
          chat: 'lr',
          from: key,
          fromName: who,
          text: tr('Datei wird empfangen …'),
          at: e.at,
          mine: false,
          status: MsgStatus.received,
          pktId: xfer,
          rssi: e.rssi,
          snr: e.snr,
          hops: 0)
        ..fileSize = size;
      messages.add(m);
      if (openChat != 'lr') unread['lr'] = (unread['lr'] ?? 0) + 1;
      return _InXfer(xfer, count, size, m);
    });
  }

  /// Ankündigung einer Datei: Übertragung anlegen, eigene Sendungen für die angekündigte Zeit zurückhalten.
  void _onFileAnnounce(ModemSlot s, LrPacket p, String key, String who, RxEvent e) {
    final a = FileAnnounce.parse(p.body);
    if (a == null) return;
    final xkey = '$key:${a.xfer}';
    if (_doneX.contains(xkey)) return;
    final x = _inFor(xkey, key, who, e, a.xfer, a.count, a.size);
    if (x.name.isEmpty) {
      x.name = a.name;
      x.mime = a.mime;
      x.msg.mime = a.mime;
    }
    _holdFor(s, DateTime.now().add(Duration(seconds: (a.airtimeS * 1.5).ceil() + 20)));
    if (!x.announced) {
      x.announced = true;
      x.msg.info = tr('{0} kündigt an: {1} ({2} KB, {3} Teile, ca. {4} s)',
          [who, a.name, (a.size / 1024).toStringAsFixed(0), a.count, a.airtimeS]);
      _log(s.role, LogKind.rx, tr('{0} kündigt eine Datei an – eigene Sendungen warten', [who]), _sig(e));
      if (settings.sound) SystemSound.play(SystemSoundType.alert);
    }
    // kommt danach gar nichts an: nach der angekündigten Zeit melden, dass alles fehlt
    if (x.parts.isEmpty) {
      x.timer?.cancel();
      x.timer = Timer(Duration(seconds: a.airtimeS + 15), () => _nack(s, xkey, x));
    }
    notifyListeners();
  }

  /// Fehlende Teile melden – und nachhaken, solange vom Sender nichts mehr kommt (höchstens 8-mal hintereinander).
  void _nack(ModemSlot s, String xkey, _InXfer x) {
    if (!identical(_inX[xkey], x)) return;
    final miss = [for (var i = 0; i < x.count; i++) if (!x.parts.containsKey(i)) i];
    if (miss.isEmpty) return;
    if (x.nacks >= 8) {
      x.msg.info = tr('{0} von {1} Teilen – der Sender antwortet nicht mehr', [x.parts.length, x.count]);
      notifyListeners();
      return;
    }
    x.nacks++;
    _sendFileAck(s, x.xfer, false, miss);
    x.timer?.cancel();
    x.timer = Timer(Duration(seconds: 10 + _rnd.nextInt(6) + (miss.length > 30 ? 10 : 0)), () => _nack(s, xkey, x));
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
    final x = _inFor(xkey, key, who, e, c.xfer, c.count, c.size);
    if (c.index == 0) {
      x.name = c.name ?? '';
      x.mime = c.mime ?? '';
      x.msg.mime = x.mime;
    }
    x.parts[c.index] = c.data;
    x.nacks = 0;
    x.msg.progress = x.parts.length / x.count;
    x.msg.info = tr('{0} von {1} Teilen', [x.parts.length, x.count]);
    x.timer?.cancel();
    // solange Teile kommen, bleibt der Kanal für diese Übertragung frei
    _holdFor(s, DateTime.now().add(const Duration(seconds: 15)));
    if (x.parts.length == x.count) {
      unawaited(_finishIn(s, xkey, x));
      return;
    }
    // nach dem letzten Stück (oder 4 s Pause) melden, was fehlt
    x.timer = Timer(Duration(milliseconds: c.index == c.count - 1 ? 600 + _rnd.nextInt(900) : 4000), () => _nack(s, xkey, x));
    notifyListeners();
  }

  Future<void> _finishIn(ModemSlot s, String xkey, _InXfer x) async {
    _inX.remove(xkey);
    _doneX.add(xkey);
    x.timer?.cancel();
    // Übertragung fertig: nur noch kurz zurückhalten (andere Empfänger melden sich evtl. noch)
    if (_quiet(s) && !_inX.values.any((o) => o.parts.length < o.count)) {
      s.quietUntil = null;
      _holdFor(s, DateTime.now().add(const Duration(seconds: 5)));
    }
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
    _enqueueFile(s, pkt, done ? tr('Datei vollständig – bestätigt') : tr('Datei: {0} Teile fehlen', [missing.length]));
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

  /// Aktuelle Position vom GPS-Modul der Node (höchstens 30 s alt), sonst null.
  GpsFix? get nodeFix => _nodeFixFresh ? nodeGps.last : null;

  /// Position in einem Chat teilen: als Text (MGRS und Grad) und bei Meshtastic zusätzlich als Positionspaket,
  /// damit sie bei den anderen auch auf der Karte erscheint. Gibt Fehlertext oder null zurück.
  String? sharePosition(String chat, double lat, double lon, double? alt) {
    final text = tr('📍 Position {0} · {1}, {2}{3}',
        [toMgrs(lat, lon), lat.toStringAsFixed(5), lon.toStringAsFixed(5), alt == null ? '' : ' · ${alt.round()} m']);
    final err = sendText(chat, text);
    if (err != null) return err;
    if (chat.startsWith('dm:')) {
      sendPosition(dest: int.parse(chat.substring(4), radix: 16));
    } else if (chat.startsWith('mt:')) {
      sendPosition();
    }
    return null;
  }

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
        if (_boxHandlesLr(s) && !e.replay) {
          // die Node bestätigt und fordert selbst nach – hier nur anzeigen
          runZoned(() => _onLr(s, e), zoneValues: {#lrMute: true});
        } else {
          _onLr(s, e);
        }
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
    if (s.on24 && !s.send24) _touch24(s);
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
        // Rückmeldungen zu eigenen Dateien (die die App selbst sendet, z. B. über 2,4 GHz) immer auswerten
        if (Zone.current[#lrReplay] != true) runZoned(() => _onFileAck(p, who), zoneValues: {#lrMute: false});
        break;
      case LrType.fileOffer:
        _onFileOffer(s, p, key, who);
        break;
      case LrType.fileAnnounce:
        _onFileAnnounce(s, p, key, who, e);
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
  final Set<int> pending = {}; // von Empfängern gemeldet, noch nicht nachgesendet
  final Map<String, int> missingBy = {}; // Empfänger -> wie viele Teile ihm zuletzt fehlten
  final ResendPolicy policy = ResendPolicy();
  int round = 0, probes = 0, inFlight = 0;
  bool finished = false;
  bool fast = false, fallback = false; // 2,4-GHz-Dateikanal / danach auf 70 cm wiederholt
  Timer? timer, collect;
  _OutXfer(this.xfer, this.chunks, this.msg, this.slot);
}

class _InXfer {
  final int xfer, count, size;
  final Message msg;
  final Map<int, Uint8List> parts = {};
  String name = '', mime = '';
  bool announced = false;
  int nacks = 0; // Rückmeldungen ohne Antwort hintereinander
  Timer? timer;
  _InXfer(this.xfer, this.count, this.size, this.msg);
}
