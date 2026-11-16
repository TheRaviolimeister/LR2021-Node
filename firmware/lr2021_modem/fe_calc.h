// 868-MHz-Frontend: Umrechnung Leistung an der Buchse <-> LR2021-Pegel (header-only, auch für native Tests)
#pragma once
#include <stdint.h>

// Kalibrierung in 0,1 dB
struct FeCalValues {
  int16_t pa10;     // Verstärkung des PA
  int16_t filt10;   // Dämpfung des Steckfilters
  int16_t lna10;    // Verstärkung des LNA
  int16_t byp10;    // Dämpfung des Bypass
};

// ganzzahlige Division durch 10, immer abgerundet (auch bei negativen Werten)
static inline int feFloorDiv10(int x) { return x >= 0 ? x / 10 : -((-x + 9) / 10); }

// Gewünschte Leistung an der Buchse (dBm, bereits auf gesetzliche Grenze und Hardware-Maximum begrenzt)
// -> LR2021-Pegel. Ab der kleinsten PA-Leistung (driveMin + PA - Filter) über den PA, darunter über den Bypass.
// Der Pegel wird abgerundet und auf driveMin..driveMax begrenzt; die Leistung liegt also nie über dem Ziel
// (bezogen auf die Kalibrierung). *pa: über den PA, *actual: Leistung an der Buchse (abgerundet).
static inline int feCalcDrive(int out, const FeCalValues& c, int driveMin, int driveMax, bool* pa, int* actual) {
  const int paMin10 = driveMin * 10 + c.pa10 - c.filt10;
  bool usePa = out * 10 >= paMin10;
  int d = feFloorDiv10(usePa ? out * 10 - c.pa10 + c.filt10 : out * 10 + c.byp10 + c.filt10);
  if (d > driveMax) d = driveMax;
  if (d < driveMin) d = driveMin;
  if (pa) *pa = usePa;
  if (actual) *actual = feFloorDiv10(usePa ? d * 10 + c.pa10 - c.filt10 : d * 10 - c.byp10 - c.filt10);
  return d;
}
