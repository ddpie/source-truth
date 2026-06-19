import { stripToolCallLeak, isToolCallLeakDominant } from "../src/strip-toolcall-leak";

describe("stripToolCallLeak", () => {
  it("strips a full function_calls/invoke block (the observed leak)", () => {
    const body = [
      "先去配置表里找怪物相关的数值数据。",
      "",
      "<function_calls>",
      '<invoke name="codegraph_search_files">',
      '<parameter name="pattern">hp|health</parameter>',
      "</invoke>",
      "</function_calls>",
      "",
      "怪物的生命值在 EnemyBasics.cs 里定义。",
    ].join("\n");
    const out = stripToolCallLeak(body);
    expect(out).not.toContain("<invoke");
    expect(out).not.toContain("function_calls");
    expect(out).not.toContain("<parameter");
    expect(out).toContain("先去配置表里找怪物");
    expect(out).toContain("怪物的生命值在 EnemyBasics.cs 里定义。");
  });

  it("strips markup wrapped in markdown bold (**</invoke>**)", () => {
    const body = '答案如下。\n**<invoke name="codegraph_glob_files">**\n**<parameter name="pattern">**/*.cs</parameter>**\n**</invoke>**\n真正的结论。';
    const out = stripToolCallLeak(body);
    expect(out).not.toContain("invoke");
    expect(out).toContain("真正的结论。");
  });

  it("strips an orphan unclosed <invoke> (truncated stream)", () => {
    const body = '结论在这里。\n<invoke name="codegraph_read_file">\n<parameter name="path">x.cs';
    const out = stripToolCallLeak(body);
    expect(out).toContain("结论在这里。");
    expect(out).not.toContain("<invoke");
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

describe("isToolCallLeakDominant", () => {
  it("is TRUE when the body is mostly tool-call markup (the empty-card case)", () => {
    const blocks = Array.from({ length: 8 }, (_, i) =>
      `<function_calls>\n<invoke name="codegraph_glob_files">\n<parameter name="pattern">**/*.cs</parameter>\n</invoke>\n</function_calls>`
    ).join("\n");
    const body = "先找配置表。\n" + blocks; // tiny prose + lots of markup
    expect(isToolCallLeakDominant(body)).toBe(true);
  });

  it("is FALSE for a real answer that contains ONE incidental leaked block", () => {
    const body = "怪物生命值：鼠 4、兽人 30、狼人 50。详见配置表，数据齐全，逐项核对无误，这是一段完整的真实答案足够长。\n<invoke name=\"x\"></invoke>";
    expect(isToolCallLeakDominant(body)).toBe(false);
  });

  it("is FALSE for a clean answer (no markers)", () => {
    expect(isToolCallLeakDominant("暴击倍率 1.5 倍。")).toBe(false);
  });
});
