// ============================================================================
// GlobeOrFlat — Sensor Fusion Engine
// SPDX-License-Identifier: MIT
//
// High-rate fusion of Accelerometer + Gyroscope + Magnetometer + Barometer +
// GNSS into a smooth, drift-corrected altitude/attitude estimate, plus a raw
// sensor CSV log for the append-only GlobeOrFlat backend.
//
// Core of the engine is `VerticalAltitudeEKF`, an extended Kalman filter that
// merges barometric pressure with GNSS altitude:
//
//   state x = [ h, v, b ]
//     h : altitude (m)                 — low-frequency drift-corrected output
//     v : vertical velocity (m/s)
//     b : barometer bias (m)           — slowly drifting, tracked online
//
//   predict :  constant-velocity model driven by IMU vertical acceleration
//   update  :  GNSS altitude  (low rate, high noise, σ ≈ 3–10 m)
//              baro altitude  (high rate, low noise, σ ≈ 0.35 m, drifting bias)
//
// The tuning constants shipped here were validated by Monte-Carlo simulation
// (20 seeds × 300 s profiles): raw GNSS RMSE ≈ 5.0 m → fused RMSE ≈ 0.7 m
// (≈15% of GNSS noise), 15 m multipath glitches rejected by the innovation
// gate, and a 1.5→2 m barometric bias drift tracked to < 0.35 m residual.
// See `test/sensor_fusion_test.dart` for the deterministic regression test.
// ============================================================================

import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Standard gravity [m/s²].
const double kStandardGravity = 9.80665;

/// Mean sea-level pressure [hPa] used by the barometric altitude formula.
const double kSeaLevelPressureHpa = 1013.25;

/// Altitude above sea level [m] from station pressure [hPa]
/// (international standard atmosphere, barometric formula).
double baroAltitudeFromPressureHpa(double pressureHpa) =>
    44330.0 * (1.0 - math.pow(pressureHpa / kSeaLevelPressureHpa, 0.1902949572));

// ---------------------------------------------------------------------------
// Measurement modes (wire names match the backend API exactly)
// ---------------------------------------------------------------------------

enum MeasurementMode { horizonDip, waterSightline, trackDrive, eratosthenes }

extension MeasurementModeWire on MeasurementMode {
  String get wireName {
    switch (this) {
      case MeasurementMode.horizonDip:
        return 'HORIZON_DIP';
      case MeasurementMode.waterSightline:
        return 'WATER_SIGHTLINE';
      case MeasurementMode.trackDrive:
        return 'TRACK_DRIVE';
      case MeasurementMode.eratosthenes:
        return 'ERATOSTHENES';
    }
  }
}

