#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Exercise CLI admission and absent-node failure only, never an actual device."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

USAGE = ("Usage: cdsp-capabilities --query-cdsp --device DEVICE\n"
         "DEVICE must be /dev/fastrpc-cdsp or /dev/fastrpc-cdsp-secure.\n"
         "ACTIVE: opening reserves a session; query and close can contact DSP firmware.\n"
         "Advertised capabilities only, not SDK/runtime or NPU qualification.\n").encode()
DEVICES = ("/dev/fastrpc-cdsp", "/dev/fastrpc-cdsp-secure")


def require_absent_nodes():
    for device in DEVICES:
        try:
            os.lstat(device)
        except FileNotFoundError:
            continue
        raise RuntimeError("Tests require isolated Linux with both FastRPC paths absent")


def main():
    if len(sys.argv) != 2:
        raise ValueError("one explicitly built executable is required")
    executable = Path(sys.argv[1]).resolve(strict=True)
    before = executable.stat()
    if not stat.S_ISREG(before.st_mode) or not os.access(executable, os.X_OK):
        raise ValueError("expected regular executable")
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    require_absent_nodes()
    cases = [
        ("help", ["--help"], 0, USAGE, b""),
        ("no-args", [], 1, b"", USAGE),
        ("no-intent", ["--device", DEVICES[0]], 1, b"", USAGE),
        ("missing-device", ["--query-cdsp", "--device"], 1, b"", USAGE),
        ("unknown-device", ["--query-cdsp", "--device", "/dev/fastrpc-adsp"], 1, b"", USAGE),
        ("relative-device", ["--query-cdsp", "--device", "fastrpc-cdsp"], 1, b"", USAGE),
        ("suffix-device", ["--query-cdsp", "--device", DEVICES[0] + "/"], 1, b"", USAGE),
        ("extra-args", ["--query-cdsp", "--device", DEVICES[0], "--help"], 1, b"", USAGE),
    ]
    receipts = []
    for name, arguments, code, stdout, stderr in cases:
        result = subprocess.run([str(executable)] + arguments,
            stdin=subprocess.DEVNULL, capture_output=True, timeout=5, check=False,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"})
        if (result.returncode, result.stdout, result.stderr) != (code, stdout, stderr):
            raise AssertionError((name, result.returncode, result.stdout, result.stderr))
        receipts.append({"name": name, "arguments": arguments, "exit": code,
                         "stdout": result.stdout.decode(), "stderr": result.stderr.decode()})
    for device in DEVICES:
        require_absent_nodes()
        arguments = ["--query-cdsp", "--device", device]
        result = subprocess.run([str(executable)] + arguments,
            stdin=subprocess.DEVNULL, capture_output=True, timeout=5, check=False,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"})
        expected = {"schema": "sp11-cdsp-capabilities-v1", "status": "failed",
            "device": device, "unsigned_pd_raw": None, "architecture_raw": None,
            "unsigned_pd_query": {"attempted": False, "return": None, "errno": None},
            "architecture_query": {"attempted": False, "return": None, "errno": None},
            "error_phase": "open", "errno": 2, "close_errno": 0,
            "device_identity": "trusted-name-and-character-type-only",
            "kernel_cache_freshness": "unknown",
            "runtime_qualified": False, "live_control_rpc_possible": True}
        if result.returncode != 1 or result.stderr or json.loads(result.stdout) != expected:
            raise AssertionError((device, result.returncode, result.stdout, result.stderr))
        receipts.append({"name": "absent-node", "arguments": arguments, "exit": 1,
                         "stdout": result.stdout.decode(), "stderr": ""})
    # Linux's standard /dev/full is a deliberate output-failure sink, not a
    # FastRPC or physical-device fixture. This help-only case never queries.
    with open("/dev/full", "wb", buffering=0) as full:
        result = subprocess.run([str(executable), "--help"],
            stdin=subprocess.DEVNULL, stdout=full, stderr=subprocess.PIPE,
            timeout=5, check=False,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"})
    if result.returncode != 1 or result.stderr:
        raise AssertionError(("help-output-failure", result.returncode, result.stderr))
    receipts.append({"name": "help-output-failure", "arguments": ["--help"],
                     "exit": 1, "stdoutSink": "/dev/full", "stderr": ""})
    require_absent_nodes()
    after = executable.stat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise AssertionError("executable identity changed")
    if hashlib.sha256(executable.read_bytes()).hexdigest() != digest:
        raise AssertionError("executable bytes changed")
    print(json.dumps({"status": "passed", "cases": receipts, "count": len(receipts),
        "scope": "CLI admission and missing-node Linux open failures only; no real FastRPC device or firmware queried"}, sort_keys=True))


if __name__ == "__main__":
    main()
