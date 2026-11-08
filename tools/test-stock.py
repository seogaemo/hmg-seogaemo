#!/usr/bin/env python3
"""Stock restore and real preuninstall entry points against an isolated root."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
from testlib import car_env, SHELL, host_shell_tree, host_shell_script, run_tests

ROOT = Path(__file__).resolve().parents[1]


def script(path, body):
    path.write_text('#!/bin/sh\n. "$FAKE_COMMON"\n' + body)
    path.chmod(0o755)


class Car:
    def __init__(self, folder):
        self.base = folder / 'package'
        shutil.copytree(ROOT / 'nemesis/package', self.base)
        host_shell_tree(self.base)
        self.state = folder / 'data'
        self.fake = folder / 'fake'
        self.fake.mkdir()
        self.live = folder / 'live'
        self.live.mkdir()
        self.backing = folder / 'property'
        self.backing.mkdir()
        self.calls = folder / 'calls'
        self.calls.touch()
        self.apk = folder / 'apk'
        self.apk.touch()
        # mksh has a builtin cat, so a PATH shim cannot replace this Linux file.
        self.boot = folder / 'boot-id'
        self.boot.write_text('test-boot')
        stock_lib = self.base / 'lib/stock.sh'
        stock_lib.write_text(stock_lib.read_text().replace(
            '/proc/sys/kernel/random/boot_id', str(self.boot)))
        self.env = car_env(dict(os.environ, SG_DATA_ROOT=str(self.state),
            SG_PROPERTY_ROOT=str(self.backing), FAKE_COMMON=str(self.base / 'lib/common.sh'),
            FAKE_LIVE=str(self.live), FAKE_CALLS=str(self.calls),
            FAKE_APK=str(self.apk), FAKE_FAIL='',
            PATH=str(self.fake) + ':' + os.environ['PATH']))
        (self.live / 'ro.build.product').write_text('NEEV.KOR.0000.V039.001.260902')
        (self.live / 'sys.boot_completed').write_text('1')
        script(self.fake / 'cat', '''
if [ "$1" = /proc/sys/kernel/random/boot_id ]; then echo test-boot; else /bin/cat "$@"; fi
''')
        script(self.fake / 'getprop', 'cat "$FAKE_LIVE/$1" 2>/dev/null || true\n')
        script(self.fake / 'setprop', 'sg_write "$2" > "$FAKE_LIVE/$1"\n')
        script(self.fake / 'pm', '''
case "$1" in
    path) [ ! -f "$FAKE_APK" ] || echo package:fake ;;
    uninstall) rm -f "$FAKE_APK"; echo Success ;;
esac
''')
        (self.base / 'modules').mkdir()
        (self.base / 'modules.list').write_text('a\nb\nc\n')
        (self.base / 'modules.graph').write_text(
            'a\tdepends=\texcludes=\nb\tdepends=a\texcludes=\nc\tdepends=\texcludes=\n')
        for name in 'abc':
            (self.base / f'modules/{name}.properties').write_text(
                f'owns_props=demo.{name}\nwatch=boot,screen_on\n' +
                ('restore=reboot\n' if name == 'c' else ''))
            script(self.base / f'modules/{name}.sh', '''
id=${HMG_SEOGAEMO_STATE##*/}
case "$1" in
    apply)
        sg_prop_set "demo.$id" ours || exit 1
        sg_status on none enabled ;;
    revert)
        sg_print "$id revert" >> "$FAKE_CALLS"
        [ "$FAKE_FAIL" != "$id" ] || { sg_status failed none injected; exit 1; }
        sg_revert_all || { sg_status conflict none drift; exit 3; }
        [ "$FAKE_FAIL" != "late-$id" ] || { sg_status failed none service; exit 1; }
        if [ "$id" = c ]; then
            sg_print info.desired=off
            sg_status pending-restart head_unit transient
        else sg_status off none restored; fi ;;
    status) sg_status off none restored ;;
    watch) sg_print "$id watch $2" >> "$FAKE_CALLS"; sg_status on none called ;;
esac
''')
        self.root = self.base / 'bin/hmg-seogaemo-root'

    def run(self, *args, ok=True):
        result = subprocess.run([SHELL, str(self.root), *args], env=self.env,
            capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result

    def enable(self):
        for name in 'abc':
            self.run(name, 'apply')

    def hook(self, ok=True):
        result = subprocess.run([SHELL, str(self.base / 'scripts/preuninstall.sh')],
            env=self.env, capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) == ok, (result.stdout, result.stderr)
        return result


def test_restore(folder):
    car = Car(folder)
    car.enable()
    # Interrupted apply: snapshots still need restoring even with desired off.
    (car.state / 'desired/b').write_text('off')
    result = car.run('stock', 'restore')
    assert 'state=pending-restart' in result.stdout
    assert 'restart=head_unit' in result.stdout
    for name in 'abc':
        assert f'info.module_{name}=reverted' in result.stdout
        assert (car.state / f'desired/{name}').read_text() == 'off'
        assert (car.live / f'demo.{name}').read_text() == ''
        assert not list((car.state / f'modules/{name}').glob('prop.*'))
    assert car.calls.read_text().splitlines() == ['c revert', 'b revert', 'a revert']
    car.run('a', 'watch', 'screen_on', ok=False)
    assert 'watch' not in car.calls.read_text()
    # Repeated restore preserves pending framework restart, including hook retry.
    assert 'state=pending-restart' in car.run('stock', 'restore').stdout
    status = car.run('stock', 'status').stdout
    receipt = (car.state / 'stock/result').read_bytes()
    assert 'info.module_a=reverted' in status
    assert (car.state / 'stock/result').read_bytes() == receipt
    # After a kernel boot, read-only status no longer claims a pending restart.
    (car.state / 'stock/boot').write_text('earlier-boot')
    assert 'state=off' in car.run('stock', 'status').stdout
    ledger = car.state / 'ledger/ledger.tsv'
    assert 'stock_start' in ledger.read_text() and 'stock_finish' in ledger.read_text()
    assert not list((car.state / 'stock').glob('recovery.*'))
    for name in 'abc':
        assert 'stock_module' in ledger.read_text()
        assert f'\\t{name}\n' in ledger.read_text() or f'\t{name}\n' in ledger.read_text()
    car.env['SG_EXPORT_ROOT'] = str(folder / 'hmg-seogaemo-export')
    car.run('export', 'adb')
    exported = next((folder / 'hmg-seogaemo-export').glob('*/ledger/ledger.tsv'))
    assert exported.read_bytes() == ledger.read_bytes()
    # A fresh explicit apply resumes operation; stale receipt is invalidated.
    car.run('a', 'apply')
    assert not (car.state / 'stock/paused').exists()
    assert not (car.state / 'stock/result').exists()
    for args in [('stock', 'restore', 'extra'), ('stock', 'bad'),
                 ('package', 'uninstall', '/evil'), ('package', 'force')]:
        car.run(*args, ok=False)


def test_damaged_selection_recovery(folder):
    car = Car(folder)
    car.enable()
    selected = folder / 'damaged-ota'
    (selected / 'bin').mkdir(parents=True)
    (selected / 'bin/hmg-seogaemo-root').write_text('if then\n')
    (selected / 'scripts').mkdir()
    (selected / 'scripts/preuninstall.sh').write_text('exit 90\n')
    current = car.state / 'update/current'
    current.parent.mkdir(parents=True)
    current.symlink_to(selected, target_is_directory=True)
    result = car.run('stock', 'restore')
    assert 'info.module_a=reverted' in result.stdout, result
    for name in 'abc':
        assert (car.state / f'desired/{name}').read_text() == 'off'
        assert (car.live / f'demo.{name}').read_text() == ''
    # Genuine drift still blocks fallback restore and retains the exact baseline.
    current.unlink()
    car.run('a', 'apply')
    current.symlink_to(selected, target_is_directory=True)
    (car.live / 'demo.a').write_text('external')
    result = car.run('stock', 'restore', ok=False)
    assert 'state=conflict' in result.stdout
    assert (car.state / 'modules/a/prop.demo.a/ready').exists()
    car.hook(ok=False)
    assert car.apk.exists()
    (car.live / 'demo.a').write_text('ours')
    car.hook()
    assert not car.apk.exists()
    assert (car.live / 'demo.a').read_text() == ''


def test_conflict(folder):
    car = Car(folder)
    car.enable()
    (car.live / 'demo.a').write_text('external')
    result = car.run('stock', 'restore', ok=False)
    assert 'state=conflict' in result.stdout and 'info.module_a=conflict' in result.stdout
    assert 'property preflight: demo.a' in result.stdout
    assert 'info.module_b=not_attempted' in result.stdout
    assert car.calls.read_text() == ''  # ALL preflight before any restore
    for name in 'abc':
        assert (car.state / f'desired/{name}').read_text() == 'on'
        assert (car.state / f'modules/{name}/prop.demo.{name}/ready').exists()
    # Paused even though desired on remains after failure, including on boot.
    car.run('a', 'watch', 'boot', ok=False)
    subprocess.run([SHELL, str(car.base / 'svc/reconcile.sh')], env=car.env, check=True)
    car.env['HMG_SEOGAEMO_RECONCILE'] = '1'
    car.run('a', 'apply', ok=False)
    car.run('a', 'revert', ok=False)
    del car.env['HMG_SEOGAEMO_RECONCILE']
    car.run('package', 'uninstall', ok=False)
    assert not (car.state / 'uninstall').exists()
    car.hook(ok=False)
    assert car.apk.exists()
    assert car.calls.read_text() == ''


def test_failure_and_hook(folder):
    car = Car(folder)
    car.enable()
    car.env['FAKE_FAIL'] = 'b'
    result = car.run('package', 'uninstall', ok=False)
    assert 'info.module_c=reverted' in result.stdout
    assert 'info.module_b=failed' in result.stdout
    assert 'info.module_a=not_attempted' in result.stdout
    assert (car.state / 'desired/c').read_text() == 'off'
    assert (car.state / 'desired/b').read_text() == 'on'
    assert (car.state / 'modules/b/prop.demo.b/ready').exists()
    assert not (car.state / 'uninstall').exists()
    car.calls.write_text('')
    car.env['FAKE_FAIL'] = ''
    car.hook()
    assert car.calls.read_text().splitlines() == ['c revert', 'b revert', 'a revert']
    assert not car.apk.exists()
    assert not (car.state / 'modules').exists()
    assert (car.state / 'ledger/ledger.tsv').exists()
    # The pause marker and receipt belong to the removed installation; ledger rows stay.
    assert not (car.state / 'stock').exists()
    assert 'stock_finish' in (car.state / 'ledger/ledger.tsv').read_text()


def test_detached(folder):
    car = Car(folder)
    car.enable()
    # The fake NEMESIS deletes the caller's package and APK, like the real hook.
    script(car.fake / 'nemesis', '''
[ "$#" -eq 2 ] && [ "$1" = uninstall ] && [ "$2" = hmg-seogaemo ] || exit 90
sg_print "nemesis $*" >> "$FAKE_CALLS"
while [ ! -f "$FAKE_RELEASE" ]; do sleep 1; done
sh "$FAKE_PACKAGE/scripts/preuninstall.sh" || exit 5
rm -rf "$FAKE_PACKAGE"
''')
    car.env['FAKE_PACKAGE'] = str(car.base)
    release = folder / 'release'
    car.env['FAKE_RELEASE'] = str(release)
    # A pipe left attached by the runner would keep communicate() blocked.
    result = car.run('package', 'uninstall')
    assert 'info.uninstall=queued' in result.stdout
    car.run('a', 'apply', ok=False)
    car.run('package', 'uninstall', ok=False)
    job = car.state / 'uninstall'
    pid = int((job / 'pending').read_text())
    os.kill(pid, signal.SIGHUP)  # ignored across exec, survives parent loss
    release.touch()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and (job / 'pending').exists():
        time.sleep(0.05)
    assert not (job / 'pending').exists(), (job / 'log').read_text()
    assert (job / 'result').read_text() == 'removed', (job / 'log').read_text()
    assert (job / 'exit-code').read_text() == '0'
    assert not car.base.exists() and not car.apk.exists()
    # Nothing of the restore bookkeeping survives; the uninstall record does.
    assert not (car.state / 'stock').exists() and not (car.state / 'restart-cleanup').exists()
    assert (job / 'log').exists() and (job / 'exit-code').exists()
    assert 'nemesis uninstall hmg-seogaemo' in car.calls.read_text()
    assert 'package_uninstall' in (car.state / 'ledger/ledger.tsv').read_text()


def test_late_failure(folder):
    car = Car(folder)
    car.enable()
    car.env['FAKE_FAIL'] = 'late-b'
    result = car.run('stock', 'restore', ok=False)
    assert 'info.module_b=failed' in result.stdout
    assert (car.state / 'desired/b').read_text() == 'on'
    copies = list((car.state / 'stock').glob('recovery.*/b/prop.demo.b/ready'))
    assert copies, 'late service failure lost recovery material'
    assert (car.live / 'demo.b').read_text() == ''


def test_detached_failure(folder):
    car = Car(folder)
    car.enable()
    script(car.fake / 'nemesis', 'sg_print "nemesis $*" >> "$FAKE_CALLS"; exit 9\n')
    result = car.run('package', 'uninstall')
    assert 'info.uninstall=queued' in result.stdout
    job = car.state / 'uninstall'
    deadline = time.monotonic() + 10
    while (job / 'pending').exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert (job / 'result').read_text() == 'failed'
    assert (job / 'exit-code').read_text() == '9'
    assert car.apk.exists() and car.base.exists()
    assert 'info.uninstall=failed' in car.run('stock', 'status').stdout
    car.run('a', 'apply')  # completed failure releases the pending block


def test_missing_handoff(folder):
    car = Car(folder)
    job = car.state / 'uninstall'
    job.mkdir(parents=True)
    shutil.copy(car.base / 'core/uninstall-detached.sh', job / 'run.sh')
    shutil.copy(car.base / 'lib/common.sh', job / 'common.sh')
    script(car.fake / 'sleep', 'exit 0\n')  # bounded expiry without waiting 30s
    runner = job / 'run.sh'
    runner.write_text('sleep() { "' + str(car.fake / 'sleep') + '" "$@"; }\n' +
                      runner.read_text())
    script(car.fake / 'nemesis', 'sg_print unexpected >> "$FAKE_CALLS"\n')
    (job / 'ready').write_text('wrong-pid')
    result = subprocess.run([SHELL, str(job / 'run.sh')], env=car.env,
        capture_output=True, text=True, timeout=10)
    assert result.returncode != 0
    assert (job / 'result').read_text() == 'failed'
    assert car.calls.read_text() == '' and car.apk.exists()


def test_shared_lines(folder):
    car = Car(folder)
    target = folder / 'featurexml.cfg'
    stock = b'alpha\nbeta\nkeep\n'
    target.write_bytes(stock)
    target.chmod(0o640)
    for name, line in (('a', 'alpha'), ('b', 'beta')):
        (car.base / f'modules/{name}.properties').write_text(
            f'owns_lines.1={target}:{line}\nwatch=boot,screen_on\n')
    car.env['FAKE_TARGET'] = str(target)
    for name, old, new in (('a', 'alpha', 'A'), ('b', 'beta', 'B')):
        script(car.base / f'modules/{name}.sh', f'''
case "$1" in
    apply) sg_file_replace_line "$FAKE_TARGET" {old} {new} || exit $?; sg_status on none enabled ;;
    revert)
        sg_print "${{HMG_SEOGAEMO_STATE##*/}} revert" >> "$FAKE_CALLS"
        sg_revert_all || {{ sg_status conflict none drift; exit 3; }}
        [ "$FAKE_FAIL" != "late-${{HMG_SEOGAEMO_STATE##*/}}" ] || {{ sg_status failed none service; exit 1; }}
        sg_status off none restored ;;
    status) sg_status off none restored ;;
esac
''')
    car.enable()
    composed = target.read_bytes()
    assert composed == b'A\nB\nkeep\n'
    shared = car.state / 'shared-lines'
    # Drift in the shared file blocks every module before any restore.
    target.write_bytes(b'external\n')
    result = car.run('stock', 'restore', ok=False)
    assert 'state=conflict' in result.stdout and car.calls.read_text() == ''
    car.hook(ok=False)
    assert target.read_bytes() == b'external\n' and car.apk.exists()
    target.write_bytes(composed)
    # Interrupted applies (desired off) still count as line-owned snapshots.
    for name in 'ab':
        (car.state / f'desired/{name}').write_text('off')
    result = car.run('stock', 'restore')
    assert 'info.module_a=reverted' in result.stdout and 'info.module_b=reverted' in result.stdout
    assert target.read_bytes() == stock and oct(target.stat().st_mode & 0o7777) == '0o640'
    assert not shared.exists() or not any(shared.iterdir())
    assert not list(car.state.glob('modules/*/line.*'))
    # The NEMESIS hook uses the same restore path.
    car.enable()
    assert target.read_bytes() == composed
    car.hook()
    assert target.read_bytes() == stock and not car.apk.exists()
    assert not shared.exists() or not any(shared.iterdir())
    # A late failure after a line-owned revert keeps the shared composition.
    car.apk.write_text('apk')
    car.enable()
    car.env['FAKE_FAIL'] = 'late-b'
    result = car.run('stock', 'restore', ok=False)
    assert 'info.module_b=failed' in result.stdout
    copies = list((car.state / 'stock').glob('recovery.*/shared-lines/*'))
    assert copies, 'late failure lost shared-line recovery material'
    assert list((car.state / 'stock').glob('recovery.*/b/line.*'))


def test_file_metadata_diagnostic(folder):
    car = Car(folder)
    target = folder / "target"
    target.write_text("stock")
    target.chmod(0o644)
    payload = folder / "payload"
    payload.write_text("ours")
    (car.base / "modules/a.properties").write_text(f"owns_files={target}\n")
    car.env.update(FAKE_TARGET=str(target), FAKE_PAYLOAD=str(payload))
    script(car.base / "modules/a.sh", '''
case "$1" in
    apply)
        sg_commit_file "$FAKE_TARGET" "$FAKE_PAYLOAD" "" "" || exit $?
        sg_status on none enabled ;;
    revert)
        sg_revert_all || { sg_status conflict none drift; exit 3; }
        sg_status off none restored ;;
    status) sg_status off none restored ;;
esac
''')
    car.run("a", "apply")
    target.chmod(0o600)  # Same bytes, unexpected metadata.
    result = car.run("stock", "restore", ok=False)
    assert "state=conflict" in result.stdout
    assert f"detail=a file preflight: {target}; backups retained; watch paused" in result.stdout
    assert list((car.state / "modules/a").glob("file.*/ready"))
    assert target.read_text() == "ours" and target.stat().st_mode & 0o777 == 0o600
    target.chmod(0o644)
    car.run("stock", "restore")
    assert target.read_text() == "stock" and target.stat().st_mode & 0o777 == 0o644


def test_reassert_restore(folder):
    car = Car(folder)
    manifest = car.base / 'modules/a.properties'
    manifest.write_text(manifest.read_text() + 'reassert_props=demo.a\n')
    (car.live / 'demo.a').write_text('original')
    (car.backing / 'demo.a').write_bytes(b'original\x00')
    car.enable()
    (car.live / 'demo.a').write_text('stock.reset')
    # Whole-package preflight permits drift ONLY for the declared property.
    (car.live / 'demo.b').write_text('external')
    car.run('stock', 'restore', ok=False)
    assert car.calls.read_text() == ''
    assert (car.live / 'demo.a').read_text() == 'stock.reset'
    (car.live / 'demo.b').write_text('ours')
    car.run('stock', 'restore')
    assert (car.live / 'demo.a').read_text() == 'original'
    assert (car.backing / 'demo.a').read_bytes() == b'original\x00'
    assert not list((car.state / 'modules/a').glob('prop.*'))
    # The preuninstall hook uses the same explicit drift policy.
    car.enable()
    (car.live / 'demo.a').write_text('user.choice')
    car.hook()
    assert (car.live / 'demo.a').read_text() == 'original'
    assert (car.backing / 'demo.a').read_bytes() == b'original\x00'


def test_snapshot_free_recovery(folder):
    car = Car(folder)
    car.run('a', 'apply')
    car.run('a', 'revert')
    assert not (car.state / 'modules/a/build').exists()
    car.run('a', 'revert')  # Direct repeated revert is harmless.
    # Exact incident: completed disk revert, stale desired ON, failed stock pause.
    (car.state / 'desired/a').write_text('on')
    (car.state / 'stock').mkdir(exist_ok=True)
    (car.state / 'stock/paused').write_text('paused')
    car.run('stock', 'restore')
    assert (car.state / 'desired/a').read_text() == 'off'
    assert (car.state / 'stock/paused').exists()
    # The app's explicit enable is allowed to recover from the paused state.
    car.run('a', 'apply')
    assert not (car.state / 'stock/paused').exists()
    # Missing build is still a conflict when actual restore material exists.
    (car.state / 'modules/a/build').unlink()
    result = car.run('stock', 'restore', ok=False)
    assert 'build preflight: ro.build.product' in result.stdout
    assert (car.state / 'desired/a').read_text() == 'on'
    assert (car.state / 'modules/a/prop.demo.a/ready').exists()
    assert (car.live / 'demo.a').read_text() == 'ours'
    # Use the shipped CarPlay revert for the owner's empty-ledger recovery.
    (car.state / 'modules/a/build').write_text('NEEV.KOR.0000.V039.001.260902')
    car.run('stock', 'restore')
    module = 'wireless-carplay-and-aa'
    shutil.copyfile(ROOT / f'modules/{module}/module.properties',
                    car.base / f'modules/{module}.properties')
    (car.base / f'modules/{module}.sh').write_text(host_shell_script(
        (ROOT / f'modules/{module}/module.sh').read_text()))
    (car.base / 'modules.list').write_text(module + '\n')
    (car.base / 'modules.graph').write_text(module + '\tdepends=\texcludes=\n')
    (car.state / f'desired/{module}').write_text('on')
    assert not (car.state / f'modules/{module}/build').exists()
    assert (car.state / 'stock/paused').exists()
    result = car.run('stock', 'restore')
    assert 'state=off' in result.stdout or 'state=pending-restart' in result.stdout
    assert (car.state / f'desired/{module}').read_text() == 'off'
    car.run(module, 'revert')


def swap_fixture(folder):
    """The real wireless module script on an isolated /system with a known stock app_process."""
    import hashlib
    car = Car(folder)
    car.enable()
    module = 'wireless-carplay-and-aa'
    target = folder / 'target'
    (target / 'system/bin').mkdir(parents=True)
    (target / 'system/lib').mkdir()
    (target / 'system/framework').mkdir()
    process = target / 'system/bin/app_process'
    process.write_bytes(b'stock-executable')
    md5 = hashlib.md5(b'stock-executable').hexdigest()
    extras = [target / 'system/bin/app_process.hmg-seogaemo-stock',
              target / 'system/lib/libhmg_seogaemo_wireless_hook.so',
              target / 'system/framework/hmg-seogaemo-wireless-hook.jar']
    (car.base / f'modules/{module}.properties').write_text(
        'owns_files=' + ','.join(map(str, [process, *extras])) + ',/system/bin/app_process\n' +
        f'known_stock.1=NEEV.KOR.*.260902:/system/bin/app_process:{md5}\n')
    (car.base / f'modules/{module}.sh').write_text(host_shell_script(
        (ROOT / f'modules/{module}/module.sh').read_text()))
    (car.base / 'modules.list').write_text(f'{module}\na\nb\nc\n')
    (car.base / 'modules.graph').write_text(
        f'{module}\tdepends=\texcludes=\na\tdepends=\texcludes=\nb\tdepends=a\texcludes=\nc\tdepends=\texcludes=\n')
    (car.state / f'desired/{module}').write_text('on')
    car.env['SG_TARGET_ROOT'] = str(target)
    return car, module, target, process, extras


def test_stale_wrapper_guard(folder):
    """The wrapper's own guard state never blocks restore or uninstall; it is swept."""
    car, module, target, process, extras = swap_fixture(folder)
    key = module.replace('-', '_')
    state = car.state / f'modules/{module}'
    state.mkdir(parents=True, exist_ok=True)
    names = ('starts', 'enable', 'enabled', 'disable')

    def stale():
        for name in names:
            (state / name).write_text('2')

    # The live wrapper recreated `starts` (and the owner touched `disable`) after an earlier revert.
    stale()
    (state / 'keep').write_text('other state')
    result = car.run('stock', 'restore')
    assert f'info.module_{key}=reverted' in result.stdout, result.stdout
    assert not any((state / name).exists() for name in names) and (state / 'keep').exists()
    assert process.read_bytes() == b'stock-executable'
    ledger = (car.state / 'ledger/ledger.tsv').read_text()
    assert ledger.count('zygote_guard_sweep') == 4, ledger
    # The same with the module desired off (no restore material at all).
    (car.state / f'desired/{module}').write_text('off')
    stale()
    car.run('stock', 'restore')
    assert not any((state / name).exists() for name in names)
    # A restart that is still pending from an earlier revert in this boot stays pending.
    car.env['SG_BOOT_ID_FILE'] = str(car.boot)
    shutil.copy(car.boot, state / 'assets-repaired-boot')
    stale()
    result = car.run('stock', 'restore')
    assert 'state=pending-restart' in result.stdout and 'restart=head_unit' in result.stdout, result.stdout
    assert not any((state / name).exists() for name in names)
    # Package uninstall and the NEMESIS hook accept the same stale state.
    car.env.pop('SG_BOOT_ID_FILE')
    (state / 'assets-repaired-boot').unlink()
    stale()
    car.run('package', 'uninstall')
    assert not any((state / name).exists() for name in names)
    # Real evidence of an unrecorded swap still refuses, with the stale state untouched.
    (car.state / 'uninstall').exists() and shutil.rmtree(car.state / 'uninstall')
    stale()
    extras[0].write_bytes(b'stock-executable')
    result = car.run('stock', 'restore', ok=False)
    assert 'state=conflict' in result.stdout and 'app_process.hmg-seogaemo-stock' in result.stdout
    assert all((state / name).exists() for name in names)


