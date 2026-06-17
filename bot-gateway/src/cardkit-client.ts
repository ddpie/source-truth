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

export function buildCreateCardBody(opts?: { summary?: string }): string {
  // summary.content customizes the chat-list preview (default would be "[生成中...]").
  const summary = opts?.summary ? `💬 ${opts.summary.slice(0, 40)}` : "source-truth 正在回答…";
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
      title: { tag: "plain_text", content: "正在思考…" },
      template: "blue",
      icon: { tag: "standard_icon", token: "ai-lib_outlined" },
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
export async function createCard(summary?: string): Promise<string> {
  const resp = (await larkApi("POST", "/open-apis/cardkit/v1/cards", buildCreateCardBody({ summary }))) as {
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

/** After close streaming: update header to "完成" (green) via full card PUT.
 *  PUT body = { card: { type, data }, sequence } — full replace, must carry body. */
export async function finalizeCard(
  cardId: string,
  conclusion: string,
  reasoning: string,
  sequence: number,
): Promise<void> {
  const card = {
    schema: "2.0",
    config: { update_multi: true },
    header: {
      title: { tag: "plain_text", content: "回答完成" },
      template: "green",
      icon: { tag: "standard_icon", token: "ai-lib_outlined" },
    },
    body: {
      elements: [
        { tag: "markdown", content: conclusion, element_id: "conclusion" },
        // Reasoning / evidence collapsed by default (animated chevron on expand).
        ...(reasoning
          ? [{
              tag: "collapsible_panel",
              expanded: false,
              background_color: "grey",
              padding: "8px 8px 8px 8px",
              border: { color: "grey", corner_radius: "5px" },
              vertical_spacing: "8px",
              header: {
                title: { tag: "markdown", content: "**🔍 取证过程**" },
                vertical_align: "center",
                padding: "4px 0px 4px 8px",
                width: "auto_when_fold",
                icon: { tag: "standard_icon", token: "down-small-ccm_outlined", color: "grey", size: "16px 16px" },
                icon_position: "follow_text",
                icon_expanded_angle: -180,
              },
              elements: [{ tag: "markdown", content: reasoning }],
            }]
          : []),
      ],
    },
  };
  const body = JSON.stringify({ card: { type: "card_json", data: JSON.stringify(card) }, sequence });
  await larkApi("PUT", `/open-apis/cardkit/v1/cards/${cardId}`, body);
}

/** After close streaming: append a subtle follow-up hint.
 *  Buttons removed for now — card action callbacks require a webhook endpoint
 *  which isn't set up yet; dead buttons are worse than no buttons. The user
 *  can continue asking in the same conversation (session-map reuses context). */
export async function appendFooter(cardId: string, sequence: number): Promise<void> {
  const elements = [
    { tag: "hr" },
    { tag: "markdown", content: "💡 直接在会话里继续追问即可，上下文会延续。如需转研发，请 @相关同学。" },
  ];
  await larkApi("POST", `/open-apis/cardkit/v1/cards/${cardId}/elements`, JSON.stringify({
    type: "append",
    sequence,
    elements: JSON.stringify(elements),
  }));
}
