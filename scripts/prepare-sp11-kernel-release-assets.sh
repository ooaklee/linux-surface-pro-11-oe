#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

sanitize_git_environment() {
  local variable_name

  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
  unset GIT_CONFIG_GLOBAL GIT_DIR GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXEC_PATH
  unset GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_PREFIX
  unset GIT_SHALLOW_FILE GIT_WORK_TREE
  for variable_name in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
    unset "$variable_name"
  done
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_ATTR_NOSYSTEM=1
  export GIT_NO_REPLACE_OBJECTS=1
}

sanitize_git_environment

KERNEL_DEBS_DIR="payload/kernel-debs"
ARTIFACTS_DIR="build/docker-sp11-qcom-x1e-kernel/artifacts"
KERNEL_BASELINE="config/kernel-baselines/7.2-rc5-jg-0.env"
PATCH_DIRS=("patches/ubuntu-qcom-x1e-7.0")
PATCH_DIR_EXPLICIT="false"
OUT_DIR=""
RELEASE_NAME=""
SOURCE_URL="https://git.launchpad.net/~ubuntu-concept/ubuntu/+source/linux/+git/resolute"
SOURCE_BRANCH="qcom-x1e-7.0"
SOURCE_URL_EXPLICIT="false"
SOURCE_BRANCH_EXPLICIT="false"
DOCKER_IMAGE=""
ALLOW_DIRTY="false"
ALLOW_MISSING_SOURCE="false"
SOURCE_ASSETS=()
SOURCE_ASSET_COUNT=0
KERNEL_SOURCE_ASSET=""
TOUCHSCREEN_SOURCE_ASSET=""
KERNEL_SOURCE_ASSET_SHA256=""
TOUCHSCREEN_SOURCE_ASSET_SHA256=""
KERNEL_SOURCE_ASSET_SIZE=""
TOUCHSCREEN_SOURCE_ASSET_SIZE=""
TOUCHSCREEN_MODULES_DIR=""
TOUCHSCREEN_SOURCE_URL=""
TOUCHSCREEN_SOURCE_REF=""
TOUCHSCREEN_ENABLED="false"
TOUCHSCREEN_MODULE_FILES=(
  "gpi.ko"
  "spi-geni-qcom.ko"
  "mshw0485_touch.ko"
)
TOUCHSCREEN_MODULE_MANIFEST="sp11-touchscreen-modules-manifest.txt"
TOUCHSCREEN_SIGNING_CERTIFICATE="sp11-module-signing-cert.x509"
MODULE_SIGNING_POLICY="sp11-controlled-rsa4096-sha512-v1"
FINAL_OUT_DIR=""
OUTPUT_ROOT_FD=52
OUTPUT_ROOT_IDENTITY=""
BUILD_WORK_ROOT_FD=53
BUILD_WORK_ROOT_IDENTITY=""
BUILD_ARTIFACTS_ROOT_FD=54
BUILD_ARTIFACTS_ROOT_IDENTITY=""
PREPARER_FIXTURE_HOOK=""

usage() {
  cat <<EOF
Usage: $0 [options]

Prepares a sanitized GitHub Release asset directory for optional prebuilt
Surface Pro 11 qcom-x1e kernel packages. It does not publish anything.

Options:
  --kernel-debs-dir DIR   Directory containing built qcom-x1e .debs,
                          default $KERNEL_DEBS_DIR.
  --artifacts-dir DIR     Exact Docker work artifacts directory containing the
                          final schema-v2 build manifest, v1 APT sidecar, and
                          v1 build-inputs envelope,
                          default $ARTIFACTS_DIR.
  --patch-dir DIR         Patch directory. Repeat to record ordered patch sets;
                          default ${PATCH_DIRS[0]}.
  --release-name NAME     Release/tag name. If omitted, derived from package
                          version when possible.
  --out-dir DIR           Output directory. If omitted, defaults to
                          build/release/<release-name>.
  --source-url URL        Upstream kernel source URL recorded in the manifest.
  --source-branch NAME    Upstream kernel source branch or tag recorded in the
                          manifest.
  --docker-image IMAGE    Exact digest-pinned Docker image. If supplied, it
                          must match the schema-v2 build manifest; otherwise
                          the helper uses the manifest value.
  --source-asset PATH     XZ-compressed corresponding-source .tar.xz archive
                          to validate and copy. Can be repeated.
  --touchscreen-modules-dir DIR
                          Optional directory containing gpi.ko,
                          spi-geni-qcom.ko, and mshw0485_touch.ko, plus the
                          build manifest when produced by the build helper.
  --touchscreen-source-url URL
                          Source repository URL for the touchscreen modules.
                          Required with --touchscreen-modules-dir.
  --touchscreen-source-ref COMMIT
                          Immutable 40- or 64-character source commit for the
                          touchscreen modules. Required with their directory.
  --allow-dirty           Allow preparing assets when the support repository has
                          uncommitted changes. Intended for local test runs.
  --allow-missing-source  Allow a local draft without source artifacts. The
                          helper will not print a publish command in this mode.
  -h, --help              Show this help.
EOF
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

trusted_regular_file_fingerprint() {
  local path="$1" maximum="$2"

  /usr/bin/python3 -I -c '
import hashlib
import os
import stat
import sys

try:
    maximum = int(sys.argv[2], 10)
    if maximum <= 0:
        raise RuntimeError
    descriptor = os.open(
        sys.argv[1],
        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
    )
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size > maximum
    ):
        raise RuntimeError
    digest = hashlib.sha256()
    offset = 0
    while offset < before.st_size:
        chunk = os.pread(descriptor, min(1048576, before.st_size - offset), offset)
        if not chunk:
            raise RuntimeError
        digest.update(chunk)
        offset += len(chunk)
    after = os.fstat(descriptor)
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
    )
    if stable(before) != stable(after):
        raise RuntimeError
    output = "%d %s\n" % (before.st_size, digest.hexdigest())
except BaseException:
    os.write(2, b"error: trusted regular-file fingerprint failed\n")
    os._exit(1)
finally:
    descriptor = locals().get("descriptor")
    if descriptor is not None:
        try:
            os.close(descriptor)
        except OSError:
            pass
os.write(1, output.encode("ascii"))
' "$path" "$maximum"
}

trusted_regular_file_sha256() {
  local fingerprint fingerprint_re='^([0-9]+) ([0-9a-f]{64})$'

  fingerprint="$(trusted_regular_file_fingerprint "$1" "$2")" || return 1
  if ! [[ "$fingerprint" =~ $fingerprint_re ]]; then
    echo "Trusted regular-file fingerprint is not canonical." >&2
    return 1
  fi
  printf '%s\n' "${BASH_REMATCH[2]}"
}

trusted_baseline_container_authority() {
  local path="$1" expected_sha256="$2"

  /usr/bin/python3 -I -c '
import hashlib
import os
import re
import stat
import sys

descriptor = None
try:
    if not re.fullmatch(r"[0-9a-f]{64}", sys.argv[2]):
        raise RuntimeError
    descriptor = os.open(
        sys.argv[1],
        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
    )
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > 1048576
    ):
        raise RuntimeError
    data = bytearray()
    offset = 0
    while offset < before.st_size:
        chunk = os.pread(descriptor, min(65536, before.st_size - offset), offset)
        if not chunk:
            raise RuntimeError
        data.extend(chunk)
        offset += len(chunk)
    after = os.fstat(descriptor)
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
    )
    if (
        stable(before) != stable(after)
        or hashlib.sha256(data).hexdigest() != sys.argv[2]
    ):
        raise RuntimeError
    text = bytes(data).decode("ascii")
    values = {}
    assignment = re.compile(r"(SP11_KERNEL_DOCKER_(?:IMAGE|PLATFORM))=\"([^\"\\\r\n]+)\"\Z")
    for line in text.splitlines():
        match = assignment.fullmatch(line)
        if match:
            if match.group(1) in values:
                raise RuntimeError
            values[match.group(1)] = match.group(2)
    image = values.get("SP11_KERNEL_DOCKER_IMAGE", "")
    platform = values.get("SP11_KERNEL_DOCKER_PLATFORM", "")
    if (
        not re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", image)
        or not re.fullmatch(r"linux/(?:amd64|arm64)(?:/v[0-9]+)?", platform)
    ):
        raise RuntimeError
    output = image + "\t" + platform + "\n"
except BaseException:
    os.write(2, b"error: trusted baseline container authority failed\n")
    raise SystemExit(1)
finally:
    if descriptor is not None:
        try:
            os.close(descriptor)
        except OSError:
            pass
os.write(1, output.encode("ascii"))
' "$path" "$expected_sha256"
}

copy_verified_regular_exclusive() {
  local source_path="$1" destination_path="$2" expected_size="$3" expected_sha256="$4"

  /usr/bin/python3 -I -c '
import hashlib
import os
import re
import signal
import stat
import sys

source = destination = parent = None
registered = False
committed = False
handled = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, handled)
try:
    expected_size = int(sys.argv[3], 10)
    expected_sha = sys.argv[4]
    name = os.path.basename(sys.argv[2])
    parent_path = os.path.dirname(sys.argv[2])
    parent_descriptor = int(sys.argv[5], 10)
    expected_parent = tuple(int(value, 10) for value in sys.argv[7:12])
    if (
        expected_size < 0
        or expected_size > 17179869184
        or not re.fullmatch(r"[0-9a-f]{64}", expected_sha)
        or not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.+_~:@=-]{0,254}", name)
        or parent_path != sys.argv[6]
        or len(expected_parent) != 5
    ):
        raise RuntimeError
    parent = os.dup(parent_descriptor)
    parent_metadata = os.fstat(parent)
    parent_mapped = os.stat(parent_path, follow_symlinks=False)
    parent_identity = (
        parent_metadata.st_dev,
        parent_metadata.st_ino,
        stat.S_IMODE(parent_metadata.st_mode),
        parent_metadata.st_uid,
        parent_metadata.st_gid,
    )
    mapped_identity = (
        parent_mapped.st_dev,
        parent_mapped.st_ino,
        stat.S_IMODE(parent_mapped.st_mode),
        parent_mapped.st_uid,
        parent_mapped.st_gid,
    )
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_identity != expected_parent
        or mapped_identity != expected_parent
    ):
        raise RuntimeError
    source = os.open(
        sys.argv[1],
        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
    )
    source_before = os.fstat(source)
    if (
        not stat.S_ISREG(source_before.st_mode)
        or source_before.st_nlink != 1
        or source_before.st_size != expected_size
    ):
        raise RuntimeError
    destination = os.open(
        name,
        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
        dir_fd=parent,
    )
    registered = True
    digest = hashlib.sha256()
    offset = 0
    while offset < expected_size:
        chunk = os.pread(source, min(1048576, expected_size - offset), offset)
        if not chunk:
            raise RuntimeError
        view = memoryview(chunk)
        written = 0
        while written < len(view):
            count = os.write(destination, view[written:])
            if count <= 0:
                raise RuntimeError
            written += count
        digest.update(chunk)
        offset += len(chunk)
    os.fchmod(destination, 0o644)
    os.fsync(destination)
    source_after = os.fstat(source)
    destination_after = os.fstat(destination)
    destination_digest = hashlib.sha256()
    destination_offset = 0
    while destination_offset < expected_size:
        chunk = os.pread(
            destination,
            min(1048576, expected_size - destination_offset),
            destination_offset,
        )
        if not chunk:
            raise RuntimeError
        destination_digest.update(chunk)
        destination_offset += len(chunk)
    destination_final = os.fstat(destination)
    parent_final = os.fstat(parent)
    parent_mapped_final = os.stat(parent_path, follow_symlinks=False)
    mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
    )
    if (
        stable(source_before) != stable(source_after)
        or digest.hexdigest() != expected_sha
        or destination_digest.hexdigest() != expected_sha
        or stable(destination_after) != stable(destination_final)
        or not stat.S_ISREG(destination_after.st_mode)
        or destination_after.st_nlink != 1
        or destination_after.st_size != expected_size
        or (destination_after.st_dev, destination_after.st_ino)
        != (mapped.st_dev, mapped.st_ino)
        or (
            parent_final.st_dev,
            parent_final.st_ino,
            stat.S_IMODE(parent_final.st_mode),
            parent_final.st_uid,
            parent_final.st_gid,
        ) != expected_parent
        or (
            parent_mapped_final.st_dev,
            parent_mapped_final.st_ino,
            stat.S_IMODE(parent_mapped_final.st_mode),
            parent_mapped_final.st_uid,
            parent_mapped_final.st_gid,
        ) != expected_parent
    ):
        raise RuntimeError
    os.fsync(parent)
    if signal.sigpending() & handled:
        raise KeyboardInterrupt
    for handled_signal in handled:
        signal.signal(handled_signal, signal.SIG_IGN)
    committed = True
except BaseException:
    if registered and destination is not None:
        try:
            os.ftruncate(destination, 0)
            os.fsync(destination)
        except OSError:
            pass
    os.write(2, b"error: exclusive verified release copy failed\n")
    raise SystemExit(1)
finally:
    signal.pthread_sigmask(signal.SIG_BLOCK, handled)
    for descriptor in (destination, source, parent):
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    if not committed:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
' \
    "$source_path" "$destination_path" "$expected_size" "$expected_sha256" \
    "$OUTPUT_ROOT_FD" "$OUT_DIR" $OUTPUT_ROOT_IDENTITY
}

write_release_text_exclusive() {
  local destination_name="$1" maximum_size="$2"

  /usr/bin/python3 -I -c '
import hashlib
import os
import re
import signal
import stat
import sys

destination = parent = None
registered = False
committed = False
handled = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, handled)
try:
    name = sys.argv[1]
    maximum = int(sys.argv[2], 10)
    parent_descriptor = int(sys.argv[3], 10)
    parent_path = sys.argv[4]
    expected_parent = tuple(int(value, 10) for value in sys.argv[5:10])
    fixture_hook = sys.argv[10]
    if (
        not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.+_~:@=-]{0,254}", name)
        or not 0 < maximum <= 16777216
        or len(expected_parent) != 5
        or fixture_hook not in {
            "",
            "mutate-release-notes-before-register",
            "mutate-output-terminal",
            "mutate-evidence-terminal",
            "mutate-control-terminal",
            "inject-work-member-terminal",
            "inject-artifact-member-terminal",
            "remap-output-root-terminal",
            "remap-work-root-terminal",
            "remap-artifacts-root-terminal",
            "pending-signal-terminal",
            "fail-root-commit",
            "signal-before-terminal-exec",
        }
    ):
        raise RuntimeError
    parent = os.dup(parent_descriptor)
    held_parent = os.fstat(parent)
    mapped_parent = os.stat(parent_path, follow_symlinks=False)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        stat.S_IMODE(value.st_mode),
        value.st_uid,
        value.st_gid,
    )
    if (
        not stat.S_ISDIR(held_parent.st_mode)
        or identity(held_parent) != expected_parent
        or identity(mapped_parent) != expected_parent
    ):
        raise RuntimeError
    destination = os.open(
        name,
        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
        dir_fd=parent,
    )
    registered = True
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = os.read(0, min(65536, maximum + 1 - size))
        if not chunk:
            break
        size += len(chunk)
        if size > maximum:
            raise RuntimeError
        digest.update(chunk)
        view = memoryview(chunk)
        written = 0
        while written < len(view):
            count = os.write(destination, view[written:])
            if count <= 0:
                raise RuntimeError
            written += count
    os.fchmod(destination, 0o644)
    os.fsync(destination)
    before = os.fstat(destination)
    mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
    observed = hashlib.sha256()
    offset = 0
    while offset < size:
        chunk = os.pread(destination, min(65536, size - offset), offset)
        if not chunk:
            raise RuntimeError
        observed.update(chunk)
        offset += len(chunk)
    after = os.fstat(destination)
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
    )
    if (
        size <= 0
        or digest.digest() != observed.digest()
        or stable(before) != stable(after)
        or not stat.S_ISREG(after.st_mode)
        or after.st_nlink != 1
        or after.st_size != size
        or (after.st_dev, after.st_ino) != (mapped.st_dev, mapped.st_ino)
        or identity(os.fstat(parent)) != expected_parent
        or identity(os.stat(parent_path, follow_symlinks=False)) != expected_parent
    ):
        raise RuntimeError
    os.fsync(parent)
    record = ("%d %s\n" % (size, digest.hexdigest())).encode("ascii")
    if fixture_hook == "mutate-release-notes-before-register" and name == "RELEASE-NOTES.md":
        if os.pwrite(destination, b"\0", 0) != 1:
            raise RuntimeError
        os.fsync(destination)
    record_offset = 0
    while record_offset < len(record):
        count = os.write(1, record[record_offset:])
        if count <= 0:
            raise RuntimeError
        record_offset += count
    if signal.sigpending() & handled:
        raise KeyboardInterrupt
    for handled_signal in handled:
        signal.signal(handled_signal, signal.SIG_IGN)
    committed = True
except BaseException:
    if registered and destination is not None:
        try:
            os.ftruncate(destination, 0)
            os.fsync(destination)
        except OSError:
            pass
    os.write(2, b"error: exclusive release text publication failed\n")
    raise SystemExit(1)
finally:
    signal.pthread_sigmask(signal.SIG_BLOCK, handled)
    for descriptor in (destination, parent):
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    if not committed:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
' \
    "$destination_name" "$maximum_size" "$OUTPUT_ROOT_FD" "$OUT_DIR" \
    $OUTPUT_ROOT_IDENTITY "$PREPARER_FIXTURE_HOOK"
}

committed_blob_sha256() {
  local object_spec="$1"

  /usr/bin/git cat-file blob "$object_spec" |
    /usr/bin/python3 -I -c '
import hashlib
import os
import sys

data = sys.stdin.buffer.read(512 * 1024 + 1)
if len(data) > 512 * 1024:
    os.write(2, b"error: committed helper blob exceeds its bound\n")
    raise SystemExit(1)
os.write(1, (hashlib.sha256(data).hexdigest() + "\n").encode("ascii"))
'
}

committed_blob_authority() {
  local commit="$1" relative_path="$2" expected_mode="$3"
  local record mode type object_id listed_path remainder size sha256

  record="$(/usr/bin/git ls-tree "$commit" -- "$relative_path")" || return 1
  IFS=$'\t' read -r record listed_path remainder <<< "$record"
  [ -z "$remainder" ] && [ "$listed_path" = "$relative_path" ] || return 1
  read -r mode type object_id remainder <<< "$record"
  [ -z "$remainder" ] && [ "$mode" = "$expected_mode" ] &&
    [ "$type" = blob ] &&
    [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  size="$(/usr/bin/git cat-file -s "$object_id")" || return 1
  [[ "$size" =~ ^[1-9][0-9]*$ ]] && [ "$size" -le 524288 ] || return 1
  sha256="$(committed_blob_sha256 "$object_id")" || return 1
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\t%s\t%s\n' "$size" "$sha256" "$object_id"
}

nul_argv_sha256() {
  /usr/bin/python3 -I -c '
import hashlib
import os
import sys

try:
    arguments = sys.argv[1:]
    if not 4 <= len(arguments) <= 128:
        raise RuntimeError
    digest = hashlib.sha256()
    for argument in arguments:
        encoded = argument.encode("ascii")
        if not encoded or len(encoded) > 8192 or b"\0" in encoded:
            raise RuntimeError
        digest.update(encoded)
        digest.update(b"\0")
except BaseException:
    os.write(2, b"error: canonical validator argv digest failed\n")
    raise SystemExit(1)
os.write(1, (digest.hexdigest() + "\n").encode("ascii"))
' "$@"
}

private_empty_directory_identity() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

descriptor = None
try:
    descriptor = os.open(
        sys.argv[1],
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    held = os.fstat(descriptor)
    mapped = os.stat(sys.argv[1], follow_symlinks=False)
    with os.scandir(descriptor) as entries:
        if next(entries, None) is not None:
            raise RuntimeError
    if (
        not stat.S_ISDIR(held.st_mode)
        or stat.S_IMODE(held.st_mode) != 0o700
        or held.st_uid != os.geteuid()
        or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        raise RuntimeError
    output = "%d %d %d %d %d\n" % (
        held.st_dev,
        held.st_ino,
        stat.S_IMODE(held.st_mode),
        held.st_uid,
        held.st_gid,
    )
except BaseException:
    os.write(2, b"error: release output root must be preexisting, private, and empty\n")
    raise SystemExit(1)
finally:
    if descriptor is not None:
        try:
            os.close(descriptor)
        except OSError:
            pass
os.write(1, output.encode("ascii"))
' "$1"
}

private_directory_identity() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

descriptor = None
try:
    descriptor = os.open(
        sys.argv[1],
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    held = os.fstat(descriptor)
    mapped = os.stat(sys.argv[1], follow_symlinks=False)
    if (
        not stat.S_ISDIR(held.st_mode)
        or stat.S_IMODE(held.st_mode) != 0o700
        or held.st_uid != os.geteuid()
        or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        raise RuntimeError
    output = "%d %d %d %d %d\n" % (
        held.st_dev,
        held.st_ino,
        stat.S_IMODE(held.st_mode),
        held.st_uid,
        held.st_gid,
    )
except BaseException:
    os.write(2, b"error: retained build work root is not private and exact\n")
    raise SystemExit(1)
finally:
    if descriptor is not None:
        try:
            os.close(descriptor)
        except OSError:
            pass
os.write(1, output.encode("ascii"))
' "$1"
}

verify_held_output_root() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

try:
    descriptor = int(sys.argv[1], 10)
    expected = tuple(int(value, 10) for value in sys.argv[3:8])
    held = os.fstat(descriptor)
    mapped = os.stat(sys.argv[2], follow_symlinks=False)
    actual = (
        held.st_dev,
        held.st_ino,
        stat.S_IMODE(held.st_mode),
        held.st_uid,
        held.st_gid,
    )
    mapped_identity = (
        mapped.st_dev,
        mapped.st_ino,
        stat.S_IMODE(mapped.st_mode),
        mapped.st_uid,
        mapped.st_gid,
    )
    if (
        not stat.S_ISDIR(held.st_mode)
        or actual != expected
        or mapped_identity != expected
    ):
        raise RuntimeError
except BaseException:
    os.write(2, b"error: held release output root changed\n")
    raise SystemExit(1)
' "$OUTPUT_ROOT_FD" "$OUT_DIR" $OUTPUT_ROOT_IDENTITY
}

verify_held_build_work_root() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

try:
    descriptor = int(sys.argv[1], 10)
    expected = tuple(int(value, 10) for value in sys.argv[3:8])
    held = os.fstat(descriptor)
    mapped = os.stat(sys.argv[2], follow_symlinks=False)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        stat.S_IMODE(value.st_mode),
        value.st_uid,
        value.st_gid,
    )
    if (
        not stat.S_ISDIR(held.st_mode)
        or identity(held) != expected
        or identity(mapped) != expected
    ):
        raise RuntimeError
except BaseException:
    os.write(2, b"error: held retained build work root changed\n")
    raise SystemExit(1)
' "$BUILD_WORK_ROOT_FD" "$build_work_dir" $BUILD_WORK_ROOT_IDENTITY
}

