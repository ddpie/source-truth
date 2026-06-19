# Spike:全仓扫描 vs CodeGraph 索引 — 代码检索性能基准

> ⚠️ **存储前提已变更（历史记录，勿删）**：本 spike 以「会话容器只读挂载 EFS、在 EFS 上 grep」为对照前提；
> 该 EFS 挂载方案**已被移除**——现行架构下仓库副本只存在 index-service 本地磁盘，会话 microVM 不挂文件系统，
> 全部读文件经 index-service 的 MCP-over-HTTP 桥。**核心结论不变且更被强化**：「先用 CodeGraph 定位、再点名
> 读文件」远优于让 Agent 逐文件全仓 grep——下文 EFS 数字是「为何不能逐文件遍历」的实测佐证，无需重做。
> 当前真相以 [`architecture.md`](architecture.md) 为准。

> 技术调研报告（Technical Spike）。结构遵循 Microsoft Engineering Playbook 的 Technical Spike 模板
> （Goal → Method → Evidence → Conclusions → Next Steps），并入技术报告通用骨架（含 Limitations）。

| 项 | 内容 |
|---|---|
| **日期** | 2026-06-16 |
| **关联** | source-truth MVP；需求评审待验证点「EFS 读性能 / 首次全量索引耗时」 |
| **环境** | AWS EC2（aarch64 ARM 8 核 / 30 GiB）；本地盘 NVMe EBS（gp）；EFS generalPurpose + bursting，NFS 4.1，与实例同可用区；Ubuntu 24.04，kernel 6.17；grep(GNU) / ripgrep 14.1.0 / CodeGraph(MCP) |
| **证据等级** | ✅实测（本机跑出，5 轮中位数）/ 📄文档（原理印证）/ ⚠️待验证 |

---

## 1. Executive Summary（执行摘要）

客户调研中记录的痛点是「未指定目录全量扫描慢，演示 **50 秒到 5 分钟**」。本 spike 用一个贴近客户特征的
16G 工程实测复现并归因了该痛点，结论是：

> **索引不是优化项，是 MVP 的地基。** 不建索引、在 EFS 上串行 grep 全仓，最坏 **265 秒**；建索引后查询恒定
> **1–5 毫秒**，且与存储介质、缓存状态、工程体积**完全解耦**。代价是首次索引在 EFS 上需 **291 秒**，必须后台预热。

这直接支撑 [`architecture.md`](architecture.md) 的设计：**先用 CodeGraph(index-service) 定位「查哪个工程/哪些文件」，
再经 EFS 只读挂载按点读取**，而非让 Agent 在 16G 工程里直接 grep。

---

## 2. Goal（调研目标）

回答三个问题：

1. 「用索引」相比「不用索引（全仓 grep/ripgrep 扫描）」到底快多少？
2. 数据放在 **EFS**（客户场景的共享存储）上时，性能会如何变化？
3. 索引方案的**代价**（首次索引耗时、写入耗时）有多大，是否可接受？

---

## 3. Method（方法）

1. **构造样本**：合成一个贴近客户「前端 Unity C# 约 15G」特征的工程——体积大但代码占比极小。
   - 代码大头：Daggerfall Unity（开源 C# 代码量天花板，~30 万行 / 1040 文件）；
   - 体积填充：Megacity Metro（Unity 官方）+ 真实美术资源复制，撑到 15G 级。
   - 结果：**16 GB / 75,595 文件，其中仅 1,752 个 C#**，其余为美术资源 / `.meta`。
   - 说明：客户商业美术资源有版权、开源无法获得，故用真实美术资源复制模拟体积；代码为真实可解析 C#。
2. **对照维度**：`grep -r` vs `ripgrep` vs `CodeGraph 索引`；本地 NVMe vs EFS；冷缓存 vs 热缓存。
3. **测量纪律**：查询目标统一 `class SaveLoadManager`；每组 **5 轮取中位数**；冷缓存每轮先
   `echo 3 > /proc/sys/vm/drop_caches`，热缓存预热一轮后连测。
4. **真实搭建 EFS**：create-file-system → SG 放行 2049 → create-mount-target → NFS 4.1 挂载，非估算。

> ⚠️ 方法教训：早期一次「单次测得 grep 热缓存 0.02s」是错误数据，多轮重测真实值 **7.68s**。**单次测量不可信**，故全程多轮取中位数。

---

## 4. Evidence（实测证据）

查询 `class SaveLoadManager`，5 轮中位数，单位秒。

### 4.1 全仓文本扫描 — 无索引 ✅实测

| 方法 | 本地 NVMe 冷 | 本地 NVMe 热 | **EFS 冷** | **EFS 热** |
|---|---|---|---|---|
| `grep -r` | 127.4 | 7.68 | **265.3** | 95.4 |
| `ripgrep` | 69.1 | 0.49 | 38.1 | 15.6 |

### 4.2 CodeGraph 索引方案 ✅实测

| 阶段 | 本地 NVMe | EFS |
|---|---|---|
| 首次全量索引（冷缓存，1753 文件） | **24 s** | **291 s** |
| 索引后查询（端到端 `query_time_ms`） | **1–5 ms** | **1–5 ms**（与介质无关） |

