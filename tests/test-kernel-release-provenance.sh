#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root=""
temporary_parent=""
real_git="$(command -v git)"
real_python3="$(command -v python3)"
digest="sha256:$(printf 'a%.0s' {1..64})"
container_image="ubuntu:26.04@$digest"
source_url="https://fixtures.example.com/sp11-kernel-fixture.git"
source_commit=""
mock_bin=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "$temporary_parent"/sp11-release-provenance.*)
      rm -rf -- "$temporary_root"
      ;;
    *)
      echo "warning: refusing to remove unexpected temporary path: $temporary_root" >&2
      ;;
  esac
}
trap cleanup EXIT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

for tool in awk cmp git grep mktemp python3 sed shasum stat xz; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root="$(mktemp -d "$temporary_parent/sp11-release-provenance.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
support_seed="$temporary_root/support-seed"
source_repo="$temporary_root/source-repository"
mock_bin="$temporary_root/mock-bin"
mkdir -p "$support_seed/scripts" "$support_seed/patches/release" "$source_repo" "$mock_bin"

cp "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/prepare-sp11-kernel-release-assets.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-source-archive.py" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-image-release-manifests.py" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-payload-identity-list.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-public-content.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" "$support_seed/scripts/"
chmod +x "$support_seed/scripts/"*.sh
printf 'build/\n' > "$support_seed/.gitignore"

printf '%s\n' \
  'diff --git a/guard.txt b/guard.txt' \
  '--- a/guard.txt' \
  '+++ b/guard.txt' \
  '@@ -1 +1 @@' \
  '-before' \
  '+after' \
  'diff --git a/new-from-patch.txt b/new-from-patch.txt' \
  'new file mode 100644' \
  '--- /dev/null' \
  '+++ b/new-from-patch.txt' \
  '@@ -0,0 +1 @@' \
  '+new file is part of the patched tree' \
  > "$support_seed/patches/release/0001-fixture-change.patch"

git -C "$support_seed" init --quiet --initial-branch=fixture
git -C "$support_seed" config user.name "SP11 CI fixture"
git -C "$support_seed" config user.email "sp11-ci@example.invalid"
git -C "$support_seed" add .
git -C "$support_seed" commit --quiet -m "Create release provenance fixture"

mkdir -p \
  "$source_repo/drivers/net/wireless/ath/ath12k" \
  "$source_repo/arch/arm64/boot/dts/qcom" \
  "$source_repo/debian"
printf 'before\n' > "$source_repo/guard.txt"
printf '%s\n' new-from-patch.txt debian/build/ > "$source_repo/.gitignore"
printf '%s\n' 'of_property_read_bool(ab->dev->of_node, "disable-rfkill")' \
  > "$source_repo/drivers/net/wireless/ath/ath12k/core.c"
printf 'disable-rfkill;\n' > "$source_repo/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi"

cat > "$source_repo/debian/rules" <<'EOF_RULES'
#!/usr/bin/env bash
set -euo pipefail

target="${1:-}"
if [ "$target" = "clean" ]; then
  exit 0
fi
if [ "${FAIL_BUILD:-false}" = "true" ]; then
  exit 42
fi

build_root="debian/build/build-qcom-x1e"
mkdir -p \
    "$build_root/arch/arm64/boot/dts/qcom" \
    "$build_root/certs"
printf 'fixture config\n' > "$build_root/.config"
printf 'fixture module symbols\n' > "$build_root/Module.symvers"
printf 'fixture system map\n' > "$build_root/System.map"
printf 'fixture EFI kernel\n' > "$build_root/arch/arm64/boot/vmlinuz.efi.stubble"
printf 'fixture OLED DTB\n' > "$build_root/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled.dtb"
printf 'fixture OLED EL2 DTB\n' > "$build_root/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled-el2.dtb"
printf 'fixture public certificate\n' > "$build_root/certs/signing_key.x509"
printf 'private fixture: must never enter provenance\n' > "$build_root/certs/signing_key.pem"
if [ "${OMIT_REQUIRED_OUTPUT:-false}" = "true" ]; then
  rm -f "$build_root/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled-el2.dtb"
fi

printf 'common headers package\n' > ../linux-qcom-x1e-headers-7.2.0-1_7.2.0-1_all.deb
printf 'headers package\n' > ../linux-headers-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb
if [ "${UNSIGNED_IMAGE:-false}" = "true" ]; then
  printf 'unsigned image package\n' > ../linux-image-unsigned-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb
else
  printf 'image package\n' > ../linux-image-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb
fi
if [ "${OMIT_MODULES_DEB:-false}" != "true" ]; then
  printf 'modules package\n' > ../linux-modules-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb
fi
if [ "${INCLUDE_OPTIONAL_DEB:-false}" = "true" ]; then
  printf 'optional modules-extra package\n' > ../linux-modules-extra-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb
fi

if [ "${MUTATE_SUPPORT:-false}" = "true" ]; then
  printf 'mutated during build\n' > "$FIXTURE_SUPPORT_DIR/mutated-during-build.txt"
fi
if [ "${MUTATE_KERNEL_SOURCE:-false}" = "true" ]; then
  printf 'mutated tracked kernel source during build\n' > guard.txt
fi
if [ "${ADD_KERNEL_SOURCE:-false}" = "true" ]; then
  printf 'generated source consumed by fixture build\n' > generated-build-input.c
fi
EOF_RULES
chmod +x "$source_repo/debian/rules"

