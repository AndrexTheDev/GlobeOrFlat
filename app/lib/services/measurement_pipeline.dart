// ============================================================================
// GlobeOrFlat — Measurement Pipeline
// SPDX-License-Identifier: MIT
//
// Shared helper for all four measurement modes: builds the backend payload
// (ordered keys, backend zod schema-compatible), appends the raw sensor CSV
// to the offline queue and triggers an immediate sync drain.
//
// Mode-specific context (sync codes, solar data, occlusion figures) rides in
// the CSV header as `# key=value` comments — the backend schema ignores
// unknown payload keys, and the raw dump is the permanent record anyway.
// ============================================================================

import 'dart:convert' show jsonEncode, utf8;

import 'sensor_fusion_service.dart';
import 'offline_db_service.dart';
import 'sync_manager.dart';

class MeasurementPipeline {
  final SyncManager sync;

  MeasurementPipeline(this.sync);

  /// Queues a finished measurement and returns its UUID.
  Future<String> enqueueMeasurement({
    required MeasurementMode mode,
    required double gpsLat,
    required double gpsLon,
    required double altitudeM,
    double? curvatureDeviationPercentage,
    required int capturedAtMs,
    required String rawCsv,
    Map<String, Object?> extraPayload = const <String, Object?>{},
  }) async {
    final String deviceId = await OfflineDbService.instance.ensureDeviceId();

    // Key order matters for stable signing (jsonEncode preserves insertion
    // order; the sync manager refreshes `signed_at` right before signing).
    final Map<String, Object?> payload = <String, Object?>{
      'device_id': deviceId, // re-set by SyncManager (single source of truth)
      'mode': mode.wireName,
      'timestamp': capturedAtMs,
      'signed_at': 0, // refreshed by SyncManager
      'gps_lat': gpsLat,
      'gps_lon': gpsLon,
      'altitude_m': double.parse(altitudeM.toStringAsFixed(3)),
      if (curvatureDeviationPercentage != null)
        'curvature_deviation_percentage':
            double.parse(curvatureDeviationPercentage.toStringAsFixed(4)),
      ...extraPayload,
    };

    return OfflineDbService.instance.enqueueMeasurement(
      deviceId: deviceId,
      mode: mode.wireName,
      payloadJson: jsonEncode(payload),
      rawCsv: rawCsv,
      csvSha256: KeystoreService.sha256HexOfBytes(utf8.encode(rawCsv)),
    );
  }

  /// Convenience: enqueue then trigger an immediate drain (no-op if offline).
  Future<String> enqueueAndSync({
    required MeasurementMode mode,
    required double gpsLat,
    required double gpsLon,
    required double altitudeM,
    double? curvatureDeviationPercentage,
    required int capturedAtMs,
    required String rawCsv,
    Map<String, Object?> extraPayload = const <String, Object?>{},
  }) async {
    final String uuid = await enqueueMeasurement(
      mode: mode,
      gpsLat: gpsLat,
      gpsLon: gpsLon,
      altitudeM: altitudeM,
      curvatureDeviationPercentage: curvatureDeviationPercentage,
      capturedAtMs: capturedAtMs,
      rawCsv: rawCsv,
      extraPayload: extraPayload,
    );
    await sync.drain();
    return uuid;
  }
}