verify_held_build_artifacts_root() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

try:
    work = int(sys.argv[1], 10)
    artifacts = int(sys.argv[2], 10)
    artifacts_path = sys.argv[3]
    expected = tuple(int(value, 10) for value in sys.argv[4:9])
    held = os.fstat(artifacts)
    mapped_path = os.stat(artifacts_path, follow_symlinks=False)
    mapped_child = os.stat("artifacts", dir_fd=work, follow_symlinks=False)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        stat.S_IMODE(value.st_mode),
        value.st_uid,
        value.st_gid,
    )
    if (
        not stat.S_ISDIR(held.st_mode)
        or identity(held) != expected
        or identity(mapped_path) != expected
        or identity(mapped_child) != expected
    ):
        raise RuntimeError
except BaseException:
    os.write(2, b"error: held retained artifacts root changed\n")
    raise SystemExit(1)
' \
    "$BUILD_WORK_ROOT_FD" "$BUILD_ARTIFACTS_ROOT_FD" "$artifacts_abs" \
    $BUILD_ARTIFACTS_ROOT_IDENTITY
}

run_committed_python_helper() {
  local relative_path="$1" expected_sha256="$2" expected_blob_id="$3"
  shift 3

  /usr/bin/python3 -I -c '
import hashlib
import os
import re
import stat
import sys

try:
    relative = sys.argv[2]
    components = relative.split("/")
    if (
        len(components) != 2
        or components[0] != "scripts"
        or not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]{0,127}", components[1])
        or not re.fullmatch(r"[0-9a-f]{64}", sys.argv[3])
        or not re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", sys.argv[4])
    ):
        raise RuntimeError
    root = os.open(
        sys.argv[1],
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    scripts = os.open(
        "scripts",
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=root,
    )
    source = os.open(
        components[1],
        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
        dir_fd=scripts,
    )
    before = os.fstat(source)
    mapped_before = os.stat(
        components[1],
        dir_fd=scripts,
        follow_symlinks=False,
    )
    if (
        not stat.S_ISREG(before.st_mode)
        or not stat.S_ISREG(mapped_before.st_mode)
        or before.st_nlink != 1
        or before.st_size > 512 * 1024
        or (before.st_dev, before.st_ino)
        != (mapped_before.st_dev, mapped_before.st_ino)
    ):
        raise RuntimeError
    data = bytearray()
    offset = 0
    while offset < before.st_size:
        chunk = os.pread(source, min(65536, before.st_size - offset), offset)
        if not chunk:
            raise RuntimeError
        data.extend(chunk)
        offset += len(chunk)
    after = os.fstat(source)
    mapped_after = os.stat(
        components[1],
        dir_fd=scripts,
        follow_symlinks=False,
    )
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
    )
    if (
        stable(before) != stable(after)
        or (after.st_dev, after.st_ino)
        != (mapped_after.st_dev, mapped_after.st_ino)
        or hashlib.sha256(data).hexdigest() != sys.argv[3]
    ):
        raise RuntimeError
    object_header = b"blob " + str(len(data)).encode("ascii") + b"\0"
    object_hash = hashlib.sha1 if len(sys.argv[4]) == 40 else hashlib.sha256
    if object_hash(object_header + data).hexdigest() != sys.argv[4]:
        raise RuntimeError
    code = compile(
        bytes(data),
        "<committed-python-helper>",
        "exec",
        dont_inherit=True,
    )
except BaseException:
    os.write(2, b"error: committed Python helper authority failed\n")
    os._exit(1)
finally:
    for descriptor_name in ("source", "scripts", "root"):
        descriptor = locals().get(descriptor_name)
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass

sys.argv = ["<committed-python-helper>", *sys.argv[5:]]
namespace = {
    "__name__": "__main__",
    "__file__": "<committed-python-helper>",
    "__package__": None,
    "__spec__": None,
}
exec(code, namespace, namespace)
' \
    "$repo_dir" \
    "$relative_path" \
    "$expected_sha256" \
    "$expected_blob_id" \
    "$@"
}

require_arg() {
  if [ -z "${2:-}" ]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 2
  fi
}

single_manifest_value() {
  local file="$1" label="$2"

  awk -v prefix="$label: " '
    index($0, prefix) == 1 {
      count++
      value = substr($0, length(prefix) + 1)
    }
    END {
      if (count != 1 || value == "") {
        exit 1
      }
      print value
    }
  ' "$file"
}

required_manifest_value() {
  local file="$1" label="$2" value

  if ! value="$(single_manifest_value "$file" "$label")"; then
    echo "Build manifest must contain exactly one nonempty '$label:' field." >&2
    return 1
  fi
  printf '%s\n' "$value"
}

verify_final_support_state() {
  local current_head current_status
  if ! current_head="$(git rev-parse --verify 'HEAD^{commit}')"; then
    echo "Could not re-resolve the support repository commit." >&2
    return 1
  fi
  current_head="$(printf '%s' "$current_head" | tr '[:upper:]' '[:lower:]')"
  if [ "$current_head" != "$repo_commit" ]; then
    echo "Support repository HEAD changed during release preparation." >&2
    return 1
  fi
  if ! current_status="$(git status --porcelain --untracked-files=all)"; then
    echo "Could not re-inspect the support repository worktree state." >&2
    return 1
  fi
  if [ "$dirty" = "false" ] && [ -n "$current_status" ]; then
    echo "Support repository became dirty during release preparation." >&2
    return 1
  fi
}

safe_relative_path() {
  case "$1" in
    ""|/*|../*|*/../*|*/..|*//*|./*|*/./*) return 1 ;;
    *) return 0 ;;
  esac
}

public_https_url() {
  local url="$1" authority path

  case "$url" in
    https://*) ;;
    *) return 1 ;;
  esac
  [ "${#url}" -le 2048 ] || return 1
  case "$url" in
    *[[:space:]]*|*\?*|*\#*|*@*|*\'*|*\"*|*\`*|*\$*|*\\*) return 1 ;;
    *[!A-Za-z0-9._~:/%+-]*) return 1 ;;
  esac
  authority="${url#https://}"
  authority="${authority%%/*}"
  case "$authority" in
    ""|.*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;;
    localhost|localhost.*|*.localhost|*.local|*.internal|*.invalid|*.test|*.example|*.onion) return 1 ;;
  esac
  case "$authority" in
    *[!0-9.]*) ;;
    *) return 1 ;;
  esac
  case "$authority" in
    *.*) ;;
    *) return 1 ;;
  esac
  path="${url#https://$authority}"
  case "$path" in
    /?*) ;;
    *) return 1 ;;
  esac
  return 0
}

file_size() {
  local path="$1"
  local size=""

  if size="$(stat -c '%s' -- "$path" 2>/dev/null)"; then
    printf '%s\n' "$size"
  elif size="$(stat -f '%z' "$path" 2>/dev/null)"; then
    printf '%s\n' "$size"
  else
    echo "Could not determine file size: $path" >&2
    return 1
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kernel-debs-dir)
      require_arg "$1" "${2:-}"
      KERNEL_DEBS_DIR="$2"
      shift 2
      ;;
    --artifacts-dir)
      require_arg "$1" "${2:-}"
      ARTIFACTS_DIR="$2"
      shift 2
      ;;
    --patch-dir)
      require_arg "$1" "${2:-}"
      if [ "$PATCH_DIR_EXPLICIT" != "true" ]; then
        PATCH_DIRS=()
        PATCH_DIR_EXPLICIT="true"
      fi
      PATCH_DIRS+=("$2")
      shift 2
      ;;
    --release-name)
      require_arg "$1" "${2:-}"
      RELEASE_NAME="$2"
      shift 2
      ;;
    --out-dir)
      require_arg "$1" "${2:-}"
      OUT_DIR="$2"
      shift 2
      ;;
    --source-url)
      require_arg "$1" "${2:-}"
      SOURCE_URL="$2"
      SOURCE_URL_EXPLICIT="true"
      shift 2
      ;;
    --source-branch)
      require_arg "$1" "${2:-}"
      SOURCE_BRANCH="$2"
      SOURCE_BRANCH_EXPLICIT="true"
      shift 2
      ;;
    --docker-image)
      require_arg "$1" "${2:-}"
      DOCKER_IMAGE="$2"
      shift 2
      ;;
    --source-asset)
      require_arg "$1" "${2:-}"
      SOURCE_ASSETS+=("$2")
      SOURCE_ASSET_COUNT=$((SOURCE_ASSET_COUNT + 1))
      shift 2
      ;;
    --touchscreen-modules-dir)
      require_arg "$1" "${2:-}"
      TOUCHSCREEN_MODULES_DIR="$2"
      shift 2
      ;;
    --touchscreen-source-url)
      require_arg "$1" "${2:-}"
      TOUCHSCREEN_SOURCE_URL="$2"
      shift 2
      ;;
    --touchscreen-source-ref)
      require_arg "$1" "${2:-}"
      TOUCHSCREEN_SOURCE_REF="$2"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY="true"
      shift
      ;;
    --allow-missing-source)
      ALLOW_MISSING_SOURCE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_tool awk
require_tool dpkg-deb
require_tool git
require_tool shasum
require_tool stat
require_tool tr

if [ -n "$TOUCHSCREEN_MODULES_DIR" ]; then
  TOUCHSCREEN_ENABLED="true"
  require_tool grep
  require_tool modinfo

  if [ -z "$TOUCHSCREEN_SOURCE_URL" ] || [ -z "$TOUCHSCREEN_SOURCE_REF" ]; then
    echo "--touchscreen-modules-dir requires --touchscreen-source-url and --touchscreen-source-ref." >&2
    exit 2
  fi
  if ! public_https_url "$TOUCHSCREEN_SOURCE_URL"; then
    echo "Touchscreen source URL must be public HTTPS without credentials, query, or fragment." >&2
    exit 2
  fi

  if [[ ! "$TOUCHSCREEN_SOURCE_REF" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
    echo "Touchscreen source ref must be an immutable 40- or 64-character hexadecimal commit." >&2
    exit 2
  fi
  TOUCHSCREEN_SOURCE_REF="$(printf '%s' "$TOUCHSCREEN_SOURCE_REF" | tr '[:upper:]' '[:lower:]')"
elif [ -n "$TOUCHSCREEN_SOURCE_URL" ] || [ -n "$TOUCHSCREEN_SOURCE_REF" ]; then
  echo "--touchscreen-source-url and --touchscreen-source-ref require --touchscreen-modules-dir." >&2
  exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"
requested_fixture_hook="${SP11_KERNEL_PREPARER_FIXTURE_HOOK:-}"
requested_fixture_context="${SP11_KERNEL_PREPARER_TEST_FIXTURE:-}"
unset SP11_KERNEL_PREPARER_FIXTURE_HOOK SP11_KERNEL_PREPARER_TEST_FIXTURE
if [ -n "$requested_fixture_hook" ]; then
  fixture_marker="$(/usr/bin/git -C "$repo_dir" show \
    HEAD:.sp11-kernel-release-provenance-fixture 2>/dev/null || true)"
  case "$repo_dir" in
    */sp11-apt-fixture.release-provenance.*/support-*) fixture_path_shape=true ;;
    *) fixture_path_shape=false ;;
  esac
  case "$requested_fixture_hook" in
    mutate-release-notes-before-register|mutate-output-terminal|\
    mutate-evidence-terminal|mutate-control-terminal|\
    inject-work-member-terminal|inject-artifact-member-terminal|\
    remap-output-root-terminal|remap-work-root-terminal|\
    remap-artifacts-root-terminal|pending-signal-terminal|\
    fail-root-commit|signal-before-terminal-exec) ;;
    *) fixture_path_shape=false ;;
  esac
  if [ "$requested_fixture_context" != "sp11-kernel-release-provenance-v1" ] ||
     [ "$fixture_marker" != "sp11-kernel-release-provenance-v1" ] ||
     [ "$fixture_path_shape" != "true" ]; then
    echo "Private release-preparer fixture authority was refused." >&2
    exit 1
  fi
  PREPARER_FIXTURE_HOOK="$requested_fixture_hook"
elif [ -n "$requested_fixture_context" ]; then
  fixture_marker="$(/usr/bin/git -C "$repo_dir" show \
    HEAD:.sp11-kernel-release-provenance-fixture 2>/dev/null || true)"
  if [ "$requested_fixture_context" != "sp11-kernel-release-provenance-v1" ] ||
     [ "$fixture_marker" != "sp11-kernel-release-provenance-v1" ]; then
    echo "Private release-preparer fixture context was refused." >&2
    exit 1
  fi
fi
public_content_validator="$repo_dir/scripts/validate-sp11-public-content.sh"
release_tree_state_validator="$repo_dir/scripts/sp11-release-tree-state.py"
if [ ! -f "$release_tree_state_validator" ] || [ -L "$release_tree_state_validator" ]; then
  echo "Missing regular release-tree state validator." >&2
  exit 1
fi

if [ ! -d "$KERNEL_DEBS_DIR" ] || [ -L "$KERNEL_DEBS_DIR" ]; then
  echo "Kernel deb directory not found or is a symlink: $KERNEL_DEBS_DIR" >&2
  exit 1
fi

if [ ! -d "$ARTIFACTS_DIR" ] || [ -L "$ARTIFACTS_DIR" ]; then
  echo "Build artifacts directory not found or is a symlink: $ARTIFACTS_DIR" >&2
  exit 1
fi

for patch_dir in "${PATCH_DIRS[@]}"; do
  if [ ! -d "$patch_dir" ]; then
    echo "Patch directory not found: $patch_dir" >&2
    exit 1
  fi
done

debs=()
deb_roles=()
if find "$KERNEL_DEBS_DIR" -maxdepth 1 -type l -name '*.deb' -print | grep -q .; then
  echo "Kernel deb directory must not contain symlinked .deb entries." >&2
  exit 1
fi
while IFS= read -r deb; do
  debs+=("$deb")
done < <(find "$KERNEL_DEBS_DIR" -maxdepth 1 -type f -name '*.deb' | LC_ALL=C sort)
if [ "${#debs[@]}" -eq 0 ]; then
  echo "No .deb files found under $KERNEL_DEBS_DIR." >&2
  exit 1
fi

kernel_abi=""
package_version=""
seen_headers="false"
seen_common_headers="false"
seen_image="false"
seen_modules="false"
seen_modules_extra="false"

for deb in "${debs[@]}"; do
  base="$(basename "$deb")"
  role=""
  case "$base" in
    linux-qcom-x1e-headers-*_all.deb) role="common_headers" ;;
    linux-headers-*_arm64.deb) role="headers" ;;
    linux-image-unsigned-*_arm64.deb|linux-image-*_arm64.deb) role="image" ;;
    linux-modules-extra-*_arm64.deb) role="modules_extra" ;;
    linux-modules-*_arm64.deb) role="modules" ;;
    *)
      echo "Unexpected kernel package filename: $base" >&2
      echo "Expected linux-{headers,image,modules,modules-extra}-<abi>_<version>_arm64.deb or linux-qcom-x1e-headers-<version>_<version>_all.deb." >&2
      exit 1
      ;;
  esac

  case "$role" in
    common_headers)
      without_arch="${base%_all.deb}"
      deb_version="${without_arch##*_}"
      deb_abi="${without_arch#linux-qcom-x1e-headers-}"
      deb_abi="${deb_abi%_$deb_version}-qcom-x1e"
      ;;
    modules_extra)
      without_arch="${base%_arm64.deb}"
      deb_version="${without_arch##*_}"
      deb_abi="${without_arch#linux-modules-extra-}"
      deb_abi="${deb_abi%_$deb_version}"
      ;;
    image)
      without_arch="${base%_arm64.deb}"
      deb_version="${without_arch##*_}"
      case "$without_arch" in
        linux-image-unsigned-*) deb_abi="${without_arch#linux-image-unsigned-}" ;;
        *) deb_abi="${without_arch#linux-image-}" ;;
      esac
      deb_abi="${deb_abi%_$deb_version}"
      ;;
    *)
      without_arch="${base%_arm64.deb}"
      deb_version="${without_arch##*_}"
      deb_abi="${without_arch#linux-$role-}"
      deb_abi="${deb_abi%_$deb_version}"
      ;;
  esac

  if [ -z "$deb_abi" ] || [ -z "$deb_version" ]; then
    echo "Could not parse kernel ABI/version from $base." >&2
    exit 1
  fi

  if [ -z "$kernel_abi" ]; then
    kernel_abi="$deb_abi"
  elif [ "$kernel_abi" != "$deb_abi" ]; then
    echo "Mixed kernel ABIs in $KERNEL_DEBS_DIR: $kernel_abi and $deb_abi." >&2
    exit 1
  fi

  if [ -z "$package_version" ]; then
    package_version="$deb_version"
  elif [ "$package_version" != "$deb_version" ]; then
    echo "Mixed package versions in $KERNEL_DEBS_DIR: $package_version and $deb_version." >&2
    exit 1
  fi

  case "$role" in
    common_headers)
      if [ "$seen_common_headers" = "true" ]; then
        echo "Duplicate linux-qcom-x1e-headers package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_common_headers="true"
      ;;
    headers)
      if [ "$seen_headers" = "true" ]; then
        echo "Duplicate linux-headers package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_headers="true"
      ;;
    image)
      if [ "$seen_image" = "true" ]; then
        echo "Duplicate linux-image package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_image="true"
      ;;
    modules)
      if [ "$seen_modules" = "true" ]; then
        echo "Duplicate linux-modules package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_modules="true"
      ;;
    modules_extra)
      if [ "$seen_modules_extra" = "true" ]; then
        echo "Duplicate linux-modules-extra package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_modules_extra="true"
      ;;
  esac
  deb_roles+=("$role")
done

if [ "$seen_headers" != "true" ] || [ "$seen_image" != "true" ] || [ "$seen_modules" != "true" ]; then
  echo "Expected exactly one linux-headers, linux-image, and linux-modules package." >&2
  exit 1
fi

case "$kernel_abi" in
  *sp11v3*-qcom-x1e)
    if [ "$TOUCHSCREEN_ENABLED" != "true" ]; then
      echo "Refusing an incomplete $kernel_abi release without its three touchscreen modules." >&2
      echo "Pass --touchscreen-modules-dir and immutable touchscreen source provenance." >&2
      exit 1
    fi
    ;;
esac

