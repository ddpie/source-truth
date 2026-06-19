/**
 * Tests for the in-process Feishu OpenAPI client (replaces spawn lark-cli on the
 * CardKit hot path). Covers: token caching (one fetch shared across calls),
 * non-zero Feishu code → throw, non-2xx → throw, and a 401 → token-refresh retry.
 * `fetch` is stubbed so no network is hit.
 */

// feishu-http reads APP_ID/SECRET at module load; set dummies BEFORE import so the
// credential guard passes (fetch is stubbed, so the values are never sent anywhere).
process.env.FEISHU_APP_ID = process.env.FEISHU_APP_ID || "cli_test";
process.env.FEISHU_APP_SECRET = process.env.FEISHU_APP_SECRET || "secret_test";

import { getTenantToken, invalidateToken, feishuApi, imReply, imSendToChat } from "../src/feishu-http";

type FetchArgs = [input: string, init?: { method?: string; headers?: Record<string, string>; body?: string }];

const realFetch = global.fetch;
let calls: FetchArgs[] = [];

function stubFetch(handler: (url: string, init: FetchArgs[1]) => { status?: number; json: unknown }) {
  calls = [];
  global.fetch = (async (url: string, init?: FetchArgs[1]) => {
    calls.push([url, init]);
    const { status = 200, json } = handler(url, init);
    return { status, json: async () => json } as unknown as Response;
  }) as unknown as typeof fetch;
}

afterEach(() => {
  global.fetch = realFetch;
  invalidateToken();
});

const tokenResponse = (token = "t-abc", expire = 7200) => ({ code: 0, tenant_access_token: token, expire });

describe("getTenantToken", () => {
  it("fetches once and caches (second call hits no network)", async () => {
    stubFetch(() => ({ json: tokenResponse("t-1") }));
    expect(await getTenantToken()).toBe("t-1");
    expect(await getTenantToken()).toBe("t-1");
    const tokenCalls = calls.filter(([u]) => u.includes("tenant_access_token"));
    expect(tokenCalls.length).toBe(1); // cached
  });

  it("throws when Feishu returns a non-zero code", async () => {
    stubFetch(() => ({ json: { code: 10003, msg: "app disabled" } }));
    await expect(getTenantToken()).rejects.toThrow(/tenant_access_token failed/);
  });
});

