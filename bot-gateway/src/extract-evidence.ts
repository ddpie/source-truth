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
// A HEADING-STYLE trailing suffix after the token is tolerated — a parenthetical
// like "供研发复核（仅研发看）" or a "供研发复核 - 以下为出处" dash-note — so a decorated
// heading is still recognized and the evidence is folded into the panel instead of
// LEAKING the raw `> file:line` block into the user-facing conclusion. The suffix
// is restricted to (parenthetical | dash-led note) so a normal prose sentence
// containing 依据 mid-line ("我判断的依据是 X 因为 Y") still does NOT match.
const EVIDENCE_MARKER = /(?:^|\n)[ \t>#*_]*(?:🔍\s*)?(?:📎\s*)?\*{0,2}\s*(?:供研发复核|依据)\s*\*{0,2}[：:]?(?:[ \t]*[（(][^\n]*[)）]|[ \t]*[-–—][^\n]*)?[ \t]*(?=\n|$)/;

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
