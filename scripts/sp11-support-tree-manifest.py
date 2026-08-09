#!/usr/bin/env python3
"""Generate or verify the committed support tree embedded in an SP11 image."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
import stat
from dataclasses import dataclass
from pathlib import Path


OID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
SAFE_PATH = re.compile(r"[A-Za-z0-9._+/-]+\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SUPPORT_ROOTS = ("README.md", "docs", "patches", "scripts", "tools")
MANIFEST_NAME = ".sp11-support-tree-v1"
MAX_FILES = 20000
MAX_TOTAL_BYTES = 512 * 1024 * 1024


class ValidationError(Exception):
    """An expected, user-facing support-tree validation failure."""


@dataclass(frozen=True)
class Entry:
    mode: str
    sha256: str
    size: int
    path: str


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def isolated_git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    redirected_names = {
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CEILING_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_CONFIG",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_GLOBAL",
        "GIT_DIR",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM",
        "GIT_EXEC_PATH",
        "GIT_INDEX_FILE",
        "GIT_NAMESPACE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_PREFIX",
        "GIT_SHALLOW_FILE",
        "GIT_WORK_TREE",
    }
    for name in list(environment):
        if name in redirected_names or re.fullmatch(
            r"GIT_CONFIG_(?:KEY|VALUE)_[0-9]+", name
        ):
            environment.pop(name, None)
    environment.update(
        {
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
        }
    )
    return environment


def run_git(repo: Path, arguments: list[str]) -> bytes:
    try:
        result = subprocess.run(
            ["git", "-c", f"safe.directory={repo}", "-C", str(repo), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=isolated_git_environment(),
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", b"")
        if isinstance(detail, bytes):
            detail = detail.decode("utf-8", "replace")
        raise ValidationError(f"could not read committed support tree: {detail}") from exc
    return result.stdout


def safe_support_path(path: str) -> bool:
    if not SAFE_PATH.fullmatch(path) or path.startswith("/"):
        return False
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    return path == "README.md" or parts[0] in SUPPORT_ROOTS[1:]


def committed_entries(repo: Path, commit: str) -> tuple[str, list[Entry]]:
    resolved = run_git(repo, ["rev-parse", "--verify", f"{commit}^{{commit}}"])
    try:
        resolved_text = resolved.decode("ascii").strip().lower()
    except UnicodeDecodeError as exc:
        raise ValidationError("support commit did not resolve as ASCII") from exc
    require(bool(OID.fullmatch(resolved_text)), "support commit is not an exact object ID")
    require(resolved_text == commit.lower(), "support commit did not resolve exactly")

    listing = run_git(
        repo,
        ["ls-tree", "-r", "-z", "--full-tree", resolved_text, "--", *SUPPORT_ROOTS],
    )
    entries: list[Entry] = []
    seen: set[str] = set()
    present_roots: set[str] = set()
    blob_cache: dict[str, bytes] = {}
    total_bytes = 0
    for raw_record in listing.split(b"\0"):
        if not raw_record:
            continue
        try:
            metadata, raw_path = raw_record.split(b"\t", 1)
            mode, object_type, object_id = metadata.decode("ascii").split(" ")
            path = raw_path.decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            raise ValidationError("support Git tree contains an unparseable entry") from exc
        require(
            mode in ("100644", "100755") and object_type == "blob",
            f"support Git tree contains a symlink, submodule, or unsupported mode: {path}",
        )
        require(safe_support_path(path), f"support Git tree contains an unsafe path: {path}")
        require(path not in seen, f"support Git tree repeats a path: {path}")
        seen.add(path)
        present_roots.add(path.split("/", 1)[0])
        blob = blob_cache.get(object_id)
        if blob is None:
            blob = run_git(repo, ["cat-file", "blob", object_id])
            blob_cache[object_id] = blob
        total_bytes += len(blob)
        require(total_bytes <= MAX_TOTAL_BYTES, "support Git tree exceeds the size limit")
        entries.append(
            Entry(mode, hashlib.sha256(blob).hexdigest(), len(blob), path)
        )
        require(len(entries) <= MAX_FILES, "support Git tree contains too many files")
    require(entries, "support Git tree contains no files")
    require(
        present_roots == set(SUPPORT_ROOTS),
        "support Git tree is missing one or more required roots",
    )
    entries.sort(key=lambda item: item.path.encode("utf-8"))
    return resolved_text, entries


def manifest_bytes(commit: str, entries: list[Entry]) -> bytes:
    lines = [
        "SP11 support tree manifest v1\n",
        f"Commit: {commit}\n",
        f"File count: {len(entries)}\n",
    ]
    lines.extend(
        f"{entry.mode} {entry.sha256} {entry.size} {entry.path}\n"
        for entry in entries
    )
    return "".join(lines).encode("utf-8")


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except OSError as exc:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise ValidationError(f"could not write support manifest: {exc}") from exc


def expected_actual_entries(entries: list[Entry]) -> dict[str, tuple[str, str, int, str]]:
    expected: dict[str, tuple[str, str, int, str]] = {}
    directories: set[str] = set()
    for entry in entries:
        parts = entry.path.split("/")
        for index in range(1, len(parts)):
            directories.add("/".join(parts[:index]))
        expected[entry.path] = ("f", entry.mode, entry.size, entry.sha256)
    for directory in directories:
        require(directory not in expected, f"support path is both a file and directory: {directory}")
        expected[directory] = ("d", "040755", 0, "-")
    return expected


def read_actual_identities(path: Path) -> dict[str, tuple[str, str, int, str]]:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise ValidationError(f"could not read extracted support identities: {exc}") from exc
    require(data and len(data) <= 16 * 1024 * 1024, "support identity list has an invalid size")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError("support identity list is not valid UTF-8") from exc
    require("\r" not in text and "\x00" not in text, "support identity list has unsafe controls")
    actual: dict[str, tuple[str, str, int, str]] = {}
    for line in text.splitlines():
        fields = line.split(" ")
        require(len(fields) == 5, "support identity list contains an invalid record")
        kind, mode, size_text, digest, entry_path = fields
        require(kind in ("d", "f"), "support identity list contains an invalid entry type")
        require(safe_support_path(entry_path), f"support identity list has an unsafe path: {entry_path}")
        require(entry_path != MANIFEST_NAME, "support manifest must be validated separately")
        require(entry_path not in actual, f"support identity list repeats a path: {entry_path}")
        require(size_text.isascii() and size_text.isdigit(), "support identity list has an invalid size")
        size = int(size_text)
        if kind == "d":
            require(mode == "040755" and size == 0 and digest == "-", "support directory metadata is invalid")
        else:
            require(
                mode in ("100644", "100755") and bool(SHA256.fullmatch(digest)),
                "support file metadata is invalid",
            )
        actual[entry_path] = (kind, mode, size, digest)
        require(len(actual) <= MAX_FILES * 2, "support identity list contains too many entries")
    return actual


def actual_identity_bytes(entries: list[Entry]) -> bytes:
    expected = expected_actual_entries(entries)
    lines = [
        f"{kind} {mode} {size} {digest} {path}\n"
        for path, (kind, mode, size, digest) in sorted(
            expected.items(), key=lambda item: item[0].encode("utf-8")
        )
    ]
    return "".join(lines).encode("utf-8")


def directory_identities(
    root: Path,
    expected_entries: list[Entry],
    normalize_modes: bool = False,
) -> dict[str, tuple[str, str, int, str]]:
    try:
        root_metadata = root.lstat()
    except OSError as exc:
        raise ValidationError(f"could not inspect staged support directory: {exc}") from exc
    require(stat.S_ISDIR(root_metadata.st_mode), "staged support root is not a directory")
    root_permissions = stat.S_IMODE(root_metadata.st_mode)
    if normalize_modes and root_permissions != 0o755:
        os.chmod(root, 0o755, follow_symlinks=False)
        root_permissions = 0o755
    require(root_permissions == 0o755, "staged support root must have mode 0755")
    actual: dict[str, tuple[str, str, int, str]] = {}
    seen_inodes: set[tuple[int, int]] = set()
    expected_paths = set(expected_actual_entries(expected_entries))
    expected_modes = {entry.path: int(entry.mode[-3:], 8) for entry in expected_entries}
    expected_modes[MANIFEST_NAME] = 0o644

    def visit(directory: Path, prefix: str) -> None:
        try:
            children = sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name))
        except OSError as exc:
            raise ValidationError(f"could not enumerate staged support tree: {exc}") from exc
        for child in children:
            path = f"{prefix}/{child.name}" if prefix else child.name
            require(safe_support_path(path) or path == MANIFEST_NAME, f"staged support tree has an unsafe path: {path}")
            try:
                metadata = child.stat(follow_symlinks=False)
            except OSError as exc:
                raise ValidationError(f"could not inspect staged support path {path}: {exc}") from exc
            inode_key = (metadata.st_dev, metadata.st_ino)
            require(inode_key not in seen_inodes, f"staged support tree reuses an inode: {path}")
            seen_inodes.add(inode_key)
            permissions = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISDIR(metadata.st_mode):
                require(path in expected_paths, f"staged support tree contains an unexpected path: {path}")
                if normalize_modes and permissions != 0o755:
                    os.chmod(child.path, 0o755, follow_symlinks=False)
                    permissions = 0o755
                require(permissions == 0o755, f"staged support directory has the wrong mode: {path}")
                actual[path] = ("d", "040755", 0, "-")
                visit(Path(child.path), path)
            elif stat.S_ISREG(metadata.st_mode):
                require(path in expected_modes, f"staged support tree contains an unexpected path: {path}")
                if normalize_modes and permissions != expected_modes[path]:
                    os.chmod(child.path, expected_modes[path], follow_symlinks=False)
                    permissions = expected_modes[path]
                require(permissions in (0o644, 0o755), f"staged support file has the wrong mode: {path}")
                if path == MANIFEST_NAME:
                    require(permissions == 0o644, "staged support manifest must have mode 0644")
                    continue
                try:
                    data = Path(child.path).read_bytes()
                except OSError as exc:
                    raise ValidationError(f"could not read staged support file {path}: {exc}") from exc
                actual[path] = (
                    "f",
                    "100755" if permissions == 0o755 else "100644",
                    len(data),
                    hashlib.sha256(data).hexdigest(),
                )
            else:
                raise ValidationError(f"staged support tree has a symlink or special entry: {path}")
            require(len(actual) <= MAX_FILES * 2, "staged support tree contains too many entries")

    visit(root, "")
    return actual


def compare_identities(
    expected: dict[str, tuple[str, str, int, str]],
    actual: dict[str, tuple[str, str, int, str]],
) -> None:
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    if missing:
        raise ValidationError(f"embedded support tree is missing: {missing[0]}")
    if extra:
        raise ValidationError(
            f"embedded support tree contains an unexpected path: {extra[0]}"
        )
    for path in sorted(expected):
        require(actual[path] == expected[path], f"embedded support identity differs: {path}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-dir", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--output-identities", type=Path)
    parser.add_argument("--verify-manifest", type=Path)
    parser.add_argument("--actual-identities", type=Path)
    parser.add_argument("--verify-directory", type=Path)
    parser.add_argument("--normalize-directory", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    requested_commit = args.commit.lower()
    require(bool(OID.fullmatch(requested_commit)), "support commit must be 40 or 64 lowercase hex")
    commit, entries = committed_entries(args.repo_dir.resolve(), requested_commit)
    expected_manifest = manifest_bytes(commit, entries)
    if args.output is not None:
        require(
            args.verify_manifest is None
            and args.actual_identities is None
            and args.verify_directory is None
            and args.normalize_directory is None,
            "--output cannot be combined with verification inputs",
        )
        write_atomic(args.output, expected_manifest)
        if args.output_identities is not None:
            write_atomic(args.output_identities, actual_identity_bytes(entries))
        print(f"Wrote {len(entries)} committed support identities.")
        return 0
    require(args.output_identities is None, "--output-identities requires --output")
    require(
        args.verify_directory is None or args.normalize_directory is None,
        "--verify-directory and --normalize-directory cannot be combined",
    )
    directory = args.verify_directory or args.normalize_directory
    if directory is not None:
        require(
            args.verify_manifest is None and args.actual_identities is None,
            "--verify-directory cannot be combined with extracted-image inputs",
        )
        embedded_path = directory / MANIFEST_NAME
        try:
            embedded_manifest = embedded_path.read_bytes()
        except OSError as exc:
            raise ValidationError(f"could not read staged support manifest: {exc}") from exc
        require(
            embedded_manifest == expected_manifest,
            "staged support manifest does not exactly match the committed support tree",
        )
        compare_identities(
            expected_actual_entries(entries),
            directory_identities(
                directory,
                entries,
                normalize_modes=args.normalize_directory is not None,
            ),
        )
        action = "Normalized and validated" if args.normalize_directory is not None else "Validated"
        print(f"{action} staged support tree with {len(entries)} committed files.")
        return 0
    require(
        args.verify_manifest is not None and args.actual_identities is not None,
        "verification requires --verify-manifest and --actual-identities",
    )
    try:
        embedded_manifest = args.verify_manifest.read_bytes()
    except OSError as exc:
        raise ValidationError(f"could not read embedded support manifest: {exc}") from exc
    require(
        embedded_manifest == expected_manifest,
        "embedded support manifest does not exactly match the committed support tree",
    )
    expected = expected_actual_entries(entries)
    actual = read_actual_identities(args.actual_identities)
    compare_identities(expected, actual)
    print(f"Validated {len(entries)} committed support files and their directories.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
