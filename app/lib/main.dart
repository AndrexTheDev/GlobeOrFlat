// ============================================================================
// GlobeOrFlat — Flutter client entrypoint
// SPDX-License-Identifier: MIT
//
// Boot order matters:
//   1. OfflineDbService.open()           — local queue + device id
//   2. KeystoreService.ensureKeyPair()   — hardware-backed ECDSA identity
//   3. Calibration gate                  — no measurements until calibrated
//   4. SyncManager.start()               — drains queue whenever online
// ============================================================================

import 'dart:convert' show jsonEncode, utf8;

import 'package:flutter/material.dart';

import 'screens/calibration_screen.dart';
import 'services/calibration_service.dart';
import 'services/keystore_service.dart';
import 'services/offline_db_service.dart';
import 'services/sensor_fusion_service.dart';
import 'services/sync_manager.dart';

/// Point this at your deployed worker (see backend README).
const String kApiBaseUrl = String.fromEnvironment(
  'GOF_API_BASE_URL',
  defaultValue: 'https://globeorflat-api.example.workers.dev',
);

/// Shared with the app build (see backend README — CLIENT_INGEST_TOKEN).
const String kIngestToken = String.fromEnvironment(
  'GOF_INGEST_TOKEN',
  defaultValue: 'local-dev-ingest-token',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OfflineDbService.instance.open();
  await OfflineDbService.instance.ensureDeviceId();
  runApp(const GlobeOrFlatApp());
}

class GlobeOrFlatApp extends StatelessWidget {
  const GlobeOrFlatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GlobeOrFlat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const _BootGate(),
    );
  }
}

/// Waits for the stored calibration, then enforces the calibration gate.
class _BootGate extends StatefulWidget {
  const _BootGate();

  @override
  State<_BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<_BootGate> {
  final KeystoreService _keystore = KeystoreService();
  late final SyncManager _sync = SyncManager(
    baseUrl: kApiBaseUrl,
    ingestToken: kIngestToken,
    keystore: _keystore,
  );

  CalibrationResult? _calibration;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final CalibrationStorage storage = CalibrationStorage();
    final CalibrationResult? stored = await storage.load();
    if (!mounted) return;
    setState(() {
      _calibration = stored;
      _loaded = true;
    });
    if (stored != null) {
      await _startSync();
    }
  }

  Future<void> _startSync() async {
    // The measurement home re-applies the stored calibration to its own
    // fusion service; here we only need the network layer running.
    await _sync.start();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final CalibrationResult? calibration = _calibration;
    if (calibration == null) {
      return CalibrationScreen(
        onCalibrated: (CalibrationResult result) {
          setState(() => _calibration = result);
          _startSync();
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<Widget>(
              builder: (BuildContext _) => _MeasurementHome(sync: _sync),
            ),
          );
        },
      );
    }
    return _MeasurementHome(sync: _sync);
  }
}

// ---------------------------------------------------------------------------
// Measurement home (deliberately minimal — the focus of this deliverable is
// the sensor fusion engine, signing, offline queue and calibration gate)
// ---------------------------------------------------------------------------

class _MeasurementHome extends StatefulWidget {
  const _MeasurementHome({required this.sync});

  final SyncManager sync;

  @override
  State<_MeasurementHome> createState() => _MeasurementHomeState();
}

class _MeasurementHomeState extends State<_MeasurementHome> {
  final SensorFusionService _fusion = SensorFusionService();
  MeasurementMode _mode = MeasurementMode.horizonDip;
  String _status = 'Idle';
  bool _measuring = false;
  FusedSample? _last;

  @override
  void initState() {
    super.initState();
    _fusion.samples.listen((FusedSample s) {
      if (mounted) {
        setState(() => _last = s);
      }
    });
  }

  Future<void> _start() async {
    try {
      _fusion.calibration = await CalibrationStorage().load();
      await _fusion.start(_mode);
      setState(() {
        _measuring = true;
        _status = 'Measuring ${_mode.wireName}…';
      });
    } on SensorPermissionException catch (e) {
      setState(() => _status = e.message);
    } on StateError catch (e) {
      setState(() => _status = e.message);
    }
  }

