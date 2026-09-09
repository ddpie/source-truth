# evaluations — 自定义 AgentCore 评估器

本目录是**可选**的，不在部署必经路径上。机器人回答问题不需要它；它花的是另一类钱（Lambda 调用与运行时长，
加上 LLM-as-judge 每次判定的模型 token）；而且它需要一份已经跑过真实问答的遥测才有意义。

部署与排错的完整步骤见 runbook 附录 F（[中文](../docs/runbook_zh.md) / [English](../docs/runbook_en.md)）。
这里只讲**设计决定**。

`apply-evaluations.sh` 默认新建禁用的在线评估配置；重跑未指定启停或采样参数时保留已有值，
用 `--enable` / `--disable` 或 `--sampling` 显式调整。评委模型按区域解析。
`--project` 只选择代码型 Lambda 的回查项目，当前一个 Lambda 只连接一个 bridge，不能替所有项目评分。
详细命令、参数和这一限制见 runbook 附录 F。

## 先用内置的

`aws bedrock-agentcore-control list-evaluators` 会列出全部内置评估器（撰写时 31 个，含 DeepEval /
AutoEval 的第三方评估器）。质量、相关性、简洁性、连贯性、指令遵循、工具选择与参数、轨迹匹配、安全性
**都不要自己写**。和本项目最贴近的是 `Builtin.Faithfulness`：回答中的信息是否被提供的上下文支撑。

`evaluators.json` 里只有两个自定义评估器，而且每一条都必须能回答「为什么内置的办不到」。办得到的
就不该出现在这里。

## 两个评估器

### `SourceTruthCitationAccuracy`（代码型，TRACE 级）

把答案里每一条 `file:line` 拿回 bridge 提供的**同一份**仓库副本比对：文件是否存在、行号是否存在、
引用行附近是否出现答案声称的符号。

内置办不到的原因是输入而非能力：`Builtin.Faithfulness` 判的是答案与 agent **拿到的内容**是否一致，
LLM 评委看不到仓库。所以当检索环节返回了错误的行号、答案忠实地引用了它时，Faithfulness 会判
Completely Yes——这恰恰是本项目已确认存在的一类缺陷。

判据分三级，强度递减且互不冒充：文件存在 → 行号存在 → 引用行附近有声称的符号。第三级需要答案里有
反引号标出的标识符；**没有可检查的标识符时返回 `Unverified`，绝不返回 `Pass`**。一个在无输入时报成功
的检查，和一个坏掉的检查产出的绿灯无法区分。

刻意**不**做的判断：「这个文件 agent 没用 `read_file` 读过」不计失败。`search_files` 的结果不在 span 里
（span 只有 `output.mime_type`，工具结果的值不落盘），所以一条出处完全可能来自搜索结果。判它失败会
制造大量假失败，而假失败会让整批评估数据失去意义。这类情况只写进 `explanation` 供人参考。

「评估器自己出错」与「答案有问题」严格分开：bridge 不可达或读取途中失败返回 `errorCode` 加非评分
label `EvaluatorError`，不返回 `Fail`。一次基础设施中断若被记成 `Fail`，评估数据里就会留下一条永久且
错误的「答案引用不成立」。

### `SourceTruthEvidenceDiscipline`（LLM-as-judge，TRACE 级）

判断答案是否留在证据之内：有源码依据的具体结论，或明说「仓库里没有这个东西」；并惩罚那些听起来完全
合理、符合该游戏/引擎通识、但并非来自本仓库源码的内容。

内置办不到的原因是一个语义反转：`Builtin.Refusal` 把「回避 / 拒答」当作负面指标，而对本机器人来说，
仓库确实没有被问到的东西时明说「代码里没有」就是**正确**答案。这个反转无法通过配置内置评估器解决。

它也比 Faithfulness 严格：Faithfulness 只看答案与上下文是否矛盾，而这里要抓的失败与上下文并不矛盾
——上下文里根本没提那件事。

## 三个实现约定

**判据模块只有一份副本**，在 `../index-service/citation_verify.py`，由 `apply-evaluations.sh` 在打包时
复制进 Lambda。不在两处各存一份：漂移的那天，评估器和线上服务会对「什么算合法出处」悄悄产生分歧。

**用官方装饰器**（`bedrock_agentcore.evaluation.custom_code_based_evaluators`）而不是自己解 Lambda
事件 dict。那份契约由服务端定义并会演进——官方文档此刻写的模块名就已经和 SDK 里的真实路径不一致。
版本与 `agent-container` 保持一致，不给这个 sample 引入第二个 SDK 版本。

**打包必须在容器里做。** `pydantic` 带 `pydantic-core` 二进制轮子，本机 pip 装出来的包在 Lambda 上
可能直接 import 失败，而那种失败只在真正评估时暴露、并以「评估器故障」的形式污染评估数据。
`apply-evaluations.sh` 用 Lambda 官方基础镜像按 `linux/arm64` 构建并验证 import，
x86 部署机需要 ARM64 仿真；import 不过就拒绝上传。

## 本地跑判据

不部署也能对答案文本跑校验（需要本机有仓库副本）：

```bash
cd ../index-service
python3 verify_citations_cli.py --repo-root /path/to/repo < answer.txt
python3 verify_citations_cli.py --repo-root /path/to/repo --jsonl < answers.jsonl
```
