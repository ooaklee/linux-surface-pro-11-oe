#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root=""
temporary_parent=""
real_git="$(command -v git)"
real_mktemp="$(command -v mktemp)"
real_shasum="$(command -v shasum)"
real_stat="$(command -v stat)"

cleanup() {
  [ -n "$temporary_root" ] || return 0
  if [ "$(dirname "$temporary_root")" = "$temporary_parent" ] &&
     [[ "$(basename "$temporary_root")" == sp11-docker-wrapper-safety.* ]]; then
    rm -rf -- "$temporary_root"
  else
    printf 'warning: refusing to remove unexpected fixture path: %s\n' "$temporary_root" >&2
  fi
}
trap cleanup EXIT

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

node_full_metadata() {
  local path="$1"

  case "$(uname -s)" in
    Darwin) stat -f '%HT:%d:%i:%Lp:%u:%g:%z:%Fm:%Fc' "$path" ;;
    *) stat -c '%F:%d:%i:%a:%u:%g:%s:%y:%z' -- "$path" ;;
  esac
}

regular_fingerprint() {
  local path="$1"

  printf '%s:%s\n' "$(cksum < "$path")" "$(node_metadata "$path")"
}

for tool in git grep mktemp readlink shasum stat; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-docker-wrapper-safety.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
temporary_parent="$(dirname "$temporary_root")"
support_dir="$temporary_root/support"
mock_bin="$temporary_root/mock-bin"
capture_attack_bin="$temporary_root/capture-attack-bin"
mkdir -p \
  "$support_dir/scripts" \
  "$support_dir/config/kernel-baselines" \
  "$support_dir/patches/release" \
  "$support_dir/payload/kernel-debs" \
  "$mock_bin" \
  "$capture_attack_bin"
cp "$repo_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh" "$support_dir/scripts/"
chmod +x "$support_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh"
sed 's#/usr/lib/apt/apt-helper#/sp11-fixture-missing-apt-helper#g' \
  "$repo_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
  > "$support_dir/scripts/build-sp11-qcom-x1e-kernel-docker-no-apt-helper.sh"
chmod +x "$support_dir/scripts/build-sp11-qcom-x1e-kernel-docker-no-apt-helper.sh"
printf 'build/\n' > "$support_dir/.gitignore"
printf 'fixture patch input\n' > "$support_dir/patches/release/0001-fixture.patch"

release_oci_index="$temporary_root/release-oci-index.json"
release_child_digest="sha256:1111111111111111111111111111111111111111111111111111111111111111"
printf '%s' \
  "{\"schemaVersion\":2,\"manifests\":[{\"digest\":\"$release_child_digest\",\"platform\":{\"os\":\"linux\",\"architecture\":\"arm64\",\"variant\":\"v8\"}}]}" \
  > "$release_oci_index"
release_oci_sha="$(shasum -a 256 "$release_oci_index" | awk '{print $1}')"
release_image="ubuntu:26.04@sha256:$release_oci_sha"
release_source_commit="2222222222222222222222222222222222222222"
cat > "$support_dir/config/kernel-baselines/7.2-rc5-jg-0.env" <<EOF_BASELINE
SP11_KERNEL_BASELINE_ID="fixture"
SP11_KERNEL_DOCKER_IMAGE="$release_image"
SP11_KERNEL_DOCKER_PLATFORM="linux/arm64/v8"
SP11_KERNEL_DOCKER_PLATFORM_MANIFEST="$release_child_digest"
SP11_KERNEL_UPSTREAM_URL="https://github.com/example/linux.git"
SP11_KERNEL_UPSTREAM_REF="fixture/ref"
SP11_KERNEL_UPSTREAM_COMMIT="$release_source_commit"
SP11_KERNEL_SOURCE_DATE_EPOCH="1785567085"
SP11_KERNEL_KBUILD_BUILD_USER="sp11-builder"
SP11_KERNEL_KBUILD_BUILD_HOST="sp11-build"
SP11_KERNEL_KBUILD_BUILD_TIMESTAMP="Sat Aug  1 06:51:25 UTC 2026"
SP11_KERNEL_BUILD_TARGET="binary-indep binary-qcom-x1e"
SP11_KERNEL_PATCH_DIRS="patches/release"
EOF_BASELINE
cat > "$support_dir/scripts/validate-sp11-kernel-baseline.sh" <<'EOF_BASELINE_VALIDATOR'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--repo-dir" ]; then
  [ "$#" -ge 3 ]
  shift 2
fi
[ "${1:-}" = "--emit-release-values" ]
shift
test "$#" -eq 1
test -f "$1"
aba_control_root=""
if [ "${MOCK_BASELINE_ROOT_ABA:-false}" = "true" ]; then
  test -n "${MOCK_BASELINE_ABA_BACKUP:-}"
  aba_control_root="$(dirname "$1")"
  mv "$aba_control_root" "$MOCK_BASELINE_ABA_BACKUP/control-root"
  mkdir "$aba_control_root"
  cp "$MOCK_BASELINE_ABA_BACKUP/control-root/kernel-baseline.env" "$1"
fi
# shellcheck disable=SC1090
. "$1"
test "$SP11_KERNEL_SOURCE_DATE_EPOCH" = "1785567085"
test "$SP11_KERNEL_KBUILD_BUILD_USER" = "sp11-builder"
test "$SP11_KERNEL_KBUILD_BUILD_HOST" = "sp11-build"
test "$SP11_KERNEL_KBUILD_BUILD_TIMESTAMP" = "Sat Aug  1 06:51:25 UTC 2026"
for variable in \
  SP11_KERNEL_BASELINE_ID \
  SP11_KERNEL_DOCKER_IMAGE \
  SP11_KERNEL_DOCKER_PLATFORM \
  SP11_KERNEL_DOCKER_PLATFORM_MANIFEST \
  SP11_KERNEL_UPSTREAM_URL \
  SP11_KERNEL_UPSTREAM_REF \
  SP11_KERNEL_UPSTREAM_COMMIT \
  SP11_KERNEL_SOURCE_DATE_EPOCH \
  SP11_KERNEL_KBUILD_BUILD_USER \
  SP11_KERNEL_KBUILD_BUILD_HOST \
  SP11_KERNEL_KBUILD_BUILD_TIMESTAMP \
  SP11_KERNEL_BUILD_TARGET \
  SP11_KERNEL_PATCH_DIRS; do
  printf '%s\t%s\n' "$variable" "${!variable}"
done
if [ -n "$aba_control_root" ]; then
  rm -f "$1"
  rmdir "$aba_control_root"
  mv "$MOCK_BASELINE_ABA_BACKUP/control-root" "$aba_control_root"
  : > "$MOCK_BASELINE_ABA_BACKUP/completed"
fi
EOF_BASELINE_VALIDATOR
cat > "$support_dir/scripts/validate-sp11-oci-index.py" <<'EOF_OCI_VALIDATOR'
#!/usr/bin/env python3
raise SystemExit(0)
EOF_OCI_VALIDATOR
chmod +x \
  "$support_dir/scripts/validate-sp11-kernel-baseline.sh" \
  "$support_dir/scripts/validate-sp11-oci-index.py"

git -C "$support_dir" init --quiet --initial-branch=fixture
git -C "$support_dir" config user.name "SP11 path-safety fixture"
git -C "$support_dir" config user.email "sp11-path-safety@example.invalid"
git -C "$support_dir" add .
git -C "$support_dir" commit --quiet -m "Create Docker wrapper safety fixture"

