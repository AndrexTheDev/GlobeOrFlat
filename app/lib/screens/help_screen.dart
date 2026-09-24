// ============================================================================
// GlobeOrFlat — Help & FAQ
// SPDX-License-Identifier: MIT
//
// Field manuals for the four measurement modes, an honest explainer of the
// sensor stack, and the FAQ. All content is Markdown rendered through the
// shared HUD theme (HudDocumentScaffold).
// ============================================================================

import 'package:flutter/material.dart';

import '../widgets/hud_document_scaffold.dart';

/// The complete Help & FAQ document (Markdown).
const String kHelpMarkdown = r'''
# Help & FAQ

GlobeOrFlat turns a phone into a honest geodesy instrument. The quality of
the science depends on the quality of the field technique — these guides
cover what actually matters outdoors.

## Before your first measurement

1. **Calibrate** — the app forces the figure-8 + flat-rest routine once, and
   after every long transport or case change. Calibration quality directly
   bounds every later measurement.
2. **Wait for the fix** — let the EKF settle for 60–120 s outdoors before
   capturing. The altitude readout on the home screen should stop moving.
3. **Charge past 20 %** — several devices throttle sensors on low battery.
4. **Check the sync card** — measurements queue offline and upload
   automatically; a green *Online* chip means you are contributing live.

## Mode A — Horizon Dip: beating refraction interference

Refraction bends light near the surface and shifts the **apparent** horizon.
Standard conditions are baked into the model (`k = 0.14`), but no day is
standard. You cannot eliminate refraction — you avoid the conditions where
it misbehaves, and you measure so its leftovers average out.

1. **Pick your window.** Measure mid-morning or mid-afternoon. Avoid dawn
   and dusk over water: strong thermal gradients produce mirage, looming and
   a fuzzy, unstable horizon.
2. **Mind the water temperature.** Cold water under warm air (spring) or a
   warm sea under cold air (autumn cold snap) is where refraction swings
   hardest. Calm, well-mixed days give the most standard conditions.
3. **Gain real height.** Dip scales with √h — at 2 m eye height the whole
   signal is ≈ 1.5′, smaller than ordinary coastal mirage. From 30–100 m
   (dune, promenade, sea-view floor) it is 6–10′ and far more robust.
4. **Trust the barometer.** The app feeds the EKF-fused altitude into
   `θ = 1.06′·√h`. Do not capture while the altitude readout still drifts.
5. **The horizon line you aim at** should be the crisp water/sky boundary —
   not a fog band, not a distant shoreline stacked on the horizon.
6. **Average.** Capture 5–10 dips over several minutes. The *mean* is the
   data point; the *spread* is your uncertainty. Upload both (the raw log
   carries every sample).
7. **Log the conditions.** Wind, haze, time of day — researchers filter dips
   by them, and so should you.

**Reading the HUD.** Green line = true horizontal (EKF attitude). Cyan
dashed = where the globe model predicts the horizon. Steady the crosshair on
the visible horizon — the measured dip is the angle between them.

## Mode B — Water Sightline: best practices for zoom work

The classic experiment: a distant ship, buoy or lighthouse partially hidden
by the horizon.

1. **Targets with known height only.** Lighthouse focal-plane heights are
   published; ship funnels and containers are standard heights. "That
   building looks about 20 m" is not a measurement.
2. **Measure distance properly.** Drop a map pin on the target and one on
   yourself; use the map distance, not a guess. Distance errors grow as
   d² in the occlusion formula — a 20 % distance error can double the
   predicted hiding.
3. **Stabilize the zoom.** At 8–10× every heartbeat moves the frame: brace
   against a solid object, elbows in, exhale, capture a burst of photos.
   Never hand-float the phone free.
4. **Account for tide.** Chart heights are referenced to chart datum; the
   app assumes height above the water surface in front of you. Note the
   tide state — low water hides more than high water, by exactly the tide.
5. **Use the occlusion slider honestly.** Estimate what fraction of the
   target is actually hidden *at the waterline* — swell makes this dance;
   average what you see over a minute of watching.
6. **Flat vs globe in one glance.** The HUD shows both: the cyan line (flat
   model) puts the waterline at the target base — nothing ever hidden; the
   red band is the globe prediction. Your photo of the real target is the
   referee.

## Mode C — Track & Curve Drive: clean profiles

1. **Set up before moving.** Mount the phone, start the recording while
   parked, place the phone where it cannot slide. **Never operate the app
   while driving** (see the Safety screen).
2. **Choose terrain on purpose.** Flat coastal plains, causeways and lake
   shores are ideal: the smaller the real relief, the more clearly the
   0.0785·s² arc distinguishes itself from a flat plane over long runs
   (10 km already accumulates ~7.9 m).
3. **Keep the barometer happy.** Keep windows closed and HVAC on
   recirculate — pressure gusts from open windows alias straight into the
   altitude. Do not hang the phone out of the window, however fun it looks.
4. **Drive both directions.** A real slope adds on one leg and subtracts on
   the other; the curvature arc accumulates regardless of direction.
5. **Aim for 10+ km** so at least 100 samples land on the profile.

## Mode D — Eratosthenes Synchro: the two-stick protocol

1. **Work at local solar noon** (the app counts down; ±15 min is the window).
   At solar noon the shadow is shortest and points due north/south — the
   geometry the classical formula assumes.
2. **Vertical is non-negotiable.** Use the on-screen plumb line. A 2° stick
   tilt is already a ~3 % elevation error.
3. **Flat, level ground** — a sloped pavement skews the shadow length.
4. **Calipers discipline.** Fit the white lines to the stick, the orange
   lines to the shadow, both times from the *same* distance and angle.
5. **Same-day pairing.** Share your 6-digit code and agree on a date. The
   bigger the north–south separation between partners, the stronger the
   result (one at roughly 25–30° apart in latitude reproduces the classical
   7.2° nicely).
6. **No sun gazing.** You only ever photograph shadows (see Safety).

## The sensor stack, honestly explained

| Sensor | What it tells us | Strength | Weakness |
| --- | --- | --- | --- |
| Barometer | Air pressure → altitude | ~1 Pa resolution (cm-level); fast; works offline and indoors | Relative only; weather fronts drift it metres per hour |
| GNSS (GPS) | Absolute position + altitude | Ties data to real coordinates; stable over long averages | Vertical error 1.5–3× worse than horizontal (3–10 m); jumpy |
| Accelerometer | Specific force (motion + gravity) | 50 Hz dynamics the others cannot see | Double-integrated noise diverges in seconds; no absolute reference |
| Gyroscope | Rotation rate | Fast, smooth short-term attitude | Bias drift — 0.01 rad/s ≈ 0.57°/s uncalibrated |
| Magnetometer | Magnetic heading anchor | Absolute yaw reference | Hard/soft-iron distortion; fooled by cars, rails, magnets |

### Why they are fused (the EKF in one paragraph)

Each sensor is trustworthy on a different **timescale**. The barometer is
smooth second-to-second but wanders over hours; GNSS wanders
second-to-second but is stable over minutes; the IMU bridges the gaps with
dynamics but knows no absolute truth. The Extended Kalman Filter tracks
`[altitude, vertical velocity, baro bias]`, predicts 50×/s from
gravity-corrected acceleration, and lets barometer (10 Hz) and GNSS (1 Hz)
updates pull the state back — each weighted by its own measured noise.
The result behaves like a sensor none of them is: centimetre-smooth *and*
hour-stable.

## FAQ

**Why must I calibrate before measuring?**
The gyro bias and magnetometer offsets it measures are subtracted from every
sample afterwards. Skipping calibration typically costs several degrees of
attitude error — fatal for a dip measurement worth 1–10 arcminutes.

**Why do my numbers differ from online curvature calculators?**
Most calculators skip refraction (k = 0.14 shifts the horizon ~18 % further
away), use different observer-height conventions (eye height vs ground
level), or reference chart datum instead of the water in front of you. The
app states every constant it uses — compare like with like.

**Does it work offline?**
Fully. Sensing, EKF, capture and the local queue are all offline-first.
Everything syncs when a connection returns. Only the map-based distance
helper and the uploads need data.

**Does it work without a barometer or GPS?**
The app requires barometer + gyroscope + GNSS by design: without them the
core altitude estimate is not trustworthy enough to publish.

**How big is an upload?**
A few hundred kilobytes — metadata JSON plus the raw sensor CSV (the whole
point is that researchers can re-verify from raw data).

**Is my location public?**
Uploaded measurements are pseudonymous (a random device ID, no account) and
dedicated to the public domain (CC0) — including your GPS coordinates and
raw sensor logs. Nothing is uploaded without your explicit tap on a capture
button, and nothing can be deleted afterwards (append-only ledger — see the
Safety & Legal screen).

**Why can't measurements be deleted?**
By design. The public dataset is an append-only ledger so nobody — including
us — can silently rewrite history. This is what makes the dataset auditable
and citable. Think before you upload; the disclaimer screen spells it out.

**The horizon doesn't sit where the cyan line says. Why?**
The HUD assumes a 60° vertical field of view (documented). Real phone FOVs
differ by a few degrees and zoom changes it. Use the *readout* numbers for
data; use the lines for orientation. Camera-FOV calibration is on the
roadmap.

**My dip came out negative / near zero.**
You likely aimed at a shoreline stacked in front of the true horizon, or
measured with the altitude still settling. Also check that you captured with
the crosshair *on* the horizon, not the water below it.

**Can I use this for real research?**
Yes — that is the point — but treat single measurements as evidence, not
proof: quote your uncertainties, average over conditions, publish raw logs
(they are included), and pair Eratosthenes measurements properly. The PDF
audit report exists so reviewers can check your chain of custody.
''';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const HudDocumentScaffold(
      title: 'Help & FAQ',
      tag: 'field manuals · sensor theory · frequently asked questions',
      headerIcon: Icons.help_outline,
      markdown: kHelpMarkdown,
    );
  }
}
