#!/usr/bin/env python3
"""Validate ownership and emit literal line claims for the root graph."""
from fnmatch import fnmatchcase
import re
import sys
from pathlib import Path

# Mirrors the sg_tr_* validators in nemesis/package/lib/common.sh.
KMOD = re.compile(r'[a-z0-9][a-z0-9_]{0,54}')
DAEMON = re.compile(r'[a-z0-9][a-z0-9_-]{0,31}')
IFACE_GLOB = re.compile(r'[a-z0-9][a-z0-9_.*-]{0,14}')
TOKEN = re.compile(r'[a-zA-Z0-9_./:=,+@!-]+')
KO = re.compile(r'[a-zA-Z0-9_./-]+\.ko')
IPTABLES_COMMAND = re.compile(
    r'-[ACDEFILNPRSVXZht].*|--(?:append|check|delete|insert|replace|list|flush|zero|new-chain|policy|'
    r'rename-chain|table|help|version|modprobe).*')


def words(value, limit):
    if not value or len(value) > 200 or any(c in value for c in '*?[\t\n'):
        return None
    split = value.split()
    return split if len(split) <= limit else None


def ko_ok(value):
    return bool(KO.fullmatch(value)) and not value.startswith('/') and '..' not in value and '//' not in value


def params_ok(value):
    split = words(value, 16)
    return split is not None and all(
        re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_]*=[a-zA-Z0-9_.,:+-]+', token) for token in split)


def derived_ok(value):
    """derived_bin.<name>=: stock program, absolute path string in it, shorter-or-equal file name."""
    split = value.split(' ')
    return (len(value) <= 200 and len(split) == 3
            and bool(re.fullmatch(r'/system/x?bin/[a-zA-Z0-9_-][a-zA-Z0-9_.-]*', split[0]))
            and bool(re.fullmatch(r'/[a-zA-Z0-9_./-]{3,127}', split[1]))
            and '..' not in split[1] and '//' not in split[1]
            and bool(re.fullmatch(r'[a-zA-Z0-9_-][a-zA-Z0-9_.-]*', split[2])) and len(split[2]) <= len(split[1]))


def daemon_ok(value):
    split = words(value, 16)
    if not split:
        return False
    executable = split[0]
    if re.fullmatch(r'/system/x?bin/[a-zA-Z0-9_-][a-zA-Z0-9_.-]*', executable):
        pass
    elif executable.startswith('@payload@/'):
        rel = executable[len('@payload@/'):]
        if not re.fullmatch(r'[a-zA-Z0-9_./-]+', rel) or rel.startswith('/') or '..' in rel or '//' in rel:
            return False
    else:
        return False
    for token in split[1:]:
        if not TOKEN.fullmatch(token):
            return False
        if '@' in token and not re.fullmatch(r'[^@]*@(?:payload|state)@(?:/[^@]*)?', token):
            return False
    return True


def net_rule_ok(value):
    split = words(value, 32)
    if not split or any(not TOKEN.fullmatch(t) or '@' in t for t in split):
        return False
    if split[0] == 'iptables':
        rest = split[1:]
        if rest[:1] == ['-t']:
            if len(rest) < 2 or rest[1] not in ('nat', 'mangle', 'filter'):
                return False
            rest = rest[2:]
        if not rest or not re.fullmatch(r'[a-zA-Z0-9_][a-zA-Z0-9_-]*', rest[0]) or len(rest) < 2:
            return False
        return not any(IPTABLES_COMMAND.fullmatch(t) for t in rest[1:])
    if split[:2] == ['ip', 'rule']:
        rest = split[2:]
        return bool(rest) and not any(
            t in ('add', 'del', 'delete', 'flush', 'list', 'lst', 'show', 'save', 'restore', 'help') or t.startswith('-')
            for t in rest)
    return False


