/**
 * CardKit v1 client — the "growing answer card".
 *
 * Lifecycle (verified live, see docs/agent/cardkit-streaming-spike.md):
 *   1. createCard      POST /open-apis/cardkit/v1/cards            -> card_id
 *   2. updateContent   PUT  .../cards/{id}/elements/conclusion/content  (full text + ++sequence, typewriter)
 *   3. closeStreaming  PATCH .../cards/{id}/settings  (streaming_mode=false)
 *   4. send as IM interactive message content {type:card, data:{card_id}}
 *
 * Hard constraints baked in: streaming_config.print_frequency_ms + print_step
 * must be paired (else code 11311); content updates carry an increasing
 * sequence; after closeStreaming content can't change (but components can be
 * appended). API calls go through lark-cli (`api <METHOD> <path> --as bot`),
 * the same /open-apis/cardkit/v1 endpoints the node-sdk hits.
 */

import { feishuApi } from "./feishu-http";
import { MAX_FOLLOW_UPS } from "./extract-followups";
import { MAX_CLARIFY_OPTIONS } from "./extract-clarify";
import { t } from "./i18n";

// ── pure request builders (unit-tested) ──────────────────────────────────────

/** Build the user-question echo element. The question is the user's RAW text, so
 *  stray markdown metacharacters (`**`, backticks, pipes, snake_case `_`) must not
 *  be interpreted — an odd `**` would leak bold into the hr/conclusion below, a
 *  backtick opens an inline-code span, etc. We render it via a `div` whose inner
 *  `text` is a `plain_text` tag: plain_text NEVER interprets markdown, so NO
 *  escaping is needed and nothing can corrupt the card (verified live — a markdown
 *  element with backslash-escapes renders the literal backslashes in CardKit,
 *  which is NOT CommonMark, so escaping would make the common case worse). A
 *  newline collapse keeps a multi-line paste on one line. element_id="question"
 *  so it survives streaming/finalize. */
export function buildQuestionElement(question: string): Record<string, unknown> {
  const oneLine = question.replace(/\s*[\r\n]+\s*/g, " ");
  return {
    tag: "div",
    element_id: "question",
    text: { tag: "plain_text", content: `${t("card.question.prefix")}${oneLine}` },
  };
}

/** "TraceID: <id>" as a single quote line at the very top of the card. The id is the
 *  same one stamped on every log line for this request, so an operator can grep logs
 *  when a user reports a problem. Rendered as ONE muted line — a grey label + the id
 *  in inline code (`<font>` greys the label so it sits quietly above the answer; the
 *  blockquote `>` was dropped because its left bar competes visually, and a code block
 *  is heavier still). The inline-code id is long-press-copyable on mobile, which is the
 *  lightweight stand-in for the copy button Feishu cards have no native component for —
 *  matching how Stripe/Sentry surface a request-id: a quiet, copyable short code. Placed
 *  as the FIRST element so it's already on-screen even if the card ends early. */
export function buildTraceElement(traceId: string): Record<string, unknown> {
  return {
    tag: "markdown",
    element_id: "trace",
    content: `<font color='grey'>${t("card.trace.prefix")}</font>\`${traceId}\``,
  };
}

export function buildCreateCardBody(opts?: { summary?: string; followUp?: boolean; question?: string; traceId?: string }): string {
  // summary.content customizes the chat-list preview (default would be "[生成中...]").
  const summary = opts?.summary ? opts.summary.slice(0, 40) : t("card.summary.default");
  // Follow-up cards (from a clicked button) get a distinct header so the chat
  // history clearly shows "this card answers a follow-up question".
  const title = opts?.followUp ? t("card.title.thinking.followup") : t("card.title.thinking");
  // Echo the user's question at the TOP of the card body as a plain_text div
  // (buildQuestionElement), so the card is self-contained — the reader sees WHAT
  // was asked without scrolling up the chat. element_id="question" so it stays put
  // through streaming/finalize; plain_text means raw markdown in the question can't
  // corrupt the card.
  const elements: unknown[] = [];
  // traceId line at the very top (above the echoed question) so it's the first thing
  // visible + survives streaming (element_id="trace"). finalizeCard re-includes it.
  if (opts?.traceId) elements.push(buildTraceElement(opts.traceId));
  const q = (opts?.question ?? "").trim();
  if (q) {
    elements.push(buildQuestionElement(q));
    elements.push({ tag: "hr" });
  }
  elements.push({ tag: "markdown", content: t("card.conclusion.placeholder"), element_id: "conclusion" });
  const card = {
    schema: "2.0",
    config: {
      update_multi: true,
      streaming_mode: true,
      summary: { content: summary },
      streaming_config: {
        print_frequency_ms: { default: 70 }, // official default; smooth typewriter
        print_step: { default: 1 },
        print_strategy: "fast",
      },
    },
    header: {
      title: { tag: "plain_text", content: title },
      template: "blue",
    },
    body: { elements },
  };
  return JSON.stringify({ type: "card_json", data: JSON.stringify(card) });
}

