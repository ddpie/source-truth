/**
 * Unit tests for extractFollowUps — pulls the "💡 你可能还想问" suggestions out of
 * the agent's answer text into card-button strings.
 */

import { extractFollowUps, stripFollowUps } from "../src/extract-followups";

describe("extractFollowUps", () => {
  it("extracts bulleted questions after the marker", () => {
    const answer = [
      "结论：calcDamage 在 Combat.cs:42。",
      "",
      "---",
      "💡 你可能还想问：",
      "- calcDamage 的调用方有哪些？",
      "- 伤害公式怎么受等级影响？",
      "- 改了 calcDamage 会影响什么？",
    ].join("\n");
    const out = extractFollowUps(answer);
    expect(out).toHaveLength(3);
    expect(out[0]).toBe("calcDamage 的调用方有哪些？");
    expect(out[2]).toBe("改了 calcDamage 会影响什么？");
  });

  it("returns [] when there is no marker", () => {
    expect(extractFollowUps("就是个普通答案，没有追问区。")).toEqual([]);
  });

  it("keeps a short 4-char question (boundary: was wrongly dropped by > 4)", () => {
    const answer = "💡 你可能还想问：\n- 为什么会\n- 这个函数在哪里定义的？";
    const out = extractFollowUps(answer);
    expect(out).toContain("为什么会"); // 4 chars — must be kept
  });

  it("drops over-long lines (> 80 chars) and the marker/emoji lines", () => {
    const long = "x".repeat(90);
    const answer = `💡 你可能还想问：\n- ${long}\n- 正常的追问？`;
    const out = extractFollowUps(answer);
    expect(out).toEqual(["正常的追问？"]);
  });

  it("caps at 3 questions", () => {
    const answer = "💡 你可能还想问：\n- 问题一？\n- 问题二？\n- 问题三？\n- 问题四？";
    expect(extractFollowUps(answer)).toHaveLength(3);
  });

  // REGRESSION (HIGH): the marker must LEAD A LINE. A real answer that merely
  // MENTIONS "你可能还想问" mid-prose, then lists DATA rows, must NOT have those
  // rows scraped into follow-up buttons.
  it("does NOT extract from a mid-prose mention of the phrase", () => {
    const answer = [
      "这个技能的相关数值，你可能还想问的我都列了：",
      "- 基础伤害 50",
      "- 暴击倍率 1.5",
      "- 冷却 8 秒",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual([]);
  });

  it("extracts only when the marker is at line start (after 💡)", () => {
    const answer = "正文。\n💡 你可能还想问：\n- 调用方有哪些？";
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？"]);
  });

  it.each([
    ["> 💡 你可能还想问：", "> "],
    ["**💡 你可能还想问：**", ""],
    ["💡 **你可能还想问**：", ""],
    ["### 你可能还想问", ""],
    ["### **💡 你可能还想问：**", ""],
    ["> ### 💡 **你可能还想问**：", "> "],
  ])("extracts and strips the same decorated whole-line marker: %s", (marker, prefix) => {
    const answer = [
      "结论：基础伤害为 50。",
      "",
      `${prefix}---`,
      marker,
      `${prefix}- 调用方有哪些？`,
      `${prefix}1. 调用方有哪些？`,
      `${prefix}* 它怎么初始化？`,
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？", "它怎么初始化？"]);
    expect(stripFollowUps(answer)).toBe("结论：基础伤害为 50。");
  });

  it("normalizes quoted and unquoted list prefixes before deduplication and the cap", () => {
    const answer = [
      "💡 你可能还想问：",
      "> - 调用方有哪些？",
      "- 调用方有哪些？",
      "> 1. 它怎么初始化？",
      "> · 改了会影响什么？",
      "> * 还有其他配置吗？",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual([
      "调用方有哪些？", "它怎么初始化？", "改了会影响什么？",
    ]);
  });

  it.each([
    "你可能还想问的逻辑在 Config.cs:10 定义。",
    "> 你可能还想问的逻辑在 Config.cs:10 定义。",
    "> **你可能还想问的逻辑在 Config.cs:10 定义。**",
    "### **你可能还想问：这些数值已经列在下方。**",
    "> ### 💡 **你可能还想问**：这些数值已经列在下方。",
    "> **你可能还想问**的逻辑在 Config.cs:10 定义。",
  ])("does not turn a decorated ordinary sentence into a marker: %s", (prose) => {
    const answer = [
      "结论：以下是已有配置。",
      prose,
      "> - 基础伤害 50",
      "> - 暴击倍率 1.5",
      "这些行必须保留在答案中。",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual([]);
    expect(stripFollowUps(answer)).toBe(answer);
  });

  it.each([
    ["> 🔍 **供研发复核**", "> - Config.cs:10 基础伤害 = 50"],
    ["> **需要你确认**", "> - 当前使用哪套配置？"],
    ["> ```chart", '> {"type":"line","data":{"values":[]}}'],
  ])("stops quoted suggestions at the following section: %s", (boundary, content) => {
    const answer = [
      "结论。",
      "> ### **💡 你可能还想问：**",
      "> - 调用方有哪些？",
      boundary,
      content,
      "> - 后续段落不应成为推荐问题？",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？"]);
  });

  it("keeps a quoted suggestion that mentions the evidence section", () => {
    const answer = [
      "> 💡 **你可能还想问：**",
      "> - 供研发复核的证据在哪里？",
      "> - 它怎么初始化？",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual(["供研发复核的证据在哪里？", "它怎么初始化？"]);
  });

  it.each([
    ["```markdown", "```", ""],
    ["~~~markdown", "~~~", ""],
    ["```markdown", "```", "> "],
    ["````markdown", "````", ""],
  ])("preserves a fenced marker before the real trailer: %s / %s / %s", (open, close, prefix) => {
    const body = [
      "结论：以下为模板原文。",
      `${prefix}${open}`,
      `${prefix}> ### **💡 你可能还想问：**`,
      `${prefix}> - 这里是模板里的示例问题？`,
      `${prefix}${close}`,
      "真实说明必须保留。",
    ].join("\n");
    const answer = `${body}\n💡 你可能还想问：\n- 真正的推荐问题是什么？`;
    expect(extractFollowUps(answer)).toEqual(["真正的推荐问题是什么？"]);
    expect(stripFollowUps(answer)).toBe(body);
  });

  it.each(["```", "~~~"])("does not close a %s fence on a content line with a language suffix", (fence) => {
    // A closing fence permits only trailing whitespace. The second line is
    // literal code content even though it starts with the same delimiter.
    const body = [
      "结论：以下为模板原文。",
      `${fence}markdown`,
      `${fence}text`,
      "> ### **💡 你可能还想问：**",
      "> - 这里是模板里的示例问题？",
      fence,
      "真实说明必须保留。",
    ].join("\n");
    const answer = `${body}\n💡 你可能还想问：\n- 真正的推荐问题是什么？`;
    expect(extractFollowUps(answer)).toEqual(["真正的推荐问题是什么？"]);
    expect(stripFollowUps(answer)).toBe(body);
  });

  it("preserves an unfinished fenced example without inventing buttons", () => {
    const answer = [
      "结论：以下为尚未传完的模板。",
      "```markdown",
      "> ### **💡 你可能还想问：**",
      "> - 这里是模板里的示例问题？",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual([]);
    expect(stripFollowUps(answer)).toBe(answer);
  });
});

describe("stripFollowUps", () => {
  it("removes the trailer (divider + 💡 marker + question list) from the body", () => {
    const answer = [
      "## 结论",
      "伤害 = 力量 × 1.5。",
      "",
      "---",
      "💡 你可能还想问：",
      "- 调用方有哪些？",
      "- 改了会影响什么？",
    ].join("\n");
    const body = stripFollowUps(answer);
    expect(body).toContain("伤害 = 力量 × 1.5。");
    expect(body).not.toContain("你可能还想问");
    expect(body).not.toContain("调用方有哪些");
    expect(body.trimEnd().endsWith("伤害 = 力量 × 1.5。")).toBe(true); // no dangling ---
  });

  it("strips even without a preceding --- divider", () => {
    const body = stripFollowUps("答案正文。\n💡 你可能还想问：\n- 问题？");
    expect(body).toBe("答案正文。");
  });

  it("leaves text unchanged when there is no trailer", () => {
    const text = "就是个普通答案，没有追问区。";
    expect(stripFollowUps(text)).toBe(text);
  });

  it("round-trips with extractFollowUps: body has no questions, buttons do", () => {
    const answer = "正文结论。\n\n---\n💡 你可能还想问：\n- 调用方有哪些？\n- 改了会影响什么？";
    expect(stripFollowUps(answer)).toBe("正文结论。");
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？", "改了会影响什么？"]);
  });

  // REGRESSION (HIGH): a mid-prose mention must NOT truncate the answer body.
  it("does NOT truncate the body on a mid-prose mention of the phrase", () => {
    const answer = [
      "这个技能的相关数值，你可能还想问的我都列了：",
      "- 基础伤害 50",
      "- 暴击倍率 1.5",
    ].join("\n");
    // The whole thing is real answer text — strip must be a no-op.
    expect(stripFollowUps(answer)).toBe(answer);
  });

  // REGRESSION (HIGH): a line that LEADS with the phrase but continues with real
  // prose must NOT hijack — the marker must be (essentially) the whole line. Before
  // the line-END anchor, "你可能还想问的逻辑在 Config.cs:10 定义" truncated the answer
  // and turned real prose lines into fake buttons.
  it("does NOT hijack a line that merely BEGINS with the phrase then continues", () => {
    const answer = "用户问代码里哪里写了字符串。\n你可能还想问的逻辑在 Config.cs:10 定义。\n继续看下文。";
    expect(stripFollowUps(answer)).toBe(answer);   // no truncation
    expect(extractFollowUps(answer)).toEqual([]);  // no fake buttons
  });

  // A bare heading line (no colon) and the 💡 heading still work.
  it("still matches a bare '你可能还想问' heading line and the 💡 heading", () => {
    expect(extractFollowUps("结论。\n你可能还想问\n- 问题A？")).toEqual(["问题A？"]);
    expect(extractFollowUps("结论。\n💡 你可能还想问：\n- 问题B？")).toEqual(["问题B？"]);
  });
  it("dedups repeated suggestions (no twin buttons)", () => {
    const answer = "结论。\n💡 你可能还想问：\n- 调用方有哪些？\n- 调用方有哪些？\n- 它怎么初始化？";
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？", "它怎么初始化？"]);
  });

  it("STOPS at an evidence block if it follows the follow-ups (model misorder)", () => {
    // The model put the follow-ups BEFORE 供研发复核 — the evidence heading + its
    // citation lines must NOT become fake buttons (cross-review HIGH).
    const answer = [
      "结论。",
      "💡 你可能还想问：",
      "- 真问题一？",
      "> 🔍 **供研发复核**",
      "> File.cs:10 里定义",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual(["真问题一？"]);
  });

  it("STOPS at a ```chart fence after the follow-ups", () => {
    const answer = [
      "结论。",
      "💡 你可能还想问：",
      "- 真问题一？",
      "```chart",
      '{"type":"line","data":{"values":[]}}',
      "```",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual(["真问题一？"]);
  });

  it("a follow-up ITEM that merely mentions 供研发复核 is NOT a section boundary", () => {
    // The boundary regex is heading-anchored (line start + >/🔍/** decorations);
    // a list item whose TEXT contains the word must stay a real button — an
    // unanchored substring match used to drop it AND every button after it.
    const answer = [
      "结论。",
      "💡 你可能还想问：",
      "- 供研发复核的证据在哪里？",
      "- 另一个问题？",
    ].join("\n");
    expect(extractFollowUps(answer)).toEqual(["供研发复核的证据在哪里？", "另一个问题？"]);
  });

  it.each([
    ["> 🔍 **供研发复核**", "> Config.cs:10 基础伤害 = 50"],
    ["> **🔍 供研发复核**", "> Config.cs:10 基础伤害 = 50"],
    ["> 📎 依据", "> Config.cs:10 基础伤害 = 50"],
    ["> 🔀 需要你确认：请选择配置版本。", "> - 当前正式服配置是什么？"],
    ["> ### **🔀 需要你确认：请选择配置版本。**", "> - 当前正式服配置是什么？"],
    ["> ```chart", '> {"type":"line","data":{"values":[]}}\n> ```'],
    ["> ~~~text", "> 后续代码必须保留。\n> ~~~"],
  ])("preserves the following section while removing only suggestions: %s", (heading, content) => {
    const section = `${heading}\n${content}`;
    const answer = [
      "结论：基础伤害为 50。",
      "> ---",
      "> ### **💡 你可能还想问：**",
      "> - 调用方有哪些？",
      section,
    ].join("\n");
    expect(stripFollowUps(answer)).toBe(`结论：基础伤害为 50。\n${section}`);
    expect(extractFollowUps(answer)).toEqual(["调用方有哪些？"]);
  });
});
