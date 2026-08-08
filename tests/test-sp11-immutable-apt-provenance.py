#!/usr/bin/env python3
"""Hostile fixtures for immutable APT acquisition and provenance binding."""

from __future__ import annotations

import gzip
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace


REPO = Path(__file__).resolve().parents[1]
APT_HELPER = REPO / "scripts/sp11-immutable-apt.sh"
WRITER = REPO / "scripts/write-sp11-apt-provenance.py"
ENVELOPE = REPO / "scripts/sp11-kernel-build-inputs.py"
OCI_VALIDATOR = REPO / "scripts/validate-sp11-oci-index.py"
DOCKER_WRAPPER = REPO / "scripts/build-sp11-qcom-x1e-kernel-docker.sh"
INNER_BUILDER = REPO / "scripts/build-sp11-qcom-x1e-kernel.sh"
BASELINE_VALIDATOR = REPO / "scripts/validate-sp11-kernel-baseline.sh"
SUITES = ("resolute", "resolute-updates", "resolute-backports", "resolute-security")
COMPONENTS = ("main", "universe", "restricted", "multiverse")
FINGERPRINT = "F6ECB3762474EDA9D21B7022871920D1991BC93C"
SUPPORT_HEAD = subprocess.run(
    ["git", "-C", str(REPO), "rev-parse", "--verify", "HEAD^{commit}"],
    check=True,
    stdout=subprocess.PIPE,
    text=True,
).stdout.strip()
SOURCE_HEAD = "b" * 40
CHILD_DIGEST = "sha256:" + "c" * 64
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
EMPTY_INDEX_PATHS = (
    "resolute-backports/main/binary-arm64/Packages.gz",
    "resolute-backports/main/source/Sources.gz",
    "resolute-backports/restricted/binary-arm64/Packages.gz",
    "resolute-backports/restricted/source/Sources.gz",
    "resolute-backports/multiverse/binary-arm64/Packages.gz",
    "resolute-backports/multiverse/source/Sources.gz",
)
EMPTY_GZIP_HEX = "1f8b08000000000002ff03000000000000000000"
EMPTY_GZIP = bytes.fromhex(EMPTY_GZIP_HEX)
EMPTY_GZIP_SHA256 = "9ceffb7310338057cfe71a4ae1e2c98d2c485d81cdef906532a801f457a38d64"
assert EMPTY_GZIP.hex() == EMPTY_GZIP_HEX
assert len(EMPTY_GZIP) == 20
assert hashlib.sha256(EMPTY_GZIP).hexdigest() == EMPTY_GZIP_SHA256
CREATED_FIXTURES: list[Path] = []


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fixture_gzip(data: bytes) -> bytes:
    return EMPTY_GZIP if not data else gzip.compress(data, mtime=0)


