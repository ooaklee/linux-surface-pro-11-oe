#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
builder="$repo_dir/scripts/build-sp11-touchscreen-modules.sh"
temporary_root=""
temporary_parent=""
managed_root=""
output_fixture_root=""
output_contract_root=""
output_contract_created="false"

cleanup() {
  if [ -n "$managed_root" ]; then
    case "$managed_root" in
      "$repo_dir/build"/sp11-touch-source-test.*) rm -rf -- "$managed_root" ;;
      *) echo "warning: refusing to remove unexpected managed fixture path: $managed_root" >&2 ;;
    esac
  fi
  if [ -n "$output_fixture_root" ]; then
    case "$output_fixture_root" in
      "$repo_dir/build/sp11-touchscreen-module-output"/sp11-touch-source-test.*)
        rm -rf -- "$output_fixture_root"
        ;;
      *) echo "warning: refusing to remove unexpected output fixture path: $output_fixture_root" >&2 ;;
    esac
  fi
  if [ "$output_contract_created" = "true" ] && [ -n "$output_contract_root" ]; then
    rmdir "$output_contract_root" 2>/dev/null || true
  fi
  if [ -n "$temporary_root" ]; then
    case "$temporary_root" in
      "$temporary_parent"/sp11-touch-source-test.*) rm -rf -- "$temporary_root" ;;
      *) echo "warning: refusing to remove unexpected fixture path: $temporary_root" >&2 ;;
    esac
  fi
}
trap cleanup EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

for tool in git mkfifo mktemp python3 shasum stat; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

fixture_mode() {
  local mode
  if mode="$(stat -c '%a' -- "$1" 2>/dev/null)"; then
    :
  elif mode="$(stat -f '%Lp' "$1" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  printf '%s\n' "$mode"
}

temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root="$(mktemp -d "$temporary_parent/sp11-touch-source-test.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
mkdir -p "$repo_dir/build"
[ -d "$repo_dir/build" ] && [ ! -L "$repo_dir/build" ] ||
  die "repository build fixture root is unsafe"
managed_root="$repo_dir/build/sp11-touch-source-test.$$"
output_contract_root="$repo_dir/build/sp11-touchscreen-module-output"
if [ -e "$output_contract_root" ] || [ -L "$output_contract_root" ]; then
  [ -d "$output_contract_root" ] && [ ! -L "$output_contract_root" ] ||
    die "module output contract fixture root is unsafe"
else
  mkdir "$output_contract_root"
  output_contract_created="true"
fi
output_fixture_root="$output_contract_root/sp11-touch-source-test.$$"
mkdir "$managed_root" "$output_fixture_root"
source_seed="$temporary_root/source-seed"
kernel_build="$temporary_root/kernel-build"
header_seed="$temporary_root/header-seed"
mock_bin="$temporary_root/mock-bin"
mkdir -p \
  "$source_seed/phase55/modules" \
  "$kernel_build/include/config" \
  "$kernel_build/include/linux" \
  "$header_seed/include/config" \
  "$header_seed/include/linux" \
  "$mock_bin"

printf '*.o\n*.ko\n*.cmd\nModule.symvers\n' > "$source_seed/.gitignore"
printf 'fixture licence\n' > "$source_seed/LICENSE"
printf 'obj-m += fixture.o\n' > "$source_seed/phase55/modules/Makefile"
printf 'int fixture(void) { return 0; }\n' > "$source_seed/phase55/modules/fixture.c"
git -C "$source_seed" init --quiet --initial-branch=fixture
git -C "$source_seed" config user.name 'SP11 source fixture'
git -C "$source_seed" config user.email 'sp11-source@example.invalid'
git -C "$source_seed" add .
git -C "$source_seed" commit --quiet -m 'Create touchscreen source fixture'
source_commit="$(git -C "$source_seed" rev-parse 'HEAD^{commit}')"

release="7.2-fixture-sp11v3-qcom-x1e"
printf '%s\n' "$release" > "$kernel_build/include/config/kernel.release"
printf 'fixture symbols\n' > "$kernel_build/Module.symvers"
printf '%s\n' \
  'CONFIG_MODULES=y' \
  'CONFIG_QCOM_GPI_DMA=m' \
  'CONFIG_SPI_QCOM_GENI=m' \
  > "$kernel_build/.config"
printf 'mutated arbitrary local header\n' > "$kernel_build/include/linux/fixture.h"
cp "$kernel_build/include/config/kernel.release" "$header_seed/include/config/kernel.release"
cp "$kernel_build/Module.symvers" "$header_seed/Module.symvers"
cp "$kernel_build/.config" "$header_seed/.config"
printf 'pristine header from exact Debs\n' > "$header_seed/include/linux/fixture.h"
common_headers_deb="$temporary_root/linux-qcom-x1e-headers-7.2-fixture-sp11v3_1_all.deb"
architecture_headers_deb="$temporary_root/linux-headers-${release}_1_arm64.deb"
printf 'common headers fixture\n' > "$common_headers_deb"
printf 'architecture headers fixture\n' > "$architecture_headers_deb"

real_uname="$(command -v uname)"
real_id="$(command -v id)"
real_install="$(command -v install)"
real_python3="$(command -v python3)"
cat > "$mock_bin/uname" <<'EOF_UNAME'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
  printf '%s\n' aarch64
else
  exec "$FIXTURE_REAL_UNAME" "$@"
fi
EOF_UNAME
cat > "$mock_bin/modinfo" <<'EOF_MODINFO'
#!/usr/bin/env bash
if [ "${1:-}" = "-p" ]; then
  [ "$(basename "${2:-}")" = "spi-geni-qcom.ko" ] || exit 98
  printf '%s\n' 'sp11_windows_se_init:fixture parameter'
  exit 0
