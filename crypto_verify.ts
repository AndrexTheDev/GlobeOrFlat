/**
 * GlobeOrFlat — ECDSA signature verification for Android Keystore signings.
 * SPDX-License-Identifier: MIT
 *
 * ---------------------------------------------------------------------------
 * PROTOCOL (GOFv1)
 * ---------------------------------------------------------------------------
 * Every GlobeOrFlat Android client holds an EC P-256 key pair that never
 * leaves the hardware-backed Android Keystore (`SHA256withECDSA`). Devices
 * sign a *canonical string* and ship the detached signature alongside the
 * payload:
 *
 *   canonical = "GOFv1"                    \n   protocol version
 *             + METHOD in uppercase        \n   e.g. "POST"
 *             + canonical request path     \n   e.g. "/api/v1/measurements/upload"
 *             + device_id                  \n
 *             + sha256_hex(payload bytes)  \n   exact bytes of the JSON payload part
 *             + signed_at (epoch ms)           fresh at signing time (anti-replay)
 *
 * Android's `Signature.getInstance("SHA256withECDSA")` emits the signature as
 * ASN.1 DER (`ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }`), while
 * WebCrypto's `SubtleCrypto.verify()` expects the fixed-width 64-byte
 * `r || s` (IEEE P1363) form. This module performs the DER -> raw conversion
 * server-side so clients can send either format (`X-GoF-Signature-Format`:
 * `der` (default) | `raw` | `ieee-p1363`).
 *
 * All cryptographic primitives are WebCrypto (workerd-native); no Node APIs.
 */

const textEncoder = new TextEncoder();

/** Protocol version baked into every canonical string. */
export const PROTOCOL_VERSION = "GOFv1";

/** Raised when a signature or key is structurally malformed. */
export class SignatureFormatError extends Error {
  constructor(message = "Malformed ECDSA signature or key material") {
    super(message);
    this.name = "SignatureFormatError";
  }
}

/** Accepted signature encodings on the wire. */
export type SignatureFormat = "der" | "raw" | "ieee-p1363";

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

