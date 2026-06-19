/**
 * In-process Feishu OpenAPI client (replaces `spawn lark-cli` on the CardKit hot
 * path).
 *
 * Why: every CardKit write used to `spawn("lark-cli", ["api", ...])`, and a single
 * lark-cli spawn costs ~800ms (Node cold start + token handling + network). On the
 * serial card-write queue that capped the live animation at ~1.2 frames/s — the
 * "timer only updates every 1-2s, feels laggy" complaint — and slowed the
 * conclusion typewriter. Calling the Feishu OpenAPI directly with `fetch` and a
 * cached tenant_access_token drops each call to ~50-100ms (one HTTPS round-trip),
 * so the animation is smooth and streaming is faster.
 *
 * Token: POST /open-apis/auth/v3/tenant_access_token/internal returns a token
 * valid `expire` seconds (typically 7200). We cache it in-process and refresh a
 * minute before expiry. Thread-safe enough for the single-process gateway (one
 * event loop): concurrent callers share one in-flight refresh promise.
 *
 * Scope: this is the hot-path CardKit client. lark-cli is still used for things
 * with no simple REST equivalent wired here (im send/reply, reactions) — those
 * are not in the per-frame animation loop, so their spawn cost doesn't matter.
 */

const BASE = process.env.FEISHU_API_BASE ?? "https://open.feishu.cn";
const APP_ID = process.env.FEISHU_APP_ID ?? "";
const APP_SECRET = process.env.FEISHU_APP_SECRET ?? "";

interface CachedToken {
  token: string;
  expiresAt: number; // epoch ms when it should be considered stale
}

let cached: CachedToken | null = null;
let inFlight: Promise<string> | null = null;

/** True when app credentials are configured. Callers on best-effort paths
 *  (reactions) skip entirely when false, so unit tests / un-provisioned envs make
 *  no network call (and don't log async errors after a test finishes). */
export function feishuConfigured(): boolean {
  return !!APP_ID && !!APP_SECRET;
}

/** Fetch (and cache) a tenant_access_token. Concurrent callers share one refresh. */
export async function getTenantToken(): Promise<string> {
  if (!APP_ID || !APP_SECRET) throw new Error("FEISHU_APP_ID/SECRET not configured");
  const now = Date.now();
  if (cached && now < cached.expiresAt) return cached.token;
  if (inFlight) return inFlight;
  inFlight = (async () => {
    try {
      const res = await fetch(`${BASE}/open-apis/auth/v3/tenant_access_token/internal`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ app_id: APP_ID, app_secret: APP_SECRET }),
      });
      const data = (await res.json()) as { code?: number; msg?: string; tenant_access_token?: string; expire?: number };
      if (data.code !== 0 || !data.tenant_access_token) {
        throw new Error(`tenant_access_token failed: code ${data.code} ${data.msg ?? ""}`);
      }
      // Refresh 60s before the stated expiry to avoid a stale-token 401 at the edge.
      cached = { token: data.tenant_access_token, expiresAt: Date.now() + Math.max(60, (data.expire ?? 7200) - 60) * 1000 };
      return cached.token;
    } finally {
      inFlight = null;
    }
  })();
  return inFlight;
}

/** Force the next call to re-fetch the token (used after a 401). */
export function invalidateToken(): void {
  cached = null;
}

export interface FeishuApiOptions {
  /** ms before the request is aborted (the same 15s ceiling lark-cli path used). */
  timeoutMs?: number;
}

// Feishu app-level codes (HTTP 200 body, code!=0) that mean "the tenant_access_token
// is invalid/expired" — Feishu signals token expiry FAR more often this way than via
// an HTTP 401, so refreshing only on HTTP 401 would leave a stale token wedging every
// write until the cache TTL. Treat these like a 401: invalidate + retry once.
const TOKEN_EXPIRY_CODES = new Set([99991663, 99991661, 99991664, 99991665, 99991677]);
// App-level throttle codes (HTTP 200 body) — retry with backoff, same as HTTP 429.
const THROTTLE_CODES = new Set([99991400, 1254607, 1254290, 1254291]);

/**
 * Call a Feishu OpenAPI endpoint in-process. `path` starts with `/open-apis/...`.
 * `body` is a JSON-serializable object (or undefined for GET). Returns the parsed
 * JSON. Throws on transport error, non-2xx, or a non-zero Feishu `code` — same
 * contract the lark-cli wrapper enforced. Resilience:
 *   - stale token (HTTP 401 OR app-level token-expiry code) → invalidate + retry once;
 *   - rate limit (HTTP 429 OR app-level throttle code) → bounded backoff retry
 *     (CardKit caps ~10 writes/s/card; a bursty turn can trip this, and a dropped
 *     FINALIZE write would leave a visibly broken card — so don't just drop it).
 */
