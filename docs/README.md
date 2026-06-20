# 文档地图

source-truth 的文档按**受众**分层：每类读者从自己的入口进，不必通读全部。
项目整体介绍与高频入口见根 [`README.md`](../README.md)；本页是完整索引。

## 给所有人（先读这些）

| 文档 | 什么时候读 |
|------|-----------|
| [`../README.md`](../README.md) | 第一次了解项目：它是什么、一次问答如何发生、MVP 边界 |
| [`runbook.md`](runbook.md) | 要部署并验证系统：前置 → 一键部署 → 连飞书 → 起网关 → 验证 → 运维 → 排错 |
| [`structure_zh.md`](structure_zh.md) · [`structure_en.md`](structure_en.md) | 想知道某个模块在哪：权威目录树（双语） |

## 给改代码的人 / AI agent

| 文档 | 什么时候读 |
|------|-----------|
| [`../AGENTS.md`](../AGENTS.md) | 动手前必读：项目约定、代码风格、边界、commit/PR 规范 |
| [`agent/architecture.md`](agent/architecture.md) | 改请求流转 / 取证 / 卡片回传 / 会话隔离前：一次提问如何在系统里流转 |
| [`agent/invariants.md`](agent/invariants.md) | 改代码前对照：7 条可执行不变量（是什么 / 以谁为准 / 怎么自动检查 / 违反后果） |
| [`agent/playbooks.md`](agent/playbooks.md) | 做某类具体改动时：7 个变更配方（改哪 / 怎么验 / 怎么上线） |

## 设计权威依据（做什么 / 为什么）

[`design/`](design/README.md) —— 需求与架构权威依据（仅中文，暂不翻译）。
回答「为什么这么设计、MVP 边界划在哪」，详见 [`design/README.md`](design/README.md)。

## 调研记录（spike）

定型某个技术选择前的实测与论证，按需查阅：

| 文档 | 结论 |
|------|------|
| [`agent/cardkit-streaming-spike.md`](agent/cardkit-streaming-spike.md) | CardKit「会生长的答案卡」流式更新可行性 |
| [`agent/indexing-performance-spike.md`](agent/indexing-performance-spike.md) | 为何必须建索引：全仓冷扫 grep vs 索引查询基准 |
| [`agent/efs-codegraph-sharing-spike.md`](agent/efs-codegraph-sharing-spike.md) | 代码副本与共享存储方案选型 |
| [`agent/perf-comparison.md`](agent/perf-comparison.md) | source-truth vs 原生 Claude Code 的耗时对比 |
| [`agent/TEMPLATE-spike.md`](agent/TEMPLATE-spike.md) | 写新调研记录的模板 |
