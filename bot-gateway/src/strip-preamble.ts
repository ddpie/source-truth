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

// STRICTER subset (used by BOTH strategies via isFullPreamble). Without a `---` signal, an opener
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
  new RegExp(`^.{0,40}(已|都).{0,8}(核实|确认|取到|取得|获取|收集|读到|查到|拿到|读完|查完|读清楚|查清楚|弄清楚)[，,]?.{0,30}(给出|得出|整理|呈现|说明).{0,12}(答案|结论|对比|说明)${TAIL}$`),
  new RegExp(`^.{0,30}(直接|下面|以下就?)给出(完整|最终|对比)?(的)?(答案|结论)${TAIL}$`),
  // "现在(我)(已经)掌握了足够的信息，(来)整理答案" — readiness + announce, full sentence.
  new RegExp(`^现在(我)?(已经)?(掌握|拿到|有)了?(足够|所有|相关)?(的)?(信息|证据|内容|数据)?[，,]?.{0,12}(整理|给出|得出)(一下)?(答案|结论|回答)${TAIL}$`),
  new RegExp(`^(我)?(已经)?(掌握|拿到|取得|获取|收集到|获取到)了?(足够|所有|相关|关键)(的)?(信息|证据|内容|数据)[，,]?.{0,16}(现在)?(整理|给出|得出|开始)?(完整|对比)?(一下)?(答案|结论|回答)?${TAIL}$`),
  // "可以作答了" / "现在可以回答了" / "已取到信息，可以作答" — the readiness sentence that
  // ends by announcing it will now answer (作答/回答). Broad on the lead-in but the
  // FULL-sentence match + short-length guard keep it from eating a real answer.
  new RegExp(`^.{0,48}(可以|现在|来|开始|这就)(作答|回答|给出答案|给出结论)(了|啦)?${TAIL}$`),
  new RegExp(`^.{0,40}(已|都)(经)?.{0,8}(取到|取得|获取|收集|拿到|有|够)了?(足够|所有|相关|关键)?(的)?(信息|证据|内容|数据)?[，,]?.{0,12}(可以|现在|来|这就)?(作答|回答|给出|整理|说明)(答案|结论)?(了|啦)?${TAIL}$`),
  // "(所有)信息都齐了，(来)整理答案" — readiness phrased as "data is all here" + announce.
  new RegExp(`^(所有|相关|关键)?(的)?(信息|证据|内容|数据|资料)(都|也|已)?(齐|够|到位|到齐|备齐)了?[，,]?.{0,12}(可以|现在|来|这就)?(整理|给出|得出|作答|回答|说明)(一下)?(完整|对比)?(的)?(答案|结论|回答)?(了|啦)?${TAIL}$`),
  /^(let me|i'?ll)\s+(now\s+)?(compile|summarize|put together|organize)\s+(the\s+)?(answer|findings?|results?)\s*[.:]?$/i,
  /^now\s+(let me|i'?ll)\s+(compile|summarize|put together|organize|give|provide)\b.{0,30}$/i,
  /^(i\s+)?(now\s+)?have\s+(enough|all\s+the)\s+(info|information|evidence)\b.{0,40}$/i,
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
// True iff `text` (a sentence body, terminator already stripped) is ENTIRELY a
// recognized preamble — a FULL match against a STANDALONE opener, not a prefix.
// This is the single discipline both strategies use, so neither can over-strip a
// real sentence that merely BEGINS with a meta-phrase ("整理答案的逻辑在 Foo.java").
function isFullPreamble(text: string): boolean {
  if (text.length === 0 || text.length > MAX_PREAMBLE_LEN) return false;
  return STANDALONE_PREAMBLE_OPENERS.some((re) => {
    const mm = re.exec(text);
    return mm !== null && mm.index === 0 && mm[0].length === text.length;
  });
}

export function stripPreamble(body: string): string {
  if (!body) return body;

  // Strategy 1 — preamble + `---` SEPARATOR. The model writes its transition note,
  // a `---`, then the real answer. Match a proper HR line (`\n---\n`) OR an inline
  // `---` (observed: "…答案了。---这个项目…"). CRITICAL: the inline fallback must NOT
  // land on a markdown TABLE separator (`|---|---|`) — the agent uses tables in
  // answers, and matching the table's `---` would chop the answer in half. So the
  // fallback requires the `-{3,}` to NOT be adjacent to a `|`. And the head before
  // the separator must be a FULL preamble sentence (isFullPreamble), not merely
  // start with a meta-phrase — else a real "可以给出对比数据如下：" + table is mangled.
  const hrMatch = body.match(/(^|\n)\s*-{3,}\s*(\n|$)/) ?? body.match(/(?<![|\s-])-{3,}(?![|-])/);
  if (hrMatch && hrMatch.index !== undefined) {
    const head = body.slice(0, hrMatch.index).trim();
    // Reduce the head to its FIRST sentence body (mirror strategy 2) for a full match.
    const headSentence = head.replace(/[。！!].*$/s, "").replace(/[。！!]\s*$/, "").trim();
    if (isFullPreamble(headSentence) || isFullPreamble(head)) {
      const tail = body.slice(hrMatch.index + hrMatch[0].length).trim();
      if (tail.length > 0) return tail;
    }
  }

  // Strategy 2 — preamble as a standalone LEADING SENTENCE, no separator (observed:
  // "数值已从代码逐一核实，直接给出对比结论。\n**匕首**的基础伤害…"). Only fire when the
  // FIRST sentence (up to the first 。/！/.\n) is ENTIRELY a recognized preamble and
  // real content follows.
  const sentMatch = body.match(/^\s*([^\n。！.!]{1,}[。！!]|[^\n]{1,}\n)/);
  if (sentMatch) {
    const firstSentence = sentMatch[0].trim();
    const sentenceBody = firstSentence.replace(/[。！!]\s*$/, "").trim();
    const tail = body.slice(sentMatch[0].length).trim();
    if (tail.length > 0 && isFullPreamble(sentenceBody)) return tail;
  }

  return body;
}
