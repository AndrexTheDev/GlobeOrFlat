// ============================================================================
// GlobeOrFlat — Contact & Developer Info
// SPDX-License-Identifier: MIT
//
// Developer credit (AndrexTheDev), contact email, GitHub repository link,
// crypto-donation entry point, plus the project's stack and license card.
// All outbound links go through url_launcher with graceful failure states.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/crypto_donation_modal.dart';
import '../widgets/hud_document_scaffold.dart';

/// Maintainer identity (single source of truth for UI + report stamps).
const String kDeveloperName = 'AndrexTheDev';
const String kContactEmail = 'hippie.highho@gmail.com';
const String kGitHubRepoUrl = 'https://github.com/AndrexTheDev/GlobeOrFlat';
const String kProjectLicense = 'MIT';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return HudDocumentScaffold(
      title: 'About & Contact',
      tag: 'the humans behind the instruments',
      headerIcon: Icons.person_pin_rounded,
      markdown: _aboutMarkdown(),
      bottom: _ActionBar(onDonate: () => showCryptoDonationModal(context)),
    );
  }

  String _aboutMarkdown() {
    return '''
# GlobeOrFlat

**Append-only citizen-science geodesy.** A Flutter instrument and an
open (MIT) measurement API, built so that anyone can test the shape of
the world with the sensors in their pocket — and so researchers can audit
every single raw sample afterwards.

## The developer

Made with stubborn curiosity by **$kDeveloperName**.

- Maintenance, backend, sensor fusion, physics models, this app.
- If a measurement of yours ends up cited somewhere, that is the dream.

## Contact

- **Email:** [$kContactEmail](mailto:$kContactEmail) — bug reports, field
  stories, research collaboration, press.
- **GitHub:** [AndrexTheDev/GlobeOrFlat]($kGitHubRepoUrl) — the backend
  (Cloudflare Workers + Hono + D1 + R2) and this app, both MIT.
  Issues and PRs are welcome: run the test suites before submitting, and
  note that changes weakening the append-only guarantees are rejected.

## Under the hood

| Layer | Tech |
| --- | --- |
| Backend API | Cloudflare Workers · Hono · D1 (SQLite) · R2 |
| Data integrity | ECDSA P-256 Android Keystore signatures (GOFv1) |
| Altitude fusion | Extended Kalman Filter (barometer ⊕ GNSS ⊕ IMU) |
| App | Flutter · sensors_plus · geolocator · CustomPainter HUDs |
| Data license | CC0 (measurements) · MIT (code) |

## Support the project

Servers, GNSS test rigs and coffee are funded by ads and donations. If the
ads annoy you, the crypto modal below is the direct route — every satoshi,
lamport and gwei goes into keeping the public measurement API free.

*$kDeveloperName — stay curious, stay empirical.*
''';
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.onDonate});

  final VoidCallback onDonate;

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
              SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE93EFF),
                    foregroundColor: const Color(0xFF0B1320),
                    textStyle: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  onPressed: onDonate,
                  icon: const Icon(Icons.currency_bitcoin),
                  label: const Text('SUPPORT PROJECT VIA CRYPTO'),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF4CFF87)),
                        foregroundColor: const Color(0xFF4CFF87),
                      ),
                      onPressed: () => AboutScreenLauncher.launchGitHub(context),
                      icon: const Icon(Icons.code, size: 18),
                      label: const Text('GitHub', overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.tealAccent.shade200),
                        foregroundColor: Colors.tealAccent.shade200,
                      ),
                      onPressed: () => AboutScreenLauncher.launchEmail(context),
                      icon: const Icon(Icons.mail_outline, size: 18),
                      label: const Text('Email', overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Static launchers kept separate so tests can exercise URL construction
/// without widget bindings.
class AboutScreenLauncher {
  static Uri emailUri() => Uri(
        scheme: 'mailto',
        path: kContactEmail,
        query: 'subject=GlobeOrFlat%20—%20hello%20from%20a%20fellow%20measurer',
      );

  static Uri githubUri() => Uri.parse(kGitHubRepoUrl);

  static Future<void> launchEmail(BuildContext context) async {
    try {
      await launchUrl(emailUri(), mode: LaunchMode.externalApplication);
    } on Exception {
      _notify(context, 'email');
    }
  }

  static Future<void> launchGitHub(BuildContext context) async {
    try {
      await launchUrl(githubUri(), mode: LaunchMode.externalApplication);
    } on Exception {
      _notify(context, 'the GitHub repository');
    }
  }

  static void _notify(BuildContext context, String what) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF102A43),
          content: Text('Could not open $what — no app handles this link.'),
        ),
      );
    }
  }
}
