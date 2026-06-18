/**
 * Compose a follow-up prompt that REPLAYS the prior conversation as context.
 *
 * A follow-up button click (or a reply to an earlier card) is a NEW agent invoke;
 * the agent does not carry the previous conversation (each runtime invoke is a
 * fresh SDK session — reusing the runtimeSessionId only pins the warm microVM, it
 * doesn't replay history). So to make 追问/reply actually continue, the gateway
 * prepends the prior turns (question + answer) as explicit context. This is the
 * stateless "external history replay" pattern (recommended over sticky-session
 * resume: any microVM can serve it, it survives restarts, and it can never
 * accidentally continue the wrong session).
 *
 * Multi-turn: `prior` is the WHOLE chain (oldest→newest) so several follow-ups /
 * replies build the full history, not just the immediately-preceding turn.
 *
 * Pure + bounded (the chain is already capped upstream by collectChain).
 */

export interface ChainTurn {
  question?: string;
  answer?: string;
}

/**
 * Build the prompt text for a follow-up. When prior turns are known, frame them
 * as background context the agent should use, then the new question. The framing
 * is explicit so the agent treats prior answers as CONTEXT, not as freshly-
 * verified truth (it must still re-verify against code per the prime directive).
 */
export function composeFollowUpPrompt(followUp: string, prior: ChainTurn[]): string {
  const turns = (prior ?? []).filter((t) => (t.question ?? "").trim() || (t.answer ?? "").trim());
  if (turns.length === 0) return followUp; // no context to replay → send as-is

  const lines = [
    "【前面的对话（供你理解本次追问的指代与背景；结论仍需以最新代码取证为准，不要把下面的旧回答当成已核实的事实）】",
  ];
  turns.forEach((t, i) => {
    const n = i + 1;
    const q = (t.question ?? "").trim();
    const a = (t.answer ?? "").trim();
    if (q) lines.push(`第${n}轮 · 问：${q}`);
    if (a) lines.push(`第${n}轮 · 答：\n${a}`);
  });
  lines.push("", `【本次追问】\n${followUp}`);
  return lines.join("\n");
}
