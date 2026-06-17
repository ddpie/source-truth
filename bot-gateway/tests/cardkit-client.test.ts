/**
 * Unit tests for cardkit-client request builders (pure: card JSON + API paths).
 * Real CardKit v1 calls are integration-only; here we verify the request shapes
 * match the verified spike (docs/agent/cardkit-streaming-spike.md appendix).
 */

import {
  buildCreateCardBody,
  contentUpdatePath,
  buildContentUpdateBody,
  settingsPath,
  buildCloseStreamingBody,
  buildSendCardContent,
  buildFollowUpToast,
  finalizeTitle,
} from "../src/cardkit-client";

describe("buildCreateCardBody", () => {
  it("builds a schema-2.0 streaming card with paired streaming_config", () => {
    const body = JSON.parse(buildCreateCardBody({ title: "source-truth" }));
    expect(body.type).toBe("card_json");
    const card = JSON.parse(body.data);
    expect(card.schema).toBe("2.0");
    expect(card.config.streaming_mode).toBe(true);
    // print_frequency_ms + print_step must be paired (else CardKit code 11311).
    expect(card.config.streaming_config.print_frequency_ms).toBeDefined();
    expect(card.config.streaming_config.print_step).toBeDefined();
    expect(card.header.title.content).toBe("正在思考…");
    expect(
      card.body.elements.some((e: { element_id?: string }) => e.element_id === "conclusion"),
    ).toBe(true);
  });
});

describe("content update", () => {
  it("targets the conclusion element content path", () => {
    expect(contentUpdatePath("CID")).toBe(
      "/open-apis/cardkit/v1/cards/CID/elements/conclusion/content",
    );
  });
  it("sends full content + increasing sequence (typewriter)", () => {
    const body = JSON.parse(buildContentUpdateBody("hello", 3));
    expect(body.content).toBe("hello");
    expect(body.sequence).toBe(3);
  });
});

describe("close streaming", () => {
  it("targets the settings path and sets streaming_mode false", () => {
    expect(settingsPath("CID")).toBe("/open-apis/cardkit/v1/cards/CID/settings");
    const body = JSON.parse(buildCloseStreamingBody(9));
    expect(body.sequence).toBe(9);
    expect(JSON.parse(body.settings).config.streaming_mode).toBe(false);
  });
});

describe("send card as IM content", () => {
  it("wraps a card_id as an interactive card message content", () => {
    const content = JSON.parse(buildSendCardContent("7652206316581309633"));
    expect(content.type).toBe("card");
    expect(content.data.card_id).toBe("7652206316581309633");
  });
});

describe("follow-up card header", () => {
  it("marks the header so a follow-up card is distinguishable in chat history", () => {
    const body = JSON.parse(buildCreateCardBody({ summary: "Q", followUp: true }));
    const card = JSON.parse(body.data);
    expect(card.header.title.content).toContain("追问");
  });

  it("uses the normal header for a fresh question", () => {
    const body = JSON.parse(buildCreateCardBody({ summary: "Q" }));
    const card = JSON.parse(body.data);
    expect(card.header.title.content).toBe("正在思考…");
  });

  it("finalizeTitle keeps the follow-up marker on the completed card", () => {
    expect(finalizeTitle(false)).toBe("回答完成");
    expect(finalizeTitle(true)).toContain("追问");
  });
});

describe("buildFollowUpToast", () => {
  it("returns an info toast naming the clicked question", () => {
    const toast = buildFollowUpToast("战斗伤害怎么算？");
    expect(toast.toast.type).toBe("info");
    expect(toast.toast.content).toContain("战斗伤害怎么算？");
  });

  it("truncates a very long question so the toast stays readable", () => {
    const long = "这是一个非常非常非常长的追问问题".repeat(10);
    const toast = buildFollowUpToast(long);
    // Toast content should not blow up; cap around 50 chars + prefix/ellipsis.
    expect(toast.toast.content.length).toBeLessThan(70);
    expect(toast.toast.content).toContain("…");
  });
});
