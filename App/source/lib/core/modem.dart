import 'dart:async';
import 'dart:typed_data';

import 'bytes.dart';
import 'frame.dart';
import 'transport.dart';
import '../i18n.dart';

/// Client für die LR2021-Modem-Firmware (Protokoll v1, siehe docs/modem-protocol.md).

class Cmd {
  static const ping = 0x01, getInfo = 0x02, getConfig = 0x03, setLora = 0x10, setFsk = 0x11,
      setLimits = 0x12, save = 0x13, factory = 0x14, setAutoRx = 0x15, tx = 0x20, rxStart = 0x21,
      standby = 0x22, sleep = 0x23, cad = 0x24, getRssi = 0x25, getStats = 0x30, resetStats = 0x31,
      resetRadio = 0x40, reboot = 0x41;
}

class Evt {
  static const boot = 0xE0, rx = 0xE1, txDone = 0xE2, log = 0xE4, error = 0xE5;
}

const protoMagic = 0x444D524C;

const statusNames = <int, String>{
  0: 'OK',
  -1: 'unbekannter Befehl',
  -2: 'falsche Länge',
  -3: 'ungültiger Parameter',
  -4: 'beschäftigt / Warteschlange voll',
  -5: 'Senden in diesem Band nicht freigegeben',
  -6: 'Sendeleistung über Grenzwert',
  -7: 'Sendezeit-Limit erreicht',
  -8: 'Fehler vom Funkchip',
  -9: 'falsche Modulationsart',
  -10: 'Kanal belegt',
  -11: 'Funkchip nicht bereit',
  -12: 'Zeitüberschreitung',
};

String statusText(int s) => statusNames[s] != null ? tr(statusNames[s]!) : tr('Status {0}', [s]);

const radioStateNames = <int, String>{0: 'aus', 1: 'Standby', 2: 'Empfang', 3: 'Senden', 4: 'Schlaf'};

class ModemError implements Exception {
  final int status;
  final int? radioCode;
  ModemError(this.status, [this.radioCode]);
  @override
  String toString() => statusText(status) + (radioCode != null ? tr(' (RadioLib {0})', [radioCode]) : '');
}

class ModemInfo {
  final int proto, fwMajor, fwMinor, fwPatch, bandId, radioState, modem, uptimeMs, chipId, initCode,
      vbatMv, subMinHz, subMaxHz;
  final String role;
  final bool radioOk;
  final double tempC;
  ModemInfo({
    required this.proto,
    required this.fwMajor,
    required this.fwMinor,
    required this.fwPatch,
    required this.role,
    required this.bandId,
    required this.radioOk,
    required this.radioState,
    required this.modem,
    required this.uptimeMs,
    required this.chipId,
    required this.initCode,
    required this.tempC,
    required this.vbatMv,
    required this.subMinHz,
    required this.subMaxHz,
  });

  String get firmware => '$fwMajor.$fwMinor.$fwPatch';
  String get bandName => bandId == 1 ? tr('HF 868') : (bandId == 2 ? tr('LF 433') : tr('Band {0}', [bandId]));
  String get chipHex => chipId.toRadixString(16).toUpperCase().padLeft(8, '0');

  static ModemInfo? parse(Uint8List p) {
    if (p.length < 31) return null;
    final r = Rd(p);
    return ModemInfo(
      proto: r.u8(),
      fwMajor: r.u8(),
      fwMinor: r.u8(),
      fwPatch: r.u8(),
      role: String.fromCharCode(r.u8()),
      bandId: r.u8(),
      radioOk: r.u8() != 0,
      radioState: r.u8(),
      modem: r.u8(),
      uptimeMs: r.u32(),
      chipId: r.u32(),
      initCode: r.i16(),
      tempC: r.i16() / 10.0,
      vbatMv: r.u16(),
      subMinHz: r.u32(),
      subMaxHz: r.u32(),
    );
  }
}

