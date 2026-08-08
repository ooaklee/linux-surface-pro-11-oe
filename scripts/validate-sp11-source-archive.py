#!/usr/bin/env python3
"""Technically validate patched-source archive candidates against Git objects."""

from __future__ import annotations

import argparse
import hashlib
import lzma
import os
import posixpath
import re
import stat
import sys
import tarfile
from dataclasses import dataclass, field
from contextlib import contextmanager
from pathlib import Path, PurePosixPath
from typing import BinaryIO


MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_EXPANDED_BYTES = 8 * 1024 * 1024 * 1024
MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBERS = 250_000
MAX_PATH_BYTES = 4096
MAX_PATH_COMPONENTS = 64
MAX_TOTAL_PATH_COMPONENTS = 1_000_000
MAX_TOTAL_PATH_AND_LINK_BYTES = 64 * 1024 * 1024
MAX_TREE_CONTENT_BYTES = 32 * 1024 * 1024
COPY_CHUNK_BYTES = 1024 * 1024
MAX_ZERO_TAIL_BYTES = 1024 * 1024
MAX_XZ_DECODER_MEMORY = 256 * 1024 * 1024
MAX_TAR_READ_REQUEST = 8 * 1024 * 1024
MAX_TAR_EXTENSION_BYTES = 64 * 1024
MAX_TAR_BYTES = MAX_EXPANDED_BYTES + MAX_MEMBERS * 1024 + MAX_ZERO_TAIL_BYTES
OBJECT_ID_PATTERN = re.compile(r"(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})\Z")


class ValidationError(Exception):
    """An expected, user-facing archive validation failure."""


@dataclass(frozen=True)
class ArchiveMember:
    """The Git-relevant identity of one validated archive member."""

    name: str
    parts: tuple[str, ...]
    kind: str
    mode: str | None = None
    object_id: str | None = None
    linkname: str | None = None


@dataclass
class TreeNode:
    """An in-memory Git tree that never touches host filesystem path semantics."""

    children: dict[bytes, "TreeNode | ArchiveMember"] = field(default_factory=dict)


def object_format(object_id: str) -> str:
    if len(object_id) == 40:
        return "sha1"
    if len(object_id) == 64:
        return "sha256"
    raise ValidationError("expected Git object ID must contain 40 or 64 hexadecimal characters")


def validate_object_id(value: str, label: str) -> str:
    if not OBJECT_ID_PATTERN.fullmatch(value):
        raise ValidationError(f"{label} must be exactly 40 or 64 hexadecimal characters")
    object_format(value)
    return value.lower()


@contextmanager
def pinned_archive_stream(archive: Path, inherited_fd: int | None):
    """Hold one immutable-by-state archive inode without filesystem intermediates."""

    descriptor = -1
    before_path = None
    try:
        if inherited_fd is None:
            before_path = archive.lstat()
            descriptor = os.open(
                archive,
                os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            )
        else:
            if inherited_fd < 3:
                raise ValidationError("inherited source-archive descriptor is invalid")
            descriptor = os.dup(inherited_fd)
        before = os.fstat(descriptor)
        identity = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            before.st_nlink,
        )
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_size <= 0
            or before.st_size > MAX_ARCHIVE_BYTES
            or (
                before_path is not None
                and (
                    not stat.S_ISREG(before_path.st_mode)
                    or stat.S_ISLNK(before_path.st_mode)
                    or (before_path.st_dev, before_path.st_ino)
                    != (before.st_dev, before.st_ino)
                )
            )
        ):
            raise ValidationError(
                "source archive must be a bounded non-empty regular, non-symlinked file"
            )
        os.lseek(descriptor, 0, os.SEEK_SET)
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            yield stream
            after = os.fstat(stream.fileno())
        if identity != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_nlink,
        ):
            raise ValidationError("source archive changed while it was validated")
        if before_path is not None:
            after_path = archive.lstat()
            if (
                after_path.st_dev,
                after_path.st_ino,
                after_path.st_size,
                after_path.st_mtime_ns,
                after_path.st_ctime_ns,
                after_path.st_nlink,
            ) != identity:
                raise ValidationError("source archive mapping changed while it was validated")
    except ValidationError:
        raise
    except OSError as exc:
        raise ValidationError("source archive could not be pinned safely") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