git -C "$source_repo" init --quiet --initial-branch=fixture
git -C "$source_repo" config user.name "SP11 CI fixture"
git -C "$source_repo" config user.email "sp11-ci@example.invalid"
git -C "$source_repo" add .
git -C "$source_repo" commit --quiet -m "Create kernel source fixture"
source_commit="$(git -C "$source_repo" rev-parse 'HEAD^{commit}')"

cat > "$mock_bin/git" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  if [ "$arg" = "$FIXTURE_PUBLIC_SOURCE_URL" ]; then
    args+=("$FIXTURE_SOURCE_REPO")
  else
    args+=("$arg")
  fi
done
exec "$FIXTURE_REAL_GIT" "${args[@]}"
EOF_GIT

cat > "$mock_bin/fakeroot" <<'EOF_FAKEROOT'
#!/usr/bin/env bash
exec "$@"
EOF_FAKEROOT

cat > "$mock_bin/python3" <<'EOF_PYTHON3'
#!/usr/bin/env bash
set -euo pipefail
if [ "${MUTATE_SOURCE_AFTER_SNAPSHOT:-false}" = "true" ] &&
  [[ "$*" == *"validate-sp11-source-archive.py"* ]] &&
  [ ! -e "$FIXTURE_SOURCE_MUTATION_MARKER" ]; then
  printf 'tampered after validation snapshot\n' > "$FIXTURE_SOURCE_ASSET_TO_MUTATE"
  : > "$FIXTURE_SOURCE_MUTATION_MARKER"
fi
exec "$FIXTURE_REAL_PYTHON3" "$@"
EOF_PYTHON3

cat > "$mock_bin/dpkg-deb" <<'EOF_DPKG_DEB'
#!/usr/bin/env bash
set -euo pipefail
file="${2:-}"
field="${3:-}"
base="$(basename "$file")"
case "$base" in
  linux-qcom-x1e-headers-*) package="linux-qcom-x1e-headers-7.2.0-1"; architecture="all" ;;
  linux-headers-*) package="linux-headers-7.2.0-1-qcom-x1e"; architecture="arm64" ;;
  linux-image-unsigned-*) package="linux-image-unsigned-7.2.0-1-qcom-x1e"; architecture="arm64" ;;
  linux-image-*) package="linux-image-7.2.0-1-qcom-x1e"; architecture="arm64" ;;
  linux-modules-extra-*) package="linux-modules-extra-7.2.0-1-qcom-x1e"; architecture="arm64" ;;
  linux-modules-*) package="linux-modules-7.2.0-1-qcom-x1e"; architecture="arm64" ;;
  *) exit 1 ;;
esac
case "$field" in
  Package) printf '%s\n' "$package" ;;
  Version) printf '%s\n' '7.2.0-1' ;;
  Architecture) printf '%s\n' "$architecture" ;;
  *) exit 1 ;;
esac
EOF_DPKG_DEB

cat > "$mock_bin/openssl" <<'EOF_OPENSSL'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *signing_key.pem*) exit 99 ;;
esac
case " $* " in
  *' -fingerprint '*)
    awk 'BEGIN { printf "sha256 Fingerprint="; for (i = 1; i <= 32; i++) printf "%sAA", (i == 1 ? "" : ":"); print "" }'
    ;;
  *' -serial '*) printf '%s\n' 'serial=01' ;;
  *) exit 1 ;;
esac
EOF_OPENSSL
chmod +x "$mock_bin/"*

clone_support() {
  local name="$1"
  "$real_git" clone --quiet "$support_seed" "$temporary_root/$name"
  printf '%s\n' "$temporary_root/$name"
}

run_release_build() {
  local support_dir="$1" work_dir="$2"
  shift 2
  PATH="$mock_bin:/usr/bin:/bin" \
    FIXTURE_REAL_GIT="$real_git" \
    FIXTURE_SOURCE_REPO="$source_repo" \
    FIXTURE_PUBLIC_SOURCE_URL="$source_url" \
    SP11_BUILD_CONTAINER_IMAGE="$container_image" \
    SP11_BUILD_CONTAINER_PLATFORM="linux/arm64/v8" \
    "$support_dir/scripts/build-sp11-qcom-x1e-kernel.sh" \
      --source git \
      --git-url "$source_url" \
      --git-branch fixture \
      --expected-source-commit "$source_commit" \
      --patch-dir "$support_dir/patches/release" \
      --work-dir "$work_dir" \
      --build-target "binary-indep binary-qcom-x1e" \
      --jobs 1 \
      --min-free-gb 1 \
      --allow-non-arm64 \
      --release-build \
      "$@"
}

manifest_value() {
  local file="$1" label="$2"
  sed -n "s/^$label: //p" "$file"
}