export function contentUpdatePath(cardId: string): string {
  return `/open-apis/cardkit/v1/cards/${cardId}/elements/conclusion/content`;
}

export function buildContentUpdateBody(content: string, sequence: number): string {
  return JSON.stringify({ content, sequence });
}

export function settingsPath(cardId: string): string {
  return `/open-apis/cardkit/v1/cards/${cardId}/settings`;
}

export function buildCloseStreamingBody(sequence: number): string {
  return JSON.stringify({
    settings: JSON.stringify({ config: { streaming_mode: false } }),
    sequence,
  });
}

export function buildSendCardContent(cardId: string): string {
  return JSON.stringify({ type: "card", data: { card_id: cardId } });
}

/** Human-readable elapsed duration: seconds under a minute, "Mm Ss" under an
 *  hour, "Hh Mm" beyond. Keeps the live timer honest AND readable on a long run
 *  (a bare seconds counter reaching "247s" reads worse than "4m 7s"). */
export function formatElapsed(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  if (total < 60) return `${total}s`;
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m ${s}s`;
}

/** Append a dedicated status line element (element_id="status") ONCE, above the
 *  conclusion. This element is updated ELEMENT-LEVEL (never a full-card PUT), so
 *  the live "正在分析 12s ⠹" timer can advance in EVERY phase — including after
 *  the stop button / reasoning panel are appended — without wiping them. (The
 *  header-based heartbeat could only animate in the thinking phase because its
 *  full-card PUT wiped appended elements.) */
export async function appendStatusLine(cardId: string, text: string, sequence: number): Promise<void> {
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "insert_before",
    target_element_id: "conclusion",
    sequence,
    elements: JSON.stringify([{ tag: "markdown", content: text, element_id: "status" }]),
  }));
}

/** Update the live status line in place (element-level PUT — does NOT touch any
 *  other element, so the stop button / reasoning panel / streamed conclusion all
 *  survive). This is what keeps the timer animating continuously. */
export async function updateStatusLine(cardId: string, text: string, sequence: number): Promise<void> {
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}/elements/status`, JSON.stringify({
    element: JSON.stringify({ tag: "markdown", content: text, element_id: "status" }),
    sequence,
  }));
}

// ── CardKit transport (in-process HTTP) ──────────────────────────────────────

// Every CardKit write goes through the Feishu OpenAPI directly via `fetch` with a
// cached tenant_access_token — NOT `spawn lark-cli`. A lark-cli spawn costs ~800ms
// (Node cold start + token handling); a direct HTTPS call is ~50-100ms. On the
// serial card-write queue that was the difference between the live timer updating
// every ~1-2s (laggy) and several times a second (smooth), and it speeds up the
// conclusion typewriter too. feishuApi enforces the same contract the old wrapper
// did (timeout, non-2xx → throw, non-zero Feishu code → throw) plus a one-shot
// 401 token-refresh retry. The data builders below emit a JSON STRING (historical
// shape); we parse it back to an object for the JSON body. Kept as a thin wrapper
// so all existing callers (build*Body → larkApi) are unchanged.
function larkApi(method: string, path: string, data: string): Promise<unknown> {
  let body: unknown;
  try {
    body = JSON.parse(data);
  } catch (e) {
    return Promise.reject(new Error(`bad CardKit request body for ${method} ${path}: ${String(e)}`));
  }
  return feishuApi(method as "GET" | "POST" | "PUT" | "PATCH" | "DELETE", path, body);
}

/** Create a streaming card; returns its card_id. summary = chat-list preview. */
export async function createCard(summary?: string, followUp?: boolean, question?: string, traceId?: string): Promise<string> {
  const resp = await larkApi("POST", "/open-apis/cardkit/v1/cards", buildCreateCardBody({ summary, followUp, question, traceId }));
  // feishuApi only guarantees code===0 + a parsed object, NOT a `data.card_id`.
  // Fail LOUD with a self-describing message (this is the first call on the answer
  // hot path) instead of an opaque "Cannot read properties of undefined" TypeError,
  // so the card_fallback log names the actual Feishu-side problem.
  const id = (resp as { data?: { card_id?: string } })?.data?.card_id;
  if (!id) throw new Error(`createCard: Feishu returned no card_id: ${JSON.stringify(resp).slice(0, 300)}`);
  return id;
}

