import 'package:flutter_test/flutter_test.dart';
import 'package:lr2021_app/core/regulatory.dart';
import 'package:lr2021_app/geo/nmea.dart';
import 'package:lr2021_app/mesh/meshtastic.dart';

void main() {
  test('NMEA GGA', () {
    final f = NmeaParser().feed(r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47')!;
    expect(f.lat, closeTo(48.1173, 1e-4));
    expect(f.lon, closeTo(11.516667, 1e-4));
    expect(f.alt, closeTo(545.4, 1e-6));
    expect(NmeaParser().feed(r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*48'), isNull);
  });

  test('Meshtastic-Frequenzen wie Firmware', () {
    expect(mtFrequency(mtRegion868, 250000, 'LongFast'), 869525000);
    expect(mtFrequency(mtRegion433, 250000, 'LongFast'), 433875000);
    expect(mtFrequency(mtRegion433, 250000, 'MediumFast'), 433125000);
    expect(mtFrequency(mtRegion868, 125000, 'LongModerate'), 869462500);
  });

  test('Leistungsgrenzen', () {
    expect(powerLimit(869525000, bwHz: 250000, licensed: false).maxDbm, 22);
    expect(powerLimit(868100000, bwHz: 125000, licensed: false).maxDbm, 14);
    expect(powerLimit(433875000, bwHz: 125000, licensed: false).maxDbm, 10);
    expect(powerLimit(433875000, bwHz: 125000, licensed: true).maxDbm, 22);
    expect(powerLimit(869525000, bwHz: 250000, licensed: true).maxDbm, 22);
    expect(powerLimit(435000000, licensed: false).allowed, isFalse);
    expect(powerLimit(433875000, bwHz: 125000, licensed: false, antennaGainDbi: 5.15).maxDbm, 7);
  });
}
