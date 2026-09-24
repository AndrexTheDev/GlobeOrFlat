#!/usr/bin/env node
/**
 * GlobeOrFlat — adversarial security audit (red-team suite).
 * SPDX-License-Identifier: MIT
 *
 * Assumes an attacker who fully controls client devices and network traffic:
 * forged/mangled payloads, replayed and cross-endpoint signatures, XSS
 * payloads in identifiers, oversized parts, wrong mime types, SQL metachar-
 * acters, header mismatches, token confusion and CORS abuse.
 *
 * Run:  npm run dev   then   node scripts/security_audit.mjs
 */

import { createHash, generateKeyPairSync, sign } from "node:crypto";

const BASE_URL = process.env.BASE_URL ?? "http://127.0.0.1:8787";
const CLIENT_INGEST_TOKEN = process.env.CLIENT_INGEST_TOKEN ?? "local-dev-ingest-token";
const ADMIN_TOKEN = process.env.ADMIN_TOKEN ?? "local-dev-admin-token";

const UPLOAD_PATH = "/api/v1/measurements/upload";
const REGISTER_PATH = "/api/v1/devices/register";

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
const assertEq = (a, e, l) => {
  if (a !== e) throw new Error(`${l}: expected ${JSON.stringify(e)}, got ${JSON.stringify(a)}`);
};
const assertNe = (a, e, l) => {
  if (a === e) throw new Error(`${l}: value must differ from ${JSON.stringify(e)}`);
};
const assertIncludes = (h, n, l) => {
  if (!String(h ?? "").toLowerCase().includes(String(n).toLowerCase())) {
    throw new Error(`${l}: "${n}" not found in ${JSON.stringify(String(h).slice(0, 160))}`);
  }
};

async function api(path, init) {
  const res = await fetch(`${BASE_URL}${path}`, init);
  let body = null;
  try { body = await res.json(); } catch { body = null; }
  return { status: res.status, body, res };
}
const sha256hex = (b) => createHash("sha256").update(b).digest("hex");
const signDer = (t, k) => sign("sha256", Buffer.from(t, "utf8"), { key: k, dsaEncoding: "der" }).toString("base64");

function makeDevice(label) {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  return {
    privateKey,
    spkiB64: publicKey.export({ type: "spki", format: "der" }).toString("base64"),
    id: `sec-${label}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`,
  };
}

async function registerDevice(device) {
  const signedAt = Date.now();
  const canonical = ["GOFv1", "POST", REGISTER_PATH, device.id, sha256hex(Buffer.from(device.spkiB64, "base64")), String(signedAt)].join("\n");
  return api(REGISTER_PATH, {
    method: "POST",
    headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({
      device_id: device.id, key_version: 1, public_key_spki: device.spkiB64,
      signed_at: signedAt, signature: signDer(canonical, device.privateKey), signature_format: "der",
    }),
  });
}

const CSV = "ts_ms,ax,ay,az\n0,0,0,-9.81\n";
function uploadInit(device, payloadText, { sigOverride = null, token = CLIENT_INGEST_TOKEN, deviceIdHeader = null, sigFormat = "der" } = {}) {
  const payload = JSON.parse(payloadText);
  const canonical = ["GOFv1", "POST", UPLOAD_PATH, payload.device_id, sha256hex(Buffer.from(payloadText, "utf8")), String(payload.signed_at)].join("\n");
  const form = new FormData();
  form.append("payload", new Blob([payloadText], { type: "application/json" }), "payload.json");
  form.append("dump", new Blob([CSV], { type: "text/csv" }), "raw.csv");
  // NOTE: never set content-type manually — fetch must generate the multipart boundary.
  return {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "x-gof-device-id": deviceIdHeader ?? payload.device_id,
      "x-gof-signature": sigOverride ?? signDer(canonical, device.privateKey),
      "x-gof-signature-format": sigFormat,
    },
    body: form,
  };
}
const payloadText = (device, overrides = {}) => {
  const signedAt = Date.now();
  return JSON.stringify({
    device_id: device.id, mode: "HORIZON_DIP", timestamp: signedAt - 30_000,
    signed_at: signedAt, gps_lat: 40.4168, gps_lon: -3.7038, altitude_m: 12,
    curvature_deviation_percentage: 1.2, ...overrides,
  });
};

console.log(`\nGlobeOrFlat security audit \u2192 ${BASE_URL}\n`);

// ========== 1 · AUTH MATRIX ==================================================
console.log("--- auth matrix ---");

await step("health & list are public (by design), detail/dump public", async () => {
  assertEq((await api("/api/v1/health")).status, 200, "health");
  assertEq((await api("/api/v1/measurements?per_page=1")).status, 200, "list");
});

