import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:usb_serial/usb_serial.dart';
import '../i18n.dart';

/// Alle Wege zum Modem sprechen dasselbe Byte-Protokoll (COBS-Rahmen).
abstract class Transport {
  String get label;
  Stream<Uint8List> get input;
  Future<void> write(Uint8List data);
  Future<void> close();
}

enum TransportKind { node, network, usb, demo }

/// Verbindungsarten, die auf diesem System möglich sind (iOS hat keinen USB-Seriell-Zugriff).
List<TransportKind> get availableTransportKinds =>
    Platform.isIOS ? const [TransportKind.network, TransportKind.demo] : TransportKind.values;

String transportKindName(TransportKind k) => switch (k) {
      TransportKind.node => 'Node-Kabel',
      TransportKind.usb => 'ESP32-USB',
      TransportKind.network => tr('Netzwerk (Pi)'),
      TransportKind.demo => tr('Demo'),
    };

/// Ein auswählbarer Anschluss.
class PortChoice {
  final String id;
  final String label;
  final bool looksLikeEsp;
  final bool cp210x; // USB-Seriell-Wandler der Node-Konsole
  final Object? handle;
  const PortChoice(this.id, this.label, {this.looksLikeEsp = false, this.cp210x = false, this.handle});
}

bool _isEspVid(int? vid) => vid == 0x1A86 || vid == 0x303A || vid == 0x10C4;

Future<List<PortChoice>> listUsbPorts() async {
  if (Platform.isIOS) return const [];
  if (Platform.isAndroid) {
    final devs = await UsbSerial.listDevices();
    return devs
        .map((d) => PortChoice(
              '${d.deviceId}',
              '${d.productName ?? tr('USB-Gerät')}  ${(d.vid ?? 0).toRadixString(16).padLeft(4, '0')}:${(d.pid ?? 0).toRadixString(16).padLeft(4, '0')}',
              looksLikeEsp: _isEspVid(d.vid),
              cp210x: d.vid == 0x10C4,
              handle: d,
            ))
        .toList();
  }
  final out = <PortChoice>[];
  for (final name in SerialPort.availablePorts) {
    var label = name;
    var esp = false;
    var cp = false;
    try {
      final p = SerialPort(name);
      final desc = p.description;
      int? vid;
      try {
        vid = p.vendorId;
      } catch (_) {}
      esp = _isEspVid(vid);
      cp = vid == 0x10C4 || (desc ?? '').toUpperCase().contains('CP210');
      if (desc != null && desc.isNotEmpty) label = '$name  ·  $desc';
      p.dispose();
    } catch (_) {}
    out.add(PortChoice(name, label, looksLikeEsp: esp, cp210x: cp));
  }
  out.sort((a, b) => (b.looksLikeEsp ? 1 : 0) - (a.looksLikeEsp ? 1 : 0));
  return out;
}

Future<Transport> openUsb(PortChoice c, {int baud = 115200}) async {
  if (Platform.isAndroid) return AndroidUsbTransport.open(c.handle as UsbDevice, baud);
  return DesktopSerialTransport.open(c.id, baud);
}

// ---------------------------------------------------------------- Windows / Linux
class DesktopSerialTransport implements Transport {
  final SerialPort _port;
  final SerialPortReader _reader;
  @override
  final String label;
  final StreamController<Uint8List> _ctrl = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  DesktopSerialTransport._(this._port, this._reader, this.label) {
    _sub = _reader.stream.listen(_ctrl.add, onError: _ctrl.addError, onDone: () => _ctrl.close());
  }

  static Future<DesktopSerialTransport> open(String name, int baud) async {
    final p = SerialPort(name);
    if (!p.openReadWrite()) {
      final e = SerialPort.lastError;
      p.dispose();
      throw Exception(tr('{0} lässt sich nicht öffnen{1}. Ist ein anderes Programm (Skript, Arduino) noch verbunden?', [name, e != null ? ': ${e.message}' : '']));
    }
    final cfg = SerialPortConfig()
      ..baudRate = baud
      ..bits = 8
      ..stopBits = 1
      ..parity = SerialPortParity.none
      ..rts = SerialPortRts.off
      ..dtr = SerialPortDtr.off
      ..cts = SerialPortCts.ignore
      ..dsr = SerialPortDsr.ignore
      ..xonXoff = SerialPortXonXoff.disabled;
    p.config = cfg;
    return DesktopSerialTransport._(p, SerialPortReader(p, timeout: 20), name);
  }

  @override
  Stream<Uint8List> get input => _ctrl.stream;

  @override
  Future<void> write(Uint8List data) async {
    var off = 0;
    while (off < data.length) {
      final n = _port.write(Uint8List.sublistView(data, off), timeout: 500);
      if (n <= 0) throw Exception(tr('Schreiben auf {0} fehlgeschlagen', [label]));
      off += n;
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    try {
      _reader.close();
    } catch (_) {}
    try {
      _port.close();
      _port.dispose();
    } catch (_) {}
    if (!_ctrl.isClosed) await _ctrl.close();
  }
}

// ---------------------------------------------------------------- Android (USB-OTG)
class AndroidUsbTransport implements Transport {
  final UsbPort _port;
  @override
  final String label;
  final StreamController<Uint8List> _ctrl = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  AndroidUsbTransport._(this._port, this.label) {
    final s = _port.inputStream;
    if (s != null) {
      _sub = s.listen(_ctrl.add, onError: _ctrl.addError, onDone: () => _ctrl.close());
    }
  }

  static Future<AndroidUsbTransport> open(UsbDevice d, int baud) async {
    // CH343 (ESP32-S3-DevKit „COM“) ist CDC-ACM-kompatibel
    var type = '';
    if (d.vid == 0x1A86 && d.pid == 0x55D3) type = UsbSerial.CDC;
    if (d.vid == 0x303A) type = UsbSerial.CDC;
    final port = await d.create(type);
    if (port == null) throw Exception(tr('USB-Gerät wird nicht unterstützt'));
    if (!await port.open()) throw Exception(tr('USB-Zugriff verweigert oder Gerät belegt'));
    await port.setDTR(false);
    await port.setRTS(false);
    await port.setPortParameters(baud, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
    return AndroidUsbTransport._(port, d.productName ?? 'USB');
  }

  @override
  Stream<Uint8List> get input => _ctrl.stream;

  @override
  Future<void> write(Uint8List data) => _port.write(data);

  @override
  Future<void> close() async {
    await _sub?.cancel();
    try {
      await _port.close();
    } catch (_) {}
    if (!_ctrl.isClosed) await _ctrl.close();
  }
}

// ---------------------------------------------------------------- Netzwerk (Orange Pi)
/// Der Pi reicht später jedes Modem als TCP-Port durch (A = 2021, B = 2022).
class TcpTransport implements Transport {
  final Socket _s;
  @override
  final String label;
  final StreamController<Uint8List> _ctrl = StreamController<Uint8List>.broadcast();

  TcpTransport._(this._s, this.label) {
    _s.listen(_ctrl.add, onError: _ctrl.addError, onDone: () => _ctrl.close());
  }

  static Future<TcpTransport> open(String host, int port) async {
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    s.setOption(SocketOption.tcpNoDelay, true);
    return TcpTransport._(s, '$host:$port');
  }

  @override
  Stream<Uint8List> get input => _ctrl.stream;

  @override
  Future<void> write(Uint8List data) async {
    _s.add(data);
    await _s.flush();
  }

  @override
  Future<void> close() async {
    try {
      await _s.close();
    } catch (_) {}
    _s.destroy();
  }
}
