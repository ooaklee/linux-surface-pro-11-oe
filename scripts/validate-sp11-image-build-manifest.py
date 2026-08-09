#!/usr/bin/env python3
"""Validate the manifest that binds an SP11 raw image to its build inputs."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


OID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
POSITIVE = re.compile(r"[1-9][0-9]*\Z")
SAFE_NAME = re.compile(r"[A-Za-z0-9._+-]+\Z")
SAFE_DTB_SOURCE = re.compile(r"[A-Za-z0-9._+:/-]{1,512}\Z")
ESP_TYPE_GUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
DATA_TYPE_GUID = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
ESP_README_SIZE = 81
ESP_README_SHA256 = "6163777e9eeca7cfb031dab492007471ed514ae99baea73c7da7de9ab51d0443"
BUILDER_IMAGE = (
    "ubuntu:26.04@sha256:"
    "678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03"
)
FIELD_ORDER = (
    "Schema",
    "Build completed",
    "Input ISO URL",
    "Expected ISO SHA256",
    "Input ISO SHA256",
    "Embedded ISO path",
    "Embedded ISO SHA256",
    "DTB source",
    "Embedded DTB path",
    "Embedded DTB SHA256",
    "Desktop",
    "GRUB mode",
    "Partition table",
    "Logical sector size",
    "Partition count",
    "Partition 1 start sector",
    "Partition 1 end sector",
    "Partition 1 sector count",
    "Partition 1 type GUID",
    "Partition 1 name",
    "Partition 1 flags",
    "Partition 1 filesystem",
    "Partition 1 filesystem label",
    "Partition 2 start sector",
    "Partition 2 end sector",
    "Partition 2 sector count",
    "Partition 2 type GUID",
    "Partition 2 name",
    "Partition 2 flags",
    "Partition 2 filesystem",
    "Partition 2 filesystem label",
    "ESP boot path",
    "ESP boot size",
    "ESP boot SHA256",
    "ESP README path",
    "ESP README size",
    "ESP README SHA256",
    "Builder image",
    "Builder platform",
    "Support commit",
    "Support manifest",
    "Support manifest SHA256",
    "Output image file",
    "Output image size",
    "Output image SHA256",
)
LAYOUT_FIELD_ORDER = FIELD_ORDER[12:37]


class ValidationError(Exception):
    """An expected image-build provenance failure."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


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
        raise ValidationError(f"could not hash {path.name}: {exc}") from exc
    return digest.hexdigest()


