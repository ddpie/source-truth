/**
 * Detect & strip LEAKED tool-call markup from an answer.
 *
 * Failure mode (observed live): when the agent's MCP tools are unreachable (e.g. a
 * warm microVM pointed at a since-replaced index instance), the model can't actually
 * INVOKE its tools, so it falls back to emitting the tool-call SYNTAX as plain text
 * — blocks like:
 *     <function_calls>
 *     <invoke name="codegraph_search_files">
 *     <parameter name="pattern">hp|health</parameter>
 *     </invoke>
 *     </function_calls>
 * The SDK hands that to the gateway as ordinary "text", so it lands in the conclusion
 * and the user sees raw XML markup in their card. That is never a valid answer — a
 * conclusion full of <invoke>/<function_calls> means retrieval did NOT happen.
 *
 * `stripToolCallLeak` removes those blocks. `isToolCallLeakDominant` reports when the
 * answer is MOSTLY such markup (so the caller can show a clean "retrieval failed,
 * retry" message instead of the stripped scraps). PURE.
 */

// Matches a whole <function_calls>…</function_calls> block, a bare
// <invoke …>…</invoke> block, or a stray <parameter …>…</parameter> / orphan tag.
// Tolerant of the markdown bolding Feishu sometimes wraps around them (**</invoke>**).
const TOOLCALL_BLOCK = /\**<\/?(?:function_calls|antml:function_calls)\b[^>]*>\**/gi;
const INVOKE_BLOCK = /\**<invoke\b[\s\S]*?<\/invoke>\**/gi;
const PARAM_BLOCK = /\**<\/?parameter\b[^>]*>\**/gi;
const ORPHAN_INVOKE_OPEN = /\**<invoke\b[^>]*>\**/gi; // an unclosed <invoke …> (truncated stream)

/** Remove leaked tool-call markup from `text`. Returns the cleaned text (trimmed). */
export function stripToolCallLeak(text: string): string {
  if (!text || (!text.includes("<invoke") && !text.includes("function_calls"))) return text;
  let out = text
    .replace(INVOKE_BLOCK, "")        // whole <invoke>…</invoke>
    .replace(ORPHAN_INVOKE_OPEN, "")  // …then any unclosed <invoke …>
    .replace(PARAM_BLOCK, "")         // stray <parameter> tags
    .replace(TOOLCALL_BLOCK, "");     // <function_calls> wrappers
  // Collapse the blank lines / dangling whitespace the removals leave behind.
  out = out.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  return out;
}

/**
 * True when the answer is DOMINATED by leaked tool-call markup — i.e. once the markup
 * is stripped, little real prose remains. The caller uses this to replace the answer
 * with a clean failure message rather than showing the scraps. Threshold-based:
 * fires when >=2 invoke/function_calls markers AND the stripped remainder is short.
 */
export function isToolCallLeakDominant(text: string): boolean {
  if (!text) return false;
  const markers = (text.match(/<invoke\b/gi) || []).length + (text.match(/function_calls/gi) || []).length;
  if (markers < 2) return false;
  const stripped = stripToolCallLeak(text);
  // If almost nothing survives the strip, the "answer" was essentially all markup.
  return stripped.length < 80;
}
