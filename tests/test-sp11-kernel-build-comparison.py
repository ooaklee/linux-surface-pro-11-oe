#!/usr/bin/env python3
"""Hostile fixtures for the SP11 adjacent kernel-build comparator."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import os
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
COMPARATOR = REPO / "scripts/compare-sp11-kernel-builds.py"
REAL_A = REPO / "build/phase0-repro-a-f93fe57/artifacts"
REAL_B = REPO / "build/phase0-repro-b-f93fe57/artifacts"


def load_comparator():
    name = "_sp11_kernel_comparison_fixture_target"
    specification = importlib.util.spec_from_file_location(name, COMPARATOR)
    if specification is None or specification.loader is None:
        raise AssertionError("comparison module could not be loaded")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


C = load_comparator()


def expect_failure(function, *arguments, contains: str | None = None) -> None:
    try:
        function(*arguments)
    except C.ValidationError as exc:
        if contains is not None and contains not in str(exc):
            raise AssertionError(f"unexpected validation error: {exc}") from exc
    else:
        raise AssertionError("hostile fixture was accepted")


def compile_header(host: bytes, suffix: bytes = b"") -> bytes:
    return (
        b'#define UTS_MACHINE "aarch64"\n'
        b'#define LINUX_COMPILE_BY "root"\n'
        b'#define LINUX_COMPILE_HOST "'
        + host
        + b'"\n'
        b'#define LINUX_COMPILER "fixture"\n'
        + suffix
    )


def signed_module(
    *,
    pad: bytes = b"\x00\x00\x00",
    signature_length: int = 3,
    duplicate_marker: bool = False,
) -> bytes:
    signer = b"S"
    key_id = b"K"
    signature = b"abc"
    payload = b"\x7fELFfixture-module"
    if duplicate_marker:
        payload += C.MODULE_MARKER
    descriptor = (
        bytes((1, 2, 3, len(signer), len(key_id)))
        + pad
        + signature_length.to_bytes(4, "big")
    )
    return payload + signer + key_id + signature + descriptor + C.MODULE_MARKER


def minimal_pe(*, overlap: bool = False, out_of_bounds: bool = False) -> bytes:
    section_count = 2 if overlap else 1
    pe_offset = 64
    optional_size = 2
    section_table = pe_offset + 24 + optional_size
    raw_offset = 256
    total = 264
    image = bytearray(total)
    image[:2] = b"MZ"
    struct.pack_into("<I", image, 0x3C, pe_offset)
    image[pe_offset : pe_offset + 4] = b"PE\x00\x00"
    struct.pack_into("<HH", image, pe_offset + 4, 0xAA64, section_count)
    struct.pack_into("<H", image, pe_offset + 20, optional_size)
    struct.pack_into("<H", image, pe_offset + 24, 0x20B)
    for index in range(section_count):
        offset = section_table + index * 40
        image[offset : offset + 8] = (b".one\x00\x00\x00\x00" if index == 0 else b".two\x00\x00\x00\x00")
        pointer = total + 1 if out_of_bounds else raw_offset
        struct.pack_into("<IIII", image, offset + 8, 8, 0x1000 + index * 0x1000, 8, pointer)
        struct.pack_into("<I", image, offset + 36, 0x40000040)
    image[raw_offset : raw_offset + 8] = b"PE-DATA!"
    return bytes(image)


def minimal_elf(*, overlap: bool = False) -> bytes:
    section_names = b"\x00.text\x00.shstrtab\x00"
    section_offset = 128
    image = bytearray(section_offset + 3 * 64)
    image[:16] = b"\x7fELF\x02\x01\x01" + b"\x00" * 9
    struct.pack_into(
        "<HHIQQQIHHHHHH",
        image,
        16,
        1,
        183,
        1,
        0,
        0,
        section_offset,
        0,
        64,
        0,
        0,
        64,
        3,
        2,
    )
    image[64] = 0xAA
    image[65 : 65 + len(section_names)] = section_names
    text_size = 8 if overlap else 1
    struct.pack_into("<IIQQQQIIQQ", image, section_offset + 64, 1, 1, 6, 0, 64, text_size, 0, 0, 1, 0)
    struct.pack_into(
        "<IIQQQQIIQQ",
        image,
        section_offset + 128,
        7,
        3,
        0,
        0,
        65,
        len(section_names),
        0,
        0,
        1,
        0,
    )
    return bytes(image)


def newc_entry(name: str, data: bytes, *, mtime: int = 1) -> bytes:
    name_bytes = name.encode("utf-8") + b"\x00"
    fields = (
        1,
        0o100644,
        0,
        0,
        1,
        mtime,
        len(data),
        0,
        0,
        0,
        0,
        len(name_bytes),
        0,
    )
    header = b"070701" + b"".join(f"{value:08x}".encode("ascii") for value in fields)
    body = header + name_bytes
    body += b"\x00" * ((-len(body)) % 4)
    body += data
    body += b"\x00" * ((-len(body)) % 4)
    return body


def test_version_and_public_failure() -> None:
    version = subprocess.run(
        [sys.executable, str(COMPARATOR), "--version"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert C.SCHEMA in version.stdout
    with tempfile.TemporaryDirectory(prefix="sp11-kernel-comparison.") as temporary:
        secret = "private-path-sentinel"
        missing_a = Path(temporary) / secret / "a"
        missing_b = Path(temporary) / secret / "b"
        failed = subprocess.run(
            [
                sys.executable,
                str(COMPARATOR),
                "--build-a",
                str(missing_a),
                "--build-b",
                str(missing_b),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert failed.returncode == 1
        assert failed.stdout == ""
        assert secret not in failed.stderr
        assert str(Path(temporary)) not in failed.stderr


def test_compile_header_policy() -> None:
    first = compile_header(b"aaaaaaaaaaaa")
    second = compile_header(b"bbbbbbbbbbbb")
    host_a, host_b, changed = C.normalize_compile_header(first, second)
    assert host_a == b"aaaaaaaaaaaa"
    assert host_b == b"bbbbbbbbbbbb"
    assert changed == 12
    expect_failure(
        C.normalize_compile_header,
        first,
        compile_header(b"short"),
        contains="different widths",
    )
    expect_failure(
        C.normalize_compile_header,
        first,
        compile_header(b"bbbbbbbbbbbb", b"unknown\n"),
        contains="outside",
    )


def test_module_signature_policy() -> None:
    module = signed_module()
    raw_sha, raw_md5, record = C.module_record(
        io.BytesIO(module), "usr/lib/modules/fixture-qcom-x1e/kernel/fixture.ko", "none", len(module)
    )
    unsigned = b"\x7fELFfixture-module"
    assert raw_sha == hashlib.sha256(module).hexdigest()
    assert raw_md5 == hashlib.md5(module, usedforsecurity=False).hexdigest()
    assert record.signed is True
    assert record.unsigned_size == len(unsigned)
    assert record.unsigned_sha256 == hashlib.sha256(unsigned).hexdigest()
    malformed_pad = signed_module(pad=b"\x00\x01\x00")
    expect_failure(
        C.module_record,
        io.BytesIO(malformed_pad),
        "usr/lib/modules/fixture-qcom-x1e/kernel/fixture.ko",
        "none",
        len(malformed_pad),
        contains="descriptor",
    )
    malformed_length = signed_module(signature_length=2**24)
    expect_failure(
        C.module_record,
        io.BytesIO(malformed_length),
        "usr/lib/modules/fixture-qcom-x1e/kernel/fixture.ko",
        "none",
        len(malformed_length),
        contains="exceeds",
    )
    duplicate = signed_module(duplicate_marker=True)
    expect_failure(
        C.module_record,
        io.BytesIO(duplicate),
        "usr/lib/modules/fixture-qcom-x1e/kernel/fixture.ko",
        "none",
        len(duplicate),
        contains="ambiguous",
    )


def test_zstd_and_instruction_policy() -> None:
    frame = C.ZSTD_MAGIC + b"\x20\x00\x01\x00\x00"
    end, content_size = C.zstd_frame_end(frame, 0)
    assert end == len(frame)
    assert content_size == 0
    reserved = bytearray(frame)
    reserved[4] |= 0x08
    expect_failure(C.zstd_frame_end, bytes(reserved), 0, contains="reserved")
    invalid_block = C.ZSTD_MAGIC + b"\x20\x00\x07\x00\x00"
    expect_failure(C.zstd_frame_end, invalid_block, 0, contains="invalid block")

    add_a = 0x91000400
    add_b = 0x91000800
    ldr_a = 0xB9400400
    ldr_b = 0xB9400800
    adds, ldrs = C.classify_zboot_prefix(
        struct.pack("<II", add_a, ldr_a), struct.pack("<II", add_b, ldr_b)
    )
    assert (adds, ldrs) == (1, 1)
    expect_failure(
        C.classify_zboot_prefix,
        struct.pack("<I", 0xD503201F),
        struct.pack("<I", 0xD503205F),
        contains="unknown",
    )


def test_binary_container_bounds() -> None:
    valid_pe = minimal_pe()
    parsed_pe = C.parse_pe(valid_pe, "fixture PE")
    assert len(parsed_pe.sections) == 1
    expect_failure(C.parse_pe, minimal_pe(overlap=True), "fixture PE", contains="overlapping")
    expect_failure(
        C.parse_pe,
        minimal_pe(out_of_bounds=True),
        "fixture PE",
        contains="out-of-bounds",
    )

    valid_elf = minimal_elf()
    parsed_elf = C.parse_elf(valid_elf, "fixture ELF")
    assert [section.name for section in parsed_elf.sections] == ["", ".text", ".shstrtab"]
    expect_failure(C.parse_elf, minimal_elf(overlap=True), "fixture ELF", contains="overlapping")

    cpio = newc_entry("fixture", b"data") + newc_entry("TRAILER!!!", b"")
    parsed_cpio = C.parse_cpio_at(cpio, 0)
    assert parsed_cpio is not None
    assert [entry[0] for entry in parsed_cpio.entries] == ["fixture", "TRAILER!!!"]
    assert C.parse_cpio_at(cpio[:-1], 0) is None
    hostile_name = bytearray(cpio)
    hostile_name[94:102] = b"ffffffff"
    assert C.parse_cpio_at(bytes(hostile_name), 0) is None


def test_link_policy() -> None:
    abi = "7.2-fixture-qcom-x1e"
    expected = f"/usr/src/linux-headers-{abi}"
    assert C.recorded_link_target("usr/lib/modules/build", expected, False, "data", abi) == expected
    expect_failure(
        C.recorded_link_target,
        "usr/lib/modules/build",
        "/private/path-sentinel",
        False,
        "data",
        abi,
        contains="unsupported",
    )
    expect_failure(
        C.recorded_link_target,
        "safe/path",
        "../../../escape",
        False,
        "data",
        abi,
        contains="escaping",
    )


def test_historical_raw_and_installed_size_policy() -> None:
    for side, roles in C.HISTORICAL_PACKAGE_ALLOWLIST.items():
        for role, (package, version, architecture, size, digest) in roles.items():
            filename = f"{package}_{version}_{architecture}.deb"
            C.validate_historical_raw_identity(side, role, filename, size, digest)
            expect_failure(
                C.validate_historical_raw_identity,
                side,
                role,
                filename,
                size,
                "0" * 64,
                contains="allowlist",
            )
            expect_failure(
                C.validate_historical_raw_identity,
                side,
                role,
                filename,
                size + 1,
                digest,
                contains="allowlist",
            )
    with tempfile.TemporaryDirectory(prefix="sp11-kernel-raw-policy.") as temporary:
        root = Path(temporary)
        for role in C.HISTORICAL_PACKAGE_ALLOWLIST["A"]:
            (root / C.historical_filename("A", role)).write_bytes(b"hostile non-allowlisted bytes")
        expect_failure(
            C.open_historical_build,
            root,
            "A",
            contains="allowlist",
        )

    for role, residual in C.HISTORICAL_INSTALLED_SIZE_RESIDUALS.items():
        record = C.MemberRecord(
            "fixture",
            "file",
            0o644,
            0,
            0,
            "root",
            "root",
            "",
            1024,
            0,
            "0" * 64,
            "0" * 32,
        )
        scan = SimpleNamespace(
            identity=SimpleNamespace(role=role),
            control_fields={"Installed-Size": str(1 + residual)},
            data=SimpleNamespace(records={"fixture": record}),
        )
        assert C.installed_size_residual(scan) == (1 + residual, 1, residual)
        mutated = SimpleNamespace(
            identity=scan.identity,
            control_fields={"Installed-Size": str(2 + residual)},
            data=scan.data,
        )
        expect_failure(
            C.installed_size_residual,
            mutated,
            contains="not bound",
        )


def test_real_retained_pair(*, require: bool) -> bool:
    if not REAL_A.is_dir() or not REAL_B.is_dir():
        if require:
            raise AssertionError("required retained A/B kernel fixtures are absent")
        print("real retained A/B kernel fixtures are absent; historical assertion skipped")
        return False
    result_a = C.compare_builds(REAL_A, REAL_B)
    result_b = C.compare_builds(REAL_A, REAL_B)
    report_a = C.render_report(result_a)
    report_b = C.render_report(result_b)
    assert report_a == report_b
    assert str(REPO) not in report_a
    assert "/Users/" not in report_a
    for packages in (result_a.packages_a, result_a.packages_b):
        compile_values = [
            match.group(1).decode("ascii")
            for content in packages["headers"].data.captures.values()
            if (match := C.COMPILE_HOST_PATTERN.search(content)) is not None
        ]
        assert len(compile_values) == 1
        assert compile_values[0] not in report_a
    expected_lines = {
        "Kernel adjacent comparison schema: sp11-kernel-adjacent-comparison-v1",
        "Semantic policy: sp11-kernel-historical-semantic-v1",
        "Raw differing package count: 4",
        "Packaged DTB count: 1792",
        "Packaged DTB v1 JSON-lines aggregate SHA256: 9e1a68ea3e863d02bb1cf544316ad08a7ea92a8888fb580b4e9aae59ad63cf2f",
        "Published historical packaged DTB aggregate reference SHA256: d41b7c27e7e58eb307494f0add22d8fab8383d2ddf13c173901908a2d53b95a6",
        "SP11 OLED DTB SHA256: 360f1b9ef87e3de33e6eeeb6fb8179abd385807860e0d177ab4d57cea9d68f7b",
        "Stubble dtbauto count: 38",
        "Stubble dtbauto v1 JSON-lines aggregate SHA256: 238814723ccf9ee72848a7c26d71590369254e8b4257024bad2523be58c6e2d5",
        "Published historical Stubble dtbauto aggregate reference SHA256: 1c9fb2a76004df732437ccf59bd18727b04daf13a7ab35fff562a0e93ca41a53",
        "Vmlinuz A SHA256: 0b360ef2a7ca504c84b1a0098434d0a14f8b318bf5682d087cc9baa7063daf23",
        "Vmlinuz B SHA256: b5abab7c999be7f44d8c9b22f68e4550ed3aa240211423a96bf88492c19e70ce",
        "Zboot changed ADD immediate words: 263",
        "Zboot changed LDR immediate words: 2",
        "Kernel Image changed bytes: 1142",
        "Kernel Image compile-host changed bytes: 33",
        "Kernel Image timestamp changed bytes: 8",
        "Kernel Image certificate changed bytes: 1069",
        "Kernel Image build-ID changed bytes: 20",
        "Kernel Image cpio-mtime changed bytes: 12",
        "Normalized Kernel Image SHA256: ccdec0fffffa9ee783bc8301187a51e4fd422273fde5f0bfd81e758fe355deb6",
        "Kernel _text.._etext SHA256: 151b8c80bb9bb2cd5b969e3c832aef74b3e1dd24f084f519b3bda408fafa12af",
        "Module count: 7814",
        "Signed module count: 7729",
        "Unsigned module count: 85",
        "Non-kheaders v1 JSON-lines normalized aggregate SHA256: ebfcc31759ed7d30ea5e68dd89e542b03385bc38a38c9a47d2afa527d9658d4e",
        "Published historical non-kheaders aggregate reference SHA256: 0c36587d0153d65abf2586d98c0c3119516c610cc8722f144eefaa5cc65e4c67",
        "Kheaders v1 JSON-lines normalized aggregate SHA256: 645b548010e898c71fb2a2252468b63f8742ac5b6f0c711174456790f203dbb5",
        "Published historical kheaders aggregate reference SHA256: 6c5c0dac76be29dfc9a67006da6aeb5101691dc7275fca7821edaa93091065d0",
        "Unknown payload difference count: 0",
        "Semantic adjacent-pair equivalence: true",
        "Comparison completed: true",
    }
    lines = set(report_a.splitlines())
    missing = expected_lines - lines
    if missing:
        raise AssertionError(f"historical report assertions are missing: {sorted(missing)}")
    raw_hashes = {
        "c1ff51eae8eabce0737b73aa09204c6ef78a69ccbb693397a9658858e3dcae46",
        "b560c6f435cb31f3ad736d63809f3eaef9d2708267503b581b2359e6a0953d62",
        "e4fa77c90e95c3a36c15dca304521f5c3b7f694697ccb25f7c1baa4ea933aa63",
        "e4101b608146915843ff96905943f56e3258b15100445671e268c72a1ee0b22e",
        "c1c7c056d81ab7f55b569ae8db4c6db01743bb1b20fd0e9f6fcecd7cce339812",
        "125f94aa247ed32a720d630443ccffca3f6d9856f556877c19693dcf445b7ac0",
        "4209f6aa05bdba18e9f40fcebf7d9a5b1cf6f223ae436c452d33a1329c80970f",
        "0ff61e491bca4106d3d252f74ea6b6ab58f8165220cac85c2dd6006c1e42abc0",
    }
    for digest in raw_hashes:
        assert digest in report_a
    expect_failure(
        C.compare_builds,
        REAL_B,
        REAL_A,
        contains="directional historical raw allowlist",
    )
    return True


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--synthetic-only",
        action="store_true",
        help="run bounded hostile fixtures without requiring retained real packages",
    )
    modes.add_argument(
        "--require-real",
        action="store_true",
        help="fail unless the retained historical A/B pair is present and verified twice",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_args(argv)
    test_version_and_public_failure()
    test_compile_header_policy()
    test_module_signature_policy()
    test_zstd_and_instruction_policy()
    test_binary_container_bounds()
    test_link_policy()
    test_historical_raw_and_installed_size_policy()
    ran_real = False
    if not arguments.synthetic_only:
        ran_real = test_real_retained_pair(require=arguments.require_real)
    if arguments.require_real and not ran_real:
        raise AssertionError("required retained A/B assertion did not run")
    print(f"Retained real A/B assertion ran: {'true' if ran_real else 'false'}")
    print("SP11 kernel adjacent-comparison hostile fixtures passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
