#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
validator="$repo_dir/scripts/validate-sp11-signed-modules.py"
product_validator="$validator"
temporary_root=""
temporary_parent=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "$temporary_parent"/sp11-controlled-signing.*) rm -rf -- "$temporary_root" ;;
    *) echo "warning: refusing to remove unexpected signing fixture path" >&2 ;;
  esac
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

for tool in openssl python3 mktemp mkfifo grep cp ln; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done
[ -f "$validator" ] && [ ! -L "$validator" ] || fail "signed-module validator is unavailable"

temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root="$(mktemp -d "$temporary_parent/sp11-controlled-signing.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
chmod 0700 "$temporary_root"

make_certificate() {
  local directory="$1" bits="$2" serial="$3"
  local basic_constraints="${4:-critical,CA:FALSE}"
  local key_usage="${5:-critical,digitalSignature}"
  mkdir -p "$directory"
  chmod 0700 "$directory"
  if ! openssl req -new -x509 -newkey "rsa:$bits" -nodes -sha512 \
      -subj '/CN=SP11 controlled signing fixture/' -set_serial "$serial" \
      -addext "basicConstraints=$basic_constraints" \
      -addext "keyUsage=$key_usage" \
      -days 2 -keyout "$directory/private-key.pem" \
      -out "$directory/certificate.pem" >/dev/null 2>&1; then
    fail "could not create controlled signing fixture certificate"
  fi
  chmod 0600 "$directory/private-key.pem"
  openssl x509 -in "$directory/certificate.pem" -outform DER \
    -out "$directory/sp11-module-signing-cert.x509" >/dev/null 2>&1 ||
    fail "could not encode controlled signing fixture certificate"
}

sign_module() {
  local directory="$1" module="$2" digest="${3:-sha512}" cms_flags="${4:--noattr -nocerts}"
  local payload="$directory/$module.payload" signature="$directory/$module.signature"
  printf 'ELF fixture payload for %s\n' "$module" > "$payload"
  # shellcheck disable=SC2086
  if ! openssl cms -sign -binary -in "$payload" \
      -signer "$directory/certificate.pem" -inkey "$directory/private-key.pem" \
      -md "$digest" $cms_flags -outform DER -out "$signature" >/dev/null 2>&1; then
    fail "could not create controlled module signature fixture"
  fi
  python3 - "$payload" "$signature" "$directory/$module" <<'PY_APPEND_SIGNATURE'
import pathlib
import struct
import sys

payload = pathlib.Path(sys.argv[1]).read_bytes()
signature = pathlib.Path(sys.argv[2]).read_bytes()
descriptor = struct.pack(">BBBBB3sI", 0, 0, 2, 0, 0, b"\0\0\0", len(signature))
pathlib.Path(sys.argv[3]).write_bytes(
    payload + signature + descriptor + b"~Module signature appended~\n"
)
PY_APPEND_SIGNATURE
}

sign_bundle() {
  local directory="$1" digest="${2:-sha512}" cms_flags="${3:--noattr -nocerts}"
  local module
  for module in gpi.ko spi-geni-qcom.ko mshw0485_touch.ko; do
    sign_module "$directory" "$module" "$digest" "$cms_flags"
  done
}

validator_arguments() {
  local directory="$1"
  printf '%s\0' \
    --certificate "$directory/sp11-module-signing-cert.x509" \
    --module "$directory/gpi.ko" \
    --module "$directory/spi-geni-qcom.ko" \
    --module "$directory/mshw0485_touch.ko"
}

run_validator() {
  local directory="$1"
  shift
  local arguments=()
  while IFS= read -r -d '' argument; do arguments+=("$argument"); done \
    < <(validator_arguments "$directory")
  python3 -I "$validator" "${arguments[@]}" "$@"
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$temporary_root/rejected.out" 2>&1; then
    fail "$label was accepted"
  fi
}

good="$temporary_root/good"
make_certificate "$good" 4096 0x1001
sign_bundle "$good"
expect_failure "self-consistent unapproved certificate bundle" run_validator "$good"
fixture_certificate_sha256="$(
  openssl dgst -sha256 "$good/sp11-module-signing-cert.x509" | awk '{print $NF}'
)"
validator="$temporary_root/fixture-validate-sp11-signed-modules.py"
cp "$product_validator" "$validator"
python3 - "$validator" "$fixture_certificate_sha256" <<'PY_BIND_FIXTURE_CERTIFICATE'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
reviewed = b"8ad9b402339b5ceff8e7fc9dfcc7dd368b2466fce0e90d97553059bcdc66e99b"
replacement = sys.argv[2].encode("ascii")
if data.count(reviewed) != 1:
    raise SystemExit("fixture validator did not contain one reviewed certificate identity")
