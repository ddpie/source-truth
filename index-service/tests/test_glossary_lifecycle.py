"""Exercise host glossary wiring with temporary files and systemd stubs only."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

SERVICE = Path(__file__).resolve().parents[1]
ROOT = SERVICE.parent


@pytest.mark.parametrize("cap", ["400", "0", ""])
def test_activation_publishes_cap_and_repo_membership(tmp_path, cap):
    text = (SERVICE / "activate_project.sh").read_text()
    publication = text[text.index('GLOSSARY_SUBDIRS="$(printf'):text.index("# Capture the project's PREVIOUS")]
    project_env = tmp_path / "project.env"
    manifest = {"projectId": "p", "port": 8080,
                "repos": [{"subdir": "one", "source": "local"}, {"subdir": "two", "source": "local"}]}
    result = subprocess.run(
        ["bash", "-eu", "-c", 'systemctl() { :; }\n' + publication],
        env={**os.environ, "PROJECT_ENV": str(project_env), "MANIFEST": str(tmp_path / "absent.json"),
             "RENDER_MANIFEST": str(ROOT / "scripts/lib/render_manifest.py"),
             "REPO_MANIFEST_JSON": json.dumps(manifest), "PROJECT_ID": "p",
             "MODEL": "m", "REGION": "r", "AGENT_SDK": "openai", "GLOSSARY_ENABLED": "true",
             "GLOSSARY_PYTHON": sys.executable, "GLOSSARY_MAX_FILES": cap},
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    values = dict(line.split("=", 1) for line in project_env.read_text().splitlines())
    assert values["GLOSSARY_MAX_FILES"] == (cap or "0")
    assert values["GLOSSARY_SUBDIRS"] == "one,two"
    assert values["AGENT_SDK"] == "openai"


def test_each_local_push_can_queue_behind_an_active_worker(tmp_path):
    text = (SERVICE / "reindex_local_repo.sh").read_text()
    function = text[text.index("refresh_glossary() {"):text.index("\n# do_build:")]
    # Both env sources are trusted host files. Substitute fixture envs; the rest
    # of the function (including unit naming, copies and argv) executes unchanged.
    function = function.replace(". /etc/index-service.env", ". /dev/null")
    function = function.replace('. "/etc/index-project-${PID}.env"', ". /dev/null")
    changed = tmp_path / "changed"
    changed.write_text("a.cs\n")
    deleted = tmp_path / "deleted"
    deleted.write_text("")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "systemd-run"
    stub.write_text(
        "#!/bin/sh\n"
        "for arg do\n"
        " case \"$arg\" in --unit=*)\n"
        "  if grep -Fxq -- \"$arg\" \"$UNIT_LOG\"; then exit 1; fi\n"
        "  printf '%s\\n' \"$arg\" >> \"$UNIT_LOG\";;\n"
        " esac\n"
        "done\n"
    )
    stub.chmod(0o700)
    unit_log = tmp_path / "units"
    unit_log.touch()
    result = subprocess.run(
        ["bash", "-eu", "-c", "systemctl() { :; }\naws() { return 0; }\n" + function
         + "\nrefresh_glossary incremental\nrefresh_glossary incremental\n"],
        env={**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
             "UNIT_LOG": str(unit_log), "GLOSSARY_ROOT": str(tmp_path / "glossary"), "PID": "p",
             "SUBDIR": "repo", "WS": str(tmp_path), "APP": str(SERVICE),
             "MODEL": "m", "REGION": "r", "AGENT_SDK": "openai",
             "CHANGED_LIST": str(changed), "DELETED_LIST": str(deleted)},
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    assert "launch failed" not in result.stdout
    assert len(set(unit_log.read_text().splitlines())) == 2
