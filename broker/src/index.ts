// Koha Easy Installer subdomain broker.
//
// One Worker, three entry points:
//   fetch      the broker API on BROKER_HOST, and the edge gate on every
//              staff hostname (<prefix><slug><STAFF_SUFFIX>.<zone>)
//   queue      provisioning / removal jobs, run through the per-library
//              Provisioner Durable Object, with retries and rollback
//   scheduled  hourly reconciliation and cleanup

import * as admin from "./admin";
import * as api from "./api";
import { audit, provisioner } from "./db";
import type { Env, JobRow, ProvisionMessage } from "./env";
import { now } from "./env";
import { errorResponse, HttpError, json } from "./http";
import { slugFromStaffHost } from "./names";
import { isNameCollision } from "./provision-steps";
import { reconcile } from "./reconcile";
import { handleStaff } from "./staff-auth";

export { Provisioner } from "./provisioner";

const MAX_JOB_ATTEMPTS = 6;

type Handler = (request: Request, env: Env, body: ArrayBuffer, params: string[]) => Promise<Response>;

const routes: [string, RegExp, Handler][] = [
  ["POST", /^\/v1\/device\/start$/, (r, e, b) => api.deviceStart(r, e, b)],
  ["POST", /^\/v1\/device\/poll$/, (r, e, b) => api.devicePoll(r, e, b)],
  ["POST", /^\/v1\/enroll$/, (r, e, b) => api.enroll(r, e, b)],
  ["GET", /^\/join$/, (r, e) => api.joinPage(r, e)],
  ["GET", /^\/v1\/jobs\/([0-9a-f-]{36})$/, (r, e, b, p) => api.getJob(r, e, b, p[0]!)],
  ["GET", /^\/v1\/library$/, (r, e, b) => api.getLibraryInfo(r, e, b)],
  ["DELETE", /^\/v1\/library$/, (r, e, b) => api.deleteLibrary(r, e, b)],
  ["GET", /^\/v1\/tunnel-token$/, (r, e, b) => api.getTunnelToken(r, e, b)],
  ["POST", /^\/v1\/rotate$/, (r, e, b) => api.rotateToken(r, e, b)],
  ["POST", /^\/v1\/heartbeat$/, (r, e, b) => api.heartbeat(r, e, b)],
  ["PUT", /^\/v1\/staff-credentials$/, (r, e, b) => api.putStaffCredentials(r, e, b)],
  ["DELETE", /^\/v1\/staff-credentials$/, (r, e, b) => api.deleteStaffCredentials(r, e, b)],
];

const adminRoutes: [string, RegExp, Handler][] = [
  ["GET", /^\/admin\/enrollments$/, (r, e) => admin.listEnrollments(e, new URL(r.url))],
  ["POST", /^\/admin\/enrollments\/([A-Z]{4}-[A-Z]{4})\/approve$/, (_r, e, b, p) => admin.decideEnrollment(e, p[0]!, true, b)],
  ["POST", /^\/admin\/enrollments\/([A-Z]{4}-[A-Z]{4})\/deny$/, (_r, e, b, p) => admin.decideEnrollment(e, p[0]!, false, b)],
  ["GET", /^\/admin\/libraries$/, (_r, e) => admin.listLibraries(e)],
  ["POST", /^\/admin\/libraries\/([0-9a-f-]{36})\/suspend$/, (_r, e, _b, p) => admin.suspendLibrary(e, p[0]!, true)],
  ["POST", /^\/admin\/libraries\/([0-9a-f-]{36})\/restore$/, (_r, e, _b, p) => admin.suspendLibrary(e, p[0]!, false)],
  ["DELETE", /^\/admin\/libraries\/([0-9a-f-]{36})$/, (_r, e, _b, p) => admin.adminDeleteLibrary(e, p[0]!)],
];

function match(table: [string, RegExp, Handler][], method: string, path: string): [Handler, string[]] | null {
  for (const [m, re, h] of table) {
    const found = re.exec(path);
    if (found && m === method) return [h, found.slice(1)];
  }
  return null;
}

async function handleApi(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const isAdmin = url.pathname.startsWith("/admin/");
  const hit = match(isAdmin ? adminRoutes : routes, request.method, url.pathname);
  if (!hit) throw new HttpError(404, "not found");
  if (isAdmin) await admin.requireAdmin(request, env);
  const body = request.method === "GET" || request.method === "HEAD" ? new ArrayBuffer(0) : await request.arrayBuffer();
  return hit[0](request, env, body, hit[1]);
}

async function runJob(env: Env, jobId: string): Promise<void> {
  const job = await env.DB.prepare("SELECT * FROM jobs WHERE id = ?").bind(jobId).first<JobRow>();
  if (!job || job.state === "done" || job.state === "failed") return;
  await env.DB.prepare("UPDATE jobs SET state = 'running', attempts = attempts + 1, updated_at = ? WHERE id = ?")
    .bind(now(), jobId)
    .run();
  const stub = provisioner(env, job.library_id);
  if (job.kind === "provision") await stub.provision(job.library_id);
  else await stub.deprovision(job.library_id, "deleted");
  await env.DB.prepare("UPDATE jobs SET state = 'done', error = NULL, updated_at = ? WHERE id = ?").bind(now(), jobId).run();
}

async function failJob(env: Env, jobId: string, err: unknown): Promise<void> {
  const message = err instanceof Error ? err.message : String(err);
  const job = await env.DB.prepare("SELECT * FROM jobs WHERE id = ?").bind(jobId).first<JobRow>();
  if (!job) return;
  if (job.kind === "provision") {
    // Roll back whatever was created so no orphan tunnel or record stays.
    try {
      await provisioner(env, job.library_id).deprovision(job.library_id, "failed");
    } catch (e) {
      console.error("rollback failed; reconciliation will clean up", e);
    }
  }
  await env.DB.prepare("UPDATE jobs SET state = 'failed', error = ?, updated_at = ? WHERE id = ?")
    .bind(message.slice(0, 500), now(), jobId)
    .run();
  await audit(env, "system", `job.${job.kind}.failed`, job.library_id, { error: message.slice(0, 500) });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const host = new URL(request.url).hostname;
      const staffSlug = slugFromStaffHost(host, env);
      if (staffSlug) return await handleStaff(request, env, staffSlug);
      if (host !== env.BROKER_HOST && !host.endsWith(".workers.dev")) return json({ error: "not found" }, 404);
      return await handleApi(request, env);
    } catch (e) {
      return errorResponse(e);
    }
  },

  async queue(batch: MessageBatch<ProvisionMessage>, env: Env): Promise<void> {
    for (const msg of batch.messages) {
      try {
        await runJob(env, msg.body.jobId);
        msg.ack();
      } catch (e) {
        const permanent = isNameCollision(e);
        if (permanent || msg.attempts >= MAX_JOB_ATTEMPTS) {
          await failJob(env, msg.body.jobId, e);
          msg.ack();
        } else {
          console.warn(`job ${msg.body.jobId} attempt ${msg.attempts} failed`, e);
          msg.retry({ delaySeconds: Math.min(300, 15 * 2 ** msg.attempts) });
        }
      }
    }
  },

  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(reconcile(env));
  },
} satisfies ExportedHandler<Env, ProvisionMessage>;
