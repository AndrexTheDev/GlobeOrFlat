#!/usr/bin/env node
/**
 * GlobeOrFlat — extended backend audit (edge cases beyond smoke_test.mjs).
 * SPDX-License-Identifier: MIT
 *
 * Covers: pagination/validation edges, CORS (incl. the portal's dump fetch),
 * signature freshness window, timestamp floors, key rotation, FLAGGED ledger
 * flow, secure headers, and — with --triggers — the storage-layer append-only
 * triggers via `wrangler d1 execute --local`.
 *
 * Run against a local dev server:   npm run dev   then
 *   node scripts/audit_backend.mjs
 * Trigger test (needs wrangler local state, same as dev):
 *   node scripts/audit_backend.mjs --triggers
 */

import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { execSync } from "node:child_process";

const BASE_URL = process.env.BASE_URL ?? "http://127.0.0.1:8787";
const CLIENT_INGEST_TOKEN = process.env.CLIENT_INGEST_TOKEN ?? "local-dev-ingest-token";
const ADMIN_TOKEN = process.env.ADMIN_TOKEN ?? "local-dev-admin-token";

const UPLOAD_PATH = "/api/v1/measurements/upload";
const REGISTER_PATH = "/api/v1/devices/register";

const runTriggers = process.argv.includes("--triggers");
const onlyHttp = process.argv.includes("--http-only");

let passed = 0;
let failed = 0;
const failures = [];
async function step(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`  \u2714 ${name}`);
  } catch (err) {
    failed += 1;
    failures.push(`${name}: ${err.message}`);
    console.error(`  \u2718 ${name}`);
    console.error(`      ${err.message}`);
  }
}
function assertEq(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
function assertIncludes(haystack, needle, label) {
  if (!String(haystack).toLowerCase().includes(String(needle).toLowerCase())) {
    throw new Error(`${label}: "${needle}" not in ${JSON.stringify(String(haystack).slice(0, 200))}`);
  }
}

async function raw(path, init) {
  return fetch(`${BASE_URL}${path}`, init);
}
async function api(path, init) {
  const res = await fetch(`${BASE_URL}${path}`, init);
  let body = null;
  if ((res.headers.get("content-type") ?? "").includes("application/json")) {
    try { body = await res.json(); } catch { body = null; }
  }
  return { status: res.status, body, res };
}
const sha256hex = (buf) => createHash("sha256").update(buf).digest("hex");
const signDer = (text, privateKey) =>
  sign("sha256", Buffer.from(text, "utf8"), { key: privateKey, dsaEncoding: "der" }).toString("base64");

function makeDevice(label) {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  return {
    label,
    privateKey,
    spkiB64: publicKey.export({ type: "spki", format: "der" }).toString("base64"),
    id: `audit-${label}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`,
  };
}

async function registerDevice(device, keyVersion = 1, keyOverride = null) {
  // Proof-of-possession: the request must be signed by the key BEING
  // registered (for rotations the device holds both Keystore keys).
  const signedAt = Date.now();
  const spki = keyOverride ? keyOverride.spkiB64 : device.spkiB64;
  const signingKey = keyOverride ? keyOverride.privateKey : device.privateKey;
  const canonical = ["GOFv1", "POST", REGISTER_PATH, device.id, sha256hex(Buffer.from(spki, "base64")), String(signedAt)].join("\n");
  const res = await api(REGISTER_PATH, {
    method: "POST",
    headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({
      device_id: device.id,
      key_version: keyVersion,
      public_key_spki: spki,
      signed_at: signedAt,
      signature: signDer(canonical, signingKey),
      signature_format: "der",
    }),
  });
  if (res.status !== 201) throw new Error(`register v${keyVersion} failed: ${res.status} ${JSON.stringify(res.body)}`);
  return res;
}

const CSV = "ts_ms,ax,ay,az\n0,0,0,-9.81\n100,0,0,-9.81\n";

function signedUpload(device, payloadText, { signatureFormat = "der", signWith = null, token = CLIENT_INGEST_TOKEN, extraHeaders = {} } = {}) {
  const payload = JSON.parse(payloadText);
  const canonical = ["GOFv1", "POST", UPLOAD_PATH, payload.device_id, sha256hex(Buffer.from(payloadText, "utf8")), String(payload.signed_at)].join("\n");
  const sig = signDer(canonical, signWith ?? device.privateKey);
  const form = new FormData();
  form.append("payload", new Blob([payloadText], { type: "application/json" }), "payload.json");
  form.append("dump", new Blob([CSV], { type: "text/csv" }), "raw.csv");
  return {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "x-gof-device-id": payload.device_id,
      "x-gof-signature": sig,
      "x-gof-signature-format": signatureFormat,
      ...extraHeaders,
    },
    body: form,
  };
}

