// ============================================================================
// GlobeOrFlat — Safety & Legal Disclaimer
// SPDX-License-Identifier: MIT
//
// Two obligations in one screen:
//   1. PHYSICAL SAFETY — this app invites people to stand near cliffs,
//      water and roads while staring at a screen. Be explicit about it.
//   2. INFORMED CONSENT — measurements become PUBLIC and PERMANENT
//      (append-only ledger, CC0). Users must understand that before the
//      first upload.
//
// Shown read-only from the dashboard, and in acknowledgment mode before the
// first calibration (onAccepted != null) — hard-gated like calibration.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/hud_document_scaffold.dart';

/// Preference key for the first-run acceptance stamp.
const String kDisclaimerAcceptedKey = 'gof_disclaimer_accepted_v1';

/// Reads whether the disclaimer has been accepted on this install.
Future<bool> isDisclaimerAccepted() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kDisclaimerAcceptedKey) ?? false;
}

/// The full disclaimer document (Markdown).
const String kDisclaimerMarkdown = r'''
# Safety & Legal Disclaimer

## ⚠️ Physical safety — read before measuring

**Your surroundings are more dangerous than any flat-Earth debate.** This
app asks you to look at a screen at sea fronts, cliff edges and roadsides.
Take the following seriously:

- ** NEVER while driving.** Do not set up, start, monitor or stop a
  measurement while operating any vehicle. For Track & Curve runs: mount
  the phone, start the recording **while parked**, drive, then stop only
  after parking again. Operating a phone while driving is illegal in most
  jurisdictions and dangerous everywhere.
- **Cliffs and edges kill without drama.** Stay behind barriers and outside
  fence lines. Attention locked on a viewfinder has pushed people off
  edges; do not back up while looking at the screen.
- **Water bodies are treacherous at the exact places you will stand.**
  Slipway algae, wet rock, rising tides, surf overtopping sea walls. Check
  tide times; never turn your back on the sea; one person watching the
  water while the other measures is not paranoia.
- **Never look at or into the sun** — not with your eyes, not through the
  camera. Mode D (Eratosthenes) only ever photographs *shadows*.
- **Urban measuring:** step out of flow paths, watch for traffic, trip
  hazards and other people. No measurement is worth colliding with anyone.
- **Private property:** ports, military sites, fenced land — observe from
  public ground or get permission.
- **Weather:** wet rock, lightning and strong wind all beat curiosity.

You are responsible for your own safety. GlobeOrFlat's developers accept no
liability for injury, loss or damage arising from use of the app.

## 🔬 Scientific disclaimer — what this app can and cannot claim

GlobeOrFlat runs on **consumer hardware with real tolerances**, and every
result it produces must be read as an estimate with uncertainty:

- **Sensors.** MEMS barometers resolve single pascals but drift with weather
  and temperature; phone GNSS vertical error is typically 3–10 m and 1.5–3×
  the horizontal error; accelerometers and gyroscopes carry bias and noise
  that calibration reduces but never removes. Absolute barometric altitude
  is only good to roughly ±8 m before the EKF anchors it to GNSS.
- **Refraction varies.** The standard atmospheric refraction coefficient
  (k = 0.14) is an average, not a law. Real conditions range from slightly
  negative k (sinking horizon) to strong ducting (k > 0.5) that can show
  objects that are geometrically hidden — or hide more than geometry says.
  Mirage, looming and fog bands routinely bend single observations by more
  than the effect being measured.
- **Single measurements are evidence, not proof.** The honest outputs of
  this app are *averages over conditions* with *quoted spreads*, ideally
  from many devices and many sites. That is exactly why every upload keeps
  its raw sensor log and calibration status attached.
- **Not for navigation, surveying, engineering, legal or safety-of-life
  use.** The app is a citizen-science instrument and an educational tool.
  It is not certified for any professional purpose, and no result from it
  should be used where an error could cause harm.

## 🔒 Your data becomes public and permanent

- Uploaded measurements are **dedicated to the public domain (CC0)** and
  served to anyone via the open API — including GPS coordinates, raw sensor
  logs and calibration data.
- Uploads are **append-only**: there is no edit and no delete, by design,
  for anyone — including the maintainers. This is what makes the dataset
  auditable and trustworthy.
- Identity is **pseudonymous** (a random device ID, no account, no email),
  but pseudonymous is not anonymous: do not upload measurements from
  private locations you would not want associated with a public dataset.
- The app itself processes nothing in the cloud; sensing, fusion and
  calibration run entirely on-device.

## ⚖️ License and warranty

GlobeOrFlat is open source under the **MIT License**: provided "as is",
without warranty of any kind, express or implied. In no event shall the
authors or copyright holders be liable for any claim, damages or other
liability arising from the software. By using the app you accept these
terms. Full license text lives in the repository's `LICENSE` file.
''';

class DisclaimerScreen extends StatelessWidget {
  const DisclaimerScreen({super.key, this.onAccepted});

  /// When non-null the screen runs in first-run acknowledgment mode: a
  /// prominent accept action replaces normal browsing and the user cannot
  /// proceed to measurements without it.
  final VoidCallback? onAccepted;

  @override
  Widget build(BuildContext context) {
    final bool ackMode = onAccepted != null;
    return HudDocumentScaffold(
      title: 'Safety & Legal',
      tag: 'outdoor safety · sensor tolerances · data permanence',
      headerIcon: Icons.gpp_maybe_outlined,
      accent: const Color(0xFFFFB454),
      markdown: kDisclaimerMarkdown,
      bottom: ackMode ? _AcknowledgeBar(onAccepted: onAccepted!) : null,
    );
  }
}

class _AcknowledgeBar extends StatelessWidget {
  const _AcknowledgeBar({required this.onAccepted});

  final VoidCallback onAccepted;

  Future<void> _accept(BuildContext context) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kDisclaimerAcceptedKey, true);
    onAccepted();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0B1320),
      elevation: 10,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'I have read and accept the safety rules, the scientific '
                'limits and the permanent-public-data policy.',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFB454),
                    foregroundColor: const Color(0xFF0B1320),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  onPressed: () => _accept(context),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('ACCEPT & CONTINUE'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
