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
  /** Total tool_use blocks seen (codegraph calls + Read/Glob/Grep), and a per-
   *  tool-name tally. The gateway already sees every tool_use here (tool-gating),
   *  so counting them is free and answers the key issue-#2 question: was a slow
   *  run "few deep model turns" or "many tool round-trips"? — different fixes. */
  toolCalls: number;
  toolCallsByName: Record<string, number>;
  /** Count of tool RESULTS that came back with is_error:true INSIDE content[] — a
   *  per-tool failure (codegraph error, a read of a missing path, a denied write under
   *  the read-only dontAsk boundary, …). This is DISTINCT from state.error (a stream-
   *  LEVEL failure that invalidates the whole answer): a healthy run can still have a few
   *  recovered tool errors. Telemetry only (toolErrorCount on answer_completed) — it does
   *  NOT flip the answer to an error. A high ratio vs toolCalls flags a flaky retrieval /
   *  bad tool args pattern worth investigating. */
  toolErrors: number;
  /** True once we've seen a partial-message StreamEvent (token deltas). When the
   *  agent runs with include_partial_messages, the conclusion streams token-by-
   *  token via content_block_delta events INSTEAD of arriving as one complete
   *  text block at the end ("freezes then dumps" → smooth typewriter). Once we're
   *  in delta mode, the full AssistantMessage that closes each turn is redundant
   *  with the accumulated deltas, so we stop taking text from it (would double).
   *  Auto-detected so this is fully backward-compatible: a stream WITHOUT partial
   *  messages never flips this and uses the old full-message path unchanged. */
  sawStreamEvent: boolean;
  /** True once the terminal ResultMessage arrived (the SDK's run-completion event:
   *  no `content` array + a top-level subtype/result/stop_reason). The stream is
   *  only TRUSTWORTHY-complete when this is set. If the read loop ends (done) WITHOUT
   *  it, the connection was cut mid-run (NAT/LB idle-timeout, microVM killed) and the
   *  accumulated text is a TRUNCATED answer that must NOT be shown as a finished
   *  conclusion — the caller flips it to an error. */
  sawResult: boolean;
  /** The agent-loop turn count from the terminal ResultMessage's `num_turns` (one model
   *  ↔ tool round-trip = one turn). 0 until the terminal message arrives. Telemetry only
   *  (turnCount on answer_completed): together with toolCalls it disambiguates a slow run —
   *  "few deep model turns" (reasoning-heavy) vs "many tool round-trips" (retrieval-heavy) —
   *  which have different fixes. The gateway sees this directly on the SSE stream (the
   *  ResultMessage carries num_turns), so NO agent-side change / image rebuild is needed —
   *  the telemetry plan's "⚠️ needs a path" note for num_turns is outdated. */
  numTurns: number;
  protocol?: "legacy" | "source-truth";
  normalized?: { runId: string; seq: number; messages: Record<string, number>; tools: Map<string, boolean> };
}

export function newStreamState(): StreamState {
  return { texts: [], sawToolAfterLastText: true /* first text starts a fresh block */, error: null, toolCalls: 0, toolCallsByName: {}, toolErrors: 0, sawStreamEvent: false, sawResult: false, numTurns: 0 };
}

/** Tally one tool_use by name (perf accounting). */
function countTool(state: StreamState, name: unknown): void {
  state.toolCalls++;
  const key = typeof name === "string" && name ? name : "(unknown)";
  state.toolCallsByName[key] = (state.toolCallsByName[key] ?? 0) + 1;
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
  if (typeof evt.error === "string" && evt.error) {
    // error_type is OPTIONAL: a stream-level error event may carry only `error`
    // (no error_type). Requiring error_type meant such an error was SILENTLY dropped
    // here and only later mis-attributed as "stream truncated" by the truncation
    // guard — or, if a normal result happened to follow, swallowed entirely
    // (a partial answer shown as 回答完成). Flag it either way (cross-review).
    return typeof evt.error_type === "string" && evt.error_type
      ? `${evt.error_type}: ${evt.error}`
      : evt.error;
  }
  if (evt.is_error === true) {
    if (typeof evt.result === "string" && evt.result) return evt.result;
    return typeof evt.subtype === "string" && evt.subtype ? `result error (${evt.subtype})` : "result error";
  }
  return null;
}

