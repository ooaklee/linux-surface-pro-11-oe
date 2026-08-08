#!/usr/bin/env bash
set -euo pipefail

repo_dir=""
baseline=""
emit_release_values="false"

die() {
  echo "error: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir)
      [ "$#" -ge 2 ] || die "--repo-dir requires a value"
      repo_dir="$2"
      shift 2
      ;;
    --emit-release-values)
      emit_release_values="true"
      shift
      ;;
    --*) die "unknown option: $1" ;;
    *)
      [ -z "$baseline" ] || die "only one kernel baseline path may be provided"
      baseline="$1"
      shift
      ;;
  esac
done

if [ -z "$repo_dir" ]; then
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
else
  [ -d "$repo_dir" ] && [ ! -L "$repo_dir" ] ||
    die "validator repository root is missing or unsafe: $repo_dir"
  repo_dir="$(cd "$repo_dir" && pwd -P)"
fi
baseline="${baseline:-$repo_dir/config/kernel-baselines/7.2-rc5-jg-0.env}"
ledger="$repo_dir/config/source-ledger.tsv"

[ -f "$baseline" ] && [ ! -L "$baseline" ] ||
  die "kernel baseline is missing, non-regular, or symlinked: $baseline"

required_variables="
SP11_KERNEL_BASELINE_ID
SP11_KERNEL_UPSTREAM_URL
SP11_KERNEL_UPSTREAM_REF
SP11_KERNEL_UPSTREAM_COMMIT
SP11_KERNEL_SOURCE_DATE_EPOCH
SP11_KERNEL_KBUILD_BUILD_USER
SP11_KERNEL_KBUILD_BUILD_HOST
SP11_KERNEL_KBUILD_BUILD_TIMESTAMP
SP11_KERNEL_FORK_URL
SP11_KERNEL_FORK_BASE_REF
SP11_KERNEL_FORK_BASE_COMMIT
SP11_KERNEL_FORK_INTEGRATION_REF
SP11_KERNEL_FORK_INTEGRATION_COMMIT
SP11_KERNEL_DOCKER_IMAGE
SP11_KERNEL_DOCKER_PLATFORM
SP11_KERNEL_DOCKER_PLATFORM_MANIFEST
SP11_APT_SNAPSHOT_ID
SP11_APT_SNAPSHOT_URI
SP11_APT_SNAPSHOT_SUITES
SP11_APT_SNAPSHOT_COMPONENTS
SP11_APT_SNAPSHOT_ARCHITECTURE
SP11_APT_ARCHIVE_KEYRING_SHA256
SP11_APT_ARCHIVE_SIGNING_FINGERPRINT
SP11_APT_INRELEASE_RESOLUTE_SHA256
SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256
SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256
SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256
SP11_APT_AUTHENTICATED_INDEX_COUNT
SP11_APT_DECOMPRESSED_EMPTY_INDEX_COUNT
SP11_APT_DECOMPRESSED_EMPTY_INDEX_SIZE
SP11_APT_DECOMPRESSED_EMPTY_INDEX_SHA256
SP11_APT_DECOMPRESSED_EMPTY_INDEX_1_PATH
SP11_APT_DECOMPRESSED_EMPTY_INDEX_2_PATH
SP11_APT_DECOMPRESSED_EMPTY_INDEX_3_PATH
SP11_APT_DECOMPRESSED_EMPTY_INDEX_4_PATH
SP11_APT_DECOMPRESSED_EMPTY_INDEX_5_PATH
SP11_APT_DECOMPRESSED_EMPTY_INDEX_6_PATH
SP11_APT_PYTHON_PACKAGE_SPEC
SP11_APT_BOOTSTRAP_PACKAGE_COUNT
SP11_APT_BOOTSTRAP_PACKAGE_1_SPEC
SP11_APT_BOOTSTRAP_PACKAGE_1_SHA256
SP11_APT_BOOTSTRAP_PACKAGE_2_SPEC
SP11_APT_BOOTSTRAP_PACKAGE_2_SHA256
SP11_APT_BOOTSTRAP_PACKAGE_3_SPEC
SP11_APT_BOOTSTRAP_PACKAGE_3_SHA256
SP11_APT_BOOTSTRAP_PACKAGE_4_SPEC
SP11_APT_BOOTSTRAP_PACKAGE_4_SHA256
SP11_KERNEL_BUILD_TARGET
SP11_KERNEL_PATCH_DIRS
SP11_KERNEL_RECOVERY_ABI
"
for variable in $required_variables; do
  unset "$variable"