/** Stream the conclusion text (full content + sequence; typewriter续写). */
export async function updateContent(cardId: string, content: string, sequence: number): Promise<void> {
  await larkApi("PUT", contentUpdatePath(cardId), buildContentUpdateBody(content, sequence));
}

/** Turn streaming off once the answer is final. */
export async function closeStreaming(cardId: string, sequence: number): Promise<void> {
  await larkApi("PATCH", settingsPath(cardId), buildCloseStreamingBody(sequence));
}

/** Completed-card header title — keeps the follow-up marker so the chat
 *  history still shows a finished follow-up card as a follow-up. When an
 *  elapsedLabel is given (e.g. "用时 67s"), it's appended so the user sees the
 *  total time the answer took. */
export function finalizeTitle(followUp?: boolean, aborted?: boolean, failed?: boolean, elapsedLabel?: string, turnCapped?: boolean, clarify?: boolean, timedOut?: boolean): string {
  // turnCapped/timedOut are PARTIAL results — their header must NOT read as a
  // confident green "回答完成" while the body says "未完成". Distinct signal.
  // clarify is NOT an answer — the agent is asking the user to disambiguate — so
  // its header must say so, not "回答完成".
  const base = failed ? t("card.title.failed")
    : aborted ? t("card.title.aborted")
    : turnCapped ? t("card.title.turnCapped")
    : timedOut ? t("card.title.timedOut")
    : clarify ? t("card.title.clarify")
    : followUp ? t("card.title.followup.done")
    : t("card.title.done");
  // Show elapsed except on a hard failure (where "time" is meaningless/misleading)
  // and on a clarify (it's a question back to the user, elapsed is noise).
  return elapsedLabel && !failed && !clarify ? `${base} · ${t("card.title.elapsed", { elapsed: elapsedLabel })}` : base;
}

/** A "停止" button shown during streaming. value.card_id lets the click
 *  callback route the abort to the right in-flight agent stream. */
export function buildStopButton(cardId: string): unknown {
  return {
    tag: "button",
    element_id: "stopbtn",
    text: { tag: "plain_text", content: t("card.button.stop") },
    type: "danger_text",
    size: "small",
    value: { action: "stop", card_id: cardId },
  };
}

/** Append the stop button to the streaming card (best-effort). */
export async function appendStopButton(cardId: string, sequence: number): Promise<void> {
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify([buildStopButton(cardId)]),
  }));
}

/** The "分析过程" collapsible panel — same component live (expanded, streaming
 *  the steps the agent is taking) and finalized (collapsed, archived for the
 *  dev to expand). Stable element_id="reasoning" so it can be updated in place
 *  mid-stream. Returns null when there are no steps yet. */
export function buildReasoningPanel(steps: string[], expanded: boolean): unknown {
  if (steps.length === 0) return null;
  const heading = expanded ? `**${t("card.panel.reasoning.live")}**` : `**${t("card.panel.reasoning.done")}**`;
  return {
    tag: "collapsible_panel",
    element_id: "reasoning",
    expanded,
    background_color: "grey",
    padding: "8px 8px 8px 8px",
    border: { color: "grey", corner_radius: "5px" },
    vertical_spacing: "8px",
    header: {
      title: { tag: "markdown", content: heading },
      vertical_align: "center",
      padding: "4px 0px 4px 8px",
      width: "auto_when_fold",
      icon: { tag: "standard_icon", token: "down-small-ccm_outlined", color: "grey", size: "16px 16px" },
      icon_position: "follow_text",
      icon_expanded_angle: -180,
    },
    elements: [{ tag: "markdown", content: steps.map((s) => `- ${s}`).join("\n") }],
  };
}

/** Append the live reasoning panel (expanded) to the card — once, when the first
 *  step appears. APPENDED (after the conclusion), NOT inserted before it, so the
 *  layout matches finalizeCard's order [conclusion, reasoning, evidence]. If the
 *  panel sat above the conclusion during streaming and below it at finalize, the
 *  whole card would visibly re-layout at stream-end (the 分析过程 / 供研发复核
 *  jumping position) — confusing the reader. Keeping the answer first and the
 *  panel below it THROUGHOUT (streaming and finalized) means nothing reorders. */
export async function appendReasoningPanel(cardId: string, steps: string[], sequence: number): Promise<void> {
  const panel = buildReasoningPanel(steps, true);
  if (!panel) return;
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify([panel]),
  }));
}

