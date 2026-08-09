#!/usr/bin/env python3
"""Validate symlink containment for an exact kernel Git tree."""

from __future__ import annotations

import argparse
from collections import deque
import hashlib
import os
import re
import signal
import stat
import subprocess
import sys


GIT = "/usr/bin/git"
MAX_ENTRIES = 250_000
MAX_PATH_BYTES = 4096
MAX_PATH_DEPTH = 64
MAX_TOTAL_PATH_AND_TARGET_BYTES = 64 * 1024 * 1024
MAX_TREE_OBJECT_BYTES = 4 * 1024 * 1024
MAX_TOTAL_TREE_OBJECT_BYTES = 64 * 1024 * 1024
MAX_SYMLINK_EXPANSIONS = 256
MAX_SYMLINK_RESOLUTION_STEPS = 1_000_000
MAX_SYMLINK_LIVE_BYTES = 4096
MAX_BATCH_HEADER_BYTES = 256
READ_CHUNK_BYTES = 64 * 1024
DIAGNOSTIC_PATH_BYTES = 256
MAX_STREAM_INPUT_BYTES = 2 * 1024 * 1024 * 1024
RELEASE_SIGNALS = frozenset((signal.SIGHUP, signal.SIGINT, signal.SIGTERM))


class ValidationError(Exception):
    """A bounded, user-facing exact-tree validation failure."""


LIVE_PROCESSES = set()
EMPTY_CONFIG_FD = -1
PRIVATE_ROOT_FD = -1
PRIVATE_PARENT_FD = -1
PRIVATE_ROOT_NAME = ""
PRIVATE_ROOT_IDENTITY = None
PRIVATE_CONTROL_FILES = {}
SOURCE_OBJECTS_FD = -1
SOURCE_OBJECTS_PATH = ""
SOURCE_OBJECTS_IDENTITY = None
SOURCE_REPO = ""


def fail(message):
    raise ValidationError(message)


def require_isolated_runtime():
    if sys.flags.isolated != 1:
        fail("validator must be started with Python isolated mode (-I)")
    if not hasattr(signal, "pthread_sigmask") or not hasattr(signal, "SIG_BLOCK"):
        fail("validator requires POSIX signal-mask support")


def interrupted_release_signal(_number, _frame):
    # Leave all release signals blocked while the exception unwinds through
    # exact child cleanup.  The top-level process exits after that cleanup.
    signal.pthread_sigmask(signal.SIG_BLOCK, RELEASE_SIGNALS)
    raise KeyboardInterrupt


def install_release_signal_contract():
    try:
        for release_signal in RELEASE_SIGNALS:
            signal.signal(release_signal, interrupted_release_signal)
    except (OSError, RuntimeError, ValueError):
        fail("validator could not install its release-signal contract")


def establish_child_reaping_contract():
    if not hasattr(signal, "SIGCHLD"):
        fail("validator requires a waitable child-process contract")
    try:
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    except (OSError, RuntimeError, ValueError):
        fail("validator could not establish its child-process contract")
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        fail("validator child processes would not remain waitable")


def require_runtime_contract():
    require_isolated_runtime()
    establish_child_reaping_contract()
    try:
        metadata = os.lstat(GIT)
    except OSError:
        fail("fixed Git executable is unavailable")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail("fixed Git executable is not a regular non-symlinked file")
    if not os.access(GIT, os.X_OK):
        fail("fixed Git executable is not executable")
    initialize_empty_config()


def initialize_empty_config():
    global EMPTY_CONFIG_FD

    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT})
    read_descriptor = -1
    write_descriptor = -1
    try:
        read_descriptor, write_descriptor = os.pipe()
        os.close(write_descriptor)
        write_descriptor = -1
        EMPTY_CONFIG_FD = read_descriptor
        read_descriptor = -1
    except OSError:
        fail("validator could not create its private empty Git configuration")
    finally:
        if read_descriptor >= 0:
            os.close(read_descriptor)
        if write_descriptor >= 0:
            os.close(write_descriptor)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def git_environment():
    if EMPTY_CONFIG_FD < 3:
        fail("private empty Git configuration is unavailable")
    config_path = (
        "/proc/self/fd/" if sys.platform.startswith("linux") else "/dev/fd/"
    ) + str(EMPTY_CONFIG_FD)
    if SOURCE_OBJECTS_FD < 3:
        fail("pinned source object directory is unavailable")
    object_path = (
        "/proc/self/fd/" + str(SOURCE_OBJECTS_FD)
        if sys.platform.startswith("linux")
        else SOURCE_OBJECTS_PATH
    )
    return {
        "HOME": "/",
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "TMPDIR": "/tmp",
        "TZ": "UTC",
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": config_path,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_DIR": ".",
        "GIT_OBJECT_DIRECTORY": object_path,
        "GIT_FLUSH": "1",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_PAGER": "cat",
        "PAGER": "cat",
    }