touchscreen_module_names=()
touchscreen_module_vermagic=()
touchscreen_module_srcversions=()
touchscreen_module_sizes=()
touchscreen_module_shas=()
touchscreen_module_payload_sizes=()
touchscreen_module_payload_shas=()
touchscreen_module_signature_sizes=()
touchscreen_module_signature_shas=()
touchscreen_source_contract=""
touchscreen_source_object_format=""
touchscreen_source_modules_path=""
touchscreen_source_modules_tree_id=""
touchscreen_source_license_path=""
touchscreen_source_license_mode=""
touchscreen_source_license_blob_id=""
touchscreen_kernel_config_sha256=""
touchscreen_kernel_module_symvers_sha256=""
touchscreen_kernel_headers_input_mode=""
touchscreen_kernel_common_headers_deb=""
touchscreen_kernel_common_headers_deb_sha256=""
touchscreen_kernel_headers_deb=""
touchscreen_kernel_headers_deb_sha256=""
touchscreen_module_compiler_identity=""
touchscreen_module_linker_identity=""
touchscreen_module_make_identity=""
input_touchscreen_module_shas=()
input_touchscreen_module_sizes=()
touchscreen_signing_policy=""
touchscreen_signing_private_material_retained=""
touchscreen_signing_hash_algorithm=""
touchscreen_signing_certificate_asset=""
touchscreen_signing_certificate_sha256=""
touchscreen_signing_certificate_fingerprint=""
touchscreen_signing_certificate_serial=""
touchscreen_signing_certificate_size=""
touchscreen_windows_se_init_default=""

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  if [ ! -d "$TOUCHSCREEN_MODULES_DIR" ] || [ -L "$TOUCHSCREEN_MODULES_DIR" ]; then
    echo "Touchscreen modules directory not found or is a symlink: $TOUCHSCREEN_MODULES_DIR" >&2
    exit 1
  fi

  touchscreen_entries=()
  while IFS= read -r entry_path; do
    entry="$(basename "$entry_path")"
    [ "$entry" = "$TOUCHSCREEN_MODULE_MANIFEST" ] && continue
    touchscreen_entries+=("$entry")
  done < <(find "$TOUCHSCREEN_MODULES_DIR" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)

  expected_touchscreen_entries="$(
    printf '%s\n' "${TOUCHSCREEN_MODULE_FILES[@]}" "$TOUCHSCREEN_SIGNING_CERTIFICATE" | sort
  )"
  actual_touchscreen_entries="$(printf '%s\n' "${touchscreen_entries[@]}" | sort)"
  if [ "${#touchscreen_entries[@]}" -ne "$(( ${#TOUCHSCREEN_MODULE_FILES[@]} + 1 ))" ] || \
     [ "$actual_touchscreen_entries" != "$expected_touchscreen_entries" ]; then
    echo "Touchscreen modules directory must contain exactly: ${TOUCHSCREEN_MODULE_FILES[*]} $TOUCHSCREEN_SIGNING_CERTIFICATE" >&2
    exit 1
  fi

  input_touchscreen_manifest="$TOUCHSCREEN_MODULES_DIR/$TOUCHSCREEN_MODULE_MANIFEST"
  if [ -f "$input_touchscreen_manifest" ] && [ ! -L "$input_touchscreen_manifest" ]; then
    input_source_url="$(required_manifest_value "$input_touchscreen_manifest" "Source URL")"
    input_source_commit="$(required_manifest_value "$input_touchscreen_manifest" "Source commit")"
    input_target_release="$(required_manifest_value "$input_touchscreen_manifest" "Target release")"
    [ "$input_source_url" = "$TOUCHSCREEN_SOURCE_URL" ] || {
      echo "Touchscreen build manifest source URL does not match --touchscreen-source-url." >&2
      exit 1
    }
    [ "$input_source_commit" = "$TOUCHSCREEN_SOURCE_REF" ] || {
      echo "Touchscreen build manifest source commit does not match --touchscreen-source-ref." >&2
      exit 1
    }
    [ "$input_target_release" = "$kernel_abi" ] || {
      echo "Touchscreen build manifest targets $input_target_release, expected $kernel_abi." >&2
      exit 1
    }
    touchscreen_signing_policy="$(required_manifest_value "$input_touchscreen_manifest" "Module signing policy")"
    touchscreen_signing_private_material_retained="$(required_manifest_value "$input_touchscreen_manifest" "Module signing private material retained")"
    touchscreen_signing_hash_algorithm="$(required_manifest_value "$input_touchscreen_manifest" "Module signing hash algorithm")"
    touchscreen_signing_certificate_asset="$(required_manifest_value "$input_touchscreen_manifest" "Module signing certificate asset")"
    touchscreen_signing_certificate_sha256="$(required_manifest_value "$input_touchscreen_manifest" "Module signing certificate SHA256")"
    touchscreen_signing_certificate_fingerprint="$(required_manifest_value "$input_touchscreen_manifest" "Module signing certificate fingerprint")"
    touchscreen_signing_certificate_serial="$(required_manifest_value "$input_touchscreen_manifest" "Module signing certificate serial")"
    touchscreen_windows_se_init_default="$(required_manifest_value "$input_touchscreen_manifest" "Windows SE init default")"
    if [ "$touchscreen_signing_policy" != "$MODULE_SIGNING_POLICY" ] ||
       [ "$touchscreen_signing_private_material_retained" != "false" ] ||
       [ "$touchscreen_signing_hash_algorithm" != "sha512" ] ||
       [ "$touchscreen_windows_se_init_default" != "disabled" ] ||
       [ "$touchscreen_signing_certificate_asset" != "$TOUCHSCREEN_SIGNING_CERTIFICATE" ] ||
       ! [[ "$touchscreen_signing_certificate_sha256" =~ ^[0-9a-f]{64}$ ]] ||
       ! [[ "$touchscreen_signing_certificate_fingerprint" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]] ||
       ! [[ "$touchscreen_signing_certificate_serial" =~ ^[0-9A-F]+$ ]]; then
      echo "Touchscreen build manifest has an invalid controlled module-signing contract." >&2
      exit 1
    fi
    signing_certificate_path="$TOUCHSCREEN_MODULES_DIR/$TOUCHSCREEN_SIGNING_CERTIFICATE"
    signing_certificate_identity="$(
      trusted_regular_file_fingerprint "$signing_certificate_path" 1048576
    )" || exit 1
    if ! [[ "$signing_certificate_identity" =~ ^([1-9][0-9]*)\ ([0-9a-f]{64})$ ]] ||
       [ "${BASH_REMATCH[2]}" != "$touchscreen_signing_certificate_sha256" ]; then
      echo "Touchscreen public signing certificate does not match its build manifest." >&2
      exit 1
    fi
    touchscreen_signing_certificate_size="${BASH_REMATCH[1]}"
    calculated_signing_fingerprint="$(
      printf '%s' "$touchscreen_signing_certificate_sha256" |
        sed 's/../&:/g; s/:$//' | tr '[:lower:]' '[:upper:]'
    )"
    if [ "$calculated_signing_fingerprint" != "$touchscreen_signing_certificate_fingerprint" ]; then
      echo "Touchscreen public signing certificate SHA256 and fingerprint disagree." >&2
      exit 1
    fi
    for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
      input_touchscreen_module_sizes+=(
        "$(required_manifest_value "$input_touchscreen_manifest" "Module $module_file size")"
      )
      input_touchscreen_module_shas+=(
        "$(required_manifest_value "$input_touchscreen_manifest" "Module $module_file SHA256")"
      )
      touchscreen_module_payload_sizes+=(
        "$(required_manifest_value "$input_touchscreen_manifest" "Module $module_file payload size")"
      )
      touchscreen_module_payload_shas+=(
        "$(required_manifest_value "$input_touchscreen_manifest" "Module $module_file payload SHA256")"
      )
      touchscreen_module_signature_sizes+=(
        "$(required_manifest_value "$input_touchscreen_manifest" "Module $module_file signature size")"
      )
      touchscreen_module_signature_shas+=(
        "$(required_manifest_value "$input_touchscreen_manifest" "Module $module_file signature SHA256")"
      )
    done
    if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
      touchscreen_source_contract="$(required_manifest_value "$input_touchscreen_manifest" "Source archive contract")"
      touchscreen_source_object_format="$(required_manifest_value "$input_touchscreen_manifest" "Source object format")"
      touchscreen_source_modules_path="$(required_manifest_value "$input_touchscreen_manifest" "Source modules path")"
      touchscreen_source_modules_tree_id="$(required_manifest_value "$input_touchscreen_manifest" "Source modules tree ID")"
      touchscreen_source_license_path="$(required_manifest_value "$input_touchscreen_manifest" "Source license path")"
      touchscreen_source_license_mode="$(required_manifest_value "$input_touchscreen_manifest" "Source license mode")"
      touchscreen_source_license_blob_id="$(required_manifest_value "$input_touchscreen_manifest" "Source license blob ID")"
      touchscreen_kernel_config_sha256="$(required_manifest_value "$input_touchscreen_manifest" "Kernel config SHA256")"
      touchscreen_kernel_module_symvers_sha256="$(required_manifest_value "$input_touchscreen_manifest" "Kernel Module.symvers SHA256")"
      touchscreen_kernel_headers_input_mode="$(required_manifest_value "$input_touchscreen_manifest" "Kernel headers input mode")"
      touchscreen_kernel_common_headers_deb="$(required_manifest_value "$input_touchscreen_manifest" "Kernel common headers Deb")"
      touchscreen_kernel_common_headers_deb_sha256="$(required_manifest_value "$input_touchscreen_manifest" "Kernel common headers Deb SHA256")"
      touchscreen_kernel_headers_deb="$(required_manifest_value "$input_touchscreen_manifest" "Kernel architecture headers Deb")"
      touchscreen_kernel_headers_deb_sha256="$(required_manifest_value "$input_touchscreen_manifest" "Kernel architecture headers Deb SHA256")"
      touchscreen_module_compiler_identity="$(required_manifest_value "$input_touchscreen_manifest" "Module compiler identity")"
      touchscreen_module_linker_identity="$(required_manifest_value "$input_touchscreen_manifest" "Module linker identity")"
      touchscreen_module_make_identity="$(required_manifest_value "$input_touchscreen_manifest" "Module make identity")"
      if [ "$touchscreen_source_contract" != "sp11-touchscreen-source-v1" ] ||
         { [ "$touchscreen_source_object_format" != "sha1" ] && [ "$touchscreen_source_object_format" != "sha256" ]; } ||
         [ "$touchscreen_source_modules_path" != "phase55/modules" ] ||
         [ "$touchscreen_source_license_path" != "LICENSE" ] ||
         [ "$touchscreen_source_license_mode" != "100644" ] ||
         ! [[ "$touchscreen_source_modules_tree_id" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
         ! [[ "$touchscreen_source_license_blob_id" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
         ! [[ "$touchscreen_kernel_config_sha256" =~ ^[0-9a-f]{64}$ ]] ||
         ! [[ "$touchscreen_kernel_module_symvers_sha256" =~ ^[0-9a-f]{64}$ ]] ||
         [ "$touchscreen_kernel_headers_input_mode" != "extracted-debs-v1" ] ||
         ! [[ "$touchscreen_kernel_common_headers_deb" =~ ^[A-Za-z0-9._+-]+\.deb$ ]] ||
         ! [[ "$touchscreen_kernel_common_headers_deb_sha256" =~ ^[0-9a-f]{64}$ ]] ||
         ! [[ "$touchscreen_kernel_headers_deb" =~ ^[A-Za-z0-9._+-]+\.deb$ ]] ||
         ! [[ "$touchscreen_kernel_headers_deb_sha256" =~ ^[0-9a-f]{64}$ ]] ||
         [ -z "$touchscreen_module_compiler_identity" ] ||
         [ -z "$touchscreen_module_linker_identity" ] ||
         [ -z "$touchscreen_module_make_identity" ]; then
        echo "Touchscreen build manifest has an incomplete source-archive identity contract." >&2
        exit 1
      fi
      case "$touchscreen_source_object_format" in
        sha1)
          [ "${#touchscreen_source_modules_tree_id}" -eq 40 ] &&
            [ "${#touchscreen_source_license_blob_id}" -eq 40 ] || {
              echo "Touchscreen source object format and object ID lengths disagree." >&2
              exit 1
            }
          ;;
        sha256)
          [ "${#touchscreen_source_modules_tree_id}" -eq 64 ] &&
            [ "${#touchscreen_source_license_blob_id}" -eq 64 ] || {
              echo "Touchscreen source object format and object ID lengths disagree." >&2
              exit 1
            }
          ;;
      esac
    fi
  elif [ -e "$input_touchscreen_manifest" ]; then
    echo "Touchscreen build manifest is not a regular file: $input_touchscreen_manifest" >&2
    exit 1
  else
    echo "Publishable touchscreen assets require $input_touchscreen_manifest." >&2
    exit 1
  fi

  common_touchscreen_vermagic_abi=""
  module_index=0
  for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
    module_path="$TOUCHSCREEN_MODULES_DIR/$module_file"
    if [ ! -f "$module_path" ] || [ -L "$module_path" ]; then
      echo "Touchscreen module must be a regular, non-symlinked file: $module_path" >&2
      exit 1
    fi

    case "$module_file" in
      gpi.ko) expected_module_name="gpi" ;;
      spi-geni-qcom.ko) expected_module_name="spi_geni_qcom" ;;
      mshw0485_touch.ko) expected_module_name="mshw0485_touch" ;;
    esac

    if ! module_name="$(modinfo -F name "$module_path")"; then
      echo "Could not read module name from $module_path." >&2
      exit 1
    fi
    if [ "$module_name" != "$expected_module_name" ]; then
      echo "Unexpected module name in $module_file: $module_name (expected $expected_module_name)." >&2
      exit 1
    fi

    if ! module_vermagic="$(modinfo -F vermagic "$module_path")"; then
      echo "Could not read vermagic from $module_path." >&2
      exit 1
    fi
    module_vermagic_abi="${module_vermagic%% *}"
    if [ -z "$module_vermagic" ] || [ "$module_vermagic_abi" != "$kernel_abi" ]; then
      echo "Module $module_file targets ${module_vermagic_abi:-unknown}, expected kernel ABI $kernel_abi." >&2
      exit 1
    fi
    if [ -z "$common_touchscreen_vermagic_abi" ]; then
      common_touchscreen_vermagic_abi="$module_vermagic_abi"
    elif [ "$module_vermagic_abi" != "$common_touchscreen_vermagic_abi" ]; then
      echo "Touchscreen modules do not share a common vermagic ABI." >&2
      exit 1
    fi

    if ! module_srcversion="$(modinfo -F srcversion "$module_path")"; then
      echo "Could not read srcversion from $module_path." >&2
      exit 1
    fi
    if [[ ! "$module_srcversion" =~ ^[0-9A-Fa-f]+$ ]]; then
      echo "Module $module_file has a missing or invalid srcversion." >&2
      exit 1
    fi

    touchscreen_module_names[$module_index]="$module_name"
    touchscreen_module_vermagic[$module_index]="$module_vermagic"
    touchscreen_module_srcversions[$module_index]="$module_srcversion"
    touchscreen_module_sizes[$module_index]="$(file_size "$module_path")"
    touchscreen_module_shas[$module_index]="$(shasum -a 256 "$module_path" | awk '{print $1}')"
    module_index=$((module_index + 1))
  done

  if ! spi_parameters="$(modinfo -p "$TOUCHSCREEN_MODULES_DIR/spi-geni-qcom.ko")"; then
    echo "Could not read parameters from spi-geni-qcom.ko." >&2
    exit 1
  fi
  if ! grep -q '^sp11_windows_se_init:' <<<"$spi_parameters"; then
    echo "spi-geni-qcom.ko is missing the required sp11_windows_se_init parameter." >&2
    exit 1
  fi

  if ! modinfo -F alias "$TOUCHSCREEN_MODULES_DIR/mshw0485_touch.ko" |
       grep -q 'microsoft,mshw0485'; then
    echo "mshw0485_touch.ko is missing the microsoft,mshw0485 device-tree alias." >&2
    exit 1
  fi
  module_index=0
  while [ "$module_index" -lt "${#TOUCHSCREEN_MODULE_FILES[@]}" ]; do
    if ! [[ "${input_touchscreen_module_sizes[$module_index]}" =~ ^[1-9][0-9]*$ ]] ||
       ! [[ "${input_touchscreen_module_shas[$module_index]}" =~ ^[0-9a-f]{64}$ ]] ||
       ! [[ "${touchscreen_module_payload_sizes[$module_index]}" =~ ^[1-9][0-9]*$ ]] ||
       ! [[ "${touchscreen_module_payload_shas[$module_index]}" =~ ^[0-9a-f]{64}$ ]] ||
       ! [[ "${touchscreen_module_signature_sizes[$module_index]}" =~ ^[1-9][0-9]*$ ]] ||
       ! [[ "${touchscreen_module_signature_shas[$module_index]}" =~ ^[0-9a-f]{64}$ ]] ||
       [ "${input_touchscreen_module_sizes[$module_index]}" != "${touchscreen_module_sizes[$module_index]}" ] ||
       [ "${input_touchscreen_module_shas[$module_index]}" != "${touchscreen_module_shas[$module_index]}" ] ||
       [ "${touchscreen_module_payload_sizes[$module_index]}" -ge "${touchscreen_module_sizes[$module_index]}" ] ||
       [ "${touchscreen_module_signature_sizes[$module_index]}" -ge "${touchscreen_module_sizes[$module_index]}" ]; then
      echo "Touchscreen module does not match its signed build manifest: ${TOUCHSCREEN_MODULE_FILES[$module_index]}" >&2
      exit 1
    fi
    module_index=$((module_index + 1))
  done
fi

version_deb="${debs[0]}"
for deb in "${debs[@]}"; do
  case "$(basename "$deb")" in
    linux-image-*)
      version_deb="$deb"
      break
      ;;
  esac
done

version="$(
  basename "$version_deb" |
    sed -n 's/^linux-[^-]*-\(.*\)_\([^_]*\)_arm64\.deb$/\1-\2/p' |
    head -n 1
)"
if [ -z "$version" ]; then
  version="kernel"
fi

if [ -z "$RELEASE_NAME" ]; then
  RELEASE_NAME="sp11-qcom-x1e-${version}-rfkill1"
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="build/release/$RELEASE_NAME"
fi

release_root="build/release"
case "$OUT_DIR" in
  "$release_root"/*)
    out_leaf="${OUT_DIR#"$release_root"/}"
    ;;
  *)
    echo "Refusing output outside $release_root/: $OUT_DIR" >&2
    exit 1
    ;;
esac

case "$out_leaf" in
  ""|*/*|*..*|.*)
    echo "Refusing unsafe release output name: $out_leaf" >&2
    exit 1
    ;;
esac

if [ -L "build" ] || [ -L "$release_root" ]; then
  echo "Refusing symlinked release output root: $release_root" >&2
  exit 1
fi

mkdir -p "$release_root"
release_root_abs="$(cd "$release_root" && pwd -P)"
expected_release_root="$repo_dir/$release_root"
if [ "$release_root_abs" != "$expected_release_root" ]; then
  echo "Refusing release output root outside repository: $release_root_abs" >&2
  exit 1
fi
OUT_DIR="$release_root_abs/$out_leaf"
OUT_DIR_DISPLAY="$release_root/$out_leaf"
if [ ! -d "$OUT_DIR" ] || [ -L "$OUT_DIR" ]; then
  echo "Release output must be a caller-created private empty directory: $OUT_DIR_DISPLAY" >&2
  exit 1
fi
OUTPUT_ROOT_IDENTITY="$(private_empty_directory_identity "$OUT_DIR")" || exit 1
output_previous_directory="$(pwd -P)"
if ! cd "$OUT_DIR"; then
  echo "Could not enter the preexisting release output directory." >&2
  exit 1
fi
exec 52< .
if ! cd "$output_previous_directory"; then
  echo "Could not restore the support repository working directory." >&2
  exit 1
fi
verify_held_output_root

build_manifest="$ARTIFACTS_DIR/sp11-kernel-build-manifest.txt"
apt_provenance="$ARTIFACTS_DIR/sp11-kernel-apt-provenance.txt"
build_inputs="$ARTIFACTS_DIR/sp11-kernel-build-inputs.txt"
kernel_signature_report="$ARTIFACTS_DIR/sp11-kernel-module-signatures.txt"
artifacts_abs="$(cd "$ARTIFACTS_DIR" && pwd -P)"
build_work_dir="$(dirname "$artifacts_abs")"
if [ "$(basename "$artifacts_abs")" != "artifacts" ]; then
  echo "Build artifacts directory must be the exact artifacts child of its retained Docker work root." >&2
  exit 1
fi
if [ ! -f "$KERNEL_BASELINE" ] || [ -L "$KERNEL_BASELINE" ]; then
  echo "Missing regular reviewed kernel baseline: $KERNEL_BASELINE" >&2
  exit 1
fi
BUILD_WORK_ROOT_IDENTITY="$(private_directory_identity "$build_work_dir")" || exit 1
build_work_previous_directory="$(pwd -P)"
if ! cd "$build_work_dir"; then
  echo "Could not enter the retained build work root." >&2
  exit 1
fi
exec 53< .
if ! cd "$build_work_previous_directory"; then
  echo "Could not restore the support repository working directory." >&2
  exit 1
fi
verify_held_build_work_root
BUILD_ARTIFACTS_ROOT_IDENTITY="$(private_directory_identity "$artifacts_abs")" || exit 1
build_artifacts_previous_directory="$(pwd -P)"
if ! cd "$artifacts_abs"; then
  echo "Could not enter the retained build artifacts root." >&2
  exit 1
fi
exec 54< .
if ! cd "$build_artifacts_previous_directory"; then
  echo "Could not restore the support repository working directory." >&2
  exit 1
fi
verify_held_build_artifacts_root
for provenance_input in \
  "$build_manifest" "$apt_provenance" "$build_inputs" \
  "$kernel_signature_report"; do
  if [ ! -f "$provenance_input" ] || [ -L "$provenance_input" ]; then
    echo "Refusing assets without a regular, non-symlinked immutable provenance input: $provenance_input" >&2
    exit 1
  fi
done

