// ============================================================================
// GlobeOrFlat — Earth Curvature Physics
// SPDX-License-Identifier: MIT
//
// The three core models used by the measurement modes, exactly as specified
// by the project, plus refraction-aware variants for context:
//
//  1. Horizon dip            θ  ≈ 1.06′ · √h                (h in m)
//        geometric variant:  θ  = √(2h/R)  rad  ≈ 1.926′ · √h
//  2. Occlusion (hidden height)
//        h_hidden ≈ (d − d_obs)² / (2 · R_eff)
//        d_obs    = 3.57 · √h_observer  [km]      (h_observer in m)
//        R_eff    = R / (1 − k),  R = 6 371 000 m, k = 0.14
//  3. Curvature drop         drop ≈ 0.0785 · s²             (s in km, drop m)
//        geometric variant:  drop = s² / (2R) · 10⁶ m  (= 0.07848 · s²)
//
// All functions are pure and unit-tested in `test/physics_test.dart` against
// independently computed reference values.
// ============================================================================

import 'dart:math' as math;

/// Mean Earth radius [m].
const double kEarthRadiusMeters = 6371000.0;

/// Standard atmospheric refraction coefficient (dimensionless).
const double kRefractionK = 0.14;

/// Refraction-adjusted ("effective") Earth radius [m]: R / (1 − k) ≈ 7408.1 km.
final double kEffectiveRadiusMeters = kEarthRadiusMeters / (1.0 - kRefractionK);

const double _radToArcmin = 180.0 / math.pi * 60.0;

double degreesToRadians(double deg) => deg * math.pi / 180.0;
double radiansToDegrees(double rad) => rad * 180.0 / math.pi;

// ---------------------------------------------------------------------------
// 1. Horizon dip
// ---------------------------------------------------------------------------

/// Horizon dip below the true horizontal [arcminutes] for eye height [hMeters]
/// — the project's standard formula θ ≈ 1.06′·√h (includes nominal
/// terrestrial refraction). On a flat Earth the dip would be exactly 0.
double horizonDipArcminutes(double hMeters) =>
    1.06 * math.sqrt(hMeters > 0 ? hMeters : 0.0);

/// Pure geometric dip (no refraction): √(2h/R) rad ≈ 1.926′·√h.
double horizonDipArcminutesGeometric(double hMeters) =>
    math.sqrt(2.0 * (hMeters > 0 ? hMeters : 0.0) / kEarthRadiusMeters) *
    _radToArcmin;

// ---------------------------------------------------------------------------
// Horizon distance
// ---------------------------------------------------------------------------

/// Distance to the apparent horizon [km] for eye height [hMeters]:
/// d ≈ 3.57·√h (the form used by the occlusion formula below).
double horizonDistanceKm(double hMeters) =>
    3.57 * math.sqrt(hMeters > 0 ? hMeters : 0.0);

/// Refraction-aware horizon distance [km]: √(2·R_eff·h) ≈ 3.86·√h.
double horizonDistanceKmRefracted(double hMeters) =>
    math.sqrt(2.0 * kEffectiveRadiusMeters * (hMeters > 0 ? hMeters : 0.0)) /
    1000.0;

// ---------------------------------------------------------------------------
// 2. Occlusion / hidden height over water
// ---------------------------------------------------------------------------

/// Height of a distant target hidden below the horizon [m], per the project
/// formula: (d − d_obs)² / (2·R_eff) with d_obs = 3.57·√h_observer [km] and
/// R_eff = R/(1−k). Returns 0 when the target is within the observer's
/// horizon distance.
double hiddenHeightMeters({
  required double observerHeightMeters,
  required double distanceKm,
}) {
  final double dObs = horizonDistanceKm(observerHeightMeters);
  final double s = distanceKm - dObs;
  if (s <= 0) return 0.0;
  return s * s / (2.0 * kEffectiveRadiusMeters / 1000.0) * 1000.0;
}

/// Visible height [m] of a target of [targetHeightMeters] given the hidden
/// amount (clamped at 0 — the target may be fully submerged by curvature).
double visibleHeightMeters({
  required double targetHeightMeters,
  required double hiddenHeightM,
}) {
  final double v = targetHeightMeters - hiddenHeightM;
  return v > 0 ? v : 0.0;
}

// ---------------------------------------------------------------------------
// 3. Curvature drop
// ---------------------------------------------------------------------------

/// Curvature drop [m] over a ground distance [distanceKm]: 0.0785·s².
/// This is how far the surface "falls away" below the tangent plane.
double curvatureDropMeters(double distanceKm) => 0.0785 * distanceKm * distanceKm;

/// Geometric variant s²/(2R)·10⁶ ≈ 0.07848·s² (indistinguishable from the
/// shorthand at field-trip distances; kept for completeness).
double curvatureDropMetersGeometric(double distanceKm) =>
    distanceKm * distanceKm / (2.0 * kEarthRadiusMeters / 1000.0) * 1000.0;

// ---------------------------------------------------------------------------
// Model comparison helpers
// ---------------------------------------------------------------------------

/// Relative deviation [%] of a measured quantity from the globe-model
/// prediction: (measured − predicted) / predicted · 100.
/// Returns null when the prediction is ~0 (division would explode).
double? deviationPercent({
  required double measured,
  required double predicted,
}) {
  if (predicted.abs() < 1e-9) return null;
  return (measured - predicted) / predicted * 100.0;
}

/// Track-drive deviation metric [%] comparing RMS residuals of the measured
/// elevation profile against the flat plane and the globe arc:
///   100·(rms_flat − rms_globe) / (rms_flat + rms_globe)
/// Negative ⇒ the globe arc fits better; positive ⇒ the flat plane fits
/// better; ≈ 0 ⇒ inconclusive (terrain dominates).
double? rmsDeviationPercent({
  required double rmsResidualFlat,
  required double rmsResidualGlobe,
}) {
  final double denom = rmsResidualFlat + rmsResidualGlobe;
  if (denom < 1e-6) return null;
  return (rmsResidualFlat - rmsResidualGlobe) / denom * 100.0;
}

/// Formats an angle in arcminutes as `X′YY"` style (e.g. 1.499′ → "1′30.0\"").
String formatDipArcminutes(double arcminutes) {
  final double m = arcminutes.abs();
  final int minutes = m.floor();
  final double seconds = (m - minutes) * 60.0;
  final String sign = arcminutes < 0 ? '−' : '';
  return '$sign$minutes′${seconds.toStringAsFixed(1)}″';
}
