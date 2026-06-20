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
  buildReasoningPanel,
  buildEvidencePanel,
  buildStopButton,
  finalizeTitle,
  buildFollowUpElements,
  buildClarifyElements,
  buildClickedButtonElement,
  formatElapsed,
  buildQuestionElement,
} from "../src/cardkit-client";

describe("buildQuestionElement", () => {
  it("renders the question as a non-markdown plain_text div so metachars can't corrupt the card", () => {
    // plain_text never interprets markdown → no escaping, ** / ` / | / _ are literal.
    const el = buildQuestionElement("成本**翻倍**了吗 max_turns") as { tag: string; text: { tag: string; content: string } };
    expect(el.tag).toBe("div");
    expect(el.text.tag).toBe("plain_text");
    expect(el.text.content).toBe("问：成本**翻倍**了吗 max_turns"); // verbatim, no backslashes
  });
  it("collapses a multi-line paste to one line", () => {
    const el = buildQuestionElement("第一行\n第二行") as { text: { content: string } };
    expect(el.text.content).toBe("问：第一行 第二行");
  });
  it("is the question element inside the created card body (element_id=question)", () => {
    const body = JSON.parse(buildCreateCardBody({ summary: "Q", question: "成本**翻倍**了吗" }));
    const card = JSON.parse(body.data);
    const qEl = card.body.elements.find((e: { element_id?: string }) => e.element_id === "question");
    expect(qEl.tag).toBe("div");
    expect(qEl.text.content).toBe("问：成本**翻倍**了吗");
  });
});

