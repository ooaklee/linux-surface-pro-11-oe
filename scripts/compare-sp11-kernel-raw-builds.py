#!/usr/bin/env python3
"""Compare one validated immutable SP11 kernel build pair without normalization."""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import fcntl
import gzip
import hashlib
import io
import json
import lzma
import os
import re
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import tarfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from types import ModuleType
from typing import BinaryIO, Callable, Iterator


SCHEMA = "sp11-kernel-raw-matched-pair-v1"
POLICY = "sp11-kernel-zero-normalization-v1"
ROLE_ORDER = ("common-headers", "headers", "image", "modules", "modules-extra")
OUTPUT_ORDER = (
    "kernel-config",
    "module-symvers",
    "system-map",
    "kernel-efi-stubble",
    "denali-oled-dtb",
    "denali-oled-el2-dtb",
    "module-signing-certificate",
)
KNOWN_ARTIFACTS = {
    "sp11-kernel-build-manifest.txt",
    "sp11-kernel-apt-provenance.txt",
    "sp11-kernel-build-inputs.txt",
    "sp11-kernel-debs.txt",
}
CONTROL_FILES = {
    "build-arguments": "docker-build-args.txt",
    "entrypoint": "docker-build-inside.sh",
    "oci-index": "sp11-oci-index.json",
    "pre-inventory": "sp11-apt-installed-pre.txt",
    "post-inventory": "sp11-apt-installed-post.txt",
}
SNAPSHOT_IMPLEMENTATIONS = (
    "scripts/sp11-kernel-build-inputs.py",
    "scripts/validate-sp11-image-release-manifests.py",
    "scripts/validate-sp11-module-signatures.py",
)
MAX_ARTIFACT_BYTES = 4 * 1024 * 1024 * 1024
MAX_ARTIFACT_TOTAL_BYTES = 8 * 1024 * 1024 * 1024
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_SIDECAR_BYTES = 16 * 1024 * 1024
MAX_CONTROL_BYTES = 8 * 1024 * 1024
MAX_BASELINE_BYTES = 256 * 1024
MAX_DEB_LIST_BYTES = 4 * 1024 * 1024
MAX_CONTROL_DECODE_MEMORY = 64 * 1024 * 1024
MAX_CONTROL_COMPRESSED_BYTES = 64 * 1024 * 1024
MAX_PATCH_COUNT = 64
MAX_ARTIFACT_ENTRIES = 16
MAX_MANAGED_ENTRIES = 4096
MAX_MANAGED_DEPTH = 16
MAX_MANAGED_TOTAL_BYTES = 16 * 1024 * 1024 * 1024
MAX_PRIVATE_ENTRIES = 20000
MAX_APT_DECODED_BYTES = 4 * 1024 * 1024 * 1024
MAX_TOOL_BYTES = 128 * 1024 * 1024
MAX_TOOL_DEPENDENCY_OUTPUT = 1024 * 1024
EXTERNAL_DECODER_STDERR_MAX = 1024 * 1024
EXTERNAL_DECODER_TOTAL_TIMEOUT_SECONDS = 300.0
EXTERNAL_DECODER_IDLE_TIMEOUT_SECONDS = 30.0
EXTERNAL_DECODER_STOP_TIMEOUT_SECONDS = 5.0
OID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+~-]*\Z")
SAFE_PACKAGE = re.compile(r"[a-z0-9][a-z0-9+.-]*\Z")
SAFE_VERSION = re.compile(r"[0-9A-Za-z.+:~_-]+\Z")
SAFE_ARCH = re.compile(r"[a-z0-9][a-z0-9-]*\Z")
BASELINE_LINE = re.compile(r'^([A-Z0-9_]+)="([^"\r\n]*)"$')


