"""Offline regressions found during the dual-SDK implementation review."""

import asyncio
import json
import socket
import sys
from contextlib import aclosing, asynccontextmanager
from pathlib import Path

import pytest
import uvicorn
from mcp.server.fastmcp import FastMCP

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agent_lib  # noqa: E402
import bedrock_converse  # noqa: E402
import engine_runner  # noqa: E402
from test_openai_runner import converse_events, install_transport  # noqa: E402
from test_openai_runner import trace_exporter as _trace_exporter  # noqa: E402

trace_exporter = _trace_exporter


@asynccontextmanager
async def mcp_fixture(monkeypatch):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    mcp = FastMCP("review", host="127.0.0.1", port=port, stateless_http=True, json_response=True)
    server = uvicorn.Server(uvicorn.Config(mcp.streamable_http_app(), log_level="error", access_log=False))
    task = None

    async def start():
        nonlocal task
        task = asyncio.create_task(server.serve(sockets=[sock]))
        for _ in range(100):
            if server.started:
                break
            await asyncio.sleep(0.01)
        assert server.started
        monkeypatch.setenv("CODEGRAPH_MCP_URL", f"http://127.0.0.1:{port}/mcp")

    try:
        yield mcp, start
    finally:
        server.should_exit = True
        if task:
            await task
        sock.close()

def configure_openai(monkeypatch):
    monkeypatch.setenv("AGENT_SDK", "openai")
    monkeypatch.setenv("AGENT_MODEL", "us.openai.gpt-6-astra")
    monkeypatch.setenv("AWS_REGION", "us-east-2")
    monkeypatch.setenv("AGENT_MAX_TURNS", "3")


@pytest.mark.parametrize("text", ["", " \n\t"])
def test_empty_mcp_result_round_trips_as_valid_converse_content(monkeypatch, trace_exporter, text):
    configure_openai(monkeypatch)
    requests = []

    def handler(body):
        requests.append(body)
        if len(requests) == 2:
            content = body["messages"][-1]["content"][0]["toolResult"]["content"]
            assert not any("text" in part and not part["text"].strip() for part in content)
            assert content == [{"json": {"output": text}}]
        return converse_events(len(requests), name="codegraph_read_file" if len(requests) == 1 else None)

    install_transport(monkeypatch, handler)

    async def run():
        async with mcp_fixture(monkeypatch) as (mcp, start):
            @mcp.tool()
            def codegraph_read_file(path: str) -> str:
                """Read an empty file or a range past EOF."""
                return text

            await start()
            return [event async for event in engine_runner.run_agent({
                "prompt": "read the file", "sdk": "claude", "model": "anthropic.untrusted",
                "agent": {"sdk": "claude"}, "maxTurns": 1,
                "CODEGRAPH_MCP_URL": "http://untrusted.invalid/mcp", "tools": ["Write"],
            })]

    events = asyncio.run(run())
    assert events[-1]["type"] == "run_completed", events
    assert all(event["sdk"] == "openai" for event in events)


def test_mcp_transport_error_is_reported_as_tool_failure(monkeypatch, trace_exporter):
    from agents.mcp import MCPServerStreamableHttp
    from mcp.shared.exceptions import McpError
    from mcp.types import ErrorData

    configure_openai(monkeypatch)
    requests = []

    def handler(body):
        requests.append(body)
        return converse_events(len(requests), name="codegraph_read_file" if len(requests) == 1 else None)

    async def failed_call(*args, **kwargs):
        raise McpError(ErrorData(code=-32603, message="temporary read failure"))

    install_transport(monkeypatch, handler)
    monkeypatch.setattr(MCPServerStreamableHttp, "call_tool", failed_call)

    async def run():
        async with mcp_fixture(monkeypatch) as (mcp, start):
            @mcp.tool()
            def codegraph_read_file(path: str) -> str:
                """Read evidence."""
                pytest.fail("transport failure must not execute a tool")

            await start()
            return [event async for event in engine_runner.run_agent({"prompt": "read the file"})]

    events = asyncio.run(run())
    assert events[-1]["type"] == "run_completed", events
    assert [event["isError"] for event in events if event["type"] == "tool_finished"] == [True]


