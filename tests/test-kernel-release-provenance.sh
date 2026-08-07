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
cp "$repo_dir/scripts/sp11-kernel-build-inputs.py" "$support_seed/scripts/"
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
if [ "${FAIL_FINAL_SUPPORT_STATE:-false}" = "true" ] &&
   [ "${1:-}" = "status" ] &&
   [ -f "$FIXTURE_FINAL_OUT_DIR/sp11-kernel-release-manifest.txt" ]; then
  if [ "${MUTATE_RETAINED_PREVIOUS:-false}" = "true" ]; then
    previous_original="$(find "$(dirname "$FIXTURE_FINAL_OUT_DIR")" \
      -mindepth 2 -maxdepth 2 -type d \
      -path "*/.${FIXTURE_PREVIOUS_RELEASE_NAME}.previous.*/original" \
      -print | sed -n '1p')"
    [ -n "$previous_original" ]
    printf 'unknown concurrent previous-output bytes\n' \
      > "$previous_original/concurrent-unknown.txt"
    : > "$FIXTURE_PREVIOUS_MUTATION_MARKER"
  fi
  : > "$FIXTURE_FINAL_SUPPORT_FAILURE_MARKER"
  exit 88
fi
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

cat > "$mock_bin/mv" <<'EOF_MV'
#!/usr/bin/env bash
set -euo pipefail
real_mv="${FIXTURE_REAL_MV:-/bin/mv}"
if [ "${MUTATE_STAGING_AT_INSTALL:-false}" = "true" ] &&
   [ "$#" -eq 2 ] &&
   [[ "$(basename "$1")" == .*\.staging.* ]] &&
   [ "$2" = "$FIXTURE_FINAL_OUT_DIR" ]; then
  target="$1/sp11-kernel-build-inputs.txt"
  printf 'Forged post-validation field: rejected\n' >> "$target"
  digest="$(shasum -a 256 "$target" | awk '{print $1}')"
  awk -v digest="$digest" '
    $2 == "sp11-kernel-build-inputs.txt" {
      print digest "  sp11-kernel-build-inputs.txt"
      next
    }
    { print }
  ' "$1/SHA256SUMS" > "$1/.SHA256SUMS.mutated"
  "$real_mv" "$1/.SHA256SUMS.mutated" "$1/SHA256SUMS"
  : > "$FIXTURE_STAGING_MUTATION_MARKER"
fi
if [ "${MUTATE_FAILED_CANDIDATE_BEFORE_RETIREMENT:-false}" = "true" ] &&
   [ "$#" -eq 2 ] && [ "$(basename "$1")" = "original" ] &&
   [ "$2" = "$FIXTURE_FINAL_OUT_DIR" ]; then
  failed_candidate="$(find "$(dirname "$FIXTURE_FINAL_OUT_DIR")" \
    -mindepth 2 -maxdepth 2 -type d \
    -path "*/.${FIXTURE_RETIREMENT_RELEASE_NAME}.failed.*/candidate" \
    -print | sed -n '1p')"
  [ -n "$failed_candidate" ]
  printf 'unknown concurrent failed-candidate bytes\n' \
    > "$failed_candidate/concurrent-unknown.txt"
  : > "$FIXTURE_FAILED_CANDIDATE_MUTATION_MARKER"
fi
exec "$real_mv" "$@"
EOF_MV

cat > "$mock_bin/rm" <<'EOF_RM'
#!/usr/bin/env bash
set -euo pipefail
real_rm="${FIXTURE_REAL_RM:-/bin/rm}"
if [ "${FAIL_PREVIOUS_OUTPUT_CLEANUP:-false}" = "true" ]; then
  for argument in "$@"; do
    case "$(basename "$(dirname "$argument")")/$(basename "$argument")" in
      ".${FIXTURE_CLEANUP_RELEASE_NAME}.previous."*/original)
        : > "$FIXTURE_PREVIOUS_CLEANUP_FAILURE_MARKER"
        exit 89
        ;;
    esac
  done
fi
exec "$real_rm" "$@"
EOF_RM

cat > "$mock_bin/fakeroot" <<'EOF_FAKEROOT'
#!/usr/bin/env bash
exec "$@"
EOF_FAKEROOT

