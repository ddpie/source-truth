"""引用校验器的测试。

这些测试的重心不在「正确的出处能通过」，而在**校验器本身不会在查不到东西时报成功**。这个模块是要
当测量仪器用的：一个在无输入时返回 OK 的检查，产出的绿灯和一个坏掉的检查产出的绿灯无法区分，而本
仓库这一轮已经被这种「空洞通过」烧过多次（校验脚本因取不到代码块而三条断言全部真空通过、守卫因
匹配到注释而对不可达代码报绿）。所以下面每一组都成对出现：一条证明它能发现问题，一条证明它在
无法判断时**明说无法判断**而不是放过。
"""

from __future__ import annotations

import pytest

from citation_verify import (
    FAILING,
    Citation,
    Verdict,
    extract_citations,
    nearby_symbols,
    verify,
)


def reader_from(files: dict[str, str]):
    def _read(path: str, line: int | None = None) -> dict[str, str]:
        if path not in files:
            raise FileNotFoundError(f"no such file: {path}")
        return {"content": files[path]}
    return _read


# --------------------------------------------------------------------------- 提取
def test_extract_path_and_line() -> None:
    cits = extract_citations("详见 Assets/Scripts/Game/Formulas.cs:120 的实现")
    assert len(cits) == 1
    assert cits[0].path == "Assets/Scripts/Game/Formulas.cs"
    assert cits[0].line == 120


def test_extract_dedups_but_keeps_first_position() -> None:
    text = "先看 a/b.cs:10，后面又提 a/b.cs:10 一次"
    cits = extract_citations(text)
    assert len(cits) == 1
    assert cits[0].start == text.index("a/b.cs:10")


def test_extract_ignores_prose_files() -> None:
    """README.md 出现在回答里是在讲文档，不是给源码出处。把它当出处校验只会制造假失败。"""
    assert extract_citations("参见 README.md 与 docs/runbook_zh.md") == []


def test_extract_treats_line_zero_as_absent() -> None:
    """行号是 1-based；0 不是有效值，必须降级为「没带行号」而不是拿 0 去读。"""
    cits = extract_citations("见 a/b.cs:0")
    assert len(cits) == 1 and cits[0].line is None


def test_extract_range_keeps_start_line() -> None:
    cits = extract_citations("见 a/b.cs:40-52")
    assert cits[0].line == 40 and cits[0].end_line == 52


def test_dotted_symbol_is_not_a_file() -> None:
    """回归：`FormulaHelper.CalculateMaxEncumbrance` 曾被当成文件 `FormulaHelper.C`（扩展名列表里
    有 `c`，而正则末尾没有边界约束）。C#/Java 回答里「命名空间.类名」极常见，这个假阳性会把每一个
    这样的符号变成一条响亮的「文件不存在」——比漏报严重得多。"""
    assert extract_citations("`FormulaHelper.CalculateMaxEncumbrance` 计算负重") == []
    assert extract_citations("Config.Json 是个类名，不是文件") == []
    assert extract_citations("Foo.Cpp11Helper 也不是") == []


def test_real_lowercase_paths_still_match() -> None:
    """上一条的边界不能收得太紧，把真出处也挡掉。"""
    for s, want in (
        ("a/b.cs:12", "a/b.cs"),
        ("Assets/Scripts/Game/Formulas.cs:7", "Assets/Scripts/Game/Formulas.cs"),
        ("index-service/http_bridge.py:244", "index-service/http_bridge.py"),
        ("(见 scripts/deploy-all.sh:960)", "scripts/deploy-all.sh"),
    ):
        cits = extract_citations(s)
        assert cits and cits[0].path == want, f"{s} 应提取出 {want}，实际 {cits}"


# --------------------------------------------------------------------------- 文件与行号
def test_file_not_found() -> None:
    r = verify("见 a/missing.cs:3", reader_from({}))
    assert r.results[0].verdict is Verdict.FILE_NOT_FOUND
    assert not r.ok


def test_line_out_of_range() -> None:
    r = verify("`Foo` 在 a/b.cs:99", reader_from({"a/b.cs": "one\ntwo\n"}))
    assert r.results[0].verdict is Verdict.LINE_OUT_OF_RANGE
    assert "只有 2 行" in r.results[0].detail
    assert not r.ok


