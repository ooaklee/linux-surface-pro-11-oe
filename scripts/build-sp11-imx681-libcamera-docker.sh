#!/usr/bin/env bash
set -euo pipefail

umask 077

IMAGE="ubuntu:26.04"
JOBS=""
MIN_FREE_GB=20
PULL_IMAGE=true

usage() {
  cat <<'EOF'
Usage: scripts/build-sp11-imx681-libcamera-docker.sh [options]

Build the five coherently signed SP11 IMX681 libcamera runtime packages in a
native ARM64 Ubuntu 26.04 Docker container. Four HEAD-authenticated inputs are
staged privately and mounted read-only, build work stays in the disposable
container, and only eight verified artifacts are copied to an ignored private
directory. Nothing is installed on the host.

Options:
  --image IMAGE       Builder image, default ubuntu:26.04. The container must
                      identify itself as Ubuntu 26.04 on arm64.
  --jobs N            Parallel package-build jobs, default min(host CPUs, 12).
  --min-free-gb N     Required host output-filesystem space, default 20 GiB.
  --no-pull           Use an already present image instead of pulling it.
  -h, --help          Show this help.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"
}

require_value() {
  [ -n "${2:-}" ] || die "Missing value for $1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      require_value "$1" "${2:-}"
      IMAGE="$2"
      shift 2
      ;;
    --jobs)
      require_value "$1" "${2:-}"
      JOBS="$2"
      shift 2
      ;;
    --min-free-gb)
      require_value "$1" "${2:-}"
      MIN_FREE_GB="$2"
      shift 2
      ;;
    --no-pull)
      PULL_IMAGE=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

host_tools=(
  awk basename chmod cmp date df dirname docker dpkg-architecture dpkg-deb
  find git grep id install mktemp nproc openssl readlink sed sha256sum sort
  stat uname wc
)
for host_tool in "${host_tools[@]}"; do
  require_tool "$host_tool"
done

script_source="${BASH_SOURCE[0]}"
[ ! -L "$script_source" ] || die "The builder script must not be a symlink"
script_path="$(readlink -f -- "$script_source")"
[ -f "$script_path" ] && [ ! -L "$script_path" ] ||
  die "Could not resolve the builder script to a regular file"
script_dir="$(dirname "$script_path")"
repo_candidate="$(git -C "$script_dir" rev-parse --show-toplevel)"
repo_dir="$(readlink -f -- "$repo_candidate")"
[ -d "$repo_dir" ] && [ ! -L "$repo_dir" ] ||
  die "Support repository root is not a real directory"
[ "$(stat -c '%u' "$repo_dir")" -eq "$(id -u)" ] ||
  die "Support repository is not owned by the invoking user: $repo_dir"
expected_script="$repo_dir/scripts/build-sp11-imx681-libcamera-docker.sh"
[ "$script_path" = "$expected_script" ] ||
  die "Builder must run from its canonical repository path: $expected_script"

[ "$(uname -s)" = Linux ] || die "The host must be Linux for native ARM64 validation"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "The host is not ARM64: $(uname -m)" ;;
esac

if [ -z "$JOBS" ]; then
  JOBS="$(nproc)"
  if [ "$JOBS" -gt 12 ]; then
    JOBS=12
  fi
fi

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
[ "$JOBS" -le 64 ] || die "--jobs must not exceed 64"
[[ "$MIN_FREE_GB" =~ ^[1-9][0-9]*$ ]] || die "--min-free-gb must be a positive integer"

support_head="$(git -C "$repo_dir" rev-parse --verify 'HEAD^{commit}')"
support_head_time="$(git -C "$repo_dir" show -s --format=%cI "$support_head")"

target_assets=(
  scripts/build-sp11-imx681-libcamera-docker.sh
  userspace/camera/libcamera/0001-libipa-add-imx681-simple-ipa-support.patch
  userspace/camera/libcamera/BASE.txt
  userspace/camera/libcamera/imx681.yaml
)

for asset in "${target_assets[@]}"; do
  git -C "$repo_dir" ls-files --error-unmatch "$asset" >/dev/null 2>&1 ||
    die "Build input is not tracked at HEAD: $asset"
  [ -f "$repo_dir/$asset" ] && [ ! -L "$repo_dir/$asset" ] ||
    die "Build input is not a regular file: $asset"

  head_sha="$(git -C "$repo_dir" show "$support_head:$asset" | sha256sum | awk '{ print $1 }')"
  worktree_sha="$(sha256sum "$repo_dir/$asset" | awk '{ print $1 }')"
  [ "$head_sha" = "$worktree_sha" ] ||
    die "Build input differs from support HEAD: $asset"
done

git -C "$repo_dir" diff --quiet "$support_head" -- "${target_assets[@]}" ||
  die "One or more camera package inputs differ from support HEAD"

base_file="$repo_dir/userspace/camera/libcamera/BASE.txt"
patch_file="$repo_dir/userspace/camera/libcamera/0001-libipa-add-imx681-simple-ipa-support.patch"
yaml_file="$repo_dir/userspace/camera/libcamera/imx681.yaml"

read_base_field() {
  local label="$1"
  local value
  value="$(awk -F': ' -v label="$label" '$1 == label { print $2 }' "$base_file")"
  [ "$(grep -c "^${label}: " "$base_file")" -eq 1 ] ||
    die "BASE.txt must contain exactly one '$label' field"
  printf '%s\n' "$value"
}

base_version="$(read_base_field 'Ubuntu package validated on device')"
base_version="${base_version%% *}"
dsc_sha="$(read_base_field 'Ubuntu DSC SHA-256')"
orig_sha="$(read_base_field 'Ubuntu orig tarball SHA-256')"
debian_sha="$(read_base_field 'Ubuntu Debian tarball SHA-256')"

