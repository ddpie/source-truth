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
});
