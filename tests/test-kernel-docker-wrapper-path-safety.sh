#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root=""
temporary_parent=""
real_git="$(command -v git)"
real_mktemp="$(command -v mktemp)"
real_python3="$(command -v python3)"
real_shasum="$(command -v shasum)"
real_stat="$(command -v stat)"
retained_private_root_log=""
sigchld_victim_pid=""

cleanup() {
  local retained_root

  if [ -n "$sigchld_victim_pid" ] &&
     kill -0 "$sigchld_victim_pid" 2>/dev/null; then
    kill -TERM "$sigchld_victim_pid" 2>/dev/null || true
    wait "$sigchld_victim_pid" 2>/dev/null || true
  fi
  sigchld_victim_pid=""
  if [ -n "$retained_private_root_log" ] &&
     [ -f "$retained_private_root_log" ]; then
    while IFS= read -r retained_root; do
      case "$retained_root" in
        /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*|\
        /tmp/sp11-kernel-support.*|/private/tmp/sp11-kernel-support.*)
          if [ -L "$retained_root" ]; then
            rm -f -- "$retained_root"
          elif [ -d "$retained_root" ]; then
            rm -rf -- "$retained_root"
          fi
          ;;
      esac
    done < "$retained_private_root_log"
  fi
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

stable_directory_identity() {
  local path="$1"

  case "$(uname -s)" in
    Darwin) stat -f '%d:%i:%Lp:%u:%g' "$path" ;;
    Linux) stat -c '%d:%i:%a:%u:%g' -- "$path" ;;
    *) die "unsupported fixture stat platform" ;;
  esac
}

full_regular_state() {
  local digest
  local metadata
  local path="$1"

  case "$(uname -s)" in
    Darwin)
      metadata="$(stat -f \
        '%HT:%d:%i:%Lp:%u:%g:%l:%z:%Fm:%Fc' "$path")"
      ;;
    Linux)
      metadata="$(stat -c \
        '%F:%d:%i:%a:%u:%g:%h:%s:%y:%z' -- "$path")"
      ;;
    *) die "unsupported fixture stat platform" ;;
  esac
  digest="$(shasum -a 256 "$path")"
  digest="${digest%% *}"
  printf '%s:%s\n' "$metadata" "$digest"
}

for tool in cmp git grep mktemp openssl readlink shasum stat; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-docker-wrapper-safety.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
temporary_parent="$(dirname "$temporary_root")"
retained_private_root_log="$temporary_root/retained-private-roots"
mock_release_volume_root="$temporary_root/mock-release-volumes"
mock_container_state_root="$temporary_root/mock-container-state"
mock_container_audit_root="$temporary_root/mock-container-audit"
: > "$retained_private_root_log"
mkdir -p \
  "$mock_release_volume_root" \
  "$mock_container_state_root" \
  "$mock_container_audit_root/created" \
  "$mock_container_audit_root/started" \
  "$mock_container_audit_root/removed" \
  "$mock_container_audit_root/terminated"
: > "$mock_container_audit_root/created-order"
: > "$mock_container_audit_root/started-order"
: > "$mock_container_audit_root/removal-targets"
export FIXTURE_REAL_MKTEMP="$real_mktemp"
export FIXTURE_REAL_PYTHON3="$real_python3"
export FIXTURE_REAL_GIT="$real_git"
export FIXTURE_REAL_SHASUM="$real_shasum"
export FIXTURE_REAL_STAT="$real_stat"
export FIXTURE_RETAINED_PRIVATE_ROOT_LOG="$retained_private_root_log"
export MOCK_RELEASE_VOLUME_ROOT="$mock_release_volume_root"
export MOCK_CONTAINER_STATE_ROOT="$mock_container_state_root"
export MOCK_CONTAINER_AUDIT_ROOT="$mock_container_audit_root"
support_dir="$temporary_root/support"
mock_bin="$temporary_root/mock-bin"
capture_attack_bin="$temporary_root/capture-attack-bin"
mkdir -p \
  "$support_dir/scripts" \
  "$support_dir/config/kernel-baselines" \
  "$support_dir/config/kernel-signing" \
  "$support_dir/patches/release" \
  "$support_dir/payload/kernel-debs" \
  "$mock_bin" \
  "$capture_attack_bin"
cp "$repo_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh" "$support_dir/scripts/"
cp "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" "$support_dir/scripts/"
cp "$repo_dir/scripts/emit-sp11-kernel-release-state.sh" "$support_dir/scripts/"
cp "$repo_dir/scripts/sp11-kernel-build-inputs.py" "$support_dir/scripts/"
cp "$repo_dir/scripts/sp11-kernel-release-state.py" "$support_dir/scripts/"
cp "$repo_dir/scripts/validate-sp11-image-release-manifests.py" \
  "$support_dir/scripts/"
chmod +x \
  "$support_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
  "$support_dir/scripts/build-sp11-qcom-x1e-kernel.sh"
cmp "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" \
  "$support_dir/scripts/build-sp11-qcom-x1e-kernel.sh" ||
  die "fixture support did not retain the exact inner builder bytes"
inner_builder_source_sha="$(
  shasum -a 256 "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" | awk '{print $1}'
)"
inner_builder_fixture_sha="$(
  shasum -a 256 "$support_dir/scripts/build-sp11-qcom-x1e-kernel.sh" | awk '{print $1}'
)"
[ "$inner_builder_fixture_sha" = "$inner_builder_source_sha" ] ||
  die "fixture support inner builder digest differs from its source authority"
sed 's#/usr/lib/apt/apt-helper#/sp11-fixture-missing-apt-helper#g' \
  "$repo_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
  > "$support_dir/scripts/build-sp11-qcom-x1e-kernel-docker-no-apt-helper.sh"
chmod +x "$support_dir/scripts/build-sp11-qcom-x1e-kernel-docker-no-apt-helper.sh"
printf 'build/\n' > "$support_dir/.gitignore"
printf 'fixture patch input\n' > "$support_dir/patches/release/0001-fixture.patch"

signing_fixture_dir="$temporary_root/module-signing"
mkdir "$signing_fixture_dir"
openssl rand -out "$signing_fixture_dir/pin" -hex 24
chmod 0600 "$signing_fixture_dir/pin"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -out "$signing_fixture_dir/raw.pem" >/dev/null 2>&1
openssl req -new -x509 -sha512 -key "$signing_fixture_dir/raw.pem" \
  -subj /CN=sp11-wrapper-fixture -days 1 \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -out "$signing_fixture_dir/cert.pem" >/dev/null 2>&1
openssl pkcs8 -topk8 -in "$signing_fixture_dir/raw.pem" \
  -out "$signing_fixture_dir/key.pem" \
  -passout "file:$signing_fixture_dir/pin" >/dev/null 2>&1
chmod 0600 "$signing_fixture_dir/key.pem"
chmod 0644 "$signing_fixture_dir/cert.pem"
signing_fixture_certificate_text="$(openssl x509 \
  -in "$signing_fixture_dir/cert.pem" -noout -text)"
printf '%s\n' "$signing_fixture_certificate_text" |
  grep -Fq 'Signature Algorithm: sha512WithRSAEncryption' ||
  die "controlled-signing fixture certificate is not RSA/SHA-512"
printf '%s\n' "$signing_fixture_certificate_text" |
  grep -A1 -F 'X509v3 Basic Constraints: critical' |
  grep -Fq 'CA:FALSE' ||
  die "controlled-signing fixture certificate is not critical CA:false"
[ "$(printf '%s\n' "$signing_fixture_certificate_text" |
    grep -A1 -F 'X509v3 Key Usage: critical' | tail -n 1 |
    tr -d '[:space:]')" = "DigitalSignature" ] ||
  die "controlled-signing fixture certificate key usage is not exact"
unset signing_fixture_certificate_text
cp "$signing_fixture_dir/cert.pem" \
  "$support_dir/config/kernel-signing/sp11-module-signing-cert.pem"
signing_fixture_sha="$(openssl x509 -in "$signing_fixture_dir/cert.pem" \
  -outform DER | shasum -a 256 | awk '{print $1}')"
signing_fixture_fingerprint="$(openssl x509 \
  -in "$signing_fixture_dir/cert.pem" -noout -sha256 -fingerprint)"
signing_fixture_fingerprint="${signing_fixture_fingerprint#*=}"
signing_fixture_fingerprint="$(printf '%s' "$signing_fixture_fingerprint" |
  tr '[:lower:]' '[:upper:]')"
signing_fixture_serial="$(openssl x509 -in "$signing_fixture_dir/cert.pem" \
  -noout -serial)"
signing_fixture_serial="$(printf '%s' "${signing_fixture_serial#*=}" |
  tr '[:lower:]' '[:upper:]')"

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
SP11_KERNEL_MODULE_SIGNING_POLICY="sp11-controlled-rsa4096-sha512-v1"
SP11_KERNEL_MODULE_SIGNING_KEY_PATH="/sp11-signing/signing.pem"
SP11_KERNEL_MODULE_SIGNING_PIN_PATH="/sp11-signing/pin"
SP11_KERNEL_MODULE_SIGNING_CERT_PATH="config/kernel-signing/sp11-module-signing-cert.pem"
SP11_KERNEL_MODULE_SIGNING_CERT_SHA256="$signing_fixture_sha"
SP11_KERNEL_MODULE_SIGNING_CERT_FINGERPRINT="$signing_fixture_fingerprint"
SP11_KERNEL_MODULE_SIGNING_CERT_SERIAL="$signing_fixture_serial"
SP11_KERNEL_MODULE_SIGNING_ALLOWED_UNSIGNED_PATH="config/kernel-signing/sp11-module-signing-allowed-unsigned.txt"
SP11_KERNEL_MODULE_SIGNING_ALLOWED_UNSIGNED_SHA256="eb507e006b37ad7d291a37524f3f2f6b5281c5a3f98738dc07056a3ca7cba800"
SP11_KERNEL_BUILD_TARGET="binary-indep binary-qcom-x1e"
SP11_KERNEL_PATCH_DIRS="patches/release"
EOF_BASELINE
cat > "$support_dir/scripts/validate-sp11-kernel-baseline.sh" <<'EOF_BASELINE_VALIDATOR'
#!/usr/bin/env bash
set -euo pipefail
baseline=""
baseline_fd=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir) [ "$#" -ge 2 ]; shift 2 ;;
    --emit-release-values) shift ;;
    --baseline-fd) [ "$#" -ge 2 ]; baseline_fd="$2"; shift 2 ;;
    *) baseline="$1"; shift ;;
  esac
done
if [ -n "$baseline_fd" ]; then
  [ "$baseline_fd" = 3 ]
  baseline=/dev/fd/3
fi
test -f "$baseline"
aba_control_root=""
if [ "${MOCK_BASELINE_ROOT_ABA:-false}" = "true" ]; then
  aba_full_regular_state() {
    local aba_digest
    local aba_metadata
    local aba_path="$1"

    case "${OSTYPE:-}" in
      darwin*)
        aba_metadata="$("$FIXTURE_REAL_STAT" -f \
          '%HT:%d:%i:%Lp:%u:%g:%l:%z:%Fm:%Fc' "$aba_path")"
        ;;
      linux*)
        aba_metadata="$("$FIXTURE_REAL_STAT" -c \
          '%F:%d:%i:%a:%u:%g:%h:%s:%y:%z' -- "$aba_path")"
        ;;
      *) exit 71 ;;
    esac
    aba_digest="$("$FIXTURE_REAL_SHASUM" -a 256 "$aba_path")"
    aba_digest="${aba_digest%% *}"
    printf '%s:%s\n' "$aba_metadata" "$aba_digest"
  }
  aba_stable_directory_identity() {
    case "${OSTYPE:-}" in
      darwin*) "$FIXTURE_REAL_STAT" -f '%d:%i:%Lp:%u:%g' "$1" ;;
      linux*) "$FIXTURE_REAL_STAT" -c '%d:%i:%a:%u:%g' -- "$1" ;;
      *) exit 71 ;;
    esac
  }

  test -n "${MOCK_BASELINE_ABA_BACKUP:-}"
  aba_control_root="$(cat \
    "$MOCK_BASELINE_ABA_BACKUP/capture/control-root-path")"
  test -d "$aba_control_root"
  test ! -L "$aba_control_root"
  test -f "$aba_control_root/kernel-baseline.env"
  test ! -L "$aba_control_root/kernel-baseline.env"
  test -f "$aba_control_root/validate-sp11-kernel-baseline.sh"
  test ! -L "$aba_control_root/validate-sp11-kernel-baseline.sh"
  aba_stable_directory_identity "$aba_control_root" \
    > "$MOCK_BASELINE_ABA_BACKUP/pre-root-stable"
  aba_full_regular_state "$aba_control_root/kernel-baseline.env" \
    > "$MOCK_BASELINE_ABA_BACKUP/pre-baseline-state"
  aba_full_regular_state \
    "$aba_control_root/validate-sp11-kernel-baseline.sh" \
    > "$MOCK_BASELINE_ABA_BACKUP/pre-validator-state"
  mv "$aba_control_root" "$MOCK_BASELINE_ABA_BACKUP/control-root"
  mkdir "$aba_control_root"
  aba_stable_directory_identity "$aba_control_root" \
    > "$MOCK_BASELINE_ABA_BACKUP/substitute-root-stable"
  printf '%s\n' 'if then' \
    > "$aba_control_root/kernel-baseline.env"
  if /bin/bash -n "$aba_control_root/kernel-baseline.env" \
      >/dev/null 2>&1; then
    exit 72
  fi
  "$FIXTURE_REAL_SHASUM" -a 256 "$aba_control_root/kernel-baseline.env" \
    > "$MOCK_BASELINE_ABA_BACKUP/substitute-baseline-sha256"
fi
# shellcheck disable=SC1090
. "$baseline"
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
  SP11_KERNEL_MODULE_SIGNING_POLICY \
  SP11_KERNEL_MODULE_SIGNING_KEY_PATH \
  SP11_KERNEL_MODULE_SIGNING_PIN_PATH \
  SP11_KERNEL_MODULE_SIGNING_CERT_PATH \
  SP11_KERNEL_MODULE_SIGNING_CERT_SHA256 \
  SP11_KERNEL_MODULE_SIGNING_CERT_FINGERPRINT \
  SP11_KERNEL_MODULE_SIGNING_CERT_SERIAL \
  SP11_KERNEL_MODULE_SIGNING_ALLOWED_UNSIGNED_PATH \
  SP11_KERNEL_MODULE_SIGNING_ALLOWED_UNSIGNED_SHA256 \
  SP11_KERNEL_BUILD_TARGET \
  SP11_KERNEL_PATCH_DIRS; do
  printf '%s\t%s\n' "$variable" "${!variable}"
done
if [ -n "$aba_control_root" ]; then
  rm -f "$aba_control_root/kernel-baseline.env"
  rmdir "$aba_control_root"
  mv "$MOCK_BASELINE_ABA_BACKUP/control-root" "$aba_control_root"
  : > "$MOCK_BASELINE_ABA_BACKUP/completed"
fi
EOF_BASELINE_VALIDATOR
cat > "$support_dir/scripts/validate-sp11-oci-index.py" <<'EOF_OCI_VALIDATOR'
#!/usr/bin/env python3
import sys
if sys.flags.isolated != 1:
    raise SystemExit("error: OCI index validator requires isolated Python startup")
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

# Exercise the exact embedded interpreter-authority program independently of
# the host layout.  macOS supplies a direct regular /usr/bin/python3, while
# Ubuntu supplies the reviewed one-hop python3 -> python3.N symlink; the two
# positive cases and every hostile case must therefore be deterministic on
# both hosts.
/usr/bin/python3 -I - "$wrapper" \
  "$support_dir/scripts/build-sp11-qcom-x1e-kernel.sh" \
  "$temporary_root/python-authority" <<'PY_AUTHORITY'
import os
from pathlib import Path
import subprocess
import sys

wrapper = Path(sys.argv[1])
inner_builder = Path(sys.argv[2])
fixture_root = Path(sys.argv[3])
source = wrapper.read_text(encoding="utf-8")
begin = "# SP11_RELEASE_PYTHON_AUTHORITY_PROGRAM_BEGIN\n"
end = "\n# SP11_RELEASE_PYTHON_AUTHORITY_PROGRAM_END"
if source.count(begin) != 1 or source.count(end) != 1:
    raise SystemExit("embedded Python-authority program markers are not exact")
program = source.split(begin, 1)[1].split(end, 1)[0]
injection_marker = "    # SP11_RELEASE_PYTHON_AUTHORITY_AFTER_INITIAL_STATE\n"
if program.count(injection_marker) != 1:
    raise SystemExit("embedded Python-authority drift marker is not exact")
inner_source = inner_builder.read_text(encoding="utf-8")
inner_begin = "# SP11_INNER_PYTHON_AUTHORITY_PROGRAM_BEGIN\n"
inner_end = "\n# SP11_INNER_PYTHON_AUTHORITY_PROGRAM_END"
if inner_source.count(inner_begin) != 1 or inner_source.count(inner_end) != 1:
    raise SystemExit("inner Python-authority program markers are not exact")
inner_program = inner_source.split(inner_begin, 1)[1].split(inner_end, 1)[0]
inner_injection_marker = "    # SP11_INNER_PYTHON_AUTHORITY_AFTER_INITIAL_STATE\n"
if inner_program.count(inner_injection_marker) != 1:
    raise SystemExit("inner Python-authority drift marker is not exact")


def new_case(name: str) -> Path:
    path = fixture_root / name
    path.mkdir(parents=True, mode=0o755)
    return path


def regular(path: Path, mode: int = 0o755) -> None:
    path.write_bytes(b"fixture Python executable\n")
    path.chmod(mode)


