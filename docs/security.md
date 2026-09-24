# GlobeOrFlat — Security Model & Operations

SPDX-License-Identifier: MIT

This document is the single source of truth for what the platform defends
against, which control enforces each property, and which test proves the
control still works. Re-run the mapped suites after any change to the
listed files — a control without a green proof is treated as broken.

## 1. Assets & adversaries

**Assets**

- Integrity of the public measurement feed (the science dataset).
- Device identity keys generated in the Android Keystore (non-exportable).
- The raw sensor dumps in R2 (write-once evidence).
- Availability of the public API and the hub.

**Adversaries (assumed capabilities)**

| Adversary | Capabilities |
|---|---|
| Malicious client | Full control of a device + network path; can forge/mangle/replay requests, flood endpoints, enroll arbitrary keys. |
| Malicious feed consumer | Can read all public data, run the hub in a hostile browser, share `?api=` links. |
| Malicious ad network | Controls ad markup/JS inside the banner WebView. |
| MITM | Passive on-path listener / rogue AP (no CA compromise). |
| Compromised CDN/dep dependency | Tries to ship altered JavaScript to hub or app. |

Out of scope: device malware with root, server-side credential compromise of
the Cloudflare account (mitigated by 2FA + scoped API tokens), legal/privacy
attacks on submitted GPS data (the dataset is public by design).

## 2. Controls by surface

### 2.1 Backend API (`worker.ts`, `crypto_verify.ts`)

