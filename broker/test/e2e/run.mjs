// End-to-end test of the bundled Worker in Miniflare (local workerd) with a
// real D1, Durable Object, Queue and rate limiters. Every outbound fetch is
// answered in-process: api.cloudflare.com by a fake Cloudflare API, and the
// staff hostnames by a fake Koha that echoes what it received.
// Run with: npm run test:e2e
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare4";
import { createFakeCloudflare } from "./fake-cloudflare.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SIGN = join(ROOT, "scripts", "kei-sign.sh");
const ZONE = "example.org";
const BROKER = `https://broker.${ZONE}`;
const ADMIN = { Authorization: `Bearer ${"a".repeat(40)}` };

const { cf, handle: fakeCloudflare } = createFakeCloudflare();

async function outbound(req) {
  const u = new URL(req.url);
  if (u.hostname === "api.cloudflare.com") return fakeCloudflare(req);
  if (u.hostname.endsWith(`-admin.${ZONE}`)) {
    return Response.json({ koha: true, path: u.pathname, authorization: req.headers.get("authorization"), cookie: req.headers.get("cookie") });
  }
  throw new Error(`unexpected outbound fetch ${req.url}`);
}

// ---------------- helpers ----------------
const tmp = mkdtempSync(join(tmpdir(), "kei-e2e-"));
const key = join(tmp, "broker.key");
execFileSync(SIGN, ["keygen", key]);
const publicKey = execFileSync(SIGN, ["pubkey", key], { encoding: "utf8" }).trim();
let libraryId = "";

function signedHeaders(method, path, body) {
  const args = ["headers", key, libraryId, method, path];
  if (body !== undefined) {
    const f = join(tmp, `body-${Math.random()}`);
    writeFileSync(f, body);
    args.push(f);
  }
  const h = {};
  for (const line of execFileSync(SIGN, args, { encoding: "utf8" }).trim().split("\n")) {
    const i = line.indexOf(": ");
    h[line.slice(0, i)] = line.slice(i + 2);
  }
  return h;
}

async function call(mf, method, path, { body, headers = {}, signed = false, host = BROKER } = {}) {
  const text = body === undefined ? undefined : JSON.stringify(body);
  const h = { ...headers, ...(signed ? signedHeaders(method, path, text) : {}) };
  if (text !== undefined) h["Content-Type"] = "application/json";
  const res = await mf.dispatchFetch(`${host}${path}`, { method, headers: h, body: text });
  const type = res.headers.get("content-type") ?? "";
  return { status: res.status, headers: res.headers, data: type.includes("json") ? await res.json() : await res.text() };
}

async function waitJob(mf, jobId) {
  for (let i = 0; i < 100; i++) {
    const r = await call(mf, "GET", `/v1/jobs/${jobId}`, { signed: true });
    assert.equal(r.status, 200, JSON.stringify(r.data));
    if (r.data.state === "done" || r.data.state === "failed") return r.data;
    await new Promise((res) => setTimeout(res, 200));
  }
  throw new Error("job did not finish");
}

let step = 0;
const check = (name) => console.log(`  ok ${++step} - ${name}`);

// ---------------- run ----------------
const mf = new Miniflare({
  modules: true,
  scriptPath: join(ROOT, ".wrangler", "e2e-build", "index.js"),
  compatibilityDate: "2026-07-01",
  bindings: {
    CF_API_TOKEN: "test-token",
    ADMIN_TOKEN: "a".repeat(40),
    STAFF_SESSION_KEY: "s".repeat(40),
    CF_ACCOUNT_ID: "acct",
    CF_ZONE_ID: "zone",
    ZONE_NAME: ZONE,
    BROKER_HOST: `broker.${ZONE}`,
    NAME_PREFIX: "t-",
    STAFF_SUFFIX: "-admin",
    AUTO_APPROVE: "false",
    PBKDF2_ITERATIONS: "1000",
    MAX_LIBRARIES_PER_DAY: "20",
  },
  d1Databases: { DB: "kei-broker" },
  durableObjects: { PROVISIONER: { className: "Provisioner", useSQLite: true } },
  queueProducers: { PROVISION_QUEUE: { queueName: "kei-provision" } },
  queueConsumers: { "kei-provision": { maxBatchSize: 1, maxBatchTimeout: 1, maxRetries: 10 } },
  ratelimits: {
    RL_DEVICE: { namespace_id: "1", simple: { limit: 3, period: 60 } },
    RL_API: { namespace_id: "2", simple: { limit: 1000, period: 60 } },
    RL_STAFF: { namespace_id: "3", simple: { limit: 20, period: 60 } },
  },
  outboundService: outbound,
});

