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

import { spawn } from "node:child_process";

// ── pure request builders (unit-tested) ──────────────────────────────────────

export function buildCreateCardBody(opts?: { summary?: string; followUp?: boolean }): string {
  // summary.content customizes the chat-list preview (default would be "[生成中...]").
  const summary = opts?.summary ? `💬 ${opts.summary.slice(0, 40)}` : "source-truth 正在回答…";
  // Follow-up cards (from a clicked button) get a distinct header so the chat
  // history clearly shows "this card answers a follow-up question".
  const title = opts?.followUp ? "↳ 正在追问…" : "正在思考…";
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
    body: { elements: [{ tag: "markdown", content: "正在分析…", element_id: "conclusion" }] },
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

// ── lark-cli runners (integration) ───────────────────────────────────────────

function larkApi(method: string, path: string, data: string): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const child = spawn("lark-cli", ["api", method, path, "--as", "bot", "--data", data], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("exit", (code) => {
      if (code !== 0) return reject(new Error(`lark-cli api ${method} ${path} exited ${code}: ${err}`));
      try {
        const json = JSON.parse(out) as { code?: number; msg?: string };
        if (json.code !== undefined && json.code !== 0) {
          return reject(new Error(`CardKit ${path} code ${json.code}: ${json.msg}`));
        }
        resolve(json);
      } catch (e) {
        reject(new Error(`bad CardKit response: ${out.slice(0, 200)} (${String(e)})`));
      }
    });
    child.on("error", reject);
  });
}

/** Create a streaming card; returns its card_id. summary = chat-list preview. */
export async function createCard(summary?: string, followUp?: boolean): Promise<string> {
  const resp = (await larkApi("POST", "/open-apis/cardkit/v1/cards", buildCreateCardBody({ summary, followUp }))) as {
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
export function finalizeTitle(followUp?: boolean, aborted?: boolean): string {
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

/** Append the live reasoning panel (expanded) to the card — once, when the
 *  first step appears. Inserted before the conclusion via partial-update API. */
export async function appendReasoningPanel(cardId: string, steps: string[], sequence: number): Promise<void> {
  const panel = buildReasoningPanel(steps, true);
  if (!panel) return;
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "insert_before",
    target_element_id: "conclusion",
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

/** After close streaming: update header to "完成" (green) via full card PUT.
 *  PUT body = { card: { type, data }, sequence } — full replace, must carry body. */
export async function finalizeCard(
  cardId: string,
  conclusion: string,
  steps: string[],
  sequence: number,
  followUp?: boolean,
  aborted?: boolean,
): Promise<void> {
  const panel = buildReasoningPanel(steps, false);
  const card = {
    schema: "2.0",
    config: { update_multi: true },
    header: {
      title: { tag: "plain_text", content: finalizeTitle(followUp, aborted) },
      template: aborted ? "grey" : "green",
    },
    body: {
      elements: [
        { tag: "markdown", content: conclusion, element_id: "conclusion" },
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
