/**
 * Adapt the Feishu SDK's nested im.message.receive_v1 event into the flat
 * ImEvent shape the gateway core (handle-event) expects.
 *
 * The SDK (@larksuiteoapi/node-sdk WSClient) delivers the raw Feishu event:
 *   { event_id, message: { chat_id, content: '{"text":"…"}', message_id,
 *     message_type, thread_id? }, sender: { sender_id: { open_id } } }
 * lark-cli used to pre-flatten this; now we do it ourselves so we can drop
 * lark-cli entirely and run a single SDK long-connection (events + callbacks).
 */

import type { ImEvent } from "./handle-event";

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

/** A post is still a text question; media nodes are not model input.
 * Receive events normally omit the locale wrapper used when sending posts. */
function postText(value: Record<string, unknown>): string {
  const post = Array.isArray(value.content) ? value
    : Object.values(value).map(record).find((entry) => Array.isArray(entry?.content));
  if (!post || !Array.isArray(post.content)) return "";
  const lines = post.content.filter(Array.isArray).map((line: unknown[]) => line.map((item) => {
    const node = record(item);
    if (!node) return "";
    if (node.tag === "text" || node.tag === "a" || node.tag === "md" || node.tag === "code_block") {
      return typeof node.text === "string" ? node.text : "";
    }
    // Mentions are authorized through the event's mentions[], never through a
    // user-controlled node. Keep separation without leaking mention IDs.
    return node.tag === "at" ? " " : "";
  }).join(""));
  return [typeof post.title === "string" ? post.title : "", ...lines]
    .filter((line) => line.trim()).join("\n");
}

export function sdkEventToImEvent(data: unknown): ImEvent | null {
  if (typeof data !== "object" || data === null) return null;
  const d = data as Record<string, unknown>;
  const message = d.message as Record<string, unknown> | undefined;
  if (!message || typeof message.chat_id !== "string") return null;

  // content is a JSON string; posts contain rows of rich-text nodes.
  let text = "";
  if (typeof message.content === "string") {
    try {
      const parsed = record(JSON.parse(message.content));
      if (parsed && message.message_type === "post") text = postText(parsed);
      else if (typeof parsed?.text === "string") text = parsed.text;
    } catch { /* Malformed content leaves an empty question. */ }
  }

  const sender = d.sender as
    | { sender_id?: { open_id?: string }; sender_type?: string }
    | undefined;

  // mentions[]: each { key:"@_user_N", id:{open_id}, name } — `key` is the inline
  // placeholder in content.text; id.open_id resolves who was @-mentioned. Used to
  // gate group answers (was the bot @'d?) and to strip the tokens from the prompt.
  const rawMentions = Array.isArray(message.mentions) ? message.mentions : [];
  const mentions = rawMentions
    .map((m) => {
      const mm = m as { key?: unknown; name?: unknown; id?: { open_id?: unknown } };
      return {
        key: typeof mm.key === "string" ? mm.key : "",
        open_id: typeof mm.id?.open_id === "string" ? mm.id.open_id : "",
        name: typeof mm.name === "string" ? mm.name : undefined,
      };
    })
    .filter((m) => m.key || m.open_id);

  return {
    event_id: typeof d.event_id === "string" ? d.event_id : "",
    chat_id: message.chat_id,
    chat_type: (message.chat_type as ImEvent["chat_type"]) ?? "group",
    content: text,
    message_id: typeof message.message_id === "string" ? message.message_id : "",
    sender_id: sender?.sender_id?.open_id ?? "",
    sender_type: typeof sender?.sender_type === "string" ? sender.sender_type : "",
    message_type: typeof message.message_type === "string" ? message.message_type : "",
    mentions,
    thread_id: typeof message.thread_id === "string" ? message.thread_id : undefined,
    // parent_id is set when this message REPLIES to another (Feishu 引用/回复). It
    // lets a typed reply to a bot answer-card continue that conversation: the
    // gateway looks parent_id up in the card registry and replays the prior chain
    // as context (same mechanism as the follow-up button).
    parent_id: typeof message.parent_id === "string" ? message.parent_id : undefined,
  };
}