def test_unrecorded_swap(folder):
    """An app_process swap with no ledger/baseline refuses restore and uninstall."""
    car, module, target, process, extras = swap_fixture(folder)
    key = module.replace('-', '_')

    def refused():
        result = car.run('stock', 'restore', ok=False)
        assert 'state=conflict' in result.stdout and f'info.module_{key}=conflict' in result.stdout, result.stdout
        # Preflight stops everything before the first module is reverted.
        assert car.calls.read_text() == ''
        for name in 'abc':
            assert (car.state / f'desired/{name}').read_text() == 'on'
        assert (car.state / f'desired/{module}').read_text() == 'on'
        for direct in ('revert', 'status'):
            outcome = car.run(module, direct, ok=False)
            assert 'state=conflict' in outcome.stdout and 'outside the ledger' in outcome.stdout, outcome.stdout
        car.run('package', 'uninstall', ok=False)
        assert not (car.state / 'uninstall').exists()
        car.hook(ok=False)
        assert car.apk.exists()
        return result

    # Our stock backup without any record.
    extras[0].write_bytes(b'stock-executable')
    assert 'app_process.hmg-seogaemo-stock' in refused().stdout
    extras[0].unlink()
    # Hook files without any record.
    extras[1].write_bytes(b'loader')
    refused()
    extras[1].unlink()
    # An executable that is not the known stock build, with nothing recorded.
    process.write_bytes(b'wrapper-of-unknown-origin')
    assert 'not the known stock build' in refused().stdout
    assert process.read_bytes() == b'wrapper-of-unknown-origin'
    # Never fixed automatically: it stays exactly as found until the owner resolves it.
    process.write_bytes(b'stock-executable')
    result = car.run('stock', 'restore')
    assert 'state=off' in result.stdout or 'state=pending-restart' in result.stdout
    assert f'info.module_{key}=reverted' in result.stdout
    for name in 'abc':
        assert (car.state / f'desired/{name}').read_text() == 'off'


