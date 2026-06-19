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

// The marker must LEAD A LINE (optionally after a 🔀 and whitespace) — the system
// prompt emits it as the first line of a clarify block, emitted INSTEAD of an
// answer. A bare indexOf would match "需要你确认" in ordinary prose (e.g. "这个值
// 需研发确认"), and since nearly every answer ends with a "💡 你可能还想问" bullet
// list, that would hijack a real answer into a broken clarify card. Anchoring to
// line-start + requiring the options to IMMEDIATELY follow closes that hole.
const MARKER_RE = /(?:^|\n)[ \t]*(?:🔀[ \t]*)?需要你确认[：:、,，]?[ \t]*([^\n]*)/;
const LIST_ITEM_RE = /^[ \t]*(?:[-·•*]|\d+[.)])\s+/;

/**
 * Parse a clarification request from the answer, or null if there isn't one.
 * Requires: (1) the marker LEADS A LINE; (2) the option list items IMMEDIATELY
 * follow the marker line (only blank lines may intervene) — the first non-blank
 * line after the marker MUST be a list item, else this isn't a clarify block;
 * (3) at least MIN_CLARIFY_OPTIONS items. These guards mean a stray prose mention
 * of "需要你确认" plus an unrelated later bullet list (follow-ups, value rows)
 * can NOT blank out a real answer. PURE.
 */
export function extractClarification(answer: string): Clarification | null {
  const m = MARKER_RE.exec(answer);
  if (!m || m.index === undefined) return null;

  // The "what's ambiguous" text is whatever followed the marker on its line.
  const question = (m[1] ?? "").replace(/^[：:、,，\s]+/, "").trim();

  // Everything after the marker LINE. The marker match consumes up to end-of-line
  // (it stops at \n), so slice from the end of the match.
  const rest = answer.slice(m.index + m[0].length);
  const lines = rest.split("\n");
  const options: string[] = [];
  let started = false;
  for (const line of lines) {
    if (LIST_ITEM_RE.test(line)) {
      started = true;
      const text = line.replace(LIST_ITEM_RE, "").trim();
      if (text.length >= 2 && text.length <= 120) options.push(text);
      if (options.length >= MAX_CLARIFY_OPTIONS) break;
      continue;
    }
    // Non-list line: tolerate ONLY leading blank lines before the list starts.
    // The first NON-BLANK non-list line ends the block — whether before the list
    // (then it's not a clarify block: options must immediately follow) or after.
    if (line.trim().length === 0) continue;
    break;
  }

  if (!started || options.length < MIN_CLARIFY_OPTIONS) return null;
  return { question: question || "这个问题有多种理解，请选择你想问的：", options };
}
