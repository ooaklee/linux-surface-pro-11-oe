#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-git-boundaries.XXXXXX")"
real_git="$(command -v git)"
mock_bin="$test_root/bin"
git_log="$test_root/git.log"
sanitized_assertion="$test_root/assert-sanitized-git-environment.sh"

cleanup() {
  case "$test_root" in
    "${TMPDIR:-/tmp}"/sp11-git-boundaries.*) rm -rf -- "$test_root" ;;
    *) printf 'warning: refusing to remove unexpected test path: %s\n' "$test_root" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for tool in awk git grep mkfifo mktemp shasum stat; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

mkdir -p "$mock_bin"
: > "$git_log"

cat > "$sanitized_assertion" <<'EOF_ASSERT'
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
EOF_ASSERT

cat > "$mock_bin/git" <<'EOF_GIT'
#!/bin/sh
set -eu

if [ "${ASSERT_SANITIZED_GIT_ENV:-false}" = "true" ]; then
  . "$SANITIZED_ASSERTION"
fi

printf 'git %s\n' "$*" >> "$MOCK_GIT_LOG"
case "${MOCK_GIT_MODE:-delegate}" in
  delegate)
    exec "$REAL_GIT" "$@"
    ;;
  fork)
    [ "${1:-}" = "ls-remote" ] || {
      printf 'unexpected mocked Git invocation: %s\n' "$*" >&2
      exit 90
    }
    printf '%s\trefs/heads/%s\n' "$MOCK_FORK_BASE_COMMIT" "$MOCK_FORK_BASE_REF"
    printf '%s\trefs/heads/%s\n' \
      "$MOCK_FORK_INTEGRATION_COMMIT" "$MOCK_FORK_INTEGRATION_REF"
    ;;
  *)
    printf 'unknown MOCK_GIT_MODE: %s\n' "$MOCK_GIT_MODE" >&2
    exit 91
    ;;
esac
EOF_GIT
chmod +x "$mock_bin/git" "$sanitized_assertion"

run_with_hostile_git_environment() {
  local hostile_git_dir="$1"
  local hostile_work_tree="$2"
  local hostile_index="$3"
  shift 3

  env \
    ASSERT_SANITIZED_GIT_ENV=true \
    SANITIZED_ASSERTION="$sanitized_assertion" \
    REAL_GIT="$real_git" \
    MOCK_GIT_LOG="$git_log" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$test_root/hostile-alternates" \
    GIT_CEILING_DIRECTORIES="$test_root" \
    GIT_COMMON_DIR="$test_root/hostile-common" \
    GIT_CONFIG="$test_root/hostile-config" \
    GIT_CONFIG_COUNT=18 \
    GIT_CONFIG_KEY_0=core.bare \
    GIT_CONFIG_VALUE_0=true \
    GIT_CONFIG_KEY_17=core.worktree \
    GIT_CONFIG_VALUE_17="$test_root/hostile-config-worktree" \
    GIT_CONFIG_PARAMETERS="'core.bare=true'" \
    GIT_CONFIG_NOSYSTEM=0 \
    GIT_CONFIG_SYSTEM="$test_root/hostile-system-config" \
    GIT_CONFIG_GLOBAL="$test_root/hostile-global-config" \
    GIT_DIR="$hostile_git_dir" \
    GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
    GIT_EXEC_PATH="$test_root/hostile-git-exec" \
    GIT_INDEX_FILE="$hostile_index" \
    GIT_NAMESPACE=hostile \
    GIT_OBJECT_DIRECTORY="$test_root/hostile-object-directory" \
    GIT_PREFIX=hostile-prefix \
    GIT_SHALLOW_FILE="$test_root/hostile-shallow" \
    GIT_WORK_TREE="$hostile_work_tree" \
    GIT_ATTR_NOSYSTEM=0 \
    GIT_NO_REPLACE_OBJECTS=0 \
    "$@"
}

configure_fixture_repository() {
  local fixture_repo="$1"

  "$real_git" -C "$fixture_repo" init --quiet --initial-branch=fixture
  "$real_git" -C "$fixture_repo" config user.name 'SP11 Git boundary fixture'
  "$real_git" -C "$fixture_repo" config user.email 'sp11-git-boundary@example.invalid'
}