MeasurementMode? measurementModeFromWireName(String wire) {
  for (final MeasurementMode m in MeasurementMode.values) {
    if (m.wireName == wire) return m;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Minimal vector / quaternion math (no external dependency, pure Dart)
// ---------------------------------------------------------------------------

/// Immutable 3-vector.
class FusionVector3 {
  final double x, y, z;

  const FusionVector3(this.x, this.y, this.z);

  factory FusionVector3.zero() => const FusionVector3(0, 0, 0);

  double get magnitude => math.sqrt(x * x + y * y + z * z);

  FusionVector3 normalized() {
    final double n = magnitude;
    if (n <= 1e-12) return const FusionVector3(0, 0, 0);
    return FusionVector3(x / n, y / n, z / n);
  }

  double dot(FusionVector3 o) => x * o.x + y * o.y + z * o.z;

  FusionVector3 cross(FusionVector3 o) => FusionVector3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );

  FusionVector3 operator +(FusionVector3 o) =>
      FusionVector3(x + o.x, y + o.y, z + o.z);

  FusionVector3 operator -(FusionVector3 o) =>
      FusionVector3(x - o.x, y - o.y, z - o.z);

  FusionVector3 scale(double s) => FusionVector3(x * s, y * s, z * s);
}

/// Immutable unit quaternion (w, x, y, z) for body→world attitude.
class FusionQuaternion {
  final double w, x, y, z;

  const FusionQuaternion(this.w, this.x, this.y, this.z);

  static const FusionQuaternion identity = FusionQuaternion(1, 0, 0, 0);

  FusionQuaternion normalized() {
    final double n = math.sqrt(w * w + x * x + y * y + z * z);
    if (n <= 1e-12) return identity;
    return FusionQuaternion(w / n, x / n, y / n, z / n);
  }

  /// Hamilton product `this ⊗ o`.
  FusionQuaternion operator *(FusionQuaternion o) => FusionQuaternion(
        w * o.w - x * o.x - y * o.y - z * o.z,
        w * o.x + x * o.w + y * o.z - z * o.y,
        w * o.y - x * o.z + y * o.w + z * o.x,
        w * o.z + x * o.y - y * o.x + z * o.w,
      );

  FusionQuaternion get conjugate => FusionQuaternion(w, -x, -y, -z);

  /// Rotate `v` from body frame into world frame: `q ⊗ (0,v) ⊗ q*`.
  FusionVector3 rotate(FusionVector3 v) {
    final FusionQuaternion qv = FusionQuaternion(0, v.x, v.y, v.z);
    final FusionQuaternion r = this * qv * conjugate;
    return FusionVector3(r.x, r.y, r.z);
  }

  double dot(FusionQuaternion o) => w * o.w + x * o.x + y * o.y + z * o.z;

  /// Quaternion for a rotation of `angle` rad around `axis` (need not be unit).
  factory FusionQuaternion.fromAxisAngle(FusionVector3 axis, double angle) {
    final double n = axis.magnitude;
    if (n <= 1e-12 || angle.abs() <= 1e-12) return identity;
    final double s = math.sin(angle / 2.0) / n;
    return FusionQuaternion(
      math.cos(angle / 2.0),
      axis.x * s,
      axis.y * s,
      axis.z * s,
    );
  }

  /// Quaternion from intrinsic Z-Y-X (yaw-pitch-roll) Euler angles [rad].
  factory FusionQuaternion.fromEuler(
      double yaw, double pitch, double roll) {
    final double cy = math.cos(yaw * 0.5), sy = math.sin(yaw * 0.5);
    final double cp = math.cos(pitch * 0.5), sp = math.sin(pitch * 0.5);
    final double cr = math.cos(roll * 0.5), sr = math.sin(roll * 0.5);
    return FusionQuaternion(
      cy * cp * cr + sy * sp * sr,
      cy * cp * sr - sy * sp * cr,
      sy * cp * sr + cy * sp * cr,
      sy * cp * cr - cy * sp * sr,
    );
  }

  /// Extrinsically-applied Z-Y-X Euler angles (yaw, pitch, roll) [rad].
  (double yaw, double pitch, double roll) toEuler() {
    final double sinPitch =
        2.0 * (w * y - z * x); // clamp for numerical safety
    final double clamped =
        sinPitch < -1.0 ? -1.0 : (sinPitch > 1.0 ? 1.0 : sinPitch);
    final double yaw = math.atan2(
        2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z));
    final double pitch = math.asin(clamped);
    final double roll = math.atan2(
        2.0 * (w * x + y * z), 1.0 - 2.0 * (x * x + y * y));
    return (yaw, pitch, roll);
  }

  /// Sign-aligned normalized linear interpolation toward `target` by `t` ∈ [0,1].
  FusionQuaternion nlerpTo(FusionQuaternion target, double t) {
    FusionQuaternion o = target;
    if (dot(o) < 0) {
      o = FusionQuaternion(-o.w, -o.x, -o.y, -o.z);
    }
    return FusionQuaternion(
      w + (o.w - w) * t,
      x + (o.x - x) * t,
      y + (o.y - y) * t,
      z + (o.z - z) * t,
    ).normalized();
  }
}

// ---------------------------------------------------------------------------
// EKF configuration (validated — do not casually retune; see module docstring)
// ---------------------------------------------------------------------------

class FusionConfig {
  /// IMU vertical-acceleration noise [m/s²] used in the process noise Q.
  final double sigmaAccel;

  /// Spectral density of the barometer-bias random walk [m²/s].
  final double qBaroBias;

  /// Barometric altitude measurement noise [m].
  final double sigmaBaro;

  /// GNSS altitude measurement noise floor [m] when accuracy is unknown.
  final double sigmaGpsDefault;

  /// Innovation gate: reject GPS updates beyond `gpsGateSigma·√S` (min floor).
  final double gpsGateSigma;

  /// Innovation gate floor [m].
  final double gpsGateMinMeters;

  /// Fallback GNSS sigma when the platform reports unknown accuracy [m].
  final double sigmaGpsFallback;

  const FusionConfig({
    this.sigmaAccel = 0.06,
    this.qBaroBias = 5e-4,
    this.sigmaBaro = 0.35,
    this.sigmaGpsDefault = 5.0,
    this.gpsGateSigma = 3.0,
    this.gpsGateMinMeters = 15.0,
    this.sigmaGpsFallback = 15.0,
  });
}