wrapper="$support_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh"
no_apt_helper_wrapper="$support_dir/scripts/build-sp11-qcom-x1e-kernel-docker-no-apt-helper.sh"

run_dry() {
  local work_dir="$1"
  shift
  "$wrapper" \
    --source apt \
    --source-package linux-fixture \
    --source-version 1.0 \
    --work-dir "$work_dir" \
    --dry-run \
    "$@"
}

# The control files are staged inside an unpredictable private directory, then
# atomically installed as regular evidence files at the documented work root.
# A mock Docker client verifies the installed files before allowing completion.
cat > "$mock_bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] &&
   [ "${3:-}" = "inspect" ] && [ "${4:-}" = "--raw" ]; then
  test -f "$MOCK_OCI_INDEX"
  /bin/cat "$MOCK_OCI_INDEX"
  exit 0
fi

host_work=""
host_control=""
host_repo=""
previous=""
last_argument=""
penultimate_argument=""
for argument in "$@"; do
  penultimate_argument="$last_argument"
  last_argument="$argument"
  if [ "$previous" = "-v" ]; then
    case "$argument" in
      *:/work) host_work="${argument%:/work}" ;;
      *:/sp11-control:ro) host_control="${argument%:/sp11-control:ro}" ;;
      *:/repo:ro) host_repo="${argument%:/repo:ro}" ;;
    esac
    previous=""
    continue
  fi
  previous="$argument"
done

[ -n "$host_work" ]
[ -f "$host_work/docker-build-args.txt" ] && [ ! -L "$host_work/docker-build-args.txt" ]
[ -f "$host_work/docker-build-inside.sh" ] && [ ! -L "$host_work/docker-build-inside.sh" ]
case "$(uname -s)" in
  Darwin)
    args_mode="$(stat -f '%Lp' "$host_work/docker-build-args.txt")"
    script_mode="$(stat -f '%Lp' "$host_work/docker-build-inside.sh")"
    ;;
  *)
    args_mode="$(stat -c '%a' "$host_work/docker-build-args.txt")"
    script_mode="$(stat -c '%a' "$host_work/docker-build-inside.sh")"
    ;;
esac
[ "$args_mode" = "600" ]
if [ -n "$host_control" ]; then
  [ "$script_mode" = "600" ]
else
  [ "$script_mode" = "700" ] && [ -x "$host_work/docker-build-inside.sh" ]
fi
grep -Fxq -- '--source' "$host_work/docker-build-args.txt"
if [ -n "$host_control" ]; then
  [ "$last_argument" = "/sp11-control/docker-build-inside.sh" ]
  [ "$penultimate_argument" = "bash" ]
  [ -f "$host_control/kernel-baseline.env" ] &&
    [ ! -L "$host_control/kernel-baseline.env" ]
  [ -f "$host_control/docker-build-args.txt" ] &&
    [ ! -L "$host_control/docker-build-args.txt" ]
  [ -f "$host_control/docker-build-inside.sh" ] &&
    [ ! -L "$host_control/docker-build-inside.sh" ]
  cmp "$host_control/docker-build-args.txt" "$host_work/docker-build-args.txt"
  cmp "$host_control/docker-build-inside.sh" "$host_work/docker-build-inside.sh"
  if [ -f "$host_control/sp11-oci-index.json" ]; then
    cmp "$host_control/sp11-oci-index.json" "$host_work/sp11-oci-index.json"
  fi
  grep -Fq 'done < "$control_dir/docker-build-args.txt"' \
    "$host_control/docker-build-inside.sh"
  printf 'private read-only controls verified\n' \
    > "$host_work/mock-private-control-verified"
fi
case "${MOCK_ABA_SWAP:-}" in
  work-args)
    [ -n "$host_control" ] && [ -n "${MOCK_ABA_BACKUP_ROOT:-}" ]
    mv "$host_work/docker-build-args.txt" "$MOCK_ABA_BACKUP_ROOT/work-args"
    printf '%s\n' '--source' 'hostile-work-evidence' \
      > "$host_work/docker-build-args.txt"
    grep -Fxq -- '--release-build' "$host_control/docker-build-args.txt"
    rm -f "$host_work/docker-build-args.txt"
    mv "$MOCK_ABA_BACKUP_ROOT/work-args" "$host_work/docker-build-args.txt"
    : > "$host_work/mock-work-aba-completed"
    ;;
  private-args)
    [ -n "$host_control" ] && [ -n "${MOCK_ABA_BACKUP_ROOT:-}" ]
    mv "$host_control/docker-build-args.txt" "$MOCK_ABA_BACKUP_ROOT/private-args"
    printf '%s\n' '--source' 'hostile-private-authority' \
      > "$host_control/docker-build-args.txt"
    grep -Fxq -- 'hostile-private-authority' "$host_control/docker-build-args.txt"
    rm -f "$host_control/docker-build-args.txt"
    mv "$MOCK_ABA_BACKUP_ROOT/private-args" "$host_control/docker-build-args.txt"
    : > "$host_work/mock-private-aba-completed"
    ;;
  private-root)
    [ -n "$host_control" ] && [ -n "${MOCK_ABA_BACKUP_ROOT:-}" ]
    mv "$host_control" "$MOCK_ABA_BACKUP_ROOT/private-root"
    mkdir "$host_control"
    printf '%s\n' '--source' 'hostile-private-root' \
      > "$host_control/docker-build-args.txt"
    grep -Fxq -- 'hostile-private-root' "$host_control/docker-build-args.txt"
    rm -f "$host_control/docker-build-args.txt"
    rmdir "$host_control"
    mv "$MOCK_ABA_BACKUP_ROOT/private-root" "$host_control"
    : > "$host_work/mock-private-root-aba-completed"
    ;;
  support-root)
    [ -n "$host_repo" ] && [ -n "${MOCK_ABA_BACKUP_ROOT:-}" ]
    support_root="$(dirname "$host_repo")"
    mv "$support_root" "$MOCK_ABA_BACKUP_ROOT/support-root"
    mkdir "$support_root"
    mkdir "$support_root/support"
    printf 'hostile support replacement\n' > "$support_root/support/README"
    rm -f "$support_root/support/README"
    rmdir "$support_root/support"
    rmdir "$support_root"
    mv "$MOCK_ABA_BACKUP_ROOT/support-root" "$support_root"
    : > "$host_work/mock-support-root-aba-completed"
    ;;
esac
mkdir -p "$host_work/artifacts"
if [ "${MOCK_CREATE_DEB:-false}" = "true" ]; then
  printf 'fixture kernel package\n' \
    > "$host_work/artifacts/linux-image-7.2.0-fixture-qcom-x1e_1_arm64.deb"
fi
printf 'installed control files verified\n' > "$host_work/mock-docker-verified"
case "${MOCK_MUTATE_CONTROL:-}" in
  docker-build-args.txt|docker-build-inside.sh|sp11-oci-index.json)
    printf 'mutated by fake Docker\n' >> "$host_work/$MOCK_MUTATE_CONTROL"
    ;;
esac
EOF_DOCKER
chmod +x "$mock_bin/docker"

# Hostile tool shims deterministically inject a path between exclusive control
# creation and first capture, or plant a symlink immediately before exclusive
# creation.  Every other invocation delegates byte-for-byte to the real tool.
cat > "$capture_attack_bin/mktemp" <<'EOF_CAPTURE_MKTEMP'
#!/usr/bin/env bash
set -euo pipefail
created="$($FIXTURE_REAL_MKTEMP "$@")"
case "$created" in
  /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*)
    printf '%s\n' "$created" > "$CAPTURE_ATTACK_STATE/control-root-path"
    ;;
  /tmp/sp11-kernel-support.*|/private/tmp/sp11-kernel-support.*)
    printf '%s\n' "$created" > "$CAPTURE_ATTACK_STATE/support-root-path"
    ;;
