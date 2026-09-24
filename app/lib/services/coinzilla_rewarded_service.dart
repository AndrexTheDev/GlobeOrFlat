// ============================================================================
// GlobeOrFlat — Coinzilla Rewarded Video + Feature Token Wallet
// SPDX-License-Identifier: MIT
//
// Coinzilla does not ship a native Flutter SDK, so rewarded video is
// integrated the standard way for web-oriented networks:
//
//   1. Fetch the VAST 2/3/4 tag (or use a direct MP4 link) from ad_config.
//   2. Extract the best `MediaFile` (prefer MP4, highest bitrate).
//   3. Play it in a fullscreen non-dismissable modal with a minimum watch
//      clock (30 s production / 5 s test placeholder).
//   4. On completion → grant a Feature Token → the caller consumes it for a
//      [PremiumAction] (PDF report, CSV export, 3D visualizer, ledger push).
//
// POLICY (documented in AdConfig): if the ad network itself fails, the
// reward is granted anyway — an ad-server outage must never block a
// scientific export. Set `AdConfig.grantRewardOnAdFailure = false` for
// strict behaviour.
// ============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:xml/xml.dart';

import 'ad_config.dart';

// ---------------------------------------------------------------------------
// Feature token wallet (persisted, observable)
// ---------------------------------------------------------------------------

/// Persists unspent feature tokens. Users can stock tokens while online and
/// spend them later — premium actions check the wallet before showing ads.
class FeatureTokenWallet {
  FeatureTokenWallet({SharedPreferences? prefs}) : _prefsOverride = prefs;

  static final FeatureTokenWallet instance = FeatureTokenWallet();

  static const String _prefKey = 'gof_feature_tokens';

  final SharedPreferences? _prefsOverride;
  final ValueNotifier<int> balanceNotifier = ValueNotifier<int>(0);

  bool _loaded = false;
  int _balance = 0;

  Future<SharedPreferences> _resolvePrefs() async =>
      _prefsOverride ?? SharedPreferences.getInstance();

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final SharedPreferences prefs = await _resolvePrefs();
    _balance = prefs.getInt(_prefKey) ?? 0;
    balanceNotifier.value = _balance;
    _loaded = true;
  }

  /// Current balance (loads on first call).
  Future<int> balance() async {
    await _ensureLoaded();
    return _balance;
  }

  /// Adds tokens (default 1) and persists. Returns the new balance.
  Future<int> grant([int amount = 1]) async {
    await _ensureLoaded();
    assert(amount > 0);
    _balance += amount;
    await (await _resolvePrefs()).setInt(_prefKey, _balance);
    balanceNotifier.value = _balance;
    return _balance;
  }

  /// Consumes tokens; returns false when the balance is insufficient.
  Future<bool> spend([int amount = 1]) async {
    await _ensureLoaded();
    if (_balance < amount) return false;
    _balance -= amount;
    await (await _resolvePrefs()).setInt(_prefKey, _balance);
    balanceNotifier.value = _balance;
    return true;
  }

  /// Empties the wallet (support / testing).
  Future<void> reset() async {
    await _ensureLoaded();
    _balance = 0;
    await (await _resolvePrefs()).setInt(_prefKey, 0);
    balanceNotifier.value = 0;
  }
}

// ---------------------------------------------------------------------------
// Outcome + service
// ---------------------------------------------------------------------------

/// Result of a rewarded-ad attempt.
enum RewardedAdOutcome {
  /// Watched to completion — a token was granted.
  earned,

  /// User quit before completion — nothing granted.
  dismissedEarly,

  /// The ad network failed (no fill, timeout, playback error).
  failed,
}

/// Rewarded-video gateway for all [PremiumAction]s.
class CoinzillaRewardedService {
  CoinzillaRewardedService({FeatureTokenWallet? wallet, http.Client? client})
      : wallet = wallet ?? FeatureTokenWallet.instance,
        _client = client ?? http.Client();

  final FeatureTokenWallet wallet;
  final http.Client _client;

  bool get _hasAdCreative =>
      AdConfig.coinzillaVastTagUrl.trim().isNotEmpty ||
      AdConfig.coinzillaDirectVideoUrl.trim().isNotEmpty;

