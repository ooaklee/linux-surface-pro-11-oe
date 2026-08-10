#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
wrapper="$repo_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-signing-lifecycle.XXXXXX")"

die() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  case "$temporary_root" in
    "${TMPDIR:-/tmp}"/sp11-signing-lifecycle.*)
      rm -rf -- "$temporary_root"
      ;;
    *) echo "warning: refusing unexpected lifecycle fixture cleanup" >&2 ;;
  esac
}
trap cleanup EXIT

for tool in awk bash chmod cp dd find grep ln mkdir mkfifo mktemp mv openssl sed shasum stat tr; do
  command -v "$tool" >/dev/null 2>&1 || die "missing fixture tool: $tool"
done
[ -x /usr/bin/openssl ] && [ -x /usr/bin/python3 ] ||
  die "controlled lifecycle fixture requires fixed OpenSSL and Python authorities"

fixture_dir="$temporary_root/inputs"
mkdir "$fixture_dir"
pin="$fixture_dir/pin"
raw_key="$fixture_dir/raw-key.pem"
key="$fixture_dir/key.pem"
certificate="$fixture_dir/certificate.pem"
openssl rand -hex 24 > "$pin"
chmod 0600 "$pin"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -out "$raw_key" >/dev/null 2>&1
openssl req -new -x509 -sha512 -key "$raw_key" \
  -subj /CN=sp11-controlled-lifecycle-fixture -days 1 \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -out "$certificate" >/dev/null 2>&1
openssl pkcs8 -topk8 -in "$raw_key" -out "$key" \
  -passout "file:$pin" >/dev/null 2>&1
chmod 0600 "$raw_key" "$key"
chmod 0644 "$certificate"

certificate_text="$(openssl x509 -in "$certificate" -noout -text)"
printf '%s\n' "$certificate_text" |
  grep -Fq 'Signature Algorithm: sha512WithRSAEncryption' ||
  die "fixture certificate is not RSA/SHA-512"
printf '%s\n' "$certificate_text" |
  grep -A1 -F 'X509v3 Basic Constraints: critical' |
  grep -Fq 'CA:FALSE' || die "fixture certificate is not critical CA:false"
[ "$(printf '%s\n' "$certificate_text" |
    grep -A1 -F 'X509v3 Key Usage: critical' | tail -n 1 |
    tr -d '[:space:]')" = "DigitalSignature" ] ||
  die "fixture certificate key usage is not exact"
unset certificate_text

certificate_sha="$(/usr/bin/openssl x509 -in "$certificate" -outform DER |
  shasum -a 256 | awk '{print $1}')"
certificate_fingerprint="$(/usr/bin/openssl x509 -in "$certificate" \
  -noout -sha256 -fingerprint)"
certificate_fingerprint="${certificate_fingerprint#*=}"
certificate_fingerprint="$(printf '%s' "$certificate_fingerprint" |
  tr '[:lower:]' '[:upper:]')"
certificate_serial="$(/usr/bin/openssl x509 -in "$certificate" -noout -serial)"
certificate_serial="$(printf '%s' "${certificate_serial#*=}" |
  tr '[:lower:]' '[:upper:]')"
pin_value="$(tr -d '\n' < "$pin")"

python_wrapper="$temporary_root/python3-fixture"
cat > "$python_wrapper" <<'EOF_PYTHON_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ge 3 ] && [ "$1" = -I ] && [ "$2" = -c ] &&
   [ "$3" = 'import secrets; print(secrets.token_hex(32))' ]; then
  printf '%s\n' "${SP11_LIFECYCLE_STAGE_TOKEN:?}"
  exit 0
fi
exec /usr/bin/python3 "$@"
EOF_PYTHON_WRAPPER
chmod 0700 "$python_wrapper"

