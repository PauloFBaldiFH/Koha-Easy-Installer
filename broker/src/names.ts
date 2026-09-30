// Subdomain name policy. Names are flat labels under the zone (free
// Universal SSL covers only one level): <prefix><slug>.<zone> for the OPAC
// and <prefix><slug><staffSuffix>.<zone> for the staff interface.

// Labels that must never be handed to a library.
export const RESERVED = new Set([
  "www", "api", "app", "admin", "administrator", "root", "mail", "email", "smtp", "imap", "pop", "mx",
  "ns", "ns1", "ns2", "dns", "ftp", "sftp", "ssh", "vpn", "cdn", "static", "assets", "img", "status",
  "join", "broker", "koha-broker", "auth", "sso", "oauth", "id", "account", "accounts", "billing",
  "support", "help", "docs", "blog", "news", "abuse", "security", "postmaster", "hostmaster",
  "webmaster", "test", "staging", "dev", "demo", "koha", "opac", "staff", "intranet",
]);

// Substrings typical of phishing names. Matched after confusable
// normalization, so "l0gin" and "rnicrosoft" are caught too. An admin can
// approve such a name explicitly with force=true after a manual review.
export const BLOCKED_SUBSTRINGS = [
  "login", "logon", "signin", "secure", "verify", "verific", "account", "password", "senha", "wallet",
  "update", "pix", "boleto", "banco", "bank", "caixa", "itau", "bradesco", "santander", "nubank",
  "paypal", "receita", "inss", "detran", "govbr", "google", "gmail", "microsoft", "outlook", "office365",
  "apple", "icloud", "facebook", "instagram", "whatsapp", "cloudflare",
];

// Returns the look-alike readings of a name ("1" reads as both "i" and "l").
export function normalizeConfusables(s: string): string[] {
  const base = s
    .toLowerCase()
    .replace(/rn/g, "m")
    .replace(/vv/g, "w")
    .replace(/0/g, "o")
    .replace(/3/g, "e")
    .replace(/4|@/g, "a")
    .replace(/5|\$/g, "s")
    .replace(/7/g, "t")
    .replace(/8/g, "b")
    .replace(/-/g, "");
  return [base.replace(/[1|!]/g, "i"), base.replace(/[1|!]/g, "l")];
}

export function slugify(input: string): string {
  return input
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/-{2,}/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function maxSlugLength(prefix: string, staffSuffix: string): number {
  return 63 - prefix.length - staffSuffix.length;
}

export type SlugCheck = { ok: true } | { ok: false; reason: string };

export function validateSlug(
  slug: string,
  opts: { prefix: string; staffSuffix: string; allowBlocked?: boolean },
): SlugCheck {
  const max = maxSlugLength(opts.prefix, opts.staffSuffix);
  if (slug.length < 3 || slug.length > max) return { ok: false, reason: `length must be 3 to ${max} characters` };
  if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(slug)) {
    return { ok: false, reason: "use only a-z, 0-9 and inner hyphens" };
  }
  if (slug.includes("--")) return { ok: false, reason: "double hyphens are not allowed" };
  if (RESERVED.has(slug)) return { ok: false, reason: "reserved name" };
  if (opts.staffSuffix && slug.endsWith(opts.staffSuffix)) return { ok: false, reason: "name ends with the staff suffix" };
  if (!opts.allowBlocked) {
    const readings = normalizeConfusables(slug);
    const hit = BLOCKED_SUBSTRINGS.find((w) => readings.some((r) => r.includes(w)));
    if (hit) return { ok: false, reason: `contains a blocked word (${hit}); needs manual approval` };
  }
  return { ok: true };
}

// Names tried, in order, for an automatic approval: the requested name, then
// the institution name, each also with -2 ... -9 when taken. Truncated to
// the room left by the prefix and the staff suffix.
export function slugCandidates(requested: string, institution: string, max: number): string[] {
  const out: string[] = [];
  for (const raw of [requested, institution]) {
    const base = slugify(raw).slice(0, max).replace(/-+$/, "");
    if (!base) continue;
    for (let n = 1; n <= 9; n++) {
      const tail = n === 1 ? "" : `-${n}`;
      const c = base.slice(0, max - tail.length).replace(/-+$/, "") + tail;
      if (!out.includes(c)) out.push(c);
    }
  }
  return out;
}

export interface Hostnames {
  opac: string;
  staff: string;
}

export function hostnamesFor(slug: string, cfg: { NAME_PREFIX: string; STAFF_SUFFIX: string; ZONE_NAME: string }): Hostnames {
  return {
    opac: `${cfg.NAME_PREFIX}${slug}.${cfg.ZONE_NAME}`,
    staff: `${cfg.NAME_PREFIX}${slug}${cfg.STAFF_SUFFIX}.${cfg.ZONE_NAME}`,
  };
}

// Inverse of hostnamesFor for the staff hostname; null when it isn't one.
export function slugFromStaffHost(
  host: string,
  cfg: { NAME_PREFIX: string; STAFF_SUFFIX: string; ZONE_NAME: string },
): string | null {
  const tail = `${cfg.STAFF_SUFFIX}.${cfg.ZONE_NAME}`;
  const h = host.toLowerCase();
  if (!cfg.STAFF_SUFFIX || !h.endsWith(tail) || !h.startsWith(cfg.NAME_PREFIX)) return null;
  const slug = h.slice(cfg.NAME_PREFIX.length, h.length - tail.length);
  return /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(slug) ? slug : null;
}
