#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
product="$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh"
temporary_root=""

die() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    /tmp/sp11-controlled-signing-inner.*) rm -rf -- "$temporary_root" ;;
    *) echo "warning: refusing unexpected inner-signing fixture cleanup" >&2 ;;
  esac
}
trap cleanup EXIT

for tool in \
  awk bash chmod cmp cp grep ln mkdir mkfifo mktemp mv openssl rm sed \
  sha256sum shasum tail tr wc; do
  command -v "$tool" >/dev/null 2>&1 || die "missing fixture tool: $tool"
done
[ -f "$product" ] && [ ! -L "$product" ] ||
  die "controlled-signing inner build script is unavailable"
[ -x /usr/bin/openssl ] && [ -x /usr/bin/python3 ] ||
  die "inner-signing fixture requires fixed OpenSSL and Python authorities"

temporary_root="$(mktemp -d /tmp/sp11-controlled-signing-inner.XXXXXX)"
case "$temporary_root" in
  /tmp/sp11-controlled-signing-inner.*) ;;
  *) die "mktemp returned an unexpected inner-signing fixture path" ;;
esac
chmod 0700 "$temporary_root"

signing_root="$temporary_root/signing"
fixture_repo="$temporary_root/repo"
fixture_inputs="$temporary_root/inputs"
alternate_inputs="$temporary_root/alternate-inputs"
mkdir -p "$signing_root" \
  "$fixture_repo/config/kernel-signing" "$fixture_inputs" "$alternate_inputs"
chmod 0700 "$signing_root" "$fixture_inputs" "$alternate_inputs"

pin="$signing_root/pin"
combined_key="$signing_root/signing.pem"
certificate="$fixture_inputs/certificate.pem"
certificate_der="$fixture_inputs/certificate.der"
raw_key="$fixture_inputs/raw-key.pem"
encrypted_key="$fixture_inputs/encrypted-key.pem"
alternate_certificate="$alternate_inputs/certificate.pem"
alternate_certificate_der="$alternate_inputs/certificate.der"
alternate_raw_key="$alternate_inputs/raw-key.pem"

openssl rand -hex 24 > "$pin"
chmod 0400 "$pin"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -out "$raw_key" >/dev/null 2>&1 || die "could not create fixture RSA-4096 key"
openssl req -new -x509 -sha512 -key "$raw_key" \
  -subj /CN=sp11-controlled-signing-inner-fixture -days 2 \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -out "$certificate" >/dev/null 2>&1 || die "could not create fixture certificate"
openssl pkcs8 -topk8 -v2 aes-256-cbc -in "$raw_key" -out "$encrypted_key" \
  -passout "file:$pin" >/dev/null 2>&1 ||
  die "could not encrypt the fixture PKCS#8 key"
cp "$certificate" "$combined_key"
/bin/cat "$encrypted_key" >> "$combined_key"
chmod 0400 "$combined_key"
openssl x509 -in "$certificate" -outform DER -out "$certificate_der" \
  >/dev/null 2>&1 || die "could not encode the fixture certificate"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$alternate_raw_key" >/dev/null 2>&1 ||
  die "could not create alternate fixture key"
openssl req -new -x509 -sha512 -key "$alternate_raw_key" \
  -subj /CN=sp11-controlled-signing-inner-alternate -days 2 \
  -out "$alternate_certificate" >/dev/null 2>&1 ||
  die "could not create alternate fixture certificate"
openssl x509 -in "$alternate_certificate" -outform DER \
  -out "$alternate_certificate_der" >/dev/null 2>&1 ||
  die "could not encode the alternate fixture certificate"

certificate_text="$(openssl x509 -in "$certificate" -noout -text)"
printf '%s\n' "$certificate_text" |
  grep -F -q 'Signature Algorithm: sha512WithRSAEncryption' ||
  die "fixture certificate is not RSA/SHA-512"
printf '%s\n' "$certificate_text" |
  grep -A1 -F 'X509v3 Basic Constraints: critical' |
  grep -F -q 'CA:FALSE' || die "fixture certificate is not critical CA:false"
[ "$(printf '%s\n' "$certificate_text" |
    grep -A1 -F 'X509v3 Key Usage: critical' | tail -n 1 |
    tr -d '[:space:]')" = DigitalSignature ] ||
  die "fixture certificate key usage is not exact"