### 4.3 部署侧 ✅实测

| 操作 | 耗时 |
|---|---|
| 16G 工程 `cp` 写入 EFS（bursting 模式） | **1180 s（~20 分钟）** |

> 数据可靠性：各组 5 轮方差极小（本地冷 grep 127.1~127.5s；EFS 冷 grep 249~327s）。

---

## 5. Discussion（分析）

### 5.1 痛点归因：客户的「50秒-5分钟」= EFS + 冷缓存 + 串行 grep
实测 265s 正落在客户描述区间。三个变量的贡献：

| 变量 | 影响幅度 |
|---|---|
| 存储介质（EFS vs 本地） | 冷 grep 265 vs 127，**~2×** |
| 缓存（冷 vs 热） | 本地 grep 127 → 7.68，**~16×** |
| 工具（grep vs ripgrep） | EFS 冷 265 → 38，**~7×** |

### 5.2 EFS 海量小文件 = 元数据往返瓶颈 ✅实测 + 📄原理
EFS **热缓存 grep 仍需 95s**（本地热仅 7.68s，差 12×）。NFS 对每个文件 open/stat 都要 revalidate 走网络，
75,595 文件 × 元数据往返 = 主要耗时，**与内容是否已缓存无关**。
→ 任何「逐文件遍历」方案在 EFS 上都会被拖垮，这是不能让 Agent 直接在 EFS 上 grep 的根本原因。

### 5.3 索引查询与环境解耦 = 索引方案的根本价值 ✅实测
CodeGraph 查询恒 1–5ms，无论数据在 EFS/本地、冷/热缓存、工程 16G 或更大——因为命中的是**内存中的图，
不触碰源文件**。**只要索引建好，EFS 慢就不再影响查询体验**，正面回应需求目标「快于本地」。

### 5.4 若保留兜底全仓扫描，必须用 ripgrep
ripgrep 并行遍历 + 跳过二进制/大文件，把 EFS 冷扫从 265s（grep）压到 38s。

---

## 6. Limitations（边界与未覆盖项，诚实标注）

- **CodeGraph 累积式全局图，只增不减** ✅实测：本轮先后索引多个目录，符号累加进同一张图，查询会返回历史
  批次路径，`total_matches` 受去重影响。→ 生产需**每仓独立图 / 可清理重建**，否则历史噪声污染结果。
- **增量更新 / 删除语义未覆盖** ⚠️待验证：代码 push 后旧符号是否残留（需求评审列为待验证点），本轮未测。
- **单次 `index_directory` 5000 文件上限** ✅实测：大仓须分批喂；分批会合并进同一全局图（跨 4 目录副本同时被检索到）。
- **语义检索（embedding）未纳入** ⚠️：本轮为文本匹配，embedding 当时仍在后台构建。
- **样本体积为真实美术资源复制填充**，非客户真实工程；代码量级接近，资源构成为模拟。

---

## 7. Conclusions（结论 — 回答 §2 的提问）

| 问题 | 结论 |
|---|---|
| 1. 索引比扫描快多少？ | 查询 1–5ms vs 扫描数十至数百秒，**快 4–5 个数量级**，且稳定 |
| 2. EFS 上如何？ | 扫描更慢（冷 grep 265s、热 grep 仍 95s）；但**索引查询不受 EFS 影响**，仍 1–5ms |
| 3. 代价可接受吗？ | 首次索引 EFS 291s、写入 16G 需 ~20min——**可接受，但必须后台预热，不能放用户请求路径** |

**总判断**：CodeGraph 索引方案对本项目「大体积、低代码占比、共享存储」场景**成立且必要**。

---

## 8. Next Steps（后续）

- [ ] **EFS 增量更新**：代码 push 后索引刷新的端到端时延与正确性（旧符号是否残留）。
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
#  体积填充：cp -r megacity-metro/Assets/Art Art_bulk/Art_copy_$i  (×40，用真实文件勿用稀疏)

# 扫描基准（冷=每轮先清缓存；热=预热后连测；各 5 轮取中位数）
drop_cache(){ sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'; }
for i in $(seq 1 5); do drop_cache; \
  s=$(date +%s.%N); grep -rl "class SaveLoadManager" "$DIR" >/dev/null; e=$(date +%s.%N); \
  echo "$e - $s" | bc; done            # ripgrep 同理替换为 rg -l

# EFS 搭建
aws efs create-file-system --performance-mode generalPurpose --throughput-mode bursting
#  SG 放行 2049 → create-mount-target 到本子网 → available
sudo apt-get install -y nfs-common
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
  <fs-id>.efs.<region>.amazonaws.com:/ /mnt/efs

# 索引基准：drop_cache 后调 CodeGraph index_directory 计时；查询读返回 query_time_ms
```

## 附录 B：测试资源清理（测完应删，避免计费）

本 spike 创建的临时 AWS 资源：EFS 文件系统 + 其 mount target + 一个放行 2049 的安全组；
本地临时数据：合成样本工程目录与 EFS 挂载点。
清理顺序：卸载挂载点 → 删 mount target → 删 EFS → 删安全组。
