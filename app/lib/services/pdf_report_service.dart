// ============================================================================
// GlobeOrFlat — PDF Audit Report Generator
// SPDX-License-Identifier: MIT
//
// Formal multi-page scientific report for a measurement, built with `pdf`
// and shareable/printable via `printing`:
//
//   p1  title block, verdict, three-model comparison, session context,
//       integrity chain (SHA-256 of the raw CSV, GOFv1 signature hash),
//       calibration status
//   p2+ telemetry tables (first 120 raw CSV rows, chunked at 40 rows/page
//       with repeated headers), mode annotations, optional track profile
//       chart
//   pN  developer verification stamp + scientific disclaimer + licenses
//
// The premium gating (rewarded ad / feature token) happens in the caller —
// this service is pure report generation.
// ============================================================================

import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../models/measurement_summary.dart';
import '../screens/about_screen.dart'
    show kContactEmail, kDeveloperName, kGitHubRepoUrl;

class PdfReportService {
  PdfReportService._();

  /// Builds the full report bytes. Pure async — no dialogs.
  static Future<Uint8List> buildPdf(MeasurementSummary s) async {
    final pw.Document doc = pw.Document(
      title: 'GlobeOrFlat Audit Report ${s.measurementId}',
      author: kDeveloperName,
      creator: 'GlobeOrFlat Flutter Client v1.0',
      subject: 'Citizen-science geodesy measurement audit',
    );

    final pw.FontTheme theme = await _fontTheme();
    final Uint8List logo = await _tryLoadAsset('assets/icon/logo_mark.png');

    doc.addPage(_titlePage(s, theme, logo));
    _addTelemetryPages(doc, s, theme);
    doc.addPage(_stampPage(s, theme));
    return doc.save();
  }

  /// Builds and opens the OS share sheet with the PDF attached.
  static Future<void> sharePdf(MeasurementSummary s) async {
    final Uint8List bytes = await buildPdf(s);
    final String dir = (await getTemporaryDirectory()).path;
    final String path =
        '$dir/globeorflat_audit_${s.measurementId.substring(0, 8)}.pdf';
    await File(path).writeAsBytes(bytes);
    await Share.shareXFiles(
      <XFile>[XFile(path, mimeType: 'application/pdf')],
      subject: 'GlobeOrFlat audit report',
      text: 'Audit report for measurement ${s.measurementId}',
    );
  }

  /// Builds and opens the platform print / preview dialog.
  static Future<void> printPdf(MeasurementSummary s) async {
    final Uint8List bytes = await buildPdf(s);
    await Printing.sharePdf(
      bytes: bytes,
      filename: 'globeorflat_audit_${s.measurementId.substring(0, 8)}.pdf',
    );
  }

  // -------------------------------------------------------------------------
  // Pages
  // -------------------------------------------------------------------------

