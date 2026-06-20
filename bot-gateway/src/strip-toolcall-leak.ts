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

// CRITICAL: Anthropic/Claude models serialize tool calls with an `antml:` namespace
// prefix on EVERY tag (<invoke>, <parameter>, <function_calls>) — that
// is the dominant real leak shape. Every pattern therefore tolerates an OPTIONAL
// `(?:antml:)?` prefix; matching only the bare form let the real shape pass through
// entirely unstripped. Also tolerant of the markdown bolding Feishu sometimes wraps
// around them (**</invoke>**).
// ReDoS NOTE: the closed-block matcher bounds the gap with `[\s\S]{0,8000}?` (not the
// unbounded `[\s\S]*?`) so N unclosed `<invoke` opens can't each scan to end-of-string
// (O(n^2) event-loop stall). A genuinely-unclosed open is then mopped up by the orphan
// pattern; 8000 chars comfortably covers a real tool-call block.
// SECOND ReDoS axis (cross-review CONFIRMED): the LEADING bold marker was `\**` — an
// UNBOUNDED `*` run. On input with a long `*` streak NOT followed by a matchable tag,
// the engine retried `\**` from every offset → O(n^2) (~10s on 32k `*`, a single-event-
// loop DoS, and the leak shape itself involves bolded markup so it's reachable). The
// marker only ever needs to absorb markdown bolding (`**…**`), so bound it to `\*{0,4}`.
const BOLD = "\\*{0,4}"; // leading/trailing markdown bold marker, BOUNDED (was \** → ReDoS)
const TOOLCALL_BLOCK = new RegExp(`${BOLD}<\\/?(?:antml:)?function_calls\\b[^>]*>${BOLD}`, "gi");
const INVOKE_BLOCK = new RegExp(`${BOLD}<(?:antml:)?invoke\\b[\\s\\S]{0,8000}?<\\/(?:antml:)?invoke>${BOLD}`, "gi");
const PARAM_BLOCK = new RegExp(`${BOLD}<\\/?(?:antml:)?parameter\\b[^>]*>${BOLD}`, "gi");
const ORPHAN_INVOKE_OPEN = new RegExp(`${BOLD}<(?:antml:)?invoke\\b[^>\\n]{0,400}>${BOLD}`, "gi"); // unclosed <invoke …>
// HAIKU-style leak: the model serializes a tool call as <attempt_{toolname}>{JSON}
// </attempt_{toolname}> (observed live on claude-haiku-4-5; a DIFFERENT shape from
// Opus/Sonnet's <invoke>). Match the paired block (bounded gap) then any orphan
// open. The tag name is always `attempt_` + word chars (the tool name).
const ATTEMPT_BLOCK = new RegExp(`${BOLD}<(attempt_[a-zA-Z0-9_]+)\\b[\\s\\S]{0,8000}?<\\/\\1>${BOLD}`, "gi");
const ORPHAN_ATTEMPT_OPEN = new RegExp(`${BOLD}<\\/?attempt_[a-zA-Z0-9_]+\\b[^>\\n]{0,400}>${BOLD}`, "gi");

// A leaked internal tool name paired with a "calling" cue, or a "Tool call:" label, or
// the raw mcp__ name — the markup-LESS leak shape (model narrates the call in mixed
// JA/EN + a ```json args block instead of emitting XML). A real answer never exposes an
// internal tool name, so these are always a leak (live: card st-96f2a7f42c25, which the
// XML-only matcher missed → rendered raw). Used by both hasToolCallMarkup + the count.
const BARE_TOOLCALL_RE = /\bcodegraph_[a-z_]+\s*(?:\(|を|呼|call|调用|調用)|(?:call|调用|調用|呼[びぶ])\s*(?:mcp__)?codegraph_[a-z_]+|mcp__codegraph__[a-z_]+\b|^\s*\**tool[ _]call\b/im;

/** True if `text` contains any (prefixed or bare) tool-call markup. */
function hasToolCallMarkup(text: string): boolean {
  return /<(?:antml:)?invoke\b/i.test(text)
    || /(?:antml:)?function_calls/i.test(text)
    || /<attempt_[a-zA-Z0-9_]+\b/i.test(text)
    || BARE_TOOLCALL_RE.test(text);
}

/** Remove leaked tool-call markup from `text`. Returns the cleaned text (trimmed). */
export function stripToolCallLeak(text: string): string {
  if (!text || !hasToolCallMarkup(text)) return text;
  let out = text
    .replace(INVOKE_BLOCK, "")        // whole <invoke>…</invoke> (bounded gap)
    .replace(ORPHAN_INVOKE_OPEN, "")  // …then any unclosed <invoke …>
    .replace(PARAM_BLOCK, "")         // stray <parameter> tags
    .replace(TOOLCALL_BLOCK, "")      // <function_calls> wrappers
    .replace(ATTEMPT_BLOCK, "")       // haiku <attempt_tool>…</attempt_tool> (bounded gap)
    .replace(ORPHAN_ATTEMPT_OPEN, "") // …then any unclosed/closing <attempt_tool …>
    // markup-LESS narration leak: a "**Tool call: codegraph_x**" label line (+ an
    // optional following ```json args block), and a bare "codegraph_x を呼びます /
    // 调用 codegraph_x" narration line. Line-anchored so prose merely mentioning a
    // tool name isn't nuked.
    .replace(/^[ \t]*\**tool[ _]call\b.*$/gim, "")
    .replace(/^[ \t]*\**(?:mcp__)?codegraph_[a-z_]+\**\s*(?:を|呼|呼びます|call|调用|調用)[^\n]*$/gim, "")
    .replace(/```json\s[\s\S]{0,800}?```/gi, ""); // a stray args json block left by the narration
  // Collapse the blank lines / dangling whitespace the removals leave behind.
  out = out.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  return out;
}

/**
 * True when the answer is DOMINATED by leaked tool-call markup — i.e. once the markup
 * is stripped, little real prose survives. The caller replaces such a body with a
 * clean failure message rather than showing the scraps. RATIO-based (not an absolute
 * floor): fires when >=2 markup markers AND the stripped remainder is either tiny
 * (<80 chars) OR less than 35% of the original — so a leak padded with filler prose
 * still triggers. Marker count is antml-tolerant (a wrapper-less antml leak must count).
 */
export function isToolCallLeakDominant(text: string): boolean {
  if (!text) return false;
  const markers = (text.match(/<(?:antml:)?invoke\b/gi) || []).length
    + (text.match(/(?:antml:)?function_calls/gi) || []).length
    + (text.match(/<attempt_[a-zA-Z0-9_]+\b/gi) || []).length
    + (text.match(/\bcodegraph_[a-z_]+\s*(?:\(|を|呼|call|调用|調用)|(?:call|调用|調用|呼[びぶ])\s*(?:mcp__)?codegraph_[a-z_]+|mcp__codegraph__[a-z_]+\b/gi) || []).length
    + (text.match(/^\s*\**tool[ _]call\b/gim) || []).length;
  if (markers < 2) return false;
  const stripped = stripToolCallLeak(text);
  return stripped.length < 80 || stripped.length < 0.35 * text.length;
}
