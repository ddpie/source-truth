/**
 * PURE decision logic for finalizing a streaming card. Extracted from
 * runStreamingInvoke (index.ts) so the branch matrix that maps an invoke outcome
 * to {what body text, keep charts?, keep follow-ups?, remember as context?} is
 * UNIT-TESTABLE — index.ts itself is an untested entry shell, so this composition
 * (which a regression could silently break: dropping follow-ups on a turn cap,
 * rendering charts on a hard failure, storing a hard-failure body as context) had
 * no coverage. index.ts now calls these helpers and only does the I/O.
 *
 * Mirrors the existing extraction pattern (classifyInvokeOutcome, serialize-session):
 * keep the side-effect-free decision here, keep the card writes in index.ts.
 */

export interface FinalizeInputs {
  /** classifyInvokeOutcome().failed — any non-200 OR a stream-level error. */
  failed: boolean;
  /** classifyInvokeOutcome().httpFailed — a non-200 transport failure. */
  httpFailed: boolean;
  /** isTurnCapError(error) — the agentic-loop turn cap (partial progress). */
  turnCappedRaw: boolean;
  /** user pressed 停止. */
  aborted: boolean;
  /** the 9-min safety timeout fired. */
  timedOut: boolean;
  /** error text matched a Bedrock model-access denial. */
  accessDenied: boolean;
}

export interface FinalizeDecision {
  /** A real outage/denial: discard the partial answer, show a fixed message. */
  hardFailed: boolean;
  /** Turn cap, gated so an HTTP failure can never be read as a turn cap. */
  turnCapped: boolean;
  /** Render data charts? (skip on hard failure — no trustworthy conclusion). */
  keepCharts: boolean;
  /** Render follow-up buttons? (skip on hard failure). */
  keepFooter: boolean;
  /** Store the answer as conversation context? (skip on hard failure). */
  remember: boolean;
}

/** Decide the terminal classification from the raw outcome flags. PURE. */
export function decideFinalize(i: FinalizeInputs): FinalizeDecision {
  // Gate turn-cap to the in-stream (HTTP-200) path: a non-200 body that happens to
  // contain "maximum turns" must NOT be read as a turn cap (it would render the raw
  // error envelope as a partial "answer"). Mirrors index.ts:516.
  const turnCapped = !i.httpFailed && i.turnCappedRaw;
  // Hard failure = a real outage/denial; a turn cap is its own (partial) branch.
  const hardFailed = i.failed && !turnCapped;
  return {
    hardFailed,
    turnCapped,
    keepCharts: !hardFailed,
    keepFooter: !hardFailed,
    remember: !hardFailed, // never store a hard-failure body as future context
  };
}

/** Fixed hard-failure message: a model-access hint vs the generic outage message.
 *  PURE (no redaction here — caller redacts the final string). */
export function hardFailureMessage(accessDenied: boolean): string {
  return accessDenied
    ? "⚠️ 模型访问未开通：请在 AWS Bedrock 控制台为该模型开通 Model access（global.* 跨区域推理需在相关区域分别开通），开通后即可正常回答。"
    : "⚠️ 查询失败（后端不可用或取证中断），请稍后重试；若持续失败请转研发。";
}

/** Shape the VISIBLE body (evidence already split off) for the non-hard-failure
 *  branches, appending the incompleteness disclaimer AFTER evidence so it isn't
 *  hidden in the folded panel. `body` is the evidence-free prose. PURE. */
export function shapeBody(
  body: string,
  d: { turnCapped: boolean; aborted: boolean; timedOut: boolean },
): string {
  if (d.turnCapped) {
    return body
      ? body + "\n\n*（分析步骤较多，未在限定步数内完成；以上为已得到的部分结论，建议把问题缩小后再问，例如只问某一个符号 / 某一处影响）*"
      : "⚠️ 这个问题分析步骤较多，未在限定步数内得出结论。请把问题缩小（如只问某一个符号 / 某一处影响）后重试。";
  }
  if (d.aborted) {
    return body ? body + "\n\n*（已停止，以上为已生成内容）*" : "⏹ 已停止。";
  }
  if (d.timedOut && !body) {
    return "⏱ 分析超时，请缩小问题范围后重试。";
  }
  return body || "(无内容)";
}