/** Decode standard or URL-safe base64 (padding optional) to bytes. */
export function base64ToBytes(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  let binary: string;
  try {
    binary = atob(padded);
  } catch {
    throw new SignatureFormatError("Signature is not valid base64");
  }
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** SHA-256 of a UTF-8 string or raw bytes, as lowercase hex. */
export async function sha256Hex(input: string | Uint8Array): Promise<string> {
  const bytes = typeof input === "string" ? textEncoder.encode(input) : input;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------------------
// ASN.1 DER -> IEEE P1363 (r || s) conversion
// ---------------------------------------------------------------------------

function readDerLength(der: Uint8Array, offset: number): { length: number; bytesUsed: number } {
  const first = der[offset];
  if (first === undefined) throw new SignatureFormatError("Truncated DER structure");
  if (first < 0x80) return { length: first, bytesUsed: 1 };
  const numBytes = first & 0x7f;
  if (numBytes === 0 || numBytes > 2) throw new SignatureFormatError("Unsupported DER length encoding");
  let length = 0;
  for (let i = 1; i <= numBytes; i++) {
    length = length * 256 + (der[offset + i] ?? 0);
  }
  return { length, bytesUsed: 1 + numBytes };
}

/**
 * Convert an ASN.1 DER ECDSA signature (what Android "SHA256withECDSA"
 * produces) into the 64-byte `r || s` form WebCrypto expects.
 */
export function derEcdsaSignatureToRaw(der: Uint8Array): Uint8Array {
  if (der.length < 8 || der[0] !== 0x30) {
    throw new SignatureFormatError("ECDSA signature must be a DER SEQUENCE");
  }
  let offset = 1;
  const { length: seqLen, bytesUsed: lenBytes } = readDerLength(der, offset);
  offset += lenBytes;
  const seqEnd = Math.min(offset + seqLen, der.length);

  const raw = new Uint8Array(64);
  for (let idx = 0; idx < 2; idx++) {
    if (offset + 2 > seqEnd || der[offset] !== 0x02) {
      throw new SignatureFormatError("ECDSA signature must contain exactly two DER INTEGERs");
    }
    offset += 1;
    const { length: intLen, bytesUsed } = readDerLength(der, offset);
    offset += bytesUsed;
    if (intLen <= 0 || offset + intLen > seqEnd) {
      throw new SignatureFormatError("DER INTEGER overruns the SEQUENCE boundary");
    }

    let start = offset;
    let len = intLen;
    // Strip the leading 0x00 DER adds to positive integers with the high bit set.
    while (len > 0 && der[start] === 0x00) {
      start += 1;
      len -= 1;
    }
    if (len === 0 || len > 32) {
      throw new SignatureFormatError("ECDSA r/s component out of P-256 range");
    }
    // Left-pad into a fixed 32-byte slot: r at [0..32), s at [32..64).
    raw.set(der.subarray(start, start + len), idx === 0 ? 32 - len : 64 - len);
    offset += intLen;
  }
  return raw;
}

/** Normalize a wire signature (DER or raw) to the 64-byte r||s form. */
export function normalizeSignature(signatureBase64: string, format: SignatureFormat): Uint8Array {
  const bytes = base64ToBytes(signatureBase64);
  if (format === "der") {
    return derEcdsaSignatureToRaw(bytes);
  }
  if (bytes.length !== 64) {
    throw new SignatureFormatError("raw/ieee-p1363 signatures must be exactly 64 bytes");
  }
  return bytes;
}

// ---------------------------------------------------------------------------
// Key import + verification
// ---------------------------------------------------------------------------

/**
 * Import a base64 DER SubjectPublicKeyInfo EC P-256 public key.
 * WebCrypto rejects keys on any other curve, so this doubles as a curve check.
 */
export async function importP256PublicKeyFromSpki(spkiBase64: string): Promise<CryptoKey> {
  const spki = base64ToBytes(spkiBase64);
  // P-256 SPKI is ~91 bytes (65-byte uncompressed point + 26-byte header).
  if (spki.length < 26 || spki.length > 128) {
    throw new SignatureFormatError("Public key SPKI has implausible length");
  }
  return crypto.subtle.importKey("spki", spki, { name: "ECDSA", namedCurve: "P-256" }, false, [
    "verify",
  ]);
}

export interface VerifyEcdsaParams {
  /** Base64 DER SPKI public key of the device (from `device_keys`). */
  publicKeySpkiBase64: string;
  /** Base64 (standard or base64url) detached signature. */
  signatureBase64: string;
  /** Wire encoding of the signature. */
  signatureFormat: SignatureFormat;
  /** The exact canonical string that was signed (UTF-8). */
  message: string;
}

/** Verify a detached ECDSA P-256 / SHA-256 signature. Never throws for bad signatures — returns false. */
export async function verifyDetachedEcdsaP256(params: VerifyEcdsaParams): Promise<boolean> {
  const key = await importP256PublicKeyFromSpki(params.publicKeySpkiBase64);
  const signature = normalizeSignature(params.signatureBase64, params.signatureFormat);
  return crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    signature,
    textEncoder.encode(params.message),
  );
}

// ---------------------------------------------------------------------------
// Canonical string builders (the exact bytes clients sign)
// ---------------------------------------------------------------------------

export interface MeasurementSignatureContext {
  method: string;
  path: string;
  deviceId: string;
  /** sha256_hex of the exact payload JSON bytes. */
  payloadSha256Hex: string;
  /** Client clock at signing time (epoch ms); must be fresh server-side. */
  signedAtMs: number;
}

export function buildMeasurementCanonicalString(ctx: MeasurementSignatureContext): string {
  return buildCanonicalString([
    PROTOCOL_VERSION,
    ctx.method.toUpperCase(),
    ctx.path,
    ctx.deviceId,
    ctx.payloadSha256Hex,
    String(ctx.signedAtMs),
  ]);
}

export interface RegistrationSignatureContext {
  method: string;
  path: string;
  deviceId: string;
  /** sha256_hex of the public key SPKI DER bytes being registered. */
  publicKeySpkiSha256Hex: string;
  signedAtMs: number;
}

export function buildRegistrationCanonicalString(ctx: RegistrationSignatureContext): string {
  return buildCanonicalString([
    PROTOCOL_VERSION,
    ctx.method.toUpperCase(),
    ctx.path,
    ctx.deviceId,
    ctx.publicKeySpkiSha256Hex,
    String(ctx.signedAtMs),
  ]);
}

function buildCanonicalString(parts: string[]): string {
  return parts.join("\n");
}