fi
[ "${1:-}" = "-F" ] && [ "$#" -eq 3 ] || exit 99
field="$2"
base="$(basename "$3")"
case "$3" in
  */.sp11-touchscreen-stage.*/*)
    if [ "${FIXTURE_BAD_STAGED_MODULE:-}" = "$base" ] && [ "$field" = "name" ]; then
      printf '%s\n' wrong_staged_identity
      exit 0
    fi
    ;;
esac
case "$field:$base" in
  name:gpi.ko) printf '%s\n' gpi ;;
  name:spi-geni-qcom.ko) printf '%s\n' spi_geni_qcom ;;
  name:mshw0485_touch.ko) printf '%s\n' mshw0485_touch ;;
  vermagic:*.ko) printf '%s SMP fixture\n' "$FIXTURE_RELEASE" ;;
  srcversion:gpi.ko) printf '%s\n' A1 ;;
  srcversion:spi-geni-qcom.ko) printf '%s\n' B2 ;;
  srcversion:mshw0485_touch.ko) printf '%s\n' C3 ;;
  alias:mshw0485_touch.ko) printf '%s\n' 'of:N*T*Cmicrosoft,mshw0485' ;;
  alias:*.ko) ;;
  *) exit 97 ;;
esac
EOF_MODINFO
cat > "$mock_bin/make" <<'EOF_MAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'GNU Make fixture 1.0'
  exit 0
fi
kernel_build_dir=""
for argument in "$@"; do
  case "$argument" in
    KDIR=*) kernel_build_dir="${argument#KDIR=}" ;;
  esac
done
printf '%s\n' "$kernel_build_dir" > "$FIXTURE_MAKE_MARKER"
if [ "${FIXTURE_VERIFY_PRISTINE_HEADERS:-false}" = "true" ]; then
  [ "$kernel_build_dir" != "$FIXTURE_MUTATED_KERNEL_BUILD" ] || exit 97
  grep -qx 'pristine header from exact Debs' \
    "$kernel_build_dir/include/linux/fixture.h" || exit 96
fi
if [ "${FIXTURE_MUTATE_SOURCE:-false}" = "true" ]; then
  source_dir=""
  previous=""
  for argument in "$@"; do
    if [ "$previous" = "-C" ]; then
      source_dir="$argument"
      break
    fi
    previous="$argument"
  done
  [ -n "$source_dir" ] || exit 98
  printf 'mutated during build\n' > "$source_dir/fixture.c"
  exit 0
fi
if [ "${FIXTURE_BUILD_SUCCESS:-false}" = "true" ]; then
  source_dir=""
  previous=""
  for argument in "$@"; do
    if [ "$previous" = "-C" ]; then
      source_dir="$argument"
      break
    fi
    previous="$argument"
  done
  [ -n "$source_dir" ] || exit 98
  for module in gpi spi-geni-qcom mshw0485_touch; do
    printf 'fixture module %s\n' "$module" > "$source_dir/$module.ko"
  done
  exit 0
fi
exit 99
EOF_MAKE
cat > "$mock_bin/dpkg-deb" <<'EOF_DPKG_DEB'
#!/usr/bin/env bash
[ "$#" -eq 3 ] && [ "$1" = "-x" ] || exit 95
case "$(basename "$2")" in
  linux-qcom-x1e-headers-*)
    mkdir -p "$3/usr/src/linux-qcom-x1e-headers-${FIXTURE_RELEASE%-qcom-x1e}"
    printf 'common header fixture\n' \
      > "$3/usr/src/linux-qcom-x1e-headers-${FIXTURE_RELEASE%-qcom-x1e}/fixture-common.h"
    if [ "${FIXTURE_ESCAPE_COMMON_HEADERS:-false}" = "true" ]; then
      ln -s "$FIXTURE_ESCAPE_TARGET" \
        "$3/usr/src/linux-headers-$FIXTURE_RELEASE"
    fi
    if [ "${FIXTURE_ESCAPE_COMMON_LIB:-false}" = "true" ]; then
      mkdir -p "$3/usr/lib"
      ln -s "$FIXTURE_ESCAPE_TARGET" "$3/usr/lib/escape"
    fi
    ;;
  linux-headers-*)
    : > "$FIXTURE_ARCH_EXTRACT_MARKER"
    if [ "${FIXTURE_ESCAPE_COMMON_LIB:-false}" = "true" ]; then
      mkdir -p "$3/usr/lib/escape"
      printf 'architecture overlay fixture\n' > "$3/usr/lib/escape/payload"
    fi
    destination="$3/usr/src/linux-headers-$FIXTURE_RELEASE"
    mkdir -p "$destination"
    cp -R "$FIXTURE_HEADER_SEED/." "$destination/"
    mkdir -p "$3/usr/lib/modules/$FIXTURE_RELEASE"
    ln -s "/usr/src/linux-headers-$FIXTURE_RELEASE" \
      "$3/usr/lib/modules/$FIXTURE_RELEASE/build"
    ;;
  *) exit 94 ;;
esac
EOF_DPKG_DEB
cat > "$mock_bin/sha256sum" <<'EOF_SHA256SUM'
#!/usr/bin/env bash
exec shasum -a 256 "$@"
EOF_SHA256SUM
cat > "$mock_bin/gcc" <<'EOF_GCC'
#!/usr/bin/env bash
printf '%s\n' 'gcc fixture 1.0'
EOF_GCC
cat > "$mock_bin/ld" <<'EOF_LD'
#!/usr/bin/env bash
printf '%s\n' 'ld fixture 1.0'
EOF_LD
cat > "$mock_bin/install" <<'EOF_INSTALL'
#!/usr/bin/env bash
"$FIXTURE_REAL_INSTALL" "$@" || exit $?
destination=""
for destination in "$@"; do :; done
case "$destination" in
  */.sp11-touchscreen-stage.*/*)
    if [ "${FIXTURE_TAMPER_STAGED_COPY:-}" = "$(basename "$destination")" ]; then
      printf 'tampered staged copy\n' >> "$destination"
    fi
    ;;
esac
EOF_INSTALL
cat > "$mock_bin/python3" <<'EOF_PYTHON3'
#!/usr/bin/env bash
destination=""
for destination in "$@"; do :; done
if [ "${FIXTURE_PUBLISH_RACE:-false}" = "true" ] && [ "${1:-}" = "-" ] &&
   [ ! -e "$FIXTURE_PUBLISH_RACE_MARKER" ]; then
  mkdir "$destination" || exit 92
  if [ "${FIXTURE_PUBLISH_RACE_EMPTY:-false}" != "true" ]; then
    printf 'publication race victim\n' > "$destination/race-victim"
  fi
  : > "$FIXTURE_PUBLISH_RACE_MARKER"
fi
exec "$FIXTURE_REAL_PYTHON3" "$@"
EOF_PYTHON3
cat > "$mock_bin/id" <<'EOF_ID'
#!/usr/bin/env bash
if [ "${FIXTURE_INSTALL_CAPTURE:-false}" = "true" ] && [ "${1:-}" = "-u" ]; then
  printf '%s\n' 1000
  exit 0
fi
exec "$FIXTURE_REAL_ID" "$@"
EOF_ID
cat > "$mock_bin/sudo" <<'EOF_SUDO'
#!/usr/bin/env bash
[ "${FIXTURE_INSTALL_CAPTURE:-false}" = "true" ] || exit 95
[ "$#" -ge 5 ] || exit 94
shift
modules_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --modules-dir) modules_dir="${2:-}"; shift 2 ;;
    --release) shift 2 ;;
    --windows-se-init) shift ;;
    *) exit 93 ;;
  esac
done
case "$modules_dir" in
  "$FIXTURE_INSTALL_PARENT"/.sp11-touchscreen-install.*) ;;
  *) exit 92 ;;
esac
[ "$modules_dir" != "$FIXTURE_PUBLIC_OUTPUT" ] &&
  [ -d "$modules_dir" ] && [ ! -L "$modules_dir" ] || exit 91
printf 'mutable public output changed during sudo\n' > "$FIXTURE_PUBLIC_OUTPUT/gpi.ko"
grep -Fxq 'fixture module gpi' "$modules_dir/gpi.ko" || exit 84
if mode="$(stat -c '%a' -- "$modules_dir" 2>/dev/null)"; then
  :
else
  mode="$(stat -f '%Lp' "$modules_dir" 2>/dev/null)" || exit 90
fi
[ "$mode" = "500" ] || exit 89
[ "$(find "$modules_dir" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" -eq 4 ] || exit 88
for leaf in gpi.ko spi-geni-qcom.ko mshw0485_touch.ko sp11-touchscreen-modules-manifest.txt; do
  [ -s "$modules_dir/$leaf" ] && [ ! -L "$modules_dir/$leaf" ] || exit 87
  if mode="$(stat -c '%a' -- "$modules_dir/$leaf" 2>/dev/null)"; then
    :
  else
    mode="$(stat -f '%Lp' "$modules_dir/$leaf" 2>/dev/null)" || exit 86
  fi
  [ "$mode" = "400" ] || exit 85
done
printf '%s\n' "$modules_dir" > "$FIXTURE_INSTALL_CAPTURE_MARKER"
EOF_SUDO
chmod +x "$mock_bin/"*

run_builder() {
  local source_dir="$1"
  local -a builder_arguments=()
  local -a kernel_arguments=()
  shift
  case "${FIXTURE_HEADER_MODE:-local}" in
    local)
      kernel_arguments=(--kernel-build-dir "$kernel_build")
      ;;
    debs)
      kernel_arguments=(
        --kernel-common-headers-deb "$common_headers_deb"
        --kernel-headers-deb "$architecture_headers_deb"
      )
      ;;
    debs-and-kdir)
      kernel_arguments=(
        --kernel-build-dir "$kernel_build"
        --kernel-common-headers-deb "$common_headers_deb"
        --kernel-headers-deb "$architecture_headers_deb"
      )
      ;;
    *) die "invalid fixture header mode" ;;
  esac
  builder_arguments=(
    --release "$release"
    "${kernel_arguments[@]}"
    --source-dir "$source_dir"
    --source-url "$source_seed"
    --source-ref "$source_commit"
    --out-dir "${FIXTURE_OUT_DIR:-$output_fixture_root/default}"
  )
  if [ "${FIXTURE_OFFLINE:-true}" = "true" ]; then
    builder_arguments+=(--offline)
  fi
  builder_arguments+=("$@")
  PATH="$mock_bin:/usr/bin:/bin" \
    FIXTURE_REAL_UNAME="$real_uname" \
    FIXTURE_REAL_ID="$real_id" \
    FIXTURE_REAL_INSTALL="$real_install" \
    FIXTURE_REAL_PYTHON3="$real_python3" \
    FIXTURE_BAD_STAGED_MODULE="${FIXTURE_BAD_STAGED_MODULE:-}" \
    FIXTURE_TAMPER_STAGED_COPY="${FIXTURE_TAMPER_STAGED_COPY:-}" \
    FIXTURE_PUBLISH_RACE="${FIXTURE_PUBLISH_RACE:-false}" \
    FIXTURE_PUBLISH_RACE_EMPTY="${FIXTURE_PUBLISH_RACE_EMPTY:-false}" \
    FIXTURE_PUBLISH_RACE_MARKER="$temporary_root/publication-raced" \
    FIXTURE_INSTALL_CAPTURE="${FIXTURE_INSTALL_CAPTURE:-false}" \
    FIXTURE_INSTALL_CAPTURE_MARKER="$temporary_root/install-captured" \
    FIXTURE_INSTALL_PARENT="${FIXTURE_INSTALL_PARENT:-$output_fixture_root}" \
    FIXTURE_PUBLIC_OUTPUT="${FIXTURE_PUBLIC_OUTPUT:-${FIXTURE_OUT_DIR:-$output_fixture_root/default}}" \
    FIXTURE_MAKE_MARKER="$temporary_root/make-invoked" \
    FIXTURE_MUTATE_SOURCE="${FIXTURE_MUTATE_SOURCE:-false}" \
    FIXTURE_BUILD_SUCCESS="${FIXTURE_BUILD_SUCCESS:-false}" \
    FIXTURE_VERIFY_PRISTINE_HEADERS="${FIXTURE_VERIFY_PRISTINE_HEADERS:-false}" \
    FIXTURE_MUTATED_KERNEL_BUILD="$kernel_build" \
    FIXTURE_HEADER_SEED="$header_seed" \
    FIXTURE_RELEASE="$release" \
    FIXTURE_ESCAPE_COMMON_HEADERS="${FIXTURE_ESCAPE_COMMON_HEADERS:-false}" \
    FIXTURE_ESCAPE_COMMON_LIB="${FIXTURE_ESCAPE_COMMON_LIB:-false}" \
    FIXTURE_ESCAPE_TARGET="$temporary_root/escaped-headers" \
    FIXTURE_ARCH_EXTRACT_MARKER="$temporary_root/architecture-extracted" \
    "$builder" "${builder_arguments[@]}" || return $?
  return 0
}

set +e
missing_header_output="$(run_builder "$source_seed" \
  --kernel-common-headers-deb "$common_headers_deb" 2>&1)"
missing_header_status=$?
set -e
[ "$missing_header_status" -ne 0 ]
printf '%s\n' "$missing_header_output" |
  grep -Fq 'supply --kernel-common-headers-deb and --kernel-headers-deb together' ||
  die "partial header-Deb provenance rejection was not explicit"

set +e
combined_header_output="$(FIXTURE_HEADER_MODE=debs-and-kdir \
  run_builder "$source_seed" 2>&1)"
combined_header_status=$?
set -e
[ "$combined_header_status" -ne 0 ]
printf '%s\n' "$combined_header_output" |
  grep -Fq 'cannot be combined with --kernel-build-dir' ||
  die "release header Debs did not reject an arbitrary explicit KDIR"
[ ! -e "$temporary_root/make-invoked" ] ||
  die "module build began with both release Debs and an arbitrary KDIR"

pristine_checkout="$managed_root/pristine-header-checkout"
git clone --quiet "$source_seed" "$pristine_checkout"
set +e
FIXTURE_HEADER_MODE=debs FIXTURE_VERIFY_PRISTINE_HEADERS=true \
  run_builder "$pristine_checkout" > "$temporary_root/pristine-headers.log" 2>&1
pristine_headers_status=$?
set -e
[ "$pristine_headers_status" -ne 0 ] ||
  die "pristine-header fixture unexpectedly completed its mocked module build"
[ -s "$temporary_root/make-invoked" ] ||
  die "release header-Deb fixture did not invoke the module build"
case "$(<"$temporary_root/make-invoked")" in
  */sp11-touchscreen-headers.*/usr/src/linux-headers-"$release") ;;
  *) die "module builder did not use the disposable Deb-extracted KDIR" ;;
