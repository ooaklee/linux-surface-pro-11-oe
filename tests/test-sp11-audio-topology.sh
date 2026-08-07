#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/scripts/sp11-audio-topology.sh"
test_root="$(mktemp -d)"
mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
case_output=""
case_status=0

trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$mock_bin"
: > "$command_log"

export MOCK_COMMAND_LOG="$command_log"
export MOCK_GIT_STATUS=""

cat > "$mock_bin/git" <<'EOF_GIT'
#!/bin/sh
printf 'git %s\n' "$*" >> "$MOCK_COMMAND_LOG"
case "$*" in
  *" rev-parse --is-inside-work-tree")
    printf '%s\n' true
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
printf '%s\n' 'fixture topology binary' > "$output"
EOF_ALSATPLG

chmod +x "$mock_bin/git" "$mock_bin/m4" "$mock_bin/alsatplg"

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

# An untracked m4 include candidate in the source checkout must fail closed
# before m4 can read it.
work_dir="$test_root/work"
source_dir="$work_dir/source"
stale_include="$source_dir/build/audioreach/stale.m4"
mkdir -p "$(dirname "$stale_include")"
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
: > "$command_log"
run_case --dry-run --work-dir "$work_dir"
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

echo 'Audio topology source isolation and option-safety tests passed.'