describe("feishuApi", () => {
  it("sends the bearer token and parses a code:0 response", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token")
        ? { json: tokenResponse("t-xyz") }
        : { json: { code: 0, data: { card_id: "c1" } } },
    );
    const res = (await feishuApi("POST", "/open-apis/cardkit/v1/cards", { x: 1 })) as { data: { card_id: string } };
    expect(res.data.card_id).toBe("c1");
    const apiCall = calls.find(([u]) => u.includes("/cardkit/"));
    expect(apiCall?.[1]?.headers?.Authorization).toBe("Bearer t-xyz");
    expect(apiCall?.[1]?.method).toBe("POST");
  });

  it("throws on a non-zero Feishu code", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token") ? { json: tokenResponse() } : { json: { code: 11311, msg: "bad seq" } },
    );
    await expect(feishuApi("PUT", "/open-apis/cardkit/v1/cards/c", { s: 1 })).rejects.toThrow(/code 11311/);
  });

  it("throws on a non-2xx HTTP status", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token") ? { json: tokenResponse() } : { status: 500, json: { msg: "boom" } },
    );
    await expect(feishuApi("GET", "/open-apis/x")).rejects.toThrow(/HTTP 500/);
  });

  it("retries ONCE after a 401 (stale token), refreshing the token", async () => {
    let apiHits = 0;
    stubFetch((url) => {
      if (url.includes("tenant_access_token")) return { json: tokenResponse(`t-${Date.now()}`) };
      apiHits++;
      return apiHits === 1 ? { status: 401, json: { msg: "expired" } } : { json: { code: 0, data: "ok" } };
    });
    const res = (await feishuApi("POST", "/open-apis/x", {})) as { data: string };
    expect(res.data).toBe("ok");
    expect(apiHits).toBe(2); // first 401, retry succeeded
  });

  it("treats an app-level token-expiry CODE (HTTP 200) like a 401 — refresh + retry", async () => {
    let apiHits = 0;
    stubFetch((url) => {
      if (url.includes("tenant_access_token")) return { json: tokenResponse(`t-${Date.now()}`) };
      apiHits++;
      // 99991663 = invalid access token, returned as HTTP 200 body (the common shape).
      return apiHits === 1 ? { json: { code: 99991663, msg: "invalid token" } } : { json: { code: 0, data: "ok" } };
    });
    const res = (await feishuApi("PUT", "/open-apis/x", {})) as { data: string };
    expect(res.data).toBe("ok");
    expect(apiHits).toBe(2);
  });

  it("retries a rate-limit (HTTP 429) with backoff, then succeeds", async () => {
    let apiHits = 0;
    stubFetch((url) => {
      if (url.includes("tenant_access_token")) return { json: tokenResponse() };
      apiHits++;
      return apiHits < 3 ? { status: 429, json: { msg: "slow down" } } : { json: { code: 0, data: "ok" } };
    });
    const res = (await feishuApi("POST", "/open-apis/x", {})) as { data: string };
    expect(res.data).toBe("ok");
    expect(apiHits).toBe(3); // two 429s retried, third succeeded
  });

  it("retries an app-level throttle CODE then gives up after the cap", async () => {
    let apiHits = 0;
    stubFetch((url) => {
      if (url.includes("tenant_access_token")) return { json: tokenResponse() };
      apiHits++;
      return { json: { code: 99991400, msg: "throttled" } }; // always throttled
    });
    await expect(feishuApi("POST", "/open-apis/x", {})).rejects.toThrow(/rate-limited/);
    expect(apiHits).toBe(4); // 1 initial + 3 retries (MAX_RATE_RETRIES)
  });

  it("does NOT treat an empty/unparseable 2xx body as success", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token") ? { json: tokenResponse() } : { status: 200, json: null },
    );
    await expect(feishuApi("PUT", "/open-apis/x", {})).rejects.toThrow(/empty\/unparseable/);
  });
});

describe("im send/reply idempotency uuid", () => {
  it("imReply forwards the uuid in the body (so a retry can't double-post)", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token")
        ? { json: tokenResponse() }
        : { json: { code: 0, data: { message_id: "om_new" } } },
    );
    const id = await imReply("om_parent", "interactive", "{}", "card-7777");
    expect(id).toBe("om_new");
    const apiCall = calls.find(([u]) => u.includes("/messages/om_parent/reply"))!;
    expect(JSON.parse(apiCall[1]!.body as string).uuid).toBe("card-7777");
  });

  it("imSendToChat forwards the uuid, and an over-50-char uuid is clamped", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token")
        ? { json: tokenResponse() }
        : { json: { code: 0, data: { message_id: "om_x" } } },
    );
    const long = "card-" + "a".repeat(80);
    await imSendToChat("oc_chat", "interactive", "{}", long);
    const apiCall = calls.find(([u]) => u.includes("/im/v1/messages?"))!;
    const sentUuid = JSON.parse(apiCall[1]!.body as string).uuid as string;
    expect(sentUuid.length).toBe(50); // clamped to Feishu's max
    expect(long.startsWith(sentUuid)).toBe(true);
  });

  it("omits uuid when none is supplied (undefined drops out of JSON)", async () => {
    stubFetch((url) =>
      url.includes("tenant_access_token")
        ? { json: tokenResponse() }
        : { json: { code: 0, data: { message_id: "om_y" } } },
    );
    await imReply("om_p", "text", "{}");
    const apiCall = calls.find(([u]) => u.includes("/messages/om_p/reply"))!;
    expect("uuid" in JSON.parse(apiCall[1]!.body as string)).toBe(false);
  });
});
