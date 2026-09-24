/**
 * GlobeOrFlat Hub — pure-helper tests (node, no framework).
 * SPDX-License-Identifier: MIT
 *
 * Asserts the web mirrors of the LOCKED app constants/formulas and the
 * on-device CSV dump conventions behave exactly like the Android client.
 * Run: node test/helpers.test.js   (from web/)
 */
const assert = require("assert");
const A = require("../app.js");

// --- locked physics mirrors -------------------------------------------------
assert.ok(Math.abs(A.horizonDipArcminutes(100) - 10.6) < 1e-9);
assert.ok(Math.abs(A.hiddenHeightMeters(2, 10) - 1.6553) < 0.001, A.hiddenHeightMeters(2, 10));
assert.ok(Math.abs(A.curvatureDropMeters(10) - 7.85) < 1e-9);
assert.ok(Math.abs(A.R_EFFECTIVE_M - 7408139.5) < 0.5);

// --- verdict / match ladder (exact app semantics) ---------------------------
const v1 = A.verdictFor(0.6, "HORIZON_DIP", "VERIFIED");
assert.strictEqual(v1.headline, "99.4% Match with Spherical Earth Model");
assert.strictEqual(v1.label, "STRONG GLOBE MATCH");
assert.strictEqual(v1.color, "#4cff87");

const v2 = A.verdictFor(-1.5094, "HORIZON_DIP", "VERIFIED");
assert.ok(Math.abs(v2.match - 98.4906) < 0.001);

const v3 = A.verdictFor(12.6, "TRACK_DRIVE", "VERIFIED");
assert.ok(Math.abs(v3.match - 87.4) < 1e-9);
assert.strictEqual(v3.label, "GLOBE CONSISTENT");
assert.strictEqual(v3.color, "#18e0ff");

const v4 = A.verdictFor(-3.4, "TRACK_DRIVE", "VERIFIED");
assert.strictEqual(v4.match, 100); // track ignores negative deviation

const v5 = A.verdictFor(41.7, "TRACK_DRIVE", "REJECTED");
assert.ok(Math.abs(v5.match - 58.3) < 1e-9);
assert.strictEqual(v5.label, "AMBIGUOUS");
const v5b = A.verdictFor(70, "TRACK_DRIVE", "REJECTED");
assert.strictEqual(v5b.match, 30);
assert.strictEqual(v5b.label, "DEVIATES FROM GLOBE (FLAT FITS BETTER)");
assert.strictEqual(v5b.color, "#e93eff");

const v6 = A.verdictFor(null, "ERATOSTHENES", "PENDING");
assert.strictEqual(v6.label, "INCONCLUSIVE");
assert.strictEqual(v6.color, "#9d7bff");

const v7 = A.verdictFor(30, "HORIZON_DIP", "FLAGGED");
assert.strictEqual(v7.label, "AMBIGUOUS");
assert.strictEqual(v7.color, "#ffb454");

const v8 = A.verdictFor(80, "HORIZON_DIP", "REJECTED");
assert.strictEqual(v8.label, "DEVIATES FROM GLOBE");

// --- AEQD plane math (radius = colatitude × R; matches proj4) ---------------
const [mx, my] = A.aeqdProject(40.4168, -3.7038); // Madrid
assert.ok(Math.abs(Math.hypot(mx, my) - 5519577) < 2, Math.hypot(mx, my));
const [rlat, rlng] = A.aeqdUnproject(mx, my);
assert.ok(Math.abs(rlat - 40.4168) < 1e-6 && Math.abs(rlng + 3.7038) < 1e-6);
const [sx, sy] = A.aeqdProject(-90, 0); // south pole = plane edge
assert.ok(Math.abs(Math.hypot(sx, sy) - Math.PI * 6378137) < 0.5);

// --- CSV dump parser (on-device conventions) --------------------------------
const d1 = A.parseDump(
  "# horizon_dip,altitude_m=100.00\n# horizon_dip,measured_arcmin=10.4400\n# horizon_dip,predicted_arcmin=10.6000\n",
);
assert.strictEqual(d1.annotations.altitude_m, "100.00");
assert.strictEqual(d1.annotations.predicted_arcmin, "10.6000");
assert.strictEqual(d1.rows.length, 0);

