#!/usr/bin/env python3
"""Render one SP11 IMX681 packed-RAW10 frame as a half-resolution PNG.

This is an inspection aid, not a calibrated image pipeline. By default it
discovers the negotiated Bayer order from the raw validator's saved media
topology and applies a 1st-to-99th-percentile preview stretch. Use --linear
when comparing exposure or gain captures so their relative brightness remains
visible.
"""

from __future__ import annotations

import argparse
from array import array
import math
import os
from pathlib import Path
import re
import struct
from typing import NoReturn
import zlib


WIDTH = 3840
HEIGHT = 2640
STRIDE = 4800
FRAME_SIZE = STRIDE * HEIGHT

BUS_TO_BAYER = {
    "SBGGR10_1X10": "BGGR",
    "SGBRG10_1X10": "GBRG",
    "SGRBG10_1X10": "GRBG",
    "SRGGB10_1X10": "RGGB",
}

BAYER_CELLS = {
    "BGGR": ("B", "G", "G", "R"),
    "GBRG": ("G", "B", "R", "G"),
    "GRBG": ("G", "R", "B", "G"),
    "RGGB": ("R", "G", "G", "B"),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Render one 3840x2640 V4L2 packed-RAW10 IMX681 frame as a "
            "1920x1320 RGB PNG."
        )
    )
    parser.add_argument("input", type=Path, help="raw file produced by the validator")
    parser.add_argument("output", type=Path, help="new PNG path; must not exist")
    parser.add_argument(
        "--frame",
        type=int,
        default=0,
        help="zero-based frame index within the raw file (default: 0)",
    )
    parser.add_argument(
        "--bayer-order",
        choices=("auto", "BGGR", "GBRG", "GRBG", "RGGB"),
        default="auto",
        help=(
            "Bayer order, or auto to read INPUT.media-after.txt / "
            "INPUT.media-before.txt (default: auto)"
        ),
    )
    parser.add_argument(
        "--linear",
        action="store_true",
        help="map 10-bit codes linearly without per-image preview stretching",
    )
    return parser.parse_args()


def fail(message: str) -> NoReturn:
    raise SystemExit(f"ERROR: {message}")


def discover_bayer_order(raw_path: Path) -> str:
    for suffix in (".media-after.txt", ".media-before.txt"):
        topology_path = Path(f"{raw_path}{suffix}")
        try:
            topology = topology_path.read_text(encoding="utf-8")
        except FileNotFoundError:
            continue
        except OSError as error:
            fail(f"could not read {topology_path}: {error}")

        formats = set(re.findall(r"\bS(?:BGGR|GBRG|GRBG|RGGB)10_1X10\b", topology))
        if len(formats) == 1:
            return BUS_TO_BAYER[formats.pop()]
        if formats:
            fail(
                f"{topology_path} contains ambiguous RAW10 Bayer formats: "
                f"{', '.join(sorted(formats))}"
            )

    fail(
        "could not discover one RAW10 Bayer order from the validator sidecars; "
        "pass --bayer-order explicitly after inspecting the saved topology"
    )


def read_frame(raw_path: Path, frame_index: int) -> bytes:
    if frame_index < 0:
        fail("--frame must not be negative")
    try:
        size = raw_path.stat().st_size
    except OSError as error:
        fail(f"could not stat {raw_path}: {error}")
    if not raw_path.is_file():
        fail(f"input is not a regular file: {raw_path}")
    if size == 0 or size % FRAME_SIZE:
        fail(
            f"input size is {size} bytes; expected a positive multiple of "
            f"{FRAME_SIZE}"
        )

    frame_count = size // FRAME_SIZE
    if frame_index >= frame_count:
        fail(f"frame {frame_index} is outside the available range 0..{frame_count - 1}")

    try:
        with raw_path.open("rb") as raw:
            raw.seek(frame_index * FRAME_SIZE)
            frame = raw.read(FRAME_SIZE)
    except OSError as error:
        fail(f"could not read {raw_path}: {error}")
    if len(frame) != FRAME_SIZE:
        fail(f"frame {frame_index} became short while it was being read")
    return frame


def unpack_row(frame: bytes, row_index: int) -> list[int]:
    row = memoryview(frame)[row_index * STRIDE : (row_index + 1) * STRIDE]
    pixels: list[int] = []
    append = pixels.append
    for offset in range(0, STRIDE, 5):
        b0, b1, b2, b3, low = row[offset : offset + 5]
        append((b0 << 2) | (low & 0x03))
        append((b1 << 2) | ((low >> 2) & 0x03))
        append((b2 << 2) | ((low >> 4) & 0x03))
        append((b3 << 2) | ((low >> 6) & 0x03))
    if len(pixels) != WIDTH:
        fail(f"row {row_index} decoded to {len(pixels)} pixels, expected {WIDTH}")
    return pixels


