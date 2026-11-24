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

  test('Versionen vergleichen', () {
    expect(Updater.compare('v1.6.0', '1.5.0'), greaterThan(0));
    expect(Updater.compare('1.5.0', '1.5.0'), 0);
    expect(Updater.compare('v1.5.1', '1.10.0'), lessThan(0));
  });
}
