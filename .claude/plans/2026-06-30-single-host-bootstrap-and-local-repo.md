# 单台 EC2 自举 + 本地仓接入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 source-truth 能在客户手动开的单台 ARM64 EC2 上自举部署（省掉临时跳板机），并支持「本地仓经 rsync 直推 + 手动重建」与现有「git 仓自动刷新」两种代码来源同项目混用。

**Architecture:** 两部分。Part 1（本地仓接入）给 manifest schema 加可选 `source` 字段（缺省 `git`），host 侧 `activate_project.sh` 据此分流——`local` 跳过 git_fetch 与 refresh timer，只建图 + 起 bridge；新增客户机侧 `push-local-repo.sh`（rsync 到暂存目录）+ host 侧 `reindex_local_repo.sh`（停 bridge→本地同步→build→起 bridge，遵守单写者）。Part 2（单台自举）给 `deploy-all.sh` 加 `--local` 模式：复用本机 VPC/子网、新建专用 SG、本机幂等跑 `bootstrap.sh`、本机 build/push 镜像；AgentCore Runtime 仍由 boto3 托管创建。

**Tech Stack:** Bash、Python 3、systemd、AWS CLI v2（EC2/S3/SSM/Secrets Manager/IMDSv2）、Docker buildx（ARM64）、rsync over SSH。

## Global Constraints

- 会话容器 / 索引主机 **ARM64-only**；Ubuntu 24.04（glibc ≥ 2.38）。
- **单写者铁律（不变量2）**：每个 repo 一个 graph.db；常驻 bridge 进程在其整个生命周期**持有** `/data/repo/<subdir>/.codegraph/.writer.lock` flock；`index-build@` 用 `flock -n` 抢同一把锁——**所以任何重建前必须先停该项目 bridge**（见 `activate_project.sh` 的 stop→build→start 序列，约 169 行）。
- **代码为唯一依据**：本地仓是「手动推送的快照」，非持续最新主干——push 脚本须写快照时间标记，invariants 须同步标注 local 例外。
- **生成物绝不手改**；改顶层目录或脚本清单 ⇒ 同步 `docs/structure_zh.md` 与 `_en.md`；改 schema ⇒ 同步 `config/projects.example.json`。
- **MVP 边界**：仅只读问答；AgentCore Runtime 保持 AWS 托管。
- Commit 用英文、Conventional Commits 前缀；**不加任何 AI 署名 trailer**。
- 离线测试入口 `./scripts/test.sh`；结构自检 `./scripts/check-invariants.sh`。
- `source` 字段枚举：`"git"`（缺省）| `"local"`；`local` 仓无 `git`/`ref`/`refreshIntervalSec`。
- subdir 正则 `\A[a-z0-9][a-z0-9-]*\Z`（已有，沿用）；subdir 全局唯一（跨项目）。该正则是 push 远程命令拼接的**唯一注入防线，严禁放宽**。

---

# Part 1 — 本地仓接入

> Part 1 自成可发布单元：schema 与分流是纯逻辑，可离线测试；push/reindex 脚本可在不动 Part 2 的前提下对现有部署使用。

### Task 1: manifest schema 接纳 `source` 字段 + 同步 schema 模板

**Files:**
- Modify: `scripts/lib/render_manifest.py`（`parse_manifest` 73-87 行；`build_multi_manifest` 158-163 行；`REPO_FIELDS` 207 行 + main 内同名 207 行；模块 docstring 9-23 行）
- Modify: `config/projects.example.json`（`_doc` 注释 + 加一个 local 仓示例）
- Test: `scripts/tests/test_manifest.sh`（追加用例）

**Interfaces:**
- Produces: `parse_manifest(raw)` 每条 repo dict 新增键 `"source"`（`"git"`|`"local"`，缺省 `"git"`）；local 仓 `git==""`。`build_multi_manifest` 透传 `source`，对 git 仓要求 git URL、对 local 仓忽略 git。`--repo-field source <subdir>` 与 `--field source` 可用。
- Consumes（既有）：`SUBDIR_RE`、`_validate_top`、`serve_args`。

- [ ] **Step 1: 写失败测试**

在 `scripts/tests/test_manifest.sh` 的汇总 echo 之前追加：

```bash
# --- source: local omits git + ref; defaults to git when absent ---
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"localrepo","source":"local"}]}'
out="$(python3 "$R" "$TMP/m.json" 2>"$TMP/err")"; rc=$?
check "local-source repo parses without git (rc 0)" "$rc"
printf '%s' "$out" | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); assert r["source"]=="local" and r["git"]=="", r'; check "local repo: source=local, git empty" $?

mk '{"projectId":"p","port":8080,"repos":[{"subdir":"g","git":"https://x/g.git"}]}'
printf '%s' "$(python3 "$R" "$TMP/m.json")" | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); assert r["source"]=="git", r'; check "absent source defaults to git" $?

mk '{"projectId":"p","port":8080,"repos":[{"subdir":"g","source":"git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>&1; rc=$?; [[ "$rc" -ne 0 ]]; check "git source without git url rejected" $?

mk '{"projectId":"p","port":8080,"repos":[{"subdir":"g","source":"svn","git":"x"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>&1; rc=$?; [[ "$rc" -ne 0 ]]; check "unknown source value rejected" $?

mk '{"projectId":"p","port":8080,"repos":[{"subdir":"loc","source":"local"}]}'
[[ "$(python3 "$R" --repo-field source loc "$TMP/m.json")" == "local" ]]; check "--repo-field source prints local" $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_manifest.sh`
Expected: 新增用例 FAIL。

- [ ] **Step 3: 改 `render_manifest.py`**

把 `parse_manifest` 循环里（73-86 行）：

```python
        git = r.get("git")
        if not isinstance(git, str) or not git.strip():
            raise ValueError(f"{where}: 'git' must be a non-empty git URL (R1: code source is git-only)")
        ref = r.get("ref")
        if ref is not None and not isinstance(ref, str):
            raise ValueError(f"{where}: 'ref' must be a string if present")
        sig = r.get("sig")
        if sig is not None and not isinstance(sig, str):
            raise ValueError(f"{where}: 'sig' must be a string if present")
        interval = r.get("refreshIntervalSec")
        if interval is not None and not isinstance(interval, int):
            raise ValueError(f"{where}: 'refreshIntervalSec' must be an integer seconds if present")
        out.append({"subdir": subdir, "git": git, "ref": ref or "", "sig": sig or "",
                    "refreshIntervalSec": interval})
```

替换为：

```python
        source = r.get("source", "git")
        if source not in ("git", "local"):
            raise ValueError(f"{where}: 'source' must be 'git' or 'local' (got {source!r})")
        git = r.get("git")
        if source == "git":
            if not isinstance(git, str) or not git.strip():
                raise ValueError(f"{where}: 'git' must be a non-empty git URL for a git-source repo")
        else:  # local: pushed via rsync (push-local-repo.sh), no git remote
            if git is not None and not isinstance(git, str):
                raise ValueError(f"{where}: 'git' must be a string if present")
            git = ""
        ref = r.get("ref")
        if ref is not None and not isinstance(ref, str):
            raise ValueError(f"{where}: 'ref' must be a string if present")
        sig = r.get("sig")
        if sig is not None and not isinstance(sig, str):
            raise ValueError(f"{where}: 'sig' must be a string if present")
        interval = r.get("refreshIntervalSec")
        if interval is not None and not isinstance(interval, int):
            raise ValueError(f"{where}: 'refreshIntervalSec' must be an integer seconds if present")
        out.append({"subdir": subdir, "source": source, "git": git, "ref": ref or "",
                    "sig": sig or "", "refreshIntervalSec": interval})
```

`build_multi_manifest`（158-163 行）entry 构造改为：

```python
    for r in repos:
        src = r.get("source", "git")
        entry = {"subdir": r["subdir"], "source": src}
        if src == "git":
            entry["git"] = r["git"]
            entry["ref"] = r.get("ref") or ""
        iv = r.get("refreshIntervalSec")
        entry["refreshIntervalSec"] = iv if isinstance(iv, int) else default_interval
        out_repos.append(entry)
```

`REPO_FIELDS`（207 行）改为 `("subdir", "source", "git", "ref", "sig", "refreshIntervalSec")`。更新 docstring 的 Manifest shape 段，注明 `source` 可选（`git`|`local`，缺省 `git`），local 仓无 git/ref，经 push-local-repo.sh 推送。

- [ ] **Step 4: 同步 `config/projects.example.json`**

`_doc` 里把 `repos: [ { subdir, git, ref?, refreshIntervalSec? }, ... ]` 改为 `repos: [ { subdir, source?(git|local), git(git源必填), ref?, refreshIntervalSec? }, ... ]`；把 `Code source is git-only (R1)` 一句改为说明「git 源自动定时刷新；local 源经 scripts/push-local-repo.sh 手动推送的快照」。在 `harbor` 项目的 repos 里加一个 local 示例条目：

```json
        { "subdir": "harbor-local", "source": "local" }
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash scripts/tests/test_manifest.sh && python3 -c "import json;json.load(open('config/projects.example.json'))"`
Expected: 全 ok；示例 JSON 合法。

- [ ] **Step 6: 提交**

```bash
git add scripts/lib/render_manifest.py scripts/tests/test_manifest.sh config/projects.example.json
git commit -m "feat(manifest): accept optional repo source field (git|local)"
```

---

### Task 2: `activate_project.sh` 按 source 分流

**Files:**
- Modify: `index-service/activate_project.sh`（顶部加纯函数；92-142 行 per-repo 循环；205-207 行 enable timers 循环）
- Test: `scripts/tests/test_activate_branch.sh`

**Interfaces:**
- Consumes: `render_manifest.py --repo-field source <subdir> <manifest>`（Task 1）。
- Produces: `source==local` 的 subdir 不调 `git_fetch.sh`、不写/不 enable `index-refresh-<subdir>.{service,timer}`；仍 mkdir graph 目录、纳入 `BUILD_UNITS`/`SERVE_FLOCKS`、跑 `index-build@`、纳入 bridge serve。要求 `/data/repo/<subdir>` 已被 push 填充，否则 fail-loud。`repo_uses_git <source>`：rc 0 = git（缺省），非 0 = local。

