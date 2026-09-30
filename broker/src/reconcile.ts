// Hourly housekeeping. Compares what Cloudflare has with what the database
// says and removes leftovers the broker created (tunnels named kei-lib-<id>,
// CNAMEs commented kei:lib:<id>) whose library is gone or failed. Records
// without the broker's comment are never touched, so the zone's other DNS
// entries are safe.

import { audit, cfApi } from "./db";
import type { Env, LibraryStatus } from "./env";
import { now } from "./env";
import { LIBRARY_ID_FROM_COMMENT, LIBRARY_ID_FROM_TUNNEL } from "./provision-steps";

const GRACE_SECONDS = 3600;

const olderThanGrace = (iso: string | undefined, t: number) => !iso || Date.parse(iso) / 1000 < t - GRACE_SECONDS;

export async function reconcile(env: Env): Promise<void> {
  const api = cfApi(env);
  const t = now();
  const rows = await env.DB.prepare("SELECT id, status FROM libraries WHERE status NOT IN ('deleted', 'failed')").all<{
    id: string;
    status: LibraryStatus;
  }>();
  const live = new Set(rows.results.map((r) => r.id));
  const removed = { records: 0, tunnels: 0 };

  for (const r of await api.listDnsRecords()) {
    const id = LIBRARY_ID_FROM_COMMENT.exec(r.comment ?? "")?.[1];
    if (id && !live.has(id) && olderThanGrace(r.created_on, t)) {
      await api.deleteDnsRecord(r.id);
      removed.records++;
    }
  }
  for (const tun of await api.listTunnels()) {
    const id = LIBRARY_ID_FROM_TUNNEL.exec(tun.name)?.[1];
    if (id && !live.has(id) && olderThanGrace(tun.created_at, t)) {
      await api.deleteTunnel(tun.id);
      removed.tunnels++;
    }
  }

  await env.DB.batch([
    env.DB.prepare("DELETE FROM nonces WHERE expires_at < ?").bind(t),
    env.DB.prepare("DELETE FROM enrollments WHERE status <> 'consumed' AND expires_at < ?").bind(t - 7 * 86400),
    env.DB.prepare("DELETE FROM reserved_names WHERE until IS NOT NULL AND until < ?").bind(t),
    env.DB.prepare("DELETE FROM audit_log WHERE at < ?").bind(t - 365 * 86400),
  ]);
  if (removed.records || removed.tunnels) await audit(env, "system", "reconcile.cleanup", null, removed);
}