describe("formatElapsed", () => {
  it("shows bare seconds under a minute", () => {
    expect(formatElapsed(0)).toBe("0s");
    expect(formatElapsed(8_400)).toBe("8s");
    expect(formatElapsed(59_900)).toBe("59s");
  });
  it("shows Mm Ss between one minute and one hour", () => {
    expect(formatElapsed(60_000)).toBe("1m 0s");
    expect(formatElapsed(247_000)).toBe("4m 7s");
    expect(formatElapsed(3_599_000)).toBe("59m 59s");
  });
  it("shows Hh Mm beyond an hour", () => {
    expect(formatElapsed(3_600_000)).toBe("1h 0m");
    expect(formatElapsed(7_530_000)).toBe("2h 5m");
  });
  it("never goes negative", () => {
    expect(formatElapsed(-500)).toBe("0s");
  });
});

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
    expect(card.header.title.content).toBe("正在分析…");
    expect(
      card.body.elements.some((e: { element_id?: string }) => e.element_id === "conclusion"),
    ).toBe(true);
  });

  it("renders the traceId in a copyable code block at the TOP when provided", () => {
    const card = JSON.parse(JSON.parse(buildCreateCardBody({ question: "Q", traceId: "a1b2c3d4" })).data);
    const first = card.body.elements[0] as { element_id?: string; content?: string };
    expect(first.element_id).toBe("trace");                 // top of the card
    expect(first.content).toContain("```\na1b2c3d4\n```");  // fenced code block → Feishu Copy control
  });

  it("omits the trace line when no traceId is given", () => {
    const card = JSON.parse(JSON.parse(buildCreateCardBody({ question: "Q" })).data);
    expect(card.body.elements.some((e: { element_id?: string }) => e.element_id === "trace")).toBe(false);
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

describe("buildStopButton", () => {
  it("builds a danger stop button carrying the card_id for abort routing", () => {
    const btn = buildStopButton("card_777") as {
      tag: string; element_id: string; type: string; value: { action: string; card_id: string };
    };
    expect(btn.tag).toBe("button");
    expect(btn.element_id).toBe("stopbtn");
    expect(btn.value.action).toBe("stop");
    expect(btn.value.card_id).toBe("card_777");
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

describe("buildEvidencePanel (供研发复核, live + finalize)", () => {
  it("builds a FOLDED panel (element_id=evidence) with the citations", () => {
    const panel = buildEvidencePanel("FormulaHelper.cs:75 MaxEncumbrance") as {
      tag: string; expanded: boolean; element_id: string; elements: Array<{ content: string }>;
    };
    expect(panel.tag).toBe("collapsible_panel");
    expect(panel.expanded).toBe(false); // dev-review folded by default
    expect(panel.element_id).toBe("evidence");
    expect(panel.elements[0].content).toContain("FormulaHelper.cs:75");
  });

  it("returns null when there is no evidence (so live append/update no-ops)", () => {
    expect(buildEvidencePanel("")).toBeNull();
    expect(buildEvidencePanel("   ")).toBeNull();
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
    expect(card.header.title.content).toBe("正在分析…");
  });

  it("finalizeTitle keeps the follow-up marker on the completed card", () => {
    expect(finalizeTitle(false)).toBe("回答完成");
    expect(finalizeTitle(true)).toContain("追问");
  });

  it("finalizeTitle appends elapsed time on a completed answer", () => {
    // elapsedLabel is whatever formatElapsed produced ("1m 7s" style).
    expect(finalizeTitle(false, false, false, "1m 7s")).toBe("回答完成 · 用时 1m 7s");
    expect(finalizeTitle(true, false, false, "1m 5s")).toContain("用时 1m 5s");
  });

  it("finalizeTitle does NOT show elapsed on a hard failure (misleading)", () => {
    expect(finalizeTitle(false, false, true, "1m 7s")).toBe("查询失败");
  });

  it("finalizeTitle marks a turn-capped partial distinctly (not a green 回答完成)", () => {
    const t = finalizeTitle(false, false, false, "2m 3s", true);
    expect(t).toContain("部分结论");
    expect(t).not.toContain("回答完成");
    expect(t).toContain("用时 2m 3s"); // time IS meaningful for a partial
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

  it("renders a retry ACTION button (fresh=true) before follow-ups", () => {
    const els = buildFollowUpElements([], [{ kind: "retry", text: "负重上限怎么算？", label: "重新试一次" }]);
    const buttons = els.filter((e) => (e as { tag: string }).tag === "button") as Array<{
      element_id: string; type: string;
      value: { action: string; text: string; fresh?: boolean };
    }>;
    expect(buttons).toHaveLength(1);
    expect(buttons[0].element_id).toBe("action_retry_0");
    expect(buttons[0].type).toBe("primary");
    expect(buttons[0].value.action).toBe("follow_up"); // reuses follow_up callback
    expect(buttons[0].value.text).toBe("负重上限怎么算？");
    expect(buttons[0].value.fresh).toBe(true); // retry re-asks fresh (no context replay)
  });

  it("narrow ACTION button is NOT fresh (keeps context) and leads the list", () => {
    const els = buildFollowUpElements(["Q1"], [{ kind: "narrow", text: "只聚焦一点：X？", label: "缩小范围再问一次" }]);
    const buttons = els.filter((e) => (e as { tag: string }).tag === "button") as Array<{
      element_id: string; value: { fresh?: boolean; text: string };
    }>;
    expect(buttons[0].element_id).toBe("action_narrow_0"); // action first
    expect(buttons[0].value.fresh).toBe(false); // narrow keeps context (not fresh)
    expect(buttons[1].element_id).toBe("followup_0");   // then the suggestion
  });

  it("omits the 'reply to continue' hint when an action button is present", () => {
    const els = buildFollowUpElements([], [{ kind: "retry", text: "x", label: "重新试一次" }]);
    const md = els.filter((e) => (e as { tag: string }).tag === "markdown") as Array<{ content: string }>;
    expect(md.every((m) => !m.content.includes("回复本条消息"))).toBe(true);
  });

  it("shows a 'not listed? reply directly' hint AFTER the follow-up buttons (user-requested)", () => {
    // The buttons are only suggestions — guide the user they can ask anything else by
    // replying to the card directly.
    const els = buildFollowUpElements(["Q1", "Q2"]);
    const md = els.filter((e) => (e as { tag: string }).tag === "markdown") as Array<{ content: string }>;
    expect(md.some((m) => m.content.includes("直接回复本条消息"))).toBe(true);
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

describe("buildClarifyElements", () => {
  it("renders one primary button per option, reusing the follow_up action", () => {
    const els = buildClarifyElements("指哪种攻击力？", [
      "武器基础攻击力怎么算？",
      "角色总攻击力怎么算？",
    ]) as Array<{ tag: string; element_id: string; type: string; value: { action: string; text: string; eid: string } }>;
    expect(els).toHaveLength(2); // buttons only — the prompt is rendered in the card body
    expect(els[0].tag).toBe("button");
    expect(els[0].type).toBe("primary");
    expect(els[0].element_id).toBe("clarify_0");
    // Clicking reuses the follow_up callback so the chosen option re-asks WITH context.
    expect(els[0].value.action).toBe("follow_up");
    expect(els[0].value.text).toBe("武器基础攻击力怎么算？");
    expect(els[1].element_id).toBe("clarify_1");
  });

  it("caps at MAX_CLARIFY_OPTIONS (4)", () => {
    const els = buildClarifyElements("?", ["a", "b", "c", "d", "e", "f"]);
    expect(els.length).toBe(4);
  });
});

describe("finalizeTitle clarify branch", () => {
  it("uses a 请选择 header (not 回答完成) and no 用时 for a clarification", () => {
    const t = finalizeTitle(false, false, false, "1m 7s", false, true);
    expect(t).toContain("请选择");
    expect(t).not.toContain("回答完成");
    expect(t).not.toContain("用时"); // elapsed is noise on a question-back-to-user
  });

  it("a normal answer is unaffected by the clarify flag default", () => {
    expect(finalizeTitle(false, false, false, "1m 7s")).toBe("回答完成 · 用时 1m 7s");
  });
});

