/**
 * Tests for stripPreamble — removing a planning/transition preamble that leaked
 * into the conclusion body (violating 结论先行). Conservative: must strip the
 * real leaked cases but NEVER mangle a legitimate answer.
 */

import { stripPreamble } from "../src/strip-preamble";

describe("stripPreamble", () => {
  it("strips the exact E2E-observed leaked preamble (现在我已经掌握… + ---)", () => {
    // The real card body from the 2026-06-19 EFS-removal E2E test.
    const body =
      "现在我已经掌握了足够的信息，来整理答案。这个项目的物品栏不是「格子数」的概念，而是基于承重的。\n---\n这个项目的**物品栏没有「格子数」这个概念**——背包的限制按承重上限来控制。";
    const out = stripPreamble(body);
    expect(out.startsWith("这个项目的**物品栏没有")).toBe(true);
    expect(out).not.toContain("现在我已经掌握");
  });

  it("strips a '整理答案' transition + separator", () => {
    const body = "好的，我来整理一下答案。\n---\n暴击倍率按等级分档，从 1.5 倍到 2.0 倍封顶。";
    expect(stripPreamble(body)).toBe("暴击倍率按等级分档，从 1.5 倍到 2.0 倍封顶。");
  });

  it("strips an English planning preamble", () => {
    const body = "Now let me compile the answer.\n---\nThe default bag capacity is 30 slots.";
    expect(stripPreamble(body)).toBe("The default bag capacity is 30 slots.");
  });

  it("does NOT strip a real answer that merely contains a --- separator", () => {
    // A legitimate answer can use --- as a section divider; the head before it is
    // real content, not a planning preamble, so it must be preserved.
    const body =
      "背包初始默认是 30 格。游戏启动时读配置表覆盖内置默认值。\n---\n改背包配置表的 default_capacity 即可。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("does NOT strip when there is no separator", () => {
    const body = "现在的暴击倍率是 1.5 倍。"; // starts with 现在 but no ---, and is the answer
    expect(stripPreamble(body)).toBe(body);
  });

  it("does NOT strip when the head before --- is long (it's the answer, not a preamble)", () => {
    const longHead = "这个数值的计算逻辑很复杂，".repeat(10); // > MAX_PREAMBLE_LEN
    const body = `${longHead}\n---\n后续补充。`;
    expect(stripPreamble(body)).toBe(body);
  });

  it("does NOT strip a normal answer with no preamble opener", () => {
    const body = "暴击倍率是 1.5 倍。\n---\n详见配置表。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("keeps the original if stripping would empty the body", () => {
    const body = "现在我整理答案。\n---\n   "; // nothing real after the separator
    expect(stripPreamble(body)).toBe(body);
  });

  it("handles empty / whitespace input", () => {
    expect(stripPreamble("")).toBe("");
    expect(stripPreamble("   ")).toBe("   ");
  });

  it("tolerates a preamble with extra dashes (-----)", () => {
    const body = "现在整理答案：\n-----\n答案在这里。";
    expect(stripPreamble(body)).toBe("答案在这里。");
  });
});