def test_claude_retry_exhaustion_keeps_its_error_code(monkeypatch):
    monkeypatch.setenv("AGENT_SDK", "claude")
    monkeypatch.setenv("AGENT_MODEL", "global.anthropic.claude-opus-4-8")

    async def failed_agent(*args, **kwargs):
        yield {"error": "retrieval unavailable after retries (MCP tools not registered)",
               "error_type": "mcp_init_race", "is_error": True}

    monkeypatch.setattr(agent_lib, "run_agent", failed_agent)

    async def run():
        return [event async for event in engine_runner.run_agent({"prompt": "read the file"})]

    events = asyncio.run(run())
    assert len(events) == 1
    assert events[0]["type"] == "run_failed"
    assert events[0]["error"] == "mcp_init_race"


def test_closing_entrypoint_closes_engine_before_return(monkeypatch):
    import agent

    closed = []

    async def fake_run(payload):
        try:
            yield {"type": "text_delta"}
        finally:
            closed.append(True)

    monkeypatch.setattr(engine_runner, "run_agent", fake_run)

    async def run():
        events = agent.run_main({"prompt": "read the file"})
        await anext(events)
        await events.aclose()
        assert closed == [True]

    asyncio.run(run())


def test_closing_claude_bridge_closes_sdk_before_return(monkeypatch):
    closed = []

    async def fake_run(payload, **kwargs):
        try:
            yield {"content": [{"text": "reading"}]}
        finally:
            closed.append(True)

    monkeypatch.setattr(agent_lib, "run_agent", fake_run)

    async def run():
        events = engine_runner.claude_events({"prompt": "read"}, "global.anthropic.claude-opus-4-8")
        await anext(events)
        await events.aclose()
        assert closed == [True]

    asyncio.run(run())


def test_closing_claude_loop_closes_query_before_return(monkeypatch):
    from claude_agent_sdk import AssistantMessage, TextBlock, ToolUseBlock

    closed = []

    async def fake_query(**kwargs):
        try:
            # A tool call commits the stream, bypassing the cold-start buffer.
            yield AssistantMessage(
                content=[TextBlock(text="reading"),
                         ToolUseBlock(id="read-1", name="mcp__codegraph__codegraph_read_file", input={})],
                model="fixture",
            )
        finally:
            closed.append(True)

    async def run():
        events = agent_lib.run_agent({"prompt": "read"}, query_fn=fake_query)
        await anext(events)
        await events.aclose()
        assert closed == [True]

    asyncio.run(run())


def test_claude_sdk_optional_error_flag_is_a_protocol_boolean(monkeypatch):
    from claude_agent_sdk import AssistantMessage, TextBlock, ToolResultBlock, ToolUseBlock, UserMessage

    async def fake_run(*args, **kwargs):
        yield AssistantMessage(content=[
            ToolUseBlock(id="read-1", name="mcp__codegraph__codegraph_read_file", input={}),
        ], model="fixture")
        yield UserMessage(content=[ToolResultBlock(tool_use_id="read-1", content="code")])
        yield AssistantMessage(content=[TextBlock(text="answer")], model="fixture")
        yield {"num_turns": 2, "is_error": False, "result": "answer"}

    monkeypatch.setattr(agent_lib, "run_agent", fake_run)

    async def run():
        return [event async for event in engine_runner.claude_events(
            {"prompt": "read"}, "global.anthropic.claude-opus-4-8",
        )]

    events = asyncio.run(run())
    assert [event["toolId"] for event in events if event["type"] == "tool_started"] == ["read-1"]
    finished = [event for event in events if event["type"] == "tool_finished"]
    assert len(finished) == 1 and finished[0]["toolId"] == "read-1"
    assert finished[0]["isError"] is False


@pytest.mark.parametrize("result", [None, "", " \n"])
def test_empty_claude_result_is_not_reported_as_success(monkeypatch, result):
    monkeypatch.setenv("AGENT_SDK", "claude")
    monkeypatch.setenv("AGENT_MODEL", "global.anthropic.claude-opus-4-8")

    async def fake_run(*args, **kwargs):
        yield {"num_turns": 1, "is_error": False, "result": result}

    monkeypatch.setattr(agent_lib, "run_agent", fake_run)

    async def run():
        return [event async for event in engine_runner.run_agent({"prompt": "read"})]

    events = asyncio.run(run())
    assert len(events) == 1
    assert events[0]["type"] == "run_failed"


