/**
 * Unit tests for the finalize decision logic extracted from runStreamingInvoke.
 * Round-15 review flagged that this composition — mapping an invoke outcome to
 * {hardFailed, turnCapped, keepCharts, keepFooter, remember} and the body text —
 * was asserted NOWHERE (index.ts is an untested entry shell), so a regression that
 * dropped follow-ups on a turn cap, rendered charts on a hard failure, or stored a
 * hard-failure body as context would ship silently. These lock the matrix.
 */

import { decideFinalize, hardFailureMessage, shapeBody } from "../src/finalize-decision";

const base = {
  failed: false, httpFailed: false, turnCappedRaw: false,
  aborted: false, timedOut: false, accessDenied: false,
};

describe("decideFinalize", () => {
  it("clean success → not hard-failed, keep charts/footer, remember", () => {
    const d = decideFinalize(base);
    expect(d).toEqual({ hardFailed: false, turnCapped: false, keepCharts: true, keepFooter: true, remember: true });
  });

  it("hard failure (HTTP) → hardFailed, drop charts/footer, do NOT remember", () => {
    const d = decideFinalize({ ...base, failed: true, httpFailed: true });
    expect(d.hardFailed).toBe(true);
    expect(d.keepCharts).toBe(false);
    expect(d.keepFooter).toBe(false);
    expect(d.remember).toBe(false);
  });

  it("turn cap (in-stream) → NOT hard-failed, KEEP charts/footer, remember (partial is still shown)", () => {
    const d = decideFinalize({ ...base, failed: true, turnCappedRaw: true });
    expect(d.turnCapped).toBe(true);
    expect(d.hardFailed).toBe(false);
    expect(d.keepCharts).toBe(true);  // a turn-capped partial keeps its charts/follow-ups
    expect(d.keepFooter).toBe(true);
    expect(d.remember).toBe(true);
  });

  it("turn-cap text on a NON-200 HTTP failure is NOT read as a turn cap (gated) → hard failure", () => {
    // The dangerous case: an HTTP error body containing 'maximum turns' must route
    // to hard-failure, not the partial-answer branch.
    const d = decideFinalize({ ...base, failed: true, httpFailed: true, turnCappedRaw: true });
    expect(d.turnCapped).toBe(false);
    expect(d.hardFailed).toBe(true);
    expect(d.remember).toBe(false);
  });

  it("a stream truncation (failed via error, not HTTP, not turn cap) → hard failure", () => {
    const d = decideFinalize({ ...base, failed: true, httpFailed: false, turnCappedRaw: false });
    expect(d.hardFailed).toBe(true);
  });
});

describe("hardFailureMessage", () => {
  it("gives the model-access hint when accessDenied", () => {
    expect(hardFailureMessage(true)).toContain("Model access");
  });
  it("gives the generic outage message otherwise", () => {
    const m = hardFailureMessage(false);
    expect(m).toContain("查询失败");
    expect(m).not.toContain("Model access");
  });
});

describe("shapeBody", () => {
  const flags = { turnCapped: false, aborted: false, timedOut: false };

  it("plain success returns the body verbatim", () => {
    expect(shapeBody("最终答案", flags)).toBe("最终答案");
  });
  it("empty body → (无内容) placeholder", () => {
    expect(shapeBody("", flags)).toBe("(无内容)");
  });
  it("turn cap WITH partial body appends the narrow-it disclaimer (kept visible, not folded)", () => {
    const out = shapeBody("部分结论", { ...flags, turnCapped: true });
    expect(out).toContain("部分结论");
    expect(out).toContain("未在限定步数内完成");
  });
  it("turn cap WITHOUT body gives the standalone narrow-it message", () => {
    const out = shapeBody("", { ...flags, turnCapped: true });
    expect(out).toContain("未在限定步数内得出结论");
  });
  it("aborted WITH body appends 已停止 note; WITHOUT body is just ⏹ 已停止", () => {
    expect(shapeBody("到一半", { ...flags, aborted: true })).toContain("已停止");
    expect(shapeBody("", { ...flags, aborted: true })).toBe("已停止。");
  });
  it("timed out with no body → the timeout narrow-it message", () => {
    expect(shapeBody("", { ...flags, timedOut: true })).toContain("分析超时");
  });
  it("turn cap takes precedence over aborted/timedOut when several flags set", () => {
    const out = shapeBody("x", { turnCapped: true, aborted: true, timedOut: true });
    expect(out).toContain("未在限定步数内完成"); // turn-cap branch wins
  });
});