support_a="$(clone_support support-a)"
support_b="$(clone_support support-b)"
work_a="$temporary_root/work-a"
work_b="$temporary_root/work-b"
unsafe_source_index=0
for unsafe_source_url in \
    https://localhost/kernel.git \
    https://10.0.0.1/kernel.git \
    https://169.254.10.20/kernel.git \
    https://kernel/kernel.git \
    https://fixtures.invalid/kernel.git; do
  unsafe_source_index=$((unsafe_source_index + 1))
  if SP11_BUILD_CONTAINER_IMAGE="$container_image" \
      SP11_BUILD_CONTAINER_PLATFORM=linux/arm64/v8 \
      "$support_a/scripts/build-sp11-qcom-x1e-kernel.sh" \
        --source git \
        --git-url "$unsafe_source_url" \
        --git-branch fixture \
        --expected-source-commit "$source_commit" \
        --patch-dir "$support_a/patches/release" \
        --work-dir "$temporary_root/unsafe-inner-$unsafe_source_index" \
        --build-target "binary-indep binary-qcom-x1e" \
        --jobs 1 \
        --min-free-gb 1 \
        --allow-non-arm64 \
        --release-build \
        > "$temporary_root/unsafe-inner-$unsafe_source_index.log" 2>&1; then
    die "inner release build accepted non-public source URL: $unsafe_source_url"
  fi
  grep -Fq 'requires a public HTTPS kernel source URL' \
    "$temporary_root/unsafe-inner-$unsafe_source_index.log" ||
    die "inner release build did not explain its non-public source rejection"

  if "$support_a/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
      --source git \
      --git-url "$unsafe_source_url" \
      --git-branch fixture \
      --expected-source-commit "$source_commit" \
      --image "$container_image" \
      --platform linux/arm64/v8 \
      --patch-dir patches/release \
      --build-target "binary-indep binary-qcom-x1e" \
      --work-dir "$support_a/build/unsafe-url-$unsafe_source_index" \
      --release-build \
      --dry-run \
      > "$temporary_root/unsafe-docker-$unsafe_source_index.log" 2>&1; then
    die "Docker release build accepted non-public source URL: $unsafe_source_url"
  fi
  grep -Fq 'requires a public HTTPS --git-url' \
    "$temporary_root/unsafe-docker-$unsafe_source_index.log" ||
    die "Docker release build did not explain its non-public source rejection"
done
if ! GIT_DIR="$source_repo/.git" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
    run_release_build "$support_a" "$work_a" > "$temporary_root/build-a.log" 2>&1; then
  cat "$temporary_root/build-a.log" >&2
  die "fixture release build A failed"
fi
if ! INCLUDE_OPTIONAL_DEB=true UNSIGNED_IMAGE=true \
    run_release_build "$support_b" "$work_b" > "$temporary_root/build-b.log" 2>&1; then
  cat "$temporary_root/build-b.log" >&2
  die "fixture release build B failed"
fi

manifest_a="$work_a/sp11-kernel-build-manifest.txt"
manifest_b="$work_b/sp11-kernel-build-manifest.txt"
[ -f "$manifest_a" ] && [ ! -L "$manifest_a" ] || die "build A did not produce a regular final manifest"
[ -f "$manifest_b" ] && [ ! -L "$manifest_b" ] || die "build B did not produce a regular final manifest"
grep -Fxq 'Provenance schema: sp11-kernel-build-v2' "$manifest_a" || die "schema v2 is missing"
grep -Fxq 'Release build: true' "$manifest_a" || die "release marker is missing"
grep -Fxq 'Build completed: true' "$manifest_a" || die "completion marker is missing"
grep -Fxq 'Patch 1 disposition: applied' "$manifest_a" || die "patch disposition is missing"
grep -Fxq 'Output 2 role: module-symvers' "$manifest_a" || die "Module.symvers output role is missing"
grep -Fxq 'Output 7 role: module-signing-certificate' "$manifest_a" || die "certificate output role is missing"
grep -Fxq 'Optional output roles: none' "$manifest_a" || die "optional output contract is ambiguous"
grep -Fxq 'Optional Deb roles: modules-extra' "$manifest_a" || die "optional package role is missing"
grep -Fxq 'Deb count: 4' "$manifest_a" || die "required package set is missing"
grep -Fxq 'Deb count: 5' "$manifest_b" || die "present optional package was not recorded"
grep -Eq '^Deb [1-9][0-9]* role: modules-extra$' "$manifest_b" ||
  die "optional package role was not recorded"
grep -Eq '^Deb [1-9][0-9]* path: linux-image-unsigned-7\.2\.0-1-qcom-x1e_7\.2\.0-1_arm64\.deb$' \
  "$manifest_b" || die "unsigned image package was not recorded as the image role"
optional_deb_index="$(sed -n 's/^Deb \([1-9][0-9]*\) role: modules-extra$/\1/p' "$manifest_b")"
grep -Fxq "Deb $optional_deb_index required: false" "$manifest_b" ||
  die "optional package was not classified as optional"
if grep -Fq 'signing_key.pem' "$manifest_a"; then
  die "private signing key path leaked into provenance"
fi
if grep -Fq "$temporary_root" "$manifest_a"; then
  die "absolute fixture path leaked into release provenance"
fi

diff_a="$(manifest_value "$manifest_a" 'Patched diff SHA256')"
diff_b="$(manifest_value "$manifest_b" 'Patched diff SHA256')"
tree_a="$(manifest_value "$manifest_a" 'Patched tree ID')"
tree_b="$(manifest_value "$manifest_b" 'Patched tree ID')"
[ -n "$diff_a" ] && [ "$diff_a" = "$diff_b" ] || die "patched diff hash depends on the checkout path"
[ -n "$tree_a" ] && [ "$tree_a" = "$tree_b" ] || die "patched tree ID depends on the checkout path"
git -C "$work_a/source/git-fixture" ls-tree --name-only "$tree_a" -- new-from-patch.txt |
  grep -Fxq 'new-from-patch.txt' || die "patched tree identity omitted an ignored file added by a patch"

# A failed build removes a stale manifest and never installs a partial replacement.
support_failure="$(clone_support support-failure)"
work_failure="$temporary_root/work-failure"
mkdir -p "$work_failure"
printf 'stale manifest\n' > "$work_failure/sp11-kernel-build-manifest.txt"
if FAIL_BUILD=true run_release_build "$support_failure" "$work_failure" > "$temporary_root/failure.log" 2>&1; then
  die "release build unexpectedly succeeded after the fixture build failed"
fi
[ ! -e "$work_failure/sp11-kernel-build-manifest.txt" ] || die "failed build left a stale or partial manifest"

