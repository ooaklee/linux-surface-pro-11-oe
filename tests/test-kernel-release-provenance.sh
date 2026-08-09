#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root=""
temporary_parent=""
real_git="$(command -v git)"
real_mv="$(command -v mv)"
real_python3="$(command -v python3)"
real_rm="$(command -v rm)"
digest="sha256:db2cb7b11291904f12adeed10ae23fbc95e7bed27f27bd3e35ade0d501e302ce"
container_image="ubuntu:26.04@$digest"
source_url="https://github.com/example/linux.git"
source_commit=""
source_date_epoch="1785567085"
kbuild_build_user="sp11-builder"
kbuild_build_host="sp11-build"
kbuild_build_timestamp="Sat Aug  1 06:51:25 UTC 2026"
mock_bin=""
apt_decoder_root=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "$temporary_parent"/sp11-apt-fixture.release-provenance.*)
      chmod -R u+w -- "$temporary_root" 2>/dev/null || true
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

regular_file_state() {
  local path="$1" metadata digest

  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  case "$(uname -s)" in
    Darwin) metadata="$(stat -f '%d:%i:%z:%m:%c:%Lp:%l' "$path")" ;;
    *) metadata="$(stat -c '%d:%i:%s:%Y:%Z:%a:%h' -- "$path")" ;;
  esac
  digest="$(shasum -a 256 "$path" | awk '{print $1}')"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s:%s\n' "$metadata" "$digest"
}

directory_permission_mode() {
  local path="$1" value
  if value="$(stat -f '%Lp' "$path" 2>/dev/null)"; then
    printf '%s\n' "$value"
  else
    stat -c '%a' -- "$path"
  fi
}

assert_incomplete_preparer_root() {
  local path="$1" log="$2"
  [ -d "$path" ] && [ ! -L "$path" ] ||
    die "failed release preparation lost its forensic output root"
  [ "$(directory_permission_mode "$path")" = 700 ] ||
    die "failed release preparation did not remain mode 0700"
  if grep -Fq 'Prepared verified release assets.' "$log"; then
    die "failed release preparation emitted a terminal success claim"
  fi
  if grep -Fq 'Traceback (most recent call last)' "$log"; then
    die "failed release preparation leaked an unexpected traceback"
  fi
}

assert_zero_regular() {
  local path="$1" size
  [ -f "$path" ] && [ ! -L "$path" ] ||
    die "expected a retained zero-length regular file: $path"
  case "$(uname -s)" in
    Darwin) size="$(stat -f '%z' "$path")" ;;
    Linux) size="$(stat -c '%s' -- "$path")" ;;
    *) die "unsupported platform for retained publication size checks" ;;
  esac
  [ "$size" = 0 ] ||
    die "retained failed publication bytes were not scrubbed: $path"
}

assert_no_publication_success() {
  local log="$1"
  if grep -Fq 'Wrote completed schema-v2 release build manifest' "$log"; then
    die "failed release publication printed a success claim"
  fi
  if grep -Fq 'Traceback (most recent call last)' "$log"; then
    die "failed release publication leaked an unexpected traceback"
  fi
  if grep -Fq 'SP11_KERNEL_RELEASE_PUBLICATION_FIXTURE_HOOK' "$log"; then
    die "failed release publication leaked its private hook authority"
  fi
}

for tool in awk cmp git grep mktemp python3 readlink sed shasum stat uname xz; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
grep -Fq 'digest-pinned OCI/APT /usr, loader, libraries, Python' \
  "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" ||
  die "kernel builder does not state its pinned toolchain trust boundary"
grep -Fq 'KERNEL_TREE_VALIDATOR_PYTHON="/proc/self/fd/8"' \
  "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" ||
  die "kernel builder does not retain the Linux validator interpreter FD"

temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root="$(mktemp -d "$temporary_parent/sp11-apt-fixture.release-provenance.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
apt_decoder_root="$temporary_root"
mkdir -p "$apt_decoder_root/mock-bin"
cat > "$apt_decoder_root/mock-bin/apt-helper" <<'EOF_APT_HELPER'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] && [ "$1" = "cat-file" ] || exit 2
cat "$2"
EOF_APT_HELPER
chmod 0755 "$apt_decoder_root/mock-bin/apt-helper"
tree_state_root="$temporary_root/tree-state-root"
tree_state_file="$temporary_root/tree-state.json"
mkdir -p "$tree_state_root/nested"
printf 'tree state fixture\n' > "$tree_state_root/nested/value"
printf 'newline-safe fixture\n' > "$tree_state_root/"$'line\nbreak'
python3 "$repo_dir/scripts/sp11-release-tree-state.py" snapshot \
  --root "$tree_state_root" --snapshot "$tree_state_file" >/dev/null
python3 "$repo_dir/scripts/sp11-release-tree-state.py" validate \
  --root "$tree_state_root" --snapshot "$tree_state_file" >/dev/null
printf 'tampered\n' >> "$tree_state_root/nested/value"
if python3 "$repo_dir/scripts/sp11-release-tree-state.py" validate \
    --root "$tree_state_root" --snapshot "$tree_state_file" \
    > "$temporary_root/tree-state-tamper.log" 2>&1; then
  die "release-tree state validator accepted changed file bytes"
fi
printf 'tree state fixture\n' > "$tree_state_root/nested/value"
ln -s value "$tree_state_root/nested/unsafe-link"
if python3 "$repo_dir/scripts/sp11-release-tree-state.py" snapshot \
    --root "$tree_state_root" --snapshot "$temporary_root/unsafe-tree-state.json" \
    > "$temporary_root/tree-state-symlink.log" 2>&1; then
  die "release-tree state validator accepted a symlinked entry"
fi
rm "$tree_state_root/nested/unsafe-link"
private_container_root="$temporary_root/private-container"
mkdir "$private_container_root"
chmod 700 "$private_container_root"
python3 "$repo_dir/scripts/sp11-release-tree-state.py" validate-private \
  --root "$private_container_root" >/dev/null
mkdir "$private_container_root/candidate"
python3 "$repo_dir/scripts/sp11-release-tree-state.py" validate-private \
  --root "$private_container_root" --child candidate >/dev/null
printf 'unknown private entry\n' > "$private_container_root/"$'\n'
if python3 "$repo_dir/scripts/sp11-release-tree-state.py" validate-private \
    --root "$private_container_root" --child candidate \
    > "$temporary_root/private-container-extra.log" 2>&1; then
  die "private-container validator accepted an extra newline-named child"
fi
rm "$private_container_root/"$'\n'
support_seed="$temporary_root/support-seed"
source_repo="$temporary_root/source-repository"
mock_bin="$temporary_root/mock-bin"
mkdir -p "$support_seed/scripts" "$support_seed/patches/release" "$source_repo" "$mock_bin"

cp "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/prepare-sp11-kernel-release-assets.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/sp11-release-tree-state.py" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-source-archive.py" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-image-release-manifests.py" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-oci-index.py" "$support_seed/scripts/"
cp "$repo_dir/scripts/sp11-kernel-build-inputs.py" "$support_seed/scripts/"
cp "$repo_dir/scripts/sp11-kernel-release-state.py" "$support_seed/scripts/"
cp "$repo_dir/scripts/emit-sp11-kernel-release-state.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-kernel-tree-symlinks.py" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-payload-identity-list.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-public-content.sh" "$support_seed/scripts/"
cp "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" "$support_seed/scripts/"
cat > "$support_seed/scripts/validate-sp11-kernel-baseline.sh" <<'EOF_BASELINE_VALIDATOR'
#!/usr/bin/env bash
set -euo pipefail
baseline_path=""
baseline_fd=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir) [ "$#" -ge 2 ]; shift 2 ;;
    --emit-release-values) shift ;;
    --baseline-fd) [ "$#" -ge 2 ]; baseline_fd="$2"; shift 2 ;;
    --*) exit 1 ;;
    *) [ -z "$baseline_path" ]; baseline_path="$1"; shift ;;
  esac
done
if [ -n "$baseline_fd" ]; then
  [ "$baseline_fd" = 3 ]
  case "$(uname -s)" in
    Linux) baseline_path=/proc/self/fd/3 ;;
    Darwin) baseline_path=/dev/fd/3 ;;
    *) exit 1 ;;
  esac
fi
[ -n "$baseline_path" ]
[ -f "$baseline_path" ]
# shellcheck disable=SC1090
. "$baseline_path"
[ "$SP11_KERNEL_SOURCE_DATE_EPOCH" = "1785567085" ]
[ "$SP11_KERNEL_KBUILD_BUILD_USER" = "sp11-builder" ]
[ "$SP11_KERNEL_KBUILD_BUILD_HOST" = "sp11-build" ]
[ "$SP11_KERNEL_KBUILD_BUILD_TIMESTAMP" = "Sat Aug  1 06:51:25 UTC 2026" ]
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
EOF_BASELINE_VALIDATOR
chmod +x "$support_seed/scripts/"*.sh
printf 'build/\n' > "$support_seed/.gitignore"
printf '%s\n' 'sp11-kernel-release-provenance-v1' \
  > "$support_seed/.sp11-kernel-release-provenance-fixture"

printf '%s\n' \
  'diff --git a/guard.txt b/guard.txt' \
  '--- a/guard.txt' \
  '+++ b/guard.txt' \
  '@@ -1,2 +1,2 @@' \
  ' fixture_function()' \
  '-before' \
  '+after' \
  'diff --git a/new-from-patch.txt b/new-from-patch.txt' \
  'new file mode 100644' \
  '--- /dev/null' \
  '+++ b/new-from-patch.txt' \
  '@@ -0,0 +1 @@' \
  '+new file is part of the patched tree' \
  > "$support_seed/patches/release/0001-fixture-change.patch"

cat > "$support_seed/patches/release/0002-delete-unsafe-baseline-link.patch" <<'EOF_DELETE_LINK'
diff --git a/debian/scripts/misc/find-dtbs.py b/debian/scripts/misc/find-dtbs.py
deleted file mode 120000
--- a/debian/scripts/misc/find-dtbs.py
+++ /dev/null
@@ -1 +0,0 @@
-/private/host-only/stubble/hwids/finddtbs.py
\ No newline at end of file
EOF_DELETE_LINK

git -C "$support_seed" init --quiet --initial-branch=fixture
git -C "$support_seed" config user.name "SP11 CI fixture"
git -C "$support_seed" config user.email "sp11-ci@example.invalid"
git -C "$support_seed" add .
git -C "$support_seed" commit --quiet -m "Create release provenance fixture"

mkdir -p \
  "$source_repo/drivers/net/wireless/ath/ath12k" \
  "$source_repo/arch/arm64/boot/dts/qcom" \
  "$source_repo/debian/scripts/misc"
printf 'guard.txt diff=cpp\n' > "$source_repo/.gitattributes"
printf 'fixture_function()\nbefore\n' > "$source_repo/guard.txt"
printf '%s\n' new-from-patch.txt debian/build/ > "$source_repo/.gitignore"
printf '%s\n' 'of_property_read_bool(ab->dev->of_node, "disable-rfkill")' \
  > "$source_repo/drivers/net/wireless/ath/ath12k/core.c"
