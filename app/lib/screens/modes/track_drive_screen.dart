// ============================================================================
// GlobeOrFlat — Mode C: "Track & Curve Drive" (Trip Recorder)
// SPDX-License-Identifier: MIT
//
// Records a drive/bike ride and samples the EKF-fused altitude every 100 m
// of accumulated ground distance. The live graph overlays:
//
//   • white points  — measured elevation profile (EKF baro⊕GNSS, relative
//                     to the first sample)
//   • cyan dashed   — Globe curvature arc: −0.0785·s² below the tangent
//   • green solid   — Flat plane reference (constant elevation)
//
// The recorded curvature_deviation_percentage compares RMS residuals of the
// measured profile against both models:
//   dev% = 100·(rms_flat − rms_globe)/(rms_flat + rms_globe)
// (negative ⇒ globe arc fits better, positive ⇒ flat fits better).
// ============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathEffect;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../physics/earth_curvature.dart';
import '../../services/measurement_pipeline.dart';
import '../../services/sensor_fusion_service.dart';
import '../../services/sync_manager.dart';

/// Sample the profile every [kSampleEveryMeters] of accumulated distance.
const double kSampleEveryMeters = 100.0;

class TripPoint {
  final double distanceKm;
  final double fusedAltitudeM;
  final double? gpsAltitudeM;
  final int atMs;

  const TripPoint({
    required this.distanceKm,
    required this.fusedAltitudeM,
    required this.gpsAltitudeM,
    required this.atMs,
  });
}

class TrackDriveScreen extends StatefulWidget {
  const TrackDriveScreen({super.key, required this.sync});

  final SyncManager sync;

  @override
  State<TrackDriveScreen> createState() => _TrackDriveScreenState();
}

class _TrackDriveScreenState extends State<TrackDriveScreen> {
  final SensorFusionService _fusion = SensorFusionService();
  StreamSubscription<Position>? _positionSub;

  bool _recording = false;
  bool _busy = false;
  String? _error;
  String? _resultMessage;

  final List<TripPoint> _points = <TripPoint>[];
  double _distanceM = 0;
  double? _lastLat;
  double? _lastLon;
  Position? _lastFix;
  FusedSample? _lastSample;

  @override
  void initState() {
    super.initState();
    _fusion.samples.listen((FusedSample s) {
      if (mounted) {
        setState(() => _lastSample = s);
      }
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
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

  Future<void> _startRecording() async {
    try {
      setState(() {
        _points.clear();
        _distanceM = 0;
        _lastLat = null;
        _lastLon = null;
        _resultMessage = null;
        _error = null;
      });
      await _fusion.start(MeasurementMode.trackDrive);

      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 10, // m — dense fixes for smooth distance accumulation
        ),
      ).listen(_onPosition, onError: (Object e) {
        if (mounted) {
          setState(() => _error = 'GPS stream error: $e');
        }
      });

      setState(() => _recording = true);
    } on SensorPermissionException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } on StateError catch (_) {
      // already running
    }
  }