- [ ] **Step 1: 写失败测试**

新建 `scripts/tests/test_activate_branch.sh`：

```bash
#!/usr/bin/env bash
# test_activate_branch.sh — the source-aware branch helper in activate_project.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_activate_branch:"

# Extract the helper (multi-line def, closing brace on its OWN line at column 0).
HELPER="$(sed -n '/^repo_uses_git() {$/,/^}$/p' "$ROOT/index-service/activate_project.sh")"
[[ -n "$HELPER" ]]; check "repo_uses_git helper extractable" $?
eval "$HELPER"

repo_uses_git git;   rc=$?; [[ $rc -eq 0 ]]; check "git source uses git" $?
repo_uses_git "";    rc=$?; [[ $rc -eq 0 ]]; check "empty source defaults to git" $?
repo_uses_git local; rc=$?; [[ $rc -ne 0 ]]; check "local source does NOT use git" $?

[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_activate_branch.sh`
Expected: FAIL —— helper 不存在。

- [ ] **Step 3: 改 `activate_project.sh`**

在脚本顶部（`source /etc/index-service.env` 之后、`APP=` 定义附近）加入**多行**函数（`}` 独占一行、顶格——测试靠此抽取）：

```bash
# repo_uses_git <source>: rc 0 if this repo is fetched via git (default), non-zero for local.
# Local repos are pushed to /data/repo/<subdir> out-of-band (scripts/push-local-repo.sh) and
# refreshed manually — no git_fetch, no refresh timer.
repo_uses_git() {
  [ "${1:-git}" != "local" ]
}
```

per-repo 循环里把（95-104 行）：

```bash
  GIT_URL="$(python3 "$RENDER_MANIFEST" --repo-field git "$SUBDIR" "$MANIFEST")" \
    || { echo "ACTIVATE_FAILED: no git url for $SUBDIR"; exit 1; }
  GIT_REF="$(python3 "$RENDER_MANIFEST" --repo-field ref "$SUBDIR" "$MANIFEST" || echo "")"
  IV="$(python3 "$RENDER_MANIFEST" --repo-field refreshIntervalSec "$SUBDIR" "$MANIFEST" 2>/dev/null || echo "")"
  [ -n "$IV" ] && [ "$IV" != "None" ] || IV=300

  bash "$GIT_FETCH" "$SUBDIR" "$GIT_URL" "$GIT_REF" "$WS" \
    || { echo "ACTIVATE_FAILED: git fetch $SUBDIR"; exit 1; }
  # graph dirs INSIDE $WS (proven layout); created after clone, git-untracked so reset --hard keeps them.
  mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"
```

替换为：

```bash
  SRC="$(python3 "$RENDER_MANIFEST" --repo-field source "$SUBDIR" "$MANIFEST" 2>/dev/null || echo git)"
  [ -n "$SRC" ] && [ "$SRC" != "None" ] || SRC=git
  if repo_uses_git "$SRC"; then
    GIT_URL="$(python3 "$RENDER_MANIFEST" --repo-field git "$SUBDIR" "$MANIFEST")" \
      || { echo "ACTIVATE_FAILED: no git url for $SUBDIR"; exit 1; }
    GIT_REF="$(python3 "$RENDER_MANIFEST" --repo-field ref "$SUBDIR" "$MANIFEST" || echo "")"
    IV="$(python3 "$RENDER_MANIFEST" --repo-field refreshIntervalSec "$SUBDIR" "$MANIFEST" 2>/dev/null || echo "")"
    [ -n "$IV" ] && [ "$IV" != "None" ] || IV=300
    bash "$GIT_FETCH" "$SUBDIR" "$GIT_URL" "$GIT_REF" "$WS" \
      || { echo "ACTIVATE_FAILED: git fetch $SUBDIR"; exit 1; }
  else
    # LOCAL source: code is pushed out-of-band to $WS by scripts/push-local-repo.sh (+ host-side
    # reindex_local_repo.sh). Refuse if it hasn't landed — index-build@ would otherwise fail later.
    if [ -z "$(ls -A "$WS" 2>/dev/null)" ]; then
      echo "ACTIVATE_FAILED: local repo '$SUBDIR' has no code at $WS — push it first (scripts/push-local-repo.sh)"
      exit 1
    fi
    echo "activate: $SUBDIR is a LOCAL repo (no git fetch, no refresh timer)"
  fi
  mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"
```

把写 refresh service+timer 的两段 here-doc（120-141 行，从 `cat > "/etc/systemd/system/index-refresh-${SUBDIR}.service"` 到 timer here-doc 收尾的 `UNIT`）整体包进 `if repo_uses_git "$SRC"; then ... fi`。

enable timers 循环（205-207 行）改为：

```bash
for SUBDIR in $SUBDIRS; do
  SRC="$(python3 "$RENDER_MANIFEST" --repo-field source "$SUBDIR" "$MANIFEST" 2>/dev/null || echo git)"
  repo_uses_git "${SRC:-git}" || { echo "activate: skip refresh timer for local repo $SUBDIR"; continue; }
  systemctl enable --now "index-refresh-${SUBDIR}.timer"
done
```

glossary 初建（218-265 行）对 local 仓照常进行，不改。

**关键修正——reconcile 必须改为 old-manifest-driven，否则删 local 仓会泄漏 graph + glossary slice（独立复审 H1 + 多仓复审 M1）。**
现有 reconcile（181-201 行）**只遍历 `index-refresh-*.timer`** 找孤儿。local 仓不建 timer，故删 local 仓后其 graph + slice 永久残留，slice 被 `glossary_read.py` 的 `os.listdir` 无条件 glob 进索引污染（注释 184 行自述）。
**为什么不用 slice-driven**：slice 是**可选产物**——无 Bedrock 权限的部署里 local 仓根本不建 slice（`activate_project.sh:235` precheck 失败即跳过），那时「遍历 slice」同样看不到孤儿、泄漏复发。唯一**权威**的「本项目上次拥有哪些仓」信号是项目自己的**旧 manifest**（activate 在 55 行覆盖它之前的内容）。改为：覆盖前抓旧 subdirs，孤儿 = 旧 − 新，与 timer/slice/glossary-engine 是否存在**全部无关**。

先在写新 manifest（55 行 `printf '%s' "$REPO_MANIFEST_JSON" > "$MANIFEST"`）**之前**抓旧 subdirs。在该行前插入：

```bash
# Capture the project's PREVIOUS subdirs BEFORE overwriting the manifest — the authoritative
# "what this project owned last time" set for orphan reconcile (independent of timers/slices,
# which may not exist for local repos or on a no-glossary-engine host).
OLD_SUBDIRS=""
[ -f "$MANIFEST" ] && OLD_SUBDIRS="$(python3 "$RENDER_MANIFEST" --field subdir "$MANIFEST" 2>/dev/null || echo "")"
```

然后把 181-201 行整段替换为 old-manifest-driven 清理：

```bash
# RECONCILE (old-manifest-driven): orphans = OLD_SUBDIRS − current SUBDIRS. Authoritative and
# source-agnostic — works for local repos (no timer) AND on hosts with no glossary engine (no
# slice). Tear down each orphan's refresh unit (git repos only; disable is a no-op for local),
# its glossary slice + lock, and its on-disk repo copy + graph.
CUR_SUBDIRS=" $(echo $SUBDIRS) "   # space-delimited membership test
GLOSSARY_ROOT="${GLOSSARY_ROOT:-/data/glossary}"
PROJ_GLOSS_DIR="$GLOSSARY_ROOT/$PROJECT_ID"
for sub in $OLD_SUBDIRS; do
  case "$CUR_SUBDIRS" in *" $sub "*) continue ;; esac   # still current → keep
  echo "reconcile: repo '$sub' removed from project $PROJECT_ID — tearing down unit + slice + repo copy"
  systemctl disable --now "index-refresh-${sub}.timer" 2>/dev/null || true
  systemctl reset-failed "index-refresh-${sub}.timer" "index-refresh-${sub}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/index-refresh-${sub}.service" "/etc/systemd/system/index-refresh-${sub}.timer" 2>/dev/null || true
  rm -f "$PROJ_GLOSS_DIR/${sub}.jsonl" "$PROJ_GLOSS_DIR/.${sub}.lock" 2>/dev/null || true
  rm -rf "$LOCAL_REPO_ROOT/${sub}" "$LOCAL_REPO_ROOT/${sub}.incoming" "$LOCAL_REPO_ROOT/${sub}.bridge.lock" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true
```

注：清理也含孤儿的 `.incoming` 暂存目录（local 仓特有），避免删仓后残留。git 孤儿仓现在也清 repo 副本，与「不再 serve 即可回收」一致，比原版「副本留在原地」更干净。

- [ ] **Step 4: 写 reconcile 回归测试**

新建 `scripts/tests/test_reconcile_orphans.sh`：静态断言 reconcile 是 old-manifest-driven、覆盖无 timer 的 local 孤儿、清 repo 副本。

```bash
#!/usr/bin/env bash
# test_reconcile_orphans.sh — reconcile must be driven by the OLD manifest's subdirs (orphans =
# old − new), NOT by refresh timers (local repos have none) or glossary slices (may be absent on a
# no-engine host). Static assertions on the source.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
A="$ROOT/index-service/activate_project.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_reconcile_orphans:"

# OLD_SUBDIRS captured BEFORE the manifest is overwritten
grep -q 'OLD_SUBDIRS=' "$A"; check "captures old subdirs" $?
ovl=$(grep -n 'OLD_SUBDIRS="\$(python3' "$A" | head -1 | cut -d: -f1)
wrl=$(grep -n "printf '%s' \"\$REPO_MANIFEST_JSON\" > \"\$MANIFEST\"" "$A" | head -1 | cut -d: -f1)
[[ -n "$ovl" && -n "$wrl" && "$ovl" -lt "$wrl" ]]; check "old subdirs captured before manifest overwrite" $?
# reconcile iterates OLD_SUBDIRS, NOT refresh timers
grep -q 'for sub in \$OLD_SUBDIRS' "$A"; check "reconcile iterates old manifest subdirs" $?
! grep -q "list-unit-files 'index-refresh-\*.timer'" "$A"; check "reconcile no longer driven by refresh timers" $?
# orphan cleanup removes the repo copy + .incoming, not just the slice
grep -q 'rm -rf "$LOCAL_REPO_ROOT/${sub}" "$LOCAL_REPO_ROOT/${sub}.incoming"' "$A"; check "orphan repo copy + .incoming removed" $?
bash -n "$A"; check "activate_project.sh parses" $?
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash scripts/tests/test_activate_branch.sh && bash scripts/tests/test_reconcile_orphans.sh && bash scripts/tests/test_manifest.sh && bash -n index-service/activate_project.sh`
Expected: 全 ok。

