/**
 * Parse the agent's raw SSE stream into narration segments + final conclusion.
 *
 * The runtime streams newline-delimited `data: {...}` events. Each event's
 * content[0] is one of:
 *   - { text: "…" }            → a prose block (narration OR the conclusion)
 *   - { thinking: "…" }        → internal reasoning (ignored)
 *   - { id, name, input }      → tool_use (ignored — narration already says it)
 *   - { tool_use_id, content } → tool_result (ignored)
 *
 * The agent emits a short human narration before each action, then a final
 * answer. So every text block EXCEPT the last is a narration ("正在定位…",
 * "换个关键词再搜"), and the LAST text block is the conclusion. We surface
 * narrations live in the 分析过程 panel and the conclusion as the answer; tool
 * names / output never reach the user.
 *
 * Tolerant: a `text` block may arrive incrementally across events with the same
 * message_id, but in practice each text block is delivered whole; we treat each
 * text content item as one segment.
 */

export interface ParsedStream {
  narrations: string[];
  conclusion: string;
}

export function parseAgentStream(raw: string): ParsedStream {
  const texts: string[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("data:")) continue;
    const jsonStr = trimmed.slice(5).trim();
    if (!jsonStr.startsWith("{")) continue;
    let evt: { content?: Array<Record<string, unknown>> };
    try {
      evt = JSON.parse(jsonStr);
    } catch {
      continue;
    }
    const item = evt.content?.[0];
    if (item && typeof item.text === "string") {
      texts.push(item.text);
    }
  }
  if (texts.length === 0) return { narrations: [], conclusion: "" };
  return { narrations: texts.slice(0, -1), conclusion: texts[texts.length - 1] };
}
