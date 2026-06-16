/**
 * Session routing: (chatId, threadId?) → stable runtimeSessionId.
 *
 * Architecture contract: same question thread reuses the same warm microVM
 * (same runtimeSessionId); different users/threads never share a session.
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
  const existing = sessions.get(key);
  if (existing) {
    return existing.sessionId;
  }

  const sessionId = randomUUID();
  const timer = setTimeout(() => {
    sessions.delete(key);
  }, ttlMs);
  if (typeof timer.unref === "function") timer.unref();

  sessions.set(key, { sessionId, timer });
  return sessionId;
}

/** Clear all sessions. Test-only. */
export function resetForTesting(): void {
  for (const entry of sessions.values()) {
    clearTimeout(entry.timer);
  }
  sessions.clear();
}