def test_path_refused_is_not_read() -> None:
    """被路径过滤拒绝的出处不能进入读取——否则这个校验器自己成了绕过 served_paths 的任意读原语。

    出处直接构造：`.env` 不含代码扩展名，正常提取不到它，而这里要测的正是过滤器本身。
    """
    opened: list[str] = []

    def _read(path: str, line: int | None = None) -> dict[str, str]:
        opened.append(path)
        return {"content": "SECRET=1\n"}

    r = verify("见 .env:1", _read,
               path_filter=lambda p: "withheld" if p == ".env" else None,
               citations=[Citation(raw=".env:1", path=".env", line=1, start=0)])
    assert r.results[0].verdict is Verdict.PATH_REFUSED
    assert opened == [], "被拒的路径不应被打开"
    assert not r.ok


# --------------------------------------------------------------------------- 符号判据
SRC = """\
using System;

namespace Game
{
    public static class FormulaHelper
    {
        public static int CalculateMaxEncumbrance(int strength)
        {
            return strength * 4;
        }
    }
}
"""


def test_symbol_confirmed() -> None:
    text = "负重上限在 `FormulaHelper.CalculateMaxEncumbrance` 里计算，见 Game/Formulas.cs:7"
    r = verify(text, reader_from({"Game/Formulas.cs": SRC}))
    assert r.results[0].verdict is Verdict.SYMBOL_CONFIRMED
    assert r.results[0].matched_symbol == "CalculateMaxEncumbrance", (
        "必须用成员名确认，而不是用外层类名 FormulaHelper —— 后者在类声明行就能命中，"
        "于是方法引错到哪一行都看不出来"
    )
    assert r.results[0].matched_line == 7
    assert r.ok


def test_container_only_hit_is_partial_not_confirmed() -> None:
    """答案说 `A.B`，出处却指向类声明行：这是「引得不够准」，独立成一档。

    本仓库已确认的引擎契约缺陷里有一条正是 `call_site` 返回调用者的**声明行**而非调用发生的行；
    只有把这一档和完全确认区分开，那类缺陷才量得出来。
    """
    text = "负重上限在 `FormulaHelper.CalculateMaxEncumbrance` 里，见 Game/Formulas.cs:5"
    r = verify(text, reader_from({"Game/Formulas.cs": SRC}), window=1)
    assert r.results[0].verdict is Verdict.SYMBOL_PARTIAL
    assert r.results[0].matched_symbol == "FormulaHelper"
    assert r.ok, "引得不够准不算失败——算失败会在正常答案上大量误报"
    assert r.summary()["partial"] == 1
    assert r.summary()["confirmed"] == 0


def test_symbol_mismatch_catches_wrong_citation() -> None:
    """这是本模块存在的主要理由：文件存在、行号也存在，但那一行跟结论无关。

    对应引擎契约上已确认的缺陷——搜索直接取 results[0]，而 0.20.1 的语义回退会把非精确匹配排在
    前面，于是答案引用的是另一个近似符号所在的行。个数检查对此完全无感。
    """
    text = "负重上限在 `CalculateMaxEncumbrance` 里计算，见 Game/Formulas.cs:1"
    r = verify(text, reader_from({"Game/Formulas.cs": SRC}))
    assert r.results[0].verdict is Verdict.SYMBOL_MISMATCH
    assert not r.ok


def test_off_by_one_within_window_is_confirmed() -> None:
    """差一行仍算确认：一条指向声明行的出处，符号可能落在紧邻行上。窗口存在就是为了容这一格。"""
    text = "见 `CalculateMaxEncumbrance`，位置 Game/Formulas.cs:8"
    r = verify(text, reader_from({"Game/Formulas.cs": SRC}))
    assert r.results[0].verdict is Verdict.SYMBOL_CONFIRMED


def test_far_off_citation_is_not_forgiven_by_window() -> None:
    """窗口必须小到抓得住「引错到十几行外」。"""
    src = "\n".join(["// filler"] * 40 + ["int CalculateMaxEncumbrance;"])
    text = "见 `CalculateMaxEncumbrance` in a/b.cs:5"
    r = verify(text, reader_from({"a/b.cs": src}))
    assert r.results[0].verdict is Verdict.SYMBOL_MISMATCH


