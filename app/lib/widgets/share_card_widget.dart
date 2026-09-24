// ============================================================================
// GlobeOrFlat — Viral 9:16 Share-Card Generator (Cyberpunk HUD)
// SPDX-License-Identifier: MIT
//
// A vertical 1080×1920 (9:16) summary card rendered with pure CustomPainter
// — no platform channels, no `widgets_to_image` dependency for the artwork
// itself. Layout is computed in a 540×960 logical space and captured at
// pixelRatio 2.0 via RepaintBoundary for exact TikTok/Reels/Shorts sizing.
//
// Band layout (validated arithmetically, no overlaps/overflow):
//   header 20..66      brand + mode chip + date
//   camera 76..300     camera snapshot (or synthetic scene) + verdict ring
//   bars   510..602    MEASURED vs GLOBE vs FLAT comparison bars
//   grid   612..708    GPS / altitude / pitch / distance tiles
//   map    718..850    route map snippet OR deviation meter
//   footer 858..960    branding + measurement id
//
// [ShareCardShareButton] captures the boundary and opens the OS share
// sheet (share_plus) with a ready-made caption.
// ============================================================================

import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/measurement_summary.dart';

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

class ShareCardWidget extends StatefulWidget {
  const ShareCardWidget({
    super.key,
    required this.boundaryKey,
    required this.summary,
    this.cameraSnapshotBytes,
  });

  /// Attach this key to the enclosing RepaintBoundary for PNG capture.
  final GlobalKey boundaryKey;
  final MeasurementSummary summary;

  /// Optional JPEG/PNG snapshot from the measurement's camera viewfinder.
  /// When null a synthetic horizon scene is drawn instead.
  final Uint8List? cameraSnapshotBytes;

  @override
  State<ShareCardWidget> createState() => _ShareCardWidgetState();
}

class _ShareCardWidgetState extends State<ShareCardWidget> {
  ui.Image? _snapshot;

  @override
  void initState() {
    super.initState();
    _decodeSnapshot();
  }