printf 'disable-rfkill;\n' > "$source_repo/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi"
ln -s /private/host-only/stubble/hwids/finddtbs.py \
  "$source_repo/debian/scripts/misc/find-dtbs.py"

cat > "$source_repo/debian/rules" <<'EOF_RULES'
#!/usr/bin/env bash
set -euo pipefail

target="${1:-}"
test "${SOURCE_DATE_EPOCH:-}" = "1785567085"
test "${KBUILD_BUILD_USER:-}" = "sp11-builder"
test "${KBUILD_BUILD_HOST:-}" = "sp11-build"
test "${KBUILD_BUILD_TIMESTAMP:-}" = "Sat Aug  1 06:51:25 UTC 2026"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$target" "$SOURCE_DATE_EPOCH" "$KBUILD_BUILD_USER" \
  "$KBUILD_BUILD_HOST" "$KBUILD_BUILD_TIMESTAMP" >> "$FIXTURE_IDENTITY_LOG"
if [ "$target" = "clean" ]; then
  exit 0
fi
if [ "$target" = "debian/control" ]; then
  printf 'Source: linux-fixture\nBuild-Depends: fixture-dependency\n' > debian/control
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
GIT_AUTHOR_DATE="$source_date_epoch +0000" \
GIT_COMMITTER_DATE="$source_date_epoch +0000" \
  git -C "$source_repo" commit --quiet -m "Create kernel source fixture"
source_commit="$(git -C "$source_repo" rev-parse 'HEAD^{commit}')"
[ "$(git -C "$source_repo" show -s --format=%ct "$source_commit")" = "$source_date_epoch" ] ||
  die "kernel fixture commit did not retain the deterministic source epoch"

apt_template="$temporary_root/immutable-apt-template"
mkdir -p "$support_seed/config/kernel-baselines"
python3 "$repo_dir/tests/test-sp11-immutable-apt-provenance.py" \
  --emit-release-template "$apt_template" \
  "$support_seed/config/kernel-baselines/7.2-rc5-jg-0.env" \
  "$source_commit" fixture
git -C "$support_seed" add config/kernel-baselines/7.2-rc5-jg-0.env
git -C "$support_seed" -c user.name='SP11 CI fixture' \
  -c user.email='sp11-ci@example.invalid' commit --quiet -m 'Add immutable input fixture'

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
if [ "${HOSTILE_SOURCE_DIFF_CONFIG:-false}" = "true" ] &&
   [ "${args[0]:-}" = "clone" ]; then
  destination="${args[${#args[@]} - 1]}"
  "$FIXTURE_REAL_GIT" "${args[@]}"
  printf 'guard.txt\n' > "$destination/.git/hostile-order"
  printf 'guard.txt -diff\n' > "$destination/.git/hostile-attributes"
  "$FIXTURE_REAL_GIT" -C "$destination" config diff.algorithm histogram
  "$FIXTURE_REAL_GIT" -C "$destination" config diff.renames copies
  "$FIXTURE_REAL_GIT" -C "$destination" config diff.orderFile \
    "$destination/.git/hostile-order"
  "$FIXTURE_REAL_GIT" -C "$destination" config diff.indentHeuristic false
  "$FIXTURE_REAL_GIT" -C "$destination" config diff.context 12
  "$FIXTURE_REAL_GIT" -C "$destination" config diff.interHunkContext 5
  "$FIXTURE_REAL_GIT" -C "$destination" config core.attributesFile \
    "$destination/.git/hostile-attributes"
  exit 0
fi
exec "$FIXTURE_REAL_GIT" "${args[@]}"
EOF_GIT

cat > "$mock_bin/mv" <<'EOF_MV'
#!/usr/bin/env bash
set -euo pipefail
real_mv="${FIXTURE_REAL_MV:-/bin/mv}"
exec "$real_mv" "$@"
EOF_MV

cat > "$mock_bin/rm" <<'EOF_RM'
#!/usr/bin/env bash
set -euo pipefail
real_rm="${FIXTURE_REAL_RM:-/bin/rm}"
exec "$real_rm" "$@"
EOF_RM

cat > "$mock_bin/fakeroot" <<'EOF_FAKEROOT'
#!/usr/bin/env bash
exec "$@"
EOF_FAKEROOT

cat > "$mock_bin/id" <<'EOF_ID'
#!/usr/bin/env bash
if [ "${FIXTURE_FORCE_NON_ROOT:-false}" = "true" ] && [ "${1:-}" = "-u" ]; then
  printf '1000\n'
  exit 0
fi
exec /usr/bin/id "$@"
EOF_ID

cat > "$mock_bin/sudo" <<'EOF_SUDO'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --preserve-env=* ]]; then
  [ "$1" = "--preserve-env=SOURCE_DATE_EPOCH,KBUILD_BUILD_USER,KBUILD_BUILD_HOST,KBUILD_BUILD_TIMESTAMP" ]
  shift
  [ "${1:-}" = "--" ]
  shift
  test "${SOURCE_DATE_EPOCH:-}" = "1785567085"
  test "${KBUILD_BUILD_USER:-}" = "sp11-builder"
  test "${KBUILD_BUILD_HOST:-}" = "sp11-build"
  test "${KBUILD_BUILD_TIMESTAMP:-}" = "Sat Aug  1 06:51:25 UTC 2026"
  printf 'sudo-preserve\n' >> "$FIXTURE_IDENTITY_LOG"
fi
exec "$@"
EOF_SUDO

cat > "$mock_bin/apt-get" <<'EOF_APT_GET'
#!/usr/bin/env bash
set -euo pipefail
printf 'apt-get\t%s\n' "$*" >> "$FIXTURE_IDENTITY_LOG"
exit 0
EOF_APT_GET

cat > "$mock_bin/dpkg-query" <<'EOF_DPKG_QUERY'
#!/usr/bin/env bash
exit 0
EOF_DPKG_QUERY

cat > "$mock_bin/lz4" <<'EOF_LZ4'
#!/usr/bin/env bash
exit 0
EOF_LZ4

cat > "$mock_bin/mk-build-deps" <<'EOF_MK_BUILD_DEPS'
#!/usr/bin/env bash
set -euo pipefail
test "${SOURCE_DATE_EPOCH:-}" = "1785567085"
test "${KBUILD_BUILD_USER:-}" = "sp11-builder"
test "${KBUILD_BUILD_HOST:-}" = "sp11-build"
test "${KBUILD_BUILD_TIMESTAMP:-}" = "Sat Aug  1 06:51:25 UTC 2026"
printf 'mk-build-deps\t%s\t%s\t%s\t%s\n' \
  "$SOURCE_DATE_EPOCH" "$KBUILD_BUILD_USER" "$KBUILD_BUILD_HOST" \
  "$KBUILD_BUILD_TIMESTAMP" >> "$FIXTURE_IDENTITY_LOG"
exit 0
EOF_MK_BUILD_DEPS

cat > "$mock_bin/python3" <<'EOF_PYTHON3'
#!/usr/bin/env bash
set -euo pipefail
if [ "${MUTATE_SOURCE_BEFORE_VALIDATION:-false}" = "true" ] &&
  [[ "$*" == *"validate-sp11-source-archive.py"* ]] &&
  [ ! -e "$FIXTURE_SOURCE_MUTATION_MARKER" ]; then
  printf 'tampered before semantic validation\n' > "$FIXTURE_SOURCE_ASSET_TO_MUTATE"
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
  local support_dir="$1" work_dir="$2" support_commit
  shift 2
  support_commit="$(
    unset GIT_DIR GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    "$real_git" -C "$support_dir" rev-parse 'HEAD^{commit}'
  )"
  PATH="$mock_bin:/usr/bin:/bin" \
    FIXTURE_REAL_GIT="$real_git" \
    FIXTURE_REAL_MV="$real_mv" \
    FIXTURE_REAL_RM="$real_rm" \
    FIXTURE_SOURCE_REPO="$source_repo" \
    FIXTURE_PUBLIC_SOURCE_URL="$source_url" \
    FIXTURE_IDENTITY_LOG="$temporary_root/build-identity-environment.log" \
    SP11_KERNEL_RELEASE_TEST_FIXTURE="${SP11_KERNEL_RELEASE_TEST_FIXTURE_OVERRIDE:-sp11-kernel-release-provenance-v1}" \
    SP11_BUILD_CONTAINER_IMAGE="${FIXTURE_CONTAINER_IMAGE_OVERRIDE:-$container_image}" \
    SP11_BUILD_CONTAINER_PLATFORM="${FIXTURE_CONTAINER_PLATFORM_OVERRIDE:-linux/arm64/v8}" \
    SP11_EXPECTED_SUPPORT_COMMIT="$support_commit" \
    "$support_dir/scripts/build-sp11-qcom-x1e-kernel.sh" \
      --source git \
      --git-url "$source_url" \
      --git-branch fixture \
      --expected-source-commit "$source_commit" \
      --source-date-epoch "$source_date_epoch" \
      --kbuild-build-user "$kbuild_build_user" \
      --kbuild-build-host "$kbuild_build_host" \
      --kbuild-build-timestamp "$kbuild_build_timestamp" \
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

