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
    expect(card.header.title.content).toBe("source-truth");
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
