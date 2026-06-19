/**
 * Unit tests for extractCharts — pulls ```chart fenced blocks (VChart specs)
 * out of the agent's answer so the gateway can render them as CardKit chart
 * components, leaving the prose text clean.
 */

import { extractCharts } from "../src/extract-charts";
import { buildChartElements } from "../src/cardkit-client";

describe("extractCharts", () => {
  it("extracts a single chart spec and strips it from the text", () => {
    const answer = [
      "各等级伤害如下：",
      "```chart",
      '{"type":"bar","data":{"values":[{"lv":1,"dmg":10}]}}',
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

  it("accepts the allow-listed types case-insensitively", () => {
    expect(extractCharts('```chart\n{"type":"BAR"}\n```').charts).toHaveLength(1);
    expect(extractCharts('```chart\n{"type":"Line"}\n```').charts).toHaveLength(1);
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
      '答案\n```chart\n{"type":"line"}```',                 // no newline before closing fence
      "答案\n  ```chart\n  {\"type\":\"pie\"}\n  ```",         // indented
      '答案\n```chart json\n{"type":"bar"}\n```',           // extra language token
      '答案\n```chart {"type":"pie"}```',                   // compact single-line
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
      '{"type":"bar","data":{"values":[]}}',
      "```",
      "和",
      "```chart",
      '{"type":"line","data":{"values":[]}}',
      "```",
    ].join("\n");
    const { charts } = extractCharts(answer);
    expect(charts).toHaveLength(2);
    expect(charts[0].type).toBe("bar");
    expect(charts[1].type).toBe("line");
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
});
