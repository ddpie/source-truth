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

  it("strips the 7th E2E case: '…数值都已读到，来整理成完整对比表。' running into a table (no separator)", () => {
    const body = "所有武器的伤害区间数值都已读到，来整理成完整对比表。各武器的基础伤害如下：";
    expect(stripPreamble(body)).toBe("各武器的基础伤害如下：");
  });

  it("does NOT over-strip a real answer mentioning 读到 mid-sentence with a table", () => {
    const body = "所有武器的伤害都写在配置表里，可以逐项调整。\n详见下表。";
    expect(stripPreamble(body)).toBe(body);
  });

  it("never cuts ON a table separator: the FULL table survives intact", () => {
    const body = "整理一下答案如下：\n| A | B |\n| --- | --- |\n| 1 | 2 |";
    // '整理一下答案如下：' is a leading preamble (now recognized), so it IS dropped —
    // but the table is the real answer and MUST survive whole, separator included
    // (the `| --- |` row must NOT be mistaken for the preamble's `---` cut point).
    const out = stripPreamble(body);
    expect(out).toBe("| A | B |\n| --- | --- |\n| 1 | 2 |");
    expect(out).toContain("| --- | --- |"); // table separator intact
    expect(out).not.toContain("整理一下答案"); // preamble intro dropped (结论先行)
  });

  it("does NOT cut a real answer's inline --- that is a table separator (no preamble head)", () => {
    // A body whose head is NOT a preamble must be left entirely alone, table and all.
    const body = "暴击倍率对照：\n| 等级 | 倍率 |\n| --- | --- |\n| 1 | 1.5 |";
    expect(stripPreamble(body)).toBe(body);
  });

  // REGRESSION (observed live via card read-back): two planning preambles that
  // ended in a PROCESS-OUTPUT noun/verb (信息 / 整理输出), not 答案/结论, leaked into
  // the body and violated 结论先行.
  it("strips '现在我有完整的数据，来整理所有怪物的完整信息。' (ends in 信息, object phrase between)", () => {
    const body = "现在我有完整的数据，来整理所有怪物的完整信息。\n\n怪物的生命值非常多样。";
    expect(stripPreamble(body)).toBe("怪物的生命值非常多样。");
  });

  it("strips '已经掌握全部怪物生命值数据，现在整理输出。' (ends in bare verb 输出)", () => {
    expect(stripPreamble("已经掌握全部怪物生命值数据，现在整理输出。\n\n各类怪物差别很大。"))
      .toBe("各类怪物差别很大。");
    // also without a separating blank line
    expect(stripPreamble("已经掌握全部怪物生命值数据，现在整理输出。各类怪物差别很大。"))
      .toBe("各类怪物差别很大。");
  });

  it("does NOT over-strip real answers that merely begin with 现在/整理/已经", () => {
    for (const real of [
      "现在的怪物生命值上限是 210 点，比旧版高很多。",
      "整理背包的逻辑在 BagSystem.cs 里实现。",
      "已经实装的怪物有 30 种，数据写死在代码里。",
    ]) {
      expect(stripPreamble(real)).toBe(real);
    }
  });

  // REGRESSION (observed live): readiness → announce-tail forms whose readiness
  // clause the specific patterns missed (取证完毕 / 查清 / 齐全), but which END their
  // first sentence announcing "现在整理答案 / 下面给出结论" — unambiguously a preamble.
  it("strips broad readiness→announce-tail preambles", () => {
    expect(stripPreamble("所有关键信息都已取证完毕，现在整理答案。\n\n这个项目是 X。"))
      .toBe("这个项目是 X。");
    expect(stripPreamble("代码都已查清，下面给出结论。\n\n伤害是 100。")).toBe("伤害是 100。");
    expect(stripPreamble("数据齐全，接下来汇总内容。\n\n背包 30 格。")).toBe("背包 30 格。");
  });

  it("does NOT over-strip a real answer whose first sentence CONTINUES past the announce phrase", () => {
    for (const real of [
      "现在整理答案的逻辑在 AnswerBuilder.cs 里实现，分三步。",
      "下面给出结论性的伤害公式：伤害 = 力量 × 1.5，这是真实答案正文继续写下去。",
      "接下来要触发的技能是火球术，冷却 8 秒。",
    ]) {
      expect(stripPreamble(real)).toBe(real);
    }
  });

  // REGRESSION (observed live on a sonnet card): a preamble ending in a result noun
  // + 如下 ("整理答案如下。" / "给出结论如下：") leaked into the body.
  it("strips an announce preamble that ends in 如下 / 如下所示", () => {
    expect(stripPreamble("已拿到完整信息，整理答案如下。\n\n角色的最大负重由力量决定。"))
      .toBe("角色的最大负重由力量决定。");
    expect(stripPreamble("数据齐全，现在给出结论如下：\n\n伤害是 100。")).toBe("伤害是 100。");
  });

  it("does NOT over-strip a real answer whose first sentence ends in 如下 then continues", () => {
    for (const real of [
      "升级所需经验如下表所示，从 1 到 10 级递增。",
      "配置表如下：A=1,B=2。",
    ]) {
      expect(stripPreamble(real)).toBe(real);
    }
  });

  // REGRESSION (observed live): readiness + 来整理…设定/逻辑/机制/规则 (an object phrase
  // between 整理 and the noun) leaked into the body.
  it("strips '现在已经掌握了完整数据，来整理全部怪物的…设定。'", () => {
    expect(stripPreamble("现在已经掌握了完整数据，来整理全部怪物的生命值和攻击力设定。\n\n怪物分两大类。"))
      .toBe("怪物分两大类。");
  });

  it("does NOT over-strip a real answer mentioning 设定/逻辑 mid-sentence", () => {
    for (const real of [
      "怪物的攻击力设定在 EnemyBasics.cs 里，按等级区间随机。",
      "整理逻辑由 Sorter.cs 负责，分三步执行。",
    ]) {
      expect(stripPreamble(real)).toBe(real);
    }
  });

  // Observed live: readiness + a BARE announce verb (整理/汇总/梳理) with NO trailing
  // 答案/结论 noun. The prior patterns all required a result noun → this leaked.
  it("strips a readiness + bare-announce-verb preamble ('…都核实清楚了，下面整理。')", () => {
    expect(stripPreamble("已经把成长途径都核实清楚了，下面整理。\n\n力量靠升级加点成长。"))
      .toBe("力量靠升级加点成长。");
    expect(stripPreamble("数据都查清了，我来梳理一下。答案正文。")).toBe("答案正文。");
    expect(stripPreamble("下面整理一下。\n\n真正的答案。")).toBe("真正的答案。");
  });

  it("does NOT over-strip a real sentence that BEGINS with 下面整理 but continues", () => {
    const real = "下面整理的逻辑都写在 InventoryManager.cs 里，包括扩容规则。";
    expect(stripPreamble(real)).toBe(real);
  });

  // Observed live: readiness + 整理成结论 / 直接回答 (verb+成/出 or a 直接 prefix with
  // no 现在/来). The result-noun is now optional, guarded by FULL-sentence match.
  it("strips '…的完整逻辑，下面整理成结论。' and '两块都查到了，下面直接回答。'", () => {
    expect(stripPreamble("我已经掌握了武器耐久从消耗到修复的完整逻辑，下面整理成结论。\n\n武器耐久内部叫 condition。"))
      .toBe("武器耐久内部叫 condition。");
    expect(stripPreamble("两块都查到了，下面直接回答。\n\n结论：金币掉落不在配置表里。"))
      .toBe("结论：金币掉落不在配置表里。");
  });

  it("does NOT over-strip real sentences beginning with 下面直接 / 直接回答 / 回答 that continue", () => {
    for (const real of [
      "下面直接说重点：伤害 = 攻击 × 系数。",
      "直接回答你的问题需要先看 DamageCalc.cs 的逻辑。",
      "回答这个问题要分三步，下面逐一说明。",
    ]) {
      expect(stripPreamble(real)).toBe(real);
    }
  });
});