done
required_words="${required_variables//$'\n'/ }"

byte_summary="$(
  LC_ALL=C od -An -v -tu1 "$baseline" | awk '
    {
      for (field = 1; field <= NF; field++) {
        byte = $field + 0
        count++
        last = byte
        if ((byte < 32 && byte != 10) || byte > 126) bad = 1
      }
    }
    END { printf "%d:%d:%d\n", count, last, bad }
  '
)"
IFS=: read -r baseline_size last_byte bad_byte remainder <<< "$byte_summary"
[[ "$baseline_size" =~ ^[0-9]+$ ]] && [ -z "$remainder" ] ||
  die "could not determine kernel baseline byte identity"
[ "$baseline_size" -gt 0 ] && [ "$baseline_size" -le 65536 ] ||
  die "kernel baseline must contain between 1 and 65536 bytes"
[ "$last_byte" = "10" ] || die "kernel baseline must be LF-terminated"
[ "$bad_byte" = "0" ] ||
  die "kernel baseline contains a control or non-ASCII byte"

# Parse the file as data in one awk process.  In particular, never source an
# unvalidated path: a baseline is allowed to contain only the reviewed,
# double-quoted assignment grammar and printable ASCII comments/blank lines.
if ! parsed_variables="$(
  LC_ALL=C awk -v required="$required_words" '
    function reject(message) {
      print "error: " message > "/dev/stderr"
      failed = 1
      exit 1
    }
    BEGIN {
      required_count = split(required, required_name)
      for (slot = 1; slot <= required_count; slot++) {
        if (required_name[slot] != "") {
          allowed[required_name[slot]] = 1
        }
      }
    }
    {
      if ($0 ~ /[^ -~]/) {
        reject("kernel baseline contains a non-printable or non-ASCII byte")
      }
      if ($0 == "" || $0 ~ /^#/) {
        next
      }
      equals = index($0, "=")
      name = substr($0, 1, equals - 1)
      encoded = substr($0, equals + 1)
      if (equals < 2 || name !~ /^SP11_[A-Z0-9_]+$/ ||
          substr(encoded, 1, 1) != "\"" ||
          substr(encoded, length(encoded), 1) != "\"") {
        reject("kernel baseline contains a noncanonical line")
      }
      value = substr(encoded, 2, length(encoded) - 2)
      if (value ~ /["\\]/) {
        reject("kernel baseline assignment contains quoting or escaping")
      }
      if (!(name in allowed)) {
        reject("unexpected kernel baseline variable: " name)
      }
      if (name in seen) {
        reject("duplicate kernel baseline variable: " name)
      }
      seen[name] = 1
      values[name] = value
      order[++assignment_count] = name
    }
    END {
      if (failed) {
        exit 1
      }
      for (slot = 1; slot <= required_count; slot++) {
        name = required_name[slot]
        if (name == "") {
          continue
        }
        if (!(name in seen) || values[name] == "") {
          reject("baseline variable is empty or missing: " name)
        }
      }
      for (slot = 1; slot <= assignment_count; slot++) {
        name = order[slot]
        printf "%s\t%s\n", name, values[name]
      }
    }
  ' "$baseline"
)"; then
  die "kernel baseline parsing failed"
fi

