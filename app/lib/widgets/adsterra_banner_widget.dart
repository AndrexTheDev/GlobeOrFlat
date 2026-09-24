// ============================================================================
// GlobeOrFlat — Adsterra Banner Widgets
// SPDX-License-Identifier: MIT
//
// Adsterra serves banners as a JavaScript tag (`atOptions` + `invoke.js`),
// so on Flutter the industry-standard integration is a WebView wrapper that
// loads the tag HTML string. This file provides:
//
//   • AdsterraBanner    — the WebView-wrapped banner in three IAB sizes,
//                         with a clearly-labeled TEST placeholder when
//                         AdConfig.testMode is on or a zone is unconfigured.
//   • AdsterraBanner.sticky()  — 320×50 for the footer bar.
//   • AdsterraBanner.mediumRectangle() — 300×250 for mid-screen results.
//   • StickyAdBar       — SafeArea bottom container with a "sponsored" chip
//                         and a session-scoped collapse button (ad-fraud
//                         hygiene: no accidental clicks, no forced views).
//
// CAMERA-SCREEN RULE: banners must only be mounted on non-camera screens
// (dashboard, results, history). Never wrap the AR viewfinders.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/ad_config.dart';

/// IAB banner formats wired to Adsterra zone keys.
enum AdsterraBannerFormat {
  /// 320×50 — bottom sticky footer.
  sticky(320, 50, AdConfig.adsterraStickyZoneKey),

  /// 300×250 — mid-screen result banner.
  mediumRectangle(300, 250, AdConfig.adsterraResultZoneKey),

  /// 728×90 — tablets / landscape results.
  leaderboard(728, 90, AdConfig.adsterraResultZoneKey);

  const AdsterraBannerFormat(this.width, this.height, this.zoneKey);

  final int width;
  final int height;
  final String zoneKey;

  bool get isConfigured =>
      !zoneKey.startsWith('PASTE_') && zoneKey.trim().isNotEmpty;
}

/// WebView-wrapped Adsterra banner.
///
/// The widget reserves exactly [AdsterraBannerFormat.width]×
/// [AdsterraBannerFormat.height] logical pixels, scaled down if the host
/// screen is narrower (small phones in portrait).
class AdsterraBanner extends StatefulWidget {
  const AdsterraBanner({super.key, required this.format});

  const AdsterraBanner.sticky({super.key})
      : format = AdsterraBannerFormat.sticky;

  const AdsterraBanner.mediumRectangle({super.key})
      : format = AdsterraBannerFormat.mediumRectangle;

  final AdsterraBannerFormat format;

  @override
  State<AdsterraBanner> createState() => _AdsterraBannerState();
}

class _AdsterraBannerState extends State<AdsterraBanner> {
  WebViewController? _controller;
  bool _loadFailed = false;

  AdsterraBannerFormat get _format => widget.format;

  bool get _useLiveAd =>
      !AdConfig.testMode && _format.isConfigured && AdConfig.adsEnabled;

