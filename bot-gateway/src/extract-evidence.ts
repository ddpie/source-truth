/**
 * Split the agent's answer into { body, evidence } at the "依据" marker.
 *
 * The system prompt tells the agent to put the business answer first, then a
 * "供研发复核" evidence section (file paths / symbols / line numbers) under a
 * `📎 依据` heading or `> 依据` quote block. We pull that section OUT of the
 * prose so the gateway can render it as a COLLAPSIBLE panel (folded by default)
 * instead of leaving it as a non-collapsing quote — keeping the card clean for
 * the non-technical reader while a dev can expand it to verify.
 *
 * Best-effort: if there's no recognizable evidence marker, evidence is "" and
 * body is the input unchanged (never throws, never drops content).
 */

export interface SplitEvidence {
  body: string;       // the business answer (marker + evidence removed)
  evidence: string;   // the evidence section content (marker line removed), or ""
}

// Matches the start of the evidence section. The system prompt (system.md:65,
// examples at 121/140/161) emits its FIRST line literally as:
//   > 🔍 **供研发复核**
// so the load-bearing token is "供研发复核" (optionally wrapped in > / 🔍 / ** /
// 📎 / # decorations). "依据" is kept ONLY as a lenient fallback heading form
// ("📎 依据" / "> 依据"), never mid-sentence. Anchored to a line start + a
// line-end lookahead so prose mentions ("判断的依据：…", "代码为唯一依据") never match.
//
// Two heading forms, deliberately asymmetric to avoid the "依据 is a common word"
// false-positive trap:
//   A) the load-bearing literal 供研发复核 — the prompt's mandated heading. A
//      DECORATED form ("供研发复核（仅研发看）" / "供研发复核 - 以下为出处") is tolerated so a
//      slightly-decorated heading still folds into the panel instead of leaking the
//      raw `> file:line` block into the conclusion. 供研发复核 is a distinctive
//      4-char term that essentially never starts a prose line, so the bounded
//      suffix is safe here.
//   B) the lenient 依据 fallback — heading-ONLY, NO suffix allowed. 依据 ("根据/依据…")
//      is an extremely common Chinese word, so "依据 - 玩家等级…" / "依据（见上文）" are
//      ordinary prose lines, NOT headings; allowing a dash/paren suffix after 依据
//      would fold the genuine conclusion lines below them into the collapsed panel
//      (a reverse leak). So 依据 matches only as a bare "📎 依据" / "> 依据[：]" line.
// Both are line-anchored (start-of-line decorations + line-end lookahead).
const NOTE = "[^\\n，。；！？、]{0,24}"; // short, punctuation-free heading note
const DECO = "[ \\t>#*_]*(?:🔍\\s*)?(?:📎\\s*)?\\*{0,2}\\s*";
const EVIDENCE_MARKER = new RegExp(
  "(?:^|\\n)(?:" +
    // A) 供研发复核 with an optional decorated note
    DECO + "供研发复核\\s*\\*{0,2}[：:]?(?:[ \\t]*[（(]" + NOTE + "[)）]|[ \\t]*[-–—][ \\t]*" + NOTE + ")?" +
    "|" +
    // B) 依据 bare heading only (no suffix)
    DECO + "依据\\s*\\*{0,2}[：:]?" +
  ")[ \\t]*(?=\\n|$)",
);

export function splitEvidence(answer: string): SplitEvidence {
  const m = EVIDENCE_MARKER.exec(answer);
  if (!m) return { body: answer, evidence: "" };
  // Body = everything before the marker; also trim a trailing "---" divider the
  // prompt puts between conclusion and evidence so the body doesn't dangle a rule.
  const markerStart = m.index + (m[0].startsWith("\n") ? 1 : 0);
  let body = answer.slice(0, markerStart);
  body = body.replace(/\n\s*(?:-{3,}|\*{3,}|_{3,})\s*$/, "").trimEnd();
  // Evidence = everything AFTER the marker line, with leading quote markers per
  // line stripped (it becomes a panel, the "> " quote styling is no longer wanted).
  const afterMarker = answer.slice(m.index + m[0].length);
  const evidence = afterMarker
    .split("\n")
    .map((line) => line.replace(/^[ \t]*>[ \t]?/, "")) // drop a single leading quote marker
    .join("\n")
    .trim();
  return { body: body || answer, evidence };
}
