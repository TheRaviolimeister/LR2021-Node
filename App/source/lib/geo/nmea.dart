import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'gps.dart';
import '../i18n.dart';

/// NMEA-Sätze (GGA, RMC) vom GPS-Modul der Node lesen.
class NmeaParser {
  double? _alt;
  int sats = 0;
  bool valid = false;

  static bool checksumOk(String line) {
    final star = line.lastIndexOf('*');
    if (!line.startsWith(r'$') || star < 0 || star + 3 > line.length) return false;
    var c = 0;
    for (final u in line.substring(1, star).codeUnits) {
      c ^= u;
    }
    return int.tryParse(line.substring(star + 1, star + 3), radix: 16) == c;
  }

  static double? _coord(String v, String hemi, int degDigits) {
    if (v.length < degDigits + 2) return null;
    final d = double.tryParse(v.substring(0, degDigits));
    final m = double.tryParse(v.substring(degDigits));
    if (d == null || m == null) return null;
    final x = d + m / 60;
    return (hemi == 'S' || hemi == 'W') ? -x : x;
  }

  /// Gibt bei einer gültigen Position einen Fix zurück.
  GpsFix? feed(String line) {
    line = line.trim();
    if (!checksumOk(line)) return null;
    final f = line.substring(1, line.lastIndexOf('*')).split(',');
    if (f.isEmpty || f[0].length < 5) return null;
    final type = f[0].substring(2);
    if (type == 'GGA' && f.length > 9) {
      final q = int.tryParse(f[6]) ?? 0;
      sats = int.tryParse(f[7]) ?? 0;
      _alt = double.tryParse(f[9]);
      valid = q > 0;
      if (!valid) return null;
      final lat = _coord(f[2], f[3], 2), lon = _coord(f[4], f[5], 3);
      if (lat == null || lon == null) return null;
      final hdop = double.tryParse(f[8]);
      return GpsFix(lat, lon, _alt, hdop == null ? null : hdop * 5, DateTime.now());
    }
    if (type == 'RMC' && f.length > 6) {
      valid = f[2] == 'A';
      if (!valid) return null;
      final lat = _coord(f[3], f[4], 2), lon = _coord(f[5], f[6], 3);
      if (lat == null || lon == null) return null;
      return GpsFix(lat, lon, _alt, null, DateTime.now());
    }
    return null;
  }
}

/// Holt NMEA vom Orange Pi (TCP 2023) und meldet Positionen.
class NodeGps {
  Socket? _sock;
  Timer? _retry;
  bool _on = false;
  final NmeaParser parser = NmeaParser();
  DateTime? lastFix;
  String status = 'aus';

  bool get connected => _sock != null;

  void start(String host, void Function(GpsFix f) onFix) {
    _on = true;
    _connect(host, onFix);
  }

  void _connect(String host, void Function(GpsFix f) onFix) async {
    if (!_on || _sock != null) return;
    try {
      status = tr('verbinde mit {0} …', [host]);
      final s = await Socket.connect(host, 2023, timeout: const Duration(seconds: 4));
      _sock = s;
      status = tr('verbunden, warte auf Fix');
      s.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(
        (line) {
          final f = parser.feed(line);
          if (f != null) {
            lastFix = f.at;
            status = tr('Fix · {0} Satelliten', [parser.sats]);
            onFix(f);
          } else if (!parser.valid) {
            status = tr('kein Fix ({0} Satelliten)', [parser.sats]);
          }
        },
        onDone: () => _lost(host, onFix),
        onError: (Object _) => _lost(host, onFix),
        cancelOnError: true,
      );
    } catch (_) {
      status = tr('Node-GPS nicht erreichbar');
      _lost(host, onFix);
    }
  }

  StreamSubscription<String>? _lines;

  /// GPS-Zeilen aus einer anderen Quelle (Node-Kabel) statt TCP 2023.
  void attachLines(Stream<String> lines, void Function(GpsFix f) onFix) {
    _on = true;
    _retry?.cancel();
    _sock?.destroy();
    _sock = null;
    _lines?.cancel();
    status = tr('über Node-Kabel, warte auf Daten');
    _lines = lines.listen((line) {
      final f = parser.feed(line);
      if (f != null) {
        lastFix = f.at;
        status = tr('Fix · {0} Satelliten (Node-Kabel)', [parser.sats]);
        onFix(f);
      } else if (!parser.valid) {
        status = tr('kein Fix ({0} Satelliten, Node-Kabel)', [parser.sats]);
      }
    });
  }

  void _lost(String host, void Function(GpsFix f) onFix) {
    _sock?.destroy();
    _sock = null;
    if (!_on) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 20), () => _connect(host, onFix));
  }

  void stop() {
    _on = false;
    _retry?.cancel();
    _sock?.destroy();
    _sock = null;
    _lines?.cancel();
    _lines = null;
    status = 'aus';
  }
}
