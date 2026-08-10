#!/usr/bin/env python3
"""Inventory appended Linux module signatures in qcom-x1e module Debs."""

from __future__ import annotations

import argparse
import fcntl
import gzip
import hashlib
import io
import lzma
import os
import posixpath
import re
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
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
MAX_SIGNATURE_BYTES = 2 * 1024 * 1024
SIGNING_POLICY = "sp11-controlled-rsa4096-sha512-v1"
CONTROLLED_REPORT_SCHEMA = "sp11-kernel-module-signature-verification-v1"
APPROVED_CERTIFICATE_DER_SHA256 = (
    "8ad9b402339b5ceff8e7fc9dfcc7dd368b2466fce0e90d97553059bcdc66e99b"
)
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
    file_name: str
    size: int
    sha256: str
    module_count: int
    signed_count: int
    unsigned_count: int
    compression_counts: tuple[int, int, int, int]
    signed_paths: tuple[str, ...]
    unsigned_paths: tuple[str, ...]


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


def fixed_program(name: str) -> Path:
    if sys.platform.startswith("linux"):
        candidate = Path("/usr/bin") / name
    elif sys.platform == "darwin":
        candidates = (
            Path(f"/opt/homebrew/bin/{name}"),
            Path(f"/usr/local/bin/{name}"),
        )
        candidate = next((path for path in candidates if path.exists()), Path("/nonexistent"))
        candidate = Path(os.path.realpath(candidate))
    else:
        candidate = Path("/nonexistent")
    try:
        metadata = os.stat(candidate, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError(f"fixed {name} authority is unavailable") from exc
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) & 0o022
        or not metadata.st_mode & 0o111
        or (sys.platform.startswith("linux") and metadata.st_uid != 0)
    ):
        raise ValidationError(f"fixed {name} authority has unsafe metadata")
    return candidate


def executable_identity(path: Path) -> tuple[int, int, int, int, int, int, int]:
    try:
        metadata = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError("fixed validation-tool mapping disappeared") from exc
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_uid,
    )


