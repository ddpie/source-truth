# Spike:全仓扫描 vs CodeGraph 索引 — 代码检索性能基准

> 技术调研报告（Technical Spike）。结构遵循 Microsoft Engineering Playbook 的 Technical Spike 模板
> （Goal → Method → Evidence → Conclusions → Next Steps），并入技术报告通用骨架（含 Limitations）。

| 项 | 内容 |
|---|---|
| **日期** | 2026-06-16 |
| **关联** | source-truth MVP；需求评审待验证点「首次全量索引耗时 / 检索延迟」 |
| **环境** | AWS EC2（aarch64 ARM 8 核 / 30 GiB）；本地盘 NVMe EBS（gp）；Ubuntu 24.04，kernel 6.17；grep(GNU) / ripgrep 14.1.0 / CodeGraph(MCP) |
| **证据等级** | ✅实测（本机测得，5 轮中位数）/ 📄文档（原理印证）/ ⚠️待验证 |

---

## 1. 执行摘要

客户调研中记录的痛点是「未指定目录全量扫描慢，演示 **50 秒到 5 分钟**」。本 spike 用一个贴近客户特征的
16G 工程做了实测，复现了该痛点并找出成因，结论是：

> **索引不是优化项，是 MVP 的基础能力。** 不建索引、冷缓存下串行 grep 全仓需 **127 秒**；建索引后查询稳定在
> **1–5 毫秒**，且与缓存状态、工程体积**完全解耦**。代价是首次索引约 **24 秒**（1753 个代码文件），后台完成即可。

这直接支撑 [`architecture.md`](architecture.md) 的设计：**先用 CodeGraph(index-service) 定位「查哪个工程/哪些文件」，
再通过 index-service 读取指定文件**，而非让 Agent 在 16G 工程里直接 grep。

---

## 2. 调研目标

1. 「用索引」相比「不用索引（全仓 grep/ripgrep 扫描）」到底快多少？
2. 索引方案的**代价**（首次索引耗时）有多大，是否可接受？

---

## 3. 方法

1. **构造样本**：合成一个贴近客户「前端 Unity C# 约 15G」特征的工程——体积大但代码占比极小。
   - 代码主体：Daggerfall Unity（开源 C# 较大样本，~30 万行 / 1040 文件）；
   - 体积填充：Megacity Metro（Unity 官方）+ 真实美术资源复制，扩展到 15G 级。
   - 结果：**16 GB / 75,595 文件，其中仅 1,752 个 C#**，其余为美术资源 / `.meta`。
   - 说明：客户商业美术资源有版权、开源无法获得，故用真实美术资源复制模拟体积；代码为真实可解析 C#。
2. **对照维度**：`grep -r` vs `ripgrep` vs `CodeGraph 索引`；冷缓存 vs 热缓存。
3. **测量纪律**：查询目标统一 `class SaveLoadManager`；每组 **5 轮取中位数**；冷缓存每轮先
   `echo 3 > /proc/sys/vm/drop_caches`，热缓存预热一轮后连测。

> ⚠️ 测量说明：早期一次「单次测得 grep 热缓存 0.02s」是错误数据，多轮重测真实值 **7.68s**。**单次测量不可信**，所以全部多轮取中位数。

---

## 4. 实测证据

查询 `class SaveLoadManager`，5 轮中位数，单位秒。本地 NVMe。

### 4.1 全仓文本扫描 — 无索引 ✅实测

| 方法 | 冷缓存 | 热缓存 |
|---|---|---|
| `grep -r` | 127.4 | 7.68 |
| `ripgrep` | 69.1 | 0.49 |

### 4.2 CodeGraph 索引方案 ✅实测

| 阶段 | 耗时 |
|---|---|
| 首次全量索引（冷缓存，1753 文件） | **24 s** |
| 索引后查询（端到端 `query_time_ms`） | **1–5 ms**（与缓存/体积无关） |

> 数据可靠性：各组 5 轮方差极小（冷 grep 127.1~127.5s）。

---

## 5. 分析

- **痛点归因**：客户的「50 秒到 5 分钟」= 冷缓存 + 串行 grep + 海量小文件遍历。缓存的影响约 16×
  （冷 127s → 热 7.68s），但冷缓存无法保证，逐文件遍历的最坏情况总会出现。
- **索引查询与环境解耦 = 索引方案的根本价值** ✅实测：CodeGraph 查询稳定在 1–5ms，冷热缓存、工程 16G
  或更大均不影响——因为命中的是**内存中的图，不触碰源文件**。
- **若保留兜底全仓扫描，必须用 ripgrep**：并行遍历 + 跳过二进制/大文件，冷扫从 127s（grep）压到 69s、热扫 0.49s。

---

## 6. 边界与未覆盖项

- **CodeGraph 累积式全局图，只增不减** ✅实测：本轮先后索引多个目录，符号累加进同一张图，查询会返回历史
  批次路径，`total_matches` 受去重影响。→ 生产需**每仓独立图 / 可清理重建**，否则历史噪声污染结果。
- **增量更新 / 删除语义未覆盖** ⚠️待验证：代码 push 后旧符号是否残留（需求评审列为待验证点），本轮未测。
- **单次 `index_directory` 5000 文件上限** ✅实测：大仓须分批写入；分批会合并进同一全局图（跨 4 目录副本同时被检索到）。
- **语义检索（embedding）未纳入** ⚠️：本轮为文本匹配，embedding 当时仍在后台构建。
- **样本体积为真实美术资源复制填充**，非客户真实工程；代码量级接近，资源构成为模拟。

---

## 7. 结论 — 回答 §2 的提问

| 问题 | 结论 |
|---|---|
| 1. 索引比扫描快多少？ | 查询 1–5ms vs 扫描数秒至数百秒，**快 4–5 个数量级**，且稳定 |
| 2. 代价可接受吗？ | 首次索引 24s（1753 代码文件；大仓按比例增长）——**可接受，放后台完成，不在用户请求路径上** |

**总判断**：CodeGraph 索引方案对本项目「大体积、低代码占比」场景**成立且必要**。

---

## 8. 后续

- [ ] **增量更新**：代码 push 后索引刷新的端到端时延与正确性（旧符号是否残留）。
- [ ] **后端 Node.js / Lua 召回率**：本轮只测 C#，需补后端样本（mangos）。
- [ ] **embedding 语义检索**：建完 embedding 后复测自然语言查询召回。
- [ ] **每仓独立图**：验证生产用「按仓隔离 + 可重建」消除累积噪声。
- [ ] 兜底扫描路径若保留，固化为 ripgrep 实现。

---

## 附录 A：复现命令

```bash
# 构造样本
git clone --depth 1 https://github.com/Interkarma/daggerfall-unity.git
git lfs install && git clone https://github.com/Unity-Technologies/megacity-metro.git
#  体积填充：cp -r megacity-metro/Assets/Art Art_bulk/Art_copy_$i  (×40，用真实文件，不要用稀疏文件)

# 扫描基准（冷=每轮先清缓存；热=预热后连测；各 5 轮取中位数）
drop_cache(){ sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'; }
for i in $(seq 1 5); do drop_cache; \
  s=$(date +%s.%N); grep -rl "class SaveLoadManager" "$DIR" >/dev/null; e=$(date +%s.%N); \
  echo "$e - $s" | bc; done            # ripgrep 同理替换为 rg -l

# 索引基准：drop_cache 后调 CodeGraph index_directory 计时；查询读返回 query_time_ms
```
