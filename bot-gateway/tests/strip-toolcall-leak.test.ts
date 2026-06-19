import { stripToolCallLeak, isToolCallLeakDominant } from "../src/strip-toolcall-leak";

// Build tool-call markup at runtime so the literal tags don't confuse tooling that
// parses this source. A = the namespace prefix Anthropic models emit.
const A = "antml:";
const inv = (name: string, params = "") => `<${A}invoke name="${name}">${params}</${A}invoke>`;
const param = (n: string, v: string) => `<${A}parameter name="${n}">${v}</${A}parameter>`;
const fcWrap = (inner: string) => `<${A}function_calls>\n${inner}\n</${A}function_calls>`;
// bare (no-prefix) variants, for the original observed shape
const binv = (name: string, params = "") => `<invoke name="${name}">${params}</invoke>`;

describe("stripToolCallLeak — bare form", () => {
  it("strips a full function_calls/invoke block (the originally observed leak)", () => {
    const body = [
      "先去配置表里找怪物相关的数值数据。",
      "",
      "<function_calls>",
      binv("codegraph_search_files", '<parameter name="pattern">hp|health</parameter>'),
      "</function_calls>",
      "",
      "怪物的生命值在 EnemyBasics.cs 里定义。",
    ].join("\n");
    const out = stripToolCallLeak(body);
    expect(out).not.toContain("invoke");
    expect(out).not.toContain("function_calls");
    expect(out).not.toContain("parameter");
    expect(out).toContain("先去配置表里找怪物");
    expect(out).toContain("怪物的生命值在 EnemyBasics.cs 里定义。");
  });

  it("strips markup wrapped in markdown bold", () => {
    const body = `答案如下。\n**${binv("codegraph_glob_files")}**\n真正的结论。`;
    expect(stripToolCallLeak(body)).not.toContain("invoke");
    expect(stripToolCallLeak(body)).toContain("真正的结论。");
  });

  it("strips an orphan unclosed <invoke> (truncated stream)", () => {
    const body = '结论在这里。\n<invoke name="codegraph_read_file">';
    const out = stripToolCallLeak(body);
    expect(out).toContain("结论在这里。");
    expect(out).not.toContain("invoke");
  });

  it("leaves a normal answer untouched (no markup)", () => {
    const body = "暴击倍率是 1.5 倍。\n| 等级 | 倍率 |\n|---|---|\n| 1 | 1.5 |";
    expect(stripToolCallLeak(body)).toBe(body);
  });

  it("does not touch prose that merely mentions the word invoke", () => {
    const body = "这个函数会 invoke 回调，但不修改状态。";
    expect(stripToolCallLeak(body)).toBe(body);
  });
});

describe("stripToolCallLeak — antml: prefix (dominant real Claude shape)", () => {
  it("strips antml:-prefixed invoke/parameter/function_calls entirely", () => {
    const block = fcWrap(inv("codegraph_search_files", param("pattern", "hp|health")));
    const body = `先查配置表。\n${block}\n怪物 HP 在 EnemyBasics.cs。`;
    const out = stripToolCallLeak(body);
    expect(out).not.toContain("invoke");
    expect(out).not.toContain("parameter");
    expect(out).not.toContain("function_calls");
    expect(out).toContain("先查配置表。");
    expect(out).toContain("怪物 HP 在 EnemyBasics.cs。");
  });

  it("strips a wrapper-LESS antml invoke block (no function_calls wrapper)", () => {
    const body = `答案：\n${inv("codegraph_glob_files", param("pattern", "**/*.cs"))}`;
    const out = stripToolCallLeak(body);
    expect(out).not.toContain("invoke");
    expect(out).toContain("答案：");
  });
});