repo_commit="$(/usr/bin/git rev-parse --verify 'HEAD^{commit}')"
if ! [[ "$repo_commit" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
  echo "Trusted Git authority returned a noncanonical support commit." >&2
  exit 1
fi

release_state_validator="$repo_dir/scripts/sp11-kernel-release-state.py"
if [ ! -f "$release_state_validator" ] || [ -L "$release_state_validator" ]; then
  echo "Missing regular retained release-evidence validator." >&2
  exit 1
fi
if [ ! -x /usr/bin/python3 ]; then
  echo "Missing trusted isolated Python interpreter at /usr/bin/python3." >&2
  exit 1
fi
retained_evidence_tar="$build_work_dir/sp11-kernel-retained-evidence.tar"
if [ ! -f "$retained_evidence_tar" ] || [ -L "$retained_evidence_tar" ]; then
  echo "Missing required regular retained release-evidence tar." >&2
  exit 1
fi

release_state_relative="scripts/sp11-kernel-release-state.py"
adapter_repo_commit="$(/usr/bin/git rev-parse --verify 'HEAD^{commit}')"
if [ "$adapter_repo_commit" != "$repo_commit" ]; then
  echo "Trusted Git authority disagrees with the retained support commit." >&2
  exit 1
fi
release_state_committed_sha="$(
  committed_blob_sha256 "$adapter_repo_commit:$release_state_relative"
)"
release_state_blob_id="$(
  /usr/bin/git rev-parse --verify "$adapter_repo_commit:$release_state_relative"
)"
if ! [[ "$release_state_committed_sha" =~ ^[0-9a-f]{64}$ ]] ||
   ! [[ "$release_state_blob_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
  echo "Could not bind the retained release-evidence validator to the support commit." >&2
  exit 1
fi
kernel_baseline_sha="$(
  trusted_regular_file_sha256 "$repo_dir/$KERNEL_BASELINE" 1048576
)"
kernel_baseline_record="$(
  committed_blob_authority "$repo_commit" "$KERNEL_BASELINE" 100644
)" || {
  echo "Could not bind the reviewed kernel baseline to the support commit." >&2
  exit 1
}
IFS=$'\t' read -r \
  kernel_baseline_committed_size kernel_baseline_committed_sha \
  kernel_baseline_object_id kernel_baseline_remainder <<< "$kernel_baseline_record"
if [ -n "$kernel_baseline_remainder" ] ||
   [ "$kernel_baseline_sha" != "$kernel_baseline_committed_sha" ]; then
  echo "Reviewed kernel baseline differs from the exact support commit." >&2
  exit 1
fi
build_args_fingerprint="$(
  trusted_regular_file_fingerprint "$build_work_dir/docker-build-args.txt" 67108864
)" || exit 1
entrypoint_fingerprint="$(
  trusted_regular_file_fingerprint "$build_work_dir/docker-build-inside.sh" 67108864
)" || exit 1
oci_index_fingerprint="$(
  trusted_regular_file_fingerprint "$build_work_dir/sp11-oci-index.json" 67108864
)" || exit 1
IFS=' ' read -r build_args_size build_args_sha build_args_remainder \
  <<< "$build_args_fingerprint"
IFS=' ' read -r entrypoint_size entrypoint_sha entrypoint_remainder \
  <<< "$entrypoint_fingerprint"
IFS=' ' read -r oci_index_size oci_index_sha oci_index_remainder \
  <<< "$oci_index_fingerprint"
if [ -n "$build_args_remainder" ] || [ -n "$entrypoint_remainder" ] ||
   [ -n "$oci_index_remainder" ]; then
  echo "Retained release-evidence control fingerprint is not canonical." >&2
  exit 1
fi
for retained_digest in \
  "$kernel_baseline_sha" \
  "$build_args_sha" \
  "$entrypoint_sha" \
  "$oci_index_sha"; do
  if ! [[ "$retained_digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Retained release-evidence authority contains a noncanonical SHA-256." >&2
    exit 1
  fi
done
for retained_size in "$build_args_size" "$entrypoint_size" "$oci_index_size"; do
  if ! [[ "$retained_size" =~ ^[1-9][0-9]*$ ]] ||
     [ "$retained_size" -gt 67108864 ]; then
    echo "Retained release-evidence control size is not canonical." >&2
    exit 1
  fi
done

case "${#repo_commit}" in
  40) release_git_object_format=sha1 ;;
  64) release_git_object_format=sha256 ;;
  *)
    echo "Retained support commit has an unsupported Git object format." >&2
    exit 1
    ;;
esac
build_inputs_helper_relative="scripts/sp11-kernel-build-inputs.py"
manifest_validator_relative="scripts/validate-sp11-image-release-manifests.py"
signed_module_validator_relative="scripts/validate-sp11-signed-modules.py"
build_inputs_helper_record="$(
  committed_blob_authority \
    "$repo_commit" "$build_inputs_helper_relative" 100755
)" || {
  echo "Could not bind the committed build-inputs helper authority." >&2
  exit 1
}
IFS=$'\t' read -r \
  build_inputs_helper_size build_inputs_helper_sha build_inputs_helper_object_id \
  build_inputs_helper_remainder <<< "$build_inputs_helper_record"
[ -z "$build_inputs_helper_remainder" ] || {
  echo "Committed build-inputs helper authority is not canonical." >&2
  exit 1
}
manifest_validator_record="$(
  committed_blob_authority \
    "$repo_commit" "$manifest_validator_relative" 100644
)" || {
  echo "Could not bind the committed manifest-validator authority." >&2
  exit 1
}
IFS=$'\t' read -r \
  manifest_validator_size manifest_validator_sha manifest_validator_object_id \
  manifest_validator_remainder <<< "$manifest_validator_record"
[ -z "$manifest_validator_remainder" ] || {
  echo "Committed manifest-validator authority is not canonical." >&2
  exit 1
}
signed_module_validator_record="$(
  committed_blob_authority \
    "$repo_commit" "$signed_module_validator_relative" 100755
)" || {
  echo "Could not bind the committed signed-module validator authority." >&2
  exit 1
}
IFS=$'\t' read -r \
  signed_module_validator_size signed_module_validator_sha \
  signed_module_validator_object_id signed_module_validator_remainder \
  <<< "$signed_module_validator_record"
[ -z "$signed_module_validator_remainder" ] || {
  echo "Committed signed-module validator authority is not canonical." >&2
  exit 1
}

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  expected_signed_module_report="$(
    {
      echo "Module signing policy: $touchscreen_signing_policy"
      echo "Module signing private material retained: $touchscreen_signing_private_material_retained"
      echo "Module signing hash algorithm: $touchscreen_signing_hash_algorithm"
      echo "Module signing certificate asset: $TOUCHSCREEN_SIGNING_CERTIFICATE"
      echo "Module signing certificate SHA256: $touchscreen_signing_certificate_sha256"
      echo "Module signing certificate fingerprint: $touchscreen_signing_certificate_fingerprint"
      echo "Module signing certificate serial: $touchscreen_signing_certificate_serial"
      echo "Windows SE init default: $touchscreen_windows_se_init_default"
      module_index=0
      while [ "$module_index" -lt "${#TOUCHSCREEN_MODULE_FILES[@]}" ]; do
        module_file="${TOUCHSCREEN_MODULE_FILES[$module_index]}"
        echo "Module $module_file size: ${touchscreen_module_sizes[$module_index]}"
        echo "Module $module_file SHA256: ${touchscreen_module_shas[$module_index]}"
        echo "Module $module_file payload size: ${touchscreen_module_payload_sizes[$module_index]}"
        echo "Module $module_file payload SHA256: ${touchscreen_module_payload_shas[$module_index]}"
        echo "Module $module_file signature size: ${touchscreen_module_signature_sizes[$module_index]}"
        echo "Module $module_file signature SHA256: ${touchscreen_module_signature_shas[$module_index]}"
        module_index=$((module_index + 1))
      done
    }
  )"
  if ! signed_module_report="$(
    run_committed_python_helper \
      "$signed_module_validator_relative" \
      "$signed_module_validator_sha" \
      "$signed_module_validator_object_id" \
      --certificate "$TOUCHSCREEN_MODULES_DIR/$TOUCHSCREEN_SIGNING_CERTIFICATE" \
      --module "$TOUCHSCREEN_MODULES_DIR/gpi.ko" \
      --module "$TOUCHSCREEN_MODULES_DIR/spi-geni-qcom.ko" \
      --module "$TOUCHSCREEN_MODULES_DIR/mshw0485_touch.ko" \
      --manifest "$input_touchscreen_manifest"
  )" || [ "$signed_module_report" != "$expected_signed_module_report" ]; then
    echo "Touchscreen producer manifest or bundle failed cryptographic signature validation." >&2
    exit 1
  fi
fi

baseline_container_authority="$(
  trusted_baseline_container_authority \
    "$repo_dir/$KERNEL_BASELINE" "$kernel_baseline_sha"
)" || {
  echo "Could not derive the exact baseline container authority." >&2
  exit 1
}
IFS=$'\t' read -r evidence_container_image evidence_container_platform \
  baseline_container_remainder <<< "$baseline_container_authority"
[ -z "$baseline_container_remainder" ] &&
  [ -n "$evidence_container_image" ] &&
  [ -n "$evidence_container_platform" ] || {
  echo "Baseline container authority is not canonical." >&2
  exit 1
}
release_validator_argv=(
  /usr/bin/python3
  -I
  /repo/scripts/sp11-kernel-build-inputs.py
  validate
  --baseline /sp11-control/kernel-baseline.env
  --baseline-sha256 "$kernel_baseline_sha"
  --build-args-sha256 "$build_args_sha"
  --entrypoint-sha256 "$entrypoint_sha"
  --oci-index-sha256 "$oci_index_sha"
  --work-dir /work
  --support-head "$repo_commit"
  --build-args /work/docker-build-args.txt
  --entrypoint /work/docker-build-inside.sh
  --oci-index /work/sp11-oci-index.json
  --build-manifest /work/artifacts/sp11-kernel-build-manifest.txt
  --apt-provenance /work/artifacts/sp11-kernel-apt-provenance.txt
  --apt-archives-dir /work/apt-archives
  --apt-lists-dir /work/apt-lists
  --apt-index-cache-dir /work/apt-indexes
  --apt-local-build-deps-dir /work/artifacts
  --apt-pre-inventory /work/sp11-apt-installed-pre.txt
  --apt-post-inventory /work/sp11-apt-installed-post.txt
  --output /work/artifacts/sp11-kernel-build-inputs.txt
  --apt-bootstrap-state /work/sp11-apt-bootstrap-state.txt
  --attestation-output /work/sp11-kernel-preseal-validation.txt
  --git-object-format "$release_git_object_format"
  --build-inputs-helper-sha256 "$build_inputs_helper_sha"
  --build-inputs-helper-object-id "$build_inputs_helper_object_id"
  --manifest-validator-sha256 "$manifest_validator_sha"
  --manifest-validator-object-id "$manifest_validator_object_id"
)
release_validator_argv_sha="$(nul_argv_sha256 "${release_validator_argv[@]}")" || {
  echo "Could not derive the exact retained validation argv authority." >&2
  exit 1
}
[[ "$release_validator_argv_sha" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Retained validation argv authority is not canonical." >&2
  exit 1
}

if ! evidence_validation="$(
  run_committed_python_helper \
    "$release_state_relative" \
    "$release_state_committed_sha" \
    "$release_state_blob_id" \
    verify-evidence-tar \
    --work-root "$build_work_dir" \
    --support-head "$repo_commit" \
    --baseline-sha256 "$kernel_baseline_sha" \
    --build-args-sha256 "$build_args_sha" \
    --entrypoint-sha256 "$entrypoint_sha" \
    --oci-index-sha256 "$oci_index_sha" \
    --container-image "$evidence_container_image" \
    --container-platform "$evidence_container_platform" \
    --git-object-format "$release_git_object_format" \
    --validator-argv-sha256 "$release_validator_argv_sha" \
    --build-inputs-helper-size "$build_inputs_helper_size" \
    --build-inputs-helper-sha256 "$build_inputs_helper_sha" \
    --build-inputs-helper-object-id "$build_inputs_helper_object_id" \
    --manifest-validator-size "$manifest_validator_size" \
    --manifest-validator-sha256 "$manifest_validator_sha" \
    --manifest-validator-object-id "$manifest_validator_object_id"
)"; then
  echo "Retained release-evidence tar validation failed." >&2
  exit 1
fi

retained_flat_names=()
retained_flat_sizes=()
retained_flat_shas=()
evidence_record_state=0
evidence_record_index=1
evidence_record_count=""
evidence_previous_name=""
evidence_tar_re='^Verified retained evidence tar: ([0-9]+) ([0-9a-f]{64})$'
evidence_count_re='^Verified flat file count: ([1-9][0-9]?)$'
evidence_flat_re='^Verified flat file ([1-9][0-9]*): ([0-9A-Za-z][0-9A-Za-z.+_~:@=-]{0,254}) ([0-9]+) ([0-9a-f]{64})$'
while IFS= read -r evidence_line; do
  case "$evidence_record_state" in
    0)
      [ "$evidence_line" = "Verified retained evidence schema: sp11-kernel-evidence-verification-v1" ] || break
      evidence_record_state=1
      ;;
    1)
      if ! [[ "$evidence_line" =~ $evidence_tar_re ]]; then break; fi
      retained_evidence_size="${BASH_REMATCH[1]}"
      retained_evidence_sha256="${BASH_REMATCH[2]}"
      evidence_record_state=2
      ;;
    2)
      if ! [[ "$evidence_line" =~ $evidence_count_re ]]; then break; fi
      evidence_record_count="${BASH_REMATCH[1]}"
      if [ "$evidence_record_count" -gt 70 ]; then break; fi
      evidence_record_state=3
      ;;
    3)
      if [ "$evidence_record_index" -le "$evidence_record_count" ]; then
        if ! [[ "$evidence_line" =~ $evidence_flat_re ]] ||
           [ "${BASH_REMATCH[1]}" -ne "$evidence_record_index" ]; then
          break
        fi
        evidence_name="${BASH_REMATCH[2]}"
        if [ -n "$evidence_previous_name" ] &&
           [[ "$evidence_name" < "$evidence_previous_name" || "$evidence_name" = "$evidence_previous_name" ]]; then
          break
        fi
        retained_flat_names+=("$evidence_name")
        retained_flat_sizes+=("${BASH_REMATCH[3]}")
        retained_flat_shas+=("${BASH_REMATCH[4]}")
        evidence_previous_name="$evidence_name"
        evidence_record_index=$((evidence_record_index + 1))
      elif [ "$evidence_line" = "Verified retained evidence complete: true" ]; then
        evidence_record_state=4
      else
        break
      fi
      ;;
    *)
      evidence_record_state=5
      break
      ;;
  esac
done <<< "$evidence_validation"
if [ "$evidence_record_state" -ne 4 ] ||
   [ "$evidence_record_index" -ne $((evidence_record_count + 1)) ] ||
   [ "${#retained_flat_names[@]}" -ne "$evidence_record_count" ]; then
  echo "Retained release-evidence validator returned a noncanonical record." >&2
  exit 1
fi

retained_flat_expected() {
  local expected_name="$1" index=0
  RETAINED_FLAT_SIZE=""
  RETAINED_FLAT_SHA256=""
  while [ "$index" -lt "${#retained_flat_names[@]}" ]; do
    if [ "${retained_flat_names[$index]}" = "$expected_name" ]; then
      RETAINED_FLAT_SIZE="${retained_flat_sizes[$index]}"
      RETAINED_FLAT_SHA256="${retained_flat_shas[$index]}"
      return 0
    fi
    index=$((index + 1))
  done
  echo "Retained release evidence omits an expected flat file." >&2
  return 1
}

verify_retained_flat_file() {
  local path="$1" expected_name="$2" actual fingerprint_re='^([0-9]+) ([0-9a-f]{64})$'
  retained_flat_expected "$expected_name" || return 1
  actual="$(trusted_regular_file_fingerprint "$path" 4294967296)" || return 1
  if ! [[ "$actual" =~ $fingerprint_re ]] ||
     [ "${BASH_REMATCH[1]}" != "$RETAINED_FLAT_SIZE" ] ||
     [ "${BASH_REMATCH[2]}" != "$RETAINED_FLAT_SHA256" ]; then
    echo "Retained flat release artifact differs from verified evidence." >&2
    return 1
  fi
}

verify_all_retained_flat_files() {
  local root="$1" index=0
  while [ "$index" -lt "${#retained_flat_names[@]}" ]; do
    verify_retained_flat_file \
      "$root/${retained_flat_names[$index]}" \
      "${retained_flat_names[$index]}" || return 1
    index=$((index + 1))
  done
}

verify_retained_evidence_tar() {
  local actual fingerprint_re='^([0-9]+) ([0-9a-f]{64})$'
  actual="$(trusted_regular_file_fingerprint "$retained_evidence_tar" 17179869184)" || return 1
  if ! [[ "$actual" =~ $fingerprint_re ]] ||
     [ "${BASH_REMATCH[1]}" != "$retained_evidence_size" ] ||
     [ "${BASH_REMATCH[2]}" != "$retained_evidence_sha256" ]; then
    echo "Retained release-evidence tar changed after validation." >&2
    return 1
  fi
}

build_manifest="$artifacts_abs/sp11-kernel-build-manifest.txt"
apt_provenance="$artifacts_abs/sp11-kernel-apt-provenance.txt"
build_inputs="$artifacts_abs/sp11-kernel-build-inputs.txt"
kernel_signature_report="$artifacts_abs/sp11-kernel-module-signatures.txt"
verify_retained_flat_file "$build_manifest" "sp11-kernel-build-manifest.txt"
build_manifest_snapshot_size="$RETAINED_FLAT_SIZE"
build_manifest_snapshot_sha="$RETAINED_FLAT_SHA256"
verify_retained_flat_file "$apt_provenance" "sp11-kernel-apt-provenance.txt"
apt_provenance_snapshot_size="$RETAINED_FLAT_SIZE"
apt_provenance_snapshot_sha="$RETAINED_FLAT_SHA256"
verify_retained_flat_file "$build_inputs" "sp11-kernel-build-inputs.txt"
build_inputs_snapshot_size="$RETAINED_FLAT_SIZE"
build_inputs_snapshot_sha="$RETAINED_FLAT_SHA256"
verify_retained_flat_file \
  "$kernel_signature_report" "sp11-kernel-module-signatures.txt"
kernel_signature_report_snapshot_size="$RETAINED_FLAT_SIZE"
kernel_signature_report_snapshot_sha="$RETAINED_FLAT_SHA256"

run_committed_python_helper \
  "$manifest_validator_relative" \
  "$manifest_validator_sha" \
  "$manifest_validator_object_id" \
  --repo-dir "$repo_dir" \
  --support-commit "$repo_commit" \
  --build-only \
  --kernel-build-manifest "$build_manifest" >/dev/null || {
  echo "Kernel module signature report failed committed build-provenance validation." >&2
  exit 1
}
if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  [ -x "$public_content_validator" ] && [ ! -L "$public_content_validator" ] || {
    echo "Missing executable public-content validator." >&2
    exit 1
  }
  public_input_args=(
    --file "$build_manifest"
    --file "$apt_provenance"
    --file "$build_inputs"
    --file "$kernel_signature_report"
  )
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    public_input_args+=(--file "$input_touchscreen_manifest")
  fi
  "$public_content_validator" "${public_input_args[@]}"
fi

provenance_schema="$(required_manifest_value "$build_manifest" "Provenance schema")"
release_build="$(required_manifest_value "$build_manifest" "Release build")"
build_completed="$(required_manifest_value "$build_manifest" "Build completed")"
support_start_head="$(required_manifest_value "$build_manifest" "Support start HEAD")"
support_start_dirty="$(required_manifest_value "$build_manifest" "Support start dirty")"
support_end_head="$(required_manifest_value "$build_manifest" "Support end HEAD")"
support_end_dirty="$(required_manifest_value "$build_manifest" "Support end dirty")"
source_mode="$(required_manifest_value "$build_manifest" "Source mode")"
source_head="$(required_manifest_value "$build_manifest" "Source HEAD")"
expected_source_commit="$(required_manifest_value "$build_manifest" "Expected source commit")"
manifest_source_url="$(required_manifest_value "$build_manifest" "Source URL")"
manifest_source_ref="$(required_manifest_value "$build_manifest" "Source ref")"
manifest_container_image="$(required_manifest_value "$build_manifest" "Container image")"
manifest_container_digest="$(required_manifest_value "$build_manifest" "Container digest")"
manifest_container_platform="$(required_manifest_value "$build_manifest" "Container platform")"
build_target="$(required_manifest_value "$build_manifest" "Build target")"
jobs="$(required_manifest_value "$build_manifest" "Jobs")"
rules_runner="$(required_manifest_value "$build_manifest" "Rules runner")"
patch_count="$(required_manifest_value "$build_manifest" "Patch count")"
patched_diff_format="$(required_manifest_value "$build_manifest" "Patched diff format")"
patched_diff_git_version="$(required_manifest_value "$build_manifest" "Patched diff Git version")"
patched_diff_sha256="$(required_manifest_value "$build_manifest" "Patched diff SHA256")"
patched_tree_id="$(required_manifest_value "$build_manifest" "Patched tree ID")"
required_output_role_set="$(required_manifest_value "$build_manifest" "Required output roles")"
optional_output_role_set="$(required_manifest_value "$build_manifest" "Optional output roles")"
output_count="$(required_manifest_value "$build_manifest" "Output count")"
module_signing_policy="$(required_manifest_value "$build_manifest" "Module signing policy")"
module_signing_private_material_retained="$(required_manifest_value "$build_manifest" "Module signing private material retained")"
signing_certificate_sha256="$(required_manifest_value "$build_manifest" "Signing certificate SHA256")"
signing_certificate_fingerprint="$(required_manifest_value "$build_manifest" "Signing certificate fingerprint")"
signing_certificate_serial="$(required_manifest_value "$build_manifest" "Signing certificate serial")"
kernel_signature_report_asset="$(required_manifest_value "$build_manifest" "Kernel module signature report asset")"
kernel_signature_report_size="$(required_manifest_value "$build_manifest" "Kernel module signature report size")"
kernel_signature_report_sha256="$(required_manifest_value "$build_manifest" "Kernel module signature report SHA256")"
kernel_signature_report_schema="$(required_manifest_value "$build_manifest" "Kernel module signature report schema")"
kernel_module_total_count="$(required_manifest_value "$build_manifest" "Kernel module total count")"
kernel_module_verified_signed_count="$(required_manifest_value "$build_manifest" "Kernel module verified signed count")"
kernel_module_policy_allowed_unsigned_count="$(required_manifest_value "$build_manifest" "Kernel module policy-allowed unsigned count")"
kernel_module_unsigned_path_inventory_sha256="$(required_manifest_value "$build_manifest" "Kernel module unsigned-path inventory SHA256")"
required_deb_role_set="$(required_manifest_value "$build_manifest" "Required Deb roles")"
optional_deb_role_set="$(required_manifest_value "$build_manifest" "Optional Deb roles")"
manifest_deb_count="$(required_manifest_value "$build_manifest" "Deb count")"
apt_provenance_schema="$(required_manifest_value "$apt_provenance" "APT provenance schema")"
apt_snapshot_id="$(required_manifest_value "$apt_provenance" "Snapshot ID")"
apt_snapshot_uri="$(required_manifest_value "$apt_provenance" "Snapshot URI")"
build_inputs_schema="$(required_manifest_value "$build_inputs" "Build inputs schema")"
build_envelope_creation_propagation="$(required_manifest_value "$build_inputs" "Publication schema propagation")"
oci_index_image="$(required_manifest_value "$build_inputs" "OCI index image")"
oci_index_digest="$(required_manifest_value "$build_inputs" "OCI index digest")"
oci_platform="$(required_manifest_value "$build_inputs" "OCI platform")"
oci_platform_manifest="$(required_manifest_value "$build_inputs" "OCI platform manifest")"

