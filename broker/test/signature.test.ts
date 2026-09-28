import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { checkSignedRequest, isValidPublicKey, SignatureDeps } from "../src/signature";

// Keys and signatures come from scripts/kei-sign.sh (openssl), exactly as
// the installer will produce them, and are verified by the Worker code.
const SCRIPT = join(__dirname, "..", "scripts", "kei-sign.sh");
const LIB = "0b6f8c3e-6a1d-4a53-9f55-2d8c9a4e7b10";
let dir: string;
let key: string;
let pub: string;

function sign(method: string, path: string, body?: string): Headers {
  let bodyFile: string[] = [];
  if (body !== undefined) {
    const f = join(dir, `body-${Math.random()}`);
    writeFileSync(f, body);
    bodyFile = [f];
  }
  const out = execFileSync(SCRIPT, ["headers", key, LIB, method, path, ...bodyFile], { encoding: "utf8" });
  const h = new Headers();
  for (const line of out.trim().split("\n")) {
    const i = line.indexOf(": ");
    h.set(line.slice(0, i), line.slice(i + 2));
  }
  return h;
}

function deps(overrides: Partial<SignatureDeps> = {}): SignatureDeps & { nonces: Set<string> } {
  const nonces = new Set<string>();
  return {
    nonces,
    now: Math.floor(Date.now() / 1000),
    lookupKey: async (id) => (id === LIB ? pub : null),
    consumeNonce: async (id, n) => {
      const k = `${id}|${n}`;
      if (nonces.has(k)) return false;
      nonces.add(k);
      return true;
    },
    ...overrides,
  };
}

const enc = (s: string) => new TextEncoder().encode(s).buffer as ArrayBuffer;
const url = (p: string) => new URL(`https://koha-broker.example.org${p}`);

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), "kei-sig-"));
  key = join(dir, "broker.key");
  execFileSync(SCRIPT, ["keygen", key]);
  pub = execFileSync(SCRIPT, ["pubkey", key], { encoding: "utf8" }).trim();
});
afterAll(() => rmSync(dir, { recursive: true, force: true }));

describe("Ed25519 request signatures", () => {
  it("accepts the public key format produced by openssl", () => {
    expect(isValidPublicKey(pub)).toBe(true);
    expect(isValidPublicKey("abc")).toBe(false);
  });

  it("verifies a signed POST with a body and query string", async () => {
    const body = '{"koha_version":"24.11"}';
    const h = sign("POST", "/v1/heartbeat?x=1", body);
    const res = await checkSignedRequest("POST", url("/v1/heartbeat?x=1"), h, enc(body), deps());
    expect(res).toEqual({ ok: true, libraryId: LIB });
  });

  it("verifies a signed GET without a body", async () => {
    const h = sign("GET", "/v1/library");
    const res = await checkSignedRequest("GET", url("/v1/library"), h, new ArrayBuffer(0), deps());
    expect(res.ok).toBe(true);
  });

  it("rejects a tampered body, path or method", async () => {
    const h = sign("POST", "/v1/heartbeat", '{"a":1}');
    expect((await checkSignedRequest("POST", url("/v1/heartbeat"), h, enc('{"a":2}'), deps())).ok).toBe(false);
    expect((await checkSignedRequest("POST", url("/v1/rotate"), h, enc('{"a":1}'), deps())).ok).toBe(false);
    expect((await checkSignedRequest("PUT", url("/v1/heartbeat"), h, enc('{"a":1}'), deps())).ok).toBe(false);
  });

  it("rejects a replayed nonce", async () => {
    const d = deps();
    const h = sign("GET", "/v1/library");
    expect((await checkSignedRequest("GET", url("/v1/library"), h, new ArrayBuffer(0), d)).ok).toBe(true);
    const again = await checkSignedRequest("GET", url("/v1/library"), h, new ArrayBuffer(0), d);
    expect(again).toMatchObject({ ok: false, error: "replayed request" });
  });

  it("rejects old timestamps", async () => {
    const h = sign("GET", "/v1/library");
    const res = await checkSignedRequest("GET", url("/v1/library"), h, new ArrayBuffer(0), deps({ now: Math.floor(Date.now() / 1000) + 600 }));
    expect(res.ok).toBe(false);
  });

  it("rejects a signature from another key and does not burn the nonce", async () => {
    const otherKey = join(dir, "other.key");
    execFileSync(SCRIPT, ["keygen", otherKey]);
    const otherPub = execFileSync(SCRIPT, ["pubkey", otherKey], { encoding: "utf8" }).trim();
    const d = deps({ lookupKey: async () => otherPub });
    const h = sign("GET", "/v1/library");
    expect((await checkSignedRequest("GET", url("/v1/library"), h, new ArrayBuffer(0), d)).ok).toBe(false);
    expect(d.nonces.size).toBe(0);
  });

  it("rejects unknown libraries and malformed headers", async () => {
    const h = sign("GET", "/v1/library");
    expect((await checkSignedRequest("GET", url("/v1/library"), h, new ArrayBuffer(0), deps({ lookupKey: async () => null }))).ok).toBe(false);
    h.set("x-kei-nonce", "short");
    expect((await checkSignedRequest("GET", url("/v1/library"), h, new ArrayBuffer(0), deps())).ok).toBe(false);
  });
});