def write_exact_build_manifest(fixture: "Fixture", path: Path) -> None:
    patch_path = "patches/jglathe-qcom-x1e-7.2-rc5/0001-debian-qcom-x1e-update-annotations-for-7.2-rc5-jg-0.patch"
    patch_bytes = subprocess.run(
        ["git", "-C", str(REPO), "show", f"{SUPPORT_HEAD}:{patch_path}"],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    image_digest = "sha256:" + digest(fixture.oci_raw)
    output_rows = (
        ("kernel-config", "debian/build/build-qcom-x1e/.config"),
        ("module-symvers", "debian/build/build-qcom-x1e/Module.symvers"),
        ("system-map", "debian/build/build-qcom-x1e/System.map"),
        ("kernel-efi-stubble", "debian/build/build-qcom-x1e/arch/arm64/boot/vmlinuz.efi.stubble"),
        ("denali-oled-dtb", "debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled.dtb"),
        ("denali-oled-el2-dtb", "debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled-el2.dtb"),
        ("module-signing-certificate", "debian/build/build-qcom-x1e/certs/signing_key.x509"),
    )
    deb_rows = (
        ("common-headers", "linux-qcom-x1e-headers-7.2.0-1", "all"),
        ("headers", "linux-headers-7.2.0-1-qcom-x1e", "arm64"),
        ("image", "linux-image-7.2.0-1-qcom-x1e", "arm64"),
        ("modules", "linux-modules-7.2.0-1-qcom-x1e", "arm64"),
    )
    lines = [
        "Provenance schema: sp11-kernel-build-v2",
        "Release build: true",
        f"Support start HEAD: {SUPPORT_HEAD}",
        "Support start dirty: false",
        f"Support end HEAD: {SUPPORT_HEAD}",
        "Support end dirty: false",
        "Source mode: git",
        "Source URL: https://github.com/example/linux.git",
        "Source ref: fixture/ref",
        f"Expected source commit: {SOURCE_HEAD}",
        f"Source HEAD: {SOURCE_HEAD}",
        f"Container image: ubuntu:26.04@{image_digest}",
        f"Container digest: {image_digest}",
        "Container platform: linux/arm64/v8",
        "Build target: binary-indep binary-qcom-x1e",
        "Jobs: 1",
        "Rules runner: direct-root",
        "Patch count: 1",
        f"Patch 1 path: {patch_path}",
        f"Patch 1 SHA256: {digest(patch_bytes)}",
        "Patch 1 disposition: applied",
        "Patched diff format: git-diff-full-index-binary-v1",
        "Patched diff Git version: git version fixture",
        f"Patched diff SHA256: {'d' * 64}",
        f"Patched tree ID: {SOURCE_HEAD}",
        "Required output roles: kernel-config module-symvers system-map kernel-efi-stubble denali-oled-dtb denali-oled-el2-dtb module-signing-certificate",
        "Optional output roles: none",
        f"Output count: {len(output_rows)}",
    ]
    for index, (role, output_path) in enumerate(output_rows, 1):
        output_hash = f"{index:x}" * 64
        lines.extend(
            (
                f"Output {index} role: {role}",
                f"Output {index} required: true",
                f"Output {index} path: {output_path}",
                f"Output {index} size: {index}",
                f"Output {index} SHA256: {output_hash}",
            )
        )
    certificate_hash = f"{len(output_rows):x}" * 64
    lines.extend(
        (
            f"Signing certificate SHA256: {certificate_hash}",
            "Signing certificate fingerprint: " + ":".join(["AA"] * 32),
            "Signing certificate serial: 01",
            "Required Deb roles: common-headers headers image modules",
            "Optional Deb roles: modules-extra",
            f"Deb count: {len(deb_rows)}",
        )
    )
    for index, (role, package, architecture) in enumerate(deb_rows, 1):
        version = "7.2.0-1"
        deb_hash = f"{index + 7:x}" * 64
        lines.extend(
            (
                f"Deb {index} role: {role}",
                "Deb %d required: true" % index,
                f"Deb {index} path: {package}_{version}_{architecture}.deb",
                f"Deb {index} package: {package}",
                f"Deb {index} version: {version}",
                f"Deb {index} architecture: {architecture}",
                f"Deb {index} size: {index}",
                f"Deb {index} SHA256: {deb_hash}",
            )
        )
    lines.append("Build completed: true")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run(command: list[str], env: dict[str, str], expect: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if (result.returncode == 0) != expect:
        print(result.stdout, end="", file=sys.stderr)
        print(result.stderr, end="", file=sys.stderr)
        raise AssertionError(
            f"unexpected exit {result.returncode} for {' '.join(command)}"
        )
    return result


class Fixture:
    def __init__(self, parent: Path) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="sp11-apt-fixture.", dir=parent))
        CREATED_FIXTURES.append(self.root)
        self.work = self.root / "work"
        self.archives = self.work / "apt-archives"
        self.index_cache = self.work / "apt-indexes"
        self.retained_lists = self.work / "apt-lists"
        self.artifacts = self.work / "artifacts"
        self.kernel_work = self.root / "kernel-work"
        self.lists = self.root / "var/lib/apt/lists"
        self.keyring = self.root / "usr/share/keyrings/ubuntu-archive-keyring.gpg"
        self.source_lists = self.root / "fixture-list-source"
        self.source_indexes = self.root / "fixture-index-source"
        self.mock_bin = self.root / "mock-bin"
        self.tool_bin = self.root / "tool-bin"
        self.deb_fields = self.root / "deb-fields.tsv"
        self.call_log = self.root / "call.log"
        self.python_source = self.root / "python3-fixture"
        self.python_install_marker = self.root / "python-package-installed"
        for directory in (
            self.archives,
            self.index_cache,
            self.retained_lists,
            self.artifacts,
            self.kernel_work,
            self.lists,
            self.keyring.parent,
            self.root / "etc/apt/sources.list.d",
            self.root / "etc/apt/apt.conf.d",
            self.root / "etc/ssl/certs",
            self.source_lists,
            self.source_indexes,
            self.mock_bin,
            self.tool_bin,
        ):
            directory.mkdir(parents=True, exist_ok=True)
        for tool in (
            "awk",
            "bash",
            "basename",
            "cat",
            "chmod",
            "cp",
            "dirname",
            "find",
            "git",
            "grep",
            "id",
            "mkdir",
            "mktemp",
            "mv",
            "rm",
            "sort",
            "stat",
            "tr",
            "uname",
            "wc",
        ):
            tool_path = shutil.which(tool)
            if tool_path is None:
                raise AssertionError(f"fixture host is missing required tool: {tool}")
            (self.tool_bin / tool).symlink_to(tool_path)
        self.keyring.write_bytes(b"fixture Ubuntu archive keyring\n")
        self.call_log.write_text("", encoding="utf-8")
        (self.root / "etc/apt/sources.list").write_text(
            "deb https://mutable.invalid/ubuntu resolute main\n", encoding="utf-8"
        )
        (self.root / "etc/apt/sources.list.d/mutable.list").write_text(
            "deb https://mutable.invalid/ubuntu resolute universe\n", encoding="utf-8"
        )
        self.debs = (
            ("ca-certificates_1_arm64.deb", "ca-certificates", "1", "arm64"),
            ("openssl_1_arm64.deb", "openssl", "1", "arm64"),
            ("libssl3t64_1_arm64.deb", "libssl3t64", "1", "arm64"),
            ("openssl-provider-legacy_1_arm64.deb", "openssl-provider-legacy", "1", "arm64"),
        )
        self.python_deb = ("python3_1_arm64.deb", "python3", "1", "arm64")
        self.deb_bytes: dict[str, bytes] = {
            name: f"fixture Deb {package}\n".encode()
            for name, package, _version, _arch in (*self.debs, self.python_deb)
        }
        self.local_name = "linux-qcom-x1e-build-deps_1.0_arm64.deb"
        self.local_bytes = b"local generated build-deps Deb\n"
        self.oci_raw = json.dumps(
            {
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "manifests": [
                    {
                        "mediaType": "application/vnd.oci.image.manifest.v1+json",
                        "digest": CHILD_DIGEST,
                        "size": 123,
                        "platform": {
                            "os": "linux",
                            "architecture": "arm64",
                            "variant": "v8",
                        },
                    }
                ],
            },
            separators=(",", ":"),
        ).encode()
        self.index_raw: dict[tuple[str, str], bytes] = {}
        self.inrelease_hashes: dict[str, str] = {}
        self._write_deb_fields()
        self._initialize_index_content()
        self.rebuild_metadata()
        self.write_baseline()
        self._write_mocks()

    def _write_deb_fields(self) -> None:
        rows = [
            f"{name}\t{package}\t{version}\t{arch}"
            for name, package, version, arch in (*self.debs, self.python_deb)
        ]
        rows.extend(
            (
                f"{self.local_name}\tlinux-qcom-x1e-build-deps\t1.0\tarm64",
                "evil_1_arm64.deb\tevil\t1\tarm64",
            )
        )
        self.deb_fields.write_text("\n".join(rows) + "\n", encoding="utf-8")

    def package_record(self, name: str, package: str, version: str, arch: str, data: bytes) -> bytes:
        return (
            f"Package: {package}\n"
            f"Version: {version}\n"
            f"Architecture: {arch}\n"
            f"Size: {len(data)}\n"
            f"SHA256: {digest(data)}\n"
            f"Filename: pool/main/f/{package}/{name}\n\n"
        ).encode()

    def _initialize_index_content(self) -> None:
        for suite in SUITES:
            for component in COMPONENTS:
                packages = b""
                if suite == "resolute" and component == "main":
                    packages = b"".join(
                        self.package_record(name, package, version, arch, self.deb_bytes[name])
                        for name, package, version, arch in (*self.debs, self.python_deb)
                    )
                else:
                    marker = f"fixture-{suite}-{component}"
                    data = marker.encode()
                    packages = self.package_record(
                        f"{marker}_1_arm64.deb", marker, "1", "arm64", data
                    )
                self.index_raw[(suite, f"{component}/binary-arm64/Packages.gz")] = packages
                self.index_raw[(suite, f"{component}/source/Sources.gz")] = (
                    f"Package: source-{suite}-{component}\nVersion: 1\n\n"
                ).encode()
        for full_path in EMPTY_INDEX_PATHS:
            suite, relative = full_path.split("/", 1)
            self.index_raw[(suite, relative)] = b""

    def inrelease_bytes(self, suite: str) -> bytes:
        lines = [
            "-----BEGIN PGP SIGNED MESSAGE-----",
            "Hash: SHA512",
            "",
            "Origin: Ubuntu",
            f"Suite: {suite}",
            "Codename: resolute",
            "Architectures: amd64 arm64",
            "SHA256:",
            f" {EMPTY_SHA256} 0 main/debian-installer/binary-arm64/Packages",
        ]
        for component in COMPONENTS:
            for relative in (
                f"{component}/binary-arm64/Packages.gz",
                f"{component}/source/Sources.gz",
            ):
                compressed = fixture_gzip(self.index_raw[(suite, relative)])
                lines.append(f" {digest(compressed)} {len(compressed)} {relative}")
        lines.extend(
            (
                "Acquire-By-Hash: yes",
                "-----BEGIN PGP SIGNATURE-----",
                "fixture",
                "-----END PGP SIGNATURE-----",
            )
        )
        return ("\n".join(lines) + "\n").encode()

    def rebuild_metadata(self) -> None:
        shutil.rmtree(self.source_lists)
        shutil.rmtree(self.source_indexes)
        self.source_lists.mkdir()
        self.source_indexes.mkdir()
        (self.source_lists / "lock").write_bytes(b"")
        self.inrelease_hashes = {}
        for suite in SUITES:
            inrelease = self.inrelease_bytes(suite)
            self.inrelease_hashes[suite] = digest(inrelease)
            (self.source_lists / f"snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_{suite}_InRelease").write_bytes(inrelease)
            for component in COMPONENTS:
                for relative in (
                    f"{component}/binary-arm64/Packages.gz",
                    f"{component}/source/Sources.gz",
                ):
                    raw = self.index_raw[(suite, relative)]
                    compressed = fixture_gzip(raw)
                    compressed_digest = digest(compressed)
                    (self.source_indexes / compressed_digest).write_bytes(compressed)
                    list_name = (
                        f"snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_{suite}_"
                        f"{relative[:-3].replace('/', '_')}.lz4"
                    )
                    if f"{suite}/{relative}" not in EMPTY_INDEX_PATHS:
                        (self.source_lists / list_name).write_bytes(raw)

    def write_baseline(self) -> None:
        image_digest = "sha256:" + digest(self.oci_raw)
        lines = [
            'SP11_KERNEL_BASELINE_ID="fixture"',
            'SP11_KERNEL_UPSTREAM_URL="https://github.com/example/linux.git"',
            'SP11_KERNEL_UPSTREAM_REF="fixture/ref"',
            f'SP11_KERNEL_UPSTREAM_COMMIT="{SOURCE_HEAD}"',
            f'SP11_KERNEL_DOCKER_IMAGE="ubuntu:26.04@{image_digest}"',
            'SP11_KERNEL_DOCKER_PLATFORM="linux/arm64/v8"',
            f'SP11_KERNEL_DOCKER_PLATFORM_MANIFEST="{CHILD_DIGEST}"',
            'SP11_KERNEL_BUILD_TARGET="binary-indep binary-qcom-x1e"',
            'SP11_APT_SNAPSHOT_ID="20260807T000000Z"',
            'SP11_APT_SNAPSHOT_URI="https://snapshot.ubuntu.com/ubuntu/20260807T000000Z/"',
            'SP11_APT_SNAPSHOT_SUITES="resolute resolute-updates resolute-backports resolute-security"',
            'SP11_APT_SNAPSHOT_COMPONENTS="main universe restricted multiverse"',
            'SP11_APT_SNAPSHOT_ARCHITECTURE="arm64"',
            f'SP11_APT_ARCHIVE_KEYRING_SHA256="{digest(self.keyring.read_bytes())}"',
            f'SP11_APT_ARCHIVE_SIGNING_FINGERPRINT="{FINGERPRINT}"',
            f'SP11_APT_INRELEASE_RESOLUTE_SHA256="{self.inrelease_hashes["resolute"]}"',
            f'SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256="{self.inrelease_hashes["resolute-updates"]}"',
            f'SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256="{self.inrelease_hashes["resolute-backports"]}"',
            f'SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256="{self.inrelease_hashes["resolute-security"]}"',
            'SP11_APT_AUTHENTICATED_INDEX_COUNT="32"',
            f'SP11_APT_DECOMPRESSED_EMPTY_INDEX_COUNT="{len(EMPTY_INDEX_PATHS)}"',
            f'SP11_APT_DECOMPRESSED_EMPTY_INDEX_SIZE="{len(EMPTY_GZIP)}"',
            f'SP11_APT_DECOMPRESSED_EMPTY_INDEX_SHA256="{EMPTY_GZIP_SHA256}"',
            'SP11_APT_PYTHON_PACKAGE_SPEC="python3=1"',
            'SP11_APT_BOOTSTRAP_PACKAGE_COUNT="4"',
        ]
        for index, path in enumerate(EMPTY_INDEX_PATHS, 1):
            lines.insert(
                lines.index('SP11_APT_PYTHON_PACKAGE_SPEC="python3=1"'),
                f'SP11_APT_DECOMPRESSED_EMPTY_INDEX_{index}_PATH="{path}"',
            )
        for index, (name, package, version, _arch) in enumerate(self.debs, 1):
            lines.extend(
                (
                    f'SP11_APT_BOOTSTRAP_PACKAGE_{index}_SPEC="{package}={version}"',
                    f'SP11_APT_BOOTSTRAP_PACKAGE_{index}_SHA256="{digest(self.deb_bytes[name])}"',
                )
            )
        self.baseline = self.root / "baseline.env"
        self.baseline.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def _write_executable(self, name: str, content: str) -> None:
        path = self.mock_bin / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def _write_mocks(self) -> None:
        self._write_executable(
            "apt-get",
            """#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" update "*)
    case " $* " in
      *" Acquire::https::Verify-Peer=false "*)
        printf '%s\n' 'apt-get update tls-peer-disabled' >> "$SP11_TEST_CALL_LOG"
        ;;
      *)
        printf '%s\n' 'apt-get update strict' >> "$SP11_TEST_CALL_LOG"
        ;;
    esac
    cp "$SP11_TEST_LIST_SOURCE"/* "$SP11_APT_FIXTURE_ROOT/var/lib/apt/lists/"
    ;;
  *" --download-only "*)
    printf 'apt-get download-only:%s\n' "$*" >> "$SP11_TEST_CALL_LOG"
    while IFS=$'\\t' read -r name package version arch; do
      case "$package" in evil|linux-qcom-x1e-build-deps|python3) continue ;; esac
      cp "$SP11_TEST_DEB_SOURCE/$name" "$SP11_TEST_ARCHIVES/$name"
    done < "$SP11_TEST_DEB_FIELDS"
    if [ "${SP11_TEST_EXTRA_DEB:-false}" = "true" ]; then
      printf 'extra\\n' > "$SP11_TEST_ARCHIVES/unrelated_1_arm64.deb"
    fi
    ;;
  *" --no-download "*)
    printf 'apt-get no-download:%s\n' "$*" >> "$SP11_TEST_CALL_LOG"
    printf 'fixture CA bundle\\n' > "$SP11_APT_FIXTURE_ROOT/etc/ssl/certs/ca-certificates.crt"
    ;;
  *" install python3="*)
    case " $* " in
      *" Acquire::https::Verify-Peer=false "*)
        printf '%s\n' 'python3 install rejected disabled TLS verification' >> "$SP11_TEST_CALL_LOG"
        exit 96
        ;;
    esac
    printf 'apt-get install python3 strict:%s\n' "$*" >> "$SP11_TEST_CALL_LOG"
    if [ "${SP11_TEST_SKIP_PYTHON_INSTALL:-false}" != "true" ]; then
      : > "$SP11_TEST_PYTHON_INSTALL_MARKER"
      if [ "${SP11_TEST_SKIP_PYTHON_EXECUTABLE:-false}" != "true" ]; then
        cp "$SP11_TEST_PYTHON_SOURCE" "$SP11_TEST_PYTHON_TARGET"
        chmod 0755 "$SP11_TEST_PYTHON_TARGET"
      fi
      cp "$SP11_TEST_PYTHON_DEB_SOURCE" "$SP11_TEST_ARCHIVES/"
    fi
    ;;
esac
""",
        )
        self._write_executable(
            "apt-helper",
            """#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  cat-file)
    printf 'apt-helper cat-file:%s\n' "$(basename "$2")" >> "$SP11_TEST_CALL_LOG"
    cat "$2"
    ;;
  download-file)
    printf 'apt-helper download-file:%s:%s\n' "$2" "$4" >> "$SP11_TEST_CALL_LOG"
    digest="${4#SHA256:}"
    cp "$SP11_TEST_INDEX_SOURCE/$digest" "$3"
    ;;
  *) exit 2 ;;
esac
""",
        )
        self._write_executable(
            "sha256sum",
            """#!/usr/bin/env bash
set -euo pipefail
path="${!#}"
value="$("$SP11_TEST_REAL_PYTHON3" - "$path" <<'PY_SHA256'
import hashlib
import sys

with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY_SHA256
)"
printf 'sha256 %s\\n' "$(basename "$path")" >> "$SP11_TEST_CALL_LOG"
printf '%s  %s\\n' "$value" "$path"
""",
        )
        self.python_source.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf 'python3 acquired:%s\n' "$(basename "${1:-}")" >> "$SP11_TEST_CALL_LOG"