def git_command(*arguments):
    return [
        GIT,
        "-c",
        "core.commitGraph=false",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
        *arguments,
    ]


def stat_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
    )


def write_all(descriptor, data):
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            fail("private Git view write stopped unexpectedly")
        offset += written


def create_private_file(name, data):
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, 0o600, dir_fd=PRIVATE_ROOT_FD)
        write_all(descriptor, data)
        os.fsync(descriptor)
        os.lseek(descriptor, 0, os.SEEK_SET)
        metadata = os.fstat(descriptor)
        mapping = os.stat(name, dir_fd=PRIVATE_ROOT_FD, follow_symlinks=False)
    except OSError:
        if "descriptor" in locals():
            os.close(descriptor)
        fail("private Git view file creation failed")
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(mapping.st_mode)
        or (metadata.st_dev, metadata.st_ino) != (mapping.st_dev, mapping.st_ino)
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
    ):
        os.close(descriptor)
        fail("private Git view file identity was unsafe")
    PRIVATE_CONTROL_FILES[name] = (descriptor, stat_identity(metadata), data)


def make_private_directory(parent_descriptor, name):
    try:
        os.mkdir(name, 0o700, dir_fd=parent_descriptor)
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_descriptor,
        )
    except OSError:
        fail("private Git view directory creation failed")
    metadata = os.fstat(descriptor)
    mapping = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(mapping.st_mode)
        or (metadata.st_dev, metadata.st_ino) != (mapping.st_dev, mapping.st_ino)
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        os.close(descriptor)
        fail("private Git view directory identity was unsafe")
    return descriptor


def directory_names(descriptor):
    try:
        names = sorted(entry.name for entry in os.scandir(descriptor))
    except OSError:
        fail("private Git view membership could not be inspected")
    if len(names) > 8:
        fail("private Git view membership exceeded its bound")
    return names


def verify_source_objects():
    if SOURCE_OBJECTS_FD < 3 or not SOURCE_OBJECTS_PATH:
        fail("source object directory was not pinned")
    try:
        held = os.fstat(SOURCE_OBJECTS_FD)
        mapped = os.stat(SOURCE_OBJECTS_PATH, follow_symlinks=False)
    except OSError:
        fail("source object directory mapping changed")
    if (
        not stat.S_ISDIR(held.st_mode)
        or stat.S_ISLNK(mapped.st_mode)
        or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
        or (held.st_dev, held.st_ino) != SOURCE_OBJECTS_IDENTITY
    ):
        fail("source object directory identity changed")
    for relative in ("info/alternates", "info/http-alternates"):
        if os.path.lexists(os.path.join(SOURCE_OBJECTS_PATH, relative)):
            fail("source object directory contains untrusted alternate authority")


def verify_private_git_view():
    if PRIVATE_ROOT_FD < 3 or PRIVATE_PARENT_FD < 3 or not PRIVATE_ROOT_NAME:
        fail("private Git view is unavailable")
    try:
        held_root = os.fstat(PRIVATE_ROOT_FD)
        mapped_root = os.stat(
            PRIVATE_ROOT_NAME, dir_fd=PRIVATE_PARENT_FD, follow_symlinks=False
        )
    except OSError:
        fail("private Git view root mapping changed")
    if (
        stat_identity(held_root) != PRIVATE_ROOT_IDENTITY
        or (held_root.st_dev, held_root.st_ino)
        != (mapped_root.st_dev, mapped_root.st_ino)
        or stat.S_IMODE(held_root.st_mode) != 0o700
    ):
        fail("private Git view root identity changed")
    if directory_names(PRIVATE_ROOT_FD) != ["HEAD", "config", "objects", "refs"]:
        fail("private Git view root membership changed")
    for name, (descriptor, expected_identity, expected_data) in PRIVATE_CONTROL_FILES.items():
        try:
            held = os.fstat(descriptor)
            mapped = os.stat(name, dir_fd=PRIVATE_ROOT_FD, follow_symlinks=False)
            os.lseek(descriptor, 0, os.SEEK_SET)
            data = os.read(descriptor, len(expected_data) + 1)
            os.lseek(descriptor, 0, os.SEEK_SET)
        except OSError:
            fail("private Git view control file changed")
        if (
            stat_identity(held) != expected_identity
            or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
            or data != expected_data
        ):
            fail("private Git view control file identity changed")
    verify_source_objects()