identity_variables=""
empty_path_variables=""
parsed_variable_count=0
while IFS=$'\t' read -r variable value remainder; do
  [ -n "$variable" ] && [ -z "$remainder" ] ||
    die "kernel baseline parser emitted malformed data"
  case $'\n'"$required_variables"$'\n' in
    *$'\n'"$variable"$'\n'*) ;;
    *) die "kernel baseline parser emitted an unexpected variable: $variable" ;;
  esac
  printf -v "$variable" '%s' "$value"
  parsed_variable_count=$((parsed_variable_count + 1))
  case "$variable" in
    SP11_KERNEL_SOURCE_DATE_EPOCH|SP11_KERNEL_KBUILD_BUILD_USER|\
    SP11_KERNEL_KBUILD_BUILD_HOST|SP11_KERNEL_KBUILD_BUILD_TIMESTAMP)
      identity_variables="${identity_variables}${identity_variables:+$'\n'}$variable"
      ;;
    SP11_APT_DECOMPRESSED_EMPTY_INDEX_[0-9]_PATH)
      empty_path_variables="${empty_path_variables}${empty_path_variables:+$'\n'}$variable"
      ;;
  esac
done <<< "$parsed_variables"

required_variable_count=0
for variable in $required_variables; do
  required_variable_count=$((required_variable_count + 1))
  [ -n "${!variable:-}" ] || die "baseline variable is empty or missing: $variable"
done
[ "$parsed_variable_count" -eq "$required_variable_count" ] ||
  die "kernel baseline field set is not exact"

expected_identity_variables="$(cat <<'EOF'
SP11_KERNEL_SOURCE_DATE_EPOCH
SP11_KERNEL_KBUILD_BUILD_USER
SP11_KERNEL_KBUILD_BUILD_HOST
SP11_KERNEL_KBUILD_BUILD_TIMESTAMP
EOF
)"
[ "$identity_variables" = "$expected_identity_variables" ] ||
  die "deterministic kernel build-identity baseline field set/order is not exact"

[[ "$SP11_KERNEL_SOURCE_DATE_EPOCH" =~ ^[1-9][0-9]{0,9}$ ]] ||
  die "SP11_KERNEL_SOURCE_DATE_EPOCH must be a canonical bounded Unix epoch"
[ "$SP11_KERNEL_SOURCE_DATE_EPOCH" -le 4102444799 ] ||
  die "SP11_KERNEL_SOURCE_DATE_EPOCH must be earlier than 2100-01-01 UTC"