unset certificate_text

# The raw and separately encrypted fixture keys are construction intermediates;
# only the cert-first encrypted bridge input remains for the product checks.
rm -f -- "$raw_key" "$encrypted_key" "$alternate_raw_key"

encrypted_private_marker='-----BEGIN ENCRYPTED '"PRIVATE KEY-----"
plain_private_marker='-----BEGIN '"PRIVATE KEY-----"
[ "$(grep -F -c -- "$encrypted_private_marker" "$combined_key")" -eq 1 ] ||
  die "fixture bridge does not contain one encrypted PKCS#8 key"
if grep -F -q -- "$plain_private_marker" "$combined_key"; then
  die "fixture bridge retained an unencrypted private key"
fi
[ "$(sed -n '1p' "$combined_key")" = "-----BEGIN CERTIFICATE-----" ] ||
  die "fixture bridge is not certificate-first"

committed_certificate="$fixture_repo/config/kernel-signing/sp11-module-signing-cert.pem"
cp "$certificate" "$committed_certificate"
chmod 0644 "$committed_certificate"

certificate_sha256="$(shasum -a 256 "$certificate_der" | awk '{print $1}')"
certificate_fingerprint="$(/usr/bin/openssl x509 -inform DER \
  -in "$certificate_der" -noout -sha256 -fingerprint)"
certificate_fingerprint="${certificate_fingerprint#*=}"
certificate_fingerprint="$(printf '%s' "$certificate_fingerprint" |
  tr '[:lower:]' '[:upper:]')"
certificate_serial="$(/usr/bin/openssl x509 -inform DER \
  -in "$certificate_der" -noout -serial)"
certificate_serial="$(printf '%s' "${certificate_serial#*=}" |
  tr '[:lower:]' '[:upper:]')"
IFS= read -r pin_value < "$pin"
[ -n "$pin_value" ] || die "fixture PIN is empty"