class LoraCfg {
  int freqHz, bwHz, sf, cr, sync, powerDbm, preamble, flags, implicitLen;
  LoraCfg({
    required this.freqHz,
    required this.bwHz,
    required this.sf,
    this.cr = 5,
    this.sync = 0x12,
    this.powerDbm = 10,
    this.preamble = 8,
    this.flags = 1,
    this.implicitLen = 0,
  });

  static const bandwidths = <int>[7800, 10400, 15600, 20800, 31250, 41670, 62500, 83340, 101000, 125000,
    203125, 250000, 406250, 500000, 812500, 1000000];

  Uint8List encode() {
    final w = Wr()
      ..u32(freqHz)
      ..u32(bwHz)
      ..u8(sf)
      ..u8(cr)
      ..u8(sync)
      ..i8(powerDbm)
      ..u16(preamble)
      ..u8(flags)
      ..u8(implicitLen);
    return w.toBytes();
  }

  static LoraCfg read(Rd r) => LoraCfg(
        freqHz: r.u32(),
        bwHz: r.u32(),
        sf: r.u8(),
        cr: r.u8(),
        sync: r.u8(),
        powerDbm: r.i8(),
        preamble: r.u16(),
        flags: r.u8(),
        implicitLen: r.u8(),
      );

  LoraCfg copy() => LoraCfg(
      freqHz: freqHz,
      bwHz: bwHz,
      sf: sf,
      cr: cr,
      sync: sync,
      powerDbm: powerDbm,
      preamble: preamble,
      flags: flags,
      implicitLen: implicitLen);

  String get summary =>
      tr('{0} MHz · {1} · SF{2} · 4/{3} · 0x{4}', [(freqHz / 1e6).toStringAsFixed(3), fmtBw(bwHz), sf, cr, sync.toRadixString(16).toUpperCase().padLeft(2, '0')]);

  /// Sendezeit eines Pakets in ms (Semtech-Formel, expliziter Header, CRC an).
  double airtimeMs(int payloadLen) {
    final tSym = (1 << sf) / bwHz * 1000.0;
    final ldro = tSym > 16.0 ? 1 : 0;
    final crc = (flags & 1) != 0 ? 1 : 0;
    final n = 8 * payloadLen - 4 * sf + 28 + 16 * crc;
    final den = 4 * (sf - 2 * ldro);
    var nPay = (n / den).ceil() * cr;
    if (nPay < 0) nPay = 0;
    return (preamble + 4.25) * tSym + (8 + nPay) * tSym;
  }
}

String fmtBw(int hz) {
  final k = hz / 1000.0;
  return '${k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1)} kHz';
}

class Limits {
  int allowMask, maxPwrSub, maxPwr24, dutyPermille;
  Limits({this.allowMask = 1, this.maxPwrSub = 22, this.maxPwr24 = 12, this.dutyPermille = 0});
  bool get allowSub => (allowMask & 1) != 0;
  bool get allow24 => (allowMask & 2) != 0;
  Uint8List encode() => (Wr()
        ..u8(allowMask)
        ..i8(maxPwrSub)
        ..i8(maxPwr24)
        ..u16(dutyPermille))
      .toBytes();
  static Limits read(Rd r) =>
      Limits(allowMask: r.u8(), maxPwrSub: r.i8(), maxPwr24: r.i8(), dutyPermille: r.u16());
}

class ModemConfig {
  final int modem; // 1 LoRa, 2 FSK
  final LoraCfg? lora;
  final Limits? limits;
  final bool autoRx;
  ModemConfig(this.modem, this.lora, this.limits, this.autoRx);

  static ModemConfig parse(Uint8List p) {
    final r = Rd(p);
    final modem = r.u8();
    LoraCfg? lora;
    if (modem == 1 && r.remaining >= 16) {
      lora = LoraCfg.read(r);
    } else if (modem == 2 && r.remaining >= 32) {
      r.bytes(32);
    }
    Limits? lim;
    if (r.remaining >= 5) lim = Limits.read(r);
    final auto = r.remaining >= 1 ? r.u8() != 0 : true;
    return ModemConfig(modem, lora, lim, auto);
  }
}

