#!/usr/bin/env python3
"""Generate a deterministic patched-source archive candidate from a bound tree."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import resource
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from contextlib import contextmanager
from pathlib import Path


MAX_CONTROL_BYTES = 512 * 1024
MAX_DIFF_BYTES = 2 * 1024 * 1024 * 1024
MAX_COMMAND_OUTPUT_BYTES = 64 * 1024
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_EXPANDED_BYTES = 8 * 1024 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 250_000
MAX_ZERO_TAIL_BYTES = 1024 * 1024
MAX_TAR_BYTES = (
    MAX_EXPANDED_BYTES + MAX_ARCHIVE_MEMBERS * 1024 + MAX_ZERO_TAIL_BYTES
)
MAX_SCRATCH_DEPTH = 16
MAX_SCRATCH_ENTRIES = 512
MAX_SCRATCH_BYTES = (
    MAX_TAR_BYTES + 3 * MAX_ARCHIVE_BYTES + 2 * MAX_DIFF_BYTES + 64 * 1024 * 1024
)
READ_CHUNK_BYTES = 1024 * 1024
BASELINE_ASSIGNMENT = re.compile(r'(SP11_[A-Z0-9_]+)="([^"\\]*)"\Z')
OBJECT_ID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SAFE_ARCHIVE_NAME = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9._+-]{0,199}-patched-source[A-Za-z0-9._+-]{0,80}\.tar\.xz\Z"
)
XZ_ARGUMENTS = (
    "--format=xz",
    "--check=crc64",
    "--threads=1",
    "-6",
    "--stdout",
)
CONTRACT_KEYS = (
    "SP11_KERNEL_SOURCE_ARCHIVE_CONTRACT",
    "SP11_KERNEL_SOURCE_ARCHIVE_PYTHON_PATH",
    "SP11_KERNEL_SOURCE_ARCHIVE_VALIDATOR_SHA256",
    "SP11_KERNEL_SOURCE_ARCHIVE_GIT_PATH",
    "SP11_KERNEL_SOURCE_ARCHIVE_GIT_SHA256",
    "SP11_KERNEL_SOURCE_ARCHIVE_GIT_VERSION",
    "SP11_KERNEL_SOURCE_ARCHIVE_XZ_PATH",
    "SP11_KERNEL_SOURCE_ARCHIVE_XZ_SHA256",
    "SP11_KERNEL_SOURCE_ARCHIVE_XZ_VERSION",
    "SP11_KERNEL_SOURCE_ARCHIVE_XZ_LIBRARY_PATH",
    "SP11_KERNEL_SOURCE_ARCHIVE_XZ_LIBRARY_SHA256",
)
ACTIVE_PASS_FDS: tuple[int, ...] = ()


class GenerationError(Exception):
    """An expected, fail-closed generation error."""


@dataclass(frozen=True)
class FileSnapshot:
    """Stable identity for a no-follow control-file read."""

    path: Path
    identity: tuple[int, int, int, int, int]
    sha256: str
    data: bytes


@dataclass(frozen=True)
class ToolSnapshot:
    """Exact executable identity from the committed toolchain contract."""

    path: Path
    identity: tuple[int, int]
    size: int
    sha256: str


@dataclass(frozen=True)
class LibrarySnapshot:
    """Exact compression-library identity from the committed contract."""

    path: Path
    identity: tuple[int, int]
    size: int
    sha256: str


@dataclass(frozen=True)
class OwnedFileSnapshot:
    """Validated state for one held creation-owned scratch file."""

    identity: tuple[int, int]
    state: tuple[int, int, int, int, int]
    size: int
    sha256: str


@dataclass
class PinnedDirectory:
    """A real directory held open across all output operations."""

    path: Path
    descriptor: int
    identity: tuple[int, int]
    label: str
    defer_close: bool = False

    def verify(self) -> None:
        try:
            descriptor_metadata = os.fstat(self.descriptor)
            path_metadata = self.path.lstat()
        except OSError as exc:
            fail(f"{self.label} changed or became inaccessible: {exc}")
        if (
            not stat.S_ISDIR(descriptor_metadata.st_mode)
            or not stat.S_ISDIR(path_metadata.st_mode)
            or stat.S_ISLNK(path_metadata.st_mode)
            or (descriptor_metadata.st_dev, descriptor_metadata.st_ino) != self.identity
            or (path_metadata.st_dev, path_metadata.st_ino) != self.identity
        ):
            fail(f"{self.label} identity changed during source-archive generation")

    def close(self) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


@dataclass
class PinnedScratch:
    """A private scratch inode addressed only through held descriptors."""

    parent: PinnedDirectory
    name: str
    descriptor: int
    identity: tuple[int, int]
    path: Path
    owned: dict[str, OwnedScratchEntry]
    retained_snapshot: dict[str, tuple[object, ...]] | None = None

    def verify(self) -> None:
        try:
            descriptor_metadata = os.fstat(self.descriptor)
            entry_metadata = os.stat(
                self.name,
                dir_fd=self.parent.descriptor,
                follow_symlinks=False,
            )
        except OSError as exc:
            fail(f"private scratch changed or became inaccessible: {exc}")
        if (
            not stat.S_ISDIR(descriptor_metadata.st_mode)
            or not stat.S_ISDIR(entry_metadata.st_mode)
            or (descriptor_metadata.st_dev, descriptor_metadata.st_ino) != self.identity
            or (entry_metadata.st_dev, entry_metadata.st_ino) != self.identity
        ):
            fail("private scratch identity changed during source-archive generation")

    def close(self) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


@dataclass
class CleanupBudget:
    """Strict aggregate limits for hostile scratch cleanup preflight."""

    entries: int = 0
    regular_bytes: int = 0


@dataclass
class OwnedScratchEntry:
    """A creation-owned scratch inode kept open until it is scrubbed."""

    kind: str
    identity: tuple[int, int]
    descriptor: int


@dataclass
class InstalledOutput:
    """A committed output inode held until the final success boundary."""

    name: str
    descriptor: int
    identity: tuple[int, int]
    state: tuple[int, int, int, int, int]
    size: int
    sha256: str


@dataclass
class FinalizationState:
    """Held authorities needed after scratch cleanup and cwd restoration."""

    pause_before_final_check: bool = False
    output_parent: PinnedDirectory | None = None
    scratch_parent: PinnedDirectory | None = None
    scratch: PinnedScratch | None = None
    installed: InstalledOutput | None = None


def fail(message: str) -> None:
    raise GenerationError(message)


def require_sigint_mask_support() -> None:
    """Fail before resource creation if POSIX signal-mask ownership is unavailable."""

    if not all(
        hasattr(signal, attribute)
        for attribute in ("pthread_sigmask", "SIG_BLOCK", "SIG_SETMASK", "SIGINT")
    ):
        fail("platform cannot protect source-archive resource ownership from SIGINT")
    try:
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    except (OSError, ValueError) as exc:
        fail(f"platform cannot protect source-archive resource ownership from SIGINT: {exc}")


@contextmanager
def blocked_sigint():
    """Defer SIGINT until a newly created resource has a visible cleanup owner."""

    try:
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT})
    except (OSError, ValueError) as exc:
        fail(f"could not block SIGINT for resource ownership transfer: {exc}")
    try:
        yield previous_mask
    finally:
        # A pending SIGINT may raise KeyboardInterrupt here.  Every caller must
        # record the resource owner inside the with body before this restoration.
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def close_finalization_handles(state: FinalizationState, *, scrub_output: bool) -> None:
    if scrub_output:
        if state.installed is not None:
            scrub_and_close_installed_output(state.installed)
        if state.scratch is not None:
            try:
                state.scratch.close()
            except OSError:
                pass
        for pinned in (state.scratch_parent, state.output_parent):
            if pinned is not None:
                try:
                    pinned.close()
                except OSError:
                    pass
        return

    # A successful return is allowed only after every retained authority has
    # actually closed.  Keep the output FD until last so an earlier close error
    # can still take the failure path and scrub the exact created inode.
    if state.scratch is not None:
        state.scratch.close()
    for pinned in (state.scratch_parent, state.output_parent):
        if pinned is not None:
            pinned.close()
    if state.installed is not None and state.installed.descriptor >= 0:
        os.close(state.installed.descriptor)
        state.installed.descriptor = -1


def canonical_existing_directory(path: Path, label: str) -> Path:
    candidate = Path(os.path.abspath(path))
    try:
        metadata = candidate.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a real, non-symlinked directory")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        fail(f"could not resolve {label}: {exc}")
    try:
        resolved_metadata = resolved.lstat()
    except OSError as exc:
        fail(f"could not re-inspect {label}: {exc}")
    if not stat.S_ISDIR(resolved_metadata.st_mode):
        fail(f"{label} must resolve to a directory")
    return resolved


def canonical_unaliased_directory(
    path: Path, label: str
) -> tuple[Path, tuple[int, int]]:
    if not path.is_absolute():
        fail(f"{label} must be an absolute path")
    candidate = Path(os.path.abspath(path))
    resolved = canonical_existing_directory(candidate, label)
    if resolved != candidate:
        fail(f"{label} must not contain a symlinked ancestor")
    metadata = resolved.lstat()
    return resolved, (metadata.st_dev, metadata.st_ino)


def open_pinned_directory(
    path: Path, expected_identity: tuple[int, int], label: str
) -> PinnedDirectory:
    if not path.is_absolute() or not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
        fail(f"{label} cannot be pinned safely on this platform")
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open("/", flags)
        for component in path.parts[1:]:
            if not component or component in (".", "..") or "/" in component:
                fail(f"{label} contains a noncanonical path component")
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        opened = os.fstat(descriptor)
        before = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        if descriptor >= 0:
            os.close(descriptor)
        fail(f"could not pin {label}: {exc}")
    identity = (opened.st_dev, opened.st_ino)
    if (
        not stat.S_ISDIR(before.st_mode)
        or not stat.S_ISDIR(opened.st_mode)
        or (before.st_dev, before.st_ino) != identity
        or identity != expected_identity
    ):
        os.close(descriptor)
        fail(f"{label} changed before it could be pinned")
    pinned = PinnedDirectory(path, descriptor, identity, label)
    pinned.verify()
    return pinned


@contextmanager
def pinned_directory(
    path: Path, expected_identity: tuple[int, int], label: str
):
    pinned = open_pinned_directory(path, expected_identity, label)
    completed = False
    try:
        yield pinned
        completed = True
    finally:
        if not completed or not pinned.defer_close:
            pinned.close()


@contextmanager
def private_scratch(parent: PinnedDirectory):
    global ACTIVE_PASS_FDS

    name = f".sp11-source-archive.{secrets.token_hex(16)}"
    scratch_handle: PinnedScratch | None = None
    previous_pass_fds = ACTIVE_PASS_FDS
    body_error: tuple[type[BaseException], BaseException, object] | None = None
    cleanup_error: BaseException | None = None
    parent.verify()
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent.descriptor)
        flags = (
            os.O_RDONLY
            | os.O_CLOEXEC
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
        )
        descriptor = os.open(name, flags, dir_fd=parent.descriptor)
        descriptor_metadata = os.fstat(descriptor)
        created_identity = (descriptor_metadata.st_dev, descriptor_metadata.st_ino)
        scratch_handle = PinnedScratch(
            parent, name, descriptor, created_identity, Path("."), {}
        )
        scratch_handle.verify()
        parent.verify()
        ACTIVE_PASS_FDS = (*previous_pass_fds, descriptor)
        try:
            yield scratch_handle
        except BaseException:
            body_error = sys.exc_info()  # type: ignore[assignment]
    finally:
        ACTIVE_PASS_FDS = previous_pass_fds
        if scratch_handle is not None:
            try:
                cleanup_private_scratch(scratch_handle)
            except BaseException as exc:
                cleanup_error = exc
            if body_error is not None or cleanup_error is not None:
                scratch_handle.close()
    if body_error is not None:
        _kind, error, traceback = body_error
        raise error.with_traceback(traceback)  # type: ignore[arg-type]
    if cleanup_error is not None:
        raise cleanup_error


@contextmanager
def entered_private_scratch(scratch: PinnedScratch):
    """Enter the held scratch inode portably, restoring cwd by descriptor."""

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    saved = os.open(".", flags)
    try:
        scratch.verify()
        os.fchdir(scratch.descriptor)
        yield
    finally:
        os.fchdir(saved)
        os.close(saved)


def scratch_components(relative: str) -> tuple[str, ...]:
    path = Path(relative)
    parts = path.parts
    if (
        path.is_absolute()
        or not parts
        or any(not part or part in (".", "..") or "/" in part for part in parts)
    ):
        fail("private scratch member path is not canonical")
    return parts


def open_owned_parent(scratch: PinnedScratch, relative: str) -> tuple[int, str]:
    parts = scratch_components(relative)
    if len(parts) == 1:
        return os.dup(scratch.descriptor), parts[0]
    expected = scratch.owned.get("/".join(parts[:-1]))
    if expected is None or expected.kind != "directory":
        fail("private scratch parent is not creation-owned")
    metadata = os.fstat(expected.descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or (metadata.st_dev, metadata.st_ino) != expected.identity
    ):
        fail("private scratch parent identity changed")
    return os.dup(expected.descriptor), parts[-1]


def register_private_entry(
    scratch: PinnedScratch, relative: str, descriptor: int, kind: str
) -> None:
    metadata = os.fstat(descriptor)
    expected_type = stat.S_ISDIR if kind == "directory" else stat.S_ISREG
    if (
        not expected_type(metadata.st_mode)
        or relative in scratch.owned
        or len(scratch.owned) >= MAX_SCRATCH_ENTRIES
    ):
        fail("private scratch creation produced an unsafe or duplicate entry")
    scratch.owned[relative] = OwnedScratchEntry(
        kind, (metadata.st_dev, metadata.st_ino), descriptor
    )


def create_private_directory(scratch: PinnedScratch, relative: str) -> None:
    parent, name = open_owned_parent(scratch, relative)
    child = -1
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent)
        child = os.open(
            name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent,
        )
        register_private_entry(scratch, relative, child, "directory")
        child = -1
    finally:
        if child >= 0:
            os.close(child)
        os.close(parent)


def create_private_file(scratch: PinnedScratch, relative: str) -> int:
    parent, name = open_owned_parent(scratch, relative)
    descriptor = -1
    try:
        descriptor = os.open(
            name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent,
        )
        register_private_entry(scratch, relative, descriptor, "file")
        held_descriptor = descriptor
        descriptor = -1
        return os.dup(held_descriptor)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


def write_private_file(scratch: PinnedScratch, relative: str, data: bytes) -> None:
    descriptor = create_private_file(scratch, relative)
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def open_private_file(scratch: PinnedScratch, relative: str) -> int:
    expected = scratch.owned.get(relative)
    if expected is None or expected.kind != "file":
        fail("private scratch file is not creation-owned")
    opened = os.fstat(expected.descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or (opened.st_dev, opened.st_ino) != expected.identity
    ):
        fail("private scratch file identity changed")
    duplicate = os.dup(expected.descriptor)
    os.lseek(duplicate, 0, os.SEEK_SET)
    return duplicate


def snapshot_owned_file(
    scratch: PinnedScratch, relative: str, label: str, maximum: int
) -> OwnedFileSnapshot:
    entry = scratch.owned.get(relative)
    if entry is None or entry.kind != "file":
        fail(f"{label} is not a creation-owned scratch file")
    before = os.fstat(entry.descriptor)
    identity = (before.st_dev, before.st_ino)
    state = (
        stat.S_IMODE(before.st_mode),
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
        before.st_nlink,
    )
    if (
        not stat.S_ISREG(before.st_mode)
        or identity != entry.identity
        or before.st_size <= 0
        or before.st_size > maximum
    ):
        fail(f"{label} has an unsafe type, identity, or size")
    size, digest = hash_open_file(entry.descriptor, maximum)
    after = os.fstat(entry.descriptor)
    if (
        (after.st_dev, after.st_ino) != identity
        or (
            stat.S_IMODE(after.st_mode),
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_nlink,
        )
        != state
        or size != before.st_size
    ):
        fail(f"{label} changed while it was validated")
    return OwnedFileSnapshot(identity, state, size, digest)


def hash_open_file(descriptor: int, maximum: int) -> tuple[int, str]:
    digest = hashlib.sha256()
    copied = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, READ_CHUNK_BYTES)
        if not chunk:
            break
        copied += len(chunk)
        if copied > maximum:
            fail("open file exceeds its bounded hashing limit")
        digest.update(chunk)
    return copied, digest.hexdigest()


def bounded_directory_names(descriptor: int, budget: CleanupBudget) -> list[str]:
    names: list[str] = []
    try:
        with os.scandir(descriptor) as entries:
            for entry in entries:
                budget.entries += 1
                if budget.entries > MAX_SCRATCH_ENTRIES:
                    fail("private scratch exceeds its cleanup member limit")
                names.append(entry.name)
    except OSError as exc:
        fail(f"could not enumerate private scratch safely: {exc}")
    return sorted(names)


def snapshot_private_tree(
    descriptor: int,
    prefix: str = "",
    *,
    depth: int = 0,
    budget: CleanupBudget | None = None,
) -> dict[str, tuple[object, ...]]:
    if depth > MAX_SCRATCH_DEPTH:
        fail("private scratch exceeds its cleanup depth limit")
    if budget is None:
        budget = CleanupBudget()
    snapshot: dict[str, tuple[object, ...]] = {}
    names = bounded_directory_names(descriptor, budget)
    for name in names:
        if not name or "/" in name or name in (".", ".."):
            fail("private scratch contains an unsafe member name")
        relative = f"{prefix}/{name}" if prefix else name
        metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        base_identity: tuple[object, ...] = (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IMODE(metadata.st_mode),
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            metadata.st_nlink,
        )
        if stat.S_ISDIR(metadata.st_mode):
            child = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                    fail("private scratch directory changed during cleanup preflight")
                snapshot[relative] = ("directory", *base_identity)
                snapshot.update(
                    snapshot_private_tree(
                        child, relative, depth=depth + 1, budget=budget
                    )
                )
            finally:
                os.close(child)
        elif stat.S_ISREG(metadata.st_mode):
            budget.regular_bytes += metadata.st_size
            if (
                metadata.st_size > MAX_TAR_BYTES
                or budget.regular_bytes > MAX_SCRATCH_BYTES
            ):
                fail("private scratch exceeds its cleanup byte limit")
            child = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                    fail("private scratch file changed during cleanup preflight")
                size, digest = hash_open_file(child, MAX_TAR_BYTES)
                after = os.fstat(child)
                if (
                    size != metadata.st_size
                    or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                    != (
                        metadata.st_dev,
                        metadata.st_ino,
                        metadata.st_size,
                        metadata.st_mtime_ns,
                        metadata.st_ctime_ns,
                    )
                ):
                    fail("private scratch file changed while it was hashed")
                snapshot[relative] = ("file", *base_identity, digest)
            finally:
                os.close(child)
        else:
            fail("private scratch contains a symlink or special file")
    return snapshot


def cleanup_private_scratch(scratch: PinnedScratch) -> None:
    cleanup_failed = False
    try:
        for relative, entry in sorted(scratch.owned.items()):
            try:
                metadata = os.fstat(entry.descriptor)
                expected_type = (
                    stat.S_ISDIR if entry.kind == "directory" else stat.S_ISREG
                )
                if (
                    not expected_type(metadata.st_mode)
                    or (metadata.st_dev, metadata.st_ino) != entry.identity
                ):
                    raise OSError("creation-owned inode identity changed")
                if entry.kind == "file":
                    os.ftruncate(entry.descriptor, 0)
                    os.fsync(entry.descriptor)
                    if os.fstat(entry.descriptor).st_size != 0:
                        raise OSError("creation-owned file did not scrub")
            except BaseException:
                cleanup_failed = True
        try:
            scratch.parent.verify()
            scratch.verify()
            first_snapshot = snapshot_private_tree(scratch.descriptor)
            if snapshot_private_tree(scratch.descriptor) != first_snapshot:
                fail("private scratch changed between retained-tree checks")
            if set(first_snapshot) != set(scratch.owned):
                fail("private scratch contains an unknown or missing retained member")
            for relative, record in first_snapshot.items():
                ownership = scratch.owned[relative]
                if (
                    (record[0], record[1], record[2])
                    != (ownership.kind, *ownership.identity)
                    or (
                        ownership.kind == "file"
                        and (record[3], record[4]) != (0o600, 0)
                    )
                    or (
                        ownership.kind == "directory"
                        and record[3] != 0o700
                    )
                ):
                    fail("private scratch retained-tree identity or size is unsafe")
            scratch.verify()
            scratch.parent.verify()
            root_metadata = os.fstat(scratch.descriptor)
            if stat.S_IMODE(root_metadata.st_mode) != 0o700:
                fail("private scratch root mode changed during retained-tree checks")
            scratch.retained_snapshot = first_snapshot
        except BaseException:
            cleanup_failed = True
    finally:
        for entry in scratch.owned.values():
            try:
                if entry.descriptor >= 0:
                    os.close(entry.descriptor)
                    entry.descriptor = -1
            except OSError:
                cleanup_failed = True
    if cleanup_failed:
        fail("private scratch could not be scrubbed safely")


def verify_scrubbed_scratch(scratch: PinnedScratch) -> None:
    """Recheck the exact retained zero-byte tree before reporting success."""

    if scratch.retained_snapshot is None:
        fail("private scratch has no completed retained-tree snapshot")
    scratch.parent.verify()
    scratch.verify()
    root_metadata = os.fstat(scratch.descriptor)
    if stat.S_IMODE(root_metadata.st_mode) != 0o700:
        fail("private scratch root mode changed before final success")
    first = snapshot_private_tree(scratch.descriptor)
    second = snapshot_private_tree(scratch.descriptor)
    if first != second or first != scratch.retained_snapshot:
        fail("private scratch retained tree changed before final success")
    scratch.verify()
    scratch.parent.verify()


def stable_file(path: Path, label: str, maximum: int = MAX_CONTROL_BYTES) -> FileSnapshot:
    candidate = Path(os.path.abspath(path))
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        before_path = candidate.lstat()
        descriptor = os.open(candidate, flags)
    except OSError as exc:
        fail(f"{label} must be a readable regular, non-symlinked file: {exc}")
    chunks: list[bytes] = []
    digest = hashlib.sha256()
    total = 0
    try:
        before_fd = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before_path.st_mode)
            or not stat.S_ISREG(before_fd.st_mode)
            or (before_path.st_dev, before_path.st_ino)
            != (before_fd.st_dev, before_fd.st_ino)
        ):
            fail(f"{label} must be a regular, non-symlinked file")
        if before_fd.st_size <= 0 or before_fd.st_size > maximum:
            fail(f"{label} has an invalid or excessive size")
        while True:
            chunk = os.read(descriptor, min(READ_CHUNK_BYTES, maximum + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                fail(f"{label} exceeds its size limit")
            chunks.append(chunk)
            digest.update(chunk)
        after_fd = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        after_path = candidate.lstat()
    except OSError as exc:
        fail(f"could not re-inspect {label}: {exc}")
    identity = (
        before_fd.st_dev,
        before_fd.st_ino,
        before_fd.st_size,
        before_fd.st_mtime_ns,
        before_fd.st_ctime_ns,
    )
    if identity != (
        after_fd.st_dev,
        after_fd.st_ino,
        after_fd.st_size,
        after_fd.st_mtime_ns,
        after_fd.st_ctime_ns,
    ) or identity != (
        after_path.st_dev,
        after_path.st_ino,
        after_path.st_size,
        after_path.st_mtime_ns,
        after_path.st_ctime_ns,
    ):
        fail(f"{label} changed while it was read")
    if total != before_fd.st_size:
        fail(f"{label} changed size while it was read")
    return FileSnapshot(candidate, identity, digest.hexdigest(), b"".join(chunks))


def verify_snapshot(snapshot: FileSnapshot, label: str) -> None:
    current = stable_file(snapshot.path, label, max(MAX_CONTROL_BYTES, len(snapshot.data)))
    if current.identity != snapshot.identity or current.sha256 != snapshot.sha256:
        fail(f"{label} changed during source-archive generation")


def decode_control(snapshot: FileSnapshot, label: str) -> list[str]:
    data = snapshot.data
    if not data.endswith(b"\n") or b"\x00" in data or b"\r" in data:
        fail(f"{label} must be non-empty LF-terminated text")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"{label} is not UTF-8: {exc}")
    if any(
        ord(character) < 0x20 or ord(character) > 0x7E
        for character in text
        if character != "\n"
    ):
        fail(f"{label} contains a non-printable character")
    return text.splitlines()


def parse_assignments(snapshot: FileSnapshot, label: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in decode_control(snapshot, label):
        if not line or line.startswith("#"):
            continue
        match = BASELINE_ASSIGNMENT.fullmatch(line)
        if match is None:
            fail(f"{label} contains a noncanonical assignment")
        key, value = match.groups()
        if key in values or not value:
            fail(f"{label} contains a duplicate or empty assignment: {key}")
        values[key] = value
    return values


def parse_manifest(snapshot: FileSnapshot) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in decode_control(snapshot, "build manifest"):
        if ": " not in line:
            fail("build manifest contains a non-schema line")
        key, value = line.split(": ", 1)
        if not key or not value or key in fields:
            fail("build manifest contains an empty or duplicate field")
        fields[key] = value
    return fields


def required(values: dict[str, str], key: str, label: str) -> str:
    value = values.get(key, "")
    if not value:
        fail(f"{label} is missing required field {key}")
    return value


def safe_environment(scratch: Path) -> dict[str, str]:
    return {
        "PATH": "/usr/bin:/bin",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "HOME": str(scratch / "home"),
        "XDG_CONFIG_HOME": str(scratch / "xdg"),
        "TMPDIR": str(scratch / "tmp"),
        "LC_ALL": "C",
        "LANG": "C",
        "TZ": "UTC",
    }


def private_git_config(object_format: str) -> bytes:
    """Return exact config bytes for one private object format."""

    if object_format == "sha1":
        return (
            b"[core]\n"
            b"\trepositoryformatversion = 0\n"
            b"\tfilemode = true\n"
            b"\tbare = true\n"
            b"\tcommitGraph = false\n"
        )
    if object_format == "sha256":
        return (
            b"[core]\n"
            b"\trepositoryformatversion = 1\n"
            b"\tfilemode = true\n"
            b"\tbare = true\n"
            b"\tcommitGraph = false\n"
            b"[extensions]\n"
            b"\tobjectformat = sha256\n"
        )
    fail("unsupported private Git object format")


def create_private_git_view(
    scratch: PinnedScratch, object_format: str, source_head: str
) -> Path:
    """Construct a config-free object view with one manifest-bound shallow root."""

    config = private_git_config(object_format)
    expected_length = 40 if object_format == "sha1" else 64
    if not OBJECT_ID.fullmatch(source_head) or len(source_head) != expected_length:
        fail("private Git shallow boundary does not match the source object format")
    create_private_directory(scratch, "object-view.git")
    create_private_directory(scratch, "object-view.git/objects")
    create_private_directory(scratch, "object-view.git/refs")
    write_private_file(
        scratch, "object-view.git/HEAD", b"ref: refs/heads/private-view\n"
    )
    write_private_file(scratch, "object-view.git/config", config)
    # The preserved production checkout may be a true depth-1 clone whose
    # source commit has an unavailable parent.  Recreate only the exact
    # manifest-bound Source HEAD as private shallow authority; never copy or
    # consult the source repository's mutable .git/shallow file.
    write_private_file(
        scratch, "object-view.git/shallow", f"{source_head}\n".encode("ascii")
    )
    return Path("object-view.git")


def tool_snapshot(path_value: str, expected_sha256: str, name: str) -> ToolSnapshot:
    candidate = Path(path_value)
    if not candidate.is_absolute() or not SHA256.fullmatch(expected_sha256):
        fail(f"{name} path or SHA-256 is not canonical in the toolchain contract")
    try:
        metadata = candidate.lstat()
    except OSError as exc:
        fail(f"could not inspect contracted {name} executable: {exc}")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        fail(f"could not resolve contracted {name} executable: {exc}")
    if (
        resolved != candidate
        or not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or not os.access(candidate, os.X_OK)
    ):
        fail(f"contracted {name} path must be an exact executable regular file")
    identity, size, digest = stable_file_digest(
        candidate, f"contracted {name} executable", 256 * 1024 * 1024
    )
    if digest != expected_sha256:
        fail(f"installed {name} executable SHA-256 does not match the toolchain contract")
    return ToolSnapshot(candidate, identity, size, digest)


def verify_tool(snapshot: ToolSnapshot, name: str) -> None:
    identity, size, digest = stable_file_digest(
        snapshot.path, f"contracted {name} executable", 256 * 1024 * 1024
    )
    if identity != snapshot.identity or size != snapshot.size or digest != snapshot.sha256:
        fail(f"contracted {name} executable changed during source-archive generation")


def library_snapshot(
    path_value: str, expected_sha256: str, name: str
) -> LibrarySnapshot:
    candidate = Path(path_value)
    if not candidate.is_absolute() or not SHA256.fullmatch(expected_sha256):
        fail(f"{name} path or SHA-256 is not canonical in the toolchain contract")
    try:
        metadata = candidate.lstat()
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        fail(f"could not inspect contracted {name}: {exc}")
    if (
        resolved != candidate
        or not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
    ):
        fail(f"contracted {name} path must be an exact regular file")
    if sys.platform.startswith("linux"):
        runtime_link = candidate.with_name("liblzma.so.5")
        try:
            runtime_link_metadata = runtime_link.lstat()
            runtime_target = runtime_link.resolve(strict=True)
        except OSError as exc:
            fail(f"could not inspect the contracted {name} runtime link: {exc}")
        if (
            not stat.S_ISLNK(runtime_link_metadata.st_mode)
            or runtime_target != candidate
        ):
            fail(f"contracted {name} is not selected by the runtime SONAME link")
    identity, size, digest = stable_file_digest(
        candidate, f"contracted {name}", 256 * 1024 * 1024
    )
    if digest != expected_sha256:
        fail(f"installed {name} SHA-256 does not match the toolchain contract")
    return LibrarySnapshot(candidate, identity, size, digest)


def verify_library(snapshot: LibrarySnapshot, name: str) -> None:
    identity, size, digest = stable_file_digest(
        snapshot.path, f"contracted {name}", 256 * 1024 * 1024
    )
    if identity != snapshot.identity or size != snapshot.size or digest != snapshot.sha256:
        fail(f"contracted {name} changed during source-archive generation")


def child_process_setup(
    previous_mask: set[signal.Signals],
    maximum: int | None,
    fixture_signal_parent_before_exec: bool = False,
):
    """Restore the caller's mask in the child and apply its optional file cap."""

    def prepare_child() -> None:
        # The fixture queues SIGINT while the parent is still inside Popen and
        # has not executed its ownership STORE.  The parent mask makes that
        # exact acquisition boundary deterministic on both macOS and Linux.
        if fixture_signal_parent_before_exec:
            os.kill(os.getppid(), signal.SIGINT)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        if maximum is not None:
            resource.setrlimit(resource.RLIMIT_FSIZE, (maximum, maximum))

    return prepare_child


