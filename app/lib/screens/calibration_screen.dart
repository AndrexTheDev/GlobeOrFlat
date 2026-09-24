// ============================================================================
// GlobeOrFlat — Interactive 3D Calibration Screen
// SPDX-License-Identifier: MIT
//
// HARD GATE: this screen must be completed before any measurement screen is
// reachable (enforced in main.dart, and re-runnable on demand).
//
// Flow:
//   1. INTRO     — why calibration matters, what will happen.
//   2. FIGURE-8  — animated 3D phone (CustomPainter) tracing a lemniscate;
//                  fills the pitch×roll orientation-coverage grid and captures
//                  magnetometer extrema for hard-/soft-iron correction.
//   3. REST      — phone flat on a table; bubble-level 3D view; accumulates
//                  4 s of stillness → gyro bias + accelerometer quality.
//   4. RESULTS   — Gyro / Accelerometer / Magnetometer accuracy 0–100 %,
//                  saved and injected into SensorFusionService.
//
// The 3D phone model is pure CustomPainter vector art: a rotated cuboid with
// painter's-algorithm face sorting, Lambert shading and a live perspective
// projection of the device's real orientation (no 3D-engine dependency).
// ============================================================================

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/calibration_service.dart';
import '../services/sensor_fusion_service.dart'
    show CalibrationResult, FusionQuaternion, FusionVector3;

// ---------------------------------------------------------------------------
// Persistence of the calibration result
// ---------------------------------------------------------------------------

class CalibrationStorage {
  static const String _key = 'gof_calibration_v1';

  Future<CalibrationResult?> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      return CalibrationResult.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> save(CalibrationResult result) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(result.toJson()));
  }

  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

enum _CalibrationStep { intro, figure8, rest, results }

