/**
 * 告警 filter 与真实发射值的对齐。
 *
 * 为什么需要这一层：metric filter 住在 JSON 里，发射点住在 TypeScript 里，两边各自都有测试，
 * 而它们之间没有任何东西。第七轮审计正是在这条缝里找到两条互相冲突的修复：
 *
 *   - 早前一轮给 metric 加了枚举白名单（防止 `any` 调用点把自由文本当维度泄出去），白名单按
 *     **字段名** `reason` 生效；
 *   - 另一轮加了 `event_dropped`，它的 reason 词表完全不同。
 *
 * 结果是所有丢弃原因被改写成 `unknown`：专为「100% 消息丢失」而建的 EventDroppedUnparseable
 * 永远匹配不到，而 EventDroppedGate 反而匹配了它明确排除的重投场景，每次部署都会误报。
 * 两轮单独验证都看不出来，因为 `log()` 路径没有白名单——Logs Insights 里 reason 一直是对的。
 *
 * 所以这里断言的是端到端：拿真实发射出来的那行 JSON，去跑 filter 的判定条件。
 */
import { emitMetric, type DropReason } from "../src/metrics";
import * as fs from "fs";
import * as path from "path";

type FilterDef = { name: string; filterPattern: string; event: string };

const DEFS: FilterDef[] = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, "../../infra/monitoring/queries/metric-filters/alarm-metrics.json"),
    "utf8",
  ),
).metrics;

function defFor(name: string): FilterDef {
  const d = DEFS.find((f) => f.name === name);
  if (!d) throw new Error(`filter ${name} 不存在——它被改名或删除了，本测试的前提不成立`);
  return d;
}

/**
 * 把 CloudWatch 的 JSON filter pattern 按本仓用到的子集求值：`$.f IS TRUE`、`$.f = "v"`、
 * `$.f != "v"`，以 `&&` 连接。故意只支持这个子集——出现别的语法就抛错，而不是悄悄放过一条
 * 本测试实际没有验证的 filter。
 */
function matches(pattern: string, line: Record<string, unknown>): boolean {
  const body = pattern.trim().replace(/^\{/, "").replace(/\}$/, "").trim();
  return body.split("&&").every((raw) => {
    const term = raw.trim();
    let m = /^\$\.([A-Za-z0-9_]+)\s+IS\s+TRUE$/.exec(term);
    if (m) return line[m[1]] === true;
    m = /^\$\.([A-Za-z0-9_]+)\s*=\s*"(.*)"$/.exec(term);
    if (m) return line[m[1]] === m[2];
    m = /^\$\.([A-Za-z0-9_]+)\s*!=\s*"(.*)"$/.exec(term);
    if (m) return line[m[1]] !== m[2];
    throw new Error(`filter 语法未被本测试支持: ${term}`);
  });
}

/** 捕获 emitMetric 实际写到 stdout 的那一行。 */
function emitted(event: string, fields: Record<string, unknown>): Record<string, unknown> {
  const lines: string[] = [];
  const orig = console.log;
  console.log = (...args: unknown[]) => { lines.push(String(args[0])); };
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (emitMetric as any)(event, fields);
  } finally {
    console.log = orig;
  }
  const hit = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .find((o) => o && o.event === event);
  if (!hit) throw new Error(`emitMetric 没有产出 ${event} 行，实际输出: ${lines.join(" | ")}`);
  return hit as Record<string, unknown>;
}

describe("event_dropped: 发射值必须被白名单原样保留", () => {
  const ALL: DropReason[] = [
    "unparseable_event", "duplicate", "unsupported_type", "empty",
    "not_mentioned", "not_a_user", "self_message", "reply_to_unknown_card",
  ];

  it.each(ALL)("reason=%s 不被改写成 unknown", (reason) => {
    const line = emitted("event_dropped", { reason, projectId: "p1" });
    expect(line.reason).toBe(reason);
  });

  it("白名单之外的值仍然被替换（这层防护本身不能被削弱）", () => {
    const line = emitted("event_dropped", { reason: "some free text from a payload", projectId: "p1" });
    expect(line.reason).toBe("unknown");
  });
});

describe("EventDroppedUnparseable：只对解析失败告警", () => {
  it("解析失败会匹配", () => {
    const line = emitted("event_dropped", { reason: "unparseable_event", projectId: "p1" });
    expect(matches(defFor("EventDroppedUnparseable").filterPattern, line)).toBe(true);
  });

  it.each(["duplicate", "not_mentioned"] as DropReason[])("%s 不匹配", (reason) => {
    const line = emitted("event_dropped", { reason, projectId: "p1" });
    expect(matches(defFor("EventDroppedUnparseable").filterPattern, line)).toBe(false);
  });
});

describe("EventDroppedGate：门禁丢弃要告警，重投不要", () => {
  it("门禁丢弃会匹配（open_id 配错时群里 100% 流量被丢）", () => {
    const line = emitted("event_dropped", { reason: "not_mentioned", projectId: "p1" });
    expect(matches(defFor("EventDroppedGate").filterPattern, line)).toBe(true);
  });

  it("重投不匹配——否则每次部署后都误报，这正是它 purpose 里要避免的", () => {
    const line = emitted("event_dropped", { reason: "duplicate", projectId: "p1" });
    expect(matches(defFor("EventDroppedGate").filterPattern, line)).toBe(false);
  });

  it("解析失败不匹配（由专门的告警覆盖，避免同一故障两处响）", () => {
    const line = emitted("event_dropped", { reason: "unparseable_event", projectId: "p1" });
    expect(matches(defFor("EventDroppedGate").filterPattern, line)).toBe(false);
  });
});

describe("turn_finished / 心跳：既有 filter 的形状不能漂移", () => {
  it("outcome 不被白名单改写（它不是枚举字段）", () => {
    const line = emitted("turn_finished", { outcome: "text_fallback", projectId: "p1" });
    expect(line.outcome).toBe("text_fallback");
  });
});
