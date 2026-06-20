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

/**
 * Validate that a parsed chart spec will actually RENDER (not just parse). VChart
 * silently draws empty axes — no error — when the field references don't bind to the
 * data, so a structurally-valid-but-unbindable spec is the worst case: the user sees a
 * blank chart with nothing logged (cross-review P1). Catch the two field-binding failures
 * the prompt warns about but can't enforce:
 *   - bar/line: `xField` AND `yField` must each name a key present in EVERY data record,
 *     and the `yField` value must be NUMERIC in every record (a unit-suffixed string like
 *     "100点" makes the linear axis plot nothing).
 *   - pie: `valueField` (numeric) + `categoryField` (present) likewise.
 * Returns a reason string when the spec is NOT renderable (for logging), else null.
 * Lenient on shape it doesn't recognize (returns null = keep) so a future valid VChart
 * variant isn't dropped — only the two known blank-chart shapes are rejected.
 */
export function chartRejectReason(spec: ChartSpec): string | null {
  const values = (spec as { data?: { values?: unknown } }).data?.values;
  if (!Array.isArray(values) || values.length === 0) return "empty data.values";
  const records = values.filter((v): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v));
  if (records.length === 0) return "no object records in data.values";
  const type = String(spec.type).toLowerCase();
  const hasKey = (k: unknown): k is string => typeof k === "string" && k.length > 0;
  const everyHas = (key: string) => records.every((r) => key in r);
  const everyNumeric = (key: string) => records.every((r) => typeof r[key] === "number" && Number.isFinite(r[key] as number));

  if (type === "pie") {
    const vf = (spec as { valueField?: unknown }).valueField;
    const cf = (spec as { categoryField?: unknown }).categoryField;
    if (!hasKey(vf) || !hasKey(cf)) return "pie missing valueField/categoryField";
    if (!everyHas(vf)) return `valueField '${vf}' not in every record`;
    if (!everyHas(cf)) return `categoryField '${cf}' not in every record`;
    if (!everyNumeric(vf)) return `valueField '${vf}' is not numeric in every record`;
    return null;
  }
  // bar / line (rectangular)
  const xf = (spec as { xField?: unknown }).xField;
  const yf = (spec as { yField?: unknown }).yField;
  if (!hasKey(xf) || !hasKey(yf)) return "bar/line missing xField/yField";
  if (!everyHas(xf)) return `xField '${xf}' not in every record`;
  if (!everyHas(yf)) return `yField '${yf}' not in every record`;
  if (!everyNumeric(yf)) return `yField '${yf}' is not numeric in every record`;
  return null;
}

export interface DroppedChart { reason: string; type?: string }

export function extractCharts(answer: string): { text: string; charts: ChartSpec[]; dropped: DroppedChart[] } {
  const charts: ChartSpec[] = [];
  const dropped: DroppedChart[] = [];
  let text = answer.replace(CHART_BLOCK, (_full, body: string) => {
    const trimmed = body.trim();
    if (trimmed.length > MAX_CHART_SPEC_BYTES) { dropped.push({ reason: "oversized" }); return ""; }
    try {
      const spec = JSON.parse(trimmed) as ChartSpec;
      if (spec && typeof spec.type === "string" && ALLOWED_CHART_TYPES.has(spec.type.toLowerCase())) {
        // Structural validation: VChart renders a parseable-but-unbindable spec as a
        // BLANK chart with no error, so reject the known blank-chart shapes here (field
        // refs not matching data keys, non-numeric yField) and let the prose-table
        // fallback stand, rather than show the user an empty plot (cross-review P1).
        const reason = chartRejectReason(spec);
        if (reason) dropped.push({ reason, type: spec.type });
        else charts.push(spec);
      } else {
        dropped.push({ reason: "bad type", type: typeof spec?.type === "string" ? spec.type : undefined });
      }
    } catch { dropped.push({ reason: "invalid JSON" }); }
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
  return { text: text.replace(/\n{3,}/g, "\n\n").trim(), charts, dropped };
}
