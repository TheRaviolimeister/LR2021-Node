import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'transport.dart';
import '../i18n.dart';

/// Verbindung zur Node über das Konsolen-Kabel (CP2102 am Pi, 115200 Baud).
/// Die App meldet sich an der Linux-Konsole an und startet /opt/lr2021/serialbridge.py.
/// Danach laufen beide Modems (Kanal 1 = A, 2 = B) und das GPS (Kanal 3) über diese eine Leitung:
///   [Kanal] [COBS-Rahmen bzw. NMEA-Zeile] 0x00     Steuerung: Kanal 0x7F ('P' Ping, 'G' GPS, 'Q' Ende)
class NodeSerialLink {
  static final Map<String, NodeSerialLink> _links = {};
  static String user = 'root';
  static String password = 'lr2021node';

  final PortChoice port;
  final Transport _raw;
  final Map<int, _Channel> _chans = {};
  final StreamController<String> _gps = StreamController<String>.broadcast();
  final void Function(String text)? log;
  StreamSubscription<Uint8List>? _sub;
  Timer? _keepAlive;
  final List<int> _buf = [];
  bool _closed = false;

  NodeSerialLink._(this.port, this._raw, this.log);

  /// NMEA-Zeilen vom GPS der Node (nach [gpsOn]).
  Stream<String> get gpsLines => _gps.stream;
  bool get closed => _closed;

  /// Aktive Verbindung (für GPS), falls eine offen ist.
  static NodeSerialLink? get active => _links.values.where((l) => !l._closed).firstOrNull;

  /// Kanal für ESP32 [role] öffnen (baut die Verbindung beim ersten Mal auf).
  static Future<Transport> channel(PortChoice port, String role, {void Function(String)? log}) async {
    var l = _links[port.id];
    if (l == null || l._closed) {
      l = await _open(port, log);
      _links[port.id] = l;
    }
    return l._channel(role == 'A' ? 1 : 2);
  }

  static Future<NodeSerialLink> _open(PortChoice port, void Function(String)? log) async {
    final raw = await openUsb(port, baud: 115200);
    final l = NodeSerialLink._(port, raw, log);
    try {
      await l._start();
    } catch (e) {
      l._closed = true;
      await raw.close();
      rethrow;
    }
    return l;
  }