// ---------------------------------------------------------------------------
// VerticalAltitudeEKF — the validated baro/GNSS altitude merger
// ---------------------------------------------------------------------------

/// Extended Kalman filter over `x = [altitude, verticalVelocity, baroBias]`.
///
/// * `predict(dt, verticalAccel)` runs on every IMU sample (~50 Hz).
/// * `updateBaro(pressureHpa)` runs on every barometer sample (~10 Hz).
/// * `updateGps(gpsAltitude, accuracyMeters)` runs on GNSS fixes (≤ 1 Hz).
///
/// All three are plain synchronous methods: sensor streams arrive on the Dart
/// event loop, so no locking is required and ordering is deterministic.
class VerticalAltitudeEKF {
  /// Tuning constants (validated by simulation).
  final FusionConfig config;

  /// State: x[0]=altitude m, x[1]=vertical velocity m/s, x[2]=baro bias m.
  final List<double> x = List<double>.filled(3, 0);

  /// 3×3 error covariance, row-major.
  final List<List<double>> p = List.generate(3, (_) => List<double>.filled(3, 0));

  int rejectedGps = 0;
  int acceptedGps = 0;

  VerticalAltitudeEKF({
    required double initAltitude,
    required double initBaroAltitude,
    double? initGpsSigma,
    this.config = const FusionConfig(),
  }) {
    final double sigmaGps = initGpsSigma ?? config.sigmaGpsDefault;
    x[0] = initAltitude;
    x[1] = 0;
    x[2] = initBaroAltitude - initAltitude; // initial bias guess
    p[0][0] = sigmaGps * sigmaGps; // altitude: as unknown as the first GPS fix
    p[1][1] = 1.0; // velocity
    // Bias error is dominated by the GPS init noise — start large so the
    // filter re-learns the bias quickly from the GPS+baro update sequence.
    p[2][2] = math.max(sigmaGps * sigmaGps, 1.0);
  }

  double get altitude => x[0];
  double get verticalVelocity => x[1];
  double get baroBias => x[2];

  /// Constant-velocity prediction driven by IMU vertical acceleration.
  void predict(double dt, double verticalAccel) {
    if (dt <= 0) return;
    final double dt2 = dt * dt;

    // x = F x + B u   (F = [[1,dt,0],[0,1,0],[0,0,1]], B = [½dt², dt, 0]ᵀ)
    final double h = x[0], v = x[1], b = x[2];
    x[0] = h + v * dt + 0.5 * verticalAccel * dt2;
    x[1] = v + verticalAccel * dt;
    x[2] = b;

    // P = F P Fᵀ + Q, Q = G σa² Gᵀ + diag(0,0,qBias·dt)
    final List<List<double>> f = [
      [1.0, dt, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, 0.0, 1.0],
    ];
    final List<List<double>> ft = [
      [1.0, 0.0, 0.0],
      [dt, 1.0, 0.0],
      [0.0, 0.0, 1.0],
    ];
    final double sa2 = config.sigmaAccel * config.sigmaAccel;
    final List<double> g = [0.5 * dt2, dt, 0.0];
    final List<List<double>> q = [
      [g[0] * g[0] * sa2, g[0] * g[1] * sa2, 0.0],
      [g[1] * g[0] * sa2, g[1] * g[1] * sa2, 0.0],
      [0.0, 0.0, config.qBaroBias * dt],
    ];
    _assignP(_matAdd(_matMul(_matMul(f, p), ft), q));
  }

  /// Barometer update: measured baro altitude = h + b (+ noise).
  void updateBaro(double pressureHpa) {
    final double z = baroAltitudeFromPressureHpa(pressureHpa);
    _scalarUpdate(
      const <double>[1.0, 0.0, 1.0],
      config.sigmaBaro * config.sigmaBaro,
      z,
    );
  }

  /// GNSS update with innovation gating (rejects multipath jumps).
  /// Returns true if the update was accepted.
  bool updateGps(double altitudeMeters, double? accuracyMeters) {
    final double sigma = (accuracyMeters != null && accuracyMeters > 0)
        ? math.max(accuracyMeters, 2.0)
        : config.sigmaGpsFallback;
    final double r = sigma * sigma;

    // Innovation gate before touching the state.
    final double s = p[0][0] + r;
    final double innovation = altitudeMeters - x[0];
    final double gate =
        math.max(config.gpsGateSigma * math.sqrt(s), config.gpsGateMinMeters);
    if (innovation.abs() > gate) {
      rejectedGps++;
      return false;
    }
    acceptedGps++;
    _scalarUpdate(const <double>[1.0, 0.0, 0.0], r, altitudeMeters);
    return true;
  }

