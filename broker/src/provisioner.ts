// One Durable Object per library (named by library id). Durable Objects run
// single-threaded, and blockConcurrencyWhile keeps other calls out until an
// operation finishes, so provisioning, rotation, suspension and teardown of
// the same library can never interleave, even with queue retries or two
// admin clicks at once. Step progress is kept in the object's own storage so
// a retry resumes where the last attempt stopped.

import { DurableObject } from "cloudflare:workers";
import type { CloudflareApi } from "./cloudflare";
import { cfApi } from "./db";
import type { Env, LibraryRow } from "./env";
import { now } from "./env";
import { hostnamesFor } from "./names";
import * as steps from "./provision-steps";

const STATE_KEY = "state";

export class Provisioner extends DurableObject<Env> {
  private api(): CloudflareApi {
    return cfApi(this.env);
  }

  private async library(id: string): Promise<LibraryRow> {
    const lib = await this.env.DB.prepare("SELECT * FROM libraries WHERE id = ?").bind(id).first<LibraryRow>();
    if (!lib) throw new Error(`library ${id} not found`);
    return lib;
  }

  private exclusive<T>(fn: () => Promise<T>): Promise<T> {
    return this.ctx.blockConcurrencyWhile(fn);
  }

  async provision(libraryId: string): Promise<void> {
    return this.exclusive(async () => {
      const lib = await this.library(libraryId);
      if (lib.status !== "provisioning") return;
      const state = (await this.ctx.storage.get<steps.ProvisionState>(STATE_KEY)) ?? {};
      const done = await steps.provision(this.api(), lib.id, hostnamesFor(lib.slug, this.env), state, (s) =>
        this.ctx.storage.put(STATE_KEY, s),
      );
      await this.env.DB.prepare(
        `UPDATE libraries SET status = 'active', tunnel_id = ?, opac_record_id = ?, staff_record_id = ?, updated_at = ?
         WHERE id = ? AND status = 'provisioning'`,
      )
        .bind(done.tunnelId, done.opacRecordId, done.staffRecordId, now(), lib.id)
        .run();
    });
  }

  // Used both for a requested removal and for rolling back a failed provision.
  async deprovision(libraryId: string, finalStatus: "deleted" | "failed"): Promise<void> {
    return this.exclusive(async () => {
      const lib = await this.library(libraryId);
      const stored = (await this.ctx.storage.get<steps.ProvisionState>(STATE_KEY)) ?? {};
      const state: steps.ProvisionState = {
        tunnelId: stored.tunnelId ?? lib.tunnel_id ?? undefined,
        opacRecordId: stored.opacRecordId ?? lib.opac_record_id ?? undefined,
        staffRecordId: stored.staffRecordId ?? lib.staff_record_id ?? undefined,
      };
      await steps.teardown(this.api(), lib.id, hostnamesFor(lib.slug, this.env), state);
      await this.ctx.storage.deleteAll();
      const stmts = [
        this.env.DB.prepare(
          `UPDATE libraries SET status = ?, tunnel_id = NULL, opac_record_id = NULL, staff_record_id = NULL, updated_at = ?
           WHERE id = ?`,
        ).bind(finalStatus, now(), lib.id),
      ];
      if (finalStatus === "deleted") {
        // Hold a released name for 180 days so nobody else can take it right away.
        stmts.push(
          this.env.DB.prepare(
            `INSERT INTO reserved_names (slug, reason, until) VALUES (?, ?, ?)
             ON CONFLICT(slug) DO UPDATE SET reason = excluded.reason, until = excluded.until`,
          ).bind(lib.slug, `released by library ${lib.id}`, now() + 180 * 86400),
        );
      }
      await this.env.DB.batch(stmts);
    });
  }

  async setSuspended(libraryId: string, suspended: boolean): Promise<void> {
    return this.exclusive(async () => {
      const lib = await this.library(libraryId);
      const from = suspended ? "active" : "suspended";
      if (lib.status !== from || !lib.tunnel_id) throw new Error(`library is ${lib.status}, expected ${from}`);
      await steps.setSuspended(this.api(), lib.tunnel_id, hostnamesFor(lib.slug, this.env), suspended);
      await this.env.DB.prepare("UPDATE libraries SET status = ?, updated_at = ? WHERE id = ?")
        .bind(suspended ? "suspended" : "active", now(), lib.id)
        .run();
    });
  }

  async rotate(libraryId: string): Promise<void> {
    return this.exclusive(async () => {
      const lib = await this.library(libraryId);
      if (lib.status !== "active" || !lib.tunnel_id) throw new Error(`library is ${lib.status}`);
      await steps.rotate(this.api(), lib.tunnel_id);
    });
  }
}
