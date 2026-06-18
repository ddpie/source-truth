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
