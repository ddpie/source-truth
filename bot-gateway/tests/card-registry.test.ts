/**
 * Unit tests for the message→card registry. Card action callbacks only carry
 * open_message_id (not the CardKit entity card_id), so we record the mapping
 * when we send a card, and look it up on a follow-up click to update its buttons
 * AND to resume the same warm session.
 */

import { rememberCard, lookupCard, forgetCard } from "../src/card-registry";

describe("card registry", () => {
  it("remembers and looks up a card_id by message_id", () => {
    rememberCard("om_msg1", "card_111");
    expect(lookupCard("om_msg1")?.cardId).toBe("card_111");
  });

  it("remembers the sessionId alongside the card so a follow-up can resume it", () => {
    rememberCard("om_msg_sess", "card_s", "sess-uuid-123");
    expect(lookupCard("om_msg_sess")).toEqual({ cardId: "card_s", sessionId: "sess-uuid-123" });
  });

  it("returns undefined for an unknown message_id", () => {
    expect(lookupCard("om_never_seen")).toBeUndefined();
  });

  it("overwrites when the same message_id is recorded again", () => {
    rememberCard("om_msg2", "card_a", "sess-a");
    rememberCard("om_msg2", "card_b", "sess-b");
    expect(lookupCard("om_msg2")).toEqual({ cardId: "card_b", sessionId: "sess-b" });
  });

  it("forgets a mapping", () => {
    rememberCard("om_msg3", "card_x");
    forgetCard("om_msg3");
    expect(lookupCard("om_msg3")).toBeUndefined();
  });
});
