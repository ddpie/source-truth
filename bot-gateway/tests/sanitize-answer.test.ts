/**
 * Tests for the shared answer-sanitizing pipeline (sanitize-answer.ts) — the
 * single implementation both the live streaming path and the finalize path in
 * index.ts call. These tests LOCK the order contract documented in the module
 * header (split-first, redact-after-strip, clamp-last); the per-helper behavior
 * is covered by each helper's own test file.
 */

import { sanitizeAnswerText, renderFinalText, clampForCard, MAX_CARD_BODY_CHARS, MAX_CARD_EVIDENCE_CHARS } from "../src/sanitize-answer";
import { extractFollowUps } from "../src/extract-followups";

const REDACTED = "[已隐藏]";

describe("order contract", () => {
  it("splitEvidence runs BEFORE stripFollowUps: a 你可能还想问 trailer that precedes 供研发复核 must not eat the evidence", () => {
    // If stripFollowUps ran first, its greedy tail-eat would swallow the
    // evidence block along with the trailer (cross-review HIGH).
    const answer = [
      "结论：攻击力上限是 999。",
      "",
      "💡 你可能还想问：",
      "- 防御力上限是多少？",
      "",
      "> 🔍 **供研发复核**",
      "> Config.cs:42 MAX_ATK = 999",
    ].join("\n");
    for (const mode of ["live", "final"] as const) {
      const out = sanitizeAnswerText(answer, { mode });
      expect(out.evidence).toContain("Config.cs:42");
      expect(out.body).toContain("999");
      expect(out.body).not.toContain("你可能还想问");
      expect(out.body).not.toContain("防御力上限");
    }
  });

  it("strips the follow-up trailer from the EVIDENCE partition too", () => {
    const answer = [
      "结论：暴击率 5%。",
      "",
      "> 🔍 **供研发复核**",
      "> Crit.cs:10 CRIT_RATE = 0.05",
      "",
      "💡 你可能还想问：",
      "- 暴击伤害倍率？",
    ].join("\n");
    for (const mode of ["live", "final"] as const) {
      const out = sanitizeAnswerText(answer, { mode });
      expect(out.evidence).toContain("Crit.cs:10");
      expect(out.evidence).not.toContain("你可能还想问");
      expect(out.evidence).not.toContain("暴击伤害倍率");
    }
  });

  it("live body: redactSensitive runs AFTER stripToolCallLeak — a secret split by a leaked <invoke> block is redacted once stripping re-joins it", () => {
    // A leaked tool-call block sits INSIDE a key=value secret, splitting it into
    // two halves. Stripping the block re-joins the full secret; redaction must
    // run AFTER the strip or the re-joined tail survives to the card (cross-
    // review P1 — the live path once had the order inverted: redact-first only
    // eats up to the '"' inside the tag and leaks the tail half).
    const answer = '结论如下。\napi_key=SuPer<invoke name="codegraph_x">q</invoke>SecretValue123456\n以上。';
    const out = sanitizeAnswerText(answer, { mode: "live" });
    expect(out.body).not.toContain("SuPer");
    expect(out.body).not.toContain("SecretValue123456");
    expect(out.body).toContain(REDACTED);
    // Regression oracle: with the INVERTED order (redact before strip), the
    // re-joined tail would survive — assert the inverted composition really does
    // leak, so this test can't silently pass for the wrong reason.
    const { redactSensitive } = require("../src/redact");
    const { stripToolCallLeak } = require("../src/strip-toolcall-leak");
    const inverted = stripToolCallLeak(redactSensitive(answer));
    expect(inverted).toContain("SecretValue123456");
  });

  it("live body: plain secrets are redacted", () => {
    const out = sanitizeAnswerText("token=abcdefgh12345678 是配置值。", { mode: "live" });
    expect(out.body).not.toContain("abcdefgh12345678");
    expect(out.body).toContain(REDACTED);
  });

  it("live evidence: secrets and tool-call markup are both scrubbed", () => {
    const answer = [
      "结论：见下。",
      "> 🔍 **供研发复核**",
      "> secrets.env:1 password=hunter2hunter2",
      '> <invoke name="codegraph_read_file"></invoke>',
    ].join("\n");
    const out = sanitizeAnswerText(answer, { mode: "live" });
    expect(out.evidence).not.toContain("hunter2hunter2");
    expect(out.evidence).toContain(REDACTED);
    expect(out.evidence).not.toContain("<invoke");
  });

  it("live body: clamp runs LAST — an over-long body ends with the truncation marker and stays under the cap+marker budget", () => {
    const long = "结论：\n" + "数据行 x=1\n".repeat(3000); // way past 9000 chars
    const out = sanitizeAnswerText(long, { mode: "live" });
    expect(out.body.length).toBeLessThan(MAX_CARD_BODY_CHARS + 200);
    expect(out.body).toContain("已截断");
  });
});

