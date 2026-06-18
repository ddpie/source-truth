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
      '答案\n```chart json\n{"type":"area"}\n```',          // extra language token
      '答案\n```chart {"type":"scatter"}```',               // compact single-line
    ];
    for (const v of variants) {
      const { text, charts } = extractCharts(v);
      expect(charts).toHaveLength(1);
      expect(text).not.toContain("```chart"); // never leak the fence into the card
      expect(text).not.toContain("type"); // nor the raw spec JSON
      expect(text).toContain("答案");
    }
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
