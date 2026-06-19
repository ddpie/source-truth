/**
 * Reply the agent's answer back to Feishu.
 *
 * Closes the loop with a bot reply to the originating message via the in-process
 * Feishu OpenAPI (was `spawn lark-cli`; the direct HTTP call is ~800ms cheaper and
 * keeps the gateway off the lark-cli binary for the answer path). The richer
 * CardKit streaming card is layered on the same reply path.
 */

import { createCard, updateContent, closeStreaming, buildSendCardContent } from "./cardkit-client";
import { imReply } from "./feishu-http";
import { replyWithCard } from "./reply-card";

export interface ReplyParams {
  messageId: string;
  answer: string;
}

/** Build the Feishu text-message content payload (JSON string). */
export function buildTextContent(answer: string): string {
  return JSON.stringify({ text: answer });
}

/** Send a plain text reply in-process. Resolves when the reply is accepted.
 *  LIVE: used as the error/serviceError fallback (index.ts) when the streaming
 *  card path can't run. */
export async function sendReply(p: ReplyParams): Promise<void> {
  await imReply(p.messageId, "text", buildTextContent(p.answer));
}

/** Reply to a message with an already-created interactive card (in-process). */
function sendCardAsReply(messageId: string, cardId: string): Promise<void> {
  return imReply(messageId, "interactive", buildSendCardContent(cardId)).then(() => undefined);
}

/**
 * @deprecated NOT the live path. The production streaming card is driven by
 * streamingCardInvoke → sendStreamingCard → runStreamingInvoke in index.ts, which
 * captures the sent message_id directly for the follow-up registry. This wrapper
 * (and reply-card.ts's replyWithCard) returns only the card_id, NOT the message_id,
 * so wiring it to rememberCard would silently break follow-up chaining — do not
 * revive without threading message_id out first. Kept only for its unit test.
 */
export async function sendReplyCard(p: ReplyParams & { title?: string }): Promise<string> {
  return replyWithCard(
    { messageId: p.messageId, answer: p.answer, title: p.title ?? "source-truth" },
    { createCard, updateContent, closeStreaming, sendCard: sendCardAsReply },
  );
}
