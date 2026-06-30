# 单台 EC2 自举 + 本地仓接入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 source-truth 能在客户手动开的单台 ARM64 EC2 上自举部署（省掉临时跳板机），并支持「本地仓经 rsync 直推 + 手动重建」与现有「git 仓自动刷新」两种代码来源同项目混用。

**Architecture:** 两部分。Part 1（本地仓接入）给 manifest schema 加可选 `source` 字段（缺省 `git`），host 侧 `activate_project.sh` 据此分流——`local` 跳过 git_fetch 与 refresh timer，只建图 + 起 bridge；新增客户机侧 `push-local-repo.sh`（rsync over SSH + 触发重建）。Part 2（单台自举）给 `deploy-all.sh` 加 `--local` 模式：复用本机 VPC/子网、本机幂等跑 `bootstrap.sh`、本机 build/push 镜像；AgentCore Runtime 仍由 boto3 托管创建。

**Tech Stack:** Bash（deploy/provision/bootstrap/activate/push 脚本）、Python 3（`render_manifest.py` 纯逻辑 + pytest 风格 shell 单测）、systemd（build@/bridge/refresh 单元）、AWS CLI v2（EC2/S3/SSM/Secrets Manager/IMDS）、Docker buildx（ARM64 镜像）。

## Global Constraints

- 会话容器 / 索引主机 **ARM64-only**；Ubuntu 24.04（glibc ≥ 2.38，codegraph-server 0.18.5 需要）。
- **代码为唯一依据**：本地仓是「快照」，非持续最新主干——答案须可标注快照时间（落 invariants 文档）。
- **单写者铁律（不变量2）**：每个 repo 一个 graph.db，build 与 bridge 共用同一 `/data/repo/<subdir>/.codegraph/.writer.lock` flock；refresh 路径永不 spawn codegraph。
- **生成物绝不手改**；改顶层目录 ⇒ 同步 `docs/structure_zh.md` 与 `_en.md`；新增 `docs/*_en.md` ⇒ 补 `_zh.md`（反之亦然）。
- **MVP 边界**：仅只读问答；AgentCore Runtime 保持 AWS 托管（不搬到 EC2 自托管）。
- Commit 用英文、Conventional Commits 前缀；**不加任何 AI 署名 trailer**。
- 离线测试入口 `./scripts/test.sh`；结构自检 `./scripts/check-invariants.sh`。
- `source` 字段枚举：`"git"`（缺省）| `"local"`。`local` 仓无 `git`/`ref`/`refreshIntervalSec`。
- subdir 正则 `\A[a-z0-9][a-z0-9-]*\Z`（已有，沿用）；subdir 全局唯一（跨项目）。

---

# Part 1 — 本地仓接入（manifest schema + 分流 + push 脚本）

> Part 1 自成可发布单元：schema 与分流是纯逻辑，可离线测试；push 脚本可在不动 Part 2 的前提下对现有部署使用。

### Task 1: manifest schema 接纳 `source` 字段（纯逻辑 + 单测）

**Files:**
- Modify: `scripts/lib/render_manifest.py`（`parse_manifest` 校验循环 84-86 行附近；`build_multi_manifest` 158-163 行附近；`REPO_FIELDS` 207 行）
- Test: `scripts/tests/test_manifest.sh`（追加用例）

**Interfaces:**
- Produces: `parse_manifest(raw)` 每条 repo dict 新增键 `"source"`（值 `"git"` 或 `"local"`，缺省 `"git"`）。`build_multi_manifest(project_id, port, repos, default_interval=None)` 透传每个 `r.get("source")`。`--repo-field source <subdir>` 与 `--field source` 可用。
- Consumes（来自既有代码）：`SUBDIR_RE`、`_validate_top`、`serve_args`。

- [ ] **Step 1: 写失败测试**

在 `scripts/tests/test_manifest.sh` 末尾（`trap` 之后、汇总 echo 之前）追加：

```bash
# --- source: local omits git + ref; defaults to git when absent ---
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"localrepo","source":"local"}]}'
out="$(python3 "$R" "$TMP/m.json" 2>"$TMP/err")"; rc=$?
check "local-source repo parses without git (rc 0)" "$rc"
printf '%s' "$out" | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); assert r["source"]=="local" and r["git"]=="", r'; check "local repo: source=local, git empty" $?

mk '{"projectId":"p","port":8080,"repos":[{"subdir":"g","git":"https://x/g.git"}]}'
printf '%s' "$(python3 "$R" "$TMP/m.json")" | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); assert r["source"]=="git", r'; check "absent source defaults to git" $?

# --- invalid: git source without git url still fails loud ---
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"g","source":"git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]]; check "git source without git url rejected" $?

# --- invalid: unknown source value ---
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"g","source":"svn","git":"x"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]]; check "unknown source value rejected" $?

# --- --repo-field source ---
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"loc","source":"local"}]}'
[[ "$(python3 "$R" --repo-field source loc "$TMP/m.json")" == "local" ]]; check "--repo-field source prints local" $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_manifest.sh`
Expected: 新增用例 FAIL（当前 `source` 未知键被忽略、`git` 缺失对 local 仍报错、`source` 不在 `REPO_FIELDS`）。

- [ ] **Step 3: 改 `render_manifest.py` 实现**

在 `parse_manifest` 的循环内，把 `git` 校验改为 source-aware，并产出 `source`。将现有（73-86 行）：

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
        else:  # local: pushed via rsync, no git remote
            if git is not None and not isinstance(git, str):
                raise ValueError(f"{where}: 'git' must be a string if present")
            git = ""  # local repos carry no remote
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

在 `build_multi_manifest`（160-163 行）把 entry 构造改为透传 source：

