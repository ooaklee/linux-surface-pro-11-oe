#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Build offline on Linux ARM64; never run live RPC or DSP payloads."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import stat
import struct
import subprocess
import time

WORK = None
KIT = None
BEFORE = None
START = time.monotonic()
COMMANDS = []
NATIVE_PINS = {
    'patches/0001-mainline-capability-call-local.patch': '27d437a1cc79cbb1b6a8b8b5ae4f82fc96f1cb7cc2cd18107c3d157345a9d829',
    'idl/sp11_native_compute_v1.idl': '6502900689957c4730c79195f7975cbf62504345b74f7584900ec8d9099dc585',
    'dsp/compute.c': '1cbb5b9985a71330aa7f089f0e6a7b9c2248f87cdcbf903cf5cd590d3d112177',
    'tests/compute-unit.c': '70ed186bd10d2eabc88d70dd9f6d878c3748cbe7e2f5cdf6a1c3a6d479d18add',
    'tests/uapi-layout.c': 'f06d26db64e29d168a7d2a9dd569f5d39503de1add783480fb03fcc0c9ec6353',
    'host/compute-client.c': '754572e4b95da22ff6505b247a8912721b542e8537d0545a82c392acc393e50a',
    'include/sp11_compute_cli.h': '6cf02d23388777d52a921684e4140b60c3b91c2b855716e97e4767ab541c5381',
    'host/compute-launcher.c': 'ff03cef59a0935cd429b060d7f301f8ef0126654660918262f62ffce7969f984',
    'tests/launcher-worker-mock.c': '6b34f0303364db81ed268474c5dadc8cc3095b60544d2316b975952a119d7d9b',
    'tests/launcher-unit.py': '27ee36489834027139485cf52ead2de9a44b6fd439fcbe69e33e97f2b7006846',
    'tests/client-control-unit.c': 'acd54bc001d370abe65bf1c14dda9486596f2a6927a16a3c8101dcf25802205f',
    'include/sp11_compute_limits.h': 'f69ca180d3013772cf2cf8f8fb80d2e2ffc03c466691f1f6c1e7b1b145aa9653',
    'include/sp11_compute_checked.h': '1e18adecb5afdb5c356918aa7c55c04e93d0bcb272ccef3db04e0ea473fbaf18',
    'host/compute-checked.c': 'd234e5e48d0f36739c5a6e7e91283c1c0679d7804237e1ea172bd05c5a0d2c4d',
    'tests/compute-checked-unit.c': '754cb38b4a965dea7d79a14c5762510a3f4c11755f9be13378024c3ef32d4f24',
    'tests/compute-ap-wire-unit.c': '01f1d226e32e30697f0fcdf8175fde21b4e30a8a4983d386274e9841446a30ab',
}
ENV = {}


def need(value, message):
    if not value:
        raise ValueError(message)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read(path, maximum=64 << 20):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and
             0 <= before.st_size <= maximum, 'bounded regular file: ' + str(path))
        data = stream.read(maximum + 1)
        need(identity(before) == identity(os.fstat(stream.fileno())) and
             len(data) == before.st_size, 'changed read: ' + str(path))
    return data, identity(before)


def pin(path, maximum=64 << 20):
    data, held = read(path, maximum)
    return {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data), 'identity': held}


def tree(root):
    root_info = root.lstat()
    need(root.resolve(strict=True) == root and stat.S_ISDIR(root_info.st_mode),
         'canonical input tree')
    result, total = {}, 0
    def walk_error(error):
        raise error
    for current, directories, files in os.walk(root, followlinks=False, onerror=walk_error):
        for leaf in sorted(directories + files):
            path = Path(current) / leaf
            info = path.lstat()
            key = path.relative_to(root).as_posix()
            need('.git' not in path.relative_to(root).parts and
                 not stat.S_ISLNK(info.st_mode), 'no Git metadata or input links: ' + str(path))
            if stat.S_ISDIR(info.st_mode):
                result[key] = {'type': 'directory', 'identity': identity(info)}
            else:
                result[key] = {'type': 'file', **pin(path, 16 << 20)}
                total += info.st_size
            need(len(result) <= 10000 and total <= 256 << 20, 'bounded source closure')
    need(identity(root_info) == identity(root.lstat()), 'input root changed during snapshot')
    return result


