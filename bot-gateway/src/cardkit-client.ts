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

// ── pure request builders (unit-tested) ──────────────────────────────────────

export function buildCreateCardBody(opts?: { summary?: string; followUp?: boolean; question?: string }): string {
  // summary.content customizes the chat-list preview (default would be "[生成中...]").
  const summary = opts?.summary ? `💬 ${opts.summary.slice(0, 40)}` : "source-truth 正在回答…";
  // Follow-up cards (from a clicked button) get a distinct header so the chat
  // history clearly shows "this card answers a follow-up question".
  const title = opts?.followUp ? "↳ 正在追问…" : "正在思考…";
  // Echo the user's question at the TOP of the card body (a quoted line), so the
  // card is self-contained — the reader sees WHAT was asked without scrolling up
  // the chat. element_id="question" so it stays put through streaming/finalize.
  const elements: unknown[] = [];
  const q = (opts?.question ?? "").trim();
  if (q) {
    elements.push({ tag: "markdown", content: `**❓ ${q}**`, element_id: "question" });
    elements.push({ tag: "hr" });
  }
  elements.push({ tag: "markdown", content: "正在分析…", element_id: "conclusion" });
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

/** Full-card PUT body that swaps the header (title + color) mid-stream while
 *  keeping streaming_mode on and re-carrying the current conclusion text — a
 *  full PUT replaces the whole body, so the in-progress text must be included
 *  or it would be wiped. Verified: streaming text survives a full PUT. */
export function buildStageBody(title: string, template: string, conclusion: string, sequence: number): string {
  const card = {
    schema: "2.0",
    config: {
      update_multi: true,
      streaming_mode: true,
      streaming_config: {
        print_frequency_ms: { default: 70 },
        print_step: { default: 1 },
        print_strategy: "fast",
      },
    },
    header: { title: { tag: "plain_text", content: title }, template },
    body: { elements: [{ tag: "markdown", content: conclusion, element_id: "conclusion" }] },
  };
  return JSON.stringify({ card: { type: "card_json", data: JSON.stringify(card) }, sequence });
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

/** Change the card's stage (header title + color) mid-stream via full PUT. */
export async function updateStage(
  cardId: string,
  title: string,
  template: string,
  conclusion: string,
  sequence: number,
): Promise<void> {
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}`, buildStageBody(title, template, conclusion, sequence));
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
export async function createCard(summary?: string, followUp?: boolean, question?: string): Promise<string> {
  const resp = (await larkApi("POST", "/open-apis/cardkit/v1/cards", buildCreateCardBody({ summary, followUp, question }))) as {
    data: { card_id: string };
  };
  return resp.data.card_id;
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
 *  history still shows a finished follow-up card as a follow-up. */
export function finalizeTitle(followUp?: boolean, aborted?: boolean, failed?: boolean): string {
  if (failed) return "⚠️ 查询失败";
  if (aborted) return "⏹ 已停止";
  return followUp ? "↳ 追问 · 已回答" : "回答完成";
}

/** A "⏹ 停止" button shown during streaming. value.card_id lets the click
 *  callback route the abort to the right in-flight agent stream. */
export function buildStopButton(cardId: string): unknown {
  return {
    tag: "button",
    element_id: "stopbtn",
    text: { tag: "plain_text", content: "⏹ 停止" },
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
  const heading = expanded ? "**🔍 分析中…**" : "**🔍 分析过程（点开看依据）**";
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
 *  layout matches finalizeCard's order [conclusion, evidence, reasoning]. If the
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

/** Wrap VChart specs (extracted from the agent's ```chart blocks) as CardKit
 *  chart components. The agent builds specs from real config-table numbers it
 *  read; the gateway only transports them. */
export function buildChartElements(specs: Array<{ type: string; [k: string]: unknown }>): unknown[] {
  return specs.map((spec, i) => ({
    tag: "chart",
    element_id: `chart_${i}`,
    chart_spec: spec,
  }));
}

/** Append data charts to the card (after the conclusion, before the footer). */
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
 *  / line numbers). Folded by default so the non-technical reader sees only the
 *  business answer; a dev expands it to verify. null when there's no evidence. */
export function buildEvidencePanel(evidence: string): unknown {
  if (!evidence.trim()) return null;
  return {
    tag: "collapsible_panel",
    element_id: "evidence",
    expanded: false,
    background_color: "grey",
    padding: "8px 8px 8px 8px",
    border: { color: "grey", corner_radius: "5px" },
    vertical_spacing: "8px",
    header: {
      title: { tag: "markdown", content: "**📎 供研发复核（点开看代码出处）**" },
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
): Promise<void> {
  const panel = buildReasoningPanel(steps, false);
  const evidencePanel = buildEvidencePanel(evidence ?? "");
  // Re-include the echoed question at the top (the full-PUT rebuilds the whole
  // body, so it'd be wiped otherwise — must match the streaming layout).
  const q = (question ?? "").trim();
  const questionEls = q
    ? [{ tag: "markdown", content: `**❓ ${q}**`, element_id: "question" }, { tag: "hr" }]
    : [];
  const card = {
    schema: "2.0",
    config: { update_multi: true },
    header: {
      title: { tag: "plain_text", content: finalizeTitle(followUp, aborted, failed) },
      template: failed ? "red" : aborted ? "grey" : "green",
    },
    body: {
      elements: [
        ...questionEls,
        { tag: "markdown", content: conclusion, element_id: "conclusion" },
        ...(evidencePanel ? [evidencePanel] : []),
        ...(panel ? [panel] : []),
      ],
    },
  };
  const body = JSON.stringify({ card: { type: "card_json", data: JSON.stringify(card) }, sequence });
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}`, body);
}

/** Build the footer elements: a divider + clickable follow-up buttons. Each
 *  button gets a stable element_id (followup_N) echoed in its value so the
 *  click callback can disable exactly the button that was pressed. */
export function buildFollowUpElements(followUps: string[]): unknown[] {
  const elements: unknown[] = [{ tag: "hr" }];
  if (followUps.length > 0) {
    elements.push({ tag: "markdown", content: "💡 **继续追问：**" });
    followUps.slice(0, 3).forEach((q, i) => {
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
  } else {
    elements.push({ tag: "markdown", content: "💡 直接在会话里继续追问即可，上下文会延续。" });
  }
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

/** After close streaming: append follow-up question buttons (clickable!).
 *  Each button carries the question in its value; when clicked, the card
 *  callback handler feeds it back as a new user message. */
export async function appendFooter(cardId: string, sequence: number, followUps: string[]): Promise<void> {
  const elements = buildFollowUpElements(followUps);

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
