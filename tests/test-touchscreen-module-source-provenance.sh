#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
builder=""
builder_repo_dir=""
temporary_root=""
temporary_parent=""
managed_root=""
output_fixture_root=""
output_contract_root=""
output_contract_created="false"

cleanup() {
  if [ -n "$managed_root" ]; then
    case "$managed_root" in
      "$builder_repo_dir/build"/sp11-touch-source-test.*) rm -rf -- "$managed_root" ;;
      *) echo "warning: refusing to remove unexpected managed fixture path: $managed_root" >&2 ;;
    esac
  fi
  if [ -n "$output_fixture_root" ]; then
    case "$output_fixture_root" in
      "$builder_repo_dir/build/sp11-touchscreen-module-output"/sp11-touch-source-test.*)
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

for tool in git mkfifo mktemp openssl python3 shasum stat; do
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
runtime_tmp="$temporary_root/runtime-tmp"
mkdir "$runtime_tmp"
chmod 0700 "$runtime_tmp"
source_seed="$temporary_root/source-seed"
kernel_build="$temporary_root/kernel-build"
header_seed="$temporary_root/header-seed"
mock_bin="$temporary_root/mock-bin"
mkdir -p \
  "$source_seed/phase55/modules" \
  "$kernel_build/include/config" \
  "$kernel_build/include/linux" \
  "$kernel_build/scripts" \
  "$header_seed/include/config" \
  "$header_seed/include/linux" \
  "$header_seed/scripts" \
  "$mock_bin"

signing_fixture="$temporary_root/module-signing"
signing_private_key="$signing_fixture/private-key.pem"
signing_certificate_pem="$signing_fixture/certificate.pem"
signing_certificate_der="$signing_fixture/sp11-module-signing-cert.x509"
signing_pin_file="$signing_fixture/pin"
fixture_signing_pin='fixture controlled signing PIN 2026'
mkdir "$signing_fixture"
chmod 0700 "$signing_fixture"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -aes-256-cbc -pass "pass:$fixture_signing_pin" \
  -out "$signing_private_key" >/dev/null 2>&1
chmod 0600 "$signing_private_key"
openssl req -new -x509 -sha512 -days 2 -set_serial 0x2001 \
  -subj '/CN=SP11 touchscreen builder fixture/' \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -key "$signing_private_key" -passin "pass:$fixture_signing_pin" \
  -out "$signing_certificate_pem" >/dev/null 2>&1
openssl x509 -in "$signing_certificate_pem" -outform DER \
  -out "$signing_certificate_der" >/dev/null 2>&1
printf '%s\n' "$fixture_signing_pin" > "$signing_pin_file"
chmod 0600 "$signing_pin_file"

builder_repo_dir="$temporary_root/support-repo"
mkdir -p \
  "$builder_repo_dir/scripts" \
  "$builder_repo_dir/config/kernel-signing" \
  "$builder_repo_dir/build/sp11-touchscreen-module-output"
cp "$repo_dir/scripts/build-sp11-touchscreen-modules.sh" \
  "$repo_dir/scripts/install-sp11-touchscreen.sh" \
  "$repo_dir/scripts/validate-sp11-signed-modules.py" \
  "$builder_repo_dir/scripts/"
cp "$signing_certificate_pem" \
  "$builder_repo_dir/config/kernel-signing/sp11-module-signing-cert.pem"
fixture_certificate_sha256="$(shasum -a 256 "$signing_certificate_der" | awk '{print $1}')"
python3 - \
  "$builder_repo_dir/scripts/build-sp11-touchscreen-modules.sh" \
  "$builder_repo_dir/scripts/validate-sp11-signed-modules.py" \
  "$fixture_certificate_sha256" <<'PY_BIND_FIXTURE_CERTIFICATE'
import pathlib
import sys

