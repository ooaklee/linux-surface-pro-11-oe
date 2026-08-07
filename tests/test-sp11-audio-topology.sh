#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/scripts/sp11-audio-topology.sh"
test_root="$(mktemp -d)"
test_root="$(cd "$test_root" && pwd -P)"
mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
real_git="$(command -v git)"
case_output=""
case_status=0

trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$mock_bin"
: > "$command_log"

export MOCK_COMMAND_LOG="$command_log"
export MOCK_GIT_STATUS=""

cat > "$mock_bin/git" <<'EOF_GIT'
#!/bin/sh
if [ "${ASSERT_SANITIZED_GIT_ENV:-false}" = "true" ]; then
  for variable_name in \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR \
    GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR \
    GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXEC_PATH GIT_INDEX_FILE \
    GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_PREFIX GIT_SHALLOW_FILE \
    GIT_WORK_TREE GIT_CONFIG_KEY_0 GIT_CONFIG_KEY_17 \
    GIT_CONFIG_VALUE_0 GIT_CONFIG_VALUE_17; do
    eval "variable_is_set=\${${variable_name}+yes}"
    if [ "$variable_is_set" = "yes" ]; then
      printf '%s was not removed from the Git environment\n' "$variable_name" >&2
      exit 92
    fi
  done

  [ "${GIT_CONFIG_NOSYSTEM:-}" = "1" ] || {
    printf 'GIT_CONFIG_NOSYSTEM was not forced to 1\n' >&2
    exit 93
  }
  [ "${GIT_CONFIG_SYSTEM:-}" = "/dev/null" ] || {
    printf 'GIT_CONFIG_SYSTEM was not redirected to /dev/null\n' >&2
    exit 94
  }
  [ "${GIT_CONFIG_GLOBAL:-}" = "/dev/null" ] || {
    printf 'GIT_CONFIG_GLOBAL was not redirected to /dev/null\n' >&2
    exit 95
  }
  [ "${GIT_ATTR_NOSYSTEM:-}" = "1" ] || {
    printf 'GIT_ATTR_NOSYSTEM was not forced to 1\n' >&2
    exit 96
  }
  [ "${GIT_NO_REPLACE_OBJECTS:-}" = "1" ] || {
    printf 'GIT_NO_REPLACE_OBJECTS was not forced to 1\n' >&2
    exit 97
  }
fi

printf 'git %s\n' "$*" >> "$MOCK_COMMAND_LOG"
case "$*" in
  *" rev-parse --is-inside-work-tree")
    printf '%s\n' true
    ;;
  *" rev-parse --show-toplevel")
    [ "${1:-}" = "-C" ] || exit 86
    printf '%s\n' "$2"
    ;;
  *" rev-parse --absolute-git-dir")
    [ "${1:-}" = "-C" ] || exit 85
    printf '%s/.git\n' "$2"
    ;;
  *" remote get-url origin")
    printf '%s\n' https://github.com/linux-msm/audioreach-topology.git
    ;;
  *" rev-parse --verify HEAD")
    printf '%s\n' d7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677
    ;;
  *" status --porcelain --untracked-files=all --ignored=matching")
    if [ -n "$MOCK_GIT_STATUS" ]; then
      printf '%s\n' "$MOCK_GIT_STATUS"
    fi
    ;;
  *)
    printf 'Unexpected git invocation: %s\n' "$*" >&2
    exit 90
    ;;
esac
EOF_GIT

cat > "$mock_bin/m4" <<'EOF_M4'
#!/bin/sh
printf 'm4 %s\n' "$*" >> "$MOCK_COMMAND_LOG"
printf '%s\n' '# fixture topology'
EOF_M4

cat > "$mock_bin/alsatplg" <<'EOF_ALSATPLG'
#!/bin/sh
printf 'alsatplg %s\n' "$*" >> "$MOCK_COMMAND_LOG"
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$output" ] || exit 91
mkdir -p "$(dirname "$output")"
case "${MOCK_ALSATPLG_MODE:-regular}" in
  regular)
    printf '%s\n' 'fixture topology binary' > "$output"
    ;;
  empty)
    : > "$output"
    ;;
  fifo)
    mkfifo "$output"
    ;;
  symlink)
    [ -n "${MOCK_ALSATPLG_VICTIM:-}" ] || exit 89
    ln -s "$MOCK_ALSATPLG_VICTIM" "$output"
    ;;
  *)
    exit 88
    ;;
esac
EOF_ALSATPLG

cat > "$mock_bin/id" <<'EOF_ID'
#!/bin/sh
if [ "${MOCK_ID_UID:-}" ]; then
  [ "${1:-}" = "-u" ] || exit 87
  printf '%s\n' "$MOCK_ID_UID"
else
  exec /usr/bin/id "$@"
fi
EOF_ID

cat > "$mock_bin/ln" <<'EOF_LN'
#!/bin/sh
last=""
for argument in "$@"; do
  last="$argument"
done
if [ -n "${MOCK_LN_FAIL_DESTINATION:-}" ] && \
   [ "$last" = "$MOCK_LN_FAIL_DESTINATION" ]; then
  if [ -n "${MOCK_LN_RACE_DESTINATION:-}" ]; then
    /bin/rm -f -- "$MOCK_LN_RACE_DESTINATION" || exit 83
    /bin/mkdir "$MOCK_LN_RACE_DESTINATION" || exit 82
    printf '%s\n' 'occupied race destination' > \
      "$MOCK_LN_RACE_DESTINATION/marker"
  fi
  if [ -n "${MOCK_LN_REGULAR_RACE_DESTINATION:-}" ]; then
    /bin/rm -f -- "$MOCK_LN_REGULAR_RACE_DESTINATION" || exit 81
    /bin/mv "${MOCK_LN_REGULAR_RACE_SOURCE:?}" \
      "$MOCK_LN_REGULAR_RACE_DESTINATION" || exit 80
  fi
  printf 'forced ln failure for %s\n' "$last" >> "$MOCK_COMMAND_LOG"
  exit 84