seal_provenance_volume() {
  local support_dir="$1" volume_work="$2" evidence_tar="$3" support_head="$4"
  local baseline helper validator object_format baseline_sha build_args_sha
  local entrypoint_sha oci_sha helper_sha validator_sha helper_oid validator_oid
  local helper_size validator_size validator_argv_sha
  local -a host_args production_argv

  baseline="$support_dir/config/kernel-baselines/7.2-rc5-jg-0.env"
  helper="$support_dir/scripts/sp11-kernel-build-inputs.py"
  validator="$support_dir/scripts/validate-sp11-image-release-manifests.py"
  baseline_sha="$(shasum -a 256 "$baseline" | awk '{print $1}')"
  build_args_sha="$(shasum -a 256 "$volume_work/docker-build-args.txt" | awk '{print $1}')"
  entrypoint_sha="$(shasum -a 256 "$volume_work/docker-build-inside.sh" | awk '{print $1}')"
  oci_sha="$(shasum -a 256 "$volume_work/sp11-oci-index.json" | awk '{print $1}')"
  helper_sha="$(shasum -a 256 "$helper" | awk '{print $1}')"
  validator_sha="$(shasum -a 256 "$validator" | awk '{print $1}')"
  helper_oid="$(/usr/bin/git -C "$support_dir" rev-parse \
    "$support_head:scripts/sp11-kernel-build-inputs.py")"
  validator_oid="$(/usr/bin/git -C "$support_dir" rev-parse \
    "$support_head:scripts/validate-sp11-image-release-manifests.py")"
  helper_size="$(wc -c < "$helper" | tr -d '[:space:]')"
  validator_size="$(wc -c < "$validator" | tr -d '[:space:]')"
  case "${#support_head}" in
    40) object_format=sha1 ;;
    64) object_format=sha256 ;;
    *) die "fixture support commit has an unsupported object format" ;;
  esac

  host_args=(
    validate
    --baseline "$baseline"
    --baseline-sha256 "$baseline_sha"
    --build-args-sha256 "$build_args_sha"
    --entrypoint-sha256 "$entrypoint_sha"
    --oci-index-sha256 "$oci_sha"
    --work-dir "$volume_work"
    --support-head "$support_head"
    --build-args "$volume_work/docker-build-args.txt"
    --entrypoint "$volume_work/docker-build-inside.sh"
    --oci-index "$volume_work/sp11-oci-index.json"
    --build-manifest "$volume_work/artifacts/sp11-kernel-build-manifest.txt"
    --apt-provenance "$volume_work/artifacts/sp11-kernel-apt-provenance.txt"
    --apt-archives-dir "$volume_work/apt-archives"
    --apt-lists-dir "$volume_work/apt-lists"
    --apt-index-cache-dir "$volume_work/apt-indexes"
    --apt-local-build-deps-dir "$volume_work/artifacts"
    --apt-pre-inventory "$volume_work/sp11-apt-installed-pre.txt"
    --apt-post-inventory "$volume_work/sp11-apt-installed-post.txt"
    --output "$volume_work/artifacts/sp11-kernel-build-inputs.txt"
    --apt-bootstrap-state "$volume_work/sp11-apt-bootstrap-state.txt"
    --attestation-output "$volume_work/sp11-kernel-preseal-validation.txt"
    --git-object-format "$object_format"
    --build-inputs-helper-sha256 "$helper_sha"
    --build-inputs-helper-object-id "$helper_oid"
    --manifest-validator-sha256 "$validator_sha"
    --manifest-validator-object-id "$validator_oid"
  )
  production_argv=(
    /usr/bin/python3 -I /repo/scripts/sp11-kernel-build-inputs.py
    validate
    --baseline /sp11-control/kernel-baseline.env
    --baseline-sha256 "$baseline_sha"
    --build-args-sha256 "$build_args_sha"
    --entrypoint-sha256 "$entrypoint_sha"
    --oci-index-sha256 "$oci_sha"
    --work-dir /work
    --support-head "$support_head"
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
    --git-object-format "$object_format"
    --build-inputs-helper-sha256 "$helper_sha"
    --build-inputs-helper-object-id "$helper_oid"
    --manifest-validator-sha256 "$validator_sha"
    --manifest-validator-object-id "$validator_oid"
  )
  validator_argv_sha="$(/usr/bin/python3 -I -c '
import hashlib
import sys
digest = hashlib.sha256()
for argument in sys.argv[1:]:
    encoded = argument.encode("ascii")
    if not encoded or len(encoded) > 8192 or b"\0" in encoded:
        raise SystemExit(1)
    digest.update(encoded)
    digest.update(b"\0")
print(digest.hexdigest())
' "${production_argv[@]}")" || die "could not hash the fixture validator vector"

  SP11_APT_FIXTURE_ROOT="$apt_decoder_root" \
  SP11_APT_HELPER="$apt_decoder_root/mock-bin/apt-helper" \
    /usr/bin/python3 -I -c '
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
module_path = sys.argv[1]
production_count = int(sys.argv[2], 10)
production = tuple(sys.argv[3 : 3 + production_count])
arguments = sys.argv[3 + production_count :]
specification = importlib.util.spec_from_file_location(
    "sp11_kernel_build_inputs_provenance_bridge", module_path
)
if specification is None or specification.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(specification)
sys.modules[specification.name] = module
specification.loader.exec_module(module)
module.exact_validator_argv = lambda: production
sys.argv = [module_path, *arguments]
module.main()
' "$helper" "${#production_argv[@]}" "${production_argv[@]}" \
      "${host_args[@]}" >/dev/null

  /usr/bin/python3 -I "$support_dir/scripts/sp11-kernel-release-state.py" seal \
    --work-root "$volume_work" \
    --support-head "$support_head" \
    --baseline-sha256 "$baseline_sha" \
    --build-args-sha256 "$build_args_sha" \
    --entrypoint-sha256 "$entrypoint_sha" \
    --oci-index-sha256 "$oci_sha" \
    --container-image "$container_image" \
    --container-platform linux/arm64/v8 \
    --git-object-format "$object_format" \
    --validator-argv-sha256 "$validator_argv_sha" \
    --build-inputs-helper-size "$helper_size" \
    --build-inputs-helper-sha256 "$helper_sha" \
    --build-inputs-helper-object-id "$helper_oid" \
    --manifest-validator-size "$validator_size" \
    --manifest-validator-sha256 "$validator_sha" \
    --manifest-validator-object-id "$validator_oid"

  /usr/bin/python3 -I -c '
import importlib.util
import os
import stat
import sys
from pathlib import Path

sys.dont_write_bytecode = True
helper_path = Path(sys.argv[1])
stage = Path(sys.argv[2])
target = Path(sys.argv[3])
specification = importlib.util.spec_from_file_location(
    "sp11_kernel_release_state_provenance_bridge", helper_path
)
if specification is None or specification.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(specification)
sys.modules[specification.name] = module
specification.loader.exec_module(module)
catalog = (stage / "catalog").read_bytes()
count = int(next(
    line.removeprefix("Payload count: ")
    for line in catalog.decode("ascii").splitlines()
    if line.startswith("Payload count: ")
))
members = [("catalog", catalog)]
for index in range(1, count + 1):
    name = "objects/%08d" % index
    members.append((name, (stage / name).read_bytes()))
descriptor = os.open(
    target,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
    0o600,
)
try:
    for name, payload in members:
        module.write_all(descriptor, module.canonical_ustar_header(name, len(payload)))
        module.write_all(descriptor, payload)
        padding = (-len(payload)) % 512
        if padding:
            module.write_all(descriptor, bytes(padding))
    module.write_all(descriptor, bytes(1024))
    os.fchmod(descriptor, 0o644)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
' "$support_dir/scripts/sp11-kernel-release-state.py" \
    "$volume_work/.sp11-release-export-v1" "$evidence_tar"
}

make_provenance_work() {
  local support_dir="$1" build_work="$2" provenance_work="$3"
  local support_head deb volume_work evidence_tar fixed_name

  [ ! -e "$provenance_work" ] || die "provenance fixture work already exists: $provenance_work"
  volume_work="${provenance_work}.release-volume"
  evidence_tar="${provenance_work}.retained-evidence.tar"
  [ ! -e "$volume_work" ] && [ ! -e "$evidence_tar" ] ||
    die "provenance fixture retained state already exists"
  mkdir -p "$volume_work"
  cp -R "$apt_template/." "$volume_work/"
  : > "$volume_work/apt-archives/lock"
  chmod 0644 "$volume_work/apt-archives/lock"
  chmod 0700 "$volume_work" "$volume_work/artifacts"
  chmod 0600 \
    "$volume_work/docker-build-args.txt" \
    "$volume_work/docker-build-inside.sh" \
    "$volume_work/sp11-oci-index.json"
  cp "$build_work/sp11-kernel-build-manifest.txt" \
    "$volume_work/artifacts/sp11-kernel-build-manifest.txt"
  cp "$build_work/sp11-kernel-debs.txt" \
    "$volume_work/artifacts/sp11-kernel-debs.txt"
  while IFS= read -r deb; do
    cp "$deb" "$volume_work/artifacts/"
  done < <(find "$build_work/source" -maxdepth 1 -type f -name '*.deb' | LC_ALL=C sort)
  support_head="$(git -C "$support_dir" rev-parse 'HEAD^{commit}')"
  SP11_APT_FIXTURE_ROOT="$apt_decoder_root" \
  SP11_APT_HELPER="$apt_decoder_root/mock-bin/apt-helper" \
    python3 "$support_dir/scripts/sp11-kernel-build-inputs.py" write \
    --baseline "$support_dir/config/kernel-baselines/7.2-rc5-jg-0.env" \
    --work-dir "$volume_work" \
    --support-head "$support_head" \
    --build-args "$volume_work/docker-build-args.txt" \
    --entrypoint "$volume_work/docker-build-inside.sh" \
    --oci-index "$volume_work/sp11-oci-index.json" \
    --build-manifest "$volume_work/artifacts/sp11-kernel-build-manifest.txt" \
    --apt-provenance "$volume_work/artifacts/sp11-kernel-apt-provenance.txt" \
    --apt-archives-dir "$volume_work/apt-archives" \
    --apt-lists-dir "$volume_work/apt-lists" \
    --apt-index-cache-dir "$volume_work/apt-indexes" \
    --apt-local-build-deps-dir "$volume_work/artifacts" \
    --apt-pre-inventory "$volume_work/sp11-apt-installed-pre.txt" \
    --apt-post-inventory "$volume_work/sp11-apt-installed-post.txt" \
    --output "$volume_work/artifacts/sp11-kernel-build-inputs.txt" \
    >/dev/null

  seal_provenance_volume "$support_dir" "$volume_work" "$evidence_tar" "$support_head"
  if find "$support_dir/scripts" \
      \( -type d -name __pycache__ -o -type f -name '*.pyc' \) \
      -print -quit | grep -q .; then
    die "provenance bridge left Python bytecode in the support checkout"
  fi

  mkdir -m 0700 "$provenance_work"
  mkdir -m 0700 "$provenance_work/artifacts"
  for fixed_name in \
    docker-build-args.txt docker-build-inside.sh sp11-oci-index.json; do
    cp "$volume_work/$fixed_name" "$provenance_work/$fixed_name"
    chmod 0600 "$provenance_work/$fixed_name"
  done
  cp "$evidence_tar" "$provenance_work/sp11-kernel-retained-evidence.tar"
  chmod 0644 "$provenance_work/sp11-kernel-retained-evidence.tar"
  for fixed_name in \
    sp11-kernel-build-manifest.txt \
    sp11-kernel-debs.txt \
    sp11-kernel-apt-provenance.txt \
    sp11-kernel-build-inputs.txt; do
    cp "$volume_work/artifacts/$fixed_name" \
      "$provenance_work/artifacts/$fixed_name"
  done
  while IFS= read -r deb; do
    [ -n "$deb" ] || continue
    cp "$volume_work/artifacts/$deb" "$provenance_work/artifacts/$deb"
  done < "$volume_work/artifacts/sp11-kernel-debs.txt"
  chmod 0644 "$provenance_work/artifacts/"*
}

clone_provenance_work() {
  local source_work="$1" destination_work="$2"
  [ ! -e "$destination_work" ] || die "cloned provenance work already exists: $destination_work"
  mkdir -m 0700 "$destination_work"
  cp -R "$source_work/." "$destination_work/"
  chmod 0700 "$destination_work/artifacts"
  chmod 0600 \
    "$destination_work/docker-build-args.txt" \
    "$destination_work/docker-build-inside.sh" \
    "$destination_work/sp11-oci-index.json"
}