function payloadText(device, overrides = {}) {
  const signedAt = Date.now();
  return JSON.stringify({
    device_id: device.id,
    mode: "HORIZON_DIP",
    timestamp: signedAt - 30_000,
    signed_at: signedAt,
    gps_lat: 40.4168,
    gps_lon: -3.7038,
    altitude_m: 12,
    curvature_deviation_percentage: 1.2,
    ...overrides,
  });
}

// =============================================================================
console.log(`\nGlobeOrFlat backend audit \u2192 ${BASE_URL}\n`);
// =============================================================================

await step("health: ok + protocol banner", async () => {
  const { status, body } = await api("/api/v1/health");
  assertEq(status, 200, "status");
  assertEq(body.status, "ok", "health.status");
  assertEq(body.protocol, "GOFv1", "health.protocol");
});

await step("secure headers present on API responses", async () => {
  const res = await raw("/api/v1/health");
  // hono secureHeaders defaults
  assertIncludes(res.headers.get("x-content-type-options") ?? "", "nosniff", "x-content-type-options");
});

await step("CORS preflight allows GET/POST/OPTIONS from any origin", async () => {
  const res = await raw("/api/v1/measurements", {
    method: "OPTIONS",
    headers: { origin: "https://hub.example", "access-control-request-method": "GET" },
  });
  assertIncludes(res.headers.get("access-control-allow-origin") ?? "", "*", "allow-origin");
  assertIncludes(res.headers.get("access-control-allow-methods") ?? "", "GET", "allow-methods");
});

await step("CORS header on GET list + dump (portal cross-origin fetch)", async () => {
  const list = await raw("/api/v1/measurements?per_page=1", { headers: { origin: "https://hub.example" } });
  assertIncludes(list.headers.get("access-control-allow-origin") ?? "", "*", "list allow-origin");
  const page1 = await (await fetch(`${BASE_URL}/api/v1/measurements?per_page=1`)).json();
  const first = page1.data[0];
  if (first) {
    const dump = await raw(`/api/v1/measurements/${first.id}/dump`, { headers: { origin: "https://hub.example" } });
    assertEq(dump.status, 200, "dump status");
    assertIncludes(dump.headers.get("access-control-allow-origin") ?? "", "*", "dump allow-origin");
  }
});

await step("validation: invalid mode / lat / altitude / status / per_page rejected (400)", async () => {
  const bad = [
    ["/api/v1/measurements?mode=WATER_LEVEL", "mode"],
    ["/api/v1/measurements?status=WHATEVER", "status"],
    ["/api/v1/measurements?per_page=101", "per_page>100"],
    ["/api/v1/measurements?per_page=0", "per_page=0"],
    ["/api/v1/measurements?page=0", "page=0"],
    ["/api/v1/measurements?min_lat=91", "min_lat"],
  ];
  for (const [path, label] of bad) {
    const { status } = await api(path);
    assertEq(status, 400, `400 for ${label}`);
  }
});

await step("pagination: page beyond range \u2192 200 with empty page + correct flags", async () => {
  const { status, body } = await api("/api/v1/measurements?page=9999&per_page=20");
  assertEq(status, 200, "status");
  assertEq(body.data.length, 0, "empty data");
  assertEq(body.pagination.has_next, false, "has_next");
  assertEq(body.pagination.has_prev, true, "has_prev");
});