esac
printf '%s\n' "$created"
EOF_CAPTURE_MKTEMP
cat > "$capture_attack_bin/stat" <<'EOF_CAPTURE_STAT'
#!/usr/bin/env bash
set -euo pipefail
last=""
for argument in "$@"; do
  last="$argument"
done
if [ "${CAPTURE_ATTACK_MODE:-}" = "replace-args" ] &&
   [ "${last##*/}" = "docker-build-args.txt" ] &&
   [ ! -e "$CAPTURE_ATTACK_MARKER" ]; then
  printf '%s\n' '--source' 'hostile-first-capture-replacement' > "$last"
  : > "$CAPTURE_ATTACK_MARKER"
fi
exec "$FIXTURE_REAL_STAT" "$@"
EOF_CAPTURE_STAT
cat > "$capture_attack_bin/shasum" <<'EOF_CAPTURE_SHASUM'
#!/usr/bin/env bash
set -euo pipefail
last=""
for argument in "$@"; do
  last="$argument"
done
if [ "${CAPTURE_ATTACK_MODE:-}" = "work-root-symlink" ] &&
   [ ! -e "$CAPTURE_ATTACK_MARKER" ]; then
  case "$last" in
    /tmp/sp11-kernel-baseline.*/docker-build-args.txt|\
    /private/tmp/sp11-kernel-baseline.*/docker-build-args.txt)
      [ -d "$CAPTURE_ATTACK_WORK_ROOT" ] && [ ! -L "$CAPTURE_ATTACK_WORK_ROOT" ]
      mv "$CAPTURE_ATTACK_WORK_ROOT" "$CAPTURE_ATTACK_STATE/original-work-root"
      ln -s "$CAPTURE_ATTACK_VICTIM" "$CAPTURE_ATTACK_WORK_ROOT"
      printf '%s\n' "$CAPTURE_ATTACK_WORK_ROOT" > "$CAPTURE_ATTACK_STATE/root-path"
      : > "$CAPTURE_ATTACK_MARKER"
      ;;
  esac
fi
if [ "$last" = "256" ]; then
  count=0
  if [ -f "$CAPTURE_ATTACK_STATE/count" ]; then
    count="$(/bin/cat "$CAPTURE_ATTACK_STATE/count")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$CAPTURE_ATTACK_STATE/count"
  if [ "${CAPTURE_ATTACK_MODE:-}" = "symlink-entrypoint" ] &&
     [ "$count" -eq 2 ] && [ ! -e "$CAPTURE_ATTACK_MARKER" ]; then
    control_root="$(/bin/cat "$CAPTURE_ATTACK_STATE/control-root-path")"
    [ -d "$control_root" ] && [ ! -L "$control_root" ]
    ln -s "$CAPTURE_ATTACK_VICTIM" "$control_root/docker-build-inside.sh"
    : > "$CAPTURE_ATTACK_MARKER"
  elif [ "${CAPTURE_ATTACK_MODE:-}" = "control-root-symlink" ] &&
       [ "$count" -eq 1 ] && [ ! -e "$CAPTURE_ATTACK_MARKER" ]; then
    control_root="$(/bin/cat "$CAPTURE_ATTACK_STATE/control-root-path")"
    [ -d "$control_root" ] && [ ! -L "$control_root" ]
    mv "$control_root" "$CAPTURE_ATTACK_STATE/original-control-root"
    ln -s "$CAPTURE_ATTACK_VICTIM" "$control_root"
    printf '%s\n' "$control_root" > "$CAPTURE_ATTACK_STATE/root-path"
    : > "$CAPTURE_ATTACK_MARKER"
  fi
fi
exec "$FIXTURE_REAL_SHASUM" "$@"
EOF_CAPTURE_SHASUM
cat > "$capture_attack_bin/git" <<'EOF_CAPTURE_GIT'
#!/usr/bin/env bash
set -euo pipefail
operation=""
for argument in "$@"; do
  case "$argument" in
    clone|cat-file) operation="$argument" ;;
  esac
done
if [ ! -e "$CAPTURE_ATTACK_MARKER" ]; then
  case "${CAPTURE_ATTACK_MODE:-}:$operation" in
    support-root-symlink:clone)
      attack_root="$(pwd -P)"
      case "$attack_root" in
        /tmp/sp11-kernel-support.*|/private/tmp/sp11-kernel-support.*) ;;
        *) exit 91 ;;
      esac
      mv "$attack_root" "$CAPTURE_ATTACK_STATE/original-support-root"
      ln -s "$CAPTURE_ATTACK_VICTIM" "$attack_root"
      printf '%s\n' "$attack_root" > "$CAPTURE_ATTACK_STATE/root-path"
      : > "$CAPTURE_ATTACK_MARKER"
      ;;
    support-child-symlink:clone)
      attack_root="$(pwd -P)"
      case "$attack_root" in
        /tmp/sp11-kernel-support.*/support|\
        /private/tmp/sp11-kernel-support.*/support) ;;
        *) exit 93 ;;
      esac
      mv "$attack_root" "$CAPTURE_ATTACK_STATE/original-support-child"
      ln -s "$CAPTURE_ATTACK_VICTIM" "$attack_root"
      printf '%s\n' "$attack_root" > "$CAPTURE_ATTACK_STATE/root-path"
      : > "$CAPTURE_ATTACK_MARKER"
      ;;
    baseline-root-symlink:cat-file)
      attack_root="$(pwd -P)"
      case "$attack_root" in
        /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
        *) exit 92 ;;
      esac
      mv "$attack_root" "$CAPTURE_ATTACK_STATE/original-control-root"
      ln -s "$CAPTURE_ATTACK_VICTIM" "$attack_root"
      printf '%s\n' "$attack_root" > "$CAPTURE_ATTACK_STATE/root-path"
      : > "$CAPTURE_ATTACK_MARKER"
      ;;
  esac
fi
exec "$FIXTURE_REAL_GIT" "$@"
EOF_CAPTURE_GIT
chmod +x \
  "$capture_attack_bin/git" \
  "$capture_attack_bin/mktemp" \
  "$capture_attack_bin/stat" \
  "$capture_attack_bin/shasum"

# Immutable validation needs an LZ4 list decoder on hosts without apt-helper.
# An isolated PATH and a wrapper fixture with an unavailable system helper make
# both fallback branches deterministic, including on Ubuntu hosts.
decoder_bin="$temporary_root/decoder-bin"
decoder_docker_marker="$temporary_root/decoder-docker-invoked"
mkdir "$decoder_bin"
for tool in \
  awk bash basename chmod dirname find git grep mkdir mktemp python3 rm rmdir shasum \
  sort stat touch tr uname wc; do
  tool_path="$(type -P "$tool")"
  [ -n "$tool_path" ] || die "missing decoder-preflight fixture tool: $tool"
  ln -s "$tool_path" "$decoder_bin/$tool"
done
cat > "$decoder_bin/docker" <<'EOF_DECODER_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
: > "$DECODER_DOCKER_MARKER"
exit 89
EOF_DECODER_DOCKER
chmod +x "$decoder_bin/docker"

decoder_args=(
  --source git
  --git-url https://github.com/example/linux.git
  --git-branch fixture/ref
  --expected-source-commit "$release_source_commit"
  --image "$release_image"
  --platform linux/arm64/v8
  --patch-dirs patches/release
  --build-target "binary-indep binary-qcom-x1e"
  --release-build
)

