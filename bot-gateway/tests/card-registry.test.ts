/**
 * Unit tests for the message→card registry. Card action callbacks only carry
 * open_message_id (not the CardKit entity card_id), so we record the mapping
 * when we send a card, and look it up on a follow-up click to update its buttons
 * AND to resume the same warm session.
 */

import { rememberCard, rememberAnswer, lookupCard, forgetCard, collectChain, claimCardUiFlag, isAskerAction } from "../src/card-registry";

describe("card registry", () => {
  it("remembers and looks up a card_id by message_id", () => {
    rememberCard("om_msg1", "card_111");
    expect(lookupCard("om_msg1")?.cardId).toBe("card_111");
  });

  it("remembers the sessionId + question alongside the card", () => {
    rememberCard("om_msg_sess", "card_s", "sess-uuid-123", "负重上限怎么决定？");
    const e = lookupCard("om_msg_sess");
    expect(e?.cardId).toBe("card_s");
    expect(e?.sessionId).toBe("sess-uuid-123");
    expect(e?.question).toBe("负重上限怎么决定？");
  });

  it("rememberAnswer fills the answer for a known card (follow-up context replay)", () => {
    rememberCard("om_qa", "card_qa", "sess-qa", "Q?");
    rememberAnswer("om_qa", "A.");
    const e = lookupCard("om_qa");
    expect(e?.question).toBe("Q?");
    expect(e?.answer).toBe("A.");
  });

  it("rememberAnswer caps very long answers", () => {
    rememberCard("om_long", "card_long");
    rememberAnswer("om_long", "x".repeat(10000));
    expect((lookupCard("om_long")?.answer ?? "").length).toBeLessThanOrEqual(4000);
  });

  it("rememberAnswer on an unknown/evicted card is a no-op (no throw)", () => {
    expect(() => rememberAnswer("om_gone", "A")).not.toThrow();
    expect(lookupCard("om_gone")).toBeUndefined();
  });

  it("returns undefined for an unknown message_id", () => {
    expect(lookupCard("om_never_seen")).toBeUndefined();
  });

  it("overwrites cardId/session on re-record but preserves a prior answer", () => {
    rememberCard("om_msg2", "card_a", "sess-a", "Q1");
    rememberAnswer("om_msg2", "A1");
    rememberCard("om_msg2", "card_b", "sess-b", "Q1");  // e.g. a re-send
    const e = lookupCard("om_msg2");
    expect(e?.cardId).toBe("card_b");
    expect(e?.sessionId).toBe("sess-b");
    expect(e?.answer).toBe("A1"); // prior answer carried over
  });

  it("forgets a mapping", () => {
    rememberCard("om_msg3", "card_x");
    forgetCard("om_msg3");
    expect(lookupCard("om_msg3")).toBeUndefined();
  });
});

describe("claimCardUiFlag (card-lifetime one-shot feedback-UI guards)", () => {
  it("flips unset→set exactly once per (card, flag), returning true only on the first claim", () => {
    rememberCard("om_flag1", "card_f1");
    expect(claimCardUiFlag("om_flag1", "voteRowPainted")).toBe(true);   // first claim paints
    expect(claimCardUiFlag("om_flag1", "voteRowPainted")).toBe(false);  // re-vote: no repaint
    expect(claimCardUiFlag("om_flag1", "voteRowPainted")).toBe(false);
    expect(lookupCard("om_flag1")?.voteRowPainted).toBe(true);
  });

  it("tracks the three flags INDEPENDENTLY so a 👍 (paints row) still lets a later 👎 append its reason grid", () => {
    rememberCard("om_flag2", "card_f2");
    expect(claimCardUiFlag("om_flag2", "voteRowPainted")).toBe(true);      // 👍 paints the row
    expect(claimCardUiFlag("om_flag2", "reasonGridAppended")).toBe(true);  // later 👎 still appends reasons once
    expect(claimCardUiFlag("om_flag2", "reasonGridAppended")).toBe(false); // a 2nd 👎 must not re-append (300315)
    expect(claimCardUiFlag("om_flag2", "reasonRowPainted")).toBe(true);    // first reason pick disables the grid
    expect(claimCardUiFlag("om_flag2", "reasonRowPainted")).toBe(false);
  });

  it("returns false for an unknown/evicted card (caller treats as do-not-write)", () => {
    expect(claimCardUiFlag("om_never_seen", "voteRowPainted")).toBe(false);
  });

  it("scopes flags per card — claiming on one card does not affect another", () => {
    rememberCard("om_flagA", "card_fA");
    rememberCard("om_flagB", "card_fB");
    expect(claimCardUiFlag("om_flagA", "voteRowPainted")).toBe(true);
    expect(claimCardUiFlag("om_flagB", "voteRowPainted")).toBe(true);  // independent card
  });
});