- [ ] **Step 6: 提交**

```bash
git add index-service/activate_project.sh scripts/tests/test_activate_branch.sh scripts/tests/test_reconcile_orphans.sh
git commit -m "feat(index): source-aware activate + old-manifest-driven reconcile (clean removed local repos)"
```

---

### Task 3: 删项目 / reconcile 兼容无 git 仓 + local 仓 teardown

**Files:**
- Modify: `scripts/lib/deploy_project.sh`（`read_proj` 36-37 行）
- Modify: `scripts/install.sh`（`flow_remove_project` 的主机侧 `RM_CMD` 571-585 行——补 local 仓清理，复核对无 git 安全）
- Test: `scripts/tests/test_local_repo_config.sh`

**Interfaces:**
- Consumes: `projects.json` 里 `{subdir, source:"local"}`（无 `git`）。
- Produces: 读 repos 的 python 片段对 local 条目不 KeyError；删项目时停 `index-build@<sub>`（无 refresh timer 可停，`systemctl disable` 不存在单元是良性 no-op）、删 `/data/repo/<sub>` 及 graph、删 glossary slice。

- [ ] **Step 1: 写失败测试**

新建 `scripts/tests/test_local_repo_config.sh`：

```bash
#!/usr/bin/env bash
# test_local_repo_config.sh — projects.json with a local repo round-trips through the python
# snippets install.sh / deploy_project.sh use (no KeyError on missing 'git').
set -uo pipefail
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_local_repo_config:"
command -v python3 >/dev/null 2>&1 || { echo "  skip (no python3)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/projects.json" <<'JSON'
{"refreshIntervalSec":300,"projects":{"demo":{"port":8080,"feishuSecretId":"source-truth/feishu-demo","repos":[{"subdir":"loc","source":"local"},{"subdir":"g","git":"https://x/g.git"}]}}}
JSON

subs="$(SEL=demo python3 -c 'import json,os,sys
cfg=json.load(open(sys.argv[1]))
p=cfg.get("projects",{}).get(os.environ["SEL"],{})
print(" ".join(r.get("subdir","") for r in p.get("repos",[]) if r.get("subdir")))' "$TMP/projects.json")"
[[ "$subs" == "loc g" ]]; check "remove-flow subdir list includes local repo" $?

ok="$(python3 -c 'import json,sys
cfg=json.load(open(sys.argv[1])); p=cfg["projects"]["demo"]
specs=[{"subdir":r["subdir"],"source":r.get("source","git"),"git":r.get("git",""),"ref":r.get("ref","")} for r in p["repos"]]
print("ok" if specs[0]["source"]=="local" and specs[0]["git"]=="" else "bad")' "$TMP/projects.json")"
[[ "$ok" == "ok" ]]; check "read_proj specs tolerate missing git on local repo" $?

[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认状态**

Run: `bash scripts/tests/test_local_repo_config.sh`
Expected: 第 1 条 ok；第 2 条 FAIL（`deploy_project.sh` 现用 `r["git"]`）。

- [ ] **Step 3: 改 `deploy_project.sh` 的 `read_proj`**

把 specs 推导（36-37 行）改为 source-aware：

```python
    specs = [{"subdir": r["subdir"], "source": r.get("source", "git"),
              "git": r.get("git", ""), "ref": r.get("ref", ""),
              "refreshIntervalSec": r.get("refreshIntervalSec")} for r in p["repos"]]
```

- [ ] **Step 4: 复核删项目主机清理对 local 仓完整**

`scripts/install.sh` 的 `flow_remove_project` 主机侧 `RM_CMD`（571-585 行）已对每个 SUBDIR 做 `index-build@/index-refresh-*` 的 disable+reset-failed、`rm -rf /data/repo/$d`、删 glossary。对 local 仓：`index-refresh-$d.*` 不存在 → disable 良性 no-op；`index-build@$d` 存在 → 正常停；`/data/repo/$d` + graph 正常删；glossary slice 正常删。FALLBACK_SUBS 由 `r.get("subdir","")` 计算（550-556 行）已含 local 仓。**复核**该 here-doc 内无任何对 `git` 字段的引用即可（应无）。若发现引用 git，改为不依赖。本步预计为「确认 + 注释」，无功能改动。

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash scripts/tests/test_local_repo_config.sh`
Expected: 两条均 ok。

- [ ] **Step 6: 提交**

```bash
git add scripts/lib/deploy_project.sh scripts/tests/test_local_repo_config.sh
git commit -m "fix(deploy): tolerate local-source repos (missing git) in read_proj + removal"
```

---

### Task 4: `install.sh` 添加项目流程支持「本地仓」

**Files:**
- Modify: `scripts/install.sh`（`flow_add_project` repo 录入循环 367-380 行；git 凭证匿名探测 461-494 行复核——已用 `r.get("git","")`，对 local 安全，无需改）

**Interfaces:**
- Produces: local 仓写入 `{"subdir":<name>,"source":"local"}`（无 git/ref）；git 仓维持 `{"subdir","source":"git","git","ref"}`。subdir 冲突检查/端口逻辑不变。

- [ ] **Step 1: 改 repo 录入循环**

把录入循环（367-380 行）改为先选来源、再按类型收字段：

```bash
  local REPOS_JSON="[]" RGIT RSUB RREF RSRC SRC_CHOICE N=0
  say info "逐个添加该项目的代码仓库（仓库名留空结束）/ add repos (blank subdir = done):"
  while true; do
    ask RSUB "  第 $((N + 1)) 个仓库 · on-host 子目录名 / repo #$((N + 1)) subdir (^[a-z0-9-]+$, blank=done)" ""
    [[ -z "$RSUB" ]] && break
    [[ "$RSUB" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { say warn "subdir 非法，跳过 / invalid subdir, skipped"; continue; }
    pick SRC_CHOICE 0 \
      "git    远程 git 仓（自动定时刷新）/ remote git repo (auto-refresh)" \
      "local  本地仓（rsync 直推 + 手动刷新）/ local repo (rsync push + manual refresh)"
    RSRC="${SRC_CHOICE%%[[:space:]]*}"
    if [[ "$RSRC" == "git" ]]; then
      ask RGIT "    git 地址 / repo git URL" ""
      [[ -n "$RGIT" ]] || { say warn "git 仓必须有地址，跳过 / git repo needs a URL, skipped"; continue; }
      ask RREF "    分支/标签（留空=默认分支）/ ref (blank=default)" ""
      REPOS_JSON="$(RGIT="$RGIT" RSUB="$RSUB" RREF="$RREF" python3 -c '
import json,os,sys
a=json.loads(sys.argv[1]); a.append({"subdir":os.environ["RSUB"],"source":"git","git":os.environ["RGIT"],"ref":os.environ["RREF"]}); print(json.dumps(a))' "$REPOS_JSON")"
      say ok "    已加入 git 仓 / git repo: $RSUB ← $RGIT${RREF:+ @$RREF}"
    else
      REPOS_JSON="$(RSUB="$RSUB" python3 -c '
import json,os,sys
a=json.loads(sys.argv[1]); a.append({"subdir":os.environ["RSUB"],"source":"local"}); print(json.dumps(a))' "$REPOS_JSON")"
      say ok "    已加入本地仓 / local repo: $RSUB （部署后用 scripts/push-local-repo.sh 推送代码）"
    fi
    N=$((N + 1))
  done
  [[ "$REPOS_JSON" != "[]" ]] || { say err "至少要一个仓库 / need at least one repo"; exit 1; }
```

- [ ] **Step 2: 语法检查**

Run: `bash -n scripts/install.sh`
Expected: 通过。（`flow_add_project` 含 AWS 调用，离线只做语法检查；交互路径在真实部署演练时验证。）

- [ ] **Step 3: 提交**

```bash
git add scripts/install.sh
git commit -m "feat(install): let add-project choose git or local repo source"
```

---

### Task 5: host 侧 `reindex_local_repo.sh`（落地→建图→失败原子回滚）

> 第二轮 review 的核心修正：原「先 rsync 覆盖 live、再建图」在 build 失败时会留下「新代码 + 旧/半截 graph」继续服务，违反「代码为唯一依据」。改为**已知正确**的方案：停 bridge → 把当前 live 快照到一旁 → 落地新代码 → **在 live 路径建图** → 成功才丢弃旧快照、失败则原子回滚到旧 live。**不**采用「在 `.incoming` 建图再 mv 切换」的低停机方案，因为 graph.db 是否能跨目录改名后仍可用未经验证（codegraph 可能写入绝对路径）——以确定正确换取一段重建期停机（local 推送是人工低频操作，可接受；停机时长见 runbook）。本脚本随 index-service 代码打包上 S3。
>
> 另含 `--prepare <subdir>` 子模式：建/授暂存目录给推送用户——使 push 脚本无需对暂存目录单独 sudo，从而 sudoers 只需授权这**一个**脚本（修第二轮安全-1）。

**Files:**
- Create: `index-service/reindex_local_repo.sh`
- Test: `scripts/tests/test_reindex_local_repo.sh`（纯 bash：参数校验 + 编排顺序 + 回滚臂 + prepare 模式静态断言，不真动 systemd）