def stop_processes(processes: list[subprocess.Popen[bytes]]) -> None:
    """Unconditionally reap children and close their parent-side pipes."""

    for process in processes:
        if process.poll() is None:
            try:
                process.kill()
            except OSError:
                pass
    for process in processes:
        try:
            process.wait()
        except BaseException:
            pass
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None and not stream.closed:
                try:
                    stream.close()
                except OSError:
                    pass
    if any(process.poll() is None for process in processes):
        fail("source-archive child process could not be reaped safely")


def bounded_process_errors(
    processes: list[tuple[str, subprocess.Popen[bytes]]],
) -> dict[str, bytes]:
    """Drain multiple child stderr pipes concurrently with one strict bound each."""

    selector = selectors.DefaultSelector()
    buffers: dict[str, bytearray] = {}
    process_by_label = {label: process for label, process in processes}
    try:
        for label, process in processes:
            if process.stderr is None:
                fail(f"{label} has no diagnostic pipe")
            buffers[label] = bytearray()
            selector.register(process.stderr, selectors.EVENT_READ, label)
        while selector.get_map():
            for key, _events in selector.select():
                label = key.data
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                buffers[label].extend(chunk)
                if len(buffers[label]) > MAX_COMMAND_OUTPUT_BYTES:
                    for process in process_by_label.values():
                        if process.poll() is None:
                            process.kill()
                    for process in process_by_label.values():
                        process.wait()
                    fail(f"{label} exceeded the bounded diagnostic-output limit")
        for process in process_by_label.values():
            process.wait()
    except BaseException:
        stop_processes(list(process_by_label.values()))
        raise
    finally:
        selector.close()
    return {label: bytes(content) for label, content in buffers.items()}