fi
exec /bin/ln "$@"
EOF_LN

chmod +x "$mock_bin/git" "$mock_bin/m4" "$mock_bin/alsatplg" \
  "$mock_bin/id" "$mock_bin/ln"

run_case() {
  if case_output="$(
    PATH="$mock_bin:/usr/bin:/bin" \
      "$helper" "$@" 2>&1
  )"; then
    case_status=0
  else
    case_status=$?
  fi
}

run_case_with_hostile_git_environment() {
  if case_output="$(
    PATH="$mock_bin:/usr/bin:/bin" \
      ASSERT_SANITIZED_GIT_ENV=true \
      GIT_ALTERNATE_OBJECT_DIRECTORIES="$test_root/hostile-objects" \
      GIT_CEILING_DIRECTORIES="$test_root" \
      GIT_COMMON_DIR="$test_root/hostile-common" \
      GIT_CONFIG="$test_root/hostile-config" \
      GIT_CONFIG_COUNT=18 \
      GIT_CONFIG_KEY_0=core.bare \
      GIT_CONFIG_VALUE_0=true \
      GIT_CONFIG_KEY_17=core.worktree \
      GIT_CONFIG_VALUE_17="$test_root/hostile-worktree" \
      GIT_CONFIG_PARAMETERS="'core.bare=true'" \
      GIT_CONFIG_SYSTEM="$test_root/hostile-system-config" \
      GIT_CONFIG_GLOBAL="$test_root/hostile-global-config" \
      GIT_CONFIG_NOSYSTEM=0 \
      GIT_DIR="$test_root/hostile-git-dir" \
      GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
      GIT_EXEC_PATH="$test_root/hostile-git-exec" \
      GIT_INDEX_FILE="$test_root/hostile-index" \
      GIT_NAMESPACE=hostile \
      GIT_OBJECT_DIRECTORY="$test_root/hostile-object-directory" \
      GIT_PREFIX=hostile-prefix \
      GIT_SHALLOW_FILE="$test_root/hostile-shallow" \
      GIT_WORK_TREE="$test_root/hostile-work-tree" \
      GIT_ATTR_NOSYSTEM=0 \
      GIT_NO_REPLACE_OBJECTS=0 \
      "$helper" "$@" 2>&1
  )"; then
    case_status=0
  else
    case_status=$?
  fi
}

run_custom_helper_as_root() {
  local custom_helper="$1"
  shift

  if case_output="$(
    PATH="$mock_bin:/usr/bin:/bin" \
      MOCK_ID_UID=0 \
      "$custom_helper" "$@" 2>&1
  )"; then
    case_status=0
  else
    case_status=$?
  fi
}

assert_status() {
  local expected="$1"

  if [ "$case_status" -ne "$expected" ]; then
    printf 'Expected status %s, got %s. Output:\n%s\n' \
      "$expected" "$case_status" "$case_output" >&2
    exit 1
  fi
}

assert_output_contains() {
  local expected="$1"

  if ! grep -Fq -- "$expected" <<< "$case_output"; then
    printf 'Missing expected output: %s\nFull output:\n%s\n' \
      "$expected" "$case_output" >&2
    exit 1
  fi
}

assert_build_tools_not_called() {
  if grep -Eq '^(m4|alsatplg) ' "$command_log"; then
    printf 'Build tools were unexpectedly invoked:\n' >&2
    cat "$command_log" >&2
    exit 1
  fi
}

assert_file_bytes() {
  local path="$1"
  local expected="$2"

  if [ ! -f "$path" ] || [ -L "$path" ] || \
     [ "$(cat "$path")" != "$expected" ]; then
    printf 'Unexpected bytes or type for %s\n' "$path" >&2
    exit 1
  fi
}

file_mode() {
  local path="$1"
  local mode

  if mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then
    printf '%s\n' "$mode"
  else
    stat -c '%a' "$path"
  fi
}

file_fingerprint() {
  local path="$1"
  local metadata

  if metadata="$(stat -f '%d:%i:%Lp:%u:%g:%z:%m' "$path" 2>/dev/null)"; then
    :
  else
    metadata="$(stat -c '%d:%i:%a:%u:%g:%s:%Y' "$path")"
  fi
  printf '%s:%s\n' "$metadata" "$(cksum "$path" | awk '{print $1 ":" $2}')"
}

prepare_mock_source() {
  local work="$1"

  mkdir -p "$work/source/.git"
  printf '%s\n' 'fixture input' > "$work/source/X1E80100-CRD.m4"
}

# Conflicting dry-run/install intent must fail before dependency or filesystem
# mutation, regardless of whether the process has installation privileges.
conflict_work="$test_root/conflict-work"
: > "$command_log"
run_case --dry-run --install --work-dir "$conflict_work"
assert_status 1
assert_output_contains '--dry-run and --install cannot be used together'
if [ -s "$command_log" ]; then
  printf 'Conflicting options invoked a source or build command:\n' >&2
  cat "$command_log" >&2
  exit 1
