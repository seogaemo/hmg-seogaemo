#!/usr/bin/env python3
"""Installed module packages through the real dispatcher, runtime and reconcile."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile
from testlib import car_env, host_shell_tree, run_tests, SHELL

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = "NEEV.KOR.0000.V039.001.260902"

SAMPLE = {
    "module.properties": "id=sample\nversion=1.0.0\napi=1\ncars=NEEV.KOR.*.260902\nrerun_on=boot\nicon=wifi\n"
                         "uses=wifi.radio:ap\nsetting.1=audio:toggle:off\nsetting.2=mode:choice(fast|safe):safe\n",
    "apply.sh": "set_prop --reassert persist.test.mode {setting:mode}\n"
                "if setting_is audio on; then\n    set_prop persist.test.extra on\nfi\n",
    "status.sh": "info mode setting mode\n",
    "ui.txt": "status\ntoggle setting=audio label=@audio\n",
    "strings/en.txt": "name=Sample\nsummary=Test\naudio=Audio\n",
    "strings/ko.txt": "name=샘플\n",
}


def script(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


def extractor_classes():
    """Compile the HSM extractor once per source version; shards share the result."""
    source = ROOT / "core/hsm/src/com/seogaemo/hmg/core/hsm/HmgSeogaemoHsmExtract.java"
    cache = ROOT / "out/test-cache"
    classes = cache / ("hsm-extract-" + hashlib.sha256(source.read_bytes()).hexdigest()[:16])
    if not classes.is_dir():
        cache.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(dir=cache))
        subprocess.run(["javac", "-nowarn", "-d", str(staging), str(source)], check=True, capture_output=True)
        try:
            staging.rename(classes)
        except OSError:  # another shard published it first
            shutil.rmtree(staging)
    return classes


class Car:
    def __init__(self, temp):
        self.temp = temp
        self.base = temp / "package"
        shutil.copytree(ROOT / "nemesis/package", self.base)
        host_shell_tree(self.base)
        for path in self.base.rglob("*"):
            if path.is_file() and path.suffix in (".sh", "") and b"random/boot_id" in path.read_bytes():
                path.write_text(path.read_text().replace("/proc/sys/kernel/random/boot_id", str(temp / "boot_id")))
        (self.base / "modules").mkdir(exist_ok=True)
        (self.base / "modules.list").write_text("builtin-a\n")
        (self.base / "modules.graph").write_text("builtin-a\tdepends=\texcludes=\n")
        (self.base / "modules.lines").write_text("")
        (self.base / "modules/builtin-a.properties").write_text(
            "id=builtin-a\nversion=1.0.0\nowns_props=persist.builtin\n"
            "owns_files=/system/etc/builtin.conf\nservices=\ndepends=\nexcludes=\n")
        script(self.base / "modules/builtin-a.sh", "echo state=off; echo restart=none; echo detail=off\n")
        self.data = temp / "data"
        self.live = temp / "live"
        self.inbox = temp / "inbox"
        for path in (self.data, self.live, self.inbox, temp / "property"):
            path.mkdir()
        classes = extractor_classes()
        fake = temp / "fake"
        script(fake / "getprop", 'cat "$FAKE_LIVE/$1" 2>/dev/null || true\n')
        script(fake / "setprop", 'printf %s "$2" > "$FAKE_LIVE/$1"\n')
        script(fake / "app_process", f'shift; cls=$1; shift; exec java -cp "{classes}" "$cls" "$@"\n')
        script(fake / "pm", "echo package:fixture\n")
        self.prop("ro.build.product", PRODUCT)
        self.prop("ro.build.version.sdk", "19")
        self.prop("sys.boot_completed", "1")
        self.prop("persist.test.mode", "stock-mode")
        self.prop("persist.test.extra", "stock-extra")
        self.env = car_env(dict(os.environ, PATH=f"{fake}:{os.environ['PATH']}", FAKE_LIVE=str(self.live),
                                SG_DATA_ROOT=str(self.data), SG_PROPERTY_ROOT=str(temp / "property"),
                                SG_HSM_INBOX=str(self.inbox), SG_BOOT_ID_FILE=str(temp / "boot_id")))
        (temp / "boot_id").write_text("boot-1\n")

    def prop(self, key, value=None):
        if value is not None:
            (self.live / key).write_text(value)
        path = self.live / key
        return path.read_text() if path.exists() else ""

    def root(self, *args, code=0):
        result = subprocess.run([SHELL, str(self.base / "bin/hmg-seogaemo-root"), *args], env=self.env,
                                capture_output=True, text=True, timeout=120)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        return result.stdout

    def offer(self, files, digest_name=None):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            for name, text in files.items():
                archive.writestr(name, text)
        data = buffer.getvalue()
        digest = hashlib.sha256(data).hexdigest()
        (self.inbox / f"{digest_name or digest}.hsm").write_bytes(data)
        return digest_name or digest


def variant(**changes):
    files = dict(SAMPLE)
    files.update(changes)
    return {name: text for name, text in files.items() if text is not None}


def test_install_validation(car):
    assert "state=failed" in car.root("module", "install", "0" * 64, code=1)
    wrong = car.offer(SAMPLE, digest_name="1" * 64)
    assert "digest mismatch" in car.root("module", "install", wrong, code=1)
    bad_key = variant(**{"module.properties": SAMPLE["module.properties"] + "owns_props=persist.x\n"})
    assert "HSM-E203" in car.root("module", "install", car.offer(bad_key), code=1)
    bad_icon = variant(**{"module.properties": SAMPLE["module.properties"].replace("icon=wifi", "icon=../x.png")})
    assert "HSM-E204 module.properties: bad value for icon" in car.root("module", "install", car.offer(bad_icon), code=1)
    builtin = variant(**{"module.properties": SAMPLE["module.properties"].replace("id=sample", "id=builtin-a")})
    assert "built-in" in car.root("module", "install", car.offer(builtin), code=3)
    collide = variant(**{"apply.sh": "put_file /system/etc/builtin.conf files/x.conf\n", "files/x.conf": "x"})
    assert "builtin-a" in car.root("module", "install", car.offer(collide), code=3)
    syntax = variant(**{"apply.sh": "if car_is X; then\n"})
    result = subprocess.run([SHELL, str(car.base / "bin/hmg-seogaemo-root"), "module", "install", car.offer(syntax)],
                            env=car.env, capture_output=True, text=True)
    assert result.returncode == 2 and "HSM-E105 apply.sh:1:" in result.stderr, result
    big = variant(**{"strings/en.txt": SAMPLE["strings/en.txt"] + "".join(f"k{i}={'x' * 60}\n" for i in range(60))})
    assert "HSM-E208" in car.root("module", "install", car.offer(big), code=1)
    bad_key = variant(**{"strings/en.txt": SAMPLE["strings/en.txt"] + "Bad-Key=x\n"})
    assert "HSM-E209" in car.root("module", "install", car.offer(bad_key), code=1)
    other_car = variant(**{"module.properties": SAMPLE["module.properties"].replace("NEEV.KOR.*.260902", "OTHER.*")})
    assert "state=incompatible" in car.root("module", "install", car.offer(other_car), code=4)
    assert not (car.data / "installed/sample").exists()


def test_lifecycle(car):
    out = car.root("module", "install", car.offer(SAMPLE))
    assert "Installed sample 1.0.0" in out, out
    generated = (car.data / "installed/sample.properties").read_text().splitlines()
    for line in ("owns_props=persist.test.mode,persist.test.extra", "reassert_props=persist.test.mode",
                 "watch=boot", "uses=wifi.radio:ap", "source=direct"):
        assert line in generated, generated
    listing = car.root("module", "list")
    assert "info.module_builtin_a=builtin-a," in listing and "info.module_sample=sample,1.0.0,direct" in listing
    described = car.root("module", "describe", "sample", "ko").splitlines()
    for line in ("info.version=1.0.0", "info.source=direct", "info.restore=exact", "info.uses=wifi.radio:ap", "info.icon=wifi",
                 "info.setting_1=audio:toggle:off", "info.ui_1=status", "info.ui_2=toggle setting=audio label=@audio",
                 "info.str_name=Sample", "info.str_name=샘플", "info.str_audio=Audio", "state=on"):
        assert line in described, described
    assert described.index("info.str_name=Sample") < described.index("info.str_name=샘플")
    assert car.root("module", "describe", "sample", "en").count("info.str_name=") == 1
    car.root("module", "describe", "sample", "KO", code=2)
    car.root("module", "describe", "builtin-a", "en", code=1)
    assert "state=off" in car.root("sample", "status")
    assert "state=on" in car.root("sample", "apply")
    assert car.prop("persist.test.mode") == "safe" and car.prop("persist.test.extra") == "stock-extra"
    assert "info.mode=safe" in car.root("sample", "status")
    car.root("sample", "set", "audio", "on")
    assert car.prop("persist.test.extra") == "on"
    car.root("sample", "set", "mode", "fast")
    assert car.prop("persist.test.mode") == "fast" and car.prop("persist.test.extra") == "on"
    car.root("sample", "set", "audio", "off")
    assert car.prop("persist.test.extra") == "stock-extra", "branch target survived a setting change"
    car.root("sample", "set", "mode", "turbo", code=2)
    car.root("builtin-a", "set", "mode", "fast", code=2)
    car.root("sample", "set", "MODE", "fast", code=2)

    clash = variant(**{"module.properties": SAMPLE["module.properties"].replace("id=sample", "id=clash")
                       .replace("wifi.radio:ap", "wifi.radio:sta"),
                       "apply.sh": "set_prop persist.test.clash on\n"})
    car.root("module", "install", car.offer(clash))
    assert "Conflicts with module on: sample" in car.root("clash", "apply", code=3)
    car.root("module", "remove", "clash")

    (car.data / "desired/sample").write_text("on")
    car.prop("persist.test.mode", "fast")
    assert "state=on" in car.root("sample", "watch", "boot")

    car.root("module", "install", car.offer(SAMPLE), code=3)
    out = car.root("module", "remove", "sample")
    assert "Removed sample" in out, out
    assert car.prop("persist.test.mode") == "stock-mode" and car.prop("persist.test.extra") == "stock-extra"
    assert "sample" not in (car.data / "installed.list").read_text()
    assert not (car.data / "installed/sample").exists() and not (car.data / "desired/sample").exists()
    car.root("sample", "status", code=2)


def test_reconcile_reapplies(car):
    car.root("module", "install", car.offer(SAMPLE))
    car.root("sample", "apply")
    car.prop("persist.test.mode", "lost-on-reboot")
    (car.temp / "boot_id").write_text("boot-2\n")
    result = subprocess.run([SHELL, str(car.base / "svc/reconcile.sh")], env=car.env,
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert car.prop("persist.test.mode") == "safe", (car.data / "reconcile.log").read_text() \
        if (car.data / "reconcile.log").exists() else result
    out = car.root("stock", "restore")
    assert "state=off" in out and "info.module_sample=reverted" in out, out
    assert car.prop("persist.test.mode") == "stock-mode"


def hooker(module_id, process):
    return {
        "module.properties": f"id={module_id}\nversion=1.0.0\napi=1\ncars=NEEV.KOR.*.260902\n",
        "apply.sh": f"hook_apps files/hook.jar demo.Entry {process} com.daudio.app.dipo:remote\n",
        "files/hook.jar": f"jar-{module_id}",
        "strings/en.txt": "name=Hooker\nsummary=Test\n",
    }


def test_hook_host(car):
    target = car.temp / "target"
    for sub in ("system/bin", "system/lib", "system/framework", "data/dalvik-cache"):
        (target / sub).mkdir(parents=True)
    process = target / "system/bin/app_process"
    process.write_bytes(b"stock-executable")
    process.chmod(0o755)
    data = car.base / "core/hook/data"
    data.mkdir(parents=True)
    for name, body in (("app_process", b"wrapper"), ("libhmg_seogaemo_hook.so", b"loader"), ("hmg-seogaemo-hook.jar", b"engine")):
        (data / name).write_bytes(body)
    fake = Path(car.env["PATH"].split(":")[1])
    for name in ("ls", "chown"):
        script(fake / name, f'exec /bin/sh "{ROOT / "tools/testlib/fake-ownership.sh"}" {name} "$@"\n')
    script(fake / "nemesis", "exit 0\n")
    car.env.update(SG_TARGET_ROOT=str(target), FAKE_OWNERS=str(car.temp / "owners.json"))
    extras = [target / "system/bin/app_process.hmg-seogaemo-stock", target / "system/lib/libhmg_seogaemo_hook.so",
              target / "system/framework/hmg-seogaemo-hook.jar"]
    mods = car.data / "core/hook/mods"

    car.root("module", "install", car.offer(hooker("hook-one", "com.android.settings")))
    generated = (car.data / "installed/hook-one.properties").read_text().splitlines()
    assert "hooks=1" in generated and "restart=head_unit" in generated, generated
    # Hook modules share the core host with CarPlay; no generated exclusion.
    assert "excludes=" in generated and "excludes=wireless-carplay-and-aa" not in generated, generated
    assert any(line.startswith("owns_files=") and f"{mods}/hook-one/entry" in line for line in generated), generated
    out = car.root("hook-one", "apply")
    assert "state=pending-restart" in out and "restart=head_unit" in out, out
    assert process.read_bytes() == b"wrapper" and extras[0].read_bytes() == b"stock-executable", out
    assert extras[1].read_bytes() == b"loader" and extras[2].read_bytes() == b"engine"
    assert (car.data / "modules/core-hook/enable").exists() and (car.data / "modules/core-hook/enabled").exists()
    assert (mods / "hook-one/entry").read_text() == "demo.Entry\n"
    assert (mods / "hook-one/processes").read_text() == "com.android.settings\ncom.daudio.app.dipo:remote\n"
    assert (mods / "hook-one/hook.jar").read_bytes() == b"jar-hook-one"
    (car.data / "core/hook/status").write_text("pid=1\ngate=ready 1\nmod.hook-one=loaded 2 process(es)\n")
    status = car.root("hook-one", "status")
    for line in ("info.hook_host=on", "info.hook_gate=ready 1", "info.hook_load=loaded 2 process(es)"):
        assert line in status, status
    # After the restart, the boot-time re-apply of an applied module must not ask for another one.
    (car.temp / "boot_id").write_text("boot-hook\n")
    out = car.root("hook-one", "apply")
    assert "state=on" in out, out
    assert "state=on" in car.root("hook-one", "status")

    car.root("module", "install", car.offer(hooker("hook-two", "com.mnsoft.navi")))
    car.root("hook-two", "apply")
    out = car.root("hook-one", "revert")
    assert "state=pending-restart" in out, out
    assert process.read_bytes() == b"wrapper", "wrapper removed while another hook module is on"
    assert not (mods / "hook-one/entry").exists() and (mods / "hook-two/entry").exists()
    car.root("hook-two", "revert")
    assert process.read_bytes() == b"stock-executable", "stock app_process not restored"
    assert not any(path.exists() for path in extras), extras
    assert not list(mods.glob("*/entry")) and not (car.data / "core/hook/dex").exists()
    assert not list((car.data / "modules/core-hook").glob("file.*/ready"))

    car.root("hook-one", "apply")
    assert process.read_bytes() == b"wrapper"
    out = car.root("stock", "restore")
    assert "info.module_hook_one=reverted" in out, out
    assert process.read_bytes() == b"stock-executable" and not any(path.exists() for path in extras), out
    car.root("module", "remove", "hook-one")
    car.root("module", "remove", "hook-two")


def test_button_action(car):
    pkg = variant(**{"module.properties": SAMPLE["module.properties"].replace("id=sample", "id=buttons")
                     .replace("rerun_on=boot\n", ""),
                     "apply.sh": "set_prop persist.test.mode on\nif action_is rescan; then\n"
                                 "    set_prop persist.test.extra rescanned\nfi\n",
                     "ui.txt": "button name=rescan label=@audio confirm=@audio\n"})
    car.root("module", "install", car.offer(pkg))
    assert "Turn the module on first" in car.root("buttons", "action", "rescan", code=3)
    car.root("buttons", "apply")
    (car.data / "desired/buttons").write_text("on")
    assert car.prop("persist.test.extra") == "stock-extra"
    assert "Unknown button" in car.root("buttons", "action", "other", code=1)
    car.root("buttons", "action", "Bad", code=2)
    car.root("builtin-a", "action", "rescan", code=2)
    out = car.root("buttons", "action", "rescan")
    assert "state=on" in out, out
    assert car.prop("persist.test.extra") == "rescanned"
    assert "state=off" in car.root("buttons", "revert")
    assert car.prop("persist.test.extra") == "stock-extra" and car.prop("persist.test.mode") == "stock-mode"


def test_usb_import(car):
    usb, unmounted, app = car.base.parent / "usb0", car.base.parent / "usb1", car.base.parent / "app-files"
    dest = app / "hsm-usb"
    for path in (usb, unmounted):
        (path / "HSM").mkdir(parents=True)
    mounts = car.base.parent / "mounts"
    mounts.write_text(f"/dev/block/sda1 {usb} vfat rw 0 0\n")
    car.env.update(SG_USB_DIRS=f"{usb} {unmounted}", SG_MOUNTS_FILE=str(mounts), SG_HSM_USB_INBOX=str(dest))
    assert "App storage not ready" in car.root("module", "usb-import", code=1)
    app.mkdir()
    dest.mkdir()
    (dest / "stale.hsm").write_text("old")
    folder = usb / "HSM"
    (usb / "top-level.hsm").write_bytes(b"PK-top")
    (folder / "theme-1.0.hsm").write_bytes(b"PK-theme")
    (folder / "UPPER.HSM").write_bytes(b"PK-upper")
    (folder / "bad name.hsm").write_bytes(b"PK")
    (folder / ".hidden.hsm").write_bytes(b"PK")
    (folder / "empty.hsm").write_bytes(b"")
    (folder / "notes.txt").write_text("x")
    (folder / "link.hsm").symlink_to(folder / "theme-1.0.hsm")
    (unmounted / "HSM" / "other.hsm").write_bytes(b"PK-other")
    out = car.root("module", "usb-import")
    assert "state=on" in out and "info.count=2" in out, out
    assert sorted(path.name for path in dest.iterdir()) == ["UPPER.hsm", "theme-1.0.hsm"]
    assert (dest / "theme-1.0.hsm").read_bytes() == b"PK-theme"
    assert oct(dest.stat().st_mode & 0o777) == "0o755"
    assert oct((dest / "theme-1.0.hsm").stat().st_mode & 0o777) == "0o644"
    (folder / "theme-1.0.hsm").unlink()
    (folder / "UPPER.HSM").unlink()
    assert "info.count=0" in car.root("module", "usb-import")
    assert list(dest.iterdir()) == []
    car.root("module", "usb-import", "x", code=2)


RAW = {
    "module.properties": "id=raw-demo\nversion=1.0.0\napi=1\ncars=NEEV.KOR.*.260902\nraw_shell=1\n"
                         "owns_props=persist.raw.demo\n",
    "module.sh": '. "$HMG_SEOGAEMO_BASE/lib/common.sh"\n'
                 'case "$1" in\n'
                 '    status) if sg_applied persist.raw.demo; then sg_status on none on; else sg_status off none off; fi ;;\n'
                 '    precheck) sg_status off none ready ;;\n'
                 '    apply) sg_prop_set persist.raw.demo on && sg_status on none on ;;\n'
                 '    revert) sg_revert_all && sg_status off none off ;;\n'
                 '    *) exit 2 ;;\n'
                 'esac\nexit $?\n',
    "strings/en.txt": "name=Raw\nsummary=Bundled raw module\n",
}


def bundle(car, files):
    (car.base / "bundled").mkdir(exist_ok=True)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, text in files.items():
            archive.writestr(name, text)
    (car.base / "bundled/raw-demo.hsm").write_bytes(buffer.getvalue())
    (car.base / "bundled/raw-demo.sha256").write_text(hashlib.sha256(buffer.getvalue()).hexdigest())


def test_bundled(car):
    direct_raw = variant(**{"module.properties": SAMPLE["module.properties"] + "raw_shell=1\n"})
    assert "HSM-E202" in car.root("module", "install", car.offer(direct_raw), code=1)
    bundle(car, RAW)
    first = car.root("module", "install-bundled")
    listed = car.root("module", "list")
    assert "raw-demo,1.0.0,bundled" in listed, (first, listed)
    assert "bundle_sha256=" in (car.data / "installed/raw-demo.properties").read_text()
    # A reserved ID cannot come in through the inbox.
    assert "bundled with HMG-Seogaemo" in car.root("module", "install", car.offer(RAW), code=3)
    assert "state=on" in car.root("raw-demo", "apply")
    assert car.prop("persist.raw.demo") == "on"
    # Same targets: replaced in place while on, state kept.
    bundle(car, dict(RAW, **{"module.properties": RAW["module.properties"].replace("1.0.0", "1.0.1")}))
    car.root("module", "install-bundled")
    assert "raw-demo,1.0.1,bundled" in car.root("module", "list")
    assert "state=on" in car.root("raw-demo", "status")
    # Different targets while on: the old copy stays.
    wider = RAW["module.properties"].replace("1.0.0", "1.0.2").replace("persist.raw.demo", "persist.raw.demo,persist.raw.more")
    bundle(car, dict(RAW, **{"module.properties": wider}))
    assert "Turn raw-demo off" in car.root("module", "install-bundled")
    assert "raw-demo,1.0.1,bundled" in car.root("module", "list")
    # Removal is remembered; the next check does not bring it back.
    car.root("module", "remove", "raw-demo")
    assert car.prop("persist.raw.demo") != "on"
    assert (car.data / "bundled-removed/raw-demo").is_file()
    car.root("module", "install-bundled")
    assert "raw-demo" not in car.root("module", "list")


def raw_package(module_id, props, extra=""):
    return {"module.properties": f"id={module_id}\nversion=1.0.0\napi=1\ncars=NEEV.KOR.*.260902\nraw_shell=1\n"
                                  f"owns_props={props}\n{extra}",
            "module.sh": RAW["module.sh"].replace("persist.raw.demo", props),
            "strings/en.txt": "name=Raw\nsummary=Bundled raw module\n"}


def bundle_as(car, module_id, files):
    (car.base / "bundled").mkdir(exist_ok=True)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, text in files.items():
            archive.writestr(name, text)
    for old in (car.base / "bundled").iterdir():
        old.unlink()
    (car.base / f"bundled/{module_id}.hsm").write_bytes(buffer.getvalue())
    (car.base / f"bundled/{module_id}.sha256").write_text(hashlib.sha256(buffer.getvalue()).hexdigest())


def test_add_bundled(car):
    # A removed bundled module is listed with its names and can be added back; failures change nothing.
    def listing(locale="en"):
        return car.root("module", "list-removed", locale)

    bundle(car, RAW)
    (car.base / "bundled/raw-demo.strings.en").write_text("name=Raw\nsummary=Bundled raw module\n")
    (car.base / "bundled/raw-demo.strings.ko").write_text("name=원시\nsummary=번들 원시 모듈\n")
    car.root("module", "install-bundled")
    assert "info.removed_" not in listing()
    car.root("module", "remove", "raw-demo")
    props = car.base / "modules/raw-demo.properties"
    props.write_text("id=raw-demo\nversion=1.0.0\nicon=wifi\n")
    out = listing()
    props.unlink()
    assert "info.removed_1=raw-demo,1.0.0,wifi" in out and "info.removed_1_name=Raw" in out, out
    assert "info.removed_1_name=원시" in listing("ko") and "info.removed_1_summary=번들 원시 모듈" in listing("ko")
    # Fixed verbs only.
    car.root("module", "list-removed", "english", code=2)
    car.root("module", "add-bundled", "Raw-Demo", code=2)
    car.root("module", "add-bundled", "../raw-demo", code=2)
    assert "is not a bundled module" in car.root("module", "add-bundled", "unknown-id", code=1)
    # A failing install puts the marker back.
    good = (car.base / "bundled/raw-demo.hsm").read_bytes()
    (car.base / "bundled/raw-demo.sha256").write_text("0" * 64)
    out = car.root("module", "add-bundled", "raw-demo", code=1)
    assert "Could not add raw-demo" in out, out
    assert (car.data / "bundled-removed/raw-demo").is_file() and "raw-demo" not in car.root("module", "list")
    (car.base / "bundled/raw-demo.sha256").write_text(hashlib.sha256(good).hexdigest())
    out = car.root("module", "add-bundled", "raw-demo")
    assert "Added raw-demo" in out, out
    assert "raw-demo,1.0.0,bundled" in car.root("module", "list")
    assert not (car.data / "bundled-removed/raw-demo").exists() and "info.removed_" not in listing()
    assert "state=on" in car.root("raw-demo", "apply")
    # Installed or never removed: refused.
    assert "was not removed" in car.root("module", "add-bundled", "raw-demo", code=1)
    # A module whose replaced predecessors were all removed comes back when the owner asks for it.
    owned = "owns_files=/system/etc/raw-demo.conf\n"
    car.root("module", "remove", "raw-demo")
    (car.data / "bundled-removed/raw-demo").unlink()
    bundle_as(car, "new-raw", raw_package("new-raw", "persist.raw.demo", owned + "replaces=old-raw\n"))
    (car.data / "bundled-removed").mkdir(exist_ok=True)
    (car.data / "bundled-removed/old-raw").write_text("")
    assert "stays removed" in car.root("module", "install-bundled")
    assert "info.removed_1=new-raw," in listing()
    assert "Added new-raw" in car.root("module", "add-bundled", "new-raw")
    assert "new-raw,1.0.0,bundled" in car.root("module", "list")
    assert not (car.data / "bundled-removed/new-raw").exists()


def test_replaces(car):
    # A package update renames a bundled module that is on: the new id takes over state without a write.
    # Both own the same file, so the installer must not count the old module as a colliding owner.
    owned = "owns_files=/system/etc/raw-demo.conf\n"
    bundle_as(car, "old-raw", raw_package("old-raw", "persist.raw.demo", owned))
    car.root("module", "install-bundled")
    assert "state=on" in car.root("old-raw", "apply")
    assert car.prop("persist.raw.demo") == "on"
    (car.data / "settings/old-raw").mkdir(parents=True)
    (car.data / "settings/old-raw/mode").write_text("x")
    before = (car.data / "ledger/ledger.tsv").read_text().count("prop_set")
    renamed = raw_package("new-raw", "persist.raw.demo", owned + "replaces=old-raw\nkmods=x8188\nkmod.x8188=files/x.ko\n")
    renamed["files/x.ko"] = "ko"
    # A target the old module owns is missing from the new one: the old module stays and nothing moves.
    wider = dict(renamed, **{"module.properties": renamed["module.properties"].replace(
        "owns_props=persist.raw.demo", "owns_props=persist.raw.other")})
    bundle_as(car, "new-raw", wider)
    assert "does not touch the same targets" in car.root("module", "install-bundled")
    assert "old-raw,1.0.0,bundled" in car.root("module", "list") and (car.data / "modules/old-raw").is_dir()
    assert not (car.data / "migrate/new-raw").exists()
    bundle_as(car, "new-raw", renamed)
    out = car.root("module", "install-bundled")
    listed = car.root("module", "list")
    assert "new-raw,1.0.0,bundled" in listed and "old-raw" not in listed, (out, listed)
    assert (car.data / "installed.list").read_text().split() == ["new-raw"]
    assert not (car.data / "installed/old-raw").exists() and not (car.data / "installed/old-raw.properties").exists()
    assert (car.data / "desired/new-raw").read_text() == "on" and not (car.data / "desired/old-raw").exists()
    assert (car.data / "settings/new-raw/mode").read_text() == "x"
    assert (car.data / "modules/new-raw/prop.persist.raw.demo").is_dir() and not (car.data / "modules/old-raw").exists()
    assert not (car.data / "migrate/new-raw").exists()
    ledger = (car.data / "ledger/ledger.tsv").read_text()
    assert "\tnew-raw\tmodule_takeover\told-raw\t" in ledger and ledger.count("prop_set") == before
    assert car.prop("persist.raw.demo") == "on"
    assert "state=on" in car.root("new-raw", "status")
    # The taken-over baseline restores stock exactly.
    assert "state=off" in car.root("new-raw", "revert")
    assert car.prop("persist.raw.demo") != "on"
    # An interrupted takeover (journal written, state moved, old package still listed) finishes next time.
    car.root("module", "remove", "new-raw")
    (car.data / "bundled-removed/new-raw").unlink()
    bundle_as(car, "old-raw", raw_package("old-raw", "persist.raw.demo", owned))
    car.root("module", "install-bundled")
    assert "state=on" in car.root("old-raw", "apply")
    (car.data / "migrate").mkdir(exist_ok=True)
    (car.data / "migrate/new-raw").write_text("old-raw")
    (car.data / "modules/old-raw").rename(car.data / "modules/new-raw")
    bundle_as(car, "new-raw", renamed)
    car.root("module", "install-bundled")
    assert "new-raw,1.0.0,bundled" in car.root("module", "list")
    assert not (car.data / "migrate/new-raw").exists() and not (car.data / "installed/old-raw").exists()
    assert "state=on" in car.root("new-raw", "status")
    assert "state=off" in car.root("new-raw", "revert")
    # An old module the owner removed keeps its successor removed.
    car.root("module", "remove", "new-raw")
    for name in ("new-raw", "old-raw"):
        (car.data / f"bundled-removed/{name}").unlink(missing_ok=True)
    bundle_as(car, "old-raw", raw_package("old-raw", "persist.raw.demo", owned))
    car.root("module", "install-bundled")
    car.root("module", "remove", "old-raw")
    bundle_as(car, "new-raw", renamed)
    assert "stays removed" in car.root("module", "install-bundled")
    assert "new-raw" not in car.root("module", "list") and (car.data / "bundled-removed/new-raw").is_file()
    # Only a bundled package may declare replaces=.
    direct = variant(**{"module.properties": SAMPLE["module.properties"] + "replaces=old-raw\n"})
    assert "HSM-E203" in car.root("module", "install", car.offer(direct), code=1)


def test_converted_builtin(car):
    # Every converted module packs, installs as bundled, keeps its touched list and runs its own root script.
    sys.path.insert(0, str(ROOT / "tools"))
    from package import bundled_hsm
    expected = {
        "skip-consent-screen": ("raw_shell=1", "restore=reboot", "service_calls=com.hkmc.factory:82", "watch=boot,screen_on"),
        "user-button": ("raw_shell=1", "owns_props=persist.sys.key.custom,persist.sys.key.swrccustom",
                        "reassert_props=persist.sys.key.custom,persist.sys.key.swrccustom", "watch=boot,screen_on",
                        "restart=none"),
        "wireless-adb": ("raw_shell=1", "owns_props=persist.service.adb.tcp.enable,persist.adb.tcp.port",
                         "services=adbd", "restart=adbd"),
        "wifi": ("raw_shell=1", "owns_props=persist.wifi.state",
                 "owns_files=/system/etc/permissions/android.hardware.wifi.xml",
                 "excludes=", "restart=head_unit", "kmods=88x2bu,8851bu", "owns_ifaces=rtwlan*",
                 "watch=boot,screen_on"),
        "wireless-carplay-and-aa": ("raw_shell=1", "hooks=1", "restart=head_unit",
                                    "known_stock.1=*.KOR.*:/system/bin/app_process:33f798115689d1859e8d2159dc88e7dc",
                                    "owns_lines.1=/system/onebin/neev_kr/featurexml.cfg:-/system/etc/permissions/com.hkmc.software.connectivity.carplay_wireless.xml",
                                    "owns_props=persist.ium.support,persist.sys.iap2.wifi,persist.iap2.iden.wireless"),
    }
    converted = sorted(p.parent.name for p in (ROOT / "modules").glob("*/module.properties")
                       if "\napi=" in "\n" + p.read_text())
    assert set(expected) <= set(converted), converted
    (car.base / "bundled").mkdir(exist_ok=True)
    (car.data / "desired").mkdir(exist_ok=True)
    for module_id in converted:
        data = bundled_hsm(ROOT / "modules" / module_id, "1.2.3")
        (car.base / f"bundled/{module_id}.hsm").write_bytes(data)
        (car.base / f"bundled/{module_id}.sha256").write_text(hashlib.sha256(data).hexdigest())
    (car.data / "desired/skip-consent-screen").write_text("on")
    # Updating from a package where CarPlay was a built-in that is on: its state stays and the
    # first bundled install must not refuse it (it moves on its next apply).
    (car.data / "desired/wireless-carplay-and-aa").write_text("on")
    legacy = car.data / "modules/wireless-carplay-and-aa/file.0123456789abcdef0123456789abcdef"
    legacy.mkdir(parents=True)
    (legacy / "ready").write_text("")
    out = car.root("module", "install-bundled")
    listed = car.root("module", "list")
    for module_id in converted:
        assert f"{module_id},1.2.3,bundled" in listed, (module_id, out)
        manifest = (car.data / f"installed/{module_id}.properties").read_text().splitlines()
        for line in expected.get(module_id, ()):
            assert line in manifest, (module_id, line, manifest)
        described = car.root("module", "describe", module_id, "ko")
        assert "info.str_name=" in described and "info.str_summary=" in described, described
        status = subprocess.run([SHELL, str(car.base / "bin/hmg-seogaemo-root"), module_id, "status"],
                                env=car.env, capture_output=True, text=True, timeout=120).stdout
        assert "state=" in status, (module_id, status)
    assert (car.data / "installed/skip-consent-screen.hookpoints").read_text().strip()
    status = subprocess.run([SHELL, str(car.base / "bin/hmg-seogaemo-root"), "skip-consent-screen", "status"],
                            env=car.env, capture_output=True, text=True, timeout=120).stdout
    assert "info.desired=on" in status, status


def line_module(module_id, path, stock, new):
    return {
        "module.properties": f"id={module_id}\nversion=1.0.0\napi=1\ncars=NEEV.KOR.*.260902\n",
        "apply.sh": f'replace_line {path} "{stock}" "{new}"\n',
        "strings/en.txt": "name=Line\nsummary=Test\n",
    }


def test_installed_shared_line(car):
    # Modules added from a user .hsm keep their manifest only under installed/; they share one
    # stock file line by line, and the installer refuses a second owner of the same line.
    # Shared-line operations act on the literal path; use a scratch file the way
    # test-line-ownership does.
    shared = car.temp / "shared.cfg"
    stock = b"alpha\nbeta\nkeep\n"
    shared.write_bytes(stock)
    fake = Path(car.env["PATH"].split(":")[1])
    for name in ("ls", "chown"):
        script(fake / name, f'exec /bin/sh "{ROOT / "tools/testlib/fake-ownership.sh"}" {name} "$@"\n')
    script(fake / "nemesis", "exit 0\n")
    car.env.update(FAKE_OWNERS=str(car.temp / "owners.json"))

    car.root("module", "install", car.offer(line_module("line-a", shared, "alpha", "A")))
    car.root("module", "install", car.offer(line_module("line-b", shared, "beta", "B")))
    assert not (car.base / "modules/line-a.properties").exists()
    assert f"owns_lines.1={shared}:alpha" in (car.data / "installed/line-a.properties").read_text()
    assert "line-a" in car.root("module", "install", car.offer(line_module("line-c", shared, "alpha", "C")), code=3)

    assert "state=on" in car.root("line-a", "apply")
    assert "state=on" in car.root("line-b", "apply")
    assert shared.read_bytes() == b"A\nB\nkeep\n"
    car.root("line-a", "revert")
    assert shared.read_bytes() == b"alpha\nB\nkeep\n"
    car.root("line-b", "revert")
    assert shared.read_bytes() == stock
    car.root("line-a", "apply")
    car.root("module", "remove", "line-a")
    car.root("module", "remove", "line-b")
    assert shared.read_bytes() == stock


MERGED_SH = ('. "$HMG_SEOGAEMO_BASE/lib/common.sh"\n'
             'on() { [ "$(cat "$SG_DATA_ROOT/settings/merged-btn/$1" 2>/dev/null)" = on ]; }\n'
             'case "$1" in\n'
             '    status) sg_status on none on ;;\n'
             '    precheck) sg_status off none ready ;;\n'
             '    apply) if on a; then sg_prop_set persist.btn.a mine || exit 1; fi\n'
             '           if on b; then sg_prop_set persist.btn.b mine || exit 1; fi; sg_status on none on ;;\n'
             '    revert) sg_revert_all && sg_status off none off ;;\n'
             '    *) exit 2 ;;\n'
             'esac\nexit $?\n')


def test_merged_takeover(car):
    # Two bundled modules merge into one; each old module's state, baseline and on/off choice survive.
    for a_on in (False, True):
        for b_on in (False, True):
            c = Car(Path(tempfile.mkdtemp(dir=car.temp)))
            for key in ("a", "b"):
                c.prop(f"persist.btn.{key}", f"stock-{key}")
                bundle_as(c, f"old-{key}", raw_package(f"old-{key}", f"persist.btn.{key}"))
                c.root("module", "install-bundled")
            for key, on in (("a", a_on), ("b", b_on)):
                if on:
                    assert "state=on" in c.root(f"old-{key}", "apply")
            merged = {"module.properties": "id=merged-btn\nversion=1.0.0\napi=1\ncars=NEEV.KOR.*.260902\nraw_shell=1\n"
                      "owns_props=persist.btn.a,persist.btn.b\nsetting.1=a:toggle:off\nsetting.2=b:toggle:off\n"
                      "replaces=old-a,old-b\nreplaces_setting.old-a=a:on\nreplaces_setting.old-b=b:on\n",
                      "module.sh": MERGED_SH, "strings/en.txt": "name=Merged\nsummary=Test\n"}
            bundle_as(c, "merged-btn", merged)
            out = c.root("module", "install-bundled")
            listed = c.root("module", "list")
            assert "merged-btn,1.0.0,bundled" in listed and "old-a" not in listed and "old-b" not in listed, (out, listed)
            assert (c.data / "installed.list").read_text().split() == ["merged-btn"]
            desired = c.data / "desired/merged-btn"
            assert (desired.read_text() if desired.exists() else "") == ("on" if a_on or b_on else ""), (a_on, b_on)
            for key, on in (("a", a_on), ("b", b_on)):
                setting = c.data / "settings/merged-btn" / key
                assert (setting.read_text() if setting.exists() else "off") == ("on" if on else "off")
                assert (c.data / "modules/merged-btn" / f"prop.persist.btn.{key}").is_dir() == on
                assert not (c.data / f"modules/old-{key}").exists() and not (c.data / f"desired/old-{key}").exists()
                assert c.prop(f"persist.btn.{key}") == ("on" if on else f"stock-{key}")  # takeover writes nothing
            ledger = (c.data / "ledger/ledger.tsv").read_text()
            assert "\tmerged-btn\tmodule_takeover\told-a\t" in ledger and "\tmerged-btn\tmodule_takeover\told-b\t" in ledger
            assert not (c.data / "migrate/merged-btn").exists()
            if a_on or b_on:
                assert "state=off" in c.root("merged-btn", "revert")
            assert c.prop("persist.btn.a") == "stock-a" and c.prop("persist.btn.b") == "stock-b"


def on_car(test):
    def run(folder):
        test(Car(folder))
    run.__name__ = test.__name__
    return run


if __name__ == "__main__":
    run_tests([on_car(test) for test in (
        test_install_validation, test_lifecycle, test_reconcile_reapplies, test_hook_host, test_usb_import,
        test_button_action, test_bundled, test_add_bundled, test_replaces, test_merged_takeover, test_converted_builtin, test_installed_shared_line)],
        "installed module tests passed")