/** Fold one whole parsed event into the state: capture a stream-level error,
 *  then fold either a partial-message token delta (StreamEvent) OR a complete
 *  message's content[0] (tool-gated). Single entry point so the live (sigv4) and
 *  whole-string parsers behave identically. */
export function applyEvent(state: StreamState, evt: Record<string, unknown>): void {
  // AgentCore transport errors have no protocol envelope, including after the
  // SDK's final event. Preserve the first error before enforcing stream mode.
  const transportError = detectEventError(evt);
  if (transportError !== null) state.error ??= transportError;
  if (evt.protocol === "source-truth") {
    if (state.protocol === "legacy") {
      state.error ??= "mixed agent stream protocol";
      return;
    }
    state.protocol = "source-truth";
    applyNormalizedEvent(state, evt);
    return;
  }
  if (state.protocol === "source-truth" || evt.protocol !== undefined) {
    state.error ??= "mixed or unknown agent stream protocol";
    return;
  }
  state.protocol = "legacy";
  if (state.error === null) {
    const err = detectEventError(evt);
    if (err !== null) state.error = err;
  }
  // Tally per-tool failures (is_error:true items INSIDE content[]). These are NOT stream
  // errors (detectEventError correctly ignores them) — a healthy run can recover from a
  // few. Counted across ALL content items (a message can carry multiple tool_results), so
  // it's independent of the content[0] tool-gating below. Telemetry only.
  if (Array.isArray(evt.content)) {
    for (const item of evt.content as Array<Record<string, unknown>>) {
      if (item && typeof item === "object" && item.is_error === true && item.tool_use_id !== undefined) {
        state.toolErrors++;
      }
    }
  }
  // Terminal ResultMessage = clean run completion. It has NO `content` array and
  // carries a RUN-SUMMARY field (num_turns / result / is_error / a real
  // stop_reason). We require seeing this before trusting the stream as complete;
  // without it, a `done` read means the connection was cut mid-run and the text is
  // truncated. Key off the run-summary fields, NOT a bare `subtype`: the SDK's
  // system INIT message is also `{subtype:"init", data:{…}}` with no content array,
  // and an intermediate message carries stop_reason:null (typeof null !== "string"
  // so it's correctly ignored). detectEventError already flags the is_error:true
  // variant; this also catches the is_error:false success ResultMessage.
  if (!Array.isArray(evt.content) &&
      (typeof evt.num_turns === "number" || evt.result != null ||
       typeof evt.is_error === "boolean" || typeof evt.stop_reason === "string")) {
    // `evt.result != null` (not a bare `"result" in evt`): a non-terminal event that
    // happens to carry result:null/undefined must NOT be mistaken for the terminal
    // ResultMessage and prematurely satisfy the truncation guard — which would let a
    // later-truncated stream render as a finished answer. Matches the type-checked
    // strictness of the other three predicates (cross-review).
    state.sawResult = true;
    // Capture the agent-loop turn count off the SAME terminal ResultMessage (telemetry).
    // Only on the terminal message (guarded by the run-summary predicate above) so an
    // intermediate event can't overwrite it; ignore a non-number/negative.
    if (typeof evt.num_turns === "number" && evt.num_turns >= 0) {
      state.numTurns = evt.num_turns;
    }
  }
  // Partial-message path: when the agent runs with include_partial_messages, the
  // AgentCore SDK yields StreamEvent objects — serialized as {uuid, session_id,
  // event:{...raw Anthropic stream event...}, parent_tool_use_id}. The raw event
  // carries token deltas, so we fold those and skip the redundant full message.
  if (typeof evt.event === "object" && evt.event !== null && "session_id" in evt) {
    applyStreamEvent(state, evt.event as Record<string, unknown>);
    return;
  }
  // Once we've started consuming deltas, the closing AssistantMessage for a turn
  // repeats the same text we already accumulated — skip it so text isn't doubled.
  if (state.sawStreamEvent && Array.isArray(evt.content)) return;
  applyContentItem(state, (evt.content as Array<Record<string, unknown>> | undefined)?.[0]);
}