# A prior package cannot satisfy a later successful build that omits that role.
support_stale_deb="$(clone_support support-stale-deb)"
work_stale_deb="$temporary_root/work-stale-deb"
mkdir -p "$work_stale_deb/source"
printf 'stale modules package\n' \
  > "$work_stale_deb/source/linux-modules-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb"
if OMIT_MODULES_DEB=true \
   run_release_build "$support_stale_deb" "$work_stale_deb" > "$temporary_root/stale-deb.log" 2>&1; then
  die "release build accepted a stale package from an earlier build"
fi
[ ! -e "$work_stale_deb/sp11-kernel-build-manifest.txt" ] ||
  die "stale-package failure produced a final manifest"
grep -Fq 'contains prior qcom-x1e kernel package output' "$temporary_root/stale-deb.log" ||
  die "stale package failure was not explicit"

# Reusing a checkout with ignored prior-build output is not a pristine release input.
support_stale="$(clone_support support-stale)"
work_stale="$temporary_root/work-stale"
if ! run_release_build "$support_stale" "$work_stale" > "$temporary_root/stale-first.log" 2>&1; then
  cat "$temporary_root/stale-first.log" >&2
  die "initial stale-output fixture build failed"
fi
git -C "$work_stale/source/git-fixture" reset --hard --quiet HEAD
git -C "$work_stale/source/git-fixture" clean -ffd --quiet
if run_release_build "$support_stale" "$work_stale" > "$temporary_root/stale-second.log" 2>&1; then
  die "release build reused an ignored prior-build output"
fi
[ ! -e "$work_stale/sp11-kernel-build-manifest.txt" ] ||
  die "stale source output failure retained an old final manifest"
grep -Fq 'ignored build outputs or files' "$temporary_root/stale-second.log" ||
  die "stale ignored source output failure was not explicit"

# A successful package target is still incomplete without every required build output.
support_missing_output="$(clone_support support-missing-output)"
work_missing_output="$temporary_root/work-missing-output"
if OMIT_REQUIRED_OUTPUT=true \
   run_release_build "$support_missing_output" "$work_missing_output" > "$temporary_root/missing-output.log" 2>&1; then
  die "release build accepted a missing required build output"
fi
[ ! -e "$work_missing_output/sp11-kernel-build-manifest.txt" ] ||
  die "missing-output build produced a final manifest"
grep -Fq 'Required release build output is missing' "$temporary_root/missing-output.log" ||
  die "missing required output failure was not explicit"

# A support worktree mutation during the build invalidates completion.
support_mutation="$(clone_support support-mutation)"
work_mutation="$temporary_root/work-mutation"
if MUTATE_SUPPORT=true FIXTURE_SUPPORT_DIR="$support_mutation" \
   run_release_build "$support_mutation" "$work_mutation" > "$temporary_root/mutation.log" 2>&1; then
  die "release build accepted a support repository mutation"
fi
[ ! -e "$work_mutation/sp11-kernel-build-manifest.txt" ] || die "mutated support build produced a final manifest"
grep -Fq 'Support repository changed during the release build' "$temporary_root/mutation.log" ||
  die "support mutation failure was not explicit"

# HEAD alone cannot prove that the patched worktree stayed unchanged. Recompute
# the exact pre-build path/mode/content tree and canonical diff after the build.
support_source_mutation="$(clone_support support-source-mutation)"
work_source_mutation="$temporary_root/work-source-mutation"
if MUTATE_KERNEL_SOURCE=true \
   run_release_build "$support_source_mutation" "$work_source_mutation" \
     > "$temporary_root/source-mutation.log" 2>&1; then
  die "release build accepted a tracked kernel source mutation"
fi
[ ! -e "$work_source_mutation/sp11-kernel-build-manifest.txt" ] ||
  die "mutated kernel source build produced a final manifest"
grep -Fq 'Patched kernel source input changed during the release build' \
  "$temporary_root/source-mutation.log" ||
  die "post-build kernel source mutation failure was not explicit"

# A new nonignored source path created after the pre-build capture cannot be
# allowed to influence binaries while remaining absent from the source tree ID.
support_source_addition="$(clone_support support-source-addition)"
work_source_addition="$temporary_root/work-source-addition"
if ADD_KERNEL_SOURCE=true \
   run_release_build "$support_source_addition" "$work_source_addition" \
     > "$temporary_root/source-addition.log" 2>&1; then
  die "release build accepted a new post-capture source path"
fi
[ ! -e "$work_source_addition/sp11-kernel-build-manifest.txt" ] ||
  die "post-capture source-addition build produced a final manifest"
grep -Fq 'A nonignored source path was added or removed during the release build' \
  "$temporary_root/source-addition.log" ||
  die "post-capture source-addition failure was not explicit"

# A tracked symlink with a .patch suffix is rejected before source mutation.
support_symlink="$(clone_support support-symlink)"
ln -s 0001-fixture-change.patch "$support_symlink/patches/release/0002-symlink.patch"
git -C "$support_symlink" add patches/release/0002-symlink.patch
git -C "$support_symlink" -c user.name='SP11 CI fixture' -c user.email='sp11-ci@example.invalid' \
  commit --quiet -m 'Add unsafe patch symlink fixture'
if run_release_build "$support_symlink" "$temporary_root/work-symlink" > "$temporary_root/symlink.log" 2>&1; then
  die "release build accepted a symlinked patch"
fi
grep -Fq 'must not contain symlinked .patch entries' "$temporary_root/symlink.log" ||
  die "symlinked patch failure was not explicit"