fi
if [ -e "$conflict_work" ]; then
  echo 'Conflicting options created the work directory.' >&2
  exit 1
fi

# Unsafe work paths must fail before any dependency, source, or build command.
unsafe_paths=(
  "/"
  "relative-audio-work"
  "$test_root/../audio-escape"
  "$test_root/trailing/"
  "$test_root/control
work"
)
for unsafe_path in "${unsafe_paths[@]}"; do
  : > "$command_log"
  run_case --dry-run --work-dir "$unsafe_path"
  assert_status 1
  if [ -s "$command_log" ]; then
    printf 'Unsafe work path invoked a source or build command: %s\n' "$unsafe_path" >&2
    cat "$command_log" >&2
    exit 1
  fi
done

# A symlinked work root, source root, or generated-output parent must never be
# followed to an external victim.
work_link_victim="$test_root/work-link-victim"
work_link="$test_root/work-link"
mkdir "$work_link_victim"
printf '%s\n' 'work victim' > "$work_link_victim/victim.txt"
ln -s "$work_link_victim" "$work_link"
: > "$command_log"
run_case --dry-run --work-dir "$work_link"
assert_status 1
assert_file_bytes "$work_link_victim/victim.txt" 'work victim'
assert_build_tools_not_called

source_link_work="$test_root/source-link-work"
source_link_victim="$test_root/source-link-victim"
mkdir "$source_link_work" "$source_link_victim"
printf '%s\n' 'source victim' > "$source_link_victim/victim.txt"
ln -s "$source_link_victim" "$source_link_work/source"
: > "$command_log"
run_case --dry-run --work-dir "$source_link_work"
assert_status 1
assert_file_bytes "$source_link_victim/victim.txt" 'source victim'
assert_build_tools_not_called

git_link_work="$test_root/git-link-work"
git_link_victim="$test_root/git-link-victim"
mkdir -p "$git_link_work/source" "$git_link_victim"
printf '%s\n' 'fixture input' > "$git_link_work/source/X1E80100-CRD.m4"
printf '%s\n' 'Git metadata victim' > "$git_link_victim/victim.txt"
ln -s "$git_link_victim" "$git_link_work/source/.git"
: > "$command_log"
run_case --dry-run --work-dir "$git_link_work"
assert_status 1
assert_output_contains 'source Git metadata must not be a symlink'
assert_file_bytes "$git_link_victim/victim.txt" 'Git metadata victim'
if [ -s "$command_log" ]; then
  echo 'Symlinked Git metadata was passed to Git.' >&2
  cat "$command_log" >&2
  exit 1
fi

output_parent_work="$test_root/output-parent-work"
output_parent_victim="$test_root/output-parent-victim"
prepare_mock_source "$output_parent_work"
mkdir -p "$output_parent_work/build" "$output_parent_victim"
printf '%s\n' 'output parent victim' > "$output_parent_victim/victim.txt"
ln -s "$output_parent_victim" "$output_parent_work/build/qcom"
: > "$command_log"
run_case --dry-run --work-dir "$output_parent_work"
assert_status 1
assert_file_bytes "$output_parent_victim/victim.txt" 'output parent victim'
assert_build_tools_not_called

# Every predictable build leaf is preflighted before m4 or alsatplg. Cover a
# symlink victim, a FIFO, and a directory across the topology and UCM outputs.
output_link_work="$test_root/output-link-work"
output_link_victim="$test_root/output-link-victim"
prepare_mock_source "$output_link_work"
mkdir -p "$output_link_work/build/qcom/x1e80100"
printf '%s\n' 'output leaf victim' > "$output_link_victim"
ln -s "$output_link_victim" \
  "$output_link_work/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11.conf"
: > "$command_log"
run_case --dry-run --work-dir "$output_link_work"
assert_status 1
assert_file_bytes "$output_link_victim" 'output leaf victim'
assert_build_tools_not_called

output_fifo_work="$test_root/output-fifo-work"
prepare_mock_source "$output_fifo_work"
mkdir -p "$output_fifo_work/build/qcom/x1e80100"
mkfifo "$output_fifo_work/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
: > "$command_log"
run_case --dry-run --work-dir "$output_fifo_work"
assert_status 1
if [ ! -p "$output_fifo_work/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin" ]; then
  echo 'Rejected topology FIFO was altered.' >&2
  exit 1
fi
assert_build_tools_not_called

output_dir_work="$test_root/output-dir-work"
prepare_mock_source "$output_dir_work"
mkdir -p "$output_dir_work/build/ucm/Surface11-HiFi.conf"
printf '%s\n' 'directory marker' > \
  "$output_dir_work/build/ucm/Surface11-HiFi.conf/marker"
: > "$command_log"
run_case --dry-run --work-dir "$output_dir_work"
assert_status 1
assert_file_bytes \
  "$output_dir_work/build/ucm/Surface11-HiFi.conf/marker" \
  'directory marker'
assert_build_tools_not_called

# An untracked m4 include candidate in the source checkout must fail closed
# before m4 can read it.
work_dir="$test_root/work"
source_dir="$work_dir/source"
stale_include="$source_dir/build/audioreach/stale.m4"
mkdir -p "$(dirname "$stale_include")" "$source_dir/.git"
printf '%s\n' 'stale untracked include' > "$stale_include"
printf '%s\n' 'fixture input' > "$source_dir/X1E80100-CRD.m4"

