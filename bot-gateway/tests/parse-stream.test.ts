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
import { parseAgentStream } from "../src/parse-stream";

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
});
