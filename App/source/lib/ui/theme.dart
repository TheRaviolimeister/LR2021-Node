import 'package:flutter/material.dart';

/// Farbwelt: Funkgerät bei Nacht – Graphit, bernsteinfarbene Anzeige (HF 868),
/// Petrol für das 70-cm-Modul (LF 433).
class RadioColors extends ThemeExtension<RadioColors> {
  final Color hf, lf, ok, warn, crit, muted, panel, panelHi, line, mine, mineText;
  const RadioColors({
    required this.hf,
    required this.lf,
    required this.ok,
    required this.warn,
    required this.crit,
    required this.muted,
    required this.panel,
    required this.panelHi,
    required this.line,
    required this.mine,
    required this.mineText,
  });

  static const dark = RadioColors(
    hf: Color(0xFFF2A33A),
    lf: Color(0xFF45B8AC),
    ok: Color(0xFF6CC17A),
    warn: Color(0xFFE8C04A),
    crit: Color(0xFFE5675A),
    muted: Color(0xFF8B97A3),
    panel: Color(0xFF181E25),
    panelHi: Color(0xFF212933),
    line: Color(0xFF2C3642),
    mine: Color(0xFF3A2C17),
    mineText: Color(0xFFF7E3C4),
  );

  static const light = RadioColors(
    hf: Color(0xFFB0630A),
    lf: Color(0xFF0D7A70),
    ok: Color(0xFF2E8A43),
    warn: Color(0xFF9A7300),
    crit: Color(0xFFC0392B),
    muted: Color(0xFF5F6B77),
    panel: Color(0xFFFFFFFF),
    panelHi: Color(0xFFF0F2F5),
    line: Color(0xFFD9DEE4),
    mine: Color(0xFFFBE7CC),
    mineText: Color(0xFF3B2405),
  );

  Color band(String role) => role == 'A' ? hf : lf;

  @override
  RadioColors copyWith() => this;

  @override
  RadioColors lerp(ThemeExtension<RadioColors>? other, double t) => other is RadioColors && t > 0.5 ? other : this;
}

extension RadioThemeX on BuildContext {
  RadioColors get rc => Theme.of(this).extension<RadioColors>() ?? RadioColors.dark;
}

const monoFamily = 'monospace';
const monoFallback = ['Consolas', 'DejaVu Sans Mono', 'Menlo', 'Courier New'];

TextStyle mono(BuildContext c, {double size = 12, Color? color, FontWeight? weight}) => TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      color: color,
      fontWeight: weight,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final rc = dark ? RadioColors.dark : RadioColors.light;
  final bg = dark ? const Color(0xFF11161C) : const Color(0xFFEDF0F3);
  final fg = dark ? const Color(0xFFE4E9EE) : const Color(0xFF17202A);
  final scheme = ColorScheme(
    brightness: b,
    primary: rc.hf,
    onPrimary: dark ? const Color(0xFF221402) : Colors.white,
    secondary: rc.lf,
    onSecondary: dark ? const Color(0xFF00201C) : Colors.white,
    error: rc.crit,
    onError: Colors.white,
    surface: rc.panel,
    onSurface: fg,
    surfaceContainerHighest: rc.panelHi,
    surfaceContainerHigh: rc.panelHi,
    surfaceContainer: rc.panel,
    surfaceContainerLow: rc.panel,
    surfaceContainerLowest: bg,
    onSurfaceVariant: rc.muted,
    outline: rc.line,
    outlineVariant: rc.line,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: b,
    scaffoldBackgroundColor: bg,
    visualDensity: VisualDensity.standard,
  );
  return base.copyWith(
    extensions: [rc],
    dividerTheme: DividerThemeData(color: rc.line, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(backgroundColor: bg, foregroundColor: fg, elevation: 0, scrolledUnderElevation: 0),
    cardTheme: CardThemeData(
      color: rc.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: rc.line)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: rc.panel,
      indicatorColor: rc.hf.withValues(alpha: 0.18),
      selectedIconTheme: IconThemeData(color: rc.hf),
      unselectedIconTheme: IconThemeData(color: rc.muted),
      selectedLabelTextStyle: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 12),
      unselectedLabelTextStyle: TextStyle(color: rc.muted, fontSize: 12),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: rc.panel,
      indicatorColor: rc.hf.withValues(alpha: 0.18),
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11, color: fg)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: rc.panelHi,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: rc.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: rc.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: rc.hf, width: 1.5)),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide(color: rc.line),
      backgroundColor: rc.panel,
      selectedColor: rc.hf.withValues(alpha: 0.2),
      labelStyle: TextStyle(fontSize: 12, color: fg),
    ),
    listTileTheme: ListTileThemeData(iconColor: rc.muted, dense: false),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: rc.panelHi,
      contentTextStyle: TextStyle(color: fg),
    ),
  );
}
