#!/usr/bin/env python3
"""Guard the observability wiring.

The failure this prevents already happened once, for months: `aws-opentelemetry-distro` sat pinned in
requirements.txt with the note "observability (toolkit default)" while nothing ever activated it. No
spans were produced, the account had no `aws/spans` log group, and each runtime's log group carried
only platform events — and every existing check was green, because the only observable symptom was
the absence of data nobody asserted on.

Two assertions, both behavioural rather than textual where possible:
  * the container's CMD must launch through `opentelemetry-instrument` — that IS the integration;
  * the ADOT pin must be >=0.18.0, below which the span destination setting is ignored.
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

ROOT = pathlib.Path(__file__).resolve().parents[2]
DOCKERFILE = ROOT / "agent-container" / "Dockerfile"
REQS = ROOT / "agent-container" / "requirements.txt"

fail = 0


def check(desc: str, ok: bool, detail: str = "") -> None:
    global fail
    if ok:
        print(f"  ok   {desc}")
    else:
        print(f"  FAIL {desc}" + (f"\n       {detail}" if detail else ""))
        fail += 1


# --- CMD must go through the auto-instrumentation wrapper --------------------------------
text = DOCKERFILE.read_text(encoding="utf-8")
cmd_lines = [ln.strip() for ln in text.splitlines()
             if re.match(r"^\s*CMD\s", ln) and not ln.strip().startswith("#")]
check("Dockerfile 里有且仅有一条 CMD", len(cmd_lines) == 1, f"找到 {len(cmd_lines)} 条: {cmd_lines}")

cmd = cmd_lines[0] if cmd_lines else ""
check(
    "CMD 通过 opentelemetry-instrument 启动（这一条就是 observability 的接入本身）",
    "opentelemetry-instrument" in cmd,
    f"当前: {cmd}\n       装了 aws-opentelemetry-distro 但不经它启动 = 零遥测，且所有检查都会是绿的。",
)
check("CMD 仍然运行 agent.py", "agent.py" in cmd, f"当前: {cmd}")

# --- ADOT pin must be >= 0.18.0 ----------------------------------------------------------
m = re.search(r"^aws-opentelemetry-distro==([0-9][0-9a-zA-Z.]*)", REQS.read_text(encoding="utf-8"), re.M)
if not m:
    check("requirements.txt 里有 aws-opentelemetry-distro 的精确钉版本", False,
          "未找到 aws-opentelemetry-distro==<version>")
else:
    ver = m.group(1)

    def parts(v: str) -> tuple[int, ...]:
        return tuple(int(x) for x in re.findall(r"\d+", v)[:3])

    check(
        f"ADOT 版本 {ver} >= 0.18.0（低于此版本会忽略 span 目标设置，只能投到共享 aws/spans）",
        parts(ver) >= (0, 18, 0),
        f"当前 {ver}",
    )

# --- OpenInference instrumentation: what makes the spans EVALUABLE -----------------------
# ADOT alone produces spans, but AgentCore Evaluations accepts spans only from a fixed list of
# instrumentation scopes and rejects anything else outright:
#   ValidationException: Provided input has no spans with supported scope.
# Measured against the live deploy: the seven scopes ADOT produced for this agent had an EMPTY
# intersection with that list, so Evaluate could not score a single session. The scope on the list
# for this SDK is `openinference.instrumentation.claude_agent_sdk`, which is exactly what this
# package registers. Dropping it does not break the bot or the telemetry — it silently makes
# evaluation impossible again, with no failing test anywhere else.
reqs_text = REQS.read_text(encoding="utf-8")
m_oi = re.search(r"^openinference-instrumentation-claude-agent-sdk==([0-9][0-9a-zA-Z.]*)",
                 reqs_text, re.M)
check(
    "requirements.txt 钉住 openinference-instrumentation-claude-agent-sdk"
    "（Evaluations 只接受受支持 scope 的 span）",
    m_oi is not None,
    "未找到该依赖：移除它不会让任何其他测试失败，但 Evaluate 会退回"
    " 'no spans with supported scope'。",
)

check("OpenAI 使用 OpenInference scope 且禁用重复自动插桩",
      "openinference-instrumentation-openai-agents==" in reqs_text
      and "OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=aws_openai_agents,openai_agents" in text
      and "exclusive_processor=True" in (ROOT / "agent-container/openai_backend.py").read_text())

print(f"\n  ran={6} failed={fail}")
sys.exit(1 if fail else 0)
