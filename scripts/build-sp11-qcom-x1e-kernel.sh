#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_ARGUMENTS=("$@")

sanitize_git_environment() {
  local variable_name

  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
  unset GIT_CONFIG_GLOBAL GIT_DIR GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXEC_PATH
  unset GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_PREFIX
  unset GIT_SHALLOW_FILE GIT_TEMPLATE_DIR GIT_WORK_TREE
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

# Host/container ambient identity must never influence package bytes.  Explicit
# deterministic arguments are validated and exported only after the exact
# source commit and its timestamp have both been verified.
unset SOURCE_DATE_EPOCH KBUILD_BUILD_USER KBUILD_BUILD_HOST KBUILD_BUILD_TIMESTAMP

SOURCE_MODE="apt"
SOURCE_PACKAGE="installed"
SOURCE_VERSION="installed"
GIT_URL="https://git.launchpad.net/~ubuntu-concept/ubuntu/+source/linux/+git/resolute"
GIT_BRANCH="qcom-x1e-7.0"
EXPECTED_SOURCE_COMMIT=""
SOURCE_DATE_EPOCH=""
KBUILD_BUILD_USER=""
KBUILD_BUILD_HOST=""
KBUILD_BUILD_TIMESTAMP=""
BUILD_TARGET="binary-qcom-x1e"
WORK_DIR="${HOME}/sp11-qcom-x1e-kernel-build"
WORK_DIR_IDENTITY=""
PATCH_DIR=""
PATCH_DIRS=""
MIN_FREE_GB=40
INSTALL_DEPS="false"
INSTALL_DEBS="false"
INSTALL_ONLY="false"
PREPARE_ONLY="false"
RELEASE_BUILD="false"
RESET_SOURCE="false"
ALLOW_NON_ARM64="false"
ALLOW_NO_FALLBACK="false"
TOUCHSCREEN_MODULES_DIR=""
SKIP_TOUCHSCREEN_MODULES="false"
SKIP_CLEAN="false"
NO_FAKEROOT="false"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
SOURCE_SPEC=""
RESOLVED_SOURCE_PACKAGE=""
SUPPORT_HEAD_START=""
KERNEL_BASELINE_REL="config/kernel-baselines/7.2-rc5-jg-0.env"
KERNEL_BASELINE_VALIDATOR_REL="scripts/validate-sp11-kernel-baseline.sh"
KERNEL_TREE_SYMLINK_VALIDATOR_REL="scripts/validate-sp11-kernel-tree-symlinks.py"
BASELINE_CONTROL_DIR=""
BASELINE_CONTROL_PARENT=""
BASELINE_CONTROL_IDENTITY=""
BASELINE_CONTROL_STATE=""
KERNEL_BASELINE=""
KERNEL_BASELINE_VALIDATOR=""
KERNEL_TREE_SYMLINK_VALIDATOR=""
KERNEL_BASELINE_STATE=""
KERNEL_BASELINE_VALIDATOR_STATE=""
KERNEL_TREE_SYMLINK_VALIDATOR_STATE=""
KERNEL_BASELINE_OID=""
KERNEL_BASELINE_VALIDATOR_OID=""
KERNEL_TREE_SYMLINK_VALIDATOR_OID=""
KERNEL_TREE_VALIDATOR_SINK_OPEN="false"
KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="false"
KERNEL_TREE_VALIDATOR_PYTHON=""
KERNEL_TREE_VALIDATOR_PYTHON_IDENTITY=""
KERNEL_TREE_VALIDATOR_HELPER_FD_OPEN="false"
KERNEL_TREE_VALIDATOR_HELPER=""
KERNEL_TREE_VALIDATOR_HELPER_SHA256=""
RELEASE_TEST_FIXTURE_CONTEXT="false"
RELEASE_BASELINE_FDS_OPEN="false"
RELEASE_BASELINE_PATH=""
RELEASE_BASELINE_VALIDATOR_PATH=""
RELEASE_SOURCE_INDEX_MUTATED="false"
BASELINE_DOCKER_IMAGE=""
BASELINE_ID=""
BASELINE_DOCKER_PLATFORM=""
BASELINE_DOCKER_PLATFORM_MANIFEST=""
BASELINE_UPSTREAM_URL=""
BASELINE_UPSTREAM_REF=""
BASELINE_UPSTREAM_COMMIT=""
BASELINE_SOURCE_DATE_EPOCH=""
BASELINE_KBUILD_BUILD_USER=""
BASELINE_KBUILD_BUILD_HOST=""
BASELINE_KBUILD_BUILD_TIMESTAMP=""
BASELINE_BUILD_TARGET=""
BASELINE_PATCH_DIRS=""
PATCHED_DIFF_FORMAT="git-diff-full-index-binary-v1"
PATCHED_DIFF_GIT_VERSION=""
PATCHED_DIFF_SIZE=""
PATCHED_DIFF_SHA256=""
PATCHED_TREE_ID=""
PATCHED_DIFF_ARGS=(
  --binary
  --full-index
  --no-ext-diff
  --no-textconv
  --no-color
  --diff-algorithm=myers
  --indent-heuristic
  --unified=3
  --inter-hunk-context=0
  --no-renames
  -O/dev/null
  --src-prefix=a/
  --dst-prefix=b/
)
PATCHED_UNTRACKED_PATHS_SIZE=""
PATCHED_UNTRACKED_PATHS_SHA256=""
RELEASE_PATCH_PATHS=()
RELEASE_PATCH_ABS_PATHS=()
RELEASE_PATCH_SHA256S=()
RELEASE_PATCH_DISPOSITIONS=()
RELEASE_OUTPUT_ROLES=()
RELEASE_OUTPUT_PATHS=()
RELEASE_OUTPUT_SIZES=()
RELEASE_OUTPUT_SHA256S=()
RELEASE_DEB_ROLES=()
RELEASE_DEB_PATHS=()
RELEASE_DEB_PACKAGES=()
RELEASE_DEB_VERSIONS=()
RELEASE_DEB_ARCHITECTURES=()
RELEASE_DEB_SIZES=()
RELEASE_DEB_SHA256S=()
SIGNING_CERT_FINGERPRINT=""
SIGNING_CERT_SERIAL=""
SIGNING_CERT_SHA256=""

baseline_control_identity() {
  local path="$1"

  case "$(uname -s)" in
    Darwin) stat -f '%d:%i:%Lp:%u:%g' "$path" ;;
    *) stat -c '%d:%i:%a:%u:%g' -- "$path" ;;
  esac
}

baseline_control_file_state() {
  local path="$1" before after digest

  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  case "$(uname -s)" in
    Darwin) before="$(stat -f '%d:%i:%z:%Fm:%Fc:%Lp:%u:%g:%l' "$path")" ;;
    *) before="$(stat -c '%d:%i:%s:%y:%z:%a:%u:%g:%h' -- "$path")" ;;
  esac
  digest="$(sha256_file "$path")"
  case "$(uname -s)" in
    Darwin) after="$(stat -f '%d:%i:%z:%Fm:%Fc:%Lp:%u:%g:%l' "$path")" ;;
    *) after="$(stat -c '%d:%i:%s:%y:%z:%a:%u:%g:%h' -- "$path")" ;;
  esac
  [ "$before" = "$after" ] && [ "${before##*:}" = "1" ] &&
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s:%s\n' "$before" "$digest"
}

baseline_control_directory_state() {
  local path="$1" before after

  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  case "$(uname -s)" in
    Darwin) before="$(stat -f '%d:%i:%z:%Fm:%Fc:%Lp:%u:%g:%l' "$path")" ;;
    *) before="$(stat -c '%d:%i:%s:%y:%z:%a:%u:%g:%h' -- "$path")" ;;
  esac
  case "$(uname -s)" in
    Darwin) after="$(stat -f '%d:%i:%z:%Fm:%Fc:%Lp:%u:%g:%l' "$path")" ;;
    *) after="$(stat -c '%d:%i:%s:%y:%z:%a:%u:%g:%h' -- "$path")" ;;
  esac
  [ "$before" = "$after" ] || return 1
  printf '%s\n' "$before"
}

verify_kernel_baseline_control_state() {
  local current

  [ "$RELEASE_BASELINE_FDS_OPEN" = "true" ] || return 1
  current="$(held_release_control_state \
    3 "$KERNEL_BASELINE" "$KERNEL_BASELINE_OID" 524288)" || return 1
  if [ "$current" != "$KERNEL_BASELINE_STATE" ]; then
    echo "Held committed kernel baseline changed after binding." >&2
    return 1
  fi
  current="$(held_release_control_state \
    4 "$KERNEL_BASELINE_VALIDATOR" "$KERNEL_BASELINE_VALIDATOR_OID" 524288)" ||
    return 1
  if [ "$current" != "$KERNEL_BASELINE_VALIDATOR_STATE" ]; then
    echo "Held committed kernel baseline validator changed after binding." >&2
    return 1
  fi
  current="$(held_release_control_state \
    7 "$KERNEL_TREE_SYMLINK_VALIDATOR" "$KERNEL_TREE_SYMLINK_VALIDATOR_OID" \
    1048576)" || return 1
  if [ "$current" != "$KERNEL_TREE_SYMLINK_VALIDATOR_STATE" ]; then
    echo "Committed kernel tree-symlink validator changed after binding." >&2
    return 1
  fi
}

cleanup_baseline_control_dir() {
  return 0
}

cleanup_private_release_state() {
  if [ "$RELEASE_SOURCE_INDEX_MUTATED" = "true" ] &&
     [ -n "${source_dir:-}" ]; then
    if git -C "$source_dir" read-tree HEAD >/dev/null 2>&1; then
      RELEASE_SOURCE_INDEX_MUTATED="false"
    else
      echo "Warning: could not restore the release source index." >&2
    fi
  fi
  cleanup_baseline_control_dir
  if [ "$KERNEL_TREE_VALIDATOR_SINK_OPEN" = "true" ]; then
    exec 9>&-
    KERNEL_TREE_VALIDATOR_SINK_OPEN="false"
  fi
  if [ "$KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN" = "true" ]; then
    exec 8<&-
    KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="false"
  fi
  if [ "$KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN" = "true" ]; then
    exec 5<&-
    KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
  fi
  KERNEL_TREE_VALIDATOR_PYTHON_IDENTITY=""
  if [ "$KERNEL_TREE_VALIDATOR_HELPER_FD_OPEN" = "true" ]; then
    exec 7<&-
    KERNEL_TREE_VALIDATOR_HELPER_FD_OPEN="false"
  fi
  if [ "$RELEASE_BASELINE_FDS_OPEN" = "true" ]; then
    exec 3<&-
    exec 4<&-
    RELEASE_BASELINE_FDS_OPEN="false"
  fi
}
trap cleanup_private_release_state EXIT

usage() {
  cat <<EOF
Usage: $0 [options]

Builds an Ubuntu qcom-x1e kernel with Surface Pro 11 Wi-Fi rfkill patches.

Default source mode is apt, which derives the source package and version from
the running qcom-x1e kernel packages on the device.

Options:
  --source MODE          Source mode: apt or git, default $SOURCE_MODE.
  --source-package NAME  Source package for apt mode, default $SOURCE_PACKAGE
                         (derive from the running kernel).
  --source-version VER   apt source version: installed, candidate, or exact.
                         Default $SOURCE_VERSION.
  --git-url URL          Kernel git URL for git mode, default $GIT_URL.
  --git-branch BRANCH    Kernel git branch or tag for git mode, default $GIT_BRANCH.
  --expected-source-commit SHA
                        Require git mode to resolve to this exact 40-hex commit
                        before any patches are applied or a build is started.
  --source-date-epoch EPOCH
                        Deterministic source-commit epoch for a release build.
  --kbuild-build-user USER
  --kbuild-build-host HOST
  --kbuild-build-timestamp TIMESTAMP
                        Stable Kbuild identity values for a release build.
  --patch-dir DIR        Patch directory, default repo patches/ubuntu-qcom-x1e-7.0.
  --patch-dirs "DIR1 DIR2 ..."
                        Space-separated list of patch directories. Patches from
                        each directory are applied in order.
  --work-dir DIR         Build work directory, default $WORK_DIR.
  --build-target TARGET  Kernel package target or quoted target list,
                         default $BUILD_TARGET.
  --jobs N              Parallel build jobs, default detected CPU count.
  --min-free-gb N        Required free space in work dir, default $MIN_FREE_GB.
  --install-deps        Install common build dependencies and apt build-deps.
  --install             Install generated qcom-x1e kernel debs after build.
  --install-only        Install existing generated qcom-x1e debs and exit.
  --prepare-only        Clone/download and apply patches, then stop.
  --release-build       Opt in to fail-closed schema-v2 release provenance.
                        Wrapper-only: requires the private read-only /repo
                        snapshot and baseline supplied by the Docker wrapper.
  --reset-source        Remove existing source directory before preparing.
  --skip-clean          Skip debian/rules clean before building.
  --no-fakeroot         Run debian/rules directly when running as root.
  --allow-non-arm64     Allow prepare/build on a non-aarch64 host.
  --allow-no-fallback   Allow install with no older qcom-x1e kernel fallback.
  --touchscreen-modules-dir DIR
                        Directory containing the matching gpi.ko,
                        spi-geni-qcom.ko, and mshw0485_touch.ko. For an
                        sp11v3 install, defaults to the kernel work directory
                        or its touchscreen-modules/ child.
  --skip-touchscreen-modules
                        Allow an sp11v3 kernel-only install. Touch will not
                        work until the matching module bundle is installed.
  -h, --help            Show this help.

The build can take hours and needs substantial free disk space. Keep an older
known-good qcom-x1e kernel installed as a GRUB fallback.
EOF
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{ print $1 }'
  else
    echo "Missing required SHA-256 tool: sha256sum or shasum" >&2
    return 1
  fi
}

file_size() {
  local path="$1" size=""

  if size="$(stat -c '%s' -- "$path" 2>/dev/null)"; then
    printf '%s\n' "$size"
  elif size="$(stat -f '%z' "$path" 2>/dev/null)"; then
    printf '%s\n' "$size"
  else
    echo "Could not determine file size: $path" >&2
    return 1
  fi
}

held_release_control_state() {
  local descriptor="$1" path="$2" object_id="$3" maximum="$4"

  /usr/bin/python3 -I -c '
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1], 10)
path = sys.argv[2]
object_id = sys.argv[3]
maximum = int(sys.argv[4], 10)
if len(object_id) == 40:
    object_digest = hashlib.sha1()
elif len(object_id) == 64:
    object_digest = hashlib.sha256()
else:
    raise SystemExit(1)
before = os.fstat(descriptor)
mapped = os.lstat(path)
if (
    not stat.S_ISREG(before.st_mode)
    or stat.S_ISLNK(mapped.st_mode)
    or (before.st_dev, before.st_ino) != (mapped.st_dev, mapped.st_ino)
    or before.st_size <= 0
    or before.st_size > maximum
):
    raise SystemExit(1)
sha256 = hashlib.sha256()
object_digest.update(("blob " + str(before.st_size) + "\0").encode("ascii"))
offset = 0
while offset < before.st_size:
    chunk = os.pread(descriptor, min(65536, before.st_size - offset), offset)
    if not chunk:
        raise SystemExit(1)
    sha256.update(chunk)
    object_digest.update(chunk)
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
if stable(before) != stable(after) or object_digest.hexdigest() != object_id:
    raise SystemExit(1)
os.lseek(descriptor, 0, os.SEEK_SET)
print(":".join(str(value) for value in (
    before.st_dev,
    before.st_ino,
    before.st_mode,
    before.st_size,
    before.st_mtime_ns,
    before.st_ctime_ns,
    before.st_nlink,
)) + ":" + sha256.hexdigest())
' "$descriptor" "$path" "$object_id" "$maximum" 2>&1
}

resolve_release_publication_fixture_hook() {
  local value="${SP11_KERNEL_RELEASE_PUBLICATION_FIXTURE_HOOK:-}"
  local repo_parent work_parent repo_name work_name

  [ -n "$value" ] || return 0
  [ "$RELEASE_TEST_FIXTURE_CONTEXT" = true ] || return 1
  repo_parent="${repo_dir%/*}"
  work_parent="${work_dir%/*}"
  repo_name="${repo_dir##*/}"
  work_name="${work_dir##*/}"
  [ "$repo_parent" = "$work_parent" ] || return 1
  case "$repo_parent:$repo_name:$work_name" in
    */sp11-apt-fixture.release-provenance.*:support-publication-*:work-publication-*) ;;
    *) return 1 ;;
  esac
  case "$value" in
    swap-work-root-terminal|mutate-fd10-after-primary|mutate-intended-double-term-scrub|inject-fifo-before-open|inject-symlink-before-open|inject-procfd-candidate-mismatch)
      printf '%s\n' "$value"
      ;;
    *) return 1 ;;
  esac
}

held_release_output_state() {
  local work_path="$1" work_identity="$2" seal="$3"
  local deb_fingerprint="$4" manifest_fingerprint="$5" fixture_hook="$6"

  "$KERNEL_TREE_VALIDATOR_PYTHON" -I -c '
import hashlib
import os
import stat
import sys

work_path, expected_work_identity, seal = sys.argv[1:4]
expected_fingerprints = sys.argv[4:6]
fixture_hook = sys.argv[6]
if fixture_hook not in (
    "",
    "swap-work-root-terminal",
    "mutate-fd10-after-primary",
    "mutate-intended-double-term-scrub",
):
    raise SystemExit(1)
held_root = os.fstat(6)
actual_work_identity = ":".join(str(value) for value in (
    held_root.st_dev,
    held_root.st_ino,
    format(stat.S_IMODE(held_root.st_mode), "o"),
    held_root.st_uid,
    held_root.st_gid,
))

def stable_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
    )

held_root_identity = stable_identity(held_root)
outputs = (
    (10, "sp11-kernel-debs.txt", 1024 * 1024),
    (11, "sp11-kernel-build-manifest.txt", 4 * 1024 * 1024),
)

def verify_root_mapping():
    current = os.fstat(6)
    mapped = os.lstat(work_path)
    if (
        not stat.S_ISDIR(current.st_mode)
        or stat.S_ISLNK(mapped.st_mode)
        or stable_identity(current) != held_root_identity
        or (current.st_dev, current.st_ino) != (mapped.st_dev, mapped.st_ino)
        or actual_work_identity != expected_work_identity
    ):
        raise SystemExit(1)

def open_reader(descriptor, name):
    if sys.platform.startswith("linux"):
        return os.open(
            "/proc/self/fd/" + str(descriptor),
            os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC,
        )
    if (
        sys.platform == "darwin"
        and os.environ.get("SP11_KERNEL_RELEASE_TEST_FIXTURE")
        == "sp11-kernel-release-provenance-v1"
        and "sp11-apt-fixture.release-provenance." in work_path
    ):
        # Darwin cannot reopen a write-only /dev/fd descriptor read-only. This
        # name read is restricted to the disposable fixture-owned tree;
        # production publication is Linux and uses only the exact held FD.
        return os.open(
            name,
            os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=6,
        )
    raise SystemExit(1)

parsed_fingerprints = []
for value in expected_fingerprints:
    fields = value.split("\t")
    if (
        len(fields) != 2
        or not fields[0].isdigit()
        or len(fields[1]) != 64
        or any(character not in "0123456789abcdef" for character in fields[1])
    ):
        raise SystemExit(1)
    parsed_fingerprints.append((int(fields[0], 10), fields[1]))

if seal == "true" and fixture_hook == "mutate-intended-double-term-scrub":
    if os.pwrite(10, b"\0", 0) != 1:
        raise SystemExit(1)
    os.fsync(10)

