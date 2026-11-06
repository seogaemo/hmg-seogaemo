#!/usr/bin/env python3
"""Other-package scan and cleanup through the real dispatcher (foreign status / clean)."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from testlib import car_env, host_shell_tree, SHELL

ROOT = Path(__file__).resolve().parents[1]


def script(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


def package(root, pid):
    (root / "apps" / pid).mkdir(parents=True)
    (root / "apps" / pid / "NEMESIS.data").write_text(f"id={pid}\n")


def main():
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory).resolve()
        base = temp / "package"
        shutil.copytree(ROOT / "nemesis/package", base)
        host_shell_tree(base)
        nemesis, system, hmgapi, local, data = (temp / name for name in ("nemesis", "system", "hmgapi", "local", "data"))
        for path in (nemesis / "apps", nemesis / "backup", system, local, data):
            path.mkdir(parents=True)
        fake = temp / "fake"
        calls = temp / "calls"
        # Fake NEMESIS: records the call and removes the package tree like the real uninstall.
        script(fake / "nemesis", f'echo "$@" >> "{calls}"\n[ "$1" = uninstall ] && rm -rf "{nemesis}/apps/$2"\nexit 0\n')
        env = car_env(dict(os.environ, PATH=f"{fake}:{os.environ['PATH']}", SG_DATA_ROOT=str(data),
                           SG_NEMESIS_ROOT=str(nemesis), SG_SYSTEM_ROOT=str(system), SG_HMGAPI_ROOT=str(hmgapi),
                           SG_LOCAL_TMP=str(local), SG_BOOT_ID_FILE=str(temp / "boot_id"),
                           SG_PROPERTY_ROOT=str(temp / "property")))
        (temp / "boot_id").write_text("boot-1\n")

        def root(*args, code=0):
            result = subprocess.run([SHELL, str(base / "bin/hmg-seogaemo-root"), *args], env=env,
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
            return result.stdout

        first = root("foreign", "status")
        assert "info.count=0" in first, first
        package(nemesis, "hmgapi")
        package(nemesis, "hmgapi.adb")
        package(nemesis, "wireless.carplay.aa")
        package(nemesis, "projection.cardata")
        (nemesis / "backup/adb.tcp").mkdir()
        (nemesis / "wireless.projection.log").write_text("log")
        (system / "system/bin").mkdir(parents=True)
        (system / "system/bin/app_process.leafia-stock").write_text("x")
        (local / "hkmc.factory82.session").write_text("s")
        out = root("foreign", "status")
        for item in ("pkg-hmgapi-mods,remove", "pkg-hmgapi,remove", "pkg-leafia,remove", "adb-tcp-orphan,report",
                     "app-process-leafia,report", "foreign-logs,delete", "factory82-state,delete"):
            assert item in out, (item, out)
        assert "info.count=7" in out and (data / "foreign/report").read_text().count("info.item_") == 7

        assert "can only be reported" in root("foreign", "clean", "adb-tcp-orphan", code=1)
        assert "not found" in root("foreign", "clean", "pkg-wireless-projection", code=1)
        root("foreign", "clean", "Bad_Id", code=2)
        assert "mod packages first" in root("foreign", "clean", "pkg-hmgapi", code=3)
        (data / "desired").mkdir()
        (data / "desired/wireless-adb").write_text("on")
        assert "Turn off wireless-adb first" in root("foreign", "clean", "pkg-hmgapi-mods", code=3)
        (data / "desired/wireless-adb").write_text("off")
        assert "state=pending-restart" in root("foreign", "clean", "pkg-hmgapi-mods")
        root("foreign", "clean", "pkg-hmgapi")
        root("foreign", "clean", "pkg-leafia")
        assert calls.read_text().splitlines() == [
            "uninstall hmgapi.adb", "uninstall hmgapi", "uninstall projection.cardata", "uninstall wireless.carplay.aa"]
        assert "Deleted foreign-logs" in root("foreign", "clean", "foreign-logs")
        root("foreign", "clean", "factory82-state")
        assert not (nemesis / "wireless.projection.log").exists() and not (local / "hkmc.factory82.session").exists()
        assert (system / "system/bin/app_process.leafia-stock").exists() and (nemesis / "backup/adb.tcp").is_dir()
        ledger = (data / "ledger/ledger.tsv").read_text()
        assert ledger.count("foreign_remove") == 4 and ledger.count("foreign_delete") == 2, ledger

        hmgapi.mkdir()
        (hmgapi / "installed.txt").write_text("1")
        script(hmgapi / "uninstall.sh", f'rm -f "{hmgapi}/installed.txt"\n')
        assert "hmgapi-standalone,remove" in root("foreign", "status")
        root("foreign", "clean", "hmgapi-standalone")
        assert "hmgapi-data,delete" in root("foreign", "status")
        root("foreign", "clean", "hmgapi-data")
        assert not hmgapi.exists()
        out = root("foreign", "status")
        assert "info.count=2" in out, out

        # HMG-API's Wi-Fi client leftovers: identical feature XML and persist.wifi.state=3, no wifi-client record.
        (temp / "property").mkdir()
        payload = (ROOT / "modules/wifi-client/payload/android.hardware.wifi.xml").read_bytes()
        (base / "modules/wifi-client.d").mkdir(parents=True)
        (base / "modules/wifi-client.d/android.hardware.wifi.xml").write_bytes(payload)
        xml = system / "system/etc/permissions/android.hardware.wifi.xml"
        xml.parent.mkdir(parents=True)
        xml.write_bytes(payload)
        (temp / "property/persist.wifi.state").write_text("3")
        record = data / "modules/wifi-client/prop.persist.wifi.state"
        record.mkdir(parents=True)
        (record / "applied").write_text("3")
        assert "hmgapi-wifi" not in root("foreign", "status")
        shutil.rmtree(data / "modules/wifi-client")
        assert "hmgapi-wifi,delete" in root("foreign", "status")
        (data / "desired").mkdir(exist_ok=True)
        (data / "desired/wifi-client").write_text("on")
        assert "Turn off wifi-client first" in root("foreign", "clean", "hmgapi-wifi", code=3)
        (data / "desired/wifi-client").write_text("off")
        assert "state=pending-restart" in root("foreign", "clean", "hmgapi-wifi")
        assert not xml.exists() and not (temp / "property/persist.wifi.state").exists()
        assert "remount rw" in calls.read_text()
        assert "hmgapi-wifi" not in root("foreign", "status")
        # A Wi-Fi XML that differs from ours is not ours to judge.
        xml.write_text("<permissions/>")
        assert "hmgapi-wifi" not in root("foreign", "status")
    print("foreign package tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
