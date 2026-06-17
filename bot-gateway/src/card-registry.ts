/**
 * In-memory message_id → card_id registry.
 *
 * Card action callbacks (card.action.trigger) only carry context.open_message_id,
 * not the CardKit entity card_id. To update a clicked button (disable it, mark
 * it ✓) we need the card_id, so we record the mapping when we send each card and
 * look it up on click.
 *
 * Bounded to avoid unbounded growth in a long-running gateway; oldest entries
 * are evicted past the cap (a clicked card is almost always a recent one).
 */

const MAX_ENTRIES = 500;
const registry = new Map<string, string>();

export function rememberCard(messageId: string, cardId: string): void {
  if (!messageId || !cardId) return;
  // Re-insert to keep Map insertion order = recency for eviction.
  registry.delete(messageId);
  registry.set(messageId, cardId);
  if (registry.size > MAX_ENTRIES) {
    const oldest = registry.keys().next().value;
    if (oldest !== undefined) registry.delete(oldest);
  }
}

export function lookupCard(messageId: string): string | undefined {
  return registry.get(messageId);
}

export function forgetCard(messageId: string): void {
  registry.delete(messageId);
}
