/**
 * GlobeOrFlat — citizen-science Earth-curvature measurement API.
 * SPDX-License-Identifier: MIT
 *
 * Cloudflare Worker entrypoint: Hono router + route handlers.
 *
 * DESIGN INVARIANTS (enforced in code AND in schema.sql):
 *   1. APPEND-ONLY — there is no UPDATE or DELETE route in this API, and D1
 *      triggers abort any UPDATE/DELETE at the storage layer. Public client
 *      keys can only ever add data.
 *   2. SIGNED INGEST — every measurement row is bound to a detached ECDSA
 *      P-256 signature produced by the device's hardware-backed Android
 *      Keystore key (see crypto_verify.ts for the GOFv1 protocol).
 *   3. RAW DATA IN R2 — the full sensor dump is written once to R2; D1 keeps
 *      its key + SHA-256 so researchers can re-verify integrity.
 *
 * Routes:
 *   POST /api/v1/measurements/upload   (client token + device signature)
 *   GET  /api/v1/measurements          (public, paginated, filterable)
 *   GET  /api/v1/measurements/:id      (public, + presigned R2 download link)
 *   GET  /api/v1/measurements/:id/dump (public, streams the raw CSV)
 *   POST /api/v1/devices/register      (client token + proof-of-possession)
 *   POST /api/v1/admin/verifications    (admin token; appends ledger event)
 *   GET  /api/v1/admin/stats            (admin token)
 *   GET  /api/v1/health
 */

import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { secureHeaders } from "hono/secure-headers";
import { z } from "zod";

import {
  base64ToBytes,
  buildMeasurementCanonicalString,
  buildRegistrationCanonicalString,
  importP256PublicKeyFromSpki,
  sha256Hex,
  verifyDetachedEcdsaP256,
  type SignatureFormat,
} from "./crypto_verify";

// ---------------------------------------------------------------------------
// Bindings & configuration
// ---------------------------------------------------------------------------

type RateLimitBinding = {
  limit(input: { key: string }): Promise<{ success: boolean }>;
};

export type Env = {
  /** D1 database (append-only tables + verification ledger). */
  DB: D1Database;
  /** R2 bucket holding raw sensor dumps (write-once). */
  RAW_DUMPS: R2Bucket;
  /** Optional Workers rate-limit binding (see wrangler.toml). */
  RATE_LIMITER?: RateLimitBinding;

  /** Secret shared with client apps; permits ONLY ingest + registration. */
  CLIENT_INGEST_TOKEN: string;
  /** Moderator token; permits ONLY appending verification ledger events. */
  ADMIN_TOKEN: string;

  MAX_SENSOR_DUMP_BYTES?: string;
  /** JSON metadata part limit (the signed `payload` part). */
  MAX_PAYLOAD_BYTES?: string;
  PRESIGN_TTL_SECONDS?: string;
  SIGNATURE_MAX_SKEW_MS?: string;
  AUTO_VERIFY_SIGNED_UPLOADS?: string;
};

const MEASUREMENT_MODES = ["HORIZON_DIP", "WATER_SIGHTLINE", "TRACK_DRIVE", "ERATOSTHENES"] as const;

/** Canonical paths are constants — signatures stay valid behind proxies/custom domains. */
const API_PREFIX = "/api/v1";
const UPLOAD_PATH = `${API_PREFIX}/measurements/upload`;
const REGISTER_PATH = `${API_PREFIX}/devices/register`;

const DEFAULT_MAX_DUMP_BYTES = 5 * 1024 * 1024; // 5 MiB
const DEFAULT_MAX_PAYLOAD_BYTES = 64 * 1024; // 64 KiB — metadata is tiny
const DEFAULT_PRESIGN_TTL = 3600; // seconds
const DEFAULT_SIGNATURE_SKEW_MS = 300_000; // ±5 min
const EPOCH_FLOOR_MS = 1577836800000; // 2020-01-01 — reject obviously bogus clocks
const CAPTURE_FUTURE_TOLERANCE_MS = 24 * 60 * 60 * 1000;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DEVICE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{7,63}$/;
const ALLOWED_DUMP_TYPES = ["text/csv", "text/plain", "application/csv", "application/octet-stream"];

