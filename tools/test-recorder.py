#!/usr/bin/env python3
"""USB report recorder (HSM-REPORTS) and the car check, against an isolated fake unit."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
from testlib import car_env, SHELL, host_shell_tree, run_tests

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = 'NEEV.KOR.0000.V039.001.260902'
SERIAL = 'ZZSERIAL1234567890'
MAC = 'aa:bb:cc:dd:ee:ff'


class Unit:
    """A fake head unit: package tree, state tree, USB mount, and toolbox shims."""

    def __init__(self, folder):
        self.folder = folder
        self.base = folder / 'package'
        shutil.copytree(ROOT / 'nemesis/package', self.base)
        shutil.copytree(ROOT / 'maps', self.base / 'maps')  # bundled car maps, as in the package
        host_shell_tree(self.base)
        (self.base / 'modules.list').write_text('demo\n')
        (self.base / 'bin/hmg-seogaemo-root').write_text(
            '#!/bin/sh\ncase "$1 $2" in\n'
            '  "map status") echo state=on; echo restart=none; echo detail=map-ok;;\n'
            '  "demo precheck") echo state=off; echo restart=none; echo detail=ready;;\n'
            '  "demo status") echo state=off; echo restart=none; echo detail=demo-status;;\n'
            'esac\n')
        (self.base / 'VERSION').write_text('0.0.0\n')
        self.data = folder / 'data'
        self.data.mkdir()
        self.usb = folder / 'usb0'
        self.usb.mkdir()
        self.mounts = folder / 'mounts'
        self.mounts.write_text(f'/dev/block/sda1 {self.usb} vfat rw 0 0\n')
        self.sdio = folder / 'sdio'
        self.sdio.mkdir()
        self.mmc = folder / 'mmc'
        self.mmc.mkdir()
        self.cmdline = folder / 'cmdline'
        self.cmdline.write_text(
            f'console=null androidboot.serialno={SERIAL} androidboot.wifimac= androidboot.mode=emmc '
            'daudio_hw_ver=34014983 vehicle_info=0xbd\n')
        self.boot = folder / 'boot-id'
        self.boot.write_text('boot-one')
        self.proc = folder / 'proc'
        self.proc.mkdir()
        self.target = folder / 'target'
        (self.target / 'system/lib').mkdir(parents=True)
        (self.target / 'system/wifi').mkdir(parents=True)
        self.fake = folder / 'fake'
        self.fake.mkdir()
        self.props = {
            'ro.build.product': PRODUCT, 'ro.build.version.release': '4.4.2', 'ro.mobis.onebindir': 'neev_kr',
            'sys.boot_completed': '1', 'wlan.driver.status': 'unloaded',
        }
        self.dmesg = folder / 'dmesg.txt'
        self.dmesg.write_text('')
        self.logcat_started = folder / 'logcat-started'
        self.write_fakes()

    def write_fakes(self):
        props = '\n'.join(f'    "{k}") echo "{v}";;' for k, v in self.props.items())
        (self.fake / 'getprop').write_text(f'#!/bin/sh\ncase "$1" in\n{props}\n    *) echo;;\nesac\n')
        (self.fake / 'dmesg').write_text(f'#!/bin/sh\ncat "{self.dmesg}"\n')
        (self.fake / 'sync').write_text('#!/bin/sh\nexit 0\n')
        (self.fake / 'ifconfig').write_text(f'#!/bin/sh\necho "lo: UP"\necho "wlan0: HWaddr {MAC}"\n')
        (self.fake / 'logcat').write_text(f'#!/bin/sh\necho started >> "{self.logcat_started}"\nexec sleep 60\n')
        for path in self.fake.iterdir():
            path.chmod(0o755)

    def env(self, **extra):
        env = car_env()
        env['PATH'] = f'{self.fake}:{env["PATH"]}'
        env.update(
            SG_DATA_ROOT=str(self.data), SG_USB_DIRS=str(self.usb), SG_MOUNTS_FILE=str(self.mounts),
            SG_SDIO_DIR=str(self.sdio), SG_MMC_DIR=str(self.mmc), SG_CMDLINE_FILE=str(self.cmdline),
            SG_BOOT_ID_FILE=str(self.boot), SG_PROC_DIR=str(self.proc), SG_TARGET_ROOT=str(self.target),
            HMG_SEOGAEMO_RECORDER_FLUSH='0', HMG_SEOGAEMO_RECORDER_SNAPSHOT='0')
        env.update(extra)
        return env

    def run(self, group, verb, **extra):
        result = subprocess.run([SHELL, str(self.base / 'core/recorder.sh'), group, verb],
                                env=self.env(**extra), capture_output=True, text=True, timeout=60)
        return result.returncode, result.stdout, result.stderr

    def checks(self):
        code, out, err = self.run('preflight', 'run')
        assert code == 0, err
        found = {}
        for line in out.splitlines():
            if line.startswith('info.check_'):
                ident, level, evidence, message = line.split('=', 1)[1].split('|', 3)
                found[ident] = (level, evidence, message)
        verdict = [line for line in out.splitlines() if line.startswith('info.verdict=')][0].split('=', 1)[1]
        return found, verdict

    def stop_logcat(self):
        pid_file = self.data / 'recorder/logcat.pid'
        if pid_file.is_file():
            try:
                os.kill(int(pid_file.read_text()), signal.SIGTERM)
            except (ProcessLookupError, ValueError):
                pass

    def reports(self):
        return self.usb / 'HSM-REPORTS'

    def boot_dir(self, number=1):
        return self.reports() / PRODUCT / f'boot-{number:04d}'


def test_check_without_wifi_chip(folder):
    unit = Unit(folder)
    unit.dmesg.write_text('<4>[   48.5] failed to power up DHD generic adapter, 3 retry left\n'
                          '<4>[   56.8] failed to power up DHD generic adapter, 0 retry left\n')
    checks, verdict = unit.checks()
    assert verdict == 'block', verdict
    assert checks['wifi_hw'][0] == 'block' and checks['wifi_hw'][1] == 'observed', checks['wifi_hw']
    assert '2 failed power-up tries' in checks['wifi_hw'][2]
    assert checks['firmware'][0] == 'ok' and checks['android'][0] == 'ok' and checks['onebin'][0] == 'ok'
    assert checks['module_demo'][0] == 'ok' and checks['boot'][0] == 'ok'
    assert checks['conflict_hmgapi'][0] == 'ok' and checks['adb_tcp'][0] == 'ok'


def test_check_with_wifi_chip_and_conflicts(folder):
    unit = Unit(folder)
    (unit.sdio / 'mmc1:0001:1').mkdir()
    unit.props['persist.service.adb.tcp.enable'] = '1'
    unit.props['ro.build.product'] = 'NEEV.USA.0000.V039.001.260507'
    unit.write_fakes()
    (unit.target / 'system/bin').mkdir(parents=True)
    (unit.target / 'system/bin/app_process.hmgapi-stock').write_text('x')
    checks, verdict = unit.checks()
    assert checks['wifi_hw'][0] == 'ok' and checks['wifi_hw'][1] == 'observed', checks['wifi_hw']
    assert checks['firmware'][0] == 'warn'  # no car map for this firmware yet
    assert checks['adb_tcp'][0] == 'warn'
    assert checks['conflict_hmgapi'][0] == 'block'
    assert verdict == 'block'


def test_check_unknown_wifi_before_radio_was_used(folder):
    unit = Unit(folder)
    checks, _ = unit.checks()
    # Empty factory address and nothing seen yet: a guess, never an observation of absence.
    assert checks['wifi_hw'][0] == 'warn' and checks['wifi_hw'][1] == 'inferred', checks['wifi_hw']
    unit.cmdline.write_text('androidboot.wifimac=001122334455 androidboot.mode=emmc\n')
    checks, _ = unit.checks()
    assert checks['wifi_hw'][0] == 'unknown' and checks['wifi_hw'][1] == 'inferred', checks['wifi_hw']
    assert SERIAL not in str(checks)


def test_native_library_hashes(folder):
    unit = Unit(folder)
    lib = unit.target / 'system/lib/libCarPlayCore.so'
    lib.write_bytes(b'stock-bytes')
    import hashlib
    digest = hashlib.md5(b'stock-bytes').hexdigest()
    (unit.base / 'modules.list').write_text('demo\nwireless-carplay-and-aa\n')
    recipes = unit.base / 'modules/wireless-carplay-and-aa.d/recipes'
    recipes.mkdir(parents=True)
    (recipes / 'core.recipe').write_text(f'id core\nfile /system/lib/libCarPlayCore.so\nnative {digest} fits\n')
    (unit.base / 'bin/hmg-seogaemo-root').write_text(
        '#!/bin/sh\necho state=off; echo restart=none; echo detail=ready\n')
    checks, _ = unit.checks()
    assert checks['lib_libCarPlayCore'][0] == 'ok', checks['lib_libCarPlayCore']
    assert checks['lib_libCarPlayAudio'][0] == 'warn'  # file missing on this unit
    lib.write_bytes(b'other-build')
    checks, _ = unit.checks()
    assert checks['lib_libCarPlayCore'][0] == 'unknown'


def test_cannot_enable_without_usb(folder):
    unit = Unit(folder)
    unit.mounts.write_text('')
    code, out, _ = unit.run('recorder', 'enable')
    assert code == 1 and 'state=failed' in out and 'Insert a USB drive' in out, out
    assert not (unit.data / 'recorder/enabled').exists()
    assert not unit.reports().exists()
    code, out, _ = unit.run('recorder', 'status')
    assert code == 0 and 'state=off' in out and 'info.usb=absent' in out, out


def test_enable_records_and_redacts(folder):
    unit = Unit(folder)
    unit.dmesg.write_text(
        f'<4>[    0.0] Kernel command line: androidboot.serialno={SERIAL} console=null\n'
        f'<4>[   20.0] wlan0: addr {MAC}\n'
        '<4>[   48.5] dhd_module_init in\n'
        '<4>[   50.5] failed to power up DHD generic adapter, 3 retry left\n'
        '<4>[   51.0] connected to network ssid=HomeNetwork\n')
    try:
        code, out, err = unit.run('recorder', 'enable')
        assert code == 0 and 'state=on' in out and 'HSM-REPORTS' in out, (out, err)
        assert (unit.data / 'recorder/enabled').is_file()
        assert (unit.reports() / 'README.txt').is_file()
        boot = unit.boot_dir(1)
        for name in ('facts.txt', 'check.txt', 'status.txt', 'dmesg.txt', 'logcat.txt', 'events.log'):
            if name == 'logcat.txt' and not (boot / name).exists():
                continue  # the fake logcat writes nothing
            assert (boot / name).is_file(), (name, sorted(p.name for p in boot.iterdir()))
        everything = '\n'.join(p.read_text() for p in unit.reports().rglob('*') if p.is_file())
        assert SERIAL not in everything and MAC not in everything and 'HomeNetwork' not in everything, everything
        assert 'dhd_module_init in' in (boot / 'dmesg.txt').read_text()
        assert 'failed to power up' in (boot / 'dmesg.txt').read_text()
        assert 'androidboot.wifimac: EMPTY' in (boot / 'facts.txt').read_text()
        assert 'wifi_hw|block|observed' in (boot / 'check.txt').read_text()
        assert 'map-ok' in (boot / 'status.txt').read_text()
        assert unit.logcat_started.is_file()
        code, out, _ = unit.run('recorder', 'status')
        assert 'state=on' in out and 'info.usb=present' in out, out
    finally:
        unit.stop_logcat()


def test_tick_follows_usb_and_boots(folder):
    unit = Unit(folder)
    try:
        assert unit.run('recorder', 'enable')[0] == 0
        # No USB: ticks succeed and write nothing new.
        unit.mounts.write_text('')
        before = sorted(str(p) for p in unit.reports().rglob('*'))
        assert unit.run('recorder', 'tick')[0] == 0
        assert sorted(str(p) for p in unit.reports().rglob('*')) == before
        assert 'usb removed' in (unit.data / 'recorder/spool/events.log').read_text()
        status = unit.run('recorder', 'status')[1]
        assert 'state=on' in status and 'info.usb=absent' in status, status
        # USB again in a new boot: a new numbered folder.
        unit.mounts.write_text(f'/dev/block/sda1 {unit.usb} vfat rw 0 0\n')
        unit.boot.write_text('boot-two')
        assert unit.run('recorder', 'tick')[0] == 0
        assert unit.boot_dir(2).is_dir() and (unit.boot_dir(2) / 'check.txt').is_file()
        assert 'boot 2 started' in (unit.boot_dir(2) / 'events.log').read_text()
    finally:
        unit.stop_logcat()


def test_disable_stops_and_keeps_reports(folder):
    unit = Unit(folder)
    try:
        assert unit.run('recorder', 'enable')[0] == 0
        pid = int((unit.data / 'recorder/logcat.pid').read_text())
        (unit.proc / str(pid)).mkdir()
        (unit.proc / str(pid) / 'cmdline').write_text('logcat -v time')
        code, out, _ = unit.run('recorder', 'disable')
        assert code == 0 and 'state=off' in out, out
        assert not (unit.data / 'recorder/enabled').exists()
        assert not (unit.data / 'recorder/spool').exists()
        assert (unit.boot_dir(1) / 'check.txt').is_file()
        deadline = time.monotonic() + 5
        alive = True
        while alive and time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
                state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True,
                                       text=True).stdout.strip()
                alive = bool(state) and not state.startswith('Z')
            except ProcessLookupError:
                alive = False
            if alive:
                time.sleep(0.1)
        assert not alive, 'the log stream was not stopped'
        # Disabled: a tick does nothing and the log stream is not restarted.
        before = sorted(str(p) for p in unit.reports().rglob('*'))
        assert unit.run('recorder', 'tick')[0] == 0
        assert sorted(str(p) for p in unit.reports().rglob('*')) == before
        assert not (unit.data / 'recorder/logcat.pid').exists()
    finally:
        unit.stop_logcat()


def test_old_boot_folders_are_pruned(folder):
    unit = Unit(folder)
    try:
        car = unit.reports() / PRODUCT
        for number in range(1, 26):
            (car / f'boot-{number:04d}').mkdir(parents=True)
        (car / 'notes').mkdir()
        (unit.data / 'recorder').mkdir()
        (unit.data / 'recorder/seq').write_text('29')
        assert unit.run('recorder', 'enable')[0] == 0
        names = sorted(p.name for p in car.iterdir())
        boots = [name for name in names if name.startswith('boot-')]
        assert len(boots) == 20, boots
        assert 'boot-0001' not in boots and 'boot-0006' not in boots and 'boot-0007' in boots, boots
        assert 'boot-0030' in boots and 'notes' in names, names
    finally:
        unit.stop_logcat()


def test_current_folder_survives_pruning_and_reused_stick(folder):
    unit = Unit(folder)
    try:
        car = unit.reports() / PRODUCT
        for number in range(2, 11):
            (car / f'boot-{number:04d}').mkdir(parents=True)
        # An earlier recording of another boot owns boot-0001 on this stick: it is left alone.
        (car / 'boot-0001').mkdir(parents=True)
        (car / 'boot-0001/.boot').write_text('old-boot')
        (car / 'boot-0001/facts.txt').write_text('earlier recording')
        assert unit.run('recorder', 'enable')[0] == 0
        assert (car / 'boot-0001/facts.txt').read_text() == 'earlier recording'
        assert (car / 'boot-0001/.boot').read_text() == 'old-boot'
        assert (unit.data / 'recorder/seq').read_text().strip() == '11'
        assert (car / 'boot-0011/facts.txt').is_file(), sorted(p.name for p in car.iterdir())
        assert (car / 'boot-0011/.boot').read_text() == 'boot-one'
    finally:
        unit.stop_logcat()


def test_report_digest_is_short_redacted_and_read_only(folder):
    unit = Unit(folder)
    (unit.data / 'desired').mkdir()
    (unit.data / 'desired/demo').write_text('on\n')
    (unit.data / 'ledger').mkdir()
    rows = ['time\tmodule\top\ttarget\tbefore-ref\tafter-ref\tresult']
    rows += [f'{1700000000 + n}\tdemo\tprop_set\tpersist.demo.{n}\tbefore/x\tafter/x\tok' for n in range(400)]
    rows.insert(5, '1690000000\tdemo\tfile_put\t/system/etc/demo.xml\tbefore/y\tafter/y\tconflict')
    (unit.data / 'ledger/ledger.tsv').write_text('\n'.join(rows) + '\n')
    (unit.data / 'modules/demo').mkdir(parents=True)
    (unit.data / 'modules/demo/module.log').write_text(
        ''.join(f'{n} old line\n' for n in range(50)) + f'ssid=HomeNet\nmac {MAC}\nLAST-DEMO-LINE\n')
    (unit.data / 'reconcile.log').write_text('boot reconcile done\n')
    before = sorted(str(p) for p in unit.data.rglob('*'))
    code, out, err = unit.run('report', 'digest')
    assert code == 0, err
    # Only the recorder state and the car check's own foreign-report cache may change.
    own = ('recorder', 'foreign')
    after = sorted(str(p) for p in unit.data.rglob('*') if not set(own) & set(p.parts))
    assert after == [p for p in before if not set(own) & set(Path(p).parts)], set(after) ^ set(before)
    lines = [line.split('=', 1)[1] for line in out.splitlines() if line.startswith('info.log_')]
    assert len(out.encode()) < 8192 and lines, out
    text = '\n'.join(lines)
    assert f'product={PRODUCT}' in text
    assert 'demo desired=on state=off demo-status' in text
    assert '1690000000 demo file_put /system/etc/demo.xml conflict' in text
    assert 'LAST-DEMO-LINE' in text and '0 old line' not in text.split('# demo log')[1].split('#')[0]
    assert 'HomeNet' not in out and MAC not in out
    assert 'before/x' not in text and 'persist.demo.399' in text
    assert 'boot reconcile done' in text


def test_dispatcher_accepts_only_fixed_verbs(folder):
    unit = Unit(folder)
    root = ROOT / 'nemesis/package/bin/hmg-seogaemo-root'
    copy = unit.base / 'bin/hmg-seogaemo-root'
    copy.write_text(root.read_text().replace('/system/bin/sh', SHELL))
    for args in (['recorder', 'enable', 'x'], ['recorder', 'delete'], ['preflight', 'x'], ['recorder'],
                 ['preflight', 'run', 'extra'], ['report', 'all'], ['report', 'digest', 'x']):
        result = subprocess.run([SHELL, str(copy)] + args, env=unit.env(), capture_output=True, text=True)
        assert result.returncode == 2 and 'state=failed' in result.stdout, (args, result.stdout)
    result = subprocess.run([SHELL, str(copy), 'preflight', 'run'], env=unit.env(), capture_output=True, text=True)
    assert result.returncode == 0 and 'info.verdict=' in result.stdout, result.stdout


run_tests([test_check_without_wifi_chip, test_check_with_wifi_chip_and_conflicts,
           test_check_unknown_wifi_before_radio_was_used, test_native_library_hashes,
           test_cannot_enable_without_usb, test_enable_records_and_redacts, test_tick_follows_usb_and_boots,
           test_disable_stops_and_keeps_reports, test_old_boot_folders_are_pruned,
           test_current_folder_survives_pruning_and_reused_stick,
           test_report_digest_is_short_redacted_and_read_only,
           test_dispatcher_accepts_only_fixed_verbs], 'recorder tests passed')
