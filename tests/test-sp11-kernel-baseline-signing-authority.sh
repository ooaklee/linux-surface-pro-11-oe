#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-baseline-signing.XXXXXX")"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  case "$temporary_root" in
    "${TMPDIR:-/tmp}"/sp11-baseline-signing.*)
      rm -rf -- "$temporary_root"
      ;;
    *)
      printf '%s\n' 'warning: refusing unexpected baseline fixture cleanup' >&2
      ;;
  esac
}
trap cleanup EXIT

for tool in awk bash chmod cp git ln mkdir mkfifo mktemp mv rm sed; do
  command -v "$tool" >/dev/null 2>&1 || die "missing fixture tool: $tool"
done
[ -x /usr/bin/git ] && [ -x /usr/bin/openssl ] && [ -x /usr/bin/python3 ] ||
  die "baseline signing fixture requires fixed Git, OpenSSL, and Python tools"

fixture_repo="$temporary_root/repo"
mkdir -p \
  "$fixture_repo/config/kernel-baselines" \
  "$fixture_repo/config/kernel-signing" \
  "$fixture_repo/config" \
  "$fixture_repo/scripts"
cp "$repo_dir/config/kernel-baselines/7.2-rc5-jg-0.env" \
  "$fixture_repo/config/kernel-baselines/"
cp "$repo_dir/config/kernel-signing/sp11-module-signing-cert.pem" \
  "$repo_dir/config/kernel-signing/sp11-module-signing-allowed-unsigned.txt" \
  "$fixture_repo/config/kernel-signing/"
cp "$repo_dir/config/source-ledger.tsv" "$fixture_repo/config/"
cp "$repo_dir/scripts/validate-sp11-kernel-baseline.sh" \
  "$fixture_repo/scripts/"
chmod 0755 "$fixture_repo/scripts/validate-sp11-kernel-baseline.sh"

patch_dirs="$(awk -F '"' \
  '$1 == "SP11_KERNEL_PATCH_DIRS=" { print $2 }' \
  "$fixture_repo/config/kernel-baselines/7.2-rc5-jg-0.env")"
[ -n "$patch_dirs" ] || die "could not read fixture patch directories"
for patch_dir in $patch_dirs; do
  mkdir -p "$fixture_repo/$patch_dir"
  printf '%s\n' fixture > "$fixture_repo/$patch_dir/.fixture"
done

/usr/bin/git -C "$fixture_repo" init --quiet --initial-branch=fixture
/usr/bin/git -C "$fixture_repo" config user.name 'SP11 baseline fixture'
/usr/bin/git -C "$fixture_repo" config user.email 'sp11-baseline@example.invalid'
/usr/bin/git -C "$fixture_repo" add .
/usr/bin/git -C "$fixture_repo" commit --quiet -m 'Create baseline signing fixture'

validator="$fixture_repo/scripts/validate-sp11-kernel-baseline.sh"
baseline="$fixture_repo/config/kernel-baselines/7.2-rc5-jg-0.env"
certificate="$fixture_repo/config/kernel-signing/sp11-module-signing-cert.pem"
certificate_sha=8ad9b402339b5ceff8e7fc9dfcc7dd368b2466fce0e90d97553059bcdc66e99b
certificate_fingerprint=8A:D9:B4:02:33:9B:5C:EF:F8:E7:FC:9D:FC:C7:DD:36:8B:24:66:FC:E0:E9:0D:97:55:30:59:BC:DC:66:E9:9B
certificate_serial=A48577E23557D28F5963279767D1C038

run_bounded() {
  local log="$1"
  shift
  /usr/bin/python3 -I -c '
import os
import signal
import subprocess
import sys

log, *command = sys.argv[1:]
descriptor = os.open(
    log,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
    0o600,
)
with os.fdopen(descriptor, "wb") as output:
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=output,
        stderr=subprocess.STDOUT,
        env=os.environ.copy(),
        start_new_session=True,
    )
    try:
        status = process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise SystemExit(124)
