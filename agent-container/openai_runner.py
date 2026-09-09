"""OpenAI Agents SDK loop with only the project's read-only HTTP MCP tools."""

from __future__ import annotations

import os
import time
from contextlib import aclosing

import agent_lib
import openai_backend
from agent_settings import AgentSettings


async def run(payload: dict, settings: AgentSettings):
    from agents import Agent, Runner
    from agents.mcp import MCPServerStreamableHttp, create_static_tool_filter

    url = os.environ.get("CODEGRAPH_MCP_URL", "")
    # Reuse the existing URL boundary and allowlist, never accept a payload endpoint.
    agent_lib.build_options_dict(system_prompt="", codegraph_url=url)
    if not url:
        raise ValueError("CODEGRAPH_MCP_URL is required")
    allowed = [name.removeprefix("mcp__codegraph__") for name in agent_lib.CODEGRAPH_TOOLS]
    trace_id = payload.get("traceId", "")
    start = time.perf_counter()

    class ObservedMCPServer(MCPServerStreamableHttp):
        async def call_tool(self, tool_name, arguments, **kwargs):
            started = time.perf_counter()
            is_error = True
            try:
                result = await super().call_tool(tool_name, arguments, **kwargs)
                is_error = agent_lib.tool_result_is_error(result.content, result.isError)
                if is_error != bool(result.isError):
                    result = result.model_copy(update={"isError": is_error})
                return result
            finally:
                agent_lib._perf("tool_latency", (time.perf_counter() - started) * 1000,
                                traceId=trace_id, sdk="openai", api="ConverseStream", tool=tool_name,
                                is_error=is_error)

    openai_backend.instrument()
    try:
        async with openai_backend.create_model(
            settings.model,
            os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "")
        ) as model, ObservedMCPServer(
            params={"url": url, "timeout": 60},
            name="codegraph", cache_tools_list=True,
            client_session_timeout_seconds=60,
            tool_filter=create_static_tool_filter(allowed_tool_names=allowed),
            require_approval="never",
            # SDK-local metadata stays attached to its call ID and is excluded
            # from model history. Completion order cannot misattribute errors.
            custom_data_extractor=lambda context: {"is_error": context.is_error},
        ) as server:
            tools = await server.list_tools()
            if not tools:
                raise RuntimeError("CodeGraph exposed no permitted tools")
            agent = Agent(
                name="source-truth",
                instructions=agent_lib.load_system_prompt(),
                tools=[], mcp_servers=[server],
                model=model,
                model_settings=openai_backend.model_settings(),
            )
            stream = Runner.run_streamed(agent, payload["prompt"], max_turns=settings.max_turns)
            try:
                async with aclosing(stream.stream_events()) as events:
                    try:
                        async for event in events:
                            if event.type == "raw_response_event" and event.data.type == "response.output_text.delta":
                                yield {"type": "text_delta", "messageId": event.data.item_id,
                                       "text": event.data.delta}
                            elif event.type == "run_item_stream_event":
                                raw = event.item.raw_item
                                if event.name == "tool_called":
                                    yield {"type": "tool_started", "toolId": raw.call_id, "name": raw.name}
                                elif event.name == "tool_output":
                                    # A transport/SDK failure has no MCP result
                                    # metadata: it is a failed call, never success.
                                    yield {"type": "tool_finished", "toolId": raw.get("call_id", ""),
                                           "isError": (event.item.custom_data or {}).get("is_error", True)}
                    finally:
                        if not stream.is_complete:
                            stream.cancel()
            finally:
                # Cancellation inside stream_events returns promptly. Drain
                # once more to await the SDK's cleanup before closing MCP/model.
                if not stream.is_complete:
                    stream.cancel()
                async for _ in stream.stream_events():
                    pass
            # response.completed only ends a model turn. Success belongs to Runner.
            if stream.interruptions or not isinstance(stream.final_output, str) or not stream.final_output.strip():
                raise RuntimeError("agent run did not produce a complete answer")
            usage = stream.context_wrapper.usage
            agent_lib._perf(
                "agent_result", (time.perf_counter() - start) * 1000,
                traceId=trace_id, sdk="openai", model=settings.model, api="ConverseStream",
                num_turns=len(stream.raw_responses), input_tokens=usage.input_tokens,
                output_tokens=usage.output_tokens, is_error=False,
            )
            yield {"type": "run_completed", "text": stream.final_output,
                   "numTurns": len(stream.raw_responses),
                   "usage": {"input_tokens": usage.input_tokens, "output_tokens": usage.output_tokens}}
    finally:
        agent_lib._perf("agent_run_total", (time.perf_counter() - start) * 1000,
                        traceId=trace_id, sdk="openai", model=settings.model, api="ConverseStream")