def demosaic_half(frame: bytes, bayer_order: str) -> tuple[array, list[int]]:
    cells = BAYER_CELLS[bayer_order]
    red_index = cells.index("R")
    blue_index = cells.index("B")
    green_indices = tuple(index for index, cell in enumerate(cells) if cell == "G")
    rgb = array("H")
    green_histogram = [0] * 1024

    for row_index in range(0, HEIGHT, 2):
        row0 = unpack_row(frame, row_index)
        row1 = unpack_row(frame, row_index + 1)
        for column in range(0, WIDTH, 2):
            values = (
                row0[column],
                row0[column + 1],
                row1[column],
                row1[column + 1],
            )
            red = values[red_index]
            blue = values[blue_index]
            green = (values[green_indices[0]] + values[green_indices[1]] + 1) // 2
            rgb.extend((red, green, blue))
            green_histogram[green] += 1

    return rgb, green_histogram


def percentile_bounds(histogram: list[int]) -> tuple[int, int]:
    total = sum(histogram)
    lower_rank = max(1, math.ceil(total * 0.01))
    upper_rank = max(1, math.ceil(total * 0.99))

    cumulative = 0
    low = 0
    high = 1023
    for code, count in enumerate(histogram):
        cumulative += count
        if cumulative >= lower_rank:
            low = code
            break
    cumulative = 0
    for code, count in enumerate(histogram):
        cumulative += count
        if cumulative >= upper_rank:
            high = code
            break
    return low, max(low + 1, high)


def make_lookup(histogram: list[int], linear: bool) -> tuple[bytes, int, int]:
    if linear:
        return bytes(round(code * 255 / 1023) for code in range(1024)), 0, 1023

    low, high = percentile_bounds(histogram)
    span = high - low
    lookup = bytes(
        round(255 * (max(0.0, min(1.0, (code - low) / span)) ** 0.45))
        for code in range(1024)
    )
    return lookup, low, high


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def encode_png(rgb: array, lookup: bytes, bayer_order: str, linear: bool) -> bytes:
    output_width = WIDTH // 2
    output_height = HEIGHT // 2
    expected_values = output_width * output_height * 3
    if len(rgb) != expected_values:
        fail(f"demosaic produced {len(rgb)} values, expected {expected_values}")

    scanlines = bytearray()
    value_index = 0
    for _ in range(output_height):
        scanlines.append(0)
        row_end = value_index + output_width * 3
        scanlines.extend(lookup[value] for value in rgb[value_index:row_end])
        value_index = row_end

    description = (
        f"SP11 IMX681 inspection preview; Bayer={bayer_order}; "
        f"mapping={'linear' if linear else '1-99 percentile gamma 0.45'}"
    ).encode("latin-1")
    return b"".join(
        (
            b"\x89PNG\r\n\x1a\n",
            png_chunk(
                b"IHDR",
                struct.pack(">IIBBBBB", output_width, output_height, 8, 2, 0, 0, 0),
            ),
            png_chunk(b"tEXt", b"Description\x00" + description),
            png_chunk(b"IDAT", zlib.compress(bytes(scanlines), 6)),
            png_chunk(b"IEND", b""),
        )
    )


def main() -> None:
    os.umask(0o077)
    args = parse_args()
    bayer_order = (
        discover_bayer_order(args.input)
        if args.bayer_order == "auto"
        else args.bayer_order
    )
    frame = read_frame(args.input, args.frame)
    rgb, histogram = demosaic_half(frame, bayer_order)
    lookup, low, high = make_lookup(histogram, args.linear)
    png = encode_png(rgb, lookup, bayer_order, args.linear)

    try:
        with args.output.open("xb") as output:
            output.write(png)
    except FileExistsError:
        fail(f"output already exists: {args.output}")
    except OSError as error:
        fail(f"could not write {args.output}: {error}")

    mapping = "linear 0..1023" if args.linear else f"preview stretch {low}..{high}"
    print(
        f"Rendered frame {args.frame}: {WIDTH}x{HEIGHT} {bayer_order} RAW10 -> "
        f"{WIDTH // 2}x{HEIGHT // 2} PNG ({mapping})"
    )
    print(f"Output: {args.output}")
    if not args.linear:
        print("This preview is auto-stretched; use --linear for exposure/gain comparisons.")


if __name__ == "__main__":
    main()
