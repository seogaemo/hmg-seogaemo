#!/usr/bin/env python3
"""Host-side tests for tools/beta-bump.py: version arithmetic and the git flow against a local origin."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/beta-bump.py"
spec = importlib.util.spec_from_file_location("beta_bump", SCRIPT)
bump = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bump)

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid", "GIT_CONFIG_GLOBAL": "/dev/null"}


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, env=ENV, check=True, capture_output=True, text=True).stdout.strip()


def commit(cwd, name, text, message):
    (Path(cwd) / name).write_text(text)
    git(cwd, "add", name)
    git(cwd, "commit", "-m", message)


def run_tool(clone, kind, tag):
    result = subprocess.run(["python3", str(SCRIPT), kind, "--tag", tag], cwd=clone, env=ENV, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def show(origin, path, ref="beta"):
    result = subprocess.run(["git", "show", f"{ref}:{path}"], cwd=origin, env=ENV, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def test_arithmetic():
    assert bump.after_final("0.1.48", "0.1.48", None) == ("0.1.49", "beta.1")
    assert bump.after_final("0.1.48", "0.1.47", "beta.3") == ("0.1.49", "beta.1")
    assert bump.after_final("0.1.49", "0.1.49", "beta.3") == ("0.1.50", "beta.1")
    assert bump.after_final("0.1.49", "0.2.0", "beta.4") == ("0.2.0", "beta.4")
    assert bump.after_final("0.1.49", "0.2.0", None) == ("0.2.0", "beta.1")
    assert bump.after_final("0.1.9", "0.1.9", None) == ("0.1.10", "beta.1")
    assert bump.after_beta("0.1.49", 2, "0.1.49", "beta.2") == "beta.3"
    assert bump.after_beta("0.1.49", 2, "0.1.49", "beta.3") is None
    assert bump.after_beta("0.1.49", 2, "0.1.50", "beta.2") is None
    assert bump.after_beta("0.1.49", 2, "0.1.49", None) is None
    try:
        bump.after_beta("0.1.49", 99, "0.1.49", "beta.99")
    except bump.Failure:
        pass
    else:
        raise AssertionError("beta.100 must be refused")


class Fixture:
    """origin (bare) with main at 0.1.48 tagged v0.1.48, plus a working clone."""

    def __init__(self, temp):
        self.origin = Path(temp) / "origin.git"
        self.clone = Path(temp) / "clone"
        git(temp, "init", "--bare", "-b", "main", str(self.origin))
        git(temp, "clone", str(self.origin), str(self.clone))
        commit(self.clone, "VERSION", "0.1.48\n", "release: 0.1.48")
        commit(self.clone, "app.txt", "one\n", "feature one")
        git(self.clone, "tag", "v0.1.48")
        git(self.clone, "push", "origin", "main", "--tags")

    def release_final(self, version, change=None):
        git(self.clone, "checkout", "main")
        if change:
            commit(self.clone, *change)
        commit(self.clone, "VERSION", version + "\n", f"release: {version}")
        git(self.clone, "tag", f"v{version}")
        git(self.clone, "push", "origin", "main", f"v{version}")


def test_create_and_cycle():
    with tempfile.TemporaryDirectory() as temp:
        fx = Fixture(temp)
        # first run creates beta from the released commit
        assert run_tool(fx.clone, "final", "v0.1.48")[0] == 0
        assert show(fx.origin, "VERSION") == "0.1.49" and show(fx.origin, "PRERELEASE") == "beta.1"
        assert git(fx.origin, "log", "-1", "--format=%s", "beta") == "beta: 0.1.49-beta.1"
        # idempotent
        before = git(fx.origin, "rev-parse", "beta")
        code, out = run_tool(fx.clone, "final", "v0.1.48")
        assert code == 0 and "skipped" in out and git(fx.origin, "rev-parse", "beta") == before, out
        # a feature merged into beta, beta.1 tagged and published
        git(fx.clone, "fetch", "origin")
        git(fx.clone, "checkout", "-B", "beta", "origin/beta")
        commit(fx.clone, "feat.txt", "x\n", "feature two")
        git(fx.clone, "tag", "v0.1.49-beta.1")
        git(fx.clone, "push", "origin", "beta", "v0.1.49-beta.1")
        assert run_tool(fx.clone, "beta", "v0.1.49-beta.1")[0] == 0
        assert show(fx.origin, "PRERELEASE") == "beta.2" and show(fx.origin, "VERSION") == "0.1.49"
        assert git(fx.origin, "log", "-1", "--format=%s", "beta") == "beta: 0.1.49-beta.2"
        # re-run and stale tag do nothing
        before = git(fx.origin, "rev-parse", "beta")
        assert run_tool(fx.clone, "beta", "v0.1.49-beta.1")[0] == 0
        assert git(fx.origin, "rev-parse", "beta") == before
        # final 0.1.49 released from main (features come from branches, not beta): beta merges it
        fx.release_final("0.1.49", ("main.txt", "m\n", "main only feature"))
        assert run_tool(fx.clone, "final", "v0.1.49")[0] == 0
        assert show(fx.origin, "VERSION") == "0.1.50" and show(fx.origin, "PRERELEASE") == "beta.1"
        assert show(fx.origin, "main.txt") == "m" and show(fx.origin, "feat.txt") == "x"
        subjects = git(fx.origin, "log", "-3", "--first-parent", "--format=%s", "beta").splitlines()
        assert subjects == ["beta: 0.1.50-beta.1", "Merge v0.1.49 into beta", "beta: 0.1.49-beta.2"], subjects
        assert show(fx.origin, "PRERELEASE", "main") is None


def test_version_conflict_and_ahead_beta():
    with tempfile.TemporaryDirectory() as temp:
        fx = Fixture(temp)
        assert run_tool(fx.clone, "final", "v0.1.48")[0] == 0
        # owner moves beta to 0.2.0 by hand; main releases 0.1.49 (VERSION conflicts)
        git(fx.clone, "fetch", "origin")
        git(fx.clone, "checkout", "-B", "beta", "origin/beta")
        commit(fx.clone, "VERSION", "0.2.0\n", "beta: 0.2.0")
        git(fx.clone, "push", "origin", "beta")
        fx.release_final("0.1.49")
        assert run_tool(fx.clone, "final", "v0.1.49")[0] == 0
        assert show(fx.origin, "VERSION") == "0.2.0" and show(fx.origin, "PRERELEASE") == "beta.1"


def test_conflict_pushes_nothing():
    with tempfile.TemporaryDirectory() as temp:
        fx = Fixture(temp)
        assert run_tool(fx.clone, "final", "v0.1.48")[0] == 0
        git(fx.clone, "fetch", "origin")
        git(fx.clone, "checkout", "-B", "beta", "origin/beta")
        commit(fx.clone, "app.txt", "beta side\n", "beta edits app")
        git(fx.clone, "push", "origin", "beta")
        fx.release_final("0.1.49", ("app.txt", "main side\n", "main edits app"))
        before = git(fx.origin, "rev-parse", "beta")
        code, out = run_tool(fx.clone, "final", "v0.1.49")
        assert code == 1 and "app.txt" in out and "Nothing was pushed" in out, out
        assert git(fx.origin, "rev-parse", "beta") == before
        assert git(fx.clone, "status", "--porcelain") == ""


JAR = "modules/wireless-carplay-and-aa/files/wireless-mod.jar"
MAKEFILE = "module-build:\n\tcat src.txt > " + JAR + "\n"


def build_output_fixture(temp, makefile=MAKEFILE):
    """beta and main both change src.txt (merges cleanly) and the jar built from it (conflicts)."""
    fx = Fixture(temp)
    git(fx.clone, "checkout", "main")
    (fx.clone / JAR).parent.mkdir(parents=True)
    commit(fx.clone, ".gitattributes", "*.jar binary\n", "jars are binary, as on the real branch")
    commit(fx.clone, "Makefile", makefile, "build")
    commit(fx.clone, "src.txt", "a\nb\nc\n", "source")
    commit(fx.clone, JAR, "a\nb\nc\n", "jar")
    git(fx.clone, "push", "origin", "main")
    git(fx.clone, "checkout", "-B", "beta")
    commit(fx.clone, "src.txt", "a\nb\nbeta\n", "beta source")
    commit(fx.clone, JAR, "a\nb\nbeta\n", "beta jar")
    git(fx.clone, "push", "origin", "beta")
    git(fx.clone, "checkout", "main")
    commit(fx.clone, "src.txt", "main\nb\nc\n", "main source")
    commit(fx.clone, JAR, "main\nb\nc\n", "main jar")
    fx.release_final("0.1.49")
    return fx


def test_build_output_rebuilt():
    with tempfile.TemporaryDirectory() as temp:
        fx = build_output_fixture(temp)
        code, out = run_tool(fx.clone, "final", "v0.1.49")
        assert code == 0, out
        assert show(fx.origin, JAR) == "main\nb\nbeta" == show(fx.origin, "src.txt")
        assert show(fx.origin, "VERSION") == "0.1.50" and show(fx.origin, "PRERELEASE") == "beta.1"


def test_build_output_rebuild_failure_pushes_nothing():
    with tempfile.TemporaryDirectory() as temp:
        fx = build_output_fixture(temp, MAKEFILE + "\techo changed > src.txt\n")
        before = git(fx.origin, "rev-parse", "beta")
        code, out = run_tool(fx.clone, "final", "v0.1.49")
        assert code == 1 and "also changed: src.txt" in out and "Nothing was pushed" in out, out
        assert git(fx.origin, "rev-parse", "beta") == before
        assert git(fx.clone, "status", "--porcelain") == ""


def test_refusals():
    with tempfile.TemporaryDirectory() as temp:
        fx = Fixture(temp)
        assert run_tool(fx.clone, "final", "v0.1.48-beta.1")[0] == 2
        assert run_tool(fx.clone, "beta", "v0.1.48")[0] == 2
        assert run_tool(fx.clone, "final", "v9.9.9")[0] == 1  # unknown tag
        # no beta branch yet: a beta tag is skipped
        git(fx.clone, "tag", "v0.1.49-beta.1")
        code, out = run_tool(fx.clone, "beta", "v0.1.49-beta.1")
        assert code == 0 and "skipped" in out, out


if __name__ == "__main__":
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            function()
    print("ok")