```python
    for r in repos:
        entry = {"subdir": r["subdir"]}
        src = r.get("source", "git")
        entry["source"] = src
        if src == "git":
            entry["git"] = r["git"]
            entry["ref"] = r.get("ref") or ""
        iv = r.get("refreshIntervalSec")
        entry["refreshIntervalSec"] = iv if isinstance(iv, int) else default_interval
        out_repos.append(entry)
```

把 `REPO_FIELDS`（207 行与 main 顶部的同名常量）加入 `"source"`：

```python
    REPO_FIELDS = ("subdir", "source", "git", "ref", "sig", "refreshIntervalSec")
```

并更新模块 docstring 的 Manifest shape 段，注明 `source` 可选（`git`|`local`，缺省 `git`），local 仓无 git/ref。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_manifest.sh`
Expected: 全部 ok，含原有 git 用例（回归未破）。

- [ ] **Step 5: 提交**

```bash
git add scripts/lib/render_manifest.py scripts/tests/test_manifest.sh
git commit -m "feat(manifest): accept optional repo source field (git|local)"
```

---

### Task 2: `activate_project.sh` 按 source 分流（local 跳过 git_fetch + 不建 refresh timer）

**Files:**
- Modify: `index-service/activate_project.sh`（92-142 行 per-repo 循环；181-201 行 reconcile 区不变但需复核；227-265 行 glossary 初建——local 仓同样建词表，因其代码已在本地）
- Test: 复用 `scripts/tests/test_git_fetch.sh` 旁新增 `scripts/tests/test_activate_branch.sh`（纯 bash，断言「source 分流」的可测片段：把分流判定抽成一个小函数或用 render_manifest 输出驱动）

**Interfaces:**
- Consumes: `render_manifest.py --repo-field source <subdir> <manifest>`（Task 1 产出）。
- Produces: 对 `source==local` 的 subdir：不调用 `git_fetch.sh`、不写 `index-refresh-<subdir>.{service,timer}`；仍 `mkdir` graph 目录、纳入 `BUILD_UNITS` 与 `SERVE_FLOCKS`、跑 `index-build@<subdir>`、纳入 bridge serve。要求 `/data/repo/<subdir>` 已由 push 脚本填充，否则 `index-build@` 的 ExecStartPre 空目录守卫 fail-loud。

- [ ] **Step 1: 写失败测试**

新建 `scripts/tests/test_activate_branch.sh`：断言 activate_project.sh 对 local 源既不生成 refresh 单元、也不调用 git_fetch。用一个可 source 的纯函数承载分流判断，测试直接调它。先写测试（会因函数不存在而失败）：

```bash
#!/usr/bin/env bash
# test_activate_branch.sh — the source-aware branch logic in activate_project.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_activate_branch:"

# Source ONLY the helper (activate_project.sh guards real work behind `main`-style exec; the
# helper is defined at top and is side-effect-free). We grep it out to keep the test hermetic.
HELPER="$(sed -n '/^repo_uses_git()/,/^}/p' "$ROOT/index-service/activate_project.sh")"
eval "$HELPER"

repo_uses_git git;  check "git source uses git"        $([[ $? -eq 0 ]] && echo 0 || echo 1)
repo_uses_git "";   rc=$?; [[ $rc -eq 0 ]]; check "empty/absent source defaults to git" $?
repo_uses_git local; rc=$?; [[ $rc -ne 0 ]]; check "local source does NOT use git" $?

