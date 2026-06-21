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
// Clip the stored QUESTION too. A planner can paste a huge blob (a log, a whole config
// table) as the "question"; left unclipped it bypasses the chain budget below — one
// long question could starve the per-turn trim (squeezing out earlier turns → lost
// context) or push the replayed prompt past AgentCore's input limit (cross-review).
// Questions are normally short; a long one is almost always an over-paste, so a tight
// cap is safe.
const MAX_QUESTION_CHARS = 1500;

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
  /** open_id of the user who asked this turn's question. A bare reply (no @) to a
   *  bot card is auto-answered only when it comes from THIS asker — so one card
   *  doesn't let every group member trigger an invoke (cost), and a bot replying
   *  to our card never matches an asker. Other members must still @-mention. */
  askerOpenId?: string;
  /** Whether the 👍/👎 vote row has already been replaced with its disabled state.
   *  CARD-lifetime flag (the vote row is a card-global element): the first vote
   *  paints the row and disables it for everyone; later votes still count (per-user
   *  metric) but must NOT repaint. Tracked here, not in the dedup store, because the
   *  vote row's "already painted" is a card-existence fact — it must outlive the
   *  dedup TTL (15min), or a vote on a still-live but stale card would repaint and
   *  the reason-grid re-append would 300315-conflict on the existing fbr_* ids. */
  voteRowPainted?: boolean;
  /** Whether the 👎 reason grid has been appended to this card (independent of
   *  voteRowPainted, so a 👍-then-👎 still gets its reason grid exactly once — a
   *  bare 👍 paints the row but does NOT append reasons). Append-once guard: a 2nd
   *  append would 300315-conflict on the existing fbr_* element ids. */
  reasonGridAppended?: boolean;
  /** Whether the reason grid has been replaced with its disabled/chosen state.
   *  CARD-lifetime, card-global element — first reason pick paints it for everyone. */
  reasonRowPainted?: boolean;
}

/** Set a card-lifetime UI flag on the entry for `messageId`, returning true iff the
 *  flag FLIPPED from unset→set on THIS call (i.e. the caller is the first to claim it).
 *  Card-scoped, mark-and-check, tied to entry lifetime (NOT the dedup TTL) so a vote /
 *  reason pick on a still-live card can never re-trigger a one-shot UI write. Returns
 *  false if the card is unknown (evicted/restart) — caller treats that as "don't write". */
export function claimCardUiFlag(messageId: string, flag: "voteRowPainted" | "reasonGridAppended" | "reasonRowPainted"): boolean {
  const e = registry.get(messageId);
  if (!e) return false;
  if (e[flag]) return false;
  e[flag] = true;
  return true;
}

/** FAIL-CLOSED asker check shared by the asker-scoped card actions (stop / feedback /
 *  feedback_reason): true ONLY when the card's asker is known AND equals the operator who
 *  clicked. Returns false if either id is empty/undefined — a card whose asker we can't
 *  verify must NOT let any member act (one card can't become a lever for the whole group:
 *  stop = abort someone's stream, feedback = the single per-card vote a shared-UI card holds).
 *  Pure (no registry access) so it's trivially unit-testable; callers pass entry?.askerOpenId. */
export function isAskerAction(askerOpenId: string | undefined, operatorOpenId: string | undefined): boolean {
  return !!askerOpenId && !!operatorOpenId && askerOpenId === operatorOpenId;
}

/** One prior turn in a replayed conversation chain (oldest→newest order). */
export interface ChainTurn { question?: string; answer?: string }

const registry = new Map<string, CardEntry>();
// Secondary index: cardId → messageId. A card-action callback (feedback / stop) carries the
// CardKit card_id but its `open_message_id` does NOT always equal the message id the card was
// sent + registered under (observed live: feedback denied with card:null because lookup by
// open_message_id missed). With the button value carrying card_id, this lets us resolve the
// SAME CardEntry by card_id when the message-id lookup misses. Kept in sync by rememberCard /
// forgetCard / the eviction path.
const cardIdIndex = new Map<string, string>();