path.write_bytes(data.replace(reviewed, replacement))
PY_BIND_FIXTURE_CERTIFICATE
chmod 0755 "$validator"
report="$(run_validator "$good")" || fail "valid controlled module bundle was rejected"
grep -Fxq 'Module signing policy: sp11-controlled-rsa4096-sha512-v1' <<<"$report" ||
  fail "signature report omitted the controlled policy"
grep -Fxq 'Module signing private material retained: false' <<<"$report" ||
  fail "signature report omitted the private-material retention declaration"
grep -Fxq 'Module signing hash algorithm: sha512' <<<"$report" ||
  fail "signature report omitted the SHA-512 contract"

{
  printf '%s\n' '# Surface Pro 11 Touchscreen Module Build Manifest' ''
  printf '%s\n' "$report"
  printf '\n## Modules\n\n- gpi.ko\n- spi-geni-qcom.ko\n- mshw0485_touch.ko\n'
} > "$good/sp11-touchscreen-modules-manifest.txt"
run_validator "$good" --manifest "$good/sp11-touchscreen-modules-manifest.txt" >/dev/null ||
  fail "valid controlled module manifest was rejected"

unsigned="$temporary_root/unsigned"
cp -R "$good" "$unsigned"
printf 'unsigned module\n' > "$unsigned/gpi.ko"
expect_failure "unsigned module" run_validator "$unsigned"

payload_tamper="$temporary_root/payload-tamper"
cp -R "$good" "$payload_tamper"
python3 - "$payload_tamper/gpi.ko" <<'PY_TAMPER_PAYLOAD'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[0] ^= 1
path.write_bytes(data)
PY_TAMPER_PAYLOAD
expect_failure "tampered signed payload" run_validator "$payload_tamper"

signature_tamper="$temporary_root/signature-tamper"
cp -R "$good" "$signature_tamper"
python3 - "$signature_tamper/gpi.ko" <<'PY_TAMPER_SIGNATURE'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
marker = b"~Module signature appended~\n"
info = len(data) - len(marker) - 12
length = struct.unpack(">BBBBB3sI", data[info : info + 12])[-1]
data[info - length + 20] ^= 1
path.write_bytes(data)
PY_TAMPER_SIGNATURE
expect_failure "tampered CMS signature" run_validator "$signature_tamper"

wrong_certificate_source="$temporary_root/wrong-certificate-source"
make_certificate "$wrong_certificate_source" 4096 0x1002
wrong_certificate="$temporary_root/wrong-certificate"
cp -R "$good" "$wrong_certificate"
cp "$wrong_certificate_source/sp11-module-signing-cert.x509" \
  "$wrong_certificate/sp11-module-signing-cert.x509"
expect_failure "wrong public certificate" run_validator "$wrong_certificate"

wrong_digest="$temporary_root/wrong-digest"
make_certificate "$wrong_digest" 4096 0x1003
sign_bundle "$wrong_digest" sha256
expect_failure "SHA-256 CMS signature" run_validator "$wrong_digest"

weak_key="$temporary_root/weak-key"
make_certificate "$weak_key" 2048 0x1004
sign_bundle "$weak_key"
expect_failure "RSA-2048 certificate" run_validator "$weak_key"

ca_certificate="$temporary_root/ca-certificate"
make_certificate "$ca_certificate" 4096 0x1007 critical,CA:TRUE critical,digitalSignature
sign_bundle "$ca_certificate"
expect_failure "CA-capable module certificate" run_validator "$ca_certificate"

wrong_key_usage="$temporary_root/wrong-key-usage"
make_certificate "$wrong_key_usage" 4096 0x1008 critical,CA:FALSE critical,keyEncipherment
sign_bundle "$wrong_key_usage"
expect_failure "module certificate without Digital Signature usage" run_validator "$wrong_key_usage"

noncritical_key_usage="$temporary_root/noncritical-key-usage"
make_certificate "$noncritical_key_usage" 4096 0x1009 critical,CA:FALSE digitalSignature
sign_bundle "$noncritical_key_usage"
expect_failure "noncritical module certificate key usage" run_validator "$noncritical_key_usage"

