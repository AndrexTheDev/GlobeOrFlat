# GlobeOrFlat — Backend

**Append-only citizen-science API for Earth-curvature measurements.**
Built on Cloudflare Workers + [Hono](https://hono.dev) + Cloudflare D1 (SQLite) + Cloudflare R2.

> Android users run one of four experiments — `HORIZON_DIP`, `WATER_SIGHTLINE`, `TRACK_DRIVE`, `ERATOSTHENES` — sign the result with a hardware-backed Android Keystore key, and upload it. Researchers query everything through a free, open, paginated JSON API.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

---

## Table of contents

1. [Design principles](#design-principles)
2. [Architecture](#architecture)
3. [Repository layout](#repository-layout)
4. [Quickstart](#quickstart)
5. [Configuration reference](#configuration-reference)
6. [The GOFv1 signature protocol](#the-gofv1-signature-protocol)
7. [API reference](#api-reference)
8. [Append-only guarantees](#append-only-guarantees)
9. [Public data access for scientists](#public-data-access-for-scientists)
10. [Local development & testing](#local-development--testing)
11. [Roadmap](#roadmap)
12. [License](#license)

---

## Design principles

1. **Strictly append-only.** There is no UPDATE or DELETE anywhere in the API. The rules are
   *also* enforced at the storage layer by SQLite triggers (see [`schema.sql`](./schema.sql)):
   any `UPDATE`/`DELETE` on `measurements`, `device_keys`, or `verification_events` aborts —
   even if run directly against D1. Public client keys can only ever **add** data.
2. **Every measurement is signed.** The device signs a canonical string with its ECDSA P-256
   Android Keystore key. The server verifies before persisting. A `UNIQUE` hash of the
   signature makes replay of an already-ingested measurement impossible.
3. **Raw data is sacred.** The complete raw sensor dump (CSV) is written once to R2; D1 stores
   its object key and SHA-256 so anyone can re-verify integrity later.
4. **Open data.** The read API requires no account, no key, no payment.

## Architecture

```
                 Android app (hardware-backed Keystore, ECDSA P-256)
                                    │  HTTPS · multipart upload + detached signature
                                    ▼
        ┌──────────────────── Cloudflare Worker (Hono) ────────────────────┐
        │  • verify CLIENT_INGEST_TOKEN                                    │
        │  • verify device ECDSA signature (crypto_verify.ts, WebCrypto)   │
        │  • validate payload (zod) + anti-replay (fresh signed_at)        │
        └───────────────┬──────────────────────────────────┬───────────────┘
                        │ metadata (INSERT only)           │ raw CSV (PUT once)
                        ▼                                  ▼
                ┌───────────────┐                  ┌──────────────────┐
                │  D1 (SQLite)  │                  │   R2 bucket      │
                │  measurements │                  │  raw sensor      │
                │  device_keys  │                  │  dumps (WORM-    │
                │  verification │                  │  recommended)    │
                │  _events      │                  └──────────────────┘
                └───────┬───────┘                          │
                        │ presigned URL / streaming proxy  │
                        ▼                                  ▼
        Researchers & scientists — public GET /api/v1/measurements[...]
```

## Repository layout

| File | Purpose |
| --- | --- |
| `worker.ts` | Hono router + all API routes (the whole backend). |
| `crypto_verify.ts` | GOFv1 canonical-string builder + Android Keystore ECDSA verification (DER→raw conversion, SPKI import, WebCrypto verify). |
| `schema.sql` | D1 SQLite schema: tables, append-only triggers, verification ledger, indexes. |
| `wrangler.toml` | Cloudflare Worker configuration (D1 + R2 bindings, vars). |
| `scripts/smoke_test.mjs` | End-to-end test: generates a P-256 key, signs and uploads a measurement, exercises every route. |
| `.dev.vars.example` | Template for local secrets. |

## Quickstart

Prerequisites: Node.js ≥ 18, an npm account-free [Cloudflare account](https://dash.cloudflare.com/) (Workers free plan is sufficient).

```bash
git clone https://github.com/AndrexTheDev/GlobeOrFlat.git
cd GlobeOrFlat
npm install

# 1. Provision resources (one-time)
npx wrangler d1 create globeorflat
#    → copy the returned database_id into wrangler.toml
npx wrangler r2 bucket create globeorflat-raw-sensor-dumps

# 2. Apply the schema
npm run db:schema:local     # local dev database
npm run db:schema:remote    # production database

# 3. Set production secrets
npx wrangler secret put CLIENT_INGEST_TOKEN   # shared with the Android app builds
npx wrangler secret put ADMIN_TOKEN           # for moderators

# 4. Run locally
cp .dev.vars.example .dev.vars
npm run dev                   # http://127.0.0.1:8787

# 5. Deploy
npm run deploy                # https://globeorflat-api.<your-subdomain>.workers.dev
```

## Configuration reference

**Bindings** (defined in `wrangler.toml`):

| Binding | Type | Purpose |
| --- | --- | --- |
| `DB` | D1 | Append-only tables + verification ledger. |
| `RAW_DUMPS` | R2 | Raw sensor CSV dumps, written once per upload. |
| `RATE_LIMITER` *(optional)* | ratelimit | Platform rate limiting; uncomment in `wrangler.toml` to enable. |

**Secrets** (`wrangler secret put` / `.dev.vars`):

| Secret | Who holds it | Grants |
| --- | --- | --- |
| `CLIENT_INGEST_TOKEN` | every app build | `POST /measurements/upload`, `POST /devices/register` — **insert only** |
| `ADMIN_TOKEN` | moderators | `POST /admin/verifications`, `GET /admin/stats` — **append-only ledger events** |

**Vars** (see `wrangler.toml`): `MAX_SENSOR_DUMP_BYTES` (5 MiB), `PRESIGN_TTL_SECONDS` (3600),
`SIGNATURE_MAX_SKEW_MS` (±300 000 ms), `AUTO_VERIFY_SIGNED_UPLOADS` (`false`).

## The GOFv1 signature protocol

Every device generates an EC P-256 key **inside the Android Keystore**
(`setDigests(DIGEST_SHA256)`, key never exportable) and registers the public key once.
Signatures are produced with `SHA256withECDSA` over this **canonical string**:

```
GOFv1                                    ← protocol version
POST                                     ← uppercase method
/api/v1/measurements/upload              ← canonical request path
<device_id>                              ← device identifier
<sha256_hex(payload JSON bytes)>         ← exact bytes of the 'payload' multipart part
<signed_at epoch ms>                     ← fresh at signing time (anti-replay)
```

joined with `\n`. The detached signature travels in the `X-GoF-Signature` header
(base64, DER or raw via `X-GoF-Signature-Format: der|raw|ieee-p1363`).

The server recomputes the canonical string, converts the DER signature to the 64-byte
`r‖s` form WebCrypto expects, and verifies against the device's registered key(s).
`signed_at` must be within ±5 minutes of server time, and `sha256(signature)` must never
have been seen before (`UNIQUE signature_hash` in D1 — replay-proof at the storage layer).

**Device registration** (`POST /api/v1/devices/register`) is *proof-of-possession*: the
registration request itself must be signed by the key being registered (canonical string
uses the SHA-256 of the SPKI bytes instead of the payload hash). Optionally attach an
Android Key Attestation chain — its SHA-256 is stored as an integrity anchor.

Example client-side signing (Kotlin):

```kotlin
val canonical = listOf(
    "GOFv1", "POST", "/api/v1/measurements/upload",
    deviceId, payloadSha256Hex, signedAtMs.toString()
).joinToString("\n")

val signature = Signature.getInstance("SHA256withECDSA").apply {
    initSign(keyStorePrivateKey)
    update(canonical.toByteArray(Charsets.UTF_8))
}.sign()   // ASN.1 DER — send as X-GoF-Signature (base64, NO_WRAP)
```

## API reference

Base URL (production): `https://globeorflat-api.<your-subdomain>.workers.dev`
All responses are JSON (except the raw dump stream) and carry an `x-request-id` header.
Errors use a uniform envelope: `{"error": "<code>", "message": "..."}`.

### `POST /api/v1/measurements/upload` — ingest a measurement

`multipart/form-data`, auth: `Authorization: Bearer <CLIENT_INGEST_TOKEN>`

| Part / header | Description |
| --- | --- |
| `payload` | UTF-8 JSON metadata (this exact text is what the device signs) |
| `dump` | Raw sensor log file, `text/csv` (≤ 5 MiB) |
| `X-GoF-Device-Id` | Must equal `payload.device_id` |
| `X-GoF-Signature` | Base64 detached ECDSA signature of the GOFv1 canonical string |
| `X-GoF-Signature-Format` | `der` (default) \| `raw` \| `ieee-p1363` |

Payload JSON:

```json
{
  "device_id": "galaxy-s24-a1b2c3",
  "mode": "HORIZON_DIP",
  "timestamp": 1790000000000,
  "signed_at": 1790000060000,
  "gps_lat": 52.2297,
  "gps_lon": 21.0122,
  "altitude_m": 113.5,
  "curvature_deviation_percentage": 0.42
}
```

```bash
curl -X POST "$BASE/api/v1/measurements/upload" \
  -H "Authorization: Bearer $CLIENT_INGEST_TOKEN" \
  -H "X-GoF-Device-Id: galaxy-s24-a1b2c3" \
  -H "X-GoF-Signature: <base64 signature>" \
  -H "X-GoF-Signature-Format: der" \
  -F 'payload={"device_id":"galaxy-s24-a1b2c3", ...}' \
  -F 'dump=@raw_sensors.csv;type=text/csv'
```

`201 Created`:

```json
{
  "id": "be1633b8-0264-4d22-b248-9ddc2d06cec2",
  "verification_status": "PENDING",
  "signature_hash": "47cf8685...",
  "signed_with_key_version": 1,
  "created_at": "2026-09-24T12:23:40.515Z",
  "raw_dump": { "r2_key": "raw-dumps/2026/09/93f7.../be16....csv", "size_bytes": 220, "sha256": "2eb0..." },
  "links": { "self": ".../api/v1/measurements/be16...", "raw_dump": ".../api/v1/measurements/be16.../dump" }
}
```

### `GET /api/v1/measurements` — public researcher feed

No auth. Returns **verified** measurements by default, newest first.

| Query param | Default | Notes |
| --- | --- | --- |
| `page` / `per_page` | `1` / `20` | `per_page` ≤ 100 |
| `status` | `VERIFIED` | `PENDING`, `REJECTED`, `FLAGGED`, or `ALL` |
| `mode` | — | `HORIZON_DIP`, `WATER_SIGHTLINE`, `TRACK_DRIVE`, `ERATOSTHENES` |
| `device_id` | — | Group observations per device |
| `since` / `until` | — | Epoch ms filter on capture time |
| `min_lat` / `max_lat` / `min_lon` / `max_lon` | — | Bounding-box query |

```bash
curl "$BASE/api/v1/measurements?mode=WATER_SIGHTLINE&min_lat=50&max_lat=55&per_page=100"
```

```json
{
  "data": [ { "id": "...", "device_id": "...", "mode": "HORIZON_DIP", "timestamp": 1790000000000,
              "timestamp_iso": "2026-09-24T12:22:40.501Z", "gps_lat": 52.2297, "gps_lon": 21.0122,
              "altitude_m": 113.5, "curvature_deviation_percentage": 0.42,
              "verification_status": "VERIFIED", "signature_hash": "47cf...", "raw_dump_sha256": "2eb0...",
              "created_at": "...", "links": { "self": "...", "raw_dump": "..." } } ],
  "pagination": { "page": 1, "per_page": 20, "total_items": 4821, "total_pages": 242, "has_next": true, "has_prev": false }
}
```

### `GET /api/v1/measurements/:id` — public detail

Adds `raw_sensor_dump_r2_key` and a `raw_dump` block with `size_bytes`, `etag`,
a time-limited **presigned download URL** (`download_url`, TTL from `PRESIGN_TTL_SECONDS`)
and a permanent **streaming proxy** (`proxy_url`) that always works.

### `GET /api/v1/measurements/:id/dump` — public raw sensor CSV

Streams the original upload straight from R2 with an `immutable` cache header
(append-only ⇒ the bytes can never change). Verify integrity with `raw_dump_sha256`.

### `POST /api/v1/devices/register` — register a Keystore public key

Auth: ingest token. Body: `{ device_id, key_version?, public_key_spki, attestation_chain?, signed_at, signature, signature_format? }`.
The request must be signed by the submitted key (proof-of-possession). `201` on success,
`409` if that `device_id`/`key_version` already exists. **Key rotation** = append a new
`key_version`; old keys remain valid for verifying historical measurements.

### `POST /api/v1/admin/verifications` — moderate (append-only ledger)

Auth: `Authorization: Bearer <ADMIN_TOKEN>`.
Body: `{ "measurement_id": "...", "decision": "VERIFIED|REJECTED|FLAGGED", "reason"?, "decided_by"? }`.
Appends an event to `verification_events`; **nothing is ever overwritten** — the latest
event per measurement is authoritative, and the full moderation history is preserved.

### `GET /api/v1/admin/stats` — totals by mode & status *(admin token)*

### `GET /api/v1/health` — liveness + D1 reachability. `GET /` — endpoint index.

**Error codes:** `unauthorized` 401 · `invalid_signature` 401 · `signature_expired` 401 ·
`unknown_device` 403 · `not_found` 404 · `duplicate_measurement` 409 (replay) ·
`invalid_*` 400 · `unsupported_media_type` / `unsupported_dump_type` 415 ·
`dump_too_large` 413 · `rate_limited` 429 · `internal_error` 500.

## Append-only guarantees

| Layer | Mechanism |
| --- | --- |
| HTTP API | No UPDATE/DELETE routes exist at all. Client tokens can only POST; moderation only POSTs ledger events. |
| D1 (SQLite) | `BEFORE UPDATE` / `BEFORE DELETE` triggers `RAISE(ABORT)` on every table — verified: `append-only violation: UPDATE on measurements is forbidden`. |
| Replay | `measurements.signature_hash` is `UNIQUE` → the same signed payload can never be ingested twice; `signed_at` must be fresh (±5 min). |
| R2 | Dumps are written once under a per-measurement UUID key and never overwritten by the worker. For platform-level WORM, enable **Object Retention (compliance mode)** on the bucket: *Dashboard → R2 → bucket → Settings → Object retention*, or via the S3 API (`PutObjectRetention`, `Mode: COMPLIANCE`). |
| Secrets | `CLIENT_INGEST_TOKEN` cannot read or modify anything; `ADMIN_TOKEN` can only append decisions. |

Status transitions are therefore an *append-only ledger* (`verification_events`): the
public feed joins the `measurement_effective_status` view, where the latest event wins.
The full moderation history of every measurement stays auditable forever.

## Public data access for scientists

No account, no API key, no rate-limit negotiation — just page through the feed:

```bash
BASE="https://globeorflat-api.<your-subdomain>.workers.dev"

# All verified WATER_SIGHTLINE measurements in the Baltic basin, 100 per page:
curl "$BASE/api/v1/measurements?mode=WATER_SIGHTLINE&min_lat=53&max_lat=66&min_lon=10&max_lon=30&per_page=100"
```

Python (pandas) full export:

```python
import pandas as pd, requests

BASE = "https://globeorflat-api.<your-subdomain>.workers.dev"
rows, page = [], 1
while True:
    r = requests.get(f"{BASE}/api/v1/measurements",
                     params={"page": page, "per_page": 100}).json()
    rows += r["data"]
    if not r["pagination"]["has_next"]:
        break
    page += 1

df = pd.DataFrame(rows)
df.to_csv("globeorflat_verified.csv", index=False)
```

Field glossary: `mode` — experiment type; `timestamp` — device capture time (epoch ms);
`curvature_deviation_percentage` — deviation between measured and theoretically expected
curvature (0 ⇒ consistent with a globe); `signature_hash` — lets you prove a record was
signed by a registered device key; `raw_dump_sha256` — lets you verify the untouched raw
sensor log you download from `/dump` is byte-for-byte what the device uploaded.

If you use GlobeOrFlat data in a publication, please cite the project and include the
`signature_hash` values — reproducibility is the point. Measurements are dedicated to the
public domain (CC0) to the maximum extent permitted by law.

## Local development & testing

```bash
npm run dev                # starts wrangler dev on http://0.0.0.0:8787
node scripts/smoke_test.mjs  # 15 end-to-end checks (all should pass ✔)
```

The smoke test generates a fresh EC P-256 key pair, mimics the Android Keystore signing
scheme (DER signatures), and exercises registration, signed upload, replay rejection
(409), tamper rejection (401), pagination, raw dump download, the moderation ledger, and
stats. Use `npm run tail` to stream production logs.

## Roadmap

- Full Android Key Attestation chain validation against the Google hardware attestation root.
- Signed nightly dataset exports (object-level provenance).
- Per-device trust scoring on top of the verification ledger.
- WebSocket live feed for observation sessions.

## Contributing

PRs welcome — please run `npm run typecheck && node scripts/smoke_test.mjs` first.
Any change that weakens the append-only guarantees will be rejected.

## License

MIT — see [LICENSE](./LICENSE). Measurement **data** is dedicated to the public domain (CC0).