esac
rm -f "$temporary_root/make-invoked"

escape_checkout="$managed_root/escape-header-checkout"
git clone --quiet "$source_seed" "$escape_checkout"
rm -f "$temporary_root/architecture-extracted"
if FIXTURE_HEADER_MODE=debs FIXTURE_ESCAPE_COMMON_HEADERS=true \
    run_builder "$escape_checkout" > "$temporary_root/escape-headers.log" 2>&1; then
  die "release header extraction accepted an escaping common-package symlink"
fi
grep -Fq 'common headers Deb must contain exactly one safe usr/src' \
  "$temporary_root/escape-headers.log" ||
  die "escaping common-package symlink rejection was not explicit"
[ ! -e "$temporary_root/architecture-extracted" ] ||
  die "architecture headers were overlaid before common-package validation"
[ ! -e "$temporary_root/escaped-headers" ] ||
  die "common-package symlink fixture wrote outside the private extraction root"

lib_escape_checkout="$managed_root/lib-escape-header-checkout"
git clone --quiet "$source_seed" "$lib_escape_checkout"
rm -f "$temporary_root/architecture-extracted" "$temporary_root/make-invoked"
if FIXTURE_HEADER_MODE=debs FIXTURE_ESCAPE_COMMON_LIB=true \
    run_builder "$lib_escape_checkout" > "$temporary_root/lib-escape-headers.log" 2>&1; then
  die "mocked module build unexpectedly completed"
