#!/usr/bin/env python3
"""Capture or validate an exact no-follow release-directory tree state."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import NoReturn


SCHEMA = "sp11-release-tree-state-v1"
MAX_ENTRIES = 100_000
MAX_BYTES = 8 * 1024 * 1024 * 1024


def fail(message: str) -> NoReturn:
    raise SystemExit(f"error: {message}")


def regular_hash(path: Path, label: str) -> tuple[int, int, int, int, int, int, str]:
    try:
        path_before = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISREG(path_before.st_mode):
        fail(f"{label} is not a regular non-symlinked file")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        fail(f"could not open {label} without following links: {exc}")
    digest = hashlib.sha256()
    try:
        before = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (path_before.st_dev, path_before.st_ino):
            fail(f"{label} changed before its descriptor was opened")
        for chunk in iter(lambda: os.read(descriptor, 1024 * 1024), b""):
            digest.update(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        path_after = path.lstat()
    except OSError as exc:
        fail(f"could not re-inspect {label}: {exc}")
    identity = (
        before.st_dev,
        before.st_ino,
        stat.S_IMODE(before.st_mode),
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    if identity != (
        after.st_dev,
        after.st_ino,
        stat.S_IMODE(after.st_mode),
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    ) or identity != (
        path_after.st_dev,
        path_after.st_ino,
        stat.S_IMODE(path_after.st_mode),
        path_after.st_size,
        path_after.st_mtime_ns,
        path_after.st_ctime_ns,
    ):
        fail(f"{label} changed while it was hashed")
    return (*identity, digest.hexdigest())


def regular_read(path: Path, label: str, maximum: int) -> bytes:
    try:
        path_before = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISREG(path_before.st_mode):
        fail(f"{label} is not a regular non-symlinked file")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        fail(f"could not open {label} without following links: {exc}")
    chunks: list[bytes] = []
    total = 0
    try:
        before = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (path_before.st_dev, path_before.st_ino):
            fail(f"{label} changed before its descriptor was opened")
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                fail(f"{label} exceeds its size limit")
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        path_after = path.lstat()
    except OSError as exc:
        fail(f"could not re-inspect {label}: {exc}")
    identity = (
        before.st_dev,
        before.st_ino,
        stat.S_IMODE(before.st_mode),
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    if identity != (
        after.st_dev,
        after.st_ino,
        stat.S_IMODE(after.st_mode),
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    ) or identity != (
        path_after.st_dev,
        path_after.st_ino,
        stat.S_IMODE(path_after.st_mode),
        path_after.st_size,
        path_after.st_mtime_ns,
        path_after.st_ctime_ns,
    ):
        fail(f"{label} changed while it was read")
    return b"".join(chunks)


def encoded_path(parts: tuple[str, ...]) -> str:
    raw = b"/".join(os.fsencode(part) for part in parts)
    return base64.b64encode(raw).decode("ascii")


def tree_state(root: Path) -> dict[str, object]:
    try:
        root_metadata = root.lstat()
    except OSError as exc:
        fail(f"could not inspect release tree root: {exc}")
    if not stat.S_ISDIR(root_metadata.st_mode) or root.is_symlink():
        fail("release tree root must be a real directory")
    entries: list[dict[str, object]] = []
    total_bytes = 0

    def visit(directory: Path, parts: tuple[str, ...]) -> None:
        nonlocal total_bytes
        try:
            children = sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name))
        except OSError as exc:
            fail(f"could not enumerate release tree: {exc}")
        for child in children:
            child_path = directory / child.name
            child_parts = (*parts, child.name)
            try:
                metadata = child.stat(follow_symlinks=False)
            except OSError as exc:
                fail(f"could not inspect release tree entry: {exc}")
            common = {
                "path_b64": encoded_path(child_parts),
                "device": metadata.st_dev,
                "inode": metadata.st_ino,
                "mode": stat.S_IMODE(metadata.st_mode),
            }
            if stat.S_ISDIR(metadata.st_mode) and not child.is_symlink():
                entries.append(
                    {
                        **common,
                        "kind": "directory",
                        "mtime_ns": metadata.st_mtime_ns,
                        "ctime_ns": metadata.st_ctime_ns,
                    }
                )
                visit(child_path, child_parts)
                try:
                    directory_after = child.stat(follow_symlinks=False)
                except OSError as exc:
                    fail(f"could not re-inspect release tree directory: {exc}")
                if (
                    directory_after.st_dev,
                    directory_after.st_ino,
                    stat.S_IMODE(directory_after.st_mode),
                    directory_after.st_mtime_ns,
                    directory_after.st_ctime_ns,
                ) != (
                    metadata.st_dev,
                    metadata.st_ino,
                    stat.S_IMODE(metadata.st_mode),
                    metadata.st_mtime_ns,
                    metadata.st_ctime_ns,
                ):
                    fail("release tree directory changed during traversal")
            elif stat.S_ISREG(metadata.st_mode):
                snapshot = regular_hash(child_path, "release tree file")
                total_bytes += snapshot[3]
                if total_bytes > MAX_BYTES:
                    fail("release tree exceeds the byte limit")
                entries.append(
                    {
                        **common,
                        "kind": "file",
                        "size": snapshot[3],
                        "mtime_ns": snapshot[4],
                        "ctime_ns": snapshot[5],
                        "sha256": snapshot[6],
                    }
                )
            else:
                fail("release tree contains a symlink or special entry")
            if len(entries) > MAX_ENTRIES:
                fail("release tree exceeds the entry limit")

    visit(root, ())
    try:
        root_after = root.lstat()
    except OSError as exc:
        fail(f"could not re-inspect release tree root: {exc}")
    if (
        root_after.st_dev,
        root_after.st_ino,
        stat.S_IMODE(root_after.st_mode),
        root_after.st_mtime_ns,
        root_after.st_ctime_ns,
    ) != (
        root_metadata.st_dev,
        root_metadata.st_ino,
        stat.S_IMODE(root_metadata.st_mode),
        root_metadata.st_mtime_ns,
        root_metadata.st_ctime_ns,
    ):
        fail("release tree root changed during traversal")
    return {
        "schema": SCHEMA,
        "root": {
            "device": root_metadata.st_dev,
            "inode": root_metadata.st_ino,
            "mode": stat.S_IMODE(root_metadata.st_mode),
        },
        "entries": entries,
    }


def serialized(state: dict[str, object]) -> bytes:
    return (json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_snapshot(root: Path, output: Path) -> None:
    first = tree_state(root)
    if tree_state(root) != first:
        fail("release tree changed while its snapshot was captured")
    if output.parent.is_symlink() or not output.parent.is_dir():
        fail("release tree snapshot parent is unsafe")
    if output.is_symlink() or (output.exists() and not output.is_file()):
        fail("release tree snapshot output is unsafe")
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(serialized(first))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
    except OSError as exc:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        fail(f"could not write release tree snapshot: {exc}")


def read_snapshot(path: Path) -> dict[str, object]:
    raw = regular_read(path, "release tree snapshot", 64 * 1024 * 1024)
    if not raw.endswith(b"\n"):
        fail("release tree snapshot must be a regular LF-terminated file")
    try:
        state = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"release tree snapshot is invalid JSON: {exc}")
    if not isinstance(state, dict) or state.get("schema") != SCHEMA:
        fail("release tree snapshot schema is invalid")
    if set(state) != {"schema", "root", "entries"}:
        fail("release tree snapshot fields are not exact")
    return state


def validate_private_container(root: Path, expected_children: list[str]) -> None:
    if len(set(expected_children)) != len(expected_children):
        fail("private-container child names must be unique")
    if any(not child or "/" in child or child in {".", ".."} for child in expected_children):
        fail("private-container child names must be single path components")
    try:
        path_before = root.lstat()
    except OSError as exc:
        fail(f"could not inspect private container: {exc}")
    if not stat.S_ISDIR(path_before.st_mode):
        fail("private container must be a real directory")
    if stat.S_IMODE(path_before.st_mode) != 0o700:
        fail("private container mode must be 0700")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(root, flags)
    except OSError as exc:
        fail(f"could not open private container without following links: {exc}")
    try:
        before = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (path_before.st_dev, path_before.st_ino):
            fail("private container changed before its descriptor was opened")
        with os.scandir(descriptor) as iterator:
            actual_children = sorted(os.fsencode(entry.name) for entry in iterator)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        path_after = root.lstat()
    except OSError as exc:
        fail(f"could not re-inspect private container: {exc}")
    identity = (
        before.st_dev,
        before.st_ino,
        stat.S_IMODE(before.st_mode),
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    if identity != (
        after.st_dev,
        after.st_ino,
        stat.S_IMODE(after.st_mode),
        after.st_mtime_ns,
        after.st_ctime_ns,
    ) or identity != (
        path_after.st_dev,
        path_after.st_ino,
        stat.S_IMODE(path_after.st_mode),
        path_after.st_mtime_ns,
        path_after.st_ctime_ns,
    ):
        fail("private container changed while it was enumerated")
    expected = sorted(os.fsencode(child) for child in expected_children)
    if actual_children != expected:
        fail("private container does not contain the exact expected children")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("snapshot", "validate", "validate-private"))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--child", action="append", default=[])
    args = parser.parse_args()
    if args.mode == "snapshot":
        if args.snapshot is None or args.child:
            fail("snapshot mode requires --snapshot and does not accept --child")
        write_snapshot(args.root, args.snapshot)
        print(f"Captured exact release tree state: {args.root}")
    elif args.mode == "validate":
        if args.snapshot is None or args.child:
            fail("validate mode requires --snapshot and does not accept --child")
        expected = read_snapshot(args.snapshot)
        if tree_state(args.root) != expected or tree_state(args.root) != expected:
            fail("release tree differs from its captured exact state")
        print(f"Validated exact release tree state: {args.root}")
    else:
        if args.snapshot is not None:
            fail("validate-private mode does not accept --snapshot")
        validate_private_container(args.root, args.child)
        print(f"Validated exact private container: {args.root}")


if __name__ == "__main__":
    main()