  /// Plays a rewarded ad and grants a token on completion.
  /// Returns the outcome; the token is already in the wallet when `earned`.
  Future<RewardedAdOutcome> showRewardedAd(
    BuildContext context, {
    required String rewardName,
  }) async {
    if (!AdConfig.rewardedAdsEnabled) {
      return RewardedAdOutcome.earned; // free build — everything unlocked
    }
    final RewardedAdOutcome? outcome = await showDialog<RewardedAdOutcome>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black,
      useSafeArea: false,
      builder: (BuildContext ctx) =>
          _RewardedVideoModal(rewardName: rewardName, client: _client),
    );
    final RewardedAdOutcome result = outcome ?? RewardedAdOutcome.dismissedEarly;
    if (result == RewardedAdOutcome.earned) {
      await wallet.grant(1);
      HapticFeedback.mediumImpact();
    }
    return result;
  }

  /// Ensures the user is entitled to [action]: spends a stocked token, or
  /// runs the rewarded flow. Returns true when the action may proceed.
  Future<bool> ensureEntitlement(
    BuildContext context,
    PremiumAction action,
  ) async {
    if (await wallet.spend(1)) {
      return true; // pre-stocked token spent
    }
    final RewardedAdOutcome outcome = await showRewardedAd(
      context,
      rewardName: action.label,
    );
    switch (outcome) {
      case RewardedAdOutcome.earned:
        // Consume the freshly granted token for this action.
        await wallet.spend(1);
        return true;
      case RewardedAdOutcome.failed:
        final bool unlock = AdConfig.grantRewardOnAdFailure;
        if (unlock && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF102A43),
              content: Text(
                  'Ad unavailable — ${action.label} unlocked anyway. '
                  'Consider supporting the project with a donation ♥'),
            ),
          );
        }
        return unlock;
      case RewardedAdOutcome.dismissedEarly:
        return false;
    }
  }

  /// Fetches and parses the VAST tag. Exposed for testing/mocking.
  Future<CoinzillaAdBreak?> fetchAdBreak() async {
    final String tag = AdConfig.coinzillaVastTagUrl.trim();
    if (tag.isNotEmpty) {
      try {
        final http.Response response =
            await _client.get(Uri.parse(tag)).timeout(AdConfig.networkTimeout);
        if (response.statusCode == 200) {
          return CoinzillaAdBreak.parseVastXml(response.body);
        }
      } on TimeoutException {
        return null;
      } on Exception {
        return null;
      }
    }
    final String direct = AdConfig.coinzillaDirectVideoUrl.trim();
    if (direct.isNotEmpty) {
      return CoinzillaAdBreak(
        mediaUrl: direct,
        mimeType: 'video/mp4',
        title: 'Coinzilla reward',
      );
    }
    return null;
  }

  /// Best-effort impression/error beacon — never throws, never blocks.
  Future<void> fireBeacon(String url) async {
    try {
      await _client
          .get(Uri.parse(url), headers: const <String, String>{
        'user-agent': 'GlobeOrFlat/1.0',
      }).timeout(AdConfig.networkTimeout);
    } on Exception {
      // Beacons are fire-and-forget by contract.
    }
  }
}

// ---------------------------------------------------------------------------
// Minimal VAST parsing
// ---------------------------------------------------------------------------

/// One linear ad break extracted from a VAST document.
class CoinzillaAdBreak {
  const CoinzillaAdBreak({
    required this.mediaUrl,
    required this.mimeType,
    this.bitrate = 0,
    this.title = '',
    this.impressionUrls = const <String>[],
    this.errorUrls = const <String>[],
  });

  final String mediaUrl;
  final String mimeType;
  final int bitrate;
  final String title;
  final List<String> impressionUrls;
  final List<String> errorUrls;

  /// Parses the first linear creative out of a VAST 2/3/4 document.
  /// Namespace-agnostic (VAST 4 uses a default xmlns, 2/3 usually do not).
  static CoinzillaAdBreak? parseVastXml(String xmlText) {
    late final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlText);
    } on XmlException {
      return null;
    }

    final List<XmlElement> all =
        doc.descendants.whereType<XmlElement>().toList(growable: false);

    String? pickText(String localName) {
      for (final XmlElement e in all) {
        if (e.name.local == localName) {
          final String t = e.innerText.trim();
          if (t.isNotEmpty) return t;
        }
      }
      return null;
    }

    XmlElement? best;
    int bestScore = -1;
    for (final XmlElement e in all) {
      if (e.name.local != 'MediaFile') continue;
      final String type =
          (e.getAttribute('type') ?? e.getAttribute('mediaType') ?? '')
              .toLowerCase();
      final int bitrate =
          int.tryParse(e.getAttribute('bitrate') ?? '0') ?? 0;
      int score = bitrate;
      if (type.contains('mp4')) score += 100000; // device-safe container
      if (type.contains('webm')) score += 100; // playable, but prefer mp4
      if (score > bestScore) {
        bestScore = score;
        best = e;
      }
    }
    final String? mediaUrl = best?.innerText.trim();
    if (mediaUrl == null || mediaUrl.isEmpty) return null;

    final List<String> impressions = <String>[];
    final List<String> errors = <String>[];
    for (final XmlElement e in all) {
      final String t = e.innerText.trim();
      if (t.isEmpty) continue;
      if (e.name.local == 'Impression' && Uri.tryParse(t) != null) {
        impressions.add(t);
      } else if (e.name.local == 'Error' && Uri.tryParse(t) != null) {
        errors.add(t);
      }
    }

    return CoinzillaAdBreak(
      mediaUrl: mediaUrl,
      mimeType: (best?.getAttribute('type') ?? 'video/mp4').toLowerCase(),
      bitrate: int.tryParse(best?.getAttribute('bitrate') ?? '0') ?? 0,
      title: pickText('AdTitle') ?? 'Coinzilla reward',
      impressionUrls: impressions,
      errorUrls: errors,
    );
  }
}

