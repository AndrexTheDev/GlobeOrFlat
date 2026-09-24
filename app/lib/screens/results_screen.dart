// ============================================================================
// GlobeOrFlat — Results Screen
// SPDX-License-Identifier: MIT
//
// The post-measurement surface:
//   • side-by-side comparison matrix — Measured vs Globe Model vs Flat Model
//   • headline score ("99.4% Match with Spherical Earth Model") + verdict
//   • mid-screen Adsterra banner above the summary (non-camera screen)
//   • actions: Share to Socials (9:16 card), PDF Audit Report (token-gated),
//     Export CSV (token-gated)
//
// Built from a [MeasurementSummary] so it works for every mode.
// ============================================================================

import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/measurement_summary.dart';
import '../services/ad_config.dart';
import '../services/coinzilla_rewarded_service.dart';
import '../services/pdf_report_service.dart';
import '../widgets/adsterra_banner_widget.dart';
import '../widgets/share_card_widget.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    super.key,
    required this.summary,
    this.cameraSnapshotBytes,
  });

  final MeasurementSummary summary;

  /// Optional JPEG/PNG frame captured from the measurement's viewfinder;
  /// rendered into the share card instead of the synthetic scene.
  final Uint8List? cameraSnapshotBytes;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  final GlobalKey _cardBoundaryKey = GlobalKey();
  bool _pdfBusy = false;
  bool _csvBusy = false;

  MeasurementSummary get s => widget.summary;

  Color get _verdictColor {
    switch (s.verdict.$2) {
      case 0:
        return const Color(0xFF4CFF87);
      case 1:
        return const Color(0xFF18E0FF);
      case 2:
        return const Color(0xFFFFB454);
      case 3:
        return const Color(0xFFE93EFF);
      default:
        return const Color(0xFF9D7BFF);
    }
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  /// Shares the raw sensor CSV as a file (token-gated premium action).
  Future<void> _exportCsv() async {
    if (_csvBusy) return;
    setState(() => _csvBusy = true);
    try {
      final CoinzillaRewardedService service = CoinzillaRewardedService();
      final bool entitled =
          await service.ensureEntitlement(context, PremiumAction.exportCsv);
      if (!entitled || !mounted) return;

      final String csv = s.rawCsv ?? '';
      if (csv.isEmpty) {
        _toast('No raw log attached to this session.');
        return;
      }
      final String dir = (await getTemporaryDirectory()).path;
      final String path =
          '$dir/globeorflat_${s.measurementId.substring(0, 8)}.csv';
      await File(path).writeAsString(csv);
      await Share.shareXFiles(
        <XFile>[XFile(path, mimeType: 'text/csv')],
        subject: 'GlobeOrFlat raw sensor log',
        text: 'Raw sensor CSV — ${s.modeWire} ${s.measurementId}',
      );
    } on Exception catch (e) {
      _toast('CSV export failed: $e');
    } finally {
      if (mounted) {
        setState(() => _csvBusy = false);
      }
    }
  }

  /// Generates and shares the formal PDF audit report (token-gated).
  Future<void> _exportPdf() async {
    if (_pdfBusy) return;
    setState(() => _pdfBusy = true);
    try {
      final CoinzillaRewardedService service = CoinzillaRewardedService();
      final bool entitled = await service.ensureEntitlement(
          context, PremiumAction.downloadPdfAuditReport);
      if (!entitled || !mounted) return;
      await PdfReportService.sharePdf(s);
    } on Exception catch (e) {
      _toast('PDF generation failed: $e');
    } finally {
      if (mounted) {
        setState(() => _pdfBusy = false);
      }
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(backgroundColor: const Color(0xFF102A43), content: Text(message)),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1320),
      appBar: AppBar(
        title: const Text('Results'),
        backgroundColor: const Color(0xFF0B1320),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // Mid-screen banner above the summary (non-camera screen).
          const MidResultBanner(title: 'Result summary'),

          const SizedBox(height: 16),
          _comparisonMatrix(),

          const SizedBox(height: 16),
          _verdictCard(),

          const SizedBox(height: 16),
          _integrityStrip(),

          const SizedBox(height: 16),
          Text('9:16 SHARE CARD',
              style: TextStyle(
                  color: Colors.tealAccent.shade200,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  letterSpacing: 2)),
          const SizedBox(height: 8),
          ShareCardWidget(
            boundaryKey: _cardBoundaryKey,
            summary: s,
            cameraSnapshotBytes: widget.cameraSnapshotBytes,
          ),
          const SizedBox(height: 12),
          ShareCardShareButton(
            boundaryKey: _cardBoundaryKey,
            summary: s,
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.tealAccent.shade200),
                    foregroundColor: Colors.tealAccent.shade200,
                  ),
                  onPressed: _pdfBusy ? null : _exportPdf,
                  icon: _pdfBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  label: const Text('PDF Audit Report',
                      overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.tealAccent.shade200),
                    foregroundColor: Colors.tealAccent.shade200,
                  ),
                  onPressed: _csvBusy ? null : _exportCsv,
                  icon: _csvBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.table_view_outlined, size: 18),
                  label: const Text('Export CSV',
                      overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Side-by-side comparison matrix
  // -------------------------------------------------------------------------

  Widget _comparisonMatrix() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF102A43),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Text('COMPARISON MATRIX · ${s.modeWire}',
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    letterSpacing: 1.6,
                    fontWeight: FontWeight.w700)),
          ),
          _matrixHeader(),
          _matrixRow(
            'Primary metric (${s.measuredUnit})',
            s.measuredValue.toStringAsFixed(2),
            s.globeExpected.toStringAsFixed(2),
            s.flatExpected.toStringAsFixed(2),
            highlightValue: true,
          ),
          _matrixDivider(),
          _matrixRow('Signed deviation', _deviationText(), '0 % (definition)',
              '—', dim: true),
          _matrixDivider(),
          for (final MapEntry<String, String> e in s.extraRows.entries) ...<Widget>[
            _matrixRow(e.key, e.value, '', '', dim: true),
            _matrixDivider(),
          ],
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _matrixHeader() {
    return Container(
      color: const Color(0xFF18E0FF).withOpacity(0.07),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      child: const Row(
        children: <Widget>[
          Expanded(
              flex: 3, child: MatrixHeadCell('QUANTITY', Colors.white38)),
          Expanded(
              flex: 3, child: MatrixHeadCell('MEASURED DATA', Colors.white)),
          Expanded(
              flex: 3, child: MatrixHeadCell('GLOBE MODEL', Color(0xFF18E0FF))),
          Expanded(
              flex: 3,
              child: MatrixHeadCell('FLAT EARTH MODEL', Color(0xFF4CFF87))),
        ],
      ),
    );
  }

  Widget _matrixRow(
    String label,
    String measured,
    String globe,
    String flat, {
    bool highlightValue = false,
    bool dim = false,
  }) {
    TextStyle cellStyle(Color c) => TextStyle(
        color: c,
        fontSize: dim ? 12 : 14,
        fontWeight: highlightValue && !dim ? FontWeight.w800 : FontWeight.w500);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
              flex: 3,
              child:
                  Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12))),
          Expanded(flex: 3, child: Text(measured, style: cellStyle(Colors.white))),
          Expanded(
              flex: 3,
              child: Text(globe, style: cellStyle(const Color(0xFF18E0FF)))),
          Expanded(
              flex: 3,
              child: Text(flat, style: cellStyle(const Color(0xFF4CFF87)))),
        ],
      ),
    );
  }

  Widget _matrixDivider() => Divider(
      height: 1,
      color: Colors.white.withOpacity(0.07),
      indent: 14,
      endIndent: 14);

  String _deviationText() {
    final double? dev = s.deviationPercent;
    if (dev == null) return 'pending';
    return '${dev >= 0 ? '+' : ''}${dev.toStringAsFixed(2)} %';
  }

  // -------------------------------------------------------------------------
  // Verdict card
  // -------------------------------------------------------------------------

  Widget _verdictCard() {
    final (String label, _) = s.verdict;
    final String? headline = s.matchHeadline;
    final double? match = s.matchPercent;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF102A43),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _verdictColor.withOpacity(0.5)),
        boxShadow: <BoxShadow>[
          BoxShadow(color: _verdictColor.withOpacity(0.12), blurRadius: 22),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _verdictColor.withOpacity(0.14),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(label,
                style: TextStyle(
                    color: _verdictColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6)),
          ),
          const SizedBox(height: 10),
          Text(
            headline ?? 'Awaiting paired measurement',
            style: TextStyle(
              color: _verdictColor,
              fontSize: 21,
              fontWeight: FontWeight.w900,
              height: 1.2,
            ),
          ),
          if (match != null) ...<Widget>[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: match / 100,
                minHeight: 10,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(_verdictColor),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'match score against the spherical model — the uncertainty '
              'lives in the raw log, not in this number',
              style: TextStyle(color: Colors.white24, fontSize: 10.5),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Integrity strip
  // -------------------------------------------------------------------------

  Widget _integrityStrip() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF05080F),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('INTEGRITY CHAIN',
              style: TextStyle(
                  color: Colors.white24,
                  fontSize: 9,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          _kv('measurement id', s.measurementId),
          _kv('raw log sha-256', s.rawCsvSha256 ?? 'hashed at enqueue'),
          _kv('signature (sha-256)',
              s.signatureHashHex ?? 'applied by sync (GOFv1)'),
          _kv('captured (utc)', s.capturedAtIso),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(k,
                style: const TextStyle(color: Colors.white24, fontSize: 10.5)),
          ),
          Expanded(
            child: Text(v,
                style: const TextStyle(
                    color: Color(0xFF9BE8FF),
                    fontSize: 10.5,
                    fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

class MatrixHeadCell extends StatelessWidget {
  const MatrixHeadCell(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8));
  }
}