refresh_build_manifest_envelope_binding() {
  local provenance_work="$1" manifest envelope size digest temporary
  manifest="$provenance_work/artifacts/sp11-kernel-build-manifest.txt"
  envelope="$provenance_work/artifacts/sp11-kernel-build-inputs.txt"
  size="$(wc -c < "$manifest" | tr -d '[:space:]')"
  digest="$(shasum -a 256 "$manifest" | awk '{print $1}')"
  temporary="$provenance_work/artifacts/.sp11-kernel-build-inputs.refresh"
  awk -v size="$size" -v digest="$digest" '
    /^Input 4 size: / { print "Input 4 size: " size; next }
    /^Input 4 SHA256: / { print "Input 4 SHA256: " digest; next }
    { print }
  ' "$envelope" > "$temporary"
  mv "$temporary" "$envelope"
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
        --source-date-epoch "$source_date_epoch" \
        --kbuild-build-user "$kbuild_build_user" \
        --kbuild-build-host "$kbuild_build_host" \
        --kbuild-build-timestamp "$kbuild_build_timestamp" \
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

expect_identity_failure() {
  local name="$1" expected="$2"
  shift 2
  if run_release_build "$support_a" "$temporary_root/identity-$name" "$@" \
      > "$temporary_root/identity-$name.log" 2>&1; then
    die "inner release build accepted hostile deterministic identity: $name"
  fi
  grep -Fq -- "$expected" "$temporary_root/identity-$name.log" || {
    cat "$temporary_root/identity-$name.log" >&2
    die "inner release identity rejection was not explicit: $name"
  }
}

expect_identity_failure alternate-user \
  'Release build identity arguments do not match the trusted kernel baseline' \
  --kbuild-build-user alternate-builder
expect_identity_failure alternate-host \
  'Release build identity arguments do not match the trusted kernel baseline' \
  --kbuild-build-host alternate-host
expect_identity_failure alternate-timestamp \
  'Release build identity arguments do not match the trusted kernel baseline' \
  --kbuild-build-timestamp 'Sat Aug  1 06:51:26 UTC 2026'
expect_identity_failure alternate-epoch \
  'Release build identity arguments do not match the trusted kernel baseline' \
  --source-date-epoch 1785567086
expect_identity_failure unsafe-user \
  '--kbuild-build-user must be a bounded portable identity' \
  --kbuild-build-user 'unsafe user'
expect_identity_failure wrong-source \
  'Release build source arguments do not match the trusted kernel baseline' \
  --expected-source-commit 0000000000000000000000000000000000000000
expect_identity_failure alternate-url \
  'Release build source arguments do not match the trusted kernel baseline' \
  --git-url https://github.com/example/alternate-linux.git
expect_identity_failure alternate-ref \
  'Release build source arguments do not match the trusted kernel baseline' \
  --git-branch fixture/alternate
FIXTURE_CONTAINER_IMAGE_OVERRIDE="ubuntu:26.04@sha256:$(printf 'a%.0s' {1..64})" \
  expect_identity_failure alternate-image \
    'Release build container identity does not match the trusted kernel baseline'
FIXTURE_CONTAINER_PLATFORM_OVERRIDE=linux/arm64 \
  expect_identity_failure alternate-platform \
    'Release build container identity does not match the trusted kernel baseline'
expect_identity_failure alternate-target \
  '--release-build requires --build-target "binary-indep binary-qcom-x1e"' \
  --build-target binary-qcom-x1e
expect_identity_failure alternate-patches \
  'Release build patch directories do not match the trusted kernel baseline' \
  --patch-dir "$support_a/patches"
SP11_KERNEL_RELEASE_TEST_FIXTURE_OVERRIDE=disabled \
  expect_identity_failure direct-inner-wrapper-only \
    '--release-build is wrapper-only and requires its exact private /repo support snapshot'

if ! FIXTURE_FORCE_NON_ROOT=true \
    GIT_DIR="$source_repo/.git" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
    run_release_build "$support_a" "$work_a" --install-deps \
      > "$temporary_root/build-a.log" 2>&1; then
  cat "$temporary_root/build-a.log" >&2
  die "fixture release build A failed"
fi

identity_log="$temporary_root/build-identity-environment.log"
for identity_target in debian/control clean binary-indep binary-qcom-x1e; do
  grep -Fq "$identity_target"$'\t'"$source_date_epoch"$'\t'"$kbuild_build_user"$'\t'"$kbuild_build_host"$'\t'"$kbuild_build_timestamp" \
    "$identity_log" || die "deterministic build identity did not reach rules target: $identity_target"
done
grep -Fxq 'sudo-preserve' "$identity_log" ||
  die "non-root build-deps path did not preserve the deterministic identity explicitly"
grep -Fq "mk-build-deps"$'\t'"$source_date_epoch"$'\t'"$kbuild_build_user"$'\t'"$kbuild_build_host"$'\t'"$kbuild_build_timestamp" \
  "$identity_log" || die "deterministic build identity did not reach mk-build-deps"
if ! FIXTURE_FORCE_NON_ROOT=true INCLUDE_OPTIONAL_DEB=true UNSIGNED_IMAGE=true \
    HOSTILE_SOURCE_DIFF_CONFIG=true \
    run_release_build "$support_b" "$work_b" --install-deps \
      > "$temporary_root/build-b.log" 2>&1; then
  cat "$temporary_root/build-b.log" >&2
  die "fixture release build B failed"
fi

provenance_a="$temporary_root/provenance-a"
provenance_b="$temporary_root/provenance-b"
make_provenance_work "$support_a" "$work_a" "$provenance_a"
make_provenance_work "$support_b" "$work_b" "$provenance_b"

manifest_a="$work_a/sp11-kernel-build-manifest.txt"
manifest_b="$work_b/sp11-kernel-build-manifest.txt"
[ -f "$manifest_a" ] && [ ! -L "$manifest_a" ] || die "build A did not produce a regular final manifest"
[ -f "$manifest_b" ] && [ ! -L "$manifest_b" ] || die "build B did not produce a regular final manifest"
grep -Fxq 'Provenance schema: sp11-kernel-build-v2' "$manifest_a" || die "schema v2 is missing"
grep -Fxq 'Release build: true' "$manifest_a" || die "release marker is missing"
grep -Fxq 'Build completed: true' "$manifest_a" || die "completion marker is missing"
grep -Fxq 'Patch 1 disposition: applied' "$manifest_a" || die "patch disposition is missing"
grep -Fxq 'Patch 2 disposition: applied' "$manifest_a" ||
  die "unsafe-link deletion patch disposition is missing"
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
baseline_link_entry="$(
  git -C "$source_repo" ls-tree "$source_commit" -- debian/scripts/misc/find-dtbs.py
)"
case "$baseline_link_entry" in
  '120000 blob '*'	debian/scripts/misc/find-dtbs.py') ;;
  *) die "kernel source fixture did not capture its unsafe baseline symlink" ;;
esac
[ -z "$(
  git -C "$work_a/source/git-fixture" ls-tree "$tree_a" -- \
    debian/scripts/misc/find-dtbs.py
)" ] || die "patched tree retained the unsafe baseline symlink"

# A release patch which adds an absolute symlink must fail at the exact-tree
# preflight before any package target runs or a final manifest is written.
support_unsafe_tree_link="$(clone_support support-unsafe-tree-link)"
cat > "$support_unsafe_tree_link/patches/release/0003-add-unsafe-link.patch" <<'EOF_UNSAFE_LINK'
diff --git a/unsafe-added-link b/unsafe-added-link
new file mode 120000
--- /dev/null
+++ b/unsafe-added-link
@@ -0,0 +1 @@
+/private/host-only/terminal-secret
\ No newline at end of file
EOF_UNSAFE_LINK
git -C "$support_unsafe_tree_link" add patches/release/0003-add-unsafe-link.patch
git -C "$support_unsafe_tree_link" -c user.name='SP11 CI fixture' \
  -c user.email='sp11-ci@example.invalid' commit --quiet \
  -m 'Add unsafe exact-tree link fixture'
unsafe_tree_work="$temporary_root/work-unsafe-tree-link"
identity_lines_before="$(wc -l < "$identity_log" | tr -d ' ')"
if run_release_build "$support_unsafe_tree_link" "$unsafe_tree_work" \
    > "$temporary_root/unsafe-tree-link.log" 2>&1; then
  die "release build accepted a patch-added absolute symlink"
fi
[ ! -e "$unsafe_tree_work/sp11-kernel-build-manifest.txt" ] ||
  die "unsafe exact tree produced a final build manifest"
grep -Fq 'Exact patched kernel tree symlink-containment preflight failed.' \
  "$temporary_root/unsafe-tree-link.log" ||
  die "unsafe exact-tree helper failure was not bounded and explicit"
grep -Fq 'Refusing build-dependency generation for an unsafe patched kernel tree.' \
  "$temporary_root/unsafe-tree-link.log" ||
  die "unsafe exact-tree build refusal was not explicit"
if grep -Fq '/private/host-only/terminal-secret' \
    "$temporary_root/unsafe-tree-link.log"; then
  die "unsafe exact-tree failure leaked symlink target bytes"
fi
[ "$(wc -l < "$identity_log" | tr -d ' ')" = "$identity_lines_before" ] ||
  die "unsafe exact-tree preflight reached a package rules target"
[ ! -e "$unsafe_tree_work/source/git-fixture/debian/build" ] ||
  die "unsafe exact-tree preflight allowed build output"

# Publication terminal checks bind the requested work-root name as well as
# both held output inodes. A fixture-only persistent root substitution after
# all byte hashes must fail and scrub only the original held output inodes.
support_publication_root="$(clone_support support-publication-root)"
work_publication_root="$temporary_root/work-publication-root"
publication_victim="$work_publication_root.publication-victim"
mkdir -p "$publication_victim"
printf 'victim package list\n' > "$publication_victim/sp11-kernel-debs.txt"
printf 'victim manifest\n' > \
  "$publication_victim/sp11-kernel-build-manifest.txt"
victim_deb_state="$(regular_file_state \
  "$publication_victim/sp11-kernel-debs.txt")"
victim_manifest_state="$(regular_file_state \
  "$publication_victim/sp11-kernel-build-manifest.txt")"
if SP11_KERNEL_RELEASE_PUBLICATION_FIXTURE_HOOK=swap-work-root-terminal \
   run_release_build "$support_publication_root" "$work_publication_root" \
     > "$temporary_root/publication-root-swap.log" 2>&1; then
  die "release publication accepted a terminal work-root substitution"
fi
grep -Fq 'Could not seal the held release outputs' \
  "$temporary_root/publication-root-swap.log" ||
  die "terminal work-root substitution refusal was not explicit"
[ "$(regular_file_state "$work_publication_root/sp11-kernel-debs.txt")" = \
  "$victim_deb_state" ] ||
  die "terminal work-root refusal changed the victim package list"
[ "$(regular_file_state \
  "$work_publication_root/sp11-kernel-build-manifest.txt")" = \
  "$victim_manifest_state" ] ||
  die "terminal work-root refusal changed the victim manifest"
assert_zero_regular \
  "$work_publication_root.publication-held/sp11-kernel-debs.txt"
assert_zero_regular \
  "$work_publication_root.publication-held/sp11-kernel-build-manifest.txt"
assert_no_publication_success "$temporary_root/publication-root-swap.log"