# --------------------------------------------------------------------------- 不得空洞通过
def test_no_line_is_uncheckable_not_ok() -> None:
    r = verify("见 Game/Formulas.cs 的实现", reader_from({"Game/Formulas.cs": SRC}))
    assert r.results[0].verdict is Verdict.UNCHECKABLE
    assert r.summary()["uncheckable"] == 1
    assert r.summary()["confirmed"] == 0, "没带行号不能算成已确认"


def test_no_symbols_is_never_counted_as_confirmed() -> None:
    """答案里没有可核对的符号时，第三级判据没有输入。

    这一条原本断言 UNCHECKABLE；`LINE_EXISTS` 出现后判决变了，但它真正要守住的性质没变，也是加
    LINE_EXISTS 时最容易破掉的那条：**绝不能算成 confirmed**。行真实存在只证明了行存在，
    没证明那一行与结论相关。
    """
    r = verify("答案见 Game/Formulas.cs:7", reader_from({"Game/Formulas.cs": SRC}))
    assert r.results[0].verdict is not Verdict.SYMBOL_CONFIRMED
    assert r.summary()["confirmed"] == 0
    assert r.results[0].verdict is Verdict.LINE_EXISTS


def test_all_uncheckable_report_is_distinguishable_from_confirmed() -> None:
    """一份全是 UNCHECKABLE 的报告 ok 为真（没查出问题），但摘要必须让它和「全部确认」区分开——
    否则「答案的出处一条都没核对上」会看起来像成功。"""
    blind = verify("见 Game/Formulas.cs:7", reader_from({"Game/Formulas.cs": SRC}))
    good = verify("`CalculateMaxEncumbrance` 见 Game/Formulas.cs:7",
                  reader_from({"Game/Formulas.cs": SRC}))
    assert blind.ok and good.ok
    assert blind.summary()["confirmed"] == 0
    assert good.summary()["confirmed"] == 1
    assert blind.summary() != good.summary()


def test_empty_answer_yields_empty_report_not_success_claim() -> None:
    r = verify("", reader_from({}))
    assert r.total == 0
    assert r.summary()["confirmed"] == 0


# --------------------------------------------------------------------------- 稳健性
def test_total_lines_beats_window_for_range_check() -> None:
    """读取方只返回一个窗口时，范围判断必须用它报告的**真实**行数。

    真机上被抓到的缺陷的第二半：拿到手的行数当作文件长度，会把一条指向窗口之外的**正确**出处
    误判成越界——响亮的假失败。
    """
    def _read(path: str, line: int | None = None) -> dict[str, object]:
        return {"lines": ["a", "b", "c"], "total_lines": 5000, "truncated": True}

    r = verify("`Foo` 见 a/b.cs:4000", _read)
    assert r.results[0].verdict is Verdict.UNCHECKABLE, r.results[0].detail
    assert "超出本次读取窗口" in r.results[0].detail
    assert r.failing == [], "行号在文件里存在，只是没读到——不得判失败"


def test_line_beyond_real_total_is_still_out_of_range() -> None:
    """上一条不能把真正的越界也放过。"""
    def _read(path: str, line: int | None = None) -> dict[str, object]:
        return {"lines": ["a", "b", "c"], "total_lines": 5000, "truncated": True}

    r = verify("`Foo` 见 a/b.cs:99999", _read)
    assert r.results[0].verdict is Verdict.LINE_OUT_OF_RANGE
    assert "共 5000" in r.results[0].detail or "只有 5000" in r.results[0].detail


def test_every_line_in_a_comma_list_is_verified() -> None:
    """逗号列表里的每个行号都要成为一条待校验的出处，不能只看第一个。

    黄金测试集抓到的：`gs_replay_0002`（毒素在哪几行扣血）答案写成
    `PoisonEffect.cs:231,235,240,254`，修完正则能解析形态之后它**仍然**报 Unverified——因为
    解析出的 `more` 组被捕获后从未使用，只有 231 进了校验。
    """
    cits = extract_citations("`a/b/PoisonEffect.cs:231,235,240,254`")
    assert [c.line for c in cits] == [231, 235, 240, 254]
    assert all(c.path == "a/b/PoisonEffect.cs" for c in cits)


