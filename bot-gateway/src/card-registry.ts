/**
 * In-memory message_id → { cardId, sessionId } registry.
 *
 * Card action callbacks (card.action.trigger) only carry context.open_message_id,
 * not the CardKit entity card_id. To update a clicked button (disable it, mark
 * it ✓) we need the card_id, so we record the mapping when we send each card and
 * look it up on click.
 *
 * We also remember the runtimeSessionId the card was answered under, so a
 * follow-up click can resume the SAME warm microVM (same conversation context)
 * regardless of how the original session key was formed. This matters for
 * THREADED questions: the original message routes via getSessionId(chat, thread)
 * → key `chat#thread`, but a follow-up click has no thread_id in its payload, so
 * re-deriving via getSessionId(chat) would mint a DIFFERENT (cold) session and
 * silently drop the prior turn's context. Reusing the stored sessionId avoids
 * that entirely.
 *
 * Bounded to avoid unbounded growth in a long-running gateway; oldest entries
 * are evicted past the cap (a clicked card is almost always a recent one).
 */

const MAX_ENTRIES = 500;

export interface CardEntry {
  cardId: string;
  sessionId?: string;
}

const registry = new Map<string, CardEntry>();

export function rememberCard(messageId: string, cardId: string, sessionId?: string): void {
  if (!messageId || !cardId) return;
  // Re-insert to keep Map insertion order = recency for eviction.
  registry.delete(messageId);
  registry.set(messageId, { cardId, sessionId });
  if (registry.size > MAX_ENTRIES) {
    const oldest = registry.keys().next().value;
    if (oldest !== undefined) registry.delete(oldest);
  }
}

/** Look up the card entry ({ cardId, sessionId }) for a sent message. */
export function lookupCard(messageId: string): CardEntry | undefined {
  return registry.get(messageId);
}

export function forgetCard(messageId: string): void {
  registry.delete(messageId);
}
