"""OpenAI Agents Model adapter for Bedrock ConverseStream.

Only text and function tools are supported. The Agents SDK still owns the loop;
Responses objects below are its internal event format, never an HTTP API call.
"""

from __future__ import annotations

import asyncio
import base64
import copy
import json
import time
from contextlib import aclosing
from typing import Any
from uuid import uuid4

import botocore.session
from agents import Model, ModelSettings
from agents.exceptions import ModelBehaviorError, UserError
from agents.items import ModelResponse
from agents.tool import FunctionTool
from agents.tracing import response_span
from agents.usage import Usage
from botocore.config import Config
from openai.types.responses import (
    Response,
    ResponseCompletedEvent,
    ResponseCreatedEvent,
    ResponseFunctionToolCall,
    ResponseOutputItemAddedEvent,
    ResponseOutputItemDoneEvent,
    ResponseOutputMessage,
    ResponseOutputText,
    ResponseReasoningItem,
    ResponseTextDeltaEvent,
    ResponseUsage,
)


def create_client(region: str):
    if not region:
        raise ValueError("AWS_REGION is required")
    # The existing openai[bedrock] lock includes botocore. Use its credential
    # chain and SigV4 directly, without adding another SDK or API-key transport.
    return botocore.session.get_session().create_client(
        "bedrock-runtime",
        region_name=region,
        config=Config(
            connect_timeout=10,
            read_timeout=300,
            retries={"mode": "standard", "total_max_attempts": 3},
        ),
    )


def _text_content(content: Any) -> list[dict]:
    if isinstance(content, str):
        return [{"text": content}]
    if isinstance(content, list) and content:
        result = []
        for part in content:
            if part.get("type") not in ("input_text", "output_text"):
                raise UserError("Converse adapter only accepts text content")
            result.append({"text": part["text"]})
        return result
    raise UserError("Converse adapter requires nonempty text content")


def messages_from_input(items: str | list[dict]) -> list[dict]:
    if isinstance(items, str):
        return [{"role": "user", "content": [{"text": items}]}]
    messages: list[dict] = []
    for item in items:
        kind = item.get("type", "message")
        role = "assistant"
        if kind == "message":
            role = item["role"]
            if role not in ("user", "assistant"):
                raise UserError("System instructions must use the agent instructions")
            content = _text_content(item["content"])
        elif kind == "function_call":
            arguments = json.loads(item["arguments"])
            if not isinstance(arguments, dict) or not item.get("call_id"):
                raise ModelBehaviorError("Invalid Converse tool call")
            content = [{"toolUse": {
                "toolUseId": item["call_id"], "name": item["name"], "input": arguments,
            }}]
        elif kind == "function_call_output":
            role = "user"
            output = item["output"]
            # Converse requires a JSON object at toolResult.content.json.
            # Empty files and reads past EOF legitimately return no text; a
            # scalar JSON string fails validation, and blank text also fails.
            if not output or (isinstance(output, str) and not output.strip()):
                result = [{"json": {"output": output}}]
            else:
                # MCP outputs arrive as lists of input_text blocks even when
                # there is only one empty text result. Normalize each block,
                # preserving its value and position alongside nonempty text.
                result = [
                    part if part["text"].strip() else {"json": {"output": part["text"]}}
                    for part in _text_content(output)
                ]
            content = [{"toolResult": {"toolUseId": item["call_id"], "content": result}}]
        elif kind == "reasoning":
            # Preserve provider blocks across SDK tool rounds, including binary
            # redactions and signatures. They are never rendered as answer text.
            reasoning = copy.deepcopy(item.get("provider_data", {}).get("bedrock_converse"))
            if not isinstance(reasoning, dict):
                raise UserError("Missing Converse reasoning continuation")
            if "redactedContent" in reasoning:
                reasoning["redactedContent"] = base64.b64decode(
                    reasoning["redactedContent"], validate=True,
                )
            content = [{"reasoningContent": reasoning}]
        else:
            raise UserError(f"Unsupported Converse input item: {kind}")
        # A model turn can contain reasoning, text and several tool calls.
        # Keep them in one assistant message, followed by one user tool-result message.
        if messages and messages[-1]["role"] == role:
            messages[-1]["content"].extend(content)
        else:
            messages.append({"role": role, "content": content})
    return messages


def _usage(raw: dict) -> ResponseUsage:
    cached = raw.get("cacheReadInputTokens", 0)
    written = raw.get("cacheWriteInputTokens", 0)
    input_tokens = raw["inputTokens"] + cached + written
    output_tokens = raw["outputTokens"]
    return ResponseUsage(
        input_tokens=input_tokens, output_tokens=output_tokens,
        total_tokens=input_tokens + output_tokens,
        input_tokens_details={"cached_tokens": cached, "cache_write_tokens": written},
        output_tokens_details={"reasoning_tokens": 0},
    )