def run_case(
    directory: Path,
    *,
    expect: bool,
    expected_uid=None,
    injected: str = "",
) -> subprocess.CompletedProcess[bytes]:
    case_program = program
    if injected:
        case_program = case_program.replace(
            injection_marker,
            injection_marker + injected,
            1,
        )
    descriptor = os.open(
        directory,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    try:
        result = subprocess.run(
            [
                "/usr/bin/python3",
                "-I",
                "-c",
                case_program,
                str(descriptor),
                str(directory),
                "python3",
                str(os.getuid() if expected_uid is None else expected_uid),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            pass_fds=(descriptor,),
        )
    finally:
        os.close(descriptor)
    if (result.returncode == 0) != expect:
        raise AssertionError(
            f"unexpected Python-authority result for {directory.name}: "
            f"{result.returncode}, {result.stderr!r}"
        )
    if result.stderr:
        raise AssertionError(
            f"Python-authority case leaked a diagnostic: {result.stderr!r}"
        )
    return result


def run_inner_case(
    directory: Path,
    *,
    expect: bool,
    expected_uid=None,
    injected: str = "",
) -> subprocess.CompletedProcess[bytes]:
    case_program = inner_program
    if injected:
        case_program = case_program.replace(
            inner_injection_marker,
            inner_injection_marker + injected,
            1,
        )
    saved_descriptor = -1
    directory_descriptor = -1
    execution_source = -1
    try:
        try:
            saved_descriptor = os.dup(8)
        except OSError:
            pass
        reservation = os.open(os.devnull, os.O_RDONLY | os.O_CLOEXEC)
        try:
            os.dup2(reservation, 8, inheritable=True)
        finally:
            if reservation != 8:
                os.close(reservation)
        directory_descriptor = os.open(
            directory,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        execution_source = os.open(
            directory / "python3",
            os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC,
        )
        os.dup2(execution_source, 8, inheritable=True)
        result = subprocess.run(
            [
                "/usr/bin/python3",
                "-I",
                "-c",
                case_program,
                str(directory_descriptor),
                str(directory),
                "python3",
                str(os.getuid() if expected_uid is None else expected_uid),
                "8",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            pass_fds=(directory_descriptor, 8),
        )
    finally:
        if execution_source >= 0:
            os.close(execution_source)
        if directory_descriptor >= 0:
            os.close(directory_descriptor)
        if saved_descriptor >= 0:
            try:
                os.dup2(saved_descriptor, 8, inheritable=True)
            finally:
                os.close(saved_descriptor)
        else:
            try:
                os.close(8)
            except OSError:
                pass
    if (result.returncode == 0) != expect:
        raise AssertionError(
            f"unexpected inner Python-authority result for {directory.name}: "
            f"{result.returncode}, {result.stderr!r}"
        )
    if result.stderr:
        raise AssertionError(
            f"inner Python-authority case leaked a diagnostic: {result.stderr!r}"
        )
    return result


direct = new_case("direct")
regular(direct / "python3")
direct_result = run_case(direct, expect=True)
direct_fields = direct_result.stdout.decode("ascii").split()
assert len(direct_fields) == 29 and direct_fields[9] == "regular"
assert direct_fields[19] == "python3"
inner_direct_result = run_inner_case(direct, expect=True)
inner_direct_fields = inner_direct_result.stdout.decode("ascii").split()
assert len(inner_direct_fields) == 29 and inner_direct_fields[9] == "regular"
assert inner_direct_fields[19] == "python3"

linked = new_case("linked")
regular(linked / "python3.12")
os.symlink("python3.12", linked / "python3")
linked_result = run_case(linked, expect=True)
linked_fields = linked_result.stdout.decode("ascii").split()
assert len(linked_fields) == 29 and linked_fields[9] == "symlink"
assert linked_fields[19] == "python3.12"
inner_linked_result = run_inner_case(linked, expect=True)
inner_linked_fields = inner_linked_result.stdout.decode("ascii").split()
assert len(inner_linked_fields) == 29 and inner_linked_fields[9] == "symlink"
assert inner_linked_fields[19] == "python3.12"

special = new_case("special")
os.mkfifo(special / "python3")
run_case(special, expect=False)
run_inner_case(special, expect=False)

wrong_owner = new_case("wrong-owner")
regular(wrong_owner / "python3")
run_case(wrong_owner, expect=False, expected_uid=os.getuid() + 1)
run_inner_case(wrong_owner, expect=False, expected_uid=os.getuid() + 1)

unsafe_directory = new_case("unsafe-directory")
regular(unsafe_directory / "python3")
unsafe_directory.chmod(0o777)
run_case(unsafe_directory, expect=False)
run_inner_case(unsafe_directory, expect=False)

unsafe_target = new_case("unsafe-target")
regular(unsafe_target / "python3.12", 0o775)
os.symlink("python3.12", unsafe_target / "python3")
run_case(unsafe_target, expect=False)
run_inner_case(unsafe_target, expect=False)

absolute_link = new_case("absolute-link")
regular(absolute_link / "python3.12")
os.symlink(str(absolute_link / "python3.12"), absolute_link / "python3")
run_case(absolute_link, expect=False)
run_inner_case(absolute_link, expect=False)

link_chain = new_case("link-chain")
regular(link_chain / "python3.13")
os.symlink("python3.13", link_chain / "python3.12")
os.symlink("python3.12", link_chain / "python3")
run_case(link_chain, expect=False)
run_inner_case(link_chain, expect=False)

alias_drift = new_case("alias-drift")
regular(alias_drift / "python3.12")
regular(alias_drift / "python3.13")
os.symlink("python3.12", alias_drift / "python3")
alias_drift_trigger = fixture_root / "alias-drift-trigger"
run_case(
    alias_drift,
    expect=False,
    injected=(
        "    os.unlink(alias_name, dir_fd=directory_descriptor)\n"
        "    os.symlink(\"python3.13\", alias_name, "
        "dir_fd=directory_descriptor)\n"
        f"    with open({str(alias_drift_trigger)!r}, \"xb\") as fixture_marker:\n"
        "        fixture_marker.write(b\"triggered\\n\")\n"
    ),
)
assert alias_drift_trigger.read_bytes() == b"triggered\n"

target_drift = new_case("target-drift")
regular(target_drift / "python3.12")
os.symlink("python3.12", target_drift / "python3")
target_drift_trigger = fixture_root / "target-drift-trigger"
run_case(
    target_drift,
    expect=False,
    injected=(
        "    fixture_writer = os.open(\n"
        "        target_name,\n"
        "        os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC,\n"
        "        dir_fd=directory_descriptor,\n"
        "    )\n"
        "    try:\n"
        "        os.lseek(fixture_writer, 0, os.SEEK_END)\n"
        "        os.write(fixture_writer, b\"drift\")\n"
        "        os.fsync(fixture_writer)\n"
        "    finally:\n"
        "        os.close(fixture_writer)\n"
        f"    with open({str(target_drift_trigger)!r}, \"xb\") as fixture_marker:\n"
        "        fixture_marker.write(b\"triggered\\n\")\n"
    ),
)
assert target_drift_trigger.read_bytes() == b"triggered\n"

directory_drift = new_case("directory-drift")
regular(directory_drift / "python3")
directory_drift_trigger = fixture_root / "directory-drift-trigger"
run_case(
    directory_drift,
    expect=False,
    injected=(
        "    os.chmod(directory_path, 0o700)\n"
        f"    with open({str(directory_drift_trigger)!r}, \"xb\") as fixture_marker:\n"
        "        fixture_marker.write(b\"triggered\\n\")\n"
    ),
)
assert directory_drift_trigger.read_bytes() == b"triggered\n"

inner_alias_drift = new_case("inner-alias-drift")
regular(inner_alias_drift / "python3.12")
regular(inner_alias_drift / "python3.13")
os.symlink("python3.12", inner_alias_drift / "python3")
inner_alias_trigger = fixture_root / "inner-alias-drift-trigger"
run_inner_case(
    inner_alias_drift,
    expect=False,
    injected=(
        "    os.unlink(alias_name, dir_fd=directory_descriptor)\n"
        "    os.symlink(\"python3.13\", alias_name, "
        "dir_fd=directory_descriptor)\n"
        f"    with open({str(inner_alias_trigger)!r}, \"xb\") as fixture_marker:\n"
        "        fixture_marker.write(b\"triggered\\n\")\n"
    ),
)
assert inner_alias_trigger.read_bytes() == b"triggered\n"

inner_target_drift = new_case("inner-target-drift")
regular(inner_target_drift / "python3.12")
os.symlink("python3.12", inner_target_drift / "python3")
inner_target_trigger = fixture_root / "inner-target-drift-trigger"
run_inner_case(
    inner_target_drift,
    expect=False,
    injected=(
        "    fixture_writer = os.open(\n"
        "        target_name,\n"
        "        os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC,\n"
        "        dir_fd=directory_descriptor,\n"
        "    )\n"
        "    try:\n"
        "        os.lseek(fixture_writer, 0, os.SEEK_END)\n"
        "        os.write(fixture_writer, b\"drift\")\n"
        "        os.fsync(fixture_writer)\n"
        "    finally:\n"
        "        os.close(fixture_writer)\n"
        f"    with open({str(inner_target_trigger)!r}, \"xb\") as fixture_marker:\n"
        "        fixture_marker.write(b\"triggered\\n\")\n"
    ),
)
assert inner_target_trigger.read_bytes() == b"triggered\n"

inner_directory_drift = new_case("inner-directory-drift")
regular(inner_directory_drift / "python3")
inner_directory_trigger = fixture_root / "inner-directory-drift-trigger"
run_inner_case(
    inner_directory_drift,
    expect=False,
    injected=(
        "    os.chmod(directory_path, 0o700)\n"
        f"    with open({str(inner_directory_trigger)!r}, \"xb\") as fixture_marker:\n"
        "        fixture_marker.write(b\"triggered\\n\")\n"
    ),
)
assert inner_directory_trigger.read_bytes() == b"triggered\n"
PY_AUTHORITY

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

run_with_ignored_sigchld() {
  "$real_python3" -I -c '
import os
import signal
import sys

signal.signal(signal.SIGCHLD, signal.SIG_IGN)
os.execve(sys.argv[1], sys.argv[1:], os.environ)
' "$@"
}

# The control files are staged inside an unpredictable private directory, then
# atomically installed as regular evidence files at the documented work root.
# A mock Docker client verifies the installed files before allowing completion.
cat > "$mock_bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${MOCK_DOCKER_ACTIVITY_MARKER:-}" ]; then
  : > "$MOCK_DOCKER_ACTIVITY_MARKER"
fi

if [ -n "${MOCK_SCRIPT_BINDING_RESTORE_DIR:-}" ]; then
  test -n "${MOCK_SCRIPT_BINDING_RESTORE_NAME:-}"
  test -n "${MOCK_SCRIPT_BINDING_RESTORE_BACKUP:-}"
  test -n "${MOCK_SCRIPT_BINDING_RESTORE_MARKER:-}"
  test -n "${MOCK_SCRIPT_BINDING_DISPLACED:-}"
  if [ -f "$MOCK_SCRIPT_BINDING_RESTORE_DIR/$MOCK_SCRIPT_BINDING_RESTORE_BACKUP" ]; then
    test -f "$MOCK_SCRIPT_BINDING_RESTORE_DIR/$MOCK_SCRIPT_BINDING_RESTORE_NAME"
    /bin/mv \
      "$MOCK_SCRIPT_BINDING_RESTORE_DIR/$MOCK_SCRIPT_BINDING_RESTORE_NAME" \
      "$MOCK_SCRIPT_BINDING_DISPLACED"
    /bin/mv \
      "$MOCK_SCRIPT_BINDING_RESTORE_DIR/$MOCK_SCRIPT_BINDING_RESTORE_BACKUP" \
      "$MOCK_SCRIPT_BINDING_RESTORE_DIR/$MOCK_SCRIPT_BINDING_RESTORE_NAME"
    : > "$MOCK_SCRIPT_BINDING_RESTORE_MARKER"
  else
    test -f "$MOCK_SCRIPT_BINDING_RESTORE_MARKER"
  fi
  unset \
    MOCK_SCRIPT_BINDING_RESTORE_DIR \
    MOCK_SCRIPT_BINDING_RESTORE_NAME \
    MOCK_SCRIPT_BINDING_RESTORE_BACKUP \
    MOCK_SCRIPT_BINDING_RESTORE_MARKER \
    MOCK_SCRIPT_BINDING_DISPLACED
fi

if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] &&
   [ "${3:-}" = "inspect" ] && [ "${4:-}" = "--raw" ]; then
  if [ "${MOCK_OCI_NONZERO_MODE:-false}" = "true" ]; then
    test -n "${MOCK_OCI_SUPERVISOR_STATE:-}"
    test -f "${MOCK_OCI_INDEX:-}"
    printf '%s\n' "$$" > "$MOCK_OCI_SUPERVISOR_STATE/producer-pid"
    /bin/cat "$MOCK_OCI_INDEX"
    exit 37
  fi
  if [ "${MOCK_OCI_HANG_MODE:-false}" = "true" ]; then
    test -n "${MOCK_OCI_SUPERVISOR_STATE:-}"
    printf '%s\n' "$$" > "$MOCK_OCI_SUPERVISOR_STATE/producer-pid"
    trap ': > "$MOCK_OCI_SUPERVISOR_STATE/producer-terminated"; exit 143' \
      HUP INT TERM
    while :; do
      /bin/sleep 1
    done
  fi
  if [ "${MOCK_OCI_STDERR_FLOOD_MODE:-false}" = "true" ]; then
    test -n "${MOCK_OCI_SUPERVISOR_STATE:-}"
    printf '%s\n' "$$" > "$MOCK_OCI_SUPERVISOR_STATE/producer-pid"
    trap ': > "$MOCK_OCI_SUPERVISOR_STATE/producer-terminated"; exit 143' \
      HUP INT TERM
    /usr/bin/python3 -I -c \
      'import os; os.write(2, b"hostile OCI diagnostic flood\n" * 65536)' || true
    while :; do
      /bin/sleep 1
    done
  fi
  if [ "${MOCK_OCI_SIGNAL_MODE:-false}" = "true" ]; then
    test -n "${MOCK_OCI_SIGNAL_STATE:-}"
    printf '%s\n' "$$" > "$MOCK_OCI_SIGNAL_STATE/producer-pid"
    trap ': > "$MOCK_OCI_SIGNAL_STATE/producer-terminated"; exit 143' \
      HUP INT TERM
    printf 'partial hostile OCI producer bytes\n'
    kill -TERM "$PPID"
    kill -HUP "$PPID"
    while :; do
      /bin/sleep 1
    done
  fi
  if [ -n "${MOCK_INSTALL_LATE_DOCKER_SHIM:-}" ]; then
    test -n "${MOCK_LATE_DOCKER_SHIM_MARKER:-}"
    printf '#!/bin/bash\n: > %q\nexit 97\n' \
      "$MOCK_LATE_DOCKER_SHIM_MARKER" > "$MOCK_INSTALL_LATE_DOCKER_SHIM"
    chmod +x "$MOCK_INSTALL_LATE_DOCKER_SHIM"
  fi
  if [ "${MOCK_OCI_SMALL_STDERR:-false}" = "true" ]; then
    printf 'bounded non-authoritative OCI warning\n' >&2
  fi
  test -f "$MOCK_OCI_INDEX"
  /bin/cat "$MOCK_OCI_INDEX"
  exit 0
fi

if [ "${1:-}" = volume ] && [ "${2:-}" = create ]; then
  if [ "${MOCK_VOLUME_NONZERO_MODE:-false}" = "true" ]; then
    test -n "${MOCK_VOLUME_SUPERVISOR_STATE:-}"
    printf '%s\n' "$$" > "$MOCK_VOLUME_SUPERVISOR_STATE/producer-pid"
    for volume_name in "$@"; do :; done
    printf '%s\n' "$volume_name"
    exit 39
  fi
  if [ "${MOCK_VOLUME_HANG_MODE:-false}" = "true" ]; then
    test -n "${MOCK_VOLUME_SUPERVISOR_STATE:-}"
    printf '%s\n' "$$" > "$MOCK_VOLUME_SUPERVISOR_STATE/producer-pid"
    trap ': > "$MOCK_VOLUME_SUPERVISOR_STATE/producer-terminated"; exit 143' \
      HUP INT TERM
    while :; do
      /bin/sleep 1
    done
  fi
  if [ "${MOCK_VOLUME_SIGNAL_MODE:-false}" = "true" ]; then
    test -n "${MOCK_VOLUME_SUPERVISOR_STATE:-}"
    printf '%s\n' "$$" > "$MOCK_VOLUME_SUPERVISOR_STATE/producer-pid"
    trap ': > "$MOCK_VOLUME_SUPERVISOR_STATE/producer-terminated"; exit 143' \
      HUP INT TERM
    kill -TERM "$PPID"
    kill -HUP "$PPID"
    while :; do
      /bin/sleep 1
    done
  fi
  if [ "${MOCK_VOLUME_STDERR_FLOOD_MODE:-false}" = "true" ]; then
    test -n "${MOCK_VOLUME_SUPERVISOR_STATE:-}"
    printf '%s\n' "$$" > "$MOCK_VOLUME_SUPERVISOR_STATE/producer-pid"
    trap ': > "$MOCK_VOLUME_SUPERVISOR_STATE/producer-terminated"; exit 143' \
      HUP INT TERM
    /usr/bin/python3 -I -c \
      'import os; os.write(2, b"hostile volume diagnostic flood\n" * 65536)' || true
    while :; do
      /bin/sleep 1
    done
  fi
  if [ "${MOCK_VOLUME_SMALL_STDERR:-false}" = "true" ]; then
    printf 'bounded non-authoritative volume warning\n' >&2
  fi
  for volume_name in "$@"; do :; done
  mkdir "$MOCK_RELEASE_VOLUME_ROOT/$volume_name"
  printf '%s\n' "$volume_name"
  exit 0
fi
if [ "${1:-}" = volume ] && [ "${2:-}" = inspect ]; then
  for volume_name in "$@"; do :; done
  printf '%s %s\n' "$volume_name" "$RELEASE_STATE_VOLUME_TOKEN"
  exit 0
fi

mock_container_id=""
if [ "${1:-}" = create ]; then
  mock_container_name=""
  previous=""
  for argument in "${@:2}"; do
    if [ "$previous" = "--name" ]; then
      mock_container_name="$argument"
      previous=""
      continue
    fi
    previous="$argument"
  done
  case "$mock_container_name" in
    sp11-release-exporter-[0-9a-f][0-9a-f]*) ;;
    *) printf 'mock Docker received no private supervisor name\n' >&2; exit 81 ;;
  esac
  mock_container_id="${mock_container_name#sp11-release-exporter-}"
  [[ "$mock_container_id" =~ ^[0-9a-f]{64}$ ]] || exit 82
  mock_container_dir="$MOCK_CONTAINER_STATE_ROOT/$mock_container_id"
  mkdir "$mock_container_dir"
  printf '%s\0' "${@:2}" > "$mock_container_dir/args"
  if printf '%s\n' "${@:2}" |
      grep -Fxq '/sp11-control/docker-build-inside.sh'; then
    printf 'build\n' > "$mock_container_dir/kind"
  else
    printf 'exporter\n' > "$mock_container_dir/kind"
  fi
  : > "$MOCK_CONTAINER_AUDIT_ROOT/created/$mock_container_id"
  printf '%s\n' "$mock_container_id" \
    >> "$MOCK_CONTAINER_AUDIT_ROOT/created-order"
  printf '%s\n' "$mock_container_id"
  exit 0
