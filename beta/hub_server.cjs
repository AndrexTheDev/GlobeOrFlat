/**
 * GlobeOrFlat — local hub server that applies Cloudflare Pages _headers
 * rules, so the beta harness tests the portal exactly as deployed
 * (CSP, nosniff, frame options...). Replaces `python3 -m http.server`.
 * SPDX-License-Identifier: MIT
 *
 * Usage: node beta/hub_server.cjs [webRoot] [port]   (defaults: web/ 8080)
 */
const http = require("http");
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(process.argv[2] || path.join(__dirname, "..", "web"));
const PORT = Number(process.argv[3] || 8080);

// --- parse _headers (path block + indented "Name: value" lines) -------------
const headerRules = [];
{
  const raw = fs.readFileSync(path.join(ROOT, "_headers"), "utf8");
  let current = null;
  for (const line of raw.split("\n")) {
    if (!line.trim() || line.trim().startsWith("#")) continue;
    if (!/^\s/.test(line)) {
      current = { pattern: line.trim(), headers: {} };
      headerRules.push(current);
    } else if (current) {
      const idx = line.indexOf(":");
      if (idx > 0) current.headers[line.slice(0, idx).trim().toLowerCase()] = line.slice(idx + 1).trim();
    }
  }
}

/** Cloudflare Pages glob: `*` matches any characters within the path. */
function ruleApplies(pattern, urlPath) {
  const rx = new RegExp("^" + pattern.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$");
  return rx.test(urlPath);
}

const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css",
  ".json": "application/json", ".png": "image/png", ".svg": "image/svg+xml",
  ".woff2": "font/woff2", ".csv": "text/csv", ".txt": "text/plain", ".map": "application/json",
};

// Sandbox-only: the production worker is https:// and matches the CSP's
// connect-src. Locally it is http://127.0.0.1:8787, so the dev hub needs an
// explicit allowance — set GOF_DEV_CONNECT="http://127.0.0.1:8787 ..." to
// append origins to connect-src. Production _headers stay untouched.
const DEV_CONNECT = (process.env.GOF_DEV_CONNECT || "").trim();

function applyCspDeviation(headers) {
  const csp = headers["content-security-policy"];
  if (!DEV_CONNECT || !csp) return;
  headers["content-security-policy"] = csp.replace(
    /connect-src([^;]*)/,
    (_m, rest) => `connect-src${rest} ${DEV_CONNECT}`,
  );
}

http.createServer((req, res) => {
  const urlPath = decodeURIComponent(req.url.split("?")[0]);
  let file = path.join(ROOT, urlPath === "/" ? "index.html" : urlPath);
  if (!file.startsWith(ROOT)) { res.writeHead(403); return res.end("forbidden"); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404, { "content-type": "text/plain" }); return res.end("not found"); }
    const headers = { "content-type": MIME[path.extname(file)] || "application/octet-stream" };
    for (const rule of headerRules) {
      if (ruleApplies(rule.pattern, urlPath)) Object.assign(headers, rule.headers);
    }
    applyCspDeviation(headers);
    res.writeHead(200, headers);
    res.end(data);
  });
}).listen(PORT, "0.0.0.0", () => {
  console.log(`hub ${ROOT} on :${PORT} (${headerRules.length} _headers rules applied)`);
});