def hash_held_output(output, expected, required_identity=None):
    descriptor, name, maximum = output
    expected_size, expected_digest = expected
    before = os.fstat(descriptor)
    if required_identity is not None and stable_identity(before) != required_identity:
        raise SystemExit(1)
    reader = open_reader(descriptor, name)
    try:
        mapped = os.stat(name, dir_fd=6, follow_symlinks=False)
        reader_metadata = os.fstat(reader)
        if (
            not stat.S_ISREG(before.st_mode)
            or not stat.S_ISREG(reader_metadata.st_mode)
            or stat.S_ISLNK(mapped.st_mode)
            or (before.st_dev, before.st_ino)
            != (mapped.st_dev, mapped.st_ino)
            or (before.st_dev, before.st_ino)
            != (reader_metadata.st_dev, reader_metadata.st_ino)
            or stat.S_IMODE(before.st_mode) != 0o644
            or before.st_size <= 0
            or before.st_size > maximum
            or before.st_size != expected_size
            or before.st_nlink != 1
        ):
            raise SystemExit(1)
        digest = hashlib.sha256()
        offset = 0
        while offset < before.st_size:
            chunk = os.pread(reader, min(65536, before.st_size - offset), offset)
            if not chunk:
                raise SystemExit(1)
            digest.update(chunk)
            offset += len(chunk)
    finally:
        os.close(reader)
    after = os.fstat(descriptor)
    remapped = os.stat(name, dir_fd=6, follow_symlinks=False)
    if (
        stable_identity(before) != stable_identity(after)
        or (after.st_dev, after.st_ino) != (remapped.st_dev, remapped.st_ino)
        or digest.hexdigest() != expected_digest
    ):
        raise SystemExit(1)
    return stable_identity(after), digest.hexdigest()

verify_root_mapping()
states = []
primary_identities = []
for index, output in enumerate(outputs):
    descriptor = output[0]
    if seal == "true":
        os.fchmod(descriptor, 0o644)
    os.fsync(descriptor)
    identity, digest = hash_held_output(output, parsed_fingerprints[index])
    primary_identities.append(identity)
    states.append(":".join(str(value) for value in identity) + ":" + digest)
    if (
        seal == "true"
        and index == 0
        and fixture_hook == "mutate-fd10-after-primary"
    ):
        if os.pwrite(10, b"\0", 0) != 1:
            raise SystemExit(1)
        os.fsync(10)
try:
    os.fsync(6)
except OSError:
    if sys.platform != "darwin":
        raise

# Cross-check both intended byte streams only after the first pass has
# completed for both files.  This prevents a stable mutation or name rebind of
# the first output while the second output is being hashed from escaping the
# per-file checks above.
verify_root_mapping()
for index, output in enumerate(outputs):
    hash_held_output(
        output,
        parsed_fingerprints[index],
        primary_identities[index],
    )

# Finish with a collective descriptor/name/root mapping pass after every byte
# read.  Names are observation-only; all byte reads above use the held inode on
# Linux.  Concurrent mutation after this bounded terminal check remains part of
# the declared trusted controller envelope.
verify_root_mapping()
for index, (descriptor, name, _maximum) in enumerate(outputs):
    metadata = os.fstat(descriptor)
    mapped = os.stat(name, dir_fd=6, follow_symlinks=False)
    if (
        stable_identity(metadata) != primary_identities[index]
        or stat.S_ISLNK(mapped.st_mode)
        or (metadata.st_dev, metadata.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        raise SystemExit(1)
if seal == "true" and fixture_hook == "swap-work-root-terminal":
    held_path = work_path + ".publication-held"
    victim_path = work_path + ".publication-victim"
    if os.path.lexists(held_path):
        raise SystemExit(1)
    victim = os.lstat(victim_path)
    if stat.S_ISLNK(victim.st_mode) or not stat.S_ISDIR(victim.st_mode):
        raise SystemExit(1)
    os.rename(work_path, held_path)
    os.rename(victim_path, work_path)
verify_root_mapping()
print("\n".join(states))
' "$work_path" "$work_identity" "$seal" \
  "$deb_fingerprint" "$manifest_fingerprint" "$fixture_hook" 2>&9
}

scrub_held_release_outputs() {
  "$KERNEL_TREE_VALIDATOR_PYTHON" -I -c '
import os
import signal
import stat
import sys

status = 0
for descriptor, enabled in ((10, sys.argv[1]), (11, sys.argv[2])):
    if enabled != "true":
        continue
    try:
        os.ftruncate(descriptor, 0)
        os.fsync(descriptor)
    except OSError:
        status = 1
    if (
        descriptor == 10
        and sys.argv[3] == "mutate-intended-double-term-scrub"
    ):
        os.kill(os.getppid(), signal.SIGTERM)
        os.kill(os.getppid(), signal.SIGTERM)
if sys.argv[3] == "mutate-intended-double-term-scrub":
    try:
        flags = os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC
        marker = os.open(
            ".sp11-publication-scrub-marker", flags, dir_fd=6
        )
        try:
            metadata = os.fstat(marker)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_nlink != 1
            ):
                raise OSError("unsafe fixture marker")
            os.ftruncate(marker, 0)
            if os.write(marker, b"double-term-survived\n") != 21:
                raise OSError("short fixture marker write")
            os.fsync(marker)
        finally:
            os.close(marker)
    except OSError:
        status = 1
raise SystemExit(status)
' "$1" "$2" "$3" 1>&9 2>&9
}

support_git() {
  GIT_OPTIONAL_LOCKS=0 git \
    -c "safe.directory=$repo_dir" \
    -c core.fsmonitor=false \
    -c core.untrackedCache=false \
    -C "$repo_dir" "$@"
}

committed_support_blob_oid() {
  local commit="$1" relative_path="$2" expected_mode="$3"
  local entry metadata listed_path mode object_type object_id remainder

  if ! entry="$(support_git ls-tree "$commit" -- "$relative_path")"; then
    return 1
  fi
  IFS=$'\t' read -r metadata listed_path remainder <<< "$entry"
  read -r mode object_type object_id remainder <<< "$metadata"
  [ -z "$remainder" ] && [ "$listed_path" = "$relative_path" ] &&
    [ "$mode" = "$expected_mode" ] && [ "$object_type" = blob ] &&
    [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf '%s\n' "$object_id"
}

verify_committed_support_file() {
  local relative_path="$1" expected_mode="$2" path="$3"
  local entry metadata listed_path mode object_type object_id remainder

  if ! entry="$(support_git ls-tree "$SUPPORT_HEAD_START" -- "$relative_path")"; then
    echo "Could not resolve committed support input: $relative_path" >&2
    return 1
  fi
  IFS=$'\t' read -r metadata listed_path remainder <<< "$entry"
  read -r mode object_type object_id remainder <<< "$metadata"
  if [ -n "$remainder" ] || [ "$listed_path" != "$relative_path" ] ||
     [ "$mode" != "$expected_mode" ] || [ "$object_type" != "blob" ] ||
     ! [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    echo "Committed support input has an unexpected Git tree identity: $relative_path" >&2
    return 1
  fi
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    echo "Committed support input is not a regular non-symlinked file: $relative_path" >&2
    return 1
  fi
  printf '%s\n' "$object_id"
}

create_release_baseline_control() {
  BASELINE_CONTROL_PARENT="$(cd /tmp && pwd -P)"
  KERNEL_BASELINE="$repo_dir/$KERNEL_BASELINE_REL"
  KERNEL_BASELINE_VALIDATOR="$repo_dir/$KERNEL_BASELINE_VALIDATOR_REL"
  KERNEL_TREE_SYMLINK_VALIDATOR="$repo_dir/$KERNEL_TREE_SYMLINK_VALIDATOR_REL"
  if [ "${SP11_RELEASE_CONTROL_FDS_BOUND:-}" != \
       "sp11-release-control-fds-v1" ]; then
    echo "Release controller inputs were not bound by the trusted launcher." >&2
    exit 1
  fi
  KERNEL_BASELINE_OID="$(
    verify_committed_support_file "$KERNEL_BASELINE_REL" 100644 "$KERNEL_BASELINE"
  )"
  KERNEL_BASELINE_VALIDATOR_OID="$(
    verify_committed_support_file \
      "$KERNEL_BASELINE_VALIDATOR_REL" 100755 "$KERNEL_BASELINE_VALIDATOR"
  )"
  KERNEL_TREE_SYMLINK_VALIDATOR_OID="$(
    verify_committed_support_file \
      "$KERNEL_TREE_SYMLINK_VALIDATOR_REL" 100755 "$KERNEL_TREE_SYMLINK_VALIDATOR"
  )"
  if ! KERNEL_BASELINE_STATE="$(held_release_control_state \
    3 "$KERNEL_BASELINE" "$KERNEL_BASELINE_OID" 524288)"; then
    echo "Held release baseline authority is invalid." >&2
    exit 1
  fi
  if ! KERNEL_BASELINE_VALIDATOR_STATE="$(held_release_control_state \
    4 "$KERNEL_BASELINE_VALIDATOR" "$KERNEL_BASELINE_VALIDATOR_OID" \
      524288)"; then
    echo "Held release baseline validator authority is invalid." >&2
    exit 1
  fi
  if ! KERNEL_TREE_SYMLINK_VALIDATOR_STATE="$(
    held_release_control_state 7 "$KERNEL_TREE_SYMLINK_VALIDATOR" \
      "$KERNEL_TREE_SYMLINK_VALIDATOR_OID" 1048576
  )"; then
    echo "Held release tree validator authority is invalid." >&2
    exit 1
  fi
  RELEASE_BASELINE_FDS_OPEN="true"
  KERNEL_TREE_VALIDATOR_HELPER_FD_OPEN="true"
  verify_kernel_baseline_control_state || exit 1
}

load_release_baseline_values() {
  local emitted key value remainder emitted_keys="" expected_keys
  local validator_fd_path

  verify_kernel_baseline_control_state || exit 1
  case "$(uname -s)" in
    Linux)
      validator_fd_path=/proc/self/fd/4
      ;;
    Darwin)
      validator_fd_path=/dev/fd/4
      ;;
    *)
      echo "Held baseline validation requires Linux or the Darwin fixture boundary." >&2
      exit 1
      ;;
  esac
  if ! emitted="$(
    /bin/bash "$validator_fd_path" \
      --repo-dir "$repo_dir" \
      --emit-release-values \
      --baseline-fd 3
  )"; then
    echo "Committed release kernel baseline validation failed." >&2
    exit 1
  fi
  while IFS=$'\t' read -r key value remainder; do
    [ -n "$key" ] && [ -n "$value" ] && [ -z "$remainder" ] || {
      echo "Committed kernel baseline validator emitted malformed data." >&2
      exit 1
    }
    emitted_keys="${emitted_keys}${emitted_keys:+$'\n'}$key"
    case "$key" in
      SP11_KERNEL_BASELINE_ID) BASELINE_ID="$value" ;;
      SP11_KERNEL_DOCKER_IMAGE) BASELINE_DOCKER_IMAGE="$value" ;;
      SP11_KERNEL_DOCKER_PLATFORM) BASELINE_DOCKER_PLATFORM="$value" ;;
      SP11_KERNEL_DOCKER_PLATFORM_MANIFEST) BASELINE_DOCKER_PLATFORM_MANIFEST="$value" ;;
      SP11_KERNEL_UPSTREAM_URL) BASELINE_UPSTREAM_URL="$value" ;;
      SP11_KERNEL_UPSTREAM_REF) BASELINE_UPSTREAM_REF="$value" ;;
      SP11_KERNEL_UPSTREAM_COMMIT) BASELINE_UPSTREAM_COMMIT="$value" ;;
      SP11_KERNEL_SOURCE_DATE_EPOCH) BASELINE_SOURCE_DATE_EPOCH="$value" ;;
      SP11_KERNEL_KBUILD_BUILD_USER) BASELINE_KBUILD_BUILD_USER="$value" ;;
      SP11_KERNEL_KBUILD_BUILD_HOST) BASELINE_KBUILD_BUILD_HOST="$value" ;;
      SP11_KERNEL_KBUILD_BUILD_TIMESTAMP) BASELINE_KBUILD_BUILD_TIMESTAMP="$value" ;;
      SP11_KERNEL_BUILD_TARGET) BASELINE_BUILD_TARGET="$value" ;;
      SP11_KERNEL_PATCH_DIRS) BASELINE_PATCH_DIRS="$value" ;;
      *)
        echo "Committed kernel baseline validator emitted an unexpected key: $key" >&2
        exit 1
        ;;
    esac
  done <<< "$emitted"
  expected_keys=$'SP11_KERNEL_BASELINE_ID\nSP11_KERNEL_DOCKER_IMAGE\nSP11_KERNEL_DOCKER_PLATFORM\nSP11_KERNEL_DOCKER_PLATFORM_MANIFEST\nSP11_KERNEL_UPSTREAM_URL\nSP11_KERNEL_UPSTREAM_REF\nSP11_KERNEL_UPSTREAM_COMMIT\nSP11_KERNEL_SOURCE_DATE_EPOCH\nSP11_KERNEL_KBUILD_BUILD_USER\nSP11_KERNEL_KBUILD_BUILD_HOST\nSP11_KERNEL_KBUILD_BUILD_TIMESTAMP\nSP11_KERNEL_BUILD_TARGET\nSP11_KERNEL_PATCH_DIRS'
  if [ "$emitted_keys" != "$expected_keys" ]; then
    echo "Committed kernel baseline validator field set/order is not exact." >&2
    exit 1
  fi
  verify_kernel_baseline_control_state || exit 1
}