def test_comma_list_lines_are_each_checked_against_the_file() -> None:
    """每个行号独立判定：有的成立、有的不成立时，两种结论都要出现。"""
    src = "\n".join([f"line{i}" for i in range(1, 11)] + ["MaxEncumbrance here"])
    r = verify("`MaxEncumbrance` 见 a/b.cs:11,3", reader_from({"a/b.cs": src}), window=0)
    verdicts = {res.citation.line: res.verdict for res in r.results}
    assert verdicts[11] is Verdict.SYMBOL_CONFIRMED
    assert verdicts[3] is Verdict.SYMBOL_MISMATCH, "第 3 行没有该符号，必须单独判为不成立"


def test_comma_separated_line_list_is_a_citation() -> None:
    """线上答案的真实写法：一个文件多个行号，逗号分隔。取第一个行号。

    这是真机上假失败的根源。正则原本不认这种写法，于是整个反引号 token 不算出处 → 路径被按 `.` 和
    空白拆开 → `Assets`、`Scripts`、`Game`、`MagicAndEffects` 这些**目录名**成了待核对符号 →
    必然找不到 → 假 symbol_mismatch。
    """
    cits = extract_citations("`a/b/PoisonEffect.cs:231,235,240,254`")
    # 这条原本断言「算 1 条出处、取第一个行号」——那是修复的中间态：正则能解析这个形态了，
    # 但只有 231 进校验，于是 gs_replay_0002 仍报 Unverified。现在每个行号各成一条出处，
    # 由 test_every_line_in_a_comma_list_is_verified 覆盖。这里保留的是它最初要守的性质：
    # 这个形态必须被识别为出处，而不是被拆成目录名当符号。
    assert len(cits) == 4
    assert cits[0].path == "a/b/PoisonEffect.cs"
    assert cits[0].line == 231


def test_directory_names_never_become_symbols() -> None:
    """判据按**形状**认路径，不依赖 _CITATION_RE 是否恰好匹配——那种耦合正是上面缺陷的成因：
    只要行号写法超出正则覆盖，目录名就会变成符号。"""
    for text in (
        "`Assets/Scripts/Game/Effects/Poisons/PoisonEffect.cs:231,235,240`",
        "`Assets/Scripts/Game/Effects/HealthLeech.cs:89,91,131`",
        "见 `Assets/Scripts/Game/WeaponManager.cs` 第 420 行",
    ):
        cits = extract_citations(text)
        assert cits, text
        primary, context = nearby_symbols(text, cits[0].start)
        bad = {"Assets", "Scripts", "Game", "Effects", "Poisons"} & set(primary + context)
        assert not bad, f"{text} → 目录名被当成符号: {bad}"


def test_glob_pattern_is_not_a_symbol() -> None:
    """答案里会写「搜过 `*Network*.cs` 没有结果」——那是搜索模式，不是待核对的符号。"""
    text = "搜过 `*Network*.cs` 没有结果，见 a/b.cs:5"
    cits = extract_citations(text)
    primary, context = nearby_symbols(text, cits[0].start)
    assert "Network" not in primary + context


def test_line_exists_when_no_symbol_available() -> None:
    """真实答案里大量出处形如「`path/File.cs:231`：中毒四档扣血」——中文说明不含标识符。

    这类出处天然无法用符号判据核对（实测占 30%），但行号成立时仍能确定性地判「该行真实存在且非空」。
    全判 UNCHECKABLE 会让分子分母都很小，于是「几乎什么都没核对」和「全部核对通过」拿到同样的 Pass。
    """
    r = verify("见 Game/Formulas.cs:7：负重上限计算", reader_from({"Game/Formulas.cs": SRC}))
    assert r.results[0].verdict is Verdict.LINE_EXISTS
    assert r.summary()["line_exists"] == 1
    assert r.summary()["confirmed"] == 0, "行存在不等于符号确认"
    assert r.ok


