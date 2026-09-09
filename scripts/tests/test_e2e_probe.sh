#!/usr/bin/env bash
# test_e2e_probe.sh — offline tests for the e2e probe's pure helpers
# (scripts/e2e-probe.py). No AWS, no network — only the region-priority and
# payload-shape logic, which are pure and were the source of a real bug.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/scripts/e2e-probe.py"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_e2e_probe:"
command -v python3 >/dev/null 2>&1 || { echo "  skip (no python3)"; exit 0; }

# import the module by file path (it's a script, not a package).
PY=$(cat <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("e2e_probe", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
ARN = "arn:aws:bedrock-agentcore:ap-northeast-1:111122223333:runtime/source_truth_agent-x"

# --- region priority: ARN region must WIN over a mismatched AWS_REGION env ---
# (the real bug: env us-east-1 + Tokyo ARN → ResourceNotFound)
assert m.resolve_region(ARN, None, "us-east-1") == "ap-northeast-1", "env must NOT override ARN region"
assert m.resolve_region(ARN, "eu-west-1", "us-east-1") == "eu-west-1", "--region must win"
assert m.resolve_region("arn:aws:x:::runtime/y", None, "us-east-1") == "us-east-1", "env is fallback when ARN has no region"
assert m.resolve_region("", "ap-south-1", None) == "ap-south-1", "explicit wins with empty arn"
assert m.resolve_region("", None, None) == "", "no source → empty (caller skips)"

# --- payload shape MUST match gateway (bot-gateway/src/sigv4.ts) ---
p = m.build_payload("Q?", "st-e2eabc", ["repoA", "repoB"])
assert p == {"prompt": "Q?", "traceId": "st-e2eabc", "repos": ["repoA", "repoB"]}, p
# repos omitted entirely when empty (single-repo / zero-config wire shape)
p2 = m.build_payload("Q?", "st-x", [])
assert p2 == {"prompt": "Q?", "traceId": "st-x"}, p2
assert "repos" not in p2, "empty repos must be omitted, not []"
# never leaks fields the agent does not read (e.g. projectId)
assert set(p2.keys()) <= {"prompt", "traceId", "repos"}, p2.keys()

# --- _resolve_repos MUST understand the object schema {subdir, git, ref} ---
# (real bug: it only kept plain strings, so the current projects.json shape was
# silently dropped and the probe sent no repos field at all)
import json, tempfile, os
base={"protocol":"source-truth","version":1,"runId":"test"}
stream="data: "+json.dumps({**base,"seq":1,"type":"text_delta","messageId":"m","text":"partial"})+"\n\n"
try:
    m._extract_answer(stream)
    raise AssertionError("truncated stream accepted")
except ValueError:
    pass
stream+="data: "+json.dumps({**base,"seq":2,"type":"run_completed","text":"complete"})
assert m._extract_answer(stream)[0] == "complete"
assert len(m.SMOKE_PROBES) == 1
assert "生命值" not in m.SMOKE_PROBES[0]["q"], "deployment smoke must work for non-game repositories"
for path in ("src/main.py:12", "server/main.go:30", "src/App.tsx:4", "native/Server.cpp:8",
             "Config/Combat.xlsx", "Config/Combat.xlsm", "Config/Template.xltx",
             "Config/Template.xltm", "Config/Combat.tsv", "Config/Combat.db",
             "Config/Combat.sqlite", "Config/Combat.sqlite3"):
    assert m._CITATION_RE.search(path).group() == path, path

class Client:
    def __init__(self, result):
        self.result = result

    def invoke_agent_runtime(self, **kwargs):
        self.payload = json.loads(kwargs["payload"])
        events = self.result if isinstance(self.result, list) else [self.result]
        return {"response": [(json.dumps(event) + "\n").encode() for event in events]}

for error in ({"is_error": True}, {"subtype": "error_max_turns"}):
    client = Client({"result": "主模块位于 src/main.py:12，处理请求分发。", **error})
    result = m.run_probe(client, ARN, ["repo-a"], m.SMOKE_PROBES[0], 20, True)
    assert not result["ok"] and any("error result" in reason for reason in result["reasons"]), result
answer = "主模块位于 server/main.go:30，处理请求分发。"
client = Client([
    {"content": [{"id": "r", "name": "mcp__codegraph__codegraph_read_file", "input": {}}]},
    {"content": [{"tool_use_id": "r", "content": "actual source", "is_error": False}]},
    {"result": answer, "is_error": False},
])
assert m.run_probe(client, ARN, ["repo-a"], m.SMOKE_PROBES[0], 20, True)["ok"]
assert client.payload["repos"] == ["repo-a"]

# A model-written filename does not establish that the code tools worked.
for event in ({"result": answer}, {**base, "seq": 1, "type": "run_completed", "text": answer}):
    result = m.run_probe(Client(event), ARN, [], m.SMOKE_PROBES[0], 20, True)
    assert not result["ok"] and result["successfulReads"] == 0, result

def normalized(*events):
    return [{**base, "seq": i, **event} for i, event in enumerate(events, 1)]

read = {"type": "tool_started", "toolId": "read", "name": "codegraph_read_file"}
read_ok = {"type": "tool_finished", "toolId": "read", "isError": False}
done = {"type": "run_completed", "text": answer}
events = normalized(read, read_ok, done)
result = m.run_probe(Client(events), ARN, [], m.SMOKE_PROBES[0], 20, True)
assert result["ok"] and result["successfulReads"] == 1, result
events = normalized(read, {**read_ok, "isError": True}, done)
result = m.run_probe(Client(events), ARN, [], m.SMOKE_PROBES[0], 20, True)
assert not result["ok"], "a denied read is not evidence"
events = normalized(read, {**read_ok, "isError": True},
                    {**read, "toolId": "retry"}, {**read_ok, "toolId": "retry"}, done)
result = m.run_probe(Client(events), ARN, [], m.SMOKE_PROBES[0], 20, True)
assert result["ok"] and result["successfulReads"] == 1, "a recovered read must remain usable"

# HTTP MCP historically encodes guarded read failures as JSON text while its
# outer ToolResult is_error remains false. A successful terminal answer cannot
# turn those failures into source evidence. A source file containing an error
# key INSIDE the successful read envelope is still valid evidence.
for content in (
    '{"error":"read failed","detail":"internal error (see service logs)"}',
    [{"type": "text", "text": '{"error":"cannot read table"}'}],
):
    events = [
        {"content": [{"id": "r", "name": "mcp__codegraph__codegraph_read_file"}]},
        {"content": [{"tool_use_id": "r", "content": content, "is_error": False}]},
        {"result": answer, "is_error": False},
    ]
    result = m.run_probe(Client(events), ARN, [], m.SMOKE_PROBES[0], 20, True)
    assert not result["ok"] and result["successfulReads"] == 0, result
    events[1]["content"][0]["content"] = json.dumps(
        {"path": "server/main.go", "content": '{"error": "application error text"}'})
    result = m.run_probe(Client(events), ARN, [], m.SMOKE_PROBES[0], 20, True)
    assert result["ok"] and result["successfulReads"] == 1, result

table_answer = "伤害倍率定义在配置表 Config/Combat.xlsx 的 Damage 列。"
events = normalized(
    {**read, "name": "codegraph_read_table"}, read_ok, {**done, "text": table_answer})
assert m.run_probe(Client(events), ARN, [], m.SMOKE_PROBES[0], 20, True)["ok"]

# Use the parser directly so "missing successful read" cannot mask a protocol
# validation regression in the smoke result.
text_a = {"type": "text_delta", "messageId": "a", "text": "narration"}
text_b = {**text_a, "messageId": "b"}
for events in (
    [{"protocol": "other", "result": answer}],
    [{"protocol": None, "result": answer}],
    normalized(text_a, text_b, text_a, done),
    normalized(text_a, read, read_ok, text_a, done),
    normalized(read, read_ok, read, read_ok, done),
    [{**base, "runId": " ", "seq": 1, **done}],
    normalized({**read, "name": " "}, read_ok, done),
    normalized({**text_a, "messageId": ""}, done),
):
    try:
        m._extract_answer("\n".join(json.dumps(event) for event in events))
        raise AssertionError(f"invalid protocol stream accepted: {events}")
    except ValueError:
        pass

invalid_streams = [
    [{"error": "upstream failed"}, *normalized(done)],
    normalized({"type": "unknown"}, done),
    [{**base, "runId": None, "seq": 1, **done}],
    [{**base, "seq": True, **done}],
    [{**base, "seq": 1, "version": True, **done}],
    normalized(done, {"type": "text_delta", "messageId": "m", "text": "late"}),
    normalized({"type": "run_completed", "text": ""}),
    normalized(read, done),
    normalized(read_ok, done),
    normalized(read, {**read_ok, "isError": "false"}, done),
    [{"is_error": True, "result": "failed"}, {"is_error": False, "result": answer}],
]
for events in invalid_streams:
    result = m.run_probe(Client(events), ARN, [], m.SMOKE_PROBES[0], 20, True)
    assert not result["ok"], events
try:
    m._extract_answer("data: " + json.dumps(normalized(done)[0]) + "\ndata: {broken")
    raise AssertionError("malformed data after completion accepted")
except ValueError:
    pass

class BrokenBody:
    closed = False
    def __iter__(self):
        yield b"partial"
        raise OSError("connection lost")
    def close(self):
        self.closed = True
body = BrokenBody()
class BrokenClient:
    def invoke_agent_runtime(self, **kwargs):
        return {"response": body}
assert not m.run_probe(BrokenClient(), ARN, [], m.SMOKE_PROBES[0], 20, True)["ok"]
assert body.closed, "failed streaming responses must close the transport"

with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
    json.dump({"projects": {"demo": {"port": 8080, "repos": [
        {"subdir": "repo-a", "git": "https://x/y.git", "ref": "main"},
        "legacy-string-repo",
    ]}}}, fh)
    tmp = fh.name
try:
    m.PROJECTS_JSON = tmp
    repos = m._resolve_repos(None)
    assert repos == ["repo-a", "legacy-string-repo"], repos
finally:
    os.unlink(tmp)
print("PYOK")
PYEOF
)

out="$(python3 -c "$PY" "$P" 2>&1)"; rc=$?
check "pure helpers import + assertions pass" "$rc"
[[ "$out" == *PYOK* ]]; check "region priority + payload shape contract holds" $?
if [[ "$rc" -ne 0 ]]; then printf '%s\n' "$out" | sed 's/^/    /'; fi

echo "  $_run run, $_fail failed"
[[ "$_fail" -eq 0 ]]