[ "$base_version" = 0.7.0-1ubuntu2 ] ||
  die "Unexpected BASE.txt Ubuntu version: $base_version"
[[ "$dsc_sha" =~ ^[0-9a-f]{64}$ ]] || die "Invalid DSC hash in BASE.txt"
[[ "$orig_sha" =~ ^[0-9a-f]{64}$ ]] || die "Invalid orig tarball hash in BASE.txt"
[[ "$debian_sha" =~ ^[0-9a-f]{64}$ ]] || die "Invalid Debian tarball hash in BASE.txt"

base_sha="$(sha256sum "$base_file" | awk '{ print $1 }')"
patch_sha="$(sha256sum "$patch_file" | awk '{ print $1 }')"
yaml_sha="$(sha256sum "$yaml_file" | awk '{ print $1 }')"
builder_sha="$(sha256sum "$script_path" | awk '{ print $1 }')"

docker_server_os="$(docker version --format '{{.Server.Os}}')"
docker_server_arch="$(docker version --format '{{.Server.Arch}}')"
docker_server_version="$(docker version --format '{{.Server.Version}}')"
[ "$docker_server_os" = linux ] || die "Docker server is not Linux: $docker_server_os"
case "$docker_server_arch" in
  arm64|aarch64) ;;
  *) die "Docker server is not native ARM64: $docker_server_arch" ;;
esac

if [ "$PULL_IMAGE" = true ]; then
  docker pull --platform linux/arm64 "$IMAGE"
else
  docker image inspect "$IMAGE" >/dev/null
fi

image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE")"
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  die "Builder image has an invalid immutable image ID: $image_id"
image_arch="$(docker image inspect --format '{{.Architecture}}' "$image_id")"
case "$image_arch" in
  arm64|aarch64) ;;
  *) die "Builder image is not ARM64: $image_arch" ;;
esac

image_repo_digests="$(docker image inspect --format '{{json .RepoDigests}}' "$image_id")"

build_timestamp="$(date -u +%Y%m%d%H%M%S%N)"
build_nonce="$(openssl rand -hex 16)"
[[ "$build_timestamp" =~ ^[0-9]{23}$ ]] ||
  die "Could not generate a nanosecond UTC build timestamp"
[[ "$build_nonce" =~ ^[0-9a-f]{32}$ ]] ||
  die "Could not generate a 128-bit cryptographic build nonce"
build_id="${build_timestamp}.${build_nonce}"
package_version="${base_version}+sp11.1.${build_id}"