def test_empty_cited_line_stays_uncheckable() -> None:
    """引用到空行且无符号可核对：这时连「行有内容」都不成立，仍是查不了。"""
    r = verify("见 Game/Formulas.cs:2：说明", reader_from({"Game/Formulas.cs": SRC}))
    assert r.results[0].verdict is Verdict.UNCHECKABLE
    assert r.summary()["line_exists"] == 0


def test_read_error_does_not_abort_report() -> None:
    def _read(path: str, line: int | None = None) -> dict[str, str]:
        if path == "a/boom.cs":
            raise RuntimeError("transport blew up")
        return {"content": SRC}

    text = "`CalculateMaxEncumbrance` 见 a/boom.cs:3 和 Game/Formulas.cs:7"
    r = verify(text, _read)
    assert r.total == 2
    verdicts = {x.verdict for x in r.results}
    assert Verdict.READ_ERROR in verdicts
    assert Verdict.SYMBOL_CONFIRMED in verdicts, "一条读取失败不应影响另一条的判定"


def test_read_error_is_not_a_statement_about_the_answer() -> None:
    """READ_ERROR 不属于 FAILING，这是被真实缺陷推出来的：它原本在 FAILING 里，于是 bridge 不可达时
    每条出处都变成 READ_ERROR、整份报告判成失败——一次基础设施中断被永久记成「答案引用不成立」。
    FAILING 只放对**答案**下判断的判决；读不到是校验器自己的问题，调用方应看 read_errors。"""
    def _read(path: str, line: int | None = None) -> dict[str, str]:
        raise RuntimeError("bridge down")

    r = verify("`CalculateMaxEncumbrance` 见 a/b.cs:3", _read)
    assert r.results[0].verdict is Verdict.READ_ERROR
    assert Verdict.READ_ERROR not in FAILING
    assert r.failing == [], "读取失败不得计入 failing"
    assert len(r.read_errors) == 1, "但必须能被调用方发现，否则会静默当成校验通过"


def test_reader_cached_per_path_and_line() -> None:
    """缓存按 (路径, 行号) 分，不是仅按路径。

    读取方现在只读引用行附近的一段（从第 1 行读固定长度时，行号超出窗口的引用根本读不到，实测占
    全部出处的 22%）。因此同一文件的两个不同行号需要两个窗口；只按路径缓存会让第二条引用拿到第一条
    的窗口，从而在正确的引用上报 symbol_mismatch。
    """
    calls: list[tuple[str, int | None]] = []

    def _read(path: str, line: int | None = None) -> dict[str, str]:
        calls.append((path, line))
        return {"content": SRC}

    verify("`CalculateMaxEncumbrance` 见 Game/Formulas.cs:7 与 Game/Formulas.cs:9", _read)
    assert calls == [("Game/Formulas.cs", 7), ("Game/Formulas.cs", 9)], calls

    # 同一 (路径, 行号) 重复出现时仍然只读一次
    calls.clear()
    verify("`CalculateMaxEncumbrance` 见 Game/Formulas.cs:7，重复一次 Game/Formulas.cs:7", _read)
    assert calls == [("Game/Formulas.cs", 7)], calls


def test_nearby_symbols_splits_member_from_container() -> None:
    primary, context = nearby_symbols(
        "见 `Game/Formulas.cs` 里的 `FormulaHelper.CalculateMaxEncumbrance`", 0)
    assert "CalculateMaxEncumbrance" in primary
    assert "FormulaHelper" in context
    assert "FormulaHelper" not in primary
    # 反引号里的路径不是符号，不能进任何一档
    assert not any("Formulas" in s for s in primary + context)


def test_nearby_symbols_strips_call_parens() -> None:
    primary, _ = nearby_symbols("调用 `CalculateMaxEncumbrance(strength)` 得到结果", 0)
    assert "CalculateMaxEncumbrance" in primary
    assert "strength" in primary  # 参数名也是标识符，命中它同样算内容对得上


def test_symbol_appearing_alone_is_primary_even_if_also_a_container() -> None:
    """`Foo` 单独出现过、又作为 `Foo.Bar` 的外层出现过时，按 primary 处理——否则
    「答案单独提过它」这个更强的信号会被降级成 context。"""
    primary, context = nearby_symbols("`FormulaHelper` 类里有 `FormulaHelper.Calc`", 0)
    assert "FormulaHelper" in primary
    assert "FormulaHelper" not in context