class SingleXZReader:
    """Bounded non-seekable reader for exactly one XZ stream."""

    def __init__(self, source: BinaryIO):
        self.source = source
        self.decompressor = lzma.LZMADecompressor(
            format=lzma.FORMAT_XZ, memlimit=MAX_XZ_DECODER_MEMORY
        )
        header = source.read(6)
        if header != b"\xfd7zXZ\x00":
            raise ValidationError("source archive must be one XZ-compressed tar stream")
        self.pending = header
        self.buffer = bytearray()
        self.expanded = 0
        self.finished = False

    def read(self, size: int = -1) -> bytes:
        if size == 0:
            return b""
        if size < 0:
            size = COPY_CHUNK_BYTES
        if size > MAX_TAR_READ_REQUEST:
            raise ValidationError("source tar metadata read request exceeds its limit")
        try:
            while len(self.buffer) < size and not self.finished:
                if not self.pending and self.decompressor.needs_input:
                    self.pending = self.source.read(COPY_CHUNK_BYTES)
                    if not self.pending:
                        raise ValidationError(
                            "source archive contains a truncated XZ stream"
                        )
                output = self.decompressor.decompress(
                    self.pending, max_length=max(1, size - len(self.buffer))
                )
                self.pending = b""
                self.expanded += len(output)
                if self.expanded > MAX_TAR_BYTES:
                    raise ValidationError(
                        "source archive exceeds the expanded-size validation limit"
                    )
                self.buffer.extend(output)
                if self.decompressor.eof:
                    if self.decompressor.unused_data or self.source.read(1):
                        raise ValidationError(
                            "source archive contains bytes after its single XZ stream"
                        )
                    self.finished = True
                elif not output and not self.decompressor.needs_input:
                    continue
            result = bytes(self.buffer[:size])
            del self.buffer[:size]
            return result
        except lzma.LZMAError as exc:
            if "memory usage limit" in str(exc).lower():
                raise ValidationError(
                    "source archive exceeds the XZ decoder memory limit"
                ) from exc
            raise ValidationError("source archive has malformed XZ compression") from exc


class BoundedTarInfo(tarfile.TarInfo):
    """Reject attacker-sized extension payloads before tarfile buffers them."""

    def _proc_pax(self, source: tarfile.TarFile):
        if self.size < 0 or self.size > MAX_TAR_EXTENSION_BYTES:
            raise ValidationError("source tar extension metadata exceeds its limit")
        # tarfile processes GNU sparse PAX keys before returning the next
        # TarInfo.  In particular, sparse 1.0 trusts a following, attacker-set
        # field count and can grow a very large integer list.  Read and strictly
        # frame the already bounded PAX payload first, reject every GNU sparse
        # namespace key, then replay the bytes to the standard parser.
        stream = source.fileobj
        padded_size = self._block(self.size)
        payload = stream.read(padded_size)
        if len(payload) != padded_size:
            raise ValidationError("source tar extension metadata is truncated")
        content = payload[: self.size]
        position = 0
        while position < len(content) and content[position] != 0:
            space = content.find(b" ", position, min(len(content), position + 32))
            if space < 0:
                raise ValidationError("source tar has malformed PAX metadata")
            length_text = content[position:space]
            if not length_text or not length_text.isdigit():
                raise ValidationError("source tar has malformed PAX metadata")
            record_length = int(length_text)
            record_end = position + record_length
            if record_length < 5 or record_end > len(content):
                raise ValidationError("source tar has malformed PAX metadata")
            record = content[space + 1 : record_end]
            if not record.endswith(b"\n"):
                raise ValidationError("source tar has malformed PAX metadata")
            keyword, equals, _value = record[:-1].partition(b"=")
            if not keyword or equals != b"=":
                raise ValidationError("source tar has malformed PAX metadata")
            if keyword.startswith(b"GNU.sparse."):
                raise ValidationError("source tar GNU sparse PAX metadata is not permitted")
            position = record_end
        if position != len(content):
            raise ValidationError("source tar has malformed PAX metadata")

        buffered = getattr(stream, "buf", None)
        stream_position = getattr(stream, "pos", None)
        if not isinstance(buffered, bytes) or not isinstance(stream_position, int):
            raise ValidationError("source tar PAX stream cannot be replayed safely")
        stream.buf = payload + buffered
        stream.pos = stream_position - len(payload)
        return super()._proc_pax(source)

    def _proc_gnulong(self, source: tarfile.TarFile):
        if self.size < 0 or self.size > MAX_TAR_EXTENSION_BYTES:
            raise ValidationError("source tar extension metadata exceeds its limit")
        return super()._proc_gnulong(source)

    def _proc_sparse(self, source: tarfile.TarFile):
        raise ValidationError("source tar sparse extension metadata is not permitted")


