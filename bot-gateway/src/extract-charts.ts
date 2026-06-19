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
// `(?![A-Za-z0-9])` right after `chart` so "```chartreuse"/"```charts" (a real
// language tag) is NOT mistaken for a chart fence (which would delete its prose).
const CHART_BLOCK = /^[ \t]*```chart(?![A-Za-z0-9])[^\S\n]*\w*[^\S\n]*([\s\S]*?)\n?[ \t]*```[ \t]*$/gm;

export interface ChartSpec {
  type: string;
  [key: string]: unknown;
}

// Only these VChart types are known-good in a Feishu card. The model occasionally
// emits an unsupported/misspelled type ("scatter"/"sankey"/"barr"); passing it
// through makes Feishu reject the append → the chart silently fails to render. We
// drop an unknown type here instead (clean drop; the prose table the model also
// emits is the fallback). Lowercased before checking.
export const ALLOWED_CHART_TYPES = new Set(["bar", "line", "pie"]);
// A chart spec is real config-table numbers, not prose — a few KB at most. A
// pathological multi-thousand-point array would (a) likely exceed Feishu's per-card
// body size (rejected append) and (b) cost a redactDeep walk over every leaf on the
// finalize hot path. Bound the raw block so an oversized spec is dropped cleanly.
const MAX_CHART_SPEC_BYTES = 20_000;

export function extractCharts(answer: string): { text: string; charts: ChartSpec[] } {
  const charts: ChartSpec[] = [];
  let text = answer.replace(CHART_BLOCK, (_full, body: string) => {
    const trimmed = body.trim();
    if (trimmed.length > MAX_CHART_SPEC_BYTES) return ""; // oversized → drop, still strip from prose
    try {
      const spec = JSON.parse(trimmed) as ChartSpec;
      if (spec && typeof spec.type === "string"
          && ALLOWED_CHART_TYPES.has(spec.type.toLowerCase())) {
        charts.push(spec);
      }
    } catch { /* invalid JSON → drop the block, don't render a broken chart */ }
    return ""; // strip the block from the prose regardless
  });
  // Defense-in-depth: if a residual ```chart fence STILL slipped through (a shape
  // the primary regex didn't anticipate), strip it. CRITICAL: this must be
  // FENCE-SHAPED (line-start fence → line-start closing fence), NOT a bare
  // substring match — a substring backstop would delete legitimate PROSE that
  // merely mentions the literal text "```chart" (e.g. a how-to answer explaining
  // charting), and its `$` fallback would nuke everything to end-of-string on an
  // unterminated mention. The line-anchored form only removes an actual fenced
  // block and stops at the matching closing fence. `(?![A-Za-z0-9])` so
  // "```chartreuse" prose isn't caught either.
  if (/^[ \t]*```chart(?![A-Za-z0-9])/m.test(text)) {
    // BOUNDED gap (not `[\s\S]*?`): an UNBOUNDED lazy gap is O(n²) when the text has
    // many line-start "```chart" opens with no matching close — each open scans to
    // end-of-string (measured: 4000 unclosed opens ≈ 1s, blocking the single shared
    // event loop → a process-wide stall for every concurrent session). A real chart
    // spec is a few KB; cap the gap so the match stays linear, mirroring
    // strip-toolcall-leak.ts. An over-long block just isn't stripped here (it was
    // already dropped from `charts` by the MAX_CHART_SPEC_BYTES guard above).
    text = text.replace(/^[ \t]*```chart(?![A-Za-z0-9])[\s\S]{0,8000}?^[ \t]*```[ \t]*$/gm, "");
  }
  // Collapse the blank lines left where blocks were removed.
  return { text: text.replace(/\n{3,}/g, "\n\n").trim(), charts };
}
