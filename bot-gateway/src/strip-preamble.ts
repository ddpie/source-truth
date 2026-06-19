/**
 * Strip a planning/transition PREAMBLE that leaked into the conclusion body.
 *
 * The agent's narration before the conclusion is supposed to land in the 分析过程
 * panel (gateway splits text blocks: all-but-last = narration, last = conclusion).
 * But some models write a transition sentence ("现在我整理答案…" / "Now let me
 * compile the answer…") in the SAME text block as the real answer, often followed
 * by a literal `---` separator, then the answer. That whole thing is the last
 * block, so the structural split can't catch it and the planning sentence shows as
 * the conclusion's first line — violating 结论先行 (the first line must BE the answer).
 *
 * This is a conservative, marker-keyed strip: it only fires when the text BEFORE
 * the first `---` looks like a short planning/transition preamble (a known opener
 * phrase, and short enough to not be a real answer). It never touches a body that
 * doesn't start with such a preamble, and never strips past the first `---`.
 */

// Planning/transition openers the model uses to introduce the answer. Matched
// case-insensitively at the START of the (trimmed) body. Kept specific so a real
// answer that merely happens to contain these words mid-sentence is untouched.
const PREAMBLE_OPENERS: RegExp[] = [
  // Chinese transitions
  /^现在(我)?(已经)?/, // 现在我已经掌握… / 现在整理…
  /^(好的?[，,。.\s]*)?(我)?(现在)?(来|开始)?(整理|汇总|总结)(一下)?(答案|结论|回答)/,
  /^(我)?(已经)?(掌握|拿到|收集到|获取到)(了)?(足够|所有|相关)(的)?(信息|证据|内容|数据)/,
  /^(基于|根据)(以上|上述)(的)?(取证|查找|搜索|信息)/,
  /^让我(来)?(整理|汇总|总结)/,
  /^答案(已经)?(很)?(清楚|明确|明朗)(了)?/,
  // "readiness to answer" meta-statements (the analysis is done, here's the answer)
  /^所有?.{0,30}(逻辑|信息|内容|证据|数据|细节|出处|配置)[都也]?.{0,8}(读|查|弄|搞|看|确认)(清楚|清|完|明白|到了?)/,
  /^可以(给出|开始|提供|整理)/, // 可以给出完整答案了
  /^.{0,24}(信息|证据|数据|内容)(都|已)?.{0,6}(齐|足够|够了|拿到|到位|都有了?)/,
  /^.{0,24}都(已|已经)?.{0,8}(读|查|弄|搞|确认)(清楚|清|完|到了?)/,
  // English transitions
  /^now\s+(let me|i'?ll|i\s+have|that)/i,
  /^(i\s+)?(now\s+)?have\s+(enough|all\s+the)\s+(info|information|evidence)/i,
  /^(let me|i'?ll)\s+(now\s+)?(compile|summarize|put together|organize)/i,
  /^based on (the above|my)/i,
  /^(all|the)\s+(key\s+)?(logic|info|information|evidence|details?)\s+(is|are|has been|have been)\s+(read|gathered|confirmed|clear)/i,
];

// A preamble is a SHORT lead-in, not a paragraph of real answer. If the segment
// before the first `---` is longer than this, we assume it's actually the answer
// (which legitimately can contain a `---`), and we don't strip.
const MAX_PREAMBLE_LEN = 160;

/**
 * If `body` opens with a planning/transition preamble followed by a `---`
 * separator, return the body with that preamble + separator removed. Otherwise
 * return `body` unchanged. PURE.
 */
export function stripPreamble(body: string): string {
  if (!body) return body;
  // Find the first `---` separator the model uses to divide its transition note
  // from the real answer. Match BOTH a proper HR line (`\n---\n`) AND an inline
  // `---` with no surrounding newlines (observed: "…答案了。---这个项目…") — the
  // model sometimes emits the separator without line breaks. Over-stripping is
  // guarded downstream: we only act when the head is a SHORT recognized preamble.
  const hrMatch = body.match(/(^|\n)\s*-{3,}\s*(\n|$)/) ?? body.match(/-{3,}/);
  if (!hrMatch || hrMatch.index === undefined) return body;
  const splitAt = hrMatch.index + hrMatch[0].length;
  const head = body.slice(0, hrMatch.index).trim();
  // Only strip when the head is SHORT and looks like a planning preamble.
  if (head.length === 0 || head.length > MAX_PREAMBLE_LEN) return body;
  const opensWithPreamble = PREAMBLE_OPENERS.some((re) => re.test(head));
  if (!opensWithPreamble) return body;
  const tail = body.slice(splitAt).trim();
  // Don't strip into emptiness — if there's no real answer after the separator,
  // keep the original (better a slightly noisy answer than an empty card).
  return tail.length > 0 ? tail : body;
}