/** Update the live reasoning panel in place as steps grow (expanded). */
export async function updateReasoningPanel(cardId: string, steps: string[], sequence: number): Promise<void> {
  const panel = buildReasoningPanel(steps, true);
  if (!panel) return;
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}/elements/reasoning`, JSON.stringify({
    element: JSON.stringify(panel),
    sequence,
  }));
}

/** Make agent-authored chart axes render reliably. Two backstops, both confirmed against
 *  the FEISHU OFFICIAL chart doc's own example (`axes[].title.{visible:true,text}` + each
 *  axis carries `type`):
 *   1. AXIS TITLE VISIBILITY — VChart hides axis titles by DEFAULT (`title.visible` is
 *      false unless set), so an agent spec `axes:[{orient,title:{text:"等级"}}]` rendered a
 *      chart with NO x/y axis description (user-reported). Force `visible:true` on any axis
 *      whose title has non-empty text.
 *   2. AXIS TYPE — if the axis `type` is missing, VChart usually infers band(x)/linear(y),
 *      but a missing/mismatched type is a separate reason an axis (and thus its title) can
 *      fail to render. Default the cartesian axes by orient: bottom→band (category),
 *      left→linear (value); leave top/right/explicit-type untouched.
 *  The prompt now emits both, but enforce gateway-side too so a spec that omits them still
 *  renders (defense-in-depth, mirrors the chart field-binding backstop). An explicit value
 *  the agent set always wins (spread AFTER the default). Pure: shallow-clones, only axes. */
export function ensureAxisTitlesVisible<T extends { [k: string]: unknown }>(spec: T): T {
  const axes = (spec as { axes?: unknown }).axes;
  if (!Array.isArray(axes)) return spec;
  const TYPE_BY_ORIENT: Record<string, string> = { bottom: "band", left: "linear" };
  const fixedAxes = axes.map((ax) => {
    if (!ax || typeof ax !== "object") return ax;
    const a = ax as { title?: unknown; orient?: unknown; type?: unknown };
    let out: Record<string, unknown> = { ...(ax as object) };
    // 1. force the title visible when it has non-empty text (explicit visible wins).
    const title = a.title;
    if (title && typeof title === "object" && typeof (title as { text?: unknown }).text === "string"
        && (title as { text: string }).text.trim() !== "") {
      out = { ...out, title: { visible: true, ...(title as object) } };
    }
    // 2. default a cartesian axis `type` by orient when the agent omitted it.
    if (a.type === undefined && typeof a.orient === "string" && a.orient in TYPE_BY_ORIENT) {
      out = { ...out, type: TYPE_BY_ORIENT[a.orient] };
    }
    return out;
  });
  return { ...spec, axes: fixedAxes };
}

/** Wrap VChart specs (extracted from the agent's ```chart blocks) as CardKit
 *  chart components. The agent builds specs from real config-table numbers it
 *  read; the gateway only transports them (plus the axis-title-visibility backstop). */
export function buildChartElements(specs: Array<{ type: string; [k: string]: unknown }>): unknown[] {
  return specs.map((spec, i) => ({
    tag: "chart",
    element_id: `chart_${i}`,
    chart_spec: ensureAxisTitlesVisible(spec),
  }));
}

// Cap on charts actually rendered. CardKit validates an append request
// atomically AND the card has a body-size limit, so an answer with many (or one
// huge) chart specs could blow the limit or contend with the per-card 10/s write
// budget. The prose table the prompt requires is the fallback for any dropped
// chart. (buildFollowUpElements caps at 3 for the same reason.)
export const MAX_CHARTS = 4;

/** Append ONE data chart as its own element. Used so a single malformed VChart
 *  spec can't make CardKit reject a whole batch (atomic append validation) and
 *  wipe every chart — each is isolated; one failing append is logged and skipped
 *  by the caller while the rest still render. `index` keeps element_ids unique. */
export async function appendOneChart(
  cardId: string,
  spec: { type: string; [k: string]: unknown },
  index: number,
  sequence: number,
): Promise<void> {
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify([{ tag: "chart", element_id: `chart_${index}`, chart_spec: ensureAxisTitlesVisible(spec) }]),
  }));
}

/** Append data charts to the card (after the conclusion, before the footer).
 *  Kept for callers/tests that batch; the live path uses appendOneChart per spec
 *  for per-chart fault isolation. */
export async function appendCharts(
  cardId: string,
  specs: Array<{ type: string; [k: string]: unknown }>,
  sequence: number,
): Promise<void> {
  const elements = buildChartElements(specs);
  if (elements.length === 0) return;
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify(elements),
  }));
}