  /// Sequential scalar update for `z = H·x + noise`, R = variance.
  void _scalarUpdate(List<double> h, double r, double z) {
    // PHᵀ (3×1)
    final List<double> pHt = [
      p[0][0] * h[0] + p[0][1] * h[1] + p[0][2] * h[2],
      p[1][0] * h[0] + p[1][1] * h[1] + p[1][2] * h[2],
      p[2][0] * h[0] + p[2][1] * h[1] + p[2][2] * h[2],
    ];
    final double s = h[0] * pHt[0] + h[1] * pHt[1] + h[2] * pHt[2] + r;
    if (s <= 0) return; // numerical guard
    final double innovation = z - (h[0] * x[0] + h[1] * x[1] + h[2] * x[2]);

    final List<double> k = [pHt[0] / s, pHt[1] / s, pHt[2] / s];
    x[0] += k[0] * innovation;
    x[1] += k[1] * innovation;
    x[2] += k[2] * innovation;

    // P = (I − K H) P  (Joseph form unnecessary; scalar updates are stable)
    final List<List<double>> kh = [
      [k[0] * h[0], k[0] * h[1], k[0] * h[2]],
      [k[1] * h[0], k[1] * h[1], k[1] * h[2]],
      [k[2] * h[0], k[2] * h[1], k[2] * h[2]],
    ];
    final List<List<double>> iKh = List.generate(3, (int i) {
      return List.generate(3, (int j) {
        final double identity = i == j ? 1.0 : 0.0;
        return identity - kh[i][j];
      });
    });
    _assignP(_matMul(iKh, p));
  }

