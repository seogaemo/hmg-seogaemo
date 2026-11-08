#!/usr/bin/env python3
"""Stable entry points execute selected logic; invalid commands never reach it."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from testlib import car_env, SHELL, host_shell_tree

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    stable = root / 'stable'
    selected = root / 'selected'
    shutil.copytree(ROOT / 'nemesis/package', stable)
    host_shell_tree(stable)
    current = root / 'state/update/current'
    current.parent.mkdir(parents=True)
    # Minimal complete runtime; binary contents are irrelevant to routing fixtures.
    (stable / 'modules').mkdir()
    (stable / 'modules.list').write_text('wifi\n')
    (stable / 'modules.graph').write_text('wifi	depends=	excludes=\n')
    (stable / 'modules/wifi.properties').write_text('id=wifi\n')
    (stable / 'modules/wifi.sh').write_text(
        'echo stable-module >> "$CALLS"; echo state=off; echo restart=none\n')
    for member in ('VERSION', 'app/hmg-seogaemo.apk', 'core/map/hmg-seogaemo-mapper.jar'):
        target = stable / member
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('fixture')
    shutil.copytree(stable, selected)
    current.symlink_to(selected, target_is_directory=True)
    calls = root / 'calls'
    calls.touch()
    env = car_env(dict(os.environ, SG_DATA_ROOT=str(root / 'state'), CALLS=str(calls)))
    def run(path, *args):
        return subprocess.run([SHELL, str(path), *args], env=env,
                              capture_output=True, text=True, timeout=10)
    entries = ['bin/hmg-seogaemo-root', 'bin/open.sh', 'svc/reconcile.sh',
               'svc/watcher.sh']
    real_dispatcher = (stable / entries[0]).read_text()
    # A directly invoked OTA dispatcher still finds the installed recovery anchor.
    real_dispatcher = real_dispatcher.replace('/data/nemesis/apps/hmg-seogaemo', str(stable))
    (stable / entries[0]).write_text(real_dispatcher)
    for entry in entries:
        target = selected / entry
        target.write_text('echo selected\nfor arg do echo "arg=$arg"; done\n')
        args = ('wifi', 'revert') if entry.endswith('hmg-seogaemo-root') else ()
        result = run(stable / entry, *args)
        assert result.returncode == 0 and result.stdout.startswith('selected\n'), (entry, result)
    dispatcher = stable / entries[0]
    for args in [(), ('device', 'bad'), ('stock', 'restore', 'extra'),
                 ('map', 'shell'), ('bad/path', 'status'), ('wifi', 'watch', 'bad')]:
        result = run(dispatcher, *args)
        assert result.returncode == 2 and 'selected' not in result.stdout
    # Fixed recovery routes never execute a selected dispatcher or selected hook.
    original_stock = (stable / 'core/stock.sh').read_text()
    (stable / 'core/update.sh').write_text(
        'echo "update:$1" >> "$CALLS"; echo state=off; echo restart=none\n')
    (stable / 'core/stock.sh').write_text(
        'echo "stock:$1" >> "$CALLS"; echo state=off; echo restart=none\n')
    (selected / 'scripts/preuninstall.sh').write_text('echo selected-hook; exit 90\n')
    result = run(stable / 'scripts/preuninstall.sh')
    assert result.returncode == 0 and 'selected' not in result.stdout, result
    def recovery():
        for verb in ('status', 'stage', 'apply', 'rollback'):
            result = run(dispatcher, 'update', verb)
            assert result.returncode == 0 and 'state=off' in result.stdout, result
            assert calls.read_text().splitlines()[-1] == 'update:' + verb
        for first, verb, expected in (('stock', 'status', 'status'),
                ('stock', 'restore', 'restore'), ('package', 'uninstall', 'uninstall')):
            result = run(dispatcher, first, verb)
            assert result.returncode == 0 and 'state=off' in result.stdout, result
            assert calls.read_text().splitlines()[-1] == 'stock:' + expected
    recovery()
    # Each damaged selection leaves recovery and read-only module queries usable.
    for member, damage in [('lib/common.sh', None), ('bin/hmg-seogaemo-root', ''),
            ('bin/hmg-seogaemo-root', 'if then\n'), ('modules/wifi.sh', None),
            ('core/map/hmg-seogaemo-mapper.jar', '')]:
        target = selected / member
        saved = target.read_bytes()
        if damage is None: target.unlink()
        else: target.write_text(damage)
        recovery()
        for verb in ('status', 'precheck'):
            assert 'state=off' in run(dispatcher, 'wifi', verb).stdout
        before = calls.read_bytes()
        for args in [('wifi', 'apply'), ('wifi', 'revert'),
                     ('wifi', 'watch', 'boot'), ('map', 'run'), ('map', 'verify'),
                     ('map', 'export')]:
            result = run(dispatcher, *args)
            assert result.returncode == 1 and 'state=failed' in result.stdout, result
            assert 'restart=none' in result.stdout and 'detail=Selected OTA payload damaged' in result.stdout
        assert calls.read_bytes() == before
        target.write_bytes(saved)
    # A valid-syntax selected failure runs exactly once and is never replayed.
    (selected / entries[0]).write_text(
        'echo selected-failure >> "$CALLS"; echo state=failed; echo restart=none; exit 1\n')
    calls.write_text('')
    result = run(dispatcher, 'wifi', 'apply')
    assert result.returncode == 1 and calls.read_text() == 'selected-failure\n', result
    (stable / 'core/stock.sh').write_text(original_stock)
    # Canonical aliases and a real selected entry must not recurse.
    current.unlink()
    current.symlink_to(stable, target_is_directory=True)
    assert 'state=off' in run(dispatcher, 'wifi', 'status').stdout
    shutil.copytree(stable, selected, dirs_exist_ok=True)
    (selected / 'NEMESIS.data').unlink()  # OTA archives omit the descriptor.
    current.unlink()
    current.symlink_to(selected, target_is_directory=True)
    assert 'state=off' in run(dispatcher, 'wifi', 'status').stdout
    assert 'state=off' in run(selected / entries[0], 'wifi', 'status').stdout
    assert 'state=off' in run(selected / entries[0], 'update', 'rollback').stdout
    current.unlink()
    current.symlink_to(root / 'missing')
    assert 'state=off' in run(dispatcher, 'wifi', 'status').stdout
    # USB repair must execute the fresh tree even with a stale OTA selection.
    current.unlink()
    current.symlink_to(selected, target_is_directory=True)
    (selected / 'scripts/postinstall.sh').write_text('echo stale; exit 90\n')
    hook = stable / 'scripts/postinstall.sh'
    hook.write_text(hook.read_text().replace('/system/xbin/nemesis', str(root / 'nemesis')))
    (root / 'nemesis').write_text('client')
    fake = root / 'fake'
    fake.mkdir()
    (fake / 'getprop').write_text(
        '#!/bin/sh\ncase "$1" in ro.build.version.sdk) echo 19;; *) echo NEEV.KOR.0000.V039.001.260902;; esac\n')
    (fake / 'getprop').chmod(0o755)
    env['PATH'] = str(fake) + ':' + env['PATH']
    for pointer in ('current-path', 'previous-path', 'previous-version', 'journal'):
        (current.parent / pointer).write_text('old')
    result = run(hook)
    assert result.returncode == 0 and 'stale' not in result.stdout, result
    assert not current.is_symlink()
    assert selected.is_dir()
    assert not (current.parent / 'previous-path').exists()
    # Android-up repair installs from the fresh tree before retiring selection.
    (fake / 'getprop').write_text(
        '#!/bin/sh\ncase "$1" in sys.boot_completed) echo 1;; ro.build.version.sdk) echo 19;; '
        '*) echo NEEV.KOR.0000.V039.001.260902;; esac\n')
    installer = stable / 'bin/install-apk.sh'
    installer.write_text('echo fresh-install; [ "${FAIL_INSTALL:-0}" = 0 ]\n')
    boot_id = root / 'boot-id'
    boot_id.write_text('fixture-boot\n')
    env['SG_BOOT_ID_FILE'] = str(boot_id)
    (fake / 'pm').write_text('#!/bin/sh\n[ "$2" != android ] || echo package:android\n')
    (fake / 'pm').chmod(0o755)
    for failure in ('1', '0'):
        if not current.is_symlink():
            current.symlink_to(selected, target_is_directory=True)
        for pointer in ('current-path', 'previous-path', 'previous-version', 'journal'):
            (current.parent / pointer).write_text('old')
        env['FAIL_INSTALL'] = failure
        result = run(hook)
        assert 'fresh-install' in result.stdout and 'stale' not in result.stdout, result
        assert result.returncode == (1 if failure == '1' else 0), result
        # The OTA selection is retired before the APK step, so even a failed
        # install never leaves the older selected payload serving root verbs.
        assert not current.is_symlink()
        assert not (current.parent / 'previous-path').exists()
        assert selected.is_dir()
    # An explicit USB install proceeds while a failed stock restore is paused,
    # and leaves the pause (and its stale desired states) untouched.
    paused = root / 'state/stock/paused'
    paused.parent.mkdir(parents=True, exist_ok=True)
    paused.write_text('paused')
    current.symlink_to(selected, target_is_directory=True)
    (current.parent / 'journal').write_text('old')
    env['FAIL_INSTALL'] = '0'
    (root / 'state/app-install/seen').unlink()  # fake pm never reports the app
    result = run(hook)
    assert result.returncode == 0 and 'fresh-install' in result.stdout, result
    assert not current.is_symlink() and not (current.parent / 'journal').exists()
    assert paused.read_text() == 'paused'
print('stable and OTA entry dispatch passed')