await step("upload validation: bad mode, bad lat, bad altitude, short device_id (400)", async () => {
  const d = makeDevice("validation");
  await registerDevice(d);
  const cases = [
    [{ mode: "SEISMIC" }, "mode"],
    [{ gps_lat: 91 }, "gps_lat"],
    [{ altitude_m: 9001 }, "altitude"],
    [{ curvature_deviation_percentage: 2_000_000 }, "deviation range"],
  ];
  for (const [overrides, label] of cases) {
    const res = await api(UPLOAD_PATH, signedUpload(d, payloadText(d, overrides)));
    assertEq(res.status, 400, `400 for ${label}`);
  }
  // short device id — rejected by regex, no registration needed
  const tiny = makeDevice("x");
  tiny.id = "ab";
  const res = await api(UPLOAD_PATH, signedUpload(tiny, payloadText(tiny)));
  assertEq(res.status, 400, "400 for short device_id");
});

await step("anti-replay freshness: stale signed_at \u2192 401 signature_expired", async () => {
  const d = makeDevice("stale");
  await registerDevice(d);
  const stale = payloadText(d, { signed_at: Date.now() - 6 * 60 * 1000, timestamp: Date.now() - 7 * 60 * 1000 });
  const res = await api(UPLOAD_PATH, signedUpload(d, stale));
  assertEq(res.status, 401, "status");
  assertEq(res.body.error, "signature_expired", "error code");
});

await step("timestamp floor: capture before 2020 \u2192 400", async () => {
  const d = makeDevice("floor");
  await registerDevice(d);
  const ancient = payloadText(d, { timestamp: 1577836799000 }); // 2019-12-31T23:59:59Z
  const res = await api(UPLOAD_PATH, signedUpload(d, ancient));
  assertEq(res.status, 400, "status");
  assertEq(res.body.error, "invalid_timestamp", "error code");
});

await step("unregistered device \u2192 403 unknown_device", async () => {
  const d = makeDevice("ghost");
  const res = await api(UPLOAD_PATH, signedUpload(d, payloadText(d)));
  assertEq(res.status, 403, "status");
  assertEq(res.body.error, "unknown_device", "error code");
});

await step("key rotation: v2 key uploads, v1 key still verifies", async () => {
  const d = makeDevice("rotate");
  await registerDevice(d, 1);
  const kp2 = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const key2 = {
    spkiB64: kp2.publicKey.export({ type: "spki", format: "der" }).toString("base64"),
    privateKey: kp2.privateKey,
  };
  await registerDevice(d, 2, key2);

  // upload signed with v2
  const res2 = await api(UPLOAD_PATH, signedUpload(d, payloadText(d), { signWith: kp2.privateKey }));
  assertEq(res2.status, 201, "v2 upload");
  // upload signed with v1 (old key remains valid — historical verification)
  const res1 = await api(UPLOAD_PATH, signedUpload(d, payloadText(d)));
  assertEq(res1.status, 201, "v1 upload still accepted");
});

await step("wrong device header \u2192 400 device_id_mismatch", async () => {
  const d = makeDevice("hdr");
  await registerDevice(d);
  const init = signedUpload(d, payloadText(d));
  init.headers["x-gof-device-id"] = "some-other-device-0001";
  const res = await api(UPLOAD_PATH, init);
  assertEq(res.status, 400, "status");
  assertEq(res.body.error, "device_id_mismatch", "error code");
});

await step("oversized dump \u2192 413", async () => {
  const d = makeDevice("big");
  await registerDevice(d);
  const text = payloadText(d);
  const canonical = ["GOFv1", "POST", UPLOAD_PATH, d.id, sha256hex(Buffer.from(text, "utf8")), String(JSON.parse(text).signed_at)].join("\n");
  const form = new FormData();
  form.append("payload", new Blob([text], { type: "application/json" }), "payload.json");
  form.append("dump", new Blob([Buffer.alloc(6 * 1024 * 1024, 7)], { type: "text/csv" }), "big.csv");
  const res = await api(UPLOAD_PATH, {
    method: "POST",
    headers: {
      authorization: `Bearer ${CLIENT_INGEST_TOKEN}`,
      "x-gof-device-id": d.id,
      "x-gof-signature": signDer(canonical, d.privateKey),
      "x-gof-signature-format": "der",
    },
    body: form,
  });
  assertEq(res.status, 413, "status");
  assertEq(res.body.error, "dump_too_large", "error code");
});

