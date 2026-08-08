#!/usr/bin/env python3
"""Acquire and inventory immutable, authenticated APT build inputs."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import re
import stat
import subprocess
import tempfile
from pathlib import Path, PurePosixPath
from typing import NoReturn


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
BASELINE_RE = re.compile(r'^([A-Z0-9_]+)="([^"\r\n]*)"$')
PACKAGE_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]*$")
VERSION_RE = re.compile(r"^[0-9A-Za-z.+:~_-]+$")
ARCH_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
INVENTORY_RE = re.compile(
    r"^[a-z0-9][a-z0-9+.-]*:[a-z0-9][a-z0-9-]*=[0-9A-Za-z.+:~_-]+$"
)
PATH_COMPONENT_RE = re.compile(r"^[0-9A-Za-z.+%_~:@=-]+$")


def fail(message: str) -> NoReturn:
    raise SystemExit(f"error: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def regular_file(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular non-symlinked file")
    return metadata


def real_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if not stat.S_ISDIR(metadata.st_mode) or resolved != path.absolute():
        fail(f"{label} must have no symlinked path components")
    return resolved


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


def required(values: dict[str, str], key: str) -> str:
    value = values.get(key, "")
    if not value:
        fail(f"baseline variable is empty or missing: {key}")
    return value


def run_field(path: Path, field: str) -> str:
    try:
        result = subprocess.run(
            ["dpkg-deb", "-f", str(path), field],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        fail(f"could not inspect {field} in {path.name}: {exc}")
    value = result.stdout.strip()
    if not value or "\n" in value or "\r" in value:
        fail(f"invalid {field} field in {path.name}")
    return value


def iter_deb822(handle: object) -> object:
    fields: dict[str, str] = {}
    for raw_line in handle:  # type: ignore[union-attr]
        line = raw_line.rstrip("\n")
        if "\r" in line:
            fail("retained package index contains a carriage return")
        if not line:
            if fields:
                yield fields
                fields = {}
            continue
        if line[0].isspace():
            continue
        if ":" not in line:
            fail("retained package index contains a malformed Deb822 line")
        key, value = line.split(":", 1)
        if key in fields:
            fail(f"duplicate Deb822 field: {key}")
        fields[key] = value.strip()
    if fields:
        yield fields


def safe_relative_path(value: str, label: str) -> PurePosixPath:
    if not value or value.startswith("/") or "\\" in value or any(
        part in ("", ".", "..") or not PATH_COMPONENT_RE.fullmatch(part)
        for part in value.split("/")
    ):
        fail(f"unsafe {label}: {value}")
    path = PurePosixPath(value)
    if path.as_posix() != value:
        fail(f"non-canonical {label}: {value}")
    return path


def clear_signed_lines(path: Path) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"could not read InRelease {path.name}: {exc}")
    try:
        start = lines.index("") + 1
    except ValueError:
        fail(f"invalid clear-signed InRelease structure: {path.name}")
    result: list[str] = []
    saw_signature = False
    for line in lines[start:]:
        if line == "-----BEGIN PGP SIGNATURE-----":
            saw_signature = True
            break
        result.append(line[2:] if line.startswith("- ") else line)
    if not saw_signature:
        fail(f"clear-signed InRelease has no signature block: {path.name}")
    return result


def signed_sha256_entries(path: Path) -> dict[str, tuple[int, str]]:
    lines = clear_signed_lines(path)
    try:
        start = lines.index("SHA256:") + 1
    except ValueError:
        fail(f"InRelease has no SHA256 section: {path.name}")
    entries: dict[str, tuple[int, str]] = {}
    for line in lines[start:]:
        if not line.startswith(" "):
            break
        parts = line.split()
        if (
            len(parts) != 3
            or not SHA256_RE.fullmatch(parts[0])
            or not parts[1].isdigit()
            or int(parts[1]) <= 0
        ):
            fail(f"invalid SHA256 entry in {path.name}")
        safe_relative_path(parts[2], "signed index path")
        if parts[2] in entries:
            fail(f"duplicate SHA256 path in {path.name}: {parts[2]}")
        entries[parts[2]] = (int(parts[1]), parts[0])
    return entries


def expected_index_rows(
    baseline: dict[str, str], lists_dir: Path
) -> list[tuple[str, str, int, str, str]]:
    snapshot_id = required(baseline, "SP11_APT_SNAPSHOT_ID")
    snapshot_uri = required(baseline, "SP11_APT_SNAPSHOT_URI")
    suites = required(baseline, "SP11_APT_SNAPSHOT_SUITES").split()
    components = required(baseline, "SP11_APT_SNAPSHOT_COMPONENTS").split()
    architecture = required(baseline, "SP11_APT_SNAPSHOT_ARCHITECTURE")
    if suites != [
        "resolute",
        "resolute-updates",
        "resolute-backports",
        "resolute-security",
    ]:
        fail("baseline suite order is not the reviewed four-pocket order")
    rows: list[tuple[str, str, int, str, str]] = []
    for suite in suites:
        inrelease = (
            lists_dir
            / f"snapshot.ubuntu.com_ubuntu_{snapshot_id}_dists_{suite}_InRelease"
        )
        entries = signed_sha256_entries(inrelease)
        suite_count = 0
        for component in components:
            for relative in (
                f"{component}/binary-{architecture}/Packages.gz",
                f"{component}/source/Sources.gz",
            ):
                if relative not in entries:
                    continue
                size, digest = entries[relative]
                parent = relative.rsplit("/", 1)[0]
                uri = (
                    f"{snapshot_uri}dists/{suite}/{parent}/by-hash/SHA256/{digest}"
                )
                rows.append((suite, relative, size, digest, uri))
                suite_count += 1
        if suite_count == 0:
            fail(f"no authenticated ARM64/source index entries found for {suite}")
    expected_count = int(required(baseline, "SP11_APT_AUTHENTICATED_INDEX_COUNT"))
    if len(rows) != expected_count or expected_count != len(suites) * len(components) * 2:
        fail(
            "authenticated index set is not the exact reviewed "
            f"4x4x2 set; found {len(rows)}"
        )
    return rows


def authenticated_binary_records(
    cache_dir: Path,
    index_rows: list[tuple[str, str, int, str, str]],
    wanted: set[tuple[str, str, str]],
) -> dict[tuple[str, str, str], list[tuple[int, str, str, str]]]:
    records: dict[
        tuple[str, str, str], list[tuple[int, str, str, str]]
    ] = {}
    for suite, relative, _size, _digest, _uri in index_rows:
        if not relative.endswith("/Packages.gz"):
            continue
        path = cache_dir / suite / relative
        try:
            with gzip.open(path, "rt", encoding="utf-8", errors="strict") as handle:
                paragraphs = iter_deb822(handle)
                for fields in paragraphs:
                    needed = ("Package", "Version", "Architecture", "Size", "SHA256", "Filename")
                    if any(not fields.get(field) for field in needed):
                        fail(f"incomplete package record in retained index {suite}/{relative}")
                    package = fields["Package"]
                    version = fields["Version"]
                    architecture = fields["Architecture"]
                    size_text = fields["Size"]
                    digest = fields["SHA256"]
                    filename = fields["Filename"]
                    if (
                        not PACKAGE_RE.fullmatch(package)
                        or not VERSION_RE.fullmatch(version)
                        or not ARCH_RE.fullmatch(architecture)
                        or not size_text.isdigit()
                        or int(size_text) <= 0
                        or not SHA256_RE.fullmatch(digest)
                    ):
                        fail(f"invalid package record in retained index {suite}/{relative}")
                    safe_relative_path(filename, "archive Filename")
                    key = (package, version, architecture)
                    if key in wanted:
                        records.setdefault(key, []).append(
                            (int(size_text), digest, filename, f"{suite}/{relative}")
                        )
        except (OSError, UnicodeDecodeError, EOFError) as exc:
            fail(f"could not parse retained signed index {suite}/{relative}: {exc}")
    return records


def ensure_empty_directory(path: Path, label: str) -> None:
    real_directory(path, label)
    if any(path.iterdir()):
        fail(f"{label} must start empty")


def apt_helper_path() -> Path:
    fixture_value = os.environ.get("SP11_APT_FIXTURE_ROOT", "")
    override = os.environ.get("SP11_APT_HELPER", "")
    if fixture_value:
        fixture_root = real_directory(Path(fixture_value), "APT fixture root")
        if not override:
            fail("fixture mode requires SP11_APT_HELPER")
        helper = Path(override)
        expected = fixture_root / "mock-bin/apt-helper"
        if helper != expected:
            fail("fixture apt-helper must be the exact fixture-root/mock-bin/apt-helper path")
        regular_file(helper, "fixture apt-helper")
        try:
            resolved = helper.resolve(strict=True)
        except OSError as exc:
            fail(f"could not resolve fixture apt-helper: {exc}")
        if resolved != helper.absolute():
            fail("fixture apt-helper must have no symlinked path components")
        return helper

    if override:
        fail("SP11_APT_HELPER is fixture-only")
    helper = Path("/usr/lib/apt/apt-helper")
    regular_file(helper, "apt-helper")
    return helper


def acquire_indexes(args: argparse.Namespace, baseline: dict[str, str]) -> None:
    lists_dir = real_directory(args.lists_dir, "APT lists directory")
    cache_dir = real_directory(args.index_cache_dir, "APT index cache directory")
    ensure_empty_directory(cache_dir, "APT index cache directory")
    rows = expected_index_rows(baseline, lists_dir)
    helper = apt_helper_path()

    for suite, relative, expected_size, expected_digest, uri in rows:
        target = cache_dir / suite / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.parent.resolve(strict=True) != target.parent.absolute():
            fail("APT index target has a symlinked parent")
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=".sp11-index.", dir=cache_dir
        )
        os.close(descriptor)
        temporary = Path(temporary_name)
        temporary.unlink()
        try:
            subprocess.run(
                [
                    str(helper),
                    "download-file",
                    uri,
                    str(temporary),
                    f"SHA256:{expected_digest}",
                ],
                check=True,
            )
            metadata = regular_file(temporary, "acquired authenticated index")
            if metadata.st_size != expected_size or sha256(temporary) != expected_digest:
                fail(f"acquired index bytes differ from signed metadata: {suite}/{relative}")
            os.chmod(temporary, 0o644)
            os.replace(temporary, target)
        except (OSError, subprocess.CalledProcessError) as exc:
            fail(f"could not acquire authenticated index {suite}/{relative}: {exc}")
        finally:
            if temporary.exists():
                temporary.unlink()
    print(f"Retained {len(rows)} authenticated gzip indexes under {cache_dir}")


def read_inventory(path: Path, label: str) -> tuple[list[str], str]:
    regular_file(path, label)
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"could not read {label}: {exc}")
    if not raw or not raw.endswith(b"\n") or b"\r" in raw:
        fail(f"{label} must be non-empty LF-terminated UTF-8")
    rows = text.splitlines()
    if rows != sorted(rows) or len(rows) != len(set(rows)):
        fail(f"{label} must contain unique C-locale sorted rows")
    for row in rows:
        if not INVENTORY_RE.fullmatch(row):
            fail(f"{label} contains an invalid package identity: {row}")
    return rows, hashlib.sha256(raw).hexdigest()


def list_targets(lists_dir: Path) -> list[tuple[str, int, str]]:
    rows: list[tuple[str, int, str]] = []
    allowed_dirs = {"auxfiles", "partial"}
    for entry in sorted(lists_dir.iterdir(), key=lambda item: item.name):
        metadata = entry.lstat()
        if stat.S_ISDIR(metadata.st_mode) and not entry.is_symlink():
            if entry.name not in allowed_dirs:
                fail(f"unexpected APT list directory: {entry.name}")
            if any(entry.iterdir()):
                fail(f"APT list directory is not empty at finalization: {entry.name}")
            continue
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"unsafe APT list target: {entry.name}")
        if entry.name != "lock" and not re.fullmatch(
            r"snapshot\.ubuntu\.com_ubuntu_[0-9]{8}T[0-9]{6}Z_dists_"
            r"[a-z0-9-]+_(?:InRelease|[a-z]+_(?:binary-arm64_Packages|source_Sources)\.lz4)",
            entry.name,
        ):
            fail(f"unexpected APT list target: {entry.name}")
        rows.append((entry.name, metadata.st_size, sha256(entry)))
    return rows


def validate_archive_layout(archives_dir: Path) -> list[Path]:
    debs: list[Path] = []
    for entry in sorted(archives_dir.iterdir(), key=lambda item: item.name):
        metadata = entry.lstat()
        if entry.name == "partial" and stat.S_ISDIR(metadata.st_mode) and not entry.is_symlink():
            if any(entry.iterdir()):
                fail("APT archive partial directory is not empty at finalization")
            continue
        if entry.name == "lock" and stat.S_ISREG(metadata.st_mode):
            continue
        if entry.name.endswith(".deb") and stat.S_ISREG(metadata.st_mode):
            debs.append(entry)
            continue
        fail(f"unexpected or unsafe APT archive entry: {entry.name}")
    return debs


def decompressed_gzip_identity(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    try:
        with gzip.open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                size += len(chunk)
                digest.update(chunk)
    except (OSError, EOFError) as exc:
        fail(f"could not decompress retained signed index {path}: {exc}")
    return size, digest.hexdigest()


def apt_list_identity(path: Path) -> tuple[int, str]:
    helper = apt_helper_path()
    digest = hashlib.sha256()
    size = 0
    try:
        process = subprocess.Popen(
            [str(helper), "cat-file", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        fail(f"could not start apt-helper for {path.name}: {exc}")
    assert process.stdout is not None
    for chunk in iter(lambda: process.stdout.read(1024 * 1024), b""):
        size += len(chunk)
        digest.update(chunk)
    _stdout, stderr = process.communicate()
    if process.returncode != 0:
        fail(
            f"could not decompress acquired APT list target {path.name}: "
            f"{stderr.decode('utf-8', errors='replace').strip()}"
        )
    return size, digest.hexdigest()


def verify_local_index_views(
    baseline: dict[str, str],
    lists_dir: Path,
    cache_dir: Path,
    index_rows: list[tuple[str, str, int, str, str]],
) -> None:
    snapshot_id = required(baseline, "SP11_APT_SNAPSHOT_ID")
    for suite, relative, _size, _digest, _uri in index_rows:
        retained = cache_dir / suite / relative
        list_name = (
            f"snapshot.ubuntu.com_ubuntu_{snapshot_id}_dists_{suite}_"
            f"{relative[:-3].replace('/', '_')}.lz4"
        )
        local = lists_dir / list_name
        regular_file(local, "acquired APT list target")
        if decompressed_gzip_identity(retained) != apt_list_identity(local):
            fail(
                "acquired APT list bytes differ from the retained signed gzip "
                f"index: {suite}/{relative}"
            )


def append_entry(
    lines: list[str], prefix: str, index: int, values: list[tuple[str, object]]
) -> None:
    for label, value in values:
        lines.append(f"{prefix} {index} {label}: {value}")


def write_provenance(args: argparse.Namespace, baseline: dict[str, str]) -> None:
    archives_dir = real_directory(args.archives_dir, "APT archives directory")
    lists_dir = real_directory(args.lists_dir, "APT lists directory")
    index_cache_dir = real_directory(args.index_cache_dir, "APT index cache directory")
    local_dir = real_directory(args.local_build_deps_dir, "local build-deps directory")
    pre_rows, pre_aggregate = read_inventory(args.pre_inventory, "pre-install inventory")
    post_rows, post_aggregate = read_inventory(args.post_inventory, "post-install inventory")

    snapshot_id = required(baseline, "SP11_APT_SNAPSHOT_ID")
    snapshot_uri = required(baseline, "SP11_APT_SNAPSHOT_URI")
    suites = required(baseline, "SP11_APT_SNAPSHOT_SUITES").split()
    components = required(baseline, "SP11_APT_SNAPSHOT_COMPONENTS").split()
    architecture = required(baseline, "SP11_APT_SNAPSHOT_ARCHITECTURE")

    inrelease_rows: list[tuple[str, str, int]] = []
    for suite in suites:
        suffix = suite.upper().replace("-", "_")
        expected_digest = required(baseline, f"SP11_APT_INRELEASE_{suffix}_SHA256")
        path = (
            lists_dir
            / f"snapshot.ubuntu.com_ubuntu_{snapshot_id}_dists_{suite}_InRelease"
        )
        metadata = regular_file(path, f"{suite} InRelease")
        actual_digest = sha256(path)
        if actual_digest != expected_digest:
            fail(f"InRelease changed before provenance finalization: {suite}")
        inrelease_rows.append((suite, actual_digest, metadata.st_size))

    index_rows = expected_index_rows(baseline, lists_dir)
    for suite, relative, expected_size, expected_digest, _uri in index_rows:
        retained = index_cache_dir / suite / relative
        metadata = regular_file(retained, "retained authenticated gzip index")
        if metadata.st_size != expected_size or sha256(retained) != expected_digest:
            fail(f"retained index does not match signed metadata: {suite}/{relative}")
    expected_retained = {index_cache_dir / row[0] / row[1] for row in index_rows}
    actual_retained = {path for path in index_cache_dir.rglob("*") if path.is_file()}
    if actual_retained != expected_retained:
        fail("APT index cache contains an extra or missing retained file")
    for path in index_cache_dir.rglob("*"):
        if path.is_symlink():
            fail("APT index cache contains a symlink")
    verify_local_index_views(baseline, lists_dir, index_cache_dir, index_rows)

    cached_rows: list[tuple[Path, str, str, str, int, str]] = []
    for path in validate_archive_layout(archives_dir):
        metadata = regular_file(path, "cached Deb")
        package = run_field(path, "Package")
        version = run_field(path, "Version")
        deb_architecture = run_field(path, "Architecture")
        if (
            not PACKAGE_RE.fullmatch(package)
            or not VERSION_RE.fullmatch(version)
            or not ARCH_RE.fullmatch(deb_architecture)
        ):
            fail(f"unsafe cached Deb identity: {path.name}")
        digest = sha256(path)
        cached_rows.append(
            (path, package, version, deb_architecture, metadata.st_size, digest)
        )
    if not cached_rows:
        fail("APT archive contains no retained Debs")

    wanted = {(row[1], row[2], row[3]) for row in cached_rows}
    package_records = authenticated_binary_records(index_cache_dir, index_rows, wanted)
    deb_rows: list[tuple[str, str, str, str, int, str, str, str, tuple[str, ...]]] = []
    for path, package, version, deb_architecture, size, digest in cached_rows:
        matches = package_records.get((package, version, deb_architecture), [])
        if not matches:
            fail(
                "cached Deb has no record in the retained signed Packages.gz set: "
                f"{package}={version}/{deb_architecture}"
            )
        if any(row_size != size or row_digest != digest for row_size, row_digest, _name, _location in matches):
            fail(
                "retained signed indexes contain conflicting size/hash metadata for "
                f"{package}={version}/{deb_architecture}"
            )
        filenames = {row[2] for row in matches}
        if len(filenames) != 1:
            fail(
                "retained signed indexes contain conflicting archive filenames for "
                f"{package}={version}/{deb_architecture}"
            )
        locations = tuple(row[3] for row in matches)
        if len(locations) != len(set(locations)):
            fail(
                "retained signed indexes duplicate a package record within one index: "
                f"{package}={version}/{deb_architecture}"
            )
        filename = next(iter(filenames))
        deb_rows.append(
            (
                path.name,
                package,
                version,
                deb_architecture,
                size,
                digest,
                filename,
                snapshot_uri + filename,
                locations,
            )
        )
    bootstrap_count = int(required(baseline, "SP11_APT_BOOTSTRAP_PACKAGE_COUNT"))
    observed = {(row[1], row[2], row[5]) for row in deb_rows}
    for index in range(1, bootstrap_count + 1):
        spec = required(baseline, f"SP11_APT_BOOTSTRAP_PACKAGE_{index}_SPEC")
        expected_digest = required(
            baseline, f"SP11_APT_BOOTSTRAP_PACKAGE_{index}_SHA256"
        )
        package, version = spec.split("=", 1)
        if (package, version, expected_digest) not in observed:
            fail(f"bootstrap package is absent from retained Deb lock: {spec}")
    python_spec = required(baseline, "SP11_APT_PYTHON_PACKAGE_SPEC")
    python_package, python_version = python_spec.split("=", 1)
    python_architecture = required(baseline, "SP11_APT_SNAPSHOT_ARCHITECTURE")
    if not any(
        row[1] == python_package
        and row[2] == python_version
        and row[3] == python_architecture
        for row in deb_rows
    ):
        fail(f"snapshot Python package is absent from retained Deb lock: {python_spec}")

    local_paths = sorted(local_dir.glob("*-build-deps_*.deb"), key=lambda item: item.name)
    if len(local_paths) != 1:
        fail(f"expected exactly one retained local build-deps Deb; found {len(local_paths)}")
    local_rows: list[tuple[str, str, str, str, int, str]] = []
    for path in local_paths:
        metadata = regular_file(path, "local build-deps Deb")
        package = run_field(path, "Package")
        version = run_field(path, "Version")
        deb_architecture = run_field(path, "Architecture")
        if (
            not PACKAGE_RE.fullmatch(package)
            or not VERSION_RE.fullmatch(version)
            or not ARCH_RE.fullmatch(deb_architecture)
        ):
            fail(f"unsafe local build-deps identity: {path.name}")
        local_rows.append(
            (
                path.name,
                package,
                version,
                deb_architecture,
                metadata.st_size,
                sha256(path),
            )
        )

    target_rows = list_targets(lists_dir)
    lines = [
        "APT provenance schema: sp11-kernel-apt-provenance-v1",
        f"Snapshot ID: {snapshot_id}",
        f"Snapshot URI: {snapshot_uri}",
        f"Suites: {' '.join(suites)}",
        f"Components: {' '.join(components)}",
        f"Architecture: {architecture}",
        f"Archive keyring SHA256: {required(baseline, 'SP11_APT_ARCHIVE_KEYRING_SHA256')}",
        f"Archive signing fingerprint: {required(baseline, 'SP11_APT_ARCHIVE_SIGNING_FINGERPRINT')}",
        "Strict HTTPS recheck: true",
        f"Pre-install package count: {len(pre_rows)}",
        f"Pre-install package aggregate SHA256: {pre_aggregate}",
    ]
    for index, row in enumerate(pre_rows, 1):
        lines.append(f"Pre-install package {index}: {row}")
    lines.extend(
        (
            f"Post-install package count: {len(post_rows)}",
            f"Post-install package aggregate SHA256: {post_aggregate}",
        )
    )
    for index, row in enumerate(post_rows, 1):
        lines.append(f"Post-install package {index}: {row}")
    lines.append(f"InRelease count: {len(inrelease_rows)}")
    for index, (suite, digest, size) in enumerate(inrelease_rows, 1):
        append_entry(
            lines,
            "InRelease",
            index,
            [("suite", suite), ("size", size), ("SHA256", digest)],
        )
    lines.append(f"Index count: {len(index_rows)}")
    for index, (suite, path, size, digest, uri) in enumerate(index_rows, 1):
        append_entry(
            lines,
            "Index",
            index,
            [
                ("suite", suite),
                ("path", path),
                ("retained path", f"{suite}/{path}"),
                ("size", size),
                ("SHA256", digest),
                ("URI", uri),
            ],
        )
    lines.append(f"APT list target count: {len(target_rows)}")
    for index, (path, size, digest) in enumerate(target_rows, 1):
        append_entry(
            lines,
            "APT list target",
            index,
            [("path", path), ("size", size), ("SHA256", digest)],
        )
    lines.append(f"Downloaded Deb count: {len(deb_rows)}")
    for index, row in enumerate(deb_rows, 1):
        name, package, version, deb_arch, size, digest, archive_filename, uri, locations = row
        append_entry(
            lines,
            "Downloaded Deb",
            index,
            [
                ("path", name),
                ("package", package),
                ("version", version),
                ("architecture", deb_arch),
                ("size", size),
                ("SHA256", digest),
                ("archive filename", archive_filename),
                ("URI", uri),
                ("signed record count", len(locations)),
            ],
        )
        for record_index, location in enumerate(locations, 1):
            lines.append(
                f"Downloaded Deb {index} signed record {record_index} location: {location}"
            )
    lines.append(f"Local build-deps count: {len(local_rows)}")
    for index, row in enumerate(local_rows, 1):
        name, package, version, deb_arch, size, digest = row
        append_entry(
            lines,
            "Local build-deps",
            index,
            [
                ("path", name),
                ("package", package),
                ("version", version),
                ("architecture", deb_arch),
                ("size", size),
                ("SHA256", digest),
            ],
        )
    lines.append("APT provenance complete: true")

    rendered = ("\n".join(lines) + "\n").encode("utf-8")
    if args.mode == "validate":
        regular_file(args.output, "APT provenance sidecar")
        if args.output.read_bytes() != rendered:
            fail("APT provenance sidecar differs from deterministic retained-input recomputation")
        print(f"Validated immutable APT provenance: {args.output}")
        return

    output_parent = real_directory(args.output.parent, "APT provenance output parent")
    if args.output.is_symlink() or (args.output.exists() and not args.output.is_file()):
        fail("APT provenance output path is unsafe")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".sp11-kernel-apt-provenance.", dir=output_parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(rendered.decode("utf-8"))
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, args.output)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()
    print(f"Wrote immutable APT provenance: {args.output}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("acquire-indexes", "write", "validate"))
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--lists-dir", required=True, type=Path)
    parser.add_argument("--index-cache-dir", required=True, type=Path)
    parser.add_argument("--archives-dir", type=Path)
    parser.add_argument("--local-build-deps-dir", type=Path)
    parser.add_argument("--pre-inventory", type=Path)
    parser.add_argument("--post-inventory", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.mode in ("write", "validate"):
        for name in (
            "archives_dir",
            "local_build_deps_dir",
            "pre_inventory",
            "post_inventory",
            "output",
        ):
            if getattr(args, name) is None:
                parser.error(f"write requires --{name.replace('_', '-')}")
    return args


def main() -> None:
    args = parse_args()
    baseline = read_baseline(args.baseline)
    if args.mode == "acquire-indexes":
        acquire_indexes(args, baseline)
    else:
        write_provenance(args, baseline)


if __name__ == "__main__":
    main()