[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_activate_branch.sh`
Expected: FAIL —— `repo_uses_git` 未定义（`sed` 抓不到，`eval` 空）。

- [ ] **Step 3: 改 `activate_project.sh` 实现**

在脚本顶部（`set -euo pipefail` 与 `exec >` 之后、变量定义区）加入纯函数：

```bash
# repo_uses_git <source>: rc 0 if this repo is fetched via git (default), non-zero for local.
# Local repos are pushed to /data/repo/<subdir> out-of-band (scripts/push-local-repo.sh) and
# refreshed manually — they get NO git_fetch and NO refresh timer.
repo_uses_git() { [ "${1:-git}" != "local" ]; }
```

在 per-repo 循环（92-142 行）内，读出 source 并据此分流。把现有（95-101 行）：

```bash
  GIT_URL="$(python3 "$RENDER_MANIFEST" --repo-field git "$SUBDIR" "$MANIFEST")" \
    || { echo "ACTIVATE_FAILED: no git url for $SUBDIR"; exit 1; }
  GIT_REF="$(python3 "$RENDER_MANIFEST" --repo-field ref "$SUBDIR" "$MANIFEST" || echo "")"
  IV="$(python3 "$RENDER_MANIFEST" --repo-field refreshIntervalSec "$SUBDIR" "$MANIFEST" 2>/dev/null || echo "")"
  [ -n "$IV" ] && [ "$IV" != "None" ] || IV=300

  bash "$GIT_FETCH" "$SUBDIR" "$GIT_URL" "$GIT_REF" "$WS" \
    || { echo "ACTIVATE_FAILED: git fetch $SUBDIR"; exit 1; }
  # graph dirs INSIDE $WS ...
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
    # LOCAL source: code is pushed out-of-band to $WS by scripts/push-local-repo.sh. Refuse to
    # proceed if it hasn't landed yet — index-build@ would otherwise fail on its empty-dir guard
    # with a less obvious message.
    if [ -z "$(ls -A "$WS" 2>/dev/null)" ]; then
      echo "ACTIVATE_FAILED: local repo '$SUBDIR' has no code at $WS — push it first (scripts/push-local-repo.sh)"
      exit 1
    fi
    echo "activate: $SUBDIR is a LOCAL repo (no git fetch, no refresh timer)"
  fi
  # graph dirs INSIDE $WS (proven layout); created after fetch/push, git-untracked so reset --hard keeps them.
  mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"
```

把写 refresh service+timer 的两段 here-doc（120-141 行）整体包进 `if repo_uses_git "$SRC"; then ... fi`（local 仓不建 refresh 单元）：在 `cat > "/etc/systemd/system/index-refresh-${SUBDIR}.service"` 之前加 `if repo_uses_git "$SRC"; then`，在 timer here-doc 的结束 `UNIT` 之后加 `fi`。

在「enable refresh timers」循环（205-207 行）里同样跳过 local：

```bash
for SUBDIR in $SUBDIRS; do
  SRC="$(python3 "$RENDER_MANIFEST" --repo-field source "$SUBDIR" "$MANIFEST" 2>/dev/null || echo git)"
  repo_uses_git "${SRC:-git}" || { echo "activate: skip refresh timer for local repo $SUBDIR"; continue; }
  systemctl enable --now "index-refresh-${SUBDIR}.timer"
done
```

glossary 初建（218-265 行）对 local 仓**照常**进行（其代码已在本地，词表有价值），无需改动。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_activate_branch.sh && bash scripts/tests/test_manifest.sh`
Expected: 两者全 ok。

- [ ] **Step 5: 提交**

```bash
git add index-service/activate_project.sh scripts/tests/test_activate_branch.sh
git commit -m "feat(index): branch activate_project by repo source (skip git fetch + refresh timer for local)"
```

---

### Task 3: 删项目 / reconcile 兼容无 git 仓

**Files:**
- Modify: `scripts/install.sh`（`flow_remove_project` 的 `FALLBACK_SUBS` 计算 550-556 行 + 主机侧 `RM_CMD` 576-581 行——已用 `r['subdir']`，需复核对 local 仓不引用 git）
- Modify: `index-service/activate_project.sh`（reconcile 区 191-201 行——按 subdir/slice 工作，复核 local 仓不被误判）

**Interfaces:**
- Consumes: `projects.json` 里 `{subdir, source:"local"}` 条目（无 `git`）。
- Produces: 删除/重配 local 仓时不因缺 `git` 键抛 KeyError；停 `index-build@<sub>`、删 `/data/repo/<sub>`、删 glossary slice，但不试图停不存在的 `index-refresh-<sub>.timer`（`systemctl disable` 对不存在单元是良性 no-op，无需特判）。

- [ ] **Step 1: 写失败测试**

`flow_remove_project` 的 `FALLBACK_SUBS` 已只读 `r.get("subdir","")`，不碰 git——但加一个守卫测试确保 install.sh 里所有读 repos 的 python 片段对 local 条目安全。新建 `scripts/tests/test_local_repo_config.sh`：

```bash
#!/usr/bin/env bash
# test_local_repo_config.sh — projects.json with a local-source repo round-trips through the
# python snippets install.sh / deploy_project.sh use (no KeyError on missing 'git').
set -uo pipefail
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_local_repo_config:"
command -v python3 >/dev/null 2>&1 || { echo "  skip (no python3)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/projects.json" <<'JSON'
{"refreshIntervalSec":300,"projects":{"demo":{"port":8080,"feishuSecretId":"source-truth/feishu-demo","repos":[{"subdir":"loc","source":"local"},{"subdir":"g","git":"https://x/g.git"}]}}}
JSON

# FALLBACK_SUBS snippet (install.sh flow_remove_project)
subs="$(SEL=demo python3 -c 'import json,os,sys
cfg=json.load(open(sys.argv[1]))
p=cfg.get("projects",{}).get(os.environ["SEL"],{})
print(" ".join(r.get("subdir","") for r in p.get("repos",[]) if r.get("subdir")))' "$TMP/projects.json")"
[[ "$subs" == "loc g" ]]; check "remove-flow subdir list includes local repo" $?

# deploy_project.sh read_proj specs snippet (must not KeyError on missing git)
ok="$(python3 -c 'import json,sys
cfg=json.load(open(sys.argv[1])); p=cfg["projects"]["demo"]
specs=[{"subdir":r["subdir"],"source":r.get("source","git"),"git":r.get("git",""),"ref":r.get("ref","")} for r in p["repos"]]
print("ok" if specs[0]["source"]=="local" and specs[0]["git"]=="" else "bad")' "$TMP/projects.json")"
[[ "$ok" == "ok" ]]; check "read_proj specs tolerate missing git on local repo" $?

[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认状态**

Run: `bash scripts/tests/test_local_repo_config.sh`
Expected: 第 1 条 ok（现有片段已用 `.get`）；第 2 条 FAIL —— `deploy_project.sh` 的 `read_proj`（30-43 行）现用 `r["git"]`，对 local 仓 KeyError。

- [ ] **Step 3: 改 `deploy_project.sh` 的 `read_proj`**

把 `scripts/lib/deploy_project.sh` 的 specs 推导（36-37 行）：

```python
    specs = [{"subdir": r["subdir"], "git": r["git"], "ref": r.get("ref", ""),
              "refreshIntervalSec": r.get("refreshIntervalSec")} for r in p["repos"]]
```

改为 source-aware（git 缺省，local 不要求 git）：

```python
    specs = [{"subdir": r["subdir"], "source": r.get("source", "git"),
              "git": r.get("git", ""), "ref": r.get("ref", ""),
              "refreshIntervalSec": r.get("refreshIntervalSec")} for r in p["repos"]]
```

（`build_multi_manifest` 已在 Task 1 接纳 `source` 并对 git 仓要求 git、对 local 仓忽略 git，故此处透传即可。）

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_local_repo_config.sh`
Expected: 两条均 ok。

- [ ] **Step 5: 提交**

```bash
git add scripts/lib/deploy_project.sh scripts/tests/test_local_repo_config.sh
git commit -m "fix(deploy): tolerate local-source repos (missing git) in read_proj"
```

---

### Task 4: `install.sh` 添加项目流程支持「本地仓」类型

**Files:**
- Modify: `scripts/install.sh`（`flow_add_project` 的 repo 录入循环 367-380 行；git 凭证匿名探测 461-494 行——仅对 git 仓探测）

**Interfaces:**
- Consumes: 操作员交互输入。
- Produces: 写入 `projects.json` 的 repo 条目对本地仓为 `{"subdir":<name>,"source":"local"}`（无 git/ref）；git 仓维持 `{"subdir","git","ref"}`。subdir 冲突检查（386-402 行）与端口逻辑不变（已与 source 无关）。

- [ ] **Step 1: 改 repo 录入循环**

把 `flow_add_project` 的录入循环（367-380 行）改为先选来源类型，再按类型收集字段：

```bash
  local REPOS_JSON="[]" RGIT RSUB RREF RSRC N=0
  say info "逐个添加该项目的代码仓库（仓库名留空结束）/ add repos (blank subdir = done):"
  while true; do
    ask RSUB "  第 $((N + 1)) 个仓库 · on-host 子目录名 / repo #$((N + 1)) subdir (^[a-z0-9-]+$, blank=done)" ""
    [[ -z "$RSUB" ]] && break
    [[ "$RSUB" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { say warn "subdir 非法，跳过 / invalid subdir, skipped"; continue; }
    local SRC_CHOICE
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
      say ok "    已加入 git 仓 / git repo #$((N+1)): $RSUB ← $RGIT${RREF:+ @$RREF}"
    else
      REPOS_JSON="$(RSUB="$RSUB" python3 -c '
import json,os,sys
a=json.loads(sys.argv[1]); a.append({"subdir":os.environ["RSUB"],"source":"local"}); print(json.dumps(a))' "$REPOS_JSON")"
      say ok "    已加入本地仓 / local repo #$((N+1)): $RSUB （部署后用 scripts/push-local-repo.sh 推送代码）"
    fi
    N=$((N + 1))
  done
  [[ "$REPOS_JSON" != "[]" ]] || { say err "至少要一个仓库 / need at least one repo"; exit 1; }
```

- [ ] **Step 2: git 凭证匿名探测只对 git 仓**

匿名探测块（461-494 行）从 `REPOS_JSON` 抽 git URL 的 here-string（476-477 行）已只产出有 `git` 字段者的 URL；local 条目无 `git` 键，`r.get("git","")` 返回空被 `[[ -n "$RURL" ]] || continue` 跳过。复核该 python 片段用的是 `r.get("git","")` 而非 `r["git"]`；若为后者则改为 `.get`。

- [ ] **Step 3: 手测（无 AWS 的录入路径）**

因 `flow_add_project` 含 AWS 调用，仅离线验证录入片段：用 `--yes` 不可（需交互选择），改为提取片段做一次手动 dry 验证或在 PR 描述中记录人工演练。最低限度跑：

Run: `bash -n scripts/install.sh`
Expected: 语法检查通过（无 `bash -n` 报错）。

- [ ] **Step 4: 提交**

```bash
git add scripts/install.sh
git commit -m "feat(install): let add-project choose git or local repo source"
```

---

### Task 5: 新增客户机侧 `scripts/push-local-repo.sh`（rsync 直推 + 触发重建）

**Files:**
- Create: `scripts/push-local-repo.sh`
- Test: `scripts/tests/test_push_local_repo.sh`（纯 bash：参数校验 + dry-run 命令拼装，不真连主机）

**Interfaces:**
- Consumes: 客户机上的本地仓路径、目标 EC2 的 SSH 可达地址（`--host`）、subdir。
- Produces: 把本地仓 `rsync -az --delete --exclude .git` 到 `<host>:/data/repo/<subdir>`，随后经 SSH 触发 `sudo systemctl start index-build@<subdir>.service` 并等待结果。`--dry-run` 只打印将执行的 rsync/ssh 命令。

- [ ] **Step 1: 写失败测试**

新建 `scripts/tests/test_push_local_repo.sh`：

```bash
#!/usr/bin/env bash
# test_push_local_repo.sh — argument validation + dry-run command assembly. No network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$ROOT/scripts/push-local-repo.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_push_local_repo:"

# missing args → non-zero + usage
bash "$S" 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "no args exits non-zero" $?

# invalid subdir rejected
bash "$S" --host h "Bad/Sub" /tmp 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "invalid subdir rejected" $?

# dry-run prints rsync + ssh build trigger, runs nothing
SRC="$(mktemp -d)"; echo hi > "$SRC/f.txt"
out="$(bash "$S" --host ec2host --dry-run localsub "$SRC" 2>&1)"; rc=$?
[[ $rc -eq 0 ]]; check "dry-run rc 0" $?
grep -q 'rsync' <<<"$out" && grep -q -- '--delete' <<<"$out"; check "dry-run shows rsync --delete" $?
grep -q '/data/repo/localsub' <<<"$out"; check "dry-run targets /data/repo/<subdir>" $?
grep -q 'index-build@localsub' <<<"$out"; check "dry-run shows rebuild trigger" $?
rm -rf "$SRC"
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_push_local_repo.sh`
Expected: FAIL —— 脚本不存在。

- [ ] **Step 3: 写 `scripts/push-local-repo.sh`**

```bash
#!/usr/bin/env bash
# push-local-repo.sh — push a LOCAL repo from the operator's machine to the source-truth index
# host, then trigger a one-shot reindex. This is the ingestion path for repos declared with
# {"source":"local"} in projects.json (no git remote). Re-run it whenever the local code changes
# — that IS the refresh (local repos are snapshots, not auto-pulled).
#
#   scripts/push-local-repo.sh --host <ec2-ssh-host> <subdir> <local-path> [--dry-run] [--ssh-opts "..."]
#
# <subdir> must match the subdir declared for this repo in projects.json. The code lands at
# /data/repo/<subdir> on the host; rsync --delete makes the host copy an exact mirror of <local-path>.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# common.sh gives say(); fall back to plain echo if sourced outside the repo.
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then # shellcheck source=lib/common.sh
  source "$SCRIPT_DIR/lib/common.sh"; else say() { shift; printf '%s\n' "$*"; }; fi

HOST="" DRY=false SSH_OPTS="" SUBDIR="" LOCAL_PATH=""
usage() { sed -n '2,12p' "$0"; exit "${1:-2}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    --ssh-opts) SSH_OPTS="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) say err "unknown flag: $1"; usage ;;
    *) if [ -z "$SUBDIR" ]; then SUBDIR="$1"; elif [ -z "$LOCAL_PATH" ]; then LOCAL_PATH="$1"; else say err "too many args"; usage; fi; shift ;;
  esac
done

[ -n "$HOST" ] || { say err "--host <ec2-ssh-host> required"; usage; }
[ -n "$SUBDIR" ] && [ -n "$LOCAL_PATH" ] || { say err "need <subdir> and <local-path>"; usage; }
case "$SUBDIR" in [a-z0-9]*) : ;; *) say err "subdir must start alphanumeric"; exit 2 ;; esac
printf '%s' "$SUBDIR" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { say err "subdir must match ^[a-z0-9][a-z0-9-]*$"; exit 2; }
[ -d "$LOCAL_PATH" ] || { say err "local path not a directory: $LOCAL_PATH"; exit 2; }

# Trailing slash on src so rsync copies CONTENTS into /data/repo/<subdir> (not a nested dir).
SRC="${LOCAL_PATH%/}/"
DEST="/data/repo/${SUBDIR}"
# shellcheck disable=SC2206
SSH_ARR=(ssh $SSH_OPTS)
RSYNC=(rsync -az --delete --exclude '.git' --exclude '.codegraph' --exclude '.home'
  -e "ssh ${SSH_OPTS}" "$SRC" "${HOST}:${DEST}/")
# rebuild trigger: oneshot build unit holds the per-repo writer flock (single-writer safe).
REBUILD="sudo mkdir -p ${DEST} && sudo systemctl reset-failed index-build@${SUBDIR}.service 2>/dev/null; sudo systemctl start index-build@${SUBDIR}.service && sudo systemctl is-active index-build@${SUBDIR}.service || sudo systemctl status --no-pager index-build@${SUBDIR}.service"

if [ "$DRY" = true ]; then
  say info "[dry-run] mkdir on host: ${SSH_ARR[*]} ${HOST} sudo mkdir -p ${DEST}"
  say info "[dry-run] ${RSYNC[*]}"
  say info "[dry-run] rebuild: ${SSH_ARR[*]} ${HOST} ${REBUILD}"
  exit 0
fi

say step "ensuring ${DEST} exists on ${HOST}"
"${SSH_ARR[@]}" "$HOST" "sudo mkdir -p ${DEST} && sudo chown \$(id -u):\$(id -g) ${DEST}"
say step "rsync ${SRC} → ${HOST}:${DEST}"
"${RSYNC[@]}"
say step "triggering reindex (index-build@${SUBDIR})"
"${SSH_ARR[@]}" "$HOST" "$REBUILD"
say ok "pushed + reindex triggered for local repo '${SUBDIR}'"
```

注：`--exclude .git` 与 manifest `.codegraph/.home` 保护一致——host 侧 graph 目录在 `$WS/.codegraph`，rsync `--delete` 必须排除，否则会删掉活动 graph.db。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_push_local_repo.sh && bash -n scripts/push-local-repo.sh`
Expected: 测试全 ok；语法检查通过。

- [ ] **Step 5: 提交**

```bash
chmod +x scripts/push-local-repo.sh
git add scripts/push-local-repo.sh scripts/tests/test_push_local_repo.sh
git commit -m "feat(scripts): add push-local-repo.sh for rsync-based local repo ingestion"
```

---

# Part 2 — 单台 EC2 自举（deploy-all 本地模式）

> Part 2 依赖 Part 1 的 schema 不变（无强耦合），但独立交付价值：把部署从「跳板机 + 新建 EC2」改为「本机自举」。

### Task 6: `bootstrap.sh` 可在已运行主机上幂等重跑

**Files:**
- Modify: `index-service/bootstrap.sh`（51 行 `exec > /var/log/... 2>&1` 不变；55 行 `source /etc/index-service.env` 需容忍由 deploy 本地写入；全脚本已大体幂等，重点是去掉对「首次 user-data」的隐含依赖）
- Test: `scripts/tests/test_bootstrap_idempotent.sh`（`bash -n` + 关键幂等片段的静态断言）

**Interfaces:**
- Consumes: `/etc/index-service.env`（含 `BUCKET/REGION/MAX_FILES/MODEL/GLOSSARY_MAX_FILES`），无论由 EC2 user-data 还是 deploy 本地模式写入。
- Produces: 在已 apt/codegraph/gateway 就绪的主机上重跑时不报错、不重复破坏（apt 幂等、`ln -sf`、`systemctl daemon-reload` 安全），最终仍打印 `BOOTSTRAP_DONE`。

- [ ] **Step 1: 写测试（静态断言幂等性质）**

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
# idempotent symlink (ln -sf, not ln -s)
grep -q 'ln -sf .* /usr/local/bin/codegraph-server' "$B"; check "codegraph symlink uses ln -sf" $?
# guarded node install (command -v node before install)
grep -q 'command -v node >/dev/null 2>&1 && return 0' "$B"; check "ensure_node guards re-install" $?
# log path is a FIXED file (re-run overwrites, not appends garbage) — acceptable for re-run
grep -q 'exec > /var/log/index-svc-bootstrap.log 2>&1' "$B"; check "bootstrap logs to fixed file" $?
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试**

Run: `bash scripts/tests/test_bootstrap_idempotent.sh`
Expected: 全 ok（bootstrap.sh 现状已满足这些性质——本测试是「防回归」护栏；若某条 FAIL 则按断言修 bootstrap.sh）。

- [ ] **Step 3: 确保 `set -euxo pipefail` 下重跑安全的一处修正**

`apt-get install` 与 `pip3 install` 在已装环境重跑是幂等的；唯一非幂等风险是 50 行 `set -e` 下 `dpkg -i` CloudWatch agent 已装时返回非零。复核 266-300 行 CloudWatch 块已用 `|| apt-get install -f -y || true` 容错——无需改。若 `bash -n` 与上述断言全过，本步为 no-op，记录「bootstrap.sh 已幂等，新增护栏测试」。

- [ ] **Step 4: 提交**

```bash
git add scripts/tests/test_bootstrap_idempotent.sh
git commit -m "test(bootstrap): guard re-run idempotency for local-mode bootstrap"
```

---

### Task 7: `provision_index_service.sh` 支持「本机即索引主机」本地模式

**Files:**
- Modify: `scripts/lib/provision_index_service.sh`（顶部参数区 16-24 行新增 `LOCAL_MODE`；reuse/launch 主体——本地模式下跳过 AMI/run-instances，直接在本机写 env + 跑 bootstrap.sh，打印本机私有 IP）
- Test: `scripts/tests/test_provision_local_mode.sh`（纯 bash：本地模式分支选择 + IMDS IP 获取函数，mock IMDS）

**Interfaces:**
- Consumes: 环境变量 `ST_LOCAL_MODE=true`（由 deploy-all `--local` 传入）；IMDSv2 获取本机私有 IP；`/etc/index-service.env` 由本函数写入。
- Produces: 本地模式下 `INDEX_SERVICE_INSTANCE` 设为本机 instance-id、`INDEX_SERVICE_IP` 为本机私有 IP、`INDEX_SERVICE_SG` 设为本机第一个 SG；stdout 打印本机私有 IP（与远程模式契约一致）。

- [ ] **Step 1: 写失败测试**

新建 `scripts/tests/test_provision_local_mode.sh`，针对抽出的纯函数 `imds_field`（用一个可注入的 curl 命令）：

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_provision_local_mode:"
HELPER="$(sed -n '/^imds_field()/,/^}/p' "$ROOT/scripts/lib/provision_index_service.sh")"
[[ -n "$HELPER" ]]; check "imds_field helper exists" $?
eval "$HELPER"
# inject a fake curl that echoes a token then the field
curl() { case "$*" in *api/token*) echo TOKEN;; *local-ipv4*) echo 10.1.2.3;; *instance-id*) echo i-abc;; *) echo "";; esac; }
export -f curl 2>/dev/null || true
[[ "$(imds_field local-ipv4)" == "10.1.2.3" ]]; check "imds_field reads local-ipv4" $?
[[ "$(imds_field instance-id)" == "i-abc" ]]; check "imds_field reads instance-id" $?
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_provision_local_mode.sh`
Expected: FAIL —— `imds_field` 未定义。

- [ ] **Step 3: 实现本地模式**

在 `provision_index_service.sh` 参数区后加入 helper 与本地模式分支。新增（24 行 `log()` 之后）：

```bash
LOCAL_MODE="${ST_LOCAL_MODE:-false}"

# imds_field <name>: read an IMDSv2 metadata field from THIS instance (local mode). Token-first.
imds_field() {
  local tok
  tok="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo "")"
  curl -fsS -H "X-aws-ec2-metadata-token: $tok" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo ""
}
```

在 reuse 逻辑之前（95 行 `CURRENT_SIG=` 之后、reconcile 之前）插入本地模式短路分支：

```bash
if [[ "$LOCAL_MODE" == "true" ]]; then
  log step "local mode: this host IS the index host — running bootstrap.sh in place"
  SELF_IP="$(imds_field local-ipv4)"; SELF_ID="$(imds_field instance-id)"
  [[ -n "$SELF_IP" ]] || { log err "local mode: could not read local-ipv4 from IMDS (is this an EC2 instance with IMDS enabled?)"; exit 1; }
  SELF_SG="$(imds_field "network/interfaces/macs/$(imds_field network/interfaces/macs | head -1)security-group-ids" | head -1)"
  # write the base env the bootstrap reads, then run it in place (idempotent — Task 6).
  sudo tee /etc/index-service.env >/dev/null <<ENV
BUCKET='$BUCKET'
REGION='$REGION'
MAX_FILES='$MAX_FILES'
MODEL='$MODEL'
GLOSSARY_MAX_FILES='$GLOSSARY_MAX_FILES'
ENV
  sudo -E bash "$ROOT/index-service/bootstrap.sh" >&2 || { log err "local-mode bootstrap.sh failed — see /var/log/index-svc-bootstrap.log"; exit 1; }
  # SG: in local mode the operator's instance already has its SG; reconcile the bridge-port range on it.
  if [[ -n "$SELF_SG" && "$SELF_SG" != "None" ]]; then reconcile_index_sg_ingress "$SELF_SG"; update_env "$CONFIG" INDEX_SERVICE_SG "$SELF_SG"; fi
  update_env "$CONFIG" INDEX_SERVICE_INSTANCE "${SELF_ID:-local}"
  log info "local mode: index host ready at $SELF_IP (instance ${SELF_ID:-?}, sg ${SELF_SG:-?})"
  echo "$SELF_IP"; exit 0
fi
```

注：`reconcile_index_sg_ingress` 与 `authorize_ingress` 定义在 57-79 行（本分支之前），可调用。本地模式不依赖 `VPC_ID`（不新建 SG，只在本机现有 SG 上加端口段）。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_provision_local_mode.sh && bash -n scripts/lib/provision_index_service.sh`
Expected: 测试 ok；语法检查通过。

- [ ] **Step 5: 提交**

```bash
git add scripts/lib/provision_index_service.sh scripts/tests/test_provision_local_mode.sh
git commit -m "feat(provision): local mode — bootstrap the index service in place on this EC2"
```

---

### Task 8: `deploy-all.sh` 加 `--local` 串起本地模式

**Files:**
- Modify: `scripts/deploy-all.sh`（flag 解析区；Phase 2 network 514-531 行；Phase 3 index-svc 534-541 行；Phase 4 image 632-664 行 平台守卫）
- Create: `scripts/tests/test_deploy_all_local.sh`（**新建**独立测试文件——既有 `test_deploy.sh` 只测已废弃的 `deploy.sh` 垫片且**严格离线无 AWS**；`deploy-all.sh --dry-run` 会调 `aws sts`，故本测试**只做离线静态断言**：usage 含 `--local` + `bash -n` + 源码含本地模式分支，绝不实际执行 deploy-all）

**Interfaces:**
- Consumes: 操作员 `--local`。
- Produces: `--local` 时——Phase 2 跳过 VPC/NAT 新建（复用本机网络，不调 `provision_network.sh`，从 IMDS/现有 deploy-config 取 `PRIVATE_SUBNET` 等所需值）；Phase 3 以 `ST_LOCAL_MODE=true` 调 `provision_index_service.sh`；Phase 4 因本机即 ARM64，buildx 平台守卫直接放行。

- [ ] **Step 1: 写失败测试（纯离线静态断言）**

新建 `scripts/tests/test_deploy_all_local.sh`：

```bash
#!/usr/bin/env bash
# test_deploy_all_local.sh — OFFLINE static checks for deploy-all.sh --local. We do NOT execute
# deploy-all (even --dry-run calls aws sts); we assert the flag is wired + the local-mode branch
# exists, plus a syntax check.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$ROOT/scripts/deploy-all.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_deploy_all_local:"

bash -n "$D"; check "deploy-all.sh parses" $?
"$D" --help 2>&1 | grep -q -- '--local'; check "--help documents --local" $?
grep -q -- '--local) LOCAL_MODE=true' "$D"; check "--local sets LOCAL_MODE" $?
grep -q 'ST_LOCAL_MODE="\$LOCAL_MODE"' "$D"; check "Phase 3 passes ST_LOCAL_MODE to provisioner" $?
grep -q 'local mode' "$D"; check "Phase 2 has a local-mode network branch" $?
[[ "$_fail" -eq 0 ]]; exit $?
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash scripts/tests/test_deploy_all_local.sh`
Expected: FAIL —— `--local` 未接线、源码无 local-mode 分支。

- [ ] **Step 3: 实现 `--local`**

在 flag 解析（与 `--refresh-index` 等并列处，约 `REFRESH_INDEX=false` 附近）加：

```bash
LOCAL_MODE=false   # --local: this EC2 IS the index host; bootstrap in place, reuse this VPC/subnet
```

在 `while`/`case` 参数解析里加分支：

```bash
    --local) LOCAL_MODE=true ;;
