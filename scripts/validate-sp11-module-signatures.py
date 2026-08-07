#!/usr/bin/env python3
"""Inventory appended Linux module signatures in qcom-x1e module Debs."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import lzma
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import BinaryIO, Iterator


AR_MAGIC = b"!<arch>\n"
MODULE_SIGNATURE_MARKER = b"~Module signature appended~\n"
CONTROL_ARCHIVE_NAMES = {
    "control.tar",
    "control.tar.gz",
    "control.tar.xz",
    "control.tar.zst",
}
DATA_ARCHIVE_NAMES = {"data.tar", "data.tar.gz", "data.tar.xz", "data.tar.zst"}
COPY_CHUNK_BYTES = 1024 * 1024
MAX_PACKAGE_BYTES = 4 * 1024 * 1024 * 1024
MAX_CONTROL_BYTES = 1024 * 1024
MAX_CONTROL_TAR_BYTES = 64 * 1024 * 1024
MAX_DATA_TAR_BYTES = 16 * 1024 * 1024 * 1024
MAX_MODULE_BYTES = 1024 * 1024 * 1024
MAX_TOTAL_MODULE_BYTES = 16 * 1024 * 1024 * 1024
MAX_TAR_METADATA_BYTES = 8192
MAX_CONSECUTIVE_GNU_METADATA = 2
MAX_XZ_DECODER_MEMORY = 256 * 1024 * 1024
MAX_MEMBERS = 500_000
MAX_PATH_BYTES = 4096
PACKAGE_PATTERN = re.compile(r"linux-modules-(?:extra-)?[a-z0-9][a-z0-9.+~-]*\Z")
VERSION_PATTERN = re.compile(r"[0-9][0-9A-Za-z.+:~_-]*\Z")
ABI_PATTERN = re.compile(r"[a-z0-9][a-z0-9.+~-]*-qcom-x1e\Z")
CONTROL_FIELD_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*\Z")


class ValidationError(Exception):
    """An expected, path-neutral validation failure."""


@dataclass(frozen=True)
class ArMember:
    """One bounded member of a Debian ar archive."""

    name: str
    offset: int
    size: int


@dataclass(frozen=True)
class PackageIdentity:
    """Validated module-package identity."""

    role: str
    package: str
    version: str
    architecture: str
    abi: str


@dataclass(frozen=True)
class PackageScan:
    """A complete signature inventory for one stable input package."""

    identity: PackageIdentity
    sha256: str
    module_count: int
    signed_count: int
    unsigned_count: int
    compression_counts: tuple[int, int, int, int]


class PreadSlice(io.RawIOBase):
    """A seekable, bounded view over a read-only file descriptor."""

    def __init__(self, descriptor: int, offset: int, size: int) -> None:
        super().__init__()
        self._descriptor = descriptor
        self._offset = offset
        self._size = size
        self._position = 0

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self._position

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence == os.SEEK_SET:
            position = offset
        elif whence == os.SEEK_CUR:
            position = self._position + offset
        elif whence == os.SEEK_END:
            position = self._size + offset
        else:
            raise ValueError("unsupported seek mode")
        if position < 0:
            raise ValueError("negative seek position")
        self._position = min(position, self._size)
        return self._position

    def readinto(self, buffer: bytearray | memoryview) -> int:
        if self._position >= self._size:
            return 0
        requested = min(len(buffer), self._size - self._position)
        data = os.pread(self._descriptor, requested, self._offset + self._position)
        if not data and requested:
            raise ValidationError("package changed or became truncated during validation")
        buffer[: len(data)] = data
        self._position += len(data)
        return len(data)


class LimitedReader(io.RawIOBase):
    """Bound a decompressed stream and expose it to tarfile."""

    def __init__(self, source: BinaryIO, limit: int, label: str) -> None:
        super().__init__()
        self._source = source
        self._limit = limit
        self._label = label
        self._count = 0

    def readable(self) -> bool:
        return True

    def readinto(self, buffer: bytearray | memoryview) -> int:
        data = self._source.read(len(buffer))
        if data is None:
            return 0
        self._count += len(data)
        if self._count > self._limit:
            raise ValidationError(f"{self._label} exceeds the expanded-size limit")
        buffer[: len(data)] = data
        return len(data)


class ExactXZReader(io.RawIOBase):
    """Decode exactly one bounded XZ stream and reject trailing bytes."""

    def __init__(self, source: BinaryIO) -> None:
        super().__init__()
        self._source = source
        self._decoder = lzma.LZMADecompressor(
            format=lzma.FORMAT_XZ, memlimit=MAX_XZ_DECODER_MEMORY
        )
        self._done = False

    def readable(self) -> bool:
        return True

    def _finish(self) -> None:
        if self._decoder.unused_data or self._source.read(1):
            raise ValidationError("XZ content contains bytes after its single stream")
        self._done = True

    def readinto(self, buffer: bytearray | memoryview) -> int:
        if self._done or not buffer:
            return 0
        view = memoryview(buffer)
        written = 0
        try:
            while written < len(view):
                if self._decoder.eof:
                    self._finish()
                    break
                if self._decoder.needs_input:
                    compressed = self._source.read(COPY_CHUNK_BYTES)
                    if not compressed:
                        raise ValidationError("XZ content is truncated")
                else:
                    compressed = b""
                output = self._decoder.decompress(
                    compressed, max_length=len(view) - written
                )
                if output:
                    view[written : written + len(output)] = output
                    written += len(output)
                if self._decoder.eof:
                    self._finish()
                    break
            return written
        except lzma.LZMAError as exc:
            raise ValidationError("XZ content is malformed or exceeds its memory limit") from exc


def parse_tar_size(field: bytes) -> int:
    """Parse the POSIX octal or GNU base-256 tar size field."""

    if len(field) != 12:
        raise ValidationError("tar archive contains a malformed size field")
    if field[0] & 0x80:
        if field[0] & 0x40:
            raise ValidationError("tar archive contains a negative size")
        value = int.from_bytes(bytes((field[0] & 0x7F,)) + field[1:], "big")
    else:
        stripped = field.rstrip(b"\x00 ").lstrip(b" ")
        if not stripped or any(character not in b"01234567" for character in stripped):
            raise ValidationError("tar archive contains a malformed size field")
        value = int(stripped, 8)
    return value


class TarMetadataGuardReader(io.RawIOBase):
    """Enforce raw tar types whose payload handling matches tarfile."""

    REGULAR_TYPES = {b"\x00", b"0"}
    LINK_AND_DIRECTORY_TYPES = {b"1", b"2", b"5"}
    GNU_METADATA_TYPES = {b"L", b"K"}
    PAX_TYPES = {b"x", b"g"}

    def __init__(self, source: BinaryIO) -> None:
        super().__init__()
        self._source = source
        self._pending = bytearray()
        self._remaining_data_blocks = 0
        self._consecutive_gnu_metadata = 0
        self._zero_headers = 0
        self._ended = False

    def readable(self) -> bool:
        return True

    def _validate_block(self, block: bytes) -> None:
        if len(block) != 512:
            if self._ended and block.strip(b"\x00"):
                raise ValidationError("tar archive contains nonzero trailing content")
            return
        if self._remaining_data_blocks:
            self._remaining_data_blocks -= 1
            return
        if not block.strip(b"\x00"):
            self._zero_headers += 1
            if self._zero_headers >= 2:
                self._ended = True
            return
        if self._ended:
            raise ValidationError("tar archive contains nonzero trailing content")
        self._zero_headers = 0
        size = parse_tar_size(block[124:136])
        member_type = block[156:157]
        if member_type in self.PAX_TYPES:
            raise ValidationError("PAX metadata is not supported in module packages")
        if member_type in self.GNU_METADATA_TYPES:
            self._consecutive_gnu_metadata += 1
            if self._consecutive_gnu_metadata > MAX_CONSECUTIVE_GNU_METADATA:
                raise ValidationError(
                    "tar archive contains too many consecutive GNU metadata records"
                )
            if size > MAX_TAR_METADATA_BYTES:
                raise ValidationError("tar archive metadata record exceeds the size limit")
            self._remaining_data_blocks = (size + 511) // 512
            return
        if member_type in self.LINK_AND_DIRECTORY_TYPES:
            if size != 0:
                raise ValidationError(
                    "tar directory, symlink, or hardlink header has nonzero size"
                )
            self._remaining_data_blocks = 0
            self._consecutive_gnu_metadata = 0
            return
        if member_type not in self.REGULAR_TYPES:
            raise ValidationError("tar archive contains an unsupported raw member type")
        self._remaining_data_blocks = (size + 511) // 512
        self._consecutive_gnu_metadata = 0

    def readinto(self, buffer: bytearray | memoryview) -> int:
        if not buffer:
            return 0
        if not self._pending:
            block = self._source.read(512)
            if not block:
                return 0
            self._validate_block(block)
            self._pending.extend(block)
        copied = min(len(buffer), len(self._pending))
        buffer[:copied] = self._pending[:copied]
        del self._pending[:copied]
        return copied


def read_exact(descriptor: int, offset: int, size: int) -> bytes:
    data = os.pread(descriptor, size, offset)
    if len(data) != size:
        raise ValidationError("package is truncated")
    return data


def hash_descriptor(descriptor: int, size: int) -> str:
    digest = hashlib.sha256()
    offset = 0
    while offset < size:
        data = os.pread(descriptor, min(COPY_CHUNK_BYTES, size - offset), offset)
        if not data:
            raise ValidationError("package changed or became truncated during validation")
        digest.update(data)
        offset += len(data)
    return digest.hexdigest()


def parse_decimal(field: bytes) -> int:
    value = field.strip()
    if not value or not value.isdigit():
        raise ValidationError("package contains a malformed ar header")
    return int(value, 10)


def parse_ar(descriptor: int, size: int) -> dict[str, ArMember]:
    if size < len(AR_MAGIC) or read_exact(descriptor, 0, len(AR_MAGIC)) != AR_MAGIC:
        raise ValidationError("input is not a Debian ar archive")
    offset = len(AR_MAGIC)
    members: dict[str, ArMember] = {}
    while offset < size:
        if size - offset < 60:
            raise ValidationError("package contains a truncated ar header")
        header = read_exact(descriptor, offset, 60)
        if header[58:60] != b"`\n":
            raise ValidationError("package contains a malformed ar header")
        parse_decimal(header[16:28])
        parse_decimal(header[28:34])
        parse_decimal(header[34:40])
        mode = header[40:48].strip()
        if not mode or any(character not in b"01234567" for character in mode):
            raise ValidationError("package contains a malformed ar header")
        try:
            raw_name = header[:16].decode("ascii").rstrip()
        except UnicodeDecodeError as exc:
            raise ValidationError("package contains a malformed ar member name") from exc
        if raw_name.endswith("/"):
            raw_name = raw_name[:-1]
        if (
            not raw_name
            or raw_name.startswith(("/", "#1/"))
            or not re.fullmatch(r"[A-Za-z0-9_.+-]+", raw_name)
        ):
            raise ValidationError("package contains an unsupported ar member name")
        member_size = parse_decimal(header[48:58])
        if raw_name == "debian-binary" and member_size != 4:
            raise ValidationError("debian-binary member must be exactly four bytes")
        member_offset = offset + 60
        member_end = member_offset + member_size
        if member_end > size:
            raise ValidationError("package contains a truncated ar member")
        if raw_name in members:
            raise ValidationError("package contains a duplicate ar member")
        members[raw_name] = ArMember(raw_name, member_offset, member_size)
        offset = member_end
        if member_size % 2:
            if offset >= size or read_exact(descriptor, offset, 1) != b"\n":
                raise ValidationError("package contains malformed ar padding")
            offset += 1
    if offset != size:
        raise ValidationError("package contains bytes after its ar members")

    allowed = {"debian-binary"}
    control_names = [name for name in members if name in CONTROL_ARCHIVE_NAMES]
    data_names = [name for name in members if name in DATA_ARCHIVE_NAMES]
    if len(control_names) != 1 or len(data_names) != 1:
        raise ValidationError("package must contain exactly one control and one data archive")
    allowed.update((control_names[0], data_names[0]))
    if set(members) != allowed:
        raise ValidationError("package contains an unexpected ar member")
    debian_binary = members["debian-binary"]
    if debian_binary.size != 4 or read_exact(
        descriptor, debian_binary.offset, 4
    ) != b"2.0\n":
        raise ValidationError("package has an unsupported Debian binary format")
    return members


def canonical_member_name(raw_name: str) -> str:
    name = raw_name
    while name.startswith("./"):
        name = name[2:]
    if name.endswith("/"):
        name = name[:-1]
    if name in ("", "."):
        return "."
    if (
        name.startswith("/")
        or "\\" in name
        or "\x00" in name
        or "//" in name
        or any(ord(character) < 32 or ord(character) == 127 for character in name)
        or len(name.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES
    ):
        raise ValidationError("package archive contains an unsafe member path")
    parts = PurePosixPath(name).parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise ValidationError("package archive contains a non-canonical member path")
    if posixpath.normpath(name) != name:
        raise ValidationError("package archive contains a non-canonical member path")
    return name


def safe_link_target(source: str, raw_target: str, hardlink: bool) -> str:
    if (
        not raw_target
        or raw_target.startswith("/")
        or "\\" in raw_target
        or "\x00" in raw_target
        or "//" in raw_target
        or any(ord(character) < 32 or ord(character) == 127 for character in raw_target)
        or len(raw_target.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES
    ):
        raise ValidationError("package archive contains an unsafe link target")
    base = "" if hardlink else posixpath.dirname(source)
    target = posixpath.normpath(posixpath.join(base, raw_target))
    while target.startswith("./"):
        target = target[2:]
    if target in ("", ".", "..") or target.startswith("../"):
        raise ValidationError("package archive contains an escaping link target")
    return canonical_member_name(target)


def compression_kind(path: str) -> str | None:
    if path.endswith(".ko.zst"):
        return "zstd"
    if path.endswith(".ko.xz"):
        return "xz"
    if path.endswith(".ko.gz"):
        return "gzip"
    if path.endswith(".ko"):
        return "none"
    return None


def zstd_program() -> str:
    program = shutil.which("zstd")
    if program is None:
        raise ValidationError("zstd is required to inspect Zstandard-compressed content")
    return program


@contextmanager
def external_zstd_stream(source: BinaryIO) -> Iterator[BinaryIO]:
    process = subprocess.Popen(
        [zstd_program(), "--decompress", "--stdout", "--quiet"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    feed_error: list[BaseException] = []

    def feed() -> None:
        try:
            while True:
                chunk = source.read(COPY_CHUNK_BYTES)
                if not chunk:
                    break
                process.stdin.write(chunk)
        except (BrokenPipeError, OSError, ValidationError) as exc:
            feed_error.append(exc)
        finally:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass

    feeder = threading.Thread(target=feed, name="sp11-zstd-input", daemon=True)
    feeder.start()
    body_error: BaseException | None = None
    try:
        yield process.stdout
    except BaseException as exc:
        body_error = exc
        raise
    finally:
        process.stdout.close()
        feeder.join()
        return_code = process.wait()
        if body_error is None and (feed_error or return_code != 0):
            raise ValidationError("package contains malformed or truncated Zstandard content")


@contextmanager
def decompressed_stream(source: BinaryIO, kind: str) -> Iterator[BinaryIO]:
    try:
        if kind == "none":
            yield source
        elif kind == "gzip":
            with gzip.GzipFile(fileobj=source, mode="rb") as stream:
                yield stream
        elif kind == "xz":
            with io.BufferedReader(ExactXZReader(source)) as stream:
                yield stream
        elif kind == "zstd":
            with external_zstd_stream(source) as stream:
                yield stream
        else:
            raise ValidationError("package uses unsupported compression")
    except (gzip.BadGzipFile, lzma.LZMAError, EOFError, OSError) as exc:
        raise ValidationError("package contains malformed or truncated compressed content") from exc


def tar_compression(member_name: str) -> str:
    if member_name.endswith(".tar.zst"):
        return "zstd"
    if member_name.endswith(".tar.xz"):
        return "xz"
    if member_name.endswith(".tar.gz"):
        return "gzip"
    if member_name.endswith(".tar"):
        return "none"
    raise ValidationError("package uses unsupported tar compression")


def read_control_fields(data: bytes) -> dict[str, str]:
    if len(data) > MAX_CONTROL_BYTES:
        raise ValidationError("package control metadata exceeds the validation limit")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError("package control metadata is not valid UTF-8") from exc
    if "\x00" in text:
        raise ValidationError("package control metadata contains a NUL byte")
    fields: dict[str, str] = {}
    current: str | None = None
    ended = False
    for line in text.splitlines():
        if not line:
            ended = True
            current = None
            continue
        if ended:
            raise ValidationError("package control archive contains multiple paragraphs")
        if line[0].isspace():
            if current is None:
                raise ValidationError("package control metadata has an orphan continuation")
            fields[current] += "\n" + line
            continue
        if ":" not in line:
            raise ValidationError("package control metadata contains a malformed field")
        key, value = line.split(":", 1)
        if not CONTROL_FIELD_PATTERN.fullmatch(key) or key in fields:
            raise ValidationError("package control metadata contains an invalid field")
        fields[key] = value.lstrip(" ")
        current = key
    return fields


def package_identity(fields: dict[str, str], input_name: str) -> PackageIdentity:
    package = fields.get("Package", "")
    version = fields.get("Version", "")
    architecture = fields.get("Architecture", "")
    if (
        not PACKAGE_PATTERN.fullmatch(package)
        or not VERSION_PATTERN.fullmatch(version)
        or architecture != "arm64"
    ):
        raise ValidationError("package control identity is not a supported arm64 module package")
    if package.startswith("linux-modules-extra-"):
        role = "modules-extra"
        abi = package[len("linux-modules-extra-") :]
    else:
        role = "modules"
        abi = package[len("linux-modules-") :]
    if not ABI_PATTERN.fullmatch(abi):
        raise ValidationError("module package ABI must end in qcom-x1e")
    if input_name != f"{package}_{version}_{architecture}.deb":
        raise ValidationError("input filename does not match its package control identity")
    return PackageIdentity(role, package, version, architecture, abi)


def drain_zero_tar_tail(stream: BinaryIO) -> None:
    while True:
        chunk = stream.read(COPY_CHUNK_BYTES)
        if not chunk:
            return
        if chunk.strip(b"\x00"):
            raise ValidationError("package tar archive contains nonzero trailing content")


def validate_member_ancestors(members: dict[str, str], archive_label: str) -> None:
    """Reject archive trees that place descendants below files or links."""

    if members.get(".") in ("file", "link") and len(members) > 1:
        raise ValidationError(
            f"{archive_label} contains a non-directory member ancestor"
        )
    for name in members:
        if name == ".":
            continue
        parts = name.split("/")
        for length in range(1, len(parts)):
            ancestor = "/".join(parts[:length])
            if members.get(ancestor) in ("file", "link"):
                raise ValidationError(
                    f"{archive_label} contains a non-directory member ancestor"
                )


def control_identity(
    descriptor: int, member: ArMember, input_name: str
) -> PackageIdentity:
    source = io.BufferedReader(PreadSlice(descriptor, member.offset, member.size))
    control_data: bytes | None = None
    seen: dict[str, str] = {}
    compression = tar_compression(member.name)
    try:
        with decompressed_stream(source, compression) as decompressed:
            limited = io.BufferedReader(
                LimitedReader(decompressed, MAX_CONTROL_TAR_BYTES, "control archive")
            )
            guarded = io.BufferedReader(TarMetadataGuardReader(limited))
            with tarfile.open(fileobj=guarded, mode="r|") as archive:
                for index, item in enumerate(archive, 1):
                    if index > MAX_MEMBERS:
                        raise ValidationError("control archive contains too many members")
                    name = canonical_member_name(item.name)
                    if name in seen:
                        raise ValidationError("control archive contains a duplicate member path")
                    if item.issparse() or not (item.isdir() or item.isfile()):
                        raise ValidationError("control archive contains a link or special member")
                    seen[name] = "directory" if item.isdir() else "file"
                    if item.isfile() and item.size > MAX_CONTROL_TAR_BYTES:
                        raise ValidationError("control archive member exceeds the size limit")
                    if name == "control":
                        if not item.isfile():
                            raise ValidationError("control archive metadata is not a regular file")
                        extracted = archive.extractfile(item)
                        if extracted is None:
                            raise ValidationError("control archive metadata could not be read")
                        with extracted:
                            control_data = extracted.read(MAX_CONTROL_BYTES + 1)
            drain_zero_tar_tail(guarded)
        validate_member_ancestors(seen, "control archive")
    except RecursionError as exc:
        raise ValidationError("package tar metadata nesting exceeds the validation limit") from exc
    except tarfile.TarError as exc:
        raise ValidationError("package contains a malformed control tar archive") from exc
    if control_data is None:
        raise ValidationError("control archive does not contain package metadata")
    return package_identity(read_control_fields(control_data), input_name)


def inspect_module(stream: BinaryIO) -> tuple[bool, int]:
    total = 0
    prefix = bytearray()
    tail = bytearray()
    while True:
        chunk = stream.read(COPY_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_MODULE_BYTES:
            raise ValidationError("module exceeds the expanded-size validation limit")
        if len(prefix) < 4:
            prefix.extend(chunk[: 4 - len(prefix)])
        tail.extend(chunk)
        if len(tail) > len(MODULE_SIGNATURE_MARKER):
            del tail[: len(tail) - len(MODULE_SIGNATURE_MARKER)]
    if bytes(prefix) != b"\x7fELF":
        raise ValidationError("module payload is not an ELF file")
    return bytes(tail) == MODULE_SIGNATURE_MARKER, total


def scan_module(item_stream: BinaryIO, compression: str) -> tuple[bool, int]:
    with decompressed_stream(item_stream, compression) as stream:
        return inspect_module(stream)


def scan_data_archive(
    descriptor: int, member: ArMember, identity: PackageIdentity
) -> tuple[int, int, int, tuple[int, int, int, int]]:
    source = io.BufferedReader(PreadSlice(descriptor, member.offset, member.size))
    module_root = f"usr/lib/modules/{identity.abi}/kernel"
    prefix = module_root + "/"
    seen: dict[str, str] = {}
    links: list[tuple[str, str]] = []
    module_count = 0
    module_bytes = 0
    signed_count = 0
    compression_counts = {"none": 0, "gzip": 0, "xz": 0, "zstd": 0}
    compression = tar_compression(member.name)
    try:
        with decompressed_stream(source, compression) as decompressed:
            limited = io.BufferedReader(
                LimitedReader(decompressed, MAX_DATA_TAR_BYTES, "data archive")
            )
            guarded = io.BufferedReader(TarMetadataGuardReader(limited))
            with tarfile.open(fileobj=guarded, mode="r|") as archive:
                for index, item in enumerate(archive, 1):
                    if index > MAX_MEMBERS:
                        raise ValidationError("data archive contains too many members")
                    name = canonical_member_name(item.name)
                    if name in seen:
                        raise ValidationError("data archive contains a duplicate member path")
                    if item.issparse():
                        raise ValidationError("data archive contains a sparse member")
                    kind = compression_kind(name)
                    if kind is not None and not name.startswith(prefix):
                        raise ValidationError(
                            "module-like file is outside the expected ABI kernel tree"
                        )
                    if item.isfile():
                        seen[name] = "file"
                        if item.size < 0 or item.size > MAX_MODULE_BYTES:
                            raise ValidationError("data archive member exceeds the size limit")
                        if kind is None:
                            continue
                        extracted = archive.extractfile(item)
                        if extracted is None:
                            raise ValidationError("module payload could not be read")
                        with extracted:
                            signed, expanded_size = scan_module(extracted, kind)
                        module_count += 1
                        module_bytes += expanded_size
                        if module_bytes > MAX_TOTAL_MODULE_BYTES:
                            raise ValidationError(
                                "modules exceed the total expanded-size validation limit"
                            )
                        signed_count += int(signed)
                        compression_counts[kind] += 1
                    elif item.isdir():
                        seen[name] = "directory"
                    elif item.issym() or item.islnk():
                        if name == module_root or name.startswith(prefix) or kind is not None:
                            raise ValidationError(
                                "module tree contains a link in place of a module"
                            )
                        target = safe_link_target(name, item.linkname, item.islnk())
                        seen[name] = "link"
                        links.append((name, target))
                    else:
                        raise ValidationError("data archive contains a special member")
            drain_zero_tar_tail(guarded)
        validate_member_ancestors(seen, "data archive")
    except RecursionError as exc:
        raise ValidationError("package tar metadata nesting exceeds the validation limit") from exc
    except tarfile.TarError as exc:
        raise ValidationError("package contains a malformed data tar archive") from exc
    for _source_name, target in links:
        if seen.get(target) != "file":
            raise ValidationError("data archive contains a dangling or chained link")
    if module_count == 0:
        raise ValidationError("module package does not contain any kernel modules")
    counts = (
        compression_counts["none"],
        compression_counts["gzip"],
        compression_counts["xz"],
        compression_counts["zstd"],
    )
    return module_count, signed_count, module_count - signed_count, counts


def stable_metadata(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def scan_package(path: Path) -> PackageScan:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_size <= 0
            or before.st_size > MAX_PACKAGE_BYTES
        ):
            raise ValidationError("input must be a bounded, non-empty regular package file")
        digest_before = hash_descriptor(descriptor, before.st_size)
        members = parse_ar(descriptor, before.st_size)
        control_member = next(
            value for key, value in members.items() if key.startswith("control.tar")
        )
        data_member = next(
            value for key, value in members.items() if key.startswith("data.tar")
        )
        identity = control_identity(descriptor, control_member, path.name)
        module_count, signed_count, unsigned_count, counts = scan_data_archive(
            descriptor, data_member, identity
        )
        digest_after = hash_descriptor(descriptor, before.st_size)
        after = os.fstat(descriptor)
        if (
            stable_metadata(before) != stable_metadata(after)
            or digest_before != digest_after
        ):
            raise ValidationError("package changed during validation")
        return PackageScan(
            identity,
            digest_before,
            module_count,
            signed_count,
            unsigned_count,
            counts,
        )
    except OSError as exc:
        raise ValidationError("input package could not be opened or read safely") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def validate_package_set(scans: list[PackageScan]) -> list[PackageScan]:
    if not scans:
        raise ValidationError("at least one module package is required")
    roles: dict[str, PackageScan] = {}
    for scan in scans:
        role = scan.identity.role
        if role in roles:
            raise ValidationError("module package role appears more than once")
        roles[role] = scan
    if "modules" not in roles:
        raise ValidationError("the required modules package is missing")
    expected = roles["modules"].identity
    for scan in scans:
        identity = scan.identity
        if (
            identity.abi != expected.abi
            or identity.version != expected.version
            or identity.architecture != expected.architecture
        ):
            raise ValidationError(
                "module packages have mixed ABI, version, or architecture"
            )
    return [roles[role] for role in ("modules", "modules-extra") if role in roles]


def render_report(scans: list[PackageScan], expectation: str) -> str:
    total_modules = sum(scan.module_count for scan in scans)
    total_signed = sum(scan.signed_count for scan in scans)
    total_unsigned = sum(scan.unsigned_count for scan in scans)
    compression_counts = tuple(
        sum(scan.compression_counts[index] for scan in scans) for index in range(4)
    )
    if expectation == "unsigned" and total_signed:
        raise ValidationError(
            f"unsigned expectation failed (signed={total_signed}, unsigned={total_unsigned})"
        )
    if expectation == "signed" and total_unsigned:
        raise ValidationError(
            f"signed expectation failed (signed={total_signed}, unsigned={total_unsigned})"
        )
    lines = [
        "Module signature scan schema: sp11-module-signature-scan-v1",
        f"Package count: {len(scans)}",
    ]
    for index, scan in enumerate(scans, 1):
        identity = scan.identity
        lines.extend(
            (
                f"Package {index} role: {identity.role}",
                f"Package {index} name: {identity.package}",
                f"Package {index} version: {identity.version}",
                f"Package {index} architecture: {identity.architecture}",
                f"Package {index} SHA256: {scan.sha256}",
                f"Package {index} module count: {scan.module_count}",
                f"Package {index} signed module count: {scan.signed_count}",
                f"Package {index} unsigned module count: {scan.unsigned_count}",
            )
        )
    lines.extend(
        (
            f"Kernel ABI: {scans[0].identity.abi}",
            f"Module count: {total_modules}",
            f"Signed module count: {total_signed}",
            f"Unsigned module count: {total_unsigned}",
            f"Uncompressed module count: {compression_counts[0]}",
            f"Gzip module count: {compression_counts[1]}",
            f"XZ module count: {compression_counts[2]}",
            f"Zstandard module count: {compression_counts[3]}",
            f"Expected signature state: {expectation}",
            "Signature expectation satisfied: true",
            "Scan completed: true",
        )
    )
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Safely inventory appended signatures in one linux-modules Deb and its "
            "optional matching linux-modules-extra Deb."
        )
    )
    parser.add_argument(
        "--expect",
        choices=("any", "unsigned", "signed"),
        default="any",
        help="optional all-module signature expectation; default: any",
    )
    parser.add_argument("packages", nargs="+", type=Path, metavar="DEB")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        scans = validate_package_set([scan_package(path) for path in arguments.packages])
        report = render_report(scans, arguments.expect)
    except ValidationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
