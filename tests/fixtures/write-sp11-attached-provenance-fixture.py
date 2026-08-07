#!/usr/bin/env python3
"""Write schema-exact synthetic attached provenance for release-gate tests."""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path


SUITES = (
    "resolute",
    "resolute-updates",
    "resolute-backports",
    "resolute-security",
)
COMPONENTS = ("main", "universe", "restricted", "multiverse")
BASELINE = re.compile(r'^([A-Z0-9_]+)="([^"\r\n]*)"$')


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def read_baseline(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = BASELINE.fullmatch(line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def required(values: dict[str, str], key: str) -> str:
    value = values.get(key, "")
    if not value:
        raise SystemExit(f"missing fixture baseline value: {key}")
    return value


def write_apt_sidecar(path: Path, baseline: dict[str, str]) -> None:
    snapshot_id = required(baseline, "SP11_APT_SNAPSHOT_ID")
    snapshot_uri = required(baseline, "SP11_APT_SNAPSHOT_URI")
    architecture = required(baseline, "SP11_APT_SNAPSHOT_ARCHITECTURE")
    lines = [
        "APT provenance schema: sp11-kernel-apt-provenance-v1",
        f"Snapshot ID: {snapshot_id}",
        f"Snapshot URI: {snapshot_uri}",
        f"Suites: {required(baseline, 'SP11_APT_SNAPSHOT_SUITES')}",
        f"Components: {required(baseline, 'SP11_APT_SNAPSHOT_COMPONENTS')}",
        f"Architecture: {architecture}",
        f"Archive keyring SHA256: {required(baseline, 'SP11_APT_ARCHIVE_KEYRING_SHA256')}",
        f"Archive signing fingerprint: {required(baseline, 'SP11_APT_ARCHIVE_SIGNING_FINGERPRINT')}",
        "Strict HTTPS recheck: true",
    ]
    for prefix, row in (
        ("Pre-install", "base-files:arm64=1"),
        ("Post-install", "base-files:arm64=1"),
    ):
        aggregate = sha256_bytes(f"{row}\n".encode())
        lines.extend(
            (
                f"{prefix} package count: 1",
                f"{prefix} package aggregate SHA256: {aggregate}",
                f"{prefix} package 1: {row}",
            )
        )

    lines.append(f"InRelease count: {len(SUITES)}")
    for index, suite in enumerate(SUITES, 1):
        suffix = suite.upper().replace("-", "_")
        lines.extend(
            (
                f"InRelease {index} suite: {suite}",
                f"InRelease {index} size: {1000 + index}",
                f"InRelease {index} SHA256: "
                f"{required(baseline, f'SP11_APT_INRELEASE_{suffix}_SHA256')}",
            )
        )

    index_rows = [
        (suite, relative)
        for suite in SUITES
        for component in COMPONENTS
        for relative in (
            f"{component}/binary-{architecture}/Packages.gz",
            f"{component}/source/Sources.gz",
        )
    ]
    lines.append(f"Index count: {len(index_rows)}")
    for index, (suite, relative) in enumerate(index_rows, 1):
        digest = sha256_bytes(f"{suite}/{relative}\n".encode())
        parent = relative.rsplit("/", 1)[0]
        lines.extend(
            (
                f"Index {index} suite: {suite}",
                f"Index {index} path: {relative}",
                f"Index {index} retained path: {suite}/{relative}",
                f"Index {index} size: {2000 + index}",
                f"Index {index} SHA256: {digest}",
                f"Index {index} URI: {snapshot_uri}dists/{suite}/{parent}"
                f"/by-hash/SHA256/{digest}",
            )
        )

    list_paths = ["lock"]
    for suite in SUITES:
        prefix = f"snapshot.ubuntu.com_ubuntu_{snapshot_id}_dists_{suite}"
        list_paths.append(f"{prefix}_InRelease")
        for component in COMPONENTS:
            list_paths.extend(
                (
                    f"{prefix}_{component}_binary-{architecture}_Packages.lz4",
                    f"{prefix}_{component}_source_Sources.lz4",
                )
            )
    list_paths.sort()
    lines.append(f"APT list target count: {len(list_paths)}")
    for index, list_path in enumerate(list_paths, 1):
        lines.extend(
            (
                f"APT list target {index} path: {list_path}",
                f"APT list target {index} size: {0 if list_path == 'lock' else 3000 + index}",
                f"APT list target {index} SHA256: "
                f"{sha256_bytes((list_path + chr(10)).encode())}",
            )
        )

    deb_rows: list[tuple[str, str, str, str, str]] = []
    count = int(required(baseline, "SP11_APT_BOOTSTRAP_PACKAGE_COUNT"))
    for index in range(1, count + 1):
        package, version = required(
            baseline, f"SP11_APT_BOOTSTRAP_PACKAGE_{index}_SPEC"
        ).split("=", 1)
        digest = required(baseline, f"SP11_APT_BOOTSTRAP_PACKAGE_{index}_SHA256")
        arch = "all" if package == "ca-certificates" else architecture
        filename = f"{package}_{version}_{arch}.deb"
        deb_rows.append((filename, package, version, arch, digest))
    deb_rows.sort()
    lines.append(f"Downloaded Deb count: {len(deb_rows)}")
    signed_location = f"{SUITES[0]}/{COMPONENTS[0]}/binary-{architecture}/Packages.gz"
    for index, (filename, package, version, arch, digest) in enumerate(deb_rows, 1):
        archive_filename = f"pool/main/f/{package}/{filename}"
        lines.extend(
            (
                f"Downloaded Deb {index} path: {filename}",
                f"Downloaded Deb {index} package: {package}",
                f"Downloaded Deb {index} version: {version}",
                f"Downloaded Deb {index} architecture: {arch}",
                f"Downloaded Deb {index} size: {4000 + index}",
                f"Downloaded Deb {index} SHA256: {digest}",
                f"Downloaded Deb {index} archive filename: {archive_filename}",
                f"Downloaded Deb {index} URI: {snapshot_uri}{archive_filename}",
                f"Downloaded Deb {index} signed record count: 1",
                f"Downloaded Deb {index} signed record 1 location: {signed_location}",
            )
        )
    lines.extend(
        (
            "Local build-deps count: 1",
            "Local build-deps 1 path: linux-qcom-x1e-build-deps_1.0_arm64.deb",
            "Local build-deps 1 package: linux-qcom-x1e-build-deps",
            "Local build-deps 1 version: 1.0",
            "Local build-deps 1 architecture: arm64",
            "Local build-deps 1 size: 5000",
            f"Local build-deps 1 SHA256: {'9' * 64}",
            "APT provenance complete: true",
        )
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_envelope(
    path: Path,
    baseline: dict[str, str],
    support_head: str,
    build_manifest: Path,
    apt_provenance: Path,
) -> None:
    image = required(baseline, "SP11_KERNEL_DOCKER_IMAGE")
    index_digest = image.rsplit("@", 1)[1]
    inputs = (
        ("docker-build-arguments", "docker-build-args.txt", 1, "1" * 64),
        ("docker-entrypoint", "docker-build-inside.sh", 1, "2" * 64),
        ("oci-index", "sp11-oci-index.json", 1, index_digest.removeprefix("sha256:")),
        (
            "kernel-build-manifest-v2",
            "artifacts/sp11-kernel-build-manifest.txt",
            build_manifest.stat().st_size,
            sha256_file(build_manifest),
        ),
        (
            "apt-provenance-v1",
            "artifacts/sp11-kernel-apt-provenance.txt",
            apt_provenance.stat().st_size,
            sha256_file(apt_provenance),
        ),
    )
    lines = [
        "Build inputs schema: sp11-kernel-build-inputs-v1",
        "Release build: true",
        f"Support HEAD: {support_head}",
        f"OCI index image: {image}",
        f"OCI index digest: {index_digest}",
        f"OCI platform: {required(baseline, 'SP11_KERNEL_DOCKER_PLATFORM')}",
        f"OCI platform manifest: {required(baseline, 'SP11_KERNEL_DOCKER_PLATFORM_MANIFEST')}",
        f"Input count: {len(inputs)}",
    ]
    for index, (role, input_path, size, digest) in enumerate(inputs, 1):
        lines.extend(
            (
                f"Input {index} role: {role}",
                f"Input {index} path: {input_path}",
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
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--support-head", required=True)
    parser.add_argument("--build-manifest", required=True, type=Path)
    parser.add_argument("--apt-provenance", required=True, type=Path)
    parser.add_argument("--build-inputs", required=True, type=Path)
    args = parser.parse_args()
    baseline = read_baseline(args.baseline)
    write_apt_sidecar(args.apt_provenance, baseline)
    write_envelope(
        args.build_inputs,
        baseline,
        args.support_head,
        args.build_manifest,
        args.apt_provenance,
    )


if __name__ == "__main__":
    main()