def bounded_process_capture(
    process: subprocess.Popen[bytes], label: str
) -> tuple[int, bytes, bytes]:
    selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    try:
        if process.stdout is None or process.stderr is None:
            fail(f"{label} has incomplete capture pipes")
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        while selector.get_map():
            for key, _events in selector.select():
                stream_name = key.data
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                buffers[stream_name].extend(chunk)
                if len(buffers[stream_name]) > MAX_COMMAND_OUTPUT_BYTES:
                    if process.poll() is None:
                        process.kill()
                    process.wait()
                    fail(f"{label} exceeded the bounded {stream_name} limit")
    except BaseException:
        stop_processes([process])
        raise
    finally:
        selector.close()
    return process.wait(), bytes(buffers["stdout"]), bytes(buffers["stderr"])


def run_file_process(
    arguments: list[str],
    environment: dict[str, str],
    output,
    label: str,
    file_size_limit: int,
    input_stream=None,
) -> tuple[int, bytes]:
    process: subprocess.Popen[bytes] | None = None
    try:
        with blocked_sigint() as previous_mask:
            process = subprocess.Popen(
                arguments,
                env=environment,
                stdin=input_stream if input_stream is not None else subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.PIPE,
                preexec_fn=child_process_setup(previous_mask, file_size_limit),
                pass_fds=ACTIVE_PASS_FDS,
            )
        error_output = bounded_process_errors([(label, process)])[label]
        return process.returncode, error_output
    except BaseException:
        if process is not None:
            stop_processes([process])
        raise


