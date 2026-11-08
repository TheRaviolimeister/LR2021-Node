import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Kompass wie im Handy: Gyroskop für schnelle, ruhige Drehung, Magnetfeld (neigungsausgeglichen)
/// zieht die Richtung langsam auf magnetisch Nord (Komplementärfilter).
/// Liefert die Richtung der Geräte-Oberkante (Hochformat) bzw. bei aufrecht gehaltenem Gerät die
/// Blickrichtung der Rückseite, in Grad, 0 = magnetisch Nord.
/// Auf Geräten ohne Sensoren (Windows, Linux) bleibt [heading] null.
class Compass extends ChangeNotifier {
  StreamSubscription<AccelerometerEvent>? _acc;
  StreamSubscription<MagnetometerEvent>? _mag;
  StreamSubscription<GyroscopeEvent>? _gyr;
  List<double>? _g, _m;
  double? heading; // Grad (Richtung der Bild-Oberkante im Hochformat bzw. Blickrichtung)
  bool upright = false; // Gerät steht fast senkrecht -> Blickrichtung statt Oberkante
  int screenTurn = 0; // 0 Hochformat, 90 = Gerät nach links gedreht, -90 = nach rechts
  bool failed = false;
  bool hasGyro = false;
  double _yawRate = 0; // rad/s um die Senkrechte
  int? _gyrUs;
  int _users = 0;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get available => heading != null;
  static bool get supported => Platform.isAndroid || Platform.isIOS;

  /// Mitbenutzen (Zähler) – Sensoren laufen nur, solange jemand zuschaut.
  void acquire() {
    _users++;
    if (_users == 1) _start();
  }

  void release() {
    _users = max(0, _users - 1);
    if (_users == 0) _stop();
  }

  void _start() {
    if (!supported || failed) return;
    try {
      _acc = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
        // Tiefpass: Schwerkraft (Bewegungen beim Drehen herausfiltern)
        final g = _g;
        _g = g == null ? [e.x, e.y, e.z] : [g[0] * 0.9 + e.x * 0.1, g[1] * 0.9 + e.y * 0.1, g[2] * 0.9 + e.z * 0.1];
      }, onError: (Object _) => _fail(), cancelOnError: true);
      _mag = magnetometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
        _m = [e.x, e.y, e.z];
        _onMag();
      }, onError: (Object _) => _fail(), cancelOnError: true);
      _gyr = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen(_onGyro,
          onError: (Object _) {
        hasGyro = false;
        _gyr = null;
      }, cancelOnError: true);
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    failed = true;
    _stop();
    heading = null;
    notifyListeners();
  }

  void _stop() {
    _acc?.cancel();
    _mag?.cancel();
    _gyr?.cancel();
    _acc = null;
    _mag = null;
    _gyr = null;
    _gyrUs = null;
  }

  static double _wrap(double d) => (d + 540) % 360 - 180; // -180 .. +180

  void _onGyro(GyroscopeEvent e) {
    final g = _g;
    final now = DateTime.now().microsecondsSinceEpoch;
    final last = _gyrUs;
    _gyrUs = now;
    if (g == null || last == null) return;
    hasGyro = true;
    final dt = (now - last) / 1e6;
    if (dt <= 0 || dt > 0.2) return;
    final n = sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
    if (n < 1) return;
    // Drehrate um die Senkrechte (Schwerkraft-Messung zeigt nach oben). Links herum = Richtung nimmt ab.
    _yawRate = (e.x * g[0] + e.y * g[1] + e.z * g[2]) / n;
    final h = heading;
    if (h == null) return;
    heading = (h - _yawRate * dt * 180 / pi + 360) % 360;
    _notify();
  }

  void _onMag() {
    final g = _g, m = _m;
    if (g == null || m == null) return;
    final r0 = headingFrom(g, m);
    if (r0 == null) return;
    final n = sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
    if (n <= 0) return;
    // steht die Bild-Oberkante fast senkrecht, ist ihre Richtung unbestimmt -> Rückseite nehmen (mit Hysterese)
    final tilt = (g[2] / n).abs();
    if (!upright && tilt < 0.35) upright = true;
    if (upright && tilt > 0.55) upright = false;
    final mag = upright ? r0.$2 : r0.$1;
    // Bildschirm-Drehung aus der Schwerkraft: liegt das Gerät quer, zeigt die Oberkante des Bildes zur Seite
    if (g[2].abs() < 8.5) {
      if (g[0].abs() > g[1].abs() * 1.5) {
        screenTurn = g[0] > 0 ? 90 : -90;
      } else if (g[1].abs() > g[0].abs() * 1.5) {
        screenTurn = 0;
      }
    }
    final h = heading;
    if (h == null) {
      heading = mag;
    } else {
      final diff = _wrap(mag - h);
      // Mit Gyroskop: Magnetfeld nur langsam einrechnen (beim schnellen Drehen fast gar nicht);
      // großer Unterschied (z. B. nach Kalibrierung) wird zügig übernommen.
      double k;
      if (hasGyro) {
        k = _yawRate.abs() > 0.8 ? 0.005 : 0.03;
        if (diff.abs() > 45) k = 0.2;
      } else {
        k = diff.abs() > 45 ? 0.4 : 0.12;
      }
      heading = (h + diff * k + 360) % 360;
    }
    _notify();
  }

  void _notify() {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds >= 40) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  /// Richtung der Bild-Oberkante (berücksichtigt Querformat, wenn [landscape]).
  double? screenHeading(bool landscape) {
    final h = heading;
    if (h == null) return null;
    if (upright) return h; // Blickrichtung hängt nicht von der Bilddrehung ab
    return (h + (landscape ? screenTurn : 0) + 360) % 360;
  }

  /// Azimut der Geräte-y-Achse aus Schwerkraft [g] und Magnetfeld [m] (Android-Achsen),
  /// wie SensorManager.getRotationMatrix + getOrientation.
  /// Ergebnis: (Azimut y-Achse, Azimut der Rückseite = -z).
  static (double, double)? headingFrom(List<double> g, List<double> m) {
    final ax = g[0], ay = g[1], az = g[2];
    final ex = m[0], ey = m[1], ez = m[2];
    var hx = ey * az - ez * ay;
    var hy = ez * ax - ex * az;
    var hz = ex * ay - ey * ax;
    final normH = sqrt(hx * hx + hy * hy + hz * hz);
    if (normH < 0.1) return null; // freier Fall oder Magnetfeld parallel zur Schwerkraft
    hx /= normH;
    hy /= normH;
    hz /= normH;
    final normA = sqrt(ax * ax + ay * ay + az * az);
    if (normA < 0.1) return null;
    final nax = ax / normA, nay = ay / normA, naz = az / normA;
    // Nord-Vektor N = A x H
    final my = naz * hx - nax * hz;
    final mz = nax * hy - nay * hx;
    final yAz = (atan2(hy, my) * 180 / pi + 360) % 360;
    final backAz = (atan2(-hz, -mz) * 180 / pi + 360) % 360;
    return (yAz, backAz);
  }
}

/// Ein Kompass für die ganze App.
final Compass compass = Compass();