/** Collapsible "供研发复核" panel for the evidence section (file paths / symbols
 *  / line numbers). Mirrors the 分析过程 panel: EXPANDED while it streams (the dev
 *  watches the citations forming, same as the reasoning steps) and FOLDED at
 *  finalize (the non-technical reader is left with just the business answer; a dev
 *  re-expands to verify). null when there's no evidence. */
export function buildEvidencePanel(evidence: string, expanded = false): unknown {
  if (!evidence.trim()) return null;
  return {
    tag: "collapsible_panel",
    element_id: "evidence",
    expanded,
    background_color: "grey",
    padding: "8px 8px 8px 8px",
    border: { color: "grey", corner_radius: "5px" },
    vertical_spacing: "8px",
    header: {
      title: { tag: "markdown", content: `**${t("card.panel.evidence.title")}**` },
      vertical_align: "center",
      padding: "4px 0px 4px 8px",
      width: "auto_when_fold",
      icon: { tag: "standard_icon", token: "down-small-ccm_outlined", color: "grey", size: "16px 16px" },
      icon_position: "follow_text",
      icon_expanded_angle: -180,
    },
    elements: [{ tag: "markdown", content: evidence }],
  };
}

/** Append the live "供研发复核" panel (folded) ONCE, when evidence first appears
 *  mid-stream. Same element_id="evidence" as finalizeCard's panel + same layout
 *  order (below the conclusion), so it does NOT re-layout at finalize — it just
 *  stops being touched. EXPANDED while streaming (mirrors 分析过程 — the dev sees
 *  citations forming live); finalizeCard re-folds it. */
export async function appendEvidencePanel(cardId: string, evidence: string, sequence: number): Promise<void> {
  const panel = buildEvidencePanel(evidence, true);
  if (!panel) return;
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify([panel]),
  }));
}

/** Update the live evidence panel in place as more citations stream in (stays
 *  expanded during streaming, same as updateReasoningPanel). */
export async function updateEvidencePanel(cardId: string, evidence: string, sequence: number): Promise<void> {
  const panel = buildEvidencePanel(evidence, true);
  if (!panel) return;
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}/elements/evidence`, JSON.stringify({
    element: JSON.stringify(panel),
    sequence,
  }));
}

/** After close streaming: update header to "完成" (green) via full card PUT.
 *  PUT body = { card: { type, data }, sequence } — full replace, must carry body.
 *  `evidence` (optional) renders as a folded "供研发复核" panel below the answer. */
export async function finalizeCard(
  cardId: string,
  conclusion: string,
  steps: string[],
  sequence: number,
  followUp?: boolean,
  aborted?: boolean,
  failed?: boolean,
  evidence?: string,
  question?: string,
  elapsedLabel?: string,
  turnCapped?: boolean,
  clarify?: boolean,
  timedOut?: boolean,
  traceId?: string,
): Promise<void> {
  const panel = buildReasoningPanel(steps, false);
  const evidencePanel = buildEvidencePanel(evidence ?? "");
  // Re-include the trace line + echoed question at the top (the full-PUT rebuilds the
  // whole body, so they'd be wiped otherwise — must match the streaming layout).
  const traceEls = traceId ? [buildTraceElement(traceId)] : [];
  const q = (question ?? "").trim();
  const questionEls = q
    ? [buildQuestionElement(q), { tag: "hr" }]
    : [];
  const card = {
    schema: "2.0",
    config: { update_multi: true },
    header: {
      title: { tag: "plain_text", content: finalizeTitle(followUp, aborted, failed, elapsedLabel, turnCapped, clarify, timedOut) },
      template: failed ? "red" : aborted ? "grey" : turnCapped ? "orange" : timedOut ? "orange" : clarify ? "blue" : "green",
    },
    body: {
      // Order MUST match the live-stream append order so the full-PUT doesn't visibly
      // reorder panels at finalize: conclusion, then reasoning (appended first, during
      // tool calls), then evidence (appended later, when the 供研发复核 section streams).
      elements: [
        ...traceEls,
        ...questionEls,
        { tag: "markdown", content: conclusion, element_id: "conclusion" },
        ...(panel ? [panel] : []),
        ...(evidencePanel ? [evidencePanel] : []),
      ],
    },
  };
  const body = JSON.stringify({ card: { type: "card_json", data: JSON.stringify(card) }, sequence });
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}`, body);
}

/** An outcome-driven ACTION button (vs an answer-derived follow-up suggestion).
 *  - retry  : re-ask the ORIGINAL question fresh (no context replay — the failed
 *             turn has nothing useful to carry; a retry usually lands on a now-warm
 *             VM and succeeds). Shown when the turn failed / leaked / no answer.
 *  - narrow : re-ask a NARROWED version (prepend a "只聚焦其中一点" hint) so a
 *             step-capped run can finish. Shown on turnCapped. */
