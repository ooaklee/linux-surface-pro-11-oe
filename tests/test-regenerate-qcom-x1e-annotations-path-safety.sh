#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root=""
temporary_parent=""
original_path="$PATH"

cleanup() {
  [ -n "$temporary_root" ] || return 0
  if [ "$(dirname "$temporary_root")" = "$temporary_parent" ] &&
     [[ "$(basename "$temporary_root")" == sp11-annotations-safety.* ]]; then
    rm -rf -- "$temporary_root"
  else
    printf 'warning: refusing to remove unexpected fixture path: %s\n' "$temporary_root" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

node_metadata() {
  local path="$1"

  case "$(uname -s)" in
    Darwin) stat -f '%HT:%i:%Lp:%u:%g:%z:%m' "$path" ;;
    *) stat -c '%F:%i:%a:%u:%g:%s:%Y' -- "$path" ;;
  esac
}

regular_fingerprint() {
  local path="$1"

  printf '%s:%s\n' "$(cksum < "$path")" "$(node_metadata "$path")"
}

assert_no_private_stages() {
  local work_dir="$1" patch_dir="$2"

  if find "$work_dir" -maxdepth 1 -name '.sp11-annotations-control.*' 2>/dev/null |
      grep -q .; then
    die "private annotations control stage survived: $work_dir"
  fi
  if find "$patch_dir" -maxdepth 1 -name '.sp11-annotations-patch.*' 2>/dev/null |
      grep -q .; then
    die "private annotations patch stage survived: $patch_dir"
  fi
}

seed_managed_patches() {
  local patch_dir="$1"

  mkdir -p "$patch_dir"
  printf 'old destination patch\n' > "$patch_dir/$patch_basename"
  printf 'old legacy patch\n' > "$patch_dir/0001-legacy-annotations.patch"
  printf 'unrelated second patch\n' > "$patch_dir/0002-unrelated.patch"
  printf 'unrelated notes\n' > "$patch_dir/NOTES.txt"
}

capture_managed_fingerprints() {
  local patch_dir="$1"

  destination_before="$(regular_fingerprint "$patch_dir/$patch_basename")"
  legacy_before="$(regular_fingerprint "$patch_dir/0001-legacy-annotations.patch")"
  unrelated_before="$(regular_fingerprint "$patch_dir/0002-unrelated.patch")"
  notes_before="$(regular_fingerprint "$patch_dir/NOTES.txt")"
}

assert_managed_patches_unchanged() {
  local patch_dir="$1"

  [ "$(regular_fingerprint "$patch_dir/$patch_basename")" = "$destination_before" ] ||
    die "destination patch changed on a rejected run: $patch_dir"
  [ "$(regular_fingerprint "$patch_dir/0001-legacy-annotations.patch")" = "$legacy_before" ] ||
    die "legacy patch changed on a rejected run: $patch_dir"
  [ "$(regular_fingerprint "$patch_dir/0002-unrelated.patch")" = "$unrelated_before" ] ||
    die "unrelated second patch changed on a rejected run: $patch_dir"
  [ "$(regular_fingerprint "$patch_dir/NOTES.txt")" = "$notes_before" ] ||
    die "unrelated notes changed on a rejected run: $patch_dir"
}

for tool in awk cksum find git grep mkfifo mktemp shasum stat; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-annotations-safety.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
temporary_parent="$(dirname "$temporary_root")"
support_dir="$temporary_root/support"
mock_bin="$temporary_root/mock-bin"
mkdir -p "$support_dir/scripts" "$support_dir/build" "$support_dir/patches" "$mock_bin"
cp "$repo_dir/scripts/regenerate-qcom-x1e-annotations.sh" "$support_dir/scripts/"
chmod +x "$support_dir/scripts/regenerate-qcom-x1e-annotations.sh"

generator="$support_dir/scripts/regenerate-qcom-x1e-annotations.sh"
git_url="https://fixtures.example.com/kernel.git"
git_branch="jg/ubuntu-qcom-x1e-7.2-rc5-jg-0"
version_token="7.2-rc5-jg-0"
base_version="7.2-rc5"
patch_basename="0001-debian-qcom-x1e-update-annotations-for-${version_token}.patch"

cat > "$mock_bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

host_work=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-v" ] && [ "$#" -ge 2 ]; then
    case "$2" in
      *:/work) host_work="${2%:/work}" ;;
    esac
    shift 2
  else
    shift
  fi
done

