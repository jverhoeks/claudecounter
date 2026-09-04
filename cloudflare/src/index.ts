export interface Env {
  STATE: KVNamespace;
  WRITE_TOKEN: string;
  READ_TOKEN: string;
}

const KEY = "state";
const TTL_SECONDS = 24 * 60 * 60;
const MAX_BODY = 8 * 1024;

function bearer(req: Request): string {
  const h = req.headers.get("Authorization") ?? "";
  return h.startsWith("Bearer ") ? h.slice(7) : "";
}

// Constant-time compare so a token can't be guessed byte by byte from
// response timing.
function equal(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname !== "/state") return new Response("not found", { status: 404 });

    if (req.method === "PUT") {
      if (!env.WRITE_TOKEN || !equal(bearer(req), env.WRITE_TOKEN)) {
        return new Response("unauthorized", { status: 401 });
      }
      const body = await req.text();
      if (body.length > MAX_BODY) return new Response("too large", { status: 400 });
      let parsed: unknown;
      try {
        parsed = JSON.parse(body);
      } catch {
        return new Response("invalid json", { status: 400 });
      }
      if (typeof parsed !== "object" || parsed === null || (parsed as { v?: unknown }).v !== 1) {
        return new Response("unsupported payload version", { status: 400 });
      }
      await env.STATE.put(KEY, body, { expirationTtl: TTL_SECONDS });
      return new Response(null, { status: 204 });
    }

    if (req.method === "GET") {
      if (!env.READ_TOKEN || !equal(bearer(req), env.READ_TOKEN)) {
        return new Response("unauthorized", { status: 401 });
      }
      const body = await env.STATE.get(KEY);
      if (body === null) return new Response("no data", { status: 404 });
      return new Response(body, {
        status: 200,
        headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
      });
    }

    return new Response("not found", { status: 404 });
  },
};
