import 'dart:async';

import 'package:geolocator/geolocator.dart';
import '../i18n.dart';

/// Standort des Geräts (Handy-GPS, Windows-Ortung). Linux: nicht unterstützt.
class GpsFix {
  final double lat, lon;
  final double? alt, accuracy;
  final DateTime at;
  GpsFix(this.lat, this.lon, this.alt, this.accuracy, this.at);
}

class DeviceGps {
  StreamSubscription<Position>? _sub;
  GpsFix? last;
  String? error;

  bool get running => _sub != null;

  /// Prüft Dienste und Rechte. Gibt Fehlertext oder null zurück.
  Future<String?> _ready() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return tr('Standortdienst ist ausgeschaltet.');
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied) return tr('Standort-Zugriff abgelehnt.');
      if (p == LocationPermission.deniedForever) return tr('Standort-Zugriff dauerhaft abgelehnt – in den Systemeinstellungen erlauben.');
      return null;
    } catch (e) {
      return tr('Ortung auf diesem Gerät nicht verfügbar.');
    }
  }

  GpsFix _fix(Position p) => GpsFix(p.latitude, p.longitude, p.altitude, p.accuracy, p.timestamp);

  /// Einmal die aktuelle Position holen.
  Future<GpsFix?> once() async {
    error = await _ready();
    if (error != null) return null;
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 30)),
      );
      last = _fix(p);
      return last;
    } catch (e) {
      error = tr('Keine Position: {0}', [e]);
      return null;
    }
  }

  /// Laufend verfolgen. [onFix] wird bei jeder Bewegung über [distanceM] aufgerufen.
  Future<String?> start(void Function(GpsFix f) onFix, {int distanceM = 15}) async {
    await stop();
    error = await _ready();
    if (error != null) return error;
    try {
      _sub = Geolocator.getPositionStream(
        locationSettings: LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: distanceM),
      ).listen((p) {
        last = _fix(p);
        onFix(last!);
      }, onError: (Object e) {
        error = tr('Ortung unterbrochen: {0}', [e]);
      });
      return null;
    } catch (e) {
      error = tr('Ortung nicht verfügbar: {0}', [e]);
      return error;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