fi

if [ "${1:-}" = inspect ]; then
  for mock_container_id in "$@"; do :; done
  [[ "$mock_container_id" =~ ^[0-9a-f]{64}$ ]] || exit 83
  mock_container_dir="$MOCK_CONTAINER_STATE_ROOT/$mock_container_id"
  [ -d "$mock_container_dir" ] && [ -f "$mock_container_dir/kind" ] || exit 1
  if printf '%s\n' "$@" | grep -Fxq '{{json .Mounts}}'; then
    mock_container_args=()
    while IFS= read -r -d '' argument; do
      mock_container_args+=("$argument")
    done < "$mock_container_dir/args"
    mock_mount_volume=""
    mock_mount_repo=""
    previous=""
    for argument in "${mock_container_args[@]}"; do
      if [ "$previous" = --mount ]; then
        case "$argument" in
          type=volume,source=*,destination=/work,readonly)
            mock_mount_volume="${argument#type=volume,source=}"
            mock_mount_volume="${mock_mount_volume%%,*}"
            ;;
        esac
        previous=""
        continue
      fi
      if [ "$previous" = -v ]; then
        case "$argument" in
          *:/repo:ro) mock_mount_repo="${argument%:/repo:ro}" ;;
        esac
        previous=""
        continue
      fi
      previous="$argument"
    done
    [ -n "$mock_mount_volume" ] && [ -n "$mock_mount_repo" ] || exit 92
    case "$mock_mount_repo" in *'"'*|*'\\'*) exit 93 ;; esac
    printf '[{"Type":"volume","Name":"%s","Destination":"/work","RW":false},{"Type":"bind","Source":"%s","Destination":"/repo","RW":false}]\n' \
      "$mock_mount_volume" "$mock_mount_repo"
    exit 0
  fi
  if [ "${MOCK_BUILD_CONTAINER_INSPECT_FAILURE:-false}" = "true" ] &&
     grep -Fxq build "$mock_container_dir/kind"; then
    printf 'hostile fixture inspect failure\n' >&2
    exit 84
  fi
  [ -f "$mock_container_dir/exit-status" ] &&
    [ "$(cat "$mock_container_dir/exit-status")" = 0 ] || exit 85
  printf 'exited 0\n'
  exit 0
fi

if [ "${1:-}" = rm ]; then
  [ "${2:-}" = -f ] || exit 86
  mock_container_id="${3:-}"
  [ "$#" -eq 3 ] &&
    [[ "$mock_container_id" =~ ^[0-9a-f]{64}$ ]] || exit 87
  mock_container_dir="$MOCK_CONTAINER_STATE_ROOT/$mock_container_id"
  [ -d "$mock_container_dir" ] || exit 88
  printf '%s\n' "$mock_container_id" \
    >> "$MOCK_CONTAINER_AUDIT_ROOT/removal-targets"
  : > "$MOCK_CONTAINER_AUDIT_ROOT/removed/$mock_container_id"
  rm -f \
    "$mock_container_dir/args" \
    "$mock_container_dir/kind" \
    "$mock_container_dir/exit-status"
  rmdir "$mock_container_dir"
  printf '%s\n' "$mock_container_id"
  exit 0
fi

if [ "${1:-}" = start ]; then
  [ "${2:-}" = --attach ] && [ "$#" -eq 3 ] || exit 89
  mock_container_id="$3"
  [[ "$mock_container_id" =~ ^[0-9a-f]{64}$ ]] || exit 90
  mock_container_dir="$MOCK_CONTAINER_STATE_ROOT/$mock_container_id"
  [ -f "$mock_container_dir/args" ] || exit 91
  mock_container_args=()
  while IFS= read -r -d '' argument; do
    mock_container_args+=("$argument")
  done < "$mock_container_dir/args"
  set -- "${mock_container_args[@]}"
  : > "$MOCK_CONTAINER_AUDIT_ROOT/started/$mock_container_id"
  printf '%s\n' "$mock_container_id" \
    >> "$MOCK_CONTAINER_AUDIT_ROOT/started-order"
fi

host_work=""
state_work=""
host_control=""
host_repo=""
previous=""
last_argument=""
penultimate_argument=""
antepenultimate_argument=""
for argument in "$@"; do
  antepenultimate_argument="$penultimate_argument"
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
  if [ "$previous" = "--mount" ]; then
    case "$argument" in
      type=volume,source=*,destination=/work,volume-nocopy)
        release_volume="${argument#type=volume,source=}"
        release_volume="${release_volume%%,*}"
        state_work="$MOCK_RELEASE_VOLUME_ROOT/$release_volume"
        ;;
    esac
    previous=""
    continue
  fi
  previous="$argument"
done

if [ -n "$host_control" ]; then
  [ -n "$state_work" ] && [ -d "$state_work" ] && [ ! -L "$state_work" ]
  mkdir -m 700 \
    "$state_work/apt-archives" "$state_work/apt-indexes" \
    "$state_work/apt-lists" "$state_work/artifacts"
  cp "$host_control/docker-build-args.txt" "$state_work/docker-build-args.txt"
  cp "$host_control/docker-build-inside.sh" "$state_work/docker-build-inside.sh"
  cp "$host_control/sp11-oci-index.json" "$state_work/sp11-oci-index.json"
  chmod 600 \
    "$state_work/docker-build-args.txt" "$state_work/docker-build-inside.sh" \
    "$state_work/sp11-oci-index.json"
  mock_work="$state_work"
else
  [ -n "$host_work" ]
  mock_work="$host_work"
fi

if [ -n "$mock_container_id" ] &&
   [ "${MOCK_BUILD_CONTAINER_SIGNAL_MODE:-false}" = "true" ] &&
   [ -n "$host_control" ]; then
  printf '0\n' > "$state_work/supervisor-mutation-counter"
  trap '
    printf "143\n" > "$mock_container_dir/exit-status"
    : > "$MOCK_CONTAINER_AUDIT_ROOT/terminated/$mock_container_id"
    exit 143
  ' HUP INT TERM
  kill -TERM "$PPID"
  mock_mutation_count=0
  while :; do
    mock_mutation_count=$((mock_mutation_count + 1))
    printf '%s\n' "$mock_mutation_count" \
      > "$state_work/supervisor-mutation-counter"
    /bin/sleep 0.05
  done
fi
[ -f "$mock_work/docker-build-args.txt" ] && [ ! -L "$mock_work/docker-build-args.txt" ]
[ -f "$mock_work/docker-build-inside.sh" ] && [ ! -L "$mock_work/docker-build-inside.sh" ]
case "$(uname -s)" in
  Darwin)
    args_mode="$(stat -f '%Lp' "$mock_work/docker-build-args.txt")"
    script_mode="$(stat -f '%Lp' "$mock_work/docker-build-inside.sh")"
    ;;
  *)
    args_mode="$(stat -c '%a' "$mock_work/docker-build-args.txt")"
    script_mode="$(stat -c '%a' "$mock_work/docker-build-inside.sh")"
    ;;
esac
[ "$args_mode" = "600" ]
if [ -n "$host_control" ]; then
  [ "$script_mode" = "600" ]
else
  [ "$script_mode" = "700" ] && [ -x "$host_work/docker-build-inside.sh" ]
fi
grep -Fxq -- '--source' "$mock_work/docker-build-args.txt"
if [ -n "$host_control" ]; then
  [ "$last_argument" = "/sp11-control/docker-build-inside.sh" ]
  [ "$penultimate_argument" = "-p" ]
  [ "$antepenultimate_argument" = "/bin/bash" ]
  [ -f "$host_control/kernel-baseline.env" ] &&
    [ ! -L "$host_control/kernel-baseline.env" ]
  [ -f "$host_control/docker-build-args.txt" ] &&
    [ ! -L "$host_control/docker-build-args.txt" ]
  [ -f "$host_control/docker-build-inside.sh" ] &&
    [ ! -L "$host_control/docker-build-inside.sh" ]
  cmp "$host_control/docker-build-args.txt" "$mock_work/docker-build-args.txt"
  cmp "$host_control/docker-build-inside.sh" "$mock_work/docker-build-inside.sh"
  if [ -f "$host_control/sp11-oci-index.json" ]; then
    cmp "$host_control/sp11-oci-index.json" "$mock_work/sp11-oci-index.json"
  fi
  grep -Fq 'done < "$control_dir/docker-build-args.txt"' \
    "$host_control/docker-build-inside.sh"
  printf 'private read-only controls verified\n' \
    > "${MOCK_ABA_WORK_ROOT:-$mock_work}/mock-private-control-verified"
fi
case "${MOCK_ABA_SWAP:-}" in
  work-args)
    [ -n "$host_control" ] && [ -n "${MOCK_ABA_BACKUP_ROOT:-}" ]
    printf '%s\n' "$host_control" > "$MOCK_ABA_BACKUP_ROOT/control-root-path"
    printf '%s\n' "$(dirname "$host_repo")" \
      > "$MOCK_ABA_BACKUP_ROOT/support-root-path"
    mv "$MOCK_ABA_WORK_ROOT/docker-build-args.txt" "$MOCK_ABA_BACKUP_ROOT/work-args"
    printf '%s\n' '--source' 'hostile-work-evidence' \
      > "$MOCK_ABA_WORK_ROOT/docker-build-args.txt"
    grep -Fxq -- '--release-build' "$host_control/docker-build-args.txt"
    rm -f "$MOCK_ABA_WORK_ROOT/docker-build-args.txt"
    mv "$MOCK_ABA_BACKUP_ROOT/work-args" "$MOCK_ABA_WORK_ROOT/docker-build-args.txt"
    : > "$MOCK_ABA_WORK_ROOT/mock-work-aba-completed"
    ;;
  private-args)
    [ -n "$host_control" ] && [ -n "${MOCK_ABA_BACKUP_ROOT:-}" ]
    printf '%s\n' "$host_control" > "$MOCK_ABA_BACKUP_ROOT/control-root-path"
    printf '%s\n' "$(dirname "$host_repo")" \
      > "$MOCK_ABA_BACKUP_ROOT/support-root-path"
    mv "$host_control/docker-build-args.txt" "$MOCK_ABA_BACKUP_ROOT/private-args"
    printf '%s\n' '--source' 'hostile-private-authority' \
      > "$host_control/docker-build-args.txt"
    grep -Fxq -- 'hostile-private-authority' "$host_control/docker-build-args.txt"
    rm -f "$host_control/docker-build-args.txt"
    mv "$MOCK_ABA_BACKUP_ROOT/private-args" "$host_control/docker-build-args.txt"
    : > "$MOCK_ABA_WORK_ROOT/mock-private-aba-completed"
    ;;
  private-root)
    [ -n "$host_control" ] && [ -n "${MOCK_ABA_BACKUP_ROOT:-}" ]
    printf '%s\n' "$host_control" > "$MOCK_ABA_BACKUP_ROOT/control-root-path"
    printf '%s\n' "$(dirname "$host_repo")" \
      > "$MOCK_ABA_BACKUP_ROOT/support-root-path"
    mv "$host_control" "$MOCK_ABA_BACKUP_ROOT/private-root"
    mkdir "$host_control"
    printf '%s\n' '--source' 'hostile-private-root' \
      > "$host_control/docker-build-args.txt"
    grep -Fxq -- 'hostile-private-root' "$host_control/docker-build-args.txt"
    rm -f "$host_control/docker-build-args.txt"
    rmdir "$host_control"
    mv "$MOCK_ABA_BACKUP_ROOT/private-root" "$host_control"
    : > "$MOCK_ABA_WORK_ROOT/mock-private-root-aba-completed"
    ;;
  support-root)
    [ -n "$host_repo" ] && [ -n "${MOCK_ABA_BACKUP_ROOT:-}" ]
    support_root="$(dirname "$host_repo")"
    printf '%s\n' "$host_control" > "$MOCK_ABA_BACKUP_ROOT/control-root-path"
    printf '%s\n' "$support_root" > "$MOCK_ABA_BACKUP_ROOT/support-root-path"
    mv "$support_root" "$MOCK_ABA_BACKUP_ROOT/support-root"
    mkdir "$support_root"
    mkdir "$support_root/support"
    printf 'hostile support replacement\n' > "$support_root/support/README"
    rm -f "$support_root/support/README"
    rmdir "$support_root/support"
    rmdir "$support_root"
    mv "$MOCK_ABA_BACKUP_ROOT/support-root" "$support_root"
    : > "$MOCK_ABA_WORK_ROOT/mock-support-root-aba-completed"
    ;;
esac
mkdir -p "$mock_work/artifacts"
if [ "${MOCK_CREATE_DEB:-false}" = "true" ]; then
  printf 'fixture kernel package\n' \
    > "$mock_work/artifacts/linux-image-7.2.0-fixture-qcom-x1e_1_arm64.deb"
fi
printf 'installed control files verified\n' > "$mock_work/mock-docker-verified"
case "${MOCK_MUTATE_CONTROL:-}" in
  docker-build-args.txt|docker-build-inside.sh|sp11-oci-index.json)
    printf 'mutated by fake Docker\n' \
      >> "${MOCK_MUTATE_ROOT:-$mock_work}/$MOCK_MUTATE_CONTROL"
    ;;
esac
if [ -n "$mock_container_id" ]; then
  printf '0\n' > "$mock_container_dir/exit-status"
fi
EOF_DOCKER
cat > "$mock_bin/mktemp" <<'EOF_MOCK_MKTEMP'
#!/usr/bin/env bash
set -euo pipefail
created="$("$FIXTURE_REAL_MKTEMP" "$@")"
case "$created" in
  /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*|\
  /tmp/sp11-kernel-support.*|/private/tmp/sp11-kernel-support.*)
    printf '%s\n' "$created" >> "$FIXTURE_RETAINED_PRIVATE_ROOT_LOG"
    ;;
esac
printf '%s\n' "$created"
EOF_MOCK_MKTEMP
chmod +x "$mock_bin/docker" "$mock_bin/mktemp"

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
    printf '%s\n' "$created" >> "$FIXTURE_RETAINED_PRIVATE_ROOT_LOG"
    ;;
  /tmp/sp11-kernel-support.*|/private/tmp/sp11-kernel-support.*)
    printf '%s\n' "$created" > "$CAPTURE_ATTACK_STATE/support-root-path"
    printf '%s\n' "$created" >> "$FIXTURE_RETAINED_PRIVATE_ROOT_LOG"
    ;;
esac
if [ "${CAPTURE_ATTACK_MODE:-}" = "work-ancestor-symlink" ] &&
   [ ! -e "${CAPTURE_ATTACK_MARKER:-}" ]; then
  case "$created" in
    /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*)
      [ -d "$CAPTURE_ATTACK_WORK_PARENT" ] &&
        [ ! -L "$CAPTURE_ATTACK_WORK_PARENT" ]
      mv "$CAPTURE_ATTACK_WORK_PARENT" \
        "$CAPTURE_ATTACK_STATE/original-work-ancestor"
      ln -s "$CAPTURE_ATTACK_VICTIM" "$CAPTURE_ATTACK_WORK_PARENT"
      : > "$CAPTURE_ATTACK_MARKER"
      ;;
  esac
fi
printf '%s\n' "$created"
EOF_CAPTURE_MKTEMP
cat > "$capture_attack_bin/python3" <<'EOF_CAPTURE_PYTHON3'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = -I ] && [ "${2:-}" = -c ] &&
   [[ "${3:-}" == *"os.O_EXCL"* ]] &&
   [ ! -e "$CAPTURE_ATTACK_MARKER" ]; then
  parent="${4:-}"
  name="${7:-}"
  operation="${9:-}"
  case "${CAPTURE_ATTACK_MODE:-}:$name:$operation" in
    baseline-root-symlink:kernel-baseline.env:copy)
      case "$parent" in
        /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
        *) exit 92 ;;
      esac
      mv "$parent" "$CAPTURE_ATTACK_STATE/original-control-root"
      ln -s "$CAPTURE_ATTACK_VICTIM" "$parent"
      printf '%s\n' "$parent" > "$CAPTURE_ATTACK_STATE/root-path"
      : > "$CAPTURE_ATTACK_MARKER"
      ;;
    snapshot-symlink:kernel-baseline.env:copy)
      case "$parent" in
        /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
        *) exit 94 ;;
      esac
      ln -s "$CAPTURE_ATTACK_VICTIM" "$parent/$name"
      : > "$CAPTURE_ATTACK_MARKER"
      ;;
    private-args-fifo:docker-build-args.txt:stdin)
      case "$parent" in
        /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
        *) exit 95 ;;
      esac
      mkfifo "$parent/$name"
      : > "$CAPTURE_ATTACK_MARKER"
      ;;
    retained-fifo-link:docker-build-args.txt:copy)
      [ "$parent" = "$CAPTURE_ATTACK_WORK_ROOT" ] || exit 96
      ln -s "$CAPTURE_ATTACK_VICTIM" "$parent/$name"
      : > "$CAPTURE_ATTACK_MARKER"
      ;;
  esac
fi
exec "$FIXTURE_REAL_PYTHON3" "$@"
EOF_CAPTURE_PYTHON3
cat > "$capture_attack_bin/stat" <<'EOF_CAPTURE_STAT'
#!/usr/bin/env bash
set -euo pipefail
last=""
for argument in "$@"; do
  last="$argument"
