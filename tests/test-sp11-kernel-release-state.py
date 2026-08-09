#!/usr/bin/env python3
"""Focused hostile tests for retained kernel release-state sealing/import."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Iterable, List, Tuple


REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "scripts/sp11-kernel-release-state.py"
EMITTER = REPO / "scripts/emit-sp11-kernel-release-state.sh"
SUPPORT_HEAD = "1" * 40
SOURCE_HEAD = "4" * 40
BASELINE_SHA256 = "2" * 64
RETAINED_VOLUME = "sp11-release-state-" + "3" * 32
CONTAINER_PLATFORM = "linux/arm64"
GIT_OBJECT_FORMAT = "sha1"
BUILD_INPUTS_HELPER_SIZE = 12345
BUILD_INPUTS_HELPER_SHA256 = "8" * 64
BUILD_INPUTS_HELPER_OBJECT_ID = "8" * 40
MANIFEST_VALIDATOR_SIZE = 23456
MANIFEST_VALIDATOR_SHA256 = "9" * 64
MANIFEST_VALIDATOR_OBJECT_ID = "9" * 40
VALIDATOR_ARGV = (
    "/usr/bin/python3",
    "-I",
    "/repo/scripts/sp11-kernel-build-inputs.py",
    "validate",
)
CONTROL_NAMES = (
    "docker-build-args.txt",
    "docker-build-inside.sh",
    "sp11-oci-index.json",
)
CREATED: List[Path] = []
IMPORT_SUCCESS = (
    b"Imported verified retained kernel release evidence and final assets.\n"
    + ("Retained Docker release-state volume: %s\n" % RETAINED_VOLUME).encode("ascii")
    + b"Retained evidence tar: sp11-kernel-retained-evidence.tar\n"
    b"Publication authorized: false\n"
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


VALIDATOR_ARGV_SHA256 = sha256(
    b"".join(value.encode("ascii") + b"\0" for value in VALIDATOR_ARGV)
)


def schema(fields: Iterable[Tuple[str, object]]) -> bytes:
    return ("\n".join("%s: %s" % (key, value) for key, value in fields) + "\n").encode("ascii")


def write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def replace_schema_fields(path: Path, replacements: Dict[str, str]) -> None:
    lines = path.read_text(encoding="ascii").splitlines()
    observed: set[str] = set()
    rendered: List[str] = []
    for line in lines:
        key, _value = line.split(": ", 1)
        if key in replacements:
            rendered.append(key + ": " + replacements[key])
            observed.add(key)
        else:
            rendered.append(line)
    assert observed == set(replacements)
    path.write_text("\n".join(rendered) + "\n", encoding="ascii")


def insert_schema_fields_before(
    path: Path,
    before_key: str,
    fields: Iterable[Tuple[str, object]],
) -> None:
    lines = path.read_text(encoding="ascii").splitlines()
    matches = [index for index, line in enumerate(lines) if line.startswith(before_key + ": ")]
    assert len(matches) == 1
    position = matches[0]
    inserted = ["%s: %s" % (key, value) for key, value in fields]
    lines[position:position] = inserted
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def file_row(fields: List[Tuple[str, object]], prefix: str, index: int, values: Iterable[Tuple[str, object]]) -> None:
    for key, value in values:
        fields.append(("%s %d %s" % (prefix, index, key), value))


def write_preseal_attestation(work: Path, digests: Dict[str, str]) -> None:
    rows: List[Tuple[str, str, str, int, str]] = []
    managed_roots = ("apt-archives", "apt-indexes", "apt-lists", "artifacts")
    for root_name in managed_roots:
        root = work / root_name
        for current, directories, files in os.walk(root):
            directories.sort()
            files.sort()
            current_path = Path(current)
            relative = current_path.relative_to(work).as_posix()
            metadata = current_path.lstat()
            rows.append(
                (
                    relative,
                    "directory",
                    "%04o" % stat.S_IMODE(metadata.st_mode),
                    0,
                    "-",
                )
            )
            for name in files:
                path = current_path / name
                payload = path.read_bytes()
                metadata = path.lstat()
                rows.append(
                    (
                        path.relative_to(work).as_posix(),
                        "regular",
                        "%04o" % stat.S_IMODE(metadata.st_mode),
                        len(payload),
                        sha256(payload),
                    )
                )
    for name in (
        "sp11-apt-bootstrap-state.txt",
        "sp11-apt-installed-post.txt",
        "sp11-apt-installed-pre.txt",
        *CONTROL_NAMES,
    ):
        path = work / name
        payload = path.read_bytes()
        metadata = path.lstat()
        rows.append(
            (
                name,
                "regular",
                "%04o" % stat.S_IMODE(metadata.st_mode),
                len(payload),
                sha256(payload),
            )
        )
    rows.sort(key=lambda row: row[0])
    assert len(rows) == len({row[0] for row in rows})
    fields: List[Tuple[str, object]] = [
        ("Kernel pre-seal validation schema", "sp11-kernel-preseal-validation-v1"),
        ("Validation mode", "validate"),
        ("Python isolated mode", "true"),
        ("Validator argv schema", "sp11-kernel-build-inputs-validate-argv-v1"),
        ("Git object format", GIT_OBJECT_FORMAT),
        ("Validator argv count", len(VALIDATOR_ARGV)),
    ]
    for index, value in enumerate(VALIDATOR_ARGV, 1):
        fields.append(("Validator argv %d" % index, value))
    fields.extend(
        (
            ("Support HEAD", SUPPORT_HEAD),
            ("Kernel baseline SHA256", BASELINE_SHA256),
            ("Container image", digests["container-image"]),
            ("Container platform", CONTAINER_PLATFORM),
            ("Build-inputs helper path", "scripts/sp11-kernel-build-inputs.py"),
            ("Build-inputs helper Git mode", "100755"),
            ("Build-inputs helper runtime mode", "0755"),
            ("Build-inputs helper size", BUILD_INPUTS_HELPER_SIZE),
            ("Build-inputs helper SHA256", BUILD_INPUTS_HELPER_SHA256),
            ("Build-inputs helper Git object ID", BUILD_INPUTS_HELPER_OBJECT_ID),
            ("Build-inputs helper object format", GIT_OBJECT_FORMAT),
            ("Manifest validator path", "scripts/validate-sp11-image-release-manifests.py"),
            ("Manifest validator Git mode", "100644"),
            ("Manifest validator runtime mode", "0644"),
            ("Manifest validator size", MANIFEST_VALIDATOR_SIZE),
            ("Manifest validator SHA256", MANIFEST_VALIDATOR_SHA256),
            ("Manifest validator Git object ID", MANIFEST_VALIDATOR_OBJECT_ID),
            ("Manifest validator object format", GIT_OBJECT_FORMAT),
            ("Validated input count", len(rows)),
        )
    )
    for index, (path, kind, mode, size, digest) in enumerate(rows, 1):
        file_row(
            fields,
            "Validated input",
            index,
            (
                ("path", path),
                ("type", kind),
                ("mode", mode),
                ("size", size),
                ("SHA256", digest),
            ),
        )
    fields.append(("Validation complete", "true"))
    write(work / "sp11-kernel-preseal-validation.txt", schema(fields))


def build_state(parent: Path, extra_manifest_fields: int = 0) -> Tuple[Path, Dict[str, str]]:
    work = parent / "volume"
    for name in ("apt-archives", "apt-indexes", "apt-lists", "artifacts"):
        (work / name).mkdir(parents=True)
    controls = {
        "docker-build-args.txt": b"--release-build\n",
        "docker-build-inside.sh": b"#!/bin/bash\nexit 0\n",
        "sp11-oci-index.json": b'{"schemaVersion":2}\n',
    }
    for name, data in controls.items():
        write(work / name, data)
    digests = {name: sha256(data) for name, data in controls.items()}
    digests["container-image"] = (
        "fixture-image@sha256:" + digests["sp11-oci-index.json"]
    )

    inventory = b"fixture:arm64=1\n"
    write(work / "sp11-apt-installed-pre.txt", inventory)
    write(work / "sp11-apt-installed-post.txt", inventory)
    write(work / "sp11-apt-bootstrap-state.txt", b"APT bootstrap state schema: fixture\n")

    kernel_debs = (
        ("common-headers", "linux-qcom-x1e-headers-7.2.0-1_7.2.0-1_all.deb", "linux-qcom-x1e-headers-7.2.0-1", "all", b"common headers\n"),
        ("headers", "linux-headers-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb", "linux-headers-7.2.0-1-qcom-x1e", "arm64", b"architecture headers\n"),
        ("image", "linux-image-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb", "linux-image-7.2.0-1-qcom-x1e", "arm64", b"kernel image\n"),
        ("modules", "linux-modules-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb", "linux-modules-7.2.0-1-qcom-x1e", "arm64", b"kernel modules\n"),
    )
    local_name = "fixture-build-deps_1_arm64.deb"
    local_bytes = b"local-build-deps\n"
    downloaded_name = "python3.14_3.14_arm64.deb"
    downloaded_bytes = b"downloaded-deb\n"
    for _role, kernel_name, _package, _architecture, kernel_bytes in kernel_debs:
        write(work / "artifacts" / kernel_name, kernel_bytes)
    write(work / "artifacts" / local_name, local_bytes)
    write(work / "apt-archives" / downloaded_name, downloaded_bytes)
    write(work / "apt-archives" / "lock", b"")

    suites = ("resolute", "resolute-updates", "resolute-backports", "resolute-security")
    snapshot_id = "20260807T000000Z"
    inrelease: List[Tuple[str, str, bytes]] = []
    for suite in suites:
        name = "snapshot.ubuntu.com_ubuntu_%s_dists_%s_InRelease" % (snapshot_id, suite)
        data = (suite + " signed metadata\n").encode("ascii")
        write(work / "apt-lists" / name, data)
        inrelease.append((suite, name, data))

    indexes: List[Tuple[str, str, bytes]] = []
    for index in range(1, 33):
        suite = suites[(index - 1) // 8]
        retained = "%s/component%d/index%02d.gz" % (suite, (index - 1) % 4, index)
        data = ("index-%02d\n" % index).encode("ascii")
        write(work / "apt-indexes" / retained, data)
        indexes.append((suite, retained, data))

    list_targets: List[Tuple[str, bytes]] = [(name, data) for _suite, name, data in inrelease]
    list_targets.append(("lock", b""))
    write(work / "apt-lists" / "lock", b"")
    for index in range(1, 27):
        name = "snapshot-list-target-%02d.lz4" % index
        data = ("list-%02d\n" % index).encode("ascii")
        write(work / "apt-lists" / name, data)
        list_targets.append((name, data))
    assert len(list_targets) == 31
    list_targets.sort(key=lambda row: row[0])

    manifest_fields: List[Tuple[str, object]] = [
        ("Provenance schema", "sp11-kernel-build-v2"),
        ("Release build", "true"),
        ("Support start HEAD", SUPPORT_HEAD),
        ("Support start dirty", "false"),
        ("Support end HEAD", SUPPORT_HEAD),
        ("Support end dirty", "false"),
        ("Source mode", "git"),
        ("Source URL", "https://github.com/example/linux.git"),
        ("Source ref", "fixture/ref"),
        ("Expected source commit", SOURCE_HEAD),
        ("Source HEAD", SOURCE_HEAD),
        ("Container image", digests["container-image"]),
        ("Container digest", "sha256:" + digests["sp11-oci-index.json"]),
        ("Container platform", CONTAINER_PLATFORM),
        ("Build target", "binary-indep binary-qcom-x1e"),
        ("Jobs", 1),
        ("Rules runner", "direct-root"),
        ("Patch count", 1),
        ("Patch 1 path", "patches/fixture/0001-fixture.patch"),
        ("Patch 1 SHA256", "6" * 64),
        ("Patch 1 disposition", "applied"),
        ("Patched diff format", "git-diff-full-index-binary-v1"),
        ("Patched diff Git version", "git version fixture"),
        ("Patched diff SHA256", "7" * 64),
        ("Patched tree ID", SOURCE_HEAD),
        ("Required output roles", "kernel-config module-symvers system-map kernel-efi-stubble denali-oled-dtb denali-oled-el2-dtb module-signing-certificate"),
        ("Optional output roles", "none"),
        ("Output count", 7),
    ]
    for index, role in enumerate(
        (
            "kernel-config", "module-symvers", "system-map",
            "kernel-efi-stubble", "denali-oled-dtb",
            "denali-oled-el2-dtb", "module-signing-certificate",
        ),
        1,
    ):
        file_row(
            manifest_fields,
            "Output",
            index,
            (
                ("role", role),
                ("required", "true"),
                ("path", "debian/build/fixture/output-%d" % index),
                ("size", index),
                ("SHA256", ("%x" % index) * 64),
            ),
        )
    manifest_fields.extend(
        (
            ("Signing certificate SHA256", "7" * 64),
            ("Signing certificate fingerprint", ":".join(["AA"] * 32)),
            ("Signing certificate serial", "01"),
            ("Required Deb roles", "common-headers headers image modules"),
            ("Optional Deb roles", "modules-extra"),
            ("Deb count", len(kernel_debs)),
        )
    )
    for index, (role, name, package, architecture, data) in enumerate(kernel_debs, 1):
        file_row(
            manifest_fields,
            "Deb",
            index,
            (
                ("role", role),
                ("required", "true"),
                ("path", name),
                ("package", package),
                ("version", "7.2.0-1"),
                ("architecture", architecture),
                ("size", len(data)),
                ("SHA256", sha256(data)),
            ),
        )
    manifest_fields.append(("Build completed", "true"))
    manifest_fields.extend(
        ("Fixture extra field %d" % index, "x")
        for index in range(1, extra_manifest_fields + 1)
    )
    manifest = schema(manifest_fields)
    write(work / "artifacts/sp11-kernel-build-manifest.txt", manifest)
    write(
        work / "artifacts/sp11-kernel-debs.txt",
        "".join(name + "\n" for _role, name, _package, _architecture, _data in kernel_debs).encode("ascii"),
    )

    sidecar_fields: List[Tuple[str, object]] = [
        ("APT provenance schema", "sp11-kernel-apt-provenance-v1"),
        ("Snapshot ID", snapshot_id),
        ("Pre-install package count", 1),
        ("Pre-install package aggregate SHA256", sha256(inventory)),
        ("Pre-install package 1", "fixture:arm64=1"),
        ("Post-install package count", 1),
        ("Post-install package aggregate SHA256", sha256(inventory)),
        ("Post-install package 1", "fixture:arm64=1"),
        ("InRelease count", 4),
    ]
    for index, (suite, _name, data) in enumerate(inrelease, 1):
        file_row(sidecar_fields, "InRelease", index, (("suite", suite), ("size", len(data)), ("SHA256", sha256(data))))
    sidecar_fields.append(("Index count", 32))
    for index, (suite, retained, data) in enumerate(indexes, 1):
        file_row(
            sidecar_fields,
            "Index",
            index,
            (
                ("suite", suite),
                ("retained path", retained),
                ("size", len(data)),
                ("SHA256", sha256(data)),
            ),
        )
    sidecar_fields.append(("APT list target count", 31))
    for index, (name, data) in enumerate(list_targets, 1):
        file_row(sidecar_fields, "APT list target", index, (("path", name), ("size", len(data)), ("SHA256", sha256(data))))
    sidecar_fields.append(("Downloaded Deb count", 1))
    file_row(sidecar_fields, "Downloaded Deb", 1, (("path", downloaded_name), ("size", len(downloaded_bytes)), ("SHA256", sha256(downloaded_bytes))))
    sidecar_fields.append(("Local build-deps count", 1))
    file_row(sidecar_fields, "Local build-deps", 1, (("path", local_name), ("size", len(local_bytes)), ("SHA256", sha256(local_bytes))))
    sidecar_fields.append(("APT provenance complete", "true"))
    sidecar = schema(sidecar_fields)
    write(work / "artifacts/sp11-kernel-apt-provenance.txt", sidecar)

    envelope_fields: List[Tuple[str, object]] = [
        ("Build inputs schema", "sp11-kernel-build-inputs-v1"),
        ("Release build", "true"),
        ("Support HEAD", SUPPORT_HEAD),
        ("Input count", 5),
    ]
    inputs = (
        ("docker-build-arguments", "docker-build-args.txt", controls["docker-build-args.txt"]),
        ("docker-entrypoint", "docker-build-inside.sh", controls["docker-build-inside.sh"]),
        ("oci-index", "sp11-oci-index.json", controls["sp11-oci-index.json"]),
        ("kernel-build-manifest-v2", "artifacts/sp11-kernel-build-manifest.txt", manifest),
        ("apt-provenance-v1", "artifacts/sp11-kernel-apt-provenance.txt", sidecar),
    )
    for index, (role, path, data) in enumerate(inputs, 1):
        file_row(envelope_fields, "Input", index, (("role", role), ("path", path), ("size", len(data)), ("SHA256", sha256(data))))
    envelope_fields.append(("Build inputs complete", "true"))
    write(work / "artifacts/sp11-kernel-build-inputs.txt", schema(envelope_fields))
    write_preseal_attestation(work, digests)
    return work, digests


def common_args(work: Path, digests: Dict[str, str]) -> List[str]:
    return [
        "--support-head", SUPPORT_HEAD,
        "--baseline-sha256", BASELINE_SHA256,
        "--build-args-sha256", digests["docker-build-args.txt"],
        "--entrypoint-sha256", digests["docker-build-inside.sh"],
        "--oci-index-sha256", digests["sp11-oci-index.json"],
        "--container-image", digests["container-image"],
        "--container-platform", CONTAINER_PLATFORM,
        "--git-object-format", GIT_OBJECT_FORMAT,
        "--validator-argv-sha256", VALIDATOR_ARGV_SHA256,
        "--build-inputs-helper-size", str(BUILD_INPUTS_HELPER_SIZE),
        "--build-inputs-helper-sha256", BUILD_INPUTS_HELPER_SHA256,
        "--build-inputs-helper-object-id", BUILD_INPUTS_HELPER_OBJECT_ID,
        "--manifest-validator-size", str(MANIFEST_VALIDATOR_SIZE),
        "--manifest-validator-sha256", MANIFEST_VALIDATOR_SHA256,
        "--manifest-validator-object-id", MANIFEST_VALIDATOR_OBJECT_ID,
    ]


def run(
    command: List[str],
    *,
    pass_fds: Tuple[int, ...] = (),
    expect: bool = True,
    environment: Dict[str, str] | None = None,
    inherited_sigchld_ignored: bool = False,
) -> subprocess.CompletedProcess[bytes]:
    def ignore_sigchld() -> None:
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)

    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        pass_fds=pass_fds,
        check=False,
        env=environment,
        preexec_fn=ignore_sigchld if inherited_sigchld_ignored else None,
    )
    if (result.returncode == 0) != expect:
        raise AssertionError("unexpected command status %d\nstdout=%r\nstderr=%r" % (result.returncode, result.stdout, result.stderr))
    return result


def directory_identity_args(path: Path) -> List[str]:
    metadata = path.lstat()
    assert stat.S_ISDIR(metadata.st_mode) and not path.is_symlink()
    return [
        str(metadata.st_dev),
        str(metadata.st_ino),
        str(stat.S_IMODE(metadata.st_mode)),
        str(metadata.st_uid),
        str(metadata.st_gid),
    ]


def control_identity_args(path: Path) -> List[str]:
    metadata = path.lstat()
    assert stat.S_ISREG(metadata.st_mode) and not path.is_symlink()
    return [
        str(metadata.st_dev),
        str(metadata.st_ino),
        str(stat.S_IMODE(metadata.st_mode)),
        str(metadata.st_size),
        str(metadata.st_mtime_ns),
        str(metadata.st_ctime_ns),
        str(metadata.st_nlink),
        str(metadata.st_uid),
        str(metadata.st_gid),
    ]


def prepare_import_root(destination: Path, state: Path) -> Path:
    artifacts = destination / "artifacts"
    artifacts.mkdir(parents=True)
    destination.chmod(0o700)
    artifacts.chmod(0o700)
    for name in CONTROL_NAMES:
        target = destination / name
        target.write_bytes((state / name).read_bytes())
        target.chmod(0o600)
    return artifacts


def verify_evidence(
    work: Path,
    state: Path,
    digests: Dict[str, str],
    *,
    expect: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    return run(
        [
            sys.executable,
            "-I",
            str(HELPER),
            "verify-evidence-tar",
            "--work-root",
            str(work),
            *common_args(state, digests),
        ],
        expect=expect,
    )


def create_mock_docker(parent: Path) -> Tuple[Path, Path]:
    state = parent / "mock-docker-state"
    state.mkdir()
    executable = parent / "mock-docker"
    executable.write_text(
        "#!/bin/sh\nexec %s -I %s mock-docker %s \"$@\"\n"
        % tuple(
            shlex.quote(str(value))
            for value in (Path(sys.executable), Path(__file__).resolve(), state)
        ),
        encoding="ascii",
    )
    executable.chmod(0o700)
    return executable, state


def create_mock_tar(parent: Path) -> Path:
    executable = parent / "mock-gnu-tar"
    executable.write_text(
        "#!/bin/sh\nexec %s -I %s mock-tar \"$@\"\n"
        % tuple(
            shlex.quote(str(value))
            for value in (Path(sys.executable), Path(__file__).resolve())
        ),
        encoding="ascii",
    )
    executable.chmod(0o700)
    return executable


def mock_docker(state: Path, arguments: List[str]) -> int:
    if not arguments:
        return 2
    if arguments[0] == "create":
        values: Dict[str, str] = {}
        index = 1
        while index < len(arguments):
            argument = arguments[index]
            if argument in (
                "--name",
                "--label",
                "--mount",
                "--fixture-stage",
                "--fixture-fault",
                "--fixture-marker",
            ):
                if index + 1 >= len(arguments):
                    return 2
                values[argument] = arguments[index + 1]
                index += 2
            else:
                index += 1
        values.setdefault("--fixture-stage", os.environ.get("SP11_RELEASE_STATE_MOCK_STAGE", ""))
        values.setdefault("--fixture-fault", os.environ.get("SP11_RELEASE_STATE_MOCK_FAULT", ""))
        values.setdefault("--fixture-marker", os.environ.get("SP11_RELEASE_STATE_MOCK_MARKER", "-"))
        if not all(
            values.get(key)
            for key in ("--name", "--label", "--fixture-stage", "--fixture-fault")
        ):
            return 2
        identifier = sha256((values["--name"] + "\n" + values["--label"]).encode("ascii"))
        record = schema(
            (
                ("stage", values["--fixture-stage"]),
                ("fault", values["--fixture-fault"]),
                ("marker", values.get("--fixture-marker", "-")),
                ("mount", values.get("--mount", "-")),
                (
                    "companion",
                    os.environ.get("SP11_RELEASE_STATE_MOCK_COMPANION", "-"),
                ),
            )
        )
        (state / identifier).write_bytes(record)
        os.write(1, (identifier + "\n").encode("ascii"))
        return 0
    if len(arguments) == 3 and arguments[:2] == ["start", "--attach"]:
        identifier = arguments[2]
        record = parse_test_fields((state / identifier).read_bytes())
        marker = None if record["marker"] == "-" else Path(record["marker"])
        if record["fault"] == "build-success":
            os.write(1, b"release build stdout\n")
            os.write(2, b"release build stderr\n")
            return 0
        if record["fault"] == "build-failure":
            os.write(2, b"release build failed\n")
            return 7
        if record["fault"] == "shell-emitter":
            if marker is None:
                return 2
            environment = dict(os.environ)
            environment["SP11_RELEASE_STATE_EMITTER_FIXTURE"] = "true"
            os.execve(
                str(EMITTER),
                [
                    str(EMITTER),
                    "--fixture-stage", record["stage"],
                    "--fixture-tar", str(marker),
                ],
                environment,
            )
        if record["fault"] == "companion-mutate":
            companion = Path(record["companion"])
            original = companion.read_bytes()
            companion.write_bytes(b"X" + original[1:])
        return emit_mode(Path(record["stage"]), record["fault"], marker)
    if len(arguments) == 3 and arguments[:2] == ["rm", "-f"]:
        identifier = arguments[2]
        record = state / identifier
        if not record.is_file():
            return 1
        record.unlink()
        os.write(1, (identifier + "\n").encode("ascii"))
        return 0
    if (
        len(arguments) == 6
        and arguments[:5] == [
            "inspect", "--type", "container", "--format",
            "{{.State.Status}} {{.State.ExitCode}}",
        ]
    ):
        if not (state / arguments[5]).is_file():
            return 1
        os.write(1, b"exited 0\n")
        return 0
    if (
        len(arguments) == 6
        and arguments[:5] == [
            "inspect", "--type", "container", "--format", "{{json .Mounts}}",
        ]
    ):
        record_path = state / arguments[5]
        if not record_path.is_file():
            return 1
        record = parse_test_fields(record_path.read_bytes())
        mount_fields = dict(
            field.split("=", 1)
            for field in record["mount"].split(",")
            if "=" in field
        )
        volume_name = mount_fields.get("source", "")
        if record["fault"] == "mount-mismatch":
            volume_name = "sp11-release-state-" + "f" * 32
        repo_source = (
            "/wrong-fixture-support"
            if record["fault"] == "repo-source-mismatch"
            else "/fixture-support"
        )
        payload = [
            {
                "Type": "volume",
                "Name": volume_name,
                "Destination": "/work",
                "RW": False,
            },
            {
                "Type": "bind",
                "Source": repo_source,
                "Destination": "/repo",
                "RW": False,
            },
        ]
        os.write(1, json.dumps(payload, separators=(",", ":")).encode("ascii") + b"\n")
        return 0
    return 2


def mock_tar(arguments: List[str]) -> int:
    if arguments == ["--version"]:
        os.write(1, b"tar (GNU tar) 1.35\n")
        return 0
    if len(arguments) < 2 or arguments[0] != "-C":
        return 2
    stage = Path(arguments[1])
    expected = [
        "-C", str(stage), "--format=ustar", "--blocking-factor=1",
        "--numeric-owner", "--owner=0", "--group=0", "--mode=0644",
        "--mtime=@0", "--no-recursion", "--hard-dereference", "--null",
        "--verbatim-files-from", "-cf", "-", "-T", str(stage / "files.nul"),
    ]
    if arguments != expected:
        os.write(2, ("mock tar argv mismatch: %r\n" % arguments).encode("ascii"))
        return 2
    return emit_mode(stage, "none")


def parse_test_fields(raw: bytes) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for line in raw.decode("ascii").splitlines():
        key, value = line.split(": ", 1)
        result[key] = value
    return result


def mock_create_command(
    docker: Path,
    state: Path,
    fault: str,
    marker: Path | None = None,
    read_only: bool = True,
    platform: str = "linux/arm64",
    image_digest: str = "9" * 64,
) -> List[str]:
    command = [str(docker), "create"]
    if read_only:
        command.extend(
            (
                "--pull=never", "--network", "none", "--read-only",
                "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                "--pids-limit", "64", "--user", "0:0", "--platform", platform,
                "--mount", "type=volume,source=%s,destination=/work,readonly" % RETAINED_VOLUME,
                "-v", "/fixture-support:/repo:ro", "--entrypoint", "/bin/bash",
            )
        )
    else:
        command.extend(("--fixture-stage", str(state / ".sp11-release-export-v1"), "--fixture-fault", fault))
        if marker is not None:
            command.extend(("--fixture-marker", str(marker)))
    command.extend(("fixture-image@sha256:" + image_digest, "/repo/scripts/emit-sp11-kernel-release-state.sh"))
    return command


def test_published_acquisition_scrub(parent: Path) -> None:
    spec = importlib.util.spec_from_file_location("sp11_release_state_fixture", HELPER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    directory = parent / "acquisition"
    directory.mkdir()
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        digest_vector = directory / "digest-vector"
        digest_payload = b"a" * (1024 * 1024) + b"b" * (1024 * 1024) + b"tail"
        digest_vector.write_bytes(digest_payload)
        digest_descriptor = os.open(
            digest_vector,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        try:
            assert module.digest_descriptor(
                digest_descriptor,
                len(digest_payload),
            ) == module.Snapshot(len(digest_payload), sha256(digest_payload))
        finally:
            os.close(digest_descriptor)

        class FailingOwner(list):
            def append(self, output: object) -> None:
                assert isinstance(output, module.PublishedFile)
                assert os.pwrite(output.descriptor, b"candidate bytes", 0) == len(b"candidate bytes")
                os.fsync(output.descriptor)
                raise RuntimeError("fixture owner registration failure")

        try:
            module.acquire_published(FailingOwner(), descriptor, "append-failure")
        except RuntimeError:
            pass
        else:
            raise AssertionError("publication owner-registration fault was accepted")
        assert (directory / "append-failure").is_file()
        assert (directory / "append-failure").stat().st_size == 0

        original_fstat = os.fstat

        def failing_fstat(candidate: int) -> os.stat_result:
            assert os.pwrite(candidate, b"validation bytes", 0) == len(b"validation bytes")
            os.fsync(candidate)
            raise OSError("fixture post-open validation failure")

        module.os.fstat = failing_fstat
        try:
            try:
                module.create_published(descriptor, "validation-failure")
            except OSError:
                pass
            else:
                raise AssertionError("publication post-open validation fault was accepted")
        finally:
            module.os.fstat = original_fstat
        assert (directory / "validation-failure").is_file()
        assert (directory / "validation-failure").stat().st_size == 0

        child_pids: List[int] = []

        class FailingChildOwner(list):
            def append(self, child: object) -> None:
                assert isinstance(child, module.ExporterProcess)
                assert child.pid is not None
                child_pids.append(child.pid)
                raise RuntimeError("fixture child owner registration failure")

        try:
            module.acquire_exporter(
                FailingChildOwner(),
                [sys.executable, "-c", "import time; time.sleep(30)"],
            )
        except RuntimeError:
            pass
        else:
            raise AssertionError("child owner-registration fault was accepted")
        assert len(child_pids) == 1
        try:
            os.kill(child_pids[0], 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("unregistered child survived its transfer failure")

        # Exercise the internal waitpid-to-owner-state boundary directly.  A
        # terminal signal is queued after the exact child has been reaped but
        # before waitpid returns to SpawnedChild.finish().  The signal must be
        # blocked there, and cleanup must observe registered terminal state
        # rather than sending to a reusable PID/process-group identifier.
        waited_status: List[int] = []
        killpg_calls: List[Tuple[int, int]] = []
        child = module.SpawnedChild(
            ["/usr/bin/python3", "-I", "-c", "pass"]
        )
        original_waitpid = module.os.waitpid
        original_killpg = module.os.killpg
        original_handlers = {
            handled: signal.getsignal(handled)
            for handled in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
        }

        def waitpid_with_pending_signal(pid: int, _options: int) -> Tuple[int, int]:
            waited, status = original_waitpid(pid, 0)
            waited_status.append(status)
            current_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            assert signal.SIGTERM in current_mask
            os.kill(os.getpid(), signal.SIGTERM)
            return waited, status

        def forbidden_killpg(pid: int, number: int) -> None:
            killpg_calls.append((pid, number))
            raise AssertionError("reaped release-state child was killed by PID")

        def interrupted(_number: int, _frame: object) -> None:
            raise KeyboardInterrupt

        module.os.waitpid = waitpid_with_pending_signal
        module.os.killpg = forbidden_killpg
        for handled in original_handlers:
            signal.signal(handled, interrupted)
        try:
            try:
                child.finish()
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("pending terminal signal was discarded after waitpid")
            assert len(waited_status) == 1
            assert child.status == waited_status[0]
            child.abort()
            assert killpg_calls == []
        finally:
            module.os.waitpid = original_waitpid
            module.os.killpg = original_killpg
            for handled, original_handler in original_handlers.items():
                signal.signal(handled, original_handler)
            if child.status is None and waited_status:
                child.status = waited_status[0]
            child.close()

        original_sigchld = signal.getsignal(signal.SIGCHLD)
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        try:
            try:
                module.SpawnedChild(
                    ["/usr/bin/python3", "-I", "-c", "pass"]
                )
            except module.ReleaseStateError:
                pass
            else:
                raise AssertionError("non-waitable child disposition was accepted")
        finally:
            signal.signal(signal.SIGCHLD, original_sigchld)

        original_scandir = os.scandir

        class FakeEntry:
            def __init__(self, index: int) -> None:
                self.name = "entry-%05d" % index

        class FakeScandir:
            def __init__(self, count: int) -> None:
                self.count = count

            def __enter__(self) -> "FakeScandir":
                return self

            def __exit__(self, *_arguments: object) -> None:
                return None

            def __iter__(self) -> Iterable[FakeEntry]:
                return iter(FakeEntry(index) for index in range(self.count))

        module.os.scandir = lambda _path: FakeScandir(module.MAX_MEMBERS * 2 + 1)
        try:
            try:
                module.scan_regular_tree(Path("/fixture"), "fixture", module.ScanBudget())
            except module.ReleaseStateError:
                pass
            else:
                raise AssertionError("oversized directory enumeration was accepted")
        finally:
            module.os.scandir = original_scandir

        module.os.scandir = lambda _descriptor: FakeScandir(3)
        try:
            try:
                module.require_exact_directory_names(descriptor, {"expected"}, "fixture output root")
            except module.ReleaseStateError:
                pass
            else:
                raise AssertionError("oversized output membership was accepted")
        finally:
            module.os.scandir = original_scandir
    finally:
        os.close(descriptor)


def octal_field(value: int, width: int) -> bytes:
    encoded = ("%0*o" % (width - 1, value)).encode("ascii") + b"\0"
    assert len(encoded) == width
    return encoded


def tar_header(name: str, size: int, member_type: bytes = b"0") -> bytes:
    block = bytearray(512)
    encoded = name.encode("ascii")
    assert len(encoded) <= 100
    block[0 : len(encoded)] = encoded
    block[100:108] = octal_field(0o644, 8)
    block[108:116] = octal_field(0, 8)
    block[116:124] = octal_field(0, 8)
    block[124:136] = octal_field(size, 12)
    block[136:148] = octal_field(0, 12)
    block[148:156] = b"        "
    block[156:157] = member_type
    block[257:263] = b"ustar\0"
    block[263:265] = b"00"
    block[329:337] = octal_field(0, 8)
    block[337:345] = octal_field(0, 8)
    checksum = sum(block)
    block[148:156] = ("%06o" % checksum).encode("ascii") + b"\0 "
    return bytes(block)


def emit_member(output: bytearray, name: str, data: bytes, member_type: bytes = b"0", declared_size: int = -1) -> None:
    size = len(data) if declared_size < 0 else declared_size
    output.extend(tar_header(name, size, member_type))
    output.extend(data)
    output.extend(b"\0" * ((-len(data)) % 512))


def emit_mode(stage: Path, fault: str, marker: Path | None = None) -> int:
    if fault == "hang":
        assert marker is not None
        marker.write_text(str(os.getpid()), encoding="ascii")
        while True:
            time.sleep(1)
    names = (stage / "files.nul").read_bytes().rstrip(b"\0").split(b"\0")
    archive = bytearray()
    for index, raw_name in enumerate(names):
        name = raw_name.decode("ascii")
        data = (stage / name).read_bytes()
        member_type = b"0"
        emitted_name = name
        declared = -1
        if index == 1 and fault == "link":
            member_type = b"2"
        elif index == 1 and fault == "pax":
            member_type = b"x"
        elif index == 1 and fault == "unknown":
            emitted_name = "objects/99999999"
        elif index == 1 and fault == "oversize":
            declared = 4 * 1024 * 1024 * 1024 + 1
            data = b""
        elif index == 0 and fault == "catalog":
            data = data.replace(b"Catalog complete: true", b"Catalog complete: false")
        emit_member(archive, emitted_name, data, member_type, declared)
        if index == 1 and fault == "duplicate":
            emit_member(archive, emitted_name, data)
    archive.extend(b"\0" * 1024)
    if fault == "trailing":
        archive.extend(b"trailing")
    if fault == "truncated":
        archive = archive[:-700]
    os.write(1, archive)
    if fault == "trailing-hang":
        payload = b"x" * (64 * 1024)
        while True:
            os.write(1, payload)
    return 0


def import_once(
    parent: Path,
    state: Path,
    digests: Dict[str, str],
    docker: Path,
    fault: str = "none",
    marker: Path | None = None,
    fixture_hook: str = "",
    inherited_sigchld_ignored: bool = False,
) -> Tuple[subprocess.CompletedProcess[bytes], Path]:
    destination = parent / ("import-" + fault + "-" + str(time.time_ns()))
    artifacts = prepare_import_root(destination, state)
    if fault == "initial-work-member":
        (destination / ".sp11-unexpected-work-member").write_bytes(b"unexpected\n")
    create_command = mock_create_command(
        docker,
        state,
        fault,
        marker,
        platform="linux/amd64" if fault == "platform-mismatch" else "linux/arm64",
        image_digest=(
            "f" * 64
            if fault == "image-mismatch"
            else digests["sp11-oci-index.json"]
        ),
    )
    if fault == "extra-option":
        create_command.insert(-2, "--privileged")
    elif fault == "shadow-mount":
        create_command[-2:-2] = (
            "--mount",
            "type=volume,source=shadow,destination=/work",
        )
    command = [
        sys.executable, "-I", str(HELPER), "import-tar",
        "--work-root", str(destination),
        "--work-root-identity", *directory_identity_args(destination),
        "--artifacts-root", str(artifacts),
        "--artifacts-root-identity", *directory_identity_args(artifacts),
        "--docker-path", str(docker),
        "--retained-volume-name", RETAINED_VOLUME,
        "--build-args-identity", *control_identity_args(destination / "docker-build-args.txt"),
        "--entrypoint-identity", *control_identity_args(destination / "docker-build-inside.sh"),
        "--oci-index-identity", *control_identity_args(destination / "sp11-oci-index.json"),
        *common_args(state, digests),
    ]
    if fixture_hook:
        command.extend(("--fixture-hook", fixture_hook))
    command.extend(("--", *create_command))
    environment = dict(os.environ)
    environment["SP11_RELEASE_STATE_MOCK_STAGE"] = str(
        state / ".sp11-release-export-v1"
    )
    environment["SP11_RELEASE_STATE_MOCK_FAULT"] = fault
    environment["SP11_RELEASE_STATE_MOCK_MARKER"] = (
        str(marker) if marker is not None else "-"
    )
    environment["SP11_RELEASE_STATE_MOCK_COMPANION"] = str(
        destination / "docker-build-args.txt"
    )
    result = run(
        command,
        expect=(
            fault in ("none", "shell-emitter")
            and fixture_hook in ("", "pending-signal-after-commit")
        ),
        environment=environment,
        inherited_sigchld_ignored=inherited_sigchld_ignored,
    )
    return result, destination


def assert_zero_outputs(destination: Path) -> None:
    evidence = destination / "sp11-kernel-retained-evidence.tar"
    assert evidence.is_file() and not evidence.is_symlink() and evidence.stat().st_size == 0
    for path in (destination / "artifacts").iterdir():
        assert path.is_file() and not path.is_symlink() and path.stat().st_size == 0


def test_semantic_group_refusals(parent: Path) -> None:
    def seal_refusal(
        label: str,
        replacements: Dict[str, str],
        expected_diagnostic: bytes,
        inserted: Iterable[Tuple[str, object]] = (),
    ) -> None:
        case_parent = parent / ("semantic-" + label)
        case_parent.mkdir()
        state, digests = build_state(case_parent)
        sidecar = state / "artifacts/sp11-kernel-apt-provenance.txt"
        replace_schema_fields(sidecar, replacements)
        inserted_rows = tuple(inserted)
        if inserted_rows:
            insert_schema_fields_before(
                sidecar,
                "Local build-deps count",
                inserted_rows,
            )
        result = run(
            [
                sys.executable,
                "-I",
                str(HELPER),
                "seal",
                "--work-root",
                str(state),
                *common_args(state, digests),
            ],
            expect=False,
        )
        assert expected_diagnostic in result.stderr
        assert b"Traceback" not in result.stderr and str(parent).encode() not in result.stderr

    resolute_data = b"resolute signed metadata\n"
    seal_refusal(
        "duplicate-inrelease",
        {
            "InRelease 4 suite": "resolute",
            "InRelease 4 size": str(len(resolute_data)),
            "InRelease 4 SHA256": sha256(resolute_data),
        },
        b"InRelease rows are not unique and ordered",
    )
    first_index = b"index-01\n"
    seal_refusal(
        "duplicate-index",
        {
            "Index 32 suite": "resolute",
            "Index 32 retained path": "resolute/component0/index01.gz",
            "Index 32 size": str(len(first_index)),
            "Index 32 SHA256": sha256(first_index),
        },
        b"index rows are not unique and suite-ordered",
    )
    seal_refusal(
        "duplicate-list",
        {
            "APT list target 31 path": "lock",
            "APT list target 31 size": "0",
            "APT list target 31 SHA256": sha256(b""),
        },
        b"list-target rows are not unique and ordered",
    )
    downloaded_data = b"downloaded-deb\n"
    seal_refusal(
        "duplicate-downloaded",
        {"Downloaded Deb count": "2"},
        b"downloaded-Deb rows are not unique and ordered",
        (
            ("Downloaded Deb 2 path", "python3.14_3.14_arm64.deb"),
            ("Downloaded Deb 2 size", len(downloaded_data)),
            ("Downloaded Deb 2 SHA256", sha256(downloaded_data)),
        ),
    )
    kernel_name = "linux-qcom-x1e-headers-7.2.0-1_7.2.0-1_all.deb"
    kernel_data = b"common headers\n"
    seal_refusal(
        "local-kernel-overlap",
        {
            "Local build-deps 1 path": kernel_name,
            "Local build-deps 1 size": str(len(kernel_data)),
            "Local build-deps 1 SHA256": sha256(kernel_data),
        },
        b"overlaps the kernel release Deb set",
    )


def test_unknown_root_refusals(parent: Path) -> None:
    for label in ("regular", "directory", "symlink", "fifo"):
        case_parent = parent / ("unknown-root-" + label)
        case_parent.mkdir()
        state, digests = build_state(case_parent)
        unexpected = state / ("unexpected-" + label)
        if label == "regular":
            unexpected.write_bytes(b"unknown root payload\n")
        elif label == "directory":
            unexpected.mkdir()
        elif label == "symlink":
            unexpected.symlink_to("artifacts")
        else:
            os.mkfifo(unexpected, 0o600)
        result = run(
            [
                sys.executable,
                "-I",
                str(HELPER),
                "seal",
                "--work-root",
                str(state),
                *common_args(state, digests),
            ],
            expect=False,
        )
        assert b"work root before sealing differs from its exact member set" in result.stderr
        assert b"Traceback" not in result.stderr and str(parent).encode() not in result.stderr
        assert not (state / ".sp11-release-export-v1").exists()


def test_preseal_attestation_refusals(parent: Path) -> None:
    for label in (
        "argv",
        "code-size",
        "duplicate-row",
        "incomplete",
        "post-validation-drift",
        "mode",
        "hardlink",
    ):
        case_parent = parent / ("attestation-" + label)
        case_parent.mkdir()
        state, digests = build_state(case_parent)
        attestation = state / "sp11-kernel-preseal-validation.txt"
        if label == "argv":
            replace_schema_fields(attestation, {"Validator argv 4": "write"})
        elif label == "code-size":
            replace_schema_fields(attestation, {"Build-inputs helper size": "1"})
        elif label == "duplicate-row":
            fields = attestation.read_text(encoding="ascii").splitlines()
            first = next(
                line.split(": ", 1)[1]
                for line in fields
                if line.startswith("Validated input 1 path: ")
            )
            replace_schema_fields(attestation, {"Validated input 2 path": first})
        elif label == "incomplete":
            replace_schema_fields(attestation, {"Validation complete": "false"})
        elif label == "post-validation-drift":
            (state / "sp11-apt-installed-post.txt").write_bytes(b"drifted\n")
        elif label == "mode":
            attestation.chmod(0o600)
        else:
            payload = attestation.read_bytes()
            attestation.unlink()
            victim = case_parent / "attestation-victim"
            victim.write_bytes(payload)
            os.link(victim, attestation)
        refused = run(
            [
                sys.executable,
                "-I",
                str(HELPER),
                "seal",
                "--work-root",
                str(state),
                *common_args(state, digests),
            ],
            expect=False,
        )
        assert b"Traceback" not in refused.stderr
        assert str(parent).encode() not in refused.stderr
        assert not (state / ".sp11-release-export-v1").exists()


def tests() -> None:
    parent = Path(tempfile.mkdtemp(prefix="sp11-release-state-fixture.")).resolve()
    CREATED.append(parent)
    test_published_acquisition_scrub(parent)
    test_semantic_group_refusals(parent)
    test_unknown_root_refusals(parent)
    test_preseal_attestation_refusals(parent)
    state, digests = build_state(parent)
    docker, docker_state = create_mock_docker(parent)
    mock_tar_path = create_mock_tar(parent)
    run([sys.executable, "-I", str(HELPER), "seal", "--work-root", str(state), *common_args(state, digests)])

    many_fields_parent = parent / "many-fields"
    many_fields_parent.mkdir()
    many_fields_state, many_fields_digests = build_state(
        many_fields_parent,
        extra_manifest_fields=32768,
    )
    many_fields = run(
        [
            sys.executable, "-I", str(HELPER), "seal",
            "--work-root", str(many_fields_state),
            *common_args(many_fields_state, many_fields_digests),
        ],
        expect=False,
    )
    assert b"field-count limit" in many_fields.stderr
    assert b"Traceback" not in many_fields.stderr and str(parent).encode() not in many_fields.stderr
    emitter_environment = dict(os.environ)
    emitter_environment["SP11_RELEASE_STATE_EMITTER_FIXTURE"] = "true"
    direct_emitter = run(
        [
            str(EMITTER),
            "--fixture-stage", str(state / ".sp11-release-export-v1"),
            "--fixture-tar", str(mock_tar_path),
        ],
        environment=emitter_environment,
    )
    assert direct_emitter.stderr == b"" and direct_emitter.stdout.endswith(b"\0" * 1024)

    build_result = run(
        [
            sys.executable, "-I", str(HELPER), "run-container",
            "--docker-path", str(docker), "--", str(docker), "create",
            "--fixture-stage", str(state / ".sp11-release-export-v1"),
            "--fixture-fault", "build-success",
        ]
    )
    assert build_result.stdout == b"release build stdout\n"
    assert build_result.stderr == b"release build stderr\n"
    assert not any(docker_state.iterdir())
    failed_build = run(
        [
            sys.executable, "-I", str(HELPER), "run-container",
            "--docker-path", str(docker), "--", str(docker), "create",
            "--fixture-stage", str(state / ".sp11-release-export-v1"),
            "--fixture-fault", "build-failure",
        ],
        expect=False,
    )
    assert b"release build failed\n" in failed_build.stderr
    assert b"Traceback" not in failed_build.stderr
    assert not any(docker_state.iterdir())

    normal_a, imported_a = import_once(parent, state, digests, docker)
    assert normal_a.stdout == IMPORT_SUCCESS and normal_a.stderr == b""
    normal_b, imported_b = import_once(parent, state, digests, docker)
    assert normal_b.stdout == IMPORT_SUCCESS and normal_b.stderr == b""
    evidence_a = imported_a / "sp11-kernel-retained-evidence.tar"
    evidence_b = imported_b / "sp11-kernel-retained-evidence.tar"
    assert evidence_a.read_bytes() == evidence_b.read_bytes()
    published_names = {
        "sp11-kernel-apt-provenance.txt",
        "sp11-kernel-build-inputs.txt",
        "sp11-kernel-build-manifest.txt",
        "sp11-kernel-debs.txt",
        "linux-qcom-x1e-headers-7.2.0-1_7.2.0-1_all.deb",
        "linux-headers-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb",
        "linux-image-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb",
        "linux-modules-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb",
    }
    assert {path.name for path in (imported_a / "artifacts").iterdir()} == published_names
    for name in published_names:
        assert (state / "artifacts" / name).read_bytes() == (imported_a / "artifacts" / name).read_bytes()
    assert not (imported_a / "artifacts/fixture-build-deps_1_arm64.deb").exists()
    assert b"artifacts/fixture-build-deps_1_arm64.deb" in evidence_a.read_bytes()
    assert not any(docker_state.iterdir())

    verified = verify_evidence(
        imported_a,
        state,
        digests,
    )
    assert verified.stderr == b""
    expected_record = bytearray(
        (
            "Verified retained evidence schema: sp11-kernel-evidence-verification-v1\n"
            "Verified retained evidence tar: %d %s\n"
            "Verified flat file count: %d\n"
            % (
                evidence_a.stat().st_size,
                sha256(evidence_a.read_bytes()),
                len(published_names),
            )
        ).encode("ascii")
    )
    for index, name in enumerate(sorted(published_names), 1):
        payload = (imported_a / "artifacts" / name).read_bytes()
        expected_record.extend(
            (
                "Verified flat file %d: %s %d %s\n"
                % (index, name, len(payload), sha256(payload))
            ).encode("ascii")
        )
    expected_record.extend(b"Verified retained evidence complete: true\n")
    assert verified.stdout == bytes(expected_record)

    def hostile_verify_case(label: str) -> Path:
        case = parent / ("verify-" + label)
        shutil.copytree(imported_a, case)
        return case

    for label in (
        "unknown-work",
        "unknown-artifact",
        "flat-tamper",
        "work-mode",
        "artifacts-mode",
    ):
        case = hostile_verify_case(label)
        if label == "unknown-work":
            (case / "apt-archives").mkdir()
        elif label == "unknown-artifact":
            (case / "artifacts/unexpected.deb").write_bytes(b"unexpected\n")
        elif label == "flat-tamper":
            (case / "artifacts/sp11-kernel-debs.txt").write_bytes(b"tampered\n")
        elif label == "work-mode":
            case.chmod(0o755)
        else:
            (case / "artifacts").chmod(0o755)
        refused = verify_evidence(case, state, digests, expect=False)
        assert b"Traceback" not in refused.stderr and str(parent).encode() not in refused.stderr

    missing_tar = hostile_verify_case("missing-tar")
    (missing_tar / "sp11-kernel-retained-evidence.tar").unlink()
    for legacy_name in ("apt-archives", "apt-indexes", "apt-lists"):
        (missing_tar / legacy_name).mkdir()
    missing_result = verify_evidence(
        missing_tar,
        state,
        digests,
        expect=False,
    )
    assert b"Traceback" not in missing_result.stderr and str(parent).encode() not in missing_result.stderr

    for label in ("symlink", "fifo", "hardlink"):
        case = hostile_verify_case("evidence-" + label)
        evidence = case / "sp11-kernel-retained-evidence.tar"
        original = evidence.read_bytes()
        evidence.unlink()
        if label == "symlink":
            victim = parent / "evidence-symlink-victim.tar"
            victim.write_bytes(original)
            evidence.symlink_to(victim)
        elif label == "fifo":
            os.mkfifo(evidence, 0o600)
        else:
            victim = parent / "evidence-hardlink-victim.tar"
            victim.write_bytes(original)
            os.link(victim, evidence)
        refused = verify_evidence(case, state, digests, expect=False)
        assert b"Traceback" not in refused.stderr and str(parent).encode() not in refused.stderr

    for label in ("symlink", "fifo", "hardlink"):
        case = hostile_verify_case("flat-" + label)
        target = case / "artifacts/sp11-kernel-debs.txt"
        original = target.read_bytes()
        target.unlink()
        victim = parent / ("verify-flat-%s-victim" % label)
        victim.write_bytes(original)
        if label == "symlink":
            target.symlink_to(victim)
        elif label == "fifo":
            os.mkfifo(target, 0o600)
        else:
            os.link(victim, target)
        refused = verify_evidence(case, state, digests, expect=False)
        assert b"Traceback" not in refused.stderr and str(parent).encode() not in refused.stderr

    shell_result, shell_import = import_once(
        parent,
        state,
        digests,
        docker,
        "shell-emitter",
        mock_tar_path,
    )
    assert shell_result.stdout == IMPORT_SUCCESS and shell_result.stderr == b""
    assert (shell_import / "sp11-kernel-retained-evidence.tar").read_bytes() == evidence_a.read_bytes()
    assert {
        path.name for path in (shell_import / "artifacts").iterdir()
    } == published_names
    assert not any(docker_state.iterdir())

    ignored_sigchld_result, ignored_sigchld_import = import_once(
        parent,
        state,
        digests,
        docker,
        inherited_sigchld_ignored=True,
    )
    assert ignored_sigchld_result.stdout == IMPORT_SUCCESS
    assert ignored_sigchld_result.stderr == b""
    assert {
        path.name for path in (ignored_sigchld_import / "artifacts").iterdir()
    } == published_names
    assert not any(docker_state.iterdir())

    late_result, late_import = import_once(
        parent,
        state,
        digests,
        docker,
        fixture_hook="inject-late-member",
    )
    assert IMPORT_SUCCESS not in late_result.stdout
    assert b"Traceback" not in late_result.stderr
    assert_zero_outputs(late_import)
    assert not any(docker_state.iterdir())

    late_work_result, late_work_import = import_once(
        parent,
        state,
        digests,
        docker,
        fixture_hook="inject-late-work-member",
    )
    assert IMPORT_SUCCESS not in late_work_result.stdout
    assert b"Traceback" not in late_work_result.stderr
    assert_zero_outputs(late_work_import)
    assert not any(docker_state.iterdir())

    late_output_result, late_output_import = import_once(
        parent,
        state,
        digests,
        docker,
        fixture_hook="mutate-output-after-wide-hashes",
    )
    assert IMPORT_SUCCESS not in late_output_result.stdout
    assert b"Traceback" not in late_output_result.stderr
    assert_zero_outputs(late_output_import)
    assert not any(docker_state.iterdir())

    pre_success_result, pre_success_import = import_once(
        parent,
        state,
        digests,
        docker,
        fixture_hook="mutate-before-success",
    )
    assert IMPORT_SUCCESS not in pre_success_result.stdout
    assert b"Traceback" not in pre_success_result.stderr
    assert_zero_outputs(pre_success_import)
    assert not any(docker_state.iterdir())

    pending_result, pending_import = import_once(
        parent,
        state,
        digests,
        docker,
        fixture_hook="pending-signal-before-success",
    )
    assert IMPORT_SUCCESS not in pending_result.stdout
    assert b"Traceback" not in pending_result.stderr
    assert_zero_outputs(pending_import)
    assert not any(docker_state.iterdir())

    committed_pending_result, committed_pending_import = import_once(
        parent,
        state,
        digests,
        docker,
        fixture_hook="pending-signal-after-commit",
    )
    assert IMPORT_SUCCESS in committed_pending_result.stdout
    assert b"Traceback" not in committed_pending_result.stderr
    assert {
        path.name for path in (committed_pending_import / "artifacts").iterdir()
    } == published_names
    assert not any(docker_state.iterdir())

    initial_member_result, initial_member_import = import_once(
        parent,
        state,
        digests,
        docker,
        "initial-work-member",
    )
    assert IMPORT_SUCCESS not in initial_member_result.stdout
    assert b"Traceback" not in initial_member_result.stderr
    assert not (initial_member_import / "sp11-kernel-retained-evidence.tar").exists()
    assert not any(docker_state.iterdir())

    for fault in (
        "mount-mismatch",
        "repo-source-mismatch",
        "image-mismatch",
        "platform-mismatch",
        "extra-option",
        "shadow-mount",
        "companion-mutate",
        "catalog",
        "duplicate",
        "link",
        "pax",
        "unknown",
        "oversize",
        "trailing",
        "truncated",
        "trailing-hang",
    ):
        started = time.monotonic()
        result, destination = import_once(parent, state, digests, docker, fault)
        assert time.monotonic() - started < 15
        assert b"Traceback" not in result.stderr and str(parent).encode() not in result.stderr
        assert_zero_outputs(destination)
        assert not any(docker_state.iterdir())

    preexisting = parent / "preexisting"
    artifacts = prepare_import_root(preexisting, state)
    victim = preexisting / "victim"
    victim.write_bytes(b"victim bytes\n")
    victim_before = (victim.stat().st_ino, victim.stat().st_size, victim.stat().st_mtime_ns, sha256(victim.read_bytes()))
    (artifacts / "sp11-kernel-build-manifest.txt").symlink_to(victim)
    result = run(
        [
            sys.executable, "-I", str(HELPER), "import-tar",
            "--work-root", str(preexisting),
            "--work-root-identity", *directory_identity_args(preexisting),
            "--artifacts-root", str(artifacts),
            "--artifacts-root-identity", *directory_identity_args(artifacts),
            "--docker-path", str(docker),
            "--retained-volume-name", RETAINED_VOLUME,
            "--container-platform", "linux/arm64",
            "--build-args-identity", *control_identity_args(preexisting / "docker-build-args.txt"),
            "--entrypoint-identity", *control_identity_args(preexisting / "docker-build-inside.sh"),
            "--oci-index-identity", *control_identity_args(preexisting / "sp11-oci-index.json"),
            *common_args(state, digests), "--", *mock_create_command(
                docker,
                state,
                "none",
                image_digest=digests["sp11-oci-index.json"],
            ),
        ],
        expect=False,
    )
    victim_after = (victim.stat().st_ino, victim.stat().st_size, victim.stat().st_mtime_ns, sha256(victim.read_bytes()))
    assert victim_after == victim_before and b"Traceback" not in result.stderr
    assert not (preexisting / "sp11-kernel-retained-evidence.tar").exists()

    interrupted = parent / "interrupted"
    interrupted_artifacts = prepare_import_root(interrupted, state)
    marker = parent / "exporter.pid"
    command = [
        sys.executable, "-I", str(HELPER), "import-tar",
        "--work-root", str(interrupted),
        "--work-root-identity", *directory_identity_args(interrupted),
        "--artifacts-root", str(interrupted_artifacts),
        "--artifacts-root-identity", *directory_identity_args(interrupted_artifacts),
        "--docker-path", str(docker),
        "--retained-volume-name", RETAINED_VOLUME,
        "--container-platform", "linux/arm64",
        "--build-args-identity", *control_identity_args(interrupted / "docker-build-args.txt"),
        "--entrypoint-identity", *control_identity_args(interrupted / "docker-build-inside.sh"),
        "--oci-index-identity", *control_identity_args(interrupted / "sp11-oci-index.json"),
        *common_args(state, digests), "--", *mock_create_command(
            docker,
            state,
            "hang",
            marker,
            image_digest=digests["sp11-oci-index.json"],
        ),
    ]
    interrupted_environment = dict(os.environ)
    interrupted_environment["SP11_RELEASE_STATE_MOCK_STAGE"] = str(
        state / ".sp11-release-export-v1"
    )
    interrupted_environment["SP11_RELEASE_STATE_MOCK_FAULT"] = "hang"
    interrupted_environment["SP11_RELEASE_STATE_MOCK_MARKER"] = str(marker)
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=interrupted_environment,
    )
    try:
        deadline = time.monotonic() + 10
        marker_value = ""
        while time.monotonic() < deadline:
            if marker.exists():
                marker_value = marker.read_text(encoding="ascii")
                if marker_value.isdigit():
                    break
            time.sleep(0.02)
        assert marker_value.isdigit()
        exporter_pid = int(marker_value)
        process.send_signal(signal.SIGTERM)
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=15)
        assert process.returncode != 0 and stdout == b"" and b"Traceback" not in stderr
        try:
            os.kill(exporter_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("interrupted exporter child survived")
        assert_zero_outputs(interrupted)
        assert not any(docker_state.iterdir())
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

    print("Validated retained kernel release-state seal/import hostile boundaries.")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "emit":
        marker_arg = Path(sys.argv[4]) if len(sys.argv) == 5 else None
        raise SystemExit(emit_mode(Path(sys.argv[2]), sys.argv[3], marker_arg))
    if len(sys.argv) >= 4 and sys.argv[1] == "mock-docker":
        raise SystemExit(mock_docker(Path(sys.argv[2]), sys.argv[3:]))
    if len(sys.argv) >= 2 and sys.argv[1] == "mock-tar":
        raise SystemExit(mock_tar(sys.argv[2:]))
    try:
        tests()
    finally:
        for path in CREATED:
            shutil.rmtree(path, ignore_errors=True)
