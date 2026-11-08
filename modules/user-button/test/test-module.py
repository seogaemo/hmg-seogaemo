"""Exercise module lifecycle with the real baseline/restore API and fake properties."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

MODULE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
MODULE_ID = MODULE.name
ROOT = MODULE.parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from testlib import SHELL, car_env
KEY = sys.argv[2] if len(sys.argv) > 2 else 'persist.sys.key.swrccustom'
INITIAL = sys.argv[3] if len(sys.argv) > 3 else 'gohome'
ACTION = 'com.seogaemo.hmg.USER_BUTTON_SWRC'
OTHER_KEY = 'persist.sys.key.custom'
OTHER_ACTION = 'com.seogaemo.hmg.USER_BUTTON_HEAD'
with tempfile.TemporaryDirectory() as directory:
    base = Path(directory).resolve()
    state = base / 'state' / MODULE_ID
    for name in ('lib', 'modules', 'props', 'backing', 'bin'):
        (base / name).mkdir()
    state.mkdir(parents=True)
    shutil.copy(ROOT / 'nemesis/package/lib/common.sh', base / 'lib/common.sh')
    shutil.copy(MODULE / 'module.properties', base / 'modules' / (MODULE_ID + '.properties'))
    def fake(name, body):
        p = base / 'bin' / name
        p.write_text('#!/bin/sh\n. "$HMG_SEOGAEMO_BASE/lib/common.sh"\n' + body)
        p.chmod(0o755)
    fake('getprop', 'cat "$FAKE_PROPS/$1" 2>/dev/null || :\n')
    fake('setprop', '[ ! -f "$FAKE_PROPS/fail" ] || exit 1\nsg_write "$2" > "$FAKE_PROPS/$1"\nsg_write "$2" > "$SG_PROPERTY_ROOT/$1"\n')
    env = car_env(dict(os.environ, PATH=str(base / 'bin') + ':' + os.environ['PATH'],
        FAKE_PROPS=str(base / 'props'), HMG_SEOGAEMO_BASE=str(base),
        HMG_SEOGAEMO_STATE=str(state), SG_DATA_ROOT=str(base / 'data'),
        SG_PROPERTY_ROOT=str(base / 'backing')))
    (base / "data/desired").mkdir(parents=True)
    settings = base / 'data/settings' / MODULE_ID
    settings.mkdir(parents=True)
    def setting(key, value): (settings / key).write_text(value)
    def prop(key, value): (base / 'props' / key).write_text(value)
    def run(verb, expected, code=0, module=MODULE, module_state=state, event=None):
        module_env = dict(env, HMG_SEOGAEMO_STATE=str(module_state))
        args = [SHELL, str(module / 'module.sh'), verb]
        if event is not None: args.append(event)
        p = subprocess.run(args, env=module_env, capture_output=True, text=True)
        assert p.returncode == code, (verb, p.stdout, p.stderr)
        if expected is not None: assert 'state=' + expected in p.stdout, p.stdout
        if code == 0 and verb in ('apply', 'revert'):
            (base / 'data/desired' / module.name).write_text('on' if verb == 'apply' else 'off')
        return p.stdout
    # Any firmware with a car map passes the car gate (not only the Ioniq 5 the module was built on).
    product = 'TEST.KOR.0000.V001.001.270101'
    for mapped in (product, 'TEST.KOR.changed.270101'):
        car = base / 'maps/test/car/kor' / mapped
        car.mkdir(parents=True)
        (car / 'car.json').write_text('{\n  "product": "%s"\n}\n' % mapped)
    prop('ro.build.product', 'WRONG.KOR.0000.V001.001.270101')
    run('apply', 'incompatible', 4)
    prop('ro.build.product', product)
    prop('ro.build.version.sdk', '19')
    prop(KEY, INITIAL)
    original = INITIAL.encode() + b'\x00'
    (base / 'backing' / KEY).write_bytes(original)
    run('status', 'off')
    run('apply', 'on')  # no button chosen: nothing is assigned
    assert not list(state.iterdir()) and (base / 'props' / KEY).read_text() == INITIAL
    run('revert', 'off')
    setting('swrc', 'on')
    run('status', 'off')
    assert not list(state.iterdir())
    assert 'warn.assignment=1' in run('precheck', 'off')
    run('watch', None, 3, event='boot')
    (base / 'data/desired' / MODULE_ID).write_text('on')
    run('watch', 'failed', 1, event='boot')
    assert not (state / ('prop.' + KEY) / 'ready').exists()
    (base / 'data/desired' / MODULE_ID).write_text('off')
    run('apply', 'on')
    run('apply', 'on')
    assert (state / ('prop.' + KEY) / 'live').read_text() == INITIAL
    # Stock reset after boot, and stock settings choice after screen-on.
    for event, value in [('boot', INITIAL), ('screen_on', 'external.choice')]:
        prop(KEY, value)
        before = (base / 'props' / KEY).read_bytes()
        assert 'info.desired=on' in run('status', 'pending-restart')
        assert (base / 'props' / KEY).read_bytes() == before  # read-only status
        run('watch', 'on', event=event)
        assert (base / 'props' / KEY).read_text() == ACTION
        assert (state / ('prop.' + KEY) / 'live').read_text() == INITIAL
        assert (state / ('prop.' + KEY) / 'backing').read_bytes() == original
    changes = (state / 'changes').read_bytes()
    run('watch', 'on', event='screen_on')
    assert (state / 'changes').read_bytes() == changes  # no matching-value write
    prop(KEY, 'external.choice')
    run('apply', 'on')  # confirmed apply/reconcile also wins over drift
    prop(KEY, 'another.choice')
    run('revert', 'off')  # even a drifted value restores the ORIGINAL baseline
    assert (base / 'props' / KEY).read_text() == INITIAL
    assert (base / 'backing' / KEY).read_bytes() == original
    # Absent backing file is restored as absent, including an empty live value.
    (base / 'backing' / KEY).unlink()
    prop(KEY, '')
    run('apply', 'on')
    prop(KEY, 'stock.reset')
    prop('ro.build.product', 'TEST.KOR.changed.270101')
    run('watch', 'conflict', 3, event='boot')
    run('apply', 'conflict', 3)
    run('revert', 'conflict', 3)
    assert (base / 'props' / KEY).read_text() == 'stock.reset'
    prop('ro.build.product', product)
    run('revert', 'off')
    assert not (base / 'backing' / KEY).exists()
    prop('ro.build.version.sdk', '20')
    run('apply', 'incompatible', 4)
    prop('ro.build.version.sdk', '19')
    prop(KEY, ACTION)
    run('apply', 'conflict', 3)
    prop(KEY, INITIAL)
    (base / 'props/fail').touch()
    run('apply', 'failed', 1)
    (base / 'props/fail').unlink()
    run('revert', 'off')
    # Each button is its own setting: turning one off (revert, then apply, as a setting change
    # does) restores only that button, and the watcher reasserts only enabled buttons.
    prop(KEY, INITIAL)
    prop(OTHER_KEY, 'other.original')
    (base / 'backing' / OTHER_KEY).write_bytes(b'other.original\x00')
    run('apply', 'on')
    assert (base / 'props' / OTHER_KEY).read_text() == 'other.original'
    setting('head', 'on')
    run('revert', 'off'); run('apply', 'on')
    assert (base / 'props' / OTHER_KEY).read_text() == OTHER_ACTION and (base / 'props' / KEY).read_text() == ACTION
    assert 'info.button_head=on' in run('status', 'on')
    setting('head', 'off')
    run('revert', 'off'); run('apply', 'on')
    assert (base / 'props' / OTHER_KEY).read_text() == 'other.original'
    assert (base / 'backing' / OTHER_KEY).read_bytes() == b'other.original\x00'
    prop(KEY, 'external.choice')
    prop(OTHER_KEY, 'other.drift')
    run('watch', 'on', event='screen_on')
    assert (base / 'props' / KEY).read_text() == ACTION
    assert (base / 'props' / OTHER_KEY).read_text() == 'other.drift'
    # The shortcut the separate modules wrote before the merge counts as ours: without a
    # baseline it is a conflict, never a stock value to save as the original.
    prop(OTHER_KEY, 'com.seogaemo.hmg.USER_BUTTON_SHORTCUT')
    run('status', 'conflict', 3)
    prop(OTHER_KEY, 'other.original')
    prop(KEY, 'final.drift')
    run('revert', 'off')
    assert (base / 'props' / KEY).read_text() == INITIAL
    run('watch', None, 3, event='screen_on')
    assert (base / 'props' / KEY).read_text() == INITIAL
print(MODULE_ID + ' reassertion, restore and independence tests passed')
