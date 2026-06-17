/**
 * Reply the agent's answer back to Feishu.
 *
 * MVP closes the loop with a bot markdown reply to the originating message
 * (`lark-cli im +messages-reply`). The richer CardKit streaming card (see
 * src/cardkit.ts) is a later enhancement layered on this same reply path.
 *
 * buildReplyArgs is pure (argv); sendReply spawns lark-cli.
 */

import { spawn } from "node:child_process";

export interface ReplyParams {
  messageId: string;
  answer: string;
}

/** Build the `lark-cli im +messages-reply` argv (bot identity, markdown). */
export function buildReplyArgs(p: ReplyParams): string[] {
  return [
    "im",
    "+messages-reply",
    "--as",
    "bot",
    "--message-id",
    p.messageId,
    "--markdown",
    p.answer,
  ];
}

/** Send the reply via lark-cli. Resolves on exit code 0, rejects otherwise. */
export function sendReply(p: ReplyParams): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn("lark-cli", buildReplyArgs(p), {
      stdio: ["ignore", "ignore", "inherit"],
    });
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`lark-cli reply exited ${code}`)),
    );
    child.on("error", reject);
  });
}
