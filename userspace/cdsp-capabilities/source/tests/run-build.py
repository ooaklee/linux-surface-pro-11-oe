#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Fresh native build and finite offline software checks. No device passthrough."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_source(source):
    manifest = json.loads((source / "SOURCE-MANIFEST.json").read_text())
    if any(path.is_symlink() for path in source.rglob("*")):
        raise ValueError("source symlinks are not supported")
    actual = {p.relative_to(source).as_posix() for p in source.rglob("*") if p.is_file()}
    if actual != set(manifest["files"]) | {"SOURCE-MANIFEST.json", "SHA256SUMS"}:
        raise ValueError("source roster mismatch")
    for name, record in manifest["files"].items():
        path = source / name
        if path.is_symlink() or not path.is_file() or digest(path) != record["sha256"]:
            raise ValueError("source hash/type mismatch: " + name)
        if path.stat().st_size != record["bytes"]:
            raise ValueError("source size mismatch: " + name)
        if path.stat().st_mode & 0o7777 != record["mode"]:
            raise ValueError("source mode mismatch: " + name)
    checksums = {name: row["sha256"] for name, row in manifest["files"].items()}
    checksums["SOURCE-MANIFEST.json"] = digest(source / "SOURCE-MANIFEST.json")
    expected = "".join(checksums[name] + "  " + name + "\n" for name in sorted(checksums))
    if (source / "SHA256SUMS").read_text() != expected:
        raise ValueError("checksum roster mismatch")
    return digest(source / "SOURCE-MANIFEST.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise ValueError("new absolute output directory required")
    if source == output or source in output.parents or os.getuid() == 0:
        raise ValueError("nonroot, disjoint source/output required")
    manifest_sha = verify_source(source)
    output.mkdir(mode=0o700)
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
                   "HOME": str(output), "TMPDIR": str(output)}
    commands = []

    def run(name, command, expected=None):
        so, se = output / (name + ".stdout"), output / (name + ".stderr")
        with so.open("xb") as stdout, se.open("xb") as stderr:
            value = subprocess.run(command, cwd=output, env=environment,
                stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, timeout=30,
                check=False)
        if so.stat().st_size + se.stat().st_size > 1 << 20:
            raise ValueError("captured output bound exceeded")
        row = {"name": name, "argv": command, "exit": value.returncode,
               "stdout": {"bytes": so.stat().st_size, "sha256": digest(so)},
               "stderr": {"bytes": se.stat().st_size, "sha256": digest(se)}}
        commands.append(row)
        with (output / (name + ".json")).open("x") as stream:
            json.dump(row, stream, indent=2); stream.write("\n")
        if value.returncode != 0 or se.read_bytes() or expected is not None and so.read_bytes() != expected:
            raise ValueError("command failure or unexpected diagnostics/oracle: " + name)
        return so.read_bytes()

    run("machine", ["/usr/bin/uname", "-m"], b"aarch64\n")
    make = ["/usr/bin/make", "-f", str(source / "Makefile"), "SRCDIR=" + str(source)]
    run("build", make + ["all", "query-unit"])
    libraries = {}
    for name in ("cdsp-capabilities", "query-unit"):
        raw = run(name + "-dynamic", ["/usr/bin/readelf", "-dW", str(output / name)])
        libraries[name] = re.findall(rb"\(NEEDED\).*?\[(.*?)\]", raw)
        if libraries[name] not in ([b"libc.so.6"], [b"libc.so.6", b"ld-linux-aarch64.so.1"]):
            raise ValueError("unexpected linked library: " + name)
        raw = run(name + "-header", ["/usr/bin/readelf", "-hW", str(output / name)])
        if not all(pattern in raw for pattern in (b"ELF64", b"little endian", b"AArch64")):
            raise ValueError("unexpected ELF machine/class/byte order")
        raw = run(name + "-segments", ["/usr/bin/readelf", "-lW", str(output / name)])
        if re.findall(rb"Requesting program interpreter: ([^\]]+)", raw) != [b"/lib/ld-linux-aarch64.so.1"]:
            raise ValueError("unexpected program interpreter")
    run("query-unit", [str(output / "query-unit")],
        b"query-unit: 15 cases passed (WRAPPED SYSCALLS ONLY; no device execution)\n")
    raw = run("cli", ["/usr/bin/python3", "-I", "-B", str(source / "tests/check-cli.py"),
                      str(output / "cdsp-capabilities")])
    cli = json.loads(raw)
    if cli["status"] != "passed" or cli["count"] != 11:
        raise ValueError("CLI oracle mismatch")
    if verify_source(source) != manifest_sha:
        raise ValueError("source manifest changed")
    result = {"status": "passed", "manifestSHA256": manifest_sha, "commands": commands,
        "artifacts": {name: {"bytes": (output / name).stat().st_size,
                                "sha256": digest(output / name)}
                      for name in ("cdsp-capabilities", "query-unit")},
        "neededLibraries": {name: [x.decode() for x in values] for name, values in libraries.items()},
        "queryUnitCases": 15, "cliCases": 11, "deviceExecuted": False,
        "DSPFirmwareQueried": False, "SDKWorkerLoaded": False,
        "runtimeQualified": False,
        "scope": "Native Linux ARM64 compiler/ELF, wrapped syscalls and absent-node CLI evidence only"}
    with (output / "RESULT.json").open("x") as stream:
        json.dump(result, stream, indent=2); stream.write("\n")
    print(json.dumps({"status": "passed", "commands": len(commands),
        "resultSHA256": digest(output / "RESULT.json"), "runtimeQualified": False}))


if __name__ == "__main__":
    main()
