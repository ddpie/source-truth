# Spike：飞书 CardKit 流式卡片能否支撑「会生长的答案卡」

> 技术调研报告（Technical Spike）。结构遵循 Microsoft Engineering Playbook 的 Technical Spike 模板
> （Goal → Method → Evidence → Conclusions → Next Steps），并入技术报告通用骨架（含 Limitations）。

| 项 | 内容 |
|---|---|
| **日期** | 2026-06-16 |
| **关联** | source-truth MVP；核心体验「会生长的答案卡」；需求评审待验证点「飞书流式卡片频控 / 图表组件边界 / 动态组件回调路由」 |
| **环境** | 飞书自建应用（bot 身份）；CardKit v1 OpenAPI；lark-cli 1.0.x 作为 API 探针，与 `@larksuiteoapi/node-sdk` 调用同一组 `/open-apis/cardkit/v1` 端点；卡片实体在后台创建，客户端渲染在飞书桌面端与移动端核对 |
| **证据等级** | ✅实测（真实 API 返回 code / 错误码 + 客户端渲染）/ 📄文档（官方文档印证）/ ⚠️待验证 |

---

## 1. Executive Summary（执行摘要）

需求评审要求 MVP 的回答体验对标 GenSpark / 腾讯 WorkBuddy：卡片化、流式不刷屏、结论结构化、可附追问。本 spike 用真实 CardKit v1 接口验证整条「会生长的答案卡」生命周期，并把一张真实答案卡发到飞书客户端核对渲染。

> **「会生长的答案卡」在飞书现有能力内成立。** 同一张卡片可从「思考中→取证中→完成」全程流式更新、不发第二条消息；结论以打字机效果先呈现，依据折叠，完成后动态追加表格 / VChart 图表 / 一键追问等组件，桌面端与移动端均正常渲染（转研发按钮经验证平台同样支持，MVP 未启用，低置信度改由 agent 在正文文字建议）。代价是若干必须在网关层处理的硬约束（频控、10 分钟窗口、回调与流式互斥、整卡更新会清空正文）。

这直接支撑 [`architecture.md`](architecture.md) 的回传设计，确认「会生长的答案卡」可落地，不是纸面方案。完整接口约束、卡片 JSON 骨架、节流算法与回调路由见本文 §4 与附录。

---

## 2. Goal（调研目标）

回答四个问题：

1. 同一张卡片能否做到「流式打字机持续更新、过程不刷屏」，并在完成后**动态追加**结构化组件？
2. 策划要的**数据可视化（图表）**能否在客户端渲染？
3. **交互回调**（点按钮追问 / 转研发）的闭环是否成立，有何前置条件？
4. 落地时有哪些**硬约束**需要在网关层规避？

---

## 3. Method（方法）

1. **真实 API 探测**：用 lark-cli 以 bot 身份直接调 CardKit v1 接口，逐个验证生命周期动作的返回 code 与错误码。卡片实体在后台创建，不发送给任何人，零打扰。
2. **对照维度**：覆盖 `create`（建实体）、`PUT .../content`（流式打字机）、`POST .../elements`（追加组件）、`PATCH .../settings`（关流式）、整卡 `PUT`（全量更新）；组件覆盖 markdown、table、VChart chart、collapsible_panel、column_set + button。
3. **客户端渲染核对**：把一张完整答案卡（三消游戏「特殊棋子生成规则」场景，代码逻辑 × 配置数值结合）经 IM 发送至飞书客户端，在桌面端与移动端观察流式生长与最终形态。
4. **错误码优先**：每个动作以真实返回的 `code` 为准；文档推断与实测冲突时，以实测错误码为准。

> ⚠️ 方法教训：只依赖官方 SDK 的 TS 类型，或沿用 1.0 卡片经验编写 2.0 卡片，容易出错（如 `action` 容器已废弃、`elements` 须传序列化字符串）。这些问题只有真实调用才会暴露，因此全程以 API 返回为准。

---

## 4. Evidence（实测证据）

