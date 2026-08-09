#!/usr/bin/env python3
"""Validate the pinned OCI index and its unique ARM64 platform descriptor."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
INDEX_REF_RE = re.compile(r"^[a-z0-9][a-z0-9._:/-]*@(sha256:[0-9a-f]{64})$")


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"error: {message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-index", required=True, type=Path)
    parser.add_argument("--index-ref", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--expected-platform-manifest", required=True)
    return parser.parse_args()


def main() -> None:
    if sys.flags.isolated != 1:
        fail("OCI index validator requires isolated Python startup")
    args = parse_args()
    match = INDEX_REF_RE.fullmatch(args.index_ref)
    if not match:
        fail("index reference must contain an immutable sha256 digest")
    expected_index_digest = match.group(1)
    if not DIGEST_RE.fullmatch(args.expected_platform_manifest):
        fail("expected platform manifest must be a sha256 digest")

    platform_parts = args.platform.split("/")
    if len(platform_parts) not in (2, 3):
        fail("platform must be os/architecture[/variant]")
    expected_os, expected_arch = platform_parts[:2]
    expected_variant = platform_parts[2] if len(platform_parts) == 3 else None

    try:
        raw = args.raw_index.read_bytes()
    except OSError as exc:
        fail(f"could not read raw OCI index: {exc}")
    actual_index_digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    if actual_index_digest != expected_index_digest:
        fail(
            "raw OCI index digest does not match the pinned reference: "
            f"{actual_index_digest}"
        )

    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"raw OCI index is not valid JSON: {exc}")
    if document.get("schemaVersion") != 2:
        fail("OCI index schemaVersion must be 2")
    if document.get("mediaType") not in (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    ):
        fail("document is not an OCI index or Docker manifest list")
    manifests = document.get("manifests")
    if not isinstance(manifests, list):
        fail("OCI index manifests must be an array")

    matches: list[dict[str, object]] = []
    for descriptor in manifests:
        if not isinstance(descriptor, dict):
            fail("OCI index contains a non-object descriptor")
        digest = descriptor.get("digest")
        size = descriptor.get("size")
        platform = descriptor.get("platform")
        if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
            fail("OCI index descriptor has an invalid digest")
        if not isinstance(size, int) or size <= 0:
            fail("OCI index descriptor has an invalid size")
        if not isinstance(platform, dict):
            continue
        if platform.get("os") != expected_os or platform.get("architecture") != expected_arch:
            continue
        if expected_variant is not None and platform.get("variant") != expected_variant:
            continue
        matches.append(descriptor)

    if len(matches) != 1:
        fail(
            f"OCI index must contain exactly one {args.platform} descriptor; "
            f"found {len(matches)}"
        )
    actual_platform_digest = matches[0]["digest"]
    if actual_platform_digest != args.expected_platform_manifest:
        fail(
            "OCI platform manifest does not match the baseline: "
            f"{actual_platform_digest}"
        )

    print(
        "Validated OCI index "
        f"{expected_index_digest} with {args.platform} child {actual_platform_digest}"
    )


if __name__ == "__main__":
    main()