missing_decoder_work="$support_dir/build/missing-list-decoder/work"
if DECODER_DOCKER_MARKER="$decoder_docker_marker" PATH="$decoder_bin" \
    "$no_apt_helper_wrapper" \
      --work-dir "$missing_decoder_work" \
      "${decoder_args[@]}" \
      > "$temporary_root/missing-list-decoder.log" 2>&1; then
  die "immutable wrapper accepted a missing APT list decoder"
fi
grep -Fxq 'Missing required tool: lz4' "$temporary_root/missing-list-decoder.log" ||
  { cat "$temporary_root/missing-list-decoder.log" >&2;
    die "missing APT list decoder rejection was not explicit"; }
[ ! -e "$decoder_docker_marker" ] ||
  die "missing APT list decoder reached Docker"

cat > "$decoder_bin/lz4" <<'EOF_LZ4'
#!/usr/bin/env bash
exit 0
EOF_LZ4
chmod +x "$decoder_bin/lz4"
available_decoder_work="$support_dir/build/available-list-decoder/work"
if DECODER_DOCKER_MARKER="$decoder_docker_marker" PATH="$decoder_bin" \
    "$no_apt_helper_wrapper" \
      --work-dir "$available_decoder_work" \
      "${decoder_args[@]}" \
      > "$temporary_root/available-list-decoder.log" 2>&1; then
  die "decoder fixture unexpectedly completed its sentinel Docker call"
fi
[ -f "$decoder_docker_marker" ] ||
  die "available lz4 did not pass the immutable decoder preflight"
grep -Fq 'Could not capture the raw pinned OCI index.' \
  "$temporary_root/available-list-decoder.log" ||
  { cat "$temporary_root/available-list-decoder.log" >&2;
    die "available lz4 did not reach the sentinel Docker failure"; }

# Keep normal release fixtures portable on hosts without apt-helper.
cp "$decoder_bin/lz4" "$mock_bin/lz4"

# Release dry-runs validate the same baseline and retain the exact contiguous
# deterministic identity block that a live invocation will bind as Input 1.
release_dry_work="$support_dir/build/release-identity-dry/work"
hostile_template="$temporary_root/hostile-git-template"
hostile_template_marker="$temporary_root/hostile-git-template-ran"
mkdir -p "$hostile_template/hooks"
cat > "$hostile_template/hooks/post-checkout" <<EOF_HOSTILE_TEMPLATE
#!/usr/bin/env bash
: > "$hostile_template_marker"
EOF_HOSTILE_TEMPLATE
chmod +x "$hostile_template/hooks/post-checkout"
GIT_TEMPLATE_DIR="$hostile_template" PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
  --work-dir "$release_dry_work" \
  "${decoder_args[@]}" \
  --dry-run > "$temporary_root/release-identity-dry.log"
[ ! -e "$hostile_template_marker" ] ||
  die "release support snapshot honored an ambient hostile Git template"
identity_block="$(
  awk '$0 == "--release-build" { remaining = 9 }
       remaining > 0 { print; remaining-- }' \
    "$release_dry_work/docker-build-args.txt"
)"
expected_identity_block="$(cat <<'EOF_IDENTITY_BLOCK'
--release-build
--source-date-epoch
1785567085
--kbuild-build-user
sp11-builder
--kbuild-build-host
sp11-build
--kbuild-build-timestamp
Sat Aug  1 06:51:25 UTC 2026
EOF_IDENTITY_BLOCK
)"
[ "$identity_block" = "$expected_identity_block" ] ||
  die "release dry-run did not retain the exact ordered deterministic identity block"
grep -Fq 'SP11_IMMUTABLE_APT_REQUIRED=true' "$temporary_root/release-identity-dry.log" ||
  die "release dry-run did not print the immutable APT container environment"
grep -Fq ':/sp11-control:ro' \
  "$temporary_root/release-identity-dry.log" ||
  die "release dry-run did not mount its private control directory read-only"
grep -Fq '/sp11-control/docker-build-inside.sh' \
  "$temporary_root/release-identity-dry.log" ||
  die "release dry-run did not execute its private read-only entrypoint"
[ "$(grep -Fc -- '--baseline /sp11-control/kernel-baseline.env' \
    "$release_dry_work/docker-build-inside.sh")" -eq 2 ] ||
  die "immutable APT bootstrap/finalize did not share the mounted baseline snapshot"
if grep -Fq -- '--baseline /repo/config/kernel-baselines/' \
    "$release_dry_work/docker-build-inside.sh"; then
  die "release entrypoint retained a live-worktree baseline authority"
fi

baseline_aba_backup="$temporary_root/baseline-root-aba-backup"
baseline_aba_work="$support_dir/build/baseline-root-aba/work"
mkdir -p "$baseline_aba_backup"
if MOCK_BASELINE_ROOT_ABA=true \
    MOCK_BASELINE_ABA_BACKUP="$baseline_aba_backup" \
    PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$baseline_aba_work" \
      "${decoder_args[@]}" \
      --dry-run > "$temporary_root/baseline-root-aba.log" 2>&1; then
  die "release preflight accepted a baseline control-root A->B->A replacement"
fi
[ -f "$baseline_aba_backup/completed" ] ||
  die "baseline validator did not complete its control-root A->B->A fixture"
grep -Fq 'Private committed-baseline control directory changed before finalization' \
  "$temporary_root/baseline-root-aba.log" ||
  die "baseline control-root A->B->A rejection was not explicit"
[ ! -e "$baseline_aba_work/docker-build-args.txt" ] ||
  die "baseline control-root A->B->A emitted retained build arguments"
preserved_baseline_control="$(
  grep -Eo '(/private)?/tmp/sp11-kernel-baseline\.[A-Za-z0-9]+' \
    "$temporary_root/baseline-root-aba.log" | tail -1
)"
case "$preserved_baseline_control" in
  /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
  *) die "could not identify preserved baseline-root hostile fixture" ;;
esac
[ -d "$preserved_baseline_control" ] && [ ! -L "$preserved_baseline_control" ] ||
  die "preserved baseline-root hostile fixture is no longer a real directory"
mv "$preserved_baseline_control" "$baseline_aba_backup/preserved-private"