fi
[ -e "$temporary_root/architecture-extracted" ] ||
  die "architecture package was not extracted in its separate private root"
[ -e "$temporary_root/make-invoked" ] ||
  die "separate-root header extraction did not reach the mocked module build"
[ ! -e "$temporary_root/escaped-headers" ] ||
  die "a non-usr/src common-package symlink was followed by architecture extraction"
rm -f "$temporary_root/make-invoked"

ignored_checkout="$managed_root/ignored-checkout"
git clone --quiet "$source_seed" "$ignored_checkout"
printf 'stale object\n' > "$ignored_checkout/phase55/modules/fixture.o"
git -C "$ignored_checkout" check-ignore -q phase55/modules/fixture.o ||
  die "stale-object fixture is not ignored"
if run_builder "$ignored_checkout" > "$temporary_root/ignored.log" 2>&1; then
  die "module builder accepted an ignored prior-build object"
fi
grep -Fq 'modified, untracked, or ignored content' "$temporary_root/ignored.log" ||
  die "ignored prior-build rejection was not explicit"
[ ! -e "$temporary_root/make-invoked" ] ||
  die "module build began before ignored source content was rejected"

status_failure_checkout="$managed_root/status-failure-checkout"
git clone --quiet "$source_seed" "$status_failure_checkout"
printf 'invalid index\n' > "$status_failure_checkout/.git/index"
if run_builder "$status_failure_checkout" > "$temporary_root/status-failure.log" 2>&1; then
  die "module builder interpreted a failed git status as pristine"
