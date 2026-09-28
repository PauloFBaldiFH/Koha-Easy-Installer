// Runs the bundled broker in local workerd (Miniflare) on 127.0.0.1 with the
// fake Cloudflare API, for the installer's test battery
// (tests/free_address.bats). Needs `npm install` and a bundle in
// .wrangler/e2e-build (npm run build:local).
//
//   node test/e2e/serve.mjs STATE_DIR
// Writes STATE_DIR/ready with two lines: the broker URL and the URL of a
// small inspection server (GET /state: tunnels, ingress and DNS records of
// the fake Cloudflare API, as JSON). Stops on SIGTERM.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare4";
import { createFakeCloudflare } from "./fake-cloudflare.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const stateDir = process.argv[2];
if (!stateDir) throw new Error("usage: serve.mjs STATE_DIR");
mkdirSync(stateDir, { recursive: true });

const { cf, handle } = createFakeCloudflare();

const mf = new Miniflare({
  modules: true,
  scriptPath: join(ROOT, ".wrangler", "e2e-build", "index.js"),
  compatibilityDate: "2026-07-01",
  host: "127.0.0.1",
  port: 0,
  bindings: {
    CF_API_TOKEN: "test-token",
    ADMIN_TOKEN: "a".repeat(40),
    STAFF_SESSION_KEY: "s".repeat(40),
    CF_ACCOUNT_ID: "acct",
    CF_ZONE_ID: "zone",
    ZONE_NAME: "example.org",
    BROKER_HOST: "127.0.0.1",
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
    RL_DEVICE: { namespace_id: "1", simple: { limit: 100, period: 60 } },
    RL_API: { namespace_id: "2", simple: { limit: 1000, period: 60 } },
    RL_STAFF: { namespace_id: "3", simple: { limit: 100, period: 60 } },
  },
  outboundService: (req) => {
    const u = new URL(req.url);
    if (u.hostname === "api.cloudflare.com") return handle(req);
    // The staff gate forwards to the tunnel: a fake Koha answers.
    if (u.hostname.endsWith("-admin.example.org")) {
      return Response.json({ koha: true, authorization: req.headers.get("authorization") });
    }
    throw new Error(`unexpected outbound fetch ${req.url}`);
  },
});

const url = await mf.ready;
const db = await mf.getD1Database("DB");
const sql = readFileSync(join(ROOT, "migrations", "0001_init.sql"), "utf8").replace(/--[^\n]*/g, "");
for (const stmt of sql.split(";").map((s) => s.trim()).filter(Boolean)) await db.prepare(stmt).run();

const inspect = createServer((req, res) => {
  const state = {
    tunnels: [...cf.tunnels.values()],
    ingress: Object.fromEntries(cf.ingress),
    records: [...cf.records.values()],
    rotations: Object.fromEntries(cf.secrets),
  };
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(state));
});
await new Promise((r) => inspect.listen(0, "127.0.0.1", r));

const broker = url.toString().replace(/\/$/, "");
writeFileSync(join(stateDir, "ready"), `${broker}\nhttp://127.0.0.1:${inspect.address().port}\n`);

const stop = async () => {
  inspect.close();
  await mf.dispose();
  process.exit(0);
};
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
