#!/usr/bin/env python3
"""Run every make-test suite in one pool of isolated worker processes.

The head unit runs mksh, so every root/module suite runs on mksh. /bin/sh
(dash on CI, bash on macOS) runs only SH_SMOKE: the byte-exact write/print
fallback that shells without mksh's print take, and the dispatcher entry.
HMG_SEOGAEMO_TEST_SHELLS=all (or --shells all) runs the full matrix on both;
without mksh everything runs on /bin/sh.

Workers default to the CPU count. Each suite, and each sharded test function
of a suite (see testlib.run_tests), runs in its own process with private
temporary fixtures and only reads the completed package; the lock/deadline
tests use fake sleeps and file handshakes rather than wall-clock races between
tests. Known long tasks start first. On failure the task log is printed,
scheduling stops and running process groups are killed.
Set HMG_SEOGAEMO_TEST_JOBS=1 (or --jobs 1) for serial diagnosis; --only
selects tasks whose label contains one of the given comma-separated words.
"""
import argparse
from datetime import datetime
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

# Root suites that run head-unit scripts under HMG_SEOGAEMO_TEST_SHELL.
ROOT_SUITES = ("test-diagnostics.py", "test-runtime.py", "test-line-ownership.py", "test-stock.py",
               "test-reconcile-map.py", "test-package.py", "test-entry-dispatch.py",
               "test-map-root.py", "test-recorder.py", "test-transient.py")
# Suites built on testlib.run_tests are sharded into one task per test function.
SHARDED = {"test-runtime.py", "test-line-ownership.py", "test-stock.py", "test-reconcile-map.py",
           "test-recorder.py", "test-transient.py", "test-module-install.py"}
SH_SMOKE = {("test-runtime.py", "test_common"), ("test-runtime.py", "test_output_bytes"),
            ("test-runtime.py", "test_file_key_failures"), ("test-entry-dispatch.py", None),
            ("skip-consent-screen", None)}
# Host-side checks: generator, packaging inputs, maps, lints, HSM, OTA, app logic.
HOST = (["python3", "tools/test-module-install.py"], ["python3", "tools/test-foreign.py"],
        ["python3", "tools/validate-maps.py", "all"], ["python3", "tools/test-validate-maps.py"],
        ["python3", "tools/test-map-evidence.py"], ["python3", "tools/test-map-scanner.py"],
        ["python3", "tools/test-map-verification.py"], ["python3", "tools/test-map-car.py"],
        ["./tools/verify-map", "maps/hyundai/ioniq5/kor/260902"],
        ["python3", "tools/test-confirm-routing.py"], ["sh", "tools/test-gen-modules.sh"],
        ["python3", "tools/test-android44-shell.py"], ["python3", "tools/lint-android44-shell.py"],
        ["python3", "tools/lint-module-root.py"], ["python3", "tools/lint-names.py"],
        ["python3", "tools/test-hsm.py"], ["python3", "tools/test-hsm-cli.py"],
        ["python3", "tools/test-partition.py"],
        ["python3", "tools/test-update.py"], ["python3", "tools/test-module-switch.py"],
        ["python3", "tools/test-beta-bump.py"],
        ["make", "-s", "test-java"])
# Measured seconds on a 4-CPU CI runner; longest first keeps the tail short.
EXPECTED = {"test_mutation_api_and_export": 55, "test_zygote_and_dex": 40, "wireless-carplay-and-aa": 35,
            "test_projection_reader_vm": 30, "test_hook_host": 30, "wifi/test": 25, "test-package.py": 25,
            "test-diagnostics.py": 20, "test_system_directory_mode": 15, "test_zygote_foreign": 15,
            "test_replaces": 15, "test_merged_takeover": 40, "test_installed_shared_line": 14, "test_converted_builtin": 14,
            "test_install_validation": 12, "test-hsm-cli.py": 12, "test_stray_temporaries": 12,
            "test_shared_lines": 11, "test_lifecycle": 10, "test-map-verification.py": 9,
            "test_bundled": 9, "sharing": 9, "test_ro_holders": 9, "test_service_call_api": 9,
            "test_restore": 8, "recovery": 8, "wireless-adb": 8, "test-java": 8}


def expected(label):
    return max((seconds for key, seconds in EXPECTED.items() if key in label), default=0)