/** Both SDKs use this contract. Keep the legacy parser during rolling upgrades. */
function applyNormalizedEvent(state: StreamState, evt: Record<string, unknown>): void {
  if (evt.version !== 1 || typeof evt.runId !== "string" || !evt.runId.trim() || !Number.isSafeInteger(evt.seq)) {
    state.error ??= "invalid agent stream protocol";
    return;
  }
  state.normalized ??= { runId: evt.runId, seq: 0, messages: Object.create(null) as Record<string, number>, tools: new Map() };
  const stream = state.normalized;
  if (stream.runId !== evt.runId || evt.seq !== stream.seq + 1 || state.sawResult) {
    state.error ??= "agent stream sequence mismatch";
    return;
  }
  stream.seq = evt.seq as number;
  if (evt.type === "text_delta" && typeof evt.messageId === "string" && evt.messageId && typeof evt.text === "string") {
    if (!evt.text) return;
    let index = stream.messages[evt.messageId];
    if (index === undefined) {
      index = state.texts.length;
      stream.messages[evt.messageId] = index;
      state.texts.push("");
    } else if (index !== state.texts.length - 1 || state.sawToolAfterLastText) {
      state.error ??= "agent stream message order mismatch";
      return;
    }
    state.texts[index] += evt.text;
    state.sawToolAfterLastText = false;
  } else if (evt.type === "tool_started") {
    if (typeof evt.toolId !== "string" || !evt.toolId || stream.tools.has(evt.toolId) ||
        typeof evt.name !== "string" || !evt.name.trim()) {
      state.error ??= "invalid agent stream tool start";
      return;
    }
    stream.tools.set(evt.toolId, false);
    state.sawToolAfterLastText = true;
    countTool(state, evt.name);
  } else if (evt.type === "tool_finished") {
    if (typeof evt.toolId !== "string" || stream.tools.get(evt.toolId) !== false ||
        typeof evt.isError !== "boolean") {
      state.error ??= "invalid agent stream tool completion";
      return;
    }
    stream.tools.set(evt.toolId, true);
    if (evt.isError === true) state.toolErrors++;
  } else if (evt.type === "run_completed" || evt.type === "run_failed") {
    state.sawResult = true;
    if (typeof evt.numTurns === "number" && Number.isSafeInteger(evt.numTurns) && evt.numTurns >= 0) {
      state.numTurns = evt.numTurns;
    }
    if (evt.type === "run_failed") {
      state.error ??= typeof evt.error === "string" && evt.error.trim() ? evt.error : "agent run failed";
    } else if ([...stream.tools.values()].some((finished) => !finished)) {
      state.error ??= "agent run completed before tools finished";
    } else if (typeof evt.text === "string" && evt.text.trim()) {
      // The final SDK snapshot replaces the last streamed answer, never doubles it.
      if (state.texts.length === 0 || state.sawToolAfterLastText) state.texts.push(evt.text);
      else state.texts[state.texts.length - 1] = evt.text;
    } else {
      state.error ??= "agent run completed without final text";
    }
  } else {
    state.error ??= "unknown agent stream event";
  }
}

/** Fold one raw Anthropic stream event (from a StreamEvent's `event` field) into
 *  the state. We care about three shapes:
 *   - content_block_start {index, content_block:{type:"tool_use"|"text"}} → a
 *     tool_use block opening means the preceding text block is a finished
 *     narration (same tool-gating as the full-message path); a text block
 *     opening after a tool starts a new logical block.
 *   - content_block_delta {delta:{type:"text_delta", text}} → append tokens to
 *     the current text block (the streaming typewriter).
 *  thinking deltas / message_start / message_delta / *_stop are ignored. */