[ -n "$host_work" ]
control="$host_work/docker-regenerate-inside.sh"
[ -f "$control" ] && [ ! -L "$control" ] && [ -x "$control" ]
case "$(uname -s)" in
  Darwin) control_mode="$(stat -f '%Lp' "$control")" ;;
  *) control_mode="$(stat -c '%a' "$control")" ;;
esac
[ "$control_mode" = "700" ]
if find "$host_work" -maxdepth 1 -name '.sp11-annotations-control.*' | grep -q .; then
  printf 'private control stage visible to Docker\n' >&2
  exit 90
fi

printf 'mock Docker invoked\n' > "$host_work/mock-docker-invoked"
patch="$host_work/0001-debian-qcom-x1e-update-annotations-for-${MOCK_VERSION_TOKEN}.patch"
case "${MOCK_GENERATED_KIND:-valid}" in
  valid)
    cat > "$patch" <<'EOF_PATCH'
diff --git a/debian.qcom-x1e/config/annotations b/debian.qcom-x1e/config/annotations
--- a/debian.qcom-x1e/config/annotations
+++ b/debian.qcom-x1e/config/annotations
@@ -1 +1 @@
-old
+new
EOF_PATCH
    ;;
  empty) : > "$patch" ;;
  symlink) ln -s "$MOCK_VICTIM" "$patch" ;;
  fifo) mkfifo "$patch" ;;
  directory) mkdir "$patch" ;;
  control-rewrite)
    printf 'changed control bytes\n' > "$control"
    chmod 700 "$control"
    cat > "$patch" <<'EOF_PATCH'
diff --git a/a b/a
--- a/a
+++ b/a
@@ -1 +1 @@
-old
+new
EOF_PATCH
    ;;
  *) printf 'unknown generated kind: %s\n' "$MOCK_GENERATED_KIND" >&2; exit 91 ;;
esac
printf 'fixture annotations\n' > "$host_work/annotations.after"
EOF_DOCKER
chmod +x "$mock_bin/docker"

run_generator() {
  local patch_dir="$1" work_dir="$2" generated_kind="$3" victim="$4"
  shift 4

  env \
    PATH="$mock_bin:$original_path" \
    MOCK_GENERATED_KIND="$generated_kind" \
    MOCK_VERSION_TOKEN="$version_token" \
    MOCK_VICTIM="$victim" \
    "$generator" \
      --git-url "$git_url" \
      --git-branch "$git_branch" \
      --version-token "$version_token" \
      --base-version "$base_version" \
      --patch-dir "$patch_dir" \
      --work-dir "$work_dir" \
      "$@"
}

# A dry run installs only regular mode-0700 control evidence and leaves prior
# regular generated outputs untouched.
dry_patch="$support_dir/patches/dry-run"
dry_work="$support_dir/build/dry-run/work"
mkdir -p "$dry_patch" "$dry_work"
printf 'prior generated patch\n' > "$dry_work/$patch_basename"
printf 'prior annotations\n' > "$dry_work/annotations.after"
dry_patch_before="$(regular_fingerprint "$dry_work/$patch_basename")"
dry_annotations_before="$(regular_fingerprint "$dry_work/annotations.after")"
run_generator "$dry_patch" "$dry_work" valid /dev/null --dry-run \
  > "$temporary_root/dry-run.log"
[ "$(regular_fingerprint "$dry_work/$patch_basename")" = "$dry_patch_before" ] ||
  die 'dry run changed a prior generated patch'
[ "$(regular_fingerprint "$dry_work/annotations.after")" = "$dry_annotations_before" ] ||
  die 'dry run changed prior annotations evidence'
[ -f "$dry_work/docker-regenerate-inside.sh" ] &&
  [ ! -L "$dry_work/docker-regenerate-inside.sh" ] ||
  die 'dry run did not install regular control evidence'
[ "$(node_metadata "$dry_work/docker-regenerate-inside.sh" | awk -F: '{print $3}')" = "700" ] ||
  die 'control evidence does not have mode 0700'
grep -Fq 'GIT_NO_REPLACE_OBJECTS=1' "$dry_work/docker-regenerate-inside.sh" ||
  die 'inner control evidence omitted the Git replacement-ref sanitizer'
grep -Fq 'Existing source has tracked or untracked changes' \
  "$dry_work/docker-regenerate-inside.sh" ||
  die 'inner control evidence omitted the existing-source clean guard'
grep -Fq 'remote get-url origin' "$dry_work/docker-regenerate-inside.sh" ||
  die 'inner control evidence omitted the existing-origin binding'
grep -Fq 'declared_ref_matches' "$dry_work/docker-regenerate-inside.sh" ||
  die 'inner control evidence omitted the keep-source ref binding'