def initialize_private_git_view(repo, object_format, scratch_parent):
    global PRIVATE_ROOT_FD, PRIVATE_PARENT_FD, PRIVATE_ROOT_NAME
    global PRIVATE_ROOT_IDENTITY, SOURCE_OBJECTS_FD, SOURCE_OBJECTS_PATH
    global SOURCE_OBJECTS_IDENTITY, SOURCE_REPO

    if not os.path.isabs(scratch_parent) or os.path.realpath(scratch_parent) != scratch_parent:
        fail("scratch parent must be an absolute canonical directory")
    try:
        parent_metadata = os.lstat(scratch_parent)
        if stat.S_ISLNK(parent_metadata.st_mode) or not stat.S_ISDIR(parent_metadata.st_mode):
            fail("scratch parent must be a real directory")
        PRIVATE_PARENT_FD = os.open(
            scratch_parent,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
    except OSError:
        fail("scratch parent could not be pinned")

    for _attempt in range(64):
        candidate = ".sp11-kernel-tree-git." + os.urandom(16).hex()
        try:
            os.mkdir(candidate, 0o700, dir_fd=PRIVATE_PARENT_FD)
        except FileExistsError:
            continue
        except OSError:
            fail("private Git view root could not be created")
        PRIVATE_ROOT_NAME = candidate
        break
    if not PRIVATE_ROOT_NAME:
        fail("private Git view root name could not be reserved")
    try:
        PRIVATE_ROOT_FD = os.open(
            PRIVATE_ROOT_NAME,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=PRIVATE_PARENT_FD,
        )
        root_mapping = os.stat(
            PRIVATE_ROOT_NAME, dir_fd=PRIVATE_PARENT_FD, follow_symlinks=False
        )
    except OSError:
        fail("private Git view root could not be pinned")
    root_metadata = os.fstat(PRIVATE_ROOT_FD)
    if (
        (root_metadata.st_dev, root_metadata.st_ino)
        != (root_mapping.st_dev, root_mapping.st_ino)
        or stat.S_IMODE(root_metadata.st_mode) != 0o700
    ):
        fail("private Git view root mapping was unsafe")
    PRIVATE_ROOT_IDENTITY = stat_identity(root_metadata)

    objects_fd = make_private_directory(PRIVATE_ROOT_FD, "objects")
    refs_fd = make_private_directory(PRIVATE_ROOT_FD, "refs")
    try:
        for name in ("info", "pack"):
            child = make_private_directory(objects_fd, name)
            os.close(child)
        for name in ("heads", "tags"):
            child = make_private_directory(refs_fd, name)
            os.close(child)
    finally:
        os.close(objects_fd)
        os.close(refs_fd)

    repository_version = "0" if object_format == "sha1" else "1"
    config = (
        "[core]\n"
        "\trepositoryformatversion = " + repository_version + "\n"
        "\tbare = true\n"
        "\tcommitGraph = false\n"
    )
    if object_format == "sha256":
        config += "[extensions]\n\tobjectFormat = sha256\n"
    create_private_file("config", config.encode("ascii"))
    create_private_file("HEAD", b"ref: refs/heads/empty\n")

    git_metadata_path = os.path.join(repo, ".git")
    SOURCE_OBJECTS_PATH = os.path.join(git_metadata_path, "objects")
    try:
        git_metadata = os.lstat(git_metadata_path)
        objects_metadata = os.lstat(SOURCE_OBJECTS_PATH)
        if (
            stat.S_ISLNK(git_metadata.st_mode)
            or not stat.S_ISDIR(git_metadata.st_mode)
            or stat.S_ISLNK(objects_metadata.st_mode)
            or not stat.S_ISDIR(objects_metadata.st_mode)
        ):
            fail("source Git metadata/object directory is unsafe")
        SOURCE_OBJECTS_FD = os.open(
            SOURCE_OBJECTS_PATH,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
    except OSError:
        fail("source Git object directory could not be pinned")
    source_objects_metadata = os.fstat(SOURCE_OBJECTS_FD)
    if (source_objects_metadata.st_dev, source_objects_metadata.st_ino) != (
        objects_metadata.st_dev,
        objects_metadata.st_ino,
    ):
        fail("source Git object directory mapping changed")
    SOURCE_OBJECTS_IDENTITY = (
        source_objects_metadata.st_dev,
        source_objects_metadata.st_ino,
    )
    SOURCE_REPO = repo
    PRIVATE_ROOT_IDENTITY = stat_identity(os.fstat(PRIVATE_ROOT_FD))
    verify_private_git_view()


def spawn_registered(arguments, *, repo, stdin=None):
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, RELEASE_SIGNALS)
    process = None
    saved_cwd = -1
    try:
        if repo != SOURCE_REPO:
            fail("Git child repository does not match the pinned source authority")
        if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
            fail("Git child process would not remain waitable")
        verify_private_git_view()
        saved_cwd = os.open(
            ".", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
        )
        os.fchdir(PRIVATE_ROOT_FD)
        process = subprocess.Popen(
            arguments,
            cwd=None,
            env=git_environment(),
            stdin=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            pass_fds=(EMPTY_CONFIG_FD, SOURCE_OBJECTS_FD),
        )
        try:
            LIVE_PROCESSES.add(process)
        except BaseException:
            # Registration is the ownership transfer.  Until it succeeds the
            # exact local process must be stopped and reaped here, while all
            # release signals are still blocked, or top-level cleanup cannot
            # find it.
            try:
                process.poll()
            except OSError:
                pass
            if process.returncode is None:
                try:
                    process.kill()
                except OSError:
                    pass
            try:
                process.wait()
            except (ChildProcessError, OSError):
                pass
            close_process_streams(process)
            raise
    finally:
        if saved_cwd >= 0:
            try:
                os.fchdir(saved_cwd)
            finally:
                os.close(saved_cwd)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    return process


def close_process_streams(process):
    for stream_name in ("stdin", "stdout", "stderr"):
        stream = getattr(process, stream_name, None)
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass


def kill_registered(process):
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, RELEASE_SIGNALS)
    try:
        if process not in LIVE_PROCESSES:
            close_process_streams(process)
            return
        # With SIGCHLD fixed at SIG_DFL, a normally exited child remains a
        # zombie until this exact owner adopts it.  Poll first so cleanup never
        # signals a child which was already reaped by a completed wait call.
        try:
            process.poll()
        except OSError:
            pass
        if process.returncode is None:
            try:
                process.kill()
            except OSError:
                pass
        try:
            process.wait()
        except (ChildProcessError, OSError):
            pass
        LIVE_PROCESSES.discard(process)
        close_process_streams(process)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def reap_registered(process):
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, RELEASE_SIGNALS)
    status = None
    failure = None
    try:
        status = process.wait()
        # Keep release signals blocked through removal from the live-owner set.
        # Popen.wait() may reap in waitpid() before recording returncode.
        LIVE_PROCESSES.discard(process)
    except BaseException as exc:
        failure = exc
    finally:
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        except BaseException as exc:
            if failure is None:
                failure = exc
    if failure is not None:
        kill_registered(process)
        raise failure
    close_process_streams(process)
    verify_private_git_view()
    return status


