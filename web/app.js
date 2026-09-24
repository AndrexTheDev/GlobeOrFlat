/**
 * GlobeOrFlat — Open Science Hub (SPA)
 * SPDX-License-Identifier: MIT
 *
 * Interfaces with the Cloudflare Worker API (worker.ts, CORS: *):
 *   GET /api/v1/measurements           → { data[], pagination{} }
 *   GET /api/v1/measurements/:id       → row + raw_dump{download_url, proxy_url}
 *   GET /api/v1/measurements/:id/dump  → raw sensor CSV stream (public)
 *
 * Engines:
 *   • 3D — Cesium.js globe (OSM imagery + ellipsoid terrain by default;
 *     optional Cesium Ion token → real digital-elevation world terrain).
 *   • 2D — Leaflet.js on a custom north-pole Azimuthal Equidistant CRS
 *     (the flat-Earth model's plane). Coastlines (Natural Earth 110m via
 *     world-atlas) are pre-projected into AEQD meters and rendered as a
 *     client-side canvas tile set — no external tile server needed.
 *
 * Pure helpers (CSV dump parser, verdict ladder, AEQD math, model-expectation
 * mirrors of the locked app formulas) are node-testable — see the module
 * exports guard at the bottom.
 */

/* global L, Cesium */

// ===========================================================================
// 0 · CONFIG
// ===========================================================================

const GITHUB_REPO = "https://github.com/AndrexTheDev/GlobeOrFlat";

const GOF_CONFIG = {
  /** API base — ?api= URL param > localStorage > "" (same origin). */
  apiBase: "",
  perPage: 100,
  fetchTimeoutMs: 12000,
  demoDataset: "assets/demo-measurements.json",
  landData: "assets/land_aeqd.json",
};

(function loadConfig() {
  if (typeof window === "undefined" || typeof localStorage === "undefined") return;
  try {
    GOF_CONFIG.apiBase =
      new URLSearchParams(window.location.search).get("api") ||
      localStorage.getItem("gof_api_base") ||
      "";
    GOF_CONFIG.ionToken = localStorage.getItem("gof_ion_token") || "";
  } catch (e) {
    /* private mode — defaults are fine */
  }
})();

// ===========================================================================
// 1 · PURE HELPERS (no DOM — node-testable)
// ===========================================================================

const R_EARTH_M = 6371000.0; // kEarthRadiusMeters (locked)
const REFRACTION_K = 0.14; // kRefractionK (locked)
const R_EFFECTIVE_M = R_EARTH_M / (1.0 - REFRACTION_K); // 7,408,139.5 m

/** Mirrors earth_curvature.dart — horizon dip θ ≈ 1.06′·√h (h in m). */
function horizonDipArcminutes(hMeters) {
  return 1.06 * Math.sqrt(Math.max(hMeters, 0));
}

/** Mirrors hiddenHeightMeters: (d − 3.57·√h_obs)² / (2·R_eff), km in. */
function hiddenHeightMeters(observerHm, distanceKm) {
  const dObs = 3.57 * Math.sqrt(Math.max(observerHm, 0));
  const s = (distanceKm - dObs) * 1000.0; // m
  if (s <= 0) return 0;
  return (s * s) / (2.0 * R_EFFECTIVE_M);
}

