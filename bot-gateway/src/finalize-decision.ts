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

import { t } from "./i18n";

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
  return accessDenied ? t("msg.fail.modelAccess") : t("msg.fail.backend");
}

/** Shape the VISIBLE body (evidence already split off) for the non-hard-failure
 *  branches, appending the incompleteness disclaimer AFTER evidence so it isn't
 *  hidden in the folded panel. `body` is the evidence-free prose. PURE. */
export function shapeBody(
  body: string,
  d: { turnCapped: boolean; aborted: boolean; timedOut: boolean },
): string {
  // Use trim() — NOT truthiness — for the "has body?" test. A whitespace-only body
  // ("  \n ") is truthy, so `body || placeholder` would render an effectively BLANK
  // card under a green "回答完成" header (the forbidden "looks complete but isn't"
  // shape), and the withBody disclaimers would append to nothing. stripPreamble /
  // splitEvidence can legitimately reduce a conclusion to whitespace (e.g. the whole
  // block was a preamble + ---), so this is reachable on a clean run, not just errors.
  const hasBody = body.trim().length > 0;
  if (d.turnCapped) {
    return hasBody ? body + t("msg.turnCapped.withBody") : t("msg.turnCapped.noBody");
  }
  if (d.aborted) {
    return hasBody ? body + t("msg.aborted.withBody") : t("msg.aborted.noBody");
  }
  if (d.timedOut && !hasBody) {
    return t("msg.timeout");
  }
  return hasBody ? body : t("msg.empty");
}
