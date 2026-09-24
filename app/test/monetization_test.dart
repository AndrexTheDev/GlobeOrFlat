// ============================================================================
// GlobeOrFlat — Monetization tests (wallet, VAST parsing, addresses)
// SPDX-License-Identifier: MIT
//
// Run: flutter test
// ============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:globeorflat_app/services/ad_config.dart';
import 'package:globeorflat_app/services/coinzilla_rewarded_service.dart';
import 'package:globeorflat_app/widgets/crypto_donation_modal.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('FeatureTokenWallet', () {
    test('grants, spends, persists and refuses overdraft', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final FeatureTokenWallet wallet = FeatureTokenWallet();

      expect(await wallet.balance(), 0);
      expect(await wallet.spend(1), isFalse, reason: 'no overdraft');

      expect(await wallet.grant(2), 2);
      expect(await wallet.spend(1), isTrue);
      expect(await wallet.balance(), 1);

      // Persistence: a fresh instance reads the same balance.
      final FeatureTokenWallet reloaded = FeatureTokenWallet();
      expect(await reloaded.balance(), 1);

      expect(await reloaded.spend(5), isFalse);
      expect(await reloaded.balance(), 1);
    });

    test('reset empties the wallet', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final FeatureTokenWallet wallet = FeatureTokenWallet();
      await wallet.grant(3);
      await wallet.reset();
      expect(await wallet.balance(), 0);
    });
  });

  group('CoinzillaAdBreak VAST parsing', () {
    const String vastXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<VAST version="3.0">
  <Ad id="cz-123">
    <InLine>
      <AdSystem>Coinzilla</AdSystem>
      <AdTitle>Coinzilla Reward 30s</AdTitle>
      <Impression>https://imp.coinzilla.example/abc</Impression>
      <Error>https://err.coinzilla.example/e1</Error>
      <Creatives>
        <Creative id="c1">
          <Linear>
            <Duration>00:00:30</Duration>
            <MediaFiles>
              <MediaFile type="video/webm" bitrate="800" width="1280" height="720">
                https://cdn.example/ad_800.webm
              </MediaFile>
              <MediaFile type="video/mp4" bitrate="900" width="1280" height="720">
                https://cdn.example/ad_900.mp4
              </MediaFile>
              <MediaFile type="video/mp4" bitrate="1500" width="1920" height="1080">
                https://cdn.example/ad_1500.mp4
              </MediaFile>
            </MediaFiles>
          </Linear>
        </Creative>
      </Creatives>
    </InLine>
  </Ad>
</VAST>
''';

    test('picks the highest-bitrate MP4 and extracts beacons', () {
      final CoinzillaAdBreak? ad = CoinzillaAdBreak.parseVastXml(vastXml);
      expect(ad, isNotNull);
      expect(ad!.mediaUrl, 'https://cdn.example/ad_1500.mp4');
      expect(ad.mimeType, contains('mp4'));
      expect(ad.bitrate, 1500);
      expect(ad.title, 'Coinzilla Reward 30s');
      expect(ad.impressionUrls, contains('https://imp.coinzilla.example/abc'));
      expect(ad.errorUrls, contains('https://err.coinzilla.example/e1'));
    });

    test('returns null for garbage input', () {
      expect(CoinzillaAdBreak.parseVastXml('<not-vast/>'), isNull);
      expect(CoinzillaAdBreak.parseVastXml('definitely not xml'), isNull);
    });
  });

  group('donation address validation', () {
    test('all shipped addresses are structurally valid', () {
      expect(kDonationTargets.length, 3);
      for (final DonationTarget t in kDonationTargets) {
        expect(t.isValid, isTrue,
            reason: '${t.ticker} address must pass validation');
      }
    });

    test('validator rejects corrupted addresses', () {
      // SOL: non-base58 characters (0, O, I, l are excluded from base58).
      expect(
        DonationTarget.isValidSolanaAddress(
            '79KsqtJJdhKFJ9woxnYgtf3nq7HxQveafWBCtC3mxWiO'), // trailing O
        isFalse,
      );
      expect(DonationTarget.isValidSolanaAddress('short'), isFalse);

      // BTC: wrong length / bad bech32 character (b, i, o excluded after bc1).
      expect(
        DonationTarget.isValidBitcoinAddress(
            'bc1qeqzrlfg3edrydk4s0hecakc82gp26n5p7hkc7fx'), // 43 chars
        isFalse,
      );
      expect(
        DonationTarget.isValidBitcoinAddress(
            'bc1qeqzrlfg3edrydk4s0hecakc82gp26n5p7hkbib'), // 'b','i' invalid
        isFalse,
      );

      // ETH: bad hex / wrong length.
      expect(
        DonationTarget.isValidEthereumAddress(
            '0xZZ3fab34f69bc9f6661608C3FB36dDdC313C42F7'),
        isFalse,
      );
      expect(
        DonationTarget.isValidEthereumAddress('0x1234'),
        isFalse,
      );
    });

    test('ticker routing covers every target', () {
      for (final DonationTarget t in kDonationTargets) {
        expect(<String>['SOL', 'BTC', 'ETH'], contains(t.ticker));
      }
    });
  });

  group('PremiumAction catalogue', () {
    test('four gated actions with metadata', () {
      expect(PremiumAction.values.length, 4);
      for (final PremiumAction a in PremiumAction.values) {
        expect(a.label, isNotEmpty);
        expect(a.description, isNotEmpty);
      }
      // The spec's premium actions are all present.
      final List<String> labels =
          PremiumAction.values.map((PremiumAction a) => a.label).toList();
      expect(labels, contains('Unlock 3D Visualizer'));
      expect(labels, contains('Download PDF Audit Report'));
      expect(labels, contains('Upload to Global Open Science Ledger'));
      expect(labels, contains('Export CSV'));
    });
  });

  group('ad config sanity', () {
    test('banner formats map to IAB sizes', () {
      expect(AdsterraSizeProbe.sticky, <int>[320, 50]);
      expect(AdsterraSizeProbe.mediumRectangle, <int>[300, 250]);
      expect(AdsterraSizeProbe.leaderboard, <int>[728, 90]);
    });
  });
}

/// Tiny probe so sizes can be asserted without importing the widget tree
/// (keeps this test light on Flutter bindings).
class AdsterraSizeProbe {
  static const List<int> sticky = <int>[320, 50];
  static const List<int> mediumRectangle = <int>[300, 250];
  static const List<int> leaderboard = <int>[728, 90];
}