fi
grep -Fq 'could not inspect the source checkout state' "$temporary_root/status-failure.log" ||
  die "git-status failure was not explicit"
[ ! -e "$temporary_root/make-invoked" ] ||
  die "module build began after source-status inspection failed"

mutation_checkout="$managed_root/mutation-checkout"
git clone --quiet "$source_seed" "$mutation_checkout"
if FIXTURE_MUTATE_SOURCE=true run_builder "$mutation_checkout" \
    > "$temporary_root/mutation.log" 2>&1; then
  die "module builder accepted source mutated during the build"
fi
grep -Fq 'source input changed during the module build' "$temporary_root/mutation.log" ||
  die "post-build source mutation rejection was not explicit"
[ -e "$temporary_root/make-invoked" ] ||
  die "post-build mutation fixture did not invoke the module build"

expect_path_rejection() {
  local label="$1" source_dir="$2" output_dir="$3" expected="$4"
  rm -f "$temporary_root/make-invoked"
  if FIXTURE_OUT_DIR="$output_dir" run_builder "$source_dir" \
      > "$temporary_root/path-$label.log" 2>&1; then
    die "module builder accepted unsafe path fixture: $label"
  fi
  grep -Fq "$expected" "$temporary_root/path-$label.log" || {
    cat "$temporary_root/path-$label.log" >&2
    die "unsafe path rejection was not explicit: $label"
  }
  [ ! -e "$temporary_root/make-invoked" ] ||
    die "module build began before unsafe path rejection: $label"
}

safe_output="$output_fixture_root/path-default"
expect_path_rejection source-root / "$safe_output" 'source directory has an unsafe path'
expect_path_rejection source-traversal "$managed_root/../source-escape" "$safe_output" \
  'source directory has an unsafe path'
expect_path_rejection source-control "$managed_root/"$'control\nsource' "$safe_output" \
  'source directory has an unsafe path'
expect_path_rejection source-build-root "$repo_dir/build" "$safe_output" \
  'source directory must be a physical descendant of repository build/'

source_parent_victim="$temporary_root/source-parent-victim"
mkdir "$source_parent_victim"
printf 'source parent victim\n' > "$source_parent_victim/victim"
ln -s "$source_parent_victim" "$managed_root/source-parent-link"
expect_path_rejection source-parent-link "$managed_root/source-parent-link/checkout" \
  "$safe_output" 'source directory parent must already be a real directory'
grep -Fxq 'source parent victim' "$source_parent_victim/victim"

ln -s "$source_seed" "$managed_root/source-leaf-link"
expect_path_rejection source-leaf-link "$managed_root/source-leaf-link" "$safe_output" \
  'source directory must be a real, non-symlinked directory'
ln -s "$temporary_root/missing-source-target" "$managed_root/source-dangling-link"
expect_path_rejection source-dangling-link "$managed_root/source-dangling-link" "$safe_output" \
  'source directory must be a real, non-symlinked directory'

git_link_checkout="$managed_root/git-link-checkout"
git clone --quiet "$source_seed" "$git_link_checkout"
mv "$git_link_checkout/.git" "$temporary_root/git-link-victim"
printf 'git victim\n' > "$temporary_root/git-link-victim/victim"
ln -s "$temporary_root/git-link-victim" "$git_link_checkout/.git"
expect_path_rejection source-git-link "$git_link_checkout" "$safe_output" \
  'source checkout must contain a real, non-symlinked .git directory'
grep -Fxq 'git victim' "$temporary_root/git-link-victim/victim"

redirected_worktree="$temporary_root/redirected-worktree-victim"
redirected_checkout="$managed_root/redirected-worktree-checkout"
mkdir "$redirected_worktree"
printf 'redirected worktree victim\n' > "$redirected_worktree/victim"
git clone --quiet "$source_seed" "$redirected_checkout"
git -C "$redirected_checkout" config core.worktree "$redirected_worktree"
expect_path_rejection source-core-worktree "$redirected_checkout" "$safe_output" \
  'source checkout core.worktree redirects outside the managed checkout'
grep -Fxq 'redirected worktree victim' "$redirected_worktree/victim"

redirected_common="$temporary_root/redirected-common-git-victim"
common_redirect_checkout="$managed_root/redirected-common-git-checkout"
git clone --quiet "$source_seed" "$common_redirect_checkout"
mkdir "$redirected_common"
cp -R "$common_redirect_checkout/.git/." "$redirected_common/"
printf 'redirected common Git victim\n' > "$redirected_common/victim"
printf '%s\n' "$redirected_common" > "$common_redirect_checkout/.git/commondir"
expect_path_rejection source-common-git "$common_redirect_checkout" "$safe_output" \
  'source checkout common Git directory redirects outside the managed checkout'
grep -Fxq 'redirected common Git victim' "$redirected_common/victim"

unsafe_filter_checkout="$managed_root/unsafe-filter-checkout"
git clone --quiet "$source_seed" "$unsafe_filter_checkout"
git -C "$unsafe_filter_checkout" config filter.fixture.clean '/bin/false'
expect_path_rejection source-filter-config "$unsafe_filter_checkout" "$safe_output" \
  'source checkout local Git configuration is unsafe'