# A stable in-place mutation of FD10 after its first hash is detected by the
# collective second hash/pass, and both exact output inodes are scrubbed.
support_publication_fd10="$(clone_support support-publication-fd10)"
work_publication_fd10="$temporary_root/work-publication-fd10"
if SP11_KERNEL_RELEASE_PUBLICATION_FIXTURE_HOOK=mutate-fd10-after-primary \
   run_release_build "$support_publication_fd10" "$work_publication_fd10" \
     > "$temporary_root/publication-fd10.log" 2>&1; then
  die "release publication accepted post-primary FD10 mutation"
fi
grep -Fq 'Could not seal the held release outputs' \
  "$temporary_root/publication-fd10.log" ||
  die "post-primary FD10 mutation refusal was not explicit"
assert_zero_regular "$work_publication_fd10/sp11-kernel-debs.txt"
assert_zero_regular "$work_publication_fd10/sp11-kernel-build-manifest.txt"
assert_no_publication_success "$temporary_root/publication-fd10.log"

# Intended fingerprints are fixed before the first seal. Mutation before that
# seal fails, while two TERM deliveries during cleanup cannot interrupt the
# exact-FD scrub of the second output.
support_publication_signal="$(clone_support support-publication-signal)"
work_publication_signal="$temporary_root/work-publication-signal"
mkdir -p "$work_publication_signal"
printf 'pending\n' > \
  "$work_publication_signal/.sp11-publication-scrub-marker"
chmod 0600 "$work_publication_signal/.sp11-publication-scrub-marker"
if SP11_KERNEL_RELEASE_PUBLICATION_FIXTURE_HOOK=mutate-intended-double-term-scrub \
   run_release_build "$support_publication_signal" "$work_publication_signal" \
     > "$temporary_root/publication-signal.log" 2>&1; then
  die "release publication adopted bytes changed before first seal"
fi
grep -Fq 'Could not seal the held release outputs' \
  "$temporary_root/publication-signal.log" ||
  die "pre-seal intended-byte mutation refusal was not explicit"
grep -Fxq 'double-term-survived' \
  "$work_publication_signal/.sp11-publication-scrub-marker" ||
  die "double TERM delivery interrupted exact-FD publication cleanup"
assert_zero_regular "$work_publication_signal/sp11-kernel-debs.txt"
assert_zero_regular "$work_publication_signal/sp11-kernel-build-manifest.txt"
assert_no_publication_success "$temporary_root/publication-signal.log"

# The late exact creator refuses special/symlinked targets with O_EXCL before
# any open for writing. The disposable fixture retains those injected nodes so
# their type and target/victim bytes can be checked after refusal.
support_publication_fifo="$(clone_support support-publication-fifo)"
work_publication_fifo="$temporary_root/work-publication-fifo"
if SP11_KERNEL_RELEASE_PUBLICATION_FIXTURE_HOOK=inject-fifo-before-open \
   run_release_build "$support_publication_fifo" "$work_publication_fifo" \
     > "$temporary_root/publication-fifo.log" 2>&1; then
  die "release publication opened a late FIFO output target"
fi
[ -p "$work_publication_fifo/sp11-kernel-debs.txt" ] ||
  die "late FIFO target was not retained for type verification"
[ ! -e "$work_publication_fifo/sp11-kernel-build-manifest.txt" ] ||
  die "late FIFO refusal created the second release output"
grep -Fq 'Could not exclusively create the release output names' \
  "$temporary_root/publication-fifo.log" ||
  die "late FIFO output refusal was not explicit"
assert_no_publication_success "$temporary_root/publication-fifo.log"

support_publication_symlink="$(clone_support support-publication-symlink)"
work_publication_symlink="$temporary_root/work-publication-symlink"
mkdir -p "$work_publication_symlink"
printf 'symlink victim bytes\n' > \
  "$work_publication_symlink/.sp11-publication-victim"
symlink_victim_state="$(regular_file_state \
  "$work_publication_symlink/.sp11-publication-victim")"
if SP11_KERNEL_RELEASE_PUBLICATION_FIXTURE_HOOK=inject-symlink-before-open \
   run_release_build "$support_publication_symlink" \
     "$work_publication_symlink" \
     > "$temporary_root/publication-symlink.log" 2>&1; then
  die "release publication followed a late symlink output target"
fi
[ -L "$work_publication_symlink/sp11-kernel-debs.txt" ] &&
  [ "$(readlink "$work_publication_symlink/sp11-kernel-debs.txt")" = \
    .sp11-publication-victim ] ||
  die "late symlink target was not retained exactly"
[ "$(regular_file_state \
  "$work_publication_symlink/.sp11-publication-victim")" = \
  "$symlink_victim_state" ] ||
  die "late symlink refusal changed victim metadata or bytes"
[ ! -e "$work_publication_symlink/sp11-kernel-build-manifest.txt" ] ||
  die "late symlink refusal created the second release output"
grep -Fq 'Could not exclusively create the release output names' \
  "$temporary_root/publication-symlink.log" ||
  die "late symlink output refusal was not explicit"
assert_no_publication_success "$temporary_root/publication-symlink.log"

# Linux procfs handoff treats newly opened candidates as unowned until their
# READY inode and exact held-name mappings both verify. A mismatched candidate
# is closed without truncating its unrelated inode; the authenticated opener
# alone scrubs the two intended empty outputs.
if [ "$(uname -s)" = Linux ]; then
  support_publication_procfd="$(clone_support support-publication-procfd)"
  work_publication_procfd="$temporary_root/work-publication-procfd"
  mkdir -p "$work_publication_procfd"
  printf 'candidate victim bytes\n' \
    > "$work_publication_procfd/.sp11-procfd-candidate-victim"
  chmod 0600 "$work_publication_procfd/.sp11-procfd-candidate-victim"
  procfd_victim_state="$(regular_file_state \
    "$work_publication_procfd/.sp11-procfd-candidate-victim")"
  if SP11_KERNEL_RELEASE_PUBLICATION_FIXTURE_HOOK=inject-procfd-candidate-mismatch \
     run_release_build "$support_publication_procfd" \
       "$work_publication_procfd" \
       > "$temporary_root/publication-procfd.log" 2>&1; then
    die "release publication accepted a mismatched procfs candidate FD"
  fi
  grep -Fq 'Held release output ownership could not be verified' \
    "$temporary_root/publication-procfd.log" ||
    die "mismatched procfs candidate refusal was not explicit"
  [ "$(regular_file_state \
    "$work_publication_procfd/.sp11-procfd-candidate-victim")" = \
    "$procfd_victim_state" ] ||
    die "mismatched procfs candidate cleanup changed the victim inode"
  assert_zero_regular "$work_publication_procfd/sp11-kernel-debs.txt"
  assert_zero_regular \
    "$work_publication_procfd/sp11-kernel-build-manifest.txt"
  assert_no_publication_success "$temporary_root/publication-procfd.log"
fi

# A preexisting final name is never deleted or adopted as release output.
support_failure="$(clone_support support-failure)"
work_failure="$temporary_root/work-failure"
mkdir -p "$work_failure"
printf 'stale manifest\n' > "$work_failure/sp11-kernel-build-manifest.txt"
stale_manifest_state="$(
  regular_file_state "$work_failure/sp11-kernel-build-manifest.txt"
)"
if FAIL_BUILD=true run_release_build "$support_failure" "$work_failure" > "$temporary_root/failure.log" 2>&1; then
  die "release build adopted a preexisting final manifest"
fi
[ "$(regular_file_state "$work_failure/sp11-kernel-build-manifest.txt")" = \
  "$stale_manifest_state" ] ||
  die "release refusal changed the preexisting final manifest"
grep -Fq 'Release output already exists; refusing replacement' \
  "$temporary_root/failure.log" ||
  die "preexisting release-output refusal was not explicit"
if grep -Fq 'Wrote completed schema-v2 release build manifest' \
    "$temporary_root/failure.log"; then
  die "preexisting release-output refusal printed a success claim"
fi

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

# A completed work directory cannot be reused, and its exact outputs are
# preserved.  Independently, a copied checkout with ignored prior-build output
# is not a pristine release input even when its new work root has no final names.
support_stale="$(clone_support support-stale)"
work_stale="$temporary_root/work-stale"
if ! run_release_build "$support_stale" "$work_stale" > "$temporary_root/stale-first.log" 2>&1; then
  cat "$temporary_root/stale-first.log" >&2
  die "initial stale-output fixture build failed"
fi
stale_manifest_state="$(
  regular_file_state "$work_stale/sp11-kernel-build-manifest.txt"
)"
stale_deb_list_state="$(regular_file_state "$work_stale/sp11-kernel-debs.txt")"
git -C "$work_stale/source/git-fixture" reset --hard --quiet HEAD
git -C "$work_stale/source/git-fixture" clean -ffd --quiet
if run_release_build "$support_stale" "$work_stale" > "$temporary_root/stale-second.log" 2>&1; then
  die "release build replaced completed outputs in a reused work directory"
fi
[ "$(regular_file_state "$work_stale/sp11-kernel-build-manifest.txt")" = \
  "$stale_manifest_state" ] ||
  die "reused work-directory refusal changed the prior final manifest"
[ "$(regular_file_state "$work_stale/sp11-kernel-debs.txt")" = \
  "$stale_deb_list_state" ] ||
  die "reused work-directory refusal changed the prior package list"
grep -Fq 'Release output already exists; refusing replacement' \
  "$temporary_root/stale-second.log" ||
  die "reused work-directory output refusal was not explicit"
if grep -Fq 'Wrote completed schema-v2 release build manifest' \
    "$temporary_root/stale-second.log"; then
  die "reused work-directory refusal printed a success claim"
fi

support_stale_source="$(clone_support support-stale-source)"
work_stale_source="$temporary_root/work-stale-source"
mkdir -p "$work_stale_source/source"
cp -R "$work_stale/source/git-fixture" \
  "$work_stale_source/source/git-fixture"
if run_release_build "$support_stale_source" "$work_stale_source" \
    > "$temporary_root/stale-source.log" 2>&1; then
  die "release build reused a checkout with ignored prior-build output"
fi
[ ! -e "$work_stale_source/sp11-kernel-build-manifest.txt" ] &&
  [ ! -e "$work_stale_source/sp11-kernel-debs.txt" ] ||
  die "stale source-output refusal produced final release outputs"
grep -Fq 'ignored build outputs or files' "$temporary_root/stale-source.log" ||
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
mkdir -p "$docker_work/artifacts"
chmod 0700 "$docker_work" "$docker_work/artifacts"
if "$support_a/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --source git \
    --git-url "$source_url" \
    --git-branch fixture \
    --expected-source-commit "$source_commit" \
    --image 'ubuntu:26.04' \
    --platform linux/arm64/v8 \
    --patch-dirs patches/release \
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