@pytest.mark.parametrize("parallel", [False, True])
def test_multiple_tool_results_keep_call_ids_error_flags_and_history(monkeypatch, trace_exporter, parallel):
    from agents import ModelSettings
    from agents.mcp import MCPServerStreamableHttp
    from mcp.types import CallToolResult, TextContent

    import openai_backend

    configure_openai(monkeypatch)
    # Exercise the SDK scheduler in both modes with a model turn containing
    # multiple tool calls. The deployed SDK setting is serial.
    monkeypatch.setattr(openai_backend, "model_settings", lambda: ModelSettings(parallel_tool_calls=parallel))
    requests = []
    completed = []

    def handler(body):
        requests.append(body)
        if len(requests) == 2:
            assistant, results = body["messages"][-2:]
            assert {block["toolUse"]["toolUseId"] for block in assistant["content"]} == {"slow", "bad"}
            assert {block["toolResult"]["toolUseId"] for block in results["content"]} == {"slow", "bad"}
            assert "is_error" not in json.dumps(body["messages"])
            return converse_events(2)
        events = [{"messageStart": {"role": "assistant"}}]
        for index, call_id in enumerate(("slow", "bad")):
            events.extend([
                {"contentBlockStart": {"contentBlockIndex": index, "start": {"toolUse": {
                    "toolUseId": call_id, "name": "codegraph_read_file",
                }}}},
                {"contentBlockDelta": {"contentBlockIndex": index, "delta": {"toolUse": {
                    "input": json.dumps({"path": call_id}),
                }}}},
                {"contentBlockStop": {"contentBlockIndex": index}},
            ])
        return events + converse_events(1, name="codegraph_read_file")[-2:]

    install_transport(monkeypatch, handler)

    async def run():
        async with mcp_fixture(monkeypatch) as (mcp, start):
            bad_finished = asyncio.Event()

            @mcp.tool()
            async def codegraph_read_file(path: str) -> str:
                """Read evidence."""
                if path == "bad":
                    completed.append(path)
                    bad_finished.set()
                    raise ValueError("file not found")
                if parallel:
                    await asyncio.wait_for(bad_finished.wait(), timeout=2)
                await asyncio.sleep(0.02)
                completed.append(path)
                return "code"

            if parallel:
                # The pinned Streamable HTTP client serializes requests on a
                # shared session. Use its real result type with an independent
                # transport to exercise out-of-order SDK tool completions.
                async def call_tool(server, name, arguments, **kwargs):
                    try:
                        text = await codegraph_read_file(**arguments)
                    except ValueError as exc:
                        return CallToolResult(content=[TextContent(type="text", text=str(exc))], isError=True)
                    return CallToolResult(content=[TextContent(type="text", text=text)])

                monkeypatch.setattr(MCPServerStreamableHttp, "call_tool", call_tool)

            await start()
            return [event async for event in engine_runner.run_agent({"prompt": "read both files"})]

    events = asyncio.run(run())
    assert events[-1]["type"] == "run_completed", events
    assert completed == (["bad", "slow"] if parallel else ["slow", "bad"])
    assert {event["toolId"]: event["isError"] for event in events if event["type"] == "tool_finished"} == {
        "bad": True, "slow": False,
    }
    assert events[-1]["numTurns"] == 2
    assert events[-1]["usage"] == {"input_tokens": 26, "output_tokens": 10}