class ValidationError(Exception):
    """A fail-closed input or provenance error safe for internal control flow."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def establish_child_wait_authority() -> None:
    """Reset an inherited ignored SIGCHLD before any owned subprocess."""

    try:
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    except (OSError, ValueError) as exc:
        raise ValidationError("child-wait authority could not be established") from exc
    require(
        signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL,
        "child-wait authority is not the default SIGCHLD disposition",
    )


def require_child_wait_authority() -> None:
    require(
        signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL,
        "child-wait authority changed before subprocess acquisition",
    )


def stable_metadata(value: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def inode_identity(value: os.stat_result) -> tuple[int, int]:
    return value.st_dev, value.st_ino


def retained_metadata(
    value: os.stat_result,
) -> tuple[int, int, int, int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_gid,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def bounded_directory_names(descriptor: int, maximum: int, label: str) -> tuple[str, ...]:
    names: list[str] = []
    try:
        with os.scandir(descriptor) as iterator:
            for entry in iterator:
                require(len(names) < maximum, f"{label} exceeds its entry limit")
                require(
                    isinstance(entry.name, str)
                    and bool(entry.name)
                    and "/" not in entry.name
                    and "\x00" not in entry.name,
                    f"{label} contains an unsafe name",
                )
                names.append(entry.name)
    except OSError as exc:
        raise ValidationError(f"{label} could not be listed") from exc
    return tuple(sorted(names))


def hash_descriptor(descriptor: int, size: int) -> str:
    digest = hashlib.sha256()
    offset = 0
    while offset < size:
        chunk = os.pread(descriptor, min(1024 * 1024, size - offset), offset)
        if not chunk:
            raise ValidationError("a retained descriptor ended before its declared size")
        digest.update(chunk)
        offset += len(chunk)
    require(not os.pread(descriptor, 1, size), "a retained descriptor grew while hashed")
    return digest.hexdigest()


def read_descriptor(record: "FileRecord", maximum: int) -> bytes:
    require(record.size <= maximum, "a bounded schema input exceeds its size limit")
    chunks: list[bytes] = []
    offset = 0
    while offset < record.size:
        chunk = os.pread(record.descriptor, min(1024 * 1024, record.size - offset), offset)
        if not chunk:
            raise ValidationError("a retained schema descriptor is truncated")
        chunks.append(chunk)
        offset += len(chunk)
    return b"".join(chunks)


@dataclass
class FileRecord:
    name: str
    descriptor: int
    before: os.stat_result
    size: int
    sha256: str

    def close(self) -> None:
        try:
            os.close(self.descriptor)
        except OSError:
            pass


@dataclass(frozen=True)
class PrivateEntry:
    relative: str
    kind: str
    metadata: tuple[int, int, int, int, int]


@dataclass(frozen=True)
class DeclaredPrivateEntry:
    relative: str
    kind: str
    metadata: tuple[int, int, int, int, int]
    sha256: str | None


@dataclass
class PrivateOwnership:
    root_inode: tuple[int, int]
    directory_inodes: dict[str, tuple[int, int]]
    file_inodes: dict[str, tuple[int, int]]
    entries: dict[str, DeclaredPrivateEntry]
    root_metadata: tuple[int, int, int, int, int] | None = None

    @classmethod
    def create(cls, root_descriptor: int) -> "PrivateOwnership":
        metadata = os.fstat(root_descriptor)
        require(stat.S_ISDIR(metadata.st_mode), "owned private root is not real")
        return cls(inode_identity(metadata), {}, {}, {})

    def declare_directory(self, relative: str, descriptor: int) -> None:
        metadata = os.fstat(descriptor)
        require(stat.S_ISDIR(metadata.st_mode), "owned private directory is not real")
        identity = inode_identity(metadata)
        existing = self.directory_inodes.get(relative)
        require(existing in (None, identity), "owned private directory identity changed")
        self.directory_inodes[relative] = identity

    def require_directory(self, relative: str, descriptor: int) -> None:
        require(
            self.directory_inodes.get(relative) == inode_identity(os.fstat(descriptor)),
            "owned private directory was replaced",
        )

    def declare_file(
        self, relative: str, descriptor: int, expected_sha256: str
    ) -> None:
        metadata = os.fstat(descriptor)
        require(
            self.file_inodes.get(relative) == inode_identity(metadata)
            and relative not in self.entries
            and stat.S_ISREG(metadata.st_mode)
            and hash_descriptor(descriptor, metadata.st_size) == expected_sha256,
            "owned private file identity is invalid",
        )
        self.entries[relative] = DeclaredPrivateEntry(
            relative,
            "file",
            stable_metadata(metadata),
            expected_sha256,
        )

    def declare_file_creation(self, relative: str, descriptor: int) -> None:
        metadata = os.fstat(descriptor)
        require(
            relative not in self.file_inodes
            and relative not in self.directory_inodes
            and stat.S_ISREG(metadata.st_mode),
            "owned private file creation identity is invalid",
        )
        self.file_inodes[relative] = inode_identity(metadata)

    def forget_removed_file(self, relative: str, descriptor: int) -> None:
        require(
            relative not in self.entries
            and self.file_inodes.get(relative)
            == inode_identity(os.fstat(descriptor)),
            "removed private file did not retain its creation identity",
        )
        del self.file_inodes[relative]

    def finalize_directories(self, root_descriptor: int) -> None:
        root = os.fstat(root_descriptor)
        require(
            stat.S_ISDIR(root.st_mode) and inode_identity(root) == self.root_inode,
            "owned private root was replaced",
        )
        for relative in sorted(
            self.directory_inodes, key=lambda value: (value.count("/"), value), reverse=True
        ):
            current = os.dup(root_descriptor)
            try:
                for component in relative.split("/"):
                    child, _metadata = open_child_directory(
                        current, component, "owned private directory"
                    )
                    os.close(current)
                    current = child
                self.require_directory(relative, current)
                metadata = os.fstat(current)
                self.entries[relative] = DeclaredPrivateEntry(
                    relative,
                    "directory",
                    stable_metadata(metadata),
                    None,
                )
            finally:
                os.close(current)
        self.root_metadata = stable_metadata(os.fstat(root_descriptor))

    def expected_entries(self) -> dict[str, PrivateEntry]:
        require(
            self.root_metadata is not None
            and set(self.entries)
            == set(self.directory_inodes) | set(self.file_inodes),
            "private ownership declarations are incomplete",
        )
        return {
            relative: PrivateEntry(relative, declared.kind, declared.metadata)
            for relative, declared in self.entries.items()
        }

    def verify(self, root_descriptor: int) -> None:
        root = os.fstat(root_descriptor)
        require(
            stat.S_ISDIR(root.st_mode)
            and inode_identity(root) == self.root_inode
            and self.root_metadata is not None
            and stable_metadata(root) == self.root_metadata,
            "private root differs from its creation-time ownership declaration",
        )
        expected = self.expected_entries()
        require(
            capture_private_entries(root_descriptor) == expected,
            "private tree differs from its creation-time ownership declarations",
        )
        for relative, declared in self.entries.items():
            if declared.kind != "file":
                continue
            parent = -1
            record: FileRecord | None = None
            try:
                parent, record = open_relative_file(
                    root_descriptor,
                    relative,
                    "owned private file",
                    maximum=declared.metadata[2],
                    nonempty=False,
                )
                require(
                    stable_metadata(record.before) == declared.metadata
                    and record.sha256 == declared.sha256,
                    "owned private file changed after declaration",
                )
            finally:
                if record is not None:
                    record.close()
                if parent >= 0:
                    os.close(parent)

    def _direct_children(self, relative: str) -> tuple[str, ...]:
        prefix = f"{relative}/" if relative else ""
        declared = set(self.directory_inodes) | set(self.file_inodes)
        return tuple(
            sorted(
                path[len(prefix) :]
                for path in declared
                if path.startswith(prefix) and "/" not in path[len(prefix) :]
            )
        )

    @staticmethod
    def _empty(directory: int) -> bool:
        try:
            with os.scandir(directory) as iterator:
                return next(iterator, None) is None
        except OSError:
            return False

    def _retire_file(self, directory: int, relative: str, name: str) -> None:
        expected_inode = self.file_inodes[relative]
        descriptor = -1
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=directory,
            )
            opened = os.fstat(descriptor)
            path_metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
            if not (
                stat.S_ISREG(opened.st_mode)
                and stat.S_ISREG(path_metadata.st_mode)
                and inode_identity(opened) == expected_inode
                and inode_identity(path_metadata) == expected_inode
            ):
                return
            declared = self.entries.get(relative)
            if declared is not None and not (
                stable_metadata(opened) == declared.metadata
                and stable_metadata(path_metadata) == declared.metadata
                and hash_descriptor(descriptor, opened.st_size) == declared.sha256
            ):
                return
            final_path = os.stat(name, dir_fd=directory, follow_symlinks=False)
            if not (
                stat.S_ISREG(final_path.st_mode)
                and stable_metadata(final_path) == stable_metadata(path_metadata)
            ):
                return
            os.unlink(name, dir_fd=directory)
        except (FileNotFoundError, OSError, ValidationError):
            return
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def _retire_directory(self, directory: int, relative: str) -> None:
        for name in self._direct_children(relative):
            child_relative = f"{relative}/{name}" if relative else name
            if child_relative in self.file_inodes:
                self._retire_file(directory, child_relative, name)
                continue
            expected_inode = self.directory_inodes[child_relative]
            child = -1
            try:
                child, opened = open_child_directory(
                    directory, name, "owned partial private directory"
                )
                path_metadata = os.stat(
                    name, dir_fd=directory, follow_symlinks=False
                )
                if not (
                    inode_identity(opened) == expected_inode
                    and inode_identity(path_metadata) == expected_inode
                ):
                    continue
                self._retire_directory(child, child_relative)
                emptied = os.fstat(child)
                final_path = os.stat(
                    name, dir_fd=directory, follow_symlinks=False
                )
                if not (
                    stat.S_ISDIR(emptied.st_mode)
                    and stat.S_ISDIR(final_path.st_mode)
                    and inode_identity(emptied) == expected_inode
                    and inode_identity(final_path) == expected_inode
                    and self._empty(child)
                ):
                    continue
                os.rmdir(name, dir_fd=directory)
            except (FileNotFoundError, OSError, ValidationError):
                continue
            finally:
                if child >= 0:
                    os.close(child)

    def retire_partial(self, private: "PrivateTree") -> None:
        try:
            private.verify_root_binding()
            root = os.fstat(private.root_descriptor)
            if not (
                stat.S_ISDIR(root.st_mode)
                and inode_identity(root) == self.root_inode
            ):
                private.preserve()
                return
            self._retire_directory(private.root_descriptor, "")
            if not self._empty(private.root_descriptor):
                private.preserve()
                return
            try:
                path_metadata = os.stat(
                    private.root_name,
                    dir_fd=private.parent_descriptor,
                    follow_symlinks=False,
                )
            except OSError:
                private.preserve()
                return
            final_root = os.fstat(private.root_descriptor)
            if not (
                stat.S_ISDIR(path_metadata.st_mode)
                and stat.S_ISDIR(final_root.st_mode)
                and inode_identity(path_metadata) == self.root_inode
                and inode_identity(final_root) == self.root_inode
                and self._empty(private.root_descriptor)
            ):
                private.preserve()
                return
            os.rmdir(private.root_name, dir_fd=private.parent_descriptor)
            try:
                os.stat(
                    private.root_name,
                    dir_fd=private.parent_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                pass
            else:
                private.preserve()
                return
            private._close_descriptors()
            private.root_descriptor = -1
            private.parent_descriptor = -1
            private.cleaned = True
        except Exception:
            private.preserve()


@dataclass
class ScratchParent:
    path: Path
    descriptor: int
    identity: tuple[int, int]

    def verify(self) -> None:
        try:
            path_metadata = self.path.lstat()
            descriptor_metadata = os.fstat(self.descriptor)
        except OSError as exc:
            raise ValidationError("private scratch parent binding changed") from exc
        require(
            stat.S_ISDIR(path_metadata.st_mode)
            and stat.S_ISDIR(descriptor_metadata.st_mode)
            and inode_identity(path_metadata) == self.identity
            and inode_identity(descriptor_metadata) == self.identity,
            "private scratch parent binding changed",
        )

    def duplicate(self) -> int:
        self.verify()
        try:
            descriptor = os.dup(self.descriptor)
        except OSError as exc:
            raise ValidationError("private scratch parent could not be retained") from exc
        if inode_identity(os.fstat(descriptor)) != self.identity:
            os.close(descriptor)
            raise ValidationError("private scratch parent identity changed")
        return descriptor

    def close(self) -> None:
        try:
            os.close(self.descriptor)
        except OSError:
            pass
        self.descriptor = -1


def private_cleanup_barrier(_tree: "PrivateTree") -> None:
    """No-op boundary used by deterministic private-tree drift fixtures."""


def private_final_remove_barrier(_tree: "PrivateTree") -> None:
    """No-op boundary used by post-delete private-root drift fixtures."""


def private_support_setup_barrier(_tree: "PrivateTree") -> None:
    """No-op boundary used by private-root ancestor replacement fixtures."""


def private_support_seal_barrier(_tree: "PrivateTree") -> None:
    """No-op boundary used by post-copy ownership-injection fixtures."""


def private_tool_launch_barrier(_tool: "BoundTool") -> None:
    """No-op boundary used by private-root decoder replacement fixtures."""


def capture_private_entries(
    root_descriptor: int, *, maximum: int = MAX_PRIVATE_ENTRIES
) -> dict[str, PrivateEntry]:
    entries: dict[str, PrivateEntry] = {}

    def walk(directory: int, prefix: str, depth: int) -> None:
        require(depth <= MAX_MANAGED_DEPTH * 4, "private tree nesting is excessive")
        remaining = maximum - len(entries)
        require(remaining > 0, "private tree exceeds its entry limit")
        names = bounded_directory_names(directory, remaining, "private tree")
        for name in names:
            require(len(entries) < maximum, "private tree exceeds its entry limit")
            relative = f"{prefix}/{name}" if prefix else name
            try:
                metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
            except OSError as exc:
                raise ValidationError("private tree changed while enumerated") from exc
            if stat.S_ISREG(metadata.st_mode):
                entries[relative] = PrivateEntry(
                    relative, "file", stable_metadata(metadata)
                )
                continue
            require(stat.S_ISDIR(metadata.st_mode), "private tree contains a link or special path")
            child, opened = open_child_directory(directory, name, "private tree directory")
            try:
                entries[relative] = PrivateEntry(
                    relative, "directory", stable_metadata(opened)
                )
                walk(child, relative, depth + 1)
                require(
                    stable_metadata(os.fstat(child)) == stable_metadata(opened),
                    "private tree directory changed while enumerated",
                )
            finally:
                os.close(child)

    walk(root_descriptor, "", 0)
    return entries


@dataclass
class PrivateTree:
    label: str
    path: Path
    parent_path: Path
    parent_descriptor: int
    parent_identity: tuple[int, int]
    root_name: str
    root_descriptor: int
    root_before: os.stat_result | None = None
    entries: dict[str, PrivateEntry] | None = None
    ownership: PrivateOwnership | None = None
    cleaned: bool = False
    preserved: bool = False

    @classmethod
    def create(
        cls, parent: ScratchParent, prefix: str, label: str
    ) -> "PrivateTree":
        require(
            bool(re.fullmatch(r"\.?[A-Za-z0-9][A-Za-z0-9._-]*\.", prefix)),
            "private tree prefix is unsafe",
        )
        parent.verify()
        parent_descriptor = parent.duplicate()
        parent_metadata = os.fstat(parent_descriptor)
        root_name = ""
        try:
            for _attempt in range(128):
                candidate = f"{prefix}{secrets.token_hex(16)}"
                try:
                    os.mkdir(candidate, mode=0o700, dir_fd=parent_descriptor)
                except FileExistsError:
                    continue
                except OSError as exc:
                    raise ValidationError("private tree root could not be created") from exc
                root_name = candidate
                break
            require(bool(root_name), "private tree root name could not be allocated")
            root_descriptor, root_metadata = open_child_directory(
                parent_descriptor, root_name, label
            )
            os.fchmod(root_descriptor, 0o700)
            root_metadata = os.fstat(root_descriptor)
        except Exception:
            os.close(parent_descriptor)
            raise
        root = parent.path / root_name
        return cls(
            label,
            root,
            parent.path,
            parent_descriptor,
            inode_identity(parent_metadata),
            root_name,
            root_descriptor,
        )

    def seal(self) -> None:
        require(self.entries is None, "private tree was sealed twice")
        before = os.fstat(self.root_descriptor)
        entries = capture_private_entries(self.root_descriptor)
        require(
            stable_metadata(os.fstat(self.root_descriptor)) == stable_metadata(before),
            "private tree root changed while sealed",
        )
        self.root_before = before
        self.entries = entries

    def verify_root_binding(self) -> None:
        try:
            parent_path_metadata = self.parent_path.lstat()
            root_path_metadata = os.stat(
                self.root_name,
                dir_fd=self.parent_descriptor,
                follow_symlinks=False,
            )
        except OSError as exc:
            raise ValidationError("private tree root binding changed") from exc
        require(
            stat.S_ISDIR(parent_path_metadata.st_mode)
            and inode_identity(parent_path_metadata) == self.parent_identity
            and inode_identity(os.fstat(self.parent_descriptor)) == self.parent_identity
            and stat.S_ISDIR(root_path_metadata.st_mode)
            and inode_identity(root_path_metadata)
            == inode_identity(os.fstat(self.root_descriptor)),
            "private tree root binding changed",
        )

    def verify(self) -> None:
        require(
            not self.cleaned and not self.preserved and self.entries is not None,
            "private tree is not available for verification",
        )
        assert self.root_before is not None
        self.verify_root_binding()
        root_path_metadata = os.stat(
            self.root_name,
            dir_fd=self.parent_descriptor,
            follow_symlinks=False,
        )
        require(
            stat.S_ISDIR(root_path_metadata.st_mode)
            and stable_metadata(root_path_metadata) == stable_metadata(self.root_before)
            and stable_metadata(os.fstat(self.root_descriptor))
            == stable_metadata(self.root_before),
            "private tree root identity changed",
        )
        require(
            capture_private_entries(self.root_descriptor) == self.entries,
            "private tree descendants changed",
        )
        if self.ownership is not None:
            self.ownership.verify(self.root_descriptor)

    def _children(self, relative: str) -> dict[str, PrivateEntry]:
        assert self.entries is not None
        prefix = f"{relative}/" if relative else ""
        children: dict[str, PrivateEntry] = {}
        for path, entry in self.entries.items():
            if not path.startswith(prefix):
                continue
            remainder = path[len(prefix) :]
            if "/" not in remainder:
                children[remainder] = entry
        return children

    def _require_name_absent(self, directory: int, name: str) -> None:
        try:
            os.stat(name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            return
        except OSError as exc:
            raise ValidationError("private cleanup removal could not be verified") from exc
        raise ValidationError("private cleanup removal left a bound name")

    def _delete_exact_file(
        self, directory: int, name: str, entry: PrivateEntry
    ) -> None:
        descriptor = -1
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=directory,
            )
            opened = os.fstat(descriptor)
            final_path = os.stat(name, dir_fd=directory, follow_symlinks=False)
            require(
                stat.S_ISREG(opened.st_mode)
                and stat.S_ISREG(final_path.st_mode)
                and stable_metadata(opened) == entry.metadata
                and stable_metadata(final_path) == entry.metadata,
                "private tree file drifted during cleanup",
            )
            os.unlink(name, dir_fd=directory)
            self._require_name_absent(directory, name)
        except OSError as exc:
            raise ValidationError("private tree file could not be removed safely") from exc
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def _delete_exact(self, directory: int, relative: str) -> None:
        expected = self._children(relative)
        names = bounded_directory_names(
            directory, MAX_PRIVATE_ENTRIES, "sealed private tree"
        )
        require(set(names) == set(expected), "private tree drifted during cleanup")
        for name in names:
            entry = expected[name]
            try:
                metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
            except OSError as exc:
                raise ValidationError("private tree drifted during cleanup") from exc
            require(
                stable_metadata(metadata) == entry.metadata,
                "private tree entry drifted during cleanup",
            )
            child_relative = f"{relative}/{name}" if relative else name
            if entry.kind == "file":
                self._delete_exact_file(directory, name, entry)
                continue
            child, opened = open_child_directory(
                directory, name, "sealed private directory"
            )
            try:
                require(
                    stable_metadata(opened) == entry.metadata,
                    "private directory drifted during cleanup",
                )
                self._delete_exact(child, child_relative)
                emptied = os.fstat(child)
                final_path = os.stat(
                    name, dir_fd=directory, follow_symlinks=False
                )
                require(
                    stat.S_ISDIR(emptied.st_mode)
                    and stat.S_ISDIR(final_path.st_mode)
                    and inode_identity(emptied) == inode_identity(final_path)
                    and stable_metadata(emptied) == stable_metadata(final_path)
                    and bounded_directory_names(
                        child, 1, "emptied private directory"
                    )
                    == (),
                    "private directory drifted before removal",
                )
                os.rmdir(name, dir_fd=directory)
                self._require_name_absent(directory, name)
            finally:
                os.close(child)

    def _close_descriptors(self) -> None:
        for descriptor in (self.root_descriptor, self.parent_descriptor):
            try:
                os.close(descriptor)
            except OSError:
                pass

    def preserve(self) -> None:
        if self.cleaned or self.preserved:
            return
        self.preserved = True
        self._close_descriptors()

    def cleanup(self) -> None:
        if self.cleaned:
            return
        require(not self.preserved, "a drifted private tree was preserved")
        try:
            private_cleanup_barrier(self)
            self.verify()
            tomb_name = f"{self.root_name}.cleanup.{secrets.token_hex(12)}"
            try:
                os.stat(tomb_name, dir_fd=self.parent_descriptor, follow_symlinks=False)
            except FileNotFoundError:
                pass
            except OSError as exc:
                raise ValidationError("private cleanup tomb could not be inspected") from exc
            else:
                raise ValidationError("private cleanup tomb already exists")
            os.rename(
                self.root_name,
                tomb_name,
                src_dir_fd=self.parent_descriptor,
                dst_dir_fd=self.parent_descriptor,
            )
            self.root_name = tomb_name
            self.path = self.parent_path / tomb_name
            require(
                inode_identity(
                    os.stat(
                        tomb_name,
                        dir_fd=self.parent_descriptor,
                        follow_symlinks=False,
                    )
                )
                == inode_identity(os.fstat(self.root_descriptor)),
                "private tree rename lost its bound root",
            )
            self._delete_exact(self.root_descriptor, "")
            emptied = os.fstat(self.root_descriptor)
            require(
                stat.S_ISDIR(emptied.st_mode)
                and bounded_directory_names(
                    self.root_descriptor, 1, "emptied private tree"
                )
                == (),
                "private tree root is not empty after exact cleanup",
            )
            private_final_remove_barrier(self)
            try:
                final_path = os.stat(
                    tomb_name,
                    dir_fd=self.parent_descriptor,
                    follow_symlinks=False,
                )
            except OSError as exc:
                raise ValidationError("private tree root drifted before final removal") from exc
            final_descriptor = os.fstat(self.root_descriptor)
            require(
                stat.S_ISDIR(final_path.st_mode)
                and stat.S_ISDIR(final_descriptor.st_mode)
                and inode_identity(final_path) == inode_identity(final_descriptor)
                and stable_metadata(final_path) == stable_metadata(emptied)
                and stable_metadata(final_descriptor) == stable_metadata(emptied)
                and bounded_directory_names(
                    self.root_descriptor, 1, "emptied private tree"
                )
                == (),
                "private tree root drifted before final removal",
            )
            os.rmdir(tomb_name, dir_fd=self.parent_descriptor)
            try:
                os.stat(
                    tomb_name,
                    dir_fd=self.parent_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                pass
            except OSError as exc:
                raise ValidationError("private tree final removal could not be verified") from exc
            else:
                raise ValidationError("private tree final removal left its bound name")
            os.close(self.root_descriptor)
            self.root_descriptor = -1
            os.close(self.parent_descriptor)
            self.parent_descriptor = -1
            self.cleaned = True
        except Exception:
            self.preserve()
            raise


def cleanup_private_setup_failure(
    private: PrivateTree, ownership: PrivateOwnership
) -> None:
    """Retire only creation-bound setup data and preserve every unknown path."""

    ownership.retire_partial(private)


@dataclass(frozen=True)
class BoundTool:
    name: str
    relative: str
    private: PrivateTree
    root_descriptor: int
    dyld_library_path: str | None = None


@dataclass(frozen=True)
class PackageRecord:
    role: str
    filename: str
    package: str
    version: str
    architecture: str
    size: int
    sha256: str


@dataclass(frozen=True)
class OutputRecord:
    role: str
    path: str
    size: int
    sha256: str


@dataclass
class OpenBuild:
    path: Path
    directory_descriptor: int
    directory_before: os.stat_result
    artifact_descriptor: int
    artifact_before: os.stat_result
    artifact_names: tuple[str, ...]
    artifacts: dict[str, FileRecord]
    controls: dict[str, FileRecord]
    managed: ManagedTree
    manifest: dict[str, str]
    envelope: dict[str, str]
    sidecar: dict[str, str]
    packages: dict[str, PackageRecord]
    outputs: dict[str, OutputRecord]
    local_build_deps: PackageRecord

    def cleanup_private(self) -> None:
        self.managed.cleanup()

    def close_descriptors(self) -> None:
        for record in (*self.artifacts.values(), *self.controls.values()):
            record.close()
        for descriptor in (self.artifact_descriptor, self.directory_descriptor):
            try:
                os.close(descriptor)
            except OSError:
                pass

    def close(self) -> None:
        cleanup_error: BaseException | None = None
        try:
            self.cleanup_private()
        except BaseException as exc:
            cleanup_error = exc
        self.close_descriptors()
        if cleanup_error is not None:
            raise ValidationError("private retained-input cleanup failed") from cleanup_error


@dataclass(frozen=True)
class Comparison:
    first: OpenBuild
    second: OpenBuild
    support: SupportBinding
    baseline: dict[str, str]
    support_head: str
    raw_package_match: bool
    output_identity_match: bool
    differing_packages: int
    differing_outputs: int

    @property
    def passed(self) -> bool:
        return self.raw_package_match and self.output_identity_match


def canonical_directory(
    path: Path, label: str, *, require_lexical_absolute: bool = False
) -> tuple[Path, int, os.stat_result]:
    absolute = Path(os.path.abspath(os.fspath(path)))
    if require_lexical_absolute:
        require(
            path.is_absolute() and os.fspath(path) == os.fspath(absolute),
            f"{label} must be a canonical absolute path",
        )
    try:
        path_metadata = absolute.lstat()
        resolved = absolute.resolve(strict=True)
    except OSError as exc:
        raise ValidationError(f"could not inspect {label}") from exc
    require(
        stat.S_ISDIR(path_metadata.st_mode) and resolved == absolute,
        f"{label} must be a canonical real directory",
    )
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    flags |= getattr(os, "O_DIRECTORY", 0)
    try:
        descriptor = os.open(absolute, flags)
    except OSError as exc:
        raise ValidationError(f"could not open {label}") from exc
    descriptor_metadata = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(descriptor_metadata.st_mode)
        or stable_metadata(descriptor_metadata) != stable_metadata(path_metadata)
    ):
        os.close(descriptor)
        raise ValidationError(f"{label} changed while opened")
    return absolute, descriptor, descriptor_metadata


def verify_bound_directory(
    binding: tuple[Path, int, os.stat_result], label: str
) -> None:
    path, descriptor, before = binding
    try:
        path_metadata = path.lstat()
        descriptor_metadata = os.fstat(descriptor)
    except OSError as exc:
        raise ValidationError(f"{label} binding changed") from exc
    require(
        stat.S_ISDIR(path_metadata.st_mode)
        and stable_metadata(path_metadata) == stable_metadata(before)
        and stable_metadata(descriptor_metadata) == stable_metadata(before),
        f"{label} binding changed",
    )


def open_scratch_parent(
    input_roots: tuple[tuple[Path, int, os.stat_result], ...]
) -> ScratchParent:
    try:
        fixed = Path("/tmp").resolve(strict=True)
    except OSError as exc:
        raise ValidationError("fixed private scratch parent is unavailable") from exc
    path, descriptor, metadata = canonical_directory(
        fixed, "fixed private scratch parent"
    )
    try:
        for binding in input_roots:
            verify_bound_directory(binding, "comparison input root")
            input_path, input_descriptor, input_metadata = binding
            require(
                input_path != path
                and input_path not in path.parents
                and inode_identity(input_metadata) != inode_identity(metadata)
                and inode_identity(os.fstat(input_descriptor))
                != inode_identity(metadata),
                "private scratch parent overlaps a comparison input root",
            )
        return ScratchParent(path, descriptor, inode_identity(metadata))
    except Exception:
        os.close(descriptor)
        raise


def open_child_directory(parent: int, name: str, label: str) -> tuple[int, os.stat_result]:
    try:
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError(f"could not inspect {label}") from exc
    require(stat.S_ISDIR(before.st_mode), f"{label} must be a real directory")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    flags |= getattr(os, "O_DIRECTORY", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=parent)
    except OSError as exc:
        raise ValidationError(f"could not open {label}") from exc
    after = os.fstat(descriptor)
    if not stat.S_ISDIR(after.st_mode) or stable_metadata(before) != stable_metadata(after):
        os.close(descriptor)
        raise ValidationError(f"{label} changed while opened")
    return descriptor, after


def open_child_file(
    parent: int,
    name: str,
    label: str,
    *,
    maximum: int,
    nonempty: bool = True,
) -> FileRecord:
    try:
        path_before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError(f"could not inspect {label}") from exc
    require(stat.S_ISREG(path_before.st_mode), f"{label} must be a regular file")
    require(path_before.st_size <= maximum, f"{label} exceeds its bounded size")
    if nonempty:
        require(path_before.st_size > 0, f"{label} must be nonempty")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(name, flags, dir_fd=parent)
    except OSError as exc:
        raise ValidationError(f"could not open {label}") from exc
    descriptor_before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(descriptor_before.st_mode)
        or stable_metadata(descriptor_before) != stable_metadata(path_before)
    ):
        os.close(descriptor)
        raise ValidationError(f"{label} changed while opened")
    try:
        digest = hash_descriptor(descriptor, descriptor_before.st_size)
        descriptor_after = os.fstat(descriptor)
    except Exception:
        os.close(descriptor)
        raise
    if stable_metadata(descriptor_before) != stable_metadata(descriptor_after):
        os.close(descriptor)
        raise ValidationError(f"{label} changed while hashed")
    return FileRecord(name, descriptor, descriptor_before, descriptor_before.st_size, digest)


def open_relative_file(
    root: int,
    relative: str,
    label: str,
    *,
    maximum: int,
    nonempty: bool = True,
) -> tuple[int, FileRecord]:
    parts = relative.split("/")
    require(
        bool(parts) and all(part not in ("", ".", "..") for part in parts),
        f"{label} has an unsafe relative path",
    )
    current = os.dup(root)
    try:
        for component in parts[:-1]:
            child, _metadata = open_child_directory(current, component, label)
            os.close(current)
            current = child
        return current, open_child_file(
            current,
            parts[-1],
            label,
            maximum=maximum,
            nonempty=nonempty,
        )
    except Exception:
        os.close(current)
        raise


@dataclass(frozen=True)
class ManagedEntry:
    relative: str
    kind: str
    metadata: tuple[int, int, int, int, int]
    sha256: str | None


def _capture_managed_directory(
    directory: int,
    prefix: str,
    entries: dict[str, ManagedEntry],
    totals: list[int],
    *,
    depth: int,
    expected_names: set[str] | None = None,
) -> None:
    require(depth <= MAX_MANAGED_DEPTH, "managed retained tree nesting is excessive")
    remaining = MAX_MANAGED_ENTRIES - totals[0]
    require(remaining > 0, "managed retained tree exceeds its entry limit")
    names = bounded_directory_names(directory, remaining, "managed retained directory")
    if expected_names is not None:
        require(set(names) == expected_names, "managed retained directory is not exact")
    for name in names:
        totals[0] += 1
        require(totals[0] <= MAX_MANAGED_ENTRIES, "managed retained tree exceeds its entry limit")
        relative = f"{prefix}/{name}" if prefix else name
        try:
            metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
        except OSError as exc:
            raise ValidationError("managed retained path changed while captured") from exc
        if stat.S_ISDIR(metadata.st_mode):
            child, opened = open_child_directory(
                directory, name, "managed retained directory"
            )
            try:
                entries[relative] = ManagedEntry(
                    relative, "directory", stable_metadata(opened), None
                )
                _capture_managed_directory(
                    child,
                    relative,
                    entries,
                    totals,
                    depth=depth + 1,
                )
                require(
                    stable_metadata(os.fstat(child)) == stable_metadata(opened),
                    "managed retained directory changed while captured",
                )
            finally:
                os.close(child)
            continue
        require(stat.S_ISREG(metadata.st_mode), "managed retained tree contains a link or special path")
        record = open_child_file(
            directory,
            name,
            "managed retained file",
            maximum=MAX_ARTIFACT_BYTES,
            nonempty=False,
        )
        try:
            totals[1] += record.size
            require(
                totals[1] <= MAX_MANAGED_TOTAL_BYTES,
                "managed retained tree exceeds its total size limit",
            )
            entries[relative] = ManagedEntry(
                relative,
                "file",
                stable_metadata(record.before),
                record.sha256,
            )
        finally:
            record.close()


def capture_managed_tree(
    root: int, artifact_names: tuple[str, ...]
) -> dict[str, ManagedEntry]:
    entries: dict[str, ManagedEntry] = {}
    totals = [0, 0]
    for name in CONTROL_FILES.values():
        totals[0] += 1
        require(totals[0] <= MAX_MANAGED_ENTRIES, "managed retained tree exceeds its entry limit")
        record = open_child_file(
            root,
            name,
            "managed retained control",
            maximum=MAX_CONTROL_BYTES,
            nonempty=False,
        )
        try:
            totals[1] += record.size
            entries[name] = ManagedEntry(
                name, "file", stable_metadata(record.before), record.sha256
            )
        finally:
            record.close()
    for name in ("apt-archives", "apt-indexes", "apt-lists", "artifacts"):
        totals[0] += 1
        require(totals[0] <= MAX_MANAGED_ENTRIES, "managed retained tree exceeds its entry limit")
        child, opened = open_child_directory(root, name, "managed retained directory")
        try:
            entries[name] = ManagedEntry(
                name, "directory", stable_metadata(opened), None
            )
            _capture_managed_directory(
                child,
                name,
                entries,
                totals,
                depth=1,
                expected_names=set(artifact_names) if name == "artifacts" else None,
            )
        finally:
            os.close(child)
    return entries


FICLONE = 0x40049409
CLONE_NOOWNERCOPY = 0x0002


def _require_private_copy_absent(destination: int, name: str) -> None:
    try:
        os.stat(name, dir_fd=destination, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as exc:
        raise ValidationError("failed private copy could not be inspected") from exc
    raise ValidationError("failed private copy left unexpected data")


def _unlink_owned_private_copy(destination: int, name: str, descriptor: int) -> None:
    try:
        opened = os.fstat(descriptor)
        path_metadata = os.stat(name, dir_fd=destination, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError("owned private copy could not be rebound for removal") from exc
    require(
        stat.S_ISREG(path_metadata.st_mode)
        and inode_identity(path_metadata) == inode_identity(opened),
        "owned private copy was replaced before removal",
    )
    os.unlink(name, dir_fd=destination)


def _try_cow_copy(
    source_descriptor: int,
    destination: int,
    name: str,
    mode: int,
    ownership: PrivateOwnership,
    relative: str,
) -> int | None:
    if sys.platform == "darwin":
        descriptor = -1
        try:
            function = ctypes.CDLL(None, use_errno=True).fclonefileat
            function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
            function.restype = ctypes.c_int
            result = function(
                source_descriptor,
                destination,
                os.fsencode(name),
                CLONE_NOOWNERCOPY,
            )
        except (AttributeError, OSError):
            return None
        if result != 0:
            _require_private_copy_absent(destination, name)
            return None
        try:
            descriptor = os.open(
                name,
                os.O_RDWR
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=destination,
            )
            ownership.declare_file_creation(relative, descriptor)
            os.fchmod(descriptor, mode)
            return descriptor
        except Exception:
            if descriptor >= 0:
                os.close(descriptor)
            raise
    if sys.platform.startswith("linux"):
        descriptor = -1
        try:
            descriptor = os.open(
                name,
                os.O_RDWR
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                mode,
                dir_fd=destination,
            )
            ownership.declare_file_creation(relative, descriptor)
            fcntl.ioctl(descriptor, FICLONE, source_descriptor)
            os.fchmod(descriptor, mode)
            return descriptor
        except OSError:
            if descriptor >= 0:
                try:
                    _unlink_owned_private_copy(destination, name, descriptor)
                    ownership.forget_removed_file(relative, descriptor)
                finally:
                    os.close(descriptor)
            else:
                _require_private_copy_absent(destination, name)
            return None
    return None


def _byte_copy(
    source_descriptor: int,
    destination: int,
    name: str,
    size: int,
    mode: int,
    ownership: PrivateOwnership,
    relative: str,
) -> int:
    try:
        descriptor = os.open(
            name,
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            mode,
            dir_fd=destination,
        )
    except OSError as exc:
        raise ValidationError("private retained file could not be created") from exc
    try:
        ownership.declare_file_creation(relative, descriptor)
        offset = 0
        while offset < size:
            chunk = os.pread(
                source_descriptor, min(1024 * 1024, size - offset), offset
            )
            require(bool(chunk), "managed retained source was truncated while copied")
            view = memoryview(chunk)
            while view:
                written = os.write(descriptor, view)
                require(written > 0, "private retained copy was truncated")
                view = view[written:]
            offset += len(chunk)
        os.fsync(descriptor)
        os.fchmod(descriptor, mode)
        return descriptor
    except Exception:
        try:
            _unlink_owned_private_copy(destination, name, descriptor)
            ownership.forget_removed_file(relative, descriptor)
        finally:
            os.close(descriptor)
        raise


def _copy_managed_file(
    source: int,
    destination: int,
    name: str,
    totals: list[int],
    ownership: PrivateOwnership,
    relative: str,
) -> None:
    try:
        before = os.stat(name, dir_fd=source, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError("managed retained file could not be inspected for copying") from exc
    require(
        stat.S_ISREG(before.st_mode)
        and before.st_size <= MAX_ARTIFACT_BYTES,
        "managed retained copy source is not a bounded regular file",
    )
    totals[1] += before.st_size
    require(
        totals[1] <= MAX_MANAGED_TOTAL_BYTES,
        "managed retained tree exceeds its total size limit",
    )
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        source_descriptor = os.open(name, flags, dir_fd=source)
    except OSError as exc:
        raise ValidationError("managed retained file could not be opened for copying") from exc
    destination_descriptor = -1
    try:
        opened = os.fstat(source_descriptor)
        require(
            stat.S_ISREG(opened.st_mode)
            and retained_metadata(opened) == retained_metadata(before),
            "managed retained source changed while opened for copying",
        )
        source_hash = hash_descriptor(source_descriptor, opened.st_size)
        mode = stat.S_IMODE(opened.st_mode)
        destination_descriptor = _try_cow_copy(
            source_descriptor,
            destination,
            name,
            mode,
            ownership,
            relative,
        ) or _byte_copy(
            source_descriptor,
            destination,
            name,
            opened.st_size,
            mode,
            ownership,
            relative,
        )
        destination_metadata = os.fstat(destination_descriptor)
        source_after = os.fstat(source_descriptor)
        source_path_after = os.stat(name, dir_fd=source, follow_symlinks=False)
        destination_path_after = os.stat(
            name, dir_fd=destination, follow_symlinks=False
        )
        require(
            retained_metadata(source_after) == retained_metadata(opened)
            and retained_metadata(source_path_after) == retained_metadata(opened)
            and stat.S_ISREG(destination_metadata.st_mode)
            and stable_metadata(destination_path_after)
            == stable_metadata(destination_metadata)
            and inode_identity(destination_metadata) != inode_identity(opened)
            and destination_metadata.st_size == opened.st_size
            and stat.S_IMODE(destination_metadata.st_mode) == mode
            and hash_descriptor(source_descriptor, opened.st_size) == source_hash
            and hash_descriptor(destination_descriptor, destination_metadata.st_size)
            == source_hash,
            "private retained copy is not independently bound to its source descriptor",
        )
        ownership.declare_file(relative, destination_descriptor, source_hash)
    finally:
        if destination_descriptor >= 0:
            os.close(destination_descriptor)
        os.close(source_descriptor)


def _copy_managed_directory(
    source: int,
    destination: int,
    *,
    depth: int,
    counter: list[int],
    ownership: PrivateOwnership,
    prefix: str,
    expected_names: set[str] | None = None,
) -> None:
    require(depth <= MAX_MANAGED_DEPTH, "managed retained tree nesting is excessive")
    remaining = MAX_MANAGED_ENTRIES - counter[0]
    require(remaining > 0, "managed retained tree exceeds its entry limit")
    names = bounded_directory_names(source, remaining, "managed retained directory")
    if expected_names is not None:
        require(set(names) == expected_names, "managed retained directory is not exact")
    for name in names:
        counter[0] += 1
        require(counter[0] <= MAX_MANAGED_ENTRIES, "managed retained tree exceeds its entry limit")
        try:
            before = os.stat(name, dir_fd=source, follow_symlinks=False)
        except OSError as exc:
            raise ValidationError("managed retained path changed while copied") from exc
        if stat.S_ISDIR(before.st_mode):
            source_child, source_opened = open_child_directory(
                source, name, "managed retained directory"
            )
            try:
                os.mkdir(name, mode=0o700, dir_fd=destination)
                destination_child, _destination_opened = open_child_directory(
                    destination, name, "private managed directory"
                )
                child_relative = f"{prefix}/{name}" if prefix else name
                ownership.declare_directory(child_relative, destination_child)
                try:
                    _copy_managed_directory(
                        source_child,
                        destination_child,
                        depth=depth + 1,
                        counter=counter,
                        ownership=ownership,
                        prefix=child_relative,
                    )
                finally:
                    os.close(destination_child)
                require(
                    stable_metadata(os.fstat(source_child))
                    == stable_metadata(source_opened),
                    "managed retained directory changed while copied",
                )
            finally:
                os.close(source_child)
            continue
        require(stat.S_ISREG(before.st_mode), "managed retained tree contains a link or special path")
        relative = f"{prefix}/{name}" if prefix else name
        _copy_managed_file(
            source, destination, name, counter, ownership, relative
        )


def _populate_managed_view(
    source: int,
    destination: int,
    artifact_names: tuple[str, ...],
    ownership: PrivateOwnership,
) -> None:
    counter = [0, 0]
    for name in CONTROL_FILES.values():
        counter[0] += 1
        _copy_managed_file(
            source, destination, name, counter, ownership, name
        )
    for name in ("apt-archives", "apt-indexes", "apt-lists", "artifacts"):
        counter[0] += 1
        source_child, _source_opened = open_child_directory(
            source, name, "managed retained directory"
        )
        try:
            os.mkdir(name, mode=0o700, dir_fd=destination)
            destination_child, _destination_opened = open_child_directory(
                destination, name, "private managed directory"
            )
            ownership.declare_directory(name, destination_child)
            try:
                _copy_managed_directory(
                    source_child,
                    destination_child,
                    depth=1,
                    counter=counter,
                    ownership=ownership,
                    prefix=name,
                    expected_names=set(artifact_names) if name == "artifacts" else None,
                )
            finally:
                os.close(destination_child)
        finally:
            os.close(source_child)


def managed_snapshot_barrier(
    _tree: "ManagedTree",
) -> Callable[[], None] | None:
    """No-op boundary used by deterministic retained-input A/B/A fixtures."""

    return None


@dataclass
class ManagedTree:
    source_path: Path
    source_descriptor: int
    artifact_names: tuple[str, ...]
    entries: dict[str, ManagedEntry]
    private: PrivateTree

    @classmethod
    def create(
        cls,
        source_path: Path,
        source_descriptor: int,
        artifact_names: tuple[str, ...],
        scratch_parent: ScratchParent,
    ) -> "ManagedTree":
        private = PrivateTree.create(
            scratch_parent,
            ".sp11-raw-copied.",
            "private retained-input view",
        )
        ownership = PrivateOwnership.create(private.root_descriptor)
        try:
            _populate_managed_view(
                source_descriptor,
                private.root_descriptor,
                artifact_names,
                ownership,
            )
            require(
                set(
                    bounded_directory_names(
                        private.root_descriptor,
                        len(CONTROL_FILES) + 5,
                        "private retained-input root",
                    )
                )
                == set(CONTROL_FILES.values())
                | {"apt-archives", "apt-indexes", "apt-lists", "artifacts"},
                "private retained-input root contains an unexpected entry",
            )
            source_entries = capture_managed_tree(source_descriptor, artifact_names)
            destination_entries = capture_managed_tree(
                private.root_descriptor, artifact_names
            )
            require(
                set(source_entries) == set(destination_entries),
                "private retained-input view is incomplete",
            )
            for relative, source in source_entries.items():
                destination = destination_entries[relative]
                require(
                    source.kind == destination.kind
                    and source.sha256 == destination.sha256
                    and (
                        source.kind == "directory"
                        or (
                            source.metadata[:2] != destination.metadata[:2]
                            and source.metadata[2] == destination.metadata[2]
                        )
                    ),
                    "private retained-input view is not independently copied",
                )
            ownership.finalize_directories(private.root_descriptor)
            ownership.verify(private.root_descriptor)
            private.seal()
            require(
                private.entries == ownership.expected_entries(),
                "sealed retained-input view differs from its owned declarations",
            )
            private.ownership = ownership
            result = cls(
                source_path,
                source_descriptor,
                artifact_names,
                source_entries,
                private,
            )
            result.verify()
            return result
        except Exception:
            cleanup_private_setup_failure(private, ownership)
            raise

    @property
    def file_identities(self) -> set[tuple[int, int]]:
        return {
            (entry.metadata[0], entry.metadata[1])
            for entry in self.entries.values()
            if entry.kind == "file"
        }

    def verify(self) -> None:
        require(
            capture_managed_tree(self.source_descriptor, self.artifact_names)
            == self.entries,
            "managed retained-input source tree changed",
        )
        if not self.private.cleaned:
            self.private.verify()

    def cleanup(self) -> None:
        try:
            self.verify()
        except Exception:
            self.private.preserve()
            raise
        self.private.cleanup()
        refreshed = capture_managed_tree(
            self.source_descriptor, self.artifact_names
        )
        require(
            refreshed == self.entries,
            "managed retained source metadata changed during private cleanup",
        )


def parse_schema(record: FileRecord, maximum: int, label: str) -> dict[str, str]:
    raw = read_descriptor(record, maximum)
    require(raw and raw.endswith(b"\n") and b"\r" not in raw, f"{label} framing is invalid")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise ValidationError(f"{label} is not UTF-8") from exc
    fields: dict[str, str] = {}
    for line in lines:
        require(": " in line, f"{label} contains a non-schema line")
        key, value = line.split(": ", 1)
        require(
            bool(key)
            and bool(value)
            and key not in fields
            and all(32 <= ord(character) < 127 for character in key + value),
            f"{label} contains an unsafe or duplicate field",
        )
        fields[key] = value
    return fields


def field(fields: dict[str, str], name: str) -> str:
    value = fields.get(name, "")
    require(bool(value), "a required schema field is missing")
    return value


def positive_decimal(value: str) -> int:
    require(bool(re.fullmatch(r"[1-9][0-9]{0,19}", value)), "a size/count is invalid")
    return int(value)


def reviewed_patch_count(fields: dict[str, str]) -> int:
    value = field(fields, "Patch count")
    require(
        bool(re.fullmatch(r"[1-9][0-9]{0,2}", value))
        and int(value) <= MAX_PATCH_COUNT,
        "kernel patch count exceeds the reviewed bound",
    )
    return int(value)


def parse_baseline(record: FileRecord) -> dict[str, str]:
    raw = read_descriptor(record, MAX_BASELINE_BYTES)
    require(
        raw
        and raw.endswith(b"\n")
        and all(byte == 0x0A or 0x20 <= byte <= 0x7E for byte in raw),
        "baseline framing or character set is invalid",
    )
    try:
        lines = raw.decode("ascii").splitlines()
    except UnicodeDecodeError as exc:
        raise ValidationError("baseline is not canonical printable ASCII") from exc
    values: dict[str, str] = {}
    for line in lines:
        if not line or line.startswith("#"):
            continue
        match = BASELINE_LINE.fullmatch(line)
        require(match is not None, "baseline contains an unsupported line")
        assert match is not None
        require(match.group(1) not in values, "baseline contains a duplicate variable")
        values[match.group(1)] = match.group(2)
    for name in (
        "SP11_KERNEL_BASELINE_ID",
        "SP11_KERNEL_UPSTREAM_URL",
        "SP11_KERNEL_UPSTREAM_REF",
        "SP11_KERNEL_UPSTREAM_COMMIT",
        "SP11_KERNEL_SOURCE_DATE_EPOCH",
        "SP11_KERNEL_KBUILD_BUILD_USER",
        "SP11_KERNEL_KBUILD_BUILD_HOST",
        "SP11_KERNEL_KBUILD_BUILD_TIMESTAMP",
        "SP11_KERNEL_DOCKER_IMAGE",
        "SP11_KERNEL_DOCKER_PLATFORM",
        "SP11_KERNEL_DOCKER_PLATFORM_MANIFEST",
        "SP11_APT_SNAPSHOT_ID",
        "SP11_APT_SNAPSHOT_URI",
    ):
        require(bool(values.get(name)), "baseline omits a required comparison identity")
    return values


def isolated_git_environment() -> dict[str, str]:
    return {
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": os.devnull,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
    }


def trusted_process_environment() -> dict[str, str]:
    return {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "TZ": "UTC"}


def trusted_git_executable() -> str:
    program = Path("/usr/bin/git")
    try:
        before = program.lstat()
        descriptor = os.open(
            program,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
    except OSError as exc:
        raise ValidationError("trusted system Git is unavailable") from exc
    try:
        opened = os.fstat(descriptor)
        require(
            stat.S_ISREG(opened.st_mode)
            and stable_metadata(opened) == stable_metadata(before)
            and opened.st_uid == 0
            and not (opened.st_mode & (stat.S_IWGRP | stat.S_IWOTH))
            and bool(opened.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)),
            "trusted system Git identity is unsafe",
        )
    finally:
        os.close(descriptor)
    return str(program)


TOOL_CANDIDATES = {
    "zstd": (
        Path("/usr/bin/zstd"),
        Path("/usr/local/bin/zstd"),
        Path("/opt/homebrew/bin/zstd"),
    ),
    "lz4": (
        Path("/usr/bin/lz4"),
        Path("/usr/local/bin/lz4"),
        Path("/opt/homebrew/bin/lz4"),
    ),
    "apt-helper": (Path("/usr/lib/apt/apt-helper"),),
}


def resolve_tool_candidate(name: str) -> tuple[Path, int, os.stat_result] | None:
    for candidate in TOOL_CANDIDATES[name]:
        try:
            resolved = candidate.resolve(strict=True)
            before = resolved.lstat()
        except OSError:
            continue
        if not stat.S_ISREG(before.st_mode):
            continue
        try:
            descriptor = os.open(
                resolved,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
            )
        except OSError:
            continue
        opened = os.fstat(descriptor)
        if (
            stable_metadata(opened) != stable_metadata(before)
            or opened.st_size <= 0
            or opened.st_size > MAX_TOOL_BYTES
            or opened.st_uid not in (0, os.getuid())
            or opened.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or not opened.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        ):
            os.close(descriptor)
            continue
        return resolved, descriptor, opened
    return None


def copy_open_descriptor(
    destination: int,
    target_name: str,
    source_descriptor: int,
    source_before: os.stat_result,
    *,
    mode: int,
    ownership: PrivateOwnership,
    relative: str,
) -> None:
    target_descriptor = -1
    try:
        target_descriptor = os.open(
            target_name,
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            mode,
            dir_fd=destination,
        )
        ownership.declare_file_creation(relative, target_descriptor)
        offset = 0
        source_digest = hashlib.sha256()
        while offset < source_before.st_size:
            chunk = os.pread(
                source_descriptor,
                min(1024 * 1024, source_before.st_size - offset),
                offset,
            )
            require(bool(chunk), "bound tool source was truncated")
            source_digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(target_descriptor, view)
                require(written > 0, "bound tool copy was truncated")
                view = view[written:]
            offset += len(chunk)
        os.fsync(target_descriptor)
        os.fchmod(target_descriptor, mode)
        require(
            stable_metadata(os.fstat(source_descriptor)) == stable_metadata(source_before),
            "bound tool source changed while copied",
        )
        target_metadata = os.fstat(target_descriptor)
        require(
            target_metadata.st_size == source_before.st_size
            and hash_descriptor(target_descriptor, target_metadata.st_size)
            == source_digest.hexdigest(),
            "bound tool copy differs from its opened source",
        )
        ownership.declare_file(
            relative, target_descriptor, source_digest.hexdigest()
        )
    finally:
        if target_descriptor >= 0:
            os.close(target_descriptor)


def darwin_dylib_dependencies(descriptor: int) -> tuple[str, ...]:
    require_child_wait_authority()
    try:
        result = subprocess.run(
            ["/usr/bin/otool", "-L", f"/dev/fd/{descriptor}"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=trusted_process_environment(),
            pass_fds=(descriptor,),
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValidationError("a private zstd dependency could not be inspected") from exc
    require(
        len(result.stdout) <= MAX_TOOL_DEPENDENCY_OUTPUT,
        "private zstd dependency metadata exceeds its limit",
    )
    try:
        lines = result.stdout.decode("utf-8", "strict").splitlines()
    except UnicodeDecodeError as exc:
        raise ValidationError("private zstd dependency metadata is not UTF-8") from exc
    require(bool(lines), "private zstd dependency metadata is empty")
    dependencies: list[str] = []
    for line in lines[1:]:
        require(line.startswith("\t") and " (" in line, "private zstd dependency metadata is malformed")
        dependency = line.strip().split(" (", 1)[0]
        require(
            bool(dependency)
            and "\x00" not in dependency
            and "\n" not in dependency
            and "\r" not in dependency,
            "private zstd dependency path is unsafe",
        )
        dependencies.append(dependency)
    return tuple(dependencies)


def open_darwin_dependency(path: Path) -> tuple[Path, int, os.stat_result]:
    try:
        resolved = path.resolve(strict=True)
        before = resolved.lstat()
        descriptor = os.open(
            resolved,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
        )
    except OSError as exc:
        raise ValidationError("a private zstd dependency could not be opened") from exc
    opened = os.fstat(descriptor)
    if not (
        stat.S_ISREG(opened.st_mode)
        and stable_metadata(opened) == stable_metadata(before)
        and 0 < opened.st_size <= MAX_TOOL_BYTES
        and opened.st_uid in (0, os.getuid())
        and not opened.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        os.close(descriptor)
        raise ValidationError("a private zstd dependency has an unsafe identity")
    return resolved, descriptor, opened


def resolve_darwin_dependency(dependency: str, loader: Path) -> Path | None:
    if dependency.startswith(("/usr/lib/", "/System/Library/")):
        return None
    if dependency.startswith("@rpath/"):
        name = dependency.removeprefix("@rpath/")
        require(
            bool(SAFE_NAME.fullmatch(name)) and "/" not in name,
            "private zstd rpath dependency is unsafe",
        )
        return loader.parent.parent / "lib" / name
    require(dependency.startswith("/"), "private zstd has an unsupported dependency path")
    return Path(dependency)


def copy_darwin_zstd_bundle(
    destination: int,
    source_path: Path,
    source_descriptor: int,
    source_before: os.stat_result,
    ownership: PrivateOwnership,
) -> str:
    os.mkdir("zstd-bundle", mode=0o700, dir_fd=destination)
    bundle, _bundle_metadata = open_child_directory(
        destination, "zstd-bundle", "private zstd bundle"
    )
    ownership.declare_directory("bound-tools/zstd-bundle", bundle)
    try:
        os.mkdir("bin", mode=0o700, dir_fd=bundle)
        os.mkdir("lib", mode=0o700, dir_fd=bundle)
        binary_directory, _binary_metadata = open_child_directory(
            bundle, "bin", "private zstd binary directory"
        )
        library_directory, _library_metadata = open_child_directory(
            bundle, "lib", "private zstd library directory"
        )
        ownership.declare_directory(
            "bound-tools/zstd-bundle/bin", binary_directory
        )
        ownership.declare_directory(
            "bound-tools/zstd-bundle/lib", library_directory
        )
        try:
            copy_open_descriptor(
                binary_directory,
                "zstd",
                source_descriptor,
                source_before,
                mode=0o500,
                ownership=ownership,
                relative="bound-tools/zstd-bundle/bin/zstd",
            )
            pending = [
                dependency
                for dependency in darwin_dylib_dependencies(source_descriptor)
                if resolve_darwin_dependency(dependency, source_path) is not None
            ]
            copied: dict[str, tuple[int, int]] = {}
            while pending:
                dependency = pending.pop(0)
                candidate = resolve_darwin_dependency(dependency, source_path)
                assert candidate is not None
                resolved, dylib_descriptor, dylib_before = open_darwin_dependency(candidate)
                try:
                    identity = inode_identity(dylib_before)
                    if identity in copied.values():
                        continue
                    name = Path(dependency).name
                    require(
                        bool(SAFE_NAME.fullmatch(name))
                        and name.endswith(".dylib")
                        and name not in copied,
                        "private zstd dependency basename is unsafe or ambiguous",
                    )
                    copy_open_descriptor(
                        library_directory,
                        name,
                        dylib_descriptor,
                        dylib_before,
                        mode=0o400,
                        ownership=ownership,
                        relative=f"bound-tools/zstd-bundle/lib/{name}",
                    )
                    copied[name] = identity
                    for nested in darwin_dylib_dependencies(dylib_descriptor):
                        nested_candidate = resolve_darwin_dependency(nested, resolved)
                        if nested_candidate is not None:
                            pending.append(nested)
                    require(
                        stable_metadata(os.fstat(dylib_descriptor))
                        == stable_metadata(dylib_before),
                        "private zstd dependency changed while inspected",
                    )
                finally:
                    os.close(dylib_descriptor)
            require(
                set(copied) == {
                    "libzstd.1.dylib",
                    "liblzma.5.dylib",
                    "liblz4.1.dylib",
                },
                "private zstd dependency closure is not exact",
            )
        finally:
            os.close(binary_directory)
            os.close(library_directory)
    finally:
        os.close(bundle)
    return "zstd-bundle/bin/zstd"


def copy_bound_tool(
    destination: int, name: str, ownership: PrivateOwnership
) -> str | None:
    candidate = resolve_tool_candidate(name)
    if candidate is None:
        return None
    source_path, source_descriptor, source_before = candidate
    try:
        if name == "zstd" and sys.platform == "darwin":
            return copy_darwin_zstd_bundle(
                destination,
                source_path,
                source_descriptor,
                source_before,
                ownership,
            )
        copy_open_descriptor(
            destination,
            name,
            source_descriptor,
            source_before,
            mode=0o500,
            ownership=ownership,
            relative=f"bound-tools/{name}",
        )
        return name
    except Exception as exc:
        raise ValidationError(f"{name} could not be bound privately") from exc
    finally:
        os.close(source_descriptor)


def descriptor_cwd_preexec(descriptor: int) -> Callable[[], None]:
    def enter() -> None:
        os.fchdir(descriptor)

    return enter


def run_git(
    repo: Path,
    arguments: list[str],
    *,
    binary: bool = False,
    cwd_descriptor: int | None = None,
) -> bytes | str:
    require_child_wait_authority()
    executable = trusted_git_executable()
    try:
        process_options: dict[str, object] = {}
        if cwd_descriptor is not None:
            process_options.update(
                pass_fds=(cwd_descriptor,),
                preexec_fn=descriptor_cwd_preexec(cwd_descriptor),
            )
        result = subprocess.run(
            [
                executable,
                "-c",
                f"safe.directory={repo}",
                "-C",
                "." if cwd_descriptor is not None else str(repo),
                *arguments,
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=isolated_git_environment(),
            timeout=60,
            **process_options,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValidationError("committed support provenance could not be verified") from exc
    if binary:
        return result.stdout
    try:
        return result.stdout.decode("utf-8", "strict").strip()
    except UnicodeDecodeError as exc:
        raise ValidationError("committed support provenance is not UTF-8") from exc


def safe_git_relative(repo: Path, path: Path) -> str:
    absolute = Path(os.path.abspath(os.fspath(path)))
    try:
        resolved = absolute.resolve(strict=True)
        relative = resolved.relative_to(repo)
    except (OSError, ValueError) as exc:
        raise ValidationError("a bound implementation path is outside the support repository") from exc
    require(resolved == absolute, "a bound implementation path has a symlinked component")
    value = relative.as_posix()
    require(
        bool(value)
        and not value.startswith("/")
        and all(part not in ("", ".", "..") for part in value.split("/")),
        "a bound implementation path is unsafe",
    )
    return value


@dataclass
class SupportBinding:
    repo: Path
    descriptor: int
    before: os.stat_result
    baseline_path: Path
    baseline_parent_descriptor: int
    baseline_record: FileRecord
    baseline: dict[str, str]
    support_head: str
    snapshot_private: PrivateTree
    snapshot_repo: Path
    snapshot_baseline: Path
    tools: dict[str, BoundTool]

    def close_descriptors(self) -> None:
        self.baseline_record.close()
        for descriptor in (self.baseline_parent_descriptor, self.descriptor):
            try:
                os.close(descriptor)
            except OSError:
                pass

    def close(self) -> None:
        cleanup_error: BaseException | None = None
        try:
            self.snapshot_private.cleanup()
        except BaseException as exc:
            cleanup_error = exc
        self.close_descriptors()
        if cleanup_error is not None:
            raise ValidationError("private support cleanup failed") from cleanup_error


def committed_blob(
    repo: Path,
    support_head: str,
    relative: str,
    *,
    maximum: int,
    repo_descriptor: int,
) -> bytes:
    require(
        bool(relative)
        and not relative.startswith("/")
        and all(part not in ("", ".", "..") for part in relative.split("/")),
        "private committed snapshot path is unsafe",
    )
    blob = run_git(
        repo,
        ["cat-file", "blob", f"{support_head}:{relative}"],
        binary=True,
        cwd_descriptor=repo_descriptor,
    )
    assert isinstance(blob, bytes)
    require(0 < len(blob) <= maximum, "private committed snapshot blob exceeds its bound")
    return blob


def write_private_snapshot_blob(
    root: int,
    relative: str,
    blob: bytes,
    created_directories: set[str],
    ownership: PrivateOwnership,
    ownership_prefix: str,
) -> None:
    parts = relative.split("/")
    current = os.dup(root)
    prefix: list[str] = []
    descriptor = -1
    try:
        for component in parts[:-1]:
            prefix.append(component)
            joined = "/".join(prefix)
            if joined not in created_directories:
                os.mkdir(component, mode=0o700, dir_fd=current)
                created_directories.add(joined)
            child, _metadata = open_child_directory(
                current, component, "private committed snapshot directory"
            )
            owned_relative = f"{ownership_prefix}/{joined}"
            if joined in created_directories:
                if owned_relative in ownership.directory_inodes:
                    ownership.require_directory(owned_relative, child)
                else:
                    ownership.declare_directory(owned_relative, child)
            os.close(current)
            current = child
        descriptor = os.open(
            parts[-1],
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o400,
            dir_fd=current,
        )
        owned_file = f"{ownership_prefix}/{relative}"
        ownership.declare_file_creation(owned_file, descriptor)
        view = memoryview(blob)
        while view:
            written = os.write(descriptor, view)
            require(written > 0, "private committed snapshot write was truncated")
            view = view[written:]
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o400)
        metadata = os.fstat(descriptor)
        require(
            metadata.st_size == len(blob)
            and hash_descriptor(descriptor, metadata.st_size)
            == hashlib.sha256(blob).hexdigest(),
            "private committed snapshot differs from its Git blob",
        )
        ownership.declare_file(
            owned_file,
            descriptor,
            hashlib.sha256(blob).hexdigest(),
        )
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(current)


def materialize_support_snapshot(
    repo: Path,
    repo_descriptor: int,
    support_head: str,
    baseline_relative: str,
    scratch_parent: ScratchParent,
) -> tuple[PrivateTree, Path, dict[str, BoundTool]]:
    try:
        private = PrivateTree.create(
            scratch_parent, "sp11-raw-support.", "private support snapshot"
        )
    except Exception as exc:
        raise ValidationError("private support snapshot could not be created") from exc
    support_descriptor = -1
    ownership = PrivateOwnership.create(private.root_descriptor)
    try:
        private_support_setup_barrier(private)
        os.mkdir("support", mode=0o700, dir_fd=private.root_descriptor)
        support_descriptor, _support_metadata = open_child_directory(
            private.root_descriptor, "support", "private support repository"
        )
        ownership.declare_directory("support", support_descriptor)
        os.fchmod(support_descriptor, 0o700)
        snapshot_files = (*SNAPSHOT_IMPLEMENTATIONS, baseline_relative)
        require(
            len(snapshot_files) == len(set(snapshot_files)),
            "private committed snapshot path set is not unique",
        )
        created_directories: set[str] = set()
        for relative in snapshot_files:
            write_private_snapshot_blob(
                support_descriptor,
                relative,
                committed_blob(
                    repo,
                    support_head,
                    relative,
                    maximum=(
                        MAX_BASELINE_BYTES
                        if relative == baseline_relative
                        else 64 * 1024 * 1024
                    ),
                    repo_descriptor=repo_descriptor,
                ),
                created_directories,
                ownership,
                "support",
            )
        expected_support_entries = created_directories | set(snapshot_files)
        require(
            set(capture_private_entries(support_descriptor))
            == expected_support_entries,
            "private committed snapshot is not the exact owned file set",
        )
        private.verify_root_binding()
        snapshot = private.path / "support"
        try:
            snapshot_metadata = snapshot.lstat()
        except OSError as exc:
            raise ValidationError("private support repository path changed during setup") from exc
        require(
            stat.S_ISDIR(snapshot_metadata.st_mode)
            and inode_identity(snapshot_metadata)
            == inode_identity(os.fstat(support_descriptor)),
            "private support repository path changed during setup",
        )
        os.mkdir("bound-tools", mode=0o700, dir_fd=private.root_descriptor)
        tools_descriptor, _tools_metadata = open_child_directory(
            private.root_descriptor, "bound-tools", "private bound-tool directory"
        )
        ownership.declare_directory("bound-tools", tools_descriptor)
        try:
            tool_names: dict[str, str] = {}
            for name in ("zstd", "lz4", "apt-helper"):
                copied = copy_bound_tool(tools_descriptor, name, ownership)
                if copied is not None:
                    tool_names[name] = copied
            expected_tool_entries: set[str] = set()
            for name, copied in tool_names.items():
                if name == "zstd" and sys.platform == "darwin":
                    require(
                        copied == "zstd-bundle/bin/zstd",
                        "private Darwin zstd path is not exact",
                    )
                    expected_tool_entries.update(
                        {
                            "zstd-bundle",
                            "zstd-bundle/bin",
                            "zstd-bundle/bin/zstd",
                            "zstd-bundle/lib",
                            "zstd-bundle/lib/libzstd.1.dylib",
                            "zstd-bundle/lib/liblzma.5.dylib",
                            "zstd-bundle/lib/liblz4.1.dylib",
                        }
                    )
                else:
                    require(copied == name, "private bound-tool path is not exact")
                    expected_tool_entries.add(name)
            require(
                set(capture_private_entries(tools_descriptor))
                == expected_tool_entries,
                "private bound-tool tree is not the exact owned file set",
            )
        finally:
            os.close(tools_descriptor)
        tools = {}
        for name, filename in tool_names.items():
            relative = f"bound-tools/{filename}"
            dyld = "bound-tools/zstd-bundle/lib" if name == "zstd" and sys.platform == "darwin" else None
            tools[name] = BoundTool(
                name,
                relative,
                private,
                private.root_descriptor,
                dyld,
            )
        require(
            set(
                bounded_directory_names(
                    private.root_descriptor, 3, "private support root"
                )
            )
            == {"support", "bound-tools"},
            "private support root contains an unexpected entry",
        )
        ownership.finalize_directories(private.root_descriptor)
        ownership.verify(private.root_descriptor)
        private_support_seal_barrier(private)
        ownership.verify(private.root_descriptor)
        private.seal()
        require(
            private.entries == ownership.expected_entries(),
            "sealed support tree differs from its owned declarations",
        )
        private.ownership = ownership
        private.verify()
        return private, snapshot, tools
    except Exception:
        cleanup_private_setup_failure(private, ownership)
        raise
    finally:
        if support_descriptor >= 0:
            os.close(support_descriptor)


def verify_blob(binding: SupportBinding, path: Path, expected: FileRecord | None = None) -> None:
    relative = safe_git_relative(binding.repo, path)
    committed = run_git(
        binding.repo,
        ["cat-file", "blob", f"{binding.support_head}:{relative}"],
        binary=True,
        cwd_descriptor=binding.descriptor,
    )
    assert isinstance(committed, bytes)
    if expected is None:
        parent = -1
        current: FileRecord | None = None
        try:
            parent, current = open_relative_file(
                binding.descriptor,
                relative,
                "bound implementation",
                maximum=64 * 1024 * 1024,
            )
            require(
                current.size == len(committed)
                and current.sha256 == hashlib.sha256(committed).hexdigest(),
                "a bound implementation differs from its support commit",
            )
            verify_file_stable(parent, current)
        finally:
            if current is not None:
                current.close()
            if parent >= 0:
                os.close(parent)
    else:
        require(
            len(committed) == expected.size
            and hashlib.sha256(committed).hexdigest() == expected.sha256,
            "the baseline differs from its support commit",
        )


def open_support_binding(
    directory_binding: tuple[Path, int, os.stat_result],
    support_head: str,
    baseline_path: Path,
    scratch_parent: ScratchParent,
) -> SupportBinding:
    repo, descriptor, before = directory_binding
    binding: SupportBinding | None = None
    baseline_record: FileRecord | None = None
    baseline_parent = -1
    snapshot_private: PrivateTree | None = None
    try:
        require(
            bool(OID.fullmatch(support_head)),
            "support HEAD must be a full lowercase object ID",
        )
        verify_bound_directory(directory_binding, "support repository")
        head = run_git(
            repo,
            ["rev-parse", "--verify", "HEAD^{commit}"],
            cwd_descriptor=descriptor,
        )
        require(head == support_head, "support repository HEAD differs from the requested commit")
        require(
            run_git(
                repo,
                ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                binary=True,
                cwd_descriptor=descriptor,
            )
            == b"",
            "support repository is not clean",
        )
        baseline_absolute = Path(os.path.abspath(os.fspath(baseline_path)))
        relative = safe_git_relative(repo, baseline_absolute)
        baseline_parent, baseline_record = open_relative_file(
            descriptor,
            relative,
            "kernel baseline",
            maximum=MAX_BASELINE_BYTES,
        )
        committed_baseline = committed_blob(
            repo,
            support_head,
            relative,
            maximum=MAX_BASELINE_BYTES,
            repo_descriptor=descriptor,
        )
        require(
            baseline_record.size == len(committed_baseline)
            and baseline_record.sha256
            == hashlib.sha256(committed_baseline).hexdigest(),
            "the parsed baseline differs from its support commit",
        )
        baseline_values = parse_baseline(baseline_record)
        verify_file_stable(baseline_parent, baseline_record)
        snapshot_private, snapshot_repo, tools = materialize_support_snapshot(
            repo, descriptor, support_head, relative, scratch_parent
        )
        snapshot_baseline = snapshot_repo / relative
        binding = SupportBinding(
            repo,
            descriptor,
            before,
            baseline_absolute,
            baseline_parent,
            baseline_record,
            baseline_values,
            support_head,
            snapshot_private,
            snapshot_repo,
            snapshot_baseline,
            tools,
        )
        comparator = Path(__file__).resolve(strict=True)
        require(
            comparator == repo / "scripts/compare-sp11-kernel-raw-builds.py",
            "the running comparator is not the supplied support implementation",
        )
        for path in (
            comparator,
            repo / "scripts/sp11-kernel-build-inputs.py",
            repo / "scripts/validate-sp11-image-release-manifests.py",
            repo / "scripts/validate-sp11-module-signatures.py",
        ):
            verify_blob(binding, path)
        verify_blob(binding, baseline_absolute, baseline_record)
        return binding
    except Exception:
        if binding is not None:
            binding.close()
        else:
            if baseline_record is not None:
                baseline_record.close()
            if baseline_parent >= 0:
                os.close(baseline_parent)
            os.close(descriptor)
            if snapshot_private is not None:
                if snapshot_private.entries is None:
                    snapshot_private.preserve()
                if not snapshot_private.preserved:
                    try:
                        snapshot_private.cleanup()
                    except Exception:
                        pass
        raise


def verify_support_stable(binding: SupportBinding) -> None:
    try:
        path_metadata = binding.repo.lstat()
    except OSError as exc:
        raise ValidationError("support repository path binding changed") from exc
    require(
        stat.S_ISDIR(path_metadata.st_mode)
        and stable_metadata(path_metadata) == stable_metadata(binding.before)
        and stable_metadata(os.fstat(binding.descriptor))
        == stable_metadata(binding.before),
        "support repository directory changed during comparison",
    )
    require(
        run_git(
            binding.repo,
            ["rev-parse", "--verify", "HEAD^{commit}"],
            cwd_descriptor=binding.descriptor,
        )
        == binding.support_head,
        "support repository HEAD changed during comparison",
    )
    require(
        run_git(
            binding.repo,
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            binary=True,
            cwd_descriptor=binding.descriptor,
        )
        == b"",
        "support repository changed during comparison",
    )
    verify_blob(binding, Path(__file__).resolve(strict=True))
    verify_blob(binding, binding.baseline_path, binding.baseline_record)
    verify_file_stable(binding.baseline_parent_descriptor, binding.baseline_record)
    if not binding.snapshot_private.cleaned:
        binding.snapshot_private.verify()


def snapshot_source_read_barrier(
    _binding: SupportBinding, _relative: str
) -> Callable[[], None] | None:
    """No-op boundary used by deterministic A/B/A race fixtures."""

    return None


def read_snapshot_source(
    binding: SupportBinding, relative: str, *, maximum: int = 64 * 1024 * 1024
) -> bytes:
    binding.snapshot_private.verify_root_binding()
    root_descriptor, opened_root = open_child_directory(
        binding.snapshot_private.root_descriptor,
        "support",
        "private support snapshot",
    )
    parent = -1
    record: FileRecord | None = None
    try:
        expected_root = binding.snapshot_private.entries
        require(expected_root is not None, "private support snapshot is not sealed")
        require(
            stable_metadata(opened_root) == expected_root["support"].metadata,
            "private support snapshot directory changed",
        )
        parent, record = open_relative_file(
            root_descriptor, relative, "private committed implementation", maximum=maximum
        )
        committed = run_git(
            binding.repo,
            ["cat-file", "blob", f"{binding.support_head}:{relative}"],
            binary=True,
            cwd_descriptor=binding.descriptor,
        )
        assert isinstance(committed, bytes)
        require(
            record.size == len(committed)
            and record.sha256 == hashlib.sha256(committed).hexdigest(),
            "private implementation differs from its committed blob",
        )
        source = read_descriptor(record, maximum)
        verify_file_stable(parent, record)
        return source
    finally:
        if record is not None:
            record.close()
        if parent >= 0:
            os.close(parent)
        os.close(root_descriptor)


def load_snapshot_module(binding: SupportBinding, relative: str, name: str) -> ModuleType:
    try:
        source = read_snapshot_source(binding, relative)
        path = binding.snapshot_repo / relative
        restore = snapshot_source_read_barrier(binding, relative)
        try:
            module = ModuleType(name)
            module.__file__ = str(path)
            module.__package__ = ""
            sys.modules[name] = module
            exec(compile(source, str(path), "exec"), module.__dict__)
            return module
        finally:
            if restore is not None:
                restore()
    except Exception as exc:
        raise ValidationError("a committed validation module could not be loaded") from exc


def load_deb_reader(binding: SupportBinding) -> ModuleType:
    name = "_sp11_raw_pair_bounded_deb_reader_v1"
    try:
        module = load_snapshot_module(
            binding, "scripts/validate-sp11-module-signatures.py", name
        )
    except Exception as exc:
        raise ValidationError("the bounded Debian reader could not be loaded") from exc
    return module


class BoundedXZReader(io.RawIOBase):
    """Stream exactly one XZ member with a hard decoder-memory ceiling."""

    def __init__(self, source: BinaryIO) -> None:
        super().__init__()
        self.source = source
        self.decoder = lzma.LZMADecompressor(
            format=lzma.FORMAT_XZ, memlimit=MAX_CONTROL_DECODE_MEMORY
        )
        self.buffer = bytearray()
        self.finished = False

    def readable(self) -> bool:
        return True

    def readinto(self, target: bytearray | memoryview) -> int:
        if not target:
            return 0
        try:
            while not self.buffer and not self.finished:
                if self.decoder.needs_input:
                    compressed = self.source.read(64 * 1024)
                    if not compressed:
                        require(self.decoder.eof, "XZ control archive is truncated")
                        self.finished = True
                        break
                else:
                    compressed = b""
                output = self.decoder.decompress(compressed, max_length=len(target))
                self.buffer.extend(output)
                if self.decoder.eof:
                    require(
                        not self.decoder.unused_data and not self.source.read(1),
                        "XZ control archive contains trailing or concatenated data",
                    )
                    self.finished = True
            count = min(len(target), len(self.buffer))
            target[:count] = self.buffer[:count]
            del self.buffer[:count]
            return count
        except lzma.LZMAError as exc:
            raise ValidationError("XZ control archive exceeds its memory limit or is malformed") from exc


def zstd_arguments(program: str) -> list[str]:
    return [
        program,
        "--decompress",
        "--stdout",
        "--quiet",
        "--memory=64MB",
    ]


def verify_bound_tool(program: BoundTool) -> None:
    program.private.verify_root_binding()
    parent = -1
    record: FileRecord | None = None
    try:
        parent, record = open_relative_file(
            program.root_descriptor,
            program.relative,
            f"bound {program.name}",
            maximum=MAX_TOOL_BYTES,
        )
        require(
            bool(record.before.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
            and not record.before.st_mode & (stat.S_IWGRP | stat.S_IWOTH),
            f"bound {program.name} is not a safe executable",
        )
        expected = program.private.entries
        require(
            expected is not None
            and program.relative in expected
            and expected[program.relative].kind == "file"
            and stable_metadata(record.before) == expected[program.relative].metadata,
            f"bound {program.name} differs from its sealed identity",
        )
        verify_file_stable(parent, record)
    finally:
        if record is not None:
            record.close()
        if parent >= 0:
            os.close(parent)


def bound_tool_environment(program: BoundTool) -> dict[str, str]:
    environment = trusted_process_environment()
    if program.dyld_library_path is not None:
        environment["DYLD_LIBRARY_PATH"] = program.dyld_library_path
    return environment


def zstd_command(program: BoundTool | None) -> list[str]:
    require(program is not None, "a bound zstd decoder is unavailable")
    assert program is not None
    verify_bound_tool(program)
    return zstd_arguments(program.relative)


def run_owned_decoder(
    command: list[str],
    *,
    label: str,
    output_maximum: int,
    retain_output: bool,
    environment: dict[str, str],
    pass_fds: tuple[int, ...] = (),
    child_setup: Callable[[], None] | None = None,
    input_source: BinaryIO | None = None,
    input_descriptor: int | None = None,
) -> tuple[bytes | None, int, str]:
    """Run one decoder with bounded streams and exact signal-safe ownership."""

    require_child_wait_authority()
    require(
        0 <= output_maximum <= MAX_APT_DECODED_BYTES,
        f"{label} has an invalid output limit",
    )
    require(
        not (input_source is not None and input_descriptor is not None),
        f"{label} has ambiguous input authority",
    )
    process: subprocess.Popen[bytes] | None = None
    selector: selectors.BaseSelector | None = None
    returncode: int | None = None
    failure: BaseException | None = None
    interrupted_signal: int | None = None
    output_size = 0
    output_digest = hashlib.sha256()
    output = bytearray() if retain_output else None
    diagnostics_size = 0
    release_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    original_handlers = {
        release_signal: signal.getsignal(release_signal)
        for release_signal in release_signals
    }

    def interrupted(number: int, _frame: object) -> None:
        nonlocal interrupted_signal
        interrupted_signal = number
        signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        raise InterruptedError(f"{label} interrupted by signal {number}")

    def check_interrupted() -> None:
        if interrupted_signal is not None:
            raise InterruptedError(
                f"{label} interrupted by signal {interrupted_signal}"
            )

    def close_streams() -> None:
        assert process is not None
        for stream in (process.stdin, process.stdout, process.stderr):
            try:
                if stream is not None:
                    stream.close()
            except BaseException:
                pass

    def stop_and_wait() -> None:
        assert process is not None
        close_streams()
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
        try:
            process.wait(timeout=EXTERNAL_DECODER_STOP_TIMEOUT_SECONDS)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
        process.wait()

    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
    try:
        for release_signal in release_signals:
            signal.signal(release_signal, interrupted)

        def child_preexec() -> None:
            if child_setup is not None:
                child_setup()
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE
            if input_source is not None
            else input_descriptor
            if input_descriptor is not None
            else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            pass_fds=pass_fds,
            close_fds=True,
            start_new_session=True,
            preexec_fn=child_preexec,
        )
        if (
            process.stdout is None
            or process.stderr is None
            or (input_source is not None and process.stdin is None)
        ):
            raise OSError(f"{label} pipes are unavailable")
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        check_interrupted()

        selector = selectors.DefaultSelector()
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout.fileno(), selectors.EVENT_READ, "stdout")
        os.set_blocking(process.stderr.fileno(), False)
        selector.register(process.stderr.fileno(), selectors.EVENT_READ, "stderr")
        pending_input = memoryview(b"")
        if input_source is not None:
            assert process.stdin is not None
            os.set_blocking(process.stdin.fileno(), False)
            selector.register(process.stdin.fileno(), selectors.EVENT_WRITE, "stdin")

        started = time.monotonic()
        deadline = started + EXTERNAL_DECODER_TOTAL_TIMEOUT_SECONDS
        last_progress = started
        while selector.get_map():
            check_interrupted()
            now = time.monotonic()
            remaining_total = deadline - now
            remaining_progress = EXTERNAL_DECODER_IDLE_TIMEOUT_SECONDS - (
                now - last_progress
            )
            if remaining_total <= 0 or remaining_progress <= 0:
                raise TimeoutError(f"{label} exceeded its deadline")
            events = selector.select(
                min(1.0, remaining_total, remaining_progress)
            )
            check_interrupted()
            if not events:
                continue
            for key, _mask in events:
                if key.data == "stdin":
                    assert input_source is not None and process.stdin is not None
                    if not pending_input:
                        chunk = input_source.read(64 * 1024)
                        if not chunk:
                            selector.unregister(key.fd)
                            process.stdin.close()
                            continue
                        if not isinstance(chunk, bytes):
                            raise OSError(f"{label} input returned non-byte data")
                        pending_input = memoryview(chunk)
                    try:
                        written = os.write(key.fd, pending_input)
                    except BlockingIOError:
                        continue
                    if written <= 0:
                        raise OSError(f"{label} input write made no progress")
                    pending_input = pending_input[written:]
                    last_progress = time.monotonic()
                    continue

                maximum_read = 64 * 1024
                if key.data == "stdout":
                    maximum_read = min(
                        maximum_read, output_maximum - output_size + 1
                    )
                try:
                    chunk = os.read(key.fd, maximum_read)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                last_progress = time.monotonic()
                if key.data == "stdout":
                    output_size += len(chunk)
                    if output_size > output_maximum:
                        raise OSError(f"{label} output exceeded its limit")
                    output_digest.update(chunk)
                    if output is not None:
                        output.extend(chunk)
                else:
                    # Tool diagnostics are non-authoritative.  Permit bounded
                    # warnings, drain them independently, and never include
                    # their untrusted bytes in an error or comparison result.
                    diagnostics_size += len(chunk)
                    if diagnostics_size > EXTERNAL_DECODER_STDERR_MAX:
                        raise OSError(f"{label} diagnostics exceeded their limit")
            check_interrupted()

        check_interrupted()
        remaining = min(
            deadline - time.monotonic(),
            EXTERNAL_DECODER_IDLE_TIMEOUT_SECONDS
            - (time.monotonic() - last_progress),
        )
        if remaining <= 0:
            raise TimeoutError(f"{label} did not exit before its deadline")
        # Popen.wait() may reap in waitpid() before it records returncode.
        # Block terminal signals through both that internal transition and the
        # caller's local registration; only then unmask and honor the latch.
        wait_mask = signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        try:
            returncode = process.wait(timeout=remaining)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, wait_mask)
        check_interrupted()
        if returncode != 0:
            raise OSError(f"{label} exited unsuccessfully")
    except BaseException as exc:
        failure = exc
    finally:
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
            # wait() records this before returning.  Adopt it across a signal
            # between the CALL and local STORE; never kill by an already-reaped
            # PID or process-group identifier.
            if returncode is None and process.returncode is not None:
                returncode = process.returncode
            if returncode is None:
                try:
                    stop_and_wait()
                except BaseException as exc:
                    if failure is None:
                        failure = exc
            else:
                close_streams()
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
        if isinstance(failure, ValidationError):
            raise failure
        raise ValidationError(f"{label} failed") from failure
    return (
        bytes(output) if output is not None else None,
        output_size,
        output_digest.hexdigest(),
    )


@contextlib.contextmanager
def bounded_zstd_stream(
    source: BinaryIO,
    program: BoundTool | None,
    maximum: int,
) -> Iterator[BinaryIO]:
    command = zstd_command(program)
    environment = trusted_process_environment()
    pass_fds: tuple[int, ...] = ()
    child_setup: Callable[[], None] | None = None
    if program is not None:
        private_tool_launch_barrier(program)
        pass_fds = (program.root_descriptor,)
        child_setup = descriptor_cwd_preexec(program.root_descriptor)
        environment = bound_tool_environment(program)
    decoded, _size, _sha256 = run_owned_decoder(
        command,
        label="bounded zstd control decoder",
        output_maximum=maximum,
        retain_output=True,
        environment=environment,
        pass_fds=pass_fds,
        child_setup=child_setup,
        input_source=source,
    )
    assert decoded is not None
    with io.BytesIO(decoded) as stream:
        yield stream


@contextlib.contextmanager
def bounded_control_stream(
    source: BinaryIO,
    member_name: str,
    zstd_program: BoundTool | None,
    maximum: int,
) -> Iterator[BinaryIO]:
    try:
        if member_name.endswith(".tar"):
            yield source
        elif member_name.endswith(".tar.gz"):
            with gzip.GzipFile(fileobj=source, mode="rb") as stream:
                yield stream
        elif member_name.endswith(".tar.xz"):
            with io.BufferedReader(BoundedXZReader(source)) as stream:
                yield stream
        elif member_name.endswith(".tar.zst"):
            with bounded_zstd_stream(source, zstd_program, maximum) as stream:
                yield stream
        else:
            raise ValidationError("Debian control archive uses unsupported compression")
    except (gzip.BadGzipFile, EOFError, OSError) as exc:
        raise ValidationError("Debian control archive compression is malformed") from exc


def package_control_fields(
    deb: ModuleType, record: FileRecord, zstd_program: BoundTool | None
) -> dict[str, str]:
    try:
        members = deb.parse_ar(record.descriptor, record.size)
        control_names = [name for name in members if name in deb.CONTROL_ARCHIVE_NAMES]
        require(len(control_names) == 1, "Debian package control archive is ambiguous")
        member = members[control_names[0]]
        require(
            member.size <= MAX_CONTROL_COMPRESSED_BYTES,
            "Debian control archive exceeds its compressed-size limit",
        )
        source: BinaryIO = io.BufferedReader(
            deb.PreadSlice(record.descriptor, member.offset, member.size)
        )
        control_data: bytes | None = None
        seen: dict[str, str] = {}
        with bounded_control_stream(
            source,
            member.name,
            zstd_program,
            deb.MAX_CONTROL_TAR_BYTES,
        ) as decompressed:
            limited = io.BufferedReader(
                deb.LimitedReader(decompressed, deb.MAX_CONTROL_TAR_BYTES, "control archive")
            )
            guarded = io.BufferedReader(deb.TarMetadataGuardReader(limited))
            with tarfile.open(fileobj=guarded, mode="r|") as archive:
                for index, item in enumerate(archive, 1):
                    require(index <= deb.MAX_MEMBERS, "Debian control archive has too many members")
                    name = deb.canonical_member_name(item.name)
                    require(name not in seen, "Debian control archive has a duplicate path")
                    require(
                        not item.issparse() and (item.isdir() or item.isfile()),
                        "Debian control archive contains a link or special member",
                    )
                    seen[name] = "directory" if item.isdir() else "file"
                    require(
                        not item.isfile() or item.size <= deb.MAX_CONTROL_TAR_BYTES,
                        "Debian control member exceeds its size limit",
                    )
                    if name == "control":
                        require(item.isfile(), "Debian control metadata is not a regular file")
                        extracted = archive.extractfile(item)
                        require(extracted is not None, "Debian control metadata could not be read")
                        assert extracted is not None
                        with extracted:
                            control_data = extracted.read(deb.MAX_CONTROL_BYTES + 1)
            deb.drain_zero_tar_tail(guarded)
        deb.validate_member_ancestors(seen, "control archive")
        require(control_data is not None, "Debian control metadata is missing")
        return deb.read_control_fields(control_data)
    except ValidationError:
        raise
    except Exception as exc:
        # The committed bounded reader has its own ValidationError type; collapse all
        # parser diagnostics so private paths/content can never reach the public CLI.
        raise ValidationError("Debian package control validation failed") from exc


def control_identity(
    deb: ModuleType,
    file_record: FileRecord,
    zstd_program: BoundTool | None,
    expected_package: str,
    expected_version: str,
    expected_architecture: str,
) -> None:
    fields = package_control_fields(deb, file_record, zstd_program)
    package = fields.get("Package", "")
    version = fields.get("Version", "")
    architecture = fields.get("Architecture", "")
    require(
        bool(SAFE_PACKAGE.fullmatch(package))
        and bool(SAFE_VERSION.fullmatch(version))
        and bool(SAFE_ARCH.fullmatch(architecture)),
        "Debian package control identity is unsafe",
    )
    require(
        (package, version, architecture)
        == (expected_package, expected_version, expected_architecture),
        "Debian package control identity differs from provenance",
    )
    require(
        file_record.name == f"{package}_{version}_{architecture}.deb",
        "Debian package filename differs from its control identity",
    )


def validator_environment(baseline: dict[str, str]) -> dict[str, str]:
    del baseline
    return trusted_process_environment()


def baseline_validation_barrier(
    _support: SupportBinding,
) -> Callable[[], None] | None:
    """No-op boundary used by deterministic baseline A/B/A fixtures."""

    return None


def bound_apt_list_identity(
    path: Path,
    baseline: dict[str, str],
    support: SupportBinding,
    private_build: PrivateTree,
    expected: tuple[int, str],
) -> tuple[int, str]:
    expected_size, expected_sha256 = expected
    require(
        isinstance(expected_size, int)
        and 0 <= expected_size <= MAX_APT_DECODED_BYTES
        and bool(SHA256.fullmatch(expected_sha256)),
        "signed APT index has an invalid decompressed identity",
    )
    parent = -1
    record: FileRecord | None = None
    try:
        require(
            path.parent.name == "apt-lists"
            and bool(SAFE_NAME.fullmatch(path.name))
            and "/" not in path.name,
            "APT list decoder requested an unsafe retained path",
        )
        parent, record = open_relative_file(
            private_build.root_descriptor,
            f"apt-lists/{path.name}",
            "APT list decoder input",
            maximum=MAX_ARTIFACT_BYTES,
        )
    except (OSError, ValueError, ValidationError) as exc:
        raise ValidationError("APT list decoder input could not be bound") from exc
    try:
        assert record is not None
        opened = record.before
        descriptor = record.descriptor
        if (
            baseline.get("SP11_KERNEL_BASELINE_ID") == "fixture"
            and baseline.get("SP11_KERNEL_UPSTREAM_URL")
            == "https://github.com/example/linux.git"
            and baseline.get("SP11_KERNEL_UPSTREAM_REF") in {"fixture", "fixture/ref"}
        ):
            result = (opened.st_size, hash_descriptor(descriptor, opened.st_size))
        else:
            standard_input: int | None = None
            if "lz4" in support.tools:
                tool = support.tools["lz4"]
                command = [tool.relative, "-d", "-c"]
                standard_input = descriptor
            elif "apt-helper" in support.tools and sys.platform.startswith("linux"):
                tool = support.tools["apt-helper"]
                command = [
                    tool.relative,
                    "cat-file",
                    f"/proc/self/fd/{descriptor}",
                ]
            else:
                raise ValidationError("a bound APT list decoder is unavailable")
            verify_bound_tool(tool)
            private_tool_launch_barrier(tool)
            _output, size, decoded_sha256 = run_owned_decoder(
                command,
                label="bound APT list decoder",
                output_maximum=expected_size,
                retain_output=False,
                environment=bound_tool_environment(tool),
                pass_fds=(tool.root_descriptor, descriptor),
                child_setup=descriptor_cwd_preexec(tool.root_descriptor),
                input_descriptor=standard_input,
            )
            result = (size, decoded_sha256)
        require(
            result == expected,
            "bound APT list decoder output differs from the signed index",
        )
        require(
            stable_metadata(os.fstat(descriptor)) == stable_metadata(opened),
            "APT list decoder input descriptor changed while decoded",
        )
        verify_file_stable(parent, record)
        return result
    finally:
        if record is not None:
            record.close()
        if parent >= 0:
            os.close(parent)


def invoke_module_main(
    module: ModuleType,
    argv: list[str],
    *,
    environment: dict[str, str] | None = None,
) -> None:
    saved_argv = sys.argv
    saved_environment = dict(os.environ) if environment is not None else None
    sys.argv = argv
    if environment is not None:
        os.environ.clear()
        os.environ.update(environment)
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            try:
                result = module.main()
            except SystemExit as exc:
                require(exc.code in (None, 0), "committed input validation failed")
            except Exception as exc:
                raise ValidationError("committed input validation failed") from exc
            else:
                require(result in (None, 0), "committed input validation failed")
    finally:
        sys.argv = saved_argv
        if saved_environment is not None:
            os.environ.clear()
            os.environ.update(saved_environment)


def validate_retained_inputs(
    build: PrivateTree,
    support: SupportBinding,
    baseline: dict[str, str],
    control_hashes: dict[str, str],
) -> None:
    module = load_snapshot_module(
        support,
        "scripts/sp11-kernel-build-inputs.py",
        f"_sp11_raw_pair_retained_validator_{id(build)}",
    )

    def validate_exact_build_manifest(path: Path, support_head: str) -> None:
        image_module = load_snapshot_module(
            support,
            "scripts/validate-sp11-image-release-manifests.py",
            f"_sp11_raw_pair_manifest_validator_{id(path)}",
        )

        def run_bound_git(
            _repo: Path, arguments: list[str], *, binary: bool = False
        ) -> bytes | str:
            return run_git(
                support.repo,
                arguments,
                binary=binary,
                cwd_descriptor=support.descriptor,
            )

        image_module.run_git = run_bound_git
        invoke_module_main(
            image_module,
            [
                str(support.snapshot_repo / "scripts/validate-sp11-image-release-manifests.py"),
                "--build-only",
                "--repo-dir",
                str(support.snapshot_repo),
                "--support-commit",
                support_head,
                "--kernel-build-manifest",
                str(path),
            ],
            environment=trusted_process_environment(),
        )

    module.validate_exact_build_manifest = validate_exact_build_manifest
    captured_baseline = dict(baseline)

    def read_bound_baseline(
        path: Path, expected_sha256: str | None = None
    ) -> dict[str, str]:
        require(
            Path(os.path.abspath(os.fspath(path))) == support.snapshot_baseline,
            "committed validator requested an unbound baseline",
        )
        require(
            expected_sha256 == support.baseline_record.sha256,
            "committed validator requested an unbound baseline hash",
        )
        return dict(captured_baseline)

    module.read_baseline = read_bound_baseline
    def bound_expected_apt_list_identity(
        path: Path,
        values: dict[str, str],
        expected: tuple[int, str],
    ) -> tuple[int, str]:
        identity = bound_apt_list_identity(
            path, values, support, build, expected
        )
        require(
            identity == expected,
            "bound APT list decoder output differs from the signed index",
        )
        return identity

    module.apt_list_identity = bound_expected_apt_list_identity
    build_path = build.path
    arguments = [
        str(support.snapshot_repo / "scripts/sp11-kernel-build-inputs.py"),
        "validate-release-snapshot",
        "--baseline",
        str(support.snapshot_baseline),
        "--baseline-sha256",
        support.baseline_record.sha256,
        "--work-dir",
        str(build_path),
        "--support-head",
        support.support_head,
        "--build-args",
        str(build_path / "docker-build-args.txt"),
        "--build-args-sha256",
        control_hashes["build-arguments"],
        "--entrypoint",
        str(build_path / "docker-build-inside.sh"),
        "--entrypoint-sha256",
        control_hashes["entrypoint"],
        "--oci-index",
        str(build_path / "sp11-oci-index.json"),
        "--oci-index-sha256",
        control_hashes["oci-index"],
        "--build-manifest",
        str(build_path / "artifacts/sp11-kernel-build-manifest.txt"),
        "--apt-provenance",
        str(build_path / "artifacts/sp11-kernel-apt-provenance.txt"),
        "--apt-archives-dir",
        str(build_path / "apt-archives"),
        "--apt-lists-dir",
        str(build_path / "apt-lists"),
        "--apt-index-cache-dir",
        str(build_path / "apt-indexes"),
        "--apt-local-build-deps-dir",
        str(build_path / "artifacts"),
        "--apt-pre-inventory",
        str(build_path / "sp11-apt-installed-pre.txt"),
        "--apt-post-inventory",
        str(build_path / "sp11-apt-installed-post.txt"),
        "--output",
        str(build_path / "artifacts/sp11-kernel-build-inputs.txt"),
    ]
    restore = baseline_validation_barrier(support)
    try:
        invoke_module_main(
            module, arguments, environment=validator_environment(baseline)
        )
    finally:
        if restore is not None:
            restore()


def safe_artifact_name(name: str) -> None:
    require(
        bool(SAFE_NAME.fullmatch(name)) and not name.startswith(".") and ".." not in name,
        "artifact directory contains an unsafe name",
    )


def parse_packages(
    manifest: dict[str, str],
    artifacts: dict[str, FileRecord],
    deb: ModuleType,
    zstd_program: BoundTool | None,
) -> dict[str, PackageRecord]:
    count = positive_decimal(field(manifest, "Deb count"))
    require(count in (4, 5), "kernel Deb count is not exact")
    packages: dict[str, PackageRecord] = {}
    for index in range(1, count + 1):
        role = field(manifest, f"Deb {index} role")
        require(role in ROLE_ORDER and role not in packages, "kernel Deb role set is invalid")
        filename = field(manifest, f"Deb {index} path")
        package = field(manifest, f"Deb {index} package")
        version = field(manifest, f"Deb {index} version")
        architecture = field(manifest, f"Deb {index} architecture")
        size = positive_decimal(field(manifest, f"Deb {index} size"))
        digest = field(manifest, f"Deb {index} SHA256")
        require(bool(SHA256.fullmatch(digest)), "kernel Deb hash is invalid")
        require(filename in artifacts, "manifest-bound kernel Deb is absent")
        file_record = artifacts[filename]
        require(
            file_record.size == size and file_record.sha256 == digest,
            "manifest-bound kernel Deb raw identity is false",
        )
        control_identity(
            deb, file_record, zstd_program, package, version, architecture
        )
        packages[role] = PackageRecord(
            role, filename, package, version, architecture, size, digest
        )
    require(
        set(packages).issuperset({"common-headers", "headers", "image", "modules"})
        and set(packages).issubset(set(ROLE_ORDER)),
        "required kernel Deb role set is incomplete",
    )
    return packages


def parse_outputs(manifest: dict[str, str]) -> dict[str, OutputRecord]:
    count = positive_decimal(field(manifest, "Output count"))
    require(count == len(OUTPUT_ORDER), "manifest output count is not exact")
    outputs: dict[str, OutputRecord] = {}
    for index in range(1, count + 1):
        role = field(manifest, f"Output {index} role")
        require(role in OUTPUT_ORDER and role not in outputs, "manifest output role set is invalid")
        size = positive_decimal(field(manifest, f"Output {index} size"))
        digest = field(manifest, f"Output {index} SHA256")
        require(bool(SHA256.fullmatch(digest)), "manifest output hash is invalid")
        outputs[role] = OutputRecord(
            role, field(manifest, f"Output {index} path"), size, digest
        )
    require(set(outputs) == set(OUTPUT_ORDER), "manifest output role set is incomplete")
    return outputs


def parse_deb_list(record: FileRecord, packages: dict[str, PackageRecord]) -> None:
    raw = read_descriptor(record, MAX_DEB_LIST_BYTES)
    require(raw.endswith(b"\n") and b"\r" not in raw, "kernel Deb list framing is invalid")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise ValidationError("kernel Deb list is not UTF-8") from exc
    require(lines == sorted(lines) and len(lines) == len(set(lines)), "kernel Deb list is not sorted/unique")
    basenames: list[str] = []
    for line in lines:
        require(
            bool(line)
            and line.startswith("/")
            and "\\" not in line
            and not any(character.isspace() or ord(character) < 32 for character in line),
            "kernel Deb list contains an unsafe path",
        )
        path = PurePosixPath(line)
        require(
            path.as_posix() == line and all(part not in ("", ".", "..") for part in path.parts),
            "kernel Deb list contains a non-canonical path",
        )
        basenames.append(path.name)
    require(
        set(basenames) == {package.filename for package in packages.values()}
        and len(basenames) == len(packages),
        "kernel Deb list differs from the exact manifest package set",
    )


def parse_local_build_deps(
    sidecar: dict[str, str],
    artifacts: dict[str, FileRecord],
    deb: ModuleType,
    zstd_program: BoundTool | None,
) -> PackageRecord:
    require(field(sidecar, "Local build-deps count") == "1", "local build-deps count is not exact")
    filename = field(sidecar, "Local build-deps 1 path")
    package = field(sidecar, "Local build-deps 1 package")
    version = field(sidecar, "Local build-deps 1 version")
    architecture = field(sidecar, "Local build-deps 1 architecture")
    size = positive_decimal(field(sidecar, "Local build-deps 1 size"))
    digest = field(sidecar, "Local build-deps 1 SHA256")
    require(bool(SHA256.fullmatch(digest)) and filename in artifacts, "local build-deps identity is invalid")
    file_record = artifacts[filename]
    require(
        file_record.size == size and file_record.sha256 == digest,
        "local build-deps raw identity differs from its sidecar",
    )
    control_identity(
        deb, file_record, zstd_program, package, version, architecture
    )
    return PackageRecord("local-build-deps", filename, package, version, architecture, size, digest)


def open_build(
    directory_binding: tuple[Path, int, os.stat_result],
    support: SupportBinding,
    deb: ModuleType,
    scratch_parent: ScratchParent,
    forbidden_inodes: set[tuple[int, int]] | None = None,
) -> OpenBuild:
    absolute, directory_descriptor, directory_before = directory_binding
    artifact_descriptor = -1
    artifacts: dict[str, FileRecord] = {}
    controls: dict[str, FileRecord] = {}
    managed: ManagedTree | None = None
    try:
        verify_bound_directory(directory_binding, "build directory")
        artifact_descriptor, artifact_before = open_child_directory(
            directory_descriptor, "artifacts", "artifact directory"
        )
        try:
            names = bounded_directory_names(
                artifact_descriptor, MAX_ARTIFACT_ENTRIES, "artifact directory"
            )
        except ValidationError:
            raise
        require(bool(names), "artifact directory is empty")
        total = 0
        for name in names:
            safe_artifact_name(name)
            record = open_child_file(
                artifact_descriptor,
                name,
                "artifact",
                maximum=MAX_ARTIFACT_BYTES,
            )
            artifacts[name] = record
            total += record.size
            require(total <= MAX_ARTIFACT_TOTAL_BYTES, "artifact set exceeds its total size limit")
        for role, name in CONTROL_FILES.items():
            controls[role] = open_child_file(
                directory_descriptor,
                name,
                "retained control input",
                maximum=MAX_CONTROL_BYTES,
            )

        for required in KNOWN_ARTIFACTS:
            require(required in artifacts, "artifact set omits a required provenance file")
        manifest = parse_schema(
            artifacts["sp11-kernel-build-manifest.txt"], MAX_MANIFEST_BYTES, "build manifest"
        )
        reviewed_patch_count(manifest)
        envelope = parse_schema(
            artifacts["sp11-kernel-build-inputs.txt"], MAX_CONTROL_BYTES, "build-inputs envelope"
        )
        sidecar = parse_schema(
            artifacts["sp11-kernel-apt-provenance.txt"], MAX_SIDECAR_BYTES, "APT sidecar"
        )

        packages = parse_packages(
            manifest, artifacts, deb, support.tools.get("zstd")
        )
        outputs = parse_outputs(manifest)
        local_build_deps = parse_local_build_deps(
            sidecar, artifacts, deb, support.tools.get("zstd")
        )
        expected_names = (
            KNOWN_ARTIFACTS
            | {package.filename for package in packages.values()}
            | {local_build_deps.filename}
        )
        require(set(names) == expected_names, "artifact set is not the exact allowlist")
        parse_deb_list(artifacts["sp11-kernel-debs.txt"], packages)
        if forbidden_inodes:
            candidate_entries = capture_managed_tree(directory_descriptor, names)
            require(
                {
                    (entry.metadata[0], entry.metadata[1])
                    for entry in candidate_entries.values()
                    if entry.kind == "file"
                }.isdisjoint(forbidden_inodes),
                "matched-pair builds share a managed retained inode",
            )
        managed = ManagedTree.create(
            absolute,
            directory_descriptor,
            names,
            scratch_parent,
        )
        restore = managed_snapshot_barrier(managed)
        try:
            validate_retained_inputs(
                managed.private,
                support,
                support.baseline,
                {role: record.sha256 for role, record in controls.items()},
            )
        finally:
            if restore is not None:
                restore()
        managed.verify()
        return OpenBuild(
            absolute,
            directory_descriptor,
            directory_before,
            artifact_descriptor,
            artifact_before,
            names,
            artifacts,
            controls,
            managed,
            manifest,
            envelope,
            sidecar,
            packages,
            outputs,
            local_build_deps,
        )
    except Exception:
        if managed is not None:
            try:
                managed.cleanup()
            except Exception:
                pass
        for record in (*artifacts.values(), *controls.values()):
            record.close()
        if artifact_descriptor >= 0:
            os.close(artifact_descriptor)
        os.close(directory_descriptor)
        raise


def verify_file_stable(parent: int, record: FileRecord) -> None:
    descriptor_after = os.fstat(record.descriptor)
    try:
        path_after = os.stat(record.name, dir_fd=parent, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError("a retained file disappeared during comparison") from exc
    require(
        stat.S_ISREG(path_after.st_mode)
        and stable_metadata(record.before) == stable_metadata(descriptor_after)
        and stable_metadata(record.before) == stable_metadata(path_after)
        and hash_descriptor(record.descriptor, record.size) == record.sha256,
        "a retained file changed during comparison",
    )


def verify_build_stable(build: OpenBuild) -> None:
    require(
        stable_metadata(os.fstat(build.directory_descriptor))
        == stable_metadata(build.directory_before),
        "build directory changed during comparison",
    )
    require(
        stable_metadata(os.fstat(build.artifact_descriptor))
        == stable_metadata(build.artifact_before),
        "artifact directory changed during comparison",
    )
    names = bounded_directory_names(
        build.artifact_descriptor, MAX_ARTIFACT_ENTRIES, "artifact directory"
    )
    require(names == build.artifact_names, "artifact set changed during comparison")
    for record in build.artifacts.values():
        verify_file_stable(build.artifact_descriptor, record)
    for record in build.controls.values():
        verify_file_stable(build.directory_descriptor, record)
    build.managed.verify()


def file_identical(first: FileRecord, second: FileRecord) -> bool:
    return first.size == second.size and first.sha256 == second.sha256


def package_identical(first: PackageRecord, second: PackageRecord) -> bool:
    return first.size == second.size and first.sha256 == second.sha256


def output_identical(first: OutputRecord, second: OutputRecord) -> bool:
    return first.size == second.size and first.sha256 == second.sha256


def build_sort_key(build: OpenBuild) -> str:
    rows = {
        "artifacts": [
            (name, build.artifacts[name].size, build.artifacts[name].sha256)
            for name in sorted(build.artifacts)
        ],
        "controls": [
            (name, build.controls[name].size, build.controls[name].sha256)
            for name in sorted(build.controls)
        ],
    }
    encoded = json.dumps(rows, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(encoded.encode("ascii")).hexdigest()


def manifest_projection(build: OpenBuild) -> tuple[tuple[str, str], ...]:
    excluded = {
        "Signing certificate SHA256",
        "Signing certificate fingerprint",
        "Signing certificate serial",
    }
    for index in range(1, len(build.outputs) + 1):
        excluded.update((f"Output {index} size", f"Output {index} SHA256"))
    for index in range(1, len(build.packages) + 1):
        excluded.update((f"Deb {index} size", f"Deb {index} SHA256"))
    return tuple((key, value) for key, value in build.manifest.items() if key not in excluded)


def envelope_projection(build: OpenBuild) -> tuple[tuple[str, str], ...]:
    excluded = {"Input 4 size", "Input 4 SHA256"}
    return tuple((key, value) for key, value in build.envelope.items() if key not in excluded)


def matched_managed_projection(
    build: OpenBuild,
) -> tuple[tuple[str, str, int, str], ...]:
    subject_paths = {
        "artifacts/sp11-kernel-build-manifest.txt",
        "artifacts/sp11-kernel-build-inputs.txt",
        *(f"artifacts/{package.filename}" for package in build.packages.values()),
    }
    rows: list[tuple[str, str, int, str]] = []
    for relative in sorted(build.managed.entries):
        if relative in subject_paths:
            continue
        entry = build.managed.entries[relative]
        if entry.kind == "directory":
            rows.append((relative, "directory", 0, "-"))
            continue
        require(entry.sha256 is not None, "matched retained file identity is incomplete")
        rows.append((relative, "file", entry.metadata[2], entry.sha256))
    return tuple(rows)


def pair_structure(first: OpenBuild, second: OpenBuild) -> None:
    require(manifest_projection(first) == manifest_projection(second), "build manifests do not form a matched pair")
    require(envelope_projection(first) == envelope_projection(second), "build envelopes do not form a matched pair")
    require(set(first.packages) == set(second.packages), "optional kernel Deb roles are asymmetric")
    for role in first.packages:
        left = first.packages[role]
        right = second.packages[role]
        require(
            (left.role, left.filename, left.package, left.version, left.architecture)
            == (right.role, right.filename, right.package, right.version, right.architecture),
            "paired kernel Deb identities differ outside raw bytes",
        )
    require(
        matched_managed_projection(first) == matched_managed_projection(second),
        "matched retained-input trees differ outside raw subjects",
    )
    require(set(first.outputs) == set(second.outputs), "manifest output roles are asymmetric")
    for role in first.outputs:
        left = first.outputs[role]
        right = second.outputs[role]
        require((left.role, left.path) == (right.role, right.path), "manifest output paths differ")

    immutable_files = (
        (first.controls["build-arguments"], second.controls["build-arguments"]),
        (first.controls["entrypoint"], second.controls["entrypoint"]),
        (first.controls["oci-index"], second.controls["oci-index"]),
        (first.controls["pre-inventory"], second.controls["pre-inventory"]),
        (first.controls["post-inventory"], second.controls["post-inventory"]),
        (
            first.artifacts["sp11-kernel-apt-provenance.txt"],
            second.artifacts["sp11-kernel-apt-provenance.txt"],
        ),
        (first.artifacts["sp11-kernel-debs.txt"], second.artifacts["sp11-kernel-debs.txt"]),
        (
            first.artifacts[first.local_build_deps.filename],
            second.artifacts[second.local_build_deps.filename],
        ),
    )
    require(all(file_identical(left, right) for left, right in immutable_files), "immutable pair inputs differ")
    require(
        first.local_build_deps == second.local_build_deps,
        "local build-deps control identities differ",
    )

    certificate_role = "module-signing-certificate"
    if output_identical(first.outputs[certificate_role], second.outputs[certificate_role]):
        for key in (
            "Signing certificate SHA256",
            "Signing certificate fingerprint",
            "Signing certificate serial",
        ):
            require(field(first.manifest, key) == field(second.manifest, key), "certificate metadata differs")

    subjects_identical = all(
        package_identical(first.packages[role], second.packages[role])
        for role in first.packages
    ) and all(
        output_identical(first.outputs[role], second.outputs[role])
        for role in first.outputs
    )
    if subjects_identical:
        require(
            file_identical(
                first.artifacts["sp11-kernel-build-manifest.txt"],
                second.artifacts["sp11-kernel-build-manifest.txt"],
            ),
            "equal raw subjects have non-identical manifests",
        )
    if file_identical(
        first.artifacts["sp11-kernel-build-manifest.txt"],
        second.artifacts["sp11-kernel-build-manifest.txt"],
    ):
        require(
            file_identical(
                first.artifacts["sp11-kernel-build-inputs.txt"],
                second.artifacts["sp11-kernel-build-inputs.txt"],
            ),
            "equal manifests have non-identical build-input envelopes",
        )


def compare_pair(
    baseline_path: Path,
    support_repo: Path,
    support_head: str,
    build_a: Path,
    build_b: Path,
) -> Comparison:
    require_child_wait_authority()
    support: SupportBinding | None = None
    opened_a: OpenBuild | None = None
    opened_b: OpenBuild | None = None
    support_root: tuple[Path, int, os.stat_result] | None = None
    build_a_root: tuple[Path, int, os.stat_result] | None = None
    build_b_root: tuple[Path, int, os.stat_result] | None = None
    scratch_parent: ScratchParent | None = None
    try:
        support_root = canonical_directory(support_repo, "support repository")
        build_a_root = canonical_directory(
            build_a, "build A directory", require_lexical_absolute=True
        )
        build_b_root = canonical_directory(
            build_b, "build B directory", require_lexical_absolute=True
        )
        require(
            inode_identity(build_a_root[2]) != inode_identity(build_b_root[2]),
            "matched-pair builds must be distinct directories",
        )
        scratch_parent = open_scratch_parent(
            (support_root, build_a_root, build_b_root)
        )

        transferred_support = support_root
        support_root = None
        support = open_support_binding(
            transferred_support,
            support_head,
            baseline_path,
            scratch_parent,
        )
        deb = load_deb_reader(support)
        transferred_a = build_a_root
        build_a_root = None
        opened_a = open_build(
            transferred_a,
            support,
            deb,
            scratch_parent,
        )
        transferred_b = build_b_root
        build_b_root = None
        opened_b = open_build(
            transferred_b,
            support,
            deb,
            scratch_parent,
            opened_a.managed.file_identities,
        )
        require(
            opened_a.managed.file_identities.isdisjoint(
                opened_b.managed.file_identities
            ),
            "matched-pair builds share a managed retained inode",
        )
        first, second = sorted((opened_a, opened_b), key=build_sort_key)
        pair_structure(first, second)
        differing_packages = sum(
            not package_identical(first.packages[role], second.packages[role])
            for role in first.packages
        )
        differing_outputs = sum(
            not output_identical(first.outputs[role], second.outputs[role])
            for role in first.outputs
        )
        result = Comparison(
            first,
            second,
            support,
            support.baseline,
            support_head,
            differing_packages == 0,
            differing_outputs == 0,
            differing_packages,
            differing_outputs,
        )
        verify_build_stable(opened_a)
        verify_build_stable(opened_b)
        verify_support_stable(support)
        return result
    except Exception:
        if opened_b is not None:
            try:
                opened_b.close()
            except Exception:
                pass
        if opened_a is not None:
            try:
                opened_a.close()
            except Exception:
                pass
        if support is not None:
            try:
                support.close()
            except Exception:
                pass
        raise
    finally:
        if scratch_parent is not None:
            scratch_parent.close()
        for root in (support_root, build_a_root, build_b_root):
            if root is not None:
                try:
                    os.close(root[1])
                except OSError:
                    pass


def close_comparison(result: Comparison) -> None:
    builds = (result.first, result.second)
    cleanup_error: BaseException | None = None
    for build in builds:
        try:
            build.cleanup_private()
        except BaseException as exc:
            if cleanup_error is None:
                cleanup_error = exc
    if cleanup_error is None:
        try:
            for build in builds:
                verify_build_stable(build)
        except BaseException as exc:
            cleanup_error = exc
    try:
        result.support.snapshot_private.cleanup()
    except BaseException as exc:
        if cleanup_error is None:
            cleanup_error = exc
    if cleanup_error is None:
        try:
            verify_support_stable(result.support)
        except BaseException as exc:
            cleanup_error = exc
    for build in builds:
        build.close_descriptors()
    result.support.close_descriptors()
    if cleanup_error is not None:
        raise ValidationError("matched-pair private cleanup or final verification failed") from cleanup_error


def boolean(value: bool) -> str:
    return "true" if value else "false"


def file_identity_lines(
    label: str,
    first: FileRecord,
    second: FileRecord,
    *,
    identical_label: str = "identical",
) -> tuple[str, ...]:
    return (
        f"{label} A size: {first.size}",
        f"{label} A SHA256: {first.sha256}",
        f"{label} B size: {second.size}",
        f"{label} B SHA256: {second.sha256}",
        f"{label} {identical_label}: {boolean(file_identical(first, second))}",
    )


def managed_rows_identity(
    rows: tuple[tuple[str, str, int, str], ...]
) -> tuple[int, int, int, str]:
    encoded_rows: list[list[str | int]] = []
    file_count = 0
    total_size = 0
    for relative, kind, size, digest_value in rows:
        try:
            relative.encode("utf-8", "strict")
        except UnicodeEncodeError as exc:
            raise ValidationError("managed retained path is not canonical UTF-8") from exc
        require(kind in ("directory", "file"), "managed retained entry type is invalid")
        if kind == "file":
            file_count += 1
            total_size += size
        encoded_rows.append([relative, kind, size, digest_value])
    preimage = json.dumps(
        encoded_rows, ensure_ascii=True, separators=(",", ":")
    ).encode("ascii")
    return len(encoded_rows), file_count, total_size, hashlib.sha256(preimage).hexdigest()


def managed_tree_identity(managed: ManagedTree) -> tuple[int, int, int, str]:
    rows: list[tuple[str, str, int, str]] = []
    for relative in sorted(managed.entries):
        entry = managed.entries[relative]
        if entry.kind == "directory":
            rows.append((relative, "directory", 0, "-"))
            continue
        require(entry.sha256 is not None, "managed retained file identity is incomplete")
        rows.append((relative, "file", entry.metadata[2], entry.sha256))
    return managed_rows_identity(tuple(rows))


def matched_managed_tree_identity(build: OpenBuild) -> tuple[int, int, int, str]:
    return managed_rows_identity(matched_managed_projection(build))


def render_report(result: Comparison) -> str:
    first = result.first
    second = result.second
    baseline = result.baseline
    manifest = first.manifest
    patch_count = reviewed_patch_count(manifest)
    first_managed_identity = managed_tree_identity(first.managed)
    second_managed_identity = managed_tree_identity(second.managed)
    first_matched_managed_identity = matched_managed_tree_identity(first)
    second_matched_managed_identity = matched_managed_tree_identity(second)
    lines = [
        f"Kernel raw matched-pair schema: {SCHEMA}",
        f"Comparison policy: {POLICY}",
        f"Support HEAD: {result.support_head}",
        f"Kernel baseline ID: {baseline['SP11_KERNEL_BASELINE_ID']}",
        f"Source URL: {baseline['SP11_KERNEL_UPSTREAM_URL']}",
        f"Source ref: {baseline['SP11_KERNEL_UPSTREAM_REF']}",
        f"Source commit: {baseline['SP11_KERNEL_UPSTREAM_COMMIT']}",
        f"Source date epoch: {baseline['SP11_KERNEL_SOURCE_DATE_EPOCH']}",
        f"Kbuild build user: {baseline['SP11_KERNEL_KBUILD_BUILD_USER']}",
        f"Kbuild build host: {baseline['SP11_KERNEL_KBUILD_BUILD_HOST']}",
        f"Kbuild build timestamp: {baseline['SP11_KERNEL_KBUILD_BUILD_TIMESTAMP']}",
        f"OCI index image: {baseline['SP11_KERNEL_DOCKER_IMAGE']}",
        f"OCI index digest: {baseline['SP11_KERNEL_DOCKER_IMAGE'].rsplit('@', 1)[1]}",
        f"OCI platform: {baseline['SP11_KERNEL_DOCKER_PLATFORM']}",
        f"OCI platform manifest: {baseline['SP11_KERNEL_DOCKER_PLATFORM_MANIFEST']}",
        f"APT snapshot ID: {baseline['SP11_APT_SNAPSHOT_ID']}",
        f"APT snapshot URI: {baseline['SP11_APT_SNAPSHOT_URI']}",
        f"Kernel baseline size: {result.support.baseline_record.size}",
        f"Kernel baseline SHA256: {result.support.baseline_record.sha256}",
        f"Patch count: {patch_count}",
    ]
    for index in range(1, patch_count + 1):
        lines.extend(
            (
                f"Patch {index} path: {field(manifest, f'Patch {index} path')}",
                f"Patch {index} SHA256: {field(manifest, f'Patch {index} SHA256')}",
                f"Patch {index} disposition: {field(manifest, f'Patch {index} disposition')}",
            )
        )
    lines.extend(
        (
            f"Patched diff format: {field(manifest, 'Patched diff format')}",
            f"Patched diff Git version: {field(manifest, 'Patched diff Git version')}",
            f"Patched diff SHA256: {field(manifest, 'Patched diff SHA256')}",
            f"Patched tree ID: {field(manifest, 'Patched tree ID')}",
            f"Artifact file count A: {len(first.artifacts)}",
            f"Artifact file count B: {len(second.artifacts)}",
            "Managed retained-input aggregate schema: sp11-managed-tree-sha256-v1",
            "Managed retained-input aggregate preimage: ASCII JSON "
            "ensure_ascii=true array of [relative-path,type,size,SHA256] rows sorted "
            "by relative-path; no whitespace; comma and colon separators; file size is "
            "a decimal JSON integer and SHA256 is lowercase hex; directory size 0 and "
            "SHA256 '-'",
            f"Managed retained-input A entry count: {first_managed_identity[0]}",
            f"Managed retained-input A file count: {first_managed_identity[1]}",
            f"Managed retained-input A total file size: {first_managed_identity[2]}",
            f"Managed retained-input A SHA256: {first_managed_identity[3]}",
            f"Managed retained-input B entry count: {second_managed_identity[0]}",
            f"Managed retained-input B file count: {second_managed_identity[1]}",
            f"Managed retained-input B total file size: {second_managed_identity[2]}",
            f"Managed retained-input B SHA256: {second_managed_identity[3]}",
            "Managed retained-input aggregate identical: "
            + boolean(first_managed_identity == second_managed_identity),
            "Matched retained-input aggregate schema: sp11-matched-managed-tree-sha256-v1",
            "Matched retained-input aggregate scope: complete managed tree excluding "
            "manifest-declared kernel Deb files, the build manifest, and the build-inputs "
            "envelope",
            f"Matched retained-input A entry count: {first_matched_managed_identity[0]}",
            f"Matched retained-input A file count: {first_matched_managed_identity[1]}",
            f"Matched retained-input A total file size: {first_matched_managed_identity[2]}",
            f"Matched retained-input A SHA256: {first_matched_managed_identity[3]}",
            f"Matched retained-input B entry count: {second_matched_managed_identity[0]}",
            f"Matched retained-input B file count: {second_matched_managed_identity[1]}",
            f"Matched retained-input B total file size: {second_matched_managed_identity[2]}",
            f"Matched retained-input B SHA256: {second_matched_managed_identity[3]}",
            "Matched retained-input aggregate identical: "
            + boolean(first_matched_managed_identity == second_matched_managed_identity),
            f"Kernel package count: {len(first.packages)}",
        )
    )
    for index, role in enumerate((role for role in ROLE_ORDER if role in first.packages), 1):
        left = first.packages[role]
        right = second.packages[role]
        lines.extend(
            (
                f"Package {index} role: {role}",
                f"Package {index} A filename: {left.filename}",
                f"Package {index} A package: {left.package}",
                f"Package {index} A version: {left.version}",
                f"Package {index} A architecture: {left.architecture}",
                f"Package {index} A size: {left.size}",
                f"Package {index} A SHA256: {left.sha256}",
                f"Package {index} B filename: {right.filename}",
                f"Package {index} B package: {right.package}",
                f"Package {index} B version: {right.version}",
                f"Package {index} B architecture: {right.architecture}",
                f"Package {index} B size: {right.size}",
                f"Package {index} B SHA256: {right.sha256}",
                f"Package {index} raw identical: {boolean(package_identical(left, right))}",
            )
        )
    lines.extend(
        file_identity_lines(
            "Build manifest",
            first.artifacts["sp11-kernel-build-manifest.txt"],
            second.artifacts["sp11-kernel-build-manifest.txt"],
            identical_label="raw identical",
        )
    )
    lines.extend(
        file_identity_lines(
            "Build-inputs envelope",
            first.artifacts["sp11-kernel-build-inputs.txt"],
            second.artifacts["sp11-kernel-build-inputs.txt"],
            identical_label="raw identical",
        )
    )
    lines.extend(
        file_identity_lines(
            "Docker build arguments",
            first.controls["build-arguments"],
            second.controls["build-arguments"],
        )
    )
    lines.extend(
        file_identity_lines(
            "Docker entrypoint",
            first.controls["entrypoint"],
            second.controls["entrypoint"],
        )
    )
    lines.extend(
        file_identity_lines(
            "OCI index",
            first.controls["oci-index"],
            second.controls["oci-index"],
            identical_label="raw identical",
        )
    )
    lines.extend(
        file_identity_lines(
            "APT sidecar",
            first.artifacts["sp11-kernel-apt-provenance.txt"],
            second.artifacts["sp11-kernel-apt-provenance.txt"],
            identical_label="raw identical",
        )
    )
    lines.extend(
        file_identity_lines(
            "Pre-install inventory",
            first.controls["pre-inventory"],
            second.controls["pre-inventory"],
        )
    )
    lines.extend(
        file_identity_lines(
            "Post-install inventory",
            first.controls["post-inventory"],
            second.controls["post-inventory"],
        )
    )
    lines.append(f"Local build-deps filename: {first.local_build_deps.filename}")
    lines.extend(
        file_identity_lines(
            "Local build-deps",
            first.artifacts[first.local_build_deps.filename],
            second.artifacts[second.local_build_deps.filename],
            identical_label="raw identical",
        )
    )
    lines.extend(
        file_identity_lines(
            "Kernel Deb list",
            first.artifacts["sp11-kernel-debs.txt"],
            second.artifacts["sp11-kernel-debs.txt"],
            identical_label="raw identical",
        )
    )
    lines.append(f"Manifest output count: {len(first.outputs)}")
    for index, role in enumerate(OUTPUT_ORDER, 1):
        left = first.outputs[role]
        right = second.outputs[role]
        lines.extend(
            (
                f"Manifest output {index} role: {role}",
                f"Manifest output {index} A size: {left.size}",
                f"Manifest output {index} A SHA256: {left.sha256}",
                f"Manifest output {index} B size: {right.size}",
                f"Manifest output {index} B SHA256: {right.sha256}",
                f"Manifest output {index} identity identical: {boolean(output_identical(left, right))}",
            )
        )
    lines.extend(
        (
            "Normalization applied: false",
            f"Raw differing package count: {result.differing_packages}",
            f"Raw differing manifest output count: {result.differing_outputs}",
            "Matched immutable inputs: true",
            f"Raw package byte reproducibility: {boolean(result.raw_package_match)}",
            f"Manifest output identity reproducibility: {boolean(result.output_identity_match)}",
            f"P0.4b raw evidence: {'pass' if result.passed else 'fail'}",
            "Publication authorized: false",
            "Comparison completed: true",
        )
    )
    return "\n".join(lines) + "\n"


def render_verified_report(result: Comparison) -> str:
    """Render from captured identities, then close the report-time race window."""

    report = render_report(result)
    verify_build_stable(result.first)
    verify_build_stable(result.second)
    verify_support_stable(result.support)
    return report


class SanitizedArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        del message
        raise ValidationError("command line is invalid")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = SanitizedArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument(
        "--version",
        action="version",
        version=f"{SCHEMA} ({POLICY})",
    )
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--support-repo", required=True, type=Path)
    parser.add_argument("--support-head", required=True)
    parser.add_argument("--build-a", required=True, type=Path)
    parser.add_argument("--build-b", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    result: Comparison | None = None
    try:
        establish_child_wait_authority()
        require(
            sys.flags.isolated == 1,
            "raw matched-pair validation requires isolated Python",
        )
        args = parse_args(argv)
        result = compare_pair(
            args.baseline,
            args.support_repo,
            args.support_head,
            args.build_a,
            args.build_b,
        )
        report = render_verified_report(result)
        passed = result.passed
        close_comparison(result)
        result = None
        sys.stdout.write(report)
        return 0 if passed else 1
    except Exception:
        print("error: raw matched-pair input validation failed", file=sys.stderr)
        return 2
    finally:
        if result is not None:
            try:
                close_comparison(result)
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