if grep -Fq 'reset --hard' "$dry_work/docker-regenerate-inside.sh"; then
  die 'inner control evidence can reset an existing checkout without explicit removal'
fi
assert_no_private_stages "$dry_work" "$dry_patch"

# The former predictable control path is a tripwire. Neither a symlink nor a
# special node may be replaced or followed.
control_victim="$temporary_root/control-victim"
printf 'control victim must remain unchanged\n' > "$control_victim"
control_victim_before="$(regular_fingerprint "$control_victim")"
for control_kind in symlink fifo; do
  control_patch="$support_dir/patches/control-$control_kind"
  control_work="$support_dir/build/control-$control_kind/work"
  mkdir -p "$control_patch" "$control_work"
  control_leaf="$control_work/docker-regenerate-inside.sh"
  case "$control_kind" in
    symlink) ln -s "$control_victim" "$control_leaf" ;;
    fifo) mkfifo "$control_leaf" ;;
  esac
  control_before="$(node_metadata "$control_leaf")"
  if run_generator "$control_patch" "$control_work" valid "$control_victim" --dry-run \
      > "$temporary_root/control-$control_kind.log" 2>&1; then
    die "accepted $control_kind control tripwire"
  fi
  [ "$(node_metadata "$control_leaf")" = "$control_before" ] ||
    die "mutated $control_kind control tripwire"
  [ "$(regular_fingerprint "$control_victim")" = "$control_victim_before" ] ||
    die "mutated control symlink victim for $control_kind"
  assert_no_private_stages "$control_work" "$control_patch"
done

# Storage arguments are canonical tokens, not host paths or protected mounts.
invalid_volume_work="$support_dir/build/invalid-volume/work"
if run_generator "$support_dir/patches/dry-run" "$invalid_volume_work" valid /dev/null \
    --linux-work-volume / --dry-run > "$temporary_root/invalid-volume.log" 2>&1; then
  die 'accepted / as a Docker named volume'
fi
[ ! -e "$invalid_volume_work" ] || die 'invalid named volume created its work directory'
grep -Fq 'must be a Docker named volume' "$temporary_root/invalid-volume.log" ||
  die 'named-volume rejection was not explicit'

invalid_url_work="$support_dir/build/invalid-url/work"
if env PATH="$mock_bin:$original_path" "$generator" \
    --git-url https://192.168.1.2/kernel.git \
    --git-branch "$git_branch" \
    --version-token "$version_token" \
    --base-version "$base_version" \
    --patch-dir "$support_dir/patches/dry-run" \
    --work-dir "$invalid_url_work" --dry-run \
    > "$temporary_root/invalid-url.log" 2>&1; then
  die 'accepted a private numeric address as a public Git URL'
fi
[ ! -e "$invalid_url_work" ] || die 'invalid Git URL created its work directory'

container_case=0
for invalid_container in \
  '/linux-work/../repo' '/safe//work' '/safe/work/' $'/safe/\twork' '/repo'; do
  container_case=$((container_case + 1))
  invalid_work="$support_dir/build/invalid-container-$container_case/work"
  if run_generator "$support_dir/patches/dry-run" "$invalid_work" valid /dev/null \
      --container-work-dir "$invalid_container" --dry-run \
      > "$temporary_root/invalid-container-$container_case.log" 2>&1; then
    die "accepted unsafe container work path: $invalid_container"
  fi
  [ ! -e "$invalid_work" ] || die 'invalid container path created its work directory'
done

# Host work and patch paths may not traverse symlink components or escape their
# dedicated repository roots.
work_escape="$temporary_root/work-escape"
mkdir -p "$work_escape"
printf 'work escape victim\n' > "$work_escape/victim"
work_escape_before="$(regular_fingerprint "$work_escape/victim")"
ln -s "$work_escape" "$support_dir/build/work-link"
if run_generator "$support_dir/patches/dry-run" "$support_dir/build/work-link/work" \
    valid /dev/null --dry-run > "$temporary_root/work-link.log" 2>&1; then
  die 'accepted a symlink component in --work-dir'
fi
[ ! -e "$work_escape/work" ] || die 'created a work directory through a symlink'
[ "$(regular_fingerprint "$work_escape/victim")" = "$work_escape_before" ] ||
  die 'mutated the work-path symlink victim'