export function rememberCard(
  messageId: string,
  cardId: string,
  sessionId?: string,
  question?: string,
  parentMessageId?: string,
  askerOpenId?: string,
): void {
  if (!messageId || !cardId) return;
  // Re-insert to keep Map insertion order = recency for eviction.
  const prev = registry.get(messageId);
  registry.delete(messageId);
  const clippedQuestion = question === undefined ? undefined : question.slice(0, MAX_QUESTION_CHARS);
  // NOTE: this deliberately does NOT carry over the feedback-UI flags
  // (voteRowPainted / reasonGridAppended / reasonRowPainted) — today there is exactly
  // one call site (at card-send time, before any button exists), so a re-record never
  // races a vote. If a FUTURE edit/re-send path ever re-records an already-answered
  // messageId, it MUST preserve these flags (spread `...prev`) or it reopens the 300315
  // duplicate-element conflict class (a vote after re-record would re-paint/re-append).
  registry.set(messageId, { cardId, sessionId, question: clippedQuestion, answer: prev?.answer, parentMessageId, askerOpenId });
  cardIdIndex.set(cardId, messageId);
  if (registry.size > MAX_ENTRIES) {
    const oldest = registry.keys().next().value;
    if (oldest !== undefined) {
      const evicted = registry.get(oldest);
      registry.delete(oldest);
      // Keep the secondary index in lockstep: only drop the cardId mapping if it still
      // points at the evicted messageId (a re-record may have repointed it elsewhere).
      if (evicted && cardIdIndex.get(evicted.cardId) === oldest) cardIdIndex.delete(evicted.cardId);
    }
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
  // Touch recency on READ, not just write: re-insert every entry this walk visits
  // (oldest→newest) so an ACTIVELY-referenced conversation's early ancestors survive
  // insertion-order eviction. Without this, a long multi-turn thread whose turn-1 is
  // old + buried under 500 newer unrelated cards gets its foundational early turns
  // evicted → collectChain hits the gap and silently truncates mid-conversation
  // (cross-review MEDIUM-HIGH: the deferred-composer's context guarantee would
  // otherwise fail under load). Collect the visited ids first, then bump them.
  const visited: string[] = [];
  let id: string | undefined = messageId;
  while (id && !seen.has(id) && turns.length < MAX_CHAIN_TURNS) {
    seen.add(id);
    const e = registry.get(id);
    if (!e) break;
    visited.push(id);
    // Require a SETTLED answer for the turn to count. A turn with a question but
    // no answer = the card is still streaming (answer stored only at finalize) or
    // it hard-failed (answer never stored). Replaying a bare question the agent
    // can't see the answer to degrades context for the most-relevant turn, so we
    // skip it (but keep walking to its finalized ancestors via parentMessageId).
    if (e.answer) turns.unshift({ question: e.question, answer: e.answer });
    id = e.parentMessageId;
  }
  // Re-insert visited entries oldest-visited→newest so the chain head (the card
  // just acted on) lands at the tail = most-recent recency. Pure recency bump; the
  // entry objects are reused unchanged.
  for (let i = visited.length - 1; i >= 0; i--) {
    const k = visited[i];
    const e = registry.get(k);
    if (e) { registry.delete(k); registry.set(k, e); }
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

/** Resolve a card entry + its messageId by CardKit card_id (the secondary index). Used by
 *  card-action callbacks (feedback / stop) whose `open_message_id` may not match the stored
 *  key — the button value carries card_id, so this is the reliable resolution path. Returns
 *  {messageId, entry} or undefined when unknown (evicted / restart). */
export function lookupByCardId(cardId: string | undefined): { messageId: string; entry: CardEntry } | undefined {
  if (!cardId) return undefined;
  const messageId = cardIdIndex.get(cardId);
  if (!messageId) return undefined;
  const entry = registry.get(messageId);
  return entry ? { messageId, entry } : undefined;
}

export function forgetCard(messageId: string): void {
  const e = registry.get(messageId);
  registry.delete(messageId);
  if (e && cardIdIndex.get(e.cardId) === messageId) cardIdIndex.delete(e.cardId);
}
