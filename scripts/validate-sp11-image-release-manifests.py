#!/usr/bin/env python3
"""Validate the exact provenance contract used to bind an SP11 release image."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import os
import re
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


def run_git(repo: Path, arguments: list[str], *, binary: bool = False) -> bytes | str:
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


def validate_git_ref(repo: Path, source_ref: str) -> None:
    require(bool(SOURCE_REF.fullmatch(source_ref)), "build source ref is unsafe")
    run_git(repo, ["check-ref-format", f"refs/heads/{source_ref}"])


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
        "Signing certificate SHA256",
        "Signing certificate fingerprint",
        "Signing certificate serial",
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
        bool(SHA256.fullmatch(certificate_sha))
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
        "certificate_sha": certificate_sha,
        "certificate_fingerprint": manifest.one("Signing certificate fingerprint"),
        "certificate_serial": manifest.one("Signing certificate serial"),
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
    kernel_source: Path,
    touchscreen_source: Path | None,
) -> dict[str, str]:
    debs = build["debs"]
    assert isinstance(debs, list)
    package_count = manifest.one("Package count")
    require(package_count == str(len(debs)), "kernel release package count differs from build")
    scalar_labels = {
        "Generated",
        "Release",
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
        "Signing certificate SHA256",
        "Signing certificate fingerprint",
        "Signing certificate serial",
        "Package count",
        "Kernel source archive",
        "Kernel source archive SHA256",
        "Kernel source tree ID",
    }
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
    manifest.exact_flat_labels(scalar_labels | dynamic_labels)
    require(bool(ISO_UTC.fullmatch(manifest.one("Generated"))), "invalid kernel release timestamp")
    kernel_release_name = manifest.one("Release")
    require(
        bool(SAFE_NAME.fullmatch(kernel_release_name))
        and not kernel_release_name.startswith(".")
        and ".." not in kernel_release_name,
        "kernel release manifest has an unsafe release identity",
    )
    comparisons = {
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
        "Signing certificate SHA256": str(build["certificate_sha"]),
        "Signing certificate fingerprint": str(build["certificate_fingerprint"]),
        "Signing certificate serial": str(build["certificate_serial"]),
        "Kernel source archive": kernel_source.name,
        "Kernel source archive SHA256": sha256_file(kernel_source),
        "Kernel source tree ID": str(build["tree"]),
    }
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
        "Required SPI parameter",
    }
    for name in MODULE_NAMES:
        scalar_labels.update(
            {
                f"Module {name} name",
                f"Module {name} size",
                f"Module {name} SHA256",
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

    module_shas: dict[str, str] = {}
    for name, expected_name in MODULE_NAMES.items():
        flat_sha = manifest.one(f"Module {name} SHA256")
        module_name = manifest.one(f"Module {name} name")
        module_size = manifest.one(f"Module {name} size")
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
    parser.add_argument("--touchscreen-module-manifest", type=Path)
    parser.add_argument("--kernel-source", type=Path)
    parser.add_argument("--touchscreen-source", type=Path)
    parser.add_argument("--expected-payload-out", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
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

    if args.kernel_release_only:
        required_paths = (
            (args.kernel_release_manifest, "kernel release manifest"),
            (args.kernel_source, "kernel source archive"),
        )
        for path, label in required_paths:
            require(path is not None, f"{label} is required")
            assert path is not None
            regular_input(path, label)
        require(args.expected_payload_out is not None, "expected payload output is required")
        assert args.kernel_release_manifest is not None
        assert args.kernel_source is not None
        assert args.expected_payload_out is not None
        validate_release(
            Manifest(args.kernel_release_manifest),
            build,
            args.kernel_source,
            None,
        )
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
    require(args.expected_payload_out is not None, "expected payload output is required")
    assert args.kernel_release_manifest is not None
    assert args.touchscreen_module_manifest is not None
    assert args.kernel_source is not None
    assert args.touchscreen_source is not None
    assert args.expected_payload_out is not None
    release = validate_release(
        Manifest(args.kernel_release_manifest),
        build,
        args.kernel_source,
        args.touchscreen_source,
    )
    module_shas = validate_module(
        Manifest(args.touchscreen_module_manifest),
        build,
        release,
        support_commit,
    )
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