@pytest.mark.parametrize("operation", ["close", "cancel"])
def test_openai_close_awaits_sdk_cleanup_before_closing_resources(monkeypatch, trace_exporter, operation):
    from agents.mcp import MCPServerStreamableHttp
    from mcp.types import Tool

    configure_openai(monkeypatch)
    monkeypatch.setenv("CODEGRAPH_MCP_URL", "http://fixture.invalid/mcp")
    install_transport(monkeypatch, lambda body: converse_events(1))
    state = {"model_stopped": False}
    original_stream = bedrock_converse.BedrockConverseModel.stream_response
    original_close = bedrock_converse.BedrockConverseModel.close

    async def enter(server):
        return server

    async def exit(server, *args):
        assert state["model_stopped"], "MCP closed while SDK model task was running"

    async def list_tools(server, *args, **kwargs):
        return [Tool(name="codegraph_read_file", inputSchema={"type": "object", "properties": {}})]

    async def slow_stream(model, *args, **kwargs):
        try:
            async with aclosing(original_stream(model, *args, **kwargs)) as source:
                async for event in source:
                    yield event
                    if event.type == "response.output_text.delta":
                        await asyncio.Event().wait()
        finally:
            # Model cleanup may itself need to await async work.
            await asyncio.sleep(0)
            state["model_stopped"] = True

    async def close(model):
        assert state["model_stopped"], "HTTP client closed while SDK model task was running"
        await original_close(model)

    monkeypatch.setattr(MCPServerStreamableHttp, "__aenter__", enter)
    monkeypatch.setattr(MCPServerStreamableHttp, "__aexit__", exit)
    monkeypatch.setattr(MCPServerStreamableHttp, "list_tools", list_tools)
    monkeypatch.setattr(bedrock_converse.BedrockConverseModel, "stream_response", slow_stream)
    monkeypatch.setattr(bedrock_converse.BedrockConverseModel, "close", close)

    async def run():
        events = engine_runner.run_agent({"prompt": "read"})
        assert (await anext(events))["type"] == "text_delta"
        if operation == "cancel":
            next_event = asyncio.create_task(anext(events))
            await asyncio.sleep(0)
            next_event.cancel()
            with pytest.raises(asyncio.CancelledError):
                await next_event
        else:
            await events.aclose()
        assert state["model_stopped"]

    asyncio.run(run())


@pytest.mark.parametrize("operation", ["close", "cancel", "complete", "initialize_error"])
@pytest.mark.parametrize("instrumented", [False, True])
def test_real_claude_sdk_closes_transport_before_return(monkeypatch, operation, instrumented):
    from functools import partial

    from claude_agent_sdk import AssistantMessage, ResultMessage, Transport, ToolUseBlock
    from openinference.instrumentation.claude_agent_sdk import ClaudeAgentSDKInstrumentor
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

    class OfflineTransport(Transport):
        """Raw I/O stub; the pinned SDK owns control initialization and parsing."""

        def __init__(self):
            self.messages = asyncio.Queue()
            self.closed = False
            self.reader_closed = False
            self.initialized = False
            self.prompts = []

        async def connect(self):
            pass

        def is_ready(self):
            return not self.closed

        async def end_input(self):
            pass

        async def close(self):
            await asyncio.sleep(0)
            self.closed = True

        async def write(self, data):
            value = json.loads(data)
            if value["type"] == "control_request":
                assert value["request"]["subtype"] == "initialize"
                self.initialized = True
                response = {
                    "subtype": "success", "request_id": value["request_id"], "response": {},
                }
                if operation == "initialize_error":
                    response.update(subtype="error", error="offline initialization failure")
                await self.messages.put({"type": "control_response", "response": response})
            elif value["type"] == "user":
                self.prompts.append(value["message"]["content"])
                await self.messages.put({
                    "type": "assistant",
                    "message": {"model": "fixture", "content": [{
                        "type": "tool_use", "id": "read-1",
                        "name": "mcp__codegraph__codegraph_read_file", "input": {"path": "file.py"},
                    }]},
                })
                if operation == "complete":
                    await self.messages.put({
                        "type": "result", "subtype": "success", "is_error": False,
                        "duration_ms": 1, "duration_api_ms": 1, "num_turns": 1,
                        "session_id": "fixture-session", "result": "answer",
                        "usage": {"input_tokens": 2, "output_tokens": 3},
                    })
                    # The one-shot query path ends when the transport reaches
                    # EOF after the result; a managed client closes it itself.
                    await self.messages.put(None)

        async def read_messages(self):
            try:
                while (message := await self.messages.get()) is not None:
                    yield message
            finally:
                self.reader_closed = True

    monkeypatch.setenv("COLD_START_MAX_RETRIES", "0")
    query_fn = agent_lib._default_query_fn()

    async def run():
        transport = OfflineTransport()
        output = agent_lib.run_agent(
            {"prompt": "read the source"}, query_fn=partial(query_fn, transport=transport),
        )
        received = asyncio.Event()

        async def consume():
            # SDK client operations and instrumentation must stay in the same
            # task/context; cancel that entire consumer, not a separate anext.
            async with aclosing(output):
                async with asyncio.timeout(2):
                    first = await anext(output)
                assert transport.initialized
                if operation == "initialize_error":
                    assert first["error_type"] == "mcp_init_race"
                else:
                    assert isinstance(first, AssistantMessage)
                    assert isinstance(first.content[0], ToolUseBlock)
                    assert transport.prompts == ["read the source"]
                    if operation == "cancel":
                        received.set()
                        await anext(output)
                    elif operation == "complete":
                        remaining = [message async for message in output]
                        assert len(remaining) == 1 and isinstance(remaining[0], ResultMessage)
                        assert remaining[0].result == "answer"

        if operation == "cancel":
            pending = asyncio.create_task(consume())
            async with asyncio.timeout(2):
                await received.wait()
            pending.cancel()
            with pytest.raises(asyncio.CancelledError):
                await pending
        else:
            await consume()
        # No event-loop ticks or GC are allowed between aclose and these checks.
        assert transport.closed
        assert transport.reader_closed

    provider = TracerProvider()
    exporter = InMemorySpanExporter()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    instrumentor = ClaudeAgentSDKInstrumentor()
    if instrumented:
        instrumentor.instrument(tracer_provider=provider)
    try:
        asyncio.run(run())
        if instrumented and operation == "complete":
            spans = exporter.get_finished_spans()
            assert any(span.instrumentation_scope.name ==
                       "openinference.instrumentation.claude_agent_sdk" for span in spans)
            assert any("answer" in str(span.attributes.get("output.value", "")) for span in spans)
    finally:
        if instrumented:
            instrumentor.uninstrument()
        provider.shutdown()


