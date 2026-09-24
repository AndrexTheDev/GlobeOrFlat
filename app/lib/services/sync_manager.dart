// ============================================================================
// GlobeOrFlat — Automatic Sync Manager
// SPDX-License-Identifier: MIT
//
// Drains the offline upload queue to the GlobeOrFlat Cloudflare Worker:
//
//   1. On startup: recovers stale IN_FLIGHT rows, listens to connectivity.
//   2. When connectivity is (re)gained → drain():
//        • ensure the device + Keystore public key are registered
//        • for each due record, in strict FIFO order:
//            – refresh `signed_at` in the payload (anti-replay freshness)
//            – sign the EXACT payload bytes with the Android Keystore key
//            – multipart-upload payload + raw CSV with GOFv1 headers
//            – 201 → synced · 409 → duplicate, counts as synced
//              4xx validation → permanent failure · 429/5xx/network → backoff
//   3. Periodic safety drain (backoff timer) while pending work exists.
//
// Uploads are idempotent server-side (UNIQUE signature_hash), so replays
// after a crash are harmless duplicates answered with 409.
// ============================================================================

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io' show SocketException;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import 'keystore_service.dart';
import 'offline_db_service.dart';

/// Live sync status for UI binding.
class SyncState {
  final bool online;
  final bool syncing;
  final int pendingCount;
  final String? lastError;
  final DateTime? at;

  const SyncState({
    required this.online,
    required this.syncing,
    required this.pendingCount,
    required this.lastError,
    required this.at,
  });
}

class SyncException implements Exception {
  final String message;
  SyncException(this.message);
  @override
  String toString() => 'SyncException: $message';
}

class SyncManager {
  SyncManager({
    required String baseUrl,
    required String ingestToken,
    required KeystoreService keystore,
    OfflineDbService? db,
    Connectivity? connectivity,
    http.Client? httpClient,
    this.batchSize = 5,
    this.retryScanInterval = const Duration(seconds: 30),
    this.uploadTimeout = const Duration(seconds: 30),
  })  : _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _ingestToken = ingestToken,
        _keystore = keystore,
        _db = db ?? OfflineDbService.instance,
        _connectivity = connectivity ?? Connectivity(),
        _client = httpClient ?? http.Client();

  final String _baseUrl;
  final String _ingestToken;
  final KeystoreService _keystore;
  final OfflineDbService _db;
  final Connectivity _connectivity;
  final http.Client _client;
  final int batchSize;
  final Duration retryScanInterval;
  final Duration uploadTimeout;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _retryTimer;
  bool _draining = false;
  bool _started = false;
  String? _deviceId;

  final StreamController<SyncState> _stateController =
      StreamController<SyncState>.broadcast();

  /// Broadcast stream of [SyncState] snapshots for the UI.
  Stream<SyncState> get state => _stateController.stream;

  SyncState _lastState =
      const SyncState(online: false, syncing: false, pendingCount: 0, lastError: null, at: null);

  /// Latest snapshot (non-stream accessor).
  SyncState get currentState => _lastState;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _deviceId = await _db.ensureDeviceId();
    await _db.recoverStaleInFlight();

    _connectivitySub = _connectivity.onConnectivityChanged.listen(
      (List<ConnectivityResult> results) async {
        if (_isConnected(results)) {
          await drain();
        }
      },
      onError: (Object e) {
        _emit(online: false, syncing: _draining, error: 'connectivity: $e');
      },
    );

    // Safety net: backoff timers, missed connectivity events, server hiccups.
    _retryTimer = Timer.periodic(retryScanInterval, (_) => drain());