def test_window_does_not_cross_sentence_boundary() -> None:
    """跨句取符号会造成**假确认**：一条出处被另一句话里的符号确认。这比漏报危险得多，
    因为本模块的全部用途就是抓引错的出处。实测触发过：密集技术描述里三个函数名同时成为候选。"""
    text = "`Alpha` 在别处实现。`Beta` 见 a/b.cs:3"
    pos = text.index("a/b.cs:3")
    primary, _ = nearby_symbols(text, pos)
    assert "Beta" in primary
    assert "Alpha" not in primary, "句号之前的符号不应参与本条出处的核对"


def test_english_sentence_boundary_also_clips() -> None:
    text = "`Alpha` lives elsewhere. `Beta` is at a/b.cs:3"
    pos = text.index("a/b.cs:3")
    primary, _ = nearby_symbols(text, pos)
    assert "Beta" in primary and "Alpha" not in primary


def test_candidates_ordered_by_distance() -> None:
    """同一子句里多个符号时，离出处最近的先试——那个才是它要支持的说法。"""
    text = "`Far` 与 `Near` 见 a/b.cs:3"
    pos = text.index("a/b.cs:3")
    primary, _ = nearby_symbols(text, pos)
    assert primary.index("Near") < primary.index("Far")


def test_nearest_symbol_wins_the_confirmation() -> None:
    src = "line1\nFar\nNear\n"
    text = "`Far` 与 `Near` 见 a/b.cs:3"
    r = verify(text, reader_from({"a/b.cs": src}), window=0)
    assert r.results[0].matched_symbol == "Near"


@pytest.mark.parametrize("v", sorted(FAILING, key=lambda x: x.value))
def test_failing_verdicts_make_report_not_ok(v: Verdict) -> None:
    """FAILING 集合里的每一个判决都必须让 ok 为假。加了新判决忘记归类时这条会红。"""
    from citation_verify import Citation, CitationResult, Report

    r = Report(results=[CitationResult(Citation("x", "a.cs", 1, 0), v)])
    assert not r.ok


def test_bare_line_numbers_bind_to_the_nearest_prior_path() -> None:
    """路径写一次、随后用独立 `:231` 列行号——这是真实答案的写法，必须能核对。

    取自 b4 轮 gs_replay_0002 的答案原文。同一条回放用例第二次逼出修改，而第二次更说明问题：
    第一轮答案写的是 `PoisonEffect.cs:231,235,240,254`（逗号列表），下一轮同一个问题改成了
    路径 + 裸行号。四个行号依然精确，但验证器认不出来就报 Unverified——那是用测量误差冒充质量
    问题。答案的引用写法本身跨轮在变，这正是已查实的模型层波动。
    """
    text = ("毒素在 `Assets/Scripts/Game/MagicAndEffects/Effects/Poisons/PoisonEffect.cs` 的 "
            "`IncrementPoisonEffects()` 里按档位扣血：一档 `:231` 调用 `Random.Range(2,12)`，"
            "二档 `:235`，三档 `:240`，四档 `:254`。")
    cites = extract_citations(text)
    lines = sorted(c.line for c in cites if c.line)
    assert lines == [231, 235, 240, 254], f"四个行号都要认出来，实际 {lines}"
    assert all(c.path.endswith("PoisonEffect.cs") for c in cites if c.line), \
        "裸行号必须绑到前文最近的路径"


def test_bare_line_without_any_prior_path_is_ignored() -> None:
    """前文没有路径时，裸行号不能凭空绑一个——猜错路径会产出自信的错误判定。"""
    assert extract_citations("大概在 `:231` 附近") == []


def test_bare_line_binds_to_the_nearest_not_the_first_path() -> None:
    """答案提到多个文件时，裸行号归属最近的那个，而不是第一个。"""
    text = "先看 `a/One.cs`，再看 `b/Two.cs`，其中 `:88` 是关键。"
    cites = [c for c in extract_citations(text) if c.line == 88]
    assert len(cites) == 1
    assert cites[0].path == "b/Two.cs"
