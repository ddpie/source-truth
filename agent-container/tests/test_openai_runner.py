"""Production runner + real HTTP MCP + signed Bedrock binary event streams."""

import asyncio
import base64
import json
import socket
import struct
import sys
import threading
import zlib
from pathlib import Path

import botocore.session
import pytest
import uvicorn
from botocore.awsrequest import AWSResponse
from botocore.config import Config
from mcp.server.fastmcp import FastMCP

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bedrock_converse  # noqa: E402
import engine_runner  # noqa: E402
import openai_backend  # noqa: E402

ANSWER = "BaseDamage = 42 (`Game/Combat.cs:12`)."

@pytest.fixture
def trace_exporter(monkeypatch):
    from agents import set_trace_processors
    from openinference.instrumentation.openai_agents import OpenAIAgentsInstrumentor
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    instrumentor = OpenAIAgentsInstrumentor()
    set_trace_processors([])
    monkeypatch.setattr(openai_backend, "instrument", lambda: instrumentor.instrument(
        tracer_provider=provider, exclusive_processor=True,
    ))
    try:
        yield exporter
    finally:
        instrumentor.uninstrument()
        set_trace_processors([])
        provider.shutdown()


def converse_events(number, *, name=None, mode="success"):
    events = [{"messageStart": {"role": "assistant"}}]
    index = 0
    if mode == "reasoning":
        for content in (
            {"redactedContent": base64.b64encode(b"opaque-reasoning").decode()},
            {"text": "provider-private", "signature": "signed-history"},
        ):
            for key, value in content.items():
                events.append({"contentBlockDelta": {
                    "contentBlockIndex": index, "delta": {"reasoningContent": {key: value}},
                }})
            events.append({"contentBlockStop": {"contentBlockIndex": index}})
            index += 1
    if name:
        events.extend([
            {"contentBlockStart": {"contentBlockIndex": index,
                                  "start": {"toolUse": {"toolUseId": f"call_{number}", "name": name}}}},
            {"contentBlockDelta": {"contentBlockIndex": index, "delta": {"toolUse": {"input": '{"path":'}}}},
            {"contentBlockDelta": {"contentBlockIndex": index,
                                  "delta": {"toolUse": {"input": '"Game/Combat.cs"}'}}}},
        ])
        if mode == "invalid_json":
            events[-1]["contentBlockDelta"]["delta"]["toolUse"]["input"] = "INVALID"
    else:
        # Text and reasoning streams legitimately omit contentBlockStart.
        events.append({"contentBlockDelta": {"contentBlockIndex": index, "delta": {"text": ANSWER}}})
    if mode == "truncated":
        return events
    if mode == "service_error":
        return events + [{"internalServerException": {"message": "offline stream failure"}}]
    events.extend([
        {"contentBlockStop": {"contentBlockIndex": index}},
        {"messageStop": {"stopReason": "max_tokens" if mode == "max_tokens" else
                         "tool_use" if name else "end_turn"}},
    ])
    if mode != "missing_metadata":
        events.append({"metadata": {"usage": {"inputTokens": 10, "outputTokens": 5,
                                               "totalTokens": 15, "cacheReadInputTokens": 3},
                                    "metrics": {"latencyMs": 1}}})
    return events


class WireStream:
    """Exercise botocore's real event-stream decoder and CRC validation."""
    def __init__(self, events):
        self.events = events
        self.closed = False

    def stream(self, **_):
        for event in self.events:
            name, value = next(iter(event.items()))
            headers = b""
            message_type = "exception" if name.endswith("Exception") else "event"
            type_header = ":exception-type" if message_type == "exception" else ":event-type"
            for key, val in {":message-type": message_type, type_header: name,
                             ":content-type": "application/json"}.items():
                key, val = key.encode(), val.encode()
                headers += bytes([len(key)]) + key + b"\x07" + struct.pack(">H", len(val)) + val
            payload = json.dumps(value).encode()
            prelude = struct.pack(">II", 16 + len(headers) + len(payload), len(headers))
            message = prelude + struct.pack(">I", zlib.crc32(prelude)) + headers + payload
            yield message + struct.pack(">I", zlib.crc32(message))

    def close(self):
        self.closed = True


def install_transport(monkeypatch, handler):
    streams = []

    def client(region):
        client = botocore.session.get_session().create_client(
            "bedrock-runtime", region_name=region, aws_access_key_id="AKIDEXAMPLE",
            aws_secret_access_key="offline-only",
            config=Config(retries={"total_max_attempts": 1}),
        )

        def send(request):
            assert request.url == f"https://bedrock-runtime.{region}.amazonaws.com/model/us.openai.gpt-6-astra/converse-stream"
            assert f"/{region}/bedrock/aws4_request" in request.headers["Authorization"].decode()
            body = json.loads(request.body)
            assert "store" not in body and "previous_response_id" not in body
            stream = WireStream(handler(body))
            streams.append(stream)
            return AWSResponse(request.url, 200, {"content-type": "application/vnd.amazon.eventstream"}, stream)

        monkeypatch.setattr(client._endpoint.http_session, "send", send)
        return client

    monkeypatch.setattr(bedrock_converse, "create_client", client)
    return streams