done
if [[ "${CAPTURE_ATTACK_MODE:-}" =~ ^artifact-root-late-(symlink|fifo)$ ]] &&
   [ "$(pwd -P)/${last#./}" = "$CAPTURE_ATTACK_ARTIFACT_ROOT" ] &&
   [ ! -e "$CAPTURE_ATTACK_MARKER" ]; then
  captured="$("$FIXTURE_REAL_STAT" "$@")"
  mv "$CAPTURE_ATTACK_ARTIFACT_ROOT" \
    "$CAPTURE_ATTACK_STATE/original-artifact-root"
  case "$CAPTURE_ATTACK_MODE" in
    artifact-root-late-symlink)
      ln -s "$CAPTURE_ATTACK_VICTIM" "$CAPTURE_ATTACK_ARTIFACT_ROOT"
      ;;
    artifact-root-late-fifo)
      mkfifo "$CAPTURE_ATTACK_ARTIFACT_ROOT"
      ;;
  esac
  : > "$CAPTURE_ATTACK_MARKER"
  printf '%s\n' "$captured"
  exit 0
fi
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
  "$capture_attack_bin/python3" \
  "$capture_attack_bin/stat" \
  "$capture_attack_bin/shasum"

# Immutable validation needs an LZ4 list decoder on hosts without apt-helper.
# An isolated PATH and a wrapper fixture with an unavailable system helper make
# both fallback branches deterministic, including on Ubuntu hosts.
decoder_bin="$temporary_root/decoder-bin"
decoder_docker_marker="$temporary_root/decoder-docker-invoked"
mkdir "$decoder_bin"
for tool in \
  awk bash basename chmod dirname find git grep mkdir python3 rm rmdir shasum \
  sort stat touch tr uname wc; do
  tool_path="$(type -P "$tool")"
  [ -n "$tool_path" ] || die "missing decoder-preflight fixture tool: $tool"
  ln -s "$tool_path" "$decoder_bin/$tool"
done
ln -s "$mock_bin/mktemp" "$decoder_bin/mktemp"
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
  --module-signing-key "$signing_fixture_dir/key.pem"
  --module-signing-certificate "$signing_fixture_dir/cert.pem"
  --module-signing-pin-file "$signing_fixture_dir/pin"
)

secure_release_work_root() {
  local work_root="$1" artifact_policy="${2:-create}"

  [ -d "$work_root" ] && [ ! -L "$work_root" ] ||
    die "fixture release work root is not a real directory: $work_root"
  chmod 0700 "$work_root"
  if [ "$artifact_policy" = create ] && [ ! -e "$work_root/artifacts" ] &&
     [ ! -L "$work_root/artifacts" ]; then
    mkdir "$work_root/artifacts"
  fi
  if [ -d "$work_root/artifacts" ] && [ ! -L "$work_root/artifacts" ]; then
    chmod 0700 "$work_root/artifacts"
  fi
}

run_wrapper_with_hostile_openssl_bounded() {
  local configuration="$1" modules="$2" random_file="$3" log="$4"
  shift 4
  /usr/bin/python3 -I -c '
import os
import signal
import subprocess
import sys

configuration, modules, random_file, log, *command = sys.argv[1:]
descriptor = os.open(
    log,
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
        command,
        stdin=subprocess.DEVNULL,
        stdout=output,
        stderr=subprocess.STDOUT,
        env=environment,
        start_new_session=True,
    )
    try:
        status = process.wait(timeout=30)
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
' "$configuration" "$modules" "$random_file" "$log" "$@"
}

"$wrapper" --help > "$temporary_root/wrapper-help.txt"
grep -Fq 'preexist as real, empty, mode-0700 directories owned' \
  "$temporary_root/wrapper-help.txt" ||
  die "wrapper help omitted the preexisting release-root authority contract"
openssl_sanitizer_line="$(grep -n '^sanitize_openssl_environment$' "$wrapper")"
openssl_sanitizer_line="${openssl_sanitizer_line%%:*}"
first_host_python_line="$(grep -n -m 1 '/usr/bin/python3 -I -c' "$wrapper")"
first_host_python_line="${first_host_python_line%%:*}"
[[ "$openssl_sanitizer_line" =~ ^[1-9][0-9]*$ ]] &&
  [[ "$first_host_python_line" =~ ^[1-9][0-9]*$ ]] &&
  [ "$openssl_sanitizer_line" -lt "$first_host_python_line" ] &&
  [ "$(grep -Fxc \
    '  unset OPENSSL_MODULES OPENSSL_ENGINES RANDFILE' "$wrapper")" -eq 1 ] &&
  [ "$(grep -Fxc '  export OPENSSL_CONF=/dev/null' "$wrapper")" -eq 1 ] ||
  die "wrapper does not sanitize OpenSSL authority before its first host Python"
unset openssl_sanitizer_line first_host_python_line

# Release mode never reaches the host-filesystem `/work` probe or legacy
# payload staging: both combinations are rejected before any private root or
# mutable destination is created.
release_early_count="$(wc -l < "$retained_private_root_log" | tr -d '[:space:]')"
if PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
    --work-dir "$support_dir/build/release-host-work-rejected/work" \
    "${decoder_args[@]}" \
    --container-work-dir /work \
    --dry-run > "$temporary_root/release-host-work-rejected.log" 2>&1; then
  die "release accepted --container-work-dir /work"
fi
grep -Fq 'requires a named Linux work volume' \
  "$temporary_root/release-host-work-rejected.log" ||
  die "release /work rejection was not explicit"
[ "$(wc -l < "$retained_private_root_log" | tr -d '[:space:]')" = \
  "$release_early_count" ] ||
  die "release /work rejection created a private root"
[ ! -e "$support_dir/build/release-host-work-rejected" ] ||
  die "release /work rejection created its host work path"

if PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
    --work-dir "$support_dir/build/release-payload-rejected/work" \
    "${decoder_args[@]}" \
    --copy-to-payload \
    --dry-run > "$temporary_root/release-payload-rejected.log" 2>&1; then
  die "release accepted --copy-to-payload"
fi
grep -Fq 'cannot copy packages into the tracked payload tree' \
  "$temporary_root/release-payload-rejected.log" ||
  die "release payload-copy rejection was not explicit"
[ "$(wc -l < "$retained_private_root_log" | tr -d '[:space:]')" = \
  "$release_early_count" ] ||
  die "release payload-copy rejection created a private root"
if find "$support_dir/payload/kernel-debs" -maxdepth 1 \
    -name '.sp11-kernel-debs.*' -print | grep -q .; then
  die "release payload-copy rejection created a staging directory"
fi

missing_decoder_work="$support_dir/build/missing-list-decoder/work"
mkdir -p "$missing_decoder_work"
secure_release_work_root "$missing_decoder_work"
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
mkdir -p "$available_decoder_work/artifacts"
secure_release_work_root "$available_decoder_work"
if DECODER_DOCKER_MARKER="$decoder_docker_marker" PATH="$decoder_bin" \
    "$no_apt_helper_wrapper" \
      --work-dir "$available_decoder_work" \
      "${decoder_args[@]}" \
      > "$temporary_root/available-list-decoder.log" 2>&1; then
  die "decoder fixture unexpectedly completed its sentinel Docker call"
fi
[ -f "$decoder_docker_marker" ] ||
  { cat "$temporary_root/available-list-decoder.log" >&2;
    die "available lz4 did not pass the immutable decoder preflight"; }
grep -Fq 'Could not capture the raw pinned OCI index.' \
  "$temporary_root/available-list-decoder.log" ||
  { cat "$temporary_root/available-list-decoder.log" >&2;
    die "available lz4 did not reach the sentinel Docker failure"; }

# Keep normal release fixtures portable on hosts without apt-helper.
cp "$decoder_bin/lz4" "$mock_bin/lz4"

# Release dry-runs validate the same baseline and retain the exact contiguous
# deterministic identity block that a live invocation will bind as Input 1.
release_dry_work="$support_dir/build/release-identity-dry/work"
mkdir -p "$release_dry_work"
secure_release_work_root "$release_dry_work"
hostile_template="$temporary_root/hostile-git-template"
hostile_template_marker="$temporary_root/hostile-git-template-ran"
mkdir -p "$hostile_template/hooks"
cat > "$hostile_template/hooks/post-checkout" <<EOF_HOSTILE_TEMPLATE
#!/usr/bin/env bash
: > "$hostile_template_marker"
EOF_HOSTILE_TEMPLATE
chmod +x "$hostile_template/hooks/post-checkout"
release_private_count_before="$(wc -l < "$retained_private_root_log" | tr -d '[:space:]')"
signing_fixture_pin_value="$(tr -d '\n' < "$signing_fixture_dir/pin")"
hostile_release_openssl_conf="$temporary_root/hostile-release-openssl.cnf"
hostile_release_openssl_modules="$temporary_root/hostile-release-openssl-modules"
hostile_release_openssl_random="$temporary_root/hostile-release-random"
mkfifo "$hostile_release_openssl_conf"
mkdir "$hostile_release_openssl_modules"
mkfifo "$hostile_release_openssl_modules/default.so"
release_identity_status=0
set +e
GIT_TEMPLATE_DIR="$hostile_template" \
  KBUILD_SIGN_PIN="$signing_fixture_pin_value" \
  PATH="$mock_bin:/usr/bin:/bin" \
  run_wrapper_with_hostile_openssl_bounded \
    "$hostile_release_openssl_conf" \
    "$hostile_release_openssl_modules" \
    "$hostile_release_openssl_random" \
    "$temporary_root/release-identity-dry.log" \
    "$wrapper" --work-dir "$release_dry_work" \
    "${decoder_args[@]}" --dry-run
release_identity_status=$?
set -e
[ "$release_identity_status" -eq 0 ] || {
  cat "$temporary_root/release-identity-dry.log" >&2
  die "release dry-run honored a hostile OpenSSL environment"
}
release_support_root="$(sed -n "$((release_private_count_before + 1))p" \
  "$retained_private_root_log")"
release_control_root="$(sed -n "$((release_private_count_before + 2))p" \
  "$retained_private_root_log")"
case "$release_support_root:$release_control_root" in
  /tmp/sp11-kernel-support.*:/tmp/sp11-kernel-baseline.*|\
  /private/tmp/sp11-kernel-support.*:/private/tmp/sp11-kernel-baseline.*) ;;
  *) die "successful release dry-run did not record its two retained private roots" ;;
esac
[ -d "$release_support_root/support" ] && [ ! -L "$release_support_root" ] &&
  [ ! -L "$release_support_root/support" ] ||
  die "successful release dry-run did not retain its private support checkout"
[ -f "$release_control_root/kernel-baseline.env" ] &&
  [ -f "$release_control_root/docker-build-args.txt" ] &&
  [ -f "$release_control_root/docker-build-inside.sh" ] &&
  [ ! -L "$release_control_root" ] ||
  die "successful release dry-run did not retain its bounded private controls"
[ ! -e "$hostile_template_marker" ] ||
  die "release support snapshot honored an ambient hostile Git template"
identity_block="$(
  awk '$0 == "--release-build" { remaining = 11 }
       remaining > 0 { print; remaining-- }' \
    "$release_dry_work/docker-build-args.txt"
)"
expected_identity_block="$(cat <<'EOF_IDENTITY_BLOCK'
--release-build
--module-signing-policy
sp11-controlled-rsa4096-sha512-v1
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
redacted_signing_mount="$(printf '%q' \
  'type=bind,source=<private-signing-directory>,destination=/sp11-signing,readonly')"
redacted_signing_mount_count="$(
  grep -Fo -- "$redacted_signing_mount" \
    "$temporary_root/release-identity-dry.log" | wc -l | tr -d '[:space:]'
)"
[ "$redacted_signing_mount_count" = 1 ] ||
  die "release dry-run did not redact its private signing stage exactly once"
encrypted_key_boundary='-----BEGIN ENCRYPTED '"PRIVATE KEY-----"
plain_key_boundary='-----BEGIN '"PRIVATE KEY-----"
rsa_key_boundary='-----BEGIN RSA '"PRIVATE KEY-----"
for signing_public_output in \
  "$temporary_root/release-identity-dry.log" \
  "$release_dry_work/docker-build-args.txt" \
  "$release_dry_work/docker-build-inside.sh" \
  "$release_control_root/docker-build-args.txt" \
  "$release_control_root/docker-build-inside.sh"; do
  if grep -Fq -- '/tmp/sp11-module-signing.' "$signing_public_output"; then
    die "release dry-run leaked its private signing stage path"
  fi
  for forbidden_signing_value in \
    "$signing_fixture_dir/key.pem" \
    "$signing_fixture_dir/cert.pem" \
    "$signing_fixture_dir/pin" \
    "$signing_fixture_pin_value" \
    "$encrypted_key_boundary" \
    "$plain_key_boundary" \
    "$rsa_key_boundary"; do
    if grep -Fq -- "$forbidden_signing_value" "$signing_public_output"; then
      die "release dry-run leaked a private signing input into retained output"
    fi
  done
done
unset signing_fixture_pin_value signing_public_output forbidden_signing_value \
  encrypted_key_boundary plain_key_boundary rsa_key_boundary \
  redacted_signing_mount redacted_signing_mount_count \
  hostile_release_openssl_conf hostile_release_openssl_modules \
  hostile_release_openssl_random release_identity_status
grep -Fq 'SP11_IMMUTABLE_APT_REQUIRED=true' "$temporary_root/release-identity-dry.log" ||
  die "release dry-run did not print the immutable APT container environment"
grep -Fq ':/sp11-control:ro' \
  "$temporary_root/release-identity-dry.log" ||
  die "release dry-run did not mount its private control directory read-only"
grep -Fq '/sp11-control/docker-build-inside.sh' \
  "$temporary_root/release-identity-dry.log" ||
  die "release dry-run did not execute its private read-only entrypoint"
grep -Fq '/bin/bash -p /sp11-control/docker-build-inside.sh' \
  "$temporary_root/release-identity-dry.log" ||
  die "release dry-run did not use privileged Bash for its mounted entrypoint"
grep -Fxq '#!/bin/bash -p' "$release_dry_work/docker-build-inside.sh" ||
  die "release entrypoint did not suppress inherited Bash startup authority"
grep -Fq \
  '/bin/bash -p /repo/scripts/build-sp11-qcom-x1e-kernel.sh "${build_args[@]}"' \
  "$release_dry_work/docker-build-inside.sh" ||
  die "release entrypoint did not invoke the inner builder with privileged Bash"
grep -Fq 'source=sp11-release-state-dry-run' \
  "$temporary_root/release-identity-dry.log" ||
  die "release dry-run did not isolate mutable state in a daemon volume"
if grep -Fq '/sp11-host-evidence' \
    "$temporary_root/release-identity-dry.log"; then
  die "release dry-run retained an unused host-evidence bind"
fi
if grep -Fq "$release_dry_work:/work" \
    "$temporary_root/release-identity-dry.log"; then
  die "release dry-run exposed the hostile host work root as writable /work"
fi
grep -Fq 'Private release-state volume did not start empty.' \
  "$release_dry_work/docker-build-inside.sh" ||
  die "release entrypoint did not require a fresh daemon state volume"
grep -Fq '"$DOCKER_BIN" buildx imagetools inspect --raw "$IMAGE"' \
  "$wrapper" ||
  die "release OCI capture did not use the resolved absolute Docker command"
if grep -Fq 'docker buildx imagetools inspect --raw "$IMAGE"' "$wrapper"; then
  die "release OCI capture retained an ambient PATH-resolved Docker command"
fi
[ "$(grep -Fc 'run_release_command_bounded 4096' "$wrapper")" -eq 2 ] ||
  die "release volume create/inspect did not share the bounded Docker supervisor"
[ "$(grep -Fc 'signal.signal(signal.SIGCHLD, signal.SIG_DFL)' \
    "$wrapper")" -eq 2 ] ||
  die "release embedded child supervisors did not establish exact wait authority"
[ "$(grep -Fc 'signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL' \
    "$wrapper")" -eq 4 ] ||
  die "release embedded child supervisors did not recheck wait authority at Popen"
[ "$(grep -Fc 'SP11_RELEASE_SUPERVISOR_FIXTURE_SIGCHLD_IGNORE' \
    "$wrapper")" -eq 2 ] ||
  die "release embedded child supervisors lack exact inherited-ignore fixtures"
[ "$(grep -Fc 'signal.signal(signal.SIGCHLD, signal.SIG_IGN)' \
    "$wrapper")" -eq 2 ] ||
  die "release embedded child supervisors lack exact ignored dispositions"
grep -Fq 'Wrapper requires default CHLD/HUP/INT/QUIT/TERM dispositions at startup.' \
  "$wrapper" ||
  die "release wrapper lacks an early inherited-SIGCHLD refusal"
grep -Fq 'code = compile(payload_bytes, synthetic_name, "exec"' "$wrapper" ||
  die "release local programs were not compiled from verified committed bytes"
for forbidden_local_program in \
  'python3 "$COMMITTED_SUPPORT_ACCESS_DIR/scripts/validate-sp11-oci-index.py"' \
  '"$COMMITTED_SUPPORT_ACCESS_DIR/scripts/sp11-kernel-release-state.py"'; do
  if grep -Fq "$forbidden_local_program" "$wrapper"; then
    die "release retained a nested pathname local-program execution"
  fi
done
grep -Fq '/usr/bin/python3 -I /repo/scripts/sp11-kernel-build-inputs.py write' \
  "$release_dry_work/docker-build-inside.sh" ||
  die "release entrypoint did not seal build inputs inside daemon state"
grep -Fq '/usr/bin/python3 -I /repo/scripts/sp11-kernel-release-state.py seal' \
  "$release_dry_work/docker-build-inside.sh" ||
  die "release entrypoint did not seal the daemon-owned release state"
grep -Fq 'find /work -mindepth 1 -maxdepth 1 -print -quit' \
  "$release_dry_work/docker-build-inside.sh" ||
  die "release entrypoint did not use a bounded state-volume emptiness probe"
[ ! -e "$release_dry_work/apt-archives" ] &&
  [ ! -e "$release_dry_work/apt-indexes" ] &&
  [ ! -e "$release_dry_work/apt-lists" ] ||
  die "release dry-run recreated retained APT trees on the host"
[ "$(grep -Fc -- '--baseline /sp11-control/kernel-baseline.env' \
    "$release_dry_work/docker-build-inside.sh")" -eq 3 ] ||
  die "immutable APT and build-input sealing did not share the mounted baseline snapshot"