// ---------------------------------------------------------------------------
// Fullscreen rewarded modal
// ---------------------------------------------------------------------------

enum _ModalPhase { loading, playing, completed, error }

class _RewardedVideoModal extends StatefulWidget {
  const _RewardedVideoModal({required this.rewardName, required this.client});

  final String rewardName;
  final http.Client client;

  @override
  State<_RewardedVideoModal> createState() => _RewardedVideoModalState();
}

class _RewardedVideoModalState extends State<_RewardedVideoModal> {
  final Stopwatch _watch = Stopwatch();
  _ModalPhase _phase = _ModalPhase.loading;
  String? _errorText;

  VideoPlayerController? _video;
  CoinzillaAdBreak? _adBreak;
  bool _usingTestCreative = false;
  bool _muted = true;
  Duration _elapsed = Duration.zero;
  bool _finished = false;

  Duration get _requiredDuration => Duration(
        seconds: (AdConfig.testMode || !_hasCreative)
            ? AdConfig.testRewardedAdDurationSeconds
            : AdConfig.rewardedAdDurationSeconds,
      );

  bool get _hasCreative =>
      AdConfig.coinzillaVastTagUrl.trim().isNotEmpty ||
      AdConfig.coinzillaDirectVideoUrl.trim().isNotEmpty;

  int get _remainingSeconds =>
      (_requiredDuration - _elapsed).inSeconds.clamp(0, 999).toInt();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _watch.stop();
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Retry hygiene: release a previous (possibly failed) controller and
    // clear the completion latch so the flow can run again.
    _video?.removeListener(_onVideoTick);
    await _video?.dispose();
    _video = null;
    _finished = false;
    setState(() {
      _phase = _ModalPhase.loading;
      _errorText = null;
    });

    // Test mode / unconfigured build → synthetic placeholder creative.
    if (AdConfig.testMode || !_hasCreative) {
      _usingTestCreative = true;
      _startWatchClock();
      return;
    }

    final CoinzillaRewardedService service = CoinzillaRewardedService(
      client: widget.client,
    );
    final CoinzillaAdBreak? adBreak = await service.fetchAdBreak();
    if (!mounted) return;
    if (adBreak == null) {
      setState(() {
        _phase = _ModalPhase.error;
        _errorText = 'No ad response from Coinzilla (no fill or offline).';
      });
      return;
    }
    _adBreak = adBreak;

