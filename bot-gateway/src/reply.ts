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

/** Send a plain text reply in-process. Resolves when the reply is accepted. */
export async function sendReply(p: ReplyParams): Promise<void> {
  await imReply(p.messageId, "text", buildTextContent(p.answer));
}

/** Reply to a message with an already-created interactive card (in-process). */
function sendCardAsReply(messageId: string, cardId: string): Promise<void> {
  return imReply(messageId, "interactive", buildSendCardContent(cardId)).then(() => undefined);
}

/**
 * Reply with a CardKit "growing answer card": create → stream → close → send.
 * This is the production reply path; sendReply (markdown) stays as a fallback.
 */
export async function sendReplyCard(p: ReplyParams & { title?: string }): Promise<string> {
  return replyWithCard(
    { messageId: p.messageId, answer: p.answer, title: p.title ?? "source-truth" },
    { createCard, updateContent, closeStreaming, sendCard: sendCardAsReply },
  );
}