if grep -Fq -- '--baseline /repo/config/kernel-baselines/' \
    "$release_dry_work/docker-build-inside.sh"; then
  die "release entrypoint retained a live-worktree baseline authority"
fi

# The only host publication child must pre-exist as an empty real directory.
# Missing, symlinked, and special targets are immutable tripwires: setup must
# neither create through them nor remove them while retained private controls
# remain available as failure evidence.
work_mode_root="$temporary_root/work-root-mode"
work_mode_work="$support_dir/build/work-root-mode/work"
mkdir -p "$work_mode_root" "$work_mode_work/artifacts"
secure_release_work_root "$work_mode_work"
chmod 0755 "$work_mode_work"
work_mode_docker_count="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" 2>/dev/null || printf 0)"
if PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
    --work-dir "$work_mode_work" \
    "${decoder_args[@]}" \
    --dry-run > "$work_mode_root/wrapper.log" 2>&1; then
  die "release accepted a non-private host work-root mode"
fi
grep -Fq 'Release work root must be mode 0700 and owned by the invoking uid' \
  "$work_mode_root/wrapper.log" ||
  die "release work-root mode rejection was not explicit"
[ "$(wc -l < "$MOCK_CONTAINER_AUDIT_ROOT/created-order" 2>/dev/null || printf 0)" = \
  "$work_mode_docker_count" ] ||
  die "release work-root mode rejection reached Docker"

for artifact_root_attack in missing symlink fifo mode; do
  artifact_attack_root="$temporary_root/artifact-root-$artifact_root_attack"
  artifact_attack_work="$support_dir/build/artifact-root-$artifact_root_attack/work"
  artifact_attack_victim="$artifact_attack_root/victim"
  mkdir -p "$artifact_attack_root" "$artifact_attack_work"
  secure_release_work_root "$artifact_attack_work" preserve
  printf 'artifact-root victim must remain unchanged\n' \
    > "$artifact_attack_victim"
  artifact_attack_victim_state="$(regular_fingerprint "$artifact_attack_victim")"
  case "$artifact_root_attack" in
    missing) ;;
    symlink) ln -s "$artifact_attack_victim" "$artifact_attack_work/artifacts" ;;
    fifo) mkfifo "$artifact_attack_work/artifacts" ;;
    mode)
      mkdir "$artifact_attack_work/artifacts"
      chmod 0755 "$artifact_attack_work/artifacts"
      ;;
  esac
  artifact_attack_node_state=""
  if [ -e "$artifact_attack_work/artifacts" ] ||
     [ -L "$artifact_attack_work/artifacts" ]; then
    artifact_attack_node_state="$(node_full_metadata \
      "$artifact_attack_work/artifacts")"
  fi
  artifact_attack_private_count="$(wc -l < "$retained_private_root_log" | tr -d '[:space:]')"
  if MOCK_OCI_INDEX="$release_oci_index" \
      PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
        --work-dir "$artifact_attack_work" \
        "${decoder_args[@]}" \
        > "$artifact_attack_root/wrapper.log" 2>&1; then
    die "release accepted an unsafe host artifact root: $artifact_root_attack"
  fi
  case "$artifact_root_attack" in
    missing)
      grep -Fq 'artifact directory must already exist' \
        "$artifact_attack_root/wrapper.log" ||
        die "missing host artifact-root rejection was not explicit"
      [ ! -e "$artifact_attack_work/artifacts" ] ||
        die "release created its missing host artifact root"
      ;;
    symlink|fifo)
      grep -Fq 'Refusing unsafe release-build directory' \
        "$artifact_attack_root/wrapper.log" ||
        die "special host artifact-root rejection was not explicit"
      [ "$(node_full_metadata "$artifact_attack_work/artifacts")" = \
        "$artifact_attack_node_state" ] ||
        die "release changed its host artifact-root tripwire"
      ;;
    mode)
      grep -Fq 'Release artifact directory must be mode 0700 and owned by the invoking uid' \
        "$artifact_attack_root/wrapper.log" ||
        die "release artifact-root mode rejection was not explicit"
      [ "$(node_full_metadata "$artifact_attack_work/artifacts")" = \
        "$artifact_attack_node_state" ] ||
        die "release changed its wrong-mode artifact root"
      ;;
  esac
  [ "$(regular_fingerprint "$artifact_attack_victim")" = \
    "$artifact_attack_victim_state" ] ||
    die "release changed a host artifact-root victim"
  [ ! -e "$artifact_attack_work/sp11-kernel-retained-evidence.tar" ] ||
    die "unsafe host artifact root produced retained evidence"
  for retained_offset in 1 2; do
    retained_attack_root="$(sed -n \
      "$((artifact_attack_private_count + retained_offset))p" \
      "$retained_private_root_log")"
    [ -d "$retained_attack_root" ] && [ ! -L "$retained_attack_root" ] ||
      die "host artifact-root failure did not retain its private root"
  done
  if grep -Fq 'Imported verified retained kernel release evidence and final assets.' \
      "$artifact_attack_root/wrapper.log"; then
    die "unsafe host artifact root printed release success"
  fi
done

# Replace the validated empty artifact child immediately after its identity
# stat, before the cwd-relative held-FD acquisition. A FIFO must fail `cd`
# without blocking; a symlink must fail the cwd identity check before any
# descriptor is opened on the victim.
for artifact_late_attack in symlink fifo; do
  artifact_late_root="$temporary_root/artifact-root-late-$artifact_late_attack"
  artifact_late_state="$artifact_late_root/state"
  artifact_late_work="$support_dir/build/artifact-root-late-$artifact_late_attack/work"
  artifact_late_victim="$artifact_late_root/victim"
  artifact_late_marker="$artifact_late_root/attack-completed"
  mkdir -p \
    "$artifact_late_state" "$artifact_late_work/artifacts" \
    "$artifact_late_victim"
  secure_release_work_root "$artifact_late_work"
  printf 'late artifact-root victim must remain unchanged\n' \
    > "$artifact_late_victim/sentinel"
  artifact_late_victim_state="$(node_full_metadata "$artifact_late_victim")"
  artifact_late_sentinel_state="$(regular_fingerprint \
    "$artifact_late_victim/sentinel")"
  artifact_late_private_count="$(wc -l < "$retained_private_root_log" | tr -d '[:space:]')"
  if FIXTURE_REAL_GIT="$real_git" \
      FIXTURE_REAL_MKTEMP="$real_mktemp" \
      FIXTURE_REAL_SHASUM="$real_shasum" \
      FIXTURE_REAL_STAT="$real_stat" \
      CAPTURE_ATTACK_MODE="artifact-root-late-$artifact_late_attack" \
      CAPTURE_ATTACK_MARKER="$artifact_late_marker" \
      CAPTURE_ATTACK_STATE="$artifact_late_state" \
      CAPTURE_ATTACK_VICTIM="$artifact_late_victim" \
      CAPTURE_ATTACK_ARTIFACT_ROOT="$artifact_late_work/artifacts" \
      MOCK_OCI_INDEX="$release_oci_index" \
      PATH="$capture_attack_bin:$mock_bin:/usr/bin:/bin" "$wrapper" \
        --work-dir "$artifact_late_work" \
        "${decoder_args[@]}" \
        > "$artifact_late_root/wrapper.log" 2>&1; then
    die "release accepted a late artifact-root $artifact_late_attack"
  fi
  [ -f "$artifact_late_marker" ] ||
    die "late artifact-root fixture did not reach the acquisition boundary"
  case "$artifact_late_attack" in
    symlink)
      [ -L "$artifact_late_work/artifacts" ] &&
        [ "$(readlink "$artifact_late_work/artifacts")" = \
          "$artifact_late_victim" ] ||
        die "release removed its late artifact-root symlink tripwire"
      ;;
    fifo)
      [ -p "$artifact_late_work/artifacts" ] ||
        die "release removed its late artifact-root FIFO tripwire"
      ;;
  esac
  [ -d "$artifact_late_state/original-artifact-root" ] &&
    [ ! -L "$artifact_late_state/original-artifact-root" ] ||
    die "late artifact-root fixture lost the original empty directory"
  [ "$(node_full_metadata "$artifact_late_victim")" = \
    "$artifact_late_victim_state" ] &&
    [ "$(regular_fingerprint "$artifact_late_victim/sentinel")" = \
      "$artifact_late_sentinel_state" ] ||
    die "late artifact-root acquisition changed its victim"
  [ ! -e "$artifact_late_work/sp11-kernel-retained-evidence.tar" ] ||
    die "late artifact-root failure published an evidence tar"
  for retained_offset in 1 2; do
    retained_attack_root="$(sed -n \
      "$((artifact_late_private_count + retained_offset))p" \
      "$retained_private_root_log")"
    [ -d "$retained_attack_root" ] && [ ! -L "$retained_attack_root" ] ||
      die "late artifact-root failure did not retain its private root"
  done
  if grep -Fq 'Imported verified retained kernel release evidence and final assets.' \
      "$artifact_late_root/wrapper.log"; then
    die "late artifact-root failure printed release success"
  fi
done

# The command producer signals the exclusive creator twice after emitting
# partial bytes. The helper must reap the producer and scrub only its exact
# newly-created inode while retaining the private root for inspection.
signal_work="$support_dir/build/release-oci-signal/work"
signal_state="$temporary_root/release-oci-signal-state"
mkdir -p "$signal_work/artifacts" "$signal_state"
secure_release_work_root "$signal_work"
signal_private_count="$(wc -l < "$retained_private_root_log" | tr -d '[:space:]')"
if MOCK_OCI_SIGNAL_MODE=true \
    MOCK_OCI_SIGNAL_STATE="$signal_state" \
    PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$signal_work" \
      "${decoder_args[@]}" \
      > "$temporary_root/release-oci-signal.log" 2>&1; then
  die "release OCI acquisition survived a producer terminal signal"
fi
[ -f "$signal_state/producer-pid" ] ||
  die "signalled OCI producer did not record its process identity"
signal_producer_pid="$(cat "$signal_state/producer-pid")"
if kill -0 "$signal_producer_pid" 2>/dev/null; then
  die "signalled OCI producer remained alive"
fi
signal_control_root="$(sed -n "$((signal_private_count + 2))p" \
  "$retained_private_root_log")"
case "$signal_control_root" in
  /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
  *) die "signal fixture did not record its retained private control root" ;;
esac
[ -f "$signal_control_root/sp11-oci-index.json" ] &&
  [ ! -L "$signal_control_root/sp11-oci-index.json" ] &&
  [ "$(wc -c < "$signal_control_root/sp11-oci-index.json")" -eq 0 ] ||
  die "signal failure did not scrub the exact private OCI inode"
grep -Fq 'Could not capture the raw pinned OCI index.' \
  "$temporary_root/release-oci-signal.log" ||
  die "signal failure was not reported as a failed OCI acquisition"
[ ! -e "$signal_work/docker-build-args.txt" ] &&
  [ ! -e "$signal_work/docker-build-inside.sh" ] &&
  [ ! -e "$signal_work/mock-docker-verified" ] ||
  die "signal failure emitted retained evidence or reached the build producer"
if grep -Fq 'Docker host control/artifact directory:' \
    "$temporary_root/release-oci-signal.log"; then
  die "signal failure printed the wrapper success summary"
fi

# A silent producer and a producer flooding only stderr exercise independent
# inactivity and byte bounds. Both must be stopped and reaped before the exact
# exclusively-created OCI evidence inode is scrubbed.
for oci_supervisor_mode in hang stderr-flood; do
  oci_supervisor_root="$temporary_root/release-oci-$oci_supervisor_mode"
  oci_supervisor_state="$oci_supervisor_root/state"
  oci_supervisor_work="$support_dir/build/release-oci-$oci_supervisor_mode/work"
  oci_supervisor_log="$oci_supervisor_root/wrapper.log"
  mkdir -p "$oci_supervisor_state" "$oci_supervisor_work/artifacts"
  secure_release_work_root "$oci_supervisor_work"
  oci_supervisor_private_count="$(wc -l < \
    "$retained_private_root_log" | tr -d '[:space:]')"
  oci_supervisor_volume_count="$(find "$mock_release_volume_root" \
    -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
  oci_supervisor_container_count="$(wc -l < \
    "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
  oci_supervisor_env=(
    SP11_RELEASE_SUPERVISOR_FIXTURE_TIMEOUT=true
    MOCK_OCI_SUPERVISOR_STATE="$oci_supervisor_state"
  )
  case "$oci_supervisor_mode" in
    hang) oci_supervisor_env+=(MOCK_OCI_HANG_MODE=true) ;;
    stderr-flood) oci_supervisor_env+=(MOCK_OCI_STDERR_FLOOD_MODE=true) ;;
  esac
  if /usr/bin/env "${oci_supervisor_env[@]}" \
      PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
        --work-dir "$oci_supervisor_work" \
        "${decoder_args[@]}" > "$oci_supervisor_log" 2>&1; then
    die "release OCI supervisor accepted a $oci_supervisor_mode producer"
  fi
  [ -f "$oci_supervisor_state/producer-pid" ] ||
    die "OCI $oci_supervisor_mode producer omitted its process identity"
  oci_supervisor_pid="$(cat "$oci_supervisor_state/producer-pid")"
  if kill -0 "$oci_supervisor_pid" 2>/dev/null; then
    die "OCI $oci_supervisor_mode producer remained alive"
  fi
  oci_supervisor_control_root="$(sed -n \
    "$((oci_supervisor_private_count + 2))p" "$retained_private_root_log")"
  [ -d "$oci_supervisor_control_root" ] &&
    [ ! -L "$oci_supervisor_control_root" ] &&
    [ -f "$oci_supervisor_control_root/sp11-oci-index.json" ] &&
    [ ! -L "$oci_supervisor_control_root/sp11-oci-index.json" ] &&
    [ "$(wc -c < "$oci_supervisor_control_root/sp11-oci-index.json")" -eq 0 ] ||
    die "OCI $oci_supervisor_mode failure did not scrub its exact output inode"
  [ "$(find "$mock_release_volume_root" -mindepth 1 -maxdepth 1 \
      -type d -print | wc -l | tr -d '[:space:]')" \
    -eq "$oci_supervisor_volume_count" ] ||
    die "OCI $oci_supervisor_mode failure reached release-volume creation"
  [ "$(wc -l < "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | \
      tr -d '[:space:]')" -eq "$oci_supervisor_container_count" ] ||
    die "OCI $oci_supervisor_mode failure reached container creation"
  grep -Fq 'Could not capture the raw pinned OCI index.' \
    "$oci_supervisor_log" ||
    die "OCI $oci_supervisor_mode failure was not explicit"
  if grep -Fq \
      'Imported verified retained kernel release evidence and final assets.' \
      "$oci_supervisor_log"; then
    die "OCI $oci_supervisor_mode failure printed terminal success"
  fi
done

# Volume create uses the same finite, dual-stream process-group ownership
# boundary. Cover inactivity, diagnostic overflow, and two pending terminal
# signals without deleting the intentionally retained private roots or
# creating a container under an unregistered volume authority.
for volume_supervisor_mode in hang stderr-flood signal; do
  volume_supervisor_root="$temporary_root/release-volume-$volume_supervisor_mode"
  volume_supervisor_state="$volume_supervisor_root/state"
  volume_supervisor_work="$support_dir/build/release-volume-$volume_supervisor_mode/work"
  volume_supervisor_log="$volume_supervisor_root/wrapper.log"
  mkdir -p "$volume_supervisor_state" "$volume_supervisor_work/artifacts"
  secure_release_work_root "$volume_supervisor_work"
  volume_supervisor_volume_count="$(find "$mock_release_volume_root" \
    -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
  volume_supervisor_container_count="$(wc -l < \
    "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
  volume_supervisor_env=(
    SP11_RELEASE_SUPERVISOR_FIXTURE_TIMEOUT=true
    MOCK_OCI_INDEX="$release_oci_index"
    MOCK_VOLUME_SUPERVISOR_STATE="$volume_supervisor_state"
  )
  case "$volume_supervisor_mode" in
    hang) volume_supervisor_env+=(MOCK_VOLUME_HANG_MODE=true) ;;
    stderr-flood) volume_supervisor_env+=(MOCK_VOLUME_STDERR_FLOOD_MODE=true) ;;
    signal) volume_supervisor_env+=(MOCK_VOLUME_SIGNAL_MODE=true) ;;
  esac
  if /usr/bin/env "${volume_supervisor_env[@]}" \
      PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
        --work-dir "$volume_supervisor_work" \
        "${decoder_args[@]}" > "$volume_supervisor_log" 2>&1; then
    die "release volume supervisor accepted a $volume_supervisor_mode producer"
  fi
  [ -f "$volume_supervisor_state/producer-pid" ] ||
    die "volume $volume_supervisor_mode producer omitted its process identity"
  volume_supervisor_pid="$(cat "$volume_supervisor_state/producer-pid")"
  if kill -0 "$volume_supervisor_pid" 2>/dev/null; then
    die "volume $volume_supervisor_mode producer remained alive"
  fi
  [ "$(find "$mock_release_volume_root" -mindepth 1 -maxdepth 1 \
      -type d -print | wc -l | tr -d '[:space:]')" \
    -eq "$volume_supervisor_volume_count" ] ||
    die "volume $volume_supervisor_mode failure created a release-state volume"
  [ "$(wc -l < "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | \
      tr -d '[:space:]')" -eq "$volume_supervisor_container_count" ] ||
    die "volume $volume_supervisor_mode failure reached container creation"
  [ ! -e "$volume_supervisor_work/sp11-kernel-retained-evidence.tar" ] ||
    die "volume $volume_supervisor_mode failure published retained evidence"
  grep -Fq 'Could not create and bind the private Docker release-state volume.' \
    "$volume_supervisor_log" ||
    die "volume $volume_supervisor_mode failure was not explicit"
  if grep -Fq \
      'Imported verified retained kernel release evidence and final assets.' \
      "$volume_supervisor_log"; then
    die "volume $volume_supervisor_mode failure printed terminal success"
  fi
done

# Linux preserves an ignored SIGCHLD disposition across exec. The outer Bash
# wrapper cannot safely restore it before Git or another child-owning tool, so
# it must refuse before any producer or private release state is created.
# Embedded Python owners separately exercise their own reset immediately before
# Popen and preserve nonzero producer status despite otherwise plausible stdout.
# A separate live process proves failure cleanup remains confined to the
# registered producer process group.
sigchld_victim_marker="$temporary_root/sigchld-unrelated-victim-signalled"
(
  trap ': > "$sigchld_victim_marker"; exit 143' HUP INT TERM
  while :; do
    /bin/sleep 1
  done
) &
sigchld_victim_pid=$!

