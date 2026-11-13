#!/usr/bin/env python3
"""Reject promoted, stale or mismatched evidence; check generated coverage."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('map_evidence', ROOT / 'tools/hmg-seogaemo-map-evidence.py')
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)
source = ROOT / 'maps/hyundai/ioniq5/kor/260902'
with tempfile.TemporaryDirectory(prefix='hmg-seogaemo-evidence-') as tmp:
    folder = Path(tmp)
    for name in ('map.json', 'car.json', 'evidence.json'):
        shutil.copyfile(source / name, folder / name)
    record, reflected = evidence.validate(folder)
    assert len(reflected) == 324
    assert len(record['mapped']['observations'][0]['points']) == 18
    assert 'iap2.service.native_handle' not in reflected
    original = copy.deepcopy(record)
    for mutate in (
        lambda e: e.update(vin='forbidden'),
        lambda e: e['mapped'].update(points_sha256='0' * 64),
        lambda e: e['reflection'][0].update(product='OTHER.KOR'),
        lambda e: e['reflection'][0].update(onebin='other_kr'),
        lambda e: e['reflection'][0].update(android='4.4.3'),
        lambda e: e['reflection'][0]['files'].update({'/system/framework/automotive.odex': '0' * 32}),
        lambda e: e['reflection'][0].update(points=sorted(e['reflection'][0]['points'] + ['iap2.service.native_handle'])),
        lambda e: e['mapped']['observations'][0]['points']['iap2.service.native_handle']['member'].update(static=False),
        lambda e: e['mapped']['observations'][0]['stock_files'].update({'/system/app/Iap2ServerApp.odex': '0' * 32}),
        lambda e: e['mapped']['observations'][0]['stock_files'].update({'/system/app/Other.odex': '0' * 32}),
        lambda e: e['mapped']['observations'][0]['stock_files'].update({'/system/framework/services.odex': 'nothex'}),
        lambda e: e['mapped'].update(observations=[]),
    ):
        record = copy.deepcopy(original)
        mutate(record)
        (folder / 'evidence.json').write_text(json.dumps(record))
        try:
            evidence.validate(folder)
        except ValueError:
            pass
        else:
            raise AssertionError('unsafe evidence accepted')
    (folder / 'evidence.json').write_text(json.dumps(original))
    mapping = json.loads((folder / 'map.json').read_text())
    mapping['points']['iap2.service.native_handle']['type'] = 'int'
    (folder / 'map.json').write_text(json.dumps(mapping))
    try:
        evidence.validate(folder)
    except ValueError:
        pass
    else:
        raise AssertionError('changed mapping accepted under old evidence')
# A host-only bundle: every point is a mapping observation, and the two WindowManagerService
# points bind to services.odex, a boot classpath member car.json does not hash.
record, reflected = evidence.validate(ROOT / 'maps/hyundai/cn7/kor/260902')
assert not reflected and len(record['mapped']['observations'][0]['points']) == 349
assert record['mapped']['observations'][0]['points']['framework.window_manager_service']['stock_file'] == '/system/framework/services.odex'
subprocess.run(['python3', str(ROOT / 'tools/hmg-seogaemo-map-evidence.py'), 'check'], check=True)
print('map evidence rejects promoted reflection, wrong stock identity and changed signatures')
