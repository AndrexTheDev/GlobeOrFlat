/** Static mirror with permissive CORS (Cesium worker bootstrap needs it). */
const http = require("http");
const fs = require("fs");
const path = require("path");
const ROOT = process.argv[2] || "/tmp/gof-cesium";
const PORT = Number(process.argv[3] || 8081);
const MIME = {
  ".js": "application/javascript", ".css": "text/css", ".json": "application/json",
  ".png": "image/png", ".jpg": "image/jpeg", ".wasm": "application/wasm",
  ".html": "text/html", ".svg": "image/svg+xml", ".woff2": "font/woff2",
};
http.createServer((req, res) => {
  const urlPath = decodeURIComponent(req.url.split("?")[0]);
  let file = path.join(ROOT, urlPath);
  if (urlPath.endsWith("/")) file = path.join(file, "index.html");
  if (!file.startsWith(ROOT)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404, { "access-control-allow-origin": "*" }); return res.end("not found"); }
    res.writeHead(200, {
      "content-type": MIME[path.extname(file)] || "application/octet-stream",
      "access-control-allow-origin": "*",
      "cache-control": "public, max-age=3600",
    });
    res.end(data);
  });
}).listen(PORT, "0.0.0.0", () => console.log(`mirror ${ROOT} on :${PORT} (CORS *)`));