def source_manifest(snapshot):
    raw, _ = read(KIT / 'SOURCE-MANIFEST.json', 8 << 20)
    manifest = json.loads(raw)
    need(manifest.get('schema') == 'sp11-native-compute-source-manifest-v1' and
         manifest.get('excluded') == ['SOURCE-MANIFEST.json', 'SHA256SUMS'] and
         isinstance(manifest.get('files'), list), 'source manifest schema/exclusions')
    expected, directories = {}, set()
    for row in manifest['files']:
        need(isinstance(row, dict) and set(row) == {'path', 'bytes', 'sha256', 'mode'},
             'source manifest file fields')
        key = row['path']
        need(isinstance(key, str) and key and not any(c.isspace() for c in key) and
             '\x00' not in key and not key.startswith('/') and
             PurePosixPath(key).as_posix() == key and
             all(part not in ('', '.', '..', '.git') for part in key.split('/')) and
             key not in ('SOURCE-MANIFEST.json', 'SHA256SUMS') and key not in expected,
             'safe unique manifest path')
        need(type(row['bytes']) is int and 0 <= row['bytes'] <= 16 << 20 and
             type(row['mode']) is int and 0 <= row['mode'] <= 0o777 and
             isinstance(row['sha256'], str) and re.fullmatch('[0-9a-f]{64}', row['sha256']),
             'bounded manifest file descriptor')
        expected[key] = row
        directories.update(p.as_posix() for p in PurePosixPath(key).parents if p.as_posix() != '.')
    actual_files = {key for key, row in snapshot.items() if row['type'] == 'file'}
    actual_dirs = {key for key, row in snapshot.items() if row['type'] == 'directory'}
    need(actual_files == set(expected) | {'SOURCE-MANIFEST.json', 'SHA256SUMS'} and
         actual_dirs == directories, 'complete manifest file/directory roster')
    for key, row in expected.items():
        actual = snapshot[key]
        need(actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256'] and
             stat.S_IMODE(actual['identity'][2]) == row['mode'], 'manifest content/mode: ' + key)
    return manifest


def capture_after():
    try:
        after = {'kit': tree(KIT)}
    except BaseException as error:
        after = {'captureError': repr(error)}
        save('INPUT-AFTER.json', after)
        save('INPUT-DIFF.json', [{'captureError': repr(error)}])
        raise
    save('INPUT-AFTER.json', after)
    changes = [{'path': key, 'before': BEFORE['kit'].get(key), 'after': after['kit'].get(key)}
               for key in sorted(set(BEFORE['kit']) | set(after['kit']))
               if BEFORE['kit'].get(key) != after['kit'].get(key)]
    save('INPUT-DIFF.json', changes)
    need(BEFORE == after, 'all read-only kit inputs unchanged')
    source_manifest(after['kit'])
    return after


def save(leaf, value):
    with (WORK / leaf).open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')


def guard():
    need(time.monotonic() - START < 1200 and shutil.disk_usage(WORK).free >= 512 << 20,
         'whole-worker deadline/free-space floor')
    total = 0
    for current, directories, files in os.walk(WORK, followlinks=False):
        directories[:] = [leaf for leaf in directories if not (Path(current) / leaf).is_symlink()]
        for leaf in files:
            try:
                info = (Path(current) / leaf).lstat()
            except FileNotFoundError:
                continue  # Compiler-owned temporary names may retire between samples.
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
    need(total <= 1 << 30, 'sampled1GiB output bound, not a quota')


