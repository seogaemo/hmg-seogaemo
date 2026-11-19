#!/usr/bin/env python3
"""Exercise the release module with the real installer and synthetic vehicle files."""
import gzip
import hashlib
import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path
import struct
import subprocess

from testlib import run_tests

ROOT = Path(__file__).resolve().parents[1]
loader = SourceFileLoader("install", str(ROOT / "tools/test-module-install.py"))
install = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(install)


def exercise(car, enhanced):
    files = {p.relative_to(ROOT / "extras/n-mode").as_posix(): p.read_bytes()
             for p in (ROOT / "extras/n-mode").rglob("*") if p.is_file()}
    prefix = str(car.temp / "system")
    onebin = "cn7_kr" if enhanced else "igpehev_kr"
    car.prop("ro.mobis.onebindir", onebin)
    car.prop("ro.product.name", "wp_daudioplus_" + onebin)
    car.prop("ro.build.product", ("CN7" if enhanced else "IGPEHEV") + ".KOR.0000.V039.001.260902")
    fake = Path(car.env["PATH"].split(":")[1])
    for name in ("chown", "ls"):
        install.script(fake / name, f'exec /bin/sh "{ROOT}/tools/testlib/fake-ownership.sh" {name} "$@"\n')
    car.env["FAKE_OWNERS"] = str(car.temp / "owners")
    hsm = car.base / "lib/hsm.sh"
    hsm.write_text(hsm.read_text().replace("prefix=/system/onebin/", "prefix=" + prefix + "/onebin/"))
    # Redirect filesystem arguments, preserving the literal stock line.
    for name in ("check.sh", "apply.sh"):
        files[name] = files[name].replace(b" /system/", b" " + prefix.encode() + b"/")
    cfg = Path(prefix) / "onebin" / onebin / "pkg.cfg"
    cfg.parent.mkdir(parents=True)
    line = b"-/system/app/HKMC_NModeApp.apk"
    cfg_stock = b"other=keep\n" + line + b"\nlast=keep "
    cfg.write_bytes(cfg_stock)
    apk = Path(prefix) / "app/HKMC_NModeApp.apk"
    apk.parent.mkdir()
    apk.touch()
    odex = apk.with_suffix(".odex")
    original = b"synthetic stock"
    target = b"synthetic gauge"
    odex.write_bytes(original)
    classes = car.temp / "classes"
    subprocess.run(["javac", "-d", str(classes), str(ROOT / "core/hsm/src/com/seogaemo/hmg/core/hsm/HmgSeogaemoStockDelta.java")], check=True)
    install.script(fake / "app_process", f'shift; cls=$1; shift; exec java -cp "{classes}:{install.extractor_classes()}" "$cls" "$@"\n')
    sha = lambda data: hashlib.sha256(data).digest()
    files["files/display.delta.gz"] = gzip.compress(b"HSD1" + sha(original) + sha(target) +
        struct.pack(">IIIiii", len(original), len(target), 1, 0, len(target), 0) + target)
    files["apply.sh"] = files["apply.sh"].replace(b"80f6f4c705a0655032a24d88384d61e0", hashlib.md5(original).hexdigest().encode())
    car.root("module", "install", car.offer(files))
    assert str(cfg) in (car.data / "installed/cn7-n-mode.properties").read_text()
    car.root("cn7-n-mode", "apply")
    assert cfg.read_bytes() == cfg_stock.replace(line, b"# HMG-Seogaemo N Mode")
    assert odex.read_bytes() == (target if enhanced else original)
    car.root("cn7-n-mode", "apply")
    car.root("cn7-n-mode", "revert")
    assert cfg.read_bytes() == cfg_stock and odex.read_bytes() == original
    if enhanced:
        files["files/display.delta.gz"] = gzip.compress(b"invalid delta")
        car.root("module", "install", car.offer(files))
        result = subprocess.run([install.SHELL, str(car.base / "bin/hmg-seogaemo-root"), "cn7-n-mode", "apply"], env=car.env)
        assert result.returncode != 0 and odex.read_bytes() == original and cfg.read_bytes() == cfg_stock


def test_other_onebin(car):
    exercise(car, False)


def test_compatible_bridge_and_rollback(car):
    exercise(car, True)


if __name__ == "__main__":
    run_tests([install.on_car(test_other_onebin), install.on_car(test_compatible_bridge_and_rollback)],
              "N Mode module tests passed")