reserved_control_index=0
for reserved_control_path in /sp11-control /sp11-control/nested; do
  reserved_control_index=$((reserved_control_index + 1))
  if "$support_a/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
      --source git \
      --git-url "$source_url" \
      --git-branch fixture \
      --expected-source-commit "$source_commit" \
      --image "$container_image" \
      --platform linux/arm64/v8 \
      --patch-dirs patches/release \
      --build-target "binary-indep binary-qcom-x1e" \
      --work-dir "$support_a/build/docker-control-overlap-$reserved_control_index" \
      --container-work-dir "$reserved_control_path" \
      --release-build \
      --dry-run > "$temporary_root/docker-control-overlap-$reserved_control_index.log" 2>&1; then
    die "Docker wrapper accepted reserved control mount overlap: $reserved_control_path"
  fi
  grep -Fq 'must not overlap a container control or support-repository mount' \
    "$temporary_root/docker-control-overlap-$reserved_control_index.log" ||
    die "reserved control-mount overlap rejection was not explicit: $reserved_control_path"
done

if ! GIT_DIR="$source_repo/.git" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
    "$support_a/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --source git \
    --git-url "$source_url" \
    --git-branch fixture \
    --expected-source-commit "$source_commit" \
    --image "$container_image" \
    --platform linux/arm64/v8 \
    --patch-dirs patches/release \
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
grep -Fq "SP11_PRIVATE_SUPPORT_SNAPSHOT=true" "$temporary_root/docker-valid.log" ||
  die "wrapper-private support marker was not forwarded"
if grep -Fq "$support_a:/repo:ro" "$temporary_root/docker-valid.log"; then
  die "release Docker command mounted the original live support worktree"
fi
grep -Fq '/sp11-kernel-support.' "$temporary_root/docker-valid.log" ||
  die "release Docker command did not use a private committed support checkout"
grep -Fq "SP11_IMMUTABLE_APT_REQUIRED=true" "$temporary_root/docker-valid.log" ||
  die "release dry-run did not preserve the immutable APT container contract"
grep -Fq ':/sp11-control:ro' "$temporary_root/docker-valid.log" ||
  die "release dry-run did not bind-mount its private control directory"
grep -Fq '/sp11-control/docker-build-inside.sh' "$temporary_root/docker-valid.log" ||
  die "release dry-run did not execute its private read-only entrypoint"
for expected_digest_variable in \
  SP11_EXPECTED_BUILD_ARGS_SHA256 \
  SP11_EXPECTED_ENTRYPOINT_SHA256 \
  SP11_EXPECTED_BASELINE_SHA256; do
  grep -Eq "$expected_digest_variable=[0-9a-f]{64}" \
    "$temporary_root/docker-valid.log" ||
    die "release dry-run omitted private control digest: $expected_digest_variable"
done
for identity_argument in \
    --source-date-epoch "$source_date_epoch" \
    --kbuild-build-user "$kbuild_build_user" \
    --kbuild-build-host "$kbuild_build_host" \
    --kbuild-build-timestamp "$kbuild_build_timestamp"; do
  grep -Fxq -- "$identity_argument" "$docker_work/docker-build-args.txt" ||
    die "Docker release build did not retain identity argument: $identity_argument"
done

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
  local output_dir="$support_dir/build/release/$release_name"
  local -a source_args=(--allow-missing-source)
  if [ -n "$source_asset" ]; then
    source_args+=(--source-asset "$source_asset")
  fi
  mkdir -p "$support_dir/build/release"
  if [ ! -e "$output_dir" ]; then
    mkdir -m 0700 "$output_dir"
  fi
  PATH="$mock_bin:/usr/bin:/bin" \
    FIXTURE_REAL_GIT="$real_git" \
    FIXTURE_REAL_MV="$real_mv" \
    FIXTURE_REAL_RM="$real_rm" \
    FIXTURE_SOURCE_REPO="$source_repo" \
    FIXTURE_PUBLIC_SOURCE_URL="$source_url" \
    FIXTURE_REAL_PYTHON3="$real_python3" \
    SP11_APT_FIXTURE_ROOT="$apt_decoder_root" \
    SP11_APT_HELPER="$apt_decoder_root/mock-bin/apt-helper" \
    SP11_KERNEL_PREPARER_TEST_FIXTURE=sp11-kernel-release-provenance-v1 \
    SP11_KERNEL_PREPARER_FIXTURE_HOOK="${SP11_KERNEL_PREPARER_FIXTURE_HOOK:-}" \
    "$support_dir/scripts/prepare-sp11-kernel-release-assets.sh" \
      --kernel-debs-dir "$kernel_debs_dir" \
      --artifacts-dir "$artifacts_dir" \
      --patch-dir "$support_dir/patches/release" \
      --release-name "$release_name" \
      --out-dir "build/release/$release_name" \
      "${source_args[@]}"
}

if ! run_preparer "$support_a" "$provenance_a/artifacts" fixture-v2 > "$temporary_root/prepare-valid.log" 2>&1; then
  cat "$temporary_root/prepare-valid.log" >&2
  die "valid schema-v2 release preparation failed"
fi
if ! run_preparer "$support_b" "$provenance_b/artifacts" fixture-v2-optional "$work_b/source" \
    > "$temporary_root/prepare-optional.log" 2>&1; then
  cat "$temporary_root/prepare-optional.log" >&2
  die "schema-v2 release preparation rejected a present optional package"
fi
[ "$(directory_permission_mode "$support_a/build/release/fixture-v2")" = 500 ] ||
  die "successful release preparation did not commit its root as mode 0500"
[ "$(directory_permission_mode "$support_b/build/release/fixture-v2-optional")" = 500 ] ||
  die "optional release preparation did not commit its root as mode 0500"

run_preparer_hook_failure() {
  local hook="$1" provenance_work="$2" release_name="$3" log
  log="$temporary_root/$release_name.log"
  if SP11_KERNEL_PREPARER_FIXTURE_HOOK="$hook" \
      run_preparer "$support_a" "$provenance_work/artifacts" "$release_name" \
      > "$log" 2>&1; then
    die "release preparer accepted its terminal hostile fixture"
  fi
  assert_incomplete_preparer_root \
    "$support_a/build/release/$release_name" "$log"
}

run_preparer_hook_failure \
  mutate-release-notes-before-register "$provenance_a" \
  fixture-writer-intent-mutation
writer_mutation_output="$support_a/build/release/fixture-writer-intent-mutation/RELEASE-NOTES.md"
[ -f "$writer_mutation_output" ] &&
  [ "$(od -An -tu1 -N1 "$writer_mutation_output" | tr -d '[:space:]')" = 0 ] ||
  die "writer pre-registration mutation hook did not alter its exact output inode"

run_preparer_hook_failure \
  mutate-output-terminal "$provenance_a" fixture-terminal-output-mutation
terminal_mutation_output="$support_a/build/release/fixture-terminal-output-mutation/RELEASE-NOTES.md"
[ -f "$terminal_mutation_output" ] &&
  [ "$(od -An -tu1 -N1 "$terminal_mutation_output" | tr -d '[:space:]')" = 0 ] ||
  die "terminal output-mutation hook did not reach the held final inode"

for terminal_hook in \
    pending-signal-terminal fail-root-commit signal-before-terminal-exec; do
  release_name="fixture-${terminal_hook}"
  run_preparer_hook_failure "$terminal_hook" "$provenance_a" "$release_name"
  grep -Fxq "fixture: $terminal_hook triggered" \
    "$temporary_root/$release_name.log" || {
      cat "$temporary_root/$release_name.log" >&2
      die "$terminal_hook did not trigger at its exact terminal boundary"
    }
  [ -f "$support_a/build/release/$release_name/SHA256SUMS" ] ||
    die "$terminal_hook did not reach the fully rendered commit fence"
done

incomplete_candidate="$support_a/build/release/fixture-fail-root-commit"
if "$support_a/scripts/validate-sp11-touchscreen-release.sh" \
    --local-prepared-candidate --dir "$incomplete_candidate" \
    > "$temporary_root/incomplete-candidate-validation.log" 2>&1; then
  die "local release validator accepted a complete-looking mode-0700 candidate"
fi
grep -Fq 'not an exact committed mode-0500 root' \
  "$temporary_root/incomplete-candidate-validation.log" ||
  die "local validator did not explain its incomplete-root rejection"

evidence_mutation_work="$temporary_root/evidence-terminal-mutation"
clone_provenance_work "$provenance_a" "$evidence_mutation_work"
run_preparer_hook_failure \
  mutate-evidence-terminal "$evidence_mutation_work" fixture-evidence-mutation
[ "$(od -An -tu1 -N1 "$evidence_mutation_work/sp11-kernel-retained-evidence.tar" | tr -d '[:space:]')" = 0 ] ||
  die "terminal evidence mutation hook did not alter the held evidence inode"

control_mutation_work="$temporary_root/control-terminal-mutation"
clone_provenance_work "$provenance_a" "$control_mutation_work"
run_preparer_hook_failure \
  mutate-control-terminal "$control_mutation_work" fixture-control-mutation
[ "$(od -An -tu1 -N1 "$control_mutation_work/docker-build-args.txt" | tr -d '[:space:]')" = 0 ] ||
  die "terminal control mutation hook did not alter the held companion inode"

work_member_work="$temporary_root/work-member-terminal"
clone_provenance_work "$provenance_a" "$work_member_work"
run_preparer_hook_failure \
  inject-work-member-terminal "$work_member_work" fixture-work-member
[ -f "$work_member_work/.sp11-terminal-injected" ] ||
  die "late work-membership hook did not create its exact tripwire"

artifact_member_work="$temporary_root/artifact-member-terminal"
clone_provenance_work "$provenance_a" "$artifact_member_work"
run_preparer_hook_failure \
  inject-artifact-member-terminal "$artifact_member_work" fixture-artifact-member
[ -f "$artifact_member_work/artifacts/.sp11-terminal-injected" ] ||
  die "late artifact-membership hook did not create its exact tripwire"

output_remap_release=fixture-output-root-remap
output_remap_dir="$support_a/build/release/$output_remap_release"
output_remap_victim="$output_remap_dir.fixture-victim"
mkdir -p "$support_a/build/release"
mkdir -m 0700 "$output_remap_victim"
printf 'output-root victim bytes must survive\n' > "$output_remap_victim/victim.txt"
output_victim_state="$(regular_file_state "$output_remap_victim/victim.txt")"
run_preparer_hook_failure \
  remap-output-root-terminal "$provenance_a" "$output_remap_release"
[ -d "$output_remap_dir.fixture-held" ] &&
  [ "$(regular_file_state "$output_remap_dir/victim.txt")" = "$output_victim_state" ] ||
  die "terminal output-root remap changed or lost the victim authority"

work_remap_source="$temporary_root/work-root-remap"
clone_provenance_work "$provenance_a" "$work_remap_source"
work_remap_victim="$work_remap_source.fixture-victim"
mkdir -m 0700 "$work_remap_victim"
printf 'work-root victim bytes must survive\n' > "$work_remap_victim/victim.txt"
work_victim_state="$(regular_file_state "$work_remap_victim/victim.txt")"
run_preparer_hook_failure \
  remap-work-root-terminal "$work_remap_source" fixture-work-root-remap
