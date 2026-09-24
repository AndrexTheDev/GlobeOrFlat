/**
 * GlobeOrFlat Hub — Cloudflare Pages readiness check.
 * SPDX-License-Identifier: MIT
 *
 * Simulates what a Pages deploy runner needs to hold true, without
 * uploading anything:
 *   • every local src/href reference in index.html resolves on disk
 *   • vendored libraries are present (no silent CDN fallbacks)
 *   • _headers parses line-by-line and references real rules
 *   • .assetsignore keeps docs/tests/node_modules out of the upload
 *   • no absolute paths or obvious secrets in shipped files
 *   • total upload size is sane (Pages per-asset limit: 25 MiB)
 *
 * Run: npm run check:pages   (from web/)
 */

const fs = require("fs");
const crypto = require("crypto");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const SHIP_IGNORE = new Set([
  "README.md", "package.json", "package-lock.json", "test", "node_modules",
  "screenshots", ".assetsignore",
]);

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "\u2714" : "\u2718"} ${name}${detail ? " — " + detail : ""}`);
  if (!ok) failed += 1;
}

function shippableFiles(dir = ROOT, base = "") {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".") && entry.name !== "_headers") continue;
    if (SHIP_IGNORE.has(entry.name)) continue;
    const rel = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...shippableFiles(path.join(dir, entry.name), rel));
    else out.push(rel);
  }
  return out;
}

// --- 1) index.html local references resolve --------------------------------
const html = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
// Resource loads only (script/link/img/source) — navigation anchors (<a href>)
// may point anywhere (GitHub repo, releases).
const resourceRefs = [
  ...html.matchAll(/<(?:script|img|source)[^>]+\bsrc="([^"#]+)"/g),
  ...html.matchAll(/<link[^>]+\bhref="([^"#]+)"/g),
].map((m) => m[1]);
const refs = resourceRefs;
const external = refs.filter((r) => /^https?:/.test(r));
const local = refs.filter((r) => !/^https?:/.test(r) && !/^(mailto:|data:)/.test(r));
let ok = true;
for (const ref of local) {
  const p = path.join(ROOT, decodeURIComponent(ref.split("?")[0]));
  if (!fs.existsSync(p)) {
    check(`index.html reference resolves: ${ref}`, false);
    ok = false;
  }
}
if (ok) check(`index.html local references resolve (${local.length})`, true);
console.log(`  external references (allowed, pinned CDNs): ${external.length}`);
// The only permitted external resource host: jsDelivr (Cesium). Anything else is drift.
const externalHosts = [...new Set(external.map((r) => new URL(r).host))];
check(
  "external references limited to pinned CDN(s)",
  externalHosts.every((h) => h === "cdn.jsdelivr.net"),
  externalHosts.join(", "),
);

// --- 2) vendored libraries present ------------------------------------------
for (const v of [
  "assets/vendor/tailwind.browser.js",
  "assets/vendor/leaflet/leaflet.js",
  "assets/vendor/leaflet/leaflet.css",
  "assets/vendor/fonts/orbitron-latin-700-normal.woff2",
  "assets/vendor/fonts/jetbrains-mono-latin-400-normal.woff2",
]) {
  const p = path.join(ROOT, v);
  check(`vendored: ${v}`, fs.existsSync(p) && fs.statSync(p).size > 1024);
}

// --- 3) _headers sanity -------------------------------------------------------
const headersPath = path.join(ROOT, "_headers");
check("_headers present", fs.existsSync(headersPath));
if (fs.existsSync(headersPath)) {
  const lines = fs.readFileSync(headersPath, "utf8").split(/\r?\n/);
  let currentPath = null;
  let headerLines = 0;
  for (const raw of lines) {
    const line = raw.trimEnd();
    if (!line.trim() || line.trim().startsWith("#")) continue;
    if (!line.startsWith(" ")) {
      currentPath = line.trim();
      continue;
    }
    if (!currentPath) {
      check("_headers: header line before any path", false, line.trim());
      continue;
    }
    if (!/^[A-Za-z-]+:\s+\S+/.test(line.trim())) {
      check("_headers: malformed header line", false, line.trim().slice(0, 60));
    }
    headerLines += 1;
  }
  check(`_headers parses (${headerLines} header rules)`, headerLines >= 5);
  const raw = fs.readFileSync(headersPath, "utf8");
  check("_headers sets CSP", /content-security-policy:/i.test(raw));
  check("_headers sets nosniff", /x-content-type-options/i.test(raw));

  // --- 3b) CSP script-hash consistency (index.html <-> _headers) --------------
  // CSP hashes are the SHA-256 digest in the CSP-standard BASE64 form.
  const cspLine = raw.split("\n").find((l) => /content-security-policy:/i.test(l)) || "";
  const listedHashes = [...cspLine.matchAll(/'sha256-([A-Za-z0-9+/=]{44}|[0-9a-f]{64})'/gi)].map((m) => m[1].toLowerCase());
  const html = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
  const inlineBodies = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const inlineHashes = inlineBodies.map((b) =>
    crypto.createHash("sha256").update(Buffer.from(b, "utf8")).digest("base64").toLowerCase(),
  );
  check("CSP script-src drops unsafe-inline", !/script-src[^;]*'unsafe-inline'/i.test(cspLine));
  check("CSP has no unsafe-eval", !/'unsafe-eval'/i.test(cspLine));
  check("CSP keeps wasm-unsafe-eval for Cesium decoders", /'wasm-unsafe-eval'/i.test(cspLine));
  for (const h of inlineHashes) {
    check(`CSP pins inline script sha256:${h.slice(0, 12)}\u2026 (base64 form)`, listedHashes.includes(h));
  }
  for (const h of listedHashes) {
    check(`CSP hash sha256:${h.slice(0, 12)}\u2026 matches an inline script`, inlineHashes.includes(h));
  }
}

// --- 4) .assetsignore coverage -----------------------------------------------
const ignore = fs.existsSync(path.join(ROOT, ".assetsignore"))
  ? fs.readFileSync(path.join(ROOT, ".assetsignore"), "utf8")
  : "";
for (const needed of ["README.md", "package.json", "package-lock.json", "test", "node_modules"]) {
  check(`.assetsignore covers ${needed}`, ignore.includes(needed));
}

// --- 5) no absolute paths / obvious secrets in shipped files -----------------
const files = shippableFiles();
let leak = null;
for (const rel of files) {
  const content = fs.readFileSync(path.join(ROOT, rel), "utf8").slice(0, 400_000);
  if (/(?:^|["'\s])\/(?:home|Users|tmp)\//.test(content)) { leak = `absolute path in ${rel}`; break; }
  if (/sk-(?:live|test)-[0-9a-zA-Z]{16,}/.test(content)) { leak = `secret-like token in ${rel}`; break; }
  if (/BEGIN (?:RSA |EC )?PRIVATE KEY/.test(content)) { leak = `private key in ${rel}`; break; }
}
check("no absolute paths / secrets in shipped files", leak === null, leak || "");

// --- 6) upload size -----------------------------------------------------------
let total = 0;
let oversize = null;
for (const rel of files) {
  const size = fs.statSync(path.join(ROOT, rel)).size;
  total += size;
  if (size > 24 * 1024 * 1024) oversize = rel; // Pages per-asset limit 25 MiB
}
check("no asset near the 25 MiB per-asset limit", oversize === null, oversize || "");
check(
  `upload size sane (${files.length} files, ${(total / 1024 / 1024).toFixed(2)} MB)`,
  total < 20 * 1024 * 1024,
);

console.log(
  failed === 0
    ? "\nALL PAGES READINESS CHECKS PASSED"
    : `\n${failed} PAGES READINESS CHECK(S) FAILED`,
);
process.exit(failed === 0 ? 0 : 1);