if [ "$provenance_schema" != "sp11-kernel-build-v2" ]; then
  echo "Refusing non-v2 kernel build provenance: $provenance_schema" >&2
  exit 1
fi
if [ "$apt_provenance_schema" != "sp11-kernel-apt-provenance-v1" ] ||
   [ "$build_inputs_schema" != "sp11-kernel-build-inputs-v1" ] ||
   [ "$build_envelope_creation_propagation" != "incomplete" ]; then
  echo "Immutable build-input schemas or build-time propagation state changed after validation." >&2
  exit 1
fi
if [ "$release_build" != "true" ]; then
  echo "Refusing a kernel build manifest that is not marked as a release build." >&2
  exit 1
fi
if [ "$build_completed" != "true" ]; then
  echo "Refusing incomplete kernel build provenance." >&2
  exit 1
fi
if [ "$support_start_dirty" != "false" ] || [ "$support_end_dirty" != "false" ] ||
   [ "$support_start_head" != "$support_end_head" ] ||
   ! [[ "$support_start_head" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
  echo "Build manifest does not prove a clean, stable support repository commit." >&2
  exit 1
fi
if [ "$source_mode" != "git" ] ||
   ! [[ "$source_head" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
   [ "$source_head" != "$expected_source_commit" ]; then
  echo "Build manifest does not bind the kernel source to its exact expected Git commit." >&2
  exit 1
fi
if ! public_https_url "$manifest_source_url"; then
  echo "Build manifest kernel source URL is not public HTTPS provenance without credentials, query, or fragment." >&2
  exit 1
fi
if ! [[ "$manifest_source_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
   ! git check-ref-format "refs/heads/$manifest_source_ref" >/dev/null 2>&1; then
  echo "Build manifest kernel source ref is not a safe full ref name." >&2
  exit 1
fi
if ! [[ "$manifest_container_image" =~ ^[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}$ ]] ||
   [ "${manifest_container_image##*@}" != "$manifest_container_digest" ]; then
  echo "Build manifest does not contain a consistent digest-pinned container image." >&2
  exit 1
fi
case "$manifest_container_platform" in
  linux/arm64|linux/arm64/v8) ;;
  *)
    echo "Build manifest has an unsupported container platform: $manifest_container_platform" >&2
    exit 1
    ;;
esac
if ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]] ||
   [ "$build_target" != "binary-indep binary-qcom-x1e" ]; then
  echo "Build manifest has incomplete target, jobs, or rules-runner provenance." >&2
  exit 1
fi
case "$rules_runner" in
  direct-root|fakeroot) ;;
  *)
    echo "Build manifest has an unsupported rules runner: $rules_runner" >&2
    exit 1
    ;;
