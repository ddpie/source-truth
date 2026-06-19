/**
 * Tests for extractClarification — parsing the agent's "ask the user to clarify"
 * block into a question + option buttons. Must parse real shapes and NOT trigger
 * on a normal answer that merely mentions confirmation.
 */

import { extractClarification, MAX_CLARIFY_OPTIONS } from "../src/extract-clarify";

describe("extractClarification", () => {
  it("parses the marker + options into question and buttons", () => {
    const answer = [
      "🔀 需要你确认：你说的「攻击力」是指哪一种？",
      "- 武器本身的基础攻击力是怎么算的？",
      "- 角色面板上的总攻击力是怎么算的？",
      "- 技能/法术造成的伤害是怎么算的？",
    ].join("\n");
    const c = extractClarification(answer);
    expect(c).not.toBeNull();
    expect(c!.question).toBe("你说的「攻击力」是指哪一种？");
    expect(c!.options).toEqual([
      "武器本身的基础攻击力是怎么算的？",
      "角色面板上的总攻击力是怎么算的？",
      "技能/法术造成的伤害是怎么算的？",
    ]);
  });

  it("dedups repeated options (no twin clarify buttons)", () => {
    const answer = "🔀 需要你确认：指哪种？\n- 武器攻击力？\n- 武器攻击力？\n- 角色总攻击力？";
    const c = extractClarification(answer);
    expect(c!.options).toEqual(["武器攻击力？", "角色总攻击力？"]);
  });

  it("works without the 🔀 emoji (keys on the literal 需要你确认)", () => {
    const answer = "需要你确认: 指哪个背包？\n- 主角随身背包容量\n- 仓库/银行存储容量";
    const c = extractClarification(answer);
    expect(c).not.toBeNull();
    expect(c!.options.length).toBe(2);
    expect(c!.question).toBe("指哪个背包？");
  });

  it("caps options at MAX_CLARIFY_OPTIONS", () => {
    const opts = Array.from({ length: 8 }, (_, i) => `- 选项 ${i + 1} 的完整问题？`).join("\n");
    const c = extractClarification(`需要你确认：太多了\n${opts}`);
    expect(c!.options.length).toBe(MAX_CLARIFY_OPTIONS);
  });

  it("returns null when there is no marker", () => {
    expect(extractClarification("暴击倍率是 1.5 倍。\n- 这是一个普通列表项")).toBeNull();
  });

  it("returns null when the marker has fewer than 2 options (not a real clarify)", () => {
    // A normal answer that happens to say 需要你确认 with only one bullet must NOT
    // be hijacked into a (broken) clarification card.
    const answer = "这个值需要你确认运行时是否被覆盖。\n- 仅一条线索，不是澄清选项";
    expect(extractClarification(answer)).toBeNull();
  });

  it("returns null on a plain answer with a bullet list but no marker", () => {
    const answer = "暴击分档如下：\n- 1–10 级：1.5 倍\n- 11–20 级：1.6 倍";
    expect(extractClarification(answer)).toBeNull();
  });

  it("stops collecting options at the first non-list line after the block", () => {
    const answer = [
      "需要你确认：指哪个？",
      "- 选项 A 的问题？",
      "- 选项 B 的问题？",
      "",
      "这行是说明文字，不该被当成选项。",
      "- 这条也不该算（在说明之后）",
    ].join("\n");
    const c = extractClarification(answer);
    expect(c!.options).toEqual(["选项 A 的问题？", "选项 B 的问题？"]);
  });

  it("falls back to a generic question if the marker line is empty", () => {
    const answer = "需要你确认\n- 选项 A？\n- 选项 B？";
    const c = extractClarification(answer);
    expect(c!.question).toContain("请选择");
    expect(c!.options.length).toBe(2);
  });

  it("tolerates numbered options (1. 2.)", () => {
    const answer = "需要你确认：哪个？\n1. 第一种理解？\n2. 第二种理解？";
    const c = extractClarification(answer);
    expect(c!.options).toEqual(["第一种理解？", "第二种理解？"]);
  });

  // --- false-trigger regressions (cross-review HIGH finding) ----------------
  it("does NOT trigger on a prose mention of 需要你确认 + trailing follow-up bullets", () => {
    // The most common shape: a real answer that says 需要你确认 mid-sentence, then
    // the standard "💡 你可能还想问" follow-up list. Must NOT be hijacked.
    const answer = [
      "这个值是否被热更覆盖需要你确认，建议找研发核实。",
      "---",
      "💡 你可能还想问：",
      "- 这个值在哪个表能调？",
      "- 不同等级分别是多少？",
    ].join("\n");
    expect(extractClarification(answer)).toBeNull();
  });

  it("does NOT trigger on a prose mention + a later 分档 value list", () => {
    const answer = [
      "背包默认 30 格，运行时是否被存档覆盖需要你确认。",
      "各档位如下：",
      "- 1 级：30 格",
      "- 10 级：40 格",
    ].join("\n");
    expect(extractClarification(answer)).toBeNull();
  });

  it("does NOT trigger when the marker is mid-sentence (not line-leading)", () => {
    const answer = "这个结论需要你确认一下，因为可能有热更。\n- 线索一\n- 线索二";
    expect(extractClarification(answer)).toBeNull();
  });

  it("does NOT trigger when options do NOT immediately follow the marker line", () => {
    // Marker leads a line, but prose intervenes before the bullets → not a clarify.
    const answer = [
      "🔀 需要你确认：指哪个？",
      "这里先解释一段背景，不是选项。",
      "- 选项 A？",
      "- 选项 B？",
    ].join("\n");
    expect(extractClarification(answer)).toBeNull();
  });

  it("STILL triggers when the marker leads a line and options immediately follow (blank lines OK)", () => {
    const answer = "🔀 需要你确认：指哪个？\n\n- 选项 A？\n- 选项 B？";
    const c = extractClarification(answer);
    expect(c).not.toBeNull();
    expect(c!.options).toEqual(["选项 A？", "选项 B？"]);
  });

  it("STILL triggers when the marker is the very first line of the answer", () => {
    const answer = "需要你确认：哪种攻击力？\n- 武器基础攻击？\n- 角色总攻击？";
    expect(extractClarification(answer)).not.toBeNull();
  });
});