function numberVar(raw: string | undefined, fallback: number): number {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

/** Length-safe string comparison (no early exit on content mismatch). */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ---------------------------------------------------------------------------
// Validation schemas
// ---------------------------------------------------------------------------

const measurementPayloadSchema = z.object({
  device_id: z.string().regex(DEVICE_ID_RE, "device_id must be 8-64 chars of [A-Za-z0-9._:-]"),
  mode: z.enum(MEASUREMENT_MODES),
  /** Client-captured measurement time, epoch ms. */
  timestamp: z.number().int(),
  /** Client clock at signing time, epoch ms (anti-replay). */
  signed_at: z.number().int(),
  gps_lat: z.number().min(-90).max(90),
  gps_lon: z.number().min(-180).max(180),
  altitude_m: z.number().min(-450).max(9000),
  curvature_deviation_percentage: z.number().min(-1_000_000).max(1_000_000).nullish(),
});

const deviceRegistrationSchema = z.object({
  device_id: z.string().regex(DEVICE_ID_RE),
  key_version: z.number().int().min(1).max(1000).default(1),
  /** Base64 DER SubjectPublicKeyInfo of the EC P-256 Keystore public key. */
  public_key_spki: z.string().min(1).max(512),
  /** Optional Android Key Attestation chain (base64 DER certs, leaf first). */
  attestation_chain: z.array(z.string().min(1).max(8192)).max(8).optional(),
  signed_at: z.number().int(),
  signature: z.string().min(1).max(1024),
  signature_format: z.enum(["der", "raw", "ieee-p1363"]).default("der"),
});

const verificationEventSchema = z.object({
  measurement_id: z.string().regex(UUID_RE),
  decision: z.enum(["VERIFIED", "REJECTED", "FLAGGED"]),
  reason: z.string().max(2000).optional(),
  decided_by: z.string().max(128).default("admin"),
});

const listQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  per_page: z.coerce.number().int().min(1).max(100).default(20),
  status: z.enum(["VERIFIED", "PENDING", "REJECTED", "FLAGGED", "ALL"]).default("VERIFIED"),
  mode: z.enum(MEASUREMENT_MODES).optional(),
  device_id: z.string().max(64).optional(),
  since: z.coerce.number().int().optional(),
  until: z.coerce.number().int().optional(),
  min_lat: z.coerce.number().min(-90).max(90).optional(),
  max_lat: z.coerce.number().min(-90).max(90).optional(),
  min_lon: z.coerce.number().min(-180).max(180).optional(),
  max_lon: z.coerce.number().min(-180).max(180).optional(),
});

// ---------------------------------------------------------------------------
// Row / response shapes
// ---------------------------------------------------------------------------

type MeasurementRow = {
  id: string;
  user_device_id: string;
  mode: string;
  timestamp: number;
  gps_lat: number;
  gps_lon: number;
  altitude_m: number;
  raw_sensor_dump_r2_key: string;
  raw_dump_sha256: string | null;
  curvature_deviation_percentage: number | null;
  verification_status: string;
  signature_hash: string;
  created_at: string;
};

function measurementToJson(row: MeasurementRow, origin: string) {
  return {
    id: row.id,
    device_id: row.user_device_id,
    mode: row.mode,
    timestamp: row.timestamp,
    timestamp_iso: new Date(row.timestamp).toISOString(),
    gps_lat: row.gps_lat,
    gps_lon: row.gps_lon,
    altitude_m: row.altitude_m,
    curvature_deviation_percentage: row.curvature_deviation_percentage,
    verification_status: row.verification_status,
    signature_hash: row.signature_hash,
    raw_dump_sha256: row.raw_dump_sha256,
    created_at: row.created_at,
    links: {
      self: `${origin}${API_PREFIX}/measurements/${row.id}`,
      raw_dump: `${origin}${API_PREFIX}/measurements/${row.id}/dump`,
    },
  };
}

// ---------------------------------------------------------------------------
// App + middleware
// ---------------------------------------------------------------------------

const app = new Hono<{ Bindings: Env }>();

app.use("*", logger());
app.use("*", secureHeaders());
app.use(
  `${API_PREFIX}/*`,
  cors({
    origin: "*",
    allowMethods: ["GET", "POST", "OPTIONS"],
    allowHeaders: ["content-type", "authorization", "x-gof-device-id", "x-gof-signature", "x-gof-signature-format"],
    exposeHeaders: ["etag", "content-length", "x-request-id"],
    maxAge: 86400,
  }),
);

// Correlate every response with a request id (surfaced in logs & CORS).
app.use("*", async (c, next) => {
  c.header("x-request-id", crypto.randomUUID());
  await next();
});

