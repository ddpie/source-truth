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
});
