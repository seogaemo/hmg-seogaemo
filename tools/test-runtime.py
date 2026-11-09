#!/usr/bin/env python3
"""Isolated checks of the shared root runtime."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from testlib import car_env, SHELL, host_shell_script, copy_shell_script, run_tests

ROOT = Path(__file__).resolve().parents[1]


def test_toolbox_md5(temp):
    sample = temp / "md5-sample"
    sample.write_bytes(b"abc")
    result = subprocess.run(["md5", str(sample)], env=car_env(), capture_output=True, text=True)
    assert result.returncode == 0
    assert result.stdout == f"900150983cd24fb0d6963f7d28e17f72  {sample}\n"
    missing = subprocess.run(["md5", str(temp / "missing")], env=car_env(), capture_output=True)
    assert missing.returncode != 0
    stdin = subprocess.run(["md5"], input=b"abc", env=car_env(), capture_output=True)
    assert stdin.returncode != 0 and not stdin.stdout
    piped = subprocess.run(["md5", "/proc/self/fd/0"], input=b"abc", env=car_env(), capture_output=True)
    assert piped.returncode == 0
    assert piped.stdout == b"900150983cd24fb0d6963f7d28e17f72  /proc/self/fd/0\n"


def script(path, body):
    # Load common.sh only where the body needs it and does not load it itself:
    # mksh R59 takes one to two seconds to redefine every function on a second load.
    sources = re.search(r'^\s*\. .*common\.sh', body, re.M)
    prefix = '. "' + str(ROOT / 'nemesis/package/lib/common.sh') + '"\n' if 'sg_' in body and not sources else ''
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\n' + prefix + host_shell_script(body))
    path.chmod(0o755)


def test_file_key_failures(temp):
    runner = temp / 'file-key-runner'
    script(runner, '''
set -eu
key=$(sg_file_key abc)
[ "$key" = 900150983cd24fb0d6963f7d28e17f72 ]
md5() { echo malformed; }
if sg_file_key abc; then exit 1; fi
md5() { :; }
if sg_file_key abc; then exit 1; fi
md5() { return 1; }
if sg_file_key abc; then exit 1; fi
sg_check_build() { :; }
if sg_file_mark_applied /owned; then exit 1; fi
''')
    run(runner, env=dict(os.environ, HMG_SEOGAEMO_STATE=str(temp)))


def fake_ownership(fake):
    for name in ("ls", "chown"):
        script(fake / name, f'exec /bin/sh "{ROOT / "tools/testlib/fake-ownership.sh"}" {name} "$@"\n')
    script(fake / "nemesis", "exit 0\n")


def run(path, *args, env, ok=True, timeout=None):
    result = subprocess.run([SHELL, str(path), *args], env=car_env(env), text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if ok:
        assert result.returncode == 0, (path, args, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (path, args, result.stdout, result.stderr)
    return result


def test_common(temp):
    base = temp / "common"
    state = base / "state"
    live = base / "live"
    backing = base / "backing"
    fake = base / "fake"
    for path in (state, live, backing, fake):
        path.mkdir(parents=True)
    (base / "modules").mkdir()
    (base / "modules/state.properties").write_text(
        f"owns_props=absent,empty,drift,ro.build.product\n"
        f"owns_files={base / 'owned'},{base / 'drift-file'},{base / 'missing'},{base / 'firmware-file'}\n"
        "services=adbd\n")
    script(fake / "getprop", 'cat "$FAKE_LIVE/$1" 2>/dev/null || true\n')
    script(fake / "setprop", 'sg_write "$2" > "$FAKE_LIVE/$1"\n')
    (live / "ro.build.product").write_text("NEEV.KOR.260902")
    target = base / "owned"
    target.write_bytes(b"original\x00bytes")
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               FAKE_LIVE=str(live), SG_PROPERTY_ROOT=str(backing),
               HMG_SEOGAEMO_STATE=str(state), HMG_SEOGAEMO_BASE=str(base),
               HMG_SEOGAEMO_MODULE_DIR=str(base / "payload"), SG_DATA_ROOT=str(base / "data"))
    common = ROOT / "nemesis/package/lib/common.sh"
    runner = base / "runner"
    script(runner, f'''
set -eu
. "{common}"
# Fresh status probes must not create state or report a firmware conflict.
if sg_applied absent; then exit 1; fi
[ ! -e "$HMG_SEOGAEMO_STATE/module.log" ]
sg_prop_baseline absent
sg_prop_set absent changed
sg_prop_restore absent
[ ! -e "$SG_PROPERTY_ROOT/absent" ]
[ -z "$(getprop absent)" ]
sg_write '' > "$SG_PROPERTY_ROOT/empty"
sg_prop_baseline empty
sg_prop_set empty changed
sg_prop_restore empty
[ -f "$SG_PROPERTY_ROOT/empty" ] && [ ! -s "$SG_PROPERTY_ROOT/empty" ]
sg_prop_baseline drift
sg_prop_set drift ours
setprop drift theirs
if sg_prop_restore drift; then exit 1; fi
[ "$(getprop drift)" = theirs ]
sg_file_baseline "{target}"
sg_write changed > "{target}"
sg_file_mark_applied "{target}"
sg_file_restore "{target}"
cmp -s "{target}" "$HMG_SEOGAEMO_STATE/file.$(sg_file_key "{target}")/bytes"
sg_file_restore "{target}"
sg_file_baseline "{base / "drift-file"}"
sg_write ours > "{base / "drift-file"}"
sg_file_mark_applied "{base / "drift-file"}"
sg_write firmware > "{base / "drift-file"}"
if sg_file_restore "{base / "drift-file"}"; then exit 1; fi
[ "$(cat "{base / "drift-file"}")" = firmware ]
sg_file_baseline "{base / "missing"}"
sg_write changed > "{base / "missing"}"
sg_file_mark_applied "{base / "missing"}"
sg_file_restore "{base / "missing"}"
[ ! -e "{base / "missing"}" ]
sg_file_baseline "{base / "firmware-file"}"
sg_write ours > "{base / "firmware-file"}"
sg_file_mark_applied "{base / "firmware-file"}"
setprop ro.build.product OTHER.BUILD
if sg_file_restore "{base / "firmware-file"}"; then exit 1; fi
[ "$(cat "{base / "firmware-file"}")" = ours ]
setprop ro.build.product NEEV.KOR.260902
sg_log test
sg_baseline_clear
''')
    run(runner, env=env)
    assert target.read_bytes() == b"original\x00bytes"
    toolbox_runner = base / "toolbox-ls"
    script(toolbox_runner, f'''
set -eu
. "{common}"
ls() {{ sg_print '-rw-r--r-- 1000 1001 3 2024-01-02 03:04 sample'; }}
[ "$(sg_file_meta sample)" = '0644 1000 1001' ]
[ "$(sg_file_size sample)" = 3 ]
''')
    run(toolbox_runner, env=env)


def test_output_bytes(temp):
    punctuation = temp / 'status-punctuation'
    script(punctuation, "sg_status on adbd 'TCP ADB on port 5555; stock switch off'\n")
    assert run(punctuation, env=os.environ).stdout == (
        'state=on\nrestart=adbd\ndetail=TCP ADB on port 5555; stock switch off\n')
    base = temp / "output-bytes"
    restricted = base / "bin"
    restricted.mkdir(parents=True)
    # No external output formatter is available, even on hosts that ship one.
    for name in ("cat", "cp", "mv", "rm", "mkdir", "chmod", "chown", "ls", "dd", "cmp", "python3"):
        (restricted / name).symlink_to(shutil.which(name))
    (restricted / "md5").symlink_to(ROOT / "tools/testlib/fakebin/md5")
    common = ROOT / "nemesis/package/lib/common.sh"
    state = base / "state"
    runner = base / "runner"
    backing = base / "backing"
    backing.mkdir()
    cases = [b"", b"value", b"value\n", b"value\n\n", b"-n", b"-e",
             b"a\\nb\\c\\\\%s\t$()", "한국어\n".encode()]
    for index, value in enumerate(cases):
        env = dict(os.environ, PATH=str(restricted), SG_DATA_ROOT=str(base / "data"),
                   HMG_SEOGAEMO_STATE=str(state), SG_PROPERTY_ROOT=str(backing),
                   TEST_VALUE=value.decode(), TEST_DEST=str(base / "output"))
        script(runner, f'''
set -eu
. "{common}"
sg_write "$TEST_VALUE" > "$TEST_DEST"
sg_print "$TEST_VALUE" '' '-n' > "$TEST_DEST.lines"
''')
        run(runner, env=env)
        assert (base / "output").read_bytes() == value
        assert (base / "output.lines").read_bytes() == value + b"\n\n-n\n"
        # Baseline/restore files and property backing bytes independently of text output.
        target = base / f"target-{index}"
        prop = backing / "demo"
        target.write_bytes(value)
        prop.write_bytes(value)
        script(runner, f'''
set -eu
. "{common}"
getprop() {{ echo 'stock'; }}
setprop() {{ :; }}
sg_file_baseline "{target}"
sg_write changed > "{target}"
sg_file_mark_applied "{target}"
sg_file_restore "{target}"
sg_prop_baseline demo
sg_write changed > "$SG_PROPERTY_ROOT/demo"
sg_prop_restore demo
''')
        run(runner, env=env)
        assert target.read_bytes() == value
        assert prop.read_bytes() == value
        assert (state / "prop.demo/backing").read_bytes() == value
        shutil.rmtree(state)
    # Absence must remain distinct from a present zero-byte file.
    prop.unlink()
    target.unlink()
    run(runner, env=env)
    assert not target.exists() and not prop.exists()
    # A failed print write must propagate; it must not retry via the fallback.
    for helper in ("sg_write", "sg_print"):
        script(runner, f'''
. "{common}"
print() {{ echo partial; return 7; }}
{helper} test
''')
        assert run(runner, env=env, ok=False).stdout == "partial\n"


def test_root(temp):
    base = temp / "root"
    (base / "bin").mkdir(parents=True)
    (base / "modules").mkdir()
    (base / "lib").mkdir()
    copy_shell_script(ROOT / "nemesis/package/bin/hmg-seogaemo-root", base / "bin/hmg-seogaemo-root")
    copy_shell_script(ROOT / "nemesis/package/lib/common.sh", base / "lib/common.sh")
    (base / "modules.list").write_text("a\nb\nc\n")
    (base / "modules.graph").write_text(
        "a\tdepends=\texcludes=c\n"
        "b\tdepends=a\texcludes=\n"
        "c\tdepends=\texcludes=a\n")
    for name in "abc":
        script(base / "modules" / (name + ".sh"),
               'case "$1" in apply) echo state=on;; revert) echo state=off;; '
               'status) echo state=off;; watch) echo state=on;; esac\necho restart=none\necho detail=\n')
    script(base / "modules/c.sh", '''
case "$1" in
    apply) echo state=on; echo restart=none ;;
    revert) echo state=pending-restart; echo restart=head_unit; echo info.desired=off ;;
    status) echo state=off; echo restart=none ;;
esac
echo detail=
''')
    (base / "modules/a.properties").write_text("watch=boot,screen_on,usb_change\n")
    (base / "modules/c.properties").write_text("restore=exact\n")
    # All module entry points and the dispatcher are non-executable after extraction.
    for path in base.rglob("*"):
        if path.is_file():
            path.chmod(0o644)
    state = base / "state"
    env = dict(os.environ, SG_DATA_ROOT=str(state))
    root = base / "bin/hmg-seogaemo-root"
    fake = base / "fake"
    fake.mkdir()
    for command in ("sync", "reboot"):
        script(fake / command, 'echo ' + command + ' >> "$FAKE_DEVICE_CALLS"\n' +
               ('[ "${FAKE_SYNC_FAIL:-0}" = 0 ]\n' if command == "sync" else 'exit 0\n'))
    calls = base / "device-calls"
    device_env = dict(env, PATH=str(fake) + ":" + os.environ["PATH"], FAKE_DEVICE_CALLS=str(calls))
    for args in [("device", "bad"), ("device", "reboot", "extra")]:
        run(root, *args, env=device_env, ok=False)
    assert not calls.exists()
    run(root, "device", "reboot", env=device_env)
    assert calls.read_text() == "sync\nreboot\n"
    calls.write_text("")
    run(root, "device", "reboot", env=dict(device_env, FAKE_SYNC_FAIL="1"), ok=False)
    assert calls.read_text() == "sync\n"
    def refused(args, detail, code=3):
        response = run(root, *args, env=env, ok=False)
        assert response.returncode == code, response
        assert ('state=conflict' if code == 3 else 'state=failed') in response.stdout
        assert 'restart=none' in response.stdout
        assert 'detail=' + detail in response.stdout, response.stdout
    refused(("b", "apply"), "Dependency off: a")
    refused(("a", "bogus"), "Invalid command", 2)
    refused(("a", "tbt-reset"), "Invalid command", 2)   # only the wireless module has it
    refused(("a", "tbt-reset", "extra"), "Invalid command", 2)
    refused(("a", "status", "extra"), "Invalid command", 2)
    refused(("unknown", "status"), "Invalid command", 2)
    run(root, "a", "apply", env=env)
    status = run(root, "a", "status", env=env).stdout
    assert 'info.desired=on' in status
    run(root, "b", "apply", env=env)
    run(root, "a", "watch", "boot", env=env)
    run(root, "a", "watch", "usb_change", env=env)
    run(root, "a", "watch", "bogus", env=env, ok=False)
    run(root, "b", "watch", "boot", env=env, ok=False)
    run(root, "b", "watch", "usb_change", env=env, ok=False)
    refused(("c", "apply"), "Excluded module on: a")
    refused(("a", "revert"), "Dependent on: b")
    run(root, "b", "revert", env=env)
    run(root, "a", "revert", env=env)
    assert 'info.desired=off' in run(root, "a", "status", env=env).stdout
    run(root, "a", "watch", "boot", env=env, ok=False)
    (state / "uninstall").mkdir()
    (state / "uninstall/pending").touch()
    refused(("c", "apply"), "Uninstall pending")
    (state / "uninstall/pending").unlink()
    run(root, "c", "apply", env=env)
    run(root, "c", "revert", env=env)
    assert (state / "desired/c").read_text() == "off"
    assert (state / "desired/a").read_text() == "off"
    assert (state / "desired/b").read_text() == "off"


def test_automatic_intent_lock(temp):
    for automatic, explicit, before, after in (
            ('apply', 'revert', 'on', 'off'), ('revert', 'apply', 'off', 'on')):
        base = temp / ('intent-' + automatic)
        for part in ('bin', 'lib', 'modules', 'state/desired', 'fake'):
            (base / part).mkdir(parents=True, exist_ok=True)
        dispatcher = base / 'bin/hmg-seogaemo-root'
        copy_shell_script(ROOT / 'nemesis/package/bin/hmg-seogaemo-root', dispatcher)
        # A private sleep wrapper makes lock contention observable even with
        # mksh's builtin sleep, without timing the race against the host clock.
        # One second per retry (ten retries) keeps the lock-wait budget at ~10 s so a
        # slow or loaded CI runner still finishes the explicit call before "busy".
        dispatcher.write_text(dispatcher.read_text().replace('umask 077', '''umask 077
sleep() { : > "$SG_DATA_ROOT/queued"; /bin/sleep 1; }''', 1))
        copy_shell_script(ROOT / 'nemesis/package/lib/common.sh', base / 'lib/common.sh')
        (base / 'modules.list').write_text('example\n')
        (base / 'modules.graph').write_text('example\tdepends=\texcludes=\n')
        (base / 'modules/example.properties').write_text('id=example\n')
        (base / 'modules/example.sh').write_text('''
echo "$1" >> "$SG_DATA_ROOT/calls"
: > "$SG_DATA_ROOT/entered"
while [ ! -f "$SG_DATA_ROOT/release" ]; do /bin/sleep 0.01; done
case "$1" in apply) echo state=on;; revert) echo state=off;; esac
echo restart=none
''')
        script(base / 'fake/pm', 'echo package:fixture\n')
        state = base / 'state'
        desired = state / 'desired/example'
        desired.write_text(before)
        env = car_env(dict(os.environ, SG_DATA_ROOT=str(state)))
        env['PATH'] = str(base / 'fake') + ':' + env['PATH']
        def wait_for(path):
            deadline = time.monotonic() + 5
            while not path.exists():
                assert time.monotonic() < deadline, str(path)
                time.sleep(0.005)
        user = subprocess.Popen([SHELL, str(dispatcher), 'example', explicit],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        queued = None
        try:
            wait_for(state / 'entered')
            queued = subprocess.Popen([SHELL, str(dispatcher), 'example', automatic],
                env=dict(env, HMG_SEOGAEMO_RECONCILE='1'),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            wait_for(state / 'queued')
            (state / 'release').touch()
            assert user.communicate(timeout=5)[0].startswith('state=')
            assert user.returncode == 0
            output, error = queued.communicate(timeout=5)
            assert queued.returncode == 0, (output, error)
            assert 'state=not-implemented' in output and 'restart=none' in output, output
            assert 'info.skipped=true' in output and 'info.desired=' + after in output, output
            assert 'detail=Automatic module intent changed' in output, output
            assert desired.read_text() == after
            assert (state / 'calls').read_text().splitlines() == [explicit]
            assert (state / 'journal').read_text().split()[-1] == explicit
        finally:
            (state / 'release').touch()
            for child in (user, queued):
                if child is not None and child.poll() is None:
                    child.kill()
                    child.communicate()


def test_mutation_api_and_export(temp):
    base = temp / "api"
    state = base / "data/modules/test"
    state.mkdir(parents=True)
    for folder in ("modules", "payload", "fake", "bin"):
        (base / folder).mkdir()
    fake = base / "fake"
    live = base / "live"
    live.mkdir()
    (live / "ro.build.product").write_text("NEEV.KOR.260902")
    (live / "init.svc.adbd").write_text("running")
    script(fake / "getprop", 'cat "$FAKE_LIVE/$1" 2>/dev/null || true\n')
    script(fake / "setprop", 'sg_write "$2" > "$FAKE_LIVE/$1"\n')
    script(fake / "stop", 'sg_write stopped > "$FAKE_LIVE/init.svc.$1"\n')
    script(fake / "start", 'sg_write running > "$FAKE_LIVE/init.svc.$1"\n')
    fake_ownership(fake)
    script(fake / "nemesis", 'echo "$*" >> "$FAKE_REMOUNTS"\n')
    # Toolbox mount accepts "-o bind source target".
    script(fake / "mount", '''
cp "$4" "$4.under"
cp "$3" "$4"
sg_print "bind $4 ext4 rw 0 0" > "$SG_MOUNTS_FILE"
''')
    script(fake / "umount", 'cp "$1.under" "$1"; rm -f "$1.under"; : > "$SG_MOUNTS_FILE"\n')
    put = base / "put"
    replace = base / "replace"
    deleted = base / "deleted"
    bound = base / "bound"
    put.write_text("old")
    replace.write_text("before\nkeep\n")
    deleted.write_text("delete me")
    bound.write_text("under")
    (base / "payload/new").write_text("new")
    (base / "payload/bind").write_text("overlay")
    (base / "modules/test.properties").write_text(
        f"owns_props=demo\nowns_files={put},{replace},{deleted},{bound}\nservices=adbd\n")
    copy_shell_script(ROOT / "nemesis/package/bin/hmg-seogaemo-root", base / "bin/hmg-seogaemo-root")
    (base / "NEMESIS.data").write_text("package-version=1.2.3\n")
    mounts = base / "mounts"
    mounts.write_text("")
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               FAKE_OWNERS=str(base / "owners.json"), FAKE_LIVE=str(live), FAKE_REMOUNTS=str(base / "remounts"),
               SG_DATA_ROOT=str(base / "data"), HMG_SEOGAEMO_STATE=str(state),
               HMG_SEOGAEMO_BASE=str(base), HMG_SEOGAEMO_MODULE_DIR=str(base / "payload"),
               SG_PROPERTY_ROOT=str(base / "property"), SG_MOUNTS_FILE=str(mounts))
    (base / "property").mkdir()
    runner = base / "run-api"
    script(runner, f'''
set -eu
. "{ROOT / 'nemesis/package/lib/common.sh'}"
if sg_prop_set unowned evil; then exit 1; fi
if sg_file_put "{base / 'unowned'}" new; then exit 1; fi
sg_remount rw
sg_remount ro
sg_prop_set demo ours
sg_file_put "{put}" new
sg_file_replace_line "{replace}" before after
sg_file_delete "{deleted}"
chmod 0600 "$HMG_SEOGAEMO_MODULE_DIR/bind"
if sg_bind_mount "{bound}" bind; then exit 1; fi
chmod 0644 "$HMG_SEOGAEMO_MODULE_DIR/bind"
chown 1000:1000 "$HMG_SEOGAEMO_MODULE_DIR/bind"
if sg_bind_mount "{bound}" bind; then exit 1; fi
chown 0:0 "$HMG_SEOGAEMO_MODULE_DIR/bind"
sg_bind_mount "{bound}" bind
cp "{bound}.under" "{bound}"
: > "$SG_MOUNTS_FILE"
sg_reapply_binds
sg_service_restart adbd
sg_applied demo
sg_applied "{put}"
sg_applied "{bound}"
sg_revert_all
''')
    run(runner, env=env)

    assert put.read_text() == "old"
    assert replace.read_text() == "before\nkeep\n"
    assert deleted.read_text() == "delete me"
    assert bound.read_text() == "under"
    assert (live / "demo").read_text() == ""
    ledger = base / "data/ledger/ledger.tsv"
    rows = ledger.read_text().splitlines()
    assert len(rows) >= 8, rows
    assert all(len(row.split("\t")) == 7 for row in rows)
    assert (base / "data/ledger/before").is_dir()
    assert (base / "data/ledger/after").is_dir()
    assert (base / "remounts").read_text().splitlines() == ["remount rw", "remount ro"]
    export_root = base / "hmg-seogaemo-export"
    (base / "lib").mkdir(exist_ok=True)
    copy_shell_script(ROOT / "nemesis/package/lib/common.sh", base / "lib/common.sh")
    copy_shell_script(ROOT / "nemesis/package/lib/diagnostics.sh", base / "lib/diagnostics.sh")
    export_root.mkdir(mode=0o700)
    env["SG_EXPORT_ROOT"] = str(export_root)
    (base / "modules.list").write_text("test\n")
    (base / "modules/test.sh").write_text("echo state=on\necho restart=none\n")
    with (base / "modules/test.properties").open("a") as metadata:
        metadata.write("owns_props=demo,wifi.ssid,wifi.psk\n")
    (live / "wifi.ssid").write_text("private-network")
    (live / "wifi.psk").write_text("private-password")
    data = base / "data"
    for relative, content in {
        "reconcile.log": "r" * 70000 + "\nreconcile finished\nssid=private-network\n",
        "watcher.log": "watcher finished\n",
        "modules/test/module.log": "module finished\n",
        "stock/result": "state=failed\n",
        "stock/module-output": "detail=restore conflict\n",
        "uninstall/result": "queued\n",
        "uninstall/log": "uninstall finished\n",
        "update/journal": "phase=healthy\n",
        "runtime/carplay/result": "native patch failed\n",
        "runtime/carplay/runtime.log": "psk=private-password\nsafe runtime log\n",
        "runtime/carplay/wpa_supplicant.conf": "private-config\n",
        "runtime/carplay/softap.conf": "private-config\n",
        "runtime/wireless-carplay-and-aa/apps/com.daudio.app.dipo/p-10-20.txt": "gate.state=ready\n",
        "runtime/wireless-carplay-and-aa/apps/com.daudio.app.dipo/p-10-20.log.1": "native EACCES\n",
    }.items():
        target = data / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    (data / "runtime/carplay/linked.log").symlink_to(data / "runtime/carplay/wpa_supplicant.conf")
    dipo = base / "dipo-runtime"
    dipo.mkdir()
    summary = "format=2\nkind=tbt-icons\n" + "type=1 junction=0 side=0 exit~-90|icon=70 kind=exact exit=-90|1|1|2|좌회전\n" * 3000
    (dipo / "tbt-icons.txt").write_text(summary)
    (dipo / "tbt-lanes.journal.3").write_bytes(b"1|n=2|frame=f102|\n" * 80000)
    (dipo / "tbt-icons.journal.9").write_text("not a fixed name\n")
    (dipo / "p-1-2.txt").write_text("not a turn-by-turn record\n")
    env["HMG_SEOGAEMO_DIPO_RUNTIME"] = str(dipo)
    result = run(base / "bin/hmg-seogaemo-root", "export", "adb", env=env)
    assert "state=on" in result.stdout
    exported = next(export_root.glob("*/ledger/ledger.tsv"))
    assert exported.read_bytes() == ledger.read_bytes()
    diagnostics = exported.parents[1] / "diagnostics"
    assert "truncated" in (diagnostics / "manifest.txt").read_text()
    for relative in ("logs/reconcile.log", "logs/watcher.log", "modules/test/module.log",
                     "stock/result", "stock/module-output", "uninstall/result", "uninstall/log",
                     "update/journal", "runtime/carplay/result", "runtime/carplay/runtime.log",
                     "runtime/wireless-carplay-and-aa/apps/com.daudio.app.dipo/p-10-20.txt",
                     "runtime/wireless-carplay-and-aa/apps/com.daudio.app.dipo/p-10-20.log.1",
                     "map-status.txt", "module-test-status.txt", "properties.txt", "owned-paths.txt"):
        assert (diagnostics / relative).is_file(), relative
    # turn-by-turn records: fixed names only, copied whole up to 1 MiB + 64 KiB
    assert (diagnostics / "tbt/tbt-icons.txt").read_bytes() == (dipo / "tbt-icons.txt").read_bytes()
    lanes_copy = (diagnostics / "tbt/tbt-lanes.journal.3").stat().st_size
    assert lanes_copy == min((dipo / "tbt-lanes.journal.3").stat().st_size, 272 * 4096), lanes_copy
    assert sorted(p.name for p in (diagnostics / "tbt").iterdir()) == ["tbt-icons.txt", "tbt-lanes.journal.3"]
    for entry in diagnostics.rglob("*"):
        if entry.is_file() and entry.parent.name != "tbt":
            assert entry.stat().st_size <= 65537, entry
            assert b"private-" not in entry.read_bytes(), entry
    assert not (diagnostics / "runtime/carplay/linked.log").exists()
    assert not list(diagnostics.rglob("*.conf"))

    assert export_root.stat().st_mode & 0o777 == 0o755
    # Every exported ancestor is traversable and every file readable by shell.
    for entry in export_root.rglob("*"):
        assert entry.stat().st_mode & 0o777 == (0o755 if entry.is_dir() else 0o644)
    assert (exported.parents[1] / "ro.build.product").read_text().strip() == "NEEV.KOR.260902"
    # USB keeps only records of the current boot and the last 12 hours; adb keeps all.
    old_record = "1000000000.1.0"
    (base / "data/ledger/before" / old_record).write_text("old before")
    (base / "data/ledger/after" / old_record).write_text("old after")
    recent = sorted(p.name for p in (base / "data/ledger/after").iterdir() if p.name != old_record)
    assert recent
    uptime = base / "uptime"
    uptime.write_text("120.50 100.00\n")
    env["SG_UPTIME_FILE"] = str(uptime)
    usb = base / "usb0"
    usb.mkdir(mode=0o711)
    (usb / "HMG-Seogaemo-export").mkdir(mode=0o700)
    private_mode = state.stat().st_mode & 0o777
    mounts.write_text(f"/dev/sda1 {usb} vfat rw 0 0\n")
    env["SG_USB_DIRS"] = str(usb)
    result = run(base / "bin/hmg-seogaemo-root", "export", "usb", env=env)
    assert "state=on" in result.stdout
    assert list(usb.glob("HMG-Seogaemo-export/*/ledger/ledger.tsv"))
    assert usb.stat().st_mode & 0o777 == 0o711
    assert state.stat().st_mode & 0o777 == private_mode
    for entry in [usb / "HMG-Seogaemo-export", *(usb / "HMG-Seogaemo-export").rglob("*")]:
        assert entry.stat().st_mode & 0o777 == (0o755 if entry.is_dir() else 0o644)
    # The stick is write-back: the export must be synced and verified before success.
    assert "info.export_safe=usb" in result.stdout
    published = next(usb.glob("HMG-Seogaemo-export/*"))
    manifest = (published / "MANIFEST").read_text().splitlines()
    sizes = dict(line.split("\t", 1)[::-1] for line in manifest)
    assert sizes["ledger/ledger.tsv"] == str(ledger.stat().st_size)
    assert sizes["package-version"] != "0" and "MANIFEST" not in sizes
    for relative, size in sizes.items():
        assert str((published / relative).stat().st_size) == size, relative
    assert not (published / "ledger/before" / old_record).exists()
    assert not (published / "ledger/after" / old_record).exists()
    assert sorted(p.name for p in (published / "ledger/after").iterdir()) == recent
    assert "since=" in (published / "ledger/WINDOW").read_text()
    adb_result = run(base / "bin/hmg-seogaemo-root", "export", "adb", env=env)
    assert "info.export_safe=adb" in adb_result.stdout
    adb_ledger = Path(adb_result.stdout.split("detail=", 1)[1].split()[0]) / "ledger"
    assert (adb_ledger / "after" / old_record).read_text() == "old after"
    assert not (adb_ledger / "WINDOW").exists()
    # Problem report: logs=ours keeps only our area of the Android log and adds NEMESIS log and a summary.
    script(fake / "logcat", 'echo "I/HMG-Seogaemo( 1): ours"; echo "I/SomeVendorApp( 2): other"\n')
    script(fake / "nemesis", 'case "$1" in log) echo "nemesis log line";; *) exit 0;; esac\n')
    # Wi-Fi/USB facts for a USB dongle: interface bus and driver, USB ids, modules, kernel log, kernel config.
    wroot = base / "wifi-root"
    iface = wroot / "sys/devices/usb1/1-1/1-1:1.0"
    (iface / "net/wlan1").mkdir(parents=True)
    (iface / "uevent").write_text("DRIVER=rtl8192cu\nPRODUCT=bda/8176/200\n")
    (iface / "driver").symlink_to("../../../../bus/usb/drivers/rtl8192cu")
    (iface / "net/wlan1/device").symlink_to("../..")
    (iface / "net/wlan1/operstate").write_text("up\n")
    (iface.parent / "idVendor").write_text("0bda\n")
    (iface.parent / "idProduct").write_text("8176\n")
    (iface.parent / "serial").write_text("private-serial\n")
    (wroot / "sys/class/net").mkdir(parents=True)
    (wroot / "sys/class/net/wlan1").symlink_to("../../devices/usb1/1-1/1-1:1.0/net/wlan1")
    (wroot / "sys/bus/usb/devices").mkdir(parents=True)
    (wroot / "sys/bus/usb/devices/1-1").symlink_to("../../../devices/usb1/1-1")
    (wroot / "proc").mkdir()
    (wroot / "proc/modules").write_text("8192cu 500000 0 - Live 0x00000000\n")
    (wroot / "proc/config.gz").write_bytes(b"\x1f\x8bkernel-config")
    script(fake / "dmesg", 'echo "usb 1-1: new high-speed USB device"; echo "wlan1: SSID home-net"; '
                           'echo "wlan1: 00:e0:4c:00:00:01 up"\n')
    env["HMG_SEOGAEMO_WIFI_ROOT"] = str(wroot)
    time.sleep(1.1)
    report = run(base / "bin/hmg-seogaemo-root", "export", "adb", "ours", env=env)
    assert "info.export_safe=adb" in report.stdout, report.stdout
    folder = Path(report.stdout.split("detail=", 1)[1].split()[0]) / "diagnostics"
    logcat = (folder / "logs/logcat.txt").read_text()
    assert "ours" in logcat and "other" not in logcat, logcat
    assert "nemesis log line" in (folder / "logs/nemesis.txt").read_text()
    assert "HMG-Seogaemo problem report" in (folder / "summary.txt").read_text()
    wifi = (folder / "wifi-usb.txt").read_text()
    assert "net=wlan1 path=../../devices/usb1/1-1/1-1:1.0/net/wlan1" in wifi, wifi
    assert "driver=../../../../bus/usb/drivers/rtl8192cu" in wifi and "DRIVER=rtl8192cu" in wifi, wifi
    assert "usb=1-1 idVendor=0bda idProduct=8176" in wifi and "8192cu 500000" in wifi, wifi
    assert "new high-speed USB device" in wifi, wifi
    assert "home-net" not in wifi and "00:e0:4c" not in wifi and "private-serial" not in wifi, wifi
    assert (folder / "kernel-config.gz").read_bytes() == b"\x1f\x8bkernel-config"
    time.sleep(1.1)
    full = run(base / "bin/hmg-seogaemo-root", "export", "adb", "all", env=env)
    full_log = (Path(full.stdout.split("detail=", 1)[1].split()[0]) / "diagnostics/logs/logcat.txt").read_text()
    assert "other" in full_log, full_log
    assert "Invalid command" in run(base / "bin/hmg-seogaemo-root", "export", "adb", "some", env=env, ok=False).stdout
    sync_log = base / "sync.log"
    script(fake / "sync", 'for m in "$FAKE_USB"/HMG-Seogaemo-export/*/MANIFEST; do [ ! -f "$m" ] || echo manifest >> "$FAKE_SYNC"; done; echo sync >> "$FAKE_SYNC"\n')
    env.update(FAKE_USB=str(usb), FAKE_SYNC=str(sync_log))
    time.sleep(1.1)
    result = run(base / "bin/hmg-seogaemo-root", "export", "usb", env=env)
    lines = sync_log.read_text().splitlines()
    assert lines[-1] == "sync" and lines.count("sync") == 1, lines
    # Both earlier published exports hold a MANIFEST; the new one was written before the sync.
    newest = Path(result.stdout.split("detail=", 1)[1].split()[0])
    assert (newest / "MANIFEST").is_file() and lines.count("manifest") == 2, lines
    # A copy that lands with no data (write-back loss) must refuse instead of reporting success.
    script(fake / "cp", """real=/bin/cp
