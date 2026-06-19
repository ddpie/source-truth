/**
 * Normalize markdown BLOCK boundaries so Feishu's `lark_md` renders them.
 *
 * Failure mode (observed live via card read-back): the model sometimes emits a
 * block element — an ATX heading (`### 标题`) or a horizontal rule (`---`) —
 * WITHOUT a blank line (or any line break) before it, e.g.:
 *     具体来说：### 魅力属性——有影响
 *     …值得注意。---### 礼仪（Etiquette）…
 *     | 1 | 2 |## 三、外部加成        (a heading jammed onto a table's last row)
 * `lark_md` only treats `#`/`---` as a block when they START a line, so the reader
 * sees the literal `###` / `---` jammed mid-paragraph. The gateway preserves the
 * model's newlines verbatim, so this is repaired deterministically here.
 *
 * DESIGN — intentionally narrow (an earlier broad version corrupted common code-QA
 * content; a cross-review caught it):
 *   - NO blockquote (`>`) handling. In a CODE Q&A bot `>` is overwhelmingly a
 *     comparison (`血量 > 50%`), a shell redirect, or an arrow (`-->`,`->`,`=>`).
 *   - The HR split fires ONLY on a `---`/`***`/`___` run right after sentence/clause
 *     punctuation (。！？.!? ：:), and NEVER on a table line (its `|---|` separator is
 *     dashes) or inside a code fence.
 *   - The heading split requires the `#…` run to have a space after AND a
 *     non-alphanumeric, non-`#` char before (so `C#`, `#3`, `#tag` are safe). It runs
 *     even on a TABLE line (a heading is never a table cell), but never inside a fence.
 * It only ADDS separators; never merges or drops content. PURE.
 */

// NUL-delimited fence placeholder. NUL (U+0000) never appears in card answer text,
// so a placeholder can't be forged by — or collide with — prose that literally
// contains the word "FENCE" followed by digits (an identifier, a regex example, a
// echoed config line). Stash writes `\x00FENCE<n>\x00`; restore matches ONLY that
// exact shape.
const FENCE_OPEN = "\x00FENCE";
const FENCE_CLOSE = "\x00";
const FENCE_RESTORE_RE = /\x00FENCE(\d+)\x00/g;

const FENCE_RE = /```[\s\S]*?```/g;
// Trailing UNCLOSED fence (open ``` to end-of-string) — streaming partials and a
// model that forgets the closing fence both produce these; their content must be
// protected too, or in-code ###/--- get wrongly promoted.
const UNCLOSED_FENCE_RE = /```[\s\S]*$/;

/** True if a line is (part of) a markdown table — has a leading/contained pipe. */
function isTableLine(line: string): boolean {
  const t = line.trim();
  return t.startsWith("|") || /\|/.test(t);
}

/**
 * Ensure jammed block markers (`#`-headings, `---`/`***`/`___` rules) begin a line
 * with a blank line before them. Conservative — see file header. PURE.
 */
export function normalizeBlocks(text: string): string {
  if (!text) return text;

  // Protect fenced code blocks (paired first, then a trailing unclosed one): swap
  // them out, normalize, swap back. A fence can contain ###/--- that stay literal.
  // The placeholder MUST be a token that can't occur in real answer text, or it
  // collides with the prose: a code-QA answer that literally discusses `FENCE0`
  // (an identifier, a regex example, a回显ed config line) was being either
  // OVERWRITTEN with a code block's content or — when the referenced index was out
  // of range — silently DELETED (`?? ""`), dropping a token from the rendered
  // answer (cross-review CONFIRMED). Wrap the index in NUL bytes (U+0000): the
  // gateway never emits NUL in card text, so the sentinel is unforgeable by prose,
  // and the restore regex matches ONLY our own placeholders.
  const fences: string[] = [];
  const stash = (m: string): string => {
    fences.push(m);
    return `${FENCE_OPEN}${fences.length - 1}${FENCE_CLOSE}`;
  };
  let work = text.replace(FENCE_RE, stash).replace(UNCLOSED_FENCE_RE, stash);

  // Process line by line so a table row / pipe line is never touched by the HR rule,
  // and an HR / heading is only split out of genuine prose (or off a table row, for
  // a heading).
  const out: string[] = [];
  for (const line of work.split("\n")) {
    const isFence = line.includes(FENCE_OPEN);
    const isTable = isTableLine(line);
    let repaired = line;

    // 1) HR jammed AFTER a sentence end OR a colon. Require sentence/clause
    //    punctuation immediately before the rule (the real jam shape) so we never
    //    touch an arrow, a range, or a mid-word dash; run must be >=3 of the SAME
    //    char and not be followed by ">" (would be "-->") or another rule char.
    //    SKIP on a table line (its "|---|" separator is dashes) and inside a fence.
    if (!isTable && !isFence) {
      repaired = repaired.replace(
        /([。！？.!?：:])(-{3,}|\*{3,}|_{3,})(?![>*_-])/g,
        (_m, punct: string, rule: string) => `${punct}\n\n${rule}\n\n`,
      );
    }

    // 2) ATX heading jammed mid-line. Char before must be non-alphanumeric, non-"#"
    //    (excludes "C# ", "#3"); a space must follow the #'s. Runs even on a TABLE
    //    line — the model sometimes jams a heading onto a table's last row
    //    ("| 1 | 2 |## 三") and a heading is NEVER a table cell, so splitting is
    //    always correct. Skipped only inside a fenced code block.
    if (!isFence) {
      repaired = repaired.replace(
        /([^\n0-9A-Za-z#])(#{1,6}[ \t]+)/g,
        (_m, before: string, head: string) => `${before}\n\n${head}`,
      );
    }

    out.push(repaired);
  }
  work = out.join("\n");

  // Restore fences. The placeholder is the NUL-delimited sentinel (\x00FENCE<n>\x00) —
  // match ONLY that exact shape, and on an out-of-range index keep the matched text
  // verbatim (`?? m`) instead of deleting it. (The old ` FENCEn `/`?? ""` form collided
  // with prose containing a literal "FENCE<n>" and silently dropped it — cross-review.)
  work = work.replace(FENCE_RESTORE_RE, (m, i: string) => fences[Number(i)] ?? m);

  // Tidy: trailing spaces before newline, and collapse >2 newlines the inserts made.
  work = work.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n");

  return work;
}
