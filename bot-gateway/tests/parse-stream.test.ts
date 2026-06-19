/**
 * Unit tests for parseAgentStream — classifies the agent's raw SSE stream into
 * narration segments (the human-readable "what I'm doing now" lines, shown live
 * in the 分析过程 panel) vs the final conclusion (the last text block, shown as
 * the answer). Tool-use / tool-result / thinking blocks are not surfaced.
 *
 * Fixture is a real captured stream (handle-event question, repo not mounted).
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseAgentStream, newStreamState, applyEvent } from "../src/parse-stream";

const FIXTURE = readFileSync(join(__dirname, "fixtures/agent-stream-sample.txt"), "utf8");

describe("parseAgentStream", () => {
  const { narrations, conclusion } = parseAgentStream(FIXTURE);

  it("pulls the narration segments (every text block except the last)", () => {
    // The sample has 5 text blocks: 4 narrations + 1 conclusion.
    expect(narrations).toHaveLength(4);
    expect(narrations[0]).toContain("定位");
    expect(narrations[1]).toContain("换关键词");
  });

  it("treats the last text block as the conclusion", () => {
    expect(conclusion).toContain("目前查不到");
    expect(conclusion).toContain("建议怎么做");
  });

  it("does not leak tool names or tool output into narration/conclusion", () => {
    const all = narrations.join("\n") + "\n" + conclusion;
    // Tool-use blocks (ToolSearch/Bash/Grep) must not appear as content.
    expect(all).not.toContain("toolu_bdrk");
    expect(all).not.toContain("tool_use_id");
  });

  it("handles a stream with a single text block (conclusion only, no narration)", () => {
    const single = 'data: {"content": [{"text": "直接的答案。"}], "stop_reason": "end_turn"}\n';
    const { narrations: n, conclusion: c } = parseAgentStream(single);
    expect(n).toHaveLength(0);
    expect(c).toBe("直接的答案。");
  });

  it("returns empty conclusion for an empty stream", () => {
    const { narrations: n, conclusion: c } = parseAgentStream("");
    expect(n).toHaveLength(0);
    expect(c).toBe("");
  });

  it("does NOT flag the healthy fixture as an error despite per-tool is_error denials", () => {
    // The captured run hit dontAsk permission denials (is_error:true INSIDE
    // content[]) yet completed successfully. Those must not be read as a
    // stream-level failure, or every healthy read-only run would look failed.
    expect(parseAgentStream(FIXTURE).error).toBeNull();
  });
});

describe("parseAgentStream error detection", () => {
  it("flags a top-level runtime error event (no content array)", () => {
    const sse =
      'data: {"content": [{"text": "正在分析…"}]}\n' +
      'data: {"error": "connection refused", "error_type": "ConnectionError", "message": "An error occurred during streaming"}\n';
    const { error, conclusion } = parseAgentStream(sse);
    expect(error).toBe("ConnectionError: connection refused");
    // The partial narration is still captured but the caller must treat the run
    // as failed (error != null), not render `conclusion` as the answer.
    expect(conclusion).toBe("正在分析…");
  });

  it("flags a ResultMessage with top-level is_error:true", () => {
    const sse =
      'data: {"content": [{"text": "partial"}]}\n' +
      'data: {"subtype": "error_max_turns", "is_error": true, "result": "Maximum turns exceeded"}\n';
    expect(parseAgentStream(sse).error).toBe("Maximum turns exceeded");
  });

  it("does NOT flag a per-tool is_error inside content[] (dontAsk denial)", () => {
    const sse =
      'data: {"content": [{"tool_use_id": "t1", "content": "blocked by permission", "is_error": true}]}\n' +
      'data: {"content": [{"text": "最终答案。"}], "stop_reason": "end_turn"}\n';
    const { error, conclusion } = parseAgentStream(sse);
    expect(error).toBeNull();
    expect(conclusion).toBe("最终答案。");
  });

  it("keeps the FIRST error when several arrive", () => {
    const sse =
      'data: {"error": "first", "error_type": "EarlyError"}\n' +
      'data: {"error": "second", "error_type": "LateError"}\n';
    expect(parseAgentStream(sse).error).toBe("EarlyError: first");
  });

  it("flags a stream error that carries `error` but NO error_type (cross-review)", () => {
    // error_type is optional; requiring it silently dropped this error → later
    // mis-reported as a truncation, or swallowed entirely.
    const sse =
      'data: {"content": [{"text": "正在分析…"}]}\n' +
      'data: {"error": "backend exploded"}\n';
    expect(parseAgentStream(sse).error).toBe("backend exploded");
  });

  it("a trailing whitespace-only text block does NOT steal the conclusion slot (HIGH)", () => {
    // The same regression splitTexts fixes — now also exercised through the full
    // parse so the live (sigv4) path, which routes through splitTexts, is covered.
    const sse =
      'data: {"content": [{"text": "真正的最终答案"}]}\n' +
      'data: {"content": [{"name": "codegraph_read_file", "input": {}}]}\n' +
      'data: {"content": [{"text": "   "}]}\n' +
      'data: {"num_turns": 5, "stop_reason": "end_turn"}\n';
    const { conclusion, narrations } = parseAgentStream(sse);
    expect(conclusion).toBe("真正的最终答案");
    expect(narrations).toEqual([]); // the blank block is dropped, not promoted
  });
});

describe("stream completion flag (sawResult) — truncation detection", () => {
  // Drive applyEvent directly so we can inspect state.sawResult (the caller uses
  // it to flip a truncated stream to an error instead of a finished answer).
  const run = (lines: string[]) => {
    const st = newStreamState();
    for (const l of lines) applyEvent(st, JSON.parse(l));
    return st;
  };

  it("sets sawResult on a terminal success ResultMessage (clean completion)", () => {
    const st = run([
      '{"content":[{"text":"最终答案。"}],"stop_reason":"end_turn"}',
      '{"subtype":"success","is_error":false,"num_turns":9,"stop_reason":"end_turn","result":"最终答案。"}',
    ]);
    expect(st.sawResult).toBe(true);
    expect(st.error).toBeNull();
  });

  it("leaves sawResult FALSE when the stream is cut mid-answer (no terminal event)", () => {
    // No ResultMessage ever arrives — connection dropped mid-conclusion.
    const st = run([
      '{"content":[{"text":"答案的前半"}]}',
      '{"content":[{"text":"句还没说完"}]}',
    ]);
    expect(st.sawResult).toBe(false); // caller will flip this to a truncation error
    expect(st.error).toBeNull();      // no explicit backend error — the gap is the missing terminal event
  });

  it("does NOT set sawResult on the SDK init message (subtype:init, no run summary)", () => {
    const st = run([
      '{"subtype":"init","data":{"session_id":"s"}}',  // SDK system init — NOT terminal
      '{"content":[{"text":"答案前半"}]}',              // then a cut
    ]);
    expect(st.sawResult).toBe(false); // init must not be mistaken for the terminal event
  });

  it("sets sawResult on the is_error terminal ResultMessage too (turn cap)", () => {
    const st = run([
      '{"content":[{"text":"partial"}]}',
      '{"subtype":"error_max_turns","is_error":true,"result":"Maximum turns exceeded"}',
    ]);
    expect(st.sawResult).toBe(true); // terminal event seen — not a truncation, it's a turn cap
    expect(st.error).toBe("Maximum turns exceeded");
  });
});

describe("parseAgentStream — partial messages (include_partial_messages)", () => {
  // AgentCore serializes an SDK StreamEvent dataclass via asdict() →
  // {uuid, session_id, event:{...raw Anthropic stream event...}, parent_tool_use_id}.
  // Helper builds one SSE line in that shape.
  const ev = (event: Record<string, unknown>) =>
    `data: ${JSON.stringify({ uuid: "u", session_id: "s", event, parent_tool_use_id: null })}\n`;
  const textDelta = (t: string) => ev({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: t } });
  const textStart = () => ev({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
  const toolStart = () => ev({ type: "content_block_start", index: 1, content_block: { type: "tool_use", name: "codegraph_symbol_search", input: {} } });

  it("assembles a conclusion from token deltas (the typewriter path)", () => {
    const sse = textStart() + textDelta("负重上限 ") + textDelta("= 力量 ") + textDelta("× 1.5。");
    const { conclusion, narrations } = parseAgentStream(sse);
    expect(conclusion).toBe("负重上限 = 力量 × 1.5。");
    expect(narrations).toEqual([]);
  });

  it("tool-gates delta blocks: a narration delta-block then a tool then the conclusion", () => {
    const sse =
      textStart() + textDelta("正在定位 MaxEncumbrance") +
      toolStart() +
      textStart() + textDelta("结论：负重=力量×1.5");
    const { narrations, conclusion } = parseAgentStream(sse);
    expect(narrations).toEqual(["正在定位 MaxEncumbrance"]);
    expect(conclusion).toBe("结论：负重=力量×1.5");
  });

  it("does NOT double-count: a closing full AssistantMessage after deltas is ignored", () => {
    // With partial messages on, the SDK still emits the complete AssistantMessage
    // at turn end carrying the SAME text. Once in delta mode we must skip it.
    const sse =
      textStart() + textDelta("答案 ") + textDelta("片段") +
      'data: {"content": [{"text": "答案 片段"}]}\n';
    expect(parseAgentStream(sse).conclusion).toBe("答案 片段");
  });

  it("still detects a stream-level error alongside partial messages", () => {
    const sse = textStart() + textDelta("partial") + 'data: {"error": "boom", "error_type": "RunError"}\n';
    expect(parseAgentStream(sse).error).toBe("RunError: boom");
  });

  it("is backward-compatible: a non-partial stream (full messages only) is unchanged", () => {
    const sse =
      'data: {"content": [{"text": "narration"}]}\n' +
      'data: {"content": [{"name": "tool", "input": {}}]}\n' +
      'data: {"content": [{"text": "conclusion"}]}\n';
    const { narrations, conclusion } = parseAgentStream(sse);
    expect(narrations).toEqual(["narration"]);
    expect(conclusion).toBe("conclusion");
  });

  // REGRESSION (HIGH): a trailing text block opened after the LAST tool_use but never
  // filled must NOT become the conclusion and demote the real answer to a narration.
  it("ignores a dangling EMPTY trailing text block (real answer stays the conclusion)", () => {
    const sse =
      textStart() + textDelta("正在定位") +
      toolStart() +
      textStart() + textDelta("最终答案在这里") +
      toolStart() +            // one last verification call
      textStart();             // opens "" — never filled, model stops
    const { narrations, conclusion } = parseAgentStream(sse);
    expect(conclusion).toBe("最终答案在这里");
    expect(narrations).toEqual(["正在定位"]);
  });

  // REGRESSION: a whitespace-only final block isn't a real answer.
  it("drops a whitespace-only final block (does not render blank as the conclusion)", () => {
    const sse =
      textStart() + textDelta("真正的结论") +
      toolStart() +
      textStart() + textDelta("   \n  ");
    expect(parseAgentStream(sse).conclusion).toBe("真正的结论");
  });

  // REGRESSION (BUG 2): a thinking block between two text blocks is a boundary — the
  // two text blocks must NOT merge (would garble narration into the conclusion).
  it("treats a thinking block as a text-block boundary (no merge)", () => {
    const thinkingStart = () => ev({ type: "content_block_start", index: 1, content_block: { type: "thinking" } });
    const sse =
      textStart() + textDelta("先想一下定位") +
      thinkingStart() +        // extended-thinking block (content ignored)
      textStart() + textDelta("结论：闪避看敏捷");
    const { narrations, conclusion } = parseAgentStream(sse);
    expect(narrations).toEqual(["先想一下定位"]);
    expect(conclusion).toBe("结论：闪避看敏捷");
  });
});

describe("tool-call accounting (perf: few-deep-turns vs many-round-trips)", () => {
  it("counts tool_use blocks per name in the full-message path", () => {
    const sse =
      'data: {"content": [{"text": "n1"}]}\n' +
      'data: {"content": [{"name": "mcp__codegraph__codegraph_symbol_search", "input": {}}]}\n' +
      'data: {"content": [{"text": "n2"}]}\n' +
      'data: {"content": [{"name": "mcp__codegraph__codegraph_get_callers", "input": {}}]}\n' +
      'data: {"content": [{"name": "Grep", "input": {}}]}\n' +
      'data: {"content": [{"text": "conclusion"}]}\n';
    const st = newStreamState();
    for (const line of sse.split("\n")) {
      const t = line.trim();
      if (!t.startsWith("data:")) continue;
      applyEvent(st, JSON.parse(t.slice(5).trim()));
    }
    expect(st.toolCalls).toBe(3);
    expect(st.toolCallsByName).toEqual({
      mcp__codegraph__codegraph_symbol_search: 1,
      mcp__codegraph__codegraph_get_callers: 1,
      Grep: 1,
    });
  });

  it("counts tool_use blocks in the partial-message (StreamEvent) path", () => {
    const ev = (event: Record<string, unknown>) =>
      JSON.stringify({ uuid: "u", session_id: "s", event, parent_tool_use_id: null });
    const st = newStreamState();
    applyEvent(st, JSON.parse(ev({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } })));
    applyEvent(st, JSON.parse(ev({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "narrate" } })));
    applyEvent(st, JSON.parse(ev({ type: "content_block_start", index: 1, content_block: { type: "tool_use", name: "Read", input: {} } })));
    applyEvent(st, JSON.parse(ev({ type: "content_block_start", index: 2, content_block: { type: "tool_use", name: "Read", input: {} } })));
    expect(st.toolCalls).toBe(2);
    expect(st.toolCallsByName).toEqual({ Read: 2 });
  });

  it("does NOT double-count a tool-first turn (tool_use then the closing full message)", () => {
    // A turn that OPENS with a tool (no narration text first) must still mark
    // partial mode active, so the redundant closing full AssistantMessage is
    // deduped and the tool is counted exactly once. Regression for the
    // sawStreamEvent-only-on-text bug.
    const ev = (event: Record<string, unknown>) =>
      JSON.stringify({ uuid: "u", session_id: "s", event, parent_tool_use_id: null });
    const st = newStreamState();
    applyEvent(st, JSON.parse(ev({ type: "content_block_start", index: 0, content_block: { type: "tool_use", name: "Read", input: {} } })));
    // The SDK's closing full AssistantMessage repeats the same tool_use:
    applyEvent(st, { content: [{ name: "Read", input: {} }] });
    expect(st.toolCalls).toBe(1);
    expect(st.toolCallsByName).toEqual({ Read: 1 });
  });

  it("counts a tool_use whose serialized form OMITS the input key (cross-review)", () => {
    // Gating on `\"input\" in item` missed a tool_use without an input key → the tool
    // went uncounted AND the surrounding text blocks merged (garbled answer).
    const st = newStreamState();
    applyEvent(st, { content: [{ text: "narration" }] });
    applyEvent(st, { content: [{ name: "weirdtool" }] }); // no input key
    applyEvent(st, { content: [{ text: "答案" }] });
    expect(st.toolCalls).toBe(1);
    expect(st.toolCallsByName).toEqual({ weirdtool: 1 });
    // The tool boundary kept the two text blocks separate (not "n...答案" merged).
    expect(st.texts).toEqual(["narration", "答案"]);
  });

  it("does NOT treat a tool_result (tool_use_id, no role) as a fresh tool call", () => {
    const st = newStreamState();
    applyEvent(st, { content: [{ text: "narration" }] });
    applyEvent(st, { content: [{ tool_use_id: "t1", name: "ignored", content: "result text" }] });
    expect(st.toolCalls).toBe(0); // tool_use_id present → it's a result, not a call
  });
});

describe("sawResult — bare-key result:null must not satisfy the terminal guard", () => {
  it("does NOT set sawResult on a non-terminal event carrying result:null (cross-review)", () => {
    const st = newStreamState();
    applyEvent(st, { result: null }); // no num_turns / is_error / stop_reason
    expect(st.sawResult).toBe(false);
  });

  it("still sets sawResult on a real terminal result string", () => {
    const st = newStreamState();
    applyEvent(st, { result: "done", num_turns: 3 });
    expect(st.sawResult).toBe(true);
  });
});