describe("collectChain (multi-turn follow-up history)", () => {
  it("walks the parent chain oldest→newest, collecting every turn's Q&A", () => {
    rememberCard("m1", "c1", "s", "Q1");          rememberAnswer("m1", "A1");
    rememberCard("m2", "c2", "s", "Q2", "m1");    rememberAnswer("m2", "A2"); // follows m1
    rememberCard("m3", "c3", "s", "Q3", "m2");    rememberAnswer("m3", "A3"); // follows m2
    const chain = collectChain("m3");
    expect(chain.map((t) => t.question)).toEqual(["Q1", "Q2", "Q3"]);
    expect(chain.map((t) => t.answer)).toEqual(["A1", "A2", "A3"]);
  });

  it("returns just the one turn when there is no parent", () => {
    rememberCard("solo", "c", "s", "Q"); rememberAnswer("solo", "A");
    expect(collectChain("solo")).toEqual([{ question: "Q", answer: "A" }]);
  });

  it("SKIPS a turn with no settled answer (in-flight / hard-failed) but keeps finalized ancestors", () => {
    rememberCard("p1", "c1", "s", "Q1"); rememberAnswer("p1", "A1"); // finalized
    rememberCard("p2", "c2", "s", "Q2", "p1");                        // in-flight: no answer yet
    // collectChain on the answer-less newest card drops it, keeps the ancestor.
    expect(collectChain("p2")).toEqual([{ question: "Q1", answer: "A1" }]);
    // once it finalizes, it's included.
    rememberAnswer("p2", "A2");
    expect(collectChain("p2")).toEqual([
      { question: "Q1", answer: "A1" },
      { question: "Q2", answer: "A2" },
    ]);
  });

  it("returns [] for an unknown/evicted card", () => {
    expect(collectChain("nope")).toEqual([]);
  });

  it("is cycle-safe (a parent loop can't hang)", () => {
    rememberCard("a", "c", "s", "Qa", "b"); rememberAnswer("a", "Aa");
    rememberCard("b", "c", "s", "Qb", "a"); rememberAnswer("b", "Ab"); // a→b→a loop
    const chain = collectChain("a");
    expect(chain.length).toBeLessThanOrEqual(2); // terminates, no infinite walk
  });

  // REGRESSION (MEDIUM-HIGH): recency must be bumped on READ. An old conversation
  // that is still actively referenced must survive eviction even when many newer
  // unrelated cards arrive — else its early turns evict and the chain truncates.
  it("collectChain bumps recency so an active old chain survives eviction", () => {
    // Build a 2-turn chain at the very start: root r1 ← child r2.
    rememberCard("r1", "c1", "s", "Q1", undefined); rememberAnswer("r1", "A1");
    rememberCard("r2", "c2", "s", "Q2", "r1"); rememberAnswer("r2", "A2");
    // Flood with newer unrelated cards, RE-WALKING the chain each step so it stays hot.
    for (let i = 0; i < 600; i++) {
      rememberCard("x" + i, "cx", "s", "Qx", undefined);
      if (i % 50 === 0) collectChain("r2"); // active reference bumps r1+r2 recency
    }
    const chain = collectChain("r2");
    // Both original turns must still be present (not evicted out from under the chain).
    expect(chain.map((t) => t.answer)).toEqual(["A1", "A2"]);
  });

  it("a STALE (never re-walked) old chain IS evicted under flood (control)", () => {
    rememberCard("g1", "c1", "s", "Q1", undefined); rememberAnswer("g1", "A1");
    rememberCard("g2", "c2", "s", "Q2", "g1"); rememberAnswer("g2", "A2");
    for (let i = 0; i < 600; i++) rememberCard("y" + i, "cy", "s", "Qy", undefined); // no re-walk
    expect(collectChain("g2")).toEqual([]); // evicted — confirms the bump is what saves the active one
  });

  it("clips an over-long pasted QUESTION so it can't starve the chain budget", () => {
    // A planner pastes a 9000-char blob as the question; the stored/replayed question
    // must be bounded (cross-review) so it can't squeeze out earlier turns or blow the
    // prompt. The clip is well under MAX_CHAIN_CHARS.
    const huge = "x".repeat(9000);
    rememberCard("q1", "c1", "s", huge, undefined);
    rememberAnswer("q1", "A1");
    const turns = collectChain("q1");
    expect(turns).toHaveLength(1);
    expect(turns[0].question!.length).toBeLessThanOrEqual(1500);
  });
});

describe("isAskerAction — fail-closed asker gate (stop / feedback / feedback_reason)", () => {
  it("allows ONLY when the known asker equals the operator", () => {
    expect(isAskerAction("ou_asker", "ou_asker")).toBe(true);
  });

  it("denies a different operator (a non-asker group member)", () => {
    // The whole point: a Feishu card has ONE shared UI, so an unscoped action lets any
    // member spend the card's single vote / abort someone's stream. A non-asker is refused.
    expect(isAskerAction("ou_asker", "ou_someone_else")).toBe(false);
  });

  it("FAILS CLOSED when the asker is unknown (empty/undefined) — never trust an unverifiable card", () => {
    expect(isAskerAction(undefined, "ou_op")).toBe(false);
    expect(isAskerAction("", "ou_op")).toBe(false);
  });

  it("FAILS CLOSED when the operator id is missing", () => {
    expect(isAskerAction("ou_asker", undefined)).toBe(false);
    expect(isAskerAction("ou_asker", "")).toBe(false);
  });

  it("does NOT treat two empty ids as a match (both-empty must not authorize)", () => {
    expect(isAskerAction("", "")).toBe(false);
    expect(isAskerAction(undefined, undefined)).toBe(false);
  });
});
