/**
 * Quick emoji reaction to acknowledge a message before the agent answers.
 *
 * Verified: lark-cli im reactions create --as bot → code:0 (bot can react).
 * This gives instant "seen, processing" feedback; the CardKit answer card
 * arrives seconds later.
 */

import { spawn } from "node:child_process";

const PROCESSING_EMOJI = "OnIt";

/** Add a "processing" reaction to a message. Best-effort (doesn't throw). */
export function ackWithReaction(messageId: string): void {
  const child = spawn(
    "lark-cli",
    [
      "im", "reactions", "create",
      "--as", "bot",
      "--message-id", messageId,
      "--data", JSON.stringify({ reaction_type: { emoji_type: PROCESSING_EMOJI } }),
    ],
    { stdio: ["ignore", "ignore", "ignore"] },
  );
  // Fire-and-forget: don't await or reject — it's a nice-to-have, not critical.
  child.on("error", () => {});
}