MOCK_GIT_STATUS='?? build/audioreach/stale.m4'
export MOCK_GIT_STATUS
: > "$command_log"
run_case --dry-run --work-dir "$work_dir"
assert_status 1
assert_output_contains 'source checkout contains modified, untracked, or ignored files'
assert_build_tools_not_called
if [ -e "$work_dir/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11.conf" ]; then
  echo 'Rejected source input still produced a topology configuration.' >&2
  exit 1
fi

# A clean checkout uses only source/source-build include roots while writing
# generated artifacts to the separate work/build tree.
rm -f "$stale_include"
rmdir "$source_dir/build/audioreach" "$source_dir/build"
MOCK_GIT_STATUS=""
export MOCK_GIT_STATUS
mkdir -p "$work_dir/build/ucm"
printf '%s\n' 'unrelated build artifact' > "$work_dir/build/ucm/unrelated.txt"
: > "$command_log"
run_case_with_hostile_git_environment --dry-run --work-dir "$work_dir"
assert_status 0

expected_m4="m4 -I $source_dir/build -I $source_dir $source_dir/X1E80100-CRD.m4"
if ! grep -Fxq -- "$expected_m4" "$command_log"; then
  printf 'm4 did not receive the pinned source include roots:\n' >&2
  cat "$command_log" >&2
  exit 1
fi
if grep -Fq -- "m4 -I $work_dir/build" "$command_log"; then
  printf 'm4 searched the generated-output tree:\n' >&2
  cat "$command_log" >&2
  exit 1
fi
if [ ! -f "$work_dir/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin" ]; then
  echo 'Expected topology artifact was not written to the output tree.' >&2
  exit 1
fi
if [ -e "$source_dir/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11.conf" ]; then
  echo 'Generated topology configuration contaminated the source checkout.' >&2
  exit 1
fi
assert_file_bytes "$work_dir/build/ucm/unrelated.txt" 'unrelated build artifact'
for built_file in \
  "$work_dir/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11.conf" \
  "$work_dir/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin" \
  "$work_dir/build/ucm/MICROSOFT-Surface-Pro-11.conf" \
  "$work_dir/build/ucm/Surface11-HiFi.conf" \
  "$work_dir/build/ucm/x1e80100.conf"; do
  if [ "$(file_mode "$built_file")" != "644" ]; then
    printf 'Generated output did not have mode 0644: %s\n' "$built_file" >&2
    exit 1
  fi
done
if find "$work_dir" -name '.sp11-audio-output.*' -o \
  -name '.sp11-audio-backup.*' | grep -q .; then
  echo 'Successful build left a private stage or backup behind.' >&2
  exit 1
fi

# A compromised compiler must not be able to publish a symlink, FIFO, or empty
# topology output from the private stage.
for generated_mode in symlink fifo empty; do
  generated_work="$test_root/generated-$generated_mode-work"
  prepare_mock_source "$generated_work"
  generated_victim="$test_root/generated-$generated_mode-victim"
  printf '%s\n' "generated $generated_mode victim" > "$generated_victim"
  MOCK_ALSATPLG_MODE="$generated_mode"
  MOCK_ALSATPLG_VICTIM="$generated_victim"
  export MOCK_ALSATPLG_MODE MOCK_ALSATPLG_VICTIM
  : > "$command_log"
  run_case --dry-run --work-dir "$generated_work"
  assert_status 1
  assert_output_contains 'generated audio output must be a nonempty regular file'
  assert_file_bytes "$generated_victim" "generated $generated_mode victim"
  if [ -e "$generated_work/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin" ] || \
     [ -L "$generated_work/build/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin" ]; then
    printf 'Rejected %s compiler output was published.\n' "$generated_mode" >&2
    exit 1
  fi
  if find "$generated_work" -name '.sp11-audio-output.*' -o \
    -name '.sp11-audio-backup.*' | grep -q .; then
    printf 'Rejected %s compiler output left a private stage behind.\n' \
      "$generated_mode" >&2
    exit 1
  fi
done
MOCK_ALSATPLG_MODE=regular
MOCK_ALSATPLG_VICTIM=""
export MOCK_ALSATPLG_MODE MOCK_ALSATPLG_VICTIM

# A deterministic failure after the first new build leaf is linked must restore
# every old destination, including inode and metadata, and remove private state.
rollback_work="$test_root/build-rollback-work"
prepare_mock_source "$rollback_work"
rollback_topology_dir="$rollback_work/build/qcom/x1e80100"
rollback_ucm_dir="$rollback_work/build/ucm"
mkdir -p "$rollback_topology_dir" "$rollback_ucm_dir"
rollback_files=(
  "$rollback_topology_dir/X1E80100-Microsoft-Surface-Pro-11.conf"
  "$rollback_topology_dir/X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
  "$rollback_ucm_dir/MICROSOFT-Surface-Pro-11.conf"
  "$rollback_ucm_dir/Surface11-HiFi.conf"
  "$rollback_ucm_dir/x1e80100.conf"
)
rollback_fingerprints=()
rollback_index=0
for rollback_file in "${rollback_files[@]}"; do
  printf 'old build output %s\n' "$rollback_index" > "$rollback_file"
  chmod 0640 "$rollback_file"
  rollback_fingerprints+=("$(file_fingerprint "$rollback_file")")
  rollback_index=$((rollback_index + 1))