@pytest.mark.parametrize("mode", [
    "success", "reasoning", "forbidden", "turn_limit", "truncated", "max_tokens", "missing_metadata",
    "invalid_json", "service_error",
])
def test_production_openai_loop(monkeypatch, mode, trace_exporter):
    monkeypatch.setenv("AGENT_SDK", "openai")
    monkeypatch.setenv("AGENT_MODEL", "us.openai.gpt-6-astra")
    monkeypatch.setenv("AGENT_MAX_TURNS", "2")
    monkeypatch.setenv("AWS_REGION", "us-east-2")
    calls, requests = [], []

    def handler(body):
        assert [t["toolSpec"]["name"] for t in body["toolConfig"]["tools"]] == ["codegraph_read_file"]
        assert body["additionalModelRequestFields"] == {"parallel_tool_calls": False}
        requests.append(body)
        number = len(requests)
        name = "forbidden_write" if mode == "forbidden" else (
            "codegraph_read_file" if mode in ("turn_limit", "invalid_json") or
            (mode in ("success", "reasoning") and number == 1) else None
        )
        if mode in ("success", "reasoning") and number == 2:
            messages = body["messages"]
            assert [message["role"] for message in messages] == ["user", "assistant", "user"]
            assert messages[-1]["content"][0]["toolResult"]["toolUseId"] == "call_1"
            assert "BaseDamage" in str(messages[-1])
            if mode == "reasoning":
                assert messages[1]["content"][:2] == [
                    {"reasoningContent": {"redactedContent": base64.b64encode(b"opaque-reasoning").decode()}},
                    {"reasoningContent": {"reasoningText": {"text": "provider-private",
                                                          "signature": "signed-history"}}},
                ]
        return converse_events(number, name=name, mode=mode)

    streams = install_transport(monkeypatch, handler)

    async def run():
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        mcp = FastMCP("fixture", host="127.0.0.1", port=port, stateless_http=True, json_response=True)

        @mcp.tool()
        def codegraph_read_file(path: str) -> str:
            """Read fixture evidence."""
            calls.append(path)
            return "12: const int BaseDamage = 42;"

        @mcp.tool()
        def forbidden_write(path: str) -> str:
            """Forbidden fixture tool."""
            pytest.fail("forbidden tool was executed")

        server = uvicorn.Server(uvicorn.Config(mcp.streamable_http_app(), log_level="error", access_log=False))
        task = asyncio.create_task(server.serve(sockets=[sock]))
        try:
            for _ in range(100):
                if server.started:
                    break
                await asyncio.sleep(0.01)
            assert server.started
            monkeypatch.setenv("CODEGRAPH_MCP_URL", f"http://127.0.0.1:{port}/mcp")
            return [event async for event in engine_runner.run_agent({"prompt": "damage?"})]
        finally:
            server.should_exit = True
            await task
            sock.close()

    events = asyncio.run(run())
    success = mode in ("success", "reasoning")
    assert all(stream.closed for stream in streams)
    assert events[-1]["type"] == ("run_completed" if success else "run_failed"), events
    assert sum(e["type"] in ("run_completed", "run_failed") for e in events) == 1
    if success:
        assert events[-1]["text"] == ANSWER
        assert events[-1]["numTurns"] == 2
        assert calls == ["Game/Combat.cs"]
        assert events[-1]["usage"] == {"input_tokens": 26, "output_tokens": 10}
        assert "provider-private" not in str(events) and "opaque-reasoning" not in str(events)
        assert [e["type"] for e in events] == ["tool_started", "tool_finished", "text_delta", "run_completed"]
        spans = trace_exporter.get_finished_spans()
        assert any(span.instrumentation_scope.name == "openinference.instrumentation.openai_agents" for span in spans)
        assert any(ANSWER in str(value) for span in spans for key, value in span.attributes.items()
                   if key.startswith("llm.output_messages.") and ".message.content" in key)
        assert "provider-private" not in str([span.attributes for span in spans])
    if mode == "turn_limit":
        assert events[-1]["error"] == "error_max_turns"
    if mode == "invalid_json":
        assert not calls