normalized_release_patch_dirs() {
  local patch_dir_list pd canonical_dir repo_real relative_dir normalized=""

  repo_real="$(cd "$repo_dir" && pwd -P)"
  if [ -n "$PATCH_DIRS" ]; then
    patch_dir_list="$PATCH_DIRS"
  elif [ -n "$PATCH_DIR" ]; then
    patch_dir_list="$PATCH_DIR"
  else
    patch_dir_list="$repo_dir/patches/ubuntu-qcom-x1e-7.0"
  fi
  for pd in $patch_dir_list; do
    if [ ! -d "$pd" ] || [ -L "$pd" ]; then
      echo "Release patch directory is missing or symlinked: $pd" >&2
      return 1
    fi
    canonical_dir="$(cd "$pd" && pwd -P)"
    case "$canonical_dir" in
      "$repo_real"/*) relative_dir="${canonical_dir#"$repo_real"/}" ;;
      *)
        echo "Release patches must resolve inside the support repository: $pd" >&2
        return 1
        ;;
    esac
    case "/$relative_dir/" in
      */../*|*/./*|*//*|*$'\n'*|*$'\r'*|*$'\t'*)
        echo "Release patch directory is not canonical: $pd" >&2
        return 1
        ;;
    esac
    normalized="${normalized}${normalized:+ }$relative_dir"
  done
  [ -n "$normalized" ] || return 1
  printf '%s\n' "$normalized"
}

support_dirty_value() {
  local status_output

  if ! status_output="$(support_git status --porcelain --untracked-files=all)"; then
    echo "Could not inspect the support repository worktree state." >&2
    return 1
  fi
  if [ -n "$status_output" ]; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
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

require_release_build_contract() {
  local container_image container_platform support_dirty

  [ "$RELEASE_BUILD" = "true" ] || return 0

  if [ "$SOURCE_MODE" != "git" ]; then
    echo "--release-build requires --source git." >&2
    exit 2
  fi
  if [ -z "$EXPECTED_SOURCE_COMMIT" ]; then
    echo "--release-build requires --expected-source-commit with an exact commit." >&2
    exit 2
  fi
  if [ -z "$SOURCE_DATE_EPOCH" ] || [ -z "$KBUILD_BUILD_USER" ] ||
     [ -z "$KBUILD_BUILD_HOST" ] || [ -z "$KBUILD_BUILD_TIMESTAMP" ]; then
    echo "--release-build requires the complete deterministic build-identity argument set." >&2
    exit 2
  fi
  if ! public_https_url "$GIT_URL"; then
    echo "--release-build requires a public HTTPS kernel source URL without credentials, query, or fragment." >&2
    exit 2
  fi
  if ! [[ "$GIT_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
     ! git check-ref-format "refs/heads/$GIT_BRANCH" >/dev/null 2>&1; then
    echo "--release-build requires a safe full kernel source ref name." >&2
    exit 2
  fi
  if [ "$PREPARE_ONLY" = "true" ] || [ "$INSTALL_ONLY" = "true" ]; then
    echo "--release-build requires a complete package build, not prepare/install-only mode." >&2
    exit 2
  fi
  if [ "$INSTALL_DEBS" = "true" ]; then
    echo "--release-build creates packages only and cannot be combined with --install." >&2
    exit 2
  fi
  if [ "$SKIP_CLEAN" = "true" ]; then
    echo "--release-build cannot be combined with --skip-clean." >&2
    exit 2
  fi
  if [ "$BUILD_TARGET" != "binary-indep binary-qcom-x1e" ]; then
    echo "--release-build requires --build-target \"binary-indep binary-qcom-x1e\"." >&2
    exit 2
  fi

  container_image="${SP11_BUILD_CONTAINER_IMAGE:-}"
  container_platform="${SP11_BUILD_CONTAINER_PLATFORM:-}"
  if ! [[ "$container_image" =~ ^[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}$ ]]; then
    echo "--release-build requires SP11_BUILD_CONTAINER_IMAGE to use an exact @sha256 digest." >&2
    exit 2
  fi
  case "$container_platform" in
    linux/arm64|linux/arm64/v8) ;;
    *)
      echo "--release-build requires SP11_BUILD_CONTAINER_PLATFORM to be linux/arm64 or linux/arm64/v8." >&2
      exit 2
      ;;
  esac

  bind_release_control_fds_and_reexec

  if ! support_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "--release-build requires the support scripts to come from a Git worktree." >&2
    exit 1
  fi
  SUPPORT_HEAD_START="$(support_git rev-parse --verify 'HEAD^{commit}')"
  if ! [[ "$SUPPORT_HEAD_START" =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]]; then
    echo "Could not resolve an exact support repository commit for --release-build." >&2
    exit 1
  fi
  SUPPORT_HEAD_START="$(printf '%s' "$SUPPORT_HEAD_START" | tr '[:upper:]' '[:lower:]')"
  if [ -n "${SP11_EXPECTED_SUPPORT_COMMIT:-}" ] &&
     [ "$SUPPORT_HEAD_START" != "${SP11_EXPECTED_SUPPORT_COMMIT}" ]; then
    echo "Mounted support repository HEAD does not match the Docker release preflight." >&2
    echo "Expected: ${SP11_EXPECTED_SUPPORT_COMMIT}" >&2
    echo "Mounted:  $SUPPORT_HEAD_START" >&2
    exit 1
  fi
  if ! support_dirty="$(support_dirty_value)"; then
    exit 1
  fi
  if [ "$support_dirty" != "false" ]; then
    echo "--release-build requires a clean support repository at start." >&2
    exit 1
  fi

  require_release_build_identity_baseline
}

require_release_build_identity_baseline() {
  local normalized_patch_dirs

  [ "$RELEASE_BUILD" = "true" ] || return 0
  create_release_baseline_control
  load_release_baseline_values
  require_wrapper_release_context

  if [ "$SOURCE_DATE_EPOCH" != "$BASELINE_SOURCE_DATE_EPOCH" ] ||
     [ "$KBUILD_BUILD_USER" != "$BASELINE_KBUILD_BUILD_USER" ] ||
     [ "$KBUILD_BUILD_HOST" != "$BASELINE_KBUILD_BUILD_HOST" ] ||
     [ "$KBUILD_BUILD_TIMESTAMP" != "$BASELINE_KBUILD_BUILD_TIMESTAMP" ]; then
    echo "Release build identity arguments do not match the trusted kernel baseline." >&2
    exit 2
  fi
  if [ "$GIT_URL" != "$BASELINE_UPSTREAM_URL" ] ||
     [ "$GIT_BRANCH" != "$BASELINE_UPSTREAM_REF" ] ||
     [ "$EXPECTED_SOURCE_COMMIT" != "$BASELINE_UPSTREAM_COMMIT" ]; then
    echo "Release build source arguments do not match the trusted kernel baseline." >&2
    exit 2
  fi
  if [ "${SP11_BUILD_CONTAINER_IMAGE:-}" != "$BASELINE_DOCKER_IMAGE" ] ||
     [ "${SP11_BUILD_CONTAINER_PLATFORM:-}" != "$BASELINE_DOCKER_PLATFORM" ]; then
    echo "Release build container identity does not match the trusted kernel baseline." >&2
    exit 2
  fi
  if [ "$BUILD_TARGET" != "$BASELINE_BUILD_TARGET" ]; then
    echo "Release build target does not match the trusted kernel baseline." >&2
    exit 2
  fi
  if ! normalized_patch_dirs="$(normalized_release_patch_dirs)" ||
     [ "$normalized_patch_dirs" != "$BASELINE_PATCH_DIRS" ]; then
    echo "Release build patch directories do not match the trusted kernel baseline." >&2
    exit 2
  fi
}

require_wrapper_release_context() {
  local fixture_context="false"
  local release_control_expected release_control_path release_control_variable

  if [ "${SP11_KERNEL_RELEASE_TEST_FIXTURE:-}" = \
       "sp11-kernel-release-provenance-v1" ] &&
     [ "$BASELINE_ID" = "fixture" ] &&
     [ "$BASELINE_UPSTREAM_URL" = "https://github.com/example/linux.git" ] &&
     [ "$BASELINE_UPSTREAM_REF" = "fixture" ] &&
    [ "$BASELINE_DOCKER_PLATFORM" = "linux/arm64/v8" ]; then
    case "$repo_dir" in
      */sp11-apt-fixture.release-provenance.*/support-*)
        fixture_context="true"
        RELEASE_TEST_FIXTURE_CONTEXT="true"
        ;;
    esac
  fi
  [ "$fixture_context" = "true" ] && return 0

  if [ "$repo_dir" != "/repo" ] ||
     [ "${SP11_PRIVATE_SUPPORT_SNAPSHOT:-}" != "true" ] ||
     [ -z "${SP11_EXPECTED_SUPPORT_COMMIT:-}" ] ||
     [ "$SP11_EXPECTED_SUPPORT_COMMIT" != "$SUPPORT_HEAD_START" ]; then
    echo "--release-build is wrapper-only and requires its exact private /repo support snapshot." >&2
    exit 1
  fi
  if [ ! -r /proc/self/mountinfo ] || [ -L /proc/self/mountinfo ] ||
     [ ! -d /sp11-control ] || [ -L /sp11-control ] ||
     [ ! -f /sp11-control/kernel-baseline.env ] ||
     [ -L /sp11-control/kernel-baseline.env ] ||
     [ ! -f /sp11-control/docker-build-args.txt ] ||
     [ -L /sp11-control/docker-build-args.txt ] ||
     [ ! -f /sp11-control/docker-build-inside.sh ] ||
     [ -L /sp11-control/docker-build-inside.sh ] ||
     [ ! -f /sp11-control/sp11-oci-index.json ] ||
     [ -L /sp11-control/sp11-oci-index.json ]; then
    echo "--release-build could not verify its private read-only support mounts." >&2
    exit 1
  fi
  if ! awk '
    function has_ro(options, count, item) {
      count = split(options, item, ",")
      for (slot = 1; slot <= count; slot++) {
        if (item[slot] == "ro") return 1
      }
      return 0
    }
    $5 == "/repo" {
      repo_count++
      if (has_ro($6)) repo_ro++
      next
    }
    index($5, "/repo/") == 1 { repo_nested++ }
    $5 == "/sp11-control" {
      control_count++
      if (has_ro($6)) control_ro++
      next
    }
    index($5, "/sp11-control/") == 1 { control_nested++ }
    END {
      exit !(repo_count == 1 && repo_ro == 1 && repo_nested == 0 &&
             control_count == 1 && control_ro == 1 && control_nested == 0)
    }
  ' /proc/self/mountinfo; then
    echo "--release-build requires unshadowed read-only /repo and /sp11-control mounts." >&2
    exit 1
  fi
  for release_control_variable in \
    SP11_EXPECTED_BUILD_ARGS_SHA256 \
    SP11_EXPECTED_ENTRYPOINT_SHA256 \
    SP11_EXPECTED_OCI_INDEX_SHA256 \
    SP11_EXPECTED_BASELINE_SHA256; do
    case "$release_control_variable" in
      SP11_EXPECTED_BUILD_ARGS_SHA256)
        release_control_expected="${SP11_EXPECTED_BUILD_ARGS_SHA256:-}"
        release_control_path=/sp11-control/docker-build-args.txt
        ;;
      SP11_EXPECTED_ENTRYPOINT_SHA256)
        release_control_expected="${SP11_EXPECTED_ENTRYPOINT_SHA256:-}"
        release_control_path=/sp11-control/docker-build-inside.sh
        ;;
      SP11_EXPECTED_OCI_INDEX_SHA256)
        release_control_expected="${SP11_EXPECTED_OCI_INDEX_SHA256:-}"
        release_control_path=/sp11-control/sp11-oci-index.json
        ;;
      SP11_EXPECTED_BASELINE_SHA256)
        release_control_expected="${SP11_EXPECTED_BASELINE_SHA256:-}"
        release_control_path=/sp11-control/kernel-baseline.env
        ;;
    esac
    if ! [[ "$release_control_expected" =~ ^[0-9a-f]{64}$ ]] ||
       [ "$(sha256_file "$release_control_path")" != "$release_control_expected" ]; then
      echo "--release-build private control digest mismatch: $release_control_variable" >&2
      exit 1
    fi
  done
  if [ "$(sha256_file /sp11-control/kernel-baseline.env)" != \
       "$(sha256_file "$KERNEL_BASELINE")" ]; then
    echo "--release-build mounted baseline differs from its exact support baseline." >&2
    exit 1
  fi
}

verify_release_support_stable() {
  local support_head_end support_dirty_end

  [ "$RELEASE_BUILD" = "true" ] || return 0

  support_head_end="$(support_git rev-parse --verify 'HEAD^{commit}')"
  support_head_end="$(printf '%s' "$support_head_end" | tr '[:upper:]' '[:lower:]')"
  if ! support_dirty_end="$(support_dirty_value)"; then
    return 1
  fi
  if [ "$support_head_end" != "$SUPPORT_HEAD_START" ] || [ "$support_dirty_end" != "false" ]; then
    echo "Support repository changed during the release build; refusing provenance completion." >&2
    echo "Start HEAD: $SUPPORT_HEAD_START" >&2
    echo "End HEAD:   $support_head_end" >&2
    echo "End dirty:  $support_dirty_end" >&2
    return 1
  fi
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    require_tool sudo
    sudo "$@"
  fi
}

as_root_with_build_identity() {
  if [ -z "$SOURCE_DATE_EPOCH" ]; then
    as_root "$@"
  elif [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    require_tool sudo
    sudo \
      --preserve-env=SOURCE_DATE_EPOCH,KBUILD_BUILD_USER,KBUILD_BUILD_HOST,KBUILD_BUILD_TIMESTAMP \
      -- "$@"
  fi
}

run_rules() {
  local rules_file="$1"
  shift

  if [ "$(id -u)" -eq 0 ]; then
    "$rules_file" "$@"
    return
  fi

  if [ "$NO_FAKEROOT" = "true" ]; then
    echo "--no-fakeroot requires running as root." >&2
    exit 1
  fi

  fakeroot "$rules_file" "$@"
}

if [ "${SP11_RELEASE_CONTROL_FDS_BOUND:-}" = \
     "sp11-release-control-fds-v1" ]; then
  repo_dir="${SP11_RELEASE_REPO_DIR:-}"
  [ -n "$repo_dir" ] && [ -d "$repo_dir" ] && [ ! -L "$repo_dir" ] &&
    [ "$(cd "$repo_dir" && pwd -P)" = "$repo_dir" ] || {
      echo "Bound release support repository path is invalid." >&2
      exit 1
    }
else
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE_MODE="$2"
      shift 2
      ;;
    --source-package)
      SOURCE_PACKAGE="$2"
      shift 2
      ;;
    --source-version)
      SOURCE_VERSION="$2"
      shift 2
      ;;
    --git-url)
      GIT_URL="$2"
      shift 2
      ;;
    --git-branch)
      GIT_BRANCH="$2"
      shift 2
      ;;
    --expected-source-commit)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1." >&2
        usage >&2
        exit 2
      fi
      EXPECTED_SOURCE_COMMIT="$2"
      shift 2
      ;;
    --source-date-epoch)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1." >&2
        usage >&2
        exit 2
      fi
      SOURCE_DATE_EPOCH="$2"
      shift 2
      ;;
    --kbuild-build-user)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1." >&2
        usage >&2
        exit 2
      fi
      KBUILD_BUILD_USER="$2"
      shift 2
      ;;
    --kbuild-build-host)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1." >&2
        usage >&2
        exit 2
      fi
      KBUILD_BUILD_HOST="$2"
      shift 2
      ;;
    --kbuild-build-timestamp)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1." >&2
        usage >&2
        exit 2
      fi
      KBUILD_BUILD_TIMESTAMP="$2"
      shift 2
      ;;
    --patch-dir)
      PATCH_DIR="$2"
      shift 2
      ;;
    --patch-dirs)
      PATCH_DIRS="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --build-target)
      BUILD_TARGET="$2"
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --min-free-gb)
      MIN_FREE_GB="$2"
      shift 2
      ;;
    --install-deps)
      INSTALL_DEPS="true"
      shift
      ;;
    --install)
      INSTALL_DEBS="true"
      shift
      ;;
    --install-only)
      INSTALL_ONLY="true"
      shift
      ;;
    --prepare-only)
      PREPARE_ONLY="true"
      shift
      ;;
    --release-build)
      RELEASE_BUILD="true"
      shift
      ;;
    --reset-source)
      RESET_SOURCE="true"
      shift
      ;;
    --skip-clean)
      SKIP_CLEAN="true"
      shift
      ;;
    --no-fakeroot)
      NO_FAKEROOT="true"
      shift
      ;;
    --allow-non-arm64)
      ALLOW_NON_ARM64="true"
      shift
      ;;
    --allow-no-fallback)
      ALLOW_NO_FALLBACK="true"
      shift
      ;;
    --touchscreen-modules-dir)
      if [ -z "${2:-}" ]; then
        echo "Missing value for $1." >&2
        usage >&2
        exit 2
      fi
      TOUCHSCREEN_MODULES_DIR="$2"
      shift 2
      ;;
    --skip-touchscreen-modules)
      SKIP_TOUCHSCREEN_MODULES="true"
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

if [ "$SKIP_TOUCHSCREEN_MODULES" = "true" ] && [ -n "$TOUCHSCREEN_MODULES_DIR" ]; then
  echo "--skip-touchscreen-modules cannot be combined with --touchscreen-modules-dir." >&2
  exit 2
fi

case "$SOURCE_MODE" in
  apt|git)
    ;;
  *)
    echo "Invalid --source: $SOURCE_MODE (expected apt or git)" >&2
    exit 2
    ;;
esac

