/**
 * Extract follow-up question suggestions from the Agent's answer text.
 *
 * The system prompt instructs the Agent to end answers with:
 *   ---
 *   💡 你可能还想问：
 *   - question 1
 *   - question 2
 *
 * We parse these out and return them as strings for the card buttons.
 */

/** Single source of truth for the follow-up suggestion cap. Used BOTH here (stop
 *  collecting) and by the card renderer (slice), so the extractor and renderer
 *  can't drift to different caps. */
export const MAX_FOLLOW_UPS = 3;

// The marker must LEAD A LINE (optionally after a "💡" and whitespace, and an
// optional preceding "---/***/___" divider line). A bare indexOf("你可能还想问")
// matches the phrase in ORDINARY prose — e.g. an answer that says "这些数值你可能
// 还想问的我都列了：" followed by data bullets — which would (1) truncate the real
// answer at the marker mid-stream and (2) turn the data rows into fake follow-up
// buttons. Anchoring to line-start closes that hole, mirroring extract-clarify.ts.
// `MARKER_RE` finds the marker line; `STRIP_RE` (anchored to end-of-string) backs
// up over the marker line + an optional preceding divider for stripping.
// Leading-whitespace class includes U+3000 (full-width space): a model formatting
// a CJK list often indents with 　 rather than ASCII space, and without it the
// marker wouldn't match → buttons silently lost AND the raw trailer leaks into the
// body. \t and ASCII space cover the rest.
// The marker must be (essentially) the WHOLE line — the phrase, an optional
// trailing "："/"…"/whitespace, then line-end. Line-START anchoring alone is NOT
// enough: a real answer line that merely BEGINS with the phrase ("你可能还想问的
// 逻辑在 Config.cs:10 定义") would otherwise truncate the answer + turn real prose
// into fake buttons (cross-review HIGH). The line-END lookahead closes that —
// mirroring extract-evidence.ts. A heading line "💡 你可能还想问：" still matches.
const MARKER_TAIL = "[ \\t　]*[：:…。\\.]*[ \\t　]*(?=\\n|$)";
const MARKER_RE = new RegExp(`(?:^|\\n)[ \\t　]*(?:💡[ \\t　]*)?你可能还想问${MARKER_TAIL}`);
const STRIP_RE = new RegExp(`(?:\\n[ \\t　]*(?:-{3,}|\\*{3,}|_{3,})[ \\t　]*)?\\n?[ \\t　]*(?:💡[ \\t　]*)?你可能还想问${MARKER_TAIL}[\\s\\S]*$`);

export function extractFollowUps(answer: string): string[] {
  // Find the marker only when it LEADS A LINE (not in mid-prose).
  const m = MARKER_RE.exec(answer);
  if (!m || m.index === undefined) return [];
  // Slice from the marker so _extractAfter scans the trailer's list lines.
  return _extractAfter(answer.slice(m.index + m[0].length));
}

/**
 * Strip the follow-up trailer from the answer body so the questions render ONLY
 * as footer buttons, not also as duplicated prose inside the card. Cuts from the
 * "💡 你可能还想问" marker (and any immediately-preceding `---` divider line,
 * which the system prompt uses exclusively for this separator) to end of string.
 * Returns the answer unchanged if there's no trailer.
 */
export function stripFollowUps(answer: string): string {
  // Only strip when the marker LEADS A LINE (same guard as extractFollowUps), so a
  // mid-prose mention of "你可能还想问" never truncates a real answer. STRIP_RE
  // anchors to end-of-string and eats the optional preceding divider + the marker
  // line + everything after, leaving the body clean (no dangling rule).
  if (!MARKER_RE.test(answer)) return answer;
  return answer.replace(STRIP_RE, "").trimEnd();
}

// A line that opens a DIFFERENT section — if the follow-up list is followed by (or,
// on a model misorder, precedes content that includes) an evidence block / chart /
// code fence, collection must STOP at that boundary, NOT swallow its lines as fake
// buttons. _extractAfter scans the raw post-marker tail (which can run to the very end
// of the answer), so without this an evidence heading `> 🔍 **供研发复核**`, a
// ```chart fence, or its JSON line each became a clickable "follow-up" that re-asks
// garbage on click (cross-review HIGH). Line-anchored, marker-tolerant of bold/quote.
// 供研发复核/需要你确认 只按「标题行」匹配（行首 + 可选 >/🔍/** 装饰），不做无锚定子串：
// 一条 follow-up 建议本身提及这个词（"- 供研发复核的证据在哪里？"）不该被当成边界，
// 否则它和后面所有合法按钮一起丢失。列表项的 "- " 前缀不满足标题锚定，故不受影响。
const SECTION_BOUNDARY_RE = /^[ \t　]*(?:>[ \t]*)?(?:🔍[ \t]*)?\*{0,2}(?:供研发复核|需要你确认)|^[ \t　]*(?:>?[ \t]*\**)?```/;

function _extractAfter(afterMarker: string): string[] {
  // Extract lines starting with "- " or "· " or numbered "1. " etc.
  const lines = afterMarker.split("\n");
  const questions: string[] = [];
  for (const line of lines) {
    // STOP at the start of another section (evidence/clarify/chart/code fence): its
    // lines are NOT follow-ups. break (not continue) so nothing past the boundary is
    // collected even if a later line happens to look list-shaped.
    if (SECTION_BOUNDARY_RE.test(line)) break;
    const trimmed = line.replace(/^[\s\-·•*\d.]+/, "").trim();
    // Dedup: a model that repeats a suggestion would otherwise render twin buttons
    // with identical captions but distinct element_ids — clicking one disables only
    // it, leaving the duplicate live (confusing UX; cross-review MED).
    if (trimmed.length >= 4 && trimmed.length <= 80 && !trimmed.startsWith("💡")
        && !trimmed.includes("你可能还想问") && !trimmed.includes("继续追问")
        && !questions.includes(trimmed)) {
      questions.push(trimmed);
    }
    if (questions.length >= MAX_FOLLOW_UPS) break;
  }
  return questions;
}