# Git inspection errors are provenance failures, never evidence of a clean tree.
support_status_failure="$(clone_support support-status-failure)"
printf 'invalid fixture index\n' > "$support_status_failure/.git/index"
if run_release_build "$support_status_failure" "$temporary_root/work-status-failure" \
    > "$temporary_root/status-build.log" 2>&1; then
  die "release build interpreted a failed support status as clean"
fi
grep -Fq 'Could not inspect the support repository worktree state' "$temporary_root/status-build.log" ||
  die "release build status failure was not explicit"

# Docker release mode must be explicit and passes the contract to the inner build.
docker_work="$support_a/build/docker-work"
if "$support_a/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --source git \
    --git-url "$source_url" \
    --git-branch fixture \
    --expected-source-commit "$source_commit" \
    --image 'ubuntu:26.04' \
    --platform linux/arm64/v8 \
    --patch-dir patches/release \
    --build-target "binary-indep binary-qcom-x1e" \
    --work-dir "$docker_work-invalid" \
    --release-build \
    --dry-run > "$temporary_root/docker-invalid.log" 2>&1; then
  die "Docker release mode accepted a floating image"
fi
grep -Fq 'requires an explicit --image pinned with @sha256' "$temporary_root/docker-invalid.log" ||
  die "floating image failure was not explicit"

if "$support_a/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --source git \
    --git-url "$source_url" \
    --git-branch fixture \
    --expected-source-commit "$source_commit" \
    --image "$container_image" \
    --patch-dir patches/release \
    --build-target "binary-indep binary-qcom-x1e" \
    --work-dir "$docker_work-no-platform" \
    --release-build \
    --dry-run > "$temporary_root/docker-platform.log" 2>&1; then
  die "Docker release mode accepted an implicit platform"
fi
grep -Fq 'requires an explicit --platform' "$temporary_root/docker-platform.log" ||
  die "implicit platform failure was not explicit"

if "$support_a/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --source git \
    --git-url "$source_url" \
    --git-branch fixture \
    --expected-source-commit "$source_commit" \
    --image "$container_image" \
    --platform linux/arm64/v8 \
    --patch-dir patches/release \
    --build-target "binary-indep binary-qcom-x1e" \
    --work-dir "$support_a/build/docker-overlap" \
    --container-work-dir /repo \
    --release-build \
    --dry-run > "$temporary_root/docker-overlap.log" 2>&1; then
  die "Docker wrapper accepted a work volume over the trusted /repo mount"
fi
grep -Fq 'must not overlap a container control or support-repository mount' \
  "$temporary_root/docker-overlap.log" ||
  die "Docker control-mount overlap rejection was not explicit"

if ! GIT_DIR="$source_repo/.git" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
    "$support_a/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --source git \
    --git-url "$source_url" \
    --git-branch fixture \
    --expected-source-commit "$source_commit" \
    --image "$container_image" \
    --platform linux/arm64/v8 \
    --patch-dir patches/release \
    --build-target "binary-indep binary-qcom-x1e" \
    --work-dir "$docker_work" \
    --release-build \
    --dry-run > "$temporary_root/docker-valid.log" 2>&1; then
  cat "$temporary_root/docker-valid.log" >&2
  die "valid Docker release preflight failed"
fi
grep -Fq -- '--release-build' "$temporary_root/docker-valid.log" ||
  die "inner release flag was not forwarded"
grep -Fq "SP11_BUILD_CONTAINER_PLATFORM=linux/arm64/v8" "$temporary_root/docker-valid.log" ||
  die "container platform was not forwarded"

if "$support_status_failure/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --source git \
    --git-url "$source_url" \
    --git-branch fixture \
    --expected-source-commit "$source_commit" \
    --image "$container_image" \
    --platform linux/arm64/v8 \
    --patch-dir patches/release \
    --build-target "binary-indep binary-qcom-x1e" \
    --work-dir "$support_status_failure/build/docker-status-failure" \
    --release-build \
    --dry-run > "$temporary_root/status-docker.log" 2>&1; then
  die "Docker release wrapper interpreted a failed support status as clean"
fi
grep -Fq 'Could not inspect the support repository worktree state' "$temporary_root/status-docker.log" ||
  die "Docker release status failure was not explicit"

run_preparer() {
  local support_dir="$1" artifacts_dir="$2" release_name="$3"
  local kernel_debs_dir="${4:-$work_a/source}"
  local source_asset="${5:-}"
  local -a source_args=(--allow-missing-source)
  if [ -n "$source_asset" ]; then
    source_args+=(--source-asset "$source_asset")
  fi
  PATH="$mock_bin:/usr/bin:/bin" \
    FIXTURE_REAL_GIT="$real_git" \
    FIXTURE_SOURCE_REPO="$source_repo" \
    FIXTURE_PUBLIC_SOURCE_URL="$source_url" \
    FIXTURE_REAL_PYTHON3="$real_python3" \
    "$support_dir/scripts/prepare-sp11-kernel-release-assets.sh" \
      --kernel-debs-dir "$kernel_debs_dir" \
      --artifacts-dir "$artifacts_dir" \
      --patch-dir "$support_dir/patches/release" \
      --release-name "$release_name" \
      --out-dir "build/release/$release_name" \
      "${source_args[@]}"
}

if ! run_preparer "$support_a" "$work_a" fixture-v2 > "$temporary_root/prepare-valid.log" 2>&1; then
  cat "$temporary_root/prepare-valid.log" >&2
  die "valid schema-v2 release preparation failed"
fi
if ! run_preparer "$support_b" "$work_b" fixture-v2-optional "$work_b/source" \
    > "$temporary_root/prepare-optional.log" 2>&1; then
  cat "$temporary_root/prepare-optional.log" >&2
  die "schema-v2 release preparation rejected a present optional package"