def tasks(aapt, shells_mode):
    mksh = shutil.which("mksh")
    car = mksh or "/bin/sh"
    full_sh = shells_mode == "all" or not mksh
    result = []
    for suite in ROOT_SUITES:
        path = str(ROOT / "tools" / suite)
        names = ([None] if suite not in SHARDED else
                 subprocess.run([sys.executable, path, "--list"], check=True, capture_output=True,
                                text=True).stdout.split())
        extra = ["--aapt", aapt] if suite == "test-package.py" else []
        for name in names:
            command = [sys.executable, path, *extra, *([name] if name else [])]
            shells = [car] if mksh else []
            if full_sh or (suite, name) in SH_SMOKE:
                shells.append("/bin/sh")
            result += [(shell, command) for shell in shells]
    for suite in sorted((ROOT / "modules").glob("*/test/run.sh")):
        module = suite.parent.parent.name
        # Fixture setup is host code; its run() selects the car shell.
        shells = [car] if mksh else []
        if full_sh or (module, None) in SH_SMOKE:
            shells.append("/bin/sh")
        result += [(shell, ["/bin/sh", str(suite)]) for shell in shells]
    module_install = str(ROOT / "tools/test-module-install.py")
    for command in HOST:
        if command[1:] == ["tools/test-module-install.py"]:
            names = subprocess.run([sys.executable, module_install, "--list"], check=True,
                                   capture_output=True, text=True).stdout.split()
            result += [(None, [sys.executable, module_install, name]) for name in names]
        else:
            result.append((None, command))
    return result, mksh


def label_of(shell, command):
    words = [str(Path(word).relative_to(ROOT)) if word.startswith(str(ROOT)) else word
             for word in command if word not in (sys.executable, "python3", "/bin/sh", "sh")]
    return " ".join(words) + (f" [{shell}]" if shell else "")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--aapt", required=True)
    parser.add_argument("--jobs", type=int,
                        default=int(os.environ.get("HMG_SEOGAEMO_TEST_JOBS") or os.cpu_count() or 2))
    parser.add_argument("--shells", choices=("car", "all"),
                        default="all" if os.environ.get("HMG_SEOGAEMO_TEST_SHELLS") == "all" else "car")
    parser.add_argument("--only", default="")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    planned, mksh = tasks(args.aapt, args.shells)
    words = [word for word in args.only.split(",") if word]
    queue = [(label_of(shell, command), shell, command) for shell, command in planned]
    queue = [task for task in queue if not words or any(word in task[0] for word in words)]
    queue.sort(key=lambda task: -expected(task[0]))  # stable: equal weights keep plan order
    if not queue:
        parser.error("no task matches --only")
    if not mksh:
        print("mksh not found: running every suite on /bin/sh only", flush=True)

    logs = ROOT / "out/test-logs"
    logs.mkdir(parents=True, exist_ok=True)
    log_dir = Path(tempfile.mkdtemp(prefix="run-", dir=logs))
    print(f"Tasks: {len(queue)}, workers: {args.jobs}", flush=True)
    print(f"Task logs: {log_dir.relative_to(ROOT)}", flush=True)
    # Host tests pick mksh themselves (testlib); java runs a nested make.
    base_env = {key: value for key, value in os.environ.items()
                if key not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "HMG_SEOGAEMO_TEST_SHELL")}
    active = []
    start = time.monotonic()
    serial = 0
    try:
        while queue or active:
            # Check every completed task before launching another after failure.
            for task in list(active):
                process, output, label, started, path = task
                status = process.poll()
                if status is None:
                    continue
                output.close()
                active.remove(task)
                elapsed = time.monotonic() - started
                stamp = datetime.now().strftime("%H:%M:%S")
                print(f"[{stamp}] {'PASS' if status == 0 else 'FAIL'} {label} ({elapsed:.2f}s)", flush=True)
                if status:
                    print(path.read_text(errors="replace"), file=sys.stderr, flush=True)
                    print(f"Failed task log: {path}", file=sys.stderr, flush=True)
                    return 1
            while queue and len(active) < args.jobs:
                label, shell, command = queue.pop(0)
                serial += 1
                name = "".join(c if c.isalnum() or c in "-_." else "-" for c in label)[:120]
                path = log_dir / f"{serial:03d}-{name}.log"
                output = path.open("w")
                env = dict(base_env, **({"HMG_SEOGAEMO_TEST_SHELL": shell} if shell else {}))
                try:
                    process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output,
                                               stderr=subprocess.STDOUT, start_new_session=True)
                except BaseException:
                    output.close()
                    raise
                active.append((process, output, label, time.monotonic(), path))
            if active:
                time.sleep(0.05)
    finally:
        # Fail fast, including a suite's child shells/Java processes.
        for process, output, *_ in active:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for process, output, *_ in active:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            output.close()
    print(f"All tasks passed in {time.monotonic() - start:.2f}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
