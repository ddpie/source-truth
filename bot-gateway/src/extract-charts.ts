/**
 * Extract ```chart fenced blocks (VChart specs) from the agent's answer.
 *
 * The agent, when a question is best answered with a chart (e.g. damage growth
 * across levels, CD comparison), emits a fenced block:
 *   ```chart
 *   { "type": "bar", "data": { "values": [ ... real config-table numbers ] } }
 *   ```
 * We pull those out, parse each as a VChart spec, and return the prose text
 * with the blocks removed so the gateway can render charts as CardKit chart
 * components separately from the conclusion text.
 *
 * "代码为唯一依据": the agent builds specs from real data it read; the gateway
 * only transports them.
 */

const CHART_BLOCK = /```chart\s*\n([\s\S]*?)\n```/g;

export interface ChartSpec {
  type: string;
  [key: string]: unknown;
}

export function extractCharts(answer: string): { text: string; charts: ChartSpec[] } {
  const charts: ChartSpec[] = [];
  const text = answer.replace(CHART_BLOCK, (_full, body: string) => {
    try {
      const spec = JSON.parse(body) as ChartSpec;
      if (spec && typeof spec.type === "string") charts.push(spec);
    } catch { /* invalid JSON → drop the block, don't render a broken chart */ }
    return ""; // strip the block from the prose regardless
  });
  // Collapse the blank lines left where blocks were removed.
  return { text: text.replace(/\n{3,}/g, "\n\n").trim(), charts };
}