def kill_all_registered():
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, RELEASE_SIGNALS)
    try:
        for process in list(LIVE_PROCESSES):
            kill_registered(process)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def close_runtime_fds():
    global EMPTY_CONFIG_FD

    if EMPTY_CONFIG_FD >= 0:
        try:
            os.close(EMPTY_CONFIG_FD)
        except OSError:
            pass
        EMPTY_CONFIG_FD = -1


def close_private_git_view():
    global PRIVATE_ROOT_FD, PRIVATE_PARENT_FD, PRIVATE_ROOT_NAME
    global PRIVATE_ROOT_IDENTITY, SOURCE_OBJECTS_FD, SOURCE_OBJECTS_PATH
    global SOURCE_OBJECTS_IDENTITY, SOURCE_REPO

    success = True
    for descriptor, _identity, _data in PRIVATE_CONTROL_FILES.values():
        try:
            os.ftruncate(descriptor, 0)
            os.fsync(descriptor)
        except OSError:
            success = False
        try:
            os.close(descriptor)
        except OSError:
            success = False
    PRIVATE_CONTROL_FILES.clear()
    for descriptor in (SOURCE_OBJECTS_FD, PRIVATE_ROOT_FD, PRIVATE_PARENT_FD):
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                success = False
    SOURCE_OBJECTS_FD = -1
    PRIVATE_ROOT_FD = -1
    PRIVATE_PARENT_FD = -1
    PRIVATE_ROOT_NAME = ""
    PRIVATE_ROOT_IDENTITY = None
    SOURCE_OBJECTS_PATH = ""
    SOURCE_OBJECTS_IDENTITY = None
    SOURCE_REPO = ""
    return success


def run_small(repo, arguments, maximum, label):
    process = spawn_registered(git_command(*arguments), repo=repo)
    try:
        assert process.stdout is not None
        output = process.stdout.read(maximum + 1)
        if len(output) > maximum:
            fail("Git output exceeded the bound while " + label)
        status = reap_registered(process)
    except BaseException:
        kill_registered(process)
        raise
    if status != 0:
        fail("Git failed while " + label)
    return output


def canonical_object_id(value, label):
    if re.fullmatch(r"[0-9a-f]{40}", value):
        return value, "sha1"
    if re.fullmatch(r"[0-9a-f]{64}", value):
        return value, "sha256"
    fail(label + " must be a canonical lowercase full Git object ID")


def object_hasher(object_format):
    if object_format == "sha1":
        return hashlib.sha1()
    if object_format == "sha256":
        return hashlib.sha256()
    fail("unsupported Git object format")


def hash_object(kind, data, object_format):
    digest = object_hasher(object_format)
    digest.update((kind + " " + str(len(data)) + "\0").encode("ascii"))
    digest.update(data)
    return digest.hexdigest()


def read_line_bounded(stream, maximum):
    output = bytearray()
    while len(output) <= maximum:
        byte = stream.read(1)
        if not byte:
            fail("Git object stream ended unexpectedly")
        if byte == b"\n":
            return bytes(output)
        output.extend(byte)
    fail("Git object header exceeded the validation bound")


def read_exact(stream, size):
    output = bytearray()
    while len(output) < size:
        chunk = stream.read(min(READ_CHUNK_BYTES, size - len(output)))
        if not chunk:
            fail("Git object stream ended before its declared size")
        output.extend(chunk)
    return bytes(output)