build_parent="$repo_dir/build"
case "$build_parent" in
  "$repo_dir"/*) ;;
  *) die "Build parent escapes the support repository: $build_parent" ;;
esac
[ "$(dirname "$build_parent")" = "$repo_dir" ] ||
  die "Build parent is not directly beneath the support repository"

validate_owned_real_dir() {
  local directory="$1"
  local expected_real="$2"
  [ -d "$directory" ] && [ ! -L "$directory" ] ||
    die "Not a real directory: $directory"
  [ "$(readlink -f -- "$directory")" = "$expected_real" ] ||
    die "Directory resolves outside its expected path: $directory"
  [ "$(stat -c '%u' "$directory")" -eq "$(id -u)" ] ||
    die "Directory is not owned by the invoking user: $directory"
}

if [ -e "$build_parent" ] || [ -L "$build_parent" ]; then
  validate_owned_real_dir "$build_parent" "$build_parent"
else
  install -d -m 0700 -- "$build_parent"
  validate_owned_real_dir "$build_parent" "$build_parent"
fi

output_root="$build_parent/libcamera-docker"
git -C "$repo_dir" check-ignore -q "build/libcamera-docker/.ignore-check" ||
  die "build/libcamera-docker is not ignored by Git"
if [ -e "$output_root" ] || [ -L "$output_root" ]; then
  validate_owned_real_dir "$output_root" "$output_root"
  [ "$(stat -c '%a' "$output_root")" = 700 ] ||
    die "Existing output root must already be mode 0700: $output_root"
else
  install -d -m 0700 -- "$output_root"
  validate_owned_real_dir "$output_root" "$output_root"
  [ "$(stat -c '%a' "$output_root")" = 700 ] ||
    die "New output root is not mode 0700: $output_root"
fi

available_kb="$(df -Pk "$output_root" | awk 'NR == 2 { print $4 }')"
required_kb=$((MIN_FREE_GB * 1024 * 1024))
[ "$available_kb" -ge "$required_kb" ] ||
  die "Need ${MIN_FREE_GB} GiB free under $output_root"

output_dir=""
input_dir=""
verify_root=""
build_complete=false

validate_private_child_path() {
  local directory="$1"
  [ -n "$directory" ] || return 1
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  [ "$(dirname "$directory")" = "$output_root" ] || return 1
  [ "$(readlink -f -- "$directory")" = "$directory" ] || return 1
  [ "$(stat -c '%u' "$directory")" -eq "$(id -u)" ] || return 1
}

validate_private_child() {
  local directory="$1"
  validate_private_child_path "$directory" || return 1
  [ "$(stat -c '%a' "$directory")" = 700 ] || return 1
}

remove_private_child() {
  local directory="$1"
  validate_private_child_path "$directory" || {
    echo "Refusing to clean unexpected private directory: $directory" >&2
    return 1
  }
  find "$directory" -xdev -depth -delete
}

report_exit() {
  local status=$?
  local cleanup_status=0
  if [ -n "$verify_root" ] && ! remove_private_child "$verify_root"; then
    cleanup_status=1
  fi
  if [ -n "$input_dir" ] && ! remove_private_child "$input_dir"; then
    cleanup_status=1
  fi
  if [ "$build_complete" != true ] && [ -n "$output_dir" ]; then
    echo "Build did not complete; private diagnostic output remains at:" >&2
    echo "  $output_dir" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  return "$cleanup_status"
}
trap report_exit EXIT

output_dir="$(mktemp -d "$output_root/build.${build_id}.XXXXXXXX")"
validate_private_child "$output_dir" || die "Invalid private output directory"

input_dir="$(mktemp -d "$output_root/.inputs.${build_id}.XXXXXXXX")"
validate_private_child "$input_dir" || die "Invalid private input directory"

staged_names=(
  builder.sh
  imx681.patch
  BASE.txt
  imx681.yaml
)
for index in "${!target_assets[@]}"; do
  install -m 0400 -- "$repo_dir/${target_assets[$index]}" \
    "$input_dir/${staged_names[$index]}"
done
[ "$(find "$input_dir" -mindepth 1 -maxdepth 1 -type f -printf '.' | wc -c)" -eq 4 ] ||
  die "Private input staging did not contain exactly four files"
[ -z "$(find "$input_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ] ||
  die "Private input staging contains a non-regular file"

echo "Building libcamera $package_version in $IMAGE"
echo "Immutable builder image: $image_id"
echo "Support HEAD: $support_head"
echo "Private output: $output_dir"

docker run --rm \
  --interactive \
  --platform linux/arm64 \
  --hostname sp11-imx681-libcamera-builder \
  --network bridge \
  --pids-limit 4096 \
  --security-opt no-new-privileges:true \
  --mount "type=bind,src=$input_dir,dst=/inputs,readonly" \
  --mount "type=bind,src=$output_dir,dst=/out" \
  --env "BASE_VERSION=$base_version" \
  --env "DSC_SHA=$dsc_sha" \
  --env "ORIG_SHA=$orig_sha" \
  --env "DEBIAN_SHA=$debian_sha" \
  --env "BASE_SHA=$base_sha" \
  --env "PATCH_SHA=$patch_sha" \
  --env "YAML_SHA=$yaml_sha" \
  --env "BUILDER_SHA=$builder_sha" \
  --env "BUILD_ID=$build_id" \
  --env "BUILD_TIMESTAMP=$build_timestamp" \
  --env "BUILD_NONCE=$build_nonce" \
  --env "PACKAGE_VERSION=$package_version" \
  --env "BUILD_JOBS=$JOBS" \
  --env "SUPPORT_HEAD=$support_head" \
  --env "SUPPORT_HEAD_TIME=$support_head_time" \
  --env "BUILDER_IMAGE_REF=$IMAGE" \
  --env "BUILDER_IMAGE_ID=$image_id" \
  --env "BUILDER_IMAGE_REPO_DIGESTS=$image_repo_digests" \
  --env "DOCKER_SERVER_VERSION=$docker_server_version" \
  --env "DOCKER_SERVER_ARCH=$docker_server_arch" \
  --env "HOST_UID=$(id -u)" \
  --env "HOST_GID=$(id -g)" \
  "$image_id" bash -s <<'CONTAINER_SCRIPT'
set -euo pipefail

umask 077
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TZ=UTC

required_env=(
  BASE_VERSION DSC_SHA ORIG_SHA DEBIAN_SHA BASE_SHA PATCH_SHA YAML_SHA
  BUILDER_SHA BUILD_ID BUILD_TIMESTAMP BUILD_NONCE PACKAGE_VERSION BUILD_JOBS
  SUPPORT_HEAD SUPPORT_HEAD_TIME
  BUILDER_IMAGE_REF BUILDER_IMAGE_ID BUILDER_IMAGE_REPO_DIGESTS
  DOCKER_SERVER_VERSION DOCKER_SERVER_ARCH HOST_UID HOST_GID
)
for env_name in "${required_env[@]}"; do
  [ -n "${!env_name:-}" ] || {
    echo "Missing container environment: $env_name" >&2
    exit 1
  }
done

[[ "$BUILD_TIMESTAMP" =~ ^[0-9]{23}$ ]]
[[ "$BUILD_NONCE" =~ ^[0-9a-f]{32}$ ]]
[ "$BUILD_ID" = "${BUILD_TIMESTAMP}.${BUILD_NONCE}" ]
[ "$PACKAGE_VERSION" = "${BASE_VERSION}+sp11.1.${BUILD_ID}" ]

build_started_epoch="$(date +%s)"
build_started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# shellcheck disable=SC1091
. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.04 ] || {
  echo "Builder must be Ubuntu 26.04, got: $PRETTY_NAME" >&2
  exit 1
}
[ "$(dpkg --print-architecture)" = arm64 ] || {
  echo "Builder architecture is not arm64" >&2
  exit 1
}
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) echo "Container kernel architecture is not ARM64" >&2; exit 1 ;;
esac

[ -z "$(find /out -mindepth 1 -maxdepth 1 -print -quit)" ] || {
  echo "/out must be empty" >&2
  exit 1
}

apt-get update
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl devscripts dpkg-dev equivs fakeroot \
  git quilt ubuntu-keyring util-linux

mount_options="$(findmnt -T /inputs -n -o OPTIONS)"
case ",$mount_options," in
  *,ro,*) ;;
  *) echo "/inputs is not mounted read-only: $mount_options" >&2; exit 1 ;;
esac
[ "$(find /inputs -mindepth 1 -maxdepth 1 -type f -printf '.' | wc -c)" -eq 4 ]
[ -z "$(find /inputs -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]

mkdir -p /work/assets /work/download /work/source /work/deps /work/verify-root
chmod 0700 /work /work/assets /work/download /work/source /work/deps /work/verify-root

printf '%s  %s\n%s  %s\n%s  %s\n%s  %s\n' \
  "$BUILDER_SHA" /inputs/builder.sh \
  "$PATCH_SHA" /inputs/imx681.patch \
  "$BASE_SHA" /inputs/BASE.txt \
  "$YAML_SHA" /inputs/imx681.yaml | \
  sha256sum --strict -c -

install -m 0400 /inputs/builder.sh /work/assets/builder.sh
install -m 0400 /inputs/imx681.patch \
  /work/assets/0001-libipa-add-imx681-simple-ipa-support.patch
install -m 0400 /inputs/BASE.txt /work/assets/BASE.txt
install -m 0400 /inputs/imx681.yaml /work/assets/imx681.yaml

upstream_version="${BASE_VERSION%%-*}"
source_base_url="https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/libcamera/$BASE_VERSION"
dsc_name="libcamera_${BASE_VERSION}.dsc"
orig_name="libcamera_${upstream_version}.orig.tar.gz"
debian_name="libcamera_${BASE_VERSION}.debian.tar.xz"

cd /work/download
for source_file in "$dsc_name" "$orig_name" "$debian_name"; do
  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 5 --retry-all-errors --output "$source_file" \
    "$source_base_url/$source_file"
  [ -s "$source_file" ] && [ ! -L "$source_file" ]
done

printf '%s  %s\n%s  %s\n%s  %s\n' \
  "$DSC_SHA" "$dsc_name" \
  "$ORIG_SHA" "$orig_name" \
  "$DEBIAN_SHA" "$debian_name" | \
  sha256sum --strict -c -

dsc_orig_sha="$(awk -v file="$orig_name" '
  /^Checksums-Sha256:$/ { active = 1; next }
  active && $3 == file { print $1; exit }
  active && /^[^[:space:]]/ { exit }
' "$dsc_name")"
dsc_debian_sha="$(awk -v file="$debian_name" '
  /^Checksums-Sha256:$/ { active = 1; next }
  active && $3 == file { print $1; exit }
  active && /^[^[:space:]]/ { exit }
' "$dsc_name")"
[ "$dsc_orig_sha" = "$ORIG_SHA" ]
[ "$dsc_debian_sha" = "$DEBIAN_SHA" ]

cd /work/deps
mk-build-deps --build-dep --install --remove \
  --tool 'apt-get -y --no-install-recommends' \
  "/work/download/$dsc_name"

source_dir="/work/source/libcamera-$upstream_version"
dpkg-source -x "/work/download/$dsc_name" "$source_dir"
cd "$source_dir"

[ "$(dpkg-parsechangelog -SVersion)" = "$BASE_VERSION" ]
mapfile -t distro_series < <(sed -E '/^[[:space:]]*(#|$)/d' debian/patches/series)
mapfile -t applied_series < .pc/applied-patches
[ "${#distro_series[@]}" -gt 0 ]
[ "${#distro_series[@]}" -eq "${#applied_series[@]}" ]
for index in "${!distro_series[@]}"; do
  [ "${distro_series[$index]}" = "${applied_series[$index]}" ] || {
    echo "Ubuntu distro patch series was not applied exactly" >&2
    exit 1
  }
done

export QUILT_PATCHES=debian/patches
quilt import -P sp11-imx681-simple-ipa.patch \
  /work/assets/0001-libipa-add-imx681-simple-ipa-support.patch
quilt push
cmp /work/assets/imx681.yaml src/ipa/simple/data/imx681.yaml

export DEBFULLNAME='SP11 camera package builder'
export DEBEMAIL='sp11-camera-builder@localhost'
dch --force-distribution --newversion "$PACKAGE_VERSION" \
  --distribution resolute --urgency medium \
  'Add Surface Pro 11 IMX681 simple-IPA support.'
[ "$(dpkg-parsechangelog -SVersion)" = "$PACKAGE_VERSION" ]

export DEB_BUILD_OPTIONS="parallel=$BUILD_JOBS"
dpkg-buildpackage -B -uc -us

package_parent="$(dirname "$source_dir")"
changes_file="$package_parent/libcamera_${PACKAGE_VERSION}_arm64.changes"
buildinfo_file="$package_parent/libcamera_${PACKAGE_VERSION}_arm64.buildinfo"
for package_record in "$changes_file" "$buildinfo_file"; do
  [ -f "$package_record" ] && [ ! -L "$package_record" ] || {
    echo "Missing package record: $package_record" >&2
    exit 1
  }
done

changes_index=/work/changes-sha256.index
awk '
  /^Checksums-Sha256:$/ {
    header_count++
    active = 1
    next
  }
  active && /^$/ {
    invalid = 1
    next
  }
  active && /^[[:space:]]/ {
    if ($0 !~ /^[[:space:]]+[0-9a-f]{64}[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]*$/) {
      invalid = 1
      next
    }
    if (++seen[$3] != 1)
      invalid = 1
    if (index($3, "/") != 0 || $3 == "." || $3 == "..")
      invalid = 1
    print $1, $2, $3
    entry_count++
    next
  }
  active && /^[^[:space:]]/ { active = 0 }
  END {
    if (invalid || header_count != 1 || entry_count == 0)
      exit 1
  }
' "$changes_file" >"$changes_index"
changes_entry_count="$(wc -l <"$changes_index")"

(
  cd "$package_parent"
  awk '{ print $1 "  " $3 }' "$changes_index" | sha256sum --strict -c -
)

changes_sha256_entry() {
  local selected_name="$1"
  awk -v selected_name="$selected_name" '
    $3 == selected_name {
      count++
      value = $1 " " $2
    }
    END {
      if (count != 1)
        exit 1
      print value
    }
  ' "$changes_index"
}

selected_entry="$(changes_sha256_entry "$(basename "$buildinfo_file")")"
read -r selected_sha selected_size <<<"$selected_entry"
[ "$selected_sha" = "$(sha256sum "$buildinfo_file" | awk '{ print $1 }')" ]
[ "$selected_size" -eq "$(stat -c '%s' "$buildinfo_file")" ]

package_names=(
  libcamera0.7
  libcamera-ipa
  libcamera-tools
  libcamera-v4l2
  gstreamer1.0-libcamera
)
package_files=()

for package_name in "${package_names[@]}"; do
  expected_file="$package_parent/${package_name}_${PACKAGE_VERSION}_arm64.deb"
  [ -f "$expected_file" ] && [ ! -L "$expected_file" ] || {
    echo "Missing expected package: $expected_file" >&2
    exit 1
  }

  match_count="$(find "$package_parent" -maxdepth 1 -type f \
    -name "${package_name}_${PACKAGE_VERSION}_*.deb" -printf '.' | wc -c)"
  [ "$match_count" -eq 1 ] || {
    echo "Expected exactly one $package_name artifact, found $match_count" >&2
    exit 1
  }

  [ "$(dpkg-deb -f "$expected_file" Package)" = "$package_name" ]
  [ "$(dpkg-deb -f "$expected_file" Version)" = "$PACKAGE_VERSION" ]
  [ "$(dpkg-deb -f "$expected_file" Architecture)" = arm64 ]
  selected_entry="$(changes_sha256_entry "$(basename "$expected_file")")"
  read -r selected_sha selected_size <<<"$selected_entry"
  [ "$selected_sha" = "$(sha256sum "$expected_file" | awk '{ print $1 }')" ]
  [ "$selected_size" -eq "$(stat -c '%s' "$expected_file")" ]
  package_files+=("$expected_file")
done

delivered_changes_names=("$(basename "$buildinfo_file")")
for package_file in "${package_files[@]}"; do
  delivered_changes_names+=("$(basename "$package_file")")
done
delivered_changes_count="${#delivered_changes_names[@]}"
[ "$delivered_changes_count" -eq 6 ]
[ "$changes_entry_count" -ge "$delivered_changes_count" ]
undelivered_changes_count=$((changes_entry_count - delivered_changes_count))

core_deb="${package_files[0]}"
ipa_deb="${package_files[1]}"
tools_deb="${package_files[2]}"

dpkg-deb -x "$ipa_deb" /work/verify-root

multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
ipa_module="/work/verify-root/usr/lib/$multiarch/libcamera/ipa/ipa_soft_simple.so"
ipa_signature="$ipa_module.sign"
tuning_file="/work/verify-root/usr/share/libcamera/ipa/simple/imx681.yaml"

for required_file in "$ipa_module" "$ipa_signature" "$tuning_file"; do
  [ -f "$required_file" ] && [ ! -L "$required_file" ] || {
    echo "Missing required libcamera-ipa package content: $required_file" >&2
    exit 1
  }
done
cmp /work/assets/imx681.yaml "$tuning_file"

dpkg-deb -x "$core_deb" /work/verify-root
dpkg-deb -x "$tools_deb" /work/verify-root
ipa_verifier="/work/verify-root/usr/bin/ipa_verify"
[ -f "$ipa_verifier" ] && [ ! -L "$ipa_verifier" ] || {
  echo "Missing required libcamera-tools package content: $ipa_verifier" >&2
  exit 1
}

verify_output="$(LD_LIBRARY_PATH="/work/verify-root/usr/lib/$multiarch" \
  "$ipa_verifier" "$ipa_module")"
[ "$verify_output" = 'IPA module signature is valid' ] || {
  echo "$verify_output" >&2
  exit 1
}

build_finished_epoch="$(date +%s)"
build_finished_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
build_duration_seconds=$((build_finished_epoch - build_started_epoch))
dsc_sha="$(sha256sum "/work/download/$dsc_name" | awk '{ print $1 }')"
changes_sha="$(sha256sum "$changes_file" | awk '{ print $1 }')"
buildinfo_sha="$(sha256sum "$buildinfo_file" | awk '{ print $1 }')"

manifest=/work/sp11-imx681-libcamera-build-manifest.txt
{
  printf 'SP11 IMX681 libcamera package build manifest\n'
  printf 'Manifest format: 2\n'
  printf 'Build status: verified\n'
  printf 'Build ID: %s\n' "$BUILD_ID"
  printf 'Build timestamp ID: %s\n' "$BUILD_TIMESTAMP"
  printf 'Build random nonce: %s\n' "$BUILD_NONCE"
  printf 'Build started UTC: %s\n' "$build_started_utc"
  printf 'Build finished UTC: %s\n' "$build_finished_utc"
  printf 'Build duration seconds: %s\n' "$build_duration_seconds"
  printf 'Build jobs: %s\n' "$BUILD_JOBS"
  printf '\n'
  printf 'Support HEAD: %s\n' "$SUPPORT_HEAD"
  printf 'Support HEAD commit time: %s\n' "$SUPPORT_HEAD_TIME"
  printf 'Four build inputs matched support HEAD: yes\n'
  printf 'Builder script SHA-256: %s\n' "$BUILDER_SHA"
  printf 'BASE.txt SHA-256: %s\n' "$BASE_SHA"
  printf 'Local patch SHA-256: %s\n' "$PATCH_SHA"
  printf 'IMX681 YAML SHA-256: %s\n' "$YAML_SHA"
  printf '\n'
  printf 'Builder image reference: %s\n' "$BUILDER_IMAGE_REF"
  printf 'Builder image ID: %s\n' "$BUILDER_IMAGE_ID"
  printf 'Builder image repository digests: %s\n' "$BUILDER_IMAGE_REPO_DIGESTS"
  printf 'Builder OS: %s\n' "$PRETTY_NAME"
  printf 'Builder architecture: %s\n' "$(dpkg --print-architecture)"
  printf 'Builder kernel architecture: %s\n' "$(uname -m)"
  printf 'Docker server version: %s\n' "$DOCKER_SERVER_VERSION"
  printf 'Docker server architecture: %s\n' "$DOCKER_SERVER_ARCH"
  printf '\n'
  printf 'Source package: libcamera\n'
  printf 'Source version: %s\n' "$BASE_VERSION"
  printf 'Source URL: %s\n' "$source_base_url"
  printf 'Source DSC: %s\n' "$dsc_name"
  printf 'Source DSC SHA-256: %s\n' "$dsc_sha"
  printf 'Orig tarball: %s\n' "$orig_name"
  printf 'Orig tarball SHA-256: %s\n' "$ORIG_SHA"
  printf 'Debian tarball: %s\n' "$debian_name"
  printf 'Debian tarball SHA-256: %s\n' "$DEBIAN_SHA"
  printf 'Ubuntu distro patches applied: %s\n' "${#distro_series[@]}"
  for distro_patch in "${distro_series[@]}"; do
    printf '  %s\n' "$distro_patch"
  done
  printf 'Local patch applied after distro series: sp11-imx681-simple-ipa.patch\n'
  printf 'Patched YAML matched support asset: yes\n'
  printf '\n'
  printf 'Package version: %s\n' "$PACKAGE_VERSION"
  printf 'Changes file: %s\n' "$(basename "$changes_file")"
  printf 'Changes file SHA-256: %s\n' "$changes_sha"
  printf 'Buildinfo file: %s\n' "$(basename "$buildinfo_file")"
  printf 'Buildinfo file SHA-256: %s\n' "$buildinfo_sha"
  printf 'Original Changes file retained unmodified: yes\n'
  printf 'Container pre-export Changes-Sha256 entry count: %s\n' \
    "$changes_entry_count"
  printf 'Container pre-export every Changes-Sha256 entry hash verified: yes\n'
  printf 'Delivered Changes-Sha256 entry count: %s\n' \
    "$delivered_changes_count"
  printf 'Undelivered Changes-Sha256 entries intentionally omitted: %s\n' \
    "$undelivered_changes_count"
  while read -r entry_sha entry_size entry_name; do
    delivered=false
    for delivered_name in "${delivered_changes_names[@]}"; do
      if [ "$entry_name" = "$delivered_name" ]; then
        delivered=true
        break
      fi
    done
    if [ "$delivered" = false ]; then
      printf '  Omitted entry: %s %s %s\n' \
        "$entry_sha" "$entry_size" "$entry_name"
    fi
  done <"$changes_index"
  printf 'Same-build IPA verification: %s\n' "$verify_output"
  printf 'Selected runtime package count: %s\n' "${#package_files[@]}"
  for package_file in "${package_files[@]}"; do
    printf '\n'
    printf 'Package file: %s\n' "$(basename "$package_file")"
    printf '  Package: %s\n' "$(dpkg-deb -f "$package_file" Package)"
    printf '  Source: %s\n' "$(dpkg-deb -f "$package_file" Source)"
    printf '  Version: %s\n' "$(dpkg-deb -f "$package_file" Version)"
    printf '  Architecture: %s\n' "$(dpkg-deb -f "$package_file" Architecture)"
    printf '  Size bytes: %s\n' "$(stat -c '%s' "$package_file")"
    printf '  SHA-256: %s\n' "$(sha256sum "$package_file" | awk '{ print $1 }')"
  done
} >"$manifest"

export_files=("${package_files[@]}" "$changes_file" "$buildinfo_file" "$manifest")
for export_file in "${export_files[@]}"; do
  install -m 0644 "$export_file" "/out/$(basename "$export_file")"
done

[ "$(find /out -maxdepth 1 -type f -name '*.deb' -printf '.' | wc -c)" -eq 5 ]
[ "$(find /out -mindepth 1 -maxdepth 1 -type f -printf '.' | wc -c)" -eq 8 ]
[ -z "$(find /out -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]

for export_file in "${export_files[@]}"; do
  output_file="/out/$(basename "$export_file")"
  chown "$HOST_UID:$HOST_GID" "$output_file"
  chmod 0644 "$output_file"
done
chown "$HOST_UID:$HOST_GID" /out
chmod 0700 /out

echo "$verify_output"
echo "Verified eight-artifact set copied to /out"
CONTAINER_SCRIPT

remove_private_child "$input_dir" || die "Could not remove private input staging"
input_dir=""
validate_private_child "$output_dir" || die "Container changed the private output directory"

manifest="$output_dir/sp11-imx681-libcamera-build-manifest.txt"
changes_file="$output_dir/libcamera_${package_version}_arm64.changes"
buildinfo_file="$output_dir/libcamera_${package_version}_arm64.buildinfo"
host_package_names=(
  libcamera0.7
  libcamera-ipa
  libcamera-tools
  libcamera-v4l2
  gstreamer1.0-libcamera
)
output_debs=()
for package_name in "${host_package_names[@]}"; do
  output_debs+=("$output_dir/${package_name}_${package_version}_arm64.deb")
done
expected_artifacts=("${output_debs[@]}" "$changes_file" "$buildinfo_file" "$manifest")

[ "$(find "$output_dir" -mindepth 1 -maxdepth 1 -type f -printf '.' | wc -c)" -eq 8 ] ||
  die "Unexpected output files"
[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ] ||
  die "Unexpected non-file output"

for artifact in "${expected_artifacts[@]}"; do
  [ -f "$artifact" ] && [ ! -L "$artifact" ] ||
    die "Missing regular output artifact: $artifact"
  [ "$(stat -c '%u' "$artifact")" -eq "$(id -u)" ] ||
    die "Output artifact has the wrong owner: $artifact"
  [ "$(stat -c '%g' "$artifact")" -eq "$(id -g)" ] ||
    die "Output artifact has the wrong group: $artifact"
  [ "$(stat -c '%a' "$artifact")" = 644 ] ||
    die "Output artifact is not mode 0644: $artifact"
done

manifest_scalar() {
  local label="$1"
  awk -v label="$label" '
    index($0, label ": ") == 1 {
      count++
      value = substr($0, length(label) + 3)
    }
    END {
      if (count != 1)
        exit 1
      print value
    }
  ' "$manifest"
}

manifest_package_field() {
  local package_file="$1"
  local field="$2"
  awk -v package_file="$package_file" -v field="$field" '
    $0 == "Package file: " package_file {
      package_count++
      active = 1
      next
    }
    active && /^Package file: / { active = 0 }
    active && $0 ~ "^  " field ": " {
      field_count++
      value = substr($0, length(field) + 5)
    }
    END {
      if (package_count != 1 || field_count != 1)
        exit 1
      print value
    }
  ' "$manifest"
}

record_scalar() {
  local record_file="$1"
  local label="$2"
  awk -v label="$label" '
    index($0, label ": ") == 1 {
      count++
      value = substr($0, length(label) + 3)
    }
    END {
      if (count != 1)
        exit 1
      print value
    }
  ' "$record_file"
}

changes_sha_size() {
  local selected_name="$1"
  awk -v selected_name="$selected_name" '
    /^Checksums-Sha256:$/ { active = 1; next }
    active && /^[[:space:]]+[0-9a-f]{64}[[:space:]]+[0-9]+[[:space:]]+/ {
      if ($3 == selected_name) {
        count++
        value = $1 " " $2
      }
      next
    }
    active && /^[^[:space:]]/ { active = 0 }
    END {
      if (count != 1)
        exit 1
      print value
    }
  ' "$changes_file"
}

[ "$(manifest_scalar 'Build status')" = verified ]
[ "$(manifest_scalar 'Manifest format')" = 2 ]
[ "$(manifest_scalar 'Support HEAD')" = "$support_head" ]
[ "$(manifest_scalar 'Four build inputs matched support HEAD')" = yes ]
[ "$(manifest_scalar 'Builder script SHA-256')" = "$builder_sha" ]
[ "$(manifest_scalar 'BASE.txt SHA-256')" = "$base_sha" ]
[ "$(manifest_scalar 'Local patch SHA-256')" = "$patch_sha" ]
[ "$(manifest_scalar 'IMX681 YAML SHA-256')" = "$yaml_sha" ]
[ "$(manifest_scalar 'Builder image ID')" = "$image_id" ]
[ "$(manifest_scalar 'Source version')" = "$base_version" ]
[ "$(manifest_scalar 'Source DSC SHA-256')" = "$dsc_sha" ]
[ "$(manifest_scalar 'Orig tarball SHA-256')" = "$orig_sha" ]
[ "$(manifest_scalar 'Debian tarball SHA-256')" = "$debian_sha" ]
[ "$(manifest_scalar 'Package version')" = "$package_version" ]
[ "$(manifest_scalar 'Build random nonce')" = "$build_nonce" ]
[ "$(manifest_scalar 'Selected runtime package count')" = 5 ]
[ "$(manifest_scalar 'Same-build IPA verification')" = 'IPA module signature is valid' ]
[ "$(manifest_scalar 'Changes file')" = "$(basename "$changes_file")" ]
[ "$(manifest_scalar 'Buildinfo file')" = "$(basename "$buildinfo_file")" ]
[ "$(manifest_scalar 'Original Changes file retained unmodified')" = yes ]
[ "$(manifest_scalar 'Container pre-export every Changes-Sha256 entry hash verified')" = yes ]
[ "$(manifest_scalar 'Delivered Changes-Sha256 entry count')" = 6 ]
manifest_changes_count="$(manifest_scalar 'Container pre-export Changes-Sha256 entry count')"
manifest_omitted_count="$(manifest_scalar 'Undelivered Changes-Sha256 entries intentionally omitted')"
[[ "$manifest_changes_count" =~ ^[0-9]+$ ]]
[[ "$manifest_omitted_count" =~ ^[0-9]+$ ]]
[ "$manifest_changes_count" -ge 6 ]
[ "$manifest_omitted_count" -eq $((manifest_changes_count - 6)) ]
mapfile -t manifest_omitted_entries < <(
  awk '/^  Omitted entry: / { print $3, $4, $5 }' "$manifest"
)
[ "${#manifest_omitted_entries[@]}" -eq "$manifest_omitted_count" ]
for omitted_entry in "${manifest_omitted_entries[@]}"; do
  read -r omitted_sha omitted_size omitted_name <<<"$omitted_entry"
  [ "$(basename "$omitted_name")" = "$omitted_name" ]
  changes_entry="$(changes_sha_size "$omitted_name")"
  read -r expected_sha expected_size <<<"$changes_entry"
  [ "$omitted_sha" = "$expected_sha" ]
  [ "$omitted_size" -eq "$expected_size" ]
  for delivered_artifact in "${output_debs[@]}" "$buildinfo_file"; do
    [ "$omitted_name" != "$(basename "$delivered_artifact")" ]
  done
done

actual_changes_sha="$(sha256sum "$changes_file" | awk '{ print $1 }')"
[ "$(manifest_scalar 'Changes file SHA-256')" = "$actual_changes_sha" ]
actual_buildinfo_sha="$(sha256sum "$buildinfo_file" | awk '{ print $1 }')"
[ "$(manifest_scalar 'Buildinfo file SHA-256')" = "$actual_buildinfo_sha" ]
[ "$(record_scalar "$changes_file" Source)" = libcamera ]
[ "$(record_scalar "$changes_file" Version)" = "$package_version" ]
[ "$(record_scalar "$changes_file" Architecture)" = arm64 ]
[ "$(record_scalar "$buildinfo_file" Source)" = libcamera ]
[ "$(record_scalar "$buildinfo_file" Version)" = "$package_version" ]
[ "$(record_scalar "$buildinfo_file" Architecture)" = arm64 ]

changes_entry="$(changes_sha_size "$(basename "$buildinfo_file")")"
read -r expected_sha expected_size <<<"$changes_entry"
[ "$expected_sha" = "$actual_buildinfo_sha" ]
[ "$expected_size" -eq "$(stat -c '%s' "$buildinfo_file")" ]

for index in "${!output_debs[@]}"; do
  package_file="${output_debs[$index]}"
  package_name="${host_package_names[$index]}"
  package_basename="$(basename "$package_file")"
  actual_sha="$(sha256sum "$package_file" | awk '{ print $1 }')"
  actual_size="$(stat -c '%s' "$package_file")"

  [ "$(dpkg-deb -f "$package_file" Package)" = "$package_name" ]
  [ "$(dpkg-deb -f "$package_file" Source)" = libcamera ]
  [ "$(dpkg-deb -f "$package_file" Version)" = "$package_version" ]
  [ "$(dpkg-deb -f "$package_file" Architecture)" = arm64 ]

  [ "$(manifest_package_field "$package_basename" Package)" = "$package_name" ]
  [ "$(manifest_package_field "$package_basename" Source)" = libcamera ]
  [ "$(manifest_package_field "$package_basename" Version)" = "$package_version" ]
  [ "$(manifest_package_field "$package_basename" Architecture)" = arm64 ]
  [ "$(manifest_package_field "$package_basename" 'Size bytes')" -eq "$actual_size" ]
  [ "$(manifest_package_field "$package_basename" SHA-256)" = "$actual_sha" ]

  changes_entry="$(changes_sha_size "$package_basename")"
  read -r expected_sha expected_size <<<"$changes_entry"
  [ "$expected_sha" = "$actual_sha" ]
  [ "$expected_size" -eq "$actual_size" ]
done

verify_root="$(mktemp -d "$output_root/.verify.${build_id}.XXXXXXXX")"
validate_private_child "$verify_root" || die "Invalid host verification directory"
dpkg-deb -x "${output_debs[1]}" "$verify_root"
validate_private_child_path "$verify_root" ||
  die "Package extraction changed the host verification path"
chmod 0700 "$verify_root"
validate_private_child "$verify_root" ||
  die "Could not restore private host verification permissions"

host_multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
[ "$host_multiarch" = aarch64-linux-gnu ] ||
  die "Unexpected host multiarch: $host_multiarch"
host_ipa_module="$verify_root/usr/lib/$host_multiarch/libcamera/ipa/ipa_soft_simple.so"
host_ipa_signature="$host_ipa_module.sign"
host_tuning="$verify_root/usr/share/libcamera/ipa/simple/imx681.yaml"
for required_file in "$host_ipa_module" "$host_ipa_signature" "$host_tuning"; do
  [ -f "$required_file" ] && [ ! -L "$required_file" ] ||
    die "Missing host-verified libcamera-ipa content: $required_file"
done
cmp -- "$yaml_file" "$host_tuning"

dpkg-deb -x "${output_debs[0]}" "$verify_root"
dpkg-deb -x "${output_debs[2]}" "$verify_root"
validate_private_child_path "$verify_root" ||
  die "Package extraction changed the host verification path"
chmod 0700 "$verify_root"
validate_private_child "$verify_root" ||
  die "Could not restore private host verification permissions"
host_ipa_verifier="$verify_root/usr/bin/ipa_verify"
[ -f "$host_ipa_verifier" ] && [ ! -L "$host_ipa_verifier" ] ||
  die "Missing host-verified libcamera-tools verifier: $host_ipa_verifier"
host_verify_output="$(LD_LIBRARY_PATH="$verify_root/usr/lib/$host_multiarch" \
  "$host_ipa_verifier" "$host_ipa_module")"
[ "$host_verify_output" = 'IPA module signature is valid' ] ||
  die "Host same-build IPA verification failed: $host_verify_output"

{
  printf '\n'
  printf 'Host post-copy delivered Changes-Sha256 entries verified: yes\n'
  printf 'Host post-copy same-build IPA verification: %s\n' "$host_verify_output"
} >>"$manifest"
[ "$(stat -c '%a' "$manifest")" = 644 ]
[ "$(manifest_scalar 'Host post-copy delivered Changes-Sha256 entries verified')" = yes ]
[ "$(manifest_scalar 'Host post-copy same-build IPA verification')" = \
  'IPA module signature is valid' ]

remove_private_child "$verify_root" || die "Could not remove host verification directory"
verify_root=""

build_complete=true
trap - EXIT

echo
echo "Verified SP11 IMX681 libcamera packages are ready:"
echo "  $output_dir"
echo "Manifest:"
echo "  $manifest"
echo "Host same-build IPA verification: $host_verify_output"
echo "Nothing was installed on the host."