def test_converse_cancellation_keeps_event_loop_live_while_http_read_is_locked(monkeypatch):
    import http.client
    import threading

    import botocore.eventstream
    import botocore.parsers
    import botocore.session
    from agents.models.interface import ModelTracing
    from urllib3.response import HTTPResponse

    import openai_backend

    left, right = socket.socketpair()
    # Headers have arrived, but the provider stops sending the event-stream
    # body. The real buffered HTTP reader holds a lock until the peer closes.
    right.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n")
    response = http.client.HTTPResponse(left)
    response.begin()
    raw = HTTPResponse(body=response, headers=dict(response.headers.items()), status=200,
                       preload_content=False, original_response=response)
    shape = botocore.session.get_session().get_service_model("bedrock-runtime").operation_model(
        "ConverseStream",
    ).output_shape.members["stream"]
    stream = botocore.eventstream.EventStream(
        raw, shape, botocore.parsers.EventStreamJSONParser(), "ConverseStream",
    )
    read_started = threading.Event()
    fallback_fired = threading.Event()
    raw_read = raw.read

    def observed_read(*args, **kwargs):
        read_started.set()
        return raw_read(*args, **kwargs)

    monkeypatch.setattr(raw, "read", observed_read)

    class Client:
        def converse_stream(self, **kwargs):
            return {"stream": stream}

        def close(self):
            pass

    monkeypatch.setattr(bedrock_converse, "create_client", lambda region: Client())

    def unblock_on_regression():
        fallback_fired.set()
        right.close()

    timer = threading.Timer(1, unblock_on_regression)

    async def run():
        async with openai_backend.create_model("fixture", "fixture") as model:
            async def consume():
                async with aclosing(model.stream_response(
                    "", "read", openai_backend.model_settings(), [], None, [], ModelTracing.DISABLED,
                )) as events:
                    async for _ in events:
                        pass

            pending = asyncio.create_task(consume())
            for _ in range(100):
                if read_started.is_set():
                    break
                await asyncio.sleep(0.005)
            assert read_started.is_set()
            await asyncio.sleep(0.02)
            timer.start()

            async def heartbeat():
                await asyncio.sleep(0.02)
                # This coroutine must run while cancellation awaits HTTP close.
                right.close()

            heartbeat_task = asyncio.create_task(heartbeat())
            pending.cancel()
            with pytest.raises(asyncio.CancelledError):
                await pending
            await heartbeat_task
            assert not fallback_fired.is_set(), "HTTP close blocked the event-loop heartbeat"
            assert raw.closed

    try:
        asyncio.run(run())
    finally:
        timer.cancel()
        if timer.ident is not None:
            timer.join()
        left.close()
        right.close()
        stream.close()


