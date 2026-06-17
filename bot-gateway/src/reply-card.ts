/**
 * replyWithCard — orchestrates the "growing answer card" reply.
 *
 * Lifecycle: create streaming card → stream the answer into the conclusion
 * element → close streaming (final state) → send the card as a reply to the
 * originating message. CardKit ops + send are injected (CardOps) so the
 * ordering is unit-testable; the real wiring is in src/reply.ts.
 *
 * Sequence numbers increase monotonically across content + close (CardKit
 * rejects out-of-order updates).
 */

export interface CardOps {
  createCard: (title: string) => Promise<string>;
  updateContent: (cardId: string, content: string, sequence: number) => Promise<void>;
  closeStreaming: (cardId: string, sequence: number) => Promise<void>;
  sendCard: (messageId: string, cardId: string) => Promise<void>;
}

export interface CardReplyParams {
  messageId: string;
  answer: string;
  title: string;
}

export async function replyWithCard(p: CardReplyParams, ops: CardOps): Promise<string> {
  const cardId = await ops.createCard(p.title);

  let seq = 1;
  // MVP: write the final answer in one streamed update. (Token-by-token
  // streaming from the agent is a later enhancement on this same path.)
  await ops.updateContent(cardId, p.answer, seq++);

  // Close streaming so the card settles into its final, forwardable state
  // before we send it (also clears the "generating" preview).
  await ops.closeStreaming(cardId, seq++);

  await ops.sendCard(p.messageId, cardId);
  return cardId;
}
