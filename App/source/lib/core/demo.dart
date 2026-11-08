import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../mesh/lr_radio.dart';
import '../mesh/meshtastic.dart';
import '../mesh/protobuf.dart';
import 'bytes.dart';
import 'frame.dart';
import 'modem.dart';
import 'transport.dart';

/// Simuliertes Modem: spricht das echte Protokoll und erzeugt Funkverkehr,
/// damit man die App ohne Hardware ausprobieren kann.
class DemoTransport implements Transport {
  final String role;
  final StreamController<Uint8List> _ctrl = StreamController<Uint8List>.broadcast();
  final FrameDecoder _dec = FrameDecoder();
  final Random _rnd = Random();
  late LoraCfg _cfg;
  final Limits _lim = Limits();
  int _state = 1;
  int _evSeq = 0;
  final List<int> _stats = List<int>.filled(9, 0);
  final DateTime _start = DateTime.now();
  Timer? _traffic;
  bool _closed = false;

  static final _mtChannel = MtChannel('LongFast', 'AQ==');
  static const _peers = <_Peer>[
    _Peer(0x2a71c0de, 'Funkturm Nord', 'TURM', 31, 52.5412, 13.4120),
    _Peer(0x5be3a210, 'Wanderer', 'WAND', 64, 52.5051, 13.3550),
    _Peer(0x0c11f00d, 'Basis 2', 'BAS2', 43, 52.4870, 13.4389),
    _Peer(0x7e0e2b44, 'Repeater Hügel', 'RPT', 9, 52.5628, 13.3302),
  ];
  static const _texts = [
    'Moin in die Runde',
    'Signaltest, wer hört mich?',
    'Bin am Turm, Empfang sehr gut',
    'Akku bei 60 %, melde mich später',
    '73 und gute Nacht',
  ];
  static const _lrStations = [
    ['DL0XYZ', 'Klubstation'],
    ['DO1ABC', 'Mobil'],
  ];

  DemoTransport(this.role) {
    _cfg = role == 'A'
        ? LoraCfg(freqHz: 869525000, bwHz: 250000, sf: 11, cr: 5, sync: 0x2B, powerDbm: 14, preamble: 16)
        : LoraCfg(freqHz: 433875000, bwHz: 125000, sf: 9, cr: 5, sync: 0x12, powerDbm: 10, preamble: 8);
    Timer(const Duration(milliseconds: 300), () => _event(Evt.boot, _infoBlock()));
    _scheduleTraffic();
  }

  @override
  String get label => 'Demo $role';

  @override
  Stream<Uint8List> get input => _ctrl.stream;

