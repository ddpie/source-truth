/**
 * Unit tests for the event-stream core of src/index.ts: parse one NDJSON line
 * from `lark-cli event consume` and dispatch it to the handler. Pure / injected
 * — no child process, no Feishu.
 */

import { processEventLine } from "../src/index-core";
import { resetForTesting as resetDedup } from "../src/dedup";
import { resetForTesting as resetSessions } from "../src/session-map";

afterEach(() => {
  resetDedup();
  resetSessions();
});

// lark-cli emits one JSON object per line; the IM event fields sit in .data.
function line(obj: unknown): string {
  return JSON.stringify(obj);
}

describe("processEventLine", () => {
  it("parses an NDJSON event line and invokes the agent", async () => {
    const prompts: string[] = [];
    const invoke = async (_s: string, p: string) => {
      prompts.push(p);
      return "ans";
    };
    const out = await processEventLine(
      line({
        data: {
          event_id: "e1",
          chat_id: "oc_1",
          chat_type: "group",
          content: "where is X",
          message_id: "om_1",
          sender_id: "ou_1",
          message_type: "text",
        },
      }),
      { invoke },
    );
    expect(out?.handled).toBe(true);
    expect(prompts).toEqual(["where is X"]);
  });

  it("ignores blank lines and non-JSON noise", async () => {
    const invoke = async () => "x";
    expect(await processEventLine("", { invoke })).toBeNull();
    expect(await processEventLine("[event] listening...", { invoke })).toBeNull();
  });

  it("ignores lines without a usable IM event", async () => {
    const invoke = async () => "x";
    const out = await processEventLine(line({ data: { foo: "bar" } }), { invoke });
    expect(out).toBeNull();
  });
});
