#!/usr/bin/env python3
"""Seal and safely import the retained SP11 kernel release-evidence stream.

The release controller assumes exclusive use of its pinned Docker context,
daemon credentials, and random retained-state volume from creation through
terminal import. Concurrent clients with the same Docker authority are outside
this technical containment boundary.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import re
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import BinaryIO, Dict, Iterable, Iterator, List, NoReturn, Optional, Sequence, Set, Tuple


CATALOG_SCHEMA = "sp11-kernel-retained-evidence-v1"
CATALOG_MEMBER = "catalog"
STAGING_NAME = ".sp11-release-export-v1"
OBJECTS_NAME = "objects"
LIST_NAME = "files.nul"
EVIDENCE_TAR_NAME = "sp11-kernel-retained-evidence.tar"
ATTESTATION_NAME = "sp11-kernel-preseal-validation.txt"
ATTESTATION_SCHEMA = "sp11-kernel-preseal-validation-v1"
ATTESTATION_ARGV_SCHEMA = "sp11-kernel-build-inputs-validate-argv-v1"
BUILD_INPUTS_HELPER_PATH = "scripts/sp11-kernel-build-inputs.py"
MANIFEST_VALIDATOR_PATH = "scripts/validate-sp11-image-release-manifests.py"

SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
COMMIT_RE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?\Z")
SAFE_COMPONENT_RE = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+%_~:@=-]{0,254}\Z")
UINT_RE = re.compile(r"0|[1-9][0-9]{0,19}\Z")
DEB_RE = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+_~:@=-]{0,254}\.deb\Z")
CONTAINER_ID_RE = re.compile(r"[0-9a-f]{64}\Z")
RETAINED_VOLUME_RE = re.compile(r"sp11-release-state-[0-9a-f]{32}\Z")
PLATFORM_RE = re.compile(r"linux/(?:amd64|arm64)(?:/v[0-9]+)?\Z")
PINNED_IMAGE_RE = re.compile(r"[^\s@]+@sha256:[0-9a-f]{64}\Z")

MAX_MEMBERS = 4096
MAX_SOURCE_PATH_BYTES = 1024
MAX_SOURCE_PATH_DEPTH = 16
MAX_AGGREGATE_PATH_BYTES = 4 * 1024 * 1024
MAX_MEMBER_BYTES = 4 * 1024 * 1024 * 1024
MAX_TOTAL_PAYLOAD_BYTES = 16 * 1024 * 1024 * 1024
MAX_TAR_BYTES = MAX_TOTAL_PAYLOAD_BYTES + 64 * 1024 * 1024
MAX_CATALOG_BYTES = 4 * 1024 * 1024
MAX_ATTESTATION_BYTES = 4 * 1024 * 1024
MAX_VALIDATOR_ARG_BYTES = 8192
MAX_CONTROL_BYTES = 64 * 1024 * 1024
MAX_TEXT_BYTES = 16 * 1024 * 1024
MAX_CAPTURED_TEXT_BYTES = 16 * 1024 * 1024
MAX_SCHEMA_FIELDS = 32768
MAX_SCHEMA_LINE_BYTES = 8192
MAX_IDLE_SECONDS = 15.0
MAX_STARTUP_SECONDS = 180.0
MAX_TOTAL_SECONDS = 60 * 60.0
MAX_DIAGNOSTIC_BYTES = 64 * 1024
MAX_BUILD_LOG_BYTES = 1024 * 1024 * 1024
MAX_BUILD_SECONDS = 8 * 60 * 60.0

VALIDATED_ROOT_PAYLOAD_FILES = (
    "sp11-apt-bootstrap-state.txt",
    "sp11-apt-installed-post.txt",
    "sp11-apt-installed-pre.txt",
)
ROOT_PAYLOAD_FILES = (*VALIDATED_ROOT_PAYLOAD_FILES, ATTESTATION_NAME)
CONTROL_FILES = (
    ("Docker build arguments", "docker-build-args.txt"),
    ("Docker entrypoint", "docker-build-inside.sh"),
    ("OCI index", "sp11-oci-index.json"),
)
WORK_COMPANION_NAMES = tuple(name for _label, name in CONTROL_FILES)
FIXED_ARTIFACTS = (
    "sp11-kernel-apt-provenance.txt",
    "sp11-kernel-build-inputs.txt",
    "sp11-kernel-build-manifest.txt",
    "sp11-kernel-debs.txt",
    "sp11-kernel-module-signatures.txt",
)
INPUT_ROLES = (
    "docker-build-arguments",
    "docker-entrypoint",
    "oci-index",
    "kernel-build-manifest-v2",
    "apt-provenance-v1",
)


class ReleaseStateError(Exception):
    """A path-neutral, expected release-state refusal."""


class ReleaseStateQuit(KeyboardInterrupt):
    """A handled SIGQUIT that retains its conventional exit status."""


def refuse(message: str) -> NoReturn:
    raise ReleaseStateError(message)


def parse_uint(value: str, label: str, maximum: int) -> int:
    if not UINT_RE.fullmatch(value):
        refuse(label + " is not a canonical unsigned integer")
    parsed = int(value, 10)
    if parsed > maximum:
        refuse(label + " exceeds its limit")
    return parsed


def safe_source_path(value: str, label: str) -> str:
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError:
        refuse(label + " is not ASCII")
    if (
        not encoded
        or len(encoded) > MAX_SOURCE_PATH_BYTES
        or value.startswith("/")
        or value.endswith("/")
        or "//" in value
        or "\\" in value
    ):
        refuse(label + " is not a bounded canonical relative path")
    parts = value.split("/")
    if len(parts) > MAX_SOURCE_PATH_DEPTH:
        refuse(label + " exceeds the path-depth limit")
    if any(part in ("", ".", "..") or not SAFE_COMPONENT_RE.fullmatch(part) for part in parts):
        refuse(label + " contains an unsafe path component")
    if PurePosixPath(value).as_posix() != value:
        refuse(label + " is not canonical")
    return value


def safe_basename(value: str, label: str) -> str:
    safe_source_path(value, label)
    if "/" in value:
        refuse(label + " must be a basename")
    return value


def parse_fields(
    raw: bytes,
    label: str,
    maximum: int = MAX_TEXT_BYTES,
    maximum_fields: int = MAX_SCHEMA_FIELDS,
) -> Dict[str, str]:
    if not raw or len(raw) > maximum or not raw.endswith(b"\n"):
        refuse(label + " must be non-empty, bounded, and LF-terminated")
    if b"\x00" in raw or b"\r" in raw:
        refuse(label + " contains a NUL or CR byte")
    field_count = raw.count(b"\n")
    if field_count == 0 or field_count > maximum_fields:
        refuse(label + " exceeds its field-count limit")
    fields: Dict[str, str] = {}
    position = 0
    while position < len(raw):
        end = raw.find(b"\n", position)
        if end < 0:
            refuse(label + " is not LF-terminated")
        encoded_line = raw[position:end]
        position = end + 1
        if not encoded_line or len(encoded_line) > MAX_SCHEMA_LINE_BYTES:
            refuse(label + " contains an empty or oversized field")
        try:
            line = encoded_line.decode("ascii")
        except UnicodeDecodeError:
            refuse(label + " is not ASCII")
        if ": " not in line:
            refuse(label + " contains a non-schema line")
        key, value = line.split(": ", 1)
        if (
            not key
            or not value
            or key in fields
            or any(ord(character) < 32 or ord(character) > 126 for character in line)
        ):
            refuse(label + " contains an empty, duplicate, or unsafe field")
        fields[key] = value
    return fields


def required(fields: Dict[str, str], key: str, label: str) -> str:
    value = fields.get(key, "")
    if not value:
        refuse(label + " is missing required field " + key)
    return value


@dataclass(frozen=True)
class Snapshot:
    size: int
    sha256: str


@dataclass(frozen=True)
class AttestedInput:
    path: str
    kind: str
    mode: str
    snapshot: Snapshot


@dataclass(frozen=True)
class CatalogEntry:
    archive_path: str
    source_path: str
    size: int
    sha256: str


@dataclass
class ScanBudget:
    entries: int = 0
    path_bytes: int = 0
    payload_bytes: int = 0


def digest_descriptor(descriptor: int, maximum: int) -> Snapshot:
    metadata_before = os.fstat(descriptor)
    if not stat.S_ISREG(metadata_before.st_mode) or metadata_before.st_size > maximum:
        refuse("release-state member is non-regular or oversized")
    digest = hashlib.sha256()
    offset = 0
    while offset < metadata_before.st_size:
        chunk = os.pread(descriptor, min(1024 * 1024, metadata_before.st_size - offset), offset)
        if not chunk:
            refuse("release-state member ended before its recorded size")
        digest.update(chunk)
        offset += len(chunk)
    metadata_after = os.fstat(descriptor)
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
    )
    if stable(metadata_before) != stable(metadata_after):
        refuse("release-state member changed while it was hashed")
    return Snapshot(metadata_before.st_size, digest.hexdigest())


def open_regular_at(parent: int, name: str, maximum: int) -> Tuple[int, Snapshot]:
    safe_basename(name, "release-state filename")
    required_flags = ("O_CLOEXEC", "O_NOFOLLOW", "O_NONBLOCK")
    if any(not hasattr(os, flag) for flag in required_flags):
        refuse("required no-follow open flags are unavailable")
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        dir_fd=parent,
    )
    try:
        mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
        held = os.fstat(descriptor)
        if (
            not stat.S_ISREG(held.st_mode)
            or not stat.S_ISREG(mapped.st_mode)
            or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            refuse("release-state filename does not map to its held regular inode")
        return descriptor, digest_descriptor(descriptor, maximum)
    except BaseException:
        os.close(descriptor)
        raise


def open_path_beneath(root: int, relative: str, maximum: int) -> Tuple[int, Snapshot]:
    safe_source_path(relative, "release-state source path")
    components = relative.split("/")
    current = os.dup(root)
    try:
        for component in components[:-1]:
            child = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=current,
            )
            metadata = os.fstat(child)
            mapped = os.stat(component, dir_fd=current, follow_symlinks=False)
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or not stat.S_ISDIR(mapped.st_mode)
                or (metadata.st_dev, metadata.st_ino) != (mapped.st_dev, mapped.st_ino)
            ):
                os.close(child)
                refuse("release-state source directory changed during traversal")
            os.close(current)
            current = child
        return open_regular_at(current, components[-1], maximum)
    finally:
        os.close(current)


def read_descriptor(descriptor: int, maximum: int) -> bytes:
    snapshot = digest_descriptor(descriptor, maximum)
    data = bytearray()
    offset = 0
    while offset < snapshot.size:
        chunk = os.pread(descriptor, min(64 * 1024, snapshot.size - offset), offset)
        if not chunk:
            refuse("release-state text ended unexpectedly")
        data.extend(chunk)
        offset += len(chunk)
    if hashlib.sha256(data).hexdigest() != snapshot.sha256:
        refuse("release-state text changed during its bounded read")
    return bytes(data)


def scan_regular_tree(root: Path, prefix: str, budget: ScanBudget) -> Dict[str, Snapshot]:
    records: Dict[str, Snapshot] = {}

    def visit(directory: Path, relative_prefix: str, depth: int) -> None:
        if depth > MAX_SOURCE_PATH_DEPTH:
            refuse("release-state directory tree exceeds its depth limit")
        try:
            entries = []
            remaining_budget = MAX_MEMBERS * 2 - budget.entries
            with os.scandir(directory) as iterator:
                for entry in iterator:
                    if len(entries) >= remaining_budget:
                        refuse("release-state tree exceeds its entry limit")
                    entries.append(entry)
            entries.sort(key=lambda item: item.name)
        except OSError:
            refuse("release-state directory could not be enumerated")
        for entry in entries:
            budget.entries += 1
            if budget.entries > MAX_MEMBERS * 2:
                refuse("release-state tree exceeds its entry limit")
            relative = entry.name if not relative_prefix else relative_prefix + "/" + entry.name
            logical = prefix + "/" + relative
            safe_source_path(logical, "release-state tree path")
            budget.path_bytes += len(logical.encode("ascii"))
            if budget.path_bytes > MAX_AGGREGATE_PATH_BYTES:
                refuse("release-state tree exceeds its aggregate path-byte limit")
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError:
                refuse("release-state tree entry could not be inspected")
            if stat.S_ISDIR(metadata.st_mode):
                visit(Path(entry.path), relative, depth + 1)
                continue
            if not stat.S_ISREG(metadata.st_mode):
                refuse("release-state tree contains a link or special entry")
            descriptor = os.open(
                entry.path,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            )
            try:
                snapshot = digest_descriptor(descriptor, MAX_MEMBER_BYTES)
            finally:
                os.close(descriptor)
            budget.payload_bytes += snapshot.size
            if budget.payload_bytes > MAX_TOTAL_PAYLOAD_BYTES:
                refuse("release-state tree exceeds its aggregate byte limit")
            records[logical] = snapshot

    visit(root, "", 1)
    return records


def scan_preseal_attested_inputs(work: Path) -> Tuple[AttestedInput, ...]:
    """Recompute the complete managed /work state that terminal validation attests."""

    rows: List[AttestedInput] = []
    budget = ScanBudget()
    directory_marker = Snapshot(0, "-")

    def add_path_bytes(path: str) -> None:
        safe_source_path(path, "pre-seal attested path")
        budget.path_bytes += len(path.encode("ascii"))
        if budget.path_bytes > MAX_AGGREGATE_PATH_BYTES:
            refuse("pre-seal attested paths exceed their aggregate limit")

    def visit(directory: Path, logical: str, depth: int) -> None:
        if depth > MAX_SOURCE_PATH_DEPTH:
            refuse("pre-seal attested tree exceeds its depth limit")
        add_path_bytes(logical)
        try:
            directory_metadata = directory.lstat()
        except OSError:
            refuse("pre-seal attested directory could not be inspected")
        if not stat.S_ISDIR(directory_metadata.st_mode) or directory.is_symlink():
            refuse("pre-seal attested directory is not a real directory")
        rows.append(
            AttestedInput(
                logical,
                "directory",
                "%04o" % stat.S_IMODE(directory_metadata.st_mode),
                directory_marker,
            )
        )
        try:
            entries: List[os.DirEntry[str]] = []
            remaining = MAX_MEMBERS * 2 - budget.entries
            with os.scandir(directory) as iterator:
                for entry in iterator:
                    if len(entries) >= remaining:
                        refuse("pre-seal attested tree exceeds its entry limit")
                    entries.append(entry)
            entries.sort(key=lambda item: item.name)
        except OSError:
            refuse("pre-seal attested directory could not be enumerated")
        for entry in entries:
            budget.entries += 1
            if budget.entries > MAX_MEMBERS * 2:
                refuse("pre-seal attested tree exceeds its entry limit")
            child_logical = logical + "/" + entry.name
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError:
                refuse("pre-seal attested entry could not be inspected")
            if stat.S_ISDIR(metadata.st_mode):
                visit(Path(entry.path), child_logical, depth + 1)
                continue
            if not stat.S_ISREG(metadata.st_mode):
                refuse("pre-seal attested tree contains a link or special entry")
            add_path_bytes(child_logical)
            descriptor = os.open(
                entry.path,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            )
            try:
                snapshot = digest_descriptor(descriptor, MAX_MEMBER_BYTES)
            finally:
                os.close(descriptor)
            budget.payload_bytes += snapshot.size
            if budget.payload_bytes > MAX_TOTAL_PAYLOAD_BYTES:
                refuse("pre-seal attested tree exceeds its aggregate byte limit")
            rows.append(
                AttestedInput(
                    child_logical,
                    "regular",
                    "%04o" % stat.S_IMODE(metadata.st_mode),
                    snapshot,
                )
            )

    for root_name in ("apt-archives", "apt-indexes", "apt-lists", "artifacts"):
        root = work / root_name
        if root.is_symlink() or not root.is_dir():
            refuse("pre-seal attested managed root is missing or symlinked")
        visit(root, root_name, 1)

    for name in (*VALIDATED_ROOT_PAYLOAD_FILES, *WORK_COMPANION_NAMES):
        add_path_bytes(name)
        descriptor = os.open(
            work / name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        )
        try:
            metadata = os.fstat(descriptor)
            snapshot = digest_descriptor(descriptor, MAX_MEMBER_BYTES)
        finally:
            os.close(descriptor)
        budget.payload_bytes += snapshot.size
        if budget.payload_bytes > MAX_TOTAL_PAYLOAD_BYTES:
            refuse("pre-seal attested inputs exceed their aggregate byte limit")
        rows.append(
            AttestedInput(
                name,
                "regular",
                "%04o" % stat.S_IMODE(metadata.st_mode),
                snapshot,
            )
        )

    ordered = tuple(sorted(rows, key=lambda row: row.path))
    if len(ordered) != len({row.path for row in ordered}):
        refuse("pre-seal attested input paths are duplicated")
    return ordered


def read_path(path: Path, maximum: int, label: str) -> Tuple[bytes, Snapshot]:
    if path.is_symlink():
        refuse(label + " is symlinked")
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        snapshot = digest_descriptor(descriptor, maximum)
        return read_descriptor(descriptor, maximum), snapshot
    finally:
        os.close(descriptor)


def expect_entry(records: Dict[str, Snapshot], path: str, size: str, digest: str, label: str) -> None:
    safe_source_path(path, label + " path")
    expected_size = parse_uint(size, label + " size", MAX_MEMBER_BYTES)
    if not SHA256_RE.fullmatch(digest):
        refuse(label + " SHA256 is not canonical")
    actual = records.get(path)
    if actual != Snapshot(expected_size, digest):
        refuse(label + " does not bind the retained evidence bytes")


def expected_attested_regulars(
    records: Dict[str, Snapshot],
    controls: Dict[str, Snapshot],
) -> Dict[str, Snapshot]:
    expected = {
        path: snapshot
        for path, snapshot in records.items()
        if path != ATTESTATION_NAME
    }
    for label, name in CONTROL_FILES:
        expected[name] = controls[label]
    return expected


def canonical_attested_directories(
    regular_paths: Iterable[str],
) -> Tuple[Set[str], Set[str]]:
    required_directories: Set[str] = {
        "apt-archives",
        "apt-indexes",
        "apt-lists",
        "artifacts",
    }
    for path in regular_paths:
        parts = path.split("/")
        if parts[0] not in required_directories:
            continue
        for index in range(1, len(parts)):
            required_directories.add("/".join(parts[:index]))
    optional_empty = {
        "apt-archives/partial",
        "apt-lists/auxfiles",
        "apt-lists/partial",
    }
    return required_directories, optional_empty


def parse_preseal_attestation(
    raw: bytes,
    args: argparse.Namespace,
    records: Dict[str, Snapshot],
    controls: Dict[str, Snapshot],
    exact_rows: Optional[Tuple[AttestedInput, ...]] = None,
) -> Tuple[AttestedInput, ...]:
    fields = parse_fields(
        raw,
        "pre-seal validation attestation",
        MAX_ATTESTATION_BYTES,
    )
    expected_keys = [
        "Kernel pre-seal validation schema",
        "Validation mode",
        "Python isolated mode",
        "Validator argv schema",
        "Git object format",
        "Validator argv count",
    ]
    argv_count = parse_uint(
        required(fields, "Validator argv count", "pre-seal validation attestation"),
        "validator argv count",
        128,
    )
    if argv_count < 4:
        refuse("pre-seal validation attestation has an incomplete validator argv")
    argv: List[str] = []
    for index in range(1, argv_count + 1):
        key = "Validator argv %d" % index
        expected_keys.append(key)
        value = required(fields, key, "pre-seal validation attestation")
        if (
            len(value.encode("ascii")) > MAX_VALIDATOR_ARG_BYTES
            or "\x00" in value
            or any(ord(character) < 32 or ord(character) > 126 for character in value)
        ):
            refuse("pre-seal validation argv contains an unsafe value")
        argv.append(value)
    expected_keys.extend(
        (
            "Support HEAD",
            "Kernel baseline SHA256",
            "Container image",
            "Container platform",
            "Build-inputs helper path",
            "Build-inputs helper Git mode",
            "Build-inputs helper runtime mode",
            "Build-inputs helper size",
            "Build-inputs helper SHA256",
            "Build-inputs helper Git object ID",
            "Build-inputs helper object format",
            "Manifest validator path",
            "Manifest validator Git mode",
            "Manifest validator runtime mode",
            "Manifest validator size",
            "Manifest validator SHA256",
            "Manifest validator Git object ID",
            "Manifest validator object format",
            "Validated input count",
        )
    )
    row_count = parse_uint(
        required(fields, "Validated input count", "pre-seal validation attestation"),
        "validated input count",
        MAX_MEMBERS * 2 + 16,
    )
    rows: List[AttestedInput] = []
    previous = ""
    aggregate_path_bytes = 0
    for index in range(1, row_count + 1):
        keys = [
            "Validated input %d path" % index,
            "Validated input %d type" % index,
            "Validated input %d mode" % index,
            "Validated input %d size" % index,
            "Validated input %d SHA256" % index,
        ]
        expected_keys.extend(keys)
        path = safe_source_path(
            required(fields, keys[0], "pre-seal validation attestation"),
            "validated input path",
        )
        if previous and path <= previous:
            refuse("pre-seal validation input rows are not unique and ordered")
        previous = path
        aggregate_path_bytes += len(path.encode("ascii"))
        if aggregate_path_bytes > MAX_AGGREGATE_PATH_BYTES:
            refuse("pre-seal validation input paths exceed their aggregate limit")
        kind = required(fields, keys[1], "pre-seal validation attestation")
        mode = required(fields, keys[2], "pre-seal validation attestation")
        size_value = required(fields, keys[3], "pre-seal validation attestation")
        digest = required(fields, keys[4], "pre-seal validation attestation")
        if not re.fullmatch(r"0[0-7]{3}", mode):
            refuse("pre-seal validation input mode is not canonical")
        size = parse_uint(size_value, "validated input size", MAX_MEMBER_BYTES)
        if kind == "directory":
            if size != 0 or digest != "-" or mode not in ("0700", "0755"):
                refuse("pre-seal validation directory row is invalid")
        elif kind == "regular":
            if not SHA256_RE.fullmatch(digest):
                refuse("pre-seal validation regular SHA256 is not canonical")
        else:
            refuse("pre-seal validation input type is unsupported")
        rows.append(AttestedInput(path, kind, mode, Snapshot(size, digest)))
    expected_keys.append("Validation complete")
    if list(fields) != expected_keys:
        refuse("pre-seal validation attestation field set/order is invalid")

    fixed_values = {
        "Kernel pre-seal validation schema": ATTESTATION_SCHEMA,
        "Validation mode": "validate",
        "Python isolated mode": "true",
        "Validator argv schema": ATTESTATION_ARGV_SCHEMA,
        "Git object format": args.git_object_format,
        "Support HEAD": args.support_head,
        "Kernel baseline SHA256": args.baseline_sha256,
        "Container image": args.container_image,
        "Container platform": args.container_platform,
        "Build-inputs helper path": BUILD_INPUTS_HELPER_PATH,
        "Build-inputs helper Git mode": "100755",
        "Build-inputs helper runtime mode": "0755",
        "Build-inputs helper SHA256": args.build_inputs_helper_sha256,
        "Build-inputs helper Git object ID": args.build_inputs_helper_object_id,
        "Build-inputs helper object format": args.git_object_format,
        "Manifest validator path": MANIFEST_VALIDATOR_PATH,
        "Manifest validator Git mode": "100644",
        "Manifest validator runtime mode": "0644",
        "Manifest validator SHA256": args.manifest_validator_sha256,
        "Manifest validator Git object ID": args.manifest_validator_object_id,
        "Manifest validator object format": args.git_object_format,
        "Validation complete": "true",
    }
    for key, expected in fixed_values.items():
        if required(fields, key, "pre-seal validation attestation") != expected:
            refuse("pre-seal validation attestation authority differs at " + key)
    for key in ("Build-inputs helper size", "Manifest validator size"):
        expected_size = (
            args.build_inputs_helper_size
            if key.startswith("Build-inputs")
            else args.manifest_validator_size
        )
        if parse_uint(
            required(fields, key, "pre-seal validation attestation"),
            key,
            512 * 1024,
        ) != expected_size:
            refuse("pre-seal validation code size differs from controller authority")
    argv_bytes = b"".join(value.encode("ascii") + b"\0" for value in argv)
    if hashlib.sha256(argv_bytes).hexdigest() != args.validator_argv_sha256:
        refuse("pre-seal validation argv differs from the controller authority")
    if argv[:4] != [
        "/usr/bin/python3",
        "-I",
        "/repo/" + BUILD_INPUTS_HELPER_PATH,
        "validate",
    ]:
        refuse("pre-seal validation argv does not use the isolated exact validator")

    parsed_rows = tuple(rows)
    if exact_rows is not None:
        if parsed_rows != exact_rows:
            refuse("pre-seal validation rows differ from the exact managed state")
        return parsed_rows

    expected_regulars = expected_attested_regulars(records, controls)
    actual_regulars = {
        row.path: row.snapshot for row in parsed_rows if row.kind == "regular"
    }
    if actual_regulars != expected_regulars:
        refuse("pre-seal validation regular rows differ from the retained catalog")
    actual_directories = {
        row.path for row in parsed_rows if row.kind == "directory"
    }
    required_directories, optional_empty = canonical_attested_directories(
        expected_regulars
    )
    if (
        not required_directories <= actual_directories
        or not actual_directories <= required_directories | optional_empty
    ):
        refuse("pre-seal validation directory rows differ from canonical parent closure")
    return parsed_rows


def semantic_source_set(
    records: Dict[str, Snapshot],
    text: Dict[str, bytes],
    args: argparse.Namespace,
    controls: Dict[str, Snapshot],
    exact_attested_rows: Optional[Tuple[AttestedInput, ...]] = None,
) -> Tuple[Set[str], Set[str]]:
    support_head = args.support_head
    manifest = parse_fields(text["artifacts/sp11-kernel-build-manifest.txt"], "kernel build manifest", 4 * 1024 * 1024)
    if (
        required(manifest, "Provenance schema", "kernel build manifest") != "sp11-kernel-build-v2"
        or required(manifest, "Release build", "kernel build manifest") != "true"
        or required(manifest, "Build completed", "kernel build manifest") != "true"
        or required(manifest, "Support start HEAD", "kernel build manifest") != support_head
        or required(manifest, "Support end HEAD", "kernel build manifest") != support_head
        or required(manifest, "Support start dirty", "kernel build manifest") != "false"
        or required(manifest, "Support end dirty", "kernel build manifest") != "false"
    ):
        refuse("kernel build manifest is not the exact completed release schema")
    deb_count = parse_uint(required(manifest, "Deb count", "kernel build manifest"), "kernel Deb count", 64)
    if deb_count == 0:
        refuse("kernel build manifest has no Debs")
    kernel_debs: List[str] = []
    for index in range(1, deb_count + 1):
        name = safe_basename(required(manifest, "Deb %d path" % index, "kernel build manifest"), "kernel Deb path")
        if not DEB_RE.fullmatch(name) or name in kernel_debs:
            refuse("kernel build manifest Deb names are unsafe or duplicated")
        kernel_debs.append(name)
        expect_entry(
            records,
            "artifacts/" + name,
            required(manifest, "Deb %d size" % index, "kernel build manifest"),
            required(manifest, "Deb %d SHA256" % index, "kernel build manifest"),
            "kernel Deb %d" % index,
        )
    expected_deb_list = "".join(name + "\n" for name in kernel_debs).encode("ascii")
    if text["artifacts/sp11-kernel-debs.txt"] != expected_deb_list:
        refuse("kernel Deb list does not match the exact manifest order")
    signature_report_name = safe_basename(
        required(
            manifest,
            "Kernel module signature report asset",
            "kernel build manifest",
        ),
        "kernel module signature report",
    )
    if signature_report_name != "sp11-kernel-module-signatures.txt":
        refuse("kernel module signature report has the wrong fixed asset name")
    expect_entry(
        records,
        "artifacts/" + signature_report_name,
        required(
            manifest,
            "Kernel module signature report size",
            "kernel build manifest",
        ),
        required(
            manifest,
            "Kernel module signature report SHA256",
            "kernel build manifest",
        ),
        "kernel module signature report",
    )
    del manifest

    sidecar = parse_fields(text["artifacts/sp11-kernel-apt-provenance.txt"], "APT provenance", MAX_TEXT_BYTES)
    if (
        required(sidecar, "APT provenance schema", "APT provenance") != "sp11-kernel-apt-provenance-v1"
        or required(sidecar, "APT provenance complete", "APT provenance") != "true"
    ):
        refuse("APT provenance sidecar schema/completion is invalid")
    expected: Set[str] = set(ROOT_PAYLOAD_FILES)
    expected.update("artifacts/" + name for name in FIXED_ARTIFACTS)
    expected.update("artifacts/" + name for name in kernel_debs)
    publish = {"artifacts/" + name for name in FIXED_ARTIFACTS}
    publish.update("artifacts/" + name for name in kernel_debs)

    for prefix, inventory_path in (
        ("Pre-install", "sp11-apt-installed-pre.txt"),
        ("Post-install", "sp11-apt-installed-post.txt"),
    ):
        count = parse_uint(required(sidecar, prefix + " package count", "APT provenance"), prefix + " package count", 100000)
        rows = [required(sidecar, "%s package %d" % (prefix, index), "APT provenance") for index in range(1, count + 1)]
        if rows != sorted(rows) or len(rows) != len(set(rows)):
            refuse(prefix + " inventory is not unique and ordered")
        rendered = "".join(row + "\n" for row in rows).encode("ascii")
        aggregate = required(sidecar, prefix + " package aggregate SHA256", "APT provenance")
        if hashlib.sha256(rendered).hexdigest() != aggregate or text[inventory_path] != rendered:
            refuse(prefix + " inventory does not match the APT sidecar")

    snapshot_id = required(sidecar, "Snapshot ID", "APT provenance")
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", snapshot_id):
        refuse("APT snapshot ID is not canonical")
    inrelease_count = parse_uint(required(sidecar, "InRelease count", "APT provenance"), "InRelease count", 16)
    if inrelease_count != 4:
        refuse("APT provenance InRelease count is not four")
    inrelease_suites: List[str] = []
    for index in range(1, inrelease_count + 1):
        suite = safe_basename(required(sidecar, "InRelease %d suite" % index, "APT provenance"), "InRelease suite")
        inrelease_suites.append(suite)
        source = "apt-lists/snapshot.ubuntu.com_ubuntu_%s_dists_%s_InRelease" % (snapshot_id, suite)
        expected.add(source)
        expect_entry(records, source, required(sidecar, "InRelease %d size" % index, "APT provenance"), required(sidecar, "InRelease %d SHA256" % index, "APT provenance"), "InRelease %d" % index)
    if tuple(inrelease_suites) != (
        "resolute",
        "resolute-updates",
        "resolute-backports",
        "resolute-security",
    ):
        refuse("APT provenance InRelease rows are not unique and ordered")

    index_count = parse_uint(required(sidecar, "Index count", "APT provenance"), "APT index count", 128)
    if index_count != 32:
        refuse("APT provenance index count is not 32")
    index_sources: List[str] = []
    index_suites: List[str] = []
    for index in range(1, index_count + 1):
        suite = safe_basename(required(sidecar, "Index %d suite" % index, "APT provenance"), "APT index suite")
        retained = safe_source_path(required(sidecar, "Index %d retained path" % index, "APT provenance"), "retained APT index path")
        if not retained.startswith(suite + "/"):
            refuse("APT provenance index suite/path binding is inconsistent")
        source = "apt-indexes/" + retained
        index_sources.append(source)
        index_suites.append(suite)
        expected.add(source)
        expect_entry(records, source, required(sidecar, "Index %d size" % index, "APT provenance"), required(sidecar, "Index %d SHA256" % index, "APT provenance"), "APT index %d" % index)
    if len(index_sources) != len(set(index_sources)) or tuple(index_suites) != tuple(
        suite
        for suite in inrelease_suites
        for _row in range(index_count // len(inrelease_suites))
    ):
        refuse("APT provenance index rows are not unique and suite-ordered")

    list_count = parse_uint(required(sidecar, "APT list target count", "APT provenance"), "APT list target count", 128)
    if list_count != 31:
        refuse("APT provenance list-target count is not 31")
    list_sources: List[str] = []
    for index in range(1, list_count + 1):
        name = safe_basename(required(sidecar, "APT list target %d path" % index, "APT provenance"), "APT list target")
        source = "apt-lists/" + name
        list_sources.append(source)
        expected.add(source)
        expect_entry(records, source, required(sidecar, "APT list target %d size" % index, "APT provenance"), required(sidecar, "APT list target %d SHA256" % index, "APT provenance"), "APT list target %d" % index)
    if list_sources != sorted(list_sources) or len(list_sources) != len(set(list_sources)):
        refuse("APT provenance list-target rows are not unique and ordered")

    downloaded_count = parse_uint(required(sidecar, "Downloaded Deb count", "APT provenance"), "downloaded Deb count", 1024)
    downloaded_sources: List[str] = []
    for index in range(1, downloaded_count + 1):
        name = safe_basename(required(sidecar, "Downloaded Deb %d path" % index, "APT provenance"), "downloaded Deb path")
        if not DEB_RE.fullmatch(name):
            refuse("downloaded Deb path is not canonical")
        source = "apt-archives/" + name
        downloaded_sources.append(source)
        expected.add(source)
        expect_entry(records, source, required(sidecar, "Downloaded Deb %d size" % index, "APT provenance"), required(sidecar, "Downloaded Deb %d SHA256" % index, "APT provenance"), "downloaded Deb %d" % index)
    if downloaded_sources != sorted(downloaded_sources) or len(downloaded_sources) != len(set(downloaded_sources)):
        refuse("APT provenance downloaded-Deb rows are not unique and ordered")
    expected.add("apt-archives/lock")
    if records.get("apt-archives/lock") != Snapshot(0, hashlib.sha256(b"").hexdigest()):
        refuse("retained APT archive lock is not the exact empty regular file")

    local_count = parse_uint(required(sidecar, "Local build-deps count", "APT provenance"), "local build-deps count", 8)
    if local_count != 1:
        refuse("APT provenance must bind exactly one local build-deps Deb")
    local_name = safe_basename(required(sidecar, "Local build-deps 1 path", "APT provenance"), "local build-deps path")
    if not DEB_RE.fullmatch(local_name):
        refuse("local build-deps path is not canonical")
    local_source = "artifacts/" + local_name
    if local_name in kernel_debs:
        refuse("local build-deps Deb overlaps the kernel release Deb set")
    expected.add(local_source)
    expect_entry(records, local_source, required(sidecar, "Local build-deps 1 size", "APT provenance"), required(sidecar, "Local build-deps 1 SHA256", "APT provenance"), "local build-deps")
    del sidecar

    envelope = parse_fields(text["artifacts/sp11-kernel-build-inputs.txt"], "build-inputs envelope", 4 * 1024 * 1024)
    if (
        required(envelope, "Build inputs schema", "build-inputs envelope") != "sp11-kernel-build-inputs-v1"
        or required(envelope, "Release build", "build-inputs envelope") != "true"
        or required(envelope, "Support HEAD", "build-inputs envelope") != support_head
        or required(envelope, "Build inputs complete", "build-inputs envelope") != "true"
        or parse_uint(required(envelope, "Input count", "build-inputs envelope"), "build-input count", 16) != 5
    ):
        refuse("build-inputs envelope schema/completion is invalid")
    envelope_sources = (
        ("docker-build-arguments", "docker-build-args.txt", controls["Docker build arguments"]),
        ("docker-entrypoint", "docker-build-inside.sh", controls["Docker entrypoint"]),
        ("oci-index", "sp11-oci-index.json", controls["OCI index"]),
        ("kernel-build-manifest-v2", "artifacts/sp11-kernel-build-manifest.txt", records["artifacts/sp11-kernel-build-manifest.txt"]),
        ("apt-provenance-v1", "artifacts/sp11-kernel-apt-provenance.txt", records["artifacts/sp11-kernel-apt-provenance.txt"]),
    )
    for index, (role, path, snapshot) in enumerate(envelope_sources, 1):
        if (
            required(envelope, "Input %d role" % index, "build-inputs envelope") != role
            or required(envelope, "Input %d path" % index, "build-inputs envelope") != path
            or parse_uint(required(envelope, "Input %d size" % index, "build-inputs envelope"), "build-input size", MAX_MEMBER_BYTES) != snapshot.size
            or required(envelope, "Input %d SHA256" % index, "build-inputs envelope") != snapshot.sha256
        ):
            refuse("build-inputs envelope does not bind the exact retained inputs")

    expected.add(ATTESTATION_NAME)
    if set(records) != expected:
        refuse("retained release evidence file set differs from the schema-derived set")
    parse_preseal_attestation(
        text[ATTESTATION_NAME],
        args,
        records,
        controls,
        exact_attested_rows,
    )
    return expected, publish


def render_catalog(
    entries: Sequence[CatalogEntry],
    args: argparse.Namespace,
    controls: Dict[str, Snapshot],
) -> bytes:
    lines = [
        "Retained release evidence catalog schema: " + CATALOG_SCHEMA,
        "Support HEAD: " + args.support_head,
        "Kernel baseline SHA256: " + args.baseline_sha256,
        "Container image: " + args.container_image,
        "Container platform: " + args.container_platform,
        "Git object format: " + args.git_object_format,
        "Validator argv SHA256: " + args.validator_argv_sha256,
        "Build-inputs helper size: " + str(args.build_inputs_helper_size),
        "Build-inputs helper SHA256: " + args.build_inputs_helper_sha256,
        "Build-inputs helper Git object ID: " + args.build_inputs_helper_object_id,
        "Manifest validator size: " + str(args.manifest_validator_size),
        "Manifest validator SHA256: " + args.manifest_validator_sha256,
        "Manifest validator Git object ID: " + args.manifest_validator_object_id,
    ]
    for label, _name in CONTROL_FILES:
        snapshot = controls[label]
        lines.extend(
            (
                label + " size: " + str(snapshot.size),
                label + " SHA256: " + snapshot.sha256,
            )
        )
    lines.append("Payload count: " + str(len(entries)))
    for index, entry in enumerate(entries, 1):
        lines.extend(
            (
                "Payload %d archive path: %s" % (index, entry.archive_path),
                "Payload %d source path: %s" % (index, entry.source_path),
                "Payload %d size: %d" % (index, entry.size),
                "Payload %d SHA256: %s" % (index, entry.sha256),
            )
        )
    lines.append("Catalog complete: true")
    rendered = ("\n".join(lines) + "\n").encode("ascii")
    if len(rendered) > MAX_CATALOG_BYTES:
        refuse("release-state catalog exceeds its byte limit")
    return rendered


def parse_catalog(
    raw: bytes,
    args: argparse.Namespace,
    expected_digests: Dict[str, str],
) -> Tuple[List[CatalogEntry], Dict[str, Snapshot]]:
    fields = parse_fields(raw, "retained release evidence catalog", MAX_CATALOG_BYTES)
    prefix_keys = [
        "Retained release evidence catalog schema",
        "Support HEAD",
        "Kernel baseline SHA256",
        "Container image",
        "Container platform",
        "Git object format",
        "Validator argv SHA256",
        "Build-inputs helper size",
        "Build-inputs helper SHA256",
        "Build-inputs helper Git object ID",
        "Manifest validator size",
        "Manifest validator SHA256",
        "Manifest validator Git object ID",
    ]
    for label, _name in CONTROL_FILES:
        prefix_keys.extend((label + " size", label + " SHA256"))
    prefix_keys.append("Payload count")
    if list(fields)[: len(prefix_keys)] != prefix_keys:
        refuse("release-state catalog header field set/order is not exact")
    if (
        required(fields, prefix_keys[0], "release-state catalog") != CATALOG_SCHEMA
        or required(fields, "Support HEAD", "release-state catalog") != args.support_head
        or required(fields, "Kernel baseline SHA256", "release-state catalog") != args.baseline_sha256
        or required(fields, "Container image", "release-state catalog") != args.container_image
        or required(fields, "Container platform", "release-state catalog") != args.container_platform
        or required(fields, "Git object format", "release-state catalog") != args.git_object_format
        or required(fields, "Validator argv SHA256", "release-state catalog") != args.validator_argv_sha256
        or required(fields, "Build-inputs helper size", "release-state catalog") != str(args.build_inputs_helper_size)
        or required(fields, "Build-inputs helper SHA256", "release-state catalog") != args.build_inputs_helper_sha256
        or required(fields, "Build-inputs helper Git object ID", "release-state catalog") != args.build_inputs_helper_object_id
        or required(fields, "Manifest validator size", "release-state catalog") != str(args.manifest_validator_size)
        or required(fields, "Manifest validator SHA256", "release-state catalog") != args.manifest_validator_sha256
        or required(fields, "Manifest validator Git object ID", "release-state catalog") != args.manifest_validator_object_id
    ):
        refuse("release-state catalog authority fields do not match the invocation")
    controls: Dict[str, Snapshot] = {}
    for label, _name in CONTROL_FILES:
        size = parse_uint(required(fields, label + " size", "release-state catalog"), label + " size", MAX_CONTROL_BYTES)
        digest = required(fields, label + " SHA256", "release-state catalog")
        if not SHA256_RE.fullmatch(digest) or digest != expected_digests[label]:
            refuse("release-state catalog control identity does not match the invocation")
        controls[label] = Snapshot(size, digest)
    count = parse_uint(required(fields, "Payload count", "release-state catalog"), "release-state payload count", MAX_MEMBERS - 1)
    if count == 0:
        refuse("release-state catalog has no payload members")
    expected_keys = list(prefix_keys)
    entries: List[CatalogEntry] = []
    previous_source = ""
    aggregate_paths = 0
    aggregate_size = 0
    for index in range(1, count + 1):
        keys = (
            "Payload %d archive path" % index,
            "Payload %d source path" % index,
            "Payload %d size" % index,
            "Payload %d SHA256" % index,
        )
        expected_keys.extend(keys)
        archive_path = required(fields, keys[0], "release-state catalog")
        expected_archive = "%s/%08d" % (OBJECTS_NAME, index)
        if archive_path != expected_archive:
            refuse("release-state catalog archive numbering is not canonical")
        source_path = safe_source_path(required(fields, keys[1], "release-state catalog"), "release-state catalog source path")
        if source_path <= previous_source:
            refuse("release-state catalog source paths are not unique and sorted")
        previous_source = source_path
        aggregate_paths += len(source_path.encode("ascii"))
        if aggregate_paths > MAX_AGGREGATE_PATH_BYTES:
            refuse("release-state catalog exceeds its aggregate path-byte limit")
        size = parse_uint(required(fields, keys[2], "release-state catalog"), "release-state payload size", MAX_MEMBER_BYTES)
        digest = required(fields, keys[3], "release-state catalog")
        if not SHA256_RE.fullmatch(digest):
            refuse("release-state payload SHA256 is not canonical")
        aggregate_size += size
        if aggregate_size > MAX_TOTAL_PAYLOAD_BYTES:
            refuse("release-state catalog exceeds its aggregate payload limit")
        entries.append(CatalogEntry(archive_path, source_path, size, digest))
    expected_keys.append("Catalog complete")
    if list(fields) != expected_keys or required(fields, "Catalog complete", "release-state catalog") != "true":
        refuse("release-state catalog field set/order or completion state is invalid")
    return entries, controls


def write_exact_file(parent: int, name: str, payload: bytes, mode: int = 0o600) -> int:
    descriptor = os.open(
        name,
        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        mode,
        dir_fd=parent,
    )
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short release-state control write")
            view = view[written:]
        os.fsync(descriptor)
        snapshot = digest_descriptor(descriptor, max(len(payload), 1))
        if snapshot != Snapshot(len(payload), hashlib.sha256(payload).hexdigest()):
            refuse("release-state control bytes changed during creation")
        return descriptor
    except BaseException:
        try:
            os.ftruncate(descriptor, 0)
            os.fsync(descriptor)
        except OSError:
            pass
        os.close(descriptor)
        raise


def seal_release_state(args: argparse.Namespace) -> None:
    if not COMMIT_RE.fullmatch(args.support_head):
        refuse("support HEAD is not a full lowercase object ID")
    for digest in (
        args.baseline_sha256,
        args.build_args_sha256,
        args.entrypoint_sha256,
        args.oci_index_sha256,
    ):
        if not SHA256_RE.fullmatch(digest):
            refuse("seal invocation contains a noncanonical SHA256")
    work = args.work_root
    if work.is_symlink() or not work.is_dir() or work.resolve(strict=True) != work.absolute():
        refuse("release-state work root is not an exact real directory")

    work_descriptor = os.open(
        work,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    try:
        require_exact_directory_names(
            work_descriptor,
            {
                "apt-archives",
                "apt-indexes",
                "apt-lists",
                "artifacts",
                *ROOT_PAYLOAD_FILES,
                *WORK_COMPANION_NAMES,
            },
            "release-state work root before sealing",
        )
    finally:
        os.close(work_descriptor)

    records: Dict[str, Snapshot] = {}
    scan_budget = ScanBudget()
    for root_name in ("apt-archives", "apt-indexes", "apt-lists", "artifacts"):
        root = work / root_name
        if root.is_symlink() or not root.is_dir():
            refuse("release-state managed root is missing or symlinked")
        scanned = scan_regular_tree(root, root_name, scan_budget)
        overlap = set(records).intersection(scanned)
        if overlap:
            refuse("release-state managed roots overlap")
        records.update(scanned)
    text: Dict[str, bytes] = {}
    captured_text_bytes = 0
    for name in ROOT_PAYLOAD_FILES:
        if name == ATTESTATION_NAME:
            try:
                attestation_metadata = (work / name).lstat()
            except OSError:
                refuse("pre-seal validation attestation could not be inspected")
            if (
                not stat.S_ISREG(attestation_metadata.st_mode)
                or stat.S_IMODE(attestation_metadata.st_mode) != 0o644
                or attestation_metadata.st_nlink != 1
            ):
                refuse("pre-seal validation attestation is not an exact 0644 regular file")
        raw, snapshot = read_path(work / name, MAX_TEXT_BYTES, name)
        captured_text_bytes += len(raw)
        if captured_text_bytes > MAX_CAPTURED_TEXT_BYTES:
            refuse("release-state semantic controls exceed their aggregate byte limit")
        records[name] = snapshot
        text[name] = raw
    for source in (
        "artifacts/sp11-kernel-build-manifest.txt",
        "artifacts/sp11-kernel-debs.txt",
        "artifacts/sp11-kernel-apt-provenance.txt",
        "artifacts/sp11-kernel-build-inputs.txt",
    ):
        raw, snapshot = read_path(work / source, MAX_TEXT_BYTES, source)
        captured_text_bytes += len(raw)
        if captured_text_bytes > MAX_CAPTURED_TEXT_BYTES:
            refuse("release-state semantic controls exceed their aggregate byte limit")
        if records.get(source) != snapshot:
            refuse("release-state control artifact changed after tree scanning")
        text[source] = raw

    controls: Dict[str, Snapshot] = {}
    expected = {
        "Docker build arguments": args.build_args_sha256,
        "Docker entrypoint": args.entrypoint_sha256,
        "OCI index": args.oci_index_sha256,
    }
    for label, name in CONTROL_FILES:
        _raw, snapshot = read_path(work / name, MAX_CONTROL_BYTES, label)
        if snapshot.sha256 != expected[label]:
            refuse("release-state control bytes do not match the private invocation")
        controls[label] = snapshot
    exact_attested_rows = scan_preseal_attested_inputs(work)
    semantic_source_set(records, text, args, controls, exact_attested_rows)

    sorted_sources = sorted(records)
    entries = [
        CatalogEntry("%s/%08d" % (OBJECTS_NAME, index), source, records[source].size, records[source].sha256)
        for index, source in enumerate(sorted_sources, 1)
    ]
    catalog = render_catalog(entries, args, controls)

    try:
        os.mkdir(work / STAGING_NAME, 0o700)
        os.mkdir(work / STAGING_NAME / OBJECTS_NAME, 0o700)
    except OSError:
        refuse("release-state export staging already exists or could not be created")
    staging = os.open(work / STAGING_NAME, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    objects = os.open(OBJECTS_NAME, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=staging)
    work_descriptor = os.open(work, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    held: List[int] = []
    try:
        for entry in entries:
            source_descriptor, source_snapshot = open_path_beneath(work_descriptor, entry.source_path, MAX_MEMBER_BYTES)
            try:
                object_name = entry.archive_path.split("/", 1)[1]
                if sys.platform.startswith("linux"):
                    # The stopped release volume and its pinned toolchain are
                    # the trusted controller envelope. Recheck both the held
                    # source and the new hardlink below; the pathname is not
                    # used as successful byte authority.
                    os.link(
                        entry.source_path,
                        object_name,
                        src_dir_fd=work_descriptor,
                        dst_dir_fd=objects,
                        follow_symlinks=False,
                    )
                elif sys.platform == "darwin":
                    # Fixture-only portability path. Production Linux uses a
                    # same-filesystem hardlink and therefore does not duplicate
                    # multi-GiB retained evidence inside the daemon volume.
                    copied = os.open(
                        object_name,
                        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                        0o600,
                        dir_fd=objects,
                    )
                    try:
                        offset = 0
                        while offset < source_snapshot.size:
                            chunk = os.pread(source_descriptor, min(1024 * 1024, source_snapshot.size - offset), offset)
                            if not chunk:
                                refuse("fixture release-state copy ended early")
                            view = memoryview(chunk)
                            while view:
                                written = os.write(copied, view)
                                if written <= 0:
                                    raise OSError("short fixture release-state copy")
                                view = view[written:]
                            offset += len(chunk)
                        os.fsync(copied)
                    finally:
                        os.close(copied)
                else:
                    refuse("release-state sealing requires Linux or the Darwin fixture platform")
                object_descriptor, object_snapshot = open_regular_at(objects, object_name, MAX_MEMBER_BYTES)
                if source_snapshot != object_snapshot or object_snapshot != Snapshot(entry.size, entry.sha256):
                    os.close(object_descriptor)
                    refuse("release-state hardlink object does not match its source")
                held.append(object_descriptor)
            finally:
                os.close(source_descriptor)
        member_list = b"\x00".join(
            [CATALOG_MEMBER.encode("ascii")]
            + [entry.archive_path.encode("ascii") for entry in entries]
        ) + b"\x00"
        held.append(write_exact_file(staging, CATALOG_MEMBER, catalog))
        held.append(write_exact_file(staging, LIST_NAME, member_list))
        for descriptor in held:
            os.fsync(descriptor)
        os.fsync(objects)
        os.fsync(staging)
    finally:
        for descriptor in held:
            os.close(descriptor)
        os.close(objects)
        os.close(staging)
        os.close(work_descriptor)


def _parse_octal(field: bytes, label: str, maximum: int) -> int:
    if not field or field[-1:] not in (b"\0", b" "):
        refuse("tar " + label + " field is not terminated canonically")
    digits = field[:-1].lstrip(b"0") or b"0"
    if any(character < ord("0") or character > ord("7") for character in digits):
        refuse("tar " + label + " field is not octal")
    value = int(digits, 8)
    if value > maximum:
        refuse("tar " + label + " exceeds its limit")
    return value


def _parse_checksum(field: bytes) -> int:
    if len(field) != 8 or field[6:8] not in (b"\0 ", b"  "):
        refuse("tar checksum field is not canonical")
    digits = field[:6].lstrip(b"0") or b"0"
    if any(character < ord("0") or character > ord("7") for character in digits):
        refuse("tar checksum field is not octal")
    return int(digits, 8)


def _nul_text(field: bytes, label: str) -> str:
    payload, separator, suffix = field.partition(b"\0")
    if separator and any(suffix):
        refuse("tar " + label + " has nonzero bytes after its terminator")
    try:
        return payload.decode("ascii")
    except UnicodeDecodeError:
        refuse("tar " + label + " is not ASCII")


@dataclass(frozen=True)
class TarHeader:
    name: str
    size: int


def _canonical_octal(value: int, width: int) -> bytes:
    encoded = ("%0*o" % (width - 1, value)).encode("ascii") + b"\0"
    if len(encoded) != width:
        refuse("canonical tar numeric field overflowed")
    return encoded


def canonical_ustar_header(name: str, size: int) -> bytes:
    encoded_name = name.encode("ascii")
    if len(encoded_name) > 100:
        refuse("canonical tar member name exceeds the USTAR name field")
    block = bytearray(512)
    block[: len(encoded_name)] = encoded_name
    block[100:108] = _canonical_octal(0o644, 8)
    block[108:116] = _canonical_octal(0, 8)
    block[116:124] = _canonical_octal(0, 8)
    block[124:136] = _canonical_octal(size, 12)
    block[136:148] = _canonical_octal(0, 12)
    block[148:156] = b"        "
    block[156:157] = b"0"
    block[257:263] = b"ustar\0"
    block[263:265] = b"00"
    block[329:337] = _canonical_octal(0, 8)
    block[337:345] = _canonical_octal(0, 8)
    checksum = sum(block)
    block[148:156] = ("%06o" % checksum).encode("ascii") + b"\0 "
    return bytes(block)


def parse_ustar_header(block: bytes) -> TarHeader:
    if len(block) != 512:
        refuse("tar header is truncated")
    stored_checksum = _parse_checksum(block[148:156])
    calculated = sum(block[:148]) + 8 * ord(" ") + sum(block[156:])
    if stored_checksum != calculated:
        refuse("tar header checksum is invalid")
    name = _nul_text(block[0:100], "name")
    prefix = _nul_text(block[345:500], "prefix")
    logical = prefix + "/" + name if prefix else name
    safe_source_path(logical, "tar member name")
    if (
        _parse_octal(block[100:108], "mode", 0o7777) != 0o644
        or _parse_octal(block[108:116], "uid", (1 << 31) - 1) != 0
        or _parse_octal(block[116:124], "gid", (1 << 31) - 1) != 0
        or _parse_octal(block[136:148], "mtime", (1 << 63) - 1) != 0
        or block[156:157] != b"0"
        or any(block[157:257])
        or block[257:263] != b"ustar\0"
        or block[263:265] != b"00"
        or _nul_text(block[265:297], "uname")
        or _nul_text(block[297:329], "gname")
        or _parse_octal(block[329:337], "device major", (1 << 31) - 1) != 0
        or _parse_octal(block[337:345], "device minor", (1 << 31) - 1) != 0
        or any(block[500:512])
    ):
        refuse("tar member metadata is not the canonical regular-file contract")
    size = _parse_octal(block[124:136], "size", MAX_MEMBER_BYTES)
    if block != canonical_ustar_header(logical, size):
        refuse("tar header bytes are not the one canonical USTAR encoding")
    return TarHeader(logical, size)


def directory_identity(metadata: os.stat_result) -> Tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_uid,
        metadata.st_gid,
    )


def stable_file_identity(metadata: os.stat_result) -> Tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
    )


def verify_directory_mapping(descriptor: int, path: Path, label: str) -> Tuple[int, ...]:
    try:
        held = os.fstat(descriptor)
        mapped = path.lstat()
    except OSError:
        refuse(label + " mapping could not be verified")
    if (
        not stat.S_ISDIR(held.st_mode)
        or not stat.S_ISDIR(mapped.st_mode)
        or stat.S_ISLNK(mapped.st_mode)
        or directory_identity(held) != directory_identity(mapped)
    ):
        refuse(label + " no longer maps to its held directory")
    return directory_identity(held)


def open_expected_directory(
    path: Path,
    expected_identity: Tuple[int, ...],
    label: str,
) -> int:
    if (
        not path.is_absolute()
        or len(expected_identity) != 5
        or expected_identity[0] < 0
        or expected_identity[1] <= 0
        or any(component in ("", ".", "..") for component in path.parts[1:])
    ):
        refuse(label + " authority is not canonical")
    required_flags = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK")
    if any(not hasattr(os, flag) for flag in required_flags):
        refuse("required held-directory flags are unavailable")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    current = os.open("/", flags)
    try:
        for component in path.parts[1:]:
            child = os.open(component, flags, dir_fd=current)
            metadata = os.fstat(child)
            if not stat.S_ISDIR(metadata.st_mode):
                os.close(child)
                refuse(label + " component is not a directory")
            os.close(current)
            current = child
        metadata = os.fstat(current)
        if directory_identity(metadata) != expected_identity:
            refuse(label + " does not match its preflight authority")
        verify_directory_mapping(current, path, label)
        return current
    except BaseException:
        os.close(current)
        raise


def open_expected_child_directory(
    parent: int,
    name: str,
    path: Path,
    expected_identity: Tuple[int, ...],
    label: str,
) -> int:
    safe_basename(name, label + " name")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    descriptor = os.open(name, flags, dir_fd=parent)
    try:
        held = os.fstat(descriptor)
        mapped_child = os.stat(name, dir_fd=parent, follow_symlinks=False)
        mapped_path = path.lstat()
        if (
            not stat.S_ISDIR(held.st_mode)
            or not stat.S_ISDIR(mapped_child.st_mode)
            or not stat.S_ISDIR(mapped_path.st_mode)
            or directory_identity(held) != expected_identity
            or directory_identity(mapped_child) != expected_identity
            or directory_identity(mapped_path) != expected_identity
            or stat.S_ISLNK(mapped_child.st_mode)
            or stat.S_ISLNK(mapped_path.st_mode)
        ):
            refuse(label + " does not match its held parent or preflight authority")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


@dataclass
class PublishedFile:
    parent: int
    name: str
    descriptor: int
    snapshot: Optional[Snapshot] = None
    identity: Optional[Tuple[int, ...]] = None


@dataclass(frozen=True)
class HeldControl:
    name: str
    descriptor: int
    snapshot: Snapshot
    identity: Tuple[int, ...]


def control_file_identity(metadata: os.stat_result) -> Tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
    )


def open_expected_control(
    parent: int,
    name: str,
    expected_identity: Tuple[int, ...],
    expected_sha256: str,
) -> HeldControl:
    if len(expected_identity) != 9 or not SHA256_RE.fullmatch(expected_sha256):
        refuse("release companion authority is not canonical")
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        dir_fd=parent,
    )
    try:
        held = os.fstat(descriptor)
        mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
        identity = control_file_identity(held)
        if (
            not stat.S_ISREG(held.st_mode)
            or not stat.S_ISREG(mapped.st_mode)
            or identity != expected_identity
            or stat.S_IMODE(held.st_mode) != 0o600
            or held.st_nlink != 1
            or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            refuse("release companion does not match its preflight authority")
        snapshot = digest_descriptor(descriptor, MAX_CONTROL_BYTES)
        if snapshot.sha256 != expected_sha256 or snapshot.size != held.st_size:
            refuse("release companion bytes differ from the committed control")
        return HeldControl(name, descriptor, snapshot, identity)
    except BaseException:
        os.close(descriptor)
        raise


def verify_held_controls(parent: int, controls: Sequence[HeldControl]) -> None:
    for control in controls:
        held = os.fstat(control.descriptor)
        mapped = os.stat(control.name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISREG(mapped.st_mode)
            or control_file_identity(held) != control.identity
            or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
            or digest_descriptor(control.descriptor, MAX_CONTROL_BYTES)
            != control.snapshot
        ):
            refuse("release companion changed before publication commit")


def verify_held_control_metadata(
    parent: int,
    controls: Sequence[HeldControl],
) -> None:
    for control in controls:
        held = os.fstat(control.descriptor)
        mapped = os.stat(control.name, dir_fd=parent, follow_symlinks=False)
        if (
            control_file_identity(held) != control.identity
            or not stat.S_ISREG(mapped.st_mode)
            or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            refuse("release companion changed at the publication boundary")


def verify_published_metadata(outputs: Sequence[PublishedFile]) -> None:
    for output in outputs:
        if output.identity is None:
            refuse("release-state output was not sealed")
        held = os.fstat(output.descriptor)
        mapped = os.stat(output.name, dir_fd=output.parent, follow_symlinks=False)
        if (
            stable_file_identity(held) != output.identity
            or not stat.S_ISREG(mapped.st_mode)
            or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            refuse("release-state output changed at the publication boundary")


def create_published(parent: int, name: str) -> PublishedFile:
    safe_basename(name, "published release-state filename")
    descriptor: Optional[int] = None
    try:
        descriptor = os.open(
            name,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
            0o600,
            dir_fd=parent,
        )
        metadata = os.fstat(descriptor)
        mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or not stat.S_ISREG(mapped.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size != 0
            or metadata.st_nlink != 1
            or (metadata.st_dev, metadata.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            refuse("exclusive release-state output is not a new private regular file")
        return PublishedFile(parent, name, descriptor)
    except BaseException:
        if descriptor is not None:
            try:
                os.ftruncate(descriptor, 0)
                os.fsync(descriptor)
            except BaseException:
                pass
            try:
                os.close(descriptor)
            except OSError:
                pass
        raise


def acquire_published(
    owner: List[PublishedFile],
    parent: int,
    name: str,
) -> PublishedFile:
    blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        output = create_published(parent, name)
        try:
            owner.append(output)
        except BaseException:
            try:
                os.ftruncate(output.descriptor, 0)
                os.fsync(output.descriptor)
            except BaseException:
                pass
            try:
                os.close(output.descriptor)
            except OSError:
                pass
            raise
        return output
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def write_all(descriptor: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short release-state output write")
        view = view[written:]


class BoundedPipe:
    def __init__(self, stdout: BinaryIO, stderr: BinaryIO, raw_output: int) -> None:
        self.stdout = stdout
        self.stderr = stderr
        self.stdout_descriptor = stdout.fileno()
        self.stderr_descriptor = stderr.fileno()
        os.set_blocking(self.stdout_descriptor, False)
        os.set_blocking(self.stderr_descriptor, False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.stdout_descriptor, selectors.EVENT_READ, "stdout")
        self.selector.register(self.stderr_descriptor, selectors.EVENT_READ, "stderr")
        self.buffer = bytearray()
        self.diagnostics = bytearray()
        self.raw_output = raw_output
        self.raw_size = 0
        self.raw_digest = hashlib.sha256()
        self.started = time.monotonic()
        self.last_stdout = self.started
        self.stdout_eof = False
        self.stderr_eof = False

    def close(self) -> None:
        self.selector.close()

    def _fill(self, reject_stdout: bool = False) -> None:
        if self.stdout_eof and self.stderr_eof:
            return
        now = time.monotonic()
        if now - self.started > MAX_TOTAL_SECONDS:
            refuse("release-state exporter exceeded its total time limit")
        idle_limit = MAX_STARTUP_SECONDS if self.raw_size == 0 else MAX_IDLE_SECONDS
        idle_remaining = idle_limit - (now - self.last_stdout)
        total_remaining = MAX_TOTAL_SECONDS - (now - self.started)
        if idle_remaining <= 0 or total_remaining <= 0:
            refuse("release-state exporter exceeded its bounded progress interval")
        events = self.selector.select(min(idle_remaining, total_remaining, 1.0))
        if not events:
            return self._fill(reject_stdout=reject_stdout)
        for key, _mask in events:
            try:
                chunk = os.read(key.fd, 64 * 1024)
            except BlockingIOError:
                continue
            if not chunk:
                self.selector.unregister(key.fd)
                if key.data == "stdout":
                    self.stdout_eof = True
                else:
                    self.stderr_eof = True
                continue
            if key.data == "stderr":
                if len(self.diagnostics) + len(chunk) > MAX_DIAGNOSTIC_BYTES:
                    refuse("release-state exporter diagnostics exceed their bound")
                self.diagnostics.extend(chunk)
                continue
            if reject_stdout:
                refuse("release-state tar has bytes after its canonical end marker")
            self.last_stdout = time.monotonic()
            self.raw_size += len(chunk)
            if self.raw_size > MAX_TAR_BYTES:
                refuse("release-state tar exceeds its in-flight byte limit")
            write_all(self.raw_output, chunk)
            self.raw_digest.update(chunk)
            self.buffer.extend(chunk)

    def read_exact(self, size: int) -> bytes:
        if size < 0 or size > max(MAX_MEMBER_BYTES, 512):
            refuse("release-state parser received an invalid read size")
        while len(self.buffer) < size and not self.stdout_eof:
            self._fill()
        if len(self.buffer) < size:
            refuse("release-state tar ended unexpectedly")
        payload = bytes(self.buffer[:size])
        del self.buffer[:size]
        return payload

    def require_eof(self) -> None:
        if self.buffer:
            refuse("release-state tar has bytes after its canonical end marker")
        while not (self.stdout_eof and self.stderr_eof):
            self._fill(reject_stdout=True)
        if self.diagnostics:
            refuse("release-state exporter emitted unexpected diagnostics")


class SpawnedChild:
    def __init__(
        self,
        command: Sequence[str],
        environment: Optional[Dict[str, str]] = None,
        child_signal_mask: Optional[Iterable[signal.Signals]] = None,
    ) -> None:
        if (
            not command
            or not os.path.isabs(command[0])
            or any(not value or "\x00" in value for value in command)
        ):
            refuse("release-state child command is not exact and absolute")
        required = ("pthread_sigmask", "SIG_BLOCK", "SIG_SETMASK")
        if any(not hasattr(signal, name) for name in required):
            refuse("signal-safe child ownership is unavailable")
        if not hasattr(signal, "SIGCHLD") or signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
            # Ignored SIGCHLD/SA_NOCLDWAIT can auto-reap a child while its PID
            # still appears live to this owner.  Every acquisition therefore
            # requires the process-wide disposition established by main().
            refuse("release-state child reaping disposition is not exact")
        self.pid: Optional[int] = None
        self.status: Optional[int] = None
        self.stdout: Optional[BinaryIO] = None
        self.stderr: Optional[BinaryIO] = None
        blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT}
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
        descriptors: List[int] = []
        try:
            stdin_read, stdin_write = os.pipe()
            stdout_read, stdout_write = os.pipe()
            stderr_read, stderr_write = os.pipe()
            descriptors = [stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write]
            actions = [
                (os.POSIX_SPAWN_DUP2, stdin_read, 0),
                (os.POSIX_SPAWN_DUP2, stdout_write, 1),
                (os.POSIX_SPAWN_DUP2, stderr_write, 2),
            ]
            actions.extend((os.POSIX_SPAWN_CLOSE, descriptor) for descriptor in descriptors)
            self.pid = os.posix_spawn(
                command[0],
                list(command),
                dict(os.environ) if environment is None else environment,
                file_actions=actions,
                setpgroup=0,
                setsigmask=tuple(previous if child_signal_mask is None else child_signal_mask),
                setsigdef=(
                    signal.SIGINT,
                    signal.SIGTERM,
                    signal.SIGHUP,
                    signal.SIGQUIT,
                ),
            )
            for descriptor in (stdin_read, stdin_write, stdout_write, stderr_write):
                os.close(descriptor)
                descriptors.remove(descriptor)
            self.stdout = os.fdopen(stdout_read, "rb", buffering=0)
            descriptors.remove(stdout_read)
            self.stderr = os.fdopen(stderr_read, "rb", buffering=0)
            descriptors.remove(stderr_read)
        except BaseException:
            # Once posix_spawn returns, this object owns the exact process
            # group even if wrapping a returned pipe descriptor fails.
            self.abort()
            self.close()
            for descriptor in descriptors:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            raise
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    def _waitpid_registered(self, options: int) -> int:
        """Wait with terminal signals blocked through exact status ownership."""

        if self.pid is None or self.status is not None:
            refuse("release-state child ownership is incomplete")
        blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT}
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
        try:
            waited, status = os.waitpid(self.pid, options)
            if waited == self.pid:
                self.status = status
            return waited
        finally:
            # A pending handled signal is delivered only after a successful
            # waitpid result has been registered on this exact owner.  Cleanup
            # therefore cannot kill a PID/process group that waitpid reaped.
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    def finish(self) -> None:
        if self.pid is None or self.status is not None:
            refuse("release-state child ownership is incomplete")
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            waited = self._waitpid_registered(os.WNOHANG)
            if waited == self.pid:
                break
            time.sleep(0.01)
        if self.status is None:
            blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT}
            previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
            try:
                self.abort()
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous)
            refuse("release-state child did not exit after closing its stream")
        if os.waitstatus_to_exitcode(self.status) != 0:
            refuse("release-state child exited unsuccessfully")

    def abort(self) -> None:
        if self.pid is None or self.status is not None:
            return
        try:
            os.killpg(self.pid, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            try:
                waited = self._waitpid_registered(os.WNOHANG)
            except ChildProcessError:
                return
            if waited == self.pid:
                return
            time.sleep(0.01)
        try:
            os.killpg(self.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            self._waitpid_registered(0)
        except (ChildProcessError, OSError):
            pass

    def close(self) -> None:
        for handle in (self.stdout, self.stderr):
            if handle is not None:
                try:
                    handle.close()
                except OSError:
                    pass


class ExporterProcess(SpawnedChild):
    pass


def acquire_exporter(
    owner: List[ExporterProcess],
    command: Sequence[str],
) -> ExporterProcess:
    blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        child = ExporterProcess(command, child_signal_mask=previous)
        try:
            owner.append(child)
        except BaseException:
            child.abort()
            child.close()
            raise
        return child
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def collect_child_output(
    child: SpawnedChild,
    stdout_limit: int,
    stderr_limit: int,
    timeout: float,
) -> Tuple[bytes, bytes]:
    if child.stdout is None or child.stderr is None:
        refuse("release-state child pipes are unavailable")
    selector = selectors.DefaultSelector()
    stdout_fd = child.stdout.fileno()
    stderr_fd = child.stderr.fileno()
    os.set_blocking(stdout_fd, False)
    os.set_blocking(stderr_fd, False)
    selector.register(stdout_fd, selectors.EVENT_READ, "stdout")
    selector.register(stderr_fd, selectors.EVENT_READ, "stderr")
    output = bytearray()
    diagnostics = bytearray()
    deadline = time.monotonic() + timeout
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                refuse("release-state control child exceeded its time limit")
            events = selector.select(min(remaining, 1.0))
            if not events:
                continue
            for key, _mask in events:
                try:
                    chunk = os.read(key.fd, 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                target = output if key.data == "stdout" else diagnostics
                limit = stdout_limit if key.data == "stdout" else stderr_limit
                if len(target) + len(chunk) > limit:
                    refuse("release-state control child output exceeds its bound")
                target.extend(chunk)
        child.finish()
        return bytes(output), bytes(diagnostics)
    finally:
        selector.close()


def relay_child_output(child: SpawnedChild) -> None:
    if child.stdout is None or child.stderr is None:
        refuse("release container log pipes are unavailable")
    selector = selectors.DefaultSelector()
    stdout_fd = child.stdout.fileno()
    stderr_fd = child.stderr.fileno()
    os.set_blocking(stdout_fd, False)
    os.set_blocking(stderr_fd, False)
    selector.register(stdout_fd, selectors.EVENT_READ, 1)
    selector.register(stderr_fd, selectors.EVENT_READ, 2)
    total = 0
    deadline = time.monotonic() + MAX_BUILD_SECONDS
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                refuse("release build container exceeded its time limit")
            events = selector.select(min(remaining, 1.0))
            if not events:
                continue
            for key, _mask in events:
                try:
                    chunk = os.read(key.fd, 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                total += len(chunk)
                if total > MAX_BUILD_LOG_BYTES:
                    refuse("release build container logs exceed their bound")
                write_all(int(key.data), chunk)
        child.finish()
    finally:
        selector.close()


EXPORTER_LABEL_KEY = "org.sp11.release-export-token"


class ExporterContainer:
    def __init__(
        self,
        docker_path: str,
        create_command: Sequence[str],
        require_read_only_exporter: bool = False,
        retained_volume_name: Optional[str] = None,
        expected_image_digest: Optional[str] = None,
        expected_platform: Optional[str] = None,
    ) -> None:
        repo_source: Optional[str] = None
        if (
            not os.path.isabs(docker_path)
            or len(create_command) < 3
            or create_command[0] != docker_path
            or create_command[1] != "create"
            or any(
                value == "--rm"
                or value.startswith("--rm=")
                or value == "--name"
                or value.startswith("--name=")
                or value == "--cidfile"
                or value.startswith("--cidfile=")
                for value in create_command[2:]
            )
        ):
            refuse("release-state exporter create command is not exact")
        if require_read_only_exporter:
            arguments = list(create_command[2:])
            if retained_volume_name is None or not RETAINED_VOLUME_RE.fullmatch(
                retained_volume_name
            ):
                refuse("release-state exporter volume authority is not canonical")
            if (
                expected_image_digest is None
                or not SHA256_RE.fullmatch(expected_image_digest)
                or expected_platform is None
                or not PLATFORM_RE.fullmatch(expected_platform)
            ):
                refuse("release-state exporter image authority is not canonical")
            if len(arguments) != 22:
                refuse("release-state exporter create vector has an unexpected length")
            platform = arguments[13]
            work_mount = (
                "type=volume,source="
                + retained_volume_name
                + ",destination=/work,readonly"
            )
            repo_bind = arguments[17]
            image = arguments[20]
            try:
                repo_source, repo_destination, repo_mode = repo_bind.rsplit(":", 2)
            except ValueError:
                refuse("release-state exporter support bind is not canonical")
            if (
                not PLATFORM_RE.fullmatch(platform)
                or platform != expected_platform
                or not PINNED_IMAGE_RE.fullmatch(image)
                or image.rsplit("@sha256:", 1)[1] != expected_image_digest
                or not repo_source.startswith("/")
                or any(character in repo_source for character in ("\x00", "\n", "\r"))
                or repo_destination != "/repo"
                or repo_mode != "ro"
                or arguments
                != [
                    "--pull=never",
                    "--network",
                    "none",
                    "--read-only",
                    "--cap-drop",
                    "ALL",
                    "--security-opt",
                    "no-new-privileges",
                    "--pids-limit",
                    "64",
                    "--user",
                    "0:0",
                    "--platform",
                    platform,
                    "--mount",
                    work_mount,
                    "-v",
                    repo_bind,
                    "--entrypoint",
                    "/bin/bash",
                    image,
                    "/repo/scripts/emit-sp11-kernel-release-state.sh",
                ]
            ):
                refuse("release-state exporter create command lacks its isolation contract")
        self.docker_path = docker_path
        self.token = secrets.token_hex(32)
        self.name = "sp11-release-exporter-" + self.token
        self.label = EXPORTER_LABEL_KEY + "=" + self.token
        self.identifier: Optional[str] = None
        self.removed = False
        self.retained_volume_name = retained_volume_name
        self.repo_source = repo_source
        self.create_command = [
            docker_path,
            "create",
            "--name",
            self.name,
            "--label",
            self.label,
            *create_command[2:],
        ]

    def create(self) -> str:
        blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT}
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
        child: Optional[SpawnedChild] = None
        try:
            child = SpawnedChild(self.create_command, child_signal_mask=previous)
            output, diagnostics = collect_child_output(child, 128, MAX_DIAGNOSTIC_BYTES, 120.0)
            if diagnostics or not output.endswith(b"\n") or output.count(b"\n") != 1:
                refuse("release-state exporter create response is not exact")
            try:
                identifier = output[:-1].decode("ascii")
            except UnicodeDecodeError:
                refuse("release-state exporter ID is not ASCII")
            if not CONTAINER_ID_RE.fullmatch(identifier):
                refuse("release-state exporter ID is not a full lowercase ID")
            self.identifier = identifier
            return identifier
        finally:
            if child is not None:
                child.abort()
                child.close()
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    def start_command(self) -> List[str]:
        if self.identifier is None:
            refuse("release-state exporter container is not registered")
        return [self.docker_path, "start", "--attach", self.identifier]

    def require_read_only_mounts(
        self,
        child_signal_mask: Iterable[signal.Signals],
    ) -> None:
        if self.identifier is None or self.retained_volume_name is None:
            refuse("release-state exporter mount authority is incomplete")
        child = SpawnedChild(
            [
                self.docker_path,
                "inspect",
                "--type",
                "container",
                "--format",
                "{{json .Mounts}}",
                self.identifier,
            ],
            child_signal_mask=child_signal_mask,
        )
        try:
            output, diagnostics = collect_child_output(
                child,
                16 * 1024,
                MAX_DIAGNOSTIC_BYTES,
                30.0,
            )
            if diagnostics or not output.endswith(b"\n") or output.count(b"\n") != 1:
                refuse("release-state exporter mount inspection is not exact")
            try:
                mounts = json.loads(output.decode("ascii"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                refuse("release-state exporter mount inspection is malformed")
            if not isinstance(mounts, list) or len(mounts) != 2:
                refuse("release-state exporter mount set is not exact")
            work = [
                mount
                for mount in mounts
                if isinstance(mount, dict) and mount.get("Destination") == "/work"
            ]
            repo = [
                mount
                for mount in mounts
                if isinstance(mount, dict) and mount.get("Destination") == "/repo"
            ]
            if (
                len(work) != 1
                or len(repo) != 1
                or work[0].get("Type") != "volume"
                or work[0].get("Name") != self.retained_volume_name
                or work[0].get("RW") is not False
                or repo[0].get("Type") != "bind"
                or repo[0].get("Source") != self.repo_source
                or repo[0].get("RW") is not False
            ):
                refuse("release-state exporter mounts do not match the retained authority")
        finally:
            child.abort()
            child.close()

    def require_successful_exit(self, child_signal_mask: Iterable[signal.Signals]) -> None:
        if self.identifier is None:
            refuse("release-state exporter container is not registered")
        child = SpawnedChild(
            [
                self.docker_path,
                "inspect",
                "--type",
                "container",
                "--format",
                "{{.State.Status}} {{.State.ExitCode}}",
                self.identifier,
            ],
            child_signal_mask=child_signal_mask,
        )
        try:
            output, diagnostics = collect_child_output(child, 128, MAX_DIAGNOSTIC_BYTES, 30.0)
            if diagnostics or output != b"exited 0\n":
                refuse("release-state container did not stop successfully")
        finally:
            child.abort()
            child.close()

    def remove(self, child_signal_mask: Iterable[signal.Signals]) -> None:
        if self.removed:
            return
        # Before Docker returns a full immutable ID, a same-UID process can
        # observe and reuse the random name/label. Never delete by those
        # mutable selectors: preserve a possible stopped orphan on failure.
        if self.identifier is None:
            return
        identifier = self.identifier
        child = SpawnedChild(
            [self.docker_path, "rm", "-f", identifier],
            child_signal_mask=child_signal_mask,
        )
        try:
            output, diagnostics = collect_child_output(child, 128, MAX_DIAGNOSTIC_BYTES, 60.0)
            if diagnostics or output != (identifier + "\n").encode("ascii"):
                refuse("release-state exporter removal was not acknowledged exactly")
            self.identifier = identifier
            self.removed = True
        finally:
            child.abort()
            child.close()


def install_signal_handlers() -> None:
    if not hasattr(signal, "SIGCHLD"):
        refuse("release-state child reaping disposition is unavailable")
    try:
        # SIG_IGN survives exec on POSIX and may imply SA_NOCLDWAIT.  Reset it
        # before the first spawn so registered children remain waitable until
        # their exact owner records terminal state.
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    except (OSError, RuntimeError, ValueError):
        refuse("release-state child reaping disposition is unavailable")

    def interrupted(number: int, _frame: object) -> None:
        if number == signal.SIGQUIT:
            raise ReleaseStateQuit
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    signal.signal(signal.SIGQUIT, interrupted)


@contextlib.contextmanager
def cleanup_signal_mask() -> Iterator[Set[signal.Signals]]:
    blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        yield previous
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def scrub_outputs(outputs: Iterable[PublishedFile]) -> None:
    with cleanup_signal_mask():
        for output in outputs:
            try:
                os.ftruncate(output.descriptor, 0)
                os.fsync(output.descriptor)
            except BaseException:
                pass


def close_outputs(outputs: Iterable[PublishedFile]) -> None:
    for output in outputs:
        try:
            os.close(output.descriptor)
        except OSError:
            pass


def seal_published(output: PublishedFile, expected: Optional[Snapshot] = None) -> Snapshot:
    os.fchmod(output.descriptor, 0o644)
    os.fsync(output.descriptor)
    snapshot = digest_descriptor(output.descriptor, MAX_TAR_BYTES if output.name == EVIDENCE_TAR_NAME else MAX_MEMBER_BYTES)
    if expected is not None and snapshot != expected:
        refuse("published release-state bytes differ from the validated stream")
    metadata = os.fstat(output.descriptor)
    mapped = os.stat(output.name, dir_fd=output.parent, follow_symlinks=False)
    if (
        not stat.S_ISREG(mapped.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o644
        or metadata.st_nlink != 1
        or (metadata.st_dev, metadata.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        refuse("published release-state output mapping is not exact")
    output.snapshot = snapshot
    output.identity = stable_file_identity(metadata)
    return snapshot


def require_exact_directory_names(
    descriptor: int,
    expected: Set[str],
    label: str,
) -> None:
    observed: Set[str] = set()
    with os.scandir(descriptor) as iterator:
        for entry in iterator:
            if len(observed) >= len(expected) + 1:
                refuse(label + " exceeds its exact member bound")
            observed.add(entry.name)
    if observed != expected:
        refuse(label + " differs from its exact member set")


def verify_output_group(
    outputs: Sequence[PublishedFile],
    controls: Sequence[HeldControl],
    work_fd: int,
    work_path: Path,
    artifacts_fd: int,
    artifacts_path: Path,
    expected_work: Tuple[int, ...],
    expected_artifacts: Tuple[int, ...],
    fixture_hook: str = "",
) -> None:
    for _pass in range(2):
        if verify_directory_mapping(work_fd, work_path, "release work root") != expected_work:
            refuse("release work root changed during publication")
        if verify_directory_mapping(artifacts_fd, artifacts_path, "release artifacts root") != expected_artifacts:
            refuse("release artifacts root changed during publication")
        mapped_child = os.stat("artifacts", dir_fd=work_fd, follow_symlinks=False)
        if directory_identity(mapped_child) != expected_artifacts:
            refuse("release artifacts root is not the exact held work child")
        verify_held_controls(work_fd, controls)
        for output in outputs:
            if output.snapshot is None or output.identity is None:
                refuse("release-state output was not sealed")
            held = os.fstat(output.descriptor)
            mapped = os.stat(output.name, dir_fd=output.parent, follow_symlinks=False)
            maximum = MAX_TAR_BYTES if output.name == EVIDENCE_TAR_NAME else MAX_MEMBER_BYTES
            if (
                stable_file_identity(held) != output.identity
                or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
                or digest_descriptor(output.descriptor, maximum) != output.snapshot
            ):
                refuse("release-state output group changed before commit")
        artifact_names = {
            output.name for output in outputs if output.parent == artifacts_fd
        }
        require_exact_directory_names(
            artifacts_fd,
            artifact_names,
            "release artifacts root",
        )
        require_exact_directory_names(
            work_fd,
            {"artifacts", EVIDENCE_TAR_NAME, *WORK_COMPANION_NAMES},
            "release work root",
        )
    # All potentially large output/control hashes are complete after the two
    # passes above. Everything from here to commit is bounded metadata,
    # membership, and mapping work only.
    if fixture_hook == "mutate-output-after-wide-hashes":
        if not outputs or os.pwrite(outputs[0].descriptor, b"\0", 0) != 1:
            refuse("release-state output mutation fixture failed")
        os.fsync(outputs[0].descriptor)
    # The final pass is deliberately metadata/name-only and collective. It
    # closes the wide window in which an early output could change after its
    # second digest while later, multi-GiB outputs were still being read.
    if verify_directory_mapping(work_fd, work_path, "release work root") != expected_work:
        refuse("release work root changed after output hashing")
    if verify_directory_mapping(artifacts_fd, artifacts_path, "release artifacts root") != expected_artifacts:
        refuse("release artifacts root changed after output hashing")
    mapped_child = os.stat("artifacts", dir_fd=work_fd, follow_symlinks=False)
    if directory_identity(mapped_child) != expected_artifacts:
        refuse("release artifacts root mapping changed after output hashing")
    verify_published_metadata(outputs)
    verify_held_control_metadata(work_fd, controls)
    if verify_directory_mapping(artifacts_fd, artifacts_path, "release artifacts root") != expected_artifacts:
        refuse("release artifacts root changed at the publication boundary")
    mapped_child = os.stat("artifacts", dir_fd=work_fd, follow_symlinks=False)
    if directory_identity(mapped_child) != expected_artifacts:
        refuse("release artifacts child mapping changed at the publication boundary")
    if verify_directory_mapping(work_fd, work_path, "release work root") != expected_work:
        refuse("release work root changed at the publication boundary")
    # Exact membership is deliberately the literal last potentially wide
    # observation before the caller's signal-blocked commit transition.
    expected_names = {
        output.name for output in outputs if output.parent == artifacts_fd
    }
    if fixture_hook == "inject-late-member":
        injected = os.open(
            ".sp11-fixture-late-member",
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=artifacts_fd,
        )
        os.close(injected)
    elif fixture_hook == "inject-late-work-member":
        injected = os.open(
            ".sp11-fixture-late-work-member",
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=work_fd,
        )
        os.close(injected)
    work_boundary = stable_file_identity(os.fstat(work_fd))
    artifacts_boundary = stable_file_identity(os.fstat(artifacts_fd))
    require_exact_directory_names(
        work_fd,
        {"artifacts", EVIDENCE_TAR_NAME, *WORK_COMPANION_NAMES},
        "release work root after collective hashing",
    )
    require_exact_directory_names(
        artifacts_fd,
        expected_names,
        "release artifacts root after collective hashing",
    )
    verify_published_metadata(outputs)
    verify_held_control_metadata(work_fd, controls)
    mapped_work = verify_directory_mapping(work_fd, work_path, "release work root")
    mapped_artifacts = verify_directory_mapping(
        artifacts_fd,
        artifacts_path,
        "release artifacts root",
    )
    mapped_child = os.stat("artifacts", dir_fd=work_fd, follow_symlinks=False)
    if (
        mapped_work != expected_work
        or mapped_artifacts != expected_artifacts
        or directory_identity(mapped_child) != expected_artifacts
        or stable_file_identity(os.fstat(work_fd)) != work_boundary
        or stable_file_identity(os.fstat(artifacts_fd)) != artifacts_boundary
    ):
        refuse("release output directories changed at the collective boundary")


def collect_text(source_path: str, size: int) -> bool:
    return source_path in ROOT_PAYLOAD_FILES or source_path in (
        "artifacts/sp11-kernel-build-manifest.txt",
        "artifacts/sp11-kernel-debs.txt",
        "artifacts/sp11-kernel-apt-provenance.txt",
        "artifacts/sp11-kernel-build-inputs.txt",
    )


def verify_terminal_output_boundary(
    outputs: Sequence[PublishedFile],
    controls: Sequence[HeldControl],
    work_fd: int,
    work_path: Path,
    artifacts_fd: int,
    artifacts_path: Path,
    expected_work: Tuple[int, ...],
    expected_artifacts: Tuple[int, ...],
) -> None:
    expected_names = {
        output.name for output in outputs if output.parent == artifacts_fd
    }
    work_boundary = stable_file_identity(os.fstat(work_fd))
    artifacts_boundary = stable_file_identity(os.fstat(artifacts_fd))
    require_exact_directory_names(
        work_fd,
        {"artifacts", EVIDENCE_TAR_NAME, *WORK_COMPANION_NAMES},
        "release work root at terminal publication",
    )
    require_exact_directory_names(
        artifacts_fd,
        expected_names,
        "release artifacts root at terminal publication",
    )
    verify_published_metadata(outputs)
    verify_held_control_metadata(work_fd, controls)
    mapped_work = verify_directory_mapping(work_fd, work_path, "release work root")
    mapped_artifacts = verify_directory_mapping(
        artifacts_fd,
        artifacts_path,
        "release artifacts root",
    )
    mapped_child = os.stat("artifacts", dir_fd=work_fd, follow_symlinks=False)
    if (
        mapped_work != expected_work
        or mapped_artifacts != expected_artifacts
        or directory_identity(mapped_child) != expected_artifacts
        or stable_file_identity(os.fstat(work_fd)) != work_boundary
        or stable_file_identity(os.fstat(artifacts_fd)) != artifacts_boundary
    ):
        refuse("release output directories changed at terminal publication")


@dataclass
class ParsedEvidence:
    entries: List[CatalogEntry]
    controls: Dict[str, Snapshot]
    records: Dict[str, Snapshot]
    text: Dict[str, bytes]
    member_offsets: Dict[str, int]
    raw_snapshot: Snapshot


@dataclass(frozen=True)
class VerifiedEvidence:
    raw: Snapshot
    flat_files: Tuple[Tuple[str, Snapshot], ...]


@dataclass
class HeldRegular:
    parent: int
    name: str
    descriptor: int
    snapshot: Snapshot
    identity: Tuple[int, ...]


class BoundedDescriptorReader:
    def __init__(self, descriptor: int) -> None:
        self.descriptor = descriptor
        self.metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(self.metadata.st_mode)
            or self.metadata.st_size > MAX_TAR_BYTES
        ):
            refuse("retained evidence tar is non-regular or oversized")
        self.identity = stable_file_identity(self.metadata)
        self.raw_size = 0
        self.raw_digest = hashlib.sha256()

    def read_exact(self, size: int) -> bytes:
        if size < 0 or size > max(MAX_MEMBER_BYTES, 512):
            refuse("release-state parser received an invalid read size")
        if self.raw_size + size > self.metadata.st_size:
            refuse("retained evidence tar ended unexpectedly")
        payload = bytearray()
        while len(payload) < size:
            chunk = os.pread(
                self.descriptor,
                min(64 * 1024, size - len(payload)),
                self.raw_size + len(payload),
            )
            if not chunk:
                refuse("retained evidence tar ended unexpectedly")
            payload.extend(chunk)
        self.raw_size += size
        self.raw_digest.update(payload)
        return bytes(payload)

    def require_eof(self) -> None:
        if self.raw_size != self.metadata.st_size:
            refuse("retained evidence tar has bytes after its canonical end marker")
        if stable_file_identity(os.fstat(self.descriptor)) != self.identity:
            refuse("retained evidence tar changed during validation")


def parse_evidence_reader(
    reader: object,
    args: argparse.Namespace,
    expected_digests: Dict[str, str],
) -> ParsedEvidence:
    first_header = parse_ustar_header(reader.read_exact(512))
    if first_header.name != CATALOG_MEMBER or first_header.size > MAX_CATALOG_BYTES:
        refuse("release-state catalog is not the first bounded tar member")
    tar_offset = 512
    catalog_raw = reader.read_exact(first_header.size)
    tar_offset += first_header.size
    catalog_digest = hashlib.sha256(catalog_raw).hexdigest()
    padding = (-first_header.size) % 512
    if padding and any(reader.read_exact(padding)):
        refuse("release-state catalog padding is nonzero")
    tar_offset += padding
    entries, controls = parse_catalog(
        catalog_raw,
        args,
        expected_digests,
    )
    artifact_candidates = [
        entry for entry in entries if entry.source_path.startswith("artifacts/")
    ]
    if not 4 <= len(artifact_candidates) <= 70:
        refuse("release-state catalog artifact count is outside its strict bound")
    candidate_names: Set[str] = set()
    for entry in artifact_candidates:
        name = safe_basename(
            entry.source_path.split("/", 1)[1],
            "release artifact candidate",
        )
        if name not in FIXED_ARTIFACTS and not DEB_RE.fullmatch(name):
            refuse("release-state catalog has an unsafe artifact candidate")
        if name in candidate_names:
            refuse("release-state catalog duplicates an artifact candidate")
        candidate_names.add(name)
    if not set(FIXED_ARTIFACTS).issubset(candidate_names):
        refuse("release-state catalog omits a required control artifact")

    records: Dict[str, Snapshot] = {}
    text: Dict[str, bytes] = {}
    member_offsets: Dict[str, int] = {}
    captured_text_bytes = 0
    for entry in entries:
        header = parse_ustar_header(reader.read_exact(512))
        tar_offset += 512
        if header.name != entry.archive_path or header.size != entry.size:
            refuse("release-state tar order or member size differs from its catalog")
        member_offsets[entry.source_path] = tar_offset
        if collect_text(entry.source_path, entry.size):
            captured_text_bytes += entry.size
            if captured_text_bytes > MAX_CAPTURED_TEXT_BYTES:
                refuse("release-state semantic controls exceed their aggregate byte limit")
            capture: Optional[bytearray] = bytearray()
        else:
            capture = None
        digest = hashlib.sha256()
        remaining = entry.size
        while remaining:
            chunk = reader.read_exact(min(64 * 1024, remaining))
            remaining -= len(chunk)
            digest.update(chunk)
            if capture is not None:
                if len(capture) + len(chunk) > MAX_TEXT_BYTES:
                    refuse("release-state semantic control exceeds its byte limit")
                capture.extend(chunk)
        tar_offset += entry.size
        if padding := ((-entry.size) % 512):
            if any(reader.read_exact(padding)):
                refuse("release-state member padding is nonzero")
            tar_offset += padding
        actual = Snapshot(entry.size, digest.hexdigest())
        if actual != Snapshot(entry.size, entry.sha256):
            refuse("release-state tar member bytes differ from the catalog")
        records[entry.source_path] = actual
        if capture is not None:
            text[entry.source_path] = bytes(capture)

    if any(reader.read_exact(512)) or any(reader.read_exact(512)):
        refuse("release-state tar end marker is not exactly two zero blocks")
    tar_offset += 1024
    reader.require_eof()
    raw_snapshot = Snapshot(reader.raw_size, reader.raw_digest.hexdigest())
    if raw_snapshot.size != tar_offset:
        refuse("release-state tar byte length is not canonical")
    if catalog_digest != hashlib.sha256(catalog_raw).hexdigest():
        refuse("release-state catalog changed during parsing")
    return ParsedEvidence(
        entries,
        controls,
        records,
        text,
        member_offsets,
        raw_snapshot,
    )


def open_current_directory(path: Path, label: str) -> Tuple[int, Tuple[int, ...]]:
    try:
        mapped = path.lstat()
    except OSError:
        refuse(label + " could not be inspected")
    if (
        not stat.S_ISDIR(mapped.st_mode)
        or stat.S_ISLNK(mapped.st_mode)
        or stat.S_IMODE(mapped.st_mode) != 0o700
        or mapped.st_uid != os.geteuid()
    ):
        refuse(label + " is not an exact private real directory")
    expected = directory_identity(mapped)
    return open_expected_directory(path, expected, label), expected


def open_current_child_directory(
    parent: int,
    name: str,
    path: Path,
    label: str,
) -> Tuple[int, Tuple[int, ...]]:
    try:
        mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError:
        refuse(label + " could not be inspected")
    if (
        not stat.S_ISDIR(mapped.st_mode)
        or stat.S_ISLNK(mapped.st_mode)
        or stat.S_IMODE(mapped.st_mode) != 0o700
        or mapped.st_uid != os.geteuid()
    ):
        refuse(label + " is not an exact private real directory")
    expected = directory_identity(mapped)
    return (
        open_expected_child_directory(parent, name, path, expected, label),
        expected,
    )


def open_bound_regular(
    parent: int,
    name: str,
    expected: Snapshot,
    mode: int,
    label: str,
) -> HeldRegular:
    descriptor, snapshot = open_regular_at(parent, name, MAX_MEMBER_BYTES)
    try:
        held = os.fstat(descriptor)
        mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
        identity = stable_file_identity(held)
        if (
            snapshot != expected
            or not stat.S_ISREG(mapped.st_mode)
            or stat.S_IMODE(held.st_mode) != mode
            or held.st_nlink != 1
            or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            refuse(label + " does not match the retained evidence authority")
        return HeldRegular(parent, name, descriptor, snapshot, identity)
    except BaseException:
        os.close(descriptor)
        raise


def verify_held_regular_metadata(held_file: HeldRegular, label: str) -> None:
    try:
        held = os.fstat(held_file.descriptor)
        mapped = os.stat(
            held_file.name,
            dir_fd=held_file.parent,
            follow_symlinks=False,
        )
    except OSError:
        refuse(label + " mapping could not be revalidated")
    if (
        stable_file_identity(held) != held_file.identity
        or not stat.S_ISREG(mapped.st_mode)
        or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        refuse(label + " changed during retained evidence validation")


def open_current_control(
    parent: int,
    name: str,
    expected_sha256: str,
) -> HeldControl:
    try:
        mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError:
        refuse("release companion could not be inspected")
    return open_expected_control(
        parent,
        name,
        control_file_identity(mapped),
        expected_sha256,
    )


def verify_evidence_tar(args: argparse.Namespace) -> VerifiedEvidence:
    if not COMMIT_RE.fullmatch(args.support_head):
        refuse("support HEAD is not a full lowercase object ID")
    expected_digests = {
        "Docker build arguments": args.build_args_sha256,
        "Docker entrypoint": args.entrypoint_sha256,
        "OCI index": args.oci_index_sha256,
    }
    if not SHA256_RE.fullmatch(args.baseline_sha256) or any(
        not SHA256_RE.fullmatch(value) for value in expected_digests.values()
    ):
        refuse("evidence verification invocation contains a noncanonical SHA256")

    roots: List[int] = []
    controls: List[HeldControl] = []
    held_files: List[HeldRegular] = []
    evidence_descriptor: Optional[int] = None
    try:
        work_fd, expected_work = open_current_directory(
            args.work_root,
            "release work root",
        )
        roots.append(work_fd)
        artifacts_path = args.work_root / "artifacts"
        artifacts_fd, expected_artifacts = open_current_child_directory(
            work_fd,
            "artifacts",
            artifacts_path,
            "release artifacts root",
        )
        roots.append(artifacts_fd)
        require_exact_directory_names(
            work_fd,
            {"artifacts", EVIDENCE_TAR_NAME, *WORK_COMPANION_NAMES},
            "release work root for evidence verification",
        )

        for label, name in CONTROL_FILES:
            control = open_current_control(
                work_fd,
                name,
                expected_digests[label],
            )
            controls.append(control)
        evidence_descriptor = os.open(
            EVIDENCE_TAR_NAME,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=work_fd,
        )
        evidence_before = os.fstat(evidence_descriptor)
        evidence_mapped = os.stat(
            EVIDENCE_TAR_NAME,
            dir_fd=work_fd,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISREG(evidence_before.st_mode)
            or not stat.S_ISREG(evidence_mapped.st_mode)
            or stat.S_IMODE(evidence_before.st_mode) != 0o644
            or evidence_before.st_nlink != 1
            or (evidence_before.st_dev, evidence_before.st_ino)
            != (evidence_mapped.st_dev, evidence_mapped.st_ino)
        ):
            refuse("retained evidence tar is not an exact single-link regular file")
        evidence_identity = stable_file_identity(evidence_before)
        reader = BoundedDescriptorReader(evidence_descriptor)
        parsed = parse_evidence_reader(
            reader,
            args,
            expected_digests,
        )
        _expected_sources, publish_sources = semantic_source_set(
            parsed.records,
            parsed.text,
            args,
            parsed.controls,
        )
        for control in controls:
            expected = parsed.controls[
                dict((name, label) for label, name in CONTROL_FILES)[control.name]
            ]
            if control.snapshot != expected:
                refuse("release companion size differs from the retained catalog")

        expected_artifact_names: Set[str] = set()
        for source in sorted(publish_sources):
            if not source.startswith("artifacts/"):
                refuse("release-state publish set contains a non-artifact path")
            name = safe_basename(
                source.split("/", 1)[1],
                "verified release artifact",
            )
            expected_artifact_names.add(name)
            held_files.append(
                open_bound_regular(
                    artifacts_fd,
                    name,
                    parsed.records[source],
                    0o644,
                    "flat release artifact",
                )
            )
        require_exact_directory_names(
            artifacts_fd,
            expected_artifact_names,
            "release artifacts root for evidence verification",
        )

        work_boundary = stable_file_identity(os.fstat(work_fd))
        artifacts_boundary = stable_file_identity(os.fstat(artifacts_fd))
        require_exact_directory_names(
            work_fd,
            {"artifacts", EVIDENCE_TAR_NAME, *WORK_COMPANION_NAMES},
            "release work root at evidence boundary",
        )
        require_exact_directory_names(
            artifacts_fd,
            expected_artifact_names,
            "release artifacts root at evidence boundary",
        )
        verify_held_controls(work_fd, controls)
        for held_file in held_files:
            verify_held_regular_metadata(
                held_file,
                "retained evidence-bound file",
            )
        evidence_after = os.fstat(evidence_descriptor)
        evidence_mapped = os.stat(
            EVIDENCE_TAR_NAME,
            dir_fd=work_fd,
            follow_symlinks=False,
        )
        if (
            stable_file_identity(evidence_after) != evidence_identity
            or not stat.S_ISREG(evidence_mapped.st_mode)
            or (evidence_after.st_dev, evidence_after.st_ino)
            != (evidence_mapped.st_dev, evidence_mapped.st_ino)
            or verify_directory_mapping(
                work_fd,
                args.work_root,
                "release work root",
            )
            != expected_work
            or verify_directory_mapping(
                artifacts_fd,
                artifacts_path,
                "release artifacts root",
            )
            != expected_artifacts
            or stable_file_identity(os.fstat(work_fd)) != work_boundary
            or stable_file_identity(os.fstat(artifacts_fd)) != artifacts_boundary
        ):
            refuse("retained evidence authority changed at the validation boundary")
        return VerifiedEvidence(
            parsed.raw_snapshot,
            tuple(
                (
                    source.split("/", 1)[1],
                    parsed.records[source],
                )
                for source in sorted(publish_sources)
            ),
        )
    finally:
        if evidence_descriptor is not None:
            try:
                os.close(evidence_descriptor)
            except OSError:
                pass
        for held_file in reversed(held_files):
            try:
                os.close(held_file.descriptor)
            except OSError:
                pass
        for control in reversed(controls):
            try:
                os.close(control.descriptor)
            except OSError:
                pass
        for descriptor in reversed(roots):
            try:
                os.close(descriptor)
            except OSError:
                pass


def copy_published_member(
    evidence_descriptor: int,
    data_offset: int,
    entry: CatalogEntry,
    output: PublishedFile,
) -> None:
    digest = hashlib.sha256()
    copied = 0
    while copied < entry.size:
        chunk = os.pread(
            evidence_descriptor,
            min(1024 * 1024, entry.size - copied),
            data_offset + copied,
        )
        if not chunk:
            refuse("retained evidence member ended during final publication")
        write_all(output.descriptor, chunk)
        digest.update(chunk)
        copied += len(chunk)
    expected = Snapshot(entry.size, entry.sha256)
    if Snapshot(copied, digest.hexdigest()) != expected:
        refuse("final release asset differs from its validated evidence member")
    seal_published(output, expected)


def import_release_state(args: argparse.Namespace, success_output: bytes) -> None:
    if not COMMIT_RE.fullmatch(args.support_head):
        refuse("support HEAD is not a full lowercase object ID")
    if not RETAINED_VOLUME_RE.fullmatch(args.retained_volume_name):
        refuse("retained release-state volume name is not canonical")
    if not PLATFORM_RE.fullmatch(args.container_platform):
        refuse("release-state container platform is not canonical")
    if args.fixture_hook and "sp11-release-state-fixture." not in str(args.work_root):
        refuse("release-state fixture hook is outside its disposable fixture root")
    expected_digests = {
        "Docker build arguments": args.build_args_sha256,
        "Docker entrypoint": args.entrypoint_sha256,
        "OCI index": args.oci_index_sha256,
    }
    if not SHA256_RE.fullmatch(args.baseline_sha256) or any(
        not SHA256_RE.fullmatch(value) for value in expected_digests.values()
    ):
        refuse("import invocation contains a noncanonical SHA256")
    expected_work = tuple(args.work_root_identity)
    expected_artifacts = tuple(args.artifacts_root_identity)
    roots: List[int] = []
    held_controls: List[HeldControl] = []
    outputs: List[PublishedFile] = []
    exporters: List[ExporterProcess] = []
    pipe: Optional[BoundedPipe] = None
    container: Optional[ExporterContainer] = None
    committed = False
    try:
        blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT}
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
        try:
            work_fd = open_expected_directory(
                args.work_root,
                expected_work,
                "release work root",
            )
            roots.append(work_fd)
            artifacts_fd = open_expected_child_directory(
                work_fd,
                "artifacts",
                args.artifacts_root,
                expected_artifacts,
                "release artifacts root",
            )
            roots.append(artifacts_fd)
            companion_authorities = (
                (
                    "docker-build-args.txt",
                    tuple(args.build_args_identity),
                    args.build_args_sha256,
                ),
                (
                    "docker-build-inside.sh",
                    tuple(args.entrypoint_identity),
                    args.entrypoint_sha256,
                ),
                (
                    "sp11-oci-index.json",
                    tuple(args.oci_index_identity),
                    args.oci_index_sha256,
                ),
            )
            for name, identity, digest in companion_authorities:
                control = open_expected_control(work_fd, name, identity, digest)
                try:
                    roots.append(control.descriptor)
                except BaseException:
                    os.close(control.descriptor)
                    raise
                held_controls.append(control)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        with os.scandir(artifacts_fd) as iterator:
            try:
                next(iterator)
            except StopIteration:
                pass
            else:
                refuse("release artifacts root must be empty before import")
        require_exact_directory_names(
            work_fd,
            {"artifacts", *WORK_COMPANION_NAMES},
            "release work root before import",
        )

        evidence = acquire_published(outputs, work_fd, EVIDENCE_TAR_NAME)
        container = ExporterContainer(
            args.docker_path,
            args.command,
            require_read_only_exporter=True,
            retained_volume_name=args.retained_volume_name,
            expected_image_digest=args.oci_index_sha256,
            expected_platform=args.container_platform,
        )
        container.create()
        with cleanup_signal_mask() as child_signal_mask:
            container.require_read_only_mounts(child_signal_mask)
        exporter = acquire_exporter(exporters, container.start_command())
        if exporter.stdout is None or exporter.stderr is None:
            refuse("release-state exporter pipes are unavailable")
        pipe = BoundedPipe(exporter.stdout, exporter.stderr, evidence.descriptor)

        parsed = parse_evidence_reader(
            pipe,
            args,
            expected_digests,
        )
        exporter.finish()
        _expected_sources, publish_sources = semantic_source_set(
            parsed.records,
            parsed.text,
            args,
            parsed.controls,
        )

        with cleanup_signal_mask() as child_signal_mask:
            pipe.close()
            pipe = None
            exporter.close()
            container.require_successful_exit(child_signal_mask)
            container.remove(child_signal_mask)

        published_sources: Set[str] = set()
        for entry in parsed.entries:
            if entry.source_path not in publish_sources:
                continue
            artifact_name = safe_basename(
                entry.source_path.split("/", 1)[1],
                "release artifact name",
            )
            output = acquire_published(outputs, artifacts_fd, artifact_name)
            copy_published_member(
                evidence.descriptor,
                parsed.member_offsets[entry.source_path],
                entry,
                output,
            )
            published_sources.add(entry.source_path)
        if published_sources != publish_sources:
            refuse("release-state final asset publication set is incomplete")
        seal_published(evidence, parsed.raw_snapshot)
        with cleanup_signal_mask():
            for descriptor in (work_fd, artifacts_fd):
                try:
                    os.fsync(descriptor)
                except OSError:
                    if sys.platform != "darwin":
                        raise
            verify_output_group(
                outputs,
                held_controls,
                work_fd,
                args.work_root,
                artifacts_fd,
                args.artifacts_root,
                expected_work,
                expected_artifacts,
                args.fixture_hook,
            )
            if args.fixture_hook == "mutate-before-success":
                if not outputs or os.pwrite(outputs[0].descriptor, b"\0", 0) != 1:
                    refuse("release-state terminal mutation fixture failed")
                os.fsync(outputs[0].descriptor)
            elif args.fixture_hook == "pending-signal-before-success":
                os.kill(os.getpid(), signal.SIGTERM)
            elif args.fixture_hook == "pending-quit-before-success":
                os.kill(os.getpid(), signal.SIGQUIT)
            verify_terminal_output_boundary(
                outputs,
                held_controls,
                work_fd,
                args.work_root,
                artifacts_fd,
                args.artifacts_root,
                expected_work,
                expected_artifacts,
            )
            pending = signal.sigpending() & blocked
            if signal.SIGQUIT in pending:
                raise ReleaseStateQuit
            if pending:
                raise KeyboardInterrupt
            committed = True
            try:
                if args.fixture_hook == "pending-signal-after-commit":
                    os.kill(os.getpid(), signal.SIGTERM)
                elif args.fixture_hook == "pending-quit-after-commit":
                    os.kill(os.getpid(), signal.SIGQUIT)
                for handled in (
                    signal.SIGINT,
                    signal.SIGTERM,
                    signal.SIGHUP,
                    signal.SIGQUIT,
                ):
                    signal.signal(handled, signal.SIG_IGN)
                os.set_blocking(1, False)
                view = memoryview(success_output)
                while view:
                    written = os.write(1, view)
                    if written <= 0:
                        break
                    view = view[written:]
            except BaseException:
                pass
    finally:
        if committed:
            if pipe is not None:
                try:
                    pipe.close()
                except BaseException:
                    pass
            for exporter in exporters:
                exporter.close()
            close_outputs(outputs)
            for descriptor in reversed(roots):
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        else:
            with cleanup_signal_mask() as child_signal_mask:
                if pipe is not None:
                    try:
                        pipe.close()
                    except BaseException:
                        pass
                for exporter in exporters:
                    exporter.abort()
                    exporter.close()
                if container is not None:
                    try:
                        container.remove(child_signal_mask)
                    except BaseException:
                        pass
                scrub_outputs(outputs)
                close_outputs(outputs)
                for descriptor in reversed(roots):
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass


def run_release_container(args: argparse.Namespace) -> None:
    container = ExporterContainer(args.docker_path, args.command)
    children: List[ExporterProcess] = []
    completed = False
    try:
        container.create()
        child = acquire_exporter(children, container.start_command())
        relay_child_output(child)
        with cleanup_signal_mask() as child_signal_mask:
            child.close()
            container.require_successful_exit(child_signal_mask)
            container.remove(child_signal_mask)
            completed = True
    finally:
        if completed:
            for child in children:
                child.close()
        else:
            with cleanup_signal_mask() as child_signal_mask:
                for child in children:
                    child.abort()
                    child.close()
                try:
                    container.remove(child_signal_mask)
                except BaseException:
                    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--support-head", required=True)
    common.add_argument("--baseline-sha256", required=True)
    common.add_argument("--build-args-sha256", required=True)
    common.add_argument("--entrypoint-sha256", required=True)
    common.add_argument("--oci-index-sha256", required=True)
    common.add_argument("--container-image", required=True)
    common.add_argument("--container-platform", required=True)
    common.add_argument("--git-object-format", required=True, choices=("sha1", "sha256"))
    common.add_argument("--validator-argv-sha256", required=True)
    common.add_argument("--build-inputs-helper-size", required=True, type=int)
    common.add_argument("--build-inputs-helper-sha256", required=True)
    common.add_argument("--build-inputs-helper-object-id", required=True)
    common.add_argument("--manifest-validator-size", required=True, type=int)
    common.add_argument("--manifest-validator-sha256", required=True)
    common.add_argument("--manifest-validator-object-id", required=True)

    seal = subparsers.add_parser("seal", parents=[common])
    seal.add_argument("--work-root", required=True, type=Path)

    verifier = subparsers.add_parser("verify-evidence-tar", parents=[common])
    verifier.add_argument("--work-root", required=True, type=Path)

    importer = subparsers.add_parser("import-tar", parents=[common])
    importer.add_argument("--work-root", required=True, type=Path)
    importer.add_argument(
        "--work-root-identity",
        required=True,
        nargs=5,
        type=int,
        metavar=("DEVICE", "INODE", "MODE_BITS", "UID", "GID"),
    )
    importer.add_argument("--artifacts-root", required=True, type=Path)
    importer.add_argument(
        "--artifacts-root-identity",
        required=True,
        nargs=5,
        type=int,
        metavar=("DEVICE", "INODE", "MODE_BITS", "UID", "GID"),
    )
    importer.add_argument("--docker-path", required=True)
    importer.add_argument("--retained-volume-name", required=True)
    for option in ("build-args", "entrypoint", "oci-index"):
        importer.add_argument(
            "--" + option + "-identity",
            required=True,
            nargs=9,
            type=int,
            metavar=(
                "DEVICE",
                "INODE",
                "MODE_BITS",
                "SIZE",
                "MTIME_NS",
                "CTIME_NS",
                "NLINK",
                "UID",
                "GID",
            ),
        )
    importer.add_argument(
        "--fixture-hook",
        choices=(
            "inject-late-member",
            "inject-late-work-member",
            "mutate-output-after-wide-hashes",
            "mutate-before-success",
            "pending-signal-before-success",
            "pending-signal-after-commit",
            "pending-quit-before-success",
            "pending-quit-after-commit",
        ),
        default="",
        help=argparse.SUPPRESS,
    )
    importer.add_argument("command", nargs=argparse.REMAINDER)
    runner = subparsers.add_parser("run-container")
    runner.add_argument("--docker-path", required=True)
    runner.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.mode != "run-container":
        object_id_width = 40 if args.git_object_format == "sha1" else 64
        authority_digests = (
            args.validator_argv_sha256,
            args.build_inputs_helper_sha256,
            args.manifest_validator_sha256,
        )
        if (
            not PINNED_IMAGE_RE.fullmatch(args.container_image)
            or not PLATFORM_RE.fullmatch(args.container_platform)
            or any(not SHA256_RE.fullmatch(value) for value in authority_digests)
            or not (0 < args.build_inputs_helper_size <= 512 * 1024)
            or not (0 < args.manifest_validator_size <= 512 * 1024)
            or not re.fullmatch(
                r"[0-9a-f]{%d}" % object_id_width,
                args.build_inputs_helper_object_id,
            )
            or not re.fullmatch(
                r"[0-9a-f]{%d}" % object_id_width,
                args.manifest_validator_object_id,
            )
        ):
            parser.error("release validation authority arguments are noncanonical")
    if args.mode in ("import-tar", "run-container"):
        if not args.command or args.command[0] != "--" or len(args.command) < 2:
            parser.error(args.mode + " requires -- followed by the exact docker create command")
        args.command = args.command[1:]
    return args


def main() -> int:
    try:
        if sys.flags.isolated != 1:
            print("error: release-state helper requires isolated Python startup", file=sys.stderr)
            return 2
        install_signal_handlers()
        args = parse_args()
        success_output = b""
        if args.mode == "import-tar":
            if not RETAINED_VOLUME_RE.fullmatch(args.retained_volume_name):
                refuse("retained release-state volume name is not canonical")
            success_output = (
                b"Imported verified retained kernel release evidence and final assets.\n"
                + (
                    "Retained Docker release-state volume: %s\n"
                    % args.retained_volume_name
                ).encode("ascii")
                + b"Retained evidence tar: sp11-kernel-retained-evidence.tar\n"
                b"Publication authorized: false\n"
            )
        if args.mode == "seal":
            seal_release_state(args)
        elif args.mode == "verify-evidence-tar":
            verified = verify_evidence_tar(args)
            result = bytearray(
                (
                    "Verified retained evidence schema: sp11-kernel-evidence-verification-v1\n"
                    "Verified retained evidence tar: %d %s\n"
                    "Verified flat file count: %d\n"
                    % (
                        verified.raw.size,
                        verified.raw.sha256,
                        len(verified.flat_files),
                    )
                ).encode("ascii")
            )
            for index, (name, snapshot) in enumerate(verified.flat_files, 1):
                result.extend(
                    (
                        "Verified flat file %d: %s %d %s\n"
                        % (index, name, snapshot.size, snapshot.sha256)
                    ).encode("ascii")
                )
            result.extend(b"Verified retained evidence complete: true\n")
            if len(result) > MAX_TEXT_BYTES:
                refuse("retained evidence verification record is oversized")
            write_all(1, bytes(result))
        elif args.mode == "import-tar":
            import_release_state(args, success_output)
        else:
            run_release_container(args)
    except SystemExit:
        # Preserve argparse's conventional help/usage exit without converting
        # it into the unexpected-failure boundary below.
        raise
    except ReleaseStateError as exc:
        print("error: " + str(exc), file=sys.stderr)
        return 1
    except ReleaseStateQuit:
        print("error: release-state operation interrupted", file=sys.stderr)
        return 128 + signal.SIGQUIT
    except KeyboardInterrupt:
        print("error: release-state operation interrupted", file=sys.stderr)
        return 130
    except BaseException:
        print("error: unexpected release-state failure", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
