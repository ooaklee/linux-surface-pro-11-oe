#!/usr/bin/env python3
"""Validate the exact provenance contract used to bind an SP11 release image."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import os
import re
import signal
import stat
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit


OID = re.compile(r"(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
POSITIVE = re.compile(r"[1-9][0-9]*\Z")
SAFE_NAME = re.compile(r"[A-Za-z0-9._+-]+\Z")
SAFE_PACKAGE = re.compile(r"[a-z0-9][a-z0-9.+-]*\Z")
SAFE_VERSION = re.compile(r"[0-9A-Za-z.+:~_-]+\Z")
SAFE_ARCH = re.compile(r"[a-z0-9][a-z0-9-]*\Z")
SAFE_PATH = re.compile(r"[A-Za-z0-9._+/-]+\Z")
ISO_UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
FINGERPRINT = re.compile(r"(?:[0-9A-F]{2}:){31}[0-9A-F]{2}\Z")
SERIAL = re.compile(r"[0-9A-F]+\Z")
SOURCE_REF = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]*\Z")
PRINTABLE = re.compile(r"[ -~]{1,512}\Z")
MODULE_SIGNING_POLICY = "sp11-controlled-rsa4096-sha512-v1"
MODULE_SIGNING_CERTIFICATE = "sp11-module-signing-cert.x509"
KERNEL_SIGNATURE_REPORT = "sp11-kernel-module-signatures.txt"
KERNEL_SIGNATURE_REPORT_SCHEMA = "sp11-kernel-module-signature-verification-v1"
KERNEL_UNSIGNED_ALLOWLIST = (
    "config/kernel-signing/sp11-module-signing-allowed-unsigned.txt"
)

OUTPUT_PATHS = {
    "kernel-config": "debian/build/build-qcom-x1e/.config",
    "module-symvers": "debian/build/build-qcom-x1e/Module.symvers",
    "system-map": "debian/build/build-qcom-x1e/System.map",
    "kernel-efi-stubble": "debian/build/build-qcom-x1e/arch/arm64/boot/vmlinuz.efi.stubble",
    "denali-oled-dtb": (
        "debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/"
        "x1e80100-microsoft-denali-oled.dtb"
    ),
    "denali-oled-el2-dtb": (
        "debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/"
        "x1e80100-microsoft-denali-oled-el2.dtb"
    ),
    "module-signing-certificate": "debian/build/build-qcom-x1e/certs/signing_key.x509",
}
REQUIRED_OUTPUTS = (
    "kernel-config module-symvers system-map kernel-efi-stubble "
    "denali-oled-dtb denali-oled-el2-dtb module-signing-certificate"
)
REQUIRED_DEBS = "common-headers headers image modules"
MODULE_NAMES = {
    "gpi.ko": "gpi",
    "spi-geni-qcom.ko": "spi_geni_qcom",
    "mshw0485_touch.ko": "mshw0485_touch",
}
BUILD_INPUT_ROLES = (
    "docker-build-arguments",
    "docker-entrypoint",
    "oci-index",
    "kernel-build-manifest-v2",
    "apt-provenance-v1",
)
ATTACHED_BASELINE = "config/kernel-baselines/7.2-rc5-jg-0.env"
FIXED_BUILD_ONLY_GIT = "/usr/bin/git"
GIT_EXECUTABLE = "git"


class ValidationError(Exception):
    """An expected, user-facing release binding failure."""


class Manifest:
    def __init__(self, path: Path) -> None:
        self.path = path
        try:
            data = path.read_bytes()
        except OSError as exc:
            raise ValidationError(f"could not read manifest {path.name}: {exc}") from exc
        if not data or len(data) > 4 * 1024 * 1024:
            raise ValidationError(f"manifest has an invalid size: {path.name}")
        try:
            self.text = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValidationError(f"manifest is not valid UTF-8: {path.name}") from exc
        if "\r" in self.text or "\x00" in self.text or any(
            ord(character) < 32 and character not in "\n\t" for character in self.text
        ):
            raise ValidationError(f"manifest contains unsafe control characters: {path.name}")
        self.lines = self.text.splitlines()
        self.fields: dict[str, list[str]] = {}
        self.top_labels: set[str] = set()
        for line in self.lines:
            if ": " not in line:
                continue
            label, value = line.split(": ", 1)
            self.fields.setdefault(label, []).append(value)
            if line and not line[0].isspace():
                self.top_labels.add(label)

    def one(self, label: str) -> str:
        values = self.fields.get(label, [])
        if len(values) != 1 or not values[0]:
            raise ValidationError(
                f"{self.path.name} must contain exactly one nonempty '{label}:' field"
            )
        return values[0]

    def exact_top_labels(self, expected: set[str]) -> None:
        missing = sorted(expected - self.top_labels)
        extra = sorted(self.top_labels - expected)
        if missing:
            raise ValidationError(
                f"{self.path.name} is missing required top-level field: {missing[0]}"
            )
        if extra:
            raise ValidationError(
                f"{self.path.name} contains an unexpected top-level field: {extra[0]}"
            )

    def exact_flat_labels(self, expected: set[str]) -> None:
        self.exact_top_labels(expected)
        for line in self.lines:
            require(
                bool(line)
                and not line[0].isspace()
                and ": " in line
                and line.split(": ", 1)[0] in expected,
                f"{self.path.name} contains a non-schema line",
            )

    def exact_flat_label_order(self, expected: list[str]) -> None:
        self.exact_flat_labels(set(expected))
        actual = [line.split(": ", 1)[0] for line in self.lines]
        require(
            actual == expected,
            f"{self.path.name} field order does not match its schema",
        )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def safe_relative_path(value: str) -> bool:
    if not SAFE_PATH.fullmatch(value):
        return False
    parts = value.split("/")
    return bool(parts) and all(part not in ("", ".", "..") for part in parts)


def public_https_url(value: str) -> bool:
    if (
        not value.startswith("https://")
        or len(value) > 2048
        or re.fullmatch(r"[A-Za-z0-9._~:/%+\-]+", value) is None
    ):
        return False
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        return False
    hostname = parsed.hostname
    if (
        hostname is None
        or not re.fullmatch(r"[A-Za-z0-9.-]+", hostname)
        or hostname.startswith(".")
        or hostname.endswith(".")
        or ".." in hostname
    ):
        return False
    if re.fullmatch(r"[0-9.]+", hostname):
        return False
    lowered_hostname = hostname.lower()
    if (
        lowered_hostname == "localhost"
        or lowered_hostname.startswith("localhost.")
        or lowered_hostname.endswith(".localhost")
        or lowered_hostname.endswith(".local")
        or lowered_hostname.endswith(".internal")
        or lowered_hostname.endswith(".invalid")
        or lowered_hostname.endswith(".test")
        or lowered_hostname.endswith(".example")
        or lowered_hostname.endswith(".onion")
    ):
        return False
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        if "." not in hostname:
            return False
    else:
        # Release provenance uses stable public DNS names, not literal addresses.
        return False
    return (
        parsed.scheme == "https"
        and port is None
        and parsed.username is None
        and parsed.password is None
        and not parsed.query
        and not parsed.fragment
        and parsed.path not in ("", "/")
        and not any(character.isspace() for character in value)
    )


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
        if (
            name in redirected_names
            or re.fullmatch(r"GIT_CONFIG_(?:KEY|VALUE)_[0-9]+", name)
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


def establish_child_wait_authority() -> None:
    try:
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    except (OSError, ValueError) as exc:
        raise ValidationError(
            "could not establish manifest-validator child wait authority"
        ) from exc
    require_child_wait_authority()


def require_child_wait_authority() -> None:
    require(
        signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL,
        "manifest-validator child wait authority changed",
    )


def run_git(repo: Path, arguments: list[str], *, binary: bool = False) -> bytes | str:
    require_child_wait_authority()
    try:
        result = subprocess.run(
            [GIT_EXECUTABLE, "-c", f"safe.directory={repo}", "-C", str(repo), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=isolated_git_environment(),
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", b"")
        if isinstance(detail, bytes):
            detail = detail.decode("utf-8", "replace")
        raise ValidationError(f"could not verify committed support provenance: {detail}") from exc
    if binary:
        return result.stdout
    return result.stdout.decode("utf-8", "strict").strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as exc:
        raise ValidationError(f"could not hash release input {path.name}: {exc}") from exc
    return digest.hexdigest()


def file_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError as exc:
        raise ValidationError(f"could not size release input {path.name}: {exc}") from exc


def validate_attached_build_inputs(
    repo: Path,
    support_commit: str,
    build_manifest: Path,
    apt_provenance: Path,
    build_inputs: Path,
) -> dict[str, str]:
    helper = repo / "scripts/sp11-kernel-build-inputs.py"
    baseline = repo / ATTACHED_BASELINE
    regular_input(helper, "attached build-input validator")
    regular_input(baseline, "kernel baseline")
    require_child_wait_authority()
    try:
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                str(helper),
                "validate-attached",
                "--baseline",
                str(baseline),
                "--support-head",
                support_commit,
                "--build-manifest",
                str(build_manifest),
                "--apt-provenance",
                str(apt_provenance),
                "--output",
                str(build_inputs),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=isolated_git_environment(),
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "")
        raise ValidationError(
            f"attached immutable build inputs failed flat validation: {detail.strip()}"
        ) from exc
    require(
        "Validated attached immutable build-inputs envelope:" in result.stdout,
        "attached build-input validator did not report completion",
    )

    apt = Manifest(apt_provenance)
    envelope = Manifest(build_inputs)
    envelope_labels = {
        "Build inputs schema",
        "Release build",
        "Support HEAD",
        "OCI index image",
        "OCI index digest",
        "OCI platform",
        "OCI platform manifest",
        "Input count",
        "Publication schema propagation",
        "Build inputs complete",
    }
    for index in range(1, len(BUILD_INPUT_ROLES) + 1):
        envelope_labels.update(
            {
                f"Input {index} role",
                f"Input {index} path",
                f"Input {index} size",
                f"Input {index} SHA256",
            }
        )
    envelope.exact_flat_labels(envelope_labels)
    require(
        envelope.one("Build inputs schema") == "sp11-kernel-build-inputs-v1"
        and envelope.one("Release build") == "true"
        and envelope.one("Support HEAD") == support_commit
        and envelope.one("Input count") == str(len(BUILD_INPUT_ROLES))
        and envelope.one("Publication schema propagation") == "incomplete"
        and envelope.one("Build inputs complete") == "true",
        "attached build-inputs envelope state is incomplete or inconsistent",
    )
    for index, role in enumerate(BUILD_INPUT_ROLES, 1):
        require(
            envelope.one(f"Input {index} role") == role,
            f"attached build-inputs role differs at input {index}",
        )
    for index, expected_path in (
        (4, build_manifest),
        (5, apt_provenance),
    ):
        require(
            envelope.one(f"Input {index} path") == f"artifacts/{expected_path.name}"
            and envelope.one(f"Input {index} size") == str(file_size(expected_path))
            and envelope.one(f"Input {index} SHA256") == sha256_file(expected_path),
            f"attached build-inputs identity differs at input {index}",
        )

    apt_schema = apt.one("APT provenance schema")
    snapshot_id = apt.one("Snapshot ID")
    snapshot_uri = apt.one("Snapshot URI")
    require(
        apt_schema == "sp11-kernel-apt-provenance-v1"
        and apt.one("APT provenance complete") == "true",
        "attached APT provenance is incomplete or has the wrong schema",
    )
    return {
        "apt_schema": apt_schema,
        "snapshot_id": snapshot_id,
        "snapshot_uri": snapshot_uri,
        "build_inputs_schema": envelope.one("Build inputs schema"),
        "creation_propagation": envelope.one("Publication schema propagation"),
        "oci_image": envelope.one("OCI index image"),
        "oci_digest": envelope.one("OCI index digest"),
        "oci_platform": envelope.one("OCI platform"),
        "oci_platform_manifest": envelope.one("OCI platform manifest"),
        "build_manifest_size": str(file_size(build_manifest)),
        "build_manifest_sha": sha256_file(build_manifest),
        "apt_size": str(file_size(apt_provenance)),
        "apt_sha": sha256_file(apt_provenance),
        "build_inputs_size": str(file_size(build_inputs)),
        "build_inputs_sha": sha256_file(build_inputs),
    }


def validate_git_ref(repo: Path, source_ref: str) -> None:
    require(bool(SOURCE_REF.fullmatch(source_ref)), "build source ref is unsafe")
    run_git(repo, ["check-ref-format", f"refs/heads/{source_ref}"])


def validate_kernel_signature_report(
    path: Path,
    manifest: Manifest,
    repo: Path,
    support_commit: str,
    abi: str,
    debs: list[dict[str, str]],
    certificate_sha: str,
    certificate_fingerprint: str,
    certificate_serial: str,
) -> dict[str, str]:
    regular_input(path, "kernel module signature report")
    data = path.read_bytes()
    require(
        len(data) <= 16 * 1024 * 1024
        and data.endswith(b"\n")
        and b"\r" not in data
        and b"\0" not in data,
        "kernel module signature report is not canonical LF text",
    )
    try:
        lines = data.decode("utf-8", "strict").splitlines()
    except UnicodeDecodeError as exc:
        raise ValidationError("kernel module signature report is not UTF-8") from exc
    require(
        len(lines) >= 16
        and lines[0] == "# Surface Pro 11 Kernel Module Signature Report"
        and lines[1] == "",
        "kernel module signature report has the wrong header",
    )
    index = 2

    def consume(label: str) -> str:
        nonlocal index
        require(index < len(lines), f"kernel module signature report is missing: {label}")
        prefix = f"{label}: "
        line = lines[index]
        require(line.startswith(prefix) and len(line) > len(prefix), f"kernel module signature report has the wrong field: {label}")
        index += 1
        return line[len(prefix) :]

    schema = consume("Schema")
    report_abi = consume("Kernel ABI")
    package_count_text = consume("Package count")
    require(
        schema == KERNEL_SIGNATURE_REPORT_SCHEMA
        and report_abi == abi
        and package_count_text in ("1", "2"),
        "kernel module signature report schema, ABI, or package count is invalid",
    )
    package_count = int(package_count_text, 10)
    package_debs = [deb for deb in debs if deb["role"] in ("modules", "modules-extra")]
    require(
        len(package_debs) == package_count
        and [deb["role"] for deb in package_debs]
        == (["modules"] if package_count == 1 else ["modules", "modules-extra"]),
        "kernel module signature report package roles differ from build provenance",
    )
    package_modules = 0
    package_signed = 0
    package_unsigned = 0
    for package_index, deb in enumerate(package_debs, 1):
        role = consume(f"Package {package_index} role")
        filename = consume(f"Package {package_index} file")
        package = consume(f"Package {package_index} name")
        version = consume(f"Package {package_index} version")
        architecture = consume(f"Package {package_index} architecture")
        size = consume(f"Package {package_index} size")
        digest = consume(f"Package {package_index} SHA256")
        module_count = consume(f"Package {package_index} module count")
        signed_count = consume(
            f"Package {package_index} cryptographically verified signed module count"
        )
        unsigned_count = consume(
            f"Package {package_index} policy-allowed unsigned module count"
        )
        require(
            (role, filename, package, version, architecture, size, digest)
            == (
                deb["role"],
                deb["path"],
                deb["package"],
                deb["version"],
                deb["architecture"],
                deb["size"],
                deb["sha"],
            )
            and bool(POSITIVE.fullmatch(module_count))
            and module_count.isdigit()
            and re.fullmatch(r"(?:0|[1-9][0-9]*)", signed_count) is not None
            and re.fullmatch(r"(?:0|[1-9][0-9]*)", unsigned_count) is not None
            and int(module_count, 10)
            == int(signed_count, 10) + int(unsigned_count, 10),
            f"kernel module signature report package {package_index} is inconsistent",
        )
        package_modules += int(module_count, 10)
        package_signed += int(signed_count, 10)
        package_unsigned += int(unsigned_count, 10)

    require(
        consume("Module signing policy") == MODULE_SIGNING_POLICY
        and consume("Module signing hash algorithm") == "sha512"
        and consume("Module signing certificate SHA256") == certificate_sha
        and consume("Module signing certificate fingerprint") == certificate_fingerprint
        and consume("Module signing certificate serial") == certificate_serial,
        "kernel module signature report signing identity differs from build provenance",
    )
    total_text = consume("Total module count")
    signed_text = consume("Cryptographically verified signed module count")
    unsigned_text = consume("Policy-allowed unsigned module count")
    inventory_sha = consume("Policy-allowed unsigned module path inventory SHA256")
    require(
        bool(POSITIVE.fullmatch(total_text))
        and re.fullmatch(r"(?:0|[1-9][0-9]*)", signed_text) is not None
        and re.fullmatch(r"(?:0|[1-9][0-9]*)", unsigned_text) is not None
        and int(total_text, 10) == package_modules
        and int(signed_text, 10) == package_signed
        and int(unsigned_text, 10) == package_unsigned
        and int(total_text, 10) == int(signed_text, 10) + int(unsigned_text, 10)
        and bool(SHA256.fullmatch(inventory_sha))
        and consume("Validation completed") == "true",
        "kernel module signature report aggregate counts are inconsistent",
    )
    require(
        index + 1 < len(lines)
        and lines[index] == ""
        and lines[index + 1] == "## Policy-allowed unsigned module paths",
        "kernel module signature report unsigned-path section is malformed",
    )
    unsigned_paths = lines[index + 2 :]
    require(
        len(unsigned_paths) == package_unsigned
        and unsigned_paths == sorted(unsigned_paths)
        and len(unsigned_paths) == len(set(unsigned_paths)),
        "kernel module signature report unsigned-path inventory is not exact",
    )
    normalized_paths: list[str] = []
    for row in unsigned_paths:
        require(row.startswith("- ") and len(row) > 2, "kernel module signature report has an invalid unsigned-path row")
        value = row[2:]
        require(
            safe_relative_path(value)
            and re.fullmatch(r"[A-Za-z0-9._+/-]+\.ko(?:\.(?:gz|xz|zst))?", value)
            is not None,
            "kernel module signature report has an unsafe unsigned module path",
        )
        normalized_paths.append(value)
    calculated_inventory_sha = hashlib.sha256(
        "".join(f"{value}\n" for value in normalized_paths).encode("ascii")
    ).hexdigest()
    require(
        calculated_inventory_sha == inventory_sha,
        "kernel module signature report unsigned-path inventory hash is false",
    )

    committed_allowlist = run_git(
        repo,
        ["show", f"{support_commit}:{KERNEL_UNSIGNED_ALLOWLIST}"],
        binary=True,
    )
    assert isinstance(committed_allowlist, bytes)
    require(
        bool(committed_allowlist)
        and committed_allowlist.endswith(b"\n")
        and b"\r" not in committed_allowlist
        and b"\0" not in committed_allowlist,
        "committed kernel module unsigned allowlist is not canonical LF text",
    )
    try:
        allowlist_paths = committed_allowlist.decode("ascii", "strict").splitlines()
    except UnicodeDecodeError as exc:
        raise ValidationError(
            "committed kernel module unsigned allowlist is not canonical ASCII"
        ) from exc
    require(
        bool(allowlist_paths)
        and allowlist_paths == sorted(allowlist_paths)
        and len(allowlist_paths) == len(set(allowlist_paths))
        and all(
            safe_relative_path(value)
            and re.fullmatch(r"[A-Za-z0-9._+/-]+\.ko(?:\.(?:gz|xz|zst))?", value)
            is not None
            for value in allowlist_paths
        ),
        "committed kernel module unsigned allowlist is malformed",
    )
    require(
        normalized_paths == allowlist_paths
        and package_unsigned == len(allowlist_paths)
        and inventory_sha == hashlib.sha256(committed_allowlist).hexdigest(),
        "kernel module signature report differs from the committed unsigned allowlist",
    )

    report_sha = sha256_file(path)
    report_size = str(file_size(path))
    comparisons = {
        "Kernel module signature report asset": KERNEL_SIGNATURE_REPORT,
        "Kernel module signature report size": report_size,
        "Kernel module signature report SHA256": report_sha,
        "Kernel module signature report schema": KERNEL_SIGNATURE_REPORT_SCHEMA,
        "Kernel module total count": total_text,
        "Kernel module verified signed count": signed_text,
        "Kernel module policy-allowed unsigned count": unsigned_text,
        "Kernel module unsigned-path inventory SHA256": inventory_sha,
    }
    for label, expected in comparisons.items():
        require(manifest.one(label) == expected, f"kernel build field does not match signature report: {label}")
    return {
        "asset": KERNEL_SIGNATURE_REPORT,
        "size": report_size,
        "sha": report_sha,
        "schema": schema,
        "total": total_text,
        "signed": signed_text,
        "unsigned": unsigned_text,
        "inventory_sha": inventory_sha,
    }


def validate_build(manifest: Manifest, repo: Path, support_commit: str) -> dict[str, object]:
    scalar_labels = {
        "Provenance schema",
        "Release build",
        "Support start HEAD",
        "Support start dirty",
        "Support end HEAD",
        "Support end dirty",
        "Source mode",
        "Source URL",
        "Source ref",
        "Expected source commit",
        "Source HEAD",
        "Container image",
        "Container digest",
        "Container platform",
        "Build target",
        "Jobs",
        "Rules runner",
        "Patch count",
        "Patched diff format",
        "Patched diff Git version",
        "Patched diff SHA256",
        "Patched tree ID",
        "Required output roles",
        "Optional output roles",
        "Output count",
        "Module signing policy",
        "Module signing private material retained",
        "Signing certificate SHA256",
        "Signing certificate fingerprint",
        "Signing certificate serial",
        "Kernel module signature report asset",
        "Kernel module signature report size",
        "Kernel module signature report SHA256",
        "Kernel module signature report schema",
        "Kernel module total count",
        "Kernel module verified signed count",
        "Kernel module policy-allowed unsigned count",
        "Kernel module unsigned-path inventory SHA256",
        "Required Deb roles",
        "Optional Deb roles",
        "Deb count",
        "Build completed",
    }
    patch_count_text = manifest.one("Patch count")
    output_count_text = manifest.one("Output count")
    deb_count_text = manifest.one("Deb count")
    require(
        bool(POSITIVE.fullmatch(patch_count_text)),
        "kernel build manifest has an invalid patch count",
    )
    require(output_count_text == "7", "kernel build manifest must contain exactly 7 outputs")
    require(deb_count_text in ("4", "5"), "kernel build manifest must contain 4 or 5 Debs")
    patch_count = int(patch_count_text)
    output_count = int(output_count_text)
    deb_count = int(deb_count_text)
    dynamic_labels: set[str] = set()
    for index in range(1, patch_count + 1):
        dynamic_labels.update(
            {
                f"Patch {index} path",
                f"Patch {index} SHA256",
                f"Patch {index} disposition",
            }
        )
    for index in range(1, output_count + 1):
        dynamic_labels.update(
            {
                f"Output {index} role",
                f"Output {index} required",
                f"Output {index} path",
                f"Output {index} size",
                f"Output {index} SHA256",
            }
        )
    for index in range(1, deb_count + 1):
        dynamic_labels.update(
            {
                f"Deb {index} role",
                f"Deb {index} required",
                f"Deb {index} path",
                f"Deb {index} package",
                f"Deb {index} version",
                f"Deb {index} architecture",
                f"Deb {index} size",
                f"Deb {index} SHA256",
            }
        )
    manifest.exact_flat_labels(scalar_labels | dynamic_labels)

    require(manifest.one("Provenance schema") == "sp11-kernel-build-v2", "wrong build schema")
    require(manifest.one("Release build") == "true", "build manifest is not a release build")
    require(manifest.one("Build completed") == "true", "build manifest is incomplete")
    start = manifest.one("Support start HEAD").lower()
    end = manifest.one("Support end HEAD").lower()
    require(
        bool(OID.fullmatch(start))
        and start == end
        and start == support_commit
        and manifest.one("Support start dirty") == "false"
        and manifest.one("Support end dirty") == "false",
        "build manifest does not bind a clean stable current support commit",
    )
    source_head = manifest.one("Source HEAD").lower()
    expected_source = manifest.one("Expected source commit").lower()
    require(
        manifest.one("Source mode") == "git"
        and bool(OID.fullmatch(source_head))
        and source_head == expected_source,
        "build manifest does not bind the expected source commit",
    )
    source_url = manifest.one("Source URL")
    source_ref = manifest.one("Source ref")
    require(public_https_url(source_url), "build source URL is not credential-free public HTTPS")
    validate_git_ref(repo, source_ref)
    container_image = manifest.one("Container image")
    container_digest = manifest.one("Container digest")
    require(
        bool(re.fullmatch(r"[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}", container_image))
        and container_image.rsplit("@", 1)[1] == container_digest,
        "build manifest does not contain a consistent digest-pinned container image",
    )
    platform = manifest.one("Container platform")
    require(platform in ("linux/arm64", "linux/arm64/v8"), "unsupported build platform")
    jobs = manifest.one("Jobs")
    rules_runner = manifest.one("Rules runner")
    require(
        manifest.one("Build target") == "binary-indep binary-qcom-x1e"
        and bool(POSITIVE.fullmatch(jobs))
        and rules_runner in ("direct-root", "fakeroot"),
        "build target, jobs, or rules-runner provenance is incomplete",
    )
    diff_sha = manifest.one("Patched diff SHA256")
    patched_tree = manifest.one("Patched tree ID").lower()
    require(
        manifest.one("Patched diff format") == "git-diff-full-index-binary-v1"
        and manifest.one("Patched diff Git version").startswith("git version ")
        and bool(SHA256.fullmatch(diff_sha))
        and bool(OID.fullmatch(patched_tree))
        and len(patched_tree) == len(source_head),
        "build manifest has incomplete canonical patched-tree provenance",
    )
    require(
        manifest.one("Required output roles") == REQUIRED_OUTPUTS
        and manifest.one("Optional output roles") == "none"
        and manifest.one("Required Deb roles") == REQUIRED_DEBS
        and manifest.one("Optional Deb roles") == "modules-extra",
        "build manifest role declarations do not match schema v2",
    )

    for index in range(1, patch_count + 1):
        path = manifest.one(f"Patch {index} path")
        patch_sha = manifest.one(f"Patch {index} SHA256")
        disposition = manifest.one(f"Patch {index} disposition")
        require(
            safe_relative_path(path)
            and bool(SHA256.fullmatch(patch_sha))
            and disposition in ("applied", "already-applied", "already-satisfied"),
            f"build patch {index} has unsafe or incomplete provenance",
        )
        blob = run_git(repo, ["cat-file", "blob", f"{support_commit}:{path}"], binary=True)
        assert isinstance(blob, bytes)
        require(
            hashlib.sha256(blob).hexdigest() == patch_sha,
            f"build patch {index} does not match the committed support patch",
        )

    outputs: dict[str, dict[str, str]] = {}
    seen_paths: set[str] = set()
    for index in range(1, output_count + 1):
        role = manifest.one(f"Output {index} role")
        path = manifest.one(f"Output {index} path")
        size = manifest.one(f"Output {index} size")
        output_sha = manifest.one(f"Output {index} SHA256")
        require(
            role in OUTPUT_PATHS
            and role not in outputs
            and path == OUTPUT_PATHS[role]
            and path not in seen_paths
            and manifest.one(f"Output {index} required") == "true"
            and bool(POSITIVE.fullmatch(size))
            and bool(SHA256.fullmatch(output_sha)),
            f"build output {index} is incomplete, duplicated, or has the wrong path",
        )
        outputs[role] = {"path": path, "sha": output_sha}
        seen_paths.add(path)
    require(set(outputs) == set(OUTPUT_PATHS), "build manifest is missing a required output role")
    certificate_sha = manifest.one("Signing certificate SHA256")
    require(
        manifest.one("Module signing policy") == MODULE_SIGNING_POLICY
        and manifest.one("Module signing private material retained") == "false"
        and bool(SHA256.fullmatch(certificate_sha))
        and outputs["module-signing-certificate"]["sha"] == certificate_sha
        and bool(FINGERPRINT.fullmatch(manifest.one("Signing certificate fingerprint")))
        and bool(SERIAL.fullmatch(manifest.one("Signing certificate serial"))),
        "build signing-certificate identity is incomplete or inconsistent",
    )

    debs: list[dict[str, str]] = []
    seen_roles: set[str] = set()
    seen_deb_paths: set[str] = set()
    versions: set[str] = set()
    abi = ""
    common_package = ""
    for index in range(1, deb_count + 1):
        role = manifest.one(f"Deb {index} role")
        required = manifest.one(f"Deb {index} required")
        path = manifest.one(f"Deb {index} path")
        package = manifest.one(f"Deb {index} package")
        version = manifest.one(f"Deb {index} version")
        architecture = manifest.one(f"Deb {index} architecture")
        size = manifest.one(f"Deb {index} size")
        deb_sha = manifest.one(f"Deb {index} SHA256")
        require(
            role in {"common-headers", "headers", "image", "modules", "modules-extra"}
            and role not in seen_roles
            and required == ("false" if role == "modules-extra" else "true")
            and bool(SAFE_NAME.fullmatch(path))
            and path.startswith("linux-")
            and path.endswith(".deb")
            and path not in seen_deb_paths
            and bool(SAFE_PACKAGE.fullmatch(package))
            and bool(SAFE_VERSION.fullmatch(version))
            and bool(SAFE_ARCH.fullmatch(architecture))
            and bool(POSITIVE.fullmatch(size))
            and bool(SHA256.fullmatch(deb_sha))
            and path == f"{package}_{version}_{architecture}.deb",
            f"build Deb {index} has incomplete or unsafe package identity",
        )
        require(
            architecture == ("all" if role == "common-headers" else "arm64"),
            f"build Deb {index} has the wrong architecture for role {role}",
        )
        if role == "common-headers":
            common_package = package
        else:
            prefixes = (
                ("linux-image-unsigned-", "linux-image-")
                if role == "image"
                else (f"linux-{role}-",)
            )
            prefix = next((item for item in prefixes if package.startswith(item)), "")
            require(bool(prefix), f"build Deb {index} package does not match its role")
            candidate_abi = package[len(prefix) :]
            if abi:
                require(candidate_abi == abi, "build Debs contain mixed kernel ABIs")
            else:
                abi = candidate_abi
        versions.add(version)
        seen_roles.add(role)
        seen_deb_paths.add(path)
        debs.append(
            {
                "role": role,
                "path": path,
                "package": package,
                "version": version,
                "architecture": architecture,
                "size": size,
                "sha": deb_sha,
            }
        )
    require(
        {"common-headers", "headers", "image", "modules"}.issubset(seen_roles)
        and seen_roles.issubset(
            {"common-headers", "headers", "image", "modules", "modules-extra"}
        )
        and len(versions) == 1
        and abi.endswith("-qcom-x1e")
        and common_package == f"linux-qcom-x1e-headers-{abi[:-len('-qcom-x1e')]}",
        "build Deb roles, versions, or ABI identities are inconsistent",
    )
    debs_by_role = {deb["role"]: deb for deb in debs}
    signature_report = validate_kernel_signature_report(
        manifest.path.with_name(KERNEL_SIGNATURE_REPORT),
        manifest,
        repo,
        support_commit,
        abi,
        debs,
        certificate_sha,
        manifest.one("Signing certificate fingerprint"),
        manifest.one("Signing certificate serial"),
    )
    return {
        "support": start,
        "source_head": source_head,
        "source_url": source_url,
        "source_ref": source_ref,
        "container_image": container_image,
        "container_digest": container_digest,
        "platform": platform,
        "target": manifest.one("Build target"),
        "jobs": jobs,
        "runner": rules_runner,
        "diff_format": manifest.one("Patched diff format"),
        "diff_git": manifest.one("Patched diff Git version"),
        "diff_sha": diff_sha,
        "tree": patched_tree,
        "required_outputs": manifest.one("Required output roles"),
        "optional_outputs": manifest.one("Optional output roles"),
        "required_debs": manifest.one("Required Deb roles"),
        "optional_debs": manifest.one("Optional Deb roles"),
        "module_signing_policy": manifest.one("Module signing policy"),
        "module_signing_private_material_retained": manifest.one(
            "Module signing private material retained"
        ),
        "certificate_sha": certificate_sha,
        "certificate_fingerprint": manifest.one("Signing certificate fingerprint"),
        "certificate_serial": manifest.one("Signing certificate serial"),
        "kernel_signature_report": signature_report,
        "config_sha": outputs["kernel-config"]["sha"],
        "symvers_sha": outputs["module-symvers"]["sha"],
        "abi": abi,
        "debs": debs,
        "common_headers_deb": debs_by_role["common-headers"]["path"],
        "common_headers_deb_sha": debs_by_role["common-headers"]["sha"],
        "headers_deb": debs_by_role["headers"]["path"],
        "headers_deb_sha": debs_by_role["headers"]["sha"],
    }


def validate_release(
    manifest: Manifest,
    build: dict[str, object],
    attached: dict[str, str],
    build_manifest: Path,
    apt_provenance: Path,
    build_inputs: Path,
    kernel_source: Path,
    touchscreen_source: Path | None,
    retained_evidence: Path | None = None,
) -> dict[str, str]:
    debs = build["debs"]
    assert isinstance(debs, list)
    package_count = manifest.one("Package count")
    require(package_count == str(len(debs)), "kernel release package count differs from build")
    scalar_labels = {
        "Generated",
        "Release",
        "Kernel release schema",
        "Build provenance schema",
        "Release build",
        "Build completed",
        "Support repo commit",
        "Support repo dirty",
        "Source mode",
        "Source URL",
        "Source branch",
        "Source HEAD",
        "Docker image",
        "Container digest",
        "Container platform",
        "Build target",
        "Jobs",
        "Rules runner",
        "Patched diff format",
        "Patched diff Git version",
        "Patched diff SHA256",
        "Patched tree ID",
        "Required output roles",
        "Optional output roles",
        "Required package roles",
        "Optional package roles",
        "Module signing policy",
        "Module signing private material retained",
        "Signing certificate SHA256",
        "Signing certificate fingerprint",
        "Signing certificate serial",
        "Kernel module signature report asset",
        "Kernel module signature report size",
        "Kernel module signature report SHA256",
        "Kernel module signature report schema",
        "Kernel module total count",
        "Kernel module verified signed count",
        "Kernel module policy-allowed unsigned count",
        "Kernel module unsigned-path inventory SHA256",
        "Package count",
        "Kernel source archive",
        "Kernel source archive SHA256",
        "Kernel source tree ID",
        "Kernel build manifest asset",
        "Kernel build manifest size",
        "Kernel build manifest SHA256",
        "APT provenance asset",
        "APT provenance schema",
        "APT provenance size",
        "APT provenance SHA256",
        "APT snapshot ID",
        "APT snapshot URI",
        "Build inputs asset",
        "Build inputs schema",
        "Build inputs size",
        "Build inputs SHA256",
        "Build envelope creation propagation",
        "Kernel release propagation",
        "OCI index image",
        "OCI index digest",
        "OCI platform",
        "OCI platform manifest",
        "Publication state",
    }
    retained_evidence_labels = {
        "Retained evidence schema",
        "Retained evidence tar",
        "Retained evidence tar size",
        "Retained evidence tar SHA256",
        "Retained evidence disposition",
    }
    has_retained_evidence = bool(retained_evidence_labels & manifest.top_labels)
    if has_retained_evidence:
        require(
            retained_evidence_labels <= manifest.top_labels,
            "kernel release manifest has an incomplete retained-evidence record",
        )
        scalar_labels.update(retained_evidence_labels)
    dynamic_labels = {
        label
        for index in range(1, len(debs) + 1)
        for label in (f"Package {index} file", f"Package {index} SHA256")
    }
    if touchscreen_source is not None:
        scalar_labels.update(
            {
                "Touchscreen source archive",
                "Touchscreen source archive SHA256",
                "Touchscreen source commit",
                "Touchscreen source modules tree ID",
                "Touchscreen source license blob ID",
                "Touchscreen kernel config SHA256",
                "Touchscreen kernel Module.symvers SHA256",
                "Touchscreen kernel headers input mode",
                "Touchscreen kernel common headers Deb",
                "Touchscreen kernel common headers Deb SHA256",
                "Touchscreen kernel architecture headers Deb",
                "Touchscreen kernel architecture headers Deb SHA256",
            }
        )
        dynamic_labels.update(f"Touchscreen module {name} SHA256" for name in MODULE_NAMES)
    ordered_labels = [
        "Generated",
        "Release",
        "Kernel release schema",
        "Build provenance schema",
        "Release build",
        "Build completed",
        "Kernel build manifest asset",
        "Kernel build manifest size",
        "Kernel build manifest SHA256",
        "APT provenance asset",
        "APT provenance schema",
        "APT provenance size",
        "APT provenance SHA256",
        "APT snapshot ID",
        "APT snapshot URI",
        "Build inputs asset",
        "Build inputs schema",
        "Build inputs size",
        "Build inputs SHA256",
        "Build envelope creation propagation",
        "Kernel release propagation",
    ]
    if has_retained_evidence:
        ordered_labels.extend(
            (
                "Retained evidence schema",
                "Retained evidence tar",
                "Retained evidence tar size",
                "Retained evidence tar SHA256",
                "Retained evidence disposition",
            )
        )
    ordered_labels.extend(
        [
        "OCI index image",
        "OCI index digest",
        "OCI platform",
        "OCI platform manifest",
        "Publication state",
        "Support repo commit",
        "Support repo dirty",
        "Source mode",
        "Source URL",
        "Source branch",
        "Source HEAD",
        "Docker image",
        "Container digest",
        "Container platform",
        "Build target",
        "Jobs",
        "Rules runner",
        "Patched diff format",
        "Patched diff Git version",
        "Patched diff SHA256",
        "Patched tree ID",
        "Required output roles",
        "Optional output roles",
        "Required package roles",
        "Optional package roles",
        "Module signing policy",
        "Module signing private material retained",
        "Signing certificate SHA256",
        "Signing certificate fingerprint",
        "Signing certificate serial",
        "Kernel module signature report asset",
        "Kernel module signature report size",
        "Kernel module signature report SHA256",
        "Kernel module signature report schema",
        "Kernel module total count",
        "Kernel module verified signed count",
        "Kernel module policy-allowed unsigned count",
        "Kernel module unsigned-path inventory SHA256",
        "Package count",
        ]
    )
    for index in range(1, len(debs) + 1):
        ordered_labels.extend((f"Package {index} file", f"Package {index} SHA256"))
    ordered_labels.extend(
        ("Kernel source archive", "Kernel source archive SHA256", "Kernel source tree ID")
    )
    if touchscreen_source is not None:
        ordered_labels.extend(
            (
                "Touchscreen source archive",
                "Touchscreen source archive SHA256",
                "Touchscreen source commit",
                "Touchscreen source modules tree ID",
                "Touchscreen source license blob ID",
                "Touchscreen kernel config SHA256",
                "Touchscreen kernel Module.symvers SHA256",
                "Touchscreen kernel headers input mode",
                "Touchscreen kernel common headers Deb",
                "Touchscreen kernel common headers Deb SHA256",
                "Touchscreen kernel architecture headers Deb",
                "Touchscreen kernel architecture headers Deb SHA256",
            )
        )
        ordered_labels.extend(f"Touchscreen module {name} SHA256" for name in MODULE_NAMES)
    require(
        set(ordered_labels) == scalar_labels | dynamic_labels,
        "internal kernel release schema order is incomplete",
    )
    manifest.exact_flat_label_order(ordered_labels)
    require(bool(ISO_UTC.fullmatch(manifest.one("Generated"))), "invalid kernel release timestamp")
    kernel_release_name = manifest.one("Release")
    require(
        bool(SAFE_NAME.fullmatch(kernel_release_name))
        and not kernel_release_name.startswith(".")
        and ".." not in kernel_release_name,
        "kernel release manifest has an unsafe release identity",
    )
    comparisons = {
        "Kernel release schema": "sp11-kernel-release-v1",
        "Build provenance schema": "sp11-kernel-build-v2",
        "Release build": "true",
        "Build completed": "true",
        "Support repo commit": str(build["support"]),
        "Support repo dirty": "false",
        "Source mode": "git",
        "Source URL": str(build["source_url"]),
        "Source branch": str(build["source_ref"]),
        "Source HEAD": str(build["source_head"]),
        "Docker image": str(build["container_image"]),
        "Container digest": str(build["container_digest"]),
        "Container platform": str(build["platform"]),
        "Build target": str(build["target"]),
        "Jobs": str(build["jobs"]),
        "Rules runner": str(build["runner"]),
        "Patched diff format": str(build["diff_format"]),
        "Patched diff Git version": str(build["diff_git"]),
        "Patched diff SHA256": str(build["diff_sha"]),
        "Patched tree ID": str(build["tree"]),
        "Required output roles": str(build["required_outputs"]),
        "Optional output roles": str(build["optional_outputs"]),
        "Required package roles": str(build["required_debs"]),
        "Optional package roles": str(build["optional_debs"]),
        "Module signing policy": str(build["module_signing_policy"]),
        "Module signing private material retained": str(
            build["module_signing_private_material_retained"]
        ),
        "Signing certificate SHA256": str(build["certificate_sha"]),
        "Signing certificate fingerprint": str(build["certificate_fingerprint"]),
        "Signing certificate serial": str(build["certificate_serial"]),
        "Kernel source archive": kernel_source.name,
        "Kernel source archive SHA256": sha256_file(kernel_source),
        "Kernel source tree ID": str(build["tree"]),
        "Kernel build manifest asset": build_manifest.name,
        "Kernel build manifest size": attached["build_manifest_size"],
        "Kernel build manifest SHA256": attached["build_manifest_sha"],
        "APT provenance asset": apt_provenance.name,
        "APT provenance schema": attached["apt_schema"],
        "APT provenance size": attached["apt_size"],
        "APT provenance SHA256": attached["apt_sha"],
        "APT snapshot ID": attached["snapshot_id"],
        "APT snapshot URI": attached["snapshot_uri"],
        "Build inputs asset": build_inputs.name,
        "Build inputs schema": attached["build_inputs_schema"],
        "Build inputs size": attached["build_inputs_size"],
        "Build inputs SHA256": attached["build_inputs_sha"],
        "Build envelope creation propagation": attached["creation_propagation"],
        "Kernel release propagation": "complete",
        "OCI index image": attached["oci_image"],
        "OCI index digest": attached["oci_digest"],
        "OCI platform": attached["oci_platform"],
        "OCI platform manifest": attached["oci_platform_manifest"],
        "Publication state": "blocked",
    }
    signature_report = build["kernel_signature_report"]
    assert isinstance(signature_report, dict)
    comparisons.update(
        {
            "Kernel module signature report asset": str(signature_report["asset"]),
            "Kernel module signature report size": str(signature_report["size"]),
            "Kernel module signature report SHA256": str(signature_report["sha"]),
            "Kernel module signature report schema": str(signature_report["schema"]),
            "Kernel module total count": str(signature_report["total"]),
            "Kernel module verified signed count": str(signature_report["signed"]),
            "Kernel module policy-allowed unsigned count": str(signature_report["unsigned"]),
            "Kernel module unsigned-path inventory SHA256": str(
                signature_report["inventory_sha"]
            ),
        }
    )
    if has_retained_evidence:
        evidence_size = manifest.one("Retained evidence tar size")
        evidence_sha = manifest.one("Retained evidence tar SHA256")
        require(
            evidence_size.isdigit()
            and int(evidence_size, 10) > 0
            and bool(SHA256.fullmatch(evidence_sha)),
            "kernel release retained-evidence fingerprint is invalid",
        )
        comparisons.update(
            {
                "Retained evidence schema": "sp11-kernel-retained-evidence-v1",
                "Retained evidence tar": "sp11-kernel-retained-evidence.tar",
                "Retained evidence disposition": "local-validation-input",
            }
        )
        if retained_evidence is not None:
            regular_input(retained_evidence, "retained release evidence tar")
            comparisons.update(
                {
                    "Retained evidence tar size": str(retained_evidence.stat().st_size),
                    "Retained evidence tar SHA256": sha256_file(retained_evidence),
                }
            )
    if touchscreen_source is not None:
        comparisons.update(
            {
                "Touchscreen source archive": touchscreen_source.name,
                "Touchscreen source archive SHA256": sha256_file(touchscreen_source),
                "Touchscreen kernel config SHA256": str(build["config_sha"]),
                "Touchscreen kernel Module.symvers SHA256": str(build["symvers_sha"]),
                "Touchscreen kernel headers input mode": "extracted-debs-v1",
                "Touchscreen kernel common headers Deb": str(build["common_headers_deb"]),
                "Touchscreen kernel common headers Deb SHA256": str(build["common_headers_deb_sha"]),
                "Touchscreen kernel architecture headers Deb": str(build["headers_deb"]),
                "Touchscreen kernel architecture headers Deb SHA256": str(build["headers_deb_sha"]),
            }
        )
    for label, expected in comparisons.items():
        require(manifest.one(label) == expected, f"kernel release field does not match build: {label}")
    for index, deb in enumerate(debs, 1):
        assert isinstance(deb, dict)
        require(
            manifest.one(f"Package {index} file") == deb["path"]
            and manifest.one(f"Package {index} SHA256") == deb["sha"],
            f"kernel release package {index} differs from schema-v2 build provenance",
        )
    if touchscreen_source is None:
        return {"release_name": kernel_release_name}

    touch_commit = manifest.one("Touchscreen source commit").lower()
    touch_tree = manifest.one("Touchscreen source modules tree ID").lower()
    touch_license = manifest.one("Touchscreen source license blob ID").lower()
    require(
        bool(OID.fullmatch(touch_commit))
        and bool(OID.fullmatch(touch_tree))
        and bool(OID.fullmatch(touch_license))
        and len({len(touch_commit), len(touch_tree), len(touch_license)}) == 1,
        "kernel release touchscreen source object identities are invalid",
    )
    module_shas: dict[str, str] = {}
    for name in MODULE_NAMES:
        module_sha = manifest.one(f"Touchscreen module {name} SHA256")
        require(bool(SHA256.fullmatch(module_sha)), f"invalid kernel release module hash: {name}")
        module_shas[name] = module_sha
    return {
        "release_name": kernel_release_name,
        "touch_commit": touch_commit,
        "touch_tree": touch_tree,
        "touch_license": touch_license,
        **{f"module:{name}": value for name, value in module_shas.items()},
    }


def validate_module(
    manifest: Manifest,
    build: dict[str, object],
    release: dict[str, str],
    support_commit: str,
) -> dict[str, str]:
    scalar_labels = {
        "Generated",
        "Release",
        "Kernel ABI",
        "Touchscreen source URL",
        "Touchscreen source commit",
        "Source archive contract",
        "Source object format",
        "Source modules path",
        "Source modules tree ID",
        "Source license path",
        "Source license mode",
        "Source license blob ID",
        "Kernel config SHA256",
        "Kernel Module.symvers SHA256",
        "Kernel headers input mode",
        "Kernel common headers Deb",
        "Kernel common headers Deb SHA256",
        "Kernel architecture headers Deb",
        "Kernel architecture headers Deb SHA256",
        "Module compiler identity",
        "Module linker identity",
        "Module make identity",
        "Support repo commit",
        "Support repo dirty",
        "Module signing policy",
        "Module signing private material retained",
        "Module signing hash algorithm",
        "Module signing certificate asset",
        "Module signing certificate SHA256",
        "Module signing certificate fingerprint",
        "Module signing certificate serial",
        "Required SPI parameter",
    }
    for name in MODULE_NAMES:
        scalar_labels.update(
            {
                f"Module {name} name",
                f"Module {name} size",
                f"Module {name} SHA256",
                f"Module {name} payload size",
                f"Module {name} payload SHA256",
                f"Module {name} signature size",
                f"Module {name} signature SHA256",
                f"Module {name} vermagic",
                f"Module {name} srcversion",
            }
        )
    manifest.exact_flat_labels(scalar_labels)
    require(bool(ISO_UTC.fullmatch(manifest.one("Generated"))), "invalid module release timestamp")
    object_format = manifest.one("Source object format")
    touch_commit = manifest.one("Touchscreen source commit").lower()
    touch_tree = manifest.one("Source modules tree ID").lower()
    touch_license = manifest.one("Source license blob ID").lower()
    required_length = 40 if object_format == "sha1" else 64 if object_format == "sha256" else 0
    require(
        required_length > 0
        and all(bool(OID.fullmatch(value)) and len(value) == required_length for value in (
            touch_commit,
            touch_tree,
            touch_license,
        )),
        "module manifest source object format and identities disagree",
    )
    comparisons = {
        "Release": release["release_name"],
        "Kernel ABI": str(build["abi"]),
        "Touchscreen source commit": release["touch_commit"],
        "Source archive contract": "sp11-touchscreen-source-v1",
        "Source modules path": "phase55/modules",
        "Source modules tree ID": release["touch_tree"],
        "Source license path": "LICENSE",
        "Source license mode": "100644",
        "Source license blob ID": release["touch_license"],
        "Kernel config SHA256": str(build["config_sha"]),
        "Kernel Module.symvers SHA256": str(build["symvers_sha"]),
        "Kernel headers input mode": "extracted-debs-v1",
        "Kernel common headers Deb": str(build["common_headers_deb"]),
        "Kernel common headers Deb SHA256": str(build["common_headers_deb_sha"]),
        "Kernel architecture headers Deb": str(build["headers_deb"]),
        "Kernel architecture headers Deb SHA256": str(build["headers_deb_sha"]),
        "Support repo commit": support_commit,
        "Support repo dirty": "false",
        "Module signing policy": str(build["module_signing_policy"]),
        "Module signing private material retained": str(
            build["module_signing_private_material_retained"]
        ),
        "Module signing hash algorithm": "sha512",
        "Module signing certificate asset": MODULE_SIGNING_CERTIFICATE,
        "Module signing certificate SHA256": str(build["certificate_sha"]),
        "Module signing certificate fingerprint": str(build["certificate_fingerprint"]),
        "Module signing certificate serial": str(build["certificate_serial"]),
        "Required SPI parameter": "sp11_windows_se_init",
    }
    for label, expected in comparisons.items():
        require(manifest.one(label) == expected, f"module release field does not match: {label}")
    require(
        public_https_url(manifest.one("Touchscreen source URL")),
        "module source URL is not credential-free public HTTPS",
    )
    for label in ("Module compiler identity", "Module linker identity", "Module make identity"):
        require(bool(PRINTABLE.fullmatch(manifest.one(label))), f"unsafe or missing {label}")

    certificate_path = manifest.path.with_name(MODULE_SIGNING_CERTIFICATE)
    regular_input(certificate_path, "touchscreen module-signing certificate")
    certificate_sha = sha256_file(certificate_path)
    certificate_fingerprint = ":".join(
        certificate_sha.upper()[index : index + 2] for index in range(0, 64, 2)
    )
    require(
        certificate_sha == manifest.one("Module signing certificate SHA256")
        and certificate_fingerprint
        == manifest.one("Module signing certificate fingerprint")
        and bool(SERIAL.fullmatch(manifest.one("Module signing certificate serial"))),
        "touchscreen module-signing certificate asset does not match its manifest identity",
    )

    module_shas: dict[str, str] = {}
    for name, expected_name in MODULE_NAMES.items():
        flat_sha = manifest.one(f"Module {name} SHA256")
        module_name = manifest.one(f"Module {name} name")
        module_size = manifest.one(f"Module {name} size")
        module_payload_size = manifest.one(f"Module {name} payload size")
        module_payload_sha = manifest.one(f"Module {name} payload SHA256")
        module_signature_size = manifest.one(f"Module {name} signature size")
        module_signature_sha = manifest.one(f"Module {name} signature SHA256")
        module_vermagic = manifest.one(f"Module {name} vermagic")
        module_srcversion = manifest.one(f"Module {name} srcversion")
        require(
            bool(SHA256.fullmatch(flat_sha))
            and flat_sha == release[f"module:{name}"],
            f"module hash differs between kernel and module release manifests: {name}",
        )
        require(
            module_name == expected_name
            and bool(POSITIVE.fullmatch(module_size))
            and bool(POSITIVE.fullmatch(module_payload_size))
            and bool(SHA256.fullmatch(module_payload_sha))
            and bool(POSITIVE.fullmatch(module_signature_size))
            and bool(SHA256.fullmatch(module_signature_sha))
            and int(module_payload_size, 10) < int(module_size, 10)
            and int(module_signature_size, 10) < int(module_size, 10)
            and module_vermagic.split(" ", 1)[0] == str(build["abi"])
            and bool(re.fullmatch(r"[0-9A-Fa-f]+", module_srcversion)),
            f"module detail identity is incomplete or inconsistent: {name}",
        )
        module_shas[name] = flat_sha
    return module_shas


def write_expected_payload(
    path: Path,
    build: dict[str, object],
    module_shas: dict[str, str] | None = None,
    module_manifest: Path | None = None,
) -> None:
    debs = build["debs"]
    assert isinstance(debs, list)
    lines = []
    for deb in debs:
        assert isinstance(deb, dict)
        lines.append(f"{deb['sha']}  {deb['path']}\n")
    if module_shas is not None or module_manifest is not None:
        require(
            module_shas is not None and module_manifest is not None,
            "module payload identity inputs are incomplete",
        )
        assert module_shas is not None
        assert module_manifest is not None
        for name in MODULE_NAMES:
            lines.append(f"{module_shas[name]}  {name}\n")
        certificate_path = module_manifest.with_name(MODULE_SIGNING_CERTIFICATE)
        regular_input(certificate_path, "touchscreen module-signing certificate")
        lines.append(f"{sha256_file(certificate_path)}  {MODULE_SIGNING_CERTIFICATE}\n")
        lines.append(f"{sha256_file(module_manifest)}  {module_manifest.name}\n")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            output.writelines(lines)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except OSError as exc:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise ValidationError(f"could not write expected payload identities: {exc}") from exc


def regular_input(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ValidationError(f"missing {label}: {path.name}") from exc
    require(
        path.is_file() and not path.is_symlink() and metadata.st_size > 0,
        f"{label} must be a non-empty regular, non-symlinked file",
    )


def require_fixed_build_only_git() -> None:
    try:
        metadata = os.lstat(FIXED_BUILD_ONLY_GIT)
    except OSError as exc:
        raise ValidationError(f"fixed build-only Git executable is unavailable: {exc}") from exc
    require(
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == 0
        and stat.S_IMODE(metadata.st_mode) & 0o111 != 0
        and stat.S_IMODE(metadata.st_mode) & 0o022 == 0,
        "fixed build-only Git executable has an unsafe identity or mode",
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-dir", required=True, type=Path)
    parser.add_argument("--support-commit", required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--build-only", action="store_true")
    mode.add_argument("--kernel-release-only", action="store_true")
    parser.add_argument("--require-current-head", action="store_true")
    parser.add_argument("--release-name")
    parser.add_argument("--kernel-build-manifest", required=True, type=Path)
    parser.add_argument("--kernel-release-manifest", type=Path)
    parser.add_argument("--apt-provenance", type=Path)
    parser.add_argument("--build-inputs", type=Path)
    parser.add_argument("--touchscreen-module-manifest", type=Path)
    parser.add_argument("--kernel-source", type=Path)
    parser.add_argument("--retained-evidence", type=Path)
    parser.add_argument("--touchscreen-source", type=Path)
    parser.add_argument("--expected-payload-out", type=Path)
    parser.add_argument("--no-expected-payload-output", action="store_true")
    return parser.parse_args()


def main() -> int:
    global GIT_EXECUTABLE

    require(
        sys.flags.isolated == 1,
        "manifest validation requires isolated Python startup",
    )
    establish_child_wait_authority()
    args = parse_arguments()
    if args.build_only:
        require_fixed_build_only_git()
        GIT_EXECUTABLE = FIXED_BUILD_ONLY_GIT
    support_commit = args.support_commit.lower()
    require(bool(OID.fullmatch(support_commit)), "support commit is not an exact Git object ID")
    regular_input(args.kernel_build_manifest, "kernel build manifest")
    if args.require_current_head:
        resolved_head = run_git(args.repo_dir, ["rev-parse", "--verify", "HEAD^{commit}"])
        require(
            resolved_head == support_commit,
            "support commit does not match current repository HEAD",
        )
    else:
        resolved_commit = run_git(
            args.repo_dir, ["rev-parse", "--verify", f"{support_commit}^{{commit}}"]
        )
        require(
            resolved_commit == support_commit,
            "support commit is not available in the repository",
        )
    build = validate_build(Manifest(args.kernel_build_manifest), args.repo_dir, support_commit)
    if args.build_only:
        print("Validated complete schema-v2 kernel build manifest.")
        return 0

    immutable_paths = (
        (args.apt_provenance, "APT provenance sidecar"),
        (args.build_inputs, "build-inputs envelope"),
    )
    for path, label in immutable_paths:
        require(path is not None, f"{label} is required")
        assert path is not None
        regular_input(path, label)
    assert args.apt_provenance is not None
    assert args.build_inputs is not None
    attached = validate_attached_build_inputs(
        args.repo_dir,
        support_commit,
        args.kernel_build_manifest,
        args.apt_provenance,
        args.build_inputs,
    )
    require(
        attached["oci_image"] == str(build["container_image"])
        and attached["oci_digest"] == str(build["container_digest"])
        and attached["oci_platform"] == str(build["platform"]),
        "attached build-inputs OCI identity differs from the build manifest",
    )

    if args.kernel_release_only:
        required_paths = (
            (args.kernel_release_manifest, "kernel release manifest"),
            (args.kernel_source, "kernel source archive"),
        )
        for path, label in required_paths:
            require(path is not None, f"{label} is required")
            assert path is not None
            regular_input(path, label)
        require(
            (args.expected_payload_out is not None) != args.no_expected_payload_output,
            "choose exactly one expected-payload output mode",
        )
        assert args.kernel_release_manifest is not None
        assert args.kernel_source is not None
        validate_release(
            Manifest(args.kernel_release_manifest),
            build,
            attached,
            args.kernel_build_manifest,
            args.apt_provenance,
            args.build_inputs,
            args.kernel_source,
            None,
            args.retained_evidence,
        )
        if args.expected_payload_out is not None:
            write_expected_payload(args.expected_payload_out, build)
        print("Validated complete schema-v2 kernel release manifest bindings.")
        return 0

    require(args.release_name is not None, "image release name is required")
    require(
        bool(SAFE_NAME.fullmatch(args.release_name))
        and not args.release_name.startswith(".")
        and ".." not in args.release_name,
        "image release name is unsafe",
    )
    required_paths = (
        (args.kernel_release_manifest, "kernel release manifest"),
        (args.touchscreen_module_manifest, "touchscreen module manifest"),
        (args.kernel_source, "kernel source archive"),
        (args.touchscreen_source, "touchscreen source archive"),
    )
    for path, label in required_paths:
        require(path is not None, f"{label} is required")
        assert path is not None
        regular_input(path, label)
    require(
        (args.expected_payload_out is not None) != args.no_expected_payload_output,
        "choose exactly one expected-payload output mode",
    )
    assert args.kernel_release_manifest is not None
    assert args.touchscreen_module_manifest is not None
    assert args.kernel_source is not None
    assert args.touchscreen_source is not None
    release = validate_release(
        Manifest(args.kernel_release_manifest),
        build,
        attached,
        args.kernel_build_manifest,
        args.apt_provenance,
        args.build_inputs,
        args.kernel_source,
        args.touchscreen_source,
        args.retained_evidence,
    )
    module_shas = validate_module(
        Manifest(args.touchscreen_module_manifest),
        build,
        release,
        support_commit,
    )
    if args.expected_payload_out is not None:
        write_expected_payload(
            args.expected_payload_out,
            build,
            module_shas,
            args.touchscreen_module_manifest,
        )
    print("Validated complete schema-v2 image release manifest bindings.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