describe("stripToolCallLeak — haiku <attempt_tool> shape", () => {
  it("strips a haiku <attempt_codegraph_*> tool-call block (real observed shape)", () => {
    const body = [
      "先定位负重系统的计算逻辑。",
      "",
      "<attempt_codegraph_symbol_search>",
      '{ "pattern": "负重|weight", "limit": 20 }',
      "</attempt_codegraph_symbol_search>",
      "",
      "负重上限在 FormulaHelper.cs。",
    ].join("\n");
    const out = stripToolCallLeak(body);
    expect(out).not.toContain("attempt_");
    expect(out).toContain("先定位负重系统的计算逻辑。");
    expect(out).toContain("负重上限在 FormulaHelper.cs。");
  });

  it("strips multiple jammed attempt blocks and an orphan open", () => {
    const body = '查一下。\n<attempt_codegraph_search_files>\n{"pattern":"x"}\n</attempt_codegraph_search_files>\n<attempt_codegraph_glob_files>';
    const out = stripToolCallLeak(body);
    expect(out).not.toContain("attempt_");
    expect(out).toContain("查一下。");
  });

  it("does not touch prose mentioning the word attempt normally", () => {
    const body = "这是第一次 attempt 调用失败后的重试逻辑说明。";
    expect(stripToolCallLeak(body)).toBe(body); // no <attempt_ tag → untouched
  });

  it("flags a haiku attempt-dominant body via isToolCallLeakDominant", () => {
    const blocks = Array.from({ length: 5 }, (_v, i) =>
      `<attempt_codegraph_search_files>\n{"pattern":"q${i}"}\n</attempt_codegraph_search_files>`,
    ).join("\n");
    expect(isToolCallLeakDominant("先查。\n" + blocks)).toBe(true);
  });
});

describe("isToolCallLeakDominant", () => {
  it("is TRUE when the body is mostly tool-call markup (bare)", () => {
    const blocks = Array.from({ length: 8 }, () =>
      `<function_calls>\n${binv("codegraph_glob_files", '<parameter name="pattern">**/*.cs</parameter>')}\n</function_calls>`,
    ).join("\n");
    expect(isToolCallLeakDominant("先找配置表。\n" + blocks)).toBe(true);
  });

  it("is TRUE for a wrapper-less antml leak (marker count must be antml-tolerant)", () => {
    const blocks = Array.from({ length: 5 }, () => inv("x", param("p", "v"))).join("\n");
    expect(isToolCallLeakDominant("先找。\n" + blocks)).toBe(true);
  });

  it("is TRUE for a leak PADDED with filler prose (ratio test, not absolute floor)", () => {
    // ~100 chars of filler + a big markup block: stripped survivor > 80 chars but
    // still <35% of the whole → must be flagged dominant.
    const filler = "我先去查一下配置表里的相关数值，再整理给你看，这一步只是说明检索方向并不是答案本身。";
    const blocks = Array.from({ length: 12 }, () => inv("codegraph_search_files", param("pattern", "x"))).join("\n");
    expect(isToolCallLeakDominant(filler + "\n" + blocks)).toBe(true);
  });

  it("is FALSE for a real answer with ONE incidental leaked block", () => {
    const body = "怪物生命值：鼠 4、兽人 30、狼人 50。详见配置表，数据齐全，逐项核对无误，这是一段完整的真实答案足够长不应被判为泄漏主导。\n" + binv("x");
    expect(isToolCallLeakDominant(body)).toBe(false);
  });

  it("is FALSE for a clean answer (no markers)", () => {
    expect(isToolCallLeakDominant("暴击倍率 1.5 倍。")).toBe(false);
  });
});

describe("no ReDoS on many unclosed invoke opens", () => {
  it("strips fast on a degenerate body of thousands of unclosed opens", () => {
    const body = `<${A}invoke name="x">\n`.repeat(20000);
    const t0 = Date.now();
    stripToolCallLeak(body);
    expect(Date.now() - t0).toBeLessThan(2000); // bounded gap → no O(n^2) stall
  });

  it("strips fast on a long '*' run after a markup marker (leading bold-marker ReDoS)", () => {
    // The leading bold marker was `\\**` (unbounded). A `<function_calls>` (so
    // hasToolCallMarkup passes) + tens of thousands of '*' with no matchable tag made
    // every pattern retry `\\**` from each offset → O(n^2) (~10s at 32k). Bounded to
    // \\*{0,4} → linear (cross-review P0).
    const body = `<${A}function_calls> ` + "*".repeat(200000);
    const t0 = Date.now();
    stripToolCallLeak(body);
    expect(Date.now() - t0).toBeLessThan(1000);
  });

  it("still strips a real bold-wrapped invoke block (the bound keeps correctness)", () => {
    const leak = `结论X。\n**${inv("codegraph_read_file", param("p", "a"))}**\n后续。`;
    const out = stripToolCallLeak(leak);
    expect(out).not.toMatch(/invoke|parameter/);
    expect(out).toContain("结论X");
    expect(out).toContain("后续");
  });
});
