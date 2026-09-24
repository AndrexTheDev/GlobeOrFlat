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

## The four measurement modes

| Mode | Screen | Physics | Recorded `curvature_deviation_percentage` |
| --- | --- | --- | --- |
| **A · Horizon Dip** | `screens/modes/horizon_dip_screen.dart` | θ ≈ 1.06′·√h; geometric √(2h/R) shown for context | (measured dip − 1.06′√h) / (1.06′√h) · 100 |
| **B · Water Sightline** | `screens/modes/water_sightline_screen.dart` | h_hidden = (d − 3.57√h_obs)² / (2·R_eff), R_eff = R/(1−k) = 7408.1 km | (estimated hidden − predicted) / predicted · 100 |
| **C · Track & Curve Drive** | `screens/modes/track_drive_screen.dart` | drop = 0.0785·s² sampled every 100 m vs measured EKF profile | 100·(rms_flat − rms_globe)/(rms_flat + rms_globe) |
| **D · Eratosthenes Synchro** | `screens/modes/eratosthenes_screen.dart` | solar noon = 12:00 − EoT − 4·lon; elevation = atan(1/(shadow/stick)) | null (computed later from the paired site) |

All physics lives in two pure, fully unit-tested modules:

* **`lib/physics/earth_curvature.dart`** — dip, horizon distance, occlusion,
  curvature drop, refraction (k = 0.14, R_eff = R/(1−k)), deviation metrics.
* **`lib/physics/solar_position.dart`** — Spencer (NOAA-style) equation of
  time + declination, solar noon, sun elevation, shadow geometry.

Expected values are locked in `test/physics_test.dart` against an
independently computed reference (almanac cross-checks: EoT Feb 11 ≈ −14.2′,
Nov 3 ≈ +16.4′; declination Jun 21 ≈ +23.45°; Madrid solar noon 2026-03-20 =
12:23 UTC).

### Mode A — how the AR HUD works

The HUD projects world elevation angles onto the screen using the camera
boresight elevation β (orientation-independent, from the fusion quaternion)
and an assumed 60° vertical FOV:

```
y(elevation) = screen_center + (β − elevation) · px_per_degree
```

* **green line** — elevation 0° (true horizontal)
* **cyan dashed** — elevation −θ (globe-predicted horizon)
* the vertical gap between them is the globe prediction, in pixels

Point the crosshair at the visible horizon and hold steady: the measured dip
is −β at capture time. On a flat Earth the cyan line would sit on the green
one — the gap *is* the hypothesis under test.

### Mode D — the sync code

Each Eratosthenes measurement gets a random 6-digit code. A partner at a
different latitude enters it before their own measurement; **both raw dumps
carry both codes** as `# eratosthenes,sync_code=…` / `partner_code=…`
comments, so researchers can pair the two sites and reproduce the classical
two-obelisk computation of Earth's circumference.

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

## Monetization (ads & crypto donations)

The app funds its free open API through a crypto-focused monetization stack:

| Piece | File | Notes |
| --- | --- | --- |
| Sticky bottom banner + mid-result banner | `lib/widgets/adsterra_banner_widget.dart` | Adsterra JS tag in a `webview_flutter` wrapper; IAB 320×50 / 300×250 / 728×90; clearly-labeled test placeholder while `AdConfig.testMode` is on. Mounted **only on non-camera screens**. |
| Rewarded video + feature tokens | `lib/services/coinzilla_rewarded_service.dart` | VAST 2/3/4 parsing (namespace-agnostic, prefers highest-bitrate MP4) played via `video_player` in a non-dismissable modal; 30 s minimum watch clock (5 s in test mode); completion grants a persisted `FeatureToken` spent on premium actions (PDF report, CSV export, 3D visualizer, ledger upload). If the ad network fails the action unlocks anyway — documented product decision. |
| Crypto donation modal | `lib/widgets/crypto_donation_modal.dart` | Cyberpunk dialog with QR codes + 1-tap copy for SOL / BTC (bech32) / ETH. Addresses are structurally validated in `test/monetization_test.dart`. |

Paste your zone keys / VAST tag into `lib/services/ad_config.dart` and flip
`testMode = false` before shipping. Never commit real keys to public forks.

## Results, Sharing & Reports

- **Results screen** (`lib/screens/results_screen.dart`): side-by-side matrix —
  **Measured Data** vs **Globe Model Expectation** vs **Flat Earth Model
  Expectation** — a headline score ("99.4% Match with Spherical Earth Model"),
  the verdict ladder, an integrity strip (SHA-256 + signature), and the
  mid-screen Adsterra banner (non-camera screen).
- **9:16 share card** (`lib/widgets/share_card_widget.dart`): CustomPainter
  HUD card (1080×1920 @ pixelRatio 2) with the camera snapshot, route map /
  deviation meter, pitch, distance and score — one tap "Share to Socials".
- **PDF audit report** (`lib/services/pdf_report_service.dart`, gated by the
  `Download PDF Audit Report` token): multi-page A4 report with the three-model
  matrix, GPS coordinates, calibration status, up to 120 rows of raw sensor
  telemetry tables, SHA-256 integrity chain, and the developer verification
  stamp. Print/preview via `printing`, OS share sheet via `share_plus`.

## Help, Safety & About

- **Help & FAQ** — mode field guides (incl. horizon-dip without refraction
  interference and water-sightline zoom best practices), sensor explanations
  (barometer vs GPS vs accelerometer) and ten FAQs, rendered with
  `flutter_markdown` on the shared HUD document scaffold.
- **Safety & Legal (Disclaimer)** — outdoor-safety warnings (never operate
  while driving; watch your surroundings near cliffs and water), the
  scientific disclaimer on sensor tolerances and refraction variability, and
  the data-permanence section. First launch is gated behind acceptance
  (`gof_disclaimer_accepted_v1`).
- **About** — developer credit (AndrexTheDev), contact e-mail, GitHub repo
  button, and the embedded crypto donation modal. All three documents share
  the cyberpunk HUD chrome in `lib/widgets/hud_document_scaffold.dart`.

## Notes

* Signatures are produced by `SHA256withECDSA` (ASN.1 DER) — exactly what the
  backend's `crypto_verify.ts` expects; the signing key never leaves the
  hardware Keystore and signing works fully offline.
* Raw CSV dumps are capped at 60 000 rows (~10 Hz × 100 min); the header notes
  truncation so researchers can trust the data.
* Uploads are idempotent: the backend's `UNIQUE signature_hash` turns crash
  replays into harmless `409 duplicate_measurement` responses.
