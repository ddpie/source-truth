"""agent 允许清单与 bridge 实际注册的工具集必须逐一对应。

为什么需要这条不变量：agent 侧的只读边界对 MCP 工具的收口方式是「白名单之外一律拒绝」
（permission_mode="dontAsk"），而完备性被显式委托给 server 侧——agent_lib.py 的注释就写着
CODEGRAPH_WRITE_TOOLS 不穷尽 codegraph 的全部工具，靠 bridge 只暴露只读子集来兜底。

问题是这个对应关系由两个文件手工维护，此前只有一句文档提醒（docs/agent/playbooks.md）。
两个方向的漂移后果不同，都不该静默发生：

  * bridge 多暴露一个工具而 agent 没加进白名单 —— dontAsk 是 fail-closed，所以是可用性
    回归（模型看得到工具却调不动），不是提权；但它会以「模型莫名其妙不用新工具」的形式
    出现，很难定位。
  * agent 白名单里留着 bridge 已经删掉的工具 —— 白名单变成一份过期的意图声明，读代码的
    人会以为那个能力还在。

所以这里断言的是集合相等，而不是单向包含。
"""
import re
from pathlib import Path

import agent_lib

_ROOT = Path(__file__).resolve().parents[2]
_BRIDGE = _ROOT / "index-service" / "http_bridge.py"

_PREFIX = f"mcp__{agent_lib.CODEGRAPH_SERVER_KEY}__"


def _agent_allowlisted() -> set[str]:
    """CODEGRAPH_TOOLS 去掉 mcp__<server>__ 前缀后的裸工具名。"""
    names = set()
    for full in agent_lib.CODEGRAPH_TOOLS:
        assert full.startswith(_PREFIX), f"{full} 不是 {_PREFIX} 形式"
        names.add(full[len(_PREFIX):])
    return names


def _bridge_registered() -> set[str]:
    """bridge 真正注册给 MCP 的工具名。

    分两种形态收集：直接写死名字的 add_tool(...) 调用，以及 `for name in EXPOSED_TOOLS`
    这类由常量列表驱动的循环注册。只解析文本、不导入 http_bridge——那会把 index-service
    的整套依赖拖进 agent-container 的测试环境。
    """
    src = _BRIDGE.read_text(encoding="utf-8")
    names: set[str] = set()

    # 形态一：add_tool 的实参里出现的字面量工具名（codegraph_ 前缀是这个项目的命名约定）。
    for m in re.finditer(r"add_tool\s*\(([^)]*)\)", src, re.S):
        names.update(re.findall(r"[\"'](codegraph_[a-z_]+)[\"']", m.group(1)))

    # 形态二：常量列表驱动的循环注册。取出列表字面量里的名字。
    # 允许可选的类型标注（`EXPOSED_TOOLS: tuple[str, ...] = (...)`）以及裸赋值。
    if re.search(r"for\s+\w+\s+in\s+EXPOSED_TOOLS", src):
        m = re.search(r"^EXPOSED_TOOLS(?:\s*:[^=\n]+)?\s*=\s*[(\[](.*?)[)\]]", src, re.S | re.M)
        assert m, "找到了 EXPOSED_TOOLS 循环但没解析出它的列表字面量"
        names.update(re.findall(r"[\"'](codegraph_[a-z_]+)[\"']", m.group(1)))

    return names


def test_bridge_file_is_where_we_think() -> None:
    """路径写错会让下面两条断言变成「空集等于空集」这种假绿。"""
    assert _BRIDGE.is_file(), f"未找到 {_BRIDGE}"
    assert "add_tool" in _BRIDGE.read_text(encoding="utf-8")


def test_allowlist_matches_bridge_exactly() -> None:
    agent = _agent_allowlisted()
    bridge = _bridge_registered()
    assert agent, "解析出的 agent 白名单为空——解析器坏了，不是白名单空了"
    assert bridge, "解析出的 bridge 注册集为空——解析器坏了，不是 bridge 没注册工具"

    only_bridge = bridge - agent
    only_agent = agent - bridge
    assert not only_bridge, (
        f"bridge 暴露了 agent 白名单里没有的工具：{sorted(only_bridge)}。"
        " dontAsk 会拒绝它们，所以模型看得到却调不动——请同步 agent_lib.CODEGRAPH_TOOLS。"
    )
    assert not only_agent, (
        f"agent 白名单里有 bridge 不再注册的工具：{sorted(only_agent)}。"
        " 白名单成了过期的意图声明，请删掉或在 bridge 侧恢复注册。"
    )


def test_write_tools_are_not_allowlisted() -> None:
    """写侧工具既要在黑名单里，也绝不能同时出现在白名单里。"""
    allowed = set(agent_lib.CODEGRAPH_TOOLS)
    for name in agent_lib.CODEGRAPH_WRITE_TOOLS:
        assert name not in allowed, f"{name} 同时出现在允许清单和写侧黑名单里"