patch_escape="$temporary_root/patch-escape"
mkdir -p "$patch_escape"
printf 'patch escape victim\n' > "$patch_escape/victim"
patch_escape_before="$(regular_fingerprint "$patch_escape/victim")"
ln -s "$patch_escape" "$support_dir/patches/patch-link"
if run_generator "$support_dir/patches/patch-link" "$support_dir/build/patch-link/work" \
    valid /dev/null --dry-run > "$temporary_root/patch-link.log" 2>&1; then
  die 'accepted a symlink component in --patch-dir'
fi
[ "$(regular_fingerprint "$patch_escape/victim")" = "$patch_escape_before" ] ||
  die 'mutated the patch-path symlink victim'

if run_generator "$support_dir/patches/dry-run" "$support_dir/build" valid /dev/null \
    --dry-run > "$temporary_root/build-root.log" 2>&1; then
  die 'accepted the repository build root as --work-dir'
fi

# Every exact 0001-*.patch leaf is preflighted as regular before Docker runs.
for stale_kind in symlink fifo; do
  stale_patch="$support_dir/patches/stale-$stale_kind"
  stale_work="$support_dir/build/stale-$stale_kind/work"
  seed_managed_patches "$stale_patch"
  capture_managed_fingerprints "$stale_patch"
  rm -f "$stale_patch/0001-legacy-annotations.patch"
  stale_victim="$temporary_root/stale-$stale_kind-victim"
  printf 'stale victim must remain unchanged\n' > "$stale_victim"
  stale_victim_before="$(regular_fingerprint "$stale_victim")"
  case "$stale_kind" in
    symlink) ln -s "$stale_victim" "$stale_patch/0001-legacy-annotations.patch" ;;
    fifo) mkfifo "$stale_patch/0001-legacy-annotations.patch" ;;
  esac
  stale_node_before="$(node_metadata "$stale_patch/0001-legacy-annotations.patch")"
  destination_before="$(regular_fingerprint "$stale_patch/$patch_basename")"
  unrelated_before="$(regular_fingerprint "$stale_patch/0002-unrelated.patch")"
  notes_before="$(regular_fingerprint "$stale_patch/NOTES.txt")"
  if run_generator "$stale_patch" "$stale_work" valid "$stale_victim" \
      > "$temporary_root/stale-$stale_kind.log" 2>&1; then
    die "accepted a $stale_kind stale 0001 patch"
  fi
  [ "$(node_metadata "$stale_patch/0001-legacy-annotations.patch")" = "$stale_node_before" ] ||
    die "mutated a $stale_kind stale patch tripwire"
  [ "$(regular_fingerprint "$stale_patch/$patch_basename")" = "$destination_before" ] ||
    die 'mutated destination peer after stale tripwire rejection'
  [ "$(regular_fingerprint "$stale_patch/0002-unrelated.patch")" = "$unrelated_before" ] ||
    die 'mutated unrelated patch after stale tripwire rejection'
  [ "$(regular_fingerprint "$stale_patch/NOTES.txt")" = "$notes_before" ] ||
    die 'mutated unrelated notes after stale tripwire rejection'
  [ "$(regular_fingerprint "$stale_victim")" = "$stale_victim_before" ] ||
    die "mutated stale $stale_kind victim"
  [ ! -e "$stale_work/mock-docker-invoked" ] || die 'Docker ran despite stale tripwire'
done

# The intended destination is subject to the same all-leaf preflight; atomic
# installation must never follow a destination symlink.
destination_patch="$support_dir/patches/destination-symlink"
destination_work="$support_dir/build/destination-symlink/work"
seed_managed_patches "$destination_patch"
rm -f "$destination_patch/$patch_basename"
destination_victim="$temporary_root/destination-symlink-victim"
printf 'destination victim must remain unchanged\n' > "$destination_victim"
destination_victim_before="$(regular_fingerprint "$destination_victim")"
ln -s "$destination_victim" "$destination_patch/$patch_basename"
destination_node_before="$(node_metadata "$destination_patch/$patch_basename")"
legacy_before="$(regular_fingerprint "$destination_patch/0001-legacy-annotations.patch")"
unrelated_before="$(regular_fingerprint "$destination_patch/0002-unrelated.patch")"
if run_generator "$destination_patch" "$destination_work" valid "$destination_victim" \
    > "$temporary_root/destination-symlink.log" 2>&1; then
  die 'accepted a symlinked destination patch'
fi
[ "$(node_metadata "$destination_patch/$patch_basename")" = "$destination_node_before" ] ||
  die 'mutated the destination symlink'
[ "$(regular_fingerprint "$destination_victim")" = "$destination_victim_before" ] ||
  die 'mutated the destination symlink victim'