# The public-content validator must enumerate the repository's real index, even
# when a caller supplies a clean alternate index that hides an ignored file.
public_repo="$test_root/public-repo"
public_index="$test_root/public-clean.index"
mkdir -p "$public_repo/scripts" "$public_repo/docs"
cp "$repo_dir/scripts/validate-sp11-public-content.sh" "$public_repo/scripts/"
printf '%s\n' 'docs/private.txt' > "$public_repo/.gitignore"
printf '/%s/%s/credential.txt\n' home fixture-user > "$public_repo/docs/private.txt"
configure_fixture_repository "$public_repo"
"$real_git" -C "$public_repo" add .gitignore scripts/validate-sp11-public-content.sh
"$real_git" -C "$public_repo" add -f docs/private.txt
"$real_git" -C "$public_repo" commit --quiet -m 'Create public-content fixture'

GIT_INDEX_FILE="$public_index" "$real_git" -C "$public_repo" read-tree --empty
GIT_INDEX_FILE="$public_index" "$real_git" -C "$public_repo" add \
  .gitignore scripts/validate-sp11-public-content.sh
if GIT_INDEX_FILE="$public_index" "$real_git" -C "$public_repo" \
  ls-files --cached --others --exclude-standard | grep -Fxq 'docs/private.txt'; then
  die 'alternate-index fixture did not hide the ignored public-content file'
fi

public_status=0
public_output="$(
  run_with_hostile_git_environment \
    "$test_root/invalid-public-git-dir" "$test_root/invalid-public-worktree" \
    "$public_index" \
    env PATH="$mock_bin:/usr/bin:/bin" MOCK_GIT_MODE=delegate \
    "$public_repo/scripts/validate-sp11-public-content.sh" 2>&1
)" || public_status=$?
[ "$public_status" -eq 1 ] || {
  printf 'public validator returned %s instead of rejecting the hidden file:\n%s\n' \
    "$public_status" "$public_output" >&2
  exit 1
}
grep -Fq 'docs/private.txt' <<< "$public_output" || {
  printf 'public validator did not report the real indexed file:\n%s\n' \
    "$public_output" >&2
  exit 1
}

# Password protection does not make private-key material public. Keep the
# marker split in this tracked fixture so the repository-wide scanner does not
# incorrectly flag the test source itself.
encrypted_key_fixture="$test_root/encrypted-private-key.txt"
printf '%s%s\n%s\n' \
  '-----BEGIN ENCRYPTED ' 'PRIVATE KEY-----' \
  'fixture bytes are deliberately not a real key' > "$encrypted_key_fixture"
public_status=0
public_output="$(
  "$public_repo/scripts/validate-sp11-public-content.sh" \
    --file "$encrypted_key_fixture" 2>&1
)" || public_status=$?
[ "$public_status" -eq 1 ] || {
  printf 'public validator accepted an encrypted private-key marker:\n%s\n' \
    "$public_output" >&2
  exit 1
}
grep -Fq 'public text input 1' <<< "$public_output" || {
  printf 'public validator did not identify the encrypted-key input safely:\n%s\n' \
    "$public_output" >&2
  exit 1
}
if grep -Fq 'fixture bytes' <<< "$public_output"; then
  die 'public validator disclosed encrypted-key fixture contents'
fi

private_item_fixture="$test_root/private-secret-store-item.txt"
printf '%s%s\n' 'https://start.1password.com/' 'open/fixture-item-identifier' > \
  "$private_item_fixture"
public_status=0
public_output="$(
  "$public_repo/scripts/validate-sp11-public-content.sh" \
    --file "$private_item_fixture" 2>&1
)" || public_status=$?
[ "$public_status" -eq 1 ] ||
  die 'public validator accepted a private secret-store item link'
grep -Fq 'public text input 1' <<< "$public_output" ||
  die 'public validator did not identify the private secret-store link safely'
if grep -Fq 'fixture-item-identifier' <<< "$public_output"; then
  die 'public validator disclosed the private secret-store fixture identifier'
fi

# The patch smoke test must fetch the declared tag under a sanitized Git
# environment and compare FETCH_HEAD with the exact pinned commit.
patch_repo="$test_root/patch-repo"
upstream_repo="$test_root/upstream-repo"
patch_baseline="$test_root/patch-baseline.env"
patch_mismatch_baseline="$test_root/patch-mismatch-baseline.env"
mkdir -p "$patch_repo/scripts" "$patch_repo/patches/fixture" \
  "$upstream_repo/drivers"