exec "$SP11_TEST_REAL_PYTHON3" "$@"
""",
            encoding="utf-8",
        )
        self.python_source.chmod(0o755)
        self._write_executable(
            "dpkg-deb",
            """#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$2")"
field="$3"
awk -F '\\t' -v name="$name" -v field="$field" '
  $1 == name {
    if (field == "Package") print $2
    else if (field == "Version") print $3
    else if (field == "Architecture") print $4
    else exit 2
    found=1
  }
  END { if (!found) exit 1 }
' "$SP11_TEST_DEB_FIELDS"
""",
        )
        self._write_executable(
            "dpkg-query",
            """#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 2 ]; then
  printf 'ii  base-files:arm64=1\\n'
  exit 0
fi
package="${!#}"
if [ "$package" = "python3" ]; then
  [ -f "$SP11_TEST_PYTHON_INSTALL_MARKER" ] || exit 1
  if [ -n "${SP11_TEST_PYTHON_INSTALLED_VERSION:-}" ]; then
    printf '%s\n' "$SP11_TEST_PYTHON_INSTALLED_VERSION"
    exit 0
  fi
fi
awk -F '\\t' -v package="$package" '$2 == package { print $3; found=1 } END { if (!found) exit 1 }' "$SP11_TEST_DEB_FIELDS"
""",
        )
        self._write_executable(
            "gpgv",
            f"""#!/usr/bin/env bash