def transient(module, fields, owners):
    """Validate transient declarations and claim them across modules."""
    def csv(key, pattern):
        value = fields.get(key, '')
        items = value.split(',') if value else []
        if any(not pattern.fullmatch(item) for item in items) or len(items) != len(set(items)):
            raise ValueError(f'invalid {key}: {module}')
        return items
    kmods = csv('kmods', KMOD)
    daemons = csv('daemons', DAEMON)
    derived = csv('derived_bins', DAEMON)
    ifaces = csv('owns_ifaces', IFACE_GLOB)
    paths = set()
    for key, value in fields.items():
        if key.startswith('kmod.'):
            name, _, platform = key[5:].partition('.')
            if (name not in kmods or not ko_ok(value) or
                    (platform and not re.fullmatch(r'[a-z0-9_]+', platform)) or (key.count('.') > 2)):
                raise ValueError(f'invalid kernel module declaration: {module}:{key}')
            paths.add(name)
        elif key.startswith('kmod_params.'):
            if key[12:] not in kmods or not params_ok(value):
                raise ValueError(f'invalid kernel module parameters: {module}:{key}')
        elif key.startswith('daemon.'):
            if key[7:] not in daemons or not daemon_ok(value):
                raise ValueError(f'invalid daemon: {module}:{key}')
        elif key.startswith('daemon_user.'):
            if key[12:] not in daemons or value != 'wifi':
                raise ValueError(f'invalid daemon user: {module}:{key}')
        elif key.startswith('derived_bin.'):
            if key[12:] not in derived or not derived_ok(value):
                raise ValueError(f'invalid derived program: {module}:{key}')
        elif key.startswith('net_rules.'):
            if not re.fullmatch(r'[1-9][0-9]{0,3}', key[10:]) or not net_rule_ok(value):
                raise ValueError(f'invalid network rule: {module}:{key}')
    if (set(kmods) - paths or set(daemons) - {key[7:] for key in fields if key.startswith('daemon.')}
            or set(derived) - {key[12:] for key in fields if key.startswith('derived_bin.')}):
        raise ValueError(f'kernel module, daemon or derived program without a definition: {module}')
    claims = [('kernel module', name) for name in kmods]
    claims += [('daemon', value) for key, value in fields.items() if key.startswith('daemon.')]
    claims += [('network rule', value) for key, value in fields.items() if key.startswith('net_rules.')]
    for claim in claims:
        if claim in owners and owners[claim] != module or claims.count(claim) > 1:
            raise ValueError(f'{claim[0]} ownership conflict: {claim[1]}')
        owners[claim] = module
    for glob in ifaces:
        for (kind, other_glob), other in owners.items():
            if kind == 'interface' and other != module and (
                    glob == other_glob or fnmatchcase(glob, other_glob) or fnmatchcase(other_glob, glob)):
                raise ValueError(f'interface ownership conflict: {glob}')
        owners['interface', glob] = module


def generate(root, order, output):
    whole, lines, records, owners = {}, {}, [], {}
    for module in Path(order).read_text().splitlines():
        fields = {}
        claims = []
        # Preserve CR rather than letting text-mode newline conversion hide it.
        source = (Path(root) / 'modules' / module / 'module.properties').read_bytes().decode('utf-8')
        for raw in source.split('\n'):
            if raw.startswith('#') or '=' not in raw:
                continue
            key, value = raw.split('=', 1)
            if (key in ('owns_files', 'owns_props', 'reassert_props', 'owns_generated_dirs', 'kmods', 'daemons',
                        'derived_bins', 'owns_ifaces')
                    or key.startswith(('kmod.', 'kmod_params.', 'daemon.', 'daemon_user.', 'derived_bin.',
                                       'net_rules.'))) and key in fields:
                raise ValueError(f'duplicate ownership key: {module}:{key}')
            if key.startswith('owns_lines'):
                if not re.fullmatch(r'owns_lines\.[1-9][0-9]*', key) or key in fields:
                    raise ValueError(f'invalid or duplicate line key: {module}:{key}')
                path, sep, stock = value.partition(':')
                if not sep or any(ord(c) < 32 or ord(c) == 127 for c in stock):
                    raise ValueError(f'invalid stock line: {module}:{key}')
                claims.append((key.split('.')[1], path, stock))
            fields[key] = value
        transient(module, fields, owners)
        reassert = fields.get('reassert_props', '')
        if reassert:
            keys = reassert.split(',')
            owned = fields.get('owns_props', '').split(',')
            if (fields.get('restore') == 'reboot' or len(keys) != len(set(keys)) or
                    any(not re.fullmatch(r'[a-zA-Z0-9_.-]+', key) or key not in owned for key in keys)):
                raise ValueError(f'invalid reassert_props: {module}')
        generated = list(filter(None, fields.get('owns_generated_dirs', '').split(',')))
        if len(generated) != len(set(generated)) or fields.get('restore') == 'reboot' and generated or any(
                not re.fullmatch(r'/data/data/[A-Za-z0-9._]+/app_hmg-seogaemo-[A-Za-z0-9_-]+', path)
                for path in generated):
            raise ValueError(f'invalid owns_generated_dirs: {module}')
        for path in filter(None, fields.get('owns_files', '').split(',')):
            validate_path(path)
            if path in whole or any(p == path for p, _ in lines):
                raise ValueError(f'whole-file ownership conflict: {path}')
            whole[path] = module
        for number, path, stock in sorted(claims, key=lambda c: int(c[0])):
            # @onebin@ is expanded on the car at install (runtime contract, line ownership).
            validate_path(path.replace('@onebin@', 'onebin'))
            if path in whole:
                raise ValueError(f'whole-file ownership conflict: {path}')
            if (path, stock) in lines:
                raise ValueError(f'duplicate line ownership: {path}:{stock}')
            if fields.get('restore') == 'reboot':
                raise ValueError(f'reboot restore cannot own persistent targets: {module}')
            lines[path, stock] = module
            records.append(f'{module}\t{number}\t{path}:{stock}\n')
    Path(output).write_text(''.join(records))


def validate_path(path):
    if not re.fullmatch(r'/[A-Za-z0-9/._+\-]+', path) or '..' in path or '//' in path or path.endswith('/'):
        raise ValueError(f'invalid ownership path: {path}')


if __name__ == '__main__':
    try:
        generate(*sys.argv[1:])
    except ValueError as error:
        sys.exit(f'gen-modules: {error}')