### 4.1 生命周期动作 ✅实测

| 动作 | 接口 | 结果 |
|---|---|---|
| 建卡片实体 | `POST /open-apis/cardkit/v1/cards` | `code:0`，返回 `card_id` |
| 流式更新文本 | `PUT .../elements/{id}/content`（content 传全量，sequence 递增） | `code:0`，前缀递增触发打字机续写 |
| 追加组件 | `POST .../elements`（insert_after / append） | `code:0` |
| 关流式 | `PATCH .../settings`（streaming_mode=false） | `code:0` |
| 整卡全量更新 | `PUT /cards/{id}`（card.{type,data}） | `code:0`，关流式后仍可用（含标题状态色变化） |

### 4.2 实测暴露的硬约束与错误码 ✅实测

| 约束 | 触发条件 | 错误码 |
|---|---|---|
| `streaming_config` 的 `print_frequency_ms` 与 `print_step` 必须成对 | 只给其一 | `11311` |
| 追加组件的 `elements` 必须是 JSON 序列化字符串，非数组对象 | 传数组 | `9499` |
| Schema 2.0 废弃 `action` 容器，按钮须直接作组件或包进 `column_set` | 用 `action` 包按钮 | `200861` |
| 关流式后文本不可再更新，但仍可追加组件 | 关流式后调 content | `300309`（追加 `POST elements` 仍 `code:0`）|
| 整卡全量 `PUT` 会替换整个 body | 只想改标题却只带空骨架 | 无报错但正文被清空（高危） |

### 4.3 客户端渲染 ✅实测

| 组件 | 桌面端 | 移动端 |
|---|---|---|
| 流式打字机文本 | 正常逐字 | 正常 |
| markdown 表格 | 正常 | 正常 |
| VChart 图表（柱状 / 折线） | 正常渲染 | 正常渲染 |
| collapsible_panel 折叠面板 | 正常展开/收起 | 正常 |
| column_set + button 按钮区 | 正常 | 正常 |
| 标题状态色（蓝→绿） | 正常 | 正常 |

> 数据可靠性：以上动作均经多次重发复现，返回稳定；客户端渲染在两类客户端各核对一次。

---

## 5. Discussion（分析）

**「会生长」靠两个机制叠加**：流式 `content` 更新让结论逐字呈现，完成后 `POST elements` 追加表格、图表、按钮等结构化组件。二者共用同一张卡片实体，全程不发第二条消息，对应 GenSpark「干净成品 + 过程可查」的体验。

**关流式后仍可追加组件**（§4.2）是关键结论：终态正确时序为「先关流式固定结论 → 再追加按钮区与折叠面板」。关流式同时消除聊天栏「生成中」预览、恢复卡片可转发。

**图表可在客户端渲染**（§4.3）直接回应策划的数值可视化诉求：数值类问题（掉率、关卡难度曲线）可在卡片内展示图表，而非只给文字。

**几个硬约束决定网关实现**：卡片更新有每秒 10 次实体级上限，流式 token 必须服务端节流合并再推；流式 10 分钟自动关窗，长任务须续期或转后台异步；处理交互回调前须先关流式，否则更新被拒；整卡全量更新会清空正文，仅改标题须带全部内容或改用局部更新。

---

## 6. Limitations（边界与未覆盖项，诚实标注）

- **交互回调闭环未端到端验证** ⚠️：本 spike 验证了按钮可带 callback 配置并正常渲染，但「点击 → 网关收 `card.action.trigger` → 路由 → 局部更新卡片」全链路依赖网关长连接在线，尚未在真实长连接上验证。
- **流式实际可用频率未压测** ⚠️：每秒 10 次为实体级上限，流式模式下是否真免除该限、节流窗口取多少最优（暂定 300 毫秒），未做压力测试。
- **10 分钟关窗续期机制未实测** ⚠️：临近 10 分钟主动续期是否刷新计时、超时后行为，未覆盖。
- **演示内容为构造数据**：客户端核对用的三消「特殊棋子」场景为构造的示例数据，验证的是卡片形态与交互，非真实问答取证。
- **VChart 表达边界未穷尽** ⚠️：仅验证柱状 / 折线基本图，临界线标注、动态数据绑定等具体能力边界未逐一测。

