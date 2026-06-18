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

export function extractFollowUps(answer: string): string[] {
  // Find the section after "你可能还想问" (tolerant of formatting variations).
  const marker = answer.indexOf("你可能还想问");
  if (marker === -1) return [];

  return _extractAfter(answer.slice(marker));
}

/**
 * Strip the follow-up trailer from the answer body so the questions render ONLY
 * as footer buttons, not also as duplicated prose inside the card. Cuts from the
 * "💡 你可能还想问" marker (and any immediately-preceding `---` divider line,
 * which the system prompt uses exclusively for this separator) to end of string.
 * Returns the answer unchanged if there's no trailer.
 */
export function stripFollowUps(answer: string): string {
  const marker = answer.indexOf("你可能还想问");
  if (marker === -1) return answer;
  // Back up over an optional "💡" and a preceding "---" divider line so the body
  // doesn't end with a dangling rule. Match from the start of the line/divider.
  const head = answer.slice(0, marker);
  // Drop a trailing "💡 " on the marker line, then any whitespace, then an
  // optional horizontal-rule line (--- / *** / ___), then trailing whitespace.
  const cleaned = head.replace(/\s*💡?\s*$/, "").replace(/\n\s*(?:-{3,}|\*{3,}|_{3,})\s*$/, "");
  return cleaned.trimEnd();
}

function _extractAfter(afterMarker: string): string[] {
  // Extract lines starting with "- " or "· " or numbered "1. " etc.
  const lines = afterMarker.split("\n");
  const questions: string[] = [];
  for (const line of lines) {
    const trimmed = line.replace(/^[\s\-·•*\d.]+/, "").trim();
    if (trimmed.length >= 4 && trimmed.length <= 80 && !trimmed.startsWith("💡") && !trimmed.includes("你可能还想问") && !trimmed.includes("继续追问")) {
      questions.push(trimmed);
    }
    if (questions.length >= 3) break;
  }
  return questions;
}
