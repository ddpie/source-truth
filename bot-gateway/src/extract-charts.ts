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

// Match a ```chart fence tolerantly. The agent emits free-form text and an LLM
// varies the fence a lot, so we must NOT require a rigid "```chart\n…\n```" at
// column 0 — a near-miss otherwise leaves the raw fence + JSON verbatim in the
// prose card (ugly, and the per-leaf redactDeep safety net never runs on it).
// Tolerate: leading indentation; an extra language/word token after `chart`
// (e.g. "```chart json"); whitespace-or-newline between the tag and the body
// (covers compact single-line "```chart {…}```"); and a missing trailing newline
// before the closing fence. `m` so ^ anchors per line. Body captured lazily.
const CHART_BLOCK = /^[ \t]*```chart[^\S\n]*\w*[^\S\n]*([\s\S]*?)\n?[ \t]*```[ \t]*$/gm;

export interface ChartSpec {
  type: string;
  [key: string]: unknown;
}

export function extractCharts(answer: string): { text: string; charts: ChartSpec[] } {
  const charts: ChartSpec[] = [];
  let text = answer.replace(CHART_BLOCK, (_full, body: string) => {
    try {
      const spec = JSON.parse(body.trim()) as ChartSpec;
      if (spec && typeof spec.type === "string") charts.push(spec);
    } catch { /* invalid JSON → drop the block, don't render a broken chart */ }
    return ""; // strip the block from the prose regardless
  });
  // Defense-in-depth: if any ```chart fence STILL slipped through (a shape the
  // regex didn't anticipate), strip the residual fence so the raw spec never
  // renders verbatim in the group-visible card. We drop from the fence to the next
  // closing ``` (or end of text if unterminated).
  if (/```chart/.test(text)) {
    text = text.replace(/```chart[\s\S]*?(?:```|$)/g, "");
  }
  // Collapse the blank lines left where blocks were removed.
  return { text: text.replace(/\n{3,}/g, "\n\n").trim(), charts };
}
