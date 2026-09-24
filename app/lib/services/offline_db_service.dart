// ============================================================================
// GlobeOrFlat — Offline Local Database (sqflite) + Upload Queue
// SPDX-License-Identifier: MIT
//
// Stores measurement sessions locally while the device is offline and queues
// them for the SyncManager. Design notes:
//
//  * The measurement payload JSON and the raw CSV are written ONCE at enqueue
//    time and are never modified afterwards — the local queue mirrors the
//    server's append-only philosophy; only sync bookkeeping columns
//    (`status`, `attempts`, `next_attempt_at`, `last_error`) ever change.
//  * Uploads are idempotent server-side (UNIQUE signature_hash → 409 on
//    replay), so a crash between "uploaded" and "markSynced" can never
//    duplicate a record.
//  * Rows left IN_FLIGHT by a crash are reset to PENDING on next open.
// ============================================================================

import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Queue entry lifecycle.
enum QueueStatus { pending, inFlight, synced, failedPermanent }

String queueStatusToWire(QueueStatus s) {
  switch (s) {
    case QueueStatus.pending:
      return 'PENDING';
    case QueueStatus.inFlight:
      return 'IN_FLIGHT';
    case QueueStatus.synced:
      return 'SYNCED';
    case QueueStatus.failedPermanent:
      return 'FAILED_PERMANENT';
  }
}

QueueStatus queueStatusFromWire(String wire) =>
    QueueStatus.values.firstWhere((QueueStatus s) => queueStatusToWire(s) == wire);

/// A queued measurement awaiting upload.
class QueuedMeasurement {
  final int id;
  final String uuid;
  final String deviceId;
  final String mode;
  final String payloadJson;
  final String rawCsv;
  final String csvSha256;
  final int createdAtMs;
  final QueueStatus status;
  final int attempts;
  final int nextAttemptAtMs;
  final String? lastError;

  const QueuedMeasurement({
    required this.id,
    required this.uuid,
    required this.deviceId,
    required this.mode,
    required this.payloadJson,
    required this.rawCsv,
    required this.csvSha256,
    required this.createdAtMs,
    required this.status,
    required this.attempts,
    required this.nextAttemptAtMs,
    required this.lastError,
  });
}

