// ============================================================================
// GlobeOrFlat — Android Keystore Cryptographic Signing Service
// SPDX-License-Identifier: MIT
//
// Manages an ECDSA P-256 key pair that lives ENTIRELY inside the
// hardware-backed Android Keystore (non-exportable) and signs measurement
// payloads with `SHA256withECDSA` (ASN.1 DER signatures — the format the
// GlobeOrFlat backend expects in `X-GoF-Signature`).
//
// The Dart side owns the GOFv1 canonical-string construction; the native
// Android side (see android/app/src/main/kotlin/.../MainActivity.kt) only
// ever sees the finished message bytes and returns a detached signature.
//
// GOFv1 canonical string (must match crypto_verify.ts on the backend):
//
//   GOFv1 \n METHOD \n path \n device_id \n sha256_hex(payload bytes) \n signed_at
//
// CRITICAL INVARIANT: the exact `payloadJson` string returned in
// [SignedMeasurement.payloadJson] is what gets hashed, signed AND uploaded.
// Any re-serialization would invalidate the signature.
// ============================================================================

import 'dart:convert' show base64, utf8;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Protocol version — must match the backend (`crypto_verify.ts`).
const String kGofProtocolVersion = 'GOFv1';

/// Backend route constants — canonical strings must use the same paths.
const String kUploadPath = '/api/v1/measurements/upload';
const String kRegisterPath = '/api/v1/devices/register';

class SignatureException implements Exception {
  final String message;
  final String? code;
  SignatureException(this.message, {this.code});

  @override
  String toString() => 'SignatureException${code == null ? '' : '($code)'}: $message';
}

/// The result of signing a measurement payload: everything the sync manager
/// needs to build a tamper-evident upload request.
class SignedMeasurement {
  /// Exact JSON payload bytes (UTF-8) that were hashed and signed.
  final String payloadJson;

  /// sha256 hex of [payloadJson] UTF-8 bytes (lowercase).
  final String payloadSha256Hex;

  /// Client clock at signing time (epoch ms) — also present in the payload.
  final int signedAtMs;

  /// Base64 (standard, no wrapping) DER-encoded ECDSA signature.
  final String signatureBase64Der;

  const SignedMeasurement({
    required this.payloadJson,
    required this.payloadSha256Hex,
    required this.signedAtMs,
    required this.signatureBase64Der,
  });
}

class KeystoreService {
  static const MethodChannel _channel = MethodChannel('globeorflat/keystore');

  /// Key alias inside the Android Keystore (must match MainActivity.kt).
  static const String keyAlias = 'gof_device_key';

  // -------------------------------------------------------------------------
  // Channel methods
  // -------------------------------------------------------------------------

  /// Creates the EC P-256 Keystore key pair if absent. Returns the public
  /// key as base64 DER SubjectPublicKeyInfo (what the backend stores in
  /// `device_keys.public_key_spki`).
  Future<String> ensureKeyPair() async {
    try {
      final String spki =
          await _channel.invokeMethod<String>('ensureKeyPair') ?? '';
      if (spki.isEmpty) {
        throw SignatureException('Keystore returned an empty public key.');
      }
      return spki;
    } on PlatformException catch (e) {
      throw SignatureException(
        'Could not create/read the Android Keystore key: ${e.message}',
        code: e.code,
      );
    }
  }

  /// Returns the registered public key (base64 DER SPKI) without creating.
  Future<String?> getPublicKeySpkiBase64() async {
    try {
      return await _channel.invokeMethod<String>('getPublicKeySpkiBase64');
    } on PlatformException catch (e) {
      throw SignatureException(e.message ?? 'Keystore read failed', code: e.code);
    }
  }

  /// Signs a canonical message (UTF-8) with `SHA256withECDSA`.
  /// Returns base64 DER — send it as `X-GoF-Signature` with
  /// `X-GoF-Signature-Format: der`.
  Future<String> signCanonicalMessage(String message) async {
    try {
      final String sig =
          await _channel.invokeMethod<String>('sign', <String, dynamic>{
        'message': message,
      }) ??
          '';
      if (sig.isEmpty) {
        throw SignatureException('Keystore returned an empty signature.');
      }
      return sig;
    } on PlatformException catch (e) {
      throw SignatureException(
        'Signing failed: ${e.message}',
        code: e.code,
      );
    }
  }

  /// Destroys the device key. The backend keeps historical keys, so past
  /// measurements remain verifiable — this only affects future uploads.
  Future<void> deleteKey() async {
    try {
      await _channel.invokeMethod<void>('deleteKey');
    } on PlatformException catch (e) {
      throw SignatureException(e.message ?? 'Key deletion failed', code: e.code);
    }
  }

  // -------------------------------------------------------------------------
  // GOFv1 canonical strings + high-level payload signing
  // -------------------------------------------------------------------------

  /// sha256 hex over UTF-8 bytes (lowercase hex — backend convention).
  static String sha256HexOfBytes(List<int> bytes) =>
      sha256.convert(bytes).toString();

  static String buildCanonicalString({
    required String method,
    required String path,
    required String deviceId,
    required String subjectSha256Hex,
    required int signedAtMs,
  }) {
    return <String>[
      kGofProtocolVersion,
      method.toUpperCase(),
      path,
      deviceId,
      subjectSha256Hex,
      signedAtMs.toString(),
    ].join('\n');
  }

  /// Signs a registration request (proof-of-possession: the subject that is
  /// hashed into the canonical string is the SPKI being registered).
  Future<SignedMeasurement> signDeviceRegistration({
    required String deviceId,
    required String publicKeySpkiBase64,
  }) async {
    final List<int> spkiBytes = base64.decode(publicKeySpkiBase64);
    final int signedAt = DateTime.now().millisecondsSinceEpoch;
    final String canonical = buildCanonicalString(
      method: 'POST',
      path: kRegisterPath,
      deviceId: deviceId,
      subjectSha256Hex: sha256HexOfBytes(spkiBytes),
      signedAtMs: signedAt,
    );
    final String signature = await signCanonicalMessage(canonical);
    return SignedMeasurement(
      payloadJson: '', // registration body is built by the sync manager
      payloadSha256Hex: sha256HexOfBytes(spkiBytes),
      signedAtMs: signedAt,
      signatureBase64Der: signature,
    );
  }

  /// Signs a measurement payload for upload.
  ///
  /// [payloadJson] must already contain `device_id` and `signed_at`
  /// (= [signedAtMs]); the canonical string hashes the exact UTF-8 bytes of
  /// the string, so callers MUST upload this same string unmodified.
  Future<SignedMeasurement> signMeasurementPayload({
    required String payloadJson,
    required String deviceId,
    required int signedAtMs,
  }) async {
    final List<int> payloadBytes = utf8.encode(payloadJson);
    final String canonical = buildCanonicalString(
      method: 'POST',
      path: kUploadPath,
      deviceId: deviceId,
      subjectSha256Hex: sha256HexOfBytes(payloadBytes),
      signedAtMs: signedAtMs,
    );
    final String signature = await signCanonicalMessage(canonical);
    return SignedMeasurement(
      payloadJson: payloadJson,
      payloadSha256Hex: sha256HexOfBytes(payloadBytes),
      signedAtMs: signedAtMs,
      signatureBase64Der: signature,
    );
  }
}
