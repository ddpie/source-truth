/**
 * Unit tests for the WSClient connection-error policy of src/index.ts.
 * Pure / injected — no child process, no Feishu.
 */

import { classifyWsError } from "../src/index-core";

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
