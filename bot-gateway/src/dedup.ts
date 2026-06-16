/**
 * Event-ID deduplication for Feishu event replay protection.
 *
 * Feishu may re-deliver the same IM event (same event_id) multiple times.
 * This module tracks seen event_ids in a TTL map and rejects duplicates.
 *
 * Design: in-memory Map with setTimeout cleanup. Sufficient for MVP single-
 * process gateway (≤5 concurrent users, low frequency). If scaled to multiple
 * processes, replace with a shared store (Redis/DDB TTL).
 */

const DEFAULT_TTL_MS = 5 * 60 * 1000; // 5 minutes

const seen = new Map<string, NodeJS.Timeout>();

/**
 * Returns `true` if this event_id was already seen (duplicate → skip).
 * Returns `false` on first occurrence (not duplicate → process).
 */
export function isDuplicate(eventId: string, ttlMs: number = DEFAULT_TTL_MS): boolean {
  if (seen.has(eventId)) {
    return true;
  }
  const timer = setTimeout(() => {
    seen.delete(eventId);
  }, ttlMs);
  // Unref so the timer doesn't prevent Node from exiting.
  if (typeof timer.unref === "function") timer.unref();
  seen.set(eventId, timer);
  return false;
}

/** Clear all tracked event_ids. Test-only. */
export function resetForTesting(): void {
  for (const timer of seen.values()) {
    clearTimeout(timer);
  }
  seen.clear();
}