| Property | Control | Proof (suite) |
|---|---|---|
| Ingest authenticity | Detached ECDSA P-256 (`GOFv1` canonical string: protocol/method/path/device/payload-hash/signedAt) | `check:security`, `smoke_test` |
| Anti-replay | `SIGNATURE_MAX_SKEW_MS` freshness window (±5 min) + unique-payload hash | `check:security` (skew ±), `audit_backend` (stale) |
| Cross-endpoint binding | Canonical string includes the route path — signatures are not transferable between endpoints | `check:security` |
| Token separation | `CLIENT_INGEST_TOKEN` (ingest+register only) ≠ `ADMIN_TOKEN` (ledger only); both via `Authorization: Bearer` over HTTPS | `check:security` (confusion matrix) |
| Key ownership | Registration requires proof-of-possession: the submitted key signs its own registration | `check:security` |
| DoS via body size | `MAX_PAYLOAD_BYTES` (64 KiB, byte-exact, 413 **before** `JSON.parse`), `MAX_SENSOR_DUMP_BYTES` (5 MiB, 413) | `check:security` (413 both sides) |
| Request floods | Workers rate-limit binding, 300 req/60 s per IP on `/api/v1/*`; worker fails OPEN if the binding errors (availability first; volumetric L3/L4 is Cloudflare edge's job) | `check:security` (400-req flood → 429, runs LAST) |
| Storage immutability | No UPDATE/DELETE routes; D1 triggers ABORT any `UPDATE`/`DELETE` at the storage layer | `audit_backend --triggers` |
| SQL injection | Every query uses `.bind()` parameters; enums parsed through zod + regex allowlists | `check:security` (metacharacter probes) |
| Malicious download content | Dumps served as `attachment` + `nosniff` + immutable cache | `check:security`, `audit_backend` |
| Error hygiene | Structured JSON errors, no stack traces; `x-request-id` for correlation | `check:security` |
| CORS | Wildcard origin **without credentials** (public reads); writes are bearer-token gated, never cookie-authenticated (no CSRF surface) | `check:security` |

### 2.2 Web hub (`web/`)

| Property | Control | Proof |
|---|---|---|
| Script injection from network | CSP: `script-src 'self' cdn.jsdelivr.net` + two inline scripts pinned by **base64** SHA-256 hashes; no `unsafe-inline`/`unsafe-eval`; `'wasm-unsafe-eval'` only for Cesium's decoders | `check:pages` (hash cross-check), beta/live CSP-violation proofs |
| Feed data as XSS vector | All API-supplied interpolations escaped (`escapeHtml`), enum fragments sanitized (`safeClass`), every `href` whitelisted (`safeUrl` blocks `javascript:`/`data:`) | `web/test/helpers.test.js` |
| CDN supply chain | Subresource Integrity (`sha384`, `crossorigin=anonymous`) on both Cesium tags pins exact artifact bytes, not just the origin | `check:pages` (SRI checks), beta run (mirror serves byte-identical files) |
| Endpoint override abuse (`?api=`) | `normalizeApiBase`: https-only (plain http only for localhost), no embedded credentials; UI shows `· CUSTOM` chip + boot toast; rejected values warn and fall back | `helpers.test.js` |
| Clickjacking | `X-Frame-Options: DENY` | `check:pages`, beta header check |
| MIME confusion | `X-Content-Type-Options: nosniff` | `check:pages` |
| Dependency vulnerabilities | `npm audit` in root/web/beta | manual gate (0 vulns as of 2026-09) |

Known toleration: Cesium bundles protobuf.js, which *attempts* `eval` to build
fast decoders, catches the CSP rejection itself and uses its slow fallback.
The beta/live suites tolerate exactly this one violation from the pinned CDN
bundle; anything else fails the run.

### 2.3 Android app (`app/`)

| Property | Control | Proof |
|---|---|---|
| Backend transport | `kApiBaseUrl` via `String.fromEnvironment`, HTTPS default; `network_security_config.xml`: cleartext disabled on **all** API levels, system CAs only | code review + CI build |
| Backup exfiltration | `android:allowBackup="false"` — device key material and offline queue never reach cloud backups / device-to-device transfer | manifest + CI build |
| Ad WebView escape | `NavigationDelegate` with exact-host-or-real-subdomain check (`host == h \|\| host.endsWith('.' + h)`); external destinations go to the OS browser | code review |
| SQL injection | sqflite fully binding-based | module audit |
| Key extraction | Keys are non-exportable Android Keystore ECDSA keys | platform guarantee |
| Surface exposure | Only `MainActivity` is `exported` | manifest audit |

## 3. Secret & key operations (runbooks)

### 3.1 Rotate `CLIENT_INGEST_TOKEN` (suspected leak / routine)

1. `npx wrangler secret put CLIENT_INGEST_TOKEN` (new value).
2. Ship the new value in the next app release (`--dart-define`).
3. Old app versions stop ingesting as soon as the old token is invalid —
   registration and upload fail **closed** (401). Schedule rotations with
   releases; there is no dual-token grace period by design (simplicity over
   zero-downtime for a citizen-science ingest).
4. `npm run check:security` must stay green afterwards.

### 3.2 Rotate `ADMIN_TOKEN`

Same as above; only moderators hold it. Ledger appends fail closed.

### 3.3 Device key rotation (built into GOFv1)

Devices register a new `key_version` signed by the **new** key (proof of
possession); the previous version stays valid so no measurement is orphaned.
Proven by `audit_backend` ("key rotation: v2 key uploads, v1 key still
verifies"). No server-side action required.

### 3.4 Compromised device key

There is deliberately **no delete** (append-only). Response: rotate the
device's key (3.3) so future measurements verify against the new key, and
append a moderator `FLAGGED`/`REJECTED` ledger event for the affected window
(ledger events are themselves append-only evidence). Public re-verification
of any dump is possible via the stored `raw_dump_sha256`.

### 3.5 Cesium artifact update (SRI pinning)

`web/index.html` pins exact bytes of `Cesium.js` + `widgets.css`:

1. Bump the version in `web/index.html` (script src, stylesheet href,
   `CESIUM_BASE_URL`) **and** in `web/test/pages_readiness.js` (allowlist).
2. Recompute both `integrity="sha384-…"` values from the new files
   (`openssl dgst -sha384 -binary FILE | openssl base64 -A`).
3. `cd web && npm run check:pages` — hash cross-checks fail loudly on drift.
4. `node beta/run_beta.cjs` — the mirror must serve byte-identical files;
   a live CDN change without matching hashes breaks the page **visibly**
   (that is the point: fail closed instead of executing tampered JS).

### 3.6 CSP inline-script edits

Both inline scripts in `web/index.html` are hash-pinned in `web/_headers`
(BASE64 digests — hex never matches!). After editing them, recompute:

```
python3 - <<'EOF'
import re, hashlib, base64
for m in re.finditer(rb'<script>(.*?)</script>', open('web/index.html','rb').read(), re.S):
    print("sha256-" + base64.b64encode(hashlib.sha256(m.group(1)).digest()).decode())
EOF
```

`npm run check:pages` verifies the set matches in both directions.

## 4. Test index

| Suite | Command | Checks |
|---|---|---|
| Web helpers (incl. security helpers) | `cd web && npm test` | assertions |
| Pages readiness (CSP/SRI/headers) | `cd web && npm run check:pages` | 28 |
| Worker typecheck | `npm run typecheck` | — |
| Smoke (API happy path) | `npm run smoke:test` | 15 |
| Backend audit | `node scripts/audit_backend.mjs --triggers` | 22 |
| **Adversarial security suite** | `node scripts/security_audit.mjs` (run LAST — the flood poisons the rate-limit window) | 20 |
| Headless beta (incl. CSP-violation proof) | `node beta/run_beta.cjs` (needs hub :8080 + mirror :8081) | 33 |
| Live integration (hub ↔ worker, CSP proof) | `node beta/run_live_api.cjs` | 14 |

## 5. Reporting

Please report vulnerabilities privately via the contact in the main README
(`mailto:` link) instead of opening a public issue. The dataset is public by
design; bugs in the ingest path or the hub will be acknowledged and fixed,
and this document updated together with the proving test.
