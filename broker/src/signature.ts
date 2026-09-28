// Ed25519 request signatures from the Koha installer.
//
// At enrollment the installer creates a key pair with
//   openssl genpkey -algorithm ed25519
// and sends the raw 32-byte public key (base64). Every later request carries
// four headers and is signed over a canonical string:
//
//   KEI-SIG-v1\n<METHOD>\n<path?query>\n<unix seconds>\n<nonce>\n<sha256 hex of body>
//
// The broker checks, in this order: header format, clock skew, the library's
// stored key, the signature, and only then consumes the nonce (so an
// unauthenticated caller can't burn nonces). A reused nonce is a replay.
// scripts/kei-sign.sh is the reference signer.

import { fromBase64, sha256Hex } from "./crypto";

export const SIG_VERSION = "KEI-SIG-v1";
export const SIG_HEADERS = {
  library: "x-kei-library",
  timestamp: "x-kei-timestamp",
  nonce: "x-kei-nonce",
  signature: "x-kei-signature",
} as const;
export const MAX_SKEW_SECONDS = 300;
export const NONCE_TTL_SECONDS = 2 * MAX_SKEW_SECONDS;

const LIBRARY_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const NONCE_RE = /^[A-Za-z0-9_-]{16,64}$/;
const TIMESTAMP_RE = /^[0-9]{9,11}$/;

export function canonicalString(
  method: string,
  pathWithQuery: string,
  timestamp: string,
  nonce: string,
  bodySha256Hex: string,
): string {
  return [SIG_VERSION, method.toUpperCase(), pathWithQuery, timestamp, nonce, bodySha256Hex].join("\n");
}

export function isValidPublicKey(b64: string): boolean {
  return fromBase64(b64)?.length === 32;
}

export async function verifyEd25519(publicKeyB64: string, message: string, signatureB64: string): Promise<boolean> {
  const pub = fromBase64(publicKeyB64);
  const sig = fromBase64(signatureB64);
  if (!pub || pub.length !== 32 || !sig || sig.length !== 64) return false;
  try {
    const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, sig, new TextEncoder().encode(message));
  } catch {
    return false;
  }
}

export interface SignatureDeps {
  now: number;
  // Returns the library's base64 public key, or null when unknown / not allowed to sign.
  lookupKey(libraryId: string): Promise<string | null>;
  // Stores the nonce; returns false if it was already used.
  consumeNonce(libraryId: string, nonce: string, expiresAt: number): Promise<boolean>;
}

export type SignatureResult = { ok: true; libraryId: string } | { ok: false; status: 401; error: string };

export async function checkSignedRequest(
  method: string,
  url: URL,
  headers: Headers,
  body: ArrayBuffer,
  deps: SignatureDeps,
): Promise<SignatureResult> {
  const fail = (error: string): SignatureResult => ({ ok: false, status: 401, error });
  const libraryId = headers.get(SIG_HEADERS.library) ?? "";
  const timestamp = headers.get(SIG_HEADERS.timestamp) ?? "";
  const nonce = headers.get(SIG_HEADERS.nonce) ?? "";
  const signature = headers.get(SIG_HEADERS.signature) ?? "";

  if (!LIBRARY_ID_RE.test(libraryId) || !TIMESTAMP_RE.test(timestamp) || !NONCE_RE.test(nonce) || !signature) {
    return fail("missing or malformed signature headers");
  }
  if (Math.abs(deps.now - Number(timestamp)) > MAX_SKEW_SECONDS) {
    return fail("timestamp outside the allowed window (check the server clock)");
  }
  const publicKey = await deps.lookupKey(libraryId);
  if (!publicKey) return fail("invalid signature");

  const message = canonicalString(method, url.pathname + url.search, timestamp, nonce, await sha256Hex(body));
  if (!(await verifyEd25519(publicKey, message, signature))) return fail("invalid signature");

  if (!(await deps.consumeNonce(libraryId, nonce, deps.now + NONCE_TTL_SECONDS))) return fail("replayed request");
  return { ok: true, libraryId };
}