export function applyStreamEvent(state: StreamState, raw: Record<string, unknown>): void {
  const type = raw.type;
  if (type === "content_block_start") {
    const block = raw.content_block as Record<string, unknown> | undefined;
    const blockType = block?.type;
    if (blockType === "tool_use") {
      // A tool started → the current text block is now a finished narration.
      // Mark partial mode active even when a turn OPENS with a tool (no narration
      // first): otherwise sawStreamEvent stays false, the closing full
      // AssistantMessage isn't deduped by applyEvent's guard, and this tool_use
      // gets counted a SECOND time → corrupted toolCalls telemetry.
      state.sawStreamEvent = true;
      state.sawToolAfterLastText = true;
      countTool(state, block?.name);
    } else if (blockType === "text") {
      // A new text block opened. Mark stream-event mode, but DON'T eagerly push("")
      // here — the content_block_delta branch below lazily creates the block on the
      // first text_delta (respecting the tool-boundary flag). Pushing on start
      // created a phantom EMPTY block when a text block is opened but never filled
      // (model opens a final text block after a last tool_use, then stops): that
      // empty trailing block became splitTexts' "conclusion" → blank card, real
      // answer demoted to the 分析过程 panel (cross-review HIGH). Just record the mode.
      state.sawStreamEvent = true;
    } else if (blockType !== undefined) {
      // Any OTHER block opening (thinking / redacted_thinking / server_tool_use / …)
      // is a boundary too: a text block after it is a NEW logical block, not a
      // continuation of the prior narration. Without this, two text blocks separated
      // only by a thinking block would MERGE (garbled). The block's own content is
      // still ignored for reassembly (only text_delta is folded in).
      state.sawStreamEvent = true;
      state.sawToolAfterLastText = true;
    }
    return;
  }
  if (type === "content_block_delta") {
    const delta = raw.delta as Record<string, unknown> | undefined;
    if (delta?.type === "text_delta" && typeof delta.text === "string") {
      state.sawStreamEvent = true;
      if (state.texts.length === 0 || state.sawToolAfterLastText) {
        state.texts.push("");
        state.sawToolAfterLastText = false;
      }
      state.texts[state.texts.length - 1] += delta.text;
    }
    // thinking_delta / input_json_delta (tool args) are ignored.
  }
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
  } else if (typeof item.name === "string" && item.name && item.tool_use_id === undefined) {
    // tool_use: the preceding text block is now a finished narration. Gate on `name`
    // (a tool_use block always has it) and NOT requiring `input` — a serialized
    // tool_use that omits an empty `input` key would otherwise slip the gate, so the
    // tool went UNcounted (skewing the perf-comparison toolCalls) AND the narration
    // before it MERGED into the next text block (garbled answer). Exclude a
    // tool_result (it carries tool_use_id + content, no semantic name role here) so
    // we don't treat a result as a fresh tool call (cross-review). Matches the
    // partial-message path, which gates on block type alone, not on input.
    state.sawToolAfterLastText = true;
    countTool(state, item.name);
  }
  // thinking / tool_result: ignored.
}

/** texts[] → {narrations (all but last), conclusion (last NON-EMPTY)}.
 *  Empty/whitespace-only blocks are dropped BEFORE classifying: a trailing empty
 *  block (model opened a final text block but never filled it) must not steal the
 *  conclusion slot and blank the card while the real answer sits in narrations
 *  (cross-review HIGH). Same filter also prevents a whitespace-only final block
 *  from rendering as a blank answer at finalize. */
export function splitTexts(texts: string[], error: string | null = null): ParsedStream {
  const nonEmpty = texts.filter((t) => t.trim() !== "");
  if (nonEmpty.length === 0) return { narrations: [], conclusion: "", error };
  return { narrations: nonEmpty.slice(0, -1), conclusion: nonEmpty[nonEmpty.length - 1], error };
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
  if (state.protocol === "source-truth" && !state.sawResult) {
    state.error ??= "stream truncated before completion (no terminal result event)";
  }
  return splitTexts(state.texts, state.error);
}