embedded_certificate="$temporary_root/embedded-certificate"
make_certificate "$embedded_certificate" 4096 0x1005
sign_bundle "$embedded_certificate" sha512 -noattr
expect_failure "embedded CMS certificate" run_validator "$embedded_certificate"

signed_attributes="$temporary_root/signed-attributes"
make_certificate "$signed_attributes" 4096 0x1006
sign_bundle "$signed_attributes" sha512 -nocerts
expect_failure "CMS signed attributes" run_validator "$signed_attributes"

bad_descriptor="$temporary_root/bad-descriptor"
cp -R "$good" "$bad_descriptor"
python3 - "$bad_descriptor/gpi.ko" <<'PY_TAMPER_DESCRIPTOR'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[-39] = 1
path.write_bytes(data)
PY_TAMPER_DESCRIPTOR
expect_failure "non-canonical module signature descriptor" run_validator "$bad_descriptor"

trailing_data="$temporary_root/trailing-data"
cp -R "$good" "$trailing_data"
printf 'x' >> "$trailing_data/gpi.ko"
expect_failure "bytes after terminal module signature marker" run_validator "$trailing_data"

symlink_module="$temporary_root/symlink-module"
cp -R "$good" "$symlink_module"
mv "$symlink_module/gpi.ko" "$symlink_module/gpi.ko.real"
ln -s gpi.ko.real "$symlink_module/gpi.ko"
expect_failure "symlinked module" run_validator "$symlink_module"

symlink_parent="$temporary_root/symlink-parent"
ln -s "$good" "$symlink_parent"
expect_failure "symlinked bundle parent" run_validator "$symlink_parent"
expect_failure "double-slash bundle root" run_validator "/$good"

root_swap="$temporary_root/root-swap"
root_swap_replacement="$temporary_root/root-swap-replacement"
root_swap_held="$temporary_root/root-swap-held"
root_swap_triggered="$temporary_root/root-swap-triggered"
cp -R "$good" "$root_swap"
cp -R "$good" "$root_swap_replacement"
chmod 0700 "$root_swap" "$root_swap_replacement"
chmod 0600 "$root_swap_replacement/gpi.ko"
printf 'invalid replacement module\n' > "$root_swap_replacement/gpi.ko"
chmod 0400 "$root_swap_replacement/gpi.ko"
set +e
run_validator "$root_swap" > "$temporary_root/root-swap.out" 2>&1 &
root_swap_pid=$!
sleep 0.05
if mv "$root_swap" "$root_swap_held" && mv "$root_swap_replacement" "$root_swap"; then
  printf '%s\n' triggered > "$root_swap_triggered"
fi
wait "$root_swap_pid"
root_swap_status=$?
set -e
[ -f "$root_swap_triggered" ] || fail "bundle root substitution fixture did not trigger"
[ -d "$root_swap_held" ] && [ -d "$root_swap" ] ||
  fail "bundle root substitution fixture did not retain both directory identities"
[ "$root_swap_status" -ne 0 ] || fail "bundle root substitution was accepted"

hardlinked_module="$temporary_root/hardlinked-module"
cp -R "$good" "$hardlinked_module"
chmod 0700 "$hardlinked_module"
rm "$hardlinked_module/gpi.ko"
cp "$good/gpi.ko" "$temporary_root/hardlink-source.ko"
ln "$temporary_root/hardlink-source.ko" "$hardlinked_module/gpi.ko"
expect_failure "hardlinked module input" run_validator "$hardlinked_module"

writable_root="$temporary_root/writable-root"
cp -R "$good" "$writable_root"
chmod 0777 "$writable_root"
expect_failure "group- and world-writable bundle root" run_validator "$writable_root"

fifo_module="$temporary_root/fifo-module"
cp -R "$good" "$fifo_module"
rm "$fifo_module/gpi.ko"
mkfifo "$fifo_module/gpi.ko"
expect_failure "FIFO module input" run_validator "$fifo_module"

fifo_certificate="$temporary_root/fifo-certificate"
cp -R "$good" "$fifo_certificate"
rm "$fifo_certificate/sp11-module-signing-cert.x509"
mkfifo "$fifo_certificate/sp11-module-signing-cert.x509"
expect_failure "FIFO certificate input" run_validator "$fifo_certificate"