def request_batch_metadata(process, object_id, expected_type, maximum):
    assert process.stdin is not None
    assert process.stdout is not None
    try:
        process.stdin.write(object_id.encode("ascii") + b"\n")
        process.stdin.flush()
    except (BrokenPipeError, OSError):
        fail("Git object reader stopped unexpectedly")
    header = read_line_bounded(process.stdout, MAX_BATCH_HEADER_BYTES)
    fields = header.split(b" ")
    if len(fields) != 3:
        fail("Git object reader returned malformed metadata")
    try:
        returned_id = fields[0].decode("ascii")
        returned_type = fields[1].decode("ascii")
        size_text = fields[2].decode("ascii")
    except UnicodeDecodeError:
        fail("Git object reader returned non-ASCII metadata")
    if returned_id != object_id or returned_type != expected_type:
        fail("Git object identity or type did not match the exact tree")
    if not re.fullmatch(r"0|[1-9][0-9]*", size_text):
        fail("Git object reader returned a non-canonical size")
    size = int(size_text)
    if size > maximum:
        fail("Git object exceeded the validation size bound")
    return size


def request_batch_object(
    check_process,
    content_process,
    object_id,
    expected_type,
    maximum,
    object_format,
):
    checked_size = request_batch_metadata(
        check_process, object_id, expected_type, maximum
    )
    content_size = request_batch_metadata(
        content_process, object_id, expected_type, maximum
    )
    if content_size != checked_size:
        fail("Git object size changed between bounded metadata and content reads")
    assert content_process.stdout is not None
    data = read_exact(content_process.stdout, content_size)
    if content_process.stdout.read(1) != b"\n":
        fail("Git object reader returned malformed framing")
    if hash_object(expected_type, data, object_format) != object_id:
        fail("Git object bytes did not match their exact object ID")
    return data


def finish_batch_reader(process):
    assert process.stdin is not None
    assert process.stdout is not None
    process.stdin.close()
    process.stdin = None
    if process.stdout.read(1):
        fail("Git object reader returned unexpected trailing output")
    status = reap_registered(process)
    if status != 0:
        fail("Git object reader failed")


def with_batch_readers(repo, callback):
    check_process = spawn_registered(
        git_command("cat-file", "--batch-check"),
        repo=repo,
        stdin=subprocess.PIPE,
    )
    content_process = spawn_registered(
        git_command("cat-file", "--batch"), repo=repo, stdin=subprocess.PIPE
    )
    try:
        result = callback(check_process, content_process)
        finish_batch_reader(check_process)
        finish_batch_reader(content_process)
    except BaseException:
        kill_registered(check_process)
        kill_registered(content_process)
        raise
    return result


def quote_path(path):
    shown = path[:DIAGNOSTIC_PATH_BYTES]
    pieces = []
    for byte in shown:
        if 0x21 <= byte <= 0x7E and byte not in (0x27, 0x5C):
            pieces.append(chr(byte))
        else:
            pieces.append("\\x" + format(byte, "02x"))
    if len(path) > len(shown):
        pieces.append("...#" + hashlib.sha256(path).hexdigest()[:16])
    return "'" + "".join(pieces) + "'"


def validate_member_path(path):
    if not path or len(path) > MAX_PATH_BYTES:
        fail("exact tree contains an empty or oversized member path")
    if path.startswith(b"/") or path.endswith(b"/") or b"\\" in path:
        fail("exact tree contains a non-canonical member path " + quote_path(path))
    if any(byte < 32 or byte == 127 for byte in path):
        fail("exact tree contains a control byte in member path " + quote_path(path))
    components = path.split(b"/")
    if len(components) > MAX_PATH_DEPTH:
        fail("exact tree member path exceeds the depth bound " + quote_path(path))
    if any(component in (b"", b".", b"..") for component in components):
        fail("exact tree contains a non-canonical member path " + quote_path(path))
    return components


def validate_link_target(path, parent_components, target, aggregate_steps):
    member = quote_path(path)
    if not target:
        fail("exact tree symbolic link has an empty target: " + member)
    if len(target) > MAX_PATH_BYTES:
        fail("exact tree symbolic link target exceeds the size bound: " + member)
    if target.startswith(b"/"):
        fail("exact tree symbolic link has an absolute target: " + member)
    if b"\\" in target or any(byte < 32 or byte == 127 for byte in target):
        fail("exact tree symbolic link has an unsafe target: " + member)

    target_components = tuple(target.split(b"/"))
    resolved = list(parent_components)
    for component in target_components:
        aggregate_steps[0] += 1
        if aggregate_steps[0] > MAX_SYMLINK_RESOLUTION_STEPS:
            fail("exact tree symbolic-link resolution exceeded its aggregate work bound")
        if component in (b"", b"."):
            continue
        if component == b"..":
            if not resolved:
                fail("exact tree symbolic link escapes the tree root: " + member)
            resolved.pop()
        else:
            resolved.append(component)
    return target_components, sum(len(component) for component in target_components)


