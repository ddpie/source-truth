/**
 * Unit tests for extractCharts — pulls ```chart fenced blocks (VChart specs)
 * out of the agent's answer so the gateway can render them as CardKit chart
 * components, leaving the prose text clean.
 */

import { extractCharts, chartRejectReason } from "../src/extract-charts";
import { buildChartElements, ensureAxisTitlesVisible } from "../src/cardkit-client";

// A minimal RENDERABLE spec helper: real bindable fields + numeric yField, so these
// extraction/stripping tests aren't rejected by the render-validity guard. The fence-
// shape / type-allowlist / strip behaviors are what's under test here, not binding.
const okBar = (extra = "") => `{"type":"bar","data":{"values":[{"x":"L1","y":1}]},"xField":"x","yField":"y"${extra}}`;
const okSpec = (type: string) => `{"type":"${type}","data":{"values":[{"x":"L1","y":1}]},"xField":"x","yField":"y","valueField":"y","categoryField":"x"}`;

describe("extractCharts", () => {
  it("extracts a single chart spec and strips it from the text", () => {
    const answer = [
      "各等级伤害如下：",
      "```chart",
      '{"type":"bar","data":{"values":[{"lv":1,"dmg":10}]},"xField":"lv","yField":"dmg"}',
      "```",
      "可见伤害随等级线性增长。",
    ].join("\n");
    const { text, charts } = extractCharts(answer);
    expect(charts).toHaveLength(1);
    expect(charts[0].type).toBe("bar");
    expect(text).not.toContain("```chart");
    expect(text).toContain("各等级伤害如下");
    expect(text).toContain("可见伤害随等级线性增长");
  });

  it("returns no charts when there is no chart block", () => {
    const { text, charts } = extractCharts("就是一段普通回答，没有图。");
    expect(charts).toHaveLength(0);
    expect(text).toBe("就是一段普通回答，没有图。");
  });

  it("drops an UNSUPPORTED chart type (allow-list: bar/line/pie) but still strips the fence", () => {
    for (const bad of ["scatter", "area", "sankey", "barr", "gauge"]) {
      const { text, charts } = extractCharts(`见图：\n\`\`\`chart\n{"type":"${bad}"}\n\`\`\`\n完。`);
      expect(charts).toHaveLength(0);            // unsupported → dropped, not a broken card element
      expect(text).not.toContain("```chart");    // fence still stripped from prose
      expect(text).toContain("完。");
    }
  });

  it("accepts the allow-listed types case-insensitively (with bindable data)", () => {
    expect(extractCharts("```chart\n" + okSpec("BAR") + "\n```").charts).toHaveLength(1);
    expect(extractCharts("```chart\n" + okSpec("Line") + "\n```").charts).toHaveLength(1);
  });

  it("drops an OVERSIZED chart spec (>20KB) cleanly, no broken card element", () => {
    const huge = JSON.stringify({ type: "bar", data: { values: Array.from({ length: 5000 }, (_, i) => ({ x: i, y: i })) } });
    expect(huge.length).toBeGreaterThan(20_000);
    const { text, charts } = extractCharts("图：\n```chart\n" + huge + "\n```\n尾。");
    expect(charts).toHaveLength(0);            // oversized → dropped
    expect(text).not.toContain("```chart");    // fence still stripped
    expect(text).toContain("尾。");
  });

  it("ignores a chart block with invalid JSON (keeps it out of charts AND out of prose)", () => {
    const answer = "见图：\n```chart\n{not valid json}\n```\n完。";
    const { text, charts } = extractCharts(answer);
    expect(charts).toHaveLength(0);
    expect(text).not.toContain("```chart"); // must not leak the raw fence
    expect(text).not.toContain("not valid json");
  });

  it("tolerates LLM fence variants (no trailing newline / indented / 'chart json' / compact inline) — extracts AND never leaks the raw fence", () => {
    const variants = [
      `答案\n\`\`\`chart\n${okSpec("line")}\`\`\``,                 // no newline before closing fence
      `答案\n  \`\`\`chart\n  ${okSpec("pie")}\n  \`\`\``,           // indented
      `答案\n\`\`\`chart json\n${okSpec("bar")}\n\`\`\``,           // extra language token
      `答案\n\`\`\`chart ${okSpec("pie")}\`\`\``,                   // compact single-line
    ];
    for (const v of variants) {
      const { text, charts } = extractCharts(v);
      expect(charts).toHaveLength(1);
      expect(text).not.toContain("```chart"); // never leak the fence into the card
      expect(text).not.toContain("type"); // nor the raw spec JSON
      expect(text).toContain("答案");
    }
  });

  it("PRESERVES prose that merely mentions ```chart (how-to answers) — no destructive backstop", () => {
    // The residual-fence backstop must be fence-shaped, not a substring match, or
    // a how-to answer explaining charting loses its body.
    for (const prose of [
      "要画图请输出一个 ```chart 围栏，里面写 VChart spec，然后系统会渲染。",
      "用法：写 ```chart 开头。\n\n示例代码：\n```\nfoo()\n```\n\n完。",
    ]) {
      const { text, charts } = extractCharts(prose);
      expect(charts).toHaveLength(0);
      expect(text).toContain("```chart"); // the literal mention survives in prose
    }
    // The unrelated code block in the 2nd case must stay intact.
    const { text } = extractCharts("用法：写 ```chart 开头。\n\n示例：\n```\nfoo()\n```\n\n完。");
    expect(text).toContain("foo()");
    expect(text).toContain("完");
  });

  it("does NOT treat ```chartreuse (a language tag) as a chart fence", () => {
    const { text, charts } = extractCharts("颜色示例：\n```chartreuse\nsome prose\n```\n结束");
    expect(charts).toHaveLength(0);
    expect(text).toContain("some prose"); // block prose not deleted
  });

  it("extracts multiple chart blocks", () => {
    const answer = [
      "```chart",
      okBar(),
      "```",
      "和",
      `{"type":"line","data":{"values":[{"x":"L1","y":2}]},"xField":"x","yField":"y"}`.replace(/^/, "```chart\n") + "\n```",
    ].join("\n");
    const { charts } = extractCharts(answer);
    expect(charts).toHaveLength(2);
    expect(charts[0].type).toBe("bar");
    expect(charts[1].type).toBe("line");
  });

  // ── render-validity guard (cross-review P1: VChart silently draws a BLANK chart for
  //    a parseable-but-unbindable spec; drop it so the prose-table fallback stands) ──
  it("DROPS a bar/line spec whose xField/yField don't match data keys (silent-blank guard)", () => {
    const bad = '```chart\n{"type":"bar","data":{"values":[{"等级":"Lv1","攻击":100}]},"xField":"level","yField":"atk"}\n```';
    const { charts, dropped } = extractCharts("见图：\n" + bad + "\n完。");
    expect(charts).toHaveLength(0);                       // not rendered (would be blank)
    expect(dropped.some((d) => /not in every record/.test(d.reason))).toBe(true);
  });

  it("DROPS a spec whose yField values are unit-suffixed STRINGS, not numbers", () => {
    const bad = '```chart\n{"type":"line","data":{"values":[{"x":"L1","y":"100点"},{"x":"L2","y":"150点"}]},"xField":"x","yField":"y"}\n```';
    const { charts, dropped } = extractCharts(bad);
    expect(charts).toHaveLength(0);
    expect(dropped.some((d) => /not numeric/.test(d.reason))).toBe(true);
  });

  it("KEEPS a correctly-bound bar spec (numeric yField, fields match keys)", () => {
    const ok = '```chart\n{"type":"bar","data":{"values":[{"等级":"Lv1","攻击":100},{"等级":"Lv2","攻击":150}]},"xField":"等级","yField":"攻击"}\n```';
    expect(extractCharts(ok).charts).toHaveLength(1);
  });

  it("chartRejectReason: validates pie valueField/categoryField too", () => {
    expect(chartRejectReason({ type: "pie", data: { values: [{ k: "a", v: 1 }] }, valueField: "v", categoryField: "k" } as never)).toBeNull();
    expect(chartRejectReason({ type: "pie", data: { values: [{ k: "a", v: "1" }] }, valueField: "v", categoryField: "k" } as never)).toMatch(/not numeric/);
    expect(chartRejectReason({ type: "pie", data: { values: [{ k: "a", v: 1 }] }, categoryField: "k" } as never)).toMatch(/missing valueField/);
  });

  it("chartRejectReason: rejects empty/missing data.values", () => {
    expect(chartRejectReason({ type: "bar", data: { values: [] }, xField: "x", yField: "y" } as never)).toMatch(/empty data/);
    expect(chartRejectReason({ type: "bar", xField: "x", yField: "y" } as never)).toMatch(/empty data/);
  });
});