if [ -n "$EXPECTED_SOURCE_COMMIT" ]; then
  if [ "$SOURCE_MODE" != "git" ]; then
    echo "--expected-source-commit requires --source git." >&2
    exit 2
  fi
  if ! [[ "$EXPECTED_SOURCE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "--expected-source-commit must be an exact 40-hex commit." >&2
    exit 2
  fi
  EXPECTED_SOURCE_COMMIT="$(printf '%s' "$EXPECTED_SOURCE_COMMIT" | tr '[:upper:]' '[:lower:]')"
fi

identity_value_count=0
for identity_value in \
  "$SOURCE_DATE_EPOCH" \
  "$KBUILD_BUILD_USER" \
  "$KBUILD_BUILD_HOST" \
  "$KBUILD_BUILD_TIMESTAMP"; do
  [ -z "$identity_value" ] || identity_value_count=$((identity_value_count + 1))
done
if [ "$identity_value_count" -ne 0 ] && [ "$identity_value_count" -ne 4 ]; then
  echo "Deterministic build identity must provide all four identity arguments together." >&2
  exit 2
fi
if [ "$identity_value_count" -ne 0 ]; then
  if [ "$SOURCE_MODE" != "git" ] || [ -z "$EXPECTED_SOURCE_COMMIT" ]; then
    echo "Deterministic build identity requires Git source and --expected-source-commit." >&2
    exit 2
  fi
  if ! [[ "$SOURCE_DATE_EPOCH" =~ ^[1-9][0-9]{0,9}$ ]] ||
     [ "$SOURCE_DATE_EPOCH" -gt 4102444799 ]; then
    echo "--source-date-epoch must be a canonical Unix epoch earlier than 2100-01-01 UTC." >&2
    exit 2
  fi
  if ! [[ "$KBUILD_BUILD_USER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo "--kbuild-build-user must be a bounded portable identity." >&2
    exit 2
  fi
  if ! [[ "$KBUILD_BUILD_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo "--kbuild-build-host must be a bounded portable identity." >&2
    exit 2
  fi
  if ! [[ "$KBUILD_BUILD_TIMESTAMP" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[[:space:]](Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[[:space:]]([[:space:]][1-9]|[12][0-9]|3[01])[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]UTC[[:space:]][0-9]{4}$ ]]; then
    echo "--kbuild-build-timestamp must use the canonical bounded Kbuild UTC form." >&2
    exit 2
  fi
fi

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [ "$JOBS" -lt 1 ]; then
  echo "--jobs must be a positive integer." >&2
  exit 2
fi

if ! [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || [ "$MIN_FREE_GB" -lt 1 ]; then
  echo "--min-free-gb must be a positive integer." >&2
  exit 2
fi

bind_release_control_fds_and_reexec() {
  [ "$RELEASE_BUILD" = "true" ] || return 0
  [ "${SP11_RELEASE_CONTROL_FDS_BOUND:-}" != \
    "sp11-release-control-fds-v1" ] || return 0

  builder_script="$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh"
  launcher_commit="${SP11_EXPECTED_SUPPORT_COMMIT:-}"
  if [ -z "$launcher_commit" ] && [ "$repo_dir" != /repo ]; then
    launcher_commit="$(support_git rev-parse --verify 'HEAD^{commit}')"
  fi
  if ! [[ "$launcher_commit" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] ||
     ! launcher_builder_oid="$(committed_support_blob_oid \
       "$launcher_commit" scripts/build-sp11-qcom-x1e-kernel.sh 100755)" ||
     ! launcher_baseline_oid="$(committed_support_blob_oid \
       "$launcher_commit" "$KERNEL_BASELINE_REL" 100644)" ||
     ! launcher_baseline_validator_oid="$(committed_support_blob_oid \
       "$launcher_commit" "$KERNEL_BASELINE_VALIDATOR_REL" 100755)" ||
     ! launcher_tree_validator_oid="$(committed_support_blob_oid \
       "$launcher_commit" "$KERNEL_TREE_SYMLINK_VALIDATOR_REL" 100755)"; then
    echo "Could not resolve exact committed release controller objects." >&2
    exit 1
  fi
  exec /usr/bin/python3 -I -c '
import hashlib
import os
import stat
import sys

items = (
    (sys.argv[1], sys.argv[2], 5, 1024 * 1024),
    (sys.argv[3], sys.argv[4], 3, 512 * 1024),
    (sys.argv[5], sys.argv[6], 4, 512 * 1024),
    (sys.argv[7], sys.argv[8], 7, 1024 * 1024),
)
script = items[0][0]
arguments = sys.argv[9:]
flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
opened = []
try:
    for path, object_id, target, maximum in items:
        descriptor = os.open(path, flags)
        opened.append(descriptor)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size <= 0
            or metadata.st_size > maximum
        ):
            raise OSError("unsafe release control input")
        digest = hashlib.sha1() if len(object_id) == 40 else hashlib.sha256()
        digest.update(("blob " + str(metadata.st_size) + "\0").encode("ascii"))
        offset = 0
        while offset < metadata.st_size:
            chunk = os.pread(
                descriptor, min(65536, metadata.st_size - offset), offset
            )
            if not chunk:
                raise OSError("truncated release control input")
            digest.update(chunk)
            offset += len(chunk)
        mapped = os.lstat(path)
        after = os.fstat(descriptor)
        if (
            (
                after.st_dev,
                after.st_ino,
                after.st_mode,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
                after.st_nlink,
            ) != (
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_mode,
                metadata.st_size,
                metadata.st_mtime_ns,
                metadata.st_ctime_ns,
                metadata.st_nlink,
            )
            or stat.S_ISLNK(mapped.st_mode)
            or (mapped.st_dev, mapped.st_ino)
            != (metadata.st_dev, metadata.st_ino)
            or digest.hexdigest() != object_id
        ):
            raise OSError("release control object mismatch")
        os.dup2(descriptor, target, inheritable=True)
        # os.dup2 may be a no-op when os.open already returned the requested
        # number (notably the fourth control commonly arrives as fd 7).  Make
        # the ownership transfer explicit so that case survives execve too.
        os.set_inheritable(target, True)
    environment = dict(os.environ)
    environment["SP11_RELEASE_CONTROL_FDS_BOUND"] = \
        "sp11-release-control-fds-v1"
    environment["SP11_RELEASE_REPO_DIR"] = os.path.dirname(os.path.dirname(script))
    script_fd = "/proc/self/fd/5" if sys.platform.startswith("linux") \
        else "/dev/fd/5"
    os.execve("/bin/bash", ["/bin/bash", script_fd, *arguments], environment)
except Exception:
    os.write(2, b"Could not bind exact release controller inputs.\n")
    raise SystemExit(1)
' "$builder_script" \
    "$launcher_builder_oid" \
    "$repo_dir/$KERNEL_BASELINE_REL" "$launcher_baseline_oid" \
    "$repo_dir/$KERNEL_BASELINE_VALIDATOR_REL" \
    "$launcher_baseline_validator_oid" \
    "$repo_dir/$KERNEL_TREE_SYMLINK_VALIDATOR_REL" \
    "$launcher_tree_validator_oid" \
    "${ORIGINAL_ARGUMENTS[@]}"
}

require_release_build_contract

PATCH_DIR="${PATCH_DIR:-$repo_dir/patches/ubuntu-qcom-x1e-7.0}"
if [ -n "$PATCH_DIRS" ]; then
  for pd in $PATCH_DIRS; do
    if [ ! -d "$pd" ]; then
      echo "Patch directory not found: $pd" >&2
      exit 1
    fi
  done
elif [ "$INSTALL_ONLY" != "true" ] && [ ! -d "$PATCH_DIR" ]; then
  echo "Patch directory not found: $PATCH_DIR" >&2
  exit 1
fi

collect_release_patch_inputs() {
  local patch_dir_list pd canonical_dir patch canonical_patch relative_path
  local directory_patch_count repo_real

  [ "$RELEASE_BUILD" = "true" ] || return 0

  repo_real="$(cd "$repo_dir" && pwd -P)"
  if [ -n "$PATCH_DIRS" ]; then
    patch_dir_list="$PATCH_DIRS"
  else
    patch_dir_list="$PATCH_DIR"
  fi

  for pd in $patch_dir_list; do
    if [ -L "$pd" ]; then
      echo "Release patch directory must not be a symlink: $pd" >&2
      exit 1
    fi
    canonical_dir="$(cd "$pd" && pwd -P)"
    case "$canonical_dir" in
      "$repo_real"/*) ;;
      *)
        echo "Release patches must be tracked inside the support repository: $pd" >&2
        exit 1
        ;;
    esac

    if find "$canonical_dir" -maxdepth 1 -type l -name '*.patch' -print | grep -q .; then
      echo "Release patch directories must not contain symlinked .patch entries: $pd" >&2
      exit 1
    fi

    directory_patch_count=0
    while IFS= read -r patch; do
      [ -n "$patch" ] || continue
      directory_patch_count=$((directory_patch_count + 1))
      if [ ! -s "$patch" ] || [ -L "$patch" ]; then
        echo "Release patch must be a nonempty regular, non-symlinked file: $patch" >&2
        exit 1
      fi
      canonical_patch="$(cd "$(dirname "$patch")" && pwd -P)/$(basename "$patch")"
      case "$canonical_patch" in
        "$repo_real"/*) relative_path="${canonical_patch#"$repo_real"/}" ;;
        *)
          echo "Release patch resolves outside the support repository: $patch" >&2
          exit 1
          ;;
      esac
      if ! support_git ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1; then
        echo "Release patch is not tracked by the support commit: $relative_path" >&2
        exit 1
      fi
      RELEASE_PATCH_PATHS+=("$relative_path")
      RELEASE_PATCH_ABS_PATHS+=("$canonical_patch")
      RELEASE_PATCH_SHA256S+=("$(sha256_file "$canonical_patch")")
    done < <(find "$canonical_dir" -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort)

    if [ "$directory_patch_count" -eq 0 ]; then
      echo "Release patch directory contains no regular .patch files: $pd" >&2
      exit 1
    fi
  done

  if [ "${#RELEASE_PATCH_PATHS[@]}" -eq 0 ]; then
    echo "--release-build requires at least one tracked patch." >&2
    exit 1
  fi
}

collect_release_patch_inputs

host_os="$(uname -s)"
host_arch="$(uname -m)"
if [ "$PREPARE_ONLY" != "true" ] && [ "$ALLOW_NON_ARM64" != "true" ]; then
  if [ "$host_os" != "Linux" ] || { [ "$host_arch" != "aarch64" ] && [ "$host_arch" != "arm64" ]; }; then
    echo "Kernel build should run on a Linux aarch64 host, ideally the installed Surface Pro 11." >&2
    echo "Pass --prepare-only to only validate patch application on this host." >&2
    exit 1
  fi
fi

if [ "$SOURCE_MODE" = "apt" ] && [ "$host_os" != "Linux" ]; then
  echo "apt source mode requires Linux apt tooling." >&2
  echo "Use --source git for prepare-only patch validation on this host." >&2
  exit 1
fi

if [ "$INSTALL_ONLY" != "true" ]; then
  require_tool git
fi

case "$WORK_DIR" in
  ""|/|.|..|../*|*/../*|*/..|./*|*/./*|*//*|-*|*/-*|*[[:cntrl:]]*)
    echo "Kernel work directory must use a dedicated canonical path: $WORK_DIR" >&2
    exit 1
    ;;
esac
work_parent="$(dirname "$WORK_DIR")"
work_leaf="$(basename "$WORK_DIR")"
if [ ! -d "$work_parent" ] || [ -L "$work_parent" ]; then
  echo "Create a real, non-symlinked parent before using --work-dir: $work_parent" >&2
  exit 1
fi
work_parent_logical="$(cd "$work_parent" && pwd -L)"
work_parent_physical="$(cd "$work_parent" && pwd -P)"
if [ "$work_parent_logical" != "$work_parent_physical" ]; then
  echo "Kernel work directory parent must not contain symlink components: $work_parent" >&2
  exit 1
fi
if [ "$work_parent_physical" = "/" ]; then
  expected_work_dir="/$work_leaf"
else
  expected_work_dir="$work_parent_physical/$work_leaf"
fi
if [ -L "$WORK_DIR" ] ||
   { [ -e "$WORK_DIR" ] && [ ! -d "$WORK_DIR" ]; }; then
  echo "Kernel work directory must be a real, non-symlinked directory: $WORK_DIR" >&2
  exit 1
fi
if [ ! -e "$WORK_DIR" ]; then
  mkdir "$expected_work_dir"
fi
work_dir="$(cd "$WORK_DIR" && pwd -P)"
if [ "$work_dir" != "$expected_work_dir" ]; then
  echo "Kernel work directory resolves outside its requested managed path: $WORK_DIR" >&2
  exit 1
fi
WORK_DIR_IDENTITY="$(baseline_control_identity "$work_dir")"
source_parent="$work_dir/source"
source_dir=""
if [ -L "$source_parent" ] ||
   { [ -e "$source_parent" ] && [ ! -d "$source_parent" ]; }; then
  echo "Kernel source parent must be a real, non-symlinked directory: $source_parent" >&2
  exit 1
fi
if [ ! -e "$source_parent" ]; then
  mkdir "$source_parent"
fi
if [ "$(cd "$source_parent" && pwd -P)" != "$source_parent" ]; then
  echo "Kernel source parent resolves outside its managed work path: $source_parent" >&2
  exit 1
fi

if [ "$RELEASE_BUILD" = "true" ]; then
  for release_output_name in \
      sp11-kernel-build-manifest.txt sp11-kernel-debs.txt; do
    release_output_path="$work_dir/$release_output_name"
    if [ -e "$release_output_path" ] || [ -L "$release_output_path" ]; then
      echo "Release output already exists; refusing replacement: $release_output_name" >&2
      exit 1
    fi
  done
fi

install_dependencies() {
  require_tool dpkg-query

  local deps source_pkg
  deps=(
    bc
    bison
    build-essential
    cpio
    debhelper
    devscripts
    dpkg-dev
    dwarves
    equivs
    flex
    git
    kmod
    libelf-dev
    libssl-dev
    openssl
    python3
    python3-dev
    rsync
  )

  if [ "$(id -u)" -ne 0 ] && [ "$NO_FAKEROOT" != "true" ]; then
    deps+=(fakeroot)
  fi

  as_root apt-get update
  as_root apt-get install -y --no-install-recommends "${deps[@]}"

  if [ "$SOURCE_MODE" = "apt" ]; then
    source_pkg="$(resolve_apt_source_package)"
    if ! as_root apt-get build-dep -y "$source_pkg"; then
      echo "apt build-dep failed for $source_pkg." >&2
      echo "Enable matching deb-src entries for the repositories that provide the qcom-x1e source package, then rerun apt update." >&2
      echo "For bring-up without matching source repositories, retry with --source git." >&2
      exit 1
    fi
  fi
}

install_source_build_dependencies() {
  local control_file="$source_dir/debian/control" rules_file
  local mk_build_deps_args=(--install)

  [ "$INSTALL_DEPS" = "true" ] || return 0
  [ "$SOURCE_MODE" = "git" ] || return 0

  if [ ! -f "$control_file" ]; then
    rules_file="$(find_rules_file)"
    (
      cd "$source_dir"
      run_rules "$rules_file" debian/control
    )
  fi

  if [ ! -f "$control_file" ]; then
    echo "Cannot install git source build dependencies; missing $control_file." >&2
    exit 1
  fi

  (
    cd "$work_dir"
    if [ "${SP11_IMMUTABLE_APT_REQUIRED:-false}" != "true" ]; then
      mk_build_deps_args+=(--remove)
    fi
    as_root_with_build_identity mk-build-deps \
      "${mk_build_deps_args[@]}" \
      --tool "apt-get -y --no-install-recommends" \
      "$control_file"
  )
}

check_free_space() {
  local available_kb required_kb
  available_kb="$(df -Pk "$work_dir" | awk 'NR == 2 { print $4 }')"
  required_kb=$((MIN_FREE_GB * 1024 * 1024))
  if [ -n "$available_kb" ] && [ "$available_kb" -lt "$required_kb" ]; then
    echo "Not enough free space for a kernel build under $work_dir." >&2
    echo "Available: $((available_kb / 1024 / 1024)) GiB; required: ${MIN_FREE_GB} GiB." >&2
    exit 1
  fi
}

installed_kernel_package_field() {
  local field release pkg value
  field="$1"
  release="$(uname -r 2>/dev/null || true)"
  [ -n "$release" ] || return 0

  for pkg in \
    "linux-modules-$release" \
    "linux-headers-$release" \
    "linux-image-unsigned-$release" \
    "linux-image-$release"; do
    value="$(dpkg-query -W -f="\${$field}" "$pkg" 2>/dev/null || true)"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
}

resolve_apt_source_package() {
  local source_pkg

  if [ "$SOURCE_PACKAGE" != "installed" ]; then
    printf '%s\n' "$SOURCE_PACKAGE"
    return 0
  fi

  source_pkg="$(installed_kernel_package_field 'source:Package')"
  if [ -n "$source_pkg" ]; then
    printf '%s\n' "$source_pkg"
    return 0
  fi

  echo "Could not derive the running kernel source package; falling back to linux." >&2
  printf '%s\n' "linux"
}

resolve_installed_source_version() {
  installed_kernel_package_field 'source:Version'
}

assert_managed_source_path() {
  local dir="$1" resolved

  if [ -L "$source_parent" ] || [ ! -d "$source_parent" ] ||
     [ "$(cd "$source_parent" && pwd -P)" != "$source_parent" ]; then
    echo "Kernel source parent is no longer the managed work directory: $source_parent" >&2
    return 1
  fi
  case "$dir" in
    "$source_parent"/git-*) ;;
    *)
      echo "Kernel Git checkout escaped the managed source parent: $dir" >&2
      return 1
      ;;
  esac
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
    echo "Kernel Git checkout must be a real, non-symlinked managed directory: $dir" >&2
    return 1
  fi
  if [ -d "$dir" ]; then
    resolved="$(cd "$dir" && pwd -P)"
    if [ "$resolved" != "$dir" ]; then
      echo "Kernel Git checkout resolves outside its managed source path: $dir" >&2
      return 1
    fi
    if [ -L "$dir/.git" ] ||
       { [ -e "$dir/.git" ] && [ ! -d "$dir/.git" ]; }; then
      echo "Kernel Git metadata must be a real, non-symlinked directory: $dir/.git" >&2
      return 1
    fi
    if [ -d "$dir/.git" ] &&
       [ "$(cd "$dir/.git" && pwd -P)" != "$dir/.git" ]; then
      echo "Kernel Git metadata resolves outside its managed checkout: $dir/.git" >&2
      return 1
    fi
  fi
}

ensure_clean_source() {
  local dir="$1"

  assert_managed_source_path "$dir" || exit 1
  if [ ! -d "$dir" ]; then
    return 0
  fi

  if [ "$RESET_SOURCE" = "true" ]; then
    if [ -d "$dir/.git" ]; then
      assert_managed_source_path "$dir" || exit 1
      git -C "$dir" reset --hard
      git -C "$dir" clean -ffdx
    else
      assert_managed_source_path "$dir" || exit 1
      rm -rf "$dir"
    fi
    return 0
  fi

  if [ -d "$dir/.git" ]; then
    if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
      echo "Existing source tree has local changes: $dir" >&2
      echo "Commit/stash them or rerun with --reset-source." >&2
      exit 1
    fi
    if [ -n "$(git -C "$dir" ls-files --others --exclude-standard)" ]; then
      echo "Existing source tree has untracked files: $dir" >&2
      echo "Remove them or rerun with --reset-source." >&2
      exit 1
    fi
    if [ "$RELEASE_BUILD" = "true" ] &&
       [ -n "$(git -C "$dir" ls-files --others --ignored --exclude-standard)" ]; then
      echo "Existing release source tree has ignored build outputs or files: $dir" >&2
      echo "Rerun with --reset-source so patched-tree provenance starts from a pristine checkout." >&2
      exit 1
    fi
  else
    echo "Existing non-git source directory found: $dir" >&2
    echo "Move it away or rerun with --reset-source." >&2
    exit 1
  fi
}

prepare_git_source() {
  local safe_branch dir local_commits ref_kind configured_origin
  safe_branch="${GIT_BRANCH//\//-}"
  dir="$source_parent/git-$safe_branch"
  ref_kind=""

  ensure_clean_source "$dir"
  if [ ! -d "$dir" ]; then
    git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL" "$dir"
    assert_managed_source_path "$dir" || exit 1
  else
    if ! configured_origin="$(git -C "$dir" remote get-url origin 2>/dev/null)"; then
      echo "Existing source tree has no readable origin remote: $dir" >&2
      echo "Rerun with --reset-source so it is cloned from $GIT_URL." >&2
      exit 1
    fi
    if [ "$configured_origin" != "$GIT_URL" ]; then
      echo "Existing source tree origin does not match --git-url: $dir" >&2
      echo "Requested:  $GIT_URL" >&2
      echo "Configured: $configured_origin" >&2
      echo "Rerun with --reset-source so retrieval provenance is unambiguous." >&2
      exit 1
    fi
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$GIT_BRANCH"; then
      ref_kind="head"
    elif git -C "$dir" show-ref --verify --quiet "refs/tags/$GIT_BRANCH"; then
      ref_kind="tag"
    elif git ls-remote --exit-code --heads "$GIT_URL" "$GIT_BRANCH" >/dev/null 2>&1; then
      ref_kind="head"
    elif git ls-remote --exit-code --tags "$GIT_URL" "$GIT_BRANCH" >/dev/null 2>&1; then
      ref_kind="tag"
    else
      echo "Git ref not found as a branch or tag: $GIT_BRANCH" >&2
      echo "Remote: $GIT_URL" >&2
      exit 1
    fi
    if [ "$ref_kind" = "head" ]; then
      git -C "$dir" fetch origin "$GIT_BRANCH"
      git -C "$dir" checkout "$GIT_BRANCH"
      local_commits="$(git -C "$dir" rev-list --count "origin/$GIT_BRANCH..HEAD" 2>/dev/null || echo 0)"
      if [ "$local_commits" != "0" ]; then
        echo "Existing source tree has local commits not present in origin/$GIT_BRANCH: $dir" >&2
        echo "Move them away or rerun with --reset-source." >&2
        exit 1
      fi
      git -C "$dir" reset --hard "origin/$GIT_BRANCH"
    else
      if ! git -C "$dir" show-ref --verify --quiet "refs/tags/$GIT_BRANCH"; then
        git -C "$dir" fetch --force origin "refs/tags/$GIT_BRANCH:refs/tags/$GIT_BRANCH"
      fi
      git -C "$dir" checkout --detach "refs/tags/$GIT_BRANCH"
      git -C "$dir" reset --hard "refs/tags/$GIT_BRANCH"
    fi
  fi

  source_dir="$dir"
}

verify_expected_source_commit() {
  local actual_source_commit

  [ -n "$EXPECTED_SOURCE_COMMIT" ] || return 0

  actual_source_commit="$(git -C "$source_dir" rev-parse --verify "HEAD^{commit}")"
  actual_source_commit="$(printf '%s' "$actual_source_commit" | tr '[:upper:]' '[:lower:]')"
  if [ "$actual_source_commit" != "$EXPECTED_SOURCE_COMMIT" ]; then
    echo "Resolved kernel source does not match --expected-source-commit." >&2
    echo "Expected: $EXPECTED_SOURCE_COMMIT" >&2
    echo "Resolved: $actual_source_commit" >&2
    echo "Refusing to apply patches or start a build from an unexpected source commit." >&2
    exit 1
  fi

  echo "Verified expected source commit: $actual_source_commit"
}

canonical_utc_timestamp() {
  local epoch="$1" rendered=""

  if rendered="$(LC_ALL=C TZ=UTC0 date -u -d "@$epoch" \
      '+%a %b %e %H:%M:%S UTC %Y' 2>/dev/null)"; then
    printf '%s\n' "$rendered"
    return 0
  fi
  if rendered="$(LC_ALL=C TZ=UTC0 date -u -r "$epoch" \
      '+%a %b %e %H:%M:%S UTC %Y' 2>/dev/null)"; then
    printf '%s\n' "$rendered"
    return 0
  fi
  return 1
}

verify_and_export_build_identity() {
  local actual_epoch expected_timestamp

  [ -n "$SOURCE_DATE_EPOCH" ] || return 0

  if ! actual_epoch="$(git -C "$source_dir" show -s --format=%ct "$EXPECTED_SOURCE_COMMIT")" ||
     ! [[ "$actual_epoch" =~ ^[1-9][0-9]{0,9}$ ]]; then
    echo "Could not resolve the exact source commit epoch for deterministic packaging." >&2
    exit 1
  fi
  if [ "$actual_epoch" != "$SOURCE_DATE_EPOCH" ]; then
    echo "--source-date-epoch does not match the exact source commit timestamp." >&2
    echo "Expected from source: $actual_epoch" >&2
    echo "Requested:            $SOURCE_DATE_EPOCH" >&2
    echo "Refusing to apply patches, generate build-deps, or start a build." >&2
    exit 1
  fi
  if ! expected_timestamp="$(canonical_utc_timestamp "$SOURCE_DATE_EPOCH")"; then
    echo "Could not render --source-date-epoch as a canonical UTC Kbuild timestamp." >&2
    exit 1
  fi
  if [ "$KBUILD_BUILD_TIMESTAMP" != "$expected_timestamp" ]; then
    echo "--kbuild-build-timestamp does not match --source-date-epoch." >&2
    echo "Expected: $expected_timestamp" >&2
    echo "Requested: $KBUILD_BUILD_TIMESTAMP" >&2
    echo "Refusing to apply patches, generate build-deps, or start a build." >&2
    exit 1
  fi

  export SOURCE_DATE_EPOCH KBUILD_BUILD_USER KBUILD_BUILD_HOST KBUILD_BUILD_TIMESTAMP
  echo "Verified deterministic source/build identity at epoch: $SOURCE_DATE_EPOCH"
}

prepare_apt_source() {
  require_tool apt-get
  require_tool apt-cache
  require_tool dpkg-query

  local before after new_dirs source_spec version source_pkg
  before="$(mktemp)"
  after="$(mktemp)"
  source_pkg="$(resolve_apt_source_package)"
  RESOLVED_SOURCE_PACKAGE="$source_pkg"

  if [ "$RESET_SOURCE" = "true" ]; then
    rm -rf "$source_parent"
    mkdir -p "$source_parent"
  elif find "$source_parent" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    echo "Existing apt source directories found under $source_parent." >&2
    echo "Rerun with --reset-source to avoid rebuilding from stale or modified source trees." >&2
    exit 1
  fi

  case "$SOURCE_VERSION" in
    installed)
      version="$(resolve_installed_source_version)"
      if [ -z "$version" ]; then
        echo "Could not derive the running kernel source version; apt source will use the default source candidate." >&2
      fi
      ;;
    candidate)
      version="$(apt-cache showsrc "$source_pkg" 2>/dev/null | awk '/^Version:/ { print $2; exit }')"
      ;;
    "")
      version=""
      ;;
    *)
      version="$SOURCE_VERSION"
      ;;
  esac

  if [ -n "$version" ]; then
    source_spec="$source_pkg=$version"
  else
    source_spec="$source_pkg"
  fi
  SOURCE_SPEC="$source_spec"

  find "$source_parent" -mindepth 1 -maxdepth 1 -type d -print | sort > "$before"
  if ! (
    cd "$source_parent" || exit 1
    apt-get source "$source_spec" || exit 1
  ); then
    rm -f "$before" "$after"
    echo "apt source failed for $source_spec." >&2
    echo "Enable matching deb-src entries for the repositories that provide the running qcom-x1e kernel packages, then rerun sudo apt update." >&2
    if [ "$SOURCE_VERSION" = "installed" ]; then
      echo "The requested version was derived from the installed kernel package source metadata." >&2
      echo "If that source version is no longer available, retry with --source-version candidate." >&2
    fi
    exit 1
  fi
  find "$source_parent" -mindepth 1 -maxdepth 1 -type d -print | sort > "$after"
  new_dirs="$(comm -13 "$before" "$after")"
  rm -f "$before" "$after"

  if [ -z "$new_dirs" ]; then
    source_dir="$(find "$source_parent" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 { sub(/^[^ ]+ /, ""); print }')"
  else
    source_dir="$(printf '%s\n' "$new_dirs" | head -n 1)"
  fi

  if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]; then
    echo "Could not find unpacked apt source under $source_parent." >&2
    echo "If apt source failed, enable deb-src entries for the running qcom-x1e kernel source." >&2
    exit 1
  fi

  echo "Using apt source: $source_spec"
}

apply_patch_file() {
  local patch="$1"

  LAST_PATCH_DISPOSITION=""
  case "$(basename "$patch")" in
    0001-wifi-ath12k-add-disable-rfkill-devicetree.patch)
      if grep -q 'of_property_read_bool(ab->dev->of_node, "disable-rfkill")' \
        "$source_dir/drivers/net/wireless/ath/ath12k/core.c"; then
        echo "Already satisfied: $(basename "$patch")"
        LAST_PATCH_DISPOSITION="already-satisfied"
        return 0
      fi
      ;;
    0002-arm64-dts-qcom-x1-denali-disable-rfkill-for-wifi.patch)
      if grep -q 'disable-rfkill;' \
        "$source_dir/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi"; then
        echo "Already satisfied: $(basename "$patch")"
        LAST_PATCH_DISPOSITION="already-satisfied"
        return 0
      fi
      ;;
    0002-debian-remove-host-local-find-dtbs-symlink.patch)
      if [ ! -e "$source_dir/debian/scripts/misc/find-dtbs.py" ] &&
         [ ! -L "$source_dir/debian/scripts/misc/find-dtbs.py" ]; then
        echo "Already satisfied: $(basename "$patch")"
        LAST_PATCH_DISPOSITION="already-satisfied"
        return 0
      fi
      ;;
  esac

  if git -C "$source_dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "Already applied: $(basename "$patch")"
    LAST_PATCH_DISPOSITION="already-applied"
    return 0
  fi

  echo "Applying: $(basename "$patch")"
  git -C "$source_dir" apply --check "$patch"
  git -C "$source_dir" apply "$patch"
  LAST_PATCH_DISPOSITION="applied"
}

