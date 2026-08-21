/**
 * Quick emoji reaction to acknowledge a message before the agent answers.
 *
 * Gives instant "seen, processing" feedback; the CardKit answer card arrives
 * seconds later. In-process Feishu OpenAPI (was `spawn lark-cli`): the add call
 * returns the reaction_id, which we remember so removeReaction can delete it
 * directly — no more query-then-delete round-trip. Best-effort throughout: a
 * reaction is a visual nicety and must never throw into the answer path.
 */

import { imAddReaction, imDeleteReaction, feishuConfigured } from "./feishu-http";
import { hashUserId } from "./log";
import { redactSensitive } from "./redact";

const PROCESSING_EMOJI = "OnIt";

// messageId → reaction_id of the "processing" reaction we added, so we can delete
// exactly that one. Bounded so it can't grow without limit in the always-on
// gateway (a reaction is short-lived; oldest entries are safe to forget).
const MAX = 500;
const reactionIds = new Map<string, string>();
// messageIds for which removeReaction ran BEFORE the add's network round-trip
// resolved (so the id wasn't in the map yet). Under load imAddReaction can be slower
// than createCard+imReply, so removeReaction would no-op and the OnIt emoji would
// stay stuck forever once the add finally lands. The add's .then consults this set
// and deletes the just-created reaction immediately rather than storing an orphan
// id (cross-review P1 — TOCTOU only visible under high latency / Feishu throttle).
const pendingRemoval = new Set<string>();

function log(event: string, messageId: string, extra: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ ts: new Date().toISOString(), event, message: hashUserId(messageId), ...extra }));
}

function deleteReaction(messageId: string, reactionId: string): void {
  void imDeleteReaction(messageId, reactionId)
    .catch((e) => log("reaction_delete_error", messageId, { error: redactSensitive(String(e)).slice(0, 200) }));
}

/** Add a "processing" reaction to a message. Best-effort (never throws). */
export function ackWithReaction(messageId: string): void {
  if (!feishuConfigured()) return; // no creds (tests / un-provisioned) → skip, no network
  void imAddReaction(messageId, PROCESSING_EMOJI)
    .then((reactionId) => {
      if (!reactionId) return;
      // If removeReaction already fired while this add was in flight, the caller has
      // moved on (card sent) and wants the emoji GONE — delete it now instead of
      // storing an id nothing will ever remove.
      if (pendingRemoval.delete(messageId)) {
        deleteReaction(messageId, reactionId);
        return;
      }
      reactionIds.set(messageId, reactionId);
      if (reactionIds.size > MAX) {
        const oldest = reactionIds.keys().next().value;
        if (oldest !== undefined) reactionIds.delete(oldest);
      }
    })
    .catch((e) => log("reaction_add_error", messageId, { error: redactSensitive(String(e)).slice(0, 200) }));
}

/** Remove the processing reaction after the real reply is sent. Best-effort.
 *  Idempotent: a missing/forgotten id is a no-op (safe to call more than once). */
export function removeReaction(messageId: string): void {
  const reactionId = reactionIds.get(messageId);
  if (!reactionId) {
    // The add hasn't resolved yet (id not stored) — record the intent so the add's
    // .then deletes it on arrival. Bounded so a stream of never-added ids (e.g. a
    // creds-less window) can't grow it unbounded; a reaction is short-lived.
    pendingRemoval.add(messageId);
    if (pendingRemoval.size > MAX) {
      const oldest = pendingRemoval.values().next().value;
      if (oldest !== undefined) pendingRemoval.delete(oldest);
    }
    return;
  }
  reactionIds.delete(messageId);
  deleteReaction(messageId, reactionId);
}