harness="$temporary_root/lifecycle-harness.sh"
{
  cat <<'EOF_HARNESS_PREFIX'
#!/usr/bin/env bash
set -euo pipefail

: "${FIXTURE_KEY:?}" "${FIXTURE_CERTIFICATE:?}" "${FIXTURE_PIN:?}"
: "${FIXTURE_REFERENCE_CERTIFICATE:?}" "${FIXTURE_PYTHON:?}"
: "${FIXTURE_CERTIFICATE_SHA:?}" "${FIXTURE_CERTIFICATE_FINGERPRINT:?}"
: "${FIXTURE_CERTIFICATE_SERIAL:?}" "${SP11_LIFECYCLE_STAGE_TOKEN:?}"

RELEASE_BUILD=true
RELEASE_PYTHON_BIN="$FIXTURE_PYTHON"
RELEASE_PYTHON_DIRECTORY=/usr/bin
RELEASE_PYTHON_DIRECTORY_FD=55
RELEASE_PYTHON_DIRECTORY_FD_OPEN=true
RELEASE_OPENSSL_BIN=/usr/bin/openssl
RELEASE_OPENSSL_IDENTITY=""
RELEASE_MODULE_SIGNING_CERT_PATH=config/kernel-signing/sp11-module-signing-cert.pem
RELEASE_MODULE_SIGNING_CERT_SHA256="$FIXTURE_CERTIFICATE_SHA"
RELEASE_MODULE_SIGNING_CERT_FINGERPRINT="$FIXTURE_CERTIFICATE_FINGERPRINT"
RELEASE_MODULE_SIGNING_CERT_SERIAL="$FIXTURE_CERTIFICATE_SERIAL"
MODULE_SIGNING_KEY="$FIXTURE_KEY"
MODULE_SIGNING_CERTIFICATE="$FIXTURE_CERTIFICATE"
MODULE_SIGNING_PIN_FILE="$FIXTURE_PIN"
MODULE_SIGNING_STAGE_DIR=""
MODULE_SIGNING_STAGE_NAME=""
MODULE_SIGNING_STAGE_IDENTITY=""
MODULE_SIGNING_PARENT_FD_OPEN=false
MODULE_SIGNING_STAGE_FD_OPEN=false
MODULE_SIGNING_KEY_FD_OPEN=false
MODULE_SIGNING_PIN_FD_OPEN=false
MODULE_SIGNING_KEY_CREATION_IDENTITY=""
MODULE_SIGNING_KEY_STATE=""
MODULE_SIGNING_PIN_CREATION_IDENTITY=""
MODULE_SIGNING_PIN_STATE=""

committed_repo_abs_path() {
  [ "$1" = "$RELEASE_MODULE_SIGNING_CERT_PATH" ] || return 1
  printf '%s\n' "$FIXTURE_REFERENCE_CERTIFICATE"
}

verify_release_python_authority() {
  [ "$RELEASE_PYTHON_BIN" = "$FIXTURE_PYTHON" ]
}
EOF_HARNESS_PREFIX
  sed -n '/^sanitize_openssl_environment() {/,/^}$/p' "$wrapper"
  printf '%s\n' sanitize_openssl_environment
  sed -n \
    '/^release_openssl_identity_record() {/,/^require_apt_list_decoder() {/p' \
    "$wrapper" | sed '$d'
  sed -n \
    '/^cleanup_module_signing_stage() {/,/^cleanup_held_release_roots() {/p' \
    "$wrapper" | sed '$d'
  sed -n \
    '/^stage_controlled_module_signing_inputs() {/,/^capture_release_support_start() {/p' \
    "$wrapper" | sed '$d'
  cat <<'EOF_HARNESS_SUFFIX'
exec 55< /usr/bin

harness_cleanup_on_exit() {
  status=$?
  trap - EXIT
  if [ -n "$MODULE_SIGNING_STAGE_NAME" ]; then
    cleanup_module_signing_stage || status=1
  fi
  exit "$status"
}
trap harness_cleanup_on_exit EXIT

open_scrub_observers() {
  exec 70>&57
  exec 71>&60
}

assert_scrubbed_observers() {
  /usr/bin/python3 -I -c '
import os
import stat
for descriptor in (70, 71):
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != 0 or metadata.st_nlink != 0:
        raise SystemExit(1)
'
  exec 71>&-
  exec 70>&-
}

assert_zeroed_observers() {
  /usr/bin/python3 -I -c '
import os
import stat
for descriptor in (70, 71):
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != 0:
        raise SystemExit(1)
'
  exec 71>&-
  exec 70>&-
}

hostile_bash_env_cleanup_case() {
  stage_controlled_module_signing_inputs
  stage_path="$MODULE_SIGNING_STAGE_DIR"
  open_scrub_observers
  export BASH_ENV="$FIXTURE_HOSTILE_BASH_ENV"
  cleanup_module_signing_stage
  unset BASH_ENV
  assert_scrubbed_observers
  [ ! -e "$stage_path" ] && [ ! -L "$stage_path" ]
  [ ! -e "$FIXTURE_HOSTILE_BASH_ENV_MARKER" ] &&
    [ ! -L "$FIXTURE_HOSTILE_BASH_ENV_MARKER" ]
}

unlink_held_name_case() {
  target="$1"
  stage_controlled_module_signing_inputs
  stage_path="$MODULE_SIGNING_STAGE_DIR"
  open_scrub_observers
  /usr/bin/python3 -I -c '
import os
import sys
os.unlink(sys.argv[1], dir_fd=56)
' "$target"
  set +e
  cleanup_module_signing_stage
  status=$?
  set -e
  [ "$status" -ne 0 ]
  assert_scrubbed_observers
  [ ! -e "$stage_path" ] && [ ! -L "$stage_path" ]
}

chmod_stage_case() {
  stage_controlled_module_signing_inputs
  stage_path="$MODULE_SIGNING_STAGE_DIR"
  open_scrub_observers
  chmod 0600 "$stage_path"
  set +e
  cleanup_module_signing_stage
  status=$?
  set -e
  [ "$status" -ne 0 ]
  assert_zeroed_observers
  if [ -d "$stage_path" ] && [ ! -L "$stage_path" ]; then
    chmod 0700 "$stage_path"
    /usr/bin/python3 -I -c '
import os
import sys
root = sys.argv[1]
for name in ("signing.pem", "pin"):
    try:
        metadata = os.lstat(os.path.join(root, name))
    except FileNotFoundError:
        continue
    if metadata.st_size != 0:
        raise SystemExit(1)
    os.unlink(os.path.join(root, name))
os.rmdir(root)
' "$stage_path"
  fi
  [ ! -e "$stage_path" ] && [ ! -L "$stage_path" ]
}

prehold_swap_case() {
  target="$1"
  kind="$2"
  : "${FIXTURE_SWAP_ROOT:?}" "${FIXTURE_BOUNDARY_LOG:?}"
  boundary="swap-before-hold-$target"
  mkdir -m 0700 "$FIXTURE_SWAP_ROOT"
  exec 72> "$FIXTURE_BOUNDARY_LOG"
  export SP11_CONTROLLED_SIGNING_TEST_FIXTURE=sp11-controlled-signing-v1
  export SP11_MODULE_SIGNING_CLEANUP_TEST_DELAY="$boundary"
  (
    attempt=0
    observed=false
    while [ "$attempt" -lt 100 ]; do
      if grep -Fxq "$boundary" "$FIXTURE_BOUNDARY_LOG"; then
        observed=true
        break
      fi
      sleep 0.02
      attempt=$((attempt + 1))
    done
    [ "$observed" = true ]
    stage_path="/tmp/sp11-module-signing.$SP11_LIFECYCLE_STAGE_TOKEN"
    case "$target" in
      key) entry=signing.pem ;;
      pin) entry=pin ;;
      *) exit 2 ;;
    esac
    candidate="$stage_path/$entry"
    created="$stage_path/$entry.created"
    victim="$FIXTURE_SWAP_ROOT/victim"
    printf '%s\n' 'pre-hold victim bytes must survive' > "$victim"
    chmod 0600 "$victim"
    mv "$candidate" "$created"
    case "$kind" in
      regular) mv "$victim" "$candidate"; victim="$candidate" ;;
      symlink) ln -s "$victim" "$candidate" ;;
      *) exit 2 ;;
    esac
    /usr/bin/python3 -I -c '
import hashlib
import os
import sys
path, output = sys.argv[1:3]
metadata = os.lstat(path)
with open(path, "rb") as source:
    digest = hashlib.sha256(source.read()).hexdigest()
state = (
    metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_size,
    metadata.st_mtime_ns, metadata.st_ctime_ns, metadata.st_nlink,
    metadata.st_uid, metadata.st_gid, digest,
)
with open(output, "x", encoding="ascii") as destination:
    print(*state, sep=":", file=destination)
' "$victim" "$FIXTURE_SWAP_ROOT/victim.state"
  ) &
  stage_controlled_module_signing_inputs
  exit 84
}

normal_case() {
  stage_controlled_module_signing_inputs
  stage_path="$MODULE_SIGNING_STAGE_DIR"
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C OPENSSL_CONF=/dev/null \
    /usr/bin/openssl x509 -in "$stage_path/signing.pem" -noout \
    >/dev/null 2>&1
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C OPENSSL_CONF=/dev/null \
    /usr/bin/openssl pkey -in "$stage_path/signing.pem" \
    -passin "file:$stage_path/pin" -pubout >/dev/null 2>&1
  verify_controlled_module_signing_stage
  open_scrub_observers
  cleanup_module_signing_stage
  assert_scrubbed_observers
  [ ! -e "$stage_path" ] && [ ! -L "$stage_path" ]
}

mutation_case() {
  target="$1"
  stage_controlled_module_signing_inputs
  stage_path="$MODULE_SIGNING_STAGE_DIR"
  open_scrub_observers
  if [ "$target" = key ]; then
    /usr/bin/python3 -I -c '
import os
metadata = os.fstat(57)
if os.pwrite(57, b"X", metadata.st_size - 2) != 1:
    raise SystemExit(1)
os.fsync(57)
'
  else
    /usr/bin/python3 -I -c '
import os
if os.pwrite(60, b"X", 0) != 1:
    raise SystemExit(1)
os.fsync(60)
'
  fi
  if verify_controlled_module_signing_stage; then
    exit 81
  fi
  cleanup_module_signing_stage
  assert_scrubbed_observers
  [ ! -e "$stage_path" ] && [ ! -L "$stage_path" ]
}