/** Mirrors the drop rule: ≈ 0.0785 · s² (s in km → m). */
function curvatureDropMeters(distanceKm) {
  return 0.0785 * distanceKm * distanceKm;
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/**
 * Verdict + match ladder — exact mirror of MeasurementSummary in the app:
 * point modes match = clamp(100 − |dev|); track = clamp(100 − max(0, dev)).
 */
function matchPercent(deviationPct, mode) {
  if (deviationPct === null || deviationPct === undefined || Number.isNaN(deviationPct)) return null;
  const dev = mode === "TRACK_DRIVE" ? Math.max(0, deviationPct) : Math.abs(deviationPct);
  return clamp(100 - dev, 0, 100);
}

function verdictFor(deviationPct, mode, verificationStatus) {
  const match = matchPercent(deviationPct, mode);
  if (match === null) {
    const paired = mode === "TRACK_DRIVE" ? "AWAITING PAIRED SITE" : "INCONCLUSIVE";
    return { label: paired, color: "#9d7bff", match: null, headline: null };
  }
  let label;
  let color;
  if (match >= 95) { label = "STRONG GLOBE MATCH"; color = "#4cff87"; }
  else if (match >= 75) { label = "GLOBE CONSISTENT"; color = "#18e0ff"; }
  else if (match >= 50) { label = "AMBIGUOUS"; color = "#ffb454"; }
  else { label = mode === "TRACK_DRIVE" ? "DEVIATES FROM GLOBE (FLAT FITS BETTER)" : "DEVIATES FROM GLOBE"; color = "#e93eff"; }
  const headline = `${match.toFixed(1)}% Match with Spherical Earth Model`;
  return { label, color, match, headline, status: verificationStatus };
}

const MODE_META = {
  HORIZON_DIP: { label: "HORIZON DIP", unit: "arcmin", glyph: "◐", color: "#18e0ff" },
  WATER_SIGHTLINE: { label: "WATER SIGHTLINE", unit: "m hidden", glyph: "≈", color: "#35d0ff" },
  TRACK_DRIVE: { label: "TRACK DRIVE", unit: "m rms", glyph: "⇥", color: "#e93eff" },
  ERATOSTHENES: { label: "ERATOSTHENES", unit: "%", glyph: "☉", color: "#ffb454" },
};

const STATUS_COLOR = {
  VERIFIED: "#4cff87",
  PENDING: "#ffb454",
  FLAGGED: "#9d7bff",
  REJECTED: "#e93eff",
};

/**
 * Best-effort Measured/Globe/Flat expectation rows for an API record.
 * Mirrors the locked public formulas; refines itself when the raw dump is
 * parsed (annotations carry distance/rms values the API row lacks).
 */
function deriveComparison(rec, dump) {
  const mode = rec.mode;
  const ann = dump ? dump.annotations : {};
  const num = (k) => {
    const v = ann[k];
    return v === undefined || v === "" ? null : Number(v);
  };
  const dev = rec.curvature_deviation_percentage;
  const fromDev = (expected) =>
    dev === null || expected === null ? null : expected * (1 + dev / 100);

  if (mode === "HORIZON_DIP") {
    const globe = num("predicted_arcmin") ?? horizonDipArcminutes(rec.altitude_m);
    const measured = num("measured_arcmin") ?? fromDev(globe);
    return {
      unit: "arcmin",
      measured, globe, flat: num("flat_model_arcmin") ?? 0,
      note: "θ ≈ 1.06′·√h — flat model predicts zero dip",
    };
  }
  if (mode === "WATER_SIGHTLINE") {
    const dKm = num("distance_km");
    const hObs = num("observer_height_m") ?? 2;
    const globe =
      num("predicted_hidden_m") ?? (dKm !== null ? hiddenHeightMeters(hObs, dKm) : null);
    return {
      unit: "m hidden",
      measured: num("measured_hidden_m") ?? fromDev(globe),
      globe,
      flat: num("flat_model_hidden_m") ?? 0,
      note: dKm !== null
        ? `(d − 3.57√h_obs)²/(2·R_eff), k = 0.14 · d = ${dKm} km`
        : "(d − 3.57√h_obs)²/(2·R_eff), k = 0.14",
    };
  }
  if (mode === "TRACK_DRIVE") {
    const rg = num("rms_vs_globe_m");
    if (rg !== null) {
      return {
        unit: "m rms",
        measured: rg, globe: 0, flat: num("rms_vs_flat_m"),
        note: "rms residual of the fused altitude profile vs each model",
      };
    }
    return { unit: "% deviation", measured: dev, globe: 0, flat: null, note: "rms annotations not in dump" };
  }
  // ERATOSTHENES — solar geometry; stick/shadow is the measured datum.
  const ratio = num("shadow_over_stick");
  return {
    unit: "% deviation",
    measured: dev,
    globe: 0,
    flat: null,
    note: ratio !== null
      ? `shadow/stick = ${ratio} · solar-noon geometry fit`
      : "circumference fit vs solar ephemeris",
  };
}

/**
 * Parser for the on-device raw sensor CSV dumps.
 * Conventions (identical to the Android client):
 *   • lines starting with '#' are annotations: "# <key>,<k>=<v>,…" and
 *     "# track_point,<v>,<v>,…" (TRACK_DRIVE per-point rows);
 *   • the `columns=` annotation names the data-row columns (first token is
 *     the mode key and is skipped);
 *   • all other non-empty lines are data rows.
 */
function parseDump(text) {
  const annotations = {};
  const trackPoints = [];
  const rows = [];
  let columns = null;

  for (const rawLine of String(text || "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    if (line.startsWith("#")) {
      const body = line.slice(1).trim();
      const parts = body.split(",");
      const key = parts[0];
      if (key === "track_point") {
        trackPoints.push(parts.slice(1).map((v) => (v === "" ? null : Number(v))));
        continue;
      }
      // "# <mode>,columns=a,b,..." — the list runs to end of line.
      const colEq = parts.findIndex((p, i) => i > 0 && p.startsWith("columns="));
      if (colEq > 0) {
        const rest = body.slice(body.indexOf("columns=") + 8);
        columns = rest.split(",").map((c) => c.trim()).filter(Boolean);
        for (let i = 1; i < colEq; i++) {
          const eq = parts[i].indexOf("=");
          if (eq > 0) annotations[parts[i].slice(0, eq)] = parts[i].slice(eq + 1);
        }
        continue;
      }
      for (let i = 1; i < parts.length; i++) {
        const eq = parts[i].indexOf("=");
        if (eq > 0) annotations[parts[i].slice(0, eq)] = parts[i].slice(eq + 1);
      }
      continue;
    }
    rows.push(line.split(",").map((v) => (v.trim() === "" ? null : Number(v))));
  }
  return { annotations, columns, rows, trackPoints };
}

/** Extract plottable numeric series from a parsed dump. */
function dumpSeries(dump) {
  const out = [];
  const cols = dump.columns || [];
  const idx = (name) => cols.indexOf(name);

  const pushSeries = (xCol, yCol, color, label) => {
    const xi = idx(xCol);
    const yi = idx(yCol);
    if (xi < 0 || yi < 0) return;
    const pts = [];
    for (const r of dump.rows) {
      if (r[xi] === null || r[yi] === null) continue;
      pts.push([r[xi], r[yi]]);
    }
    if (pts.length >= 2) out.push({ label, color, points: pts });
  };

  if (idx("ts_ms") >= 0) {
    pushSeries("ts_ms", "fused_alt", "#18e0ff", "FUSED ALT (m)");
    pushSeries("ts_ms", "gps_alt", "#4cff87", "GPS ALT (m)");
    pushSeries("ts_ms", "pitch", "#e93eff", "PITCH (°)");
    pushSeries("ts_ms", "pressure_hpa", "#ffb454", "PRESSURE (hPa)");
  } else if (dump.trackPoints.length >= 2) {
    const ptsA = [];
    const ptsB = [];
    for (const p of dump.trackPoints) {
      if (p[0] === null) continue;
      if (p[1] !== null) ptsA.push([p[0], p[1]]);
      if (p[2] !== null) ptsB.push([p[0], p[2]]);
    }
    if (ptsA.length >= 2) out.push({ label: "FUSED ALT (m)", color: "#18e0ff", points: ptsA });
    if (ptsB.length >= 2) out.push({ label: "GPS ALT (m)", color: "#4cff87", points: ptsB });
  }
  return out;
}

/** GPS trajectory in a dump: per-sample gps_lat/gps_lon columns, or
 *  `# track_point` annotation rows whose arity matches the columns list. */
function dumpTrajectory(dump) {
  if (!dump || !dump.columns) return null;
  const li = dump.columns.indexOf("gps_lat");
  const gi = dump.columns.indexOf("gps_lon");
  if (li < 0 || gi < 0) return null;
  const coords = [];
  if (dump.rows.length > 0) {
    for (const r of dump.rows) {
      if (r[li] === null || r[gi] === null) continue;
      coords.push([r[li], r[gi]]);
    }
  } else if (dump.trackPoints.length > 0 && dump.trackPoints[0].length === dump.columns.length) {
    for (const p of dump.trackPoints) {
      if (p[li] === null || p[gi] === null) continue;
      coords.push([p[li], p[gi]]);
    }
  }
  const distinct = new Set(coords.map((c) => `${c[0].toFixed(4)},${c[1].toFixed(4)}`));
  return distinct.size >= 2 ? coords : null;
}

// --- Azimuthal Equidistant (north-pole) plane math --------------------------

const AEQD_R = 6378137; // sphere — MUST match assets/land_aeqd.json
const AEQD_MAX_R = Math.PI * AEQD_R;

/** lat/lng degrees → [x, y] meters. x east, y south (Greenwich meridian down). */
function aeqdProject(lat, lng) {
  const c = ((90 - lat) * Math.PI) / 180; // colatitude
  const r = c * AEQD_R;
  const lam = (lng * Math.PI) / 180;
  return [r * Math.sin(lam), r * Math.cos(lam)];
}

/** [x, y] meters → [lat, lng] degrees. */
function aeqdUnproject(x, y) {
  const r = Math.hypot(x, y);
  const lat = 90 - (r / AEQD_R) * (180 / Math.PI);
  let lng = (Math.atan2(x, y) * 180) / Math.PI;
  if (lng > 180) lng -= 360;
  if (lng < -180) lng += 360;
  return [lat, lng];
}

// --- formatting --------------------------------------------------------------

const shortId = (id) => String(id || "").slice(0, 8);
const fmtNum = (v, dp = 2) => (v === null || v === undefined || Number.isNaN(v) ? "—" : Number(v).toFixed(dp));
const fmtDate = (iso) => {
  if (!iso) return "—";
  return String(iso).replace("T", " ").replace(/\.\d+Z$/, "Z");
};

// ===========================================================================
// 2 · STATE
// ===========================================================================

const state = {
  mode: "boot", // 'live' | 'demo' | 'boot'
  records: [], // current page (server-paginated when live)
  pagination: null,
  page: 1,
  filters: { status: "VERIFIED", mode: "", device: "" },
  selectedId: null,
  trajectory: null, // { id, coords: [[lat,lng], ...] }
  demoById: new Map(),
  landRings: null, // AEQD coastlines
  flatMap: null,
  flatMarkerLayer: null,
  flatTrajectoryLayer: null,
  cesium: null, // { viewer, entitiesReady }
  cesiumBooting: false,
  projection: "3d",
};

// ===========================================================================
// 3 · API + DATA
// ===========================================================================

function apiUrl(path) {
  const base = (GOF_CONFIG.apiBase || "").replace(/\/+$/, "");
  return `${base}${path}`;
}

async function fetchJson(url, timeoutMs = GOF_CONFIG.fetchTimeoutMs) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: ctrl.signal, headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

function buildQuery(page) {
  const q = new URLSearchParams();
  q.set("page", String(page));
  q.set("per_page", String(GOF_CONFIG.perPage));
  q.set("status", state.filters.status || "ALL");
  if (state.filters.mode) q.set("mode", state.filters.mode);
  if (state.filters.device) q.set("device_id", state.filters.device);
  return q.toString();
}

async function fetchFeed(page = 1) {
  const qs = buildQuery(page);
  const payload = await fetchJson(apiUrl(`/api/v1/measurements?${qs}`));
  state.mode = "live";
  state.page = page;
  state.pagination = payload.pagination || null;
  state.records = (payload.data || []).map(normalizeRecord);
  // Top-level stats use an unfiltered first page the first time around.
  if (page === 1 && !state.statsFetched) {
    state.statsFetched = true;
    fetchStats();
  }
}

async function fetchStats() {
  try {
    const all = await fetchJson(apiUrl(`/api/v1/measurements?page=1&per_page=100&status=ALL`));
    const rows = (all.data || []).map(normalizeRecord);
    renderStats(
      all.pagination ? all.pagination.total_items : rows.length,
      rows.filter((r) => r.verification_status === "VERIFIED").length,
      new Set(rows.map((r) => r.device_id)).size,
      new Set(rows.map((r) => r.mode)).size,
    );
  } catch (e) {
    /* stats are decorative — table already reflects the feed */
  }
}

function normalizeRecord(raw) {
  return {
    id: raw.id,
    device_id: raw.device_id,
    mode: raw.mode,
    timestamp: raw.timestamp,
    timestamp_iso: raw.timestamp_iso || new Date(raw.timestamp).toISOString(),
    gps_lat: raw.gps_lat,
    gps_lon: raw.gps_lon,
    altitude_m: raw.altitude_m,
    curvature_deviation_percentage: raw.curvature_deviation_percentage,
    verification_status: raw.verification_status || "PENDING",
    signature_hash: raw.signature_hash,
    raw_dump_sha256: raw.raw_dump_sha256,
    created_at: raw.created_at,
    links: raw.links || {},
    demo_raw_csv: raw.demo_raw_csv || null, // bundled synthetic dataset only
  };
}

async function loadDemo() {
  const data = await fetchJson(GOF_CONFIG.demoDataset);
  state.mode = "demo";
  const records = data.map(normalizeRecord);
  state.demoById = new Map(records.map((r) => [r.id, r]));
  applyDemoFilters();
  renderStats(
    records.length,
    records.filter((r) => r.verification_status === "VERIFIED").length,
    new Set(records.map((r) => r.device_id)).size,
    new Set(records.map((r) => r.mode)).size,
  );
}

/** Client-side filter/pagination over the bundled dataset. */
function applyDemoFilters() {
  const { status, mode, device } = state.filters;
  const all = [...state.demoById.values()].filter((r) => {
    if (status && status !== "ALL" && r.verification_status !== status) return false;
    if (mode && r.mode !== mode) return false;
    if (device && !r.device_id.toLowerCase().includes(device.toLowerCase())) return false;
    return true;
  });
  const per = GOF_CONFIG.perPage;
  const totalPages = Math.max(1, Math.ceil(all.length / per));
  state.page = clamp(state.page, 1, totalPages);
  state.records = all.slice((state.page - 1) * per, state.page * per);
  state.pagination = {
    page: state.page,
    per_page: per,
    total_items: all.length,
    total_pages: totalPages,
    has_next: state.page < totalPages,
    has_prev: state.page > 1,
  };
}

async function refresh() {
  setFeedLoading(true);
  try {
    if (state.mode !== "demo") {
      await fetchFeed(state.page);
    } else {
      applyDemoFilters();
    }
    setConnection(state.mode === "live" ? "LIVE" : "DEMO");
    document.getElementById("demoBanner").classList.toggle("hidden", state.mode === "live");
  } catch (err) {
    console.warn("[gof] live feed unavailable:", err.message);
    try {
      await loadDemo();
      setConnection("DEMO");
      document.getElementById("demoBanner").classList.remove("hidden");
    } catch (err2) {
      setConnection("OFFLINE");
      toast(`Feed unavailable: ${err2.message}`);
    }
  } finally {
    setFeedLoading(false);
    renderTable();
    renderPagination();
    plotAllPoints();
  }
}

// ===========================================================================
// 4 · RENDERING — header, stats, table, pagination
// ===========================================================================

function setConnection(kind) {
  const chip = document.getElementById("apiChip");
  const text = document.getElementById("apiChipText");
  const dot = chip.querySelector(".live-dot");
  chip.classList.remove("badge-VERIFIED", "badge-PENDING", "badge-REJECTED");
  if (kind === "LIVE") {
    chip.classList.add("badge-VERIFIED");
    text.textContent = "API LIVE";
    dot.classList.remove("offline");
  } else if (kind === "CONNECTING") {
    chip.classList.add("badge-PENDING");
    text.textContent = "CONNECTING";
    dot.classList.add("offline");
  } else if (kind === "DEMO") {
    chip.classList.add("badge-PENDING");
    text.textContent = "OFFLINE CAPSULE";
    dot.classList.add("offline");
  } else {
    chip.classList.add("badge-REJECTED");
    text.textContent = "API OFFLINE";
    dot.classList.add("offline");
  }
}

function renderStats(total, verified, devices, modes) {
  document.getElementById("statTotal").textContent = String(total);
  document.getElementById("statVerified").textContent = String(verified);
  document.getElementById("statDevices").textContent = String(devices);
  document.getElementById("statModes").textContent = `${modes}/4`;
}

function setFeedLoading(loading) {
  document.getElementById("feedSkeleton").style.display = loading ? "block" : "none";
}

function filteredRecordsForTable() {
  return state.records;
}

function renderTable() {
  const tbody = document.getElementById("feedBody");
  const rows = filteredRecordsForTable();
  tbody.innerHTML = "";

  if (rows.length === 0) {
    tbody.innerHTML = `<tr><td colspan="6" class="text-center py-8 hud-tag">NO RECORDS FOR THIS FILTER</td></tr>`;
    return;
  }

  for (const rec of rows) {
    const v = verdictFor(rec.curvature_deviation_percentage, rec.mode, rec.verification_status);
    const tr = document.createElement("tr");
    tr.className = rec.id === state.selectedId ? "selected" : "";
    tr.dataset.id = rec.id;
    tr.innerHTML = `
      <td class="font-data text-gof-ink">${escapeHtml(rec.device_id)}</td>
      <td><span class="hud-chip mode-chip mode-${rec.mode}">${MODE_META[rec.mode] ? MODE_META[rec.mode].glyph + " " + MODE_META[rec.mode].label : rec.mode}</span></td>
      <td class="font-data">${fmtNum(rec.altitude_m, 1)}</td>
      <td class="font-data" style="color:${v.color}">${rec.curvature_deviation_percentage === null ? "—" : fmtNum(rec.curvature_deviation_percentage, 2) + " %"}</td>
      <td><span class="hud-chip badge-${rec.verification_status}">${rec.verification_status}</span></td>
      <td class="font-data text-slate-400 whitespace-nowrap">${fmtDate(rec.timestamp_iso).slice(0, 16)}</td>`;
    tr.addEventListener("click", () => openDrawer(rec.id));
    tbody.appendChild(tr);
  }
  document.getElementById("mapCount").textContent = `${rows.length} PTS`;
}

function renderPagination() {
  const p = state.pagination;
  document.getElementById("pageInfo").textContent = p
    ? `PAGE ${p.page}/${p.total_pages} · ${p.total_items} RECS`
    : "PAGE —/—";
  document.getElementById("btnPrev").disabled = !p || !p.has_prev;
  document.getElementById("btnNext").disabled = !p || !p.has_next;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// ===========================================================================
// 5 · 2D FLAT ENGINE — Leaflet on a north-pole AEQD CRS + canvas tile set
// ===========================================================================

function makeAeqdCrs() {
  const T = 1 / (2 * AEQD_MAX_R);
  return L.Util.extend({}, L.CRS, {
    code: "GOF:AEQD",
    projection: {
      project(latlng) {
        const p = aeqdProject(latlng.lat, latlng.lng);
        return new L.Point(p[0], p[1]);
      },
      unproject(point) {
        const ll = aeqdUnproject(point.x, point.y);
        return new L.LatLng(ll[0], ll[1]);
      },
      bounds: L.bounds(L.point(-AEQD_MAX_R, -AEQD_MAX_R), L.point(AEQD_MAX_R, AEQD_MAX_R)),
    },
    transformation: new L.Transformation(T, 0.5, T, 0.5),
    infinite: false,
  });
}

async function loadLandRings() {
  if (state.landRings) return state.landRings;
  const res = await fetch(GOF_CONFIG.landData);
  const data = await res.json();
  state.landRings = data.rings.map((ring) => {
    let minX = Infinity; let minY = Infinity; let maxX = -Infinity; let maxY = -Infinity;
    for (const [x, y] of ring) {
      if (x < minX) minX = x; if (y < minY) minY = y;
      if (x > maxX) maxX = x; if (y > maxY) maxY = y;
    }
    return { ring, bbox: [minX, minY, maxX, maxY] };
  });
  return state.landRings;
}

function initFlatMap() {
  if (state.flatMap || typeof L === "undefined") return;

  const crs = makeAeqdCrs();
  const map = L.map("mapFlat", {
    crs,
    minZoom: 0,
    maxZoom: 7,
    attributionControl: true,
    zoomControl: true,
  });
  map.attributionControl.setPrefix(false);
  map.attributionControl.addAttribution("coastlines: Natural Earth 110m (public domain) · AEQD north-pole plane");
  map.setView([45, 20], 1);

  // -- the AEQD tile set: ocean/graticule/land rendered client-side per tile --
  const AeqdTiles = L.GridLayer.extend({
    createTile(coords) {
      const tile = document.createElement("canvas");
      tile.width = 256;
      tile.height = 256;
      const ctx = tile.getContext("2d");
      drawAeqdTile(ctx, coords, state.landRings || []);
      return tile;
    },
  });

  const graticule = precomputeGraticule();
  const tiles = new AeqdTiles({
    tileSize: 256,
    updateWhenIdle: true,
    keepBuffer: 2,
  });
  tiles.addTo(map);

  loadLandRings()
    .then(() => {
      tiles.redraw();
    })
    .catch((err) => console.warn("[gof] land data unavailable:", err));

  state.flatMap = map;
  state.flatMarkerLayer = L.layerGroup().addTo(map);
  state.flatTrajectoryLayer = L.layerGroup().addTo(map);
  return map;
}

function precomputeGraticule() {
  const meridians = [];
  for (let lon = -180; lon < 180; lon += 30) {
    const line = [];
    for (let r = 0; r <= AEQD_MAX_R; r += AEQD_MAX_R / 90) {
      const lat = 90 - (r / AEQD_R) * (180 / Math.PI);
      line.push(aeqdProject(lat, lon));
    }
    meridians.push(line);
  }
  const parallels = [];
  for (let lat = -75; lat <= 75; lat += 15) {
    if (lat === 90) continue;
    const circ = [];
    for (let a = 0; a <= 360; a += 3) {
      circ.push(aeqdProject(lat, a));
    }
    parallels.push(circ);
  }
  return { meridians, parallels };
}

function drawAeqdTile(ctx, coords, rings) {
  const z = coords.z;
  const s = 256 * Math.pow(2, z);
  const toPx = (x, y) => [
    ((x / (2 * AEQD_MAX_R) + 0.5) * s) - coords.x * 256,
    ((y / (2 * AEQD_MAX_R) + 0.5) * s) - coords.y * 256,
  ];
  const tileMeters = (2 * AEQD_MAX_R) / Math.pow(2, z); // tile edge length in meters
  const ox = ((coords.x * 256) / s - 0.5) * 2 * AEQD_MAX_R;
  const oy = ((coords.y * 256) / s - 0.5) * 2 * AEQD_MAX_R;
  const bbox = [ox, oy, ox + tileMeters, oy + tileMeters];

  const strokePath = (points, style, dashed) => {
    ctx.beginPath();
    let started = false;
    for (const [mx, my] of points) {
      if (mx < bbox[0] - tileMeters || mx > bbox[2] + tileMeters || my < bbox[1] - tileMeters || my > bbox[3] + tileMeters) {
        started = false; // break the path far outside this tile
        continue;
      }
      const [px, py] = toPx(mx, my);
      if (!started) { ctx.moveTo(px, py); started = true; }
      else ctx.lineTo(px, py);
    }
    ctx.strokeStyle = style;
    ctx.lineWidth = 1;
    ctx.setLineDash(dashed || []);
    ctx.stroke();
    ctx.setLineDash([]);
  };

  // graticule (precomputed meters polylines)
  const g = state.graticule;
  if (g) {
    for (const line of g.parallels) strokePath(line, "rgba(24,224,255,0.12)");
    for (const line of g.meridians) strokePath(line, "rgba(24,224,255,0.09)");
  }

  // land rings (pre-projected meters, bbox-rejected)
  for (const { ring, bbox: rb } of rings) {
    if (rb[2] < bbox[0] || rb[0] > bbox[2] || rb[3] < bbox[1] || rb[1] > bbox[3]) continue;
    ctx.beginPath();
    for (let i = 0; i < ring.length; i++) {
      const [px, py] = toPx(ring[i][0], ring[i][1]);
      if (i === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    }
    ctx.closePath();
    ctx.fillStyle = "rgba(16,58,77,0.9)";
    ctx.strokeStyle = "rgba(24,224,255,0.4)";
    ctx.lineWidth = 1;
    ctx.fill();
    ctx.stroke();
  }

  // the "edge of the world" — AEQD south-pole circle (flat-model ice ring)
  ctx.beginPath();
  const cc = toPx(0, 0);
  const rEdge = (AEQD_MAX_R / (2 * AEQD_MAX_R)) * s;
  ctx.arc(cc[0], cc[1], rEdge, 0, Math.PI * 2);
  ctx.strokeStyle = "rgba(233,62,255,0.45)";
  ctx.setLineDash([6, 6]);
  ctx.lineWidth = 1.2;
  ctx.stroke();
  ctx.setLineDash([]);
}

function plotFlatPoints() {
  if (!state.flatMarkerLayer) return;
  state.flatMarkerLayer.clearLayers();
  for (const rec of state.records) {
    const color = STATUS_COLOR[rec.verification_status] || "#9d7bff";
    const m = L.circleMarker([rec.gps_lat, rec.gps_lon], {
      radius: 6,
      color,
      weight: 1.6,
      fillColor: color,
      fillOpacity: 0.85,
    });
    m.bindPopup(
      `<b style="color:${color}">${rec.verification_status}</b> · ${rec.mode}<br>` +
      `dev ${rec.curvature_deviation_percentage === null ? "—" : rec.curvature_deviation_percentage.toFixed(2) + " %"}<br>` +
      `<span style="color:#9be8ff">${shortId(rec.id)}…</span><br><i>click for record inspector</i>`,
    );
    m.on("click", () => openDrawer(rec.id));
    state.flatMarkerLayer.addLayer(m);
  }
}

function plotFlatTrajectory(traj) {
  if (!state.flatTrajectoryLayer) return;
  state.flatTrajectoryLayer.clearLayers();
  if (!traj || traj.coords.length < 2) return;
  const latlngs = traj.coords.map((c) => [c[0], c[1]]);
  L.polyline(latlngs, { color: "#e93eff", weight: 2.4, opacity: 0.9, dashArray: "5 5" }).addTo(state.flatTrajectoryLayer);
  const [slat, slng] = latlngs[0];
  const [elat, elng] = latlngs[latlngs.length - 1];
  L.circleMarker([slat, slng], { radius: 5, color: "#4cff87", fillOpacity: 1 }).addTo(state.flatTrajectoryLayer);
  L.circleMarker([elat, elng], { radius: 5, color: "#e93eff", fillOpacity: 1 }).addTo(state.flatTrajectoryLayer);
  state.flatMap.fitBounds(L.latLngBounds(latlngs), { padding: [40, 40], maxZoom: 5 });
}

// ===========================================================================
// 6 · 3D GLOBE ENGINE — Cesium (lazy boot, OSM + ellipsoid, optional Ion)
// ===========================================================================

async function bootCesium() {
  if (state.cesium || state.cesiumBooting) return state.cesium;
  state.cesiumBooting = true;
  const boot = document.getElementById("mapBoot");
  const bootText = document.getElementById("bootText");
  boot.classList.remove("hidden");
  boot.style.display = "flex";
  bootText.textContent = "BOOTING 3D ENGINE…";

  try {
    if (typeof Cesium === "undefined") throw new Error("Cesium.js failed to load (CDN unreachable)");
    if (GOF_CONFIG.ionToken) Cesium.Ion.defaultAccessToken = GOF_CONFIG.ionToken;

    const osm = new Cesium.OpenStreetMapImageryProvider({ url: "https://tile.openstreetmap.org/" });
    const viewer = new Cesium.Viewer("mapGlobe", {
      baseLayer: new Cesium.ImageryLayer(osm),
      terrainProvider: new Cesium.EllipsoidTerrainProvider(),
      animation: false, timeline: false, baseLayerPicker: false, geocoder: false,
      homeButton: false, sceneModePicker: false, navigationHelpButton: false,
      fullscreenButton: false, infoBox: false, selectionIndicator: false,
      creditContainer: document.getElementById("cesiumCredits"),
      requestRenderMode: false,
    });
    viewer.scene.globe.baseColor = Cesium.Color.fromCssColorString("#06202e");
    state.cesium = { viewer, pointMap: new Map(), trajectoryEntity: null };
    boot.style.display = "none";

    // Optional: real digital-elevation world terrain (needs an Ion token).
    if (GOF_CONFIG.ionToken) {
      boot.style.display = "flex";
      bootText.textContent = "STREAMING WORLD TERRAIN…";
      try {
        viewer.terrainProvider = await Cesium.createWorldTerrainAsync();
        document.getElementById("terrainChip").textContent = "TERRAIN: WORLD (ION)";
      } catch (e) {
        toast("Ion terrain unavailable — staying on smooth ellipsoid");
        document.getElementById("terrainChip").textContent = "TERRAIN: ELLIPSOID";
      }
      boot.style.display = "none";
    }
    plotCesiumPoints();
    return state.cesium;
  } catch (err) {
    bootText.textContent = "3D ENGINE UNAVAILABLE — SWITCHED TO 2D";
    toast(`Cesium failed: ${err.message}`);
    setTimeout(() => setProjection("2d"), 900);
    return null;
  } finally {
    state.cesiumBooting = false;
  }
}

function cesiumColorFor(status) {
  const hex = STATUS_COLOR[status] || "#9d7bff";
  const c = Cesium.Color.fromCssColorString(hex);
  return c.withAlpha(0.95);
}

function plotCesiumPoints() {
  const cs = state.cesium;
  if (!cs) return;
  for (const ent of cs.pointMap.values()) cs.viewer.entities.remove(ent);
  cs.pointMap.clear();

  for (const rec of state.records) {
    if (rec.gps_lat === null || rec.gps_lon === null) continue;
    const ent = cs.viewer.entities.add({
      position: Cesium.Cartesian3.fromDegrees(rec.gps_lon, rec.gps_lat),
      point: {
        pixelSize: 9,
        color: cesiumColorFor(rec.verification_status),
        outlineColor: Cesium.Color.fromCssColorString("#05080f"),
        outlineWidth: 1.5,
        disableDepthTestDistance: Number.POSITIVE_INFINITY,
        heightReference: Cesium.HeightReference.CLAMP_TO_GROUND,
      },
      label: {
        text: `${rec.mode.replace("_", " ")} · ${shortId(rec.id)}`,
        font: "11px 'JetBrains Mono', monospace",
        fillColor: Cesium.Color.fromCssColorString("#9be8ff"),
        showBackground: true,
        backgroundColor: Cesium.Color.fromCssColorString("rgba(5,8,15,0.8)"),
        pixelOffset: new Cesium.Cartesian2(0, 18),
        distanceDisplayCondition: new Cesium.DistanceDisplayCondition(0, 8_000_000),
      },
      properties: { id: rec.id },
    });
    ent.description = "";
    cs.pointMap.set(rec.id, ent);
  }

  if (state.trajectory && state.trajectory.coords.length >= 2) plotCesiumTrajectory(state.trajectory);
}

function plotCesiumTrajectory(traj) {
  const cs = state.cesium;
  if (!cs) return;
  if (cs.trajectoryEntity) cs.viewer.entities.remove(cs.trajectoryEntity);
  const positions = [];
  for (const [lat, lng] of traj.coords) {
    positions.push(...Cesium.Cartesian3.fromDegrees(lng, lat, 12000));
  }
  cs.trajectoryEntity = cs.viewer.entities.add({
    polyline: {
      positions,
      width: 2.5,
      material: new Cesium.PolylineDashMaterialProperty({
        color: Cesium.Color.fromCssColorString("#e93eff"),
        dashLength: 12,
      }),
    },
  });
}

function flyCesiumTo(rec) {
  const cs = state.cesium;
  if (!cs) return;
  cs.viewer.camera.flyTo({
    destination: Cesium.Cartesian3.fromDegrees(rec.gps_lon, rec.gps_lat, 2_200_000),
    duration: 1.4,
  });
}

// ===========================================================================
// 7 · PROJECTION TOGGLE + plotting fan-out
// ===========================================================================

function setProjection(which) {
  state.projection = which;
  const globeEl = document.getElementById("mapGlobe");
  const flatEl = document.getElementById("mapFlat");
  const b3 = document.getElementById("btn3d");
  const b2 = document.getElementById("btn2d");

  if (which === "3d") {
    b3.classList.add("active-3d");
    b2.classList.remove("active-2d");
    b3.setAttribute("aria-selected", "true");
    flatEl.style.display = "none";
    globeEl.style.display = "";
    if (!state.cesium) bootCesium();
    else if (state.trajectory) plotCesiumTrajectory(state.trajectory);
  } else {
    b2.classList.add("active-2d");
    b3.classList.remove("active-3d");
    b2.setAttribute("aria-selected", "true");
    globeEl.style.display = "none";
    flatEl.style.display = "";
    document.getElementById("mapBoot").style.display = "none";
    if (state.flatMap) state.flatMap.invalidateSize();
  }
}

function plotAllPoints() {
  plotFlatPoints();
  plotCesiumPoints();
}

function showTrajectory(traj, rec) {
  state.trajectory = traj && traj.coords && traj.coords.length >= 2 ? traj : null;
  document.getElementById("trajectoryRow").classList.toggle("hidden", !state.trajectory);
  if (!state.trajectory) {
    if (state.flatTrajectoryLayer) state.flatTrajectoryLayer.clearLayers();
    if (state.cesium && state.cesium.trajectoryEntity) {
      state.cesium.viewer.entities.remove(state.cesium.trajectoryEntity);
      state.cesium.trajectoryEntity = null;
    }
    return;
  }
  plotFlatTrajectory(state.trajectory);
  if (state.projection === "3d") {
    if (state.cesium) plotCesiumTrajectory(state.trajectory);
  } else if (rec) {
    // flat already fitBounds — nothing more
  }
}

// ===========================================================================
// 8 · RECORD DRAWER
// ===========================================================================

let drawerDumpCache = new Map(); // id → parsed dump (per session)

async function openDrawer(id) {
  const rec = state.records.find((r) => r.id === id) || state.demoById.get(id);
  if (!rec) return;
  state.selectedId = id;
  highlightTableRow(id);

  const v = verdictFor(rec.curvature_deviation_percentage, rec.mode, rec.verification_status);

  document.getElementById("drawerTitle").textContent = `MEASUREMENT ${shortId(rec.id)}…`;
  const modeChip = document.getElementById("drawerMode");
  modeChip.className = `hud-chip mode-chip mode-${rec.mode}`;
  modeChip.textContent = `${MODE_META[rec.mode] ? MODE_META[rec.mode].glyph + " " : ""}${rec.mode}`;
  document.getElementById("drawerSub").textContent =
    `${rec.device_id} · captured ${fmtDate(rec.timestamp_iso)} · ingest ${fmtDate(rec.created_at)}`;

  const badge = document.getElementById("drawerBadge");
  badge.className = `hud-chip badge-${rec.verification_status}`;
  badge.textContent = rec.verification_status;

  document.getElementById("drawerKv").innerHTML = `
    <div><div class="k">position</div><div class="v">${fmtNum(rec.gps_lat, 4)}°, ${fmtNum(rec.gps_lon, 4)}°</div></div>
    <div><div class="k">altitude</div><div class="v">${fmtNum(rec.altitude_m, 1)} m</div></div>
    <div><div class="k">deviation</div><div class="v" style="color:${v.color}">${rec.curvature_deviation_percentage === null ? "—" : fmtNum(rec.curvature_deviation_percentage, 2) + " %"}</div></div>
    <div><div class="k">mode</div><div class="v">${rec.mode}</div></div>`;

  document.getElementById("drawerIntegrity").innerHTML = `
    <div><div class="k">record id</div><div class="v" title="${rec.id}">${rec.id}</div></div>
    <div><div class="k">raw sha-256</div><div class="v" title="verify against /dump bytes">${rec.raw_dump_sha256 || "—"}</div></div>
    <div><div class="k">signature (sha-256)</div><div class="v">${shortId(rec.signature_hash)}… (ECDSA P-256)</div></div>`;

  document.getElementById("drawerHeadline").textContent = v.headline || v.label;
  document.getElementById("drawerHeadline").style.color = v.color;
  document.getElementById("drawerVerdictNote").textContent = v.match === null
    ? "No deviation score on this record — the paired-site or solar-geometry result is still open."
    : `Verdict ${v.label} · match score = 100 − |deviation| against the spherical expectation. Uncertainty lives in the raw dump, not in this number.`;

  // links / actions
  const dumpUrl = rec.demo_raw_csv !== null ? "#demo" : rec.links.raw_dump || apiUrl(`/api/v1/measurements/${rec.id}/dump`);
  const csvBtn = document.getElementById("btnDownloadCsv");
  csvBtn.dataset.mode = rec.demo_raw_csv !== null ? "demo" : "live";
  csvBtn.href = dumpUrl;
  document.getElementById("btnApiJson").href =
    rec.demo_raw_csv !== null ? GITHUB_REPO : apiUrl(`/api/v1/measurements/${rec.id}`);
  document.getElementById("btnCopySha").onclick = () => {
    navigator.clipboard.writeText(rec.raw_dump_sha256 || rec.signature_hash || "").then(() => toast("SHA-256 copied"));
  };

  // comparison matrix (refined once the dump arrives)
  renderMatrix(rec, null);

  // share card — draw immediately from API fields
  drawShareCard(rec, null);

  // telemetry — lazy dump fetch (real) or embedded (demo)
  loadDump(rec);

  // drawer mechanics
  document.getElementById("drawerBackdrop").classList.add("open");
  document.getElementById("drawer").classList.add("open");

  // map focus
  if (state.projection === "3d") flyCesiumTo(rec);
}

function closeDrawer() {
  document.getElementById("drawerBackdrop").classList.remove("open");
  document.getElementById("drawer").classList.remove("open");
  showTrajectory(null, null);
  state.selectedId = null;
  highlightTableRow(null);
}

function highlightTableRow(id) {
  for (const tr of document.querySelectorAll("#feedBody tr")) {
    tr.classList.toggle("selected", Boolean(id) && tr.dataset.id === id);
  }
}

function renderMatrix(rec, dump) {
  const cmp = deriveComparison(rec, dump);
  const host = document.getElementById("drawerMatrix");
  const rows = [
    ["MEASURED", cmp.measured],
    ["GLOBE EXPECTATION", cmp.globe],
    ["FLAT EXPECTATION", cmp.flat],
  ];
  host.innerHTML = rows
    .map(([k, v], i) => {
      const color = i === 0 ? "#ffffff" : i === 1 ? "#18e0ff" : "#4cff87";
      return `<div class="flex items-center gap-2">
        <span class="hud-tag !tracking-[0.1em] w-36 flex-none">${k}</span>
        <span class="font-data text-[12px]" style="color:${color}">${v === null || v === undefined ? "—" : fmtNum(v, 3) + " " + cmp.unit}</span>
      </div>`;
    })
    .join("") + `<p class="hud-tag !normal-case !text-[9px] leading-snug pt-1">${cmp.note}</p>`;
}

async function loadDump(rec) {
  const src = document.getElementById("telemetrySource");
  const grid = document.getElementById("chartGrid");
  grid.innerHTML = "";
  src.textContent = "";

  let text = null;
  try {
    if (rec.demo_raw_csv !== null) {
      text = rec.demo_raw_csv;
      src.textContent = "source: bundled synthetic capsule";
    } else if (rec.links && rec.links.raw_dump) {
      src.textContent = "fetching raw dump…";
      const res = await fetch(rec.links.raw_dump);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      text = await res.text();
      src.textContent = `source: R2 raw dump · ${(text.length / 1024).toFixed(1)} KB`;
    }
  } catch (err) {
    src.textContent = "raw dump unavailable";
    grid.innerHTML = `<p class="hud-tag !normal-case col-span-2">Raw dump fetch failed (${escapeHtml(err.message)}). CSV download link remains available.</p>`;
    return;
  }

  if (!text) {
    grid.innerHTML = `<p class="hud-tag !normal-case col-span-2">No raw log is publicly attached to this record.</p>`;
    return;
  }

  const dump = parseDump(text);
  drawerDumpCache.set(rec.id, dump);
  renderMatrix(rec, dump); // refine comparison with annotations
  drawShareCard(rec, dump); // refine share card

  const series = dumpSeries(dump);
  if (series.length === 0) {
    grid.innerHTML = `<p class="hud-tag !normal-case col-span-2">Dump contains no numeric telemetry rows (annotations only).</p>`;
  } else {
    for (const s of series.slice(0, 4)) {
      const box = document.createElement("div");
      box.className = "chart-box hud-panel !bg-gof-deep/40 p-2";
      const label = document.createElement("p");
      label.className = "hud-tag mb-1";
      label.style.color = s.color;
      label.textContent = s.label;
      const canvas = document.createElement("canvas");
      canvas.width = 480;
      canvas.height = 110;
      box.appendChild(label);
      box.appendChild(canvas);
      grid.appendChild(box);
      drawSpark(canvas, [s]);
    }
  }

  const traj = dumpTrajectory(dump);
  if (traj) {
    showTrajectory({ id: rec.id, coords: traj }, rec);
    document.getElementById("btnToggleTrajectory").onclick = () => {
      if (state.projection === "2d") {
        setProjection("3d");
      } else {
        setProjection("2d");
        plotFlatTrajectory(state.trajectory);
      }
    };
  } else {
    showTrajectory(null, rec);
  }
}

// ===========================================================================
// 9 · CANVAS — sparkline charts + 9:16 share card (mirrors the app painter)
// ===========================================================================

function drawSpark(canvas, series) {
  const ctx = canvas.getContext("2d");
  const W = canvas.width;
  const H = canvas.height;
  ctx.clearRect(0, 0, W, H);

  // grid
  ctx.strokeStyle = "rgba(24,224,255,0.08)";
  ctx.lineWidth = 1;
  for (let i = 1; i < 4; i++) {
    const y = (H / 4) * i;
    ctx.beginPath();
    ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke();
  }

  let minX = Infinity; let maxX = -Infinity; let minY = Infinity; let maxY = -Infinity;
  for (const s of series) {
    for (const [x, y] of s.points) {
      if (x < minX) minX = x; if (x > maxX) maxX = x;
      if (y < minY) minY = y; if (y > maxY) maxY = y;
    }
  }
  if (!Number.isFinite(minX) || minX === maxX) { maxX = minX + 1; }
  if (minY === maxY) { maxY = minY + 1; }
  const pad = 6;
  const tx = (x) => pad + ((x - minX) / (maxX - minX)) * (W - 2 * pad);
  const ty = (y) => H - pad - ((y - minY) / (maxY - minY)) * (H - 2 * pad);

  for (const s of series) {
    ctx.beginPath();
    for (let i = 0; i < s.points.length; i++) {
      const px = tx(s.points[i][0]);
      const py = ty(s.points[i][1]);
      if (i === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    }
    ctx.strokeStyle = s.color;
    ctx.lineWidth = 1.8;
    ctx.shadowColor = s.color;
    ctx.shadowBlur = 6;
    ctx.stroke();
    ctx.shadowBlur = 0;
  }
}

/**
 * 9:16 share card — canvas mirror of the mobile ShareCardPainter
 * (logical 540×960; rendered at scale 2 → 1080×1920 for download).
 */
function drawShareCard(rec, dump) {
  const canvas = document.getElementById("shareCardCanvas");
  canvas.width = 540;
  canvas.height = 960;
  const ctx = canvas.getContext("2d");
  paintShareCard(ctx, rec, dump);
}

/** Painter body in logical 540×960 coordinates (caller sets any scale). */
function paintShareCard(ctx, rec, dump) {
  const W = 540;
  const H = 960;
  const PAD = 20;
  const v = verdictFor(rec.curvature_deviation_percentage, rec.mode, rec.verification_status);
  const cmp = deriveComparison(rec, dump);
  const ann = dump ? dump.annotations : {};

  // base
  ctx.fillStyle = "#05080f";
  ctx.fillRect(0, 0, W, H);
  ctx.strokeStyle = "rgba(24,224,255,0.06)";
  ctx.lineWidth = 1;
  for (let y = 0; y < H; y += 24) {
    ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke();
  }

  // ---- header band 20–66
  ctx.textBaseline = "top";
  ctx.fillStyle = "#18e0ff";
  ctx.font = "800 22px Orbitron, monospace";
  ctx.fillText("GLOBEORFLAT", PAD, 24);
  ctx.font = "10px 'JetBrains Mono', monospace";
  ctx.fillStyle = "rgba(155,232,255,0.6)";
  ctx.fillText("OPEN SCIENCE", PAD + 152, 30);
  // mode chip
  const mm = MODE_META[rec.mode] || { label: rec.mode, color: "#18e0ff", glyph: "?" };
  ctx.strokeStyle = mm.color;
  ctx.strokeRect(W - PAD - 158, 24, 158, 20);
  ctx.fillStyle = mm.color;
  ctx.font = "700 10px 'JetBrains Mono', monospace";
  ctx.fillText(`${mm.glyph} ${mm.label}`, W - PAD - 150, 30);
  ctx.fillStyle = "rgba(155,232,255,0.5)";
  ctx.fillText(fmtDate(rec.timestamp_iso).slice(0, 10) + " UTC", PAD, 50);

  // ---- scene band 76–300: synthetic horizon (no camera frame server-side)
  const sx = PAD; const sy = 76; const sw = W - 2 * PAD; const sh = 224;
  const sky = ctx.createLinearGradient(0, sy, 0, sy + sh);
  sky.addColorStop(0, "#0b2740");
  sky.addColorStop(0.62, "#124059");
  sky.addColorStop(0.62, "#082433");
  sky.addColorStop(1, "#04141f");
  ctx.fillStyle = sky;
  ctx.fillRect(sx, sy, sw, sh);
  ctx.strokeStyle = "rgba(24,224,255,0.35)";
  ctx.strokeRect(sx, sy, sw, sh);
  const cy = sy + sh * 0.62;
  ctx.strokeStyle = "#4cff87";
  ctx.lineWidth = 1.6;
  ctx.beginPath(); ctx.moveTo(sx + 10, cy); ctx.lineTo(sx + sw - 10, cy); ctx.stroke(); // globe horizon
  ctx.strokeStyle = "rgba(24,224,255,0.8)";
  ctx.setLineDash([7, 7]);
  ctx.beginPath(); ctx.moveTo(sx + 10, cy + 8); ctx.lineTo(sx + sw - 10, cy + 8); ctx.stroke(); // flat reference
  ctx.setLineDash([]);
  ctx.font = "9px 'JetBrains Mono', monospace";
  ctx.fillStyle = "rgba(155,232,255,0.7)";
  ctx.fillText("CURVED HORIZON", sx + 12, cy - 22);
  ctx.fillStyle = "rgba(233,62,255,0.75)";
  ctx.fillText("FLAT REFERENCE", sx + 12, cy + 14);
  ctx.fillStyle = "rgba(155,232,255,0.4)";
  ctx.fillText("SYNTHETIC SCENE — NO FRAME CAPTURED", sx + 12, sy + 10);

  // ---- verdict ring, center (270, 406) r 78
  const rx = 270; const ry = 406; const rr = 78;
  ctx.lineWidth = 10;
  ctx.strokeStyle = "rgba(255,255,255,0.07)";
  ctx.beginPath(); ctx.arc(rx, ry, rr, 0, Math.PI * 2); ctx.stroke();
  if (v.match !== null) {
    ctx.strokeStyle = v.color;
    ctx.shadowColor = v.color;
    ctx.shadowBlur = 14;
    ctx.beginPath();
    ctx.arc(rx, ry, rr, -Math.PI / 2, -Math.PI / 2 + (v.match / 100) * Math.PI * 2);
    ctx.stroke();
    ctx.shadowBlur = 0;
  }
  ctx.textAlign = "center";
  ctx.fillStyle = v.color;
  ctx.font = "900 30px Orbitron, monospace";
  ctx.fillText(v.match === null ? "—" : `${v.match.toFixed(1)}%`, rx, ry - 20);
  ctx.font = "700 9px 'JetBrains Mono', monospace";
  ctx.fillStyle = "rgba(155,232,255,0.7)";
  ctx.fillText("MATCH · SPHERICAL MODEL", rx, ry + 16);
  ctx.textAlign = "left";

  // ---- bars 510–602
  const barRows = [
    ["MEASURED", cmp.measured],
    ["GLOBE EXPECT", cmp.globe],
    ["FLAT EXPECT", cmp.flat],
  ];
  const vals = barRows.map((r) => Math.abs(r[1] === null || r[1] === undefined ? 0 : r[1]));
  const maxV = Math.max(...vals, 1e-9);
  let by = 510;
  const barColors = ["#ffffff", "#18e0ff", "#4cff87"];
  barRows.forEach(([label, val], i) => {
    ctx.font = "700 10px 'JetBrains Mono', monospace";
    ctx.fillStyle = "rgba(155,232,255,0.65)";
    ctx.fillText(label, PAD, by + 6);
    const bx = PAD + 120;
    const bw = 276;
    ctx.fillStyle = "rgba(255,255,255,0.06)";
    ctx.fillRect(bx, by, bw, 16);
    const frac = val === null || val === undefined ? 0 : Math.abs(val) / maxV;
    ctx.fillStyle = barColors[i];
    ctx.shadowColor = barColors[i];
    ctx.shadowBlur = 8;
    ctx.fillRect(bx, by, Math.max(2, frac * bw), 16);
    ctx.shadowBlur = 0;
    ctx.fillStyle = barColors[i];
    ctx.font = "700 11px 'JetBrains Mono', monospace";
    ctx.fillText(
      val === null || val === undefined ? "—" : `${fmtNum(val, 2)} ${cmp.unit}`,
      bx + bw + 10, by + 4,
    );
    by += 32;
  });

  // ---- info tiles 612–708 (245×43, gap 10)
  const tiles = [
    ["POSITION", `${fmtNum(rec.gps_lat, 3)}, ${fmtNum(rec.gps_lon, 3)}`],
    ["ALTITUDE (EKF)", `${fmtNum(rec.altitude_m, 1)} m`],
    ["DEVICE", rec.device_id],
    ["STATUS", rec.verification_status],
  ];
  tiles.forEach(([k, val], i) => {
    const txx = PAD + (i % 2) * 255;
    const tyy = 612 + Math.floor(i / 2) * 53;
    ctx.strokeStyle = "rgba(24,224,255,0.25)";
    ctx.strokeRect(txx, tyy, 245, 43);
    ctx.font = "700 8.5px 'JetBrains Mono', monospace";
    ctx.fillStyle = "rgba(155,232,255,0.5)";
    ctx.fillText(k, txx + 10, tyy + 8);
    ctx.font = "700 13px 'JetBrains Mono', monospace";
    ctx.fillStyle = "#d7f6ff";
    ctx.fillText(String(val).slice(0, 26), txx + 10, tyy + 22);
  });

  // ---- band 718–850: trajectory mini-map or deviation meter
  ctx.strokeStyle = "rgba(24,224,255,0.25)";
  ctx.strokeRect(PAD, 718, W - 2 * PAD, 132);
  const traj = state.trajectory && state.trajectory.id === rec.id ? state.trajectory.coords : null;
  if (traj && traj.length >= 2) {
    ctx.strokeStyle = "#e93eff";
    ctx.lineWidth = 2;
    ctx.shadowColor = "#e93eff";
    ctx.shadowBlur = 8;
    ctx.beginPath();
    let minX = Infinity; let maxX = -Infinity; let minY = Infinity; let maxY = -Infinity;
    for (const [la, lo] of traj) {
      const p = aeqdProject(la, lo);
      if (p[0] < minX) minX = p[0]; if (p[0] > maxX) maxX = p[0];
      if (p[1] < minY) minY = p[1]; if (p[1] > maxY) maxY = p[1];
    }
    const spanX = Math.max(maxX - minX, 1);
    const spanY = Math.max(maxY - minY, 1);
    traj.forEach(([la, lo], i) => {
      const p = aeqdProject(la, lo);
      const px = PAD + 14 + ((p[0] - minX) / spanX) * (W - 2 * PAD - 28);
      const py = 718 + 14 + ((p[1] - minY) / spanY) * (132 - 28);
      if (i === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    });
    ctx.stroke();
    ctx.shadowBlur = 0;
    ctx.fillStyle = "#4cff87";
    ctx.font = "700 9px 'JetBrains Mono', monospace";
    ctx.fillText("GPS TRAJECTORY", PAD + 14, 728);
  } else {
    // deviation meter: axis −50 % … +50 %
    const axY = 792;
    ctx.strokeStyle = "rgba(255,255,255,0.2)";
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(PAD + 14, axY); ctx.lineTo(W - PAD - 14, axY); ctx.stroke();
    ctx.font = "700 9px 'JetBrains Mono', monospace";
    ctx.fillStyle = "rgba(155,232,255,0.5)";
    ctx.fillText("−50 %", PAD + 14, axY + 10);
    ctx.textAlign = "center";
    ctx.fillText("0", rx, axY + 10);
    ctx.fillText("+50 %", W - PAD - 14, axY + 10);
    const dev = rec.curvature_deviation_percentage;
    if (dev !== null && dev !== undefined) {
      const frac = clamp(dev / 50, -1, 1);
      const dx = rx + frac * ((W - 2 * PAD - 28) / 2);
      ctx.fillStyle = v.color;
      ctx.shadowColor = v.color;
      ctx.shadowBlur = 10;
      ctx.beginPath(); ctx.arc(dx, axY, 7, 0, Math.PI * 2); ctx.fill();
      ctx.shadowBlur = 0;
      ctx.textAlign = "center";
      ctx.fillText(`dev ${fmtNum(dev, 2)} %`, rx, axY - 34);
    }
    ctx.textAlign = "left";
    ctx.fillStyle = "rgba(155,232,255,0.5)";
    ctx.fillText("DEVIATION vs SPHERICAL MODEL", PAD + 14, 728);
  }

  // ---- footer 858–960
  ctx.fillStyle = "rgba(155,232,255,0.5)";
  ctx.font = "700 11px 'JetBrains Mono', monospace";
  ctx.fillText(`#${shortId(rec.id)}…`, PAD, 874);
  ctx.textAlign = "right";
  ctx.fillText("@globeorflat", W - PAD, 874);
  ctx.textAlign = "center";
  ctx.fillStyle = "rgba(155,232,255,0.35)";
  ctx.fillText("measured with GlobeOrFlat · open-source citizen geodesy", rx, 934);
  ctx.textAlign = "left";
}

async function downloadShareCard() {
  const rec = currentDrawerRecord();
  if (!rec) return;
  const dump = drawerDumpCache.get(rec.id) || null;
  // re-render at 2× offscreen → 1080×1920
  const off = document.createElement("canvas");
  const tmpId = document.getElementById("shareCardCanvas");
  drawShareCardOn(off, rec, dump, 2);
  const blob = await new Promise((resolve) => off.toBlob(resolve, "image/png"));
  triggerDownload(blob, `globeorflat_card_${shortId(rec.id)}.png`);
  toast("9:16 card downloaded (1080×1920)");
}

/** Render the card onto any canvas at any scale (preview = 1, export = 2). */
function drawShareCardOn(canvas, rec, dump, scale) {
  canvas.width = 540 * scale;
  canvas.height = 960 * scale;
  const ctx = canvas.getContext("2d");
  ctx.scale(scale, scale);
  paintShareCard(ctx, rec, dump);
}

async function shareCardNativeShare() {
  const rec = currentDrawerRecord();
  if (!rec) return;
  const dump = drawerDumpCache.get(rec.id) || null;
  const off = document.createElement("canvas");
  drawShareCardOn(off, rec, dump, 2);
  const blob = await new Promise((resolve) => off.toBlob(resolve, "image/png"));
  const v = verdictFor(rec.curvature_deviation_percentage, rec.mode, rec.verification_status);
  const caption = `${v.headline || v.label} — measured with GlobeOrFlat (open-source citizen geodesy). #globeorflat #science`;
  const file = new File([blob], `globeorflat_${shortId(rec.id)}.png`, { type: "image/png" });
  if (navigator.canShare && navigator.canShare({ files: [file] })) {
    try {
      await navigator.share({ files: [file], text: caption });
      return;
    } catch (e) {
      if (e && e.name === "AbortError") return;
    }
  }
  if (navigator.clipboard && window.ClipboardItem) {
    try {
      await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
      toast("Card PNG copied — paste it into your social app");
      return;
    } catch (e) { /* fall through */ }
  }
  triggerDownload(blob, `globeorflat_${shortId(rec.id)}.png`);
  toast("Sharing unsupported here — card downloaded instead");
}

function currentDrawerRecord() {
  return state.records.find((r) => r.id === state.selectedId) || state.demoById.get(state.selectedId) || null;
}

function triggerDownload(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}

// ===========================================================================
// 10 · UI WIRING + BOOT
// ===========================================================================

function toast(msg) {
  const host = document.getElementById("toastHost");
  const el = document.createElement("div");
  el.className = "toast";
  el.textContent = msg;
  host.appendChild(el);
  setTimeout(() => el.remove(), 3200);
}

function wireUi() {
  document.getElementById("btn3d").addEventListener("click", () => setProjection("3d"));
  document.getElementById("btn2d").addEventListener("click", () => setProjection("2d"));

  document.getElementById("btnPrev").addEventListener("click", () => {
    if (state.mode === "demo") { state.page -= 1; refresh(); }
    else if (state.page > 1) { state.page -= 1; refresh(); }
  });
  document.getElementById("btnNext").addEventListener("click", () => {
    state.page += 1;
    refresh();
  });

  let filterTimer = null;
  const onFilter = () => {
    clearTimeout(filterTimer);
    filterTimer = setTimeout(() => {
      state.filters.status = document.getElementById("filterStatus").value;
      state.filters.mode = document.getElementById("filterMode").value;
      state.filters.device = document.getElementById("filterDevice").value.trim();
      state.page = 1;
      refresh();
    }, 250);
  };
  ["filterStatus", "filterMode", "filterDevice"].forEach((id) =>
    document.getElementById(id).addEventListener("change", onFilter),
  );
  document.getElementById("filterDevice").addEventListener("input", onFilter);

  document.getElementById("drawerClose").addEventListener("click", closeDrawer);
  document.getElementById("drawerBackdrop").addEventListener("click", closeDrawer);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { closeDrawer(); closeSettings(); }
  });

  document.getElementById("btnDownloadCard").addEventListener("click", downloadShareCard);
  document.getElementById("btnShareCard").addEventListener("click", shareCardNativeShare);

  document.getElementById("btnDownloadCsv").addEventListener("click", (e) => {
    const rec = currentDrawerRecord();
    if (!rec) return;
    if (rec.demo_raw_csv !== null) {
      e.preventDefault();
      const blob = new Blob([rec.demo_raw_csv], { type: "text/csv" });
      triggerDownload(blob, `globeorflat_${shortId(rec.id)}.csv`);
      toast("Synthetic capsule CSV downloaded");
    } else {
      toast("Streaming raw dump from append-only storage…");
    }
  });

  // settings modal
  const modal = document.getElementById("settingsModal");
  const openSettings = () => {
    document.getElementById("apiBaseInput").value = GOF_CONFIG.apiBase || "";
    document.getElementById("ionTokenInput").value = GOF_CONFIG.ionToken || "";
    modal.classList.remove("hidden");
    modal.classList.add("flex");
  };
  const closeSettings = () => {
    modal.classList.add("hidden");
    modal.classList.remove("flex");
  };
  window.closeSettings = closeSettings;
  document.getElementById("openSettings").addEventListener("click", openSettings);
  document.getElementById("apiChip").addEventListener("click", openSettings);
  document.getElementById("openSettingsFromBanner").addEventListener("click", openSettings);
  modal.querySelectorAll("[data-close-settings]").forEach((el) => el.addEventListener("click", closeSettings));
  document.getElementById("settingsSave").addEventListener("click", () => {
    GOF_CONFIG.apiBase = document.getElementById("apiBaseInput").value.trim();
    GOF_CONFIG.ionToken = document.getElementById("ionTokenInput").value.trim();
    try {
      localStorage.setItem("gof_api_base", GOF_CONFIG.apiBase);
      localStorage.setItem("gof_ion_token", GOF_CONFIG.ionToken);
    } catch (e) { /* private mode */ }
    closeSettings();
    state.statsFetched = false;
    state.mode = "boot";
    state.page = 1;
    resetCesium();
    refresh();
  });
  document.getElementById("settingsReset").addEventListener("click", () => {
    document.getElementById("apiBaseInput").value = "";
    document.getElementById("ionTokenInput").value = "";
  });
}

function resetCesium() {
  if (state.cesium) {
    state.cesium.viewer.destroy();
    state.cesium = null;
  }
  document.getElementById("terrainChip").textContent = "TERRAIN: ELLIPSOID";
}

async function boot() {
  wireUi();
  // static graticule shared by the tile painter
  state.graticule = precomputeGraticule();
  initFlatMap();
  setConnection("CONNECTING");
  await refresh();
  setProjection("3d"); // boots Cesium lazily (2D engine is already live beneath)
}

if (typeof window !== "undefined" && typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
}

// ===========================================================================
// node-test exports (pure helpers only)
// ===========================================================================

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    horizonDipArcminutes,
    hiddenHeightMeters,
    curvatureDropMeters,
    matchPercent,
    verdictFor,
    parseDump,
    dumpSeries,
    dumpTrajectory,
    deriveComparison,
    aeqdProject,
    aeqdUnproject,
    R_EFFECTIVE_M,
  };
}
