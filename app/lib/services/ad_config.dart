// ============================================================================
// GlobeOrFlat — Ad & Monetization Configuration
// SPDX-License-Identifier: MIT
//
// Central place for network keys and monetization policy. NO ad code runs in
// test mode: placeholder creatives are shown so layout/UX can be verified
// without hitting live networks (and without generating junk impressions).
//
// PRODUCTION CHECKLIST
//   1. Adsterra: create two banner zones in the dashboard (320×50 sticky,
//      300×250 mid-result), paste the zone `key` values below, and set the
//      invoke domain shown in your snippet (it varies per account).
//   2. Coinzilla: copy your VAST tag URL (or direct MP4 link) for the
//      rewarded placement.
//   3. Flip `testMode` to false.
//   4. Never commit real keys to a public fork of this repo.
// ============================================================================

/// Global monetization configuration.
class AdConfig {
  AdConfig._();

  /// MASTER SWITCH: while true, no live ad network is contacted and clearly
  /// labeled placeholder creatives render instead.
  static const bool testMode = true;

  /// Sticky banners + mid-result banners (Adsterra). Disable to ship an
  /// entirely ad-free build (donation-funded).
  static const bool adsEnabled = true;

  /// Rewarded video (Coinzilla). Disable to make premium actions free.
  static const bool rewardedAdsEnabled = true;

  // -------------------------------------------------------------------------
  // Adsterra (display banners, WebView-wrapped JS tag)
  // -------------------------------------------------------------------------

  /// Zone key for the 320×50 sticky footer banner.
  static const String adsterraStickyZoneKey = 'PASTE_STICKY_320x50_ZONE_KEY';

  /// Zone key for the 300×250 mid-screen result banner.
  static const String adsterraResultZoneKey = 'PASTE_RESULT_300x250_ZONE_KEY';

  /// The invoke.js host from your Adsterra snippet (varies per account,
  /// e.g. www.topcreativeformat.com / www.highperformanceformat.com).
  static const String adsterraInvokeHost = 'www.highperformanceformat.com';

  // -------------------------------------------------------------------------
  // Coinzilla (rewarded video, VAST tag or direct MP4)
  // -------------------------------------------------------------------------

  /// VAST 2/3/4 tag URL for the rewarded placement. Leave empty when using a
  /// direct video link instead.
  static const String coinzillaVastTagUrl = '';

  /// Direct video URL fallback when no VAST tag is configured.
  static const String coinzillaDirectVideoUrl = '';

  /// Minimum watch time before the reward callback fires [seconds].
  static const int rewardedAdDurationSeconds = 30;

  /// Placeholder "ad" duration in test mode [seconds] — short on purpose so
  /// developers can exercise the whole reward flow quickly.
  static const int testRewardedAdDurationSeconds = 5;

  /// PRODUCT DECISION: when the ad network fails (offline, no fill, timeout)
  /// the reward is granted anyway. GlobeOrFlat is an open-science tool — a
  /// network outage on a third party must never block a measurement export.
  /// Set to false for strict ads-must-complete behaviour.
  static const bool grantRewardOnAdFailure = true;

  /// Ad request / VAST fetch timeout.
  static const Duration networkTimeout = Duration(seconds: 10);
}

/// The gated premium actions (rewarded video triggers).
enum PremiumAction {
  unlock3dVisualizer('Unlock 3D Visualizer',
      'Interactive 3D globe/flat visualizer for your measurement'),
  downloadPdfAuditReport('Download PDF Audit Report',
      'Formal multi-page audit report with sensor telemetry and signatures'),
  uploadScienceLedger('Upload to Global Open Science Ledger',
      'Priority submission of your measurement to the public ledger'),
  exportCsv('Export CSV', 'Export the raw sensor log as a CSV file');

  const PremiumAction(this.label, this.description);

  final String label;
  final String description;
}