    // Initial drain (app might start already online).
    await drain();
  }

  Future<void> stop() async {
    _started = false;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  // -------------------------------------------------------------------------
  // Drain loop
  // -------------------------------------------------------------------------

  Future<bool> isOnline() async {
    try {
      final List<ConnectivityResult> results =
          await _connectivity.checkConnectivity();
      return _isConnected(results);
    } on Exception {
      return false; // plugin unavailable — assume offline, stay safe
    }
  }

  bool _isConnected(List<ConnectivityResult> results) {
    return results.any((ConnectivityResult r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet ||
        r == ConnectivityResult.vpn);
  }

  /// Uploads everything currently due. Safe to call from anywhere;
  /// concurrent calls are coalesced.
  Future<void> drain() async {
    if (_draining || !_started) return;
    _draining = true;
    try {
      if (!await isOnline()) {
        await _emit(online: false, syncing: false);
        return;
      }
      await ensureDeviceRegistered();

      while (await isOnline()) {
        final List<QueuedMeasurement> batch =
            await _db.claimDueBatch(limit: batchSize);
        if (batch.isEmpty) break;

        bool stopBatch = false;
        for (final QueuedMeasurement m in batch) {
          try {
            final UploadResult result = await _uploadOne(m);
            switch (result.outcome) {
              case UploadOutcome.accepted:
              case UploadOutcome.duplicate:
                await _db.markSynced(m.id);
                break;
              case UploadOutcome.permanentFailure:
                await _db.markPermanentFailure(
                    m.id, result.detail ?? 'rejected by server');
                break;
              case UploadOutcome.retryLater:
                await _db.markRetry(m.id, result.detail ?? 'server unavailable');
                stopBatch = true; // server troubled — back off, try later
                break;
            }
          } on TimeoutException catch (e) {
            await _db.markRetry(m.id, 'timeout: ${e.message ?? ''}');
            stopBatch = true;
          } on SocketException catch (e) {
            await _db.markRetry(m.id, 'network: ${e.message}');
            stopBatch = true;
          } on http.ClientException catch (e) {
            await _db.markRetry(m.id, 'network: ${e.message}');
            stopBatch = true;
          } on SignatureException catch (e) {
            // Keystore trouble will not heal by retrying in a tight loop.
            await _db.markRetry(m.id, 'keystore: $e');
            stopBatch = true;
          }
          await _emit(online: true, syncing: true);
          if (stopBatch) break;
        }
        if (stopBatch) break;
      }
      await _emit(online: true, syncing: false);
    } on SyncException catch (e) {
      await _emit(online: true, syncing: false, error: e.message);
    } finally {
      _draining = false;
    }
  }

  // -------------------------------------------------------------------------
  // Registration + single upload
  // -------------------------------------------------------------------------

  /// Registers this device's Keystore public key exactly once
  /// (409 "already registered" counts as success — append-only ledger).
  Future<void> ensureDeviceRegistered() async {
    final String? registered = await _db.getMeta('device_registered');
    if (registered == '1') return;

    final String deviceId = await _resolveDeviceId();
    final String spki = await _keystore.ensureKeyPair();
    final SignedMeasurement signed = await _keystore.signDeviceRegistration(
      deviceId: deviceId,
      publicKeySpkiBase64: spki,
    );

    final http.Response response = await _client
        .post(
          Uri.parse('$_baseUrl$kRegisterPath'),
          headers: <String, String>{
            'authorization': 'Bearer $_ingestToken',
            'content-type': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{
            'device_id': deviceId,
            'key_version': 1,
            'public_key_spki': spki,
            'signed_at': signed.signedAtMs,
            'signature': signed.signatureBase64Der,
            'signature_format': 'der',
          }),
        )
        .timeout(uploadTimeout);

    if (response.statusCode == 201 || response.statusCode == 409) {
      await _db.setMeta('device_registered', '1');
      return;
    }
    throw SyncException(
        'Device registration failed (HTTP ${response.statusCode}): ${_clip(response.body)}');
  }

  Future<UploadResult> _uploadOne(QueuedMeasurement m) async {
    final String deviceId = await _resolveDeviceId();

    // Refresh signed_at: the backend enforces a ±5 min signature freshness
    // window at upload time, and queued records may be hours old.
    // jsonDecode → jsonEncode preserves key order, and the payload string we
    // hash is byte-identical to the payload part we upload.
    final Map<String, dynamic> payload =
        jsonDecode(m.payloadJson) as Map<String, dynamic>;
    payload['device_id'] = deviceId;
    payload['signed_at'] = DateTime.now().millisecondsSinceEpoch;
    final String payloadJson = jsonEncode(payload);

    final SignedMeasurement signed = await _keystore.signMeasurementPayload(
      payloadJson: payloadJson,
      deviceId: deviceId,
      signedAtMs: payload['signed_at'] as int,
    );

    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl$kUploadPath'),
    )
      ..headers['authorization'] = 'Bearer $_ingestToken'
      ..headers['x-gof-device-id'] = deviceId
      ..headers['x-gof-signature'] = signed.signatureBase64Der
      ..headers['x-gof-signature-format'] = 'der'
      ..files.add(http.MultipartFile.fromBytes(
        'payload',
        utf8.encode(signed.payloadJson),
        filename: 'payload.json',
      ))
      ..files.add(http.MultipartFile.fromString(
        'dump',
        m.rawCsv,
        filename: 'raw_sensors.csv',
        contentType: MediaType('text', 'csv'),
      ));

    final http.StreamedResponse response =
        await request.send().timeout(uploadTimeout);
    final String body = await response.stream.bytesToString();

    switch (response.statusCode) {
      case 201:
        return const UploadResult.accepted();
      case 409: // duplicate signature — the record is already on the server
        return const UploadResult.duplicate();
      case 400:
      case 401:
      case 403:
      case 413:
      case 415:
        // Validation/auth/size/type problems will not heal on retry.
        return UploadResult.permanentFailure(
            'HTTP ${response.statusCode}: ${_clip(body)}');
      default: // 409 replay-guard aside: 429, 5xx, …
        return UploadResult.retryLater(
            'HTTP ${response.statusCode}: ${_clip(body)}');
    }
  }

  Future<String> _resolveDeviceId() async {
    // Stable for the lifetime of the installation (persisted in app_meta).
    return _deviceId ??= await _db.ensureDeviceId();
  }

  Future<void> _emit({
    required bool online,
    required bool syncing,
    String? error,
  }) async {
    final int pending = await _db.pendingCount();
    _lastState = SyncState(
      online: online,
      syncing: syncing,
      pendingCount: pending,
      lastError: error,
      at: DateTime.now(),
    );
    if (!_stateController.isClosed) {
      _stateController.add(_lastState);
    }
  }

  static String _clip(String s) => s.length > 200 ? '${s.substring(0, 200)}…' : s;
}

/// Outcome classification for a single upload attempt.
class UploadResult {
  final UploadOutcome outcome;
  final String? detail;

  const UploadResult._(this.outcome, this.detail);

  const UploadResult.accepted() : this._(UploadOutcome.accepted, null);
  const UploadResult.duplicate() : this._(UploadOutcome.duplicate, null);
  const UploadResult.permanentFailure(String reason)
      : this._(UploadOutcome.permanentFailure, reason);
  const UploadResult.retryLater(String reason)
      : this._(UploadOutcome.retryLater, reason);
}

enum UploadOutcome { accepted, duplicate, permanentFailure, retryLater }