def test_residue_on_restore(folder):
    """A successful whole-package restore also clears provable residue, best effort."""
    car = Car(folder)
    script(car.fake / 'nemesis', 'exit 0\n')
    target = folder / 'target'
    namespace = target / 'system/etc/hmg-seogaemo'
    (namespace / 'a/recipes').mkdir(parents=True)
    generated = target / 'data/data/com.example.one/app_hmg-seogaemo-wireless-runtime'
    generated.mkdir(parents=True)
    (generated / 'p-1-2.txt').write_text('generated')
    cache = target / 'data/dalvik-cache'
    cache.mkdir(parents=True)
    ours = cache / 'data@nemesis@apps@hmg-seogaemo@core@map@hmg-seogaemo-mapper.jar@classes.dex'
    other = cache / 'system@framework@core.jar@classes.dex'
    ours.write_text('cache')
    other.write_text('cache')
    vm = car.state / 'core/vm/dalvik-cache'
    vm.mkdir(parents=True)
    (vm / 'entry').write_text('cache')
    scratch = car.state / 'core/vm.status.4242/dalvik-cache'
    scratch.mkdir(parents=True)
    (car.base / 'modules/a.properties').write_text(
        'owns_props=demo.a\nwatch=boot,screen_on\n'
        'owns_files=/system/etc/hmg-seogaemo/a/recipes/x.recipe\n'
        'owns_generated_dirs=/data/data/com.example.one/app_hmg-seogaemo-wireless-runtime\n')
    car.env['SG_TARGET_ROOT'] = str(target)
    result = car.run('stock', 'restore')
    assert 'state=off' in result.stdout or 'state=pending-restart' in result.stdout
    assert not generated.exists() and not namespace.exists()
    assert not ours.exists() and other.exists() and not (car.state / 'core/vm').exists()
    assert not scratch.exists()
    ledger = (car.state / 'ledger/ledger.tsv').read_text()
    assert 'generated_dir_remove' in ledger and 'legacy_dir_remove' in ledger
    assert 'dex_legacy_remove' in ledger and 'stock_residue' in ledger
    # An unexpected entry in a generated directory never fails a restore: the plain
    # files go, the directory stays, and boot reconcile gets a retry marker.
    generated.mkdir(parents=True)
    (generated / 'nested').mkdir()
    (generated / 'p-1-2.txt').write_text('generated')
    result = car.run('stock', 'restore')
    assert 'state=off' in result.stdout or 'state=pending-restart' in result.stdout
    assert (generated / 'nested').is_dir() and not (generated / 'p-1-2.txt').exists()
    assert (car.state / 'restart-cleanup/a').is_file()