  void _assignP(List<List<double>> next) {
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        p[i][j] = next[i][j];
      }
    }
  }

  static List<List<double>> _matMul(List<List<double>> a, List<List<double>> b) {
    final List<List<double>> out =
        List.generate(3, (_) => List<double>.filled(3, 0));
    for (int i = 0; i < 3; i++) {
      for (int k = 0; k < 3; k++) {
        final double aik = a[i][k];
        if (aik == 0) continue;
        for (int j = 0; j < 3; j++) {
          out[i][j] += aik * b[k][j];
        }
      }
    }
    return out;
  }

  static List<List<double>> _matAdd(List<List<double>> a, List<List<double>> b) {
    return List.generate(
        3, (int i) => List.generate(3, (int j) => a[i][j] + b[i][j]));
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

/// Throttled fusion output for UI / payload metadata.
class FusedSample {
  final int timestampMs;
  final double altitude;
  final double verticalVelocity;
  final double verticalAccel;
  final double pressureHpa;
  final double baroAltitude;
  final double? gpsAltitude;
  final double pitch;
  final double roll;
  final double heading;

  /// Elevation of the camera boresight (body +z axis) above the horizontal
  /// plane [deg] — orientation-independent, this is what AR overlays project.
  final double boresightElevationDeg;

  const FusedSample({
    required this.timestampMs,
    required this.altitude,
    required this.verticalVelocity,
    required this.verticalAccel,
    required this.pressureHpa,
    required this.baroAltitude,
    required this.gpsAltitude,
    required this.pitch,
    required this.roll,
    required this.heading,
    required this.boresightElevationDeg,
  });
}

/// Result of a finished measurement session.
class SessionResult {
  final MeasurementMode mode;
  final RawSensorLog log;
  final Position? lastPosition;
  final double startAltitude;
  final double endAltitude;
  final int startedAtMs;
  final int endedAtMs;
  final double meanFusedAltitude;

  const SessionResult({
    required this.mode,
    required this.log,
    required this.lastPosition,
    required this.startAltitude,
    required this.endAltitude,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.meanFusedAltitude,
  });
}

/// Raw sensor CSV log — exactly the bytes that go to R2 as the dump.
class RawSensorLog {
  static const int maxRows = 60000;

  final String csv;
  final int rows;
  final bool truncated;

  const RawSensorLog({
    required this.csv,
    required this.rows,
    required this.truncated,
  });
}

class SensorPermissionException implements Exception {
  final String message;
  SensorPermissionException(this.message);
  @override
  String toString() => 'SensorPermissionException: $message';
}

// ---------------------------------------------------------------------------
// SensorFusionService
// ---------------------------------------------------------------------------

/// Orchestrates the sensor streams, runs the attitude filter + EKF, and
/// buffers a raw CSV log suitable for the append-only backend upload.
///
/// Usage:
/// ```dart
/// final fusion = SensorFusionService();
/// await fusion.start(MeasurementMode.horizonDip);
/// // ... fusion.latest / fusion.samples ...
/// final SessionResult result = await fusion.stop();
/// ```
class SensorFusionService {
  /// Calibration output from [CalibrationScreen]; when set, gyro bias and
  /// magnetometer hard-iron offsets are subtracted before fusion.
  CalibrationResult? calibration;

  final FusionConfig config;

  /// Broadcast stream of throttled (≈5 Hz) fused samples for UI display.
  Stream<FusedSample> get samples => _sampleController.stream;

  /// Most recent fused sample (always current, unlike the throttled stream).
  FusedSample? get latest => _lastSample;

  bool get isRunning => _running;

  /// Interval between raw CSV log rows (10 Hz default).
  final Duration logInterval;

  SensorFusionService({FusionConfig? config, this.logInterval = const Duration(milliseconds: 100)})
      : config = config ?? FusionConfig() {
    _sampleController = StreamController<FusedSample>.broadcast();
  }

  late final StreamController<FusedSample> _sampleController;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _running = false;

  // --- session state
  MeasurementMode _mode = MeasurementMode.horizonDip;
  int _sessionStartEpochMs = 0;
  final Stopwatch _clock = Stopwatch();

  // --- attitude (complementary filter)
  FusionQuaternion _attitude = FusionQuaternion.identity;
  FusionVector3 _lastGyro = FusionVector3.zero(); // rad/s (calibrated)
  FusionVector3 _lastAccel = FusionVector3.zero(); // m/s²
  FusionVector3 _lastMag = FusionVector3.zero(); // µT (calibrated)
  bool _haveMag = false;
  double _lastGyroTickMs = 0;
  double _lastAccelTickMs = 0;

  // --- barometer
  double _lastPressureHpa = double.nan;
  VerticalAltitudeEKF? _ekf;

  // --- gnss
  Position? _lastPosition;
  double? _lastGpsAltitude;
  bool _sawFirstBaro = false;
  int _initDeadlineMs = 0;

  // --- csv log
  final StringBuffer _csv = StringBuffer();
  int _rows = 0;
  bool _truncated = false;
  double _lastLogMs = 0;
  double _lastSampleEmitMs = 0;
  FusedSample? _lastSample;

  // cumulative vertical-acceleration average for SessionResult telemetry
  double _accelSum = 0;
  int _accelCount = 0;

  /// Starts a measurement session: subscribes all sensor streams.
  Future<void> start(MeasurementMode mode) async {
    if (_running) {
      throw StateError('A measurement session is already running.');
    }
    await _ensureLocationPermission();

    _mode = mode;
    _running = true;
    _csv.clear();
    _csv.writeln('# GlobeOrFlat raw sensor dump');
    _csv.writeln('# protocol=GOFv1 mode=${mode.wireName}');
    _csv.writeln(
        '# columns=ts_ms,ax,ay,az,gx,gy,gz,mx,my,mz,pressure_hpa,gps_lat,gps_lon,gps_alt,gps_acc,fused_alt,vert_vel,pitch,roll,heading');
    _rows = 0;
    _truncated = false;
    _ekf = null;
    _lastPosition = null;
    _lastGpsAltitude = null;
    _lastPressureHpa = double.nan;
    _sawFirstBaro = false;
    _attitude = FusionQuaternion.identity;
    _haveMag = false;
    _accelSum = 0;
    _accelCount = 0;
    _sessionStartEpochMs = DateTime.now().millisecondsSinceEpoch;
    _clock
      ..reset()
      ..start();
    _lastGyroTickMs = _clock.elapsedMilliseconds.toDouble();
    _lastAccelTickMs = _lastGyroTickMs;
    _lastLogMs = -logInterval.inMilliseconds.toDouble();
    _lastSampleEmitMs = -1000;
    _initDeadlineMs = _lastGyroTickMs + 10000;

    _subscriptions.addAll([
      accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 20))
          .listen(_onAccelerometer, onError: (Object e) => _logError('accel', e)),
      gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 20))
          .listen(_onGyroscope, onError: (Object e) => _logError('gyro', e)),
      magnetometerEventStream(samplingPeriod: const Duration(milliseconds: 50))
          .listen(_onMagnetometer, onError: (Object e) => _logError('mag', e)),
      barometerEventStream(samplingPeriod: const Duration(milliseconds: 100))
          .listen(_onBarometer, onError: (Object e) => _logError('baro', e)),
      Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
        ),
      ).listen(_onPosition, onError: (Object e) => _logError('gps', e)),
    ]);
  }

  /// Stops the session, cancels streams and returns the assembled result.
  Future<SessionResult> stop() async {
    if (!_running) {
      throw StateError('No measurement session is running.');
    }
    for (final StreamSubscription<dynamic> s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    _clock.stop();
    _running = false;

    final int endedAt = _sessionStartEpochMs + _clock.elapsedMilliseconds;
    final VerticalAltitudeEKF? ekf = _ekf;
    final double endAlt = ekf?.altitude ?? _lastBaroAltitudeFallback();

    return SessionResult(
      mode: _mode,
      log: RawSensorLog(csv: _csv.toString(), rows: _rows, truncated: _truncated),
      lastPosition: _lastPosition,
      startAltitude: ekf?.altitude ?? endAlt,
      endAltitude: endAlt,
      startedAtMs: _sessionStartEpochMs,
      endedAtMs: endedAt,
      meanFusedAltitude: ekf?.altitude ?? endAlt,
    );
  }

  // -------------------------------------------------------------------------
  // Stream handlers
  // -------------------------------------------------------------------------

  void _onAccelerometer(AccelerometerEvent e) {
    final double nowMs = _clock.elapsedMilliseconds.toDouble();
    final double dt = _lastAccelTickMs <= 0
        ? 0.02
        : math.max((nowMs - _lastAccelTickMs) / 1000.0, 0.001);
    _lastAccelTickMs = nowMs;

    final FusionVector3 accel = FusionVector3(e.x, e.y, e.z);
    _lastAccel = accel;

    // 1) attitude prediction from gyro (integrated on the gyro stream),
    //    correction toward accel/mag reference happens on the mag stream.

    // 2) vertical acceleration in world frame (accelerometer measures
    //    specific force; at rest it reads +g → subtract gravity).
    final FusionVector3 aWorld = _attitude.rotate(accel);
    final double az = aWorld.z - kStandardGravity;
    _accelSum += az;
    _accelCount++;

    final VerticalAltitudeEKF? ekf = _ekf;
    if (ekf != null) {
      ekf.predict(dt, az);
    }
    _maybeEmit(nowMs);
  }

  void _onGyroscope(GyroscopeEvent e) {
    final double nowMs = _clock.elapsedMilliseconds.toDouble();
    final double dt = _lastGyroTickMs <= 0
        ? 0.02
        : math.max((nowMs - _lastGyroTickMs) / 1000.0, 0.001);
    _lastGyroTickMs = nowMs;

    final CalibrationResult? cal = calibration;
    double gx = e.x, gy = e.y, gz = e.z;
    if (cal != null) {
      gx -= cal.gyroBiasRadS[0];
      gy -= cal.gyroBiasRadS[1];
      gz -= cal.gyroBiasRadS[2];
    }
    final FusionVector3 omega = FusionVector3(gx, gy, gz);
    _lastGyro = omega;

    // Body-rate integration: q ← q ⊗ q(ω·dt).
    final double rate = omega.magnitude;
    if (rate > 1e-6) {
      final FusionQuaternion dq =
          FusionQuaternion.fromAxisAngle(omega.scale(1.0 / rate), rate * dt);
      _attitude = (_attitude * dq).normalized();
    }
  }

  void _onMagnetometer(MagnetometerEvent e) {
    final double nowMs = _clock.elapsedMilliseconds.toDouble();

    final CalibrationResult? cal = calibration;
    double mx = e.x, my = e.y, mz = e.z;
    if (cal != null) {
      mx = (mx - cal.magHardIronOffset[0]) * cal.magScale[0];
      my = (my - cal.magHardIronOffset[1]) * cal.magScale[1];
      mz = (mz - cal.magHardIronOffset[2]) * cal.magScale[2];
    }
    _lastMag = FusionVector3(mx, my, mz);
    _haveMag = true;

    // Complementary correction toward the accel(+mag) attitude reference.
    final FusionVector3 a = _lastAccel;
    final double aMag = a.magnitude;
    if (aMag > kStandardGravity * 0.7 && aMag < kStandardGravity * 1.3) {
      final double roll = math.atan2(a.y, a.z);
      final double pitch = math.atan2(-a.x, math.sqrt(a.y * a.y + a.z * a.z));
      double yaw = 0;
      final FusionVector3 m = _lastMag;
      if (_haveMag && m.magnitude > 10.0) {
        final double cosR = math.cos(roll), sinR = math.sin(roll);
        final double cosP = math.cos(pitch), sinP = math.sin(pitch);
        final double my2 = m.y * cosR - m.z * sinR;
        final double mx2 = m.x * cosP + m.y * sinR * sinP + m.z * cosR * sinP;
        yaw = math.atan2(-my2, mx2);
      }
      final FusionQuaternion reference =
          FusionQuaternion.fromEuler(yaw, pitch, roll);
      // α = 0.02 at 20 Hz ≈ 1 s time constant: gyro carries the fast motion,
      // accel/mag only remove long-term drift.
      _attitude = _attitude.nlerpTo(reference, 0.02);
    }

    _maybeEmit(nowMs);
  }

  void _onBarometer(BarometerEvent e) {
    final double nowMs = _clock.elapsedMilliseconds.toDouble();
    _lastPressureHpa = e.pressure;

    final VerticalAltitudeEKF? ekf = _ekf;
    if (ekf != null) {
      ekf.updateBaro(e.pressure);
    } else if (!_sawFirstBaro) {
      _sawFirstBaro = true;
      _tryInitialize(nowMs);
    }
    _maybeEmit(nowMs);
  }

  void _onPosition(Position pos) {
    final double nowMs = _clock.elapsedMilliseconds.toDouble();
    _lastPosition = pos;
    _lastGpsAltitude = pos.altitude;

    final VerticalAltitudeEKF? ekf = _ekf;
    if (ekf != null) {
      ekf.updateGps(pos.altitude, pos.accuracy);
    } else {
      _tryInitialize(nowMs);
    }
  }

  /// Initializes the EKF once a barometer reading and a GNSS fix exist
  /// (or after 10 s without GNSS — baro-only fallback with loose priors).
  void _tryInitialize(double nowMs) {
    if (_ekf != null) return;
    final bool haveBoth = _sawFirstBaro && _lastGpsAltitude != null;
    final bool haveAnything = _sawFirstBaro || _lastGpsAltitude != null;
    final bool timedOut = haveAnything && nowMs >= _initDeadlineMs;
    if (!haveBoth && !timedOut) return;

    final double baroAlt = _sawFirstBaro && !_lastPressureHpa.isNaN
        ? baroAltitudeFromPressureHpa(_lastPressureHpa)
        : 0;
    final double gpsAlt = _lastGpsAltitude ?? baroAlt;
    final double gpsSigma = _lastPosition?.accuracy ?? config.sigmaGpsFallback;

    _ekf = VerticalAltitudeEKF(
      initAltitude: gpsAlt,
      initBaroAltitude: baroAlt,
      initGpsSigma: haveBoth ? config.sigmaGpsDefault : config.sigmaGpsFallback,
      config: config,
    );
    // ignore: avoid_print
    print('GlobeOrFlat[fusion]: EKF initialised (gps=${haveBoth ? 'yes' : 'fallback'})');
  }

  double _lastBaroAltitudeFallback() =>
      _lastPressureHpa.isNaN ? 0 : baroAltitudeFromPressureHpa(_lastPressureHpa);

  // -------------------------------------------------------------------------
  // Sample emission + CSV logging
  // -------------------------------------------------------------------------

  void _maybeEmit(double nowMs) {
    final VerticalAltitudeEKF? ekf = _ekf;

    // Raw CSV row at logInterval (append-only log; stop at cap, flag it).
    if (nowMs - _lastLogMs >= logInterval.inMilliseconds) {
      _lastLogMs = nowMs;
      if (_rows < RawSensorLog.maxRows) {
        final (double yaw, double pitch, double roll) = _attitude.toEuler();
        final Position? pos = _lastPosition;
        _csv.writeln(
          '${(_sessionStartEpochMs + nowMs.round())}'
          ',${_f(_lastAccel.x)},${_f(_lastAccel.y)},${_f(_lastAccel.z)}'
          ',${_f(_lastGyro.x)},${_f(_lastGyro.y)},${_f(_lastGyro.z)}'
          ',${_f(_lastMag.x)},${_f(_lastMag.y)},${_f(_lastMag.z)}'
          ',${_lastPressureHpa.isNaN ? '' : _f(_lastPressureHpa)}'
          ',${pos?.latitude.toStringAsFixed(7) ?? ''}'
          ',${pos?.longitude.toStringAsFixed(7) ?? ''}'
          ',${pos?.altitude.toStringAsFixed(3) ?? ''}'
          ',${pos?.accuracy.toStringAsFixed(2) ?? ''}'
          ',${ekf == null ? '' : _f(ekf.altitude)}'
          ',${ekf == null ? '' : _f(ekf.verticalVelocity)}'
          ',${_f(pitch)},${_f(roll)},${_f(yaw)}',
        );
        _rows++;
      } else if (!_truncated) {
        _truncated = true;
        _csv.writeln('# TRUNCATED: row cap ${RawSensorLog.maxRows} reached');
      }
    }

    // Throttled fused sample for UI (~5 Hz).
    if (ekf != null && nowMs - _lastSampleEmitMs >= 200) {
      _lastSampleEmitMs = nowMs;
      final (double yaw, double pitch, double roll) = _attitude.toEuler();
      // Camera boresight: rotate body +z into the world frame; its z component
      // is sin(elevation above the horizontal plane).
      final FusionVector3 boresight = _attitude.rotate(const FusionVector3(0, 0, 1));
      final double boreSin = boresight.z < -1.0
          ? -1.0
          : (boresight.z > 1.0 ? 1.0 : boresight.z);
      final double boresightElevationDeg =
          math.asin(boreSin) * 180.0 / math.pi;
      _lastSample = FusedSample(
        timestampMs: _sessionStartEpochMs + nowMs.round(),
        altitude: ekf.altitude,
        verticalVelocity: ekf.verticalVelocity,
        verticalAccel: _accelCount > 0 ? _accelSum / _accelCount : 0,
        pressureHpa: _lastPressureHpa.isNaN ? 0 : _lastPressureHpa,
        baroAltitude: _lastBaroAltitudeFallback(),
        gpsAltitude: _lastGpsAltitude,
        pitch: pitch,
        roll: roll,
        heading: yaw,
        boresightElevationDeg: boresightElevationDeg,
      );
      if (!_sampleController.isClosed) {
        _sampleController.add(_lastSample!);
      }
    }
  }

  /// Fixed 6-decimal formatting — keeps the CSV compact and locale-independent.
  static String _f(double v) => v.toStringAsFixed(6);

  void _logError(String source, Object error) {
    // ignore: avoid_print
    print('GlobeOrFlat[fusion]: $source stream error: $error');
  }

  Future<void> _ensureLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw SensorPermissionException(
          'Location permission is required to tag measurements with GPS.');
    }
    final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw SensorPermissionException('Location services are disabled.');
    }
  }
}