def regular_input(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ValidationError(f"missing {label}: {path}") from exc
    require(
        path.is_file() and not path.is_symlink() and metadata.st_size > 0,
        f"{label} must be a non-empty regular, non-symlinked file",
    )


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
        ipaddress.ip_address(hostname)
    except ValueError:
        if "." not in hostname:
            return False
    else:
        return False
    return (
        parsed.scheme == "https"
        and port is None
        and parsed.username is None
        and parsed.password is None
        and parsed.path not in ("", "/")
        and not parsed.query
        and not parsed.fragment
        and not any(character.isspace() for character in value)
    )


def read_fields(
    path: Path,
    *,
    field_order: tuple[str, ...] = FIELD_ORDER,
    description: str = "image-build manifest",
) -> dict[str, str]:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise ValidationError(f"could not read {description}: {exc}") from exc
    require(data and len(data) <= 1024 * 1024, f"{description} has an invalid size")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError(f"{description} is not valid UTF-8") from exc
    require(
        "\r" not in text
        and "\x00" not in text
        and all(ord(character) >= 32 or character in "\n\t" for character in text),
        f"{description} contains unsafe control characters",
    )
    expected_fields = set(field_order)
    fields: dict[str, str] = {}
    observed_order: list[str] = []
    for line in text.splitlines():
        require(bool(line) and ": " in line, f"{description} contains a non-schema line")
        field_label, value = line.split(": ", 1)
        require(
            field_label in expected_fields,
            f"{path.name} contains an unexpected field: {field_label}",
        )
        require(
            field_label not in fields and bool(value),
            f"{path.name} repeats or empties: {field_label}",
        )
        fields[field_label] = value
        observed_order.append(field_label)
    missing = sorted(expected_fields - set(fields))
    if missing:
        raise ValidationError(f"{path.name} is missing: {missing[0]}")
    require(
        tuple(observed_order) == field_order,
        f"{path.name} fields are not in canonical schema order",
    )
    return fields


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--support-commit", required=True)
    parser.add_argument("--support-manifest", required=True, type=Path)
    parser.add_argument("--expected-kernel-dtb-sha256", required=True)
    parser.add_argument("--actual-layout", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    regular_input(args.manifest, "image-build manifest")
    regular_input(args.image, "raw image")
    regular_input(args.support_manifest, "expected support manifest")
    support_commit = args.support_commit.lower()
    require(bool(OID.fullmatch(support_commit)), "support commit is not an exact object ID")
    fields = read_fields(args.manifest)
    expected_kernel_dtb_sha256 = args.expected_kernel_dtb_sha256.lower()
    require(
        bool(SHA256.fullmatch(expected_kernel_dtb_sha256)),
        "expected kernel DTB SHA-256 is invalid",
    )
    image_size = args.image.stat().st_size
    comparisons = {
        "Schema": "sp11-live-image-build-v1",
        "Build completed": "true",
        "Embedded ISO path": "iso/ubuntu-x1e.iso",
        "Embedded DTB path": "dtb/sp11-denali.dtb",
        "Partition table": "gpt",
        "Logical sector size": "512",
        "Partition count": "2",
        "Partition 1 start sector": "2048",
        "Partition 1 end sector": "1050623",
        "Partition 1 sector count": "1048576",
        "Partition 1 type GUID": ESP_TYPE_GUID,
        "Partition 1 name": "SP11EFI",
        "Partition 1 flags": "boot,esp",
        "Partition 1 filesystem": "fat32",
        "Partition 1 filesystem label": "SP11EFI",
        "Partition 2 start sector": "1050624",
        "Partition 2 type GUID": DATA_TYPE_GUID,
        "Partition 2 name": "SP11DATA",
        "Partition 2 flags": "none",
        "Partition 2 filesystem": "ext4",
        "Partition 2 filesystem label": "SP11DATA",
        "ESP boot path": "EFI/BOOT/BOOTAA64.EFI",
        "ESP README path": "README.txt",
        "ESP README size": str(ESP_README_SIZE),
        "ESP README SHA256": ESP_README_SHA256,
        "Builder image": BUILDER_IMAGE,
        "Builder platform": "linux/arm64/v8",
        "Support commit": support_commit,
        "Support manifest": ".sp11-support-tree-v1",
        "Support manifest SHA256": sha256_file(args.support_manifest),
        "Output image file": args.image.name,
        "Output image size": str(image_size),
        "Output image SHA256": sha256_file(args.image),
    }
    for label, expected in comparisons.items():
        require(fields[label] == expected, f"image-build manifest does not match: {label}")
    require(public_https_url(fields["Input ISO URL"]), "input ISO URL is not public HTTPS")
    for label in (
        "Expected ISO SHA256",
        "Input ISO SHA256",
        "Embedded ISO SHA256",
        "Embedded DTB SHA256",
        "ESP boot SHA256",
        "ESP README SHA256",
    ):
        require(bool(SHA256.fullmatch(fields[label])), f"image-build manifest has an invalid {label}")
    require(
        fields["Input ISO SHA256"] == fields["Expected ISO SHA256"],
        "input ISO does not match its predeclared expected SHA-256",
    )
    require(
        fields["Desktop"] in ("gnome", "kde")
        and fields["GRUB mode"] in ("menu", "direct"),
        "image-build desktop or GRUB mode is invalid",
    )
    if fields["Desktop"] == "gnome":
        require(
            fields["Embedded ISO SHA256"] == fields["Input ISO SHA256"],
            "GNOME embedded ISO is not the exact pinned input ISO",
        )
    require(bool(SAFE_DTB_SOURCE.fullmatch(fields["DTB source"])), "DTB source is unsafe")
    require(
        fields["DTB source"] == "kernel-output:denali-oled-dtb",
        "publishable image DTB must come from the bound denali-oled-dtb kernel output",
    )
    require(
        fields["Embedded DTB SHA256"] == expected_kernel_dtb_sha256,
        "embedded DTB does not match the bound denali-oled-dtb kernel output",
    )
    require(bool(SAFE_NAME.fullmatch(args.image.name)), "raw image basename is unsafe")
    require(bool(POSITIVE.fullmatch(fields["Output image size"])), "output image size is invalid")
    for label in (
        "Partition 1 start sector",
        "Partition 1 end sector",
        "Partition 1 sector count",
        "Partition 2 start sector",
        "Partition 2 end sector",
        "Partition 2 sector count",
        "ESP boot size",
        "ESP README size",
    ):
        require(bool(POSITIVE.fullmatch(fields[label])), f"image-build manifest has an invalid {label}")
    require(image_size % 512 == 0, "raw image size is not a whole number of sectors")
    require(image_size % (1024 * 1024) == 0, "raw image size is not a whole number of MiB")
    expected_data_end = image_size // 512 - 2049
    require(expected_data_end >= 1050624, "raw image is too small for the fixed GPT layout")
    require(
        int(fields["Partition 2 end sector"]) == expected_data_end,
        "partition 2 does not end at the exact aligned sector",
    )
    require(
        int(fields["Partition 2 sector count"]) == expected_data_end - 1050624 + 1,
        "partition 2 sector count is inconsistent",
    )
    if args.actual_layout is not None:
        regular_input(args.actual_layout, "actual raw-image layout")
        actual_layout = read_fields(
            args.actual_layout,
            field_order=LAYOUT_FIELD_ORDER,
            description="actual raw-image layout",
        )
        for label in LAYOUT_FIELD_ORDER:
            require(
                actual_layout[label] == fields[label],
                f"raw image does not match image-build manifest: {label}",
            )
    print("Validated complete SP11 image-build provenance.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
