/**
 * Extract a CLARIFICATION request from the agent's answer.
 *
 * When the user's question is genuinely ambiguous (multiple distinct things they
 * could mean, and guessing would risk a wrong answer), the system prompt tells the
 * agent to STOP and ask — emitting, instead of an answer:
 *
 *   🔀 需要你确认：<one short business-language sentence on what's ambiguous>
 *   - <clarified option A, phrased as a complete question>
 *   - <clarified option B, phrased as a complete question>
 *   - <option C…>            (2–4 options)
 *
 * The gateway parses these into clickable buttons; clicking one re-asks that
 * clarified question (reusing the follow-up invoke path, which replays context).
 * This keeps disambiguation a ONE-TAP action for the (non-technical) user rather
 * than a free-text back-and-forth.
 *
 * Keyed on the EXACT literal "🔀 需要你确认" / "需要你确认" — see
 * tests/prompt-marker-contract.test.ts (the agent's system.md must keep emitting it).
 */

/** Cap on clarification options (buttons). Mirrors MAX_FOLLOW_UPS' intent. */
export const MAX_CLARIFY_OPTIONS = 4;
const MIN_CLARIFY_OPTIONS = 2;

export interface Clarification {
  /** The short "what's ambiguous" prompt shown above the buttons. */
  question: string;
  /** The clarified-question options, each becomes a button. */
  options: string[];
}

const MARKER = "需要你确认";

/**
 * Parse a clarification request from the answer, or null if there isn't one.
 * Requires the marker AND at least MIN_CLARIFY_OPTIONS list items — a lone marker
 * with no parseable options is NOT treated as a clarification (the answer renders
 * normally), so a stray mention can't blank out a real answer. PURE.
 */
export function extractClarification(answer: string): Clarification | null {
  const markerIdx = answer.indexOf(MARKER);
  if (markerIdx === -1) return null;

  // The "what's ambiguous" line: from the marker to end-of-line, minus leading
  // emoji/colon decoration.
  const afterMarker = answer.slice(markerIdx + MARKER.length);
  const firstNl = afterMarker.indexOf("\n");
  const questionRaw = (firstNl === -1 ? afterMarker : afterMarker.slice(0, firstNl)).trim();
  const question = questionRaw.replace(/^[：:、,，\s]+/, "").trim();

  // Options: list items below the marker line.
  const rest = firstNl === -1 ? "" : afterMarker.slice(firstNl + 1);
  const options: string[] = [];
  for (const line of rest.split("\n")) {
    // A list item: optional leading bullet / number, then the clarified question.
    if (!/^[\s]*(?:[-·•*]|\d+[.)])\s+/.test(line)) {
      // Stop at the first non-list, non-blank line AFTER we already have options
      // (the options block has ended); keep skipping leading blanks.
      if (options.length > 0 && line.trim().length > 0) break;
      continue;
    }
    const text = line.replace(/^[\s]*(?:[-·•*]|\d+[.)])\s+/, "").trim();
    if (text.length >= 2 && text.length <= 120) options.push(text);
    if (options.length >= MAX_CLARIFY_OPTIONS) break;
  }

  if (options.length < MIN_CLARIFY_OPTIONS) return null;
  return { question: question || "这个问题有多种理解，请选择你想问的：", options };
}