  Future<void> _stopAndEnqueue() async {
    final SessionResult result = await _fusion.stop();
    if (result.lastPosition == null) {
      // The backend requires plausible coordinates; a 0/0 fallback would
      // poison researcher datasets, so we refuse to queue this session.
      setState(() {
        _measuring = false;
        _status =
            'No GPS fix was acquired — session not queued. Try again outdoors.';
      });
      return;
    }
    final String deviceId = await OfflineDbService.instance.ensureDeviceId();
    final String payloadJson = _buildPayloadJson(result, deviceId);
    final String csvSha256 =
        KeystoreService.sha256HexOfBytes(utf8.encode(result.log.csv));
    final String uuid = await OfflineDbService.instance.enqueueMeasurement(
      deviceId: deviceId,
      mode: result.mode.wireName,
      payloadJson: payloadJson,
      rawCsv: result.log.csv,
      csvSha256: csvSha256,
    );
    setState(() {
      _measuring = false;
      _status = 'Queued $uuid — waiting for connectivity';
    });
    await widget.sync.drain(); // if we are online this uploads immediately
  }

  String _buildPayloadJson(SessionResult r, String deviceId) {
    // Key order is preserved through sync (jsonDecode → jsonEncode keeps the
    // insertion order), and `signed_at` is refreshed at upload time there.
    final Map<String, dynamic> payload = <String, dynamic>{
      'device_id': deviceId,
      'mode': r.mode.wireName,
      'timestamp': r.startedAtMs,
      'signed_at': 0, // refreshed by SyncManager right before signing
      'gps_lat': r.lastPosition?.latitude ?? 0.0,
      'gps_lon': r.lastPosition?.longitude ?? 0.0,
      'altitude_m': double.parse(r.meanFusedAltitude.toStringAsFixed(3)),
    };
    return jsonEncode(payload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GlobeOrFlat')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            StreamBuilder<SyncState>(
              stream: widget.sync.state,
              initialData: widget.sync.currentState,
              builder: (BuildContext context, AsyncSnapshot<SyncState> snap) {
                final SyncState s = snap.data ?? widget.sync.currentState;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          s.syncing
                              ? 'Syncing…'
                              : s.online
                                  ? 'Online'
                                  : 'Offline — measurements queue locally',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text('${s.pendingCount} measurement(s) pending upload'),
                        if (s.lastError != null)
                          Text(
                            s.lastError!,
                            style: const TextStyle(
                                color: Colors.redAccent, fontSize: 12),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<MeasurementMode>(
              value: _mode,
              decoration: const InputDecoration(
                labelText: 'Experiment mode',
                border: OutlineInputBorder(),
              ),
              items: MeasurementMode.values
                  .map((MeasurementMode m) => DropdownMenuItem<MeasurementMode>(
                        value: m,
                        child: Text(m.wireName),
                      ))
                  .toList(),
              onChanged: _measuring
                  ? null
                  : (MeasurementMode? m) => setState(() => _mode = m!),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('Fused altitude (EKF: baro + GNSS)',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                      _last == null
                          ? '—'
                          : '${_last!.altitude.toStringAsFixed(2)} m'
                              '  (v=${_last!.verticalVelocity.toStringAsFixed(2)} m/s)',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      _last == null
                          ? 'waiting for sensors…'
                          : 'baro ${_last!.baroAltitude.toStringAsFixed(2)} m · '
                              'gnss ${_last!.gpsAltitude?.toStringAsFixed(2) ?? '—'} m · '
                              '${_last!.pressureHpa.toStringAsFixed(1)} hPa',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                icon: Icon(_measuring ? Icons.stop : Icons.play_arrow),
                label: Text(_measuring ? 'Stop & queue upload' : 'Start measurement'),
                onPressed: _measuring ? _stopAndEnqueue : _start,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