cp "$repo_dir/scripts/test-sp11-kernel-patches.sh" "$patch_repo/scripts/"
printf '%s\n' 'old value' > "$upstream_repo/drivers/fixture.c"
configure_fixture_repository "$upstream_repo"
"$real_git" -C "$upstream_repo" add drivers/fixture.c
"$real_git" -C "$upstream_repo" commit --quiet -m 'Create patch upstream fixture'
upstream_commit="$("$real_git" -C "$upstream_repo" rev-parse 'HEAD^{commit}')"
"$real_git" -C "$upstream_repo" tag fixture-tag

cat > "$patch_repo/patches/fixture/0001-fixture.patch" <<'EOF_PATCH'
diff --git a/drivers/fixture.c b/drivers/fixture.c
--- a/drivers/fixture.c
+++ b/drivers/fixture.c
@@ -1 +1 @@
-old value
+new value
EOF_PATCH
{
  printf "SP11_KERNEL_UPSTREAM_URL='%s'\n" "$upstream_repo"
  printf "SP11_KERNEL_UPSTREAM_REF='%s'\n" fixture-tag
  printf "SP11_KERNEL_UPSTREAM_COMMIT='%s'\n" "$upstream_commit"
  printf "SP11_KERNEL_PATCH_DIRS='%s'\n" patches/fixture
} > "$patch_baseline"

patch_output="$(
  run_with_hostile_git_environment \
    "$test_root/invalid-patch-git-dir" "$test_root/invalid-patch-worktree" \
    "$test_root/invalid-patch-index" \
    env PATH="$mock_bin:/usr/bin:/bin" MOCK_GIT_MODE=delegate \
    "$patch_repo/scripts/test-sp11-kernel-patches.sh" "$patch_baseline" 2>&1
)" || {
  printf 'patch smoke test failed under hostile Git environment:\n%s\n' \
    "$patch_output" >&2
  exit 1
}
grep -Fq "at $upstream_commit" <<< "$patch_output" || {
  printf 'patch smoke test did not report the exact fetched commit:\n%s\n' \
    "$patch_output" >&2
  exit 1
}
grep -Fq 'fetch --quiet --depth=1 --filter=blob:none origin refs/tags/fixture-tag' \
  "$git_log" || die 'patch smoke test did not fetch the exact declared tag'

{
  printf "SP11_KERNEL_UPSTREAM_URL='%s'\n" "$upstream_repo"
  printf "SP11_KERNEL_UPSTREAM_REF='%s'\n" fixture-tag
  printf "SP11_KERNEL_UPSTREAM_COMMIT='%040d'\n" 0
  printf "SP11_KERNEL_PATCH_DIRS='%s'\n" patches/fixture
} > "$patch_mismatch_baseline"
patch_mismatch_status=0
patch_mismatch_output="$(
  run_with_hostile_git_environment \
    "$test_root/invalid-patch-git-dir" "$test_root/invalid-patch-worktree" \
    "$test_root/invalid-patch-index" \
    env PATH="$mock_bin:/usr/bin:/bin" MOCK_GIT_MODE=delegate \
    "$patch_repo/scripts/test-sp11-kernel-patches.sh" \
    "$patch_mismatch_baseline" 2>&1
)" || patch_mismatch_status=$?
[ "$patch_mismatch_status" -ne 0 ] || die 'patch smoke test accepted a mismatched commit'
grep -Fq "upstream ref resolved to $upstream_commit" <<< "$patch_mismatch_output" || {
  printf 'patch smoke mismatch did not expose the exact resolved commit:\n%s\n' \
    "$patch_mismatch_output" >&2
  exit 1
}

