# config

配置驱动的文案与阈值（JSON），与代码分离便于运维调整。

- `i18n.json`：CardKit 卡片用户可见文案的多语言包。默认 `zh`，`LOCALE` 环境变量可切到
  `en`（或其它已配置 locale）。bot-gateway 启动时用 `initI18n()` 加载；缺 key 时返回 key 本身并告警，不中断启动。
  zh/en 必须 key 对齐（由 `bot-gateway/tests/i18n.test.ts` 的 parity 用例守卫）。**不包含**答案里的交互 marker（供研发复核 /
  你可能还想问 / 需要你确认）——这些 marker 由 agent 写在答案文本里、再由网关解析，属于
  `agent-container/prompts/system.md` 的契约，翻译它们会破坏网关对 marker 的解析。
- `alarm-thresholds.json`：CloudWatch 告警阈值，运维可调。改阈值后重跑 `scripts/apply-monitoring.sh --only alarms` 即生效，无需改代码（渲染逻辑见 `scripts/lib/render_alarms.py`）。
- `projects.example.json`：多项目路由清单（`port` / `feishuSecretId` / `repos`）的 schema 示例；真实配置写在 `.local/projects.json`（不入库，由 `install.sh` 的「添加项目」生成）。字段说明见文件内 `_doc`。
