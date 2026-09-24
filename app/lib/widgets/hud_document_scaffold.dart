// ============================================================================
// GlobeOrFlat — HUD Document Scaffold (shared by Help / Disclaimer / About)
// SPDX-License-Identifier: MIT
//
// A consistent cyberpunk chrome for text-heavy screens: scanline overlay,
// HUD header with mode tag, and a themed [MarkdownBody] rendering the
// content. Centralizing the markdown theme here keeps the three document
// screens pixel-identical.
//
// NOTE ON flutter_markdown: the Flutter team discontinued the package in
// 2025 (v0.7.x remains fully functional); the community fork
// `flutter_markdown_plus` is API-compatible — swapping the import is the
// only change needed if we migrate. See app/README.md.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// Cyberpunk document chrome: header + scanlines + themed markdown body.
class HudDocumentScaffold extends StatelessWidget {
  const HudDocumentScaffold({
    super.key,
    required this.title,
    required this.tag,
    required this.markdown,
    this.headerIcon = Icons.description_outlined,
    this.accent = const Color(0xFF18E0FF),
    this.actions = const <Widget>[],
    this.bottom,
  });

  final String title;
  final String tag;
  final String markdown;
  final IconData headerIcon;
  final Color accent;
  final List<Widget> actions;
  final Widget? bottom;

  /// The shared cyberpunk markdown theme for all document screens.
  static MarkdownStyleSheet markdownStyle(BuildContext context) {
    final TextTheme textTheme =
        Theme.of(context).textTheme.withAlpha(255).apply(
              bodyColor: Colors.white70,
              displayColor: Colors.white70,
            );
    return MarkdownStyleSheet.fromTheme(
      Theme.of(context).copyWith(textTheme: textTheme),
    ).copyWith(
      p: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.55),
      pPadding: const EdgeInsets.only(bottom: 10),
      h1: const TextStyle(
          color: Color(0xFF18E0FF),
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5),
      h1Padding: const EdgeInsets.only(top: 14, bottom: 8),
      h2: const TextStyle(
          color: Color(0xFF9BE8FF),
          fontSize: 16.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4),
      h2Padding: const EdgeInsets.only(top: 14, bottom: 6),
      h3: const TextStyle(
          color: Colors.white,
          fontSize: 14.5,
          fontWeight: FontWeight.w700),
      h3Padding: const EdgeInsets.only(top: 12, bottom: 4),
      listBullet: const TextStyle(color: Colors.white70, fontSize: 13.5),
      strong: const TextStyle(
          color: Colors.white, fontWeight: FontWeight.w700),
      em: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic),
      code: TextStyle(
        color: const Color(0xFF9BE8FF),
        fontSize: 12.5,
        backgroundColor: const Color(0xFF18E0FF).withOpacity(0.08),
      ),
      codeblockDecoration: BoxDecoration(
        color: const Color(0xFF05080F),
        border: Border.all(color: Colors.white12),
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      blockquoteDecoration: BoxDecoration(
        color: const Color(0xFF18E0FF).withOpacity(0.05),
        border: const Border(
          left: BorderSide(color: Color(0xFF18E0FF), width: 3),
        ),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
      ),
      blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      tableBorder: TableBorder.all(color: Colors.white12, width: 1),
      tableHead: const TextStyle(
          color: Color(0xFF18E0FF),
          fontSize: 12.5,
          fontWeight: FontWeight.w700),
      tableBody: const TextStyle(color: Colors.white70, fontSize: 12.5),
      tableCellsPadding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.12), width: 1),
        ),
      ),
      hrPadding: const EdgeInsets.symmetric(vertical: 8),
      aBody: const TextStyle(color: Color(0xFF4CFF87)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1320),
      appBar: AppBar(
        title: Text(title),
        backgroundColor: const Color(0xFF0B1320),
        actions: actions,
      ),
      bottomNavigationBar: bottom,
      body: Stack(
        children: <Widget>[
          // Faint scanlines over everything (cheap, static).
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _ScanlinesPainter(accent: accent)),
            ),
          ),
          CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(child: _header()),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 32),
                sliver: SliverToBoxAdapter(
                  child: MarkdownBody(
                    data: markdown.trim(),
                    softLineBreak: true,
                    styleSheet: markdownStyle(context),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: accent.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withOpacity(0.35)),
        ),
        child: Row(
          children: <Widget>[
            Icon(headerIcon, color: accent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title.toUpperCase(),
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      letterSpacing: 2,
                    ),
                  ),
                  Text(
                    tag,
                    style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        letterSpacing: 0.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanlinesPainter extends CustomPainter {
  const _ScanlinesPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = accent.withOpacity(0.025)
      ..strokeWidth = 1;
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