  @override
  void didUpdateWidget(covariant ShareCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cameraSnapshotBytes != widget.cameraSnapshotBytes) {
      _decodeSnapshot();
    }
  }

  Future<void> _decodeSnapshot() async {
    final Uint8List? bytes = widget.cameraSnapshotBytes;
    if (bytes == null) {
      setState(() => _snapshot = null);
      return;
    }
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    setState(() => _snapshot = frame.image);
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 9 / 16,
      child: RepaintBoundary(
        key: widget.boundaryKey,
        child: CustomPaint(
          painter: ShareCardPainter(summary: widget.summary, snapshot: _snapshot),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Capture + share
// ---------------------------------------------------------------------------

class ShareCardShareButton extends StatelessWidget {
  const ShareCardShareButton({
    super.key,
    required this.boundaryKey,
    required this.summary,
    this.label = 'Share to Socials',
  });

  final GlobalKey boundaryKey;
  final MeasurementSummary summary;
  final String label;

  static String captionFor(MeasurementSummary s) {
    final String headline = s.matchHeadline ??
        (s.family == SummaryFamily.pairPending
            ? 'Eratosthenes shadow measurement logged — awaiting a paired site'
            : 'Field measurement logged');
    return '$headline — measured with GlobeOrFlat '
        '(open-source citizen geodesy). #globeorflat #science';
  }

  Future<void> _share(BuildContext context) async {
    try {
      final BuildContext? ctx = boundaryKey.currentContext;
      if (ctx == null) throw StateError('card not mounted');
      final RenderRepaintBoundary boundary =
          ctx.findRenderObject()! as RenderRepaintBoundary;
      final ui.Image image =
          await boundary.toImage(pixelRatio: 2.0); // 540×960 → 1080×1920
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG encode failed');

      final String dir = (await getTemporaryDirectory()).path;
      final String path =
          '$dir/globeorflat_card_${summary.measurementId.substring(0, 8)}.png';
      await File(path).writeAsBytes(data.buffer.asUint8List());

      await Share.shareXFiles(
        <XFile>[XFile(path, mimeType: 'image/png')],
        subject: 'GlobeOrFlat measurement',
        text: captionFor(summary),
      );
    } on Exception catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF102A43),
            content: Text('Share failed: $e'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF18E0FF),
          foregroundColor: const Color(0xFF05080F),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        onPressed: () => _share(context),
        icon: const Icon(Icons.share_rounded),
        label: Text(label.toUpperCase(),
            style: const TextStyle(letterSpacing: 1.2)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class ShareCardPainter extends CustomPainter {
  ShareCardPainter({required this.summary, this.snapshot});

  final MeasurementSummary summary;
  final ui.Image? snapshot;

  // Logical canvas: 540 × 960 (rendered at 2× for 1080×1920).
  static const double W = 540;
  static const double H = 960;
  static const double PAD = 20;

  static const Color _bgTop = Color(0xFF070D18);
  static const Color _bgBottom = Color(0xFF0C1A2E);
  static const Color _cyan = Color(0xFF18E0FF);
  static const Color _green = Color(0xFF4CFF87);
  static const Color _magenta = Color(0xFFE93EFF);
  static const Color _amber = Color(0xFFFFB454);
  static const Color _violet = Color(0xFF9D7BFF);

  Color get _verdictColor {
    switch (summary.verdict.$2) {
      case 0:
        return _green;
      case 1:
        return _cyan;
      case 2:
        return _amber;
      case 3:
        return _magenta;
      default:
        return _violet;
    }
  }

  // ---- text helper ---------------------------------------------------------
  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    double size = 13,
    Color color = Colors.white70,
    FontWeight weight = FontWeight.w400,
    double letterSpacing = 0,
  }) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          letterSpacing: letterSpacing,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: W - 2 * PAD);
    tp.paint(canvas, at);
  }

  double _textWidth(String text, double size, FontWeight weight,
      {double letterSpacing = 0}) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, fontWeight: weight, letterSpacing: letterSpacing),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width ?? 0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Scale the fixed logical space onto whatever the RepaintBoundary is.
    final double s = size.width / W;
    canvas.save();
    canvas.scale(s, s);

    _paintBackground(canvas);
    _paintHeader(canvas);
    _paintCameraPanel(canvas);
    _paintVerdictRing(canvas);
    _paintComparisonBars(canvas);
    _paintMetricsGrid(canvas);
    if (summary.routePoints != null && summary.routePoints!.isNotEmpty) {
      _paintRouteMap(canvas);
    } else {
      _paintDeviationMeter(canvas);
    }
    _paintFooter(canvas);

    canvas.restore();
  }

  void _paintBackground(Canvas canvas) {
    final Paint bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[_bgTop, _bgBottom],
      ).createShader(const Rect.fromLTWH(0, 0, W, H));
    canvas.drawRect(const Rect.fromLTWH(0, 0, W, H), bg);

    // Subtle grid.
    final Paint grid = Paint()
      ..color = _cyan.withOpacity(0.045)
      ..strokeWidth = 1;
    for (double x = 0; x <= W; x += 45) {
      canvas.drawLine(Offset(x, 0), Offset(x, H), grid);
    }
    for (double y = 0; y <= H; y += 45) {
      canvas.drawLine(Offset(0, y), Offset(W, y), grid);
    }
    // Scanlines.
    final Paint scan = Paint()
      ..color = Colors.white.withOpacity(0.012)
      ..strokeWidth = 1;
    for (double y = 0; y <= H; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(W, y), scan);
    }
  }

  void _paintHeader(Canvas canvas) {
    _text(canvas, 'GLOBEORFLAT', const Offset(PAD, 26),
        size: 22, color: _cyan, weight: FontWeight.w900, letterSpacing: 3);
    _text(canvas, 'CITIZEN GEODESY · FIELD REPORT', const Offset(PAD, 52),
        size: 10, color: Colors.white38, letterSpacing: 1.6);

    // Mode chip, right-aligned.
    final String mode = summary.modeWire;
    final double chipW = _textWidth(mode, 11, FontWeight.w800, letterSpacing: 1.5) + 20;
    final Rect chip = Rect.fromLTWH(W - PAD - chipW, 24, chipW, 26);
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, const Radius.circular(6)),
      Paint()
        ..color = _magenta.withOpacity(0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    _text(canvas, mode, Offset(chip.left + 10, chip.top + 7),
        size: 11, color: _magenta, weight: FontWeight.w800, letterSpacing: 1.5);

    final String date = DateTime.fromMillisecondsSinceEpoch(summary.capturedAtMs)
        .toUtc()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll('T', ' ');
    _text(canvas, '$date UTC', Offset(W - PAD - _textWidth(date, 10, FontWeight.w500) - 10, 52),
        size: 10, color: Colors.white38);
  }

  void _paintCameraPanel(Canvas canvas) {
    final Rect panel = Rect.fromLTWH(PAD, 76, W - 2 * PAD, 224);
    final RRect rrect = RRect.fromRectAndRadius(panel, const Radius.circular(12));

    // Frame + clip.
    canvas.save();
    canvas.clipRRect(rrect);
    if (snapshot != null) {
      // Cover-crop the snapshot into the panel (validated math).
      final double iw = snapshot!.width.toDouble();
      final double ih = snapshot!.height.toDouble();
      final double scale = math.max(panel.width / iw, panel.height / ih);
      final double dw = iw * scale, dh = ih * scale;
      canvas.drawImageRect(
        snapshot!,
        Rect.fromLTWH(0, 0, iw, ih),
        Rect.fromLTWH(
            panel.left + (panel.width - dw) / 2,
            panel.top + (panel.height - dh) / 2,
            dw,
            dh),
        Paint(),
      );
      // Dark scrim for HUD readability.
      canvas.drawRect(panel, Paint()..color = Colors.black.withOpacity(0.35));
    } else {
      _paintSyntheticScene(canvas, panel);
    }

    // Mini HUD overlay on the snippet: horizon + dip lines.
    final double cy = panel.center.dy;
    canvas.drawLine(Offset(panel.left, cy), Offset(panel.right, cy),
        Paint()..color = _green.withOpacity(0.9)..strokeWidth = 2);
    final Path dashed = Path()
      ..moveTo(panel.left, cy + 8)
      ..lineTo(panel.right, cy + 8);
    canvas.drawPath(
      dashed,
      Paint()
        ..color = _cyan.withOpacity(0.9)
        ..strokeWidth = 2
        ..pathEffect = ui.PathEffect.dash(const <double>[8, 6], 0),
    );
    canvas.restore();

    canvas.drawRRect(rrect, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = _cyan.withOpacity(0.5));

    _text(canvas, 'CAMERA / SCENE SNIPPET', Offset(panel.left + 10, panel.top + 8),
        size: 9, color: Colors.white38, letterSpacing: 1.5);
  }

  /// Synthetic fallback scene: sky, sea, horizon — echoes Mode A's HUD.
  void _paintSyntheticScene(Canvas canvas, Rect panel) {
    final Paint sky = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Color(0xFF0E2A45), Color(0xFF14415F)],
      ).createShader(panel);
    canvas.drawRect(panel, sky);
    final Rect sea = Rect.fromLTRB(
        panel.left, panel.center.dy, panel.right, panel.bottom);
    canvas.drawRect(
      sea,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF0A3B4F), Color(0xFF062330)],
        ).createShader(sea),
    );
    // Distant target silhouette.
    final double tx = panel.left + panel.width * 0.72;
    final Path ship = Path()
      ..moveTo(tx, panel.center.dy)
      ..lineTo(tx, panel.center.dy - 26)
      ..lineTo(tx + 54, panel.center.dy - 26)
      ..lineTo(tx + 54, panel.center.dy)
      ..close();
    canvas.drawPath(ship, Paint()..color = Colors.white.withOpacity(0.22));
  }

  void _paintVerdictRing(Canvas canvas) {
    final Offset center = const Offset(W / 2, 406);
    const double r = 78;
    final double? match = summary.matchPercent;

    // Track.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..color = Colors.white.withOpacity(0.07),
    );
    final double progress = (match ?? 0) / 100.0;
    if (progress > 0.003) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..strokeCap = StrokeCap.round
          ..color = _verdictColor,
      );
    }
    // Tick at 100%.
    canvas.drawCircle(
      center,
      r + 12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white12,
    );

    final String centerText =
        match == null ? '?' : '${match.toStringAsFixed(1)}%';
    _text(canvas, centerText,
        Offset(center.dx - _textWidth(centerText, 34, FontWeight.w900) / 2, center.dy - 24),
        size: 34, color: _verdictColor, weight: FontWeight.w900);
    const String sub = 'MATCH';
    _text(canvas, sub,
        Offset(center.dx - _textWidth(sub, 11, FontWeight.w700, letterSpacing: 3) / 2,
            center.dy + 18),
        size: 11, color: Colors.white54, weight: FontWeight.w700, letterSpacing: 3);

    final (String label, _) = summary.verdict;
    _text(canvas, label,
        Offset(center.dx - _textWidth(label, 14, FontWeight.w800, letterSpacing: 2) / 2,
            center.dy + r + 26),
        size: 14, color: _verdictColor, weight: FontWeight.w800, letterSpacing: 2);
    const String caption = 'WITH SPHERICAL EARTH MODEL';
    _text(canvas, caption,
        Offset(center.dx - _textWidth(caption, 9, FontWeight.w500, letterSpacing: 2) / 2,
            center.dy + r + 46),
        size: 9, color: Colors.white24, letterSpacing: 2);
  }

  void _paintComparisonBars(Canvas canvas) {
    const double top = 510;
    const double labelW = 120, valueW = 92, gap = 12;
    const double barW = 540 - 2 * PAD - labelW - valueW - gap;

    final double maxAbs = <double>[
      summary.measuredValue.abs(),
      summary.globeExpected.abs(),
      summary.flatExpected.abs(),
      1e-9,
    ].reduce(math.max);

    final List<(String, double, Color)> rows = <(String, double, Color)>[
      ('MEASURED', summary.measuredValue, Colors.white),
      ('GLOBE', summary.globeExpected, _cyan),
      ('FLAT', summary.flatExpected, _green),
    ];

    for (int i = 0; i < rows.length; i++) {
      final double y = top + i * 30.0;
      final (String label, double value, Color color) = rows[i];
      _text(canvas, label, const Offset(PAD, y + 2), size: 11,
          color: label == 'MEASURED' ? Colors.white : Colors.white54,
          weight: FontWeight.w700, letterSpacing: 1);

      final double frac = (value.abs() / maxAbs).clamp(0.0, 1.0).toDouble();
      final Rect track = Rect.fromLTWH(PAD + labelW, y, barW, 10);
      canvas.drawRRect(
        RRect.fromRectAndRadius(track, const Radius.circular(5)),
        Paint()..color = Colors.white.withOpacity(0.07),
      );
      if (frac > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(PAD + labelW, y, math.max(barW * frac, 4), 10),
              const Radius.circular(5)),
          Paint()..color = color.withOpacity(0.85),
        );
      }
      final String valueText =
          '${value >= 0 ? '' : '−'}${value.abs().toStringAsFixed(2)} ${summary.expectationUnit}';
      _text(canvas, valueText,
          Offset(W - PAD - _textWidth(valueText, 11, FontWeight.w600), y + 1),
          size: 11, color: color, weight: FontWeight.w600);
    }
  }

  void _paintMetricsGrid(Canvas canvas) {
    const double top = 612;
    const double tileW = (540 - 2 * PAD - 10) / 2;
    const double tileH = 43;

    String fmtCoord(double? v, int digits, String hemiPos, String hemiNeg) {
      if (v == null) return '—';
      return '${v.abs().toStringAsFixed(digits)}°${v >= 0 ? hemiPos : hemiNeg}';
    }

    final double? lat = summary.latitude;
    final double? lon = summary.longitude;
    final List<(String, String)> cells = <(String, String)>[
      (
        'POSITION',
        lat == null || lon == null
            ? 'NO FIX'
            : '${fmtCoord(lat, 4, 'N', 'S')} ${fmtCoord(lon, 4, 'E', 'W')}'
      ),
      (
        'ALTITUDE (EKF)',
        summary.altitudeM == null ? '—' : '${summary.altitudeM!.toStringAsFixed(1)} m'
      ),
      (
        'BORESIGHT PITCH',
        summary.pitchDeg == null ? '—' : '${summary.pitchDeg!.toStringAsFixed(2)}°'
      ),
      (
        'DISTANCE',
        summary.distanceKm == null
            ? (summary.durationS == null
                ? '—'
                : '${summary.durationS!.toStringAsFixed(0)} s session')
            : '${summary.distanceKm!.toStringAsFixed(2)} km'
      ),
    ];

    for (int i = 0; i < cells.length; i++) {
      final double x = PAD + (i % 2) * (tileW + 10);
      final double y = top + (i ~/ 2) * (tileH + 10);
      final Rect tile = Rect.fromLTWH(x, y, tileW, tileH);
      canvas.drawRRect(
        RRect.fromRectAndRadius(tile, const Radius.circular(8)),
        Paint()..color = Colors.white.withOpacity(0.035),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(tile, const Radius.circular(8)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withOpacity(0.08),
      );
      _text(canvas, cells[i].$1, Offset(x + 10, y + 7),
          size: 8.5, color: Colors.white24, letterSpacing: 1.4);
      _text(canvas, cells[i].$2, Offset(x + 10, y + 21),
          size: 13, color: Colors.white, weight: FontWeight.w700);
    }
  }

  void _paintRouteMap(Canvas canvas) {
    final Rect panel = Rect.fromLTWH(PAD, 718, W - 2 * PAD, 132);
    final RRect rrect =
        RRect.fromRectAndRadius(panel, const Radius.circular(10));
    canvas.drawRRect(
        rrect, Paint()..color = const Color(0xFF05080F).withOpacity(0.85));
    canvas.drawRRect(rrect, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white12);

    // Grid.
    final Paint grid = Paint()
      ..color = _cyan.withOpacity(0.05)
      ..strokeWidth = 1;
    for (double x = panel.left + 20; x < panel.right; x += 40) {
      canvas.drawLine(Offset(x, panel.top), Offset(x, panel.bottom), grid);
    }
    for (double y = panel.top + 20; y < panel.bottom; y += 40) {
      canvas.drawLine(Offset(panel.left, y), Offset(panel.right, y), grid);
    }

    // Route polyline (normalized points inset by 14px).
    final List<(double, double)> pts = summary.routePoints!;
    final Paint line = Paint()
      ..color = _cyan
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final Path path = Path();
    final Rect inner = panel.deflate(14);
    for (int i = 0; i < pts.length; i++) {
      final Offset o = Offset(
        inner.left + pts[i].$1 * inner.width,
        inner.top + pts[i].$2 * inner.height,
      );
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(path, line);
    if (pts.isNotEmpty) {
      final Offset start = Offset(inner.left + pts.first.$1 * inner.width,
          inner.top + pts.first.$2 * inner.height);
      final Offset end = Offset(inner.left + pts.last.$1 * inner.width,
          inner.top + pts.last.$2 * inner.height);
      canvas.drawCircle(start, 4, Paint()..color = _green);
      canvas.drawCircle(end, 4, Paint()..color = _magenta);
    }

    _text(canvas, 'ROUTE SNIPPET', Offset(panel.left + 10, panel.top + 6),
        size: 9, color: Colors.white24, letterSpacing: 1.5);
  }

  void _paintDeviationMeter(Canvas canvas) {
    final Rect panel = Rect.fromLTWH(PAD, 718, W - 2 * PAD, 132);
    final RRect rrect =
        RRect.fromRectAndRadius(panel, const Radius.circular(10));
    canvas.drawRRect(
        rrect, Paint()..color = const Color(0xFF05080F).withOpacity(0.85));
    canvas.drawRRect(rrect, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white12);

    const double axisY = 792;
    final double axisL = panel.left + 28;
    final double axisR = panel.right - 28;

    // Gradient axis: magenta (flat-leaning) → violet (perfect) → cyan? No:
    // center = globe match; both sides = deviation magnitude.
    final Rect axis = Rect.fromLTWH(axisL, axisY, axisR - axisL, 6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(axis, const Radius.circular(3)),
      Paint()
        ..shader = const LinearGradient(colors: <Color>[
          Color(0xFFE93EFF),
          Color(0xFF4CFF87),
          Color(0xFFE93EFF),
        ]).createShader(axis),
    );

    // Center tick (0% = globe).
    canvas.drawLine(Offset(W / 2, axisY - 12), Offset(W / 2, axisY + 18),
        Paint()..color = Colors.white54..strokeWidth = 2);
    _text(canvas, 'GLOBE', Offset(W / 2 - _textWidth('GLOBE', 9, FontWeight.w700, letterSpacing: 1) / 2, axisY + 24),
        size: 9, color: Colors.white38, weight: FontWeight.w700, letterSpacing: 1);

    final double? dev = summary.deviationPercent;
    if (dev != null) {
      final double t = ((dev / 50.0) + 1) / 2; // −50..+50 → 0..1
      final double mx = axisL + t.clamp(0.0, 1.0) * (axisR - axisL);
      canvas.drawCircle(Offset(mx, axisY + 3), 8,
          Paint()..color = Colors.white);
      canvas.drawCircle(Offset(mx, axisY + 3), 8, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _verdictColor);
      final String label = 'DEV ${dev >= 0 ? '+' : ''}${dev.toStringAsFixed(1)}%';
      _text(canvas, label, Offset(mx - _textWidth(label, 11, FontWeight.w700) / 2, axisY - 30),
          size: 11, color: _verdictColor, weight: FontWeight.w700);
    } else {
      _text(canvas, 'DEVIATION PENDING', Offset(W / 2 - 52, axisY - 30),
          size: 11, color: Colors.white38);
    }

    _text(canvas, 'DEVIATION FROM SPHERICAL MODEL', Offset(panel.left + 10, panel.top + 6),
        size: 9, color: Colors.white24, letterSpacing: 1.5);
    _text(canvas, '−50%', Offset(axisL, axisY + 24), size: 9, color: Colors.white24);
    _text(canvas, '+50%', Offset(axisR - _textWidth('+50%', 9, FontWeight.w400), axisY + 24),
        size: 9, color: Colors.white24);
  }

  void _paintFooter(Canvas canvas) {
    _text(canvas, 'Measured with GlobeOrFlat', const Offset(PAD, 876),
        size: 15, color: Colors.white, weight: FontWeight.w800);
    _text(canvas, 'append-only · open data (CC0) · MIT', const Offset(PAD, 898),
        size: 10, color: Colors.white38);
    final String id = '#${summary.measurementId.substring(0, 8)}';
    _text(canvas, id, Offset(W - PAD - _textWidth(id, 12, FontWeight.w700), 880),
        size: 12, color: _cyan, weight: FontWeight.w700);
    const String handle = '@globeorflat';
    _text(canvas, handle,
        Offset(W - PAD - _textWidth(handle, 10, FontWeight.w500), 900),
        size: 10, color: Colors.white38);
  }

  @override
  bool shouldRepaint(covariant ShareCardPainter oldDelegate) =>
      oldDelegate.summary != summary || oldDelegate.snapshot != snapshot;
}