fi
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  if PATH="$mock_bin:/usr/bin:/bin" \
      GIT_DIR="$source_repo/.git" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
      FIXTURE_REAL_GIT="$real_git" \
      FIXTURE_SOURCE_REPO="$source_repo" \
      FIXTURE_PUBLIC_SOURCE_URL="$source_url" \
      FIXTURE_REAL_PYTHON3="$real_python3" \
      "$support_a/scripts/validate-sp11-touchscreen-release.sh" \
        --dir "$support_a/build/release/fixture-v2" \
        > "$temporary_root/validate-source-less-v2.log" 2>&1; then
    die "standalone release validator accepted a source-less schema-v2 draft"
  fi
  grep -Fq 'missing or unsafe kernel source archive name' \
    "$temporary_root/validate-source-less-v2.log" ||
    die "source-less schema-v2 rejection was not explicit"
else
  printf 'Skipping standalone release-validator round trip: Bash 4+ is exercised in Linux CI.\n'
fi
if run_preparer "$support_status_failure" "$work_a" fixture-status-failure \
    > "$temporary_root/status-prepare.log" 2>&1; then
  die "release preparer interpreted a failed support status as clean"
fi
grep -Fq 'Could not inspect the support repository worktree state' "$temporary_root/status-prepare.log" ||
  die "release preparer status failure was not explicit"
release_manifest="$support_a/build/release/fixture-v2/sp11-kernel-release-manifest.txt"
attached_build_manifest="$support_a/build/release/fixture-v2/sp11-kernel-build-manifest.txt"
cmp "$manifest_a" "$attached_build_manifest" ||
  die "kernel release did not attach the exact validated schema-v2 build manifest"
grep -Fq '  sp11-kernel-build-manifest.txt' \
  "$support_a/build/release/fixture-v2/SHA256SUMS" ||
  die "kernel release checksums omitted the schema-v2 build manifest"
grep -Fxq 'Build provenance schema: sp11-kernel-build-v2' "$release_manifest" ||
  die "release manifest omitted schema-v2 provenance"
grep -Fxq "Container platform: linux/arm64/v8" "$release_manifest" ||
  die "release manifest omitted the container platform"
grep -Fxq "Patched diff SHA256: $diff_a" "$release_manifest" ||
  die "release manifest omitted the patched diff identity"
if grep -Fq "$temporary_root" "$release_manifest"; then
  die "release manifest leaked an absolute fixture path"
fi
if grep -R -Fq "$temporary_root" "$support_a/build/release/fixture-v2"; then
  die "prepared public release assets leaked an absolute fixture path"
fi

release_source_dir="$support_a/build/release-source"
mkdir -p "$release_source_dir"
kernel_source_archive="$release_source_dir/fixture-v2-patched-source.tar.xz"
git -C "$work_a/source/git-fixture" archive \
  --format=tar \
  --prefix=fixture-v2-patched-source/ \
  "$tree_a" |
  xz --threads=1 -6 > "$kernel_source_archive"
kernel_source_archive_sha="$(shasum -a 256 "$kernel_source_archive" | awk '{print $1}')"
if ! GIT_DIR="$source_repo/.git" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
    run_preparer "$support_a" "$work_a" fixture-v2-source "$work_a/source" \
    "$kernel_source_archive" > "$temporary_root/prepare-source.log" 2>&1; then
  cat "$temporary_root/prepare-source.log" >&2
  die "release preparer rejected an exact patched-tree source archive"
fi
grep -Fq 'gh release create' "$temporary_root/prepare-source.log" ||
  die "validated source preparation did not produce a publish command"

release_source_dir_b="$support_b/build/release-source"
mkdir -p "$release_source_dir_b"
kernel_source_archive_b="$release_source_dir_b/fixture-v2-optional-patched-source.tar.xz"
git -C "$work_b/source/git-fixture" archive \
  --format=tar \
  --prefix=fixture-v2-optional-patched-source/ \
  "$tree_b" |
  xz --threads=1 -6 > "$kernel_source_archive_b"
if ! run_preparer "$support_b" "$work_b" fixture-v2-optional-source \
    "$work_b/source" "$kernel_source_archive_b" \
    > "$temporary_root/prepare-optional-source.log" 2>&1; then
  cat "$temporary_root/prepare-optional-source.log" >&2
  die "schema-v2 release preparation rejected source-bound optional/unsigned packages"
fi

