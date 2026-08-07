#!/usr/bin/env python3
"""Create or validate the immutable Docker-build input envelope."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import NoReturn


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
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
SUITES = (
    "resolute",
    "resolute-updates",
    "resolute-backports",
    "resolute-security",
)
COMPONENTS = ("main", "universe", "restricted", "multiverse")


def fail(message: str) -> NoReturn:
    raise SystemExit(f"error: {message}")


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


def regular_file(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular non-symlinked file")
    return metadata


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


def read_baseline(path: Path) -> dict[str, str]:
    regular_file(path, "baseline")
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
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


def exact_keys(fields: dict[str, str], expected: list[str], label: str) -> None:
    actual = list(fields)
    if actual != expected:
        missing = [key for key in expected if key not in fields]
        extra = [key for key in actual if key not in expected]
        fail(
            f"{label} field set/order mismatch; missing={missing or 'none'} "
            f"extra={extra or 'none'}"
        )


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


def positive_count(fields: dict[str, str], key: str, maximum: int = 100000) -> int:
    value = required(fields, key)
    if not value.isdigit() or int(value) <= 0 or int(value) > maximum:
        fail(f"{key} is invalid")
    return int(value)


def safe_input(work_dir: Path, path: Path, label: str) -> tuple[str, int, str]:
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


def expected_list_targets(snapshot_id: str, architecture: str) -> list[str]:
    names = ["lock"]
    for suite in SUITES:
        prefix = f"snapshot.ubuntu.com_ubuntu_{snapshot_id}_dists_{suite}"
        names.append(f"{prefix}_InRelease")
        for component in COMPONENTS:
            names.extend(
                (
                    f"{prefix}_{component}_binary-{architecture}_Packages.lz4",
                    f"{prefix}_{component}_source_Sources.lz4",
                )
            )
    return sorted(names)


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
        if not required(fields, keys[3]).isdigit() or int(fields[keys[3]]) <= 0:
            fail(f"APT sidecar index size is invalid at row {index}")
        digest = required(fields, keys[4])
        if not SHA256_RE.fullmatch(digest):
            fail(f"APT sidecar index hash is invalid at row {index}")
        expected_uri = (
            f"{snapshot_uri}dists/{suite}/{relative.rsplit('/', 1)[0]}"
            f"/by-hash/SHA256/{digest}"
        )
        if required(fields, keys[5]) != expected_uri:
            fail(f"APT sidecar by-hash URI is invalid at row {index}")

    list_paths = expected_list_targets(required(fields, "Snapshot ID"), architecture)
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


def clear_signed_sha256(path: Path) -> dict[str, tuple[int, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    try:
        message_start = lines.index("") + 1
        sha_start = lines.index("SHA256:", message_start) + 1
    except ValueError:
        fail(f"retained InRelease has an invalid clear-signed structure: {path.name}")
    entries: dict[str, tuple[int, str]] = {}
    for line in lines[sha_start:]:
        if not line.startswith(" "):
            break
        parts = line.split()
        if len(parts) != 3 or not SHA256_RE.fullmatch(parts[0]) or not parts[1].isdigit():
            fail(f"retained InRelease has an invalid SHA256 row: {path.name}")
        safe_relative(parts[2], "signed InRelease path")
        if parts[2] in entries:
            fail(f"retained InRelease has a duplicate SHA256 path: {path.name}")
        entries[parts[2]] = (int(parts[1]), parts[0])
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
    expected_index_files: set[Path] = set()
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
        expected_index_files.add(path)
        metadata = regular_file(path, f"retained index {suite}/{relative}")
        digest_value = sha256(path)
        if (
            metadata.st_size != int(fields[f"Index {row_index} size"])
            or digest_value != fields[f"Index {row_index} SHA256"]
            or signed_by_suite[suite].get(relative) != (metadata.st_size, digest_value)
        ):
            fail(f"retained index differs from signed InRelease/sidecar: {suite}/{relative}")
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
    actual_index_files = {path for path in indexes.rglob("*") if path.is_file()}
    if actual_index_files != expected_index_files or any(path.is_symlink() for path in indexes.rglob("*")):
        fail("retained APT index tree contains an extra, missing, or symlinked path")

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

    expected_list_names = expected_list_targets(snapshot_id, fields["Architecture"])
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

    local_paths = sorted(local_dir.glob("*-build-deps_*.deb"), key=lambda path: path.name)
    if len(local_paths) != 1 or local_paths[0].name != fields["Local build-deps 1 path"]:
        fail("retained local build-deps Deb set differs from sidecar")
    metadata = regular_file(local_paths[0], "retained local build-deps Deb")
    if metadata.st_size != int(fields["Local build-deps 1 size"]) or sha256(local_paths[0]) != fields[
        "Local build-deps 1 SHA256"
    ]:
        fail("retained local build-deps Deb differs from sidecar")


def retained_snapshot(args: argparse.Namespace) -> tuple[tuple[object, ...], ...]:
    rows: list[tuple[object, ...]] = []
    for label, root in (
        ("archives", args.apt_archives_dir),
        ("indexes", args.apt_index_cache_dir),
        ("lists", args.apt_lists_dir),
    ):
        real_directory(root, f"retained {label}")
        for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
            metadata = path.lstat()
            relative = path.relative_to(root).as_posix()
            if stat.S_ISDIR(metadata.st_mode) and not path.is_symlink():
                rows.append((label, relative + "/", 0, "directory"))
            elif stat.S_ISREG(metadata.st_mode):
                rows.append((label, relative, *stable_file_snapshot(path, f"retained {label}/{relative}")))
            else:
                fail(f"retained {label} contains a symlink or special path: {relative}")
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
        rows.append((label, path.name, *stable_file_snapshot(path, label)))
    for path in sorted(args.apt_local_build_deps_dir.glob("*-build-deps_*.deb")):
        rows.append(
            (
                "local-build-deps",
                path.name,
                *stable_file_snapshot(path, "local build-deps snapshot"),
            )
        )
    return tuple(rows)


def validate_oci_index(path: Path, baseline: dict[str, str]) -> None:
    raw = path.read_bytes()
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
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
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
    for index, (role, path) in enumerate(zip(INPUT_ROLES, inputs), 1):
        relative, size, digest = safe_input(args.work_dir, path, role)
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
    command = (
        sys.executable,
        str(validator),
        "--build-only",
        "--repo-dir",
        str(repo_dir),
        "--support-commit",
        support_head,
        "--kernel-build-manifest",
        str(path),
    )
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
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

    validate_attached(args, baseline)
    apt_fields = validate_apt_sidecar(args.apt_provenance, baseline)
    validate_retained_apt(args, apt_fields, baseline)
    validate_oci_index(args.oci_index, baseline)

    envelope = parse_unique_lines(args.output)
    live_inputs = (args.build_args, args.entrypoint, args.oci_index)
    expected_paths = (
        "docker-build-args.txt",
        "docker-build-inside.sh",
        "sp11-oci-index.json",
    )
    for index, (role, path, expected_path) in enumerate(
        zip(INPUT_ROLES[:3], live_inputs, expected_paths), 1
    ):
        relative, size, digest = safe_input(args.work_dir, path, role)
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
    args = parse_args()
    if not COMMIT_RE.fullmatch(args.support_head):
        fail("support HEAD must be a full lowercase commit")
    baseline = read_baseline(args.baseline)
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
    before = retained_snapshot(args)
    written_output_snapshot: tuple[int, int, int, int, int, str] | None = None
    validate_exact_build_manifest(args.build_manifest, args.support_head)
    validate_manifest(args.build_manifest, baseline, args.support_head)
    apt_fields = validate_apt_sidecar(args.apt_provenance, baseline)
    validate_retained_apt(args, apt_fields, baseline)
    validate_oci_index(args.oci_index, baseline)
    if retained_snapshot(args) != before:
        fail("retained APT inputs changed during pre-envelope validation")

    if args.mode == "write":
        inputs = (
            args.build_args,
            args.entrypoint,
            args.oci_index,
            args.build_manifest,
            args.apt_provenance,
        )
        rows = [
            safe_input(args.work_dir, path, role)
            for role, path in zip(INPUT_ROLES, inputs)
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
        if args.output.parent.is_symlink() or not args.output.parent.is_dir():
            fail("build-inputs output parent must be real")
        if args.output.is_symlink() or (args.output.exists() and not args.output.is_file()):
            fail("build-inputs output path is unsafe")
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=".sp11-kernel-build-inputs.", dir=args.output.parent
        )
        temporary_path = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
                handle.write("\n".join(lines) + "\n")
            os.chmod(temporary_path, 0o644)
            os.replace(temporary_path, args.output)
        finally:
            if temporary_path.exists():
                temporary_path.unlink()
        written_output_snapshot = stable_file_snapshot(
            args.output, "new build-inputs envelope"
        )

    validate_envelope(args, baseline)
    apt_fields = validate_apt_sidecar(args.apt_provenance, baseline)
    validate_retained_apt(args, apt_fields, baseline)
    if retained_snapshot(args) != before:
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
