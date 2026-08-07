#!/usr/bin/env python3
"""Safely validate corresponding-source archives against Git object IDs."""

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
import tempfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import BinaryIO


MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_EXPANDED_BYTES = 8 * 1024 * 1024 * 1024
MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBERS = 250_000
MAX_PATH_BYTES = 4096
COPY_CHUNK_BYTES = 1024 * 1024
MAX_ZERO_TAIL_BYTES = 1024 * 1024
MAX_XZ_DECODER_MEMORY = 256 * 1024 * 1024
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


def snapshot_archive(archive: Path, scratch: Path) -> Path:
    """Pin one bounded input capture before any multi-pass format validation."""

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(archive, flags)
    except OSError as exc:
        raise ValidationError(
            "source archive must be a non-empty regular, non-symlinked file"
        ) from exc
    snapshot = scratch / "captured-source.tar.xz"
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0:
            raise ValidationError(
                "source archive must be a non-empty regular, non-symlinked file"
            )
        if metadata.st_size > MAX_ARCHIVE_BYTES:
            raise ValidationError("source archive exceeds the compressed-size validation limit")
        copied = 0
        with os.fdopen(descriptor, "rb", closefd=True) as source:
            descriptor = -1
            with snapshot.open("xb") as output:
                while True:
                    chunk = source.read(COPY_CHUNK_BYTES)
                    if not chunk:
                        break
                    copied += len(chunk)
                    if copied > MAX_ARCHIVE_BYTES or copied > metadata.st_size:
                        raise ValidationError(
                            "source archive changed or exceeded the compressed-size validation limit"
                        )
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            final_metadata = os.fstat(source.fileno())
            if copied != metadata.st_size or final_metadata.st_size != metadata.st_size:
                raise ValidationError("source archive changed while it was captured")
        os.chmod(snapshot, 0o400)
        return snapshot
    except OSError as exc:
        raise ValidationError(f"source archive could not be captured safely: {exc}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def decompress_single_xz_stream(source: BinaryIO, destination: Path) -> None:
    decompressor = lzma.LZMADecompressor(
        format=lzma.FORMAT_XZ, memlimit=MAX_XZ_DECODER_MEMORY
    )
    expanded = 0
    try:
        if source.read(6) != b"\xfd7zXZ\x00":
            raise ValidationError("source archive must be one XZ-compressed tar stream")
        source.seek(0)
        with destination.open("xb") as output_file:
            while True:
                chunk = source.read(COPY_CHUNK_BYTES)
                if not chunk:
                    break
                pending = chunk
                while pending or not decompressor.needs_input:
                    output = decompressor.decompress(pending, max_length=COPY_CHUNK_BYTES)
                    pending = b""
                    expanded += len(output)
                    if expanded > MAX_TAR_BYTES:
                        raise ValidationError(
                            "source archive exceeds the expanded-size validation limit"
                        )
                    output_file.write(output)
                    if decompressor.eof:
                        if decompressor.unused_data or source.read(1):
                            raise ValidationError(
                                "source archive contains bytes after its single XZ stream"
                            )
                        output_file.flush()
                        os.fsync(output_file.fileno())
                        os.chmod(destination, 0o400)
                        return
        if not decompressor.eof:
            raise ValidationError("source archive contains a truncated XZ stream")
    except lzma.LZMAError as exc:
        if "memory usage limit" in str(exc).lower():
            raise ValidationError("source archive exceeds the XZ decoder memory limit") from exc
        raise ValidationError(f"source archive has malformed XZ compression: {exc}") from exc


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
    if not parts or any(part in ("", ".", "..") for part in parts):
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


def validate_header_identity(member: tarfile.TarInfo, name: str) -> None:
    if member.uid != 0 or member.gid != 0 or member.uname != "root" or member.gname != "root":
        raise ValidationError(f"archive member has non-canonical owner metadata: {name}")
    if member.devmajor != 0 or member.devminor != 0:
        raise ValidationError(f"archive member has non-canonical device metadata: {name}")
    if not isinstance(member.mtime, (int, float)) or member.mtime < 0:
        raise ValidationError(f"archive member has an invalid timestamp: {name}")


def read_members(
    archive_stream: BinaryIO,
    expected_comment: str | None,
    git_object_format: str,
) -> tuple[list[ArchiveMember], str]:
    try:
        archive_stream.seek(0)
        source = tarfile.open(fileobj=archive_stream, mode="r:")
    except (tarfile.TarError, OSError) as exc:
        raise ValidationError(f"source archive is malformed or unsupported: {exc}") from exc

    members: list[ArchiveMember] = []
    seen: set[str] = set()
    roots: set[str] = set()
    expanded_bytes = 0
    try:
        if not allowed_global_pax_headers(source.pax_headers, expected_comment):
            raise ValidationError(
                "archive must carry only the expected Git archive comment in its global pax header"
            )
        for member in source:
            if len(members) >= MAX_MEMBERS:
                raise ValidationError("source archive contains too many members")
            name, parts = canonical_member_name(member.name)
            if name in seen:
                raise ValidationError(f"archive contains a duplicate path: {name}")
            seen.add(name)
            roots.add(parts[0])
            if not allowed_member_pax_headers(
                member.pax_headers, expected_comment, member, name
            ):
                raise ValidationError(f"archive member has untrusted pax metadata: {name}")
            validate_header_identity(member, name)

            if member.isdir():
                mode = stat.S_IMODE(member.mode)
                if mode not in (0o755, 0o775):
                    raise ValidationError(
                        f"directory has a non-Git archive mode {mode:o}: {name}"
                    )
                record = ArchiveMember(name=name, parts=parts, kind="directory")
            elif member.isreg():
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
            elif member.issym():
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
        source.fileobj.seek(source.offset)
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
        parts = member.parts
        for depth in range(1, len(parts)):
            parent = "/".join(parts[:depth])
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
        tree_content = b"".join(
            mode + b" " + name + b"\0" + object_id
            for name, _, mode, object_id in entries
        )
        object_ids[id(current)] = hash_git_object(
            "tree", tree_content, git_object_format
        )
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

    touchscreen = subparsers.add_parser("touchscreen")
    touchscreen.add_argument("--archive", required=True, type=Path)
    touchscreen.add_argument("--expected-modules-tree", required=True)
    touchscreen.add_argument("--expected-license-blob", required=True)
    touchscreen.add_argument("--license-mode", required=True)
    touchscreen.add_argument("--expected-archive-comment", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    comment = None
    if args.expected_archive_comment is not None:
        comment = validate_object_id(args.expected_archive_comment, "expected Git archive comment")
    if args.mode == "kernel":
        expected_object_id = validate_object_id(args.expected_tree, "expected kernel tree ID")
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
    with tempfile.TemporaryDirectory(prefix="sp11-source-archive.") as temporary:
        temporary_root = Path(temporary)
        captured_archive = snapshot_archive(args.archive, temporary_root)
        captured_tar = temporary_root / "captured-source.tar"
        git_object_format = object_format(expected_object_id)
        with captured_archive.open("rb") as archive_stream:
            decompress_single_xz_stream(archive_stream, captured_tar)
        with captured_tar.open("rb") as archive_stream:
            members, archive_root = read_members(
                archive_stream, comment, git_object_format
            )
        if args.mode == "kernel":
            lines = validate_kernel(args, members, archive_root, git_object_format)
        else:
            lines = validate_touchscreen(
                args, members, archive_root, git_object_format
            )
    print("Validated corresponding-source archive safely.")
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