name_replacement_case() {
  target="$1"
  stage_controlled_module_signing_inputs
  stage_path="$MODULE_SIGNING_STAGE_DIR"
  open_scrub_observers
  if [ "$target" = key ]; then
    entry=signing.pem
    target_descriptor=70
    other_descriptor=71
  else
    entry=pin
    target_descriptor=71
    other_descriptor=70
  fi
  backup="$stage_path/.held-$entry"
  victim="$stage_path/$entry"
  mv "$victim" "$backup"
  printf '%s\n' "byte-distinct $target victim" > "$victim"
  chmod 0400 "$victim"
  victim_state="$(/usr/bin/python3 -I -c '
import hashlib
import os
import stat
import sys
metadata = os.lstat(sys.argv[1])
with open(sys.argv[1], "rb") as source:
    digest = hashlib.sha256(source.read()).hexdigest()
print(metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_size,
      metadata.st_mtime_ns, metadata.st_ctime_ns, metadata.st_nlink,
      metadata.st_uid, metadata.st_gid, digest)
' "$victim")"
  [ -f "$backup" ] && [ -f "$victim" ] || exit 84
  if verify_controlled_module_signing_stage; then
    exit 85
  fi
  set +e
  cleanup_module_signing_stage
  status=$?
  set -e
  [ "$status" -ne 0 ]
  [ "$(/usr/bin/python3 -I -c '
import hashlib
import os
import sys
metadata = os.lstat(sys.argv[1])
with open(sys.argv[1], "rb") as source:
    digest = hashlib.sha256(source.read()).hexdigest()
print(metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_size,
      metadata.st_mtime_ns, metadata.st_ctime_ns, metadata.st_nlink,
      metadata.st_uid, metadata.st_gid, digest)
' "$victim")" = "$victim_state" ]
  /usr/bin/python3 -I -c '
import os
import stat
import sys
target_descriptor = int(sys.argv[1], 10)
other_descriptor = int(sys.argv[2], 10)
backup = sys.argv[3]
target = os.fstat(target_descriptor)
other = os.fstat(other_descriptor)
mapped_backup = os.lstat(backup)
if (
    not stat.S_ISREG(target.st_mode)
    or target.st_size != 0
    or target.st_nlink != 1
    or (target.st_dev, target.st_ino) != (mapped_backup.st_dev, mapped_backup.st_ino)
    or not stat.S_ISREG(other.st_mode)
    or other.st_size != 0
    or other.st_nlink != 0
):
    raise SystemExit(1)
' "$target_descriptor" "$other_descriptor" "$backup"
  exec 71>&-
  exec 70>&-
  rm -f -- "$victim" "$backup"
  rmdir "$stage_path"
}

substitution_case() {
  verify_first="${1:-false}"
  stage_controlled_module_signing_inputs
  stage_path="$MODULE_SIGNING_STAGE_DIR"
  held_path="$stage_path.held"
  open_scrub_observers
  mv "$stage_path" "$held_path"
  mkdir -m 0700 "$stage_path"
  printf '%s\n' 'substitute victim remains' > "$stage_path/victim"
  victim_state="$(shasum -a 256 "$stage_path/victim")"
  [ -d "$held_path" ] && [ -d "$stage_path" ] &&
    [ -f "$stage_path/victim" ] || exit 82
  if [ "$verify_first" = true ] &&
     verify_controlled_module_signing_stage; then
    exit 83
  fi
  set +e
  cleanup_module_signing_stage
  status=$?
  set -e
  [ "$status" -ne 0 ]
  [ "$(shasum -a 256 "$stage_path/victim")" = "$victim_state" ]
  assert_scrubbed_observers
  [ -d "$held_path" ] && [ -d "$stage_path" ]
  [ -z "$(find "$held_path" -mindepth 1 -maxdepth 1 -print -quit)" ]
  rm -f -- "$stage_path/victim"
  rmdir "$stage_path" "$held_path"
}

signal_case() {
  boundary="$1"
  signal_name="$2"
  expected_status="$3"
  : "${FIXTURE_BOUNDARY_LOG:?}"
  stage_controlled_module_signing_inputs
  stage_path="$MODULE_SIGNING_STAGE_DIR"
  open_scrub_observers
  boundary_observed="$FIXTURE_BOUNDARY_LOG.observed"
  exec 72> "$FIXTURE_BOUNDARY_LOG"
  export SP11_CONTROLLED_SIGNING_TEST_FIXTURE=sp11-controlled-signing-v1
  export SP11_MODULE_SIGNING_CLEANUP_TEST_DELAY="$boundary"
  (
    attempt=0
    observed=false
    while [ "$attempt" -lt 100 ]; do
      if grep -Fxq "$boundary" "$FIXTURE_BOUNDARY_LOG"; then
        if [ "$boundary" != pre-ignore ] ||
           grep -Fxq parent-restored "$FIXTURE_BOUNDARY_LOG"; then
          observed=true
          break
        fi
      fi
      sleep 0.02
      attempt=$((attempt + 1))
    done
    [ "$observed" = true ]
    /usr/bin/python3 -I -c '
import os
import sys

boundary = sys.argv[1]
key = os.fstat(70)
pin = os.fstat(71)
if boundary in ("pre-ignore", "pre-scrub"):
    valid = key.st_size > 0 and pin.st_size > 0
elif boundary == "mid-scrub":
    valid = key.st_size == 0 and pin.st_size > 0
else:
    valid = False
if not valid:
    raise SystemExit(1)
' "$boundary"
    printf '%s\n' "$boundary" > "$boundary_observed"
    trap '' "$signal_name"
    /usr/bin/python3 -I -c '
import os
import signal
import sys
os.killpg(os.getpgrp(), getattr(signal, "SIG" + sys.argv[1]))
' "$signal_name"
  ) &
  signal_job=$!
  set +e
  cleanup_module_signing_stage
  status=$?
  wait "$signal_job"
  signal_job_status=$?
  set -e
  exec 72>&-
  unset SP11_CONTROLLED_SIGNING_TEST_FIXTURE
  unset SP11_MODULE_SIGNING_CLEANUP_TEST_DELAY
  [ "$signal_job_status" -eq 0 ]
  grep -Fxq "$boundary" "$FIXTURE_BOUNDARY_LOG"
  if [ "$boundary" = pre-ignore ]; then
    grep -Fxq parent-restored "$FIXTURE_BOUNDARY_LOG"
  fi
  grep -Fxq "$boundary" "$boundary_observed"
  [ "$status" -eq "$expected_status" ]
  assert_scrubbed_observers
  [ ! -e "$stage_path" ] && [ ! -L "$stage_path" ]
  [ -z "$(jobs -pr)" ]
}

case "${1:-}" in
  normal) normal_case ;;
  hostile-bash-env-cleanup) hostile_bash_env_cleanup_case ;;
  unlink-key) unlink_held_name_case signing.pem ;;
  unlink-pin) unlink_held_name_case pin ;;
  chmod-stage) chmod_stage_case ;;
  swap-before-hold-key-regular) prehold_swap_case key regular ;;
  swap-before-hold-key-symlink) prehold_swap_case key symlink ;;
  swap-before-hold-pin-regular) prehold_swap_case pin regular ;;
  swap-before-hold-pin-symlink) prehold_swap_case pin symlink ;;
  stage-only)
    stage_controlled_module_signing_inputs
    unexpected_path="$MODULE_SIGNING_STAGE_DIR"
    cleanup_module_signing_stage
    [ ! -e "$unexpected_path" ]
    exit 80
    ;;
  mutate-key) mutation_case key ;;
  mutate-pin) mutation_case pin ;;
  replace-key-name) name_replacement_case key ;;
  replace-pin-name) name_replacement_case pin ;;
  substitute-root) substitution_case false ;;
  verify-substitute-root) substitution_case true ;;
  hup-pre-ignore) signal_case pre-ignore HUP 129 ;;
  hup-pre) signal_case pre-scrub HUP 129 ;;
  quit-pre) signal_case pre-scrub QUIT 131 ;;
  quit-mid) signal_case mid-scrub QUIT 131 ;;
  term-mid) signal_case mid-scrub TERM 143 ;;
  *) exit 2 ;;