set -euo pipefail
for last_arg in "$@"; do :; done
printf 'gpgv %s\n' "$(basename "$last_arg")" >> "$SP11_TEST_CALL_LOG"
[ "${{SP11_TEST_BAD_SIGNATURE:-false}}" != "true" ] || exit 1
printf '[GNUPG:] VALIDSIG {FINGERPRINT} 2026 0 0 0 0 0 0 0\n'
""",
        )

    def env(self, **extra: str) -> dict[str, str]:
        environment = dict(os.environ)
        environment.update(
            {
                "PATH": f"{self.mock_bin}:{self.tool_bin}",
                "SP11_APT_FIXTURE_ROOT": str(self.root),
                "SP11_APT_ALLOW_NON_ROOT_FIXTURE": "true",
                "SP11_APT_HELPER": str(self.mock_bin / "apt-helper"),
                "SP11_TEST_LIST_SOURCE": str(self.source_lists),
                "SP11_TEST_INDEX_SOURCE": str(self.source_indexes),
                "SP11_TEST_DEB_SOURCE": str(self.root / "deb-source"),
                "SP11_TEST_DEB_FIELDS": str(self.deb_fields),
                "SP11_TEST_ARCHIVES": str(self.archives),
                "SP11_TEST_CALL_LOG": str(self.call_log),
                "SP11_TEST_PYTHON_SOURCE": str(self.python_source),
                "SP11_TEST_PYTHON_TARGET": str(self.mock_bin / "python3"),
                "SP11_TEST_PYTHON_INSTALL_MARKER": str(
                    self.python_install_marker
                ),
                "SP11_TEST_PYTHON_DEB_SOURCE": str(
                    self.root / "deb-source" / self.python_deb[0]
                ),
                "SP11_TEST_REAL_PYTHON3": sys.executable,
            }
        )
        environment.update(extra)
        return environment

    def populate_deb_source(self) -> None:
        source = self.root / "deb-source"
        source.mkdir(exist_ok=True)
        for name, data in self.deb_bytes.items():
            (source / name).write_bytes(data)

    def helper_command(self, mode: str) -> list[str]:
        command = [
            "bash",
            str(APT_HELPER),
            mode,
            "--baseline",
            str(self.baseline),
            "--archives-dir",
            str(self.archives),
            "--index-cache-dir",
            str(self.index_cache),
            "--retained-lists-dir",
            str(self.retained_lists),
            "--work-dir",
            str(self.work),
            "--kernel-work-dir",
            str(self.kernel_work),
        ]
        if mode == "finalize":
            command.extend(
                (
                    "--output",
                    str(self.artifacts / "sp11-kernel-apt-provenance.txt"),
                )
            )
        return command

    def writer_command(self, output: Path) -> list[str]:
        return [
            sys.executable,
            str(WRITER),
            "write",
            "--baseline",
            str(self.baseline),
            "--archives-dir",
            str(self.archives),
            "--lists-dir",
            str(self.retained_lists),
            "--index-cache-dir",
            str(self.index_cache),
            "--local-build-deps-dir",
            str(self.artifacts),
            "--pre-inventory",
            str(self.work / "sp11-apt-installed-pre.txt"),
            "--post-inventory",
            str(self.work / "sp11-apt-installed-post.txt"),
            "--output",
            str(output),
        ]


def assert_path_guards(temp_root: Path) -> None:
    fixture = Fixture(temp_root)
    victim = fixture.root / "victim"
    victim.mkdir()
    sentinel = victim / "sentinel"
    sentinel.write_text("preserve\n", encoding="utf-8")
    environment = fixture.env()
    environment.pop("SP11_APT_FIXTURE_ROOT")
    environment["SP11_APT_ETC_DIR"] = str(victim)
    run(fixture.helper_command("bootstrap"), environment, expect=False)
    assert sentinel.read_text(encoding="utf-8") == "preserve\n"

    environment = fixture.env()
    bad_command = fixture.helper_command("bootstrap")
    bad_command[bad_command.index(str(fixture.archives))] = str(victim)
    run(bad_command, environment, expect=False)
    assert sentinel.exists()

    environment = fixture.env(APT_CONFIG=str(victim / "apt.conf"))
    run(fixture.helper_command("bootstrap"), environment, expect=False)
    assert sentinel.exists()

    environment = fixture.env()
    link = fixture.work / "linked-archives"
    link.symlink_to(victim, target_is_directory=True)
    bad_command = fixture.helper_command("bootstrap")
    bad_command[bad_command.index(str(fixture.archives))] = str(link)
    run(bad_command, environment, expect=False)
    assert sentinel.exists()


def assert_wrapper_contract() -> None:
    wrapper = DOCKER_WRAPPER.read_text(encoding="utf-8")
    inner = INNER_BUILDER.read_text(encoding="utf-8")
    apt_helper = APT_HELPER.read_text(encoding="utf-8")
    for required_text in (
        "docker buildx imagetools inspect --raw",
        "/repo/scripts/sp11-immutable-apt.sh bootstrap",
        "/repo/scripts/sp11-immutable-apt.sh finalize",
        "SP11_IMMUTABLE_APT_REQUIRED=true",
        "sp11-kernel-apt-provenance.txt",
        "sp11-kernel-build-inputs.txt",
        "Publication remains blocked: outer release validation",
    ):
        assert required_text in wrapper
    assert 'mk_build_deps_args+=(--remove)' in inner
    assert 'if [ "${SP11_IMMUTABLE_APT_REQUIRED:-false}" != "true" ]' in inner
    envelope_write = wrapper.index(
        'python3 "$repo_dir/scripts/sp11-kernel-build-inputs.py" write'
    )
    envelope_validate = wrapper.index(
        'python3 "$repo_dir/scripts/sp11-kernel-build-inputs.py" validate',
        envelope_write,
    )
    required_artifacts = wrapper.index(
        'for required_artifact in "$completed_manifest" "$apt_provenance" "$build_inputs"',
        envelope_validate,
    )
    final_stability_check = wrapper.rindex("\nverify_release_support_stable")
    assert envelope_write < envelope_validate < required_artifacts < final_stability_check
    assert wrapper.rstrip().endswith("verify_release_support_stable")

    bootstrap = apt_helper[
        apt_helper.index("bootstrap() {") : apt_helper.index("\nfinalize() {")
    ]
    initial_preflight = bootstrap[: bootstrap.index('if find "$archives_dir"')]
    assert "python3" not in initial_preflight
    strict_update = bootstrap.index("apt-get --error-on=any update")
    strict_verification = bootstrap.index("verify_snapshot_metadata", strict_update)
    python_install = bootstrap.index(
        'apt-get -y --no-install-recommends install "$SP11_APT_PYTHON_PACKAGE_SPEC"',
        strict_verification,
    )
    installed_version = bootstrap.index("dpkg-query -W -f='${Version}'", python_install)
    executable_check = bootstrap.index("command -v python3", installed_version)
    python_use = bootstrap.index(
        'python3 "$repo_dir/scripts/write-sp11-apt-provenance.py" acquire-indexes',
        executable_check,
    )
    state_write = bootstrap.index("APT bootstrap state schema", python_use)
    assert (
        strict_update
        < strict_verification
        < python_install
        < installed_version
        < executable_check
        < python_use
        < state_write
    )


def assert_production_baseline_is_exact(temp_root: Path) -> None:
    original = (REPO / "config/kernel-baselines/7.2-rc5-jg-0.env").read_text(
        encoding="utf-8"
    )
    descriptor, temporary_name = tempfile.mkstemp(prefix="sp11-baseline.", dir=temp_root)
    os.close(descriptor)
    tampered = Path(temporary_name)
    try:
        tampered.write_text(
            original.replace(
                "45f95ce276cdba3e41870516a130e03c58b8b7a79e9546b0efe9e526d255740c",
                "0" * 64,
            ),
            encoding="utf-8",
        )
        run(["bash", str(BASELINE_VALIDATOR), str(tampered)], dict(os.environ), expect=False)
        tampered.write_text(
            original.replace(
                'SP11_APT_PYTHON_PACKAGE_SPEC="python3=3.14.3-0ubuntu2"',
                'SP11_APT_PYTHON_PACKAGE_SPEC="python3=3.14.3-0ubuntu1"',
            ),
            encoding="utf-8",
        )
        run(["bash", str(BASELINE_VALIDATOR), str(tampered)], dict(os.environ), expect=False)
        for old, new in (
            (
                'SP11_APT_DECOMPRESSED_EMPTY_INDEX_COUNT="6"',
                'SP11_APT_DECOMPRESSED_EMPTY_INDEX_COUNT="5"',
            ),
            (
                'SP11_APT_DECOMPRESSED_EMPTY_INDEX_SIZE="20"',
                'SP11_APT_DECOMPRESSED_EMPTY_INDEX_SIZE="21"',
            ),
            (
                f'SP11_APT_DECOMPRESSED_EMPTY_INDEX_SHA256="{EMPTY_GZIP_SHA256}"',
                'SP11_APT_DECOMPRESSED_EMPTY_INDEX_SHA256="' + "0" * 64 + '"',
            ),
            (
                f'SP11_APT_DECOMPRESSED_EMPTY_INDEX_1_PATH="{EMPTY_INDEX_PATHS[0]}"',
                'SP11_APT_DECOMPRESSED_EMPTY_INDEX_1_PATH="../escape"',
            ),
        ):
            tampered.write_text(original.replace(old, new), encoding="utf-8")
            run(
                ["bash", str(BASELINE_VALIDATOR), str(tampered)],
                dict(os.environ),
                expect=False,
            )
        tampered.write_text(
            original
            + 'SP11_APT_DECOMPRESSED_EMPTY_INDEX_7_PATH="resolute/main/source/Sources.gz"\n',
            encoding="utf-8",
        )
        run(["bash", str(BASELINE_VALIDATOR), str(tampered)], dict(os.environ), expect=False)
    finally:
        tampered.unlink(missing_ok=True)


def assert_bootstrap_authentication_failures(temp_root: Path) -> None:
    keyring_fixture = Fixture(temp_root)
    keyring_fixture.populate_deb_source()
    keyring_fixture.keyring.write_bytes(b"tampered fixture keyring\n")
    run(
        keyring_fixture.helper_command("bootstrap"),
        keyring_fixture.env(),
        expect=False,
    )
    keyring_events = keyring_fixture.call_log.read_text(encoding="utf-8").splitlines()
    assert keyring_events[0] == "apt-get update tls-peer-disabled"
    assert any(event == "sha256 ubuntu-archive-keyring.gpg" for event in keyring_events)
    assert not any(event.startswith("apt-get download-only:") for event in keyring_events)

    inrelease_fixture = Fixture(temp_root)
    inrelease_fixture.populate_deb_source()
    inrelease = (
        inrelease_fixture.source_lists
        / "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_InRelease"
    )
    inrelease.write_bytes(inrelease.read_bytes() + b"tampered metadata\n")
    run(
        inrelease_fixture.helper_command("bootstrap"),
        inrelease_fixture.env(),
        expect=False,
    )
    inrelease_events = inrelease_fixture.call_log.read_text(
        encoding="utf-8"
    ).splitlines()
    assert "sha256 snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_InRelease" in inrelease_events
    assert not any(event.startswith("gpgv ") for event in inrelease_events)
    assert not any(event.startswith("apt-get download-only:") for event in inrelease_events)

    signature_fixture = Fixture(temp_root)
    signature_fixture.populate_deb_source()
    run(
        signature_fixture.helper_command("bootstrap"),
        signature_fixture.env(SP11_TEST_BAD_SIGNATURE="true"),
        expect=False,
    )
    signature_events = signature_fixture.call_log.read_text(
        encoding="utf-8"
    ).splitlines()
    assert (
        "gpgv snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_InRelease"
        in signature_events
    )
    assert not any(event.startswith("apt-get download-only:") for event in signature_events)


def assert_inrelease_empty_entry_contract(temp_root: Path) -> None:
    def acquire_indexes(fixture: Fixture) -> subprocess.CompletedProcess[str]:
        return run(
            [
                sys.executable,
                str(WRITER),
                "acquire-indexes",
                "--baseline",
                str(fixture.baseline),
                "--lists-dir",
                str(fixture.source_lists),
                "--index-cache-dir",
                str(fixture.index_cache),
            ],
            fixture.env(),
            expect=False,
        )

    benign = (
        f" {EMPTY_SHA256} 0 main/debian-installer/binary-arm64/Packages"
    )
    hostile_rows = (
        f" {'f' * 64} 0 main/debian-installer/binary-arm64/Packages",
        f" {EMPTY_SHA256} 1 main/debian-installer/binary-arm64/Packages",
        f" {EMPTY_SHA256} \u0660 main/debian-installer/binary-arm64/Packages",
        f" {EMPTY_SHA256} 00 main/debian-installer/binary-arm64/Packages",
        f" {'f' * 64} {1 << 64} main/debian-installer/binary-arm64/Packages",
        f" {'f' * 64} {'9' * 5000} main/debian-installer/binary-arm64/Packages",
    )
    for hostile in hostile_rows:
        fixture = Fixture(temp_root)
        inrelease = (
            fixture.source_lists
            / "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_InRelease"
        )
        original = inrelease.read_text(encoding="utf-8")
        assert original.count(benign) == 1
        assert original.index(benign) < original.index("\nAcquire-By-Hash: yes\n")
        inrelease.write_text(
            original.replace(benign, hostile), encoding="utf-8"
        )
        result = acquire_indexes(fixture)
        assert (
            "error: invalid SHA256 entry in "
            "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_InRelease"
            in result.stderr
        )
        assert "Traceback" not in result.stderr
        assert fixture.call_log.read_text(encoding="utf-8") == ""

    fixture = Fixture(temp_root)
    inrelease = (
        fixture.source_lists
        / "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_InRelease"
    )
    original = inrelease.read_text(encoding="utf-8")
    selected_suffix = " main/binary-arm64/Packages.gz"
    selected = next(
        line for line in original.splitlines() if line.endswith(selected_suffix)
    )
    selected_empty = f" {EMPTY_SHA256} 0{selected_suffix}"
    inrelease.write_text(
        original.replace(selected, selected_empty, 1), encoding="utf-8"
    )
    result = acquire_indexes(fixture)
    assert (
        "error: selected authenticated index entry is empty: "
        "resolute/main/binary-arm64/Packages.gz"
        in result.stderr
    )
    assert fixture.call_log.read_text(encoding="utf-8") == ""


def assert_decompressed_empty_index_contract(temp_root: Path) -> None:
    def acquire_indexes(fixture: Fixture) -> subprocess.CompletedProcess[str]:
        return run(
            [
                sys.executable,
                str(WRITER),
                "acquire-indexes",
                "--baseline",
                str(fixture.baseline),
                "--lists-dir",
                str(fixture.source_lists),
                "--index-cache-dir",
                str(fixture.index_cache),
            ],
            fixture.env(),
            expect=False,
        )

    shape_fixture = Fixture(temp_root)
    assert len([path for path in shape_fixture.source_lists.iterdir() if path.is_file()]) == 31
    for full_path in EMPTY_INDEX_PATHS:
        suite, relative = full_path.split("/", 1)
        compressed = fixture_gzip(shape_fixture.index_raw[(suite, relative)])
        assert len(compressed) == 20
        assert digest(compressed) == EMPTY_GZIP_SHA256
        list_name = (
            "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_"
            f"{suite}_{relative[:-3].replace('/', '_')}.lz4"
        )
        assert not (shape_fixture.source_lists / list_name).exists()

    path_fixture = Fixture(temp_root)
    baseline_text = path_fixture.baseline.read_text(encoding="utf-8")
    path_fixture.baseline.write_text(
        baseline_text.replace(
            EMPTY_INDEX_PATHS[0], "resolute-backports/universe/binary-arm64/Packages.gz"
        ),
        encoding="utf-8",
    )
    result = acquire_indexes(path_fixture)
    assert "decompressed-empty index paths do not match the reviewed sequence" in result.stderr
    assert path_fixture.call_log.read_text(encoding="utf-8") == ""

    declared_nonempty = Fixture(temp_root)
    suite, relative = EMPTY_INDEX_PATHS[0].split("/", 1)
    declared_nonempty.index_raw[(suite, relative)] = b"unexpected non-empty bytes\n"
    declared_nonempty.rebuild_metadata()
    declared_nonempty.write_baseline()
    result = acquire_indexes(declared_nonempty)
    assert (
        "declared empty index has an unexpected signed gzip identity: "
        f"{EMPTY_INDEX_PATHS[0]}" in result.stderr
    )

    undeclared_empty = Fixture(temp_root)
    undeclared_path = "resolute-backports/universe/binary-arm64/Packages.gz"
    suite, relative = undeclared_path.split("/", 1)
    undeclared_empty.index_raw[(suite, relative)] = b""
    undeclared_empty.rebuild_metadata()
    undeclared_empty.write_baseline()
    result = acquire_indexes(undeclared_empty)
    assert (
        "acquired index decompressed-empty state differs from baseline: "
        f"{undeclared_path}" in result.stderr
    )

    placeholder = Fixture(temp_root)
    suite, relative = EMPTY_INDEX_PATHS[0].split("/", 1)
    placeholder_name = (
        "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_"
        f"{suite}_{relative[:-3].replace('/', '_')}.lz4"
    )
    (placeholder.source_lists / placeholder_name).write_bytes(b"")
    result = acquire_indexes(placeholder)
    assert "APT list target set differs from the baseline-derived set" in result.stderr
    assert placeholder.call_log.read_text(encoding="utf-8") == ""

    missing_view = Fixture(temp_root)
    missing_name = (
        "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_"
        "main_binary-arm64_Packages.lz4"
    )
    (missing_view.source_lists / missing_name).unlink()
    result = acquire_indexes(missing_view)
    assert "APT list target set differs from the baseline-derived set" in result.stderr
    assert missing_view.call_log.read_text(encoding="utf-8") == ""

    malformed = Fixture(temp_root)
    suite = "resolute"
    relative = "main/source/Sources.gz"
    inrelease = (
        malformed.source_lists
        / "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_InRelease"
    )
    original = inrelease.read_text(encoding="utf-8")
    old_row = next(line for line in original.splitlines() if line.endswith(f" {relative}"))
    malformed_gzip = b"not a gzip stream"
    malformed_digest = digest(malformed_gzip)
    new_row = f" {malformed_digest} {len(malformed_gzip)} {relative}"
    inrelease.write_text(original.replace(old_row, new_row), encoding="utf-8")
    (malformed.source_indexes / malformed_digest).write_bytes(malformed_gzip)
    malformed.inrelease_hashes[suite] = digest(inrelease.read_bytes())
    malformed.write_baseline()
    result = acquire_indexes(malformed)
    assert "could not decompress acquired authenticated index" in result.stderr
    assert "Traceback" not in result.stderr


def assert_full_validator_signed_size_contract(temp_root: Path) -> None:
    specification = importlib.util.spec_from_file_location(
        "sp11_kernel_build_inputs_signed_size_fixture", ENVELOPE
    )
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)

    benign = f" {EMPTY_SHA256} 0 main/debian-installer/binary-arm64/Packages"
    hostile_rows = (
        f" {'f' * 64} 0 main/debian-installer/binary-arm64/Packages",
        f" {EMPTY_SHA256} 1 main/debian-installer/binary-arm64/Packages",
        f" {EMPTY_SHA256} \u0660 main/debian-installer/binary-arm64/Packages",
        f" {EMPTY_SHA256} 00 main/debian-installer/binary-arm64/Packages",
        f" {'f' * 64} {1 << 64} main/debian-installer/binary-arm64/Packages",
        f" {'f' * 64} {'9' * 5000} main/debian-installer/binary-arm64/Packages",
    )
    valid_fixture = Fixture(temp_root)
    valid_inrelease = (
        valid_fixture.source_lists
        / "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_InRelease"
    )
    assert module.clear_signed_sha256(valid_inrelease)[
        "main/debian-installer/binary-arm64/Packages"
    ] == (0, EMPTY_SHA256)
    for hostile in hostile_rows:
        fixture = Fixture(temp_root)
        inrelease = (
            fixture.source_lists
            / "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_resolute_InRelease"
        )
        original = inrelease.read_text(encoding="utf-8")
        inrelease.write_text(original.replace(benign, hostile), encoding="utf-8")
        try:
            module.clear_signed_sha256(inrelease)
        except SystemExit as exc:
            assert "invalid SHA256 row" in str(exc)
        else:
            raise AssertionError("full validator accepted a hostile signed size row")


def assert_full_validator_decoder_contract(temp_root: Path) -> None:
    specification = importlib.util.spec_from_file_location(
        "sp11_kernel_build_inputs_decoder_fixture", ENVELOPE
    )
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)

    class SystemHelper:
        def is_file(self) -> bool:
            return True

        def is_symlink(self) -> bool:
            return False

        def __str__(self) -> str:
            return "/usr/lib/apt/apt-helper"

    system_helper = SystemHelper()
    real_path = Path
    module.Path = lambda value: (
        system_helper
        if str(value) == "/usr/lib/apt/apt-helper"
        else real_path(value)
    )
    executable = False
    access_calls: list[tuple[object, int]] = []

    def access(path: object, mode: int) -> bool:
        access_calls.append((path, mode))
        return executable

    module.os = SimpleNamespace(environ={}, access=access, X_OK=os.X_OK)
    decoder_lookup_calls: list[str] = []

    def decoder_lookup(name: str) -> str:
        decoder_lookup_calls.append(name)
        return "/fixture/bin/lz4"

    module.shutil = SimpleNamespace(which=decoder_lookup)
    target = temp_root / "decoder-contract.lz4"
    assert module.apt_list_decoder(target, {}) == [
        "/fixture/bin/lz4",
        "-d",
        "-c",
        str(target),
    ]
    assert access_calls == [(system_helper, os.X_OK)]
    assert decoder_lookup_calls == ["lz4"]

    executable = True
    decoder_lookup_calls.clear()
    assert module.apt_list_decoder(target, {}) == [
        "/usr/lib/apt/apt-helper",
        "cat-file",
        str(target),
    ]
    assert access_calls[-1] == (system_helper, os.X_OK)
    assert decoder_lookup_calls == []


def assert_ordered_bootstrap_calls(fixture: Fixture) -> None:
    events = fixture.call_log.read_text(encoding="utf-8").splitlines()

    def next_event(expected: str, start: int) -> int:
        try:
            return events.index(expected, start)
        except ValueError as exc:
            raise AssertionError(f"missing ordered fixture event: {expected}") from exc

    cursor = next_event("apt-get update tls-peer-disabled", 0) + 1
    cursor = next_event("sha256 ubuntu-archive-keyring.gpg", cursor) + 1
    for suite in SUITES:
        name = (
            "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_"
            f"{suite}_InRelease"
        )
        cursor = next_event(f"sha256 {name}", cursor) + 1
        cursor = next_event(f"gpgv {name}", cursor) + 1

    download_index = next(
        index
        for index, event in enumerate(events[cursor:], cursor)
        if event.startswith("apt-get download-only:")
    )
    download_event = events[download_index]
    exact_specs = "ca-certificates=1 openssl=1 libssl3t64=1 openssl-provider-legacy=1"
    assert exact_specs in download_event
    install_index = next(
        index
        for index, event in enumerate(events[download_index + 1 :], download_index + 1)
        if event.startswith("apt-get no-download:")
    )
    assert exact_specs in events[install_index]
    for name, _package, _version, _arch in fixture.debs:
        deb_hash_index = next_event(f"sha256 {name}", download_index + 1)
        assert deb_hash_index < install_index

    strict_index = next_event("apt-get update strict", install_index + 1)
    cursor = next_event("sha256 ubuntu-archive-keyring.gpg", strict_index + 1) + 1
    for suite in SUITES:
        name = (
            "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_"
            f"{suite}_InRelease"
        )
        cursor = next_event(f"sha256 {name}", cursor) + 1
        cursor = next_event(f"gpgv {name}", cursor) + 1

    python_install_event = (
        "apt-get install python3 strict:"
        "-y --no-install-recommends install python3=1"
    )
    python_install_index = next_event(python_install_event, cursor)
    assert "Acquire::https::Verify-Peer=false" not in events[python_install_index]
    python_use_index = next_event(
        "python3 acquired:write-sp11-apt-provenance.py", python_install_index + 1
    )

    index_downloads = [
        (index, event)
        for index, event in enumerate(events)
        if event.startswith("apt-helper download-file:")
    ]
    assert len(index_downloads) == 32
    assert all(index > python_use_index for index, _event in index_downloads)
    assert all(
        event.startswith(
            "apt-helper download-file:https://snapshot.ubuntu.com/ubuntu/"
            "20260807T000000Z/dists/"
        )
        and "/by-hash/SHA256/" in event
        and event.rsplit(":SHA256:", 1)[-1].isalnum()
        and len(event.rsplit(":SHA256:", 1)[-1]) == 64
        for _index, event in index_downloads
    )


def bootstrap_and_finalize(temp_root: Path) -> Fixture:
    missing_python_fixture = Fixture(temp_root)
    missing_python_fixture.populate_deb_source()
    missing_python_result = run(
        missing_python_fixture.helper_command("bootstrap"),
        missing_python_fixture.env(SP11_TEST_SKIP_PYTHON_INSTALL="true"),
        expect=False,
    )
    missing_python_events = missing_python_fixture.call_log.read_text(
        encoding="utf-8"
    ).splitlines()
    assert any(
        event.startswith("apt-get install python3 strict:")
        for event in missing_python_events
    )
    assert (
        "error: authenticated snapshot Python package was not installed: python3"
        in missing_python_result.stderr
    )
    assert not any(event.startswith("apt-helper download-file:") for event in missing_python_events)
    assert not (missing_python_fixture.work / "sp11-apt-bootstrap-state.txt").exists()

    wrong_python_fixture = Fixture(temp_root)
    wrong_python_fixture.populate_deb_source()
    wrong_python_result = run(
        wrong_python_fixture.helper_command("bootstrap"),
        wrong_python_fixture.env(SP11_TEST_PYTHON_INSTALLED_VERSION="2"),
        expect=False,
    )
    wrong_python_events = wrong_python_fixture.call_log.read_text(
        encoding="utf-8"
    ).splitlines()
    assert (
        "error: authenticated snapshot Python package version does not match the baseline"
        in wrong_python_result.stderr
    )
    assert not any(event.startswith("python3 acquired:") for event in wrong_python_events)
    assert not any(event.startswith("apt-helper download-file:") for event in wrong_python_events)
    assert not (wrong_python_fixture.work / "sp11-apt-bootstrap-state.txt").exists()

    missing_executable_fixture = Fixture(temp_root)
    missing_executable_fixture.populate_deb_source()
    missing_executable_result = run(
        missing_executable_fixture.helper_command("bootstrap"),
        missing_executable_fixture.env(SP11_TEST_SKIP_PYTHON_EXECUTABLE="true"),
        expect=False,
    )
    missing_executable_events = missing_executable_fixture.call_log.read_text(
        encoding="utf-8"
    ).splitlines()
    assert (
        "error: authenticated snapshot Python installation did not provide python3"
        in missing_executable_result.stderr
    )
    assert not any(
        event.startswith("python3 acquired:") for event in missing_executable_events
    )
    assert not any(
        event.startswith("apt-helper download-file:")
        for event in missing_executable_events
    )
    assert not (
        missing_executable_fixture.work / "sp11-apt-bootstrap-state.txt"
    ).exists()

    extra_fixture = Fixture(temp_root)
    extra_fixture.populate_deb_source()
    run(
        extra_fixture.helper_command("bootstrap"),
        extra_fixture.env(SP11_TEST_EXTRA_DEB="true"),
        expect=False,
    )

    fixture = Fixture(temp_root)
    fixture.populate_deb_source()
    run(fixture.helper_command("bootstrap"), fixture.env())
    assert not (fixture.root / "etc/apt/sources.list").exists()
    assert [
        path.name for path in (fixture.root / "etc/apt/sources.list.d").iterdir()
    ] == ["sp11-immutable-snapshot.sources"]
    sources = (
        fixture.root / "etc/apt/sources.list.d/sp11-immutable-snapshot.sources"
    ).read_text(encoding="utf-8")
    assert sources == (
        "Types: deb deb-src\n"
        "URIs: https://snapshot.ubuntu.com/ubuntu/20260807T000000Z/\n"
        "Suites: resolute resolute-updates resolute-backports resolute-security\n"
        "Components: main universe restricted multiverse\n"
        "Architectures: arm64\n"
        f"Signed-By: {fixture.keyring}\n"
        "InRelease-Path: InRelease\n"
        "By-Hash: force\n"
        "PDiffs: no\n"
        "Check-Valid-Until: yes\n"
    )
    apt_config = (fixture.root / "etc/apt/apt.conf.d/99sp11-immutable-snapshot").read_text(
        encoding="utf-8"
    )
    assert 'Acquire::https::Verify-Peer "true";' in apt_config
    assert 'Acquire::https::Verify-Host "true";' in apt_config
    assert 'Acquire::Languages "none";' in apt_config
    (fixture.artifacts / fixture.local_name).write_bytes(fixture.local_bytes)
    run(fixture.helper_command("finalize"), fixture.env())
    assert_ordered_bootstrap_calls(fixture)
    sidecar = (fixture.artifacts / "sp11-kernel-apt-provenance.txt").read_text(
        encoding="utf-8"
    )
    assert "Index count: 32\n" in sidecar
    assert "APT list target count: 31\n" in sidecar
    for full_path in EMPTY_INDEX_PATHS:
        suite, relative = full_path.split("/", 1)
        empty_list_name = (
            "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_"
            f"{suite}_{relative[:-3].replace('/', '_')}.lz4"
        )
        assert empty_list_name not in sidecar
    python_name, python_package, python_version, python_arch = fixture.python_deb
    python_bytes = fixture.deb_bytes[python_name]
    assert "Downloaded Deb count: 5\n" in sidecar
    assert f"Downloaded Deb 5 path: {python_name}\n" in sidecar
    assert f"Downloaded Deb 5 package: {python_package}\n" in sidecar
    assert f"Downloaded Deb 5 version: {python_version}\n" in sidecar
    assert f"Downloaded Deb 5 architecture: {python_arch}\n" in sidecar
    assert f"Downloaded Deb 5 size: {len(python_bytes)}\n" in sidecar
    assert f"Downloaded Deb 5 SHA256: {digest(python_bytes)}\n" in sidecar
    assert (
        f"Downloaded Deb 5 archive filename: pool/main/f/{python_package}/{python_name}\n"
        in sidecar
    )
    return fixture


def writer_hostile_cases(fixture: Fixture) -> None:
    sidecar = fixture.artifacts / "sp11-kernel-apt-provenance.txt"
    local_target = next(
        path for path in fixture.retained_lists.iterdir() if path.name.endswith("main_binary-arm64_Packages.lz4")
    )
    original_local = local_target.read_bytes()
    local_target.write_bytes(original_local + b"tampered apt-cache/list record\n")
    run(fixture.writer_command(fixture.artifacts / "corrupt-list.txt"), fixture.env(), expect=False)
    local_target.write_bytes(original_local)

    retained = fixture.index_cache / "resolute/main/binary-arm64/Packages.gz"
    original_retained = retained.read_bytes()
    retained.write_bytes(original_retained + b"corrupt")
    run(fixture.writer_command(fixture.artifacts / "corrupt-index.txt"), fixture.env(), expect=False)
    retained.write_bytes(original_retained)
    retained.unlink()
    run(fixture.writer_command(fixture.artifacts / "missing-index.txt"), fixture.env(), expect=False)
    retained.write_bytes(original_retained)

    extra_index_dir = fixture.index_cache / "unexpected-empty-directory"
    extra_index_dir.mkdir()
    extra_dir_result = run(
        fixture.writer_command(fixture.artifacts / "extra-index-directory.txt"),
        fixture.env(),
        expect=False,
    )
    assert "APT index cache tree is not the exact reviewed 32-file layout" in extra_dir_result.stderr
    extra_index_dir.rmdir()

    evil = fixture.archives / "evil_1_arm64.deb"
    evil.write_bytes(b"evil Deb not present in signed Packages.gz\n")
    run(fixture.writer_command(fixture.artifacts / "mutable-apt-cache.txt"), fixture.env(), expect=False)
    evil.unlink()

    duplicate = fixture.package_record(
        fixture.debs[0][0], fixture.debs[0][1], fixture.debs[0][2], fixture.debs[0][3], fixture.deb_bytes[fixture.debs[0][0]]
    )
    key = ("resolute", "universe/binary-arm64/Packages.gz")
    fixture.index_raw[key] += duplicate
    fixture.rebuild_metadata()
    fixture.write_baseline()
    for entry in fixture.retained_lists.iterdir():
        if entry.is_file():
            entry.unlink()
    for entry in fixture.source_lists.iterdir():
        shutil.copy2(entry, fixture.retained_lists / entry.name)
    shutil.rmtree(fixture.index_cache)
    fixture.index_cache.mkdir()
    for suite in SUITES:
        for component in COMPONENTS:
            for relative in (
                f"{component}/binary-arm64/Packages.gz",
                f"{component}/source/Sources.gz",
            ):
                compressed = fixture_gzip(fixture.index_raw[(suite, relative)])
                target = fixture.index_cache / suite / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(compressed)
    duplicate_sidecar = fixture.artifacts / "duplicate-identical.txt"
    run(fixture.writer_command(duplicate_sidecar), fixture.env())
    assert "Downloaded Deb 1 signed record count: 2\n" in duplicate_sidecar.read_text(
        encoding="utf-8"
    )

    conflict = fixture.package_record(
        fixture.debs[0][0], fixture.debs[0][1], fixture.debs[0][2], fixture.debs[0][3], b"conflicting signed Deb bytes\n"
    )
    fixture.index_raw[key] += conflict
    fixture.rebuild_metadata()
    fixture.write_baseline()
    for entry in fixture.retained_lists.iterdir():
        if entry.is_file():
            entry.unlink()
    for entry in fixture.source_lists.iterdir():
        shutil.copy2(entry, fixture.retained_lists / entry.name)
    shutil.rmtree(fixture.index_cache)
    fixture.index_cache.mkdir()
    for suite in SUITES:
        for component in COMPONENTS:
            for relative in (
                f"{component}/binary-arm64/Packages.gz",
                f"{component}/source/Sources.gz",
            ):
                target = fixture.index_cache / suite / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(fixture_gzip(fixture.index_raw[(suite, relative)]))
    run(fixture.writer_command(fixture.artifacts / "duplicate-conflict.txt"), fixture.env(), expect=False)
    assert sidecar.exists()


def envelope_cases(fixture: Fixture) -> None:
    # Restore a non-duplicate signed set and regenerate the positive sidecar.
    fixture._initialize_index_content()
    fixture.rebuild_metadata()
    fixture.write_baseline()
    for entry in fixture.retained_lists.iterdir():
        if entry.is_file():
            entry.unlink()
    for entry in fixture.source_lists.iterdir():
        shutil.copy2(entry, fixture.retained_lists / entry.name)
    shutil.rmtree(fixture.index_cache)
    fixture.index_cache.mkdir()
    for suite in SUITES:
        for component in COMPONENTS:
            for relative in (
                f"{component}/binary-arm64/Packages.gz",
                f"{component}/source/Sources.gz",
            ):
                target = fixture.index_cache / suite / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(fixture_gzip(fixture.index_raw[(suite, relative)]))
    sidecar = fixture.artifacts / "sp11-kernel-apt-provenance.txt"
    run(fixture.writer_command(sidecar), fixture.env())

    oci = fixture.work / "sp11-oci-index.json"
    oci.write_bytes(fixture.oci_raw)
    build_args = fixture.work / "docker-build-args.txt"
    entrypoint = fixture.work / "docker-build-inside.sh"
    build_args.write_text("--release-build\n", encoding="utf-8")
    entrypoint.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    manifest = fixture.artifacts / "sp11-kernel-build-manifest.txt"
    write_exact_build_manifest(fixture, manifest)
    envelope = fixture.artifacts / "sp11-kernel-build-inputs.txt"
    base_command = [
        sys.executable,
        str(ENVELOPE),
        "write",
        "--baseline",
        str(fixture.baseline),
        "--work-dir",
        str(fixture.work),
        "--support-head",
        SUPPORT_HEAD,
        "--build-args",
        str(build_args),
        "--entrypoint",
        str(entrypoint),
        "--oci-index",
        str(oci),
        "--build-manifest",
        str(manifest),
        "--apt-provenance",
        str(sidecar),
        "--apt-archives-dir",
        str(fixture.archives),
        "--apt-lists-dir",
        str(fixture.retained_lists),
        "--apt-index-cache-dir",
        str(fixture.index_cache),
        "--apt-local-build-deps-dir",
        str(fixture.artifacts),
        "--apt-pre-inventory",
        str(fixture.work / "sp11-apt-installed-pre.txt"),
        "--apt-post-inventory",
        str(fixture.work / "sp11-apt-installed-post.txt"),
        "--output",
        str(envelope),
    ]
    run(base_command, fixture.env())
    validate_command = base_command.copy()
    validate_command[2] = "validate"
    run(validate_command, fixture.env())
    production_identity_baseline = fixture.root / "production-identity-baseline.env"
    production_identity_baseline.write_text(
        fixture.baseline.read_text(encoding="utf-8").replace(
            'SP11_KERNEL_BASELINE_ID="fixture"',
            'SP11_KERNEL_BASELINE_ID="7.2-rc5-jg-0"',
        ),
        encoding="utf-8",
    )
    production_identity_command = [
        str(production_identity_baseline)
        if value == str(fixture.baseline)
        else value
        for value in validate_command
    ]
    production_fixture_result = run(
        production_identity_command, fixture.env(), expect=False
    )
    assert (
        "fixture APT decoder is forbidden for a production baseline"
        in production_fixture_result.stderr
    )
    attached_command = [
        sys.executable,
        str(ENVELOPE),
        "validate-attached",
        "--baseline",
        str(fixture.baseline),
        "--support-head",
        SUPPORT_HEAD,
        "--build-manifest",
        str(manifest),
        "--apt-provenance",
        str(sidecar),
        "--output",
        str(envelope),
    ]
    run(attached_command, fixture.env())

    original_sidecar = sidecar.read_text(encoding="utf-8")
    without_python = [
        line
        for line in original_sidecar.splitlines()
        if not line.startswith("Downloaded Deb 5 ")
    ]
    without_python[without_python.index("Downloaded Deb count: 5")] = (
        "Downloaded Deb count: 4"
    )
    sidecar.write_text("\n".join(without_python) + "\n", encoding="utf-8")
    missing_python_result = run(attached_command, fixture.env(), expect=False)
    assert (
        "error: APT sidecar is missing the required snapshot Python package"
        in missing_python_result.stderr
    )
    sidecar.write_text(original_sidecar, encoding="utf-8")

    sidecar.write_text(
        original_sidecar.replace(
            "Downloaded Deb 5 version: 1", "Downloaded Deb 5 version: 2"
        ),
        encoding="utf-8",
    )
    wrong_python_result = run(attached_command, fixture.env(), expect=False)
    assert (
        "error: APT sidecar is missing the required snapshot Python package"
        in wrong_python_result.stderr
    )
    sidecar.write_text(original_sidecar, encoding="utf-8")

    sidecar.write_text(
        original_sidecar.replace(
            "Downloaded Deb 5 architecture: arm64",
            "Downloaded Deb 5 architecture: amd64",
        ),
        encoding="utf-8",
    )
    wrong_python_arch_result = run(attached_command, fixture.env(), expect=False)
    assert (
        "error: APT sidecar is missing the required snapshot Python package"
        in wrong_python_arch_result.stderr
    )
    sidecar.write_text(original_sidecar, encoding="utf-8")

    release_snapshot = fixture.root / "release-snapshot"
    release_snapshot.mkdir()
    snapshot_manifest = release_snapshot / manifest.name
    snapshot_sidecar = release_snapshot / sidecar.name
    snapshot_envelope = release_snapshot / envelope.name
    shutil.copy2(manifest, snapshot_manifest)
    shutil.copy2(sidecar, snapshot_sidecar)
    shutil.copy2(envelope, snapshot_envelope)
    release_snapshot_command = validate_command.copy()
    release_snapshot_command[2] = "validate-release-snapshot"
    for old_path, new_path in (
        (manifest, snapshot_manifest),
        (sidecar, snapshot_sidecar),
        (envelope, snapshot_envelope),
    ):
        release_snapshot_command[
            release_snapshot_command.index(str(old_path))
        ] = str(new_path)
    run(release_snapshot_command, fixture.env())

    snapshot_envelope_text = snapshot_envelope.read_text(encoding="utf-8")
    input_one_hash = next(
        line for line in snapshot_envelope_text.splitlines() if line.startswith("Input 1 SHA256: ")
    )
    snapshot_envelope.write_text(
        snapshot_envelope_text.replace(input_one_hash, f"Input 1 SHA256: {'0' * 64}"),
        encoding="utf-8",
    )
    run(release_snapshot_command, fixture.env(), expect=False)
    snapshot_envelope.write_text(snapshot_envelope_text, encoding="utf-8")

    def assert_mid_validation_mutation_rejected(
        target: Path,
        hook_name: str,
        suffix: bytes,
        command: list[str] = validate_command,
    ) -> None:
        module_name = f"sp11_kernel_build_inputs_fixture_{hook_name}_{target.name.replace('.', '_')}"
        specification = importlib.util.spec_from_file_location(module_name, ENVELOPE)
        assert specification is not None and specification.loader is not None
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        original_hook = getattr(module, hook_name)
        original_bytes = target.read_bytes()
        mutated = False

        def mutating_hook(*args: object, **kwargs: object) -> object:
            nonlocal mutated
            result = original_hook(*args, **kwargs)
            if not mutated:
                target.write_bytes(original_bytes + suffix)
                mutated = True
            return result

        setattr(module, hook_name, mutating_hook)
        saved_arguments = sys.argv
        saved_environment = dict(os.environ)
        fixture_environment = fixture.env()
        sys.argv = [str(ENVELOPE), *command[2:]]
        os.environ.clear()
        os.environ.update(fixture_environment)
        try:
            try:
                module.main()
            except SystemExit as exc:
                assert "changed" in str(exc)
            else:
                raise AssertionError(
                    f"full envelope validation accepted a mid-validation mutation of {target.name}"
                )
        finally:
            sys.argv = saved_arguments
            os.environ.clear()
            os.environ.update(saved_environment)
            target.write_bytes(original_bytes)
        assert mutated

    assert_mid_validation_mutation_rejected(
        manifest, "validate_manifest", b"mid-validation manifest mutation\n"
    )
    assert_mid_validation_mutation_rejected(
        build_args, "validate_manifest", b"mid-validation control mutation\n"
    )
    assert_mid_validation_mutation_rejected(
        oci, "validate_oci_index", b"mid-validation OCI mutation\n"
    )
    assert_mid_validation_mutation_rejected(
        envelope, "validate_envelope", b"mid-validation envelope mutation\n"
    )
    assert_mid_validation_mutation_rejected(
        snapshot_manifest,
        "validate_manifest",
        b"mid-attached-validation manifest mutation\n",
        [
            str(snapshot_manifest)
            if value == str(manifest)
            else str(snapshot_sidecar)
            if value == str(sidecar)
            else str(snapshot_envelope)
            if value == str(envelope)
            else value
            for value in attached_command
        ],
    )
    assert_mid_validation_mutation_rejected(
        envelope,
        "validate_envelope",
        b"post-write envelope mutation\n",
        base_command,
    )

    original_sidecar = sidecar.read_text(encoding="utf-8")
    sidecar.write_text(original_sidecar + "Unexpected field: rejected\n", encoding="utf-8")
    run(validate_command, fixture.env(), expect=False)
    run(attached_command, fixture.env(), expect=False)
    sidecar.write_text(original_sidecar, encoding="utf-8")

    sidecar.write_text(
        original_sidecar.replace("Index 17 size: 20", "Index 17 size: 21"),
        encoding="utf-8",
    )
    empty_size_result = run(attached_command, fixture.env(), expect=False)
    assert "declared-empty gzip identity is invalid" in empty_size_result.stderr
    sidecar.write_text(original_sidecar, encoding="utf-8")

    sidecar.write_text(
        original_sidecar.replace(
            "APT list target count: 31", "APT list target count: 37"
        ),
        encoding="utf-8",
    )
    list_count_result = run(attached_command, fixture.env(), expect=False)
    assert "APT sidecar list-target count is not exact" in list_count_result.stderr
    sidecar.write_text(original_sidecar, encoding="utf-8")

    uri_line = next(
        line
        for line in original_sidecar.splitlines()
        if line.startswith("Downloaded Deb 1 URI: ")
    )
    sidecar.write_text(
        original_sidecar.replace(uri_line, uri_line.replace("snapshot.ubuntu.com", "example.invalid")),
        encoding="utf-8",
    )
    run(validate_command, fixture.env(), expect=False)
    sidecar.write_text(original_sidecar, encoding="utf-8")

    old_hash = next(
        line.split(": ", 1)[1]
        for line in original_sidecar.splitlines()
        if line.startswith("Index 1 SHA256: ")
    )
    tampered_hash = "d" * 64
    tampered_sidecar = original_sidecar.replace(
        f"Index 1 SHA256: {old_hash}", f"Index 1 SHA256: {tampered_hash}"
    ).replace(
        f"/by-hash/SHA256/{old_hash}", f"/by-hash/SHA256/{tampered_hash}", 1
    )
    sidecar.write_text(tampered_sidecar, encoding="utf-8")
    run(validate_command, fixture.env(), expect=False)
    sidecar.write_text(original_sidecar, encoding="utf-8")

    reordered_sidecar = original_sidecar.splitlines()
    first = reordered_sidecar.index("Index 1 suite: resolute")
    reordered_sidecar[first], reordered_sidecar[first + 1] = (
        reordered_sidecar[first + 1],
        reordered_sidecar[first],
    )
    sidecar.write_text("\n".join(reordered_sidecar) + "\n", encoding="utf-8")
    run(validate_command, fixture.env(), expect=False)
    sidecar.write_text(original_sidecar, encoding="utf-8")

    sidecar.write_text(
        original_sidecar.replace(
            "Index 1 retained path: resolute/main/binary-arm64/Packages.gz",
            "Index 1 retained path: ../escape",
        ),
        encoding="utf-8",
    )
    run(validate_command, fixture.env(), expect=False)
    sidecar.write_text(original_sidecar, encoding="utf-8")

    original_envelope = envelope.read_text(encoding="utf-8")
    envelope.write_text(original_envelope + "Unexpected field: rejected\n", encoding="utf-8")
    run(validate_command, fixture.env(), expect=False)
    run(attached_command, fixture.env(), expect=False)
    envelope.write_text(original_envelope, encoding="utf-8")

    manifest_bytes = manifest.read_bytes()
    manifest.write_bytes(manifest_bytes + b"Unexpected build field: rejected\n")
    run(base_command, fixture.env(), expect=False)
    assert envelope.read_text(encoding="utf-8") == original_envelope
    run(attached_command, fixture.env(), expect=False)
    manifest.write_bytes(manifest_bytes)

    envelope.write_text(
        original_envelope.replace(
            f"Input 3 SHA256: {digest(fixture.oci_raw)}",
            f"Input 3 SHA256: {'0' * 64}",
        ),
        encoding="utf-8",
    )
    run(attached_command, fixture.env(), expect=False)
    envelope.write_text(original_envelope, encoding="utf-8")

    retained_deb = fixture.archives / fixture.debs[0][0]
    retained_deb.write_bytes(retained_deb.read_bytes() + b"tamper")
    run(validate_command, fixture.env(), expect=False)
    retained_deb.write_bytes(fixture.deb_bytes[fixture.debs[0][0]])

    retained_index = fixture.index_cache / "resolute/main/binary-arm64/Packages.gz"
    index_bytes = retained_index.read_bytes()
    retained_index.write_bytes(index_bytes + b"tamper")
    run(validate_command, fixture.env(), expect=False)
    retained_index.write_bytes(index_bytes)

    extra_index_dir = fixture.index_cache / "unexpected-empty-directory"
    extra_index_dir.mkdir()
    extra_dir_result = run(validate_command, fixture.env(), expect=False)
    assert (
        "retained APT index tree is not the exact reviewed 32-file layout"
        in extra_dir_result.stderr
    )
    extra_index_dir.rmdir()

    retained_list = next(
        path for path in fixture.retained_lists.iterdir() if path.name.endswith("main_binary-arm64_Packages.lz4")
    )
    list_bytes = retained_list.read_bytes()
    retained_list.write_bytes(list_bytes + b"tamper")
    run(validate_command, fixture.env(), expect=False)
    retained_list.write_bytes(list_bytes)

    empty_suite, empty_relative = EMPTY_INDEX_PATHS[0].split("/", 1)
    forbidden_empty_view = fixture.retained_lists / (
        "snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_"
        f"{empty_suite}_{empty_relative[:-3].replace('/', '_')}.lz4"
    )
    forbidden_empty_view.write_bytes(b"")
    empty_view_result = run(validate_command, fixture.env(), expect=False)
    assert "retained APT list target set differs from reviewed set" in empty_view_result.stderr
    forbidden_empty_view.unlink()

    pre_inventory = fixture.work / "sp11-apt-installed-pre.txt"
    inventory_bytes = pre_inventory.read_bytes()
    pre_inventory.write_bytes(inventory_bytes + b"extra:arm64=1\n")
    run(validate_command, fixture.env(), expect=False)
    pre_inventory.write_bytes(inventory_bytes)

    local_build_deps = fixture.artifacts / fixture.local_name
    local_bytes = local_build_deps.read_bytes()
    local_build_deps.write_bytes(local_bytes + b"tamper")
    run(validate_command, fixture.env(), expect=False)
    local_build_deps.write_bytes(local_bytes)

    lines = original_envelope.splitlines()
    lines[0], lines[1] = lines[1], lines[0]
    envelope.write_text("\n".join(lines) + "\n", encoding="utf-8")
    run(validate_command, fixture.env(), expect=False)
    envelope.write_text(original_envelope, encoding="utf-8")

    duplicate_oci = json.loads(fixture.oci_raw)
    duplicate_oci["manifests"].append(dict(duplicate_oci["manifests"][0]))
    duplicate_raw = json.dumps(duplicate_oci, separators=(",", ":")).encode()
    duplicate_path = fixture.work / "duplicate-oci.json"
    duplicate_path.write_bytes(duplicate_raw)
    run(
        [
            sys.executable,
            str(OCI_VALIDATOR),
            "--raw-index",
            str(duplicate_path),
            "--index-ref",
            f"ubuntu:26.04@sha256:{digest(duplicate_raw)}",
            "--platform",
            "linux/arm64/v8",
            "--expected-platform-manifest",
            CHILD_DIGEST,
        ],
        fixture.env(),
        expect=False,
    )


def emit_release_template(
    destination: Path, baseline_output: Path, source_head: str, source_ref: str
) -> None:
    if len(source_head) not in (40, 64) or any(character not in "0123456789abcdef" for character in source_head):
        raise SystemExit("source commit must be a full lowercase Git object ID")
    if destination.exists():
        raise SystemExit(f"template destination already exists: {destination}")
    if baseline_output.exists():
        raise SystemExit(f"baseline destination already exists: {baseline_output}")
    fixture = bootstrap_and_finalize(Path(tempfile.gettempdir()).resolve())
    sidecar = fixture.artifacts / "sp11-kernel-apt-provenance.txt"
    run(fixture.writer_command(sidecar), fixture.env())
    (fixture.work / "docker-build-args.txt").write_text(
        "--release-build\n", encoding="utf-8"
    )
    (fixture.work / "docker-build-inside.sh").write_text(
        "#!/usr/bin/env bash\nexit 0\n", encoding="utf-8"
    )
    (fixture.work / "sp11-oci-index.json").write_bytes(fixture.oci_raw)
    baseline_text = fixture.baseline.read_text(encoding="utf-8").replace(
        f'SP11_KERNEL_UPSTREAM_COMMIT="{SOURCE_HEAD}"',
        f'SP11_KERNEL_UPSTREAM_COMMIT="{source_head}"',
    )
    baseline_text = baseline_text.replace(
        'SP11_KERNEL_UPSTREAM_REF="fixture/ref"',
        f'SP11_KERNEL_UPSTREAM_REF="{source_ref}"',
    )
    if f'SP11_KERNEL_UPSTREAM_COMMIT="{source_head}"' not in baseline_text:
        raise AssertionError("could not specialize immutable-APT fixture baseline")
    baseline_output.parent.mkdir(parents=True, exist_ok=True)
    baseline_output.write_text(baseline_text, encoding="utf-8")
    shutil.copytree(fixture.work, destination)


def main() -> None:
    temp_root = Path(tempfile.gettempdir()).resolve()
    try:
        assert_wrapper_contract()
        assert_production_baseline_is_exact(temp_root)
        assert_path_guards(temp_root)
        assert_bootstrap_authentication_failures(temp_root)
        assert_inrelease_empty_entry_contract(temp_root)
        assert_decompressed_empty_index_contract(temp_root)
        assert_full_validator_signed_size_contract(temp_root)
        assert_full_validator_decoder_contract(temp_root)
        fixture = bootstrap_and_finalize(temp_root)
        writer_hostile_cases(fixture)
        envelope_cases(fixture)
        print("immutable APT provenance hostile fixtures passed")
    finally:
        for path in reversed(CREATED_FIXTURES):
            shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) == 6 and sys.argv[1] == "--emit-release-template":
        try:
            emit_release_template(
                Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5]
            )
        finally:
            for path in reversed(CREATED_FIXTURES):
                shutil.rmtree(path, ignore_errors=True)
    elif len(sys.argv) == 1:
        main()
    else:
        raise SystemExit(
            "usage: test-sp11-immutable-apt-provenance.py "
            "[--emit-release-template DESTINATION BASELINE SOURCE_COMMIT SOURCE_REF]"
        )