reviewed = b"8ad9b402339b5ceff8e7fc9dfcc7dd368b2466fce0e90d97553059bcdc66e99b"
replacement = sys.argv[3].encode("ascii")
for name in sys.argv[1:3]:
    path = pathlib.Path(name)
    data = path.read_bytes()
    if data.count(reviewed) != 1:
        raise SystemExit(f"fixture product did not contain one reviewed certificate identity: {path.name}")
    path.write_bytes(data.replace(reviewed, replacement))
PY_BIND_FIXTURE_CERTIFICATE
chmod 0755 "$builder_repo_dir/scripts/"*.sh \
  "$builder_repo_dir/scripts/validate-sp11-signed-modules.py"
builder="$builder_repo_dir/scripts/build-sp11-touchscreen-modules.sh"
managed_root="$builder_repo_dir/build/sp11-touch-source-test.$$"
output_contract_root="$builder_repo_dir/build/sp11-touchscreen-module-output"
output_fixture_root="$output_contract_root/sp11-touch-source-test.$$"
mkdir "$managed_root" "$output_fixture_root"

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
  'CONFIG_MODULE_SIG=y' \
  'CONFIG_MODULE_SIG_SHA512=y' \
  'CONFIG_MODULE_SIG_HASH="sha512"' \
  'CONFIG_MODULE_SIG_KEY_TYPE_RSA=y' \
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
real_chmod="$(command -v chmod)"
real_python3="$(command -v python3)"
real_openssl="$(command -v openssl)"
cat > "$kernel_build/scripts/sign-file" <<'EOF_SIGN_FILE'
#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 5 ] && [ "$1" = "sha512" ] || exit 95
key="$2"
certificate="$3"
module="$4"
destination="$5"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/sp11-sign-file-fixture.XXXXXX")"
cleanup() {
  case "$temporary" in
    "${TMPDIR:-/tmp}"/sp11-sign-file-fixture.*) rm -rf -- "$temporary" ;;
    *) exit 96 ;;
  esac
}
trap cleanup EXIT
"$FIXTURE_OPENSSL" x509 -inform DER -in "$certificate" -outform PEM \
  -out "$temporary/certificate.pem" >/dev/null 2>&1
"$FIXTURE_OPENSSL" cms -sign -binary -in "$module" -signer "$temporary/certificate.pem" \
  -inkey "$key" -passin env:KBUILD_SIGN_PIN -md sha512 -noattr -nocerts \
  -outform DER -out "$temporary/signature.der" >/dev/null 2>&1
"$FIXTURE_REAL_PYTHON3" - "$module" "$temporary/signature.der" "$destination" <<'PY_SIGN_FILE'
import pathlib
import struct
import sys

payload = pathlib.Path(sys.argv[1]).read_bytes()
signature = pathlib.Path(sys.argv[2]).read_bytes()
descriptor = struct.pack(">BBBBB3sI", 0, 0, 2, 0, 0, b"\0\0\0", len(signature))
pathlib.Path(sys.argv[3]).write_bytes(
    payload + signature + descriptor + b"~Module signature appended~\n"
)
PY_SIGN_FILE
if [ "${FIXTURE_TAMPER_STAGED_COPY:-}" = "$(basename "$destination")" ]; then
  printf 'tampered staged copy\n' >> "$destination"
fi
EOF_SIGN_FILE
chmod 0755 "$kernel_build/scripts/sign-file"
cp "$kernel_build/scripts/sign-file" "$header_seed/scripts/sign-file"
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
cat > "$mock_bin/chmod" <<'EOF_CHMOD'
#!/usr/bin/env bash
"$FIXTURE_REAL_CHMOD" "$@" || exit $?
if [ "${FIXTURE_PUBLISH_RACE:-false}" = "true" ] &&
   [ "${1:-}" = "0755" ] &&
   [[ "${2:-}" == */.sp11-touchscreen-stage.* ]] &&
   [ ! -e "$FIXTURE_PUBLISH_RACE_MARKER" ]; then
  mkdir "$FIXTURE_PUBLIC_OUTPUT" || exit 92
  if [ "${FIXTURE_PUBLISH_RACE_EMPTY:-false}" != "true" ]; then
    printf 'publication race victim\n' > "$FIXTURE_PUBLIC_OUTPUT/race-victim"
  fi
  : > "$FIXTURE_PUBLISH_RACE_MARKER"
