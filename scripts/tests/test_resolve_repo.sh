#!/usr/bin/env bash
# test_resolve_repo.sh — scripts/lib/resolve_repo.sh 单元测试（纯 bash + git）。
# 约定：scripts/tests/test_*.sh 可独立 `bash` 运行；退出码 0 = 全绿。
# 由 scripts/test.sh 的 unit 层自动发现并运行。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/resolve_repo.sh
source "$ROOT/scripts/lib/resolve_repo.sh"

_run=0
_fail=0

assert_rc() { # <expected_rc> <name> <cmd...>
  local want="$1" name="$2"; shift 2
  _run=$((_run + 1))
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" -eq "$want" ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s (want rc=%s, got rc=%s)\n' "$name" "$want" "$got"
    _fail=$((_fail + 1))
  fi
}

assert_eq() { # <expected> <name> <actual>
  local want="$1" name="$2" got="$3"
  _run=$((_run + 1))
  if [[ "$got" == "$want" ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s (want %q, got %q)\n' "$name" "$want" "$got"
    _fail=$((_fail + 1))
  fi
}

echo "test_resolve_repo:"

# --- classify_repo_source: network-free kind detection ---
assert_eq local "classify 本地存在目录" "$(classify_repo_source "$ROOT")"
assert_eq unknown "classify 不存在的裸名" "$(classify_repo_source "no-such-thing-xyz")"
assert_eq s3 "classify s3 tarball" "$(classify_repo_source "s3://bucket/code.tar.gz")"
assert_eq s3 "classify s3 prefix" "$(classify_repo_source "s3://bucket/prefix/")"
assert_eq git "classify github https" "$(classify_repo_source "https://github.com/org/repo")"
assert_eq git "classify .git 后缀" "$(classify_repo_source "https://gitlab.com/org/repo.git")"
assert_eq git "classify git@ ssh" "$(classify_repo_source "git@github.com:org/repo.git")"
assert_eq git "classify ssh:// " "$(classify_repo_source "ssh://git@host/repo.git")"

# 本地存在的 xxx.git 目录优先判为 local（裸仓库镜像），不是 git URL（cross-review M4）
_bare="$(mktemp -d)/mirror.git"; mkdir -p "$_bare"
assert_eq local "classify 本地 xxx.git 目录优先 local" "$(classify_repo_source "$_bare")"
rm -rf "$(dirname "$_bare")"

# --- fetch_repo_source: 拒绝危险 git 源 / 非法 ref（cross-review M2） ---
assert_rc 1 "拒绝 ext:: 传输" fetch_repo_source "ext::sh -c id" git us-east-1 /tmp/_rr_x
assert_rc 1 "拒绝 - 开头的源" fetch_repo_source "--upload-pack=evil" git us-east-1 /tmp/_rr_x
assert_rc 1 "拒绝非法 ref" fetch_repo_source "https://github.com/o/r.git" git us-east-1 /tmp/_rr_x "--evil"

# --- repo_subdir_from_source: network-free name derivation ---
assert_eq repo    "subdir github 无 .git" "$(repo_subdir_from_source "https://github.com/org/repo" git)"
assert_eq my-game "subdir gitlab 多层 .git" "$(repo_subdir_from_source "https://gitlab.com/org/sub/my-game.git" git)"
assert_eq code-5x "subdir git@ ssh" "$(repo_subdir_from_source "git@github.com:org/code-5x.git" git)"
assert_eq teamcode "subdir s3 tarball 去扩展名" "$(repo_subdir_from_source "s3://bucket/teamcode.tar.gz" s3)"
assert_eq prefix  "subdir s3 prefix" "$(repo_subdir_from_source "s3://bucket/prefix/" s3)"

# --- fetch_repo_source git: real clone via file:// (no network) ---
# Build a tiny source repo, clone it through the resolver, and assert the TARGET
# dir IS the repo root (the contract bootstrap.sh relies on) and .git was dropped.
if command -v git >/dev/null 2>&1; then
  _src="$(mktemp -d)"
  ( cd "$_src" && git init -q && mkdir Assets && echo 'class X{}' > Assets/X.cs \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
  _root="$(mktemp -d)"
  fetch_repo_source "file://$_src/.git" git us-east-1 "$_root/code-5x" >/dev/null 2>&1
  assert_eq "Assets" "git fetch: target 即仓库根（含 Assets）" "$(ls -A "$_root/code-5x" 2>/dev/null)"
  _run=$((_run + 1))
  if [[ ! -d "$_root/code-5x/.git" ]]; then
    printf '  ok   %s\n' "git fetch: .git 已剥离"
  else
    printf '  FAIL %s (.git 仍存在)\n' "git fetch: .git 已剥离"; _fail=$((_fail + 1))
  fi
  rm -rf "$_src" "$_root"
else
  echo "  skip git fetch（无 git）"
fi

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
