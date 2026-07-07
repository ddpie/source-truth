/**
 * Reply the agent's answer back to Feishu.
 *
 * Closes the loop with a bot reply to the originating message via the in-process
 * Feishu OpenAPI (was `spawn lark-cli`; the direct HTTP call is ~800ms cheaper and
 * keeps the gateway off the lark-cli binary for the answer path). The richer
 * CardKit streaming card is layered on the same reply path.
 */

import { imReply } from "./feishu-http";

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
  // Idempotency key stable per replied-to message so a transport retry can't post a
  // second fallback text into the chat (cross-review H1). One message gets at most one
  // fallback, so keying on messageId is both stable (dedupe retries) and distinct.
  await imReply(p.messageId, "text", buildTextContent(p.answer), `reply-text-${p.messageId}`);
}
