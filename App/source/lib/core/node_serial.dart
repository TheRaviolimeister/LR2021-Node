import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'transport.dart';
import '../i18n.dart';

/// Eine Verbindung zur Node, über die alles läuft (Brücke auf der Node, /opt/lr2021/serialbridge.py):
///  * Node-Kabel (CH340 der Trägerplatine oder CP2102, 115200 Baud): die App meldet sich an der Linux-Konsole an
///    und startet die Brücke
///  * Bluetooth (Android): Sammelkanal der Node, die Brücke läuft dort schon – ohne Anmeldung
/// Rahmen:  [Kanal] [Daten] 0x00   Kanal 1 = ESP32 A, 2 = ESP32 B (COBS-Rahmen), 3 = GPS (NMEA-Zeile),
///          4 = Postfach (JSON-Zeile), 0x7F = Steuerung ('P' Ping, 'G'/'g' GPS, 'Q' Ende)
class NodeSerialLink {
  static final Map<String, NodeSerialLink> _links = {};
  static String user = 'root';
  static String password = 'lr2021node';

  final PortChoice port;
  final bool bluetooth;
  final Transport _raw;
  final Map<int, _Channel> _chans = {};
  final StreamController<String> _gps = StreamController<String>.broadcast();
  final StreamController<String> _box = StreamController<String>.broadcast();
  final void Function(String text)? log;
  StreamSubscription<Uint8List>? _sub;
  Timer? _keepAlive;
  final List<int> _buf = [];
  bool _closed = false;
  int _boxUsers = 0;
  String bridgeVersion = '1';

  NodeSerialLink._(this.port, this._raw, this.log, this.bluetooth);

  /// NMEA-Zeilen vom GPS der Node (nach [gpsOn]).
  Stream<String> get gpsLines => _gps.stream;
  /// JSON-Zeilen vom Postfach der Node (Kanal 4).
  Stream<String> get boxLines => _box.stream;
  bool get closed => _closed;
  String get label => bluetooth ? 'Bluetooth ${port.label.split('  ·  ').first}' : 'Node-Kabel ${port.id}';

  /// Aktive Verbindung (für GPS und Postfach), falls eine offen ist.
  static NodeSerialLink? get active => _links.values.where((l) => !l._closed).firstOrNull;

  static String _key(PortChoice p, bool bt) => bt ? 'bt:${p.id}' : p.id;

  /// Kanal für ESP32 [role] öffnen (baut die Verbindung beim ersten Mal auf).
  static Future<Transport> channel(PortChoice port, String role, {bool bluetooth = false, void Function(String)? log}) async {
    final l = await open(port, bluetooth: bluetooth, log: log);
    return l._channel(role == 'A' ? 1 : 2);
  }

  static Future<NodeSerialLink> open(PortChoice port, {bool bluetooth = false, void Function(String)? log}) async {
    final k = _key(port, bluetooth);
    var l = _links[k];
    if (l == null || l._closed) {
      final raw = bluetooth ? await BtTransport.open(port) : await openUsb(port, baud: 115200);
      l = NodeSerialLink._(port, raw, log, bluetooth);
      try {
        await l._start();
      } catch (e) {
        l._closed = true;
        await raw.close();
        rethrow;
      }
      _links[k] = l;
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
      // 1) Läuft die Brücke schon (Bluetooth immer; Kabel z. B. nach Neustart der App)?
      await _raw.write(Uint8List.fromList([0x7F, 0x50, 0x00]));
      if (await waitFor(() => _hasPong(bytes), Duration(milliseconds: bluetooth ? 4000 : 700))) {
        if (!bluetooth) log?.call(tr('Node-Kabel: Brücke lief schon'));
      } else if (bluetooth) {
        throw Exception(tr('Die Node antwortet nicht über Bluetooth. Läuft dort lr2021d 1.2 oder neuer?'));
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
            throw Exception(tr('Keine Antwort von der Node-Konsole. Steckt das Konsolen-Kabel und läuft der Pi?'));
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
        bytes.clear();
        await _raw.write(Uint8List.fromList([0x7F, 0x50, 0x00]));
        await waitFor(() => _hasPong(bytes), const Duration(milliseconds: 700));
      }
      bridgeVersion = _pongVersion(bytes) ?? '1';
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

  static String? _pongVersion(List<int> b) {
    for (var i = 0; i + 2 < b.length; i++) {
      if (b[i] == 0x7F && b[i + 1] == 0x70 && b[i + 2] != 0) return String.fromCharCode(b[i + 2]);
    }
    return null;
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'[\x00-\x1F\x7F-\xFF]'), ' ').trim();

  void _onData(Uint8List d) {
    for (final b in d) {
      if (b != 0) {
        _buf.add(b);
        if (_buf.length > 8 * 1024 * 1024) _buf.clear();
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
      } else if (ch == 4) {
        _box.add(utf8.decode(body, allowMalformed: true));
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
    if (!_box.isClosed) _box.close();
  }

  Future<void> _ctrl(String cmd) async {
    if (_closed) return;
    try {
      await _raw.write(Uint8List.fromList([0x7F, cmd.codeUnitAt(0), 0x00]));
    } catch (_) {}
  }

  Future<void> gpsOn(bool on) => _ctrl(on ? 'G' : 'g');

  /// Postfach benutzen (Kanal 4, ab Brücke 2). Mit [releaseBox] wieder freigeben.
  bool get hasBox => bridgeVersion.compareTo('2') >= 0;
  void useBox() => _boxUsers++;
  Future<void> releaseBox() async {
    if (_boxUsers > 0) _boxUsers--;
    await _maybeClose();
  }

  Future<void> sendBox(String jsonLine) async {
    if (_closed) throw Exception(tr('Verbindung zur Node getrennt'));
    await _raw.write(Uint8List.fromList([4, ...utf8.encode(jsonLine), 0]));
  }

  Transport _channel(int ch) {
    final old = _chans[ch];
    if (old != null && !old._ctrl.isClosed) old._ctrl.close();
    final c = _Channel(this, ch);
    _chans[ch] = c;
    return c;
  }

  Future<void> _write(int ch, Uint8List data) async {
    if (_closed) throw Exception(tr('Verbindung zur Node getrennt'));
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
    await _maybeClose();
  }

  Future<void> _maybeClose() async {
    if (_chans.isEmpty && _boxUsers == 0 && !_closed) {
      // keiner mehr verbunden: Brücke beenden (Kabel: Konsole wieder frei)
      if (!bluetooth) await _ctrl('Q');
      _closed = true;
      _keepAlive?.cancel();
      await _sub?.cancel();
      await _raw.close();
      if (!_gps.isClosed) await _gps.close();
      if (!_box.isClosed) await _box.close();
      _links.remove(_key(port, bluetooth));
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
  String get label => '${link.label} · ${ch == 1 ? 'A' : 'B'}';

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
