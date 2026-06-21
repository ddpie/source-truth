/**
 * Session routing: (chatId, threadId?) → runtimeSessionId, backed by a bounded
 * pool of warm sessions.
 *
 * Architecture contract: same question thread reuses the same warm microVM (same
 * runtimeSessionId). On TOP of that, a NEW chat/thread does not blindly cold-start
 * a fresh microVM — it BEST-EFFORT borrows an idle warm session that some other
 * conversation already spun up. This is safe because each runtime invoke is a
 * fresh SDK session (history is replayed via the prompt, not held in the VM), so
 * two conversations sharing one warm sessionId never bleed context — they only
 * serialize against each other (serialize-session.ts), which the concurrency gate
 * would bound anyway. Reuse is therefore opportunistic, NOT guaranteed: a borrowed
 * session may be recycled and a later turn falls back to a cold mint.
 *
 * Pool shape:
 *  - HIT (same key, within TTL): reuse its session, refresh TTL. (unchanged)
 *  - MISS: borrow the MOST-recently-used IDLE warm session if one exists; else
 *    mint a fresh (cold) session while the warm pool is below cap; else (pool full
 *    AND all busy) share the OLDEST session — its turn started earliest so it
 *    frees up soonest — rather than spin a VM the concurrency gate can't run.
 *  - The pool of DISTINCT sessions is hard-capped at MAX_WARM_POOL (mirrors the
 *    invoke concurrency gate: a warm VM beyond what can run concurrently is waste).
 *  - Sessions are recycled purely by the sliding TTL (no explicit return): the key
 *    not touched for the longest expires first, which drops its session from the
 *    pool once no key references it — i.e. LRU recycling falls out of the TTL.
 *
 * IMPORTANT: the returned id is sent as the AgentCore runtimeSessionId, which
 * AgentCore requires to be >= 33 chars (HTTP 400 otherwise — verified live).
 * randomUUID() is 36 chars, so it satisfies this; any future id scheme MUST
 * keep >= 33 chars (sigv4.buildInvokeRequest asserts MIN_SESSION_ID_LEN).
 *
 * MVP: in-memory Map with TTL. If scaled to multi-process, replace with DDB
 * (chatId#threadId as PK, TTL attribute for auto-expiry) + a shared pool view.
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

/**
 * Max number of DISTINCT warm sessions to hold. Mirrors the invoke concurrency
 * gate (MAX_CONCURRENT_INVOKES, default 8 in index.ts): a warm VM beyond what the
 * gate can ever run concurrently is just idle cost, so the pool never grows past
 * it — past the cap, a new conversation shares an existing session instead of
 * minting a 9th. Keeping the same env/default as the gate ties the two together.
 */
function resolveMaxWarmPool(): number {
  const raw = Number(process.env.MAX_CONCURRENT_INVOKES);
  return Number.isFinite(raw) && raw > 0 ? raw : 8;
}

const MAX_WARM_POOL = resolveMaxWarmPool();

interface Entry {
  sessionId: string;
  timer: NodeJS.Timeout;
}

// Insertion-ordered (JS Map): oldest key first, most-recently-used key last.
// Reused keys are re-inserted at the tail (touch-to-tail) so "MRU idle" borrow
// and TTL-driven "LRU recycle" both read straight off this order.
const sessions = new Map<string, Entry>();

type BusyProbe = (sessionId: string) => boolean;

/**
 * Whether a session currently has an invoke queued/running. Injected by index.ts
 * (wraps SessionSerializer.isBusy) — kept as a hook so session-map doesn't import
 * the serializer (avoids a cycle) and stays unit-testable in isolation.
 *
 * Default: treat EVERY session as busy → never borrow → mint a fresh session per
 * new key (the pre-pool behaviour) until the cap. This is the safe default: if
 * the probe is never wired, traffic does NOT collapse onto one over-serialized
 * session. Wiring the real probe is what ENABLES warm-session borrowing.
 */
let isBusy: BusyProbe = () => true;

/** Wire the real busy probe (index.ts startup). Enables warm-session borrowing. */
export function setBusyProbe(fn: BusyProbe): void {
  isBusy = fn;
}

function makeKey(chatId: string, threadId?: string): string {
  return threadId ? `${chatId}#${threadId}` : chatId;
}

/**
 * Get or reuse a runtimeSessionId for the given chat/thread.
 * Same key within TTL returns the same value; a new key best-effort borrows a
 * warm session (see file header) or mints a fresh one.
 */
export function getSessionId(
  chatId: string,
  threadId?: string,
  ttlMs: number = DEFAULT_TTL_MS,
): string {
  return getSessionState(chatId, threadId, ttlMs).sessionId;
}

/** Like getSessionId but also reports whether the session was freshly minted
 *  (`cold: true` ⇒ a brand-new UUID ⇒ a real AgentCore cold start: microVM
 *  spin-up + routing folded into the first response). A REUSED key OR a BORROWED
 *  warm session is `cold: false` — both land on an already-warm VM, so only true
 *  cold mints should drive the runtime_cold_start telemetry / perf comparison. */
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
    // Sliding TTL: refresh expiry on every reuse so an actively-used conversation
    // isn't dropped mid-thread (which would spawn a new session and lose context).
    clearTimeout(existing.timer);
    existing.timer = arm();
    // Touch-to-tail: move this key to the MRU end so recency order stays accurate
    // for MRU-idle borrow / LRU-recycle.
    sessions.delete(key);
    sessions.set(key, existing);
    return { sessionId: existing.sessionId, cold: false };
  }

  // MISS. One pass over the pool (oldest→newest) gathers everything the three
  // fallbacks need: the MRU idle session (last idle seen), the distinct-session
  // count (cap check), and the oldest session (first seen) for the full-pool case.
  let mruIdle: string | undefined;
  let oldest: string | undefined;
  const distinct = new Set<string>();
  for (const e of sessions.values()) {
    if (oldest === undefined) oldest = e.sessionId;
    distinct.add(e.sessionId);
    if (!isBusy(e.sessionId)) mruIdle = e.sessionId;
  }

  // (1) Borrow the most-recently-used IDLE warm session, if any.
  if (mruIdle !== undefined) {
    sessions.set(key, { sessionId: mruIdle, timer: arm() });
    return { sessionId: mruIdle, cold: false };
  }

  // (2) No idle session. Mint a fresh (cold) one only while the DISTINCT warm
  // pool is below cap.
  if (distinct.size < MAX_WARM_POOL) {
    const sessionId = randomUUID();
    sessions.set(key, { sessionId, timer: arm() });
    return { sessionId, cold: true };
  }

  // (3) Pool full AND everything busy: share the OLDEST session rather than mint
  // one the concurrency gate could never run. Oldest (not MRU) because its turn
  // started earliest → it frees up soonest, so this overflow turn serializes
  // behind the SHORTEST remaining wait. `oldest` is set whenever the pool is
  // non-empty, and distinct.size >= cap >= 1 guarantees it here.
  const share = oldest as string;
  sessions.set(key, { sessionId: share, timer: arm() });
  return { sessionId: share, cold: false };
}

/** Clear all sessions and restore the default busy probe. Test-only. */
export function resetForTesting(): void {
  for (const entry of sessions.values()) {
    clearTimeout(entry.timer);
  }
  sessions.clear();
  isBusy = () => true;
}
