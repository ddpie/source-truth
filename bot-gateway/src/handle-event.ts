/**
 * IM-event core for the gateway.
 *
 * Consumes a normalized Feishu im.message.receive_v1 event, dedups
 * re-deliveries, routes to a runtimeSessionId, and decides whether/what to
 * answer. Pure gating + routing — the actual streaming invoke is driven by
 * the caller (src/index.ts) from the returned HandleResult.
 *
 * The real long-connection subscriber (src/index.ts) feeds events here; that
 * piece needs bot identity + IM scopes and is wired separately.
 */

import { isDuplicate } from "./dedup";
import { getSessionState } from "./session-map";
import { ackWithReaction } from "./reaction";

/** One @-mention inside a message: `key` is the inline placeholder token in
 *  content.text (e.g. "@_user_1"); `open_id` is who it resolves to. */
export interface Mention {
  key: string;
  open_id: string;
  name?: string;
}

/** Normalized im.message.receive_v1 (subset we use). Matches lark-cli output. */
export interface ImEvent {
  event_id: string;
  chat_id: string;
  chat_type: "p2p" | "group";
  content: string;
  message_id: string;
  sender_id: string;
  sender_type: string;
  message_type: string;
  mentions: Mention[];
  thread_id?: string;
  /** message_id this message replies to (Feishu 回复/引用), if any. */
  parent_id?: string;
}

export interface HandleResult {
  handled: boolean;
  /** The cleaned question text (mentions stripped) to send to the agent. */
  prompt?: string;
  sessionId?: string;
  /** True when this turn's sessionId was freshly minted (no warm microVM behind it
   *  → AgentCore cold start: spin-up + routing folded into the first response). Used
   *  for cold-start telemetry (frequency + duration). A reused (warm) session is false. */
  coldStart?: boolean;
  messageId?: string;
  /** message_id this message replied to (for follow-up context replay), if any. */
  parentId?: string;
  /** open_id of the asker, remembered on the card so a later bare reply by the
   *  same user is auto-answered (scopes the group reply bypass to the asker). */
  senderId?: string;
  /** Upstream Feishu event_id (idempotency key burned by the dedup gate above).
   *  Surfaced so a failed first card-send can roll it back and let the re-delivery
   *  retry — the `msg:` key alone can't, since the re-delivery hits this event_id
   *  gate first. */
  eventId?: string;
  reason?: "duplicate" | "unsupported_type" | "empty" | "not_mentioned" | "not_a_user" | "self_message" | "reply_to_unknown_card";
}

/** Options that gate WHEN to answer. botOpenId is the bot's own open_id; when
 *  set, group messages are answered only if the bot was @-mentioned.
 *  isAskerReply(parentId, senderId) returns true when a message replies to one of
 *  OUR bot cards AND the replier is the user who asked that card's question — such
 *  a reply is unambiguous intent toward the bot from the conversation owner, so it
 *  counts as an implicit @-mention (one card can't let every group member trigger
 *  an invoke, and a bot can't match an asker). Injected as a predicate so this
 *  module stays decoupled from the card registry / testable. */
export interface HandleOptions {
  botOpenId?: string;
  isAskerReply?: (parentId: string, senderId: string) => boolean;
}

/**
 * Strip @-mention tokens from the message text. Feishu inlines each mention as a
 * placeholder ("@_user_N") wherever it appears (not only leading), with the real
 * id in `mentions[]`. Remove every known placeholder token anywhere in the text,
 * then fall back to a global non-anchored pattern for any stray "@_user_N".
 */
function stripMentions(text: string, mentions: Mention[]): string {
  let out = text;
  for (const m of mentions) {
    if (m.key) out = out.split(m.key).join(" ");
  }
  out = out.replace(/@_user_\d+/g, " ");
  return out.replace(/\s+/g, " ").trim();
}