---

## 7. Conclusions（结论 — 回答 §2 的提问）

| 问题 | 结论 |
|---|---|
| 1. 流式不刷屏 + 完成追加组件？ | ✅ 成立。同一卡片流式更新 + 关流式后追加组件，全程不发第二条消息 |
| 2. 图表能否在客户端渲染？ | ✅ 能。VChart 柱状 / 折线在桌面端与移动端均正常 |
| 3. 交互回调闭环？ | 📄 按钮 callback 配置与渲染可行；端到端闭环依赖网关长连接，⚠️ 待落地验证 |
| 4. 有哪些硬约束？ | ✅ 已验证五条（频控、10 分钟窗口、回调与流式互斥、整卡更新清空正文、SDK 仅 v1），均可在网关层规避 |

**总判断**：飞书交互能力足以支撑「会生长的答案卡」核心体验，可作为 MVP 标准呈现形态。

---

## 8. Next Steps（后续）

- [ ] **交互回调闭环**：在网关长连接上验证 `card.action.trigger` 收取 → 按 action 路由 → 局部更新卡片。
- [ ] **流式频率压测**：实测流式模式下可用更新频率，敲定节流窗口。
- [ ] **10 分钟窗口续期**：验证续期与超时行为，确定长任务转后台异步的触发点。
- [ ] **VChart 边界**：测临界线标注、动态数据绑定等图表能力上限。
- [ ] **移动端窄屏降级**：复杂分栏 / 宽表在低版本客户端的降级表现与纯文本兜底。

---

## 附录 A：复现命令

```bash
# 1) 建卡（streaming_config 两子字段必须成对，否则 code 11311）
lark-cli api POST /open-apis/cardkit/v1/cards --as bot --data '{"type":"card_json","data":"{\"schema\":\"2.0\",\"config\":{\"update_multi\":true,\"streaming_mode\":true,\"streaming_config\":{\"print_frequency_ms\":{\"default\":30},\"print_step\":{\"default\":1},\"print_strategy\":\"fast\"}},\"header\":{\"title\":{\"tag\":\"plain_text\",\"content\":\"<标题>\"},\"template\":\"blue\"},\"body\":{\"elements\":[{\"tag\":\"markdown\",\"content\":\"\",\"element_id\":\"conclusion\"}]}}"}'

# 2) 流式更新（content 传全量、sequence 递增 → 打字机续写）
lark-cli api PUT /open-apis/cardkit/v1/cards/<CARD_ID>/elements/conclusion/content --as bot --data '{"content":"<全量文本>","sequence":1}'

# 3) 追加组件（elements 是 JSON 序列化字符串；按钮用 column_set 包，勿用已废弃的 action）
lark-cli api POST /open-apis/cardkit/v1/cards/<CARD_ID>/elements --as bot --data '{"type":"append","sequence":8,"elements":"[{\"tag\":\"column_set\",\"columns\":[<button...>]}]"}'

# 4) 关流式（关后 content 不可改，但仍可追加组件）
lark-cli api PATCH /open-apis/cardkit/v1/cards/<CARD_ID>/settings --as bot --data '{"settings":"{\"config\":{\"streaming_mode\":false}}","sequence":9}'
```

> 探针说明：lark-cli 仅用于真实 API 验证（与 node-sdk 调用同一组端点，契约通用）；生产实现在 bot-gateway 走 node-sdk `client.request`，统一调用 `/open-apis/cardkit/v1` path（SDK 无 cardkit.v2）。

## 附录 B：测试资源清理

本 spike 仅在飞书后台创建若干临时卡片实体，未持久化、未占用云计费资源；卡片实体 14 天自动过期，无需手动清理。无本地或 AWS 资源遗留。