fifo_manifest="$temporary_root/fifo-manifest"
cp -R "$good" "$fifo_manifest"
rm "$fifo_manifest/sp11-touchscreen-modules-manifest.txt"
mkfifo "$fifo_manifest/sp11-touchscreen-modules-manifest.txt"
expect_failure "FIFO manifest input" run_validator "$fifo_manifest" \
  --manifest "$fifo_manifest/sp11-touchscreen-modules-manifest.txt"

hostile_bin="$temporary_root/hostile-bin"
hostile_marker="$temporary_root/hostile-openssl-ran"
mkdir "$hostile_bin"
cat > "$hostile_bin/openssl" <<'EOF_HOSTILE_OPENSSL'
#!/usr/bin/env bash
: > "${HOSTILE_OPENSSL_MARKER:?}"
exit 0
EOF_HOSTILE_OPENSSL
chmod 0755 "$hostile_bin/openssl"
PATH="$hostile_bin:$PATH" HOSTILE_OPENSSL_MARKER="$hostile_marker" \
  run_validator "$good" >/dev/null || fail "fixed OpenSSL validation rejected a valid bundle"
[ ! -e "$hostile_marker" ] || fail "signed-module validator executed hostile PATH OpenSSL"

ignored_sigchld_tmp="$temporary_root/ignored-sigchld-tmp"
mkdir "$ignored_sigchld_tmp"
chmod 0700 "$ignored_sigchld_tmp"
set +e
(
  trap '' CHLD
  TMPDIR="$ignored_sigchld_tmp" exec /usr/bin/python3 -I "$validator" \
    --certificate "$good/sp11-module-signing-cert.x509" \
    --module "$good/gpi.ko" \
    --module "$good/spi-geni-qcom.ko" \
    --module "$good/mshw0485_touch.ko"
) > "$temporary_root/ignored-sigchld.stdout" \
  2> "$temporary_root/ignored-sigchld.stderr"
ignored_sigchld_status=$?
set -e
[ "$ignored_sigchld_status" -ne 0 ] ||
  fail "signed-module validator accepted an ignored SIGCHLD disposition"
[ ! -s "$temporary_root/ignored-sigchld.stdout" ] ||
  fail "ignored-SIGCHLD rejection emitted stdout"
grep -Fq 'controlled module validation requires the default SIGCHLD disposition' \
  "$temporary_root/ignored-sigchld.stderr" ||
  fail "ignored-SIGCHLD rejection was not explicit"
if find "$ignored_sigchld_tmp" -mindepth 1 -print -quit | grep -q .; then
  fail "ignored-SIGCHLD rejection created temporary validation state"
fi

manifest_tamper="$temporary_root/manifest-tamper"
cp -R "$good" "$manifest_tamper"
python3 - "$manifest_tamper/sp11-touchscreen-modules-manifest.txt" <<'PY_TAMPER_MANIFEST'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
needle = b"Module gpi.ko payload SHA256: "
if data.count(needle) != 1:
    raise SystemExit("fixture manifest did not contain one gpi.ko payload identity")
path.write_bytes(data.replace(needle, needle + b"00", 1))
PY_TAMPER_MANIFEST
expect_failure "tampered module manifest identity" run_validator "$manifest_tamper" \
  --manifest "$manifest_tamper/sp11-touchscreen-modules-manifest.txt"

manifest_order="$temporary_root/manifest-order"
cp -R "$good" "$manifest_order"
python3 - "$manifest_order/sp11-touchscreen-modules-manifest.txt" <<'PY_REORDER_MANIFEST'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
records = path.read_bytes().splitlines(keepends=True)
first_record = b"Module signing hash algorithm: sha512\n"
second_record = b"Module signing certificate asset: sp11-module-signing-cert.x509\n"
if records.count(first_record) != 1 or records.count(second_record) != 1:
    raise SystemExit("fixture manifest signing fields are not unique LF records")
first = records.index(first_record)
second = records.index(second_record)
records[first], records[second] = records[second], records[first]
path.write_bytes(b"".join(records))
PY_REORDER_MANIFEST
expect_failure "reordered module manifest fields" run_validator "$manifest_order" \
  --manifest "$manifest_order/sp11-touchscreen-modules-manifest.txt"

echo "Controlled touchscreen module signing validation tests passed."