apply_patches() {
  local patch_dir_list patch_index

  if [ "$RELEASE_BUILD" = "true" ]; then
    patch_index=0
    while [ "$patch_index" -lt "${#RELEASE_PATCH_ABS_PATHS[@]}" ]; do
      apply_patch_file "${RELEASE_PATCH_ABS_PATHS[$patch_index]}"
      if [ "$(sha256_file "${RELEASE_PATCH_ABS_PATHS[$patch_index]}")" != \
           "${RELEASE_PATCH_SHA256S[$patch_index]}" ]; then
        echo "Release patch changed while it was being applied: ${RELEASE_PATCH_PATHS[$patch_index]}" >&2
        exit 1
      fi
      RELEASE_PATCH_DISPOSITIONS+=("$LAST_PATCH_DISPOSITION")
      patch_index=$((patch_index + 1))
    done
  else
    if [ -n "$PATCH_DIRS" ]; then
      patch_dir_list="$PATCH_DIRS"
    else
      patch_dir_list="$PATCH_DIR"
    fi

    for pd in $patch_dir_list; do
      echo "Applying patches from $pd"
      for patch in "$pd"/*.patch; do
        [ -f "$patch" ] || continue
        apply_patch_file "$patch"
      done
    done
  fi

  grep -q 'of_property_read_bool(ab->dev->of_node, "disable-rfkill")' \
    "$source_dir/drivers/net/wireless/ath/ath12k/core.c"
  grep -q 'disable-rfkill;' \
    "$source_dir/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi"
}

find_rules_file() {
  if [ -x "$source_dir/debian/rules" ]; then
    printf '%s\n' "debian/rules"
  elif [ -x "$source_dir/.debian/rules" ]; then
    printf '%s\n' ".debian/rules"
  else
    echo "Could not find executable debian/rules or .debian/rules in $source_dir." >&2
    exit 1
  fi
}

kernel_tree_validator_python_identity_record() {
  [ "$KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN" = "true" ] &&
    [ "$KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN" = "true" ] &&
    [ -n "$KERNEL_TREE_VALIDATOR_PYTHON" ] || return 1
  "$KERNEL_TREE_VALIDATOR_PYTHON" -I -c '
# SP11_INNER_PYTHON_AUTHORITY_PROGRAM_BEGIN
import os
import re
import stat
import sys

target_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
target_descriptor = -1

def identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
    )

try:
    if len(sys.argv) != 6:
        raise RuntimeError
    directory_descriptor = int(sys.argv[1], 10)
    directory_path = sys.argv[2]
    alias_name = sys.argv[3]
    expected_uid_text = sys.argv[4]
    execution_descriptor = int(sys.argv[5], 10)
    if (
        sys.flags.isolated != 1
        or not expected_uid_text.isascii()
        or not expected_uid_text.isdecimal()
        or str(int(expected_uid_text, 10)) != expected_uid_text
        or not os.path.isabs(directory_path)
        or os.path.normpath(directory_path) != directory_path
        or alias_name != "python3"
        or execution_descriptor != 8
    ):
        raise RuntimeError
    expected_uid = int(expected_uid_text, 10)
    directory_before = os.fstat(directory_descriptor)
    directory_mapped_before = os.stat(directory_path, follow_symlinks=False)
    if (
        not stat.S_ISDIR(directory_before.st_mode)
        or not stat.S_ISDIR(directory_mapped_before.st_mode)
        or directory_before.st_uid != expected_uid
        or stat.S_IMODE(directory_before.st_mode) & 0o022
        or identity(directory_before) != identity(directory_mapped_before)
    ):
        raise RuntimeError
    alias_before = os.stat(
        alias_name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    if stat.S_ISREG(alias_before.st_mode):
        alias_kind = "regular"
        target_name = alias_name
    elif stat.S_ISLNK(alias_before.st_mode):
        if alias_before.st_uid != expected_uid or alias_before.st_nlink != 1:
            raise RuntimeError
        alias_kind = "symlink"
        target_name = os.readlink(alias_name, dir_fd=directory_descriptor)
        if not re.fullmatch(r"python3\.[0-9]+", target_name):
            raise RuntimeError
    else:
        raise RuntimeError
    target_mapped_before = os.stat(
        target_name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    if (
        not stat.S_ISREG(target_mapped_before.st_mode)
        or target_mapped_before.st_uid != expected_uid
        or stat.S_IMODE(target_mapped_before.st_mode) & 0o022
        or not stat.S_IMODE(target_mapped_before.st_mode) & 0o111
        or target_mapped_before.st_size <= 0
        or target_mapped_before.st_size > 256 * 1024 * 1024
    ):
        raise RuntimeError
    target_descriptor = os.open(
        target_name,
        target_flags,
        dir_fd=directory_descriptor,
    )
    target_before = os.fstat(target_descriptor)
    execution_before = os.fstat(execution_descriptor)
    alias_followed_before = os.stat(
        alias_name,
        dir_fd=directory_descriptor,
        follow_symlinks=True,
    )
    if (
        identity(target_before) != identity(target_mapped_before)
        or identity(alias_followed_before) != identity(target_before)
        or identity(execution_before) != identity(target_before)
        or not os.pread(target_descriptor, 1, 0)
        or not os.pread(execution_descriptor, 1, 0)
    ):
        raise RuntimeError

    # SP11_INNER_PYTHON_AUTHORITY_AFTER_INITIAL_STATE

    directory_after = os.fstat(directory_descriptor)
    directory_mapped_after = os.stat(directory_path, follow_symlinks=False)
    alias_after = os.stat(
        alias_name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    target_mapped_after = os.stat(
        target_name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    alias_followed_after = os.stat(
        alias_name,
        dir_fd=directory_descriptor,
        follow_symlinks=True,
    )
    target_after = os.fstat(target_descriptor)
    execution_after = os.fstat(execution_descriptor)
    if (
        identity(directory_after) != identity(directory_before)
        or identity(directory_mapped_after) != identity(directory_before)
        or identity(alias_after) != identity(alias_before)
        or identity(target_mapped_after) != identity(target_before)
        or identity(alias_followed_after) != identity(target_before)
        or identity(target_after) != identity(target_before)
        or identity(execution_after) != identity(target_before)
        or (
            alias_kind == "symlink"
            and os.readlink(alias_name, dir_fd=directory_descriptor) != target_name
        )
    ):
        raise RuntimeError
    print(
        *identity(directory_before),
        alias_kind,
        *identity(alias_before),
        target_name,
        *identity(target_before),
    )
except BaseException:
    raise SystemExit(1)
finally:
    if target_descriptor >= 0:
        try:
            os.close(target_descriptor)
        except OSError:
            pass
# SP11_INNER_PYTHON_AUTHORITY_PROGRAM_END
' 5 /usr/bin python3 0 8
}

verify_kernel_tree_validator_sink() {
  local current_python_identity

  [ "$KERNEL_TREE_VALIDATOR_SINK_OPEN" = "true" ] &&
    [ "$KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN" = "true" ] &&
    [ "$KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN" = "true" ] &&
    [ "$KERNEL_TREE_VALIDATOR_HELPER_FD_OPEN" = "true" ] &&
    [ -n "$KERNEL_TREE_VALIDATOR_PYTHON" ] &&
    [ -n "$KERNEL_TREE_VALIDATOR_PYTHON_IDENTITY" ] &&
    [ -n "$KERNEL_TREE_VALIDATOR_HELPER" ] &&
    [[ "$KERNEL_TREE_VALIDATOR_HELPER_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
  current_python_identity="$(kernel_tree_validator_python_identity_record)" || return 1
  [ "$current_python_identity" = "$KERNEL_TREE_VALIDATOR_PYTHON_IDENTITY" ] || return 1
  "$KERNEL_TREE_VALIDATOR_PYTHON" -I -c '
import hashlib
import os
import stat
import sys

expected_helper_digest = sys.argv[1]
helper_path = sys.argv[2]
helper_metadata = os.fstat(7)
helper_mapping = os.lstat(helper_path)
python_metadata = os.fstat(8)
python_mapping = os.stat("/usr/bin/python3")
metadata = os.fstat(9)
expected = (1, 3) if sys.platform.startswith("linux") else (3, 2)
if sys.platform != "darwin" and not sys.platform.startswith("linux"):
    raise SystemExit(1)
if not stat.S_ISREG(python_metadata.st_mode) or not python_metadata.st_mode & 0o111:
    raise SystemExit(1)
if not stat.S_ISREG(python_mapping.st_mode):
    raise SystemExit(1)
if (python_mapping.st_dev, python_mapping.st_ino) != (
    python_metadata.st_dev,
    python_metadata.st_ino,
):
    raise SystemExit(1)
if (
    stat.S_ISLNK(helper_mapping.st_mode)
    or not stat.S_ISREG(helper_mapping.st_mode)
    or not stat.S_ISREG(helper_metadata.st_mode)
    or helper_metadata.st_size <= 0
    or helper_metadata.st_size > 1024 * 1024
    or helper_metadata.st_nlink != 1
    or (helper_mapping.st_dev, helper_mapping.st_ino)
    != (helper_metadata.st_dev, helper_metadata.st_ino)
):
    raise SystemExit(1)
helper_identity = (
    helper_metadata.st_dev,
    helper_metadata.st_ino,
    helper_metadata.st_mode,
    helper_metadata.st_size,
    helper_metadata.st_mtime_ns,
    helper_metadata.st_ctime_ns,
    helper_metadata.st_nlink,
)
os.lseek(7, 0, os.SEEK_SET)
digest = hashlib.sha256()
remaining = helper_metadata.st_size
while remaining:
    chunk = os.read(7, min(65536, remaining))
    if not chunk:
        raise SystemExit(1)
    digest.update(chunk)
    remaining -= len(chunk)
if os.read(7, 1) or digest.hexdigest() != expected_helper_digest:
    raise SystemExit(1)
os.lseek(7, 0, os.SEEK_SET)
helper_after = os.fstat(7)
if helper_identity != (
    helper_after.st_dev,
    helper_after.st_ino,
    helper_after.st_mode,
    helper_after.st_size,
    helper_after.st_mtime_ns,
    helper_after.st_ctime_ns,
    helper_after.st_nlink,
):
    raise SystemExit(1)
if not stat.S_ISCHR(metadata.st_mode):
    raise SystemExit(1)
if (os.major(metadata.st_rdev), os.minor(metadata.st_rdev)) != expected:
    raise SystemExit(1)
' "$KERNEL_TREE_VALIDATOR_HELPER_SHA256" \
    "$KERNEL_TREE_SYMLINK_VALIDATOR" 1>&9 2>&9
}

initialize_kernel_tree_validator_sink() {
  local python_identity_fields=()

  [ "$RELEASE_BUILD" = "true" ] || return 0
  # Trust boundary: the digest-pinned OCI/APT /usr, loader, libraries, Python
  # stdlib, and Git toolchain are materialized build authority. FD 8 prevents a
  # later executable-name swap; it is not a defense against arbitrary root
  # mutation of that trusted toolchain. Darwin is fixture-only because macOS
  # does not permit executing /dev/fd/8.
  if ! exec 5</usr/bin; then
    echo "Could not hold the trusted kernel-tree validator interpreter directory." >&2
    return 1
  fi
  KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="true"
  if ! exec 8</usr/bin/python3; then
    exec 5<&-
    KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
    echo "Could not pin the trusted kernel-tree validator interpreter." >&2
    return 1
  fi
  KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="true"
  case "$host_os" in
    Linux)
      KERNEL_TREE_VALIDATOR_PYTHON="/proc/self/fd/8"
      KERNEL_TREE_VALIDATOR_HELPER="/proc/self/fd/7"
      ;;
    Darwin)
      KERNEL_TREE_VALIDATOR_PYTHON="/usr/bin/python3"
      KERNEL_TREE_VALIDATOR_HELPER="/dev/fd/7"
      ;;
    *)
      exec 8<&-
      exec 5<&-
      KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="false"
      KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
      echo "Kernel-tree validation requires Linux or the Darwin fixture boundary." >&2
      return 1
      ;;
  esac
  KERNEL_TREE_VALIDATOR_PYTHON_IDENTITY="$(
    kernel_tree_validator_python_identity_record
  )" || {
    exec 8<&-
    exec 5<&-
    KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="false"
    KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
    echo "Trusted kernel-tree validator interpreter authority is unavailable." >&2
    return 1
  }
  read -r -a python_identity_fields <<< "$KERNEL_TREE_VALIDATOR_PYTHON_IDENTITY"
  if [ "${#python_identity_fields[@]}" -ne 29 ]; then
    exec 8<&-
    exec 5<&-
    KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="false"
    KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
    KERNEL_TREE_VALIDATOR_PYTHON_IDENTITY=""
    echo "Trusted kernel-tree validator interpreter identity is not exact." >&2
    return 1
  fi
  KERNEL_TREE_VALIDATOR_HELPER_SHA256="${KERNEL_TREE_SYMLINK_VALIDATOR_STATE##*:}"
  if ! [[ "$KERNEL_TREE_VALIDATOR_HELPER_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    exec 8<&-
    exec 5<&-
    KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="false"
    KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
    echo "Exact kernel-tree validator helper digest is unavailable." >&2
    return 1
  fi
  if [ "$KERNEL_TREE_VALIDATOR_HELPER_FD_OPEN" != "true" ] ||
     ! verify_kernel_baseline_control_state; then
    exec 8<&-
    exec 5<&-
    KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="false"
    KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
    echo "Exact kernel-tree validator helper binding is unavailable." >&2
    return 1
  fi
  if ! exec 9>/dev/null; then
    exec 7<&-
    exec 8<&-
    exec 5<&-
    KERNEL_TREE_VALIDATOR_HELPER_FD_OPEN="false"
    KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="false"
    KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
    echo "Could not open the trusted kernel-tree validator output sink." >&2
    return 1
  fi
  KERNEL_TREE_VALIDATOR_SINK_OPEN="true"
  if ! verify_kernel_tree_validator_sink; then
    exec 9>&-
    exec 7<&-
    exec 8<&-
    exec 5<&-
    KERNEL_TREE_VALIDATOR_SINK_OPEN="false"
    KERNEL_TREE_VALIDATOR_HELPER_FD_OPEN="false"
    KERNEL_TREE_VALIDATOR_PYTHON_FD_OPEN="false"
    KERNEL_TREE_VALIDATOR_PYTHON_DIRECTORY_FD_OPEN="false"
    echo "Kernel-tree validator output sink does not match the trusted platform." >&2
    return 1
  fi
}

run_bound_kernel_tree_helper() {
  local status

  if ! verify_kernel_tree_validator_sink ||
     ! verify_kernel_baseline_control_state; then
    return 1
  fi
  if [ "$host_os" = Darwin ]; then
    # macOS /dev/fd opens share the held descriptor offset, and Python 3.9 can
    # consequently treat a nonempty /dev/fd script as empty.  The fixture-only
    # fallback compiles the exact preheld bytes without reopening their name.
    if "$KERNEL_TREE_VALIDATOR_PYTHON" -I -c '
import hashlib
import os
import stat
import sys

expected = sys.argv[1]
metadata = os.fstat(7)
if (
    not stat.S_ISREG(metadata.st_mode)
    or metadata.st_size <= 0
    or metadata.st_size > 1024 * 1024
):
    raise SystemExit(1)
content = bytearray()
offset = 0
while offset < metadata.st_size:
    chunk = os.pread(7, min(65536, metadata.st_size - offset), offset)
    if not chunk:
        raise SystemExit(1)
    content.extend(chunk)
    offset += len(chunk)
after = os.fstat(7)
stable = lambda value: (
    value.st_dev,
    value.st_ino,
    value.st_mode,
    value.st_size,
    value.st_mtime_ns,
    value.st_ctime_ns,
    value.st_nlink,
)
if stable(metadata) != stable(after) or hashlib.sha256(content).hexdigest() != expected:
    raise SystemExit(1)
arguments = sys.argv[2:]
sys.argv = ["<held-kernel-tree-validator>", *arguments]
namespace = {
    "__name__": "__main__",
    "__file__": "<held-kernel-tree-validator>",
    "__package__": None,
    "__spec__": None,
    "__cached__": None,
}
exec(compile(bytes(content), "<held-kernel-tree-validator>", "exec"), namespace)
' "$KERNEL_TREE_VALIDATOR_HELPER_SHA256" "$@" 2>&9; then
      status=0
    else
      status=$?
    fi
  elif "$KERNEL_TREE_VALIDATOR_PYTHON" -I "$KERNEL_TREE_VALIDATOR_HELPER" \
      "$@" 2>&9; then
    status=0
  else
    status=$?
  fi
  if ! verify_kernel_tree_validator_sink ||
     ! verify_kernel_baseline_control_state; then
    return 1
  fi
  return "$status"
}

split_stream_fingerprint() {
  local value="$1" size digest

  case "$value" in
    *$'\t'*) ;;
    *) return 1 ;;
  esac
  size="${value%%$'\t'*}"
  digest="${value#*$'\t'}"
  [[ "$size" =~ ^(0|[1-9][0-9]*)$ ]] &&
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n%s\n' "$size" "$digest"
}

validate_release_kernel_tree_symlinks() {
  local tree_id="$1" status

  [ "$RELEASE_BUILD" = "true" ] || return 0
  if ! [[ "$tree_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    echo "Cannot validate a non-canonical patched kernel tree ID." >&2
    return 1
  fi
  if ! verify_kernel_baseline_control_state; then
    echo "Committed kernel tree-symlink validator control changed before use." >&2
    return 1
  fi
  if ! verify_kernel_tree_validator_sink; then
    echo "Kernel-tree validator output sink changed before use." >&2
    return 1
  fi
  if (
    ulimit -f 128
    run_bound_kernel_tree_helper \
      --repo "$source_dir" \
      --tree "$tree_id" \
      --scratch-parent "$BASELINE_CONTROL_PARENT" \
      --quiet 1>&9 2>&9
  ); then
    status=0
  else
    status=$?
  fi
  if ! verify_kernel_tree_validator_sink; then
    echo "Kernel-tree validator output sink changed during use." >&2
    return 1
  fi
  if ! verify_kernel_baseline_control_state; then
    echo "Committed kernel tree-symlink validator control changed during use." >&2
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    echo "Exact patched kernel tree symlink-containment preflight failed." >&2
    return 1
  fi
  if ! verify_kernel_tree_validator_sink ||
     ! verify_kernel_baseline_control_state; then
    echo "Kernel tree-symlink validation authority changed before completion." >&2
    return 1
  fi
  echo "Validated exact patched kernel tree symlink containment: $tree_id"
}

preflight_release_patched_tree_symlinks() {
  local preliminary_tree="" capture_status=0 restore_status=0

  [ "$RELEASE_BUILD" = "true" ] || return 0
  # The release clone is required to start with HEAD in its real index. Use
  # that source-owned index before any package rule runs, then restore HEAD in
  # every outcome; this avoids a mktemp-name unlink/reopen victim window.
  if ! git -C "$source_dir" diff --cached --quiet --exit-code HEAD --; then
    echo "Preliminary kernel-tree preflight requires a pristine source index." >&2
    return 1
  fi
  RELEASE_SOURCE_INDEX_MUTATED="true"
  if ! git -C "$source_dir" add -A -f -- . ||
     ! preliminary_tree="$(git -C "$source_dir" write-tree)"; then
    capture_status=1
  fi
  if ! git -C "$source_dir" read-tree HEAD; then
    restore_status=1
  else
    RELEASE_SOURCE_INDEX_MUTATED="false"
  fi
  if [ "$capture_status" -ne 0 ] || [ "$restore_status" -ne 0 ]; then
    echo "Could not capture the preliminary patched kernel tree." >&2
    return 1
  fi
  if ! validate_release_kernel_tree_symlinks "$preliminary_tree"; then
    echo "Refusing build-dependency generation for an unsafe patched kernel tree." >&2
    return 1
  fi
}

capture_patched_tree_identity() {
  local diff_fingerprint untracked_fingerprint fingerprint_parts

  [ "$RELEASE_BUILD" = "true" ] || return 0

  if [ -e "$source_dir/.git/info/attributes" ] ||
     [ -L "$source_dir/.git/info/attributes" ]; then
    echo "Release source repository must not contain private Git attributes." >&2
    exit 1
  fi

  if ! git -C "$source_dir" diff --cached --quiet --exit-code HEAD --; then
    echo "Canonical patched-tree capture requires the source index at HEAD." >&2
    exit 1
  fi

  RELEASE_SOURCE_INDEX_MUTATED="true"
  if ! git -C "$source_dir" add -A -f -- . ||
     ! PATCHED_TREE_ID="$(git -C "$source_dir" write-tree)"; then
    echo "Could not capture the canonical patched kernel tree identity." >&2
    exit 1
  fi
  if ! validate_release_kernel_tree_symlinks "$PATCHED_TREE_ID"; then
    echo "Refusing to build from an unsafe exact patched kernel tree." >&2
    exit 1
  fi
  if ! diff_fingerprint="$(
    LC_ALL=C GIT_EXTERNAL_DIFF= \
      git -C "$source_dir" -c core.attributesFile=/dev/null \
        -c diff.suppressBlankEmpty=false --attr-source="$PATCHED_TREE_ID" diff \
        "${PATCHED_DIFF_ARGS[@]}" HEAD "$PATCHED_TREE_ID" -- 2>&9 |
      run_bound_kernel_tree_helper --stream-sha256 2147483648
  )"; then
    echo "Could not capture the canonical patched kernel diff identity." >&2
    exit 1
  fi
  if ! fingerprint_parts="$(split_stream_fingerprint "$diff_fingerprint")"; then
    echo "Canonical patched kernel diff fingerprint was malformed." >&2
    exit 1
  fi
  PATCHED_DIFF_SIZE="${fingerprint_parts%%$'\n'*}"
  PATCHED_DIFF_SHA256="${fingerprint_parts#*$'\n'}"

  if ! untracked_fingerprint="$(
    git -C "$source_dir" ls-files -z --others --exclude-standard 2>&9 |
      run_bound_kernel_tree_helper --stream-sha256 67108864
  )" || ! fingerprint_parts="$(split_stream_fingerprint "$untracked_fingerprint")"; then
    echo "Could not bind the pre-build nonignored untracked source paths." >&2
    exit 1
  fi
  PATCHED_UNTRACKED_PATHS_SIZE="${fingerprint_parts%%$'\n'*}"
  PATCHED_UNTRACKED_PATHS_SHA256="${fingerprint_parts#*$'\n'}"
  PATCHED_DIFF_GIT_VERSION="$(LC_ALL=C git --version)"

  if ! [[ "$PATCHED_TREE_ID" =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]] ||
     ! [[ "$PATCHED_DIFF_SIZE" =~ ^(0|[1-9][0-9]*)$ ]] ||
     ! [[ "$PATCHED_DIFF_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Canonical patched kernel tree identity is incomplete." >&2
    exit 1
  fi
}

verify_patched_tree_stable() {
  local current_index_tree deleted_status recomputed_tree source_head
  local diff_fingerprint untracked_fingerprint fingerprint_parts
  local recomputed_diff_size recomputed_diff_sha post_untracked_size post_untracked_sha

  [ "$RELEASE_BUILD" = "true" ] || return 0

  if [ -e "$source_dir/.git/info/attributes" ] ||
     [ -L "$source_dir/.git/info/attributes" ]; then
    echo "Release source repository gained private Git attributes during the build." >&2
    return 1
  fi

  if ! source_head="$(git -C "$source_dir" rev-parse --verify 'HEAD^{commit}')" ||
     [ "$source_head" != "$EXPECTED_SOURCE_COMMIT" ]; then
    echo "Kernel source HEAD changed during the release build." >&2
    return 1
  fi

  if ! current_index_tree="$(git -C "$source_dir" write-tree)" ||
     [ "$current_index_tree" != "$PATCHED_TREE_ID" ]; then
    echo "The exact release source index changed during the build." >&2
    return 1
  fi

  if ! untracked_fingerprint="$(
    git -C "$source_dir" ls-files -z --others --exclude-standard 2>&9 |
      run_bound_kernel_tree_helper --stream-sha256 67108864
  )" || ! fingerprint_parts="$(split_stream_fingerprint "$untracked_fingerprint")"; then
    echo "Could not inspect post-build nonignored untracked source paths." >&2
    return 1
  fi
  post_untracked_size="${fingerprint_parts%%$'\n'*}"
  post_untracked_sha="${fingerprint_parts#*$'\n'}"
  if [ "$post_untracked_size" != "$PATCHED_UNTRACKED_PATHS_SIZE" ] ||
     [ "$post_untracked_sha" != "$PATCHED_UNTRACKED_PATHS_SHA256" ]; then
    echo "A nonignored source path was added or removed during the release build." >&2
    return 1
  fi

  # A patched tree can intentionally delete a path from HEAD. Such a path is
  # absent from the pre-build index, so check the deletion contract explicitly
  # before refreshing the exact pre-build path set below.
  if git -C "$source_dir" -c core.attributesFile=/dev/null \
      diff-tree -r -z --no-commit-id --name-only --no-ext-diff --no-textconv \
      --diff-filter=D HEAD "$PATCHED_TREE_ID" -- 2>&9 |
      run_bound_kernel_tree_helper --check-deleted-paths "$source_dir" \
        --max-input-bytes 67108864 1>&9; then
    deleted_status=0
  else
    deleted_status=$?
  fi
  if [ "$deleted_status" -ne 0 ]; then
    echo "Could not verify paths deleted by the captured patched tree." >&2
    return 1
  fi

  if ! git -C "$source_dir" add -u -- . ||
     ! recomputed_tree="$(git -C "$source_dir" write-tree)"; then
    echo "Could not recompute the exact pre-build kernel source contract." >&2
    return 1
  fi
  if ! validate_release_kernel_tree_symlinks "$recomputed_tree"; then
    echo "Recomputed patched kernel tree failed symlink-containment validation." >&2
    return 1
  fi
  if ! diff_fingerprint="$(
    LC_ALL=C GIT_EXTERNAL_DIFF= \
      git -C "$source_dir" -c core.attributesFile=/dev/null \
        -c diff.suppressBlankEmpty=false --attr-source="$recomputed_tree" diff \
        "${PATCHED_DIFF_ARGS[@]}" HEAD "$recomputed_tree" -- 2>&9 |
      run_bound_kernel_tree_helper --stream-sha256 2147483648
  )" || ! fingerprint_parts="$(split_stream_fingerprint "$diff_fingerprint")"; then
    echo "Could not recompute the canonical patched kernel diff identity." >&2
    return 1
  fi
  recomputed_diff_size="${fingerprint_parts%%$'\n'*}"
  recomputed_diff_sha="${fingerprint_parts#*$'\n'}"

  if [ "$recomputed_tree" != "$PATCHED_TREE_ID" ] ||
     [ "$recomputed_diff_size" != "$PATCHED_DIFF_SIZE" ] ||
     [ "$recomputed_diff_sha" != "$PATCHED_DIFF_SHA256" ]; then
    echo "Patched kernel source input changed during the release build." >&2
    echo "The completed manifest will not describe a pre-build-only source identity." >&2
    return 1
  fi
  if ! git -C "$source_dir" read-tree HEAD; then
    echo "Could not restore the source index after stable-tree verification." >&2
    return 1
  fi
  RELEASE_SOURCE_INDEX_MUTATED="false"
}

write_manifest() {
  local manifest="$work_dir/sp11-kernel-build-manifest.txt"

  {
    echo "Source mode: $SOURCE_MODE"
    if [ "$SOURCE_MODE" = "apt" ]; then
      echo "Requested source package: $SOURCE_PACKAGE"
      echo "Resolved source package: $RESOLVED_SOURCE_PACKAGE"
      echo "Source version mode: $SOURCE_VERSION"
      echo "Apt source spec: $SOURCE_SPEC"
    else
      echo "Source URL: $GIT_URL"
      echo "Source ref: $GIT_BRANCH"
      echo "Expected source commit: ${EXPECTED_SOURCE_COMMIT:-not specified}"
    fi
    echo "Source directory: $source_dir"
    if [ -d "$source_dir/.git" ]; then
      echo "Source HEAD: $(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)"
    fi
    if [ -n "$PATCH_DIRS" ]; then
      echo "Patch directories: $PATCH_DIRS"
      for pd in $PATCH_DIRS; do
        echo "Patches in $pd:"
        for patch in "$pd"/*.patch; do
          [ -f "$patch" ] && echo "  - $(basename "$patch")"
        done
      done
    else
      echo "Patch directory: $PATCH_DIR"
      echo "Patches:"
      for patch in "$PATCH_DIR"/*.patch; do
        [ -f "$patch" ] && echo "  - $(basename "$patch")"
      done
    fi
    echo "Build target: $BUILD_TARGET"
    echo "Jobs: $JOBS"
    echo "Build container image: ${SP11_BUILD_CONTAINER_IMAGE:-not specified}"
    if command -v dpkg >/dev/null 2>&1; then
      echo "Build architecture: $(dpkg --print-architecture 2>/dev/null || echo unknown)"
    else
      echo "Build architecture: unknown"
    fi
    if [ "$(id -u)" -eq 0 ]; then
      echo "Rules runner: direct-root"
    elif [ "$NO_FAKEROOT" = "true" ]; then
      echo "Rules runner: no-fakeroot-requested-non-root"
    else
      echo "Rules runner: fakeroot"
    fi
    if command -v dpkg-query >/dev/null 2>&1; then
      echo "Installed package inventory:"
      dpkg-query -W -f='${binary:Package}=${Version}\n' 2>/dev/null |
        LC_ALL=C sort |
        sed 's/^/  - /'
    else
      echo "Installed package inventory: unavailable"
    fi
  } > "$manifest"

  echo "Wrote build manifest: $manifest"
}

collect_kernel_debs() {
  {
    find "$source_parent" -maxdepth 2 -type f \
      \( -name 'linux-image-unsigned-*-qcom-x1e_*.deb' \
      -o -name 'linux-image-*-qcom-x1e_*.deb' \
      -o -name 'linux-modules-*-qcom-x1e_*.deb' \
      -o -name 'linux-modules-extra-*-qcom-x1e_*.deb' \
      -o -name 'linux-headers-*-qcom-x1e_*.deb' \
      -o -name 'linux-qcom-x1e-headers-*_*.deb' \
      -o -name 'linux-qcom-x1e_*.deb' \
      -o -name 'linux-image-qcom-x1e_*.deb' \
      -o -name 'linux-headers-qcom-x1e_*.deb' \)
    find "$work_dir" -maxdepth 2 -type f \
      \( -name 'linux-image-unsigned-*-qcom-x1e_*.deb' \
      -o -name 'linux-image-*-qcom-x1e_*.deb' \
      -o -name 'linux-modules-*-qcom-x1e_*.deb' \
      -o -name 'linux-modules-extra-*-qcom-x1e_*.deb' \
      -o -name 'linux-headers-*-qcom-x1e_*.deb' \
      -o -name 'linux-qcom-x1e-headers-*_*.deb' \
      -o -name 'linux-qcom-x1e_*.deb' \
      -o -name 'linux-image-qcom-x1e_*.deb' \
      -o -name 'linux-headers-qcom-x1e_*.deb' \)
  } |
    LC_ALL=C sort -u
}

assert_release_package_output_pristine() {
  local existing_debs

  [ "$RELEASE_BUILD" = "true" ] || return 0

  if ! existing_debs="$(collect_kernel_debs)"; then
    echo "Could not inspect the release work directory for prior package output." >&2
    return 1
  fi
  if [ -n "$existing_debs" ]; then
    echo "Release work directory contains prior qcom-x1e kernel package output." >&2
    echo "Use a clean release work directory so stale packages cannot satisfy the release contract." >&2
    return 1
  fi
}

deb_kernel_abi() {
  local base abi
  base="$(basename "$1")"

  case "$base" in
    linux-image-unsigned-*-qcom-x1e_*.deb)
      abi="${base#linux-image-unsigned-}"
      abi="${abi%%_*}"
      ;;
    linux-image-*-qcom-x1e_*.deb)
      abi="${base#linux-image-}"
      abi="${abi%%_*}"
      ;;
    *)
      return 0
      ;;
  esac

  case "$abi" in
    [0-9]*-qcom-x1e) printf '%s\n' "$abi" ;;
  esac
}

touchscreen_target_release() {
  local deb abi found=""

  for deb in "$@"; do
    abi="$(deb_kernel_abi "$deb")"
    case "$abi" in
      *sp11v3*-qcom-x1e)
        if [ -n "$found" ] && [ "$found" != "$abi" ]; then
          echo "Mixed touchscreen kernel ABIs in one install: $found and $abi." >&2
          return 1
        fi
        found="$abi"
        ;;
    esac
  done

  printf '%s\n' "$found"
}

resolve_touchscreen_modules_dir() {
  local candidate
  local -a candidates=()

  if [ -n "$TOUCHSCREEN_MODULES_DIR" ]; then
    candidates+=("$TOUCHSCREEN_MODULES_DIR")
  else
    candidates+=("$work_dir/touchscreen-modules" "$work_dir")
  fi

  for candidate in "${candidates[@]}"; do
    [ -d "$candidate" ] || continue
    if [ -s "$candidate/gpi.ko" ] && \
      [ -s "$candidate/spi-geni-qcom.ko" ] && \
      [ -s "$candidate/mshw0485_touch.ko" ]; then
      (cd "$candidate" && pwd -P)
      return 0
    fi
  done

  return 1
}

validate_touchscreen_modules_dir() {
  local directory="$1"
  local release="$2"
  local index module_path actual_name vermagic module_release srcversion
  local -a module_files=(gpi.ko spi-geni-qcom.ko mshw0485_touch.ko)
  local -a module_names=(gpi spi_geni_qcom mshw0485_touch)

  require_tool modinfo
  require_tool grep

  for index in "${!module_files[@]}"; do
    module_path="$directory/${module_files[index]}"
    if [ ! -f "$module_path" ] || [ -L "$module_path" ]; then
      echo "Touchscreen module must be a regular, non-symlinked file: $module_path" >&2
      return 1
    fi

    actual_name="$(modinfo -F name "$module_path" 2>/dev/null || true)"
    if [ "$actual_name" != "${module_names[index]}" ]; then
      echo "Unexpected module name in ${module_files[index]}: ${actual_name:-unknown}; expected ${module_names[index]}." >&2
      return 1
    fi

    vermagic="$(modinfo -F vermagic "$module_path" 2>/dev/null || true)"
    module_release="${vermagic%%[[:space:]]*}"
    if [ "$module_release" != "$release" ]; then
      echo "${module_files[index]} targets ${module_release:-unknown}, expected $release." >&2
      return 1
    fi

    srcversion="$(modinfo -F srcversion "$module_path" 2>/dev/null || true)"
    if [[ ! "$srcversion" =~ ^[0-9A-Fa-f]+$ ]]; then
      echo "${module_files[index]} has no valid source-version identity." >&2
      return 1
    fi
  done

  if ! modinfo -p "$directory/spi-geni-qcom.ko" 2>/dev/null |
       grep -q '^sp11_windows_se_init:'; then
    echo "spi-geni-qcom.ko is not the required SP11 controller override." >&2
    return 1
  fi
  if ! modinfo -F alias "$directory/mshw0485_touch.ko" 2>/dev/null |
       grep -q 'microsoft,mshw0485'; then
    echo "mshw0485_touch.ko lacks the Surface Pro 11 device-tree alias." >&2
    return 1
  fi

  echo "Verified the exact-ABI touchscreen module bundle before package installation."
}

installed_kernel_abis() {
  local status pkg abi

  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
    'linux-image-*-qcom-x1e' \
    'linux-image-unsigned-*-qcom-x1e' 2>/dev/null |
    while read -r status pkg; do
      case "$status" in
        ?i*) ;;
        *) continue ;;
      esac
      case "$pkg" in
        linux-image-unsigned-*)
          abi="${pkg#linux-image-unsigned-}"
          ;;
        linux-image-*)
          abi="${pkg#linux-image-}"
          ;;
        *)
          continue
          ;;
      esac
      case "$abi" in
        [0-9]*-qcom-x1e) printf '%s\n' "$abi" ;;
      esac
    done |
    sort -u
}

ensure_kernel_fallback() {
  local target_abis installed_abis fallback_abi deb abi

  [ "$ALLOW_NO_FALLBACK" = "true" ] && return 0

  target_abis="$(
    for deb in "$@"; do
      deb_kernel_abi "$deb"
    done | sort -u
  )"
  # Headers/modules-only transactions do not replace a bootable kernel image.
  [ -n "$target_abis" ] || return 0

  installed_abis="$(installed_kernel_abis || true)"
  fallback_abi=""
  while IFS= read -r abi; do
    [ -n "$abi" ] || continue
    if ! printf '%s\n' "$target_abis" | grep -Fxq "$abi"; then
      fallback_abi="$abi"
      break
    fi
  done <<<"$installed_abis"

  if [ -z "$fallback_abi" ]; then
    echo "Refusing to install generated qcom-x1e kernel packages without an installed fallback ABI." >&2
    echo "Generated image ABI/ABIs:" >&2
    printf '%s\n' "$target_abis" | sed 's/^/  - /' >&2
    echo "Installed qcom-x1e image ABI/ABIs:" >&2
    if [ -n "$installed_abis" ]; then
      printf '%s\n' "$installed_abis" | sed 's/^/  - /' >&2
    else
      echo "  - none detected" >&2
    fi
    echo "Keep or install an older known-good qcom-x1e kernel first, or pass --allow-no-fallback if you accept live-USB recovery as the fallback." >&2
    exit 1
  fi

  echo "Found installed fallback qcom-x1e kernel ABI: $fallback_abi"
}

ensure_header_dependencies_present() {
  local deb base abi common_pkg common_found

  for deb in "$@"; do
    base="$(basename "$deb")"
    case "$base" in
      linux-headers-*-qcom-x1e_*.deb)
        abi="${base#linux-headers-}"
        abi="${abi%%-qcom-x1e_*}"
        common_pkg="linux-qcom-x1e-headers-${abi}_"
        common_found="false"
        for candidate in "$@"; do
          case "$(basename "$candidate")" in
            "${common_pkg}"*_all.deb)
              common_found="true"
              break
              ;;
          esac
        done
        if [ "$common_found" != "true" ]; then
          echo "Missing common qcom-x1e headers package for $base." >&2
          echo "Expected a local package matching: ${common_pkg}*_all.deb" >&2
          echo "Rebuild the payload with:" >&2
          echo "  --build-target \"binary-indep binary-qcom-x1e\"" >&2
          echo "For boot-only recovery, install the linux-image and linux-modules packages without linux-headers." >&2
          exit 1
        fi
        ;;
    esac
  done
}

write_deb_manifest() {
  [ "$RELEASE_BUILD" = "true" ] && return 0
  collect_kernel_debs > "$work_dir/sp11-kernel-debs.txt"
}

add_release_output() {
  local role="$1" relative_path="$2" absolute_path

  absolute_path="$source_dir/$relative_path"
  if [ ! -f "$absolute_path" ] || [ ! -s "$absolute_path" ] || [ -L "$absolute_path" ]; then
    echo "Required release build output is missing, empty, or not a regular file: $relative_path" >&2
    return 1
  fi
  RELEASE_OUTPUT_ROLES+=("$role")
  RELEASE_OUTPUT_PATHS+=("$relative_path")
  RELEASE_OUTPUT_SIZES+=("$(file_size "$absolute_path")")
  RELEASE_OUTPUT_SHA256S+=("$(sha256_file "$absolute_path")")
}

capture_signing_certificate_identity() {
  local certificate="$source_dir/debian/build/build-qcom-x1e/certs/signing_key.x509"
  local fingerprint_output serial_output certificate_format

  require_tool openssl
  SIGNING_CERT_SHA256="$(sha256_file "$certificate")"
  certificate_format="DER"
  if ! fingerprint_output="$(openssl x509 -inform DER -in "$certificate" -noout -sha256 -fingerprint 2>/dev/null)"; then
    certificate_format="PEM"
    fingerprint_output="$(openssl x509 -inform PEM -in "$certificate" -noout -sha256 -fingerprint)"
  fi
  serial_output="$(openssl x509 -inform "$certificate_format" -in "$certificate" -noout -serial)"
  SIGNING_CERT_FINGERPRINT="${fingerprint_output#*=}"
  SIGNING_CERT_FINGERPRINT="$(printf '%s' "$SIGNING_CERT_FINGERPRINT" | tr '[:lower:]' '[:upper:]')"
  SIGNING_CERT_SERIAL="${serial_output#*=}"
  SIGNING_CERT_SERIAL="$(printf '%s' "$SIGNING_CERT_SERIAL" | tr '[:lower:]' '[:upper:]')"

  if ! [[ "$SIGNING_CERT_FINGERPRINT" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]]; then
    echo "Could not extract a valid public X.509 SHA-256 fingerprint." >&2
    return 1
  fi
  if ! [[ "$SIGNING_CERT_SERIAL" =~ ^[0-9A-F]+$ ]]; then
    echo "Could not extract a valid public X.509 serial number." >&2
    return 1
  fi
}

capture_release_build_outputs() {
  local build_root="debian/build/build-qcom-x1e"

  add_release_output "kernel-config" "$build_root/.config"
  add_release_output "module-symvers" "$build_root/Module.symvers"
  add_release_output "system-map" "$build_root/System.map"
  add_release_output "kernel-efi-stubble" "$build_root/arch/arm64/boot/vmlinuz.efi.stubble"
  add_release_output "denali-oled-dtb" "$build_root/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled.dtb"
  add_release_output "denali-oled-el2-dtb" "$build_root/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled-el2.dtb"
  add_release_output "module-signing-certificate" "$build_root/certs/signing_key.x509"
  capture_signing_certificate_identity
}

release_deb_role() {
  case "$(basename "$1")" in
    linux-qcom-x1e-headers-*_all.deb) printf '%s\n' common-headers ;;
    linux-headers-*-qcom-x1e_*.deb) printf '%s\n' headers ;;
    linux-image-unsigned-*-qcom-x1e_*.deb|linux-image-*-qcom-x1e_*.deb) printf '%s\n' image ;;
    linux-modules-extra-*-qcom-x1e_*.deb) printf '%s\n' modules-extra ;;
    linux-modules-*-qcom-x1e_*.deb) printf '%s\n' modules ;;
    *) return 1 ;;
  esac
}

release_deb_abi() {
  local role="$1" package="$2"

  case "$role:$package" in
    common-headers:linux-qcom-x1e-headers-*)
      printf '%s-qcom-x1e\n' "${package#linux-qcom-x1e-headers-}"
      ;;
    headers:linux-headers-*) printf '%s\n' "${package#linux-headers-}" ;;
    image:linux-image-unsigned-*) printf '%s\n' "${package#linux-image-unsigned-}" ;;
    image:linux-image-*) printf '%s\n' "${package#linux-image-}" ;;
    modules:linux-modules-*) printf '%s\n' "${package#linux-modules-}" ;;
    modules-extra:linux-modules-extra-*) printf '%s\n' "${package#linux-modules-extra-}" ;;
    *) return 1 ;;
  esac
}

capture_release_debs() {
  local deb role package version architecture existing_role required_role found index
  local base expected_package filename_without_arch expected_version common_version=""
  local package_abi common_abi=""

  require_tool dpkg-deb
  while IFS= read -r deb; do
    [ -n "$deb" ] || continue
    if [ ! -f "$deb" ] || [ -L "$deb" ]; then
      echo "Release package must be a regular, non-symlinked file: $deb" >&2
      return 1
    fi
    if ! role="$(release_deb_role "$deb")"; then
      echo "Unexpected package in release build output: $(basename "$deb")" >&2
      return 1
    fi
    index=0
    while [ "$index" -lt "${#RELEASE_DEB_ROLES[@]}" ]; do
      existing_role="${RELEASE_DEB_ROLES[$index]}"
      if [ "$existing_role" = "$role" ]; then
        echo "Duplicate $role package in release build output." >&2
        return 1
      fi
      index=$((index + 1))
    done

    package="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
    version="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
    architecture="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"
    if [ -z "$package" ] || [ -z "$version" ] || [ -z "$architecture" ]; then
      echo "Could not read package identity from $(basename "$deb")." >&2
      return 1
    fi
    base="$(basename "$deb")"
    expected_package="${base%%_*}"
    if [ "$package" != "$expected_package" ]; then
      echo "Package field $package does not match release filename $base." >&2
      return 1
    fi
    filename_without_arch="${base%_${architecture}.deb}"
    expected_version="${filename_without_arch##*_}"
    if [ "$version" != "$expected_version" ]; then
      echo "Version field $version does not match release filename $base." >&2
      return 1
    fi
    if [ -z "$common_version" ]; then
      common_version="$version"
    elif [ "$version" != "$common_version" ]; then
      echo "Release build output contains mixed package versions: $common_version and $version." >&2
      return 1
    fi
    if ! package_abi="$(release_deb_abi "$role" "$package")"; then
      echo "Package $package does not match its release role $role." >&2
      return 1
    fi
    if [ -z "$common_abi" ]; then
      common_abi="$package_abi"
    elif [ "$package_abi" != "$common_abi" ]; then
      echo "Release build output contains mixed kernel ABIs: $common_abi and $package_abi." >&2
      return 1
    fi
    if ! [[ "$package" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] ||
       ! [[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] ||
       ! [[ "$architecture" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "Package identity contains unsafe or unsupported characters in $(basename "$deb")." >&2
      return 1
    fi
    case "$role:$architecture" in
      common-headers:all|headers:arm64|image:arm64|modules:arm64|modules-extra:arm64) ;;
      *)
        echo "Unexpected architecture $architecture for $role package $(basename "$deb")." >&2
        return 1
        ;;
    esac

    RELEASE_DEB_ROLES+=("$role")
    RELEASE_DEB_PATHS+=("$(basename "$deb")")
    RELEASE_DEB_PACKAGES+=("$package")
    RELEASE_DEB_VERSIONS+=("$version")
    RELEASE_DEB_ARCHITECTURES+=("$architecture")
    RELEASE_DEB_SIZES+=("$(file_size "$deb")")
    RELEASE_DEB_SHA256S+=("$(sha256_file "$deb")")
  done < <(collect_kernel_debs)

  for required_role in common-headers headers image modules; do
    found="false"
    for existing_role in "${RELEASE_DEB_ROLES[@]}"; do
      [ "$existing_role" = "$required_role" ] && found="true"
    done
    if [ "$found" != "true" ]; then
      echo "Release build is missing the required $required_role package." >&2
      return 1
    fi
  done
}

acquire_release_output_descriptors() {
  local opener_job_pid opener_pid opener_deb_fd opener_manifest_fd
  local opener_protocol opener_endpoint opener_token
  local deb_dev deb_ino manifest_dev manifest_ino marker extra

  release_output_opener_control() {
    local action="$1" acknowledgement=""

    if [ "$opener_protocol" = fixture-delay ]; then
      [ "$action" = ABORT ] && return 0
      if ! IFS= read -r acknowledgement <&12 ||
         [ "$acknowledgement" != TRANSFERRED ]; then
        return 1
      fi
      return 0
    fi

    "$KERNEL_TREE_VALIDATOR_PYTHON" -I -c '
import os
import socket
import struct
import sys

protocol, endpoint, token, expected_pid, action = sys.argv[1:]
if action not in ("TRANSFER", "ABORT"):
    raise SystemExit(1)
if protocol == "unix" and sys.platform.startswith("linux"):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    address = b"\0" + bytes.fromhex(endpoint)
elif protocol == "unix-fixture" and sys.platform == "darwin":
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    os.fchdir(6)
    address = endpoint
else:
    raise SystemExit(1)
connection.settimeout(5.0)
try:
    connection.connect(address)
    if protocol == "unix":
        size = struct.calcsize("3i")
        credentials = connection.getsockopt(
            socket.SOL_SOCKET, socket.SO_PEERCRED, size
        )
        peer_pid, peer_uid, _peer_gid = struct.unpack("3i", credentials)
        if peer_pid != int(expected_pid, 10) or peer_uid != os.getuid():
            raise SystemExit(1)
    connection.sendall((action + " " + token + "\n").encode("ascii"))
    response = bytearray()
    while len(response) <= 64:
        chunk = connection.recv(65 - len(response))
        if not chunk:
            break
        response.extend(chunk)
    expected = b"TRANSFERRED\n" if action == "TRANSFER" else b"ABORTED\n"
    if bytes(response) != expected:
        raise SystemExit(1)
finally:
    connection.close()
' "$opener_protocol" "$opener_endpoint" "$opener_token" \
      "$opener_pid" "$action" 1>&9 2>&9
  }

  close_release_output_opener_channel() {
    local require_success="$1" unexpected="" wait_status=0

    if IFS= read -r unexpected <&12; then
      exec 12<&-
      release_output_opener_channel_open=false
      return 1
    fi
    exec 12<&-
    release_output_opener_channel_open=false
    if [ "$host_os" = Linux ]; then
      if wait "$opener_job_pid" 2>/dev/null; then
        wait_status=0
      else
        wait_status=$?
      fi
      if [ "$require_success" = true ] && [ "$wait_status" -ne 0 ]; then
        return 1
      fi
    fi
    release_output_opener_job_pid=""
  }

  # The release path must not use Bash noclobber as an O_EXCL substitute:
  # noclobber still opens existing FIFOs/devices.  A short trusted Python
  # owner creates both fixed names relative to held work-root FD 6 with real
  # O_EXCL|O_NOFOLLOW and keeps those exact inodes open until this shell has
  # acquired its own descriptors.  A bounded authenticated socket handshake,
  # rather than PID signalling, transfers ownership without a PID-reuse victim
  # window.  Production duplicates only through trusted procfs descriptor
  # authority; Darwin name reopening is restricted to the disposable fixture.
  exec 12< <(exec "$KERNEL_TREE_VALIDATOR_PYTHON" -I -c '
import os
import secrets
import select
import socket
import stat
import struct
import sys
import time

created = []
foreign = []
listener = None
ready = False
stage = "startup"
fixture_hook = sys.argv[1]
if fixture_hook not in (
    "",
    "swap-work-root-terminal",
    "mutate-fd10-after-primary",
    "mutate-intended-double-term-scrub",
    "inject-fifo-before-open",
    "inject-symlink-before-open",
    "inject-procfd-candidate-mismatch",
):
    raise SystemExit(1)

try:
    stage = "flags"
    required = ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC", "O_EXCL")
    if any(not hasattr(os, name) for name in required):
        raise OSError("required open flags unavailable")
    root = os.fstat(6)
    if not stat.S_ISDIR(root.st_mode):
        raise OSError("held work root is not a directory")
    old_umask = os.umask(0o077)
    try:
        stage = "open"
        if fixture_hook == "inject-fifo-before-open":
            if os.mkfifo in os.supports_dir_fd:
                os.mkfifo("sp11-kernel-debs.txt", 0o600, dir_fd=6)
            else:
                os.fchdir(6)
                os.mkfifo("sp11-kernel-debs.txt", 0o600)
        elif fixture_hook == "inject-symlink-before-open":
            os.symlink(
                ".sp11-publication-victim",
                "sp11-kernel-debs.txt",
                dir_fd=6,
            )
        flags = (
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | os.O_CLOEXEC
        )
        for name in (
            "sp11-kernel-debs.txt",
            "sp11-kernel-build-manifest.txt",
        ):
            descriptor = os.open(name, flags, 0o600, dir_fd=6)
            created.append(descriptor)
    finally:
        os.umask(old_umask)
    metadata = [os.fstat(descriptor) for descriptor in created]
    stage = "metadata"
    if any(
        not stat.S_ISREG(value.st_mode)
        or stat.S_IMODE(value.st_mode) != 0o600
        or value.st_size != 0
        or value.st_nlink != 1
        for value in metadata
    ):
        raise OSError("created release output is unsafe")
    reported = list(created)
    if fixture_hook == "inject-procfd-candidate-mismatch":
        victim = os.open(
            ".sp11-procfd-candidate-victim",
            os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=6,
        )
        victim_metadata = os.fstat(victim)
        if (
            not stat.S_ISREG(victim_metadata.st_mode)
            or stat.S_IMODE(victim_metadata.st_mode) != 0o600
            or victim_metadata.st_nlink != 1
        ):
            raise OSError("candidate mismatch fixture victim is unsafe")
        foreign.append(victim)
        reported[0] = victim
    token = secrets.token_hex(32)
    stage = "socket"
    if sys.platform.startswith("linux"):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        address = b"\0sp11-release-output-" + secrets.token_bytes(16)
        listener.bind(address)
        protocol = "unix"
        endpoint = address[1:].hex()
    elif sys.platform == "darwin":
        # The macOS provenance fixture runs in a socket-restricted sandbox.
        # It receives no production authority: keep the exact O_EXCL-created
        # inodes open for a short bounded handoff and acknowledge on the
        # already-owned stdout pipe. Production Linux uses authenticated
        # abstract AF_UNIX peer credentials below.
        protocol = "fixture-delay"
        endpoint = "none"
    else:
        raise OSError("unsupported release output platform")
    if listener is not None:
        listener.listen(4)
        listener.settimeout(0.1)
        liveness = select.poll()
        liveness.register(1, select.POLLERR | select.POLLHUP | select.POLLNVAL)
    readiness = "READY {} {} {} {} {} {} {} {} {} {}\n".format(
        os.getpid(),
        protocol,
        endpoint,
        token,
        reported[0],
        reported[1],
        metadata[0].st_dev,
        metadata[0].st_ino,
        metadata[1].st_dev,
        metadata[1].st_ino,
    ).encode("ascii")
    os.write(1, readiness)
    ready = True
    if protocol == "fixture-delay":
        time.sleep(0.1)
        for descriptor in created:
            os.close(descriptor)
        created.clear()
        os.write(1, b"TRANSFERRED\n")
        raise SystemExit(0)
    deadline = time.monotonic() + 30.0
    attempts = 0
    while time.monotonic() < deadline and attempts < 8:
        if liveness.poll(0):
            raise OSError("release output owner disappeared")
        try:
            connection, _address = listener.accept()
        except socket.timeout:
            continue
        attempts += 1
        try:
            connection.settimeout(2.0)
            if protocol == "unix":
                size = struct.calcsize("3i")
                credentials = connection.getsockopt(
                    socket.SOL_SOCKET, socket.SO_PEERCRED, size
                )
                _peer_pid, peer_uid, _peer_gid = struct.unpack(
                    "3i", credentials
                )
                if peer_uid != os.getuid():
                    continue
            request = bytearray()
            while len(request) <= 128 and b"\n" not in request:
                chunk = connection.recv(129 - len(request))
                if not chunk:
                    break
                request.extend(chunk)
            transfer_request = ("TRANSFER " + token + "\n").encode("ascii")
            abort_request = ("ABORT " + token + "\n").encode("ascii")
            if bytes(request) == transfer_request:
                for descriptor in created:
                    os.close(descriptor)
                created.clear()
                connection.sendall(b"TRANSFERRED\n")
                raise SystemExit(0)
            if bytes(request) == abort_request:
                for descriptor in created:
                    os.ftruncate(descriptor, 0)
                    os.fsync(descriptor)
                    os.close(descriptor)
                created.clear()
                connection.sendall(b"ABORTED\n")
                raise SystemExit(1)
        finally:
            connection.close()
    raise OSError("release output ownership transfer timed out")
except SystemExit:
    raise
except BaseException:
    for descriptor in created:
        try:
            os.ftruncate(descriptor, 0)
            os.fsync(descriptor)
        except OSError:
            pass
        try:
            os.close(descriptor)
        except OSError:
            pass
    if not ready:
        try:
            os.write(1, ("ERROR " + stage + "\n").encode("ascii"))
        except OSError:
            pass
    raise SystemExit(1)
finally:
    if listener is not None:
        listener.close()
    for descriptor in foreign:
        try:
            os.close(descriptor)
        except OSError:
            pass
' "$publication_fixture_hook" 2>&9)
  release_output_opener_channel_open=true
  opener_job_pid=$!
  release_output_opener_job_pid="$opener_job_pid"
  if ! IFS=' ' read -r marker opener_pid opener_protocol opener_endpoint \
      opener_token opener_deb_fd opener_manifest_fd deb_dev deb_ino \
      manifest_dev manifest_ino extra <&12 ||
     [ "$marker" != READY ] || [ -n "$extra" ] ||
     ! [[ "$opener_job_pid" =~ ^[1-9][0-9]*$ ]] ||
     [ "$opener_pid" != "$opener_job_pid" ] ||
     ! [[ "$opener_protocol" =~ ^(unix|fixture-delay)$ ]] ||
     ! [[ "$opener_endpoint" =~ ^[A-Za-z0-9.-]+$ ]] ||
     ! [[ "$opener_token" =~ ^[0-9a-f]{64}$ ]] ||
     ! [[ "$opener_deb_fd" =~ ^[0-9]+$ ]] ||
     ! [[ "$opener_manifest_fd" =~ ^[0-9]+$ ]] ||
     ! [[ "$deb_dev" =~ ^[0-9]+$ ]] || ! [[ "$deb_ino" =~ ^[0-9]+$ ]] ||
     ! [[ "$manifest_dev" =~ ^[0-9]+$ ]] ||
     ! [[ "$manifest_ino" =~ ^[0-9]+$ ]]; then
    close_release_output_opener_channel false || :
    echo "Could not exclusively create the release output names." >&2
    return 1
  fi

  case "$host_os" in
    Linux)
      if ! exec 10<>"/proc/$opener_pid/fd/$opener_deb_fd"; then
        release_output_opener_control ABORT || :
        close_release_output_opener_channel false || :
        echo "Could not acquire the held release package-list inode." >&2
        return 1
      fi
      if ! exec 11<>"/proc/$opener_pid/fd/$opener_manifest_fd"; then
        exec 10>&-
        release_output_opener_control ABORT || :
        close_release_output_opener_channel false || :
        echo "Could not acquire the held release-manifest inode." >&2
        return 1
      fi
      ;;
    Darwin)
      case "${SP11_KERNEL_RELEASE_TEST_FIXTURE:-}:$work_dir" in
        sp11-kernel-release-provenance-v1:*/sp11-apt-fixture.release-provenance.*/work-*) ;;
        *)
          release_output_opener_control ABORT || :
          close_release_output_opener_channel false || :
          echo "Darwin release-output acquisition is fixture-only." >&2
          return 1
          ;;
      esac
      if ! exec 10<>./sp11-kernel-debs.txt; then
        release_output_opener_control ABORT || :
        close_release_output_opener_channel false || :
        echo "Could not acquire the fixture release package-list inode." >&2
        return 1
      fi
      if ! exec 11<>./sp11-kernel-build-manifest.txt; then
        exec 10>&-
        release_output_opener_control ABORT || :
        close_release_output_opener_channel false || :
        echo "Could not acquire the fixture release-manifest inode." >&2
        return 1
      fi
      ;;
    *)
      release_output_opener_control ABORT || :
      close_release_output_opener_channel false || :
      echo "Release-output acquisition requires Linux." >&2
      return 1
      ;;
  esac

  if ! "$KERNEL_TREE_VALIDATOR_PYTHON" -I -c '
