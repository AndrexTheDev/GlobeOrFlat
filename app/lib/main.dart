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

import 'package:flutter/material.dart';

import 'screens/calibration_screen.dart';
import 'screens/modes/eratosthenes_screen.dart';
import 'screens/modes/horizon_dip_screen.dart';
import 'screens/modes/track_drive_screen.dart';
import 'screens/modes/water_sightline_screen.dart';
import 'services/calibration_service.dart';
import 'services/keystore_service.dart';
import 'services/offline_db_service.dart';
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
              builder: (BuildContext _) =>
                  _HomeDashboard(sync: _sync, keystore: _keystore),
            ),
          );
        },
      );
    }
    return _HomeDashboard(sync: _sync, keystore: _keystore);
  }
}

// ---------------------------------------------------------------------------
// Home dashboard: sync status + the four measurement modes
// ---------------------------------------------------------------------------

class _HomeDashboard extends StatelessWidget {
  const _HomeDashboard({required this.sync, required this.keystore});

  final SyncManager sync;
  final KeystoreService keystore;

  Future<void> _openMode(BuildContext context, Widget screen) async {
    await Navigator.of(context).push(
      MaterialPageRoute<Widget>(builder: (BuildContext _) => screen),
    );
  }

  Future<void> _recalibrate(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<Widget>(
        builder: (BuildContext _) => CalibrationScreen(
          onCalibrated: (CalibrationResult result) {
            CalibrationStorage().save(result);
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Recalibration saved')),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GlobeOrFlat'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Recalibrate sensors',
            icon: const Icon(Icons.tune),
            onPressed: () => _recalibrate(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _SyncStatusCard(sync: sync),
            const SizedBox(height: 16),
            const Text(
              'Measurement modes',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.25,
                children: <Widget>[
                  _modeCard(
                    context,
                    icon: Icons.waves,
                    color: const Color(0xFF18E0FF),
                    title: 'Horizon Dip',
                    subtitle: 'AR HUD · θ = 1.06′·√h',
                    screen: HorizonDipScreen(sync: sync),
                  ),
                  _modeCard(
                    context,
                    icon: Icons.sailing,
                    color: const Color(0xFFFF6B61),
                    title: 'Water Sightline',
                    subtitle: 'occlusion over water',
                    screen: WaterSightlineScreen(sync: sync),
                  ),
                  _modeCard(
                    context,
                    icon: Icons.directions_car,
                    color: const Color(0xFF4CFF87),
                    title: 'Track & Curve',
                    subtitle: 'drive profile · 0.0785·s²',
                    screen: TrackDriveScreen(sync: sync),
                  ),
                  _modeCard(
                    context,
                    icon: Icons.wb_sunny,
                    color: const Color(0xFFFFC843),
                    title: 'Eratosthenes',
                    subtitle: 'P2P shadow sync',
                    screen: EratosthenesScreen(sync: sync),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeCard(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required Widget screen,
  }) {
    return Card(
      color: const Color(0xFF102A43),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openMode(context, screen),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, color: color, size: 30),
              const Spacer(),
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(subtitle,
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SyncStatusCard extends StatelessWidget {
  const _SyncStatusCard({required this.sync});

  final SyncManager sync;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncState>(
      stream: sync.state,
      initialData: sync.currentState,
      builder: (BuildContext context, AsyncSnapshot<SyncState> snap) {
        final SyncState s = snap.data ?? sync.currentState;
        return Card(
          color: const Color(0xFF102A43),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                Icon(
                  s.syncing
                      ? Icons.sync
                      : (s.online ? Icons.cloud_done : Icons.cloud_off),
                  size: 18,
                  color: s.syncing
                      ? Colors.orangeAccent
                      : (s.online ? Colors.greenAccent : Colors.white38),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    s.syncing
                        ? 'Syncing measurements…'
                        : s.online
                            ? 'Online — ${s.pendingCount} pending'
                            : 'Offline — ${s.pendingCount} queued locally',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (s.lastError != null)
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: Colors.orangeAccent),
              ],
            ),
          ),
        );
      },
    );
  }
}