cat > "$mock_bin/python3" <<'EOF_PYTHON3'
#!/usr/bin/env bash
set -euo pipefail
if [ "${SWAP_PROVENANCE_DURING_RELEASE_VALIDATION:-false}" = "true" ] &&
  [[ "$*" == *"sp11-kernel-build-inputs.py validate-release-snapshot --baseline"* ]] &&
  [ ! -e "$FIXTURE_PROVENANCE_MUTATION_MARKER" ]; then
  cp "$FIXTURE_VALID_PROVENANCE" "$FIXTURE_PROVENANCE_TO_MUTATE"
  set +e
  "$FIXTURE_REAL_PYTHON3" "$@"
  validation_status=$?
  set -e
  cp "$FIXTURE_FORGED_PROVENANCE" "$FIXTURE_PROVENANCE_TO_MUTATE"
  : > "$FIXTURE_PROVENANCE_MUTATION_MARKER"
  exit "$validation_status"
fi
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
    FIXTURE_REAL_MV="$real_mv" \
    FIXTURE_REAL_RM="$real_rm" \
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

make_provenance_work() {
  local support_dir="$1" build_work="$2" provenance_work="$3"
  local support_head deb

  [ ! -e "$provenance_work" ] || die "provenance fixture work already exists: $provenance_work"
  mkdir -p "$provenance_work"
  cp -R "$apt_template/." "$provenance_work/"
  cp "$build_work/sp11-kernel-build-manifest.txt" \
    "$provenance_work/artifacts/sp11-kernel-build-manifest.txt"
  while IFS= read -r deb; do
    cp "$deb" "$provenance_work/artifacts/"
  done < <(find "$build_work/source" -maxdepth 1 -type f -name '*.deb' | LC_ALL=C sort)
  support_head="$(git -C "$support_dir" rev-parse 'HEAD^{commit}')"
  python3 "$support_dir/scripts/sp11-kernel-build-inputs.py" write \
    --baseline "$support_dir/config/kernel-baselines/7.2-rc5-jg-0.env" \
    --work-dir "$provenance_work" \
    --support-head "$support_head" \
    --build-args "$provenance_work/docker-build-args.txt" \
    --entrypoint "$provenance_work/docker-build-inside.sh" \
    --oci-index "$provenance_work/sp11-oci-index.json" \
    --build-manifest "$provenance_work/artifacts/sp11-kernel-build-manifest.txt" \
    --apt-provenance "$provenance_work/artifacts/sp11-kernel-apt-provenance.txt" \
    --apt-archives-dir "$provenance_work/apt-archives" \
    --apt-lists-dir "$provenance_work/apt-lists" \
    --apt-index-cache-dir "$provenance_work/apt-indexes" \
    --apt-local-build-deps-dir "$provenance_work/artifacts" \
    --apt-pre-inventory "$provenance_work/sp11-apt-installed-pre.txt" \
    --apt-post-inventory "$provenance_work/sp11-apt-installed-post.txt" \
    --output "$provenance_work/artifacts/sp11-kernel-build-inputs.txt" \
    >/dev/null
}