class Stats {
  final List<int> v;
  Stats(this.v);
  int get rxOk => v[0];
  int get rxCrc => v[1];
  int get txOk => v[2];
  int get txFail => v[3];
  int get txRejected => v[4];
  int get airtimeTotalMs => v[5];
  int get airtimeHourMs => v[6];
  int get badFrames => v[7];
  int get cadBusy => v[8];
  static Stats parse(Uint8List p) {
    final r = Rd(p);
    return Stats(List<int>.generate(9, (_) => r.remaining >= 4 ? r.u32() : 0));
  }
}

// ---------------------------------------------------------------- Ereignisse
abstract class ModemEvent {
  final DateTime at = DateTime.now();
}

class RxEvent extends ModemEvent {
  final double rssi, snr;
  final int freqErr, timeMs;
  final bool crcError;
  final Uint8List data;
  RxEvent(this.rssi, this.snr, this.freqErr, this.crcError, this.timeMs, this.data);
}

class TxDoneEvent extends ModemEvent {
  final int id, status, airtimeUs;
  TxDoneEvent(this.id, this.status, this.airtimeUs);
  bool get ok => status == 0;
}

class LogEvent extends ModemEvent {
  final int level;
  final String text;
  LogEvent(this.level, this.text);
}

class BootEvent extends ModemEvent {
  final ModemInfo? info;
  BootEvent(this.info);
}

class ErrorEvent extends ModemEvent {
  final int code, radioCode;
  ErrorEvent(this.code, this.radioCode);
}

class DisconnectEvent extends ModemEvent {
  final String reason;
  DisconnectEvent(this.reason);
}

// ---------------------------------------------------------------- Client
class ModemClient {
  final Transport transport;
  final FrameDecoder _dec = FrameDecoder();
  final Map<int, Completer<Uint8List>> _pending = {};
  final StreamController<ModemEvent> _events = StreamController<ModemEvent>.broadcast();
  StreamSubscription<Uint8List>? _sub;
  int _seq = 0;
  int _txId = 0;
  bool _closed = false;

  ModemClient(this.transport) {
    _sub = transport.input.listen(
      _onData,
      onError: (Object e) => _fail(tr('Verbindungsfehler: {0}', [e])),
      onDone: () => _fail(tr('Verbindung getrennt')),
      cancelOnError: false,
    );
  }

  Stream<ModemEvent> get events => _events.stream;
  bool get isClosed => _closed;
  int get badFrames => _dec.bad;