if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  validate_schema_v2_dir() {
    local support_dir="$1" release_name="$2" log_name="$3"
    PATH="$mock_bin:/usr/bin:/bin" \
      GIT_DIR="$source_repo/.git" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
      FIXTURE_REAL_GIT="$real_git" \
      FIXTURE_SOURCE_REPO="$source_repo" \
      FIXTURE_PUBLIC_SOURCE_URL="$source_url" \
      FIXTURE_REAL_PYTHON3="$real_python3" \
      "$support_dir/scripts/validate-sp11-touchscreen-release.sh" \
        --dir "$support_dir/build/release/$release_name" --tag "$release_name" \
        > "$temporary_root/$log_name" 2>&1
  }
  rewrite_release_checksums() {
    local release_dir="$1" checksum_files=() checksum_file
    while IFS= read -r checksum_file; do checksum_files+=("$checksum_file"); done < <(
      find "$release_dir" -mindepth 1 -maxdepth 1 -type f \
        ! -name SHA256SUMS ! -name RELEASE-NOTES.md \
        -exec basename {} \; | LC_ALL=C sort
    )
    (cd "$release_dir" && shasum -a 256 "${checksum_files[@]}" > SHA256SUMS)
  }

  git -C "$support_a" tag fixture-v2-source
  git -C "$support_b" tag fixture-v2-optional-source
  if ! validate_schema_v2_dir "$support_a" fixture-v2-source \
      validate-flat-v2-source.log; then
    cat "$temporary_root/validate-flat-v2-source.log" >&2
    die "standalone release validator rejected a fully bound schema-v2 kernel release"
  fi
  if ! validate_schema_v2_dir "$support_b" fixture-v2-optional-source \
      validate-flat-v2-optional-source.log; then
    cat "$temporary_root/validate-flat-v2-optional-source.log" >&2
    die "standalone release validator rejected source-bound optional/unsigned schema-v2 assets"
  fi

  bound_release_dir="$support_a/build/release/fixture-v2-source"
  printf 'checksummed but not manifest-bound\n' > "$bound_release_dir/unexpected.txt"
  rewrite_release_checksums "$bound_release_dir"
  if validate_schema_v2_dir "$support_a" fixture-v2-source \
      validate-flat-v2-extra.log; then
    die "standalone release validator accepted an unexpected checksummed schema-v2 asset"
  fi
  grep -Fq 'schema-v2 release contains an unexpected asset: unexpected.txt' \
    "$temporary_root/validate-flat-v2-extra.log" ||
    die "unexpected schema-v2 asset rejection was not explicit"
  rm "$bound_release_dir/unexpected.txt"
  rewrite_release_checksums "$bound_release_dir"

  cp "$bound_release_dir/sp11-kernel-release-manifest.txt" \
    "$temporary_root/kernel-release-manifest.original"
  printf 'Build provenance schema: sp11-kernel-build-v2\n' \
    >> "$bound_release_dir/sp11-kernel-release-manifest.txt"
  rewrite_release_checksums "$bound_release_dir"
  if validate_schema_v2_dir "$support_a" fixture-v2-source \
      validate-flat-v2-schema-duplicate.log; then
    die "standalone release validator accepted an ambiguous schema declaration"
  fi
  grep -Fq 'unsupported or ambiguous Build provenance schema declaration' \
    "$temporary_root/validate-flat-v2-schema-duplicate.log" ||
    die "ambiguous schema rejection was not explicit"
  cp "$temporary_root/kernel-release-manifest.original" \
    "$bound_release_dir/sp11-kernel-release-manifest.txt"
  rewrite_release_checksums "$bound_release_dir"

  support_ahead="$(clone_support support-validator-ahead)"
  mkdir -p "$support_ahead/build/release"
  cp -R "$bound_release_dir" "$support_ahead/build/release/fixture-v2-source"
  git -C "$support_ahead" tag fixture-v2-source
  printf 'newer support work continued\n' > "$support_ahead/after-release.txt"
  git -C "$support_ahead" add after-release.txt
  git -C "$support_ahead" -c user.name='SP11 CI fixture' \
    -c user.email='sp11-ci@example.invalid' commit --quiet -m 'Advance after release'
  if ! validate_schema_v2_dir "$support_ahead" fixture-v2-source \
      validate-flat-v2-ahead.log; then
    cat "$temporary_root/validate-flat-v2-ahead.log" >&2
    die "standalone validator required current HEAD instead of the exact release tag"
  fi
fi

support_no_origin="$(clone_support support-no-origin)"
git -C "$support_no_origin" remote remove origin
mkdir -p "$support_no_origin/build/release-source"
no_origin_source="$support_no_origin/build/release-source/fixture-v2-patched-source.tar.xz"
cp "$kernel_source_archive" "$no_origin_source"
if run_preparer "$support_no_origin" "$work_a" fixture-v2-no-origin \
    "$work_a/source" "$no_origin_source" \
    > "$temporary_root/prepare-no-origin.log" 2>&1; then
  die "publishable kernel preparer accepted a repository without origin"
fi
grep -Fq 'support repository has no origin remote' \
  "$temporary_root/prepare-no-origin.log" || {
  cat "$temporary_root/prepare-no-origin.log" >&2
  die "missing kernel release origin rejection was not explicit"
}

augmented_artifacts="$temporary_root/augmented-artifacts"
mkdir -p "$augmented_artifacts"
cp "$manifest_a" "$augmented_artifacts/sp11-kernel-build-manifest.txt"
printf 'Forged extra field: accepted-by-loose-parser\n' \
  >> "$augmented_artifacts/sp11-kernel-build-manifest.txt"
if run_preparer "$support_a" "$augmented_artifacts" fixture-v2-extra-field \
    "$work_a/source" "$kernel_source_archive" \
    > "$temporary_root/prepare-extra-field.log" 2>&1; then
  die "release preparer accepted an extra schema-v2 build-manifest field"
fi
grep -Fq 'unexpected top-level field' "$temporary_root/prepare-extra-field.log" ||
  die "extra build-manifest field rejection was not explicit"

cp "$manifest_a" "$augmented_artifacts/sp11-kernel-build-manifest.txt"
printf 'forged colonless release claim\n' \
  >> "$augmented_artifacts/sp11-kernel-build-manifest.txt"
if run_preparer "$support_a" "$augmented_artifacts" fixture-v2-nonschema \
    "$work_a/source" "$kernel_source_archive" \
    > "$temporary_root/prepare-nonschema.log" 2>&1; then
  die "release preparer accepted a non-schema build-manifest line"
fi
grep -Fq 'contains a non-schema line' "$temporary_root/prepare-nonschema.log" ||
  die "non-schema build-manifest rejection was not explicit"