# The thin-fork validator's ls-remote call must not consume caller-provided Git
# config, redirect, namespace, or replacement-object settings.
fork_baseline="$test_root/fork-baseline.env"
fork_base_ref='sp11/base-fixture'
fork_integration_ref='sp11/integration-fixture'
fork_base_commit='1111111111111111111111111111111111111111'
fork_integration_commit='2222222222222222222222222222222222222222'
{
  printf "SP11_KERNEL_FORK_URL='%s'\n" \
    'https://github.com/example/sp11-kernel.git'
  printf "SP11_KERNEL_FORK_BASE_REF='%s'\n" "$fork_base_ref"
  printf "SP11_KERNEL_FORK_BASE_COMMIT='%s'\n" "$fork_base_commit"
  printf "SP11_KERNEL_FORK_INTEGRATION_REF='%s'\n" "$fork_integration_ref"
  printf "SP11_KERNEL_FORK_INTEGRATION_COMMIT='%s'\n" \
    "$fork_integration_commit"
} > "$fork_baseline"

fork_output="$(
  run_with_hostile_git_environment \
    "$test_root/invalid-fork-git-dir" "$test_root/invalid-fork-worktree" \
    "$test_root/invalid-fork-index" \
    env PATH="$mock_bin:/usr/bin:/bin" MOCK_GIT_MODE=fork \
    MOCK_FORK_BASE_REF="$fork_base_ref" \
    MOCK_FORK_BASE_COMMIT="$fork_base_commit" \
    MOCK_FORK_INTEGRATION_REF="$fork_integration_ref" \
    MOCK_FORK_INTEGRATION_COMMIT="$fork_integration_commit" \
    "$repo_dir/scripts/validate-sp11-kernel-fork-refs.sh" \
    "$fork_baseline" 2>&1
)" || {
  printf 'thin-fork validation failed under hostile Git environment:\n%s\n' \
    "$fork_output" >&2
  exit 1
}
grep -Fq "Validated thin-fork branch $fork_base_ref at $fork_base_commit" \
  <<< "$fork_output" || die 'thin-fork base result was not exact'
grep -Fq \
  "Validated thin-fork branch $fork_integration_ref at $fork_integration_commit" \
  <<< "$fork_output" || die 'thin-fork integration result was not exact'

# The nonpublishable audio local-draft manifest must describe the original HEAD
# and observe a dirty worktree even when a persistent replacement ref and
# redirected clean repository would otherwise claim a different identity and
# clean state.
audio_repo="$test_root/audio-repo"
audio_assets="$audio_repo/payload/audio"
hostile_audio_repo="$test_root/hostile-audio-repo"
mkdir -p "$audio_repo/scripts" "$audio_assets" "$hostile_audio_repo"
cp "$repo_dir/scripts/prepare-sp11-audio-release-assets.sh" "$audio_repo/scripts/"
for asset in \
  X1E80100-Microsoft-Surface-Pro-11-tplg.bin \
  MICROSOFT-Surface-Pro-11.conf Surface11-HiFi.conf x1e80100.conf CMakeLists.txt; do
  printf 'fixture asset: %s\n' "$asset" > "$audio_assets/$asset"
done
printf '%s\n' 'original support tree' > "$audio_repo/README.md"
configure_fixture_repository "$audio_repo"
"$real_git" -C "$audio_repo" add .
"$real_git" -C "$audio_repo" commit --quiet -m 'Create audio local-draft fixture'
audio_original_commit="$("$real_git" -C "$audio_repo" rev-parse 'HEAD^{commit}')"

printf '%s\n' 'replacement support tree' > "$audio_repo/README.md"
"$real_git" -C "$audio_repo" commit --quiet -am 'Create replacement tree'
audio_replacement_commit="$("$real_git" -C "$audio_repo" rev-parse 'HEAD^{commit}')"
"$real_git" -C "$audio_repo" replace \
  "$audio_original_commit" "$audio_replacement_commit"
"$real_git" -C "$audio_repo" checkout --quiet --detach "$audio_original_commit"
[ -z "$("$real_git" -C "$audio_repo" status --porcelain --untracked-files=all)" ] ||
  die 'replacement-ref audio fixture was not falsely clean with replacements enabled'
[ -n "$(GIT_NO_REPLACE_OBJECTS=1 "$real_git" -C "$audio_repo" \
  status --porcelain --untracked-files=all)" ] ||
  die 'replacement-ref audio fixture was not dirty with replacements disabled'

