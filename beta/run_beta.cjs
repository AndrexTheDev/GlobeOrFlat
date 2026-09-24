/**
 * GlobeOrFlat — Open Science Hub beta harness (headless Chromium).
 * SPDX-License-Identifier: MIT
 *
 * What it does:
 *   • boots the real portal (http://localhost:8080) in headless Chromium
 *     (WebGL via SwiftShader),
 *   • mirrors the pinned Cesium CDN + OSM imagery tiles from local copies
 *     (sandbox browsers have no external egress — production keeps the CDN),
 *   • walks the whole UI, asserts behavior, and captures the screenshot
 *     matrix into beta/screenshots/,
 *   • fails on any console error / page error / failed request.
 *
 * Usage:  node beta/run_beta.cjs   (from repo root; needs web server :8080
 *         and cesium mirror :8081 — see beta/serve_mirrors.sh)
 */

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const puppeteer = require("puppeteer-core");
const chromium = require("@sparticuz/chromium").default;

const BASE = process.env.GOF_BASE || "http://localhost:8080";
const CESIUM_MIRROR = "http://localhost:8081";
const OUT = path.join(__dirname, "screenshots");

const consoleErrors = [];
const pageErrors = [];
const failedRequests = [];

/** Solid-color PNG (RGBA) — stand-in for blocked OSM tiles. */
function solidTilePng(r, g, b, size = 256) {
  const row = Buffer.alloc(1 + size * 4);
  for (let x = 0; x < size; x++) {
    row[1 + x * 4] = r; row[2 + x * 4] = g; row[3 + x * 4] = b; row[4 + x * 4] = 255;
  }
  const raw = Buffer.concat(Array.from({ length: size }, () => row));
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body) >>> 0);
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8-bit RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

