#!/usr/bin/env python3
"""Off-car checks for the archives and shell interface."""
import argparse
import configparser
import hashlib
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import zipfile

from package import DIST, ROOT, HOST_SHELL, apk_version, verify
from version import read_label, read_version
from testlib import car_env, SHELL, host_shell_script


def descriptor(data):
    parser = configparser.ConfigParser(interpolation=None)
    parser.read_string(data.decode())
    return parser


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument("--aapt", required=True)
    args = parser.parse_args()
    os.environ.update(car_env())
    version, code = read_version(ROOT / "VERSION")
    prefix = f"hmg-seogaemo-{version}"
    verify(args.aapt)
    package_path = DIST / f"{prefix}-nemesis-package.zip"
    usb_path = DIST / f"{prefix}-nemesis-usb.zip"
    ota_path = DIST / f"{prefix}-ota.zip"
    with zipfile.ZipFile(package_path) as package, zipfile.ZipFile(usb_path) as usb, zipfile.ZipFile(ota_path) as ota:
        # Every Java root command must explicitly select the device interpreter.
        for source, expected_count in (("module/RootClient.java", 8),
                                       ("core/update/UpdateClient.java", 1)):
            java = (ROOT / "app/src/com/seogaemo/hmg" / source).read_text()
            commands = re.findall(r'"([^"\n]*bin/hmg-seogaemo-root [^"\n]*)"', java)
            assert len(commands) == expected_count, commands
            assert all(command.startswith("/system/bin/sh /data/nemesis/apps/")
                       for command in commands), commands
            assert '"/data/nemesis/apps/hmg-seogaemo/bin/nemesis-client"' in java
        entries = set(package.namelist())
        required = {"NEMESIS.data", "app/hmg-seogaemo.apk", "bin/hmg-seogaemo-root", "bin/install-apk.sh",
                    "bin/open.sh", "svc/install-pending.sh", "scripts/postinstall.sh", "scripts/preuninstall.sh",
                    "svc/reconcile.sh", "svc/watcher.sh", "lib/common.sh", "modules.list", "modules.graph",
                    "core/stock.sh", "lib/stock.sh", "core/uninstall-detached.sh", "core/foreign.sh",
                    "core/map/hmg-seogaemo-mapper.jar", "core/hmg-seogaemo-map.sh", "hookpoints/framework.json",
                    "hookpoints.required/wireless-carplay-and-aa",
                    "bundled/skip-consent-screen.hsm", "bundled/skip-consent-screen.sha256",
                    "bundled/user-button.hsm",
                    "bundled/wireless-carplay-and-aa.hsm", "modules/package-compat.sh",
                    "modules/package-compat.properties",
                    "maps/hyundai/ioniq5/kor/260902/map.json",
                    "maps/hyundai/ioniq5/kor/260902/car.json"}
        assert required <= entries, required - entries
        assert package.read("modules.list") == b"package-compat\n", package.read("modules.list")
        # Shared-line and whole-file ownership checks read every module's manifest from the
        # package's modules/ (a bundled CarPlay without it could not claim its featurexml lines).
        for bundled in sorted(n for n in entries if n.startswith("bundled/") and n.endswith(".hsm")):
            module_id = bundled[len("bundled/"):-len(".hsm")]
            manifest = package.read(f"modules/{module_id}.properties").decode()
            assert f"\nid={module_id}\n" in "\n" + manifest, (module_id, manifest)
        assert "owns_lines.1=/system/onebin/neev_kr/featurexml.cfg:" in package.read(
            "modules/wireless-carplay-and-aa.properties").decode()
        # Installs from 0.1.33 and older check an OTA payload with their own lib/payload.sh before
        # switching to it; the new payload (no built-in modules) must pass that old check.
        with tempfile.TemporaryDirectory() as old_check:
            payload_dir = Path(old_check) / "payload"
            ota.extractall(payload_dir)
            checker = Path(old_check) / "check.sh"
            checker.write_text(host_shell_script((ROOT / "tools/fixtures/payload-0.1.33.sh").read_text()) +
                               '\nhmg_seogaemo_payload_valid "$1"\n')
            old = subprocess.run([SHELL, str(checker), str(payload_dir)], capture_output=True, text=True)
            assert old.returncode == 0, (old.stdout, old.stderr)
        for map_name in ("map.json", "car.json", "README.md"):
            source = ROOT / "maps/hyundai/ioniq5/kor/260902" / map_name
            assert package.read(f"maps/hyundai/ioniq5/kor/260902/{map_name}") == source.read_bytes()
        preuninstall = package.read("scripts/preuninstall.sh").decode()
        assert "id=hmg-seogaemo" in preuninstall
        assert "/data/local/tmp/nemesis/stage/hmg-seogaemo/NEMESIS.data" in preuninstall
        for script_name in ("core/update.sh", "core/hmg-seogaemo-map.sh", "svc/reconcile.sh", "svc/watcher.sh"):
            body = package.read(script_name).decode()
            assert not re.search(r"\b(?:printf|awk|sed|tail|head|cut|tr|wc|sort|uniq|xargs|find|stat|sha256sum|sha1sum|tar|unzip|busybox|toybox)\b", body), script_name
        assert set(usb.namelist()) == {"NEMESIS.data", "install.sh", "packages/hmg-seogaemo.zip"}
        assert usb.read("packages/hmg-seogaemo.zip") == package_path.read_bytes()
        assert b'install --update "${0%/*}/packages/hmg-seogaemo.zip"' in usb.read("install.sh")
        assert ota.read("VERSION") == (version + "\n").encode()
        assert ota.read("app/hmg-seogaemo.apk") == package.read("app/hmg-seogaemo.apk")
        assert ota.read("update_roots.pem") == (ROOT / "app/res/raw/update_roots.pem").read_bytes()
        for name in ota.namelist():
            assert name in ("VERSION", "update_roots.pem", "app/hmg-seogaemo.apk", "modules.list", "modules.graph", "modules.lines") or name.startswith(("bin/", "lib/", "modules/", "core/", "svc/", "hookpoints/", "hookpoints.required/", "maps/", "bundled/"))
            if name in entries:
                assert ota.read(name) == package.read(name)
        usb_meta = descriptor(usb.read("NEMESIS.data"))
        assert dict(usb_meta["nemesis"]) == {"version": "1.0", "type": "execute", "path": "install.sh"}
        meta = descriptor(package.read("NEMESIS.data"))
        assert dict(meta["nemesis"]) == {
            "version": "1.1", "id": "hmg-seogaemo", "name": "HMG-Seogaemo", "type": "application,service",
            "package-version": version, "short-desc": '"Built-in controls for the Gen5W head unit."',
            "os": "*.KOR.*", "models": "*_kr", "postinstall": "scripts/postinstall.sh",
            "preuninstall": "scripts/preuninstall.sh"}
        assert dict(meta["app.0"]) == {"kind": "sh", "path": "bin/open.sh", "uid": "root"}
        assert dict(meta["service.0"]) == {"name": "reconcile", "kind": "sh", "path": "svc/reconcile.sh", "uid": "root", "mode": "background"}
        assert dict(meta["service.1"]) == {"name": "watcher", "kind": "sh", "path": "svc/watcher.sh", "uid": "root", "mode": "restart"}
        ids = package.read("modules.list").decode().splitlines()
        assert ids and len(ids) == len(set(ids))
        assert len(package.read("modules.graph").decode().splitlines()) == len(ids)
        for name in ids:
            props = package.read(f"modules/{name}.properties").decode()
            assert f"\nid={name}\n" in "\n" + props
            assert f"\nversion={version}\n" in "\n" + props
            assert f"modules/{name}.sh" in entries
            payload = ROOT / "modules" / name / "payload"
            if payload.is_dir():
                assert f"modules/{name}.d/" in entries
                for source in payload.rglob("*"):
                    if source.is_file():
                        entry = f"modules/{name}.d/{source.relative_to(payload).as_posix()}"
                        if source.relative_to(ROOT).as_posix() in HOST_SHELL:
                            assert entry not in entries
                            assert entry not in ota.namelist()
                            continue
                        assert package.read(entry) == source.read_bytes()
        # package-compat is a stub for older installs' payload checks, not a module.
        for name in [n for n in ids if n != "package-compat"]:
            with tempfile.TemporaryDirectory() as module_temp:
                module_root = Path(module_temp)
                (module_root / "lib").mkdir()
                (module_root / "modules").mkdir()
                (module_root / "lib/common.sh").write_bytes(package.read("lib/common.sh"))
                script = module_root / f"modules/{name}.sh"
                script.write_bytes(package.read(f"modules/{name}.sh"))
                (module_root / "state").mkdir()
                fake = module_root / "fake-bin"
                fake.mkdir()
                for command in ("getprop", "ifconfig", "netcfg", "pm", "settings", "dumpsys"):
                    path = fake / command
                    path.write_text("#!/bin/sh\nexit 0\n")
                    path.chmod(0o755)
                for verb in ("status", "precheck"):
                    result = subprocess.run([SHELL, str(script), verb],
                                            env=dict(os.environ, PATH=f"{fake}:{os.environ['PATH']}",
                                                     HMG_SEOGAEMO_BASE=str(module_root),
                                                     HMG_SEOGAEMO_STATE=str(module_root / "state"),
                                                     HMG_SEOGAEMO_MODULE_DIR=str(module_root / "payload"),
                                                     SG_DATA_ROOT=str(module_root / "data")),
                                            capture_output=True, text=True)
                    assert result.returncode in (0, 1, 3, 4), result.stderr
                    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
                    assert fields.get("state") in ("off", "on", "pending-restart", "conflict",
                                                    "incompatible", "failed", "not-implemented"), result.stdout
                    assert fields.get("restart") in ("none", "adbd", "head_unit"), result.stdout
                    assert "detail" in fields and len(fields["detail"]) <= 200, result.stdout
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            for name in entries:
                if name.endswith(".sh") or name == "bin/hmg-seogaemo-root":
                    path = temp / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(host_shell_script(package.read(name).decode()))
                    # Reproduce NEMESIS extraction rather than ZIP Unix modes.
                    path.chmod(0o755 if name.startswith(("scripts/", "svc/")) else 0o644)
                    subprocess.run([SHELL, "-n", str(path)], check=True)
            # Run a copied dispatcher against an isolated fake module tree.
            (temp / "modules.list").write_text("good\n")
            (temp / "modules/good.sh").write_text('#!/bin/sh\n. "$HMG_SEOGAEMO_BASE/lib/common.sh"\nsg_print "action=$1" "base=$HMG_SEOGAEMO_BASE" "state=$HMG_SEOGAEMO_STATE" "module_dir=$HMG_SEOGAEMO_MODULE_DIR"\n')
            (temp / "modules/good.sh").chmod(0o644)
            assert not os.access(temp / "bin/hmg-seogaemo-root", os.X_OK)
            assert not os.access(temp / "modules/good.sh", os.X_OK)
            command = [SHELL, str(temp / "bin/hmg-seogaemo-root")]
            result = subprocess.run(command + ["good", "status"], capture_output=True, text=True)
            expected = f"action=status\nbase={temp}\nstate=/data/nemesis/backup/hmg-seogaemo/modules/good\nmodule_dir={temp}/modules/good.d\n"
            assert result.returncode == 0 and result.stdout == expected + 'info.desired=off\n'
            result = subprocess.run(command + ["good", "precheck"], capture_output=True, text=True)
            assert result.returncode == 0 and result.stdout == expected.replace("status", "precheck")
            for bad in ([], ["bad", "status"], ["../good", "status"], ["good", "delete"], ["good", "status", "extra"]):
                assert subprocess.run(command + bad, capture_output=True).returncode != 0
            # A PackageManager text failure can exit zero. The boot property
            # still has to be restored in both outcomes.
            (temp / "app").mkdir()
            (temp / "app/hmg-seogaemo.apk").write_bytes(b"test")
            fake = temp / "fake-bin"
            fake.mkdir()
            state = temp / "boot-property"
            for name, script in {
                "getprop": '#!/bin/sh\ncat "$FAKE_STATE"\n',
                "setprop": '#!/bin/sh\n. "$HMG_SEOGAEMO_TEST_COMMON"\nsg_write "$2" > "$FAKE_STATE"\n',
                "pm": '#!/bin/sh\ncase "$1" in install) echo $$ > "$FAKE_PM_PID"; case "$FAKE_PM_RESULT" in hang) sleep 20;; hang-ignore) trap "" TERM; sleep 20;; esac; echo "$FAKE_PM_RESULT";; path) echo package:/data/app/hmg-seogaemo.apk;; esac\n',
            }.items():
                path = fake / name
                path.write_text(script)
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{fake}:{os.environ['PATH']}", FAKE_STATE=str(state),
                       FAKE_PM_PID=str(temp / "pm.pid"),
                       HMG_SEOGAEMO_TEST_COMMON=str(temp / "lib/common.sh"),
                       HMG_SEOGAEMO_APK_STAGE=str(temp), SG_DATA_ROOT=str(temp / "state"))
            for output, succeeds in (("Success", True), ("Failure [INSTALL_FAILED]", False)):
                state.write_text("1")
                env["FAKE_PM_RESULT"] = output
                result = subprocess.run([SHELL, str(temp / "bin/install-apk.sh")], env=env, capture_output=True)
                assert (result.returncode == 0) == succeeds
                assert state.read_text() == "1"
                assert not list(temp.glob("hmg-seogaemo-install.*.apk"))
            # A hung pm is bounded by the watchdog; the boot property comes
            # back on the timeout path and when the installer itself is killed.
            env["FAKE_PM_RESULT"] = "hang"
            env["HMG_SEOGAEMO_PM_TIMEOUT"] = "2"
            state.write_text("1")
            started = time.monotonic()
            result = subprocess.run([SHELL, str(temp / "bin/install-apk.sh")], env=env, capture_output=True, text=True)
            assert result.returncode == 1 and "timed out" in result.stderr, result
            assert time.monotonic() - started < 15
            assert state.read_text() == "1"
            assert not list(temp.glob("hmg-seogaemo-install.*"))
            env["HMG_SEOGAEMO_PM_TIMEOUT"] = "100"
            state.write_text("1")
            process = subprocess.Popen([SHELL, str(temp / "bin/install-apk.sh")], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 8
            while state.read_text() != "0":  # pm install runs with the property forced to 0
                assert time.monotonic() < deadline
                time.sleep(0.02)
            process.terminate()
            process.communicate(timeout=10)
            assert process.returncode != 0 and state.read_text() == "1"
            assert not list(temp.glob("hmg-seogaemo-install.*"))
            assert not list((temp / "state").glob("install-apk.*"))

            def pm_gone():
                pids = [int(x) for x in (temp / "pm.pid").read_text().split()]
                for pid in pids:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        continue
                    return False
                return True

            def wait_for(check, what, seconds=20):
                deadline = time.monotonic() + seconds
                while not check():
                    assert time.monotonic() < deadline, what
                    time.sleep(0.05)

            def start_hung(timeout):
                env["HMG_SEOGAEMO_PM_TIMEOUT"] = timeout
                state.write_text("1")
                child = subprocess.Popen([SHELL, str(temp / "bin/install-apk.sh")], env=env,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                wait_for(lambda: state.read_text() == "0" and (temp / "pm.pid").exists(), "pm never started")
                # Only the staged APK may live in the (world-visible) stage directory.
                assert [p.name for p in temp.glob("hmg-seogaemo-install.*")] and \
                    all(p.suffix == ".apk" for p in temp.glob("hmg-seogaemo-install.*"))
                work = list((temp / "state").glob("install-apk.*"))
                assert len(work) == 1 and (work[0].stat().st_mode & 0o777) == 0o700, work
                return child

            # A pm that ignores TERM is KILLed after the grace period.
            env["FAKE_PM_RESULT"] = "hang-ignore"
            env["HMG_SEOGAEMO_PM_GRACE"] = "1"
            (temp / "pm.pid").unlink(missing_ok=True)
            state.write_text("1")
            started = time.monotonic()
            env["HMG_SEOGAEMO_PM_TIMEOUT"] = "2"
            result = subprocess.run([SHELL, str(temp / "bin/install-apk.sh")], env=env, capture_output=True, text=True)
            assert result.returncode == 1 and "timed out" in result.stderr, result
            assert time.monotonic() - started < 15 and state.read_text() == "1"
            wait_for(pm_gone, "TERM-ignoring pm survived the watchdog")
            assert not list(temp.glob("hmg-seogaemo-install.*")) and not list((temp / "state").glob("install-apk.*"))
            # SIGKILL of the installer itself cannot run its trap: the watchdog
            # must notice the dead parent, stop pm and restore the property.
            env["FAKE_PM_RESULT"] = "hang"
            (temp / "pm.pid").unlink(missing_ok=True)
            process = start_hung("100")
            os.kill(process.pid, signal.SIGKILL)
            process.wait(timeout=10)  # reap it: a zombie still answers kill -0
            process.communicate(timeout=10)
            wait_for(lambda: state.read_text() == "1", "watchdog did not restore sys.boot_completed")
            wait_for(pm_gone, "pm survived the killed installer")
            wait_for(lambda: not list(temp.glob("hmg-seogaemo-install.*")) and
                     not list((temp / "state").glob("install-apk.*")), "installer residue left")
            # Whole process group killed (watchdog included): the next run
            # recovers the property from the saved value before reading it.
            (temp / "pm.pid").unlink(missing_ok=True)
            process = start_hung("100")
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=10)
            assert state.read_text() == "0"
            pm_pids = [int(x) for x in (temp / "pm.pid").read_text().split()]
            for pid in pm_pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            env["FAKE_PM_RESULT"] = "Success"
            result = subprocess.run([SHELL, str(temp / "bin/install-apk.sh")], env=env, capture_output=True, text=True)
            assert result.returncode == 0 and state.read_text() == "1", result
            assert not list(temp.glob("hmg-seogaemo-install.*")) and not list((temp / "state").glob("install-apk.*"))
            del env["HMG_SEOGAEMO_PM_TIMEOUT"], env["HMG_SEOGAEMO_PM_GRACE"]
            # Root postinstall must explicitly install native client mode, even
            # when its source and all package bin files start non-executable.
            native = temp / "fake-nemesis"
            native.write_bytes(b"native-client")
            native.chmod(0o644)
            (fake / "getprop").write_text(
                '#!/bin/sh\ncase "$1" in ro.build.product) echo NEEV.KOR.0000.V039.001.260902;; *) echo 0;; esac\n')
            hook = temp / "scripts/postinstall.sh"
            hook.write_text(host_shell_script(package.read("scripts/postinstall.sh").decode())
                            .replace("/system/xbin/nemesis", str(native)))
            result = subprocess.run([SHELL, str(hook)], env=env, capture_output=True)
            assert result.returncode == 0, result.stderr
            job = temp / "state/app-install"
            assert (job / "pending").exists()
            assert (job / "payload/app/hmg-seogaemo.apk").read_bytes() == b"test"
            assert (job / "payload/bin/install-apk.sh").exists()
            client = temp / "bin/nemesis-client"
            assert client.read_bytes() == native.read_bytes()
            assert client.stat().st_mode & 0o777 == 0o755
            for name in ("hmg-seogaemo-root", "open.sh", "install-apk.sh"):
                assert (temp / "bin" / name).stat().st_mode & 0o777 == 0o755
        with tempfile.NamedTemporaryFile(suffix=".apk") as temp:
            temp.write(package.read("app/hmg-seogaemo.apk"))
            temp.flush()
            assert apk_version(Path(temp.name), args.aapt) == (read_label(ROOT / "VERSION")[0], code)
        # Exercise the fixed updater transaction against a fake root tree.
        with tempfile.TemporaryDirectory() as fake_temp:
            fake_root = Path(fake_temp).resolve()
            package_root = fake_root / "package"
            (package_root / "core").mkdir(parents=True)
            (package_root / "lib").mkdir()
            (package_root / "lib/common.sh").write_bytes(package.read("lib/common.sh"))
            (package_root / "bin").mkdir()
            (package_root / "app").mkdir()
            (package_root / "app/hmg-seogaemo.apk").write_bytes(b"old apk")
            (package_root / "NEMESIS.data").write_bytes(package.read("NEMESIS.data"))
            (package_root / "bin/install-apk.sh").write_text("#!/bin/sh\nexit 0\n")
            updater = package.read("core/update.sh").decode()
            state = fake_root / "state"
            incoming = fake_root / "download"
            updater = updater.replace("state=/data/nemesis/backup/hmg-seogaemo", "state=" + str(state))
            updater = updater.replace("input=/data/data/com.seogaemo.hmg/files/update", "input=" + str(incoming))
            (package_root / "core/update.sh").write_text(host_shell_script(updater))
            incoming.mkdir()
            for name in ("hmg-seogaemo-0.1.1-manifest.json", "hmg-seogaemo-0.1.1-manifest.json.sig", "hmg-seogaemo-0.1.1-ota.zip"):
                (incoming / name).write_bytes(b"test")
            (incoming / "payload/app").mkdir(parents=True)
            for name in ("VERSION", "app/hmg-seogaemo.apk", "modules.list", "modules.graph", "modules.lines"):
                (incoming / "payload" / name).write_text("test\n")
            (incoming / "payload/VERSION").write_text("0.1.1\n")
            md5_lines = "".join(hashlib.md5((incoming / "payload" / name).read_bytes()).hexdigest() + "|" + name + "\n" for name in ("VERSION", "app/hmg-seogaemo.apk", "modules.list", "modules.graph", "modules.lines"))
            (incoming / "payload/files.md5").write_text(md5_lines)
            fake_bin = fake_root / "bin"
            fake_bin.mkdir()
            (fake_bin / "app_process").write_text("""#!/bin/sh
[ "$ANDROID_DATA" = "$SG_STATE_FOR_TEST/core/vm" ] && [ -d "$ANDROID_DATA/dalvik-cache" ] || exit 9
case "$3" in
  copy) mkdir "$5"; cp "$4"/hmg-seogaemo-* "$5/"; cp -R "$4/payload" "$5/";;
  verify) echo "$5" > "$SG_STATE_FOR_TEST/verify-installed"; echo 0.1.1;;
  extract) mkdir -p "$6/app" "$6/bin" "$6/svc"; cp "$4/payload/VERSION" "$6/VERSION"; cp "$4/payload/modules.graph" "$6/modules.graph"; cp "$4/payload/modules.lines" "$6/modules.lines"; cp "$4/payload/modules.list" "$6/modules.list"; cp "$4/payload/app/hmg-seogaemo.apk" "$6/app/hmg-seogaemo.apk"; echo '#!/bin/sh' > "$6/bin/install-apk.sh"; echo 'exit 0' >> "$6/bin/install-apk.sh"; echo '#!/bin/sh' > "$6/bin/hmg-seogaemo-root"; echo 'exit 0' >> "$6/bin/hmg-seogaemo-root"; echo '#!/bin/sh' > "$6/svc/reconcile.sh"; echo 'exit 0' >> "$6/svc/reconcile.sh"; cp "$4/payload/files.md5" "$6/files.md5";;
  switch) python3 -c 'import os,sys; os.replace(sys.argv[1],sys.argv[2])' "$4" "$5";;
esac
""")
            (fake_bin / "dumpsys").write_text("#!/bin/sh\necho versionName=0.1.1\n")
            for name in ("app_process", "dumpsys"):
                (fake_bin / name).chmod(0o755)
            env = dict(os.environ, PATH=f"{fake_bin}:{os.environ['PATH']}", SG_STATE_FOR_TEST=str(state))
            updater_cmd = [SHELL, str(package_root / "core/update.sh")]
            for verb in ("stage", "apply", "rollback"):
                if verb == 'stage':
                    # a beta USB package compares as older than the release of its version
                    (package_root / "PRERELEASE").write_text("beta.2\n")
                if verb == 'apply':
                    health = state / 'update/versions/0.1.1/svc/reconcile.sh'
                    health.write_text('#!/bin/sh\n[ "$HMG_SEOGAEMO_UPDATE_HEALTH" = 1 ] && '
                                      '[ "$HMG_SEOGAEMO_PROJECTION_ROLLBACK_GUARD" = 1 ]\n')
                if verb == 'rollback':
                    # Applied projection generations must never be paired with
                    # an older selected package/APK, even after interruption.
                    projection = state / 'modules/wireless-carplay-and-aa'
                    projection.mkdir(parents=True)
                    (projection / 'changes').write_text('file\t/system/bin/app_process\n')
                    selected = (state / 'update/current').resolve()
                    blocked = subprocess.run(updater_cmd + [verb], env=env, capture_output=True, text=True)
                    assert blocked.returncode != 0 and 'disable wireless-carplay-and-aa' in blocked.stderr
                    assert (state / 'update/current').resolve() == selected
                    assert (state / 'update/journal').read_text().strip() == 'phase=healthy'
                    (projection / 'changes').unlink()
                result = subprocess.run(updater_cmd + [verb], env=env, capture_output=True, text=True)
                assert result.returncode == 0, (verb, result.stdout, result.stderr)
                if verb == 'stage':
                    assert (state / "verify-installed").read_text().strip() == version + "-beta.2"
                    (package_root / "PRERELEASE").unlink()
            assert "package-version=" + version in (package_root / "NEMESIS.data").read_text(), (package_root / "NEMESIS.data").read_text()
            assert (state / "update/journal").read_text().strip() == "phase=rolled-back"
            (state / "update/staged").write_text("0.1.1\n")
            (fake_bin / "dumpsys").write_text("#!/bin/sh\necho versionName=wrong\n")
            result = subprocess.run(updater_cmd + ["apply"], env=env, capture_output=True, text=True)
            assert result.returncode != 0
            assert (state / "update/current").resolve() == package_root.resolve(), (result.stdout, result.stderr, (state / "update/current").resolve(), package_root.resolve(), (state / "update/journal").read_text())
            assert (state / "update/journal").read_text().strip() == "phase=auto-rollback"
            # Automatic health failure also retains the newly selected package
            # while projection system files have restore material.
            (projection / 'changes').write_text('file\t/system/bin/app_process\n')
            result = subprocess.run(updater_cmd + ["apply"], env=env, capture_output=True, text=True)
            assert result.returncode != 0 and 'rollback blocked' in result.stderr
            assert (state / 'update/current').resolve() == (state / 'update/versions/0.1.1').resolve()
            assert (state / 'update/journal').read_text().strip() == 'phase=auto-rollback'
            blocked = subprocess.run(updater_cmd + ['rollback'], env=env, capture_output=True, text=True)
            assert blocked.returncode != 0 and 'rollback blocked' in blocked.stderr
            (projection / 'changes').unlink()
            result = subprocess.run(updater_cmd + ['rollback'], env=env, capture_output=True, text=True)
            assert result.returncode == 0, (result.stdout, result.stderr)
            assert (state / 'update/current').resolve() == package_root.resolve()
    print("NEMESIS package tests passed")


if __name__ == "__main__":
    run()
