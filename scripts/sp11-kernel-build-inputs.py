#!/usr/bin/env python3
"""Create or validate the immutable Docker-build input envelope."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath
from typing import NoReturn


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
SIGNED_SIZE_RE = re.compile(r"(?:0|[1-9][0-9]{0,19})\Z")
UINT64_MAX = (1 << 64) - 1
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")
BASELINE_RE = re.compile(r'^([A-Z0-9_]+)="([^"\r\n]*)"$')
PACKAGE_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]*$")
VERSION_RE = re.compile(r"^[0-9A-Za-z.+:~_-]+$")
ARCH_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
INVENTORY_RE = re.compile(
    r"^[a-z0-9][a-z0-9+.-]*:[a-z0-9][a-z0-9-]*=[0-9A-Za-z.+:~_-]+$"
)
PATH_COMPONENT_RE = re.compile(r"^[0-9A-Za-z.+%_~:@=-]+$")
INPUT_ROLES = (
    "docker-build-arguments",
    "docker-entrypoint",
    "oci-index",
    "kernel-build-manifest-v2",
    "apt-provenance-v1",
)
BUILD_IDENTITY_ARGUMENTS = (
    ("--source-date-epoch", "SP11_KERNEL_SOURCE_DATE_EPOCH"),
    ("--kbuild-build-user", "SP11_KERNEL_KBUILD_BUILD_USER"),
    ("--kbuild-build-host", "SP11_KERNEL_KBUILD_BUILD_HOST"),
    ("--kbuild-build-timestamp", "SP11_KERNEL_KBUILD_BUILD_TIMESTAMP"),
)
SUITES = (
    "resolute",
    "resolute-updates",
    "resolute-backports",
    "resolute-security",
)
COMPONENTS = ("main", "universe", "restricted", "multiverse")
REVIEWED_EMPTY_INDEX_PATHS = (
    "resolute-backports/main/binary-arm64/Packages.gz",
    "resolute-backports/main/source/Sources.gz",
    "resolute-backports/restricted/binary-arm64/Packages.gz",
    "resolute-backports/restricted/source/Sources.gz",
    "resolute-backports/multiverse/binary-arm64/Packages.gz",
    "resolute-backports/multiverse/source/Sources.gz",
)
REVIEWED_EMPTY_GZIP_SIZE = 20
REVIEWED_EMPTY_GZIP_SHA256 = (
    "9ceffb7310338057cfe71a4ae1e2c98d2c485d81cdef906532a801f457a38d64"
)
PRESEAL_ATTESTATION_NAME = "sp11-kernel-preseal-validation.txt"
PRESEAL_ATTESTATION_SCHEMA = "sp11-kernel-preseal-validation-v1"
VALIDATOR_ARGV_SCHEMA = "sp11-kernel-build-inputs-validate-argv-v1"
BUILD_INPUTS_HELPER_PATH = "scripts/sp11-kernel-build-inputs.py"
MANIFEST_VALIDATOR_PATH = "scripts/validate-sp11-image-release-manifests.py"
FIXED_PYTHON = "/usr/bin/python3"
FIXED_PYTHON_OWNER_UID = 0
FIXED_PYTHON_TARGET_RE = re.compile(r"python3\.[0-9]+\Z")
MAX_VALIDATED_INPUTS = 4096
MAX_VALIDATED_PATH_BYTES = 1024
MAX_VALIDATED_AGGREGATE_PATH_BYTES = 4 * 1024 * 1024
MAX_VALIDATED_INPUT_BYTES = 16 * 1024 * 1024 * 1024
MAX_VALIDATED_MEMBER_BYTES = 4 * 1024 * 1024 * 1024
MAX_VALIDATED_DEPTH = 16
MAX_ATTESTATION_BYTES = 4 * 1024 * 1024
MAX_VALIDATOR_ARGV = 128
MAX_VALIDATOR_ARG_BYTES = 8192
APT_DECODER_STDERR_MAX = 1024 * 1024
APT_DECODER_TOTAL_TIMEOUT_SECONDS = 300.0
APT_DECODER_IDLE_TIMEOUT_SECONDS = 30.0
APT_DECODER_STOP_TIMEOUT_SECONDS = 5.0
MANAGED_WORK_NAMES = {
    "apt-archives",
    "apt-indexes",
    "apt-lists",
    "artifacts",
    "docker-build-args.txt",
    "docker-build-inside.sh",
    "sp11-apt-bootstrap-state.txt",
    "sp11-apt-installed-post.txt",
    "sp11-apt-installed-pre.txt",
    "sp11-oci-index.json",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"error: {message}")


def establish_child_wait_authority() -> None:
    """Own child statuses even when an invoking shell ignored SIGCHLD."""

    try:
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    except (OSError, ValueError) as exc:
        fail(f"could not establish child-wait authority: {exc}")
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        fail("child-wait authority is not the default SIGCHLD disposition")


def require_child_wait_authority() -> None:
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        fail("child-wait authority changed before subprocess acquisition")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_file_snapshot(path: Path, label: str) -> tuple[int, int, int, int, int, str]:
    """Hash one regular file through a no-follow descriptor and prove stability."""

    try:
        path_before = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISREG(path_before.st_mode):
        fail(f"{label} must be a regular non-symlinked file")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        fail(f"could not open {label} without following links: {exc}")
    digest = hashlib.sha256()
    try:
        descriptor_before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(descriptor_before.st_mode)
            or (descriptor_before.st_dev, descriptor_before.st_ino)
            != (path_before.st_dev, path_before.st_ino)
        ):
            fail(f"{label} changed before its no-follow descriptor was opened")
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        descriptor_after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        path_after = path.lstat()
    except OSError as exc:
        fail(f"could not re-inspect {label}: {exc}")
    identity_before = (
        descriptor_before.st_dev,
        descriptor_before.st_ino,
        descriptor_before.st_size,
        descriptor_before.st_mtime_ns,
        descriptor_before.st_ctime_ns,
    )
    identity_after = (
        descriptor_after.st_dev,
        descriptor_after.st_ino,
        descriptor_after.st_size,
        descriptor_after.st_mtime_ns,
        descriptor_after.st_ctime_ns,
    )
    path_identity_after = (
        path_after.st_dev,
        path_after.st_ino,
        path_after.st_size,
        path_after.st_mtime_ns,
        path_after.st_ctime_ns,
    )
    if identity_before != identity_after or identity_before != path_identity_after:
        fail(f"{label} changed while it was hashed")
    return (*identity_before, digest.hexdigest())


def write_exclusive_regular(path: Path, payload: bytes, label: str) -> None:
    """Create one final regular file through a held parent without name cleanup."""

    parent_path = real_directory(path.parent, f"{label} parent")
    name = path.name
    if (
        not name
        or name in (".", "..")
        or len(name) > 128
        or any(ord(character) < 32 or ord(character) == 127 for character in name)
        or path.absolute() != parent_path / name
    ):
        fail(f"{label} path is not an exact safe child of its parent")

    required_open_flags = ("O_CLOEXEC", "O_NOFOLLOW", "O_NONBLOCK", "O_DIRECTORY")
    if any(not hasattr(os, flag) for flag in required_open_flags):
        fail(f"{label} requires no-follow exclusive-open support")
    directory_flags = (
        os.O_RDONLY
        | os.O_CLOEXEC
        | os.O_NOFOLLOW
        | os.O_NONBLOCK
        | os.O_DIRECTORY
    )
    output_flags = (
        os.O_RDWR
        | os.O_CREAT
        | os.O_EXCL
        | os.O_CLOEXEC
        | os.O_NOFOLLOW
        | os.O_NONBLOCK
    )

    def directory_authority(metadata: os.stat_result) -> tuple[int, ...]:
        return (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IMODE(metadata.st_mode),
            metadata.st_uid,
            metadata.st_gid,
        )

    def open_parent_exact() -> int:
        current = os.open("/", directory_flags)
        try:
            for component in parent_path.parts[1:]:
                child = os.open(component, directory_flags, dir_fd=current)
                metadata = os.fstat(child)
                if not stat.S_ISDIR(metadata.st_mode):
                    os.close(child)
                    fail(f"{label} parent component is not a directory")
                os.close(current)
                current = child
            return current
        except BaseException:
            os.close(current)
            raise

    expected_payload_digest = hashlib.sha256(payload).digest()

    def descriptor_has_exact_payload(descriptor: int) -> bool:
        metadata = os.fstat(descriptor)
        if metadata.st_size != len(payload):
            return False
        digest = hashlib.sha256()
        offset = 0
        while offset < metadata.st_size:
            chunk = os.pread(
                descriptor, min(64 * 1024, metadata.st_size - offset), offset
            )
            if not chunk:
                return False
            digest.update(chunk)
            offset += len(chunk)
        return (
            not os.pread(descriptor, 1, metadata.st_size)
            and digest.digest() == expected_payload_digest
        )

    parent = -1
    output = -1
    created = False
    release_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    original_handlers = {
        release_signal: signal.getsignal(release_signal)
        for release_signal in release_signals
    }
    publication_mask: set[signal.Signals] | None = None

    def interrupted(_number: int, _frame: object) -> None:
        # Keep further terminal signals pending until exact-inode scrub and
        # descriptor closure have completed.
        signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        raise KeyboardInterrupt

    try:
        for release_signal in release_signals:
            signal.signal(release_signal, interrupted)
        parent_before = parent_path.lstat()
        parent = open_parent_exact()
        parent_held = os.fstat(parent)
        parent_mapped = parent_path.lstat()
        if (
            not stat.S_ISDIR(parent_held.st_mode)
            or stat.S_ISLNK(parent_mapped.st_mode)
            or directory_authority(parent_before)
            != directory_authority(parent_held)
            or directory_authority(parent_held)
            != directory_authority(parent_mapped)
        ):
            fail(f"{label} parent changed before exclusive creation")

        publication_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK, release_signals
        )
        output = os.open(name, output_flags, 0o644, dir_fd=parent)
        created = True
        os.fchmod(output, 0o644)
        view = memoryview(payload)
        while view:
            written = os.write(output, view)
            if written <= 0:
                raise OSError("short exclusive output write")
            view = view[written:]
        os.fsync(output)
        if not descriptor_has_exact_payload(output):
            fail(f"{label} bytes differ from the independently intended payload")

        output_held = os.fstat(output)
        output_mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
        parent_after = parent_path.lstat()
        if (
            not stat.S_ISREG(output_held.st_mode)
            or not stat.S_ISREG(output_mapped.st_mode)
            or stat.S_IMODE(output_held.st_mode) != 0o644
            or output_held.st_size != len(payload)
            or output_held.st_nlink != 1
            or (output_held.st_dev, output_held.st_ino)
            != (output_mapped.st_dev, output_mapped.st_ino)
            or directory_authority(parent_held)
            != directory_authority(parent_after)
        ):
            fail(f"{label} or its parent changed during exclusive creation")
        try:
            os.fsync(parent)
        except OSError:
            if sys.platform != "darwin":
                raise
        output_after = os.fstat(output)
        output_remapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (
            (
                output_held.st_dev,
                output_held.st_ino,
                output_held.st_mode,
                output_held.st_size,
                output_held.st_mtime_ns,
                output_held.st_ctime_ns,
                output_held.st_nlink,
            )
            != (
                output_after.st_dev,
                output_after.st_ino,
                output_after.st_mode,
                output_after.st_size,
                output_after.st_mtime_ns,
                output_after.st_ctime_ns,
                output_after.st_nlink,
            )
            or (output_after.st_dev, output_after.st_ino)
            != (output_remapped.st_dev, output_remapped.st_ino)
            or not descriptor_has_exact_payload(output)
        ):
            fail(f"{label} changed before its exclusive publication seal")
        # The durable exact inode is committed.  Keep terminal signals blocked
        # while their pending instances are discarded and every publication
        # descriptor is closed, so success cannot become a nonzero caller with
        # a full output left behind.
        for release_signal in release_signals:
            signal.signal(release_signal, signal.SIG_IGN)
        if output >= 0:
            try:
                os.close(output)
            except BaseException:
                pass
            output = -1
        if parent >= 0:
            try:
                os.close(parent)
            except BaseException:
                pass
            parent = -1
        signal.pthread_sigmask(signal.SIG_SETMASK, publication_mask)
        publication_mask = None
        for release_signal, original_handler in original_handlers.items():
            signal.signal(release_signal, original_handler)
    except BaseException as exc:
        try:
            if publication_mask is None:
                publication_mask = signal.pthread_sigmask(
                    signal.SIG_BLOCK, release_signals
                )
            for release_signal in release_signals:
                signal.signal(release_signal, signal.SIG_IGN)
        except BaseException:
            pass
        # Once created, retain the exact inode as zero-length failure evidence;
        # never unlink, replace, or reopen a possibly substituted pathname.
        if created and output >= 0:
            try:
                os.ftruncate(output, 0)
                os.fsync(output)
            except BaseException:
                pass
        if isinstance(exc, SystemExit):
            raise
        fail(f"could not exclusively create {label}: {exc}")
    finally:
        if output >= 0:
            try:
                os.close(output)
            except BaseException:
                pass
        if parent >= 0:
            try:
                os.close(parent)
            except BaseException:
                pass
        for release_signal, original_handler in original_handlers.items():
            try:
                signal.signal(release_signal, original_handler)
            except BaseException:
                pass
        if publication_mask is not None:
            try:
                signal.pthread_sigmask(signal.SIG_SETMASK, publication_mask)
            except BaseException:
                pass


def stable_file_bytes(
    path: Path, label: str, *, maximum_size: int
) -> tuple[bytes, tuple[int, int, int, int, int, str]]:
    """Read bounded bytes through one no-follow descriptor and bind its inode."""

    try:
        path_before = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISREG(path_before.st_mode):
        fail(f"{label} must be a regular non-symlinked file")
    if path_before.st_size > maximum_size:
        fail(f"{label} exceeds its maximum size")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        fail(f"could not open {label} without following links: {exc}")
    chunks: list[bytes] = []
    digest = hashlib.sha256()
    total = 0
    try:
        descriptor_before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(descriptor_before.st_mode)
            or (descriptor_before.st_dev, descriptor_before.st_ino)
            != (path_before.st_dev, path_before.st_ino)
        ):
            fail(f"{label} changed before its no-follow descriptor was opened")
        while True:
            chunk = os.read(descriptor, min(64 * 1024, maximum_size + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_size:
                fail(f"{label} exceeds its maximum size")
            chunks.append(chunk)
            digest.update(chunk)
        descriptor_after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        path_after = path.lstat()
    except OSError as exc:
        fail(f"could not re-inspect {label}: {exc}")
    identity_before = (
        descriptor_before.st_dev,
        descriptor_before.st_ino,
        descriptor_before.st_size,
        descriptor_before.st_mtime_ns,
        descriptor_before.st_ctime_ns,
    )
    identity_after = (
        descriptor_after.st_dev,
        descriptor_after.st_ino,
        descriptor_after.st_size,
        descriptor_after.st_mtime_ns,
        descriptor_after.st_ctime_ns,
    )
    path_identity_after = (
        path_after.st_dev,
        path_after.st_ino,
        path_after.st_size,
        path_after.st_mtime_ns,
        path_after.st_ctime_ns,
    )
    if identity_before != identity_after or identity_before != path_identity_after:
        fail(f"{label} changed while it was read")
    return b"".join(chunks), (*identity_before, digest.hexdigest())


def regular_file(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular non-symlinked file")
    return metadata


def _python_metadata_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
    )


def _fixed_python_entry(
    directory_descriptor: int,
    alias_name: str,
) -> tuple[str, os.stat_result, str, str]:
    try:
        alias_metadata = os.stat(
            alias_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except OSError:
        fail("fixed isolated Python alias is unavailable")
    if stat.S_ISREG(alias_metadata.st_mode):
        return "regular", alias_metadata, "-", alias_name
    if not stat.S_ISLNK(alias_metadata.st_mode):
        fail("fixed isolated Python alias has an unsafe type")
    if alias_metadata.st_uid != FIXED_PYTHON_OWNER_UID:
        fail("fixed isolated Python alias has an unsafe owner")
    try:
        link_target = os.readlink(alias_name, dir_fd=directory_descriptor)
    except OSError:
        fail("fixed isolated Python alias could not be read")
    if not FIXED_PYTHON_TARGET_RE.fullmatch(link_target):
        fail("fixed isolated Python alias target is not an approved direct basename")
    return "symlink", alias_metadata, link_target, link_target


def _verify_fixed_python_authority(
    directory_descriptor: int,
    target_descriptor: int,
    expected: tuple[object, ...],
) -> None:
    (
        expected_directory,
        expected_kind,
        expected_alias,
        expected_link_target,
        expected_target_name,
        expected_target,
    ) = expected
    fixed_path = Path(FIXED_PYTHON)
    if (
        not fixed_path.is_absolute()
        or fixed_path.name != "python3"
        or str(fixed_path.parent) != os.path.dirname(FIXED_PYTHON)
    ):
        fail("fixed isolated Python path is not canonical")
    try:
        directory_metadata = os.fstat(directory_descriptor)
        mapped_directory = os.lstat(fixed_path.parent)
        kind, alias_metadata, link_target, target_name = _fixed_python_entry(
            directory_descriptor,
            fixed_path.name,
        )
        target_metadata = os.fstat(target_descriptor)
        mapped_target = os.stat(
            target_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        followed_target = os.stat(fixed_path, follow_symlinks=True)
    except OSError:
        fail("fixed isolated Python authority could not be rechecked")
    if (
        _python_metadata_identity(directory_metadata) != expected_directory
        or _python_metadata_identity(mapped_directory) != expected_directory
        or kind != expected_kind
        or _python_metadata_identity(alias_metadata) != expected_alias
        or link_target != expected_link_target
        or target_name != expected_target_name
        or _python_metadata_identity(target_metadata) != expected_target
        or _python_metadata_identity(mapped_target) != expected_target
        or _python_metadata_identity(followed_target) != expected_target
    ):
        fail("fixed isolated Python authority changed")


def _acquire_fixed_python_authority() -> tuple[int, int, tuple[object, ...]]:
    fixed_path = Path(FIXED_PYTHON)
    if (
        not fixed_path.is_absolute()
        or fixed_path.name != "python3"
        or str(fixed_path.parent) != os.path.dirname(FIXED_PYTHON)
    ):
        fail("fixed isolated Python path is not canonical")
    required_flags = ("O_CLOEXEC", "O_NOFOLLOW", "O_NONBLOCK", "O_DIRECTORY")
    if any(not hasattr(os, name) for name in required_flags):
        fail("fixed isolated Python validation requires no-follow descriptors")
    directory_descriptor = -1
    target_descriptor = -1
    try:
        directory_descriptor = os.open(
            fixed_path.parent,
            os.O_RDONLY
            | os.O_CLOEXEC
            | os.O_NOFOLLOW
            | os.O_NONBLOCK
            | os.O_DIRECTORY,
        )
        directory_metadata = os.fstat(directory_descriptor)
        mapped_directory = os.lstat(fixed_path.parent)
        if (
            not stat.S_ISDIR(directory_metadata.st_mode)
            or directory_metadata.st_uid != FIXED_PYTHON_OWNER_UID
            or stat.S_IMODE(directory_metadata.st_mode) & 0o022
            or _python_metadata_identity(directory_metadata)
            != _python_metadata_identity(mapped_directory)
        ):
            fail("fixed isolated Python directory has an unsafe identity or mode")
        kind, alias_metadata, link_target, target_name = _fixed_python_entry(
            directory_descriptor,
            fixed_path.name,
        )
        target_descriptor = os.open(
            target_name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=directory_descriptor,
        )
        target_metadata = os.fstat(target_descriptor)
        mapped_target = os.stat(
            target_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        followed_target = os.stat(fixed_path, follow_symlinks=True)
        if (
            not stat.S_ISREG(target_metadata.st_mode)
            or target_metadata.st_uid != FIXED_PYTHON_OWNER_UID
            or stat.S_IMODE(target_metadata.st_mode) & 0o111 == 0
            or stat.S_IMODE(target_metadata.st_mode) & 0o022
            or not 0 < target_metadata.st_size <= 256 * 1024 * 1024
            or _python_metadata_identity(target_metadata)
            != _python_metadata_identity(mapped_target)
            or _python_metadata_identity(target_metadata)
            != _python_metadata_identity(followed_target)
            or not os.pread(target_descriptor, 1, 0)
        ):
            fail("fixed isolated Python target has an unsafe identity or mode")
        expected = (
            _python_metadata_identity(directory_metadata),
            kind,
            _python_metadata_identity(alias_metadata),
            link_target,
            target_name,
            _python_metadata_identity(target_metadata),
        )
        _verify_fixed_python_authority(
            directory_descriptor,
            target_descriptor,
            expected,
        )
        return directory_descriptor, target_descriptor, expected
    except OSError:
        if target_descriptor >= 0:
            os.close(target_descriptor)
        if directory_descriptor >= 0:
            os.close(directory_descriptor)
        fail("fixed isolated Python authority could not be acquired")
    except BaseException:
        if target_descriptor >= 0:
            os.close(target_descriptor)
        if directory_descriptor >= 0:
            os.close(directory_descriptor)
        raise


def parse_unique_lines(path: Path) -> dict[str, str]:
    regular_file(path, path.name)
    fields: dict[str, str] = {}
    try:
        raw = path.read_bytes()
        if not raw or not raw.endswith(b"\n") or b"\r" in raw:
            fail(f"{path.name} must be non-empty LF-terminated UTF-8")
        lines = raw.decode("utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"could not read {path.name}: {exc}")
    for line_number, line in enumerate(lines, 1):
        if ": " not in line:
            fail(f"{path.name}:{line_number} is not a schema line")
        key, value = line.split(": ", 1)
        if not key or not value or key in fields:
            fail(f"{path.name}:{line_number} has an empty or duplicate field")
        fields[key] = value
    return fields


def parse_unique_bytes(raw: bytes, label: str) -> dict[str, str]:
    if (
        not raw
        or len(raw) > 4 * 1024 * 1024
        or not raw.endswith(b"\n")
        or b"\r" in raw
        or b"\0" in raw
    ):
        fail(f"{label} must be bounded, non-empty LF-terminated UTF-8")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        fail(f"{label} is not UTF-8: {exc}")
    fields: dict[str, str] = {}
    for line_number, line in enumerate(lines, 1):
        if ": " not in line:
            fail(f"{label}:{line_number} is not a schema line")
        key, value = line.split(": ", 1)
        if not key or not value or key in fields:
            fail(f"{label}:{line_number} has an empty or duplicate field")
        fields[key] = value
    return fields


def read_baseline(path: Path, expected_sha256: str | None = None) -> dict[str, str]:
    raw, _snapshot = stable_file_bytes(path, "baseline", maximum_size=256 * 1024)
    if expected_sha256 is not None:
        if not SHA256_RE.fullmatch(expected_sha256):
            fail("expected baseline SHA256 is not canonical")
        if hashlib.sha256(raw).hexdigest() != expected_sha256:
            fail("baseline bytes do not match the committed snapshot SHA256")
    if not raw or not raw.endswith(b"\n"):
        fail("baseline must be non-empty and LF-terminated")
    if b"\x00" in raw or b"\r" in raw:
        fail("baseline contains a NUL or CR byte")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"baseline is not UTF-8: {exc}")
    values: dict[str, str] = {}
    for line in text.splitlines():
        match = BASELINE_RE.fullmatch(line)
        if match:
            if match.group(1) in values:
                fail(f"duplicate baseline variable: {match.group(1)}")
            values[match.group(1)] = match.group(2)
    return values


def required(fields: dict[str, str], key: str) -> str:
    value = fields.get(key, "")
    if not value:
        fail(f"required field is empty or missing: {key}")
    return value


def require_expected_digest(
    snapshot: tuple[int, int, int, int, int, str],
    expected_sha256: str | None,
    label: str,
) -> None:
    if expected_sha256 is None:
        return
    if not SHA256_RE.fullmatch(expected_sha256):
        fail(f"expected {label} SHA256 is not canonical")
    if snapshot[5] != expected_sha256:
        fail(f"{label} bytes do not match the private release control SHA256")


def validate_build_arguments(
    path: Path,
    baseline: dict[str, str],
    expected_sha256: str | None = None,
) -> tuple[int, int, int, int, int, str]:
    """Require the retained release identity block in its one canonical order."""

    raw, snapshot = stable_file_bytes(
        path, "Docker build arguments", maximum_size=64 * 1024
    )
    require_expected_digest(snapshot, expected_sha256, "Docker build arguments")
    if not raw or not raw.endswith(b"\n"):
        fail("Docker build arguments must be non-empty and LF-terminated")
    if b"\x00" in raw or b"\r" in raw:
        fail("Docker build arguments contain a NUL or CR byte")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"Docker build arguments are not UTF-8: {exc}")
    if any(
        ord(character) < 0x20 or 0x7F <= ord(character) <= 0x9F
        for character in text
        if character != "\n"
    ):
        fail("Docker build arguments contain a control character")

    arguments = text[:-1].split("\n")
    if any(not argument for argument in arguments):
        fail("Docker build arguments contain an empty argument")
    if arguments.count("--release-build") != 1:
        fail("Docker build arguments must contain exactly one --release-build flag")

    expected_block: list[str] = []
    for flag, baseline_field in BUILD_IDENTITY_ARGUMENTS:
        if arguments.count(flag) != 1:
            fail(f"Docker build arguments must contain exactly one {flag} flag")
        expected_block.extend((flag, required(baseline, baseline_field)))
    release_index = arguments.index("--release-build")
    actual_block = arguments[release_index + 1 : release_index + 1 + len(expected_block)]
    if actual_block != expected_block:
        fail(
            "Docker build arguments do not contain the exact ordered deterministic "
            "identity block immediately after --release-build"
        )
    return snapshot


def exact_keys(fields: dict[str, str], expected: list[str], label: str) -> None:
    actual = list(fields)
    if actual != expected:
        missing = [key for key in expected if key not in fields]
        extra = [key for key in actual if key not in expected]
        fail(
            f"{label} field set/order mismatch; missing={missing or 'none'} "
            f"extra={extra or 'none'}"
        )


def validate_bootstrap_state(
    path: Path,
    pre_inventory: Path,
    baseline: dict[str, str],
) -> tuple[int, int, int, int, int, str]:
    raw, snapshot = stable_file_bytes(
        path, "APT bootstrap state", maximum_size=64 * 1024
    )
    fields = parse_unique_bytes(raw, "APT bootstrap state")
    expected_keys = [
        "APT bootstrap state schema",
        "Snapshot ID",
        "Strict HTTPS recheck",
        "Pre-install inventory path",
        "Pre-install inventory size",
        "Pre-install inventory SHA256",
    ]
    exact_keys(fields, expected_keys, "APT bootstrap state")
    snapshot_id = required(baseline, "SP11_APT_SNAPSHOT_ID")
    snapshot_uri = required(baseline, "SP11_APT_SNAPSHOT_URI")
    if snapshot_uri != f"https://snapshot.ubuntu.com/ubuntu/{snapshot_id}/":
        fail("APT baseline snapshot URI is not the strict canonical HTTPS URI")
    pre_snapshot = stable_file_snapshot(
        pre_inventory, "APT bootstrap pre-install inventory"
    )
    expected = (
        ("APT bootstrap state schema", "sp11-immutable-apt-bootstrap-v1"),
        ("Snapshot ID", snapshot_id),
        ("Strict HTTPS recheck", "true"),
        ("Pre-install inventory path", "sp11-apt-installed-pre.txt"),
        ("Pre-install inventory size", str(pre_snapshot[2])),
        ("Pre-install inventory SHA256", pre_snapshot[5]),
    )
    for key, value in expected:
        if required(fields, key) != value:
            fail(f"APT bootstrap state does not match: {key}")
    if stable_file_snapshot(path, "APT bootstrap state") != snapshot:
        fail("APT bootstrap state changed during exact six-field validation")
    return snapshot


def safe_relative(value: str, label: str, *, basename: bool = False) -> None:
    if not value or value.startswith("/") or "\\" in value or any(
        part in ("", ".", "..") or not PATH_COMPONENT_RE.fullmatch(part)
        for part in value.split("/")
    ):
        fail(f"{label} is not a safe relative path")
    if PurePosixPath(value).as_posix() != value:
        fail(f"{label} is not canonical")
    if basename and "/" in value:
        fail(f"{label} must be a basename")


def empty_index_contract(
    baseline: dict[str, str],
    index_sequence: list[tuple[str, str]] | None = None,
) -> tuple[tuple[str, ...], int, str]:
    count_text = required(baseline, "SP11_APT_DECOMPRESSED_EMPTY_INDEX_COUNT")
    size_text = required(baseline, "SP11_APT_DECOMPRESSED_EMPTY_INDEX_SIZE")
    digest = required(baseline, "SP11_APT_DECOMPRESSED_EMPTY_INDEX_SHA256")
    if not re.fullmatch(r"[1-9][0-9]{0,2}", count_text) or int(count_text) != len(
        REVIEWED_EMPTY_INDEX_PATHS
    ):
        fail("decompressed-empty index count is not the reviewed value")
    if not SIGNED_SIZE_RE.fullmatch(size_text) or int(size_text) != REVIEWED_EMPTY_GZIP_SIZE:
        fail("decompressed-empty index gzip size is not the reviewed value")
    if digest != REVIEWED_EMPTY_GZIP_SHA256:
        fail("decompressed-empty index gzip hash is not the reviewed value")

    expected_keys = {
        f"SP11_APT_DECOMPRESSED_EMPTY_INDEX_{index}_PATH"
        for index in range(1, int(count_text) + 1)
    }
    actual_keys = {
        key
        for key in baseline
        if re.fullmatch(r"SP11_APT_DECOMPRESSED_EMPTY_INDEX_[0-9]+_PATH", key)
    }
    if actual_keys != expected_keys:
        fail("decompressed-empty index baseline path fields are not exact")
    paths = tuple(
        required(baseline, f"SP11_APT_DECOMPRESSED_EMPTY_INDEX_{index}_PATH")
        for index in range(1, int(count_text) + 1)
    )
    for path in paths:
        safe_relative(path, "decompressed-empty index path")
    if paths != REVIEWED_EMPTY_INDEX_PATHS:
        fail("decompressed-empty index paths do not match the reviewed sequence")
    if index_sequence is not None:
        selected = {f"{suite}/{relative}" for suite, relative in index_sequence}
        if not set(paths).issubset(selected):
            fail("decompressed-empty index baseline is outside the authenticated set")
    return paths, int(size_text), digest


def positive_count(fields: dict[str, str], key: str, maximum: int = 100000) -> int:
    value = required(fields, key)
    if not value.isdigit() or int(value) <= 0 or int(value) > maximum:
        fail(f"{key} is invalid")
    return int(value)


def safe_input(
    work_dir: Path,
    path: Path,
    label: str,
    expected_sha256: str | None = None,
) -> tuple[str, int, str]:
    regular_file(path, label)
    work_real = work_dir.resolve(strict=True)
    path_real = path.resolve(strict=True)
    try:
        relative = path_real.relative_to(work_real)
    except ValueError:
        fail(f"{label} resolves outside the Docker work directory")
    if path_real != path.absolute():
        fail(f"{label} contains a symlinked or non-canonical path component")
    relative_text = relative.as_posix()
    safe_relative(relative_text, f"{label} envelope path")
    snapshot = stable_file_snapshot(path, label)
    require_expected_digest(snapshot, expected_sha256, label)
    return relative_text, snapshot[2], snapshot[5]


def validate_inventory(
    fields: dict[str, str], prefix: str, expected_keys: list[str]
) -> list[str]:
    count = positive_count(fields, f"{prefix} package count")
    aggregate = required(fields, f"{prefix} package aggregate SHA256")
    if not SHA256_RE.fullmatch(aggregate):
        fail(f"{prefix} package aggregate is not a SHA-256")
    expected_keys.extend(
        (f"{prefix} package count", f"{prefix} package aggregate SHA256")
    )
    rows: list[str] = []
    for index in range(1, count + 1):
        key = f"{prefix} package {index}"
        expected_keys.append(key)
        row = required(fields, key)
        if not INVENTORY_RE.fullmatch(row):
            fail(f"{key} has an invalid package:architecture=version identity")
        rows.append(row)
    if rows != sorted(rows) or len(rows) != len(set(rows)):
        fail(f"{prefix} package inventory is not unique and C-locale sorted")
    calculated = hashlib.sha256(
        "".join(f"{row}\n" for row in rows).encode("utf-8")
    ).hexdigest()
    if calculated != aggregate:
        fail(f"{prefix} package inventory aggregate mismatch")
    return rows


def expected_index_sequence(architecture: str) -> list[tuple[str, str]]:
    return [
        (suite, relative)
        for suite in SUITES
        for component in COMPONENTS
        for relative in (
            f"{component}/binary-{architecture}/Packages.gz",
            f"{component}/source/Sources.gz",
        )
    ]


def local_list_name(snapshot_id: str, suite: str, relative: str) -> str:
    if not relative.endswith(".gz"):
        fail(f"authenticated index path does not end in .gz: {suite}/{relative}")
    return (
        f"snapshot.ubuntu.com_ubuntu_{snapshot_id}_dists_{suite}_"
        f"{relative[:-3].replace('/', '_')}.lz4"
    )


def expected_list_targets(baseline: dict[str, str]) -> list[str]:
    snapshot_id = required(baseline, "SP11_APT_SNAPSHOT_ID")
    architecture = required(baseline, "SP11_APT_SNAPSHOT_ARCHITECTURE")
    index_sequence = expected_index_sequence(architecture)
    empty_paths, _empty_size, _empty_digest = empty_index_contract(
        baseline, index_sequence
    )
    empty_set = set(empty_paths)
    names = ["lock"]
    for suite in SUITES:
        prefix = f"snapshot.ubuntu.com_ubuntu_{snapshot_id}_dists_{suite}"
        names.append(f"{prefix}_InRelease")
    names.extend(
        local_list_name(snapshot_id, suite, relative)
        for suite, relative in index_sequence
        if f"{suite}/{relative}" not in empty_set
    )
    if len(names) != 31 or len(names) != len(set(names)):
        fail("derived APT list target set is not the reviewed 31-file set")
    return sorted(names)


def validate_index_cache_layout(
    cache_dir: Path, index_sequence: list[tuple[str, str]]
) -> None:
    expected_files = {cache_dir / suite / relative for suite, relative in index_sequence}
    expected_dirs: set[Path] = set()
    for path in expected_files:
        parent = path.parent
        while parent != cache_dir:
            expected_dirs.add(parent)
            parent = parent.parent
    actual_files: set[Path] = set()
    actual_dirs: set[Path] = set()
    for path in cache_dir.rglob("*"):
        try:
            metadata = path.lstat()
        except OSError as exc:
            fail(f"could not inspect retained APT index path {path}: {exc}")
        if stat.S_ISREG(metadata.st_mode):
            actual_files.add(path)
        elif stat.S_ISDIR(metadata.st_mode) and not path.is_symlink():
            actual_dirs.add(path)
        else:
            fail(f"retained APT index tree contains an unsafe path: {path}")
    if actual_files != expected_files or actual_dirs != expected_dirs:
        fail("retained APT index tree is not the exact reviewed 32-file layout")


def validate_apt_sidecar(path: Path, baseline: dict[str, str]) -> dict[str, str]:
    fields = parse_unique_lines(path)
    expected_keys = [
        "APT provenance schema",
        "Snapshot ID",
        "Snapshot URI",
        "Suites",
        "Components",
        "Architecture",
        "Archive keyring SHA256",
        "Archive signing fingerprint",
        "Strict HTTPS recheck",
    ]
    if required(fields, "APT provenance schema") != "sp11-kernel-apt-provenance-v1":
        fail("unsupported APT provenance schema")
    for label, baseline_key in (
        ("Snapshot ID", "SP11_APT_SNAPSHOT_ID"),
        ("Snapshot URI", "SP11_APT_SNAPSHOT_URI"),
        ("Suites", "SP11_APT_SNAPSHOT_SUITES"),
        ("Components", "SP11_APT_SNAPSHOT_COMPONENTS"),
        ("Architecture", "SP11_APT_SNAPSHOT_ARCHITECTURE"),
        ("Archive keyring SHA256", "SP11_APT_ARCHIVE_KEYRING_SHA256"),
        ("Archive signing fingerprint", "SP11_APT_ARCHIVE_SIGNING_FINGERPRINT"),
    ):
        if required(fields, label) != required(baseline, baseline_key):
            fail(f"APT sidecar {label} does not match the baseline")
    if tuple(required(fields, "Suites").split()) != SUITES:
        fail("APT sidecar suite set/order is not exact")
    if tuple(required(fields, "Components").split()) != COMPONENTS:
        fail("APT sidecar component set/order is not exact")
    architecture = required(fields, "Architecture")
    if architecture != "arm64" or required(fields, "Strict HTTPS recheck") != "true":
        fail("APT sidecar architecture or strict HTTPS state is invalid")

    validate_inventory(fields, "Pre-install", expected_keys)
    validate_inventory(fields, "Post-install", expected_keys)

    expected_keys.append("InRelease count")
    if required(fields, "InRelease count") != str(len(SUITES)):
        fail("APT sidecar must contain exactly four InRelease rows")
    for index, suite in enumerate(SUITES, 1):
        row_keys = (
            f"InRelease {index} suite",
            f"InRelease {index} size",
            f"InRelease {index} SHA256",
        )
        expected_keys.extend(row_keys)
        if required(fields, row_keys[0]) != suite:
            fail(f"APT sidecar InRelease suite order changed at row {index}")
        if not required(fields, row_keys[1]).isdigit() or int(fields[row_keys[1]]) <= 0:
            fail(f"APT sidecar InRelease size is invalid: {suite}")
        suffix = suite.upper().replace("-", "_")
        if required(fields, row_keys[2]) != required(
            baseline, f"SP11_APT_INRELEASE_{suffix}_SHA256"
        ):
            fail(f"APT sidecar InRelease hash does not match baseline: {suite}")

    index_sequence = expected_index_sequence(architecture)
    empty_paths, empty_gzip_size, empty_gzip_digest = empty_index_contract(
        baseline, index_sequence
    )
    empty_set = set(empty_paths)
    expected_keys.append("Index count")
    if required(fields, "Index count") != required(
        baseline, "SP11_APT_AUTHENTICATED_INDEX_COUNT"
    ) or len(index_sequence) != int(fields["Index count"]):
        fail("APT sidecar index count is not the reviewed 4x4x2 set")
    snapshot_uri = required(fields, "Snapshot URI")
    for index, (suite, relative) in enumerate(index_sequence, 1):
        keys = (
            f"Index {index} suite",
            f"Index {index} path",
            f"Index {index} retained path",
            f"Index {index} size",
            f"Index {index} SHA256",
            f"Index {index} URI",
        )
        expected_keys.extend(keys)
        if required(fields, keys[0]) != suite or required(fields, keys[1]) != relative:
            fail(f"APT sidecar index path/order changed at row {index}")
        if required(fields, keys[2]) != f"{suite}/{relative}":
            fail(f"APT sidecar retained index path changed at row {index}")
        size_text = required(fields, keys[3])
        if (
            not SIGNED_SIZE_RE.fullmatch(size_text)
            or int(size_text) <= 0
            or int(size_text) > UINT64_MAX
        ):
            fail(f"APT sidecar index size is invalid at row {index}")
        digest = required(fields, keys[4])
        if not SHA256_RE.fullmatch(digest):
            fail(f"APT sidecar index hash is invalid at row {index}")
        full_path = f"{suite}/{relative}"
        if full_path in empty_set:
            if int(size_text) != empty_gzip_size or digest != empty_gzip_digest:
                fail(
                    "APT sidecar declared-empty gzip identity is invalid at "
                    f"row {index}"
                )
        elif int(size_text) == empty_gzip_size and digest == empty_gzip_digest:
            fail(f"APT sidecar undeclared empty gzip appears at row {index}")
        expected_uri = (
            f"{snapshot_uri}dists/{suite}/{relative.rsplit('/', 1)[0]}"
            f"/by-hash/SHA256/{digest}"
        )
        if required(fields, keys[5]) != expected_uri:
            fail(f"APT sidecar by-hash URI is invalid at row {index}")

    list_paths = expected_list_targets(baseline)
    expected_keys.append("APT list target count")
    if required(fields, "APT list target count") != str(len(list_paths)):
        fail("APT sidecar list-target count is not exact")
    for index, expected_path in enumerate(list_paths, 1):
        keys = (
            f"APT list target {index} path",
            f"APT list target {index} size",
            f"APT list target {index} SHA256",
        )
        expected_keys.extend(keys)
        if required(fields, keys[0]) != expected_path:
            fail(f"APT list target path/order changed at row {index}")
        size = required(fields, keys[1])
        if not size.isdigit() or (expected_path != "lock" and int(size) <= 0):
            fail(f"APT list target size is invalid at row {index}")
        if not SHA256_RE.fullmatch(required(fields, keys[2])):
            fail(f"APT list target hash is invalid at row {index}")

    expected_keys.append("Downloaded Deb count")
    deb_count = positive_count(fields, "Downloaded Deb count", maximum=10000)
    if deb_count < int(required(baseline, "SP11_APT_BOOTSTRAP_PACKAGE_COUNT")):
        fail("APT sidecar downloaded Deb set omits bootstrap packages")
    deb_paths: list[str] = []
    deb_identities: set[tuple[str, str, str, str]] = set()
    bootstrap_seen: set[tuple[str, str, str]] = set()
    location_order = {
        f"{suite}/{relative}": position
        for position, (suite, relative) in enumerate(index_sequence)
        if relative.endswith("/Packages.gz")
    }
    for index in range(1, deb_count + 1):
        keys = tuple(
            f"Downloaded Deb {index} {label}"
            for label in (
                "path",
                "package",
                "version",
                "architecture",
                "size",
                "SHA256",
                "archive filename",
                "URI",
                "signed record count",
            )
        )
        expected_keys.extend(keys)
        path_value = required(fields, keys[0])
        safe_relative(path_value, f"Downloaded Deb {index} path", basename=True)
        if not path_value.endswith(".deb"):
            fail(f"Downloaded Deb {index} path must end in .deb")
        package = required(fields, keys[1])
        version = required(fields, keys[2])
        deb_arch = required(fields, keys[3])
        if (
            not PACKAGE_RE.fullmatch(package)
            or not VERSION_RE.fullmatch(version)
            or not ARCH_RE.fullmatch(deb_arch)
        ):
            fail(f"Downloaded Deb {index} identity is invalid")
        if not required(fields, keys[4]).isdigit() or int(fields[keys[4]]) <= 0:
            fail(f"Downloaded Deb {index} size is invalid")
        digest = required(fields, keys[5])
        if not SHA256_RE.fullmatch(digest):
            fail(f"Downloaded Deb {index} hash is invalid")
        archive_filename = required(fields, keys[6])
        safe_relative(archive_filename, f"Downloaded Deb {index} archive filename")
        if required(fields, keys[7]) != snapshot_uri + archive_filename:
            fail(f"Downloaded Deb {index} dated URI is invalid")
        record_count_text = required(fields, keys[8])
        if not record_count_text.isdigit() or not (1 <= int(record_count_text) <= 16):
            fail(f"Downloaded Deb {index} signed-record count is invalid")
        locations: list[str] = []
        for record_index in range(1, int(record_count_text) + 1):
            location_key = f"Downloaded Deb {index} signed record {record_index} location"
            expected_keys.append(location_key)
            location = required(fields, location_key)
            if location not in location_order:
                fail(f"Downloaded Deb {index} has an invalid signed-record location")
            locations.append(location)
        if len(locations) != len(set(locations)) or locations != sorted(
            locations, key=location_order.__getitem__
        ):
            fail(f"Downloaded Deb {index} signed-record locations are not unique and ordered")
        deb_paths.append(path_value)
        identity = (package, version, deb_arch, digest)
        if identity in deb_identities:
            fail(f"Downloaded Deb {index} duplicates an earlier identity")
        deb_identities.add(identity)
        bootstrap_seen.add((package, version, digest))
    if deb_paths != sorted(deb_paths) or len(deb_paths) != len(set(deb_paths)):
        fail("Downloaded Deb rows are not unique and path-sorted")
    for index in range(1, int(required(baseline, "SP11_APT_BOOTSTRAP_PACKAGE_COUNT")) + 1):
        package, version = required(
            baseline, f"SP11_APT_BOOTSTRAP_PACKAGE_{index}_SPEC"
        ).split("=", 1)
        digest = required(baseline, f"SP11_APT_BOOTSTRAP_PACKAGE_{index}_SHA256")
        if (package, version, digest) not in bootstrap_seen:
            fail(f"APT sidecar is missing bootstrap lock entry {index}")
    python_package, python_version = required(
        baseline, "SP11_APT_PYTHON_PACKAGE_SPEC"
    ).split("=", 1)
    python_architecture = required(baseline, "SP11_APT_SNAPSHOT_ARCHITECTURE")
    if not any(
        package == python_package
        and version == python_version
        and architecture == python_architecture
        for package, version, architecture, _digest in deb_identities
    ):
        fail("APT sidecar is missing the required snapshot Python package")

    expected_keys.append("Local build-deps count")
    if required(fields, "Local build-deps count") != "1":
        fail("APT sidecar must bind exactly one local build-deps Deb")
    local_keys = tuple(
        f"Local build-deps 1 {label}"
        for label in ("path", "package", "version", "architecture", "size", "SHA256")
    )
    expected_keys.extend(local_keys)
    local_path = required(fields, local_keys[0])
    safe_relative(local_path, "local build-deps path", basename=True)
    if not local_path.endswith(".deb") or "-build-deps_" not in local_path:
        fail("local build-deps path grammar is invalid")
    if not PACKAGE_RE.fullmatch(required(fields, local_keys[1])):
        fail("local build-deps package grammar is invalid")
    if not VERSION_RE.fullmatch(required(fields, local_keys[2])):
        fail("local build-deps version grammar is invalid")
    if not ARCH_RE.fullmatch(required(fields, local_keys[3])):
        fail("local build-deps architecture grammar is invalid")
    if not required(fields, local_keys[4]).isdigit() or int(fields[local_keys[4]]) <= 0:
        fail("local build-deps size is invalid")
    if not SHA256_RE.fullmatch(required(fields, local_keys[5])):
        fail("local build-deps hash is invalid")

    expected_keys.append("APT provenance complete")
    if required(fields, "APT provenance complete") != "true":
        fail("APT provenance is incomplete")
    exact_keys(fields, expected_keys, "APT provenance")
    return fields


def clear_signed_lines(path: Path) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"could not read retained InRelease {path.name}: {exc}")
    try:
        start = lines.index("") + 1
    except ValueError:
        fail(f"retained InRelease has an invalid clear-signed structure: {path.name}")
    result: list[str] = []
    saw_signature = False
    for line in lines[start:]:
        if line == "-----BEGIN PGP SIGNATURE-----":
            saw_signature = True
            break
        result.append(line[2:] if line.startswith("- ") else line)
    if not saw_signature:
        fail(f"retained InRelease has no signature block: {path.name}")
    return result


def clear_signed_sha256(path: Path) -> dict[str, tuple[int, str]]:
    lines = clear_signed_lines(path)
    try:
        sha_start = lines.index("SHA256:") + 1
    except ValueError:
        fail(f"retained InRelease has no SHA256 section: {path.name}")
    entries: dict[str, tuple[int, str]] = {}
    for line in lines[sha_start:]:
        if not line.startswith(" "):
            break
        parts = line.split()
        if (
            len(parts) != 3
            or not SHA256_RE.fullmatch(parts[0])
            or not SIGNED_SIZE_RE.fullmatch(parts[1])
        ):
            fail(f"retained InRelease has an invalid SHA256 row: {path.name}")
        size = int(parts[1])
        if size > UINT64_MAX or (size == 0) != (parts[0] == EMPTY_SHA256):
            fail(f"retained InRelease has an invalid SHA256 row: {path.name}")
        safe_relative(parts[2], "signed InRelease path")
        if parts[2] in entries:
            fail(f"retained InRelease has a duplicate SHA256 path: {path.name}")
        entries[parts[2]] = (size, parts[0])
    return entries


def real_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISDIR(metadata.st_mode) or resolved != path.absolute():
        fail(f"{label} has a symlinked or non-canonical component")
    return resolved


def iter_packages(path: Path) -> object:
    try:
        with gzip.open(path, "rt", encoding="utf-8", errors="strict") as handle:
            fields: dict[str, str] = {}
            for raw_line in handle:
                line = raw_line.rstrip("\n")
                if "\r" in line:
                    fail(f"retained Packages.gz contains a carriage return: {path}")
                if not line:
                    if fields:
                        yield fields
                        fields = {}
                    continue
                if line[0].isspace():
                    continue
                if ":" not in line:
                    fail(f"retained Packages.gz contains malformed Deb822: {path}")
                key, value = line.split(":", 1)
                if key in fields:
                    fail(f"retained Packages.gz contains duplicate field {key}: {path}")
                fields[key] = value.strip()
            if fields:
                yield fields
    except (OSError, UnicodeDecodeError, EOFError) as exc:
        fail(f"could not parse retained Packages.gz {path}: {exc}")


def decompressed_gzip_identity(path: Path, label: str) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    try:
        with gzip.open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                size += len(chunk)
                digest.update(chunk)
    except (OSError, EOFError) as exc:
        fail(f"could not decompress {label}: {exc}")
    return size, digest.hexdigest()


def apt_list_decoder(path: Path, baseline: dict[str, str]) -> list[str]:
    fixture_value = os.environ.get("SP11_APT_FIXTURE_ROOT", "")
    override = os.environ.get("SP11_APT_HELPER", "")
    if fixture_value:
        if (
            baseline.get("SP11_KERNEL_BASELINE_ID") != "fixture"
            or baseline.get("SP11_KERNEL_UPSTREAM_URL")
            != "https://github.com/example/linux.git"
            or baseline.get("SP11_KERNEL_UPSTREAM_REF")
            not in {"fixture", "fixture/ref"}
        ):
            fail("fixture APT decoder is forbidden for a production baseline")
        fixture_root = real_directory(Path(fixture_value), "APT fixture root")
        temporary_root = Path(os.environ.get("TMPDIR", "/tmp")).resolve(strict=True)
        slash_tmp = Path("/tmp").resolve(strict=True)
        if (
            fixture_root.parent not in {temporary_root, slash_tmp}
            or not fixture_root.name.startswith("sp11-apt-fixture.")
        ):
            fail("APT fixture root is not an exact temporary fixture child")
        try:
            path.resolve(strict=True).relative_to(fixture_root)
        except (OSError, ValueError):
            fail("fixture APT list target resolves outside the fixture root")
        if not override:
            fail("fixture mode requires SP11_APT_HELPER")
        helper = Path(override)
        if helper != fixture_root / "mock-bin/apt-helper":
            fail("fixture apt-helper path is not exact")
        regular_file(helper, "fixture apt-helper")
        if helper.resolve(strict=True) != helper.absolute():
            fail("fixture apt-helper has a symlinked path component")
        return [str(helper), "cat-file", str(path)]
    if override:
        fail("SP11_APT_HELPER is fixture-only")
    system_helper = Path("/usr/lib/apt/apt-helper")
    if (
        system_helper.is_file()
        and not system_helper.is_symlink()
        and os.access(system_helper, os.X_OK)
    ):
        return [str(system_helper), "cat-file", str(path)]
    lz4 = shutil.which("lz4")
    if not lz4:
        fail("apt-helper or lz4 is required to validate retained APT list views")
    return [lz4, "-d", "-c", str(path)]


def apt_list_identity(
    path: Path,
    baseline: dict[str, str],
    expected: tuple[int, str],
) -> tuple[int, str]:
    """Decode one list through a bounded, signal-safe owned subprocess."""

    require_child_wait_authority()
    expected_size, expected_sha256 = expected
    if (
        not isinstance(expected_size, int)
        or expected_size < 0
        or expected_size > UINT64_MAX
        or not SHA256_RE.fullmatch(expected_sha256)
    ):
        fail("signed APT index has an invalid decompressed identity")

    digest = hashlib.sha256()
    size = 0
    diagnostics_size = 0
    process: subprocess.Popen[bytes] | None = None
    selector: selectors.BaseSelector | None = None
    failure: BaseException | None = None
    returncode: int | None = None
    interrupted_signal: int | None = None
    release_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    original_handlers = {
        release_signal: signal.getsignal(release_signal)
        for release_signal in release_signals
    }

    def interrupted(number: int, _frame: object) -> None:
        nonlocal interrupted_signal
        # Defer any second terminal signal until the exact registered decoder
        # has been stopped and waited.  The first signal unwinds into that
        # single owner instead of escaping between Popen CALL and assignment.
        interrupted_signal = number
        signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        raise InterruptedError(f"APT list decoder interrupted by signal {number}")

    def check_interrupted() -> None:
        if interrupted_signal is not None:
            raise InterruptedError(
                f"APT list decoder interrupted by signal {interrupted_signal}"
            )

    def stop_and_wait_decoder() -> None:
        assert process is not None
        for stream in (process.stdout, process.stderr):
            try:
                if stream is not None:
                    stream.close()
            except BaseException:
                pass
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
        try:
            process.wait(timeout=APT_DECODER_STOP_TIMEOUT_SECONDS)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
        # SIGKILL leaves no producer code able to extend the wait.  Always
        # collect the exact child so neither timeout nor BaseException can
        # return with a zombie or an unowned decoder.
        process.wait()

    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
    try:
        for release_signal in release_signals:
            signal.signal(release_signal, interrupted)

        def restore_child_signal_mask() -> None:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

        # Terminal signals remain blocked through CALL, assignment, and owner
        # registration.  The child restores the exact mask inherited before
        # this acquisition boundary.
        process = subprocess.Popen(
            apt_list_decoder(path, baseline),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            start_new_session=True,
            preexec_fn=restore_child_signal_mask,
        )
        if process.stdout is None or process.stderr is None:
            raise OSError("APT list decoder pipes are unavailable")
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        check_interrupted()

        selector = selectors.DefaultSelector()
        for stream, stream_name in (
            (process.stdout, "stdout"),
            (process.stderr, "stderr"),
        ):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream.fileno(), selectors.EVENT_READ, stream_name)

        started = time.monotonic()
        deadline = started + APT_DECODER_TOTAL_TIMEOUT_SECONDS
        last_progress = started
        while selector.get_map():
            check_interrupted()
            now = time.monotonic()
            remaining_total = deadline - now
            remaining_progress = APT_DECODER_IDLE_TIMEOUT_SECONDS - (
                now - last_progress
            )
            if remaining_total <= 0 or remaining_progress <= 0:
                raise TimeoutError("APT list decoder exceeded its deadline")
            events = selector.select(
                min(1.0, remaining_total, remaining_progress)
            )
            check_interrupted()
            if not events:
                continue
            for key, _mask in events:
                maximum_read = 64 * 1024
                if key.data == "stdout":
                    maximum_read = min(maximum_read, expected_size - size + 1)
                try:
                    chunk = os.read(key.fd, maximum_read)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                last_progress = time.monotonic()
                if key.data == "stdout":
                    size += len(chunk)
                    if size > expected_size:
                        raise OSError(
                            "APT list decoder output exceeded the signed size"
                        )
                    digest.update(chunk)
                else:
                    # Docker/apt helpers may emit legitimate warnings even on
                    # success.  Stderr is bounded and drained but discarded;
                    # it is never an authority for the decoded bytes.
                    diagnostics_size += len(chunk)
                    if diagnostics_size > APT_DECODER_STDERR_MAX:
                        raise OSError(
                            "APT list decoder diagnostics exceeded their limit"
                        )
            check_interrupted()

        check_interrupted()
        remaining = min(
            deadline - time.monotonic(),
            APT_DECODER_IDLE_TIMEOUT_SECONDS
            - (time.monotonic() - last_progress),
        )
        if remaining <= 0:
            raise TimeoutError("APT list decoder did not exit before its deadline")
        # CPython records waitpid() status on the Popen object after the child
        # has already been reaped.  Keep terminal signals blocked across that
        # internal transition and this local registration so no handler can
        # mistake the reusable PID for a live process-group authority.
        wait_mask = signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        try:
            returncode = process.wait(timeout=remaining)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, wait_mask)
        check_interrupted()
        if returncode != 0:
            raise OSError("APT list decoder exited unsuccessfully")
        check_interrupted()
        if size != expected_size or digest.hexdigest() != expected_sha256:
            raise OSError("APT list decoder output differs from the signed index")
    except BaseException as exc:
        failure = exc
    finally:
        # From here through wait and handler restoration, further terminal
        # signals stay pending.  This also covers exceptions raised while a
        # selector or pipe is being closed.
        try:
            signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        except BaseException as exc:
            if failure is None:
                failure = exc
        if selector is not None:
            try:
                selector.close()
            except BaseException as exc:
                if failure is None:
                    failure = exc
        if process is not None:
            # Popen.wait() stores this before returning.  A signal may raise
            # between that internal reap and the caller's local assignment;
            # adopt the exact object's terminal state so an already-reaped PID
            # is never used as a process-group kill authority.
            if returncode is None and process.returncode is not None:
                returncode = process.returncode
            if returncode is None:
                try:
                    stop_and_wait_decoder()
                except BaseException as exc:
                    if failure is None:
                        failure = exc
            else:
                for stream in (process.stdout, process.stderr):
                    try:
                        if stream is not None:
                            stream.close()
                    except BaseException as exc:
                        if failure is None:
                            failure = exc
        for release_signal, original_handler in original_handlers.items():
            try:
                signal.signal(release_signal, original_handler)
            except BaseException as exc:
                if failure is None:
                    failure = exc
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        except BaseException as exc:
            if failure is None:
                failure = exc

    if failure is not None:
        if isinstance(failure, SystemExit):
            raise failure
        fail(f"could not decode retained APT list target {path.name}: {failure}")
    return size, digest.hexdigest()


def validate_retained_apt(
    args: argparse.Namespace, fields: dict[str, str], baseline: dict[str, str]
) -> None:
    work = real_directory(args.work_dir, "Docker work directory")
    archives = real_directory(args.apt_archives_dir, "retained APT archives")
    indexes = real_directory(args.apt_index_cache_dir, "retained APT indexes")
    lists = real_directory(args.apt_lists_dir, "retained APT lists")
    local_dir = real_directory(args.apt_local_build_deps_dir, "local build-deps directory")
    if archives != work / "apt-archives" or indexes != work / "apt-indexes" or lists != work / "apt-lists":
        fail("retained APT directories are not the exact managed work children")
    if local_dir != work / "artifacts":
        fail("local build-deps directory is not the exact work artifacts child")
    if args.apt_pre_inventory.absolute() != work / "sp11-apt-installed-pre.txt":
        fail("pre-install inventory path is not exact")
    if args.apt_post_inventory.absolute() != work / "sp11-apt-installed-post.txt":
        fail("post-install inventory path is not exact")

    for prefix, inventory_path in (
        ("Pre-install", args.apt_pre_inventory),
        ("Post-install", args.apt_post_inventory),
    ):
        regular_file(inventory_path, f"{prefix} package inventory")
        raw = inventory_path.read_bytes()
        rows = raw.decode("utf-8").splitlines()
        count = int(fields[f"{prefix} package count"])
        expected_rows = [fields[f"{prefix} package {index}"] for index in range(1, count + 1)]
        if rows != expected_rows or not raw.endswith(b"\n"):
            fail(f"{prefix} package inventory differs from sidecar")
        if hashlib.sha256(raw).hexdigest() != fields[f"{prefix} package aggregate SHA256"]:
            fail(f"{prefix} package inventory hash differs from sidecar")

    snapshot_id = fields["Snapshot ID"]
    signed_by_suite: dict[str, dict[str, tuple[int, str]]] = {}
    for index, suite in enumerate(SUITES, 1):
        name = f"snapshot.ubuntu.com_ubuntu_{snapshot_id}_dists_{suite}_InRelease"
        path = lists / name
        metadata = regular_file(path, f"retained {suite} InRelease")
        if metadata.st_size != int(fields[f"InRelease {index} size"]):
            fail(f"retained InRelease size differs from sidecar: {suite}")
        actual_digest = sha256(path)
        if actual_digest != fields[f"InRelease {index} SHA256"] or actual_digest != required(
            baseline, f"SP11_APT_INRELEASE_{suite.upper().replace('-', '_')}_SHA256"
        ):
            fail(f"retained InRelease hash differs from baseline/sidecar: {suite}")
        signed_by_suite[suite] = clear_signed_sha256(path)

    index_sequence = expected_index_sequence(fields["Architecture"])
    empty_paths, empty_gzip_size, empty_gzip_digest = empty_index_contract(
        baseline, index_sequence
    )
    declared_empty = set(empty_paths)
    observed_empty: set[str] = set()
    decompressed_indexes: dict[str, tuple[int, str]] = {}
    wanted_packages: set[tuple[str, str, str]] = set()
    deb_count = int(fields["Downloaded Deb count"])
    for index in range(1, deb_count + 1):
        wanted_packages.add(
            (
                fields[f"Downloaded Deb {index} package"],
                fields[f"Downloaded Deb {index} version"],
                fields[f"Downloaded Deb {index} architecture"],
            )
        )
    package_records: dict[
        tuple[str, str, str], list[tuple[int, str, str, str]]
    ] = {}
    for row_index, (suite, relative) in enumerate(index_sequence, 1):
        path = indexes / suite / relative
        metadata = regular_file(path, f"retained index {suite}/{relative}")
        digest_value = sha256(path)
        if (
            metadata.st_size != int(fields[f"Index {row_index} size"])
            or digest_value != fields[f"Index {row_index} SHA256"]
            or signed_by_suite[suite].get(relative) != (metadata.st_size, digest_value)
        ):
            fail(f"retained index differs from signed InRelease/sidecar: {suite}/{relative}")
        full_path = f"{suite}/{relative}"
        decompressed = decompressed_gzip_identity(
            path, f"retained index {full_path}"
        )
        decompressed_indexes[full_path] = decompressed
        if decompressed[0] == 0:
            observed_empty.add(full_path)
        if (decompressed[0] == 0) != (full_path in declared_empty):
            fail(f"retained index decompressed-empty state differs from baseline: {full_path}")
        if full_path in declared_empty and (
            metadata.st_size != empty_gzip_size
            or digest_value != empty_gzip_digest
            or decompressed != (0, EMPTY_SHA256)
        ):
            fail(f"declared empty index identity differs from baseline: {full_path}")
        if not relative.endswith("/Packages.gz"):
            continue
        location = f"{suite}/{relative}"
        for record in iter_packages(path):
            needed = ("Package", "Version", "Architecture", "Size", "SHA256", "Filename")
            if any(not record.get(key) for key in needed):
                fail(f"incomplete record in retained Packages.gz: {location}")
            identity = (record["Package"], record["Version"], record["Architecture"])
            if identity not in wanted_packages:
                continue
            if not record["Size"].isdigit() or not SHA256_RE.fullmatch(record["SHA256"]):
                fail(f"invalid target record in retained Packages.gz: {location}")
            safe_relative(record["Filename"], "retained package archive filename")
            package_records.setdefault(identity, []).append(
                (int(record["Size"]), record["SHA256"], record["Filename"], location)
            )
    validate_index_cache_layout(indexes, index_sequence)
    if observed_empty != declared_empty:
        fail("observed decompressed-empty index set differs from the baseline")

    expected_deb_paths: set[Path] = set()
    for index in range(1, deb_count + 1):
        deb_path = archives / fields[f"Downloaded Deb {index} path"]
        expected_deb_paths.add(deb_path)
        metadata = regular_file(deb_path, f"retained downloaded Deb {index}")
        digest_value = sha256(deb_path)
        if metadata.st_size != int(fields[f"Downloaded Deb {index} size"]) or digest_value != fields[
            f"Downloaded Deb {index} SHA256"
        ]:
            fail(f"retained downloaded Deb differs from sidecar at row {index}")
        identity = (
            fields[f"Downloaded Deb {index} package"],
            fields[f"Downloaded Deb {index} version"],
            fields[f"Downloaded Deb {index} architecture"],
        )
        matches = package_records.get(identity, [])
        expected_filename = fields[f"Downloaded Deb {index} archive filename"]
        if not matches or any(
            size != metadata.st_size or digest != digest_value or filename != expected_filename
            for size, digest, filename, _location in matches
        ):
            fail(f"retained Deb is not consistently authenticated by signed indexes: row {index}")
        locations = [location for _size, _digest, _filename, location in matches]
        recorded = [
            fields[f"Downloaded Deb {index} signed record {record} location"]
            for record in range(1, int(fields[f"Downloaded Deb {index} signed record count"]) + 1)
        ]
        if locations != recorded:
            fail(f"retained Deb signed-record locations differ from sidecar: row {index}")
    for entry in archives.iterdir():
        metadata = entry.lstat()
        if entry in expected_deb_paths and stat.S_ISREG(metadata.st_mode):
            continue
        if entry.name == "lock" and stat.S_ISREG(metadata.st_mode):
            continue
        if entry.name == "partial" and stat.S_ISDIR(metadata.st_mode) and not entry.is_symlink() and not any(entry.iterdir()):
            continue
        fail(f"retained APT archive has an unexpected entry: {entry.name}")
    if {path for path in archives.glob("*.deb")} != expected_deb_paths:
        fail("retained APT archive Deb set differs from sidecar")

    expected_list_names = expected_list_targets(baseline)
    actual_list_files: set[str] = set()
    for entry in lists.iterdir():
        metadata = entry.lstat()
        if stat.S_ISREG(metadata.st_mode):
            actual_list_files.add(entry.name)
            continue
        if entry.name in ("partial", "auxfiles") and stat.S_ISDIR(metadata.st_mode) and not entry.is_symlink() and not any(entry.iterdir()):
            continue
        fail(f"retained APT lists have an unexpected entry: {entry.name}")
    if actual_list_files != set(expected_list_names):
        fail("retained APT list target set differs from reviewed set")
    for index, name in enumerate(expected_list_names, 1):
        path = lists / name
        metadata = regular_file(path, f"retained APT list target {index}")
        if metadata.st_size != int(fields[f"APT list target {index} size"]) or sha256(path) != fields[
            f"APT list target {index} SHA256"
        ]:
            fail(f"retained APT list target differs from sidecar: {name}")
    for suite, relative in index_sequence:
        full_path = f"{suite}/{relative}"
        local = lists / local_list_name(snapshot_id, suite, relative)
        if full_path in declared_empty:
            if os.path.lexists(local):
                fail(f"declared empty index has a retained APT local-list view: {full_path}")
            continue
        regular_file(local, f"retained APT local-list view {full_path}")
        if (
            apt_list_identity(
                local, baseline, decompressed_indexes[full_path]
            )
            != decompressed_indexes[full_path]
        ):
            fail(
                "retained APT local-list bytes differ from the signed gzip index: "
                f"{full_path}"
            )

    local_paths = sorted(local_dir.glob("*-build-deps_*.deb"), key=lambda path: path.name)
    if len(local_paths) != 1 or local_paths[0].name != fields["Local build-deps 1 path"]:
        fail("retained local build-deps Deb set differs from sidecar")
    metadata = regular_file(local_paths[0], "retained local build-deps Deb")
    if metadata.st_size != int(fields["Local build-deps 1 size"]) or sha256(local_paths[0]) != fields[
        "Local build-deps 1 SHA256"
    ]:
        fail("retained local build-deps Deb differs from sidecar")


def control_expected_sha256(args: argparse.Namespace, label: str) -> str | None:
    return {
        "build-arguments": args.build_args_sha256,
        "entrypoint": args.entrypoint_sha256,
        "oci-index": args.oci_index_sha256,
    }.get(label)


def retained_snapshot(args: argparse.Namespace) -> tuple[tuple[object, ...], ...]:
    rows: list[tuple[object, ...]] = []
    entry_count = 0
    aggregate_path_bytes = 0
    aggregate_file_bytes = 0

    def reserve(path_text: str, size: int) -> None:
        nonlocal entry_count, aggregate_path_bytes, aggregate_file_bytes
        try:
            encoded = path_text.encode("ascii")
        except UnicodeEncodeError:
            fail("retained snapshot contains a non-ASCII path")
        entry_count += 1
        aggregate_path_bytes += len(encoded)
        aggregate_file_bytes += size
        if (
            not encoded
            or len(encoded) > MAX_VALIDATED_PATH_BYTES
            or entry_count > MAX_VALIDATED_INPUTS
            or aggregate_path_bytes > MAX_VALIDATED_AGGREGATE_PATH_BYTES
            or size > MAX_VALIDATED_MEMBER_BYTES
            or aggregate_file_bytes > MAX_VALIDATED_INPUT_BYTES
        ):
            fail("retained snapshot exceeds its entry/path/byte bound")

    for label, root in (
        ("archives", args.apt_archives_dir),
        ("indexes", args.apt_index_cache_dir),
        ("lists", args.apt_lists_dir),
    ):
        real_directory(root, f"retained {label}")
        discovered: list[tuple[Path, str, os.stat_result]] = []

        def discover(directory: Path, prefix: str, depth: int) -> None:
            if depth > MAX_VALIDATED_DEPTH:
                fail(f"retained {label} exceeds its path-depth bound")
            try:
                entries = os.scandir(directory)
            except OSError as exc:
                fail(f"could not scan retained {label}: {exc}")
            with entries:
                for entry in entries:
                    try:
                        entry.name.encode("ascii")
                    except UnicodeEncodeError:
                        fail(f"retained {label} contains a non-ASCII name")
                    if not PATH_COMPONENT_RE.fullmatch(entry.name):
                        fail(f"retained {label} contains an unsafe name")
                    relative = f"{prefix}/{entry.name}" if prefix else entry.name
                    try:
                        metadata = entry.stat(follow_symlinks=False)
                    except OSError as exc:
                        fail(f"could not inspect retained {label}/{relative}: {exc}")
                    if stat.S_ISDIR(metadata.st_mode):
                        reserve(f"{label}/{relative}/", 0)
                        discovered.append((Path(entry.path), relative + "/", metadata))
                        discover(Path(entry.path), relative, depth + 1)
                    elif stat.S_ISREG(metadata.st_mode):
                        if metadata.st_nlink != 1:
                            fail(f"retained {label} file has an unsafe link count: {relative}")
                        reserve(f"{label}/{relative}", metadata.st_size)
                        discovered.append((Path(entry.path), relative, metadata))
                    else:
                        fail(
                            f"retained {label} contains a symlink or special path: {relative}"
                        )

        discover(root, "", 1)
        discovered.sort(key=lambda item: item[1].encode("ascii"))
        for path, relative, metadata in discovered:
            if relative.endswith("/"):
                current = path.lstat()
                if (
                    not stat.S_ISDIR(current.st_mode)
                    or (metadata.st_dev, metadata.st_ino, metadata.st_mode)
                    != (current.st_dev, current.st_ino, current.st_mode)
                ):
                    fail(f"retained {label} directory changed during its scan")
                rows.append((label, relative, 0, "directory"))
            else:
                rows.append(
                    (
                        label,
                        relative,
                        *stable_file_snapshot(path, f"retained {label}/{relative}"),
                    )
                )
    stable_files = [
        ("build-arguments", args.build_args),
        ("entrypoint", args.entrypoint),
        ("oci-index", args.oci_index),
        ("build-manifest", args.build_manifest),
        ("pre-inventory", args.apt_pre_inventory),
        ("post-inventory", args.apt_post_inventory),
        ("sidecar", args.apt_provenance),
    ]
    if args.mode in ("validate", "validate-release-snapshot"):
        stable_files.append(("build-inputs", args.output))
    for label, path in stable_files:
        assert path is not None
        metadata = regular_file(path, label)
        reserve(f"{label}/{path.name}", metadata.st_size)
        snapshot = stable_file_snapshot(path, label)
        digest_label = {
            "build-arguments": "Docker build arguments",
            "entrypoint": "Docker entrypoint",
            "oci-index": "OCI index",
        }.get(label, label)
        require_expected_digest(
            snapshot, control_expected_sha256(args, label), digest_label
        )
        rows.append((label, path.name, *snapshot))
    local_paths: list[Path] = []
    try:
        local_entries = os.scandir(args.apt_local_build_deps_dir)
    except OSError as exc:
        fail(f"could not scan retained local build-deps: {exc}")
    with local_entries:
        for entry in local_entries:
            if not entry.name.endswith(".deb") or "-build-deps_" not in entry.name:
                continue
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as exc:
                fail(f"could not inspect retained local build-deps: {exc}")
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                fail("retained local build-deps contains an unsafe node")
            reserve(f"local-build-deps/{entry.name}", metadata.st_size)
            local_paths.append(Path(entry.path))
    local_paths.sort(key=lambda path: path.name.encode("ascii"))
    for path in local_paths:
        rows.append(
            (
                "local-build-deps",
                path.name,
                *stable_file_snapshot(path, "local build-deps snapshot"),
            )
        )
    return tuple(rows)


def git_object_format(value: str, label: str) -> str:
    if re.fullmatch(r"[0-9a-f]{40}", value):
        return "sha1"
    if re.fullmatch(r"[0-9a-f]{64}", value):
        return "sha256"
    fail(f"{label} is not a canonical full Git object ID")


def git_blob_object_id(payload: bytes, object_format: str) -> str:
    if object_format == "sha1":
        digest = hashlib.sha1()
    elif object_format == "sha256":
        digest = hashlib.sha256()
    else:
        fail("unsupported Git object format")
    digest.update(f"blob {len(payload)}\0".encode("ascii"))
    digest.update(payload)
    return digest.hexdigest()


def code_identity(
    path: Path,
    label: str,
    logical_path: str,
    git_mode: str,
    expected_sha256: str,
    expected_object_id: str,
    expected_object_format: str,
) -> tuple[str, str, str, int, str, str, str]:
    if git_mode not in ("100644", "100755"):
        fail(f"{label} Git mode is not canonical")
    expected_runtime_mode = 0o755 if git_mode == "100755" else 0o644
    if not SHA256_RE.fullmatch(expected_sha256):
        fail(f"{label} expected SHA256 is not canonical")
    if git_object_format(expected_object_id, f"{label} Git object ID") != expected_object_format:
        fail(f"{label} Git object format differs from the invocation")
    raw, snapshot = stable_file_bytes(path, label, maximum_size=512 * 1024)
    metadata = path.lstat()
    runtime_mode = stat.S_IMODE(metadata.st_mode)
    if runtime_mode != expected_runtime_mode or metadata.st_nlink != 1:
        fail(f"{label} runtime mode or link count differs from its committed mode")
    if snapshot[5] != expected_sha256:
        fail(f"{label} raw bytes differ from the expected SHA256")
    if git_blob_object_id(raw, expected_object_format) != expected_object_id:
        fail(f"{label} raw bytes differ from the expected Git blob")
    if stable_file_snapshot(path, label) != snapshot:
        fail(f"{label} changed during its code-identity validation")
    return (
        logical_path,
        git_mode,
        f"{runtime_mode:04o}",
        len(raw),
        expected_sha256,
        expected_object_id,
        expected_object_format,
    )


def exact_validator_argv() -> tuple[str, ...]:
    original = tuple(getattr(sys, "orig_argv", ()))
    if not original:
        # Apple's fixed /usr/bin/python3 is still Python 3.9 and does not
        # expose sys.orig_argv.  This is a fixture-portability boundary only:
        # Linux production must attest the interpreter-provided exact vector.
        if (
            sys.platform != "darwin"
            or sys.flags.isolated != 1
            or sys.warnoptions
            or sys._xoptions
        ):
            fail("pre-seal validation cannot recover its exact Python argv")
        original = (FIXED_PYTHON, "-I", *sys.argv)
    if (
        len(original) < 4
        or len(original) > MAX_VALIDATOR_ARGV
        or original[0] != FIXED_PYTHON
        or original[1] != "-I"
        or original[2] != sys.argv[0]
        or not os.path.isabs(original[2])
        or tuple(original[2:]) != tuple(sys.argv)
        or sys.flags.isolated != 1
        or sys.argv[1] != "validate"
    ):
        fail("pre-seal validation requires the exact isolated Python argv shape")
    aggregate = 0
    for argument in original:
        try:
            encoded = argument.encode("ascii")
        except UnicodeEncodeError:
            fail("pre-seal validator argv is not ASCII")
        aggregate += len(encoded) + 1
        if (
            not encoded
            or len(encoded) > MAX_VALIDATOR_ARG_BYTES
            or aggregate > MAX_ATTESTATION_BYTES
            or any(byte < 0x20 or byte == 0x7F for byte in encoded)
        ):
            fail("pre-seal validator argv is empty, unsafe, or oversized")
    return original


def managed_state_snapshot(
    work_dir: Path,
    *,
    attestation_present: bool,
) -> tuple[tuple[object, ...], ...]:
    """Snapshot the complete bounded managed namespace through held parents."""

    work_path = real_directory(work_dir, "managed validation work root")
    required_flags = ("O_CLOEXEC", "O_NOFOLLOW", "O_NONBLOCK", "O_DIRECTORY")
    if any(not hasattr(os, name) for name in required_flags):
        fail("managed validation walk requires no-follow directory descriptors")
    directory_flags = (
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_DIRECTORY
    )
    file_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK

    def stable(metadata: os.stat_result) -> tuple[int, ...]:
        return (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mode,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            metadata.st_nlink,
            metadata.st_uid,
            metadata.st_gid,
        )

    def validate_component(name: str) -> bytes:
        try:
            encoded = name.encode("ascii")
        except UnicodeEncodeError:
            fail("managed validation state contains a non-ASCII name")
        if (
            not encoded
            or len(encoded) > 255
            or name in (".", "..")
            or not PATH_COMPONENT_RE.fullmatch(name)
        ):
            fail("managed validation state contains an unsafe name")
        return encoded

    records: list[tuple[object, ...]] = []
    aggregate_path_bytes = 0
    aggregate_input_bytes = 0
    seen_paths: set[str] = set()

    def add_record(
        relative: str,
        node_type: str,
        metadata: os.stat_result,
        digest: str,
    ) -> None:
        nonlocal aggregate_path_bytes, aggregate_input_bytes
        try:
            encoded = relative.encode("ascii")
        except UnicodeEncodeError:
            fail("managed validation state contains a non-ASCII path")
        aggregate_path_bytes += len(encoded)
        if (
            not encoded
            or len(encoded) > MAX_VALIDATED_PATH_BYTES
            or aggregate_path_bytes > MAX_VALIDATED_AGGREGATE_PATH_BYTES
            or len(records) >= MAX_VALIDATED_INPUTS
            or relative in seen_paths
        ):
            fail("managed validation state exceeds its path/member bound")
        if node_type == "regular":
            aggregate_input_bytes += metadata.st_size
            if (
                metadata.st_size > MAX_VALIDATED_MEMBER_BYTES
                or aggregate_input_bytes > MAX_VALIDATED_INPUT_BYTES
            ):
                fail("managed validation state exceeds its byte bound")
        seen_paths.add(relative)
        records.append(
            (
                relative,
                node_type,
                f"{stat.S_IMODE(metadata.st_mode):04o}",
                metadata.st_size if node_type == "regular" else 0,
                digest,
                *stable(metadata),
            )
        )

    root = os.open(work_path, directory_flags)
    try:
        root_before = os.fstat(root)
        root_mapped = work_path.lstat()
        if (
            not stat.S_ISDIR(root_before.st_mode)
            or (root_before.st_dev, root_before.st_ino)
            != (root_mapped.st_dev, root_mapped.st_ino)
        ):
            fail("managed validation work root changed before its walk")

        expected_root_names = set(MANAGED_WORK_NAMES)
        if attestation_present:
            expected_root_names.add(PRESEAL_ATTESTATION_NAME)
        actual_root_names: set[str] = set()
        with os.scandir(root) as entries:
            for entry in entries:
                validate_component(entry.name)
                actual_root_names.add(entry.name)
                if len(actual_root_names) > len(expected_root_names):
                    fail("managed validation work root has an unexpected member")
        if actual_root_names != expected_root_names:
            fail("managed validation work-root membership is not exact")

        def walk(directory: int, prefix: str, depth: int) -> None:
            if depth > MAX_VALIDATED_DEPTH:
                fail("managed validation state exceeds its depth bound")
            directory_before = os.fstat(directory)
            if not stat.S_ISDIR(directory_before.st_mode):
                fail("managed validation directory descriptor changed type")
            local_names: set[str] = set()
            with os.scandir(directory) as entries:
                for entry in entries:
                    name = entry.name
                    validate_component(name)
                    if name in local_names:
                        fail("managed validation directory contains a duplicate name")
                    local_names.add(name)
                    if len(local_names) > MAX_VALIDATED_INPUTS:
                        fail("managed validation directory exceeds its member bound")
                    relative = f"{prefix}/{name}" if prefix else name
                    before = os.stat(name, dir_fd=directory, follow_symlinks=False)
                    if not prefix and name == PRESEAL_ATTESTATION_NAME:
                        if not attestation_present or not stat.S_ISREG(before.st_mode):
                            fail("managed validation attestation mapping is unsafe")
                        continue
                    if stat.S_ISDIR(before.st_mode):
                        child = os.open(name, directory_flags, dir_fd=directory)
                        try:
                            held = os.fstat(child)
                            if stable(held) != stable(before):
                                fail("managed validation directory changed before open")
                            add_record(relative, "directory", held, "-")
                            walk(child, relative, depth + 1)
                            after = os.fstat(child)
                            remapped = os.stat(
                                name, dir_fd=directory, follow_symlinks=False
                            )
                            if stable(held) != stable(after) or stable(after) != stable(remapped):
                                fail("managed validation directory changed during walk")
                        finally:
                            os.close(child)
                    elif stat.S_ISREG(before.st_mode):
                        if before.st_nlink != 1 or before.st_size > MAX_VALIDATED_MEMBER_BYTES:
                            fail("managed validation file has an unsafe link count or size")
                        child = os.open(name, file_flags, dir_fd=directory)
                        try:
                            held = os.fstat(child)
                            if stable(held) != stable(before):
                                fail("managed validation file changed before open")
                            digest = hashlib.sha256()
                            offset = 0
                            while offset < held.st_size:
                                chunk = os.pread(
                                    child, min(1024 * 1024, held.st_size - offset), offset
                                )
                                if not chunk:
                                    fail("managed validation file ended before its size")
                                digest.update(chunk)
                                offset += len(chunk)
                            if os.pread(child, 1, held.st_size):
                                fail("managed validation file grew during hashing")
                            after = os.fstat(child)
                            remapped = os.stat(
                                name, dir_fd=directory, follow_symlinks=False
                            )
                            if stable(held) != stable(after) or stable(after) != stable(remapped):
                                fail("managed validation file changed during hashing")
                            add_record(relative, "regular", after, digest.hexdigest())
                        finally:
                            os.close(child)
                    else:
                        fail("managed validation state contains a symlink or special node")
            directory_after = os.fstat(directory)
            if stable(directory_before) != stable(directory_after):
                fail("managed validation directory changed during membership scan")

        walk(root, "", 1)
        root_after = os.fstat(root)
        root_remapped = work_path.lstat()
        if stable(root_before) != stable(root_after) or (
            root_after.st_dev,
            root_after.st_ino,
        ) != (root_remapped.st_dev, root_remapped.st_ino):
            fail("managed validation work root changed during its walk")
    finally:
        os.close(root)

    records.sort(key=lambda row: str(row[0]).encode("ascii"))
    return tuple(records)


def render_preseal_attestation(
    args: argparse.Namespace,
    baseline: dict[str, str],
    validator_argv: tuple[str, ...],
    build_inputs_identity: tuple[str, str, str, int, str, str, str],
    manifest_validator_identity: tuple[str, str, str, int, str, str, str],
    managed: tuple[tuple[object, ...], ...],
) -> bytes:
    lines = [
        f"Kernel pre-seal validation schema: {PRESEAL_ATTESTATION_SCHEMA}",
        "Validation mode: validate",
        "Python isolated mode: true",
        f"Validator argv schema: {VALIDATOR_ARGV_SCHEMA}",
        f"Git object format: {args.git_object_format}",
        f"Validator argv count: {len(validator_argv)}",
    ]
    lines.extend(
        f"Validator argv {index}: {argument}"
        for index, argument in enumerate(validator_argv, 1)
    )
    lines.extend(
        (
            f"Support HEAD: {args.support_head}",
            f"Kernel baseline SHA256: {args.baseline_sha256}",
            f"Container image: {required(baseline, 'SP11_KERNEL_DOCKER_IMAGE')}",
            f"Container platform: {required(baseline, 'SP11_KERNEL_DOCKER_PLATFORM')}",
        )
    )
    for prefix, identity in (
        ("Build-inputs helper", build_inputs_identity),
        ("Manifest validator", manifest_validator_identity),
    ):
        path, git_mode, runtime_mode, size, digest, object_id, object_format = identity
        lines.extend(
            (
                f"{prefix} path: {path}",
                f"{prefix} Git mode: {git_mode}",
                f"{prefix} runtime mode: {runtime_mode}",
                f"{prefix} size: {size}",
                f"{prefix} SHA256: {digest}",
                f"{prefix} Git object ID: {object_id}",
                f"{prefix} object format: {object_format}",
            )
        )
    lines.append(f"Validated input count: {len(managed)}")
    for index, row in enumerate(managed, 1):
        path, node_type, mode, size, digest = row[:5]
        lines.extend(
            (
                f"Validated input {index} path: {path}",
                f"Validated input {index} type: {node_type}",
                f"Validated input {index} mode: {mode}",
                f"Validated input {index} size: {size}",
                f"Validated input {index} SHA256: {digest}",
            )
        )
    lines.append("Validation complete: true")
    rendered = ("\n".join(lines) + "\n").encode("ascii")
    if len(rendered) > MAX_ATTESTATION_BYTES:
        fail("pre-seal validation attestation exceeds its byte bound")
    return rendered


def validate_oci_index(
    path: Path, baseline: dict[str, str], expected_sha256: str | None = None
) -> None:
    raw, snapshot = stable_file_bytes(path, "OCI index", maximum_size=64 * 1024 * 1024)
    require_expected_digest(snapshot, expected_sha256, "OCI index")
    expected_index = required(baseline, "SP11_KERNEL_DOCKER_IMAGE").rsplit("@", 1)[1]
    if "sha256:" + hashlib.sha256(raw).hexdigest() != expected_index:
        fail("bound OCI index bytes do not match the pinned image digest")
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"bound OCI index is invalid JSON: {exc}")
    if document.get("schemaVersion") != 2 or not isinstance(document.get("manifests"), list):
        fail("bound OCI index has an invalid schema")
    platform_parts = required(baseline, "SP11_KERNEL_DOCKER_PLATFORM").split("/")
    matches = []
    for descriptor in document["manifests"]:
        if not isinstance(descriptor, dict) or not isinstance(descriptor.get("platform"), dict):
            continue
        platform = descriptor["platform"]
        if (
            platform.get("os") == platform_parts[0]
            and platform.get("architecture") == platform_parts[1]
            and (len(platform_parts) == 2 or platform.get("variant") == platform_parts[2])
        ):
            matches.append(descriptor)
    expected_child = required(baseline, "SP11_KERNEL_DOCKER_PLATFORM_MANIFEST")
    if len(matches) != 1 or matches[0].get("digest") != expected_child:
        fail("bound OCI index does not contain the unique pinned ARM64 child")


def validate_manifest(
    path: Path, baseline: dict[str, str], support_head: str
) -> None:
    manifest = parse_unique_lines(path)
    checks = (
        ("Provenance schema", "sp11-kernel-build-v2"),
        ("Release build", "true"),
        ("Support start HEAD", support_head),
        ("Support start dirty", "false"),
        ("Support end HEAD", support_head),
        ("Support end dirty", "false"),
        ("Source mode", "git"),
        ("Source URL", required(baseline, "SP11_KERNEL_UPSTREAM_URL")),
        ("Source ref", required(baseline, "SP11_KERNEL_UPSTREAM_REF")),
        ("Expected source commit", required(baseline, "SP11_KERNEL_UPSTREAM_COMMIT")),
        ("Source HEAD", required(baseline, "SP11_KERNEL_UPSTREAM_COMMIT")),
        ("Container image", required(baseline, "SP11_KERNEL_DOCKER_IMAGE")),
        (
            "Container digest",
            required(baseline, "SP11_KERNEL_DOCKER_IMAGE").rsplit("@", 1)[1],
        ),
        ("Container platform", required(baseline, "SP11_KERNEL_DOCKER_PLATFORM")),
        ("Build target", required(baseline, "SP11_KERNEL_BUILD_TARGET")),
        ("Build completed", "true"),
    )
    for key, expected in checks:
        if required(manifest, key) != expected:
            fail(f"kernel build manifest {key} does not match immutable inputs")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        choices=("write", "validate", "validate-attached", "validate-release-snapshot"),
    )
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--baseline-sha256")
    parser.add_argument("--build-args-sha256")
    parser.add_argument("--entrypoint-sha256")
    parser.add_argument("--oci-index-sha256")
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--support-head", required=True)
    parser.add_argument("--build-args", type=Path)
    parser.add_argument("--entrypoint", type=Path)
    parser.add_argument("--oci-index", type=Path)
    parser.add_argument("--build-manifest", required=True, type=Path)
    parser.add_argument("--apt-provenance", required=True, type=Path)
    parser.add_argument("--apt-archives-dir", type=Path)
    parser.add_argument("--apt-lists-dir", type=Path)
    parser.add_argument("--apt-index-cache-dir", type=Path)
    parser.add_argument("--apt-local-build-deps-dir", type=Path)
    parser.add_argument("--apt-pre-inventory", type=Path)
    parser.add_argument("--apt-post-inventory", type=Path)
    parser.add_argument("--apt-bootstrap-state", type=Path)
    parser.add_argument("--attestation-output", type=Path)
    parser.add_argument("--git-object-format", choices=("sha1", "sha256"))
    parser.add_argument("--build-inputs-helper-sha256")
    parser.add_argument("--build-inputs-helper-object-id")
    parser.add_argument("--manifest-validator-sha256")
    parser.add_argument("--manifest-validator-object-id")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    expected_control_hashes = (
        args.build_args_sha256,
        args.entrypoint_sha256,
        args.oci_index_sha256,
    )
    if any(value is not None for value in expected_control_hashes) and not all(
        value is not None for value in expected_control_hashes
    ):
        parser.error(
            "private control SHA256 options must be supplied together: "
            "--build-args-sha256 --entrypoint-sha256 --oci-index-sha256"
        )
    for value in expected_control_hashes:
        if value is not None and not SHA256_RE.fullmatch(value):
            parser.error("private control SHA256 options must be canonical lowercase SHA-256")
    attestation_values = (
        args.apt_bootstrap_state,
        args.attestation_output,
        args.git_object_format,
        args.build_inputs_helper_sha256,
        args.build_inputs_helper_object_id,
        args.manifest_validator_sha256,
        args.manifest_validator_object_id,
    )
    if args.mode == "validate":
        if any(value is None for value in attestation_values):
            parser.error(
                "validate requires bootstrap, attestation, Git format, and exact code identities"
            )
        for value in (
            args.build_inputs_helper_sha256,
            args.manifest_validator_sha256,
        ):
            if value is None or not SHA256_RE.fullmatch(value):
                parser.error("validate code SHA256 options must be canonical lowercase SHA-256")
        for value in (
            args.build_inputs_helper_object_id,
            args.manifest_validator_object_id,
        ):
            if value is None or not COMMIT_RE.fullmatch(value):
                parser.error("validate code object IDs must be canonical lowercase full IDs")
    elif any(value is not None for value in attestation_values):
        parser.error("pre-seal attestation options are valid only with validate")
    if args.mode != "validate-attached":
        required = (
            "work_dir",
            "build_args",
            "entrypoint",
            "oci_index",
            "apt_archives_dir",
            "apt_lists_dir",
            "apt_index_cache_dir",
            "apt_local_build_deps_dir",
            "apt_pre_inventory",
            "apt_post_inventory",
        )
        missing = [f"--{name.replace('_', '-')}" for name in required if getattr(args, name) is None]
        if missing:
            parser.error(f"{args.mode} requires: {' '.join(missing)}")
    return args


def envelope_keys() -> list[str]:
    keys = [
        "Build inputs schema",
        "Release build",
        "Support HEAD",
        "OCI index image",
        "OCI index digest",
        "OCI platform",
        "OCI platform manifest",
        "Input count",
    ]
    for index in range(1, len(INPUT_ROLES) + 1):
        keys.extend(
            (
                f"Input {index} role",
                f"Input {index} path",
                f"Input {index} size",
                f"Input {index} SHA256",
            )
        )
    keys.extend(("Publication schema propagation", "Build inputs complete"))
    return keys


def validate_envelope(args: argparse.Namespace, baseline: dict[str, str]) -> None:
    assert args.work_dir is not None
    assert args.build_args is not None
    assert args.entrypoint is not None
    assert args.oci_index is not None
    fields = parse_unique_lines(args.output)
    exact_keys(fields, envelope_keys(), "build-inputs envelope")
    if required(fields, "Build inputs schema") != "sp11-kernel-build-inputs-v1":
        fail("unsupported build-inputs schema")
    if required(fields, "Release build") != "true":
        fail("build-inputs envelope is not marked as a release build")
    if required(fields, "Support HEAD") != args.support_head:
        fail("build-inputs support HEAD changed")
    if required(fields, "OCI index image") != required(
        baseline, "SP11_KERNEL_DOCKER_IMAGE"
    ):
        fail("build-inputs OCI index image does not match baseline")
    if required(fields, "OCI index digest") != required(
        baseline, "SP11_KERNEL_DOCKER_IMAGE"
    ).rsplit("@", 1)[1]:
        fail("build-inputs OCI index digest does not match baseline")
    if required(fields, "OCI platform") != required(
        baseline, "SP11_KERNEL_DOCKER_PLATFORM"
    ):
        fail("build-inputs OCI platform does not match baseline")
    if required(fields, "OCI platform manifest") != required(
        baseline, "SP11_KERNEL_DOCKER_PLATFORM_MANIFEST"
    ):
        fail("build-inputs OCI platform manifest does not match baseline")
    if required(fields, "Input count") != str(len(INPUT_ROLES)):
        fail("build-inputs envelope has an unexpected input count")
    if required(fields, "Publication schema propagation") != "incomplete":
        fail("build-inputs publication propagation state is ambiguous")
    if required(fields, "Build inputs complete") != "true":
        fail("build-inputs envelope is incomplete")

    inputs = (
        args.build_args,
        args.entrypoint,
        args.oci_index,
        args.build_manifest,
        args.apt_provenance,
    )
    expected_digests = (
        args.build_args_sha256,
        args.entrypoint_sha256,
        args.oci_index_sha256,
        None,
        None,
    )
    for index, (role, path, expected_digest) in enumerate(
        zip(INPUT_ROLES, inputs, expected_digests), 1
    ):
        relative, size, digest = safe_input(
            args.work_dir, path, role, expected_digest
        )
        if required(fields, f"Input {index} role") != role:
            fail(f"build-inputs role mismatch at input {index}")
        if required(fields, f"Input {index} path") != relative:
            fail(f"build-inputs path mismatch at input {index}")
        if required(fields, f"Input {index} size") != str(size):
            fail(f"build-inputs size mismatch at input {index}")
        if required(fields, f"Input {index} SHA256") != digest:
            fail(f"build-inputs hash mismatch at input {index}")
        if index == 3 and digest != required(fields, "OCI index digest").removeprefix(
            "sha256:"
        ):
            fail("build-inputs raw OCI index hash does not match its index digest")


def validate_exact_build_manifest(path: Path, support_head: str) -> None:
    repo_dir = Path(__file__).resolve().parent.parent
    validator = repo_dir / "scripts/validate-sp11-image-release-manifests.py"
    regular_file(validator, "exact schema-v2 build-manifest validator")
    directory_descriptor, target_descriptor, python_authority = (
        _acquire_fixed_python_authority()
    )
    command = (
        FIXED_PYTHON,
        "-I",
        str(validator),
        "--build-only",
        "--repo-dir",
        str(repo_dir),
        "--support-commit",
        support_head,
        "--kernel-build-manifest",
        str(path),
    )
    try:
        _verify_fixed_python_authority(
            directory_descriptor,
            target_descriptor,
            python_authority,
        )
        require_child_wait_authority()
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        _verify_fixed_python_authority(
            directory_descriptor,
            target_descriptor,
            python_authority,
        )
    finally:
        os.close(target_descriptor)
        os.close(directory_descriptor)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        fail(
            "attached kernel build manifest failed exact schema-v2 validation"
            + (f": {detail}" if detail else "")
        )


def attached_trio_snapshot(
    args: argparse.Namespace,
) -> tuple[tuple[int, int, int, int, int, str], ...]:
    return tuple(
        stable_file_snapshot(path, label)
        for path, label in (
            (args.build_manifest, "attached kernel build manifest"),
            (args.apt_provenance, "attached APT provenance"),
            (args.output, "attached build-inputs envelope"),
        )
    )


def validate_attached(args: argparse.Namespace, baseline: dict[str, str]) -> None:
    """Validate the self-contained release copy of the immutable build trio."""

    before = attached_trio_snapshot(args)
    validate_exact_build_manifest(args.build_manifest, args.support_head)
    validate_manifest(args.build_manifest, baseline, args.support_head)
    validate_apt_sidecar(args.apt_provenance, baseline)

    fields = parse_unique_lines(args.output)
    exact_keys(fields, envelope_keys(), "build-inputs envelope")
    if required(fields, "Build inputs schema") != "sp11-kernel-build-inputs-v1":
        fail("unsupported build-inputs schema")
    if required(fields, "Release build") != "true":
        fail("build-inputs envelope is not marked as a release build")
    if required(fields, "Support HEAD") != args.support_head:
        fail("build-inputs support HEAD changed")

    image = required(baseline, "SP11_KERNEL_DOCKER_IMAGE")
    index_digest = image.rsplit("@", 1)[1]
    platform = required(baseline, "SP11_KERNEL_DOCKER_PLATFORM")
    platform_manifest = required(baseline, "SP11_KERNEL_DOCKER_PLATFORM_MANIFEST")
    for label, expected in (
        ("OCI index image", image),
        ("OCI index digest", index_digest),
        ("OCI platform", platform),
        ("OCI platform manifest", platform_manifest),
    ):
        if required(fields, label) != expected:
            fail(f"build-inputs {label} does not match baseline/build provenance")
    if required(fields, "Input count") != str(len(INPUT_ROLES)):
        fail("build-inputs envelope has an unexpected input count")
    if required(fields, "Publication schema propagation") != "incomplete":
        fail("build-envelope creation propagation state is not the literal build-time fact")
    if required(fields, "Build inputs complete") != "true":
        fail("build-inputs envelope is incomplete")

    expected_paths = (
        "docker-build-args.txt",
        "docker-build-inside.sh",
        "sp11-oci-index.json",
        "artifacts/sp11-kernel-build-manifest.txt",
        "artifacts/sp11-kernel-apt-provenance.txt",
    )
    attached = {
        4: args.build_manifest,
        5: args.apt_provenance,
    }
    for index, (role, path_value) in enumerate(zip(INPUT_ROLES, expected_paths), 1):
        if required(fields, f"Input {index} role") != role:
            fail(f"build-inputs role mismatch at input {index}")
        if required(fields, f"Input {index} path") != path_value:
            fail(f"build-inputs path mismatch at input {index}")
        size_value = required(fields, f"Input {index} size")
        digest_value = required(fields, f"Input {index} SHA256")
        if not size_value.isdigit() or int(size_value) <= 0:
            fail(f"build-inputs size is invalid at input {index}")
        if not SHA256_RE.fullmatch(digest_value):
            fail(f"build-inputs hash is invalid at input {index}")
        if index == 3 and digest_value != index_digest.removeprefix("sha256:"):
            fail("build-inputs raw OCI index hash does not match its index digest")
        if index in attached:
            snapshot = before[index - 4]
            if snapshot[2] != int(size_value):
                fail(f"attached {role} size differs from build-inputs envelope")
            if snapshot[5] != digest_value:
                fail(f"attached {role} hash differs from build-inputs envelope")
    if attached_trio_snapshot(args) != before:
        fail("attached immutable build-input trio changed during validation")


def validate_release_snapshot(
    args: argparse.Namespace, baseline: dict[str, str]
) -> None:
    """Bind a private release trio directly to every retained/live build input."""

    assert args.work_dir is not None
    assert args.build_args is not None
    assert args.entrypoint is not None
    assert args.oci_index is not None
    before = retained_snapshot(args)

    build_arguments_snapshot = validate_build_arguments(
        args.build_args, baseline, args.build_args_sha256
    )
    if (
        "build-arguments",
        args.build_args.name,
        *build_arguments_snapshot,
    ) not in before:
        fail("Docker build arguments changed before semantic validation")
    validate_attached(args, baseline)
    apt_fields = validate_apt_sidecar(args.apt_provenance, baseline)
    validate_retained_apt(args, apt_fields, baseline)
    validate_oci_index(args.oci_index, baseline, args.oci_index_sha256)

    envelope = parse_unique_lines(args.output)
    live_inputs = (args.build_args, args.entrypoint, args.oci_index)
    expected_paths = (
        "docker-build-args.txt",
        "docker-build-inside.sh",
        "sp11-oci-index.json",
    )
    expected_digests = (
        args.build_args_sha256,
        args.entrypoint_sha256,
        args.oci_index_sha256,
    )
    for index, (role, path, expected_path, expected_digest) in enumerate(
        zip(INPUT_ROLES[:3], live_inputs, expected_paths, expected_digests), 1
    ):
        relative, size, digest = safe_input(
            args.work_dir, path, role, expected_digest
        )
        if relative != expected_path:
            fail(f"live release input path changed at row {index}")
        if required(envelope, f"Input {index} role") != role:
            fail(f"release-snapshot role mismatch at input {index}")
        if required(envelope, f"Input {index} path") != expected_path:
            fail(f"release-snapshot path mismatch at input {index}")
        if required(envelope, f"Input {index} size") != str(size):
            fail(f"release-snapshot size mismatch at input {index}")
        if required(envelope, f"Input {index} SHA256") != digest:
            fail(f"release-snapshot hash mismatch at input {index}")

    if retained_snapshot(args) != before:
        fail("release-snapshot inputs changed during direct retained-input validation")


def main() -> None:
    establish_child_wait_authority()
    args = parse_args()
    validator_argv: tuple[str, ...] | None = None
    build_inputs_identity: tuple[str, str, str, int, str, str, str] | None = None
    manifest_validator_identity: tuple[str, str, str, int, str, str, str] | None = None
    if not COMMIT_RE.fullmatch(args.support_head):
        fail("support HEAD must be a full lowercase commit")
    if args.mode == "validate":
        validator_argv = exact_validator_argv()
        if (
            args.baseline_sha256 is None
            or not SHA256_RE.fullmatch(args.baseline_sha256)
            or git_object_format(args.support_head, "support HEAD")
            != args.git_object_format
        ):
            fail("pre-seal validation authority fields are incomplete or inconsistent")
    baseline = read_baseline(args.baseline, args.baseline_sha256)
    if tuple(required(baseline, "SP11_APT_SNAPSHOT_SUITES").split()) != SUITES:
        fail("baseline suite order changed")
    if tuple(required(baseline, "SP11_APT_SNAPSHOT_COMPONENTS").split()) != COMPONENTS:
        fail("baseline component order changed")
    if args.mode == "validate-attached":
        validate_attached(args, baseline)
        print(f"Validated attached immutable build-inputs envelope: {args.output}")
        return

    assert args.work_dir is not None
    assert args.build_args is not None
    assert args.entrypoint is not None
    assert args.oci_index is not None
    assert args.apt_archives_dir is not None
    assert args.apt_lists_dir is not None
    assert args.apt_index_cache_dir is not None
    assert args.apt_local_build_deps_dir is not None
    assert args.apt_pre_inventory is not None
    assert args.apt_post_inventory is not None
    if args.work_dir.is_symlink() or not args.work_dir.is_dir():
        fail("Docker work directory must be real")
    if args.work_dir.resolve(strict=True) != args.work_dir.absolute():
        fail("Docker work directory must have no symlinked path components")
    if args.mode == "validate-release-snapshot":
        for actual, expected, label in (
            (args.build_args, args.work_dir / "docker-build-args.txt", "Docker build arguments"),
            (args.entrypoint, args.work_dir / "docker-build-inside.sh", "Docker entrypoint"),
            (args.oci_index, args.work_dir / "sp11-oci-index.json", "OCI index"),
        ):
            assert actual is not None
            if actual.absolute() != expected:
                fail(f"{label} path is not the exact managed work path")
        snapshot_parent = real_directory(
            args.build_manifest.parent, "private release provenance snapshot"
        )
        for actual, name, label in (
            (args.build_manifest, "sp11-kernel-build-manifest.txt", "kernel build manifest"),
            (args.apt_provenance, "sp11-kernel-apt-provenance.txt", "APT provenance"),
            (args.output, "sp11-kernel-build-inputs.txt", "build-inputs envelope"),
        ):
            if actual.absolute() != snapshot_parent / name:
                fail(f"{label} is not in the exact private release snapshot")
            regular_file(actual, label)
        validate_release_snapshot(args, baseline)
        print(f"Validated private release snapshot against retained inputs: {snapshot_parent}")
        return

    expected_paths = (
        (args.build_args, args.work_dir / "docker-build-args.txt", "Docker build arguments"),
        (args.entrypoint, args.work_dir / "docker-build-inside.sh", "Docker entrypoint"),
        (args.oci_index, args.work_dir / "sp11-oci-index.json", "OCI index"),
        (
            args.build_manifest,
            args.work_dir / "artifacts/sp11-kernel-build-manifest.txt",
            "kernel build manifest",
        ),
        (
            args.apt_provenance,
            args.work_dir / "artifacts/sp11-kernel-apt-provenance.txt",
            "APT provenance",
        ),
        (
            args.output,
            args.work_dir / "artifacts/sp11-kernel-build-inputs.txt",
            "build-inputs envelope",
        ),
    )
    for actual, expected, label in expected_paths:
        if actual.absolute() != expected:
            fail(f"{label} path is not the exact managed work path")
    if args.mode == "validate":
        assert args.apt_bootstrap_state is not None
        assert args.attestation_output is not None
        assert args.build_inputs_helper_sha256 is not None
        assert args.build_inputs_helper_object_id is not None
        assert args.manifest_validator_sha256 is not None
        assert args.manifest_validator_object_id is not None
        if args.apt_bootstrap_state.absolute() != (
            args.work_dir / "sp11-apt-bootstrap-state.txt"
        ):
            fail("APT bootstrap state path is not the exact managed work path")
        if args.attestation_output.absolute() != (
            args.work_dir / PRESEAL_ATTESTATION_NAME
        ):
            fail("pre-seal attestation path is not the exact managed work path")
        if os.path.lexists(args.attestation_output):
            fail("pre-seal validation attestation already exists")
        repo_dir = Path(__file__).resolve().parent.parent
        build_inputs_identity = code_identity(
            Path(__file__).resolve(),
            "build-inputs helper",
            BUILD_INPUTS_HELPER_PATH,
            "100755",
            args.build_inputs_helper_sha256,
            args.build_inputs_helper_object_id,
            args.git_object_format,
        )
        manifest_validator_identity = code_identity(
            repo_dir / MANIFEST_VALIDATOR_PATH,
            "manifest validator",
            MANIFEST_VALIDATOR_PATH,
            "100644",
            args.manifest_validator_sha256,
            args.manifest_validator_object_id,
            args.git_object_format,
        )
        validate_bootstrap_state(args.apt_bootstrap_state, args.apt_pre_inventory, baseline)
        before = managed_state_snapshot(args.work_dir, attestation_present=False)
    else:
        before = retained_snapshot(args)
    written_output_snapshot: tuple[int, int, int, int, int, str] | None = None
    build_arguments_snapshot = validate_build_arguments(
        args.build_args, baseline, args.build_args_sha256
    )
    if args.mode == "validate":
        matching_build_arguments = [
            row for row in before if row[0] == "docker-build-args.txt"
        ]
        if len(matching_build_arguments) != 1:
            fail("Docker build arguments are absent from the complete managed snapshot")
        managed_build_arguments = matching_build_arguments[0]
        if (
            managed_build_arguments[1] != "regular"
            or managed_build_arguments[3] != build_arguments_snapshot[2]
            or managed_build_arguments[4] != build_arguments_snapshot[5]
            or (
                managed_build_arguments[5],
                managed_build_arguments[6],
                managed_build_arguments[8],
                managed_build_arguments[9],
                managed_build_arguments[10],
            )
            != build_arguments_snapshot[:5]
        ):
            fail("Docker build arguments changed before semantic validation")
    elif (
        "build-arguments",
        args.build_args.name,
        *build_arguments_snapshot,
    ) not in before:
        fail("Docker build arguments changed before semantic validation")
    validate_exact_build_manifest(args.build_manifest, args.support_head)
    validate_manifest(args.build_manifest, baseline, args.support_head)
    apt_fields = validate_apt_sidecar(args.apt_provenance, baseline)
    validate_retained_apt(args, apt_fields, baseline)
    validate_oci_index(args.oci_index, baseline, args.oci_index_sha256)
    if args.mode == "validate":
        if managed_state_snapshot(args.work_dir, attestation_present=False) != before:
            fail("managed release inputs changed during pre-envelope validation")
    elif retained_snapshot(args) != before:
        fail("retained APT inputs changed during pre-envelope validation")

    if args.mode == "write":
        inputs = (
            args.build_args,
            args.entrypoint,
            args.oci_index,
            args.build_manifest,
            args.apt_provenance,
        )
        expected_digests = (
            args.build_args_sha256,
            args.entrypoint_sha256,
            args.oci_index_sha256,
            None,
            None,
        )
        rows = [
            safe_input(args.work_dir, path, role, expected_digest)
            for role, path, expected_digest in zip(
                INPUT_ROLES, inputs, expected_digests
            )
        ]
        lines = [
            "Build inputs schema: sp11-kernel-build-inputs-v1",
            "Release build: true",
            f"Support HEAD: {args.support_head}",
            f"OCI index image: {required(baseline, 'SP11_KERNEL_DOCKER_IMAGE')}",
            f"OCI index digest: {required(baseline, 'SP11_KERNEL_DOCKER_IMAGE').rsplit('@', 1)[1]}",
            f"OCI platform: {required(baseline, 'SP11_KERNEL_DOCKER_PLATFORM')}",
            f"OCI platform manifest: {required(baseline, 'SP11_KERNEL_DOCKER_PLATFORM_MANIFEST')}",
            f"Input count: {len(INPUT_ROLES)}",
        ]
        for index, (role, row) in enumerate(zip(INPUT_ROLES, rows), 1):
            relative, size, digest = row
            lines.extend(
                (
                    f"Input {index} role: {role}",
                    f"Input {index} path: {relative}",
                    f"Input {index} size: {size}",
                    f"Input {index} SHA256: {digest}",
                )
            )
        lines.extend(
            (
                "Publication schema propagation: incomplete",
                "Build inputs complete: true",
            )
        )
        output_bytes = ("\n".join(lines) + "\n").encode("utf-8")
        write_exclusive_regular(
            args.output, output_bytes, "build-inputs output"
        )
        written_output_snapshot = stable_file_snapshot(
            args.output, "new build-inputs envelope"
        )

    validate_envelope(args, baseline)
    apt_fields = validate_apt_sidecar(args.apt_provenance, baseline)
    validate_retained_apt(args, apt_fields, baseline)
    if args.mode == "validate":
        assert args.apt_bootstrap_state is not None
        assert args.attestation_output is not None
        assert validator_argv is not None
        assert build_inputs_identity is not None
        assert manifest_validator_identity is not None
        validate_bootstrap_state(args.apt_bootstrap_state, args.apt_pre_inventory, baseline)
        after = managed_state_snapshot(args.work_dir, attestation_present=False)
        if after != before:
            fail("managed release inputs changed during full pre-seal validation")
        repo_dir = Path(__file__).resolve().parent.parent
        if code_identity(
            Path(__file__).resolve(),
            "build-inputs helper",
            BUILD_INPUTS_HELPER_PATH,
            "100755",
            args.build_inputs_helper_sha256,
            args.build_inputs_helper_object_id,
            args.git_object_format,
        ) != build_inputs_identity or code_identity(
            repo_dir / MANIFEST_VALIDATOR_PATH,
            "manifest validator",
            MANIFEST_VALIDATOR_PATH,
            "100644",
            args.manifest_validator_sha256,
            args.manifest_validator_object_id,
            args.git_object_format,
        ) != manifest_validator_identity:
            fail("pre-seal validator code identities changed during validation")
        attestation = render_preseal_attestation(
            args,
            baseline,
            validator_argv,
            build_inputs_identity,
            manifest_validator_identity,
            before,
        )
        write_exclusive_regular(
            args.attestation_output,
            attestation,
            "pre-seal validation attestation",
        )
        try:
            print(
                f"Validated immutable build-inputs envelope and created pre-seal attestation: "
                f"{args.attestation_output}"
            )
        except OSError:
            pass
        return
    elif retained_snapshot(args) != before:
        fail("retained APT inputs changed during envelope generation/validation")
    if (
        written_output_snapshot is not None
        and stable_file_snapshot(args.output, "new build-inputs envelope")
        != written_output_snapshot
    ):
        fail("new build-inputs envelope changed before write-mode success")
    print(f"Validated immutable build-inputs envelope: {args.output}")


if __name__ == "__main__":
    main()
