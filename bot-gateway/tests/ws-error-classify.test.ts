/**
 * classifyWsError decides whether a long-connection error restarts the process.
 *
 * Why this is worth pinning: the unit is Restart=always with no StartLimitBurst (deliberately, so
 * a gateway never gives up permanently). That makes "exit" an UNBOUNDED 5-second crash loop, and
 * every cycle wipes the in-memory dedup map and card registry — so misclassifying a transient
 * blip as fatal amplifies it into a sustained outage plus lost conversation context. Everything
 * except the connection-limit code used to return "exit".
 */
import { classifyWsError } from "../src/index-core";

describe("classifyWsError", () => {
  it("ignores everything while shutting down", () => {
    expect(classifyWsError(new Error("ECONNRESET"), true)).toBe("ignore");
    expect(classifyWsError(new Error("invalid app secret"), true)).toBe("ignore");
  });

  it("retries the connection-limit code (another gateway holds the slot)", () => {
    expect(classifyWsError(new Error("code 1000040350"), false)).toBe("retry");
    expect(classifyWsError(new Error("exceed_conn_limit"), false)).toBe("retry");
  });

  it("retries transient transport failures instead of crash-looping", () => {
    for (const m of [
      "ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "EAI_AGAIN", "ENOTFOUND",
      "EPIPE", "socket hang up", "network error", "handshake timeout",
    ]) {
      expect(classifyWsError(new Error(m), false)).toBe("retry");
    }
  });

  it("still exits on errors a restart cannot fix", () => {
    for (const m of ["invalid app_secret", "app not published", "permission denied", "token revoked"]) {
      expect(classifyWsError(new Error(m), false)).toBe("exit");
    }
  });
});
