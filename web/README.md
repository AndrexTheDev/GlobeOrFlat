# GlobeOrFlat — Open Science Hub (web portal)

Zero-build public SPA over the append-only Cloudflare D1 API. No bundler,
no runtime npm dependencies: **Tailwind v4 (browser build), Leaflet and the
HUD fonts are vendored** under `assets/vendor/` — only Cesium (~1 MB gzip
loader + workers) streams from the pinned jsDelivr CDN.

```
web/
├── index.html                     SPA shell (Tailwind Play CDN + HUD chrome)
├── styles.css                     cyberpunk HUD styling (matches the app)
├── app.js                         feed, dual-projection engine, drawer, card
├── assets/land_aeqd.json          Natural Earth 110m coastlines pre-projected
│                                  to north-pole Azimuthal Equidistant meters
├── assets/demo-measurements.json  bundled synthetic "OFFLINE CAPSULE" dataset
│                                  (clearly labeled — used only when the API
│                                  is unreachable)
├── package.json                   scripts + commonjs scope for node tests
└── test/helpers.test.js           node asserts on the pure helpers
```

## Run locally

```bash
cd web
npm start            # python3 http.server on :8080
# or any static server; open http://localhost:8080
```

Tests (no framework):

```bash
npm test             # node test/helpers.test.js
```

## Point it at a live API node

The hub reads `GET /api/v1/measurements` (default `status=VERIFIED`,
`per_page=100`) and `GET /api/v1/measurements/:id/dump` for the raw CSV.
CORS on the worker is `*`, so any origin works.

Three ways to set the endpoint (priority order):

1. URL parameter — `?api=https://globeorflat-api.<subdomain>.workers.dev`
2. The **API SETTINGS** dialog (or the connection chip) — saved to
   `localStorage` (`gof_api_base`).
3. Same-origin: leave empty when the portal is deployed **as a Worker static
   asset next to the API** (below).

Optional: set a **Cesium Ion token** in the same dialog
(`localStorage.gof_ion_token`, never committed) to stream real
digital-elevation world terrain. Without it the 3D view uses the smooth
ellipsoid + OpenStreetMap imagery.

## Beta harness (headless browser matrix)

`../beta/run_beta.cjs` boots the real portal in headless Chromium (SwiftShader
WebGL), walks the entire UI — capsule boot, projection toggle & worker-gate
degradation, AEQD tile rendering, record drawer (share card + telemetry
charts), GPS trajectory, filters, settings, mobile viewport, CSV download —
and fails on any console/page error. Requires the API host to 404 (offline
capsule mode) and optionally the local Cesium mirror (`serve_mirrors.sh`).
Screenshots land in `../beta/screenshots/`, per-check results in
`../beta/beta_summary.json`.

```bash
node ../beta/run_beta.cjs     # 30 checks
npm test                      # pure-helper unit asserts
```

## 3D engine degradation (worker gate)

Cesium builds globe geometry in web workers. On hosts where worker threads
are unavailable (hardened kiosk browsers, some sandboxes), a plain Cesium
boot shows a dead black sphere — so the hub probes worker support first and
**degrades to the 2D engine** with an explanatory toast; the 3D toggle stays
guarded. In normal browsers the full Cesium globe boots as usual.

## Deploy

### Option A — static host (GitHub Pages, Netlify, R2 …)

Upload the `web/` directory as-is and set the API endpoint via `?api=` or
the settings dialog.

### Option B — same origin as the API (recommended)

Cloudflare Workers can serve static assets next to the worker script. Add to
`wrangler.toml`:

```toml
[assets]
directory = "./web"
# worker still handles /api/* — asset requests never reach it
```

Then `npm run deploy` serves the hub at the worker's origin with
`apiBase = ""` (same-origin) working out of the box.

## Engineering notes

- **2D flat engine** — `Leaflet` with a custom CRS implementing the
  north-pole **Azimuthal Equidistant** projection (the flat-Earth model's
  canonical plane, UN-flag layout: Greenwich meridian points down, Americas
  west). The tile set is generated **client-side** by an `L.GridLayer`
  canvas painter from `assets/land_aeqd.json` (126 pre-projected rings,
  95 KB, rounded to 500 m). To use a remote AEQD XYZ tile server instead,
  swap the `AeqdTiles` layer for `L.tileLayer('<url>', { crs })` — the CRS
  already matches `+proj=aeqd +lat_0=90 +R=6378137`.
- **3D globe engine** — pinned `cesium@1.119.0` from jsDelivr; boots lazily
  on first activation; measurement points are `CLAMP_TO_GROUND` entities
  colored by verification status; per-sample GPS trajectories from raw dumps
  render as dashed polylines on both engines.
- **Raw telemetry** — the record drawer fetches the public `/dump` CSV and
  parses it with the exact on-device conventions (`#` annotations,
  `columns=` list, `# track_point` rows); charts are hand-rolled HUD
  canvases (no chart lib).
- **Share card** — canvas mirror of the mobile `ShareCardPainter`
  (540×960 logical, exported at 2× = 1080×1920) with native
  `navigator.share` / clipboard fallback.
- **Verdict + match ladder** — exact port of the app's
  `MeasurementSummary` semantics ("99.4% Match with Spherical Earth
  Model"), locked formulas mirrored from `earth_curvature.dart`
  (1.06′·√h; (d−3.57√h)²/(2R_eff), k=0.14; 0.0785·s²).
- **Tailwind** — Play CDN for zero-build convenience; for a hardened
  production deploy compile once with the Tailwind CLI and replace the CDN
  script tag.
