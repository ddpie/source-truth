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
});