**Interfaces:**
- Consumes: `[--prepare] <subdir>`；host 上 `/etc/index-projects/<pid>.json` 各项目 manifest；暂存目录 `/data/repo/<subdir>.incoming/`（由 push 脚本 rsync 填充）；`$SUDO_USER`（prepare 模式 chown 目标）。
- Produces:
  - `--prepare <subdir>`：mkdir `/data/repo/<subdir>.incoming` 并 chown 给 `$SUDO_USER`（**从不**碰 live 目录）。
  - `<subdir>`：解析拥有该 subdir 的 projectId → 停 `index-bridge-<pid>` → `mv` 当前 live 到一旁快照 → `mv` `.incoming` 到 live → 写 `.snapshot-time` → 在 live 路径 `index-build@<subdir>`（bridge 已停，flock 空闲）→ 成功则起 bridge + 删旧快照；**任何失败经 `trap rollback EXIT` 原子回滚旧 live 并起回 bridge**。

- [ ] **Step 1: 写失败测试**

新建 `scripts/tests/test_reindex_local_repo.sh`：

```bash
#!/usr/bin/env bash
# test_reindex_local_repo.sh — static checks: arg validation + orchestration order + rollback arm
# + prepare mode. No systemd, no network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$ROOT/index-service/reindex_local_repo.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_reindex_local_repo:"

[[ -f "$S" ]]; check "script exists" $?
bash -n "$S"; check "parses" $?
bash "$S" "Bad/Sub" 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "invalid subdir rejected" $?
bash "$S" --prepare "Bad/Sub" 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "prepare rejects invalid subdir" $?
# orchestration: stop bridge BEFORE build, build BEFORE final bridge start
stop_ln=$(grep -nF 'systemctl stop "$BRIDGE"' "$S" | head -1 | cut -d: -f1)
build_ln=$(grep -nF 'systemctl start "index-build@' "$S" | head -1 | cut -d: -f1)
start_ln=$(grep -nF 'systemctl start "$BRIDGE"' "$S" | tail -1 | cut -d: -f1)
[[ -n "$stop_ln" && -n "$build_ln" && -n "$start_ln" && "$stop_ln" -lt "$build_ln" && "$build_ln" -lt "$start_ln" ]]
check "stop bridge < build < start bridge" $?
grep -q 'trap rollback EXIT' "$S"; check "arms rollback on failure" $?
grep -q 'REINDEX_PREPARED' "$S"; check "has --prepare mode" $?
# glossary slice must be rebuilt after a successful graph build (local repos have no refresh timer)
grep -q 'glossary_gen' "$S" && glos_ln=$(grep -nF 'glossary_gen' "$S" | head -1 | cut -d: -f1)
[[ -n "${glos_ln:-}" && "$glos_ln" -gt "$start_ln" ]]; check "glossary rebuilt after graph build+bridge start" $?
grep -q 'bedrock-runtime converse' "$S"; check "glossary rebuild gated by Bedrock precheck" $?
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_reindex_local_repo.sh`
Expected: FAIL —— 脚本不存在。

- [ ] **Step 3: 写 `index-service/reindex_local_repo.sh`**

```bash
#!/usr/bin/env bash
# reindex_local_repo.sh — host-side ingest for a LOCAL repo. Two modes:
#   --prepare <subdir>  : create staging dir /data/repo/<subdir>.incoming owned by the SSH user
#                         (so push-local-repo.sh rsyncs into it without sudo on the dir).
#   <subdir>            : swap staged code into live and rebuild, with ATOMIC ROLLBACK on failure.
#
# CORRECTNESS OVER SPEED (MVP). We stop the project bridge, snapshot the current live dir aside,
# move staged code into place, and rebuild the graph AT THE LIVE PATH (never build at a different
# path than it's served from). If the build FAILS, we roll back to the snapshot (old code + old
# graph) and restart — the live copy is never left as "new code + stale graph" (which would cite
# wrong lines, 违反代码为唯一依据). The bridge is down for the rebuild duration; local pushes are
# manual + infrequent so this is acceptable (see runbook). A future optimization is build-in-
# staging-then-rename for sub-second downtime — DEFERRED pending verification that graph.db is
# portable across a directory rename.
#
# SINGLE-WRITER (不变量2): the rebuild runs while the bridge is STOPPED, so index-build@'s flock is
# free — never two writers on graph.db.
set -euo pipefail

MODE="reindex"
if [ "${1:-}" = "--prepare" ]; then MODE="prepare"; shift; fi
SUBDIR="${1:?usage: reindex_local_repo.sh [--prepare] <subdir>}"
echo "$SUBDIR" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { echo "REINDEX_FAILED: invalid subdir '$SUBDIR'"; exit 2; }

LOCAL_REPO_ROOT=/data/repo
WS="$LOCAL_REPO_ROOT/$SUBDIR"
STAGE="$LOCAL_REPO_ROOT/$SUBDIR.incoming"

if [ "$MODE" = "prepare" ]; then
  # Staging dir owned by the INVOKING (sudo) user; NEVER touches the live dir.
  mkdir -p "$STAGE"
  owner="${SUDO_USER:-root}"
  chown -R "$owner":"$owner" "$STAGE" 2>/dev/null || true
  echo "REINDEX_PREPARED stage=$STAGE owner=$owner"
  exit 0
fi

[ -d "$STAGE" ] || { echo "REINDEX_FAILED: no staged code at $STAGE (run push-local-repo.sh first)"; exit 1; }
[ -n "$(ls -A "$STAGE" 2>/dev/null)" ] || { echo "REINDEX_FAILED: staged dir $STAGE is empty"; exit 1; }

# Resolve the owning project from the manifests.
PID=""
for m in /etc/index-projects/*.json; do
  [ -f "$m" ] || continue
  if python3 -c 'import json,sys
m=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in [r.get("subdir") for r in m.get("repos",[])] else 1)' "$m" "$SUBDIR"; then
    PID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["projectId"])' "$m")"; break
  fi
done
[ -n "$PID" ] || { echo "REINDEX_FAILED: subdir '$SUBDIR' not found in any project manifest"; exit 1; }
BRIDGE="index-bridge-${PID}.service"
OLD="$LOCAL_REPO_ROOT/.$SUBDIR.old.$$"

echo "reindex: stopping $BRIDGE for swap+rebuild (project offline during rebuild)"
systemctl stop "$BRIDGE" 2>/dev/null || true

rollback() {
  echo "reindex: ROLLING BACK — restoring previous live copy"
  rm -rf "$WS" 2>/dev/null || true
  [ -d "$OLD" ] && mv "$OLD" "$WS" 2>/dev/null || true
  systemctl start "$BRIDGE" 2>/dev/null || true
}
trap rollback EXIT

# Snapshot current live aside (atomic rename, same filesystem), then move staged code into place.
if [ -d "$WS" ]; then mv "$WS" "$OLD"; fi
mv "$STAGE" "$WS"
mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"   # fresh graph workspace dirs for the rebuild
# Snapshot marker so answers can surface "pushed at <ts>" (local repos have no sha). It lives in
# $WS and survives — reindex uses mv, not a --delete rsync, so nothing strips it.
date -u +%Y-%m-%dT%H:%M:%SZ > "$WS/.snapshot-time" 2>/dev/null || true

echo "reindex: building graph at live path (bridge stopped, flock free)"
systemctl reset-failed "index-build@${SUBDIR}.service" 2>/dev/null || true
systemctl start "index-build@${SUBDIR}.service"
R="$(systemctl show "index-build@${SUBDIR}.service" --value -p Result 2>/dev/null || echo unknown)"
[ "$R" = "success" ] || { echo "REINDEX_FAILED: index-build@${SUBDIR} Result=$R — rolling back"; journalctl -u "index-build@${SUBDIR}.service" --no-pager | tail -30 || true; exit 1; }

# Success: start bridge, drop the old copy, disarm rollback.
systemctl start "$BRIDGE"
trap - EXIT
rm -rf "$OLD"

# REBUILD THE GLOSSARY SLICE (修多仓复审 C1). git repos refresh their slice via the per-repo timer
# (glossary_refresh.sh, diff-based); LOCAL repos have NO timer, so without this the slice would stay
# frozen at the first activate — new/renamed Chinese-term→symbol mappings would be missing and
# deleted symbols would linger. We mirror activate_project's initial build: --full (local repos have
# no sha to diff), same per-slice flock shared with any concurrent refresh, Bedrock precheck so a
# no-engine host degrades gracefully (graph already rebuilt; an empty/stale glossary is tolerable).
# Detached so reindex returns promptly; the bridge is already serving the fresh graph.
# shellcheck disable=SC1091
. /etc/index-service.env 2>/dev/null || true   # MODEL, REGION, GLOSSARY_MAX_FILES
GLOSSARY_ROOT="${GLOSSARY_ROOT:-/data/glossary}"
if [ -z "${MODEL:-}" ]; then
  echo "reindex: MODEL empty — graph rebuilt, skipping glossary refresh (engine disabled)"
elif ! aws bedrock-runtime converse --region "${REGION:-}" --model-id "$MODEL" \
        --messages '[{"role":"user","content":[{"text":"ok"}]}]' \
        --cli-connect-timeout 8 --cli-read-timeout 20 >/dev/null 2>&1; then
  echo "reindex: Bedrock not invokable — graph rebuilt, skipping glossary refresh (slice left as-is)"
else
  mkdir -p "$GLOSSARY_ROOT/${PID}"
  GLOG="/var/log/glossary-build-${PID}-${SUBDIR}.log"
  ( cd /opt/idx/app && nohup env GLOSSARY_ROOT="$GLOSSARY_ROOT" AWS_REGION="${REGION:-}" \
      ${GLOSSARY_MAX_FILES:+GLOSSARY_MAX_FILES="$GLOSSARY_MAX_FILES"} \
      flock "$GLOSSARY_ROOT/${PID}/.${SUBDIR}.lock" \
        python3 -m glossary_gen --project "${PID}" --repo-root "$WS" \
          --out "$GLOSSARY_ROOT/${PID}/${SUBDIR}.jsonl" \
          --model "$MODEL" --region "${REGION:-}" --full \
          >>"$GLOG" 2>&1 & ) || true
  echo "reindex: glossary slice rebuild launched (detached) for $SUBDIR"
fi
echo "REINDEX_DONE subdir=${SUBDIR} project=${PID}"
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_reindex_local_repo.sh`
Expected: 全 ok。