def run(label, argv, timeout=30, cwd=None, environment=None):
    guard()
    if cwd is None:
        cwd = WORK
    env = dict(ENV if environment is None else environment)
    row = {'label': label, 'argv': [str(item) for item in argv], 'cwd': str(cwd),
           'environment': env, 'timeoutSeconds': timeout, 'exit': None,
           'failure': None, 'cleanupErrors': [], 'captureErrors': []}
    COMMANDS.append(row)
    stdout, stderr = WORK / 'logs' / (label + '.stdout'), WORK / 'logs' / (label + '.stderr')
    child, primary = None, None
    try:
        with stdout.open('xb') as so, stderr.open('xb') as se:
            child = subprocess.Popen(row['argv'], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                     stdout=so, stderr=se, start_new_session=True)
            deadline = min(START + 1200, time.monotonic() + timeout)
            while child.poll() is None:
                guard()
                need(time.monotonic() < deadline and
                     os.fstat(so.fileno()).st_size + os.fstat(se.fileno()).st_size <= 16 << 20,
                     'command deadline/log bound: ' + label)
                time.sleep(0.25)
            need(child.returncode == 0, 'command nonzero: ' + label)
    except BaseException as error:
        primary = error
        row['failure'] = repr(error)
    finally:
        if child is not None and child.poll() is None:
            for sig, seconds in ((signal.SIGTERM, 5), (signal.SIGKILL, 5)):
                try:
                    os.killpg(child.pid, sig)
                except ProcessLookupError:
                    pass
                except BaseException as error:
                    row['cleanupErrors'].append(repr(error))
                try:
                    child.wait(timeout=seconds)
                    break
                except subprocess.TimeoutExpired:
                    continue
                except BaseException as error:
                    row['cleanupErrors'].append(repr(error))
            if child.poll() is None:
                row['cleanupErrors'].append('owned child unreaped')
        row['exit'] = None if child is None else child.returncode
        row['streams'] = {}
        for suffix, path in (('stdout', stdout), ('stderr', stderr)):
            try:
                row['streams'][suffix] = pin(path, 16 << 20)
            except BaseException as error:
                row['streams'][suffix] = None
                row['captureErrors'].append(suffix + ': ' + repr(error))
        try:
            save('command-%02d.json' % len(COMMANDS), row)
        except BaseException as receipt_error:
            if primary is not None:
                raise primary from receipt_error
            raise
    if primary is not None:
        raise primary
    need(not row['cleanupErrors'] and not row['captureErrors'], 'command capture/cleanup failure')
    return read(stdout, 16 << 20)[0], read(stderr, 16 << 20)[0]


def elf(path, allowed):
    data, _ = read(path)
    need(len(data) >= 64 and data[:7] == b'\x7fELF\x02\x01\x01' and
         struct.unpack_from('<H', data, 18)[0] == 183 and
         struct.unpack_from('<H', data, 16)[0] in allowed, 'native AArch64 ELF: ' + str(path))
    return pin(path)


