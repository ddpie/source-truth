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

  it("strips the 2nd E2E case: '所有关键逻辑都已读清楚' with INLINE --- (no newlines)", () => {
    // The exact 2026-06-19 升级 card: readiness meta-statement + inline --- separator.
    const body =
      "所有关键逻辑都已读清楚。可以给出完整答案了。---这个项目的**角色升级完全不使用「经验值」这个概念**——升级靠技能成长。";
    const out = stripPreamble(body);
    expect(out.startsWith("这个项目的**角色升级")).toBe(true);
    expect(out).not.toContain("所有关键逻辑都已读清楚");
    expect(out).not.toContain("可以给出完整答案");
  });

  it("strips '可以给出完整答案了' readiness opener", () => {
    const body = "可以给出完整答案了。---暴击倍率从 1.5 到 2.0 封顶。";
    expect(stripPreamble(body)).toBe("暴击倍率从 1.5 到 2.0 封顶。");
  });

  it("does NOT strip an inline --- inside a real answer (no preamble opener)", () => {
    // An answer with an inline triple-dash but NO planning opener must be untouched.
    const body = "暴击倍率是 1.5 倍（区间 1---10 级），高等级更高。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("strips the 3rd E2E case: readiness preamble as a leading sentence, NO --- separator", () => {
    // Exact 2026-06-19 reply card: preamble sentence then the answer on the next line.
    const body =
      "数值已从代码逐一核实，直接给出对比结论。\n**匕首**的基础伤害每次在 **1～6** 之间随机，平均 **3.5 点**。";
    const out = stripPreamble(body);
    expect(out.startsWith("**匕首**")).toBe(true);
    expect(out).not.toContain("数值已从代码逐一核实");
  });

  it("strips a leading '可以给出完整答案了。' sentence with no separator", () => {
    const body = "可以给出完整答案了。\n背包默认 30 格。";
    expect(stripPreamble(body)).toBe("背包默认 30 格。");
  });

  it("does NOT truncate a real first sentence that merely starts with a stripped word (no separator)", () => {
    // "现在的暴击倍率…" starts with 现在 but is the ANSWER. The strict standalone opener
    // set (used when there's no --- separator) EXCLUDES bare 现在, so this real first
    // sentence must be fully preserved.
    const body = "现在的暴击倍率是 1.5 倍，比上个版本高。\n详见配置表。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("does NOT strip a normal multi-line answer with no preamble opener (no separator)", () => {
    const body = "暴击倍率是 1.5 倍。\n不同等级会变化。";
    expect(stripPreamble(body)).toBe(body);
  });

  // --- over-strip regressions (cross-review: prefix-match was too greedy) ----
  it("does NOT strip a real sentence that merely BEGINS with 整理答案 (then continues)", () => {
    // "整理答案的逻辑在 Foo.java。" is a REAL answer about where assembly logic lives —
    // the opener must match the WHOLE sentence, not just the 整理答案 prefix.
    const body = "整理答案的逻辑在 Foo.java。\n它做了排序。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("does NOT strip '可以给出完整答案，但需要补充测试数据。' (real caveat, not a pure preamble)", () => {
    const body = "可以给出完整答案，但需要补充测试数据。\n详见下。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("STILL strips a pure '整理一下答案。' preamble (full-sentence match)", () => {
    const body = "整理一下答案。\n暴击倍率是 1.5 倍。";
    expect(stripPreamble(body)).toBe("暴击倍率是 1.5 倍。");
  });

  // --- round-2: strategy-1 (separator path) over-strip + markdown table ------
  it("does NOT strip a real first sentence (begins with 整理答案) even WITH a --- separator", () => {
    const body = "整理答案的逻辑在 Foo.java。\n---\n它做了排序。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("does NOT strip '可以给出完整答案，但…' WITH a --- separator", () => {
    const body = "可以给出完整答案，但需要补充测试数据。\n---\n详见下。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("does NOT chop a markdown TABLE whose first line begins with a preamble prefix", () => {
    // The inline `-{3,}` fallback must NEVER land on a `|---|` table separator —
    // the agent uses tables in answers; chopping there would halve the answer.
    const body = "可以给出对比数据如下：\n| 名称 | 伤害 |\n|---|---|\n| 匕首 | 3.5 |";
    expect(stripPreamble(body)).toBe(body);
  });

  it("strips the 4th E2E case: '已取得所有关键数据，现在整理完整答案。' + inline ---", () => {
    // Observed 2026-06-19 on the clarified-answer card.
    const body = "已取得所有关键数据，现在整理完整答案。---## 武器攻击伤害的完整算法…";
    expect(stripPreamble(body)).toBe("## 武器攻击伤害的完整算法…");
  });

  it("does NOT over-strip a real answer that mentions 已取得的数据 mid-sentence", () => {
    const body = "攻击力由武器决定，已取得的数据显示匕首 1-6。\n详见表。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("strips the 5th E2E case: '已经取到足够的信息，可以作答了。' + inline ---", () => {
    const body = "已经取到足够的信息，可以作答了。---怪物的攻击力数值全部写死在代码里。";
    expect(stripPreamble(body)).toBe("怪物的攻击力数值全部写死在代码里。");
  });

  it("does NOT over-strip a real answer whose first sentence begins with 回答", () => {
    const body = "回答这个问题需要先看配置表。\n配置表在 Config 下。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("strips the 6th E2E case: '所有信息都齐了，来整理答案。' + inline ---", () => {
    const body = "所有信息都齐了，来整理答案。---角色的负重上限完全由力量决定。";
    expect(stripPreamble(body)).toBe("角色的负重上限完全由力量决定。");
  });

  it("does NOT over-strip '所有信息都在配置表里…' (real answer, not a preamble)", () => {
    const body = "所有信息都在配置表里，可自行调整。\n详见表。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("does NOT match a --- adjacent to a table pipe as the cut point", () => {
    const body = "整理一下答案如下：\n| A | B |\n| --- | --- |\n| 1 | 2 |";
    // The head '整理一下答案如下' is a preamble-ish prefix, but the only `---` is in a
    // table separator (pipe-adjacent), so nothing is stripped.
    expect(stripPreamble(body)).toBe(body);
  });
});
