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

const PROCESSING_EMOJI = "OnIt";

// messageId → reaction_id of the "processing" reaction we added, so we can delete
// exactly that one. Bounded so it can't grow without limit in the always-on
// gateway (a reaction is short-lived; oldest entries are safe to forget).
const MAX = 500;
const reactionIds = new Map<string, string>();

function log(event: string, messageId: string, extra: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ ts: new Date().toISOString(), event, message: hashUserId(messageId), ...extra }));
}

/** Add a "processing" reaction to a message. Best-effort (never throws). */
export function ackWithReaction(messageId: string): void {
  if (!feishuConfigured()) return; // no creds (tests / un-provisioned) → skip, no network
  void imAddReaction(messageId, PROCESSING_EMOJI)
    .then((reactionId) => {
      if (!reactionId) return;
      reactionIds.set(messageId, reactionId);
      if (reactionIds.size > MAX) {
        const oldest = reactionIds.keys().next().value;
        if (oldest !== undefined) reactionIds.delete(oldest);
      }
    })
    .catch((e) => log("reaction_add_error", messageId, { error: String(e) }));
}

/** Remove the processing reaction after the real reply is sent. Best-effort.
 *  Idempotent: a missing/forgotten id is a no-op (safe to call more than once). */
export function removeReaction(messageId: string): void {
  const reactionId = reactionIds.get(messageId);
  if (!reactionId) return; // never added, already removed, or evicted — nothing to do
  reactionIds.delete(messageId);
  void imDeleteReaction(messageId, reactionId)
    .catch((e) => log("reaction_delete_error", messageId, { error: String(e) }));
}