/// RFC 4122 v4 UUID from a secure RNG (no external dependency).
String generateUuidV4() {
  final Random rng = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final String h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class OfflineDbService {
  OfflineDbService._();

  static final OfflineDbService instance = OfflineDbService._();

  Database? _db;

  Database get _requireDb {
    final Database? db = _db;
    if (db == null) {
      throw StateError('OfflineDbService.open() must be called before use.');
    }
    return db;
  }

  /// Opens (and migrates) the database. Safe to call multiple times.
  Future<void> open() async {
    if (_db != null) return;
    final dir = await getApplicationDocumentsDirectory();
    final Database db = await openDatabase(
      p.join(dir.path, 'globeorflat.db'),
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE measurement_queue (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid             TEXT NOT NULL UNIQUE,
            device_id        TEXT NOT NULL,
            mode             TEXT NOT NULL,
            payload_json     TEXT NOT NULL,
            raw_csv          TEXT NOT NULL,
            csv_sha256       TEXT NOT NULL,
            created_at       INTEGER NOT NULL,
            status           TEXT NOT NULL DEFAULT 'PENDING',
            attempts         INTEGER NOT NULL DEFAULT 0,
            next_attempt_at  INTEGER NOT NULL DEFAULT 0,
            last_error       TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_queue_status_next ON measurement_queue (status, next_attempt_at)');
        await db.execute('''
          CREATE TABLE app_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
    _db = db;
    await recoverStaleInFlight();
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // -------------------------------------------------------------------------
  // Queue operations
  // -------------------------------------------------------------------------

  /// Appends a finished measurement session to the upload queue.
  /// Returns the generated measurement UUID.
  Future<String> enqueueMeasurement({
    required String deviceId,
    required String mode,
    required String payloadJson,
    required String rawCsv,
    required String csvSha256,
  }) async {
    final String uuid = generateUuidV4();
    await _requireDb.insert(
      'measurement_queue',
      <String, Object?>{
        'uuid': uuid,
        'device_id': deviceId,
        'mode': mode,
        'payload_json': payloadJson,
        'raw_csv': rawCsv,
        'csv_sha256': csvSha256,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'PENDING',
        'attempts': 0,
        'next_attempt_at': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore, // UNIQUE uuid — never duplicate
    );
    return uuid;
  }

  /// Rows currently waiting to go online (PENDING + due IN_FLIGHT retries).
  Future<int> pendingCount() async {
    final List<Map<String, Object?>> rows = await _requireDb.rawQuery(
      "SELECT COUNT(*) AS n FROM measurement_queue "
      "WHERE status IN ('PENDING','IN_FLIGHT')",
    );
    final Object? n = rows.isEmpty ? 0 : rows.first['n'];
    return n is int ? n : int.parse(n.toString());
  }

  /// Atomically claims the next due batch: selects due PENDING rows and
  /// flips them to IN_FLIGHT in one transaction.
  Future<List<QueuedMeasurement>> claimDueBatch({
    int limit = 5,
    int? nowMs,
  }) async {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final Database db = _requireDb;
    final List<QueuedMeasurement> claimed = <QueuedMeasurement>[];

    await db.transaction((Transaction txn) async {
      final List<Map<String, Object?>> rows = await txn.query(
        'measurement_queue',
        where: "status = 'PENDING' AND next_attempt_at <= ?",
        whereArgs: <Object?>[now],
        orderBy: 'created_at',
        limit: limit,
      );
      for (final Map<String, Object?> row in rows) {
        final QueuedMeasurement queued = _rowToQueued(row);
        await txn.update(
          'measurement_queue',
          <String, Object?>{'status': 'IN_FLIGHT'},
          where: 'id = ?',
          whereArgs: <Object?>[queued.id],
        );
        claimed.add(queued);
      }
    });
    return claimed;
  }

  Future<void> markSynced(int id) => _setStatus(id, 'SYNCED', null);

  /// Schedules a retry with exponential backoff.
  Future<void> markRetry(int id, String error) async {
    final Database db = _requireDb;
    final List<Map<String, Object?>> rows = await db.query(
      'measurement_queue',
      columns: <String>['attempts'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    final int attempts = (rows.isEmpty ? 0 : rows.first['attempts'] as int? ?? 0) + 1;
    final int backoffMs = _backoffMs(attempts);
    await db.update(
      'measurement_queue',
      <String, Object?>{
        'status': 'PENDING',
        'attempts': attempts,
        'next_attempt_at': DateTime.now().millisecondsSinceEpoch + backoffMs,
        'last_error': error.length > 500 ? error.substring(0, 500) : error,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// The record will never be accepted by the server (validation, signature,
  /// size). Kept forever for audit — the user can inspect & export it.
  Future<void> markPermanentFailure(int id, String error) async {
    final Database db = _requireDb;
    await db.update(
      'measurement_queue',
      <String, Object?>{
        'status': 'FAILED_PERMANENT',
        'last_error': error.length > 500 ? error.substring(0, 500) : error,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Crash recovery: anything left IN_FLIGHT goes back to PENDING.
  Future<void> recoverStaleInFlight() async {
    await _requireDb.update(
      'measurement_queue',
      <String, Object?>{'status': 'PENDING'},
      where: "status = 'IN_FLIGHT'",
    );
  }

  /// All records regardless of status (debug/export UI).
  Future<List<QueuedMeasurement>> allEntries({int limit = 200}) async {
    final List<Map<String, Object?>> rows = await _requireDb.query(
      'measurement_queue',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(_rowToQueued).toList();
  }

  // -------------------------------------------------------------------------
  // App metadata (device id, registration state)
  // -------------------------------------------------------------------------

  Future<String?> getMeta(String key) async {
    final List<Map<String, Object?>> rows = await _requireDb.query(
      'app_meta',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) async {
    await _requireDb.insert(
      'app_meta',
      <String, Object?>{'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Stable pseudonymous device id, created on first launch.
  Future<String> ensureDeviceId() async {
    String? id = await getMeta('device_id');
    if (id == null || id.isEmpty) {
      id = 'android-${generateUuidV4().substring(0, 13)}';
      await setMeta('device_id', id);
    }
    return id;
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  Future<void> _setStatus(int id, String status, String? error) async {
    await _requireDb.update(
      'measurement_queue',
      <String, Object?>{'status': status, 'last_error': error},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Exponential backoff with jitter: min(30 min, 30 s · 2^attempts) + jitter.
  static int _backoffMs(int attempts) {
    final int base = 30 * 1000; // 30 s
    final int capped = attempts > 6 ? 6 : attempts;
    final int exp = base * (1 << capped);
    final int withCap = exp > 30 * 60 * 1000 ? 30 * 60 * 1000 : exp;
    final int jitter = Random.secure().nextInt(10 * 1000);
    return withCap + jitter;
  }

  QueuedMeasurement _rowToQueued(Map<String, Object?> row) {
    return QueuedMeasurement(
      id: row['id'] as int,
      uuid: row['uuid'] as String,
      deviceId: row['device_id'] as String,
      mode: row['mode'] as String,
      payloadJson: row['payload_json'] as String,
      rawCsv: row['raw_csv'] as String,
      csvSha256: row['csv_sha256'] as String,
      createdAtMs: row['created_at'] as int,
      status: queueStatusFromWire(row['status'] as String),
      attempts: row['attempts'] as int? ?? 0,
      nextAttemptAtMs: row['next_attempt_at'] as int? ?? 0,
      lastError: row['last_error'] as String?,
    );
  }
}