done
printf '%s\n' 'rollback unrelated' > "$rollback_ucm_dir/unrelated.txt"
MOCK_LN_FAIL_DESTINATION="${rollback_files[1]}"
export MOCK_LN_FAIL_DESTINATION
: > "$command_log"
run_case --dry-run --work-dir "$rollback_work"
assert_status 1
assert_output_contains 'cannot publish audio output atomically'
rollback_index=0
for rollback_file in "${rollback_files[@]}"; do
  if [ "$(file_fingerprint "$rollback_file")" != \
       "${rollback_fingerprints[$rollback_index]}" ]; then
    printf 'Build rollback changed managed peer %s\n' "$rollback_file" >&2
    exit 1
  fi
  rollback_index=$((rollback_index + 1))
done
assert_file_bytes "$rollback_ucm_dir/unrelated.txt" 'rollback unrelated'
if find "$rollback_work" \
  \( -name '.sp11-audio-output.*' -o -name '.sp11-audio-backup.*' \) \
  -print | grep -q .; then
  echo 'Failed build transaction left a private stage or backup behind.' >&2
  exit 1
fi
MOCK_LN_FAIL_DESTINATION=""
export MOCK_LN_FAIL_DESTINATION

# If a concurrent actor replaces an already linked destination before rollback,
# leave that actor's entry untouched and preserve the displaced original in its
# private recovery directory instead of deleting the only recoverable copy.
race_work="$test_root/build-race-work"
prepare_mock_source "$race_work"
race_topology_dir="$race_work/build/qcom/x1e80100"
race_ucm_dir="$race_work/build/ucm"
mkdir -p "$race_topology_dir" "$race_ucm_dir"
race_files=(
  "$race_topology_dir/X1E80100-Microsoft-Surface-Pro-11.conf"
  "$race_topology_dir/X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
  "$race_ucm_dir/MICROSOFT-Surface-Pro-11.conf"
  "$race_ucm_dir/Surface11-HiFi.conf"
  "$race_ucm_dir/x1e80100.conf"
)
race_fingerprints=()
race_index=0
for race_file in "${race_files[@]}"; do
  printf 'old race output %s\n' "$race_index" > "$race_file"
  chmod 0640 "$race_file"
  race_fingerprints+=("$(file_fingerprint "$race_file")")
  race_index=$((race_index + 1))
done
MOCK_LN_FAIL_DESTINATION="${race_files[1]}"
MOCK_LN_RACE_DESTINATION="${race_files[0]}"
export MOCK_LN_FAIL_DESTINATION MOCK_LN_RACE_DESTINATION
: > "$command_log"
run_case --dry-run --work-dir "$race_work"
assert_status 1
assert_output_contains 'audio destination is occupied during rollback; preserving recoverable backup'
if [ ! -d "${race_files[0]}" ] || [ -L "${race_files[0]}" ]; then
  echo 'Occupied race destination was removed during rollback.' >&2
  exit 1
fi
assert_file_bytes "${race_files[0]}/marker" 'occupied race destination'
race_index=1
while [ "$race_index" -lt "${#race_files[@]}" ]; do
  if [ "$(file_fingerprint "${race_files[$race_index]}")" != \
       "${race_fingerprints[$race_index]}" ]; then
    printf 'Race rollback changed restorable peer %s\n' \
      "${race_files[$race_index]}" >&2
    exit 1
  fi
  race_index=$((race_index + 1))
done
race_backup_count=0
race_backup_original=""
while IFS= read -r race_backup_dir; do
  race_backup_count=$((race_backup_count + 1))
  race_backup_original="$race_backup_dir/original"
done < <(find "$race_work" -type d -name '.sp11-audio-backup.*' -print)
if [ "$race_backup_count" -ne 1 ] || [ -z "$race_backup_original" ]; then
  echo 'Occupied-destination rollback did not preserve exactly one recovery backup.' >&2
  exit 1
fi
if [ "$(file_fingerprint "$race_backup_original")" != "${race_fingerprints[0]}" ]; then
  echo 'Preserved race recovery backup differs from the displaced original.' >&2
  exit 1
fi
if find "$race_work" -name '.sp11-audio-output.*' -print | grep -q .; then
  echo 'Occupied-destination rollback left its build stage behind.' >&2
  exit 1
fi
MOCK_LN_FAIL_DESTINATION=""
MOCK_LN_RACE_DESTINATION=""
export MOCK_LN_FAIL_DESTINATION MOCK_LN_RACE_DESTINATION

# A concurrent regular-file replacement is distinct from the hard link this
# transaction published even though both nodes pass the regular-file type gate.
# Rollback must compare the recorded publication identity, preserve that new
# file byte-for-byte, and retain the displaced old output for manual recovery.
regular_race_work="$test_root/build-regular-race-work"
prepare_mock_source "$regular_race_work"
regular_race_topology_dir="$regular_race_work/build/qcom/x1e80100"
regular_race_ucm_dir="$regular_race_work/build/ucm"
mkdir -p "$regular_race_topology_dir" "$regular_race_ucm_dir"
regular_race_files=(
  "$regular_race_topology_dir/X1E80100-Microsoft-Surface-Pro-11.conf"
  "$regular_race_topology_dir/X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
  "$regular_race_ucm_dir/MICROSOFT-Surface-Pro-11.conf"
  "$regular_race_ucm_dir/Surface11-HiFi.conf"
  "$regular_race_ucm_dir/x1e80100.conf"
)
regular_race_fingerprints=()
regular_race_index=0
for regular_race_file in "${regular_race_files[@]}"; do
  printf 'old regular-race output %s\n' "$regular_race_index" > "$regular_race_file"
  chmod 0640 "$regular_race_file"
  regular_race_fingerprints+=("$(file_fingerprint "$regular_race_file")")
  regular_race_index=$((regular_race_index + 1))
