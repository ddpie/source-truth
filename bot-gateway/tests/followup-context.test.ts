/**
 * Tests for composeFollowUpPrompt — replays the prior conversation CHAIN
 * (oldest→newest) as explicit context so multiple follow-ups/replies build the
 * whole history (the agent doesn't carry history across invokes). Must: include
 * every prior turn, keep order, send the follow-up as-is when there's no context,
 * and never lose the new question.
 */

import { composeFollowUpPrompt } from "../src/followup-context";

describe("composeFollowUpPrompt", () => {
  it("replays a single prior turn then the new follow-up", () => {
    const out = composeFollowUpPrompt("那它有上限吗？", [
      { question: "负重上限怎么决定？", answer: "负重上限 = 力量 × 1.5。" },
    ]);
    expect(out).toContain("负重上限怎么决定？");
    expect(out).toContain("负重上限 = 力量 × 1.5。");
    expect(out).toContain("那它有上限吗？");
    expect(out.indexOf("那它有上限吗？")).toBeGreaterThan(out.indexOf("负重上限 = 力量"));
  });

  it("replays a MULTI-turn chain in order (whole history, not just last)", () => {
    const out = composeFollowUpPrompt("第三个追问", [
      { question: "Q1", answer: "A1" },
      { question: "Q2", answer: "A2" },
    ]);
    // Both prior turns present, in order, before the new question.
    expect(out.indexOf("Q1")).toBeLessThan(out.indexOf("Q2"));
    expect(out.indexOf("A1")).toBeLessThan(out.indexOf("A2"));
    expect(out.indexOf("A2")).toBeLessThan(out.indexOf("第三个追问"));
  });

  it("sends the follow-up as-is when there is no prior context", () => {
    expect(composeFollowUpPrompt("继续", [])).toBe("继续");
    expect(composeFollowUpPrompt("继续", [{ question: "", answer: "" }])).toBe("继续");
  });

  it("includes whichever side of a prior turn is present", () => {
    expect(composeFollowUpPrompt("q", [{ question: "Q only" }])).toContain("Q only");
    expect(composeFollowUpPrompt("q", [{ answer: "A only" }])).toContain("A only");
  });

  it("frames prior answers as context to re-verify, not as established truth", () => {
    const out = composeFollowUpPrompt("再问", [{ question: "x", answer: "y" }]);
    expect(out).toMatch(/取证|代码|verify/);
  });
});
