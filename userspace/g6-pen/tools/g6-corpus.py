#!/usr/bin/env python3
"""Convert Windows HEAT CSV captures and pack deterministic G6 replay files."""

from __future__ import annotations

import argparse
import calendar
import csv
import datetime as dt
import pathlib
import re
import struct
import sys

MAGIC = 0x31483647
ABI_VERSION = 1
HEADER_LEN = 32
MAX_CONTENT = 4349
CORE_REPORTS = {0x0B, 0x0C, 0x0D, 0x1A}
SIDEBAND_REPORTS = {0x07, 0x6E}
ISO_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})"
    r"(?:\.(\d{1,9}))?([+-])(\d{2}):(\d{2})$"
)


def parse_int(text: str, maximum: int) -> int:
    value = int(text, 0)
    if value < 0 or value > maximum:
        raise ValueError(f"integer {text!r} is outside 0..{maximum}")
    return value


def timestamp_ns(text: str) -> int:
    match = ISO_RE.fullmatch(text.strip())
    if not match:
        raise ValueError(f"unsupported timestamp {text!r}")
    year, month, day, hour, minute, second = map(int, match.group(1, 2, 3, 4, 5, 6))
    fraction = int((match.group(7) or "").ljust(9, "0"))
    offset_seconds = (int(match.group(9)) * 60 + int(match.group(10))) * 60
    if match.group(8) == "-":
        offset_seconds = -offset_seconds
    local = dt.datetime(year, month, day, hour, minute, second)
    seconds = calendar.timegm(local.timetuple()) - offset_seconds
    return seconds * 1_000_000_000 + fraction


def iter_g6t(path: pathlib.Path):
    header = False
    with path.open("r", encoding="utf-8") as source:
        for line_number, raw_line in enumerate(source, 1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if not header:
                if line != "G6T1":
                    raise ValueError(f"{path}:{line_number}: missing G6T1 header")
                header = True
                continue
            fields = line.split()
            if len(fields) != 6:
                raise ValueError(f"{path}:{line_number}: expected six fields")
            generation = parse_int(fields[0], 0xFFFFFFFF)
            timestamp = parse_int(fields[1], 0xFFFFFFFFFFFFFFFF)
            sequence = parse_int(fields[2], 0xFFFFFFFF)
            report_id = parse_int(fields[3], 0xFF)
            flags = parse_int(fields[4], 0xFF)
            payload = b"" if fields[5] == "-" else bytes.fromhex(fields[5])
            if len(payload) > MAX_CONTENT:
                raise ValueError(f"{path}:{line_number}: payload exceeds {MAX_CONTENT}")
            yield generation, timestamp, sequence, report_id, flags, payload
    if not header:
        raise ValueError(f"{path}: empty corpus")


def pack_corpus(args: argparse.Namespace) -> None:
    with args.output.open("wb") as output:
        for generation, timestamp, sequence, report_id, flags, payload in iter_g6t(args.input):
            output.write(
                struct.pack(
                    "<IHHIIQIHBB",
                    MAGIC,
                    ABI_VERSION,
                    HEADER_LEN,
                    HEADER_LEN + len(payload),
                    generation,
                    timestamp,
                    sequence,
                    len(payload),
                    report_id,
                    flags,
                )
            )
            output.write(payload)


def windows_csv(args: argparse.Namespace) -> None:
    allowed = CORE_REPORTS | (SIDEBAND_REPORTS if args.include_sideband else set())
    first_timestamp = None
    previous_timestamp = None
    output_sequence = 0
    if args.include_sideband:
        print(
            "WARNING: report 0x6e may contain a device/pen identifier; sanitize the corpus before sharing.",
            file=sys.stderr,
        )
    with args.input.open("r", encoding="utf-8-sig", newline="") as source, args.output.open(
        "w", encoding="utf-8", newline="\n"
    ) as output:
        rows = csv.DictReader(source)
        required = {"Timestamp", "ContentLength", "ReportId", "Hex"}
        if not rows.fieldnames or not required.issubset(rows.fieldnames):
            missing = sorted(required - set(rows.fieldnames or ()))
            raise ValueError(f"missing CSV columns: {', '.join(missing)}")
        output.write("G6T1\n")
        output.write(f"# source={args.input.name}; timestamps are relative to first exported record\n")
        if args.include_sideband:
            output.write("# PRIVACY: 0x6e may contain a device/pen identifier; sanitize before sharing.\n")
        for row_number, row in enumerate(rows, 2):
            report_id = int(row["ReportId"], 0)
            if report_id not in allowed:
                continue
            content_length = int(row["ContentLength"], 0)
            raw = bytes.fromhex(row["Hex"])
            if content_length > MAX_CONTENT:
                raise ValueError(f"row {row_number}: content exceeds {MAX_CONTENT}")
            if len(raw) < 4 + content_length:
                raise ValueError(f"row {row_number}: truncated HID-SPI transfer")
            if raw[3] != report_id:
                raise ValueError(f"row {row_number}: ReportId does not match Hex byte 3")
            encoded_length = raw[1] | raw[2] << 8
            if encoded_length != content_length:
                raise ValueError(f"row {row_number}: ContentLength does not match HID-SPI header")
            absolute = timestamp_ns(row["Timestamp"])
            if first_timestamp is None:
                first_timestamp = absolute
            if previous_timestamp is not None and absolute < previous_timestamp:
                raise ValueError(f"row {row_number}: timestamps moved backwards")
            previous_timestamp = absolute
            output_sequence += 1
            payload = raw[4 : 4 + content_length]
            output.write(
                f"{args.generation} {absolute - first_timestamp} {output_sequence} "
                f"0x{report_id:02x} 0 {payload.hex()}\n"
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    csv_parser = subparsers.add_parser("windows-csv", help="convert hidspi-rx-bodies.csv to G6T1")
    csv_parser.add_argument("input", type=pathlib.Path)
    csv_parser.add_argument("output", type=pathlib.Path)
    csv_parser.add_argument("--generation", type=int, default=1)
    csv_parser.add_argument(
        "--include-sideband",
        action="store_true",
        help="include 0x07/0x6e (privacy: 0x6e may identify a device or pen)",
    )
    csv_parser.set_defaults(function=windows_csv)

    pack_parser = subparsers.add_parser("pack", help="pack G6T1 as concatenated binary G6H1 records")
    pack_parser.add_argument("input", type=pathlib.Path)
    pack_parser.add_argument("output", type=pathlib.Path)
    pack_parser.set_defaults(function=pack_corpus)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.function(args)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