extract_function() {
  local name="$1" destination="$2"
  sed -n "/^${name}() {\$/,/^}\$/p" "$product" > "$destination"
  [ "$(grep -c "^${name}() {\$" "$destination")" -eq 1 ] ||
    die "could not extract exact product function: $name"
  [ "$(tail -n 1 "$destination")" = "}" ] ||
    die "product function extraction is incomplete: $name"
}

private_functions="$temporary_root/private-functions.sh"
public_functions="$temporary_root/public-functions.sh"
extracted_functions="$temporary_root/extracted-functions.sh"
extract_function validate_controlled_module_signing_input "$private_functions"
: > "$public_functions"
for function_name in \
  add_release_output \
  capture_signing_certificate_identity \
  validate_release_module_signing_config \
  capture_release_build_outputs \
  verify_release_module_signing_state_stable \
  build_kernel; do
  extracted="$temporary_root/$function_name.sh"
  extract_function "$function_name" "$extracted"
  /bin/cat "$extracted" >> "$public_functions"
  printf '\n' >> "$public_functions"
done

/usr/bin/python3 -I - \
  "$private_functions" "$public_functions" "$extracted_functions" \
  "$signing_root" "$fixture_repo" <<'PY_REWRITE_MOUNTS'
from pathlib import Path
import re
import sys

private_path, public_path, output_path, signing_root, fixture_repo = sys.argv[1:]
for value in (signing_root, fixture_repo):
    if re.fullmatch(r"/[A-Za-z0-9._/-]+", value) is None:
        raise SystemExit("unsafe fixture mount replacement")

private = Path(private_path).read_text(encoding="utf-8")
public = Path(public_path).read_text(encoding="utf-8")
if "/sp11-signing" not in private or '"/repo/' not in private:
    raise SystemExit("private bridge function lost its fixed mount contract")
if 'local committed="/repo/' not in public:
    raise SystemExit("certificate function lost its committed-certificate mount")
if 'CONFIG_MODULE_SIG_KEY="/sp11-signing/signing.pem"' not in public:
    raise SystemExit("config validator lost its reviewed logical key path")

private = private.replace("/sp11-signing", signing_root)
private = private.replace('"/repo/', f'"{fixture_repo}/')
public = public.replace('local committed="/repo/', f'local committed="{fixture_repo}/')
Path(output_path).write_text(private + "\n" + public, encoding="utf-8")
PY_REWRITE_MOUNTS

# shellcheck source=/dev/null
source "$extracted_functions"

require_tool() {
  command -v "$1" >/dev/null 2>&1
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

expect_failure() {
  local label="$1"
  shift
  if ( "$@" ) >"$temporary_root/rejected.out" 2>&1; then
    die "$label was accepted"
  fi
}

expect_failure_with_diagnostic() {
  local label="$1" diagnostic="$2"
  shift 2
  if ( "$@" ) >"$temporary_root/rejected.out" 2>&1; then
    die "$label was accepted"
  fi
  grep -F -q -- "$diagnostic" "$temporary_root/rejected.out" ||
    die "$label failed without its intended product diagnostic"
}

BASELINE_MODULE_SIGNING_CERT_PATH="config/kernel-signing/sp11-module-signing-cert.pem"
BASELINE_MODULE_SIGNING_CERT_SHA256="$certificate_sha256"
BASELINE_MODULE_SIGNING_CERT_FINGERPRINT="$certificate_fingerprint"
BASELINE_MODULE_SIGNING_CERT_SERIAL="$certificate_serial"
BASELINE_MODULE_SIGNING_PIN_PATH="$pin"
KERNEL_TREE_VALIDATOR_PYTHON=/usr/bin/python3
RELEASE_BUILD=true
RELEASE_TEST_FIXTURE_CONTEXT=false

unset KBUILD_SIGN_PIN
validate_controlled_module_signing_input
[ -z "${KBUILD_SIGN_PIN+x}" ] ||
  die "private-input validation exported the signing PIN"

good_pin="$temporary_root/good-pin"
cp "$pin" "$good_pin"
chmod 0400 "$good_pin"
chmod 0600 "$pin"
printf '%s\n' wrong-fixture-pin > "$pin"
chmod 0400 "$pin"
expect_failure_with_diagnostic \
  "incorrect bridge PIN" \
  "Controlled module-signing PIN did not unlock the encrypted private key." \
  validate_controlled_module_signing_input
mv "$good_pin" "$pin"
chmod 0400 "$pin"

write_valid_config() {
  local destination="$1"
  {
    printf '%s\n' \
      'CONFIG_ARM64=y' \
      'CONFIG_MODULE_SIG=y' \
      'CONFIG_MODULE_SIG_ALL=y' \
      '# CONFIG_MODULE_SIG_FORCE is not set' \
      'CONFIG_MODULE_SIG_HASH="sha512"' \
      'CONFIG_MODULE_SIG_KEY="/sp11-signing/signing.pem"' \
      'CONFIG_VERSION_SIGNATURE="Ubuntu 7.2-rc5-jg-0sp11v3r2-qcom-x1e 7.2-rc5"' \
      'CONFIG_LOCALVERSION=""'
  } > "$destination"
  chmod 0644 "$destination"
}

make_valid_build_tree() {
  local root="$1" build_root
  build_root="$root/debian/build/build-qcom-x1e"
  mkdir -p \
    "$build_root/certs" \
    "$build_root/arch/arm64/boot/dts/qcom"
  write_valid_config "$build_root/.config"
  printf 'module symvers fixture\n' > "$build_root/Module.symvers"
  printf 'system map fixture\n' > "$build_root/System.map"
  printf 'EFI stubble fixture\n' > "$build_root/arch/arm64/boot/vmlinuz.efi.stubble"
  printf 'denali OLED DTB fixture\n' > \
    "$build_root/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled.dtb"
  printf 'denali OLED EL2 DTB fixture\n' > \
    "$build_root/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled-el2.dtb"
  cp "$certificate_der" "$build_root/certs/signing_key.x509"
  chmod 0644 "$build_root/certs/signing_key.x509"
}

reset_captured_signing_state() {
  RELEASE_OUTPUT_ROLES=()
  RELEASE_OUTPUT_PATHS=()
  RELEASE_OUTPUT_SIZES=()
  RELEASE_OUTPUT_SHA256S=()
  SIGNING_CONFIG_SIZE=""
  SIGNING_CONFIG_SHA256=""
  SIGNING_CERT_SIZE=""
  SIGNING_CERT_SHA256=""
  SIGNING_CERT_FINGERPRINT=""
  SIGNING_CERT_SERIAL=""
}

valid_tree="$temporary_root/valid-tree"
make_valid_build_tree "$valid_tree"
source_dir="$valid_tree"
validate_release_module_signing_config

expected_config_lines=(
  'CONFIG_MODULE_SIG=y'
  'CONFIG_MODULE_SIG_ALL=y'
  '# CONFIG_MODULE_SIG_FORCE is not set'
  'CONFIG_MODULE_SIG_HASH="sha512"'
  'CONFIG_MODULE_SIG_KEY="/sp11-signing/signing.pem"'
  'CONFIG_VERSION_SIGNATURE="Ubuntu 7.2-rc5-jg-0sp11v3r2-qcom-x1e 7.2-rc5"'
)
conflicting_config_lines=(
  '# CONFIG_MODULE_SIG is not set'
  '# CONFIG_MODULE_SIG_ALL is not set'
  'CONFIG_MODULE_SIG_FORCE=y'
  'CONFIG_MODULE_SIG_HASH="sha256"'
  'CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"'
  'CONFIG_VERSION_SIGNATURE="unreviewed fixture"'
)

config_index=0
while [ "$config_index" -lt "${#expected_config_lines[@]}" ]; do
  missing_tree="$temporary_root/config-missing-$config_index"
  make_valid_build_tree "$missing_tree"
  awk -v removed="${expected_config_lines[$config_index]}" \
    '$0 != removed' \
    "$missing_tree/debian/build/build-qcom-x1e/.config" > \
    "$missing_tree/debian/build/build-qcom-x1e/.config.without-reviewed-line"
  mv "$missing_tree/debian/build/build-qcom-x1e/.config.without-reviewed-line" \
    "$missing_tree/debian/build/build-qcom-x1e/.config"
  chmod 0644 "$missing_tree/debian/build/build-qcom-x1e/.config"
  source_dir="$missing_tree"
  expect_failure_with_diagnostic \
    "missing controlled config symbol $config_index" \
    "${expected_config_lines[$config_index]}" \
    validate_release_module_signing_config

  duplicate_tree="$temporary_root/config-duplicate-$config_index"
  make_valid_build_tree "$duplicate_tree"
  printf '%s\n' "${expected_config_lines[$config_index]}" >> \
    "$duplicate_tree/debian/build/build-qcom-x1e/.config"
  source_dir="$duplicate_tree"
  expect_failure_with_diagnostic \
    "duplicate controlled config symbol $config_index" \
    "${expected_config_lines[$config_index]}" \
    validate_release_module_signing_config

  conflict_tree="$temporary_root/config-conflict-$config_index"
  make_valid_build_tree "$conflict_tree"
  printf '%s\n' "${conflicting_config_lines[$config_index]}" >> \
    "$conflict_tree/debian/build/build-qcom-x1e/.config"
  source_dir="$conflict_tree"
  expect_failure_with_diagnostic \
    "conflicting controlled config symbol $config_index" \
    "${expected_config_lines[$config_index]}" \
    validate_release_module_signing_config
  config_index=$((config_index + 1))
done

regular_private_tree="$temporary_root/regular-private-tree"
make_valid_build_tree "$regular_private_tree"
printf '%s\n' "$plain_private_marker" > \
  "$regular_private_tree/debian/build/build-qcom-x1e/certs/signing_key.pem"
source_dir="$regular_private_tree"
expect_failure_with_diagnostic \
  "regular generated or copied signing_key.pem" \
  "Release build retained a generated or copied private module-signing key." \
  validate_release_module_signing_config

symlink_private_tree="$temporary_root/symlink-private-tree"
make_valid_build_tree "$symlink_private_tree"
ln -s missing-private-key \
  "$symlink_private_tree/debian/build/build-qcom-x1e/certs/signing_key.pem"
source_dir="$symlink_private_tree"
expect_failure_with_diagnostic \
  "symlinked generated or copied signing_key.pem" \
  "Release build retained a generated or copied private module-signing key." \
  validate_release_module_signing_config

source_dir="$valid_tree"
reset_captured_signing_state
capture_release_build_outputs
[ "${#RELEASE_OUTPUT_ROLES[@]}" -eq 7 ] ||
  die "initial capture did not retain the exact seven-output contract"
[ "$SIGNING_CONFIG_SHA256" = "$(sha256_file \
    "$valid_tree/debian/build/build-qcom-x1e/.config")" ] ||
  die "captured config identity is false"
[ "$SIGNING_CERT_SHA256" = "$certificate_sha256" ] ||
  die "captured certificate identity is false"
verify_release_module_signing_state_stable

wrong_built_tree="$temporary_root/wrong-built-certificate"
make_valid_build_tree "$wrong_built_tree"
cp "$alternate_certificate_der" \
  "$wrong_built_tree/debian/build/build-qcom-x1e/certs/signing_key.x509"
source_dir="$wrong_built_tree"
reset_captured_signing_state
expect_failure_with_diagnostic \
  "different self-consistent built certificate" \
  "Built module-signing certificate identity does not match the release baseline." \
  capture_release_build_outputs

pem_built_tree="$temporary_root/pem-built-certificate"
make_valid_build_tree "$pem_built_tree"
cp "$certificate" "$pem_built_tree/debian/build/build-qcom-x1e/certs/signing_key.x509"
source_dir="$pem_built_tree"
reset_captured_signing_state
expect_failure_with_diagnostic \
  "non-DER built certificate" \
  "Built module-signing certificate could not be validated safely." \
  capture_release_build_outputs

symlink_built_tree="$temporary_root/symlink-built-certificate"
make_valid_build_tree "$symlink_built_tree"
mv "$symlink_built_tree/debian/build/build-qcom-x1e/certs/signing_key.x509" \
  "$symlink_built_tree/debian/build/build-qcom-x1e/certs/signing_key.x509.real"
ln -s signing_key.x509.real \
  "$symlink_built_tree/debian/build/build-qcom-x1e/certs/signing_key.x509"
source_dir="$symlink_built_tree"
reset_captured_signing_state
expect_failure_with_diagnostic \
  "symlinked built certificate" \
  "Required release build output is missing, empty, or not a regular file:" \
  capture_release_build_outputs

fifo_built_tree="$temporary_root/fifo-built-certificate"
make_valid_build_tree "$fifo_built_tree"
rm -f -- "$fifo_built_tree/debian/build/build-qcom-x1e/certs/signing_key.x509"
mkfifo "$fifo_built_tree/debian/build/build-qcom-x1e/certs/signing_key.x509"
source_dir="$fifo_built_tree"
reset_captured_signing_state
expect_failure_with_diagnostic \
  "FIFO built certificate" \
  "Required release build output is missing, empty, or not a regular file:" \
  capture_release_build_outputs

hostile_openssl_tree="$temporary_root/hostile-openssl-environment"
make_valid_build_tree "$hostile_openssl_tree"
printf '%s\n' 'this is intentionally not an OpenSSL configuration' > \
  "$temporary_root/hostile-openssl.cnf"
mkdir "$temporary_root/hostile-openssl-modules"
source_dir="$hostile_openssl_tree"
reset_captured_signing_state
(
  export OPENSSL_CONF="$temporary_root/hostile-openssl.cnf"
  export OPENSSL_MODULES="$temporary_root/hostile-openssl-modules"
  capture_release_build_outputs
) || die "built-certificate authority consumed hostile ambient OpenSSL settings"

committed_backup="$temporary_root/committed-certificate-backup.pem"
cp "$committed_certificate" "$committed_backup"
cp "$alternate_certificate" "$committed_certificate"
source_dir="$valid_tree"
reset_captured_signing_state
expect_failure_with_diagnostic \
  "different committed public certificate" \
  "Built module-signing certificate differs from the committed public certificate." \
  capture_release_build_outputs
mv "$committed_backup" "$committed_certificate"
chmod 0644 "$committed_certificate"

late_config_tree="$temporary_root/late-config-tree"
make_valid_build_tree "$late_config_tree"
source_dir="$late_config_tree"
reset_captured_signing_state
capture_release_build_outputs
printf '%s\n' 'CONFIG_MODULE_SIG_HASH="sha256"' >> \
  "$late_config_tree/debian/build/build-qcom-x1e/.config"
expect_failure_with_diagnostic \
  "late controlled config mutation" \
  'CONFIG_MODULE_SIG_HASH="sha512"' \
  verify_release_module_signing_state_stable

late_certificate_tree="$temporary_root/late-certificate-tree"
make_valid_build_tree "$late_certificate_tree"
source_dir="$late_certificate_tree"
reset_captured_signing_state
capture_release_build_outputs
cp "$alternate_certificate_der" \
  "$late_certificate_tree/debian/build/build-qcom-x1e/certs/signing_key.x509"
expect_failure_with_diagnostic \
  "late built-certificate replacement" \
  "Built module-signing certificate identity does not match the release baseline." \
  verify_release_module_signing_state_stable

late_private_tree="$temporary_root/late-private-tree"
make_valid_build_tree "$late_private_tree"
source_dir="$late_private_tree"
reset_captured_signing_state
capture_release_build_outputs
printf '%s\n' "$plain_private_marker" > \
  "$late_private_tree/debian/build/build-qcom-x1e/certs/signing_key.pem"
expect_failure_with_diagnostic \
  "late private-key creation" \
  "Release build retained a generated or copied private module-signing key." \
  verify_release_module_signing_state_stable

late_private_symlink_tree="$temporary_root/late-private-symlink-tree"
make_valid_build_tree "$late_private_symlink_tree"
source_dir="$late_private_symlink_tree"
reset_captured_signing_state
capture_release_build_outputs
ln -s missing-late-private-key \
  "$late_private_symlink_tree/debian/build/build-qcom-x1e/certs/signing_key.pem"
expect_failure_with_diagnostic \
  "late private-key symlink creation" \
  "Release build retained a generated or copied private module-signing key." \
  verify_release_module_signing_state_stable

late_output_binding_tree="$temporary_root/late-output-binding-tree"
make_valid_build_tree "$late_output_binding_tree"
source_dir="$late_output_binding_tree"
reset_captured_signing_state
capture_release_build_outputs
output_index=0
while [ "$output_index" -lt "${#RELEASE_OUTPUT_ROLES[@]}" ]; do
  if [ "${RELEASE_OUTPUT_ROLES[$output_index]}" = module-signing-certificate ]; then
    RELEASE_OUTPUT_SHA256S[$output_index]="$(printf '0%.0s' {1..64})"
    break
  fi
  output_index=$((output_index + 1))
done
[ "$output_index" -lt "${#RELEASE_OUTPUT_ROLES[@]}" ] ||
  die "captured certificate role is absent"
expect_failure_with_diagnostic \
  "late captured-output binding mutation" \
  "Captured module-signing certificate changed before publication." \
  verify_release_module_signing_state_stable

rules_log="$temporary_root/rules.log"
fixture_rules_file="$temporary_root/debian-rules"
FAIL_RULE_TARGET=""
: > "$fixture_rules_file"
chmod 0700 "$fixture_rules_file"

find_rules_file() {
  printf '%s\n' "$fixture_rules_file"
}

run_rules() {
  local invoked_rules="$1" target="$2"
  [ "$invoked_rules" = "$fixture_rules_file" ] || return 71
  case "$target" in
    clean)
      [ -z "${KBUILD_SIGN_PIN+x}" ] || return 72
      printf '%s\n' 'clean:pin-absent' >> "$rules_log"
      ;;
    binary-indep|binary-qcom-x1e)
      [ "${KBUILD_SIGN_PIN+x}" = x ] || return 73
      [ "$KBUILD_SIGN_PIN" = "$pin_value" ] || return 74
      if [ "$FAIL_RULE_TARGET" = "$target" ]; then
        printf '%s\n' "$target:pin-present-before-failure" >> "$rules_log"
        return 76
      fi
      printf '%s\n' "$target:pin-present" >> "$rules_log"
      ;;
    *) return 75 ;;
  esac
}

