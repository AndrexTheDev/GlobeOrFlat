// ============================================================================
// GlobeOrFlat — Mode A: "Horizon Dip" (Camera AR HUD)
// SPDX-License-Identifier: MIT
//
// Protocol: stand at a known height above sea level with a clear view of the
// sea horizon. Point the camera so the crosshair sits on the visible horizon
// and hold steady — the measured dip is the negated camera pitch (pointing
// DOWN at the horizon ⇒ negative pitch ⇒ dip = −pitch).
//
// HUD elements over the live preview:
//   • green solid line   — the true horizontal plane (0° elevation), placed
//                          using the live EKF pitch.
//   • cyan dashed line   — where the globe model (θ ≈ 1.06′·√h) predicts the
//                          horizon should appear for the current EKF altitude.
//   • tick scale + live readouts comparing measured vs predicted vs flat (0).
//
// On a flat Earth the cyan line would coincide with the green one (dip = 0);
// the vertical gap between the lines IS the globe prediction in pixels.
// ============================================================================

import 'dart:async' show StreamSubscription;
import 'dart:math' as math;
import 'dart:ui' show PathEffect;

import 'package:flutter/material.dart';

import '../../physics/earth_curvature.dart';
import '../../services/measurement_pipeline.dart';
import '../../services/sensor_fusion_service.dart';
import '../../services/sync_manager.dart';
import '../../widgets/ar_camera_view.dart';

/// Assumed vertical field of view of the camera [°] — maps angles to pixels.
/// (Conservative default for a phone main camera at ResolutionPreset.medium;
/// calibration of the true FOV is on the roadmap.)
const double kAssumedVerticalFovDeg = 60.0;

class HorizonDipScreen extends StatefulWidget {
  const HorizonDipScreen({super.key, required this.sync});

  final SyncManager sync;

  @override
  State<HorizonDipScreen> createState() => _HorizonDipScreenState();
}

