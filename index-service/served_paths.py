"""哪些仓库内的文件不允许交给 agent。

为什么需要这一层：`path_align.to_local_path` 把 agent 给的路径**限制在仓库副本内**，
而且限制得很扎实（词法层与 realpath 层各自独立成立，变异测试证明过）。但"限制在仓库内"
不等于"仓库内的一切都可以给"——而部署恰恰把不该给的东西放进了那棵被服务的树：

  * `http_bridge` 把 `$HOME` 设成 `<workspace>/.home`，于是 RocksDB 图存储
    （`.home/.codegraph/*.sst`）和 shell 历史都落在仓库副本里面；
  * 被索引的仓库自身可能带着 `.env`、`.git/config`（里面是带 token 的 remote URL）、
    私钥。

在补上这层之前，`read_file` 没有任何排除，`glob_files` 只跳过三个目录名（而它的
docstring 却声称"Hidden/.git/node_modules entries are excluded"，是假的），
`file_search` 只排除 `.git/` 和 `node_modules/` 且刻意开着 `--hidden --no-ignore`。
实测能读出数据库口令、API key、`.git/config` 里的 GitHub token 和图存储字节。

容器提示词里有一条"绝不输出凭据"的硬规则，但那是模型侧的约束。这个模块是它的程序化
兜底：**服务端根本不把这些内容送出去**，所以提示注入或模型漂移都拿不到。

设计取向是默认拒绝加上少量明确豁免。误拒的代价是一次带明确原因的失败读取，agent 可以
如实告诉用户"这类文件不提供"；漏放的代价是凭据经由一个无认证端口离开主机。
"""
from __future__ import annotations

import os
import posixpath

# 目录名：任意一段命中即整棵子树不提供。
_DENY_SEGMENTS = frozenset({
    ".git",          # remote URL 常含 token；索引也不需要 VCS 元数据
    ".home",         # bridge 把 $HOME 指到这里 —— 图存储、shell 历史都在里面
    ".codegraph",    # 图存储本体（即便 $HOME 之后被移出仓库，这条仍然有效）
    ".ssh",
    ".aws",
    ".gnupg",
    "node_modules",  # 体量巨大且不是项目自己的代码
    ".venv",
    "__pycache__",
})

# 文件名（精确匹配，大小写不敏感）。
_DENY_NAMES = frozenset({
    ".npmrc", ".netrc", ".pgpass", ".htpasswd",
    "credentials", "credentials.json",
    "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    ".dockercfg",
})

# 文件名后缀。
_DENY_SUFFIXES = (
    ".pem", ".key", ".pfx", ".p12", ".jks", ".keystore",
    ".sst", ".ldb",          # RocksDB / LevelDB 数据文件
)

# `.env` 家族默认拒绝，但示例文件是合法且常被问到的项目文档，明确豁免。
_ENV_ALLOW = frozenset({
    ".env.example", ".env.sample", ".env.template", ".env.dist", ".env.defaults",
})

WITHHELD_MESSAGE = (
    "this path is not served: it is credential or index-internal material, not project source"
)


def _name_denied(name: str) -> bool:
    low = name.lower()
    if low in _DENY_NAMES:
        return True
    if low.endswith(_DENY_SUFFIXES):
        return True
    # id_rsa.pub 之类的派生名
    if low.startswith(("id_rsa", "id_ed25519", "id_ecdsa", "id_dsa")):
        return True
    if low == ".env" or low.startswith(".env"):
        return low not in _ENV_ALLOW
    return False


def withheld_reason(rel_path: str) -> str | None:
    """``rel_path`` 是仓库相对路径。不提供时返回原因，允许时返回 ``None``。

    只做纯字符串判断，不碰文件系统——调用方在 ``to_local_path`` 之后、真正 ``open``
    之前调用它，所以被拒的文件连打开都不会发生。
    """
    if not rel_path:
        return None
    norm = rel_path.replace("\\", "/")
    # 去掉开头的 "./"，注意必须按前缀去、不能用 lstrip("./")：那是按**字符集**剥离，会把
    # ".env" 剥成 "env"、".git/config" 剥成 "git/config"，于是所有以点开头的目标——也就是
    # 这份名单要拦的全部对象——统统漏过，而过滤器看起来在正常工作。
    while norm.startswith("./"):
        norm = norm[2:]
    norm = posixpath.normpath(norm)
    if norm in (".", "/", ""):
        return None
    segs = [s for s in norm.split("/") if s and s != "."]
    if not segs:
        return None
    for s in segs[:-1]:
        if s.lower() in _DENY_SEGMENTS:
            return f"{WITHHELD_MESSAGE} (directory '{s}')"
    last = segs[-1]
    if last.lower() in _DENY_SEGMENTS:
        return f"{WITHHELD_MESSAGE} (directory '{last}')"
    if _name_denied(last):
        return f"{WITHHELD_MESSAGE} ('{last}')"
    return None


def is_withheld(rel_path: str) -> bool:
    return withheld_reason(rel_path) is not None


def rg_exclude_globs() -> list[str]:
    """给 ripgrep 的 ``--glob`` 参数，让被拒内容根本不进搜索结果。

    只放**负向** glob。ripgrep 里一旦出现一个正向 glob，匹配集就被收窄成"仅符合该 glob 的
    文件"——第一版为了把 `.env.example` 从 `!.env*` 里豁免回来而加了正向 glob，效果是整个
    搜索只看 `.env.example`，其余文件一个都不搜，于是搜索静默返回零结果，agent 会据此得出
    "代码里没有这个东西"。所以豁免逻辑一律不进这里。

    `.env` 家族也不在这里排除：负向排除会连 `.env.example` 一起挡掉，而它是合法且常被问到的
    项目文档。这一族全部交给调用方对每条命中跑 :func:`is_withheld`——那条检查才是权威的，
    也是非 ripgrep 兜底路径唯一经过的地方。ripgrep 侧的排除只为性能和结果质量服务。
    """
    globs: list[str] = []
    for seg in sorted(_DENY_SEGMENTS):
        globs += ["--glob", f"!{seg}/"]
    for name in sorted(_DENY_NAMES):
        globs += ["--glob", f"!{name}"]
    for suf in sorted(_DENY_SUFFIXES):
        globs += ["--glob", f"!*{suf}"]
    return globs


def env_var_home_outside(workspace: str) -> str:
    """建议的 $HOME 位置：仓库副本之外。

    `.home` 在拒绝名单里已经足够阻止内容被服务，但把 $HOME 放在被扫描的树里本身就是
    个隐患——术语表构建那次就是因此把图存储喂给了模型。真正的结构性修法是让它一开始
    就不在里面。保留这个 helper 以便迁移，并给现有六个项目留一个明确的落点。
    """
    return os.path.join("/data", "graph-home", os.path.basename(workspace.rstrip("/")) or "default")