if [ "$(uname -s)" = Linux ]; then
  sigchld_entry_root="$temporary_root/release-inherited-sigchld-entry"
  sigchld_entry_state="$sigchld_entry_root/state"
  sigchld_entry_work="$support_dir/build/release-inherited-sigchld-entry/work"
  sigchld_entry_log="$sigchld_entry_root/wrapper.log"
  mkdir -p "$sigchld_entry_state" "$sigchld_entry_work/artifacts"
  secure_release_work_root "$sigchld_entry_work"
  sigchld_entry_private_count="$(wc -l < \
    "$retained_private_root_log" | tr -d '[:space:]')"
  sigchld_entry_volume_count="$(find "$mock_release_volume_root" \
    -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
  sigchld_entry_container_count="$(wc -l < \
    "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
  sigchld_entry_status=0
  MOCK_OCI_NONZERO_MODE=true \
      MOCK_OCI_SUPERVISOR_STATE="$sigchld_entry_state" \
      MOCK_OCI_INDEX="$release_oci_index" \
      PATH="$mock_bin:/usr/bin:/bin" \
      run_with_ignored_sigchld "$wrapper" \
        --work-dir "$sigchld_entry_work" \
        "${decoder_args[@]}" > "$sigchld_entry_log" 2>&1 ||
    sigchld_entry_status=$?
  [ "$sigchld_entry_status" -eq 2 ] ||
    die "inherited-SIGCHLD entry refusal did not return status 2"
  [ ! -e "$sigchld_entry_state/producer-pid" ] ||
    die "inherited-SIGCHLD entry refusal reached the OCI producer"
  [ "$(wc -l < "$sigchld_entry_log" | tr -d '[:space:]')" -eq 1 ] ||
    die "inherited-SIGCHLD entry refusal emitted an ambiguous diagnostic"
  grep -Fxq \
    'Wrapper requires default CHLD/HUP/INT/QUIT/TERM dispositions at startup.' \
    "$sigchld_entry_log" ||
    die "inherited-SIGCHLD entry refusal was not exact and explicit"
  [ "$(wc -l < "$retained_private_root_log" | tr -d '[:space:]')" \
    -eq "$sigchld_entry_private_count" ] ||
    die "inherited-SIGCHLD entry refusal created private release state"
  [ "$(find "$mock_release_volume_root" -mindepth 1 -maxdepth 1 \
      -type d -print | wc -l | tr -d '[:space:]')" \
    -eq "$sigchld_entry_volume_count" ] ||
    die "inherited-SIGCHLD entry refusal created a release-state volume"
  [ "$(wc -l < "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | \
      tr -d '[:space:]')" -eq "$sigchld_entry_container_count" ] ||
    die "inherited-SIGCHLD entry refusal reached container creation"
  [ -z "$(find "$sigchld_entry_work" -mindepth 1 -maxdepth 1 \
      ! -name artifacts -print -quit)" ] &&
    [ -z "$(find "$sigchld_entry_work/artifacts" -mindepth 1 \
      -maxdepth 1 -print -quit)" ] ||
    die "inherited-SIGCHLD entry refusal wrote release work outputs"
  if ! kill -0 "$sigchld_victim_pid" 2>/dev/null ||
     [ -e "$sigchld_victim_marker" ]; then
    die "inherited-SIGCHLD entry refusal signalled an unrelated process"
  fi
  if grep -Fq \
      'Imported verified retained kernel release evidence and final assets.' \
      "$sigchld_entry_log"; then
    die "inherited-SIGCHLD entry refusal printed terminal success"
  fi
fi

sigchld_oci_root="$temporary_root/release-oci-inherited-sigchld-ignore"
sigchld_oci_state="$sigchld_oci_root/state"
sigchld_oci_work="$support_dir/build/release-oci-inherited-sigchld-ignore/work"
sigchld_oci_log="$sigchld_oci_root/wrapper.log"
mkdir -p "$sigchld_oci_state" "$sigchld_oci_work/artifacts"
secure_release_work_root "$sigchld_oci_work"
sigchld_oci_private_count="$(wc -l < \
  "$retained_private_root_log" | tr -d '[:space:]')"
sigchld_oci_volume_count="$(find "$mock_release_volume_root" \
  -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
sigchld_oci_container_count="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
if SP11_RELEASE_SUPERVISOR_FIXTURE_TIMEOUT=true \
    SP11_RELEASE_SUPERVISOR_FIXTURE_SIGCHLD_IGNORE=true \
    MOCK_OCI_NONZERO_MODE=true \
    MOCK_OCI_SUPERVISOR_STATE="$sigchld_oci_state" \
    MOCK_OCI_INDEX="$release_oci_index" \
    PATH="$mock_bin:/usr/bin:/bin" \
    "$wrapper" \
      --work-dir "$sigchld_oci_work" \
      "${decoder_args[@]}" > "$sigchld_oci_log" 2>&1; then
  die "release OCI supervisor accepted nonzero under inherited SIGCHLD ignore"
fi
[ -f "$sigchld_oci_state/producer-pid" ] ||
  die "inherited-SIGCHLD OCI producer omitted its process identity"
sigchld_oci_pid="$(cat "$sigchld_oci_state/producer-pid")"
[[ "$sigchld_oci_pid" =~ ^[0-9]+$ ]] ||
  die "inherited-SIGCHLD OCI producer recorded an invalid process identity"
if kill -0 "$sigchld_oci_pid" 2>/dev/null; then
  die "inherited-SIGCHLD OCI producer was not exactly reaped"
fi
sigchld_oci_control_root="$(sed -n \
  "$((sigchld_oci_private_count + 2))p" "$retained_private_root_log")"
[ -d "$sigchld_oci_control_root" ] &&
  [ ! -L "$sigchld_oci_control_root" ] &&
  [ -f "$sigchld_oci_control_root/sp11-oci-index.json" ] &&
  [ ! -L "$sigchld_oci_control_root/sp11-oci-index.json" ] &&
  [ "$(wc -c < "$sigchld_oci_control_root/sp11-oci-index.json")" -eq 0 ] ||
  die "inherited-SIGCHLD OCI failure did not scrub its exact output inode"
[ "$(find "$mock_release_volume_root" -mindepth 1 -maxdepth 1 \
    -type d -print | wc -l | tr -d '[:space:]')" \
  -eq "$sigchld_oci_volume_count" ] ||
  die "inherited-SIGCHLD OCI failure reached release-volume creation"
[ "$(wc -l < "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | \
    tr -d '[:space:]')" -eq "$sigchld_oci_container_count" ] ||
  die "inherited-SIGCHLD OCI failure reached container creation"
grep -Fq 'Could not capture the raw pinned OCI index.' "$sigchld_oci_log" ||
  die "inherited-SIGCHLD OCI nonzero status was not explicit"
if ! kill -0 "$sigchld_victim_pid" 2>/dev/null ||
   [ -e "$sigchld_victim_marker" ]; then
  die "inherited-SIGCHLD OCI cleanup signalled an unrelated process"
fi
if grep -Fq \
    'Imported verified retained kernel release evidence and final assets.' \
    "$sigchld_oci_log"; then
  die "inherited-SIGCHLD OCI failure printed terminal success"
fi

sigchld_volume_root="$temporary_root/release-volume-inherited-sigchld-ignore"
sigchld_volume_state="$sigchld_volume_root/state"
sigchld_volume_work="$support_dir/build/release-volume-inherited-sigchld-ignore/work"
sigchld_volume_log="$sigchld_volume_root/wrapper.log"
mkdir -p "$sigchld_volume_state" "$sigchld_volume_work/artifacts"
secure_release_work_root "$sigchld_volume_work"
sigchld_volume_count="$(find "$mock_release_volume_root" \
  -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
sigchld_volume_container_count="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
if SP11_RELEASE_SUPERVISOR_FIXTURE_TIMEOUT=true \
    SP11_RELEASE_SUPERVISOR_FIXTURE_SIGCHLD_IGNORE=true \
    MOCK_OCI_INDEX="$release_oci_index" \
    MOCK_VOLUME_NONZERO_MODE=true \
    MOCK_VOLUME_SUPERVISOR_STATE="$sigchld_volume_state" \
    PATH="$mock_bin:/usr/bin:/bin" \
    "$wrapper" \
      --work-dir "$sigchld_volume_work" \
      "${decoder_args[@]}" > "$sigchld_volume_log" 2>&1; then
  die "release volume supervisor accepted nonzero under inherited SIGCHLD ignore"
fi
[ -f "$sigchld_volume_state/producer-pid" ] ||
  die "inherited-SIGCHLD volume producer omitted its process identity"
sigchld_volume_pid="$(cat "$sigchld_volume_state/producer-pid")"
[[ "$sigchld_volume_pid" =~ ^[0-9]+$ ]] ||
  die "inherited-SIGCHLD volume producer recorded an invalid process identity"
if kill -0 "$sigchld_volume_pid" 2>/dev/null; then
  die "inherited-SIGCHLD volume producer was not exactly reaped"
fi
[ "$(find "$mock_release_volume_root" -mindepth 1 -maxdepth 1 \
    -type d -print | wc -l | tr -d '[:space:]')" \
  -eq "$sigchld_volume_count" ] ||
  die "inherited-SIGCHLD nonzero producer created a release-state volume"
[ "$(wc -l < "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | \
    tr -d '[:space:]')" -eq "$sigchld_volume_container_count" ] ||
  die "inherited-SIGCHLD volume failure reached container creation"
[ ! -e "$sigchld_volume_work/sp11-kernel-retained-evidence.tar" ] ||
  die "inherited-SIGCHLD volume failure published retained evidence"
grep -Fq 'Could not create and bind the private Docker release-state volume.' \
  "$sigchld_volume_log" ||
  die "inherited-SIGCHLD volume nonzero status was not explicit"
if ! kill -0 "$sigchld_victim_pid" 2>/dev/null ||
   [ -e "$sigchld_victim_marker" ]; then
  die "inherited-SIGCHLD volume cleanup signalled an unrelated process"
fi
if grep -Fq \
    'Imported verified retained kernel release evidence and final assets.' \
    "$sigchld_volume_log"; then
  die "inherited-SIGCHLD volume failure printed terminal success"
fi

kill -TERM "$sigchld_victim_pid"
wait "$sigchld_victim_pid" 2>/dev/null || true
sigchld_victim_pid=""

# In-place mutation and restoration after the launcher has read its bounded
# bytes changes the held inode metadata. The launcher must reject before
# compiling/executing those bytes, even though the pathname bytes were restored.
script_mutation_root="$temporary_root/release-script-mutate-restore"
script_mutation_work="$support_dir/build/release-script-mutate-restore/work"
mkdir -p "$script_mutation_root" "$script_mutation_work/artifacts"
secure_release_work_root "$script_mutation_work"
script_mutation_private_count="$(wc -l < \
  "$retained_private_root_log" | tr -d '[:space:]')"
script_mutation_volume_count="$(find "$mock_release_volume_root" \
  -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
script_mutation_container_count="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
if SP11_RELEASE_SCRIPT_BINDING_FIXTURE=true \
    SP11_RELEASE_SCRIPT_BINDING_ACTION=mutate-restore \
    SP11_RELEASE_SCRIPT_BINDING_TARGET=scripts/validate-sp11-oci-index.py \
    MOCK_OCI_INDEX="$release_oci_index" \
    PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$script_mutation_work" \
      "${decoder_args[@]}" > "$script_mutation_root/wrapper.log" 2>&1; then
  die "release executed an in-place-mutated committed validator"
fi
script_mutation_support_root="$(sed -n \
  "$((script_mutation_private_count + 1))p" "$retained_private_root_log")"
[ -d "$script_mutation_support_root/support" ] &&
  [ ! -L "$script_mutation_support_root/support" ] ||
  die "validator mutation failure did not retain its private support root"
cmp "$support_dir/scripts/validate-sp11-oci-index.py" \
  "$script_mutation_support_root/support/scripts/validate-sp11-oci-index.py" ||
  die "validator mutation fixture did not restore the exact committed bytes"
[ "$(find "$mock_release_volume_root" -mindepth 1 -maxdepth 1 \
    -type d -print | wc -l | tr -d '[:space:]')" \
  -eq "$script_mutation_volume_count" ] ||
  die "mutated validator reached release-volume creation"
[ "$(wc -l < "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | \
    tr -d '[:space:]')" -eq "$script_mutation_container_count" ] ||
  die "mutated validator reached container creation"
grep -Fq 'committed release support program binding failed' \
  "$script_mutation_root/wrapper.log" ||
  die "mutated validator binding failure was not explicit"
grep -Fq 'Could not execute the exact committed OCI-index validator.' \
  "$script_mutation_root/wrapper.log" ||
  die "mutated validator caller failure was not explicit"

# Replace the helper name only after its committed blob/OID/SHA has been read,
# stable-fstat checked, and compiled from memory. The held A program must still
# own and remove the exact build container; the hostile B program must never
# run. Later conservative snapshot-metadata verification may reject the build.
script_swap_root="$temporary_root/release-script-swap-after-seal"
script_swap_work="$support_dir/build/release-script-swap-after-seal/work"
script_swap_hostile_marker="$script_swap_root/hostile-helper-executed"
script_swap_restore_marker="$script_swap_root/original-helper-restored"
script_swap_displaced="$script_swap_root/displaced-hostile-helper.py"
mkdir -p "$script_swap_root" "$script_swap_work/artifacts"
secure_release_work_root "$script_swap_work"
script_swap_private_count="$(wc -l < \
  "$retained_private_root_log" | tr -d '[:space:]')"
script_swap_container_count="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
if SP11_RELEASE_SCRIPT_BINDING_FIXTURE=true \
    SP11_RELEASE_SCRIPT_BINDING_ACTION=swap-after-seal \
    SP11_RELEASE_SCRIPT_BINDING_TARGET=scripts/sp11-kernel-release-state.py \
    SP11_RELEASE_SCRIPT_BINDING_BACKUP=.sp11-fixture-helper-backup \
    SP11_RELEASE_SCRIPT_BINDING_HOSTILE_MARKER="$script_swap_hostile_marker" \
    SP11_RELEASE_SCRIPT_BINDING_RESTORE_MARKER="$script_swap_restore_marker" \
    SP11_RELEASE_SCRIPT_BINDING_DISPLACED="$script_swap_displaced" \
    MOCK_OCI_INDEX="$release_oci_index" \
    PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$script_swap_work" \
      "${decoder_args[@]}" > "$script_swap_root/wrapper.log" 2>&1; then
  die "release accepted changed support metadata after the held helper ran"
fi
[ -f "$script_swap_restore_marker" ] && [ -f "$script_swap_displaced" ] ||
  die "held-helper substitution fixture did not restore its original mapping"
[ ! -e "$script_swap_hostile_marker" ] ||
  die "release executed the hostile substitute helper pathname"
script_swap_support_root="$(sed -n \
  "$((script_swap_private_count + 1))p" "$retained_private_root_log")"
[ -f "$script_swap_support_root/support/scripts/sp11-kernel-release-state.py" ] &&
  [ ! -L "$script_swap_support_root/support/scripts/sp11-kernel-release-state.py" ] ||
  die "held-helper substitution lost the retained original helper"
cmp "$support_dir/scripts/sp11-kernel-release-state.py" \
  "$script_swap_support_root/support/scripts/sp11-kernel-release-state.py" ||
  die "held-helper substitution did not preserve committed helper bytes"
script_swap_container_after="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
[ "$script_swap_container_after" -eq "$((script_swap_container_count + 1))" ] ||
  die "held helper did not register exactly one build container"
script_swap_container_id="$(sed -n \
  "$((script_swap_container_count + 1))p" \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order")"
for script_swap_audit in created started removed; do
  [ -f "$MOCK_CONTAINER_AUDIT_ROOT/$script_swap_audit/$script_swap_container_id" ] ||
    die "held helper omitted its $script_swap_audit exact-container audit"
done
[ ! -e "$MOCK_CONTAINER_STATE_ROOT/$script_swap_container_id" ] ||
  die "held helper left its exact registered container active"
[ ! -e "$script_swap_work/sp11-kernel-retained-evidence.tar" ] ||
  die "held-helper substitution failure published retained evidence"
if grep -Fq \
    'Imported verified retained kernel release evidence and final assets.' \
    "$script_swap_root/wrapper.log"; then
  die "held-helper substitution failure printed terminal success"
fi

# A hostile replacement of an already-existing work ancestor occurs before
# work-root capture. Release setup performs no pre-pin mkdir/touch/remove, so
# the replacement victim stays byte-for-byte and membership-identical.
ancestor_fixture="$temporary_root/release-work-ancestor"
ancestor_state="$ancestor_fixture/state"
ancestor_victim="$ancestor_fixture/victim"
ancestor_parent="$support_dir/build/release-work-ancestor"
ancestor_work="$ancestor_parent/work"
ancestor_marker="$ancestor_fixture/attack-completed"
mkdir -p "$ancestor_state" "$ancestor_victim" "$ancestor_work"
secure_release_work_root "$ancestor_work"
printf 'ancestor victim must remain unchanged\n' > "$ancestor_victim/sentinel"
ancestor_victim_state="$(node_full_metadata "$ancestor_victim")"
ancestor_sentinel_state="$(regular_fingerprint "$ancestor_victim/sentinel")"
if CAPTURE_ATTACK_MODE=work-ancestor-symlink \
    CAPTURE_ATTACK_MARKER="$ancestor_marker" \
    CAPTURE_ATTACK_STATE="$ancestor_state" \
    CAPTURE_ATTACK_VICTIM="$ancestor_victim" \
    CAPTURE_ATTACK_WORK_PARENT="$ancestor_parent" \
    PATH="$capture_attack_bin:$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$ancestor_work" \
      "${decoder_args[@]}" \
      --dry-run > "$ancestor_fixture/wrapper.log" 2>&1; then
  die "release accepted a replaced work-directory ancestor"
fi
[ -f "$ancestor_marker" ] ||
  die "work-ancestor replacement fixture did not run"