configure_fixture_repository "$hostile_audio_repo"
printf '%s\n' 'redirected clean support tree' > "$hostile_audio_repo/README.md"
"$real_git" -C "$hostile_audio_repo" add README.md
"$real_git" -C "$hostile_audio_repo" commit --quiet -m 'Create redirected fixture'
hostile_audio_commit="$("$real_git" -C "$hostile_audio_repo" rev-parse 'HEAD^{commit}')"
[ "$hostile_audio_commit" != "$audio_original_commit" ] ||
  die 'redirected audio fixture unexpectedly reused the original commit'
[ -z "$(GIT_DIR="$hostile_audio_repo/.git" GIT_WORK_TREE="$hostile_audio_repo" \
  "$real_git" status --porcelain --untracked-files=all)" ] ||
  die 'redirected audio fixture was not clean'

audio_no_flag_status=0
audio_no_flag_output="$(
  "$audio_repo/scripts/prepare-sp11-audio-release-assets.sh" \
    --release-name no-flag \
    --out-dir build/local-drafts/audio/no-flag 2>&1
)" || audio_no_flag_status=$?
[ "$audio_no_flag_status" -eq 2 ] || {
  printf 'audio helper returned %s instead of requiring --local-draft:\n%s\n' \
    "$audio_no_flag_status" "$audio_no_flag_output" >&2
  exit 1
}
grep -Fq 'explicit --local-draft acknowledgement' <<< "$audio_no_flag_output" || {
  printf 'audio helper did not explain its local-draft gate:\n%s\n' \
    "$audio_no_flag_output" >&2
  exit 1
}
[ ! -e "$audio_repo/build/local-drafts/audio/no-flag" ] ||
  die 'audio helper created output without --local-draft'

audio_output="$(
  run_with_hostile_git_environment \
    "$hostile_audio_repo/.git" "$hostile_audio_repo" \
    "$test_root/hostile-audio-index" \
    env PATH="$mock_bin:/usr/bin:/bin" MOCK_GIT_MODE=delegate \
    "$audio_repo/scripts/prepare-sp11-audio-release-assets.sh" \
    --local-draft --release-name fixture-audio \
    --out-dir build/local-drafts/audio/fixture-audio 2>&1
)" || {
  printf 'audio local-draft preparation failed under hostile Git environment:\n%s\n' \
    "$audio_output" >&2
  exit 1
}
audio_draft_dir="$audio_repo/build/local-drafts/audio/fixture-audio"
audio_manifest="$audio_draft_dir/sp11-audio-topology-manifest.txt"
audio_notes="$audio_draft_dir/RELEASE-NOTES.md"
grep -Fxq 'Artifact classification: NONPUBLISHABLE LOCAL DRAFT' \
  "$audio_manifest" || die 'audio manifest lacked the nonpublishable classification'
grep -Fxq 'Publishable: no' "$audio_manifest" ||
  die 'audio manifest did not explicitly prohibit publishing'
grep -Fq 'Publication gate: blocked' "$audio_manifest" ||
  die 'audio manifest did not record the blocked publication gate'
grep -Fq 'd7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677' "$audio_manifest" ||
  die 'audio manifest did not record the full AudioReach source commit'
grep -Fq 'NONPUBLISHABLE LOCAL DRAFT' "$audio_notes" ||
  die 'audio release notes lacked the nonpublishable local-draft warning'
grep -Fq 'd7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677' "$audio_notes" ||
  die 'audio release notes did not record the full AudioReach source commit'
if grep -Eq 'gh[[:space:]]+release[[:space:]]+(create|upload)' <<< "$audio_output"; then
  die 'audio local-draft helper printed a GitHub release command'
fi
grep -Fxq "Support repo commit: $audio_original_commit" "$audio_manifest" || {
  printf 'audio manifest did not bind the original full HEAD:\n' >&2
  grep -F 'Support repo commit:' "$audio_manifest" >&2 || true
  exit 1
}
grep -Fxq 'Support repo dirty: true' "$audio_manifest" ||
  die 'audio manifest claimed a replacement-masked worktree was clean'
if grep -Fq "$hostile_audio_commit" "$audio_manifest"; then
  die 'audio manifest consumed the redirected repository HEAD'
fi

