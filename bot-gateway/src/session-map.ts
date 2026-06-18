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

const DEFAULT_TTL_MS = 30 * 60 * 1000; // 30 minutes (> AgentCore idle ~15min)

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
    return existing.sessionId;
  }

  const sessionId = randomUUID();
  sessions.set(key, { sessionId, timer: arm() });
  return sessionId;
}

/** Clear all sessions. Test-only. */
export function resetForTesting(): void {
  for (const entry of sessions.values()) {
    clearTimeout(entry.timer);
  }
  sessions.clear();
}
