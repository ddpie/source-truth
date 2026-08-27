"""到 index-service bridge 的最小 MCP 客户端，只为代码型评估器回查源码用。

为什么走 bridge 而不是别的来源：bridge 提供的是 **agent 当时读的同一份**仓库副本。S3 里的产物可能
比它旧，Lambda 里再放一份仓库既大又必然漂移。用同一个来源，才能保证「校验失败」说明的是答案的问题，
而不是两份代码不一致。

为什么要自己写而不装 `mcp` 包：Lambda 包越小冷启动越快，而这里只需要三个 JSON-RPC 调用
（initialize → notifications/initialized → tools/call）。完整 SDK 会带进一堆本用不到的传输实现。
标准库以外零依赖。

只实现读取。这个客户端刻意**不**暴露 bridge 的写入或执行类工具——评估器需要的全部能力就是把一行源码
读回来核对，多给一分权限就是多一分风险，而它运行在一个能访问私有子网的 Lambda 里。
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any

_PROTOCOL = "2024-11-05"
_CLIENT = {"name": "source-truth-citation-evaluator", "version": "1"}


class BridgeError(RuntimeError):
    """bridge 不可达或返回了无法解析的响应。"""


def _parse_body(raw: bytes, content_type: str) -> dict[str, Any]:
    """MCP streamable-HTTP 既可能回纯 JSON，也可能回 SSE 帧；两种都要能读。

    只按 Content-Type 判断是不够的：实测某些代理会把 SSE 的 content-type 改写掉。所以先看内容是不是
    以 `data:` 开头，再回落到直接 JSON 解析。
    """
    text = raw.decode("utf-8", errors="replace").strip()
    if not text:
        raise BridgeError("bridge 返回空响应")
    if text.startswith("data:") or "\ndata:" in text:
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                payload = line[5:].strip()
                if payload:
                    try:
                        return json.loads(payload)
                    except ValueError:
                        continue
        raise BridgeError(f"SSE 响应里没有可解析的 data 帧: {text[:200]}")
    try:
        return json.loads(text)
    except ValueError as e:
        raise BridgeError(f"响应不是 JSON（content-type={content_type}）: {text[:200]}") from e


class BridgeClient:
    """一次评估期间复用一个 MCP 会话。"""

    def __init__(self, url: str, *, timeout: float = 10.0) -> None:
        self.url = url
        self.timeout = timeout
        self._session_id: str | None = None
        self._next_id = 0
        self._initialized = False

    def _post(self, payload: dict[str, Any], *, expect_body: bool = True) -> dict[str, Any] | None:
        body = json.dumps(payload).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            # 两个都要声明：服务端据此选择回 JSON 还是 SSE，只写一个会在某些版本上得到 406。
            "Accept": "application/json, text/event-stream",
        }
        if self._session_id:
            headers["mcp-session-id"] = self._session_id
        req = urllib.request.Request(self.url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                sid = resp.headers.get("mcp-session-id")
                if sid:
                    self._session_id = sid
                raw = resp.read()
                ctype = resp.headers.get("Content-Type", "")
        except urllib.error.HTTPError as e:
            raise BridgeError(f"HTTP {e.code}: {e.read()[:200]!r}") from e
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            raise BridgeError(f"无法连接 bridge {self.url}: {e}") from e
        if not expect_body:
            return None
        return _parse_body(raw, ctype)

    def _rpc(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self._next_id += 1
        resp = self._post({"jsonrpc": "2.0", "id": self._next_id,
                           "method": method, "params": params})
        assert resp is not None
        if "error" in resp:
            raise BridgeError(f"{method} 失败: {json.dumps(resp['error'], ensure_ascii=False)[:200]}")
        return resp.get("result") or {}

    def initialize(self) -> None:
        if self._initialized:
            return
        self._rpc("initialize", {
            "protocolVersion": _PROTOCOL,
            "capabilities": {},
            "clientInfo": _CLIENT,
        })
        # 通知没有 id、也没有响应体。漏掉它，后续 tools/call 会被拒。
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, expect_body=False)
        self._initialized = True

    def read_file(self, path: str, *, line: int | None = None,
                  limit: int | None = None) -> str:
        """调 bridge 的 codegraph_read_file，返回其文本载荷。"""
        self.initialize()
        args: dict[str, Any] = {"path": path}
        if line is not None:
            args["line"] = line
        if limit is not None:
            args["limit"] = limit
        result = self._rpc("tools/call", {"name": "codegraph_read_file", "arguments": args})
        # isError 为真时把内容当错误抛出，而不是当成「文件内容」拿去比对——否则一段错误信息会被
        # 当作源码，进而得出「引用不成立」这种错误结论。
        if result.get("isError"):
            raise BridgeError(_first_text(result) or "read_file 返回 isError")
        text = _first_text(result)
        if text is None:
            raise BridgeError(f"read_file 响应里没有文本内容: {json.dumps(result)[:200]}")
        return text


def _first_text(result: dict[str, Any]) -> str | None:
    for item in result.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "text":
            return item.get("text")
    return None