```

usage 文本补一行说明。

Phase 2（network）整体在本地模式下改为复用、不新建。把 514-531 行包一层：

```bash
if [[ "$LOCAL_MODE" == true ]]; then
  say step "Phase 2: network (local mode — reuse this host's VPC/subnet)"
  # In local mode we don't create a VPC/NAT. The operator's EC2 already lives in a subnet with
  # egress. Derive PRIVATE_SUBNET/VPC_ID from IMDS so later phases (runtime ENI placement) have them.
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] local mode: reuse VPC/subnet from this instance's IMDS; no VPC/NAT created"
  else
    _TOK="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || echo '')"
    _MAC="$(curl -fsS -H "X-aws-ec2-metadata-token: $_TOK" http://169.254.169.254/latest/meta-data/network/interfaces/macs/ 2>/dev/null | head -1)"
    SELF_SUBNET="$(curl -fsS -H "X-aws-ec2-metadata-token: $_TOK" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${_MAC}subnet-id" 2>/dev/null || echo '')"
    SELF_VPC="$(curl -fsS -H "X-aws-ec2-metadata-token: $_TOK" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${_MAC}vpc-id" 2>/dev/null || echo '')"
    [[ -n "$SELF_SUBNET" && -n "$SELF_VPC" ]] || { say err "local mode: could not read subnet/vpc from IMDS"; exit 1; }
    update_env "$CONFIG_FILE" PRIVATE_SUBNET "$SELF_SUBNET"
    update_env "$CONFIG_FILE" VPC_ID "$SELF_VPC"
    safe_source_env "$CONFIG_FILE"
    say ok "local mode: reusing VPC $SELF_VPC / subnet $SELF_SUBNET (no VPC/NAT created)"
  fi
