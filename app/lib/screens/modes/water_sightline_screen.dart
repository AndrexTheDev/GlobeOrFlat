// ============================================================================
// GlobeOrFlat — Mode B: "Water Sightline" (Camera zoom over water)
// SPDX-License-Identifier: MIT
//
// Protocol: observe a distant object across water (ship, buoy, lighthouse,
// shore buildings). Enter the distance to the target and its height; the HUD
// overlays what each model says you should see at the waterline:
//
//   • red band on the target  — globe occlusion h_hidden = (d−d_obs)²/(2·R_eff)
//   • cyan dashed waterline   — flat-Earth prediction: nothing ever hidden
//
// The observer estimates the actually-hidden fraction with a slider; the app
// records the deviation between estimate and globe prediction.
// ============================================================================

import 'dart:async' show StreamSubscription;
import 'dart:math' as math;
import 'dart:ui' show PathEffect;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../physics/earth_curvature.dart';
import '../../services/measurement_pipeline.dart';
import '../../services/sensor_fusion_service.dart';
import '../../services/sync_manager.dart';
import '../../widgets/ar_camera_view.dart';

class WaterSightlineScreen extends StatefulWidget {
  const WaterSightlineScreen({super.key, required this.sync});

  final SyncManager sync;

  @override
  State<WaterSightlineScreen> createState() => _WaterSightlineScreenState();
}

class _WaterSightlineScreenState extends State<WaterSightlineScreen> {
  final SensorFusionService _fusion = SensorFusionService();
  final TextEditingController _distanceCtrl =
      TextEditingController(text: '10.0');
  final TextEditingController _targetHeightCtrl =
      TextEditingController(text: '12.0');
  final TextEditingController _observerHeightCtrl =
      TextEditingController(text: '2.0');

