// Provisioning steps for one library, kept free of Worker APIs so they can
// be unit-tested against a fake Cloudflare API. The Provisioner Durable
// Object runs them one library at a time.
//
// Every step is idempotent: after a crash or a queue retry, the next run
// adopts what already exists (tunnel by its name, CNAME by name + target)
// instead of creating duplicates. A DNS name that already exists and points
// elsewhere is never overwritten.

import type { CloudflareApi, IngressRule } from "./cloudflare";
import type { Hostnames } from "./names";
import { randomBytes, toBase64 } from "./crypto";

export type TunnelDnsApi = Pick<
  CloudflareApi,
  | "createTunnel"
  | "findTunnelByName"
  | "putTunnelIngress"
  | "rotateTunnelSecret"
  | "deleteTunnel"
  | "findDnsRecords"
  | "createCname"
  | "deleteDnsRecord"
>;

export interface ProvisionState {
  tunnelId?: string;
  opacRecordId?: string;
  staffRecordId?: string;
}

export class NameCollisionError extends Error {
  constructor(readonly hostname: string) {
    super(`${hostname} already exists in DNS and does not belong to this library`);
    this.name = "NameCollisionError";
  }
}

// Errors thrown inside a Durable Object reach the caller as plain Errors
// (the class is lost over RPC), so match on the message.
export function isNameCollision(e: unknown): boolean {
  return e instanceof NameCollisionError || (e instanceof Error && e.message.endsWith("does not belong to this library"));
}

export const tunnelName = (libraryId: string): string => `kei-lib-${libraryId}`;
export const recordComment = (libraryId: string): string => `kei:lib:${libraryId}`;
export const tunnelTarget = (tunnelId: string): string => `${tunnelId}.cfargotunnel.com`;
export const LIBRARY_ID_FROM_COMMENT = /^kei:lib:([0-9a-f-]{36})$/;
export const LIBRARY_ID_FROM_TUNNEL = /^kei-lib-([0-9a-f-]{36})$/;

// OPAC to Apache :80 and staff to :8080 on the library server. When
// suspended, every hostname answers 503 from the tunnel itself, so DNS stays
// untouched and restoring is instant.
export function ingressFor(names: Hostnames, mode: "active" | "suspended"): IngressRule[] {
  if (mode === "suspended") {
    return [{ service: "http_status:503" }];
  }
  return [
    { hostname: names.opac, service: "http://localhost:80" },
    { hostname: names.staff, service: "http://localhost:8080" },
    { service: "http_status:404" },
  ];
}

async function ensureCname(api: TunnelDnsApi, name: string, target: string, comment: string): Promise<string> {
  const existing = await api.findDnsRecords(name);
  const ours = existing.find((r) => r.type === "CNAME" && r.content === target);
  if (ours) return ours.id;
  if (existing.length > 0) throw new NameCollisionError(name);
  return (await api.createCname(name, target, comment)).id;
}

export async function provision(
  api: TunnelDnsApi,
  libraryId: string,
  names: Hostnames,
  state: ProvisionState,
  save: (s: ProvisionState) => Promise<void>,
): Promise<Required<ProvisionState>> {
  if (!state.tunnelId) {
    const found = await api.findTunnelByName(tunnelName(libraryId));
    state.tunnelId = (found ?? (await api.createTunnel(tunnelName(libraryId)))).id;
    await save(state);
  }
  await api.putTunnelIngress(state.tunnelId, ingressFor(names, "active"));

  const target = tunnelTarget(state.tunnelId);
  const comment = recordComment(libraryId);
  state.opacRecordId = await ensureCname(api, names.opac, target, comment);
  await save(state);
  state.staffRecordId = await ensureCname(api, names.staff, target, comment);
  await save(state);
  return state as Required<ProvisionState>;
}

// Removes what belongs to the library and nothing else: records are deleted
// by stored id, or found by name only when they point at this library's
// tunnel or carry its comment.
export async function teardown(
  api: TunnelDnsApi,
  libraryId: string,
  names: Hostnames,
  state: ProvisionState,
): Promise<void> {
  const tunnelId = state.tunnelId ?? (await api.findTunnelByName(tunnelName(libraryId)))?.id;
  const comment = recordComment(libraryId);
  for (const [name, storedId] of [
    [names.opac, state.opacRecordId],
    [names.staff, state.staffRecordId],
  ] as const) {
    if (storedId) {
      await api.deleteDnsRecord(storedId);
      continue;
    }
    for (const r of await api.findDnsRecords(name)) {
      if (r.comment === comment || (tunnelId && r.content === tunnelTarget(tunnelId))) {
        await api.deleteDnsRecord(r.id);
      }
    }
  }
  if (tunnelId) await api.deleteTunnel(tunnelId);
}

export async function setSuspended(api: TunnelDnsApi, tunnelId: string, names: Hostnames, suspended: boolean): Promise<void> {
  await api.putTunnelIngress(tunnelId, ingressFor(names, suspended ? "suspended" : "active"));
}

export async function rotate(api: TunnelDnsApi, tunnelId: string): Promise<void> {
  await api.rotateTunnelSecret(tunnelId, toBase64(randomBytes(32)));
}