for capture_attack_mode in replace-args symlink-entrypoint; do
  capture_attack_root="$temporary_root/capture-$capture_attack_mode"
  capture_attack_work="$support_dir/build/capture-$capture_attack_mode/work"
  capture_attack_marker="$capture_attack_root/attack-completed"
  capture_attack_start="$capture_attack_root/attack-start"
  capture_attack_victim="$capture_attack_root/victim"
  mkdir -p "$capture_attack_root/state"
  printf 'exclusive-create victim must remain unchanged\n' > "$capture_attack_victim"
  touch "$capture_attack_start"
  if FIXTURE_REAL_GIT="$real_git" \
      FIXTURE_REAL_MKTEMP="$real_mktemp" \
      FIXTURE_REAL_SHASUM="$real_shasum" \
      FIXTURE_REAL_STAT="$real_stat" \
      CAPTURE_ATTACK_MODE="$capture_attack_mode" \
      CAPTURE_ATTACK_MARKER="$capture_attack_marker" \
      CAPTURE_ATTACK_START="$capture_attack_start" \
      CAPTURE_ATTACK_STATE="$capture_attack_root/state" \
      CAPTURE_ATTACK_VICTIM="$capture_attack_victim" \
      PATH="$capture_attack_bin:$mock_bin:/usr/bin:/bin" "$wrapper" \
        --work-dir "$capture_attack_work" \
        "${decoder_args[@]}" \
        --dry-run > "$capture_attack_root/wrapper.log" 2>&1; then
    die "release preflight accepted hostile first capture: $capture_attack_mode"
  fi
  [ -f "$capture_attack_marker" ] ||
    die "hostile first-capture fixture did not run: $capture_attack_mode"
  grep -Fxq 'exclusive-create victim must remain unchanged' "$capture_attack_victim" ||
    die "exclusive control creation followed a planted symlink victim"
  case "$capture_attack_mode" in
    replace-args)
      grep -Fq 'differ from their in-memory authority' \
        "$capture_attack_root/wrapper.log" ||
        die "first-capture args replacement rejection was not explicit"
      ;;
    symlink-entrypoint)
      grep -Fq 'Could not exclusively create the private release entrypoint' \
        "$capture_attack_root/wrapper.log" ||
        { cat "$capture_attack_root/wrapper.log" >&2;
          die "private entrypoint symlink rejection was not explicit"; }
      ;;
  esac
  [ ! -e "$capture_attack_work/docker-build-args.txt" ] ||
    die "hostile first capture emitted retained build arguments"
  preserved_capture_control="$(
    grep -Eo '(/private)?/tmp/sp11-kernel-baseline\.[A-Za-z0-9]+' \
      "$capture_attack_root/wrapper.log" | tail -1
  )"
  case "$preserved_capture_control" in
    /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
    *) die "could not identify preserved first-capture fixture: $capture_attack_mode" ;;
  esac
  [ -d "$preserved_capture_control" ] && [ ! -L "$preserved_capture_control" ] ||
    die "preserved first-capture fixture is no longer a real directory"
  mv "$preserved_capture_control" "$capture_attack_root/preserved-private"
done

# A freshly created private root must be pinned before any external operation,
# and every pre-seal write must stay relative to that pinned directory object.
# Replacing its absolute pathname with a symlink must therefore fail without
# creating, removing, or changing anything in the symlink target.
for root_attack_mode in \
  support-root-symlink \
  support-child-symlink \
  baseline-root-symlink \
  control-root-symlink; do
  root_attack_fixture="$temporary_root/capture-$root_attack_mode"
  root_attack_work="$support_dir/build/capture-$root_attack_mode/work"
  root_attack_marker="$root_attack_fixture/attack-completed"
  root_attack_start="$root_attack_fixture/attack-start"
  root_attack_victim="$root_attack_fixture/victim"
  mkdir -p "$root_attack_fixture/state" "$root_attack_victim"
  if [ "$root_attack_mode" != "support-child-symlink" ]; then
    printf 'private-root victim sentinel\n' > "$root_attack_victim/sentinel"
  fi
  root_attack_victim_state="$(node_full_metadata "$root_attack_victim")"
  root_attack_sentinel_state=""
  if [ -f "$root_attack_victim/sentinel" ]; then
    root_attack_sentinel_state="$(regular_fingerprint "$root_attack_victim/sentinel")"
  fi
  touch "$root_attack_start"
  if FIXTURE_REAL_GIT="$real_git" \
      FIXTURE_REAL_MKTEMP="$real_mktemp" \
      FIXTURE_REAL_SHASUM="$real_shasum" \
      FIXTURE_REAL_STAT="$real_stat" \
      CAPTURE_ATTACK_MODE="$root_attack_mode" \
      CAPTURE_ATTACK_MARKER="$root_attack_marker" \
      CAPTURE_ATTACK_START="$root_attack_start" \
      CAPTURE_ATTACK_STATE="$root_attack_fixture/state" \
      CAPTURE_ATTACK_VICTIM="$root_attack_victim" \
      PATH="$capture_attack_bin:$mock_bin:/usr/bin:/bin" "$wrapper" \
        --work-dir "$root_attack_work" \
        "${decoder_args[@]}" \
        --dry-run > "$root_attack_fixture/wrapper.log" 2>&1; then
    die "release preflight accepted a private-root victim substitution: $root_attack_mode"
  fi
  [ -f "$root_attack_marker" ] ||
    die "private-root victim substitution fixture did not run: $root_attack_mode"
  [ "$(node_full_metadata "$root_attack_victim")" = "$root_attack_victim_state" ] ||
    die "private-root creation changed the symlink victim: $root_attack_mode"
  if [ "$root_attack_mode" = "support-child-symlink" ]; then
    [ -z "$(find "$root_attack_victim" -mindepth 1 -maxdepth 1 -print)" ] ||
      die "private checkout creation polluted the empty symlink victim"
  else
    [ "$(regular_fingerprint "$root_attack_victim/sentinel")" = \
      "$root_attack_sentinel_state" ] ||
      die "private-root creation changed the victim sentinel: $root_attack_mode"
    [ "$(find "$root_attack_victim" -mindepth 1 -maxdepth 1 -print)" = \
      "$root_attack_victim/sentinel" ] ||
      die "private-root creation polluted the symlink victim: $root_attack_mode"
  fi
  attacked_root="$(cat "$root_attack_fixture/state/root-path")"
  case "$root_attack_mode:$attacked_root" in
    support-root-symlink:/tmp/sp11-kernel-support.*|\
    support-root-symlink:/private/tmp/sp11-kernel-support.*) ;;
    support-child-symlink:/tmp/sp11-kernel-support.*/support|\
    support-child-symlink:/private/tmp/sp11-kernel-support.*/support) ;;
    baseline-root-symlink:/tmp/sp11-kernel-baseline.*|\
    baseline-root-symlink:/private/tmp/sp11-kernel-baseline.*|\
    control-root-symlink:/tmp/sp11-kernel-baseline.*|\
    control-root-symlink:/private/tmp/sp11-kernel-baseline.*) ;;
    *) die "private-root fixture recorded an unexpected attacked path: $root_attack_mode" ;;
  esac
  [ -L "$attacked_root" ] &&
    [ "$(readlink "$attacked_root")" = "$root_attack_victim" ] ||
    die "wrapper followed or removed the private-root victim symlink: $root_attack_mode"
  rm -f -- "$attacked_root"
  case "$root_attack_mode" in
    support-root-symlink)
      [ -d "$root_attack_fixture/state/original-support-root" ] &&
        [ ! -L "$root_attack_fixture/state/original-support-root" ] ||
        die "support-root fixture lost its pinned original directory"
      ;;
    support-child-symlink)
      [ -d "$root_attack_fixture/state/original-support-child" ] &&
        [ ! -L "$root_attack_fixture/state/original-support-child" ] ||
        die "support-child fixture lost its pinned original directory"
      attacked_parent="${attacked_root%/support}"
      [ -d "$attacked_parent" ] && [ ! -L "$attacked_parent" ] ||
        die "support-child fixture lost its private parent root"
      mv "$attacked_parent" "$root_attack_fixture/state/preserved-support-root"
      ;;
    *)
      [ -d "$root_attack_fixture/state/original-control-root" ] &&
        [ ! -L "$root_attack_fixture/state/original-control-root" ] ||
        die "control-root fixture lost its pinned original directory: $root_attack_mode"
      ;;
  esac
done