  void _onPosition(Position pos) {
    if (!_recording) return;
    _lastFix = pos;
    if (_lastLat != null && _lastLon != null) {
      final double delta =
          Geolocator.distanceBetween(_lastLat!, _lastLon!, pos.latitude, pos.longitude);
      // Ignore GPS jumps larger than a plausible fix-to-fix distance.
      if (delta < 0 || delta > 500) return;
      _distanceM += delta;
    }
    _lastLat = pos.latitude;
    _lastLon = pos.longitude;

    final FusedSample? sample = _lastSample;
    if (sample != null && _distanceM >= _points.length * kSampleEveryMeters) {
      _points.add(TripPoint(
        distanceKm: _distanceM / 1000.0,
        fusedAltitudeM: sample.altitude,
        gpsAltitudeM: sample.gpsAltitude,
        atMs: sample.timestampMs,
      ));
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _stopRecording() async {
    if (_busy || !_recording) return;
    setState(() => _busy = true);
    try {
      _positionSub?.cancel();
      _positionSub = null;

      final SessionResult result = await _fusion.stop();
      final Position? pos = result.lastPosition ?? _lastFix;
      if (pos == null || _points.length < 3) {
        if (mounted) {
          setState(() {
            _recording = false;
            _error = _points.length < 3
                ? 'Trip too short — need at least 3 samples (300 m).'
                : 'No GPS fix — cannot record trip.';
          });
        }
        return;
      }

      // Relative profile (first sample = reference altitude).
      final double refAlt = _points.first.fusedAltitudeM;
      final double flatRms = _rms(_points
          .map((TripPoint p) => p.fusedAltitudeM - refAlt)
          .toList(growable: false));
      final double globeRms = _rms(_points
          .map((TripPoint p) =>
              (p.fusedAltitudeM - refAlt) +
              curvatureDropMeters(p.distanceKm)) // measured − (−drop)
          .toList(growable: false));
      final double? deviation =
          rmsDeviationPercent(rmsResidualFlat: flatRms, rmsResidualGlobe: globeRms);

      final StringBuffer csv = StringBuffer(result.log.csv);
      csv.writeln('# track_drive,points=${_points.length}');
      csv.writeln('# track_drive,distance_km=${(_distanceM / 1000).toStringAsFixed(3)}');
      csv.writeln('# track_drive,rms_vs_flat_m=${flatRms.toStringAsFixed(4)}');
      csv.writeln('# track_drive,rms_vs_globe_m=${globeRms.toStringAsFixed(4)}');
      if (deviation != null) {
        csv.writeln('# track_drive,deviation_pct=${deviation.toStringAsFixed(4)}');
      }
      csv.writeln('# track_drive,columns=d_km,fused_alt_m,gps_alt_m');
      for (final TripPoint p in _points) {
        csv.writeln('# track_point,${p.distanceKm.toStringAsFixed(4)},'
            '${p.fusedAltitudeM.toStringAsFixed(3)},'
            '${p.gpsAltitudeM?.toStringAsFixed(2) ?? ''}');
      }

      await MeasurementPipeline(widget.sync).enqueueAndSync(
        mode: MeasurementMode.trackDrive,
        gpsLat: pos.latitude,
        gpsLon: pos.longitude,
        altitudeM: math.max(refAlt, 0),
        curvatureDeviationPercentage: deviation,
        capturedAtMs: result.endedAtMs,
        rawCsv: csv.toString(),
      );

      if (mounted) {
        setState(() {
          _recording = false;
          _resultMessage = 'Trip queued: ${(_distanceM / 1000).toStringAsFixed(2)} km, '
              '${_points.length} samples · rms flat ${flatRms.toStringAsFixed(2)} m '
              'vs globe ${globeRms.toStringAsFixed(2)} m';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  static double _rms(List<double> xs) {
    if (xs.isEmpty) return 0;
    double acc = 0;
    for (final double x in xs) {
      acc += x * x;
    }
    return math.sqrt(acc / xs.length);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1320),
      appBar: AppBar(
        title: const Text('Mode C · Track & Curve Drive'),
        backgroundColor: Colors.black54,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Card(
                color: const Color(0xFF102A43),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            _recording ? Icons.radio_button_checked : Icons.radio_button_off,
                            color: _recording ? Colors.redAccent : Colors.white24,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _recording ? 'RECORDING' : 'idle',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const Spacer(),
                          Text(
                            '${(_distanceM / 1000).toStringAsFixed(2)} km',
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${_points.length} profile samples (every ${kSampleEveryMeters.round()} m)'
                        '${_lastSample == null ? '' : ' · alt ${_lastSample!.altitude.toStringAsFixed(1)} m (EKF)'}',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  color: const Color(0xFF071018),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: CustomPaint(
                      painter: _ElevationGraphPainter(points: _points),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                ),
              if (_resultMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_resultMessage!,
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                ),
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _recording ? Colors.redAccent : Colors.tealAccent,
                    foregroundColor: _recording ? Colors.white : Colors.black,
                  ),
                  onPressed: _busy
                      ? null
                      : (_recording ? _stopRecording : _startRecording),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(_recording ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _busy
                        ? 'Saving…'
                        : _recording
                            ? 'Stop & queue trip'
                            : 'Start trip recording',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Live elevation graph
// ---------------------------------------------------------------------------

class _ElevationGraphPainter extends CustomPainter {
  _ElevationGraphPainter({required this.points});

  final List<TripPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    const double padLeft = 38, padRight = 10, padTop = 12, padBottom = 22;
    final double w = size.width - padLeft - padRight;
    final double h = size.height - padTop - padBottom;
    if (w <= 0 || h <= 0) return;

    final TextPainter tp = TextPainter(textDirection: TextDirection.ltr);
    void label(String text, Offset at, Color color,
        {double fontSize = 10, bool bold = false}) {
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400),
      );
      tp.layout();
      tp.paint(canvas, at);
    }

    // --- vertical range over all three series
    double maxDistKm = 0.5;
    double yMin = -1.0, yMax = 1.0;
    for (final TripPoint p in points) {
      if (p.distanceKm > maxDistKm) maxDistKm = p.distanceKm;
      final double rel = p.fusedAltitudeM - points.first.fusedAltitudeM;
      final double globe = -curvatureDropMeters(p.distanceKm);
      yMin = math.min(yMin, math.min(rel, globe));
      yMax = math.max(yMax, math.max(rel, globe));
    }
    // At least the globe arc of the full x-range into view.
    yMin = math.min(yMin, -curvatureDropMeters(maxDistKm));
    final double span = (yMax - yMin).abs() < 1e-6 ? 1.0 : (yMax - yMin);
    yMin -= span * 0.08;
    yMax += span * 0.08;

    Offset xy(double distKm, double elevM) => Offset(
          padLeft + (distKm / maxDistKm) * w,
          padTop + (1 - (elevM - yMin) / (yMax - yMin)) * h,
        );

    // --- grid + y labels
    final Paint grid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;
    for (int i = 0; i <= 4; i++) {
      final double yy = padTop + h * i / 4;
      canvas.drawLine(Offset(padLeft, yy), Offset(padLeft + w, yy), grid);
      final double value = yMax - (yMax - yMin) * i / 4;
      label(value.toStringAsFixed(0), Offset(4, yy - 6), Colors.white24);
    }

    // --- FLAT plane (reference, 0 m)
    final Paint flat = Paint()
      ..color = const Color(0xFF4CFF87)
      ..strokeWidth = 2;
    canvas.drawLine(xy(0, 0), xy(maxDistKm, 0), flat);

    // --- GLOBE arc (−0.0785·s²)
    final Paint globe = Paint()
      ..color = const Color(0xFF18E0FF)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final Path globePath = Path();
    for (double s = 0; s <= maxDistKm + 1e-9; s += maxDistKm / 80) {
      final Offset p = xy(s, -curvatureDropMeters(s));
      if (s == 0) {
        globePath.moveTo(p.dx, p.dy);
      } else {
        globePath.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(globePath, globe..pathEffect = PathEffect.dash(const <double>[9, 7], 0));

    // --- MEASURED profile (points + polyline)
    if (points.isNotEmpty) {
      final Paint line = Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final Path path = Path();
      final Paint dot = Paint()..color = Colors.white;
      bool first = true;
      for (final TripPoint p in points) {
        final Offset o = xy(p.distanceKm, p.fusedAltitudeM - points.first.fusedAltitudeM);
        if (first) {
          path.moveTo(o.dx, o.dy);
          first = false;
        } else {
          path.lineTo(o.dx, o.dy);
        }
        canvas.drawCircle(o, 3, dot);
      }
      canvas.drawPath(path, line);
    }

    // --- legend
    label('measured (EKF)', Offset(padLeft + 8, padTop + 2), Colors.white, bold: true);
    label('globe arc −0.0785·s²', Offset(padLeft + 8, padTop + 16),
        const Color(0xFF18E0FF));
    label('flat plane', Offset(padLeft + 8, padTop + 30), const Color(0xFF4CFF87));
    label('distance (km)', Offset(size.width - 96, size.height - 14), Colors.white24);
  }

  @override
  bool shouldRepaint(_ElevationGraphPainter old) =>
      old.points.length != points.length;
}