[ -L "$ancestor_parent" ] &&
  [ "$(readlink "$ancestor_parent")" = "$ancestor_victim" ] ||
  die "release work setup removed its replaced ancestor tripwire"
[ "$(node_full_metadata "$ancestor_victim")" = "$ancestor_victim_state" ] &&
  [ "$(regular_fingerprint "$ancestor_victim/sentinel")" = \
    "$ancestor_sentinel_state" ] &&
  [ "$(find "$ancestor_victim" -mindepth 1 -maxdepth 1 -print)" = \
    "$ancestor_victim/sentinel" ] ||
  die "release work setup mutated the ancestor-swap victim"
grep -Fq -- '--work-dir must not contain symlink components' \
  "$ancestor_fixture/wrapper.log" ||
  die "work-ancestor replacement rejection was not explicit"

support_baseline_aba="$temporary_root/support-baseline-aba"
baseline_aba_backup="$temporary_root/baseline-root-aba-backup"
baseline_aba_capture="$baseline_aba_backup/capture"
baseline_aba_docker_marker="$baseline_aba_backup/docker-invoked"
baseline_aba_log="$temporary_root/baseline-root-aba.log"
baseline_aba_victim="$baseline_aba_backup/unrelated-victim"
mkdir -p "$baseline_aba_backup" "$baseline_aba_capture"
git clone --quiet "$support_dir" "$support_baseline_aba"
baseline_aba_validator="$support_baseline_aba/scripts/validate-sp11-kernel-baseline.sh"
"$real_python3" -I - "$baseline_aba_validator" \
  "$baseline_aba_backup" "$real_stat" "$real_shasum" <<'PY_BASELINE_ABA_VALIDATOR'
from pathlib import Path
import shlex
import sys

path = Path(sys.argv[1])
backup = shlex.quote(sys.argv[2])
real_stat = shlex.quote(sys.argv[3])
real_shasum = shlex.quote(sys.argv[4])
data = path.read_bytes()
activation = b'if [ "${MOCK_BASELINE_ROOT_ABA:-false}" = "true" ]; then'
if data.count(activation) != 1:
    raise SystemExit("baseline A->B->A activation patch was not exact")
replacement = (
    f"aba_backup={backup}\n"
    f"aba_real_stat={real_stat}\n"
    f"aba_real_shasum={real_shasum}\n"
    "if true; then"
).encode("utf-8")
data = data.replace(activation, replacement)
replacements = (
    (b"${MOCK_BASELINE_ABA_BACKUP:-}", b"$aba_backup", 1),
    (b"$MOCK_BASELINE_ABA_BACKUP", b"$aba_backup", 9),
    (b"$FIXTURE_REAL_STAT", b"$aba_real_stat", 4),
    (b"$FIXTURE_REAL_SHASUM", b"$aba_real_shasum", 2),
)
for old, new, expected_count in replacements:
    if data.count(old) != expected_count:
        raise SystemExit("baseline A->B->A authority patch count drifted")
    data = data.replace(old, new)
for forbidden in (
    activation,
    b"MOCK_BASELINE_ROOT_ABA",
    b"MOCK_BASELINE_ABA_BACKUP",
    b"FIXTURE_REAL_STAT",
    b"FIXTURE_REAL_SHASUM",
):
    if forbidden in data:
        raise SystemExit("baseline A->B->A authority patch was incomplete")
path.write_bytes(data)
PY_BASELINE_ABA_VALIDATOR
git -C "$support_baseline_aba" diff --check
[ "$(git -C "$support_baseline_aba" diff --name-only)" = \
  scripts/validate-sp11-kernel-baseline.sh ] ||
  die "baseline A->B->A fixture changed more than its validator"
git -C "$support_baseline_aba" add scripts/validate-sp11-kernel-baseline.sh
git -C "$support_baseline_aba" -c user.name='SP11 path-safety fixture' \
  -c user.email='sp11-path-safety@example.invalid' \
  commit --quiet -m 'Exercise committed baseline control-root replacement'
[ -z "$(git -C "$support_baseline_aba" status --porcelain)" ] ||
  die "baseline A->B->A fixture clone is not clean"
baseline_aba_wrapper="$support_baseline_aba/scripts/build-sp11-qcom-x1e-kernel-docker.sh"
cmp "$repo_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
  "$baseline_aba_wrapper" ||
  die "baseline A->B->A fixture changed the wrapper authority"
baseline_aba_work="$support_baseline_aba/build/baseline-root-aba/work"
mkdir -p "$baseline_aba_work"
secure_release_work_root "$baseline_aba_work"
# Concurrent same-credential A->B->A mutation is outside the release-controller
# custody boundary.  After exact restoration, refresh may accept the held A or
# conservatively fail a contemporaneous authority check; neither history
# detection nor availability is promised, and no third outcome is valid.
printf 'baseline ABA unrelated victim must remain unchanged\n' \
  > "$baseline_aba_victim"
baseline_aba_victim_state="$(full_regular_state "$baseline_aba_victim")"
baseline_aba_volume_count="$(find "$mock_release_volume_root" \
  -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
baseline_aba_container_count="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
baseline_aba_status=0
MOCK_DOCKER_ACTIVITY_MARKER="$baseline_aba_docker_marker" \
    CAPTURE_ATTACK_MODE=none \
    CAPTURE_ATTACK_MARKER="$baseline_aba_capture/unused-marker" \
    CAPTURE_ATTACK_STATE="$baseline_aba_capture" \
    PATH="$capture_attack_bin:$mock_bin:/usr/bin:/bin" "$baseline_aba_wrapper" \
      --work-dir "$baseline_aba_work" \
      "${decoder_args[@]}" \
      --dry-run > "$baseline_aba_log" 2>&1 ||
  baseline_aba_status=$?
case "$baseline_aba_status" in
  0|1) ;;
  *)
    cat "$baseline_aba_log" >&2
    die "baseline A->B->A produced an unsupported outcome"
    ;;
esac
[ -f "$baseline_aba_backup/completed" ] || {
  cat "$baseline_aba_log" >&2
  die "baseline validator did not complete its control-root A->B->A fixture"
}
preserved_baseline_control="$(cat "$baseline_aba_capture/control-root-path")"
case "$preserved_baseline_control" in
  /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
  *) die "could not identify preserved baseline-root hostile fixture" ;;
esac
[ -d "$preserved_baseline_control" ] && [ ! -L "$preserved_baseline_control" ] ||
  die "preserved baseline-root hostile fixture is no longer a real directory"
baseline_aba_pre_stable="$(cat "$baseline_aba_backup/pre-root-stable")"
baseline_aba_post_stable="$(stable_directory_identity \
  "$preserved_baseline_control")"
[ "$baseline_aba_post_stable" = "$baseline_aba_pre_stable" ] ||
  die "baseline A->B->A did not restore the original root identity"
[ "$baseline_aba_post_stable" != \
    "$(cat "$baseline_aba_backup/substitute-root-stable")" ] ||
  die "baseline A->B->A retained the substitute root"
baseline_aba_pre_baseline_state="$(cat \
  "$baseline_aba_backup/pre-baseline-state")"
baseline_aba_pre_validator_state="$(cat \
  "$baseline_aba_backup/pre-validator-state")"
[ "$(full_regular_state \
      "$preserved_baseline_control/kernel-baseline.env")" = \
    "$baseline_aba_pre_baseline_state" ] ||
  die "baseline A->B->A changed the restored baseline member state"
[ "$(full_regular_state \
      "$preserved_baseline_control/validate-sp11-kernel-baseline.sh")" = \
    "$baseline_aba_pre_validator_state" ] ||
  die "baseline A->B->A changed the restored validator member state"
baseline_aba_substitute_sha="$(cat \
  "$baseline_aba_backup/substitute-baseline-sha256")"
baseline_aba_substitute_sha="${baseline_aba_substitute_sha%% *}"
[ "$baseline_aba_substitute_sha" != \
    "${baseline_aba_pre_baseline_state##*:}" ] ||
  die "baseline A->B->A substitute was not byte-distinct from held A"
[ ! -e "$baseline_aba_backup/control-root" ] &&
  [ ! -L "$baseline_aba_backup/control-root" ] ||
  die "baseline A->B->A retained its backup alias"
[ "$(full_regular_state "$baseline_aba_victim")" = \
    "$baseline_aba_victim_state" ] ||
  die "baseline A->B->A changed its unrelated victim"
[ ! -e "$baseline_aba_docker_marker" ] ||
  die "baseline A->B->A reached Docker"
[ "$(find "$mock_release_volume_root" -mindepth 1 -maxdepth 1 \
    -type d -print | wc -l | tr -d '[:space:]')" \
  -eq "$baseline_aba_volume_count" ] ||
  die "baseline A->B->A changed release-volume state"
[ "$(wc -l < "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | \
    tr -d '[:space:]')" -eq "$baseline_aba_container_count" ] ||
  die "baseline A->B->A reached container creation"
baseline_aba_control_members="$(find "$preserved_baseline_control" \
  -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)"
baseline_aba_work_members="$(find "$baseline_aba_work" \
  -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)"
if [ "$baseline_aba_status" -eq 0 ]; then
  baseline_aba_expected_control_members="$(printf '%s\n%s\n%s\n%s\n' \
    "$preserved_baseline_control/docker-build-args.txt" \
    "$preserved_baseline_control/docker-build-inside.sh" \
    "$preserved_baseline_control/kernel-baseline.env" \
    "$preserved_baseline_control/validate-sp11-kernel-baseline.sh" | \
    LC_ALL=C sort)"
  [ "$baseline_aba_control_members" = \
    "$baseline_aba_expected_control_members" ] ||
    die "successful baseline A->B->A changed final control membership"
  baseline_aba_expected_work_members="$(printf '%s\n%s\n%s\n' \
    "$baseline_aba_work/artifacts" \
    "$baseline_aba_work/docker-build-args.txt" \
    "$baseline_aba_work/docker-build-inside.sh" | LC_ALL=C sort)"
  [ "$baseline_aba_work_members" = "$baseline_aba_expected_work_members" ] ||
    die "successful baseline A->B->A changed dry-run work membership"
  [ -d "$baseline_aba_work/artifacts" ] &&
    [ ! -L "$baseline_aba_work/artifacts" ] &&
    [ -z "$(find "$baseline_aba_work/artifacts" -mindepth 1 \
      -maxdepth 1 -print -quit)" ] ||
    die "successful baseline A->B->A changed the empty artifact root"
  for baseline_aba_control in \
    docker-build-args.txt docker-build-inside.sh; do
    [ -f "$baseline_aba_work/$baseline_aba_control" ] &&
      [ ! -L "$baseline_aba_work/$baseline_aba_control" ] &&
      cmp "$baseline_aba_work/$baseline_aba_control" \
        "$release_dry_work/$baseline_aba_control" &&
      cmp "$baseline_aba_work/$baseline_aba_control" \
        "$preserved_baseline_control/$baseline_aba_control" ||
      die "successful baseline A->B->A changed $baseline_aba_control bytes"
  done
  grep -Fq 'Docker command:' "$baseline_aba_log" ||
    die "successful baseline A->B->A omitted normal dry-run output"
else
  baseline_aba_expected_control_members="$(printf '%s\n%s\n' \
    "$preserved_baseline_control/kernel-baseline.env" \
    "$preserved_baseline_control/validate-sp11-kernel-baseline.sh" | \
    LC_ALL=C sort)"
  [ "$baseline_aba_control_members" = \
    "$baseline_aba_expected_control_members" ] ||
    die "refused baseline A->B->A changed initial control membership"
  [ "$baseline_aba_work_members" = "$baseline_aba_work/artifacts" ] &&
    [ -d "$baseline_aba_work/artifacts" ] &&
    [ ! -L "$baseline_aba_work/artifacts" ] &&
    [ -z "$(find "$baseline_aba_work/artifacts" -mindepth 1 \
      -maxdepth 1 -print -quit)" ] ||
    die "refused baseline A->B->A published work output"
  [ "$(wc -l < "$baseline_aba_log" | tr -d '[:space:]')" -eq 1 ] &&
    grep -Fxq \
      'Held committed-baseline authority changed during validation.' \
      "$baseline_aba_log" ||
    die "refused baseline A->B->A omitted its exact generic diagnostic"
  if grep -Fq 'Traceback (most recent call last):' "$baseline_aba_log" ||
     grep -Fq 'MOCK_BASELINE_ROOT_ABA' "$baseline_aba_log" ||
     grep -Fq 'MOCK_BASELINE_ABA_BACKUP' "$baseline_aba_log" ||
     grep -Fq 'CAPTURE_ATTACK_' "$baseline_aba_log" ||
     grep -Fq "$temporary_root" "$baseline_aba_log" ||
     grep -Fq "$preserved_baseline_control" "$baseline_aba_log"; then
    die "refused baseline A->B->A exposed private state"
  fi
  if grep -Fq 'Docker command:' "$baseline_aba_log" ||
     grep -Fq \
       'Imported verified retained kernel release evidence and final assets.' \
       "$baseline_aba_log"; then
    die "refused baseline A->B->A printed terminal success"
  fi
fi
mv "$preserved_baseline_control" "$baseline_aba_backup/preserved-private"

for capture_attack_mode in replace-args symlink-entrypoint; do
  capture_attack_root="$temporary_root/capture-$capture_attack_mode"
  capture_attack_work="$support_dir/build/capture-$capture_attack_mode/work"
  capture_attack_marker="$capture_attack_root/attack-completed"
  capture_attack_start="$capture_attack_root/attack-start"
  capture_attack_victim="$capture_attack_root/victim"
  mkdir -p "$capture_attack_root/state" "$capture_attack_work"
  secure_release_work_root "$capture_attack_work"
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
  preserved_capture_control="$(cat \
    "$capture_attack_root/state/control-root-path")"
  case "$preserved_capture_control" in
    /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
    *) die "could not identify preserved first-capture fixture: $capture_attack_mode" ;;
  esac
  [ -d "$preserved_capture_control" ] && [ ! -L "$preserved_capture_control" ] ||
    die "preserved first-capture fixture is no longer a real directory"
  mv "$preserved_capture_control" "$capture_attack_root/preserved-private"
done

# Special targets planted at the exact exclusive-open boundary must be retained
# untouched.  The wrapper must neither block on a FIFO nor follow a symlink to
# one, and a failed private acquisition must not emit public retained evidence.
for exclusive_attack_mode in snapshot-symlink private-args-fifo; do
  exclusive_attack_root="$temporary_root/exclusive-$exclusive_attack_mode"
  exclusive_attack_state="$exclusive_attack_root/state"
  exclusive_attack_work="$support_dir/build/exclusive-$exclusive_attack_mode/work"
  exclusive_attack_marker="$exclusive_attack_root/attack-completed"
  exclusive_attack_victim="$exclusive_attack_root/victim"
  mkdir -p "$exclusive_attack_state" "$exclusive_attack_work"
  secure_release_work_root "$exclusive_attack_work"
  printf 'exclusive snapshot victim must remain unchanged\n' \
    > "$exclusive_attack_victim"
  exclusive_attack_victim_state="$(regular_fingerprint \
    "$exclusive_attack_victim")"
  if SP11_RELEASE_CREATOR_FIXTURE=true \
      CAPTURE_ATTACK_MODE="$exclusive_attack_mode" \
      CAPTURE_ATTACK_MARKER="$exclusive_attack_marker" \
      CAPTURE_ATTACK_STATE="$exclusive_attack_state" \
      CAPTURE_ATTACK_VICTIM="$exclusive_attack_victim" \
      PATH="$capture_attack_bin:$mock_bin:/usr/bin:/bin" "$wrapper" \
        --work-dir "$exclusive_attack_work" \
        "${decoder_args[@]}" \
        --dry-run > "$exclusive_attack_root/wrapper.log" 2>&1; then
    die "release preflight accepted an exclusive special target: $exclusive_attack_mode"
  fi
  exclusive_control_root="$(cat \
    "$exclusive_attack_state/control-root-path")"
  case "$exclusive_control_root" in
    /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*) ;;
    *) die "exclusive special-target fixture recorded an unsafe control root" ;;
  esac
  [ -d "$exclusive_control_root" ] && [ ! -L "$exclusive_control_root" ] ||
    die "failed exclusive acquisition did not retain its private root"
  case "$exclusive_attack_mode" in
    snapshot-symlink)
      [ -L "$exclusive_control_root/kernel-baseline.env" ] &&
        [ "$(readlink "$exclusive_control_root/kernel-baseline.env")" = \
          "$exclusive_attack_victim" ] ||
        die "snapshot acquisition removed its planted symlink"
      [ "$(regular_fingerprint "$exclusive_attack_victim")" = \
        "$exclusive_attack_victim_state" ] ||
        die "snapshot acquisition followed or changed its symlink victim"
      grep -Fq 'Could not materialize committed support input' \
        "$exclusive_attack_root/wrapper.log" ||
        die "snapshot special-target rejection was not explicit"
      ;;
    private-args-fifo)
      [ -p "$exclusive_control_root/docker-build-args.txt" ] ||
        die "private-args acquisition removed its FIFO tripwire"
      grep -Fq 'Could not exclusively create private release build arguments' \
        "$exclusive_attack_root/wrapper.log" ||
        die "private-args FIFO rejection was not explicit"
      ;;
  esac
  [ ! -e "$exclusive_attack_work/docker-build-args.txt" ] ||
    die "failed private exclusive acquisition emitted retained evidence"
  if grep -Fq 'Docker command:' "$exclusive_attack_root/wrapper.log"; then
    die "failed private exclusive acquisition printed a success command"
  fi
done

retained_fifo_root="$temporary_root/exclusive-retained-fifo-link"
retained_fifo_state="$retained_fifo_root/state"
retained_fifo_work="$support_dir/build/exclusive-retained-fifo-link/work"
retained_fifo_marker="$retained_fifo_root/attack-completed"
retained_fifo_victim="$retained_fifo_root/victim-fifo"
mkdir -p "$retained_fifo_state" "$retained_fifo_work"
secure_release_work_root "$retained_fifo_work"
mkfifo "$retained_fifo_victim"
retained_fifo_victim_state="$(node_full_metadata "$retained_fifo_victim")"
if SP11_RELEASE_CREATOR_FIXTURE=true \
    CAPTURE_ATTACK_MODE=retained-fifo-link \
    CAPTURE_ATTACK_MARKER="$retained_fifo_marker" \
    CAPTURE_ATTACK_STATE="$retained_fifo_state" \
    CAPTURE_ATTACK_VICTIM="$retained_fifo_victim" \
    CAPTURE_ATTACK_WORK_ROOT="$retained_fifo_work" \
    PATH="$capture_attack_bin:$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$retained_fifo_work" \
      "${decoder_args[@]}" \
      --dry-run > "$retained_fifo_root/wrapper.log" 2>&1; then
  die "release preflight accepted a retained-evidence symlink to a FIFO"
