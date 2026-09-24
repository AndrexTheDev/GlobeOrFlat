/**
 * GlobeOrFlat — cross-module integration beta: web hub ⇄ live worker.
 * SPDX-License-Identifier: MIT
 *
 * Boots the Open Science Hub against a REAL `wrangler dev` worker (D1 + R2
 * local emulation) via the ?api= parameter and asserts the full chain:
 * live chip, real records from D1, record drawer over the public dump route
 * (R2 stream), integrity strip with the actual SHA-256, filters, stats.
 *
 * Usage: node beta/run_live_api.cjs   (needs :8080 static hub + :8787 worker)
 */

const fs = require("fs");
const path = require("path");
const { createHash, generateKeyPairSync, sign } = require("node:crypto");
const puppeteer = require("puppeteer-core");
const chromium = require("@sparticuz/chromium").default;

const HUB = "http://localhost:8080";
const API = "http://127.0.0.1:8787";
const CLIENT_INGEST_TOKEN = process.env.CLIENT_INGEST_TOKEN ?? "local-dev-ingest-token";
const ADMIN_TOKEN = process.env.ADMIN_TOKEN ?? "local-dev-admin-token";
const OUT = path.join(__dirname, "screenshots");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sha256hex = (b) => createHash("sha256").update(b).digest("hex");
const signDer = (t, k) => sign("sha256", Buffer.from(t, "utf8"), { key: k, dsaEncoding: "der" }).toString("base64");