raise SystemExit(status if status >= 0 else 125)
' "$log" "$@"
}

# Ambient OpenSSL configuration and PATH-resolved digest/text tools must not
# participate in the certificate claim.
hostile_bin="$temporary_root/hostile-bin"
hostile_tool_marker="$temporary_root/hostile-tool-ran"
hostile_conf="$temporary_root/hostile-openssl.cnf"
hostile_modules="$temporary_root/hostile-modules"
mkdir "$hostile_bin" "$hostile_modules"
mkfifo "$hostile_conf" "$hostile_modules/default.so"
cat > "$hostile_bin/hostile-tool" <<'EOF_HOSTILE_TOOL'
#!/usr/bin/env bash
set -euo pipefail
: "${HOSTILE_TOOL_MARKER:?}"
printf '%s\n' invoked >> "$HOSTILE_TOOL_MARKER"
exit 93
EOF_HOSTILE_TOOL
chmod 0700 "$hostile_bin/hostile-tool"
for hostile_name in awk basename bash git grep od sha256sum shasum tr uname; do
  ln -s hostile-tool "$hostile_bin/$hostile_name"
done
hostile_function_marker="$temporary_root/hostile-function-ran"
hostile_bash_env="$temporary_root/hostile-bash-env"
hostile_bash_env_marker="$temporary_root/hostile-bash-env-ran"
cat > "$hostile_bash_env" <<'EOF_HOSTILE_BASH_ENV'
: "${HOSTILE_BASH_ENV_MARKER:?}"
printf '%s\n' sourced > "$HOSTILE_BASH_ENV_MARKER"
exit 95
EOF_HOSTILE_BASH_ENV
awk() {
  printf '%s\n' awk >> "$HOSTILE_FUNCTION_MARKER"
  return 94
}
git() {
  printf '%s\n' git >> "$HOSTILE_FUNCTION_MARKER"
  return 94
}
export -f awk git
if [ "$(uname -s)" = Linux ]; then
  linux_hashlib_probe_log="$temporary_root/linux-hashlib-openssl-startup.log"
  set +e
  OPENSSL_CONF="$hostile_conf" \
  OPENSSL_MODULES="$hostile_modules" \
  OPENSSL_ENGINES="$hostile_modules" \
  RANDFILE="$temporary_root/hostile-random" \
  run_bounded "$linux_hashlib_probe_log" \
    /usr/bin/python3 -I -c 'import hashlib'
  linux_hashlib_probe_status=$?
  set -e
  [ "$linux_hashlib_probe_status" -eq 124 ] || {
    cat "$linux_hashlib_probe_log" >&2
    die "Linux hashlib/OpenSSL startup fixture did not exercise the hostile configuration FIFO"
  }
fi
hostile_log="$temporary_root/hostile-environment.log"
set +e
PATH="$hostile_bin:$PATH" \
HOSTILE_TOOL_MARKER="$hostile_tool_marker" \
HOSTILE_FUNCTION_MARKER="$hostile_function_marker" \
HOSTILE_BASH_ENV_MARKER="$hostile_bash_env_marker" \
BASH_ENV="$hostile_bash_env" \
OPENSSL_CONF="$hostile_conf" \
OPENSSL_MODULES="$hostile_modules" \
OPENSSL_ENGINES="$hostile_modules" \
RANDFILE="$temporary_root/hostile-random" \
run_bounded "$hostile_log" \
  "$validator" --repo-dir "$fixture_repo" "$baseline"
hostile_status=$?
set -e
unset -f awk git
[ "$hostile_status" -eq 0 ] || {
  cat "$hostile_log" >&2
  die "baseline validator honored hostile OpenSSL or PATH authority"
}
[ ! -e "$hostile_tool_marker" ] && [ ! -L "$hostile_tool_marker" ] ||
  die "baseline certificate validation invoked a PATH-resolved claim tool"
