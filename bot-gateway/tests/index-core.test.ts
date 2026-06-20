/**
 * Unit tests for the event-stream core of src/index.ts: parse one NDJSON line
 * from `lark-cli event consume` and dispatch it to the handler. Pure / injected
 * — no child process, no Feishu.
 */

import { processEventLine, classifyWsError } from "../src/index-core";
import { resetForTesting as resetDedup } from "../src/dedup";
import { resetForTesting as resetSessions } from "../src/session-map";

afterEach(() => {
  resetDedup();
  resetSessions();
});

describe("classifyWsError (WSClient onError decision)", () => {
  it("IGNORES any error while shutting down (drain owns the exit, no exit(1) race)", () => {
    // The bug it guards: SIGTERM → wsRef.stop() → SDK fires onError for the closing
    // socket; without this the error hit exit(1) ahead of the drain → frozen cards +
    // a redeploy that looks like a crash.
    expect(classifyWsError("forbidden: bad creds", true)).toBe("ignore");
    expect(classifyWsError("exceed_conn_limit", true)).toBe("ignore");
    expect(classifyWsError("anything", true)).toBe("ignore");
  });
  it("RETRIES exceed_conn_limit (1000040350) in-process (stale peer holds the slot)", () => {
    expect(classifyWsError("error code 1000040350", false)).toBe("retry");
    expect(classifyWsError("exceed_conn_limit for app", false)).toBe("retry");
  });
  it("EXITS on any other error (terminal: bad/revoked creds → supervisor restart)", () => {
    expect(classifyWsError("forbidden", false)).toBe("exit");
    expect(classifyWsError("auth_failed", false)).toBe("exit");
    expect(classifyWsError(new Error("unknown"), false)).toBe("exit");
  });
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
          chat_type: "p2p", // p2p needs no @-mention to answer
          content: "where is X",
          message_id: "om_1",
          sender_id: "ou_1",
          sender_type: "user",
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