class _HorizonDipScreenState extends State<HorizonDipScreen> {
  final SensorFusionService _fusion = SensorFusionService(
    logInterval: const Duration(milliseconds: 100),
  );
  StreamSubscription<FusedSample>? _sampleSub;
  FusedSample? _last;
  String? _error;
  bool _busy = false;
  double _lastPitchDeg = 0;
  double _pitchRateDegPerS = 0; // for the stability badge
  DateTime _lastSampleAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _beginSession();
  }

  @override
  void dispose() {
    _sampleSub?.cancel();
    _safeStop();
    super.dispose();
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

  Future<void> _beginSession() async {
    try {
      _sampleSub?.cancel();
      _sampleSub = _fusion.samples.listen((FusedSample s) {
        if (!mounted) return;
        final DateTime now = DateTime.now();
        final double dt = now.difference(_lastSampleAt).inMilliseconds / 1000.0;
        final double boresightDeg = s.boresightElevationDeg;
        if (dt > 0.05) {
          _pitchRateDegPerS = (boresightDeg - _lastPitchDeg).abs() / dt;
          _lastPitchDeg = boresightDeg;
          _lastSampleAt = now;
        }
        setState(() => _last = s);
      });
      await _fusion.start(MeasurementMode.horizonDip);
    } on SensorPermissionException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } on StateError catch (_) {
      // session already running — nothing to do
    }
  }

  bool get _steady => _pitchRateDegPerS < 0.15;

  Future<void> _capture() async {
    final FusedSample? sample = _last;
    if (sample == null || _busy) return;
    setState(() => _busy = true);
    try {
      final double altitude = math.max(sample.altitude, 0.25);
      final double predictedArcmin = horizonDipArcminutes(altitude);
      // Crosshair on the horizon ⇒ boresight elevation = −dip.
      final double measuredArcmin = -sample.boresightElevationDeg * 60.0;
      final double? deviation = deviationPercent(
        measured: measuredArcmin,
        predicted: predictedArcmin,
      );

      final SessionResult result = await _fusion.stop();
      final Position? pos = result.lastPosition;
      if (pos == null) {
        if (mounted) {
          setState(() {
            _error = 'No GPS fix — cannot record a dip measurement.';
            _busy = false;
          });
        }
        await _beginSession();
        return;
      }

      final String csv = _withDipAnnotations(
        result.log.csv,
        altitudeM: altitude,
        measuredArcmin: measuredArcmin,
        predictedArcmin: predictedArcmin,
        deviationPct: deviation,
      );

      final String uuid = await _pipelineImpl().enqueueAndSync(
        mode: MeasurementMode.horizonDip,
        gpsLat: pos.latitude,
        gpsLon: pos.longitude,
        altitudeM: altitude,
        curvatureDeviationPercentage: deviation,
        capturedAtMs: result.endedAtMs,
        rawCsv: csv,
      );

      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: const Color(0xFF102A43),
            title: const Text('Horizon dip recorded'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('measured:    ${formatDipArcminutes(measuredArcmin)}'),
                Text('globe model: ${formatDipArcminutes(predictedArcmin)}'),
                Text('flat model:  0′0.0″'),
                if (deviation != null)
                  Text('deviation:   ${deviation.toStringAsFixed(1)} %'),
                const SizedBox(height: 8),
                Text('queued as $uuid',
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        await _beginSession();
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  MeasurementPipeline _pipelineImpl() => MeasurementPipeline(widget.sync);

  static String _withDipAnnotations(
    String csv, {
    required double altitudeM,
    required double measuredArcmin,
    required double predictedArcmin,
    double? deviationPct,
  }) {
    final StringBuffer buf = StringBuffer(csv);
    buf.writeln('# horizon_dip,altitude_m=${altitudeM.toStringAsFixed(2)}');
    buf.writeln('# horizon_dip,measured_arcmin=${measuredArcmin.toStringAsFixed(4)}');
    buf.writeln('# horizon_dip,predicted_arcmin=${predictedArcmin.toStringAsFixed(4)}');
    buf.writeln('# horizon_dip,flat_model_arcmin=0');
    if (deviationPct != null) {
      buf.writeln('# horizon_dip,deviation_pct=${deviationPct.toStringAsFixed(4)}');
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Mode A · Horizon Dip'),
        backgroundColor: Colors.black54,
      ),
      body: _error != null
          ? _errorView()
          : Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ArCameraView(overlayBuilder: _buildHud),
                _buildReadoutPanel(),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_last != null && _steady && !_busy) ? _capture : null,
        icon: _busy
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.photo_camera),
        label: Text(_busy ? 'Saving…' : _steady ? 'Capture dip' : 'Hold steady…'),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            const SizedBox(height: 12),
            Text(_error ?? '', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildHud(BuildContext context) {
    final FusedSample? sample = _last;
    final double altitude = sample == null ? 0 : math.max(sample.altitude, 0.25);
    final double predictedArcmin = horizonDipArcminutes(altitude);
    return CustomPaint(
      painter: _HorizonDipHudPainter(
        boresightElevationDeg:
            sample == null ? 0 : sample.boresightElevationDeg,
        predictedDipArcmin: predictedArcmin,
        hasFix: sample != null,
      ),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildReadoutPanel() {
    final FusedSample? s = _last;
    final double altitude = s == null ? 0 : math.max(s.altitude, 0.25);
    final double predicted = horizonDipArcminutes(altitude);
    final double measured =
        s == null ? 0 : -s.boresightElevationDeg * 60.0;
    return Positioned(
      left: 12,
      right: 12,
      bottom: 88,
      child: Card(
        color: Colors.black.withOpacity(0.55),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white, fontSize: 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      _steady ? Icons.check_circle : Icons.sync,
                      size: 14,
                      color: _steady ? Colors.greenAccent : Colors.orangeAccent,
                    ),
                    const SizedBox(width: 6),
                    Text(_steady ? 'steady' : 'moving',
                        style: const TextStyle(fontSize: 11)),
                    const Spacer(),
                    Text(
                      s == null
                          ? 'waiting for sensors…'
                          : 'alt ${altitude.toStringAsFixed(1)} m',
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _readoutRow('Measured dip (crosshair)',
                    formatDipArcminutes(measured), Colors.greenAccent),
                _readoutRow(
                    'Globe 1.06′·√h', formatDipArcminutes(predicted), Colors.cyanAccent),
                _staticRow('Flat model', '0′0.0″'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _staticRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(color: Colors.white38)),
        ],
      ),
    );
  }

  Widget _readoutRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// HUD painter: elevation lines projected through the assumed camera FOV
// ---------------------------------------------------------------------------

class _HorizonDipHudPainter extends CustomPainter {
  _HorizonDipHudPainter({
    required this.boresightElevationDeg,
    required this.predictedDipArcmin,
    required this.hasFix,
  });

  final double boresightElevationDeg;
  final double predictedDipArcmin;
  final bool hasFix;

  /// Screen y [px] of a world elevation [elevDeg] given the camera boresight
  /// elevation β: the line of elevation e sits (β − e)·px below the center.
  double _yForElevation(double elevDeg, Size size, double pxPerDeg) {
    return size.height / 2 + (boresightElevationDeg - elevDeg) * pxPerDeg;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double pxPerDeg = size.height / kAssumedVerticalFovDeg;
    final double center = size.height / 2;

    // Angle tick scale on the left edge (every 2°, labels every 10°).
    final Paint tick = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    final TextPainter labelTp = TextPainter(textDirection: TextDirection.ltr);
    for (double e = -30; e <= 30; e += 2) {
      final double y = _yForElevation(e, size, pxPerDeg);
      if (y < 0 || y > size.height) continue;
      final bool major = e.toInt() % 10 == 0;
      canvas.drawLine(Offset(0, y), Offset(major ? 26 : 12, y), tick);
      if (major) {
        labelTp.text = TextSpan(
          text: '$e°',
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        );
        labelTp.layout();
        labelTp.paint(canvas, Offset(30, y - 6));
      }
    }

    // GREEN: true horizontal plane (0°).
    final double yHorizon0 = _yForElevation(0, size, pxPerDeg);
    final Paint green = Paint()
      ..color = const Color(0xFF4CFF87)
      ..strokeWidth = 2.5;
    canvas.drawLine(Offset(0, yHorizon0), Offset(size.width, yHorizon0), green);

    // CYAN DASHED: globe-predicted horizon (elevation = −dip).
    final double dipDeg = predictedDipArcmin / 60.0;
    final double yGlobe = _yForElevation(-dipDeg, size, pxPerDeg);
    final Paint cyan = Paint()
      ..color = const Color(0xFF18E0FF)
      ..strokeWidth = 2.5
      ..pathEffect = _dashPathEffect();
    final Path dashed = Path()
      ..moveTo(0, yGlobe)
      ..lineTo(size.width, yGlobe);
    canvas.drawPath(dashed, cyan);

    // Gap annotation between the two model lines (this gap IS the prediction).
    if ((yGlobe - yHorizon0).abs() > 14) {
      final double x = size.width - 26;
      final Paint connector = Paint()
        ..color = Colors.cyanAccent.withOpacity(0.7)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(x, yHorizon0), Offset(x, yGlobe), connector);
      canvas.drawLine(Offset(x - 6, yHorizon0), Offset(x + 6, yHorizon0), connector);
      canvas.drawLine(Offset(x - 6, yGlobe), Offset(x + 6, yGlobe), connector);
      labelTp.text = TextSpan(
        text: 'Δ ${predictedDipArcmin.toStringAsFixed(2)}′',
        style: const TextStyle(color: Colors.cyanAccent, fontSize: 11),
      );
      labelTp.layout();
      labelTp.paint(
          canvas, Offset(x - (labelTp.width ?? 0) - 8, (yHorizon0 + yGlobe) / 2 - 7));
    }

    // Crosshair (aim the center at the visible horizon).
    final Paint cross = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(
        Offset(size.width / 2 - 22, center), Offset(size.width / 2 - 8, center), cross);
    canvas.drawLine(Offset(size.width / 2 + 8, center),
        Offset(size.width / 2 + 22, center), cross);
    canvas.drawCircle(Offset(size.width / 2, center), 4, cross..style = PaintingStyle.stroke);

    // Legend.
    _legend(canvas, size, 'green: 0° true horizontal (EKF pitch)',
        Offset(12, yHorizon0.clamp(20, size.height - 90).toDouble()));
    _legend(canvas, size, 'cyan: globe prediction θ = 1.06′·√h',
        Offset(12, yGlobe.clamp(20, size.height - 60).toDouble()));

    if (!hasFix) {
      labelTp.text = const TextSpan(
        text: 'waiting for EKF altitude fix…',
        style: TextStyle(color: Colors.orangeAccent, fontSize: 13),
      );
      labelTp.layout();
      labelTp.paint(canvas, Offset(size.width / 2 - (labelTp.width ?? 0) / 2, 70));
    }
  }

  void _legend(Canvas canvas, Size size, String text, Offset at) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  PathEffect _dashPathEffect() => PathEffect.dash(const <double>[10, 8], 0);

  @override
  bool shouldRepaint(_HorizonDipHudPainter oldDelegate) =>
      oldDelegate.boresightElevationDeg != boresightElevationDeg ||
      oldDelegate.predictedDipArcmin != predictedDipArcmin;
}