class ControlledSignatureVerifier:
    """Verify sign-file CMS trailers against one captured public certificate."""

    def __init__(self, certificate_path: Path, temporary_root: Path) -> None:
        self.openssl = fixed_program("openssl")
        self.openssl_identity = executable_identity(self.openssl)
        self.temporary_root = temporary_root
        certificate = read_stable_file(certificate_path, 1024 * 1024, "certificate")
        lines = certificate.splitlines()
        if (
            len(lines) < 3
            or lines[0] != b"-----BEGIN CERTIFICATE-----"
            or lines[-1] != b"-----END CERTIFICATE-----"
            or not certificate.endswith(b"\n")
            or any(not re.fullmatch(rb"[A-Za-z0-9+/=]+", line) for line in lines[1:-1])
        ):
            raise ValidationError("controlled certificate is not one exact PEM certificate")
        self.certificate_der = self.run(
            ["x509", "-inform", "PEM", "-outform", "DER"],
            "controlled certificate",
            certificate,
        )
        self.sha256 = hashlib.sha256(self.certificate_der).hexdigest()
        if self.sha256 != APPROVED_CERTIFICATE_DER_SHA256:
            raise ValidationError(
                "controlled certificate does not match the approved public identity"
            )
        details = self.run(
            ["x509", "-inform", "DER", "-text", "-noout"],
            "controlled certificate",
            self.certificate_der,
        ).decode("utf-8", "strict")
        if len(re.findall(r"Public-Key:\s*\(4096 bit\)", details)) != 1:
            raise ValidationError("controlled certificate does not contain an RSA-4096 key")
        if len(re.findall(r"Public Key Algorithm:\s*rsaEncryption\b", details)) != 1:
            raise ValidationError("controlled certificate does not use an RSA public key")
        if len(re.findall(r"Signature Algorithm:\s*sha512WithRSAEncryption\b", details)) != 2:
            raise ValidationError("controlled certificate does not use an RSA/SHA-512 signature")
        if not re.search(
            r"X509v3 Basic Constraints:\s*critical\s*\n\s*CA:FALSE\s*$",
            details,
            re.MULTILINE,
        ):
            raise ValidationError("controlled certificate does not declare critical CA:FALSE")
        usage = re.search(r"X509v3 Key Usage:\s*critical\s*\n\s*([^\n]+)", details)
        if usage is None or usage.group(1).strip() != "Digital Signature":
            raise ValidationError("controlled certificate has the wrong critical key usage")
        fingerprint_output = self.run(
            ["x509", "-inform", "DER", "-sha256", "-fingerprint", "-noout"],
            "controlled certificate fingerprint",
            self.certificate_der,
        ).decode("ascii", "strict").strip()
        match = re.fullmatch(
            r"SHA256 Fingerprint=((?:[0-9A-F]{2}:){31}[0-9A-F]{2})",
            fingerprint_output,
            re.IGNORECASE,
        )
        if match is None:
            raise ValidationError("controlled certificate fingerprint is invalid")
        self.fingerprint = match.group(1).upper()
        serial_output = self.run(
            ["x509", "-inform", "DER", "-serial", "-noout"],
            "controlled certificate serial",
            self.certificate_der,
        ).decode("ascii", "strict").strip()
        serial_match = re.fullmatch(r"serial=([0-9A-F]+)", serial_output, re.IGNORECASE)
        if serial_match is None:
            raise ValidationError("controlled certificate serial is invalid")
        self.serial = serial_match.group(1).upper()
        self.certificate_pem_path = temporary_root / "certificate.pem"
        self.certificate_pem_path.write_bytes(certificate)
        os.chmod(self.certificate_pem_path, 0o400)

    def run(
        self, arguments: list[str], label: str, input_data: bytes | None = None
    ) -> bytes:
        before = executable_identity(self.openssl)
        if before != self.openssl_identity:
            raise ValidationError("fixed OpenSSL authority mapping changed")
        try:
            result = subprocess.run(
                [str(self.openssl), *arguments],
                input=input_data,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=30,
                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C", "TZ": "UTC"},
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ValidationError(f"OpenSSL could not validate {label}") from exc
        if result.returncode != 0:
            raise ValidationError(f"OpenSSL rejected {label}")
        if executable_identity(self.openssl) != before:
            raise ValidationError("fixed OpenSSL authority mapping changed during validation")
        return result.stdout

    def verify_module(self, module_path: Path, module_size: int) -> None:
        with module_path.open("r+b", buffering=0) as module:
            marker_count = 0
            overlap = b""
            module.seek(0)
            while True:
                chunk = module.read(COPY_CHUNK_BYTES)
                if not chunk:
                    break
                combined = overlap + chunk
                marker_count += combined.count(MODULE_SIGNATURE_MARKER)
                overlap = combined[-(len(MODULE_SIGNATURE_MARKER) - 1) :]
            if marker_count != 1:
                raise ValidationError("signed module does not contain one exact signature marker")
            marker_length = len(MODULE_SIGNATURE_MARKER)
            if module_size <= marker_length + 12:
                raise ValidationError("signed module has a truncated signature trailer")
            module.seek(module_size - marker_length)
            if module.read(marker_length) != MODULE_SIGNATURE_MARKER:
                raise ValidationError("signed module has no terminal signature marker")
            info_start = module_size - marker_length - 12
            module.seek(info_start)
            descriptor = module.read(12)
            algorithm, digest, identifier, signer_length, key_length, padding, signature_length = struct.unpack(
                ">BBBBB3sI", descriptor
            )
            if (algorithm, digest, identifier, signer_length, key_length, padding) != (
                0,
                0,
                2,
                0,
                0,
                b"\0\0\0",
            ):
                raise ValidationError("signed module has a non-canonical signature descriptor")
            if signature_length <= 0 or signature_length > MAX_SIGNATURE_BYTES:
                raise ValidationError("signed module has an invalid CMS signature length")
            signature_start = info_start - signature_length
            if signature_start <= 0:
                raise ValidationError("signed module has a truncated CMS signature")
            module.seek(signature_start)
            signature = module.read(signature_length)
            if len(signature) != signature_length:
                raise ValidationError("signed module CMS length does not match its descriptor")
            module.truncate(signature_start)
        signature_path = self.temporary_root / "signature.der"
        if signature_path.exists():
            os.chmod(signature_path, 0o600)
        signature_path.write_bytes(signature)
        os.chmod(signature_path, 0o400)
        structure = self.run(
            ["cms", "-inform", "DER", "-cmsout", "-print"],
            "module CMS structure",
            signature,
        ).decode("utf-8", "strict")
        if (
            structure.count("algorithm: sha512 ") != 2
            or structure.count("algorithm: rsaEncryption ") != 1
            or structure.count("d.issuerAndSerialNumber:") != 1
            or not re.search(r"certificates:\s*\n\s*<ABSENT>", structure)
            or not re.search(r"signedAttrs:\s*\n\s*<ABSENT>", structure)
            or not re.search(r"unsignedAttrs:\s*\n\s*<ABSENT>", structure)
        ):
            raise ValidationError("module CMS does not match the controlled SHA-512 RSA contract")
        self.run(
            [
                "cms",
                "-verify",
                "-binary",
                "-inform",
                "DER",
                "-in",
                str(signature_path),
                "-content",
                str(module_path),
                "-nointern",
                "-certfile",
                str(self.certificate_pem_path),
                "-noverify",
                "-out",
                os.devnull,
            ],
            "module CMS signature",
        )


def read_stable_file(
    path: Path, maximum: int, label: str, allow_empty: bool = False
) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or (before.st_size <= 0 and not allow_empty)
            or before.st_size > maximum
        ):
            raise ValidationError(f"{label} must be one bounded regular non-symlinked file")
        data = b""
        while len(data) <= maximum:
            chunk = os.read(descriptor, min(COPY_CHUNK_BYTES, maximum + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        after = os.fstat(descriptor)
        mapped = os.stat(path, follow_symlinks=False)
        if (
            len(data) != before.st_size
            or stable_metadata(before) != stable_metadata(after)
            or stable_metadata(before) != stable_metadata(mapped)
        ):
            raise ValidationError(f"{label} changed while it was read")
        return data
    except OSError as exc:
        raise ValidationError(f"{label} could not be opened safely") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


@contextmanager
def external_zstd_stream(source: BinaryIO) -> Iterator[BinaryIO]:
    program = fixed_program("zstd")
    program_identity = executable_identity(program)
    try:
        process = subprocess.Popen(
            [str(program), "--decompress", "--stdout", "--quiet"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C", "TZ": "UTC"},
        )
    except OSError as exc:
        raise ValidationError("fixed zstd authority could not be executed") from exc
    if executable_identity(program) != program_identity:
        process.kill()
        process.wait()
        raise ValidationError("fixed zstd authority mapping changed during validation")
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
        if executable_identity(program) != program_identity:
            raise ValidationError("fixed zstd authority mapping changed during validation")
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


def scan_module(
    item_stream: BinaryIO,
    compression: str,
    verifier: ControlledSignatureVerifier | None = None,
) -> tuple[bool, int]:
    with decompressed_stream(item_stream, compression) as stream:
        if verifier is None:
            return inspect_module(stream)
        module_path = verifier.temporary_root / "module.bin"
        total = 0
        prefix = bytearray()
        tail = bytearray()
        with module_path.open("wb", buffering=0) as output:
            os.chmod(module_path, 0o600)
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
                output.write(chunk)
        if bytes(prefix) != b"\x7fELF":
            raise ValidationError("module payload is not an ELF file")
        signed = bytes(tail) == MODULE_SIGNATURE_MARKER
        if signed:
            verifier.verify_module(module_path, total)
        return signed, total


def scan_data_archive(
    descriptor: int,
    member: ArMember,
    identity: PackageIdentity,
    verifier: ControlledSignatureVerifier | None = None,
) -> tuple[
    int,
    int,
    int,
    tuple[int, int, int, int],
    tuple[str, ...],
    tuple[str, ...],
]:
    source = io.BufferedReader(PreadSlice(descriptor, member.offset, member.size))
    module_root = f"usr/lib/modules/{identity.abi}/kernel"
    prefix = module_root + "/"
    seen: dict[str, str] = {}
    links: list[tuple[str, str]] = []
    module_count = 0
    module_bytes = 0
    signed_count = 0
    signed_paths: list[str] = []
    unsigned_paths: list[str] = []
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
                            signed, expanded_size = scan_module(extracted, kind, verifier)
                        module_count += 1
                        module_bytes += expanded_size
                        if module_bytes > MAX_TOTAL_MODULE_BYTES:
                            raise ValidationError(
                                "modules exceed the total expanded-size validation limit"
                            )
                        signed_count += int(signed)
                        relative_path = name[len(prefix) :]
                        if signed:
                            signed_paths.append(relative_path)
                        else:
                            unsigned_paths.append(relative_path)
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
    return (
        module_count,
        signed_count,
        module_count - signed_count,
        counts,
        tuple(sorted(signed_paths)),
        tuple(sorted(unsigned_paths)),
    )


def stable_metadata(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def scan_package(
    path: Path, verifier: ControlledSignatureVerifier | None = None
) -> PackageScan:
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
        module_count, signed_count, unsigned_count, counts, signed_paths, unsigned_paths = scan_data_archive(
            descriptor, data_member, identity, verifier
        )
        digest_after = hash_descriptor(descriptor, before.st_size)
        after = os.fstat(descriptor)
        mapped = os.stat(path, follow_symlinks=False)
        if (
            stable_metadata(before) != stable_metadata(after)
            or stable_metadata(before) != stable_metadata(mapped)
            or digest_before != digest_after
        ):
            raise ValidationError("package changed during validation")
        return PackageScan(
            identity,
            path.name,
            before.st_size,
            digest_before,
            module_count,
            signed_count,
            unsigned_count,
            counts,
            signed_paths,
            unsigned_paths,
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


def unsigned_path_inventory(scans: list[PackageScan]) -> tuple[str, ...]:
    paths = [path for scan in scans for path in scan.unsigned_paths]
    if len(paths) != len(set(paths)):
        raise ValidationError("module packages contain a duplicate normalized unsigned path")
    return tuple(sorted(paths))


def module_path_inventory(scans: list[PackageScan]) -> tuple[str, ...]:
    paths = [
        path
        for scan in scans
        for path in (*scan.signed_paths, *scan.unsigned_paths)
    ]
    if len(paths) != len(set(paths)):
        raise ValidationError("module packages contain a duplicate normalized module path")
    return tuple(sorted(paths))


def read_allowed_unsigned_paths(path: Path) -> tuple[str, ...]:
    data = read_stable_file(path, 4 * 1024 * 1024, "allowed-unsigned list", True)
    if data and not data.endswith(b"\n"):
        raise ValidationError("allowed-unsigned list must end with LF")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ValidationError("allowed-unsigned list must be ASCII text") from exc
    paths = tuple(text.splitlines())
    if paths != tuple(sorted(set(paths))):
        raise ValidationError("allowed-unsigned list must be bytewise sorted and unique")
    for path_text in paths:
        if (
            not path_text
            or not path_text.startswith("drivers/staging/")
            or path_text.startswith(("/", "."))
            or "//" in path_text
            or "\\" in path_text
            or posixpath.normpath(path_text) != path_text
            or any(part in ("", ".", "..") for part in PurePosixPath(path_text).parts)
            or not re.fullmatch(r"[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*\.ko(?:\.(?:gz|xz|zst))?", path_text)
        ):
            raise ValidationError("allowed-unsigned list contains a non-canonical module path")
    return paths


def render_controlled_report(
    scans: list[PackageScan],
    verifier: ControlledSignatureVerifier,
    allowed_unsigned: tuple[str, ...],
) -> str:
    module_path_inventory(scans)
    actual_unsigned = unsigned_path_inventory(scans)
    if actual_unsigned != allowed_unsigned:
        raise ValidationError(
            "actual unsigned module paths do not exactly match the reviewed allowlist"
        )
    total_modules = sum(scan.module_count for scan in scans)
    total_signed = sum(scan.signed_count for scan in scans)
    inventory_bytes = "".join(f"{path}\n" for path in actual_unsigned).encode("ascii")
    lines = [
        "# Surface Pro 11 Kernel Module Signature Report",
        "",
        f"Schema: {CONTROLLED_REPORT_SCHEMA}",
        f"Kernel ABI: {scans[0].identity.abi}",
        f"Package count: {len(scans)}",
    ]
    for index, scan in enumerate(scans, 1):
        identity = scan.identity
        lines.extend(
            [
                f"Package {index} role: {identity.role}",
                f"Package {index} file: {scan.file_name}",
                f"Package {index} name: {identity.package}",
                f"Package {index} version: {identity.version}",
                f"Package {index} architecture: {identity.architecture}",
                f"Package {index} size: {scan.size}",
                f"Package {index} SHA256: {scan.sha256}",
                f"Package {index} module count: {scan.module_count}",
                f"Package {index} cryptographically verified signed module count: {scan.signed_count}",
                f"Package {index} policy-allowed unsigned module count: {scan.unsigned_count}",
            ]
        )
    lines.extend(
        [
            f"Module signing policy: {SIGNING_POLICY}",
            "Module signing hash algorithm: sha512",
            f"Module signing certificate SHA256: {verifier.sha256}",
            f"Module signing certificate fingerprint: {verifier.fingerprint}",
            f"Module signing certificate serial: {verifier.serial}",
            f"Total module count: {total_modules}",
            f"Cryptographically verified signed module count: {total_signed}",
            f"Policy-allowed unsigned module count: {len(actual_unsigned)}",
            "Policy-allowed unsigned module path inventory SHA256: "
            f"{hashlib.sha256(inventory_bytes).hexdigest()}",
            "Validation completed: true",
            "",
            "## Policy-allowed unsigned module paths",
        ]
    )
    lines.extend(f"- {path}" for path in actual_unsigned)
    return "\n".join(lines) + "\n"


def write_exclusive(path: Path, data: bytes, label: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(path, flags, 0o600)
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise OSError
            offset += written
        os.fsync(descriptor)
    except OSError as exc:
        raise ValidationError(f"could not write exclusive {label}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def write_held_report(descriptor: int, data: bytes) -> None:
    """Write a controlled report only to the fixed inherited publication FD."""

    if descriptor != 13:
        raise ValidationError("controlled report descriptor must be inherited fd 13")
    try:
        before = os.fstat(descriptor)
        immutable = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_nlink,
            value.st_uid,
            value.st_gid,
        )
        if (
            not stat.S_ISREG(before.st_mode)
            or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_uid != os.getuid()
            or before.st_nlink != 1
            or before.st_size != 0
            or os.lseek(descriptor, 0, os.SEEK_CUR) != 0
            or fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE
            != os.O_RDWR
        ):
            raise OSError
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise OSError
            offset += written
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        if (
            immutable(after) != immutable(before)
            or after.st_size != len(data)
            or os.lseek(descriptor, 0, os.SEEK_CUR) != len(data)
        ):
            raise OSError
    except OSError as exc:
        raise ValidationError("could not write held controlled report") from exc


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
    parser.add_argument(
        "--unsigned-paths-out",
        type=Path,
        help="write the sorted normalized unsigned-module path inventory exclusively",
    )
    parser.add_argument("--controlled-certificate", type=Path)
    parser.add_argument("--allowed-unsigned-file", type=Path)
    parser.add_argument("--report-out", type=Path)
    parser.add_argument("--report-fd", type=int)
    parser.add_argument("packages", nargs="+", type=Path, metavar="DEB")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
            raise ValidationError(
                "module signature validation requires the default SIGCHLD disposition"
            )
        controlled_values = (
            arguments.controlled_certificate,
            arguments.allowed_unsigned_file,
            arguments.report_out,
            arguments.report_fd,
        )
        controlled = (
            arguments.controlled_certificate is not None
            and arguments.allowed_unsigned_file is not None
            and (arguments.report_out is None) != (arguments.report_fd is None)
        )
        if any(value is not None for value in controlled_values) and not controlled:
            raise ValidationError(
                "controlled verification requires a certificate, allowlist, "
                "and exactly one report sink"
            )
        if controlled and (arguments.expect != "any" or arguments.unsigned_paths_out is not None):
            raise ValidationError("controlled verification cannot be combined with inventory expectations")
        if controlled:
            old_umask = os.umask(0o077)
            try:
                with tempfile.TemporaryDirectory(prefix="sp11-module-signatures-") as temporary:
                    temporary_root = Path(temporary)
                    verifier = ControlledSignatureVerifier(
                        arguments.controlled_certificate, temporary_root
                    )
                    scans = validate_package_set(
                        [scan_package(path, verifier) for path in arguments.packages]
                    )
                    allowed = read_allowed_unsigned_paths(arguments.allowed_unsigned_file)
                    report = render_controlled_report(scans, verifier, allowed)
                    encoded_report = report.encode("utf-8")
                    if arguments.report_fd is not None:
                        write_held_report(arguments.report_fd, encoded_report)
                    else:
                        write_exclusive(
                            arguments.report_out,
                            encoded_report,
                            "controlled report",
                        )
            finally:
                os.umask(old_umask)
            return 0

        scans = validate_package_set([scan_package(path) for path in arguments.packages])
        report = render_report(scans, arguments.expect)
        if arguments.unsigned_paths_out is not None:
            inventory = unsigned_path_inventory(scans)
            write_exclusive(
                arguments.unsigned_paths_out,
                "".join(f"{path}\n" for path in inventory).encode("utf-8"),
                "unsigned path inventory",
            )
    except ValidationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
