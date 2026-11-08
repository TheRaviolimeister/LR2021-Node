import '../i18n.dart';
import 'dart:math';

/// Koordinaten-Umrechnungen: MGRS (UTMREF), UTM, Maidenhead-Locator, Kachelnummern.

class Utm {
  final int zone;
  final double easting, northing;
  final bool south;
  const Utm(this.zone, this.easting, this.northing, this.south);
}

Utm toUtm(double lat, double lon) {
  const a = 6378137.0;
  const f = 1 / 298.257223563;
  const k0 = 0.9996;
  var zone = ((lon + 180) / 6).floor() + 1;
  if (lat >= 56 && lat < 64 && lon >= 3 && lon < 12) zone = 32;
  if (lat >= 72 && lat < 84) {
    if (lon >= 0 && lon < 9) {
      zone = 31;
    } else if (lon >= 9 && lon < 21) {
      zone = 33;
    } else if (lon >= 21 && lon < 33) {
      zone = 35;
    } else if (lon >= 33 && lon < 42) {
      zone = 37;
    }
  }
  final lon0 = (zone - 1) * 6 - 180 + 3;
  const e2 = f * (2 - f);
  const ep2 = e2 / (1 - e2);
  final phi = lat * pi / 180;
  final lam = (lon - lon0) * pi / 180;
  final n = a / sqrt(1 - e2 * sin(phi) * sin(phi));
  final t = tan(phi) * tan(phi);
  final c = ep2 * cos(phi) * cos(phi);
  final aa = cos(phi) * lam;
  const e4 = e2 * e2, e6 = e4 * e2;
  final a2 = aa * aa, a3 = a2 * aa, a4 = a3 * aa, a5 = a4 * aa, a6 = a5 * aa;
  final m = a *
      ((1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi -
          (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * sin(2 * phi) +
          (15 * e4 / 256 + 45 * e6 / 1024) * sin(4 * phi) -
          (35 * e6 / 3072) * sin(6 * phi));
  final e = k0 * n * (aa + (1 - t + c) * a3 / 6 + (5 - 18 * t + t * t + 72 * c - 58 * ep2) * a5 / 120) + 500000;
  var no = k0 *
      (m +
          n *
              tan(phi) *
              (aa * aa / 2 +
                  (5 - t + 9 * c + 4 * c * c) * a4 / 24 +
                  (61 - 58 * t + t * t + 600 * c - 330 * ep2) * a6 / 720));
  if (lat < 0) no += 10000000;
  return Utm(zone, e, no, lat < 0);
}

/// MGRS / UTMREF, z. B. „32U NC 12345 67890“. Genauigkeit 1 m.
String toMgrs(double lat, double lon) {
  if (lat < -80 || lat > 84) return tr('außerhalb MGRS');
  final u = toUtm(lat, lon);
  const bands = 'CDEFGHJKLMNPQRSTUVWXX';
  final band = bands[((lat + 80) / 8).floor()];
  final set = (u.zone - 1) % 6 + 1;
  const colSets = ['ABCDEFGH', 'JKLMNPQR', 'STUVWXYZ'];
  final cols = colSets[(set - 1) % 3];
  final colIdx = (u.easting / 100000).floor() - 1;
  final col = cols[colIdx.clamp(0, 7)];
  const rows = 'ABCDEFGHJKLMNPQRSTUV';
  final row = rows[((u.northing / 100000).floor() % 20 + (set % 2 == 0 ? 5 : 0)) % 20];
  final e = (u.easting % 100000).floor().toString().padLeft(5, '0');
  final n = (u.northing % 100000).floor().toString().padLeft(5, '0');
  return '${u.zone}$band $col$row $e $n';
}

/// QTH-Locator (6-stellig), z. B. „JO43xm“.
String toMaidenhead(double lat, double lon) {
  final lo = lon + 180, la = lat + 90;
  final a = String.fromCharCode(65 + (lo / 20).floor());
  final b = String.fromCharCode(65 + (la / 10).floor());
  final c = ((lo % 20) / 2).floor();
  final d = (la % 10).floor();
  final e = String.fromCharCode(97 + ((lo % 2) * 12).floor());
  final g = String.fromCharCode(97 + ((la % 1) * 24).floor());
  return '$a$b$c$d$e$g';
}

String toDms(double lat, double lon) {
  String one(double v, String pos, String neg) {
    final h = v >= 0 ? pos : neg;
    v = v.abs();
    final d = v.floor();
    final m = ((v - d) * 60).floor();
    final s = ((v - d) * 60 - m) * 60;
    return '$d°${m.toString().padLeft(2, '0')}\'${s.toStringAsFixed(1).padLeft(4, '0')}"$h';
  }

  return '${one(lat, 'N', 'S')} ${one(lon, 'O', 'W')}';
}

/// Entfernung (km) und Richtung (Grad) zwischen zwei Punkten.
(double, double) distBearing(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final h = sin(dLat / 2) * sin(dLat / 2) + cos(rad(lat1)) * cos(rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  final dist = 2 * r * atan2(sqrt(h), sqrt(1 - h));
  final y = sin(dLon) * cos(rad(lat2));
  final x = cos(rad(lat1)) * sin(rad(lat2)) - sin(rad(lat1)) * cos(rad(lat2)) * cos(dLon);
  final brg = (atan2(y, x) * 180 / pi + 360) % 360;
  return (dist, brg);
}

/// Richtung auch in Strich (6400 je Vollkreis, wie beim Bund).
int toMils(double deg) => (deg / 360 * 6400).round() % 6400;

int lonToTileX(double lon, int z) => ((lon + 180) / 360 * (1 << z)).floor().clamp(0, (1 << z) - 1);
int latToTileY(double lat, int z) {
  final r = lat.clamp(-85.0511, 85.0511) * pi / 180;
  return ((1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * (1 << z)).floor().clamp(0, (1 << z) - 1);
}
