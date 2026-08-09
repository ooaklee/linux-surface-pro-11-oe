#!/usr/bin/env python3
"""Fail-closed semantic comparison for adjacent SP11 kernel package builds."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
import re
import stat
import struct
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable, Iterator


SCHEMA = "sp11-kernel-adjacent-comparison-v1"
POLICY = "sp11-kernel-historical-semantic-v1"
AGGREGATE_SCHEMA = "sp11-path-inventory-json-lines-v1"
MAX_SPECIAL_FILE_BYTES = 256 * 1024 * 1024
MAX_KHEADERS_MODULE_BYTES = 64 * 1024 * 1024
MAX_KHEADERS_TAR_BYTES = 512 * 1024 * 1024
MAX_INNER_IMAGE_BYTES = 128 * 1024 * 1024
MAX_PE_SECTIONS = 256
MAX_ELF_SECTIONS = 1024
MAX_CPIO_ENTRIES = 100_000
MAX_CPIO_NAME_BYTES = 4096
MAX_IDENTITY_BYTES = 256
MODULE_MARKER = b"~Module signature appended~\n"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
ARM64_IMAGE_MAGIC = b"ARM\x64"
DTB_MAGIC = b"\xd0\x0d\xfe\xed"
ZBOOT_POST_ANCHOR = b"i\x00n\x00i\x00t\x00r\x00d\x00=\x00"
ROLE_ORDER = ("common-headers", "headers", "image", "modules", "modules-extra")
HISTORICAL_VERSION = "7.2-rc5-jg-0sp11v3"
HISTORICAL_PACKAGE_ALLOWLIST = {
    "A": {
        "common-headers": (
            "linux-qcom-x1e-headers-7.2-rc5-jg-0sp11v3",
            HISTORICAL_VERSION,
            "all",
            15_167_686,
            "c1ff51eae8eabce0737b73aa09204c6ef78a69ccbb693397a9658858e3dcae46",
        ),
        "headers": (
            "linux-headers-7.2-rc5-jg-0sp11v3-qcom-x1e",
            HISTORICAL_VERSION,
            "arm64",
            1_431_262,
            "e4fa77c90e95c3a36c15dca304521f5c3b7f694697ccb25f7c1baa4ea933aa63",
        ),
        "image": (
            "linux-image-7.2-rc5-jg-0sp11v3-qcom-x1e",
            HISTORICAL_VERSION,
            "arm64",
            164_032,
            "c1c7c056d81ab7f55b569ae8db4c6db01743bb1b20fd0e9f6fcecd7cce339812",
        ),
        "modules": (
            "linux-modules-7.2-rc5-jg-0sp11v3-qcom-x1e",
            HISTORICAL_VERSION,
            "arm64",
            306_821_312,
            "4209f6aa05bdba18e9f40fcebf7d9a5b1cf6f223ae436c452d33a1329c80970f",
        ),
    },
    "B": {
        "common-headers": (
            "linux-qcom-x1e-headers-7.2-rc5-jg-0sp11v3",
            HISTORICAL_VERSION,
            "all",
            15_168_272,
            "b560c6f435cb31f3ad736d63809f3eaef9d2708267503b581b2359e6a0953d62",
        ),
        "headers": (
            "linux-headers-7.2-rc5-jg-0sp11v3-qcom-x1e",
            HISTORICAL_VERSION,
            "arm64",
            1_430_668,
            "e4101b608146915843ff96905943f56e3258b15100445671e268c72a1ee0b22e",
        ),
        "image": (
            "linux-image-7.2-rc5-jg-0sp11v3-qcom-x1e",
            HISTORICAL_VERSION,
            "arm64",
            164_032,
            "125f94aa247ed32a720d630443ccffca3f6d9856f556877c19693dcf445b7ac0",
        ),
        "modules": (
            "linux-modules-7.2-rc5-jg-0sp11v3-qcom-x1e",
            HISTORICAL_VERSION,
            "arm64",
            306_811_072,
            "0ff61e491bca4106d3d252f74ea6b6ab58f8165220cac85c2dd6006c1e42abc0",
        ),
    },
}
HISTORICAL_INSTALLED_SIZE_RESIDUALS = {
    "common-headers": 4_112,
    "headers": 456,
    "image": 17,
    "modules": 1_415,
}
PUBLISHED_HISTORICAL_AGGREGATES = {
    "packaged-dtb": "d41b7c27e7e58eb307494f0add22d8fab8383d2ddf13c173901908a2d53b95a6",
    "dtbauto": "1c9fb2a76004df732437ccf59bd18727b04daf13a7ab35fff562a0e93ca41a53",
    "non-kheaders-modules": "0c36587d0153d65abf2586d98c0c3119516c610cc8722f144eefaa5cc65e4c67",
    "kheaders": "6c5c0dac76be29dfc9a67006da6aeb5101691dc7275fca7821edaa93091065d0",
}
PACKAGE_NAME = re.compile(r"[a-z0-9][a-z0-9+.-]*\Z")
PACKAGE_VERSION = re.compile(r"[0-9][0-9A-Za-z.+:~_-]*\Z")
ABI_PATTERN = re.compile(r"[a-z0-9][a-z0-9.+~-]*-qcom-x1e\Z")
SAFE_IDENTITY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+~:-]*\Z")
HEX_32 = re.compile(r"[0-9a-f]{32}\Z")
TIMESTAMP_PATTERN = re.compile(
    rb"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) "
    rb"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) "
    rb"[ 0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-6][0-9] UTC [0-9]{4}"
)
COMPILE_HOST_PATTERN = re.compile(
    rb'(?m)^#define LINUX_COMPILE_HOST[ \t]+"([A-Za-z0-9._-]{1,64})"$'
)


def _load_deb_reader():
    path = Path(__file__).resolve().with_name("validate-sp11-module-signatures.py")
    try:
        metadata = path.stat()
    except OSError as exc:
        raise RuntimeError("the bounded Debian package reader is unavailable") from exc
    if not stat.S_ISREG(metadata.st_mode):
        raise RuntimeError("the bounded Debian package reader is unavailable")
    name = "_sp11_bounded_deb_reader_v1"
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError("the bounded Debian package reader could not be loaded")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


DEB = _load_deb_reader()
ValidationError = DEB.ValidationError


@dataclass(frozen=True)
class PackageIdentity:
    role: str
    package: str
    version: str
    architecture: str
    abi: str


@dataclass(frozen=True)
class MemberRecord:
    path: str
    kind: str
    mode: int
    uid: int
    gid: int
    uname: str
    gname: str
    target: str
    size: int
    mtime: int
    sha256: str
    md5: str


@dataclass(frozen=True)
class ModuleRecord:
    path: str
    compression: str
    expanded_size: int
    expanded_sha256: str
    unsigned_size: int
    unsigned_sha256: str
    signed: bool
    descriptor: tuple[int, int, int, int, int, int]
    trailer_sha256: str
    kheaders_payload: bytes | None


@dataclass
class ArchiveScan:
    records: dict[str, MemberRecord]
    captures: dict[str, bytes]
    modules: dict[str, ModuleRecord]


@dataclass
class PackageScan:
    identity: PackageIdentity
    filename: str
    size: int
    sha256: str
    ar_members: tuple[tuple[str, int, str], ...]
    control: ArchiveScan
    data: ArchiveScan
    control_fields: dict[str, str]
    md5sums: dict[str, str]


@dataclass
class OpenPackage:
    side: str
    role: str
    filename: str
    descriptor: int
    before: os.stat_result
    sha256: str


@dataclass
class OpenBuild:
    side: str
    descriptor: int
    before: os.stat_result
    names: tuple[str, ...]
    packages: dict[str, OpenPackage]


@dataclass(frozen=True)
class PESection:
    index: int
    name: str
    virtual_size: int
    virtual_address: int
    raw_size: int
    raw_offset: int
    characteristics: int
    data: bytes


@dataclass(frozen=True)
class PEImage:
    sections: tuple[PESection, ...]


@dataclass(frozen=True)
class ELFSection:
    index: int
    name: str
    section_type: int
    flags: int
    address: int
    offset: int
    size: int
    link: int
    info: int
    alignment: int
    entry_size: int
    data: bytes


@dataclass(frozen=True)
class ELFImage:
    section_table_offset: int
    sections: tuple[ELFSection, ...]


@dataclass(frozen=True)
class CpioArchive:
    start: int
    end: int
    entries: tuple[tuple[str, int, int, int], ...]


@dataclass
class ComparisonResult:
    packages_a: dict[str, PackageScan]
    packages_b: dict[str, PackageScan]
    values: dict[str, str | int | bool]


class HashingReader:
    """Record both package-file digests while a decompressor consumes a member."""

    def __init__(self, source: BinaryIO) -> None:
        self.source = source
        self.sha256 = hashlib.sha256()
        self.md5 = hashlib.md5(usedforsecurity=False)
        self.count = 0

    def read(self, size: int = -1) -> bytes:
        data = self.source.read(size)
        if data:
            self.sha256.update(data)
            self.md5.update(data)
            self.count += len(data)
        return data


def stable_metadata(value: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def safe_text(value: str, label: str, *, allow_empty: bool = True) -> str:
    try:
        encoded = value.encode("utf-8")
    except UnicodeError as exc:
        raise ValidationError(f"{label} is not valid UTF-8") from exc
    if (not value and not allow_empty) or len(encoded) > MAX_IDENTITY_BYTES:
        raise ValidationError(f"{label} has an invalid length")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValidationError(f"{label} contains a control character")
    return value


def hash_region(descriptor: int, offset: int, size: int, algorithm: str = "sha256") -> str:
    digest = hashlib.new(algorithm, usedforsecurity=False)
    position = 0
    while position < size:
        chunk = os.pread(descriptor, min(DEB.COPY_CHUNK_BYTES, size - position), offset + position)
        if not chunk:
            raise ValidationError("package changed or became truncated during comparison")
        digest.update(chunk)
        position += len(chunk)
    return digest.hexdigest()


def historical_filename(side: str, role: str) -> str:
    try:
        package, version, architecture, _size, _digest = HISTORICAL_PACKAGE_ALLOWLIST[side][role]
    except KeyError as exc:
        raise ValidationError("historical package side or role is unsupported") from exc
    return f"{package}_{version}_{architecture}.deb"


def validate_historical_raw_identity(
    side: str,
    role: str,
    filename: str,
    size: int,
    digest: str,
    identity: PackageIdentity | None = None,
) -> None:
    try:
        package, version, architecture, expected_size, expected_digest = (
            HISTORICAL_PACKAGE_ALLOWLIST[side][role]
        )
    except KeyError as exc:
        raise ValidationError("historical package side or role is unsupported") from exc
    if (
        filename != f"{package}_{version}_{architecture}.deb"
        or size != expected_size
        or digest != expected_digest
        or (
            identity is not None
            and (
                identity.role != role
                or identity.package != package
                or identity.version != version
                or identity.architecture != architecture
            )
        )
    ):
        raise ValidationError("package does not match the directional historical raw allowlist")


def close_open_build(opened: OpenBuild | None) -> None:
    if opened is None:
        return
    for package in opened.packages.values():
        if package.descriptor >= 0:
            os.close(package.descriptor)
            package.descriptor = -1
    if opened.descriptor >= 0:
        os.close(opened.descriptor)
        opened.descriptor = -1


def open_historical_build(path: Path, side: str) -> OpenBuild:
    if side not in HISTORICAL_PACKAGE_ALLOWLIST:
        raise ValidationError("historical build side is unsupported")
    directory_flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        directory_flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
    if hasattr(os, "O_DIRECTORY"):
        directory_flags |= os.O_DIRECTORY
    descriptor = -1
    packages: dict[str, OpenPackage] = {}
    try:
        descriptor = os.open(path, directory_flags)
        before = os.fstat(descriptor)
        if not stat.S_ISDIR(before.st_mode):
            raise ValidationError("build input must be a real directory")
        names = tuple(sorted(os.listdir(descriptor)))
        actual_debs = {name for name in names if name.endswith(".deb")}
        expected_debs = {
            historical_filename(side, role)
            for role in HISTORICAL_PACKAGE_ALLOWLIST[side]
        }
        if actual_debs != expected_debs:
            raise ValidationError("build input does not have the exact historical package filename set")
        package_flags = os.O_RDONLY
        if hasattr(os, "O_CLOEXEC"):
            package_flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            package_flags |= os.O_NOFOLLOW
        if hasattr(os, "O_NONBLOCK"):
            package_flags |= os.O_NONBLOCK
        for role in ROLE_ORDER:
            if role not in HISTORICAL_PACKAGE_ALLOWLIST[side]:
                continue
            filename = historical_filename(side, role)
            package_descriptor = -1
            try:
                package_descriptor = os.open(filename, package_flags, dir_fd=descriptor)
                package_before = os.fstat(package_descriptor)
                if (
                    not stat.S_ISREG(package_before.st_mode)
                    or package_before.st_size <= 0
                    or package_before.st_size > DEB.MAX_PACKAGE_BYTES
                ):
                    raise ValidationError("historical package input is not a bounded regular file")
                digest = hash_region(package_descriptor, 0, package_before.st_size)
                package_after = os.fstat(package_descriptor)
                if stable_metadata(package_before) != stable_metadata(package_after):
                    raise ValidationError("historical package changed during raw preflight")
                validate_historical_raw_identity(
                    side, role, filename, package_before.st_size, digest
                )
                packages[role] = OpenPackage(
                    side,
                    role,
                    filename,
                    package_descriptor,
                    package_before,
                    digest,
                )
                package_descriptor = -1
            finally:
                if package_descriptor >= 0:
                    os.close(package_descriptor)
        after = os.fstat(descriptor)
        if stable_metadata(before) != stable_metadata(after) or names != tuple(
            sorted(os.listdir(descriptor))
        ):
            raise ValidationError("build input directory changed during raw preflight")
        return OpenBuild(side, descriptor, before, names, packages)
    except (OSError, ValidationError) as exc:
        partial = OpenBuild(side, descriptor, os.stat_result((0,) * 10), (), packages)
        close_open_build(partial)
        if isinstance(exc, ValidationError):
            raise
        raise ValidationError("build input could not be opened or preflighted safely") from exc


def validate_open_build_stable(opened: OpenBuild) -> None:
    try:
        after = os.fstat(opened.descriptor)
        names = tuple(sorted(os.listdir(opened.descriptor)))
    except OSError as exc:
        raise ValidationError("build input directory changed during comparison") from exc
    if stable_metadata(opened.before) != stable_metadata(after) or opened.names != names:
        raise ValidationError("build input directory changed during comparison")


def read_bounded(stream: BinaryIO, limit: int, label: str) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = stream.read(DEB.COPY_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise ValidationError(f"{label} exceeds its expanded-size limit")
        chunks.append(chunk)
    return b"".join(chunks)


def hash_regular(stream: BinaryIO, expected_size: int) -> tuple[str, str]:
    sha256 = hashlib.sha256()
    md5 = hashlib.md5(usedforsecurity=False)
    total = 0
    while True:
        chunk = stream.read(DEB.COPY_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > expected_size:
            raise ValidationError("tar member exceeds its declared size")
        sha256.update(chunk)
        md5.update(chunk)
    if total != expected_size:
        raise ValidationError("tar member is truncated")
    return sha256.hexdigest(), md5.hexdigest()


def count_marker(stream: BinaryIO, limit: int) -> int:
    stream.seek(0)
    overlap = b""
    count = 0
    total = 0
    while True:
        chunk = stream.read(DEB.COPY_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise ValidationError("module exceeds its expanded-size limit")
        combined = overlap + chunk
        start = 0
        while True:
            position = combined.find(MODULE_MARKER, start)
            if position < 0:
                break
            count += 1
            start = position + 1
        overlap = combined[-(len(MODULE_MARKER) - 1) :]
    return count


def hash_prefix(stream: BinaryIO, size: int) -> str:
    stream.seek(0)
    digest = hashlib.sha256()
    remaining = size
    while remaining:
        chunk = stream.read(min(DEB.COPY_CHUNK_BYTES, remaining))
        if not chunk:
            raise ValidationError("module became truncated during comparison")
        digest.update(chunk)
        remaining -= len(chunk)
    return digest.hexdigest()


def module_record(
    item_stream: BinaryIO, path: str, compression: str, raw_size: int
) -> tuple[str, str, ModuleRecord]:
    hashing = HashingReader(item_stream)
    with tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024) as expanded:
        expanded_digest = hashlib.sha256()
        expanded_size = 0
        with DEB.decompressed_stream(hashing, compression) as decoded:
            while True:
                chunk = decoded.read(DEB.COPY_CHUNK_BYTES)
                if not chunk:
                    break
                expanded_size += len(chunk)
                if expanded_size > DEB.MAX_MODULE_BYTES:
                    raise ValidationError("module exceeds its expanded-size limit")
                expanded_digest.update(chunk)
                expanded.write(chunk)
        if hashing.count != raw_size:
            raise ValidationError("compressed module did not consume its complete tar member")
        expanded.seek(0)
        if expanded.read(4) != b"\x7fELF":
            raise ValidationError("module payload is not an ELF file")
        signed = False
        descriptor = (0, 0, 0, 0, 0, 0)
        trailer_size = 0
        if expanded_size >= len(MODULE_MARKER) + 12:
            expanded.seek(expanded_size - len(MODULE_MARKER))
            signed = expanded.read(len(MODULE_MARKER)) == MODULE_MARKER
        if signed:
            descriptor_offset = expanded_size - len(MODULE_MARKER) - 12
            expanded.seek(descriptor_offset)
            raw_descriptor = expanded.read(12)
            if len(raw_descriptor) != 12 or raw_descriptor[5:8] != b"\x00\x00\x00":
                raise ValidationError("module signature descriptor is malformed")
            algorithm, hash_algorithm, identifier_type, signer_length, key_id_length = raw_descriptor[:5]
            signature_length = int.from_bytes(raw_descriptor[8:12], "big")
            if signature_length <= 0:
                raise ValidationError("module signature length is invalid")
            trailer_size = (
                signer_length
                + key_id_length
                + signature_length
                + 12
                + len(MODULE_MARKER)
            )
            if trailer_size >= expanded_size:
                raise ValidationError("module signature trailer exceeds the module")
            descriptor = (
                algorithm,
                hash_algorithm,
                identifier_type,
                signer_length,
                key_id_length,
                signature_length,
            )
        marker_count = count_marker(expanded, DEB.MAX_MODULE_BYTES)
        if marker_count != int(signed):
            raise ValidationError("module signature marker layout is ambiguous")
        unsigned_size = expanded_size - trailer_size
        unsigned_digest = hash_prefix(expanded, unsigned_size)
        trailer_digest = hashlib.sha256()
        if trailer_size:
            expanded.seek(unsigned_size)
            remaining = trailer_size
            while remaining:
                chunk = expanded.read(min(DEB.COPY_CHUNK_BYTES, remaining))
                if not chunk:
                    raise ValidationError("module signature trailer is truncated")
                trailer_digest.update(chunk)
                remaining -= len(chunk)
        kheaders_payload: bytes | None = None
        if path.endswith("/kernel/kernel/kheaders.ko.zst"):
            if unsigned_size > MAX_KHEADERS_MODULE_BYTES:
                raise ValidationError("kheaders module exceeds its comparison limit")
            expanded.seek(0)
            kheaders_payload = expanded.read(unsigned_size)
            if len(kheaders_payload) != unsigned_size:
                raise ValidationError("kheaders module is truncated")
        return (
            hashing.sha256.hexdigest(),
            hashing.md5.hexdigest(),
            ModuleRecord(
                path,
                compression,
                expanded_size,
                expanded_digest.hexdigest(),
                unsigned_size,
                unsigned_digest,
                signed,
                descriptor,
                trailer_digest.hexdigest() if signed else "none",
                kheaders_payload,
            ),
        )


def is_compile_header_path(path: str) -> bool:
    return path == "include/generated/compile.h" or path.endswith(
        "/include/generated/compile.h"
    )


def capture_limit(archive_kind: str, path: str) -> int | None:
    if archive_kind == "control" and path in ("control", "md5sums"):
        return DEB.MAX_CONTROL_TAR_BYTES
    if is_compile_header_path(path):
        return MAX_SPECIAL_FILE_BYTES
    if archive_kind == "data" and (
        path.startswith("boot/vmlinuz-")
        or path.startswith("boot/System.map-")
        or path.endswith("/x1e80100-microsoft-denali-oled.dtb")
    ):
        return MAX_SPECIAL_FILE_BYTES
    return None


def recorded_link_target(
    source: str, raw_target: str, hardlink: bool, archive_kind: str, abi: str | None
) -> str:
    """Validate link text without ever resolving or materializing the link."""

    if not hardlink and raw_target.startswith("/"):
        expected = f"/usr/src/linux-headers-{abi}" if archive_kind == "data" and abi else ""
        if raw_target != expected:
            raise ValidationError("package archive contains an unsupported absolute symlink target")
        safe_text(raw_target, "absolute symlink target", allow_empty=False)
        return raw_target
    return DEB.safe_link_target(source, raw_target, hardlink)


def scan_tar_stream(
    source: BinaryIO,
    expanded_limit: int,
    archive_kind: str,
    abi: str | None,
) -> ArchiveScan:
    limited = io.BufferedReader(DEB.LimitedReader(source, expanded_limit, f"{archive_kind} archive"))
    guarded = io.BufferedReader(DEB.TarMetadataGuardReader(limited))
    records: dict[str, MemberRecord] = {}
    captures: dict[str, bytes] = {}
    modules: dict[str, ModuleRecord] = {}
    try:
        with tarfile.open(fileobj=guarded, mode="r|") as archive:
            for index, item in enumerate(archive, 1):
                if index > DEB.MAX_MEMBERS:
                    raise ValidationError(f"{archive_kind} archive contains too many members")
                path = DEB.canonical_member_name(item.name)
                if path in records:
                    raise ValidationError(f"{archive_kind} archive contains a duplicate member path")
                uname = safe_text(item.uname or "", "tar owner name")
                gname = safe_text(item.gname or "", "tar group name")
                if not isinstance(item.mtime, (int, float)) or int(item.mtime) != item.mtime:
                    raise ValidationError("tar member has a non-integral timestamp")
                mtime = int(item.mtime)
                if mtime < 0 or mtime >= 1 << 63:
                    raise ValidationError("tar member timestamp is outside the supported range")
                if item.mode < 0 or item.mode > 0o7777 or item.uid < 0 or item.gid < 0:
                    raise ValidationError("tar member metadata is outside the supported range")
                target = ""
                sha256 = "none"
                md5 = "none"
                size = 0
                if item.issparse():
                    raise ValidationError(f"{archive_kind} archive contains a sparse member")
                if item.isfile():
                    kind = "file"
                    size = item.size
                    if size < 0 or size > expanded_limit:
                        raise ValidationError(f"{archive_kind} archive member exceeds the size limit")
                    extracted = archive.extractfile(item)
                    if extracted is None:
                        raise ValidationError(f"{archive_kind} archive member could not be read")
                    module_compression = DEB.compression_kind(path)
                    if module_compression is not None:
                        if archive_kind != "data" or abi is None:
                            raise ValidationError("module-like file appears outside a package data archive")
                        module_root = f"usr/lib/modules/{abi}/kernel/"
                        if not path.startswith(module_root):
                            raise ValidationError("module-like file is outside the expected ABI kernel tree")
                        with extracted:
                            sha256, md5, module = module_record(
                                extracted, path, module_compression, size
                            )
                        modules[path] = module
                    else:
                        limit = capture_limit(archive_kind, path)
                        if limit is None:
                            with extracted:
                                sha256, md5 = hash_regular(extracted, size)
                        else:
                            with extracted:
                                content = read_bounded(extracted, min(limit, size), "captured member")
                            if len(content) != size:
                                raise ValidationError("captured tar member is truncated")
                            sha256 = hashlib.sha256(content).hexdigest()
                            md5 = hashlib.md5(content, usedforsecurity=False).hexdigest()
                            captures[path] = content
                elif item.isdir():
                    kind = "directory"
                    if item.size != 0:
                        raise ValidationError("tar directory has nonzero size")
                elif item.issym() or item.islnk():
                    kind = "hardlink" if item.islnk() else "symlink"
                    if item.size != 0:
                        raise ValidationError("tar link has nonzero size")
                    target = recorded_link_target(
                        path, item.linkname, item.islnk(), archive_kind, abi
                    )
                else:
                    raise ValidationError(f"{archive_kind} archive contains a special member")
                records[path] = MemberRecord(
                    path,
                    kind,
                    item.mode,
                    item.uid,
                    item.gid,
                    uname,
                    gname,
                    target,
                    size,
                    mtime,
                    sha256,
                    md5,
                )
        DEB.drain_zero_tar_tail(guarded)
    except RecursionError as exc:
        raise ValidationError("tar metadata nesting exceeds the comparison limit") from exc
    except tarfile.TarError as exc:
        raise ValidationError(f"package contains a malformed {archive_kind} archive") from exc
    DEB.validate_member_ancestors(
        {name: ("link" if record.kind in ("symlink", "hardlink") else record.kind) for name, record in records.items()},
        f"{archive_kind} archive",
    )
    return ArchiveScan(records, captures, modules)


def scan_ar_archive(
    descriptor: int, member: object, archive_kind: str, abi: str | None
) -> ArchiveScan:
    source = io.BufferedReader(DEB.PreadSlice(descriptor, member.offset, member.size))
    with DEB.decompressed_stream(source, DEB.tar_compression(member.name)) as decoded:
        limit = DEB.MAX_CONTROL_TAR_BYTES if archive_kind == "control" else DEB.MAX_DATA_TAR_BYTES
        return scan_tar_stream(decoded, limit, archive_kind, abi)


def parse_identity(fields: dict[str, str], filename: str) -> PackageIdentity:
    package = fields.get("Package", "")
    version = fields.get("Version", "")
    architecture = fields.get("Architecture", "")
    if not PACKAGE_NAME.fullmatch(package) or not PACKAGE_VERSION.fullmatch(version):
        raise ValidationError("package has an unsupported control identity")
    role = ""
    abi = ""
    if package.startswith("linux-modules-extra-"):
        role = "modules-extra"
        abi = package[len("linux-modules-extra-") :]
    elif package.startswith("linux-modules-"):
        role = "modules"
        abi = package[len("linux-modules-") :]
    elif package.startswith("linux-image-"):
        role = "image"
        abi = package[len("linux-image-") :]
    elif package.startswith("linux-headers-"):
        role = "headers"
        abi = package[len("linux-headers-") :]
    elif package.startswith("linux-qcom-x1e-headers-"):
        role = "common-headers"
        release = package[len("linux-qcom-x1e-headers-") :]
        if release != version:
            raise ValidationError("common-header package release does not match its version")
        abi = release + "-qcom-x1e"
    else:
        raise ValidationError("package role is not supported by the historical policy")
    expected_architecture = "all" if role == "common-headers" else "arm64"
    if architecture != expected_architecture or not ABI_PATTERN.fullmatch(abi):
        raise ValidationError("package architecture or ABI is not supported")
    if filename != f"{package}_{version}_{architecture}.deb":
        raise ValidationError("package filename does not match its control identity")
    return PackageIdentity(role, package, version, architecture, abi)


def parse_md5sums(data: bytes) -> dict[str, str]:
    if len(data) > DEB.MAX_CONTROL_TAR_BYTES:
        raise ValidationError("md5sums metadata exceeds the comparison limit")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError("md5sums metadata is not valid UTF-8") from exc
    result: dict[str, str] = {}
    for line in text.splitlines():
        if not line or len(line) < 35 or line[32:34] != "  ":
            raise ValidationError("md5sums metadata contains a malformed row")
        digest = line[:32]
        path = DEB.canonical_member_name(line[34:])
        if not HEX_32.fullmatch(digest) or path in result:
            raise ValidationError("md5sums metadata contains an invalid or duplicate row")
        result[path] = digest
    if not result:
        raise ValidationError("package md5sums metadata is empty")
    return result


def validate_md5sums(scan: ArchiveScan, values: dict[str, str]) -> None:
    regular = {path: record.md5 for path, record in scan.records.items() if record.kind == "file"}
    if values != regular:
        raise ValidationError("package md5sums do not bind every regular data member exactly")


def scan_package(opened: OpenPackage) -> PackageScan:
    descriptor = opened.descriptor
    try:
        before = os.fstat(descriptor)
        if stable_metadata(before) != stable_metadata(opened.before):
            raise ValidationError("historical package changed after raw preflight")
        raw_digest = hash_region(descriptor, 0, before.st_size)
        validate_historical_raw_identity(
            opened.side,
            opened.role,
            opened.filename,
            before.st_size,
            raw_digest,
        )
        members = DEB.parse_ar(descriptor, before.st_size)
        control_member = next(value for key, value in members.items() if key.startswith("control.tar"))
        control = scan_ar_archive(descriptor, control_member, "control", None)
        if "control" not in control.captures or "md5sums" not in control.captures:
            raise ValidationError("package control archive lacks required control or md5sums metadata")
        fields = DEB.read_control_fields(control.captures["control"])
        identity = parse_identity(fields, opened.filename)
        validate_historical_raw_identity(
            opened.side,
            opened.role,
            opened.filename,
            before.st_size,
            raw_digest,
            identity,
        )
        data_member = next(value for key, value in members.items() if key.startswith("data.tar"))
        data = scan_ar_archive(descriptor, data_member, "data", identity.abi)
        md5sums = parse_md5sums(control.captures["md5sums"])
        validate_md5sums(data, md5sums)
        ar_members = tuple(
            (name, member.size, hash_region(descriptor, member.offset, member.size))
            for name, member in members.items()
        )
        digest_after = hash_region(descriptor, 0, before.st_size)
        after = os.fstat(descriptor)
        if stable_metadata(before) != stable_metadata(after) or raw_digest != digest_after:
            raise ValidationError("package changed during comparison")
        return PackageScan(
            identity,
            opened.filename,
            before.st_size,
            raw_digest,
            ar_members,
            control,
            data,
            fields,
            md5sums,
        )
    except OSError as exc:
        raise ValidationError("input package could not be opened or read safely") from exc


def scan_build(opened: OpenBuild) -> dict[str, PackageScan]:
    scans: dict[str, PackageScan] = {}
    for role in ROLE_ORDER:
        if role not in opened.packages:
            continue
        scan = scan_package(opened.packages[role])
        if scan.identity.role in scans:
            raise ValidationError("package role appears more than once in a build")
        scans[scan.identity.role] = scan
    required = {"common-headers", "headers", "image", "modules"}
    if not required.issubset(scans) or not set(scans).issubset(set(ROLE_ORDER)):
        raise ValidationError("build package role set is incomplete or unsupported")
    expected_abi = scans["modules"].identity.abi
    expected_version = scans["modules"].identity.version
    for scan in scans.values():
        if scan.identity.abi != expected_abi or scan.identity.version != expected_version:
            raise ValidationError("build packages have mixed ABI or version identities")
    validate_open_build_stable(opened)
    return scans


def inventory_digest(records: Iterable[dict[str, object]]) -> str:
    digest = hashlib.sha256()
    for record in records:
        encoded = json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")
        digest.update(encoded)
        digest.update(b"\n")
    return digest.hexdigest()


def member_metadata(record: MemberRecord) -> tuple[object, ...]:
    return (
        record.kind,
        record.mode,
        record.uid,
        record.gid,
        record.uname,
        record.gname,
        record.target,
    )


def compare_archive_shape(first: ArchiveScan, second: ArchiveScan) -> int:
    if set(first.records) != set(second.records):
        raise ValidationError("paired package archives have different member paths")
    changed_mtimes = 0
    for path in sorted(first.records):
        left = first.records[path]
        right = second.records[path]
        if member_metadata(left) != member_metadata(right):
            raise ValidationError("paired package archive member type, mode, ownership, or link target differs")
        changed_mtimes += int(left.mtime != right.mtime)
    return changed_mtimes


def installed_size_residual(scan: PackageScan) -> tuple[int, int, int]:
    value = scan.control_fields.get("Installed-Size", "")
    if not value.isdigit():
        raise ValidationError("Installed-Size is absent or is not a decimal derived value")
    apparent_kib = sum(
        (record.size + 1023) // 1024
        for record in scan.data.records.values()
        if record.kind == "file"
    )
    installed_size = int(value)
    residual = installed_size - apparent_kib
    expected = HISTORICAL_INSTALLED_SIZE_RESIDUALS.get(scan.identity.role)
    if expected is None or residual != expected:
        raise ValidationError("Installed-Size is not bound to its historical data inventory")
    return installed_size, apparent_kib, residual


def compare_control(first: PackageScan, second: PackageScan) -> None:
    if set(first.control_fields) != set(second.control_fields):
        raise ValidationError("paired package control field sets differ")
    installed_a, apparent_a, residual_a = installed_size_residual(first)
    installed_b, apparent_b, residual_b = installed_size_residual(second)
    if (
        residual_a != residual_b
        or installed_a - installed_b != apparent_a - apparent_b
        or (apparent_a == apparent_b and installed_a != installed_b)
    ):
        raise ValidationError("paired Installed-Size values are not exact data-derived values")
    for field in sorted(first.control_fields):
        left = first.control_fields[field]
        right = second.control_fields[field]
        if field == "Installed-Size":
            continue
        if left != right:
            raise ValidationError("paired package control metadata differs outside Installed-Size")
    if set(first.md5sums) != set(second.md5sums):
        raise ValidationError("paired package md5sums path sets differ")
    for path, left in first.control.records.items():
        right = second.control.records[path]
        if left.kind != "file":
            continue
        if path not in ("control", "md5sums") and left.sha256 != right.sha256:
            raise ValidationError("paired package control member has an unknown content difference")


def normalize_compile_header(first: bytes, second: bytes) -> tuple[bytes, bytes, int]:
    match_a = list(COMPILE_HOST_PATTERN.finditer(first))
    match_b = list(COMPILE_HOST_PATTERN.finditer(second))
    if len(match_a) != 1 or len(match_b) != 1:
        raise ValidationError("compile.h does not contain exactly one bounded build-host identity")
    host_a = match_a[0].group(1)
    host_b = match_b[0].group(1)
    if len(host_a) != len(host_b):
        raise ValidationError("compile.h build-host identities have different widths")
    start_a, end_a = match_a[0].span(1)
    start_b, end_b = match_b[0].span(1)
    normalized_a = first[:start_a] + b"H" * len(host_a) + first[end_a:]
    normalized_b = second[:start_b] + b"H" * len(host_b) + second[end_b:]
    if normalized_a != normalized_b:
        raise ValidationError("compile.h differs outside its build-host identity")
    changed = sum(left != right for left, right in zip(host_a, host_b))
    return host_a, host_b, changed


def parse_pe(data: bytes, label: str) -> PEImage:
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise ValidationError(f"{label} is not a PE image")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if pe_offset < 0x40 or pe_offset + 24 > len(data) or data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise ValidationError(f"{label} has a malformed PE header")
    machine, section_count = struct.unpack_from("<HH", data, pe_offset + 4)
    optional_size = struct.unpack_from("<H", data, pe_offset + 20)[0]
    if machine != 0xAA64 or not (1 <= section_count <= MAX_PE_SECTIONS):
        raise ValidationError(f"{label} has an unsupported PE machine or section count")
    optional_offset = pe_offset + 24
    if optional_size < 2 or optional_offset + optional_size > len(data):
        raise ValidationError(f"{label} has a truncated PE optional header")
    if struct.unpack_from("<H", data, optional_offset)[0] != 0x20B:
        raise ValidationError(f"{label} is not a PE32+ image")
    section_offset = optional_offset + optional_size
    if section_offset + section_count * 40 > len(data):
        raise ValidationError(f"{label} has a truncated PE section table")
    sections: list[PESection] = []
    occupied: list[tuple[int, int]] = []
    for index in range(section_count):
        raw = data[section_offset + index * 40 : section_offset + (index + 1) * 40]
        raw_name = raw[:8].split(b"\0", 1)[0]
        try:
            name = raw_name.decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValidationError(f"{label} has a non-ASCII PE section name") from exc
        if not name or any(character < " " or character > "~" for character in name):
            raise ValidationError(f"{label} has an unsafe PE section name")
        virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from("<IIII", raw, 8)
        characteristics = struct.unpack_from("<I", raw, 36)[0]
        if raw_size:
            if raw_offset < section_offset + section_count * 40 or raw_offset + raw_size > len(data):
                raise ValidationError(f"{label} has an out-of-bounds PE section")
            occupied.append((raw_offset, raw_offset + raw_size))
        sections.append(
            PESection(
                index,
                name,
                virtual_size,
                virtual_address,
                raw_size,
                raw_offset,
                characteristics,
                data[raw_offset : raw_offset + raw_size],
            )
        )
    occupied.sort()
    if any(previous[1] > current[0] for previous, current in zip(occupied, occupied[1:])):
        raise ValidationError(f"{label} has overlapping PE sections")
    return PEImage(tuple(sections))


def single_pe_section(image: PEImage, name: str, label: str) -> PESection:
    matches = [section for section in image.sections if section.name == name]
    if len(matches) != 1:
        raise ValidationError(f"{label} does not contain exactly one {name} section")
    return matches[0]


def compare_outside_range(first: bytes, second: bytes, start: int, size: int, label: str) -> None:
    if len(first) != len(second) or first[:start] != second[:start] or first[start + size :] != second[start + size :]:
        raise ValidationError(f"{label} differs outside its classified section")


def parse_dtb(section: PESection) -> bytes:
    if len(section.data) < 8 or section.data[:4] != DTB_MAGIC:
        raise ValidationError("Stubble dtbauto section is not a flattened device tree")
    total = int.from_bytes(section.data[4:8], "big")
    if total < 40 or total > len(section.data) or section.data[total:].strip(b"\x00"):
        raise ValidationError("Stubble dtbauto section has an invalid size or padding")
    return section.data[:total]


def zstd_frame_end(data: bytes, start: int) -> tuple[int, int | None]:
    if start < 0 or start + 5 > len(data) or data[start : start + 4] != ZSTD_MAGIC:
        raise ValidationError("zboot payload does not begin with a Zstandard frame")
    position = start + 4
    descriptor = data[position]
    position += 1
    if descriptor & 0x18:
        raise ValidationError("zboot Zstandard frame uses reserved header bits")
    single_segment = bool(descriptor & 0x20)
    checksum = bool(descriptor & 0x04)
    dictionary_size = (0, 1, 2, 4)[descriptor & 0x03]
    fcs_flag = descriptor >> 6
    if not single_segment:
        if position >= len(data):
            raise ValidationError("zboot Zstandard frame header is truncated")
        position += 1
    position += dictionary_size
    fcs_size = (1 if single_segment else 0, 2, 4, 8)[fcs_flag]
    if position + fcs_size > len(data):
        raise ValidationError("zboot Zstandard frame header is truncated")
    content_size: int | None = None
    if fcs_size:
        content_size = int.from_bytes(data[position : position + fcs_size], "little")
        if fcs_size == 2:
            content_size += 256
    position += fcs_size
    while True:
        if position + 3 > len(data):
            raise ValidationError("zboot Zstandard frame has a truncated block header")
        header = int.from_bytes(data[position : position + 3], "little")
        position += 3
        last = bool(header & 1)
        block_type = (header >> 1) & 3
        block_size = header >> 3
        if block_type == 3 or block_size > 128 * 1024:
            raise ValidationError("zboot Zstandard frame has an invalid block")
        payload_size = 1 if block_type == 1 else block_size
        if position + payload_size > len(data):
            raise ValidationError("zboot Zstandard frame has a truncated block")
        position += payload_size
        if last:
            break
    if checksum:
        position += 4
        if position > len(data):
            raise ValidationError("zboot Zstandard frame checksum is truncated")
    return position, content_size


def decompress_zstd_frame(frame: bytes) -> bytes:
    with DEB.decompressed_stream(io.BytesIO(frame), "zstd") as stream:
        return read_bounded(stream, MAX_INNER_IMAGE_BYTES, "decompressed kernel Image")


def classify_zboot_prefix(first: bytes, second: bytes) -> tuple[int, int]:
    if len(first) != len(second) or len(first) % 4:
        raise ValidationError("zboot executable prefix has incompatible word alignment")
    add_count = 0
    ldr_count = 0
    immediate_mask = 0x003FFC00
    for offset in range(0, len(first), 4):
        left = int.from_bytes(first[offset : offset + 4], "little")
        right = int.from_bytes(second[offset : offset + 4], "little")
        if left == right:
            continue
        if (
            (left & ~immediate_mask) == (right & ~immediate_mask)
            and (left & 0x7F000000) == 0x11000000
        ):
            add_count += 1
            continue
        if (
            (left & ~immediate_mask) == (right & ~immediate_mask)
            and (left & 0xFFC00000) in (0x39400000, 0x79400000, 0xB9400000, 0xF9400000)
        ):
            ldr_count += 1
            continue
        raise ValidationError("zboot executable contains an unknown changed instruction word")
    return add_count, ldr_count


def canonical_zboot_suffix(data: bytes) -> tuple[bytes, int, int]:
    if data.count(ZBOOT_POST_ANCHOR) != 1:
        raise ValidationError("zboot post-payload anchor is absent or ambiguous")
    anchor = data.index(ZBOOT_POST_ANCHOR)
    before = data[:anchor]
    after = data[anchor:]
    before_padding = len(before) - len(before.rstrip(b"\x00"))
    after_padding = len(after) - len(after.rstrip(b"\x00"))
    if not (1 <= before_padding <= 16) or not (1 <= after_padding <= 4096):
        raise ValidationError("zboot post-payload alignment padding is outside policy")
    canonical = before.rstrip(b"\x00") + b"\x00" + after.rstrip(b"\x00")
    return canonical, before_padding, after_padding


def parse_arm64_image(data: bytes) -> None:
    if len(data) < 64 or data[56:60] != ARM64_IMAGE_MAGIC:
        raise ValidationError("decompressed zboot payload is not an ARM64 kernel Image")
    image_size = struct.unpack_from("<Q", data, 16)[0]
    if image_size not in (0, len(data)):
        raise ValidationError("ARM64 kernel Image size field does not match the payload")


def find_all(data: bytes, value: bytes) -> list[int]:
    result: list[int] = []
    start = 0
    while True:
        position = data.find(value, start)
        if position < 0:
            return result
        result.append(position)
        start = position + 1


def der_total_size(data: bytes, start: int) -> int | None:
    if start + 2 > len(data) or data[start] != 0x30:
        return None
    first = data[start + 1]
    if first < 0x80:
        header = 2
        body = first
    else:
        count = first & 0x7F
        if count == 0 or count > 4 or start + 2 + count > len(data):
            return None
        raw = data[start + 2 : start + 2 + count]
        if raw[0] == 0:
            return None
        header = 2 + count
        body = int.from_bytes(raw, "big")
        if body < 0x80:
            return None
    total = header + body
    if total > 64 * 1024 or start + total > len(data):
        return None
    return total


def find_build_certificate(data: bytes) -> tuple[int, int]:
    phrase = b"Build time autogenerated kernel key"
    phrase_positions = find_all(data, phrase)
    if not (1 <= len(phrase_positions) <= 4):
        raise ValidationError("kernel Image build certificate identity is absent or ambiguous")
    candidates_set: set[tuple[int, int]] = set()
    for phrase_position in phrase_positions:
        lower = max(0, phrase_position - 64 * 1024)
        for start in range(lower, phrase_position):
            total = der_total_size(data, start)
            if total is not None and start + total >= phrase_position + len(phrase) and total >= 512:
                candidates_set.add((start, total))
    candidates = sorted(candidates_set)
    outer = [
        candidate
        for candidate in candidates
        if not any(
            other[0] <= candidate[0]
            and other[0] + other[1] >= candidate[0] + candidate[1]
            and other != candidate
            for other in candidates
        )
    ]
    if len(outer) != 1:
        raise ValidationError("kernel Image build certificate boundary is ambiguous")
    return outer[0]


def parse_cpio_at(data: bytes, start: int) -> CpioArchive | None:
    position = start
    entries: list[tuple[str, int, int, int]] = []
    for _index in range(MAX_CPIO_ENTRIES):
        if position + 110 > len(data) or data[position : position + 6] not in (b"070701", b"070702"):
            return None
        fields: list[int] = []
        try:
            for field_index in range(13):
                raw = data[position + 6 + field_index * 8 : position + 14 + field_index * 8]
                if len(raw) != 8 or any(character not in b"0123456789abcdefABCDEF" for character in raw):
                    return None
                fields.append(int(raw, 16))
        except ValueError:
            return None
        file_size = fields[6]
        name_size = fields[11]
        if not (1 <= name_size <= MAX_CPIO_NAME_BYTES) or file_size > MAX_INNER_IMAGE_BYTES:
            return None
        name_start = position + 110
        name_end = name_start + name_size
        if name_end > len(data) or data[name_end - 1] != 0:
            return None
        try:
            name = data[name_start : name_end - 1].decode("utf-8")
        except UnicodeDecodeError:
            return None
        try:
            canonical_name = "TRAILER!!!" if name == "TRAILER!!!" else DEB.canonical_member_name(name)
        except ValidationError:
            return None
        data_start = (name_end + 3) & ~3
        data_end = data_start + file_size
        if data_end > len(data):
            return None
        mtime_start = position + 46
        entries.append((canonical_name, file_size, mtime_start, fields[5]))
        position = (data_end + 3) & ~3
        if canonical_name == "TRAILER!!!":
            if len(entries) < 2:
                return None
            return CpioArchive(start, position, tuple(entries))
    raise ValidationError("built-in cpio archive exceeds the entry limit")


def find_cpio_archives(data: bytes) -> tuple[CpioArchive, ...]:
    archives: list[CpioArchive] = []
    cursor = 0
    while True:
        position = data.find(b"07070", cursor)
        if position < 0:
            break
        archive = parse_cpio_at(data, position)
        if archive is None:
            cursor = position + 1
        else:
            archives.append(archive)
            cursor = archive.end
    if not archives:
        raise ValidationError("kernel Image contains no bounded built-in newc archive")
    return tuple(archives)


def add_span(
    spans: dict[str, list[tuple[int, int]]], label: str, start: int, end: int, size: int
) -> None:
    if start < 0 or end <= start or end > size:
        raise ValidationError("kernel Image normalization span is out of bounds")
    for values in spans.values():
        for other_start, other_end in values:
            if start < other_end and other_start < end:
                raise ValidationError("kernel Image normalization spans overlap")
    spans.setdefault(label, []).append((start, end))


def normalize_kernel_images(
    first: bytes, second: bytes, host_a: bytes, host_b: bytes
) -> tuple[bytes, dict[str, int]]:
    if len(first) != len(second):
        raise ValidationError("decompressed kernel Images have different sizes")
    spans_a: dict[str, list[tuple[int, int]]] = {}
    spans_b: dict[str, list[tuple[int, int]]] = {}
    host_positions_a = find_all(first, host_a)
    host_positions_b = find_all(second, host_b)
    if not host_positions_a or host_positions_a != host_positions_b or len(host_a) != len(host_b):
        raise ValidationError("kernel Image build-host identities have incompatible locations")
    for position in host_positions_a:
        add_span(spans_a, "host", position, position + len(host_a), len(first))
        add_span(spans_b, "host", position, position + len(host_b), len(second))

    timestamps_a = [(match.start(), match.end()) for match in TIMESTAMP_PATTERN.finditer(first)]
    timestamps_b = [(match.start(), match.end()) for match in TIMESTAMP_PATTERN.finditer(second)]
    if not timestamps_a or timestamps_a != timestamps_b:
        raise ValidationError("kernel Image build timestamps have incompatible locations")
    for start, end in timestamps_a:
        add_span(spans_a, "timestamp", start, end, len(first))
        add_span(spans_b, "timestamp", start, end, len(second))

    note_prefix = b"\x04\x00\x00\x00\x14\x00\x00\x00\x03\x00\x00\x00GNU\x00"
    notes_a = find_all(first, note_prefix)
    notes_b = find_all(second, note_prefix)
    if not notes_a or notes_a != notes_b:
        raise ValidationError("kernel Image GNU build-ID note is absent or ambiguous")
    changed_notes = [
        position
        for position in notes_a
        if first[position + len(note_prefix) : position + len(note_prefix) + 20]
        != second[position + len(note_prefix) : position + len(note_prefix) + 20]
    ]
    if len(changed_notes) != 1:
        raise ValidationError("kernel Image does not have exactly one changed GNU build-ID note")
    changed_note = changed_notes[0]
    desc_a = first[changed_note + len(note_prefix) : changed_note + len(note_prefix) + 20]
    desc_b = second[changed_note + len(note_prefix) : changed_note + len(note_prefix) + 20]
    copies_a = find_all(first, desc_a)
    copies_b = find_all(second, desc_b)
    if desc_a == desc_b or not copies_a or copies_a != copies_b:
        raise ValidationError("kernel Image build-ID values are not pairwise attributable")
    for position in copies_a:
        add_span(spans_a, "build_id", position, position + 20, len(first))
        add_span(spans_b, "build_id", position, position + 20, len(second))

    certificate_a = find_build_certificate(first)
    certificate_b = find_build_certificate(second)
    if certificate_a != certificate_b:
        raise ValidationError("kernel Image build certificates have incompatible regions")
    add_span(spans_a, "certificate", certificate_a[0], sum(certificate_a), len(first))
    add_span(spans_b, "certificate", certificate_b[0], sum(certificate_b), len(second))

    cpio_a = find_cpio_archives(first)
    cpio_b = find_cpio_archives(second)
    shape_a = tuple(tuple((name, size, offset - archive.start) for name, size, offset, _mtime in archive.entries) for archive in cpio_a)
    shape_b = tuple(tuple((name, size, offset - archive.start) for name, size, offset, _mtime in archive.entries) for archive in cpio_b)
    locations_a = tuple((archive.start, archive.end) for archive in cpio_a)
    locations_b = tuple((archive.start, archive.end) for archive in cpio_b)
    if shape_a != shape_b or locations_a != locations_b:
        raise ValidationError("kernel Image built-in cpio structures differ")
    for archive_a, archive_b in zip(cpio_a, cpio_b):
        for entry_a, entry_b in zip(archive_a.entries, archive_b.entries):
            start_a = entry_a[2]
            start_b = entry_b[2]
            add_span(spans_a, "cpio_mtime", start_a, start_a + 8, len(first))
            add_span(spans_b, "cpio_mtime", start_b, start_b + 8, len(second))

    normalized_a = bytearray(first)
    normalized_b = bytearray(second)
    for label in sorted(spans_a):
        if spans_a[label] != spans_b.get(label):
            raise ValidationError("kernel Image normalization locations differ")
        for start, end in spans_a[label]:
            normalized_a[start:end] = b"\x00" * (end - start)
            normalized_b[start:end] = b"\x00" * (end - start)
    if normalized_a != normalized_b:
        raise ValidationError("kernel Image contains unclassified payload differences")
    counts: dict[str, int] = {}
    covered: set[int] = set()
    for label, spans in spans_a.items():
        changed = 0
        changed_fields = 0
        for start, end in spans:
            field_changed = False
            for position in range(start, end):
                if first[position] != second[position]:
                    changed += 1
                    covered.add(position)
                    field_changed = True
            changed_fields += int(field_changed)
        counts[label] = changed
        counts[label + "_fields"] = changed_fields
    all_changed = {position for position, (left, right) in enumerate(zip(first, second)) if left != right}
    if covered != all_changed:
        raise ValidationError("kernel Image changed-byte accounting is incomplete")
    counts["total"] = len(all_changed)
    counts["host_occurrences"] = len(host_positions_a)
    counts["timestamp_occurrences"] = len(timestamps_a)
    counts["cpio_archives"] = len(cpio_a)
    return bytes(normalized_a), counts


def system_map_bounds(data: bytes) -> tuple[int, int]:
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ValidationError("System.map is not ASCII") from exc
    symbols: dict[str, int] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 3 or not re.fullmatch(r"[0-9a-fA-F]{16}", parts[0]):
            raise ValidationError("System.map contains a malformed row")
        name = parts[2]
        if name in ("_text", "_etext"):
            if name in symbols:
                raise ValidationError("System.map contains a duplicate code-boundary symbol")
            symbols[name] = int(parts[0], 16)
    if set(symbols) != {"_text", "_etext"} or symbols["_etext"] <= symbols["_text"]:
        raise ValidationError("System.map lacks valid kernel code boundaries")
    return symbols["_text"], symbols["_etext"]


def parse_elf(data: bytes, label: str) -> ELFImage:
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or data[6] != 1:
        raise ValidationError(f"{label} is not a little-endian ELF64 image")
    header = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    (
        elf_type,
        machine,
        version,
        _entry,
        program_offset,
        section_offset,
        _flags,
        header_size,
        program_entry_size,
        program_count,
        section_entry_size,
        section_count,
        string_index,
    ) = header
    if (
        elf_type != 1
        or machine != 183
        or version != 1
        or header_size != 64
        or program_offset != 0
        or program_entry_size != 0
        or program_count != 0
        or section_entry_size != 64
        or not (1 <= section_count <= MAX_ELF_SECTIONS)
        or string_index >= section_count
        or section_offset + section_count * 64 > len(data)
    ):
        raise ValidationError(f"{label} has an unsupported ELF layout")
    raw_sections = [
        struct.unpack_from("<IIQQQQIIQQ", data, section_offset + index * 64)
        for index in range(section_count)
    ]
    string_section = raw_sections[string_index]
    if string_section[1] != 3 or string_section[4] + string_section[5] > len(data):
        raise ValidationError(f"{label} has an invalid ELF section-name table")
    names = data[string_section[4] : string_section[4] + string_section[5]]
    sections: list[ELFSection] = []
    occupied: list[tuple[int, int]] = []
    seen_names: set[str] = set()
    for index, raw in enumerate(raw_sections):
        name_offset, section_type, flags, address, offset, size, link, info, alignment, entry_size = raw
        if name_offset >= len(names):
            raise ValidationError(f"{label} has an invalid ELF section name")
        end = names.find(b"\x00", name_offset)
        if end < 0:
            raise ValidationError(f"{label} has an unterminated ELF section name")
        try:
            name = names[name_offset:end].decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValidationError(f"{label} has a non-ASCII ELF section name") from exc
        if name in seen_names and name:
            raise ValidationError(f"{label} has a duplicate ELF section name")
        seen_names.add(name)
        if section_type != 8 and size:
            if offset + size > len(data):
                raise ValidationError(f"{label} has an out-of-bounds ELF section")
            occupied.append((offset, offset + size))
            section_data = data[offset : offset + size]
        else:
            section_data = b""
        sections.append(
            ELFSection(
                index,
                name,
                section_type,
                flags,
                address,
                offset,
                size,
                link,
                info,
                alignment,
                entry_size,
                section_data,
            )
        )
    occupied.sort()
    if any(left[1] > right[0] for left, right in zip(occupied, occupied[1:])):
        raise ValidationError(f"{label} has overlapping ELF sections")
    return ELFImage(section_offset, tuple(sections))


def elf_section(image: ELFImage, name: str, label: str) -> ELFSection:
    matches = [section for section in image.sections if section.name == name]
    if len(matches) != 1:
        raise ValidationError(f"{label} lacks exactly one {name} section")
    return matches[0]


def validate_build_id_note(data: bytes) -> None:
    prefix = b"\x04\x00\x00\x00\x14\x00\x00\x00\x03\x00\x00\x00GNU\x00"
    if len(data) != 36 or not data.startswith(prefix):
        raise ValidationError("kheaders GNU build-ID note has an unsupported layout")


def scan_kheaders_archive(data: bytes) -> ArchiveScan:
    with DEB.decompressed_stream(io.BytesIO(data), "xz") as decoded:
        return scan_tar_stream(decoded, MAX_KHEADERS_TAR_BYTES, "kheaders", None)


def compare_kheaders(
    first: ModuleRecord, second: ModuleRecord
) -> tuple[str, int]:
    if first.kheaders_payload is None or second.kheaders_payload is None:
        raise ValidationError("kheaders module payload was not retained")
    elf_a = parse_elf(first.kheaders_payload, "kheaders module")
    elf_b = parse_elf(second.kheaders_payload, "kheaders module")
    if tuple(section.name for section in elf_a.sections) != tuple(section.name for section in elf_b.sections):
        raise ValidationError("kheaders ELF section sets differ")
    rodata_a = elf_section(elf_a, ".rodata", "kheaders module")
    rodata_b = elf_section(elf_b, ".rodata", "kheaders module")
    if rodata_a.offset != rodata_b.offset:
        raise ValidationError("kheaders archive section offsets are incompatible")
    size_delta = rodata_a.size - rodata_b.size
    if elf_a.section_table_offset - rodata_a.size != elf_b.section_table_offset - rodata_b.size:
        raise ValidationError("kheaders section-table layout is not derived from archive size")
    variable_sections = {
        ".rodata",
        ".note.gnu.build-id",
        ".rela.data..ro_after_init",
        ".symtab",
    }
    for left, right in zip(elf_a.sections, elf_b.sections):
        metadata_a = (
            left.name,
            left.section_type,
            left.flags,
            left.address,
            left.offset if left.offset <= rodata_a.offset else left.offset - rodata_a.size,
            0 if left.name == ".rodata" else left.size,
            left.link,
            left.info,
            left.alignment,
            left.entry_size,
        )
        metadata_b = (
            right.name,
            right.section_type,
            right.flags,
            right.address,
            right.offset if right.offset <= rodata_b.offset else right.offset - rodata_b.size,
            0 if right.name == ".rodata" else right.size,
            right.link,
            right.info,
            right.alignment,
            right.entry_size,
        )
        if metadata_a != metadata_b:
            raise ValidationError("kheaders ELF layout differs outside archive-size derivations")
        if left.name not in variable_sections and left.data != right.data:
            raise ValidationError("kheaders ELF contains an unknown section-content difference")
    build_id_a = elf_section(elf_a, ".note.gnu.build-id", "kheaders module")
    build_id_b = elf_section(elf_b, ".note.gnu.build-id", "kheaders module")
    validate_build_id_note(build_id_a.data)
    validate_build_id_note(build_id_b.data)
    if build_id_a.data[:16] != build_id_b.data[:16]:
        raise ValidationError("kheaders build-ID note metadata differs")

    relocation_a = elf_section(elf_a, ".rela.data..ro_after_init", "kheaders module")
    relocation_b = elf_section(elf_b, ".rela.data..ro_after_init", "kheaders module")
    if len(relocation_a.data) != len(relocation_b.data) or len(relocation_a.data) % 24:
        raise ValidationError("kheaders relocation section has an unsupported size")
    for index in range(0, len(relocation_a.data), 24):
        row_a = struct.unpack_from("<QQq", relocation_a.data, index)
        row_b = struct.unpack_from("<QQq", relocation_b.data, index)
        if index == 0:
            if row_a[:2] != row_b[:2] or row_a[2] != rodata_a.size - 16 or row_b[2] != rodata_b.size - 16:
                raise ValidationError("kheaders archive-end relocation is not size-derived")
        elif row_a != row_b:
            raise ValidationError("kheaders contains an unknown relocation difference")

    symtab_a = elf_section(elf_a, ".symtab", "kheaders module")
    symtab_b = elf_section(elf_b, ".symtab", "kheaders module")
    strtab_a = elf_section(elf_a, ".strtab", "kheaders module")
    strtab_b = elf_section(elf_b, ".strtab", "kheaders module")
    if strtab_a.data != strtab_b.data or len(symtab_a.data) != len(symtab_b.data) or len(symtab_a.data) % 24:
        raise ValidationError("kheaders symbol tables are incompatible")
    derived_symbols = {"$d": 16, "kernel_headers_data_end": 20}
    seen_derived: set[str] = set()
    for index in range(0, len(symtab_a.data), 24):
        row_a = struct.unpack_from("<IBBHQQ", symtab_a.data, index)
        row_b = struct.unpack_from("<IBBHQQ", symtab_b.data, index)
        name_offset = row_a[0]
        if name_offset >= len(strtab_a.data):
            raise ValidationError("kheaders symbol name is out of bounds")
        end = strtab_a.data.find(b"\x00", name_offset)
        if end < 0:
            raise ValidationError("kheaders symbol name is unterminated")
        name = strtab_a.data[name_offset:end].decode("ascii")
        if name in derived_symbols and row_a != row_b:
            adjustment = derived_symbols[name]
            if (
                row_a[:4] != row_b[:4]
                or row_a[3] != rodata_a.index
                or row_a[4] != rodata_a.size - adjustment
                or row_b[4] != rodata_b.size - adjustment
                or row_a[5] != row_b[5]
            ):
                raise ValidationError("kheaders archive-end symbol is not size-derived")
            seen_derived.add(name)
        elif row_a != row_b:
            raise ValidationError("kheaders contains an unknown symbol-table difference")
    if size_delta and seen_derived != set(derived_symbols):
        raise ValidationError("kheaders expected archive-size-derived symbols were not observed")

    kheaders_suffix = b"\x00\x00\x00\x00kheaders.tar.xz\x00"
    if not rodata_a.data.endswith(kheaders_suffix) or not rodata_b.data.endswith(kheaders_suffix):
        raise ValidationError("kheaders archive section has unknown trailing data")
    archive_a = scan_kheaders_archive(rodata_a.data[: -len(kheaders_suffix)])
    archive_b = scan_kheaders_archive(rodata_b.data[: -len(kheaders_suffix)])
    compare_archive_shape(archive_a, archive_b)
    if set(archive_a.records) != set(archive_b.records):
        raise ValidationError("kheaders archive path sets differ")
    compile_paths = [path for path in archive_a.records if is_compile_header_path(path)]
    if len(compile_paths) != 1:
        raise ValidationError("kheaders archive lacks exactly one compile.h")
    compile_path = compile_paths[0]
    if compile_path not in archive_a.captures or compile_path not in archive_b.captures:
        raise ValidationError("kheaders compile.h was not retained")
    _host_a, _host_b, changed = normalize_compile_header(
        archive_a.captures[compile_path], archive_b.captures[compile_path]
    )
    records: list[dict[str, object]] = []
    for path in sorted(archive_a.records):
        left = archive_a.records[path]
        right = archive_b.records[path]
        digest = left.sha256
        if path == compile_path:
            normalized, _other, _changed = normalize_compile_header(
                archive_a.captures[path], archive_b.captures[path]
            )
            canonical = COMPILE_HOST_PATTERN.sub(
                lambda match: match.group(0).replace(match.group(1), b"H" * len(match.group(1))),
                archive_a.captures[path],
            )
            digest = hashlib.sha256(canonical).hexdigest()
        elif left.kind == "file" and left.sha256 != right.sha256:
            raise ValidationError("kheaders archive contains an unknown file-content difference")
        records.append(
            {
                "path": path,
                "kind": left.kind,
                "mode": left.mode,
                "uid": left.uid,
                "gid": left.gid,
                "uname": left.uname,
                "gname": left.gname,
                "target": left.target,
                "size": left.size if path != compile_path else len(archive_a.captures[path]),
                "mtime": 0,
                "sha256": digest,
            }
        )
    return inventory_digest(records), changed


def compare_vmlinuz(
    first: bytes,
    second: bytes,
    system_map: bytes,
    host_a: bytes,
    host_b: bytes,
    packaged_surface_dtb: bytes,
) -> dict[str, str | int]:
    outer_a = parse_pe(first, "outer kernel image")
    outer_b = parse_pe(second, "outer kernel image")
    if len(outer_a.sections) != len(outer_b.sections):
        raise ValidationError("outer kernel PE section counts differ")
    linux_a = single_pe_section(outer_a, ".linux", "outer kernel image")
    linux_b = single_pe_section(outer_b, ".linux", "outer kernel image")
    if (linux_a.raw_offset, linux_a.raw_size) != (linux_b.raw_offset, linux_b.raw_size):
        raise ValidationError("outer kernel PE linux sections have incompatible layout")
    compare_outside_range(first, second, linux_a.raw_offset, linux_a.raw_size, "outer kernel image")
    dtbs_a = [parse_dtb(section) for section in outer_a.sections if section.name == ".dtbauto"]
    dtbs_b = [parse_dtb(section) for section in outer_b.sections if section.name == ".dtbauto"]
    if not dtbs_a or dtbs_a != dtbs_b:
        raise ValidationError("Stubble embedded DTB inventories differ")
    matching_surface = [index for index, data in enumerate(dtbs_a) if data == packaged_surface_dtb]
    if matching_surface != [7]:
        raise ValidationError("packaged Surface Pro 11 DTB does not match dtbauto index 7")
    dtb_aggregate = inventory_digest(
        {"index": index, "sha256": hashlib.sha256(data).hexdigest()}
        for index, data in enumerate(dtbs_a)
    )

    nested_a = parse_pe(linux_a.data, "nested zboot image")
    nested_b = parse_pe(linux_b.data, "nested zboot image")
    text_a = single_pe_section(nested_a, ".text", "nested zboot image")
    text_b = single_pe_section(nested_b, ".text", "nested zboot image")
    if (text_a.raw_offset, text_a.raw_size) != (text_b.raw_offset, text_b.raw_size):
        raise ValidationError("nested zboot text sections have incompatible layout")
    if (
        len(linux_a.data) != len(linux_b.data)
        or linux_a.data[:12] != linux_b.data[:12]
        or linux_a.data[16 : text_a.raw_offset] != linux_b.data[16 : text_b.raw_offset]
        or linux_a.data[text_a.raw_offset + text_a.raw_size :]
        != linux_b.data[text_b.raw_offset + text_b.raw_size :]
        or linux_a.data[4:8] != b"zimg"
        or linux_a.data[24:28] != b"zstd"
        or struct.unpack_from("<I", linux_a.data, 8)[0]
        != text_a.raw_offset + text_a.data.find(ZSTD_MAGIC)
        or struct.unpack_from("<I", linux_b.data, 8)[0]
        != text_b.raw_offset + text_b.data.find(ZSTD_MAGIC)
    ):
        raise ValidationError("nested zboot image differs outside text and its payload-size field")
    frame_start_a = text_a.data.find(ZSTD_MAGIC)
    frame_start_b = text_b.data.find(ZSTD_MAGIC)
    if frame_start_a < 0 or frame_start_a != frame_start_b:
        raise ValidationError("nested zboot payload locations differ")
    frame_end_a, content_size_a = zstd_frame_end(text_a.data, frame_start_a)
    frame_end_b, content_size_b = zstd_frame_end(text_b.data, frame_start_b)
    frame_a = text_a.data[frame_start_a:frame_end_a]
    frame_b = text_b.data[frame_start_b:frame_end_b]
    if (
        struct.unpack_from("<I", linux_a.data, 12)[0] != len(frame_a)
        or struct.unpack_from("<I", linux_b.data, 12)[0] != len(frame_b)
    ):
        raise ValidationError("nested zboot payload-size field does not match its Zstandard frame")
    image_a = decompress_zstd_frame(frame_a)
    image_b = decompress_zstd_frame(frame_b)
    if content_size_a not in (None, len(image_a)) or content_size_b not in (None, len(image_b)):
        raise ValidationError("zboot Zstandard content-size field is inconsistent")
    parse_arm64_image(image_a)
    parse_arm64_image(image_b)
    add_count, ldr_count = classify_zboot_prefix(
        text_a.data[:frame_start_a], text_b.data[:frame_start_b]
    )
    suffix_a, before_pad_a, after_pad_a = canonical_zboot_suffix(text_a.data[frame_end_a:])
    suffix_b, before_pad_b, after_pad_b = canonical_zboot_suffix(text_b.data[frame_end_b:])
    if suffix_a != suffix_b:
        raise ValidationError("zboot post-payload bytes differ outside alignment padding")
    normalized, counts = normalize_kernel_images(image_a, image_b, host_a, host_b)
    text_start, text_end = system_map_bounds(system_map)
    code_size = text_end - text_start
    if code_size > len(image_a):
        raise ValidationError("System.map kernel code range exceeds the Image")
    code_a = image_a[:code_size]
    code_b = image_b[:code_size]
    if code_a != code_b:
        raise ValidationError("kernel _text.._etext code bytes differ")
    return {
        "vmlinuz_a_sha256": hashlib.sha256(first).hexdigest(),
        "vmlinuz_b_sha256": hashlib.sha256(second).hexdigest(),
        "vmlinuz_size": len(first),
        "dtbauto_count": len(dtbs_a),
        "dtbauto_aggregate": dtb_aggregate,
        "zboot_frame_a_sha256": hashlib.sha256(frame_a).hexdigest(),
        "zboot_frame_b_sha256": hashlib.sha256(frame_b).hexdigest(),
        "zboot_frame_a_size": len(frame_a),
        "zboot_frame_b_size": len(frame_b),
        "zboot_add_immediates": add_count,
        "zboot_ldr_immediates": ldr_count,
        "zboot_before_padding_a": before_pad_a,
        "zboot_before_padding_b": before_pad_b,
        "zboot_after_padding_a": after_pad_a,
        "zboot_after_padding_b": after_pad_b,
        "image_a_sha256": hashlib.sha256(image_a).hexdigest(),
        "image_b_sha256": hashlib.sha256(image_b).hexdigest(),
        "image_size": len(image_a),
        "normalized_image_sha256": hashlib.sha256(normalized).hexdigest(),
        "kernel_code_sha256": hashlib.sha256(code_a).hexdigest(),
        "kernel_code_size": code_size,
        "image_changed_bytes": counts["total"],
        "image_host_changed_bytes": counts["host"],
        "image_timestamp_changed_bytes": counts["timestamp"],
        "image_certificate_changed_bytes": counts["certificate"],
        "image_build_id_changed_bytes": counts["build_id"],
        "image_cpio_mtime_changed_bytes": counts["cpio_mtime"],
        "image_host_occurrences": counts["host_occurrences"],
        "image_timestamp_occurrences": counts["timestamp_occurrences"],
        "image_cpio_mtime_fields": counts["cpio_mtime_fields"],
    }


def required_capture(scan: ArchiveScan, pattern: str, label: str) -> tuple[str, bytes]:
    matches = [(path, data) for path, data in scan.captures.items() if re.fullmatch(pattern, path)]
    if len(matches) != 1:
        raise ValidationError(f"package lacks exactly one {label}")
    return matches[0]


def compare_builds(path_a: Path, path_b: Path) -> ComparisonResult:
    opened_a: OpenBuild | None = None
    opened_b: OpenBuild | None = None
    try:
        # Retain all eight validated no-follow descriptors before any deep parser runs.
        opened_a = open_historical_build(path_a, "A")
        opened_b = open_historical_build(path_b, "B")
        result = compare_open_builds(opened_a, opened_b)
        validate_open_build_stable(opened_a)
        validate_open_build_stable(opened_b)
        return result
    finally:
        close_open_build(opened_b)
        close_open_build(opened_a)


def compare_open_builds(opened_a: OpenBuild, opened_b: OpenBuild) -> ComparisonResult:
    packages_a = scan_build(opened_a)
    packages_b = scan_build(opened_b)
    if set(packages_a) != set(packages_b):
        raise ValidationError("adjacent builds have different package role sets")
    for role in packages_a:
        if packages_a[role].identity != packages_b[role].identity:
            raise ValidationError("adjacent builds have different package identities")
    values: dict[str, str | int | bool] = {}
    mtime_changes = 0
    for role in sorted(packages_a, key=ROLE_ORDER.index):
        first = packages_a[role]
        second = packages_b[role]
        if tuple((name, size) for name, size, _digest in first.ar_members) != tuple(
            (name, size) for name, size, _digest in second.ar_members
        ):
            # Compressed member sizes may differ; member names, not sizes, are semantic.
            if tuple(name for name, _size, _digest in first.ar_members) != tuple(
                name for name, _size, _digest in second.ar_members
            ):
                raise ValidationError("paired Debian archives have different ar member sets")
        mtime_changes += compare_archive_shape(first.control, second.control)
        mtime_changes += compare_archive_shape(first.data, second.data)
        compare_control(first, second)
    values["archive_mtime_changes"] = mtime_changes

    headers_a = packages_a["headers"]
    headers_b = packages_b["headers"]
    compile_path_a, compile_a = required_capture(
        headers_a.data, r"usr/src/[^/]+/include/generated/compile\.h", "generated compile.h"
    )
    compile_path_b, compile_b = required_capture(
        headers_b.data, r"usr/src/[^/]+/include/generated/compile\.h", "generated compile.h"
    )
    if compile_path_a != compile_path_b:
        raise ValidationError("paired header packages place compile.h at different paths")
    host_a, host_b, compile_changed = normalize_compile_header(compile_a, compile_b)
    values["compile_header_changed_bytes"] = compile_changed

    for role in sorted(packages_a, key=ROLE_ORDER.index):
        first = packages_a[role]
        second = packages_b[role]
        for path in sorted(first.data.records):
            left = first.data.records[path]
            right = second.data.records[path]
            if left.kind != "file" or left.sha256 == right.sha256:
                continue
            if role == "headers" and path == compile_path_a:
                continue
            if role in ("modules", "modules-extra") and path in first.data.modules:
                continue
            if role == "modules" and path == f"boot/vmlinuz-{first.identity.abi}":
                continue
            raise ValidationError("package data contains an unknown file-content difference")

    modules_a: dict[str, ModuleRecord] = {}
    modules_b: dict[str, ModuleRecord] = {}
    for role in ("modules", "modules-extra"):
        if role in packages_a:
            modules_a.update(packages_a[role].data.modules)
            modules_b.update(packages_b[role].data.modules)
    if not modules_a or set(modules_a) != set(modules_b):
        raise ValidationError("adjacent builds have different module path sets")
    signed_count = 0
    unsigned_count = 0
    non_kheaders_records: list[dict[str, object]] = []
    kheaders_paths = [path for path in modules_a if path.endswith("/kernel/kernel/kheaders.ko.zst")]
    if len(kheaders_paths) != 1:
        raise ValidationError("module set lacks exactly one compressed kheaders module")
    kheaders_path = kheaders_paths[0]
    for path in sorted(modules_a):
        left = modules_a[path]
        right = modules_b[path]
        if (
            left.compression != right.compression
            or left.signed != right.signed
            or left.descriptor != right.descriptor
            or left.unsigned_size != right.unsigned_size and path != kheaders_path
        ):
            raise ValidationError("paired modules have incompatible signature or compression layouts")
        signed_count += int(left.signed)
        unsigned_count += int(not left.signed)
        if path == kheaders_path:
            continue
        if left.unsigned_sha256 != right.unsigned_sha256:
            raise ValidationError("module payload differs after validated signature removal")
        non_kheaders_records.append(
            {"path": path, "size": left.unsigned_size, "sha256": left.unsigned_sha256}
        )
    kheaders_aggregate, kheaders_compile_changed = compare_kheaders(
        modules_a[kheaders_path], modules_b[kheaders_path]
    )
    values.update(
        {
            "module_count": len(modules_a),
            "signed_module_count": signed_count,
            "unsigned_module_count": unsigned_count,
            "non_kheaders_module_count": len(non_kheaders_records),
            "non_kheaders_aggregate": inventory_digest(non_kheaders_records),
            "kheaders_aggregate": kheaders_aggregate,
            "kheaders_compile_changed_bytes": kheaders_compile_changed,
        }
    )

    module_package_a = packages_a["modules"]
    module_package_b = packages_b["modules"]
    system_path_a, system_map_a = required_capture(
        module_package_a.data, r"boot/System\.map-[^/]+", "System.map"
    )
    system_path_b, system_map_b = required_capture(
        module_package_b.data, r"boot/System\.map-[^/]+", "System.map"
    )
    if system_path_a != system_path_b or system_map_a != system_map_b:
        raise ValidationError("adjacent builds have different System.map payloads")
    vmlinuz_path_a, vmlinuz_a = required_capture(
        module_package_a.data, r"boot/vmlinuz-[^/]+", "vmlinuz"
    )
    vmlinuz_path_b, vmlinuz_b = required_capture(
        module_package_b.data, r"boot/vmlinuz-[^/]+", "vmlinuz"
    )
    if vmlinuz_path_a != vmlinuz_path_b:
        raise ValidationError("adjacent builds place vmlinuz at different paths")
    dtb_rows_a = [
        (path, record)
        for path, record in module_package_a.data.records.items()
        if path.endswith(".dtb") and record.kind == "file"
    ]
    dtb_rows_b = [
        (path, record)
        for path, record in module_package_b.data.records.items()
        if path.endswith(".dtb") and record.kind == "file"
    ]
    if not dtb_rows_a or [(p, r.sha256) for p, r in dtb_rows_a] != [(p, r.sha256) for p, r in dtb_rows_b]:
        raise ValidationError("packaged DTB inventories differ")
    surface_matches = [
        (path, record)
        for path, record in dtb_rows_a
        if path.endswith("/x1e80100-microsoft-denali-oled.dtb")
    ]
    if len(surface_matches) != 1:
        raise ValidationError("packaged DTB inventory lacks exactly one SP11 OLED DTB")
    surface_path = surface_matches[0][0]
    surface_content = module_package_a.data.captures.get(surface_path)
    if surface_content is None:
        # DTBs are bounded by the data member size; retain only the one required for cross-layer binding.
        raise ValidationError("SP11 OLED DTB was not retained for Stubble binding")
    values["packaged_dtb_count"] = len(dtb_rows_a)
    values["packaged_dtb_aggregate"] = inventory_digest(
        {"path": path, "sha256": record.sha256} for path, record in sorted(dtb_rows_a)
    )
    values["surface_dtb_sha256"] = surface_matches[0][1].sha256
    values.update(
        compare_vmlinuz(
            vmlinuz_a,
            vmlinuz_b,
            system_map_a,
            host_a,
            host_b,
            surface_content,
        )
    )
    return ComparisonResult(packages_a, packages_b, values)


def render_report(result: ComparisonResult) -> str:
    lines = [
        f"Kernel adjacent comparison schema: {SCHEMA}",
        f"Semantic policy: {POLICY}",
        f"Aggregate encoding: {AGGREGATE_SCHEMA}",
        "Published aggregate reference binding: exact directional historical raw allowlist",
        f"Package count: {len(result.packages_a)}",
    ]
    raw_differences = 0
    for index, role in enumerate((role for role in ROLE_ORDER if role in result.packages_a), 1):
        first = result.packages_a[role]
        second = result.packages_b[role]
        raw_differences += int(first.sha256 != second.sha256)
        lines.extend(
            (
                f"Package {index} role: {role}",
                f"Package {index} name: {first.identity.package}",
                f"Package {index} version: {first.identity.version}",
                f"Package {index} architecture: {first.identity.architecture}",
                f"Package {index} A size: {first.size}",
                f"Package {index} A SHA256: {first.sha256}",
                f"Package {index} B size: {second.size}",
                f"Package {index} B SHA256: {second.sha256}",
                f"Package {index} raw identical: {'true' if first.sha256 == second.sha256 else 'false'}",
            )
        )
    values = result.values
    lines.extend(
        (
            f"Raw differing package count: {raw_differences}",
            f"Archive member mtime difference count: {values['archive_mtime_changes']}",
            f"Header compile-host changed bytes: {values['compile_header_changed_bytes']}",
            f"Packaged DTB count: {values['packaged_dtb_count']}",
            f"Packaged DTB v1 JSON-lines aggregate SHA256: {values['packaged_dtb_aggregate']}",
            "Published historical packaged DTB aggregate reference SHA256: "
            + PUBLISHED_HISTORICAL_AGGREGATES["packaged-dtb"],
            f"SP11 OLED DTB SHA256: {values['surface_dtb_sha256']}",
            f"Stubble dtbauto count: {values['dtbauto_count']}",
            f"Stubble dtbauto v1 JSON-lines aggregate SHA256: {values['dtbauto_aggregate']}",
            "Published historical Stubble dtbauto aggregate reference SHA256: "
            + PUBLISHED_HISTORICAL_AGGREGATES["dtbauto"],
            f"Vmlinuz A size: {values['vmlinuz_size']}",
            f"Vmlinuz A SHA256: {values['vmlinuz_a_sha256']}",
            f"Vmlinuz B size: {values['vmlinuz_size']}",
            f"Vmlinuz B SHA256: {values['vmlinuz_b_sha256']}",
            f"Zboot frame A size: {values['zboot_frame_a_size']}",
            f"Zboot frame A SHA256: {values['zboot_frame_a_sha256']}",
            f"Zboot frame B size: {values['zboot_frame_b_size']}",
            f"Zboot frame B SHA256: {values['zboot_frame_b_sha256']}",
            f"Zboot changed ADD immediate words: {values['zboot_add_immediates']}",
            f"Zboot changed LDR immediate words: {values['zboot_ldr_immediates']}",
            f"Kernel Image A size: {values['image_size']}",
            f"Kernel Image A SHA256: {values['image_a_sha256']}",
            f"Kernel Image B size: {values['image_size']}",
            f"Kernel Image B SHA256: {values['image_b_sha256']}",
            f"Kernel Image changed bytes: {values['image_changed_bytes']}",
            f"Kernel Image compile-host changed bytes: {values['image_host_changed_bytes']}",
            f"Kernel Image timestamp changed bytes: {values['image_timestamp_changed_bytes']}",
            f"Kernel Image certificate changed bytes: {values['image_certificate_changed_bytes']}",
            f"Kernel Image build-ID changed bytes: {values['image_build_id_changed_bytes']}",
            f"Kernel Image cpio-mtime changed bytes: {values['image_cpio_mtime_changed_bytes']}",
            f"Normalized Kernel Image SHA256: {values['normalized_image_sha256']}",
            f"Kernel _text.._etext size: {values['kernel_code_size']}",
            f"Kernel _text.._etext SHA256: {values['kernel_code_sha256']}",
            f"Module count: {values['module_count']}",
            f"Signed module count: {values['signed_module_count']}",
            f"Unsigned module count: {values['unsigned_module_count']}",
            f"Non-kheaders module count: {values['non_kheaders_module_count']}",
            f"Non-kheaders v1 JSON-lines normalized aggregate SHA256: {values['non_kheaders_aggregate']}",
            "Published historical non-kheaders aggregate reference SHA256: "
            + PUBLISHED_HISTORICAL_AGGREGATES["non-kheaders-modules"],
            f"Kheaders v1 JSON-lines normalized aggregate SHA256: {values['kheaders_aggregate']}",
            "Published historical kheaders aggregate reference SHA256: "
            + PUBLISHED_HISTORICAL_AGGREGATES["kheaders"],
            f"Kheaders compile-host changed bytes: {values['kheaders_compile_changed_bytes']}",
            "Unknown payload difference count: 0",
            f"Semantic adjacent-pair equivalence: true",
            "Comparison completed: true",
        )
    )
    return "\n".join(lines) + "\n"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare two retained SP11 kernel Deb directories under a fail-closed historical policy."
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {SCHEMA}")
    parser.add_argument("--build-a", required=True, type=Path, metavar="DIR")
    parser.add_argument("--build-b", required=True, type=Path, metavar="DIR")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_args(argv)
    try:
        result = compare_builds(arguments.build_a, arguments.build_b)
        sys.stdout.write(render_report(result))
        return 0
    except ValidationError as exc:
        print(f"error: kernel adjacent comparison failed: {exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError, struct.error, UnicodeError):
        print("error: kernel adjacent comparison failed safely", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