esac
EOF_HARNESS_SUFFIX
} > "$harness"
chmod 0700 "$harness"
bash -n "$harness"

next_token() {
  /usr/bin/python3 -I -c 'import secrets; print(secrets.token_hex(32))'
}

stage_path_for_token() {
  printf '/tmp/sp11-module-signing.%s\n' "$1"
}

controlled_stage_snapshot() {
  /usr/bin/python3 -I -c '
import os
import stat

rows = []
with os.scandir("/tmp") as entries:
    for entry in entries:
        if not entry.name.startswith("sp11-module-signing."):
            continue
        metadata = entry.stat(follow_symlinks=False)
        rows.append((
            entry.name,
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mode,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            metadata.st_nlink,
            metadata.st_uid,
            metadata.st_gid,
        ))
for row in sorted(rows):
    print(*row, sep=":")
'
}

fixture_exact_file_state() {
  /usr/bin/python3 -I -c '
import hashlib
import os
import sys
metadata = os.lstat(sys.argv[1])
with open(sys.argv[1], "rb") as source:
    digest = hashlib.sha256(source.read()).hexdigest()
print(
    metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_size,
    metadata.st_mtime_ns, metadata.st_ctime_ns, metadata.st_nlink,
    metadata.st_uid, metadata.st_gid, digest, sep=":",
)
' "$1"
}

run_harness() {
  local action="$1" token="$2" fixture_key="$3" fixture_certificate="$4"
  local fixture_pin="$5"
  FIXTURE_KEY="$fixture_key" \
  FIXTURE_CERTIFICATE="$fixture_certificate" \
  FIXTURE_PIN="$fixture_pin" \
  FIXTURE_REFERENCE_CERTIFICATE="$certificate" \
  FIXTURE_PYTHON="$python_wrapper" \
  FIXTURE_CERTIFICATE_SHA="$certificate_sha" \
  FIXTURE_CERTIFICATE_FINGERPRINT="$certificate_fingerprint" \
  FIXTURE_CERTIFICATE_SERIAL="$certificate_serial" \
  FIXTURE_HOSTILE_BASH_ENV="${hostile_cleanup_bash_env:-}" \
  FIXTURE_HOSTILE_BASH_ENV_MARKER="${hostile_cleanup_bash_env_marker:-}" \
  FIXTURE_SWAP_ROOT="$temporary_root/swap-$token" \
  FIXTURE_BOUNDARY_LOG="$temporary_root/boundary-$token.log" \
  SP11_LIFECYCLE_STAGE_TOKEN="$token" \
    "$harness" "$action"
}

run_signal_harness() {
  local action="$1" token="$2" fixture_key="$3" fixture_certificate="$4"
  local fixture_pin="$5"
  FIXTURE_KEY="$fixture_key" \
  FIXTURE_CERTIFICATE="$fixture_certificate" \
  FIXTURE_PIN="$fixture_pin" \
  FIXTURE_REFERENCE_CERTIFICATE="$certificate" \
  FIXTURE_PYTHON="$python_wrapper" \
  FIXTURE_CERTIFICATE_SHA="$certificate_sha" \
  FIXTURE_CERTIFICATE_FINGERPRINT="$certificate_fingerprint" \
  FIXTURE_CERTIFICATE_SERIAL="$certificate_serial" \
  FIXTURE_HOSTILE_BASH_ENV="${hostile_cleanup_bash_env:-}" \
  FIXTURE_HOSTILE_BASH_ENV_MARKER="${hostile_cleanup_bash_env_marker:-}" \
  FIXTURE_SWAP_ROOT="$temporary_root/swap-$token" \
  FIXTURE_BOUNDARY_LOG="$temporary_root/boundary-$token.log" \
  SP11_LIFECYCLE_STAGE_TOKEN="$token" \
    /usr/bin/python3 -I -c '
import os
import sys
os.setsid()
os.execve(sys.argv[1], [sys.argv[1], sys.argv[2]], os.environ)
' "$harness" "$action"
}

run_harness_bounded() {
  local action="$1" token="$2" fixture_key="$3" fixture_certificate="$4"
  local fixture_pin="$5" log="$6"
  FIXTURE_KEY="$fixture_key" \
  FIXTURE_CERTIFICATE="$fixture_certificate" \
  FIXTURE_PIN="$fixture_pin" \
  FIXTURE_REFERENCE_CERTIFICATE="$certificate" \
  FIXTURE_PYTHON="$python_wrapper" \
  FIXTURE_CERTIFICATE_SHA="$certificate_sha" \
  FIXTURE_CERTIFICATE_FINGERPRINT="$certificate_fingerprint" \
  FIXTURE_CERTIFICATE_SERIAL="$certificate_serial" \
  FIXTURE_HOSTILE_BASH_ENV="${hostile_cleanup_bash_env:-}" \
  FIXTURE_HOSTILE_BASH_ENV_MARKER="${hostile_cleanup_bash_env_marker:-}" \
  FIXTURE_SWAP_ROOT="$temporary_root/swap-$token" \
  FIXTURE_BOUNDARY_LOG="$temporary_root/boundary-$token.log" \
  SP11_LIFECYCLE_STAGE_TOKEN="$token" \
    /usr/bin/python3 -I -c '
import os
import signal
import subprocess
import sys

harness, action, log = sys.argv[1:4]
descriptor = os.open(
    log,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
    0o600,
)
with os.fdopen(descriptor, "wb") as output:
    process = subprocess.Popen(
        [harness, action],
        stdin=subprocess.DEVNULL,
        stdout=output,
        stderr=subprocess.STDOUT,
        env=os.environ.copy(),
        start_new_session=True,
    )
    try:
        status = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise SystemExit(124)
if status < 0:
    raise SystemExit(125)
raise SystemExit(status)
' "$harness" "$action" "$log"
}

assert_no_secret_leak() {
  local log="$1" encrypted_boundary plain_boundary rsa_boundary forbidden
  shift
  encrypted_boundary='-----BEGIN ENCRYPTED '"PRIVATE KEY-----"
  plain_boundary='-----BEGIN '"PRIVATE KEY-----"
  rsa_boundary='-----BEGIN RSA '"PRIVATE KEY-----"
  for forbidden in \
    "$key" "$certificate" "$pin" "$pin_value" \
    "$encrypted_boundary" "$plain_boundary" "$rsa_boundary" \
    KBUILD_SIGN_PIN "$@"; do
    if grep -Fq -- "$forbidden" "$log"; then
      die "controlled lifecycle output leaked private signing input material"
    fi
  done
}