def validate_composed_link_target(
    path,
    parent_components,
    target_components,
    target_component_bytes,
    members,
    link_targets,
    aggregate_steps,
):
    """Expand tracked links as POSIX lookup would, without touching the host tree."""

    member = quote_path(path)
    resolved = list(parent_components)
    pending = deque(target_components)
    resolved_component_bytes = sum(len(component) for component in resolved)
    pending_component_bytes = target_component_bytes
    pending_component_count = len(target_components)
    active_links = set()
    expansions = 0

    while pending:
        aggregate_steps[0] += 1
        if aggregate_steps[0] > MAX_SYMLINK_RESOLUTION_STEPS:
            fail("exact tree symbolic-link resolution exceeded its aggregate work bound")
        live_components = len(resolved) + pending_component_count
        live_bytes = (
            resolved_component_bytes
            + pending_component_bytes
            + max(live_components - 1, 0)
        )
        if len(resolved) > MAX_PATH_DEPTH or live_bytes > MAX_SYMLINK_LIVE_BYTES:
            fail("exact tree symbolic-link resolution exceeded its path bound: " + member)

        component = pending.popleft()
        if isinstance(component, tuple):
            active_links.remove(component)
            continue
        pending_component_count -= 1
        pending_component_bytes -= len(component)
        if component in (b"", b"."):
            continue
        if component == b"..":
            if not resolved:
                fail("exact tree symbolic link escapes the tree root: " + member)
            removed = resolved.pop()
            resolved_component_bytes -= len(removed)
            continue

        candidate = (*resolved, component)
        if len(candidate) > MAX_PATH_DEPTH:
            fail("exact tree symbolic-link resolution exceeded its path bound: " + member)
        mode = members.get(candidate)
        if mode == b"120000":
            if candidate in active_links:
                fail("exact tree symbolic-link resolution contains a cycle: " + member)
            active_links.add(candidate)
            expansions += 1
            if expansions > MAX_SYMLINK_EXPANSIONS:
                fail("exact tree symbolic-link resolution exceeded its expansion bound: " + member)
            nested_components, nested_component_bytes = link_targets[candidate]
            pending.appendleft(candidate)
            pending.extendleft(reversed(nested_components))
            pending_component_count += len(nested_components)
            pending_component_bytes += nested_component_bytes
            continue

        # A missing member or a known non-directory stops actual POSIX lookup.
        # The raw lexical pass above has already proved that the remaining text
        # cannot underflow the tree root without a tracked symlink expansion.
        if mode is None or mode != b"40000":
            return
        resolved.append(component)
        resolved_component_bytes += len(component)

    if len(resolved) > MAX_PATH_DEPTH:
        fail("exact tree symbolic-link resolution exceeded its path bound: " + member)


def parse_tree_object(data, object_format):
    object_id_bytes = 20 if object_format == "sha1" else 32
    entries = []
    offset = 0
    previous_sort_key = None
    seen_names = set()
    while offset < len(data):
        space = data.find(b" ", offset)
        if space < 0:
            fail("exact tree object contains a truncated mode")
        mode = data[offset:space]
        nul = data.find(b"\0", space + 1)
        if nul < 0:
            fail("exact tree object contains an unterminated member name")
        name = data[space + 1 : nul]
        oid_start = nul + 1
        oid_end = oid_start + object_id_bytes
        if oid_end > len(data):
            fail("exact tree object contains a truncated object ID")
        raw_object_id = data[oid_start:oid_end]
        offset = oid_end

        if mode not in (b"100644", b"100755", b"120000", b"40000", b"160000"):
            fail("exact tree object contains a non-canonical member mode")
        if not name or name in (b".", b"..") or b"/" in name:
            fail("exact tree object contains an invalid member name")
        if name in seen_names:
            fail("exact tree object contains a duplicate member name")
        seen_names.add(name)
        sort_key = name + (b"/" if mode == b"40000" else b"")
        if previous_sort_key is not None and sort_key <= previous_sort_key:
            fail("exact tree object has non-canonical member ordering")
        previous_sort_key = sort_key
        entries.append((mode, name, raw_object_id.hex()))
    return entries


