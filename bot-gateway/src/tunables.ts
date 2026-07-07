/**
 * Cross-module tunable constants — a NEUTRAL leaf module (imports nothing), so
 * dedup.ts / session-map.ts / index.ts can all import the same value without
 * pulling in the gateway entrypoint (index.ts runs side effects at import time
 * and importing it from dedup/session-map would create a cycle). Values that
 * more than one module must agree on live HERE, never as per-file copies "kept
 * in sync by comment".
 */

/** Feishu force-closes a streaming card at 10 min — the external hard limit. */
export const FEISHU_STREAM_HARD_LIMIT_MS = 10 * 60 * 1000;

/**
 * Safety timeout for one streaming invoke. Derived from the external Feishu hard
 * window with a 1-min margin to finalize gracefully, so the "must stay below the
 * hard window" invariant is self-documenting (not a magic 9 vs a prose "Feishu
 * closes at 10" comment that can drift if either value changes). dedup.ts derives
 * its event-replay TTL from this same constant (TTL must outlive the longest
 * in-flight invoke), so changing the timeout moves the dedup window with it.
 */
export const STREAM_TIMEOUT_MS = FEISHU_STREAM_HARD_LIMIT_MS - 60 * 1000;

/**
 * Default for the MAX_CONCURRENT_INVOKES env when unset/invalid. Shared by the
 * global invoke gate (index.ts) and the warm-session pool cap (session-map.ts):
 * a warm VM beyond what the gate can ever run concurrently is just idle cost, so
 * the pool caps at the same number. Each site still parses the env itself; only
 * the DEFAULT is single-sourced (previously two hardcoded 8s that could drift).
 */
export const DEFAULT_MAX_CONCURRENT_INVOKES = 8;
