// ============================================================================
// GlobeOrFlat — Solar Position (Eratosthenes mode)
// SPDX-License-Identifier: MIT
//
// Low-precision solar ephemeris (Spencer, 1971 — the standard "NOAA-style"
// approximation, accuracy ≈ 1 arcmin for the equation of time and ≈ 0.25°
// for the declination), sufficient for shadow-stick work and solar-noon
// scheduling.
//
//   γ  = 2π/365 · (doy − 1 + (hour − 12)/24)          day angle
//   EoT = 229.18·(0.000075 + 0.001868cosγ − 0.032077sinγ
//                 − 0.014615cos2γ − 0.040849sin2γ)    [minutes]
//   δ   = 0.006918 − 0.399912cosγ + 0.070257sinγ
//         − 0.006758cos2γ + 0.000907sin2γ
//         − 0.002697cos3γ + 0.00148sin3γ              [rad]
//
//   solar noon (UTC minutes) = 720 − EoT − 4·longitude_east
//   sin(elevation) = sinφ·sinδ + cosφ·cosδ·cosH
//   shadow length  = stick / tan(elevation)
//
// Validated against published tables (EoT: Feb 11 ≈ −14.2′, Nov 3 ≈ +16.4′;
// declination: Jun 21 ≈ +23.45°) — see `test/physics_test.dart`.
// ============================================================================

import 'dart:math' as math;

import 'earth_curvature.dart' show degreesToRadians, radiansToDegrees;

/// Equation of time [minutes] for the given instant (UTC).
double equationOfTimeMinutes(DateTime utc) {
  final double g = _dayAngle(utc);
  return 229.18 *
      (0.000075 +
          0.001868 * math.cos(g) -
          0.032077 * math.sin(g) -
          0.014615 * math.cos(2 * g) -
          0.040849 * math.sin(2 * g));
}

/// Solar declination [radians] for the given instant (UTC).
double solarDeclinationRadians(DateTime utc) {
  final double g = _dayAngle(utc);
  return 0.006918 -
      0.399912 * math.cos(g) +
      0.070257 * math.sin(g) -
      0.006758 * math.cos(2 * g) +
      0.000907 * math.sin(2 * g) -
      0.002697 * math.cos(3 * g) +
      0.00148 * math.sin(3 * g);
}

double _dayAngle(DateTime utc) {
  final DateTime yearStart = DateTime.utc(utc.year, 1, 1);
  final int dayOfYear =
      utc.difference(yearStart).inDays + 1; // 1-based, matches the formula
  final double hourFraction = (utc.hour - 12 + utc.minute / 60.0) / 24.0;
  return 2 * math.pi / 365.0 * (dayOfYear - 1 + hourFraction);
}

/// Local solar noon as a UTC [DateTime] for the calendar day of [dateUtc]
/// at [longitudeDeg] (east positive).
DateTime solarNoonUtc({
  required DateTime dateUtc,
  required double longitudeDeg,
}) {
  final DateTime noonRef =
      DateTime.utc(dateUtc.year, dateUtc.month, dateUtc.day, 12);
  final double minutes =
      720.0 - equationOfTimeMinutes(noonRef) - 4.0 * longitudeDeg;
  return DateTime.utc(dateUtc.year, dateUtc.month, dateUtc.day)
      .add(Duration(milliseconds: (minutes * 60000).round()));
}

/// Sun elevation [degrees] above the horizon at an instant.
double solarElevationDegrees({
  required DateTime utc,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  final double delta = solarDeclinationRadians(utc);
  // True solar time [minutes]: UTC + EoT + 4·lon (east positive).
  final double utcMinutes =
      utc.hour * 60.0 + utc.minute + utc.second / 60.0 + utc.millisecond / 60000.0;
  final double solarMinutes =
      utcMinutes + equationOfTimeMinutes(utc) + 4.0 * longitudeDeg;
  final double hourAngle = degreesToRadians(solarMinutes / 4.0 - 180.0);
  final double phi = degreesToRadians(latitudeDeg);

  final double sinAlt = math.sin(phi) * math.sin(delta) +
      math.cos(phi) * math.cos(delta) * math.cos(hourAngle);
  return radiansToDegrees(math.asin(sinAlt.clamp(-1.0, 1.0).toDouble()));
}

/// Shadow length [cm] cast by a vertical [stickCm] stick at [elevationDeg].
/// Returns null when the sun is at or below the horizon (no finite shadow).
double? shadowLengthCm({
  required double stickCm,
  required double elevationDeg,
}) {
  if (elevationDeg <= 0.05) return null;
  return stickCm / math.tan(degreesToRadians(elevationDeg));
}

/// Sun elevation [degrees] implied by a shadow-to-stick length ratio
/// (ratio > 0; the stick and its shadow form a right triangle):
///   tan(elevation) = stick / shadow  ⇒  elevation = atan(1/ratio).
double elevationFromShadowRatio(double shadowOverStick) {
  if (shadowOverStick <= 0) return 90.0;
  return radiansToDegrees(math.atan(1.0 / shadowOverStick));
}

/// HH:mm local-time formatting for countdowns / readouts.
String formatHm(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}