def collect_symlinks(check_process, content_process, tree_id, object_format):
    tree_cache = {}
    symlinks = []
    members = {}
    pending = [(tree_id, ())]
    entry_count = 0
    aggregate_bytes = 0
    total_tree_object_bytes = 0

    while pending:
        current_tree, parent_components = pending.pop()
        entries = tree_cache.get(current_tree)
        if entries is None:
            try:
                tree_data = request_batch_object(
                    check_process,
                    content_process,
                    current_tree,
                    "tree",
                    MAX_TREE_OBJECT_BYTES,
                    object_format,
                )
            except ValidationError as exc:
                if parent_components:
                    fail(
                        str(exc)
                        + " for tree member "
                        + quote_path(b"/".join(parent_components))
                    )
                raise
            total_tree_object_bytes += len(tree_data)
            if total_tree_object_bytes > MAX_TOTAL_TREE_OBJECT_BYTES:
                fail("exact tree exceeds the aggregate tree-object byte bound")
            entries = parse_tree_object(tree_data, object_format)
            tree_cache[current_tree] = entries
            if len(tree_cache) > MAX_ENTRIES:
                fail("exact tree exceeds the unique-tree validation bound")

        for mode, name, object_id in entries:
            components = (*parent_components, name)
            path = b"/".join(components)
            validate_member_path(path)
            entry_count += 1
            if entry_count > MAX_ENTRIES:
                fail("exact tree exceeds the entry-count validation bound")
            aggregate_bytes += len(path)
            if aggregate_bytes > MAX_TOTAL_PATH_AND_TARGET_BYTES:
                fail("exact tree exceeds the aggregate path/target byte bound")
            if components in members:
                fail("exact tree contains a duplicate expanded member path")
            members[components] = mode
            if mode == b"40000":
                pending.append((object_id, components))
            elif mode == b"120000":
                symlinks.append((path, components, object_id))
    return symlinks, members, entry_count, aggregate_bytes


def validate_tree(repo, tree_id, scratch_parent):
    tree_id, object_format = canonical_object_id(tree_id, "tree ID")
    initialize_private_git_view(repo, object_format, scratch_parent)
    repository_format = run_small(
        repo,
        ["rev-parse", "--show-object-format"],
        32,
        "reading the repository object format",
    ).strip()
    if repository_format != object_format.encode("ascii"):
        fail("tree ID length does not match the repository object format")
    resolved = run_small(
        repo,
        ["rev-parse", "--verify", tree_id + "^{tree}"],
        128,
        "resolving the exact tree",
    ).strip()
    if resolved != tree_id.encode("ascii"):
        fail("requested object is not the exact canonical tree")

    def validate_objects(check_process, content_process):
        symlinks, members, entry_count, aggregate_bytes = collect_symlinks(
            check_process,
            content_process,
            tree_id,
            object_format,
        )
        target_cache = {}
        link_targets = {}
        aggregate_steps = [0]
        for path, components, object_id in symlinks:
            target = target_cache.get(object_id)
            if target is None:
                try:
                    target = request_batch_object(
                        check_process,
                        content_process,
                        object_id,
                        "blob",
                        MAX_PATH_BYTES,
                        object_format,
                    )
                except ValidationError as exc:
                    fail(str(exc) + " for tree member " + quote_path(path))
                target_cache[object_id] = target
            aggregate_bytes += len(target)
            if aggregate_bytes > MAX_TOTAL_PATH_AND_TARGET_BYTES:
                fail("exact tree exceeds the aggregate path/target byte bound")
            link_targets[components] = validate_link_target(
                path, components[:-1], target, aggregate_steps
            )
        for path, components, _object_id in symlinks:
            validate_composed_link_target(
                path,
                components[:-1],
                *link_targets[components],
                members,
                link_targets,
                aggregate_steps,
            )
        return entry_count, len(symlinks)

    return with_batch_readers(repo, validate_objects)


def bounded_input_limit(value):
    try:
        limit = int(value, 10)
    except ValueError:
        fail("stream byte bound must be a canonical positive decimal integer")
    if str(limit) != value or limit <= 0 or limit > MAX_STREAM_INPUT_BYTES:
        fail("stream byte bound is outside the supported range")
    return limit


