// ============================================================================
// GlobeOrFlat — Mode D: "Eratosthenes Synchro" (P2P shadow measurement)
// SPDX-License-Identifier: MIT
//
// The 240 BC experiment, app-guided:
//   1. App computes LOCAL SOLAR NOON for the device's GPS position
//      (Noon_UTC = 12:00 − EoT − 4·lon) and counts down to it.
//   2. At solar noon the user stands a 10 cm stick vertically (screen plumb
//      line as guide) and measures its shadow ON SCREEN with draggable
//      calipers — first on the stick itself (pixel calibration), then on the
//      shadow. The ratio is dimensionless, so no absolute pixel scale is
//      needed:  elevation = atan(1 / (shadow/stick)).
//   3. A 6-digit SYNC CODE is generated per measurement; a partner elsewhere
//      (different latitude, same-day solar noon) enters it into their app,
//      and both raw dumps carry both codes — the classical two-site
//      Eratosthenes pair, ready for researchers to combine.
// ============================================================================

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../../physics/earth_curvature.dart';
import '../../physics/solar_position.dart';
import '../../services/measurement_pipeline.dart';
import '../../services/sensor_fusion_service.dart';
import '../../services/sync_manager.dart';
import '../../widgets/ar_camera_view.dart';

/// The classic stick height [cm] — fixed by protocol so pairs are comparable.
const double kStickHeightCm = 10.0;

/// ± window around solar noon considered "simultaneous enough" [min].
const int kSolarNoonWindowMin = 15;

class EratosthenesScreen extends StatefulWidget {
  const EratosthenesScreen({super.key, required this.sync});

  final SyncManager sync;

  @override
  State<EratosthenesScreen> createState() => _EratosthenesScreenState();
}

class _EratosthenesScreenState extends State<EratosthenesScreen> {
  final SensorFusionService _fusion = SensorFusionService();
  final TextEditingController _partnerCodeCtrl = TextEditingController();

  Position? _position;
  DateTime? _solarNoon;
  String? _error;
  bool _busy = false;

  // Caliper positions as fractions of the camera-view height.
  double _stickTopY = 0.30;
  double _stickBottomY = 0.55;
  double _shadowTopY = 0.30;
  double _shadowBottomY = 0.55;

  /// 6-digit pairing code generated for THIS measurement.
  late final String syncCode = _generateSyncCode();

  @override
  void initState() {
    super.initState();
    _beginSession();
  }

