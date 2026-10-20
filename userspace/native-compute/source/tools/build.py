#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Verify and build this source kit offline; never execute the RPC client or DSP DSO."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import stat
import subprocess
import sys
import time

WORK = KIT = BEFORE = None
START, COMMANDS = time.monotonic(), []
ENV = {}
ORIGINS = {'qaic': ('https://github.com/qualcomm/QAIC', 'a66a0019fb488abae955bbc9b3a9de3dc15962d0'),
           'fastrpc': ('https://github.com/qualcomm/fastrpc', 'a56e9d4de3614a8d8f4b0e15ff561350c4b686e3')}


def need(value, message):
    if not value:
        raise ValueError(message)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read(path, maximum=16 << 20):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 <= before.st_size <= maximum,
             'bounded unshared regular file: ' + str(path))
        raw = stream.read(maximum + 1)
        need(len(raw) == before.st_size and identity(before) == identity(os.fstat(stream.fileno())),
             'input changed while reading: ' + str(path))
    return raw, {'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw), 'identity': identity(before)}


def decode(raw):
    def pairs(rows):
        result = {}
        for key, value in rows:
            need(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs)


def save(leaf, value):
    with (WORK / leaf).open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')


def tree(root):
    held = identity(root.lstat())
    result, total = {}, 0
    def walk_error(error):
        raise error
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        for leaf in sorted(dirs + files):
            path = Path(directory) / leaf
            key, info = path.relative_to(root).as_posix(), path.lstat()
            need(re.fullmatch('[A-Za-z0-9_.+/-]+', key) and '.git' not in path.relative_to(root).parts,
                 'safe source path with no Git metadata')
            if stat.S_ISDIR(info.st_mode):
                result[key] = {'type': 'directory', 'identity': identity(info)}
            else:
                raw, descriptor = read(path)
                result[key] = {'type': 'file', **descriptor}
                total += len(raw)
            need(len(result) <= 10000 and total <= 256 << 20, 'bounded complete source closure')
    need(identity(root.lstat()) == held, 'source root changed during snapshot')
    return result


def verify_kit(snapshot):
    manifest_raw, manifest_pin = read(KIT / 'SOURCE-MANIFEST.json', 8 << 20)
    manifest = decode(manifest_raw)
    need(manifest.get('schema') == 'sp11-native-compute-source-manifest-v1' and
         manifest.get('excluded') == ['SOURCE-MANIFEST.json', 'SHA256SUMS'] and
         isinstance(manifest.get('files'), list), 'source manifest schema/exclusions')
    expected, directories = {}, set()
    for row in manifest['files']:
        need(isinstance(row, dict) and set(row) == {'path', 'bytes', 'sha256', 'mode'}, 'manifest file fields')
        key = row['path']
        need(isinstance(key, str) and re.fullmatch('[A-Za-z0-9_.+/-]+', key) and
             not key.startswith('/') and PurePosixPath(key).as_posix() == key and
             all(part not in ('', '.', '..', '.git') for part in key.split('/')) and
             key not in ('SOURCE-MANIFEST.json', 'SHA256SUMS') and key not in expected,
             'safe unique manifest relative path')
        need(type(row['bytes']) is int and 0 <= row['bytes'] <= 16 << 20 and
             type(row['mode']) is int and row['mode'] in (0o644, 0o755) and
             isinstance(row['sha256'], str) and re.fullmatch('[0-9a-f]{64}', row['sha256']),
             'bounded manifest file hash/size/mode')
        expected[key] = row
        directories.update(p.as_posix() for p in PurePosixPath(key).parents if p.as_posix() != '.')
    need(list(expected) == sorted(expected), 'canonical manifest file order')
    need({key for key, row in snapshot.items() if row['type'] == 'file'} ==
         set(expected) | {'SOURCE-MANIFEST.json', 'SHA256SUMS'} and
         {key for key, row in snapshot.items() if row['type'] == 'directory'} == directories,
         'closed source manifest file/directory roster')
    for key, row in expected.items():
        actual = snapshot[key]
        need(actual['sha256'] == row['sha256'] and actual['bytes'] == row['bytes'] and
             stat.S_IMODE(actual['identity'][2]) == row['mode'], 'manifest material/mode: ' + key)
    need(all(stat.S_IMODE(snapshot[key]['identity'][2]) == 0o644 for key in
             ('SOURCE-MANIFEST.json', 'SHA256SUMS')), 'manifest and checksum file modes')
    need(all(key in expected for key in ('tools/build.py', 'tools/build-cpu.py', 'tools/build-hexagon.py',
                                        'SOURCE-PROVENANCE.json')), 'all three helpers and provenance are manifest-bound')
    checks = {key: row['sha256'] for key, row in expected.items()}
    checks['SOURCE-MANIFEST.json'] = manifest_pin['sha256']
    checksum_raw, checksum_pin = read(KIT / 'SHA256SUMS', 2 << 20)
    need(checksum_raw == ''.join(checks[key] + '  ' + key + '\n' for key in sorted(checks)).encode('ascii'),
         'complete canonical SHA256SUMS including source manifest')
    provenance_raw, provenance_pin = read(KIT / 'SOURCE-PROVENANCE.json', 1 << 20)
    for key, pin in (('SOURCE-MANIFEST.json', manifest_pin), ('SHA256SUMS', checksum_pin),
                     ('SOURCE-PROVENANCE.json', provenance_pin)):
        need({k: v for k, v in snapshot[key].items() if k != 'type'} == pin,
             'verified metadata matches complete input snapshot: ' + key)
    provenance = decode(provenance_raw)
    need(provenance.get('schema') == 'sp11-native-compute-source-provenance-v1', 'source provenance schema')
    for project, (url, revision) in ORIGINS.items():
        need(provenance.get('origins', {}).get(project) ==
             {'prefix': 'upstream/' + project, 'url': url, 'revision': revision}, 'exact declared upstream source origin')
    own = read(Path(__file__).resolve(strict=True), 1 << 20)[1]
    need(own['sha256'] == expected['tools/build.py']['sha256'] and
         own['bytes'] == expected['tools/build.py']['bytes'], 'executed orchestrator matches the verified kit')
    return {'manifest': manifest_pin, 'checksums': checksum_pin, 'provenance': provenance_pin,
            'executedBuilder': own, 'files': len(checks) + 1, 'directories': len(directories)}


def guard():
    need(time.monotonic() - START < 1800 and shutil.disk_usage(WORK).free >= 128 << 20,
         'whole orchestration1800s/free128MiB floor')
    total = 0
    for directory, dirs, files in os.walk(WORK, followlinks=False):
        dirs[:] = [leaf for leaf in dirs if not (Path(directory) / leaf).is_symlink()]
        for leaf in files:
            try:
                info = (Path(directory) / leaf).lstat()
            except FileNotFoundError:
                continue
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
    need(total <= 1280 << 20, 'sampled1280MiB whole-output bound, not a quota')


def run(label, argv, maximum):
    guard()
    row = {'label': label, 'argv': [str(value) for value in argv], 'cwd': str(WORK),
           'environment': dict(ENV), 'maximumSeconds': maximum, 'exit': None,
           'failure': None, 'cleanupErrors': [], 'captureErrors': []}
    COMMANDS.append(row)
    stdout, stderr = WORK / (label + '.stdout'), WORK / (label + '.stderr')
    child, primary = None, None
    try:
        with stdout.open('xb') as so, stderr.open('xb') as se:
            child = subprocess.Popen(row['argv'], cwd=WORK, env=ENV, stdin=subprocess.DEVNULL,
                                     stdout=so, stderr=se, start_new_session=True)
            deadline = min(START + 1800, time.monotonic() + maximum)
            while child.poll() is None:
                guard()
                need(time.monotonic() < deadline and os.fstat(so.fileno()).st_size <= 16 << 20 and
                     os.fstat(se.fileno()).st_size <= 16 << 20,
                     'helper deadline/captured-stream bound: ' + label)
                time.sleep(0.2)
            need(child.returncode == 0, 'helper nonzero: ' + label)
    except BaseException as error:
        primary = error
        row['failure'] = repr(error)
    finally:
        if child is not None and child.poll() is None:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(child.pid, sig)
                except ProcessLookupError:
                    pass
                except BaseException as error:
                    row['cleanupErrors'].append(repr(error))
                try:
                    child.wait(timeout=5)
                    break
                except subprocess.TimeoutExpired:
                    continue
                except BaseException as error:
                    row['cleanupErrors'].append(repr(error))
            if child.poll() is None:
                row['cleanupErrors'].append('owned helper child unreaped')
        row['exit'] = None if child is None else child.returncode
        row['streams'] = {}
        for suffix, path in (('stdout', stdout), ('stderr', stderr)):
            try:
                row['streams'][suffix] = read(path)[1]
            except BaseException as error:
                row['streams'][suffix] = None
                row['captureErrors'].append(suffix + ': ' + repr(error))
        save('command-%02d.json' % len(COMMANDS), row)
    if primary is not None:
        raise primary
    need(not row['cleanupErrors'] and not row['captureErrors'], 'helper capture/cleanup errors')


def after_snapshot():
    after = tree(KIT)
    save('INPUT-AFTER.json', {'kit': after})
    differences = [{'path': key, 'before': BEFORE.get(key), 'after': after.get(key)}
                   for key in sorted(set(BEFORE) | set(after)) if BEFORE.get(key) != after.get(key)]
    save('INPUT-DIFF.json', differences)
    need(BEFORE == after, 'complete kit input identities unchanged')
    verify_kit(after)


def main():
    global KIT, WORK, BEFORE, ENV
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kit', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--isa', required=True, choices=['v73'])
    args = parser.parse_args()
    os.umask(0o077)
    need(os.geteuid() != 0 and os.uname().sysname == 'Linux' and os.uname().machine == 'aarch64',
         'native Linux ARM64 nonroot user required')
    KIT, output = args.kit, args.output
    need(KIT.is_absolute() and KIT.resolve(strict=True) == KIT and KIT.is_dir() and
         output.is_absolute() and output.parent.resolve(strict=True) == output.parent and
         output.name not in ('', '.', '..') and output.resolve(strict=False) == output and
         not any(c.isspace() or c in '\\:' for c in str(KIT) + str(output)), 'canonical plain absolute paths')
    need(not output.is_relative_to(KIT) and not KIT.is_relative_to(output), 'output outside and disjoint from kit')
    if not output.exists():
        output.mkdir(mode=0o700)
    info = output.lstat()
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700 and
         output.resolve(strict=True) == output and not any(output.iterdir()) and
         shutil.disk_usage(output).free >= 2 << 30, 'new owned0700 empty output and initial2GiB floor')
    WORK = output
    BEFORE = tree(KIT)
    save('INPUT-BEFORE.json', {'kit': BEFORE})
    kit_verified = verify_kit(BEFORE)
    python = Path(sys.executable).resolve(strict=True)
    python_pin = read(python, 256 << 20)[1]
    ENV = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'TZ': 'UTC',
           'PYTHONDONTWRITEBYTECODE': '1', 'HOME': str(WORK / 'home'), 'TMPDIR': str(WORK / 'tmp')}
    for leaf in ('home', 'tmp'):
        (WORK / leaf).mkdir(mode=0o700)
    cpu, hexagon = WORK / 'cpu', WORK / 'hexagon'
    need(not cpu.exists() and not hexagon.exists(), 'both helper output directories must be new')
    run('cpu', [python, '-I', '-B', KIT / 'tools/build-cpu.py', '--kit', KIT, '--output', cpu], 1260)
    cpu_raw, cpu_pin = read(cpu / 'RESULT.json')
    cpu_result = decode(cpu_raw)
    need(cpu_result['schema'] == 'sp11-r83-native-compute-cpu-build-v1' and
         cpu_result['status'] == 'cpu-build-and-pure-units-passed-diagnostics-await-root' and
         cpu_result['rpcClientExecuted'] is False and cpu_result['dspArtifactCompiled'] is False,
         'actual completed CPU build and pure/mock units, not live RPC execution')
    need(cpu_result['sourceManifest']['sha256'] == kit_verified['manifest']['sha256'] and
         cpu_result['sourceProvenance']['sha256'] == kit_verified['provenance']['sha256'], 'CPU used this verified kit')
    run('hexagon', [python, '-I', '-B', KIT / 'tools/build-hexagon.py', '--kit', KIT,
        '--cpu-output', cpu, '--output', hexagon, '--cpu-result-sha256', cpu_pin['sha256'], '--isa', args.isa], 360)
    hex_raw, hex_pin = read(hexagon / 'RESULT.json')
    hex_result = decode(hex_raw)
    need(hex_result['schema'] == 'sp11-r83-hexagon-analysis-v1' and
         hex_result['status'] == 'analysis-completed-runtime-unqualified' and
         hex_result['cpuResultSHA256'] == cpu_pin['sha256'] and hex_result['isaArgument'] == args.isa and
         hex_result['executedArtifact'] is False and hex_result['deployable'] is False and
         hex_result['runtimeClosure'] == 'unproved', 'actual unexecuted runtime-unqualified Hexagon analysis')
    need(read(cpu / 'RESULT.json')[1] == cpu_pin, 'CPU receipt unchanged across Hexagon build')
    after_snapshot()
    guard()
    save('RESULT.json', {'schema': 'sp11-r83-native-compute-build-v1',
        'status': 'cpu-and-hexagon-analysis-passed-diagnostics-await-root', 'commands': COMMANDS,
        'sourceKit': kit_verified, 'python': {'path': str(python), **python_pin},
        'inputBefore': read(WORK / 'INPUT-BEFORE.json')[1], 'inputAfter': read(WORK / 'INPUT-AFTER.json')[1],
        'cpuResult': cpu_pin, 'hexagonResult': hex_pin, 'isaArgument': args.isa,
        'hardwareExecuted': False, 'rpcClientExecuted': False, 'dspArtifactExecuted': False,
        'deployable': False, 'runtimeClosure': 'unproved', 'seconds': time.monotonic() - START,
        'scope': 'Verified complete source kit; actual CPU helper build/pure/mock checks, then actual Hexagon compile/link and ELF profile inventory. No SDK-linked RPC client or DSP artifact is executed. No installation, daemon, device query or network command is added.',
        'limits': 'Manifest/checksum consistency is not a signature or authenticated source provenance. All raw helper diagnostics still need review. Deadlines and output bounds are sampled/cooperative, not hard real-time or filesystem quotas. Helper termination targets its exact owned process group; nested helper child sessions have their own cleanup and this wrapper alone does not prove every descendant reaped. An isolated container controller remains the final process/isolation boundary. Successful builds do not prove physical ISA, QuRT loader ABI or hardware parity.'})


if __name__ == '__main__':
    try:
        main()
    except BaseException as error:
        try:
            if WORK is not None and not (WORK / 'FAILURE.json').exists():
                snapshot_error = None
                if BEFORE is not None and not (WORK / 'INPUT-AFTER.json').exists():
                    try:
                        after_snapshot()
                    except BaseException as secondary:
                        snapshot_error = repr(secondary)
                save('FAILURE.json', {'schema': 'sp11-r83-native-compute-build-failure-v1', 'status': 'failed',
                    'failure': repr(error), 'commands': COMMANDS, 'inputEvidenceError': snapshot_error,
                    'hardwareExecuted': False, 'deployable': False, 'seconds': time.monotonic() - START,
                    'scope': 'Failure preserved; no pass inferred from partial CPU or Hexagon outputs.'})
        except BaseException as receipt_error:
            raise error from receipt_error
        raise
