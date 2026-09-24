// ============================================================================
// GlobeOrFlat — EKF regression test (deterministic, no device required)
// SPDX-License-Identifier: MIT
//
// Mirrors the Monte-Carlo validation used to tune VerticalAltitudeEKF:
//   raw GNSS RMSE ≈ 5 m  →  fused RMSE must land well under 50 % of that,
//   a 15 m multipath glitch between t=200..210 s must be innovation-gated,
//   and the drifting barometer bias must be tracked to < 1 m residual.
//
// Run: flutter test
// ============================================================================

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:globeorflat_app/services/sensor_fusion_service.dart';

/// Tiny deterministic LCG so the test never flakes (no dart:math Random).
class _DeterministicRandom {
  double _state;
  _DeterministicRandom(this._state);

  double _nextUnit() {
    _state = (_state * 1103515245 + 12345) % 2147483648;
    return _state / 2147483648;
  }

  double nextNormal() {
    final double u1 = _nextUnit().clamp(1e-9, 1.0).toDouble();
    final double u2 = _nextUnit();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }
}

const double _pa0 = kSeaLevelPressureHpa;

double _smooth(double s) {
  final double c = s < 0 ? 0 : (s > 1 ? 1 : s);
  return 0.5 - 0.5 * math.cos(math.pi * c);
}

double _trueAltitude(double t) {
  double alt = 120.0;
  if (60 <= t && t < 90) {
    alt += 8.0 * _smooth((t - 60) / 30.0);
  } else if (t >= 90) {
    alt += 8.0;
  }
  if (150 <= t && t < 180) {
    alt -= 5.0 * _smooth((t - 150) / 30.0);
  } else if (t >= 180) {
    alt -= 5.0;
  }
  alt += 0.30 * math.sin(2 * math.pi * t / 25.0);
  return alt;
}

double _trueAccel(double t) {
  const double d = 0.02;
  return (_trueAltitude(t + d) - 2 * _trueAltitude(t) + _trueAltitude(t - d)) /
      (d * d);
}

double _pressureFor(double altitudeMeters) =>
    _pa0 * math.pow(1.0 - altitudeMeters / 44330.0, 1.0 / 0.1902949572);

void main() {
  test('EKF suppresses GNSS noise, gates glitches and tracks baro bias',
      () {
    final _DeterministicRandom rng = _DeterministicRandom(20260924);
    const double dt = 0.02;
    const double duration = 300.0;
    const double sigmaAccel = 0.06;
    const double sigmaGps = 5.0;

    double bias = 1.5;
    final double h0 = _trueAltitude(0);
    final double initGps = h0 + sigmaGps * rng.nextNormal();
    final double initBaroAlt =
        baroAltitudeFromPressureHpa(_pressureFor(h0 + bias));

    final VerticalAltitudeEKF ekf = VerticalAltitudeEKF(
      initAltitude: initGps,
      initBaroAltitude: initBaroAlt,
      initGpsSigma: sigmaGps,
    );

    final List<double> gpsErrors = <double>[];
    final List<double> fusedErrors = <double>[];

    double t = 0;
    int lastBaroDeci = -1;

    while (t < duration) {
      final double aMeas = _trueAccel(t) + sigmaAccel * rng.nextNormal();
      ekf.predict(dt, aMeas);

      // Barometer @ 10 Hz with drifting bias + 0.02 hPa (~0.35 m) noise.
      final int deci = (t * 10).floor();
      if (deci != lastBaroDeci) {
        lastBaroDeci = deci;
        bias += rng.nextNormal() * 0.0004;
        bias += (2.0 - 1.5) * dt / duration;
        final double p =
            _pressureFor(_trueAltitude(t) + bias) + 0.02 * rng.nextNormal();
        ekf.updateBaro(p);
      }

      // GNSS @ 1 Hz with a stubborn multipath glitch at t ∈ [200, 210).
      final bool newSecond = (t.floor()) != ((t - dt).floor());
      if (newSecond) {
        double z = _trueAltitude(t) + sigmaGps * rng.nextNormal();
        if (t >= 200 && t < 210) {
          z += 15.0;
        }
        ekf.updateGps(z, sigmaGps);
        gpsErrors.add(z - _trueAltitude(t));
      }

      fusedErrors.add(ekf.altitude - _trueAltitude(t));
      t += dt;
    }

    double rmse(List<double> xs) {
      double acc = 0;
      for (final double e in xs) {
        acc += e * e;
      }
      return math.sqrt(acc / xs.length);
    }

    final double gpsRmse = rmse(gpsErrors);
    final double fusedRmse = rmse(fusedErrors);

    // ignore: avoid_print
    print('GNSS RMSE  : ${gpsRmse.toStringAsFixed(3)} m');
    // ignore: avoid_print
    print('fused RMSE : ${fusedRmse.toStringAsFixed(3)} m');
    // ignore: avoid_print
    print('gps rejected: ${ekf.rejectedGps}, bias residual: '
        '${(ekf.baroBias - bias).abs().toStringAsFixed(3)} m');

    expect(fusedRmse, lessThan(2.0),
        reason: 'fused altitude should be far smoother than GNSS');
    expect(fusedRmse, lessThan(gpsRmse * 0.5),
        reason: 'fusion must at least halve the high-frequency GNSS noise');
    expect(ekf.rejectedGps, greaterThanOrEqualTo(8),
        reason: 'the 10-second 15 m glitch must be innovation-gated');
    expect((ekf.baroBias - bias).abs(), lessThan(1.0),
        reason: 'the drifting barometer bias must be tracked');
  });

  test('baro altitude formula matches the standard atmosphere', () {
    expect(baroAltitudeFromPressureHpa(kSeaLevelPressureHpa), closeTo(0, 0.01));
    // 990 hPa ≈ 195 m above sea level.
    expect(baroAltitudeFromPressureHpa(990.0), closeTo(195.4, 2));
  });

  test('measurement mode wire names match the backend contract', () {
    expect(MeasurementMode.horizonDip.wireName, 'HORIZON_DIP');
    expect(MeasurementMode.waterSightline.wireName, 'WATER_SIGHTLINE');
    expect(MeasurementMode.trackDrive.wireName, 'TRACK_DRIVE');
    expect(MeasurementMode.eratosthenes.wireName, 'ERATOSTHENES');
    expect(
        measurementModeFromWireName('TRACK_DRIVE'), MeasurementMode.trackDrive);
    expect(measurementModeFromWireName('NOPE'), isNull);
  });
}
