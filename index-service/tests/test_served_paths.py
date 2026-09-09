"""被服务内容的边界，以及引用行号的往返一致性。

两组不变量，都来自第七轮审计里实测出的问题：

1. 路径限制在仓库副本内 ≠ 仓库副本内的一切都可以给。部署把 `$HOME`（含 RocksDB 图存储）
   放在被服务的那棵树里，被索引的仓库自身还可能带 `.env`、`.git/config`、私钥。审计实测
   读出了数据库口令、API key、`.git/config` 里的 token 和图存储字节——`read_file` 当时
   没有任何排除，`glob_files` 只跳过三个目录名，而它的 docstring 却声称排除了隐藏文件。

2. `codegraph_search_files` 报的是 1 基行号，`read_file` 的 `offset` 是 0 基。于是 agent
   拿自己刚产出的引用去复核，会读到**下一行**并把它当作被引用的那一行——静默错位。

第 2 组用往返断言而不是断言某个具体数字：搜到的行原样传回去，必须取回同一段文本。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import file_read  # noqa: E402
import file_search  # noqa: E402
import served_paths  # noqa: E402


# --- 1. 默认拒绝过滤器 ---------------------------------------------------------------

WITHHELD = [
    ".env",
    ".env.local",
    "alpha/.env",
    "./.env",
    ".git/config",
    "a/b/.git/config",
    ".home/.codegraph/000123.sst",
    ".home/.bash_history",
    ".codegraph/x.ldb",
    "sub/.ssh/id_rsa",
    "deploy/server.pem",
    "keys/private.p12",
    "conf/.npmrc",
    "node_modules/x/y.js",
    ".venv/lib/a.py",
]

SERVED = [
    ".env.example",
    ".env.sample",
    "Assets/Scripts/Player.cs",
    "Config/items.json",
    "README.md",
    "src/keyboard.cs",
    "data/monster.keys.json",
    "docs/keymap.md",
    "src/Home/Player.cs",
    "Assets/Config/.gitkeep",
]


@pytest.mark.parametrize("rel", WITHHELD)
def test_withheld(rel: str) -> None:
    assert served_paths.is_withheld(rel), f"{rel} 必须不被提供"


@pytest.mark.parametrize("rel", SERVED)
def test_served(rel: str) -> None:
    # 误拒同样是缺陷：这是一个回答源码问题的产品，把正常源文件挡掉就是功能损坏。
    assert not served_paths.is_withheld(rel), f"{rel} 是正常项目内容，必须可读"


def test_leading_dot_is_not_stripped_as_a_character_class() -> None:
    """曾经用 lstrip("./") 规范化路径，那是按字符集剥离：".env" 被剥成 "env"，
    ".git/config" 被剥成 "git/config"，于是所有以点开头的目标——也就是这份名单要拦的
    全部对象——统统漏过，而过滤器看起来在正常工作。这条钉住前缀语义。"""
    assert served_paths.is_withheld(".env")
    assert served_paths.is_withheld(".git/config")
    assert served_paths.is_withheld("./.env")


def test_read_file_refuses_withheld_before_opening(tmp_path: Path) -> None:
    """必须在 open() 之前拒绝——被拒的文件连读进内存都不该发生。"""
    (tmp_path / ".env").write_text("TOKEN_VALUE=x\n", encoding="utf-8")
    with pytest.raises(ValueError) as ei:
        file_read.read_file(".env", local_root=str(tmp_path))
    assert "not served" in str(ei.value)


def test_glob_does_not_list_withheld(tmp_path: Path) -> None:
    (tmp_path / ".env").write_text("A=1\n", encoding="utf-8")
    (tmp_path / "ok.cs").write_text("class A {}\n", encoding="utf-8")
    got = file_read.glob_files("*", local_root=str(tmp_path))["paths"]
    assert not any(p.endswith(".env") for p in got), got
    assert any(p.endswith("ok.cs") for p in got), got


def test_search_does_not_return_withheld_hits(tmp_path: Path) -> None:
    needle = "UNIQUE_NEEDLE_9f3a"
    (tmp_path / ".env").write_text(f"SECRET={needle}\n", encoding="utf-8")
    (tmp_path / "code.cs").write_text(f"// {needle}\n", encoding="utf-8")
    raw = file_search.search_to_json(needle, local_root=str(tmp_path))
    hits = json.loads(raw).get("matches", [])
    paths = [h.get("path", "") for h in hits]
    assert not any(p.endswith(".env") for p in paths), paths
    assert any(p.endswith("code.cs") for p in paths), paths


def test_rg_globs_are_all_negative() -> None:
    """ripgrep 里一旦出现正向 glob，匹配集就收窄成"仅符合该 glob 的文件"。第一版为了豁免
    `.env.example` 加了正向 glob，实测效果是整个搜索只看那一个文件、其余一律不搜，于是
    搜索静默返回零结果——比漏放更糟，因为 agent 会据此断定代码里没有要找的东西。"""
    globs = served_paths.rg_exclude_globs()
    values = [g for g in globs if g != "--glob"]
    assert values, "没有生成任何 glob，说明过滤器没接上"
    positive = [v for v in values if not v.startswith("!")]
    assert not positive, f"出现了正向 glob，会把搜索范围收窄成只看这些文件：{positive}"


def test_env_example_stays_searchable() -> None:
    """`.env` 家族不能在 ripgrep 层面整体排除：那会连合法的示例文件一起挡掉。
    这一族由每条命中的 is_withheld 复核处理。"""
    values = [g for g in served_paths.rg_exclude_globs() if g != "--glob"]
    assert not any(v.lstrip("!").startswith(".env") for v in values), values
    assert served_paths.is_withheld(".env")
    assert not served_paths.is_withheld(".env.example")


# --- 2. 引用往返 ---------------------------------------------------------------------

def test_search_line_round_trips_through_read_file(tmp_path: Path) -> None:
    """搜索报出的行号原样传给 read_file(line=...)，必须取回同一段文本。

    这条断言故意不写死行号：写死会把当前的基准（无论对错）固化下来，而要保证的性质是
    两个工具彼此一致。
    """
    target = "L2-TARGET-MARKER"
    (tmp_path / "lines.py").write_text(
        f"L1-alpha\n{target}\nL3-delta\nL4-epsilon\n", encoding="utf-8")

    hits = json.loads(file_search.search_to_json(target, local_root=str(tmp_path)))["matches"]
    assert hits, "搜索没有命中，测试前提不成立"
    hit = hits[0]

    got = file_read.read_file(hit["path"], local_root=str(tmp_path), line=hit["line"], limit=1)
    assert target in got["content"], (
        f"搜索报第 {hit['line']} 行，按同一行号读回的却是 {got['content']!r}；"
        " 两个工具的行号基准不一致，agent 复核自己的引用会确认到错误的文本"
    )


def test_line_and_offset_differ_by_one(tmp_path: Path) -> None:
    """显式钉住两者的关系，避免有人"统一"成同一个基准而悄悄改变分页契约。"""
    (tmp_path / "f.txt").write_text("a\nb\nc\n", encoding="utf-8")
    by_line = file_read.read_file("f.txt", local_root=str(tmp_path), line=2, limit=1)
    by_offset = file_read.read_file("f.txt", local_root=str(tmp_path), offset=1, limit=1)
    assert by_line["content"] == by_offset["content"] == "b"


def test_start_line_1based_is_emitted(tmp_path: Path) -> None:
    (tmp_path / "f.txt").write_text("a\nb\nc\n", encoding="utf-8")
    got = file_read.read_file("f.txt", local_root=str(tmp_path), line=2, limit=1)
    assert got["start_line"] == 1
    assert got["start_line_1based"] == 2