toctou_archive="$release_source_dir/fixture-v2-toctou-patched-source.tar.xz"
cp "$support_a/build/release/fixture-v2-source/fixture-v2-patched-source.tar.xz" "$toctou_archive"
mutation_marker="$temporary_root/source-mutated"
if ! MUTATE_SOURCE_AFTER_SNAPSHOT=true \
    FIXTURE_SOURCE_ASSET_TO_MUTATE="$toctou_archive" \
    FIXTURE_SOURCE_MUTATION_MARKER="$mutation_marker" \
    run_preparer "$support_a" "$work_a" fixture-v2-toctou "$work_a/source" \
      "$toctou_archive" > "$temporary_root/prepare-toctou.log" 2>&1; then
  cat "$temporary_root/prepare-toctou.log" >&2
  die "release preparer did not preserve its validated source snapshot"
fi
[ -e "$mutation_marker" ] || die "source TOCTOU fixture did not mutate the original input"
prepared_toctou="$support_a/build/release/fixture-v2-toctou/$(basename "$toctou_archive")"
[ "$(shasum -a 256 "$prepared_toctou" | awk '{print $1}')" = "$kernel_source_archive_sha" ] ||
  die "prepared source archive did not retain the validated pre-mutation bytes"

expect_prepare_failure() {
  local artifacts_dir="$1" release_name="$2" expected="$3"
  if run_preparer "$support_a" "$artifacts_dir" "$release_name" > "$temporary_root/$release_name.log" 2>&1; then
    die "release preparer accepted invalid provenance for $release_name"
  fi
  grep -Fq "$expected" "$temporary_root/$release_name.log" ||
    die "release preparer did not explain $release_name failure"
}

nonpublic_url_index=0
for nonpublic_url in \
    https://localhost/kernel.git \
    https://192.168.50.10/kernel.git \
    https://kernel/kernel.git \
    https://fixtures.invalid/kernel.git; do
  nonpublic_url_index=$((nonpublic_url_index + 1))
  nonpublic_artifacts="$temporary_root/nonpublic-url-$nonpublic_url_index"
  mkdir "$nonpublic_artifacts"
  sed "s#^Source URL: .*#Source URL: $nonpublic_url#" \
    "$manifest_a" > "$nonpublic_artifacts/sp11-kernel-build-manifest.txt"
  expect_prepare_failure "$nonpublic_artifacts" \
    "fixture-nonpublic-url-$nonpublic_url_index" \
    'kernel source URL is not public HTTPS provenance'
done

cross_validator_artifacts="$temporary_root/cross-validator-private-url"
mkdir "$cross_validator_artifacts"
sed 's#^Source URL: .*#Source URL: https://169.254.10.20/kernel.git#' \
  "$manifest_a" > "$cross_validator_artifacts/sp11-kernel-build-manifest.txt"
support_commit_a="$(manifest_value "$manifest_a" "Support start HEAD")"
if python3 "$support_a/scripts/validate-sp11-image-release-manifests.py" \
    --build-only \
    --repo-dir "$support_a" \
    --support-commit "$support_commit_a" \
    --kernel-build-manifest "$cross_validator_artifacts/sp11-kernel-build-manifest.txt" \
    > "$temporary_root/cross-validator-private-url.log" 2>&1; then
  die "schema-v2 cross-validator accepted a link-local source URL"
fi
grep -Fq 'build source URL is not credential-free public HTTPS' \
  "$temporary_root/cross-validator-private-url.log" ||
  die "schema-v2 cross-validator did not explain its non-public source rejection"

legacy_artifacts="$temporary_root/legacy-artifacts"
mkdir -p "$legacy_artifacts"
sed 's/^Provenance schema: .*/Provenance schema: sp11-kernel-build-v1/' \
  "$manifest_a" > "$legacy_artifacts/sp11-kernel-build-manifest.txt"
expect_prepare_failure "$legacy_artifacts" fixture-v1 'Refusing non-v2 kernel build provenance'

nonrelease_artifacts="$temporary_root/nonrelease-artifacts"
mkdir -p "$nonrelease_artifacts"
sed 's/^Release build: true$/Release build: false/' \
  "$manifest_a" > "$nonrelease_artifacts/sp11-kernel-build-manifest.txt"
expect_prepare_failure "$nonrelease_artifacts" fixture-nonrelease 'not marked as a release build'

incomplete_artifacts="$temporary_root/incomplete-artifacts"
mkdir -p "$incomplete_artifacts"
sed '/^Build completed: true$/d' \
  "$manifest_a" > "$incomplete_artifacts/sp11-kernel-build-manifest.txt"
expect_prepare_failure "$incomplete_artifacts" fixture-incomplete "exactly one nonempty 'Build completed:' field"

bad_patch_artifacts="$temporary_root/bad-patch-artifacts"
mkdir -p "$bad_patch_artifacts"
sed "s/^Patch 1 SHA256: .*/Patch 1 SHA256: $(printf '0%.0s' {1..64})/" \
  "$manifest_a" > "$bad_patch_artifacts/sp11-kernel-build-manifest.txt"
expect_prepare_failure "$bad_patch_artifacts" fixture-bad-patch 'patch order or SHA-256 does not match'

image_deb="$work_a/source/linux-image-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb"
cp "$image_deb" "$temporary_root/image.deb.backup"
printf 'tampered\n' >> "$image_deb"
expect_prepare_failure "$work_a" fixture-tampered-deb 'does not match its build provenance'
mv "$temporary_root/image.deb.backup" "$image_deb"

"$repo_dir/tests/test-source-archive-bindings.sh"
"$repo_dir/tests/test-touchscreen-module-source-provenance.sh"
printf 'Kernel release provenance fixtures passed.\n'
