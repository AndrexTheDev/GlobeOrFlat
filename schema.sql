-- ============================================================================
-- GlobeOrFlat — Cloudflare D1 (SQLite) schema
-- SPDX-License-Identifier: MIT
--
-- DESIGN INVARIANT: STRICTLY APPEND-ONLY
-- ----------------------------------------------------------------------------
-- Public client keys may only ever INSERT. There is no UPDATE or DELETE
-- capability anywhere in the API surface, and the rules below are enforced
-- again at the STORAGE LAYER with SQLite triggers: any UPDATE or DELETE on
-- these tables raises ABORT, even if executed directly against D1.
--
-- Moderation (PENDING -> VERIFIED / REJECTED) is modeled as an append-only
-- *ledger* (`verification_events`): deciding a measurement appends a new
-- event; the latest event wins. Nothing is ever mutated. This gives the
-- project a complete, auditable moderation history for free.
--
-- Raw sensor dumps in R2 are write-once by convention; enable R2 Object
-- Retention (WORM, compliance mode) on the bucket to harden this at the
-- platform level. See README.md ("Append-only guarantees").
--
-- Apply with:
--   npx wrangler d1 execute globeorflat --remote --file=./schema.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- measurements — one row per submitted experiment run. Immutable.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS measurements (
  -- UUIDv4 generated server-side (crypto.randomUUID()).
  id                            TEXT    PRIMARY KEY,

  -- Pseudonymous device identifier generated on the client.
  user_device_id                TEXT    NOT NULL,

  -- Experiment type.
  mode                          TEXT    NOT NULL CHECK (mode IN (
                                    'HORIZON_DIP',
                                    'WATER_SIGHTLINE',
                                    'TRACK_DRIVE',
                                    'ERATOSTHENES'
                                  )),

  -- Client-captured UTC time of the measurement, milliseconds since epoch.
  timestamp                     INTEGER NOT NULL CHECK (timestamp > 1577836800000),

  gps_lat                       REAL    NOT NULL CHECK (gps_lat  >= -90   AND gps_lat  <= 90),
  gps_lon                       REAL    NOT NULL CHECK (gps_lon  >= -180  AND gps_lon  <= 180),
  altitude_m                    REAL    NOT NULL CHECK (altitude_m >= -450 AND altitude_m <= 9000),

  -- R2 object key of the raw sensor log (bucket: globeorflat-raw-sensor-dumps).
  raw_sensor_dump_r2_key        TEXT    NOT NULL,

  -- SHA-256 (hex) of the raw dump bytes, for integrity re-verification.
  raw_dump_sha256               TEXT,

  -- Percent deviation between measured and theoretically expected curvature.
  curvature_deviation_percentage REAL   CHECK (curvature_deviation_percentage IS NULL
                                        OR (curvature_deviation_percentage > -1000000
                                        AND curvature_deviation_percentage <  1000000)),

  -- Status AT INGESTION TIME (immutable column). Current status is derived
  -- from the verification_events ledger — see view measurement_effective_status.
  verification_status           TEXT    NOT NULL DEFAULT 'PENDING'
                                        CHECK (verification_status IN ('PENDING','VERIFIED','REJECTED')),

  -- SHA-256 (hex) of the ECDSA signature bytes. UNIQUE => database-level
  -- replay protection: the same signed payload can never be ingested twice.
  signature_hash                TEXT    NOT NULL UNIQUE,

  -- Server-side ingestion time (RFC 3339, UTC).
  created_at                    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- ----------------------------------------------------------------------------
-- APPEND-ONLY ENFORCEMENT (storage layer): any UPDATE/DELETE aborts.
-- ----------------------------------------------------------------------------
CREATE TRIGGER IF NOT EXISTS measurements_block_update
BEFORE UPDATE ON measurements
BEGIN
  SELECT RAISE(ABORT, 'append-only violation: UPDATE on measurements is forbidden');
END;

CREATE TRIGGER IF NOT EXISTS measurements_block_delete
BEFORE DELETE ON measurements
BEGIN
  SELECT RAISE(ABORT, 'append-only violation: DELETE on measurements is forbidden');
END;

-- ----------------------------------------------------------------------------
-- device_keys — Android Keystore ECDSA P-256 public keys, append-only.
-- Key rotation = appending a new row with a higher key_version. Old keys are
-- kept forever so historical signatures remain verifiable.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_keys (
  device_id          TEXT    NOT NULL,
  key_version        INTEGER NOT NULL DEFAULT 1 CHECK (key_version >= 1),

  -- Base64 DER SubjectPublicKeyInfo of the EC P-256 public key.
  public_key_spki    TEXT    NOT NULL,

  -- SHA-256 over the (optional) Android Key Atestation chain, as an
  -- integrity anchor. Full chain validation against the Google root is
  -- handled out-of-band / on the roadmap.
  attestation_sha256 TEXT,

  registered_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),

  PRIMARY KEY (device_id, key_version)
);

CREATE TRIGGER IF NOT EXISTS device_keys_block_update
BEFORE UPDATE ON device_keys
BEGIN
  SELECT RAISE(ABORT, 'append-only violation: UPDATE on device_keys is forbidden');
END;

CREATE TRIGGER IF NOT EXISTS device_keys_block_delete
BEFORE DELETE ON device_keys
BEGIN
  SELECT RAISE(ABORT, 'append-only violation: DELETE on device_keys is forbidden');
END;

-- ----------------------------------------------------------------------------
-- verification_events — append-only moderation / QA ledger.
-- Latest event per measurement (by created_at, then rowid) is authoritative.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS verification_events (
  id             TEXT PRIMARY KEY,
  measurement_id TEXT NOT NULL REFERENCES measurements(id),
  decision       TEXT NOT NULL CHECK (decision IN ('VERIFIED','REJECTED','FLAGGED')),
  reason         TEXT,
  decided_by     TEXT NOT NULL DEFAULT 'system',
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TRIGGER IF NOT EXISTS verification_events_block_update
BEFORE UPDATE ON verification_events
BEGIN
  SELECT RAISE(ABORT, 'append-only violation: UPDATE on verification_events is forbidden');
END;

CREATE TRIGGER IF NOT EXISTS verification_events_block_delete
BEFORE DELETE ON verification_events
BEGIN
  SELECT RAISE(ABORT, 'append-only violation: DELETE on verification_events is forbidden');
END;

-- ----------------------------------------------------------------------------
-- View: current (effective) verification status of every measurement.
-- Latest ledger event wins; falls back to the immutable ingest-time column.
-- ----------------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS measurement_effective_status AS
SELECT
  m.id AS measurement_id,
  COALESCE(
    (SELECT v.decision
       FROM verification_events v
      WHERE v.measurement_id = m.id
      ORDER BY v.created_at DESC, v.rowid DESC
      LIMIT 1),
    m.verification_status
  ) AS effective_status
FROM measurements m;

-- ----------------------------------------------------------------------------
-- Indexes for the public researcher queries.
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_measurements_timestamp ON measurements (timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_measurements_device_ts ON measurements (user_device_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_measurements_mode_ts   ON measurements (mode, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_verification_events_measurement
    ON verification_events (measurement_id, created_at DESC);