def run_text(
    arguments: list[str],
    environment: dict[str, str],
    label: str,
    *,
    extra_pass_fds: tuple[int, ...] = (),
    fixture_interrupt_child: bool = False,
) -> str:
    process: subprocess.Popen[bytes] | None = None
    try:
        with blocked_sigint() as previous_mask:
            process = subprocess.Popen(
                arguments,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                preexec_fn=child_process_setup(
                    previous_mask,
                    None,
                    fixture_signal_parent_before_exec=fixture_interrupt_child,
                ),
                pass_fds=tuple(
                    sorted(set((*ACTIVE_PASS_FDS, *extra_pass_fds)))
                ),
            )
        returncode, stdout_bytes, stderr_bytes = bounded_process_capture(
            process, label
        )
    except OSError as exc:
        if process is not None:
            stop_processes([process])
        fail(f"could not run {label}: {exc}")
    except BaseException:
        if process is not None:
            stop_processes([process])
            if fixture_interrupt_child:
                print(
                    f"Fixture source-archive child reaped PID: {process.pid}",
                    file=sys.stderr,
                )
        raise
    if returncode != 0:
        detail = stderr_bytes.decode("utf-8", "replace").strip()
        fail(f"{label} failed" + (f": {detail}" if detail else ""))
    try:
        return stdout_bytes.decode("utf-8").rstrip("\n")
    except UnicodeDecodeError as exc:
        fail(f"{label} emitted non-UTF-8 output: {exc}")