/** Ingest + admin-verify one fresh record so the live test is self-contained. */
async function seedVerifiedRecord() {
  const id = `live-seed-${Date.now()}`;
  const kp = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const spki = kp.publicKey.export({ type: "spki", format: "der" }).toString("base64");

  // 1) register (proof-of-possession with the registered key itself)
  let signedAt = Date.now();
  let canonical = ["GOFv1", "POST", "/api/v1/devices/register", id, sha256hex(Buffer.from(spki, "base64")), String(signedAt)].join("\n");
  let res = await fetch(`${API}/api/v1/devices/register`, {
    method: "POST",
    headers: { authorization: `Bearer ${CLIENT_INGEST_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ device_id: id, key_version: 1, public_key_spki: spki, signed_at: signedAt, signature: signDer(canonical, kp.privateKey), signature_format: "der" }),
  });
  if (res.status !== 201) throw new Error(`register failed: ${res.status}`);

  // 2) upload a signed HORIZON_DIP measurement with a real annotated dump
  const csv = [
    "# horizon_dip,altitude_m=42.00",
    "# horizon_dip,measured_arcmin=6.9000",
    "# horizon_dip,predicted_arcmin=6.8797",
    "# horizon_dip,flat_model_arcmin=0",
    "# horizon_dip,deviation_pct=0.29",
    "# horizon_dip,columns=ts_ms,fused_alt,pitch",
    "0,42.0,6.90",
    "1000,42.0,6.88",
    "2000,42.1,6.91",
  ].join("\n");
  const payloadText = JSON.stringify({
    device_id: id, mode: "HORIZON_DIP",
    timestamp: Date.now() - 60_000, signed_at: Date.now(),
    gps_lat: 38.4167, gps_lon: -9.2167, altitude_m: 42,
    curvature_deviation_percentage: 0.29,
  });
  canonical = ["GOFv1", "POST", "/api/v1/measurements/upload", id, sha256hex(Buffer.from(payloadText, "utf8")), String(JSON.parse(payloadText).signed_at)].join("\n");
  const form = new FormData();
  form.append("payload", new Blob([payloadText], { type: "application/json" }), "payload.json");
  form.append("dump", new Blob([csv], { type: "text/csv" }), "raw.csv");
  res = await fetch(`${API}/api/v1/measurements/upload`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${CLIENT_INGEST_TOKEN}`,
      "x-gof-device-id": id,
      "x-gof-signature": signDer(canonical, kp.privateKey),
      "x-gof-signature-format": "der",
    },
    body: form,
  });
  const up = await res.json();
  if (res.status !== 201) throw new Error(`upload failed: ${res.status} ${JSON.stringify(up)}`);

  // 3) moderator appends VERIFIED to the append-only ledger
  res = await fetch(`${API}/api/v1/admin/verifications`, {
    method: "POST",
    headers: { authorization: `Bearer ${ADMIN_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ measurement_id: up.id, decision: "VERIFIED", reason: "live-integration seed", decided_by: "beta-runner" }),
  });
  if (res.status !== 201) throw new Error(`verify failed: ${res.status}`);
  return { id: up.id, deviceId: id };
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await puppeteer.launch({
    executablePath: await chromium.executablePath(),
    args: [...chromium.args.filter((a) => !a.startsWith("--single-process")), "--enable-unsafe-swiftshader"],
    headless: "shell",
    env: {
      ...process.env,
      LD_LIBRARY_PATH: "/tmp/gof-libs/lib:/tmp/gof-libs:" + (process.env.LD_LIBRARY_PATH || ""),
      FONTCONFIG_PATH: "/tmp/gof-fonts",
    },
    defaultViewport: { width: 1440, height: 900 },
  });

  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));

  const results = [];
  const check = (name, ok, detail = "") => {
    results.push({ name, ok, detail });
    console.log(`${ok ? "✅" : "❌"} ${name}${detail ? " — " + detail : ""}`);
  };

  // Mirror the pinned Cesium CDN (sandbox has no egress); let API traffic pass.
  await page.setRequestInterception(true);
  page.on("request", (req) => {
    const url = req.url();
    if (url.startsWith("https://cdn.jsdelivr.net/npm/cesium@1.119.0/Build/Cesium/")) {
      return req.continue({ url: url.replace("https://cdn.jsdelivr.net/npm/cesium@1.119.0/Build/Cesium", "http://localhost:8081") });
    }
    if (url.startsWith("https://tile.openstreetmap.org/")) {
      return req.respond({
        status: 200,
        contentType: "image/png",
        headers: { "access-control-allow-origin": "*" },
        body: Buffer.from(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
          "base64",
        ),
      });
    }
    return req.continue();
  });

  console.log("\n=== LIVE INTEGRATION: hub \u2194 wrangler dev (D1 + R2) ===");
  const seeded = await seedVerifiedRecord();
  console.log(`  (seeded VERIFIED record ${seeded.id} via real ingest + ledger)`);
  await page.goto(`${HUB}/?api=${API}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(
    () => window.__GOF && (window.__GOF.mode === "live" || window.__GOF.mode === "demo"),
    { timeout: 30000, polling: 400 },
  );
  const mode = await page.evaluate(() => window.__GOF.mode);
  check("hub connected to live worker (?api=)", mode === "live", `mode=${mode}`);

  const chip = await page.$eval("#apiChipText", (el) => el.textContent);
  // security hardening: a custom endpoint is always surfaced as "… · CUSTOM"
  check("connection chip = API LIVE", chip === "API LIVE" || chip === "API LIVE · CUSTOM", chip);

  const bannerHidden = await page.$eval("#demoBanner", (el) => el.classList.contains("hidden"));
  check("offline-capsule banner hidden", bannerHidden);

  await sleep(1800);
  const stats = await page.evaluate(() => ({
    total: document.getElementById("statTotal").textContent,
    verified: document.getElementById("statVerified").textContent,
  }));
  check("stats reflect real D1 data", Number(stats.total) >= 1 && Number(stats.verified) >= 1, `total=${stats.total} verified=${stats.verified}`);

  // feed rows: default status filter on the live feed is VERIFIED
  // the feed table renders device_id (not the measurement uuid)
  const deviceTag = seeded.deviceId.slice(0, 18);
  await page.waitForFunction(
    (tag) => [...document.querySelectorAll("#feedBody tr")].some((tr) => tr.textContent.includes(tag)),
    { timeout: 15000, polling: 400 },
    deviceTag,
  ).catch(() => {});
  const seededRow = await page.evaluate((tag) => {
    const tr = [...document.querySelectorAll("#feedBody tr")].find((t) => t.textContent.includes(tag));
    if (!tr) return false;
    tr.click();
    return true;
  }, deviceTag);
  check("seeded VERIFIED record in live feed", seededRow);

  // open the record → drawer over the real R2 dump stream
  await sleep(2500);
  const drawerOpen = await page.$eval("#drawer", (el) => el.classList.contains("open"));
  check("record drawer opens on live record", drawerOpen);

  const integrity = await page.$eval("#drawerIntegrity", (el) => el.textContent);
  check("integrity strip shows real sha-256", /[0-9a-f]{32}/i.test(integrity), integrity.slice(0, 90));

  const csvHref = await page.$eval("#btnDownloadCsv", (el) => el.href);
  check("CSV button points at worker dump route", csvHref.includes(":8787/api/v1/measurements/") && csvHref.endsWith("/dump"), csvHref.slice(0, 80));

  // the annotated dump (predicted_arcmin etc.) must refine the comparison matrix
  await sleep(1000);
  const matrix = await page.$eval("#drawerMatrix", (el) => el.textContent);
  check("comparison matrix uses dump annotations", /arcmin/.test(matrix), matrix.slice(0, 120));

  // status filter switch → PENDING rows from D1
  await page.evaluate(() => document.getElementById("drawerClose").click());
  await page.select("#filterStatus", "PENDING");
  await sleep(1800);
  const pendingCount = await page.$$eval("#feedBody tr", (trs) => trs.length);
  check("live PENDING filter returns rows (audit uploads)", pendingCount >= 1, `${pendingCount} rows`);
  const pendingBadges = await page.$$eval("#feedBody .badge-PENDING", (els) => els.length);
  check("badges reflect PENDING status", pendingBadges >= 1, `${pendingBadges} badges`);

  await page.screenshot({ path: path.join(OUT, "L1_live_api_integration.png") });
  console.log("  📸 L1_live_api_integration.png");

  check("zero page errors (live run)", errors.length === 0, errors.slice(0, 3).join(" | "));

  await browser.close();
  const failed = results.filter((r) => !r.ok);
  console.log(`\n=== LIVE INTEGRATION: ${results.length - failed.length}/${results.length} passed ===`);
  if (failed.length) process.exit(1);
})().catch((e) => {
  console.error("HARNESS FAIL:", e.message.split("\n").slice(0, 4).join(" | "));
  process.exit(2);
});
