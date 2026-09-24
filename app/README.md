# GlobeOrFlat — Android Client (Flutter)

The citizen-science companion app to the [GlobeOrFlat backend](../../README.md).
Implements the full measurement pipeline: **sensors → EKF fusion → guided
calibration → offline queue → Keystore-signed upload** to the append-only
Cloudflare Workers API.

```
┌──────────────────────── Flutter (lib/) ────────────────────────┐
│                                                                │
│  calibration_screen.dart   3D figure-8 + rest-check hard gate  │
│         │ results (gyro bias, mag hard-iron)                   │
│         ▼                                                      │
│  sensor_fusion_service.dart                                    │
│    • sensors_plus: accel/gyro/mag/baro streams                 │
│    • geolocator: GNSS fixes                                    │
│    • complementary attitude filter (quaternion)                │
│    • VerticalAltitudeEKF: baro ⊕ GNSS altitude  ← validated    │
│         │ raw CSV log (write-once) + payload metadata          │
│         ▼                                                      │
│  offline_db_service.dart (sqflite)   upload queue, crash-safe  │
│         │                                                      │
│         ▼                                                      │
│  sync_manager.dart   auto-drain on connectivity restore        │
│         │ signs with keystore_service.dart (GOFv1)             │
│         ▼                                                      │
└────────────────── MethodChannel ───────────────────────────────┘
                          ▼
        MainActivity.kt — Android Keystore EC P-256
        SHA256withECDSA (DER), key non-exportable
```

## Files of interest

| File | Purpose |
| --- | --- |
| `lib/services/sensor_fusion_service.dart` | **Deliverable 1** — sensor subsystem + `VerticalAltitudeEKF` (baro/GNSS fusion) + quaternion attitude filter + raw CSV logging. |
| `lib/services/keystore_service.dart` | **Deliverable 2** — Android Keystore ECDSA signing service (GOFv1 canonical strings, payload hashing). |
| `lib/services/offline_db_service.dart` | **Deliverable 3a** — sqflite offline store + append-style upload queue (payloads written once; only sync bookkeeping changes). |
| `lib/services/sync_manager.dart` | **Deliverable 3b** — automatic sync on connectivity restore, exponential backoff, idempotency-aware (409 = already there). |
| `lib/screens/calibration_screen.dart` | **Deliverable 4** — mandatory calibration gate: animated 3D phone (pure `CustomPainter`), figure-8 sweep, flat-surface rest check, Gyro/Accel/Magnetometer accuracy 0–100 %. |
| `lib/services/calibration_service.dart` | The math behind the screen (coverage grid, Welford statistics, hard-/soft-iron estimation). |
| `android/app/src/main/kotlin/dev/globeorflat/app/MainActivity.kt` | Native Keystore bridge (`ensureKeyPair`, `sign`, …). |
| `test/sensor_fusion_test.dart` | Deterministic EKF regression test (`flutter test`). |

## The EKF in one page

State `x = [h, v, b]` — altitude, vertical velocity, barometer bias.

* **Predict** (every IMU tick, ~50 Hz): constant-velocity model driven by the
  *world-frame vertical acceleration* obtained by rotating the accelerometer
  reading with the attitude quaternion and subtracting gravity.
* **Update — barometer** (~10 Hz): `baro_altitude(p) = 44330·(1 − (p/1013.25)^0.1903)`
  measures `h + b` with σ ≈ 0.35 m. This is what kills the GNSS noise: between
  1 Hz GPS fixes, altitude rides the low-noise barometer.
* **Update — GNSS** (≤ 1 Hz, σ ≈ 3–10 m): keeps `h` honest so barometric drift
  and weather-induced pressure changes cannot run away, and simultaneously
  re-learns the bias `b`. A 3σ innovation gate (min 15 m) rejects multipath jumps.

Tuning was validated by 20-seed Monte-Carlo simulation: **GNSS RMSE ≈ 5 m →
fused RMSE ≈ 0.7 m**, glitch rejection and bias tracking verified.
`test/sensor_fusion_test.dart` locks this in with a deterministic replay.

## Calibration scoring

| Step | Signal | Score contribution |
| --- | --- | --- |
| Figure-8 | pitch×roll coverage grid (5×12 buckets) | magnetometer 55 % |
| Figure-8 | stability of \|m\| across the sweep | magnetometer 45 % |
| Rest | per-axis gyro noise while still | gyroscope 0–100 |
| Rest | \|‖a‖−g\| and noise while still | accelerometer 0–100 |

Outputs applied to all future measurements: gyro bias (mean ω at rest),
magnetometer hard-iron offset `(max+min)/2`, soft-iron scale (normalised
`max−min`/2).

## Build & run

> Scaffold the Android runner once with
> `flutter create --org dev.globeorflat .` inside `app/`, then merge
> `AndroidManifest.xml` permissions and drop in `MainActivity.kt` (paths above).
> Set `minSdkVersion 23`.

```bash
flutter pub get
flutter test                                   # deterministic EKF regression
flutter run --dart-define=GOF_API_BASE_URL=https://globeorflat-api.<you>.workers.dev \
            --dart-define=GOF_INGEST_TOKEN=<your CLIENT_INGEST_TOKEN>
```

Minimum Android 6.0 (API 23) with barometer + gyroscope + compass + GNSS.

## Notes

* Signatures are produced by `SHA256withECDSA` (ASN.1 DER) — exactly what the
  backend's `crypto_verify.ts` expects; the signing key never leaves the
  hardware Keystore and signing works fully offline.
* Raw CSV dumps are capped at 60 000 rows (~10 Hz × 100 min); the header notes
  truncation so researchers can trust the data.
* Uploads are idempotent: the backend's `UNIQUE signature_hash` turns crash
  replays into harmless `409 duplicate_measurement` responses.