def git_text(
    git: str,
    source_repo: Path,
    environment: dict[str, str],
    arguments: list[str],
    label: str,
) -> str:
    return run_text([git, "-C", str(source_repo), *arguments], environment, label)


def require_absent(path: Path, label: str) -> None:
    try:
        path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    fail(f"{label} must be absent from the source object authority")


def stable_file_digest(path: Path, label: str, maximum: int) -> tuple[tuple[int, int], int, str]:
    """Hash one large regular file without retaining its payload in memory."""

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        before_path = path.lstat()
        descriptor = os.open(path, flags)
    except OSError as exc:
        fail(f"{label} must be a readable regular, non-symlinked file: {exc}")
    digest = hashlib.sha256()
    copied = 0
    try:
        before_fd = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before_path.st_mode)
            or not stat.S_ISREG(before_fd.st_mode)
            or (before_path.st_dev, before_path.st_ino)
            != (before_fd.st_dev, before_fd.st_ino)
        ):
            fail(f"{label} must be a regular, non-symlinked file")
        if before_fd.st_size <= 0 or before_fd.st_size > maximum:
            fail(f"{label} has an invalid or excessive size")
        while True:
            chunk = os.read(descriptor, READ_CHUNK_BYTES)
            if not chunk:
                break
            copied += len(chunk)
            if copied > maximum:
                fail(f"{label} exceeds its size limit")
            digest.update(chunk)
        after_fd = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        after_path = path.lstat()
    except OSError as exc:
        fail(f"could not re-inspect {label}: {exc}")
    identity = (
        before_fd.st_dev,
        before_fd.st_ino,
        before_fd.st_size,
        before_fd.st_mtime_ns,
        before_fd.st_ctime_ns,
    )
    if identity != (
        after_fd.st_dev,
        after_fd.st_ino,
        after_fd.st_size,
        after_fd.st_mtime_ns,
        after_fd.st_ctime_ns,
    ) or identity != (
        after_path.st_dev,
        after_path.st_ino,
        after_path.st_size,
        after_path.st_mtime_ns,
        after_path.st_ctime_ns,
    ):
        fail(f"{label} changed while it was hashed")
    if copied != before_fd.st_size:
        fail(f"{label} changed size while it was hashed")
    return (before_fd.st_dev, before_fd.st_ino), copied, digest.hexdigest()


def stable_entry_digest(
    parent: PinnedDirectory, name: str, label: str, maximum: int
) -> tuple[tuple[int, int], int, str]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent.verify()
    try:
        before_entry = os.stat(
            name, dir_fd=parent.descriptor, follow_symlinks=False
        )
        descriptor = os.open(name, flags, dir_fd=parent.descriptor)
    except OSError as exc:
        fail(f"{label} must be a readable regular, non-symlinked file: {exc}")
    digest = hashlib.sha256()
    copied = 0
    try:
        before_fd = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before_entry.st_mode)
            or not stat.S_ISREG(before_fd.st_mode)
            or (before_entry.st_dev, before_entry.st_ino)
            != (before_fd.st_dev, before_fd.st_ino)
            or before_fd.st_size <= 0
            or before_fd.st_size > maximum
        ):
            fail(f"{label} has an unsafe type, identity, or size")
        while True:
            chunk = os.read(descriptor, READ_CHUNK_BYTES)
            if not chunk:
                break
            copied += len(chunk)
            if copied > maximum:
                fail(f"{label} exceeds its size limit")
            digest.update(chunk)
        after_fd = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    after_entry = os.stat(name, dir_fd=parent.descriptor, follow_symlinks=False)
    identity = (
        before_fd.st_dev,
        before_fd.st_ino,
        before_fd.st_size,
        before_fd.st_mtime_ns,
        before_fd.st_ctime_ns,
    )
    if identity != (
        after_fd.st_dev,
        after_fd.st_ino,
        after_fd.st_size,
        after_fd.st_mtime_ns,
        after_fd.st_ctime_ns,
    ) or identity != (
        after_entry.st_dev,
        after_entry.st_ino,
        after_entry.st_size,
        after_entry.st_mtime_ns,
        after_entry.st_ctime_ns,
    ):
        fail(f"{label} changed while it was hashed")
    if copied != before_fd.st_size:
        fail(f"{label} changed size while it was hashed")
    parent.verify()
    return (before_fd.st_dev, before_fd.st_ino), copied, digest.hexdigest()


def verify_source_binding(
    *,
    git: str,
    private_git_dir: Path,
    environment: dict[str, str],
    scratch: PinnedScratch,
    source_head: str,
    patched_tree: str,
    expected_diff_sha256: str,
) -> None:
    if run_text(
        [git, "--git-dir", str(private_git_dir), "cat-file", "-t", source_head],
        environment,
        "source commit type check",
    ) != "commit":
        fail("manifest Source HEAD is not a commit object in the private object view")
    if run_text(
        [git, "--git-dir", str(private_git_dir), "cat-file", "-t", patched_tree],
        environment,
        "patched-tree type check",
    ) != "tree":
        fail("manifest Patched tree ID is not a tree object in the private object view")

    diff_name = "canonical.diff"
    try:
        diff_descriptor = create_private_file(scratch, diff_name)
        with os.fdopen(diff_descriptor, "wb") as output:
            result_status, error_output = run_file_process(
                [
                    git,
                    "--git-dir",
                    str(private_git_dir),
                    "-c",
                    "core.attributesFile=/dev/null",
                    "-c",
                    "diff.suppressBlankEmpty=false",
                    f"--attr-source={patched_tree}",
                    "diff",
                    "--binary",
                    "--full-index",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--no-color",
                    "--diff-algorithm=myers",
                    "--indent-heuristic",
                    "--unified=3",
                    "--inter-hunk-context=0",
                    "--no-renames",
                    "-O/dev/null",
                    "--src-prefix=a/",
                    "--dst-prefix=b/",
                    source_head,
                    patched_tree,
                    "--",
                ],
                environment,
                output,
                "canonical patched diff",
                MAX_DIFF_BYTES,
            )
            output.flush()
            os.fsync(output.fileno())
    except OSError as exc:
        fail(f"could not reproduce canonical patched diff: {exc}")
    if result_status != 0:
        detail = error_output.decode("utf-8", "replace").strip()
        fail("canonical patched diff reproduction failed" + (f": {detail}" if detail else ""))
    actual_diff_sha256 = snapshot_owned_file(
        scratch, diff_name, "canonical patched diff", MAX_DIFF_BYTES
    ).sha256
    if actual_diff_sha256 != expected_diff_sha256:
        fail("source repository tree does not reproduce Patched diff SHA256")