fi
EOF_CHMOD
cat > "$mock_bin/python3" <<'EOF_PYTHON3'
#!/usr/bin/env bash
: > "${FIXTURE_HOSTILE_PYTHON_MARKER:?}"
exit 0
EOF_PYTHON3
cat > "$mock_bin/id" <<'EOF_ID'
#!/usr/bin/env bash
if [ "${FIXTURE_INSTALL_CAPTURE:-false}" = "true" ] && [ "${1:-}" = "-u" ]; then
  printf '%s\n' 1000
  exit 0
fi
exec "$FIXTURE_REAL_ID" "$@"
EOF_ID
cat > "$mock_bin/openssl" <<'EOF_HOSTILE_OPENSSL'
#!/usr/bin/env bash
: > "${FIXTURE_HOSTILE_OPENSSL_MARKER:?}"
exit 0
EOF_HOSTILE_OPENSSL
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
grep -a -Fxq 'fixture module gpi' "$modules_dir/gpi.ko" || exit 84
if mode="$(stat -c '%a' -- "$modules_dir" 2>/dev/null)"; then
  :
else
  mode="$(stat -f '%Lp' "$modules_dir" 2>/dev/null)" || exit 90
fi
[ "$mode" = "500" ] || exit 89
[ "$(find "$modules_dir" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" -eq 5 ] || exit 88
for leaf in \
  gpi.ko spi-geni-qcom.ko mshw0485_touch.ko \
  sp11-module-signing-cert.x509 sp11-touchscreen-modules-manifest.txt; do
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
  case "${FIXTURE_SIGNING_OPTIONS:-full}" in
    full)
      builder_arguments+=(
        --module-signing-key "${FIXTURE_SIGNING_KEY:-$signing_private_key}"
        --module-signing-certificate "${FIXTURE_SIGNING_CERTIFICATE:-$signing_certificate_pem}"
        --module-signing-pin-file "${FIXTURE_SIGNING_PIN_FILE:-$signing_pin_file}"
      )
      ;;
    key-only)
      builder_arguments+=(--module-signing-key "$signing_private_key")
      ;;
    certificate-only)
      builder_arguments+=(--module-signing-certificate "$signing_certificate_pem")
      ;;
    pin-only)
      builder_arguments+=(--module-signing-pin-file "$signing_pin_file")
      ;;
    none) ;;
    *) die "invalid signing-option fixture mode" ;;
  esac
  if [ "${FIXTURE_OFFLINE:-true}" = "true" ]; then
    builder_arguments+=(--offline)
  fi
  builder_arguments+=("$@")
  PATH="$mock_bin:/usr/bin:/bin" \
    TMPDIR="$runtime_tmp" \
    KBUILD_SIGN_PIN="$fixture_signing_pin" \
    FIXTURE_REAL_UNAME="$real_uname" \
    FIXTURE_REAL_ID="$real_id" \
    FIXTURE_REAL_INSTALL="$real_install" \
    FIXTURE_REAL_CHMOD="$real_chmod" \
    FIXTURE_REAL_PYTHON3="$real_python3" \
    FIXTURE_OPENSSL="$real_openssl" \
    FIXTURE_HOSTILE_OPENSSL_MARKER="$temporary_root/hostile-openssl-ran" \
    FIXTURE_HOSTILE_PYTHON_MARKER="$temporary_root/hostile-python-ran" \
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

