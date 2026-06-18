/**
 * Unit tests for handleMessageEvent — the gateway's IM-event core.
 *
 * Event shape matches lark-cli's normalized im.message.receive_v1 (chat_id,
 * chat_type, content, event_id, sender_id, ...). The agent invoke is injected
 * so the whole flow (dedup → session route → invoke) is testable without AWS
 * or Feishu.
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
  it("invokes the agent with the message text and a session id", async () => {
    const calls: Array<{ prompt: string; sessionId: string }> = [];
    const invoke = async (sessionId: string, prompt: string) => {
      calls.push({ sessionId, prompt });
      return "answer: 2";
    };
    const out = await handleMessageEvent(evt(), { invoke });
    expect(out.handled).toBe(true);
    expect(out.answer).toBe("answer: 2");
    expect(calls).toHaveLength(1);
    expect(calls[0].prompt).toBe("消除判定逻辑在哪");
    expect(calls[0].sessionId).toBeTruthy();
  });

  it("skips duplicate event_id (Feishu re-delivery)", async () => {
    let n = 0;
    const invoke = async () => {
      n++;
      return "ok";
    };
    await handleMessageEvent(evt({ event_id: "dup" }), { invoke });
    const second = await handleMessageEvent(evt({ event_id: "dup" }), { invoke });
    expect(n).toBe(1);
    expect(second.handled).toBe(false);
    expect(second.reason).toBe("duplicate");
  });

  it("routes same chat+thread to the same session id", async () => {
    const seen: string[] = [];
    const invoke = async (sessionId: string) => {
      seen.push(sessionId);
      return "ok";
    };
    await handleMessageEvent(evt({ event_id: "a", chat_id: "oc_x" }), { invoke });
    await handleMessageEvent(evt({ event_id: "b", chat_id: "oc_x" }), { invoke });
    expect(seen[0]).toBe(seen[1]);
  });

  it("strips a leading @bot mention from the prompt", async () => {
    let captured = "";
    const invoke = async (_s: string, prompt: string) => {
      captured = prompt;
      return "ok";
    };
    await handleMessageEvent(
      evt({ content: "@_user_1 消除判定在哪", mentions: [{ key: "@_user_1", open_id: "ou_bot" }] }),
      { invoke },
    );
    expect(captured).toBe("消除判定在哪");
  });

  it("strips a NON-leading @bot mention (text before the @)", async () => {
    let captured = "";
    const invoke = async (_s: string, prompt: string) => {
      captured = prompt;
      return "ok";
    };
    await handleMessageEvent(
      evt({ content: "请问 @_user_1 消除判定在哪", mentions: [{ key: "@_user_1", open_id: "ou_bot" }] }),
      { invoke },
    );
    expect(captured).toBe("请问 消除判定在哪");
    expect(captured).not.toContain("@_user_"); // no dangling placeholder
  });

  it("ignores non-text messages", async () => {
    let n = 0;
    const invoke = async () => {
      n++;
      return "ok";
    };
    const out = await handleMessageEvent(evt({ message_type: "image" }), { invoke });
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("unsupported_type");
    expect(n).toBe(0);
  });

  it("ignores non-user senders (no bot-answers-bot loop)", async () => {
    let n = 0;
    const invoke = async () => { n++; return "ok"; };
    const out = await handleMessageEvent(evt({ sender_type: "bot" }), { invoke });
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_a_user");
    expect(n).toBe(0);
  });

  it("in a GROUP, ignores a message that does not @-mention the bot", async () => {
    let n = 0;
    const invoke = async () => { n++; return "ok"; };
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "大家觉得这个数值怎么样", mentions: [] }),
      { invoke },
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_mentioned");
    expect(n).toBe(0);
  });

  it("in a GROUP, answers when the bot IS @-mentioned", async () => {
    let captured = "";
    const invoke = async (_s: string, prompt: string) => { captured = prompt; return "ok"; };
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "@_user_1 消除判定在哪", mentions: [{ key: "@_user_1", open_id: "ou_bot" }] }),
      { invoke },
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(true);
    expect(captured).toBe("消除判定在哪");
  });

  it("in a GROUP with another user @-mentioned (not the bot), stays silent", async () => {
    let n = 0;
    const invoke = async () => { n++; return "ok"; };
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "@_user_2 你看看", mentions: [{ key: "@_user_2", open_id: "ou_someone_else" }] }),
      { invoke },
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_mentioned");
    expect(n).toBe(0);
  });

  it("p2p answers without requiring an @-mention", async () => {
    const out = await handleMessageEvent(evt({ chat_type: "p2p", mentions: [] }), { invoke: async () => "ok" }, { botOpenId: "ou_bot" });
    expect(out.handled).toBe(true);
  });

  it("in a GROUP, answers the ASKER's bare reply to one of OUR bot cards (implicit mention)", async () => {
    let captured = "";
    const invoke = async (_s: string, prompt: string) => { captured = prompt; return "ok"; };
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "那骷髅呢", mentions: [], parent_id: "om_ourcard", sender_id: "ou_asker" }),
      { invoke },
      { botOpenId: "ou_bot", isAskerReply: (pid, sid) => pid === "om_ourcard" && sid === "ou_asker" },
    );
    expect(out.handled).toBe(true);
    expect(out.parentId).toBe("om_ourcard");
    expect(out.senderId).toBe("ou_asker");
    expect(captured).toBe("那骷髅呢");
  });

  it("in a GROUP, a reply to OUR card by a DIFFERENT member (not the asker) is not auto-answered", async () => {
    let n = 0;
    const invoke = async () => { n++; return "ok"; };
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "我也想知道", mentions: [], parent_id: "om_ourcard", sender_id: "ou_other" }),
      { invoke },
      { botOpenId: "ou_bot", isAskerReply: (pid, sid) => pid === "om_ourcard" && sid === "ou_asker" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("reply_to_unknown_card");
    expect(n).toBe(0);
  });

  it("in a GROUP, a reply to an unknown/evicted card reports reply_to_unknown_card (diagnosable, not silent)", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "收到", mentions: [], parent_id: "om_evicted", sender_id: "ou_asker" }),
      { invoke: async () => "ok" },
      { botOpenId: "ou_bot", isAskerReply: () => false },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("reply_to_unknown_card");
  });

  it("a non-reply non-mention in a GROUP is still a plain not_mentioned (no parent_id)", async () => {
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "随便聊聊", mentions: [] }),
      { invoke: async () => "ok" },
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
    let n = 0;
    const invoke = async () => { n++; return "ok"; };
    const out = await handleMessageEvent(
      evt({ chat_type: "group", content: "我也回复一下", mentions: [], parent_id: "om_ourcard", sender_id: "ou_anyone" }),
      { invoke },
      { botOpenId: "ou_bot", isAskerReply: realPredicate("") /* asker unknown */ },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("reply_to_unknown_card");
    expect(n).toBe(0);
  });

  it("FAILS CLOSED on empty/absent sender_type (treated as not-a-user, no cross-bot loop)", async () => {
    let n = 0;
    const invoke = async () => { n++; return "ok"; };
    // p2p so the mention gate can't be the thing rejecting it — only the user gate should.
    const out = await handleMessageEvent(
      evt({ chat_type: "p2p", sender_type: "", mentions: [] }),
      { invoke },
      { botOpenId: "ou_bot" },
    );
    expect(out.handled).toBe(false);
    expect(out.reason).toBe("not_a_user");
    expect(n).toBe(0);
  });
});
