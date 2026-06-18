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
// Cap the remembered answer so the registry can't grow unbounded and so a
// follow-up's replayed context stays a reasonable size (a multi-KB answer is
// plenty of context; we keep the head where the conclusion lives).
const MAX_ANSWER_CHARS = 4000;

// How many prior turns to replay at most, and the total context budget, so a
// long conversation can't blow up the prompt. Newest turns are kept.
const MAX_CHAIN_TURNS = 8;
const MAX_CHAIN_CHARS = 12000;

export interface CardEntry {
  cardId: string;
  sessionId?: string;
  /** The user's question this card answered + the answer text. Stored so a
   *  follow-up can REPLAY the prior turn as context (stateless external history —
   *  the community-recommended pattern, vs. relying on a sticky warm microVM that
   *  doesn't actually carry SDK conversation state across invokes). */
  question?: string;
  answer?: string;
  /** The message_id of the card this turn was a follow-up/reply OF, forming a
   *  conversation chain. Walking parentMessageId back collects the WHOLE history
   *  so multi-step 追问/reply串 carry the full context, not just the last turn. */
  parentMessageId?: string;
}

/** One prior turn in a replayed conversation chain (oldest→newest order). */
export interface ChainTurn { question?: string; answer?: string }

const registry = new Map<string, CardEntry>();

export function rememberCard(
  messageId: string,
  cardId: string,
  sessionId?: string,
  question?: string,
  parentMessageId?: string,
): void {
  if (!messageId || !cardId) return;
  // Re-insert to keep Map insertion order = recency for eviction.
  const prev = registry.get(messageId);
  registry.delete(messageId);
  registry.set(messageId, { cardId, sessionId, question, answer: prev?.answer, parentMessageId });
  if (registry.size > MAX_ENTRIES) {
    const oldest = registry.keys().next().value;
    if (oldest !== undefined) registry.delete(oldest);
  }
}

/**
 * Walk the parent chain from `messageId` (the card being followed-up/replied-to)
 * back through its ancestors, collecting each turn's {question, answer} in
 * oldest→newest order so they replay naturally. Bounded by turn count, total
 * chars (drops oldest first), and a cycle guard. Returns [] when the card is
 * unknown (evicted/restart). This is what lets MULTIPLE follow-ups/replies build
 * the whole conversation, not just the immediately-preceding turn.
 */
export function collectChain(messageId: string): ChainTurn[] {
  const turns: ChainTurn[] = [];
  const seen = new Set<string>();
  let id: string | undefined = messageId;
  while (id && !seen.has(id) && turns.length < MAX_CHAIN_TURNS) {
    seen.add(id);
    const e = registry.get(id);
    if (!e) break;
    // Require a SETTLED answer for the turn to count. A turn with a question but
    // no answer = the card is still streaming (answer stored only at finalize) or
    // it hard-failed (answer never stored). Replaying a bare question the agent
    // can't see the answer to degrades context for the most-relevant turn, so we
    // skip it (but keep walking to its finalized ancestors via parentMessageId).
    if (e.answer) turns.unshift({ question: e.question, answer: e.answer });
    id = e.parentMessageId;
  }
  // Trim from the OLDEST end if over the char budget (keep the most recent turns,
  // which are the most relevant to the current follow-up).
  let total = turns.reduce((n, t) => n + (t.question?.length ?? 0) + (t.answer?.length ?? 0), 0);
  while (turns.length > 1 && total > MAX_CHAIN_CHARS) {
    const dropped = turns.shift()!;
    total -= (dropped.question?.length ?? 0) + (dropped.answer?.length ?? 0);
  }
  return turns;
}

/** Record the final answer for a card (called at finalize) so a later follow-up
 *  on this card can replay the full prior turn (question + answer) as context. */
export function rememberAnswer(messageId: string, answer: string): void {
  if (!messageId) return;
  const entry = registry.get(messageId);
  if (!entry) return; // card evicted/unknown — best-effort
  entry.answer = answer.slice(0, MAX_ANSWER_CHARS);
}

/** Look up the card entry for a sent message. */
export function lookupCard(messageId: string): CardEntry | undefined {
  return registry.get(messageId);
}

export function forgetCard(messageId: string): void {
  registry.delete(messageId);
}