def stream_sha256(maximum):
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = sys.stdin.buffer.read(READ_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > maximum:
            fail("input stream exceeded its byte bound")
        digest.update(chunk)
    print(str(total) + "\t" + digest.hexdigest())


def copy_stream_sha256(descriptor, maximum):
    if descriptor not in (10, 11):
        fail("output-copy descriptor is outside the fixed release contract")
    try:
        before = os.fstat(descriptor)
    except OSError:
        fail("output-copy descriptor is unavailable")
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_IMODE(before.st_mode) != 0o600
        or before.st_size != 0
        or before.st_nlink != 1
    ):
        fail("output-copy descriptor is not a new private regular file")
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = sys.stdin.buffer.read(READ_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > maximum:
            fail("input stream exceeded its byte bound")
        offset = 0
        while offset < len(chunk):
            try:
                written = os.write(descriptor, chunk[offset:])
            except OSError:
                fail("held release output write failed")
            if written <= 0:
                fail("held release output write stopped unexpectedly")
            offset += written
        digest.update(chunk)
    try:
        os.fsync(descriptor)
        after = os.fstat(descriptor)
    except OSError:
        fail("held release output could not be synchronized")
    if (
        (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
        or after.st_size != total
        or after.st_nlink != 1
    ):
        fail("held release output identity changed during writing")
    print(str(total) + "\t" + digest.hexdigest())


def validate_deleted_path_stream(repo, maximum):
    if not os.path.isabs(repo) or os.path.realpath(repo) != repo:
        fail("deleted-path repository root must be absolute and canonical")
    try:
        metadata = os.lstat(repo)
    except OSError:
        fail("deleted-path repository root is unavailable")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        fail("deleted-path repository root must be a real directory")

    repo_bytes = os.fsencode(repo)
    buffered = bytearray()
    cursor = 0
    total = 0
    count = 0
    while True:
        chunk = sys.stdin.buffer.read(READ_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > maximum:
            fail("deleted-path stream exceeded its byte bound")
        if cursor:
            del buffered[:cursor]
            cursor = 0
        buffered.extend(chunk)
        while True:
            nul = buffered.find(0, cursor)
            if nul < 0:
                if len(buffered) - cursor > MAX_PATH_BYTES:
                    fail("deleted-path stream contains an oversized member path")
                break
            path = bytes(buffered[cursor:nul])
            cursor = nul + 1
            validate_member_path(path)
            count += 1
            if count > MAX_ENTRIES:
                fail("deleted-path stream exceeded its entry-count bound")
            candidate = os.path.join(repo_bytes, path)
            if os.path.lexists(candidate):
                fail("a path deleted by the exact patched tree reappeared")
    if len(buffered) != cursor:
        fail("deleted-path stream ended without NUL framing")


def parse_arguments(argv):
    parser = argparse.ArgumentParser(
        description="Preflight symlink containment in an exact kernel Git tree."
    )
    parser.add_argument("--repo")
    parser.add_argument("--tree")
    parser.add_argument("--scratch-parent", default="/tmp")
    parser.add_argument("--quiet", action="store_true")
    utilities = parser.add_mutually_exclusive_group()
    utilities.add_argument("--stream-sha256", metavar="MAX_BYTES")
    utilities.add_argument("--copy-sha256-to-fd", metavar="FD")
    utilities.add_argument("--check-deleted-paths", metavar="REPO_ROOT")
    parser.add_argument("--max-input-bytes", default=str(64 * 1024 * 1024))
    return parser.parse_args(argv)


def main(argv):
    args = parse_arguments(argv)
    require_isolated_runtime()
    install_release_signal_contract()
    if args.stream_sha256 is not None:
        if args.repo is not None or args.tree is not None:
            fail("stream hashing does not accept tree-validation arguments")
        stream_sha256(bounded_input_limit(args.stream_sha256))
        return 0
    if args.copy_sha256_to_fd is not None:
        if args.repo is not None or args.tree is not None:
            fail("output copying does not accept tree-validation arguments")
        try:
            descriptor = int(args.copy_sha256_to_fd, 10)
        except ValueError:
            fail("output-copy descriptor must be a canonical integer")
        if str(descriptor) != args.copy_sha256_to_fd:
            fail("output-copy descriptor must be a canonical integer")
        copy_stream_sha256(
            descriptor,
            bounded_input_limit(args.max_input_bytes),
        )
        return 0
    if args.check_deleted_paths is not None:
        if args.repo is not None or args.tree is not None:
            fail("deleted-path checking does not accept tree-validation arguments")
        validate_deleted_path_stream(
            args.check_deleted_paths,
            bounded_input_limit(args.max_input_bytes),
        )
        return 0
    if args.repo is None or args.tree is None:
        fail("exact-tree validation requires --repo and --tree")
    require_runtime_contract()
    if not os.path.isabs(args.repo):
        fail("repository path must be absolute")
    try:
        repo_metadata = os.lstat(args.repo)
    except OSError:
        fail("repository path is unavailable")
    if stat.S_ISLNK(repo_metadata.st_mode) or not stat.S_ISDIR(repo_metadata.st_mode):
        fail("repository path must be a real directory")
    if os.path.realpath(args.repo) != args.repo:
        fail("repository path must be canonical and unaliased")
    entries, symlinks = validate_tree(args.repo, args.tree, args.scratch_parent)
    if not args.quiet:
        print(
            "Validated exact kernel tree symlink containment: "
            + str(entries)
            + " bounded entries, "
            + str(symlinks)
            + " symlinks."
        )
    return 0


if __name__ == "__main__":
    status = 1
    try:
        status = main(sys.argv[1:])
    except ValidationError as exc:
        print("error: " + str(exc), file=sys.stderr)
    except KeyboardInterrupt:
        print("error: exact kernel tree symlink preflight was interrupted", file=sys.stderr)
        status = 130
    except Exception:
        print("error: exact kernel tree validation failed unexpectedly", file=sys.stderr)
    finally:
        # No release signal may interrupt exact child/private-view cleanup.
        # This process exits immediately afterward, so the mask need not be
        # restored and pending terminal signals cannot create an orphan.
        signal.pthread_sigmask(signal.SIG_BLOCK, RELEASE_SIGNALS)
        kill_all_registered()
        if not close_private_git_view() and status == 0:
            print("error: private Git view cleanup failed", file=sys.stderr)
            status = 1
        close_runtime_fds()
    raise SystemExit(status)