// Best-effort platform rate limiting; degrades to allow-all if the optional
// RATE_LIMITER binding is not configured (e.g. local dev).
app.use(`${API_PREFIX}/*`, async (c, next) => {
  const limiter = c.env.RATE_LIMITER;
  if (limiter) {
    try {
      const ip = c.req.header("cf-connecting-ip") ?? "unknown";
      const { success } = await limiter.limit({ key: ip });
      if (!success) {
        return jsonError(c, 429, "rate_limited", "Too many requests. Slow down.");
      }
    } catch {
      // Rate limiter unavailable — fail open.
    }
  }
  await next();
});

// ---------------------------------------------------------------------------
// Shared auth helpers
// ---------------------------------------------------------------------------

function bearerToken(c: { req: { header(name: string): string | undefined } }): string | null {
  const header = c.req.header("authorization");
  if (!header) return null;
  const [scheme, token] = header.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !token) return null;
  return token.trim();
}

/** Client ingest token: allows INSERT-only operations (upload, register). */
function requireIngestToken(c: { env: Env; req: any }): Response | null {
  if (!c.env.CLIENT_INGEST_TOKEN) {
    return jsonError(c, 500, "server_misconfigured", "CLIENT_INGEST_TOKEN secret is not set.");
  }
  const token = bearerToken(c);
  if (!token || !timingSafeEqual(token, c.env.CLIENT_INGEST_TOKEN)) {
    return jsonError(c, 401, "unauthorized", "Provide Authorization: Bearer <CLIENT_INGEST_TOKEN>.");
  }
  return null;
}

/** Admin token: allows appending verification events + reading stats. */
function requireAdminToken(c: { env: Env; req: any }): Response | null {
  if (!c.env.ADMIN_TOKEN) {
    return jsonError(c, 500, "server_misconfigured", "ADMIN_TOKEN secret is not set.");
  }
  const token = bearerToken(c);
  if (!token || !timingSafeEqual(token, c.env.ADMIN_TOKEN)) {
    return jsonError(c, 401, "unauthorized", "Provide Authorization: Bearer <ADMIN_TOKEN>.");
  }
  return null;
}

function jsonError(
  c: any,
  status: number,
  code: string,
  message: string,
  details?: unknown,
): Response {
  const body: Record<string, unknown> = { error: code, message };
  if (details !== undefined) body.details = details;
  return c.json(body, status as 400);
}