def only_module(car, name, properties, body=None, text=None):
    for old in 'abc':
        for ext in ('properties', 'sh'):
            (car.base / f'modules/{old}.{ext}').unlink()
    (car.base / 'modules.list').write_text(name + '\n')
    (car.base / 'modules.graph').write_text(f'{name}\tdepends=\texcludes=\n')
    (car.base / f'modules/{name}.properties').write_text(properties)
    if body is not None:
        script(car.base / f'modules/{name}.sh', body)
    else:
        (car.base / f'modules/{name}.sh').write_text(host_shell_script(text))
        (car.base / f'modules/{name}.sh').chmod(0o755)


def assert_fully_restored(car, name):
    result = car.run('stock', 'restore')
    assert 'state=off' in result.stdout, result.stdout
    assert f'info.module_{name.replace("-", "_")}=reverted' in result.stdout, result.stdout
    leftover = car.state / f'modules/{name}'
    assert not leftover.exists() or not [
        entry.name for entry in leftover.iterdir()
        if entry.name.startswith(('prop.', 'file.', 'bind.')) or entry.name in ('changes', 'build')], \
        sorted(entry.name for entry in leftover.iterdir())
    assert (car.state / f'desired/{name}').read_text() == 'off'
    assert not list((car.state / 'stock').glob('recovery.*'))