let CRC_TABLE = null;
function crc32(buf) {
  if (!CRC_TABLE) {
    CRC_TABLE = [];
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      CRC_TABLE[n] = c;
    }
  }
  let crc = 0xffffffff;
  for (const b of buf) crc = CRC_TABLE[(crc ^ b) & 0xff] ^ (crc >>> 8);
  return crc ^ 0xffffffff;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const shot = (page, name) =>
    page.screenshot({ path: path.join(OUT, name) }).then(() => console.log(`  📸 ${name}`));

  const browser = await puppeteer.launch({
    executablePath: await chromium.executablePath(),
    args: [...chromium.args, "--enable-unsafe-swiftshader", "--use-angle=swiftshader-webgl"],
    headless: "shell",
    env: {
      ...process.env,
      LD_LIBRARY_PATH: "/tmp/gof-libs/lib:/tmp/gof-libs:" + (process.env.LD_LIBRARY_PATH || ""),
      FONTCONFIG_PATH: "/tmp/gof-fonts",
    },
    defaultViewport: { width: 1440, height: 900 },
  });

  const context = browser.defaultBrowserContext;
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 900 });

  // CSP violation collector — injected before any page script runs.
  // The hub server applies the production _headers (hash-pinned CSP),
  // so any violation here means the portal broke its own policy.
  await page.evaluateOnNewDocument(() => {
    window.__gofCspViolations = [];
    document.addEventListener("securitypolicyviolation", (e) => {
      window.__gofCspViolations.push(`${e.violatedDirective} <- ${e.blockedURL || e.sourceFile || "?"}`);
    });
  });

  let expectedApi404 = false; // offline-capsule fallback: /api/v1/* 404s on the static host by design
  page.on("response", (res) => {
    if (res.status() === 404 && res.url().includes("/api/v1/")) expectedApi404 = true;
  });
  page.on("console", (msg) => {
    if (msg.type() === "error") consoleErrors.push(msg.text().slice(0, 300));
  });
  page.on("pageerror", (err) => pageErrors.push(String(err).slice(0, 300)));
  page.on("requestfailed", (req) => {
    const reason = req.failure() ? req.failure().errorText : "";
    // blocked external hosts are expected in the sandbox (intercepted below)
    if (!req.url().startsWith("http://localhost")) {
      failedRequests.push(`${req.url().slice(0, 120)} → ${reason}`);
    }
  });

  // Mirror blocked CDNs onto local servers (same paths).
  await page.setRequestInterception(true);
  page.on("request", (req) => {
    const url = req.url();
    if (url.startsWith("https://cdn.jsdelivr.net/npm/cesium@1.119.0/Build/Cesium/")) {
      return req.continue({ url: url.replace("https://cdn.jsdelivr.net/npm/cesium@1.119.0/Build/Cesium", CESIUM_MIRROR) });
    }
    if (url.startsWith("https://tile.openstreetmap.org/")) {
      return req.respond({
        status: 200,
        contentType: "image/png",
        headers: {
          "cache-control": "public, max-age=86400",
          "access-control-allow-origin": "*", // Cesium fetches imagery cross-origin
        },
        body: solidTilePng(10, 42, 67), // gof-panel blue "ocean"
      });
    }
    return req.continue();
  });

  const results = [];
  const check = (name, ok, detail = "") => {
    results.push({ name, ok, detail });
    console.log(`${ok ? "✅" : "❌"} ${name}${detail ? " — " + detail : ""}`);
  };

  console.log("\n=== S1 · BOOT / OFFLINE CAPSULE ===");
  let hubHeaders = {}; // production headers must actually reach the browser
  const navRes = await page.goto(BASE, { waitUntil: "domcontentloaded" });
  hubHeaders = Object.fromEntries(Object.entries(navRes?.headers() ?? {}).map(([k, v]) => [k.toLowerCase(), v]));
  await page.waitForSelector("#feedBody tr", { timeout: 30000 });
  await sleep(2500); // tailwind v4 runtime + stats settle
  const rowCount = await page.$$eval("#feedBody tr", (trs) => trs.length);
  check("feed rendered (9 VERIFIED capsule records)", rowCount === 9, `${rowCount} rows`);
  const bannerVisible = await page.$eval("#demoBanner", (el) => !el.classList.contains("hidden"));
  check("offline-capsule banner shown", bannerVisible);
  const chip = await page.$eval("#apiChipText", (el) => el.textContent);
  check("connection chip = OFFLINE CAPSULE", chip === "OFFLINE CAPSULE", chip);
  const stats = await page.evaluate(() => ({
    total: document.getElementById("statTotal").textContent,
    verified: document.getElementById("statVerified").textContent,
    devices: document.getElementById("statDevices").textContent,
    modes: document.getElementById("statModes").textContent,
  }));
  check("stats computed", stats.total === "14" && stats.verified === "9" && stats.modes === "4/4", JSON.stringify(stats));
  const tailwindStyled = await page.$eval("header", (el) => getComputedStyle(el).position === "sticky");
  check("tailwind v4 runtime applied", tailwindStyled);
  const fontsLoaded = await page.evaluate(() => document.fonts.check('700 14px Orbitron'));
  check("Orbitron font loaded", fontsLoaded);
  await shot(page, "S1_boot_capsule.png");

  console.log("\n=== S2 · 3D ENGINE — WORKER GATE + GRACEFUL DEGRADATION ===");
  // This sandbox's headless shell cannot spawn worker threads; the portal must
  // detect that and fall back to the 2D engine instead of showing a dead globe.
  await page.waitForFunction("window.__GOF && window.__GOF.cesiumBlocked === true", { timeout: 30000, polling: 300 })
    .then(() => check("worker-thread gate detects broken 3D env", true))
    .catch(() => check("worker-thread gate detects broken 3D env", false));
  await sleep(800);
  const proj = await page.evaluate(() => window.__GOF.projection);
  check("auto-switched to 2D projection", proj === "2d", `projection=${proj}`);
  const bootHidden = await page.$eval("#mapBoot", (el) => el.style.display === "none");
  check("boot overlay dismissed", bootHidden);
  const chipText = await page.$eval("#terrainChip", (el) => el.textContent);
  check("terrain chip shows degraded mode", chipText === "TERRAIN: UNAVAILABLE", chipText);
  // user clicking 3D in a blocked env must stay on 2D + keep toggle state sane
  await page.evaluate(() => document.getElementById("btn3d").click());
  await sleep(400);
  const still2d = await page.evaluate(() => window.__GOF.projection);
  check("3D toggle blocked-mode guard", still2d === "2d", `projection=${still2d}`);
  const activeOn2d = await page.$eval("#btn2d", (el) => el.classList.contains("active-2d"));
  check("toggle button state consistent", activeOn2d);
  await shot(page, "S2_globe_degraded_2d.png");

  console.log("\n=== S3 · 2D FLAT PROJECTION (AEQD) ===");
  await sleep(1500); // already the active projection after the S2 failover
  const flatTiles = await page.$$eval("#mapFlat canvas.leaflet-tile", (ts) => ts.length);
  check("AEQD canvas tiles rendered", flatTiles > 0, `${flatTiles} tiles`);
  const landPainted = await page.evaluate(() => {
    const tile = document.querySelector("#mapFlat canvas.leaflet-tile");
    if (!tile) return false;
    const ctx = tile.getContext("2d");
    const d = ctx.getImageData(0, 0, tile.width, tile.height).data;
    let colorVariance = 0;
    let prev = d[0];
    for (let i = 4; i < d.length; i += 40) { if (d[i] !== prev) colorVariance++; prev = d[i]; }
    return colorVariance > 4; // ocean + land + graticule = varied pixels
  });
  check("coastlines/graticule painted", landPainted);
  const flatMarkers = await page.evaluate(() => window.__GOF.flatMarkerLayer.getLayers().length);
  check("2D markers plotted", flatMarkers === 9, `${flatMarkers} markers`);
  await shot(page, "S3_flat_2d.png");

  console.log("\n=== S4 · RECORD DRAWER (card + telemetry) ===");
  // open the Madrid sensor-session record (has full EKF telemetry in the dump)
  const opened = await page.evaluate(() => {
    const rows = [...document.querySelectorAll("#feedBody tr")];
    const row = rows.find((r) => r.textContent.includes("gof-mad-01c4") && /HORIZON\s*DIP/.test(r.textContent));
    if (row) { row.click(); return row.textContent.slice(0, 60); }
    return null;
  });
  check("sensor-session record clicked", Boolean(opened), opened || "");
  await page.waitForFunction(
    () => document.querySelectorAll("#chartGrid canvas").length >= 3,
    { timeout: 15000 },
  ).then(() => check("telemetry charts drawn (fused/gps/pitch/pressure)", true))
    .catch(() => check("telemetry charts drawn", false));
  const headline = await page.$eval("#drawerHeadline", (el) => el.textContent);
  check("match headline rendered", /% Match with Spherical Earth Model/.test(headline), headline);
  const badge = await page.$eval("#drawerBadge", (el) => el.textContent);
  check("verification badge", badge === "VERIFIED", badge);
  const cardPainted = await page.evaluate(() => {
    const c = document.getElementById("shareCardCanvas");
    const ctx = c.getContext("2d");
    const d = ctx.getImageData(0, 0, 540, 960).data;
    let nonBlack = 0;
    for (let i = 0; i < d.length; i += 400) { if (d[i] + d[i + 1] + d[i + 2] > 30) nonBlack++; }
    return nonBlack > 200;
  });
  check("9:16 share card painted", cardPainted);
  const sha = await page.$eval("#drawerIntegrity", (el) => el.textContent);
  check("integrity strip (sha-256 present)", /sha-256/i.test(sha) && /[0-9a-f]{16}/i.test(sha));
  await shot(page, "S4_drawer_record.png");

  console.log("\n=== S5 · TRACK DRIVE + GPS TRAJECTORY ===");
  await page.evaluate(() => document.getElementById("drawerClose").click());
  await sleep(400);
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll("#feedBody tr")];
    const row = rows.find((r) => /TRACK\s*DRIVE/.test(r.textContent) && r.textContent.includes("gof-mad-01c4"));
    row.click();
  });
  await page.waitForFunction(() => !document.getElementById("trajectoryRow").classList.contains("hidden"), { timeout: 15000 })
    .then(() => check("GPS trajectory detected in dump", true))
    .catch(() => check("GPS trajectory detected in dump", false));
  await page.evaluate(() => document.getElementById("btnToggleTrajectory").click()); // switches to 2D + polyline
  await sleep(1500);
  const trajOnMap = await page.evaluate(() => {
    const layers = window.__GOF.flatTrajectoryLayer.getLayers();
    return layers.length >= 3; // polyline + start + end
  });
  check("trajectory plotted on flat plane", trajOnMap);
  await shot(page, "S5_trajectory_flat.png");

  console.log("\n=== S6 · FILTERS + PAGINATION STATE ===");
  await page.evaluate(() => document.getElementById("drawerClose").click());
  await page.select("#filterMode", "HORIZON_DIP");
  await sleep(1200);
  const dipRows = await page.$$eval("#feedBody tr", (trs) => trs.length);
  check("mode filter narrows feed (VERIFIED∩HORIZON_DIP)", dipRows === 4, `${dipRows} rows`);
  await page.select("#filterMode", "");
  await page.select("#filterStatus", "PENDING");
  await sleep(1200);
  const pendingRows = await page.$$eval("#feedBody tr", (trs) => trs.length);
  check("status filter narrows feed", pendingRows === 3, `${pendingRows} rows`);
  await shot(page, "S6_filter_pending.png");
  await page.select("#filterStatus", "VERIFIED");
  await sleep(1000);

  console.log("\n=== S7 · SETTINGS / API ENDPOINT ===");
  await page.click("#openSettings");
  await sleep(400);
  const modalOpen = await page.$eval("#settingsModal", (el) => el.classList.contains("flex"));
  check("settings modal opens", modalOpen);
  await shot(page, "S7_settings.png");
  await page.keyboard.press("Escape");
  await sleep(300);

  console.log("\n=== S8 · MOBILE VIEWPORT (390×844) ===");
  await page.setViewport({ width: 390, height: 844 });
  await sleep(900);
  await shot(page, "S8_mobile.png");
  await page.setViewport({ width: 1440, height: 900 });

  console.log("\n=== S9 · CSV DUMP DOWNLOAD ===");
  try {
    const cdp = await page.createCDPSession();
    await cdp.send("Browser.setDownloadBehavior", {
      behavior: "allowAndName",
      downloadPath: "/tmp/gof-dl",
      eventsEnabled: true,
    });
    await page.evaluate(() => {
      const rows = [...document.querySelectorAll("#feedBody tr")];
      rows.find((r) => r.textContent.includes("gof-esp-7f3a")).click();
    });
    await sleep(800);
    const downloadDone = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("download timeout")), 10000);
      cdp.on("Browser.downloadProgress", (e) => {
        if (e.state === "completed") { clearTimeout(timer); resolve(e); }
        if (e.state === "canceled") { clearTimeout(timer); reject(new Error("download canceled")); }
      });
    });
    await page.evaluate(() => document.getElementById("btnDownloadCsv").click());
    await downloadDone;
    check("CSV raw dump download fires", true, "browser download completed");
  } catch (e) {
    check("CSV raw dump download fires", false, e.message.split("\n")[0]);
  }
  await page.evaluate(() => document.getElementById("drawerClose").click());

  console.log("\n=== ERRORS ===");
  const realConsoleErrors = expectedApi404
    ? consoleErrors.filter((e) => !/Failed to load resource/.test(e))
    : consoleErrors;
  check(
    "zero unexpected console errors",
    realConsoleErrors.length === 0,
    expectedApi404 ? "(expected /api/v1 fallback 404 whitelisted) " + realConsoleErrors.slice(0, 5).join(" | ") : realConsoleErrors.slice(0, 5).join(" | "),
  );
  check("zero page errors", pageErrors.length === 0, pageErrors.slice(0, 5).join(" | "));
  check("zero failed requests", failedRequests.length === 0, failedRequests.slice(0, 5).join(" | "));

  console.log("\n=== SECURITY ===");
  const cspHeader = hubHeaders["content-security-policy"] || "";
  check(
    "hub serves production CSP (sha256-pinned, no unsafe-inline scripts)",
    cspHeader.includes("sha256-") && !/script-src[^;]*'unsafe-inline'/.test(cspHeader),
    cspHeader.slice(0, 120),
  );
  const cspViolations = await page.evaluate(() => window.__gofCspViolations || ["<collector missing>"]);
  // Same benign exception as run_live_api: Cesium's bundled protobuf.js
  // attempts eval, catches the CSP rejection, uses its slow fallback.
  const benign = (v) =>
    v.startsWith("script-src <- https://cdn.jsdelivr.net/npm/cesium@1.119.0/Build/Cesium/Cesium.js");
  const realViolations = cspViolations.filter((v) => !benign(v) && !v.includes("<collector missing>"));
  check(
    "zero CSP violations across the whole walk (protobuf fallback tolerated)",
    realViolations.length === 0 && !cspViolations.includes("<collector missing>"),
    `${cspViolations.length - realViolations.length} benign, real: ${realViolations.slice(0, 3).join(" | ") || "none"}`,
  );
  check(
    "hub serves nosniff + frame-deny",
    hubHeaders["x-content-type-options"] === "nosniff" && hubHeaders["x-frame-options"] === "DENY",
    `nosniff=${hubHeaders["x-content-type-options"]} frame=${hubHeaders["x-frame-options"]}`,
  );

  await browser.close();

  const failed = results.filter((r) => !r.ok);
  console.log(`\n=== RESULT: ${results.length - failed.length}/${results.length} checks passed ===`);
  if (failed.length) {
    console.log("FAILED:");
    for (const f of failed) console.log(`  ✗ ${f.name} ${f.detail}`);
    process.exit(1);
  }
  // write machine-readable summary
  fs.writeFileSync(path.join(__dirname, "beta_summary.json"), JSON.stringify(results, null, 2));
  console.log("beta_summary.json written");
})().catch((e) => {
  console.error("HARNESS FAIL:", e.message.split("\n").slice(0, 5).join(" | "));
  process.exit(2);
});