expect_stage_failure() {
  local label="$1" fixture_key="$2" fixture_certificate="$3" fixture_pin="$4"
  local token log stage_path status
  token="$(next_token)"
  log="$temporary_root/$label.log"
  stage_path="$(stage_path_for_token "$token")"
  set +e
  run_harness_bounded stage-only "$token" "$fixture_key" \
    "$fixture_certificate" "$fixture_pin" "$log"
  status=$?
  set -e
  [ "$status" -ne 124 ] ||
    die "controlled signing hostile fixture timed out: $label"
  [ "$status" -ne 80 ] ||
    die "controlled signing accepted hostile input: $label"
  [ "$status" -eq 1 ] ||
    die "controlled signing hostile fixture reached an unexpected branch: $label ($status)"
  grep -Fq 'Controlled module-signing input validation failed.' "$log" ||
    die "controlled signing hostile fixture missed input rejection: $label"
  [ ! -e "$stage_path" ] && [ ! -L "$stage_path" ] ||
    die "controlled signing failure retained its private stage: $label"
  assert_no_secret_leak \
    "$log" "$fixture_key" "$fixture_certificate" "$fixture_pin"
}

# The option contract is enforced before any build or private staging work.
for option_mask in 1 2 4 3 5 6; do
  signing_options=()
  [ $((option_mask & 1)) -eq 0 ] ||
    signing_options+=(--module-signing-key "$key")
  [ $((option_mask & 2)) -eq 0 ] ||
    signing_options+=(--module-signing-certificate "$certificate")
  [ $((option_mask & 4)) -eq 0 ] ||
    signing_options+=(--module-signing-pin-file "$pin")
  option_log="$temporary_root/options-$option_mask.log"
  if "$wrapper" --release-build "${signing_options[@]}" \
      > "$option_log" 2>&1; then
    die "release wrapper accepted a partial signing CLI set: $option_mask"
  fi
  grep -Fq 'requires all three controlled module-signing file options' \
    "$option_log" || die "partial signing CLI rejection was not explicit"
done
if "$wrapper" \
    --module-signing-key "$key" \
    --module-signing-certificate "$certificate" \
    --module-signing-pin-file "$pin" \
    > "$temporary_root/nonrelease-options.log" 2>&1; then
  die "nonrelease wrapper accepted controlled signing inputs"
fi
grep -Fq 'accepted only with --release-build' \
  "$temporary_root/nonrelease-options.log" ||
  die "nonrelease signing CLI rejection was not explicit"

early_mock_bin="$temporary_root/early-mock-bin"
mkdir "$early_mock_bin"
cat > "$early_mock_bin/docker" <<'EOF_EARLY_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
: "${SP11_EARLY_DOCKER_MARKER:?}"
: > "$SP11_EARLY_DOCKER_MARKER"
exit 88
EOF_EARLY_DOCKER
chmod 0700 "$early_mock_bin/docker"
fixture_env_diagnostic='Wrapper refuses controlled-signing lifecycle fixture variables.'
for fixture_env_case in boundary delay both; do
  case "$fixture_env_case" in
    boundary)
      fixture_env=(SP11_CONTROLLED_SIGNING_TEST_FIXTURE=sp11-controlled-signing-v1)
      ;;
    delay)
      fixture_env=(SP11_MODULE_SIGNING_CLEANUP_TEST_DELAY=pre-scrub)
      ;;
    both)
      fixture_env=(
        SP11_CONTROLLED_SIGNING_TEST_FIXTURE=sp11-controlled-signing-v1
        SP11_MODULE_SIGNING_CLEANUP_TEST_DELAY=mid-scrub
      )
      ;;
  esac
  fixture_env_log="$temporary_root/fixture-env-$fixture_env_case.log"
  fixture_env_work="$temporary_root/fixture-env-$fixture_env_case-work"
  fixture_env_docker_marker="$temporary_root/fixture-env-$fixture_env_case-docker"
  fixture_env_stage_before="$(controlled_stage_snapshot)"
  set +e
  PATH="$early_mock_bin:$PATH" \
  SP11_EARLY_DOCKER_MARKER="$fixture_env_docker_marker" \
  /usr/bin/env "${fixture_env[@]}" "$wrapper" --release-build \
    --work-dir "$fixture_env_work" --dry-run \
    > "$fixture_env_log" 2>&1
  fixture_env_status=$?
  set -e
  [ "$fixture_env_status" -eq 2 ] ||
    die "wrapper accepted controlled-signing fixture environment: $fixture_env_case"
  [ "$(cat "$fixture_env_log")" = "$fixture_env_diagnostic" ] ||
    die "fixture environment refusal was not the single fixed diagnostic"
  fixture_env_stage_after="$(controlled_stage_snapshot)"
  if [ "$fixture_env_stage_after" != "$fixture_env_stage_before" ]; then
    printf 'before: %s\nafter: %s\n' \
      "$fixture_env_stage_before" "$fixture_env_stage_after" >&2
    die "fixture environment refusal changed private signing-stage state"
  fi
  [ ! -e "$fixture_env_work" ] && [ ! -L "$fixture_env_work" ] &&
    [ ! -e "$fixture_env_docker_marker" ] &&
    [ ! -L "$fixture_env_docker_marker" ] ||
    die "fixture environment refusal created work or Docker state"
done
unset fixture_env fixture_env_case fixture_env_diagnostic fixture_env_log \
  fixture_env_status fixture_env_work fixture_env_docker_marker \
  fixture_env_stage_before fixture_env_stage_after

hostile_bash_env="$temporary_root/hostile-wrapper-bash-env"
hostile_bash_env_marker="$temporary_root/hostile-wrapper-bash-env-ran"
cat > "$hostile_bash_env" <<'EOF_HOSTILE_WRAPPER_BASH_ENV'
: "${SP11_HOSTILE_BASH_ENV_MARKER:?}"
printf '%s\n' sourced > "$SP11_HOSTILE_BASH_ENV_MARKER"
exit 96
EOF_HOSTILE_WRAPPER_BASH_ENV
if ! BASH_ENV="$hostile_bash_env" \
    SP11_HOSTILE_BASH_ENV_MARKER="$hostile_bash_env_marker" \
    "$wrapper" --help > "$temporary_root/hostile-bash-env.log" 2>&1; then
  die "privileged wrapper launch failed with a hostile BASH_ENV present"
fi
[ ! -e "$hostile_bash_env_marker" ] && [ ! -L "$hostile_bash_env_marker" ] ||
  die "release wrapper sourced a hostile BASH_ENV before its authority checks"
unset hostile_bash_env hostile_bash_env_marker

# Ignored dispositions survive exec, and Bash cannot restore them to a
# catchable state.  The wrapper must refuse each one before creating state.
startup_signal_diagnostic='Wrapper requires default CHLD/HUP/INT/QUIT/TERM dispositions at startup.'
for ignored_signal in CHLD HUP INT QUIT TERM; do
  ignored_signal_log="$temporary_root/ignored-$ignored_signal.log"
  ignored_signal_work="$temporary_root/ignored-$ignored_signal-work"
  ignored_signal_docker_marker="$temporary_root/ignored-$ignored_signal-docker"
  ignored_signal_stage_before="$(controlled_stage_snapshot)"
  set +e
  PATH="$early_mock_bin:$PATH" \
  SP11_EARLY_DOCKER_MARKER="$ignored_signal_docker_marker" \
  /usr/bin/python3 -I -c '
