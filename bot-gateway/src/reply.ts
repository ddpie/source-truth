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

import { createCard, updateContent, closeStreaming, buildSendCardContent } from "./cardkit-client";
import { replyWithCard } from "./reply-card";

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

/** Send a plain markdown reply via lark-cli. Resolves on exit 0. */
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

/** Reply to a message with an already-created interactive card. */
function sendCardAsReply(messageId: string, cardId: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "lark-cli",
      ["im", "+messages-reply", "--as", "bot", "--message-id", messageId,
       "--msg-type", "interactive", "--content", buildSendCardContent(cardId)],
      { stdio: ["ignore", "ignore", "inherit"] },
    );
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`lark-cli card reply exited ${code}`)),
    );
    child.on("error", reject);
  });
}

/**
 * Reply with a CardKit "growing answer card": create → stream → close → send.
 * This is the production reply path; sendReply (markdown) stays as a fallback.
 */
export async function sendReplyCard(p: ReplyParams & { title?: string }): Promise<string> {
  return replyWithCard(
    { messageId: p.messageId, answer: p.answer, title: p.title ?? "source-truth" },
    { createCard, updateContent, closeStreaming, sendCard: sendCardAsReply },
  );
}
