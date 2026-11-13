#!/usr/bin/env python3
"""Validate host-only map evidence and generate catalogue coverage."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('map_validation', ROOT / 'tools/validate-maps.py')
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


BOOT_FILE = re.compile(r'/system/framework/[A-Za-z0-9_.-]+\.odex')
MD5 = re.compile(r'[0-9a-f]{32}')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=True).encode()).hexdigest()


def exact(value, keys, label):
    if not isinstance(value, dict) or set(value) != set(keys.split()):
        raise ValueError('invalid evidence fields: ' + label)


def validate(directory, stock=None):
    mapping = json.loads((directory / 'map.json').read_text())['points']
    car = json.loads((directory / 'car.json').read_text())
    evidence = json.loads((directory / 'evidence.json').read_text())
    exact(evidence, 'schema mapped reflection physical_features', 'root')
    if evidence['schema'] != 1:
        raise ValueError('invalid evidence schema')
    mapped = evidence['mapped']
    exact(mapped, 'points_sha256 observations', 'mapped')
    if mapped['points_sha256'] != digest(mapping):
        raise ValueError('mapped evidence snapshot changed')
    observed = set()
    extra_stock = {}
    for observation in mapped['observations']:
        exact(observation, 'date source points stock_files', 'mapping observation')
        if observation['source'] not in ('owner-preinstall-report', 'kor-stock-dex-scan'):
            raise ValueError('unknown mapping evidence source')
        if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', observation['date']):
            raise ValueError('invalid observation date')
        if not observation['points'] or not set(observation['points']) <= set(mapping):
            raise ValueError('mapping observation contains unmapped IDs')
        observed.update(observation['points'])
        for point, fact in observation['points'].items():
            exact(fact, 'class member stock_file', point)
            if fact['stock_file'] not in observation['stock_files']:
                raise ValueError('point stock source absent: ' + point)
            entry = mapping[point]
            owner = point.rsplit('.', 1)[0]
            expected_class = entry.get('class', mapping.get(owner, {}).get('class'))
            if fact['class'] != expected_class or fact['member'] != entry:
                raise ValueError('point evidence signature changed: ' + point)
        if not observation['stock_files']:
            raise ValueError('unknown mapping stock files')
        for path, md5 in observation['stock_files'].items():
            if path in car['files']:
                if md5 != car['files'][path]:
                    raise ValueError('mapping stock hash mismatch')
            elif not (BOOT_FILE.fullmatch(path) and MD5.fullmatch(md5)):
                # A host scan may find a framework class on a boot classpath member the
                # catalogue does not hash (e.g. services.odex); record it with its MD5.
                raise ValueError('unknown mapping stock files')
            elif stock is not None:
                extra_stock[path] = md5
    reflected = set()
    for event in evidence['reflection']:
        exact(event, 'date source product onebin android files points points_sha256', 'reflection')
        if event['source'] != 'owner-on-car-reflection-result' or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', event['date']):
            raise ValueError('invalid reflection source/date')
        if any(event[key] != car[key] for key in ('product', 'onebin', 'android', 'files')):
            raise ValueError('reflection exact-stock identity mismatch')
        ids = event['points']
        if not isinstance(ids, list) or not ids or ids != sorted(set(ids)) or not set(ids) <= set(mapping):
            raise ValueError('invalid reflection point set')
        if event['points_sha256'] != digest({key: mapping[key] for key in ids}):
            raise ValueError('reflection signatures changed since observation')
        reflected.update(ids)
    if observed | reflected != set(mapping):
        raise ValueError('mapped points lack evidence')
    for feature in evidence['physical_features']:
        exact(feature, 'feature version result observation', 'physical feature')
        if feature['result'] not in ('partial', 'passed', 'failed', 'pending') or not all(
                isinstance(feature[key], str) and feature[key] for key in feature):
            raise ValueError('invalid physical feature observation')
    if stock is not None:
        for path, md5 in dict(car['files'], **extra_stock).items():
            actual = hashlib.md5((stock / path[len('/system/'):]).read_bytes()).hexdigest()
            if actual != md5:
                raise ValueError('dump hash mismatch: ' + path)
    return evidence, reflected


def generate():
    points, files, apps = validation.catalogue()
    required = validation.requirements(points)
    bundles = []
    for path in sorted((ROOT / 'maps').glob('*/*/*/*/car.json')):
        directory = path.parent
        validation.validate_bundle(directory, points, files, apps, required)
        evidence, reflected = validate(directory)
        bundles.append((directory, json.loads(path.read_text()),
                        json.loads((directory / 'map.json').read_text())['points'], evidence, reflected))
    lines = ['# Hookpoint catalogue and coverage', '',
             'Generated by tools/hmg-seogaemo-map-evidence.py generate; do not edit by hand.', '',
             f'The independently authored catalogue contains **{len(points)} points**. Stable IDs follow HMG-API; see [UPSTREAM.md](../UPSTREAM.md).', '',
             'Mapped means a name/signature was resolved. Reflection means the listed points were checked on the exact product, onebin, Android release and stock MD5 set in the sidecar. Neither proves a physical feature works. Host validation checks evidence consistency; it does not reproduce an on-car result.', '']
    for directory, car, mapping, evidence, reflected in bundles:
        label = directory.relative_to(ROOT).as_posix()
        lines += [f'## {label}', '',
                  f'{car["product"]} · {car["onebin"]} · Android {car["android"]} · {len(car["files"])} exact stock MD5s.', '',
                  f'**{len(mapping)}/{len(points)} mapped; {len(car["missing"])} missing; {len(reflected)}/{len(mapping)} reflection-verified on exact stock files.**', '',
                  f'Evidence: [{label}/evidence.json](../{label}/evidence.json).', '']
        for event in evidence['reflection']:
            lines += [f'- {event["date"]}: owner-reported on-car reflection passed {len(event["points"])}/{len(event["points"])} points in that historical snapshot.']
        lines += ['']
        for feature in evidence['physical_features']:
            lines += [f'- {feature["feature"]}, {feature["version"]}: **{feature["result"]}** — {feature["observation"]}']
        lines += ['', 'The new catalogue additions require on-car reflection; existing module requirements are unchanged.', '',
                  '| Point | Kind | Mapped class/member or missing reason | Exact-stock reflection | Required by |',
                  '| --- | --- | --- | --- | --- |']
        for point, rule in sorted(points.items()):
            entry = mapping.get(point)
            if entry is None:
                name = 'Missing: ' + car['missing'][point]
            else:
                owner = mapping.get(rule.get('owner'), {}).get('class', '')
                name = entry.get('class') or owner + '.' + (entry.get('method') or entry.get('field') or '<init>')
            modules = ', '.join(module for module, ids in required.items() if point in ids) or '—'
            lines += [f'| {point} | {rule["type"]} | {name.replace("|", "&#124;")} | {"yes" if point in reflected else "not recorded"} | {modules} |']
        lines += ['']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['validate', 'generate', 'check'])
    parser.add_argument('--stock', type=Path, help='optional pulled /system tree; validate every stock MD5')
    args = parser.parse_args()
    document = generate()
    if args.stock:
        for path in (ROOT / 'maps').glob('*/*/*/*/car.json'):
            validate(path.parent, args.stock)
    target = ROOT / 'docs/hookpoints.md'
    if args.command == 'generate':
        target.write_text(document)
    elif args.command == 'check' and (not target.exists() or target.read_text() != document):
        raise ValueError('docs/hookpoints.md is stale; run evidence tool generate')
    print('map evidence and catalogue coverage ' + args.command + ' passed')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        print('map-evidence: ' + str(error), file=sys.stderr)
        sys.exit(1)
