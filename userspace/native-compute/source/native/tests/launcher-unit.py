#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Exercise only a libc-only launcher and an explicitly supplied local mock.

The genuine SDK worker is never an input, copied, discovered or invoked by this
harness. These finite fixtures establish admission and executable resolution,
not a sandbox for arbitrary executables or a hardware/runtime qualification.
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import time

LIMIT = 64 * 1024
INPUT_LIMIT = 16 * 1024 * 1024
TIMEOUT = 5.0
MARKER = b"launcher-worker-mock: constructor\n"
ORACLE = ("launcher-unit: 27 cases passed (LIBC-ONLY LAUNCHER; "
          "LOCAL MOCK WORKER ONLY; genuine SDK worker never executed)\n")
BAD_ARCH = b"Expected architecture must be an explicit nonzero hex byte.\n"
MISMATCH = b"Requested architecture differs from this client's paired skeleton build.\n"
PREFIX = ["--run-cdsp", "--expect-arch"]


def identity(info):
    return [info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def digest(raw):
    return {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def write_new(path, raw, mode=0o600):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                         os.O_CLOEXEC | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fchmod(stream.fileno(), mode)


def write_json(path, value):
    write_new(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def canonical_input(argument):
    path = Path(argument)
    if not path.is_absolute() or str(path.resolve(strict=True)) != argument:
        raise ValueError("binary input must be an absolute canonical path")
    candidate = path.lstat()
    if (not stat.S_ISREG(candidate.st_mode) or not candidate.st_mode & 0o111 or
            candidate.st_nlink != 1 or candidate.st_uid != os.getuid() or
            candidate.st_size > INPUT_LIMIT):
        raise ValueError("binary input must be an owned bounded regular executable")
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if identity(before) != identity(candidate):
            raise ValueError("binary input changed before opening")
        with os.fdopen(os.dup(descriptor), "rb") as stream:
            raw = stream.read(INPUT_LIMIT + 1)
        if len(raw) != before.st_size or identity(os.fstat(descriptor)) != identity(before):
            raise ValueError("binary input changed while being read")
        if identity(path.lstat()) != identity(before):
            raise ValueError("binary input path changed")
        return {"path": str(path), "identityBefore": identity(before),
                **digest(raw)}, descriptor, raw
    except BaseException:
        os.close(descriptor)
        raise


def finish_input(record, descriptor, expected):
    os.lseek(descriptor, 0, os.SEEK_SET)
    with os.fdopen(os.dup(descriptor), "rb") as stream:
        actual = stream.read(INPUT_LIMIT + 1)
    record["identityAfter"] = identity(os.fstat(descriptor))
    record["after"] = digest(actual)
    if (actual != expected or record["identityAfter"] != record["identityBefore"] or
            identity(Path(record["path"]).lstat()) != record["identityBefore"]):
        raise ValueError("binary input changed during launcher tests")


def run_child(executable, argv, cwd, environment, folder):
    outputs = {"stdout": bytearray(), "stderr": bytearray()}
    result = {"executable": str(executable), "argv": argv, "cwd": str(cwd),
              "environment": environment,
              "timeoutSeconds": TIMEOUT, "streamLimitBytes": LIMIT,
              "failure": None, "cleanupErrors": []}
    process = None
    selector = selectors.DefaultSelector()
    started = time.monotonic()
    try:
        process = subprocess.Popen(argv, executable=str(executable), cwd=cwd,
                                   env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   close_fds=True, start_new_session=True)
        for name, pipe in (("stdout", process.stdout), ("stderr", process.stderr)):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, name)
        while selector.get_map() or process.poll() is None:
            remaining = TIMEOUT - (time.monotonic() - started)
            if remaining <= 0:
                raise TimeoutError("owned child exceeded five seconds")
            for key, _events in selector.select(min(remaining, 0.05)):
                try:
                    chunk = os.read(key.fileobj.fileno(), min(8192, LIMIT - len(outputs[key.data]) + 1))
                except (BlockingIOError, InterruptedError):
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                available = LIMIT - len(outputs[key.data])
                outputs[key.data].extend(chunk[:available])
                if len(chunk) > available:
                    raise ValueError(key.data + " exceeded 64 KiB")
    except Exception as error:
        result["failure"] = type(error).__name__ + ": " + str(error)
    finally:
        if process is not None:
            # The reviewed fixtures only exec; they never spawn descendants.
            # Do not signal a group after poll/wait has reaped its leader.
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                except OSError as error:
                    result["cleanupErrors"].append("TERM: " + str(error))
                try:
                    process.wait(timeout=0.25)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    except OSError as error:
                        result["cleanupErrors"].append("KILL: " + str(error))
                    try:
                        process.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        result["cleanupErrors"].append("owned child did not reap")
            result["exit"] = process.returncode
            for pipe in (process.stdout, process.stderr):
                pipe.close()
        selector.close()
        result["seconds"] = time.monotonic() - started
        result["streams"] = {}
        for name, raw in outputs.items():
            write_new(folder / name, raw)
            result["streams"][name] = {"file": name, **digest(raw)}
    return result, bytes(outputs["stdout"]), bytes(outputs["stderr"])


def cases():
    rows = [("no-arguments", [], "usage"), ("help", ["--help"], "usage"),
            ("wrong-first-flag", ["--other", "--expect-arch", "0x73"], "usage"),
            ("wrong-second-flag", ["--run-cdsp", "--other", "0x73"], "usage"),
            ("missing-architecture", PREFIX, "usage"),
            ("extra-argument", PREFIX + ["0x73", "extra"], "usage")]
    for name, value in (("empty", ""), ("malformed", "0xgg"),
                        ("trailing-junk", "0x73tail"), ("zero", "0x0"),
                        ("over-byte", "0x100"),
                        ("overflow", "0x100000000000000000000000000000000000"),
                        ("negative-sign", "-0x73"), ("positive-sign", "+0x73"),
                        ("leading-space", " 0x73"), ("trailing-space", "0x73 "),
                        ("missing-prefix", "73"), ("uppercase-prefix", "0X73"),
                        ("bare-prefix", "0x")):
        rows.append((name, PREFIX + [value], "bad-arch"))
    rows.append(("wrong-paired-byte", PREFIX + ["0x75"], "mismatch"))
    for name in ("canonical", "legacy-padded", "worker-nonzero", "missing-worker",
                 "changed-cwd", "spoofed-argv0", "symlink-launcher"):
        rows.append((name, PREFIX + ["0x073" if name == "legacy-padded" else "0x73"],
                     "missing-worker" if name == "missing-worker" else "dispatch"))
    if len(rows) != 27:
        raise AssertionError("source-derived case roster changed")
    return rows


def mock_stdout(worker, argv, exit_status):
    text = MARKER.decode() + "launcher-worker-mock: argc=%d exit=%d\n" % (len(argv), exit_status)
    text += "exe.hex=" + os.fsencode(worker).hex() + "\n"
    for index, argument in enumerate(argv):
        text += "argv[%d].hex=%s\n" % (index, os.fsencode(argument).hex())
    return text.encode()


def run_case(number, row, output, launcher_raw, worker_raw):
    name, arguments, kind = row
    folder = output / ("%02d-%s" % (number, name))
    folder.mkdir(mode=0o700)
    real, impostor = folder / "real", folder / "impostor"
    real.mkdir(mode=0o700)
    impostor.mkdir(mode=0o700)
    launcher, worker = real / "compute-client", real / "compute-rpc-worker"
    write_new(launcher, launcher_raw, 0o700)
    if kind != "missing-worker":
        write_new(worker, worker_raw, 0o700)
    write_new(impostor / "compute-rpc-worker", worker_raw, 0o700)
    copied = [launcher, impostor / "compute-rpc-worker"]
    if kind != "missing-worker":
        copied.append(worker)
    copied_before = {str(path.relative_to(folder)): {
        "identity": identity(path.lstat()), **digest(path.read_bytes())} for path in copied}
    executable, argv0, cwd = launcher, str(launcher), real
    if name in ("changed-cwd", "spoofed-argv0", "symlink-launcher", "missing-worker"):
        cwd = impostor
    if name in ("spoofed-argv0", "symlink-launcher"):
        argv0 = str(impostor / "compute-client")
    if name == "symlink-launcher":
        executable = impostor / "compute-client"
        executable.symlink_to(launcher)
    argv = [argv0] + arguments
    worker_exit = 23 if name == "worker-nonzero" else 0
    environment = {"PATH": str(impostor) + ":/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "TZ": "UTC",
                   "SP11_LAUNCHER_MOCK_EXIT": str(worker_exit)}
    expected_stdout, expected_stderr = b"", b""
    expected_exit = worker_exit if kind == "dispatch" else 1
    if kind == "usage":
        expected_stderr = ("Usage: %s --run-cdsp --expect-arch 0xNN\n"
                           "Requires separately qualified CDSP firmware/runtime and architecture.\n"
                           "This executes real DSP RPC; it is not a passive diagnostic.\n" % argv0).encode()
    elif kind == "bad-arch":
        expected_stderr = BAD_ARCH
    elif kind == "mismatch":
        expected_stderr = MISMATCH
    elif kind == "missing-worker":
        expected_stderr = ("Could not execute sibling compute-rpc-worker (errno %d).\n" % errno.ENOENT).encode()
    else:
        expected_stdout = mock_stdout(worker, argv, worker_exit)
    result, stdout, stderr = run_child(executable, argv, cwd, environment, folder)
    result.update({"name": name, "kind": kind, "expectedExit": expected_exit,
                   "expectedStdout": digest(expected_stdout), "expectedStderr": digest(expected_stderr),
                   "fixtureBinaryBefore": copied_before})
    discrepancies = []
    if result.get("exit") != expected_exit or stdout != expected_stdout or stderr != expected_stderr:
        discrepancies.append("exact exit/stdout/stderr oracle mismatch")
    marked = stdout.startswith(MARKER)
    result["constructorExecuted"] = marked
    result["marker"] = {"medium": "stdout", "present": marked, **digest(MARKER)}
    if marked != (kind == "dispatch"):
        discrepancies.append("constructor dispatch cardinality mismatch")
    result["fixtureBinaryAfter"] = {str(path.relative_to(folder)): {
        "identity": identity(path.lstat()), **digest(path.read_bytes())} for path in copied}
    if result["fixtureBinaryAfter"] != copied_before:
        discrepancies.append("copied binary bytes or identity changed")
    result["discrepancies"] = discrepancies
    result["passed"] = not discrepancies and result["failure"] is None and not result["cleanupErrors"]
    write_json(folder / "RESULT.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--mock-worker", required=True)
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()
    output = Path(arguments.output)
    if (not output.is_absolute() or str(output.parent.resolve(strict=True) / output.name) != arguments.output or
            not output.parent.is_dir() or output.parent.stat().st_uid != os.getuid() or os.path.lexists(output)):
        parser.error("output must be absent with an absolute canonical owned parent")
    output.mkdir(mode=0o700)
    result = {"schema": "sp11-r86-launcher-unit-v1", "status": "failed",
              "genuineSDKWorkerExecuted": False, "expectedCases": 27,
              "records": [], "binaryInputs": {}, "failure": None, "cleanupErrors": []}
    held = []
    try:
        for label, path in (("launcher", arguments.launcher), ("mockWorker", arguments.mock_worker)):
            record, descriptor, raw = canonical_input(path)
            result["binaryInputs"][label] = record
            held.append((record, descriptor, raw))
        for number, row in enumerate(cases(), 1):
            record = run_case(number, row, output, held[0][2], held[1][2])
            result["records"].append(record)
            if not record["passed"]:
                raise ValueError("case failed: " + record["name"])
        rejected = sum(record["kind"] in ("usage", "bad-arch", "mismatch") for record in result["records"])
        dispatched = sum(record["kind"] == "dispatch" for record in result["records"])
        missing = sum(record["kind"] == "missing-worker" for record in result["records"])
        markers = sum(record["constructorExecuted"] for record in result["records"])
        if (rejected, dispatched, missing, markers) != (20, 6, 1, 6):
            raise AssertionError("source-derived case cardinalities changed")
        result.update({"cases": len(result["records"]), "invalidAdmissionCases": rejected,
                       "admittedDispatchCases": dispatched, "missingWorkerCases": missing,
                       "constructorMarkers": markers, "status": "passed"})
    except Exception as error:
        result["failure"] = type(error).__name__ + ": " + str(error)
    finally:
        for record, descriptor, raw in held:
            try:
                finish_input(record, descriptor, raw)
            except Exception as error:
                result["cleanupErrors"].append("input identity: " + str(error))
                result["status"] = "failed"
                if result["failure"] is None:
                    result["failure"] = "input identity changed"
            finally:
                os.close(descriptor)
        result["casesCompleted"] = len(result["records"])
        write_json(output / "RESULT.json", result)
    if result["status"] != "passed":
        print("launcher-unit failed: " + str(result["failure"]), file=sys.stderr)
        return 1
    sys.stdout.write(ORACLE)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
