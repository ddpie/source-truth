"""引用校验器：检查回答里的每一条 `文件:行` 出处是否真的存在、且是否真的说了它被用来支持的话。

为什么需要它
------------
这个机器人的全部价值在于「答案有源码出处」。但在这次改动之前，**没有任何东西校验过一条出处是否
成立**：`scripts/e2e-probe.py` 只用正则**数**出处的个数，个数够就算通过。于是一条指向不存在的文件、
指向越界行号、或者指向一段与结论无关的代码的出处，和一条正确出处得到完全相同的绿灯。

这不是假想的失败。引擎契约上已确认存在的几个缺陷正好都产出这种答案：搜索结果直接取 `results[0]`
而 0.20.1 的语义回退会把非精确匹配排前面（于是引用的是另一个同名近似符号）；定位失败返回的
`{"callers": [], "message": "Could not find starting node…"}` 没有 `error` 键，被读成「确认无调用者」；
`read_file` 的 offset 曾是 0-based 而搜索报的行号是 1-based，差一行意味着 agent 复核自己的引用时读到
的是**下一行**，确认了错误的文本并报告「已核对」。这几种都不产生任何错误日志，也都通不过
「答案里有几条出处」这种检查。

设计取舍
--------
1. **纯确定性，不用模型判断。** 校验器要当**测量仪器**用——先有它，才能量化修引擎契约到底改善了
   什么。一个自己会产生不确定结果的仪器没法当基线。
2. **三级判据，强度递减，且互不冒充**：文件存在 → 行号存在 → 引用行附近确实出现了答案中声称的符号。
   第三级是唯一能抓住「取错符号」和「差一行」的判据，但它需要答案里有反引号标出的标识符；**没有可
   检查的标识符时必须返回 `UNCHECKABLE`，绝不能返回 OK**。一个在无输入时报成功的检查，和一个坏掉的
   检查产出的绿灯是同一种绿灯。
3. **不自己开文件。** 读取通过注入的 ``reader`` 完成，所以核心逻辑离线可测，且线上路径必须复用
   ``served_paths`` 的默认拒绝过滤——否则这个校验器本身就成了一个绕过过滤的任意读原语。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Iterable

# 代码/资源扩展名。刻意不含 .md/.txt 这类散文文件：回答里提到 README.md 是在讲文档，不是在给出处，
# 把它当出处校验只会制造假失败。e2e-probe 的正则包含它们，因为它只需要「有没有出处的样子」。
_CODE_EXT = (
    "cs|py|ts|tsx|js|jsx|go|rs|java|kt|c|cc|cpp|h|hpp|sh|bash|yaml|yml|json|toml|xml|"
    "asset|prefab|unity|shader|cginc|hlsl|sql|proto"
)

# 出处形态：可选目录段 + 文件名 + 扩展名 + 可选行号。行号支持三种真实写法，都取自线上答案：
#   `a/b.cs:75`            单行号
#   `a/b.cs:40-52`         区间（取起始行）
#   `a/b.cs:231,235,240`   逗号列表（取第一个）—— 这一种是真机上的假失败来源：正则不认它时，整个
#                          反引号 token 就不被视为出处，于是路径被拆成 Assets / Scripts / Game 这些
#                          目录名，当作「答案声称此处存在的符号」去核对，必然找不到 → 假 symbol_mismatch。
#
# 三处边界约束都是必需的，第一条是测试直接抓出来的真缺陷：
#   * 结尾 `(?!\w)` —— 没有它，`FormulaHelper.CalculateMaxEncumbrance` 会被当成文件
#     `FormulaHelper.C`（扩展名列表里有 `c`），于是 C#/Java 回答里每一个「命名空间.类名」都变成一条
#     「文件不存在」的假失败。这比漏报严重得多：漏报只是 UNCHECKABLE，假失败是响亮的错误结论。
#   * 开头 `(?<![\w.])` —— 不从标识符中间或某个点之后起匹配。
#   * **不加 re.IGNORECASE** —— 扩展名只认小写。代价是漏掉字面写作 `Foo.CS` 的文件（降级为
#     UNCHECKABLE，无害）；收益是 `Some.Cs`、`Config.Json` 这类符号名不再被误判成文件。
_CITATION_RE = re.compile(
    rf"(?<![\w.])(?P<path>(?:[\w.\-]+/)*[\w.\-]+\.(?:{_CODE_EXT}))(?!\w)"
    r"(?::(?P<line>\d+)(?:-(?P<end>\d+))?(?P<more>(?:,\d+)*))?"
)

# 反引号里的标识符。用于第三级判据：答案说「在 `FormulaHelper.CalculateMaxEncumbrance` 里」，
# 那么引用行附近就应当出现这个名字。取最后一段（`A.B.C` → `C`）以及整串，两者命中其一即可。
_BACKTICK_RE = re.compile(r"`([^`\n]{1,120})`")
_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
# 句/子句边界。中文标点必须在列：答案主要是中文，只按 ". " 断句等于不断句。
_BOUNDARY_RE = re.compile(r"[。；！？\n]|(?<=[a-z0-9)\]])\.\s")


def _looks_like_path(raw: str) -> str | bool:
    """反引号内容是否是路径（而非符号）。**按形状判断，不依赖 _CITATION_RE 是否恰好匹配。**

    这一条是真机假失败的直接修复。原来的判据是 `_CITATION_RE.fullmatch(raw)`，也就是「只有能被完整
    解析成出处的字符串才算路径」。但线上答案写出了 `PoisonEffect.cs:231,235,240,254` 这种逗号行号列表，
    正则当时不认它，于是它不算路径 → 整个路径被按 `.` 和空白拆开 → `Assets`、`Scripts`、`Game`、
    `MagicAndEffects` 这些**目录名**成了「答案声称此处存在的符号」，核对必然失败，产出假
    symbol_mismatch。也就是说：判据的成立与否，取决于另一个正则的覆盖面是否完整——这种耦合本身就是缺陷。

    所以改成形状判断：带路径分隔符，或以代码扩展名结尾，或含 glob 通配（`*Network*.cs` 是模式不是出处），
    都不作为待核对符号。正则再漏掉哪种行号写法，都不会再让目录名变成符号。
    """
    if "/" in raw or "\\" in raw:
        return True
    if "*" in raw or "?" in raw:
        return True
    return bool(re.search(rf"\.(?:{_CODE_EXT})\b", raw))


def _clause_span(text: str, pos: int, before: int, after: int) -> tuple[int, int]:
    """取 ``pos`` 所在子句的范围，再以 before/after 为硬上限收紧。

    为什么要按句界裁剪：不裁剪时窗口会跨到相邻句子，于是一条出处可能被**另一句话里**的符号
    「确认」。假确认比漏报危险得多——漏报只是 UNCHECKABLE，假确认会让一条引错的出处变成绿灯，
    而这个模块的全部用途就是抓引错的出处。实测触发过：一段密集的技术描述里，三个不同函数名
    同时成为同一条出处的候选。
    """
    lo_cap = max(0, pos - before)
    hi_cap = min(len(text), pos + after)
    lo = lo_cap
    for m in _BOUNDARY_RE.finditer(text, lo_cap, pos):
        lo = m.end()
    hi = hi_cap
    m = _BOUNDARY_RE.search(text, pos, hi_cap)
    if m:
        hi = m.start()
    return lo, hi


class Verdict(str, Enum):
    OK = "ok"                              # 文件与行号都成立（符号未检查或已确认）
    SYMBOL_CONFIRMED = "symbol_confirmed"  # 最强：引用行附近有答案声称的**那个成员**
    SYMBOL_PARTIAL = "symbol_partial"      # 只命中外层类型/命名空间，没命中成员本身
    # 行号成立且该行有实际代码，但答案没给可核对的符号。这一档是看真实答案加出来的：项目里大量答案
    # 形如「`path/File.cs:231`：中毒四档扣血」——路径 + 行号 + 中文说明，说明里不含任何标识符。
    # 那不是答案写得不好，是这类出处天然无法用符号判据核对。此时仍能确定性地判一件事：该行真实存在
    # 且不是空行/纯注释边界。比 UNCHECKABLE 强（确实核对了行的存在与内容非空），比 SYMBOL_CONFIRMED
    # 弱（没有验证那一行与结论相关），所以必须是独立一档——并进任何一边都会让评分失真。
    LINE_EXISTS = "line_exists"
    SYMBOL_MISMATCH = "symbol_mismatch"    # 有可检查的符号，但引用行附近找不到 → 大概率引错
    LINE_OUT_OF_RANGE = "line_out_of_range"
    FILE_NOT_FOUND = "file_not_found"
    PATH_REFUSED = "path_refused"          # 被 served_paths 拒绝，或越出仓库根
    READ_ERROR = "read_error"
    UNCHECKABLE = "uncheckable"            # 出处没带行号，或答案里没有可核对的标识符


# 判为「引用不成立」的判决。SYMBOL_MISMATCH 计入其中：它是本校验器存在的主要理由。
#
# SYMBOL_PARTIAL 刻意**不**计入失败。答案说 `A.B`、引用行附近只找到 `A`，最常见的成因是出处指向了
# 类声明行而不是成员所在行——这是「引得不够准」，不是「引错了」，把它算成失败会在正常答案上大量误报。
# 但它必须是独立判决而不是并入 SYMBOL_CONFIRMED：本仓库已确认的引擎契约缺陷里就有一条是
# `call_site` 返回调用者的**声明行**而非调用发生的行，而那类缺陷只有在这两者被区分开时才量得出来。
#
# READ_ERROR **不**计入失败，这一条是被真机跑出来的假失败推出来的：一次 bridge 不可达会让每条出处
# 都变成 READ_ERROR、整份报告判 Fail——把基础设施中断永久记成「答案的引用不成立」。同一个判决也承载
# 「校验器没能把出处映射回仓库文件」：答案里的出处常写成裸文件名（`LevitateMotor.cs:83`）或缺仓库前缀的
# 路径，真机首次运行时这让 4 个 trace 全判 Fail，而那些出处经人工核对**全部真实存在**。
#
# PATH_REFUSED 则**保留**在失败集合里：映射失败已经改走 READ_ERROR，所以它现在只剩一种含义——路径被
# served_paths 按策略拒绝（如 `.env`）。引用一个连 agent 自己都读不到的文件，是在说答案而不是说校验器。
#
# 原则：这个集合只放**对答案下判断**的判决。调用方用 `read_errors` 判断校验是否真正完成。
FAILING = frozenset({
    Verdict.SYMBOL_MISMATCH,
    Verdict.LINE_OUT_OF_RANGE,
    Verdict.FILE_NOT_FOUND,
    Verdict.PATH_REFUSED,
})


@dataclass(frozen=True)
class Citation:
    raw: str
    path: str
    line: int | None
    start: int          # 在答案文本中的起始偏移，用于就近取标识符
    end_line: int | None = None


@dataclass
class CitationResult:
    citation: Citation
    verdict: Verdict
    detail: str = ""
    expected_symbols: tuple[str, ...] = ()
    matched_symbol: str = ""
    matched_line: int | None = None


@dataclass
class Report:
    results: list[CitationResult] = field(default_factory=list)

    @property
    def total(self) -> int:
        return len(self.results)

    @property
    def failing(self) -> list[CitationResult]:
        return [r for r in self.results if r.verdict in FAILING]

    @property
    def confirmed(self) -> list[CitationResult]:
        return [r for r in self.results if r.verdict is Verdict.SYMBOL_CONFIRMED]

    @property
    def read_errors(self) -> list[CitationResult]:
        """读取失败的出处。这是**校验器自己**的故障，不构成对答案的判断——调用方应据此报告
        「校验没能完成」，而不是「引用不成立」。"""
        return [r for r in self.results if r.verdict is Verdict.READ_ERROR]

    @property
    def ok(self) -> bool:
        """没有任何一条判为不成立。注意 UNCHECKABLE 不算失败——它是「查不了」而不是「查出问题」，
        把它算成失败会让「答案里出处不带行号」这种正常写法变成红灯。但它必须被单独报出来，
        否则一份全是 UNCHECKABLE 的报告看起来和一份全部确认的报告一样绿。"""
        return not self.failing

    def summary(self) -> dict[str, Any]:
        counts: dict[str, int] = {}
        for r in self.results:
            counts[r.verdict.value] = counts.get(r.verdict.value, 0) + 1
        return {
            "total": self.total,
            "failing": len(self.failing),
            "confirmed": len(self.confirmed),
            "partial": counts.get(Verdict.SYMBOL_PARTIAL.value, 0),
            # 行存在但无符号可核对。单列出来而不是并进 confirmed：它验证了行的存在，没验证相关性。
            "line_exists": counts.get(Verdict.LINE_EXISTS.value, 0),
            "uncheckable": counts.get(Verdict.UNCHECKABLE.value, 0),
            "by_verdict": counts,
            "ok": self.ok,
        }


def extract_citations(text: str) -> list[Citation]:
    """从答案文本里取出所有出处，按出现顺序、按 (path, line) 去重。

    去重保留**首次**出现的位置，因为第三级判据要靠就近的反引号标识符，而首次出现处通常正是
    「在 `X` 里（见 a/b.cs:120）」这种句式。
    """
    seen: set[tuple[str, int | None]] = set()
    out: list[Citation] = []
    for m in _CITATION_RE.finditer(text or ""):
        path = m.group("path")
        line_s = m.group("line")
        line = int(line_s) if line_s else None
        end_s = m.group("end")
        # 行号 0 或负数不是有效的 1-based 行号；当作没带行号处理，而不是当成有效值去读。
        if line is not None and line < 1:
            line = None
        # 逗号列表里的**每一个**行号都要校验，不能只看第一个。
        #
        # 这是黄金测试集抓到的：`gs_replay_0002`（毒素在哪几行扣血）的答案写成
        # `PoisonEffect.cs:231,235,240,254`，此前只核对 231，其余三个行号完全没查——而这条回放
        # 用例存在的理由正是这种写法。修完正则能解析形态之后，它仍然报 Unverified，因为解析出来的
        # `more` 组被捕获后从未使用。
        lines: list[int | None] = [line]
        more = m.group("more")
        if line is not None and more:
            for extra in more.split(","):
                extra = extra.strip()
                if extra.isdigit() and int(extra) >= 1:
                    lines.append(int(extra))
        for i, ln in enumerate(lines):
            key = (path, ln)
            if key in seen:
                continue
            seen.add(key)
            out.append(Citation(
                raw=m.group(0) if i == 0 else f"{path}:{ln}",
                path=path, line=ln, start=m.start(),
                end_line=int(end_s) if end_s and i == 0 else None))
    out.extend(_bare_line_citations(text or "", out, seen))
    out.sort(key=lambda c: c.start)
    return out


# 裸行号形态：`路径` 写一次，随后用独立的 `:231` `:235` 逐个列行号。
#
# 这是同一条回放用例（gs_replay_0002，「毒素在哪几行扣血」）第二次逼出的修改，而第二次比第一次
# 更说明问题。第一次答案写的是 `PoisonEffect.cs:231,235,240,254`，于是正则学会了逗号列表；
# 下一轮同一个问题的答案改写成：
#
#     `Assets/.../PoisonEffect.cs` 的 `IncrementPoisonEffects()` …… `:231` …… `:235` ……
#
# 于是又报 Unverified——不是因为答案变差了（四个行号依然精确），而是因为**答案的引用写法本身
# 跨轮在变**，这正是已经查实的模型层波动。所以判据不能一次只认一种写法：认不出来的代价是
# 把一个精确的答案判成「无法核对」，也就是用测量误差冒充质量问题。
#
# 只把裸行号绑到**它前面最近出现过的路径**上，且要求该路径在同一段文本里出现过。不做跨段推断：
# 猜错路径会产出一个自信的错误判定，比判不出来更糟——这一课在「路径候选歧义时放弃」那次已经付过。
_BARE_LINE_RE = re.compile(r"`:(?P<line>\d+)(?:-(?P<end>\d+))?`")


def _bare_line_citations(text: str, found: list[Citation],
                         seen: set[tuple[str, int | None]]) -> list[Citation]:
    """把 `:NNN` 这类裸行号归到前文最近的那个路径上。"""
    # 文本里出现过的路径及其位置，用于「最近的前文路径」判断。
    anchors: list[tuple[int, str]] = sorted(
        {(c.start, c.path) for c in found if c.path}, key=lambda t: t[0])
    if not anchors:
        return []
    extra: list[Citation] = []
    for m in _BARE_LINE_RE.finditer(text):
        line = int(m.group("line"))
        if line < 1:
            continue
        prior = [p for pos, p in anchors if pos < m.start()]
        if not prior:
            continue
        path = prior[-1]
        key = (path, line)
        if key in seen:
            continue
        seen.add(key)
        end_s = m.group("end")
        extra.append(Citation(raw=f"{path}:{line}", path=path, line=line, start=m.start(),
                              end_line=int(end_s) if end_s else None))
    return extra


def nearby_symbols(text: str, pos: int, *, before: int = 400,
                   after: int = 120) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """取出处所在**子句**里反引号中的标识符，返回 ``(primary, context)``，按与出处的距离由近到远。

    ``primary`` 是答案实际在讲的东西——`A.B.C` 里的 `C`，或者不带点的整个标识符。
    ``context`` 是它的外层类型/命名空间段（`A`、`B`）。区分二者是为了让「引到了成员」和「只引到了
    外层类的声明行」得到不同判决；混在一起的话，用类名就能确认，方法引错到哪一行都看不出来。

    距离排序同样是精度手段：同一子句里若有多个符号，离出处最近的那个才是它要支持的说法。
    """
    lo, hi = _clause_span(text, pos, before, after)
    # 距离按符号在原文中的位置到 pos 的绝对距离算，所以要保留全局偏移。
    scored: list[tuple[int, str, bool]] = []   # (distance, ident, is_primary)
    for m in _BACKTICK_RE.finditer(text, lo, hi):
        raw = m.group(1).strip()
        if _looks_like_path(raw):
            continue  # 路径不是符号
        dist = abs(m.start() - pos)
        # 去掉调用写法的括号：`CalculateMaxEncumbrance(strength)`
        parts = [p for p in raw.replace("(", " ").replace(")", " ").split() if p]
        for part in parts:
            segs = [s for s in part.split(".") if s]
            if not segs:
                continue
            for ident in _IDENT_RE.findall(segs[-1]):
                scored.append((dist, ident, True))
            for seg in segs[:-1]:
                for ident in _IDENT_RE.findall(seg):
                    scored.append((dist, ident, False))

    scored.sort(key=lambda t: t[0])
    primary: list[str] = []
    context: list[str] = []
    for _, ident, is_primary in scored:
        bucket = primary if is_primary else context
        if ident not in primary and ident not in context:
            bucket.append(ident)
        elif is_primary and ident in context:
            # 同一标识符先作为外层出现、后又单独出现：升级为 primary，因为「答案单独提过它」
            # 是更强的信号，降级会丢掉它。
            context.remove(ident)
            primary.append(ident)
    return tuple(primary), tuple(context)


def verify(
    text: str,
    reader: Callable[[str], dict[str, Any]],
    *,
    window: int = 4,
    path_filter: Callable[[str], str | None] | None = None,
    citations: Iterable[Citation] | None = None,
) -> Report:
    """校验 ``text`` 里的每一条出处。

    ``reader(path)`` 返回 ``{"content": str}``（或 ``{"lines": [...]}``），文件不存在时抛
    ``FileNotFoundError``，路径越界时抛 ``ValueError``。``path_filter`` 是
    ``served_paths.withheld_reason``：先做纯字符串判断，被拒的文件连读都不读。

    ``window`` 是符号检查的行窗口（引用行 ±window）。给 4 而不是 0，因为一条合理的出处常指向声明行、
    而符号可能出现在紧邻的属性/注解/重载行上；同时 4 足够小，不会把「引错到几十行外」放过去。
    """
    report = Report()
    cits = list(citations) if citations is not None else extract_citations(text)
    # 按 (路径, 行号) 缓存：读取方现在只读引用行附近的一段，同一文件的不同引用需要不同的窗口，
    # 只按路径缓存会让第二条引用拿到第一条的窗口。
    cache: dict[tuple[str, int | None], dict[str, Any] | Exception] = {}

    for c in cits:
        if path_filter is not None:
            reason = path_filter(c.path)
            if reason:
                report.results.append(CitationResult(c, Verdict.PATH_REFUSED, reason))
                continue

        ckey = (c.path, c.line)
        if ckey not in cache:
            try:
                # 把引用行传给读取方：它可以只读该行附近的一段，而不是从头读固定长度。
                # 这不是优化——从第 1 行读 400 行时，任何行号大于 400 的引用都读不到，实测占全部
                # 出处的 22%，而它们与答案质量无关，纯粹是校验器读错了范围。
                cache[ckey] = reader(c.path, c.line)
            except FileNotFoundError as e:
                cache[ckey] = e
            except ValueError as e:
                cache[ckey] = e
            except Exception as e:  # noqa: BLE001 — 任何读取异常都记成判决，不让它中断整份报告
                cache[ckey] = e
        got = cache[ckey]

        if isinstance(got, FileNotFoundError):
            report.results.append(CitationResult(c, Verdict.FILE_NOT_FOUND, str(got)))
            continue
        if isinstance(got, ValueError):
            report.results.append(CitationResult(c, Verdict.PATH_REFUSED, str(got)))
            continue
        if isinstance(got, Exception):
            report.results.append(CitationResult(
                c, Verdict.READ_ERROR, f"{type(got).__name__}: {got}"))
            continue

        lines = got.get("lines")
        if not isinstance(lines, list):
            lines = (got.get("content") or "").splitlines()

        # 读取方可以报告文件的**真实**行数，即使它只返回了一个窗口。范围判断必须用它：拿到手的行数
        # 会把一条指向窗口之外的正确出处误判成越界，而那是响亮的假失败。
        total = got.get("total_lines")
        total = total if isinstance(total, int) and total >= len(lines) else len(lines)
        truncated = bool(got.get("truncated"))

        if c.line is None:
            report.results.append(CitationResult(
                c, Verdict.UNCHECKABLE, "出处未带行号，只能确认文件存在"))
            continue
        if c.line > total:
            report.results.append(CitationResult(
                c, Verdict.LINE_OUT_OF_RANGE,
                f"引用第 {c.line} 行，但文件只有 {total} 行"))
            continue
        if c.line > len(lines):
            # 行号在文件里存在，只是不在这次读到的窗口内。这是「查不了」而不是「查出问题」——
            # 判成失败会把正确出处误伤，而这类误伤会让整批评估数据失去意义。
            report.results.append(CitationResult(
                c, Verdict.UNCHECKABLE,
                f"第 {c.line} 行超出本次读取窗口（拿到 {len(lines)} 行 / 共 {total} 行"
                f"{'，已截断' if truncated else ''}），无法核对内容"))
            continue

        primary, context = nearby_symbols(text, c.start)
        if not primary and not context:
            # 没有可核对的符号，但行号成立——仍能确定性地判「该行真实存在且有内容」。
            # 这比直接放弃有用得多：实测这类出处占 30%，全判 UNCHECKABLE 会让大多数答案的分子分母都很小，
            # 于是「几乎什么都没核对」和「全部核对通过」拿到同样的 Pass。
            body = lines[c.line - 1].strip() if c.line - 1 < len(lines) else ""
            if body:
                report.results.append(CitationResult(
                    c, Verdict.LINE_EXISTS,
                    f"第 {c.line} 行存在且非空（答案未给可核对的符号）：{body[:80]!r}"))
            else:
                report.results.append(CitationResult(
                    c, Verdict.UNCHECKABLE,
                    f"第 {c.line} 行是空行，且答案未给可核对的符号"))
            continue

        lo = max(0, c.line - 1 - window)
        hi = min(len(lines), c.line - 1 + window + 1)

        def _find(cands: tuple[str, ...]) -> tuple[str, int | None]:
            for sym in cands:
                for i in range(lo, hi):
                    if sym in lines[i]:
                        return sym, i + 1
            return "", None

        hit, hit_line = _find(primary)
        if hit:
            report.results.append(CitationResult(
                c, Verdict.SYMBOL_CONFIRMED,
                f"在第 {hit_line} 行找到 `{hit}`",
                expected_symbols=primary, matched_symbol=hit, matched_line=hit_line))
            continue

        ctx_hit, ctx_line = _find(context)
        if ctx_hit:
            report.results.append(CitationResult(
                c, Verdict.SYMBOL_PARTIAL,
                f"只在第 {ctx_line} 行找到外层 `{ctx_hit}`，未找到 {list(primary[:4])}"
                f"（该行内容：{lines[c.line - 1].strip()[:80]!r}）",
                expected_symbols=primary, matched_symbol=ctx_hit, matched_line=ctx_line))
            continue

        report.results.append(CitationResult(
            c, Verdict.SYMBOL_MISMATCH,
            f"第 {lo + 1}-{hi} 行内找不到 {list((primary or context)[:4])} 中任何一个"
            f"（该行内容：{lines[c.line - 1].strip()[:80]!r}）",
            expected_symbols=primary or context))
    return report
