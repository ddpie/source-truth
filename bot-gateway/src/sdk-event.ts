/**
 * Adapt the Feishu SDK's nested im.message.receive_v1 event into the flat
 * ImEvent shape the gateway core (index-core/handle-event) expects.
 *
 * The SDK (@larksuiteoapi/node-sdk WSClient) delivers the raw Feishu event:
 *   { event_id, message: { chat_id, content: '{"text":"…"}', message_id,
 *     message_type, thread_id? }, sender: { sender_id: { open_id } } }
 * lark-cli used to pre-flatten this; now we do it ourselves so we can drop
 * lark-cli entirely and run a single SDK long-connection (events + callbacks).
 */

import type { ImEvent } from "./handle-event";

export function sdkEventToImEvent(data: unknown): ImEvent | null {
  if (typeof data !== "object" || data === null) return null;
  const d = data as Record<string, unknown>;
  const message = d.message as Record<string, unknown> | undefined;
  if (!message || typeof message.chat_id !== "string") return null;

  // content is a JSON string; for text messages it's {"text":"…"}.
  let text = "";
  if (typeof message.content === "string") {
    try {
      const parsed = JSON.parse(message.content) as { text?: string };
      if (typeof parsed.text === "string") text = parsed.text;
    } catch { /* non-text content (image/file/post) → leave empty */ }
  }

  const sender = d.sender as { sender_id?: { open_id?: string } } | undefined;

  return {
    event_id: typeof d.event_id === "string" ? d.event_id : "",
    chat_id: message.chat_id,
    chat_type: (message.chat_type as ImEvent["chat_type"]) ?? "group",
    content: text,
    message_id: typeof message.message_id === "string" ? message.message_id : "",
    sender_id: sender?.sender_id?.open_id ?? "",
    message_type: typeof message.message_type === "string" ? message.message_type : "",
    thread_id: typeof message.thread_id === "string" ? message.thread_id : undefined,
  };
}