clone_provenance_work() {
  local source_work="$1" destination_work="$2"
  [ ! -e "$destination_work" ] || die "cloned provenance work already exists: $destination_work"
  mkdir -p "$destination_work"
  cp -R "$source_work/." "$destination_work/"
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
    FIXTURE_REAL_MV="$real_mv" \
    FIXTURE_REAL_RM="$real_rm" \
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

if ! run_preparer "$support_a" "$provenance_a/artifacts" fixture-v2 > "$temporary_root/prepare-valid.log" 2>&1; then
  cat "$temporary_root/prepare-valid.log" >&2
  die "valid schema-v2 release preparation failed"
fi
if ! run_preparer "$support_b" "$provenance_b/artifacts" fixture-v2-optional "$work_b/source" \
    > "$temporary_root/prepare-optional.log" 2>&1; then
  cat "$temporary_root/prepare-optional.log" >&2
  die "schema-v2 release preparation rejected a present optional package"
fi

provenance_valid="$temporary_root/build-inputs.valid"
provenance_forged="$temporary_root/build-inputs.forged"
cp "$provenance_a/artifacts/sp11-kernel-build-inputs.txt" "$provenance_valid"
sed "s/^Input 1 SHA256: .*/Input 1 SHA256: $(printf '0%.0s' {1..64})/" \
  "$provenance_valid" > "$provenance_forged"
cp "$provenance_forged" "$provenance_a/artifacts/sp11-kernel-build-inputs.txt"
provenance_mutation_marker="$temporary_root/provenance-mutated"
if SWAP_PROVENANCE_DURING_RELEASE_VALIDATION=true \
    FIXTURE_PROVENANCE_TO_MUTATE="$provenance_a/artifacts/sp11-kernel-build-inputs.txt" \
    FIXTURE_VALID_PROVENANCE="$provenance_valid" \
    FIXTURE_FORGED_PROVENANCE="$provenance_forged" \
    FIXTURE_PROVENANCE_MUTATION_MARKER="$provenance_mutation_marker" \
    run_preparer "$support_a" "$provenance_a/artifacts" fixture-provenance-race \
      > "$temporary_root/provenance-race.log" 2>&1; then
  die "kernel release preparer accepted an A/B/A envelope swap around retained validation"
fi
[ -e "$provenance_mutation_marker" ] ||
  die "provenance validation-race fixture did not mutate its target"
grep -Fq 'release-snapshot hash mismatch at input 1' \
  "$temporary_root/provenance-race.log" ||
  die "A/B/A provenance swap rejection was not explicit"
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

  awk '
    /^Kernel release schema: / { kernel_schema = $0; next }
    /^Build provenance schema: / { print; print kernel_schema; next }
    { print }
  ' "$temporary_root/kernel-release-manifest.original" \
    > "$bound_release_dir/sp11-kernel-release-manifest.txt"
  rewrite_release_checksums "$bound_release_dir"
  if validate_schema_v2_dir "$support_a" fixture-v2-source \
      validate-flat-v2-schema-order.log; then
    die "standalone release validator accepted reordered outer v1 fields"
  fi
  grep -Fq 'field order does not match its schema' \
    "$temporary_root/validate-flat-v2-schema-order.log" ||
    die "reordered outer v1 field rejection was not explicit"
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
grep -Fq 'unexpected top-level field' "$temporary_root/prepare-extra-field.log" ||
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
grep -Fq 'contains a non-schema line' "$temporary_root/prepare-nonschema.log" ||
  die "non-schema build-manifest rejection was not explicit"

toctou_archive="$release_source_dir/fixture-v2-toctou-patched-source.tar.xz"
cp "$support_a/build/release/fixture-v2-source/fixture-v2-patched-source.tar.xz" "$toctou_archive"
mutation_marker="$temporary_root/source-mutated"
if ! MUTATE_SOURCE_AFTER_SNAPSHOT=true \
    FIXTURE_SOURCE_ASSET_TO_MUTATE="$toctou_archive" \
    FIXTURE_SOURCE_MUTATION_MARKER="$mutation_marker" \
    run_preparer "$support_a" "$provenance_a/artifacts" fixture-v2-toctou "$work_a/source" \
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

assert_previous_output_restored() {
  local release_name="$1" expected_failed_recovery="${2:-false}" final_dir
  local expected_recovery_path="${3:-}" entry_count
  local failed_recovery_dir

  final_dir="$support_a/build/release/$release_name"

  [ -f "$final_dir/previous-output-sentinel.txt" ] ||
    die "failed $release_name transaction did not restore its previous output"
  grep -Fxq 'previous output must survive' "$final_dir/previous-output-sentinel.txt" ||
    die "failed $release_name transaction changed its previous output"
  entry_count="$(find "$final_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')"
  [ "$entry_count" = 1 ] ||
    die "failed $release_name transaction nested or mixed candidate and previous output"
  if find "$support_a/build/release" -mindepth 1 -maxdepth 1 \
      \( -name ".$release_name.staging.*" -o -name ".$release_name.previous.*" \) \
      -print | grep -q .; then
    die "failed $release_name transaction retained a staging or previous directory"
  fi
  failed_recovery_dir="$(find "$support_a/build/release" -mindepth 1 -maxdepth 1 \
    -type d -name ".$release_name.failed.*" -print | sed -n '1p')"
  if [ "$expected_failed_recovery" = "true" ]; then
    [ -n "$failed_recovery_dir" ] ||
      die "changed failed candidate was not preserved as recovery data"
    if [ -n "$expected_recovery_path" ]; then
      [ -f "$failed_recovery_dir/candidate/$expected_recovery_path" ] ||
        die "concurrently changed failed candidate was not preserved"
    else
      grep -Fq 'Forged post-validation field: rejected' \
        "$failed_recovery_dir/candidate/sp11-kernel-build-inputs.txt" ||
        die "changed failed candidate was not preserved as recovery data"
    fi
    "$real_rm" -rf -- "$failed_recovery_dir"
  elif [ -n "$failed_recovery_dir" ]; then
    die "unchanged failed candidate was not retired after rollback"
  fi
}

post_install_mutation_release=fixture-post-install-mutation
post_install_mutation_dir="$support_a/build/release/$post_install_mutation_release"
mkdir "$post_install_mutation_dir"
printf 'previous output must survive\n' \
  > "$post_install_mutation_dir/previous-output-sentinel.txt"
post_install_mutation_marker="$temporary_root/post-install-mutated"
if MUTATE_STAGING_AT_INSTALL=true \
    FIXTURE_FINAL_OUT_DIR="$post_install_mutation_dir" \
    FIXTURE_STAGING_MUTATION_MARKER="$post_install_mutation_marker" \
    run_preparer "$support_a" "$provenance_a/artifacts" \
      "$post_install_mutation_release" \
      > "$temporary_root/post-install-mutation.log" 2>&1; then
  die "release preparer accepted post-validation mutation plus checksum rewrite"
fi
[ -e "$post_install_mutation_marker" ] ||
  die "post-install mutation fixture did not mutate the staged candidate"
grep -Eq 'independently captured bytes|SHA256SUMS bytes or row order changed' \
  "$temporary_root/post-install-mutation.log" ||
  die "post-install mutation rejection was not explicit"
grep -Fq 'preserving changed failed release output for recovery' \
  "$temporary_root/post-install-mutation.log" || {
    cat "$temporary_root/post-install-mutation.log" >&2
    die "changed failed-candidate preservation was not explicit"
  }
assert_previous_output_restored "$post_install_mutation_release" true

late_support_release=fixture-late-support-failure
late_support_dir="$support_a/build/release/$late_support_release"
mkdir "$late_support_dir"
printf 'previous output must survive\n' \
  > "$late_support_dir/previous-output-sentinel.txt"
late_support_marker="$temporary_root/late-support-failed"
failed_candidate_mutation_marker="$temporary_root/failed-candidate-mutated"
if FAIL_FINAL_SUPPORT_STATE=true MUTATE_FAILED_CANDIDATE_BEFORE_RETIREMENT=true \
    FIXTURE_FINAL_OUT_DIR="$late_support_dir" \
    FIXTURE_FINAL_SUPPORT_FAILURE_MARKER="$late_support_marker" \
    FIXTURE_RETIREMENT_RELEASE_NAME="$late_support_release" \
    FIXTURE_FAILED_CANDIDATE_MUTATION_MARKER="$failed_candidate_mutation_marker" \
    run_preparer "$support_a" "$provenance_a/artifacts" "$late_support_release" \
      > "$temporary_root/late-support-failure.log" 2>&1; then
  die "release preparer accepted a late support-state inspection failure"
fi
[ -e "$late_support_marker" ] ||
  die "late support-state fixture did not reach the post-install check"
[ -e "$failed_candidate_mutation_marker" ] ||
  die "failed-candidate retirement fixture did not mutate after the first exact check"
grep -Fq 'Could not re-inspect the support repository worktree state' \
  "$temporary_root/late-support-failure.log" ||
  die "late support-state rejection was not explicit"
grep -Fq 'preserving changed failed release output for recovery' \
  "$temporary_root/late-support-failure.log" ||
  die "failed-candidate retirement mutation preservation was not explicit"
assert_previous_output_restored "$late_support_release" true concurrent-unknown.txt

previous_mutation_release=fixture-previous-output-mutation
previous_mutation_dir="$support_a/build/release/$previous_mutation_release"
mkdir "$previous_mutation_dir"
printf 'previous output must survive\n' \
  > "$previous_mutation_dir/previous-output-sentinel.txt"
previous_mutation_marker="$temporary_root/previous-output-mutated"
previous_mutation_support_marker="$temporary_root/previous-output-support-failed"
if FAIL_FINAL_SUPPORT_STATE=true MUTATE_RETAINED_PREVIOUS=true \
    FIXTURE_FINAL_OUT_DIR="$previous_mutation_dir" \
    FIXTURE_FINAL_SUPPORT_FAILURE_MARKER="$previous_mutation_support_marker" \
    FIXTURE_PREVIOUS_RELEASE_NAME="$previous_mutation_release" \
    FIXTURE_PREVIOUS_MUTATION_MARKER="$previous_mutation_marker" \
    run_preparer "$support_a" "$provenance_a/artifacts" "$previous_mutation_release" \
      > "$temporary_root/previous-output-mutation.log" 2>&1; then
  die "release preparer accepted mutation of privately retained previous output"
fi
[ -e "$previous_mutation_marker" ] ||
  die "previous-output mutation fixture did not change the private backup"
[ ! -e "$previous_mutation_dir" ] ||
  die "release preparer restored a changed previous output as authoritative"
grep -Fq 'preserving changed previous release output for recovery' \
  "$temporary_root/previous-output-mutation.log" ||
  die "changed previous-output preservation was not explicit"
previous_mutation_recovery="$(find "$support_a/build/release" -mindepth 1 -maxdepth 1 \
  -type d -name ".$previous_mutation_release.previous.*" -print | sed -n '1p')"
[ -n "$previous_mutation_recovery" ] &&
  [ -f "$previous_mutation_recovery/original/previous-output-sentinel.txt" ] &&
  [ -f "$previous_mutation_recovery/original/concurrent-unknown.txt" ] ||
  die "changed previous-output recovery did not preserve every observed byte"
previous_candidate_recovery="$(find "$support_a/build/release" -mindepth 1 -maxdepth 1 \
  -type d -name ".$previous_mutation_release.failed.*" -print | sed -n '1p')"
[ -n "$previous_candidate_recovery" ] &&
  [ -f "$previous_candidate_recovery/candidate/sp11-kernel-release-manifest.txt" ] ||
  die "failed candidate was not preserved when previous-output restore was unsafe"
"$real_rm" -rf -- "$previous_mutation_recovery" "$previous_candidate_recovery"

cleanup_failure_release=fixture-previous-cleanup-failure
cleanup_failure_dir="$support_a/build/release/$cleanup_failure_release"
mkdir "$cleanup_failure_dir"
printf 'previous output must survive\n' \
  > "$cleanup_failure_dir/previous-output-sentinel.txt"
cleanup_failure_marker="$temporary_root/previous-cleanup-failed"
if FAIL_PREVIOUS_OUTPUT_CLEANUP=true \
    FIXTURE_CLEANUP_RELEASE_NAME="$cleanup_failure_release" \
    FIXTURE_PREVIOUS_CLEANUP_FAILURE_MARKER="$cleanup_failure_marker" \
    run_preparer "$support_a" "$provenance_a/artifacts" "$cleanup_failure_release" \
      > "$temporary_root/previous-cleanup-failure.log" 2>&1; then
  die "release preparer hid a committed-candidate cleanup failure"
fi
[ -e "$cleanup_failure_marker" ] ||
  die "previous-output cleanup failure fixture did not reach retirement"
[ -f "$cleanup_failure_dir/sp11-kernel-release-manifest.txt" ] ||
  die "cleanup failure rolled back the fully verified committed candidate"
[ ! -e "$cleanup_failure_dir/previous-output-sentinel.txt" ] ||
  die "cleanup failure nested the previous output inside the committed candidate"
grep -Fq 'new release output is committed' \
  "$temporary_root/previous-cleanup-failure.log" ||
  die "committed-candidate cleanup failure was not explicit"
cleanup_recovery_dir="$(find "$support_a/build/release" -mindepth 1 -maxdepth 1 \
  -type d -name ".$cleanup_failure_release.previous.*" -print | sed -n '1p')"
[ -n "$cleanup_recovery_dir" ] &&
  [ -f "$cleanup_recovery_dir/original/previous-output-sentinel.txt" ] &&
  [ -f "$cleanup_recovery_dir/tree-state.json" ] ||
  die "cleanup failure did not preserve the previous output as recovery data"
"$real_rm" -rf -- "$cleanup_recovery_dir"

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
  'APT sidecar Snapshot ID does not match the baseline'

extra_envelope_work="$temporary_root/extra-envelope"
clone_provenance_work "$provenance_a" "$extra_envelope_work"
printf 'Forged publication input: accepted-by-loose-parser\n' \
  >> "$extra_envelope_work/artifacts/sp11-kernel-build-inputs.txt"
expect_prepare_failure "$extra_envelope_work/artifacts" \
  fixture-extra-build-envelope \
  'build-inputs envelope field set/order mismatch'

legacy_envelope_work="$temporary_root/legacy-envelope"
clone_provenance_work "$provenance_a" "$legacy_envelope_work"
sed 's/^Build inputs schema: .*/Build inputs schema: sp11-kernel-build-inputs-v0/' \
  "$provenance_a/artifacts/sp11-kernel-build-inputs.txt" \
  > "$legacy_envelope_work/artifacts/sp11-kernel-build-inputs.txt"
expect_prepare_failure "$legacy_envelope_work/artifacts" \
  fixture-legacy-build-envelope \
  'unsupported build-inputs schema'

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
    'build source URL is not credential-free public HTTPS'
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
clone_provenance_work "$provenance_a" "$legacy_artifacts"
sed 's/^Provenance schema: .*/Provenance schema: sp11-kernel-build-v1/' \
  "$manifest_a" > "$legacy_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$legacy_artifacts"
expect_prepare_failure "$legacy_artifacts/artifacts" fixture-v1 'wrong build schema'

nonrelease_artifacts="$temporary_root/nonrelease-artifacts"
clone_provenance_work "$provenance_a" "$nonrelease_artifacts"
sed 's/^Release build: true$/Release build: false/' \
  "$manifest_a" > "$nonrelease_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$nonrelease_artifacts"
expect_prepare_failure "$nonrelease_artifacts/artifacts" fixture-nonrelease 'build manifest is not a release build'

incomplete_artifacts="$temporary_root/incomplete-artifacts"
clone_provenance_work "$provenance_a" "$incomplete_artifacts"
sed '/^Build completed: true$/d' \
  "$manifest_a" > "$incomplete_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$incomplete_artifacts"
expect_prepare_failure "$incomplete_artifacts/artifacts" fixture-incomplete 'is missing required top-level field: Build completed'

bad_patch_artifacts="$temporary_root/bad-patch-artifacts"
clone_provenance_work "$provenance_a" "$bad_patch_artifacts"
sed "s/^Patch 1 SHA256: .*/Patch 1 SHA256: $(printf '0%.0s' {1..64})/" \
  "$manifest_a" > "$bad_patch_artifacts/artifacts/sp11-kernel-build-manifest.txt"
refresh_build_manifest_envelope_binding "$bad_patch_artifacts"
expect_prepare_failure "$bad_patch_artifacts/artifacts" fixture-bad-patch 'does not match the committed support patch'

image_deb="$work_a/source/linux-image-7.2.0-1-qcom-x1e_7.2.0-1_arm64.deb"
cp "$image_deb" "$temporary_root/image.deb.backup"
printf 'tampered\n' >> "$image_deb"
expect_prepare_failure "$provenance_a/artifacts" fixture-tampered-deb 'does not match its build provenance'
mv "$temporary_root/image.deb.backup" "$image_deb"

"$repo_dir/tests/test-source-archive-bindings.sh"
"$repo_dir/tests/test-touchscreen-module-source-provenance.sh"
printf 'Kernel release provenance fixtures passed.\n'