export async function feishuApi(
  method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE",
  path: string,
  body?: unknown,
  opts: FeishuApiOptions = {},
): Promise<unknown> {
  const timeoutMs = opts.timeoutMs ?? 15000;
  const MAX_RATE_RETRIES = 3;
  let tokenRetried = false;
  let rateRetries = 0;
  for (;;) {
    const token = await getTenantToken();
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    if (typeof timer.unref === "function") timer.unref();
    let status: number;
    let retryAfterMs = 0;
    let json: { code?: number; msg?: string } | null;
    try {
      const res = await fetch(`${BASE}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json; charset=utf-8",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: ctrl.signal,
      }).catch((e: unknown) => {
        // Make a timeout/network abort self-describing (which write hung).
        throw new Error(`feishu ${method} ${path} transport error: ${String((e as Error)?.message ?? e)}`);
      });
      status = res.status;
      const ra = res.headers?.get?.("retry-after");
      if (ra) retryAfterMs = (Number(ra) || 0) * 1000;
      json = (await res.json().catch(() => null)) as { code?: number; msg?: string } | null;
    } finally {
      clearTimeout(timer);
    }

    const code = json?.code;
    const tokenExpired = status === 401 || (code !== undefined && TOKEN_EXPIRY_CODES.has(code));
    const throttled = status === 429 || (code !== undefined && THROTTLE_CODES.has(code));

    if (tokenExpired) {
      invalidateToken();
      if (!tokenRetried) { tokenRetried = true; continue; }
      throw new Error(`feishu ${method} ${path} token-expired (status ${status} code ${code}) after refresh`);
    }
    if (throttled) {
      if (rateRetries < MAX_RATE_RETRIES) {
        rateRetries++;
        const backoff = retryAfterMs || (150 * rateRetries + Math.floor(Math.random() * 100));
        await new Promise((r) => setTimeout(r, backoff));
        continue;
      }
      throw new Error(`feishu ${method} ${path} rate-limited (status ${status} code ${code}) after ${rateRetries} retries`);
    }
    if (status < 200 || status >= 300) {
      throw new Error(`feishu ${method} ${path} HTTP ${status}: ${json?.msg ?? ""}`);
    }
    if (code !== undefined && code !== 0) {
      throw new Error(`feishu ${method} ${path} code ${code}: ${json?.msg ?? ""}`);
    }
    // A 2xx whose body didn't parse (empty/HTML/truncated) must NOT be treated as a
    // successful write — a finalize that actually failed at the edge would look ok.
    if (json === null) {
      throw new Error(`feishu ${method} ${path} HTTP ${status} but response body was empty/unparseable`);
    }
    return json;
  }
}

// ── IM helpers (in-process; replace the remaining `spawn lark-cli im …`) ─────

interface SentMessage { data?: { message_id?: string } }

/** Reply to a message. msgType e.g. "interactive" (card) or "text". `content` is
 *  the already-JSON-stringified content payload Feishu expects. Returns the new
 *  message_id (for the card registry), or undefined. */
export async function imReply(messageId: string, msgType: string, content: string): Promise<string | undefined> {
  const res = (await feishuApi("POST", `/open-apis/im/v1/messages/${messageId}/reply`, {
    msg_type: msgType,
    content,
  })) as SentMessage;
  return res?.data?.message_id;
}

/** Send a message to a chat. Returns the new message_id, or undefined. */
export async function imSendToChat(chatId: string, msgType: string, content: string): Promise<string | undefined> {
  const res = (await feishuApi("POST", "/open-apis/im/v1/messages?receive_id_type=chat_id", {
    receive_id: chatId,
    msg_type: msgType,
    content,
  })) as SentMessage;
  return res?.data?.message_id;
}

/** Add a reaction emoji to a message. Returns the reaction_id (to delete later). */
export async function imAddReaction(messageId: string, emojiType: string): Promise<string | undefined> {
  const res = (await feishuApi("POST", `/open-apis/im/v1/messages/${messageId}/reactions`, {
    reaction_type: { emoji_type: emojiType },
  })) as { data?: { reaction_id?: string } };
  return res?.data?.reaction_id;
}

/** Delete a reaction by its reaction_id. */
export async function imDeleteReaction(messageId: string, reactionId: string): Promise<void> {
  await feishuApi("DELETE", `/open-apis/im/v1/messages/${messageId}/reactions/${reactionId}`);
}