[ -d "$work_remap_source.fixture-held" ] &&
  [ "$(regular_file_state "$work_remap_source/victim.txt")" = "$work_victim_state" ] ||
  die "terminal work-root remap changed or lost the victim authority"

artifacts_remap_source="$temporary_root/artifacts-root-remap"
clone_provenance_work "$provenance_a" "$artifacts_remap_source"
artifacts_remap_victim="$artifacts_remap_source.artifacts-victim"
mkdir -m 0700 "$artifacts_remap_victim"
printf 'artifacts-root victim bytes must survive\n' > "$artifacts_remap_victim/victim.txt"
artifacts_victim_state="$(regular_file_state "$artifacts_remap_victim/victim.txt")"
run_preparer_hook_failure \
  remap-artifacts-root-terminal "$artifacts_remap_source" \
  fixture-artifacts-root-remap
[ -d "$artifacts_remap_source.artifacts-held" ] &&
  [ "$(regular_file_state "$artifacts_remap_source/artifacts/victim.txt")" = \
    "$artifacts_victim_state" ] ||
  die "terminal artifacts-root remap changed or lost the victim authority"

preexisting_release=fixture-preexisting-committed-root
preexisting_dir="$support_a/build/release/$preexisting_release"
mkdir -m 0700 "$preexisting_dir"
printf 'preexisting committed root must survive\n' > "$preexisting_dir/victim.txt"
chmod 0500 "$preexisting_dir"
preexisting_state="$(regular_file_state "$preexisting_dir/victim.txt")"
if run_preparer "$support_a" "$provenance_a/artifacts" "$preexisting_release" \
    > "$temporary_root/preexisting-committed-root.log" 2>&1; then
  die "release preparer reused a preexisting mode-0500 root"
fi
[ "$(regular_file_state "$preexisting_dir/victim.txt")" = "$preexisting_state" ] &&
  [ "$(directory_permission_mode "$preexisting_dir")" = 500 ] ||
  die "release preparer changed a preexisting committed-root victim"

if [ "${SP11_PREPARER_PUBLICATION_FOCUSED:-false}" = true ]; then
  printf 'kernel release preparer publication-boundary fixtures passed\n'
  exit 0
fi

provenance_valid="$temporary_root/build-inputs.valid"
provenance_forged="$temporary_root/build-inputs.forged"
cp "$provenance_a/artifacts/sp11-kernel-build-inputs.txt" "$provenance_valid"
sed "s/^Input 1 SHA256: .*/Input 1 SHA256: $(printf '0%.0s' {1..64})/" \
  "$provenance_valid" > "$provenance_forged"
cp "$provenance_forged" "$provenance_a/artifacts/sp11-kernel-build-inputs.txt"
if run_preparer "$support_a" "$provenance_a/artifacts" fixture-provenance-race \
    > "$temporary_root/provenance-race.log" 2>&1; then
  die "kernel release preparer accepted a flat envelope outside retained evidence"
fi
assert_incomplete_preparer_root \
  "$support_a/build/release/fixture-provenance-race" \
  "$temporary_root/provenance-race.log"
grep -Fq 'Retained release-evidence tar validation failed.' \
  "$temporary_root/provenance-race.log" ||
  die "flat-envelope/evidence mismatch rejection was not explicit"
cp "$provenance_valid" "$provenance_a/artifacts/sp11-kernel-build-inputs.txt"
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  if PATH="$mock_bin:/usr/bin:/bin" \
      GIT_DIR="$source_repo/.git" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
      FIXTURE_REAL_GIT="$real_git" \
      FIXTURE_SOURCE_REPO="$source_repo" \
      FIXTURE_PUBLIC_SOURCE_URL="$source_url" \
      FIXTURE_REAL_PYTHON3="$real_python3" \
      "$support_a/scripts/validate-sp11-touchscreen-release.sh" \
        --local-prepared-candidate \
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
if run_preparer "$support_status_failure" "$provenance_a/artifacts" fixture-status-failure \
    > "$temporary_root/status-prepare.log" 2>&1; then
  die "release preparer interpreted a failed support status as clean"
fi
grep -Fq 'Could not inspect the support repository worktree state' "$temporary_root/status-prepare.log" ||
  die "release preparer status failure was not explicit"
release_manifest="$support_a/build/release/fixture-v2/sp11-kernel-release-manifest.txt"
attached_build_manifest="$support_a/build/release/fixture-v2/sp11-kernel-build-manifest.txt"
attached_apt_provenance="$support_a/build/release/fixture-v2/sp11-kernel-apt-provenance.txt"
attached_build_inputs="$support_a/build/release/fixture-v2/sp11-kernel-build-inputs.txt"
release_notes="$support_a/build/release/fixture-v2/RELEASE-NOTES.md"
release_notes_sha="$(shasum -a 256 "$release_notes" | awk '{print $1}')"
[ "$(grep -Fxc 'Experimental prebuilt qcom-x1e kernel packages for Surface Pro 11.' \
    "$release_notes")" = 1 ] ||
  die "kernel release notes duplicated or omitted their opening sentence"
if ! cmp "$manifest_a" "$attached_build_manifest"; then
  cat "$temporary_root/prepare-valid.log" >&2
  find "$support_a/build/release" -mindepth 1 -maxdepth 2 -print >&2 || true
  die "kernel release did not attach the exact validated schema-v2 build manifest"
fi
cmp "$provenance_a/artifacts/sp11-kernel-apt-provenance.txt" "$attached_apt_provenance" ||
  die "kernel release did not attach the exact validated APT sidecar"
cmp "$provenance_a/artifacts/sp11-kernel-build-inputs.txt" "$attached_build_inputs" ||
  die "kernel release did not attach the exact validated build-inputs envelope"
grep -Fq '  sp11-kernel-build-manifest.txt' \
  "$support_a/build/release/fixture-v2/SHA256SUMS" ||
  die "kernel release checksums omitted the schema-v2 build manifest"
grep -Fq '  sp11-kernel-apt-provenance.txt' \
  "$support_a/build/release/fixture-v2/SHA256SUMS" ||
  die "kernel release checksums omitted the APT sidecar"
grep -Fq '  sp11-kernel-build-inputs.txt' \
  "$support_a/build/release/fixture-v2/SHA256SUMS" ||
  die "kernel release checksums omitted the build-inputs envelope"
grep -Fxq 'Kernel release schema: sp11-kernel-release-v1' "$release_manifest" ||
  die "release manifest omitted its outer v1 schema"
grep -Fxq 'Build envelope creation propagation: incomplete' "$release_manifest" ||
  die "release manifest rewrote the build-time envelope state"
grep -Fxq 'Kernel release propagation: complete' "$release_manifest" ||
  die "release manifest omitted its completed kernel propagation attestation"
grep -Fxq 'Publication state: blocked' "$release_manifest" ||
  die "release manifest did not preserve the publication block"
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
    run_preparer "$support_a" "$provenance_a/artifacts" fixture-v2-source "$work_a/source" \
    "$kernel_source_archive" > "$temporary_root/prepare-source.log" 2>&1; then
  cat "$temporary_root/prepare-source.log" >&2
  die "release preparer rejected an exact patched-tree source archive"
fi
[ "$(shasum -a 256 \
    "$support_a/build/release/fixture-v2-source/RELEASE-NOTES.md" | awk '{print $1}')" = \
  "$release_notes_sha" ] ||
  die "equivalent release inputs did not reproduce the exact release-note bytes"
grep -Fq 'NO-PUBLISH:' "$temporary_root/prepare-source.log" ||
  die "validated source preparation did not report the publication stop"
if grep -Fq 'gh release create' "$temporary_root/prepare-source.log"; then
  die "validated source preparation exposed a publication command while gates remain open"
fi

release_source_dir_b="$support_b/build/release-source"
mkdir -p "$release_source_dir_b"
kernel_source_archive_b="$release_source_dir_b/fixture-v2-optional-patched-source.tar.xz"
git -C "$work_b/source/git-fixture" archive \
  --format=tar \
  --prefix=fixture-v2-optional-patched-source/ \
  "$tree_b" |
  xz --threads=1 -6 > "$kernel_source_archive_b"