source_dir="$valid_tree"
BUILD_TARGET="binary-indep binary-qcom-x1e"
JOBS=2
SKIP_CLEAN=false
BASELINE_MODULE_SIGNING_PIN_PATH="$pin"
unset KBUILD_SIGN_PIN
FAIL_RULE_TARGET=binary-qcom-x1e
: > "$rules_log"
set +e
(
  set -e
  build_kernel
) >"$temporary_root/target-failure.out" 2>&1
target_failure_status=$?
set -e
[ "$target_failure_status" -eq 76 ] ||
  die "second rules-target failure did not preserve its exact status"
[ -z "${KBUILD_SIGN_PIN+x}" ] ||
  die "failed build subshell leaked KBUILD_SIGN_PIN"
[ "$(/bin/cat "$rules_log")" = $'clean:pin-absent\nbinary-indep:pin-present\nbinary-qcom-x1e:pin-present-before-failure' ] ||
  die "failed rules target did not observe the exact isolated PIN lifecycle"
if grep -F -q -- "$pin_value" \
    "$rules_log" "$temporary_root/target-failure.out"; then
  die "failed rules target logged its signing PIN"
fi

FAIL_RULE_TARGET=""
: > "$rules_log"
build_kernel
[ -z "${KBUILD_SIGN_PIN+x}" ] || die "build subshell leaked KBUILD_SIGN_PIN"
[ "$(/bin/cat "$rules_log")" = $'clean:pin-absent\nbinary-indep:pin-present\nbinary-qcom-x1e:pin-present' ] ||
  die "rules targets did not observe the exact isolated PIN lifecycle"

