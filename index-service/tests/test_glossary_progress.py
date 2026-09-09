"""A per-build cap must not acknowledge files that were never rebuilt."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import glossary  # noqa: E402
import glossary_build  # noqa: E402
import glossary_config  # noqa: E402
import glossary_gen  # noqa: E402


@pytest.mark.parametrize("kind", ["git", "local"])
@pytest.mark.parametrize("empty_output", ["[]", "", "not JSONL"])
def test_explicit_empty_batch_advances_capped_progress(tmp_path, monkeypatch, kind, empty_output):
    import openai_glossary

    repo = tmp_path / "repo"
    repo.mkdir()

    def git(*args):
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                              text=True, check=True).stdout.strip()

    for name, text in [("a.ref", "oldTerm"), ("z.cs", "oldValue")]:
        (repo / name).write_text(text)
    if kind == "git":
        git("init", "-q")
        git("config", "user.email", "fixture@example.invalid")
        git("config", "user.name", "Fixture")
        git("add", ".")
        git("commit", "-qm", "old")
    old = git("rev-parse", "HEAD") if kind == "git" else None
    config = tmp_path / "project.env"
    config.write_text("AGENT_SDK=openai\nMODEL=m\nREGION=r\nGLOSSARY_MAX_FILES=1\n")
    monkeypatch.setenv("GLOSSARY_CONFIG_FILE", str(config))
    out = tmp_path / "slice.jsonl"
    out.write_text("\n".join(json.dumps({
        "concept_id": concept, "kind": "symbol", "value": value,
        "source": source, "line": 1, "confidence": "high",
    }) for concept, value, source in [("term", "oldTerm", "a.ref"), ("code", "oldValue", "z.cs")]) + "\n")
    glossary_config.stamp(str(out), glossary_config.fingerprint("openai", "m", "r", max_files=1),
                          source_revision=old)
    previous = out.read_bytes()
    (repo / "a.ref").write_text("This file contains only repetitive sample text.")
    (repo / "z.cs").write_text("int newValue;\n")
    if kind == "git":
        git("add", ".")
        git("commit", "-qm", "new")
    new = git("rev-parse", "HEAD") if kind == "git" else None
    changed = tmp_path / "changed"
    changed.write_text("a.ref\nz.cs\n")
    options = ["--old", old, "--new", new] if kind == "git" else ["--changed-list", str(changed)]
    args = ["--project", "p", "--repo-root", str(repo), "--out", str(out),
            "--model", "m", "--region", "r", "--source", kind, "--strict"]
    calls = []

    def run_batch(prompt, *, files, **kwargs):
        calls.append(files)
        if files == ["a.ref"]:
            return empty_output
        return json.dumps({"concept_id": "code", "kind": "symbol", "value": "newValue",
                           "source": "z.cs", "line": 1, "confidence": "high"})

    monkeypatch.setattr(openai_glossary, "run_batch", run_batch)
    rc = glossary_gen.main(args + options)
    if empty_output != "[]":
        assert rc == 2
        assert out.read_bytes() == previous
        assert glossary_config.metadata(str(out))["source_revision"] == old
        return
    assert rc == 0
    assert {e.source for e in glossary.read_entries(str(out))} == {"z.cs"}
    changed.write_text("")
    options = ["--old", new, "--new", new] if kind == "git" else ["--changed-list", str(changed)]
    assert glossary_gen.main(args + options) == 0
    assert calls == [["a.ref"], ["z.cs"]]
    assert [e.value for e in glossary.read_entries(str(out))] == ["newValue"]
    assert glossary_config.metadata(str(out))["source_revision"] == new
    assert not Path(str(out) + ".pending").exists()


def test_explicit_local_full_build_ignores_leftover_git_directory(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / ".git").mkdir()  # not a usable Git repo; the manifest declares local
    (repo / "a.cs").write_text("current_value")
    config = tmp_path / "project.env"
    config.write_text("AGENT_SDK=openai\nMODEL=m\nREGION=r\n")
    monkeypatch.setenv("GLOSSARY_CONFIG_FILE", str(config))
    out = tmp_path / "slice.jsonl"
    monkeypatch.setattr(glossary_build, "build", lambda *args, **kwargs: [
        glossary.Entry("power", "symbol", "current_value", "a.cs", 1, "high")])
    assert glossary_gen.main([
        "--project", "p", "--repo-root", str(repo), "--out", str(out), "--model", "m",
        "--region", "r", "--full", "--source", "local",
    ]) == 0
    assert glossary_config.metadata(str(out))["source_revision"] is None


@pytest.mark.parametrize("kind", ["git", "local"])
@pytest.mark.parametrize("next_change", [False, True])
@pytest.mark.parametrize("retry_failure", [False, True])
def test_capped_incremental_preserves_unprocessed_progress(
    tmp_path, monkeypatch, kind, next_change, retry_failure,
):
    repo = tmp_path / "repo"
    repo.mkdir()

    def git(*args):
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                              text=True, check=True).stdout.strip()

    if kind == "git":
        git("init", "-q")
        git("config", "user.email", "fixture@example.invalid")
        git("config", "user.name", "Fixture")
    config = tmp_path / "project.env"
    config.write_text("AGENT_SDK=openai\nMODEL=m\nREGION=r\nGLOSSARY_MAX_FILES=1\n")
    monkeypatch.setenv("GLOSSARY_CONFIG_FILE", str(config))
    out = tmp_path / "slice.jsonl"
    args = ["--project", "p", "--repo-root", str(repo), "--out", str(out), "--model", "m", "--region", "r"]
    changed = tmp_path / "changed"
    calls = []
    revision = ""

    def build(files, **kwargs):
        assert len(files) <= 1
        calls.append(list(files))
        return [glossary.Entry(Path(path).stem, "symbol", (repo / path).read_text().strip(),
                               path, 1, "high") for path in files]

    monkeypatch.setattr(glossary_build, "build", build)

    def update(values, *, full=False):
        nonlocal revision
        for path, value in values.items():
            (repo / path).write_text(value)
        options = []
        if kind == "git":
            if values:
                git("add", ".")
                git("commit", "-qm", "fixture")
            current = git("rev-parse", "HEAD")
            options = ["--old", revision, "--new", current] if revision else []
            revision = current
        else:
            changed.write_text("\n".join(values))
            options = ["--changed-list", str(changed)]
        return glossary_gen.main(args + (["--full"] if full else options))

    assert update({"a.cs": "a_old"}, full=True) == 0
    assert update({"b.cs": "b_old"}) == 0
    assert update({"a.cs": "a_new", "b.cs": "b_new"}) == 0
    assert calls[-1] == ["a.cs"]
    if kind == "git":
        assert glossary_config.metadata(str(out))["source_revision"] != revision
    else:
        assert json.loads(Path(str(out) + ".pending").read_text())["changed"] == ["b.cs"]

    if retry_failure:
        previous = out.read_bytes()
        provenance = Path(str(out) + ".meta").read_bytes()

        def fail(*args, **kwargs):
            raise subprocess.SubprocessError("fixture temporary failure")

        monkeypatch.setattr(glossary_build, "build", fail)
        assert update({}) == 0
        assert out.read_bytes() == previous
        assert Path(str(out) + ".meta").read_bytes() == provenance
        monkeypatch.setattr(glossary_build, "build", build)

    # A fresh change must be combined with the old tail, not replace it. Existing
    # pending work gets priority, so repeated a.cs changes cannot starve b.cs.
    assert update({"a.cs": "a_newest"} if next_change else {}) == 0
    assert calls[-1] == ["b.cs"]
    if next_change:
        assert update({}) == 0
        assert calls[-1] == ["a.cs"]
    values = {entry.source: entry.value for entry in glossary.read_entries(str(out))}
    assert values == {"a.cs": "a_newest" if next_change else "a_new", "b.cs": "b_new"}
    count = len(calls)
    assert update({}) == 0
    assert len(calls) == count
    if kind == "git":
        assert glossary_config.metadata(str(out))["source_revision"] == revision
    else:
        assert not Path(str(out) + ".pending").exists()