[ "$(regular_fingerprint "$destination_patch/0001-legacy-annotations.patch")" = "$legacy_before" ] ||
  die 'mutated a stale peer after destination rejection'
[ "$(regular_fingerprint "$destination_patch/0002-unrelated.patch")" = "$unrelated_before" ] ||
  die 'mutated an unrelated peer after destination rejection'

# Predictable generated-output tripwires are rejected before Docker can follow
# them as root.
for source_kind in symlink fifo; do
  source_patch="$support_dir/patches/source-$source_kind"
  source_work="$support_dir/build/source-$source_kind/work"
  mkdir -p "$source_patch" "$source_work"
  source_victim="$temporary_root/source-$source_kind-victim"
  printf 'generated source victim\n' > "$source_victim"
  source_victim_before="$(regular_fingerprint "$source_victim")"
  source_leaf="$source_work/$patch_basename"
  case "$source_kind" in
    symlink) ln -s "$source_victim" "$source_leaf" ;;
    fifo) mkfifo "$source_leaf" ;;
  esac
  source_node_before="$(node_metadata "$source_leaf")"
  if run_generator "$source_patch" "$source_work" valid "$source_victim" \
      > "$temporary_root/source-$source_kind.log" 2>&1; then
    die "accepted a $source_kind generated-output tripwire"
  fi
  [ "$(node_metadata "$source_leaf")" = "$source_node_before" ] ||
    die "mutated a $source_kind generated-output tripwire"
  [ "$(regular_fingerprint "$source_victim")" = "$source_victim_before" ] ||
    die "mutated generated-output $source_kind victim"
  [ ! -e "$source_work/mock-docker-invoked" ] || die 'Docker ran despite output tripwire'
done

# Invalid container output and control evidence must fail after mock Docker but
# before any existing destination patch is changed.
for generated_kind in empty symlink fifo directory control-rewrite; do
  generated_patch="$support_dir/patches/generated-$generated_kind"
  generated_work="$support_dir/build/generated-$generated_kind/work"
  seed_managed_patches "$generated_patch"
  capture_managed_fingerprints "$generated_patch"
  generated_victim="$temporary_root/generated-$generated_kind-victim"
  printf 'generated victim must remain unchanged\n' > "$generated_victim"
  generated_victim_before="$(regular_fingerprint "$generated_victim")"
  if run_generator "$generated_patch" "$generated_work" "$generated_kind" \
      "$generated_victim" > "$temporary_root/generated-$generated_kind.log" 2>&1; then
    die "accepted invalid generated output: $generated_kind"
  fi
  [ -f "$generated_work/mock-docker-invoked" ] ||
    die "mock Docker did not exercise generated case: $generated_kind"
  assert_managed_patches_unchanged "$generated_patch"
  [ "$(regular_fingerprint "$generated_victim")" = "$generated_victim_before" ] ||
    die "mutated generated victim for case: $generated_kind"
  assert_no_private_stages "$generated_work" "$generated_patch"
done

# A valid generated textual patch is staged on the destination filesystem,
# atomically installed, and only then replaces all stale exact 0001 leaves.
success_patch="$support_dir/patches/success"
success_work="$support_dir/build/success/work"
seed_managed_patches "$success_patch"
success_unrelated_before="$(regular_fingerprint "$success_patch/0002-unrelated.patch")"
success_notes_before="$(regular_fingerprint "$success_patch/NOTES.txt")"
run_generator "$success_patch" "$success_work" valid /dev/null \
  > "$temporary_root/success.log"
grep -q '^diff --git ' "$success_patch/$patch_basename" ||
  die 'valid generated patch was not installed'
[ ! -e "$success_patch/0001-legacy-annotations.patch" ] ||
  die 'stale exact 0001 patch survived a successful install'
[ "$(regular_fingerprint "$success_patch/0002-unrelated.patch")" = "$success_unrelated_before" ] ||
  die 'successful install mutated unrelated second patch'
[ "$(regular_fingerprint "$success_patch/NOTES.txt")" = "$success_notes_before" ] ||
  die 'successful install mutated unrelated notes'
[ -f "$success_work/docker-regenerate-inside.sh" ] &&
  [ ! -L "$success_work/docker-regenerate-inside.sh" ] ||
  die 'successful run lost regular control evidence'
[ "$(node_metadata "$success_work/docker-regenerate-inside.sh" | awk -F: '{print $3}')" = "700" ] ||
  die 'successful control evidence lost mode 0700'
assert_no_private_stages "$success_work" "$success_patch"

printf '%s\n' 'Annotations regeneration path-safety regression tests passed.'