def generate_archive(
    *,
    git: str,
    xz: str,
    private_git_dir: Path,
    environment: dict[str, str],
    scratch: PinnedScratch,
    archive_name: str,
    archive_root: str,
    patched_tree: str,
    epoch: int,
) -> None:
    tar_name = f"{archive_name}.raw.tar"
    try:
        tar_descriptor = create_private_file(scratch, tar_name)
        with os.fdopen(tar_descriptor, "wb") as tar_output:
            archive_status, archive_error = run_file_process(
                [
                    git,
                    "--git-dir",
                    str(private_git_dir),
                    "-c",
                    "core.attributesFile=/dev/null",
                    "-c",
                    "tar.umask=0002",
                    "archive",
                    "--format=tar",
                    f"--mtime=@{epoch}",
                    f"--prefix={archive_root}/",
                    patched_tree,
                    "--",
                ],
                environment,
                tar_output,
                "git archive",
                MAX_TAR_BYTES,
            )
            tar_output.flush()
            os.fsync(tar_output.fileno())
        if archive_status != 0:
            detail = archive_error.decode("utf-8", "replace").strip()
            fail("git archive failed" + (f": {detail}" if detail else ""))
        tar_metadata = os.fstat(scratch.owned[tar_name].descriptor)
        if (
            not stat.S_ISREG(tar_metadata.st_mode)
            or tar_metadata.st_size <= 0
            or tar_metadata.st_size > MAX_TAR_BYTES
        ):
            fail("git archive exceeded the bounded expanded-tar contract")
        tar_input_descriptor = open_private_file(scratch, tar_name)
        archive_descriptor = create_private_file(scratch, archive_name)
        with (
            os.fdopen(tar_input_descriptor, "rb") as tar_input,
            os.fdopen(archive_descriptor, "wb") as output,
        ):
            compression_status, compression_error = run_file_process(
                [xz, *XZ_ARGUMENTS],
                environment,
                output,
                "xz",
                MAX_ARCHIVE_BYTES,
                input_stream=tar_input,
            )
            output.flush()
            os.fsync(output.fileno())
    except OSError as exc:
        fail(f"could not generate source archive: {exc}")
    if compression_status != 0:
        detail = compression_error.decode("utf-8", "replace").strip()
        fail("xz compression failed" + (f": {detail}" if detail else ""))
    metadata = os.fstat(scratch.owned[archive_name].descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0:
        fail("source archive pipeline did not produce a non-empty regular file")


def validate_archive(
    validator_descriptor: int,
    archive: Path,
    archive_descriptor: int,
    patched_tree: str,
    epoch: int,
    environment: dict[str, str],
    *,
    fixture_interrupt_child: bool = False,
) -> str:
    validator_metadata = os.fstat(validator_descriptor)
    validator_path: Path | None = None
    for descriptor_root in ("/proc/self/fd", "/dev/fd"):
        candidate = Path(descriptor_root) / str(validator_descriptor)
        try:
            candidate_metadata = candidate.stat()
        except OSError:
            continue
        if (
            stat.S_ISREG(candidate_metadata.st_mode)
            and candidate_metadata.st_ino == validator_metadata.st_ino
            and candidate_metadata.st_size == validator_metadata.st_size
        ):
            validator_path = candidate
            break
    if validator_path is None:
        fail("platform cannot execute the held source-archive validator descriptor")
    os.lseek(validator_descriptor, 0, os.SEEK_SET)
    return run_text(
        [
            sys.executable,
            "-I",
            str(validator_path),
            "kernel",
            "--archive",
            str(archive),
            "--archive-fd",
            str(archive_descriptor),
            "--expected-tree",
            patched_tree,
            "--expected-mtime",
            str(epoch),
        ],
        environment,
        "independent source-archive validation",
        extra_pass_fds=(validator_descriptor, archive_descriptor),
        fixture_interrupt_child=fixture_interrupt_child,
    )


def regular_file_state(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        stat.S_IMODE(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
    )


def verify_installed_output(
    installed: InstalledOutput,
    output_parent: PinnedDirectory,
    *,
    expected_state: tuple[int, int, int, int, int] | None = None,
) -> tuple[int, int, int, int, int]:
    """Bind the held output bytes to the requested name and parent mapping."""

    if installed.descriptor < 0:
        fail("installed source archive descriptor was closed before final verification")
    output_parent.verify()
    before = os.fstat(installed.descriptor)
    state = regular_file_state(before)
    if (
        not stat.S_ISREG(before.st_mode)
        or (before.st_dev, before.st_ino) != installed.identity
        or state[0] != 0o644
        or state[1] != installed.size
        or state[4] != 1
        or (expected_state is not None and state != expected_state)
    ):
        fail(
            "installed source archive inode or destination mapping changed "
            "before final verification"
        )
    held_size, held_digest = hash_open_file(
        installed.descriptor, MAX_ARCHIVE_BYTES
    )
    after = os.fstat(installed.descriptor)
    if (
        (after.st_dev, after.st_ino) != installed.identity
        or regular_file_state(after) != state
        or held_size != installed.size
        or held_digest != installed.sha256
    ):
        fail("installed source archive changed while it was revalidated")
    mapped_identity, mapped_size, mapped_digest = stable_entry_digest(
        output_parent,
        installed.name,
        "installed source archive",
        MAX_ARCHIVE_BYTES,
    )
    mapped = os.stat(
        installed.name,
        dir_fd=output_parent.descriptor,
        follow_symlinks=False,
    )
    if (
        mapped_identity != installed.identity
        or mapped_size != installed.size
        or mapped_digest != installed.sha256
        or (mapped.st_dev, mapped.st_ino) != installed.identity
        or regular_file_state(mapped) != state
    ):
        fail("destination mapping differs from the validated source archive")
    output_parent.verify()
    return state


def scrub_and_close_installed_output(installed: InstalledOutput) -> None:
    """Best-effort scrub only the exact held output inode on failed finalization."""

    if installed.descriptor < 0:
        return
    try:
        os.ftruncate(installed.descriptor, 0)
        os.fsync(installed.descriptor)
    except BaseException:
        pass
    try:
        os.close(installed.descriptor)
    except OSError:
        pass
    installed.descriptor = -1


def verify_installed_mapping_state(
    installed: InstalledOutput, output_parent: PinnedDirectory
) -> None:
    """Perform the last descriptor/name metadata check without reopening data."""

    output_parent.verify()
    held = os.fstat(installed.descriptor)
    mapped = os.stat(
        installed.name,
        dir_fd=output_parent.descriptor,
        follow_symlinks=False,
    )
    if (
        not stat.S_ISREG(held.st_mode)
        or not stat.S_ISREG(mapped.st_mode)
        or (held.st_dev, held.st_ino) != installed.identity
        or (mapped.st_dev, mapped.st_ino) != installed.identity
        or regular_file_state(held) != installed.state
        or regular_file_state(mapped) != installed.state
    ):
        fail("destination mapping changed at the final success boundary")
    output_parent.verify()


@contextmanager
def generation_finalization_guard(state: FinalizationState):
    """Finalize exact retained/output mappings after all inner contexts exit."""

    try:
        yield
        if (
            state.output_parent is None
            or state.scratch_parent is None
            or state.scratch is None
            or state.installed is None
        ):
            fail("source-archive generation did not retain its final authorities")
        if state.pause_before_final_check:
            time.sleep(3)
        verify_scrubbed_scratch(state.scratch)
        state.installed.state = verify_installed_output(
            state.installed,
            state.output_parent,
            expected_state=state.installed.state,
        )
        # Recheck both requested mappings in a tight final sequence after the
        # potentially long archive digest and retained-tree checks.
        state.scratch.verify()
        state.scratch_parent.verify()
        verify_installed_mapping_state(state.installed, state.output_parent)
        close_finalization_handles(state, scrub_output=False)
    except BaseException:
        close_finalization_handles(state, scrub_output=True)
        raise


def install_exclusive(
    source_name: str,
    scratch: PinnedScratch,
    output_name: str,
    output_parent: PinnedDirectory,
    validated: OwnedFileSnapshot,
    finalization: FinalizationState,
    *,
    fixture_pause_after_copy: bool = False,
    fixture_raise_after_copy: bool = False,
    fixture_sigint_before_transfer: bool = False,
) -> InstalledOutput:
    source = scratch.owned.get(source_name)
    if source is None or source.kind != "file":
        fail("validated source archive is not a creation-owned scratch file")
    if snapshot_owned_file(
        scratch, source_name, "validated source archive", MAX_ARCHIVE_BYTES
    ) != validated:
        fail("validated source archive changed before destination copy")
    scratch.verify()
    output_parent.verify()
    output_descriptor = -1
    install_committed = False
    provisional: InstalledOutput | None = None
    try:
        output_descriptor = os.open(
            output_name,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
            dir_fd=output_parent.descriptor,
        )
    except FileExistsError:
        fail("refusing to overwrite an existing source-archive output")
    except OSError as exc:
        fail(f"could not install source archive exclusively: {exc}")
    try:
        output_metadata = os.fstat(output_descriptor)
        output_identity = (output_metadata.st_dev, output_metadata.st_ino)
        if not stat.S_ISREG(output_metadata.st_mode):
            fail("exclusive destination did not create a regular file")
        os.fchmod(output_descriptor, 0o644)
        os.lseek(source.descriptor, 0, os.SEEK_SET)
        os.lseek(output_descriptor, 0, os.SEEK_SET)
        copied = 0
        copied_digest = hashlib.sha256()
        while True:
            chunk = os.read(source.descriptor, READ_CHUNK_BYTES)
            if not chunk:
                break
            copied += len(chunk)
            if copied > MAX_ARCHIVE_BYTES:
                fail("validated source archive exceeded its copy limit")
            copied_digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(output_descriptor, view)
                view = view[written:]
        os.fsync(output_descriptor)
        if copied != validated.size or copied_digest.hexdigest() != validated.sha256:
            fail("validated source archive changed during destination copy")
        if snapshot_owned_file(
            scratch, source_name, "post-copy source archive", MAX_ARCHIVE_BYTES
        ) != validated:
            fail("validated source archive changed during destination copy")
        installed_size, installed_digest = hash_open_file(
            output_descriptor, MAX_ARCHIVE_BYTES
        )
        if (
            installed_size != validated.size
            or installed_digest != validated.sha256
        ):
            fail("destination bytes differ from the validated source archive")
        if fixture_pause_after_copy:
            time.sleep(2)
        if fixture_raise_after_copy:
            raise RuntimeError("fixture unexpected install interruption")
        provisional = InstalledOutput(
            output_name,
            output_descriptor,
            output_identity,
            regular_file_state(os.fstat(output_descriptor)),
            validated.size,
            validated.sha256,
        )
        provisional.state = verify_installed_output(provisional, output_parent)
        os.fsync(output_parent.descriptor)
        provisional.state = verify_installed_output(
            provisional, output_parent, expected_state=provisional.state
        )
        if fixture_sigint_before_transfer:
            os.kill(os.getpid(), signal.SIGINT)
        # The caller holds SIGINT blocked across this direct shared-state store,
        # the return, and its confirming assignment.  Do not suppress local
        # scrubbing until the finalization guard can see the exact descriptor.
        finalization.installed = provisional
        install_committed = True
        return provisional
    finally:
        if output_descriptor >= 0 and not install_committed:
            try:
                os.ftruncate(output_descriptor, 0)
                os.fsync(output_descriptor)
            except (OSError, KeyboardInterrupt):
                pass
        if output_descriptor >= 0 and not install_committed:
            os.close(output_descriptor)
            if provisional is not None:
                provisional.descriptor = -1
                if finalization.installed is provisional:
                    finalization.installed = None


def parse_arguments() -> argparse.Namespace:
    script_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--build-manifest", required=True, type=Path)
    parser.add_argument("--source-repo", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--scratch-parent", type=Path, default=Path("/tmp"))
    parser.add_argument(
        "--fixture-mutate-validated-archive",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--fixture-pause-after-destination-copy",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--fixture-raise-after-destination-copy",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--fixture-interrupt-validator-child",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--fixture-sigint-before-install-transfer",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--fixture-pause-before-final-mapping-check",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--toolchain-contract",
        type=Path,
        default=script_root / "config/kernel-source-archive-v1.env",
    )
    return parser.parse_args()


def main() -> int:
    if not sys.flags.isolated:
        fail("source archive generator must be invoked with Python isolated mode (-I)")
    require_sigint_mask_support()
    args = parse_arguments()
    baseline_snapshot = stable_file(args.baseline, "kernel baseline")
    manifest_snapshot = stable_file(args.build_manifest, "build manifest")
    contract_snapshot = stable_file(args.toolchain_contract, "source-archive toolchain contract")
    baseline = parse_assignments(baseline_snapshot, "kernel baseline")
    manifest = parse_manifest(manifest_snapshot)
    contract = parse_assignments(contract_snapshot, "source-archive toolchain contract")
    fixture_baseline = baseline.get("SP11_KERNEL_BASELINE_ID") == "fixture"
    if (
        args.fixture_mutate_validated_archive
        or args.fixture_pause_after_destination_copy
        or args.fixture_raise_after_destination_copy
        or args.fixture_interrupt_validator_child
        or args.fixture_sigint_before_install_transfer
        or args.fixture_pause_before_final_mapping_check
    ) and not fixture_baseline:
        fail("source-archive fault injection is permitted only for a fixture baseline")
    if tuple(contract) != CONTRACT_KEYS:
        fail("source-archive toolchain contract field set or order is not exact")
    if required(
        contract, "SP11_KERNEL_SOURCE_ARCHIVE_CONTRACT", "toolchain contract"
    ) != "sp11-kernel-source-archive-v1":
        fail("unsupported source-archive toolchain contract")
    expected_python_path = Path(
        required(
            contract,
            "SP11_KERNEL_SOURCE_ARCHIVE_PYTHON_PATH",
            "toolchain contract",
        )
    )
    if not expected_python_path.is_absolute() or Path(sys.executable) != expected_python_path:
        fail("active isolated Python path does not match the toolchain contract")
    default_contract = (
        Path(__file__).resolve().parent.parent / "config/kernel-source-archive-v1.env"
    )
    if (
        contract_snapshot.path.resolve(strict=True) != default_contract.resolve(strict=True)
        and not fixture_baseline
    ):
        fail("a non-default toolchain contract is permitted only for a fixture baseline")

    epoch_text = required(baseline, "SP11_KERNEL_SOURCE_DATE_EPOCH", "kernel baseline")
    if not re.fullmatch(r"[1-9][0-9]{0,9}", epoch_text) or int(epoch_text) > 4_102_444_799:
        fail("kernel baseline source epoch is not canonical and bounded before 2100 UTC")
    epoch = int(epoch_text)
    baseline_commit = required(baseline, "SP11_KERNEL_UPSTREAM_COMMIT", "kernel baseline")
    if not OBJECT_ID.fullmatch(baseline_commit):
        fail("kernel baseline source commit is not a canonical Git object ID")

    exact_manifest = {
        "Provenance schema": "sp11-kernel-build-v2",
        "Release build": "true",
        "Build completed": "true",
        "Source mode": "git",
        "Source URL": required(baseline, "SP11_KERNEL_UPSTREAM_URL", "kernel baseline"),
        "Source ref": required(baseline, "SP11_KERNEL_UPSTREAM_REF", "kernel baseline"),
        "Expected source commit": baseline_commit,
        "Source HEAD": baseline_commit,
        "Patched diff format": "git-diff-full-index-binary-v1",
    }
    for field, expected in exact_manifest.items():
        if required(manifest, field, "build manifest") != expected:
            fail(f"build manifest {field} does not match its release provenance contract")

    source_head = required(manifest, "Source HEAD", "build manifest")
    patched_tree = required(manifest, "Patched tree ID", "build manifest")
    diff_sha256 = required(manifest, "Patched diff SHA256", "build manifest")
    manifest_git_version = required(manifest, "Patched diff Git version", "build manifest")
    if not OBJECT_ID.fullmatch(source_head) or not OBJECT_ID.fullmatch(patched_tree):
        fail("build manifest source or patched-tree ID is not canonical lowercase hexadecimal")
    if len(source_head) != len(patched_tree):
        fail("build manifest source and patched-tree IDs use mixed Git object formats")
    if not SHA256.fullmatch(diff_sha256):
        fail("build manifest Patched diff SHA256 is not canonical")
    if manifest_git_version != required(
        contract, "SP11_KERNEL_SOURCE_ARCHIVE_GIT_VERSION", "toolchain contract"
    ):
        fail("build manifest Git version does not match the source-archive toolchain contract")

    output_parent, output_parent_identity = canonical_unaliased_directory(
        args.output.parent, "output parent"
    )
    output_name = args.output.name
    if not SAFE_ARCHIVE_NAME.fullmatch(output_name):
        fail("output must use a bounded safe *-patched-source*.tar.xz basename")
    output = output_parent / output_name
    archive_root = output_name[: -len(".tar.xz")]
    source_repo, source_repo_identity = canonical_unaliased_directory(
        args.source_repo, "source repository"
    )
    scratch_parent, scratch_parent_identity = canonical_unaliased_directory(
        args.scratch_parent, "scratch parent"
    )
    git_metadata = source_repo / ".git"
    try:
        git_metadata_stat = git_metadata.lstat()
    except OSError as exc:
        fail(f"source repository has no inspectable private Git directory: {exc}")
    if not stat.S_ISDIR(git_metadata_stat.st_mode) or stat.S_ISLNK(git_metadata_stat.st_mode):
        fail("source repository must have a real, non-symlinked .git directory")

    validator = Path(__file__).resolve().parent / "validate-sp11-source-archive.py"
    validator_source_snapshot = stable_file(
        validator, "source-archive validator", MAX_CONTROL_BYTES
    )
    if validator_source_snapshot.sha256 != required(
        contract,
        "SP11_KERNEL_SOURCE_ARCHIVE_VALIDATOR_SHA256",
        "toolchain contract",
    ):
        fail("source-archive validator SHA-256 does not match the toolchain contract")
    finalization = FinalizationState(
        pause_before_final_check=args.fixture_pause_before_final_mapping_check
    )
    with (
        generation_finalization_guard(finalization),
        pinned_directory(
            output_parent, output_parent_identity, "output parent"
        ) as output_parent_handle,
        pinned_directory(
            scratch_parent, scratch_parent_identity, "scratch parent"
        ) as scratch_parent_handle,
        private_scratch(scratch_parent_handle) as scratch_handle,
        entered_private_scratch(scratch_handle),
    ):
        output_parent_handle.defer_close = True
        scratch_parent_handle.defer_close = True
        finalization.output_parent = output_parent_handle
        finalization.scratch_parent = scratch_parent_handle
        finalization.scratch = scratch_handle
        scratch = scratch_handle.path
        try:
            os.stat(
                output_name,
                dir_fd=output_parent_handle.descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        except OSError as exc:
            fail(f"could not inspect requested source-archive output: {exc}")
        else:
            fail("refusing to overwrite an existing source-archive output")
        create_private_directory(scratch_handle, "home")
        create_private_directory(scratch_handle, "xdg")
        create_private_directory(scratch_handle, "tmp")
        validator_name = "validator-snapshot.py"
        write_private_file(
            scratch_handle, validator_name, validator_source_snapshot.data
        )
        validator_validated = snapshot_owned_file(
            scratch_handle,
            validator_name,
            "private source-archive validator snapshot",
            MAX_CONTROL_BYTES,
        )
        if validator_validated.sha256 != validator_source_snapshot.sha256:
            fail("private source-archive validator snapshot changed during capture")
        validator_descriptor = scratch_handle.owned[validator_name].descriptor
        environment = safe_environment(scratch)
        git_snapshot = tool_snapshot(
            required(contract, "SP11_KERNEL_SOURCE_ARCHIVE_GIT_PATH", "toolchain contract"),
            required(contract, "SP11_KERNEL_SOURCE_ARCHIVE_GIT_SHA256", "toolchain contract"),
            "Git",
        )
        xz_snapshot = tool_snapshot(
            required(contract, "SP11_KERNEL_SOURCE_ARCHIVE_XZ_PATH", "toolchain contract"),
            required(contract, "SP11_KERNEL_SOURCE_ARCHIVE_XZ_SHA256", "toolchain contract"),
            "XZ",
        )
        xz_library_snapshot = library_snapshot(
            required(
                contract,
                "SP11_KERNEL_SOURCE_ARCHIVE_XZ_LIBRARY_PATH",
                "toolchain contract",
            ),
            required(
                contract,
                "SP11_KERNEL_SOURCE_ARCHIVE_XZ_LIBRARY_SHA256",
                "toolchain contract",
            ),
            "XZ compression library",
        )
        git = str(git_snapshot.path)
        xz = str(xz_snapshot.path)
        actual_git_version = run_text([git, "--version"], environment, "Git version check")
        if actual_git_version != manifest_git_version:
            fail("installed Git version does not match Patched diff Git version")
        actual_xz_version = run_text([xz, "--version"], environment, "XZ version check").splitlines()[0]
        expected_xz_version = required(
            contract, "SP11_KERNEL_SOURCE_ARCHIVE_XZ_VERSION", "toolchain contract"
        )
        if actual_xz_version != expected_xz_version:
            fail("installed XZ version does not match the source-archive toolchain contract")

        top_level = git_text(
            git, source_repo, environment, ["rev-parse", "--show-toplevel"], "source root check"
        )
        if Path(top_level).resolve(strict=True) != source_repo:
            fail("--source-repo is not the exact Git worktree root")
        git_directory = git_text(
            git, source_repo, environment, ["rev-parse", "--absolute-git-dir"], "Git directory check"
        )
        if Path(git_directory).resolve(strict=True) != git_metadata.resolve(strict=True):
            fail("source repository resolves through an unexpected Git directory")
        object_format = git_text(
            git, source_repo, environment, ["rev-parse", "--show-object-format"], "object-format check"
        )
        expected_object_format = "sha1" if len(source_head) == 40 else "sha256"
        if object_format != expected_object_format:
            fail("source repository object format does not match manifest object IDs")
        actual_source_head = git_text(
            git,
            source_repo,
            environment,
            ["rev-parse", "--verify", "HEAD^{commit}"],
            "source HEAD check",
        ).lower()
        if actual_source_head != source_head:
            fail("source repository HEAD does not match the build manifest")
        require_absent(
            git_metadata / "info/attributes", "source repository private attributes"
        )
        source_objects = canonical_existing_directory(
            git_metadata / "objects", "source object directory"
        )
        require_absent(
            source_objects / "info/alternates", "source repository object alternates"
        )
        if os.pathsep in str(source_objects) or "\n" in str(source_objects):
            fail("source object directory cannot be encoded as one private alternate")

        private_git_dir = create_private_git_view(
            scratch_handle, object_format, source_head
        )
        object_environment = environment.copy()
        object_environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = str(source_objects)
        private_commit_graph = run_text(
            [
                git,
                "--git-dir",
                str(private_git_dir),
                "config",
                "--type=bool",
                "--get",
                "core.commitGraph",
            ],
            object_environment,
            "private commit-graph authority check",
        )
        if private_commit_graph != "false":
            fail("private Git view did not disable ambient commit-graph authority")
        commit_epoch = run_text(
            [
                git,
                "--git-dir",
                str(private_git_dir),
                "show",
                "-s",
                "--format=%ct",
                source_head,
            ],
            object_environment,
            "source commit epoch check",
        )
        if commit_epoch != epoch_text:
            fail("kernel baseline source epoch does not match the bound source commit")

        verify_source_binding(
            git=git,
            private_git_dir=private_git_dir,
            environment=object_environment,
            scratch=scratch_handle,
            source_head=source_head,
            patched_tree=patched_tree,
            expected_diff_sha256=diff_sha256,
        )
        archive_name = "generated-a.tar.xz"
        archive_path = Path(archive_name)
        generate_archive(
            git=git,
            xz=xz,
            private_git_dir=private_git_dir,
            environment=object_environment,
            scratch=scratch_handle,
            archive_name=archive_name,
            archive_root=archive_root,
            patched_tree=patched_tree,
            epoch=epoch,
        )
        first_validated = snapshot_owned_file(
            scratch_handle,
            archive_name,
            "pre-validation generated source archive",
            MAX_ARCHIVE_BYTES,
        )
        validation_output = validate_archive(
            validator_descriptor,
            archive_path,
            scratch_handle.owned[archive_name].descriptor,
            patched_tree,
            epoch,
            object_environment,
            fixture_interrupt_child=args.fixture_interrupt_validator_child,
        )
        if args.fixture_mutate_validated_archive:
            fixture_source = scratch_handle.owned[archive_name].descriptor
            os.ftruncate(fixture_source, 0)
            os.lseek(fixture_source, 0, os.SEEK_SET)
            os.write(fixture_source, b"fixture post-validation mutation\n")
            os.fsync(fixture_source)
        if snapshot_owned_file(
            scratch_handle,
            archive_name,
            "post-validation generated source archive",
            MAX_ARCHIVE_BYTES,
        ) != first_validated:
            fail("independently validated source archive changed after validation")
        repeated_archive_name = "generated-b.tar.xz"
        generate_archive(
            git=git,
            xz=xz,
            private_git_dir=private_git_dir,
            environment=object_environment,
            scratch=scratch_handle,
            archive_name=repeated_archive_name,
            archive_root=archive_root,
            patched_tree=patched_tree,
            epoch=epoch,
        )
        carried_first = snapshot_owned_file(
            scratch_handle,
            archive_name,
            "first generated source archive",
            MAX_ARCHIVE_BYTES,
        )
        second_validated = snapshot_owned_file(
            scratch_handle,
            repeated_archive_name,
            "repeated generated source archive",
            MAX_ARCHIVE_BYTES,
        )
        if carried_first != first_validated:
            fail("independently validated source archive changed during repeat generation")
        if (
            first_validated.size,
            first_validated.sha256,
        ) != (
            second_validated.size,
            second_validated.sha256,
        ):
            fail("repeated source-archive generation did not produce identical raw bytes")
        verify_snapshot(baseline_snapshot, "kernel baseline")
        verify_snapshot(manifest_snapshot, "build manifest")
        verify_snapshot(contract_snapshot, "source-archive toolchain contract")
        verify_snapshot(validator_source_snapshot, "source-archive validator")
        if snapshot_owned_file(
            scratch_handle,
            validator_name,
            "private source-archive validator snapshot",
            MAX_CONTROL_BYTES,
        ) != validator_validated:
            fail("private source-archive validator snapshot changed during generation")
        verify_tool(git_snapshot, "Git")
        verify_tool(xz_snapshot, "XZ")
        verify_library(xz_library_snapshot, "XZ compression library")
        final_head = git_text(
            git,
            source_repo,
            environment,
            ["rev-parse", "--verify", "HEAD^{commit}"],
            "final source HEAD check",
        ).lower()
        if final_head != source_head:
            fail("source repository HEAD changed during source-archive generation")
        final_source_metadata = source_repo.lstat()
        if (
            not stat.S_ISDIR(final_source_metadata.st_mode)
            or (final_source_metadata.st_dev, final_source_metadata.st_ino)
            != source_repo_identity
        ):
            fail("source repository identity changed during source-archive generation")
        final_tree_type = run_text(
            [git, "--git-dir", str(private_git_dir), "cat-file", "-t", patched_tree],
            object_environment,
            "final tree check",
        )
        if final_tree_type != "tree":
            fail("patched tree object changed during source-archive generation")
        with blocked_sigint():
            finalization.installed = install_exclusive(
                archive_name,
                scratch_handle,
                output_name,
                output_parent_handle,
                first_validated,
                finalization,
                fixture_pause_after_copy=args.fixture_pause_after_destination_copy,
                fixture_raise_after_copy=args.fixture_raise_after_destination_copy,
                fixture_sigint_before_transfer=(
                    args.fixture_sigint_before_install_transfer
                ),
            )
        size = finalization.installed.size
        digest = finalization.installed.sha256

    print("Generated deterministic patched-source archive candidate.")
    print(f"Contract: {contract['SP11_KERNEL_SOURCE_ARCHIVE_CONTRACT']}")
    print(f"Archive: {output.name}")
    print(f"Archive root: {archive_root}")
    print(f"Patched tree ID: {patched_tree}")
    print(f"Source epoch: {epoch}")
    print(f"Git version: {manifest_git_version}")
    print(f"XZ version: {expected_xz_version}")
    print(f"XZ arguments: {' '.join(XZ_ARGUMENTS)}")
    print(f"Archive size: {size}")
    print(f"Archive SHA256: {digest}")
    print(validation_output)
    print("Corresponding-source legal sufficiency review required: true")
    print("Publication authorized: false")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GenerationError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
    except Exception as error:  # Defensive boundary: never emit an uncontrolled traceback.
        print(
            f"error: source archive generation failed safely ({type(error).__name__})",
            file=sys.stderr,
        )
        raise SystemExit(2)
    except KeyboardInterrupt:
        print("error: source archive generation interrupted safely", file=sys.stderr)
        raise SystemExit(2)