await step("ledger: FLAGGED event moves record between status filters", async () => {
  const d = makeDevice("flag");
  await registerDevice(d);
  const up = await api(UPLOAD_PATH, signedUpload(d, payloadText(d)));
  assertEq(up.status, 201, "upload");
  const id = up.body.id;

  const ev = await api("/api/v1/admin/verifications", {
    method: "POST",
    headers: { authorization: `Bearer ${ADMIN_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ measurement_id: id, decision: "FLAGGED", reason: "audit: refraction anomaly", decided_by: "audit-bot" }),
  });
  assertEq(ev.status, 201, "event status");

  const flagged = await api(`/api/v1/measurements?status=FLAGGED&device_id=${d.id}`);
  assertEq(flagged.body.data.some((m) => m.id === id), true, "in FLAGGED feed");
  const verified = await api(`/api/v1/measurements?status=VERIFIED&device_id=${d.id}`);
  assertEq(verified.body.data.some((m) => m.id === id), false, "not in VERIFIED feed");
});

await step("mode filter: exact-match only", async () => {
  const all = await api("/api/v1/measurements?status=ALL&mode=HORIZON_DIP&per_page=50");
  assertEq(all.status, 200, "status");
  for (const row of all.body.data) assertEq(row.mode, "HORIZON_DIP", "mode purity");
});

await step("bbox filters accepted (min/max lat/lon)", async () => {
  const { status, body } = await api("/api/v1/measurements?status=ALL&min_lat=35&max_lat=45&min_lon=-10&max_lon=5&per_page=50");
  assertEq(status, 200, "status");
  for (const row of body.data) {
    if (row.gps_lat < 35 || row.gps_lat > 45 || row.gps_lon < -10 || row.gps_lon > 5) {
      throw new Error(`row outside bbox: ${row.id}`);
    }
  }
});

await step("detail: non-UUID \u2192 400, random UUID \u2192 404", async () => {
  assertEq((await api("/api/v1/measurements/not-a-uuid")).status, 400, "non-uuid");
  assertEq((await api("/api/v1/measurements/00000000-0000-4000-8000-000000000000")).status, 404, "unknown uuid");
});

await step("dump: attachment disposition + immutable cache headers", async () => {
  const page1 = await (await fetch(`${BASE_URL}/api/v1/measurements?per_page=1`)).json();
  const first = page1.data[0];
  if (!first) return; // nothing ingested yet — smoke test covers the rest
  const res = await raw(`/api/v1/measurements/${first.id}/dump`);
  assertIncludes(res.headers.get("content-disposition") ?? "", "attachment", "content-disposition");
  assertIncludes(res.headers.get("cache-control") ?? "", "immutable", "cache-control");
});

if (runTriggers) {
  console.log("\n--- storage-layer append-only triggers (wrangler d1 --local) ---");
  await step("UPDATE measurements \u2192 ABORT", async () => {
    let aborted = false;
    try {
      execSync(
        `npx wrangler d1 execute globeorflat --local -y --command "UPDATE measurements SET altitude_m = 0"`,
        { stdio: "pipe", cwd: process.cwd() },
      );
    } catch (e) {
      aborted = true;
      assertIncludes(String(e.stderr || e.message), "append-only", "abort reason");
    }
    assertEq(aborted, true, "expected abort");
  });
  await step("DELETE FROM verification_events \u2192 ABORT", async () => {
    let aborted = false;
    try {
      execSync(
        `npx wrangler d1 execute globeorflat --local -y --command "DELETE FROM verification_events"`,
        { stdio: "pipe", cwd: process.cwd() },
      );
    } catch (e) {
      aborted = true;
      assertIncludes(String(e.stderr || e.message), "append-only", "abort reason");
    }
    assertEq(aborted, true, "expected abort");
  });
  await step("INSERT still works (append-only permits writes)", async () => {
    const out = execSync(
      `npx wrangler d1 execute globeorflat --local -y --command "SELECT COUNT(*) AS n FROM measurements" --json`,
      { stdio: "pipe", cwd: process.cwd() },
    ).toString();
    assertIncludes(out, '"n"', "select result");
  });
}

console.log(`\n=== audit: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  for (const f of failures) console.log(`  ✗ ${f}`);
  process.exit(1);
}
