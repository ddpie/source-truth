/**
 * Unit tests for splitEvidence — pulls the "📎 依据 / 供研发复核" section out of
 * the answer body so the gateway can render it as a folded collapsible panel.
 */

import { splitEvidence } from "../src/extract-evidence";

describe("splitEvidence", () => {
  it("splits the REAL prompt heading '> 🔍 **供研发复核**' out of the body", () => {
    // This is the exact form system.md:65 + the worked examples emit. Anchoring
    // the test on the real contract (not a synthetic 📎 依据) is the whole point.
    const answer = [
      "负重上限 = 力量 × 1.5。",
      "",
      "> 🔍 **供研发复核**",
      "> - FormulaHelper.cs:75 MaxEncumbrance()",
    ].join("\n");
    const { body, evidence } = splitEvidence(answer);
    expect(body).toBe("负重上限 = 力量 × 1.5。");
    expect(evidence).toBe("- FormulaHelper.cs:75 MaxEncumbrance()"); // "> " + heading stripped
    expect(evidence).not.toContain("供研发复核");
  });

  it("recognizes a DECORATED 供研发复核 heading (parenthetical / dash note) so evidence still folds, not leaks", () => {
    // If the agent decorates the heading, a too-strict marker would MISS it and the
    // raw `> file:line` block would leak into the user-facing conclusion. Tolerate
    // a trailing parenthetical / dash-note while staying line-anchored.
    for (const heading of ["> 🔍 **供研发复核**（仅研发看）", "> 🔍 供研发复核 - 以下为出处", "📎 供研发复核（研发可展开）"]) {
      const answer = `结论在此。\n\n${heading}\n> - FormulaHelper.cs:75 MaxEncumbrance()`;
      const { body, evidence } = splitEvidence(answer);
      expect(body).toBe("结论在此。");
      expect(evidence).toContain("FormulaHelper.cs:75");
      expect(body).not.toContain("供研发复核"); // the heading must NOT leak into the body
      expect(body).not.toContain("FormulaHelper"); // nor the file:line evidence
    }
  });

  it("does NOT mistake a prose sentence/line containing 依据 for the evidence marker", () => {
    // 依据 is a very common word ("根据/依据…"); a line that merely STARTS with 依据 +
    // a dash/paren is ordinary prose, NOT a heading. The 依据 fallback is heading-ONLY
    // (no decorated suffix) precisely so these don't fold the genuine conclusion lines
    // below them into the collapsed panel (a reverse leak).
    for (const prose of [
      "我判断的依据是后一行无条件覆盖了默认值，所以最终生效的是 75。",
      "这条规则代码为唯一依据，配置表改不了，要走研发。",
      "依据玩家当前等级，伤害会按公式提升。",
      "依据 - 玩家等级决定基础系数，VIP 再叠加倍率。",   // dash-led prose
      "依据 - 玩家等级计算",                            // short dash prose
      "依据（见上文）",                                 // standalone parenthetical prose
      "依据——是指代码里某段逻辑",                        // em-dash prose
    ]) {
      const { body, evidence } = splitEvidence(prose);
      expect(evidence).toBe(""); // no false split
      expect(body).toBe(prose);
    }
  });

  it("a prose line starting with 依据 does NOT fold the following conclusion lines (reverse-leak guard)", () => {
    const answer = "结算规则如下：\n依据 - 玩家等级决定基础系数，VIP 再叠加倍率。\n具体倍率见下表。\n节日活动会临时翻倍。";
    const { body, evidence } = splitEvidence(answer);
    expect(evidence).toBe("");          // no false evidence split
    expect(body).toContain("具体倍率见下表"); // the real conclusion lines stay visible
    expect(body).toContain("节日活动会临时翻倍");
  });

  it("still handles the lenient '📎 依据' / '> 依据' fallback heading", () => {
    const answer = "结论文本。\n\n> 📎 依据\n> - A.cs:1 foo()\n> - B.cs:2 bar()";
    const { body, evidence } = splitEvidence(answer);
    expect(body).toBe("结论文本。");
    expect(evidence).toBe("- A.cs:1 foo()\n- B.cs:2 bar()"); // "> " stripped
  });

  it("trims a trailing --- divider from the body", () => {
    const answer = "答案。\n\n---\n> 🔍 **供研发复核**\n> - X.cs:3";
    const { body } = splitEvidence(answer);
    expect(body).toBe("答案。"); // no dangling rule
  });

  it("returns the whole answer as body when there is no evidence marker", () => {
    const text = "就是个普通答案，没有依据区。提到「依据」二字也不该误触发。";
    const { body, evidence } = splitEvidence(text);
    expect(body).toBe(text);
    expect(evidence).toBe("");
  });

  it("does not match 依据 mid-sentence or prose mentions (only a heading line)", () => {
    expect(splitEvidence("这是判断的依据：力量越高负重越大。").evidence).toBe("");
    expect(splitEvidence("# 第一性原则：代码为唯一依据\n正文…").evidence).toBe("");
  });
});
