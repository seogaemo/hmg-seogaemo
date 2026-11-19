#!/usr/bin/env python3
"""Raw partition ranges (put_partition, sg_partition_put) through the real dispatcher and runtime."""
import hashlib
import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path
import subprocess
from testlib import run_tests, SHELL

ROOT = Path(__file__).resolve().parents[1]
_loader = SourceFileLoader("module_install_tests", str(ROOT / "tools/test-module-install.py"))
install = importlib.util.module_from_spec(importlib.util.spec_from_loader(_loader.name, _loader))
_loader.exec_module(install)

SECTOR = 512
SECTORS = 16
OFFSET = 4 * SECTOR
STOCK = bytes((i * 7 + i // SECTOR) % 251 for i in range(SECTORS * SECTOR))
PAYLOAD = bytes(255 - (i % 256) for i in range(2 * SECTOR))
CLAIM = f"splash:{OFFSET}:{len(PAYLOAD)}"


def splash(car, read_only="0"):
    """The unit's splash partition: a sysfs entry found by name and a regular file as its node."""
    sys_root, dev_root = car.temp / "sys-block", car.temp / "dev-block"
    dev_root.mkdir()
    for dev, name in (("mmcblk0p5", "boot"), ("mmcblk0p6", "splash")):
        (sys_root / dev).mkdir(parents=True)
        (sys_root / dev / "uevent").write_text(f"MAJOR=179\nDEVNAME={dev}\nDEVTYPE=partition\nPARTNAME={name}\n")
        (sys_root / dev / "size").write_text(f"{SECTORS}\n")
        (sys_root / dev / "ro").write_text("0\n")
        (dev_root / dev).write_bytes(STOCK)
    (sys_root / "mmcblk0p6/ro").write_text(read_only + "\n")
    car.env.update(HMG_SEOGAEMO_BLOCK_SYS_ROOT=str(sys_root), HMG_SEOGAEMO_BLOCK_DEV_ROOT=str(dev_root))
    return dev_root / "mmcblk0p6"


def stock_md5(offset=OFFSET, length=len(PAYLOAD)):
    return hashlib.md5(STOCK[offset:offset + length]).hexdigest()


def logo(module_id="logo", offset=OFFSET, name="splash", payload=PAYLOAD, stock=None, apply=None):
    stock = f"stock_partition.1={name}:{offset}:{len(payload)}:{stock_md5(offset, len(payload))}\n" if stock is None else stock
    return {
        "module.properties": f"id={module_id}\nversion=1.0.0\napi=1\ncars=NEEV.KOR.*.260902\n{stock}",
        "apply.sh": apply or f"put_partition {name} {offset} files/logo.bin\n",
        "files/logo.bin": payload,
        "strings/en.txt": "name=Logo\nsummary=Test\n",
    }


def api(car, module_id, *call):
    """One runtime API call as the module, without the dispatcher's own stock precheck."""
    runner = car.temp / "api.sh"
    runner.write_text('. "$HMG_SEOGAEMO_BASE/lib/common.sh"\n"$@"\n')
    env = dict(car.env, HMG_SEOGAEMO_BASE=str(car.base), HMG_SEOGAEMO_STATE=str(car.data / "modules" / module_id),
               HMG_SEOGAEMO_MODULE_DIR=str(car.data / "installed" / module_id))
    return subprocess.run([SHELL, str(runner), *call], env=env, capture_output=True, text=True, timeout=60)


def ledger_rows(car, op):
    ledger = car.data / "ledger/ledger.tsv"
    return [row for row in ledger.read_text().splitlines() if f"\t{op}\t{CLAIM}\t" in row] if ledger.exists() else []


def test_apply_writes_only_the_range_and_off_restores_every_byte(car):
    node = splash(car)
    car.root("module", "install", car.offer(logo()))
    manifest = (car.data / "installed/logo.properties").read_text().splitlines()
    assert f"owns_partitions.1={CLAIM}" in manifest, manifest
    assert f"known_partition.1=NEEV.KOR.*.260902:{CLAIM}:{stock_md5()}" in manifest, manifest
    assert "restore=reboot" not in manifest, manifest
    assert "state=off" in car.root("logo", "status")

    assert "state=on" in car.root("logo", "apply")
    applied = STOCK[:OFFSET] + PAYLOAD + STOCK[OFFSET + len(PAYLOAD):]
    assert node.read_bytes() == applied
    assert (node.parent / "mmcblk0p5").read_bytes() == STOCK, "another partition was written"
    assert "state=on" in car.root("logo", "status")

    # Boot reconcile applies again: the range already holds the payload, so nothing is written.
    assert "state=on" in car.root("logo", "apply")
    assert len(ledger_rows(car, "partition_put")) == 1, ledger_rows(car, "partition_put")

    assert "state=off" in car.root("logo", "revert")
    assert node.read_bytes() == STOCK
    assert len(ledger_rows(car, "revert")) == 1
    assert not list((car.data / "modules/logo").glob("part.*")), "baseline kept after a verified restore"

    car.root("logo", "apply")
    assert "Removed logo" in car.root("module", "remove", "logo")
    assert node.read_bytes() == STOCK


def test_range_that_is_not_proven_stock_is_refused_untouched(car):
    node = splash(car)
    foreign = STOCK[:OFFSET] + b"\x00" + STOCK[OFFSET + 1:]
    node.write_bytes(foreign)
    car.root("module", "install", car.offer(logo()))
    assert "state=incompatible" in car.root("logo", "apply", code=4)
    assert node.read_bytes() == foreign
    # The runtime call refuses on its own, whoever calls it.
    result = api(car, "logo", "sg_partition_put", "splash", str(OFFSET), "files/logo.bin")
    assert result.returncode == 3, result
    assert node.read_bytes() == foreign
    assert not list((car.data / "modules/logo").glob("part.*/ready"))

    node.write_bytes(STOCK)
    past_end = logo("past-end", offset=(SECTORS - 1) * SECTOR)
    car.root("module", "remove", "logo")
    car.root("module", "install", car.offer(past_end))
    assert "state=incompatible" in car.root("past-end", "apply", code=4)
    result = api(car, "past-end", "sg_partition_put", "splash", str((SECTORS - 1) * SECTOR), "files/logo.bin")
    assert result.returncode == 4, result
    assert node.read_bytes() == STOCK

    # A stock MD5 declared for another firmware proves nothing about this one.
    car.root("module", "remove", "past-end")
    elsewhere = f"stock_partition.1=OTHER.KOR.*:{CLAIM}:{stock_md5()}\n"
    car.root("module", "install", car.offer(logo(stock=elsewhere)))
    assert f"known_partition.1=OTHER.KOR.*:{CLAIM}:{stock_md5()}" in (car.data / "installed/logo.properties").read_text()
    assert "state=incompatible" in car.root("logo", "apply", code=4)
    result = api(car, "logo", "sg_partition_put", "splash", str(OFFSET), "files/logo.bin")
    assert result.returncode == 4, result
    assert node.read_bytes() == STOCK


def test_read_only_partition_is_refused(car):
    node = splash(car, read_only="1")
    car.root("module", "install", car.offer(logo()))
    assert "state=incompatible" in car.root("logo", "apply", code=4)
    assert node.read_bytes() == STOCK


def test_rerun_never_captures_a_new_baseline(car):
    node = splash(car)
    car.root("module", "install", car.offer(logo(stock=f"stock_partition.1={CLAIM}:{stock_md5()}\nrerun_on=boot\n")))
    (car.data / "desired").mkdir(exist_ok=True)
    (car.data / "desired/logo").write_text("on")
    assert "state=failed" in car.root("logo", "watch", "boot", code=1)
    assert node.read_bytes() == STOCK
    assert not list((car.data / "modules/logo").glob("part.*"))

    car.root("logo", "apply")
    assert "state=on" in car.root("logo", "watch", "boot")
    assert node.read_bytes()[OFFSET:OFFSET + len(PAYLOAD)] == PAYLOAD


def test_foreign_change_after_apply_blocks_restore_and_keeps_the_backup(car):
    node = splash(car)
    car.root("module", "install", car.offer(logo()))
    car.root("logo", "apply")
    applied = node.read_bytes()
    foreign = applied[:OFFSET + 5] + b"\x00\x00" + applied[OFFSET + 7:]
    assert foreign != applied
    node.write_bytes(foreign)

    assert "state=failed" in car.root("logo", "status", code=1)
    assert "state=conflict" in car.root("logo", "revert", code=3)
    assert node.read_bytes() == foreign, "restore overwrote bytes it did not write"
    ready, = (car.data / "modules/logo").glob("part.*/ready")
    (ready.parent / "pending").write_text("1")
    assert api(car, "logo", "sg_partition_restore", CLAIM).returncode == 3
    assert node.read_bytes() == foreign
    kept = list((car.data / "modules/logo").glob("part.*/bytes"))
    assert len(kept) == 1 and kept[0].read_bytes() == STOCK[OFFSET:OFFSET + len(PAYLOAD)]

    node.write_bytes(applied)
    assert "state=off" in car.root("logo", "revert")
    assert node.read_bytes() == STOCK


def test_damaged_backup_cannot_write_outside_the_slot(car):
    node = splash(car)
    car.root("module", "install", car.offer(logo()))
    car.root("logo", "apply")
    applied = node.read_bytes()
    backup, = (car.data / "modules/logo").glob("part.*/bytes")
    original = backup.read_bytes()
    for damaged in (original + bytes(SECTOR), bytes(len(original))):
        backup.write_bytes(damaged)
        assert api(car, "logo", "sg_partition_restore", CLAIM).returncode != 0
        assert node.read_bytes() == applied
    backup.write_bytes(original)
    car.root("logo", "revert")
    assert node.read_bytes() == STOCK


def test_failed_write_is_rolled_back_to_stock(car):
    node = splash(car)
    fake = Path(car.env["PATH"].split(":")[1])
    flag = car.temp / "fail-next-partition-write"
    # The next write to the node stops after one sector of payload, like a write cut short.
    install.script(fake / "dd", f'for arg do\n    if [ "$arg" = "of={node}" ] && [ -f "{flag}" ]; then\n'
                                f'        rm -f "{flag}"\n'
                                f'        /bin/dd "$@" count=1 '
                                'conv=notrunc 2>/dev/null\n        exit 1\n    fi\ndone\nexec /bin/dd "$@"\n')
    car.root("module", "install", car.offer(logo()))
    flag.write_text("")
    out = car.root("logo", "apply", code=1)
    assert "state=failed" in out and "rolled back" in out, out
    assert not flag.exists(), "the write never reached the node"
    assert node.read_bytes() == STOCK
    assert "state=off" in car.root("logo", "status")

    assert "state=on" in car.root("logo", "apply")
    assert node.read_bytes()[OFFSET:OFFSET + len(PAYLOAD)] == PAYLOAD


def test_install_refuses_unsafe_or_unproven_ranges(car):
    node = splash(car)

    def refused(files, code, text):
        result = subprocess.run([SHELL, str(car.base / "bin/hmg-seogaemo-root"), "module", "install", car.offer(files)],
                                env=car.env, capture_output=True, text=True, timeout=120)
        assert result.returncode == code and text in result.stdout + result.stderr, (text, result)

    refused(logo(name="boot"), 1, "HSM-E204 module.properties: bad value for stock_partition.1")
    refused(logo(name="boot", stock=""), 2, "HSM-E112 apply.sh:1:")
    refused(logo(offset=OFFSET + 1, stock=""), 2, "HSM-E112 apply.sh:1:")
    refused(logo(payload=PAYLOAD[:-1], stock=""), 2, "HSM-E112 apply.sh:1:")
    refused(logo(apply='put_partition splash "{setting:x}" files/logo.bin\n'), 2, "HSM-E112 apply.sh:1:")
    refused(logo(stock=""), 1, f"HSM-E214 apply.sh: put_partition {CLAIM} needs a stock_partition entry")
    refused(logo(stock=f"stock_partition.1=splash:{OFFSET}:{SECTOR}:{stock_md5(OFFSET, SECTOR)}\n"), 1, "HSM-E214")
    refused(logo(stock=f"stock_partition.1=splash:{OFFSET}:{len(PAYLOAD)}:nothex\n"), 1,
            "HSM-E204 module.properties: bad value for stock_partition.1")
    overlap = logo(stock=f"stock_partition.1={CLAIM}:{stock_md5()}\n"
                         f"stock_partition.2=splash:{OFFSET + SECTOR}:{len(PAYLOAD)}:{stock_md5(OFFSET + SECTOR)}\n",
                   apply=f"put_partition splash {OFFSET} files/logo.bin\n"
                         f"put_partition splash {OFFSET + SECTOR} files/logo.bin\n")
    refused(overlap, 1, "HSM-E215")
    action = logo(stock=f"stock_partition.1={CLAIM}:{stock_md5()}\nkind=action\n")
    action["ui.txt"] = "button name=go label=@name\n"
    refused(action, 1, "HSM-E211")
    assert not (car.data / "installed/logo").exists()

    car.root("module", "install", car.offer(logo()))
    other = logo("logo-b", offset=OFFSET + 4 * SECTOR)
    refused(other, 3, "Writes the same partition as logo")
    # The runtime checks again at every call, in case a manifest reached the catalogue another way.
    (car.data / "installed/logo-b.properties").write_text(f"id=logo-b\nowns_partitions.1=splash:{OFFSET + 4 * SECTOR}:{SECTOR}\n")
    result = api(car, "logo", "sg_partition_put", "splash", str(OFFSET), "files/logo.bin")
    assert result.returncode == 3, result
    assert node.read_bytes() == STOCK


if __name__ == "__main__":
    run_tests([install.on_car(test) for test in (
        test_apply_writes_only_the_range_and_off_restores_every_byte,
        test_range_that_is_not_proven_stock_is_refused_untouched, test_read_only_partition_is_refused,
        test_rerun_never_captures_a_new_baseline,
        test_foreign_change_after_apply_blocks_restore_and_keeps_the_backup,
        test_damaged_backup_cannot_write_outside_the_slot, test_failed_write_is_rolled_back_to_stock,
        test_install_refuses_unsafe_or_unproven_ranges)],
        "partition range tests passed")