safe_git_checkout="$managed_root/safe-git-wrapper-checkout"
hook_victim="$temporary_root/post-checkout-hook-victim"
fsmonitor_victim="$temporary_root/fsmonitor-victim"
fsmonitor_helper="$temporary_root/fsmonitor-helper"
git clone --quiet "$source_seed" "$safe_git_checkout"
printf 'post-checkout hook preserved\n' > "$hook_victim"
printf 'fsmonitor preserved\n' > "$fsmonitor_victim"
{
  printf '%s\n' '#!/bin/sh'
  printf "printf 'post-checkout hook executed\\n' >> '%s'\n" "$hook_victim"
} > "$safe_git_checkout/.git/hooks/post-checkout"
{
  printf '%s\n' '#!/bin/sh'
  printf "printf 'fsmonitor executed\\n' >> '%s'\n" "$fsmonitor_victim"
  printf '%s\n' 'exit 0'
} > "$fsmonitor_helper"
chmod +x "$safe_git_checkout/.git/hooks/post-checkout" "$fsmonitor_helper"
git -C "$safe_git_checkout" config core.fsmonitor "$fsmonitor_helper"
rm -f "$temporary_root/make-invoked"
if FIXTURE_OUT_DIR="$safe_output" run_builder "$safe_git_checkout" \
    > "$temporary_root/safe-git-wrapper.log" 2>&1; then
  die "safe Git wrapper fixture unexpectedly completed its mocked module build"
fi
[ -s "$temporary_root/make-invoked" ] ||
  die "safe Git wrapper rejected the checkout before the mocked build"
grep -Fxq 'post-checkout hook preserved' "$hook_victim" ||
  die "source checkout post-checkout hook executed"
grep -Fxq 'fsmonitor preserved' "$fsmonitor_victim" ||
  die "source checkout fsmonitor command executed"
rm -f "$temporary_root/make-invoked"

expect_path_rejection source-missing-parent "$managed_root/missing-parent/checkout" \
  "$safe_output" 'source directory parent must already be a real directory'
[ ! -e "$managed_root/missing-parent" ] ||
  die "module builder created an unapproved source parent"

path_checkout="$managed_root/output-path-checkout"
git clone --quiet "$source_seed" "$path_checkout"
expect_path_rejection output-root "$path_checkout" / 'output directory has an unsafe path'
expect_path_rejection output-dot "$path_checkout" . 'output directory has an unsafe path'
expect_path_rejection output-traversal "$path_checkout" \
  "$output_fixture_root/../output-escape" 'output directory has an unsafe path'
expect_path_rejection output-control "$path_checkout" \
  "$output_fixture_root/"$'control\noutput' 'output directory has an unsafe path'
expect_path_rejection output-build-root "$path_checkout" "$repo_dir/build" \
  'output directory must match repository .sp11-kmod-vN'

documented_output="$repo_dir/build/release-r2-fixture-$$-touchscreen-modules"
rm -f "$temporary_root/make-invoked"
if FIXTURE_OUT_DIR="$documented_output" run_builder "$path_checkout" \
    > "$temporary_root/documented-output.log" 2>&1; then
  die "documented direct build/*-touchscreen-modules output unexpectedly completed"
fi
[ -s "$temporary_root/make-invoked" ] ||
  die "documented direct build/*-touchscreen-modules output was rejected before the build"
[ ! -e "$documented_output" ] && [ ! -L "$documented_output" ] ||
  die "failed mocked build created the documented output path"
rm -f "$temporary_root/make-invoked"

output_parent_victim="$temporary_root/output-parent-victim"
mkdir "$output_parent_victim"
printf 'output parent victim\n' > "$output_parent_victim/victim"
ln -s "$output_parent_victim" "$output_fixture_root/output-parent-link"
expect_path_rejection output-parent-link "$path_checkout" \
  "$output_fixture_root/output-parent-link/output" \
  'output directory parent must already be a real directory'
grep -Fxq 'output parent victim' "$output_parent_victim/victim"

output_leaf_victim="$temporary_root/output-leaf-victim"
printf 'output leaf victim\n' > "$output_leaf_victim"
ln -s "$output_leaf_victim" "$output_fixture_root/output-leaf-link"
expect_path_rejection output-leaf-link "$path_checkout" \
  "$output_fixture_root/output-leaf-link" \
  'output path must be a real, non-symlinked directory'
grep -Fxq 'output leaf victim' "$output_leaf_victim"
ln -s "$temporary_root/missing-output-target" "$output_fixture_root/output-dangling-link"
expect_path_rejection output-dangling-link "$path_checkout" \
  "$output_fixture_root/output-dangling-link" \
  'output path must be a real, non-symlinked directory'
mkfifo "$output_fixture_root/output-fifo"
expect_path_rejection output-fifo "$path_checkout" "$output_fixture_root/output-fifo" \
  'output path must be a real, non-symlinked directory'

staged_identity_checkout="$managed_root/staged-identity-checkout"
staged_identity_output="$output_fixture_root/staged-identity-output"
git clone --quiet "$source_seed" "$staged_identity_checkout"
if FIXTURE_BUILD_SUCCESS=true FIXTURE_BAD_STAGED_MODULE=gpi.ko \
    FIXTURE_OUT_DIR="$staged_identity_output" \
    run_builder "$staged_identity_checkout" > "$temporary_root/staged-identity.log" 2>&1; then
  die "module builder accepted a staged module with the wrong identity"
fi
grep -Fq 'unexpected staged module name' "$temporary_root/staged-identity.log" ||
  die "staged module identity rejection was not explicit"
[ ! -e "$staged_identity_output" ] && [ ! -L "$staged_identity_output" ] ||
  die "staged module identity failure published an output directory"

staged_hash_checkout="$managed_root/staged-hash-checkout"
staged_hash_output="$output_fixture_root/staged-hash-output"
git clone --quiet "$source_seed" "$staged_hash_checkout"
if FIXTURE_BUILD_SUCCESS=true FIXTURE_TAMPER_STAGED_COPY=gpi.ko \
    FIXTURE_OUT_DIR="$staged_hash_output" \
    run_builder "$staged_hash_checkout" > "$temporary_root/staged-hash.log" 2>&1; then
  die "module builder accepted a changed staged module copy"