import os
import stat
import sys

for descriptor, name, expected_dev, expected_ino in (
    (10, "sp11-kernel-debs.txt", sys.argv[1], sys.argv[2]),
    (11, "sp11-kernel-build-manifest.txt", sys.argv[3], sys.argv[4]),
):
    metadata = os.fstat(descriptor)
    mapped = os.stat(name, dir_fd=6, follow_symlinks=False)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(mapped.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_size != 0
        or metadata.st_nlink != 1
        or (metadata.st_dev, metadata.st_ino)
        != (mapped.st_dev, mapped.st_ino)
        or str(metadata.st_dev) != expected_dev
        or str(metadata.st_ino) != expected_ino
    ):
        raise SystemExit(1)
' "$deb_dev" "$deb_ino" "$manifest_dev" "$manifest_ino" 1>&9 2>&9; then
    exec 10>&-
    exec 11>&-
    release_output_opener_control ABORT || :
    close_release_output_opener_channel false || :
    echo "Held release output ownership could not be verified." >&2
    return 1
  fi
  # Only exact descriptors that have passed the READY identity and held-name
  # checks become scrub-owned. A procfs PID/FD mismatch is merely closed above;
  # the authenticated opener remains responsible for its intended empty files.
  deb_output_open=true
  manifest_output_open=true
  if ! release_output_opener_control TRANSFER ||
     ! close_release_output_opener_channel true; then
    echo "Held release output ownership transfer failed." >&2
    return 1
  fi
}