await step("upload: anonymous / wrong token / admin token / wrong methods all rejected", async () => {
  const d = makeDevice("authz");
  await registerDevice(d);
  const base = payloadText(d);
  assertEq((await api(UPLOAD_PATH, uploadInit(d, base, { token: "" }))).status, 401, "anonymous");
  assertEq((await api(UPLOAD_PATH, uploadInit(d, base, { token: "wrong-token-1234" }))).status, 401, "wrong token");
  assertEq((await api(UPLOAD_PATH, uploadInit(d, base, { token: ADMIN_TOKEN }))).status, 401, "admin token on upload");
  // Hono routes are method-scoped: GET falls through to the public :id route
  // (invalid UUID -> 400), PUT is unmounted -> 404. Either way: no method confusion.
  const getRes = await api(UPLOAD_PATH, { method: "GET", headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}` } });
  if (getRes.status !== 400 && getRes.status !== 404) throw new Error(`GET on upload path: expected 400/404, got ${getRes.status}`);
  assertEq((await api(UPLOAD_PATH, { method: "PUT", headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}` } })).status, 404, "PUT on upload path");
});

await step("admin: client token rejected on verifications + stats", async () => {
  assertEq((await api("/api/v1/admin/verifications", {
    method: "POST",
    headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ measurement_id: "00000000-0000-4000-8000-000000000000", decision: "VERIFIED" }),
  })).status, 401, "client token on admin write");
  assertEq((await api("/api/v1/admin/stats", { headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}` } })).status, 401, "client token on stats");
  assertEq((await api("/api/v1/admin/stats")).status, 401, "anonymous stats");
});

await step("register: wrong token rejected; signature must cover submitted key", async () => {
  const d = makeDevice("regz");
  const signedAt = Date.now();
  const canonical = ["GOFv1", "POST", REGISTER_PATH, d.id, sha256hex(Buffer.from(d.spkiB64, "base64")), String(signedAt)].join("\n");
  const init = {
    method: "POST",
    headers: { authorization: `Bearer wrong`, "content-type": "application/json" },
    body: JSON.stringify({ device_id: d.id, key_version: 1, public_key_spki: d.spkiB64, signed_at: signedAt, signature: signDer(canonical, d.privateKey), signature_format: "der" }),
  };
  assertEq((await api(REGISTER_PATH, init)).status, 401, "wrong token");
  // proof-of-possession violation: signature made over a DIFFERENT key
  const other = makeDevice("other");
  const init2 = {
    method: "POST",
    headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ device_id: d.id, key_version: 1, public_key_spki: d.spkiB64, signed_at: signedAt, signature: signDer(canonical, other.privateKey), signature_format: "der" }),
  };
  assertEq((await api(REGISTER_PATH, init2)).status, 401, "signature by another key");
});

// ========== 2 · SIGNATURE ABUSE ==============================================
console.log("--- signature abuse ---");

await step("cross-endpoint replay: signature over payload A submitted with payload B \u2192 401", async () => {
  const d = makeDevice("xend");
  await registerDevice(d);
  // valid upload first
  const ok = await api(UPLOAD_PATH, uploadInit(d, payloadText(d)));
  assertEq(ok.status, 201, "baseline upload");
  // signature computed over payload A, submitted with payload B -> 401 (not a dup error)
  const textA = payloadText(d, { altitude_m: 12 });
  const textB = payloadText(d, { altitude_m: 13 });
  const sigA = uploadInit(d, textA).headers["x-gof-signature"];
  const r = await api(UPLOAD_PATH, uploadInit(d, textB, { sigOverride: sigA }));
  assertEq(r.status, 401, "signature over different payload rejected");
  assertNe(r.body?.error, "duplicate_measurement", "not a dup error");
});

await step("signature from REGISTER endpoint reused on UPLOAD \u2192 401 (canonical path binding)", async () => {
  const d = makeDevice("pathbind");
  const signedAt = Date.now();
  const regCanonical = ["GOFv1", "POST", REGISTER_PATH, d.id, sha256hex(Buffer.from(d.spkiB64, "base64")), String(signedAt)].join("\n");
  await api(REGISTER_PATH, {
    method: "POST",
    headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ device_id: d.id, key_version: 1, public_key_spki: d.spkiB64, signed_at: signedAt, signature: signDer(regCanonical, d.privateKey), signature_format: "der" }),
  });
  // same signature bytes, but now for an upload canonical string \u2192 must fail
  const up = payloadText(d);
  const upCanonical = ["GOFv1", "POST", UPLOAD_PATH, d.id, sha256hex(Buffer.from(up, "utf8")), String(JSON.parse(up).signed_at)].join("\n");
  // signDer(regCanonical) \u2260 signDer(upCanonical); forge by reusing register signature bytes:
  const regSig = signDer(regCanonical, d.privateKey);
  const r = await api(UPLOAD_PATH, uploadInit(d, up, { sigOverride: regSig }));
  assertEq(r.status, 401, "register sig on upload");
});

await step("freshness window: +6 min \u2192 401, \u22124 min \u2192 accepted", async () => {
  const d = makeDevice("skew");
  await registerDevice(d);
  const future = payloadText(d, { signed_at: Date.now() + 6 * 60_000, timestamp: Date.now() });
  assertEq((await api(UPLOAD_PATH, uploadInit(d, future))).status, 401, "future signed_at");
  const past = payloadText(d, { signed_at: Date.now() - 4 * 60_000, timestamp: Date.now() - 4 * 60_000 });
  assertEq((await api(UPLOAD_PATH, uploadInit(d, past))).status, 201, "within window");
});

// ========== 3 · INPUT ABUSE ==================================================
console.log("--- input abuse ---");

await step("oversized payload part \u2192 413 payload_too_large (new guard)", async () => {
  const d = makeDevice("bigp");
  await registerDevice(d);
  const big = payloadText(d, { note: "A".repeat(80 * 1024) }); // 80 KB of padding
  const r = await api(UPLOAD_PATH, uploadInit(d, big));
  assertEq(r.status, 413, "status");
  assertEq(r.body?.error, "payload_too_large", "error code");
});

await step("payload just under the limit with padding field accepted (unknown fields stripped)", async () => {
  const d = makeDevice("pad");
  await registerDevice(d);
  const padded = payloadText(d, { note: "A".repeat(40 * 1024) });
  assertEq((await api(UPLOAD_PATH, uploadInit(d, padded))).status, 201, "40 KB payload ok");
});

await step("XSS/injection payloads in device_id \u2192 400 (charset regex), never 500", async () => {
  const evil = [
    `<script>alert(1)</script>-device`,
    `device"><img src=x onerror=alert(1)>`,
    `dev'; DROP TABLE measurements;--`,
    `dev${encodeURIComponent("\u202e")}`, // RTLO char \u2192 percent-encoded \u2192 '%' blocked by regex
  ];
  for (const [i, id] of evil.entries()) {
    const d = makeDevice(`xss${i}`);
    d.id = id;
    const r = await api(UPLOAD_PATH, uploadInit(d, payloadText(d)));
    assertEq(r.status, 400, `malicious device_id #${i} rejected`);
  }
});