@pytest.mark.parametrize("envelope,expected", [
    ({"error": "read failed", "detail": "internal failure"}, True),
    ({"error": "repo not in scope"}, True),
    ({"error": None, "content": "source"}, False),
    ({"path": "file.py", "content": '{"error":"a literal in the source"}'}, False),
    ({"rows": [{"error": "column value"}]}, False),
])
@pytest.mark.parametrize("as_blocks", [False, True])
def test_claude_json_error_envelope_updates_protocol_and_telemetry(monkeypatch, envelope, expected, as_blocks):
    from claude_agent_sdk import AssistantMessage, ToolResultBlock, ToolUseBlock, UserMessage

    monkeypatch.setenv("AGENT_SDK", "claude")
    monkeypatch.setenv("AGENT_MODEL", "global.anthropic.claude-opus-4-8")
    content = json.dumps(envelope)
    content = [{"type": "text", "text": content}] if as_blocks else content
    original_run = agent_lib.run_agent
    samples = []

    async def fake_query(**kwargs):
        yield AssistantMessage(content=[
            ToolUseBlock(id="read-1", name="mcp__codegraph__codegraph_read_file", input={}),
        ], model="fixture")
        yield UserMessage(content=[ToolResultBlock(tool_use_id="read-1", content=content)])
        yield {"num_turns": 2, "is_error": False, "result": "answer"}

    monkeypatch.setattr(agent_lib, "run_agent", lambda payload, **kwargs: original_run(
        payload, query_fn=fake_query, **kwargs,
    ))
    monkeypatch.setattr(agent_lib, "_perf", lambda event, ms, **kwargs: samples.append((event, kwargs)))

    async def run():
        return [event async for event in engine_runner.run_agent({"prompt": "read"})]

    events = asyncio.run(run())
    assert events[-1]["type"] == "run_completed"
    assert [event["isError"] for event in events if event["type"] == "tool_finished"] == [expected]
    assert [fields["is_error"] for event, fields in samples if event == "tool_latency"] == [expected]
    assert "internal failure" not in json.dumps(events)


def test_openai_json_error_then_successful_read_retry(monkeypatch, trace_exporter):
    configure_openai(monkeypatch)
    requests, samples = [], []
    results = [
        '{"error":"read failed","detail":"private failure detail"}',
        '{"path":"Game/Combat.cs","content":"const string example = {\\"error\\":\\"source literal\\"};"}',
    ]

    def handler(body):
        requests.append(body)
        number = len(requests)
        if number == 2:
            assert "read failed" in json.dumps(body["messages"][-1])
        if number == 3:
            assert "source literal" in json.dumps(body["messages"][-1])
        return converse_events(number, name="codegraph_read_file" if number < 3 else None)

    install_transport(monkeypatch, handler)
    monkeypatch.setattr(agent_lib, "_perf", lambda event, ms, **kwargs: samples.append((event, kwargs)))

    async def run():
        async with mcp_fixture(monkeypatch) as (mcp, start):
            @mcp.tool()
            def codegraph_read_file(path: str) -> str:
                """Read evidence, with a bridge error on the first attempt."""
                return results.pop(0)

            await start()
            return [event async for event in engine_runner.run_agent({"prompt": "read the file"})]

    events = asyncio.run(run())
    assert events[-1]["type"] == "run_completed", events
    assert events[-1]["numTurns"] == 3
    assert [event["isError"] for event in events if event["type"] == "tool_finished"] == [True, False]
    assert [fields["is_error"] for event, fields in samples if event == "tool_latency"] == [True, False]
    assert "private failure detail" not in json.dumps(events)