esac
if [ "$patched_diff_format" != "git-diff-full-index-binary-v1" ] ||
   [[ "$patched_diff_git_version" != git\ version\ * ]] ||
   ! [[ "$patched_diff_sha256" =~ ^[0-9a-f]{64}$ ]] ||
   ! [[ "$patched_tree_id" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
  echo "Build manifest has incomplete canonical patched-tree provenance." >&2
  exit 1
fi
if ! [[ "$patch_count" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "$output_count" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "$manifest_deb_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build manifest has invalid patch, output, or package counts." >&2
  exit 1
fi
if [ "$required_output_role_set" != "kernel-config module-symvers system-map kernel-efi-stubble denali-oled-dtb denali-oled-el2-dtb module-signing-certificate" ] ||
   [ "$optional_output_role_set" != "none" ] ||
   [ "$required_deb_role_set" != "common-headers headers image modules" ] ||
   [ "$optional_deb_role_set" != "modules-extra" ]; then
  echo "Build manifest does not declare the schema-v2 required and optional role sets." >&2
  exit 1
fi
if [ "$output_count" -ne 7 ] ||
   { [ "$manifest_deb_count" -ne 4 ] && [ "$manifest_deb_count" -ne 5 ]; }; then
  echo "Build manifest has an unexpected required-output or optional-package cardinality." >&2
  exit 1
fi
if [ "$module_signing_policy" != "$MODULE_SIGNING_POLICY" ] ||
   [ "$module_signing_private_material_retained" != "false" ] ||
   ! [[ "$signing_certificate_sha256" =~ ^[0-9a-f]{64}$ ]] ||
   ! [[ "$signing_certificate_fingerprint" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]] ||
   ! [[ "$signing_certificate_serial" =~ ^[0-9A-F]+$ ]]; then
  echo "Build manifest has incomplete public X.509 signing-certificate identity." >&2
  exit 1
fi
if [ "$kernel_signature_report_asset" != "sp11-kernel-module-signatures.txt" ] ||
   [ "$kernel_signature_report_schema" != "sp11-kernel-module-signature-verification-v1" ] ||
   [ "$kernel_signature_report_size" != "$kernel_signature_report_snapshot_size" ] ||
   [ "$kernel_signature_report_sha256" != "$kernel_signature_report_snapshot_sha" ] ||
   ! [[ "$kernel_signature_report_size" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "$kernel_signature_report_sha256" =~ ^[0-9a-f]{64}$ ]] ||
   ! [[ "$kernel_module_total_count" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "$kernel_module_verified_signed_count" =~ ^(0|[1-9][0-9]*)$ ]] ||
   ! [[ "$kernel_module_policy_allowed_unsigned_count" =~ ^(0|[1-9][0-9]*)$ ]] ||
   ! [[ "$kernel_module_unsigned_path_inventory_sha256" =~ ^[0-9a-f]{64}$ ]] ||
   [ "$kernel_module_total_count" -ne $((
     10#$kernel_module_verified_signed_count +
       10#$kernel_module_policy_allowed_unsigned_count
   )) ]; then
  echo "Build manifest has incomplete or false kernel module signature-report bindings." >&2
  exit 1
fi

manifest_patch_paths=()
manifest_patch_sha256s=()
manifest_patch_dispositions=()
index=1
while [ "$index" -le "$patch_count" ]; do
  manifest_patch_path="$(required_manifest_value "$build_manifest" "Patch $index path")"
  manifest_patch_sha="$(required_manifest_value "$build_manifest" "Patch $index SHA256")"
  manifest_patch_disposition="$(required_manifest_value "$build_manifest" "Patch $index disposition")"
  if ! safe_relative_path "$manifest_patch_path" ||
     ! [[ "$manifest_patch_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Build manifest patch $index has an unsafe path or invalid SHA-256." >&2
    exit 1
  fi
  case "$manifest_patch_disposition" in
    applied|already-applied|already-satisfied) ;;
    *)
      echo "Build manifest patch $index has an invalid disposition: $manifest_patch_disposition" >&2
      exit 1
      ;;
  esac
  manifest_patch_paths+=("$manifest_patch_path")
  manifest_patch_sha256s+=("$manifest_patch_sha")
  manifest_patch_dispositions+=("$manifest_patch_disposition")
  index=$((index + 1))
done

manifest_output_roles=()
manifest_output_paths=()
manifest_output_sizes=()
manifest_output_sha256s=()
index=1
while [ "$index" -le "$output_count" ]; do
  manifest_output_role="$(required_manifest_value "$build_manifest" "Output $index role")"
  manifest_output_required="$(required_manifest_value "$build_manifest" "Output $index required")"
  manifest_output_path="$(required_manifest_value "$build_manifest" "Output $index path")"
  manifest_output_size="$(required_manifest_value "$build_manifest" "Output $index size")"
  manifest_output_sha="$(required_manifest_value "$build_manifest" "Output $index SHA256")"
  if [ -z "$manifest_output_role" ] || [ "$manifest_output_required" != "true" ] ||
     ! safe_relative_path "$manifest_output_path" ||
     ! [[ "$manifest_output_size" =~ ^[1-9][0-9]*$ ]] ||
     ! [[ "$manifest_output_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Build manifest output $index is incomplete or unsafe." >&2
    exit 1
  fi
  previous=0
  while [ "$previous" -lt "${#manifest_output_roles[@]}" ]; do
    if [ "${manifest_output_roles[$previous]}" = "$manifest_output_role" ] ||
       [ "${manifest_output_paths[$previous]}" = "$manifest_output_path" ]; then
      echo "Build manifest contains a duplicate output role or path." >&2
      exit 1
    fi
    previous=$((previous + 1))
  done
  manifest_output_roles+=("$manifest_output_role")
  manifest_output_paths+=("$manifest_output_path")
  manifest_output_sizes+=("$manifest_output_size")
  manifest_output_sha256s+=("$manifest_output_sha")
  index=$((index + 1))
done

required_output_roles=(
  kernel-config
  module-symvers
  system-map
  kernel-efi-stubble
  denali-oled-dtb
  denali-oled-el2-dtb
  module-signing-certificate
)
required_output_paths=(
  debian/build/build-qcom-x1e/.config
  debian/build/build-qcom-x1e/Module.symvers
  debian/build/build-qcom-x1e/System.map
  debian/build/build-qcom-x1e/arch/arm64/boot/vmlinuz.efi.stubble
  debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled.dtb
  debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled-el2.dtb
  debian/build/build-qcom-x1e/certs/signing_key.x509
)
required_index=0
certificate_output_sha=""
kernel_config_output_sha=""
kernel_module_symvers_output_sha=""
while [ "$required_index" -lt "${#required_output_roles[@]}" ]; do
  found="false"
  output_index=0
  while [ "$output_index" -lt "${#manifest_output_roles[@]}" ]; do
    if [ "${manifest_output_roles[$output_index]}" = "${required_output_roles[$required_index]}" ] &&
       [ "${manifest_output_paths[$output_index]}" = "${required_output_paths[$required_index]}" ]; then
      found="true"
      if [ "${required_output_roles[$required_index]}" = "module-signing-certificate" ]; then
        certificate_output_sha="${manifest_output_sha256s[$output_index]}"
      elif [ "${required_output_roles[$required_index]}" = "kernel-config" ]; then
        kernel_config_output_sha="${manifest_output_sha256s[$output_index]}"
      elif [ "${required_output_roles[$required_index]}" = "module-symvers" ]; then
        kernel_module_symvers_output_sha="${manifest_output_sha256s[$output_index]}"
      fi
      break
    fi
    output_index=$((output_index + 1))
  done
  if [ "$found" != "true" ]; then
    echo "Build manifest is missing required output ${required_output_roles[$required_index]}." >&2
    exit 1
  fi
  required_index=$((required_index + 1))
done
if [ "$certificate_output_sha" != "$signing_certificate_sha256" ]; then
  echo "Build manifest signing-certificate hashes disagree." >&2
  exit 1
fi
if [ "$TOUCHSCREEN_ENABLED" = "true" ] &&
   { [ "$touchscreen_signing_policy" != "$module_signing_policy" ] ||
     [ "$touchscreen_signing_private_material_retained" != "$module_signing_private_material_retained" ] ||
     [ "$touchscreen_signing_certificate_sha256" != "$signing_certificate_sha256" ] ||
     [ "$touchscreen_signing_certificate_fingerprint" != "$signing_certificate_fingerprint" ] ||
     [ "$touchscreen_signing_certificate_serial" != "$signing_certificate_serial" ]; }; then
  echo "Touchscreen signing policy or public certificate identity does not match the kernel build." >&2
  exit 1
fi
if [ "$TOUCHSCREEN_ENABLED" = "true" ] && [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  if [ "$touchscreen_kernel_config_sha256" != "$kernel_config_output_sha" ]; then
    echo "Touchscreen module build config does not match the release kernel build config." >&2
    exit 1
  fi
  if [ "$touchscreen_kernel_module_symvers_sha256" != "$kernel_module_symvers_output_sha" ]; then
    echo "Touchscreen module build Module.symvers does not match the release kernel build." >&2
    exit 1
  fi
fi

manifest_deb_roles=()
manifest_deb_paths=()
manifest_deb_packages=()
manifest_deb_versions=()
manifest_deb_architectures=()
manifest_deb_sizes=()
manifest_deb_sha256s=()
index=1
while [ "$index" -le "$manifest_deb_count" ]; do
  manifest_deb_role="$(required_manifest_value "$build_manifest" "Deb $index role")"
  manifest_deb_required="$(required_manifest_value "$build_manifest" "Deb $index required")"
  manifest_deb_path="$(required_manifest_value "$build_manifest" "Deb $index path")"
  manifest_deb_package="$(required_manifest_value "$build_manifest" "Deb $index package")"
  manifest_deb_version="$(required_manifest_value "$build_manifest" "Deb $index version")"
  manifest_deb_architecture="$(required_manifest_value "$build_manifest" "Deb $index architecture")"
  manifest_deb_size="$(required_manifest_value "$build_manifest" "Deb $index size")"
  manifest_deb_sha="$(required_manifest_value "$build_manifest" "Deb $index SHA256")"
  case "$manifest_deb_role" in
    common-headers|headers|image|modules|modules-extra) ;;
    *)
      echo "Build manifest package $index has an invalid role: $manifest_deb_role" >&2
      exit 1
      ;;
  esac
  case "$manifest_deb_role:$manifest_deb_required" in
    common-headers:true|headers:true|image:true|modules:true|modules-extra:false) ;;
    *)
      echo "Build manifest package $index has inconsistent required/optional classification." >&2
      exit 1
      ;;
  esac
  if ! safe_relative_path "$manifest_deb_path" || [[ "$manifest_deb_path" == */* ]] ||
     [ -z "$manifest_deb_package" ] || [ -z "$manifest_deb_version" ] ||
     [ -z "$manifest_deb_architecture" ] ||
     ! [[ "$manifest_deb_size" =~ ^[1-9][0-9]*$ ]] ||
     ! [[ "$manifest_deb_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Build manifest package $index is incomplete or unsafe." >&2
    exit 1
  fi
  if ! [[ "$manifest_deb_package" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] ||
     ! [[ "$manifest_deb_version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] ||
     ! [[ "$manifest_deb_architecture" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "Build manifest package $index has unsafe identity fields." >&2
    exit 1
  fi
  manifest_deb_roles+=("$manifest_deb_role")
  manifest_deb_paths+=("$manifest_deb_path")
  manifest_deb_packages+=("$manifest_deb_package")
  manifest_deb_versions+=("$manifest_deb_version")
  manifest_deb_architectures+=("$manifest_deb_architecture")
  manifest_deb_sizes+=("$manifest_deb_size")
  manifest_deb_sha256s+=("$manifest_deb_sha")
  index=$((index + 1))
done

if [ "$manifest_deb_count" -ne "${#debs[@]}" ]; then
  echo "Build manifest package count does not match the release package directory." >&2
  exit 1
fi
actual_deb_sizes=()
actual_deb_shas=()
actual_index=0
while [ "$actual_index" -lt "${#debs[@]}" ]; do
  actual_deb="${debs[$actual_index]}"
  actual_base="$(basename "$actual_deb")"
  case "${deb_roles[$actual_index]}" in
    common_headers) actual_role="common-headers" ;;
    modules_extra) actual_role="modules-extra" ;;
    *) actual_role="${deb_roles[$actual_index]}" ;;
  esac
  actual_package="$(dpkg-deb -f "$actual_deb" Package)"
  actual_version="$(dpkg-deb -f "$actual_deb" Version)"
  actual_architecture="$(dpkg-deb -f "$actual_deb" Architecture)"
  actual_size="$(file_size "$actual_deb")"
  actual_sha="$(shasum -a 256 "$actual_deb" | awk '{ print $1 }')"
  actual_deb_sizes+=("$actual_size")
  actual_deb_shas+=("$actual_sha")
  if [ "$actual_package" != "${actual_base%%_*}" ]; then
    echo "Package field $actual_package does not match release filename $actual_base." >&2
    exit 1
  fi
  actual_filename_without_arch="${actual_base%_${actual_architecture}.deb}"
  if [ "$actual_version" != "${actual_filename_without_arch##*_}" ]; then
    echo "Version field $actual_version does not match release filename $actual_base." >&2
    exit 1
  fi
  matched="false"
  manifest_index=0
  while [ "$manifest_index" -lt "${#manifest_deb_paths[@]}" ]; do
    if [ "${manifest_deb_paths[$manifest_index]}" = "$actual_base" ]; then
      if [ "$matched" = "true" ]; then
        echo "Build manifest lists package $actual_base more than once." >&2
        exit 1
      fi
      matched="true"
      if [ "${manifest_deb_roles[$manifest_index]}" != "$actual_role" ] ||
         [ "${manifest_deb_packages[$manifest_index]}" != "$actual_package" ] ||
         [ "${manifest_deb_versions[$manifest_index]}" != "$actual_version" ] ||
         [ "${manifest_deb_architectures[$manifest_index]}" != "$actual_architecture" ] ||
         [ "${manifest_deb_sizes[$manifest_index]}" != "$actual_size" ] ||
         [ "${manifest_deb_sha256s[$manifest_index]}" != "$actual_sha" ]; then
        echo "Release package does not match its build provenance: $actual_base" >&2
        exit 1
      fi
    fi
    manifest_index=$((manifest_index + 1))
  done
  if [ "$matched" != "true" ]; then
    echo "Release package is absent from the build manifest: $actual_base" >&2
    exit 1
  fi
  actual_index=$((actual_index + 1))
done

for required_deb_role in common-headers headers image modules; do
  found="false"
  for manifest_deb_role in "${manifest_deb_roles[@]}"; do
    [ "$manifest_deb_role" = "$required_deb_role" ] && found="true"
  done
  if [ "$found" != "true" ]; then
    echo "Build manifest is missing required package role $required_deb_role." >&2
    exit 1
  fi
done

if [ "$TOUCHSCREEN_ENABLED" = "true" ] && [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  matched_common_headers="false"
  matched_architecture_headers="false"
  manifest_index=0
  while [ "$manifest_index" -lt "${#manifest_deb_roles[@]}" ]; do
    if [ "${manifest_deb_roles[$manifest_index]}" = "common-headers" ] &&
       [ "${manifest_deb_paths[$manifest_index]}" = "$touchscreen_kernel_common_headers_deb" ] &&
       [ "${manifest_deb_sha256s[$manifest_index]}" = "$touchscreen_kernel_common_headers_deb_sha256" ]; then
      matched_common_headers="true"
    fi
    if [ "${manifest_deb_roles[$manifest_index]}" = "headers" ] &&
       [ "${manifest_deb_paths[$manifest_index]}" = "$touchscreen_kernel_headers_deb" ] &&
       [ "${manifest_deb_sha256s[$manifest_index]}" = "$touchscreen_kernel_headers_deb_sha256" ]; then
      matched_architecture_headers="true"
    fi
    manifest_index=$((manifest_index + 1))
  done
  if [ "$matched_common_headers" != "true" ] || [ "$matched_architecture_headers" != "true" ]; then
    echo "Touchscreen module build header Debs do not match kernel build provenance." >&2
    exit 1
  fi
fi

repo_commit="$(git rev-parse 'HEAD^{commit}')"
repo_commit="$(printf '%s' "$repo_commit" | tr '[:upper:]' '[:lower:]')"
dirty="false"
if ! support_status="$(git status --porcelain --untracked-files=all)"; then
  echo "Could not inspect the support repository worktree state." >&2
  exit 1
fi
if [ -n "$support_status" ]; then
  dirty="true"
fi

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  require_tool python3
  build_manifest_validator="$repo_dir/scripts/validate-sp11-image-release-manifests.py"
  if [ ! -f "$build_manifest_validator" ] || [ -L "$build_manifest_validator" ]; then
    echo "Missing regular schema-v2 build-manifest validator." >&2
    exit 1
  fi
  run_committed_python_helper \
    "$manifest_validator_relative" \
    "$manifest_validator_sha" \
    "$manifest_validator_object_id" \
    --build-only \
    --require-current-head \
    --repo-dir "$repo_dir" \
    --support-commit "$repo_commit" \
    --kernel-build-manifest "$build_manifest"
fi

if [ "$dirty" = "true" ] && [ "$ALLOW_DIRTY" != "true" ]; then
  echo "Refusing to prepare public release assets from a dirty support repository." >&2
  echo "Commit or stash changes first, or pass --allow-dirty for a local test run." >&2
  exit 1
fi

if [ "$support_start_head" != "$repo_commit" ]; then
  echo "Build provenance support commit does not match the current support repository HEAD." >&2
  exit 1
fi

actual_patch_paths=()
actual_patch_sha256s=()
for patch_dir in "${PATCH_DIRS[@]}"; do
  if [ -L "$patch_dir" ]; then
    echo "Release patch directory must not be a symlink: $patch_dir" >&2
    exit 1
  fi
  canonical_patch_dir="$(cd "$patch_dir" && pwd -P)"
  case "$canonical_patch_dir" in
    "$repo_dir"/*) ;;
    *)
      echo "Release patch directory resolves outside the support repository: $patch_dir" >&2
      exit 1
      ;;
  esac
  if find "$canonical_patch_dir" -maxdepth 1 -type l -name '*.patch' -print | grep -q .; then
    echo "Release patch directory contains a symlinked .patch entry: $patch_dir" >&2
    exit 1
  fi
  while IFS= read -r actual_patch; do
    [ -n "$actual_patch" ] || continue
    if [ ! -s "$actual_patch" ] || [ -L "$actual_patch" ]; then
      echo "Release patch must be a nonempty regular, non-symlinked file: $actual_patch" >&2
      exit 1
    fi
    actual_patch_path="${actual_patch#"$repo_dir"/}"
    if ! git ls-files --error-unmatch -- "$actual_patch_path" >/dev/null 2>&1; then
      echo "Release patch is not tracked by the support commit: $actual_patch_path" >&2
      exit 1
    fi
    actual_patch_paths+=("$actual_patch_path")
    actual_patch_sha256s+=("$(shasum -a 256 "$actual_patch" | awk '{ print $1 }')")
  done < <(find "$canonical_patch_dir" -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort)
done
if [ "${#actual_patch_paths[@]}" -ne "$patch_count" ]; then
  echo "Release patch count does not match the build manifest." >&2
  exit 1
fi
index=0
while [ "$index" -lt "${#actual_patch_paths[@]}" ]; do
  if [ "${actual_patch_paths[$index]}" != "${manifest_patch_paths[$index]}" ] ||
     [ "${actual_patch_sha256s[$index]}" != "${manifest_patch_sha256s[$index]}" ]; then
    echo "Release patch order or SHA-256 does not match build provenance at entry $((index + 1))." >&2
    exit 1
  fi
  index=$((index + 1))
done

if [ "$SOURCE_URL_EXPLICIT" != "true" ]; then
  SOURCE_URL="$manifest_source_url"
elif [ "$SOURCE_URL" != "$manifest_source_url" ]; then
  echo "--source-url does not match the URL recorded by the build manifest." >&2
  exit 1
fi
if [ "$SOURCE_BRANCH_EXPLICIT" != "true" ]; then
  SOURCE_BRANCH="$manifest_source_ref"
elif [ "$SOURCE_BRANCH" != "$manifest_source_ref" ]; then
  echo "--source-branch does not match the ref recorded by the build manifest." >&2
  exit 1
fi
if [ -z "$DOCKER_IMAGE" ]; then
  DOCKER_IMAGE="$manifest_container_image"
elif [ "$DOCKER_IMAGE" != "$manifest_container_image" ]; then
  echo "--docker-image does not match the digest-pinned image recorded by the build manifest." >&2
  exit 1
fi

if ! git check-ref-format "refs/tags/$RELEASE_NAME" >/dev/null 2>&1; then
  echo "Release name is not a valid Git tag: $RELEASE_NAME" >&2
  exit 1
fi

if [ "$SOURCE_ASSET_COUNT" -eq 0 ] && [ "$ALLOW_MISSING_SOURCE" != "true" ]; then
  echo "Refusing to prepare publishable kernel assets without corresponding source." >&2
  echo "Pass the exact patched-source archive with --source-asset PATH." >&2
  echo "For a local draft only, pass --allow-missing-source." >&2
  exit 1
fi

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  require_tool python3
  source_archive_validator="$repo_dir/scripts/validate-sp11-source-archive.py"
  if [ ! -f "$source_archive_validator" ] || [ -L "$source_archive_validator" ]; then
    echo "Missing regular source-archive validator: scripts/validate-sp11-source-archive.py" >&2
    exit 1
  fi

  canonical_source_assets=()
  for source_asset_input in "${SOURCE_ASSETS[@]}"; do
    if [ ! -s "$source_asset_input" ] || [ -L "$source_asset_input" ]; then
      echo "Source asset must be a non-empty regular, non-symlinked file: $source_asset_input" >&2
      exit 1
    fi
    source_asset_dir="$(cd "$(dirname "$source_asset_input")" && pwd -P)"
    source_asset="$source_asset_dir/$(basename "$source_asset_input")"
    case "$source_asset" in
      "$repo_dir"/*) ;;
      *)
        echo "Source asset must resolve inside the support repository: $source_asset_input" >&2
        exit 1
        ;;
    esac
    source_asset_base="$(basename "$source_asset")"
    case "$source_asset_base" in
      ""|*[!A-Za-z0-9._+-]*)
        echo "Source asset has an unsafe release basename: $source_asset_base" >&2
        exit 1
        ;;
    esac
    case "$source_asset_base" in
      sp11-touchscreen-modules-source-*.tar.xz)
        if [ -n "$TOUCHSCREEN_SOURCE_ASSET" ]; then
          echo "Supply exactly one touchscreen corresponding-source archive." >&2
          exit 1
        fi
        TOUCHSCREEN_SOURCE_ASSET="$source_asset"
        ;;
      *patched-source*.tar.xz)
        if [ -n "$KERNEL_SOURCE_ASSET" ]; then
          echo "Supply exactly one patched-kernel corresponding-source archive." >&2
          exit 1
        fi
        KERNEL_SOURCE_ASSET="$source_asset"
        ;;
      *)
        echo "Unexpected corresponding-source archive name: $source_asset_base" >&2
        exit 1
        ;;
    esac
    canonical_source_assets+=("$source_asset")
  done
  SOURCE_ASSETS=("${canonical_source_assets[@]}")

  if [ -z "$KERNEL_SOURCE_ASSET" ]; then
    echo "Publishable kernel assets require exactly one patched-source .tar.xz archive." >&2
    exit 1
  fi
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    if [ -z "$TOUCHSCREEN_SOURCE_ASSET" ] || [ "$SOURCE_ASSET_COUNT" -ne 2 ]; then
      echo "Publishable sp11v3 assets require one kernel and one touchscreen source archive." >&2
      exit 1
    fi
  elif [ -n "$TOUCHSCREEN_SOURCE_ASSET" ] || [ "$SOURCE_ASSET_COUNT" -ne 1 ]; then
    echo "A non-touchscreen kernel release accepts exactly one patched-source archive." >&2
    exit 1
  fi

  source_asset_sizes=()
  source_asset_shas=()
  source_fingerprint_re='^([1-9][0-9]*) ([0-9a-f]{64})$'
  for source_asset in "${SOURCE_ASSETS[@]}"; do
    source_fingerprint="$(
      trusted_regular_file_fingerprint "$source_asset" 17179869184
    )" || {
      echo "Could not bind the corresponding-source input bytes." >&2
      exit 1
    }
    if ! [[ "$source_fingerprint" =~ $source_fingerprint_re ]]; then
      echo "Corresponding-source input fingerprint is not canonical." >&2
      exit 1
    fi
    source_asset_sizes+=("${BASH_REMATCH[1]}")
    source_asset_shas+=("${BASH_REMATCH[2]}")
    if [ "$source_asset" = "$KERNEL_SOURCE_ASSET" ]; then
      KERNEL_SOURCE_ASSET_SIZE="${BASH_REMATCH[1]}"
      KERNEL_SOURCE_ASSET_SHA256="${BASH_REMATCH[2]}"
    else
      TOUCHSCREEN_SOURCE_ASSET_SIZE="${BASH_REMATCH[1]}"
      TOUCHSCREEN_SOURCE_ASSET_SHA256="${BASH_REMATCH[2]}"
    fi
  done

  if ! python3 -I "$source_archive_validator" kernel \
      --archive "$KERNEL_SOURCE_ASSET" \
      --expected-tree "$patched_tree_id"; then
    echo "Patched-kernel corresponding-source archive does not match build provenance." >&2
    exit 1
  fi
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    if ! python3 -I "$source_archive_validator" touchscreen \
        --archive "$TOUCHSCREEN_SOURCE_ASSET" \
        --expected-modules-tree "$touchscreen_source_modules_tree_id" \
        --expected-license-blob "$touchscreen_source_license_blob_id" \
        --license-mode "$touchscreen_source_license_mode" \
        --expected-archive-comment "$TOUCHSCREEN_SOURCE_REF"; then
      echo "Touchscreen corresponding-source archive does not match module build provenance." >&2
      exit 1
    fi
  fi
  source_index=0
  while [ "$source_index" -lt "${#SOURCE_ASSETS[@]}" ]; do
    source_asset="${SOURCE_ASSETS[$source_index]}"
    source_fingerprint="$(
      trusted_regular_file_fingerprint "$source_asset" 17179869184
    )" || {
      echo "Corresponding-source input changed during semantic validation." >&2
      exit 1
    }
    if [ "$source_fingerprint" != \
         "${source_asset_sizes[$source_index]} ${source_asset_shas[$source_index]}" ]; then
      echo "Corresponding-source input changed during semantic validation." >&2
      exit 1
    fi
    source_index=$((source_index + 1))
  done
fi


if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  if git show-ref --verify --quiet "refs/tags/$RELEASE_NAME"; then
    local_tag_commit="$(git rev-parse "refs/tags/$RELEASE_NAME^{commit}")"
    if [ "$local_tag_commit" != "$repo_commit" ]; then
      echo "Refusing release: local tag $RELEASE_NAME points to $local_tag_commit, not support repo HEAD $repo_commit." >&2
      exit 1
    fi
  fi

  if [ "$dirty" = "false" ] && git remote get-url origin >/dev/null 2>&1; then
    remote_tag_output=""
    remote_tag_status=0
    remote_tag_output="$(
      git ls-remote --exit-code --tags origin \
        "refs/tags/$RELEASE_NAME" "refs/tags/$RELEASE_NAME^{}" 2>/dev/null
    )" || remote_tag_status=$?

    if [ "$remote_tag_status" -eq 0 ]; then
      remote_tag_commit="$(printf '%s\n' "$remote_tag_output" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
      if [ -z "$remote_tag_commit" ]; then
        remote_tag_commit="$(printf '%s\n' "$remote_tag_output" | awk 'NF >= 2 { print $1; exit }')"
      fi
      if [ -n "$remote_tag_commit" ] && [ "$remote_tag_commit" != "$repo_commit" ]; then
        echo "Refusing release: remote tag $RELEASE_NAME points to $remote_tag_commit, not support repo HEAD $repo_commit." >&2
        exit 1
      fi
    elif [ "$remote_tag_status" -ne 2 ]; then
      echo "Refusing a publishable release because remote tag $RELEASE_NAME could not be checked on origin." >&2
      echo "Restore remote access and rerun so an existing tag cannot be reused accidentally." >&2
      exit 1
    fi
  elif [ "$dirty" = "false" ]; then
    echo "Refusing a publishable release because the support repository has no origin remote." >&2
    echo "Configure the public release remote and rerun so an existing tag cannot be missed." >&2
    exit 1
  fi
fi

upload_assets=()
claimed_output_names=()
claimed_output_origins=()

claim_output_name() {
  local name="$1"
  local origin="$2"
  local index=0

  while [ "$index" -lt "${#claimed_output_names[@]}" ]; do
    if [ "${claimed_output_names[$index]}" = "$name" ]; then
      echo "Refusing colliding release asset name $name from $origin; already used by ${claimed_output_origins[$index]}." >&2
      exit 1
    fi
    index=$((index + 1))
  done
  claimed_output_names+=("$name")
  claimed_output_origins+=("$origin")
}

append_upload_asset() {
  local name="$1"
  local origin="$2"

  claim_output_name "$name" "$origin"
  upload_assets+=("$name")
}

checksummed_assets=()
expected_output_names=()
expected_output_sizes=()
expected_output_shas=()
trusted_checksum_contents=""

register_expected_output() {
  local name="$1" size="$2" sha256="$3" index=0

  if ! [[ "$name" =~ ^[0-9A-Za-z][0-9A-Za-z.+_~:@=-]{0,254}$ ]] ||
     ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -gt 17179869184 ] ||
     ! [[ "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Cannot register a noncanonical prepared output authority." >&2
    return 1
  fi
  while [ "$index" -lt "${#expected_output_names[@]}" ]; do
    if [ "${expected_output_names[$index]}" = "$name" ]; then
      echo "Prepared output authority was registered more than once." >&2
      return 1
    fi
    index=$((index + 1))
  done
  expected_output_names+=("$name")
  expected_output_sizes+=("$size")
  expected_output_shas+=("$sha256")
}

register_written_output() {
  local name="$1" record="$2"
  local record_re='^([1-9][0-9]*) ([0-9a-f]{64})$'

  if ! [[ "$record" =~ $record_re ]]; then
    echo "Generated output writer returned a noncanonical intended-byte record." >&2
    return 1
  fi
  register_expected_output "$name" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

expected_output_checksum_line() {
  local name="$1" index=0

  while [ "$index" -lt "${#expected_output_names[@]}" ]; do
    if [ "${expected_output_names[$index]}" = "$name" ]; then
      printf '%s  %s\n' "${expected_output_shas[$index]}" "$name"
      return 0
    fi
    index=$((index + 1))
  done
  echo "Checksummed asset lacks an intended-byte authority." >&2
  return 1
}

verify_expected_output_bytes() {
  local root="$1" index=0 name path fingerprint
  local fingerprint_re='^([0-9]+) ([0-9a-f]{64})$'

  while [ "$index" -lt "${#expected_output_names[@]}" ]; do
    name="${expected_output_names[$index]}"
    path="$root/$name"
    fingerprint="$(trusted_regular_file_fingerprint "$path" 17179869184)" || return 1
    if ! [[ "$fingerprint" =~ $fingerprint_re ]] ||
       [ "${BASH_REMATCH[1]}" != "${expected_output_sizes[$index]}" ] ||
       [ "${BASH_REMATCH[2]}" != "${expected_output_shas[$index]}" ]; then
      echo "Prepared output differs from its independently captured bytes: $name" >&2
      return 1
    fi
    index=$((index + 1))
  done
}

verify_current_output_membership() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

try:
    descriptor = int(sys.argv[1], 10)
    root_path = sys.argv[2]
    expected_root = tuple(int(value, 10) for value in sys.argv[3:8])
    expected = sys.argv[8:]
    if not 1 <= len(expected) <= 70 or len(set(expected)) != len(expected):
        raise RuntimeError
    root = os.dup(descriptor)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        stat.S_IMODE(value.st_mode),
        value.st_uid,
        value.st_gid,
    )
    if (
        identity(os.fstat(root)) != expected_root
        or identity(os.stat(root_path, follow_symlinks=False)) != expected_root
    ):
        raise RuntimeError
    observed = []
    with os.scandir(root) as entries:
        for entry in entries:
            if len(observed) >= len(expected) + 1:
                raise RuntimeError
            observed.append(entry.name)
    if len(observed) != len(expected) or set(observed) != set(expected):
        raise RuntimeError
except BaseException:
    os.write(2, b"error: prepared output membership differs from its exact plan\n")
    raise SystemExit(1)
finally:
    root = locals().get("root")
    if root is not None:
        try:
            os.close(root)
        except OSError:
            pass
' "$OUTPUT_ROOT_FD" "$OUT_DIR" $OUTPUT_ROOT_IDENTITY \
    "${expected_output_names[@]}"
}

verify_held_output_group() {
  local completion_mode="$1" index=0
  local -a output_args=() artifact_args=()

  while [ "$index" -lt "${#expected_output_names[@]}" ]; do
    output_args+=(
      "${expected_output_names[$index]}"
      "${expected_output_sizes[$index]}"
      "${expected_output_shas[$index]}"
    )
    index=$((index + 1))
  done
  index=0
  while [ "$index" -lt "${#retained_flat_names[@]}" ]; do
    artifact_args+=("${retained_flat_names[$index]}")
    index=$((index + 1))
  done
  exec /usr/bin/python3 -I -c '
import hashlib
import os
import re
import signal
import stat
import sys

root = work = artifacts = evidence = None
opened = []
controls = []
committed = False
handled = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
signal.pthread_sigmask(signal.SIG_BLOCK, handled)
for handled_signal in handled:
    signal.signal(handled_signal, signal.SIG_DFL)
try:
    descriptor = int(sys.argv[1], 10)
    root_path = sys.argv[2]
    expected_root = tuple(int(value, 10) for value in sys.argv[3:8])
    evidence_path = sys.argv[8]
    evidence_size = int(sys.argv[9], 10)
    evidence_sha = sys.argv[10]
    count = int(sys.argv[11], 10)
    control_base = 12 + count * 3
    work_descriptor = int(sys.argv[control_base], 10)
    work_path = sys.argv[control_base + 1]
    expected_work = tuple(
        int(value, 10) for value in sys.argv[control_base + 2 : control_base + 7]
    )
    control_authorities = (
        ("docker-build-args.txt", int(sys.argv[control_base + 7], 10), sys.argv[control_base + 8]),
        ("docker-build-inside.sh", int(sys.argv[control_base + 9], 10), sys.argv[control_base + 10]),
        ("sp11-oci-index.json", int(sys.argv[control_base + 11], 10), sys.argv[control_base + 12]),
    )
    artifacts_base = control_base + 13
    artifacts_descriptor = int(sys.argv[artifacts_base], 10)
    artifacts_path = sys.argv[artifacts_base + 1]
    expected_artifacts = tuple(
        int(value, 10) for value in sys.argv[artifacts_base + 2 : artifacts_base + 7]
    )
    artifact_count = int(sys.argv[artifacts_base + 7], 10)
    artifact_names = sys.argv[artifacts_base + 8 : artifacts_base + 8 + artifact_count]
    completion_mode = sys.argv[artifacts_base + 8 + artifact_count]
    fixture_hook = sys.argv[artifacts_base + 9 + artifact_count]
    completion = {
        "draft-both": (
            b"Prepared verified release assets.\n\n"
            b"NO-PUBLISH: kernel-release propagation is complete, but independent release gates remain open.\n"
            b"This is a local draft only.\n"
            b"Rerun with --source-asset and from a clean support repository before publishing binaries.\n"
        ),
        "draft-dirty": (
            b"Prepared verified release assets.\n\n"
            b"NO-PUBLISH: kernel-release propagation is complete, but independent release gates remain open.\n"
            b"This is a local draft only.\n"
            b"Rerun from a clean support repository before publishing binaries.\n"
        ),
        "draft-source": (
            b"Prepared verified release assets.\n\n"
            b"NO-PUBLISH: kernel-release propagation is complete, but independent release gates remain open.\n"
            b"This is a local draft only.\n"
            b"Rerun with --source-asset before publishing binaries.\n"
        ),
        "offline-review": (
            b"Prepared verified release assets.\n\n"
            b"NO-PUBLISH: kernel-release propagation is complete, but independent release gates remain open.\n"
            b"The source-bound candidate is ready for offline review only; no publication command was generated.\n"
        ),
    }.get(completion_mode)
    if completion is None:
        raise RuntimeError
    if (
        not 1 <= count <= 70
        or not 1 <= artifact_count <= 70
        or len(set(artifact_names)) != artifact_count
        or not 0 < evidence_size <= 17179869184
        or not re.fullmatch(r"[0-9a-f]{64}", evidence_sha)
        or fixture_hook not in {
            "",
            "mutate-release-notes-before-register",
            "mutate-output-terminal",
            "mutate-evidence-terminal",
            "mutate-control-terminal",
            "inject-work-member-terminal",
            "inject-artifact-member-terminal",
            "remap-output-root-terminal",
            "remap-work-root-terminal",
            "remap-artifacts-root-terminal",
            "pending-signal-terminal",
            "fail-root-commit",
            "signal-before-terminal-exec",
        }
        or len(sys.argv) != artifacts_base + 10 + artifact_count
    ):
        raise RuntimeError
    root = os.dup(descriptor)
    root_identity = lambda value: (
        value.st_dev,
        value.st_ino,
        stat.S_IMODE(value.st_mode),
        value.st_uid,
        value.st_gid,
    )
    if (
        root_identity(os.fstat(root)) != expected_root
        or root_identity(os.stat(root_path, follow_symlinks=False)) != expected_root
    ):
        raise RuntimeError
    work = os.dup(work_descriptor)
    if (
        root_identity(os.fstat(work)) != expected_work
        or root_identity(os.stat(work_path, follow_symlinks=False)) != expected_work
    ):
        raise RuntimeError
    artifacts = os.dup(artifacts_descriptor)
    mapped_artifacts = os.stat("artifacts", dir_fd=work, follow_symlinks=False)
    if (
        root_identity(os.fstat(artifacts)) != expected_artifacts
        or root_identity(os.stat(artifacts_path, follow_symlinks=False)) != expected_artifacts
        or root_identity(mapped_artifacts) != expected_artifacts
    ):
        raise RuntimeError
    observed_work = []
    with os.scandir(work) as entries:
        for entry in entries:
            if len(observed_work) >= 6:
                raise RuntimeError
            observed_work.append(entry.name)
    if set(observed_work) != {
        "artifacts",
        "docker-build-args.txt",
        "docker-build-inside.sh",
        "sp11-kernel-retained-evidence.tar",
        "sp11-oci-index.json",
    } or len(observed_work) != 5:
        raise RuntimeError
    observed_artifacts = []
    with os.scandir(artifacts) as entries:
        for entry in entries:
            if len(observed_artifacts) >= artifact_count + 1:
                raise RuntimeError
            observed_artifacts.append(entry.name)
    if len(observed_artifacts) != artifact_count or set(observed_artifacts) != set(artifact_names):
        raise RuntimeError
    for name, size, digest in control_authorities:
        if (
            not 0 < size <= 67108864
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
        ):
            raise RuntimeError
        child = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=work,
        )
        metadata = os.fstat(child)
        mapped = os.stat(name, dir_fd=work, follow_symlinks=False)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_nlink != 1
            or metadata.st_size != size
            or (metadata.st_dev, metadata.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            os.close(child)
            raise RuntimeError
        controls.append((name, child, metadata, size, digest))
    evidence_name = os.path.basename(evidence_path)
    if evidence_name != "sp11-kernel-retained-evidence.tar" or evidence_path != os.path.join(work_path, evidence_name):
        raise RuntimeError
    evidence = os.open(
        evidence_name,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
        dir_fd=work,
    )
    evidence_original = os.fstat(evidence)
    evidence_mapped = os.stat(evidence_name, dir_fd=work, follow_symlinks=False)
    if (
        not stat.S_ISREG(evidence_original.st_mode)
        or stat.S_IMODE(evidence_original.st_mode) != 0o644
        or evidence_original.st_nlink != 1
        or evidence_original.st_size != evidence_size
        or (evidence_original.st_dev, evidence_original.st_ino)
        != (evidence_mapped.st_dev, evidence_mapped.st_ino)
    ):
        raise RuntimeError
    expected_names = []
    for index in range(count):
        base = 12 + index * 3
        name = sys.argv[base]
        size = int(sys.argv[base + 1], 10)
        digest = sys.argv[base + 2]
        if (
            not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.+_~:@=-]{0,254}", name)
            or name in expected_names
            or not 0 <= size <= 17179869184
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
        ):
            raise RuntimeError
        expected_names.append(name)
        child = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=root,
        )
        metadata = os.fstat(child)
        mapped = os.stat(name, dir_fd=root, follow_symlinks=False)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o644
            or metadata.st_nlink != 1
            or metadata.st_size != size
            or (metadata.st_dev, metadata.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            os.close(child)
            raise RuntimeError
        opened.append((name, child, metadata, size, digest))
    observed_names = []
    with os.scandir(root) as entries:
        for entry in entries:
            if len(observed_names) >= count + 1:
                raise RuntimeError
            observed_names.append(entry.name)
    if set(observed_names) != set(expected_names) or len(observed_names) != count:
        raise RuntimeError
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
    )
    root_original = os.fstat(root)
    work_original = os.fstat(work)
    artifacts_original = os.fstat(artifacts)
    for _pass in range(2):
        digest = hashlib.sha256()
        offset = 0
        while offset < evidence_size:
            chunk = os.pread(evidence, min(1048576, evidence_size - offset), offset)
            if not chunk:
                raise RuntimeError
            digest.update(chunk)
            offset += len(chunk)
        evidence_current = os.fstat(evidence)
        evidence_mapped = os.stat(evidence_name, dir_fd=work, follow_symlinks=False)
        if (
            digest.hexdigest() != evidence_sha
            or stable(evidence_current) != stable(evidence_original)
            or (evidence_current.st_dev, evidence_current.st_ino)
            != (evidence_mapped.st_dev, evidence_mapped.st_ino)
        ):
            raise RuntimeError
        for name, child, original, size, expected_digest in controls:
            digest = hashlib.sha256()
            offset = 0
            while offset < size:
                chunk = os.pread(child, min(1048576, size - offset), offset)
                if not chunk:
                    raise RuntimeError
                digest.update(chunk)
                offset += len(chunk)
            current = os.fstat(child)
            mapped = os.stat(name, dir_fd=work, follow_symlinks=False)
            if (
                digest.hexdigest() != expected_digest
                or stable(current) != stable(original)
                or (current.st_dev, current.st_ino) != (mapped.st_dev, mapped.st_ino)
            ):
                raise RuntimeError
        for name, child, original, size, expected_digest in opened:
            digest = hashlib.sha256()
            offset = 0
            while offset < size:
                chunk = os.pread(child, min(1048576, size - offset), offset)
                if not chunk:
                    raise RuntimeError
                digest.update(chunk)
                offset += len(chunk)
            current = os.fstat(child)
            mapped = os.stat(name, dir_fd=root, follow_symlinks=False)
            if (
                digest.hexdigest() != expected_digest
                or stable(current) != stable(original)
                or (current.st_dev, current.st_ino) != (mapped.st_dev, mapped.st_ino)
            ):
                raise RuntimeError
    if fixture_hook == "mutate-output-terminal":
        name, child, _original, _size, _digest = next(
            item for item in opened if item[0] == "RELEASE-NOTES.md"
        )
        mutation = os.open(
            name,
            os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=root,
        )
        try:
            metadata = os.fstat(mutation)
            held = os.fstat(child)
            if (
                (metadata.st_dev, metadata.st_ino) != (held.st_dev, held.st_ino)
                or os.pwrite(mutation, b"\0", 0) != 1
            ):
                raise RuntimeError
            os.fsync(mutation)
        finally:
            os.close(mutation)
    elif fixture_hook == "mutate-evidence-terminal":
        mutation = os.open(
            evidence_name,
            os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=work,
        )
        try:
            metadata = os.fstat(mutation)
            held = os.fstat(evidence)
            if (
                (metadata.st_dev, metadata.st_ino) != (held.st_dev, held.st_ino)
                or os.pwrite(mutation, b"\0", 0) != 1
            ):
                raise RuntimeError
            os.fsync(mutation)
        finally:
            os.close(mutation)
    elif fixture_hook == "mutate-control-terminal":
        name, child, _original, _size, _digest = controls[0]
        mutation = os.open(
            name,
            os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=work,
        )
        try:
            metadata = os.fstat(mutation)
            held = os.fstat(child)
            if (
                (metadata.st_dev, metadata.st_ino) != (held.st_dev, held.st_ino)
                or os.pwrite(mutation, b"\0", 0) != 1
            ):
                raise RuntimeError
            os.fsync(mutation)
        finally:
            os.close(mutation)
    elif fixture_hook == "inject-work-member-terminal":
        mutation = os.open(
            ".sp11-terminal-injected",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=work,
        )
        os.fsync(mutation)
        os.close(mutation)
        os.fsync(work)
    elif fixture_hook == "inject-artifact-member-terminal":
        mutation = os.open(
            ".sp11-terminal-injected",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=artifacts,
        )
        os.fsync(mutation)
        os.close(mutation)
        os.fsync(artifacts)
    elif fixture_hook in {
        "remap-output-root-terminal",
        "remap-work-root-terminal",
        "remap-artifacts-root-terminal",
    }:
        if fixture_hook == "remap-output-root-terminal":
            mapped_path = root_path
            held_path = root_path + ".fixture-held"
            victim_path = root_path + ".fixture-victim"
        elif fixture_hook == "remap-work-root-terminal":
            mapped_path = work_path
            held_path = work_path + ".fixture-held"
            victim_path = work_path + ".fixture-victim"
        else:
            mapped_path = artifacts_path
            held_path = work_path + ".artifacts-held"
            victim_path = work_path + ".artifacts-victim"
        victim = os.stat(victim_path, follow_symlinks=False)
        if not stat.S_ISDIR(victim.st_mode) or stat.S_IMODE(victim.st_mode) != 0o700:
            raise RuntimeError
        try:
            os.stat(held_path, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise RuntimeError
        os.rename(mapped_path, held_path)
        os.rename(victim_path, mapped_path)
    observed_names = []
    with os.scandir(root) as entries:
        for entry in entries:
            if len(observed_names) >= count + 1:
                raise RuntimeError
            observed_names.append(entry.name)
    if set(observed_names) != set(expected_names) or len(observed_names) != count:
        raise RuntimeError
    evidence_current = os.fstat(evidence)
    evidence_mapped = os.stat(evidence_name, dir_fd=work, follow_symlinks=False)
    if (
        stable(evidence_current) != stable(evidence_original)
        or (evidence_current.st_dev, evidence_current.st_ino)
        != (evidence_mapped.st_dev, evidence_mapped.st_ino)
    ):
        raise RuntimeError
    for name, child, original, _size, _digest in controls:
        current = os.fstat(child)
        mapped = os.stat(name, dir_fd=work, follow_symlinks=False)
        if (
            stable(current) != stable(original)
            or (current.st_dev, current.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            raise RuntimeError
    observed_work = []
    with os.scandir(work) as entries:
        for entry in entries:
            if len(observed_work) >= 6:
                raise RuntimeError
            observed_work.append(entry.name)
    if set(observed_work) != {
        "artifacts",
        "docker-build-args.txt",
        "docker-build-inside.sh",
        "sp11-kernel-retained-evidence.tar",
        "sp11-oci-index.json",
    } or len(observed_work) != 5:
        raise RuntimeError
    observed_artifacts = []
    with os.scandir(artifacts) as entries:
        for entry in entries:
            if len(observed_artifacts) >= artifact_count + 1:
                raise RuntimeError
            observed_artifacts.append(entry.name)
    if len(observed_artifacts) != artifact_count or set(observed_artifacts) != set(artifact_names):
        raise RuntimeError
    for name, child, original, _size, _digest in opened:
        current = os.fstat(child)
        mapped = os.stat(name, dir_fd=root, follow_symlinks=False)
        if (
            stable(current) != stable(original)
            or (current.st_dev, current.st_ino) != (mapped.st_dev, mapped.st_ino)
        ):
            raise RuntimeError
    if (
        stable(os.fstat(root)) != stable(root_original)
        or stable(os.fstat(work)) != stable(work_original)
        or stable(os.fstat(artifacts)) != stable(artifacts_original)
        or root_identity(os.fstat(root)) != expected_root
        or root_identity(os.stat(root_path, follow_symlinks=False)) != expected_root
        or root_identity(os.fstat(work)) != expected_work
        or root_identity(os.stat(work_path, follow_symlinks=False)) != expected_work
        or root_identity(os.fstat(artifacts)) != expected_artifacts
        or root_identity(os.stat(artifacts_path, follow_symlinks=False)) != expected_artifacts
        or root_identity(os.stat("artifacts", dir_fd=work, follow_symlinks=False)) != expected_artifacts
    ):
        raise RuntimeError
    os.fsync(root)
    if fixture_hook == "pending-signal-terminal":
        os.write(2, b"fixture: pending-signal-terminal triggered\n")
        os.kill(os.getpid(), signal.SIGTERM)
    if signal.sigpending() & handled:
        raise KeyboardInterrupt
    # A private 0700 root is an incomplete forensic candidate.  This held-FD
    # chmod is the sole irreversible commit point; every operation after it is
    # best effort and cannot turn the committed 0500 root back into a failure.
    if fixture_hook == "fail-root-commit":
        os.write(2, b"fixture: fail-root-commit triggered\n")
        os.close(root)
        root = -1
    os.fchmod(root, 0o500)
    committed = True
    for handled_signal in (*handled, signal.SIGPIPE):
        try:
            signal.signal(handled_signal, signal.SIG_IGN)
        except BaseException:
            pass
    try:
        os.fsync(root)
    except OSError:
        pass
    try:
        os.set_blocking(1, False)
        offset = 0
        while offset < len(completion):
            try:
                written = os.write(1, completion[offset:])
            except (BrokenPipeError, BlockingIOError, OSError):
                break
            if written <= 0:
                break
            offset += written
    except BaseException:
        pass
except BaseException:
    if not committed:
        try:
            os.write(2, b"error: prepared output group changed before commit\n")
        except OSError:
            pass
finally:
    for _name, child, _metadata, _size, _digest in reversed(opened):
        try:
            os.close(child)
        except OSError:
            pass
    for _name, child, _metadata, _size, _digest in reversed(controls):
        try:
            os.close(child)
        except OSError:
            pass
    if evidence is not None:
        try:
            os.close(evidence)
        except OSError:
            pass
    if root is not None:
        try:
            os.close(root)
        except OSError:
            pass
    if work is not None:
        try:
            os.close(work)
        except OSError:
            pass
    if artifacts is not None:
        try:
            os.close(artifacts)
        except OSError:
            pass
if not committed:
    raise SystemExit(1)
' "$OUTPUT_ROOT_FD" "$OUT_DIR" $OUTPUT_ROOT_IDENTITY \
    "$retained_evidence_tar" "$retained_evidence_size" \
    "$retained_evidence_sha256" "${#expected_output_names[@]}" \
    "${output_args[@]}" \
    "$BUILD_WORK_ROOT_FD" "$build_work_dir" $BUILD_WORK_ROOT_IDENTITY \
    "$build_args_size" "$build_args_sha" \
    "$entrypoint_size" "$entrypoint_sha" \
    "$oci_index_size" "$oci_index_sha" \
    "$BUILD_ARTIFACTS_ROOT_FD" "$artifacts_abs" \
    $BUILD_ARTIFACTS_ROOT_IDENTITY "${#artifact_args[@]}" \
    "${artifact_args[@]}" "$completion_mode" "$PREPARER_FIXTURE_HOOK"
}

validate_prepared_semantics() {
  local root="$1"
  local index=0 payload_path payload_fingerprint fingerprint_re='^([0-9]+) ([0-9a-f]{64})$'
  local staged_signed_module_report=""
  local -a validator_args public_output_args

  run_committed_python_helper \
    "$manifest_validator_relative" \
    "$manifest_validator_sha" \
    "$manifest_validator_object_id" \
    --repo-dir "$repo_dir" \
    --support-commit "$repo_commit" \
    --build-only \
    --kernel-build-manifest "$root/sp11-kernel-build-manifest.txt" >/dev/null || {
    echo "Prepared kernel module signature report failed committed validation." >&2
    return 1
  }

  if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
    validator_args=(
      --repo-dir "$repo_dir"
      --support-commit "$repo_commit"
      --kernel-build-manifest "$root/sp11-kernel-build-manifest.txt"
      --kernel-release-manifest "$root/sp11-kernel-release-manifest.txt"
      --apt-provenance "$root/sp11-kernel-apt-provenance.txt"
      --build-inputs "$root/sp11-kernel-build-inputs.txt"
      --kernel-source "$root/$(basename "$KERNEL_SOURCE_ASSET")"
      --retained-evidence "$retained_evidence_tar"
      --no-expected-payload-output
    )
    if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
      validator_args+=(
        --release-name "$RELEASE_NAME"
        --touchscreen-module-manifest "$root/$TOUCHSCREEN_MODULE_MANIFEST"
        --touchscreen-source "$root/$(basename "$TOUCHSCREEN_SOURCE_ASSET")"
      )
    else
      validator_args+=(--kernel-release-only)
    fi
    run_committed_python_helper \
      "$manifest_validator_relative" \
      "$manifest_validator_sha" \
      "$manifest_validator_object_id" \
      "${validator_args[@]}" >/dev/null
  fi

  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    if ! staged_signed_module_report="$(
      run_committed_python_helper \
        "$signed_module_validator_relative" \
        "$signed_module_validator_sha" \
        "$signed_module_validator_object_id" \
        --certificate "$root/$TOUCHSCREEN_SIGNING_CERTIFICATE" \
        --module "$root/gpi.ko" \
        --module "$root/spi-geni-qcom.ko" \
        --module "$root/mshw0485_touch.ko"
    )" || [ "$staged_signed_module_report" != "$expected_signed_module_report" ]; then
      echo "Prepared touchscreen bundle failed cryptographic signature validation." >&2
      return 1
    fi
  fi

  while [ "$index" -lt "${#manifest_deb_paths[@]}" ]; do
    payload_path="$root/${manifest_deb_paths[$index]}"
    payload_fingerprint="$(trusted_regular_file_fingerprint "$payload_path" 4294967296)" || return 1
    if ! [[ "$payload_fingerprint" =~ $fingerprint_re ]] ||
       [ "${BASH_REMATCH[1]}" != "${manifest_deb_sizes[$index]}" ] ||
       [ "${BASH_REMATCH[2]}" != "${manifest_deb_sha256s[$index]}" ]; then
      echo "Prepared kernel payload differs from exact build provenance." >&2
      return 1
    fi
    index=$((index + 1))
  done

  public_output_args=(
    --file "$root/sp11-kernel-build-manifest.txt"
    --file "$root/sp11-kernel-apt-provenance.txt"
    --file "$root/sp11-kernel-build-inputs.txt"
    --file "$root/sp11-kernel-module-signatures.txt"
    --file "$root/sp11-kernel-release-manifest.txt"
    --file "$root/sp11-kernel-debs.txt"
    --file "$root/RELEASE-NOTES.md"
  )
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    public_output_args+=(--file "$root/$TOUCHSCREEN_MODULE_MANIFEST")
  fi
  "$public_content_validator" "${public_output_args[@]}" >/dev/null
}

verify_output_snapshot() {
  local root="$1"

  verify_current_output_membership
  verify_expected_output_bytes "$root"
}

verify_prepared_output() {
  local root="$1"

  verify_output_snapshot "$root"
  verify_all_retained_flat_files "$root"
  validate_prepared_semantics "$root"
  verify_all_retained_flat_files "$root"
  verify_output_snapshot "$root"
}

claim_output_name "SHA256SUMS" "generated checksum file"
claim_output_name "RELEASE-NOTES.md" "generated release notes"

for deb in "${debs[@]}"; do
  append_upload_asset "$(basename "$deb")" "$deb"
done

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  for source_asset in "${SOURCE_ASSETS[@]}"; do
    append_upload_asset "$(basename "$source_asset")" "$source_asset"
  done
fi

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
    append_upload_asset "$module_file" "$TOUCHSCREEN_MODULES_DIR/$module_file"
  done
  append_upload_asset \
    "$TOUCHSCREEN_SIGNING_CERTIFICATE" \
    "$TOUCHSCREEN_MODULES_DIR/$TOUCHSCREEN_SIGNING_CERTIFICATE"
  append_upload_asset "$TOUCHSCREEN_MODULE_MANIFEST" "generated touchscreen module manifest"
fi

append_upload_asset "sp11-kernel-release-manifest.txt" "generated kernel release manifest"
append_upload_asset "sp11-kernel-debs.txt" "generated kernel package list"
append_upload_asset "sp11-kernel-build-manifest.txt" "schema-v2 kernel build provenance"
append_upload_asset "sp11-kernel-apt-provenance.txt" "immutable APT provenance"
append_upload_asset "sp11-kernel-build-inputs.txt" "immutable build-input envelope"
append_upload_asset \
  "sp11-kernel-module-signatures.txt" \
  "controlled kernel-module signature evidence"

FINAL_OUT_DIR="$OUT_DIR"
verify_held_output_root

verify_retained_flat_file "$build_manifest" "sp11-kernel-build-manifest.txt"
copy_verified_regular_exclusive \
  "$build_manifest" "$OUT_DIR/sp11-kernel-build-manifest.txt" \
  "$RETAINED_FLAT_SIZE" "$RETAINED_FLAT_SHA256"
register_expected_output \
  sp11-kernel-build-manifest.txt \
  "$RETAINED_FLAT_SIZE" "$RETAINED_FLAT_SHA256"
build_manifest="$OUT_DIR/sp11-kernel-build-manifest.txt"
if ! verify_retained_flat_file "$build_manifest" "sp11-kernel-build-manifest.txt"; then
  echo "Staged kernel build manifest changed after provenance validation." >&2
  exit 1
fi
copy_verified_regular_exclusive \
  "$apt_provenance" "$OUT_DIR/sp11-kernel-apt-provenance.txt" \
  "$apt_provenance_snapshot_size" "$apt_provenance_snapshot_sha"
register_expected_output \
  sp11-kernel-apt-provenance.txt \
  "$apt_provenance_snapshot_size" "$apt_provenance_snapshot_sha"
apt_provenance="$OUT_DIR/sp11-kernel-apt-provenance.txt"
if ! verify_retained_flat_file "$apt_provenance" "sp11-kernel-apt-provenance.txt"; then
  echo "Staged APT provenance changed after validation." >&2
  exit 1
fi
copy_verified_regular_exclusive \
  "$build_inputs" "$OUT_DIR/sp11-kernel-build-inputs.txt" \
  "$build_inputs_snapshot_size" "$build_inputs_snapshot_sha"
register_expected_output \
  sp11-kernel-build-inputs.txt \
  "$build_inputs_snapshot_size" "$build_inputs_snapshot_sha"
build_inputs="$OUT_DIR/sp11-kernel-build-inputs.txt"
if ! verify_retained_flat_file "$build_inputs" "sp11-kernel-build-inputs.txt"; then
  echo "Staged build-input envelope changed after validation." >&2
  exit 1
fi
copy_verified_regular_exclusive \
  "$kernel_signature_report" "$OUT_DIR/sp11-kernel-module-signatures.txt" \
  "$kernel_signature_report_snapshot_size" "$kernel_signature_report_snapshot_sha"
register_expected_output \
  sp11-kernel-module-signatures.txt \
  "$kernel_signature_report_snapshot_size" "$kernel_signature_report_snapshot_sha"
kernel_signature_report="$OUT_DIR/sp11-kernel-module-signatures.txt"
if ! verify_retained_flat_file \
  "$kernel_signature_report" "sp11-kernel-module-signatures.txt"; then
  echo "Staged kernel module signature report changed after provenance validation." >&2
  exit 1
fi

for deb in "${debs[@]}"; do
  deb_name="$(basename "$deb")"
  verify_retained_flat_file "$deb" "$deb_name"
  copy_verified_regular_exclusive \
    "$deb" "$OUT_DIR/$deb_name" \
    "$RETAINED_FLAT_SIZE" "$RETAINED_FLAT_SHA256"
  register_expected_output \
    "$deb_name" "$RETAINED_FLAT_SIZE" "$RETAINED_FLAT_SHA256"
done

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  staged_source_assets=()
  source_index=0
  for source_asset in "${SOURCE_ASSETS[@]}"; do
    staged_source="$OUT_DIR/$(basename "$source_asset")"
    copy_verified_regular_exclusive \
      "$source_asset" "$staged_source" \
      "${source_asset_sizes[$source_index]}" \
      "${source_asset_shas[$source_index]}"
    register_expected_output \
      "$(basename "$source_asset")" \
      "${source_asset_sizes[$source_index]}" \
      "${source_asset_shas[$source_index]}"
    staged_source_assets+=("$staged_source")
    source_index=$((source_index + 1))
  done
  SOURCE_ASSETS=("${staged_source_assets[@]}")
  KERNEL_SOURCE_ASSET="$OUT_DIR/$(basename "$KERNEL_SOURCE_ASSET")"
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    TOUCHSCREEN_SOURCE_ASSET="$OUT_DIR/$(basename "$TOUCHSCREEN_SOURCE_ASSET")"
  fi
fi

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  module_index=0
  while [ "$module_index" -lt "${#TOUCHSCREEN_MODULE_FILES[@]}" ]; do
    module_file="${TOUCHSCREEN_MODULE_FILES[$module_index]}"
    copy_verified_regular_exclusive \
      "$TOUCHSCREEN_MODULES_DIR/$module_file" "$OUT_DIR/$module_file" \
      "${touchscreen_module_sizes[$module_index]}" \
      "${touchscreen_module_shas[$module_index]}"
    register_expected_output \
      "$module_file" "${touchscreen_module_sizes[$module_index]}" \
      "${touchscreen_module_shas[$module_index]}"
    module_index=$((module_index + 1))
  done
  copy_verified_regular_exclusive \
    "$TOUCHSCREEN_MODULES_DIR/$TOUCHSCREEN_SIGNING_CERTIFICATE" \
    "$OUT_DIR/$TOUCHSCREEN_SIGNING_CERTIFICATE" \
    "$touchscreen_signing_certificate_size" \
    "$touchscreen_signing_certificate_sha256"
  register_expected_output \
    "$TOUCHSCREEN_SIGNING_CERTIFICATE" \
    "$touchscreen_signing_certificate_size" \
    "$touchscreen_signing_certificate_sha256"
fi

actual_index=0
while [ "$actual_index" -lt "${#debs[@]}" ]; do
  staged_deb="$OUT_DIR/$(basename "${debs[$actual_index]}")"
  staged_deb_sha="$(shasum -a 256 "$staged_deb" | awk '{print $1}')"
  expected_staged_deb_sha=""
  manifest_index=0
  while [ "$manifest_index" -lt "${#manifest_deb_paths[@]}" ]; do
    if [ "${manifest_deb_paths[$manifest_index]}" = "$(basename "$staged_deb")" ]; then
      expected_staged_deb_sha="${manifest_deb_sha256s[$manifest_index]}"
      break
    fi
    manifest_index=$((manifest_index + 1))
  done
  if [ -z "$expected_staged_deb_sha" ] || [ "$staged_deb_sha" != "$expected_staged_deb_sha" ]; then
    echo "Staged kernel package changed after provenance validation: $(basename "$staged_deb")" >&2
    exit 1
  fi
  actual_index=$((actual_index + 1))
done
if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  [ "$(shasum -a 256 "$KERNEL_SOURCE_ASSET" | awk '{print $1}')" = "$KERNEL_SOURCE_ASSET_SHA256" ] || {
    echo "Staged patched-kernel source archive changed after validation." >&2
    exit 1
  }
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    [ "$(shasum -a 256 "$TOUCHSCREEN_SOURCE_ASSET" | awk '{print $1}')" = "$TOUCHSCREEN_SOURCE_ASSET_SHA256" ] || {
      echo "Staged touchscreen source archive changed after validation." >&2
      exit 1
    }
  fi
fi
if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  module_index=0
  while [ "$module_index" -lt "${#TOUCHSCREEN_MODULE_FILES[@]}" ]; do
    staged_module="$OUT_DIR/${TOUCHSCREEN_MODULE_FILES[$module_index]}"
    if [ "$(shasum -a 256 "$staged_module" | awk '{print $1}')" != "${touchscreen_module_shas[$module_index]}" ]; then
      echo "Staged touchscreen module changed after provenance validation: ${TOUCHSCREEN_MODULE_FILES[$module_index]}" >&2
      exit 1
    fi
    module_index=$((module_index + 1))
  done
  if [ "$(shasum -a 256 "$OUT_DIR/$TOUCHSCREEN_SIGNING_CERTIFICATE" | awk '{print $1}')" != "$touchscreen_signing_certificate_sha256" ]; then
    echo "Staged touchscreen public signing certificate changed after provenance validation." >&2
    exit 1
  fi
fi

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  touchscreen_manifest_record="$(
  {
    echo "Generated: $generated_at"
    echo "Release: $RELEASE_NAME"
    echo "Kernel ABI: $kernel_abi"
    echo "Touchscreen source URL: $TOUCHSCREEN_SOURCE_URL"
    echo "Touchscreen source commit: $TOUCHSCREEN_SOURCE_REF"
    echo "Source archive contract: $touchscreen_source_contract"
    echo "Source object format: $touchscreen_source_object_format"
    echo "Source modules path: $touchscreen_source_modules_path"
    echo "Source modules tree ID: $touchscreen_source_modules_tree_id"
    echo "Source license path: $touchscreen_source_license_path"
    echo "Source license mode: $touchscreen_source_license_mode"
    echo "Source license blob ID: $touchscreen_source_license_blob_id"
    echo "Kernel config SHA256: $touchscreen_kernel_config_sha256"
    echo "Kernel Module.symvers SHA256: $touchscreen_kernel_module_symvers_sha256"
    echo "Kernel headers input mode: $touchscreen_kernel_headers_input_mode"
    echo "Kernel common headers Deb: $touchscreen_kernel_common_headers_deb"
    echo "Kernel common headers Deb SHA256: $touchscreen_kernel_common_headers_deb_sha256"
    echo "Kernel architecture headers Deb: $touchscreen_kernel_headers_deb"
    echo "Kernel architecture headers Deb SHA256: $touchscreen_kernel_headers_deb_sha256"
    echo "Module compiler identity: $touchscreen_module_compiler_identity"
    echo "Module linker identity: $touchscreen_module_linker_identity"
    echo "Module make identity: $touchscreen_module_make_identity"
    echo "Support repo commit: $repo_commit"
    echo "Support repo dirty: $dirty"
    echo "Module signing policy: $touchscreen_signing_policy"
    echo "Module signing private material retained: $touchscreen_signing_private_material_retained"
    echo "Module signing hash algorithm: $touchscreen_signing_hash_algorithm"
    echo "Module signing certificate asset: $TOUCHSCREEN_SIGNING_CERTIFICATE"
    echo "Module signing certificate SHA256: $touchscreen_signing_certificate_sha256"
    echo "Module signing certificate fingerprint: $touchscreen_signing_certificate_fingerprint"
    echo "Module signing certificate serial: $touchscreen_signing_certificate_serial"
    echo "Required SPI parameter: sp11_windows_se_init"
    module_index=0
    for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
      echo "Module $module_file name: ${touchscreen_module_names[$module_index]}"
      echo "Module $module_file size: ${touchscreen_module_sizes[$module_index]}"
      echo "Module $module_file SHA256: ${touchscreen_module_shas[$module_index]}"
      echo "Module $module_file payload size: ${touchscreen_module_payload_sizes[$module_index]}"
      echo "Module $module_file payload SHA256: ${touchscreen_module_payload_shas[$module_index]}"
      echo "Module $module_file signature size: ${touchscreen_module_signature_sizes[$module_index]}"
      echo "Module $module_file signature SHA256: ${touchscreen_module_signature_shas[$module_index]}"
      echo "Module $module_file vermagic: ${touchscreen_module_vermagic[$module_index]}"
      echo "Module $module_file srcversion: ${touchscreen_module_srcversions[$module_index]}"
      module_index=$((module_index + 1))
    done
  } | write_release_text_exclusive "$TOUCHSCREEN_MODULE_MANIFEST" 1048576
  )" || exit 1
  register_written_output \
    "$TOUCHSCREEN_MODULE_MANIFEST" "$touchscreen_manifest_record"
fi

release_manifest_record="$(
{
  echo "Generated: $generated_at"
  echo "Release: $RELEASE_NAME"
  echo "Kernel release schema: sp11-kernel-release-v1"
  echo "Build provenance schema: $provenance_schema"
  echo "Release build: $release_build"
  echo "Build completed: $build_completed"
  echo "Kernel build manifest asset: sp11-kernel-build-manifest.txt"
  echo "Kernel build manifest size: $build_manifest_snapshot_size"
  echo "Kernel build manifest SHA256: $build_manifest_snapshot_sha"
  echo "APT provenance asset: sp11-kernel-apt-provenance.txt"
  echo "APT provenance schema: $apt_provenance_schema"
  echo "APT provenance size: $apt_provenance_snapshot_size"
  echo "APT provenance SHA256: $apt_provenance_snapshot_sha"
  echo "APT snapshot ID: $apt_snapshot_id"
  echo "APT snapshot URI: $apt_snapshot_uri"
  echo "Build inputs asset: sp11-kernel-build-inputs.txt"
  echo "Build inputs schema: $build_inputs_schema"
  echo "Build inputs size: $build_inputs_snapshot_size"
  echo "Build inputs SHA256: $build_inputs_snapshot_sha"
  echo "Build envelope creation propagation: $build_envelope_creation_propagation"
  echo "Kernel release propagation: complete"
  echo "Retained evidence schema: sp11-kernel-retained-evidence-v1"
  echo "Retained evidence tar: sp11-kernel-retained-evidence.tar"
  echo "Retained evidence tar size: $retained_evidence_size"
  echo "Retained evidence tar SHA256: $retained_evidence_sha256"
  echo "Retained evidence disposition: local-validation-input"
  echo "OCI index image: $oci_index_image"
  echo "OCI index digest: $oci_index_digest"
  echo "OCI platform: $oci_platform"
  echo "OCI platform manifest: $oci_platform_manifest"
  echo "Publication state: blocked"
  echo "Support repo commit: $repo_commit"
  echo "Support repo dirty: $dirty"
  echo "Source mode: ${source_mode:-unknown}"
  echo "Source URL: ${SOURCE_URL:-unknown}"
  echo "Source branch: ${SOURCE_BRANCH:-unknown}"
  echo "Source HEAD: ${source_head:-unknown}"
  echo "Docker image: $DOCKER_IMAGE"
  echo "Container digest: $manifest_container_digest"
  echo "Container platform: $manifest_container_platform"
  echo "Build target: ${build_target:-unknown}"
  echo "Jobs: ${jobs:-unknown}"
  echo "Rules runner: ${rules_runner:-unknown}"
  echo "Patched diff format: $patched_diff_format"
  echo "Patched diff Git version: $patched_diff_git_version"
  echo "Patched diff SHA256: $patched_diff_sha256"
  echo "Patched tree ID: $patched_tree_id"
  echo "Required output roles: $required_output_role_set"
  echo "Optional output roles: $optional_output_role_set"
  echo "Required package roles: $required_deb_role_set"
  echo "Optional package roles: $optional_deb_role_set"
  echo "Module signing policy: $module_signing_policy"
  echo "Module signing private material retained: $module_signing_private_material_retained"
  echo "Signing certificate SHA256: $signing_certificate_sha256"
  echo "Signing certificate fingerprint: $signing_certificate_fingerprint"
  echo "Signing certificate serial: $signing_certificate_serial"
  echo "Kernel module signature report asset: $kernel_signature_report_asset"
  echo "Kernel module signature report size: $kernel_signature_report_size"
  echo "Kernel module signature report SHA256: $kernel_signature_report_sha256"
  echo "Kernel module signature report schema: $kernel_signature_report_schema"
  echo "Kernel module total count: $kernel_module_total_count"
  echo "Kernel module verified signed count: $kernel_module_verified_signed_count"
  echo "Kernel module policy-allowed unsigned count: $kernel_module_policy_allowed_unsigned_count"
  echo "Kernel module unsigned-path inventory SHA256: $kernel_module_unsigned_path_inventory_sha256"
  echo "Package count: ${#debs[@]}"
  package_index=0
  while [ "$package_index" -lt "${#debs[@]}" ]; do
    echo "Package $((package_index + 1)) file: $(basename "${debs[$package_index]}")"
    echo "Package $((package_index + 1)) SHA256: ${actual_deb_shas[$package_index]}"
    package_index=$((package_index + 1))
  done
  if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
    echo "Kernel source archive: $(basename "$KERNEL_SOURCE_ASSET")"
    echo "Kernel source archive SHA256: $KERNEL_SOURCE_ASSET_SHA256"
    echo "Kernel source tree ID: $patched_tree_id"
    if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
      echo "Touchscreen source archive: $(basename "$TOUCHSCREEN_SOURCE_ASSET")"
      echo "Touchscreen source archive SHA256: $TOUCHSCREEN_SOURCE_ASSET_SHA256"
      echo "Touchscreen source commit: $TOUCHSCREEN_SOURCE_REF"
      echo "Touchscreen source modules tree ID: $touchscreen_source_modules_tree_id"
      echo "Touchscreen source license blob ID: $touchscreen_source_license_blob_id"
      echo "Touchscreen kernel config SHA256: $touchscreen_kernel_config_sha256"
      echo "Touchscreen kernel Module.symvers SHA256: $touchscreen_kernel_module_symvers_sha256"
      echo "Touchscreen kernel headers input mode: $touchscreen_kernel_headers_input_mode"
      echo "Touchscreen kernel common headers Deb: $touchscreen_kernel_common_headers_deb"
      echo "Touchscreen kernel common headers Deb SHA256: $touchscreen_kernel_common_headers_deb_sha256"
      echo "Touchscreen kernel architecture headers Deb: $touchscreen_kernel_headers_deb"
      echo "Touchscreen kernel architecture headers Deb SHA256: $touchscreen_kernel_headers_deb_sha256"
      module_index=0
      while [ "$module_index" -lt "${#TOUCHSCREEN_MODULE_FILES[@]}" ]; do
        echo "Touchscreen module ${TOUCHSCREEN_MODULE_FILES[$module_index]} SHA256: ${touchscreen_module_shas[$module_index]}"
        module_index=$((module_index + 1))
      done
    fi
  fi
} | write_release_text_exclusive sp11-kernel-release-manifest.txt 4194304
)" || exit 1
register_written_output \
  sp11-kernel-release-manifest.txt "$release_manifest_record"

deb_list_record="$(
{
  for deb in "${debs[@]}"; do
    basename "$deb"
  done
} | write_release_text_exclusive sp11-kernel-debs.txt 1048576
)" || exit 1
register_written_output sp11-kernel-debs.txt "$deb_list_record"

release_notes_record="$(
{
cat <<EOF
# Surface Pro 11 qcom-x1e Kernel Packages

Experimental prebuilt qcom-x1e kernel packages for Surface Pro 11.

These artifacts are optional conveniences, are not an apt repository, and
should be used only with a known-good fallback qcom-x1e kernel still installed.
The release asset set has no separate detached signature; its kernel and
touchscreen modules use the controlled signing policy recorded below.

## Verify

Download \`SHA256SUMS\` and every asset named in it, then run:

\`\`\`bash
(cd /path/to/downloaded-release-assets && shasum -a 256 -c SHA256SUMS)
\`\`\`

EOF

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  cat <<EOF
## Install Flow

The kernel packages and touchscreen modules are one ABI-matched set. Install
both from the same downloaded asset directory, and keep the fallback kernel
until the new kernel and touchscreen have both been tested.

\`\`\`bash
ASSET_DIR=/absolute/path/to/downloaded-release-assets
cd /path/to/linux-surface-pro-11-oe

sudo ./scripts/build-sp11-qcom-x1e-kernel.sh \\
  --work-dir "\$ASSET_DIR" \\
  --install-only
\`\`\`

The unified installer finds the three modules beside the packages and installs
them for \`$kernel_abi\`. It refuses an incomplete sp11v3 transaction rather
than silently installing a kernel whose touchscreen cannot initialize. Reboot
after it completes, then test both the new kernel and touchscreen.

EOF
else
  cat <<EOF
## Install Flow

1. Copy the verified \`.deb\` files into local \`payload/kernel-debs/\`.
2. Rebuild and write the Surface Pro 11 USB image.
3. On the Surface, install using:

\`\`\`bash
sudo ./scripts/build-sp11-qcom-x1e-kernel.sh \\
  --work-dir "\$SP11DATA/payload/kernel-debs" \\
  --install-only
\`\`\`

EOF
fi

cat <<EOF
## Provenance

See \`sp11-kernel-release-manifest.txt\` for package hashes, source metadata,
support repository commit, patch checksums, and exact hashes for the attached
schema-v2 build manifest, v1 APT sidecar, v1 build-inputs envelope, and
\`sp11-kernel-module-signatures.txt\` controlled-signature verification report.

Recorded source:

- Source URL: \`${SOURCE_URL:-unknown}\`
- Source ref: \`${SOURCE_BRANCH:-unknown}\`
- Source HEAD: \`${source_head:-unknown}\`
EOF

echo "- Docker image: \`$DOCKER_IMAGE\`"
echo "- Container platform: \`$manifest_container_platform\`"
echo "- Patched tree ID: \`$patched_tree_id\`"
echo "- Patched diff SHA256: \`$patched_diff_sha256\`"
echo "- Module signing policy: \`$module_signing_policy\`"
echo "- Module signing private material retained: \`$module_signing_private_material_retained\`"
echo "- Module signing certificate SHA256: \`$signing_certificate_sha256\`"
echo "- Cryptographically verified signed kernel modules: \`$kernel_module_verified_signed_count\`"
echo "- Policy-allowed unsigned kernel modules: \`$kernel_module_policy_allowed_unsigned_count\`"
echo "- APT snapshot: \`$apt_snapshot_id\`"
echo "- OCI platform manifest: \`$oci_platform_manifest\`"

echo "- Ordered patch count: \`$patch_count\`"

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  cat <<EOF
- Touchscreen source URL: \`$TOUCHSCREEN_SOURCE_URL\`
- Touchscreen source commit: \`$TOUCHSCREEN_SOURCE_REF\`
- Touchscreen manifest: \`$TOUCHSCREEN_MODULE_MANIFEST\`
- Touchscreen public signing certificate: \`$TOUCHSCREEN_SIGNING_CERTIFICATE\`
EOF
fi

cat <<EOF

These artifacts were built from recorded inputs; they are not claimed to be
bit-for-bit reproducible. Kernel-release provenance propagation is complete,
but publication remains blocked by the independent real-build, recovery,
corresponding-source, and release-authorization gates. The interim
licence/UCM direction is recorded in LEGAL.md with final reviews pending; those
reviews are disclosure obligations rather than a blanket block on newly
authored artifacts. This preparer deliberately emits no publication command.
EOF
} | write_release_text_exclusive RELEASE-NOTES.md 1048576
)" || exit 1
register_written_output RELEASE-NOTES.md "$release_notes_record"

checksummed_assets=("${upload_assets[@]}")
validate_prepared_semantics "$OUT_DIR"
verify_expected_output_bytes "$OUT_DIR"

trusted_checksum_contents="$(
  for asset in "${checksummed_assets[@]}"; do
    expected_output_checksum_line "$asset"
  done
)"
checksum_record="$(
  printf '%s\n' "$trusted_checksum_contents" |
    write_release_text_exclusive SHA256SUMS 1048576
)" || exit 1
register_written_output SHA256SUMS "$checksum_record"

verify_final_support_state
verify_prepared_output "$OUT_DIR"
verify_final_support_state
verify_prepared_output "$OUT_DIR"
verify_retained_evidence_tar
if [ "$SOURCE_ASSET_COUNT" -eq 0 ] && [ "$dirty" = "true" ]; then
  completion_mode=draft-both
elif [ "$SOURCE_ASSET_COUNT" -eq 0 ]; then
  completion_mode=draft-source
elif [ "$dirty" = "true" ]; then
  completion_mode=draft-dirty
else
  completion_mode=offline-review
fi
trap 'exit 130' HUP INT TERM
trap '' PIPE
if [ "$PREPARER_FIXTURE_HOOK" = signal-before-terminal-exec ]; then
  printf 'fixture: signal-before-terminal-exec triggered\n' >&2
  kill -TERM "$$"
  exit 1
fi
verify_held_output_group "$completion_mode"
exit 1
