export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export function json(data: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extra },
  });
}

export function errorResponse(e: unknown): Response {
  if (e instanceof HttpError) return json({ error: e.message }, e.status);
  console.error("unhandled", e instanceof Error ? e.stack ?? e.message : String(e));
  return json({ error: "internal error" }, 500);
}

export function parseJson<T>(body: ArrayBuffer): T {
  if (body.byteLength > 16 * 1024) throw new HttpError(413, "request body too large");
  try {
    return JSON.parse(new TextDecoder().decode(body || new ArrayBuffer(0)) || "{}") as T;
  } catch {
    throw new HttpError(400, "invalid JSON");
  }
}

export function str(v: unknown, field: string, opts: { min?: number; max: number; re?: RegExp; optional?: boolean }): string {
  if ((v === undefined || v === null || v === "") && opts.optional) return "";
  if (typeof v !== "string") throw new HttpError(400, `${field} is required`);
  const s = v.trim();
  if (s.length < (opts.min ?? 1) || s.length > opts.max) throw new HttpError(400, `${field} has an invalid length`);
  if (opts.re && !opts.re.test(s)) throw new HttpError(400, `${field} is invalid`);
  return s;
}