try {
  const db = await mf.getD1Database("DB");
  const sql = readFileSync(join(ROOT, "migrations", "0001_init.sql"), "utf8").replace(/--[^\n]*/g, "");
  for (const stmt of sql.split(";").map((s) => s.trim()).filter(Boolean)) await db.prepare(stmt).run();
  check("schema applied");

  // Foreign record that must survive everything.
  cf.records.set("foreign", { id: "foreign", name: `www.${ZONE}`, type: "CNAME", content: "elsewhere.example.net", created_on: "2020-01-01T00:00:00Z" });

  // Enrollment
  let r = await call(mf, "POST", "/v1/device/start", {
    body: { institution_name: "Biblioteca Pública Municipal", contact_email: "biblioteca@palotina.pr.gov.br", requested_name: "Palotina PR" },
  });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  const { device_code, user_code, suggested_slug, verification_uri } = r.data;
  assert.equal(suggested_slug, "palotina-pr");
  assert.match(verification_uri, /\/join\?c=[A-Z]{4}-[A-Z]{4}$/);
  check("device/start returns codes and a suggested name");

  r = await call(mf, "POST", "/v1/device/poll", { body: { device_code } });
  assert.equal(r.data.status, "pending");
  r = await call(mf, "GET", `/join?c=${user_code}`);
  assert.match(r.data, /waiting for review/);
  check("request is pending until an admin decides");

  r = await call(mf, "POST", "/v1/enroll", { body: { device_code, public_key: publicKey } });
  assert.equal(r.status, 409);
  check("enroll refused before approval");

  r = await call(mf, "GET", "/admin/enrollments");
  assert.equal(r.status, 401);
  r = await call(mf, "POST", `/admin/enrollments/${user_code}/approve`, { headers: ADMIN, body: { slug: "caixa-login" } });
  assert.equal(r.status, 400);
  r = await call(mf, "POST", `/admin/enrollments/${user_code}/approve`, { headers: ADMIN, body: {} });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  assert.equal(r.data.hostnames.opac, `t-palotina-pr.${ZONE}`);
  check("admin auth required; phishing name rejected; approval works");

  r = await call(mf, "POST", "/v1/enroll", { body: { device_code, public_key: publicKey } });
  assert.equal(r.status, 202, JSON.stringify(r.data));
  libraryId = r.data.library_id;
  const provisionJob = r.data.job_id;
  r = await call(mf, "POST", "/v1/enroll", { body: { device_code, public_key: publicKey } });
  assert.equal(r.status, 409);
  check("enroll accepted once; the device code cannot be reused");

  const job = await waitJob(mf, provisionJob);
  assert.equal(job.state, "done", JSON.stringify(job));
  assert.equal(job.library_status, "active");
  assert.equal(cf.tunnels.size, 1);
  const [tunnel] = cf.tunnels.values();
  assert.equal(tunnel.name, `kei-lib-${libraryId}`);
  assert.deepEqual(cf.ingress.get(tunnel.id), [
    { hostname: `t-palotina-pr.${ZONE}`, service: "http://localhost:80" },
    { hostname: `t-palotina-pr-admin.${ZONE}`, service: "http://localhost:8080" },
    { service: "http_status:404" },
  ]);
  const ours = [...cf.records.values()].filter((x) => x.comment === `kei:lib:${libraryId}`);
  assert.equal(ours.length, 2);
  assert.ok(ours.every((x) => x.content === `${tunnel.id}.cfargotunnel.com`));
  check("queue + Durable Object provisioned tunnel, ingress and two CNAMEs");

  r = await call(mf, "GET", "/v1/tunnel-token", { signed: true });
  assert.equal(r.data.tunnel_token, `tunnel-token-for-${tunnel.id}-v0`);
  check("signed request returns the tunnel token");

  // Replay: same headers twice.
  const h = signedHeaders("GET", "/v1/library");
  r = await call(mf, "GET", "/v1/library", { headers: h });
  assert.equal(r.status, 200);
  r = await call(mf, "GET", "/v1/library", { headers: h });
  assert.equal(r.status, 401);
  assert.equal(r.data.error, "replayed request");
  r = await call(mf, "GET", "/v1/library", { headers: { ...signedHeaders("GET", "/v1/library"), "X-KEI-Signature": h["X-KEI-Signature"] } });
  assert.equal(r.status, 401);
  check("replayed and forged signatures are rejected");

  // Staff edge gate
  const STAFF = `https://t-palotina-pr-admin.${ZONE}`;
  r = await call(mf, "GET", "/cgi-bin/koha/mainpage.pl", { host: STAFF });
  assert.equal(r.status, 403);
  assert.match(r.data, /Remote staff access is off/);
  check("staff hostname is closed until a password is set");

  r = await call(mf, "PUT", "/v1/staff-credentials", { signed: true, body: { username: "biblioteca", password: "short" } });
  assert.equal(r.status, 400);
  r = await call(mf, "PUT", "/v1/staff-credentials", { signed: true, body: { username: "biblioteca", password: "uma senha bem longa" } });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  check("staff credentials set with a signed request");

  r = await call(mf, "GET", "/cgi-bin/koha/mainpage.pl", { host: STAFF });
  assert.equal(r.status, 401);
  assert.match(r.headers.get("www-authenticate"), /^Basic /);
  r = await call(mf, "GET", "/cgi-bin/koha/mainpage.pl", { host: STAFF, headers: { Authorization: `Basic ${btoa("biblioteca:errada")}` } });
  assert.equal(r.status, 401);
  r = await call(mf, "GET", "/cgi-bin/koha/mainpage.pl", {
    host: STAFF,
    headers: { Authorization: `Basic ${btoa("biblioteca:uma senha bem longa")}`, Cookie: "KOHA_SESSION=abc" },
  });
  assert.equal(r.status, 200);
  assert.equal(r.data.koha, true);
  assert.equal(r.data.authorization, null, "gate password must not reach Koha");
  assert.equal(r.data.cookie, "KOHA_SESSION=abc");
  const setCookie = r.headers.get("set-cookie");
  assert.match(setCookie, /^__Host-kei_staff=.*; Secure; HttpOnly; SameSite=Lax/);
  const session = setCookie.split(";")[0];
  r = await call(mf, "GET", "/intranet-tmpl/x.css", { host: STAFF, headers: { Cookie: `${session}; KOHA_SESSION=abc` } });
  assert.equal(r.status, 200);
  assert.equal(r.data.cookie, "KOHA_SESSION=abc", "gate cookie must not reach Koha");
  check("Basic Auth challenge, wrong password, success, session cookie; gate secrets stripped");

  r = await call(mf, "PUT", "/v1/staff-credentials", {
    signed: true,
    body: { username: "biblioteca", password: "outra senha bem longa", allow_cidrs: ["200.10.0.0/16"] },
  });
  assert.equal(r.status, 200);
  r = await call(mf, "GET", "/", { host: STAFF, headers: { Cookie: session, "CF-Connecting-IP": "200.10.3.4" } });
  assert.equal(r.status, 401, "password change must invalidate sessions");
  r = await call(mf, "GET", "/", {
    host: STAFF,
    headers: { Authorization: `Basic ${btoa("biblioteca:outra senha bem longa")}`, "CF-Connecting-IP": "8.8.8.8" },
  });
  assert.equal(r.status, 403);
  r = await call(mf, "GET", "/", {
    host: STAFF,
    headers: { Authorization: `Basic ${btoa("biblioteca:outra senha bem longa")}`, "CF-Connecting-IP": "200.10.3.4" },
  });
  assert.equal(r.status, 200);
  check("password change invalidates sessions; IP allowlist enforced");

  let limited = false;
  for (let i = 0; i < 25 && !limited; i++) {
    r = await call(mf, "GET", "/", { host: STAFF, headers: { Authorization: `Basic ${btoa("x:y")}`, "CF-Connecting-IP": "200.10.9.9" } });
    limited = r.status === 429;
  }
  assert.ok(limited);
  check("staff login attempts are rate limited");

  // Rotation, suspension
  r = await call(mf, "POST", "/v1/rotate", { signed: true, body: {} });
  assert.equal(r.status, 200);
  r = await call(mf, "GET", "/v1/tunnel-token", { signed: true });
  assert.equal(r.data.tunnel_token, `tunnel-token-for-${tunnel.id}-v1`);
  check("tunnel token rotation");

  r = await call(mf, "POST", `/admin/libraries/${libraryId}/suspend`, { headers: ADMIN });
  assert.equal(r.status, 200);
  assert.deepEqual(cf.ingress.get(tunnel.id), [{ service: "http_status:503" }]);
  r = await call(mf, "GET", "/", { host: STAFF, headers: { Authorization: `Basic ${btoa("biblioteca:outra senha bem longa")}`, "CF-Connecting-IP": "200.10.3.4" } });
  assert.equal(r.status, 503);
  r = await call(mf, "POST", `/admin/libraries/${libraryId}/restore`, { headers: ADMIN });
  assert.equal(r.status, 200);
  assert.equal(cf.ingress.get(tunnel.id).length, 3);
  check("suspend switches the tunnel to 503 and restore brings it back");

  // A second request for the same name is refused while it is taken.
  r = await call(mf, "POST", "/v1/device/start", { body: { institution_name: "Outra", contact_email: "x@palotina.pr.gov.br", requested_name: "palotina-pr" } });
  r = await call(mf, "POST", `/admin/enrollments/${r.data.user_code}/approve`, { headers: ADMIN, body: {} });
  assert.equal(r.status, 409);
  check("a name in use cannot be approved twice");

  // Reconciliation removes an orphan the broker created, never foreign records.
  const orphanLib = crypto.randomUUID();
  cf.records.set("orphan", { id: "orphan", name: `t-old.${ZONE}`, type: "CNAME", content: "x.cfargotunnel.com", comment: `kei:lib:${orphanLib}`, created_on: "2020-01-01T00:00:00Z" });
  const worker = await mf.getWorker();
  await worker.scheduled({ cron: "17 * * * *" });
  assert.ok(!cf.records.has("orphan"));
  assert.ok(cf.records.has("foreign"));
  assert.equal(cf.tunnels.size, 1);
  check("reconciliation removes orphans and keeps foreign and live records");

  // Removal
  r = await call(mf, "DELETE", "/v1/library", { signed: true });
  assert.equal(r.status, 202, JSON.stringify(r.data));
  const del = r.data.job_id;
  for (let i = 0; i < 100; i++) {
    const row = await db.prepare("SELECT state FROM jobs WHERE id = ?").bind(del).first();
    if (row.state === "done" || row.state === "failed") break;
    await new Promise((res) => setTimeout(res, 200));
  }
  assert.equal((await db.prepare("SELECT state FROM jobs WHERE id = ?").bind(del).first()).state, "done");
  assert.equal(cf.tunnels.size, 0);
  assert.deepEqual([...cf.records.keys()], ["foreign"]);
  const held = await db.prepare("SELECT until FROM reserved_names WHERE slug = 'palotina-pr'").first();
  assert.ok(held && held.until > Date.now() / 1000 + 170 * 86400);
  r = await call(mf, "GET", "/v1/library", { signed: true });
  assert.equal(r.status, 401);
  check("removal deletes tunnel and records, holds the name, and revokes the key");

  console.log(`\n${step} checks passed`);
} finally {
  await mf.dispose();
  rmSync(tmp, { recursive: true, force: true });
}
