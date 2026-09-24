// ============================================================================
// GlobeOrFlat — Crypto Donation Modal (Cyberpunk)
// SPDX-License-Identifier: MIT
//
// A sleek "support the developer" dialog with scannable QR codes and 1-tap
// copy for the three donation addresses (Solana / Bitcoin / Ethereum).
//
// Design notes:
//   • QRs encode the PLAIN address (no URI scheme) for maximum wallet-
//     scanner compatibility; advanced users paste the address instead.
//   • QRs render on a white quiet-zone panel with near-black modules — the
//     only reliable combo for phone-camera scanning.
//   • Address validators are pure functions, unit-tested in
//     test/monetization_test.dart (the shipped addresses pass real checksum
//     validation: BTC bech32 polymod, SOL base58→32-byte ed25519 pubkey).
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

// ---------------------------------------------------------------------------
// Donation targets + validation (pure, testable)
// ---------------------------------------------------------------------------

class DonationTarget {
  const DonationTarget({
    required this.chain,
    required this.ticker,
    required this.address,
    required this.accent,
    required this.note,
  });

  final String chain;
  final String ticker;
  final String address;
  final Color accent;
  final String note;

  // ---- format validators (checksum-level verification lives in the tests --

  static const String _base58Alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  /// Base58 (Bitcoin alphabet), decodes to a 32-byte ed25519 pubkey.
  static bool isValidSolanaAddress(String address) {
    if (address.length < 32 || address.length > 44) return false;
    for (final int code in address.codeUnits) {
      if (!_base58Alphabet.contains(String.fromCharCode(code))) return false;
    }
    return true;
  }

  /// Bech32 (BIP-173) P2WPKH shape: bc1 + 39 charset chars. Full polymod
  /// checksum verification is covered by the reference test.
  static bool isValidBitcoinAddress(String address) {
    if (!address.startsWith('bc1') || address.length != 42) return false;
    const String charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
    for (final int code in address.substring(3).codeUnits) {
      final String c = String.fromCharCode(code).toLowerCase();
      if (!charset.contains(c)) return false;
    }
    return true;
  }

  /// 0x + 40 hex digits (EIP-55 mixed case accepted).
  static bool isValidEthereumAddress(String address) {
    if (!address.startsWith('0x') || address.length != 42) return false;
    return RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(address.substring(2));
  }

  bool get isValid {
    switch (ticker) {
      case 'SOL':
        return isValidSolanaAddress(address);
      case 'BTC':
        return isValidBitcoinAddress(address);
      case 'ETH':
        return isValidEthereumAddress(address);
      default:
        return false;
    }
  }
}

/// The maintainer's official donation addresses (verified in CI).
const List<DonationTarget> kDonationTargets = <DonationTarget>[
  DonationTarget(
    chain: 'Solana',
    ticker: 'SOL',
    address: '79KsqtJJdhKFJ9woxnYgtf3nq7HxQveafWBCtC3mxWi8',
    accent: Color(0xFF14F195),
    note: 'Fastest & cheapest — preferred',
  ),
  DonationTarget(
    chain: 'Bitcoin',
    ticker: 'BTC',
    address: 'bc1qeqzrlfg3edrydk4s0hecakc82gp26n5p7hkc7f',
    accent: Color(0xFFF7931A),
    note: 'Native SegWit (bech32)',
  ),
  DonationTarget(
    chain: 'Ethereum',
    ticker: 'ETH',
    address: '0xBC3fab34f69bc9f6661608C3FB36dDdC313C42F7',
    accent: Color(0xFF627EEA),
    note: 'Mainnet / L2s',
  ),
];

/// Opens the cyberpunk donation dialog.
Future<void> showCryptoDonationModal(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0xB3000000),
    builder: (BuildContext ctx) => const _CyberDonationDialog(),
  );
}

// ---------------------------------------------------------------------------
// Dialog
// ---------------------------------------------------------------------------

class _CyberDonationDialog extends StatelessWidget {
  const _CyberDonationDialog();

  @override
  Widget build(BuildContext context) {
    final double width =
        (MediaQuery.sizeOf(context).width - 32).clamp(280.0, 420.0).toDouble();
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        width: width,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0xFF0B1320), Color(0xFF101E33)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF18E0FF).withOpacity(0.5)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: const Color(0xFF18E0FF).withOpacity(0.18),
              blurRadius: 24,
              spreadRadius: 1,
            ),
            BoxShadow(
              color: const Color(0xFFE93EFF).withOpacity(0.10),
              blurRadius: 48,
              spreadRadius: 4,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _ScanlinePainter()),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _CornerBracketsPainter()),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _header(),
                  const Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: _DonationList(),
                    ),
                  ),
                  _footer(context),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.currency_bitcoin,
                  color: Color(0xFFE93EFF), size: 20),
              const SizedBox(width: 8),
              const Text(
                'SUPPORT THE MISSION',
                style: TextStyle(
                  color: Color(0xFF18E0FF),
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  letterSpacing: 2.5,
                  shadows: <Shadow>[
                    Shadow(color: Color(0x8818E0FF), blurRadius: 12),
                  ],
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'v1.0',
                  style: TextStyle(color: Colors.white24, fontSize: 9),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'GlobeOrFlat is free, open (MIT) and ad-light. Donations pay for '
            'the open measurement API that researchers rely on.',
            style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
      child: SizedBox(
        width: double.infinity,
        height: 42,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF18E0FF), width: 1.2),
            foregroundColor: const Color(0xFF18E0FF),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('BACK TO SCIENCE',
              style: TextStyle(letterSpacing: 1.5, fontSize: 12)),
        ),
      ),
    );
  }
}

