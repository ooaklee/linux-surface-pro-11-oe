#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Build a v73 Hexagon analysis DSO only; never execute or qualify a DSP runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import struct
import subprocess
import time

WORK = CPU = KIT = SOURCE = FASTRPC = None
OUTPUT_ADMITTED = False
START, COMMANDS, HELD = time.monotonic(), [], {}
ENV = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'TZ': 'UTC',
       'PYTHONDONTWRITEBYTECODE': '1'}
NATIVE = {'dsp/compute.c': '1cbb5b9985a71330aa7f089f0e6a7b9c2248f87cdcbf903cf5cd590d3d112177',
          'freestanding/include/stdio.h': '78422a997416fee0c1bd8939eafe5dffa9748e0219f4df9f20366d42e8f0b59e',
          'freestanding/include/stdlib.h': 'f2693faa4c1bc101ab324f6f4a66a8acfc037ca736c1ef7790c3598a76cb8048',
          'freestanding/include/string.h': '2f1c5d87956269b8ca2e81027a03948169beb61514641c7f55c76de402e2ec47',
          'freestanding/include/sys/types.h': 'd46447e2bb6bf1bc9b2c57146fcc5890a308f9e1f9f32efde697b41a163f4e02'}
SONAME = 'libsp11_native_compute_v1_skel.so'
ENTRY = 'sp11_native_compute_v1_skel_handle_invoke'
PAGE = 4096


def need(value, message):
    if not value:
        raise ValueError(message)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read(path, maximum=32 << 20, hold=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and
             0 <= before.st_size <= maximum, 'bounded unshared regular input: ' + str(path))
        data = stream.read(maximum + 1)
        need(identity(before) == identity(os.fstat(stream.fileno())) and len(data) == before.st_size,
             'changed read: ' + str(path))
    descriptor = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data), 'identity': identity(before)}
    if hold:
        if str(path) in HELD:
            need(HELD[str(path)] == descriptor, 'held input changed')
        HELD[str(path)] = descriptor
    return data, descriptor


def decode(data):
    def pairs(rows):
        result = {}
        for key, value in rows:
            need(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs)


def save(leaf, value):
    with (WORK / leaf).open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')


def guard():
    need(time.monotonic() - START < 300 and shutil.disk_usage(WORK).free >= 128 << 20,
         'whole-worker300s/free-space floor')
    total = 0
    for directory, dirs, files in os.walk(WORK, followlinks=False):
        dirs[:] = [name for name in dirs if not (Path(directory) / name).is_symlink()]
        for name in files:
            try:
                info = (Path(directory) / name).lstat()
            except FileNotFoundError:
                continue
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
    need(total <= 64 << 20, 'sampled64MiB output bound, not a quota')


def run(label, argv, maximum=60):
    guard()
    row = {'label': label, 'argv': [str(item) for item in argv], 'cwd': str(WORK),
           'environment': dict(ENV), 'maximumSeconds': maximum, 'exit': None,
           'failure': None, 'cleanupErrors': [], 'captureErrors': []}
    COMMANDS.append(row)
    stdout, stderr = WORK / (label + '.stdout'), WORK / (label + '.stderr')
    child, primary = None, None
    try:
        with stdout.open('xb') as so, stderr.open('xb') as se:
            child = subprocess.Popen(row['argv'], cwd=WORK, env=ENV, stdin=subprocess.DEVNULL,
                stdout=so, stderr=se, start_new_session=True)
            deadline = min(START + 300, time.monotonic() + maximum)
            while child.poll() is None:
                guard()
                need(time.monotonic() < deadline and
                     os.fstat(so.fileno()).st_size + os.fstat(se.fileno()).st_size <= 4 << 20,
                     'command deadline/log bound: ' + label)
                time.sleep(0.1)
            need(child.returncode == 0, 'command nonzero: ' + label)
    except BaseException as error:
        primary = error
        row['failure'] = repr(error)
    finally:
        if child is not None and child.poll() is None:
            for sig, seconds in ((signal.SIGTERM, 3), (signal.SIGKILL, 3)):
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
                row['streams'][suffix] = read(path, 4 << 20)[1]
            except BaseException as error:
                row['streams'][suffix] = None
                row['captureErrors'].append(suffix + ': ' + repr(error))
        save('command-%02d.json' % len(COMMANDS), row)
    if primary is not None:
        raise primary
    need(not row['cleanupErrors'] and not row['captureErrors'], 'capture/cleanup failure')
    return read(stdout, 4 << 20)[0]