[ ! -e "$hostile_function_marker" ] && [ ! -L "$hostile_function_marker" ] ||
  die "baseline validation invoked an inherited hostile function"
[ ! -e "$hostile_bash_env_marker" ] && [ ! -L "$hostile_bash_env_marker" ] ||
  die "baseline validation sourced an inherited BASH_ENV"
grep -Fq 'Validated kernel baseline' "$hostile_log" ||
  die "baseline hostile-environment fixture missed successful validation"

# Extract the exact isolated certificate-authority program and mechanically
# rebind only its trusted directory and expected owner for hostile mapping
# vectors that cannot safely mutate the real root-owned /usr/bin.
authority_raw="$temporary_root/certificate-authority-raw.py"
authority_program="$temporary_root/certificate-authority.py"
authority_dir="$temporary_root/authority-bin"
authority_uid="$(/usr/bin/python3 -I -c 'import os; print(os.getuid())')"
mkdir "$authority_dir"
chmod 0755 "$authority_dir"
sed -n \
  '/^# SP11_BASELINE_CERTIFICATE_AUTHORITY_BEGIN$/,/^# SP11_BASELINE_CERTIFICATE_AUTHORITY_END$/p' \
  "$validator" | sed '1d;$d' > "$authority_raw"
sed \
  -e "s#/usr/bin#$authority_dir#g" \
  -e "s/directory.st_uid != 0/directory.st_uid != $authority_uid/" \
  -e "s/target.st_uid != 0/target.st_uid != $authority_uid/" \
  "$authority_raw" > "$authority_program"

run_authority() {
  /usr/bin/python3 -I "$authority_program" \
    "$certificate" "$certificate_sha" "$certificate_fingerprint" \
    "$certificate_serial" >/dev/null 2>&1
}

install_authority_tool() {
  printf '%s\n' '#!/bin/sh' 'exec /usr/bin/openssl "$@"' \
    > "$authority_dir/openssl"
  chmod 0755 "$authority_dir/openssl"
}

install_authority_tool
run_authority || die "isolated baseline authority rejected a valid executable"
rm -f -- "$authority_dir/openssl"

ln -s /usr/bin/openssl "$authority_dir/openssl"
if run_authority; then
  die "baseline authority accepted a symlinked OpenSSL executable"
fi
rm -f -- "$authority_dir/openssl"
mkdir "$authority_dir/openssl"
if run_authority; then
  die "baseline authority accepted a directory in place of OpenSSL"
fi
rmdir "$authority_dir/openssl"
install_authority_tool
chmod 0775 "$authority_dir/openssl"
if run_authority; then
  die "baseline authority accepted a group-writable OpenSSL executable"
fi
rm -f -- "$authority_dir/openssl"

install_authority_tool
authority_remap="$temporary_root/certificate-authority-remap.py"
awk -v tool="$authority_dir/openssl" '
  { print }
  /SP11_BASELINE_OPENSSL_AUTHORITY_AFTER_CAPTURE/ {
    printf "    os.rename(%c%s%c, %c%s.held%c)\n", 34, tool, 34, 34, tool, 34
    printf "    with open(%c%s%c, %cwbc) as output:\n", 34, tool, 34, 34
    print "        output.write(b\"#!/bin/sh\\nexec /usr/bin/openssl \\\"$@\\\"\\n\")"
    printf "    os.chmod(%c%s%c, 0o755)\n", 34, tool, 34
  }
' "$authority_program" > "$authority_remap"
if /usr/bin/python3 -I "$authority_remap" \
    "$certificate" "$certificate_sha" "$certificate_fingerprint" \
    "$certificate_serial" >/dev/null 2>&1; then
  die "baseline authority accepted an executable mapping replacement"
fi
rm -f -- "$authority_dir/openssl" "$authority_dir/openssl.held"

printf '%s\n' 'Kernel baseline signing certificate authority tests passed.'