# Retained release evidence must be written relative to the already-pinned
# work-directory object.  Replacing the public work path while a private
# control file is hashed must not redirect an evidence copy into the victim.
work_root_attack_fixture="$temporary_root/capture-work-root-symlink"
work_root_attack_work="$support_dir/build/capture-work-root-symlink/work"
work_root_attack_victim="$work_root_attack_fixture/victim"
work_root_attack_marker="$work_root_attack_fixture/attack-completed"
mkdir -p "$work_root_attack_fixture/state" "$work_root_attack_victim"
work_root_attack_victim_state="$(node_full_metadata "$work_root_attack_victim")"
if FIXTURE_REAL_GIT="$real_git" \
    FIXTURE_REAL_MKTEMP="$real_mktemp" \
    FIXTURE_REAL_SHASUM="$real_shasum" \
    FIXTURE_REAL_STAT="$real_stat" \
    CAPTURE_ATTACK_MODE="work-root-symlink" \
    CAPTURE_ATTACK_MARKER="$work_root_attack_marker" \
    CAPTURE_ATTACK_STATE="$work_root_attack_fixture/state" \
    CAPTURE_ATTACK_VICTIM="$work_root_attack_victim" \
    CAPTURE_ATTACK_WORK_ROOT="$work_root_attack_work" \
    PATH="$capture_attack_bin:$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$work_root_attack_work" \
      "${decoder_args[@]}" \
      --dry-run > "$work_root_attack_fixture/wrapper.log" 2>&1; then
  die "release preflight accepted a work-root victim substitution"
fi
[ -f "$work_root_attack_marker" ] ||
  die "work-root victim substitution fixture did not run"
[ "$(node_full_metadata "$work_root_attack_victim")" = \
  "$work_root_attack_victim_state" ] ||
  die "release evidence creation changed the work-root victim"
[ -z "$(find "$work_root_attack_victim" -mindepth 1 -maxdepth 1 -print)" ] ||
  die "release evidence creation polluted the work-root victim"
[ -L "$work_root_attack_work" ] &&
  [ "$(readlink "$work_root_attack_work")" = "$work_root_attack_victim" ] ||
  die "work-root fixture lost its victim symlink"
grep -Fq 'Release work root changed from its pinned directory' \
  "$work_root_attack_fixture/wrapper.log" ||
  die "work-root substitution rejection was not explicit"
rm -f -- "$work_root_attack_work"
[ -d "$work_root_attack_fixture/state/original-work-root" ] &&
  [ ! -L "$work_root_attack_fixture/state/original-work-root" ] ||
  die "work-root fixture lost its pinned original directory"

if PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
    --work-dir "$support_dir/build/release-identity-tampered-input/work" \
    "${decoder_args[@]}" \
    --expected-source-commit "3333333333333333333333333333333333333333" \
    --dry-run > "$temporary_root/release-identity-tampered-input.log" 2>&1; then
  die "release dry-run accepted a source commit outside the baseline"
fi
grep -Fq 'source commit does not match the immutable kernel baseline' \
  "$temporary_root/release-identity-tampered-input.log" ||
  die "release dry-run source mismatch rejection was not explicit"

tampered_support="$temporary_root/tampered-baseline-support"
git clone --quiet "$support_dir" "$tampered_support"
sed 's/SP11_KERNEL_KBUILD_BUILD_USER="sp11-builder"/SP11_KERNEL_KBUILD_BUILD_USER="alternate-builder"/' \
  "$tampered_support/config/kernel-baselines/7.2-rc5-jg-0.env" \
  > "$tampered_support/config/kernel-baselines/.baseline-tampered"
mv "$tampered_support/config/kernel-baselines/.baseline-tampered" \
  "$tampered_support/config/kernel-baselines/7.2-rc5-jg-0.env"
git -C "$tampered_support" add config/kernel-baselines/7.2-rc5-jg-0.env
git -C "$tampered_support" -c user.name='SP11 fixture' \
  -c user.email='sp11-fixture@example.invalid' commit --quiet -m 'Tamper identity baseline'
if PATH="$mock_bin:/usr/bin:/bin" \
    "$tampered_support/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --work-dir "$tampered_support/build/release-identity-tampered-baseline/work" \
    "${decoder_args[@]}" \
    --dry-run > "$temporary_root/release-identity-tampered-baseline.log" 2>&1; then
  die "release dry-run accepted a tampered deterministic identity baseline"
fi
[ ! -e "$tampered_support/build/release-identity-tampered-baseline/work/docker-build-args.txt" ] ||
  die "tampered release baseline emitted retained build arguments"

private_work="$support_dir/build/private-control-work"
PATH="$mock_bin:/usr/bin:/bin" run_dry "$private_work" > "$temporary_root/private-dry.log"
grep -Fq '/work/docker-build-inside.sh' "$temporary_root/private-dry.log" ||
  die "dry-run command did not use the installed control entrypoint"
[ -f "$private_work/docker-build-args.txt" ] &&
  [ ! -L "$private_work/docker-build-args.txt" ] ||
  die "dry run did not retain regular build-argument evidence"
[ -x "$private_work/docker-build-inside.sh" ] &&
  [ ! -L "$private_work/docker-build-inside.sh" ] ||
  die "dry run did not retain a regular inner-build script"
if find "$private_work" -maxdepth 1 -name '.sp11-docker-control.*' | grep -q .; then
  die "dry run retained its private control directory"
fi

# Reaching the checkout through a symlink must still canonicalize the repository
# root before enforcing the repository-local build/ boundary.
linked_support="$temporary_root/support-link"
ln -s "$support_dir" "$linked_support"
linked_work="$support_dir/build/symlinked-checkout-work"
PATH="$mock_bin:/usr/bin:/bin" \
  "$linked_support/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --source apt \
    --source-package linux-fixture \
    --source-version 1.0 \
    --work-dir build/symlinked-checkout-work \
    --dry-run > "$temporary_root/symlinked-checkout.log"
[ -f "$linked_work/docker-build-args.txt" ] ||
  die "symlinked checkout invocation did not use the physical repository build root"

live_work="$support_dir/build/private-control-live-work"
PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
  --source apt \
  --source-package linux-fixture \
  --source-version 1.0 \
  --work-dir "$live_work" > "$temporary_root/private-live.log"
[ -f "$live_work/mock-docker-verified" ] ||
  die "mock Docker client did not verify private controls"
if find "$live_work" -maxdepth 1 -name '.sp11-docker-control.*' | grep -q .; then
  die "completed wrapper retained its private control directory"
fi

for mutated_control in docker-build-args.txt docker-build-inside.sh; do
  mutation_work="$support_dir/build/mutated-$mutated_control/work"
  if MOCK_MUTATE_CONTROL="$mutated_control" PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
      --source apt \
      --source-package linux-fixture \
      --source-version 1.0 \
      --work-dir "$mutation_work" \
      > "$temporary_root/mutated-$mutated_control.log" 2>&1; then
    die "wrapper accepted a fake-Docker mutation of $mutated_control"
  fi
  grep -Fq 'Docker control input changed after its pre-run validation' \
    "$temporary_root/mutated-$mutated_control.log" ||
    die "fake-Docker control mutation rejection was not explicit: $mutated_control"
done

immutable_oci_work="$support_dir/build/mutated-immutable-oci/work"
if MOCK_OCI_INDEX="$release_oci_index" \
    MOCK_MUTATE_CONTROL=sp11-oci-index.json \
    PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
      --source git \
      --git-url https://github.com/example/linux.git \
      --git-branch fixture/ref \
      --expected-source-commit "$release_source_commit" \
      --image "$release_image" \
      --platform linux/arm64/v8 \
      --patch-dirs patches/release \
      --build-target "binary-indep binary-qcom-x1e" \
      --work-dir "$immutable_oci_work" \
      --release-build \
      > "$temporary_root/mutated-immutable-oci.log" 2>&1; then
  die "wrapper accepted a fake-Docker mutation of the immutable OCI index"
