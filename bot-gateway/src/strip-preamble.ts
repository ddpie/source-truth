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
// Trailing particles/punctuation that can follow the announce noun without making
// it a real answer. Includes an optional "如下"/"如下所示"/"下面" closer ("整理答案
// 如下。") — a transition sentence often ends that way, and it's never how a real
// business answer's FIRST sentence ends.
const TAIL = "(?:如下所示|如下|下面)?[了啦呢吧，,：:。\\s]{0,4}";
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
  // "所有X(数值)都已读到/取到，来整理成(完整)对比表/列表/答案" — readiness ending in
  // an announce-to-PRESENT verb + a result noun that can be a TABLE/LIST (not just
  // 答案/结论). The .{0,48} lead-in + FULL-sentence match + 160-char cap keep it from
  // matching a real answer sentence. Result noun set incl. 对比表/表格/清单/列表/对比.
  new RegExp(`^.{0,48}(都|也|已|已经)?(读到|读完|取到|取得|拿到|查到|获取|收集|核实|确认)了?[，,]?.{0,16}(可以|现在|来|这就|开始)?(整理|汇总|给出|得出|呈现|列出|做)(成|出|一下)?(完整|对比)?(的)?(对比表|表格|清单|列表|对比|答案|结论|回答)${TAIL}$`),
  // Broad readiness→announce skeleton: "<任意取证铺垫>，(现在|来|这就)整理/汇总/给出
  // …答案/结论". Keyed on the ANNOUNCE TAIL ("现在整理答案" / "来给出结论"), which is
  // unambiguously a transition note, not a business answer — a real answer never
  // ENDS its first sentence announcing it will now answer. The lead-in .{0,60}
  // absorbs varied readiness phrasings (取证完毕 / 都已查清 / 数据齐全 …) that the
  // specific patterns above miss. FULL-sentence match + 160-char cap是安全网：a real
  // sentence继续讲内容、不会在"整理答案"处终止，故不会被full-match命中。
  new RegExp(`^.{0,60}[，,。]?(现在|来|这就|接下来|下面|直接)(就)?(我)?(来|开始|直接)?(分类|逐类|逐一|依次|分别)?(整理|汇总|给出|得出|呈现|输出|回答|说明|讲解|讲讲|讲)(成|出)?(一下)?(完整|最终|对比)?(的)?(答案|结论|回答|内容|信息|结果|输出)?${TAIL}$`),
  // "现在我有完整的数据，来整理所有怪物的完整信息" / "数据齐全，来整理一下结果" — readiness
  // (有/拿到/掌握 + 数据/信息) + a 来/现在 + 整理/汇总 announce that ends in a
  // PROCESS-OUTPUT noun (信息/内容/输出/结果/数据/资料), NOT just 答案/结论. Observed live.
  // The .{0,20} after 整理 absorbs an object phrase ("所有怪物的完整"). FULL-match +
  // 160-char cap keep it from eating a real answer sentence.
  new RegExp(`^(现在)?(我)?(已经)?(有|拿到|掌握|取得|获取|收集)了?(完整|全部|所有|相关|足够|关键)?(的)?(数据|信息|内容|资料|证据)?[，,]?.{0,8}(现在|来|这就|开始)?(整理|汇总|输出|给出|呈现|列出)(一下)?.{0,20}(信息|内容|输出|结果|数据|资料|答案|结论|回答|设定|逻辑|机制|规则)${TAIL}$`),
  // "已经掌握全部怪物生命值数据，现在整理输出" — readiness + announce ending in the
  // bare verb 输出/作答 (no trailing noun). The lead-in absorbs the object; the
  // announce verb itself is the terminator.
  new RegExp(`^(现在)?(我)?(已经)?(有|拿到|掌握|取得|获取|收集|读到|查到|核实|确认)了?.{0,30}(数据|信息|内容|资料|证据|代码|逻辑)[，,]?.{0,8}(现在|来|这就|开始)?(整理|汇总|给出|呈现)?(并)?(输出|作答|回答)(一下)?${TAIL}$`),
  // "<readiness>，下面整理" / "…都核实清楚了，下面整理" — readiness + a BARE
  // announce verb (整理/汇总/梳理/归纳) with NO result noun after it (observed live:
  // "已经把成长途径都核实清楚了，下面整理。"). The other patterns require a trailing
  // 答案/结论 noun; here the announce verb itself is the sentence terminator. The
  // .{0,60} lead-in absorbs the readiness clause; FULL-sentence match + 160-char cap
  // keep it from eating a real sentence (a real answer never ENDS its first sentence
  // on a bare "下面整理" — that's purely a transition).
  new RegExp(`^.{0,60}[，,。]?(现在|来|这就|接下来|下面|稍后)(就)?(我)?(来|开始)?(整理|汇总|梳理|归纳)(一下)?${TAIL}$`),
  // "已核对完整的XX逻辑，结论清楚了。" / "都查清了，结论很明确。" — a readiness/取证
  // verb (核对/核实/确认/查清/梳理/搞清) FOLLOWED by a COMPLETION announce
  // (结论清楚/清楚了/明确了/明白了/有结论了) with no result content after it. This is
  // purely a "I'm done investigating" transition — a real answer's first sentence never
  // ENDS by announcing the conclusion is now clear; it just STATES the conclusion. The
  // FULL-sentence match + 160-char cap keep it from eating a real sentence that merely
  // contains 结论/清楚 mid-clause ("结论清楚了之后会缓存…" continues → not a full match).
  new RegExp(`^.{0,48}(核对|核实|确认|查清|查证|梳理|搞清|弄清|核查|对照)(完|完毕|清楚|好)?了?.{0,20}[，,]?(结论|答案|逻辑|情况|机制)?(已)?(清楚|明确|明了|明白|清晰|有了结论|出来了|清楚了)了?${TAIL}$`),
  // "已经把XX都查清了。" / "我已经把…核对完了。" — a "把…(都)<取证动词>(完/清)了" readiness
  // sentence that ENDS on the bare completion verb (no result content). Often the
  // FIRST of a 2-sentence preamble (paired with "下面分类说明。" below; the iterative
  // 2-pass strip handles the pair). FULL-match guard + 160 cap keep it safe.
  new RegExp(`^(我)?(现在)?(已经|已)?(把|将)?.{0,40}(都|全部|逐一|一一)?(查清楚|查清|查明|核对|核实|确认|查证|梳理|搞清楚|搞清|弄清楚|弄清|核查|查完|读完|看完|捋|过)(完|完毕|清楚|好|了一遍|一遍)?了${TAIL}$`),
  // "已经查清玩家摔落伤害的完整逻辑了。" — readiness verb EARLY, then an object phrase,
  // ending on "(的)(完整)?(逻辑|机制|规则|算法|计算|公式|设定|流程)了" — an
  // investigation-complete announce about the TOPIC's logic, no result content. The
  // .{0,40} absorbs the object; the trailing process-noun + 了 is the terminator.
  // FULL-sentence match + 160 cap keep a real sentence (which continues past 了) safe.
  // The completion 了 may sit right after the VERB (掌握了…全貌) OR after the noun
  // (查清…逻辑了) — so both 了s are optional but at least the verb's or the noun's
  // marks completion (the readiness 已经/已 prefix + process-noun ending is the anchor).
  new RegExp(`^(我)?(现在)?(已经|已)(把|将)?.{0,40}(查清楚|查清|查明|核对|核实|确认|查证|梳理|搞清楚|搞清|弄清楚|弄清|核查|看|掌握|拿到|弄明白|摸清)了?.{0,40}(的)?(完整|整套|全部|所有)?(逻辑|机制|规则|算法|计算|公式|设定|流程|来龙去脉|情况|全貌|全部|影响点|影响|关键点|要点|细节)了?${TAIL}$`),
  // "下面分类说明。" / "下面是结论。" / "下面逐类讲。" — a bare "下面/接下来 + 呈现动词"
  // announce with NO readiness lead-in (often the SECOND sentence of a 2-sentence
  // preamble). Kept tight: requires a 下面/接下来/这就/下面就 opener so it can't match a
  // real sentence that merely starts with 说明/讲.
  new RegExp(`^(下面|接下来|这就|下面就|那么)(我)?(就)?(来|开始|先|直接)?(分类|逐类|逐一|依次|分别)?(说明|讲|讲讲|讲解|展开|道来|是结论|给结论|说结论|说答案|给答案|回答|列出来)(一下)?(它|其|这些)?(在.{0,16}(里|中))?(的)?(作用|机制|规则|逻辑|用法|影响|效果)?${TAIL}$`),
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
  // The model sometimes emits a TWO-sentence preamble ("已经把X都查清了。下面分类
  // 说明。" then the answer) — each sentence is independently a full preamble. Strip
  // ITERATIVELY (bounded to 2 passes so a pathological input can't loop, and so we
  // never chew into a real answer — 2 transition sentences is the observed max).
  // Each pass must make progress (shorter) or we stop.
  let out = body;
  for (let i = 0; i < 2; i++) {
    const next = stripPreambleOnce(out);
    if (next === out) break;
    out = next;
  }
  return out;
}

/** One pass: strip a SINGLE leading preamble (separator form or standalone
 *  sentence). Returns the input unchanged if the head isn't a full preamble. PURE. */
function stripPreambleOnce(body: string): string {
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
    // The tail must hold REAL content — not just a bare separator / whitespace
    // (else "现在我整理答案。\n---\n  " would strip down to "---", which is not an
    // answer). Drop a leading HR line before checking emptiness.
    const tail = body.slice(sentMatch[0].length).replace(/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/m, "").trim();
    if (tail.length > 0 && isFullPreamble(sentenceBody)) return tail;
  }

  return body;
}
