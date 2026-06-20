# 设计权威依据（design）

本目录是 source-truth 的**需求与架构权威依据**：需求评审纪要、POC 架构方案，以及一份组件设计概览。
当代码 / 实现文档与这里冲突时，按 [`AGENTS.md`](../../AGENTS.md) 的「代码为唯一依据」——以代码为准并标注差异；
但**做什么、为什么这么做、MVP 边界在哪里**，以本目录为准。

> **语言：仅中文，暂不翻译。** 本目录文档不参与 `docs/` 的 `_zh`/`_en` 双语配对
> （配对校验只作用于顶层 `docs/*_{zh,en}.md`，见 [`../agent/invariants.md`](../agent/invariants.md) §4）。

## 文档一览

| 文档 | 是什么 |
|------|--------|
| [`requirements_zh.md`](requirements_zh.md) | 需求与方案评审纪要：背景、MVP 边界、验收基准 |
| [`architecture-overview_zh.md`](architecture-overview_zh.md) | POC 架构方案：系统形态、组件分工、技术选型 |
| [`agent-container_zh.md`](agent-container_zh.md) | agent-container 组件设计概览（面向人工阅读） |
| [`multi-repo-isolation_zh.md`](multi-repo-isolation_zh.md) | 多项目 / 多仓的索引与隔离设计（post-MVP，先写文档，不改代码） |

## 与其他文档的关系

设计文档回答「做什么 / 为什么」，AI 面向文档回答「一次提问如何在系统里流转 / 改代码时不能破坏什么」：

- 一次提问的生命周期、数据面、会话隔离 → [`../agent/architecture.md`](../agent/architecture.md)（面向 AI 的工作原理）
- 可执行的不变量与权威依据映射 → [`../agent/invariants.md`](../agent/invariants.md)
- 常见改动的操作手册 → [`../agent/playbooks.md`](../agent/playbooks.md)
- 从零部署 / 连飞书 / 运维 / 排错 → [`../runbook.md`](../runbook.md)

全部文档入口见 [`../README.md`](../README.md)。
