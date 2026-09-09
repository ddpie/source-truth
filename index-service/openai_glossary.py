"""OpenAI glossary worker: exact batch reads, no shell or other host tools."""

from __future__ import annotations

import asyncio
import os
import subprocess
from pathlib import Path

from glossary_source import open_source


class RetryableBatchError(subprocess.SubprocessError):
    """Transient provider failure; safe detail only, never prompt/source text."""


def read_source(root: Path, allowed: set[str], path: str, start_line: int = 1,
                max_lines: int = 200, start_column: int = 1) -> str:
    if path not in allowed or start_line < 1 or start_column < 1 or not 1 <= max_lines <= 500:
        raise ValueError("read outside batch or invalid line range")
    parts = []
    size = 0
    number, column = 1, 1
    with open_source(root, path) as source:
        while True:
            # Bound memory even for a minified/generated file with a multi-megabyte line.
            chunk = source.readline(4000)
            if not chunk:
                break
            next_number, next_column = ((number + 1, 1) if chunk.endswith("\n")
                                        else (number, column + len(chunk)))
            if number < start_line or (number == start_line and next_column <= start_column
                                       and next_number == number):
                number, column = next_number, next_column
                continue
            if number == start_line and column < start_column:
                chunk = chunk[start_column - column:]
                column = start_column
            label = f"{number}: " if column == 1 else f"{number} (column {column}): "
            text = label + chunk
            parts.append(text)
            size += len(text)
            number, column = next_number, next_column
            if number >= start_line + max_lines or size >= 44000:
                if source.read(1):
                    parts.append(f"\n[Continue at start_line={number}, start_column={column}]\n")
                break
    return "".join(parts)


def run_batch(prompt: str, *, files: list[str], cwd: str, model: str, region: str, timeout: int) -> str:
    from agents import Agent, RunConfig, Runner, function_tool
    from botocore.exceptions import (
        ClientError, ConnectionClosedError, ConnectTimeoutError, EndpointConnectionError, ReadTimeoutError,
    )
    from urllib3.exceptions import ProtocolError, ReadTimeoutError as StreamReadTimeoutError

    import openai_backend

    @function_tool
    def read_glossary_source(path: str, start_line: int = 1, max_lines: int = 200,
                             start_column: int = 1) -> str:
        """Read batch source; follow continuation line/column for long lines or files."""
        return read_source(Path(cwd), set(files), path, start_line, max_lines, start_column)

    async def invoke() -> str:
        async with openai_backend.create_model(model, region) as backend:
            agent = Agent(
                name="source-truth-glossary",
                instructions="Extract grounded terminology using only read_glossary_source. "
                             "Read the supplied files before emitting JSONL.",
                tools=[read_glossary_source],
                model=backend,
                model_settings=openai_backend.model_settings(),
            )
            stream = Runner.run_streamed(
                agent, prompt, max_turns=int(os.environ.get("GLOSSARY_MAX_TURNS", "400")),
                run_config=RunConfig(tracing_disabled=True),
            )
            async for _ in stream.stream_events():
                pass
            if stream.interruptions or not isinstance(stream.final_output, str):
                raise RuntimeError("glossary run did not complete")
            if not stream.final_output.strip():
                raise RetryableBatchError("OpenAI glossary returned no output")
            return stream.final_output

    async def bounded() -> str:
        return await asyncio.wait_for(invoke(), timeout)

    try:
        return asyncio.run(bounded())
    except RetryableBatchError:
        raise
    except (TimeoutError, ConnectTimeoutError, ReadTimeoutError,
            EndpointConnectionError, ConnectionClosedError,
            StreamReadTimeoutError, ProtocolError) as exc:
        # EventStream iteration can expose urllib3 errors after headers arrive,
        # without botocore wrapping them in its own transport exception types.
        raise RetryableBatchError(f"OpenAI glossary failed: {type(exc).__name__}") from exc
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in {"ThrottlingException", "ModelTimeoutException", "ModelNotReadyException",
                    "ServiceUnavailableException", "InternalServerException"}:
            raise RetryableBatchError(f"OpenAI glossary failed: {code}") from exc
        raise subprocess.SubprocessError("OpenAI glossary failed: ClientError") from exc
    except Exception as exc:
        # Match the existing batch failure contract without logging prompt/source.
        raise subprocess.SubprocessError(f"OpenAI glossary failed: {type(exc).__name__}") from exc