if ! run_preparer "$support_b" "$provenance_b/artifacts" fixture-v2-optional-source \
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
        --local-prepared-candidate \
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
  local_candidate_state() {
    local release_dir="$1" candidate_path
    printf 'root-mode:%s\n' "$(directory_permission_mode "$release_dir")"
    while IFS= read -r candidate_path; do
      [ -f "$candidate_path" ] && [ ! -L "$candidate_path" ] ||
        die "local candidate fixture contains a non-regular member"
      printf '%s\t%s\n' "${candidate_path##*/}" \
        "$(regular_file_state "$candidate_path")"
    done < <(
      find "$release_dir" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort
    )
  }
  clone_local_candidate() {
    local clone_name="$1" clone_dir candidate_dir
    clone_dir="$(clone_support "$clone_name")"
    mkdir -p "$clone_dir/build/release"
    candidate_dir="$clone_dir/build/release/fixture-v2-source"
    cp -R "$bound_release_dir" "$candidate_dir"
    chmod 0700 "$candidate_dir"
    printf '%s\n' "$clone_dir"
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
  original_candidate_state="$(local_candidate_state "$bound_release_dir")"

  support_extra_candidate="$(clone_local_candidate support-validator-extra)"
  extra_candidate_dir="$support_extra_candidate/build/release/fixture-v2-source"
  printf 'checksummed but not manifest-bound\n' > "$extra_candidate_dir/unexpected.txt"
  rewrite_release_checksums "$extra_candidate_dir"
  chmod 0500 "$extra_candidate_dir"
  git -C "$support_extra_candidate" tag fixture-v2-source
  if validate_schema_v2_dir "$support_extra_candidate" fixture-v2-source \
      validate-flat-v2-extra.log; then
    die "standalone release validator accepted an unexpected checksummed schema-v2 asset"
  fi
  grep -Fq 'schema-v2 release contains an unexpected asset: unexpected.txt' \
    "$temporary_root/validate-flat-v2-extra.log" ||
    die "unexpected schema-v2 asset rejection was not explicit"

  support_duplicate_candidate="$(clone_local_candidate support-validator-duplicate)"
  duplicate_candidate_dir="$support_duplicate_candidate/build/release/fixture-v2-source"
  printf 'Build provenance schema: sp11-kernel-build-v2\n' \
    >> "$duplicate_candidate_dir/sp11-kernel-release-manifest.txt"
  rewrite_release_checksums "$duplicate_candidate_dir"
  chmod 0500 "$duplicate_candidate_dir"
  git -C "$support_duplicate_candidate" tag fixture-v2-source
  if validate_schema_v2_dir "$support_duplicate_candidate" fixture-v2-source \
      validate-flat-v2-schema-duplicate.log; then
    die "standalone release validator accepted an ambiguous schema declaration"
  fi
  grep -Fq 'unsupported or ambiguous Build provenance schema declaration' \
    "$temporary_root/validate-flat-v2-schema-duplicate.log" ||
    die "ambiguous schema rejection was not explicit"

  support_order_candidate="$(clone_local_candidate support-validator-order)"
  order_candidate_dir="$support_order_candidate/build/release/fixture-v2-source"
  awk '
    /^Kernel release schema: / { kernel_schema = $0; next }
    /^Build provenance schema: / { print; print kernel_schema; next }
    { print }
  ' "$bound_release_dir/sp11-kernel-release-manifest.txt" \
    > "$order_candidate_dir/sp11-kernel-release-manifest.txt"
  rewrite_release_checksums "$order_candidate_dir"
  chmod 0500 "$order_candidate_dir"
  git -C "$support_order_candidate" tag fixture-v2-source
  if validate_schema_v2_dir "$support_order_candidate" fixture-v2-source \
      validate-flat-v2-schema-order.log; then
    die "standalone release validator accepted reordered outer v1 fields"
  fi
  grep -Fq 'field order does not match its schema' \
    "$temporary_root/validate-flat-v2-schema-order.log" ||
    die "reordered outer v1 field rejection was not explicit"
  [ "$(local_candidate_state "$bound_release_dir")" = \
    "$original_candidate_state" ] ||
    die "semantic validator fixtures changed the original local candidate"

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
if run_preparer "$support_no_origin" "$provenance_a/artifacts" fixture-v2-no-origin \
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
clone_provenance_work "$provenance_a" "$augmented_artifacts"
cp "$manifest_a" "$augmented_artifacts/artifacts/sp11-kernel-build-manifest.txt"
printf 'Forged extra field: accepted-by-loose-parser\n' \
  >> "$augmented_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$augmented_artifacts"
if run_preparer "$support_a" "$augmented_artifacts/artifacts" fixture-v2-extra-field \
    "$work_a/source" "$kernel_source_archive" \
    > "$temporary_root/prepare-extra-field.log" 2>&1; then
  die "release preparer accepted an extra schema-v2 build-manifest field"
fi
grep -Fq 'Retained release-evidence tar validation failed.' \
  "$temporary_root/prepare-extra-field.log" ||
  die "extra build-manifest field rejection was not explicit"

cp "$manifest_a" "$augmented_artifacts/artifacts/sp11-kernel-build-manifest.txt"
printf 'forged colonless release claim\n' \
  >> "$augmented_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$augmented_artifacts"
if run_preparer "$support_a" "$augmented_artifacts/artifacts" fixture-v2-nonschema \
    "$work_a/source" "$kernel_source_archive" \
    > "$temporary_root/prepare-nonschema.log" 2>&1; then
  die "release preparer accepted a non-schema build-manifest line"
fi
grep -Fq 'Retained release-evidence tar validation failed.' \
  "$temporary_root/prepare-nonschema.log" ||
  die "non-schema build-manifest rejection was not explicit"

toctou_archive="$release_source_dir/fixture-v2-toctou-patched-source.tar.xz"
cp "$support_a/build/release/fixture-v2-source/fixture-v2-patched-source.tar.xz" "$toctou_archive"
mutation_marker="$temporary_root/source-mutated"
toctou_victim="$release_source_dir/fixture-v2-toctou-victim"
printf 'preserve source mutation victim\n' > "$toctou_victim"
toctou_victim_sha="$(shasum -a 256 "$toctou_victim" | awk '{print $1}')"
if MUTATE_SOURCE_BEFORE_VALIDATION=true \
    FIXTURE_SOURCE_ASSET_TO_MUTATE="$toctou_archive" \
    FIXTURE_SOURCE_MUTATION_MARKER="$mutation_marker" \
    run_preparer "$support_a" "$provenance_a/artifacts" fixture-v2-toctou "$work_a/source" \
      "$toctou_archive" > "$temporary_root/prepare-toctou.log" 2>&1; then
  die "release preparer accepted a persistently mutated source input"
fi
[ -e "$mutation_marker" ] || die "source TOCTOU fixture did not mutate the original input"
grep -Fq 'Patched-kernel corresponding-source archive does not match build provenance.' \
  "$temporary_root/prepare-toctou.log" ||
  die "persistent source mutation rejection was not explicit"
toctou_output_root="$support_a/build/release/fixture-v2-toctou"
assert_incomplete_preparer_root "$toctou_output_root" \
  "$temporary_root/prepare-toctou.log"
[ ! -e "$toctou_output_root/$(basename "$toctou_archive")" ] &&
  [ ! -e "$toctou_output_root/SHA256SUMS" ] ||
  die "persistent source mutation left staged or authorized output"
[ "$(cat "$toctou_archive")" = 'tampered before semantic validation' ] ||
  die "persistent source mutation evidence was not retained exactly"
[ "$(shasum -a 256 "$toctou_victim" | awk '{print $1}')" = \
  "$toctou_victim_sha" ] || die "persistent source mutation changed a victim"

expect_prepare_failure() {
  local artifacts_dir="$1" release_name="$2" expected="$3"
  if run_preparer "$support_a" "$artifacts_dir" "$release_name" > "$temporary_root/$release_name.log" 2>&1; then
    die "release preparer accepted invalid provenance for $release_name"
  fi
  grep -Fq "$expected" "$temporary_root/$release_name.log" ||
    die "release preparer did not explain $release_name failure"
}

# Replacement/rollback behavior is intentionally absent from the current
# release contract.  The focused publication block above covers O_EXCL
# refusal, retained mode-0700 failures, and the irreversible mode-0500 commit.

for missing_provenance_name in \
    sp11-kernel-apt-provenance.txt \
    sp11-kernel-build-inputs.txt; do
  missing_provenance_work="$temporary_root/missing-${missing_provenance_name%.txt}"
  clone_provenance_work "$provenance_a" "$missing_provenance_work"
  rm "$missing_provenance_work/artifacts/$missing_provenance_name"
  expect_prepare_failure "$missing_provenance_work/artifacts" \
    "fixture-missing-${missing_provenance_name%.txt}" \
    'regular, non-symlinked immutable provenance input'
done

tampered_sidecar_work="$temporary_root/tampered-sidecar"
clone_provenance_work "$provenance_a" "$tampered_sidecar_work"
sed 's/^Snapshot ID: .*/Snapshot ID: 19700101T000000Z/' \
  "$provenance_a/artifacts/sp11-kernel-apt-provenance.txt" \
  > "$tampered_sidecar_work/artifacts/sp11-kernel-apt-provenance.txt"
expect_prepare_failure "$tampered_sidecar_work/artifacts" \
  fixture-tampered-apt-sidecar \
  'Retained release-evidence tar validation failed.'

extra_envelope_work="$temporary_root/extra-envelope"
clone_provenance_work "$provenance_a" "$extra_envelope_work"
printf 'Forged publication input: accepted-by-loose-parser\n' \
  >> "$extra_envelope_work/artifacts/sp11-kernel-build-inputs.txt"
expect_prepare_failure "$extra_envelope_work/artifacts" \
  fixture-extra-build-envelope \
  'Retained release-evidence tar validation failed.'

legacy_envelope_work="$temporary_root/legacy-envelope"
clone_provenance_work "$provenance_a" "$legacy_envelope_work"
sed 's/^Build inputs schema: .*/Build inputs schema: sp11-kernel-build-inputs-v0/' \
  "$provenance_a/artifacts/sp11-kernel-build-inputs.txt" \
  > "$legacy_envelope_work/artifacts/sp11-kernel-build-inputs.txt"
expect_prepare_failure "$legacy_envelope_work/artifacts" \
  fixture-legacy-build-envelope \
  'Retained release-evidence tar validation failed.'

nonpublic_url_index=0
for nonpublic_url in \
    https://localhost/kernel.git \
    https://192.168.50.10/kernel.git \
    https://kernel/kernel.git \
    https://fixtures.invalid/kernel.git; do
  nonpublic_url_index=$((nonpublic_url_index + 1))
  nonpublic_artifacts="$temporary_root/nonpublic-url-$nonpublic_url_index"
  clone_provenance_work "$provenance_a" "$nonpublic_artifacts"
  sed "s#^Source URL: .*#Source URL: $nonpublic_url#" \
    "$manifest_a" > "$nonpublic_artifacts/artifacts/sp11-kernel-build-manifest.txt"
  refresh_build_manifest_envelope_binding "$nonpublic_artifacts"
  expect_prepare_failure "$nonpublic_artifacts/artifacts" \
    "fixture-nonpublic-url-$nonpublic_url_index" \
    'Retained release-evidence tar validation failed.'
done

cross_validator_artifacts="$temporary_root/cross-validator-private-url"
mkdir "$cross_validator_artifacts"
sed 's#^Source URL: .*#Source URL: https://169.254.10.20/kernel.git#' \
  "$manifest_a" > "$cross_validator_artifacts/sp11-kernel-build-manifest.txt"
support_commit_a="$(manifest_value "$manifest_a" "Support start HEAD")"
if /usr/bin/python3 -I \
    "$support_a/scripts/validate-sp11-image-release-manifests.py" \
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
clone_provenance_work "$provenance_a" "$legacy_artifacts"
sed 's/^Provenance schema: .*/Provenance schema: sp11-kernel-build-v1/' \
  "$manifest_a" > "$legacy_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$legacy_artifacts"
expect_prepare_failure "$legacy_artifacts/artifacts" fixture-v1 \
  'Retained release-evidence tar validation failed.'

nonrelease_artifacts="$temporary_root/nonrelease-artifacts"
clone_provenance_work "$provenance_a" "$nonrelease_artifacts"
sed 's/^Release build: true$/Release build: false/' \
  "$manifest_a" > "$nonrelease_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$nonrelease_artifacts"
expect_prepare_failure "$nonrelease_artifacts/artifacts" fixture-nonrelease \
  'Retained release-evidence tar validation failed.'

incomplete_artifacts="$temporary_root/incomplete-artifacts"
clone_provenance_work "$provenance_a" "$incomplete_artifacts"
sed '/^Build completed: true$/d' \
  "$manifest_a" > "$incomplete_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$incomplete_artifacts"
expect_prepare_failure "$incomplete_artifacts/artifacts" fixture-incomplete \
  'Retained release-evidence tar validation failed.'

bad_patch_artifacts="$temporary_root/bad-patch-artifacts"
clone_provenance_work "$provenance_a" "$bad_patch_artifacts"
sed "s/^Patch 1 SHA256: .*/Patch 1 SHA256: $(printf '0%.0s' {1..64})/" \
  "$manifest_a" > "$bad_patch_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$bad_patch_artifacts"
expect_prepare_failure "$bad_patch_artifacts/artifacts" fixture-bad-patch \
  'Retained release-evidence tar validation failed.'

image_deb="$work_a/source/linux-image-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb"
cp "$image_deb" "$temporary_root/image.deb.backup"
printf 'tampered\n' >> "$image_deb"
expect_prepare_failure "$provenance_a/artifacts" fixture-tampered-deb 'does not match its build provenance'
mv "$temporary_root/image.deb.backup" "$image_deb"

"$repo_dir/tests/test-source-archive-bindings.sh"
"$repo_dir/tests/test-touchscreen-module-source-provenance.sh"
printf 'Kernel release provenance fixtures passed.\n'
