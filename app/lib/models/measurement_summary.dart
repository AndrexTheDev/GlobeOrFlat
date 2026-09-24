// ============================================================================
// GlobeOrFlat — Measurement Summary (shared result model)
// SPDX-License-Identifier: MIT
//
// The single data structure that flows into the Results screen, the 9:16
// share card and the PDF audit report. Carries everything those three
// surfaces need: the three-model comparison, the deviation/match scores,
// session context (GPS, altitude, distance, pitch), the integrity hashes
// and the calibration status.
//
// Match-score semantics (validated against the "99.4% Match" example):
//   dip / sightline modes : match = clamp(100 − |deviation%|, 0, 100)
//   track mode            : match = clamp(100 − max(0, deviation%), …)
//                           (negative deviation ⇒ globe arc fits better)
//   eratosthenes          : null until the paired site exists
// ============================================================================

import 'dart:math' as math;

/// Which family of semantics applies for scoring/verdicts.
enum SummaryFamily { pointModes, track, pairPending }

class MeasurementSummary {
  const MeasurementSummary({
    required this.measurementId,
    required this.modeWire,
    required this.capturedAtMs,
    required this.measuredValue,
    required this.measuredUnit,
    required this.globeExpected,
    required this.flatExpected,
    required this.expectationUnit,
    this.deviationPercent,
    this.latitude,
    this.longitude,
    this.altitudeM,
    this.distanceKm,
    this.durationS,
    this.pitchDeg,
    this.rawCsv,
    this.rawCsvSha256,
    this.signatureHashHex,
    this.gyroScore,
    this.accelScore,
    this.magScore,
    this.calibratedAtMs,
    this.routePoints,
    this.extraRows = const <String, String>{},
  });

  final String measurementId;
  final String modeWire;
  final int capturedAtMs;

  /// Measured quantity and unit (e.g. dip arcminutes, hidden metres, RMS m).
  final double measuredValue;
  final String measuredUnit;

  /// Model expectations in the same unit.
  final double globeExpected;
  final double flatExpected;
  final String expectationUnit;

  /// Signed deviation vs the globe model [%]; null when not computable yet.
  final double? deviationPercent;

  // Session context (nullable — degrade gracefully).
  final double? latitude;
  final double? longitude;
  final double? altitudeM;
  final double? distanceKm;
  final double? durationS;
  final double? pitchDeg;

  // Integrity chain.
  final String? rawCsv;
  final String? rawCsvSha256;
  final String? signatureHashHex;

  // Calibration status.
  final double? gyroScore;
  final double? accelScore;
  final double? magScore;
  final int? calibratedAtMs;

  /// Normalized route polyline (each entry 0..1 within the bounding box)
  /// for the share-card map snippet.
  final List<(double, double)>? routePoints;

  /// Mode-specific key/values surfaced on the card (e.g. sync code).
  final Map<String, String> extraRows;

  SummaryFamily get family =>
      modeWire == 'TRACK_DRIVE'
          ? SummaryFamily.track
          : (modeWire == 'ERATOSTHENES' && deviationPercent == null
              ? SummaryFamily.pairPending
              : SummaryFamily.pointModes);

  static double _clamp(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  /// "99.4 % Match with Spherical Earth Model" — see semantics above.
  double? get matchPercent {
    final double? dev = deviationPercent;
    if (dev == null) return null;
    switch (family) {
      case SummaryFamily.track:
        return _clamp(100.0 - math.max(0.0, dev), 0.0, 100.0);
      case SummaryFamily.pointModes:
      case SummaryFamily.pairPending:
        return _clamp(100.0 - dev.abs(), 0.0, 100.0);
    }
  }

  /// Short verdict label + the accent color index used by UI surfaces.
  /// 0=lime 1=cyan 2=amber 3=magenta 4=violet
  (String label, int accentIndex) get verdict {
    final double? m = matchPercent;
    if (m == null) {
      return (
        family == SummaryFamily.pairPending
            ? 'AWAITING PAIRED SITE'
            : 'INCONCLUSIVE',
        4
      );
    }
    if (m >= 95) return ('STRONG GLOBE MATCH', 0);
    if (m >= 75) return ('GLOBE CONSISTENT', 1);
    if (m >= 50) return ('AMBIGUOUS', 2);
    return (
      family == SummaryFamily.track ? 'FLAT FITS BETTER' : 'DEVIATES FROM GLOBE',
      3
    );
  }

  /// The human one-liner, e.g. "99.4% Match with Spherical Earth Model".
  String? get matchHeadline {
    final double? m = matchPercent;
    if (m == null) return null;
    return '${m.toStringAsFixed(1)}% Match with Spherical Earth Model';
  }

  /// Parsed raw-CSV data rows (comments and header skipped, max [maxRows]).
  List<List<String>> telemetryRows({int maxRows = 120}) {
    final String csv = rawCsv ?? '';
    if (csv.isEmpty) return const <List<String>>[];
    final List<List<String>> rows = <List<String>>[];
    for (final String line in csv.split('\n')) {
      final String l = line.trim();
      if (l.isEmpty || l.startsWith('#')) continue;
      rows.add(l.split(','));
      if (rows.length >= maxRows) break;
    }
    return rows;
  }

  /// First raw-CSV line that starts with `#` and contains [needle].
  String? csvAnnotation(String needle) {
    for (final String line in (rawCsv ?? '').split('\n')) {
      final String l = line.trim();
      if (l.startsWith('#') && l.contains(needle)) {
        return l.substring(1).trim();
      }
    }
    return null;
  }

  String get capturedAtIso =>
      DateTime.fromMillisecondsSinceEpoch(capturedAtMs).toIso8601String();
}