for signing_mode in none key-only certificate-only pin-only; do
  if FIXTURE_SIGNING_OPTIONS="$signing_mode" run_builder "$source_seed" \
      > "$temporary_root/signing-$signing_mode.log" 2>&1; then
    die "module builder accepted incomplete controlled signing inputs: $signing_mode"
  fi
  grep -Fq 'controlled module signing requires all three signing file options' \
    "$temporary_root/signing-$signing_mode.log" ||
    die "incomplete controlled signing rejection was not explicit: $signing_mode"
  [ ! -e "$temporary_root/make-invoked" ] ||
    die "module build began with incomplete controlled signing inputs: $signing_mode"
done

invalid_signing="$temporary_root/invalid-signing"
mkdir "$invalid_signing"
chmod 0700 "$invalid_signing"
printf '%s\n' 'wrong fixture PIN' > "$invalid_signing/wrong-pin"
printf '%s\n%s\n' "$fixture_signing_pin" 'second line' > "$invalid_signing/multiline-pin"
printf 'fixture\001pin\n' > "$invalid_signing/nonprintable-pin"
chmod 0600 "$invalid_signing/wrong-pin" \
  "$invalid_signing/multiline-pin" "$invalid_signing/nonprintable-pin"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -aes-256-cbc -pass "pass:$fixture_signing_pin" \
  -out "$invalid_signing/mismatched-key.pem" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -out "$invalid_signing/unencrypted-key.pem" >/dev/null 2>&1
cp "$signing_private_key" "$invalid_signing/insecure-mode-key.pem"
cp "$signing_private_key" "$invalid_signing/hardlink-key-target.pem"
ln "$invalid_signing/hardlink-key-target.pem" "$invalid_signing/hardlink-key.pem"
ln -s "$signing_private_key" "$invalid_signing/symlink-key.pem"
{
  awk '1' "$signing_private_key"
  awk '1' "$signing_private_key"
} > "$invalid_signing/extra-key.pem"
{
  awk '1' "$signing_private_key"
  printf '%s\n' trailing
} > "$invalid_signing/trailing-key.pem"
{
  awk '1' "$signing_certificate_pem"
  awk '1' "$signing_certificate_pem"
} > "$invalid_signing/extra-certificate.pem"
{
  awk '1' "$signing_certificate_pem"
  printf '%s\n' trailing
} > "$invalid_signing/trailing-certificate.pem"
chmod 0600 "$invalid_signing/"*.pem
chmod 0644 "$invalid_signing/insecure-mode-key.pem"

expect_invalid_signing_input() {
  local label="$1" key="$2" certificate="$3" pin_file="$4" private_value="${5:-}"
  local log="$temporary_root/invalid-signing-$label.log"

  if FIXTURE_SIGNING_KEY="$key" \
      FIXTURE_SIGNING_CERTIFICATE="$certificate" \
      FIXTURE_SIGNING_PIN_FILE="$pin_file" \
      run_builder "$source_seed" > "$log" 2>&1; then
    die "module builder accepted invalid controlled signing input: $label"
  fi
  grep -Fq 'controlled module-signing' "$log" ||
    die "invalid controlled signing rejection was not explicit: $label"
  [ ! -e "$temporary_root/make-invoked" ] ||
    die "module build began with invalid controlled signing input: $label"
  if [ -n "$private_value" ] && grep -Fq "$private_value" "$log"; then
    die "invalid controlled signing rejection leaked private input: $label"
  fi
  if find "$runtime_tmp" -mindepth 1 -maxdepth 1 \
      -name 'sp11-touchscreen-signing.*' -print -quit | grep -q .; then
    die "invalid controlled signing rejection retained private staging: $label"
  fi
}

expect_invalid_signing_input wrong-pin \
  "$signing_private_key" "$signing_certificate_pem" "$invalid_signing/wrong-pin" \
  'wrong fixture PIN'
expect_invalid_signing_input mismatched-key \
  "$invalid_signing/mismatched-key.pem" "$signing_certificate_pem" "$signing_pin_file"