    try {
      final VideoPlayerController controller =
          VideoPlayerController.networkUrl(Uri.parse(adBreak.mediaUrl));
      _video = controller;
      await controller.initialize();
      if (!mounted) return;
      await controller.setVolume(_muted ? 0 : 1);
      await controller.setLooping(true);
      await controller.play();
      controller.addListener(_onVideoTick);
      setState(() => _phase = _ModalPhase.playing);
      _startWatchClock();

      // Fire the impression beacon best-effort.
      for (final String url in adBreak.impressionUrls.take(1)) {
        unawaited(service.fireBeacon(url));
      }
    } on Exception catch (e) {
      if (!mounted) return;
      for (final String url in _adBreak?.errorUrls.take(1) ?? const <String>[]) {
        unawaited(service.fireBeacon(url));
      }
      setState(() {
        _phase = _ModalPhase.error;
        _errorText = 'Playback failed: $e';
      });
    }
  }

  void _startWatchClock() {
    _watch
      ..reset()
      ..start();
    // One shared ticker drives the ring for both test + real creatives.
    Timer.periodic(const Duration(milliseconds: 200), (Timer t) {
      if (!mounted || _finished) {
        t.cancel();
        return;
      }
      setState(() => _elapsed = _watch.elapsed);
      if (_watch.elapsed >= _requiredDuration) {
        t.cancel();
        _complete();
      }
    });
  }

  void _onVideoTick() {
    final VideoPlayerController? v = _video;
    if (v == null) return;
    if (v.value.hasError && !_finished && mounted) {
      setState(() {
        _phase = _ModalPhase.error;
        _errorText = v.value.errorDescription ?? 'Video error';
      });
    }
  }

  Future<void> _complete() async {
    if (_finished) return;
    _finished = true;
    _watch.stop();
    await _video?.pause();
    if (!mounted) return;
    setState(() => _phase = _ModalPhase.completed);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    if (mounted) {
      Navigator.of(context).pop(RewardedAdOutcome.earned);
    }
  }

  Future<void> _quitEarly() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: const Color(0xFF102A43),
        title: const Text('Quit the ad?'),
        content: Text(
            'You will not receive “${widget.rewardName}” if you leave now.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep watching'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Quit',
                style: TextStyle(color: Colors.orangeAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(context).pop(RewardedAdOutcome.dismissedEarly);
    }
  }

  Future<void> _toggleMute() async {
    setState(() => _muted = !_muted);
    await _video?.setVolume(_muted ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<RewardedAdOutcome>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, RewardedAdOutcome? result) {
        if (!didPop) {
          _quitEarly();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF05080F),
        body: SafeArea(
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: _buildPhase()),
              _buildTopBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 8,
      left: 12,
      right: 12,
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'REWARDED · ${AdConfig.testMode ? 'TEST' : 'COINZILLA'}',
              style: const TextStyle(
                color: Color(0xFF18E0FF),
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: _muted ? 'Unmute' : 'Mute',
            onPressed: _usingTestCreative ? null : _toggleMute,
            icon: Icon(
              _muted ? Icons.volume_off : Icons.volume_up,
              color: Colors.white70,
            ),
          ),
          IconButton(
            tooltip: 'Quit ad',
            onPressed: _quitEarly,
            icon: const Icon(Icons.close, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _buildPhase() {
    switch (_phase) {
      case _ModalPhase.loading:
        return const _PhaseLoading();
      case _ModalPhase.playing:
        return _usingTestCreative
            ? _PhaseTestCreative(remaining: _remainingSeconds)
            : _PhaseVideo(controller: _video!);
      case _ModalPhase.completed:
        return _PhaseCompleted(rewardName: widget.rewardName);
      case _ModalPhase.error:
        return _PhaseError(errorText: _errorText ?? 'Unknown error',
            onRetry: _load);
    }
  }
}

// ---------------------------------------------------------------------------
// Phase widgets
// ---------------------------------------------------------------------------

class _PhaseLoading extends StatelessWidget {
  const _PhaseLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(color: Color(0xFF18E0FF)),
          const SizedBox(height: 18),
          Text(
            'Contacting Coinzilla…',
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 13,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _PhaseVideo extends StatelessWidget {
  const _PhaseVideo({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final Size size = controller.value.size;
    return Center(
      child: AspectRatio(
        aspectRatio: size.width > 0 && size.height > 0
            ? size.width / size.height
            : 16 / 9,
        child: VideoPlayer(controller),
      ),
    );
  }
}

/// Clearly-labeled synthetic creative used in test mode / unconfigured builds.
class _PhaseTestCreative extends StatelessWidget {
  const _PhaseTestCreative({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.movie_filter,
              size: 72, color: const Color(0xFF18E0FF).withOpacity(0.7)),
          const SizedBox(height: 16),
          const Text(
            'TEST AD PLACEHOLDER',
            style: TextStyle(
              color: Color(0xFF18E0FF),
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Coinzilla rewarded video renders here\nin production',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 24),
          Text(
            '$remaining s',
            style: const TextStyle(
                color: Colors.white, fontSize: 34, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _PhaseCompleted extends StatelessWidget {
  const _PhaseCompleted({required this.rewardName});

  final String rewardName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.verified, color: Color(0xFF4CFF87), size: 72),
          const SizedBox(height: 14),
          const Text(
            'REWARD EARNED',
            style: TextStyle(
              color: Color(0xFF4CFF87),
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '“$rewardName” is unlocked',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _PhaseError extends StatelessWidget {
  const _PhaseError({required this.errorText, required this.onRetry});

  final String errorText;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.cloud_off, color: Colors.orangeAccent, size: 56),
            const SizedBox(height: 14),
            const Text(
              'Ad unavailable',
              style: TextStyle(
                  color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              errorText,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                OutlinedButton(
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
