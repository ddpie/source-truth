/**
 * Unit tests for extractCharts — pulls ```chart fenced blocks (VChart specs)
 * out of the agent's answer so the gateway can render them as CardKit chart
 * components, leaving the prose text clean.
 */

import { extractCharts } from "../src/extract-charts";

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

  it("ignores a chart block with invalid JSON (keeps it out of charts)", () => {
    const answer = "见图：\n```chart\n{not valid json}\n```\n完。";
    const { charts } = extractCharts(answer);
    expect(charts).toHaveLength(0);
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
