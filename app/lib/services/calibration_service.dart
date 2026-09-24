// ============================================================================
// GlobeOrFlat — Sensor Calibration Engine
// SPDX-License-Identifier: MIT
//
// Consumes raw sensor samples fed by the calibration screen and produces a
// [CalibrationResult] consumed by SensorFusionService:
//
//  • Figure-8 sweep  → magnetometer coverage + hard-iron/soft-iron correction
//      – coverage: how much of the (pitch × roll) gravity-orientation grid the
//        user has swept (this is what the animated 3D phone guides them along)
//      – hard-iron offset  = (max + min) / 2   per axis
//      – soft-iron scale   = normalised (max − min) / 2 per axis
//      – field consistency: stability of |m| across the sweep (quality signal)
//  • Flat-surface rest → gyro bias (mean ω while still), accelerometer
//    magnitude error and noise, and the stillness stability scores.
//
// All math is pure Dart and unit-testable without a device.
// ============================================================================

import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import 'sensor_fusion_service.dart' show CalibrationResult, FusionVector3, kStandardGravity;

/// Duration the device must stay perfectly still to pass the rest check.
const Duration kRestCheckDuration = Duration(seconds: 4);

/// Stillness thresholds for the rest check.
const double kRestAccelTolerance = 0.25; // |‖a‖ − g| [m/s²]
const double kRestGyroTolerance = 0.03; // |ω| [rad/s]

/// Figure-8 orientation coverage grid granularity.
const int kPitchBins = 5; // −90°…90°
const int kRollBins = 12; // −180°…180°

/// Coverage fraction required to pass the figure-8 step.
const double kFigure8RequiredCoverage = 0.8;

/// Running mean/variance accumulator (Welford) — numerically stable.
class _Welford {
  int _n = 0;
  double _mean = 0;
  double _m2 = 0;

  void add(double v) {
    _n++;
    final double d = v - _mean;
    _mean += d / _n;
    _m2 += d * (v - _mean);
  }

  int get count => _n;
  double get mean => _n > 0 ? _mean : 0;
  double get variance => _n > 1 ? _m2 / (_n - 1) : 0;
  double get stdDev => math.sqrt(variance);
}

class _AxisStats {
  final _Welford x = _Welford(), y = _Welford(), z = _Welford();
  double minX = 0, maxX = 0, minY = 0, maxY = 0, minZ = 0, maxZ = 0;
  bool _seen = false;

  void add(double x, double y, double z) {
    this.x.add(x);
    this.y.add(y);
    this.z.add(z);
    if (!_seen) {
      minX = maxX = x;
      minY = maxY = y;
      minZ = maxZ = z;
      _seen = true;
    } else {
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (z < minZ) minZ = z;
      if (z > maxZ) maxZ = z;
    }
  }
}

/// Figure-8 sweep state.
class Figure8State {
  /// pitch × roll coverage buckets touched during the sweep.
  final Set<int> coveredBuckets = <int>{};
  final _AxisStats mag = _AxisStats();
  final _Welford magMagnitude = _Welford();

  int get totalBuckets => kPitchBins * kRollBins;

  /// 0..1 — fraction of the orientation grid visited.
  double get coverage => coveredBuckets.length / totalBuckets;

  /// Relative spread of |m| — small means a trustworthy, interference-free sweep.
  double get magnitudeRelStdDev =>
      magMagnitude.mean > 0 ? magMagnitude.stdDev / magMagnitude.mean : 1.0;
}

/// Flat-surface rest check state.
class RestState {
  final _AxisStats gyro = _AxisStats();
  final _Welford accelMagnitude = _Welford();

  int _stableMs = 0;
  int? _lastStableAtMs;

  /// 0..1 progress toward [kRestCheckDuration] of accumulated stillness.
  double get progress {
    final double frac = _stableMs / kRestCheckDuration.inMilliseconds;
    return frac > 1 ? 1 : (frac < 0 ? 0 : frac);
  }

  bool get done => progress >= 1.0;

  void onSample({
    required FusionVector3 accel,
    required FusionVector3 gyro,
    required int nowMs,
  }) {
    final double aDev = (accel.magnitude - kStandardGravity).abs();
    final double wMag = gyro.magnitude;
    final bool still = aDev < kRestAccelTolerance && wMag < kRestGyroTolerance;

    if (_lastStableAtMs != null) {
      final int delta = nowMs - _lastStableAtMs!;
      if (still) {
        // guard against clock jumps / resume-from-suspend
        final int d = delta < 0 ? 0 : (delta > 250 ? 250 : delta);
        _stableMs += d;
      } else {
        // decay rather than reset — kinder UX on a wobbly table
        _stableMs = (_stableMs * 0.5).round();
      }
    }
    _lastStableAtMs = nowMs;

    if (still) {
      this.gyro.add(gyro.x, gyro.y, gyro.z);
      accelMagnitude.add(accel.magnitude);
    }
  }
}

class CalibrationService {
  Figure8State figure8 = Figure8State();
  RestState rest = RestState();

  /// Latest smoothed orientation for the 3D phone animation [rad].
  double roll = 0, pitch = 0, heading = 0;

  FusionVector3 _gravityLpf = const FusionVector3(0, 0, 0);
  bool _gravityInit = false;