  void _fail(String why) {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(why));
    }
    _pending.clear();
    _events.add(DisconnectEvent(why));
  }

  Future<void> close() async {
    _fail('getrennt');
    await _sub?.cancel();
    try {
      await transport.close();
    } catch (_) {}
  }

  void _onData(Uint8List chunk) {
    for (final f in _dec.feed(chunk)) {
      _handle(f);
    }
  }

  void _handle(Frame f) {
    if (f.type >= 0x81 && f.type <= 0xDF) {
      final c = _pending.remove((f.type << 8) | f.seq);
      if (c == null || c.isCompleted) return;
      if (f.payload.length < 2) {
        c.completeError(ModemError(-2));
        return;
      }
      final r = Rd(f.payload);
      final st = r.i16();
      final data = r.rest();
      if (st != 0) {
        int? rc;
        if (st == -8 && data.length >= 2) rc = Rd(data).i16();
        c.completeError(ModemError(st, rc));
      } else {
        c.complete(data);
      }
      return;
    }
    final p = f.payload;
    try {
      switch (f.type) {
        case Evt.rx:
          if (p.length < 13) return;
          final r = Rd(p);
          final rssi = r.i16() / 10.0;
          final snr = r.i16() / 10.0;
          final fe = r.i32();
          final fl = r.u8();
          final t = r.u32();
          _events.add(RxEvent(rssi, snr, fe, (fl & 1) != 0, t, r.rest()));
          break;
        case Evt.txDone:
          if (p.length < 8) return;
          final r = Rd(p);
          _events.add(TxDoneEvent(r.u16(), r.i16(), r.u32()));
          break;
        case Evt.log:
          if (p.isEmpty) return;
          _events.add(LogEvent(p[0], String.fromCharCodes(p.sublist(1)).trim()));
          break;
        case Evt.boot:
          _events.add(BootEvent(ModemInfo.parse(p)));
          break;
        case Evt.error:
          if (p.length < 4) return;
          final r = Rd(p);
          _events.add(ErrorEvent(r.i16(), r.i16()));
          break;
      }
    } catch (_) {
      // kaputtes Ereignis ignorieren
    }
  }

  Future<Uint8List> request(int cmd, [List<int> payload = const [], Duration timeout = const Duration(seconds: 2)]) async {
    if (_closed) throw StateError(tr('nicht verbunden'));
    _seq = (_seq + 1) & 0xFF;
    final key = ((cmd | 0x80) << 8) | _seq;
    final c = Completer<Uint8List>();
    _pending[key] = c;
    try {
      await transport.write(buildFrame(cmd, _seq, payload));
    } catch (e) {
      _pending.remove(key);
      rethrow;
    }
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(key);
      throw ModemError(-12);
    }
  }

  Future<bool> ping() async {
    final d = await request(Cmd.ping);
    return d.length >= 4 && Rd(d).u32() == protoMagic;
  }

  Future<ModemInfo> info() async {
    final i = ModemInfo.parse(await request(Cmd.getInfo));
    if (i == null) throw FormatException(tr('Info-Block zu kurz'));
    return i;
  }

  Future<ModemConfig> config() async => ModemConfig.parse(await request(Cmd.getConfig));
  Future<void> setLora(LoraCfg c) => request(Cmd.setLora, c.encode(), const Duration(seconds: 5));
  Future<void> setLimits(Limits l) => request(Cmd.setLimits, l.encode());
  Future<void> save() => request(Cmd.save, const [], const Duration(seconds: 3));
  Future<void> factoryReset() => request(Cmd.factory);
  Future<void> setAutoRx(bool on) => request(Cmd.setAutoRx, [on ? 1 : 0]);
  Future<void> rxStart() => request(Cmd.rxStart);
  Future<void> standby() => request(Cmd.standby);
  Future<void> sleep() => request(Cmd.sleep);
  Future<bool> cad() async => (await request(Cmd.cad, const [], const Duration(seconds: 3)))[0] != 0;
  Future<double> rssi() async => Rd(await request(Cmd.getRssi)).i16() / 10.0;
  Future<Stats> stats() async => Stats.parse(await request(Cmd.getStats));
  Future<void> resetStats() => request(Cmd.resetStats);
  Future<void> resetRadio() => request(Cmd.resetRadio, const [], const Duration(seconds: 5));
  Future<void> reboot() => request(Cmd.reboot);

  /// Paket in die Sendewarteschlange. Gibt die tx_id zurück.
  Future<int> tx(Uint8List data, {bool lbt = false, int? id}) async {
    final tid = id ?? (_txId = (_txId + 1) & 0xFFFF);
    final w = Wr()
      ..u8(lbt ? 1 : 0)
      ..u16(tid)
      ..add(data);
    await request(Cmd.tx, w.toBytes());
    return tid;
  }

  /// Senden und auf TX_DONE warten.
  Future<TxDoneEvent> txWait(Uint8List data, {bool lbt = false, Duration timeout = const Duration(seconds: 15)}) async {
    _txId = (_txId + 1) & 0xFFFF;
    final tid = _txId;
    final fut = events
        .where((e) => e is TxDoneEvent && e.id == tid)
        .cast<TxDoneEvent>()
        .first
        .timeout(timeout, onTimeout: () => TxDoneEvent(tid, -12, 0));
    await tx(data, lbt: lbt, id: tid);
    return fut;
  }
}
