# config

配置驱动的文案与阈值（JSON），与代码分离便于运维调整。

- `i18n.json`：CardKit 卡片用户可见文案的多语言包。默认 `zh`，`LOCALE` 环境变量可切到
  `en`（或其它已配置 locale）。bot-gateway 启动时用 `initI18n()` 加载；缺 key 时返回 key 本身并告警，不中断启动。
  zh/en 必须 key 对齐（由 `bot-gateway/tests/i18n.test.ts` 的 parity 用例守卫）。**不包含** agent 在答案文本里
  输出、由网关解析的 marker（供研发复核 / 你可能还想问 / 需要你确认）——这些属于
  `agent-container/prompts/system.md` 的契约，翻译会破坏抽取。
- `alarm-thresholds.json`（p1，未实现）：告警阈值默认配置。