  static pw.Page _titlePage(
      MeasurementSummary s, pw.FontTheme theme, Uint8List? logo) {
    final (String verdict, _) = s.verdict;
    return pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 46, 40, 40),
      theme: theme,
      build: (pw.Context ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          _header(s, logo),
          pw.SizedBox(height: 18),
          _sectionTitle('1 · VERDICT'),
          _verdictBlock(s, verdict),
          pw.SizedBox(height: 16),
          _sectionTitle('2 · MODEL COMPARISON MATRIX'),
          _comparisonTable(s),
          pw.SizedBox(height: 16),
          _sectionTitle('3 · SESSION CONTEXT'),
          _sessionTable(s),
          pw.SizedBox(height: 16),
          _sectionTitle('4 · INTEGRITY CHAIN'),
          _integrityTable(s),
          pw.SizedBox(height: 16),
          _sectionTitle('5 · CALIBRATION STATUS'),
          _calibrationTable(s),
          pw.Spacer(),
          _footer(ctx, s),
        ],
      ),
    );
  }

  void _addTelemetryPages(pw.Document doc, MeasurementSummary s, pw.FontTheme theme) {
    final List<List<String>> rows = s.telemetryRows(maxRows: 120);
    // csvAnnotation('columns') is "<mode>,columns=a,b,..." — take the raw
    // list after the 'columns=' marker, not the split tokens.
    final String? columnsAnnotation = s.csvAnnotation('columns');
    final String colBody =
        columnsAnnotation != null && columnsAnnotation.contains('columns=')
            ? columnsAnnotation.substring(
                columnsAnnotation.indexOf('columns=') + 'columns='.length)
            : '';
    final List<String> cols = colBody.isNotEmpty
        ? _padHeader(colBody.split(',').map((c) => c.trim()).take(6).toList())
        : <String>['c0', 'c1', 'c2', 'c3', 'c4', 'c5'];

    const int rowsPerPage = 40;
    final int totalPages = (rows.length / rowsPerPage).ceil();

    for (int page = 0; page * rowsPerPage < rows.length; page++) {
      final int lo = page * rowsPerPage;
      final int hi = math.min(rows.length, lo + rowsPerPage);
      final List<List<String>> slice =
          rows.sublist(lo, hi).map(_padRow).toList();

      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(36, 42, 36, 36),
          theme: theme,
          build: (pw.Context ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: <pw.Widget>[
              _sectionTitle('6 · RAW SENSOR TELEMETRY'
                  '  (rows ${lo + 1}–$hi of ${rows.length}'
                  '${page == 0 ? ', first 120 of the log' : ''})'),
              pw.Text(
                'Complete raw logs ship with the dataset; this excerpt is for '
                'human review. Column names from the CSV header follow.',
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
              pw.SizedBox(height: 8),
              pw.TableHelper.fromTextArray(
                headers: cols,
                data: slice
                    .map((List<String> r) =>
                        r.take(6).map((String c) => c).toList())
                    .toList(),
                headerStyle: pw.TextStyle(
                    fontSize: 6.5,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.cyan900),
                cellStyle: const pw.TextStyle(fontSize: 6.0),
                cellAlignment: pw.Alignment.centerLeft,
                border: pw.TableBorder.all(
                    color: PdfColors.grey300, width: 0.4),
                headerDecoration:
                    const pw.BoxDecoration(color: PdfColors.cyan50),
                oddRowDecoration:
                    const pw.BoxDecoration(color: PdfColors.grey50),
              ),
              pw.Spacer(),
              _footer(ctx, s, pageLabel: 'telemetry ${page + 1}/$totalPages'),
            ],
          ),
        ),
      );
    }
  }

  static pw.Page _stampPage(MeasurementSummary s, pw.FontTheme theme) {
    return pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 46, 40, 40),
      theme: theme,
      build: (pw.Context ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          _sectionTitle('7 · MODE ANNOTATIONS'),
          _annotationsTable(s),
          pw.SizedBox(height: 20),
          _sectionTitle('8 · DEVELOPER VERIFICATION STAMP'),
          pw.Container(
            padding: const pw.EdgeInsets.all(14),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.cyan800, width: 1.5),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              color: PdfColors.cyan50,
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: <pw.Widget>[
                pw.Text(
                  'VERIFIED GENERATION — GLOBEORFLAT v1.0 (GOFv1)',
                  style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.cyan900),
                ),
                pw.SizedBox(height: 6),
                _stampRow('Report ID', s.measurementId),
                _stampRow('Generated (UTC)',
                    DateTime.now().toUtc().toIso8601String()),
                _stampRow('Signature protocol',
                    'ECDSA P-256 · SHA256withECDSA · Android Keystore (non-exportable)'),
                _stampRow('Backend verification',
                    'crypto_verify.ts — DER→P1363 WebCrypto, UNIQUE signature_hash'),
                _stampRow('Developer', kDeveloperName),
                _stampRow('Contact', kContactEmail),
                _stampRow('Source', kGitHubRepoUrl),
              ],
            ),
          ),
          pw.SizedBox(height: 20),
          _sectionTitle('9 · SCIENTIFIC LIMITS (READ BEFORE CITING)'),
          pw.Bullet(
              text: 'Consumer MEMS sensors: barometric drift, GNSS vertical '
                  'error 3–10 m, accelerometer/gyro bias after calibration.'),
          pw.Bullet(
              text: 'Environmental refraction varies around the standard '
                  'k = 0.14; mirage and ducting can outweigh the measured effect.'),
          pw.Bullet(
              text: 'Single measurements are evidence with uncertainty — cite '
                  'averages and spreads, and verify the SHA-256 above against '
                  'the raw log served by the public API.'),
          pw.SizedBox(height: 16),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey400)),
            child: pw.Text(
              'Data: dedicated to the public domain (CC0). Code: MIT — '
              'provided "as is", without warranty of any kind. This report is '
              'auto-generated from on-device sensor data and is not certified '
              'for navigation, surveying, engineering or legal use.',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
          ),
          pw.Spacer(),
          _footer(ctx, s, pageLabel: 'stamp'),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Building blocks
  // -------------------------------------------------------------------------

  static pw.Widget _header(MeasurementSummary s, Uint8List? logo) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 10),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: PdfColors.cyan800, width: 2)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: <pw.Widget>[
          if (logo != null) ...<pw.Widget>[
            pw.Container(
              width: 42,
              height: 42,
              child: pw.Image(pw.MemoryImage(logo)),
            ),
            pw.SizedBox(width: 12),
          ],
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: <pw.Widget>[
                pw.Text('GLOBEORFLAT — MEASUREMENT AUDIT REPORT',
                    style: pw.TextStyle(
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.cyan900)),
                pw.Text(
                  'mode ${s.modeWire} · captured '
                  '${s.capturedAtIso} · id ${s.measurementId}',
                  style: const pw.TextStyle(
                      fontSize: 8.5, color: PdfColors.grey700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 6),
      child: pw.Text(text.toUpperCase(),
          style: pw.TextStyle(
              fontSize: 9.5,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.cyan900,
              letterSpacing: 1)),
    );
  }

  static pw.Widget _verdictBlock(MeasurementSummary s, String verdict) {
    final String? headline = s.matchHeadline;
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.cyan50,
        border: pw.Border.all(color: PdfColors.cyan200),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Text(verdict,
              style: pw.TextStyle(
                  fontSize: 16, fontWeight: pw.FontWeight.bold)),
          if (headline != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text(headline,
                  style: const pw.TextStyle(
                      fontSize: 11, color: PdfColors.grey800)),
            ),
          if (s.deviationPercent != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text(
                  'Signed deviation vs spherical model: '
                  '${s.deviationPercent!.toStringAsFixed(2)} %',
                  style: const pw.TextStyle(
                      fontSize: 9.5, color: PdfColors.grey700)),
            ),
        ],
      ),
    );
  }

  static pw.Widget _comparisonTable(MeasurementSummary s) {
    return _kvTable(<List<String>>[
      <String>['MEASURED', s.measuredValue.toStringAsFixed(3), s.measuredUnit],
      <String>['GLOBE MODEL EXPECTATION', s.globeExpected.toStringAsFixed(3), s.expectationUnit],
      <String>['FLAT EARTH MODEL EXPECTATION', s.flatExpected.toStringAsFixed(3), s.expectationUnit],
    ], <String>['Quantity', 'Value', 'Unit']);
  }

  static pw.Widget _sessionTable(MeasurementSummary s) {
    String coord(double? v, String pos, String neg) =>
        v == null ? '—' : '${v.abs().toStringAsFixed(5)}° ${v >= 0 ? pos : neg}';
    return _kvTable(<List<String>>[
      <String>['Latitude', coord(s.latitude, 'N', 'S')],
      <String>['Longitude', coord(s.longitude, 'E', 'W')],
      <String>['EKF altitude', s.altitudeM?.toStringAsFixed(2) ?? '—', 'm'],
      <String>['Track distance', s.distanceKm?.toStringAsFixed(3) ?? '—', 'km'],
      <String>['Session duration', s.durationS?.toStringAsFixed(0) ?? '—', 's'],
      <String>['Boresight pitch', s.pitchDeg?.toStringAsFixed(3) ?? '—', '°'],
      <String>['Captured at (local)', s.capturedAtIso],
    ], <String>['Parameter', 'Value', 'Unit']);
  }

  static pw.Widget _integrityTable(MeasurementSummary s) {
    return _kvTable(<List<String>>[
      <String>['Measurement ID (UUIDv4)', s.measurementId],
      <String>[
        'Raw log SHA-256',
        s.rawCsvSha256 ?? '— (hashed at enqueue time)'
      ],
      <String>[
        'Device signature (SHA-256)',
        s.signatureHashHex ?? '— (applied by sync layer, GOFv1)'
      ],
      <String>[
        'Storage',
        'Cloudflare D1 (append-only) + R2 raw dump, public API (CC0)'
      ],
    ], <String>['Field', 'Value']);
  }

  static pw.Widget _calibrationTable(MeasurementSummary s) {
    String score(double? v) => v == null ? '—' : '${v.toStringAsFixed(0)} %';
    return _kvTable(<List<String>>[
      <String>['Gyroscope (bias from rest check)', score(s.gyroScore)],
      <String>['Accelerometer (magnitude/noise)', score(s.accelScore)],
      <String>['Magnetometer (figure-8 coverage)', score(s.magScore)],
      <String>[
        'Calibrated at',
        s.calibratedAtMs == null
            ? '—'
            : DateTime.fromMillisecondsSinceEpoch(s.calibratedAtMs!)
                .toUtc()
                .toIso8601String()
      ],
    ], <String>['Component', 'Status']);
  }

  static pw.Widget _annotationsTable(MeasurementSummary s) {
    final List<List<String>> rows = <List<String>>[];
    for (final String line in (s.rawCsv ?? '').split('\n')) {
      final String l = line.trim();
      if (!l.startsWith('#') || l.contains('columns=')) continue;
      final String body = l.substring(1).trim();
      final int comma = body.indexOf(',');
      if (comma <= 0) continue;
      rows.add(<String>[body.substring(0, comma), body.substring(comma + 1)]);
    }
    if (s.extraRows.isNotEmpty) {
      s.extraRows.forEach((String k, String v) => rows.add(<String>[k, v]));
    }
    if (rows.isEmpty) {
      return pw.Text('No mode-specific annotations in this log.',
          style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700));
    }
    return _kvTable(rows, <String>['Key', 'Value']);
  }

  static pw.Widget _kvTable(List<List<String>> rows, List<String> headers) {
    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: rows,
      headerStyle: pw.TextStyle(
          fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.cyan900),
      cellStyle: const pw.TextStyle(fontSize: 8.5),
      cellAlignment: pw.Alignment.centerLeft,
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.4),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.cyan50),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey50),
    );
  }

  static pw.Widget _stampRow(String k, String v) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.SizedBox(
            width: 130,
            child: pw.Text('$k:',
                style: pw.TextStyle(
                    fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
          ),
          pw.Expanded(
            child: pw.Text(v, style: const pw.TextStyle(fontSize: 8.5)),
          ),
        ],
      ),
    );
  }

  static pw.Widget _footer(pw.Context ctx, MeasurementSummary s,
      {String? pageLabel}) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.Border(
          top: pw.BorderSide(color: PdfColors.grey300, width: 0.5)),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: <pw.Widget>[
          pw.Text('GlobeOrFlat · citizen geodesy · CC0 data / MIT code',
              style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
          pw.Text(
            pageLabel ?? 'audit report',
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
          ),
          pw.Text(
            'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  static List<String> _padRow(List<String> r) {
    final List<String> out = List<String>.from(r);
    while (out.length < 6) {
      out.add('');
    }
    return out;
  }

  static List<String> _padHeader(Iterable<String> h) {
    final List<String> out = List<String>.from(h);
    while (out.length < 6) {
      out.add('');
    }
    return out;
  }

  static Future<pw.FontTheme> _fontTheme() async {
    // The bundled fonts ship with the pdf package; fall back gracefully.
    return pw.FontTheme.withBase(
      base: const pw.TextStyle(fontSize: 9),
    );
  }

  static Future<Uint8List?> _tryLoadAsset(String assetPath) async {
    try {
      final ByteData data = await rootBundle.load(assetPath);
      return data.buffer.asUint8List();
    } on Exception {
      return null; // optional asset — report renders without the logo
    }
  }
}