fi
[ -L "$retained_fifo_work/docker-build-args.txt" ] &&
  [ "$(readlink "$retained_fifo_work/docker-build-args.txt")" = \
    "$retained_fifo_victim" ] ||
  die "retained evidence acquisition removed its FIFO symlink tripwire"
[ "$(node_full_metadata "$retained_fifo_victim")" = \
  "$retained_fifo_victim_state" ] ||
  die "retained evidence acquisition opened or changed its FIFO victim"
grep -Fq 'Could not exclusively create retained Docker evidence' \
  "$retained_fifo_root/wrapper.log" ||
  die "retained FIFO evidence rejection was not explicit"
[ ! -e "$retained_fifo_work/mock-private-control-verified" ] ||
  die "retained FIFO evidence failure reached the Docker producer"
if grep -Fq 'Docker command:' "$retained_fifo_root/wrapper.log"; then
  die "retained FIFO evidence failure printed a success command"
fi

# The exclusive host controller boundary explicitly excludes concurrent
# same-credential root replacement while private support/control roots are
# created and acquired.  We therefore do not emulate an OS watcher for those
# creation races.  Preexisting special-node collisions are covered above;
# post-acquisition work/mount drift and exact held-root confinement remain
# covered below.

# Retained release evidence must be written relative to the already-pinned
# work-directory object.  Replacing the public work path while a private
# control file is hashed must not redirect an evidence copy into the victim.
work_root_attack_fixture="$temporary_root/capture-work-root-symlink"
work_root_attack_work="$support_dir/build/capture-work-root-symlink/work"
work_root_attack_victim="$work_root_attack_fixture/victim"
work_root_attack_marker="$work_root_attack_fixture/attack-completed"
mkdir -p "$work_root_attack_fixture/state" "$work_root_attack_victim"
mkdir -p "$work_root_attack_work"
secure_release_work_root "$work_root_attack_work"
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
grep -Eq 'Release work root changed from its (held|pinned) directory' \
  "$work_root_attack_fixture/wrapper.log" ||
  die "work-root substitution rejection was not explicit"
rm -f -- "$work_root_attack_work"
[ -d "$work_root_attack_fixture/state/original-work-root" ] &&
  [ ! -L "$work_root_attack_fixture/state/original-work-root" ] ||
  die "work-root fixture lost its pinned original directory"

mkdir -p "$support_dir/build/release-identity-tampered-input/work"
secure_release_work_root \
  "$support_dir/build/release-identity-tampered-input/work"
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
mkdir -p "$tampered_support/build/release-identity-tampered-baseline/work"
secure_release_work_root \
  "$tampered_support/build/release-identity-tampered-baseline/work"
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

# Release build containers are registered by their full immutable Docker ID
# before they can run. A terminal signal delivered while attached must stop
# the exact process group, remove that exact registered container, and leave
# the retained state volume quiescent after the wrapper reports failure.
supervisor_signal_work="$support_dir/build/supervisor-signal/work"
mkdir -p "$supervisor_signal_work/artifacts"
secure_release_work_root "$supervisor_signal_work"
supervisor_signal_before="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
if MOCK_OCI_INDEX="$release_oci_index" \
    MOCK_BUILD_CONTAINER_SIGNAL_MODE=true \
    PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$supervisor_signal_work" \
      "${decoder_args[@]}" \
      > "$temporary_root/supervisor-signal.log" 2>&1; then
  die "release build-container supervisor survived a terminal signal"
fi
supervisor_signal_after="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
[ "$supervisor_signal_after" -eq "$((supervisor_signal_before + 1))" ] ||
  die "signalled release build did not register exactly one container"
supervisor_signal_id="$(sed -n "$((supervisor_signal_before + 1))p" \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order")"
[[ "$supervisor_signal_id" =~ ^[0-9a-f]{64}$ ]] ||
  die "signalled release build did not record a full container ID"
for audit_state in created started removed terminated; do
  [ -f "$MOCK_CONTAINER_AUDIT_ROOT/$audit_state/$supervisor_signal_id" ] ||
    die "signalled release build omitted its $audit_state container audit"
done
[ ! -e "$MOCK_CONTAINER_STATE_ROOT/$supervisor_signal_id" ] ||
  die "signalled release build left its registered container active"
grep -Fxq "$supervisor_signal_id" \
  "$MOCK_CONTAINER_AUDIT_ROOT/removal-targets" ||
  die "signalled release build did not remove its exact registered ID"
supervisor_signal_volume="$(find "$mock_release_volume_root" \
  -mindepth 2 -maxdepth 2 -type f \
  -name supervisor-mutation-counter -print)"
[ -n "$supervisor_signal_volume" ] &&
  [ "$(printf '%s\n' "$supervisor_signal_volume" | wc -l | tr -d '[:space:]')" -eq 1 ] ||
  die "signalled release build did not retain one bounded state volume"
supervisor_signal_volume="$(dirname "$supervisor_signal_volume")"
supervisor_signal_counter_state="$(regular_fingerprint \
  "$supervisor_signal_volume/supervisor-mutation-counter")"
/bin/sleep 1
[ "$(regular_fingerprint \
  "$supervisor_signal_volume/supervisor-mutation-counter")" = \
  "$supervisor_signal_counter_state" ] ||
  die "signalled release volume continued mutating after exact-ID cleanup"
grep -Fq 'Docker kernel build failed' "$temporary_root/supervisor-signal.log" ||
  die "signalled release build failure was not explicit"
if grep -Fq 'Imported verified retained kernel release evidence' \
    "$temporary_root/supervisor-signal.log"; then
  die "signalled release build printed terminal import success"
fi

# A Docker CLI failure after the build ID is registered and the mock container
# has exited follows the same exact-ID cleanup path. This exercises a failure
# outside the attached producer while proving that the retained volume stops
# changing before control returns to Bash.
supervisor_cli_work="$support_dir/build/supervisor-cli-failure/work"
mkdir -p "$supervisor_cli_work/artifacts"
secure_release_work_root "$supervisor_cli_work"
supervisor_cli_before="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
supervisor_cli_volumes_before="$(find "$mock_release_volume_root" \
  -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort)"
if MOCK_OCI_INDEX="$release_oci_index" \
    MOCK_BUILD_CONTAINER_INSPECT_FAILURE=true \
    PATH="$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$supervisor_cli_work" \
      "${decoder_args[@]}" \
      > "$temporary_root/supervisor-cli-failure.log" 2>&1; then
  die "release build-container supervisor survived a Docker CLI failure"
fi
supervisor_cli_after="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
[ "$supervisor_cli_after" -eq "$((supervisor_cli_before + 1))" ] ||
  die "CLI-failed release build did not register exactly one container"
supervisor_cli_id="$(sed -n "$((supervisor_cli_before + 1))p" \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order")"
[[ "$supervisor_cli_id" =~ ^[0-9a-f]{64}$ ]] ||
  die "CLI-failed release build did not record a full container ID"
for audit_state in created started removed; do
  [ -f "$MOCK_CONTAINER_AUDIT_ROOT/$audit_state/$supervisor_cli_id" ] ||
    die "CLI-failed release build omitted its $audit_state container audit"
done
[ ! -e "$MOCK_CONTAINER_STATE_ROOT/$supervisor_cli_id" ] ||
  die "CLI-failed release build left its registered container active"
grep -Fxq "$supervisor_cli_id" \
  "$MOCK_CONTAINER_AUDIT_ROOT/removal-targets" ||
  die "CLI-failed release build did not remove its exact registered ID"
supervisor_cli_volume="$(comm -13 \
  <(printf '%s\n' "$supervisor_cli_volumes_before") \
  <(find "$mock_release_volume_root" \
    -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort))"
[ -n "$supervisor_cli_volume" ] &&
  [ "$(printf '%s\n' "$supervisor_cli_volume" | wc -l | tr -d '[:space:]')" -eq 1 ] &&
  [ -f "$supervisor_cli_volume/mock-docker-verified" ] ||
  die "CLI-failed release build did not retain one completed state volume"
supervisor_cli_volume_state="$(regular_fingerprint \
  "$supervisor_cli_volume/mock-docker-verified")"
/bin/sleep 1
[ "$(regular_fingerprint "$supervisor_cli_volume/mock-docker-verified")" = \
  "$supervisor_cli_volume_state" ] ||
  die "CLI-failed release volume mutated after exact-ID cleanup"
grep -Fq 'Docker kernel build failed' \
  "$temporary_root/supervisor-cli-failure.log" ||
  die "Docker CLI failure was not reported as a failed release build"
if grep -Fq 'Imported verified retained kernel release evidence' \
    "$temporary_root/supervisor-cli-failure.log"; then
  die "CLI-failed release build printed terminal import success"
fi

# The mock exporter deliberately emits no tar. Reaching and removing its second
# full container ID proves that the real importer accepted the wrapper's root
# and three nine-field companion identities plus the exact hardened create
# argv. Its already-acquired evidence inode must be scrubbed without returning
# to Bash or publishing any flat artifact.
import_argv_work="$support_dir/build/import-argv/work"
late_docker_path="$temporary_root/late-docker-path"
late_docker_marker="$temporary_root/late-docker-path-invoked"
hostile_python_path="$temporary_root/hostile-python-path"
hostile_python_site="$temporary_root/hostile-python-site"
hostile_python_marker="$temporary_root/hostile-python-invoked"
hostile_python_site_marker="$temporary_root/hostile-python-site-imported"
mkdir -p "$import_argv_work/artifacts"
mkdir "$late_docker_path"
mkdir "$hostile_python_path" "$hostile_python_site"
printf '#!/bin/bash\n: > %q\nexit 98\n' "$hostile_python_marker" \
  > "$hostile_python_path/python3"
chmod +x "$hostile_python_path/python3"
printf '%s\n' \
  'import os' \
  'from pathlib import Path' \
  'Path(os.environ["SP11_HOSTILE_PYTHON_SITE_MARKER"]).write_text("loaded")' \
  > "$hostile_python_site/sitecustomize.py"
secure_release_work_root "$import_argv_work"
import_argv_before="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
if MOCK_OCI_INDEX="$release_oci_index" \
    MOCK_OCI_SMALL_STDERR=true \
    MOCK_VOLUME_SMALL_STDERR=true \
    SP11_RELEASE_EXCLUSIVE_CLOSE_SIGNAL_FIXTURE=true \
    SP11_RELEASE_EXCLUSIVE_CLOSE_SIGNAL_TARGET=sp11-oci-index.json \
    SP11_HOSTILE_PYTHON_SITE_MARKER="$hostile_python_site_marker" \
    PYTHONPATH="$hostile_python_site" \
    PYTHONUSERBASE="$hostile_python_site" \
    MOCK_INSTALL_LATE_DOCKER_SHIM="$late_docker_path/docker" \
    MOCK_LATE_DOCKER_SHIM_MARKER="$late_docker_marker" \
    PATH="$late_docker_path:$hostile_python_path:$mock_bin:/usr/bin:/bin" "$wrapper" \
      --work-dir "$import_argv_work" \
      "${decoder_args[@]}" \
      > "$temporary_root/import-argv.log" 2>&1; then
  die "terminal importer accepted an empty exporter stream"
fi
[ -x "$late_docker_path/docker" ] ||
  die "late PATH-spoof fixture did not install its hostile Docker shim"
[ ! -e "$late_docker_marker" ] ||
  die "release re-resolved Docker through hostile PATH after capture"
[ ! -e "$hostile_python_marker" ] &&
  [ ! -e "$hostile_python_site_marker" ] ||
  die "release executed ambient PATH/PYTHONPATH/user-site Python code"
[ -s "$import_argv_work/sp11-oci-index.json" ] ||
  die "post-fsync terminal signals left an uncommitted OCI-index output"
import_argv_after="$(wc -l < \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order" | tr -d '[:space:]')"
[ "$import_argv_after" -eq "$((import_argv_before + 2))" ] ||
  { cat "$temporary_root/import-argv.log" >&2;
    die "import argv fixture did not register build and exporter containers"; }
import_argv_build_id="$(sed -n "$((import_argv_before + 1))p" \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order")"
import_argv_exporter_id="$(sed -n "$((import_argv_before + 2))p" \
  "$MOCK_CONTAINER_AUDIT_ROOT/created-order")"
for import_container_id in "$import_argv_build_id" "$import_argv_exporter_id"; do
  [[ "$import_container_id" =~ ^[0-9a-f]{64}$ ]] ||
    die "import argv fixture recorded a noncanonical container ID"
  for audit_state in created started removed; do
    [ -f "$MOCK_CONTAINER_AUDIT_ROOT/$audit_state/$import_container_id" ] ||
      die "import argv fixture omitted its $audit_state container audit"
  done
  [ ! -e "$MOCK_CONTAINER_STATE_ROOT/$import_container_id" ] ||
    die "import argv fixture retained a registered container"
  grep -Fxq "$import_container_id" \
    "$MOCK_CONTAINER_AUDIT_ROOT/removal-targets" ||
    die "import argv fixture did not remove an exact registered ID"
done
[ -f "$import_argv_work/sp11-kernel-retained-evidence.tar" ] &&
  [ ! -L "$import_argv_work/sp11-kernel-retained-evidence.tar" ] &&
  [ "$(wc -c < "$import_argv_work/sp11-kernel-retained-evidence.tar")" -eq 0 ] ||
  die "failed terminal importer did not scrub its exact evidence inode"
[ -z "$(find "$import_argv_work/artifacts" \
  -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  die "failed terminal importer published a flat artifact"
grep -Fq 'error:' "$temporary_root/import-argv.log" ||
  die "empty exporter stream did not produce a terminal importer error"
if grep -Fq 'Could not import the sealed Docker release-state stream' \
    "$temporary_root/import-argv.log"; then
  die "terminal import returned to Bash failure handling"
fi
if grep -Fq 'Imported verified retained kernel release evidence' \
    "$temporary_root/import-argv.log"; then
  die "failed terminal importer printed committed success"
fi

immutable_oci_work="$support_dir/build/mutated-immutable-oci/work"
mkdir -p "$immutable_oci_work/artifacts"
secure_release_work_root "$immutable_oci_work"
immutable_volume_count="$(find "$mock_release_volume_root" \
  -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
if MOCK_OCI_INDEX="$release_oci_index" \
    MOCK_MUTATE_CONTROL=sp11-oci-index.json \
    MOCK_MUTATE_ROOT="$immutable_oci_work" \
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
      --module-signing-key "$signing_fixture_dir/key.pem" \
      --module-signing-certificate "$signing_fixture_dir/cert.pem" \
      --module-signing-pin-file "$signing_fixture_dir/pin" \
      > "$temporary_root/mutated-immutable-oci.log" 2>&1; then
  die "wrapper accepted a fake-Docker mutation of the immutable OCI index"
fi
grep -Fq 'Docker control input changed after its pre-run validation' \
  "$temporary_root/mutated-immutable-oci.log" ||
  die "fake-Docker immutable OCI mutation rejection was not explicit"
grep -Fq 'sp11-oci-index.json' "$temporary_root/mutated-immutable-oci.log" ||
  die "fake-Docker immutable OCI mutation rejection did not identify the control"
[ "$(find "$mock_release_volume_root" \
    -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')" \
  -eq "$((immutable_volume_count + 1))" ] ||
  die "failed release did not retain exactly one private state volume"
retained_state_volume="$(find "$mock_release_volume_root" \
  -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort | tail -n 1)"
[ -d "$retained_state_volume/artifacts" ] &&
  [ -f "$retained_state_volume/sp11-oci-index.json" ] ||
  die "failed release state volume did not retain bounded evidence"
[ ! -e "$immutable_oci_work/sp11-kernel-retained-evidence.tar" ] ||
  die "failed release published a host evidence tar"

# A coordinated A->B->A replacement must not make the writable evidence paths
# authoritative, and the private control directory's own rename history must be
# detected even when the original private file is restored byte-for-byte.
for aba_scope in work-args private-args private-root support-root; do
  aba_work="$support_dir/build/aba-$aba_scope/work"
  aba_backup="$temporary_root/aba-$aba_scope-backup"
  mkdir -p "$aba_backup" "$aba_work/artifacts"
  secure_release_work_root "$aba_work"
  if MOCK_OCI_INDEX="$release_oci_index" \
      MOCK_ABA_SWAP="$aba_scope" \
      MOCK_ABA_BACKUP_ROOT="$aba_backup" \
      MOCK_ABA_WORK_ROOT="$aba_work" \
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
    case "$aba_scope" in
      private-args|private-root)
        preserved_private_path="$(cat "$aba_backup/control-root-path")"
        ;;
      support-root)
        preserved_private_path="$(cat "$aba_backup/support-root-path")"
        ;;
    esac
    case "$preserved_private_path" in
      /tmp/sp11-kernel-baseline.*|/private/tmp/sp11-kernel-baseline.*|\
      /tmp/sp11-kernel-support.*|/private/tmp/sp11-kernel-support.*) ;;
      *) die "could not identify preserved hostile private fixture: $aba_scope" ;;
    esac
    [ -d "$preserved_private_path" ] && [ ! -L "$preserved_private_path" ] ||
      die "preserved hostile private fixture is no longer a real directory"
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
mkdir -p "$git_work/artifacts"
secure_release_work_root "$git_work"
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
      --module-signing-key "$signing_fixture_dir/key.pem" \
      --module-signing-certificate "$signing_fixture_dir/cert.pem" \
      --module-signing-pin-file "$signing_fixture_dir/pin" \
      --dry-run > "$temporary_root/git-environment.log" 2>&1; then
  cat "$temporary_root/git-environment.log" >&2
  die "wrapper did not sanitize replacement-ref and Git redirection variables"
fi

printf 'Kernel Docker wrapper path-safety fixtures passed.\n'