export interface ActionButton {
  kind: "retry" | "narrow";
  text: string;   // the question to re-ask (raw user question; narrow prepends a hint)
  label: string;  // the button caption
}

/** Build the footer elements: a divider + outcome ACTION buttons (retry/narrow,
 *  shown first) + clickable follow-up suggestions. Each gets a stable element_id
 *  echoed in its value so the click callback can disable exactly the one pressed. */
export function buildFollowUpElements(followUps: string[], actions: ActionButton[] = []): unknown[] {
  const elements: unknown[] = [{ tag: "hr" }];
  // Outcome action buttons first (the user's most likely next move on a failed /
  // capped turn). They reuse the follow_up callback path (re-ask value.text); the
  // action kind lets the callback decide whether to replay context.
  actions.forEach((a, i) => {
    const eid = `action_${a.kind}_${i}`;
    elements.push({
      tag: "button",
      element_id: eid,
      text: { tag: "plain_text", content: a.label },
      // primary so the recovery action stands out from grey follow-up suggestions.
      type: "primary",
      size: "small",
      width: "fill",
      value: { action: "follow_up", text: a.text, eid, fresh: a.kind === "retry" },
    });
  });
  if (followUps.length > 0) {
    elements.push({ tag: "markdown", content: `**${t("card.footer.followup.heading")}**` });
    followUps.slice(0, MAX_FOLLOW_UPS).forEach((q, i) => {
      const eid = `followup_${i}`;
      elements.push({
        tag: "button",
        element_id: eid,
        text: { tag: "plain_text", content: q },
        type: "default",
        size: "small",
        width: "fill",
        value: { action: "follow_up", text: q, eid },
      });
    });
    // After the suggested buttons, guide the user that they can ask ANYTHING not
    // listed by replying to the card directly (the buttons are just suggestions).
    elements.push({ tag: "markdown", content: t("card.footer.followup.replyHintWithButtons") });
  } else if (actions.length === 0) {
    // No suggested follow-ups AND no action buttons. Tell the user HOW to continue
    // with context: reply to this card. A bare "继续追问即可" was misleading —
    // context only carries when the message replies to a prior card.
    elements.push({ tag: "markdown", content: t("card.footer.followup.replyHint") });
  }
  return elements;
}

/** Build the clarify OPTION buttons (one per clarified option). The "what's
 *  ambiguous" prompt is rendered in the card BODY (finalText), not here, so it
 *  isn't shown twice. Clicking an option reuses the SAME `follow_up` callback
 *  action (so the click re-asks that clarified question WITH context replay) — no
 *  new callback path needed. The buttons are `primary` so they read as the main
 *  call-to-action, since the card has no other answer. */
export function buildClarifyElements(_question: string, options: string[]): unknown[] {
  const elements: unknown[] = [];
  options.slice(0, MAX_CLARIFY_OPTIONS).forEach((q, i) => {
    const eid = `clarify_${i}`;
    elements.push({
      tag: "button",
      element_id: eid,
      text: { tag: "plain_text", content: q },
      type: "primary",
      size: "small",
      width: "fill",
      // Reuse the follow_up action: clicking re-asks `q` as a new turn with the
      // prior context replayed (the callback resolves the parent card → chain).
      value: { action: "follow_up", text: q, eid },
    });
  });
  return elements;
}

/** A disabled button marked as already-clicked (✓ prefix). Used to update the
 *  pressed follow-up button in place after a click. Returns a JSON string
 *  (the update-element API takes `element` as a serialized string). */
export function buildClickedButtonElement(elementId: string, question: string): string {
  return JSON.stringify({
    tag: "button",
    element_id: elementId,
    text: { tag: "plain_text", content: `✓ ${question}` },
    type: "primary_text",
    size: "small",
    width: "fill",
    disabled: true,
    value: { action: "follow_up_done", text: question, eid: elementId },
  });
}

/** A disabled button keeping its ORIGINAL label, no ✓ (greyed-but-not-chosen). Used to
 *  disable the SIBLING buttons in a mutually-exclusive group when one is picked — e.g.
 *  after a 👍 vote, the 👎 button must also go disabled so the user can't then also vote
 *  👎 (the count guard already drops the 2nd vote, but the buttons looked clickable). */
export function buildDisabledButtonElement(elementId: string, label: string): string {
  return JSON.stringify({
    tag: "button",
    element_id: elementId,
    text: { tag: "plain_text", content: label },
    type: "default",
    size: "small",
    width: "fill",
    disabled: true,
    value: { action: "noop", eid: elementId },
  });
}