write_release_manifest_v2() {
  local source_head container_image container_digest rules_runner
  local index publication_fixture_hook

  [ "$RELEASE_BUILD" = "true" ] || return 0

  if ! publication_fixture_hook="$(
    resolve_release_publication_fixture_hook
  )"; then
    echo "Release publication fixture hook is outside its private test boundary." >&2
    return 1
  fi

  verify_release_support_stable
  verify_patched_tree_stable
  capture_release_build_outputs
  capture_release_debs
  verify_release_support_stable

  source_head="$(git -C "$source_dir" rev-parse --verify 'HEAD^{commit}')"
  source_head="$(printf '%s' "$source_head" | tr '[:upper:]' '[:lower:]')"
  if [ "$source_head" != "$EXPECTED_SOURCE_COMMIT" ]; then
    echo "Kernel source HEAD changed during the release build." >&2
    return 1
  fi
  container_image="${SP11_BUILD_CONTAINER_IMAGE}"
  container_digest="${container_image##*@}"
  if [ "$(id -u)" -eq 0 ]; then
    rules_runner="direct-root"
  else
    rules_runner="fakeroot"
  fi

  (
    deb_output_open=false
    manifest_output_open=false
    work_output_root_open=false
    publication_committed=false
    release_output_opener_channel_open=false
    release_output_opener_job_pid=""

    cleanup_release_publication() {
      local cleanup_status=$?
      trap - EXIT
      trap '' HUP INT TERM
      if [ "$release_output_opener_channel_open" = true ]; then
        exec 12<&- || :
        release_output_opener_channel_open=false
        if [ "$host_os" = Linux ] &&
           [[ "$release_output_opener_job_pid" =~ ^[1-9][0-9]*$ ]]; then
          wait "$release_output_opener_job_pid" 2>/dev/null || cleanup_status=1
        fi
        release_output_opener_job_pid=""
      fi
      if [ "$publication_committed" != "true" ] &&
         { [ "$deb_output_open" = "true" ] ||
           [ "$manifest_output_open" = "true" ]; }; then
        scrub_held_release_outputs \
          "$deb_output_open" "$manifest_output_open" \
          "$publication_fixture_hook" || cleanup_status=1
      fi
      [ "$manifest_output_open" = "true" ] && exec 11>&-
      [ "$deb_output_open" = "true" ] && exec 10>&-
      [ "$work_output_root_open" = "true" ] && exec 6<&-
      exit "$cleanup_status"
    }
    trap cleanup_release_publication EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    cd "$work_dir"
    exec 6<.
    work_output_root_open=true
    if ! "$KERNEL_TREE_VALIDATOR_PYTHON" -I -c '
import os
import stat
import sys

metadata = os.fstat(6)
mapped = os.lstat(sys.argv[1])
identity = ":".join(str(value) for value in (
    metadata.st_dev,
    metadata.st_ino,
    format(stat.S_IMODE(metadata.st_mode), "o"),
    metadata.st_uid,
    metadata.st_gid,
))
if (
    not stat.S_ISDIR(metadata.st_mode)
    or stat.S_ISLNK(mapped.st_mode)
    or (metadata.st_dev, metadata.st_ino) != (mapped.st_dev, mapped.st_ino)
    or identity != sys.argv[2]
):
    raise SystemExit(1)
' "$work_dir" "$WORK_DIR_IDENTITY" 1>&9 2>&9; then
      echo "Release work directory identity changed before publication." >&2
      exit 1
    fi

    acquire_release_output_descriptors || exit 1

    if ! deb_list_fingerprint="$(
      printf '%s\n' "${RELEASE_DEB_PATHS[@]}" |
        run_bound_kernel_tree_helper --copy-sha256-to-fd 10 \
          --max-input-bytes 1048576
    )" || ! split_stream_fingerprint "$deb_list_fingerprint" >/dev/null; then
      echo "Could not write the held release package list." >&2
      exit 1
    fi
    if ! manifest_fingerprint="$(
      {
      echo "Provenance schema: sp11-kernel-build-v2"
      echo "Release build: true"
      echo "Support start HEAD: $SUPPORT_HEAD_START"
      echo "Support start dirty: false"
      echo "Support end HEAD: $SUPPORT_HEAD_START"
      echo "Support end dirty: false"
      echo "Source mode: git"
      echo "Source URL: $GIT_URL"
      echo "Source ref: $GIT_BRANCH"
      echo "Expected source commit: $EXPECTED_SOURCE_COMMIT"
      echo "Source HEAD: $source_head"
      echo "Container image: $container_image"
      echo "Container digest: $container_digest"
      echo "Container platform: ${SP11_BUILD_CONTAINER_PLATFORM}"
      echo "Build target: $BUILD_TARGET"
      echo "Jobs: $JOBS"
      echo "Rules runner: $rules_runner"
      echo "Patch count: ${#RELEASE_PATCH_PATHS[@]}"
      index=0
      while [ "$index" -lt "${#RELEASE_PATCH_PATHS[@]}" ]; do
        echo "Patch $((index + 1)) path: ${RELEASE_PATCH_PATHS[$index]}"
        echo "Patch $((index + 1)) SHA256: ${RELEASE_PATCH_SHA256S[$index]}"
        echo "Patch $((index + 1)) disposition: ${RELEASE_PATCH_DISPOSITIONS[$index]}"
        index=$((index + 1))
      done
      echo "Patched diff format: $PATCHED_DIFF_FORMAT"
      echo "Patched diff Git version: $PATCHED_DIFF_GIT_VERSION"
      echo "Patched diff SHA256: $PATCHED_DIFF_SHA256"
      echo "Patched tree ID: $PATCHED_TREE_ID"
      echo "Required output roles: kernel-config module-symvers system-map kernel-efi-stubble denali-oled-dtb denali-oled-el2-dtb module-signing-certificate"
      echo "Optional output roles: none"
      echo "Output count: ${#RELEASE_OUTPUT_PATHS[@]}"
      index=0
      while [ "$index" -lt "${#RELEASE_OUTPUT_PATHS[@]}" ]; do
        echo "Output $((index + 1)) role: ${RELEASE_OUTPUT_ROLES[$index]}"
        echo "Output $((index + 1)) required: true"
        echo "Output $((index + 1)) path: ${RELEASE_OUTPUT_PATHS[$index]}"
        echo "Output $((index + 1)) size: ${RELEASE_OUTPUT_SIZES[$index]}"
        echo "Output $((index + 1)) SHA256: ${RELEASE_OUTPUT_SHA256S[$index]}"
        index=$((index + 1))
      done
      echo "Signing certificate SHA256: $SIGNING_CERT_SHA256"
      echo "Signing certificate fingerprint: $SIGNING_CERT_FINGERPRINT"
      echo "Signing certificate serial: $SIGNING_CERT_SERIAL"
      echo "Required Deb roles: common-headers headers image modules"
      echo "Optional Deb roles: modules-extra"
      echo "Deb count: ${#RELEASE_DEB_PATHS[@]}"
      index=0
      while [ "$index" -lt "${#RELEASE_DEB_PATHS[@]}" ]; do
        echo "Deb $((index + 1)) role: ${RELEASE_DEB_ROLES[$index]}"
        if [ "${RELEASE_DEB_ROLES[$index]}" = "modules-extra" ]; then
          echo "Deb $((index + 1)) required: false"
        else
          echo "Deb $((index + 1)) required: true"
        fi
        echo "Deb $((index + 1)) path: ${RELEASE_DEB_PATHS[$index]}"
        echo "Deb $((index + 1)) package: ${RELEASE_DEB_PACKAGES[$index]}"
        echo "Deb $((index + 1)) version: ${RELEASE_DEB_VERSIONS[$index]}"
        echo "Deb $((index + 1)) architecture: ${RELEASE_DEB_ARCHITECTURES[$index]}"
        echo "Deb $((index + 1)) size: ${RELEASE_DEB_SIZES[$index]}"
        echo "Deb $((index + 1)) SHA256: ${RELEASE_DEB_SHA256S[$index]}"
        index=$((index + 1))
      done
      echo "Build completed: true"
      } | run_bound_kernel_tree_helper --copy-sha256-to-fd 11 \
        --max-input-bytes 4194304
    )" || ! split_stream_fingerprint "$manifest_fingerprint" >/dev/null; then
      echo "Could not write the held schema-v2 release build manifest." >&2
      exit 1
    fi

    first_publication_state="$(
      held_release_output_state "$work_dir" "$WORK_DIR_IDENTITY" true \
        "$deb_list_fingerprint" "$manifest_fingerprint" \
        "$publication_fixture_hook"
    )" || {
      echo "Could not seal the held release outputs." >&2
      exit 1
    }
    verify_release_support_stable || exit 1
    verify_kernel_baseline_control_state || exit 1
    verify_kernel_tree_validator_sink || exit 1
    final_publication_state="$(
      held_release_output_state "$work_dir" "$WORK_DIR_IDENTITY" false \
        "$deb_list_fingerprint" "$manifest_fingerprint" \
        "$publication_fixture_hook"
    )" || {
      echo "Release output mapping changed before completion." >&2
      exit 1
    }
    if [ "$final_publication_state" != "$first_publication_state" ]; then
      echo "Held release output bytes changed during final validation." >&2
      exit 1
    fi

    # At this point both exact descriptors, their final names, the pinned work
    # root, and support provenance have been revalidated. Treat later terminal
    # signals as arriving after the publication commit boundary.
    trap '' HUP INT TERM
    publication_committed=true
    exec 11>&-
    manifest_output_open=false
    exec 10>&-
    deb_output_open=false
    exec 6<&-
    work_output_root_open=false
    trap - EXIT
    echo "Wrote completed schema-v2 release build manifest: $work_dir/sp11-kernel-build-manifest.txt"
  )
}