[[ "$SP11_KERNEL_KBUILD_BUILD_USER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
  die "SP11_KERNEL_KBUILD_BUILD_USER must be a bounded portable identity"
[[ "$SP11_KERNEL_KBUILD_BUILD_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
  die "SP11_KERNEL_KBUILD_BUILD_HOST must be a bounded portable identity"
[[ "$SP11_KERNEL_KBUILD_BUILD_TIMESTAMP" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[[:space:]](Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[[:space:]]([[:space:]][1-9]|[12][0-9]|3[01])[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]UTC[[:space:]][0-9]{4}$ ]] ||
  die "SP11_KERNEL_KBUILD_BUILD_TIMESTAMP must use the canonical Kbuild UTC form"

[ "$SP11_KERNEL_SOURCE_DATE_EPOCH:$SP11_KERNEL_KBUILD_BUILD_TIMESTAMP" = \
  "1785567085:Sat Aug  1 06:51:25 UTC 2026" ] ||
  die "deterministic timestamp identity does not match the reviewed source commit epoch"
[ "$SP11_KERNEL_KBUILD_BUILD_USER" = "sp11-builder" ] ||
  die "SP11_KERNEL_KBUILD_BUILD_USER does not match the reviewed release identity"
[ "$SP11_KERNEL_KBUILD_BUILD_HOST" = "sp11-build" ] ||
  die "SP11_KERNEL_KBUILD_BUILD_HOST does not match the reviewed release identity"

[[ "$SP11_KERNEL_DOCKER_IMAGE" =~ ^[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]] ||
  die "SP11_KERNEL_DOCKER_IMAGE must include an immutable sha256 digest"
[ "$SP11_KERNEL_DOCKER_PLATFORM" = "linux/arm64/v8" ] ||
  die "SP11_KERNEL_DOCKER_PLATFORM must be linux/arm64/v8"
[[ "$SP11_KERNEL_DOCKER_PLATFORM_MANIFEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  die "SP11_KERNEL_DOCKER_PLATFORM_MANIFEST must be a sha256 digest"

[[ "$SP11_APT_SNAPSHOT_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
  die "SP11_APT_SNAPSHOT_ID must be a UTC snapshot timestamp"
[ "$SP11_APT_SNAPSHOT_ID" = "20260807T000000Z" ] ||
  die "SP11_APT_SNAPSHOT_ID must match the reviewed 2026-08-07 snapshot"
[ "$SP11_APT_SNAPSHOT_URI" = "https://snapshot.ubuntu.com/ubuntu/$SP11_APT_SNAPSHOT_ID/" ] ||
  die "SP11_APT_SNAPSHOT_URI must be the direct dated Ubuntu snapshot URI"
[ "$SP11_APT_SNAPSHOT_SUITES" = "resolute resolute-updates resolute-backports resolute-security" ] ||
  die "SP11_APT_SNAPSHOT_SUITES must contain the reviewed Resolute pockets"
[ "$SP11_APT_SNAPSHOT_COMPONENTS" = "main universe restricted multiverse" ] ||
  die "SP11_APT_SNAPSHOT_COMPONENTS must contain the reviewed Ubuntu components"
[ "$SP11_APT_SNAPSHOT_ARCHITECTURE" = "arm64" ] ||
  die "SP11_APT_SNAPSHOT_ARCHITECTURE must be arm64"
[[ "$SP11_APT_ARCHIVE_KEYRING_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  die "SP11_APT_ARCHIVE_KEYRING_SHA256 must be a lowercase SHA-256"
[[ "$SP11_APT_ARCHIVE_SIGNING_FINGERPRINT" =~ ^[0-9A-F]{40}$ ]] ||
  die "SP11_APT_ARCHIVE_SIGNING_FINGERPRINT must be a 40-hex fingerprint"
[ "$SP11_APT_ARCHIVE_KEYRING_SHA256" = "80a36b0a6de2f69f49d2df75ef473ccde121e9e190b9ea01d20a4f63778d5c31" ] ||
  die "SP11_APT_ARCHIVE_KEYRING_SHA256 does not match the reviewed keyring"
[ "$SP11_APT_ARCHIVE_SIGNING_FINGERPRINT" = "F6ECB3762474EDA9D21B7022871920D1991BC93C" ] ||
  die "SP11_APT_ARCHIVE_SIGNING_FINGERPRINT does not match the reviewed archive key"

for variable in \
  SP11_APT_INRELEASE_RESOLUTE_SHA256 \
  SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256 \
  SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256 \
  SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256; do
  value="${!variable}"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] ||
    die "$variable must be a lowercase SHA-256"
done

[ "$SP11_APT_INRELEASE_RESOLUTE_SHA256" = "45f95ce276cdba3e41870516a130e03c58b8b7a79e9546b0efe9e526d255740c" ] ||
  die "SP11_APT_INRELEASE_RESOLUTE_SHA256 does not match the reviewed snapshot"
[ "$SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256" = "9553631dec5b79a35dcdc5173e56f384ca93abcb37726a161c1090c4acc481f0" ] ||
  die "SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256 does not match the reviewed snapshot"
[ "$SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256" = "b5105f9b273e83dbaabe95cbbceb724264b375709b434af654023896dcc7f8ec" ] ||
  die "SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256 does not match the reviewed snapshot"
[ "$SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256" = "439791ef018139c01e9c2b434f06a3362f9cc6787badeef5d7d9e7716217a1b9" ] ||
  die "SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256 does not match the reviewed snapshot"

[ "$SP11_APT_AUTHENTICATED_INDEX_COUNT" = "32" ] ||
  die "SP11_APT_AUTHENTICATED_INDEX_COUNT must cover the reviewed 4x4x2 index set"
[ "$SP11_APT_DECOMPRESSED_EMPTY_INDEX_COUNT" = "6" ] ||
  die "SP11_APT_DECOMPRESSED_EMPTY_INDEX_COUNT must cover the reviewed six empty indexes"
[ "$SP11_APT_DECOMPRESSED_EMPTY_INDEX_SIZE" = "20" ] ||
  die "SP11_APT_DECOMPRESSED_EMPTY_INDEX_SIZE does not match the reviewed gzip identity"
[ "$SP11_APT_DECOMPRESSED_EMPTY_INDEX_SHA256" = \
  "9ceffb7310338057cfe71a4ae1e2c98d2c485d81cdef906532a801f457a38d64" ] ||
  die "SP11_APT_DECOMPRESSED_EMPTY_INDEX_SHA256 does not match the reviewed gzip identity"

reviewed_empty_index_paths=(
  "resolute-backports/main/binary-arm64/Packages.gz"
  "resolute-backports/main/source/Sources.gz"
  "resolute-backports/restricted/binary-arm64/Packages.gz"
  "resolute-backports/restricted/source/Sources.gz"
  "resolute-backports/multiverse/binary-arm64/Packages.gz"
  "resolute-backports/multiverse/source/Sources.gz"
)
for empty_index in "${!reviewed_empty_index_paths[@]}"; do
  variable="SP11_APT_DECOMPRESSED_EMPTY_INDEX_$((empty_index + 1))_PATH"
  [ "${!variable}" = "${reviewed_empty_index_paths[$empty_index]}" ] ||
    die "$variable does not match the reviewed empty-index sequence"
done
expected_empty_path_variables="$(
  for empty_index in 1 2 3 4 5 6; do
    printf 'SP11_APT_DECOMPRESSED_EMPTY_INDEX_%s_PATH\n' "$empty_index"
  done
)"
[ "$empty_path_variables" = "$expected_empty_path_variables" ] ||
  die "decompressed-empty index baseline path field set/order is not exact"
[ "$SP11_APT_PYTHON_PACKAGE_SPEC" = "python3=3.14.3-0ubuntu2" ] ||
  die "SP11_APT_PYTHON_PACKAGE_SPEC does not match the reviewed snapshot"

[ "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" = "4" ] ||
  die "SP11_APT_BOOTSTRAP_PACKAGE_COUNT must be 4"
bootstrap_index=1
while [ "$bootstrap_index" -le "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" ]; do
  spec_variable="SP11_APT_BOOTSTRAP_PACKAGE_${bootstrap_index}_SPEC"
  sha_variable="SP11_APT_BOOTSTRAP_PACKAGE_${bootstrap_index}_SHA256"
  spec="${!spec_variable:-}"
  sha="${!sha_variable:-}"
  [[ "$spec" =~ ^[a-z0-9][a-z0-9.+-]*=[0-9A-Za-z.+:~_-]+$ ]] ||
    die "$spec_variable must pin one exact package version"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] ||
    die "$sha_variable must be a lowercase SHA-256"
  bootstrap_index=$((bootstrap_index + 1))
done

[ "$SP11_APT_BOOTSTRAP_PACKAGE_1_SPEC:$SP11_APT_BOOTSTRAP_PACKAGE_1_SHA256" = \
  "ca-certificates=20260601~26.04.1:6077d27c6b6f8b23590cb01ff877ed8c804a67a5442cc32b5a33da10d2bd0e90" ] ||
  die "bootstrap package 1 does not match the reviewed snapshot"
[ "$SP11_APT_BOOTSTRAP_PACKAGE_2_SPEC:$SP11_APT_BOOTSTRAP_PACKAGE_2_SHA256" = \
  "openssl=3.5.5-1ubuntu3.3:d676e507c49f884f0c4582a32c4827d4cf94e0c4b2b1282c0e9c95693928856c" ] ||
  die "bootstrap package 2 does not match the reviewed snapshot"
[ "$SP11_APT_BOOTSTRAP_PACKAGE_3_SPEC:$SP11_APT_BOOTSTRAP_PACKAGE_3_SHA256" = \
  "libssl3t64=3.5.5-1ubuntu3.3:6f02fb682e7a873ac831da6066c856c982a51c08f2917cd90591b25663bd1feb" ] ||
  die "bootstrap package 3 does not match the reviewed snapshot"
[ "$SP11_APT_BOOTSTRAP_PACKAGE_4_SPEC:$SP11_APT_BOOTSTRAP_PACKAGE_4_SHA256" = \
  "openssl-provider-legacy=3.5.5-1ubuntu3.3:365b59eb0d11c4b037709776a02618ecdab9a07f03804b48e425cec5b2f4325b" ] ||
  die "bootstrap package 4 does not match the reviewed snapshot"

for variable in SP11_KERNEL_UPSTREAM_COMMIT SP11_KERNEL_FORK_BASE_COMMIT \
  SP11_KERNEL_FORK_INTEGRATION_COMMIT; do
  value="${!variable}"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] ||
    die "$variable must be a full lowercase 40-hex commit"
done

for variable in SP11_KERNEL_UPSTREAM_URL SP11_KERNEL_FORK_URL; do
  value="${!variable}"
  [[ "$value" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git$ ]] ||
    die "$variable must be a canonical HTTPS GitHub clone URL"
done

case "$SP11_KERNEL_RECOVERY_ABI" in
  *-qcom-x1e) ;;
  *) die "SP11_KERNEL_RECOVERY_ABI must end in -qcom-x1e" ;;
esac

for patch_dir in $SP11_KERNEL_PATCH_DIRS; do
  case "$patch_dir" in
    /*|*..*) die "unsafe patch directory in baseline: $patch_dir" ;;
  esac
  [ -d "$repo_dir/$patch_dir" ] || die "baseline patch directory not found: $patch_dir"
done

[ -f "$ledger" ] || die "source ledger not found: $ledger"
upstream_row="$(awk -F '\t' '$1 == "jg-kernel" {print $2 "\t" $3 "\t" $4}' "$ledger")"
expected_upstream="${SP11_KERNEL_UPSTREAM_URL}"$'\t'"${SP11_KERNEL_UPSTREAM_REF}"$'\t'"${SP11_KERNEL_UPSTREAM_COMMIT}"
[ "$upstream_row" = "$expected_upstream" ] ||
  die "jg-kernel ledger row does not match the kernel baseline"

fork_base_row="$(awk -F '\t' '$1 == "sp11-kernel-fork-base" {print $2 "\t" $3 "\t" $4}' "$ledger")"
expected_fork_base="${SP11_KERNEL_FORK_URL}"$'\t'"${SP11_KERNEL_FORK_BASE_REF}"$'\t'"${SP11_KERNEL_FORK_BASE_COMMIT}"
[ "$fork_base_row" = "$expected_fork_base" ] ||
  die "sp11-kernel-fork-base ledger row does not match the kernel baseline"

fork_integration_row="$(awk -F '\t' '$1 == "sp11-kernel-integration" {print $2 "\t" $3 "\t" $4}' "$ledger")"
expected_fork_integration="${SP11_KERNEL_FORK_URL}"$'\t'"${SP11_KERNEL_FORK_INTEGRATION_REF}"$'\t'"${SP11_KERNEL_FORK_INTEGRATION_COMMIT}"
[ "$fork_integration_row" = "$expected_fork_integration" ] ||
  die "sp11-kernel-integration ledger row does not match the kernel baseline"

if [ "$emit_release_values" = "true" ]; then
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
else
  printf 'Validated kernel baseline %s at %s\n' \
    "$SP11_KERNEL_BASELINE_ID" "$SP11_KERNEL_UPSTREAM_COMMIT"
fi