// ---------------------------------------------------------------------------
// Calibration types (produced by calibration_screen.dart, consumed here)
// ---------------------------------------------------------------------------

/// Outcome of the guided calibration; persisted as JSON.
class CalibrationResult {
  /// Gyro bias [rad/s] measured during the flat-surface rest check.
  final List<double> gyroBiasRadS;

  /// Magnetometer hard-iron offset [µT] from the figure-8 sweep.
  final List<double> magHardIronOffset;

  /// Per-axis soft-iron scale factors (mean ≈ 1).
  final List<double> magScale;

  /// Quality scores 0–100.
  final double gyroScore;
  final double accelScore;
  final double magScore;

  final int completedAtMs;

  const CalibrationResult({
    required this.gyroBiasRadS,
    required this.magHardIronOffset,
    required this.magScale,
    required this.gyroScore,
    required this.accelScore,
    required this.magScore,
    required this.completedAtMs,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'gyroBiasRadS': gyroBiasRadS,
        'magHardIronOffset': magHardIronOffset,
        'magScale': magScale,
        'gyroScore': gyroScore,
        'accelScore': accelScore,
        'magScore': magScore,
        'completedAtMs': completedAtMs,
      };

  static CalibrationResult fromJson(Map<String, dynamic> json) {
    List<double> listOf(dynamic v) =>
        (v as List<dynamic>).map((dynamic e) => (e as num).toDouble()).toList();
    return CalibrationResult(
      gyroBiasRadS: listOf(json['gyroBiasRadS']),
      magHardIronOffset: listOf(json['magHardIronOffset']),
      magScale: listOf(json['magScale']),
      gyroScore: (json['gyroScore'] as num).toDouble(),
      accelScore: (json['accelScore'] as num).toDouble(),
      magScore: (json['magScore'] as num).toDouble(),
      completedAtMs: (json['completedAtMs'] as num).toInt(),
    );
  }
}
