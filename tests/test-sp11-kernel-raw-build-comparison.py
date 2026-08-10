#!/usr/bin/env python3
"""Synthetic matched-pair and hostile fixtures for the raw kernel comparator."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import lzma
import os
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import threading
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from pathlib import Path
from types import ModuleType
from typing import Callable, Iterator


ISOLATION_ERROR = (
    "error: raw comparator hostile fixtures require isolated Python startup"
)
if sys.flags.isolated != 1:
    print(ISOLATION_ERROR, file=sys.stderr)
    raise SystemExit(2)


REPO = Path(__file__).resolve().parents[1]
SOURCE_COMPARATOR = REPO / "scripts/compare-sp11-kernel-raw-builds.py"
APT_FIXTURES = REPO / "tests/test-sp11-immutable-apt-provenance.py"
SUPPORT_FILES = (
    "config/kernel-signing/sp11-module-signing-allowed-unsigned.txt",
    "scripts/compare-sp11-kernel-raw-builds.py",
    "scripts/sp11-kernel-build-inputs.py",
    "scripts/validate-sp11-image-release-manifests.py",
    "scripts/validate-sp11-module-signatures.py",
)
ROLES = ("common-headers", "headers", "image", "modules")
OUTPUTS = (
    ("kernel-config", "debian/build/build-qcom-x1e/.config"),
    ("module-symvers", "debian/build/build-qcom-x1e/Module.symvers"),
    ("system-map", "debian/build/build-qcom-x1e/System.map"),
    (
        "kernel-efi-stubble",
        "debian/build/build-qcom-x1e/arch/arm64/boot/vmlinuz.efi.stubble",
    ),
    (
        "denali-oled-dtb",
        "debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/"
        "x1e80100-microsoft-denali-oled.dtb",
    ),
    (
        "denali-oled-el2-dtb",
        "debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/"
        "x1e80100-microsoft-denali-oled-el2.dtb",
    ),
    (
        "module-signing-certificate",
        "debian/build/build-qcom-x1e/certs/signing_key.x509",
    ),
)
VERSION = "7.2-rc5-jg-0sp11v3r2"
ABI = f"{VERSION}-qcom-x1e"
PACKAGE_IDENTITIES = {
    "common-headers": (f"linux-qcom-x1e-headers-{VERSION}", "all"),
    "headers": (f"linux-headers-{ABI}", "arm64"),
    "image": (f"linux-image-{ABI}", "arm64"),
    "modules": (f"linux-modules-{ABI}", "arm64"),
    "modules-extra": (f"linux-modules-extra-{ABI}", "arm64"),
}
SOURCE_HEAD = "b" * 40
PATCH_PATH = "patches/release/0001-fixture.patch"
PATCH_BYTES = b"synthetic committed patch fixture\n"
GENERIC_ERROR = "error: raw matched-pair input validation failed\n"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_module(path: Path, name: str) -> ModuleType:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise AssertionError(f"could not load fixture module {name}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        specification.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


APT = load_module(APT_FIXTURES, "_sp11_raw_pair_apt_fixture_source")


def ar_member(name: str, data: bytes) -> bytes:
    encoded_name = (name + "/").encode("ascii")
    if len(encoded_name) > 16:
        raise AssertionError("fixture ar name is too long")
    header = b"".join(
        (
            encoded_name.ljust(16, b" "),
            b"0".ljust(12, b" "),
            b"0".ljust(6, b" "),
            b"0".ljust(6, b" "),
            b"100644".ljust(8, b" "),
            str(len(data)).encode("ascii").ljust(10, b" "),
            b"`\n",
        )
    )
    result = header + data
    if len(data) % 2:
        result += b"\n"
    return result


def tar_bytes(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data in files.items():
            item = tarfile.TarInfo(name)
            item.size = len(data)
            item.mode = 0o644
            item.uid = 0
            item.gid = 0
            item.mtime = 0
            archive.addfile(item, io.BytesIO(data))
    return buffer.getvalue()


def deb_bytes(
    package: str,
    version: str,
    architecture: str,
    *,
    payload: bytes = b"fixture payload\n",
    control_compression: str = "tar",
) -> bytes:
    control = (
        f"Package: {package}\n"
        f"Version: {version}\n"
        f"Architecture: {architecture}\n"
        "Maintainer: Fixture <fixture@example.com>\n"
        "Description: bounded raw comparator fixture\n"
    ).encode("utf-8")
    control_tar = tar_bytes({"control": control})
    if control_compression == "tar":
        control_name = "control.tar"
        control_member = control_tar
    elif control_compression == "zst":
        candidates = (
            Path("/usr/bin/zstd"),
            Path("/usr/local/bin/zstd"),
            Path("/opt/homebrew/bin/zstd"),
        )
        program = next((path.resolve() for path in candidates if path.exists()), None)
        if program is None:
            raise AssertionError("host zstd is required for the control.tar.zst fixture")
        completed = subprocess.run(
            [str(program), "--compress", "--stdout", "--quiet"],
            input=control_tar,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        control_name = "control.tar.zst"
        control_member = completed.stdout
    else:
        raise AssertionError(f"unsupported fixture control compression: {control_compression}")
    return b"!<arch>\n" + b"".join(
        (
            ar_member("debian-binary", b"2.0\n"),
            ar_member(control_name, control_member),
            ar_member("data.tar", tar_bytes({"usr/share/fixture": payload})),
        )
    )


def run(
    command: list[str],
    *,
    env: dict[str, str],
    expected: int = 0,
    cwd: Path | None = None,
    preexec_fn: Callable[[], None] | None = None,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=180,
        cwd=cwd,
        preexec_fn=preexec_fn,
    )
    if completed.returncode != expected:
        print(completed.stdout, end="", file=sys.stderr)
        print(completed.stderr, end="", file=sys.stderr)
        raise AssertionError(
            f"unexpected exit {completed.returncode}, expected {expected}: {command[0]}"
        )
    return completed


@contextmanager
def replaced_environment(environment: dict[str, str]) -> Iterator[None]:
    saved = dict(os.environ)
    os.environ.clear()
    os.environ.update(environment)
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(saved)


def invoke_loaded_main(
    comparator: ModuleType, command: list[str], environment: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    assert command[0] == sys.executable and command[1] == "-I"
    stdout = io.StringIO()
    stderr = io.StringIO()
    with replaced_environment(environment), redirect_stdout(stdout), redirect_stderr(stderr):
        return_code = comparator.main(command[3:])
    return subprocess.CompletedProcess(
        command, return_code, stdout.getvalue(), stderr.getvalue()
    )


def git(repo: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


class PairFixture:
    def __init__(self) -> None:
        self.apt = APT.bootstrap_and_finalize(Path(tempfile.gettempdir()).resolve())
        self.root = self.apt.root
        (self.apt.work / "apt-archives/lock").write_bytes(b"")
        self.support = self.root / "support"
        self.support.mkdir()
        for relative in SUPPORT_FILES:
            destination = self.support / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / relative, destination)
        patch = self.support / PATCH_PATH
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_bytes(PATCH_BYTES)
        self.baseline = self.support / "config/kernel-baselines/fixture.env"
        self.baseline.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.apt.baseline, self.baseline)
        git(self.support, "init", "--quiet")
        git(self.support, "add", ".")
        git(
            self.support,
            "-c",
            "user.name=SP11 Fixture",
            "-c",
            "user.email=fixture@example.com",
            "commit",
            "--quiet",
            "-m",
            "fixture support",
        )
        self.support_head = git(self.support, "rev-parse", "--verify", "HEAD^{commit}")
        self.comparator = self.support / "scripts/compare-sp11-kernel-raw-builds.py"

        local = self.apt.artifacts / self.apt.local_name
        local.write_bytes(
            deb_bytes("linux-qcom-x1e-build-deps", "1.0", "arm64", payload=b"build deps\n")
        )
        APT.run(
            self.apt.writer_command(
                self.apt.artifacts / "sp11-kernel-apt-provenance.txt"
            ),
            self.apt.env(),
        )
        self.prepare_work(self.apt.work)
        self.build_a = self.clone(self.apt.work, "private-path-sentinel-a")
        self.build_b = self.clone(self.apt.work, "private-path-sentinel-b")

    def env(self) -> dict[str, str]:
        return self.apt.env()

    def close(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)
        if self.root in APT.CREATED_FIXTURES:
            APT.CREATED_FIXTURES.remove(self.root)

    def clone(self, source: Path, name: str) -> Path:
        destination = self.root / name
        shutil.copytree(source, destination)
        return destination

    def package_roles(self, work: Path) -> tuple[str, ...]:
        artifacts = work / "artifacts"
        roles = list(ROLES)
        extra_package, extra_arch = PACKAGE_IDENTITIES["modules-extra"]
        extra_name = f"{extra_package}_{VERSION}_{extra_arch}.deb"
        if (artifacts / extra_name).exists():
            roles.append("modules-extra")
        return tuple(roles)

    def install_kernel_debs(self, work: Path, roles: tuple[str, ...] = ROLES) -> None:
        artifacts = work / "artifacts"
        for role in roles:
            package, architecture = PACKAGE_IDENTITIES[role]
            name = f"{package}_{VERSION}_{architecture}.deb"
            target = artifacts / name
            if not target.exists():
                target.write_bytes(deb_bytes(package, VERSION, architecture, payload=role.encode()))
        expected = {
            f"{PACKAGE_IDENTITIES[role][0]}_{VERSION}_{PACKAGE_IDENTITIES[role][1]}.deb"
            for role in roles
        }
        for target in artifacts.glob("linux-*.deb"):
            if "-build-deps_" not in target.name and target.name not in expected:
                target.unlink()
        (artifacts / "sp11-kernel-debs.txt").write_text(
            "".join(f"/linux-work/source/{name}\n" for name in sorted(expected)),
            encoding="utf-8",
        )

    def write_manifest(
        self,
        work: Path,
        *,
        output_override: dict[str, tuple[int, str]] | None = None,
        scalar_override: dict[str, str] | None = None,
    ) -> None:
        output_override = output_override or {}
        scalar_override = scalar_override or {}
        artifacts = work / "artifacts"
        roles = self.package_roles(work)
        image_digest = "sha256:" + digest(self.apt.oci_raw)
        patch_sha = digest(PATCH_BYTES)
        lines = [
            "Provenance schema: sp11-kernel-build-v2",
            "Release build: true",
            f"Support start HEAD: {self.support_head}",
            "Support start dirty: false",
            f"Support end HEAD: {self.support_head}",
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
            f"Patch 1 path: {PATCH_PATH}",
            f"Patch 1 SHA256: {patch_sha}",
            "Patch 1 disposition: applied",
            "Patched diff format: git-diff-full-index-binary-v1",
            "Patched diff Git version: git version fixture",
            f"Patched diff SHA256: {'d' * 64}",
            f"Patched tree ID: {SOURCE_HEAD}",
            "Required output roles: kernel-config module-symvers system-map "
            "kernel-efi-stubble denali-oled-dtb denali-oled-el2-dtb "
            "module-signing-certificate",
            "Optional output roles: none",
            f"Output count: {len(OUTPUTS)}",
        ]
        output_identities: dict[str, tuple[int, str]] = {}
        for index, (role, path) in enumerate(OUTPUTS, 1):
            size, output_sha = output_override.get(
                role, (index, digest(f"fixture output {role}\n".encode()))
            )
            output_identities[role] = (size, output_sha)
            lines.extend(
                (
                    f"Output {index} role: {role}",
                    f"Output {index} required: true",
                    f"Output {index} path: {path}",
                    f"Output {index} size: {size}",
                    f"Output {index} SHA256: {output_sha}",
                )
            )
        certificate_sha = output_identities["module-signing-certificate"][1]
        certificate_fingerprint = ":".join(
            certificate_sha.upper()[index : index + 2]
            for index in range(0, len(certificate_sha), 2)
        )
        signature_packages = [role for role in roles if role in ("modules", "modules-extra")]
        unsigned_allowlist_raw = (
            self.support
            / "config/kernel-signing/sp11-module-signing-allowed-unsigned.txt"
        ).read_bytes()
        unsigned_allowlist = unsigned_allowlist_raw.decode("ascii").splitlines()
        unsigned_count = len(unsigned_allowlist)
        unsigned_inventory_sha = digest(unsigned_allowlist_raw)
        signature_report_lines = [
            "# Surface Pro 11 Kernel Module Signature Report",
            "",
            "Schema: sp11-kernel-module-signature-verification-v1",
            f"Kernel ABI: {ABI}",
            f"Package count: {len(signature_packages)}",
        ]
        for index, role in enumerate(signature_packages, 1):
            package, architecture = PACKAGE_IDENTITIES[role]
            filename = f"{package}_{VERSION}_{architecture}.deb"
            raw = (artifacts / filename).read_bytes()
            package_unsigned_count = unsigned_count if role == "modules" else 0
            signature_report_lines.extend(
                (
                    f"Package {index} role: {role}",
                    f"Package {index} file: {filename}",
                    f"Package {index} name: {package}",
                    f"Package {index} version: {VERSION}",
                    f"Package {index} architecture: {architecture}",
                    f"Package {index} size: {len(raw)}",
                    f"Package {index} SHA256: {digest(raw)}",
                    f"Package {index} module count: {1 + package_unsigned_count}",
                    f"Package {index} cryptographically verified signed module count: 1",
                    "Package "
                    f"{index} policy-allowed unsigned module count: {package_unsigned_count}",
                )
            )
        signature_report_lines.extend(
            (
                "Module signing policy: sp11-controlled-rsa4096-sha512-v1",
                "Module signing hash algorithm: sha512",
                f"Module signing certificate SHA256: {certificate_sha}",
                f"Module signing certificate fingerprint: {certificate_fingerprint}",
                "Module signing certificate serial: 01",
                f"Total module count: {len(signature_packages) + unsigned_count}",
                "Cryptographically verified signed module count: "
                f"{len(signature_packages)}",
                f"Policy-allowed unsigned module count: {unsigned_count}",
                "Policy-allowed unsigned module path inventory SHA256: "
                + unsigned_inventory_sha,
                "Validation completed: true",
                "",
                "## Policy-allowed unsigned module paths",
            )
        )
        signature_report_lines.extend(f"- {path}" for path in unsigned_allowlist)
        signature_report_path = artifacts / "sp11-kernel-module-signatures.txt"
        signature_report_path.write_text(
            "\n".join(signature_report_lines) + "\n", encoding="utf-8"
        )
        signature_report_raw = signature_report_path.read_bytes()
        lines.extend(
            (
                "Module signing policy: sp11-controlled-rsa4096-sha512-v1",
                "Module signing private material retained: false",
                f"Signing certificate SHA256: {certificate_sha}",
                f"Signing certificate fingerprint: {certificate_fingerprint}",
                "Signing certificate serial: 01",
                "Kernel module signature report asset: "
                "sp11-kernel-module-signatures.txt",
                f"Kernel module signature report size: {len(signature_report_raw)}",
                "Kernel module signature report SHA256: "
                f"{digest(signature_report_raw)}",
                "Kernel module signature report schema: "
                "sp11-kernel-module-signature-verification-v1",
                "Kernel module total count: "
                f"{len(signature_packages) + unsigned_count}",
                "Kernel module verified signed count: "
                f"{len(signature_packages)}",
                f"Kernel module policy-allowed unsigned count: {unsigned_count}",
                "Kernel module unsigned-path inventory SHA256: "
                + unsigned_inventory_sha,
                "Required Deb roles: common-headers headers image modules",
                "Optional Deb roles: modules-extra",
                f"Deb count: {len(roles)}",
            )
        )
        for index, role in enumerate(roles, 1):
            package, architecture = PACKAGE_IDENTITIES[role]
            filename = f"{package}_{VERSION}_{architecture}.deb"
            raw = (artifacts / filename).read_bytes()
            lines.extend(
                (
                    f"Deb {index} role: {role}",
                    f"Deb {index} required: {'false' if role == 'modules-extra' else 'true'}",
                    f"Deb {index} path: {filename}",
                    f"Deb {index} package: {package}",
                    f"Deb {index} version: {VERSION}",
                    f"Deb {index} architecture: {architecture}",
                    f"Deb {index} size: {len(raw)}",
                    f"Deb {index} SHA256: {digest(raw)}",
                )
            )
        lines.append("Build completed: true")
        for label, value in scalar_override.items():
            prefix = f"{label}: "
            matches = [index for index, line in enumerate(lines) if line.startswith(prefix)]
            if len(matches) != 1:
                raise AssertionError(f"fixture scalar override is ambiguous: {label}")
            lines[matches[0]] = f"{label}: {value}"
        (artifacts / "sp11-kernel-build-manifest.txt").write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )

    def envelope_command(self, work: Path) -> list[str]:
        return [
            sys.executable,
            str(self.support / "scripts/sp11-kernel-build-inputs.py"),
            "write",
            "--baseline",
            str(self.baseline),
            "--work-dir",
            str(work),
            "--support-head",
            self.support_head,
            "--build-args",
            str(work / "docker-build-args.txt"),
            "--entrypoint",
            str(work / "docker-build-inside.sh"),
            "--oci-index",
            str(work / "sp11-oci-index.json"),
            "--build-manifest",
            str(work / "artifacts/sp11-kernel-build-manifest.txt"),
            "--apt-provenance",
            str(work / "artifacts/sp11-kernel-apt-provenance.txt"),
            "--apt-archives-dir",
            str(work / "apt-archives"),
            "--apt-lists-dir",
            str(work / "apt-lists"),
            "--apt-index-cache-dir",
            str(work / "apt-indexes"),
            "--apt-local-build-deps-dir",
            str(work / "artifacts"),
            "--apt-pre-inventory",
            str(work / "sp11-apt-installed-pre.txt"),
            "--apt-post-inventory",
            str(work / "sp11-apt-installed-post.txt"),
            "--output",
            str(work / "artifacts/sp11-kernel-build-inputs.txt"),
        ]

    def regenerate(
        self,
        work: Path,
        *,
        output_override: dict[str, tuple[int, str]] | None = None,
        scalar_override: dict[str, str] | None = None,
    ) -> None:
        envelope = work / "artifacts/sp11-kernel-build-inputs.txt"
        if os.path.lexists(envelope):
            metadata = envelope.lstat()
            assert stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1
            assert work == self.apt.work or work.parent == self.root
            # The clone belongs wholly to this fixture.  Retire only its exact
            # creation-owned envelope before intentionally asking the O_EXCL
            # writer to regenerate it; no product cleanup or overwrite path is
            # weakened by this test plumbing.
            envelope.unlink()
        self.write_manifest(
            work,
            output_override=output_override,
            scalar_override=scalar_override,
        )
        command = self.envelope_command(work)
        run(command, env=self.env())
        metadata = envelope.lstat()
        assert (
            stat.S_ISREG(metadata.st_mode)
            and stat.S_IMODE(metadata.st_mode) == 0o644
            and metadata.st_nlink == 1
            and metadata.st_size > 0
        )
        attached = command.copy()
        attached[2] = "validate-attached"
        run(attached, env=self.env())

    def prepare_work(self, work: Path) -> None:
        self.install_kernel_debs(work)
        (work / "docker-build-args.txt").write_text(
            APT.build_argument_text(), encoding="utf-8"
        )
        (work / "docker-build-inside.sh").write_text(
            "#!/usr/bin/env bash\nexit 0\n", encoding="utf-8"
        )
        (work / "sp11-oci-index.json").write_bytes(self.apt.oci_raw)
        self.regenerate(work)

    def command(self, build_a: Path, build_b: Path) -> list[str]:
        return [
            sys.executable,
            "-I",
            str(self.comparator),
            "--baseline",
            str(self.baseline),
            "--support-repo",
            str(self.support),
            "--support-head",
            self.support_head,
            "--build-a",
            str(build_a),
            "--build-b",
            str(build_b),
        ]

    def compare(
        self, build_a: Path, build_b: Path, *, expected: int
    ) -> subprocess.CompletedProcess[str]:
        return run(self.command(build_a, build_b), env=self.env(), expected=expected)


@contextmanager
def restored_bytes(path: Path) -> Iterator[None]:
    original = path.read_bytes()
    try:
        yield
    finally:
        path.write_bytes(original)


def assert_sanitized_failure(result: subprocess.CompletedProcess[str], fixture: PairFixture) -> None:
    assert result.returncode == 2
    assert result.stdout == ""
    assert result.stderr == GENERIC_ERROR
    assert str(fixture.root) not in result.stderr
    assert "private-path-sentinel" not in result.stderr


def assert_file_identity_rows(
    report: str, label: str, first: Path, second: Path
) -> None:
    first_raw = first.read_bytes()
    second_raw = second.read_bytes()
    for side, raw in (("A", first_raw), ("B", second_raw)):
        assert f"{label} {side} size: {len(raw)}\n" in report
        assert f"{label} {side} SHA256: {digest(raw)}\n" in report


def managed_source_metadata(work: Path) -> tuple[tuple[object, ...], ...]:
    paths = [
        work / "docker-build-args.txt",
        work / "docker-build-inside.sh",
        work / "sp11-oci-index.json",
        work / "sp11-apt-installed-pre.txt",
        work / "sp11-apt-installed-post.txt",
    ]
    for name in ("apt-archives", "apt-indexes", "apt-lists", "artifacts"):
        root = work / name
        paths.append(root)
        paths.extend(sorted(root.rglob("*"), key=lambda path: path.as_posix()))
    rows = []
    for path in paths:
        metadata = path.lstat()
        rows.append(
            (
                path.relative_to(work).as_posix(),
                metadata.st_mode,
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_nlink,
                metadata.st_size,
                metadata.st_mtime_ns,
                metadata.st_ctime_ns,
            )
        )
    return tuple(rows)


def complete_tree_state(root: Path) -> tuple[tuple[object, ...], ...]:
    paths = [root, *sorted(root.rglob("*"), key=lambda path: path.as_posix())]
    rows: list[tuple[object, ...]] = []
    for path in paths:
        metadata = path.lstat()
        if stat.S_ISREG(metadata.st_mode):
            payload_identity = digest(path.read_bytes())
        elif stat.S_ISLNK(metadata.st_mode):
            payload_identity = os.readlink(path)
        else:
            payload_identity = "-"
        rows.append(
            (
                "." if path == root else path.relative_to(root).as_posix(),
                metadata.st_mode,
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_uid,
                metadata.st_gid,
                metadata.st_nlink,
                metadata.st_size,
                metadata.st_mtime_ns,
                metadata.st_ctime_ns,
                payload_identity,
            )
        )
    return tuple(rows)


def positive_and_mismatch_cases(fixture: PairFixture) -> None:
    first = fixture.compare(fixture.build_a, fixture.build_b, expected=0)
    repeated = fixture.compare(fixture.build_a, fixture.build_b, expected=0)
    swapped = fixture.compare(fixture.build_b, fixture.build_a, expected=0)
    assert first.stdout == repeated.stdout == swapped.stdout
    assert first.stderr == repeated.stderr == swapped.stderr == ""
    report = first.stdout
    assert "Kernel raw matched-pair schema: sp11-kernel-raw-matched-pair-v1\n" in report
    assert "Comparison policy: sp11-kernel-zero-normalization-v1\n" in report
    assert "Module signing policy: sp11-controlled-rsa4096-sha512-v1\n" in report
    assert "Module signing private material retained: false\n" in report
    assert "Signing certificate SHA256: " in report
    assert "Signing certificate fingerprint: " in report
    assert "Signing certificate serial: 01\n" in report
    assert (
        "Kernel module signature report schema: "
        "sp11-kernel-module-signature-verification-v1\n" in report
    )
    assert "Kernel module total count: 86\n" in report
    assert "Kernel module verified signed count: 1\n" in report
    assert "Kernel module policy-allowed unsigned count: 85\n" in report
    assert "Kernel package count: 4\n" in report
    assert sum(
        line.startswith("Package ") and line.endswith(" raw identical: true")
        for line in report.splitlines()
    ) == 4
    assert sum(
        line.startswith("Manifest output ")
        and line.endswith(" identity identical: true")
        for line in report.splitlines()
    ) == 7
    assert "Normalization applied: false\n" in report
    assert "Raw differing package count: 0\n" in report
    assert "Raw differing manifest output count: 0\n" in report
    assert "Matched immutable inputs: true\n" in report
    assert "Raw package byte reproducibility: true\n" in report
    assert "Manifest output identity reproducibility: true\n" in report
    assert "P0.4b raw evidence: pass\n" in report
    assert "Publication authorized: false\n" in report
    assert report.endswith("Comparison completed: true\n")
    assert str(fixture.root) not in report
    assert "private-path-sentinel" not in report
    assert f"Source date epoch: {APT.SOURCE_DATE_EPOCH}\n" in report
    assert f"Kbuild build user: {APT.KBUILD_BUILD_USER}\n" in report
    assert f"Kbuild build host: {APT.KBUILD_BUILD_HOST}\n" in report
    assert f"Kbuild build timestamp: {APT.KBUILD_BUILD_TIMESTAMP}\n" in report
    baseline_raw = fixture.baseline.read_bytes()
    assert f"Kernel baseline size: {len(baseline_raw)}\n" in report
    assert f"Kernel baseline SHA256: {digest(baseline_raw)}\n" in report
    assert (
        "Managed retained-input aggregate schema: sp11-managed-tree-sha256-v1\n"
        in report
    )
    assert "Managed retained-input aggregate preimage: ASCII JSON" in report
    assert "Managed retained-input aggregate identical: true\n" in report
    assert (
        "Matched retained-input aggregate schema: "
        "sp11-matched-managed-tree-sha256-v1\n" in report
    )
    assert "Matched retained-input aggregate identical: true\n" in report
    for label, relative in (
        ("Build manifest", "artifacts/sp11-kernel-build-manifest.txt"),
        ("Build-inputs envelope", "artifacts/sp11-kernel-build-inputs.txt"),
        (
            "Kernel module signature report",
            "artifacts/sp11-kernel-module-signatures.txt",
        ),
        ("Docker build arguments", "docker-build-args.txt"),
        ("Docker entrypoint", "docker-build-inside.sh"),
        ("OCI index", "sp11-oci-index.json"),
        ("APT sidecar", "artifacts/sp11-kernel-apt-provenance.txt"),
        ("Pre-install inventory", "sp11-apt-installed-pre.txt"),
        ("Post-install inventory", "sp11-apt-installed-post.txt"),
        ("Local build-deps", f"artifacts/{fixture.apt.local_name}"),
        ("Kernel Deb list", "artifacts/sp11-kernel-debs.txt"),
    ):
        assert_file_identity_rows(
            report, label, fixture.build_a / relative, fixture.build_b / relative
        )

    bilateral_a = fixture.clone(fixture.apt.work, "bilateral-benign-control-a")
    bilateral_b = fixture.clone(fixture.apt.work, "bilateral-benign-control-b")
    bilateral_entrypoint = (
        b"#!/usr/bin/env bash\n# benign bilateral report-identity fixture\nexit 0\n"
    )
    for work in (bilateral_a, bilateral_b):
        (work / "docker-build-inside.sh").write_bytes(bilateral_entrypoint)
        fixture.regenerate(work)
    bilateral = fixture.compare(bilateral_a, bilateral_b, expected=0)
    bilateral_swapped = fixture.compare(bilateral_b, bilateral_a, expected=0)
    assert bilateral.stdout == bilateral_swapped.stdout
    assert bilateral.stderr == bilateral_swapped.stderr == ""
    assert bilateral.stdout != report
    assert "P0.4b raw evidence: pass\n" in bilateral.stdout
    assert_file_identity_rows(
        bilateral.stdout,
        "Docker entrypoint",
        bilateral_a / "docker-build-inside.sh",
        bilateral_b / "docker-build-inside.sh",
    )
    assert str(bilateral_a) not in bilateral.stdout
    assert str(bilateral_b) not in bilateral.stdout

    mismatch = fixture.clone(fixture.apt.work, "raw-mismatch")
    package, architecture = PACKAGE_IDENTITIES["modules"]
    package_path = mismatch / "artifacts" / f"{package}_{VERSION}_{architecture}.deb"
    package_path.write_bytes(
        deb_bytes(package, VERSION, architecture, payload=b"intended raw mismatch\n")
    )
    output_sha = digest(b"intended System.map mismatch\n")
    fixture.regenerate(mismatch, output_override={"system-map": (101, output_sha)})
    failed = fixture.compare(fixture.build_a, mismatch, expected=1)
    failed_swapped = fixture.compare(mismatch, fixture.build_a, expected=1)
    assert failed.stderr == failed_swapped.stderr == ""
    assert failed.stdout == failed_swapped.stdout
    assert "Package 4 raw identical: false\n" in failed.stdout
    assert "Manifest output 3 identity identical: false\n" in failed.stdout
    assert "Raw differing package count: 1\n" in failed.stdout
    assert "Raw differing manifest output count: 1\n" in failed.stdout
    assert "Build manifest raw identical: false\n" in failed.stdout
    assert "Build-inputs envelope raw identical: false\n" in failed.stdout
    assert "Matched immutable inputs: true\n" in failed.stdout
    assert "Raw package byte reproducibility: false\n" in failed.stdout
    assert "Manifest output identity reproducibility: false\n" in failed.stdout
    assert "P0.4b raw evidence: fail\n" in failed.stdout
    assert "Publication authorized: false\n" in failed.stdout
    assert failed.stdout.endswith("Comparison completed: true\n")
    assert str(fixture.root) not in failed.stdout


def artifact_shape_cases(fixture: PairFixture) -> None:
    extra = fixture.clone(fixture.apt.work, "extra-artifact")
    (extra / "artifacts/unexpected.bin").write_bytes(b"unexpected\n")
    assert_sanitized_failure(fixture.compare(extra, fixture.build_b, expected=2), fixture)

    missing = fixture.clone(fixture.apt.work, "missing-artifact")
    package, architecture = PACKAGE_IDENTITIES["headers"]
    (missing / "artifacts" / f"{package}_{VERSION}_{architecture}.deb").unlink()
    assert_sanitized_failure(fixture.compare(missing, fixture.build_b, expected=2), fixture)

    symlink = fixture.clone(fixture.apt.work, "symlink-artifact")
    target = symlink / "artifacts/sp11-kernel-debs.txt"
    target.unlink()
    target.symlink_to("sp11-kernel-build-manifest.txt")
    assert_sanitized_failure(fixture.compare(symlink, fixture.build_b, expected=2), fixture)

    special = fixture.clone(fixture.apt.work, "special-artifact")
    fifo = special / "artifacts/unsafe.fifo"
    os.mkfifo(fifo)
    assert_sanitized_failure(fixture.compare(special, fixture.build_b, expected=2), fixture)

    asymmetric = fixture.clone(fixture.apt.work, "optional-asymmetric")
    fixture.install_kernel_debs(asymmetric, (*ROLES, "modules-extra"))
    fixture.regenerate(asymmetric)
    assert_sanitized_failure(
        fixture.compare(asymmetric, fixture.build_b, expected=2), fixture
    )

    bounded = fixture.clone(fixture.apt.work, "bounded-artifact-scan")
    for index in range(20):
        (bounded / "artifacts" / f"unexpected-{index:02d}.bin").write_bytes(b"x")
    assert_sanitized_failure(
        fixture.compare(bounded, fixture.build_b, expected=2), fixture
    )

    shared = fixture.clone(fixture.apt.work, "shared-retained-inode")
    relative = Path("apt-indexes/resolute/main/binary-arm64/Packages.gz")
    target = shared / relative
    target.unlink()
    os.link(fixture.build_b / relative, target)
    assert_sanitized_failure(
        fixture.compare(shared, fixture.build_b, expected=2), fixture
    )


def provenance_and_control_cases(fixture: PairFixture) -> None:
    manifest = fixture.build_a / "artifacts/sp11-kernel-build-manifest.txt"
    with restored_bytes(manifest):
        manifest.write_text(
            manifest.read_text(encoding="utf-8").replace(
                f"Source HEAD: {SOURCE_HEAD}", f"Source HEAD: {'c' * 40}"
            ),
            encoding="utf-8",
        )
        assert_sanitized_failure(
            fixture.compare(fixture.build_a, fixture.build_b, expected=2), fixture
        )

    with restored_bytes(manifest):
        manifest.write_text(
            manifest.read_text(encoding="utf-8").replace(
                f"Patch 1 SHA256: {digest(PATCH_BYTES)}",
                f"Patch 1 SHA256: {'0' * 64}",
            ),
            encoding="utf-8",
        )
        assert_sanitized_failure(
            fixture.compare(fixture.build_a, fixture.build_b, expected=2), fixture
        )

    envelope = fixture.build_a / "artifacts/sp11-kernel-build-inputs.txt"
    with restored_bytes(envelope):
        text = envelope.read_text(encoding="utf-8")
        old = next(line for line in text.splitlines() if line.startswith("Input 1 SHA256: "))
        envelope.write_text(text.replace(old, f"Input 1 SHA256: {'0' * 64}"), encoding="utf-8")
        assert_sanitized_failure(
            fixture.compare(fixture.build_a, fixture.build_b, expected=2), fixture
        )

    sidecar = fixture.build_a / "artifacts/sp11-kernel-apt-provenance.txt"
    for old_prefix, replacement in (
        ("Snapshot ID: ", "Snapshot ID: 20990101T000000Z"),
        ("Index 1 path: ", "Index 1 path: ../private-path-sentinel"),
        ("Index 1 SHA256: ", f"Index 1 SHA256: {'0' * 64}"),
    ):
        with restored_bytes(sidecar):
            lines = sidecar.read_text(encoding="utf-8").splitlines()
            index = next(i for i, line in enumerate(lines) if line.startswith(old_prefix))
            lines[index] = replacement
            sidecar.write_text("\n".join(lines) + "\n", encoding="utf-8")
            result = fixture.compare(fixture.build_a, fixture.build_b, expected=2)
            assert_sanitized_failure(result, fixture)
            assert "private-path-sentinel" not in result.stderr

    build_arguments = fixture.build_a / "docker-build-args.txt"
    with restored_bytes(build_arguments):
        build_arguments.write_bytes(
            build_arguments.read_bytes() + b"private-content-sentinel\n"
        )
        result = fixture.compare(fixture.build_a, fixture.build_b, expected=2)
        assert_sanitized_failure(result, fixture)
        assert "private-content-sentinel" not in result.stderr

    pre_inventory = fixture.build_a / "sp11-apt-installed-pre.txt"
    with restored_bytes(pre_inventory):
        pre_inventory.write_bytes(pre_inventory.read_bytes() + b"extra:arm64=1\n")
        assert_sanitized_failure(
            fixture.compare(fixture.build_a, fixture.build_b, expected=2), fixture
        )

    local = fixture.build_a / "artifacts" / fixture.apt.local_name
    with restored_bytes(local):
        local.write_bytes(local.read_bytes() + b"tamper\n")
        assert_sanitized_failure(
            fixture.compare(fixture.build_a, fixture.build_b, expected=2), fixture
        )

    retained = fixture.build_a / "apt-indexes/resolute/main/binary-arm64/Packages.gz"
    with restored_bytes(retained):
        retained.write_bytes(retained.read_bytes() + b"tamper\n")
        assert_sanitized_failure(
            fixture.compare(fixture.build_a, fixture.build_b, expected=2), fixture
        )

    baseline_original = fixture.baseline.read_bytes()
    try:
        fixture.baseline.write_bytes(baseline_original + b"# dirty baseline\n")
        assert_sanitized_failure(
            fixture.compare(fixture.build_a, fixture.build_b, expected=2), fixture
        )
    finally:
        fixture.baseline.write_bytes(baseline_original)
    assert git(fixture.support, "status", "--porcelain") == ""

    wrong_control = fixture.clone(fixture.apt.work, "wrong-deb-control")
    package, architecture = PACKAGE_IDENTITIES["common-headers"]
    target = wrong_control / "artifacts" / f"{package}_{VERSION}_{architecture}.deb"
    target.write_bytes(deb_bytes("wrong-package", VERSION, architecture))
    fixture.regenerate(wrong_control)
    assert_sanitized_failure(
        fixture.compare(wrong_control, fixture.build_b, expected=2), fixture
    )

    huge_patch_count = fixture.clone(fixture.apt.work, "huge-patch-count")
    huge_manifest = huge_patch_count / "artifacts/sp11-kernel-build-manifest.txt"
    huge_manifest.write_text(
        huge_manifest.read_text(encoding="utf-8").replace(
            "Patch count: 1", "Patch count: 99999999999999999999"
        ),
        encoding="utf-8",
    )
    bounded_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_patch_count_bound_fixture_target"
    )
    helper_calls: list[object] = []

    def record_forbidden_helper(*arguments: object, **keywords: object) -> None:
        helper_calls.append((arguments, keywords))
        raise AssertionError("committed helper ran before the patch-count bound")

    bounded_comparator.validate_retained_inputs = record_forbidden_helper
    bounded_result = invoke_loaded_main(
        bounded_comparator,
        fixture.command(huge_patch_count, fixture.build_b),
        fixture.env(),
    )
    assert_sanitized_failure(bounded_result, fixture)
    assert helper_calls == []

    lock_a = fixture.clone(fixture.apt.work, "apt-archive-lock-mismatch-a")
    lock_b = fixture.clone(fixture.apt.work, "apt-archive-lock-mismatch-b")
    (lock_a / "apt-archives/lock").write_bytes(b"A")
    (lock_b / "apt-archives/lock").write_bytes(b"B")
    lock_result = fixture.compare(lock_a, lock_b, expected=2)
    assert_sanitized_failure(lock_result, fixture)


def race_case(fixture: PairFixture) -> None:
    comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_race_fixture_target"
    )
    original_validator = comparator.validate_retained_inputs
    target = fixture.build_a / "artifacts/sp11-kernel-debs.txt"
    original_bytes = target.read_bytes()
    mutated = False
    private_views: list[Path] = []

    def record_private_view(tree: object):
        private_views.append(tree.private.path)
        return None

    def mutate_after_validation(*arguments: object, **keywords: object) -> None:
        nonlocal mutated
        original_validator(*arguments, **keywords)
        if not mutated:
            target.write_bytes(original_bytes + b"/private/race-sentinel.deb\n")
            mutated = True

    comparator.validate_retained_inputs = mutate_after_validation
    comparator.managed_snapshot_barrier = record_private_view
    saved_environment = dict(os.environ)
    fixture_environment = fixture.env()
    os.environ.clear()
    os.environ.update(fixture_environment)
    try:
        try:
            comparator.compare_pair(
                fixture.baseline,
                fixture.support,
                fixture.support_head,
                fixture.build_a,
                fixture.build_b,
            )
        except comparator.ValidationError:
            pass
        else:
            raise AssertionError("mid-comparison artifact mutation was accepted")
    finally:
        target.write_bytes(original_bytes)
        for path in private_views:
            if path.exists():
                shutil.rmtree(path)
        os.environ.clear()
        os.environ.update(saved_environment)
    assert mutated


def baseline_report_sanitization_cases(fixture: PairFixture) -> None:
    cases = (
        ("nul", b"# BASELINE-NUL-SENTINEL\x00\n", "BASELINE-NUL-SENTINEL"),
        ("escape", b"# BASELINE-ESC-SENTINEL\x1b\n", "BASELINE-ESC-SENTINEL"),
        (
            "nonascii",
            b"# BASELINE-NONASCII-SENTINEL\xc3\xa9\n",
            "BASELINE-NONASCII-SENTINEL",
        ),
    )
    for label, hostile, sentinel in cases:
        support = fixture.root / f"committed-hostile-baseline-{label}"
        shutil.copytree(fixture.support, support)
        baseline = support / fixture.baseline.relative_to(fixture.support)
        baseline.write_bytes(baseline.read_bytes() + hostile)
        git(support, "add", baseline.relative_to(support).as_posix())
        git(
            support,
            "-c",
            "user.name=SP11 Fixture",
            "-c",
            "user.email=fixture@example.com",
            "commit",
            "--quiet",
            "-m",
            f"hostile baseline {label}",
        )
        support_head = git(support, "rev-parse", "--verify", "HEAD^{commit}")
        command = [
            sys.executable,
            "-I",
            str(support / "scripts/compare-sp11-kernel-raw-builds.py"),
            "--baseline",
            str(baseline),
            "--support-repo",
            str(support),
            "--support-head",
            support_head,
            "--build-a",
            str(fixture.build_a),
            "--build-b",
            str(fixture.build_b),
        ]
        result = run(command, env=fixture.env(), expected=2)
        assert_sanitized_failure(result, fixture)
        assert sentinel not in result.stdout
        assert sentinel not in result.stderr


def committed_code_swap_case(fixture: PairFixture) -> None:
    comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_code_swap_fixture_target"
    )
    swapped = False
    preserved: Path | None = None

    def swap_after_read(
        binding: object, relative: str
    ):  # Return type is deliberately duck-typed across the loaded module.
        nonlocal swapped, preserved
        if swapped or relative != "scripts/sp11-kernel-build-inputs.py":
            return None
        snapshot_repo = binding.snapshot_repo
        preserved = binding.snapshot_private.path
        target = snapshot_repo / relative
        original = target.read_bytes()
        target.chmod(0o600)
        target.write_text(
            "raise RuntimeError('A/B/A implementation swap executed')\n",
            encoding="utf-8",
        )
        swapped = True

        def restore() -> None:
            target.write_bytes(original)
            target.chmod(0o400)

        return restore

    comparator.snapshot_source_read_barrier = swap_after_read
    try:
        with replaced_environment(fixture.env()):
            try:
                comparator.compare_pair(
                    fixture.baseline,
                    fixture.support,
                    fixture.support_head,
                    fixture.build_a,
                    fixture.build_b,
                )
            except comparator.ValidationError:
                pass
            else:
                raise AssertionError("committed validator A/B/A swap was accepted")
    finally:
        if preserved is not None:
            assert preserved.exists()
            shutil.rmtree(preserved)
    assert swapped


def report_time_race_case(fixture: PairFixture) -> None:
    comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_report_race_fixture_target"
    )
    saved_environment = dict(os.environ)
    fixture_environment = fixture.env()
    os.environ.clear()
    os.environ.update(fixture_environment)
    result = None
    target = fixture.build_a / "artifacts/sp11-kernel-debs.txt"
    original_bytes = target.read_bytes()
    original_render = comparator.render_report
    mutated = False

    def mutate_after_render(comparison: object) -> str:
        nonlocal mutated
        report = original_render(comparison)
        target.write_bytes(original_bytes + b"/private/report-race.deb\n")
        mutated = True
        return report

    comparator.render_report = mutate_after_render
    try:
        result = comparator.compare_pair(
            fixture.baseline,
            fixture.support,
            fixture.support_head,
            fixture.build_a,
            fixture.build_b,
        )
        try:
            comparator.render_verified_report(result)
        except comparator.ValidationError:
            pass
        else:
            raise AssertionError("report-time artifact mutation was accepted")
    finally:
        target.write_bytes(original_bytes)
        if result is not None:
            preserved = [
                build.managed.private.path
                for build in (result.first, result.second)
            ]
            try:
                comparator.close_comparison(result)
            except comparator.ValidationError:
                pass
            for path in preserved:
                if path.exists():
                    shutil.rmtree(path)
        os.environ.clear()
        os.environ.update(saved_environment)
    assert mutated


def retained_view_aba_cases(fixture: PairFixture) -> None:
    baseline_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_baseline_aba_fixture_target"
    )
    baseline_swapped = False
    baseline_private: Path | None = None

    def swap_baseline(binding: object):
        nonlocal baseline_swapped, baseline_private
        if baseline_swapped:
            return None
        target = binding.snapshot_baseline
        backup = target.with_name(target.name + ".aba-original")
        target.rename(backup)
        target.write_text(
            'SP11_KERNEL_BASELINE_ID="private-baseline-sentinel"\n',
            encoding="utf-8",
        )
        baseline_private = binding.snapshot_private.path
        baseline_swapped = True

        def restore() -> None:
            target.unlink()
            backup.rename(target)

        return restore

    baseline_comparator.baseline_validation_barrier = swap_baseline
    try:
        with replaced_environment(fixture.env()):
            try:
                baseline_comparator.compare_pair(
                    fixture.baseline,
                    fixture.support,
                    fixture.support_head,
                    fixture.build_a,
                    fixture.build_b,
                )
            except baseline_comparator.ValidationError:
                pass
            else:
                raise AssertionError("committed baseline A/B/A swap was accepted")
    finally:
        if baseline_private is not None:
            assert baseline_private.exists()
            shutil.rmtree(baseline_private)
    assert baseline_swapped

    nested_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_nested_aba_fixture_target"
    )
    nested_swapped = False
    nested_private: Path | None = None

    def swap_nested(tree: object):
        nonlocal nested_swapped, nested_private
        if nested_swapped or tree.source_path != fixture.build_a:
            return None
        target = tree.source_path / "apt-indexes/resolute/main/binary-arm64/Packages.gz"
        backup = target.with_name(target.name + ".aba-original")
        target.rename(backup)
        target.write_bytes(b"private nested retained-input sentinel\n")
        nested_private = tree.private.path
        nested_swapped = True

        def restore() -> None:
            target.unlink()
            backup.rename(target)

        return restore

    nested_comparator.managed_snapshot_barrier = swap_nested
    try:
        with replaced_environment(fixture.env()):
            try:
                nested_comparator.compare_pair(
                    fixture.baseline,
                    fixture.support,
                    fixture.support_head,
                    fixture.build_a,
                    fixture.build_b,
                )
            except nested_comparator.ValidationError:
                pass
            else:
                raise AssertionError("nested retained-input A/B/A swap was accepted")
    finally:
        if nested_private is not None:
            assert nested_private.exists()
            shutil.rmtree(nested_private)
    assert nested_swapped


def private_support_setup_victim_case(fixture: PairFixture) -> None:
    comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_support_setup_victim_fixture_target"
    )
    victim = fixture.root / "private-support-setup-victim"
    victim.mkdir()
    sentinel = victim / "victim-sentinel"
    sentinel.write_text("preserve victim data\n", encoding="utf-8")
    replacement: Path | None = None
    preserved_original: Path | None = None

    def replace_root_before_setup(tree: object) -> None:
        nonlocal replacement, preserved_original
        if replacement is not None:
            return
        replacement = tree.path
        preserved_original = tree.path.with_name(
            tree.path.name + ".setup-preserved"
        )
        tree.path.rename(preserved_original)
        tree.path.symlink_to(victim, target_is_directory=True)

    comparator.private_support_setup_barrier = replace_root_before_setup
    try:
        result = invoke_loaded_main(
            comparator,
            fixture.command(fixture.build_a, fixture.build_b),
            fixture.env(),
        )
        assert_sanitized_failure(result, fixture)
        assert replacement is not None and preserved_original is not None
        assert replacement.is_symlink()
        assert sentinel.read_text(encoding="utf-8") == "preserve victim data\n"
        assert not (victim / "support").exists()
        assert (
            preserved_original / "support/scripts/sp11-kernel-build-inputs.py"
        ).is_file()
    finally:
        if replacement is not None and replacement.is_symlink():
            replacement.unlink()
        if preserved_original is not None and preserved_original.exists():
            shutil.rmtree(preserved_original)
        shutil.rmtree(victim)


def failed_setup_subtree_preservation_cases(fixture: PairFixture) -> None:
    support_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_support_setup_subtree_fixture_target"
    )
    support_victim_parent = fixture.root / "support-setup-moved-victim-parent"
    support_victim = support_victim_parent / "victim"
    support_victim.mkdir(parents=True)
    support_sentinel = support_victim / "do-not-delete"
    support_sentinel.write_text("preserve moved support victim\n", encoding="utf-8")
    support_private: Path | None = None
    support_injected: Path | None = None

    def inject_support_subtree(tree: object) -> None:
        nonlocal support_private, support_injected
        if support_private is not None:
            return
        support_private = tree.path
        support_injected = tree.path / "same-uid-moved-victim"
        support_victim.rename(support_injected)

    support_comparator.private_support_setup_barrier = inject_support_subtree
    try:
        support_result = invoke_loaded_main(
            support_comparator,
            fixture.command(fixture.build_a, fixture.build_b),
            fixture.env(),
        )
        assert_sanitized_failure(support_result, fixture)
        assert support_private is not None and support_injected is not None
        assert support_private.is_dir()
        assert support_injected.is_dir()
        assert (support_injected / "do-not-delete").read_text(encoding="utf-8") == (
            "preserve moved support victim\n"
        )
        assert {path.name for path in support_private.iterdir()} == {
            "same-uid-moved-victim"
        }
    finally:
        if support_private is not None and support_private.exists():
            shutil.rmtree(support_private)
        if support_victim_parent.exists():
            shutil.rmtree(support_victim_parent)

    seal_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_support_seal_subtree_fixture_target"
    )
    seal_victim_parent = fixture.root / "support-seal-moved-victim-parent"
    seal_victim = seal_victim_parent / "victim"
    seal_victim.mkdir(parents=True)
    (seal_victim / "do-not-delete").write_text(
        "preserve post-tool-copy victim\n", encoding="utf-8"
    )
    seal_private: Path | None = None
    seal_injected: Path | None = None

    def inject_after_tool_copy(tree: object) -> None:
        nonlocal seal_private, seal_injected
        if seal_private is not None:
            return
        seal_private = tree.path
        seal_injected = tree.path / "bound-tools/same-uid-moved-victim"
        seal_victim.rename(seal_injected)

    seal_comparator.private_support_seal_barrier = inject_after_tool_copy
    try:
        seal_result = invoke_loaded_main(
            seal_comparator,
            fixture.command(fixture.build_a, fixture.build_b),
            fixture.env(),
        )
        assert_sanitized_failure(seal_result, fixture)
        assert seal_private is not None and seal_injected is not None
        assert seal_private.is_dir()
        assert (seal_injected / "do-not-delete").read_text(encoding="utf-8") == (
            "preserve post-tool-copy victim\n"
        )
        assert not (seal_private / "support").exists()
        assert {path.name for path in seal_private.iterdir()} == {"bound-tools"}
        assert {
            path.name for path in (seal_private / "bound-tools").iterdir()
        } == {"same-uid-moved-victim"}
    finally:
        if seal_private is not None and seal_private.exists():
            shutil.rmtree(seal_private)
        if seal_victim_parent.exists():
            shutil.rmtree(seal_victim_parent)

    replacement_comparator = load_module(
        fixture.comparator,
        "_sp11_raw_pair_support_expected_name_replacement_fixture_target",
    )
    replacement_parent = fixture.root / "support-expected-name-victim-parent"
    replacement_parent.mkdir()
    replacement_victim = replacement_parent / "victim-helper.py"
    replacement_sentinel = b"EXPECTED-NAME-VICTIM-MUST-SURVIVE\n"
    replacement_victim.write_bytes(replacement_sentinel)
    replacement_backup = replacement_parent / "owned-helper-backup.py"
    replacement_private: Path | None = None
    replacement_target: Path | None = None

    def replace_expected_owned_name(tree: object) -> None:
        nonlocal replacement_private, replacement_target
        if replacement_private is not None:
            return
        replacement_private = tree.path
        replacement_target = (
            tree.path / "support/scripts/sp11-kernel-build-inputs.py"
        )
        replacement_target.rename(replacement_backup)
        replacement_victim.rename(replacement_target)

    replacement_comparator.private_support_seal_barrier = (
        replace_expected_owned_name
    )
    try:
        replacement_result = invoke_loaded_main(
            replacement_comparator,
            fixture.command(fixture.build_a, fixture.build_b),
            fixture.env(),
        )
        assert_sanitized_failure(replacement_result, fixture)
        assert replacement_private is not None and replacement_target is not None
        assert replacement_private.is_dir()
        assert replacement_target.read_bytes() == replacement_sentinel
        assert replacement_backup.is_file()
        assert not (replacement_private / "bound-tools").exists()
        assert {path.name for path in replacement_private.iterdir()} == {"support"}
        assert {
            path.name for path in (replacement_private / "support/scripts").iterdir()
        } == {"sp11-kernel-build-inputs.py"}
    finally:
        if replacement_private is not None and replacement_private.exists():
            shutil.rmtree(replacement_private)
        if replacement_parent.exists():
            shutil.rmtree(replacement_parent)

    fifo_comparator = load_module(
        fixture.comparator,
        "_sp11_raw_pair_support_expected_name_fifo_fixture_target",
    )
    fifo_parent = fixture.root / "support-expected-name-fifo-parent"
    fifo_parent.mkdir()
    fifo_backup = fifo_parent / "owned-helper-backup.py"
    fifo_private: Path | None = None
    fifo_target: Path | None = None
    fifo_ready = threading.Event()
    fifo_results: list[subprocess.CompletedProcess[str]] = []
    fifo_errors: list[BaseException] = []

    def replace_expected_owned_name_with_fifo(tree: object) -> None:
        nonlocal fifo_private, fifo_target
        if fifo_private is not None:
            return
        fifo_private = tree.path
        fifo_target = tree.path / "support/scripts/sp11-kernel-build-inputs.py"
        fifo_target.rename(fifo_backup)
        os.mkfifo(fifo_target, 0o600)
        fifo_ready.set()

    def invoke_fifo_case() -> None:
        try:
            command = fixture.command(fixture.build_a, fixture.build_b)
            with replaced_environment(fixture.env()):
                try:
                    unexpected = fifo_comparator.compare_pair(
                        fixture.baseline,
                        fixture.support,
                        fixture.support_head,
                        fixture.build_a,
                        fixture.build_b,
                    )
                except Exception:
                    fifo_results.append(
                        subprocess.CompletedProcess(
                            command,
                            2,
                            "",
                            GENERIC_ERROR,
                        )
                    )
                else:
                    try:
                        fifo_comparator.close_comparison(unexpected)
                    finally:
                        raise AssertionError(
                            "expected-name FIFO fixture was accepted"
                        )
        except BaseException as exc:
            fifo_errors.append(exc)

    fifo_comparator.private_support_seal_barrier = (
        replace_expected_owned_name_with_fifo
    )
    fifo_worker = threading.Thread(target=invoke_fifo_case, daemon=True)
    try:
        fifo_worker.start()
        assert fifo_ready.wait(timeout=15)
        fifo_worker.join(timeout=10)
        blocked = fifo_worker.is_alive()
        if blocked:
            assert fifo_target is not None
            writer = os.open(
                fifo_target,
                os.O_WRONLY | getattr(os, "O_NONBLOCK", 0),
            )
            os.close(writer)
            fifo_worker.join(timeout=10)
        assert not blocked, "partial cleanup blocked while probing an expected-name FIFO"
        assert not fifo_worker.is_alive()
        assert fifo_errors == []
        assert len(fifo_results) == 1
        assert_sanitized_failure(fifo_results[0], fixture)
        assert fifo_private is not None and fifo_target is not None
        assert stat.S_ISFIFO(fifo_target.lstat().st_mode)
        assert fifo_backup.is_file()
        assert not (fifo_private / "bound-tools").exists()
        assert {path.name for path in fifo_private.iterdir()} == {"support"}
    finally:
        if fifo_worker.is_alive() and fifo_target is not None:
            try:
                writer = os.open(
                    fifo_target,
                    os.O_WRONLY | getattr(os, "O_NONBLOCK", 0),
                )
                os.close(writer)
            except OSError:
                pass
            fifo_worker.join(timeout=10)
        if fifo_private is not None and fifo_private.exists():
            shutil.rmtree(fifo_private)
        if fifo_parent.exists():
            shutil.rmtree(fifo_parent)

    special_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_support_late_special_fixture_target"
    )
    special_private: Path | None = None
    special_path: Path | None = None

    def inject_late_special(tree: object) -> None:
        nonlocal special_private, special_path
        if special_private is not None:
            return
        special_private = tree.path
        special_path = tree.path / "bound-tools/late-special-entry"
        os.mkfifo(special_path, 0o600)

    special_comparator.private_support_seal_barrier = inject_late_special
    try:
        special_result = invoke_loaded_main(
            special_comparator,
            fixture.command(fixture.build_a, fixture.build_b),
            fixture.env(),
        )
        assert_sanitized_failure(special_result, fixture)
        assert special_private is not None and special_path is not None
        assert special_private.is_dir()
        assert stat.S_ISFIFO(special_path.lstat().st_mode)
        assert not (special_private / "support").exists()
        assert {path.name for path in special_private.iterdir()} == {"bound-tools"}
        assert {
            path.name for path in (special_private / "bound-tools").iterdir()
        } == {"late-special-entry"}
    finally:
        if special_path is not None and special_path.exists():
            special_path.unlink()
        if special_private is not None and special_private.exists():
            shutil.rmtree(special_private)

    retained_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_retained_setup_subtree_fixture_target"
    )
    retained_victim_parent = fixture.root / "retained-setup-moved-victim-parent"
    retained_victim = retained_victim_parent / "victim"
    retained_victim.mkdir(parents=True)
    retained_sentinel = retained_victim / "do-not-delete"
    retained_sentinel.write_text("preserve moved retained victim\n", encoding="utf-8")
    retained_private: object | None = None
    retained_injected: Path | None = None
    original_create = retained_comparator.PrivateTree.create
    original_populate = retained_comparator._populate_managed_view

    def record_private_create(
        cls: object, parent: Path, prefix: str, label: str
    ) -> object:
        nonlocal retained_private
        tree = original_create(parent, prefix, label)
        if label == "private retained-input view":
            retained_private = tree
        return tree

    def inject_retained_subtree(*arguments: object, **keywords: object) -> None:
        nonlocal retained_injected
        original_populate(*arguments, **keywords)
        if retained_injected is not None:
            return
        assert retained_private is not None
        retained_injected = retained_private.path / "same-uid-moved-victim"
        retained_victim.rename(retained_injected)

    retained_comparator.PrivateTree.create = classmethod(record_private_create)
    retained_comparator._populate_managed_view = inject_retained_subtree
    try:
        retained_result = invoke_loaded_main(
            retained_comparator,
            fixture.command(fixture.build_a, fixture.build_b),
            fixture.env(),
        )
        assert_sanitized_failure(retained_result, fixture)
        assert retained_private is not None and retained_injected is not None
        assert retained_private.path.is_dir()
        assert retained_injected.is_dir()
        assert (retained_injected / "do-not-delete").read_text(encoding="utf-8") == (
            "preserve moved retained victim\n"
        )
        assert {path.name for path in retained_private.path.iterdir()} == {
            "same-uid-moved-victim"
        }
    finally:
        if retained_private is not None and retained_private.path.exists():
            shutil.rmtree(retained_private.path)
        if retained_victim_parent.exists():
            shutil.rmtree(retained_victim_parent)


def cleanup_drift_cases(fixture: PairFixture) -> None:
    normal_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_cleanup_success_fixture_target"
    )
    cleaned_paths: list[Path] = []

    def record_normal_cleanup(tree: object) -> None:
        cleaned_paths.append(tree.path)

    normal_comparator.private_cleanup_barrier = record_normal_cleanup
    normal_comparator._try_cow_copy = lambda *_arguments, **_keywords: None
    before_a = managed_source_metadata(fixture.build_a)
    before_b = managed_source_metadata(fixture.build_b)
    fixture_root_mode = stat.S_IMODE(fixture.root.stat().st_mode)
    fixture.root.chmod(fixture_root_mode & ~0o222)
    try:
        normal = invoke_loaded_main(
            normal_comparator,
            fixture.command(fixture.build_a, fixture.build_b),
            fixture.env(),
        )
    finally:
        fixture.root.chmod(fixture_root_mode)
    assert normal.returncode == 0
    assert normal.stderr == ""
    assert normal.stdout.endswith("Comparison completed: true\n")
    assert len(cleaned_paths) == 3
    assert all(not path.exists() for path in cleaned_paths)
    assert managed_source_metadata(fixture.build_a) == before_a
    assert managed_source_metadata(fixture.build_b) == before_b

    addition_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_cleanup_addition_fixture_target"
    )
    addition_private: Path | None = None

    def add_before_cleanup(tree: object) -> None:
        nonlocal addition_private
        if addition_private is not None or tree.label != "private retained-input view":
            return
        addition_private = tree.path
        (tree.path / "unexpected-cleanup-sentinel").write_text(
            "preserve unexpected cleanup data\n", encoding="utf-8"
        )

    addition_comparator.private_cleanup_barrier = add_before_cleanup
    added = invoke_loaded_main(
        addition_comparator,
        fixture.command(fixture.build_a, fixture.build_b),
        fixture.env(),
    )
    assert_sanitized_failure(added, fixture)
    assert addition_private is not None
    assert (addition_private / "unexpected-cleanup-sentinel").is_file()
    shutil.rmtree(addition_private)

    replacement_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_cleanup_replacement_fixture_target"
    )
    replacement: Path | None = None
    preserved_original: Path | None = None

    def replace_before_cleanup(tree: object) -> None:
        nonlocal replacement, preserved_original
        if replacement is not None or tree.label != "private support snapshot":
            return
        replacement = tree.path
        preserved_original = tree.path.with_name(
            tree.path.name + ".unexpected-preserved"
        )
        tree.path.rename(preserved_original)
        tree.path.mkdir(mode=0o700)
        (tree.path / "replacement-cleanup-sentinel").write_text(
            "preserve replacement data\n", encoding="utf-8"
        )

    replacement_comparator.private_cleanup_barrier = replace_before_cleanup
    replaced = invoke_loaded_main(
        replacement_comparator,
        fixture.command(fixture.build_a, fixture.build_b),
        fixture.env(),
    )
    assert_sanitized_failure(replaced, fixture)
    assert replacement is not None and preserved_original is not None
    assert (replacement / "replacement-cleanup-sentinel").is_file()
    assert preserved_original.is_dir()
    shutil.rmtree(replacement)
    shutil.rmtree(preserved_original)

    final_comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_cleanup_final_swap_fixture_target"
    )
    final_replacement: Path | None = None
    final_preserved: Path | None = None

    def replace_after_exact_delete(tree: object) -> None:
        nonlocal final_replacement, final_preserved
        if final_replacement is not None or tree.label != "private support snapshot":
            return
        final_replacement = tree.path
        final_preserved = tree.path.with_name(tree.path.name + ".final-preserved")
        tree.path.rename(final_preserved)
        tree.path.mkdir(mode=0o700)
        (tree.path / "final-remove-victim-sentinel").write_text(
            "preserve final replacement data\n", encoding="utf-8"
        )

    final_comparator.private_final_remove_barrier = replace_after_exact_delete
    final_result = invoke_loaded_main(
        final_comparator,
        fixture.command(fixture.build_a, fixture.build_b),
        fixture.env(),
    )
    assert_sanitized_failure(final_result, fixture)
    assert final_replacement is not None and final_preserved is not None
    assert (final_replacement / "final-remove-victim-sentinel").is_file()
    assert final_preserved.is_dir()
    shutil.rmtree(final_replacement)
    shutil.rmtree(final_preserved)


def private_ownership_bound_cases(fixture: PairFixture) -> None:
    comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_private_ownership_bound_fixture_target"
    )
    scratch_parent = comparator.open_scratch_parent(())
    private = comparator.PrivateTree.create(
        scratch_parent,
        "sp11-raw-ownership-bound.",
        "private ownership bound fixture",
    )
    ownership = comparator.PrivateOwnership.create(private.root_descriptor)
    private_path = private.path
    try:
        sizes = {
            "empty-lock": 0,
            "over-tool-limit-sparse": comparator.MAX_TOOL_BYTES + 4096,
        }
        assert sizes["over-tool-limit-sparse"] < comparator.MAX_ARTIFACT_BYTES
        for name, size in sizes.items():
            descriptor = os.open(
                name,
                os.O_RDWR
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                0o600,
                dir_fd=private.root_descriptor,
            )
            try:
                ownership.declare_file_creation(name, descriptor)
                os.ftruncate(descriptor, size)
                os.fchmod(descriptor, 0o400)
                file_hash = comparator.hash_descriptor(descriptor, size)
                ownership.declare_file(name, descriptor, file_hash)
            finally:
                os.close(descriptor)
        ownership.finalize_directories(private.root_descriptor)
        ownership.verify(private.root_descriptor)
        private.seal()
        assert private.entries == ownership.expected_entries()
        private.ownership = ownership
        private.verify()
        private.cleanup()
        assert not private_path.exists()
    finally:
        if not private.cleaned and not private.preserved:
            comparator.cleanup_private_setup_failure(private, ownership)
        if private_path.exists():
            shutil.rmtree(private_path)
        scratch_parent.close()


def hostile_tmpdir_nonmutation_cases(fixture: PairFixture) -> None:
    roots = (fixture.support, fixture.build_a, fixture.build_b)
    initial = tuple(complete_tree_state(root) for root in roots)
    for hostile_tmpdir in (
        fixture.build_a,
        fixture.build_a / "apt-indexes/resolute/main/binary-arm64",
    ):
        environment = fixture.env()
        environment["TMPDIR"] = str(hostile_tmpdir)
        result = run(
            fixture.command(fixture.build_a, fixture.build_b),
            env=environment,
        )
        assert result.stderr == ""
        assert result.stdout.endswith("Comparison completed: true\n")
        assert tuple(complete_tree_state(root) for root in roots) == initial
        assert not any(
            path.name.startswith(
                ("sp11-raw-support.", ".sp11-raw-copied.")
            )
            for path in hostile_tmpdir.iterdir()
        )


def real_zstd_and_path_binding_cases(fixture: PairFixture) -> None:
    first = fixture.clone(fixture.apt.work, "real-control-zstd-a")
    second = fixture.clone(fixture.apt.work, "real-control-zstd-b")
    package, architecture = PACKAGE_IDENTITIES["common-headers"]
    filename = f"{package}_{VERSION}_{architecture}.deb"
    compressed = deb_bytes(
        package,
        VERSION,
        architecture,
        payload=b"real retained retry4 zstd control fixture\n",
        control_compression="zst",
    )
    (first / "artifacts" / filename).write_bytes(compressed)
    (second / "artifacts" / filename).write_bytes(compressed)
    fixture.regenerate(first)
    fixture.regenerate(second)

    shadow = fixture.root / "hostile-path-shadow"
    shadow.mkdir()
    sentinel = fixture.root / "hostile-path-tool-executed"
    for name in ("git", "lz4", "zstd"):
        tool = shadow / name
        tool.write_text(
            f"#!/bin/sh\nprintf executed > {sentinel}\nexit 99\n",
            encoding="utf-8",
        )
        tool.chmod(0o755)
    environment = fixture.env()
    environment["PATH"] = str(shadow) + os.pathsep + environment.get("PATH", "")
    result = run(
        fixture.command(first, second),
        env=environment,
        expected=0,
    )
    assert "P0.4b raw evidence: pass\n" in result.stdout
    assert not sentinel.exists()

    comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_tool_root_swap_fixture_target"
    )
    launch_sentinel = fixture.root / "private-tool-root-swap-executed"
    replacement: Path | None = None
    preserved_original: Path | None = None
    swapped = False

    def replace_root_before_tool_launch(tool: object) -> None:
        nonlocal replacement, preserved_original, swapped
        if swapped or tool.name != "zstd":
            return
        if sys.platform == "darwin":
            assert tool.dyld_library_path == "bound-tools/zstd-bundle/lib"
            assert comparator.bound_tool_environment(tool)["DYLD_LIBRARY_PATH"] == (
                "bound-tools/zstd-bundle/lib"
            )
            assert {
                "bound-tools/zstd-bundle/lib/libzstd.1.dylib",
                "bound-tools/zstd-bundle/lib/liblzma.5.dylib",
                "bound-tools/zstd-bundle/lib/liblz4.1.dylib",
            }.issubset(tool.private.entries)
        replacement = tool.private.path
        preserved_original = replacement.with_name(
            replacement.name + ".tool-preserved"
        )
        replacement.rename(preserved_original)
        hostile = replacement / tool.relative
        hostile.parent.mkdir(parents=True)
        hostile.write_text(
            f"#!/bin/sh\nprintf executed > {launch_sentinel}\nexit 99\n",
            encoding="utf-8",
        )
        hostile.chmod(0o755)
        swapped = True

    comparator.private_tool_launch_barrier = replace_root_before_tool_launch
    try:
        swapped_result = invoke_loaded_main(
            comparator,
            fixture.command(first, second),
            fixture.env(),
        )
        assert_sanitized_failure(swapped_result, fixture)
        assert swapped
        assert replacement is not None and preserved_original is not None
        assert not launch_sentinel.exists()
        assert (replacement / "bound-tools").is_dir()
        assert (preserved_original / "bound-tools").is_dir()
    finally:
        if replacement is not None and replacement.exists():
            shutil.rmtree(replacement)
        if preserved_original is not None and preserved_original.exists():
            shutil.rmtree(preserved_original)


def external_decoder_supervisor_cases(fixture: PairFixture) -> None:
    tool_root = fixture.root / "hostile-comparator-decoder"
    tool_root.mkdir()
    decoder = tool_root / "decoder"
    decoder.write_text(
        textwrap.dedent(
            f"""\
            #!{sys.executable}
            import os
            import sys
            import time

            mode = os.environ["SP11_DECODER_BEHAVIOR"]
            if mode == "small-stderr":
                os.write(2, b"legitimate decoder warning\\n")
                os.write(1, b"x")
            elif mode == "oversize":
                os.write(1, b"xx")
            elif mode == "infinite-stdout":
                while True:
                    os.write(1, b"x" * 65536)
            elif mode == "stderr-flood":
                os.write(1, b"x")
                while True:
                    os.write(2, b"e" * 65536)
            elif mode == "total-timeout":
                while True:
                    os.write(2, b"progress")
                    time.sleep(0.05)
            elif mode in {{"hang", "pending-signal"}}:
                while True:
                    time.sleep(10)
            elif mode == "interrupt":
                os.write(1, b"x")
                while True:
                    time.sleep(10)
            elif mode in {{"wait-return-signal", "internal-wait-signal"}}:
                os.write(1, b"x")
            elif mode == "nonzero-after-eof":
                os.write(1, b"x")
                raise SystemExit(7)
            elif mode == "digest-mismatch":
                os.write(1, b"y")
            else:
                raise SystemExit(99)
            """
        ),
        encoding="utf-8",
    )
    decoder.chmod(0o500)
    target = next(
        path for path in (fixture.build_a / "apt-lists").iterdir() if path.is_file()
    )

    harness = textwrap.dedent(
        """\
        import hashlib
        import importlib.util
        import io
        import os
        from pathlib import Path
        import signal
        import sys
        from types import SimpleNamespace

        comparator_path = Path(sys.argv[1])
        tool_root = Path(sys.argv[2])
        build_root = Path(sys.argv[3])
        target = Path(sys.argv[4])
        mode = sys.argv[5]
        pid_path = Path(sys.argv[6])
        signal_marker = Path(sys.argv[7])
        kind, behavior = mode.split("-", 1)
        specification = importlib.util.spec_from_file_location(
            "sp11_comparator_decoder_supervisor_fixture", comparator_path
        )
        assert specification is not None and specification.loader is not None
        comparator = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = comparator
        sys.dont_write_bytecode = True
        specification.loader.exec_module(comparator)
        comparator.EXTERNAL_DECODER_STDERR_MAX = 4096
        comparator.EXTERNAL_DECODER_TOTAL_TIMEOUT_SECONDS = 0.8
        comparator.EXTERNAL_DECODER_IDLE_TIMEOUT_SECONDS = 0.2
        comparator.EXTERNAL_DECODER_STOP_TIMEOUT_SECONDS = 0.2

        child_environment = {
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "SP11_DECODER_BEHAVIOR": behavior,
        }
        comparator.verify_bound_tool = lambda _tool: None
        comparator.private_tool_launch_barrier = lambda _tool: None
        comparator.bound_tool_environment = lambda _tool: dict(child_environment)

        original_popen = comparator.subprocess.Popen
        def recording_popen(*arguments, **keywords):
            child = original_popen(*arguments, **keywords)
            descriptor = os.open(
                pid_path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            try:
                os.write(descriptor, (str(child.pid) + "\\n").encode("ascii"))
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            if behavior == "pending-signal":
                signal_marker.write_text("pending signal sent\\n", encoding="ascii")
                os.kill(os.getpid(), signal.SIGTERM)
            elif behavior == "wait-return-signal":
                original_wait = child.wait
                sent = False
                def signalling_wait(*wait_arguments, **wait_keywords):
                    nonlocal sent
                    result = original_wait(*wait_arguments, **wait_keywords)
                    if not sent:
                        sent = True
                        with signal_marker.open("a", encoding="ascii") as marker:
                            marker.write("wait-return signal sent\\n")
                        os.kill(os.getpid(), signal.SIGTERM)
                    return result
                child.wait = signalling_wait
            elif behavior == "internal-wait-signal":
                def internal_wait(*_arguments, **_keywords):
                    blocked = signal.pthread_sigmask(signal.SIG_BLOCK, ())
                    if signal.SIGTERM not in blocked:
                        raise AssertionError("terminal wait signal mask was not blocked")
                    waited_pid, wait_status = os.waitpid(child.pid, 0)
                    if waited_pid != child.pid:
                        raise AssertionError("waitpid returned an unexpected child")
                    with signal_marker.open("a", encoding="ascii") as marker:
                        marker.write("internal wait signal sent\\n")
                    os.kill(os.getpid(), signal.SIGTERM)
                    child.returncode = os.waitstatus_to_exitcode(wait_status)
                    return child.returncode
                child.wait = internal_wait
            return child
        comparator.subprocess.Popen = recording_popen

        if behavior == "interrupt":
            original_selector = comparator.selectors.DefaultSelector
            class InterruptingSelector:
                def __init__(self):
                    self._selector = original_selector()
                    self._sent = False
                def __getattr__(self, name):
                    return getattr(self._selector, name)
                def select(self, timeout=None):
                    if not self._sent:
                        self._sent = True
                        events = self._selector.select(timeout)
                        signal_marker.write_text(
                            "selector interrupt sent\\n", encoding="ascii"
                        )
                        os.kill(os.getpid(), signal.SIGTERM)
                        return events
                    return self._selector.select(timeout)
            comparator.selectors.DefaultSelector = InterruptingSelector

        if behavior in {
            "wait-return-signal",
            "internal-wait-signal",
            "nonzero-after-eof",
            "digest-mismatch",
        }:
            def forbidden_killpg(_pid, _signal):
                with signal_marker.open("a", encoding="ascii") as marker:
                    marker.write("killpg called after exact child reap\\n")
            comparator.os.killpg = forbidden_killpg

        tool_descriptor = os.open(tool_root, os.O_RDONLY | os.O_DIRECTORY)
        build_descriptor = os.open(build_root, os.O_RDONLY | os.O_DIRECTORY)
        tool = SimpleNamespace(
            relative="./decoder",
            root_descriptor=tool_descriptor,
        )
        expected = (1, hashlib.sha256(b"x").hexdigest())
        try:
            if kind == "apt":
                result = comparator.bound_apt_list_identity(
                    target,
                    {},
                    SimpleNamespace(tools={"lz4": tool}),
                    SimpleNamespace(root_descriptor=build_descriptor),
                    expected,
                )
            elif kind == "zstd":
                with comparator.bounded_zstd_stream(
                    io.BytesIO(b"compressed fixture"), tool, 1
                ) as stream:
                    result = stream.read()
            else:
                raise AssertionError("unknown comparator decoder fixture kind")
        except comparator.ValidationError:
            if behavior == "small-stderr":
                raise
            print("comparator-decoder-refused:" + mode)
        else:
            wanted = expected if kind == "apt" else b"x"
            if behavior != "small-stderr" or result != wanted:
                raise AssertionError("hostile comparator decoder was accepted")
            print("comparator-decoder-accepted-small-stderr:" + kind)
        finally:
            os.close(build_descriptor)
            os.close(tool_descriptor)
        """
    )

    modes = (
        "apt-small-stderr",
        "apt-oversize",
        "apt-infinite-stdout",
        "apt-stderr-flood",
        "apt-total-timeout",
        "apt-hang",
        "apt-interrupt",
        "apt-pending-signal",
        "apt-wait-return-signal",
        "apt-internal-wait-signal",
        "apt-nonzero-after-eof",
        "apt-digest-mismatch",
        "zstd-small-stderr",
        "zstd-oversize",
        "zstd-stderr-flood",
        "zstd-hang",
        "zstd-interrupt",
        "zstd-pending-signal",
        "zstd-wait-return-signal",
        "zstd-internal-wait-signal",
        "zstd-nonzero-after-eof",
    )
    for mode in modes:
        pid_path = fixture.root / f"comparator-decoder-{mode}.pid"
        signal_marker = fixture.root / f"comparator-decoder-{mode}.signals"
        result = run(
            [
                sys.executable,
                "-I",
                "-c",
                harness,
                str(fixture.comparator),
                str(tool_root),
                str(fixture.build_a),
                str(target),
                mode,
                str(pid_path),
                str(signal_marker),
            ],
            env=fixture.env(),
        )
        kind, behavior = mode.split("-", 1)
        if behavior == "small-stderr":
            assert f"comparator-decoder-accepted-small-stderr:{kind}" in (
                result.stdout
            )
        else:
            assert f"comparator-decoder-refused:{mode}" in result.stdout
        assert pid_path.is_file() and not pid_path.is_symlink()
        child_pid = int(pid_path.read_text(encoding="ascii").strip())
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            pass
        else:
            try:
                os.killpg(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            raise AssertionError(f"comparator decoder child was not reaped: {mode}")
        if behavior in {"nonzero-after-eof", "digest-mismatch"}:
            assert not os.path.lexists(signal_marker)
        elif behavior == "wait-return-signal":
            assert signal_marker.read_text(encoding="ascii") == (
                "wait-return signal sent\n"
            )
        elif behavior == "internal-wait-signal":
            assert signal_marker.read_text(encoding="ascii") == (
                "internal wait signal sent\n"
            )
        elif behavior == "interrupt":
            assert signal_marker.read_text(encoding="ascii") == (
                "selector interrupt sent\n"
            )
        elif behavior == "pending-signal":
            assert signal_marker.read_text(encoding="ascii") == (
                "pending signal sent\n"
            )


def decoder_bound_cases(fixture: PairFixture) -> None:
    external_decoder_supervisor_cases(fixture)
    assert not any(fixture.support.rglob("__pycache__"))
    assert not any(fixture.support.rglob("*.pyc"))
    assert git(fixture.support, "status", "--porcelain") == ""
    comparator = load_module(
        fixture.comparator, "_sp11_raw_pair_decoder_bound_fixture_target"
    )
    comparator_raw = fixture.comparator.read_text(encoding="utf-8")
    retained_validator_block = comparator_raw.split(
        "def validate_retained_inputs(", 1
    )[1].split("def safe_artifact_name(", 1)[0]
    assert '"validate-release-snapshot",' in retained_validator_block
    assert '\n        "validate",\n' not in retained_validator_block
    compressed = lzma.compress(b"bounded decoder fixture\n", format=lzma.FORMAT_XZ)
    original_limit = comparator.MAX_CONTROL_DECODE_MEMORY
    comparator.MAX_CONTROL_DECODE_MEMORY = 1024 * 1024
    try:
        reader = io.BufferedReader(comparator.BoundedXZReader(io.BytesIO(compressed)))
        try:
            reader.read()
        except comparator.ValidationError:
            pass
        else:
            raise AssertionError("XZ decoder accepted a dictionary above its memory limit")
        finally:
            reader.close()
    finally:
        comparator.MAX_CONTROL_DECODE_MEMORY = original_limit

    command = comparator.zstd_arguments("/usr/bin/zstd")
    assert command[-1] == "--memory=64MB"
    assert "--decompress" in command and "--stdout" in command

    class LoadedReaderError(Exception):
        pass

    class RaisingReader:
        def read(self, _size: int) -> bytes:
            raise LoadedReaderError("private loaded-reader sentinel")

    thread_failures: list[object] = []
    original_excepthook = threading.excepthook
    original_command = comparator.zstd_command
    threading.excepthook = lambda arguments: thread_failures.append(arguments)
    comparator.zstd_command = lambda _program: ["/usr/bin/true"]
    try:
        try:
            with comparator.bounded_zstd_stream(
                RaisingReader(), None, 1024
            ) as stream:
                stream.read()
        except comparator.ValidationError:
            pass
        else:
            raise AssertionError("loaded-reader exception escaped zstd feeder handling")
    finally:
        comparator.zstd_command = original_command
        threading.excepthook = original_excepthook
    assert thread_failures == []


def cli_shape_case(fixture: PairFixture) -> None:
    def ignore_sigchld_before_exec() -> None:
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)

    ignored_sigchld = run(
        fixture.command(fixture.build_a, fixture.build_b),
        env=fixture.env(),
        preexec_fn=ignore_sigchld_before_exec,
    )
    assert ignored_sigchld.stdout.endswith("Comparison completed: true\n")
    assert ignored_sigchld.stderr == ""
    nonisolated = run(
        [sys.executable, str(fixture.comparator), "--version"],
        env=fixture.env(),
        expected=2,
    )
    assert_sanitized_failure(nonisolated, fixture)
    version = run(
        [sys.executable, "-I", str(fixture.comparator), "--version"],
        env=fixture.env(),
    )
    assert (
        version.stdout
        == "sp11-kernel-raw-matched-pair-v1 (sp11-kernel-zero-normalization-v1)\n"
    )
    assert version.stderr == ""
    missing_flag = run(
        [sys.executable, "-I", str(fixture.comparator)],
        env=fixture.env(),
        expected=2,
    )
    assert_sanitized_failure(missing_flag, fixture)
    unknown_private = run(
        [
            sys.executable,
            "-I",
            str(fixture.comparator),
            "--private-path-sentinel-option",
            str(fixture.root),
        ],
        env=fixture.env(),
        expected=2,
    )
    assert_sanitized_failure(unknown_private, fixture)
    abbreviated = fixture.command(fixture.build_a, fixture.build_b)
    abbreviated[abbreviated.index("--support-head")] = "--support-hea"
    assert_sanitized_failure(
        run(abbreviated, env=fixture.env(), expected=2), fixture
    )
    bad_head = fixture.command(fixture.build_a, fixture.build_b)
    bad_head[bad_head.index(fixture.support_head)] = "A" * 40
    assert_sanitized_failure(run(bad_head, env=fixture.env(), expected=2), fixture)

    same = fixture.compare(fixture.build_a, fixture.build_a, expected=2)
    assert_sanitized_failure(same, fixture)

    alias = fixture.root / "build-directory-alias"
    alias.symlink_to(fixture.build_a, target_is_directory=True)
    assert_sanitized_failure(
        fixture.compare(alias, fixture.build_b, expected=2), fixture
    )

    relative = fixture.command(fixture.build_a, fixture.build_b)
    relative[relative.index(str(fixture.build_a))] = os.path.relpath(
        fixture.build_a, REPO
    )
    assert_sanitized_failure(run(relative, env=fixture.env(), expected=2), fixture)

    relative_support = fixture.command(fixture.build_a, fixture.build_b)
    relative_support[relative_support.index(str(fixture.support))] = "."
    relative_support[relative_support.index(str(fixture.baseline))] = (
        "config/kernel-baselines/fixture.env"
    )
    permitted = run(
        relative_support,
        env=fixture.env(),
        cwd=fixture.support,
    )
    assert permitted.stdout.endswith("Comparison completed: true\n")
    assert permitted.stderr == ""


def main() -> None:
    fixture = PairFixture()
    try:
        positive_and_mismatch_cases(fixture)
        artifact_shape_cases(fixture)
        provenance_and_control_cases(fixture)
        race_case(fixture)
        baseline_report_sanitization_cases(fixture)
        committed_code_swap_case(fixture)
        report_time_race_case(fixture)
        retained_view_aba_cases(fixture)
        private_support_setup_victim_case(fixture)
        failed_setup_subtree_preservation_cases(fixture)
        real_zstd_and_path_binding_cases(fixture)
        cleanup_drift_cases(fixture)
        private_ownership_bound_cases(fixture)
        hostile_tmpdir_nonmutation_cases(fixture)
        decoder_bound_cases(fixture)
        cli_shape_case(fixture)
        print("raw kernel matched-pair comparator hostile fixtures passed")
    finally:
        fixture.close()


if __name__ == "__main__":
    main()
