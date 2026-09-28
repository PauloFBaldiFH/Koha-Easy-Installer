import { CloudflareApi } from "./cloudflare";
import type { Env, LibraryRow } from "./env";
import { now } from "./env";

export async function audit(env: Env, actor: string, action: string, libraryId: string | null, detail?: unknown): Promise<void> {
  await env.DB.prepare("INSERT INTO audit_log (at, actor, action, library_id, detail) VALUES (?, ?, ?, ?, ?)")
    .bind(now(), actor, action, libraryId, detail === undefined ? null : JSON.stringify(detail))
    .run();
}

// A name is free when no live library uses it, it isn't held after a
// release, and no approved enrollment is waiting to claim it.
export async function slugAvailable(env: Env, slug: string, exceptUserCode = ""): Promise<boolean> {
  const t = now();
  const row = await env.DB.prepare(
    `SELECT
       (SELECT COUNT(*) FROM libraries WHERE slug = ?1 AND status NOT IN ('deleted', 'failed')) +
       (SELECT COUNT(*) FROM reserved_names WHERE slug = ?1 AND (until IS NULL OR until > ?2)) +
       (SELECT COUNT(*) FROM enrollments WHERE approved_slug = ?1 AND status = 'approved' AND expires_at > ?2 AND user_code <> ?3)
     AS taken`,
  )
    .bind(slug, t, exceptUserCode)
    .first<{ taken: number }>();
  return (row?.taken ?? 1) === 0;
}

export async function getLibrary(env: Env, id: string): Promise<LibraryRow | null> {
  return env.DB.prepare("SELECT * FROM libraries WHERE id = ?").bind(id).first<LibraryRow>();
}

export function provisioner(env: Env, libraryId: string) {
  return env.PROVISIONER.get(env.PROVISIONER.idFromName(libraryId));
}

export function cfApi(env: Env): CloudflareApi {
  return new CloudflareApi({
    token: env.CF_API_TOKEN,
    accountId: env.CF_ACCOUNT_ID,
    zoneId: env.CF_ZONE_ID,
    base: env.CF_API_BASE || undefined,
  });
}