done
regular_race_source="$test_root/regular-race-replacement"
printf '%s\n' 'concurrent regular replacement' > "$regular_race_source"
chmod 0600 "$regular_race_source"
regular_race_replacement_fingerprint="$(file_fingerprint "$regular_race_source")"
MOCK_LN_FAIL_DESTINATION="${regular_race_files[1]}"
MOCK_LN_REGULAR_RACE_DESTINATION="${regular_race_files[0]}"
MOCK_LN_REGULAR_RACE_SOURCE="$regular_race_source"
export MOCK_LN_FAIL_DESTINATION MOCK_LN_REGULAR_RACE_DESTINATION
export MOCK_LN_REGULAR_RACE_SOURCE
: > "$command_log"
run_case --dry-run --work-dir "$regular_race_work"
assert_status 1
assert_output_contains 'failed audio destination was replaced during rollback; leaving it untouched'
if [ "$(file_fingerprint "${regular_race_files[0]}")" != \
     "$regular_race_replacement_fingerprint" ]; then
  echo 'Rollback changed or removed the concurrent regular-file replacement.' >&2
  exit 1
fi
regular_race_index=1
while [ "$regular_race_index" -lt "${#regular_race_files[@]}" ]; do
  if [ "$(file_fingerprint "${regular_race_files[$regular_race_index]}")" != \
       "${regular_race_fingerprints[$regular_race_index]}" ]; then
    printf 'Regular-race rollback changed restorable peer %s\n' \
      "${regular_race_files[$regular_race_index]}" >&2
    exit 1
  fi
  regular_race_index=$((regular_race_index + 1))
done
regular_race_backup_count=0
regular_race_backup_original=""
while IFS= read -r regular_race_backup_dir; do
  regular_race_backup_count=$((regular_race_backup_count + 1))
  regular_race_backup_original="$regular_race_backup_dir/original"
done < <(find "$regular_race_work" -type d -name '.sp11-audio-backup.*' -print)
if [ "$regular_race_backup_count" -ne 1 ] || [ -z "$regular_race_backup_original" ]; then
  echo 'Regular replacement rollback did not preserve exactly one recovery backup.' >&2
  exit 1
fi
if [ "$(file_fingerprint "$regular_race_backup_original")" != \
     "${regular_race_fingerprints[0]}" ]; then
  echo 'Regular replacement recovery backup differs from the displaced original.' >&2
  exit 1
fi
if find "$regular_race_work" -name '.sp11-audio-output.*' -print | grep -q .; then
  echo 'Regular replacement rollback left its build stage behind.' >&2
  exit 1
fi
MOCK_LN_FAIL_DESTINATION=""
MOCK_LN_REGULAR_RACE_DESTINATION=""
MOCK_LN_REGULAR_RACE_SOURCE=""
export MOCK_LN_FAIL_DESTINATION MOCK_LN_REGULAR_RACE_DESTINATION
export MOCK_LN_REGULAR_RACE_SOURCE

# Specialize the fixed system destinations into a private fixture root so the
# complete root-install transaction can be exercised without host mutation.
make_install_helper() {
  local install_root="$1"
  local output_helper="$2"

  sed \
    -e "s|^FW_PATH=.*|FW_PATH=\"$install_root/lib/firmware/qcom/x1e80100\"|" \
    -e "s|^UCM_QUALCOMM_DIR=.*|UCM_QUALCOMM_DIR=\"$install_root/usr/share/alsa/ucm2/Qualcomm/x1e80100\"|" \
    -e "s|^UCM_CONFD_DIR=.*|UCM_CONFD_DIR=\"$install_root/usr/share/alsa/ucm2/conf.d/x1e80100\"|" \
    "$helper" > "$output_helper"
  chmod +x "$output_helper"
}

set_install_paths() {
  local install_root="$1"

  install_fw_dir="$install_root/lib/firmware/qcom/x1e80100"
  install_ucm_dir="$install_root/usr/share/alsa/ucm2/Qualcomm/x1e80100"
  install_conf_dir="$install_root/usr/share/alsa/ucm2/conf.d/x1e80100"
  install_fw="$install_fw_dir/X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
  install_card="$install_ucm_dir/MICROSOFT-Surface-Pro-11.conf"
  install_hifi="$install_ucm_dir/Surface11-HiFi.conf"
  install_machine="$install_conf_dir/x1e80100.conf"
}

seed_install_root() {
  local install_root="$1"

  set_install_paths "$install_root"
  mkdir -p "$install_fw_dir" "$install_ucm_dir" "$install_conf_dir"
  printf '%s\n' 'old topology' > "$install_fw"
  printf '%s\n' 'old card' > "$install_card"
  printf '%s\n' 'old hifi' > "$install_hifi"
  printf '%s\n' 'old machine' > "$install_machine"
  printf '%s\n' 'unrelated install file' > "$install_ucm_dir/unrelated.txt"
}

assert_install_peers_unchanged() {
  assert_file_bytes "$install_fw" 'old topology'
  assert_file_bytes "$install_card" 'old card'
  assert_file_bytes "$install_hifi" 'old hifi'
  assert_file_bytes "$install_machine" 'old machine'
  assert_file_bytes "$install_ucm_dir/unrelated.txt" 'unrelated install file'
}

install_work="$test_root/install-work"
prepare_mock_source "$install_work"