fi
grep -Fq 'Docker control input changed after its pre-run validation' \
  "$temporary_root/mutated-immutable-oci.log" ||
  die "fake-Docker immutable OCI mutation rejection was not explicit"
grep -Fq 'sp11-oci-index.json' "$temporary_root/mutated-immutable-oci.log" ||
  die "fake-Docker immutable OCI mutation rejection did not identify the control"

# A coordinated A->B->A replacement must not make the writable evidence paths
# authoritative, and the private control directory's own rename history must be
# detected even when the original private file is restored byte-for-byte.
for aba_scope in work-args private-args private-root support-root; do
  aba_work="$support_dir/build/aba-$aba_scope/work"
  aba_backup="$temporary_root/aba-$aba_scope-backup"
  mkdir -p "$aba_backup"
  if MOCK_OCI_INDEX="$release_oci_index" \
      MOCK_ABA_SWAP="$aba_scope" \
      MOCK_ABA_BACKUP_ROOT="$aba_backup" \
      PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
        --work-dir "$aba_work" \
        "${decoder_args[@]}" \
        > "$temporary_root/aba-$aba_scope.log" 2>&1; then
    die "release wrapper accepted an A->B->A $aba_scope control replacement"
  fi
  [ -f "$aba_work/mock-private-control-verified" ] ||
    die "mock Docker did not prove private control authority for $aba_scope"
  [ -f "$aba_work/mock-${aba_scope%-args}-aba-completed" ] ||
    die "mock Docker did not complete the hostile A->B->A replacement: $aba_scope"
  case "$aba_scope" in
    work-args)
      grep -Fq 'Docker control input changed after its pre-run validation' \
        "$temporary_root/aba-$aba_scope.log" ||
        die "work-evidence A->B->A rejection was not explicit"
      ;;
    private-args|private-root)
      grep -Fq 'Private release control directory state or membership changed' \
        "$temporary_root/aba-$aba_scope.log" ||
        die "private-control A->B->A rejection was not explicit"
      ;;
    support-root)
      grep -Fq 'Private committed support snapshot root state changed' \
        "$temporary_root/aba-$aba_scope.log" ||
        die "private-support root A->B->A rejection was not explicit"
      ;;
  esac
  if [ "$aba_scope" != work-args ]; then
    preserved_private_path="$(
      grep -Eo '(/private)?/tmp/sp11-kernel-(baseline|support)\.[A-Za-z0-9]+' \
        "$temporary_root/aba-$aba_scope.log" | tail -1
    )"
    case "$preserved_private_path" in
      /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*|\
      /tmp/sp11-kernel-support.*|/private/tmp/sp11-kernel-support.*) ;;
      *) die "could not identify preserved hostile private fixture: $aba_scope" ;;
    esac
    [ -d "$preserved_private_path" ] && [ ! -L "$preserved_private_path" ] ||
      die "preserved hostile private fixture is no longer a real directory"
    mv "$preserved_private_path" "$aba_backup/preserved-private"
  fi
done

# Both former predictable control paths are explicit tripwires. The wrapper
# must fail before creating private controls and must never follow either link.
for control_name in docker-build-args.txt docker-build-inside.sh; do
  tripwire_work="$support_dir/build/tripwire-$control_name/work"
  tripwire_victim="$temporary_root/tripwire-$control_name/victim"
  mkdir -p "$tripwire_work" "$(dirname "$tripwire_victim")"
  printf 'control victim must remain unchanged\n' > "$tripwire_victim"
  ln -s "$tripwire_victim" "$tripwire_work/$control_name"
  if run_dry "$tripwire_work" > "$temporary_root/$control_name.log" 2>&1; then
    die "wrapper accepted symlinked legacy control path: $control_name"
  fi
  grep -Fq 'Refusing symlinked Docker control-file tripwire' \
    "$temporary_root/$control_name.log" ||
    die "control-file symlink rejection was not explicit: $control_name"
  grep -Fxq 'control victim must remain unchanged' "$tripwire_victim" ||
    die "wrapper mutated a control-file symlink victim: $control_name"
  if find "$tripwire_work" -maxdepth 1 -name '.sp11-docker-control.*' | grep -q .; then
    die "control-file tripwire failure created a private control directory"
  fi
done

# Work directories cannot be broad, contain parent traversal, or resolve
# through any symlink component.
if run_dry / > "$temporary_root/broad-work.log" 2>&1; then
  die "wrapper accepted the filesystem root as --work-dir"
fi
grep -Fq -- '--work-dir is too broad' "$temporary_root/broad-work.log" ||
  grep -Fq "must be a dedicated child of this repository's build/ directory" \
    "$temporary_root/broad-work.log" ||
    die "broad work-directory rejection was not explicit"

if run_dry "$support_dir/build" > "$temporary_root/build-root-work.log" 2>&1; then
  die "wrapper accepted the repository build root as --work-dir"
fi
grep -Fq "must be a dedicated child of this repository's build/ directory" \
  "$temporary_root/build-root-work.log" ||
  die "repository build-root rejection was not explicit"

external_work="$temporary_root/unrelated-existing/work"
mkdir -p "$external_work/artifacts"
printf 'unrelated artifact must remain unchanged\n' > "$external_work/artifacts/victim"
if run_dry "$external_work" > "$temporary_root/external-work.log" 2>&1; then
  die "wrapper accepted an existing work directory outside repository build/"
fi
grep -Fq "must be a dedicated child of this repository's build/ directory" \
  "$temporary_root/external-work.log" ||
  die "external work-directory rejection was not explicit"
grep -Fxq 'unrelated artifact must remain unchanged' "$external_work/artifacts/victim" ||
  die "wrapper mutated an unrelated external work directory"

if run_dry 'build/../escaped-work' > "$temporary_root/escaping-work.log" 2>&1; then
  die "wrapper accepted parent traversal in --work-dir"
fi
grep -Fq "must not contain a '..' path component" "$temporary_root/escaping-work.log" ||
  die "work-directory traversal rejection was not explicit"
[ ! -e "$support_dir/escaped-work" ] || die "escaping work-directory fixture created its target"

real_parent="$support_dir/build/work-symlink-real"
linked_parent="$support_dir/build/work-symlink-link"
mkdir -p "$real_parent"
ln -s "$real_parent" "$linked_parent"
if run_dry "$linked_parent/work" > "$temporary_root/symlink-work.log" 2>&1; then
  die "wrapper accepted a symlink component in --work-dir"
fi
grep -Fq 'must not contain symlink components' "$temporary_root/symlink-work.log" ||
  die "symlinked work-directory rejection was not explicit"
[ ! -e "$real_parent/work" ] || die "symlinked work-directory fixture mutated its target"

# The Linux build storage is a Docker named volume, never an implicit host
# bind mount or an option-bearing mount specification.
volume_work="$support_dir/build/volume-name-checks/work"
for invalid_volume in / ../outside named:rw named,rw path/to/volume; do
  volume_token="$(printf '%s' "$invalid_volume" | tr '/:,' '---')"
  if run_dry "$volume_work-$volume_token" --linux-work-volume "$invalid_volume" \
      > "$temporary_root/volume-$volume_token.log" 2>&1; then
    die "wrapper accepted unsafe --linux-work-volume: $invalid_volume"
  fi
  grep -Fq 'must be a Docker named volume' "$temporary_root/volume-$volume_token.log" ||
    die "named-volume rejection was not explicit: $invalid_volume"