import os
import signal
import sys
number = getattr(signal, "SIG" + sys.argv[1])
signal.signal(number, signal.SIG_IGN)
os.execve(
    sys.argv[2],
    [sys.argv[2], "--release-build", "--work-dir", sys.argv[3], "--dry-run"],
    os.environ,
)
' "$ignored_signal" "$wrapper" "$ignored_signal_work" \
    > "$ignored_signal_log" 2>&1
  ignored_signal_status=$?
  set -e
  [ "$ignored_signal_status" -eq 2 ] ||
    die "wrapper accepted or misclassified ignored $ignored_signal"
  [ "$(cat "$ignored_signal_log")" = "$startup_signal_diagnostic" ] ||
    die "ignored $ignored_signal rejection was not the single fixed diagnostic"
  [ "$(controlled_stage_snapshot)" = "$ignored_signal_stage_before" ] ||
    die "ignored $ignored_signal refusal changed private signing-stage state"
  [ ! -e "$ignored_signal_work" ] && [ ! -L "$ignored_signal_work" ] &&
    [ ! -e "$ignored_signal_docker_marker" ] &&
    [ ! -L "$ignored_signal_docker_marker" ] ||
    die "ignored $ignored_signal refusal created work or Docker state"
done
unset ignored_signal ignored_signal_log ignored_signal_status \
  ignored_signal_work ignored_signal_docker_marker ignored_signal_stage_before \
  startup_signal_diagnostic early_mock_bin

# Prove the unique stage-only status really denotes accepted input before using
# it to discriminate every hostile-input case below.
accepted_token="$(next_token)"
accepted_log="$temporary_root/accepted-stage-only.log"
set +e
run_harness stage-only "$accepted_token" "$key" "$certificate" "$pin" \
  > "$accepted_log" 2>&1
accepted_status=$?
set -e
if [ "$accepted_status" -ne 80 ]; then
  cat "$accepted_log" >&2
  die "controlled signing acceptance sentinel is not discriminating"
fi
accepted_stage_path="$(stage_path_for_token "$accepted_token")"
[ ! -e "$accepted_stage_path" ] && [ ! -L "$accepted_stage_path" ] ||
  die "controlled signing acceptance sentinel retained its private stage"
assert_no_secret_leak "$accepted_log"
unset accepted_token accepted_log accepted_status accepted_stage_path

for prehold_target in key pin; do
  case "$prehold_target" in
    key)
      prehold_entry=signing.pem
      prehold_diagnostic='Private signing key creation mapping changed before hold.'
      ;;
    pin)
      prehold_entry=pin
      prehold_diagnostic='Private signing PIN creation mapping changed before hold.'
      ;;
  esac
  for prehold_kind in regular symlink; do
    prehold_token="$(next_token)"
    prehold_action="swap-before-hold-$prehold_target-$prehold_kind"
    prehold_log="$temporary_root/$prehold_action.log"
    set +e
    run_harness "$prehold_action" "$prehold_token" \
      "$key" "$certificate" "$pin" > "$prehold_log" 2>&1
    prehold_status=$?
    set -e
    [ "$prehold_status" -eq 1 ] || {
      cat "$prehold_log" >&2
      die "pre-hold $prehold_target $prehold_kind swap was misclassified"
    }
    grep -Fxq "$prehold_diagnostic" "$prehold_log" || {
      cat "$prehold_log" >&2
      die "pre-hold $prehold_target $prehold_kind swap missed its mapping fence"
    }
    prehold_stage="$(stage_path_for_token "$prehold_token")"
    prehold_swap_root="$temporary_root/swap-$prehold_token"
    prehold_created="$prehold_stage/$prehold_entry.created"
    [ -f "$prehold_created" ] && [ ! -L "$prehold_created" ] &&
      [ ! -s "$prehold_created" ] ||
      die "pre-hold swap changed the empty creation-owned inode"
    if [ "$prehold_kind" = regular ]; then
      prehold_victim="$prehold_stage/$prehold_entry"
      [ -f "$prehold_victim" ] && [ ! -L "$prehold_victim" ] ||
        die "pre-hold regular victim mapping was not preserved"
    else
      prehold_victim="$prehold_swap_root/victim"
      [ -L "$prehold_stage/$prehold_entry" ] &&
        [ "$(readlink "$prehold_stage/$prehold_entry")" = "$prehold_victim" ] ||
        die "pre-hold symlink victim mapping was not preserved"
    fi
    [ "$(fixture_exact_file_state "$prehold_victim")" = \
      "$(cat "$prehold_swap_root/victim.state")" ] ||
      die "pre-hold $prehold_target $prehold_kind victim changed"
    assert_no_secret_leak "$prehold_log"
    for prehold_member in signing.pem pin signing.pem.created pin.created; do
      prehold_member_path="$prehold_stage/$prehold_member"
      if [ -e "$prehold_member_path" ] || [ -L "$prehold_member_path" ]; then
        if [ -f "$prehold_member_path" ] && [ ! -L "$prehold_member_path" ]; then
          [ ! -s "$prehold_member_path" ] ||
            [ "$prehold_member" = "$prehold_entry" ] ||
            die "pre-hold swap cleanup retained unexpected nonempty bytes"
        fi
        unlink "$prehold_member_path"
      fi
    done
    rmdir "$prehold_stage"
  done
done
unset prehold_action prehold_created prehold_diagnostic prehold_entry \
  prehold_kind prehold_log prehold_member prehold_member_path \
  prehold_stage prehold_status prehold_swap_root prehold_target \
  prehold_token prehold_victim

hostile_cleanup_bash_env="$temporary_root/hostile-cleanup-bash-env"
hostile_cleanup_bash_env_marker="$temporary_root/hostile-cleanup-bash-env-ran"
cat > "$hostile_cleanup_bash_env" <<'EOF_HOSTILE_CLEANUP_BASH_ENV'
: "${FIXTURE_HOSTILE_BASH_ENV_MARKER:?}"
printf '%s\n' sourced > "$FIXTURE_HOSTILE_BASH_ENV_MARKER"
exit 0
EOF_HOSTILE_CLEANUP_BASH_ENV
hostile_cleanup_token="$(next_token)"
hostile_cleanup_log="$temporary_root/hostile-cleanup-bash-env.log"
if ! run_harness hostile-bash-env-cleanup "$hostile_cleanup_token" \
    "$key" "$certificate" "$pin" > "$hostile_cleanup_log" 2>&1; then
  cat "$hostile_cleanup_log" >&2
  die "private signing cleanup failed under a hostile inherited BASH_ENV"
fi
[ ! -e "$hostile_cleanup_bash_env_marker" ] &&
  [ ! -L "$hostile_cleanup_bash_env_marker" ] ||
  die "private signing cleanup sourced a hostile inherited BASH_ENV"
hostile_cleanup_stage="$(stage_path_for_token "$hostile_cleanup_token")"
[ ! -e "$hostile_cleanup_stage" ] && [ ! -L "$hostile_cleanup_stage" ] ||
  die "hostile BASH_ENV cleanup test retained its private signing stage"
assert_no_secret_leak "$hostile_cleanup_log"
unset hostile_cleanup_bash_env hostile_cleanup_bash_env_marker \
  hostile_cleanup_token hostile_cleanup_log hostile_cleanup_stage

wrong_pin="$fixture_dir/wrong-pin"
printf '%s\n' 'wrong-fixture-pin' > "$wrong_pin"
chmod 0600 "$wrong_pin"

second_raw="$fixture_dir/second-raw.pem"
second_key="$fixture_dir/second-key.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -out "$second_raw" >/dev/null 2>&1
openssl pkcs8 -topk8 -in "$second_raw" -out "$second_key" \
  -passout "file:$pin" >/dev/null 2>&1
