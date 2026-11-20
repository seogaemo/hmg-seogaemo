#!/usr/bin/env python3
"""Boot map gating, deferred retries and finite OTA health with private fixtures."""
import os
import signal
import shutil
from pathlib import Path
import subprocess
import sys
import time

from testlib import SHELL, car_env, copy_shell_script, run_tests

ROOT = Path(__file__).resolve().parents[1]


def script(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


def reconcile_fixture(folder):
    base, state, fake = folder / "package", folder / "state", folder / "fake"
    for path in (base / "svc", base / "bin", base / "hookpoints.required",
                 state / "desired", fake):
        path.mkdir(parents=True)
    copy_shell_script(ROOT / "nemesis/package/svc/reconcile.sh", base / "svc/reconcile.sh")
    # mksh has a sleep builtin, which precedes PATH. Override only the private
    # fixture copy so its retry clock remains controlled by the fake executable.
    fixture = base / "svc/reconcile.sh"
    fixture.write_text(fixture.read_text().replace(
        "umask 077", f'umask 077\nsleep() {{ "{fake}/sleep" "$@"; }}', 1))
    (base / "modules.list").write_text("mapped\ndependent\nindependent\n")
    (base / "modules.graph").write_text(
        "mapped\tdepends=\texcludes=\n"
        "dependent\tdepends=mapped\texcludes=\n"
        "independent\tdepends=\texcludes=\n")
    (base / "hookpoints.required/mapped").write_text("example.point\n")
    for name in ("mapped", "dependent", "independent"):
        (state / "desired" / name).write_text("on\n")
    script(fake / "getprop", "echo 1\n")
    script(fake / "pm", '[ "$2" = android ] || [ ! -f "$SG_DATA_ROOT/apk-missing" ] || exit 0; echo package:fixture\n')
    script(fake / "sleep", '''
[ "$1" = 30 ] || { /bin/sleep 0.01; exit 0; }
[ "$HMG_SEOGAEMO_UPDATE_HEALTH" != 1 ] || exit 98
echo retry >> "$SG_DATA_ROOT/calls"
while [ ! -f "$SG_DATA_ROOT/release-retry" ]; do /bin/sleep 0.01; done
case "$RETRY_MODE" in
    verified) : > "$SG_DATA_ROOT/verified";;
    paused) mkdir -p "$SG_DATA_ROOT/stock"; : > "$SG_DATA_ROOT/stock/paused";;
    missing) : > "$SG_DATA_ROOT/apk-missing";;
    off) echo off > "$SG_DATA_ROOT/desired/mapped"; echo off > "$SG_DATA_ROOT/desired/dependent";;
    selection) ln -s "$NEXT_PACKAGE" "$SG_DATA_ROOT/update/current";;
    busy) : > "$SG_DATA_ROOT/busy-cleared";;
    *) echo unexpected-retry >&2; exit 99;;
esac
''')
    script(base / "bin/hmg-seogaemo-root", '''
echo "$1 $2" >> "$SG_DATA_ROOT/calls"
if [ "$1" = map ]; then
    if [ "$2" = verify ]; then
        case "$VERIFY_MODE" in
            success) : > "$SG_DATA_ROOT/verified";;
            pause) mkdir -p "$SG_DATA_ROOT/stock"; : > "$SG_DATA_ROOT/stock/paused"; : > "$SG_DATA_ROOT/verified";;
            fail) echo state=failed; exit 1;;
            malformed) echo state=off; exit 0;;
        esac
    fi
    if [ -f "$SG_DATA_ROOT/verified" ]; then echo state=on; else echo state=off; fi
    exit 0
fi
if [ "$2" = apply ]; then
    if [ "$1" = mapped ] || [ "$1" = dependent ]; then
        [ -f "$SG_DATA_ROOT/verified" ] || exit 77
    fi
    [ "$APPLY_FAIL" != "$1" ] || exit 1
    if [ "$APPLY_BUSY" = "$1" ] && [ ! -f "$SG_DATA_ROOT/busy-cleared" ]; then
        echo state=failed; echo 'detail=Module operation busy'; exit 1
    fi
fi
echo state=on
''')
    env = dict(car_env(), PATH=str(fake) + ":" + car_env()["PATH"],
               SG_DATA_ROOT=str(state), VERIFY_MODE="success", RETRY_MODE="unexpected", APPLY_FAIL="", APPLY_BUSY="")
    (state / "release-retry").touch()
    return base, state, env


def invoke(base, env):
    return subprocess.run([SHELL, str(base / "svc/reconcile.sh")], env=env,
                          capture_output=True, text=True, timeout=8)


def wait_for(predicate):
    deadline = time.monotonic() + 8
    while not predicate():
        assert time.monotonic() < deadline, "timed out waiting for retry worker"
        time.sleep(0.01)


def test_reconcile(folder):
    for mode in ("success", "already", "retry", "paused", "missing", "off",
                 "health", "malformed", "independent", "apply-failed", "selection", "alias-selection"):
        base, state, env = reconcile_fixture(folder / mode)
        if mode == "already":
            (state / "verified").touch()
        if mode in ("retry", "paused", "missing", "off", "health", "selection", "alias-selection"):
            env["VERIFY_MODE"] = "fail"
            env["RETRY_MODE"] = "verified" if mode in ("retry", "health") else mode
        if mode in ("health", "malformed"):
            env["HMG_SEOGAEMO_UPDATE_HEALTH"] = "1"
        if mode == "malformed":
            env["VERIFY_MODE"] = "malformed"
            env["RETRY_MODE"] = "paused"
        if mode == "independent":
            (base / "hookpoints.required/mapped").write_text("")
            (state / "verified").touch()
        if mode == "apply-failed":
            env["APPLY_FAIL"] = "independent"
        if mode in ("selection", "alias-selection"):
            target = folder / (mode + "-selected")
            (target / "svc").mkdir(parents=True)
            (state / "update").mkdir()
            script(target / "svc/reconcile.sh", 'echo selected >> "$SG_DATA_ROOT/calls"\n')
            env["NEXT_PACKAGE"] = str(target)
            env["RETRY_MODE"] = "selection"
        launch = base
        if mode == "alias-selection":
            (state / "update/current").symlink_to(base)
            # The retry fixture replaces the pointer just as OTA selection does.
            sleep = Path(env["PATH"].split(":")[0]) / "sleep"
            sleep.write_text(sleep.read_text().replace(
                'selection) ln -s', 'selection) rm -f "$SG_DATA_ROOT/update/current"; ln -s'))
            launch = state / "update/current"
        result = invoke(launch, env)
        assert result.returncode == (1 if mode == "apply-failed" else 0), (mode, result)
        wait_for(lambda: not (state / "reconcile-retry").exists())
        calls = (state / "calls").read_text().splitlines()
        if mode == "independent":
            assert calls == ["mapped apply", "dependent apply", "independent apply"], calls
        elif mode in ("success", "already", "apply-failed"):
            expected = ["map status"] + ([] if mode == "already" else ["map verify"])
            assert calls == expected + ["mapped apply", "dependent apply", "independent apply"], calls
        else:
            assert calls[:3] == ["map status", "map verify", "independent apply"], calls
            if mode in ("retry", "health"):
                assert calls[3:] == ["retry", "map status", "mapped apply", "dependent apply"], calls
            elif mode in ("selection", "alias-selection"):
                assert calls[3:] == ["retry"], calls
            else:
                assert calls[3:] == ["retry"], calls
        if mode != "off":
            assert (state / "desired/mapped").read_text() == "on\n"
            assert (state / "desired/dependent").read_text() == "on\n"

    # An apply refused only because another module held the operation lock is retried, not failed.
    base, state, env = reconcile_fixture(folder / "busy")
    (state / "verified").touch()
    env["APPLY_BUSY"] = "independent"
    env["RETRY_MODE"] = "busy"
    assert invoke(base, env).returncode == 0
    wait_for(lambda: not (state / "reconcile-retry").exists())
    assert (state / "calls").read_text().splitlines() == [
        "map status", "mapped apply", "dependent apply", "independent apply",
        "retry", "independent apply"], (state / "calls").read_text()
    assert "deferred independent: module operation busy" in (state / "reconcile.log").read_text()

    base, state, env = reconcile_fixture(folder / "initial-paused")
    (state / "stock").mkdir()
    (state / "stock/paused").touch()
    assert invoke(base, env).returncode == 0
    assert not (state / "calls").exists()

    base, state, env = reconcile_fixture(folder / "pause-during-verify")
    env["VERIFY_MODE"] = "pause"
    assert invoke(base, env).returncode == 0
    assert (state / "calls").read_text().splitlines() == ["map status", "map verify"]

    # A canonical current symlink to the running payload must not recurse.
    base, state, env = reconcile_fixture(folder / "canonical")
    (state / "update").mkdir()
    (state / "update/current").symlink_to(base)
    assert invoke(state / "update/current", env).returncode == 0
    assert (state / "calls").read_text().count("mapped apply") == 1


def test_android_readiness(folder):
    # NEMESIS invokes the same service after install/update and at startup.
    # Already-on status must never suppress apply's repair/upgrade path.
    for reason in ("boot", "install-update"):
        base, state, env = reconcile_fixture(folder / reason)
        (state / "verified").touch()
        result = subprocess.run([SHELL, str(base / "bin/hmg-seogaemo-root"),
                                 "independent", "status"], env=env,
                                capture_output=True, text=True, check=True)
        assert "state=on" in result.stdout
        (state / "calls").write_text("")
        assert invoke(base, env).returncode == 0
        assert (state / "calls").read_text().splitlines() == [
            "map status", "mapped apply", "dependent apply", "independent apply"]
    for mode in ("slow-boot", "late-pm", "health"):
        base, state, env = reconcile_fixture(folder / mode)
        fake = Path(env["PATH"].split(":")[0])
        script(fake / "getprop", 'if [ -f "$SG_DATA_ROOT/android-ready" ] || [ "$READINESS_MODE" = late-pm ]; then echo 1; else echo 0; fi\n')
        script(fake / "pm", '[ -f "$SG_DATA_ROOT/android-ready" ] && echo package:fixture\n')
        script(fake / "sleep", '''
echo "$1" >> "$SG_DATA_ROOT/waits"
n=$(cat "$SG_DATA_ROOT/wait-count" 2>/dev/null); n=${n:-0}; n=$((n + 1))
echo "$n" > "$SG_DATA_ROOT/wait-count"
[ "$n" -lt 10 ] || : > "$SG_DATA_ROOT/android-ready"
''')
        env["READINESS_MODE"] = mode
        if mode == "health":
            env["HMG_SEOGAEMO_UPDATE_HEALTH"] = "1"
        result = invoke(base, env)
        assert result.returncode == (1 if mode == "health" else 0), result
        waits = (state / "waits").read_text().splitlines()
        assert waits[:6] == ["2", "4", "8", "16", "30", "30"], waits
        if mode == "health":
            assert len(waits) == 6 and not (state / "calls").exists()
        else:
            assert len(waits) == 10
            assert "independent apply" in (state / "calls").read_text()


def test_detached_lifecycle(folder):
    for mode in ("verified", "paused", "stale", "unpublished", "health"):
        base, state, env = reconcile_fixture(folder / mode)
        env.update(VERIFY_MODE="fail", RETRY_MODE="paused" if mode == "paused" else "verified")
        if mode == "health":
            env["HMG_SEOGAEMO_UPDATE_HEALTH"] = "1"
        (state / "release-retry").unlink()
        marker = state / "reconcile-retry/pid"
        if mode in ("stale", "unpublished"):
            marker.parent.mkdir()
        if mode == "stale":
            marker.write_text("2147483647 2147483647\n")
        try:
            started = time.monotonic()
            result = invoke(base, env)
            assert result.returncode == 0, result
            assert time.monotonic() - started < 3, "once service waited for retry"
            wait_for(lambda: "retry" in (state / "calls").read_text().splitlines())
            original = marker.read_text()
            pid = int(original.split()[0])
            os.kill(pid, signal.SIGHUP)
            # Repeated normal starts and OTA health must preserve the worker.
            assert invoke(base, env).returncode == 0
            env["HMG_SEOGAEMO_UPDATE_HEALTH"] = "1"
            assert invoke(base, env).returncode == 0
            assert marker.read_text() == original
            assert (state / "calls").read_text().splitlines().count("retry") == 1
            (state / "release-retry").touch()
            wait_for(lambda: not marker.parent.exists())
            calls = (state / "calls").read_text().splitlines()
            assert calls.count("mapped apply") == (0 if mode == "paused" else 1), calls
            assert calls.count("dependent apply") == (0 if mode == "paused" else 1), calls
        finally:
            (state / "release-retry").touch()
            if marker.exists():
                pid = int(marker.read_text().split()[0])
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass


def test_retry_backoff(folder):
    # A map that never verifies must not keep two JVMs running every 30 seconds
    # until the next boot: waits grow 30, 60, 120, 300 and stop after 8 tries.
    base, state, env = reconcile_fixture(folder)
    fake = Path(env["PATH"].split(":")[0])
    script(fake / "sleep", '''
echo "$1" >> "$SG_DATA_ROOT/waits"
/bin/sleep 0.01
''')
    env["VERIFY_MODE"] = "fail"
    assert invoke(base, env).returncode == 0
    wait_for(lambda: not (state / "reconcile-retry").exists())
    waits = [w for w in (state / "waits").read_text().split() if int(w) >= 30]
    assert waits == ["30", "60", "120"] + ["300"] * 5, waits
    calls = (state / "calls").read_text().splitlines()
    assert calls.count("map verify") == 9, calls
    assert "retries exhausted" in (state / "reconcile.log").read_text()


def test_reverse_restore_material(folder):
    # Interrupted applies can leave only a directory reference, bind or cache
    # journal before the main changes file/desired-on commit is published.
    for marker in ("prop.demo/ready", "file.demo/ready", "line.demo/ready",
                   "bind.demo", "changes", "dex.cache", "dir.demo", "dir-order"):
        base, state, env = reconcile_fixture(folder / marker.replace("/", "-"))
        for name in ("mapped", "dependent", "independent"):
            (state / "desired" / name).write_text("off")
        material = state / "modules/mapped" / marker
        material.parent.mkdir(parents=True)
        material.touch()
        assert invoke(base, env).returncode == 0
        assert (state / "calls").read_text().splitlines() == ["mapped revert"]


def test_payload_replacement(folder):
    base, state, env = reconcile_fixture(folder)
    env.update(VERIFY_MODE="fail", RETRY_MODE="verified")
    (state / "release-retry").unlink()
    (state / "update").mkdir()
    current = state / "update/current"
    current.symlink_to(base)
    marker = state / "reconcile-retry/pid"
    replacement = folder / "replacement"
    shutil.copytree(base, replacement)
    pids = []
    try:
        assert invoke(current, env).returncode == 0
        wait_for(lambda: (state / "calls").read_text().splitlines().count("retry") == 1)
        pids.append(int(marker.read_text().split()[0]))
        current.unlink()
        current.symlink_to(replacement)
        assert invoke(current, env).returncode == 0
        wait_for(lambda: (state / "calls").read_text().splitlines().count("retry") == 2)
        pids.append(int(marker.read_text().split()[0]))
        assert pids[0] != pids[1]
        assert (marker.parent / "base").read_text().strip() == str(replacement.resolve())
        (state / "release-retry").touch()
        wait_for(lambda: not marker.parent.exists())
        calls = (state / "calls").read_text().splitlines()
        assert calls.count("mapped apply") == 1, calls
        assert calls.count("dependent apply") == 1, calls
    finally:
        (state / "release-retry").touch()
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


def test_pending_install(folder):
    def setup(name):
        base, state, env = reconcile_fixture(folder / name)
        fake = Path(env["PATH"].split(":")[0])
        job = state / "app-install"
        (job / "payload/app").mkdir(parents=True)
        (job / "payload/bin").mkdir()
        (job / "payload/app/hmg-seogaemo.apk").write_bytes(b"retained-apk")
        copy_shell_script(ROOT / "nemesis/package/bin/install-apk.sh", job / "payload/bin/install-apk.sh")
        copy_shell_script(ROOT / "nemesis/package/svc/install-pending.sh", base / "svc/install-pending.sh")
        worker = base / "svc/install-pending.sh"
        worker.write_text(worker.read_text().replace(
            "umask 077", f'umask 077\nsleep() {{ "{fake}/sleep" "$@"; }}', 1).replace(
                '/proc/$holder/cmdline', str(state / 'proc') + '/$holder/cmdline'))
        (job / "pending").write_text("request-1\n")
        (state / "boot-id").write_text("boot-one\n")
        (state / "boot-property").write_text("1\n")
        script(fake / "getprop", 'cat "$SG_DATA_ROOT/boot-property"\n')
        script(fake / "setprop", 'echo "$2" > "$SG_DATA_ROOT/boot-property"\n')
        script(fake / "sleep", '''
# install-apk.sh's pm watchdog polls once a second through this PATH sleep when
# the shell has no builtin; those ticks are not worker waits.
[ "$1" != 1 ] || { /bin/sleep 0.01; exit 0; }
echo "$1" >> "$SG_DATA_ROOT/waits"
if [ "$PENDING_MODE" = slow ]; then
    n=$(cat "$SG_DATA_ROOT/ready-count" 2>/dev/null); [ -n "$n" ] || n=0; n=$((n + 1))
    echo "$n" > "$SG_DATA_ROOT/ready-count"
    [ "$n" -lt 10 ] || { echo 1 > "$SG_DATA_ROOT/boot-property"; : > "$SG_DATA_ROOT/pm-ready"; }
fi
''')
        script(fake / "pm", '''
case "$1:$2" in
    path:android) [ -f "$SG_DATA_ROOT/pm-ready" ] && echo package:android;;
    path:com.seogaemo.hmg) [ -f "$SG_DATA_ROOT/installed" ] && echo package:app;;
    install:*)
        echo install >> "$SG_DATA_ROOT/installs"
        if [ "$PENDING_MODE" = blocked ]; then
            : > "$SG_DATA_ROOT/install-entered"
            while [ ! -f "$SG_DATA_ROOT/install-release" ]; do /bin/sleep 0.01; done
        fi
        [ "$PENDING_MODE" != fail ] || { echo 'Failure [TRANSIENT]'; exit 0; }
        : > "$SG_DATA_ROOT/installed"; echo Success;;
esac
''')
        (state / "pm-ready").touch()
        env.update(SG_BOOT_ID_FILE=str(state / "boot-id"),
                   HMG_SEOGAEMO_APK_STAGE=str(state), PENDING_MODE="success",
                   HMG_SEOGAEMO_PM_TIMEOUT="100000")
        return base, state, job, env

    def worker(base, env):
        return subprocess.run([SHELL, str(base / "svc/install-pending.sh")], env=env,
                              capture_output=True, text=True, timeout=8)

    for mode in ("success", "slow", "late-pm", "fail", "removed", "paused", "uninstall", "no-request", "stale", "health"):
        base, state, job, env = setup(mode)
        if mode in ("slow", "late-pm", "health"):
            (state / "pm-ready").unlink()
            if mode != "late-pm":
                (state / "boot-property").write_text("0\n")
            env["PENDING_MODE"] = "slow"
        if mode == "health":
            env["HMG_SEOGAEMO_UPDATE_HEALTH"] = "1"
        if mode == "fail":
            env["PENDING_MODE"] = "fail"
        if mode == "removed":
            (job / "seen").touch()
        if mode in ("paused", "uninstall"):
            marker = state / ("stock/paused" if mode == "paused" else "uninstall/pending")
            marker.parent.mkdir(); marker.touch()
            # A retained OTA selection (version dir kept) that a completed
            # USB-requested install must drop; stock/paused itself stays.
            update = state / "update"
            (update / "versions/0.1.22").mkdir(parents=True)
            (update / "current").symlink_to(update / "versions/0.1.22")
            for name in ("current-path", "previous-path", "previous-version", "journal"):
                (update / name).write_text("x\n")
        if mode == "no-request":
            (job / "pending").unlink()
        if mode == "stale":
            (job / "worker").mkdir()
            (job / "worker/pid").write_text("2147483647 old-boot\n")
        result = worker(base, env)
        assert result.returncode == (1 if mode in ("fail", "health") else 0), (mode, result)
        assert not (job / "worker").exists()
        assert not (state / "operation.lock").exists()
        if mode in ("removed", "uninstall", "no-request", "health"):
            assert not (state / "installs").exists(), mode
            if mode == "removed":
                assert not (job / "pending").exists() and not (job / "payload").exists()
            if mode == "uninstall":
                # Queued uninstall keeps the request and the OTA selection.
                assert (job / "pending").exists() and (state / "update/current").is_symlink()
            continue
        assert (state / "boot-property").read_text().strip() == "1"
        if mode == "fail":
            assert (state / "installs").read_text().splitlines() == ["install"] * 4
            assert (state / "waits").read_text().splitlines() == ["5", "10", "20"]
            assert (job / "pending").exists() and (job / "payload/app/hmg-seogaemo.apk").exists()
            assert worker(base, env).returncode == 1
            assert (state / "installs").read_text().splitlines() == ["install"] * 4
            (state / "boot-id").write_text("boot-two\n")
            env["PENDING_MODE"] = "success"
            assert worker(base, env).returncode == 0
            assert (state / "installs").read_text().splitlines() == ["install"] * 5
        else:
            assert (state / "installs").read_text().splitlines() == ["install"]
        assert (job / "seen").exists() and not (job / "pending").exists()
        assert not (job / "payload").exists()
        if mode == "paused":
            # Explicit USB install proceeds despite a paused stock restore,
            # drops the OTA selection, and never clears the pause itself.
            update = state / "update"
            assert (state / "stock/paused").exists()
            for name in ("current", "current-path", "previous-path", "previous-version", "journal"):
                assert not (update / name).exists() and not (update / name).is_symlink(), name
            assert (update / "versions/0.1.22").is_dir()
        if mode in ("slow", "late-pm"):
            assert (state / "waits").read_text().splitlines() == ["2", "4", "8", "16"] + ["30"] * 6
        (state / "installed").unlink()
        assert worker(base, env).returncode == 0
        assert not (state / "installed").exists()

    # A concurrent launcher must preserve the live worker and attempt budget.
    base, state, job, env = setup("concurrent")
    env["PENDING_MODE"] = "blocked"
    process = subprocess.Popen([SHELL, str(base / "svc/install-pending.sh")], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        wait_for(lambda: (state / "install-entered").exists())
        claim = (job / "worker/pid").read_text()
        cmdline = state / "proc" / claim.split()[0] / "cmdline"
        cmdline.parent.mkdir(parents=True)
        cmdline.write_text("sh install-pending.sh")
        assert worker(base, env).returncode == 0
        assert (job / "worker/pid").read_text() == claim
        assert (state / "installs").read_text().splitlines() == ["install"]
        assert (state / "operation.lock").is_dir()
    finally:
        (state / "install-release").touch()
        process.communicate(timeout=8)
    assert process.returncode == 0 and not (job / "worker").exists()

    # A paused stock restore must not strand an explicit USB install request:
    # reconcile completes the APK, drops the OTA selection, but applies nothing.
    base, state, job, env = setup("reconcile-paused-install")
    (state / "stock").mkdir(); (state / "stock/paused").touch()
    old = folder / "paused-old-payload"
    (old / "svc").mkdir(parents=True)
    script(old / "svc/reconcile.sh", 'echo selected >> "$SG_DATA_ROOT/calls"\n')
    (state / "update").mkdir()
    (state / "update/current").symlink_to(old)
    (state / "update/journal").write_text("phase=healthy\n")
    result = invoke(base, env)
    assert result.returncode == 0, result
    assert (state / "installs").read_text().splitlines() == ["install"]
    assert not (job / "pending").exists() and not (state / "calls").exists()
    assert not (state / "update/current").is_symlink() and not (state / "update/journal").exists()
    assert (state / "stock/paused").exists()

    for mode in ("success", "fail", "removed", "update-failed", "old-selection"):
        base, state, job, env = setup("reconcile-" + mode)
        env["PENDING_MODE"] = "fail" if mode == "update-failed" else mode
        (state / "verified").touch()
        material = state / "modules/mapped/changes"
        material.parent.mkdir(parents=True); material.touch()
        if mode == "removed":
            (job / "seen").touch()
        if mode == "update-failed":
            (state / "installed").touch()
        if mode == "old-selection":
            old = folder / "old-payload"
            (old / "svc").mkdir(parents=True)
            script(old / "svc/reconcile.sh", 'echo selected >> "$SG_DATA_ROOT/calls"\n')
            (state / "update").mkdir()
            (state / "update/current").symlink_to(old)
        result = invoke(base, env)
        assert result.returncode == (1 if mode == "fail" else 0), (mode, result)
        calls = (state / "calls").read_text().splitlines() if (state / "calls").exists() else []
        if mode in ("success", "update-failed"):
            assert "mapped apply" in calls and "mapped revert" not in calls, calls
        elif mode == "old-selection":
            # Completing the USB request drops the stale OTA selection, so this
            # tree (matching the installed APK) reconciles instead of the old one.
            assert "selected" not in calls and "mapped apply" in calls, calls
            assert not (job / "pending").exists() and not (state / "update/current").is_symlink()
        elif mode == "removed":
            assert calls == ["mapped revert"], calls
        else:
            assert calls == [] and material.exists(), calls

    # Failed guarded restore retains the APK request; successful uninstall
    # cancels it so a surviving launcher cannot install after package removal.
    base, state, job, env = setup("preuninstall")
    (base / "scripts").mkdir()
    (base / "core").mkdir()
    copy_shell_script(ROOT / "nemesis/package/scripts/preuninstall.sh", base / "scripts/preuninstall.sh")
    script(base / "core/stock.sh", 'exit "$RESTORE_RESULT"\n')
    for restore_result in ("1", "0"):
        env["RESTORE_RESULT"] = restore_result
        result = subprocess.run([SHELL, str(base / "scripts/preuninstall.sh")],
                                env=env, capture_output=True, text=True, timeout=8)
        assert result.returncode == int(restore_result), result
        assert job.exists() == (restore_result == "1")


def test_mapper_deadlines(folder):
    base, state, fake = folder / "package", folder / "state", folder / "fake"
    for path in (base / "core", base / "lib", fake, state):
        path.mkdir(parents=True)
    copy_shell_script(ROOT / "nemesis/package/core/hmg-seogaemo-map.sh", base / "core/hmg-seogaemo-map.sh")
    fixture = base / "core/hmg-seogaemo-map.sh"
    fixture.write_text(fixture.read_text().replace(
        "umask 077", f'umask 077\nsleep() {{ "{fake}/sleep" "$@"; }}', 1))
    copy_shell_script(ROOT / "nemesis/package/lib/common.sh", base / "lib/common.sh")
    # Executable Python is the actual child PID; TERM is deliberately ignored.
    (fake / "app_process").write_text(f"#!{sys.executable}\n" + '''
import os, signal, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(os.environ["SG_DATA_ROOT"], "child").write_text(str(os.getpid()))
while True: time.sleep(1)
''')
    (fake / "app_process").chmod(0o755)
    # Refuses fractions like toolbox sleep, so the deadline also covers sg_bounded_wait's whole-second fallback.
    (fake / "sleep").write_text(f"#!{sys.executable}\nimport sys, time\nif '.' in sys.argv[1]: sys.exit(1)\ntime.sleep(0.03)\n")
    (fake / "sleep").chmod(0o755)
    env = dict(car_env(), PATH=str(fake) + ":" + car_env()["PATH"], SG_DATA_ROOT=str(state))
    for verb in ("status", "verify"):
        result = subprocess.run([SHELL, str(base / "core/hmg-seogaemo-map.sh"), verb],
                                env=env, capture_output=True, text=True, timeout=8)
        assert result.returncode != 0 and "map command timeout" in result.stdout, result
        assert not (state / "operation.lock").exists()
        assert not list((state / "car-maps").glob(".work.*"))
        pid = int((state / "child").read_text())
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError(f"mapper child {pid} survived deadline")

    # Signal cancellation must reap the mapper and release its operation lock.
    (state / "child").unlink()
    process = subprocess.Popen([SHELL, str(base / "core/hmg-seogaemo-map.sh"), "verify"],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if (state / "child").exists():
                break
            time.sleep(0.01)
        assert (state / "child").exists()
        pid = int((state / "child").read_text())
        process.terminate()
        process.communicate(timeout=8)
        assert not (state / "operation.lock").exists()
        assert not list((state / "car-maps").glob(".work.*"))
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError(f"mapper child {pid} survived cancellation")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


run_tests([test_pending_install, test_android_readiness, test_reconcile, test_detached_lifecycle,
           test_retry_backoff, test_reverse_restore_material, test_payload_replacement,
           test_mapper_deadlines], "reconcile map verification, retries, dependencies and deadlines passed")
