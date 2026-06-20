/**
 * Event-stream core for the long-connection subscriber (src/index.ts).
 *
 * `lark-cli event consume im.message.receive_v1` emits one JSON object per line
 * (NDJSON) on stdout, plus `[event] ...` log lines on stderr. processEventLine
 * parses a single stdout line and, if it carries a usable IM event, dispatches
 * it to handleMessageEvent. Pure + injected — no child process here (that lives
 * in src/index.ts, which pipes consume's stdout through this).
 */

import { handleMessageEvent, type ImEvent, type InvokeFn, type HandleResult } from "./handle-event";

/** What the WSClient onError handler should do with a connection error. PURE +
 *  unit-tested so the transient/terminal/shutdown decision (which governs whether a
 *  long-running gateway survives a blip, restarts on bad creds, or cleanly stands
 *  down on redeploy) isn't untested inline logic in the entry shell. */
export type WsErrorAction = "ignore" | "retry" | "exit";

/** Classify a WSClient error into an action.
 *  - shuttingDown  → "ignore": we closed the socket on purpose (SIGTERM); the drain
 *    owns the exit, so connection-teardown noise must NOT race exit(1) ahead of it.
 *  - exceed_conn_limit (1000040350) → "retry": a stale peer still holds the slot;
 *    exiting would race a supervised restart into the SAME limit (crash-loop). Back
 *    off + re-start in-process instead.
 *  - everything else → "exit": treat as terminal (bad/revoked creds etc.) and let the
 *    supervisor restart with fresh state rather than run dark. */
export function classifyWsError(err: unknown, shuttingDown: boolean): WsErrorAction {
  if (shuttingDown) return "ignore";
  const msg = String(err);
  if (msg.includes("1000040350") || msg.includes("exceed_conn_limit")) return "retry";
  return "exit";
}

function asImEvent(data: unknown): ImEvent | null {
  if (typeof data !== "object" || data === null) return null;
  const d = data as Record<string, unknown>;
  // Minimum fields we need to act on a message event.
  if (
    typeof d.event_id === "string" &&
    typeof d.chat_id === "string" &&
    typeof d.content === "string" &&
    typeof d.message_type === "string"
  ) {
    const rawMentions = Array.isArray(d.mentions) ? d.mentions : [];
    return {
      event_id: d.event_id,
      chat_id: d.chat_id,
      chat_type: (d.chat_type as ImEvent["chat_type"]) ?? "group",
      content: d.content,
      message_id: typeof d.message_id === "string" ? d.message_id : "",
      sender_id: typeof d.sender_id === "string" ? d.sender_id : "",
      sender_type: typeof d.sender_type === "string" ? d.sender_type : "",
      message_type: d.message_type,
      mentions: rawMentions
        .map((m) => {
          const mm = m as { key?: unknown; open_id?: unknown; name?: unknown };
          return {
            key: typeof mm.key === "string" ? mm.key : "",
            open_id: typeof mm.open_id === "string" ? mm.open_id : "",
            name: typeof mm.name === "string" ? mm.name : undefined,
          };
        })
        .filter((m) => m.key || m.open_id),
      thread_id: typeof d.thread_id === "string" ? d.thread_id : undefined,
    };
  }
  return null;
}

/**
 * Parse one NDJSON line and dispatch it. Returns the handler result, or null
 * for blank lines / non-JSON noise / lines without a usable IM event.
 */
export async function processEventLine(
  rawLine: string,
  deps: { invoke: InvokeFn },
): Promise<HandleResult | null> {
  const trimmed = rawLine.trim();
  if (!trimmed || trimmed[0] !== "{") return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return null;
  }

  // lark-cli wraps the IM payload under `.data` (fall back to the root object).
  const container = parsed as Record<string, unknown>;
  const event = asImEvent(container.data) ?? asImEvent(container);
  if (!event) return null;

  return handleMessageEvent(event, deps);
}