/** Disable a button in place WITHOUT the ✓ (sibling of a chosen button). Best-effort. */
export async function disableButtonPlain(cardId: string, elementId: string, label: string, sequence: number): Promise<void> {
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}/elements/${elementId}`, JSON.stringify({
    element: buildDisabledButtonElement(elementId, label),
    sequence,
  }));
}

// The negative-feedback reason codes (mirror metrics.ts FeedbackReasonCode). A 👎 reveals
// these; clicking one emits feedback_reason{reasonCode} then disables them. too_slow /
// hard_to_understand / too_shallow added (user request): for the non-technical 策划/QA
// audience "看不懂"(说人话没做到) / "太浅显"(漏档位/分支) / "时间太长"(延迟) are real,
// high-value负反馈信号 distinct from the accuracy/evidence ones.
export const FEEDBACK_REASON_CODES = [
  "inaccurate", "no_evidence", "off_topic", "outdated",
  "too_slow", "hard_to_understand", "too_shallow", "other",
] as const;

// The vote row is ONE column_set with its OWN element_id, so a vote replaces the WHOLE row
// in a single same-tag (column_set→column_set) PUT by that top-level id. Disabling the
// individual buttons NESTED in the column_set does NOT reliably take effect in the Feishu
// client (the PUT returns 200 but the nested button stays clickable — observed live: 👎 still
// re-clickable), so we replace the container, not its children.
export const FEEDBACK_ROW_EID = "feedback_row";

/** Build the 👍/👎 vote row (a column_set, two equal columns, element_id FEEDBACK_ROW_EID).
 *  `chosen` (set after a click) renders BOTH buttons disabled — the chosen one with a ✓ — so
 *  re-clicking does nothing (the buttons are inert). value.action="feedback" keeps them
 *  disjoint from follow_up/stop and the marker emoji. NOT asker-scoped: anyone may rate. */
export function buildFeedbackButtons(chosen?: "up" | "down"): unknown[] {
  const voteBtn = (vote: "up" | "down", eid: string, key: string) => {
    const picked = chosen === vote;
    const label = t(key);
    return {
      tag: "column", width: "weighted", weight: 1, elements: [{
        tag: "button", element_id: eid,
        text: { tag: "plain_text", content: picked ? `✓ ${label}` : label },
        type: picked ? "primary_text" : "default",
        size: "small", width: "fill",
        // When the row is in its chosen/disabled state, ALL vote buttons are disabled so a
        // re-click is impossible; value.action="noop" is belt-and-suspenders for a racing tap.
        disabled: chosen !== undefined,
        value: chosen !== undefined ? { action: "noop", eid } : { action: "feedback", vote, eid },
      }],
    };
  };
  return [{
    tag: "column_set",
    element_id: FEEDBACK_ROW_EID,
    flex_mode: "bisect",   // two equal columns share the row
    horizontal_spacing: "8px",
    columns: [voteBtn("up", "fb_up", "card.feedback.up"), voteBtn("down", "fb_down", "card.feedback.down")],
  }];
}

/** Replace the whole vote row with its disabled/chosen state (same-tag column_set PUT by the
 *  row's own top-level element_id — the reliable path, vs. disabling nested children). */
export async function disableFeedbackRow(cardId: string, chosen: "up" | "down", sequence: number): Promise<void> {
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}/elements/${FEEDBACK_ROW_EID}`, JSON.stringify({
    element: JSON.stringify(buildFeedbackButtons(chosen)[0]),
    sequence,
  }));
}

/** Stable element_id for the i-th reason button. INDEX-based (fbr_0..), NOT fbr_<code>:
 *  Feishu requires element_id ≤ 20 chars (letters/digits/underscore, letter-start) and
 *  `fbr_hard_to_understand` is 22 → the whole append was rejected with code 300315 and NO
 *  reason buttons showed (live bug). The reasonCode still travels in value.reasonCode for the
 *  metric; only the DOM id is shortened. Kept as a function so the callback's disable path
 *  derives the same id from the code's index. */
export function feedbackReasonEid(code: string): string {
  const i = FEEDBACK_REASON_CODES.indexOf(code as (typeof FEEDBACK_REASON_CODES)[number]);
  return `fbr_${i}`;
}

// The reason buttons live in ONE column_set with its own element_id, laid out as a compact
// 2-column grid (was 8 full-width rows — too tall for a non-technical reader, user request).
// A pick replaces the WHOLE grid in a single same-tag column_set PUT (disableFeedbackReasonRow)
// — same reliable path as the vote row, because disabling the buttons NESTED in the column_set
// does NOT take effect in the Feishu client (PUT 200 but stays clickable).
export const FEEDBACK_REASON_EID = "fbr_row";
const FEEDBACK_REASON_COLS = 2;

