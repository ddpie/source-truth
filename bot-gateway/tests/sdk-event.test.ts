/**
 * Unit tests for sdkEventToImEvent — adapts the Feishu SDK's nested
 * im.message.receive_v1 event into the flat ImEvent shape the gateway core
 * expects (the shape lark-cli used to deliver). Captured from a live event.
 */

import { sdkEventToImEvent } from "../src/sdk-event";

// Real event shape captured live from @larksuiteoapi/node-sdk WSClient.
const LIVE_EVENT = {
  schema: "2.0",
  event_id: "d1529900790228daff5d295f10865304",
  event_type: "im.message.receive_v1",
  message: {
    chat_id: "oc_c9bce1d07bf0a51c82507473c336eda8",
    chat_type: "p2p",
    content: '{"text":"session-map 有几种状态"}',
    message_id: "om_x100b6c1c66b6f4a8c287a839b12804e",
    message_type: "text",
  },
  sender: {
    sender_id: { open_id: "ou_208edaa2b50e6e7343cf110f1d051a47" },
    sender_type: "user",
  },
};

describe("sdkEventToImEvent", () => {
  it("flattens the nested SDK event into ImEvent", () => {
    const ev = sdkEventToImEvent(LIVE_EVENT);
    expect(ev).not.toBeNull();
    expect(ev!.event_id).toBe("d1529900790228daff5d295f10865304");
    expect(ev!.chat_id).toBe("oc_c9bce1d07bf0a51c82507473c336eda8");
    expect(ev!.chat_type).toBe("p2p");
    expect(ev!.message_id).toBe("om_x100b6c1c66b6f4a8c287a839b12804e");
    expect(ev!.message_type).toBe("text");
    expect(ev!.sender_id).toBe("ou_208edaa2b50e6e7343cf110f1d051a47");
  });

  it("extracts the text from the content JSON", () => {
    const ev = sdkEventToImEvent(LIVE_EVENT);
    expect(ev!.content).toBe("session-map 有几种状态");
  });

  it("returns null for a non-text message type (e.g. image)", () => {
    const img = { ...LIVE_EVENT, message: { ...LIVE_EVENT.message, message_type: "image", content: '{"image_key":"img_xxx"}' } };
    const ev = sdkEventToImEvent(img);
    // Non-text content has no .text; we surface message_type and let the core reject it.
    expect(ev!.message_type).toBe("image");
    expect(ev!.content).toBe("");
  });

  it("returns null for a malformed event (no message)", () => {
    expect(sdkEventToImEvent({ event_id: "x" })).toBeNull();
  });

  it("carries thread_id when present (threaded reply)", () => {
    const threaded = { ...LIVE_EVENT, message: { ...LIVE_EVENT.message, thread_id: "omt_thread123" } };
    const ev = sdkEventToImEvent(threaded);
    expect(ev!.thread_id).toBe("omt_thread123");
  });

  it("carries parent_id when the message REPLIES to another (follow-up context)", () => {
    const reply = { ...LIVE_EVENT, message: { ...LIVE_EVENT.message, parent_id: "om_parent_card_99" } };
    expect(sdkEventToImEvent(reply)!.parent_id).toBe("om_parent_card_99");
    // absent when not a reply
    expect(sdkEventToImEvent(LIVE_EVENT)!.parent_id).toBeUndefined();
  });

  it("extracts sender_type (so non-user senders can be filtered)", () => {
    expect(sdkEventToImEvent(LIVE_EVENT)!.sender_type).toBe("user");
  });

  it("extracts the mentions array (key + open_id) for group @-gating", () => {
    const grp = {
      ...LIVE_EVENT,
      message: {
        ...LIVE_EVENT.message,
        chat_type: "group",
        content: '{"text":"@_user_1 消除判定在哪"}',
        mentions: [{ key: "@_user_1", id: { open_id: "ou_bot" }, name: "助手" }],
      },
    };
    const ev = sdkEventToImEvent(grp);
    expect(ev!.chat_type).toBe("group");
    expect(ev!.mentions).toEqual([{ key: "@_user_1", open_id: "ou_bot", name: "助手" }]);
  });

  it("defaults mentions to [] and sender_type to '' when absent", () => {
    const ev = sdkEventToImEvent({ event_id: "x", message: { chat_id: "oc_1", content: '{"text":"hi"}', message_type: "text" } });
    expect(ev!.mentions).toEqual([]);
    expect(ev!.sender_type).toBe("");
  });
});
