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
  // "X 已核实/取到，(直接)给出结论" — readiness statement that ends by announcing
  // the answer (observed: "数值已从代码逐一核实，直接给出对比结论。").
  /^.{0,40}(已|都).{0,8}(核实|确认|取到|读到|查到|拿到|读完|查完).{0,30}(给出|得出|整理|呈现|说明).{0,12}(答案|结论|对比|说明)/,
  /^.{0,30}(直接|下面|以下就?)给出/,
  // English transitions
  /^now\s+(let me|i'?ll|i\s+have|that)/i,
  /^(i\s+)?(now\s+)?have\s+(enough|all\s+the)\s+(info|information|evidence)/i,
  /^(let me|i'?ll)\s+(now\s+)?(compile|summarize|put together|organize)/i,
  /^based on (the above|my)/i,
  /^(all|the)\s+(key\s+)?(logic|info|information|evidence|details?)\s+(is|are|has been|have been)\s+(read|gathered|confirmed|clear)/i,
];

// STRICTER subset for strategy 2 (NO separator). Without a `---` signal, an opener
// must be UNAMBIGUOUSLY about the answer/analysis process — never a phrase that
// could begin a real answer. E.g. the loose `^现在` (matches "现在的暴击倍率…", a real
// answer) is EXCLUDED here; only meta-statements like "现在整理答案" / "数值已核实，给出
// 结论" / "可以给出答案了" qualify. A standalone leading sentence is stripped only if it
// matches one of these AND the whole sentence is the preamble (ends at 。/！/newline).
// Each entry must be able to match the WHOLE first-sentence body (terminator
// already stripped by the caller), so they end with a tolerant tail
// `[了啦呢吧，,：: ]{0,4}` that mops up trailing particles/punctuation. The caller
// requires mm.index===0 AND mm[0].length===sentenceBody.length (a FULL match), so
// these never strip a sentence that merely BEGINS with the phrase and continues
// with real content (e.g. "整理答案的逻辑在 Foo.java").
const TAIL = "[了啦呢吧，,：:。\\s]{0,4}";
const STANDALONE_PREAMBLE_OPENERS: RegExp[] = [
  new RegExp(`^(好的?[，,。.\\s]*)?(我)?(现在)?(来|开始)?(整理|汇总|总结)(一下)?(答案|结论|回答)${TAIL}$`),
  new RegExp(`^让我(来)?(整理|汇总|总结)(一下)?(答案|结论|回答)?${TAIL}$`),
  new RegExp(`^可以(给出|开始|提供|整理)(完整|最终|对比)?(的)?(答案|结论)${TAIL}$`),
  new RegExp(`^.{0,40}(已|都).{0,8}(核实|确认|取到|读到|查到|拿到|读完|查完|读清楚|查清楚|弄清楚)[，,]?.{0,30}(给出|得出|整理|呈现|说明).{0,12}(答案|结论|对比|说明)${TAIL}$`),
  new RegExp(`^.{0,30}(直接|下面|以下就?)给出(完整|最终|对比)?(的)?(答案|结论)${TAIL}$`),
  /^(let me|i'?ll)\s+(now\s+)?(compile|summarize|put together|organize)\s+(the\s+)?(answer|findings?|results?)\s*[.:]?$/i,
  /^(all|the)\s+(key\s+)?(logic|info|information|evidence|details?|values?)\s+(is|are|has been|have been)\s+(read|gathered|confirmed|verified|clear)\s*[.:]?$/i,
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
  const looksLikePreamble = (head: string): boolean =>
    head.length > 0 && head.length <= MAX_PREAMBLE_LEN && PREAMBLE_OPENERS.some((re) => re.test(head));

  // Strategy 1 — preamble + `---` SEPARATOR. The model writes its transition note,
  // a `---`, then the real answer. Match BOTH a proper HR line (`\n---\n`) AND an
  // inline `---` (observed: "…答案了。---这个项目…").
  const hrMatch = body.match(/(^|\n)\s*-{3,}\s*(\n|$)/) ?? body.match(/-{3,}/);
  if (hrMatch && hrMatch.index !== undefined) {
    const head = body.slice(0, hrMatch.index).trim();
    if (looksLikePreamble(head)) {
      const tail = body.slice(hrMatch.index + hrMatch[0].length).trim();
      if (tail.length > 0) return tail;
    }
  }

  // Strategy 2 — preamble as a standalone LEADING SENTENCE, no separator (observed:
  // "数值已从代码逐一核实，直接给出对比结论。\n**匕首**的基础伤害…"). Only fire when the
  // FIRST sentence (up to the first 。/！/.\n) is ENTIRELY a recognized preamble and
  // real content follows. CRITICAL: the opener must match the WHOLE sentence body
  // (terminator stripped), not just a PREFIX — otherwise a real answer whose first
  // sentence merely BEGINS with a meta-phrase ("整理答案的逻辑在 Foo.java。") would be
  // wrongly discarded. We strip the trailing 。/！/! and test a $-anchored full match.
  const sentMatch = body.match(/^\s*([^\n。！.!]{1,}[。！!]|[^\n]{1,}\n)/);
  if (sentMatch) {
    const firstSentence = sentMatch[0].trim();
    // Sentence body without its terminating punctuation, for a full-match test.
    const sentenceBody = firstSentence.replace(/[。！!]\s*$/, "").trim();
    const tail = body.slice(sentMatch[0].length).trim();
    const isStandalonePreamble =
      sentenceBody.length > 0 && sentenceBody.length <= MAX_PREAMBLE_LEN &&
      STANDALONE_PREAMBLE_OPENERS.some((re) => {
        const mm = re.exec(sentenceBody);
        // Require the opener to consume the ENTIRE sentence body (a full preamble),
        // not just lead it — so "整理答案的逻辑在 Foo.java" (continues with real
        // content) is NOT eligible, but "整理一下答案" / "数值已核实，直接给出对比结论" is.
        return mm !== null && mm.index === 0 && mm[0].length === sentenceBody.length;
      });
    if (tail.length > 0 && isStandalonePreamble) return tail;
  }

  return body;
}