class _DonationList extends StatelessWidget {
  const _DonationList();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        for (final DonationTarget t in kDonationTargets) ...<Widget>[
          _DonationCard(target: t),
          const SizedBox(height: 12),
        ],
        const _ThankYouNote(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// One chain card
// ---------------------------------------------------------------------------

class _DonationCard extends StatelessWidget {
  const _DonationCard({required this.target});

  final DonationTarget target;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: target.address));
    HapticFeedback.mediumImpact();
    if (context.mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF102A43),
          content: Text(
              '${target.ticker} address copied — thank you for the support! ♥'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool valid = target.isValid;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: target.accent.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              _ChainBadge(accent: target.accent, ticker: target.ticker),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${target.chain}  ·  ${target.ticker}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      target.note,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 10),
                    ),
                  ],
                ),
              ),
              if (!valid)
                const Icon(Icons.warning_amber_rounded,
                    color: Colors.orangeAccent, size: 18),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // White quiet-zone panel — the only reliably scannable combo.
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: QrImageView(
                  data: target.address,
                  version: QrVersions.auto,
                  size: 118,
                  gapless: true,
                  backgroundColor: Colors.white,
                  eyeStyle: QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: const Color(0xFF0A1420),
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: const Color(0xFF0A1420),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF05080F),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: SelectableText(
                        target.address,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                          color: Color(0xFF9BE8FF),
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 36,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: target.accent.withOpacity(0.14),
                          foregroundColor: target.accent,
                          elevation: 0,
                          side: BorderSide(color: target.accent, width: 1),
                          textStyle: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 12),
                        ),
                        onPressed: () => _copy(context),
                        icon: const Icon(Icons.copy_rounded, size: 15),
                        label: const Text('COPY ADDRESS'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChainBadge extends StatelessWidget {
  const _ChainBadge({required this.accent, required this.ticker});

  final Color accent;
  final String ticker;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: accent, width: 1.6),
        boxShadow: <BoxShadow>[
          BoxShadow(color: accent.withOpacity(0.35), blurRadius: 10),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        ticker.substring(0, 1),
        style: TextStyle(
          color: accent,
          fontWeight: FontWeight.w800,
          fontSize: 14,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Thank-you note from the developer
// ---------------------------------------------------------------------------

class _ThankYouNote extends StatelessWidget {
  const _ThankYouNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE93EFF).withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE93EFF).withOpacity(0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.favorite, color: Color(0xFFE93EFF), size: 14),
              const SizedBox(width: 8),
              const Text(
                'A NOTE FROM THE DEVELOPER',
                style: TextStyle(
                  color: Color(0xFFE93EFF),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Whether GlobeOrFlat settles a bar argument or (better) ends up '
            'cited in someone’s research — thank you for measuring with me. '
            'Every donation goes straight into servers, GNSS test rigs and '
            'coffee. Stay curious, stay empirical.\n',
            style: TextStyle(
                color: Colors.white70, fontSize: 12, height: 1.45),
          ),
          const Align(
            alignment: Alignment.centerRight,
            child: Text(
              '— AndrexTheDev, maintainer',
              style: TextStyle(
                color: Color(0xFFE93EFF),
                fontSize: 12,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cyberpunk decoration painters
// ---------------------------------------------------------------------------

/// Faint horizontal scanlines over the whole dialog.
class _ScanlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = const Color(0xFF18E0FF).withOpacity(0.03)
      ..strokeWidth = 1;
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Neon corner brackets — the classic HUD frame.
class _CornerBracketsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const double len = 18;
    const double inset = 6;
    final Paint p = Paint()
      ..color = const Color(0xFF18E0FF).withOpacity(0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final Path path = Path()
      // top-left
      ..moveTo(inset, inset + len)
      ..lineTo(inset, inset)
      ..lineTo(inset + len, inset)
      // top-right
      ..moveTo(size.width - inset - len, inset)
      ..lineTo(size.width - inset, inset)
      ..lineTo(size.width - inset, inset + len)
      // bottom-right
      ..moveTo(size.width - inset, size.height - inset - len)
      ..lineTo(size.width - inset, size.height - inset)
      ..lineTo(size.width - inset - len, size.height - inset)
      // bottom-left
      ..moveTo(inset + len, size.height - inset)
      ..lineTo(inset, size.height - inset)
      ..lineTo(inset, size.height - inset - len);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
