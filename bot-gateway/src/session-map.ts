/**
 * Session routing: (chatId, threadId?) → stable runtimeSessionId.
 *
 * Architecture contract: same question thread reuses the same warm microVM
 * (same runtimeSessionId); different users/threads never share a session.
 *
 * IMPORTANT: the returned id is sent as the AgentCore runtimeSessionId, which
 * AgentCore requires to be >= 33 chars (HTTP 400 otherwise — verified live).
 * randomUUID() is 36 chars, so it satisfies this; any future id scheme MUST
 * keep >= 33 chars (sigv4.buildInvokeRequest asserts MIN_SESSION_ID_LEN).
 *
 * MVP: in-memory Map with TTL. If scaled to multi-process, replace with DDB
 * (chatId#threadId as PK, TTL attribute for auto-expiry).
 */

import { randomUUID } from "node:crypto";

/**
 * Session-reuse TTL, ALIGNED to the AgentCore runtime's idle timeout.
 *
 * Reusing a runtimeSessionId only pays off while AgentCore still holds the warm
 * microVM behind it; once the runtime's idle timeout recycles that VM, "reuse"
 * silently lands on a cold start. So this TTL must NOT exceed the runtime idle
 * window. The deploy writes the runtime's actual idle timeout into the gateway
 * env (RUNTIME_IDLE_TIMEOUT_SECS, set by activate_gateway.sh from deploy-all's
 * --idle-timeout), so the two are driven by one value instead of two guesses.
 * Default 900s (15min) = AgentCore's own default, used when the env is unset.
 *
 * The TTL is sliding (refreshed on every reuse), so it bounds idle-gap-to-expiry,
 * not total conversation length.
 */
function resolveDefaultTtlMs(): number {
  const raw = process.env.RUNTIME_IDLE_TIMEOUT_SECS;
  const secs = raw ? Number(raw) : NaN;
  // Guard against unset/garbage/non-positive; fall back to the AgentCore default.
  return Number.isFinite(secs) && secs > 0 ? secs * 1000 : 900 * 1000;
}

const DEFAULT_TTL_MS = resolveDefaultTtlMs();

interface Entry {
  sessionId: string;
  timer: NodeJS.Timeout;
}

const sessions = new Map<string, Entry>();

function makeKey(chatId: string, threadId?: string): string {
  return threadId ? `${chatId}#${threadId}` : chatId;
}

/**
 * Get or create a runtimeSessionId for the given chat/thread.
 * First call for a key creates a new UUID; subsequent calls within TTL return
 * the same value. After TTL expiry the entry is removed and next call creates
 * a fresh session.
 */
export function getSessionId(
  chatId: string,
  threadId?: string,
  ttlMs: number = DEFAULT_TTL_MS,
): string {
  return getSessionState(chatId, threadId, ttlMs).sessionId;
}

/** Like getSessionId but also reports whether the session was REUSED (warm) or
 *  freshly minted (cold). `cold` is the perf signal for issue #2: a cold invoke
 *  folds in microVM spin-up + AgentCore routing (native cc has none), so only
 *  warm rows are apples-to-apples comparable to native-cc steady state. */
export function getSessionState(
  chatId: string,
  threadId?: string,
  ttlMs: number = DEFAULT_TTL_MS,
): { sessionId: string; cold: boolean } {
  const key = makeKey(chatId, threadId);
  const arm = (): NodeJS.Timeout => {
    const t = setTimeout(() => { sessions.delete(key); }, ttlMs);
    if (typeof t.unref === "function") t.unref();
    return t;
  };

  const existing = sessions.get(key);
  if (existing) {
    // Sliding TTL: refresh the expiry on every reuse so an actively-used
    // conversation isn't dropped mid-thread at the fixed 30-min mark (which
    // would spawn a new session and lose context). Idle keys still expire.
    clearTimeout(existing.timer);
    existing.timer = arm();
    return { sessionId: existing.sessionId, cold: false };
  }

  const sessionId = randomUUID();
  sessions.set(key, { sessionId, timer: arm() });
  return { sessionId, cold: true };
}

/** Clear all sessions. Test-only. */
export function resetForTesting(): void {
  for (const entry of sessions.values()) {
    clearTimeout(entry.timer);
  }
  sessions.clear();
}