fi
grep -Fq 'changed while copying it into the private stage' "$temporary_root/staged-hash.log" ||
  die "staged module hash rejection was not explicit"
[ ! -e "$staged_hash_output" ] && [ ! -L "$staged_hash_output" ] ||
  die "staged module hash failure published an output directory"
if find "$output_fixture_root" -mindepth 1 -maxdepth 1 \
    -name '.sp11-touchscreen-stage.*' -print -quit | grep -q .; then
  die "staged module validation failure left a private stage"
fi

leaf_case_index=0
for protected_leaf in \
  gpi.ko spi-geni-qcom.ko mshw0485_touch.ko \
  sp11-touchscreen-modules-manifest.txt; do
  for protected_kind in symlink fifo directory; do
    leaf_case_index=$((leaf_case_index + 1))
    leaf_checkout="$managed_root/output-leaf-checkout-$leaf_case_index"
    leaf_output="$output_fixture_root/output-leaf-$leaf_case_index"
    leaf_victim="$temporary_root/output-leaf-victim-$leaf_case_index"
    git clone --quiet "$source_seed" "$leaf_checkout"
    mkdir "$leaf_output"
    if [ "$protected_leaf" = "gpi.ko" ]; then
      sentinel_leaf=spi-geni-qcom.ko
    else
      sentinel_leaf=gpi.ko
    fi
    printf 'existing safe output\n' > "$leaf_output/$sentinel_leaf"
    case "$protected_kind" in
      symlink)
        printf 'protected leaf victim\n' > "$leaf_victim"
        ln -s "$leaf_victim" "$leaf_output/$protected_leaf"
        ;;
      fifo)
        mkfifo "$leaf_output/$protected_leaf"
        ;;
      directory)
        mkdir "$leaf_output/$protected_leaf"
        printf 'protected directory victim\n' > "$leaf_output/$protected_leaf/victim"
        ;;
    esac
    rm -f "$temporary_root/make-invoked"
    if FIXTURE_BUILD_SUCCESS=true FIXTURE_OUT_DIR="$leaf_output" \
        run_builder "$leaf_checkout" > "$temporary_root/output-leaf-$leaf_case_index.log" 2>&1; then
      die "module builder accepted $protected_kind output leaf: $protected_leaf"
    fi
    grep -Fq 'module output leaf is not a regular, non-symlinked file' \
      "$temporary_root/output-leaf-$leaf_case_index.log" ||
      die "unsafe output leaf rejection was not explicit: $protected_kind $protected_leaf"
    grep -Fxq 'existing safe output' "$leaf_output/$sentinel_leaf"
    case "$protected_kind" in
      symlink) grep -Fxq 'protected leaf victim' "$leaf_victim" ;;
      directory) grep -Fxq 'protected directory victim' "$leaf_output/$protected_leaf/victim" ;;
    esac
    if find "$output_fixture_root" -mindepth 1 -maxdepth 1 \
        \( -name '.sp11-touchscreen-stage.*' -o -name '.sp11-touchscreen-backup.*' \) \
        -print -quit | grep -q .; then
      die "module builder left a private publication artifact after rejection"
    fi
  done
done

rollback_checkout="$managed_root/rollback-checkout"
rollback_output="$output_fixture_root/rollback-output"
git clone --quiet "$source_seed" "$rollback_checkout"
mkdir "$rollback_output"
for rollback_leaf in \
  gpi.ko spi-geni-qcom.ko mshw0485_touch.ko \
  sp11-touchscreen-modules-manifest.txt; do
  printf 'rollback victim %s\n' "$rollback_leaf" > "$rollback_output/$rollback_leaf"
done
rm -f "$temporary_root/publication-raced"
if FIXTURE_BUILD_SUCCESS=true FIXTURE_PUBLISH_RACE=true \
    FIXTURE_OUT_DIR="$rollback_output" \
    run_builder "$rollback_checkout" > "$temporary_root/rollback.log" 2>&1; then
  die "module builder nested its private stage into a raced output directory"
fi
[ -e "$temporary_root/publication-raced" ] ||
  die "atomic-publication race fixture did not reach the exclusive final rename"
grep -Fxq 'publication race victim' "$rollback_output/race-victim" ||
  die "exclusive publication did not preserve the raced output victim"
rollback_backup="$(find "$output_fixture_root" -mindepth 1 -maxdepth 1 \
  -type d -name '.sp11-touchscreen-backup.*' -print)"
[ -n "$rollback_backup" ] && [ "$(printf '%s\n' "$rollback_backup" | wc -l | tr -d '[:space:]')" -eq 1 ] ||
  die "exclusive publication did not preserve exactly one prior-output backup"
for rollback_leaf in \
  gpi.ko spi-geni-qcom.ko mshw0485_touch.ko \
  sp11-touchscreen-modules-manifest.txt; do
  grep -Fxq "rollback victim $rollback_leaf" "$rollback_backup/previous/$rollback_leaf" ||
    die "exclusive publication did not preserve prior $rollback_leaf"
done
if find "$output_fixture_root" -mindepth 1 -maxdepth 1 \
    -name '.sp11-touchscreen-stage.*' -print -quit | grep -q .; then
  die "exclusive publication race left a private module stage"
fi
rm -rf -- "$rollback_output" "$rollback_backup"

