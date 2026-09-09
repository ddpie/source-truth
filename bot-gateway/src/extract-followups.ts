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

function unquote(line: string): string {
  return line.replace(/^[ \t　]*(?:>[ \t　]*)*/, "").trim();
}

// Normalize only Markdown decoration, then require the WHOLE marker line.
// Extraction sees raw quoted evidence while sanitizeAnswerText sees unquoted
// evidence; both must recognize the same trailer or questions disappear from
// the body without becoming buttons. Ordinary prose containing the phrase must
// remain untouched.
function isMarker(line: string): boolean {
  const plain = unquote(line).replace(/^#{1,6}[ \t　]+/, "").replace(/\*\*|__/g, "");
  return /^(?:💡[ \t　]*)?你可能还想问[ \t　]*[：:…。\\.]*[ \t　]*$/.test(plain);
}

function findMarker(lines: string[]): number {
  let fence: string | undefined;
  for (let i = 0; i < lines.length; i++) {
    const code = /^(`{3,}|~{3,})(.*)$/.exec(unquote(lines[i]));
    if (code) {
      if (!fence) fence = code[1];
      else if (code[1][0] === fence[0] && code[1].length >= fence.length && !code[2].trim()) fence = undefined;
      continue;
    }
    if (!fence && isMarker(lines[i])) return i;
  }
  return -1;
}

export function extractFollowUps(answer: string): string[] {
  const lines = answer.split("\n");
  const marker = findMarker(lines);
  return marker < 0 ? [] : _extractAfter(lines.slice(marker + 1));
}

/**
 * Strip the follow-up trailer from the answer body so the questions render ONLY
 * as footer buttons, not also as duplicated prose inside the card. Cuts from the
 * "💡 你可能还想问" marker (and any immediately-preceding `---` divider line,
 * which the system prompt uses exclusively for this separator) up to the next
 * section or end of string.
 * Returns the answer unchanged if there's no trailer.
 */
export function stripFollowUps(answer: string): string {
  const lines = answer.split("\n");
  const marker = findMarker(lines);
  if (marker < 0) return answer;
  let start = marker;
  while (start > 0 && !unquote(lines[start - 1])) start--;
  if (start > 0 && /^(?:-{3,}|\*{3,}|_{3,})$/.test(unquote(lines[start - 1]))) start--;
  let end = marker + 1;
  while (end < lines.length && !isSectionBoundary(lines[end])) end++;
  return [...lines.slice(0, start), ...lines.slice(end)].join("\n").trimEnd();
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
function isSectionBoundary(line: string): boolean {
  const plain = unquote(line).replace(/^#{1,6}[ \t　]+/, "").replace(/\*\*|__/g, "");
  return /^(?:(?:🔍|📎|🔀)[ \t　]*)?(?:供研发复核|需要你确认)|^(?:(?:🔍|📎)[ \t　]*)?依据[ \t　：:]*$|^(?:`{3,}|~{3,})/.test(plain);
}

function _extractAfter(lines: string[]): string[] {
  // Extract lines starting with "- " or "· " or numbered "1. " etc.
  const questions: string[] = [];
  for (const line of lines) {
    // STOP at the start of another section (evidence/clarify/chart/code fence): its
    // lines are NOT follow-ups. break (not continue) so nothing past the boundary is
    // collected even if a later line happens to look list-shaped.
    if (isSectionBoundary(line)) break;
    const trimmed = unquote(line).replace(/^[\s\-·•*\d.]+/, "").trim();
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