# A symlink destination must not overwrite its external victim or retire any
# regular peer selected for the same install transaction.
install_symlink_root="$test_root/install-symlink-root"
install_symlink_helper="$test_root/install-symlink-helper.sh"
install_symlink_victim="$test_root/install-symlink-victim"
seed_install_root "$install_symlink_root"
rm -f "$install_fw"
printf '%s\n' 'install symlink victim' > "$install_symlink_victim"
ln -s "$install_symlink_victim" "$install_fw"
make_install_helper "$install_symlink_root" "$install_symlink_helper"
: > "$command_log"
run_custom_helper_as_root "$install_symlink_helper" --install --work-dir "$install_work"
assert_status 1
assert_output_contains 'installed topology destination must not be a symlink'
assert_file_bytes "$install_symlink_victim" 'install symlink victim'
if [ ! -L "$install_fw" ] || [ "$(readlink "$install_fw")" != "$install_symlink_victim" ]; then
  echo 'Rejected installed topology symlink was altered.' >&2
  exit 1
fi
assert_file_bytes "$install_card" 'old card'
assert_file_bytes "$install_hifi" 'old hifi'
assert_file_bytes "$install_machine" 'old machine'
assert_file_bytes "$install_ucm_dir/unrelated.txt" 'unrelated install file'

# FIFO and directory leaves at later transaction positions must likewise fail
# before any earlier regular destination is retired.
install_fifo_root="$test_root/install-fifo-root"
install_fifo_helper="$test_root/install-fifo-helper.sh"
seed_install_root "$install_fifo_root"
rm -f "$install_card"
mkfifo "$install_card"
make_install_helper "$install_fifo_root" "$install_fifo_helper"
: > "$command_log"
run_custom_helper_as_root "$install_fifo_helper" --install --work-dir "$install_work"
assert_status 1
assert_output_contains 'installed UCM card destination must be absent or a regular file'
if [ ! -p "$install_card" ]; then
  echo 'Rejected installed UCM FIFO was altered.' >&2
  exit 1
fi
assert_file_bytes "$install_fw" 'old topology'
assert_file_bytes "$install_hifi" 'old hifi'
assert_file_bytes "$install_machine" 'old machine'
assert_file_bytes "$install_ucm_dir/unrelated.txt" 'unrelated install file'

install_dir_root="$test_root/install-dir-root"
install_dir_helper="$test_root/install-dir-helper.sh"
seed_install_root "$install_dir_root"
rm -f "$install_hifi"
mkdir "$install_hifi"
printf '%s\n' 'install directory victim' > "$install_hifi/marker"
make_install_helper "$install_dir_root" "$install_dir_helper"
: > "$command_log"
run_custom_helper_as_root "$install_dir_helper" --install --work-dir "$install_work"
assert_status 1
assert_output_contains 'installed UCM HiFi destination must be absent or a regular file'
assert_file_bytes "$install_hifi/marker" 'install directory victim'
assert_file_bytes "$install_fw" 'old topology'
assert_file_bytes "$install_card" 'old card'
assert_file_bytes "$install_machine" 'old machine'
assert_file_bytes "$install_ucm_dir/unrelated.txt" 'unrelated install file'

# A parent symlink resolving outside the specialized install root must be
# rejected before the external directory or any other install target changes.
install_parent_root="$test_root/install-parent-root"
install_parent_helper="$test_root/install-parent-helper.sh"
install_parent_victim="$test_root/install-parent-victim"
mkdir -p "$install_parent_root/usr/share/alsa/ucm2" "$install_parent_victim"
printf '%s\n' 'install parent victim' > "$install_parent_victim/victim.txt"
ln -s "$install_parent_victim" \
  "$install_parent_root/usr/share/alsa/ucm2/Qualcomm"
make_install_helper "$install_parent_root" "$install_parent_helper"
: > "$command_log"
run_custom_helper_as_root "$install_parent_helper" --install --work-dir "$install_work"
assert_status 1
assert_output_contains 'installation directory resolves outside its allowed physical path'
assert_file_bytes "$install_parent_victim/victim.txt" 'install parent victim'
if [ -e "$install_parent_victim/x1e80100" ]; then
  echo 'Rejected install-parent symlink created content in its victim.' >&2
  exit 1
fi

# A failure linking the final install leaf must restore all four old files with
# their original identity and metadata, after three replacements were linked.
install_rollback_root="$test_root/install-rollback-root"
install_rollback_helper="$test_root/install-rollback-helper.sh"
seed_install_root "$install_rollback_root"
install_rollback_files=("$install_fw" "$install_card" "$install_hifi" "$install_machine")
install_rollback_fingerprints=()
for install_rollback_file in "${install_rollback_files[@]}"; do
  chmod 0640 "$install_rollback_file"
  install_rollback_fingerprints+=("$(file_fingerprint "$install_rollback_file")")
done
make_install_helper "$install_rollback_root" "$install_rollback_helper"
MOCK_LN_FAIL_DESTINATION="$install_machine"
export MOCK_LN_FAIL_DESTINATION
: > "$command_log"
run_custom_helper_as_root "$install_rollback_helper" --install --work-dir "$install_work"
assert_status 1
assert_output_contains 'cannot publish audio output atomically'
install_rollback_index=0
for install_rollback_file in "${install_rollback_files[@]}"; do
  if [ "$(file_fingerprint "$install_rollback_file")" != \
       "${install_rollback_fingerprints[$install_rollback_index]}" ]; then
    printf 'Install rollback changed managed peer %s\n' "$install_rollback_file" >&2
    exit 1
  fi
  install_rollback_index=$((install_rollback_index + 1))