  /// Feeds one sensor frame (call ~20 Hz while the calibration screen is open).
  void onSensorSample({
    required AccelerometerEvent accelerometer,
    required GyroscopeEvent gyroscope,
    required MagnetometerEvent magnetometer,
    required int nowMs,
  }) {
    final FusionVector3 a = FusionVector3(accelerometer.x, accelerometer.y, accelerometer.z);
    final FusionVector3 g = FusionVector3(gyroscope.x, gyroscope.y, gyroscope.z);
    final FusionVector3 m = FusionVector3(magnetometer.x, magnetometer.y, magnetometer.z);

    // Low-pass gravity direction (α = 0.15 ≈ 100 ms at 20 Hz).
    if (!_gravityInit) {
      _gravityLpf = a;
      _gravityInit = true;
    } else {
      _gravityLpf = _gravityLpf.scale(0.85) + a.scale(0.15);
    }
    final FusionVector3 gn = _gravityLpf.normalized();
    if (gn.magnitude > 0.9) {
      roll = math.atan2(gn.y, gn.z);
      pitch = math.atan2(-gn.x, math.sqrt(gn.y * gn.y + gn.z * gn.z));
      final double cosR = math.cos(roll), sinR = math.sin(roll);
      final double cosP = math.cos(pitch), sinP = math.sin(pitch);
      final double my2 = m.y * cosR - m.z * sinR;
      final double mx2 = m.x * cosP + m.y * sinR * sinP + m.z * cosR * sinP;
      heading = math.atan2(-my2, mx2);
    }

    // Figure-8: coverage over the gravity-orientation grid + mag extrema.
    if (a.magnitude > kStandardGravity * 0.7 && a.magnitude < kStandardGravity * 1.3) {
      final int pitchBin = (((pitch + math.pi / 2) / math.pi) * kPitchBins)
          .floor()
          .clamp(0, kPitchBins - 1)
          .toInt();
      final int rollBin = (((roll + math.pi) / (2 * math.pi)) * kRollBins)
          .floor()
          .clamp(0, kRollBins - 1)
          .toInt();
      figure8.coveredBuckets.add(pitchBin * kRollBins + rollBin);
      figure8.mag.add(m.x, m.y, m.z);
      figure8.magMagnitude.add(m.magnitude);
    }

    rest.onSample(accel: a, gyro: g, nowMs: nowMs);
  }

  /// Magnetometer accuracy 0–100: coverage (55%) + field consistency (45%).
  double get magnetometerScore {
    final double coverageScore =
        (figure8.coverage / kFigure8RequiredCoverage).clamp(0.0, 1.0).toDouble();
    final double consistency =
        (1.0 - figure8.magnitudeRelStdDev / 0.20).clamp(0.0, 1.0).toDouble();
    final double s =
        (coverageScore * 0.55 + consistency * 0.45) * 100;
    return s.clamp(0.0, 100.0).toDouble();
  }

  /// Gyro accuracy 0–100: stillness noise of all axes during the rest check.
  double get gyroscopeScore {
    final double worst =
        math.max(figure8RestGyroStdDev, 0.0005); // floor avoids div-by-zero noise
    return ((1.0 - worst / 0.010) * 100).clamp(0.0, 100.0).toDouble();
  }

  double get figure8RestGyroStdDev {
    final double sx = rest.gyro.x.stdDev;
    final double sy = rest.gyro.y.stdDev;
    final double sz = rest.gyro.z.stdDev;
    return math.max(sx, math.max(sy, sz));
  }

  /// Accelerometer accuracy 0–100: magnitude error + stillness noise.
  double get accelerometerScore {
    final double magErr = (rest.accelMagnitude.mean - kStandardGravity).abs();
    final double noise = rest.accelMagnitude.stdDev;
    final double s =
        ((1.0 - magErr / 0.30) * 0.6 + (1.0 - noise / 0.20) * 0.4) * 100;
    return s.clamp(0.0, 100.0).toDouble();
  }

  bool get figure8Done => figure8.coverage >= kFigure8RequiredCoverage;
  bool get restDone => rest.done;

  /// Freezes the calibration into a [CalibrationResult] for fusion + storage.
  CalibrationResult finalize() {
    final _AxisStats mag = figure8.mag;
    if (mag.x.count < 10) {
      // Not enough sweep data — return a neutral result (caller treats it as
      // low quality via the scores below).
      return CalibrationResult(
        gyroBiasRadS: <double>[0, 0, 0],
        magHardIronOffset: <double>[0, 0, 0],
        magScale: const <double>[1, 1, 1],
        gyroScore: gyroscopeScore,
        accelScore: accelerometerScore,
        magScore: 0,
        completedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    final double offX = (mag.minX + mag.maxX) / 2;
    final double offY = (mag.minY + mag.maxY) / 2;
    final double offZ = (mag.minZ + mag.maxZ) / 2;
    final double spanX = (mag.maxX - mag.minX) / 2;
    final double spanY = (mag.maxY - mag.minY) / 2;
    final double spanZ = (mag.maxZ - mag.minZ) / 2;
    final double meanSpan = (spanX + spanY + spanZ) / 3;

    List<double> scales() {
      double one(double span) {
        if (span <= 1e-6 || meanSpan <= 1e-6) return 1.0;
        final double s = meanSpan / span;
        // Guard against pathological swings that would blow up the magnetometer.
        return s.clamp(0.4, 2.5).toDouble();
      }

      return <double>[one(spanX), one(spanY), one(spanZ)];
    }

    return CalibrationResult(
      gyroBiasRadS: <double>[rest.gyro.x.mean, rest.gyro.y.mean, rest.gyro.z.mean],
      magHardIronOffset: <double>[offX, offY, offZ],
      magScale: scales(),
      gyroScore: gyroscopeScore,
      accelScore: accelerometerScore,
      magScore: magnetometerScore,
      completedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Resets all progress (user taps "recalibrate").
  void reset() {
    figure8 = Figure8State();
    rest = RestState();
    roll = pitch = heading = 0;
    _gravityInit = false;
    _gravityLpf = const FusionVector3(0, 0, 0);
  }
}
