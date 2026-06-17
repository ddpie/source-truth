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
  child.on("error", () => {});
}

/** Remove the processing reaction after the real reply is sent. Best-effort. */
export function removeReaction(messageId: string): void {
  // lark-cli im reactions delete needs the reaction_id, but we don't have it.
  // Simpler: just add a different emoji or use the batch_query + delete flow.
  // Actually the simplest: the bot can delete its own reaction by type.
  // But the API requires reaction_id. Workaround: query then delete.
  // For MVP: just leave it — or use the raw API to delete by emoji type.
  // Feishu API: DELETE /open-apis/im/v1/messages/{message_id}/reactions/{reaction_id}
  // We need reaction_id. Fetch it first:
  const query = spawn(
    "lark-cli",
    ["im", "reactions", "list", "--as", "bot", "--message-id", messageId],
    { stdio: ["ignore", "pipe", "ignore"] },
  );
  let out = "";
  query.stdout.on("data", (d) => (out += d));
  query.on("exit", () => {
    try {
      const data = JSON.parse(out);
      const items = data?.data?.items ?? data?.items ?? [];
      const mine = items.find(
        (r: { reaction_type?: { emoji_type?: string }; operator?: { operator_type?: string } }) =>
          r.reaction_type?.emoji_type === PROCESSING_EMOJI &&
          r.operator?.operator_type === "app",
      );
      if (mine?.reaction_id) {
        spawn("lark-cli", [
          "im", "reactions", "delete", "--as", "bot",
          "--message-id", messageId,
          "--reaction-id", mine.reaction_id,
        ], { stdio: ["ignore", "ignore", "ignore"] });
      }
    } catch { /* best-effort */ }
  });
  query.on("error", () => {});
}