  @override
  void dispose() {
    _safeStop();
    _partnerCodeCtrl.dispose();
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

  static String _generateSyncCode() {
    final math.Random rng = math.Random.secure();
    return (rng.nextInt(1000000)).toString().padLeft(6, '0');
  }

  Future<void> _beginSession() async {
    try {
      _fusion.samples.listen((FusedSample _) {
        // Fusion runs for the raw log + GPS tagging; UI does not need samples.
      });
      await _fusion.start(MeasurementMode.eratosthenes);
      final Position pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      ).timeout(const Duration(seconds: 25));
      if (!mounted) return;
      setState(() {
        _position = pos;
        _solarNoon = solarNoonUtc(
          dateUtc: DateTime.now().toUtc(),
          longitudeDeg: pos.longitude,
        );
      });
    } on SensorPermissionException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } on TimeoutException {
      if (mounted) {
        setState(() => _error =
            'No GPS fix yet — solar noon needs your longitude. Retry outdoors.');
      }
    } on StateError catch (_) {
      // already running
    }
  }

  double get _stickPx {
    final double d = _stickBottomY - _stickTopY;
    return d > 0.01 ? d : 0.01; // guard against degenerate calipers
  }

  double get _shadowPx {
    final double d = _shadowBottomY - _shadowTopY;
    return d > 0.005 ? d : 0.005;
  }

  double get _shadowOverStick => _shadowPx / _stickPx;
  double get _shadowCm => kStickHeightCm * _shadowOverStick;
  double get _sunElevationDeg => elevationFromShadowRatio(_shadowOverStick);

  bool get _nearSolarNoon {
    final DateTime? noon = _solarNoon;
    if (noon == null) return false;
    final int diffMin =
        DateTime.now().toUtc().difference(noon).inMinutes.abs();
    return diffMin <= kSolarNoonWindowMin;
  }

  Future<void> _capture() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final SessionResult result = await _fusion.stop();
      final Position? pos = result.lastPosition ?? _position;
      if (pos == null) {
        if (mounted) {
          setState(() => _error = 'No GPS fix — latitude is required for an '
              'Eratosthenes pair.');
        }
        await _beginSession();
        return;
      }

      final DateTime nowUtc = DateTime.now().toUtc();
      final DateTime noon =
          _solarNoon ?? solarNoonUtc(dateUtc: nowUtc, longitudeDeg: pos.longitude);
      final double noonElevation = 90.0 -
          (pos.latitude - radiansToDegrees(solarDeclinationRadians(noon))).abs();

      final StringBuffer csv = StringBuffer(result.log.csv);
      csv.writeln('# eratosthenes,stick_cm=${kStickHeightCm.toStringAsFixed(1)}');
      csv.writeln('# eratosthenes,shadow_cm=${_shadowCm.toStringAsFixed(3)}');
      csv.writeln('# eratosthenes,shadow_over_stick=${_shadowOverStick.toStringAsFixed(5)}');
      csv.writeln('# eratosthenes,sun_elevation_deg=${_sunElevationDeg.toStringAsFixed(4)}');
      csv.writeln('# eratosthenes,solar_noon_utc=${noon.toIso8601String()}');
      csv.writeln('# eratosthenes,solar_noon_elevation_deg=${noonElevation.toStringAsFixed(3)}');
      csv.writeln('# eratosthenes,sync_code=$syncCode');
      csv.writeln('# eratosthenes,partner_code=${_partnerCodeCtrl.text.trim()}');

      await MeasurementPipeline(widget.sync).enqueueAndSync(
        mode: MeasurementMode.eratosthenes,
        gpsLat: pos.latitude,
        gpsLon: pos.longitude,
        altitudeM: math.max(result.meanFusedAltitude, 0),
        curvatureDeviationPercentage: null, // needs the paired site
        capturedAtMs: result.endedAtMs,
        rawCsv: csv.toString(),
        extraPayload: <String, Object?>{
          'eratosthenes_sync_code': syncCode,
          'eratosthenes_partner_code': _partnerCodeCtrl.text.trim(),
          'eratosthenes_shadow_cm': double.parse(_shadowCm.toStringAsFixed(3)),
          'eratosthenes_solar_noon_utc': noon.toIso8601String(),
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF102A43),
            content: Text(
                'Shadow measurement queued · share code $syncCode with your partner'),
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
        title: const Text('Mode D · Eratosthenes Synchro'),
        backgroundColor: Colors.black54,
      ),
      body: Column(
        children: <Widget>[
          _solarCard(),
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _beginSession,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : ArCameraView(overlayBuilder: _buildCaliperOverlay),
          ),
          _controlsCard(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _capture,
        icon: _busy
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.wb_sunny),
        label: const Text('Record shadow'),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Solar noon card
  // -------------------------------------------------------------------------

  Widget _solarCard() {
    final DateTime? noon = _solarNoon;
    return Container(
      color: const Color(0xFF102A43),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: noon == null
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: <Widget>[
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('Locating for solar noon…',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            )
          : Row(
              children: <Widget>[
                Icon(
                  _nearSolarNoon ? Icons.wb_sunny : Icons.schedule,
                  color: _nearSolarNoon ? Colors.orangeAccent : Colors.white54,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Local solar noon ${formatHm(noon.toLocal())} '
                        '(${kSolarNoonWindowMin} min window)',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _countdownText(noon),
                        style: TextStyle(
                          fontSize: 11,
                          color: _nearSolarNoon
                              ? Colors.orangeAccent
                              : Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
                Builder(builder: (BuildContext ctx) {
                  final double elev = solarElevationDegrees(
                    utc: DateTime.now().toUtc(),
                    latitudeDeg: _position?.latitude ?? 0,
                    longitudeDeg: _position?.longitude ?? 0,
                  );
                  final double? shadow = shadowLengthCm(
                    stickCm: kStickHeightCm,
                    elevationDeg: elev,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text('elev ${elev.toStringAsFixed(1)}°',
                          style: const TextStyle(fontSize: 12)),
                      Text(
                        'shadow ≈ ${shadow?.toStringAsFixed(1) ?? '∞'} cm',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54),
                      ),
                    ],
                  );
                }),
              ],
            ),
    );
  }

  String _countdownText(DateTime noonUtc) {
    final Duration d = noonUtc.difference(DateTime.now().toUtc());
    final int minutes = d.inMinutes.abs();
    if (d.isNegative) {
      return '$minutes min after solar noon';
    }
    return 'in ${d.inHours}h ${(minutes % 60).toString().padLeft(2, '0')}m';
  }

  // -------------------------------------------------------------------------
  // Caliper overlay (drag the pairs onto the stick, then onto the shadow)
  // -------------------------------------------------------------------------

  Widget _buildCaliperOverlay(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double height = c.maxHeight;
        Widget caliper(
          double y,
          Color color,
          String tag,
          ValueChanged<DragUpdateDetails> onDrag,
        ) {
          return Positioned(
            left: 0,
            right: 0,
            top: (y * height - 18).clamp(0.0, height - 36).toDouble(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: onDrag,
              child: Container(
                height: 36,
                color: Colors.transparent,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Container(height: 2, color: color),
                    Text(tag,
                        style: TextStyle(
                            color: color,
                            fontSize: 9,
                            backgroundColor: Colors.black38)),
                  ],
                ),
              ),
            ),
          );
        }

        return Stack(
          children: <Widget>[
            // Plumb line guide for holding the stick vertical.
            Center(
              child: Container(
                width: 1.5,
                color: Colors.white24,
              ),
            ),
            caliper(
              _stickTopY,
              Colors.white,
              'stick top',
              (DragUpdateDetails d) => setState(
                  () => _stickTopY = (_stickTopY + d.delta.dy / height).clamp(0.0, 0.95).toDouble()),
            ),
            caliper(
              _stickBottomY,
              Colors.white,
              'stick base',
              (DragUpdateDetails d) => setState(
                  () => _stickBottomY =
                      (_stickBottomY + d.delta.dy / height).clamp(0.05, 1.0).toDouble()),
            ),
            caliper(
              _shadowTopY,
              Colors.orangeAccent,
              'shadow tip',
              (DragUpdateDetails d) => setState(
                  () => _shadowTopY = (_shadowTopY + d.delta.dy / height).clamp(0.0, 0.95).toDouble()),
            ),
            caliper(
              _shadowBottomY,
              Colors.orangeAccent,
              'shadow end',
              (DragUpdateDetails d) => setState(
                  () => _shadowBottomY =
                      (_shadowBottomY + d.delta.dy / height).clamp(0.05, 1.0).toDouble()),
            ),
            Positioned(
              top: 8,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                color: Colors.black38,
                child: const Text(
                  'drag WHITE lines onto the 10 cm stick,\n'
                  'ORANGE lines onto its shadow',
                  style: TextStyle(color: Colors.white70, fontSize: 11, height: 1.3),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Results + pairing controls
  // -------------------------------------------------------------------------

  Widget _controlsCard() {
    return Container(
      color: const Color(0xE60B1320),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                _stat('shadow', '${_shadowCm.toStringAsFixed(1)} cm'),
                _stat('stick', '${kStickHeightCm.toStringAsFixed(0)} cm'),
                _stat('sun elev', '${_sunElevationDeg.toStringAsFixed(1)}°'),
                _stat('sync code', syncCode, highlight: true),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _partnerCodeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              style: const TextStyle(color: Colors.white, letterSpacing: 4),
              decoration: const InputDecoration(
                labelText: "partner's sync code (optional)",
                labelStyle: TextStyle(color: Colors.white38, fontSize: 12),
                counterText: '',
                isDense: true,
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {bool highlight = false}) {
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
          Text(
            value,
            style: TextStyle(
              color: highlight ? Colors.orangeAccent : Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: highlight ? 2 : 0,
            ),
          ),
        ],
      ),
    );
  }
}