describe.each(["live", "final"] as const)("decorated follow-up pipeline (%s)", (mode) => {
  it.each([
    "> 💡 你可能还想问：",
    "> **💡 你可能还想问：**",
    "> ### 💡 **你可能还想问**：",
  ])("keeps raw-answer buttons when quoted evidence is cleaned: %s", (marker) => {
    // Production regression: splitEvidence removes the quote prefix before
    // stripping, while button extraction consumes the original quoted answer.
    const answer = [
      "结论：负重上限由力量决定。",
      "",
      "> 🔍 **供研发复核**",
      "> FormulaHelper.cs:75 MaxEncumbrance()",
      "> ---",
      marker,
      "> - 调用方有哪些？",
      "> 1. 调用方有哪些？",
      "> - 改了会影响什么？",
    ].join("\n");
    const questions = ["调用方有哪些？", "改了会影响什么？"];
    expect(extractFollowUps(answer)).toEqual(questions);
    const out = sanitizeAnswerText(answer, { mode });
    expect(out.body).toBe("结论：负重上限由力量决定。");
    expect(out.evidence.trim()).toBe("FormulaHelper.cs:75 MaxEncumbrance()");
    for (const text of [out.body, out.evidence]) {
      expect(text).not.toContain("你可能还想问");
      for (const question of questions) expect(text).not.toContain(question);
    }
  });

  it("preserves evidence after a decorated follow-up section and never makes it a button", () => {
    const answer = [
      "结论：基础伤害为 50。",
      "",
      "> ---",
      "> ### **💡 你可能还想问：**",
      "> - 调用方有哪些？",
      "",
      "> 🔍 **供研发复核**",
      "> - Combat.cs:42 baseDamage = 50",
      "> - Config.cs:10 damageScale = 1",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？"]);
    const out = sanitizeAnswerText(answer, { mode });
    expect(out.body).toBe("结论：基础伤害为 50。");
    expect(out.evidence).toContain("Combat.cs:42 baseDamage = 50");
    expect(out.evidence).toContain("Config.cs:10 damageScale = 1");
    expect(out.evidence).not.toContain("调用方有哪些");
    expect(out.body).not.toContain("你可能还想问");
  });

  it("preserves a quoted ordinary sentence and its data rows without creating buttons", () => {
    const answer = [
      "结论：这些是已经查到的数据。",
      "> ### **你可能还想问的逻辑在 Config.cs:10 定义。**",
      "> - 基础伤害 50",
      "> - 暴击倍率 1.5",
      "> 🔍 **供研发复核**",
      "> Config.cs:10 为配置入口",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual([]);
    const out = sanitizeAnswerText(answer, { mode });
    expect(out.body).toContain("你可能还想问的逻辑在 Config.cs:10 定义。");
    expect(out.body).toContain("基础伤害 50");
    expect(out.body).toContain("暴击倍率 1.5");
    expect(out.evidence).toContain("Config.cs:10 为配置入口");
  });

  it.each(["> 📎 依据", "> **🔍 供研发复核**"])("preserves later evidence without turning it into buttons: %s", (heading) => {
    const answer = [
      "结论：基础伤害为 50。",
      "> ### **💡 你可能还想问：**",
      "> - 调用方有哪些？",
      heading,
      "> Config.cs:10 基础伤害 = 50",
    ].join("\n");
    const out = sanitizeAnswerText(answer, { mode });
    expect(out.body).toBe("结论：基础伤害为 50。");
    expect(out.evidence).toBe("Config.cs:10 基础伤害 = 50");
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？"]);
  });

  it("retains the subsequent quoted clarification prompt and all its options", () => {
    const answer = [
      "结论：请先核对配置版本。",
      "> ### **💡 你可能还想问：**",
      "> - 调用方有哪些？",
      "> 🔀 需要你确认：请选择配置版本。",
      "> - 当前正式服配置是什么？",
      "> - 当前测试服配置是什么？",
    ].join("\n");
    const out = sanitizeAnswerText(answer, { mode });
    expect(out.body).toContain("🔀 需要你确认：请选择配置版本。");
    expect(out.body).toContain("当前正式服配置是什么？");
    expect(out.body).toContain("当前测试服配置是什么？");
    expect(out.body).not.toContain("你可能还想问");
    expect(out.body).not.toContain("调用方有哪些？");
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？"]);
  });

  it("retains a later chart fence after removing the quoted suggestions", () => {
    const chart = '```chart\n{"type":"line","data":{"values":[]}}\n```';
    const answer = [
      "结论：趋势如下。",
      "> ### **💡 你可能还想问：**",
      "> - 调用方有哪些？",
      chart,
    ].join("\n");
    const out = sanitizeAnswerText(answer, { mode });
    expect(out.body).toContain(chart);
    expect(out.body).not.toContain("你可能还想问");
    expect(out.body).not.toContain("调用方有哪些？");
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？"]);
  });

  it("keeps fenced template text when a delimiter with a suffix occurs inside it", () => {
    const template = [
      "```markdown",
      "```text",
      "> **💡 你可能还想问：**",
      "> - 这里是模板里的示例问题？",
      "```",
    ].join("\n");
    const answer = [
      "结论：以下为模板原文。",
      template,
      "真实说明必须保留。",
      "💡 你可能还想问：",
      "- 真正的推荐问题是什么？",
    ].join("\n");
    const out = sanitizeAnswerText(answer, { mode });
    expect(out.body).toContain(template);
    expect(out.body).toContain("真实说明必须保留。");
    expect(out.body).not.toContain("真正的推荐问题是什么？");
    expect(extractFollowUps(answer)).toEqual(["真正的推荐问题是什么？"]);
  });
});

describe("live mode", () => {
  it("strips a planning preamble so the typewriter leads with the answer", () => {
    const out = sanitizeAnswerText("现在我整理答案。\n---\n攻击力上限是 999。", { mode: "live" });
    expect(out.body.startsWith("攻击力上限")).toBe(true);
  });

  it("falls back to the raw text when the stripped body is empty (partial trailer-only frame never blanks)", () => {
    // Mid-stream, the model may have emitted ONLY the follow-up trailer so far;
    // body strips to "" and the pipeline must fall back to showing the raw text.
    const partial = "💡 你可能还想问：\n- 问题一？";
    const out = sanitizeAnswerText(partial, { mode: "live" });
    expect(out.body.trim().length).toBeGreaterThan(0);
  });

  it("returns empty evidence when no 供研发复核 marker streamed yet", () => {
    const out = sanitizeAnswerText("结论：暂无依据部分。", { mode: "live" });
    expect(out.evidence).toBe("");
    expect(out.body).toContain("暂无依据部分");
  });

  it("strips leaked tool-call XML from the live body", () => {
    const answer = '结论前。<invoke name="codegraph_search_files"><parameter name="p">hp</parameter></invoke>结论后。';
    const out = sanitizeAnswerText(answer, { mode: "live" });
    expect(out.body).not.toContain("<invoke");
    expect(out.body).not.toContain("parameter");
    expect(out.body).toContain("结论前");
    expect(out.body).toContain("结论后");
  });

  it("repairs jammed block markers (normalizeBlocks) in the live body", () => {
    const out = sanitizeAnswerText("具体来说：### 魅力属性\n内容。", { mode: "live" });
    expect(out.body).toContain("\n### 魅力属性");
  });
});

describe("final mode", () => {
  it("returns the front-half body (preamble-stripped, follow-ups stripped) WITHOUT redaction/clamp — finalize's renderFinalText does the tail", () => {
    // final mode intentionally leaves redaction to renderFinalText (finalize
    // runs its own middle steps — shapeBody, leak checks, clarify — in between).
    const answer = "现在我整理答案。\n---\ntoken=abcdefgh12345678 的默认值如上。\n\n💡 你可能还想问：\n- 其他配置？";
    const out = sanitizeAnswerText(answer, { mode: "final" });
    expect(out.body.startsWith("token=")).toBe(true); // preamble + trailer gone
    expect(out.body).toContain("abcdefgh12345678"); // NOT yet redacted here…
    const rendered = renderFinalText(out.body, MAX_CARD_BODY_CHARS);
    expect(rendered).not.toContain("abcdefgh12345678"); // …redacted by the tail
    expect(rendered).toContain(REDACTED);
  });

  it("splits evidence and returns it raw (finalize leak-strips/redacts it in its own middle steps)", () => {
    const answer = "结论。\n\n> 🔍 **供研发复核**\n> Foo.cs:7 X = 1";
    const out = sanitizeAnswerText(answer, { mode: "final" });
    expect(out.body).toBe("结论。");
    expect(out.evidence).toContain("Foo.cs:7");
  });
});

describe("renderFinalText", () => {
  it("redacts, then clamps, then normalizes blocks", () => {
    const text = "结束：### 标题\npassword=supersecretvalue1";
    const rendered = renderFinalText(text, MAX_CARD_EVIDENCE_CHARS);
    expect(rendered).not.toContain("supersecretvalue1");
    expect(rendered).toContain(REDACTED);
    expect(rendered).toContain("\n### 标题");
  });

  it("clamps an over-long field with the truncation marker", () => {
    const long = "行内容\n".repeat(5000);
    const rendered = renderFinalText(long, MAX_CARD_BODY_CHARS);
    expect(rendered.length).toBeLessThan(MAX_CARD_BODY_CHARS + 200);
    expect(rendered).toContain("已截断");
  });
});

describe("clampForCard", () => {
  it("returns short text unchanged", () => {
    expect(clampForCard("短文本", 100)).toBe("短文本");
  });

  it("cuts on a line boundary near the limit", () => {
    const text = "第一行内容比较长一点\n".repeat(20);
    const out = clampForCard(text, 100);
    const marker = "\n\n_（内容较长，已截断；完整依据见“供研发复核”或直接查阅源码）_";
    expect(out.endsWith(marker)).toBe(true);
    // The kept head must end exactly at a line boundary (no mid-line slice).
    const head = out.slice(0, out.length - marker.length);
    expect(head.endsWith("长一点")).toBe(true);
  });
});