expect_invalid_signing_input unencrypted-key \
  "$invalid_signing/unencrypted-key.pem" "$signing_certificate_pem" "$signing_pin_file"
expect_invalid_signing_input symlink-key \
  "$invalid_signing/symlink-key.pem" "$signing_certificate_pem" "$signing_pin_file"
expect_invalid_signing_input hardlink-key \
  "$invalid_signing/hardlink-key.pem" "$signing_certificate_pem" "$signing_pin_file"
expect_invalid_signing_input insecure-key-mode \
  "$invalid_signing/insecure-mode-key.pem" "$signing_certificate_pem" "$signing_pin_file"
expect_invalid_signing_input multiline-pin \
  "$signing_private_key" "$signing_certificate_pem" "$invalid_signing/multiline-pin"
expect_invalid_signing_input nonprintable-pin \
  "$signing_private_key" "$signing_certificate_pem" "$invalid_signing/nonprintable-pin"
expect_invalid_signing_input extra-key-object \
  "$invalid_signing/extra-key.pem" "$signing_certificate_pem" "$signing_pin_file"
expect_invalid_signing_input trailing-key-bytes \
  "$invalid_signing/trailing-key.pem" "$signing_certificate_pem" "$signing_pin_file"
expect_invalid_signing_input extra-certificate-object \
  "$signing_private_key" "$invalid_signing/extra-certificate.pem" "$signing_pin_file"
expect_invalid_signing_input trailing-certificate-bytes \
  "$signing_private_key" "$invalid_signing/trailing-certificate.pem" "$signing_pin_file"

cp "$repo_dir/config/kernel-signing/sp11-module-signing-cert.pem" \
  "$builder_repo_dir/config/kernel-signing/sp11-module-signing-cert.pem"
fixture_certificate_argument="$signing_certificate_pem"
signing_certificate_pem="$builder_repo_dir/config/kernel-signing/sp11-module-signing-cert.pem"
if run_builder "$source_seed" > "$temporary_root/wrong-trust-anchor.log" 2>&1; then
  die "module builder accepted a substituted public trust anchor"
fi
signing_certificate_pem="$fixture_certificate_argument"
grep -Fq 'committed module-signing public trust anchor does not match the approved certificate identity' \
  "$temporary_root/wrong-trust-anchor.log" ||
  die "substituted public trust-anchor rejection was not explicit"
[ ! -e "$temporary_root/make-invoked" ] ||
  die "module build began with a substituted public trust anchor"
cp "$signing_certificate_pem" \
  "$builder_repo_dir/config/kernel-signing/sp11-module-signing-cert.pem"

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
expect_path_rejection source-build-root "$builder_repo_dir/build" "$safe_output" \
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
expect_path_rejection output-build-root "$path_checkout" "$builder_repo_dir/build" \
  'output directory must match repository .sp11-kmod-vN'

documented_output="$builder_repo_dir/build/release-r2-fixture-$$-touchscreen-modules"
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

nested_documented_output="$output_fixture_root/g6-k1a-touchscreen-modules"
rm -f "$temporary_root/make-invoked"
if FIXTURE_OUT_DIR="$nested_documented_output" run_builder "$path_checkout" \
    > "$temporary_root/nested-documented-output.log" 2>&1; then
  die "dedicated nested *-touchscreen-modules output unexpectedly completed"
fi
[ -s "$temporary_root/make-invoked" ] ||
  die "dedicated nested *-touchscreen-modules output was rejected before the build"
[ ! -e "$nested_documented_output" ] && [ ! -L "$nested_documented_output" ] ||
  die "failed mocked build created the dedicated nested output path"
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
grep -Fq 'controlled touchscreen module signature validation failed' \
  "$temporary_root/staged-hash.log" ||
  die "staged module signature rejection was not explicit"
[ ! -e "$staged_hash_output" ] && [ ! -L "$staged_hash_output" ] ||
  die "staged module hash failure published an output directory"