[ -x "$real" ] || real=/usr/bin/cp
"$real" "$@" || exit $?
for last; do :; done
case "$last" in */ledger) : > "$last/ledger.tsv";; esac
""")
    time.sleep(1.1)
    result = run(base / "bin/hmg-seogaemo-root", "export", "usb", env=env, ok=False)
    assert "state=failed" in result.stdout and "USB write not flushed" in result.stdout, result.stdout
    assert "state=on" not in result.stdout
    (fake / "cp").unlink()
    (fake / "sync").unlink()


def test_service_call_api(temp):
    base = temp / "service-call"
    state = base / "data/modules/skip-consent-screen"
    state.mkdir(parents=True)
    (base / "modules").mkdir()
    (base / "modules/skip-consent-screen.properties").write_text(
        "service_calls=com.hkmc.factory:82\n")
    fake = base / "fake"
    fake.mkdir()
    script(fake / "service", 'sg_print "$2 $3" >> "$FAKE_CALLS"; echo "Parcel(00000000)"\n')
    boot = base / "boot-id"
    boot.write_text("boot-a")
    runner = base / "runner"
    script(runner, f'''
set -eu
. "{ROOT / 'nemesis/package/lib/common.sh'}"
if sg_service_call wrong.name 82; then exit 1; fi
if sg_service_call com.hkmc.factory 83; then exit 1; fi
if sg_service_call 'com.hkmc.factory;bad' 82; then exit 1; fi
if sg_service_call com.hkmc.factory 00082; then exit 1; fi
sg_service_call com.hkmc.factory 82
[ "$SG_SERVICE_CALL_RESPONSE" = 'Parcel(00000000)' ]
sg_service_call_this_boot
''')
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               SG_DATA_ROOT=str(base / "data"), HMG_SEOGAEMO_STATE=str(state),
               HMG_SEOGAEMO_BASE=str(base), SG_BOOT_ID_FILE=str(boot),
               HMG_SEOGAEMO_SERVICE_BIN=str(fake / "service"),
               FAKE_CALLS=str(base / "calls"))
    run(runner, env=env)
    assert (base / "calls").read_text() == "com.hkmc.factory 82\n"
    ledger = (base / "data/ledger/ledger.tsv").read_text()
    assert "service_call\tcom.hkmc.factory:82" in ledger
    assert "Parcel(00000000)" in "".join(
        path.read_text() for path in (base / "data/ledger/after").iterdir())
    # Exercise the full timeout path without spending fifteen real seconds.
    # This service ignores TERM; the runtime must KILL it before wait().
    (fake / 'service').write_text(
        '#!' + sys.executable + chr(10) +
        'import signal, time, os' + chr(10) +
        'signal.signal(signal.SIGTERM, signal.SIG_IGN)' + chr(10) +
        'open(os.environ["FAKE_CALLS"] + ".ready", "w").close()' + chr(10) +
        'time.sleep(60)' + chr(10))
    (fake / 'sleep').write_text(
        '#!' + sys.executable + chr(10) +
        'import os, time' + chr(10) +
        'deadline = time.monotonic() + 2' + chr(10) +
        'while not os.path.exists(os.environ["FAKE_CALLS"] + ".ready") and time.monotonic() < deadline: time.sleep(.01)' + chr(10) +
        'time.sleep(.01)' + chr(10))
    (fake / 'sleep').chmod(0o755)
    script(runner, '''
set -u
sleep() { "$FAKE_SLEEP" "$@"; }
if sg_service_call com.hkmc.factory 82; then exit 1; fi
[ "$(cat "$HMG_SEOGAEMO_STATE/last-call-result")" = timeout ]
''')
    timed = subprocess.run([SHELL, str(runner)], env=car_env(dict(env, FAKE_SLEEP=str(fake / 'sleep'))),
                           capture_output=True, timeout=6)
    assert timed.returncode == 0, timed.stderr
    assert b'timeout' in (base / 'data/ledger/ledger.tsv').read_bytes()
    boot.write_text("boot-b")
    check = base / "check-boot"
    script(check, f'. "{ROOT / "nemesis/package/lib/common.sh"}"\nsg_service_call_this_boot\n')
    run(check, env=env, ok=False)


def test_reconcile(temp):
    base = temp / "lifecycle"
    for folder in ("bin", "svc", "scripts", "lib"):
        (base / folder).mkdir(parents=True)
    copy_shell_script(ROOT / "nemesis/package/svc/reconcile.sh", base / "svc/reconcile.sh")
    copy_shell_script(ROOT / "nemesis/package/scripts/preuninstall.sh", base / "scripts/preuninstall.sh")
    copy_shell_script(ROOT / "nemesis/package/lib/common.sh", base / "lib/common.sh")
    (base / "modules.list").write_text("a\nb\n")
    state = base / "state"
    (state / "desired").mkdir(parents=True)
    fake = base / "fake"
    fake.mkdir()
    script(fake / "getprop", 'echo 1\n')
    script(fake / "pm", 'case "$1" in path) if [ "$2" = android ] || [ -f "$FAKE_PM_MARKER" ]; then echo package:fake; fi;; uninstall) rm -f "$FAKE_PM_MARKER"; echo Success;; esac\n')
    log = base / "calls"
    marker = base / "apk-installed"
    marker.write_text("1")
    script(base / "bin/hmg-seogaemo-root", '''
echo "$1 $2" >> "$FAKE_CALLS"
case "$2" in
    revert) sg_write off > "$SG_DATA_ROOT/desired/$1"; echo state=off ;;
    apply) echo state=on ;;
    status) echo state=off ;;
esac
echo restart=none
echo detail=
[ "$FAKE_FAIL" != "$1:$2" ]
''')
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               SG_DATA_ROOT=str(state), FAKE_CALLS=str(log), FAKE_FAIL="",
               FAKE_PM_MARKER=str(marker))
    (state / "desired/a").write_text("on")
    (state / "desired/b").write_text("on")
    run(base / "svc/reconcile.sh", env=env)
    assert log.read_text().splitlines() == ["a apply", "b apply"]
    log.write_text("")
    for name in ("a", "b"):
        (state / "desired" / name).write_text("off")
        # Interrupted directory-only applies must be found in reverse discovery.
        ready = state / "modules" / name / ("dir.key" if name == "a" else "dir-order")
        ready.parent.mkdir(parents=True)
        ready.write_text("1")
    run(base / "svc/reconcile.sh", env=env)
    assert log.read_text().splitlines() == ["b revert", "a revert"]
    log.write_text("")
    # A generated-directory cleanup recorded before a restart is retried at boot, even
    # while a stock restore keeps automatic module calls paused, and never calls modules.
    shutil.rmtree(state / "modules")
    (base / "modules").mkdir()
    (base / "modules/a.properties").write_text(
        "owns_generated_dirs=/data/data/com.example.one/app_hmg-seogaemo-wireless-runtime\n")
    target = base / "target"
    leftover = target / "data/data/com.example.one/app_hmg-seogaemo-wireless-runtime"
    leftover.mkdir(parents=True)
    (leftover / "p-1-2.txt").write_text("generated")
    (state / "restart-cleanup").mkdir()
    (state / "restart-cleanup/a").write_text("older-boot")
    (state / "stock").mkdir()
    (state / "stock/paused").write_text("paused")
    getprop = base / "boot-id"
    getprop.write_text("this-boot")
    script(fake / "getprop", 'echo 1\n')
    run(base / "svc/reconcile.sh", env=dict(env, SG_TARGET_ROOT=str(target), SG_BOOT_ID_FILE=str(getprop)))
    assert not leftover.exists() and not (state / "restart-cleanup").exists()
    assert log.read_text() == ""
    assert not (state / "operation.lock").exists()


def test_watch_dispatch(temp):
    base = temp / "watch-dispatch"
    for folder in ("bin", "svc", "modules", "lib"):
        (base / folder).mkdir(parents=True)
    copy_shell_script(ROOT / "nemesis/package/lib/common.sh", base / "lib/common.sh")
    # Newer mksh has a sleep builtin, so PATH alone cannot intercept it.
    script(base / "svc/watcher.sh",
           f'sleep() {{ "{base / "fake/sleep"}" "$@"; }}\n' +
           (ROOT / "nemesis/package/svc/watcher.sh").read_text())
    (base / "modules.list").write_text("watcher\nplain\n")
    (base / "modules/watcher.properties").write_text("watch=boot,screen_on\n")
    (base / "modules/plain.properties").write_text("id=plain\n")
    state = base / "state"
    (state / "desired").mkdir(parents=True)
    fake = base / "fake"
    fake.mkdir()
    script(fake / "getprop", 'echo 1\n')
    script(fake / "dumpsys", 'cat "$FAKE_DISPLAY"\n')
    # Each sleep flips the display on, so the second poll sees off -> on.
    script(fake / "sleep", 'echo "$1" >> "$FAKE_SLEEPS"; echo "mWakefulness=Awake" > "$FAKE_DISPLAY"\n')
    script(base / "bin/hmg-seogaemo-root", 'echo "$1 $2 $3" >> "$FAKE_CALLS"; echo state=on\n')
    display = base / "display"
    boot_id = base / "boot-id"
    boot_id.write_text("boot-a")
    uptime = base / "uptime"
    uptime.write_text("100.0 0.0\n")
    # Fully synchronous by construction: the fake sleep, the uptime file, the
    # boot ID and the display are all driven by this test, and no real clock,
    # real sleep or inherited tuning variable can reach the watcher. Scrub the
    # caller's environment of every runtime knob so only values set here count,
    # and bound each invocation so a hang fails instead of stalling the suite.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("HMG_SEOGAEMO_", "SG_"))}
    env.update(PATH=str(fake) + ":" + os.environ["PATH"],
               SG_DATA_ROOT=str(state), FAKE_DISPLAY=str(display),
               FAKE_CALLS=str(base / "calls"), FAKE_SLEEPS=str(base / "sleeps"),
               SG_BOOT_ID_FILE=str(boot_id), HMG_SEOGAEMO_WATCH_MAX_POLLS="3",
               HMG_SEOGAEMO_WATCH_UPTIME_FILE=str(uptime),
               HMG_SEOGAEMO_WATCH_POLL="5", HMG_SEOGAEMO_WATCH_IDLE="300")
    calls = base / "calls"
    watcher = base / "svc/watcher.sh"
    # Nothing enabled: idle with the long interval, never dispatch, never exit early.
    display.write_text("mWakefulness=Asleep")
    run(watcher, env=env, timeout=120)
    assert not calls.exists()
    assert (base / "sleeps").read_text().splitlines() == ["300", "300"]
    (base / "sleeps").unlink()
    # Enabled: boot dispatched once, screen_on on the off -> on transition only.
    (state / "desired/watcher").write_text("on")
    (state / "desired/plain").write_text("on")
    display.write_text("mWakefulness=Asleep")
    run(watcher, env=env, timeout=120)
    assert calls.read_text().splitlines() == ["watcher watch boot", "watcher watch screen_on"]
    assert (base / "sleeps").read_text().splitlines() == ["5", "5"]
    # Watcher restart in the same boot does not repeat the boot event; a new boot does.
    calls.write_text("")
    display.write_text("mWakefulness=Awake")
    run(watcher, env=env, timeout=120)
    assert calls.read_text() == ""
    boot_id.write_text("boot-b")
    run(watcher, env=env, timeout=120)
    assert calls.read_text().splitlines() == ["watcher watch boot"]
    # The watcher never applies or reverts.
    assert "apply" not in calls.read_text() and "revert" not in calls.read_text()
    # Unreadable display state never triggers a call.
    calls.write_text("")
    display.write_text("garbage")
    script(fake / "sleep", 'echo "$1" >> "$FAKE_SLEEPS"\n')
    boot_id.write_text("boot-c")
    run(watcher, env=env, timeout=120)
    assert calls.read_text().splitlines() == ["watcher watch boot"]
    # Screen off-> on recognises both Android 4.4 policy and wakefulness keys.
    calls.write_text("")
    script(fake / "dumpsys", 'if [ -f "$FAKE_DISPLAY.n" ]; then echo mDisplayPowerRequest.policy=BRIGHT; else : > "$FAKE_DISPLAY.n"; echo mDisplayPowerRequest.policy=OFF; fi\n')
    run(watcher, env=env, timeout=120)
    assert calls.read_text().splitlines() == ["watcher watch screen_on"]


    # Quick boot: same boot ID, always Awake, property drift alone dispatches.
    (base / "modules/watcher.properties").write_text(
        "watch=boot,screen_on\nowns_props=demo\nreassert_props=demo\n")
    prop_dir = state / "modules/watcher/prop.demo"
    prop_dir.mkdir(parents=True)
    (prop_dir / "ready").write_text("1")
    (prop_dir / "applied").write_text("our.action")
    actual = base / "actual-property"
    env["FAKE_PROPERTY"] = str(actual)
    script(fake / "getprop", 'if [ "$1" = sys.boot_completed ]; then echo 1; else cat "$FAKE_PROPERTY"; fi\n')
    script(fake / "dumpsys", 'echo mWakefulness=Awake\n')
    script(base / "bin/hmg-seogaemo-root", 'echo "$1 $2 $3" >> "$FAKE_CALLS"; echo our.action > "$FAKE_PROPERTY"; echo state=on\n')
    for drift in ("stock.reset", "user.choice"):
        actual.write_text(drift)
        calls.write_text("")
        run(watcher, env=env, timeout=120)
        assert calls.read_text().splitlines() == ["watcher watch screen_on"]
        assert actual.read_text().strip() == "our.action"
    calls.write_text("")
    run(watcher, env=env, timeout=120)
    assert calls.read_text() == ""  # matching value never dispatches
    (state / "desired/watcher").write_text("off")
    actual.write_text("user.choice")
    run(watcher, env=env, timeout=120)
    assert calls.read_text() == "" and actual.read_text() == "user.choice"
    (state / "desired/watcher").write_text("on")
    (state / "stock").mkdir()
    (state / "stock/paused").touch()
    run(watcher, env=env, timeout=120)
    assert calls.read_text() == ""
    (state / "stock/paused").unlink()
    (prop_dir / "applied").unlink()
    run(watcher, env=env, timeout=120)
    assert calls.read_text() == ""  # never invent an assignment without a snapshot

    # Failed boot delivery is never acknowledged; capped retries survive restart.
    (base / "modules/watcher.properties").write_text("watch=boot,screen_on\n")
    script(base / "bin/hmg-seogaemo-root",
           'echo "$1 $2 $3" >> "$FAKE_CALLS"; [ ! -f "$SG_DATA_ROOT/fail-watch" ]\n')
    boot_id.write_text("boot-retry")
    calls.write_text("")
    env["HMG_SEOGAEMO_WATCH_MAX_POLLS"] = "1"
    (state / "fail-watch").touch()
    for clock, count in ((100, 1), (104, 1), (105, 2), (114, 2),
                         (115, 3), (135, 4), (175, 5), (235, 6), (999, 6)):
        uptime.write_text(f"{clock}.0 0.0\n")
        run(watcher, env=env, timeout=120)
        assert len(calls.read_text().splitlines()) == count, calls.read_text()
        assert (state / "watch/boot.watcher").read_text().strip() != "boot-retry"
    # A new boot gets its own budget; after success no repeats on restart.
    boot_id.write_text("boot-recovered")
    (state / "fail-watch").unlink()
    run(watcher, env=env, timeout=120)
    assert (state / "watch/boot.watcher").read_text().strip() == "boot-recovered"
    count = len(calls.read_text().splitlines())
    run(watcher, env=env, timeout=120)
    assert len(calls.read_text().splitlines()) == count
    # Retry a transient failure before budget exhaustion within the same boot.
    boot_id.write_text("boot-transient")
    (state / "fail-watch").touch()
    uptime.write_text("100.0 0.0\n")
    run(watcher, env=env, timeout=120)
    (state / "fail-watch").unlink()
    uptime.write_text("105.0 0.0\n")
    run(watcher, env=env, timeout=120)
    assert (state / "watch/boot.watcher").read_text().strip() == "boot-transient"
    # A failed wake stays queued even after the display remains on.
    calls.write_text("")
    (state / "fail-watch").touch()
    script(fake / "dumpsys",
           'if [ -f "$FAKE_DISPLAY.edge" ]; then echo mScreenOn=true; else : > "$FAKE_DISPLAY.edge"; echo mScreenOn=false; fi\n')
    script(fake / "sleep",
           'echo "110.0 0.0" > "$HMG_SEOGAEMO_WATCH_UPTIME_FILE"\n')
    env["HMG_SEOGAEMO_WATCH_MAX_POLLS"] = "2"
    run(watcher, env=env, timeout=120)
    assert calls.read_text().splitlines() == ["watcher watch screen_on"]
    (state / "fail-watch").unlink()
    uptime.write_text("115.0 0.0\n")
    env["HMG_SEOGAEMO_WATCH_MAX_POLLS"] = "1"
    run(watcher, env=env, timeout=120)
    assert calls.read_text().splitlines() == ["watcher watch screen_on"] * 2
    assert not (state / "watch/screen.watcher").exists()
    run(watcher, env=env, timeout=120)
    assert calls.read_text().splitlines() == ["watcher watch screen_on"] * 2


def test_usb_watch_dispatch(temp):
    base = temp / "usb-watch"
    for folder in ("bin", "svc", "modules", "lib", "fake", "state/desired",
                   "state/stock", "usb", "net"):
        (base / folder).mkdir(parents=True, exist_ok=True)
    copy_shell_script(ROOT / "nemesis/package/lib/common.sh", base / "lib/common.sh")
    script(base / "svc/watcher.sh",
           f'sleep() {{ "{base / "fake/sleep"}" "$@"; }}\n' +
           (ROOT / "nemesis/package/svc/watcher.sh").read_text())
    (base / "modules.list").write_text("adapter\n")
    (base / "modules/adapter.properties").write_text("watch=usb_change\nowns_ifaces=rtwlan*,usbnet0\n")
    state = base / "state"
    desired = state / "desired/adapter"
    desired.write_text("on")
    script(base / "fake/getprop", 'echo 1\n')
    script(base / "fake/dumpsys", 'echo mWakefulness=Awake\n')
    script(base / "fake/sleep", ':\n')
    script(base / "bin/hmg-seogaemo-root",
           'echo "$1 $2 $3" >> "$FAKE_CALLS"; [ ! -f "$SG_DATA_ROOT/fail-watch" ]\n')
    calls, uptime, boot = (base / name for name in ("calls", "uptime", "boot"))
    calls.write_text("")
    boot.write_text("usb-boot\n")
    usb, net = base / "usb", base / "net"
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("HMG_SEOGAEMO_", "SG_"))}
    env.update(PATH=str(base / "fake") + ":" + os.environ["PATH"],
               SG_DATA_ROOT=str(state), SG_USB_DEVICES_DIR=str(usb), SG_SYS_NET_ROOT=str(net),
               FAKE_CALLS=str(calls), SG_BOOT_ID_FILE=str(boot),
               HMG_SEOGAEMO_WATCH_MAX_POLLS="1", HMG_SEOGAEMO_WATCH_UPTIME_FILE=str(uptime))

    def poll(clock=100):
        uptime.write_text(f"{clock}.0 0.0\n")
        run(base / "svc/watcher.sh", env=env, timeout=120)
        return len(calls.read_text().splitlines())

    # First observation (even no devices) dispatches once; same-boot restart is quiet.
    assert poll() == 1
    assert poll() == 1
    device = usb / "1-1"
    device.mkdir()
    for name, value in (("idVendor", "0bda"), ("idProduct", "8179"), ("devnum", "2")):
        (device / name).write_text(value + "\n")
    assert poll() == 2
    assert poll() == 2
    # Replug entirely between polls changes devnum at the same USB port.
    (device / "devnum").write_text("3\n")
    assert poll() == 3
    (device / "idVendor").write_text("2357\n")
    assert poll() == 4
    (device / "idProduct").write_text("010c\n")
    assert poll() == 5
    iface = net / "rtwlan0"
    iface.mkdir()
    (iface / "ifindex").write_text("7\n")
    assert poll() == 6  # driver creates the owned interface after USB enumeration
    (iface / "flags").write_text("0x1003\n")
    other = net / "wlan0"
    other.mkdir()
    (other / "ifindex").write_text("22\n")
    assert poll() == 6  # neither link flags nor an unowned interface affects signature
    (iface / "ifindex").write_text("8\n")
    assert poll() == 7
    # Exact second owns_ifaces entry is observed too.
    (net / "usbnet0").mkdir()
    (net / "usbnet0/ifindex").write_text("23\n")
    assert poll() == 8
    # Unplug/replug while display stays on within one watcher process.
    script(base / "fake/sleep", f'''
if [ -f "{device}/idVendor" ]; then
    rm "{device}/idVendor" "{iface}/ifindex"
else
    echo 2357 > "{device}/idVendor"
    echo 9 > "{iface}/ifindex"
fi
''')
    env["HMG_SEOGAEMO_WATCH_MAX_POLLS"] = "3"
    assert poll() == 10
    env["HMG_SEOGAEMO_WATCH_MAX_POLLS"] = "1"
    # Failed event remains pending with an unchanged signature across restart,
    # desired-off and stock-pause periods. No success receipt until actual success.
    fail = state / "fail-watch"
    fail.touch()
    (device / "devnum").write_text("4\n")
    assert poll() == 11
    pending = state / "watch/usb.adapter"
    retry = state / "watch/retry.adapter.usb_change"
    assert pending.read_text() == "usb-boot"
    reserved = retry.read_text()
    assert poll(104) == 11 and retry.read_text() == reserved
    desired.write_text("off")
    assert poll(105) == 11 and retry.read_text() == reserved and pending.exists()
    desired.write_text("on")
    paused = state / "stock/paused"
    paused.touch()
    assert poll(105) == 11 and retry.read_text() == reserved and pending.exists()
    paused.unlink()
    fail.unlink()
    assert poll(105) == 12
    assert not pending.exists() and not retry.exists()
    assert poll(999) == 12
    # Each signature's six-attempt limit survives watcher restarts. New identity
    # or kernel boot resets its budget; successful same-boot restart stays quiet.
    fail.touch()
    (device / "devnum").write_text("5\n")
    for clock, count in ((1000, 13), (1004, 13), (1005, 14), (1015, 15),
                         (1035, 16), (1075, 17), (1135, 18), (9999, 18)):
        assert poll(clock) == count
        assert pending.exists()
    (device / "devnum").write_text("6\n")
    assert poll(10000) == 19
    assert retry.read_text().split()[1] == "1"
    boot.write_text("usb-next-boot\n")
    assert poll(10) == 20
    assert retry.read_text().split() == ["usb-next-boot", "1", "15"]
    fail.unlink()
    assert poll(15) == 21
    assert poll(20) == 21
    assert calls.read_text().splitlines() == ["adapter watch usb_change"] * 21


def test_reconcile_does_not_watch(temp):
    text = (ROOT / "nemesis/package/svc/reconcile.sh").read_text()
    assert " watch " not in text and "dumpsys" not in text


def test_noglob_and_changes_dedup(temp):
    base = temp / "noglob"
    state = base / "state"
    fake = base / "fake"
    for path in (state, fake, base / "modules"):
        path.mkdir(parents=True)
    (base / "modules/state.properties").write_text("owns_props=demo\n")
    script(fake / "getprop", 'cat "$FAKE_LIVE/$1" 2>/dev/null || true\n')
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"], FAKE_LIVE=str(base),
               HMG_SEOGAEMO_STATE=str(state), HMG_SEOGAEMO_BASE=str(base),
               SG_DATA_ROOT=str(base / "data"), SG_PROPERTY_ROOT=str(base / "backing"))
    common = ROOT / "nemesis/package/lib/common.sh"
    runner = base / "runner"
    script(runner, f'''
set -f
. "{common}"
make() {{
    mkdir -p "$HMG_SEOGAEMO_STATE/prop.demo" "$HMG_SEOGAEMO_STATE/file.k" "$HMG_SEOGAEMO_STATE/bind.x"
    : > "$HMG_SEOGAEMO_STATE/prop.demo/ready"; : > "$HMG_SEOGAEMO_STATE/file.k/ready"
    : > "$HMG_SEOGAEMO_STATE/build"; : > "$HMG_SEOGAEMO_STATE/changes"
}}
make
sg_restore_material || exit 1
sg_baseline_clear || exit 2
# The caller's noglob survives the runtime call.
case $- in *f*) ;; *) exit 3;; esac
if sg_restore_material; then exit 4; fi
set -- "$HMG_SEOGAEMO_STATE"/*
[ ! -e "$1" ] || exit 5
make
# A drifted property must still be seen by preflight under noglob.
mkdir -p "$HMG_SEOGAEMO_STATE/prop.drifted"
sg_write other > "$HMG_SEOGAEMO_STATE/prop.drifted/live"
sg_write ours > "$HMG_SEOGAEMO_STATE/prop.drifted/applied"
: > "$HMG_SEOGAEMO_STATE/prop.drifted/ready"
sg_write NEEV.KOR.0000.V039.001.260902 > "$HMG_SEOGAEMO_STATE/build"
sg_restore_preflight >/dev/null 2>&1 && exit 6
rm -rf "$HMG_SEOGAEMO_STATE"/prop.*
sg_changed prop demo; sg_changed prop demo; sg_changed file /x; sg_changed prop demo
[ "$(grep -c . "$HMG_SEOGAEMO_STATE/changes")" -eq 2 ] || exit 7
''')
    run(runner, env=env)
    assert (state / "changes").read_text() == "prop\tdemo\nfile\t/x\n"


def test_lint(temp):
    safe = temp / "modules/safe/root/safe.sh"
    script(safe, 'sg_prop_set demo value\n')
    lint = ROOT / "tools/lint-module-root.py"
    assert subprocess.run(["python3", str(lint), str(safe)], capture_output=True).returncode == 0
    script(safe, 'setprop demo value\n')
    assert subprocess.run(["python3", str(lint), str(safe)], capture_output=True).returncode != 0
    for body in ('sg_file_put /system/etc/private payload 0600 0:0\n',
                 'ASSET=/system/etc/hmg-seogaemo/test\nsg_file_put "$ASSET/private" payload 600 0:0\n'):
        script(safe, body)
        assert subprocess.run(["python3", str(lint), str(safe)], capture_output=True).returncode != 0
    script(safe, 'sg_file_put /system/etc/private payload 0600 0:0 # payload-mode: allow -- root-only boot secret\n')
    assert subprocess.run(["python3", str(lint), str(safe)], capture_output=True).returncode == 0
    for body in ('set -efu\n', 'set -f\n', 'set -o noglob\n', 'set -- $x\nset -f\nset -- $x\n'):
        script(safe, body)
        assert subprocess.run(["python3", str(lint), str(safe)], capture_output=True).returncode != 0, body
    for body in ('set -eu\n', 'set -f; set -- $line; set +f\n', "echo '-f'  # set -f\n"):
        script(safe, body)
        assert subprocess.run(["python3", str(lint), str(safe)], capture_output=True).returncode == 0, body
    package = temp / "nemesis/package/bin/bad.sh"
    lint = ROOT / "tools/lint-android44-shell.py"
    script(package, 'head -c 5 /tmp/file\n')
    assert subprocess.run(["python3", str(lint), str(package)], capture_output=True).returncode != 0
    for path in (safe, package):
        script(path, 'printf "%s\\n" value\n')
        assert subprocess.run(["python3", str(lint), str(path)], capture_output=True).returncode != 0


def test_module_build_hook(temp):
    base = temp / "build-hook"
    (base / "app/src").mkdir(parents=True)
    (base / "app/res").mkdir()
    hook = base / "modules/example/build/build.sh"
    script(hook, 'sg_write built > modules/example/payload-built\n')
    result = subprocess.run(["make", "-f", str(ROOT / "Makefile"), "module-build"],
                            cwd=base, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert (base / "modules/example/payload-built").read_text() == "built"


def test_remount_ro_busy(temp):
    base = temp / "remount-busy"
    state = base / "state"
    fake = base / "fake"
    state.mkdir(parents=True)
    script(fake / "nemesis", '''
echo "$*" >> "$FAKE_REMOUNTS"
[ "$1 $2" != "remount ro" ] || exit 16
''')
    runner = base / "runner"
    script(runner, '''
set -eu
# A busy /system must not fail a write that was already verified.
sg_remount_ro
# The raw call still reports the failure to callers that need it.
if sg_remount ro; then exit 1; fi
grep -Fq 'warning: /system stays read-write until restart' "$HMG_SEOGAEMO_STATE/module.log"
''')
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"], FAKE_REMOUNTS=str(base / "remounts"),
               HMG_SEOGAEMO_STATE=str(state))
    run(runner, env=env)
    assert (base / "remounts").read_text().splitlines() == ["remount ro", "remount ro"]


def test_system_directory_mode(temp):
    base = temp / "dir-mode"
    base.mkdir()
    runner = base / "runner"
    fake = base / "fake"
    fake_ownership(fake)
    script(fake / "getprop", "echo firmware\n")
    system = base / "system"
    namespace = system / "etc/hmg-seogaemo"
    (system / "etc").mkdir(parents=True)
    for module in ("a", "b"):
        manifest = base / "modules" / f"{module}.properties"
        manifest.parent.mkdir(exist_ok=True)
        manifest.write_text(f"owns_files={namespace}/{module}/recipes/audio.recipe\n")
    payload = base / "payload"
    payload.mkdir()
    (payload / "recipe").write_text("patch")
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               FAKE_OWNERS=str(base / "owners.json"), SG_TARGET_ROOT=str(base),
               SG_DATA_ROOT=str(base / "data"), HMG_SEOGAEMO_BASE=str(base),
               HMG_SEOGAEMO_STATE=str(base / "data/modules/a"), HMG_SEOGAEMO_MODULE_DIR=str(payload))
    def check(body, ok=True):
        script(runner, "set -eu\numask 077\n" + body)
        return run(runner, env=env, ok=ok)
    apply = f'sg_file_put "{namespace}/a/recipes/audio.recipe" recipe 0644 0:0\n'
    check(apply + f'sg_public_readable "{namespace}/a/recipes/audio.recipe"\n')
    for target in (namespace, namespace / "a", namespace / "a/recipes"):
        assert target.stat().st_mode & 0o777 == 0o755
    check(f'HMG_SEOGAEMO_STATE="{base}/data/modules/b"\nsg_file_put "{namespace}/b/recipes/audio.recipe" recipe 0644 0:0\n')
    check("sg_revert_all\n")
    assert namespace.is_dir() and not (namespace / "a").exists()
    check(f'HMG_SEOGAEMO_STATE="{base}/data/modules/b"\nsg_revert_all\n')
    assert not namespace.exists()
    # Legacy 0700 ancestors: preserve their real baseline and repair traversal.
    (namespace / "a/recipes").mkdir(parents=True)
    for target in (namespace, namespace / "a", namespace / "a/recipes"):
        target.chmod(0o700)
    check(f'chown 1000:1001 "{namespace}" "{namespace}/a" "{namespace}/a/recipes"\n')
    # Interrupted chown/chmod sequence recognizes only the journaled intermediate.
    check(f'chmod() {{ [ "$2" != "{namespace}" ] || return 1; command chmod "$@"; }}\nsg_payload_dirs "{namespace}/a/recipes/audio.recipe"\n', ok=False)
    check("sg_revert_all\n")
    check(f'[ "$(sg_file_meta "{namespace}")" = "0700 1000 1001" ]\n')
    check(apply)
    # Directory drift refuses before any file restores.
    (namespace / "a/recipes").chmod(0o711)
    result = check("sg_revert_all\n", ok=False)
    assert f"info.restore_conflict=dir preflight: {namespace}/a/recipes" in result.stdout
    result = check("sg_dirs_revert\n", ok=False)
    assert f"info.restore_conflict=dir restore: {namespace}/a/recipes" in result.stdout
    result = check(apply, ok=False)
    assert f"info.restore_conflict=dir apply: {namespace}/a/recipes" in result.stdout
    assert (namespace / "a/recipes/audio.recipe").read_text() == "patch"
    (namespace / "a/recipes").chmod(0o755)
    # Simulate loss after metadata restoration, before the restored marker.
    check("sg_remount_ro() { exit 77; }\nsg_dirs_revert\n", ok=False)
    assert (namespace / "a/recipes").stat().st_mode & 0o777 == 0o700
    check("sg_dirs_preflight\n")
    (namespace / "a/recipes").chmod(0o711)
    check("sg_dirs_preflight\n", ok=False)
    (namespace / "a/recipes").chmod(0o700)
    # A failed restored-marker write also remains resumable.
    check('sg_write() { case "$1" in 1) return 1;; *) printf "%s" "$1";; esac; }\nsg_dirs_revert\n', ok=False)
    check("sg_revert_all\n")
    for target in (namespace, namespace / "a", namespace / "a/recipes"):
        assert target.stat().st_mode & 0o777 == 0o700
        check(f'[ "$(sg_file_meta "{target}")" = "0700 1000 1001" ]\n')
    shutil.rmtree(namespace)
    # A failed file copy still leaves directory-only material for rollback.
    script(fake / "cp", '[ "$1" != "$HMG_SEOGAEMO_MODULE_DIR/recipe" ] || exit 1\n/bin/cp "$@"\n')
    check(apply, ok=False)
    check("sg_restore_material\n")
    check("sg_revert_all\n")
    check("sg_restore_material\n", ok=False)
    check("sg_revert_all\n")  # Empty restore remains idempotent.
    assert not namespace.exists()
    (fake / "cp").unlink()
    check(apply)
    (namespace / "a/recipes/unrelated").write_text("external")
    check("sg_revert_all\n", ok=False)
    assert list((base / "data/payload-dirs").glob("*/ready"))
    (namespace / "a/recipes/unrelated").unlink()
    check("sg_revert_all\n")
    assert not namespace.exists()
    # Ancestor symlink substitution never follows into another tree.
    outside = base / "outside"
    outside.mkdir()
    namespace.symlink_to(outside, target_is_directory=True)
    check(apply, ok=False)
    assert not list(outside.iterdir())


def test_stray_temporaries(temp):
    """Leftovers of interrupted atomic writes never block restore; look-alikes do."""
    base = temp / "strays"
    base.mkdir()
    runner = base / "runner"
    fake = base / "fake"
    fake_ownership(fake)
    script(fake / "getprop", "echo firmware\n")
    system = base / "system"
    namespace = system / "etc/hmg-seogaemo"
    (system / "etc").mkdir(parents=True)
    plain = base / "plain"
    plain.mkdir()
    (base / "modules").mkdir()
    (base / "modules/a.properties").write_text(
        f"owns_files={namespace}/a/recipes/audio.recipe,{plain}/file\n")
    payload = base / "payload"
    payload.mkdir()
    (payload / "recipe").write_text("patch")
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               FAKE_OWNERS=str(base / "owners.json"), SG_TARGET_ROOT=str(base),
               SG_DATA_ROOT=str(base / "data"), HMG_SEOGAEMO_BASE=str(base),
               HMG_SEOGAEMO_STATE=str(base / "data/modules/a"), HMG_SEOGAEMO_MODULE_DIR=str(payload))

    def check(body, ok=True):
        script(runner, "set -eu\numask 077\n" + body)
        return run(runner, env=env, ok=ok)

    apply = (f'sg_file_put "{namespace}/a/recipes/audio.recipe" recipe 0644 0:0\n'
             f'sg_file_put "{plain}/file" recipe 0644 0:0\n')
    check(apply)
    recipes = namespace / "a/recipes"
    # Names that only look like ours, or are not regular files, still block rmdir.
    blockers = ("x.hmg-seogaemo.12a", "x.hmg-seogaemo.", ".hmg-seogaemo.5", "x.hmg-seogaemo",
                "x.hmg-seogaemo.5.bak", "unrelated")
    for name in blockers:
        (recipes / name).write_text("external")
        result = check("sg_revert_all\n", ok=False)
        assert result.returncode == 3, (name, result.stdout)
        assert (recipes / name).read_text() == "external"
        (recipes / name).unlink()
    (recipes / "d.hmg-seogaemo.5").mkdir()
    check("sg_revert_all\n", ok=False)
    assert (recipes / "d.hmg-seogaemo.5").is_dir()
    (recipes / "d.hmg-seogaemo.5").rmdir()
    (recipes / "l.hmg-seogaemo.7").symlink_to(base / "outside")
    check("sg_revert_all\n", ok=False)
    assert (recipes / "l.hmg-seogaemo.7").is_symlink()
    (recipes / "l.hmg-seogaemo.7").unlink()
    # Our own interrupted temporaries are swept before the empty directory is removed.
    (recipes / "audio.recipe.hmg-seogaemo.4242").write_text("partial")
    (recipes / "other.hmg-seogaemo.7").write_text("partial")
    check("sg_revert_all\n")
    assert not namespace.exists()
    assert "temp_sweep" in (base / "data/ledger/ledger.tsv").read_text()
    # The same for a temporary beside an owned file in a directory that existed before.
    check(apply)
    (plain / "file.hmg-seogaemo.99").write_text("partial")
    (plain / "file.hmg-seogaemo.99x").write_text("kept")
    (plain / "neighbour.hmg-seogaemo.5").write_text("kept")
    check("sg_revert_all\n")
    assert not (plain / "file").exists() and not (plain / "file.hmg-seogaemo.99").exists()
    assert (plain / "file.hmg-seogaemo.99x").exists() and (plain / "neighbour.hmg-seogaemo.5").exists()
    # Leftover zygote journals: exact names inside the module state directory only.
    state = base / "data/modules/a"
    for name in ("zygote-prepare.4242", "zygote-retired.77"):
        (state / name).mkdir()
        (state / name / "f").write_text("x")
    for name in ("zygote-prepare.12a", "zygote-prepare", "zygote-retired.", "zygote-upgrade.5"):
        (state / name).mkdir()
    (state / "zygote-prepare.5").symlink_to(base / "outside")
    (base / "outside").mkdir()
    (base / "outside/keep").write_text("x")
    check("sg_zygote_sweep\n")
    assert not (state / "zygote-prepare.4242").exists() and not (state / "zygote-retired.77").exists()
    for name in ("zygote-prepare.12a", "zygote-prepare", "zygote-retired.", "zygote-upgrade.5"):
        assert (state / name).is_dir(), name
    assert (state / "zygote-prepare.5").is_symlink() and (base / "outside/keep").exists()
    (state / "zygote-prepare.88").mkdir()
    check("sg_revert_all\n")  # Even with nothing to restore.
    assert not (state / "zygote-prepare.88").exists()


def test_residue_cleanup(temp):
    """Generated app dirs, journal-less project dirs and our Dalvik cache entries."""
    base = temp / "residue"
    base.mkdir()
    runner = base / "runner"
    fake = base / "fake"
    fake_ownership(fake)
    script(fake / "getprop", "echo firmware\n")
    (base / "modules").mkdir()
    namespace = base / "system/etc/hmg-seogaemo"
    one = base / "data/data/com.example.one/app_hmg-seogaemo-wireless-runtime"
    two = base / "data/data/com.example.two/app_hmg-seogaemo-wireless-runtime"
    manifest = base / "modules/a.properties"

    def declare(dirs):
        manifest.write_text(
            "owns_files=/system/etc/hmg-seogaemo/a/recipes/x.recipe,/system/etc/hmg-seogaemo/a/y,/system/lib/other.so\n"
            f"owns_generated_dirs={dirs}\n")

    logical_one = "/data/data/com.example.one/app_hmg-seogaemo-wireless-runtime"
    logical_two = "/data/data/com.example.two/app_hmg-seogaemo-wireless-runtime"
    declare(f"{logical_one},{logical_two}")
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               FAKE_OWNERS=str(base / "owners.json"), SG_TARGET_ROOT=str(base),
               SG_DATA_ROOT=str(base / "ledgerroot"), HMG_SEOGAEMO_BASE=str(base),
               HMG_SEOGAEMO_STATE=str(base / "ledgerroot/modules/a"))

    def check(body, ok=True):
        script(runner, "set -eu\numask 077\n" + body)
        return run(runner, env=env, ok=ok)

    def populate(directory):
        directory.mkdir(parents=True)
        for name in ("p-1-2.txt", "p-1-2.log", "p-1-2.log.1", "p-3-4.txt.tmp"):
            (directory / name).write_text("generated")

    # Absent directories are fine; present ones are emptied and removed.
    check("sg_generated_dirs_remove\n")
    populate(one)
    populate(two)
    check("sg_generated_dirs_remove\n")
    assert not one.exists() and not two.exists()
    assert (base / "data/data/com.example.one").is_dir()
    assert (base / "ledgerroot/ledger/ledger.tsv").read_text().count("generated_dir_remove") == 2
    # Removal is advisory: it never fails, removes what it can, leaves anything unexpected
    # in place and records a cleanup marker for the next boot.
    marker = base / "ledgerroot/restart-cleanup/a"
    assert not marker.exists()
    env["SG_BOOT_ID_FILE"] = str(base / "boot-id")
    (base / "boot-id").write_text("boot-one\n")
    for unexpected in ("subdir", "link", "bad name", "many"):
        populate(one)
        populate(two)
        if unexpected == "subdir":
            (two / "nested").mkdir()
        elif unexpected == "link":
            (two / "link.txt").symlink_to(base / "outside")
        elif unexpected == "bad name":
            (two / "p 1.txt").write_text("x")
        else:
            for number in range(70):
                (two / f"f{number}.txt").write_text("x")
        check("sg_generated_dirs_remove\n")
        assert not one.exists(), unexpected
        assert two.is_dir() and (two / "p-1-2.txt").exists() == (unexpected == "many"), unexpected
        assert marker.read_text() == "boot-one"
        shutil.rmtree(two)
        # A pass that completes clears the marker again.
        check("sg_generated_dirs_remove\n")
        assert not marker.exists()
    # A symlinked data directory is never followed.
    (base / "outside").mkdir()
    (base / "outside/keep").write_text("x")
    one.parent.mkdir(parents=True, exist_ok=True)
    one.symlink_to(base / "outside", target_is_directory=True)
    check("sg_generated_dirs_remove\n")
    assert (base / "outside/keep").exists() and marker.exists()
    one.unlink()
    check("sg_generated_dirs_remove\n")
    assert not marker.exists()
    # Running hooks can still recreate the directories: removed now, retried after a restart.
    populate(one)
    (base / "ledgerroot/modules/a").mkdir(parents=True, exist_ok=True)
    (base / "ledgerroot/modules/a/assets-repaired-boot").write_text("boot-one")
    check("sg_generated_dirs_remove\n")
    assert not one.exists() and marker.read_text() == "boot-one"
    # Same boot: left alone (hooks may still write). A new boot retries and clears the marker.
    populate(one)
    check("sg_restart_cleanup_run\n")
    assert one.exists() and marker.exists()
    (base / "boot-id").write_text("boot-two\n")
    check("sg_restart_cleanup_run\n")
    assert not one.exists() and not marker.exists()
    assert not (base / "ledgerroot/restart-cleanup").exists()
    # What cannot be removed is retried at every later boot; an applied module is not touched.
    populate(one)
    (one / "nested").mkdir()
    marker.parent.mkdir()
    marker.write_text("boot-one")
    check("sg_restart_cleanup_run\n")
    assert one.exists() and not (one / "p-1-2.txt").exists() and marker.read_text() == "boot-two"
    shutil.rmtree(one)
    populate(one)
    (base / "ledgerroot/desired").mkdir(exist_ok=True)
    (base / "ledgerroot/desired/a").write_text("on")
    marker.write_text("boot-one")
    check("sg_restart_cleanup_run\n")
    assert (one / "p-1-2.txt").exists() and not marker.exists()
    (base / "ledgerroot/desired/a").write_text("off")
    shutil.rmtree(one)
    # Markers for unknown modules or odd names are discarded; strange declarations are ignored.
    marker.parent.mkdir(exist_ok=True)
    (marker.parent / "gone").write_text("boot-one")
    (marker.parent / "Bad.tmp.1").write_text("boot-one")
    check("sg_restart_cleanup_run\n")
    assert not marker.parent.exists()
    del env["SG_BOOT_ID_FILE"]
    # Only exact project-named app directories may be declared.
    declare("/data/data/com.example.one/not_ours")
    populate(base / "data/data/com.example.one/not_ours")
    check("sg_generated_dirs_remove\n")
    assert (base / "data/data/com.example.one/not_ours/p-1-2.txt").exists()
    declare(f"{logical_one},{logical_two}")

    # Legacy project directories: derived from owned paths, rmdir only, journals respected.
    (namespace / "a/recipes").mkdir(parents=True)
    (namespace / "a/recipes/foreign").write_text("kept")
    check("sg_legacy_dirs_cleanup\n")
    assert (namespace / "a/recipes/foreign").exists()
    (namespace / "a/recipes/foreign").unlink()
    (namespace.parent / "unrelated").mkdir()
    journal = base / "ledgerroot/payload-dirs"
    key = subprocess.run([SHELL, "-c", f'. "{ROOT / "nemesis/package/lib/common.sh"}"; sg_file_key "{namespace}"'],
                         env=car_env(env), capture_output=True, text=True).stdout.strip()
    (journal / key).mkdir(parents=True)
    (journal / key / "ready").write_text("1")
    check("sg_legacy_dirs_cleanup\n")
    assert not (namespace / "a").exists() and namespace.is_dir()
    assert (namespace.parent / "unrelated").is_dir()
    shutil.rmtree(journal)
    check("sg_legacy_dirs_cleanup\n")
    assert not namespace.exists() and (namespace.parent / "unrelated").is_dir()
    assert "legacy_dir_remove" in (base / "ledgerroot/ledger/ledger.tsv").read_text()
    # A symlinked namespace is left alone.
    (base / "elsewhere").mkdir()
    namespace.symlink_to(base / "elsewhere", target_is_directory=True)
    check("sg_legacy_dirs_cleanup\n")
    assert namespace.is_symlink() and (base / "elsewhere").is_dir()
    namespace.unlink()

    # Dalvik cache entries of our own jars, by exact derived name only.
    cache = base / "data/dalvik-cache"
    cache.mkdir(parents=True)
    ours = [
        "data@nemesis@apps@hmg-seogaemo@core@map@hmg-seogaemo-mapper.jar@classes.dex",
        "data@nemesis@apps@hmg-seogaemo@app@hmg-seogaemo.apk@classes.dex",
        "data@nemesis@apps@hmg-seogaemo@modules@wireless-carplay-and-aa.d@data@hmg-seogaemo-projection-runtime.jar@classes.dex",
        "data@nemesis@backup@hmg-seogaemo@update@current@core@map@hmg-seogaemo-mapper.jar@classes.dex",
        "data@nemesis@backup@hmg-seogaemo@update@versions@0.1.24@app@hmg-seogaemo.apk@classes.dex",
    ]
    others = [
        "system@framework@hmg-seogaemo-wireless-hook.jar@classes.dex",
        "data@nemesis@apps@hmg-seogaemo-evil@core@map@hmg-seogaemo-mapper.jar@classes.dex",
        "data@nemesis@apps@hmg-seogaemo@core@map@other.jar@classes.dex",
        "data@nemesis@apps@other@core@map@hmg-seogaemo-mapper.jar@classes.dex",
        "data@nemesis@apps@hmg-seogaemo@core@map@hmg-seogaemo-mapper.jar@classes.dex.bak",
        "data@app@com.seogaemo.hmg-1.apk@classes.dex",
    ]
    for name in ours + others:
        (cache / name).write_text("cache")
    (cache / "data@nemesis@apps@hmg-seogaemo@app@link.apk@classes.dex").symlink_to(base / "outside/keep")
    check("sg_legacy_dex_cleanup\n")
    assert not any((cache / name).exists() for name in ours)
    assert all((cache / name).exists() for name in others)
    assert (cache / "data@nemesis@apps@hmg-seogaemo@app@link.apk@classes.dex").is_symlink()
    assert (base / "outside/keep").exists()
    assert (base / "ledgerroot/ledger/ledger.tsv").read_text().count("dex_legacy_remove") == len(ours)

    # An applied OTA prunes the entries of versions that were removed, and only those.
    (base / "ledgerroot/update/versions/0.1.25").mkdir(parents=True)
    kept = [
        "data@nemesis@backup@hmg-seogaemo@update@versions@0.1.25@core@map@hmg-seogaemo-mapper.jar@classes.dex",
        "data@nemesis@backup@hmg-seogaemo@update@current@core@map@hmg-seogaemo-mapper.jar@classes.dex",
        "data@nemesis@backup@hmg-seogaemo@update@versions@0.1.23@core@map@other.jar@classes.dex",
        "data@nemesis@backup@hmg-seogaemo@update@versions@x1@app@hmg-seogaemo.apk@classes.dex",
        "data@nemesis@backup@other@update@versions@0.1.23@app@hmg-seogaemo.apk@classes.dex",
    ]
    gone = [
        "data@nemesis@backup@hmg-seogaemo@update@versions@0.1.23@core@map@hmg-seogaemo-mapper.jar@classes.dex",
        "data@nemesis@backup@hmg-seogaemo@update@versions@0.1.24@app@hmg-seogaemo.apk@classes.dex",
        "data@nemesis@backup@hmg-seogaemo@update@versions@0.1.24@modules@wireless-carplay-and-aa.d@data@hmg-seogaemo-projection-runtime.jar@classes.dex",
    ]
    for name in kept + gone:
        (cache / name).write_text("cache")
    check(f'sg_update_dex_prune "{base}/ledgerroot/update/versions"\n')
    assert not any((cache / name).exists() for name in gone)
    assert all((cache / name).exists() for name in kept)

    # Private VM cache of the mapper and update verifier.
    vm = base / "ledgerroot/core/vm"
    (vm / "dalvik-cache").mkdir(parents=True)
    (vm / "dalvik-cache/entry").write_text("cache")
    for leftover in ("vm.status.4242", "vm.status.7"):
        (base / "ledgerroot/core" / leftover / "dalvik-cache").mkdir(parents=True)
    (base / "ledgerroot/core/vm.status.abc").mkdir()
    (base / "ledgerroot/core/vm.statusX").mkdir()
    check("sg_vm_cleanup\n")
    assert not vm.exists() and (base / "ledgerroot/core").is_dir()
    assert not list((base / "ledgerroot/core").glob("vm.status.[0-9]*"))
    assert (base / "ledgerroot/core/vm.status.abc").is_dir() and (base / "ledgerroot/core/vm.statusX").is_dir()
    (base / "ledgerroot/core/vm.status.abc").rmdir()
    (base / "ledgerroot/core/vm.statusX").rmdir()
    (base / "ledgerroot/core").rmdir()
    (base / "ledgerroot/core").symlink_to(base / "outside", target_is_directory=True)
    (base / "outside/vm").mkdir()
    check("sg_vm_cleanup\n", ok=False)
    assert (base / "outside/vm").is_dir()


def test_public_readable(temp):
    base = temp / "public-bits"
    directory = base / "parent"
    directory.mkdir(parents=True)
    target = directory / "recipe"
    target.write_text("patch")
    runner = base / "runner"
    env = dict(os.environ, SG_TARGET_ROOT=str(base))
    # All low permission digits: owner/group bits must never imply public access.
    for digit in range(8):
        target.chmod(0o660 + digit)
        script(runner, f'sg_public_readable "{target}"\n')
        run(runner, env=env, ok=digit >= 4)
    target.chmod(0o664)
    for digit in range(8):
        directory.chmod(0o770 + digit)
        run(runner, env=env, ok=bool(digit & 1))
    directory.chmod(0o755)


def test_file_metadata_guards(temp):
    base = temp / "file-metadata"
    fake = base / "fake"
    fake_ownership(fake)
    script(fake / "getprop", "echo firmware\n")
    (base / "modules").mkdir()
    target = base / "target"
    target.write_text("stock")
    payload = base / "payload"
    payload.mkdir()
    (payload / "new").write_text("ours")
    (base / "modules/a.properties").write_text(f"owns_props=demo\nowns_files={target}\n")
    backing = base / "property"
    backing.mkdir()
    (backing / "demo").write_bytes(b"stock backing\x00")
    (backing / "demo").chmod(0o600)
    script(fake / "getprop", 'if [ "$1" = demo ]; then cat "$SG_PROPERTY_ROOT/live" 2>/dev/null || :; else echo firmware; fi\n')
    script(fake / "setprop", 'sg_write "$2" > "$SG_PROPERTY_ROOT/live"\n')
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               FAKE_OWNERS=str(base / "owners.json"), SG_DATA_ROOT=str(base / "data"),
               SG_PROPERTY_ROOT=str(backing),
               HMG_SEOGAEMO_BASE=str(base), HMG_SEOGAEMO_STATE=str(base / "data/modules/a"),
               HMG_SEOGAEMO_MODULE_DIR=str(payload))
    runner = base / "runner"
    script(runner, f'''
set -eu
chown 1000:1001 "$SG_PROPERTY_ROOT/demo"
sg_prop_set demo ours
chmod 0644 "$SG_PROPERTY_ROOT/demo"
chown 0:0 "$SG_PROPERTY_ROOT/demo"
sg_prop_restore demo
[ "$(sg_file_meta "$SG_PROPERTY_ROOT/demo")" = "0600 1000 1001" ]
sg_file_put "{target}" new 0644 0:0
chmod 0600 "{target}"
if sg_applied "{target}"; then exit 1; fi
if sg_restore_preflight; then exit 1; fi
if sg_file_restore "{target}"; then exit 1; fi
if sg_file_put "{target}" new 0644 0:0; then exit 1; fi
if sg_file_delete "{target}"; then exit 1; fi
chmod 0644 "{target}"
chown 1000:1000 "{target}"
if sg_applied "{target}"; then exit 1; fi
if sg_revert_all; then exit 1; fi
chown 0:0 "{target}"
rm "$HMG_SEOGAEMO_STATE/file.$(sg_file_key "{target}")/applied-meta"
sg_applied "{target}"
[ -f "$HMG_SEOGAEMO_STATE/file.$(sg_file_key "{target}")/applied-meta" ]
sg_revert_all
# A chown that lies must fail before replacing the live file.
chown() {{ :; }}
if sg_file_put "{target}" new 0644 1000:1000; then exit 1; fi
[ "$(cat "{target}")" = stock ]
chown() {{ return 1; }}
if sg_file_put "{target}" new 0644 0:0; then exit 1; fi
[ "$(cat "{target}")" = stock ]
''')
    result = run(runner, env=env)
    for stage in ("preflight", "restore", "apply", "delete"):
        assert f"info.restore_conflict=file {stage}: {target}" in result.stdout


def test_zygote_and_dex(temp):
    base = temp / "zygote"
    state = base / "data/nemesis/backup/hmg-seogaemo/modules/wireless-carplay-and-aa"
    target = base / "target"
    payload = base / "payload"
    manifest = base / "modules/wireless-carplay-and-aa.properties"
    for folder in (state, target / "system/bin", target / "system/lib",
                   target / "system/framework", target / "data/dalvik-cache",
                   payload, manifest.parent, base / "fake", base / "live"):
        folder.mkdir(parents=True, exist_ok=True)
    paths = [target / "system/bin/app_process",
             target / "system/bin/app_process.hmg-seogaemo-stock",
             target / "system/lib/libhmg_seogaemo_wireless_hook.so",
             target / "system/framework/hmg-seogaemo-wireless-hook.jar"]
    guards = [state / name for name in ("enable", "enabled", "starts", "disable")]
    paths[0].write_bytes(b"stock-executable")
    paths[0].chmod(0o755)
    (payload / "wrapper").write_bytes(b"wrapper")
    (payload / "loader").write_bytes(b"loader")
    (payload / "jar").write_bytes(b"jar")
    for source in payload.iterdir():
        source.chmod(0o644)
    manifest.write_text("owns_props=\nowns_files=" + ",".join(map(str, paths + guards)) +
                        "\nservices=\n")
    live = base / "live"
    (live / "ro.build.product").write_text("NEEV.KOR.260902")
    fake = base / "fake"
    script(fake / "getprop", 'cat "$FAKE_LIVE/$1" 2>/dev/null || true\n')
    fake_ownership(fake)
    cache = target / "data/dalvik-cache/system@framework@hmg-seogaemo-wireless-hook.jar@classes.dex"
    cache.write_bytes(b"previous-cache")
    app_dir = target / "data/data/com.daudio.app.dipo/app_hmg-seogaemo-wireless-dex"
    boot_id = base / 'boot-id'
    boot_id.write_text('test-boot')
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               SG_DATA_ROOT=str(base / "data/nemesis/backup/hmg-seogaemo"),
               SG_TARGET_ROOT=str(target), HMG_SEOGAEMO_STATE=str(state),
               HMG_SEOGAEMO_BASE=str(base), HMG_SEOGAEMO_MODULE_DIR=str(payload),
               FAKE_OWNERS=str(base / "owners.json"), FAKE_LIVE=str(live),
               SG_BOOT_ID_FILE=str(boot_id))
    common = ROOT / "nemesis/package/lib/common.sh"
    runner = base / "run-zygote"
    script(runner, f'''
set -eu
. "{common}"
sg_dex_cache_track /system/framework/hmg-seogaemo-wireless-hook.jar com.daudio.app.dipo
sg_zygote_install wrapper loader jar
[ "$(cat "{paths[1]}")" = stock-executable ]
[ -x "{paths[1]}" ]
[ "$(cat "{paths[0]}")" = wrapper ]
[ -x "{paths[0]}" ]
sg_write 3 > "{guards[2]}"
sg_write generated > "{cache}"
mkdir -p "{app_dir}"
sg_write generated > "{app_dir / 'classes.dex'}"
sg_revert_all
[ "$(cat "{paths[0]}")" = stock-executable ]
[ ! -e "{paths[1]}" ] && [ ! -e "{paths[2]}" ] && [ ! -e "{paths[3]}" ]
[ ! -e "{guards[0]}" ] && [ ! -e "{guards[1]}" ] && [ ! -e "{guards[2]}" ] && [ ! -e "{guards[3]}" ]
[ "$(cat "{cache}")" = previous-cache ]
[ ! -e "{app_dir}" ]
''')
    run(runner, env=env)
    ledger = base / "data/nemesis/backup/hmg-seogaemo/ledger/ledger.tsv"
    assert "zygote_starts" in ledger.read_text()
    assert "dex_generated" in ledger.read_text()
    # A failure at the final wrapper copy must leave stock executable intact.
    script(fake / "cp", '''
if [ "$1" = "$FAIL_SOURCE" ]; then exit 1; fi
/bin/cp "$@"
''')
    rollback_env = dict(env, FAIL_SOURCE=str(payload / "wrapper"))
    script(runner, f'''
set -eu
. "{common}"
if sg_zygote_install wrapper loader jar; then exit 1; fi
[ "$(cat "{paths[0]}")" = stock-executable ]
[ ! -e "{paths[1]}" ] && [ ! -e "{paths[2]}" ] && [ ! -e "{paths[3]}" ]
''')
    run(runner, env=rollback_env)
    (fake / "cp").unlink()
    # A -> B retains the first stock baseline and invalidates both dex namespaces.
    paths[2].write_bytes(b'original-loader')
    paths[3].write_bytes(b'original-jar')
    paths[2].chmod(0o640)
    paths[3].chmod(0o600)
    install = ('set -eu\nsg_dex_cache_track /system/framework/hmg-seogaemo-wireless-hook.jar '
               'com.daudio.app.dipo\nsg_zygote_install wrapper loader jar\n')
    script(runner, install)
    run(runner, env=env)
    app_dir.mkdir(parents=True, exist_ok=True)
    generated = app_dir / 'classes.dex'
    cache.write_bytes(b'A-cache')
    generated.write_bytes(b'A-app-cache')
    for name in ('wrapper', 'loader', 'jar'):
        (payload / name).write_bytes((name + '-B').encode())
    deferred = run(runner, env=dict(env, HMG_SEOGAEMO_UPDATE_HEALTH='1'))
    assert 'info.hook_upgrade=deferred until update is finalized' in deferred.stdout
    assert paths[0].read_bytes() == b'wrapper' and paths[2].read_bytes() == b'loader'
    assert cache.read_bytes() == b'A-cache' and generated.read_bytes() == b'A-app-cache'
    assert not (state / 'zygote-upgrade').exists()
    # USB postinstall uses ordinary reconcile (no health window), so advances.
    run(runner, env=env)
    assert [p.read_bytes() for p in paths] == [b'wrapper-B', b'stock-executable', b'loader-B', b'jar-B']
    assert not cache.exists() and not generated.exists()
    assert (state / 'assets-repaired-boot').exists()
    assert 'zygote_upgrade' in ledger.read_text() and 'dex_invalidate' in ledger.read_text()
    cache.write_bytes(b'B-cache')
    run(runner, env=env)
    assert cache.read_bytes() == b'B-cache'
    # The conservative rollback policy must retain the selected package and
    # these actual B system bytes/caches until projection is restored first.
    updater_base = base / 'updater'
    (updater_base / 'core').mkdir(parents=True)
    (updater_base / 'lib').mkdir()
    (updater_base / 'lib/common.sh').write_text(common.read_text())
    (updater_base / 'NEMESIS.data').write_text('package-version=0.1.0\n')
    update_state = Path(env['SG_DATA_ROOT']) / 'update'
    update_state.mkdir()
    (update_state / 'current').symlink_to(payload)
    updater = updater_base / 'core/update.sh'
    updater.write_text(host_shell_script((ROOT / 'nemesis/package/core/update.sh').read_text())
                       .replace('state=/data/nemesis/backup/hmg-seogaemo',
                                'state=' + env['SG_DATA_ROOT']))
    blocked = subprocess.run([SHELL, str(updater), 'rollback'], env=car_env(env),
                             capture_output=True, text=True)
    assert blocked.returncode != 0 and 'rollback blocked' in blocked.stderr
    assert (update_state / 'current').resolve() == payload.resolve()
    assert [p.read_bytes() for p in paths] == [b'wrapper-B', b'stock-executable', b'loader-B', b'jar-B']
    assert cache.read_bytes() == b'B-cache'

    # Kill after loader/JAR commit but before wrapper commit, then resume.
    for name in ('wrapper', 'loader', 'jar'):
        (payload / name).write_bytes((name + '-C').encode())
    generated.write_bytes(b'B-app-cache')
    # First interrupt immediately after cache deletion, before its applied
    # absence marker. Retry must finalize this now-missing path as well.
    script(fake / 'rm', f'''
/bin/rm "$@" || exit 1
if [ "${{2:-}}" = "{generated}" ]; then kill -KILL "$PPID"; fi
''')
    run(runner, env=env, ok=False)
    (fake / 'rm').unlink()
    assert not cache.exists() and not generated.exists() and paths[0].read_bytes() == b'wrapper-B'
    script(fake / 'cp', f'''
if [ "$1" = "{state}/zygote-upgrade/$(sg_file_key "{paths[0]}")/next" ]; then
    kill -KILL "$PPID"
    exit 1
fi
exec /bin/cp "$@"
''')
    run(runner, env=env, ok=False)
    assert paths[0].read_bytes() == b'wrapper-B'
    assert paths[2].read_bytes() == b'loader-C' and paths[3].read_bytes() == b'jar-C'
    assert (state / 'zygote-upgrade/ready').exists()
    (fake / 'cp').unlink()
    (payload / 'wrapper').write_bytes(b'unrelated-selected-wrapper')
    blocked = run(runner, env=env, ok=False)
    assert blocked.returncode == 3 and 'resume selected projection payload' in blocked.stdout
    assert paths[0].read_bytes() == b'wrapper-B'
    (payload / 'wrapper').write_bytes(b'wrapper-C')
    run(runner, env=dict(env, HMG_SEOGAEMO_UPDATE_HEALTH='1',
                         HMG_SEOGAEMO_PROJECTION_ROLLBACK_GUARD='1'))
    assert paths[0].read_bytes() == b'wrapper-C'
    assert not (state / 'zygote-upgrade').exists()
    script(runner, f'set -eu\nsg_file_applied "{cache}"\nsg_file_applied "{generated}"\n')
    run(runner, env=env)
    script(runner, install)

    # Kill after wrapper rename but before its applied marker; restore accepts
    # only journaled bytes/metadata and returns exactly to original stock.
    for name in ('wrapper', 'loader', 'jar'):
        (payload / name).write_bytes((name + '-D').encode())
    script(fake / 'mv', f'''
/bin/mv "$@" || exit 1
if [ "$2" = "{paths[0]}" ]; then kill -KILL "$PPID"; fi
''')
    run(runner, env=env, ok=False)
    (fake / 'mv').unlink()
    assert paths[0].read_bytes() == b'wrapper-D'
    script(runner, 'set -eu\nsg_restore_preflight\nsg_revert_all\n')
    run(runner, env=env)
    assert paths[0].read_bytes() == b'stock-executable'
    assert paths[0].stat().st_mode & 0o777 == 0o755
    assert not paths[1].exists()
    assert paths[2].read_bytes() == b'original-loader' and paths[2].stat().st_mode & 0o777 == 0o640
    assert paths[3].read_bytes() == b'original-jar' and paths[3].stat().st_mode & 0o777 == 0o600
    assert cache.read_bytes() == b'previous-cache' and not app_dir.exists()
    assert not (state / 'zygote-upgrade').exists()
    for name in ('wrapper', 'loader', 'jar'):
        (payload / name).write_bytes(name.encode())
    # A drifted runtime must block the entire restore before app_process changes.
    script(runner, f'''
set -eu
. "{common}"
sg_zygote_install wrapper loader jar
sg_write external > "{paths[2]}"
if sg_revert_all; then exit 1; fi
[ "$(cat "{paths[0]}")" = wrapper ]
[ -x "{paths[0]}" ]
[ "$(cat "{paths[1]}")" = stock-executable ]
''')
    run(runner, env=env)
    (payload / 'wrapper').write_bytes(b'next-wrapper')
    script(runner, 'sg_zygote_install wrapper loader jar\n')
    result = run(runner, env=env, ok=False)
    assert result.returncode == 3 and 'payload drift' in result.stdout
    assert paths[0].read_bytes() == b'wrapper' and paths[2].read_bytes() == b'external'


def test_zygote_foreign(temp):
    """An app_process swap without an ownership record is a conflict, never stock."""
    import hashlib
    base = temp / "foreign"
    state = base / "data/nemesis/backup/hmg-seogaemo/modules/wireless-carplay-and-aa"
    target = base / "target"
    payload = base / "payload"
    manifest = base / "modules/wireless-carplay-and-aa.properties"
    for folder in (state, target / "system/bin", target / "system/lib", target / "system/framework",
                   payload, manifest.parent, base / "fake", base / "live"):
        folder.mkdir(parents=True, exist_ok=True)
    stock_md5 = hashlib.md5(b"stock-executable").hexdigest()
    paths = [target / "system/bin/app_process",
             target / "system/bin/app_process.hmg-seogaemo-stock",
             target / "system/lib/libhmg_seogaemo_wireless_hook.so",
             target / "system/framework/hmg-seogaemo-wireless-hook.jar"]
    guards = [state / name for name in ("enable", "enabled", "starts", "disable")]
    paths[0].write_bytes(b"stock-executable")
    paths[0].chmod(0o755)
    for name, data in (("wrapper", b"wrapper"), ("loader", b"loader"), ("jar", b"jar")):
        (payload / name).write_bytes(data)
        (payload / name).chmod(0o644)

    def write_manifest(known=True, owner=True):
        text = "owns_props=\nservices=\n"
        if owner:
            text += "owns_files=" + ",".join(map(str, paths + guards)) + "\n"
        if known:
            text += f"known_stock.1=NEEV.KOR.*.260902:/system/bin/app_process:{stock_md5}\n"
        manifest.write_text(text)

    write_manifest()
    live = base / "live"
    (live / "ro.build.product").write_text("NEEV.KOR.0000.V039.001.260902")
    fake = base / "fake"
    script(fake / "getprop", 'cat "$FAKE_LIVE/$1" 2>/dev/null || true\n')
    fake_ownership(fake)
    boot_id = base / "boot-id"
    boot_id.write_text("test-boot")
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"],
               SG_DATA_ROOT=str(base / "data/nemesis/backup/hmg-seogaemo"),
               SG_TARGET_ROOT=str(target), HMG_SEOGAEMO_STATE=str(state),
               HMG_SEOGAEMO_BASE=str(base), HMG_SEOGAEMO_MODULE_DIR=str(payload),
               FAKE_OWNERS=str(base / "owners.json"), FAKE_LIVE=str(live),
               SG_BOOT_ID_FILE=str(boot_id))
    runner = base / "runner"

    def check(body, ok=True):
        script(runner, "set -eu\n" + body)
        return run(runner, env=env, ok=ok)

    # Genuine stock, or no known build for this product: nothing to refuse.
    check("sg_zygote_foreign\nsg_revert_all\n")
    paths[0].write_bytes(b"something else")
    (live / "ro.build.product").write_text("OTHER.KOR.0000.V039.001.260902")
    check("sg_zygote_foreign\nsg_revert_all\n")
    (live / "ro.build.product").write_text("NEEV.KOR.0000.V039.001.260902")
    # An unknown executable with no owner is refused by every revert entry point.
    for body in ("sg_zygote_foreign\n", "sg_revert_all\n"):
        result = check(body, ok=False)
        assert result.returncode == 3 and "info.restore_conflict=app_process is not the known stock build" in result.stdout
    assert paths[0].read_bytes() == b"something else"
    paths[0].write_bytes(b"stock-executable")
    # Our files without any record: the stock backup and each hook file count.
    for leftover in (paths[1], paths[2], paths[3]):
        leftover.write_bytes(b"x")
        for body in ("sg_zygote_foreign\n", "sg_revert_all\n"):
            result = check(body, ok=False)
            assert result.returncode == 3 and "without ownership record" in result.stdout, (leftover, result)
        assert leftover.read_bytes() == b"x" and paths[0].read_bytes() == b"stock-executable"
        leftover.unlink()
    # Every offender is listed on one line, the unknown executable included.
    for leftover in paths[1:]:
        leftover.write_bytes(b"x")
    paths[0].write_bytes(b"something else")
    result = check("sg_zygote_foreign\n", ok=False)
    lines = [line for line in result.stdout.splitlines() if line.startswith("info.restore_conflict=")]
    assert result.returncode == 3 and len(lines) == 1, result.stdout
    for needle in ("app_process.hmg-seogaemo-stock", "libhmg_seogaemo_wireless_hook.so",
                   "hmg-seogaemo-wireless-hook.jar", "not the known stock build"):
        assert needle in lines[0], (needle, lines)
    paths[0].write_bytes(b"stock-executable")
    for leftover in paths[1:]:
        leftover.unlink()
    # The wrapper's guard state alone is no evidence: the guard passes, and restore
    # sweeps exactly those names (ledger row each) while leaving other files alone.
    for guard in guards:
        guard.write_bytes(b"3")
    (state / "keep").write_bytes(b"k")
    check("sg_zygote_foreign\n")
    assert all(guard.exists() for guard in guards)
    check("sg_zygote_foreign\nsg_revert_all\n")
    assert not any(guard.exists() for guard in guards) and (state / "keep").exists()
    assert paths[0].read_bytes() == b"stock-executable"
    ledger = (base / "data/nemesis/backup/hmg-seogaemo/ledger/ledger.tsv").read_text()
    assert ledger.count("zygote_guard_sweep") == 4, ledger
    (state / "keep").unlink()
    # No hook files and stock app_process: only the guard state is swept even when it
    # is the only thing present; an unrecorded real swap evidence still wins over it.
    guards[0].write_bytes(b"1")
    paths[1].write_bytes(b"x")
    assert check("sg_revert_all\n", ok=False).returncode == 3 and guards[0].exists()
    paths[1].unlink()
    guards[0].unlink()
    # A directory in place of a guard file is not ours: conflict, nothing removed.
    guards[2].mkdir()
    guards[3].write_bytes(b"x")
    assert check("sg_revert_all\n", ok=False).returncode == 3 and guards[3].exists()
    guards[2].rmdir()
    guards[3].unlink()
    # A symlink in place of our file is also foreign.
    paths[1].symlink_to(base / "nowhere")
    assert check("sg_zygote_foreign\n", ok=False).returncode == 3
    paths[1].unlink()
    # A module that does not own app_process never reports the swap.
    write_manifest(owner=False)
    paths[1].write_bytes(b"x")
    check("sg_zygote_foreign\n")
    paths[1].unlink()
    write_manifest()
    # Once the swap is recorded the normal guarded restore owns it, wrapper bytes included.
    check("sg_zygote_install wrapper loader jar\nsg_zygote_foreign\n")
    assert paths[0].read_bytes() == b"wrapper"
    check("sg_zygote_foreign\nsg_revert_all\n")
    assert paths[0].read_bytes() == b"stock-executable" and not paths[1].exists()
    check("sg_zygote_foreign\n")
    # The live wrapper recreates `starts` after the revert (watcher, O_CREAT), and the
    # documented manual `touch disable` is also left behind: restore must still pass,
    # report the pending restart (this boot) and sweep them instead of blocking.
    check("sg_restart_pending\n")
    guards[2].write_bytes(b"0")
    guards[3].write_bytes(b"")
    check("sg_zygote_foreign\nsg_revert_all\n")
    assert not guards[2].exists() and not guards[3].exists()
    check("sg_restart_pending\n")
    boot_id.write_text("another-boot")
    assert check("sg_restart_pending\n", ok=False).returncode != 0
    boot_id.write_text("test-boot")
    # Only an unrecorded swap (state wiped) is refused: restoring cannot proceed.
    check("sg_zygote_install wrapper loader jar\n")
    for entry in state.glob("file.*"):
        shutil.rmtree(entry)
    result = check("sg_revert_all\n", ok=False)
    assert result.returncode == 3 and paths[0].read_bytes() == b"wrapper" and paths[1].read_bytes() == b"stock-executable"


def test_kill_tree(temp):
    """Every process of a live tree, TERM-ignoring ones included, is signalled and dies."""
    base = temp / 'kill-tree'
    base.mkdir()
    # Each node records its own PID, optionally starts a child node and then idles
    # without ever exiting by itself (bounded to 40 seconds so a failure cleans up).
    idle = 'i=0\nwhile [ "$i" -lt 40 ]; do sleep 1; i=$((i + 1)); done\n'
    (base / 'leaf.sh').write_text(host_shell_script(
        '#!/bin/sh\ntrap "" TERM\necho $$ > "$T/leaf"\n' + idle))
    (base / 'mid.sh').write_text(host_shell_script(
        '#!/bin/sh\ntrap "" TERM\necho $$ > "$T/mid"\n' + SHELL + ' "$T/leaf.sh" &\n' + idle))
    (base / 'side.sh').write_text(host_shell_script(
        '#!/bin/sh\necho $$ > "$T/side"\n' + idle))
    (base / 'top.sh').write_text(host_shell_script(
        '#!/bin/sh\necho $$ > "$T/top"\n' + SHELL + ' "$T/mid.sh" &\n' + SHELL + ' "$T/side.sh" &\n' + idle))
    runner = base / 'runner'
    script(runner, f'''
set -eu
T={base}; export T
{SHELL} "$T/top.sh" < /dev/null > /dev/null 2>&1 &
top=$!
tries=0
while [ ! -s "$T/leaf" ] || [ ! -s "$T/mid" ] || [ ! -s "$T/side" ] || [ ! -s "$T/top" ]; do
    tries=$((tries + 1)); [ "$tries" -lt 100 ] || exit 9
    sleep 1
done
# Tree: top with children mid (ignores TERM) and side; leaf (ignores TERM) below mid.
sg_kill_tree "$top" 5
''')
    result = subprocess.run([SHELL, str(runner)], env=car_env(), text=True, capture_output=True, timeout=60)
    assert result.returncode == 0, (result.stdout, result.stderr)
    for name in ('top', 'mid', 'leaf', 'side'):
        pid = int((base / name).read_text())
        for _ in range(20):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.2)
        else:
            raise AssertionError(f'{name} process {pid} survived sg_kill_tree')
    # Invalid targets are refused without signalling anything.
    script(runner, 'for bad in "" abc 0 1 "1 2"; do if sg_kill_tree "$bad"; then exit 1; fi; done\n')
    run(runner, env=os.environ)


def test_update_signal(temp):
    """A signal to the updater ends the verifier VM (even one ignoring TERM) and frees the lock."""
    import hashlib
    base = temp / "update-signal"
    package_root = base / "package"
    state = base / "state"
    incoming = base / "download"
    fake = base / "fake"
    for folder in (package_root / "core", package_root / "lib", package_root / "app", incoming / "payload", fake):
        folder.mkdir(parents=True)
    shutil.copy(ROOT / "nemesis/package/lib/common.sh", package_root / "lib/common.sh")
    (package_root / "NEMESIS.data").write_text("package-version=0.1.0\n")
    (package_root / "app/hmg-seogaemo.apk").write_bytes(b"apk")
    updater = (ROOT / "nemesis/package/core/update.sh").read_text()
    updater = updater.replace("state=/data/nemesis/backup/hmg-seogaemo", "state=" + str(state))
    updater = updater.replace("input=/data/data/com.seogaemo.hmg/files/update", "input=" + str(incoming))
    (package_root / "core/update.sh").write_text(host_shell_script(updater))
    names = ("VERSION", "modules.list", "modules.graph", "modules.lines")
    lines = ""
    for name in names + ("app/hmg-seogaemo.apk",):
        target = incoming / "payload" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("test\n")
        lines += hashlib.md5(target.read_bytes()).hexdigest() + "|" + name + "\n"
    (incoming / "payload/files.md5").write_text(lines)
    # The verifier ignores TERM and spawns a helper, like a wedged Dalvik VM.
    script(fake / "app_process", '''
trap "" TERM
sg_write "$$" > "$UPDATE_TEST_PIDS"
sleep 40 &
sg_write " $!" >> "$UPDATE_TEST_PIDS"
i=0
while [ "$i" -lt 40 ]; do sleep 1; i=$((i + 1)); done
''')
    pids = base / "pids"
    env = car_env(dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"], UPDATE_TEST_PIDS=str(pids)))
    process = subprocess.Popen([SHELL, str(package_root / "core/update.sh"), "stage"], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(100):
        if pids.exists() and " " in pids.read_text():
            break
        time.sleep(0.1)
    else:
        process.kill()
        raise AssertionError("fake verifier never started")
    assert (state / ".lock").is_dir()
    process.terminate()
    process.communicate(timeout=30)
    assert process.returncode != 0
    for pid in pids.read_text().split():
        for _ in range(30):
            try:
                os.kill(int(pid), 0)
            except ProcessLookupError:
                break
            time.sleep(0.2)
        else:
            raise AssertionError(f"verifier process {pid} survived the signal")
    assert not (state / ".lock").exists()
    assert not list((state / "update").glob("java-out.*"))


def test_projection_reader_vm(temp):
    base = temp / 'projection-reader'
    state = base / 'state/modules/wireless-carplay-and-aa'
    payload = base / 'payload'
    target = base / 'target'
    for directory in (state, payload / 'files', base / 'modules', target / 'system/bin'):
        directory.mkdir(parents=True)
    (base / 'modules/wireless-carplay-and-aa.properties').write_text('owns_files=/system/bin/app_process\n')
    (payload / 'files/hmg-seogaemo-projection-runtime.jar').write_bytes(b'reader')
    process = target / 'system/bin/app_process.hmg-seogaemo-stock'
    script(process, '''
set -eu
[ "$1" = /system/bin ]
[ "$2" = com.seogaemo.hmg.runtime.HmgSeogaemoProjectionRuntime ]
[ "$4" = "$SG_DATA_ROOT" ]
[ "$ANDROID_DATA" = "$SG_DATA_ROOT/runtime/wireless-carplay-and-aa/vm" ]
[ -d "$ANDROID_DATA/dalvik-cache" ]
[ "$BOOTCLASSPATH" = /system/framework/core.jar ]
sg_write "$3" > "$SG_DATA_ROOT/invoked"
case "$3" in
    clear) ;;
    *) sg_print state=on restart=none detail=ready ;;
esac
''')
    env = dict(os.environ, HMG_SEOGAEMO_BASE=str(base), HMG_SEOGAEMO_STATE=str(state),
               HMG_SEOGAEMO_MODULE_DIR=str(payload), SG_DATA_ROOT=str(base / 'state'),
               SG_TARGET_ROOT=str(target), BOOTCLASSPATH='/system/framework/core.jar')
    runner = base / 'runner'
    # Host UID differs from root; exercise the real path/mode/launch checks
    # with deterministic KitKat metadata and owner mutation.
    preamble = 'set -eu\nsg_file_meta() { echo 0700 0 0; }\nchown() { :; }\n'
    script(runner, preamble + 'sg_projection_runtime prepare\nsg_projection_runtime status\n')
    result = run(runner, env=env)
    assert 'state=on' in result.stdout and 'detail=ready' in result.stdout
    vm = base / 'state/runtime/wireless-carplay-and-aa/vm'
    assert vm.stat().st_mode & 0o777 == 0o700
    assert (vm / 'dalvik-cache').stat().st_mode & 0o777 == 0o700
    assert (base / 'state/invoked').read_text().strip() == 'status'
    selected = base / 'selected-current'
    selected.symlink_to(payload, target_is_directory=True)
    run(runner, env=dict(env, HMG_SEOGAEMO_MODULE_DIR=str(selected)))
    assert (base / 'state/invoked').read_text().strip() == 'status'
    script(runner, preamble + 'sg_projection_runtime clear\n')
    run(runner, env=env)
    assert (base / 'state/invoked').read_text().strip() == 'clear'
    # Unusable reader results never read as success: bounded, validated, unknown.
    def reader(body, mode='status', ok=True, **extra):
        script(process, body)
        script(runner, preamble + f'sg_projection_runtime {mode}\n')
        return run(runner, env=dict(env, **extra), ok=ok)

    result = reader('exit 0\n')
    assert 'state=unknown' in result.stdout and 'no valid output' in result.stdout
    result = reader('sg_print state=on restart=none detail=a extra=1\n')
    assert 'state=unknown' in result.stdout and 'state=on' not in result.stdout
    result = reader('sg_print state=bogus restart=none detail=a\n')
    assert 'state=unknown' in result.stdout
    result = reader('sg_print state=on restart=none detail=a\nexit 7\n')
    assert 'state=unknown' in result.stdout and 'state=on' not in result.stdout
    result = reader('sg_print state=failed restart=none detail=broken\nexit 1\n', ok=False)
    assert result.returncode == 1 and 'state=failed' in result.stdout and 'detail=broken' in result.stdout
    result = reader('exit 0\n', mode='applying')
    assert 'state=pending-restart' in result.stdout and 'restart=head_unit' in result.stdout
    # Optional read-only tbt counters: digits only, both or neither, status and applying only.
    result = reader('sg_print state=on restart=none detail=ready info.tbt_inexact=3 info.tbt_blank=1\n')
    assert 'state=on' in result.stdout and 'info.tbt_inexact=3' in result.stdout and 'info.tbt_blank=1' in result.stdout
    result = reader('sg_print state=on restart=none detail=ready\n')
    assert 'state=on' in result.stdout and 'info.tbt' not in result.stdout
    for bad in ('info.tbt_inexact=x info.tbt_blank=1', 'info.tbt_inexact=3', 'info.tbt_inexact=1 info.tbt_blank=2 info.tbt_other=1'):
        result = reader('sg_print state=on restart=none detail=ready ' + bad + '\n')
        assert 'state=unknown' in result.stdout and 'state=on' not in result.stdout, bad
    result = reader('sg_print state=on restart=none detail=removed2files\n', mode='tbt-reset')
    assert 'state=on' in result.stdout and 'detail=removed2files' in result.stdout
    result = reader('sg_print state=on restart=none detail=x info.tbt_inexact=1 info.tbt_blank=0\n', mode='tbt-reset', ok=False)
    assert 'state=failed' in result.stdout and 'state=on' not in result.stdout, 'counters are not valid on reset'
    result = reader('exit 0\n', mode='tbt-reset', ok=False)
    assert result.returncode == 1 and 'state=failed' in result.stdout
    # A hung VM is killed (with its child) after the limit; the caller is not held.
    hung = reader('sleep 60 &\nsg_write "$! $$" > "$SG_DATA_ROOT/hung-pids"\nwait\n',
                  SG_READER_TIMEOUT='2')
    assert 'state=unknown' in hung.stdout and 'timed out after 2 seconds' in hung.stdout
    for pid in (base / 'state/hung-pids').read_text().split():
        try:
            os.kill(int(pid), 0)
        except ProcessLookupError:
            continue
        raise AssertionError(f'reader process {pid} survived the timeout')
    assert not list((base / 'state').glob('reader.*'))
    # Output files of an earlier killed run are swept by exact name; a live PID's files,
    # look-alike names and other files stay.
    finished = subprocess.run(["true"])
    dead = str(subprocess.Popen(["true"]).pid)
    time.sleep(0.2)
    data = base / 'state'
    stale = [data / f'reader.out.{dead}', data / f'reader.err.{dead}']
    kept = [data / f'reader.out.{os.getpid()}', data / 'reader.out.abc', data / f'reader.out.{dead}.tmp',
            data / f'reader.outer.{dead}', data / 'unrelated']
    for path in stale + kept:
        path.write_text('x')
    reader('sg_print state=on restart=none detail=ok\n')
    assert not any(path.exists() for path in stale), stale
    assert all(path.exists() for path in kept), kept
    for path in kept:
        path.unlink()
    # A termination signal ends the reader VM (even one ignoring TERM) and its helper.
    pids = data / 'term-pids'
    script(process, 'trap "" TERM\nsg_write "$$" > "$SG_DATA_ROOT/term-pids"\nsleep 40 &\n'
                    'sg_write " $!" >> "$SG_DATA_ROOT/term-pids"\ni=0\n'
                    'while [ "$i" -lt 40 ]; do sleep 1; i=$((i + 1)); done\n')
    script(runner, preamble + 'sg_projection_runtime status\n')
    running = subprocess.Popen([SHELL, str(runner)], env=car_env(env), start_new_session=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(100):
        if pids.exists() and ' ' in pids.read_text():
            break
        time.sleep(0.1)
    else:
        running.kill()
        raise AssertionError('fake reader never started')
    import signal
    os.killpg(running.pid, signal.SIGTERM)
    running.communicate(timeout=30)
    for pid in pids.read_text().split():
        for _ in range(30):
            try:
                os.kill(int(pid), 0)
            except ProcessLookupError:
                break
            time.sleep(0.2)
        else:
            raise AssertionError(f'reader process {pid} survived termination')
    assert not list(data.glob('reader.*'))
    pids.unlink()
    # A timeout during clear removes the root-only private tree directly.
    (base / 'state/runtime/wireless-carplay-and-aa/leftover').write_text('x')
    reader('sleep 60\n', mode='clear', SG_READER_TIMEOUT='2')
    assert not (base / 'state/runtime/wireless-carplay-and-aa').exists()
    script(runner, preamble + 'sg_projection_runtime prepare\n')
    run(runner, env=env)
    # No usable BOOTCLASSPATH: unknown, and the VM is never started.
    invoked = base / 'state/invoked'
    invoked.write_text('untouched')
    no_boot = {key: value for key, value in env.items() if key != 'BOOTCLASSPATH'}
    script(process, 'sg_write started > "$SG_DATA_ROOT/invoked"\n')
    script(runner, preamble + 'sg_projection_runtime status\n')
    result = run(runner, env=dict(no_boot, SG_INIT_ENVIRON=str(base / 'missing.rc')))
    assert 'state=unknown' in result.stdout and 'BOOTCLASSPATH unavailable' in result.stdout
    assert invoked.read_text() == 'untouched'
    (base / 'init.rc').write_text('on init\n    export BOOTCLASSPATH /system/framework/core.jar:/bad;rm\n')
    result = run(runner, env=dict(no_boot, SG_INIT_ENVIRON=str(base / 'init.rc')))
    assert 'BOOTCLASSPATH unavailable' in result.stdout and invoked.read_text() == 'untouched'
    (base / 'init.rc').write_text('on init\n    export PATH /sbin\n    export BOOTCLASSPATH /system/framework/core.jar\n')
    script(process, '[ "$BOOTCLASSPATH" = /system/framework/core.jar ]\nsg_print state=on restart=none detail=derived\n')
    result = run(runner, env=dict(no_boot, SG_INIT_ENVIRON=str(base / 'init.rc')))
    assert 'detail=derived' in result.stdout
    invoked.write_text('clear')
    (vm / 'dalvik-cache').rmdir()
    outside = base / 'outside'
    outside.mkdir()
    (vm / 'dalvik-cache').symlink_to(outside, target_is_directory=True)
    script(runner, preamble + 'sg_projection_runtime status\n')
    blocked = run(runner, env=env, ok=False)
    assert blocked.returncode == 3
    assert (base / 'state/invoked').read_text().strip() == 'clear'


def test_owned_dirs_prune(temp):
    """sg_owned_dirs_prune removes only empty, owned directories under /system/etc/hmg-seogaemo."""
    base = temp / "prune"
    state = base / "data/modules/prune"
    state.mkdir(parents=True)
    (base / "modules").mkdir()
    fake = base / "fake"
    fake.mkdir()
    script(fake / "nemesis", 'echo "$*" >> "$FAKE_REMOUNTS"\n')
    root = base / "target"
    assets = root / "system/etc/hmg-seogaemo"
    (assets / "m/recipes").mkdir(parents=True)
    (assets / "full").mkdir()
    (assets / "full/x").write_text("kept")
    (root / "system/etc/other").mkdir(parents=True)
    (base / "modules/prune.properties").write_text(
        "owns_files=/system/etc/hmg-seogaemo/m/recipes/a.recipe,/system/etc/hmg-seogaemo/full/x\n")
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"], FAKE_REMOUNTS=str(base / "remounts"),
               SG_DATA_ROOT=str(base / "data"), HMG_SEOGAEMO_STATE=str(state), HMG_SEOGAEMO_BASE=str(base),
               SG_TARGET_ROOT=str(root))
    runner = base / "run-prune"
    script(runner, f'''
set -eu
. "{ROOT / 'nemesis/package/lib/common.sh'}"
for refused in /system/etc/other /system/etc/hmg-seogaemo/unowned /system/etc/hmg-seogaemo/m/../full; do
    rc=0; sg_owned_dirs_prune "$refused" || rc=$?
    [ "$rc" -eq 2 ] || exit 10
done
# Callers may run with noglob; a non-empty directory must still be kept.
set -f
sg_owned_dirs_prune /system/etc/hmg-seogaemo/full
set +f
sg_owned_dirs_prune /system/etc/hmg-seogaemo/m/recipes /system/etc/hmg-seogaemo/m /system/etc/hmg-seogaemo
# Already gone: nothing to do.
sg_owned_dirs_prune /system/etc/hmg-seogaemo/m/recipes /system/etc/hmg-seogaemo/m
''')
    run(runner, env=env)
    assert not (assets / "m").exists()
    assert (assets / "full/x").read_text() == "kept"
    assert (root / "system/etc/other").is_dir()
    rows = (base / "data/ledger/ledger.tsv").read_text().splitlines()[1:]
    assert [r.split("\t")[1:4] for r in rows] == [
        ["prune", "directory_prune", "/system/etc/hmg-seogaemo/m/recipes"],
        ["prune", "directory_prune", "/system/etc/hmg-seogaemo/m"]], rows
    assert (base / "remounts").read_text().splitlines() == ["remount rw", "remount ro"] * 2


def test_ro_holders(temp):
    """A failed remount ro records, once per boot, which processes hold /system files."""
    base = temp / "ro"
    state = base / "data/modules/demo"
    state.mkdir(parents=True)
    fake = base / "fake"
    fake.mkdir()
    script(fake / "nemesis", '[ "$2" = ro ] && exit 1\nexit 0\n')
    proc = base / "proc"
    (proc / "100/fd").mkdir(parents=True)
    (proc / "200").mkdir()
    (proc / "mounts").write_text("/dev/block/system /system ext4 rw,relatime 0 0\n/dev/block/data /data ext4 rw 0 0\n")
    (proc / "100/comm").write_text("zygote\n")
    (proc / "100/maps").write_text(
        "7f000000-7f001000 r-xp 00000000 b3:01 12 /system/lib/libleafiaaac.so (deleted)\n"
        "7f001000-7f002000 r-xp 00000000 b3:01 13 /system/lib/libc.so\n")
    os.symlink("/system/etc/held.conf", proc / "100/fd/3")
    (proc / "200/comm").write_text("idle\n")
    (proc / "200/maps").write_text("7f000000-7f001000 r-xp 00000000 b3:01 13 /system/lib/libc.so\n")
    boot = base / "boot_id"
    boot.write_text("boot-1\n")
    env = dict(os.environ, PATH=str(fake) + ":" + os.environ["PATH"], SG_DATA_ROOT=str(base / "data"),
               HMG_SEOGAEMO_STATE=str(state), HMG_SEOGAEMO_BASE=str(base), SG_PROC_ROOT=str(proc),
               SG_BOOT_ID_FILE=str(boot))
    runner = base / "run-ro"
    script(runner, f'''
set -eu
. "{ROOT / 'nemesis/package/lib/common.sh'}"
sg_remount_ro
sg_remount_ro
''')
    run(runner, env=env)
    log = (base / "data/system-rw.log").read_text()
    assert log.count("== ") == 1, log
    assert "boot=boot-1 module=demo" in log, log
    assert "/dev/block/system /system ext4 rw,relatime 0 0" in log and "/data ext4" not in log, log
    assert "map 100 zygote /system/lib/libleafiaaac.so (deleted)" in log, log
    assert "libc.so" not in log and " 200 " not in log, log
    assert "fd 100 zygote /system/etc/held.conf" in log, log
    assert "remount ro failed" in (state / "module.log").read_text()
    boot.write_text("boot-2\n")
    run(runner, env=env)
    assert (base / "data/system-rw.log").read_text().count("== ") == 2


run_tests([
    test_toolbox_md5,
    test_file_key_failures,
    test_common,
    test_output_bytes,
    test_root,
    test_automatic_intent_lock,
    test_mutation_api_and_export,
    test_owned_dirs_prune,
    test_ro_holders,
    test_service_call_api,
    test_reconcile,
    test_watch_dispatch,
    test_usb_watch_dispatch,
    test_reconcile_does_not_watch,
    test_noglob_and_changes_dedup,
    test_lint,
    test_module_build_hook,
    test_zygote_and_dex,
    test_zygote_foreign,
    test_remount_ro_busy,
    test_system_directory_mode,
    test_stray_temporaries,
    test_residue_cleanup,
    test_public_readable,
    test_file_metadata_guards,
    test_kill_tree,
    test_update_signal,
    test_projection_reader_vm,
], "shared runtime tests passed")
