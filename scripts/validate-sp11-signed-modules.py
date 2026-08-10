#!/usr/bin/env python3
"""Validate the exact controlled Surface Pro 11 touchscreen module bundle."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import signal
import stat
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


POLICY = "sp11-controlled-rsa4096-sha512-v1"
CERTIFICATE_NAME = "sp11-module-signing-cert.x509"
MANIFEST_NAME = "sp11-touchscreen-modules-manifest.txt"
MODULE_NAMES = ("gpi.ko", "spi-geni-qcom.ko", "mshw0485_touch.ko")
MODULE_SIGNATURE_MARKER = b"~Module signature appended~\n"
MODULE_SIGNATURE_INFO_SIZE = 12
MAX_CERTIFICATE_SIZE = 1024 * 1024
MAX_MODULE_SIZE = 64 * 1024 * 1024
MAX_SIGNATURE_SIZE = 2 * 1024 * 1024
MAX_MANIFEST_SIZE = 4 * 1024 * 1024
APPROVED_CERTIFICATE_DER_SHA256 = (
    "8ad9b402339b5ceff8e7fc9dfcc7dd368b2466fce0e90d97553059bcdc66e99b"
)

OID_SIGNED_DATA = bytes.fromhex("2a864886f70d010702")
OID_DATA = bytes.fromhex("2a864886f70d010701")
OID_SHA512 = bytes.fromhex("608648016503040203")
OID_RSA_ENCRYPTION = bytes.fromhex("2a864886f70d010101")


def fixed_openssl_path() -> Path:
    if sys.platform.startswith("linux"):
        return Path("/usr/bin/openssl")
    if sys.platform == "darwin":
        for candidate in (
            "/opt/homebrew/opt/openssl@3/bin/openssl",
            "/usr/local/opt/openssl@3/bin/openssl",
        ):
            resolved = Path(os.path.realpath(candidate))
            if resolved.is_file():
                return resolved
    raise RuntimeError("no fixed OpenSSL 3 authority is configured for this platform")


try:
    OPENSSL_PATH = fixed_openssl_path()
except RuntimeError:
    OPENSSL_PATH = Path("/nonexistent/sp11-openssl")
OPENSSL_IDENTITY: tuple[int, ...] | None = None


class ValidationError(Exception):
    """A controlled-bundle validation failure."""


@dataclass(frozen=True)
class HeldFile:
    data: bytes
    identity: tuple[int, ...]


@dataclass(frozen=True)
class SignedModule:
    name: str
    full: bytes
    payload: bytes
    signature: bytes


def stable_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
    )


def open_bundle_root(paths: list[str]) -> tuple[int, int, str, tuple[int, ...]]:
    parents: set[str] = set()
    for path_text in paths:
        if (
            not os.path.isabs(path_text)
            or path_text.startswith("//")
            or os.path.normpath(path_text) != path_text
        ):
            raise ValidationError("controlled bundle paths must use canonical absolute spelling")
        parents.add(os.path.dirname(path_text))
    if len(parents) != 1:
        raise ValidationError("all controlled bundle roles must share one exact directory")
    parent = parents.pop()
    flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open("/", flags)
        for component in Path(parent).parts[1:]:
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
    except OSError as exc:
        try:
            os.close(descriptor)
        except (OSError, UnboundLocalError):
            pass
        raise ValidationError("controlled bundle directory chain is not physical and non-symlinked") from exc
    held = os.fstat(descriptor)
    mapped = os.stat(parent, follow_symlinks=False)
    if stable_identity(held) != stable_identity(mapped):
        os.close(descriptor)
        raise ValidationError("controlled bundle directory mapping changed during acquisition")
    if not stat.S_ISDIR(held.st_mode) or stat.S_IMODE(held.st_mode) & 0o022:
        os.close(descriptor)
        raise ValidationError("controlled bundle directory must not be group- or world-writable")
    return descriptor, held.st_uid, parent, stable_identity(held)


def verify_bundle_root(
    descriptor: int, parent: str, expected_identity: tuple[int, ...]
) -> None:
    try:
        held = os.fstat(descriptor)
        mapped = os.stat(parent, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError("controlled bundle directory mapping disappeared") from exc
    if stable_identity(held) != expected_identity or stable_identity(mapped) != expected_identity:
        raise ValidationError("controlled bundle directory mapping changed during validation")


def read_held_file(
    bundle_descriptor: int,
    bundle_owner: int,
    name: str,
    label: str,
    maximum_size: int,
) -> HeldFile:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(name, flags, dir_fd=bundle_descriptor)
    except OSError as exc:
        raise ValidationError(f"cannot open {label} as a regular non-symlinked file") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValidationError(f"{label} is not a regular file")
        if before.st_uid != bundle_owner or stat.S_IMODE(before.st_mode) & 0o022:
            raise ValidationError(f"{label} does not have owner-safe metadata")
        if before.st_nlink != 1:
            raise ValidationError(f"{label} must have exactly one filesystem link")
        if before.st_size <= 0:
            raise ValidationError(f"{label} is empty")
        if before.st_size > maximum_size:
            raise ValidationError(f"{label} exceeds its size bound")
        chunks: list[bytes] = []
        remaining = before.st_size + 1
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        mapped = os.stat(name, dir_fd=bundle_descriptor, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError(f"{label} disappeared while it was read") from exc
    identity = stable_identity(before)
    if len(data) != before.st_size or identity != stable_identity(after) or identity != stable_identity(mapped):
        raise ValidationError(f"{label} changed while it was read")
    return HeldFile(data=data, identity=identity)


def openssl_identity() -> tuple[int, ...]:
    global OPENSSL_IDENTITY

    try:
        metadata = os.stat(OPENSSL_PATH, follow_symlinks=False)
    except OSError as exc:
        raise ValidationError("fixed OpenSSL authority is unavailable") from exc
    identity = stable_identity(metadata)
    if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) & 0o022:
        raise ValidationError("fixed OpenSSL authority has unsafe metadata")
    if metadata.st_mode & 0o111 == 0:
        raise ValidationError("fixed OpenSSL authority is not executable")
    if sys.platform.startswith("linux") and metadata.st_uid != 0:
        raise ValidationError("fixed OpenSSL authority is not root-owned")
    if OPENSSL_IDENTITY is None:
        OPENSSL_IDENTITY = identity
    elif OPENSSL_IDENTITY != identity:
        raise ValidationError("fixed OpenSSL authority mapping changed")
    return identity


def run_openssl(arguments: list[str], label: str, input_data: bytes | None = None) -> bytes:
    before = openssl_identity()
    try:
        result = subprocess.run(
            [str(OPENSSL_PATH), *arguments],
            input=input_data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=20,
            env={
                "PATH": "/usr/bin:/bin",
                "LC_ALL": "C",
                "LANG": "C",
                "TZ": "UTC",
            },
        )
    except FileNotFoundError as exc:
        raise ValidationError("openssl is required for module signature validation") from exc
    except subprocess.TimeoutExpired as exc:
        raise ValidationError(f"openssl timed out while validating {label}") from exc
    if result.returncode != 0:
        raise ValidationError(f"openssl rejected {label}")
    if openssl_identity() != before:
        raise ValidationError("fixed OpenSSL authority mapping changed during validation")
    return result.stdout


def read_der_length(data: bytes, offset: int, label: str) -> tuple[int, int]:
    if offset >= len(data):
        raise ValidationError(f"{label} has a truncated DER length")
    first = data[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    width = first & 0x7F
    if width == 0 or width > 4 or offset + width > len(data):
        raise ValidationError(f"{label} has an invalid DER length")
    encoded = data[offset : offset + width]
    if encoded[0] == 0:
        raise ValidationError(f"{label} has a non-minimal DER length")
    length = int.from_bytes(encoded, "big")
    if length < 0x80:
        raise ValidationError(f"{label} has a non-minimal DER length")
    return length, offset + width


def read_der_tlv(data: bytes, offset: int, label: str) -> tuple[int, bytes, int]:
    if offset >= len(data):
        raise ValidationError(f"{label} has a truncated DER object")
    tag = data[offset]
    if tag & 0x1F == 0x1F:
        raise ValidationError(f"{label} uses an unsupported DER tag")
    length, content_offset = read_der_length(data, offset + 1, label)
    end = content_offset + length
    if end > len(data):
        raise ValidationError(f"{label} has a truncated DER value")
    return tag, data[content_offset:end], end


def der_children(data: bytes, label: str) -> list[tuple[int, bytes]]:
    children: list[tuple[int, bytes]] = []
    offset = 0
    while offset < len(data):
        tag, content, offset = read_der_tlv(data, offset, label)
        children.append((tag, content))
    return children


def require_single_der_object(data: bytes, expected_tag: int, label: str) -> bytes:
    tag, content, end = read_der_tlv(data, 0, label)
    if tag != expected_tag or end != len(data):
        raise ValidationError(f"{label} is not one exact DER object")
    return content


def require_algorithm_identifier(
    item: tuple[int, bytes], expected_oid: bytes, label: str, allow_null: bool
) -> None:
    tag, content = item
    if tag != 0x30:
        raise ValidationError(f"{label} is not a DER AlgorithmIdentifier")
    children = der_children(content, label)
    if not children or children[0] != (0x06, expected_oid):
        raise ValidationError(f"{label} uses the wrong algorithm")
    if len(children) == 1:
        return
    if allow_null and len(children) == 2 and children[1] == (0x05, b""):
        return
    raise ValidationError(f"{label} has unexpected algorithm parameters")


def validate_cms_contract(signature: bytes) -> None:
    content_info = der_children(
        require_single_der_object(signature, 0x30, "module CMS signature"),
        "module CMS signature",
    )
    if len(content_info) != 2 or content_info[0] != (0x06, OID_SIGNED_DATA) or content_info[1][0] != 0xA0:
        raise ValidationError("module signature is not exact CMS SignedData")
    signed_data_wrapper = der_children(content_info[1][1], "CMS SignedData wrapper")
    if len(signed_data_wrapper) != 1 or signed_data_wrapper[0][0] != 0x30:
        raise ValidationError("module CMS SignedData wrapper is malformed")
    signed_data = der_children(signed_data_wrapper[0][1], "CMS SignedData")
    if len(signed_data) != 4:
        raise ValidationError("module CMS must omit embedded certificates and revocation lists")
    if signed_data[0] != (0x02, b"\x01"):
        raise ValidationError("module CMS SignedData has an unsupported version")
    if signed_data[1][0] != 0x31:
        raise ValidationError("module CMS digestAlgorithms is malformed")
    digest_algorithms = der_children(signed_data[1][1], "CMS digestAlgorithms")
    if len(digest_algorithms) != 1:
        raise ValidationError("module CMS must contain exactly one digest algorithm")
    require_algorithm_identifier(digest_algorithms[0], OID_SHA512, "CMS digest algorithm", True)

    if signed_data[2][0] != 0x30:
        raise ValidationError("module CMS encapsulated content is malformed")
    encapsulated = der_children(signed_data[2][1], "CMS encapsulated content")
    if encapsulated != [(0x06, OID_DATA)]:
        raise ValidationError("module CMS signature must use detached binary content")

    if signed_data[3][0] != 0x31:
        raise ValidationError("module CMS signerInfos is malformed")
    signer_infos = der_children(signed_data[3][1], "CMS signerInfos")
    if len(signer_infos) != 1 or signer_infos[0][0] != 0x30:
        raise ValidationError("module CMS must contain exactly one signer")
    signer = der_children(signer_infos[0][1], "CMS SignerInfo")
    if len(signer) != 5:
        raise ValidationError("module CMS signer must omit signed and unsigned attributes")
    if signer[0] != (0x02, b"\x01"):
        raise ValidationError("module CMS signer has an unsupported version")
    if signer[1][0] != 0x30:
        raise ValidationError("module CMS signer identifier is malformed")
    signer_identifier = der_children(signer[1][1], "CMS signer identifier")
    if len(signer_identifier) != 2 or signer_identifier[0][0] != 0x30 or signer_identifier[1][0] != 0x02:
        raise ValidationError("module CMS signer must use issuer and serial identity")
    require_algorithm_identifier(signer[2], OID_SHA512, "CMS signer digest algorithm", True)
    require_algorithm_identifier(signer[3], OID_RSA_ENCRYPTION, "CMS signature algorithm", True)
    if signer[4][0] != 0x04 or not signer[4][1]:
        raise ValidationError("module CMS has no RSA signature bytes")


def certificate_identity(certificate: HeldFile) -> tuple[str, str]:
    require_single_der_object(certificate.data, 0x30, "module signing certificate")
    if sha256(certificate.data) != APPROVED_CERTIFICATE_DER_SHA256:
        raise ValidationError(
            "module signing certificate does not match the approved public identity"
        )
    canonical = run_openssl(
        ["x509", "-inform", "DER", "-outform", "DER"],
        "module signing certificate",
        certificate.data,
    )
    if canonical != certificate.data:
        raise ValidationError("module signing certificate is not canonical DER")
    details = run_openssl(
        ["x509", "-inform", "DER", "-text", "-noout"],
        "module signing certificate public key",
        certificate.data,
    ).decode("utf-8", "strict")
    if len(re.findall(r"Public Key Algorithm:\s*rsaEncryption\b", details)) != 1:
        raise ValidationError("module signing certificate must use an RSA public key")
    if len(re.findall(r"Public-Key:\s*\(4096 bit\)", details)) != 1:
        raise ValidationError("module signing certificate must contain an RSA-4096 public key")
    if len(re.findall(r"Signature Algorithm:\s*sha512WithRSAEncryption\b", details)) != 2:
        raise ValidationError("module signing certificate must use an RSA/SHA-512 certificate signature")
    if not re.search(
        r"X509v3 Basic Constraints:\s*critical\s*\n\s*CA:FALSE\s*$",
        details,
        re.MULTILINE,
    ):
        raise ValidationError("module signing certificate must declare critical CA:FALSE")
    key_usage = re.search(
        r"X509v3 Key Usage:\s*critical\s*\n\s*([^\n]+)",
        details,
    )
    if key_usage is None or key_usage.group(1).strip() != "Digital Signature":
        raise ValidationError("module signing certificate must declare only critical Digital Signature usage")

    fingerprint_output = run_openssl(
        ["x509", "-inform", "DER", "-sha256", "-fingerprint", "-noout"],
        "module signing certificate fingerprint",
        certificate.data,
    ).decode("ascii", "strict").strip()
    fingerprint_match = re.fullmatch(
        r"SHA256 Fingerprint=((?:[0-9A-F]{2}:){31}[0-9A-F]{2})",
        fingerprint_output,
        re.IGNORECASE,
    )
    if fingerprint_match is None:
        raise ValidationError("openssl returned an invalid certificate fingerprint")
    fingerprint = fingerprint_match.group(1).upper()

    serial_output = run_openssl(
        ["x509", "-inform", "DER", "-serial", "-noout"],
        "module signing certificate serial",
        certificate.data,
    ).decode("ascii", "strict").strip()
    serial_match = re.fullmatch(r"serial=([0-9A-F]+)", serial_output, re.IGNORECASE)
    if serial_match is None:
        raise ValidationError("openssl returned an invalid certificate serial")
    return fingerprint, serial_match.group(1).upper()


def split_signed_module(name: str, data: bytes) -> SignedModule:
    if data.count(MODULE_SIGNATURE_MARKER) != 1 or not data.endswith(MODULE_SIGNATURE_MARKER):
        raise ValidationError(f"{name} does not contain one terminal module signature marker")
    info_end = len(data) - len(MODULE_SIGNATURE_MARKER)
    info_start = info_end - MODULE_SIGNATURE_INFO_SIZE
    if info_start <= 0:
        raise ValidationError(f"{name} has a truncated module signature descriptor")
    algorithm, digest, identifier, signer_length, key_length, padding, signature_length = struct.unpack(
        ">BBBBB3sI", data[info_start:info_end]
    )
    if (algorithm, digest, identifier, signer_length, key_length, padding) != (0, 0, 2, 0, 0, b"\0\0\0"):
        raise ValidationError(f"{name} has a non-canonical module signature descriptor")
    if signature_length <= 0 or signature_length > MAX_SIGNATURE_SIZE:
        raise ValidationError(f"{name} has an invalid module signature length")
    signature_start = info_start - signature_length
    if signature_start <= 0:
        raise ValidationError(f"{name} has a truncated module signature")
    payload = data[:signature_start]
    signature = data[signature_start:info_start]
    if len(signature) != signature_length:
        raise ValidationError(f"{name} module signature length does not match its descriptor")
    validate_cms_contract(signature)
    return SignedModule(name=name, full=data, payload=payload, signature=signature)


def verify_signature(module: SignedModule, certificate: HeldFile) -> None:
    old_umask = os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix="sp11-signed-module-") as temporary:
            temp_path = Path(temporary)
            payload = temp_path / "payload"
            signature = temp_path / "signature.der"
            certificate_pem = temp_path / "certificate.pem"
            payload.write_bytes(module.payload)
            signature.write_bytes(module.signature)
            certificate_pem.write_bytes(
                run_openssl(
                    ["x509", "-inform", "DER", "-outform", "PEM"],
                    "module signing certificate",
                    certificate.data,
                )
            )
            run_openssl(
                [
                    "cms",
                    "-verify",
                    "-binary",
                    "-inform",
                    "DER",
                    "-in",
                    str(signature),
                    "-content",
                    str(payload),
                    "-nointern",
                    "-certfile",
                    str(certificate_pem),
                    "-noverify",
                    "-out",
                    os.devnull,
                ],
                f"{module.name} signature",
            )
    finally:
        os.umask(old_umask)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def report_lines(
    certificate: HeldFile,
    fingerprint: str,
    serial: str,
    modules: list[SignedModule],
) -> list[str]:
    lines = [
        f"Module signing policy: {POLICY}",
        "Module signing private material retained: false",
        "Module signing hash algorithm: sha512",
        f"Module signing certificate asset: {CERTIFICATE_NAME}",
        f"Module signing certificate SHA256: {sha256(certificate.data)}",
        f"Module signing certificate fingerprint: {fingerprint}",
        f"Module signing certificate serial: {serial}",
        "Windows SE init default: disabled",
    ]
    for module in modules:
        lines.extend(
            [
                f"Module {module.name} size: {len(module.full)}",
                f"Module {module.name} SHA256: {sha256(module.full)}",
                f"Module {module.name} payload size: {len(module.payload)}",
                f"Module {module.name} payload SHA256: {sha256(module.payload)}",
                f"Module {module.name} signature size: {len(module.signature)}",
                f"Module {module.name} signature SHA256: {sha256(module.signature)}",
            ]
        )
    return lines


def validate_manifest(manifest: HeldFile, expected_lines: list[str], manifest_format: str) -> None:
    try:
        text = manifest.data.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        raise ValidationError("touchscreen manifest is not valid UTF-8") from exc
    if "\0" in text or "\r" in text or not text.endswith("\n"):
        raise ValidationError("touchscreen manifest does not use canonical LF text")
    lines = text.splitlines()
    required_lines = expected_lines
    if manifest_format == "release":
        required_lines = [
            line for line in expected_lines if line != "Windows SE init default: disabled"
        ]
    indexes: list[int] = []
    for expected in required_lines:
        matches = [index for index, line in enumerate(lines) if line == expected]
        if len(matches) != 1:
            raise ValidationError(f"touchscreen manifest does not contain exactly one '{expected}' field")
        indexes.append(matches[0])
    if indexes != sorted(indexes):
        raise ValidationError("touchscreen manifest signing fields are not in canonical order")
    if manifest_format == "build":
        if indexes != list(range(indexes[0], indexes[0] + len(required_lines))):
            raise ValidationError("touchscreen manifest signing fields are not in canonical contiguous order")
        module_header_matches = [index for index, line in enumerate(lines) if line == "## Modules"]
        if len(module_header_matches) != 1 or module_header_matches[0] <= indexes[-1]:
            raise ValidationError("touchscreen manifest Modules section is missing or precedes signing fields")

    expected_prefixes = {line.split(": ", 1)[0] for line in required_lines}
    release_detail_prefixes = {
        f"Module {name} {detail}"
        for name in MODULE_NAMES
        for detail in ("name", "vermagic", "srcversion")
    }
    for line in lines:
        if line.startswith("Module signing ") or any(
            line.startswith(f"Module {name} ") for name in MODULE_NAMES
        ):
            prefix = line.split(": ", 1)[0]
            if prefix not in expected_prefixes and not (
                manifest_format == "release" and prefix in release_detail_prefixes
            ):
                raise ValidationError(f"touchscreen manifest contains an unknown signing field: {prefix}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the exact controlled Surface Pro 11 signed touchscreen module bundle."
    )
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--module", action="append", required=True)
    parser.add_argument("--manifest")
    parser.add_argument("--manifest-format", choices=("build", "release"), default="build")
    return parser.parse_args()


def main() -> int:
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        raise ValidationError(
            "controlled module validation requires the default SIGCHLD disposition"
        )
    arguments = parse_arguments()
    if Path(arguments.certificate).name != CERTIFICATE_NAME:
        raise ValidationError(f"certificate asset must be named {CERTIFICATE_NAME}")
    if len(arguments.module) != len(MODULE_NAMES):
        raise ValidationError("exactly three touchscreen modules are required")
    module_paths: dict[str, str] = {}
    for module_path in arguments.module:
        name = Path(module_path).name
        if name not in MODULE_NAMES or name in module_paths:
            raise ValidationError("module inputs must contain each exact touchscreen module basename once")
        module_paths[name] = module_path
    if tuple(sorted(module_paths)) != tuple(sorted(MODULE_NAMES)):
        raise ValidationError("module inputs do not contain the exact touchscreen module roles")
    if arguments.manifest and Path(arguments.manifest).name != MANIFEST_NAME:
        raise ValidationError(f"manifest asset must be named {MANIFEST_NAME}")

    all_paths = [arguments.certificate, *(module_paths[name] for name in MODULE_NAMES)]
    if arguments.manifest:
        all_paths.append(arguments.manifest)
    bundle_descriptor, bundle_owner, bundle_parent, bundle_identity = open_bundle_root(all_paths)
    try:
        certificate = read_held_file(
            bundle_descriptor,
            bundle_owner,
            CERTIFICATE_NAME,
            "module signing certificate",
            MAX_CERTIFICATE_SIZE,
        )
        held_modules = {
            name: read_held_file(
                bundle_descriptor,
                bundle_owner,
                name,
                name,
                MAX_MODULE_SIZE,
            )
            for name in MODULE_NAMES
        }
        identities = [certificate.identity[:2], *(held.identity[:2] for held in held_modules.values())]
        if len(set(identities)) != len(identities):
            raise ValidationError("controlled bundle roles must not alias the same filesystem object")

        fingerprint, serial = certificate_identity(certificate)
        modules: list[SignedModule] = []
        for name in MODULE_NAMES:
            module = split_signed_module(name, held_modules[name].data)
            verify_signature(module, certificate)
            modules.append(module)
        lines = report_lines(certificate, fingerprint, serial, modules)

        if arguments.manifest:
            manifest = read_held_file(
                bundle_descriptor,
                bundle_owner,
                MANIFEST_NAME,
                "touchscreen manifest",
                MAX_MANIFEST_SIZE,
            )
            if manifest.identity[:2] in identities:
                raise ValidationError("touchscreen manifest aliases another controlled bundle role")
            validate_manifest(manifest, lines, arguments.manifest_format)
        verify_bundle_root(bundle_descriptor, bundle_parent, bundle_identity)
    finally:
        os.close(bundle_descriptor)
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