chmod 0600 "$second_raw" "$second_key"

key_symlink="$fixture_dir/key-symlink.pem"
certificate_symlink="$fixture_dir/certificate-symlink.pem"
pin_symlink="$fixture_dir/pin-symlink"
ln -s "$key" "$key_symlink"
ln -s "$certificate" "$certificate_symlink"
ln -s "$pin" "$pin_symlink"

key_hardlink="$fixture_dir/key-hardlink.pem"
certificate_hardlink="$fixture_dir/certificate-hardlink.pem"
pin_hardlink="$fixture_dir/pin-hardlink"
cp "$key" "$key_hardlink"
cp "$certificate" "$certificate_hardlink"
cp "$pin" "$pin_hardlink"
ln "$key_hardlink" "$fixture_dir/key-hardlink-alias.pem"
ln "$certificate_hardlink" "$fixture_dir/certificate-hardlink-alias.pem"
ln "$pin_hardlink" "$fixture_dir/pin-hardlink-alias"

key_insecure="$fixture_dir/key-insecure.pem"
certificate_insecure="$fixture_dir/certificate-insecure.pem"
pin_insecure="$fixture_dir/pin-insecure"
cp "$key" "$key_insecure"
cp "$certificate" "$certificate_insecure"
cp "$pin" "$pin_insecure"
chmod 0644 "$key_insecure" "$pin_insecure"
chmod 0666 "$certificate_insecure"

multiline_pin="$fixture_dir/pin-multiline"
nonprintable_pin="$fixture_dir/pin-nonprintable"
printf '%s\n%s\n' first second > "$multiline_pin"
printf 'printable\001not-printable\n' > "$nonprintable_pin"
chmod 0600 "$multiline_pin" "$nonprintable_pin"

extra_pem_key="$fixture_dir/key-extra-pem.pem"
trailing_certificate="$fixture_dir/certificate-trailing.pem"
cp "$key" "$extra_pem_key"
cat "$certificate" >> "$extra_pem_key"
cp "$certificate" "$trailing_certificate"
printf '%s\n' trailing-bytes >> "$trailing_certificate"
chmod 0600 "$extra_pem_key"
chmod 0644 "$trailing_certificate"

key_fifo="$fixture_dir/key-fifo.pem"
certificate_fifo="$fixture_dir/certificate-fifo.pem"
pin_fifo="$fixture_dir/pin-fifo"
mkfifo "$key_fifo" "$certificate_fifo" "$pin_fifo"
chmod 0600 "$key_fifo" "$pin_fifo"
chmod 0644 "$certificate_fifo"

key_directory="$fixture_dir/key-directory"
certificate_directory="$fixture_dir/certificate-directory"
pin_directory="$fixture_dir/pin-directory"
mkdir "$key_directory" "$certificate_directory" "$pin_directory"
chmod 0700 "$key_directory" "$pin_directory"
chmod 0755 "$certificate_directory"

empty_key="$fixture_dir/key-empty.pem"
empty_certificate="$fixture_dir/certificate-empty.pem"
empty_pin="$fixture_dir/pin-empty"
: > "$empty_key"
: > "$empty_certificate"
: > "$empty_pin"
chmod 0600 "$empty_key" "$empty_pin"
chmod 0644 "$empty_certificate"

oversize_key="$fixture_dir/key-oversize.pem"
oversize_certificate="$fixture_dir/certificate-oversize.pem"
oversize_pin="$fixture_dir/pin-oversize"
dd if=/dev/zero of="$oversize_key" bs=1048577 count=1 >/dev/null 2>&1
dd if=/dev/zero of="$oversize_certificate" bs=1048577 count=1 \
  >/dev/null 2>&1
dd if=/dev/zero of="$oversize_pin" bs=257 count=1 >/dev/null 2>&1
chmod 0600 "$oversize_key" "$oversize_pin"
chmod 0644 "$oversize_certificate"

expect_stage_failure wrong-pin "$key" "$certificate" "$wrong_pin"
expect_stage_failure key-certificate-mismatch \
  "$second_key" "$certificate" "$pin"
expect_stage_failure unencrypted-key "$raw_key" "$certificate" "$pin"
expect_stage_failure key-symlink "$key_symlink" "$certificate" "$pin"
expect_stage_failure certificate-symlink "$key" "$certificate_symlink" "$pin"
expect_stage_failure pin-symlink "$key" "$certificate" "$pin_symlink"
expect_stage_failure key-hardlink "$key_hardlink" "$certificate" "$pin"
expect_stage_failure certificate-hardlink \
  "$key" "$certificate_hardlink" "$pin"
expect_stage_failure pin-hardlink "$key" "$certificate" "$pin_hardlink"
expect_stage_failure key-insecure-mode "$key_insecure" "$certificate" "$pin"
expect_stage_failure certificate-insecure-mode \
  "$key" "$certificate_insecure" "$pin"
expect_stage_failure pin-insecure-mode "$key" "$certificate" "$pin_insecure"
expect_stage_failure multiline-pin "$key" "$certificate" "$multiline_pin"
expect_stage_failure nonprintable-pin \
  "$key" "$certificate" "$nonprintable_pin"
expect_stage_failure extra-pem-object "$extra_pem_key" "$certificate" "$pin"
expect_stage_failure trailing-certificate \
  "$key" "$trailing_certificate" "$pin"
expect_stage_failure key-fifo "$key_fifo" "$certificate" "$pin"
expect_stage_failure certificate-fifo "$key" "$certificate_fifo" "$pin"
expect_stage_failure pin-fifo "$key" "$certificate" "$pin_fifo"
expect_stage_failure key-directory "$key_directory" "$certificate" "$pin"
expect_stage_failure certificate-directory \
  "$key" "$certificate_directory" "$pin"
expect_stage_failure pin-directory "$key" "$certificate" "$pin_directory"
expect_stage_failure key-empty "$empty_key" "$certificate" "$pin"
expect_stage_failure certificate-empty "$key" "$empty_certificate" "$pin"
expect_stage_failure pin-empty "$key" "$certificate" "$empty_pin"
expect_stage_failure key-oversize "$oversize_key" "$certificate" "$pin"
expect_stage_failure certificate-oversize \
  "$key" "$oversize_certificate" "$pin"
expect_stage_failure pin-oversize "$key" "$certificate" "$oversize_pin"

hostile_openssl_conf="$fixture_dir/hostile-openssl.cnf"
hostile_openssl_modules="$fixture_dir/hostile-openssl-modules"
mkfifo "$hostile_openssl_conf"
mkdir "$hostile_openssl_modules"
mkfifo "$hostile_openssl_modules/default.so"
if [ "$(uname -s)" = Linux ]; then
  hostile_openssl_raw_log="$temporary_root/hostile-openssl-raw-python.log"
  set +e
  /usr/bin/python3 -I -c '
import os
import signal
import subprocess
import sys

configuration, modules, random_file, output_path = sys.argv[1:5]
descriptor = os.open(
    output_path,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
    0o600,
)
environment = os.environ.copy()
environment.update(
    {
        "OPENSSL_CONF": configuration,
        "OPENSSL_MODULES": modules,
        "OPENSSL_ENGINES": modules,
        "RANDFILE": random_file,
    }
)
with os.fdopen(descriptor, "wb") as output:
    process = subprocess.Popen(
        [
            "/usr/bin/python3",
            "-I",
            "-c",
            "import hashlib, secrets; print(hashlib.sha256(secrets.token_bytes(32)).hexdigest())",
        ],
        stdin=subprocess.DEVNULL,
        stdout=output,
        stderr=subprocess.STDOUT,
        env=environment,
        start_new_session=True,
    )
    try:
        status = process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise SystemExit(124)
