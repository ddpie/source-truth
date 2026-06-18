/**
 * Unit tests for buildTextContent — builds the Feishu text-message content
 * payload (JSON string) for a plain bot reply. The actual send is in-process
 * HTTP (feishu-http), integration-only.
 */

import { buildTextContent } from "../src/reply";

describe("buildTextContent", () => {
  it("wraps the answer as a Feishu text content payload", () => {
    const content = buildTextContent("**1+1 = 2**");
    expect(JSON.parse(content)).toEqual({ text: "**1+1 = 2**" });
  });

  it("escapes newlines/quotes safely via JSON", () => {
    const content = buildTextContent('line1\n"quoted"');
    expect(JSON.parse(content).text).toBe('line1\n"quoted"');
  });
});
