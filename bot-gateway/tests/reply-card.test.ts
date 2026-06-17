/**
 * Unit tests for replyWithCard — orchestrates the growing-card lifecycle:
 * create -> stream content -> close streaming -> send card as a reply.
 * CardKit ops + send are injected, so the orchestration order is testable
 * without hitting Feishu.
 */

import { replyWithCard, type CardOps } from "../src/reply-card";

function recordingOps(): { ops: CardOps; calls: string[] } {
  const calls: string[] = [];
  const ops: CardOps = {
    createCard: async (title) => {
      calls.push(`create:${title}`);
      return "card_1";
    },
    updateContent: async (id, content, seq) => {
      calls.push(`update:${id}:${content}:${seq}`);
    },
    closeStreaming: async (id, seq) => {
      calls.push(`close:${id}:${seq}`);
    },
    sendCard: async (messageId, cardId) => {
      calls.push(`send:${messageId}:${cardId}`);
    },
  };
  return { ops, calls };
}

describe("replyWithCard", () => {
  it("creates, streams the answer, closes streaming, then sends the card", async () => {
    const { ops, calls } = recordingOps();
    await replyWithCard({ messageId: "om_1", answer: "**1+1 = 2**", title: "source-truth" }, ops);
    expect(calls[0]).toBe("create:source-truth");
    expect(calls.some((c) => c.startsWith("update:card_1:**1+1 = 2**"))).toBe(true);
    const closeIdx = calls.findIndex((c) => c.startsWith("close:card_1"));
    const sendIdx = calls.findIndex((c) => c.startsWith("send:om_1:card_1"));
    expect(closeIdx).toBeGreaterThan(0);
    // Card is sent after streaming is closed (final, non-streaming state).
    expect(sendIdx).toBeGreaterThan(closeIdx);
  });

  it("uses increasing sequence numbers across content + close", async () => {
    const { ops, calls } = recordingOps();
    await replyWithCard({ messageId: "om_1", answer: "ans", title: "t" }, ops);
    const seqs = calls
      .map((c) => c.match(/:(\d+)$/)?.[1])
      .filter((s): s is string => Boolean(s))
      .map(Number);
    const sorted = [...seqs].sort((a, b) => a - b);
    expect(seqs).toEqual(sorted); // monotonically increasing
  });
});