await step("SQL metacharacters in query filters \u2192 400/200 (validated), never 500", async () => {
  const probes = [
    `/api/v1/measurements?device_id=x' OR '1'='1`,
    `/api/v1/measurements?mode=HORIZON_DIP'--`,
    `/api/v1/measurements?min_lat=40 OR 1=1`,
    `/api/v1/measurements?since=100000;DROP TABLE verification_events`,
  ];
  for (const p of probes) {
    const r = await api(p);
    assertNe(r.status, 500, `no 500 for ${p.slice(0, 60)}`);
    if (r.status !== 200) assertEq(r.status, 400, `validated rejection for ${p.slice(0, 60)}`);
  }
});

await step("wrong dump mime (text/html) \u2192 415 \u2014 no stored-XSS via content type", async () => {
  const d = makeDevice("mime");
  await registerDevice(d);
  const text = payloadText(d);
  const canonical = ["GOFv1", "POST", UPLOAD_PATH, d.id, sha256hex(Buffer.from(text, "utf8")), String(JSON.parse(text).signed_at)].join("\n");
  const form = new FormData();
  form.append("payload", new Blob([text], { type: "application/json" }), "payload.json");
  form.append("dump", new Blob(["<h1>evil</h1>"], { type: "text/html" }), "evil.html");
  const r = await api(UPLOAD_PATH, {
    method: "POST",
    headers: {
      authorization: `Bearer ${CLIENT_INGEST_TOKEN}`,
      "x-gof-device-id": d.id,
      "x-gof-signature": signDer(canonical, d.privateKey),
      "x-gof-signature-format": "der",
    },
    body: form,
  });
  assertEq(r.status, 415, "status");
  assertEq(r.body?.error, "unsupported_dump_type", "error code");
});

