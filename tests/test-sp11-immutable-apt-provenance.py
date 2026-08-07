#!/usr/bin/env python3
"""Hostile fixtures for immutable APT acquisition and provenance binding."""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


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
SUPPORT_HEAD = "a" * 40
SOURCE_HEAD = "b" * 40
CHILD_DIGEST = "sha256:" + "c" * 64
CREATED_FIXTURES: list[Path] = []


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
        self.deb_fields = self.root / "deb-fields.tsv"
        self.call_log = self.root / "call.log"
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
        ):
            directory.mkdir(parents=True, exist_ok=True)
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
        self.deb_bytes: dict[str, bytes] = {
            name: f"fixture Deb {package}\n".encode()
            for name, package, _version, _arch in self.debs
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
        rows = [f"{name}\t{package}\t{version}\t{arch}" for name, package, version, arch in self.debs]
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
                        for name, package, version, arch in self.debs
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

    def inrelease_bytes(self, suite: str) -> bytes:
        lines = [
            "-----BEGIN PGP SIGNED MESSAGE-----",
            "Hash: SHA512",
            "",
            "Origin: Ubuntu",
            f"Suite: {suite}",
            "Codename: resolute",
            "Architectures: amd64 arm64",
            "Acquire-By-Hash: yes",
            "SHA256:",
        ]
        for component in COMPONENTS:
            for relative in (
                f"{component}/binary-arm64/Packages.gz",
                f"{component}/source/Sources.gz",
            ):
                compressed = gzip.compress(self.index_raw[(suite, relative)], mtime=0)
                lines.append(f" {digest(compressed)} {len(compressed)} {relative}")
        lines.extend(("-----BEGIN PGP SIGNATURE-----", "fixture", "-----END PGP SIGNATURE-----"))
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
                    compressed = gzip.compress(raw, mtime=0)
                    compressed_digest = digest(compressed)
                    (self.source_indexes / compressed_digest).write_bytes(compressed)
                    list_name = (
                        f"snapshot.ubuntu.com_ubuntu_20260807T000000Z_dists_{suite}_"
                        f"{relative[:-3].replace('/', '_')}.lz4"
                    )
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
            'SP11_APT_BOOTSTRAP_PACKAGE_COUNT="4"',
        ]
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
      case "$package" in evil|linux-qcom-x1e-build-deps) continue ;; esac
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
            """#!/usr/bin/env python3
import hashlib
import os
import sys

path = sys.argv[-1]
with open(path, "rb") as handle:
    value = hashlib.sha256(handle.read()).hexdigest()
with open(os.environ["SP11_TEST_CALL_LOG"], "a", encoding="utf-8") as handle:
    handle.write(f"sha256 {os.path.basename(path)}\\n")
print(f"{value}  {path}")
""",
        )
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
                "PATH": f"{self.mock_bin}:{environment['PATH']}",
                "SP11_APT_FIXTURE_ROOT": str(self.root),
                "SP11_APT_ALLOW_NON_ROOT_FIXTURE": "true",
                "SP11_APT_HELPER": str(self.mock_bin / "apt-helper"),
                "SP11_TEST_LIST_SOURCE": str(self.source_lists),
                "SP11_TEST_INDEX_SOURCE": str(self.source_indexes),
                "SP11_TEST_DEB_SOURCE": str(self.root / "deb-source"),
                "SP11_TEST_DEB_FIELDS": str(self.deb_fields),
                "SP11_TEST_ARCHIVES": str(self.archives),
                "SP11_TEST_CALL_LOG": str(self.call_log),
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
    for required_text in (
        "docker buildx imagetools inspect --raw",
        "/repo/scripts/sp11-immutable-apt.sh bootstrap",
        "/repo/scripts/sp11-immutable-apt.sh finalize",
        "SP11_IMMUTABLE_APT_REQUIRED=true",
        "sp11-kernel-apt-provenance.txt",
        "sp11-kernel-build-inputs.txt",
        "Publication remains closed: schema-v3",
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

    index_downloads = [
        (index, event)
        for index, event in enumerate(events)
        if event.startswith("apt-helper download-file:")
    ]
    assert len(index_downloads) == 32
    assert all(index >= cursor for index, _event in index_downloads)
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
                compressed = gzip.compress(fixture.index_raw[(suite, relative)], mtime=0)
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
                target.write_bytes(gzip.compress(fixture.index_raw[(suite, relative)], mtime=0))
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
                target.write_bytes(gzip.compress(fixture.index_raw[(suite, relative)], mtime=0))
    sidecar = fixture.artifacts / "sp11-kernel-apt-provenance.txt"
    run(fixture.writer_command(sidecar), fixture.env())

    oci = fixture.work / "sp11-oci-index.json"
    oci.write_bytes(fixture.oci_raw)
    build_args = fixture.work / "docker-build-args.txt"
    entrypoint = fixture.work / "docker-build-inside.sh"
    build_args.write_text("--release-build\n", encoding="utf-8")
    entrypoint.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    manifest = fixture.artifacts / "sp11-kernel-build-manifest.txt"
    image_digest = "sha256:" + digest(fixture.oci_raw)
    manifest.write_text(
        "\n".join(
            (
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
                "Build completed: true",
            )
        )
        + "\n",
        encoding="utf-8",
    )
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

    original_sidecar = sidecar.read_text(encoding="utf-8")
    sidecar.write_text(original_sidecar + "Unexpected field: rejected\n", encoding="utf-8")
    run(validate_command, fixture.env(), expect=False)
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

    retained_list = next(
        path for path in fixture.retained_lists.iterdir() if path.name.endswith("main_binary-arm64_Packages.lz4")
    )
    list_bytes = retained_list.read_bytes()
    retained_list.write_bytes(list_bytes + b"tamper")
    run(validate_command, fixture.env(), expect=False)
    retained_list.write_bytes(list_bytes)

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


def main() -> None:
    temp_root = Path(tempfile.gettempdir()).resolve()
    try:
        assert_wrapper_contract()
        assert_production_baseline_is_exact(temp_root)
        assert_path_guards(temp_root)
        assert_bootstrap_authentication_failures(temp_root)
        fixture = bootstrap_and_finalize(temp_root)
        writer_hostile_cases(fixture)
        envelope_cases(fixture)
        print("immutable APT provenance hostile fixtures passed")
    finally:
        for path in reversed(CREATED_FIXTURES):
            shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    main()