build_kernel() {
  local rules_file target build_targets=()
  rules_file="$(find_rules_file)"
  read -r -a build_targets <<<"$BUILD_TARGET"
  if [ "${#build_targets[@]}" -eq 0 ]; then
    echo "No build target specified." >&2
    exit 2
  fi

  (
    cd "$source_dir"
    export DEB_BUILD_OPTIONS="parallel=$JOBS nocheck noautodbgsym"
    if [ "$SKIP_CLEAN" != "true" ]; then
      run_rules "$rules_file" clean
    fi
    for target in "${build_targets[@]}"; do
      run_rules "$rules_file" "$target"
    done
  )
}

install_kernel_debs() {
  require_tool dpkg-query

  local debs=() touchscreen_release="" touchscreen_dir=""
  if [ -f "$work_dir/sp11-kernel-debs.txt" ]; then
    while IFS= read -r deb; do
      [ -f "$deb" ] && debs+=("$deb")
    done < "$work_dir/sp11-kernel-debs.txt"
  fi
  if [ "${#debs[@]}" -eq 0 ]; then
    while IFS= read -r deb; do
      debs+=("$deb")
    done < <(collect_kernel_debs)
  fi

  if [ "${#debs[@]}" -eq 0 ]; then
    echo "No qcom-x1e kernel debs found under $work_dir." >&2
    exit 1
  fi

  printf 'Installing generated kernel debs:\n'
  printf '  %s\n' "${debs[@]}"
  ensure_header_dependencies_present "${debs[@]}"
  ensure_kernel_fallback "${debs[@]}"

  touchscreen_release="$(touchscreen_target_release "${debs[@]}")"
  if [ -n "$touchscreen_release" ]; then
    if [ "$SKIP_TOUCHSCREEN_MODULES" = "true" ]; then
      echo "Warning: installing $touchscreen_release without its required touchscreen module bundle." >&2
      echo "Touch will remain unavailable until install-sp11-touchscreen.sh completes." >&2
    else
      touchscreen_dir="$(resolve_touchscreen_modules_dir || true)"
      if [ -z "$touchscreen_dir" ]; then
        echo "Refusing an incomplete $touchscreen_release installation." >&2
        echo "The v3 kernel device tree requires a matching module bundle containing:" >&2
        echo "  - gpi.ko" >&2
        echo "  - spi-geni-qcom.ko" >&2
        echo "  - mshw0485_touch.ko" >&2
        echo "Place them in $work_dir, use --touchscreen-modules-dir DIR, or explicitly pass --skip-touchscreen-modules." >&2
        exit 1
      fi
      if [ ! -x "$repo_dir/scripts/install-sp11-touchscreen.sh" ]; then
        echo "Missing guarded touchscreen installer: $repo_dir/scripts/install-sp11-touchscreen.sh" >&2
        exit 1
      fi
      validate_touchscreen_modules_dir "$touchscreen_dir" "$touchscreen_release" || exit 1
      echo "Found matching touchscreen module bundle: $touchscreen_dir"
    fi
  elif [ -n "$TOUCHSCREEN_MODULES_DIR" ]; then
    echo "--touchscreen-modules-dir was supplied, but this transaction has no sp11v3 kernel image." >&2
    exit 1
  fi

  if [ ! -x "$repo_dir/scripts/install-sp11-support.sh" ]; then
    echo "Missing support installer: $repo_dir/scripts/install-sp11-support.sh" >&2
    exit 1
  fi

  as_root "$repo_dir/scripts/install-sp11-support.sh" --retire-loose-dtb-only
  as_root apt install --reinstall "${debs[@]}"
  as_root "$repo_dir/scripts/install-sp11-support.sh" --installed-system

  if [ -n "$touchscreen_release" ] && [ "$SKIP_TOUCHSCREEN_MODULES" != "true" ]; then
    as_root "$repo_dir/scripts/install-sp11-touchscreen.sh" \
      --modules-dir "$touchscreen_dir" \
      --release "$touchscreen_release"
  fi
}

if [ "$INSTALL_ONLY" = "true" ]; then
  install_kernel_debs
  exit 0
fi

if [ "$INSTALL_DEPS" = "true" ]; then
  install_dependencies
fi

initialize_kernel_tree_validator_sink || exit 1

if [ "$PREPARE_ONLY" != "true" ]; then
  check_free_space
fi

case "$SOURCE_MODE" in
  apt) prepare_apt_source ;;
  git) prepare_git_source ;;
esac

verify_expected_source_commit
verify_and_export_build_identity
echo "Using source tree: $source_dir"
assert_release_package_output_pristine
apply_patches
preflight_release_patched_tree_symlinks
install_source_build_dependencies
capture_patched_tree_identity
if [ "$RELEASE_BUILD" != "true" ]; then
  write_manifest
fi

if [ "$PREPARE_ONLY" = "true" ]; then
  echo "Prepare-only mode complete."
  exit 0
fi

build_kernel
write_deb_manifest
write_release_manifest_v2

echo
echo "Generated kernel packages:"
generated_debs=()
while IFS= read -r deb; do
  generated_debs+=("$deb")
done < <(collect_kernel_debs)
if [ "${#generated_debs[@]}" -gt 0 ]; then
  ls -lh "${generated_debs[@]}"
else
  echo "No qcom-x1e kernel packages found under $work_dir."
fi

if [ "$INSTALL_DEBS" = "true" ]; then
  install_kernel_debs
else
  echo
  echo "Review the generated debs, then install the qcom-x1e image/modules/header packages."
  echo "Reboot into the patched kernel and rerun scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock."
fi
