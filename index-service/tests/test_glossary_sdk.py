"""SDK switching invalidates unchanged source, and failed builds retain the slice."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import glossary_build  # noqa: E402
import glossary_config  # noqa: E402
import glossary_gen  # noqa: E402
from openai_glossary import read_source  # noqa: E402


@pytest.mark.parametrize("path", [".env", ".home/history", ".git/config", "src/private.key"])
def test_batch_read_uses_existing_served_path_policy(tmp_path, path):
    target = tmp_path / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("fixture confidential material")
    with pytest.raises(ValueError):
        read_source(tmp_path, {path}, path)
    alias = tmp_path / "ordinary.txt"
    alias.symlink_to(target)
    with pytest.raises(ValueError):
        read_source(tmp_path, {"ordinary.txt"}, "ordinary.txt")


def test_batch_read_preserves_allowed_hidden_examples(tmp_path):
    (tmp_path / ".env.example").write_text("example\n")
    assert read_source(tmp_path, {".env.example"}, ".env.example") == "1: example\n"


def test_candidate_scan_uses_existing_served_path_policy(tmp_path):
    for name in (".env", ".env.example", ".home/history", ".git/config", "src/a.cs"):
        target = tmp_path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("fixture")
    (tmp_path / "alias.cs").symlink_to(tmp_path / ".env")
    assert glossary_gen.candidate_files(str(tmp_path)) == [".env.example", "src/a.cs"]

def test_binary_content_is_excluded_before_the_model_and_file_cap(tmp_path):
    (tmp_path / "a.unknown").write_bytes(b"binary header\x00payload")
    (tmp_path / "b.PDB").write_bytes(b"Microsoft C/C++ debug symbols")
    (tmp_path / "c.cs").write_text("int power; // 战力\n")
    assert glossary_gen.candidate_files(str(tmp_path)) == ["c.cs"]
    with pytest.raises(ValueError, match="must be text"):
        read_source(tmp_path, {"a.unknown"}, "a.unknown")
    assert read_source(tmp_path, {"c.cs"}, "c.cs") == "1: int power; // 战力\n"
    assert glossary_build.build(
        ["a.unknown"], project="demo", cwd=str(tmp_path), model="m", region="r",
        sdk="openai", runner=lambda *a, **k: pytest.fail("binary reached model"),
    ) == []


def test_model_batch_does_not_silently_drop_a_read_failure(tmp_path, monkeypatch):
    (tmp_path / "a.cs").write_text("int power;\n")

    def unreadable(*a, **k):
        raise OSError("fixture transient I/O error")

    monkeypatch.setattr(glossary_build, "open_source", unreadable)
    with pytest.raises(OSError):
        glossary_build.build(
            ["a.cs"], project="demo", cwd=str(tmp_path), model="m", region="r",
            runner=lambda *a, **k: pytest.fail("partial batch reached model"),
        )


def test_grounding_does_not_read_withheld_paths(tmp_path, monkeypatch):
    (tmp_path / "a.cs").write_text("int power;\n")
    (tmp_path / ".env").write_text("只在敏感文件\n")
    row = json.dumps({"concept_id": "power", "kind": "alias", "value": "只在敏感文件",
                      "source": ".env", "line": 1, "confidence": "high"})
    monkeypatch.setattr(glossary_build, "run_cc", lambda *args, **kwargs: row)
    assert glossary_build.build(["a.cs"], project="demo", cwd=str(tmp_path),
                                model="m", region="r") == []


def test_openai_output_cannot_publish_a_source_outside_its_batch(tmp_path):
    (tmp_path / "a.cs").write_text("int power;\n")
    (tmp_path / "b.cs").write_text("// 战力\n")
    rows = [
        {"concept_id": "power", "kind": "alias", "value": "战力", "source": "b.cs",
         "line": 1, "confidence": "high"},
        {"concept_id": "power", "kind": "symbol", "value": "power", "source": ".env",
         "line": 1, "confidence": "high"},
    ]
    entries = glossary_build.build(
        ["a.cs"], project="demo", cwd=str(tmp_path), model="m", region="r", sdk="openai",
        runner=lambda *args, **kwargs: "\n".join(json.dumps(row) for row in rows),
    )
    assert entries == []


def test_model_source_paths_are_canonical_before_incremental_merge(tmp_path):
    (tmp_path / "a.cs").write_text("// 战力 power\n")
    rows = [{"concept_id": "power", "kind": kind, "value": value,
             "source": str(tmp_path / "a.cs"), "line": 1, "confidence": "high"}
            for kind, value in [("symbol", "power"), ("alias", "战力")]]
    entries = glossary_build.build(
        ["a.cs"], project="demo", cwd=str(tmp_path), model="m", region="r",
        runner=lambda *args, **kwargs: "\n".join(json.dumps(row) for row in rows),
    )
    assert len(entries) == 2
    assert all(entry.source == "a.cs" for entry in entries)
    assert glossary_build.merge_incremental(entries, changed={"a.cs"}, deleted=set(), rebuilt=[]) == []


def test_openai_transport_connection_failure_is_retryable(monkeypatch):
    from contextlib import asynccontextmanager
    from types import SimpleNamespace

    from botocore.exceptions import EndpointConnectionError
    import openai_glossary

    @asynccontextmanager
    async def unavailable(*args):
        raise EndpointConnectionError(endpoint_url="https://fixture.invalid")
        yield  # pragma: no cover

    monkeypatch.setitem(sys.modules, "openai_backend", SimpleNamespace(create_model=unavailable))
    with pytest.raises(openai_glossary.RetryableBatchError):
        openai_glossary.run_batch("fixture", files=["a.cs"], cwd="/tmp",
                                 model="m", region="r", timeout=1)


def test_empty_model_output_retries_but_explicit_no_terms_completes(monkeypatch):
    from contextlib import asynccontextmanager
    from types import SimpleNamespace

    import agents
    import openai_glossary

    closed = []
    outputs = iter(["", "[]"])

    @asynccontextmanager
    async def backend(*args):
        try:
            yield object()
        finally:
            closed.append(True)

    class Stream:
        interruptions = []

        def __init__(self):
            self.final_output = next(outputs)

        async def stream_events(self):
            if False:
                yield None

    monkeypatch.setitem(sys.modules, "openai_backend", SimpleNamespace(
        create_model=backend, model_settings=lambda: None))
    monkeypatch.setattr(agents, "Agent", lambda **kwargs: object())
    monkeypatch.setattr(agents.Runner, "run_streamed", lambda *args, **kwargs: Stream())
    result = glossary_build._run_with_retry(
        lambda *args, **kwargs: openai_glossary.run_batch(*args, files=["a.cs"], **kwargs),
        prompt="fixture", cwd="/tmp", model="m", region="r", timeout=1, batch_idx=1,
        sleeper=lambda _: None, rng=lambda _a, _b: 0,
    )
    assert result == "[]"
    assert closed == [True, True]


@pytest.mark.parametrize("error_kind", ["read_timeout", "protocol"])
def test_raw_stream_transport_failure_retries_and_closes_model(monkeypatch, caplog, error_kind):
    from contextlib import asynccontextmanager
    from types import SimpleNamespace

    import agents
    import openai_glossary
    from urllib3.exceptions import ProtocolError, ReadTimeoutError

    private_detail = "fixture source content that must not be logged"
    error = (ReadTimeoutError(None, "/fixture", private_detail)
             if error_kind == "read_timeout" else ProtocolError(private_detail))
    attempts = []
    closed = []

    @asynccontextmanager
    async def backend(*args):
        try:
            yield object()
        finally:
            closed.append(True)

    class Stream:
        interruptions = []
        final_output = "[]"

        async def stream_events(self):
            attempts.append(True)
            if len(attempts) == 1:
                raise error
            if False:
                yield None

    monkeypatch.setitem(sys.modules, "openai_backend", SimpleNamespace(
        create_model=backend, model_settings=lambda: None))
    monkeypatch.setattr(agents, "Agent", lambda **kwargs: object())
    monkeypatch.setattr(agents.Runner, "run_streamed", lambda *args, **kwargs: Stream())
    result = glossary_build._run_with_retry(
        lambda *args, **kwargs: openai_glossary.run_batch(*args, files=["a.cs"], **kwargs),
        prompt="fixture", cwd="/tmp", model="m", region="r", timeout=1, batch_idx=1,
        sleeper=lambda _: None, rng=lambda _a, _b: 0,
    )
    assert result == "[]"
    assert len(attempts) == 2
    assert closed == [True, True]
    assert "glossary_build_retry" in caplog.text
    assert private_detail not in caplog.text


def test_long_line_page_can_resume_without_losing_content(tmp_path):
    (tmp_path / "a.cs").write_text("a" * 50000 + "TAIL\nnext\n")
    first = read_source(tmp_path, {"a.cs"}, "a.cs")
    assert "start_line=1" in first and "start_column=" in first
    import re
    column = int(re.search(r"start_column=(\d+)", first).group(1))
    second = read_source(tmp_path, {"a.cs"}, "a.cs", start_column=column)
    assert "TAIL" in second and "2: next" in second


def test_queued_worker_observes_disabled_config(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "a.cs").write_text("int power;\n")
    out = tmp_path / "slice.jsonl"
    out.write_text("previous artifact\n")
    config = tmp_path / "project.env"
    config.write_text("AGENT_SDK=openai\nMODEL=\nREGION=r\nGLOSSARY_ENABLED=false\n")
    monkeypatch.setenv("GLOSSARY_CONFIG_FILE", str(config))
    monkeypatch.setattr(glossary_build, "build",
                        lambda *args, **kwargs: pytest.fail("disabled worker invoked model"))
    assert glossary_gen.main(["--project", "p", "--repo-root", str(repo), "--out", str(out),
                              "--model", "previous", "--region", "r"]) == 0
    assert out.read_text() == "previous artifact\n"


def test_queued_worker_for_removed_repo_cannot_recreate_slice(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "a.cs").write_text("int power;\n")
    config = tmp_path / "project.env"
    config.write_text("AGENT_SDK=openai\nMODEL=m\nREGION=r\nGLOSSARY_SUBDIRS=retained\n")
    monkeypatch.setenv("GLOSSARY_CONFIG_FILE", str(config))
    monkeypatch.setattr(glossary_build, "build",
                        lambda *args, **kwargs: pytest.fail("removed repo invoked model"))
    out = tmp_path / "removed.jsonl"
    assert glossary_gen.main(["--project", "p", "--repo-root", str(repo), "--out", str(out),
                              "--model", "m", "--region", "r"]) == 0
    assert not out.exists()

def test_file_cap_change_invalidates_fingerprint(monkeypatch):
    monkeypatch.setenv("GLOSSARY_MAX_FILES", "400")
    capped = glossary_config.fingerprint("openai", "m", "r")
    monkeypatch.setenv("GLOSSARY_MAX_FILES", "0")
    assert glossary_config.fingerprint("openai", "m", "r") != capped


@pytest.mark.parametrize("metadata", ["null", "[]", "42", '"text"'])
def test_malformed_metadata_is_stale_instead_of_crashing(tmp_path, metadata):
    out = tmp_path / "slice.jsonl"
    out.write_text("old")
    Path(str(out) + ".meta").write_text(metadata)
    assert not glossary_config.matches(str(out), "expected")


def test_batch_reads_confined_and_paginated(tmp_path):
    (tmp_path / "a.cs").write_text("one\ntwo\nthree\n")
    page = read_source(tmp_path, {"a.cs"}, "a.cs", 2, 1)
    assert page.startswith("2: two\n") and "start_line=3, start_column=1" in page
    with pytest.raises(ValueError):
        read_source(tmp_path, {"a.cs"}, "../secret")
    (tmp_path / "link").symlink_to(tmp_path.parent)
    with pytest.raises(ValueError):
        read_source(tmp_path, {"link/secret"}, "link/secret")


def test_source_swap_between_check_and_open_cannot_follow_symlink(tmp_path, monkeypatch):
    import glossary_source

    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "a.cs").write_text("safe")
    secret = tmp_path / "outside"
    secret.write_text("must not read")
    checked = glossary_source.source_path

    def swap(root, path):
        target = checked(root, path)
        target.unlink()
        target.symlink_to(secret)
        return target

    monkeypatch.setattr(glossary_source, "source_path", swap)
    with pytest.raises((ValueError, OSError)):
        read_source(repo, {"a.cs"}, "a.cs")


def test_worker_reloads_python_selection_after_slice_lock(tmp_path):
    import os

    selected = tmp_path / "selected-python"
    selected.write_text("#!/bin/sh\nprintf '%s\\n' \"$AGENT_SDK\" \"$@\"\n")
    selected.chmod(0o700)
    config = tmp_path / "project.env"
    config.write_text(f"AGENT_SDK=openai\nMODEL=new\nREGION=r\nGLOSSARY_PYTHON={selected}\n")
    worker = Path(__file__).resolve().parents[1] / "glossary_worker.sh"
    result = subprocess.run(
        ["bash", str(worker), "--model", "stale", "--region", "r"],
        env={**os.environ, "AGENT_SDK": "claude", "GLOSSARY_PYTHON": "/nonexistent/python",
             "GLOSSARY_CONFIG_FILE": str(config)}, capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines()[:3] == ["openai", "-m", "glossary_gen"]


def test_git_refresh_retries_diff_since_last_success(tmp_path, monkeypatch):
    import glossary

    repo = tmp_path / "repo"
    repo.mkdir()

    def git(*args):
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                              text=True, check=True).stdout.strip()

    git("init", "-q")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "user.name", "Fixture")
    source = repo / "a.cs"
    source.write_text("int previous;\n")
    git("add", ".")
    git("commit", "-qm", "initial")
    old = git("rev-parse", "HEAD")
    config = tmp_path / "project.env"
    config.write_text("AGENT_SDK=openai\nMODEL=m\nREGION=r\n")
    monkeypatch.setenv("GLOSSARY_CONFIG_FILE", str(config))
    out = tmp_path / "slice.jsonl"
    args = ["--project", "p", "--repo-root", str(repo), "--out", str(out),
            "--model", "m", "--region", "r"]
    monkeypatch.setattr(glossary_build, "build", lambda *a, **k: [
        glossary.Entry("power", "symbol", "previous", "a.cs", 1, "high")])
    assert glossary_gen.main(args + ["--full"]) == 0
    source.write_text("int current;\n")
    git("add", ".")
    git("commit", "-qm", "update")
    new = git("rev-parse", "HEAD")

    def fail(*args, **kwargs):
        raise subprocess.SubprocessError("fixture transient failure")

    monkeypatch.setattr(glossary_build, "build", fail)
    glossary_gen.main(args + ["--old", old, "--new", new])
    assert glossary.read_entries(str(out))[0].value == "previous"
    called = []

    def recover(files, **kwargs):
        called.extend(files)
        return [glossary.Entry("power", "symbol", "current", "a.cs", 1, "high")]

    monkeypatch.setattr(glossary_build, "build", recover)
    # The next fetch sees no new commit. It still owes the previous failed diff.
    assert glossary_gen.main(args + ["--old", new, "--new", new]) == 0
    assert called == ["a.cs"]
    assert glossary.read_entries(str(out))[0].value == "current"


@pytest.mark.parametrize("git_residue", [False, True])
def test_local_refresh_retries_failed_change_list(tmp_path, monkeypatch, git_residue):
    import glossary

    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "a.cs").write_text("int previous;\n")
    if git_residue:
        for args in (["init", "-q"], ["config", "user.email", "fixture@example.invalid"],
                     ["config", "user.name", "Fixture"], ["add", "."], ["commit", "-qm", "old git source"]):
            subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)
    config = tmp_path / "project.env"
    config.write_text("AGENT_SDK=openai\nMODEL=m\nREGION=r\n")
    monkeypatch.setenv("GLOSSARY_CONFIG_FILE", str(config))
    out = tmp_path / "slice.jsonl"
    args = ["--project", "p", "--repo-root", str(repo), "--out", str(out),
            "--model", "m", "--region", "r"]
    monkeypatch.setattr(glossary_build, "build", lambda *a, **k: [
        glossary.Entry("power", "symbol", "previous", "a.cs", 1, "high")])
    assert glossary_gen.main(args + ["--full"]) == 0
    (repo / "a.cs").write_text("int current;\n")
    changed = tmp_path / "changed"
    changed.write_text("a.cs\n")

    def fail(*args, **kwargs):
        raise subprocess.SubprocessError("fixture failure")

    monkeypatch.setattr(glossary_build, "build", fail)
    glossary_gen.main(args + ["--changed-list", str(changed)])
    assert Path(str(out) + ".pending").exists()
    changed.write_text("")  # the next push has no additional changes to a.cs
    seen = []

    def recover(files, **kwargs):
        seen.extend(files)
        return [glossary.Entry("power", "symbol", "current", "a.cs", 1, "high")]

    monkeypatch.setattr(glossary_build, "build", recover)
    assert glossary_gen.main(args + ["--changed-list", str(changed)]) == 0
    assert seen == ["a.cs"]
    assert glossary.read_entries(str(out))[0].value == "current"


def test_incremental_empty_result_with_deletions_preserves_old_slice(tmp_path, monkeypatch):
    import glossary

    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "a.cs").write_text("int still_here;\n")
    out = tmp_path / "slice.jsonl"
    glossary.write_entries(str(out), [
        glossary.Entry("power", "symbol", "still_here", "a.cs", 1, "high"),
        glossary.Entry("gone", "symbol", "gone", "removed.cs", 1, "high"),
    ])
    previous = out.read_bytes()
    changed = tmp_path / "changed"
    changed.write_text("a.cs\n")
    deleted = tmp_path / "deleted"
    deleted.write_text("removed.cs\n")
    monkeypatch.setattr(glossary_build, "build", lambda *args, **kwargs: [])
    result = glossary_gen.main([
        "--project", "p", "--repo-root", str(repo), "--out", str(out), "--model", "m",
        "--region", "r", "--changed-list", str(changed), "--deleted-list", str(deleted), "--strict",
    ])
    assert result == 2
    assert out.read_bytes() == previous
def test_openai_batches_leave_turn_budget_for_reads_and_pagination(tmp_path, monkeypatch):
    import openai_glossary

    files = [f"source-{i}.cs" for i in range(301)]
    for path in files:
        (tmp_path / path).write_text("int power;\n")
    seen = []

    def run_batch(prompt, *, files, **kwargs):
        # One read per file already exhausts a 120-turn run with legacy
        # 300-file batches. Reserve extra rounds for pagination and output.
        assert len(files) * 3 + 1 <= 120
        seen.extend(files)
        return ""

    monkeypatch.setattr(openai_glossary, "run_batch", run_batch)
    glossary_build.build(files, project="demo", cwd=str(tmp_path),
                         model="global.openai.gpt-6-astra", region="ap-northeast-1",
                         sdk="openai")
    assert sorted(seen) == sorted(files)


def test_openai_large_files_are_batched_by_page_budget(tmp_path, monkeypatch):
    import openai_glossary

    files = [f"source-{i}.cs" for i in range(20)]
    for path in files:
        (tmp_path / path).write_text("int power;\n" * 2000)  # ten default pages per file
    seen = []

    def run_batch(prompt, *, files, **kwargs):
        # Extra turns are headroom for a large single file, not larger batches.
        assert len(files) * 10 <= 59
        seen.extend(files)
        return ""

    monkeypatch.setattr(openai_glossary, "run_batch", run_batch)
    glossary_build.build(files, project="demo", cwd=str(tmp_path), sdk="openai",
                         model="m", region="r")
    assert sorted(seen) == sorted(files)

def test_sdk_switch_with_empty_diff_and_failed_rebuild(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "a.cs").write_text("int power; // 战力\n")
    out = tmp_path / "glossary" / "repo.jsonl"
    config = tmp_path / "project.env"
    monkeypatch.setenv("GLOSSARY_CONFIG_FILE", str(config))
    row = json.dumps({"concept_id": "power", "kind": "symbol", "value": "power",
                      "source": "a.cs", "line": 1, "confidence": "high"})
    selected = []

    def build(files, **kwargs):
        selected.append(kwargs.get("sdk", "claude"))
        return glossary_build.extract_entries(row)

    monkeypatch.setattr(glossary_build, "build", build)
    args = ["--project", "demo", "--repo-root", str(repo), "--out", str(out),
            "--model", "old", "--region", "r", "--changed-list", str(tmp_path / "empty")]
    config.write_text("AGENT_SDK=claude\nMODEL=anthropic.test\nREGION=r\n")
    assert glossary_gen.main(args) == 0
    config.write_text("AGENT_SDK=openai\nMODEL=openai.test\nREGION=r\n")
    assert glossary_gen.main(args) == 0
    assert selected == ["claude", "openai"]
    assert glossary_gen.main(args) == 0  # same fingerprint + empty diff = no model call
    assert len(selected) == 2
    original = out.read_bytes()
    config.write_text("AGENT_SDK=claude\nMODEL=anthropic.other\nREGION=r\n")

    def fail(*args, **kwargs):
        raise subprocess.SubprocessError("fixture failure")

    monkeypatch.setattr(glossary_build, "build", fail)
    assert glossary_gen.main(args) == 2
    assert out.read_bytes() == original
    assert not glossary_config.matches(str(out), glossary_config.fingerprint("claude", "anthropic.other", "r"))


def test_old_worker_cannot_publish_after_selection_changed(tmp_path):
    config = tmp_path / "project.env"
    config.write_bytes(b"old")
    before = config.read_bytes()
    config.write_bytes(b"new")
    with pytest.raises(RuntimeError):
        with glossary_config.publish_guard(str(config), before):
            pytest.fail("stale worker acquired publication permission")


def test_metadata_write_failure_preserves_previous_data(tmp_path, monkeypatch):
    out = tmp_path / "slice.jsonl"
    out.write_text("previous\n")

    def fail(*args, **kwargs):
        raise OSError("fixture disk full")

    monkeypatch.setattr(glossary_config, "stamp", fail)
    with pytest.raises(OSError):
        glossary_gen._write_atomic(str(out), [], fingerprint="new")
    assert out.read_text() == "previous\n"
