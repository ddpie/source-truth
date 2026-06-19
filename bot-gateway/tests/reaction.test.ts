/**
 * Tests for the processing-reaction (OnIt emoji) lifecycle, focused on the
 * add/remove TOCTOU under load: removeReaction can fire BEFORE imAddReaction's
 * network round-trip resolves, so the id isn't stored yet. The late-landing add
 * must then delete the reaction itself instead of leaving the emoji stuck forever.
 */

// Mock feishu-http so no network is hit and we control the add's resolution timing.
let addResolvers: Array<(id: string | undefined) => void> = [];
const deleted: Array<[string, string]> = [];

jest.mock("../src/feishu-http", () => ({
  feishuConfigured: () => true,
  imAddReaction: jest.fn(
    () => new Promise<string | undefined>((resolve) => { addResolvers.push(resolve); }),
  ),
  imDeleteReaction: jest.fn((messageId: string, reactionId: string) => {
    deleted.push([messageId, reactionId]);
    return Promise.resolve();
  }),
}));

import { ackWithReaction, removeReaction } from "../src/reaction";

afterEach(() => {
  addResolvers = [];
  deleted.length = 0;
  jest.clearAllMocks();
});

describe("reaction add/remove lifecycle", () => {
  it("removes the reaction normally when the add resolved first", async () => {
    ackWithReaction("om_1");
    addResolvers[0]("rid_1");          // add lands first → id stored
    await Promise.resolve();           // let the .then run
    removeReaction("om_1");
    expect(deleted).toEqual([["om_1", "rid_1"]]);
  });

  it("does NOT leave the emoji stuck when remove fires BEFORE the add resolves (P1)", async () => {
    ackWithReaction("om_2");           // add in flight, NOT resolved
    removeReaction("om_2");            // caller already sent the card → wants it gone
    expect(deleted).toEqual([]);       // nothing to delete yet (id unknown)
    addResolvers[0]("rid_2");          // add finally lands…
    await Promise.resolve();
    // …and must delete itself because a removal was already requested.
    expect(deleted).toEqual([["om_2", "rid_2"]]);
  });

  it("a never-resolved add followed by remove never deletes (no spurious call)", async () => {
    ackWithReaction("om_3");
    removeReaction("om_3");
    // add stays pending → no delete; the pendingRemoval intent is recorded, harmless.
    await Promise.resolve();
    expect(deleted).toEqual([]);
  });
});
