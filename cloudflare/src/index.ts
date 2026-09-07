import { DurableObject } from "cloudflare:workers";

export interface Env {
  STATE: DurableObjectNamespace<State>;
  WRITE_TOKEN: string;
  READ_TOKEN: string;
}

const TTL_MS = 24 * 60 * 60 * 1000;
const MAX_BODY = 8 * 1024;

/// One instance (always the same id) holds the latest payload. Durable
/// Objects on the Workers free plan allow 100 000 requests a day, so a
/// 60 s publish plus a 60 s poll (2 880 a day) is nowhere near the
/// limit, unlike KV's 1 000 writes a day.
export class State extends DurableObject<Env> {
  private body: string | null = null;
  private expiresAt = 0;
  private loaded = false;

  private async load(): Promise<void> {
    if (this.loaded) return;
    this.body = (await this.ctx.storage.get<string>("body")) ?? null;
    this.expiresAt = (await this.ctx.storage.get<number>("expiresAt")) ?? 0;
    this.loaded = true;
  }

  async put(body: string): Promise<void> {
    await this.load();
    this.body = body;
    this.expiresAt = Date.now() + TTL_MS;
    await this.ctx.storage.put({ body, expiresAt: this.expiresAt });
    // A stopped mac app eventually yields 404 rather than a day-old
    // number forever; the alarm clears storage, `get` guards the window
    // between expiry and the alarm firing.
    await this.ctx.storage.setAlarm(this.expiresAt);
  }

  async get(): Promise<string | null> {
    await this.load();
    if (this.body === null || Date.now() >= this.expiresAt) return null;
    return this.body;
  }

  async alarm(): Promise<void> {
    await this.load();
    if (Date.now() >= this.expiresAt) {
      this.body = null;
      await this.ctx.storage.deleteAll();
    }
  }
}

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

    const state = env.STATE.get(env.STATE.idFromName("state"));

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
      await state.put(body);
      return new Response(null, { status: 204 });
    }

    if (req.method === "GET") {
      if (!env.READ_TOKEN || !equal(bearer(req), env.READ_TOKEN)) {
        return new Response("unauthorized", { status: 401 });
      }
      const body = await state.get();
      if (body === null) return new Response("no data", { status: 404 });
      return new Response(body, {
        status: 200,
        headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
      });
    }

    return new Response("not found", { status: 404 });
  },
};