audio_symlink_target="$test_root/audio-symlink-target.conf"
audio_symlink_input="$audio_assets/Surface11-HiFi.conf"
cp "$audio_symlink_input" "$audio_symlink_target"
rm "$audio_symlink_input"
ln -s "$audio_symlink_target" "$audio_symlink_input"
audio_symlink_status=0
audio_symlink_output="$(
  "$audio_repo/scripts/prepare-sp11-audio-release-assets.sh" \
    --local-draft --release-name symlink-input \
    --out-dir build/local-drafts/audio/symlink-input 2>&1
)" || audio_symlink_status=$?
[ "$audio_symlink_status" -ne 0 ] ||
  die 'audio local-draft helper accepted a symlinked asset input'
grep -Fq 'Refusing symlinked audio asset input' <<< "$audio_symlink_output" || {
  printf 'audio symlink rejection was not explicit:\n%s\n' \
    "$audio_symlink_output" >&2
  exit 1
}
[ ! -e "$audio_repo/build/local-drafts/audio/symlink-input" ] ||
  die 'audio helper created output for a symlinked asset input'
rm "$audio_symlink_input"
cp "$audio_symlink_target" "$audio_symlink_input"

audio_special_input="$audio_assets/Surface11-HiFi.conf"
rm "$audio_special_input"
mkfifo "$audio_special_input"
audio_special_status=0
audio_special_output="$(
  "$audio_repo/scripts/prepare-sp11-audio-release-assets.sh" \
    --local-draft --release-name special-input \
    --out-dir build/local-drafts/audio/special-input 2>&1
)" || audio_special_status=$?
[ "$audio_special_status" -ne 0 ] ||
  die 'audio local-draft helper accepted a nonregular asset input'
grep -Fq 'Refusing nonregular audio asset input' <<< "$audio_special_output" || {
  printf 'audio nonregular-input rejection was not explicit:\n%s\n' \
    "$audio_special_output" >&2
  exit 1
}
[ ! -e "$audio_repo/build/local-drafts/audio/special-input" ] ||
  die 'audio helper created output for a nonregular asset input'
rm "$audio_special_input"
cp "$audio_symlink_target" "$audio_special_input"

# A dry-run annotations regeneration must put the same sanitizer inside the
# generated Docker entrypoint. Execute its generated prefix under a hostile
# environment so this checks behavior, not just emitted text.
annotation_repo="$test_root/annotation-repo"
annotation_prefix="$test_root/annotation-sanitizer-prefix.sh"
mkdir -p "$annotation_repo/scripts" \
  "$annotation_repo/patches/jglathe-qcom-x1e-7.2-rc5"
annotation_repo="$(cd "$annotation_repo" && pwd -P)"
annotation_patch_dir="$annotation_repo/patches/jglathe-qcom-x1e-7.2-rc5"
annotation_work="$annotation_repo/build/annotation-work"
cp "$repo_dir/scripts/regenerate-qcom-x1e-annotations.sh" \
  "$annotation_repo/scripts/"

annotation_output="$(
  run_with_hostile_git_environment \
    "$test_root/invalid-annotation-git-dir" \
    "$test_root/invalid-annotation-worktree" \
    "$test_root/invalid-annotation-index" \
    "$annotation_repo/scripts/regenerate-qcom-x1e-annotations.sh" \
    --git-url https://fixtures.example.com/kernel.git \
    --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
    --patch-dir "$annotation_patch_dir" \
    --work-dir "$annotation_work" --dry-run 2>&1
)" || {
  printf 'annotations dry-run failed under hostile Git environment:\n%s\n' \
    "$annotation_output" >&2
  exit 1
}
annotation_inner="$annotation_work/docker-regenerate-inside.sh"
[ -f "$annotation_inner" ] || die 'annotations dry-run did not generate its Docker script'
awk '
  { print }
  /^sanitize_git_environment$/ { found = 1; exit }
  END { if (!found) exit 1 }
' "$annotation_inner" > "$annotation_prefix" ||
  die 'generated annotations Docker script omitted its sanitizer invocation'
printf '%s\n' '. "$SANITIZED_ASSERTION"' >> "$annotation_prefix"

run_with_hostile_git_environment \
  "$test_root/invalid-inner-git-dir" "$test_root/invalid-inner-worktree" \
  "$test_root/invalid-inner-index" \
  /bin/bash "$annotation_prefix" ||
  die 'generated annotations Docker sanitizer did not neutralize the hostile environment'

printf '%s\n' \
  'Git boundary sanitization and replacement-ref regression tests passed.'