if find "$output_fixture_root" -mindepth 1 -maxdepth 1 \
    -name '.sp11-touchscreen-stage.*' -print -quit | grep -q .; then
  die "staged module validation failure left a private stage"
fi

leaf_case_index=0
for protected_leaf in \
  gpi.ko spi-geni-qcom.ko mshw0485_touch.ko \
  sp11-module-signing-cert.x509 \
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
  sp11-module-signing-cert.x509 \
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
  sp11-module-signing-cert.x509 \
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
  sp11-module-signing-cert.x509 \
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
[ "$(find "$success_output" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" -eq 5 ] ||
  die "successful atomic output does not contain exactly five files"
if find "$success_output" -mindepth 1 -maxdepth 1 ! -type f -print -quit | grep -q .; then
  die "successful atomic output contains a symlink or special entry"
fi
for success_leaf in \
  gpi.ko spi-geni-qcom.ko mshw0485_touch.ko \
  sp11-module-signing-cert.x509 \
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
cmp -s "$signing_certificate_der" \
  "$success_output/sp11-module-signing-cert.x509" ||
  die "successful atomic output changed the public signing certificate"
python3 - "$success_output/sp11-touchscreen-modules-manifest.txt" <<'PY_CHECK_SIGNING_ORDER'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
labels = [
    "Module signing policy: sp11-controlled-rsa4096-sha512-v1",
    "Module signing private material retained: false",
    "Module signing hash algorithm: sha512",
    "Module signing certificate asset: sp11-module-signing-cert.x509",
    "Module signing certificate SHA256: ",
    "Module signing certificate fingerprint: ",
    "Module signing certificate serial: ",
    "Windows SE init default: disabled",
]
for module in ("gpi.ko", "spi-geni-qcom.ko", "mshw0485_touch.ko"):
    labels.extend(
        [
            f"Module {module} size: ",
            f"Module {module} SHA256: ",
            f"Module {module} payload size: ",
            f"Module {module} payload SHA256: ",
            f"Module {module} signature size: ",
            f"Module {module} signature SHA256: ",
        ]
    )
indexes = []
for label in labels:
    matches = [
        index
        for index, line in enumerate(lines)
        if line == label or line.startswith(label)
    ]
    if len(matches) != 1:
        raise SystemExit(f"missing or duplicate controlled signing field: {label}")
    indexes.append(matches[0])
if indexes != sorted(indexes) or indexes[-1] >= lines.index("## Modules"):
    raise SystemExit("controlled signing manifest fields are not in canonical order")
PY_CHECK_SIGNING_ORDER
encrypted_private_marker='BEGIN ENCRYPTED'
encrypted_private_marker="$encrypted_private_marker PRIVATE KEY"
for private_value in \
  "$signing_private_key" \
  "$signing_certificate_der" \
  "$fixture_signing_pin" \
  "$encrypted_private_marker"; do
  if grep -Fq "$private_value" "$temporary_root/success.log" \
      "$success_output/sp11-touchscreen-modules-manifest.txt"; then
    die "module build output exposed a private signing input"
  fi
done
[ ! -e "$temporary_root/hostile-openssl-ran" ] ||
  die "module builder executed an OpenSSL binary supplied through PATH"
[ ! -e "$temporary_root/hostile-python-ran" ] ||
  die "module builder executed a Python interpreter supplied through PATH"
if find "$runtime_tmp" -mindepth 1 -maxdepth 1 \
    -name 'sp11-touchscreen-signing.*' -print -quit | grep -q .; then
  die "module builder retained a private signing stage"
fi
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
[ "$(find "$install_output" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" -eq 5 ] ||
  die "install build did not publish exactly five public release files"
grep -Fxq 'mutable public output changed during sudo' "$install_output/gpi.ko" ||
  die "private install fixture did not mutate the public output independently"

printf 'Touchscreen module source-provenance fixtures passed.\n'