public_output="$temporary_root/public-output"
mkdir "$public_output"
cp "$valid_tree/debian/build/build-qcom-x1e/.config" "$public_output/kernel.config"
cp "$valid_tree/debian/build/build-qcom-x1e/certs/signing_key.x509" \
  "$public_output/signing-certificate.x509"
cp "$rules_log" "$public_output/rules-observations.txt"
[ -z "${KBUILD_SIGN_PIN+x}" ] || die "public report inherited KBUILD_SIGN_PIN"
{
  printf '%s\n' \
    'Controlled module-signing inner fixture report' \
    'Module signing policy: sp11-controlled-rsa4096-sha512-v1' \
    'Module signing private material retained: false' \
    "Signing certificate SHA256: $SIGNING_CERT_SHA256" \
    "Signing certificate fingerprint: $SIGNING_CERT_FINGERPRINT" \
    "Signing certificate serial: $SIGNING_CERT_SERIAL" \
    'Validation completed: true'
} > "$public_output/public-report.txt"

/usr/bin/python3 -I - "$public_output" "$pin" "$temporary_root" \
  "$encrypted_private_marker" "$plain_private_marker" <<'PY_ASSERT_PUBLIC_OUTPUT'
from pathlib import Path
import sys

root = Path(sys.argv[1])
pin = Path(sys.argv[2]).read_bytes().removesuffix(b"\n")
needles = [pin, *(value.encode() for value in sys.argv[3:] if value)]
for path in sorted(root.rglob("*")):
    if not path.is_file() or path.is_symlink():
        raise SystemExit("public output contains a non-regular entry")
    data = path.read_bytes()
    if any(needle in data for needle in needles):
        raise SystemExit("public output retained private signing material or fixture paths")