done

# Container work paths are compared only after exact lexical canonicalization;
# traversal and separator tricks cannot evade protected-mount checks.
container_work="$support_dir/build/container-path-checks/work"
container_case=0
for invalid_container in \
  '/linux-work/../repo' \
  '/safe/../../work' \
  '/safe//work' \
  '/safe/work/' \
  $'/safe/\twork'; do
  container_case=$((container_case + 1))
  if run_dry "$container_work-$container_case" --container-work-dir "$invalid_container" \
      > "$temporary_root/container-$container_case.log" 2>&1; then
    die "wrapper accepted noncanonical --container-work-dir"
  fi
  grep -Eq 'must use a canonical absolute path|must not contain control characters' \
    "$temporary_root/container-$container_case.log" ||
    die "container-path rejection was not explicit"
done

# Payload destinations are repository-relative, canonical children of payload/.
payload_work="$support_dir/build/payload-checks/work"
if run_dry "$payload_work" --payload-dir "$support_dir/payload/kernel-debs" \
    > "$temporary_root/payload-absolute.log" 2>&1; then
  die "wrapper accepted an absolute --payload-dir"
fi
grep -Fq 'must be repository-relative beneath payload/' "$temporary_root/payload-absolute.log" ||
  die "absolute payload rejection was not explicit"

if run_dry "$payload_work" --payload-dir 'payload/../outside' \
    > "$temporary_root/payload-traversal.log" 2>&1; then
  die "wrapper accepted parent traversal in --payload-dir"
fi
grep -Fq "must not contain a '..' path component" "$temporary_root/payload-traversal.log" ||
  die "payload traversal rejection was not explicit"

payload_victim="$temporary_root/payload-victim"
mkdir -p "$payload_victim"
printf 'payload victim must remain unchanged\n' > "$payload_victim/sentinel"
ln -s "$payload_victim" "$support_dir/payload/linked-destination"
if run_dry "$payload_work" --payload-dir 'payload/linked-destination/kernel-debs' \
    > "$temporary_root/payload-link.log" 2>&1; then
  die "wrapper accepted a symlink component in --payload-dir"
fi
grep -Fq 'must not contain symlink components' "$temporary_root/payload-link.log" ||
  die "payload symlink rejection was not explicit"
grep -Fxq 'payload victim must remain unchanged' "$payload_victim/sentinel" ||
  die "wrapper mutated a payload symlink victim"
[ ! -e "$payload_victim/kernel-debs" ] || die "wrapper created a directory through a payload symlink"
if run_dry "$payload_work" --payload-dir 'payload/linked-destination' \
    > "$temporary_root/payload-leaf-link.log" 2>&1; then
  die "wrapper accepted a symlink leaf as --payload-dir"
fi
grep -Fq 'must not contain symlink components' "$temporary_root/payload-leaf-link.log" ||
  die "payload symlink-leaf rejection was not explicit"
rm -f "$support_dir/payload/linked-destination"

# A symlinked package entry also stops an actual copy-to-payload run before
# its victim or any existing package is removed.
payload_deb_victim="$temporary_root/payload-deb-victim"
payload_deb_link="$support_dir/payload/kernel-debs/tripwire.deb"
printf 'payload package victim must remain unchanged\n' > "$payload_deb_victim"
ln -s "$payload_deb_victim" "$payload_deb_link"
payload_copy_work="$support_dir/build/payload-copy/work"
if MOCK_CREATE_DEB=true PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
    --source apt \
    --source-package linux-fixture \
    --source-version 1.0 \
    --work-dir "$payload_copy_work" \
    --payload-dir 'payload/kernel-debs' \
    > "$temporary_root/payload-deb-link.log" 2>&1; then
  die "wrapper accepted a symlinked package in --payload-dir"
fi
grep -Fq 'Refusing non-regular or symlinked .deb entries in --payload-dir' \
  "$temporary_root/payload-deb-link.log" ||
  die "payload package-symlink rejection was not explicit"
grep -Fxq 'payload package victim must remain unchanged' "$payload_deb_victim" ||
  die "wrapper mutated a payload package-symlink victim"
[ -L "$payload_deb_link" ] || die "wrapper removed a payload package-symlink tripwire"
rm -f "$payload_deb_link"

# Directories and special nodes with package suffixes are also tripwires. The
# wrapper must detect all of them before pruning any existing regular package.
for collision_type in directory fifo; do
  collision_entry="$support_dir/payload/kernel-debs/collision-$collision_type.deb"
  existing_deb="$support_dir/payload/kernel-debs/existing-$collision_type.deb"
  printf 'existing payload package must remain unchanged\n' > "$existing_deb"
  chmod 0640 "$existing_deb"
  case "$collision_type" in
    directory) mkdir "$collision_entry" ;;
    fifo) mkfifo "$collision_entry" ;;
  esac
  existing_before="$(regular_fingerprint "$existing_deb")"
  collision_before="$(node_metadata "$collision_entry")"
  collision_work="$support_dir/build/payload-$collision_type-collision/work"

  if MOCK_CREATE_DEB=true PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
      --source apt \
      --source-package linux-fixture \
      --source-version 1.0 \
      --work-dir "$collision_work" \
      --payload-dir 'payload/kernel-debs' \
      > "$temporary_root/payload-$collision_type-collision.log" 2>&1; then
    die "wrapper accepted a $collision_type with a .deb suffix"
  fi
  grep -Fq 'Refusing non-regular or symlinked .deb entries in --payload-dir' \
    "$temporary_root/payload-$collision_type-collision.log" ||
    die "payload $collision_type rejection was not explicit"
  [ "$(regular_fingerprint "$existing_deb")" = "$existing_before" ] ||
    die "payload $collision_type collision changed an existing regular package"
  [ "$(node_metadata "$collision_entry")" = "$collision_before" ] ||
    die "payload $collision_type collision changed the tripwire node"

  rm -f -- "$existing_deb"
  case "$collision_type" in
    directory) rmdir "$collision_entry" ;;
    fifo) rm -f -- "$collision_entry" ;;
  esac
done

# A hostile caller cannot re-enable replacement objects or redirect Git while
# the release preflight records the support commit.
cat > "$mock_bin/git" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail
[ "${GIT_NO_REPLACE_OBJECTS:-}" = "1" ] || {
  printf 'GIT_NO_REPLACE_OBJECTS was not forced to 1\n' >&2
  exit 97
}
exec "$FIXTURE_REAL_GIT" "$@"
EOF_GIT
chmod +x "$mock_bin/git"

git_work="$support_dir/build/git-environment/work"
if ! PATH="$mock_bin:/usr/bin:/bin" \
    FIXTURE_REAL_GIT="$real_git" \
    GIT_NO_REPLACE_OBJECTS=0 \
    GIT_DIR="$temporary_root/hostile.git" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
    "$wrapper" \
      --source git \
      --git-url 'https://github.com/example/linux.git' \
      --git-branch fixture/ref \
      --expected-source-commit "$release_source_commit" \
      --image "$release_image" \
      --platform linux/arm64/v8 \
      --patch-dirs patches/release \
      --build-target 'binary-indep binary-qcom-x1e' \
      --work-dir "$git_work" \
      --release-build \
      --dry-run > "$temporary_root/git-environment.log" 2>&1; then
  cat "$temporary_root/git-environment.log" >&2
  die "wrapper did not sanitize replacement-ref and Git redirection variables"
fi

printf 'Kernel Docker wrapper path-safety fixtures passed.\n'