done
assert_file_bytes "$install_ucm_dir/unrelated.txt" 'unrelated install file'
if find "$install_rollback_root" \
  \( -name '.sp11-audio-install.*' -o -name '.sp11-audio-backup.*' \) \
  -print | grep -q .; then
  echo 'Failed audio install left a private stage or backup behind.' >&2
  exit 1
fi
MOCK_LN_FAIL_DESTINATION=""
export MOCK_LN_FAIL_DESTINATION

# A valid root install replaces exactly the four managed leaves, keeps
# unrelated files, publishes mode 0644, and removes all private stages.
install_valid_root="$test_root/install-valid-root"
install_valid_helper="$test_root/install-valid-helper.sh"
seed_install_root "$install_valid_root"
make_install_helper "$install_valid_root" "$install_valid_helper"
: > "$command_log"
run_custom_helper_as_root "$install_valid_helper" --install --work-dir "$install_work"
assert_status 0
assert_file_bytes "$install_fw" 'fixture topology binary'
assert_file_bytes "$install_ucm_dir/unrelated.txt" 'unrelated install file'
for installed_file in "$install_fw" "$install_card" "$install_hifi" "$install_machine"; do
  if [ "$(file_mode "$installed_file")" != "644" ]; then
    printf 'Installed audio output did not have mode 0644: %s\n' "$installed_file" >&2
    exit 1
  fi
done
if find "$install_valid_root" \
  \( -name '.sp11-audio-install.*' -o -name '.sp11-audio-backup.*' \) \
  -print | grep -q .; then
  echo 'Successful audio install left a private stage or backup behind.' >&2
  exit 1
fi

# A replacement ref can make a checkout report the nominal pinned HEAD and a
# clean status while Git reads a different commit tree. The helper must disable
# replacement objects, observe the original pinned tree, and reject that worktree.
replace_work="$test_root/replacement-work"
replace_source="$replace_work/source"
replace_bin="$test_root/replace-bin"
replace_helper="$test_root/sp11-audio-topology-replacement-fixture.sh"
mkdir -p "$replace_source" "$replace_bin"
ln -s "$real_git" "$replace_bin/git"
cp "$mock_bin/m4" "$mock_bin/alsatplg" "$replace_bin/"

"$real_git" -C "$replace_source" init --quiet
"$real_git" -C "$replace_source" config user.name 'SP11 test'
"$real_git" -C "$replace_source" config user.email 'sp11-test@example.invalid'
"$real_git" -C "$replace_source" remote add origin \
  https://github.com/linux-msm/audioreach-topology.git
printf '%s\n' 'trusted topology input' > "$replace_source/X1E80100-CRD.m4"
"$real_git" -C "$replace_source" add X1E80100-CRD.m4
"$real_git" -C "$replace_source" commit --quiet -m 'Create pinned source fixture'
pinned_commit="$("$real_git" -C "$replace_source" rev-parse HEAD)"

printf '%s\n' 'replacement topology input' > "$replace_source/X1E80100-CRD.m4"
"$real_git" -C "$replace_source" commit --quiet -am 'Create replacement source fixture'
replacement_commit="$("$real_git" -C "$replace_source" rev-parse HEAD)"
"$real_git" -C "$replace_source" replace "$pinned_commit" "$replacement_commit"
"$real_git" -C "$replace_source" checkout --quiet --detach "$pinned_commit"

if [ "$("$real_git" -C "$replace_source" rev-parse --verify HEAD)" != "$pinned_commit" ]; then
  echo 'Replacement-ref fixture did not retain the nominal pinned HEAD.' >&2
  exit 1
fi
if [ -n "$("$real_git" -C "$replace_source" status --porcelain --untracked-files=all --ignored=matching)" ]; then
  echo 'Replacement-ref fixture was not clean while replacements were enabled.' >&2
  exit 1
fi
if [ -z "$(GIT_NO_REPLACE_OBJECTS=1 "$real_git" -C "$replace_source" status --porcelain --untracked-files=all --ignored=matching)" ]; then
  echo 'Replacement-ref fixture did not diverge from the original pinned tree.' >&2
  exit 1
fi

sed "s/^REPO_REF=\"[0-9a-f][0-9a-f]*\"$/REPO_REF=\"$pinned_commit\"/" \
  "$helper" > "$replace_helper"
chmod +x "$replace_helper"
if ! grep -Fxq "REPO_REF=\"$pinned_commit\"" "$replace_helper"; then
  echo 'Could not specialize the audio helper for the replacement-ref fixture.' >&2
  exit 1
fi

: > "$command_log"
if replacement_output="$(
  PATH="$replace_bin:/usr/bin:/bin" \
    MOCK_COMMAND_LOG="$command_log" \
    GIT_NO_REPLACE_OBJECTS=0 \
    "$replace_helper" --dry-run --work-dir "$replace_work" 2>&1
)"; then
  printf 'Replacement-ref checkout was accepted unexpectedly:\n%s\n' \
    "$replacement_output" >&2
  exit 1
fi
if ! grep -Fq 'source checkout contains modified, untracked, or ignored files' \
  <<< "$replacement_output"; then
  printf 'Replacement-ref rejection was not explicit:\n%s\n' \
    "$replacement_output" >&2
  exit 1
fi
assert_build_tools_not_called

echo 'Audio topology source isolation, Git provenance, and option-safety tests passed.'