class BedrockConverseModel(Model):
    def __init__(self, model: str, region: str):
        self.model = model
        self.region = region
        self.client = create_client(region)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        await self.close()

    async def close(self) -> None:
        await asyncio.to_thread(self.client.close)

    def _request(self, instructions, input, settings: ModelSettings, tools) -> dict:
        request: dict = {"modelId": self.model, "messages": messages_from_input(input)}
        if instructions:
            request["system"] = [{"text": instructions}]
        inference = {
            key: value for key, value in (
                ("maxTokens", settings.max_tokens),
                ("temperature", settings.temperature),
                ("topP", settings.top_p),
            ) if value is not None
        }
        if inference:
            request["inferenceConfig"] = inference
        if settings.tool_choice != "none" and tools:
            specs = []
            for tool in tools:
                if not isinstance(tool, FunctionTool):
                    raise UserError("Converse adapter only supports local function/MCP tools")
                specs.append({"toolSpec": {
                    "name": tool.name, "description": tool.description or tool.name,
                    "inputSchema": {"json": tool.params_json_schema},
                }})
            choice = settings.tool_choice or "auto"
            tool_choice = (
                {"auto": {}} if choice == "auto" else
                {"any": {}} if choice == "required" else {"tool": {"name": choice}}
            )
            request["toolConfig"] = {"tools": specs, "toolChoice": tool_choice}
            request["additionalModelRequestFields"] = {"parallel_tool_calls": False}
        if settings.reasoning is not None:
            request.setdefault("additionalModelRequestFields", {})["reasoning"] = (
                settings.reasoning.model_dump(exclude_none=True)
            )
        return request

    async def _open_stream(self, request: dict):
        # Cancellation may happen while botocore is waiting for response headers.
        # Shield the worker so its eventual HTTP body can still be closed.
        task = asyncio.create_task(asyncio.to_thread(self.client.converse_stream, **request))
        try:
            return (await asyncio.shield(task))["stream"]
        except asyncio.CancelledError:
            def close_late(done):
                if not done.cancelled() and done.exception() is None:
                    done.result()["stream"].close()
            task.add_done_callback(close_late)
            raise

    async def get_response(self, *args, **kwargs) -> ModelResponse:
        async with aclosing(self.stream_response(*args, **kwargs)) as events:
            async for event in events:
                if event.type == "response.completed":
                    response = event.response
                    usage = response.usage
                    return ModelResponse(
                        output=response.output, response_id=None,
                        usage=Usage(
                            requests=1, input_tokens=usage.input_tokens,
                            output_tokens=usage.output_tokens, total_tokens=usage.total_tokens,
                            input_tokens_details=usage.input_tokens_details,
                            output_tokens_details=usage.output_tokens_details,
                        ),
                    )
        raise ModelBehaviorError("Converse stream has no completed response")

    async def stream_response(
        self, system_instructions, input, model_settings, tools, output_schema,
        handoffs, tracing, *, previous_response_id=None, conversation_id=None, prompt=None,
    ):
        if previous_response_id or conversation_id or prompt or handoffs or (
            output_schema and not output_schema.is_plain_text()
        ):
            raise UserError("Converse adapter requires local text/tool history")
        request = self._request(system_instructions, input, model_settings, tools)
        response = Response(
            id="converse-" + uuid4().hex, created_at=time.time(), model=self.model,
            object="response", output=[], parallel_tool_calls=False, tool_choice="auto",
            tools=[], status="in_progress",
        )
        sequence = 0

        def event(cls, **fields):
            nonlocal sequence
            sequence += 1
            return cls(sequence_number=sequence, **fields)

        with response_span(disabled=tracing.is_disabled()) as span:
            if tracing.include_data():
                span.span_data.input = (
                    input if isinstance(input, str) else
                    [item for item in input if item.get("type") != "reasoning"]
                )
            stream = await self._open_stream(request)
            blocks: dict[int, dict] = {}
            output = {}
            started, stopped, usage = False, None, None
            try:
                yield event(ResponseCreatedEvent, type="response.created", response=response)
                iterator = iter(stream)
                while (entry := await asyncio.to_thread(next, iterator, None)) is not None:
                    if "messageStart" in entry:
                        if started or entry["messageStart"]["role"] != "assistant":
                            raise ModelBehaviorError("Invalid Converse message start")
                        started = True
                        continue
                    if "metadata" in entry:
                        if usage is not None or stopped is None:
                            raise ModelBehaviorError("Invalid Converse metadata order")
                        usage = _usage(entry["metadata"]["usage"])
                        continue
                    if "messageStop" in entry:
                        if stopped is not None or set(blocks) != set(output):
                            raise ModelBehaviorError("Unfinished Converse content blocks")
                        stopped = entry["messageStop"]["stopReason"]
                        if stopped not in ("end_turn", "tool_use", "stop_sequence"):
                            raise ModelBehaviorError(f"Converse stopped: {stopped}")
                        continue
                    if not started or stopped is not None:
                        raise ModelBehaviorError("Content outside Converse message")
                    name = next(iter(entry))
                    if name not in ("contentBlockStart", "contentBlockDelta", "contentBlockStop"):
                        raise ModelBehaviorError("Unexpected Converse stream event")
                    data = entry[name]
                    index = data["contentBlockIndex"]
                    if index in output:
                        raise ModelBehaviorError("Converse content after block stop")
                    value = data.get("start", data.get("delta", {}))
                    if index not in blocks:
                        if "toolUse" in value:
                            tool = value["toolUse"]
                            if not tool.get("toolUseId") or not tool.get("name"):
                                raise ModelBehaviorError("Missing Converse tool identity")
                            item = ResponseFunctionToolCall(
                                id="fc-" + uuid4().hex, type="function_call",
                                call_id=tool["toolUseId"], name=tool["name"], arguments="",
                            )
                            block = {"item": item, "kind": "toolUse"}
                        elif "text" in value:
                            item = ResponseOutputMessage(
                                id="msg-" + uuid4().hex, type="message", role="assistant",
                                content=[], status="in_progress",
                            )
                            block = {"item": item, "kind": "text", "text": ""}
                        elif "reasoningContent" in value:
                            item = ResponseReasoningItem(
                                id="rs-" + uuid4().hex, type="reasoning", summary=[],
                            )
                            block = {"item": item, "kind": "reasoningContent", "reasoning": {}}
                        else:
                            raise ModelBehaviorError("Unsupported Converse content block")
                        blocks[index] = block
                        yield event(ResponseOutputItemAddedEvent, type="response.output_item.added",
                                    output_index=index, item=item.model_copy(deep=True))
                    block = blocks[index]
                    item = block["item"]
                    if name == "contentBlockDelta":
                        kind = block["kind"]
                        if kind not in value:
                            raise ModelBehaviorError("Converse content block changed type")
                        if kind == "text":
                            block["text"] += value["text"]
                            yield event(
                                ResponseTextDeltaEvent, type="response.output_text.delta",
                                output_index=index, content_index=0, item_id=item.id,
                                delta=value["text"], logprobs=[],
                            )
                        elif kind == "toolUse":
                            item.arguments += value["toolUse"]["input"]
                        else:
                            for key, part in value["reasoningContent"].items():
                                if key not in ("text", "signature", "redactedContent"):
                                    raise ModelBehaviorError("Unknown Converse reasoning field")
                                default = b"" if key == "redactedContent" else ""
                                block["reasoning"][key] = block["reasoning"].get(key, default) + part
                    elif name == "contentBlockStop":
                        if block["kind"] == "text":
                            item.content = [ResponseOutputText(
                                type="output_text", text=block["text"], annotations=[],
                            )]
                        elif block["kind"] == "toolUse":
                            if not isinstance(json.loads(item.arguments), dict):
                                raise ModelBehaviorError("Converse tool arguments must be an object")
                        else:
                            native = block["reasoning"]
                            reasoning = (
                                {"redactedContent": base64.b64encode(native["redactedContent"]).decode()}
                                if "redactedContent" in native else {"reasoningText": native}
                            )
                            item = ResponseReasoningItem.model_validate({
                                **item.model_dump(), "provider_data": {"bedrock_converse": reasoning},
                            })
                        item.status = "completed"
                        output[index] = item
                        yield event(ResponseOutputItemDoneEvent, type="response.output_item.done",
                                    output_index=index, item=item)
                if not started or stopped is None or usage is None or not output:
                    raise ModelBehaviorError("Incomplete Converse stream")
                response.output = [output[index] for index in sorted(output)]
                has_tools = any(item.type == "function_call" for item in response.output)
                if has_tools != (stopped == "tool_use"):
                    raise ModelBehaviorError("Converse tool stop reason mismatch")
                response.status = "completed"
                response.usage = usage
                if tracing.include_data():
                    # Keep provider reasoning payloads out of application traces.
                    span.span_data.response = response.model_copy(update={
                        "output": [item for item in response.output if item.type != "reasoning"],
                    })
                yield event(ResponseCompletedEvent, type="response.completed", response=response)
            except Exception as exc:
                span.set_error({"message": type(exc).__name__})
                raise
            finally:
                # urllib3/http.client close waits on the buffered reader lock
                # if a cancelled to_thread(next) is still reading the body.
                # Await cleanup without blocking health checks or other tasks.
                await asyncio.to_thread(stream.close)
