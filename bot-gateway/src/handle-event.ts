/**
 * IM-event core for the gateway.
 *
 * Consumes a normalized Feishu im.message.receive_v1 event (the shape lark-cli
 * delivers), dedups re-deliveries, routes to a runtimeSessionId, and invokes
 * the agent. The agent invoke is injected so this is testable without AWS or a
 * live Feishu long-connection.
 *
 * The real long-connection subscriber (src/index.ts) feeds events here; that
 * piece needs bot identity + IM scopes and is wired separately.
 */

import { isDuplicate } from "./dedup";
import { getSessionId } from "./session-map";
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

/** Invoke the agent for a session; returns the answer text. */
export type InvokeFn = (sessionId: string, prompt: string) => Promise<string>;

export interface HandleResult {
  handled: boolean;
  answer?: string;
  sessionId?: string;
  messageId?: string;
  /** message_id this message replied to (for follow-up context replay), if any. */
  parentId?: string;
  reason?: "duplicate" | "unsupported_type" | "empty" | "not_mentioned" | "not_a_user";
}

/** Options that gate WHEN to answer. botOpenId is the bot's own open_id; when
 *  set, group messages are answered only if the bot was @-mentioned.
 *  isKnownCard(parentId) returns true when a message replies to one of OUR bot
 *  cards — such a reply is unambiguous intent toward the bot, so it counts as an
 *  implicit @-mention (the user replied directly to our answer). Injected as a
 *  predicate so this module stays decoupled from the card registry / testable. */
export interface HandleOptions {
  botOpenId?: string;
  isKnownCard?: (parentId: string) => boolean;
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
  deps: { invoke: InvokeFn },
  options: HandleOptions = {},
): Promise<HandleResult> {
  // 1. Dedup — Feishu re-delivers events; event_id is the idempotency key.
  if (isDuplicate(event.event_id)) {
    return { handled: false, reason: "duplicate" };
  }

  // 2. Only answer real human users — never another bot / system message (a bot
  //    answering a bot's plain text in a group is a cross-bot loop/cost path).
  if (event.sender_type && event.sender_type !== "user") {
    return { handled: false, reason: "not_a_user" };
  }

  // 3. Only text messages are answered in MVP.
  if (event.message_type !== "text") {
    return { handled: false, reason: "unsupported_type" };
  }

  // 4. In a GROUP, answer only when the bot is @-mentioned (matches the design:
  //    "策划在群里 @机器人 提问"). Without this the bot replies to every line from
  //    anyone — unsolicited answers + runaway cost. p2p/private chat needs no @.
  //    Gate requires the bot's own open_id; if it isn't configured we can't tell
  //    which mention is the bot, so fall back to "any mention present".
  if (event.chat_type === "group") {
    const mentioned = options.botOpenId
      ? event.mentions.some((m) => m.open_id === options.botOpenId)
      : event.mentions.length > 0;
    // A reply to one of our own bot cards is addressed to the bot just as
    // unambiguously as an @-mention — treat it as an implicit mention so
    // reply-based follow-ups work in groups without forcing the user to also @.
    const repliesToOurCard =
      !!event.parent_id && !!options.isKnownCard && options.isKnownCard(event.parent_id);
    if (!mentioned && !repliesToOurCard) {
      return { handled: false, reason: "not_mentioned" };
    }
  }

  const prompt = stripMentions(event.content, event.mentions);
  if (!prompt) {
    return { handled: false, reason: "empty" };
  }

  // 3. Immediately react so the user knows we're on it (fire-and-forget).
  if (event.message_id) ackWithReaction(event.message_id);

  // 4. Route to a stable session (same chat+thread reuses one warm microVM).
  const sessionId = getSessionId(event.chat_id, event.thread_id);

  // 4. Invoke the agent.
  const answer = await deps.invoke(sessionId, prompt);
  return { handled: true, answer, sessionId, messageId: event.message_id, parentId: event.parent_id };
}