  // ------------------------------------------------------------------ Anmelden und Brücke starten
  Future<void> _start() async {
    final text = StringBuffer();
    final bytes = <int>[];
    final sub = _raw.input.listen((d) {
      bytes.addAll(d);
      text.write(latin1.decode(d, allowInvalid: true));
    });
    Future<bool> waitFor(bool Function() cond, Duration t) async {
      final end = DateTime.now().add(t);
      while (DateTime.now().isBefore(end)) {
        if (cond()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return cond();
    }

    String tail() {
      final s = text.toString();
      return s.length > 400 ? s.substring(s.length - 400) : s;
    }

    Future<void> send(String s) => _raw.write(Uint8List.fromList(latin1.encode(s)));
    try {
      // 1) Läuft die Brücke schon (App wurde z. B. nur neu gestartet)?
      await _raw.write(Uint8List.fromList([0x7F, 0x50, 0x00]));
      if (await waitFor(() => _hasPong(bytes), const Duration(milliseconds: 700))) {
        log?.call(tr('Node-Kabel: Brücke lief schon'));
      } else {
        // 2) Konsole: laufendes Programm abbrechen, Zustand erkennen
        text.clear();
        await send('\x03\r');
        await waitFor(() => RegExp(r'(login:|[#\$] ?$)').hasMatch(tail().trimRight()), const Duration(seconds: 3));
        if (tail().contains('login:')) {
          log?.call(tr('Node-Kabel: melde mich als {0} an', [user]));
          text.clear();
          await send('$user\r');
          if (!await waitFor(() => tail().contains('assword'), const Duration(seconds: 5))) {
            throw Exception(tr('Die Node fragt nicht nach dem Passwort – läuft der Pi? (Konsole: {0})', [_clean(tail())]));
          }
          text.clear();
          await send('$password\r');
          final ok = await waitFor(
              () => RegExp(r'[#\$] ?$').hasMatch(tail().trimRight()) || tail().contains('incorrect'), const Duration(seconds: 15));
          if (!ok || tail().contains('incorrect')) {
            throw Exception(tr('Anmeldung an der Node fehlgeschlagen (Benutzer {0}). Passwort unter Einstellungen → Verbindung prüfen.', [user]));
          }
        } else if (!RegExp(r'[#\$] ?$').hasMatch(tail().trimRight())) {
          // keine Antwort: vielleicht gerade beim Starten
          text.clear();
          await send('\r');
          if (!await waitFor(() => tail().contains('login:') || RegExp(r'[#\$] ?$').hasMatch(tail().trimRight()),
              const Duration(seconds: 4))) {
            throw Exception(tr('Keine Antwort von der Node-Konsole. Ist das Kabel am CP2102 und läuft der Pi?'));
          }
          if (tail().contains('login:')) return await _restart(sub);
        }
        // 3) Brücke starten (ersetzt die Shell; beim Ende kommt wieder „login:“)
        text.clear();
        await send('exec python3 /opt/lr2021/serialbridge.py\r');
        if (!await waitFor(() => tail().contains('LRB1'), const Duration(seconds: 8))) {
          throw Exception(tail().contains('No such file')
              ? tr('Auf der Node fehlt /opt/lr2021/serialbridge.py – bitte das neue Update-Paket einspielen.')
              : tr('Brücke auf der Node startet nicht ({0})', [_clean(tail())]));
        }
        log?.call(tr('Node-Kabel: Brücke gestartet'));
      }
    } finally {
      await sub.cancel();
    }
    // Rest nach der Startmeldung verwerfen, ab jetzt nur Rahmen
    _sub = _raw.input.listen(_onData, onDone: _lost, onError: (Object _) => _lost());
    _keepAlive = Timer.periodic(const Duration(seconds: 20), (_) => _ctrl('P'));
  }

  Future<void> _restart(StreamSubscription<Uint8List> sub) async {
    await sub.cancel();
    return _start();
  }

  static bool _hasPong(List<int> b) {
    for (var i = 0; i + 1 < b.length; i++) {
      if (b[i] == 0x7F && b[i + 1] == 0x70) return true;
    }
    return false;
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'[\x00-\x1F\x7F-\xFF]'), ' ').trim();

  void _onData(Uint8List d) {
    for (final b in d) {
      if (b != 0) {
        _buf.add(b);
        if (_buf.length > 4096) _buf.clear();
        continue;
      }
      if (_buf.isEmpty) continue;
      final ch = _buf[0];
      final body = Uint8List.fromList(_buf.sublist(1));
      _buf.clear();
      if (ch == 1 || ch == 2) {
        final c = _chans[ch];
        if (c != null && !c._ctrl.isClosed) c._ctrl.add(Uint8List.fromList([...body, 0]));
      } else if (ch == 3) {
        _gps.add(latin1.decode(body, allowInvalid: true));
      }
      // 0x7F (Pong) und Müll werden ignoriert
    }
  }

  void _lost() {
    if (_closed) return;
    _closed = true;
    _keepAlive?.cancel();
    for (final c in _chans.values) {
      if (!c._ctrl.isClosed) c._ctrl.close();
    }
    _chans.clear();
  }

  Future<void> _ctrl(String cmd) async {
    if (_closed) return;
    try {
      await _raw.write(Uint8List.fromList([0x7F, cmd.codeUnitAt(0), 0x00]));
    } catch (_) {}
  }

  Future<void> gpsOn(bool on) => _ctrl(on ? 'G' : 'g');

  Transport _channel(int ch) {
    final old = _chans[ch];
    if (old != null && !old._ctrl.isClosed) old._ctrl.close();
    final c = _Channel(this, ch);
    _chans[ch] = c;
    return c;
  }

  Future<void> _write(int ch, Uint8List data) async {
    if (_closed) throw Exception(tr('Node-Kabel getrennt'));
    // Jeden Rahmen (endet mit 0x00) mit der Kanalnummer versehen
    final out = <int>[];
    final pend = _chans[ch]!._pending;
    for (final b in data) {
      if (b == 0) {
        if (pend.isNotEmpty) out.addAll([ch, ...pend, 0]);
        pend.clear();
      } else {
        pend.add(b);
      }
    }
    if (out.isNotEmpty) await _raw.write(Uint8List.fromList(out));
  }

  Future<void> _release(int ch) async {
    _chans.remove(ch);
    if (_chans.isEmpty && !_closed) {
      // keiner mehr verbunden: Brücke beenden, Konsole wieder frei
      await _ctrl('Q');
      _closed = true;
      _keepAlive?.cancel();
      await _sub?.cancel();
      await _raw.close();
      if (!_gps.isClosed) await _gps.close();
      _links.remove(port.id);
    }
  }
}

class _Channel implements Transport {
  final NodeSerialLink link;
  final int ch;
  final StreamController<Uint8List> _ctrl = StreamController<Uint8List>.broadcast();
  final List<int> _pending = [];
  bool _released = false;
  _Channel(this.link, this.ch);

  @override
  String get label => 'Node-Kabel ${link.port.id} · ${ch == 1 ? 'A' : 'B'}';

  @override
  Stream<Uint8List> get input => _ctrl.stream;

  @override
  Future<void> write(Uint8List data) => link._write(ch, data);

  @override
  Future<void> close() async {
    if (_released) return;
    _released = true;
    if (!_ctrl.isClosed) await _ctrl.close();
    await link._release(ch);
  }
}
