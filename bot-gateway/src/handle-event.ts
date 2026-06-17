/**
 * IM-event core for the gateway.
 *
 * Consumes a normalized Feishu im.message.receive_v1 event (the shape lark-cli
 * delivers), dedups re-deliveries, routes to a runtimeSessionId, and invokes
 * the agent. The agent invoke is injected so this is testable without AWS or a
 * live Feishu long-connection.
 *
 * The real long-connection subscriber (src/index.ts) feeds events here; that
 * piece needs bot identity + IM scopes and is wired separately.
 */

import { isDuplicate } from "./dedup";
import { getSessionId } from "./session-map";
import { ackWithReaction } from "./reaction";

/** Normalized im.message.receive_v1 (subset we use). Matches lark-cli output. */
export interface ImEvent {
  event_id: string;
  chat_id: string;
  chat_type: "p2p" | "group";
  content: string;
  message_id: string;
  sender_id: string;
  message_type: string;
  thread_id?: string;
}

/** Invoke the agent for a session; returns the answer text. */
export type InvokeFn = (sessionId: string, prompt: string) => Promise<string>;

export interface HandleResult {
  handled: boolean;
  answer?: string;
  sessionId?: string;
  messageId?: string;
  reason?: "duplicate" | "unsupported_type" | "empty";
}

/** Strip a leading @-mention token (e.g. "@_user_1 ...") from card-rendered text. */
function stripMention(text: string): string {
  return text.replace(/^@\S+\s+/, "").trim();
}

export async function handleMessageEvent(
  event: ImEvent,
  deps: { invoke: InvokeFn },
): Promise<HandleResult> {
  // 1. Dedup — Feishu re-delivers events; event_id is the idempotency key.
  if (isDuplicate(event.event_id)) {
    return { handled: false, reason: "duplicate" };
  }

  // 2. Only text messages are answered in MVP.
  if (event.message_type !== "text") {
    return { handled: false, reason: "unsupported_type" };
  }

  const prompt = stripMention(event.content);
  if (!prompt) {
    return { handled: false, reason: "empty" };
  }

  // 3. Immediately react so the user knows we're on it (fire-and-forget).
  if (event.message_id) ackWithReaction(event.message_id);

  // 4. Route to a stable session (same chat+thread reuses one warm microVM).
  const sessionId = getSessionId(event.chat_id, event.thread_id);

  // 4. Invoke the agent.
  const answer = await deps.invoke(sessionId, prompt);
  return { handled: true, answer, sessionId, messageId: event.message_id };
}