/** Build the 👎-reason grid (a column_set, element_id FEEDBACK_REASON_EID). `chosen` (set after
 *  a pick) renders every button disabled — the chosen one with a ✓ — so re-picking is inert.
 *  Buttons carry the enumerated reasonCode (in value, for the metric, never free text → no PII);
 *  the DOM element_id is the short index form fbr_<i> to stay within Feishu's 20-char limit. */
export function buildFeedbackReasonGrid(chosen?: string): unknown[] {
  const reasonBtn = (code: string) => {
    const picked = chosen === code;
    const label = t(`card.feedback.reason.${code}`);
    const eid = feedbackReasonEid(code);
    return {
      tag: "button", element_id: eid,
      text: { tag: "plain_text", content: picked ? `✓ ${label}` : label },
      type: picked ? "primary_text" : "default", size: "small", width: "fill",
      disabled: chosen !== undefined,
      value: chosen !== undefined ? { action: "noop", eid } : { action: "feedback_reason", reasonCode: code, eid },
    };
  };
  // Column-major fill into FEEDBACK_REASON_COLS equal columns (each column stacks its buttons
  // vertically — that's how column_set renders), so the grid stays dense and balanced.
  const perCol = Math.ceil(FEEDBACK_REASON_CODES.length / FEEDBACK_REASON_COLS);
  const columns = [];
  for (let c = 0; c < FEEDBACK_REASON_COLS; c++) {
    const slice = FEEDBACK_REASON_CODES.slice(c * perCol, (c + 1) * perCol);
    columns.push({ tag: "column", width: "weighted", weight: 1, vertical_spacing: "4px", elements: slice.map(reasonBtn) });
  }
  return [{ tag: "column_set", element_id: FEEDBACK_REASON_EID, flex_mode: "bisect", horizontal_spacing: "8px", columns }];
}

/** After a 👎, the prompt line + the reason grid (appended together). */
export function buildFeedbackReasonElements(): unknown[] {
  return [{ tag: "markdown", content: t("card.feedback.reason.prompt") }, ...buildFeedbackReasonGrid()];
}

/** Replace the whole reason grid with its disabled/chosen state (same-tag column_set PUT by the
 *  grid's own top-level element_id — reliable, vs. disabling nested children). */
export async function disableFeedbackReasonRow(cardId: string, chosen: string, sequence: number): Promise<void> {
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}/elements/${FEEDBACK_REASON_EID}`, JSON.stringify({
    element: JSON.stringify(buildFeedbackReasonGrid(chosen)[0]),
    sequence,
  }));
}

/** Append the 👍/👎 feedback row to a finalized (successful) card. Its own write so it
 *  doesn't contend with the footer/charts appends. */
export async function appendFeedbackButtons(cardId: string, sequence: number): Promise<void> {
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify(buildFeedbackButtons()),
  }));
}

/** Append the 👎 reason buttons (after a down-vote). */
export async function appendFeedbackReasons(cardId: string, sequence: number): Promise<void> {
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify(buildFeedbackReasonElements()),
  }));
}

/** After close streaming: append follow-up question buttons (clickable!).
 *  Each button carries the question in its value; when clicked, the card
 *  callback handler feeds it back as a new user message. */
export async function appendFooter(cardId: string, sequence: number, followUps: string[], actions: ActionButton[] = []): Promise<void> {
  const elements = buildFollowUpElements(followUps, actions);

  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify(elements),
  }));
}

/** Append the clarification block (prompt + option buttons) to a card. Used in
 *  place of appendFooter when the agent asked the user to disambiguate. A leading
 *  hr separates it from the (minimal) body, mirroring appendFooter's layout. */
export async function appendClarify(cardId: string, sequence: number, question: string, options: string[]): Promise<void> {
  const elements = [{ tag: "hr" }, ...buildClarifyElements(question, options)];
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify(elements),
  }));
}

/** Update a single follow-up button in place → disabled + ✓ (clicked) state.
 *  PUT /cards/{card_id}/elements/{element_id} with element as a JSON string +
 *  a strictly-increasing sequence. Best-effort (visual nicety). */
export async function disableFollowUpButton(
  cardId: string,
  elementId: string,
  question: string,
  sequence: number,
): Promise<void> {
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}/elements/${elementId}`, JSON.stringify({
    element: buildClickedButtonElement(elementId, question),
    sequence,
  }));
}