exclusive_checkout="$managed_root/exclusive-empty-race-checkout"
exclusive_output="$output_fixture_root/exclusive-empty-race-output"
git clone --quiet "$source_seed" "$exclusive_checkout"
mkdir "$exclusive_output"
printf 'exclusive prior output\n' > "$exclusive_output/gpi.ko"
rm -f "$temporary_root/publication-raced"
if FIXTURE_BUILD_SUCCESS=true FIXTURE_PUBLISH_RACE=true \
    FIXTURE_PUBLISH_RACE_EMPTY=true FIXTURE_OUT_DIR="$exclusive_output" \
    run_builder "$exclusive_checkout" > "$temporary_root/exclusive-empty.log" 2>&1; then
  die "exclusive publication replaced an empty directory that appeared at the destination"
fi
[ -e "$temporary_root/publication-raced" ] ||
  die "exclusive empty-destination fixture did not reach the final rename"
[ -d "$exclusive_output" ] && [ ! -L "$exclusive_output" ] ||
  die "exclusive publication did not preserve the empty raced destination"
if find "$exclusive_output" -mindepth 1 -print -quit | grep -q .; then
  die "exclusive publication nested or moved content into the empty raced destination"
fi
exclusive_backup="$(find "$output_fixture_root" -mindepth 1 -maxdepth 1 \
  -type d -name '.sp11-touchscreen-backup.*' -print)"
[ -n "$exclusive_backup" ] && [ "$(printf '%s\n' "$exclusive_backup" | wc -l | tr -d '[:space:]')" -eq 1 ] ||
  die "exclusive empty-destination race did not preserve exactly one prior-output backup"
grep -Fxq 'exclusive prior output' "$exclusive_backup/previous/gpi.ko" ||
  die "exclusive empty-destination race did not preserve the prior output"
rm -rf -- "$exclusive_output" "$exclusive_backup"

success_source_parent="$managed_root/success-source-parent"
success_source="$success_source_parent/checkout"
success_output="$output_fixture_root/success-output"
mkdir "$success_source_parent" "$success_output"
for success_leaf in \
  gpi.ko spi-geni-qcom.ko mshw0485_touch.ko \
  sp11-touchscreen-modules-manifest.txt; do
  printf 'old output %s\n' "$success_leaf" > "$success_output/$success_leaf"
done
if ! (
  FIXTURE_BUILD_SUCCESS=true FIXTURE_OFFLINE=false FIXTURE_OUT_DIR="$success_output" \
    run_builder "$success_source"
) > "$temporary_root/success.log" 2>&1; then
  cat "$temporary_root/success.log" >&2
  die "fully mocked atomic module build failed"
fi
[ -d "$success_source/.git" ] && [ ! -L "$success_source/.git" ] ||
  die "successful new checkout did not retain a physical .git directory"
[ "$(find "$success_output" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" -eq 4 ] ||
  die "successful atomic output does not contain exactly four files"
if find "$success_output" -mindepth 1 -maxdepth 1 ! -type f -print -quit | grep -q .; then
  die "successful atomic output contains a symlink or special entry"
fi
for success_leaf in \
  gpi.ko spi-geni-qcom.ko mshw0485_touch.ko \
  sp11-touchscreen-modules-manifest.txt; do
  [ -s "$success_output/$success_leaf" ] && [ ! -L "$success_output/$success_leaf" ] ||
    die "successful atomic output is missing $success_leaf"
  [ "$(fixture_mode "$success_output/$success_leaf")" = "644" ] ||
    die "successful atomic output has the wrong mode: $success_leaf"
  if grep -Fq 'old output' "$success_output/$success_leaf"; then
    die "successful atomic output retained stale bytes: $success_leaf"
  fi
done
[ "$(fixture_mode "$success_output")" = "755" ] ||
  die "successful atomic output directory does not have mode 0755"
grep -Fq "Source commit: $source_commit" \
  "$success_output/sp11-touchscreen-modules-manifest.txt" ||
  die "successful atomic output manifest does not bind the source commit"
if find "$output_fixture_root" -mindepth 1 -maxdepth 1 \
    \( -name '.sp11-touchscreen-stage.*' -o -name '.sp11-touchscreen-backup.*' \) \
    -print -quit | grep -q .; then
  die "successful atomic output left a private publication artifact"
fi

install_checkout="$managed_root/install-checkout"
install_output="$output_fixture_root/install-output"
git clone --quiet "$source_seed" "$install_checkout"
rm -f "$temporary_root/install-captured"
if ! FIXTURE_BUILD_SUCCESS=true FIXTURE_INSTALL_CAPTURE=true \
    FIXTURE_INSTALL_PARENT="$output_fixture_root" \
    FIXTURE_PUBLIC_OUTPUT="$install_output" FIXTURE_OUT_DIR="$install_output" \
    run_builder "$install_checkout" --install > "$temporary_root/install.log" 2>&1; then
  cat "$temporary_root/install.log" >&2
  die "private install-snapshot fixture failed"
fi
[ -s "$temporary_root/install-captured" ] ||
  die "guarded installer mock did not receive a private module snapshot"
captured_install_dir="$(<"$temporary_root/install-captured")"
case "$captured_install_dir" in
  "$output_fixture_root"/.sp11-touchscreen-install.*) ;;
  *) die "guarded installer mock received an unexpected module path" ;;
esac
[ "$captured_install_dir" != "$install_output" ] ||
  die "builder passed mutable public module output to the guarded installer"
[ ! -e "$captured_install_dir" ] && [ ! -L "$captured_install_dir" ] ||
  die "private install snapshot remained after the guarded installer returned"
if find "$output_fixture_root" -mindepth 1 -maxdepth 1 \
    -name '.sp11-touchscreen-install.*' -print -quit | grep -q .; then
  die "builder left a private install snapshot"
fi
[ "$(find "$install_output" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" -eq 4 ] ||
  die "install build did not publish exactly four public release files"
grep -Fxq 'mutable public output changed during sudo' "$install_output/gpi.ko" ||
  die "private install fixture did not mutate the public output independently"

printf 'Touchscreen module source-provenance fixtures passed.\n'
