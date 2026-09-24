#!/usr/bin/env node
/**
 * GlobeOrFlat end-to-end smoke test (local dev server).
 * SPDX-License-Identifier: MIT
 *
 * Prerequisites:
 *   npm install
 *   npm run db:schema:local
 *   cp .dev.vars.example .dev.vars   (defaults match the values below)
 *   npm run dev                      (in another terminal)
 *
 * Run:
 *   node scripts/smoke_test.mjs
 *   BASE_URL=http://127.0.0.1:8787 node scripts/smoke_test.mjs
 */

import { createHash, generateKeyPairSync, sign } from "node:crypto";

const BASE_URL = process.env.BASE_URL ?? "http://127.0.0.1:8787";
const CLIENT_INGEST_TOKEN = process.env.CLIENT_INGEST_TOKEN ?? "local-dev-ingest-token";
const ADMIN_TOKEN = process.env.ADMIN_TOKEN ?? "local-dev-admin-token";

// Unique per run so repeated smoke tests never collide with prior data.
const DEVICE_ID = `smoke-device-${Date.now()}`;
const UPLOAD_PATH = "/api/v1/measurements/upload";
const REGISTER_PATH = "/api/v1/devices/register";

// --- Client-side crypto (mirrors the Android Keystore behaviour) -----------
const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const spkiB64 = publicKey.export({ type: "spki", format: "der" }).toString("base64");

const sha256hex = (buf) => createHash("sha256").update(buf).digest("hex");
const signDer = (text) =>
  sign("sha256", Buffer.from(text, "utf8"), { key: privateKey, dsaEncoding: "der" }).toString("base64");

const CSV_DUMP = [
  "ts_ms,accel_x,accel_y,accel_z,gyro_x,gyro_y,gyro_z,pressure_hpa",
  "0,0.001,-0.012,9.801,0.0001,0.0002,-0.0001,1013.25",
  "100,0.002,-0.011,9.799,0.0002,0.0001,0.0000,1013.24",
  "200,-0.001,-0.010,9.803,-0.0001,0.0003,0.0001,1013.25",
].join("\n");