- [ ] **Step 5: 确保打包上 S3 + 可执行**

artifacts phase 用 glob `cp "$ROOT"/index-service/*.sh "$IDX_STAGE"/`（deploy-all.sh:469），故 `reindex_local_repo.sh` **自动**被打进 `index-service.tar.gz`，无需改 deploy-all。只需在 `deploy_project.sh:94` 的 chmod 行追加它：

把

```bash
chmod +x /opt/idx/app/activate_project.sh /opt/idx/app/git_fetch.sh /opt/idx/app/glossary_refresh.sh
```

改为

```bash
chmod +x /opt/idx/app/activate_project.sh /opt/idx/app/git_fetch.sh /opt/idx/app/glossary_refresh.sh /opt/idx/app/reindex_local_repo.sh
```

- [ ] **Step 6: 提交**

```bash
chmod +x index-service/reindex_local_repo.sh
git add index-service/reindex_local_repo.sh scripts/tests/test_reindex_local_repo.sh scripts/lib/deploy_project.sh
git commit -m "feat(index): reindex_local_repo.sh — swap+rebuild with atomic rollback; --prepare stage mode"
```

---

### Task 6: 客户机侧 `push-local-repo.sh`（rsync 到暂存 + 触发重建，加固注入面）

**Files:**
- Create: `scripts/push-local-repo.sh`
- Test: `scripts/tests/test_push_local_repo.sh`

**Interfaces:**
- Consumes: `<subdir> <local-path>`、`--host <ssh-host>`、可选 `--identity <keyfile>`、`--dry-run`。
- Produces: `rsync -az` 本地仓 → `<host>:/data/repo/<subdir>.incoming/`（bridge 仍服务，不碰 live 目录），再 ssh 执行 `sudo /opt/idx/app/reindex_local_repo.sh <subdir>`。**安全**：subdir 正则校验；**不接受任意 `--ssh-opts`**（只暴露 `--identity` 一个受控旋钮，避免 ProxyCommand 注入）；不 chown live 目录。

- [ ] **Step 1: 写失败测试**

新建 `scripts/tests/test_push_local_repo.sh`：

```bash
#!/usr/bin/env bash
# test_push_local_repo.sh — arg validation + dry-run command assembly + injection guards. No network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$ROOT/scripts/push-local-repo.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_push_local_repo:"

[[ -f "$S" ]]; check "script exists" $?
bash -n "$S"; check "parses" $?
bash "$S" 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "no args exits non-zero" $?
bash "$S" --host h "Bad/Sub" /tmp 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "invalid subdir rejected" $?
# refuse a / local path (would mirror the whole disk)
bash "$S" --host h sub / 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "root local path rejected" $?
# NO --ssh-opts knob (injection vector) — unknown flag must error
bash "$S" --ssh-opts "-oProxyCommand=evil" --host h sub /tmp 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "--ssh-opts not accepted (no ProxyCommand injection)" $?

SRC="$(mktemp -d)"; echo hi > "$SRC/f.txt"
out="$(bash "$S" --host ec2host --dry-run localsub "$SRC" 2>&1)"; rc=$?
[[ $rc -eq 0 ]]; check "dry-run rc 0" $?
grep -q 'rsync' <<<"$out"; check "dry-run shows rsync" $?
grep -q 'safe-links' <<<"$out" && grep -q 'no-links' <<<"$out"; check "dry-run rsync refuses symlink escape" $?
grep -q '/data/repo/localsub.incoming' <<<"$out"; check "dry-run stages to .incoming (not live dir)" $?
grep -q 'reindex_local_repo.sh --prepare localsub' <<<"$out"; check "dry-run prepares stage via host script (no raw sudo mkdir)" $?
grep -q 'reindex_local_repo.sh localsub' <<<"$out"; check "dry-run triggers host reindex" $?
! grep -qE 'sudo (mkdir|chown)' <<<"$out"; check "no raw sudo mkdir/chown in remote commands" $?
rm -rf "$SRC"
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_push_local_repo.sh`
Expected: FAIL —— 脚本不存在。

- [ ] **Step 3: 写 `scripts/push-local-repo.sh`**

```bash
#!/usr/bin/env bash
# push-local-repo.sh — push a LOCAL repo from your machine to the source-truth index host, then
# trigger a single-writer-safe reindex. Ingestion path for repos declared {"source":"local"} in
# projects.json (no git remote). Re-run whenever the code changes — that IS the refresh.
#
#   scripts/push-local-repo.sh --host <ssh-host> [--identity <key>] <subdir> <local-path> [--dry-run]
#
# Code is staged to /data/repo/<subdir>.incoming/ (the live dir keeps serving), then the host's
# reindex_local_repo.sh stops that project's bridge, lands the code, rebuilds, and restarts.
#
# SECURITY: we deliberately do NOT expose a free-form --ssh-opts (a `-oProxyCommand=...` there is
# local RCE). Only a vetted --identity keyfile is accepted. <subdir> is regex-validated; it is the
# ONLY thing interpolated into the remote command — keep the regex strict.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then # shellcheck source=lib/common.sh
  source "$SCRIPT_DIR/lib/common.sh"; else say() { local l="$1"; shift; printf '%s\n' "$*"; }; fi

HOST="" IDENTITY="" DRY=false SUBDIR="" LOCAL_PATH=""
usage() { sed -n '2,12p' "$0"; exit "${1:-2}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage 0 ;;
    -*) say err "unknown flag: $1 (note: free-form --ssh-opts is intentionally not supported)"; usage ;;
    *) if [ -z "$SUBDIR" ]; then SUBDIR="$1"; elif [ -z "$LOCAL_PATH" ]; then LOCAL_PATH="$1"; else say err "too many args"; usage; fi; shift ;;
  esac
done

[ -n "$HOST" ] || { say err "--host <ssh-host> required"; usage; }
[ -n "$SUBDIR" ] && [ -n "$LOCAL_PATH" ] || { say err "need <subdir> and <local-path>"; usage; }
printf '%s' "$SUBDIR" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { say err "subdir must match ^[a-z0-9][a-z0-9-]*$"; exit 2; }
[ -d "$LOCAL_PATH" ] || { say err "local path not a directory: $LOCAL_PATH"; exit 2; }
# Refuse a root / near-root source (a trailing-slash mirror of / would be catastrophic).
REAL="$(cd "$LOCAL_PATH" && pwd -P)"
[ "$REAL" != "/" ] || { say err "refusing to push the filesystem root"; exit 2; }

# Build the ssh argv as an ARRAY (no string-splitting, no -e "...") and only from vetted inputs.
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
[ -n "$IDENTITY" ] && SSH+=(-i "$IDENTITY")

SRC="${REAL%/}/"
STAGE="/data/repo/${SUBDIR}.incoming"
REINDEX="/opt/idx/app/reindex_local_repo.sh"
# --safe-links: drop any symlink that points OUTSIDE the tree; --no-links additionally refuses to
# recreate symlinks at all. Without these, a pushed `x -> /etc` would let the host's root-run build
# index files outside the repo (info leak). Both client push AND host landing must be link-safe.
# --exclude .git keeps VCS metadata out; protect filters are belt-and-suspenders (stage has no graph
# dirs, but if someone points --host at a live dir by mistake, --delete still won't strip them).
RSYNC=(rsync -az --delete --safe-links --no-links
  --filter='P .codegraph/' --filter='P .home/' --exclude='.git'
  -e "$(printf '%q ' "${SSH[@]}")" "$SRC" "${HOST}:${STAGE}/")
# The host script (run via a SINGLE sudo-authorized entry) creates+owns the stage dir, then later
# does the swap+rebuild. push never runs raw `sudo mkdir/chown` — so sudoers authorizes ONE script.
# Invoke via `bash <script>` (not direct exec) so it works even if the +x bit isn't set yet — the
# chmod happens at activate time, but a first push could precede a re-activate. sudoers must then
# authorize `/bin/bash /opt/idx/app/reindex_local_repo.sh *` (see runbook).
REMOTE_PREPARE="sudo bash ${REINDEX} --prepare ${SUBDIR}"
REMOTE_REINDEX="sudo bash ${REINDEX} ${SUBDIR}"

if [ "$DRY" = true ]; then
  say info "[dry-run] prepare stage: ${SSH[*]} ${HOST} ${REMOTE_PREPARE}"
  say info "[dry-run] ${RSYNC[*]}"
  say info "[dry-run] reindex: ${SSH[*]} ${HOST} ${REMOTE_REINDEX}"
  exit 0
fi

say step "preparing stage ${STAGE} on ${HOST} (via host script)"
"${SSH[@]}" "$HOST" "$REMOTE_PREPARE"
say step "rsync ${SRC} → ${HOST}:${STAGE}"
"${RSYNC[@]}"
say step "triggering host reindex (stop bridge → swap → build → start, rollback on failure)"
"${SSH[@]}" "$HOST" "$REMOTE_REINDEX"
say ok "pushed + reindexed local repo '${SUBDIR}'"
```