def canonical_member_name(raw_name: str) -> tuple[str, tuple[str, ...]]:
    name = raw_name[:-1] if raw_name.endswith("/") else raw_name
    if (
        not name
        or name.startswith("/")
        or "\\" in name
        or "\x00" in name
        or any(ord(character) < 32 or ord(character) == 127 for character in name)
    ):
        raise ValidationError(f"archive contains an unsafe path: {raw_name!r}")
    if len(name.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES:
        raise ValidationError("archive contains a path longer than the validation limit")
    parts = PurePosixPath(name).parts
    if len(parts) > MAX_PATH_COMPONENTS:
        raise ValidationError(
            "archive path exceeds the path-component validation limit"
        )
    if (
        not parts
        or any(part in ("", ".", "..") for part in parts)
    ):
        raise ValidationError(f"archive contains a non-canonical path: {raw_name!r}")
    if posixpath.normpath(name) != name or "//" in name:
        raise ValidationError(f"archive contains a non-canonical path: {raw_name!r}")
    if ".git" in parts:
        raise ValidationError("source archive must not contain a .git path")
    return name, parts


def allowed_global_pax_headers(headers: dict[str, str], expected_comment: str | None) -> bool:
    if expected_comment is None:
        return not headers
    return headers == {"comment": expected_comment}


def allowed_member_pax_headers(
    headers: dict[str, str],
    expected_comment: str | None,
    member: tarfile.TarInfo,
    name: str,
) -> bool:
    expected: dict[str, str] = {}
    if expected_comment is not None and "comment" in headers:
        expected["comment"] = expected_comment
    if "path" in headers:
        expected["path"] = name + "/" if member.isdir() else name
    if "linkpath" in headers and member.issym():
        expected["linkpath"] = member.linkname
    return headers == expected


def validate_header_identity(
    member: tarfile.TarInfo, name: str, expected_mtime: int | None
) -> None:
    if member.uid != 0 or member.gid != 0 or member.uname != "root" or member.gname != "root":
        raise ValidationError(f"archive member has non-canonical owner metadata: {name}")
    if member.devmajor != 0 or member.devminor != 0:
        raise ValidationError(f"archive member has non-canonical device metadata: {name}")
    if not isinstance(member.mtime, (int, float)) or member.mtime < 0:
        raise ValidationError(f"archive member has an invalid timestamp: {name}")
    if expected_mtime is not None and member.mtime != expected_mtime:
        raise ValidationError(
            f"archive member timestamp does not match the expected source epoch: {name}"
        )


def read_members(
    archive_stream: BinaryIO,
    expected_comment: str | None,
    git_object_format: str,
    expected_mtime: int | None = None,
) -> tuple[list[ArchiveMember], str]:
    try:
        source = tarfile.open(
            fileobj=archive_stream, mode="r|", tarinfo=BoundedTarInfo
        )
    except (tarfile.TarError, OSError) as exc:
        raise ValidationError(f"source archive is malformed or unsupported: {exc}") from exc

    members: list[ArchiveMember] = []
    seen: set[str] = set()
    roots: set[str] = set()
    expanded_bytes = 0
    total_path_components = 0
    total_path_and_link_bytes = 0
    try:
        if not allowed_global_pax_headers(source.pax_headers, expected_comment):
            raise ValidationError(
                "archive must carry only the expected Git archive comment in its global pax header"
            )
        for member in source:
            if len(members) >= MAX_MEMBERS:
                raise ValidationError("source archive contains too many members")
            name, parts = canonical_member_name(member.name)
            total_path_components += len(parts)
            if total_path_components > MAX_TOTAL_PATH_COMPONENTS:
                raise ValidationError(
                    "archive exceeds the aggregate path-component validation limit"
                )
            total_path_and_link_bytes += len(
                name.encode("utf-8", "surrogateescape")
            )
            if total_path_and_link_bytes > MAX_TOTAL_PATH_AND_LINK_BYTES:
                raise ValidationError(
                    "archive exceeds the aggregate path and link-name byte limit"
                )
            if name in seen:
                raise ValidationError(f"archive contains a duplicate path: {name}")
            seen.add(name)
            roots.add(parts[0])
            if not allowed_member_pax_headers(
                member.pax_headers, expected_comment, member, name
            ):
                raise ValidationError(f"archive member has untrusted pax metadata: {name}")
            validate_header_identity(member, name, expected_mtime)

            if member.type == tarfile.DIRTYPE:
                if member.size != 0:
                    raise ValidationError(
                        f"directory carries a non-canonical payload: {name}"
                    )
                mode = stat.S_IMODE(member.mode)
                if mode not in (0o755, 0o775):
                    raise ValidationError(
                        f"directory has a non-Git archive mode {mode:o}: {name}"
                    )
                record = ArchiveMember(name=name, parts=parts, kind="directory")
            elif member.type == tarfile.REGTYPE:
                mode = stat.S_IMODE(member.mode)
                if mode not in (0o644, 0o664, 0o755, 0o775):
                    raise ValidationError(
                        f"regular file has a non-Git archive mode {mode:o}: {name}"
                    )
                if member.size < 0 or member.size > MAX_FILE_BYTES:
                    raise ValidationError(f"archive member exceeds the file-size limit: {name}")
                expanded_bytes += member.size
                if expanded_bytes > MAX_EXPANDED_BYTES:
                    raise ValidationError("source archive exceeds the expanded-size validation limit")
                stream = source.extractfile(member)
                if stream is None:
                    raise ValidationError(f"could not read regular archive member: {name}")
                try:
                    object_id = hash_git_blob_stream(
                        stream,
                        member.size,
                        git_object_format,
                        member_name=name,
                    )
                finally:
                    stream.close()
                git_mode = "100755" if mode & 0o111 else "100644"
                record = ArchiveMember(
                    name=name,
                    parts=parts,
                    kind="file",
                    mode=git_mode,
                    object_id=object_id,
                )
            elif member.type == tarfile.SYMTYPE:
                if member.size != 0:
                    raise ValidationError(
                        f"symlink carries a non-canonical payload: {name}"
                    )
                if (
                    not member.linkname
                    or "\x00" in member.linkname
                    or "\\" in member.linkname
                    or any(
                        ord(character) < 32 or ord(character) == 127
                        for character in member.linkname
                    )
                ):
                    raise ValidationError(f"archive contains an unsafe symlink target: {name}")
                if len(member.linkname.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES:
                    raise ValidationError(f"archive symlink target is too long: {name}")
                total_path_and_link_bytes += len(
                    member.linkname.encode("utf-8", "surrogateescape")
                )
                if total_path_and_link_bytes > MAX_TOTAL_PATH_AND_LINK_BYTES:
                    raise ValidationError(
                        "archive exceeds the aggregate path and link-name byte limit"
                    )
                if stat.S_IMODE(member.mode) != 0o777:
                    raise ValidationError(f"symlink has a non-Git archive mode: {name}")
                object_id = hash_git_blob_bytes(
                    member.linkname.encode("utf-8", "surrogateescape"),
                    git_object_format,
                )
                record = ArchiveMember(
                    name=name,
                    parts=parts,
                    kind="symlink",
                    mode="120000",
                    object_id=object_id,
                    linkname=member.linkname,
                )
            else:
                raise ValidationError(
                    f"archive contains a non-file, non-directory, non-symlink member: {name}"
                )
            members.append(record)
        tail = source.fileobj.read(MAX_ZERO_TAIL_BYTES + 1)
        if len(tail) > MAX_ZERO_TAIL_BYTES:
            raise ValidationError("source tar has an excessive end-of-archive zero tail")
        if any(tail):
            raise ValidationError(
                "source tar contains non-zero or concatenated content after its end marker"
            )
    except (tarfile.TarError, OSError) as exc:
        raise ValidationError(f"source archive could not be read safely: {exc}") from exc
    finally:
        source.close()

    if len(roots) != 1:
        raise ValidationError("source archive must contain exactly one top-level root")
    root = next(iter(roots))
    root_entries = [entry for entry in members if entry.name == root]
    if len(root_entries) != 1 or root_entries[0].kind != "directory":
        raise ValidationError("source archive must contain one explicit top-level directory")

    kinds = {member.name: member.kind for member in members}
    nonempty_directories = {
        member.name.rpartition("/")[0]
        for member in members
        if "/" in member.name
    }
    for member in members:
        name = member.name
        if "/" in name:
            parent = name.rpartition("/")[0]
            if kinds.get(parent) == "symlink":
                raise ValidationError(f"archive member traverses a symlink parent: {name}")
            if kinds.get(parent) != "directory":
                raise ValidationError(f"archive member has a non-directory parent: {name}")
        if member.kind == "symlink":
            assert member.linkname is not None
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
            if target != root and not target.startswith(root + "/"):
                raise ValidationError(f"archive symlink escapes the top-level root: {name}")

    for member in members:
        name = member.name
        if member.kind != "directory" or name == root:
            continue
        if name not in nonempty_directories:
            raise ValidationError(f"archive contains an untracked empty directory: {name}")
    return members, root


def new_git_hasher(git_object_format: str):
    if git_object_format == "sha1":
        return hashlib.sha1()
    if git_object_format == "sha256":
        return hashlib.sha256()
    raise ValidationError(f"unsupported Git object format: {git_object_format}")


def hash_git_object(kind: str, content: bytes, git_object_format: str) -> str:
    digest = new_git_hasher(git_object_format)
    digest.update(f"{kind} {len(content)}\0".encode("ascii"))
    digest.update(content)
    return digest.hexdigest()


def hash_git_blob_stream(
    stream: BinaryIO,
    expected_size: int,
    git_object_format: str,
    *,
    member_name: str,
) -> str:
    digest = new_git_hasher(git_object_format)
    digest.update(f"blob {expected_size}\0".encode("ascii"))
    copied = 0
    while copied < expected_size:
        chunk = stream.read(min(COPY_CHUNK_BYTES, expected_size - copied))
        if not chunk:
            raise ValidationError(f"archive member ended before its header size: {member_name}")
        copied += len(chunk)
        digest.update(chunk)
    if stream.read(1):
        raise ValidationError(f"archive member expanded past its header size: {member_name}")
    return digest.hexdigest()


def hash_git_blob_bytes(data: bytes, git_object_format: str) -> str:
    return hash_git_object("blob", data, git_object_format)


def member_name_bytes(name: str) -> bytes:
    return name.encode("utf-8", "surrogateescape")


def build_tree(members: list[ArchiveMember], archive_root: str) -> TreeNode:
    root = TreeNode()
    directories = sorted(
        (member for member in members if member.kind == "directory" and member.name != archive_root),
        key=lambda member: (len(member.parts), member.name),
    )
    for member in directories:
        node = root
        for part in member.parts[1:]:
            key = member_name_bytes(part)
            existing = node.children.get(key)
            if existing is None:
                child = TreeNode()
                node.children[key] = child
                node = child
            elif isinstance(existing, TreeNode):
                node = existing
            else:
                raise ValidationError(f"archive path collides with a non-directory: {member.name}")

    for member in members:
        if member.kind == "directory":
            continue
        node = root
        for part in member.parts[1:-1]:
            key = member_name_bytes(part)
            existing = node.children.get(key)
            if not isinstance(existing, TreeNode):
                raise ValidationError(f"archive member has a non-directory parent: {member.name}")
            node = existing
        leaf = member_name_bytes(member.parts[-1])
        if leaf in node.children:
            raise ValidationError(f"archive contains a path type collision: {member.name}")
        node.children[leaf] = member
    return root


def write_tree(node: TreeNode, git_object_format: str) -> str:
    # Use an explicit post-order stack. A valid 4096-byte Git path can contain
    # more components than Python's recursion limit, and validation must fail
    # deterministically rather than raising RecursionError.
    stack: list[tuple[TreeNode, bool]] = [(node, False)]
    object_ids: dict[int, str] = {}
    aggregate_tree_content_bytes = 0
    while stack:
        current, ready = stack.pop()
        if not ready:
            stack.append((current, True))
            for child in current.children.values():
                if isinstance(child, TreeNode):
                    stack.append((child, False))
            continue

        entries: list[tuple[bytes, bool, bytes, bytes]] = []
        for name, child in current.children.items():
            if isinstance(child, TreeNode):
                child_object_id = object_ids.get(id(child))
                if child_object_id is None:
                    raise ValidationError("archive tree reconstruction order is incomplete")
                entries.append((name, True, b"40000", bytes.fromhex(child_object_id)))
            else:
                if child.mode is None or child.object_id is None:
                    raise ValidationError(
                        f"archive member has incomplete Git identity: {child.name}"
                    )
                entries.append(
                    (name, False, child.mode.encode("ascii"), bytes.fromhex(child.object_id))
                )

        entries.sort(key=lambda entry: entry[0] + (b"/" if entry[1] else b""))
        records = [
            mode + b" " + name + b"\0" + object_id
            for name, _, mode, object_id in entries
        ]
        content_size = sum(map(len, records))
        aggregate_tree_content_bytes += content_size
        if aggregate_tree_content_bytes > MAX_TREE_CONTENT_BYTES:
            raise ValidationError(
                "archive exceeds the aggregate Git tree-content byte limit"
            )
        digest = new_git_hasher(git_object_format)
        digest.update(f"tree {content_size}\0".encode("ascii"))
        for record in records:
            digest.update(record)
        object_ids[id(current)] = digest.hexdigest()
    return object_ids[id(node)]


def validate_kernel(
    args: argparse.Namespace,
    members: list[ArchiveMember],
    archive_root: str,
    git_object_format: str,
) -> list[str]:
    expected_tree = validate_object_id(args.expected_tree, "expected kernel tree ID")
    actual_tree = write_tree(build_tree(members, archive_root), git_object_format)
    if actual_tree != expected_tree:
        raise ValidationError(
            f"kernel source archive tree ID {actual_tree} does not match {expected_tree}"
        )
    return [f"Archive root: {archive_root}", f"Kernel tree ID: {actual_tree}"]


def validate_touchscreen(
    args: argparse.Namespace,
    members: list[ArchiveMember],
    archive_root: str,
    git_object_format: str,
) -> list[str]:
    expected_tree = validate_object_id(args.expected_modules_tree, "expected modules tree ID")
    expected_license = validate_object_id(args.expected_license_blob, "expected licence blob ID")
    if object_format(expected_tree) != object_format(expected_license):
        raise ValidationError("touchscreen source object IDs use mixed Git object formats")
    if args.license_mode != "100644":
        raise ValidationError("touchscreen licence mode contract must be 100644")

    expected_prefixes = {"LICENSE", "phase55", "phase55/modules"}
    actual_relative: set[str] = set()
    for member in members:
        relative = "/".join(member.parts[1:])
        if not relative:
            continue
        actual_relative.add(relative)
        if relative not in expected_prefixes and not relative.startswith("phase55/modules/"):
            raise ValidationError(f"touchscreen archive contains an out-of-contract path: {relative}")
    if not expected_prefixes.issubset(actual_relative):
        raise ValidationError("touchscreen archive must contain LICENSE and complete phase55/modules")
    by_relative = {"/".join(member.parts[1:]): member for member in members}
    license_member = by_relative["LICENSE"]
    if license_member.kind != "file" or license_member.mode != "100644":
        raise ValidationError("touchscreen archive has invalid required source path types")
    if by_relative["phase55"].kind != "directory" or by_relative["phase55/modules"].kind != "directory":
        raise ValidationError("touchscreen archive has invalid required source path types")

    root_tree = build_tree(members, archive_root)
    phase55 = root_tree.children.get(b"phase55")
    if not isinstance(phase55, TreeNode):
        raise ValidationError("touchscreen archive has invalid phase55 directory identity")
    modules_tree = phase55.children.get(b"modules")
    if not isinstance(modules_tree, TreeNode):
        raise ValidationError("touchscreen archive has invalid modules directory identity")
    actual_tree = write_tree(modules_tree, git_object_format)
    if actual_tree != expected_tree:
        raise ValidationError(
            f"touchscreen modules tree ID {actual_tree} does not match {expected_tree}"
        )
    actual_license = license_member.object_id
    if actual_license != expected_license:
        raise ValidationError(
            f"touchscreen licence blob ID {actual_license} does not match {expected_license}"
        )
    return [
        f"Archive root: {archive_root}",
        f"Touchscreen modules tree ID: {actual_tree}",
        f"Touchscreen licence blob ID: {actual_license}",
    ]


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)

    kernel = subparsers.add_parser("kernel")
    kernel.add_argument("--archive", required=True, type=Path)
    kernel.add_argument("--expected-tree", required=True)
    kernel.add_argument("--expected-archive-comment")
    kernel.add_argument("--expected-mtime")
    kernel.add_argument("--archive-fd", type=int, help=argparse.SUPPRESS)

    touchscreen = subparsers.add_parser("touchscreen")
    touchscreen.add_argument("--archive", required=True, type=Path)
    touchscreen.add_argument("--expected-modules-tree", required=True)
    touchscreen.add_argument("--expected-license-blob", required=True)
    touchscreen.add_argument("--license-mode", required=True)
    touchscreen.add_argument("--expected-archive-comment", required=True)
    touchscreen.add_argument("--archive-fd", type=int, help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    if not sys.flags.isolated:
        raise ValidationError(
            "source archive validator must be invoked with Python isolated mode (-I)"
        )
    args = parse_arguments()
    comment = None
    if args.expected_archive_comment is not None:
        comment = validate_object_id(args.expected_archive_comment, "expected Git archive comment")
    if args.mode == "kernel":
        expected_object_id = validate_object_id(args.expected_tree, "expected kernel tree ID")
        if comment is not None and object_format(comment) != object_format(expected_object_id):
            raise ValidationError(
                "kernel source commit and tree identities use mixed Git object formats"
            )
        if args.expected_mtime is not None:
            if not re.fullmatch(r"[1-9][0-9]{0,9}", args.expected_mtime):
                raise ValidationError("expected source epoch must be canonical decimal")
            args.expected_mtime = int(args.expected_mtime)
            if args.expected_mtime > 4_102_444_799:
                raise ValidationError(
                    "expected source epoch must be a bounded Unix timestamp before 2100 UTC"
                )
    else:
        expected_object_id = validate_object_id(
            args.expected_modules_tree, "expected modules tree ID"
        )
        expected_license = validate_object_id(
            args.expected_license_blob, "expected licence blob ID"
        )
        if object_format(expected_object_id) != object_format(expected_license):
            raise ValidationError("touchscreen source object IDs use mixed Git object formats")
        if comment is None or object_format(comment) != object_format(expected_object_id):
            raise ValidationError(
                "touchscreen source commit and object identities use mixed Git object formats"
            )
    with pinned_archive_stream(args.archive, args.archive_fd) as captured_archive:
        git_object_format = object_format(expected_object_id)
        expanded_stream = SingleXZReader(captured_archive)
        members, archive_root = read_members(
            expanded_stream,
            comment,
            git_object_format,
            args.expected_mtime if args.mode == "kernel" else None,
        )
        if args.mode == "kernel":
            lines = validate_kernel(args, members, archive_root, git_object_format)
        else:
            lines = validate_touchscreen(
                args, members, archive_root, git_object_format
            )
    print("Validated patched-source archive technical structure, tree identity, and metadata.")
    for line in lines:
        print(line)
    if args.mode == "kernel" and args.expected_mtime is not None:
        print(f"Archive source epoch: {args.expected_mtime}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
    except Exception as error:
        print(
            f"error: source archive validation failed safely ({type(error).__name__})",
            file=sys.stderr,
        )
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("error: source archive validation interrupted safely", file=sys.stderr)
        raise SystemExit(1)