if any(path.name == "signing_key.pem" for path in root.rglob("*")):
    raise SystemExit("public output retained a private signing-key filename")
PY_ASSERT_PUBLIC_OUTPUT
if grep -Fq '/sp11-signing/' "$public_output/public-report.txt"; then
  die "public report retained the private logical signing path"
fi

/usr/bin/python3 -I - "$product" <<'PY_ASSERT_PRODUCT_ORDER'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
if len(re.findall(r"(?m)^unset KBUILD_SIGN_PIN$", text)) != 1:
    raise SystemExit("product startup does not unset KBUILD_SIGN_PIN exactly once")
unset_at = text.index("unset KBUILD_SIGN_PIN")
argument_loop = text.index('while [ "$#" -gt 0 ]; do')
if unset_at >= argument_loop:
    raise SystemExit("product does not clear KBUILD_SIGN_PIN before argument handling")
late = text.rfind("verify_release_module_signing_state_stable || exit 1")
report = text.rfind("verify_kernel_module_signature_report_stable || exit 1", 0, late)
commit = text.rfind("publication_committed=true")
if min(late, report, commit) < 0 or not report < late < commit:
    raise SystemExit("late signing revalidation is not at the publication boundary")
PY_ASSERT_PRODUCT_ORDER

printf 'Controlled module-signing inner bridge fixtures passed.\n'