注：暂存目录 `.incoming` 由 host 脚本 `--prepare` 建并 chown 给 SSH 用户（push 端**不**跑裸 `sudo mkdir/chown`，使 sudoers 只授权这一个脚本——修第二轮安全-1）；live 目录 `/data/repo/<subdir>` 的属主始终由 host 侧 reindex 控制，从不 chown 给推送用户。`--safe-links --no-links` 在 push 与 host 落地两侧都防止软链逃逸出仓（修第二轮安全-2）。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_push_local_repo.sh`
Expected: 全 ok。

- [ ] **Step 5: 提交**

```bash
chmod +x scripts/push-local-repo.sh
git add scripts/push-local-repo.sh scripts/tests/test_push_local_repo.sh
git commit -m "feat(scripts): push-local-repo.sh (staged rsync + injection-hardened, no free-form ssh opts)"
```

---

# Part 2 — 单台 EC2 自举（deploy-all 本地模式）

### Task 7: `bootstrap.sh` 可在已运行主机上幂等重跑

**Files:**
- Modify: 无（bootstrap.sh 现状已大体幂等；本任务加护栏测试 + 一处日志读权限说明）
- Test: `scripts/tests/test_bootstrap_idempotent.sh`

**Interfaces:**
- Consumes: `/etc/index-service.env`（`BUCKET/REGION/MAX_FILES/MODEL/GLOSSARY_MAX_FILES`），由 user-data 或 deploy 本地模式写入。
- Produces: 在已就绪主机重跑不破坏正在服务的 bridge（bootstrap 只装 build@/gateway@ 模板与依赖，**不碰** activate 写的 concrete bridge unit），最终打印 `BOOTSTRAP_DONE`。

- [ ] **Step 1: 写测试**

新建 `scripts/tests/test_bootstrap_idempotent.sh`：

```bash
#!/usr/bin/env bash
# test_bootstrap_idempotent.sh — static guards that bootstrap.sh is safe to re-run on a live host.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$ROOT/index-service/bootstrap.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_bootstrap_idempotent:"

bash -n "$B"; check "bootstrap.sh parses" $?
grep -q 'ln -sf .* /usr/local/bin/codegraph-server' "$B"; check "codegraph symlink uses ln -sf" $?
grep -q 'command -v node >/dev/null 2>&1 && return 0' "$B"; check "ensure_node guards re-install" $?
# bootstrap must NOT stop/restart the resident project bridge (it doesn't own it)
! grep -qE 'systemctl (stop|restart) .*index-bridge-' "$B"; check "bootstrap never touches a project bridge" $?
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试**

Run: `bash scripts/tests/test_bootstrap_idempotent.sh`
Expected: 全 ok（bootstrap.sh 现状满足；测试为防回归护栏）。

- [ ] **Step 3: 提交**

```bash
git add scripts/tests/test_bootstrap_idempotent.sh
git commit -m "test(bootstrap): guard re-run idempotency for local-mode bootstrap"
```

---

### Task 8: `provision_index_service.sh` 本地模式（专用 SG + describe-instances 取身份）

**Files:**
- Modify: `scripts/lib/provision_index_service.sh`（顶部参数区 16-24 行加 `LOCAL_MODE` + `imds_token`/`imds_field`；95 行 `CURRENT_SIG=` 之后插入本地模式分支）
- Test: `scripts/tests/test_provision_local_mode.sh`

**Interfaces:**
- Consumes: `ST_LOCAL_MODE=true`（由 deploy-all `--local`）；IMDSv2 取本机 instance-id；`aws ec2 describe-instances` 取 VPC/subnet（**不**靠 IMDS 多级 mac 路径，修 review C2）。
- Produces: 本地模式——新建/复用专用 SG `source-truth-index-svc`（8080-8099 自引用）、**附加**到本机实例（保留客户原有 SG）、用它做 bridge ingress + runtime SG；写 `/etc/index-service.env`；以超时包裹同步跑 `bootstrap.sh`；设置 `INDEX_SERVICE_INSTANCE/IP/SG`；stdout 打印本机私有 IP。

- [ ] **Step 1: 写失败测试**

新建 `scripts/tests/test_provision_local_mode.sh`：

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$ROOT/scripts/lib/provision_index_service.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_provision_local_mode:"

bash -n "$F"; check "parses" $?
# imds_field helper present + extractable (multi-line, closing brace col 0)
HELPER="$(sed -n '/^imds_field() {$/,/^}$/p' "$F"; sed -n '/^imds_token() {$/,/^}$/p' "$F")"
[[ -n "$HELPER" ]]; check "imds helpers extractable" $?
eval "$HELPER"
curl() { case "$*" in *api/token*) echo TOKEN;; *instance-id*) echo i-abc;; *local-ipv4*) echo 10.1.2.3;; *) echo "";; esac; }
[[ "$(imds_field instance-id)" == "i-abc" ]]; check "imds_field reads instance-id" $?
[[ "$(imds_field local-ipv4)" == "10.1.2.3" ]]; check "imds_field reads local-ipv4" $?
# local mode must derive VPC/subnet via describe-instances, NOT IMDS mac paths
grep -q 'describe-instances' "$F"; check "uses describe-instances for vpc/subnet/sg" $?
! grep -q 'macs/.*security-group-ids' "$F"; check "does NOT scrape IMDS mac sg path" $?
# local mode must wrap bootstrap with a timeout
grep -qE 'timeout [0-9].* bash .*bootstrap.sh|run_timeout .* bootstrap.sh' "$F"; check "bootstrap wrapped in a timeout" $?
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_provision_local_mode.sh`
Expected: FAIL —— 无本地模式实现。

- [ ] **Step 3: 实现本地模式**

参数区（24 行 `log()` 之后）加：

```bash
LOCAL_MODE="${ST_LOCAL_MODE:-false}"

