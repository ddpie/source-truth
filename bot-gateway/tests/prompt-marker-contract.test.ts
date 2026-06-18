/**
 * Cross-component CONTRACT test: the gateway parses the agent's answer by keying
 * on EXACT Chinese literal markers that the agent's system.md prompt is told to
 * emit. That coupling is convention-only (no shared module), so a future prompt
 * reword would SILENTLY break evidence-folding (raw file:line leaks into the
 * group-visible 正文 — a product-rule violation) and follow-up buttons, with NO
 * error and NO other test failing. This test reads the real system.md and asserts
 * it still contains each marker, so a prompt edit that drops one fails CI loudly.
 *
 * If you intentionally change a marker here, you MUST update the matching parser:
 *   - "你可能还想问"      → src/extract-followups.ts
 *   - "供研发复核"        → src/extract-evidence.ts
 *   - single "---" divider → both (separates 正文 / evidence / follow-ups)
 */

import { readFileSync } from "fs";
import { join } from "path";

const SYSTEM_MD = join(__dirname, "../../agent-container/prompts/system.md");

describe("agent↔gateway marker contract (system.md must emit the literals the parsers key on)", () => {
  const md = readFileSync(SYSTEM_MD, "utf8");

  it("emits the follow-up marker the gateway's extract-followups.ts keys on", () => {
    expect(md).toContain("你可能还想问");
  });

  it("emits the evidence-section marker the gateway's extract-evidence.ts keys on", () => {
    expect(md).toContain("供研发复核");
  });

  it("instructs the single '---' divider the body/evidence/follow-up split relies on", () => {
    // The prompt must tell the agent to use the --- divider; the parsers split on it.
    expect(md).toContain("---");
  });
});