  @override
  Future<void> write(Uint8List data) async {
    for (final f in _dec.feed(data)) {
      Timer(Duration(milliseconds: 5 + _rnd.nextInt(20)), () => _respond(f));
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _traffic?.cancel();
    if (!_ctrl.isClosed) await _ctrl.close();
  }

  void _send(Uint8List frame) {
    if (!_closed && !_ctrl.isClosed) _ctrl.add(frame);
  }

  void _reply(Frame f, int status, [List<int> data = const []]) {
    final w = Wr()
      ..i16(status)
      ..add(data);
    _send(buildFrame(f.type | 0x80, f.seq, w.toBytes()));
  }

  void _event(int type, List<int> data) {
    _evSeq = (_evSeq + 1) & 0xFF;
    _send(buildFrame(type, _evSeq, data));
  }

  Uint8List _infoBlock() {
    final w = Wr()
      ..u8(1)
      ..u8(1)
      ..u8(0)
      ..u8(10)
      ..u8(role.codeUnitAt(0))
      ..u8(role == 'A' ? 1 : 2)
      ..u8(1)
      ..u8(_state)
      ..u8(1)
      ..u32(DateTime.now().difference(_start).inMilliseconds)
      ..u32(role == 'A' ? 0xDE118428 : 0xDE11B07B)
      ..i16(0)
      ..i16(310 + _rnd.nextInt(30))
      ..u16(3700 + _rnd.nextInt(200))
      ..u32(role == 'A' ? 850000000 : 410000000)
      ..u32(role == 'A' ? 930000000 : 510000000);
    return w.toBytes();
  }

  void _respond(Frame f) {
    final p = f.payload;
    switch (f.type) {
      case Cmd.ping:
        _reply(f, 0, (Wr()
              ..u32(protoMagic)
              ..u8(1))
            .toBytes());
        break;
      case Cmd.getInfo:
        _reply(f, 0, _infoBlock());
        break;
      case Cmd.getConfig:
        _reply(f, 0, [1, ..._cfg.encode(), ..._lim.encode(), 1]);
        break;
      case Cmd.setLora:
        if (p.length < 16) {
          _reply(f, -2);
          return;
        }
        _cfg = LoraCfg.read(Rd(p));
        _state = 1;
        _scheduleTraffic();
        _reply(f, 0);
        break;
      case Cmd.setLimits:
        if (p.length >= 5) {
          final l = Limits.read(Rd(p));
          _lim
            ..allowMask = l.allowMask
            ..maxPwrSub = l.maxPwrSub
            ..maxPwr24 = l.maxPwr24
            ..dutyPermille = l.dutyPermille;
        }
        _reply(f, 0);
        break;
      case Cmd.tx:
        if (p.length < 4) {
          _reply(f, -2);
          return;
        }
        final r = Rd(p);
        r.u8();
        final id = r.u16();
        final data = r.rest();
        _reply(f, 0);
        _state = 3;
        final air = _cfg.airtimeMs(data.length);
        Timer(Duration(milliseconds: air.round()), () {
          _state = 2;
          _stats[2]++;
          _stats[5] += air.round();
          _event(Evt.txDone, (Wr()
                ..u16(id)
                ..i16(0)
                ..u32((air * 1000).round()))
              .toBytes());
          _afterOwnTx(data);
        });
        break;
      case Cmd.rxStart:
        _state = 2;
        _reply(f, 0);
        break;
      case Cmd.standby:
        _state = 1;
        _reply(f, 0);
        break;
      case Cmd.sleep:
        _state = 4;
        _reply(f, 0);
        break;
      case Cmd.cad:
        _reply(f, 0, [_rnd.nextInt(10) == 0 ? 1 : 0]);
        break;
      case Cmd.getRssi:
        _reply(f, 0, (Wr()..i16(-1180 + _rnd.nextInt(60))).toBytes());
        break;
      case Cmd.getStats:
        final w = Wr();
        for (final v in _stats) {
          w.u32(v);
        }
        _reply(f, 0, w.toBytes());
        break;
      case Cmd.resetStats:
        _stats.fillRange(0, 9, 0);
        _reply(f, 0);
        break;
      case Cmd.save:
      case Cmd.setAutoRx:
      case Cmd.resetRadio:
        _reply(f, 0);
        break;
      case Cmd.factory:
      case Cmd.reboot:
        _reply(f, 0);
        Timer(const Duration(seconds: 1), () => _event(Evt.boot, _infoBlock()));
        break;
      default:
        _reply(f, -1);
    }
  }

  bool get _isMeshtastic => _cfg.sync == 0x2B;
  bool get _isLr => _cfg.sync == 0x12 && _cfg.freqHz < 520000000;

  void _rx(Uint8List data, {double? rssi, double? snr}) {
    if (_state != 2) return;
    _stats[0]++;
    final w = Wr()
      ..i16(((rssi ?? (-70 - _rnd.nextInt(45).toDouble())) * 10).round())
      ..i16(((snr ?? (9 - _rnd.nextInt(18).toDouble())) * 10).round())
      ..i32(28000 + _rnd.nextInt(2000))
      ..u8(0)
      ..u32(DateTime.now().difference(_start).inMilliseconds)
      ..add(data);
    _event(Evt.rx, w.toBytes());
  }

  void _scheduleTraffic() {
    _traffic?.cancel();
    _traffic = Timer(Duration(milliseconds: 4000 + _rnd.nextInt(7000)), () {
      if (_closed) return;
      _makeTraffic();
      _scheduleTraffic();
    });
  }

  int _rid() => 1 + _rnd.nextInt(0x7FFFFFFE);

  void _makeTraffic() {
    if (_isMeshtastic) {
      final peer = _peers[_rnd.nextInt(_peers.length)];
      final k = _rnd.nextInt(10);
      int port;
      Uint8List payload;
      if (k < 3) {
        port = Port.text;
        payload = _utf8(_texts[_rnd.nextInt(_texts.length)]);
      } else if (k < 5) {
        port = Port.nodeinfo;
        payload = userPayload(peer.num, peer.long, peer.short, hwModel: peer.hw);
      } else if (k < 7) {
        port = Port.position;
        payload = positionPayload(peer.lat + (_rnd.nextDouble() - 0.5) * 0.001, peer.lon + (_rnd.nextDouble() - 0.5) * 0.001,
            altM: 40 + _rnd.nextInt(30));
      } else if (k == 9) {
        port = Port.waypoint;
        payload = waypointPayload(id: 4711, lat: peer.lat + 0.004, lon: peer.lon - 0.006, name: 'Treffpunkt', description: 'Parkplatz am Waldrand');
      } else {
        port = Port.telemetry;
        final dm = PbWriter()
          ..varint(1, 40 + _rnd.nextInt(60))
          ..float32(2, 3.6 + _rnd.nextDouble() * 0.5)
          ..float32(3, _rnd.nextDouble() * 12)
          ..float32(4, _rnd.nextDouble() * 2);
        payload = (PbWriter()..bytes(2, dm.toBytes())).toBytes();
      }
      final hops = _rnd.nextInt(3);
      final pkt = buildMtPacket(from: peer.num, id: _rid(), channel: _mtChannel, port: port, payload: payload, hopLimit: 3);
      pkt[12] = (3 - hops) | (3 << 5);
      _rx(pkt);
    } else if (_isLr) {
      final st = _lrStations[_rnd.nextInt(_lrStations.length)];
      final num = st[0].hashCode & 0xFFFFFFFF;
      final isText = _rnd.nextBool();
      final pkt = LrPacket.build(isText ? LrType.text : LrType.beacon, num, _rid(), st[0], st[1],
          isText ? _utf8('Hier ${st[0]}, Test auf 70 cm') : <int>[]);
      _rx(pkt);
    } else if (_cfg.freqHz == 869618000) {
      // MeshCore-Ankündigung
      final w = Wr()
        ..u8(0x11) // Flood, Typ 4 (Advert)
        ..u8(0)
        ..add(List<int>.generate(32, (_) => _rnd.nextInt(256)))
        ..u32(DateTime.now().millisecondsSinceEpoch ~/ 1000)
        ..add(List<int>.filled(64, 0xAA))
        ..u8(0x92)
        ..i32(52530000)
        ..i32(13380000)
        ..add(_utf8('MC Repeater Demo'));
      _rx(w.toBytes());
    }
  }

  /// Nach eigenem Senden: Weiterleitung und Bestätigungen simulieren.
  void _afterOwnTx(Uint8List data) {
    if (_isMeshtastic) {
      final p = MtPacket.parse(data);
      if (p == null) return;
      final relay = _peers[_rnd.nextInt(_peers.length)];
      Timer(Duration(milliseconds: 900 + _rnd.nextInt(1500)), () {
        final copy = Uint8List.fromList(data);
        final hl = (p.hopLimit > 0 ? p.hopLimit - 1 : 0);
        copy[12] = (copy[12] & 0xF8) | hl;
        copy[15] = relay.num & 0xFF;
        _rx(copy);
      });
      if (!p.isBroadcast && p.decrypt([_mtChannel]) && p.port == Port.traceroute) {
        Timer(Duration(milliseconds: 2500 + _rnd.nextInt(2500)), () {
          final hop = (Wr()..u32(relay.num)).toBytes();
          final rd = (PbWriter()
                ..bytes(1, hop)
                ..bytes(3, hop))
              .toBytes();
          _rx(buildMtPacket(
              from: p.dest, id: _rid(), channel: _mtChannel, port: Port.traceroute, payload: rd, dest: p.from, requestId: p.id));
        });
      }
      if (!p.isBroadcast && p.wantAck) {
        Timer(Duration(milliseconds: 2500 + _rnd.nextInt(2000)), () {
          final ack = buildMtPacket(
              from: p.dest,
              id: _rid(),
              channel: _mtChannel,
              port: Port.routing,
              payload: routingAckPayload(),
              dest: p.from,
              requestId: p.id,
              hopLimit: 3);
          _rx(ack);
        });
      }
    } else if (_isLr) {
      final p = LrPacket.parse(data);
      if (p == null || p.type != LrType.text) return;
      final st = _lrStations[_rnd.nextInt(_lrStations.length)];
      Timer(Duration(milliseconds: 1200 + _rnd.nextInt(1500)), () {
        _rx(LrPacket.build(LrType.ack, st[0].hashCode & 0xFFFFFFFF, _rid(), st[0], st[1], (Wr()..u32(p.id)).toBytes()));
      });
    }
  }

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));
}

class _Peer {
  final int num;
  final String long, short;
  final int hw;
  final double lat, lon;
  const _Peer(this.num, this.long, this.short, this.hw, this.lat, this.lon);
}