# IMDSv2 helpers (token-first). Used ONLY in local mode to learn THIS instance's id; VPC/subnet/SG
# are then read via describe-instances (authoritative, no fragile mac-path scraping).
imds_token() {
  curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo ""
}
imds_field() {
  local tok; tok="$(imds_token)"
  curl -fsS -H "X-aws-ec2-metadata-token: $tok" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo ""
}
```

`CURRENT_SIG="$(artifact_signature)"`（95 行）之后插入：

```bash
if [[ "$LOCAL_MODE" == "true" ]]; then
  log step "local mode: this host IS the index host — provisioning in place"
  SELF_ID="$(imds_field instance-id)"
  [[ -n "$SELF_ID" ]] || { log err "local mode: IMDS unavailable (need an EC2 with IMDSv2 reachable)"; exit 1; }
  read -r SELF_IP SELF_VPC SELF_SUBNET < <(Q describe-instances --instance-ids "$SELF_ID" \
    --query 'Reservations[0].Instances[0].[PrivateIpAddress,VpcId,SubnetId]' --output text)
  [[ -n "$SELF_IP" && "$SELF_VPC" != None && -n "$SELF_SUBNET" ]] \
    || { log err "local mode: could not read IP/VPC/subnet for $SELF_ID"; exit 1; }

  # DEDICATED SG (NOT the operator's primary SG): self-referencing 8080-8099 only, so only SG
  # members (this host + the runtimes we launch into it) reach the bridge — the bridge has no MCP
  # authn. Reuse provision's create-or-find + reconcile path. Attach it ADDITIVELY to this instance
  # (keep the operator's existing SGs).
  SG="$(Q describe-security-groups --filters "Name=group-name,Values=source-truth-index-svc" "Name=vpc-id,Values=$SELF_VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [[ "$SG" == "None" || -z "$SG" ]]; then
    SG="$(Q create-security-group --group-name source-truth-index-svc --description "index-service codegraph bridge" --vpc-id "$SELF_VPC" --query GroupId --output text)"
  fi
  reconcile_index_sg_ingress "$SG"
  # Collect the instance's current SGs into an ARRAY and filter out any "None"/empty token, so the
  # `--groups` arg is never malformed (a bare `--groups "" sg-x` errors). modify-instance-attribute
  # --groups is REPLACE-semantics, so we pass existing + new together to ADD without dropping any.
  # Skip the call entirely if the dedicated SG is already attached (idempotent re-run).
  mapfile -t CUR_SGS < <(Q describe-instances --instance-ids "$SELF_ID" \
    --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text | tr '\t' '\n' | grep -E '^sg-')
  # GUARD: a running instance ALWAYS has ≥1 SG. An empty read means an IAM/throttle/race glitch —
  # NOT "no SGs". Bail rather than call modify-instance-attribute with just "$SG", which (REPLACE
  # semantics) would STRIP the operator's existing SGs (lose their 22/business ingress) — the
  # opposite of the additive intent.
  [[ ${#CUR_SGS[@]} -gt 0 ]] || { log err "local mode: read 0 current SGs for $SELF_ID (transient API glitch?) — refusing to modify groups; re-run"; exit 1; }
  _has_sg=false; for g in "${CUR_SGS[@]}"; do [[ "$g" == "$SG" ]] && _has_sg=true; done
  if [[ "$_has_sg" != true ]]; then
    Q modify-instance-attribute --instance-id "$SELF_ID" --groups "${CUR_SGS[@]}" "$SG"
  fi

  sudo tee /etc/index-service.env >/dev/null <<ENV
BUCKET='$BUCKET'
REGION='$REGION'
MAX_FILES='$MAX_FILES'
MODEL='$MODEL'
GLOSSARY_MAX_FILES='$GLOSSARY_MAX_FILES'
ENV
  # Synchronous bootstrap, but bounded: a hung apt/pip must not wedge the deploy forever.
  log info "local mode: running bootstrap.sh in place (bounded 1800s) ..."
  timeout 1800 sudo -E bash "$ROOT/index-service/bootstrap.sh" >&2 \
    || { log err "local-mode bootstrap.sh failed/timed out — see /var/log/index-svc-bootstrap.log"; exit 1; }

  update_env "$CONFIG" PRIVATE_SUBNET "$SELF_SUBNET"
  update_env "$CONFIG" VPC_ID "$SELF_VPC"
  update_env "$CONFIG" INDEX_SERVICE_SG "$SG"
  update_env "$CONFIG" INDEX_SERVICE_INSTANCE "$SELF_ID"
  log info "local mode: index host ready at $SELF_IP (instance $SELF_ID, dedicated sg $SG)"
  echo "$SELF_IP"; exit 0
fi
```

注：`reconcile_index_sg_ingress` / `authorize_ingress`（57-79 行）定义在此分支之前，可调用。`modify-instance-attribute --groups` 是覆盖式，故先读 `CUR_SGS` 连同新 SG 一起传（附加语义）。`sudo -E` 需免密 sudo（Task 10 runbook 写明）。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_provision_local_mode.sh`
Expected: 全 ok。

- [ ] **Step 5: 提交**

```bash
git add scripts/lib/provision_index_service.sh scripts/tests/test_provision_local_mode.sh
git commit -m "feat(provision): local mode — dedicated SG + in-place bounded bootstrap on this EC2"
```

---

### Task 9: `deploy-all.sh` 加 `--local`（含 ARM64 自检、网络复用、跳过 wait）

**Files:**
- Modify: `scripts/deploy-all.sh`（flag 解析 + ARM64 自检；Phase 2 network 514-531 行；Phase 3 index-svc 540-560 行）
- Test: `scripts/tests/test_deploy_all_local.sh`（**新建**，纯离线静态断言；既有 `test_deploy.sh` 只测废弃垫片且禁网，`deploy-all --dry-run` 会调 `aws sts` 故不实跑）

**Interfaces:**
- Produces: `--local` 时——入口断言 `uname -m == aarch64`（修 review H3）；Phase 2 不新建 VPC/NAT，从 IMDS+describe-instances 取本机 VPC/subnet 写入 config；Phase 3 以 `ST_LOCAL_MODE=true` 调 provisioner，且跳过 `wait_base_host.sh`（bootstrap 已同步跑完），改 `sudo grep BOOTSTRAP_DONE`。

- [ ] **Step 1: 写失败测试**

新建 `scripts/tests/test_deploy_all_local.sh`：

```bash
#!/usr/bin/env bash
# test_deploy_all_local.sh — OFFLINE static checks for deploy-all.sh --local. We do NOT execute
# deploy-all (even --dry-run calls aws sts).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$ROOT/scripts/deploy-all.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_deploy_all_local:"

bash -n "$D"; check "deploy-all.sh parses" $?
"$D" --help 2>&1 | grep -q -- '--local'; check "--help documents --local" $?
grep -q -- '--local) LOCAL_MODE=true' "$D"; check "--local sets LOCAL_MODE" $?
grep -q 'uname -m' "$D"; check "has an arch guard" $?
grep -q 'ST_LOCAL_MODE=' "$D"; check "Phase 3 passes ST_LOCAL_MODE to provisioner" $?
grep -qi 'local mode' "$D"; check "Phase 2 has a local-mode network branch" $?
grep -q 'sudo grep .*BOOTSTRAP_DONE\|sudo tail' "$D"; check "local-mode confirms BOOTSTRAP_DONE with sudo" $?
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_deploy_all_local.sh`
Expected: FAIL。

- [ ] **Step 3: 实现 `--local`**

flag 默认值（`REFRESH_INDEX=false` 附近）加 `LOCAL_MODE=false`；`case` 加 `--local) LOCAL_MODE=true ;;`；usage 补一行 `--local  this EC2 IS the index host: bootstrap in place, reuse its VPC/subnet (ARM64 only)`。

参数解析结束后、Phase 0 之前加 ARM64 自检：

```bash
if [[ "$LOCAL_MODE" == true && "$(uname -m)" != "aarch64" ]]; then
  say err "--local requires an ARM64 (aarch64) host (the agent image + codegraph-server are ARM64-only); this host is $(uname -m)."
  exit 1
fi
```

Phase 2（514-531 行）包成本地模式分支：

```bash
if [[ "$LOCAL_MODE" == true ]]; then
  say step "Phase 2: network (local mode — reuse this host's VPC/subnet, no VPC/NAT created)"
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] local mode: derive VPC/subnet from this instance via IMDS + describe-instances"
  else
    say info "local mode: VPC/subnet are derived inside the index-svc phase (describe-instances)"
  fi
elif skip network; then say warn "skip network"; else
  say step "Phase 2: network"
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] provision_network.sh (VPC/subnets/IGW/NAT) — discovers + reconciles by tag"
  else
    "$SCRIPT_DIR/lib/provision_network.sh" "$REGION" "$CONFIG_FILE"
    safe_source_env "$CONFIG_FILE"
  fi
fi
```

（VPC/subnet 实际写入放在 Task 8 的本地模式分支里，Phase 3 调用后 `safe_source_env` 即可见。）

Phase 3 调用（541-542 行）传 `ST_LOCAL_MODE`：

```bash
  INDEX_IP="$(ST_LOCAL_MODE="$LOCAL_MODE" "$SCRIPT_DIR/lib/provision_index_service.sh" \
    "$REGION" "$CONFIG_FILE" "$BUCKET" "$MAX_FILES" "$INSTANCE_TYPE" "$REFRESH_INDEX" "$ROOT_VOLUME_GB" "$MODEL" "$GLOSSARY_MAX_FILES")"
```

bootstrap 等待段（现有 `if [[ "$DRY_RUN" != true ]] && [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then ... fi`，约 549-571 行，内含 `wait_base_host.sh` + 失败的 --refresh-index 清理）改为：**把现有 `if` 整块原样降级为 `elif`，前面加一个 LOCAL_MODE 短路分支**。即把开头的 `if [[ "$DRY_RUN" != true ]] && [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then` 这一行改成下面这两段（其余行——`wait_base_host.sh` 调用、failed-refresh 清理、收尾 `fi`——**一字不动保留**）：

把这一行：

```bash
  if [[ "$DRY_RUN" != true ]] && [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then
```

替换为：

```bash
  if [[ "$LOCAL_MODE" == true ]]; then
    # bootstrap ran synchronously inside the provisioner (Task 8); just confirm its done-marker.
    # The log is written by root via sudo, so read it with sudo.
    sudo grep -q BOOTSTRAP_DONE /var/log/index-svc-bootstrap.log 2>/dev/null \
      || { say err "local-mode bootstrap did not finish (no BOOTSTRAP_DONE) — sudo tail /var/log/index-svc-bootstrap.log"; exit 1; }
    say ok "local-mode base host bootstrap confirmed"
  elif [[ "$DRY_RUN" != true ]] && [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then
```

这样 `wait_base_host.sh` 块连同其 failed-refresh 清理逻辑（terminate 坏的新实例、还原 INDEX_SERVICE_INSTANCE）完整保留在 `elif` 分支里，本地模式只是在它前面短路掉。

Phase 4（image）：本机 ARM64 时现有 `uname -m` buildx 守卫自然放行，无需改。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_deploy_all_local.sh && bash scripts/tests/test_deploy.sh`
Expected: 两者全 ok。

- [ ] **Step 5: 提交**

```bash
git add scripts/deploy-all.sh scripts/tests/test_deploy_all_local.sh
git commit -m "feat(deploy): --local mode (ARM64 guard, reuse VPC/subnet, in-place bootstrap)"
```

---

### Task 10: 文档（runbook / invariants / structure / sudoers / IMDSv2）

**Files:**
- Modify: `docs/runbook.md`（新增「单台 EC2 自举部署」「本地仓上传」两节，含最小 sudoers + IMDSv2 要求）
- Modify: `docs/agent/invariants.md`（不变量1新鲜度段 + 不变量3 来源表标注 local 例外；新增 local 快照语义条目）
- Modify: `docs/structure_zh.md` + `docs/structure_en.md`（scripts 段加 `push-local-repo.sh`；index-service 段加 `reindex_local_repo.sh`）
- Modify: `scripts/README.md`（`push-local-repo.sh` 一行表项）

**Interfaces:** 无代码接口；文档与 Task 1-9 行为一致。

- [ ] **Step 1: runbook 两节**

「单台 EC2 自举部署」：开一台 **ARM64** EC2（Ubuntu 24.04；实例角色含建 ECR/AgentCore/Secrets/SSM/Bedrock + 出网；**IMDSv2 required、hop-limit 1**；该机不与其他用途共用）；deploy 用户需**免密 sudo**（或以 root 跑）——bootstrap 与 reindex 用 `sudo`；`git clone` 仓库后 `./scripts/install.sh` 或 `./scripts/deploy-all.sh --region <r> --local`；强调 AgentCore 仍托管、不占本机；前置仍需 Bedrock model access + 飞书 secret。

「本地仓上传」：projects.json 声明 `{subdir, source:"local"}`；客户机跑 `scripts/push-local-repo.sh --host <ec2> [--identity <key>] <subdir> <本地路径>`；重跑即刷新。要说明的点：
- 推送先把代码同步到主机暂存目录（`.incoming`，此时 bot 仍在线），再由主机脚本**停该项目 bot → 切换代码 → 重建图 → 起 bot**；**重建期间该项目的 bot 会离线几分钟**（取决于仓库大小，与首次建图同量级），重建失败会**自动回滚到上一版**、bot 不会服务到坏代码。**同一项目的其他仓（含 git 仓）也会在这几分钟内一并离线**（它们共用一个 bot 进程）。
- `--delete` 镜像语义（主机副本与本地一致）、自动排除 `.git`、软链不会被同步进仓（`--safe-links --no-links`）、不支持自由 `--ssh-opts`（防注入，只认 `--identity <key>`）。
- **首次推送前**：用带外渠道核对 EC2 的 SSH host key 指纹（脚本首连用 `accept-new`，会信任首次见到的指纹），或预置 `known_hosts`，以防中间人截获源码。

给出**最小 sudoers**——只授权这**一个**脚本（建/授暂存目录、切换、重建都在脚本内做，参数已被脚本内 `^[a-z0-9][a-z0-9-]*$` 校验、unit 名固定）：

```
# /etc/sudoers.d/source-truth-push  (deploy/push user only)
# push 脚本以 `sudo bash /opt/idx/app/reindex_local_repo.sh ...` 调用（不依赖 +x 位）。
<pushuser> ALL=(root) NOPASSWD: /bin/bash /opt/idx/app/reindex_local_repo.sh *
```

明确禁止把 `systemctl`、`mkdir`、`chown` 等通用命令放进 NOPASSWD（通配会被 `-R`/`..` 滥用提权）。注意：`/bin/bash <固定脚本路径> *` 把可执行体钉死在这一个脚本上，`*` 只放开它的参数（参数已被脚本内 `^[a-z0-9][a-z0-9-]*$` 校验）；**不可**写成裸 `/bin/bash *`（那等于任意命令）。

- [ ] **Step 2: invariants 改原文 + 加条目**

- 不变量1「分钟级新鲜」段：加注「**git 源**仓由 refresh timer 客观保证分钟级新鲜；**local 源**仓是经 `push-local-repo.sh` 手动推送的快照，新鲜度由人工决定」。
- 不变量3 来源表（约 47 行）：在「本地仓库副本」行标注「git 源：定时 git pull；local 源：rsync 手动推送，无 timer」。
- 新增条目：local 仓答案应可标注快照时间（host 侧 `/data/repo/<subdir>/.snapshot-time`，由 reindex 写入），低置信度转研发。

- [ ] **Step 3: structure 双语 + scripts README**

- `docs/structure_zh.md` scripts 段（62-65 行附近）加：`push-local-repo.sh  客户机侧：rsync 直推本地仓到索引主机暂存目录并触发重建（本地仓刷新入口）`；index-service 段加 `reindex_local_repo.sh  host 侧本地仓切换+重建编排（停 bridge→切换→建图→起 bridge，失败回滚）`。
- `docs/structure_en.md` 对应英文两行。
- `scripts/README.md` 表格加 `push-local-repo.sh` 一行（客户机侧、阶段标 p1、职责）。

- [ ] **Step 4: 结构自检 + 提交**

Run: `./scripts/check-invariants.sh`
Expected: PASS（双语配对/顶层目录/结构一致）。

```bash
git add docs/runbook.md docs/agent/invariants.md docs/structure_zh.md docs/structure_en.md scripts/README.md
git commit -m "docs: single-host bootstrap + local-repo ingestion (runbook, invariants, structure, sudoers)"
```

---

### Task 11: 全量离线套件验证

**Files:** 无修改——收尾验证。

- [ ] **Step 1: 离线套件**

Run: `./scripts/test.sh`
Expected: 退出码 0（lint + 全部 shell/python 单测 + typecheck；新增 `test_activate_branch.sh`/`test_reconcile_orphans.sh`/`test_local_repo_config.sh`/`test_reindex_local_repo.sh`/`test_push_local_repo.sh`/`test_bootstrap_idempotent.sh`/`test_provision_local_mode.sh`/`test_deploy_all_local.sh` + 扩充的 `test_manifest.sh` 均被发现并通过）。

- [ ] **Step 2: 结构自检**

Run: `./scripts/check-invariants.sh`
Expected: PASS。

- [ ] **Step 3: 确认工作区干净**

Run: `git status --short`
Expected: 干净。

---

## 真实集成验证（离线套件之外，必做，不可用桩刷绿）

以下行为离线只能静态测，**必须**在一台真实 ARM64 EC2 上演练一遍（与项目「真实集成禁止桩刷绿」要求一致）：

1. 全新 ARM64 EC2（仅 aws/docker/git/python3 + 实例角色 + 免密 sudo + IMDSv2 required）跑 `deploy-all.sh --region <r> --local`，**全程不另起第二台 EC2**，AgentCore runtime 正常创建。
2. 一个项目内混声明一个 git 仓 + 一个 local 仓；git 仓自动刷新；local 仓 `push-local-repo.sh` 推送后，确认：bot 重建期间离线、重建成功后恢复、graph 节点数非 0、问答能取证到 local 仓代码、`.snapshot-time` 已写。
   - **回滚臂**：故意推一份会让 build 失败的代码（如制造空目录/超限），确认 reindex **回滚到上一版**、bot 起回服务的是旧代码（不是坏代码）、退出码非零且有 `REINDEX_FAILED` 日志。
   - **软链防御**：在本地仓里放一个指向仓外（如 `/etc`）的符号链接，确认推送后主机副本里不含该软链、codegraph 未索引到仓外文件。
3. 删除该 local 仓后 `/data/repo/<sub>` 与 graph、glossary slice 均被清理，git 仓不受影响。
4. 验证专用 SG 只放行 8080-8099 自引用，客户原有 SG 仍在（附加而非替换）。

---

## Self-Review

**Spec coverage（spec §6 + review 14 条）：**
1. deploy-all `--local`（network 复用 / index-svc 本机 / image 本机）→ Task 8, 9 ✓
2. bootstrap.sh 幂等重跑 → Task 7 ✓
3. activate_project 分流（local 跳过）→ Task 2 ✓
4. install 支持本地仓 + 删项目/reconcile 兼容 + **local teardown** → Task 3, 4 ✓
5. push 脚本 → Task 6 ✓；6. schema + 模板 → Task 1 ✓；7. 文档 → Task 10 ✓
- 第一轮 review 硬伤：①单写者重建编排→Task 5 ✓；②ssh 注入→Task 6（去 --ssh-opts、数组传参）✓；③防误删→Task 5/6 ✓；④专用 SG→Task 8 ✓
- 第一轮应修：⑤测试自洽→Task 9 grep `ST_LOCAL_MODE=`、Task 2/8 多行函数+`/^}$/` 抽取 ✓；⑥SG 用 describe-instances→Task 8 ✓；⑦ARM64 自检→Task 9 ✓；⑧超时+sudo 日志→Task 8/9 ✓；⑨local teardown→Task 3 ✓；⑩sudoers→Task 10 ✓；⑪structure+example→Task 1/10 ✓；⑫invariants 原文→Task 10 ✓；⑬快照标记→Task 5 写 `.snapshot-time` + Task 10 文档 ✓；⑭IMDSv2→Task 10 ✓

**第二轮 review 修订（修复引入的新问题）：**
- 🔴 reindex 回滚语义（build 失败留「新代码+旧图」）→ Task 5 重写为 **swap+rebuild+原子回滚**：停 bridge→快照旧 live→切换→在 live 路径建图→失败 `trap rollback` 还原旧 live；放弃未验证的「.incoming 建图后 mv」方案，以重建期停机换确定正确（停机时长入 runbook）✓
- 🟠 sudoers 通配可提权 → Task 5 加 `--prepare` 子模式把建/授暂存目录收进脚本；Task 10 sudoers 收成**单脚本授权** `NOPASSWD: /opt/idx/app/reindex_local_repo.sh`，删除 mkdir/chown 通配 ✓
- 🟠 rsync 保留软链可越界 → Task 6 push 与 Task 5 落地两侧均用 `--safe-links --no-links`（落地侧用 mv，天然不引入软链；push 侧显式拒绝）✓
- 🟡 `.snapshot-time` 自删 → Task 5 改用 mv 切换（无 `--delete` rsync 剥离），标记稳定保留 ✓
- 🟡 停整项目 bridge 波及同项目其他仓 → Task 10 runbook 明说「同项目其他仓一并离线几分钟」✓
- 🟡 SG `--groups $CUR_SGS` 裸展开 → Task 8 改 `mapfile` 数组 + `grep '^sg-'` 过滤 None + 已含则跳过 ✓
- 🟡 host key TOFU → Task 10 runbook 提示首推前带外核对指纹 ✓

**第三轮 review 修订：**
- 🟡 SG 空读会替换掉客户原 SG → Task 8 加 `${#CUR_SGS[@]}>0` 守卫，fail-closed ✓
- 🟡 纯 push 时脚本可能无 +x → Task 6 改 `sudo bash <script>` 调用；Task 10 sudoers 同步为 `/bin/bash <固定脚本> *` ✓

**第四轮 review 修订（独立全量复审 H1）：**
- 🔴 删 local 仓泄漏 graph + glossary slice（reconcile 只遍历 refresh timer，local 仓无 timer 故永不被清，slice 被 glossary_read 无条件 glob 污染索引）→ Task 2 reconcile 改为按孤儿清理（初版 slice-driven，第五轮升级为 old-manifest-driven）✓

**第五轮 review 修订（多仓/路径对齐独立复审）：**
- 🔴 C1：local 仓 glossary 词表永不刷新（git 仓靠 timer→glossary_refresh.sh diff 重建；local 无 timer，reindex 只建 graph 不碰词表 → 中文词→新符号映射失效，删的旧符号仍被返回）→ Task 5 reindex 成功后追加一次 `--full` glossary 重建（镜像 activate：Bedrock precheck + 同一 per-slice flock + 后台 detached）✓
- 🟠 M1：slice-driven reconcile 在「无 Bedrock 引擎」部署下失效（local 仓没 slice → 孤儿判据落空、泄漏复发）→ Task 2 reconcile 升级为 **old-manifest-driven**（覆盖前抓旧 subdirs，孤儿=旧−新，与 timer/slice/引擎是否存在全部无关）；测试改名 `test_reconcile_orphans.sh` ✓
- 🟡 M2：build 模板未排除 `.codegraph/.home`（local reindex 走全新空目录、无残留，比 git 仓更干净；列入真机集成核对 graph 节点数）— 记录，不阻断
- 五个面（路径对齐 / bridge 多仓隔离 / 停机波及 git 仓 / `.incoming` 不干扰 glossary / serve-args 隔离）经独立复审验证正确，无需改

**Placeholder scan:** 无 TBD/TODO；每个代码步骤含完整代码块与命令、预期输出。

**Type consistency:** `source` 字段（Task 1 产出 → Task 2/3 消费 `--repo-field source` / `r.get("source","git")`）；`repo_uses_git`（Task 2 定义+测试，多行 `}` 顶格，与 `sed '/^repo_uses_git() {$/,/^}$/p'` 抽取一致）；`imds_field`/`imds_token`（Task 8 定义+测试，多行）；`reindex_local_repo.sh`（Task 5 产出 → Task 6 远程调 `/opt/idx/app/reindex_local_repo.sh`，路径与 deploy_project 的 app 目录一致）；`ST_LOCAL_MODE`/`LOCAL_MODE`（Task 8 读 `ST_LOCAL_MODE` ↔ Task 9 传 `ST_LOCAL_MODE="$LOCAL_MODE"`，测试 grep `ST_LOCAL_MODE=`）；`.incoming` 暂存目录（Task 6 推 → Task 5 落地+删）。

**Scope:** Part 1 纯逻辑/host 脚本可独立测发布；Part 2 部署改造在后。真实集成项单列，明确不可用离线桩替代。
