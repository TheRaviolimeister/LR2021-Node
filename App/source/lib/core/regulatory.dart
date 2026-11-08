import '../i18n.dart';

/// Sendeleistungs-Grenzen (Deutschland/EU).
///
/// Ohne Lizenz gelten die Grenzen für Funkanwendungen geringer Reichweite (SRD,
/// ERC/REC 70-03, Allgemeinzuteilung der BNetzA). Mit Amateurfunk-Lizenz entfällt
/// die Grenze in den Amateurfunkbändern; dann gilt nur noch das Maximum des Chips.
/// Werte sind ERP (bezogen auf einen Dipol, 2,15 dBi).
class BandRule {
  final int fromHz, toHz;
  final double erpDbm;
  final double dutyPct;
  final String name;
  const BandRule(this.fromHz, this.toHz, this.erpDbm, this.dutyPct, this.name);
}

const srdRules = <BandRule>[
  BandRule(433050000, 434790000, 10, 10, '433 MHz SRD: 10 mW ERP, 10 %'),
  BandRule(863000000, 865000000, 14, 0.1, '863–865 MHz: 25 mW ERP, 0,1 %'),
  BandRule(865000000, 868000000, 14, 1, '865–868 MHz: 25 mW ERP, 1 %'),
  BandRule(868000000, 868600000, 14, 1, '868,0–868,6 MHz: 25 mW ERP, 1 %'),
  BandRule(868700000, 869200000, 14, 0.1, '868,7–869,2 MHz: 25 mW ERP, 0,1 %'),
  BandRule(869400000, 869650000, 27, 10, '869,4–869,65 MHz: 500 mW ERP, 10 %'),
  BandRule(869700000, 870000000, 14, 1, '869,7–870 MHz: 25 mW ERP, 1 %'),
  BandRule(2400000000, 2483500000, 20, 100, '2,4 GHz: 100 mW EIRP'),
];

/// Amateurfunkbänder, die die LR2021-Module abdecken.
const hamBands = <(int, int, String)>[
  (430000000, 440000000, '70 cm'),
  (2320000000, 2450000000, '13 cm'),
];

const chipMaxSubGhz = 22;
const chipMax24 = 12;

BandRule? srdRuleFor(int freqHz, [int bwHz = 0]) {
  final lo = freqHz - bwHz ~/ 2, hi = freqHz + bwHz ~/ 2;
  for (final r in srdRules) {
    if (lo >= r.fromHz && hi <= r.toHz) return r;
  }
  return null;
}

String? hamBandFor(int freqHz) {
  for (final b in hamBands) {
    if (freqHz >= b.$1 && freqHz <= b.$2) return b.$3;
  }
  return null;
}

class PowerLimit {
  final int maxDbm; // am Chip-Ausgang
  final bool allowed;
  final String _reason;
  String get reason => tr(_reason); // Texte der Tabellen werden erst bei der Anzeige übersetzt
  const PowerLimit(this.maxDbm, this.allowed, this._reason);
}

/// Höchste erlaubte Leistung am Chip-Ausgang für eine Frequenz.
PowerLimit powerLimit(int freqHz, {int bwHz = 0, required bool licensed, double antennaGainDbi = 2.15}) {
  final chip = freqHz > 2000000000 ? chipMax24 : chipMaxSubGhz;
  final ham = hamBandFor(freqHz);
  if (licensed && ham != null) {
    return PowerLimit(chip, true, tr('Amateurfunk {0} – Chip-Maximum {1} dBm', [ham, chip]));
  }
  final r = srdRuleFor(freqHz, bwHz);
  if (r == null) {
    if (ham != null) return PowerLimit(0, false, tr('Amateurfunkband – Senden nur mit Lizenz'));
    return PowerLimit(0, false, tr('Kein freigegebener Bereich für diese Frequenz'));
  }
  // ERP → Leistung am Ausgang: Antennengewinn über Dipol abziehen
  final cond = (r.erpDbm - (antennaGainDbi - 2.15)).floor();
  final max = cond > chip ? chip : cond;
  return PowerLimit(max, true, '${r.name}${max == chip && cond > chip ? tr(' (Chip-Maximum {0} dBm)', [chip]) : ''}');
}
