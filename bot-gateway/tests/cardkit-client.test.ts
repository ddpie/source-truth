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
  buildStageBody,
  buildReasoningPanel,
  finalizeTitle,
  buildFollowUpElements,
  buildClickedButtonElement,
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

describe("buildReasoningPanel", () => {
  it("builds an expanded panel listing the live steps (in-progress)", () => {
    const panel = buildReasoningPanel(["定位 calcDamage", "读取 SkillConfig.xlsx"], true) as {
      tag: string; expanded: boolean; element_id: string; elements: Array<{ content: string }>;
    };
    expect(panel.tag).toBe("collapsible_panel");
    expect(panel.expanded).toBe(true);
    expect(panel.element_id).toBe("reasoning");
    expect(panel.elements[0].content).toContain("定位 calcDamage");
    expect(panel.elements[0].content).toContain("读取 SkillConfig.xlsx");
  });

  it("builds a collapsed panel when done (archived)", () => {
    const panel = buildReasoningPanel(["步骤1"], false) as { expanded: boolean };
    expect(panel.expanded).toBe(false);
  });

  it("returns null when there are no steps", () => {
    expect(buildReasoningPanel([], true)).toBeNull();
  });
});

describe("buildStageBody (mid-stream header status change)", () => {
  it("builds a full-card PUT body that changes header but keeps streaming + conclusion", () => {
    const raw = buildStageBody("正在分析…", "orange", "已分析到一半的文本", 5);
    const outer = JSON.parse(raw);
    expect(outer.sequence).toBe(5);
    const card = JSON.parse(outer.card.data);
    // Header reflects the new stage.
    expect(card.header.title.content).toBe("正在分析…");
    expect(card.header.template).toBe("orange");
    // Streaming must stay on (we're still mid-answer) so the typewriter survives.
    expect(card.config.streaming_mode).toBe(true);
    // Body carries the current conclusion text (else a full PUT would wipe it).
    const conclusion = card.body.elements.find((e: { element_id?: string }) => e.element_id === "conclusion");
    expect(conclusion.content).toBe("已分析到一半的文本");
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

describe("follow-up buttons (clickable, with element_id)", () => {
  it("gives each button a stable element_id and carries it in the value", () => {
    const els = buildFollowUpElements(["Q1", "Q2"]);
    const buttons = els.filter((e) => (e as { tag: string }).tag === "button") as Array<{
      element_id: string;
      value: { action: string; text: string; eid: string };
    }>;
    expect(buttons).toHaveLength(2);
    expect(buttons[0].element_id).toBe("followup_0");
    expect(buttons[0].value.eid).toBe("followup_0");
    expect(buttons[0].value.text).toBe("Q1");
    expect(buttons[1].element_id).toBe("followup_1");
  });
});

describe("buildClickedButton", () => {
  it("renders a disabled button marked as clicked (✓) for the chosen question", () => {
    const el = JSON.parse(buildClickedButtonElement("followup_1", "战斗伤害怎么算？"));
    expect(el.tag).toBe("button");
    expect(el.element_id).toBe("followup_1");
    expect(el.disabled).toBe(true);
    expect(el.text.content).toContain("战斗伤害怎么算？");
    expect(el.text.content).toContain("✓");
  });
});