describe("buildChartElements", () => {
  it("wraps each VChart spec as a CardKit chart element", () => {
    const els = buildChartElements([{ type: "bar", data: { values: [] } }]) as Array<{
      tag: string; chart_spec: { type: string };
    }>;
    expect(els).toHaveLength(1);
    expect(els[0].tag).toBe("chart");
    expect(els[0].chart_spec.type).toBe("bar");
  });

  it("returns an empty array for no specs", () => {
    expect(buildChartElements([])).toEqual([]);
  });

  it("forces axis titles VISIBLE so the chart shows axis descriptions (user-reported)", () => {
    // VChart hides axis titles by default; an agent spec with title.text but no `visible`
    // rendered a chart with no axis labels. buildChartElements must inject visible:true.
    const spec = { type: "bar", data: { values: [{ x: "L1", y: 1 }] }, xField: "x", yField: "y",
      axes: [{ orient: "bottom", title: { text: "等级" } }, { orient: "left", title: { text: "攻击力" } }] };
    const els = buildChartElements([spec]) as Array<{ chart_spec: { axes: Array<{ title: { visible?: boolean; text: string } }> } }>;
    const ax = els[0].chart_spec.axes;
    expect(ax[0].title.visible).toBe(true);
    expect(ax[0].title.text).toBe("等级");        // text preserved
    expect(ax[1].title.visible).toBe(true);
  });
});

describe("ensureAxisTitlesVisible", () => {
  it("respects an explicit visible:false (don't override an intentional choice)", () => {
    const out = ensureAxisTitlesVisible({ type: "bar", axes: [{ orient: "bottom", title: { visible: false, text: "x" } }] }) as
      { axes: Array<{ title: { visible: boolean } }> };
    expect(out.axes[0].title.visible).toBe(false);
  });

  it("leaves an axis with no title text untouched (no empty title box)", () => {
    const out = ensureAxisTitlesVisible({ type: "bar", axes: [{ orient: "bottom" }] }) as { axes: Array<Record<string, unknown>> };
    expect(out.axes[0]).not.toHaveProperty("title");
  });

  it("is a no-op when there are no axes (e.g. a pie chart)", () => {
    const pie = { type: "pie", data: { values: [] }, valueField: "val", categoryField: "cat" };
    expect(ensureAxisTitlesVisible(pie)).toEqual(pie);
  });
});