def main():
    global WORK, KIT, BEFORE, ENV
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kit', required=True, type=Path, help='canonical source-kit root')
    parser.add_argument('--output', required=True, type=Path, help='absent or empty owned output directory')
    args = parser.parse_args()
    os.umask(0o077)
    need(os.geteuid() != 0 and os.uname().sysname == 'Linux' and os.uname().machine == 'aarch64',
         'native Linux ARM64 nonroot required')
    KIT = args.kit
    output = args.output
    need(KIT.is_absolute() and KIT.resolve(strict=True) == KIT and
         output.is_absolute() and output.parent.resolve(strict=True) == output.parent and
         output.name not in ('', '.', '..') and
         not any(c.isspace() for c in str(KIT) + str(output)),
         'absolute canonical paths without whitespace (upstream Make limitation)')
    need(KIT != output and KIT not in output.parents and output not in KIT.parents,
         'output must be outside and disjoint from the source kit')
    if not output.exists():
        output.mkdir(mode=0o700)
    info = output.lstat()
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and
         stat.S_IMODE(info.st_mode) == 0o700 and output.resolve(strict=True) == output and
         not any(output.iterdir()) and shutil.disk_usage(output).free >= 2 << 30,
         'fresh owned0700 output and initial2GiB gate')
    WORK = output
    ENV = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'TZ': 'UTC',
           'HOME': str(WORK / 'home'), 'TMPDIR': str(WORK / 'tmp'),
           'PYTHONDONTWRITEBYTECODE': '1', 'CABAL_DIR': str(WORK / 'cabal'),
           'CABAL_CONFIG': str(WORK / 'cabal/config'), 'GHC_ENVIRONMENT': '-',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': str(WORK / 'empty-git-config'),
           'GIT_CEILING_DIRECTORIES': str(WORK)}
    for leaf in ('logs', 'evidence', 'home', 'tmp', 'cabal', 'bin', 'generated', 'fastrpc-build'):
        (WORK / leaf).mkdir(mode=0o700)
    save('NATIVE-UNAME.json', dict(zip(('sysname', 'nodename', 'release', 'version', 'machine'), os.uname())))
    (WORK / 'empty-git-config').write_bytes(b'')
    (WORK / 'cabal/config').write_text('active-repositories: :none\n' + ''.join(
        name + ': ' + str(WORK / 'cabal' / leaf) + '\n' for name, leaf in
        (('remote-repo-cache', 'packages'), ('store-dir', 'store'), ('logs-dir', 'logs'), ('world-file', 'world'))))
    BEFORE = {'kit': tree(KIT)}
    save('INPUT-BEFORE.json', BEFORE)
    source_manifest(BEFORE['kit'])
    executed_builder = pin(Path(__file__).resolve(strict=True), 1 << 20)
    need(executed_builder['sha256'] == BEFORE['kit']['tools/build-cpu.py']['sha256'] and
         executed_builder['bytes'] == BEFORE['kit']['tools/build-cpu.py']['bytes'],
         'executed builder must match the manifest-bound source')
    provenance = json.loads(read(KIT / 'SOURCE-PROVENANCE.json', 1 << 20)[0])
    origins = provenance.get('origins', {})
    for project in ('qaic', 'fastrpc'):
        origin = origins.get(project, {})
        need(origin.get('prefix') == 'upstream/' + project and
             isinstance(origin.get('revision'), str) and re.fullmatch('[0-9a-f]{40}', origin['revision']) and
             isinstance(origin.get('url'), str) and origin['url'].startswith('https://') and
             not any(c.isspace() for c in origin['url']), 'declared upstream source provenance')
    for leaf, expected in NATIVE_PINS.items():
        need(pin(KIT / 'native' / leaf)['sha256'] == expected, 'reviewed native source pin: ' + leaf)
    for project in ('qaic', 'fastrpc'):
        shutil.copytree(KIT / 'upstream' / project, WORK / project, symlinks=False)
    shutil.copytree(KIT / 'native', WORK / 'native-source', symlinks=False)
    tools = {}
    for label, argv in [('ghc', ['/usr/bin/ghc', '--numeric-version']),
                        ('cabal', ['/usr/bin/cabal', '--numeric-version']),
                        ('ghc-packages', ['/usr/bin/ghc-pkg', 'list']),
                        ('clang', ['/usr/bin/clang-19', '--version'])]:
        tools[label] = run('tool-' + label, argv)[0].decode()
    packages = None
    package_tool = shutil.which('dpkg-query', path=ENV['PATH'])
    if package_tool:
        data, _ = run('tool-packages', [package_tool, '-W', '-f=${binary:Package}\t${Version}\t${Architecture}\n'])
        (WORK / 'evidence/packages.tsv').write_bytes(data)
        packages = pin(WORK / 'evidence/packages.tsv')
    for name in ('ghc', 'cabal'):
        need(re.fullmatch('[0-9.]+', tools[name].strip()), 'numeric tool version for source metadata')
    version_path = WORK / 'qaic/src/Compiler/Version.hs'
    version_raw = read(version_path, 1 << 20)[0]
    need(not re.search(rb'(?m)^\s*(gitcommit|ghcVersion|cabalVersion|platform)\s*(::|=)', version_raw),
         'unmodified upstream version metadata before fresh-copy preparation')
    version_fields = {'gitcommit': 'source-export:' + origins['qaic']['revision'],
                      'ghcVersion': tools['ghc'].strip(), 'cabalVersion': tools['cabal'].strip(),
                      'platform': os.uname().sysname + ' ' + os.uname().machine}
    with version_path.open('ab') as stream:
        for name, value in version_fields.items():
            stream.write(('\n' + name + ' :: String\n' + name + ' = ' + json.dumps(value) + '\n').encode())
    # All four Makefile grep guards now find definitions; no Git query or fake HEAD is needed.
    save('SOURCE-BUILD-METADATA.json', {'upstreamOrigins': origins, 'versionFields': version_fields,
        'sourceManifest': pin(KIT / 'SOURCE-MANIFEST.json', 8 << 20),
        'sourceProvenance': pin(KIT / 'SOURCE-PROVENANCE.json', 1 << 20)})
    run('qaic-build', ['/usr/bin/make', '-j1', 'TARGET_ARCH=aarch64-linux'], 600, WORK / 'qaic/src')
    qaic = WORK / 'qaic/src/Linux_ReleaseG/ship/qaic'
    artifacts = {'qaic': elf(qaic, (2, 3))}
    run('qaic-version', [qaic, '--version'])
    patch = WORK / 'native-source/patches/0001-mainline-capability-call-local.patch'
    run('fastrpc-patch', ['/usr/bin/patch', '--batch', '--forward', '-p1', '-i', patch], cwd=WORK / 'fastrpc')
    run('fastrpc-autogen', ['/bin/sh', 'autogen.sh'], 90, WORK / 'fastrpc')
    compile_env = dict(ENV, CC='/usr/bin/clang-19', CXX='/usr/bin/clang++-19')
    run('fastrpc-configure', [WORK / 'fastrpc/configure', '--prefix=' + str(WORK / 'never-installed'),
        '--enable-stricter', '--with-config-base-dir=' + str(WORK / 'no-runtime-config')], 90,
        WORK / 'fastrpc-build', compile_env)
    run('libcdsprpc-build', ['/usr/bin/make', '-C', WORK / 'fastrpc-build/src', '-j2', 'V=1', 'libcdsprpc.la'],
        180, environment=compile_env)
    la = WORK / 'fastrpc-build/src/libcdsprpc.la'
    matches = re.findall(r"^dlname='(libcdsprpc\.so\.[0-9.]+)'$", read(la)[0].decode(), re.M)
    need(len(matches) == 1, 'one actual libcdsprpc SONAME from libtool')
    library = (la.parent / '.libs' / matches[0]).resolve(strict=True)
    need(library.parent == la.parent / '.libs', 'fresh shared library confinement')
    artifacts['libcdsprpc'] = elf(library, (3,))
    run('libcdsprpc-elf', ['/usr/bin/readelf', '-hWd', library])
    run('qaic-generate', [qaic, '-st', '-I', WORK / 'fastrpc/idl', '-I', WORK / 'qaic/inc',
        '-o', WORK / 'generated', WORK / 'native-source/idl/sp11_native_compute_v1.idl'])
    generated = {'sp11_native_compute_v1.h', 'sp11_native_compute_v1_stub.c', 'sp11_native_compute_v1_skel.c'}
    need({p.name for p in (WORK / 'generated').iterdir()} == generated, 'actual exact three generated outputs')
    generation = {leaf: pin(WORK / 'generated' / leaf) for leaf in sorted(generated)}
    flags = ['/usr/bin/clang-19', '-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-pedantic',
             '-I' + str(WORK / 'generated'), '-I' + str(WORK / 'fastrpc/inc'),
             '-I' + str(WORK / 'native-source/include')]
    layout = WORK / 'bin/uapi-layout'
    run('uapi-layout-compile', flags + ['-DLEXR_KERNEL_FASTRPC_UAPI_HEADER="' + str(KIT / 'interfaces/linux/fastrpc.h') + '"',
        WORK / 'native-source/tests/uapi-layout.c', '-o', layout])
    artifacts['uapi-layout'] = elf(layout, (2, 3))
    so, se = run('uapi-layout-unit', [layout])
    need(so == se == b'', 'pure layout unit must be silent')
    unit = WORK / 'bin/compute-unit'
    run('compute-unit-compile', flags + [WORK / 'native-source/tests/compute-unit.c',
        WORK / 'native-source/dsp/compute.c', '-o', unit])
    artifacts['compute-unit'] = elf(unit, (2, 3))
    so, se = run('compute-unit', [unit])
    need(so == b'compute-unit: 60 checks passed (pure implementation only)\n' and se == b'',
         'actual pure implementation unit oracle')
    checked = WORK / 'bin/compute-checked-unit'
    run('checked-api-unit-compile', flags + [WORK / 'native-source/tests/compute-checked-unit.c',
        WORK / 'native-source/host/compute-checked.c', '-o', checked])
    artifacts['checked-api-unit'] = elf(checked, (2, 3))
    so, se = run('checked-api-unit', [checked])
    need(so == b'checked-api-unit: 266 checks passed (LOCAL VALIDATION ONLY; no SDK/stub/remote execution)\n'
         and se == b'', 'actual local checked-API rejection/forwarding oracle')
    stub = WORK / 'bin/sp11_native_compute_v1_stub.o'
    # The pinned QAIC/FARF generator intentionally uses GNU comma-elision.
    # Compile that third-party generated TU in its actual dialect. Keep all
    # normal warnings fatal; authored C and units retain strict C11/pedantic.
    stub_flags = [flag for flag in flags if flag not in ('-std=c11', '-pedantic')]
    run('ap-stub-compile', stub_flags + ['-std=gnu11', '-fPIC', '-c',
        WORK / 'generated/sp11_native_compute_v1_stub.c', '-o', stub])
    artifacts['ap-stub'] = elf(stub, (1,))
    wire = WORK / 'bin/compute-ap-wire-unit'
    # Execute the genuine generated AP stub only with explicit local transport
    # and logging mocks. Neither libcdsprpc nor the DSP implementation is linked.
    run('ap-wire-unit-link', flags + [WORK / 'native-source/tests/compute-ap-wire-unit.c',
        WORK / 'native-source/host/compute-checked.c', stub, '-Wl,--no-undefined', '-o', wire])
    artifacts['ap-wire-unit'] = elf(wire, (2, 3))
    so, se = run('ap-wire-elf', ['/usr/bin/readelf', '-hWd', '--dyn-syms', wire])
    needed = re.findall(rb'\(NEEDED\).*Shared library: \[([^\]]+)\]', so)
    need(needed == [b'libc.so.6'] and se == b'', 'wire fixture has only libc, not the SDK')
    so, se = run('ap-wire-symbols', ['/usr/bin/nm', '--defined-only', wire])
    symbols = {name.decode() for kind, name in
               re.findall(rb'(?m)^[0-9a-fA-F]+ ([TW]) ([A-Za-z0-9_]+)$', so)}
    need(se == b'' and {'remote_handle64_open', 'remote_handle64_invoke', 'remote_handle64_close',
        'HAP_debug_v2', 'HAP_debug_runtime', 'sp11_native_compute_v1_sum',
        'sp11_native_compute_v1_max', 'sp11_native_compute_v1_sum_checked',
        'sp11_native_compute_v1_max_checked'}.issubset(symbols),
        'actual generated, checked and mock definitions are linked into the wire fixture')
    so, se = run('ap-wire-unit', [wire])
    need(so == b'ap-wire-unit: 32 cases, 708 checks passed (MOCK TRANSPORT ONLY; genuine AP stub; no SDK/DSP/remote execution)\n'
         and se == b'', 'actual genuine-stub/local-mock wire oracle')
    # The SDK has constructors which can open device resources before main.
    # Keep its executable behind a separately linked libc-only public launcher.
    client = WORK / 'bin/compute-rpc-worker'
    run('ap-client-link-only', flags + ['-DSP11_COMPUTE_ARCH_BYTE=0x73', WORK / 'native-source/host/compute-client.c',
        WORK / 'native-source/host/compute-checked.c', stub, library,
        '-Wl,--no-undefined', '-o', client])
    artifacts['rpc-client-not-executed'] = elf(client, (2, 3))
    run('ap-client-elf', ['/usr/bin/readelf', '-hWd', '--dyn-syms', client])
    run('ap-client-symbols', ['/usr/bin/nm', '--defined-only', client])
    launcher = WORK / 'bin/compute-client'
    run('launcher-compile', flags + ['-DSP11_COMPUTE_ARCH_BYTE=0x73',
        WORK / 'native-source/host/compute-launcher.c', '-Wl,--no-undefined', '-o', launcher])
    artifacts['public-launcher'] = elf(launcher, (2, 3))
    launcher_elf, launcher_stderr = run('launcher-elf',
        ['/usr/bin/readelf', '-hWd', '--dyn-syms', launcher])
    launcher_needed = re.findall(rb'\(NEEDED\).*Shared library: \[([^\]]+)\]', launcher_elf)
    need(launcher_needed == [b'libc.so.6'] and launcher_stderr == b'',
         'public launcher has only libc, not the SDK or generated RPC code')
    mock_worker = WORK / 'bin/launcher-worker-mock'
    run('launcher-mock-worker-compile', flags + ['-DSP11_COMPUTE_ARCH_BYTE=0x73',
        WORK / 'native-source/tests/launcher-worker-mock.c',
        '-Wl,--no-undefined', '-o', mock_worker])
    artifacts['launcher-mock-worker'] = elf(mock_worker, (2, 3))
    mock_elf, mock_stderr = run('launcher-mock-worker-elf',
        ['/usr/bin/readelf', '-hWd', mock_worker])
    need(re.findall(rb'\(NEEDED\).*Shared library: \[([^\]]+)\]', mock_elf) == [b'libc.so.6']
         and mock_stderr == b'', 'mock worker has no SDK dependency before execution')
    launcher_cases = WORK / 'launcher-unit'
    launcher_stdout, launcher_stderr = run('launcher-admission-unit',
        ['/usr/bin/python3', '-I', '-B', WORK / 'native-source/tests/launcher-unit.py',
         '--launcher', launcher, '--mock-worker', mock_worker, '--output', launcher_cases])
    need(launcher_stdout == b'launcher-unit: 27 cases passed (LIBC-ONLY LAUNCHER; LOCAL MOCK WORKER ONLY; genuine SDK worker never executed)\n'
         and launcher_stderr == b'', 'source-derived launcher fixture oracle')
    launcher_report = json.loads(read(launcher_cases / 'RESULT.json', 1 << 20)[0])
    need(launcher_report.get('schema') == 'sp11-r86-launcher-unit-v1' and
         launcher_report.get('status') == 'passed' and
         launcher_report.get('genuineSDKWorkerExecuted') is False and
         launcher_report.get('cases') == 27 and len(launcher_report.get('records', [])) == 27 and
         launcher_report.get('invalidAdmissionCases') == 20 and
         launcher_report.get('admittedDispatchCases') == 6 and
         launcher_report.get('missingWorkerCases') == 1 and
         launcher_report.get('constructorMarkers') == 6,
         'launcher fixture proves only local admission and process dispatch')
    mock_client = WORK / 'bin/client-under-test.o'
    mock_fixture = WORK / 'bin/client-control-unit.o'
    mock_unit = WORK / 'bin/client-control-unit'
    mock_flags = flags + ['-DSP11_COMPUTE_ARCH_BYTE=0x73']
    run('mock-client-compile', mock_flags + ['-Dmain=sp11_client_main', '-c',
        WORK / 'native-source/host/compute-client.c', '-o', mock_client])
    run('mock-fixture-compile', mock_flags + ['-c',
        WORK / 'native-source/tests/client-control-unit.c', '-o', mock_fixture])
    # Checked calls reach only fixture raw-API mocks, never SDK/stub/DSP code.
    run('mock-unit-link', flags + [WORK / 'native-source/host/compute-checked.c', mock_client, mock_fixture,
        '-Wl,--no-undefined', '-o', mock_unit])
    artifacts['mock-control-unit'] = elf(mock_unit, (2, 3))
    so, se = run('mock-control-unit', [mock_unit])
    need(so == b'client-control-unit: 23 scenarios passed (MOCKCONTROLONLY; no SDK/stub/remote execution)\n'
         and se == b'', 'actual client-control unit oracle, not remote execution')
    capture_after()
    guard()
    save('RESULT.json', {'schema': 'sp11-r83-native-compute-cpu-build-v1',
        'status': 'cpu-build-and-pure-units-passed-diagnostics-await-root', 'commands': COMMANDS,
        'tools': tools, 'observedPackages': packages, 'artifacts': artifacts, 'generated': generation,
        'sourceManifest': pin(KIT / 'SOURCE-MANIFEST.json', 8 << 20),
        'sourceProvenance': pin(KIT / 'SOURCE-PROVENANCE.json', 1 << 20),
        'builder': pin(KIT / 'tools/build-cpu.py', 1 << 20),
        'executedBuilder': executed_builder,
        'qaicVersionSource': pin(WORK / 'qaic/src/Compiler/Version.hs'), 'libtoolArchive': pin(la),
        'inputBefore': pin(WORK / 'INPUT-BEFORE.json'), 'inputAfter': pin(WORK / 'INPUT-AFTER.json'),
        'seconds': time.monotonic() - START, 'rpcClientExecuted': False, 'dspArtifactCompiled': False,
        'clientBuildArchitectureByte': '0x73 candidate only; actual firmware architecture is unverified',
        'launcherUnitReport': pin(launcher_cases / 'RESULT.json'),
        'publicLauncherExecutedWithMockWorker': True,
        'launcherNeededLibraries': [name.decode() for name in launcher_needed],
        'checkedAPI': {'unitChecks': 266, 'rejectionCases': 50, 'forwardingCases': 18,
                       'realClientUsesCheckedAPI': True, 'rawGeneratedAPIsRemainAvailable': True,
                       'pointerStorageValidityProved': False},
        'generatedAPStubExecutedWithMockTransport': True,
        'wireUnitSDKLinked': False,
        'apWireUnit': {'cases': 32, 'checks': 708, 'validWireCases': 18,
                       'locallyRejectedCases': 14, 'runtimeLogCalls': 12,
                       'neededLibraries': [name.decode() for name in needed],
                       'openClosePassthroughTested': False,
                       'independentAllInputBytesCompared': False},
        'scope': 'Real native QAIC/file2hs build and IDL generation; patched fresh libcdsprpc only; actual-header layout, pure C implementation and checked-API units; genuine AP-stub marshalling against local transport/logging mocks only. The libc-only public launcher runs solely in fixtures with a local mock worker. Genuine SDK worker remains link-only; its constructors are not run. No DSP execution, live capability/RPC/device query, daemon, installation, firmware or hardware qualification.',
        'limits': 'Tool compatibility is earned only by actual completed commands. Full raw diagnostics require disposition. Observed package versions and sampled resource bounds are not a hermetic toolchain or hard filesystem quota. Source-export revision metadata is not a claim of Git HEAD. No installation or network operation is performed by this builder.'})


try:
    main()
except BaseException as error:
    try:
        if WORK is not None and WORK.is_dir() and not (WORK / 'FAILURE.json').exists():
            input_error = None
            if BEFORE is not None and not (WORK / 'INPUT-AFTER.json').exists():
                try:
                    capture_after()
                except BaseException as snapshot_error:
                    input_error = repr(snapshot_error)
            save('FAILURE.json', {'schema': 'sp11-r83-native-compute-build-failure-v1',
                'status': 'failed', 'failure': repr(error), 'commands': COMMANDS,
                'inputEvidenceError': input_error,
                'seconds': time.monotonic() - START, 'rpcClientExecuted': False,
                'scope': 'Failure preserved; no pass inferred from partial build products.'})
    except BaseException as receipt_error:
        raise error from receipt_error
    raise