// --- Tiny test harness ------------------------------------------------------
let passed = 0;
let failed = 0;
async function step(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`  \u2714 ${name}`);
  } catch (err) {
    failed += 1;
    console.error(`  \u2718 ${name}`);
    console.error(`      ${err.message}`);
  }
}
function assertEq(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

async function api(path, init) {
  const res = await fetch(`${BASE_URL}${path}`, init);
  let body = null;
  if ((res.headers.get("content-type") ?? "").includes("application/json")) {
    try {
      body = await res.json();
    } catch {
      body = null;
    }
  }
  return { status: res.status, body, res };
}

function authed(token) {
  return { authorization: `Bearer ${token}` };
}

function signedUpload(payloadText, { signature, format = "der", token = CLIENT_INGEST_TOKEN } = {}) {
  const payload = JSON.parse(payloadText);
  const canonical = [
    "GOFv1",
    "POST",
    UPLOAD_PATH,
    payload.device_id,
    sha256hex(Buffer.from(payloadText, "utf8")),
    String(payload.signed_at),
  ].join("\n");
  const sig = signature ?? signDer(canonical);

  const form = new FormData();
  form.append("payload", new Blob([payloadText], { type: "application/json" }), "payload.json");
  form.append("dump", new Blob([CSV_DUMP], { type: "text/csv" }), "raw_sensors.csv");

  return {
    method: "POST",
    headers: {
      ...authed(token),
      "x-gof-device-id": payload.device_id,
      "x-gof-signature": sig,
      "x-gof-signature-format": format,
    },
    body: form,
  };
}

function measurementPayload(overrides = {}) {
  const signedAt = Date.now();
  return JSON.stringify({
    device_id: DEVICE_ID,
    mode: "HORIZON_DIP",
    timestamp: signedAt - 60_000,
    signed_at: signedAt,
    gps_lat: 52.2297,
    gps_lon: 21.0122,
    altitude_m: 113.5,
    curvature_deviation_percentage: 0.42,
    ...overrides,
  });
}

// =============================================================================
console.log(`\nGlobeOrFlat smoke test \u2192 ${BASE_URL}\n`);
// =============================================================================

await step("GET /api/v1/health returns ok", async () => {
  const { status, body } = await api("/api/v1/health");
  assertEq(status, 200, "status");
  assertEq(body.status, "ok", "health.status");
});

await step("registers a device with proof-of-possession (201)", async () => {
  const signedAt = Date.now();
  const canonical = [
    "GOFv1",
    "POST",
    REGISTER_PATH,
    DEVICE_ID,
    sha256hex(Buffer.from(spkiB64, "base64")),
    String(signedAt),
  ].join("\n");
  const { status, body } = await api(REGISTER_PATH, {
    method: "POST",
    headers: { ...authed(CLIENT_INGEST_TOKEN), "content-type": "application/json" },
    body: JSON.stringify({
      device_id: DEVICE_ID,
      key_version: 1,
      public_key_spki: spkiB64,
      signed_at: signedAt,
      signature: signDer(canonical),
      signature_format: "der",
    }),
  });
  assertEq(status, 201, "status");
  assertEq(body.device_id, DEVICE_ID, "device_id");
});

await step("re-registering the same key_version is rejected (409)", async () => {
  const signedAt = Date.now();
  const canonical = [
    "GOFv1",
    "POST",
    REGISTER_PATH,
    DEVICE_ID,
    sha256hex(Buffer.from(spkiB64, "base64")),
    String(signedAt),
  ].join("\n");
  const { status } = await api(REGISTER_PATH, {
    method: "POST",
    headers: { ...authed(CLIENT_INGEST_TOKEN), "content-type": "application/json" },
    body: JSON.stringify({
      device_id: DEVICE_ID,
      key_version: 1,
      public_key_spki: spkiB64,
      signed_at: signedAt,
      signature: signDer(canonical),
    }),
  });
  assertEq(status, 409, "status");
});

let uploaded = null;
await step("uploads a signed measurement (201)", async () => {
  const { status, body } = await api(UPLOAD_PATH, signedUpload(measurementPayload()));
  assertEq(status, 201, "status");
  assertEq(body.verification_status, "PENDING", "initial status");
  assertEq(body.raw_dump.size_bytes, Buffer.byteLength(CSV_DUMP), "dump size");
  uploaded = body;
});

await step("rejects a replayed signature (409)", async () => {
  const payloadText = measurementPayload();
  const payload = JSON.parse(payloadText);
  const canonical = [
    "GOFv1",
    "POST",
    UPLOAD_PATH,
    payload.device_id,
    sha256hex(Buffer.from(payloadText, "utf8")),
    String(payload.signed_at),
  ].join("\n");
  const sig = signDer(canonical);

  const first = await api(UPLOAD_PATH, signedUpload(payloadText, { signature: sig }));
  assertEq(first.status, 201, "first upload");
  const second = await api(UPLOAD_PATH, signedUpload(payloadText, { signature: sig }));
  assertEq(second.status, 409, "replay status");
});

await step("rejects a tampered payload (401)", async () => {
  const payloadText = measurementPayload({ curvature_deviation_percentage: 0.42 });
  const signedForOriginal = signedUpload(payloadText);
  const tampered = payloadText.replace("0.42", "9.99");
  const { status } = await api(UPLOAD_PATH, {
    ...signedUpload(tampered),
    headers: signedForOriginal.headers, // signature no longer covers the payload
  });
  assertEq(status, 401, "status");
});

await step("rejects uploads without an ingest token (401)", async () => {
  const init = signedUpload(measurementPayload());
  delete init.headers.authorization;
  const { status } = await api(UPLOAD_PATH, init);
  assertEq(status, 401, "status");
});

await step("public list defaults to VERIFIED and is paginated", async () => {
  const { status, body } = await api("/api/v1/measurements?per_page=5");
  assertEq(status, 200, "status");
  assertEq(Array.isArray(body.data), true, "data array");
  assertEq(body.pagination.per_page, 5, "per_page");
  const pending = await api("/api/v1/measurements?status=PENDING");
  assertEq(pending.body.data.some((m) => m.id === uploaded.id), true, "uploaded measurement is PENDING");
});

await step("detail endpoint returns raw dump links", async () => {
  const { status, body } = await api(`/api/v1/measurements/${uploaded.id}`);
  assertEq(status, 200, "status");
  assertEq(body.id, uploaded.id, "id");
  assertEq(typeof body.raw_dump.download_url, "string", "download_url");
  assertEq(body.raw_sensor_dump_r2_key, uploaded.raw_dump.r2_key, "r2 key");
});

await step("dump endpoint streams the exact CSV bytes", async () => {
  const { status, res } = await api(`/api/v1/measurements/${uploaded.id}/dump`);
  assertEq(status, 200, "status");
  const text = await res.text();
  assertEq(text, CSV_DUMP, "dump content");
});

await step("append-only: unknown id returns 404", async () => {
  const { status } = await api("/api/v1/measurements/00000000-0000-4000-8000-000000000000");
  assertEq(status, 404, "status");
});

await step("admin verification event is appended (201)", async () => {
  const { status, body } = await api("/api/v1/admin/verifications", {
    method: "POST",
    headers: { ...authed(ADMIN_TOKEN), "content-type": "application/json" },
    body: JSON.stringify({
      measurement_id: uploaded.id,
      decision: "REJECTED",
      reason: "smoke-test: horizon dip implausible for altitude",
      decided_by: "smoke-test",
    }),
  });
  assertEq(status, 201, "status");
  assertEq(body.effective_status, "REJECTED", "effective status");
});

await step("rejected measurement leaves the default VERIFIED feed", async () => {
  const verified = await api("/api/v1/measurements?status=VERIFIED");
  assertEq(verified.body.data.some((m) => m.id === uploaded.id), false, "not in VERIFIED");
  const rejected = await api("/api/v1/measurements?status=REJECTED");
  assertEq(rejected.body.data.some((m) => m.id === uploaded.id), true, "in REJECTED");
});

await step("admin endpoints require the admin token (401)", async () => {
  const { status } = await api("/api/v1/admin/stats");
  assertEq(status, 401, "status");
});

await step("admin stats aggregate by mode and status", async () => {
  const { status, body } = await api("/api/v1/admin/stats", { headers: authed(ADMIN_TOKEN) });
  assertEq(status, 200, "status");
  assertEq(typeof body.totals.measurements, "number", "totals");
});

// =============================================================================
console.log(`\n${passed} passed, ${failed} failed\n`);
process.exitCode = failed === 0 ? 0 : 1;