def same_material(path, expected):
    data, current = read(path, hold=True)
    need(current['sha256'] == expected['sha256'] and current['bytes'] == expected['bytes'],
         'actual CPU material binding: ' + str(path))
    return data


def header(data, expected_type):
    need(len(data) >= 52 and data[:7] == b'\x7fELF\x01\x01\x01', 'ELF32 little-endian header')
    value = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    need(value[1] == expected_type and value[2] == 164 and value[3] == 1 and value[8] == 52 and
         value[7] == 0x73, 'actual EM_HEXAGON164/type/version/header size and exact v73 e_flags0x73')
    return value


def program_headers(data, h):
    offset, stride, count = h[5], h[9], h[10]
    need(stride == 32 and 0 < count <= 256 and offset <= len(data) and
         count * stride <= len(data) - offset, 'bounded ELF32 program-header table')
    result, loads = [], []
    for i in range(count):
        kind, off, va, pa, filesz, memsz, flags, align = struct.unpack_from('<8I', data, offset + i * stride)
        need(off <= len(data) and filesz <= len(data) - off and va + memsz <= 1 << 32 and
             pa + memsz <= 1 << 32, 'bounded PHDR file/32-bit address extent')
        need(align in (0, 1) or align & (align - 1) == 0, 'power-of-two PHDR alignment')
        need(not (flags & 1 and flags & 2), 'explicit analysis profile rejects actual W+X PHDR')
        row = {'index': i, 'type': kind, 'offset': off, 'virtualAddress': va, 'physicalAddress': pa,
               'fileBytes': filesz, 'memoryBytes': memsz, 'flags': flags, 'alignment': align}
        if kind == 1:
            need(filesz <= memsz and memsz > 0 and align == PAGE and off % PAGE == va % PAGE,
                 'actual nonempty LOAD filesz/memsz/4096-alignment/congruence profile')
            row['virtualPageRange'] = [va // PAGE * PAGE, (va + memsz + PAGE - 1) // PAGE * PAGE]
            row['filePageRange'] = [off // PAGE * PAGE, (off + filesz + PAGE - 1) // PAGE * PAGE] if filesz else None
            loads.append(row)
        result.append(row)
    need(loads, 'actual loadable segments required')
    for field in ('virtualPageRange', 'filePageRange'):
        ranges = sorted((r[field][0], r[field][1], r['index']) for r in loads if r[field] is not None)
        for previous, current in zip(ranges, ranges[1:]):
            need(previous[1] <= current[0], 'pairwise disjoint 4096-rounded LOAD ' + field)
    return result


def inventory(data):
    h = header(data, 3)
    phdrs = program_headers(data, h)
    offset, stride, count, names_index = h[6], h[11], h[12], h[13]
    need(stride == 40 and 0 < count <= 4096 and names_index < count and
         offset <= len(data) and count * stride <= len(data) - offset, 'bounded section table')
    sections = [struct.unpack_from('<IIIIIIIIII', data, offset + i * stride) for i in range(count)]
    def extent(section):
        start, size = section[4], section[5]
        need(start <= len(data) and size <= len(data) - start, 'bounded section extent')
        return data[start:start + size]
    for section in sections:
        if section[1] != 8:
            extent(section)
        need(section[3] + section[5] <= 1 << 32, '32-bit section address extent')
    need(sections[names_index][1] == 3, 'section-name string table')
    names = extent(sections[names_index])
    def string(table, start):
        need(start < len(table), 'bounded string offset')
        end = table.find(b'\0', start)
        need(end >= 0, 'terminated ELF string')
        return table[start:end].decode('ascii')
    labels = [string(names, row[0]) for row in sections]
    dy = [i for i, row in enumerate(sections) if row[1] == 11]
    dynamic = [i for i, row in enumerate(sections) if row[1] == 6]
    need(len(dy) == len(dynamic) == 1 and labels[dy[0]] == '.dynsym', 'one complete dynamic symbol/table pair')
    symbol_tables = {}
    for table_index, symbol_section in enumerate(sections):
        if symbol_section[1] not in (2, 11):
            continue
        need(symbol_section[9] == 16 and symbol_section[5] % 16 == 0 and symbol_section[6] < count and
             sections[symbol_section[6]][1] == 3, 'actual ELF32 symbol stride/string-table link')
        strings, symbols = extent(sections[symbol_section[6]]), []
        raw = extent(symbol_section)
        need(len(raw) // 16 <= 65536, 'bounded actual symbol count')
        for index in range(len(raw) // 16):
            name, value, size, info, other, shndx = struct.unpack_from('<IIIBBH', raw, index * 16)
            need(shndx < count or shndx >= 0xff00, 'bounded or special symbol section index')
            symbols.append({'index': index, 'name': string(strings, name), 'value': value, 'bytes': size,
                'binding': info >> 4, 'type': info & 15, 'visibility': other & 3, 'sectionIndex': shndx})
        symbol_tables[table_index] = symbols
    symbols = symbol_tables[dy[0]]
    row = sections[dynamic[0]]
    need(row[9] == 8 and row[5] % 8 == 0 and row[6] < count and sections[row[6]][1] == 3,
         'actual ELF32 dynamic stride/string-table link')
    dynstr, dynamic_raw = extent(sections[row[6]]), extent(row)
    tags = [struct.unpack_from('<iI', dynamic_raw, i) for i in range(0, len(dynamic_raw), 8)]
    need(any(tag == 0 for tag, value in tags), 'terminated dynamic table')
    needed = [string(dynstr, value) for tag, value in tags if tag == 1]
    sonames = [string(dynstr, value) for tag, value in tags if tag == 14]
    need(needed == [] and sonames == [SONAME], 'no fabricated runtime dependency; exact unique SONAME')
    exports = [row for row in symbols if row['name'] and row['sectionIndex'] != 0 and row['binding'] in (1, 2)]
    entries = [row for row in exports if row['name'] == ENTRY]
    need(len(entries) == 1 and entries[0]['binding'] == 1 and entries[0]['type'] == 2 and
         entries[0]['visibility'] in (0, 3), 'one actual exported skeleton entry')
    undefined = [row for row in symbols if row['name'] and row['sectionIndex'] == 0]
    need(all(row['binding'] == 2 for row in undefined), 'analysis profile forbids strong unresolved imports')
    relocations = []
    for index, section in enumerate(sections):
        if section[1] not in (4, 9):
            continue
        step = 12 if section[1] == 4 else 8
        need(section[9] == step and section[5] % step == 0 and section[6] in symbol_tables and
             section[7] < count, 'complete relocation stride/symbol link/target')
        raw, linked = extent(section), symbol_tables[section[6]]
        need(len(raw) // step <= 65536, 'bounded relocation count')
        for position in range(0, len(raw), step):
            address, info = struct.unpack_from('<II', raw, position)
            sym = info >> 8
            need(sym < len(linked), 'relocation actual symbol index')
            relocations.append({'sectionIndex': index, 'sectionName': labels[index], 'index': position // step,
                'offset': address, 'rawInfo': info, 'type': info & 255, 'symbolIndex': sym,
                'symbolName': linked[sym]['name'], 'symbolTableSectionIndex': section[6],
                'addend': struct.unpack_from('<i', raw, position + 8)[0] if step == 12 else None,
                'allocated': bool(section[2] & 2)})
    return {'class': 32, 'machine': 164, 'type': 3, 'eFlags': h[7], 'eFlagsHex': hex(h[7]),
        'programHeaders': phdrs, 'loadPageBytes': PAGE, 'loadPageRangesDisjoint': True,
        'gnuStack': [r for r in phdrs if r['type'] == 0x6474e551],
        'tlsProgramHeaders': [r for r in phdrs if r['type'] == 7],
        'noteProgramHeaders': [r for r in phdrs if r['type'] == 4],
        'sections': [{'index': i, 'name': labels[i], 'type': row[1], 'flags': row[2], 'address': row[3],
            'offset': row[4], 'bytes': row[5], 'link': row[6], 'info': row[7], 'alignment': row[8],
            'entryBytes': row[9]} for i, row in enumerate(sections)],
        'allDynamicSymbols': symbols, 'exports': exports, 'strongUndefined': [r for r in undefined if r['binding'] != 2],
        'weakUndefined': [r for r in undefined if r['binding'] == 2],
        'dynamicTags': [{'tag': tag, 'value': value} for tag, value in tags], 'relocations': relocations,
        'dynamicNeeded': needed, 'soname': sonames[0], 'exportedSkeletonEntry': entries[0]}


def main():
    global WORK, CPU, KIT, SOURCE, FASTRPC, OUTPUT_ADMITTED
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kit', required=True, type=Path)
    parser.add_argument('--cpu-output', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cpu-result-sha256', required=True)
    parser.add_argument('--isa', required=True, choices=['v73'])
    args = parser.parse_args()
    need(re.fullmatch('[0-9a-f]{64}', args.cpu_result_sha256), 'external actual CPU-result SHA required')
    os.umask(0o077)
    KIT, CPU, WORK = (path.absolute() for path in (args.kit, args.cpu_output, args.output))
    for path in (KIT, CPU, WORK):
        need(not any(c.isspace() or c in '\\:' for c in str(path)), 'plain path required by fixed depfile grammar')
    need(KIT.resolve(strict=True) == KIT and KIT.is_dir() and CPU.resolve(strict=True) == CPU and CPU.is_dir(),
         'canonical existing kit and CPU-output directories')
    need(os.geteuid() != 0 and os.uname().machine == 'aarch64', 'native ARM64 nonroot user required')
    need(WORK.resolve(strict=False) == WORK, 'canonical output path before any creation')
    need(not WORK.is_relative_to(KIT) and not KIT.is_relative_to(WORK) and
         not WORK.is_relative_to(CPU) and not CPU.is_relative_to(WORK), 'output disjoint from all input roots')
    if not WORK.exists():
        WORK.mkdir(mode=0o700)
    info = WORK.lstat()
    need(os.geteuid() != 0 and os.uname().machine == 'aarch64' and WORK.resolve(strict=True) == WORK and
         stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700 and info.st_uid == os.geteuid() and
         not any(WORK.iterdir()) and shutil.disk_usage(WORK).free >= 256 << 20,
         'fresh native nonroot-owned mode0700 analysis output')
    OUTPUT_ADMITTED = True
    SOURCE, FASTRPC = KIT / 'native', KIT / 'upstream/fastrpc'
    need(SOURCE.resolve(strict=True) == SOURCE and FASTRPC.resolve(strict=True) == FASTRPC,
         'canonical kit native and FastRPC sources')
    ENV.update({'HOME': str(WORK / 'home'), 'TMPDIR': str(WORK / 'tmp')})
    for leaf in ('home', 'tmp', 'generated'):
        (WORK / leaf).mkdir(mode=0o700)
    result_raw, descriptor = read(CPU / 'RESULT.json', 16 << 20, True)
    need(descriptor['sha256'] == args.cpu_result_sha256, 'externally pinned completed CPU receipt')
    result = decode(result_raw)
    need(result['schema'] == 'sp11-r83-native-compute-cpu-build-v1' and
         result['status'] == 'cpu-build-and-pure-units-passed-diagnostics-await-root' and
         result['rpcClientExecuted'] is False and result['dspArtifactCompiled'] is False,
         'actual CPU stage only, not inferred success from generated leaves')
    before = decode(same_material(CPU / 'INPUT-BEFORE.json', result['inputBefore']))
    after = decode(same_material(CPU / 'INPUT-AFTER.json', result['inputAfter']))
    need(before == after and set(before) == {'kit'}, 'actual CPU full kit identities unchanged')
    kit_before = before['kit']
    same_material(KIT / 'SOURCE-MANIFEST.json', result['sourceManifest'])
    same_material(KIT / 'SOURCE-PROVENANCE.json', result['sourceProvenance'])
    builder = read(Path(__file__).resolve(strict=True), 1 << 20, True)[1]
    same_material(KIT / 'tools/build-hexagon.py', kit_before['tools/build-hexagon.py'])
    need(builder['sha256'] == kit_before['tools/build-hexagon.py']['sha256'] and
         builder['bytes'] == kit_before['tools/build-hexagon.py']['bytes'], 'executed builder matches CPU-bound kit tool')
    for leaf, expected_sha in NATIVE.items():
        data, current = read(SOURCE / leaf, hold=True)
        expected = kit_before['native/' + leaf]
        need(expected['type'] == 'file' and current['sha256'] == expected_sha == expected['sha256'] and
             current['bytes'] == expected['bytes'], 'reviewed current native/facade input: ' + leaf)
        if leaf == 'dsp/compute.c':
            (WORK / 'compute.c').write_bytes(data)
    for leaf in ('sp11_native_compute_v1.h', 'sp11_native_compute_v1_skel.c'):
        (WORK / 'generated' / leaf).write_bytes(same_material(CPU / 'generated' / leaf, result['generated'][leaf]))
    tools = {name: read(Path(path).resolve(strict=True), 256 << 20, True)[1] for name, path in
             [('clang', '/usr/bin/clang-19'), ('linker', '/usr/bin/ld.lld-19'),
              ('readelf', '/usr/bin/llvm-readelf-19'), ('nm', '/usr/bin/llvm-nm-19')]}
    resource_text = run('clang-resource-dir', ['/usr/bin/clang-19', '-print-resource-dir']).decode().strip()
    resource = Path(resource_text).resolve(strict=True)
    need(resource.is_relative_to(Path('/usr/lib/llvm-19')) and (resource / 'include').is_dir(),
         'compiler-owned resource headers')
    flags = ['/usr/bin/clang-19', '--target=hexagon-unknown-none-elf', '-mcpu=hexagon' + args.isa, '-std=c11', '-O2', '-g',
        '-Wall', '-Wextra', '-Werror', '-pedantic', '-ffreestanding', '-nostdinc', '-fPIC', '-isystem', resource / 'include',
        '-I' + str(SOURCE / 'freestanding/include'), '-I' + str(WORK / 'generated'), '-I' + str(FASTRPC / 'inc')]
    objects, dependencies = [], {}
    for label, source in [('compute', WORK / 'compute.c'), ('skeleton', WORK / 'generated/sp11_native_compute_v1_skel.c')]:
        obj, dep = WORK / (label + '.o'), WORK / (label + '.d')
        # Authored implementation is strict C11; the pinned generated skeleton
        # uses its generator's GNU dialect, with normal warnings still fatal.
        unit_flags = flags if label == 'compute' else [flag for flag in flags
                                                     if flag not in ('-std=c11', '-pedantic')] + ['-std=gnu11']
        run(label + '-compile', unit_flags + ['-MD', '-MF', dep, '-MT', obj, '-c', source, '-o', obj])
        header(read(obj)[0], 1)
        raw = read(dep, 1 << 20)[0].decode().replace('\\\n', ' ')
        target, colon, names = raw.partition(':')
        need(colon and target.strip() == str(obj), 'fixed compilation dependency target')
        rows = {}
        for name in names.split():
            need('\\' not in name and ':' not in name and '..' not in Path(name).parts, 'plain bounded dependency')
            path = Path(name).resolve(strict=True)
            expected = None
            if path.is_relative_to(FASTRPC / 'inc'):
                expected = kit_before['upstream/fastrpc/' + path.relative_to(FASTRPC).as_posix()]
            elif path.is_relative_to(SOURCE / 'freestanding/include'):
                expected = kit_before['native/' + path.relative_to(SOURCE).as_posix()]
            else:
                need(path == source or path.is_relative_to(WORK / 'generated') or path.is_relative_to(resource / 'include'),
                     'no host-sysroot or unreviewed header dependency')
            if expected is not None:
                need(expected['type'] == 'file', 'CPU-bound source dependency is a file')
                same_material(path, expected)
            rows[str(path)] = read(path, hold=not path.is_relative_to(WORK))[1]
        dependencies[label] = {'raw': raw, 'files': rows, 'object': read(obj)[1], 'dependencyFile': read(dep)[1]}
        objects.append(obj)
    output = WORK / SONAME
    run('analysis-link', ['/usr/bin/ld.lld-19', '-shared', '--no-undefined', '-soname', SONAME,
        '-z', 'max-page-size=4096', '-z', 'common-page-size=4096', '-z', 'separate-loadable-segments',
        '-o', output] + objects)
    artifact_raw, artifact = read(output)
    symbols = inventory(artifact_raw)
    save('ELF-INVENTORY.json', symbols)
    run('analysis-readelf', ['/usr/bin/llvm-readelf-19', '-hWld', '--dyn-syms', output])
    run('analysis-relocations', ['/usr/bin/llvm-readelf-19', '-rW', output])
    run('analysis-nm', ['/usr/bin/llvm-nm-19', '-D', output])
    held_after = {path: read(Path(path), 256 << 20)[1] for path in HELD}
    save('HELD-INPUT-AFTER.json', held_after)
    need(held_after == HELD, 'every held input/tool/dependency preserved')
    guard()
    save('RESULT.json', {'schema': 'sp11-r83-hexagon-analysis-v1', 'status': 'analysis-completed-runtime-unqualified',
        'cpuResultSHA256': args.cpu_result_sha256, 'isaArgument': args.isa, 'artifact': artifact,
        'commands': COMMANDS, 'heldInputs': HELD, 'heldInputAfter': read(WORK / 'HELD-INPUT-AFTER.json')[1],
        'executedBuilder': builder, 'sourceManifest': result['sourceManifest'], 'sourceProvenance': result['sourceProvenance'],
        'tools': tools, 'resourceDirectory': str(resource), 'kit': str(KIT), 'cpuOutput': str(CPU),
        'dependencies': dependencies, 'elfInventory': read(WORK / 'ELF-INVENTORY.json')[1],
        'strongRuntimeImportNames': [row['name'] for row in symbols['strongUndefined']],
        'qualificationBlockers': ['Any strong unresolved imports have no qualified runtime provider.'] if symbols['strongUndefined'] else [],
        'deployable': False, 'runtimeClosure': 'unproved', 'physicalISA': 'unknown', 'loaderABI': 'unknown',
        'executedArtifact': False, 'seconds': time.monotonic() - START,
        'scope': 'Fresh freestanding Hexagon analysis objects/shared link with explicit 4096-byte separate LOAD profile, compiler resource headers and four declaration-only facade headers; no CRT/stdlib/allocator implementation or ignored-undefined override. Complete sections, PHDRs, dynamic symbols, relocations and source dependencies retained. No client, DSP or runtime execution.',
        'limits': 'A successful shared link and page-profile validation are not runtime resolution, QuRT ABI/loader compatibility, real v73 firmware identity, DSP execution or installation qualification. NOTE/TLS/GNU_STACK are inventoried, not generic loader-support claims. Declaration facades are not runtime implementations. All diagnostics remain for review; output bounds are sampled, not hard quotas.'})


if __name__ == '__main__':
    try:
        main()
    except BaseException as error:
        try:
            if OUTPUT_ADMITTED and WORK.is_dir() and not (WORK / 'FAILURE.json').exists():
                save('FAILURE.json', {'schema': 'sp11-r83-hexagon-analysis-failure-v1', 'status': 'failed',
                    'failure': repr(error), 'commands': COMMANDS, 'deployable': False,
                    'runtimeClosure': 'unproved', 'executedArtifact': False, 'seconds': time.monotonic() - START})
        except BaseException as receipt_error:
            raise error from receipt_error
        raise
