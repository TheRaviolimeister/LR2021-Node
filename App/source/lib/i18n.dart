// Sprache der App: Englisch (Standard) oder Deutsch. Der Quelltext enthält die deutschen Texte,
// tr() schlägt bei Englisch die Übersetzung nach (i18n_en.dart). {0}, {1} … = eingesetzte Werte.
import 'i18n_en.dart';

class L {
  static String lang = 'en'; // 'en' oder 'de'
  static bool get en => lang != 'de';
}

String tr(String de, [List<Object?> args = const []]) {
  var s = L.en ? (enTexts[de] ?? de) : de;
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}
