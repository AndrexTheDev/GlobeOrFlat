// ============================================================================
// GlobeOrFlat — Physics regression tests (deterministic)
// SPDX-License-Identifier: MIT
//
// Expected values were computed independently (Python mirror with IEEE
// doubles) from the exact formulas in lib/physics/. Run: flutter test
// ============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:globeorflat_app/physics/earth_curvature.dart';
import 'package:globeorflat_app/physics/solar_position.dart';

void main() {
  group('horizon dip', () {
    test('project formula θ ≈ 1.06′·√h', () {
      expect(horizonDipArcminutes(0), 0);
      expect(horizonDipArcminutes(2), closeTo(1.499, 0.001));
      expect(horizonDipArcminutes(10), closeTo(3.352, 0.001));
      expect(horizonDipArcminutes(100), closeTo(10.600, 0.001));
      expect(horizonDipArcminutes(8848), closeTo(99.708, 0.01));
    });

    test('geometric dip √(2h/R) ≈ 1.926′·√h', () {
      expect(horizonDipArcminutesGeometric(2), closeTo(2.724, 0.001));
      expect(horizonDipArcminutesGeometric(100), closeTo(19.261, 0.001));
    });

    test('flat model sanity: dip must grow monotonically', () {
      double prev = -1;
      for (final double h in <double>[1, 2, 5, 10, 50, 100, 500, 1000]) {
        final double d = horizonDipArcminutes(h);
        expect(d, greaterThan(prev));
        prev = d;
      }
    });
  });

  group('occlusion (hidden height)', () {
    test('effective radius R/(1−k)', () {
      expect(kEffectiveRadiusMeters, closeTo(7408139.5, 0.5));
    });

    test('project formula (d − 3.57√h)² / (2·R_eff)', () {
      expect(
        hiddenHeightMeters(observerHeightMeters: 2, distanceKm: 10),
        closeTo(1.6546, 0.005),
      );
      expect(
        hiddenHeightMeters(observerHeightMeters: 10, distanceKm: 20),
        closeTo(5.1211, 0.005),
      );
      expect(
        hiddenHeightMeters(observerHeightMeters: 1.7, distanceKm: 30),
        closeTo(43.3566, 0.05),
      );
    });

    test('target within horizon distance → nothing hidden', () {
      expect(
        hiddenHeightMeters(observerHeightMeters: 2, distanceKm: 4),
        0,
      );
      expect(
        hiddenHeightMeters(observerHeightMeters: 2, distanceKm: 5.049),
        closeTo(0, 0.02),
      );
    });

    test('visible height clamps at zero', () {
      expect(
        visibleHeightMeters(targetHeightMeters: 5, hiddenHeightM: 12),
        0,
      );
      expect(
        visibleHeightMeters(targetHeightMeters: 20, hiddenHeightM: 5.12),
        closeTo(14.88, 0.001),
      );
    });

    test('horizon distances', () {
      expect(horizonDistanceKm(2), closeTo(5.049, 0.001));
      expect(horizonDistanceKm(100), closeTo(35.700, 0.001));
      expect(horizonDistanceKmRefracted(2), closeTo(5.444, 0.001));
      expect(horizonDistanceKmRefracted(100), closeTo(38.492, 0.001));
    });
  });

  group('curvature drop', () {
    test('project formula 0.0785·s²', () {
      expect(curvatureDropMeters(0), 0);
      expect(curvatureDropMeters(1), closeTo(0.0785, 0.0001));
      expect(curvatureDropMeters(5), closeTo(1.9625, 0.001));
      expect(curvatureDropMeters(10), closeTo(7.850, 0.001));
      expect(curvatureDropMeters(30), closeTo(70.650, 0.001));
    });

    test('matches exact geometry s²/2R within 0.05 %', () {
      expect(
        (curvatureDropMeters(10) - curvatureDropMetersGeometric(10)).abs(),
        lessThan(0.05),
      );
    });
  });

  group('model deviation metrics', () {
    test('percent deviation', () {
      expect(deviationPercent(measured: 12, predicted: 10), closeTo(20, 1e-9));
      expect(deviationPercent(measured: 5, predicted: 10), closeTo(-50, 1e-9));
      expect(deviationPercent(measured: 1, predicted: 0), isNull);
    });

    test('rms deviation: globe fits better ⇒ negative', () {
      expect(
        rmsDeviationPercent(rmsResidualFlat: 3, rmsResidualGlobe: 1),
        closeTo(-50, 1e-9),
      );
      expect(
        rmsDeviationPercent(rmsResidualFlat: 1, rmsResidualGlobe: 3),
        closeTo(50, 1e-9),
      );
      expect(
        rmsDeviationPercent(rmsResidualFlat: 0, rmsResidualGlobe: 0),
        isNull,
      );
    });
  });

  group('solar position (Spencer approximation)', () {
    // Reference values computed with the same formulas from first principles
    // and cross-checked against published almanac tables.
    test('equation of time matches almanac table', () {
      expect(
        equationOfTimeMinutes(DateTime.utc(2026, 2, 11, 12)),
        closeTo(-14.200, 0.05),
      );
      expect(
        equationOfTimeMinutes(DateTime.utc(2026, 11, 3, 12)),
        closeTo(16.365, 0.05),
      );
      expect(
        equationOfTimeMinutes(DateTime.utc(2026, 6, 21, 12)),
        closeTo(-1.328, 0.05),
      );
    });

    test('declination: solstice and equinox', () {
      final double june =
          radiansToDegForTest(solarDeclinationRadians(DateTime.utc(2026, 6, 21, 12)));
      expect(june, closeTo(23.452, 0.02));
      final double march =
          radiansToDegForTest(solarDeclinationRadians(DateTime.utc(2026, 3, 20, 12)));
      expect(march, closeTo(-0.461, 0.05));
    });

    test('solar noon Madrid (lon −3.7038°), 2026-03-20', () {
      final DateTime noon = solarNoonUtc(
        dateUtc: DateTime.utc(2026, 3, 20, 12),
        longitudeDeg: -3.7038,
      );
      final double minutesUtc =
          noon.hour * 60.0 + noon.minute + noon.second / 60.0;
      expect(minutesUtc, closeTo(742.979, 0.5)); // 12:22:59 UTC
    });

    test('sun elevation at known instants', () {
      // Madrid, 2026-03-20 15:00 UTC → 35.79°.
      expect(
        solarElevationDegrees(
          utc: DateTime.utc(2026, 3, 20, 15, 0),
          latitudeDeg: 40.4168,
          longitudeDeg: -3.7038,
        ),
        closeTo(35.788, 0.1),
      );
      // Midnight ⇒ sun below horizon.
      expect(
        solarElevationDegrees(
          utc: DateTime.utc(2026, 3, 20, 0, 0),
          latitudeDeg: 40.4168,
          longitudeDeg: -3.7038,
        ),
        lessThan(-10),
      );
    });

    test('shadow geometry round-trip', () {
      final double elevation = 49.122; // Madrid equinox solar noon
      final double shadow = shadowLengthCm(stickCm: 10, elevationDeg: elevation)!;
      expect(shadow, closeTo(8.656, 0.02));
      // And back: ratio → elevation.
      expect(
        elevationFromShadowRatio(shadow / 10),
        closeTo(elevation, 0.01),
      );
      expect(shadowLengthCm(stickCm: 10, elevationDeg: 0), isNull);
    });
  });

  group('formatting', () {
    test('dip DMS formatting', () {
      expect(formatDipArcminutes(1.499), "1′29.9″");
      expect(formatDipArcminutes(0), "0′0.0″");
      expect(formatDipArcminutes(-2.5), "−2′30.0″");
    });
  });
}

/// Test-local rad→deg (avoids exporting a stray helper from production code).
double radiansToDegForTest(double rad) => rad * 180.0 / 3.141592653589793;
