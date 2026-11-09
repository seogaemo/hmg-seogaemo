#!/usr/bin/env python3
"""Verify reflection shapes and cache invalidation with a real JVM class loader."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MAIN = 'com.seogaemo.hmg.core.map.HmgSeogaemoMapTool'
with tempfile.TemporaryDirectory(prefix='hmg-seogaemo-map-verification-') as tmp:
    temp = Path(tmp)
    classes = temp / 'classes'
    classes.mkdir()
    loader = temp / 'PathClassLoader.java'
    loader.write_text('''package dalvik.system;
public class PathClassLoader extends java.net.URLClassLoader {
 public PathClassLoader(String path, ClassLoader parent) throws Exception {
  super(new java.net.URL[]{new java.io.File(path).toURI().toURL()},parent);
 }
}
''')
    subprocess.run(['javac', '-source', '7', '-target', '7', '-d', str(classes),
                    *map(str, (ROOT / 'core/map/src').rglob('*.java')), str(loader),
                    str(ROOT / 'tools/fixtures/dex/Example.java')], check=True)
    # The JVM resolves /system/app/...apk below to this isolated fixture JAR.
    apk = temp / 'Example.apk'
    subprocess.run(['jar', 'cf', str(apk), '-C', str(classes), 'com/example'], check=True)
    package = temp / 'package'
    bundle = package / 'maps/x/y/z/w'
    bundle.mkdir(parents=True)
    catalogue = package / 'hookpoints'
    catalogue.mkdir()
    (catalogue / 'example.json').write_text('{}')
    required = package / 'hookpoints.required'
    required.mkdir()
    (required / 'example').write_text('example.target\nexample.target.unique\n')
    system = temp / 'system/app'
    system.mkdir(parents=True)
    stock = system / 'Example.odex'
    stock.write_bytes(b'exact stock identity')
    # For reflection the declared app path is a host fixture; sameCar still hashes stock.
    car = dict(schema=1, product='TEST.KOR.1', onebin='test_kr', android='4.4.2',
               files={'/system/app/Example.odex': hashlib.md5(stock.read_bytes()).hexdigest()},
               app_files={'example': {'package': 'com.example', 'files': [str(apk)]}},
               missing={}, by_reference=['example.target.bad_static'])
    points = {
        'example.target': {'class': 'com.example.Example'},
        'example.target.unique': {'method': 'unique', 'params': [], 'ret': 'void', 'static': False},
        'example.target.handle': {'field': 'handle', 'type': 'long', 'static': True},
        'example.target.lock': {'field': 'lock', 'type': 'java.lang.Object', 'static': True},
        'example.target.as_interface': {'method': 'asInterface', 'params': ['java.lang.Object'],
                                        'ret': 'com.example.Example', 'static': True},
        'example.target.add_listener': {'method': 'addListener', 'params': ['com.example.Example'],
                                        'ret': 'void', 'static': False},
        'example.target.bad_static': {'field': 'handle', 'type': 'long', 'static': False},
        'example.target.bad_signature': {'method': 'asInterface', 'params': ['com.example.Example'],
                                        'ret': 'com.example.Example', 'static': True},
    }
    (bundle / 'car.json').write_text(json.dumps(car))
    (bundle / 'map.json').write_text(json.dumps(dict(schema=1, points=points)))
    state = temp / 'state'
    state.mkdir()
    scratch = temp / 'scratch'
    scratch.mkdir()
    boot = temp / 'boot'
    boot.write_text('boot-one\n')
    env = dict(os.environ, HMG_SEOGAEMO_MAP_SYSTEM=str(temp / 'system'),
               HMG_SEOGAEMO_MAP_PRODUCT=car['product'], HMG_SEOGAEMO_MAP_ONEBIN=car['onebin'],
               HMG_SEOGAEMO_MAP_ANDROID=car['android'], HMG_SEOGAEMO_MAP_BOOT_FILE=str(boot))

    def run(verb, success=True):
        result = subprocess.run(['java', '-cp', str(classes), MAIN, verb, str(package), str(state),
                                 str(scratch)], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result.stdout

    def publish():
        run('verify')
        relative = '/'.join([car['product'], (scratch / 'hash-id').read_text().strip(),
                             (scratch / 'map-id').read_text().strip()])
        active = state / 'car-maps' / relative
        if active.exists():
            for name in ('map.json', 'car.json', 'verified', 'layout'):
                assert (active / name).read_bytes() == (scratch / name).read_bytes(), name
        active.mkdir(parents=True, exist_ok=True)
        for path in scratch.iterdir():
            if path.is_file():
                shutil.copyfile(path, active / path.name)
        (state / 'car-maps/active').write_text(relative + '\n')
        return active

    assert 'state=off\n' in run('status')
    active = publish()
    verified = json.loads((active / 'map.json').read_text())['points']
    assert json.loads((active / 'car.json').read_text())['by_reference'] == []
    assert len(verified) == 6 and 'example.target.bad_static' not in verified
    assert 'example.target.bad_signature' not in verified
    assert 'info.verified=6\n' in run('status')  # Filtered optional failures stay cached.
    lines = (active / 'verified').read_text().splitlines()
    assert lines[:3] == [car['product'], (active / 'hash-id').read_text().strip(), 'boot-one']
    assert len(lines) == 4  # Projection's product/hash prefix is unchanged.
    assert publish() == active  # Identical verification has a stable map ID.
    (state / 'car-maps/active').write_text('invalid-pointer\n')
    active = publish()  # Explicit verification repairs the pointer through the bundle.
    old_id = active.name
    relocated = bundle.with_name('relocated')
    bundle.rename(relocated)
    bundle = relocated
    assert 'state=off\n' in run('status')
    active = publish()
    assert active.name != old_id
    assert (active / 'layout').read_text() == 'maps/x/y/z/relocated\n'
    for path, content in ((bundle / 'map.json', json.dumps(dict(schema=1, points=points), indent=2)),
                          (bundle / 'car.json', json.dumps(dict(car, missing={'example.optional': 'absent'}))),
                          (bundle / 'car.json', json.dumps(dict(car, by_reference=['example.target.handle']))),
                          (bundle / 'car.json', json.dumps(dict(car, app_files={
                              'example': dict(package='com.example.changed', files=[str(apk)])}))),
                          (catalogue / 'example.json', '{"schema":1}'),
                          (required / 'example', 'example.target\n'),
                          (required / 'other', 'example.target.unique\n')):
        old_id = active.name
        path.write_text(content)
        assert 'state=off\n' in run('status'), path
        active = publish()
        assert active.name != old_id, path
        assert 'state=on\n' in run('status'), path
    # A legacy receipt belongs to its old immutable ID, not a corrupted new ID.
    legacy = active.with_name('0' * 32)
    active.rename(legacy)
    (state / 'car-maps/active').write_text(str(legacy.relative_to(state / 'car-maps')) + '\n')
    (legacy / 'verified').write_text('\n'.join(lines[:3]) + '\n')
    assert 'state=off\n' in run('status')  # Old three-line receipt migrates by re-verification.
    active = publish()
    boot.write_text('boot-two\n')
    assert 'state=off\n' in run('status')
    active = publish()
    assert 'state=on\n' in run('status')
    # Generated maps remain usable after boot and keep their PR export layout.
    shutil.rmtree(package / 'maps')
    for path in scratch.iterdir():
        if path.is_file():
            path.unlink()
    boot.write_text('boot-three\n')
    active = publish()
    assert (active / 'layout').read_text() == 'maps/x/y/z/relocated\n'
    assert 'state=on\n' in run('status')
    assert publish() == active
    stock.write_bytes(b'changed firmware')
    assert 'state=incompatible\n' in run('status')
    assert 'mapping needed' in run('verify', success=False)
    stock.write_bytes(b'exact stock identity')
    (required / 'example').write_text('example.target.bad_static\n')
    pointer = (state / 'car-maps/active').read_text()
    for path in scratch.iterdir():
        if path.is_file():
            path.unlink()
    assert 'required point failed: example.target.bad_static' in run('verify', success=False)
    assert (state / 'car-maps/active').read_text() == pointer
    # Nothing is published, but the candidate stays in scratch with the reason each point failed.
    assert (scratch / 'incomplete').read_text() == 'example.target.bad_static\n'
    assert not (scratch / 'verified').exists() and not (scratch / 'map-id').exists()
    kept = json.loads((scratch / 'car.json').read_text())
    assert kept['incomplete'] == ['example.target.bad_static']
    assert 'example.target.bad_static' in kept['missing']
    assert 'example.target.bad_static' not in json.loads((scratch / 'map.json').read_text())['points']
    assert (scratch / 'layout').read_text() == 'maps/x/y/z/relocated\n'
    (required / 'example').write_text('example.target.bad_static\nexample.target.bad_signature\n')
    assert 'required point failed: example.target.bad_static (+1 more)' in run('verify', success=False)
    assert (scratch / 'incomplete').read_text() == 'example.target.bad_static\nexample.target.bad_signature\n'
print('map reflection static/ref signatures, optional filtering, input/boot invalidation and legacy migration passed')
