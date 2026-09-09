"""Versioned gateway events; SDK-specific objects never cross this boundary."""

from __future__ import annotations

from dataclasses import asdict, is_dataclass
from contextlib import aclosing
from uuid import uuid4

import agent_lib
from agent_settings import runtime_settings


async def claude_events(payload: dict, model: str):
    partial = False
    message_id = ""
    counter = 0
    async with aclosing(agent_lib.run_agent(payload, model=model)) as messages:
        async for message in messages:
            item = asdict(message) if is_dataclass(message) else message
            if not isinstance(item, dict):
                continue
            raw = item.get("event")
            if isinstance(raw, dict):
                partial = True
                if raw.get("type") == "content_block_start":
                    block = raw.get("content_block", {})
                    counter += 1
                    message_id = f"claude-{counter}"
                    if block.get("type") == "tool_use":
                        yield {"type": "tool_started", "toolId": block["id"], "name": block["name"]}
                elif raw.get("type") == "content_block_delta":
                    delta = raw.get("delta", {})
                    if delta.get("type") == "text_delta":
                        yield {"type": "text_delta", "messageId": message_id, "text": delta["text"]}
            for block in item.get("content", []) if isinstance(item.get("content"), list) else []:
                if "tool_use_id" in block:
                    yield {"type": "tool_finished", "toolId": block["tool_use_id"],
                           "isError": agent_lib.tool_result_is_error(
                               block.get("content"), block.get("is_error"),
                           )}
                elif not partial:
                    if "text" in block:
                        counter += 1
                        yield {"type": "text_delta", "messageId": f"claude-{counter}", "text": block["text"]}
                    elif "id" in block and "name" in block:
                        yield {"type": "tool_started", "toolId": block["id"], "name": block["name"]}
            if "num_turns" in item and "is_error" in item:
                yield {"type": "run_failed" if item["is_error"] else "run_completed",
                       "error": item.get("subtype", "") if item["is_error"] else None,
                       "text": item.get("result") or "", "numTurns": item["num_turns"],
                       "usage": item.get("usage") or {}}
            elif item.get("is_error"):
                # agent_lib's exhausted cold-start retry is a terminal error
                # dictionary, rather than a Claude SDK ResultMessage.
                yield {"type": "run_failed", "error": item.get("error_type") or "agent_error"}


async def run_agent(payload):
    run_id = str(uuid4())
    seq = 0
    terminal = None
    try:
        if not isinstance(payload, dict) or not isinstance(payload.get("prompt"), str) or not payload["prompt"].strip():
            raise ValueError("payload.prompt must be a non-empty string")
        settings = runtime_settings()
        if settings.sdk == "openai":
            from openai_runner import run

            events = run(payload, settings)
        else:
            events = claude_events(payload, settings.model)
        async with aclosing(events):
            async for event in events:
                if terminal is not None:
                    raise RuntimeError("events after terminal result")
                if event["type"] in ("run_completed", "run_failed"):
                    terminal = event
                    continue
                seq += 1
                yield {"protocol": "source-truth", "version": 1, "runId": run_id, "seq": seq,
                       "sdk": settings.sdk, **event}
        if terminal is None:
            raise RuntimeError("agent stream ended without a terminal result")
        if terminal["type"] == "run_completed" and (
            not isinstance(terminal.get("text"), str) or not terminal["text"].strip()
        ):
            raise RuntimeError("agent run did not produce a complete answer")
        yield {"protocol": "source-truth", "version": 1, "runId": run_id, "seq": seq + 1,
               "sdk": settings.sdk, **terminal}
    except Exception as exc:
        # Do not stream exception details: upstream errors may contain model input.
        error = "error_max_turns" if type(exc).__name__ == "MaxTurnsExceeded" else type(exc).__name__
        yield {"protocol": "source-truth", "version": 1, "runId": run_id, "seq": seq + 1,
               "type": "run_failed", "error": error}