if status < 0:
    raise SystemExit(125)
raise SystemExit(status)
' "$hostile_openssl_conf" "$hostile_openssl_modules" \
    "$fixture_dir/hostile-random-file" "$hostile_openssl_raw_log"
  hostile_openssl_raw_status=$?
  set -e
  [ "$hostile_openssl_raw_status" -eq 124 ] || {
    cat "$hostile_openssl_raw_log" >&2
    die "raw Linux Python crypto startup did not honor hostile OpenSSL authority"
  }
  [ ! -s "$hostile_openssl_raw_log" ] ||
    die "raw Linux Python crypto startup produced output before its timeout"
  unset hostile_openssl_raw_log hostile_openssl_raw_status
fi
hostile_openssl_token="$(next_token)"
hostile_openssl_log="$temporary_root/hostile-openssl-env.log"
set +e
OPENSSL_CONF="$hostile_openssl_conf" \
OPENSSL_MODULES="$hostile_openssl_modules" \
OPENSSL_ENGINES="$hostile_openssl_modules" \
RANDFILE="$fixture_dir/hostile-random-file" \
run_harness_bounded normal "$hostile_openssl_token" \
  "$key" "$certificate" "$pin" "$hostile_openssl_log"
hostile_openssl_status=$?
set -e
[ "$hostile_openssl_status" -eq 0 ] || {
  cat "$hostile_openssl_log" >&2
  die "controlled signing honored a hostile OpenSSL environment"
}
[ ! -e "$(stage_path_for_token "$hostile_openssl_token")" ] &&
  [ ! -L "$(stage_path_for_token "$hostile_openssl_token")" ] ||
  die "hostile OpenSSL environment fixture retained its signing stage"
assert_no_secret_leak "$hostile_openssl_log"
unset hostile_openssl_conf hostile_openssl_modules hostile_openssl_token \
  hostile_openssl_log hostile_openssl_status

for action in \
    normal unlink-key unlink-pin chmod-stage \
    mutate-key mutate-pin replace-key-name replace-pin-name \
    substitute-root verify-substitute-root hup-pre-ignore hup-pre \
    quit-pre quit-mid term-mid; do
  token="$(next_token)"
  action_log="$temporary_root/$action.log"
  if [[ "$action" =~ ^(hup|quit|term)- ]]; then
    lifecycle_runner=run_signal_harness
  else
    lifecycle_runner=run_harness
  fi
  "$lifecycle_runner" "$action" "$token" "$key" "$certificate" "$pin" \
    > "$action_log" 2>&1 || {
      cat "$action_log" >&2
      die "controlled signing lifecycle action failed: $action"
    }
  [ ! -e "$(stage_path_for_token "$token")" ] &&
    [ ! -L "$(stage_path_for_token "$token")" ] ||
    die "controlled signing lifecycle retained stage after: $action"
  assert_no_secret_leak "$action_log"
done
unset lifecycle_runner

# Exercise the exact fixed-tool authority logic against an isolated mechanical
# copy whose trusted directory owner is rebound from root to this fixture UID.
openssl_authority_dir="$temporary_root/openssl-authority"
openssl_authority_library="$temporary_root/openssl-authority.sh"
mkdir "$openssl_authority_dir"
chmod 0755 "$openssl_authority_dir"
openssl_authority_uid="$(/usr/bin/python3 -I -c 'import os; print(os.getuid())')"
case "$openssl_authority_dir" in
  *" "*|*"#"*|*"&"*|*"'"*|*'"'*)
    die "unsafe OpenSSL authority fixture path"
    ;;
esac
{
  printf '%s\n' \
    "RELEASE_BUILD=true" \
    "RELEASE_PYTHON_DIRECTORY_FD_OPEN=true" \
    "RELEASE_PYTHON_DIRECTORY_FD=55" \
    "RELEASE_PYTHON_DIRECTORY='$openssl_authority_dir'" \
    "RELEASE_PYTHON_BIN=/usr/bin/python3" \
    "RELEASE_OPENSSL_BIN='$openssl_authority_dir/openssl'" \
    "RELEASE_OPENSSL_IDENTITY=''" \
    "verify_release_python_authority() { return 0; }"
  sed -n \
    '/^release_openssl_identity_record() {/,/^require_apt_list_decoder() {/p' \
    "$wrapper" | sed '$d' | sed \
      -e "s#/usr/bin#$openssl_authority_dir#g" \
      -e "s/expected_uid_text != \"0\"/expected_uid_text != \"$openssl_authority_uid\"/" \
      -e "s/openssl 0$/openssl $openssl_authority_uid/"
} > "$openssl_authority_library"
# shellcheck disable=SC1090
. "$openssl_authority_library"
exec 55< "$openssl_authority_dir"

cp /usr/bin/openssl "$openssl_authority_dir/openssl"
chmod 0755 "$openssl_authority_dir/openssl"
capture_release_openssl_authority ||
  die "isolated OpenSSL authority rejected its valid direct executable"
mv "$openssl_authority_dir/openssl" "$openssl_authority_dir/openssl.held"
cp /usr/bin/openssl "$openssl_authority_dir/openssl"
chmod 0755 "$openssl_authority_dir/openssl"
if verify_release_openssl_authority; then
  die "OpenSSL authority accepted a replaced executable mapping"
fi
rm -f -- "$openssl_authority_dir/openssl" "$openssl_authority_dir/openssl.held"

cp /usr/bin/openssl "$openssl_authority_dir/openssl"
chmod 0755 "$openssl_authority_dir/openssl"
capture_release_openssl_authority ||
  die "OpenSSL authority could not recapture a valid executable"
chmod 0700 "$openssl_authority_dir/openssl"
if verify_release_openssl_authority; then
  die "OpenSSL authority accepted post-capture executable state drift"
fi
chmod 0775 "$openssl_authority_dir/openssl"
if capture_release_openssl_authority; then
  die "OpenSSL authority accepted a group-writable executable"
fi
rm -f -- "$openssl_authority_dir/openssl"

ln -s /usr/bin/openssl "$openssl_authority_dir/openssl"
if capture_release_openssl_authority; then
  die "OpenSSL authority accepted a symlinked executable"
fi
rm -f -- "$openssl_authority_dir/openssl"
mkdir "$openssl_authority_dir/openssl"
if capture_release_openssl_authority; then
  die "OpenSSL authority accepted a directory in place of its executable"
fi
rmdir "$openssl_authority_dir/openssl"
exec 55<&-
unset -f release_openssl_identity_record capture_release_openssl_authority \
  verify_release_openssl_authority verify_release_python_authority
unset openssl_authority_dir openssl_authority_library openssl_authority_uid \
  RELEASE_BUILD RELEASE_PYTHON_DIRECTORY_FD_OPEN RELEASE_PYTHON_DIRECTORY_FD \
  RELEASE_PYTHON_DIRECTORY RELEASE_PYTHON_BIN RELEASE_OPENSSL_BIN \
  RELEASE_OPENSSL_IDENTITY

printf '%s\n' 'Controlled module-signing lifecycle tests passed.'