export async function handleMessageEvent(
  event: ImEvent,
  options: HandleOptions = {},
): Promise<HandleResult> {
  // 1. Dedup — Feishu re-delivers events; event_id is the idempotency key. Guard on
  //    a NON-EMPTY event_id only: a missing event_id normalizes to "" (sdk-event.ts),
  //    and deduping on "" would make ALL no-event_id messages share one key — the
  //    second distinct such message would be mis-dropped as a "duplicate" and the user
  //    gets no answer. When event_id is absent, skip this gate and rely on the
  //    per-message `msg:<messageId>` guard downstream (message_id is unique per
  //    message), so idempotency still holds (cross-review CONFIRMED).
  if (event.event_id && isDuplicate(event.event_id)) {
    return { handled: false, reason: "duplicate" };
  }

  // 2. Only answer real human users — never another bot / system message (a bot
  //    answering a bot's plain text in a group is a cross-bot loop/cost path).
  //    FAIL CLOSED: an absent/empty sender_type must NOT be treated as a user
  //    (the only safe answer is a clear "user"); otherwise an event with a missing
  //    sender_type slips through and, combined with the card-reply bypass below,
  //    re-opens the very loop this gate closes.
  if (event.sender_type !== "user") {
    return { handled: false, reason: "not_a_user" };
  }
  // 2b. Defense-in-depth self-loop guard: never act on a message whose sender IS the
  //     bot. The sender_type filter above already blocks this IF Feishu always labels
  //     the bot's own outgoing messages non-"user" — but a single mislabeled event
  //     (a tenant/app-as-user identity surprise) would re-open the echo loop, and the
  //     bot's plain-text FALLBACK reply is a `text` message that could re-enter. An
  //     explicit open_id match makes the guard robust to any sender_type labeling
  //     surprise (cross-review P2). No-op when botOpenId is unconfigured.
  if (options.botOpenId && event.sender_id === options.botOpenId) {
    return { handled: false, reason: "self_message" };
  }

  // 3. Accept text questions, including the textual part of a rich-text post.
  // Images/files alone remain unsupported; the adapter never passes media.
  if (event.message_type !== "text" && event.message_type !== "post") {
    return { handled: false, reason: "unsupported_type" };
  }

  // 4. In a GROUP, answer only when the bot is @-mentioned (matches the design:
  //    "策划在群里 @机器人 提问"). Without this the bot replies to every line from
  //    anyone — unsolicited answers + runaway cost. Only a true 1:1 private chat
  //    (`p2p`) skips the @-gate.
  //    FAIL CLOSED on chat_type: gate on `!== "p2p"` (NOT `=== "group"`). Feishu today
  //    emits only p2p/group, but an unknown/future type (e.g. a topic-group) cast
  //    through here must REQUIRE the @-mention, not fall through as un-gated p2p and let
  //    the bot answer every message from anyone (cross-review P1: `=== "group"` failed
  //    OPEN on any unrecognized chat_type).
  //    Gate requires the bot's own open_id; if it isn't configured we can't tell
  //    which mention is the bot, so fall back to "any mention present".
  if (event.chat_type !== "p2p") {
    const mentioned = options.botOpenId
      ? event.mentions.some((m) => m.open_id === options.botOpenId)
      : event.mentions.length > 0;
    // A reply by the original asker to one of our own bot cards is addressed to
    // the bot just as unambiguously as an @-mention — treat it as an implicit
    // mention so reply-based follow-ups work in groups without forcing the user
    // to also @. (Scoped to the asker so one card can't let every group member
    // trigger an invoke, and a bot reply never matches an asker.)
    const repliesToOurCard =
      !!event.parent_id && !!options.isAskerReply && options.isAskerReply(event.parent_id, event.sender_id);
    if (!mentioned && !repliesToOurCard) {
      // Distinguish "replied to a card we no longer know / not the asker" from a
      // plain non-mention, so silent drops (restart/eviction) are diagnosable.
      const reason = event.parent_id ? "reply_to_unknown_card" : "not_mentioned";
      return { handled: false, reason };
    }
  }

  const prompt = stripMentions(event.content, event.mentions);
  if (!prompt) {
    return { handled: false, reason: "empty" };
  }

  // 3. Immediately react so the user knows we're on it (fire-and-forget).
  if (event.message_id) ackWithReaction(event.message_id);

  // 4. Route to a stable session (same chat+thread reuses one warm microVM).
  //    `cold` = freshly minted session → AgentCore cold start (no warm VM yet).
  const { sessionId, cold } = getSessionState(event.chat_id, event.thread_id);

  return { handled: true, prompt, sessionId, coldStart: cold, messageId: event.message_id, parentId: event.parent_id, senderId: event.sender_id, eventId: event.event_id };
}