class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({
    super.key,
    required this.onCalibrated,
    this.storage,
  });

  /// Called after the user finishes (or has previously finished) calibration.
  final void Function(CalibrationResult result) onCalibrated;
  final CalibrationStorage? storage;

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen>
    with SingleTickerProviderStateMixin {
  final CalibrationService _calibration = CalibrationService();
  late final CalibrationStorage _storage;

  late final AnimationController _targetController;
  final List<StreamSubscription<dynamic>> _sensorSubs = <StreamSubscription<dynamic>>[];
  Timer? _uiTimer;

  AccelerometerEvent? _accel;
  GyroscopeEvent? _gyro;
  MagnetometerEvent? _mag;

  _CalibrationStep _step = _CalibrationStep.intro;
  CalibrationResult? _result;
  String? _sensorError;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? CalibrationStorage();
    _targetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    );
  }

  @override
  void dispose() {
    _stopSensors();
    _targetController.dispose();
    _uiTimer?.cancel();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Sensor plumbing (50 Hz acquisition, 30 fps UI)
  // -------------------------------------------------------------------------

  void _startSensors() {
    _sensorError = null;
    _sensorSubs.addAll(<StreamSubscription<dynamic>>[
      accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 20))
          .listen((AccelerometerEvent e) => _accel = e,
              onError: (Object e) => _setSensorError(e)),
      gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 20))
          .listen((GyroscopeEvent e) => _gyro = e,
              onError: (Object e) => _setSensorError(e)),
      magnetometerEventStream(samplingPeriod: const Duration(milliseconds: 20))
          .listen((MagnetometerEvent e) => _mag = e,
              onError: (Object e) => _setSensorError(e)),
    ]);
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final AccelerometerEvent? a = _accel;
      final GyroscopeEvent? g = _gyro;
      final MagnetometerEvent? m = _mag;
      if (a != null && g != null && m != null) {
        _calibration.onSensorSample(
          accelerometer: a,
          gyroscope: g,
          magnetometer: m,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      if (mounted) {
        setState(() {}); // repaint the 3D scene + progress indicators
      }
    });
  }

  void _stopSensors() {
    for (final StreamSubscription<dynamic> s in _sensorSubs) {
      s.cancel();
    }
    _sensorSubs.clear();
    _uiTimer?.cancel();
    _uiTimer = null;
    _targetController.stop();
  }

  void _setSensorError(Object e) {
    if (mounted) {
      setState(() => _sensorError = e.toString());
    }
  }

  // -------------------------------------------------------------------------
  // Step transitions
  // -------------------------------------------------------------------------

  void _beginFigure8() {
    _startSensors();
    setState(() => _step = _CalibrationStep.figure8);
    _targetController.repeat();
  }

  void _beginRest() {
    setState(() => _step = _CalibrationStep.rest);
    _targetController.stop();
  }

  Future<void> _finishRest() async {
    final CalibrationResult result = _calibration.finalize();
    await _storage.save(result);
    _stopSensors();
    if (mounted) {
      setState(() {
        _result = result;
        _step = _CalibrationStep.results;
      });
    }
  }

  void _restart() {
    _calibration.reset();
    setState(() {
      _result = null;
      _step = _CalibrationStep.intro;
    });
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // hard gate: no leaving mid-calibration
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1320),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: _buildStep(context),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    switch (_step) {
      case _CalibrationStep.intro:
        return _buildIntro(context);
      case _CalibrationStep.figure8:
        return _buildFigure8(context);
      case _CalibrationStep.rest:
        return _buildRest(context);
      case _CalibrationStep.results:
        return _buildResults(context);
    }
  }

  Widget _buildIntro(BuildContext context) {
    return _stepShell(
      context,
      title: 'Calibrate your sensors',
      icon: Icons.tune,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Text(
            'GlobeOrFlat measurements are only as good as your sensors.\n\n'
            'Two quick checks are required before your first measurement:\n',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
          ),
          _introRow(Icons.rotate_right, 'Figure-8 sweep',
              'Wakes up and zero-points the magnetometer'),
          _introRow(Icons.table_restaurant, 'Flat-surface rest',
              'Measures gyro drift while your phone lies still'),
          const SizedBox(height: 16),
          Text(
            'Total time: about 30 seconds.',
            style: TextStyle(color: Colors.tealAccent.shade200, fontSize: 14),
          ),
        ],
      ),
      actionLabel: 'Start calibration',
      onAction: _beginFigure8,
    );
  }

  Widget _introRow(IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(icon, color: Colors.tealAccent.shade200, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFigure8(BuildContext context) {
    final double figureProgress =
        (_calibration.figure8.coverage / kFigure8RequiredCoverage)
            .clamp(0.0, 1.0)
            .toDouble();
    return _stepShell(
      context,
      title: 'Step 1 · Figure-8 sweep',
      icon: Icons.rotate_right,
      child: Column(
        children: <Widget>[
          const SizedBox(height: 8),
          const Text(
            'Hold your phone upright and draw a slow figure-8 —\nlike stirring an invisible pot of soup.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
          ),
          Expanded(
            child: CustomPaint(
              painter: _CalibrationPainter(
                mode: _SceneMode.figure8,
                roll: _calibration.roll,
                pitch: _calibration.pitch,
                heading: _calibration.heading,
                targetT: _targetController.value,
                progress: figureProgress,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          _progressRow(
              'Magnetometer coverage', figureProgress, Icons.explore, Colors.tealAccent),
          const SizedBox(height: 12),
          Text(
            '${(figureProgress * 100).round()}%  ·  keep the phone away from magnets and metal',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
      actionLabel: _calibration.figure8Done ? 'Continue to rest check' : 'Keep sweeping…',
      onAction: _calibration.figure8Done ? _beginRest : null,
    );
  }

  Widget _buildRest(BuildContext context) {
    return _stepShell(
      context,
      title: 'Step 2 · Flat-surface rest',
      icon: Icons.table_restaurant,
      child: Column(
        children: <Widget>[
          const SizedBox(height: 8),
          const Text(
            'Place your phone flat on a table, screen up.\nDo not touch it until the level bubble settles.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
          ),
          Expanded(
            child: CustomPaint(
              painter: _CalibrationPainter(
                mode: _SceneMode.rest,
                roll: _calibration.roll,
                pitch: _calibration.pitch,
                heading: _calibration.heading,
                targetT: 0,
                progress: _calibration.rest.progress,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          _progressRow('Stillness', _calibration.rest.progress, Icons.timer,
              Colors.tealAccent),
          const SizedBox(height: 6),
          _progressRow('Gyroscope', _calibration.gyroscopeScore / 100,
              Icons.speed, Colors.lightBlueAccent),
          _progressRow('Accelerometer', _calibration.accelerometerScore / 100,
              Icons.vibration, Colors.orangeAccent),
          const SizedBox(height: 12),
          Text(
            '${(_calibration.rest.progress * 100).round()}%  ·  required: 4.0 s of stillness',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
      actionLabel: _calibration.restDone ? 'Finish calibration' : 'Hold still…',
      onAction: _calibration.restDone ? _finishRest : null,
    );
  }

  Widget _buildResults(BuildContext context) {
    final CalibrationResult? r = _result;
    if (r == null) {
      return _buildIntro(context);
    }
    final double overall = (r.gyroScore + r.accelScore + r.magScore) / 3;
    return _stepShell(
      context,
      title: 'Calibration complete',
      icon: Icons.verified,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.check_circle_outline,
              color: Colors.tealAccent, size: 72),
          const SizedBox(height: 18),
          _scoreRow('Gyroscope', r.gyroScore, Icons.speed),
          _scoreRow('Accelerometer', r.accelScore, Icons.vibration),
          _scoreRow('Magnetometer', r.magScore, Icons.explore),
          const Divider(color: Colors.white12, height: 32),
          Text(
            'Overall sensor accuracy: ${overall.round()}%',
            style: const TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Gyro bias and magnetometer offsets are now applied\nto every measurement you take.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: _restart,
            child: const Text('Recalibrate',
                style: TextStyle(color: Colors.white38)),
          ),
        ],
      ),
      actionLabel: 'Start measuring',
      onAction: () => widget.onCalibrated(r),
    );
  }

  Widget _scoreRow(String label, double score, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Row(
        children: <Widget>[
          Icon(icon, color: Colors.tealAccent.shade200, size: 22),
          const SizedBox(width: 12),
          SizedBox(width: 120, child: Text(label, style: const TextStyle(color: Colors.white))),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: (score / 100).clamp(0.0, 1.0).toDouble(),
                minHeight: 10,
                backgroundColor: Colors.white10,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.tealAccent),
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${score.round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressRow(String label, double value, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          SizedBox(
            width: 150,
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: value.clamp(0.0, 1.0).toDouble(),
                minHeight: 8,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              '${(value.clamp(0.0, 1.0) * 100).round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepShell(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Widget child,
    required String actionLabel,
    VoidCallback? onAction,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, color: Colors.tealAccent.shade200),
            const SizedBox(width: 10),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700)),
          ],
        ),
        if (_sensorError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Sensor error: $_sensorError',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),
        Expanded(child: child),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: onAction,
            style: ElevatedButton.styleFrom(
              backgroundColor: onAction == null
                  ? Colors.white10
                  : Colors.tealAccent.shade200,
              foregroundColor:
                  onAction == null ? Colors.white38 : const Color(0xFF0B1320),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            child: Text(actionLabel),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3D scene — CustomPainter vector-art phone
// ---------------------------------------------------------------------------

enum _SceneMode { figure8, rest }

class _CalibrationPainter extends CustomPainter {
  _CalibrationPainter({
    required this.mode,
    required this.roll,
    required this.pitch,
    required this.heading,
    required this.targetT,
    required this.progress,
  });

  final _SceneMode mode;
  final double roll, pitch, heading, targetT, progress;

  // Cuboid dimensions in scene units (screen-independent).
  static const double _w = 52, _h = 104, _d = 6;

  static const List<List<int>> _faces = <List<int>>[
    <int>[0, 1, 2, 3], // back
    <int>[5, 4, 7, 6], // front
    <int>[4, 0, 3, 7], // left
    <int>[1, 5, 6, 2], // right
    <int>[4, 5, 1, 0], // bottom
    <int>[3, 2, 6, 7], // top
  ];

  static const List<FusionVector3> _faceNormals = <FusionVector3>[
    FusionVector3(0, 0, -1),
    FusionVector3(0, 0, 1),
    FusionVector3(-1, 0, 0),
    FusionVector3(1, 0, 0),
    FusionVector3(0, -1, 0),
    FusionVector3(0, 1, 0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double scale = math.min(size.width, size.height) / 340;

    _paintProgressRing(canvas, center, scale);
    if (mode == _SceneMode.figure8) {
      _paintFigure8Guide(canvas, center, scale);
    } else {
      _paintBubbleLevel(canvas, center, scale);
    }
    _paintPhone(canvas, center, scale);
  }

  FusionQuaternion get _attitude => FusionQuaternion.fromEuler(heading, pitch, roll);

  /// Projects a body-frame point to screen coordinates with mild perspective.
  Offset _project(FusionVector3 p, Offset center, double scale) {
    final FusionVector3 w = _attitude.rotate(p);
    final double persp = 420 / (420 - w.z * scale); // z>0 = toward viewer
    return Offset(
      center.dx + w.x * scale * persp,
      center.dy - w.y * scale * persp,
    );
  }

  List<FusionVector3> get _corners => <FusionVector3>[
        const FusionVector3(-_w / 2, -_h / 2, -_d / 2),
        const FusionVector3(_w / 2, -_h / 2, -_d / 2),
        const FusionVector3(_w / 2, _h / 2, -_d / 2),
        const FusionVector3(-_w / 2, _h / 2, -_d / 2),
        const FusionVector3(-_w / 2, -_h / 2, _d / 2),
        const FusionVector3(_w / 2, -_h / 2, _d / 2),
        const FusionVector3(_w / 2, _h / 2, _d / 2),
        const FusionVector3(-_w / 2, _h / 2, _d / 2),
      ];

  void _paintPhone(Canvas canvas, Offset center, double scale) {
    final List<FusionVector3> corners = _corners;
    final FusionQuaternion q = _attitude;

    // Face depth sort (painter's algorithm, far → near).
    final List<int> order = List<int>.generate(_faces.length, (int i) => i);
    final List<double> depths = _faces
        .map((List<int> f) => _faceCentroid(f, corners).z)
        .toList(growable: false);
    order.sort((int a, int b) => depths[a].compareTo(depths[b]));

    final FusionVector3 light = const FusionVector3(0.35, 0.5, 0.8).normalized();

    for (final int fi in order) {
      final List<int> face = _faces[fi];
      final FusionVector3 normalWorld = q.rotate(_faceNormals[fi]);
      final bool isFront = fi == 1;
      final bool backFacing = normalWorld.z < 0 && !isFront;

      final List<Offset> pts = <Offset>[
        _project(corners[face[0]], center, scale),
        _project(corners[face[1]], center, scale),
        _project(corners[face[2]], center, scale),
        _project(corners[face[3]], center, scale),
      ];

      final Path facePath = Path()
        ..moveTo(pts[0].dx, pts[0].dy)
        ..lineTo(pts[1].dx, pts[1].dy)
        ..lineTo(pts[2].dx, pts[2].dy)
        ..lineTo(pts[3].dx, pts[3].dy)
        ..close();

      // Body: dark slate edges; front face: screen blue with Lambert shading.
      final double lambert = math
          .max(0.0, normalWorld.dot(light))
          .toDouble();
      if (isFront) {
        final Paint body = Paint()
          ..color = const Color(0xFF102A43)
          ..style = PaintingStyle.fill;
        canvas.drawPath(facePath, body);
        // Inset "screen".
        final Offset c0 = _quadCentroid(pts);
        final List<Offset> screen =
            pts.map((Offset p) => Offset.lerp(c0, p, 0.86)!).toList();
        final Path screenPath = Path()
          ..moveTo(screen[0].dx, screen[0].dy)
          ..lineTo(screen[1].dx, screen[1].dy)
          ..lineTo(screen[2].dx, screen[2].dy)
          ..lineTo(screen[3].dx, screen[3].dy)
          ..close();
        canvas.drawPath(
          screenPath,
          Paint()
            ..shader = uiGradient(screen[0], screen[2])
            ..style = PaintingStyle.fill,
        );
        // Camera dot near the top edge of the screen.
        final Offset cam = Offset.lerp(c0, screen[0], 0.82)!;
        canvas.drawCircle(cam, 2.4, Paint()..color = const Color(0xFF0B1320));
        canvas.drawCircle(cam, 1.2, Paint()..color = Colors.tealAccent.shade200);
      } else {
        final double shade = backFacing ? 0.16 : 0.22 + 0.5 * lambert;
        canvas.drawPath(
          facePath,
          Paint()
            ..color = Color.fromARGB(255, (18 * shade + 8).round(),
                (36 * shade + 14).round(), (56 * shade + 22).round())
            ..style = PaintingStyle.fill,
        );
      }
      canvas.drawPath(
        facePath,
        Paint()
          ..color = backFacing ? Colors.white12 : Colors.white24
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  Shader uiGradient(Offset a, Offset b) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[const Color(0xFF0E4D64), const Color(0xFF136F88)],
    ).createShader(Rect.fromPoints(a, b));
  }

  FusionVector3 _faceCentroid(List<int> face, List<FusionVector3> corners) {
    double x = 0, y = 0, z = 0;
    for (final int i in face) {
      x += corners[i].x;
      y += corners[i].y;
      z += corners[i].z;
    }
    return FusionVector3(x / face.length, y / face.length, z / face.length);
  }

  Offset _quadCentroid(List<Offset> pts) {
    double x = 0, y = 0;
    for (final Offset p in pts) {
      x += p.dx;
      y += p.dy;
    }
    return Offset(x / pts.length, y / pts.length);
  }

  /// Lemniscate of Gerono: x = A·sin t, y = B·sin t·cos t (dotted guide).
  void _paintFigure8Guide(Canvas canvas, Offset center, double scale) {
    const double a = 92, b = 62;
    final Paint dot = Paint()
      ..color = Colors.tealAccent.withOpacity(0.35)
      ..style = PaintingStyle.fill;

    for (double t = 0; t < 2 * math.pi; t += 0.14) {
      final double x = a * math.sin(t);
      final double y = b * math.sin(t) * math.cos(t);
      canvas.drawCircle(
        Offset(center.dx + x * scale, center.dy - y * scale),
        2.2 * scale,
        dot,
      );
    }

    // Moving target dot the user's phone icon should chase.
    final double tt = 2 * math.pi * targetT;
    final double tx = a * math.sin(tt);
    final double ty = b * math.sin(tt) * math.cos(tt);
    final Offset target =
        Offset(center.dx + tx * scale, center.dy - ty * scale);
    canvas.drawCircle(target, 7 * scale,
        Paint()..color = Colors.tealAccent.withOpacity(0.25));
    canvas.drawCircle(
        target, 3.6 * scale, Paint()..color = Colors.tealAccent);

    // Direction hint text
    final TextPainter tp = TextPainter(
      text: const TextSpan(
          text: 'figure-8',
          style: TextStyle(color: Colors.white24, fontSize: 12)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + 110 * scale));
  }

  /// Bubble level: outer rings + live bubble offset by (roll, pitch).
  void _paintBubbleLevel(Canvas canvas, Offset center, double scale) {
    final double r = 78 * scale;
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white24;
    canvas.drawCircle(center, r, ring);
    canvas.drawCircle(center, r * 0.55, ring..color = Colors.white12);
    // Crosshair.
    canvas.drawLine(center + Offset(-r, 0), center + Offset(r, 0),
        Paint()..color = Colors.white10);
    canvas.drawLine(center + Offset(0, -r), center + Offset(0, r),
        Paint()..color = Colors.white10);

    final Offset bubble = Offset(
      center.dx + math.sin(roll) * r * 0.9,
      center.dy - math.sin(pitch) * r * 0.9,
    );
    final bool level =
        math.sqrt(math.pow(math.sin(roll), 2) + math.pow(math.sin(pitch), 2)) < 0.05;
    canvas.drawCircle(
      bubble,
      10 * scale,
      Paint()..color = (level ? Colors.tealAccent : Colors.orangeAccent).withOpacity(0.25),
    );
    canvas.drawCircle(
      bubble,
      5.5 * scale,
      Paint()..color = level ? Colors.tealAccent : Colors.orangeAccent,
    );
  }

  void _paintProgressRing(Canvas canvas, Offset center, double scale) {
    final double radius = 132 * scale;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = Colors.white10,
    );
    if (progress > 0.002) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..color = Colors.tealAccent,
      );
    }
  }

  @override
  bool shouldRepaint(_CalibrationPainter oldDelegate) => true;
}
