/**
 * The tenant switch — the SINGLE place that turns FEISHU_DOMAIN into a transport target.
 *
 * Why this is its own module: the gateway talks to Feishu over two independent transports, the
 * event long-connection (WSClient, src/index.ts) and the REST API (src/feishu-http.ts). They must
 * point at the same tenant. When they did not, the failure was maximally confusing — an
 * international Lark app authenticated fine on REST and then never received a single event, with
 * nothing in the logs naming the cause.
 *
 * The first fix derived both from the same env var but resolved it twice, in two files, and pinned
 * that arrangement with a test that matched source TEXT. That test could not fail for an inverted
 * ternary (`=== "lark" ? Domain.Feishu : Domain.Lark` satisfies every regex it applied), which is
 * precisely the mistake worth catching. Resolving once, here, makes the two transports agree
 * structurally instead of by assertion, and lets the resolution be tested by VALUE.
 */
import * as lark from "@larksuiteoapi/node-sdk";

export type FeishuTenant = "feishu" | "lark";

const REST_BASES: Record<FeishuTenant, string> = {
  feishu: "https://open.feishu.cn",
  lark: "https://open.larksuite.com",
};

/**
 * Normalise FEISHU_DOMAIN. Returns null for a value that was SET but unrecognised, so the caller
 * can fail loudly: unset legitimately means "China tenant" (the original deployment target and
 * the documented default), but an operator who typed something has an intent we cannot guess, and
 * guessing wrong means the bot is 100% dark. This mirrors how RUNTIME_ARN and REGION are treated
 * in index.ts — a wrong silent default there points the gateway at the wrong regional endpoint,
 * and this is the same class of mistake one layer out.
 */
export function resolveTenant(raw: string | undefined): FeishuTenant | null {
  if (raw === undefined || raw.trim() === "") return "feishu";
  const v = raw.trim().toLowerCase();
  return v === "feishu" || v === "lark" ? v : null;
}

/** The SDK domain for the event long-connection. */
export function wsDomainFor(tenant: FeishuTenant): lark.Domain {
  return tenant === "lark" ? lark.Domain.Lark : lark.Domain.Feishu;
}

/** The REST base URL for the same tenant. */
export function restBaseFor(tenant: FeishuTenant): string {
  return REST_BASES[tenant];
}
