import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lr2021_app/core/updater.dart';
import 'package:lr2021_app/mesh/lr_file.dart';
import 'package:lr2021_app/mesh/lr_radio.dart';

void main() {
  test('Datei in Stücke teilen und wieder zusammensetzen', () {
    final data = Uint8List.fromList(List<int>.generate(1000, (i) => i * 7 & 0xFF));
    final chunks = FileChunk.split(data, 'image/jpeg', 'bild.jpg', 0x1234);
    expect(chunks.length, greaterThan(5));
    final parts = <int, Uint8List>{};
    String? name, mime;
    for (final c in chunks) {
      // jedes Stück muss in ein LR-Paket passen
      final pkt = LrPacket.build(LrType.file, 0x4C520001, 1, 'DL1ABC', '', c);
      expect(pkt.length, lessThanOrEqualTo(255));
      final p = LrPacket.parse(pkt)!;
      final f = FileChunk.parse(p.body)!;
      expect(f.xfer, 0x1234);
      expect(f.size, 1000);
      parts[f.index] = f.data;
      if (f.index == 0) {
        name = f.name;
        mime = f.mime;
      }
    }
    expect(name, 'bild.jpg');
    expect(mime, 'image/jpeg');
    final out = <int>[for (var i = 0; i < chunks.length; i++) ...parts[i]!];
    expect(out, data);
  });

  test('Bestätigung mit fehlenden Teilen', () {
    final a = FileAck.parse(FileAck.build(7, false, [1, 5, 9]))!;
    expect(a.xfer, 7);
    expect(a.done, isFalse);
    expect(a.missing, [1, 5, 9]);
    expect(FileAck.parse(FileAck.build(7, true, const []))!.done, isTrue);
  });

  test('Dateiteile doppelt: jede Kopie zeitversetzt, letztes Teil einmal am Ende', () {
    for (final n in [1, 2, 5, 9, 10, 40]) {
      final o = fileSendOrder(n);
      final count = <int, int>{};
      for (final i in o) {
        count[i] = (count[i] ?? 0) + 1;
      }
      expect(count.keys.toSet(), {for (var i = 0; i < n; i++) i});
      for (var i = 0; i < n - 1; i++) {
        expect(count[i], 2);
      }
      expect(count[n - 1], 1);
      expect(o.last, n - 1);
    }
    expect(fileSendOrder(12).take(11).toList(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 9]);
  });

  test('2,4-GHz-Ankündigung und größere Teile', () {
    final o = FileOffer(0xA1B2C3D4, 2425000000, 812500, 5, 5, 74, 14665);
    final p = FileOffer.parse(o.build())!;
    expect([p.xfer, p.freqHz, p.bwHz, p.sf, p.cr, p.count, p.size], [0xA1B2C3D4, 2425000000, 812500, 5, 5, 74, 14665]);
    final data = Uint8List.fromList(List<int>.generate(5000, (i) => i * 13 & 0xFF));
    final chunks = FileChunk.split(data, 'image/jpeg', 'bild.jpg', 7, size: LrFileProto.chunkSize24);
    final back = <int>[];
    for (final c in chunks) {
      back.addAll(FileChunk.parse(c)!.data);
      final pkt = LrPacket.build(LrType.file, 1, 2, 'DL5RAV-12345', '', c); // längstes Rufzeichen (12)
      expect(pkt.length, lessThanOrEqualTo(255));
    }
    expect(back, data);
    expect(chunks.length, lessThan(FileChunk.split(data, 'image/jpeg', 'bild.jpg', 7).length));
  });

  test('Ankündigung einer Datei', () {
    final a = FileAnnounce(0xCAFE0001, 129025, 717, 412, 'image/jpeg', 'foto_mit_einem_recht_langen_namen.jpg');
    final pkt = LrPacket.build(LrType.fileAnnounce, 1, 2, 'DL5RAV-12345', '', a.build());
    expect(pkt.length, lessThanOrEqualTo(255));
    final b = FileAnnounce.parse(LrPacket.parse(pkt)!.body)!;
    expect([b.xfer, b.size, b.count, b.airtimeS, b.mime, b.name],
        [0xCAFE0001, 129025, 717, 412, 'image/jpeg', 'foto_mit_einem_recht_langen_namen.jpg']);
    expect(FileAnnounce.parse(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('Rückmeldung nennt die Gesamtzahl fehlender Teile, ältere Form bleibt lesbar', () {
    final many = [for (var i = 0; i < 300; i++) i * 2];
    final a = FileAck.parse(FileAck.build(9, false, many))!;
    expect(a.missing.length, LrFileProto.maxMissingPerAck);
    expect(a.total, 300);
    // ältere App-Version: ohne angehängte Gesamtzahl
    final old = Uint8List.fromList([9, 0, 0, 0, 0, 2, 1, 0, 5, 0]);
    final o = FileAck.parse(old)!;
    expect(o.missing, [1, 5]);
    expect(o.total, 2);
    final pkt = LrPacket.build(LrType.fileAck, 1, 2, 'DL5RAV-12345', '', FileAck.build(9, false, many));
    expect(pkt.length, lessThanOrEqualTo(255));
  });

  test('Nachsenden: weiter, solange es besser wird', () {
    final p = ResendPolicy(maxStall: 3);
    expect(p.next(300), isTrue);
    expect(p.next(210), isTrue);
    expect(p.next(120), isTrue);
    expect(p.next(120), isTrue); // einmal gleich: noch weiter
    expect(p.next(130), isTrue);
    expect(p.next(125), isFalse); // dreimal hintereinander nicht besser
    p.reset();
    expect(p.next(5), isTrue);
    expect(p.next(0), isFalse); // nichts fehlt mehr
  });

  test('Kanal frei/belegt nach Grundrauschen', () {
    final w = ChannelWatch();
    expect(w.busy(-80), isTrue); // ohne Vorwissen: sehr starkes Signal = belegt
    for (final v in [-118.0, -117.0, -119.0, -116.0, -118.0]) {
      expect(w.busy(v), isFalse);
    }
    expect(w.floor, closeTo(-118, 1.5));
    expect(w.busy(-110), isFalse); // 8 dB über dem Rauschen: noch frei
    expect(w.busy(-95), isTrue); // anderer Sender
    expect(w.floor, lessThan(-114)); // belegte Werte verändern das Rauschen nicht
  });

  test('Versionen vergleichen', () {
    expect(Updater.compare('v1.6.0', '1.5.0'), greaterThan(0));
    expect(Updater.compare('1.5.0', '1.5.0'), 0);
    expect(Updater.compare('v1.5.1', '1.10.0'), lessThan(0));
  });
}