def test_noglob_module_restore(folder):
    # A module shell with noglob must still restore: the runtime globs state itself.
    car = Car(folder)
    only_module(car, 'a', 'owns_props=demo.a\nwatch=boot,screen_on\n', body='''
set -efu
id=${HMG_SEOGAEMO_STATE##*/}
case "$1" in
    apply) sg_prop_set "demo.$id" ours; sg_status on none enabled ;;
    revert) sg_revert_all || { sg_status conflict none drift; exit 3; }; sg_status off none restored ;;
    status) sg_status off none restored ;;
esac
''')
    car.run('a', 'apply')
    assert (car.live / 'demo.a').read_text() == 'ours'
    changes = car.state / 'modules/a/changes'
    changes.write_text(changes.read_text() * 5)
    assert_fully_restored(car, 'a')
    assert (car.live / 'demo.a').read_text() == ''


def test_wireless_adb_restore(folder):
    car = Car(folder)
    properties = (ROOT / 'modules/wireless-adb/module.properties').read_text().replace('@VERSION@', 'test')
    # The listener check reads /proc/net/tcp*: point it at a fake table with adbd
    # listening on 5555, never at the host's (Linux CI has a real, empty one).
    proc = folder / 'proc-net'
    proc.mkdir()
    (proc / 'tcp').write_text('  sl  local_address rem_address   st\n'
                              '   0: 00000000:15B3 00000000:0000 0A 00000000:00000000 00:00000000 00000000\n')
    (proc / 'tcp6').write_text('  sl  local_address rem_address   st\n')
    text = (ROOT / 'modules/wireless-adb/module.sh').read_text()
    text = text.replace('/proc/net/tcp6', f'{proc}/tcp6').replace('/proc/net/tcp', f'{proc}/tcp')
    only_module(car, 'wireless-adb', properties + 'watch=boot,screen_on\n', text=text)
    for name, body in {
        'stop': 'sg_print "stop $*" >> "$FAKE_CALLS"\n',
        'start': 'sg_print "start $*" >> "$FAKE_CALLS"; sg_write running > "$FAKE_LIVE/init.svc.adbd"\n',
        'ifconfig': 'exit 1\n', 'netcfg': 'exit 0\n',
    }.items():
        script(car.fake / name, body)
    (car.live / 'init.svc.adbd').write_text('running')
    (car.live / 'ro.build.version.sdk').write_text('19')
    shutil.copytree(ROOT / 'maps', car.base / 'maps')  # the car gate needs this firmware's map
    car.run('wireless-adb', 'apply')
    assert (car.state / 'modules/wireless-adb/changes').is_file()
    changes = car.state / 'modules/wireless-adb/changes'
    changes.write_text(changes.read_text() * 5)
    assert_fully_restored(car, 'wireless-adb')


run_tests([
    test_restore,
    test_conflict,
    test_failure_and_hook,
    test_detached,
    test_late_failure,
    test_detached_failure,
    test_missing_handoff,
    test_shared_lines,
    test_file_metadata_diagnostic,
    test_reassert_restore,
    test_snapshot_free_recovery,
    test_damaged_selection_recovery,
    test_unrecorded_swap,
    test_stale_wrapper_guard,
    test_residue_on_restore,
    test_noglob_module_restore,
    test_wireless_adb_restore,
], 'stock restore, shared hook, and detached uninstall passed')
