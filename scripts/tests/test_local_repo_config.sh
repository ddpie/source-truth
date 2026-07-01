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
