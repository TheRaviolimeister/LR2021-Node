import 'package:flutter_test/flutter_test.dart';
import 'package:lr2021_app/i18n.dart';
import 'package:lr2021_app/i18n_en.dart';

void main() {
  test('Sprache: Englisch Standard, Deutsch umschaltbar, Platzhalter', () {
    L.lang = 'en';
    expect(tr('Einstellungen'), 'Settings');
    expect(tr('Ziel: {0}', ['Heltec']), 'Target: Heltec');
    expect(tr('gibt es nicht'), 'gibt es nicht'); // fehlende Übersetzung -> deutsch
    L.lang = 'de';
    expect(tr('Einstellungen'), 'Einstellungen');
    expect(tr('Ziel: {0}', ['Heltec']), 'Ziel: Heltec');
    L.lang = 'en';
  });

  test('Übersetzungen haben dieselben Platzhalter', () {
    final re = RegExp(r'\{\d+\}');
    for (final e in enTexts.entries) {
      final a = re.allMatches(e.key).map((m) => m.group(0)).toSet();
      final b = re.allMatches(e.value).map((m) => m.group(0)).toSet();
      // englisch darf einen Platzhalter weglassen (z. B. deutsche Pluralendung), aber keinen neuen erfinden
      expect(b.difference(a), isEmpty, reason: e.key);
    }
  });
}
