import 'package:flutter_test/flutter_test.dart';
import 'package:lr2021_app/geo/coords.dart';

// Prüfwerte aus der Python-Gegenrechnung (gleiche Formeln, geprüft am Washington Monument).
void main() {
  test('MGRS', () {
    expect(toMgrs(38.8895, -77.0352), '18S UJ 23486 06483');
    expect(toMgrs(52.5163, 13.3777), '33U UU 89917 19701');
    expect(toMgrs(-33.8568, 151.2153), '56H LH 34900 52288');
  });
  test('Locator', () => expect(toMaidenhead(52.5163, 13.3777), 'JO62qm'));
  test('Strich', () => expect(toMils(90), 1600));
  test('Kacheln', () {
    expect(lonToTileX(13.3777, 10), 550);
    expect(latToTileY(52.5163, 10), 335);
  });
}