@pytest.mark.parametrize("source_text", ["int damage; // 伤害\n", ""])
def test_real_openai_glossary_loop_and_grounding(monkeypatch, tmp_path, source_text):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "index-service"))
    import glossary_build

    source = tmp_path / "Game" / "Combat.cs"
    source.parent.mkdir()
    source.write_text(source_text)
    rows = [json.dumps({"concept_id": "damage", "kind": kind, "value": value,
                        "source": "Game/Combat.cs", "line": 1, "confidence": "high"})
            for kind, value in [("symbol", "damage"), ("alias", "伤害"), ("alias", "虚构词")]]
    monkeypatch.setattr(sys.modules[__name__], "ANSWER", "\n".join(rows) if source_text else "No terminology.")
    requests = []

    def handler(body):
        assert [tool["toolSpec"]["name"] for tool in body["toolConfig"]["tools"]] == ["read_glossary_source"]
        requests.append(body)
        if len(requests) == 2:
            content = body["messages"][-1]["content"][0]["toolResult"]["content"]
            if source_text:
                assert "伤害" in str(content)
            else:
                assert content == [{"json": {"output": ""}}]
        return converse_events(len(requests), name="read_glossary_source" if len(requests) == 1 else None)

    streams = install_transport(monkeypatch, handler)
    monkeypatch.setattr(glossary_build, "run_cc", lambda **kw: pytest.fail("Claude called"))
    entries = glossary_build.build(["Game/Combat.cs"], project="demo", cwd=str(tmp_path),
                                   model="us.openai.gpt-6-astra", region="us-east-2", sdk="openai")
    assert [entry.value for entry in entries] == (["damage", "伤害"] if source_text else [])
    assert len(requests) == 2
    assert all(stream.closed for stream in streams)


@pytest.mark.parametrize("value", ["", " \n\t", []])
def test_blank_tool_results_use_a_converse_json_object(value):
    messages = bedrock_converse.messages_from_input([
        {"type": "function_call_output", "call_id": "empty-file", "output": value},
    ])
    assert messages == [{"role": "user", "content": [{"toolResult": {
        "toolUseId": "empty-file", "content": [{"json": {"output": value}}],
    }}]}]


@pytest.mark.parametrize("failure", ["ReadTimeoutError", "ThrottlingException", "ValidationException"])
def test_glossary_retries_transient_provider_failure_only(monkeypatch, tmp_path, failure):
    from functools import partial

    from botocore.exceptions import ClientError, ReadTimeoutError

    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "index-service"))
    import glossary_build
    import openai_glossary

    (tmp_path / "Game").mkdir()
    (tmp_path / "Game/Combat.cs").write_text("int damage;\n")
    requests, waits = [], []

    def handler(body):
        requests.append(body)
        number = len(requests)
        if number == 2:
            if failure == "ReadTimeoutError":
                raise ReadTimeoutError(endpoint_url="https://bedrock.invalid")
            raise ClientError({"Error": {"Code": failure, "Message": "private source text"}}, "ConverseStream")
        return converse_events(number, name="read_glossary_source" if number in (1, 3) else None)

    streams = install_transport(monkeypatch, handler)
    run = partial(glossary_build._run_with_retry,
                  partial(openai_glossary.run_batch, files=["Game/Combat.cs"]),
                  prompt="Read the fixture.", cwd=str(tmp_path), model="us.openai.gpt-6-astra",
                  region="us-east-2", timeout=10, batch_idx=1, sleeper=waits.append)
    if failure == "ValidationException":
        import subprocess

        with pytest.raises(subprocess.SubprocessError, match="ClientError") as error:
            run()
        assert "private source text" not in str(error.value)
        assert len(requests) == 2 and not waits
    else:
        assert run() == ANSWER
        assert len(requests) == 4 and len(waits) == 1
    assert all(stream.closed for stream in streams)


def test_cancellation_closes_late_http_response(monkeypatch):
    from agents.models.interface import ModelTracing

    started, release = threading.Event(), threading.Event()
    stream = WireStream([])

    class Client:
        def converse_stream(self, **_):
            started.set()
            assert release.wait(3)
            return {"stream": stream}

        def close(self):
            pass

    monkeypatch.setattr(bedrock_converse, "create_client", lambda _: Client())

    async def run():
        async with openai_backend.create_model("us.openai.gpt-6-astra", "us-east-2") as model:
            events = model.stream_response(
                "", "hello", openai_backend.model_settings(), [], None, [], ModelTracing.DISABLED,
            )
            pending = asyncio.create_task(anext(events))
            try:
                for _ in range(100):
                    if started.is_set():
                        break
                    await asyncio.sleep(0.01)
                assert started.is_set()
                pending.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await pending
            finally:
                release.set()
                await events.aclose()
            for _ in range(100):
                if stream.closed:
                    break
                await asyncio.sleep(0.01)
            assert stream.closed

    asyncio.run(run())
