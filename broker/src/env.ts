import type { Provisioner } from "./provisioner";

// Bindings and variables declared in wrangler.toml. Secrets (set with
// `wrangler secret put`) are marked; they never appear in the repository.
export interface Env {
  DB: D1Database;
  PROVISIONER: DurableObjectNamespace<Provisioner>;
  PROVISION_QUEUE: Queue<ProvisionMessage>;
  RL_DEVICE: RateLimit;
  RL_API: RateLimit;
  RL_STAFF: RateLimit;

  CF_API_TOKEN: string; // secret: Cloudflare API token (Tunnel Edit + DNS Edit on one zone)
  ADMIN_TOKEN: string; // secret: bearer token for /admin endpoints
  STAFF_SESSION_KEY: string; // secret: HMAC key for staff session cookies

  CF_ACCOUNT_ID: string; // account that owns the zone and the tunnels
  CF_ZONE_ID: string;
  ZONE_NAME: string; // e.g. bibliotecamunicipalpalotina.org
  BROKER_HOST: string; // hostname serving the broker API
  NAME_PREFIX: string; // "t-" on the test zone, "" in production
  STAFF_SUFFIX: string; // "-admin"
  AUTO_APPROVE: string; // "true" | "false"
  PBKDF2_ITERATIONS: string;
  MAX_LIBRARIES_PER_DAY: string;
  CF_API_BASE?: string; // local tests only (.dev.vars): points the client at a fake API
}

export interface ProvisionMessage {
  jobId: string;
}

export type LibraryStatus = "provisioning" | "active" | "suspended" | "failed" | "deprovisioning" | "deleted";

export interface LibraryRow {
  id: string;
  slug: string;
  status: LibraryStatus;
  institution_name: string;
  contact_email: string;
  cnpj: string | null;
  public_key: string;
  tunnel_id: string | null;
  opac_record_id: string | null;
  staff_record_id: string | null;
  staff_user: string | null;
  staff_pass_hash: string | null;
  staff_pass_salt: string | null;
  staff_pass_iter: number | null;
  staff_cred_version: number;
  staff_allow_cidrs: string | null;
  koha_version: string | null;
  installer_version: string | null;
  last_heartbeat: number | null;
  created_at: number;
  updated_at: number;
}

export interface JobRow {
  id: string;
  library_id: string;
  kind: "provision" | "deprovision";
  state: "queued" | "running" | "done" | "failed";
  attempts: number;
  error: string | null;
  created_at: number;
  updated_at: number;
}

export const now = (): number => Math.floor(Date.now() / 1000);