const csv2 =
  "# horizon_dip,columns=ts_ms,ax,ay,az,gx,gy,gz,mx,my,mz,pressure_hpa,gps_lat,gps_lon,gps_alt,gps_acc,fused_alt,vert_vel,pitch,roll,heading\n" +
  "1000,0,0,-9.8,0,0,0,0,0,0,1014.1,40.0,-3.7,668.0,4.0,12.0,0.0,3.70,0.1,180\n" +
  "1200,0,0,-9.8,0,0,0,0,0,0,1014.0,40.0,-3.7,668.0,4.0,12.0,0.0,3.72,0.1,180\n";
const d2 = A.parseDump(csv2);
assert.strictEqual(d2.columns.length, 20);
assert.strictEqual(d2.columns[0], "ts_ms");
assert.strictEqual(d2.rows.length, 2);
const s2 = A.dumpSeries(d2);
assert.ok(s2.length >= 3, "expect fused/gps/pitch series");
assert.ok(s2.some((s) => s.label.includes("FUSED")));
assert.ok(s2.some((s) => s.label.includes("PITCH")));

const csv3 =
  "# track_drive,columns=d_km,fused_alt_m,gps_alt_m,gps_lat,gps_lon\n" +
  "# track_point,0.0,705.0,707.1,40.520,-3.650\n" +
  "# track_point,7.1,698.2,700.3,40.565,-3.595\n" +
  "# track_point,14.2,705.0,707.1,40.520,-3.540\n";
const d3 = A.parseDump(csv3);
assert.strictEqual(d3.trackPoints.length, 3);
assert.strictEqual(A.dumpSeries(d3).length, 2);
const t3 = A.dumpTrajectory(d3);
assert.ok(Array.isArray(t3) && t3.length === 3, "track_point trajectory");
assert.ok(Math.abs(t3[1][0] - 40.565) < 1e-9);

const t4 = A.dumpTrajectory(
  A.parseDump(
    "# horizon_dip,columns=ts_ms,gps_lat,gps_lon,fused_alt\n1000,40.0,-3.7,12\n1200,40.1,-3.8,12\n1400,40.2,-3.9,12\n",
  ),
);
assert.ok(t4 && t4.length === 3);
assert.strictEqual(
  A.dumpTrajectory(
    A.parseDump("# horizon_dip,columns=ts_ms,gps_lat,gps_lon,fused_alt\n1000,40.0,-3.7,12\n1200,40.0,-3.7,12\n"),
  ),
  null,
  "constant coords → no trajectory",
);

// --- comparison derivation honors dump annotations --------------------------
const cmp = A.deriveComparison(
  { mode: "WATER_SIGHTLINE", altitude_m: 2, curvature_deviation_percentage: 3.9 },
  A.parseDump("# water_sightline,distance_km=10.000\n# water_sightline,predicted_hidden_m=1.6553\n# water_sightline,measured_hidden_m=1.7200\n"),
);
assert.ok(Math.abs(cmp.measured - 1.72) < 1e-9);
assert.ok(Math.abs(cmp.globe - 1.6553) < 1e-9);

const cmpH = A.deriveComparison({ mode: "HORIZON_DIP", altitude_m: 100, curvature_deviation_percentage: -1.5 }, null);
assert.ok(Math.abs(cmpH.globe - 10.6) < 1e-9);
assert.ok(Math.abs(cmpH.measured - 10.441) < 0.01);

// --- bundled demo dataset integrity ------------------------------------------
const demo = require("../assets/demo-measurements.json");
assert.ok(Array.isArray(demo) && demo.length >= 10);
for (const r of demo) {
  assert.ok(["HORIZON_DIP", "WATER_SIGHTLINE", "TRACK_DRIVE", "ERATOSTHENES"].includes(r.mode), r.mode);
  assert.ok(["VERIFIED", "PENDING", "FLAGGED", "REJECTED"].includes(r.verification_status));
  assert.ok(typeof r.demo_raw_csv === "string" && r.demo_raw_csv.startsWith("#"));
  assert.ok(A.parseDump(r.demo_raw_csv) !== null);
}
// record 1 must reproduce the locked dip value
const dipAnn = A.parseDump(demo[0].demo_raw_csv).annotations;
assert.ok(Math.abs(Number(dipAnn.predicted_arcmin) - 10.6) < 0.001);

console.log("ALL WEB HELPER TESTS PASSED");
