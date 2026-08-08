#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root=""
temporary_parent=""
real_git="$(command -v git)"

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

regular_fingerprint() {
  local path="$1"

  printf '%s:%s\n' "$(cksum < "$path")" "$(node_metadata "$path")"
}

for tool in git grep mktemp shasum stat; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-docker-wrapper-safety.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
temporary_parent="$(dirname "$temporary_root")"
support_dir="$temporary_root/support"
mock_bin="$temporary_root/mock-bin"
mkdir -p \
  "$support_dir/scripts" \
  "$support_dir/config/kernel-baselines" \
  "$support_dir/patches/release" \
  "$support_dir/payload/kernel-debs" \
  "$mock_bin"
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
SP11_KERNEL_DOCKER_IMAGE="$release_image"
SP11_KERNEL_DOCKER_PLATFORM="linux/arm64/v8"
SP11_KERNEL_DOCKER_PLATFORM_MANIFEST="$release_child_digest"
SP11_KERNEL_UPSTREAM_URL="https://github.com/example/linux.git"
SP11_KERNEL_UPSTREAM_REF="fixture/ref"
SP11_KERNEL_UPSTREAM_COMMIT="$release_source_commit"
SP11_KERNEL_BUILD_TARGET="binary-indep binary-qcom-x1e"
SP11_KERNEL_PATCH_DIRS="patches/release"
EOF_BASELINE
cat > "$support_dir/scripts/validate-sp11-kernel-baseline.sh" <<'EOF_BASELINE_VALIDATOR'
#!/usr/bin/env bash
set -euo pipefail
test -f "$1"
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
previous=""
for argument in "$@"; do
  if [ "$previous" = "-v" ]; then
    case "$argument" in
      *:/work) host_work="${argument%:/work}" ;;
    esac
    previous=""
    continue
  fi
  previous="$argument"
done

[ -n "$host_work" ]
[ -f "$host_work/docker-build-args.txt" ] && [ ! -L "$host_work/docker-build-args.txt" ]
[ -x "$host_work/docker-build-inside.sh" ] && [ ! -L "$host_work/docker-build-inside.sh" ]
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
[ "$args_mode" = "600" ] && [ "$script_mode" = "700" ]
grep -Fxq -- '--source' "$host_work/docker-build-args.txt"
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

# Immutable validation needs an LZ4 list decoder on hosts without apt-helper.
# An isolated PATH and a wrapper fixture with an unavailable system helper make
# both fallback branches deterministic, including on Ubuntu hosts.
decoder_bin="$temporary_root/decoder-bin"
decoder_docker_marker="$temporary_root/decoder-docker-invoked"
mkdir "$decoder_bin"
for tool in \
  awk bash chmod dirname find git grep mkdir mktemp python3 rm rmdir shasum \
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
  die "missing APT list decoder rejection was not explicit"
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
  die "available lz4 did not reach the sentinel Docker failure"

# Keep normal release fixtures portable on hosts without apt-helper.
cp "$decoder_bin/lz4" "$mock_bin/lz4"

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
digest="sha256:$(printf 'a%.0s' {1..64})"
if ! PATH="$mock_bin:/usr/bin:/bin" \
    FIXTURE_REAL_GIT="$real_git" \
    GIT_NO_REPLACE_OBJECTS=0 \
    GIT_DIR="$temporary_root/hostile.git" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
    "$wrapper" \
      --source git \
      --git-url 'https://fixtures.example.com/sp11-kernel.git' \
      --git-branch fixture \
      --expected-source-commit "$(printf 'b%.0s' {1..40})" \
      --image "ubuntu:26.04@$digest" \
      --platform linux/arm64/v8 \
      --build-target 'binary-indep binary-qcom-x1e' \
      --work-dir "$git_work" \
      --release-build \
      --dry-run > "$temporary_root/git-environment.log" 2>&1; then
  cat "$temporary_root/git-environment.log" >&2
  die "wrapper did not sanitize replacement-ref and Git redirection variables"
fi

printf 'Kernel Docker wrapper path-safety fixtures passed.\n'
