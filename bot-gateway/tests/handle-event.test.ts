/**
 * Unit tests for handleMessageEvent — the gateway's IM-event core.
 *
 * Event shape matches the normalized im.message.receive_v1 (chat_id,
 * chat_type, content, event_id, sender_id, ...). The handler only gates and
 * routes (dedup → session route → cleaned prompt); the actual agent invoke is
 * driven by the caller, so the whole flow is testable without AWS or Feishu.
 */

import { handleMessageEvent, type ImEvent } from "../src/handle-event";
import { resetForTesting as resetDedup } from "../src/dedup";
import { resetForTesting as resetSessions } from "../src/session-map";

afterEach(() => {
  resetDedup();
  resetSessions();
});

function evt(overrides: Partial<ImEvent> = {}): ImEvent {
  return {
    event_id: "evt_1",
    chat_id: "oc_chat1",
    chat_type: "p2p", // default p2p: no @-mention needed (group gating tested separately)
    content: "消除判定逻辑在哪",
    message_id: "om_1",
    sender_id: "ou_user1",
    sender_type: "user",
    message_type: "text",
    mentions: [],
    ...overrides,
  };
}

describe("handleMessageEvent", () => {
  it("returns the message text as prompt and a session id", async () => {
    const out = await handleMessageEvent(evt());
    expect(out.handled).toBe(true);
    expect(out.prompt).toBe("消除判定逻辑在哪");
    expect(out.sessionId).toBeTruthy();
  });

  it("skips duplicate event_id (Feishu re-delivery)", async () => {
    const first = await handleMessageEvent(evt({ event_id: "dup" }));
    const second = await handleMessageEvent(evt({ event_id: "dup" }));
    expect(first.handled).toBe(true);
    expect(second.handled).toBe(false);
    expect(second.reason).toBe("duplicate");
  });

  it("does NOT dedup two distinct messages that both lack an event_id", async () => {
    // REGRESSION: a missing event_id normalizes to "" upstream; deduping on "" made
    // ALL no-event_id messages share one key, so the 2nd distinct such message was
    // mis-dropped as a duplicate. With the empty-id skip, both are handled (the unique
    // message_id / msg: guard still provides idempotency downstream).
    const a = await handleMessageEvent(evt({ event_id: "", message_id: "om_a" }));
    const b = await handleMessageEvent(evt({ event_id: "", message_id: "om_b" }));
    expect(a.handled).toBe(true);
    expect(b.handled).toBe(true);
  });

  it("routes same chat+thread to the same session id", async () => {
    const a = await handleMessageEvent(evt({ event_id: "a", chat_id: "oc_x" }));
    const b = await handleMessageEvent(evt({ event_id: "b", chat_id: "oc_x" }));
    expect(a.sessionId).toBe(b.sessionId);
  });

  it("strips a leading @bot mention from the prompt", async () => {
    const out = await handleMessageEvent(
      evt({ content: "@_user_1 消除判定在哪", mentions: [{ key: "@_user_1", open_id: "ou_bot" }] }),
    );
    expect(out.prompt).toBe("消除判定在哪");
  });

  it("strips a NON-leading @bot mention (text before the @)", async () => {
    const out = await handleMessageEvent(
      evt({ content: "请问 @_user_1 消除判定在哪", mentions: [{ key: "@_user_1", open_id: "ou_bot" }] }),
    );
    expect(out.prompt).toBe("请问 消除判定在哪");
    expect(out.prompt).not.toContain("@_user_"); // no dangling placeholder
  });

  it("ignores non-text messages", async () => {
    const out = await handleMessageEvent(evt({ message_type: "image" }));
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("unsupported_type");
  });

  it("ignores non-user senders (no bot-answers-bot loop)", async () => {
    const out = await handleMessageEvent(evt({ sender_type: "bot" }));
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_a_user");
  });

  it("in a GROUP, ignores a message that does not @-mention the bot", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "大家觉得这个数值怎么样", mentions: [] }),
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_mentioned");
  });

  it("in a GROUP, answers when the bot IS @-mentioned", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "@_user_1 消除判定在哪", mentions: [{ key: "@_user_1", open_id: "ou_bot" }] }),
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(true);
    expect(out.prompt).toBe("消除判定在哪");
  });

  it("in a GROUP with another user @-mentioned (not the bot), stays silent", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "@_user_2 你看看", mentions: [{ key: "@_user_2", open_id: "ou_someone_else" }] }),
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_mentioned");
  });

  it("p2p answers without requiring an @-mention", async () => {
    const out = await handleMessageEvent(evt({ chat_type: "p2p", mentions: [] }), { botOpenId: "ou_bot" });
    expect(out.handled).toBe(true);
  });

  it("FAILS CLOSED on an UNKNOWN chat_type: requires the @-gate, not un-gated p2p (cross-review P1)", async () => {
    // A future/unknown chat_type (e.g. a topic-group) must NOT be answered without an
    // @-mention. Gating on `!== "p2p"` means anything non-p2p needs the gate.
    const out = await handleMessageEvent(
      evt({ chat_type: "topic" as unknown as "group", content: "大家随便聊", mentions: [] }),
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_mentioned");
  });

  it("an UNKNOWN chat_type WITH an @bot mention IS answered (gate satisfied)", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "topic" as unknown as "group", content: "@_user_1 看下", mentions: [{ key: "@_user_1", open_id: "ou_bot" }] }),
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(true);
  });

  it("ignores a message whose sender IS the bot itself (self-loop defense-in-depth)", async () => {
    // Even mislabeled sender_type="user", an open_id match to the bot must be dropped.
    const out = await handleMessageEvent(
      evt({ chat_type: "p2p", sender_id: "ou_bot", sender_type: "user", mentions: [] }),
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("self_message");
  });

  it("in a GROUP, answers the ASKER's bare reply to one of OUR bot cards (implicit mention)", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "那骷髅呢", mentions: [], parent_id: "om_ourcard", sender_id: "ou_asker" }),
      { botOpenId: "ou_bot", isAskerReply: (pid, sid) => pid === "om_ourcard" && sid === "ou_asker" },
    );
    expect(out.handled).toBe(true);
    expect(out.parentId).toBe("om_ourcard");
    expect(out.senderId).toBe("ou_asker");
    expect(out.prompt).toBe("那骷髅呢");
  });

  it("surfaces the upstream event_id on a handled result (so a failed first send can roll it back)", async () => {
    // The IM dedup gate burns event_id; if the FIRST card-send then fails, the
    // gateway must roll back THIS event_id (not just the msg: key) so Feishu's
    // re-delivery — which carries the same event_id — isn't dropped at the gate
    // and can retry. That rollback needs the event_id surfaced here.
    const out = await handleMessageEvent(
      evt({ event_id: "evt_rollback", chat_type: "p2p", mentions: [] }),
    );
    expect(out.handled).toBe(true);
    expect(out.eventId).toBe("evt_rollback");
  });

  it("in a GROUP, a reply to OUR card by a DIFFERENT member (not the asker) is not auto-answered", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "我也想知道", mentions: [], parent_id: "om_ourcard", sender_id: "ou_other" }),
      { botOpenId: "ou_bot", isAskerReply: (pid, sid) => pid === "om_ourcard" && sid === "ou_asker" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("reply_to_unknown_card");
  });

  it("in a GROUP, a reply to an unknown/evicted card reports reply_to_unknown_card (diagnosable, not silent)", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "收到", mentions: [], parent_id: "om_evicted", sender_id: "ou_asker" }),
      { botOpenId: "ou_bot", isAskerReply: () => false },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("reply_to_unknown_card");
  });

  it("a non-reply non-mention in a GROUP is still a plain not_mentioned (no parent_id)", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "随便聊聊", mentions: [] }),
      { botOpenId: "ou_bot", isAskerReply: () => false },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_mentioned");
  });

  it("a card with an UNKNOWN asker (empty askerOpenId) does NOT auto-answer a bare reply — fail closed", async () => {
    // Mirror the real index.ts wiring: isAskerReply requires a non-empty stored
    // askerOpenId AND a non-empty senderId that matches. An empty stored asker
    // must NOT match any sender (else any member could drive invokes off the card).
    const realPredicate = (storedAsker: string) => (pid: string, sid: string) =>
      pid === "om_ourcard" && !!storedAsker && !!sid && storedAsker === sid;
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "我也回复一下", mentions: [], parent_id: "om_ourcard", sender_id: "ou_anyone" }),
      { botOpenId: "ou_bot", isAskerReply: realPredicate("") /* asker unknown */ },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("reply_to_unknown_card");
  });

  it("FAILS CLOSED on empty/absent sender_type (treated as not-a-user, no cross-bot loop)", async () => {
    // p2p so the mention gate can't be the thing rejecting it — only the user gate should.
    const out = await handleMessageEvent(
      evt({ chat_type: "p2p", sender_type: "", mentions: [] }),
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_a_user");
  });
});