  StreamSubscription<FusedSample>? _sampleSub;
  FusedSample? _last;
  double _measuredHiddenFraction = 0.0; // user estimate, 0..1 of target height
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _beginSession();
    _distanceCtrl.addListener(_refresh);
    _targetHeightCtrl.addListener(_refresh);
    _observerHeightCtrl.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _sampleSub?.cancel();
    _safeStop();
    _distanceCtrl.dispose();
    _targetHeightCtrl.dispose();
    _observerHeightCtrl.dispose();
    super.dispose();
  }

  Future<void> _beginSession() async {
    try {
      _sampleSub?.cancel();
      _sampleSub = _fusion.samples.listen((FusedSample s) {
        if (mounted) {
          setState(() => _last = s);
        }
      });
      await _fusion.start(MeasurementMode.waterSightline);
    } on SensorPermissionException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } on StateError catch (_) {
      // already running
    }
  }

  /// Fire-and-forget session teardown that can never throw.
  Future<void> _safeStop() async {
    try {
      if (_fusion.isRunning) {
        await _fusion.stop();
      }
    } on Exception {
      // session already gone — nothing to do
    }
  }

  double get _distanceKm =>
      double.tryParse(_distanceCtrl.text.replaceFirst(',', '.')) ?? 10.0;
  double get _targetHeightM =>
      double.tryParse(_targetHeightCtrl.text.replaceFirst(',', '.')) ?? 12.0;
  double get _observerHeightM {
    final double? manual =
        double.tryParse(_observerHeightCtrl.text.replaceFirst(',', '.'));
    if (manual != null && manual > 0) return manual;
    final double fused = _last?.altitude ?? 0;
    return fused > 0.25 ? fused : 2.0;
  }

  double get _predictedHiddenM => hiddenHeightMeters(
        observerHeightMeters: _observerHeightM,
        distanceKm: _distanceKm,
      );

  double get _measuredHiddenM =>
      _measuredHiddenFraction * math.max(_targetHeightM, 0.1);

  Future<void> _capture() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final double predicted = _predictedHiddenM;
      final double? deviation = predicted > 1e-6
          ? deviationPercent(measured: _measuredHiddenM, predicted: predicted)
          : null;

      final SessionResult result = await _fusion.stop();
      final Position? pos = result.lastPosition;
      if (pos == null) {
        if (mounted) {
          setState(() => _error = 'No GPS fix — cannot record sightline.');
        }
        await _beginSession();
        return;
      }

      final StringBuffer csv = StringBuffer(result.log.csv);
      csv.writeln('# water_sightline,distance_km=${_distanceKm.toStringAsFixed(3)}');
      csv.writeln('# water_sightline,observer_height_m=${_observerHeightM.toStringAsFixed(2)}');
      csv.writeln('# water_sightline,target_height_m=${_targetHeightM.toStringAsFixed(2)}');
      csv.writeln('# water_sightline,predicted_hidden_m=${predicted.toStringAsFixed(4)}');
      csv.writeln('# water_sightline,measured_hidden_m=${_measuredHiddenM.toStringAsFixed(4)}');
      csv.writeln('# water_sightline,flat_model_hidden_m=0');
      if (deviation != null) {
        csv.writeln('# water_sightline,deviation_pct=${deviation.toStringAsFixed(4)}');
      }

      await MeasurementPipeline(widget.sync).enqueueAndSync(
        mode: MeasurementMode.waterSightline,
        gpsLat: pos.latitude,
        gpsLon: pos.longitude,
        altitudeM: math.max(result.meanFusedAltitude, 0),
        curvatureDeviationPercentage: deviation,
        capturedAtMs: result.endedAtMs,
        rawCsv: csv.toString(),
        extraPayload: <String, Object?>{
          // stripped server-side, kept for local audit
          'sightline_distance_km': _distanceKm,
          'sightline_target_height_m': _targetHeightM,
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF102A43),
            content: Text(
              'Sightline queued — predicted hidden ${predicted.toStringAsFixed(2)} m, '
              'your estimate ${_measuredHiddenM.toStringAsFixed(2)} m',
            ),
          ),
        );
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Mode B · Water Sightline'),
        backgroundColor: Colors.black54,
      ),
      body: _error != null
          ? Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!, textAlign: TextAlign.center),
            ))
          : Column(
              children: <Widget>[
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ArCameraView(overlayBuilder: _buildHud),
                    ],
                  ),
                ),
                _buildControls(),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _capture,
        icon: _busy
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.photo_camera),
        label: const Text('Capture sightline'),
      ),
    );
  }

  Widget _buildHud(BuildContext context) {
    return CustomPaint(
      painter: _OcclusionHudPainter(
        distanceKm: _distanceKm,
        targetHeightM: _targetHeightM,
        observerHeightM: _observerHeightM,
        hiddenM: _predictedHiddenM,
        measuredHiddenM: _measuredHiddenM,
      ),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildControls() {
    final double predicted = _predictedHiddenM;
    final double? deviation = predicted > 1e-6
        ? deviationPercent(measured: _measuredHiddenM, predicted: predicted)
        : null;
    final double horizonKm = horizonDistanceKm(_observerHeightM);

    return SafeArea(
      top: false,
      child: Container(
        color: const Color(0xE60B1320),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                _numField('distance (km)', _distanceCtrl),
                const SizedBox(width: 8),
                _numField('target (m)', _targetHeightCtrl),
                const SizedBox(width: 8),
                _numField('eye (m)', _observerHeightCtrl),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'horizon at ${horizonKm.toStringAsFixed(2)} km · globe hides '
              '${predicted.toStringAsFixed(2)} m · flat hides 0 m'
              '${deviation != null ? ' · your estimate: ${deviation.toStringAsFixed(0)} % off' : ''}',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                const Text('observed occlusion',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: _measuredHiddenFraction.clamp(0.0, 1.0).toDouble(),
                    onChanged: (double v) =>
                        setState(() => _measuredHiddenFraction = v),
                    divisions: 100,
                    label: '${(_measuredHiddenFraction * 100).round()} %',
                  ),
                ),
                Text('${(_measuredHiddenFraction * 100).round()} %',
                    style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numField(String label, TextEditingController ctrl) {
    return Expanded(
      child: TextField(
        controller: ctrl,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: false),
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        ],
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white38, fontSize: 11),
          isDense: true,
          filled: true,
          fillColor: Colors.white10,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// HUD: schematic target with occlusion band + model waterlines
// ---------------------------------------------------------------------------

class _OcclusionHudPainter extends CustomPainter {
  _OcclusionHudPainter({
    required this.distanceKm,
    required this.targetHeightM,
    required this.observerHeightM,
    required this.hiddenM,
    required this.measuredHiddenM,
  });

  final double distanceKm;
  final double targetHeightM;
  final double observerHeightM;
  final double hiddenM;
  final double measuredHiddenM;

  @override
  void paint(Canvas canvas, Size size) {
    final TextPainter tp = TextPainter(textDirection: TextDirection.ltr);

    // Schematic occupies the right third of the screen.
    final double baseX = size.width * 0.78;
    final double groundY = size.height * 0.62;
    final double scale =
        (size.height * 0.45) / math.max(math.max(targetHeightM, hiddenM), 1.0);

    // Target outline.
    final double targetW = 34;
    final Paint outline = Paint()
      ..color = Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final Rect targetRect = Rect.fromLTWH(
        baseX, groundY - targetHeightM * scale, targetW, targetHeightM * scale);
    canvas.drawRect(targetRect, outline);

    // RED: predicted hidden band (from target base up).
    if (hiddenM > 0) {
      final Paint red = Paint()..color = const Color(0x99FF3B30);
      canvas.drawRect(
        Rect.fromLTWH(baseX, groundY - hiddenM * scale, targetW,
            math.min(hiddenM * scale, targetHeightM * scale)),
        red,
      );
    }

    // Orange: user-estimated hidden height marker.
    final double yMeas = groundY - measuredHiddenM * scale;
    final Paint orange = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 2;
    canvas.drawLine(Offset(baseX - 14, yMeas), Offset(baseX + targetW + 14, yMeas), orange);

    // CYAN DASHED: flat-Earth waterline (nothing hidden → at target base).
    final Paint cyan = Paint()
      ..color = const Color(0xFF18E0FF)
      ..strokeWidth = 2
      ..pathEffect = PathEffect.dash(const <double>[8, 6], 0);
    canvas.drawLine(
        Offset(baseX - 90, groundY), Offset(baseX + targetW + 40, groundY), cyan);

    // Ground/water shading below.
    canvas.drawRect(
      Rect.fromLTWH(0, groundY, size.width, size.height - groundY),
      Paint()..color = const Color(0x33103A52),
    );

    void label(String text, Offset at, Color color,
        {double fontSize = 11, bool bold = false}) {
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400),
      );
      tp.layout();
      tp.paint(canvas, at);
    }

    label('globe hides ${hiddenM.toStringAsFixed(2)} m',
        Offset(12, groundY - 66), const Color(0xFFFF6B61), bold: true);
    label('flat hides 0 m', Offset(12, groundY - 48), const Color(0xFF18E0FF));
    label('d = ${distanceKm.toStringAsFixed(1)} km · h_eye = '
        '${observerHeightM.toStringAsFixed(1)} m', Offset(12, groundY - 30),
        Colors.white54);
    label('◀ your estimate', Offset(baseX + targetW + 18, yMeas - 7),
        Colors.orangeAccent);
    label('${targetHeightM.toStringAsFixed(0)} m',
        Offset(baseX + targetW + 6, groundY - targetHeightM * scale - 4),
        Colors.white70);
  }

  @override
  bool shouldRepaint(_OcclusionHudPainter old) =>
      old.hiddenM != hiddenM ||
      old.distanceKm != distanceKm ||
      old.measuredHiddenM != measuredHiddenM ||
      old.targetHeightM != targetHeightM;
}
