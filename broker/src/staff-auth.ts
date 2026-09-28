// Edge gate for the staff hostnames (<slug>-admin.<zone>). This Worker is
// attached to them by a route, so every request passes here before it can
// reach the tunnel. The layers, in order:
//
//   1. library must exist and be active; remote staff access must be enabled
//      (a password set from the Koha panel). Default: closed.
//   2. optional IP allowlist (CIDRs) per library.
//   3. a valid signed session cookie lets the request through cheaply.
//   4. otherwise rate limit per IP + library, then HTTP Basic Auth checked
//      against a PBKDF2 hash. Success sets the session cookie.
//
// Koha's own staff login still applies after this; the gate keeps bots and
// password spraying away from Koha itself.

import type { Env, LibraryRow } from "./env";
import { now } from "./env";
import { fromBase64, hmacSign, hmacVerify, pbkdf2, timingSafeEqualStr } from "./crypto";
import { ipAllowed } from "./netaddr";

export const SESSION_COOKIE = "__Host-kei_staff";
export const SESSION_TTL_SECONDS = 12 * 3600;

export function parseBasicAuth(header: string | null): { user: string; pass: string } | null {
  const m = header?.match(/^Basic\s+([A-Za-z0-9+/=]+)$/i);
  if (!m?.[1]) return null;
  const raw = fromBase64(m[1]);
  if (!raw) return null;
  const decoded = new TextDecoder().decode(raw);
  const i = decoded.indexOf(":");
  if (i < 1) return null;
  return { user: decoded.slice(0, i), pass: decoded.slice(i + 1) };
}

export function getCookie(header: string | null, name: string): string | null {
  for (const part of (header ?? "").split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=");
  }
  return null;
}

function withoutCookie(header: string | null, name: string): string {
  return (header ?? "")
    .split(";")
    .map((p) => p.trim())
    .filter((p) => p && !p.startsWith(`${name}=`))
    .join("; ");
}

const sessionMessage = (host: string, libraryId: string, exp: number, version: number) =>
  `${host}|${libraryId}|${exp}|${version}`;

export async function makeSession(key: string, host: string, libraryId: string, version: number, at: number): Promise<string> {
  const exp = at + SESSION_TTL_SECONDS;
  return `${exp}.${version}.${await hmacSign(key, sessionMessage(host, libraryId, exp, version))}`;
}

// The credential version is part of the MAC, so changing the staff
// password invalidates every existing session.
export async function verifySession(
  key: string,
  value: string,
  host: string,
  libraryId: string,
  version: number,
  at: number,
): Promise<boolean> {
  const [expS, verS, mac] = value.split(".");
  if (!expS || !verS || !mac || !/^\d+$/.test(expS) || !/^\d+$/.test(verS)) return false;
  const exp = Number(expS);
  if (exp < at || Number(verS) !== version) return false;
  return hmacVerify(key, sessionMessage(host, libraryId, exp, version), mac);
}

export async function checkPassword(lib: Pick<LibraryRow, "staff_user" | "staff_pass_hash" | "staff_pass_salt" | "staff_pass_iter">, user: string, pass: string): Promise<boolean> {
  if (!lib.staff_user || !lib.staff_pass_hash || !lib.staff_pass_salt || !lib.staff_pass_iter) return false;
  const salt = fromBase64(lib.staff_pass_salt);
  if (!salt) return false;
  const [userOk, passOk] = await Promise.all([
    timingSafeEqualStr(user, lib.staff_user),
    pbkdf2(pass, salt, lib.staff_pass_iter).then((h) => timingSafeEqualStr(h, lib.staff_pass_hash!)),
  ]);
  return userOk && passOk;
}

function page(status: number, title: string, text: string, extra: Record<string, string> = {}): Response {
  const body = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title><body style="font-family:system-ui;max-width:36rem;margin:3rem auto;padding:0 1rem"><h1>${title}</h1><p>${text}</p>`;
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Robots-Tag": "noindex", ...extra },
  });
}

const challenge = () =>
  page(401, "Koha staff", "Sign in with the remote access user set in the Koha panel.", {
    "WWW-Authenticate": 'Basic realm="Koha staff", charset="UTF-8"',
  });

async function forward(request: Request, setCookie?: string): Promise<Response> {
  const headers = new Headers(request.headers);
  headers.delete("Authorization"); // the gate password never reaches Koha
  const cookie = withoutCookie(headers.get("Cookie"), SESSION_COOKIE);
  if (cookie) headers.set("Cookie", cookie);
  else headers.delete("Cookie");
  const upstream = await fetch(new Request(request, { headers, redirect: "manual" }));
  const res = new Response(upstream.body, upstream);
  res.headers.set("X-Robots-Tag", "noindex, nofollow");
  if (setCookie) res.headers.append("Set-Cookie", setCookie);
  return res;
}

export async function handleStaff(request: Request, env: Env, slug: string): Promise<Response> {
  const host = new URL(request.url).hostname;
  const lib = await env.DB.prepare(
    "SELECT * FROM libraries WHERE slug = ? AND status IN ('active', 'suspended')",
  )
    .bind(slug)
    .first<LibraryRow>();
  if (!lib) return page(404, "Not found", "There is no library at this address.");
  if (lib.status === "suspended") return page(503, "Temporarily unavailable", "This library is temporarily unavailable.");
  if (!lib.staff_pass_hash) {
    return page(403, "Remote staff access is off", "Turn it on in the Koha panel by setting a remote access password.");
  }

  const ip = request.headers.get("CF-Connecting-IP") ?? "";
  const cidrs: string[] = lib.staff_allow_cidrs ? JSON.parse(lib.staff_allow_cidrs) : [];
  if (cidrs.length > 0 && !ipAllowed(ip, cidrs)) {
    return page(403, "Access denied", "This network is not allowed to open the staff interface.");
  }

  const at = now();
  const session = getCookie(request.headers.get("Cookie"), SESSION_COOKIE);
  if (session && (await verifySession(env.STAFF_SESSION_KEY, session, host, lib.id, lib.staff_cred_version, at))) {
    return forward(request);
  }

  const { success } = await env.RL_STAFF.limit({ key: `${ip}|${lib.id}` });
  if (!success) return page(429, "Too many attempts", "Wait a minute and try again.", { "Retry-After": "60" });

  const creds = parseBasicAuth(request.headers.get("Authorization"));
  if (!creds || !(await checkPassword(lib, creds.user, creds.pass))) return challenge();

  const value = await makeSession(env.STAFF_SESSION_KEY, host, lib.id, lib.staff_cred_version, at);
  return forward(
    request,
    `${SESSION_COOKIE}=${value}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${SESSION_TTL_SECONDS}`,
  );
}
