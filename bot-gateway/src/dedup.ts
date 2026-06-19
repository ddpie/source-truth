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

// The TTL MUST outlive the longest possible in-flight invoke, or a duplicate
// guard expires WHILE its work is still running: a single answer can stream up to
// ~9 min (index.ts STREAM_TIMEOUT_MS = Feishu's 10-min hard close minus a 1-min
// finalize margin). If Feishu re-delivers the triggering event after the 5-min mark
// (push retry / network blip), BOTH the event_id and msg: guards have already
// expired → the event passes the gates again → a SECOND invoke + a SECOND card +
// double cost (cross-review CONFIRMED). Set the window past the invoke ceiling plus
// a redelivery margin so a guard never lapses mid-flight. Kept in sync with index.ts
// by COMMENT (dedup.ts must not import the gateway entrypoint); if the stream timeout
// changes, revisit this. 15 min = 9-min invoke ceiling + ~6-min redelivery margin.
const DEFAULT_TTL_MS = 15 * 60 * 1000; // 15 minutes — must exceed the ~9-min invoke ceiling

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

/**
 * Roll back a `isDuplicate` mark so the SAME id can be processed again. Used when
 * the work the dedup was guarding FAILED before completing (e.g. the card send threw
 * on a transient error): without this, the dedup key stays burned for the full TTL,
 * so Feishu's re-delivery of that event — the very retry the user needs — is silently
 * dropped and they get no card at all. Rolling back lets the re-delivery retry.
 */
export function forget(eventId: string): void {
  const timer = seen.get(eventId);
  if (timer) {
    clearTimeout(timer);
    seen.delete(eventId);
  }
}

/** Clear all tracked event_ids. Test-only. */
export function resetForTesting(): void {
  for (const timer of seen.values()) {
    clearTimeout(timer);
  }
  seen.clear();
}
