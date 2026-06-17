/**
 * Unit tests for buildReplyArgs — builds the `lark-cli im +messages-reply`
 * argv that sends the agent's answer back to Feishu as a bot markdown reply.
 * Pure (argv construction); the actual spawn is integration-only.
 */

import { buildReplyArgs } from "../src/reply";

describe("buildReplyArgs", () => {
  it("replies to the originating message as the bot, in markdown", () => {
    const argv = buildReplyArgs({ messageId: "om_123", answer: "**1+1 = 2**" });
    expect(argv[0]).toBe("im");
    expect(argv).toContain("+messages-reply");
    expect(argv).toContain("--as");
    expect(argv).toContain("bot");
    expect(argv).toContain("--message-id");
    expect(argv).toContain("om_123");
    expect(argv).toContain("--markdown");
    expect(argv).toContain("**1+1 = 2**");
  });

  it("keeps message-id and markdown adjacent to their flags", () => {
    const argv = buildReplyArgs({ messageId: "om_x", answer: "ans" });
    expect(argv[argv.indexOf("--message-id") + 1]).toBe("om_x");
    expect(argv[argv.indexOf("--markdown") + 1]).toBe("ans");
  });
});
