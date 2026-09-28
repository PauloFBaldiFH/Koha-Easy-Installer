// In-memory fake of the Cloudflare API calls the broker makes (tunnels and
// DNS records), shared by the end-to-end test and the installer's bats test.
import assert from "node:assert/strict";

export function createFakeCloudflare() {
  const cf = { tunnels: new Map(), ingress: new Map(), records: new Map(), secrets: new Map(), n: 0 };
  const ok = (result, status = 200) => Response.json({ success: true, errors: [], result }, { status });
  const notFound = () => Response.json({ success: false, errors: [{ code: 1003, message: "not found" }], result: null }, { status: 404 });

  async function handle(req) {
    if (req.headers.get("authorization") !== "Bearer test-token") return Response.json({ success: false, errors: [{ code: 10000, message: "auth" }] }, { status: 403 });
    const u = new URL(req.url);
    const p = u.pathname.replace("/client/v4", "");
    const body = req.method === "GET" || req.method === "DELETE" ? null : await req.json();
    let m;
    if (p === "/accounts/acct/cfd_tunnel" && req.method === "POST") {
      assert.equal(body.config_src, "cloudflare");
      const t = { id: crypto.randomUUID(), name: body.name, created_at: new Date().toISOString() };
      cf.tunnels.set(t.id, t);
      return ok(t);
    }
    if (p === "/accounts/acct/cfd_tunnel" && req.method === "GET") {
      const name = u.searchParams.get("name");
      return ok([...cf.tunnels.values()].filter((t) => !name || t.name === name));
    }
    if ((m = p.match(/^\/accounts\/acct\/cfd_tunnel\/([^/]+)\/configurations$/)) && req.method === "PUT") {
      if (!cf.tunnels.has(m[1])) return notFound();
      cf.ingress.set(m[1], body.config.ingress);
      return ok({});
    }
    if ((m = p.match(/^\/accounts\/acct\/cfd_tunnel\/([^/]+)\/token$/))) {
      return cf.tunnels.has(m[1]) ? ok(`tunnel-token-for-${m[1]}-v${cf.secrets.get(m[1]) ?? 0}`) : notFound();
    }
    if ((m = p.match(/^\/accounts\/acct\/cfd_tunnel\/([^/]+)\/connections$/)) && req.method === "DELETE") return ok(null);
    if ((m = p.match(/^\/accounts\/acct\/cfd_tunnel\/([^/]+)$/))) {
      if (!cf.tunnels.has(m[1])) return notFound();
      if (req.method === "PATCH") {
        assert.ok(body.tunnel_secret);
        cf.secrets.set(m[1], (cf.secrets.get(m[1]) ?? 0) + 1);
        return ok(cf.tunnels.get(m[1]));
      }
      if (req.method === "DELETE") {
        cf.tunnels.delete(m[1]);
        cf.ingress.delete(m[1]); // the configuration goes with the tunnel
        return ok(null);
      }
    }
    if (p === "/zones/zone/dns_records" && req.method === "GET") {
      const name = u.searchParams.get("name");
      return ok([...cf.records.values()].filter((r) => !name || r.name === name), 200);
    }
    if (p === "/zones/zone/dns_records" && req.method === "POST") {
      assert.equal(body.type, "CNAME");
      assert.equal(body.proxied, true);
      const r = { id: `rec${++cf.n}`, created_on: new Date().toISOString(), ...body };
      cf.records.set(r.id, r);
      return ok(r);
    }
    if ((m = p.match(/^\/zones\/zone\/dns_records\/(.+)$/)) && req.method === "DELETE") {
      if (!cf.records.delete(m[1])) return notFound();
      return ok({ id: m[1] });
    }
    throw new Error(`fake API: unhandled ${req.method} ${p}`);
  }

  return { cf, handle };
}