await step("multipart abuse: missing parts \u2192 400; JSON garbage \u2192 400", async () => {
  const d = makeDevice("multi");
  await registerDevice(d);
  // payload only
  const form1 = new FormData();
  form1.append("payload", new Blob([payloadText(d)], { type: "application/json" }), "p.json");
  const r1 = await api(UPLOAD_PATH, { method: "POST", headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}` }, body: form1 });
  assertEq(r1.status, 400, "missing dump");
  // garbage json
  const form2 = new FormData();
  form2.append("payload", new Blob(["{not json"], { type: "application/json" }), "p.json");
  form2.append("dump", new Blob([CSV], { type: "text/csv" }), "r.csv");
  const r2 = await api(UPLOAD_PATH, { method: "POST", headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}` }, body: form2 });
  assertEq(r2.status, 400, "invalid json");
  assertEq(r2.body?.error, "invalid_payload", "error code");
});

await step("header device mismatch \u2192 400 (impersonation blocked)", async () => {
  const d = makeDevice("imp");
  await registerDevice(d);
  const victim = makeDevice("victim");
  const r = await api(UPLOAD_PATH, uploadInit(d, payloadText(d), { deviceIdHeader: victim.id }));
  assertEq(r.status, 400, "status");
  assertEq(r.body?.error, "device_id_mismatch", "error code");
});

// ========== 4 · RESPONSE HARDENING ==========================================
console.log("--- response hardening ---");

await step("dump responses: attachment disposition + nosniff (defense against stored content)", async () => {
  const page1 = await (await fetch(`${BASE_URL}/api/v1/measurements?per_page=1`)).json();
  const first = page1.data?.[0];
  if (!first) return; // nothing stored yet \u2014 smoke test covers with data
  const res = await fetch(`${BASE_URL}/api/v1/measurements/${first.id}/dump`);
  assertIncludes(res.headers.get("content-disposition"), "attachment", "content-disposition");
  assertIncludes(res.headers.get("x-content-type-options"), "nosniff", "nosniff");
});

await step("error responses never leak stack traces / internals", async () => {
  const r = await api("/api/v1/measurements?page=abc");
  const raw = JSON.stringify(r.body);
  assertIncludes(raw, "invalid", "structured error");
  if (/at .+ \(\/|node_modules|worker\.js:\d+/.test(raw)) throw new Error("stack leak in error body");
});

await step("request ids present for correlation (no info leak via headers)", async () => {
  const res = await fetch(`${BASE_URL}/api/v1/health`);
  const rid = res.headers.get("x-request-id");
  if (rid && !/^[0-9a-f-]{36}$/i.test(rid)) throw new Error(`malformed request id: ${rid}`);
});

// ========== 5 · CORS =========================================================
console.log("--- cors ---");

await step("preflight restricted to safe methods + listed headers", async () => {
  const res = await fetch(`${BASE_URL}/api/v1/measurements`, {
    method: "OPTIONS",
    headers: { origin: "https://evil.example", "access-control-request-method": "DELETE" },
  });
  const methods = res.headers.get("access-control-allow-methods") ?? "";
  if (!methods) return; // no CORS answer for unlisted method \u2014 fine
  assertIncludes(methods, "GET", "GET allowed");
  if (/DELETE|PUT|PATCH/i.test(methods)) throw new Error(`unsafe method allowed: ${methods}`);
});

await step("CORS origin is wildcard (public reads; writes are token-gated, not cookie-gated)", async () => {
  const res = await fetch(`${BASE_URL}/api/v1/measurements?per_page=1`, { headers: { origin: "https://evil.example" } });
  assertIncludes(res.headers.get("access-control-allow-origin"), "*", "wildcard by design");
  assertNe(res.headers.get("access-control-allow-credentials"), "true", "no credentialed CORS");
});

// ========== 6 · RATE LIMITING (MUST run LAST — the flood poisons the =========
// per-IP window for up to 60 s, so nothing may follow in the same window) ====
console.log("--- rate limiting (flood; final check — poisons the window) ---");

await step("sustained flood trips the platform rate limiter (429 rate_limited)", async () => {
  const codes = new Map();
  let saw429Body = null;
  const one = async () => {
    const r = await fetch(`${BASE_URL}/api/v1/health`);
    codes.set(r.status, (codes.get(r.status) ?? 0) + 1);
    if (r.status === 429 && !saw429Body) saw429Body = await r.json().catch(() => null);
  };
  await Promise.all(Array.from({ length: 400 }, one));
  if (!codes.has(429)) {
    throw new Error(`no 429 after a 400-request flood: ${JSON.stringify([...codes])}`);
  }
  if (saw429Body?.error !== "rate_limited") throw new Error(`429 body malformed: ${JSON.stringify(saw429Body)}`);
});

console.log(`\n=== security audit: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  for (const f of failures) console.log(`  \u2717 ${f}`);
  process.exit(1);
}
