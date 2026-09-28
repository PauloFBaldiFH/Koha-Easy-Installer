import { describe, expect, it } from "vitest";
import type { DnsRecord, IngressRule, Tunnel } from "../src/cloudflare";
import { hostnamesFor } from "../src/names";
import { NameCollisionError, provision, ProvisionState, recordComment, setSuspended, teardown, TunnelDnsApi } from "../src/provision-steps";

class FakeApi implements TunnelDnsApi {
  tunnels = new Map<string, Tunnel>();
  ingress = new Map<string, IngressRule[]>();
  records = new Map<string, DnsRecord>();
  calls: string[] = [];
  failOn = "";
  private n = 0;

  private hit(name: string) {
    this.calls.push(name);
    if (this.failOn === name) {
      this.failOn = "";
      throw new Error(`injected failure in ${name}`);
    }
  }
  async createTunnel(name: string) {
    this.hit("createTunnel");
    const t = { id: `00000000-0000-0000-0000-${String(++this.n).padStart(12, "0")}`, name, created_at: "" };
    this.tunnels.set(t.id, t);
    return t;
  }
  async findTunnelByName(name: string) {
    this.hit("findTunnelByName");
    return [...this.tunnels.values()].find((t) => t.name === name) ?? null;
  }
  async putTunnelIngress(id: string, ingress: IngressRule[]) {
    this.hit("putTunnelIngress");
    this.ingress.set(id, ingress);
  }
  async rotateTunnelSecret() {
    this.hit("rotateTunnelSecret");
  }
  async deleteTunnel(id: string) {
    this.hit("deleteTunnel");
    this.tunnels.delete(id);
  }
  async findDnsRecords(name: string) {
    this.hit("findDnsRecords");
    return [...this.records.values()].filter((r) => r.name === name);
  }
  async createCname(name: string, content: string, comment: string) {
    this.hit("createCname");
    const r = { id: `rec${++this.n}`, name, type: "CNAME", content, comment };
    this.records.set(r.id, r);
    return r;
  }
  async deleteDnsRecord(id: string) {
    this.hit("deleteDnsRecord");
    this.records.delete(id);
  }
}

const LIB = "0b6f8c3e-6a1d-4a53-9f55-2d8c9a4e7b10";
const names = hostnamesFor("palotina-pr", { NAME_PREFIX: "t-", STAFF_SUFFIX: "-admin", ZONE_NAME: "example.org" });
const noSave = async () => {};

describe("provisioning steps", () => {
  it("creates tunnel, ingress and two proxied CNAMEs", async () => {
    const api = new FakeApi();
    const s = await provision(api, LIB, names, {}, noSave);
    expect(api.tunnels.size).toBe(1);
    expect(api.ingress.get(s.tunnelId)).toEqual([
      { hostname: names.opac, service: "http://localhost:80" },
      { hostname: names.staff, service: "http://localhost:8080" },
      { service: "http_status:404" },
    ]);
    const recs = [...api.records.values()];
    expect(recs.map((r) => r.name).sort()).toEqual([names.opac, names.staff].sort());
    expect(recs.every((r) => r.content === `${s.tunnelId}.cfargotunnel.com` && r.comment === recordComment(LIB))).toBe(true);
  });

  it("resumes after a crash without creating duplicates", async () => {
    const api = new FakeApi();
    let saved: ProvisionState = {};
    api.failOn = "createCname";
    await expect(provision(api, LIB, names, {}, async (s) => void (saved = { ...s }))).rejects.toThrow();
    // Retry with lost state: the tunnel is adopted by name.
    await provision(api, LIB, names, {}, noSave);
    expect(api.tunnels.size).toBe(1);
    expect(api.records.size).toBe(2);
    // Retry with saved state is also a no-op on existing resources.
    await provision(api, LIB, names, saved, noSave);
    expect(api.tunnels.size).toBe(1);
    expect(api.records.size).toBe(2);
  });

  it("never overwrites a foreign DNS record", async () => {
    const api = new FakeApi();
    api.records.set("x", { id: "x", name: names.opac, type: "A", content: "203.0.113.9" });
    await expect(provision(api, LIB, names, {}, noSave)).rejects.toBeInstanceOf(NameCollisionError);
    expect(api.records.get("x")?.content).toBe("203.0.113.9");
  });

  it("tears down only what belongs to the library", async () => {
    const api = new FakeApi();
    const s = await provision(api, LIB, names, {}, noSave);
    api.records.set("other", { id: "other", name: "www.example.org", type: "CNAME", content: "elsewhere.example.net" });
    await teardown(api, LIB, names, {}); // no stored ids: found by name + ownership
    expect([...api.records.keys()]).toEqual(["other"]);
    expect(api.tunnels.has(s.tunnelId)).toBe(false);
  });

  it("suspends with a 503 ingress and restores", async () => {
    const api = new FakeApi();
    const s = await provision(api, LIB, names, {}, noSave);
    await setSuspended(api, s.tunnelId, names, true);
    expect(api.ingress.get(s.tunnelId)).toEqual([{ service: "http_status:503" }]);
    await setSuspended(api, s.tunnelId, names, false);
    expect(api.ingress.get(s.tunnelId)?.length).toBe(3);
  });
});