// ===========================================================================
// POST /api/v1/measurements/upload
// ---------------------------------------------------------------------------
// multipart/form-data:
//   payload  (required) — UTF-8 JSON measurement metadata (signed)
//   dump     (required) — raw sensor log file (CSV)
// headers:
//   Authorization:            Bearer <CLIENT_INGEST_TOKEN>
//   X-GoF-Device-Id:          must match payload.device_id
//   X-GoF-Signature:          base64 detached ECDSA signature (GOFv1 canonical)
//   X-GoF-Signature-Format:   der (default) | raw | ieee-p1363
// ===========================================================================
app.post(UPLOAD_PATH, async (c) => {
  const authError = requireIngestToken(c);
  if (authError) return authError;

  const contentType = (c.req.header("content-type") ?? "").toLowerCase();
  if (!contentType.includes("multipart/form-data")) {
    return jsonError(
      c,
      415,
      "unsupported_media_type",
      "Uploads must be multipart/form-data with 'payload' (JSON) and 'dump' (raw sensor file) parts.",
    );
  }

  let form: Record<string, string | File>;
  try {
    form = await c.req.parseBody();
  } catch {
    return jsonError(c, 400, "invalid_multipart", "Could not parse multipart body.");
  }

  const payloadPart = form["payload"];
  const dumpPart = form["dump"];
  if (payloadPart === undefined || dumpPart === undefined || typeof dumpPart !== "object") {
    return jsonError(c, 400, "missing_part", "Both 'payload' (JSON) and 'dump' (file) parts are required.");
  }

  const payloadText = typeof payloadPart === "string" ? payloadPart : await payloadPart.text();
  // Byte-exact size guard on the (signed) metadata part — a multi-megabyte
  // JSON blob would burn hash/verify CPU before any validation runs.
  const maxPayloadBytes = numberVar(c.env.MAX_PAYLOAD_BYTES, DEFAULT_MAX_PAYLOAD_BYTES);
  const payloadBytes = new TextEncoder().encode(payloadText).byteLength;
  if (payloadBytes > maxPayloadBytes) {
    return jsonError(c, 413, "payload_too_large", `The 'payload' part exceeds the ${maxPayloadBytes}-byte limit.`);
  }
  const dump = dumpPart as File;

  let payloadJson: unknown;
  try {
    payloadJson = JSON.parse(payloadText);
  } catch {
    return jsonError(c, 400, "invalid_payload", "The 'payload' part is not valid JSON.");
  }

  const parsed = measurementPayloadSchema.safeParse(payloadJson);
  if (!parsed.success) {
    return jsonError(c, 400, "invalid_payload", "Payload failed schema validation.", parsed.error.flatten());
  }
  const p = parsed.data;

  const headerDeviceId = c.req.header("x-gof-device-id");
  if (headerDeviceId !== p.device_id) {
    return jsonError(c, 400, "device_id_mismatch", "X-GoF-Device-Id header must match payload.device_id.");
  }

  // --- Anti-replay: the signature must be fresh -----------------------------
  const skewMs = numberVar(c.env.SIGNATURE_MAX_SKEW_MS, DEFAULT_SIGNATURE_SKEW_MS);
  const now = Date.now();
  if (Math.abs(now - p.signed_at) > skewMs) {
    return jsonError(c, 401, "signature_expired", `signed_at is outside the ±${skewMs / 1000}s window. Retry with a fresh signature.`);
  }
  if (p.timestamp < EPOCH_FLOOR_MS || p.timestamp > now + CAPTURE_FUTURE_TOLERANCE_MS) {
    return jsonError(c, 400, "invalid_timestamp", "Measurement timestamp is out of plausible range.");
  }

  // --- Raw dump sanity -------------------------------------------------------
  const maxDumpBytes = numberVar(c.env.MAX_SENSOR_DUMP_BYTES, DEFAULT_MAX_DUMP_BYTES);
  if (dump.size > maxDumpBytes) {
    return jsonError(c, 413, "dump_too_large", `Raw sensor dump exceeds the ${maxDumpBytes}-byte limit.`);
  }
  const dumpType = (dump.type || "text/csv").toLowerCase();
  if (!ALLOWED_DUMP_TYPES.includes(dumpType)) {
    return jsonError(c, 415, "unsupported_dump_type", `Dump content-type must be one of: ${ALLOWED_DUMP_TYPES.join(", ")}.`);
  }

  // --- Device lookup ----------------------------------------------------------
  const keyResult = await c.env.DB.prepare(
    `SELECT key_version, public_key_spki, attestation_sha256
       FROM device_keys
      WHERE device_id = ?
      ORDER BY key_version DESC`,
  )
    .bind(p.device_id)
    .all();
  const deviceKeys = (keyResult.results ?? []) as Array<{
    key_version: number;
    public_key_spki: string;
    attestation_sha256: string | null;
  }>;
  if (deviceKeys.length === 0) {
    return jsonError(c, 403, "unknown_device", "Device is not registered. POST /api/v1/devices/register first.");
  }

  // --- Signature verification (GOFv1 canonical string) -----------------------
  const payloadSha256Hex = await sha256Hex(payloadText);
  const canonical = buildMeasurementCanonicalString({
    method: "POST",
    path: UPLOAD_PATH,
    deviceId: p.device_id,
    payloadSha256Hex,
    signedAtMs: p.signed_at,
  });

  const signatureHeader = c.req.header("x-gof-signature");
  if (!signatureHeader) {
    return jsonError(c, 401, "missing_signature", "X-GoF-Signature header is required.");
  }
  const signatureFormat = (c.req.header("x-gof-signature-format") ?? "der") as SignatureFormat;

  let signatureOk = false;
  let signedKeyVersion: number | null = null;
  for (const key of deviceKeys) {
    const ok = await verifyDetachedEcdsaP256({
      publicKeySpkiBase64: key.public_key_spki,
      signatureBase64: signatureHeader,
      signatureFormat,
      message: canonical,
    }).catch(() => false);
    if (ok) {
      signatureOk = true;
      signedKeyVersion = key.key_version;
      break;
    }
  }
  if (!signatureOk) {
    return jsonError(c, 401, "invalid_signature", "ECDSA P-256 verification failed against all registered device keys.");
  }

  const signatureHash = await sha256Hex(base64ToBytes(signatureHeader));

  // --- Replay defense (database-level backstop via UNIQUE signature_hash) ----
  const duplicate = await c.env.DB.prepare(
    "SELECT 1 AS x FROM measurements WHERE signature_hash = ?",
  )
    .bind(signatureHash)
    .first();
  if (duplicate) {
    return jsonError(c, 409, "duplicate_measurement", "This exact signature was already ingested (replay rejected).");
  }

  // --- Write raw dump to R2 (write-once key includes the measurement UUID) ---
  const id = crypto.randomUUID();
  const uploadedAt = new Date();
  const deviceHash = (await sha256Hex(p.device_id)).slice(0, 16);
  const r2Key = `raw-dumps/${uploadedAt.getUTCFullYear()}/${String(uploadedAt.getUTCMonth() + 1).padStart(2, "0")}/${deviceHash}/${id}.csv`;

  const dumpBytes = await dump.arrayBuffer();
  const dumpSha256HexValue = await sha256Hex(new Uint8Array(dumpBytes));

  await c.env.RAW_DUMPS.put(r2Key, dumpBytes, {
    httpMetadata: { contentType: dumpType },
    customMetadata: {
      measurement_id: id,
      device_id: p.device_id,
      signed_with_key_version: String(signedKeyVersion),
      payload_sha256: payloadSha256Hex,
      signature_hash: signatureHash,
      dump_sha256: dumpSha256HexValue,
    },
  });

  // --- Insert metadata into D1 (append-only) ---------------------------------
  const autoVerify = (c.env.AUTO_VERIFY_SIGNED_UPLOADS ?? "false").toLowerCase() === "true";
  const initialStatus = autoVerify ? "VERIFIED" : "PENDING";

  try {
    await c.env.DB.prepare(
      `INSERT INTO measurements (
         id, user_device_id, mode, timestamp,
         gps_lat, gps_lon, altitude_m,
         raw_sensor_dump_r2_key, raw_dump_sha256,
         curvature_deviation_percentage,
         verification_status, signature_hash
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        id,
        p.device_id,
        p.mode,
        p.timestamp,
        p.gps_lat,
        p.gps_lon,
        p.altitude_m,
        r2Key,
        dumpSha256HexValue,
        p.curvature_deviation_percentage ?? null,
        initialStatus,
        signatureHash,
      )
      .run();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("UNIQUE constraint failed") && msg.includes("signature_hash")) {
      return jsonError(c, 409, "duplicate_measurement", "Replay detected at insert time (concurrent duplicate).");
    }
    throw err;
  }

  const origin = new URL(c.req.url).origin;
  return c.json(
    {
      id,
      verification_status: initialStatus,
      signature_hash: signatureHash,
      signed_with_key_version: signedKeyVersion,
      created_at: uploadedAt.toISOString(),
      raw_dump: { r2_key: r2Key, size_bytes: dump.size, sha256: dumpSha256HexValue },
      links: {
        self: `${origin}${API_PREFIX}/measurements/${id}`,
        raw_dump: `${origin}${API_PREFIX}/measurements/${id}/dump`,
      },
    },
    201,
  );
});

// ===========================================================================
// GET /api/v1/measurements — public researcher feed
// ===========================================================================
app.get(`${API_PREFIX}/measurements`, async (c) => {
  const q = listQuerySchema.safeParse(c.req.query());
  if (!q.success) {
    return jsonError(c, 400, "invalid_query", "Invalid query parameters.", q.error.flatten());
  }
  const { page, per_page, status, mode, device_id, since, until, min_lat, max_lat, min_lon, max_lon } = q.data;

  const where: string[] = [];
  const binds: (string | number)[] = [];
  if (status !== "ALL") {
    where.push("s.effective_status = ?");
    binds.push(status);
  }
  if (mode !== undefined) {
    where.push("m.mode = ?");
    binds.push(mode);
  }
  if (device_id !== undefined) {
    where.push("m.user_device_id = ?");
    binds.push(device_id);
  }
  if (since !== undefined) {
    where.push("m.timestamp >= ?");
    binds.push(since);
  }
  if (until !== undefined) {
    where.push("m.timestamp <= ?");
    binds.push(until);
  }
  if (min_lat !== undefined) {
    where.push("m.gps_lat >= ?");
    binds.push(min_lat);
  }
  if (max_lat !== undefined) {
    where.push("m.gps_lat <= ?");
    binds.push(max_lat);
  }
  if (min_lon !== undefined) {
    where.push("m.gps_lon >= ?");
    binds.push(min_lon);
  }
  if (max_lon !== undefined) {
    where.push("m.gps_lon <= ?");
    binds.push(max_lon);
  }
  const whereSql = where.length > 0 ? ` WHERE ${where.join(" AND ")}` : "";

  const countRow = (await c.env.DB.prepare(
    `SELECT COUNT(*) AS total
       FROM measurements m
       JOIN measurement_effective_status s ON s.measurement_id = m.id${whereSql}`,
  )
    .bind(...binds)
    .first()) as { total: number } | null;
  const total = countRow?.total ?? 0;

  const offset = (page - 1) * per_page;
  const listResult = await c.env.DB.prepare(
    `SELECT m.id, m.user_device_id, m.mode, m.timestamp,
            m.gps_lat, m.gps_lon, m.altitude_m,
            m.raw_sensor_dump_r2_key, m.raw_dump_sha256,
            m.curvature_deviation_percentage,
            s.effective_status AS verification_status,
            m.signature_hash, m.created_at
       FROM measurements m
       JOIN measurement_effective_status s ON s.measurement_id = m.id${whereSql}
      ORDER BY m.timestamp DESC, m.created_at DESC
      LIMIT ? OFFSET ?`,
  )
    .bind(...binds, per_page, offset)
    .all();

  const rows = (listResult.results ?? []) as unknown as MeasurementRow[];
  const totalPages = Math.max(1, Math.ceil(total / per_page));
  const origin = new URL(c.req.url).origin;

  return c.json(
    {
      data: rows.map((row) => measurementToJson(row, origin)),
      pagination: {
        page,
        per_page,
        total_items: total,
        total_pages: totalPages,
        has_next: page < totalPages,
        has_prev: page > 1,
      },
    },
    200,
    { "cache-control": "public, max-age=15" },
  );
});

// ===========================================================================
// GET /api/v1/measurements/:id — public detail + raw dump links
// ===========================================================================
app.get(`${API_PREFIX}/measurements/:id`, async (c) => {
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) {
    return jsonError(c, 400, "invalid_id", "Measurement id must be a UUID.");
  }

  const row = (await c.env.DB.prepare(
    `SELECT m.id, m.user_device_id, m.mode, m.timestamp,
            m.gps_lat, m.gps_lon, m.altitude_m,
            m.raw_sensor_dump_r2_key, m.raw_dump_sha256,
            m.curvature_deviation_percentage,
            s.effective_status AS verification_status,
            m.signature_hash, m.created_at
       FROM measurements m
       JOIN measurement_effective_status s ON s.measurement_id = m.id
      WHERE m.id = ?`,
  )
    .bind(id)
    .first()) as MeasurementRow | null;
  if (!row) {
    return jsonError(c, 404, "not_found", `No measurement with id ${id}.`);
  }

  const origin = new URL(c.req.url).origin;
  const proxyUrl = `${origin}${API_PREFIX}/measurements/${id}/dump`;

  // Presigned, expiring download link for the raw CSV (falls back to proxy).
  const presignTtl = numberVar(c.env.PRESIGN_TTL_SECONDS, DEFAULT_PRESIGN_TTL);
  let downloadUrl = proxyUrl;
  try {
    const bucket = c.env.RAW_DUMPS as R2Bucket & {
      createSignedURL?: (key: string, expiresIn: number) => Promise<string>;
    };
    if (typeof bucket.createSignedURL === "function") {
      downloadUrl = await bucket.createSignedURL(row.raw_sensor_dump_r2_key, presignTtl);
    }
  } catch {
    // Presigning unavailable — the streaming proxy route always works.
  }

  let head: R2Object | null = null;
  try {
    head = await c.env.RAW_DUMPS.head(row.raw_sensor_dump_r2_key);
  } catch {
    // Object listing unavailable in this context — report available: false.
  }

  return c.json(
    {
      ...measurementToJson(row, origin),
      raw_sensor_dump_r2_key: row.raw_sensor_dump_r2_key,
      raw_dump: {
        available: head !== null,
        size_bytes: head?.size ?? null,
        content_type: head?.httpMetadata?.contentType ?? null,
        etag: head?.httpEtag ?? null,
        download_url: downloadUrl,
        proxy_url: proxyUrl,
      },
    },
    200,
    { "cache-control": "public, max-age=30" },
  );
});

// ===========================================================================
// GET /api/v1/measurements/:id/dump — public raw sensor CSV stream
// ===========================================================================
app.get(`${API_PREFIX}/measurements/:id/dump`, async (c) => {
  const id = c.req.param("id");
  if (!UUID_RE.test(id)) {
    return jsonError(c, 400, "invalid_id", "Measurement id must be a UUID.");
  }

  const row = (await c.env.DB.prepare(
    "SELECT raw_sensor_dump_r2_key FROM measurements WHERE id = ?",
  )
    .bind(id)
    .first()) as { raw_sensor_dump_r2_key: string } | null;
  if (!row) {
    return jsonError(c, 404, "not_found", `No measurement with id ${id}.`);
  }

  const object = await c.env.RAW_DUMPS.get(row.raw_sensor_dump_r2_key);
  if (!object) {
    return jsonError(c, 404, "dump_missing", "Raw sensor dump object is missing from storage.");
  }

  const headers = new Headers();
  headers.set("content-type", object.httpMetadata?.contentType ?? "text/csv");
  headers.set("etag", object.httpEtag);
  headers.set("content-disposition", `attachment; filename="gof-${id}.csv"`);
  headers.set("cache-control", "public, max-age=3600, immutable"); // append-only: content never changes
  headers.set("content-length", String(object.size));

  return new Response(object.body, { headers });
});

// ===========================================================================
// POST /api/v1/devices/register — append a device Keystore public key.
// Proof-of-possession: the request itself must be signed by that key.
// ===========================================================================
app.post(REGISTER_PATH, async (c) => {
  const authError = requireIngestToken(c);
  if (authError) return authError;

  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return jsonError(c, 400, "invalid_json", "Request body must be JSON.");
  }

  const parsed = deviceRegistrationSchema.safeParse(body);
  if (!parsed.success) {
    return jsonError(c, 400, "invalid_payload", "Registration failed schema validation.", parsed.error.flatten());
  }
  const p = parsed.data;

  // The submitted key must actually be a usable EC P-256 key.
  try {
    await importP256PublicKeyFromSpki(p.public_key_spki);
  } catch {
    return jsonError(c, 400, "invalid_public_key", "public_key_spki is not a valid EC P-256 SubjectPublicKeyInfo (base64 DER).");
  }

  const skewMs = numberVar(c.env.SIGNATURE_MAX_SKEW_MS, DEFAULT_SIGNATURE_SKEW_MS);
  if (Math.abs(Date.now() - p.signed_at) > skewMs) {
    return jsonError(c, 401, "signature_expired", `signed_at is outside the ±${skewMs / 1000}s window.`);
  }

  // Proof-of-possession: verify the signature against the submitted key itself.
  const spkiBytes = base64ToBytes(p.public_key_spki);
  const canonical = buildRegistrationCanonicalString({
    method: "POST",
    path: REGISTER_PATH,
    deviceId: p.device_id,
    publicKeySpkiSha256Hex: await sha256Hex(spkiBytes),
    signedAtMs: p.signed_at,
  });

  const possessionOk = await verifyDetachedEcdsaP256({
    publicKeySpkiBase64: p.public_key_spki,
    signatureBase64: p.signature,
    signatureFormat: p.signature_format,
    message: canonical,
  }).catch(() => false);
  if (!possessionOk) {
    return jsonError(c, 401, "invalid_signature", "Signature does not verify against the submitted public key.");
  }

  // Attestation chain is stored as a SHA-256 integrity anchor (full chain
  // validation against the Google attestation root is on the roadmap).
  const attestationSha256 = p.attestation_chain ? await sha256Hex(p.attestation_chain.join("\n")) : null;

  try {
    await c.env.DB.prepare(
      `INSERT INTO device_keys (device_id, key_version, public_key_spki, attestation_sha256)
       VALUES (?, ?, ?, ?)`,
    )
      .bind(p.device_id, p.key_version, p.public_key_spki, attestationSha256)
      .run();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("UNIQUE constraint failed") && msg.includes("device_keys")) {
      return jsonError(c, 409, "already_registered", `device_id/key_version (${p.device_id}, v${p.key_version}) is already registered.`);
    }
    throw err;
  }

  return c.json(
    {
      device_id: p.device_id,
      key_version: p.key_version,
      attestation_recorded: attestationSha256 !== null,
      registered_at: new Date().toISOString(),
      note: "Key rotation: append a new key_version. Prior keys remain valid for verifying historical measurements.",
    },
    201,
  );
});

// ===========================================================================
// Admin — append-only verification ledger + stats (ADMIN_TOKEN)
// ===========================================================================

app.post(`${API_PREFIX}/admin/verifications`, async (c) => {
  const authError = requireAdminToken(c);
  if (authError) return authError;

  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return jsonError(c, 400, "invalid_json", "Request body must be JSON.");
  }

  const parsed = verificationEventSchema.safeParse(body);
  if (!parsed.success) {
    return jsonError(c, 400, "invalid_payload", "Verification event failed schema validation.", parsed.error.flatten());
  }
  const p = parsed.data;

  const exists = await c.env.DB.prepare("SELECT 1 AS x FROM measurements WHERE id = ?")
    .bind(p.measurement_id)
    .first();
  if (!exists) {
    return jsonError(c, 404, "not_found", `No measurement with id ${p.measurement_id}.`);
  }

  const eventId = crypto.randomUUID();
  await c.env.DB.prepare(
    `INSERT INTO verification_events (id, measurement_id, decision, reason, decided_by)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(eventId, p.measurement_id, p.decision, p.reason ?? null, p.decided_by)
    .run();

  const latest = (await c.env.DB.prepare(
    `SELECT decision FROM verification_events
      WHERE measurement_id = ?
      ORDER BY created_at DESC, rowid DESC
      LIMIT 1`,
  )
    .bind(p.measurement_id)
    .first()) as { decision: string } | null;

  return c.json(
    {
      id: eventId,
      measurement_id: p.measurement_id,
      decision: p.decision,
      effective_status: latest?.decision ?? p.decision,
      note: "Appended to the immutable ledger. Nothing was overwritten.",
    },
    201,
  );
});

app.get(`${API_PREFIX}/admin/stats`, async (c) => {
  const authError = requireAdminToken(c);
  if (authError) return authError;

  const [total, byMode, byStatus] = await c.env.DB.batch([
    c.env.DB.prepare("SELECT COUNT(*) AS n FROM measurements"),
    c.env.DB.prepare("SELECT mode, COUNT(*) AS n FROM measurements GROUP BY mode ORDER BY n DESC"),
    c.env.DB.prepare(
      "SELECT effective_status AS status, COUNT(*) AS n FROM measurement_effective_status GROUP BY effective_status",
    ),
  ]);

  return c.json({
    totals: { measurements: (total.results?.[0] as { n: number } | undefined)?.n ?? 0 },
    by_mode: (byMode.results ?? []) as Array<{ mode: string; n: number }>,
    by_effective_status: (byStatus.results ?? []) as Array<{ status: string; n: number }>,
    generated_at: new Date().toISOString(),
  });
});

// ===========================================================================
// Service endpoints
// ===========================================================================

app.get(`${API_PREFIX}/health`, async (c) => {
  const pong = (await c.env.DB.prepare("SELECT 1 AS ok").first()) as { ok: number } | null;
  return c.json({
    status: pong?.ok === 1 ? "ok" : "degraded",
    database: pong?.ok === 1 ? "reachable" : "unreachable",
    protocol: "GOFv1",
    time: new Date().toISOString(),
  });
});

app.get("/", (c) =>
  c.json({
    name: "GlobeOrFlat API",
    description: "Append-only citizen-science API for Earth-curvature measurements.",
    protocol: "GOFv1",
    version: "1.0.0",
    license: "MIT",
    documentation: "https://github.com/AndrexTheDev/GlobeOrFlat#readme",
    endpoints: [
      "POST /api/v1/measurements/upload",
      "GET  /api/v1/measurements",
      "GET  /api/v1/measurements/:id",
      "GET  /api/v1/measurements/:id/dump",
      "POST /api/v1/devices/register",
      "POST /api/v1/admin/verifications   (admin)",
      "GET  /api/v1/admin/stats           (admin)",
      "GET  /api/v1/health",
    ],
  }),
);

app.notFound((c) => jsonError(c, 404, "not_found", "Unknown route. See GET / for the endpoint index."));

app.onError((err, c) => {
  console.error(`[globeorflat] unhandled error: ${err.stack ?? err}`);
  return jsonError(c, 500, "internal_error", "Unexpected server error. Include x-request-id in bug reports.");
});

export default app;