  @override
  void initState() {
    super.initState();
    if (_useLiveAd) {
      _controller = WebViewController()
        ..setJavaScriptMode(JavascriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..setNavigationDelegate(
          NavigationDelegate(
            // Keep the banner webview on the ad tag; external destinations
            // are the OS browser's job, not an embedded frame's.
            onNavigationRequest: (NavigationRequest request) {
              final Uri uri = Uri.parse(request.url);
              final String host = uri.host.toLowerCase();
              final String invokeHost =
                  AdConfig.adsterraInvokeHost.toLowerCase();
              final bool sameHost =
                  host.isEmpty || host.endsWith(invokeHost);
              return sameHost
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
            onWebResourceError: (WebResourceError _) {
              if (mounted) {
                setState(() => _loadFailed = true);
              }
            },
          ),
        )
        ..loadHtmlString(_buildAdHtml(_format));
    }
  }

  @override
  void dispose() {
    // WebViewController has no explicit dispose in v4 — dropping the
    // reference releases the native webview with the widget.
    _controller = null;
    super.dispose();
  }

  /// The exact snippet shape from the Adsterra dashboard, parameterized.
  static String _buildAdHtml(AdsterraBannerFormat format) {
    final int w = format.width;
    final int h = format.height;
    return '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<style>
  html, body { margin:0; padding:0; background:transparent; overflow:hidden;
               width:${w}px; height:${h}px; }
  iframe { border:0; }
</style>
</head>
<body>
<script type="text/javascript">
  atOptions = {
    'key'    : '${format.zoneKey}',
    'format' : 'iframe',
    'height' : $h,
    'width'  : $w,
    'params' : {}
  };
</script>
<script src="https://${AdConfig.adsterraInvokeHost}/${format.zoneKey}/invoke.js"></script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    final double scale = _scaleToFit(context, _format);
    final double w = _format.width * scale;
    final double h = _format.height * scale;

    return SizedBox(
      width: w,
      height: h,
      child: _useLiveAd && !_loadFailed
          ? WebViewWidget(controller: _controller!)
          : _TestAdPlaceholder(format: _format, failed: _loadFailed),
    );
  }

  static double _scaleToFit(BuildContext context, AdsterraBannerFormat format) {
    final double available =
        MediaQuery.sizeOf(context).width - 24; // breathing room
    final double natural = format.width.toDouble();
    if (available >= natural) return 1.0;
    return (available / natural).clamp(0.5, 1.0).toDouble();
  }
}

// ---------------------------------------------------------------------------
// Test / fallback placeholder — visibly fake, never hits the network
// ---------------------------------------------------------------------------

class _TestAdPlaceholder extends StatelessWidget {
  const _TestAdPlaceholder({required this.format, required this.failed});

  final AdsterraBannerFormat format;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final bool small = format.height <= 90;
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0E1A2B),
        border: Border.all(color: const Color(0xFF18E0FF).withOpacity(0.35)),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: EdgeInsets.symmetric(horizontal: small ? 10 : 16),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF18E0FF).withOpacity(0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              failed ? 'AD ERROR' : 'TEST AD',
              style: TextStyle(
                color: failed ? Colors.orangeAccent : const Color(0xFF18E0FF),
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              failed
                  ? 'Ad network unreachable — slot reserved'
                  : 'Adsterra ${format.width}×${format.height} — set the zone '
                      'key in ad_config.dart',
              maxLines: small ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
          if (!small) ...<Widget>[
            const SizedBox(width: 8),
            Icon(Icons.crop_square,
                size: 18, color: Colors.white.withOpacity(0.15)),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// StickyAdBar — bottom footer container for non-camera screens
// ---------------------------------------------------------------------------

/// Pins a banner to the bottom of the screen inside a SafeArea, with a
/// subtle "sponsored" tag and a session-scoped collapse (×) button.
class StickyAdBar extends StatefulWidget {
  const StickyAdBar({super.key, required this.child});

  final Widget child;

  @override
  State<StickyAdBar> createState() => _StickyAdBarState();
}

class _StickyAdBarState extends State<StickyAdBar> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    if (_collapsed) return const SizedBox.shrink();
    return Material(
      color: const Color(0xFF0B1320),
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Stack(
          children: <Widget>[
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(height: 14), // room for the sponsored chip
                Center(child: widget.child),
              ],
            ),
            const Positioned(
              left: 8,
              top: 2,
              child: _SponsoredChip(),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'Hide banner',
                color: Colors.white24,
                icon: const Icon(Icons.close),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  setState(() => _collapsed = true);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SponsoredChip extends StatelessWidget {
  const _SponsoredChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(3),
      ),
      child: const Text(
        'SPONSORED',
        style: TextStyle(
          color: Colors.white24,
          fontSize: 8,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Mid-screen result banner block: a 300×250 slot centered above the results
/// summary, with generous tap spacing and the sponsored chip. Drop this at
/// the top of a results column.
class MidResultBanner extends StatelessWidget {
  const MidResultBanner({super.key, this.title = 'Result summary'});

  /// Optional caption rendered above the slot (e.g. the results heading).
  final String title;

  @override
  Widget build(BuildContext context) {
    if (!AdConfig.adsEnabled) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Row(
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              const _SponsoredChip(),
            ],
          ),
        ),
        const Center(child: AdsterraBanner.mediumRectangle()),
      ],
    );
  }
}
