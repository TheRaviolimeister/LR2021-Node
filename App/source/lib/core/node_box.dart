import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'node_serial.dart';
import '../i18n.dart';

/// Postfach der Node (lr2021d ab 1.2, /opt/lr2021/postbox.py): eine JSON-Zeile je Nachricht.
/// Anfragen tragen eine Nummer (rid), die Antwort dieselbe; ohne rid sind es Meldungen der Node
/// (job, scan, cursor, file).
class NodeBox {
  final Future<void> Function(String line) _send;
  final Future<void> Function()? _onClose;
  StreamSubscription<String>? _sub;
  final StreamController<Map<String, dynamic>> _events = StreamController<Map<String, dynamic>>.broadcast();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _rid = 0;
  bool closed = false;
  final String via;
  Map<String, dynamic> hello = const {};

  NodeBox._(this._send, Stream<String> lines, this._onClose, this.via) {
    _sub = lines.listen(_onLine, onDone: _done, onError: (Object _) => _done());
  }

  /// Über das Netz (WLAN-Hotspot, USB-Netz): TCP-Port 2024 der Node.
  static Future<NodeBox> overTcp(String host, {int port = 2024}) async {
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    final lines = s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
    return NodeBox._((l) async {
      s.add(utf8.encode('$l\n'));
      await s.flush();
    }, lines, () async {
      try {
        await s.close();
      } catch (_) {}
      s.destroy();
    }, '$host:$port');
  }

  /// Über Node-Kabel oder Bluetooth: Kanal 4 der Brücke.
  static NodeBox overLink(NodeSerialLink l) {
    l.useBox();
    return NodeBox._(l.sendBox, l.boxLines, l.releaseBox, l.label);
  }

  Stream<Map<String, dynamic>> get events => _events.stream;
  List<String> get caps => ((hello['caps'] as List?) ?? const []).cast<String>();
  String get nodeId => hello['node'] as String? ?? '';

  void _onLine(String line) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final rid = m['rid'];
    if (rid is int) {
      final c = _pending.remove(rid);
      if (c != null && !c.isCompleted) c.complete(m);
      return;
    }
    if (!_events.isClosed) _events.add(m);
  }

  void _done() {
    if (closed) return;
    closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(tr('Postfach getrennt')));
    }
    _pending.clear();
    if (!_events.isClosed) _events.close();
  }

  Future<Map<String, dynamic>> call(String op, [Map<String, dynamic> args = const {}, Duration timeout = const Duration(seconds: 15)]) async {
    if (closed) throw StateError(tr('Postfach getrennt'));
    final rid = ++_rid;
    final c = Completer<Map<String, dynamic>>();
    _pending[rid] = c;
    await _send(jsonEncode({...args, 'op': op, 'rid': rid}));
    try {
      final r = await c.future.timeout(timeout);
      final err = r['error'];
      if (err != null) throw Exception(err);
      return r;
    } on TimeoutException {
      _pending.remove(rid);
      throw Exception(tr('Postfach antwortet nicht ({0})', [op]));
    }
  }

  Future<void> close() async {
    if (closed) return;
    await _sub?.cancel();
    _done();
    await _onClose?.call();
  }
}

/// Ein Kanal aus der Frequenzsuche der Node.
class ScanChannel {
  final double mhz, busy, maxDb;
  ScanChannel(this.mhz, this.busy, this.maxDb);
  static ScanChannel from(Map m) =>
      ScanChannel((m['mhz'] as num).toDouble(), (m['busy'] as num).toDouble(), (m['max_db'] as num).toDouble());
}

/// Ergebnis der Frequenzsuche.
class ScanResult {
  final double fromMhz, toMhz, bwKhz, minutes;
  final int sweeps;
  final double? floorDbm;
  final List<ScanChannel> channels, quiet;
  final DateTime at;
  ScanResult(this.fromMhz, this.toMhz, this.bwKhz, this.minutes, this.sweeps, this.floorDbm, this.channels, this.quiet, this.at);

  static ScanResult? from(Object? o) {
    if (o is! Map) return null;
    try {
      return ScanResult(
        (o['from_mhz'] as num).toDouble(),
        (o['to_mhz'] as num).toDouble(),
        (o['bw_khz'] as num).toDouble(),
        (o['minutes'] as num? ?? 0).toDouble(),
        o['sweeps'] as int? ?? 0,
        (o['floor_dbm'] as num?)?.toDouble(),
        [for (final c in (o['channels'] as List? ?? const [])) ScanChannel.from(c as Map)],
        [for (final c in (o['quiet'] as List? ?? const [])) ScanChannel.from(c as Map)],
        DateTime.fromMillisecondsSinceEpoch(((o['t'] as num? ?? 0) * 1000).round()),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Hinweis zum 70-cm-Bandplan (IARU Region 1) für eine Frequenz – nur zur Orientierung.
String bandHint(double mhz) {
  if (mhz >= 435.0 && mhz < 438.0) return tr('Satellitenbereich – nicht benutzen');
  if (mhz >= 433.05 && mhz <= 434.79) {
    if ((mhz - 433.92).abs() < 0.15) return tr('lizenzfrei, viele Funkschlüssel/Wetterstationen');
    if ((mhz - 433.775).abs() < 0.07) return tr('LoRa-APRS');
    return tr('auch lizenzfrei nutzbar (10 mW)');
  }
  if (mhz >= 438.65 && mhz < 439.45) return tr('Relaisausgaben – meiden');
  if (mhz >= 431.05 && mhz < 431.85) return tr('Relaiseingaben – meiden');
  if (mhz >= 432.0 && mhz < 432.1) return tr('Schmalband/EME – meiden');
  if (mhz >= 430.0 && mhz <= 440.0) return tr('70-cm-Band (nur mit Lizenz)');
  return tr('außerhalb des 70-cm-Bands');
}
