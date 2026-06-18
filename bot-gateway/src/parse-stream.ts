/**
 * Shared parsing of the agent's SSE stream into narration segments + the final
 * conclusion. This is the SINGLE source of truth for that classification —
 * sigv4.invokeRuntimeStreaming uses the same accumulator for its incremental
 * parse, so the live path and any whole-string parse can never diverge.
 *
 * The runtime streams newline-delimited `data: {...}` events. Each event's
 * content[0] is one of:
 *   - { text: "…" }            → a prose block (narration OR the conclusion)
 *   - { thinking: "…" }        → internal reasoning (ignored)
 *   - { id, name, input }      → tool_use (ignored as content, but it GATES text
 *                                blocks: a text after a tool starts a new block)
 *   - { tool_use_id, content } → tool_result (ignored)
 *
 * Tool-gating: the agent emits a short narration, runs a tool, narrates again,
 * etc., then a final answer. Consecutive text items WITHOUT an intervening
 * tool_use belong to the SAME logical block (append); a text AFTER a tool_use
 * starts a NEW block. So every block except the last is a narration; the last
 * is the conclusion. Tool names / output never reach the user.
 */

export interface ParsedStream {
  narrations: string[];
  conclusion: string;
  /** Stream-level backend failure, if any (null when the run completed cleanly). */
  error: string | null;
}

/** Mutable accumulator so the incremental (sigv4) and whole-string parsers share logic. */
export interface StreamState {
  texts: string[];
  /** True when a tool_use arrived after the latest text → next text is a new block. */
  sawToolAfterLastText: boolean;
  /** First backend failure surfaced in the stream (null if none). A non-null
   *  value means the answer is NOT trustworthy and must be shown as an error,
   *  never as a completed conclusion. */
  error: string | null;
}

export function newStreamState(): StreamState {
  return { texts: [], sawToolAfterLastText: true /* first text starts a fresh block */, error: null };
}

/**
 * Detect a STREAM-LEVEL failure event (not a per-tool result).
 *
 * The AgentCore runtime emits a transport error as a top-level
 * `{error, error_type, message}` object over the already-open HTTP 200 stream
 * (bedrock_agentcore/runtime/app.py _stream_with_error_handling). The SDK's
 * final ResultMessage reports a run-level failure via a top-level `is_error:
 * true` (with subtype/result). BOTH have NO `content` array.
 *
 * Crucially, a routine per-tool permission denial (common under the read-only
 * `dontAsk` boundary) is an `is_error: true` item INSIDE `content[]` — that is
 * NOT a stream failure and must be ignored here, or every healthy run with a
 * denied write attempt would be misreported as an error. The `content` array
 * guard is what separates the two.
 */
export function detectEventError(evt: Record<string, unknown>): string | null {
  if (Array.isArray(evt.content)) return null; // per-tool result item, not a stream error
  if (typeof evt.error === "string" && evt.error && typeof evt.error_type === "string") {
    return `${evt.error_type}: ${evt.error}`;
  }
  if (evt.is_error === true) {
    if (typeof evt.result === "string" && evt.result) return evt.result;
    return typeof evt.subtype === "string" && evt.subtype ? `result error (${evt.subtype})` : "result error";
  }
  return null;
}

/** Fold one whole parsed event into the state: capture a stream-level error,
 *  then fold its content[0] (tool-gated). Single entry point so the live
 *  (sigv4) and whole-string parsers detect errors identically. */
export function applyEvent(state: StreamState, evt: Record<string, unknown>): void {
  if (state.error === null) {
    const err = detectEventError(evt);
    if (err !== null) state.error = err;
  }
  applyContentItem(state, (evt.content as Array<Record<string, unknown>> | undefined)?.[0]);
}

/** Fold one already-parsed event's content[0] into the state (tool-gated). */
export function applyContentItem(state: StreamState, item: Record<string, unknown> | undefined): void {
  if (!item) return;
  if (typeof item.text === "string") {
    if (state.sawToolAfterLastText || state.texts.length === 0) {
      state.texts.push(item.text);
      state.sawToolAfterLastText = false;
    } else {
      // Same logical block continued: append (NOT replace — replacing drops the
      // earlier chunk and corrupts the output).
      state.texts[state.texts.length - 1] += item.text;
    }
  } else if (typeof item.name === "string" && "input" in item) {
    // tool_use: the preceding text block is now a finished narration.
    state.sawToolAfterLastText = true;
  }
  // thinking / tool_result: ignored.
}

/** texts[] → {narrations (all but last), conclusion (last)}. */
export function splitTexts(texts: string[], error: string | null = null): ParsedStream {
  if (texts.length === 0) return { narrations: [], conclusion: "", error };
  return { narrations: texts.slice(0, -1), conclusion: texts[texts.length - 1], error };
}

/** Parse a whole captured SSE string (used by tests / non-streaming callers). */
export function parseAgentStream(raw: string): ParsedStream {
  const state = newStreamState();
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("data:")) continue;
    const jsonStr = trimmed.slice(5).trim();
    if (!jsonStr.startsWith("{")) continue;
    let evt: Record<string, unknown>;
    try {
      evt = JSON.parse(jsonStr);
    } catch {
      continue;
    }
    applyEvent(state, evt);
  }
  return splitTexts(state.texts, state.error);
}