elif skip network; then say warn "skip network"; else
  # ... existing Phase 2 body unchanged ...
fi
```

Phase 3 调用传 `ST_LOCAL_MODE`：把 541-542 行的调用改为

```bash
  INDEX_IP="$(ST_LOCAL_MODE="$LOCAL_MODE" "$SCRIPT_DIR/lib/provision_index_service.sh" \
    "$REGION" "$CONFIG_FILE" "$BUCKET" "$MAX_FILES" "$INSTANCE_TYPE" "$REFRESH_INDEX" "$ROOT_VOLUME_GB" "$MODEL" "$GLOSSARY_MAX_FILES")"
```

本地模式下 `provision_index_service.sh` 自己跑了 bootstrap（同步），故其后的 `wait_base_host.sh`（SSM 等待）在本地模式应跳过——把那段（547 行起）包 `if [[ "$LOCAL_MODE" != true ]]; then ... fi`，本地模式下改为直接确认 `/var/log/index-svc-bootstrap.log` 末尾有 `BOOTSTRAP_DONE`：

```bash
  if [[ "$LOCAL_MODE" == true ]]; then
    grep -q BOOTSTRAP_DONE /var/log/index-svc-bootstrap.log 2>/dev/null \
      || { say err "local-mode bootstrap did not finish (no BOOTSTRAP_DONE) — see /var/log/index-svc-bootstrap.log"; exit 1; }
    say ok "local-mode base host bootstrap confirmed"
  elif [[ "$DRY_RUN" != true ]] && [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then
    # ... existing wait_base_host.sh block ...
  fi
```

Phase 4（image）平台守卫：本机为 ARM64 时现有 `uname -m` 检查（638-664 行）已自然放行（host is aarch64 → 不进 buildx 模拟分支），无需改；但在 dry-run 文案补一句本地模式提示（可选，最小改动可不动）。

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash scripts/tests/test_deploy_all_local.sh && bash scripts/tests/test_deploy.sh`
Expected: 两者全 ok（新文件 5 条 + 既有 deploy 垫片测试未回归）。

- [ ] **Step 5: 提交**

```bash
git add scripts/deploy-all.sh scripts/tests/test_deploy_all_local.sh
git commit -m "feat(deploy): --local mode bootstraps the full stack on this single EC2"
```

---

### Task 9: 文档（runbook 自举 + 本地仓两节；invariants 快照语义）

**Files:**
- Modify: `docs/runbook.md`（新增「单台 EC2 自举部署」与「本地仓上传（push-local-repo.sh）」两节）
- Modify: `docs/agent/invariants.md`（补「本地仓快照语义」条目）
- Modify: `scripts/README.md`（`push-local-repo.sh` 一行表项）
- 复核：顶层目录未变（无需动 `docs/structure_*.md`）；未新增 `docs/*_en.md`（无需补对）

**Interfaces:** 无代码接口；文档与 Task 1-8 行为一致。

- [ ] **Step 1: runbook 加两节**

在 `docs/runbook.md` 部署章节后追加（要点，去 AI 味、通俗专业）：
- 「单台 EC2 自举部署」：开一台 ARM64 EC2（Ubuntu 24.04、实例角色含建 ECR/AgentCore/Secrets/SSM/Bedrock + 出网）；`git clone` 仓库；`./scripts/install.sh`（或 `deploy-all.sh --region <r> --local`）；强调 AgentCore 仍托管、不占本机；前置仍需 Bedrock model access + 飞书 secret。
- 「本地仓上传」：projects.json 声明 `{subdir, source:"local"}`；客户机跑 `scripts/push-local-repo.sh --host <ec2> <subdir> <本地路径>`；重跑即刷新；说明 `--delete` 镜像语义与 `.git` 排除。

- [ ] **Step 2: invariants 加快照语义**

在 `docs/agent/invariants.md` 加一条：本地仓（`source:local`）是**手动推送的快照**，非持续最新主干；答案涉及 local 仓时应标注快照时间/来源，低置信度转研发。与「代码为唯一依据」并存：依据仍是真实代码，只是新鲜度由人工推送决定。

- [ ] **Step 3: scripts/README 加表项**

在 `scripts/README.md` 的脚本表加一行 `push-local-repo.sh`（客户机侧、rsync 直推 + 触发重建、本地仓刷新入口）。

- [ ] **Step 4: 结构自检 + 提交**

Run: `./scripts/check-invariants.sh`
Expected: PASS（双语配对/顶层目录无变动）。

```bash
git add docs/runbook.md docs/agent/invariants.md scripts/README.md
git commit -m "docs: single-host bootstrap + local-repo ingestion (runbook, invariants, scripts README)"
```

---

### Task 10: 全量离线套件验证

**Files:** 无修改——收尾验证。

- [ ] **Step 1: 跑离线套件**

Run: `./scripts/test.sh`
Expected: 退出码 0（lint + 所有 shell/python 单测 + typecheck 通过；新增 `test_manifest.sh`(扩充)/`test_activate_branch.sh`/`test_local_repo_config.sh`/`test_push_local_repo.sh`/`test_bootstrap_idempotent.sh`/`test_provision_local_mode.sh`/`test_deploy_all_local.sh` 均被发现并通过）。

- [ ] **Step 2: 结构自检**

Run: `./scripts/check-invariants.sh`
Expected: PASS。

- [ ] **Step 3: 若全绿，提交收尾（如有未提交的测试发现配置）**

```bash
git status --short   # 期望干净
```

---

## Self-Review

**Spec coverage（spec §6 改动清单逐条）：**
1. deploy-all `--local` 模式（network 复用 / index-svc 本机 / image 本机）→ Task 7, 8 ✓
2. bootstrap.sh 可在已运行主机幂等重跑 → Task 6 ✓
3. activate_project + git_fetch 分流（local 跳过）→ Task 2 ✓
4. install.sh 支持本地仓 + 删项目/reconcile 兼容 → Task 3, 4 ✓
5. push-local-repo.sh → Task 5 ✓
6. render_manifest / projects.json schema 接纳 source → Task 1 ✓
7. 文档（runbook / invariants / structure）→ Task 9 ✓
- 验收（spec §8）：全新 EC2 单脚本部署 → Task 8 串联；混用 git+local → Task 1-5；离线套件 + check-invariants → Task 10 ✓

**Placeholder scan:** 无 TBD/TODO；每个代码步骤含完整代码块与确切命令、预期输出。

**Type consistency:** `source` 字段在 Task 1 定义（`parse_manifest` 产出 `"source"`、`build_multi_manifest` 透传、`REPO_FIELDS` 含 `source`、`--repo-field source` 可查），Task 2/3 消费同名 `--repo-field source` 与 `r.get("source","git")`。`repo_uses_git()` 在 Task 2 定义、Task 2 自身消费。`imds_field()` 在 Task 7 定义并测试。`LOCAL_MODE`/`ST_LOCAL_MODE` 在 Task 7（provision，读 `ST_LOCAL_MODE`）与 Task 8（deploy，传 `ST_LOCAL_MODE="$LOCAL_MODE"`）间契约一致。

**Scope:** 两部分各自可独立交付测试；Part 1 纯逻辑优先、Part 2 部署改造在后，符合「先可测、后集成」。
