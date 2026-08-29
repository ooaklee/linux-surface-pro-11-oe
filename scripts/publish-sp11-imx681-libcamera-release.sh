#!/usr/bin/env bash
set -euo pipefail

umask 022

DEFAULT_TAG="sp11-imx681-libcamera-v1"
DEFAULT_KERNEL_TAG="sp11-qcom-x1e-7.2.0-jg-0sp11v14"
DEFAULT_KERNEL_ABI="7.2.0-jg-0sp11v14-qcom-x1e"
DEFAULT_GITHUB_REPO="ooaklee/linux-surface-pro-11-oe"

MODE=""
ARTIFACTS_DIR=""
TAG="$DEFAULT_TAG"
KERNEL_TAG="$DEFAULT_KERNEL_TAG"
KERNEL_ABI="$DEFAULT_KERNEL_ABI"
GITHUB_REPO="$DEFAULT_GITHUB_REPO"

usage() {
	cat <<EOF
Usage: $(basename "$0") (--dry-run | --publish) --artifacts-dir DIR [options]

Stage, verify, and optionally publish one coherent Surface Pro 11 IMX681
libcamera package build. The input directory must contain exactly the five
selected ARM64 runtime packages, their original .changes and .buildinfo files,
and the verified build manifest produced by the Docker builder.

Modes:
  --dry-run             Verify and stage the release, then print the gh command.
  --publish             Verify, publish, and validate a fresh download.

Required:
  --artifacts-dir DIR   Exact eight-file output directory from
                        build-sp11-imx681-libcamera-docker.sh.

Options:
  --tag TAG             Release tag (default: $DEFAULT_TAG).
  --kernel-tag TAG      Paired kernel release tag
                        (default: $DEFAULT_KERNEL_TAG).
  --kernel-abi ABI      Paired installed kernel ABI
                        (default: $DEFAULT_KERNEL_ABI).
  --repo OWNER/REPO     GitHub repository (default: $DEFAULT_GITHUB_REPO).
  -h, --help            Show this help.

Staging directory:
  build/release/<tag>/
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

require_arg() {
	[[ -n "${2:-}" ]] || {
		printf 'ERROR: %s requires a value.\n' "$1" >&2
		usage >&2
		exit 2
	}
}

require_tool() {
	command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

print_command() {
	printf '  '
	printf '%q ' "$@"
	printf '\n'
}

file_size() {
	stat -c '%s' -- "$1"
}

file_sha256() {
	sha256sum -- "$1" | awk '{ print $1 }'
}

while (($#)); do
	case "$1" in
	--dry-run)
		[[ -z "$MODE" ]] || die "choose exactly one of --dry-run or --publish"
		MODE="dry-run"
		shift
		;;
	--publish)
		[[ -z "$MODE" ]] || die "choose exactly one of --dry-run or --publish"
		MODE="publish"
		shift
		;;
	--artifacts-dir)
		require_arg "$1" "${2:-}"
		ARTIFACTS_DIR="$2"
		shift 2
		;;
	--tag)
		require_arg "$1" "${2:-}"
		TAG="$2"
		shift 2
		;;
	--kernel-tag)
		require_arg "$1" "${2:-}"
		KERNEL_TAG="$2"
		shift 2
		;;
	--kernel-abi)
		require_arg "$1" "${2:-}"
		KERNEL_ABI="$2"
		shift 2
		;;
	--repo)
		require_arg "$1" "${2:-}"
		GITHUB_REPO="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'ERROR: unknown argument: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

[[ -n "$MODE" ]] || {
	usage >&2
	exit 2
}
[[ -n "$ARTIFACTS_DIR" ]] || die "--artifacts-dir is required"
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "unsafe release tag: $TAG"
[[ "$KERNEL_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
	die "unsafe kernel tag: $KERNEL_TAG"
[[ "$KERNEL_ABI" =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]] ||
	die "unsafe kernel ABI: $KERNEL_ABI"
kernel_version="${KERNEL_ABI%-qcom-x1e}"
[[ "$kernel_version" != "$KERNEL_ABI" && "$KERNEL_TAG" == *"$kernel_version"* ]] ||
	die "kernel tag and installed ABI do not identify the same qcom-x1e version"
[[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
	die "unsafe GitHub repository: $GITHUB_REPO"

required_tools=(
	awk basename cat cmp dirname dpkg-architecture dpkg-deb find git grep id
	install mktemp readlink rm sha256sum sort stat uname wc
)
for required_tool in "${required_tools[@]}"; do
	require_tool "$required_tool"
done

script_source="${BASH_SOURCE[0]}"
[[ ! -L "$script_source" ]] || die "release script must not be a symlink"
script_path="$(readlink -f -- "$script_source")"
script_dir="$(dirname "$script_path")"
repo_dir="$(git -C "$script_dir" rev-parse --show-toplevel)"
repo_dir="$(readlink -f -- "$repo_dir")"
expected_script="$repo_dir/scripts/$(basename "$script_path")"
[[ "$script_path" == "$expected_script" ]] ||
	die "release script must run from its canonical repository path"
cd "$repo_dir"

git check-ref-format "refs/tags/$TAG" >/dev/null 2>&1 ||
	die "invalid release tag: $TAG"
git check-ref-format "refs/tags/$KERNEL_TAG" >/dev/null 2>&1 ||
	die "invalid kernel tag: $KERNEL_TAG"

git diff --quiet -- || die "tracked worktree changes must be committed first"
git diff --cached --quiet -- || die "staged changes must be committed first"

support_commit="$(git rev-parse --verify 'HEAD^{commit}')"
current_branch="$(git symbolic-ref --quiet --short HEAD)" ||
	die "publish from a named support-repository branch"

script_relative="scripts/$(basename "$script_path")"
git ls-files --error-unmatch "$script_relative" >/dev/null 2>&1 ||
	die "release script is not tracked at support HEAD"
script_head_sha="$(git show "$support_commit:$script_relative" | sha256sum | awk '{ print $1 }')"
[[ "$script_head_sha" == "$(file_sha256 "$script_path")" ]] ||
	die "release script differs from support HEAD"

origin_url="$(git remote get-url origin)" || die "support repository has no origin remote"
case "$origin_url" in
git@github.com:*) origin_repo="${origin_url#git@github.com:}" ;;
https://github.com/*) origin_repo="${origin_url#https://github.com/}" ;;
ssh://git@github.com/*) origin_repo="${origin_url#ssh://git@github.com/}" ;;
*) die "unsupported origin URL for GitHub publication: $origin_url" ;;
esac
origin_repo="${origin_repo%.git}"
[[ "$origin_repo" == "$GITHUB_REPO" ]] ||
	die "--repo $GITHUB_REPO does not match origin repository $origin_repo"

build_root="$repo_dir/build"
if [[ -e "$build_root" || -L "$build_root" ]]; then
	[[ -d "$build_root" && ! -L "$build_root" ]] ||
		die "refusing unsafe build directory: $build_root"
else
	install -d -m 0755 -- "$build_root"
fi
[[ "$(readlink -f -- "$build_root")" == "$build_root" ]] ||
	die "build directory resolves outside its canonical path"
[[ "$(stat -c '%u' -- "$build_root")" == "$(id -u)" ]] ||
	die "build directory is not owned by the invoking user"

release_inputs=(
	scripts/build-sp11-imx681-libcamera-docker.sh
	userspace/camera/libcamera/0001-libipa-add-imx681-simple-ipa-support.patch
	userspace/camera/libcamera/BASE.txt
	userspace/camera/libcamera/imx681.yaml
)
for release_input in "${release_inputs[@]}"; do
	git ls-files --error-unmatch "$release_input" >/dev/null 2>&1 ||
		die "release input is not tracked: $release_input"
	[[ -f "$release_input" && ! -L "$release_input" ]] ||
		die "release input is not a regular file: $release_input"
	head_sha="$(git show "$support_commit:$release_input" | sha256sum | awk '{ print $1 }')"
	worktree_sha="$(file_sha256 "$release_input")"
	[[ "$head_sha" == "$worktree_sha" ]] ||
		die "release input differs from support HEAD: $release_input"
done

artifact_root="$build_root/libcamera-docker"
[[ -d "$artifact_root" && ! -L "$artifact_root" ]] ||
	die "missing canonical libcamera builder output root: $artifact_root"
[[ "$(readlink -f -- "$artifact_root")" == "$artifact_root" ]] ||
	die "libcamera builder output root resolves outside its canonical path"
[[ "$(stat -c '%u' -- "$artifact_root")" == "$(id -u)" ]] ||
	die "libcamera builder output root is not owned by the invoking user"
[[ "$(stat -c '%a' -- "$artifact_root")" == "700" ]] ||
	die "libcamera builder output root must be mode 0700"

[[ -d "$ARTIFACTS_DIR" && ! -L "$ARTIFACTS_DIR" ]] ||
	die "artifact directory must be a real directory: $ARTIFACTS_DIR"
ARTIFACTS_DIR="$(readlink -f -- "$ARTIFACTS_DIR")"
[[ "$(dirname "$ARTIFACTS_DIR")" == "$artifact_root" ]] ||
	die "artifact directory must be a direct child of $artifact_root"
[[ "$(basename "$ARTIFACTS_DIR")" == build.* ]] ||
	die "artifact directory must use the builder's build.* naming convention"
[[ "$(stat -c '%u' -- "$ARTIFACTS_DIR")" == "$(id -u)" ]] ||
	die "artifact directory is not owned by the invoking user"
[[ "$(stat -c '%a' -- "$ARTIFACTS_DIR")" == "700" ]] ||
	die "artifact directory must be mode 0700"

manifest="$ARTIFACTS_DIR/sp11-imx681-libcamera-build-manifest.txt"
[[ -f "$manifest" && ! -L "$manifest" ]] ||
	die "missing regular build manifest: $manifest"

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
	local changes_file="$1"
	local selected_name="$2"
	awk -v selected_name="$selected_name" '
		/^Checksums-Sha256:$/ { active = 1; next }
		active && NF == 3 {
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

[[ "$(manifest_scalar 'Manifest format')" == "2" ]] ||
	die "unsupported build-manifest format"
[[ "$(manifest_scalar 'Build status')" == "verified" ]] ||
	die "build manifest is not verified"
[[ "$(manifest_scalar 'Four build inputs matched support HEAD')" == "yes" ]] ||
	die "build inputs were not authenticated at build time"
[[ "$(manifest_scalar 'Selected runtime package count')" == "5" ]] ||
	die "build manifest does not select five runtime packages"
[[ "$(manifest_scalar 'Same-build IPA verification')" == "IPA module signature is valid" ]] ||
	die "container IPA verification did not pass"
[[ "$(manifest_scalar 'Host post-copy delivered Changes-Sha256 entries verified')" == "yes" ]] ||
	die "host Changes verification did not pass"
[[ "$(manifest_scalar 'Host post-copy same-build IPA verification')" == "IPA module signature is valid" ]] ||
	die "host IPA verification did not pass"
[[ "$(manifest_scalar 'Original Changes file retained unmodified')" == "yes" ]] ||
	die "original Changes record was not retained"
[[ "$(manifest_scalar 'Container pre-export every Changes-Sha256 entry hash verified')" == "yes" ]] ||
	die "container Changes verification did not pass"
[[ "$(manifest_scalar 'Delivered Changes-Sha256 entry count')" == "6" ]] ||
	die "manifest does not bind the five packages and buildinfo"

changes_entry_count="$(manifest_scalar 'Container pre-export Changes-Sha256 entry count')"
omitted_entry_count="$(manifest_scalar 'Undelivered Changes-Sha256 entries intentionally omitted')"
[[ "$changes_entry_count" =~ ^[0-9]+$ && "$omitted_entry_count" =~ ^[0-9]+$ ]] ||
	die "invalid Changes entry counts in the manifest"
[[ "$changes_entry_count" -ge 6 && "$omitted_entry_count" -eq $((changes_entry_count - 6)) ]] ||
	die "Changes delivered/omitted entry counts are inconsistent"
actual_omitted_count="$(grep -c '^  Omitted entry: ' "$manifest")"
[[ "$actual_omitted_count" -eq "$omitted_entry_count" ]] ||
	die "manifest omitted-entry list does not match its count"

build_id="$(manifest_scalar 'Build ID')"
source_version="$(manifest_scalar 'Source version')"
package_version_from_manifest="$(manifest_scalar 'Package version')"
[[ "$build_id" =~ ^[0-9]{23}\.[0-9a-f]{32}$ ]] ||
	die "invalid unique build ID in manifest"
[[ "$package_version_from_manifest" == "${source_version}+sp11.1.${build_id}" ]] ||
	die "package version is not derived from source version and build ID"

base_file="userspace/camera/libcamera/BASE.txt"
base_source_version="$(record_scalar "$base_file" 'Ubuntu package validated on device')"
base_source_version="${base_source_version%% *}"
[[ "$base_source_version" == "$source_version" ]] ||
	die "manifest source version differs from authenticated BASE.txt"
[[ "$(record_scalar "$base_file" 'Ubuntu DSC SHA-256')" == "$(manifest_scalar 'Source DSC SHA-256')" ]] ||
	die "DSC hash differs from BASE.txt"
[[ "$(record_scalar "$base_file" 'Ubuntu orig tarball SHA-256')" == "$(manifest_scalar 'Orig tarball SHA-256')" ]] ||
	die "orig tarball hash differs from BASE.txt"
[[ "$(record_scalar "$base_file" 'Ubuntu Debian tarball SHA-256')" == "$(manifest_scalar 'Debian tarball SHA-256')" ]] ||
	die "Debian tarball hash differs from BASE.txt"

build_support_commit="$(manifest_scalar 'Support HEAD')"
[[ "$build_support_commit" =~ ^[0-9a-f]{40}$ ]] ||
	die "invalid build support commit: $build_support_commit"
git cat-file -e "$build_support_commit^{commit}" 2>/dev/null ||
	die "build support commit is unavailable locally: $build_support_commit"
git merge-base --is-ancestor "$build_support_commit" "$support_commit" ||
	die "build support commit is not an ancestor of release support HEAD"

declare -A input_manifest_fields=(
	[scripts/build-sp11-imx681-libcamera-docker.sh]="Builder script SHA-256"
	[userspace/camera/libcamera/0001-libipa-add-imx681-simple-ipa-support.patch]="Local patch SHA-256"
	[userspace/camera/libcamera/BASE.txt]="BASE.txt SHA-256"
	[userspace/camera/libcamera/imx681.yaml]="IMX681 YAML SHA-256"
)
for release_input in "${release_inputs[@]}"; do
	manifest_sha="$(manifest_scalar "${input_manifest_fields[$release_input]}")"
	build_head_sha="$(git show "$build_support_commit:$release_input" | sha256sum | awk '{ print $1 }')"
	current_head_sha="$(git show "$support_commit:$release_input" | sha256sum | awk '{ print $1 }')"
	[[ "$manifest_sha" == "$build_head_sha" && "$manifest_sha" == "$current_head_sha" ]] ||
		die "build input identity changed: $release_input"
done

package_version="$package_version_from_manifest"
[[ "$package_version" =~ ^[A-Za-z0-9.+:~_-]+$ ]] ||
	die "unsafe package version in manifest: $package_version"

package_names=(
	libcamera0.7
	libcamera-ipa
	libcamera-tools
	libcamera-v4l2
	gstreamer1.0-libcamera
)
package_files=()
artifact_names=()
for package_name in "${package_names[@]}"; do
	package_file="${package_name}_${package_version}_arm64.deb"
	package_files+=("$ARTIFACTS_DIR/$package_file")
	artifact_names+=("$package_file")
done

changes_name="$(manifest_scalar 'Changes file')"
buildinfo_name="$(manifest_scalar 'Buildinfo file')"
[[ "$changes_name" == "libcamera_${package_version}_arm64.changes" ]] ||
	die "unexpected Changes filename: $changes_name"
[[ "$buildinfo_name" == "libcamera_${package_version}_arm64.buildinfo" ]] ||
	die "unexpected buildinfo filename: $buildinfo_name"
changes_file="$ARTIFACTS_DIR/$changes_name"
buildinfo_file="$ARTIFACTS_DIR/$buildinfo_name"
artifact_names+=("$changes_name" "$buildinfo_name" "$(basename "$manifest")")

declare -A expected_artifacts=()
for artifact_name in "${artifact_names[@]}"; do
	expected_artifacts["$artifact_name"]=1
done

artifact_count=0
while IFS= read -r -d '' artifact; do
	artifact_count=$((artifact_count + 1))
	[[ -f "$artifact" && ! -L "$artifact" ]] ||
		die "unexpected non-regular artifact entry: $artifact"
	[[ "$(stat -c '%u' -- "$artifact")" == "$(id -u)" ]] ||
		die "artifact is not owned by the invoking user: $artifact"
	[[ "$(stat -c '%a' -- "$artifact")" == "644" ]] ||
		die "artifact must be mode 0644: $artifact"
	artifact_name="$(basename "$artifact")"
	[[ -n "${expected_artifacts[$artifact_name]+x}" ]] ||
		die "unexpected artifact in bounded build directory: $artifact_name"
done < <(find "$ARTIFACTS_DIR" -mindepth 1 -maxdepth 1 -print0)
[[ "$artifact_count" -eq 8 && "${#expected_artifacts[@]}" -eq 8 ]] ||
	die "artifact directory must contain exactly the expected eight files"

[[ "$(record_scalar "$changes_file" Source)" == "libcamera" ]] ||
	die "Changes source is not libcamera"
[[ "$(record_scalar "$changes_file" Version)" == "$package_version" ]] ||
	die "Changes version does not match the manifest"
[[ "$(record_scalar "$changes_file" Architecture)" == "arm64" ]] ||
	die "Changes architecture is not arm64"
[[ "$(record_scalar "$buildinfo_file" Source)" == "libcamera" ]] ||
	die "buildinfo source is not libcamera"
[[ "$(record_scalar "$buildinfo_file" Version)" == "$package_version" ]] ||
	die "buildinfo version does not match the manifest"
[[ "$(record_scalar "$buildinfo_file" Architecture)" == "arm64" ]] ||
	die "buildinfo architecture is not arm64"
[[ "$(manifest_scalar 'Changes file SHA-256')" == "$(file_sha256 "$changes_file")" ]] ||
	die "Changes hash does not match the manifest"
[[ "$(manifest_scalar 'Buildinfo file SHA-256')" == "$(file_sha256 "$buildinfo_file")" ]] ||
	die "buildinfo hash does not match the manifest"

mapfile -t omitted_records < <(
	awk '/^  Omitted entry: / { print $3, $4, $5 }' "$manifest"
)
[[ "${#omitted_records[@]}" -eq "$omitted_entry_count" ]] ||
	die "could not parse every omitted Changes entry"
for omitted_record in "${omitted_records[@]}"; do
	read -r omitted_sha omitted_size omitted_name <<<"$omitted_record"
	[[ "$omitted_sha" =~ ^[0-9a-f]{64}$ && "$omitted_size" =~ ^[0-9]+$ ]] ||
		die "invalid omitted Changes record: $omitted_record"
	[[ "$(basename "$omitted_name")" == "$omitted_name" ]] ||
		die "unsafe omitted artifact name: $omitted_name"
	read -r changes_sha changes_size <<<"$(changes_sha_size "$changes_file" "$omitted_name")"
	[[ "$changes_sha" == "$omitted_sha" && "$changes_size" == "$omitted_size" ]] ||
		die "omitted manifest entry differs from Changes: $omitted_name"
	[[ ! -e "$ARTIFACTS_DIR/$omitted_name" && ! -L "$ARTIFACTS_DIR/$omitted_name" ]] ||
		die "artifact marked omitted is present: $omitted_name"
done

for index in "${!package_files[@]}"; do
	package_path="${package_files[$index]}"
	package_name="${package_names[$index]}"
	package_file="$(basename "$package_path")"
	[[ -f "$package_path" && ! -L "$package_path" ]] ||
		die "missing regular runtime package: $package_path"
	[[ "$(dpkg-deb -f "$package_path" Package)" == "$package_name" ]] ||
		die "wrong package identity in $package_file"
	[[ "$(dpkg-deb -f "$package_path" Source)" == "libcamera" ]] ||
		die "wrong package source in $package_file"
	[[ "$(dpkg-deb -f "$package_path" Version)" == "$package_version" ]] ||
		die "mixed package version in $package_file"
	[[ "$(dpkg-deb -f "$package_path" Architecture)" == "arm64" ]] ||
		die "wrong package architecture in $package_file"

	actual_size="$(file_size "$package_path")"
	actual_sha="$(file_sha256 "$package_path")"
	[[ "$(manifest_package_field "$package_file" Package)" == "$package_name" ]] ||
		die "manifest package identity mismatch for $package_file"
	[[ "$(manifest_package_field "$package_file" Source)" == "libcamera" ]] ||
		die "manifest package source mismatch for $package_file"
	[[ "$(manifest_package_field "$package_file" Version)" == "$package_version" ]] ||
		die "manifest package version mismatch for $package_file"
	[[ "$(manifest_package_field "$package_file" Architecture)" == "arm64" ]] ||
		die "manifest package architecture mismatch for $package_file"
	[[ "$(manifest_package_field "$package_file" 'Size bytes')" == "$actual_size" ]] ||
		die "manifest package size mismatch for $package_file"
	[[ "$(manifest_package_field "$package_file" 'SHA-256')" == "$actual_sha" ]] ||
		die "manifest package hash mismatch for $package_file"

	read -r changes_sha changes_size <<<"$(changes_sha_size "$changes_file" "$package_file")"
	[[ "$changes_sha" == "$actual_sha" && "$changes_size" == "$actual_size" ]] ||
		die "Changes entry mismatch for $package_file"
done

buildinfo_sha="$(file_sha256 "$buildinfo_file")"
buildinfo_size="$(file_size "$buildinfo_file")"
read -r changes_sha changes_size <<<"$(changes_sha_size "$changes_file" "$buildinfo_name")"
[[ "$changes_sha" == "$buildinfo_sha" && "$changes_size" == "$buildinfo_size" ]] ||
	die "Changes entry mismatch for $buildinfo_name"

case "$(uname -m)" in
aarch64 | arm64) ;;
*) die "native ARM64 is required for same-build IPA verification" ;;
esac
multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
[[ "$multiarch" == "aarch64-linux-gnu" ]] || die "unexpected host multiarch: $multiarch"

verify_root="$(mktemp -d "$repo_dir/build/.libcamera-release-verify.XXXXXXXX")"
cleanup_verify_root() {
	if [[ -n "${verify_root:-}" && -d "$verify_root" && ! -L "$verify_root" ]]; then
		case "$(readlink -f -- "$verify_root")" in
		"$repo_dir"/build/.libcamera-release-verify.*)
			find "$verify_root" -xdev -depth -delete
			;;
		esac
	fi
}
trap cleanup_verify_root EXIT

dpkg-deb -x "${package_files[0]}" "$verify_root"
dpkg-deb -x "${package_files[1]}" "$verify_root"
dpkg-deb -x "${package_files[2]}" "$verify_root"
ipa_module="$verify_root/usr/lib/$multiarch/libcamera/ipa/ipa_soft_simple.so"
ipa_signature="$ipa_module.sign"
ipa_verifier="$verify_root/usr/bin/ipa_verify"
tuning_file="$verify_root/usr/share/libcamera/ipa/simple/imx681.yaml"
for required_file in "$ipa_module" "$ipa_signature" "$ipa_verifier" "$tuning_file"; do
	[[ -f "$required_file" && ! -L "$required_file" ]] ||
		die "missing extracted IPA verification input: $required_file"
done
cmp -- userspace/camera/libcamera/imx681.yaml "$tuning_file" ||
	die "packaged IMX681 tuning does not match the authenticated support asset"
verify_output="$(
	LD_LIBRARY_PATH="$verify_root/usr/lib/$multiarch" \
		"$ipa_verifier" "$ipa_module"
)"
[[ "$verify_output" == "IPA module signature is valid" ]] ||
	die "same-build IPA signature verification failed: $verify_output"
cleanup_verify_root
verify_root=""
trap - EXIT

release_root="$repo_dir/build/release"
stage_dir="$release_root/$TAG"
[[ ! -L "$repo_dir/build" ]] || die "refusing symlinked build directory"
if [[ -e "$release_root" || -L "$release_root" ]]; then
	[[ -d "$release_root" && ! -L "$release_root" ]] ||
		die "refusing unsafe release root: $release_root"
else
	install -d -m 0755 -- "$release_root"
fi
[[ "$(readlink -f -- "$release_root")" == "$release_root" ]] ||
	die "release root resolves outside its canonical path"
[[ "$(stat -c '%u' -- "$release_root")" == "$(id -u)" ]] ||
	die "release root is not owned by the invoking user"
if [[ -e "$stage_dir" || -L "$stage_dir" ]]; then
	[[ -d "$stage_dir" && ! -L "$stage_dir" ]] ||
		die "refusing unsafe staging directory: $stage_dir"
else
	install -d -m 0755 -- "$stage_dir"
fi
[[ "$(readlink -f -- "$stage_dir")" == "$stage_dir" ]] ||
	die "staging directory resolves outside its canonical path"
[[ "$(stat -c '%u' -- "$stage_dir")" == "$(id -u)" ]] ||
	die "staging directory is not owned by the invoking user"

allowed_stage_names=("${artifact_names[@]}" SHA256SUMS RELEASE-NOTES.md)
declare -A allowed_stage=()
for allowed_name in "${allowed_stage_names[@]}"; do
	allowed_stage["$allowed_name"]=1
done
while IFS= read -r -d '' existing; do
	existing_name="$(basename "$existing")"
	[[ -n "${allowed_stage[$existing_name]+x}" && -f "$existing" && ! -L "$existing" ]] ||
		die "refusing unknown or unsafe staging entry: $existing"
done < <(find "$stage_dir" -mindepth 1 -maxdepth 1 -print0)
for allowed_name in "${allowed_stage_names[@]}"; do
	rm -f -- "$stage_dir/$allowed_name"
done

for artifact_name in "${artifact_names[@]}"; do
	install -m 0644 -- "$ARTIFACTS_DIR/$artifact_name" "$stage_dir/$artifact_name"
done

(
	cd "$stage_dir"
	sha256sum -- "${artifact_names[@]}" >SHA256SUMS
	sha256sum --check --strict SHA256SUMS
)

kernel_url="https://github.com/$GITHUB_REPO/releases/tag/$KERNEL_TAG"
release_url="https://github.com/$GITHUB_REPO/releases/tag/$TAG"
source_url="$(manifest_scalar 'Source URL')"
notes_file="$stage_dir/RELEASE-NOTES.md"
cat >"$notes_file" <<'RELEASE_NOTES'
# Surface Pro 11 IMX681 libcamera package set

IMX681-aware libcamera Simple IPA packages for the Microsoft Surface Pro 11
(X1E80100). This userspace release is paired with the
[@KERNEL_TAG@ kernel release](@KERNEL_URL@), installed ABI
`@KERNEL_ABI@`.

Install the paired kernel and all five packages below as coherent sets. The
libcamera core embeds the public key used to verify the same-build IPA module;
mixing package versions can make the IPA fail authentication.

## Artifact set

- `@ARTIFACT_0@`
- `@ARTIFACT_1@`
- `@ARTIFACT_2@`
- `@ARTIFACT_3@`
- `@ARTIFACT_4@`
- `@CHANGES_NAME@` and `@BUILDINFO_NAME@` preserve the original package-build
  records.
- `sp11-imx681-libcamera-build-manifest.txt` records source, builder, input,
  package, and signature-verification provenance.
- `SHA256SUMS` covers every other uploaded asset exactly once.

The original `.changes` also records development, Python, debug, and detached
debug-symbol outputs that were deliberately not selected for this bounded
runtime release. The attached manifest names those omitted build outputs.

## Verify and install

Download `SHA256SUMS` and every asset named in it into one directory, then run:

```bash
sha256sum --check --strict SHA256SUMS

sudo apt install -- \
  ./@ARTIFACT_0@ \
  ./@ARTIFACT_1@ \
  ./@ARTIFACT_2@ \
  ./@ARTIFACT_3@ \
  ./@ARTIFACT_4@
```

Reboot after installing the paired kernel and userspace packages so every
camera client and service loads the same package generation.

Firefox needs `media.webrtc.camera.allow-pipewire=true`. Chromium and Google
Chrome need the `WebRtcPipeWireCamera` feature, exposed by
`chrome://flags/#enable-webrtc-pipewire-camera` when available.

## Validation

This exact five-package version was installed and validated on the target
Surface Pro 11 with the paired camera kernel. The simple IPA selected
`simple/imx681.yaml`, its signature verified against the same-build core,
PipeWire/WirePlumber published `Built-in Front Camera`, and Firefox Google
Meet received a processed 1280x720 stream. Raw capture also passed repeated
and continuous transport tests. Non-blocking resilience, automatic-exposure,
privacy-LED, pedestal, and colour-calibration follow-up remains in
[issue #54](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/54).

## Provenance

- Package version: `@PACKAGE_VERSION@`
- Package-build support commit: `@BUILD_SUPPORT_COMMIT@`
- Release-tool support commit and tag target: `@SUPPORT_COMMIT@`
- Ubuntu source package: `@SOURCE_VERSION@`
- Ubuntu source URL: @SOURCE_URL@
- Builder image: `@BUILDER_IMAGE@`
- Build jobs: `@BUILD_JOBS@`
- Package inputs and output hashes: `sp11-imx681-libcamera-build-manifest.txt`

The exact downstream patch, tuning, base-source hashes, and builder are retained
in the immutable [@RELEASE_TAG@ support tree](@SUPPORT_TREE_URL@)
and in the attached provenance records. These artifacts were built from the
recorded inputs; bit-for-bit reproducibility is not claimed.

The IMX681 Simple IPA work derives from
[turbineBMW](https://github.com/turbineBMW/surface-pro-11-linux/tree/main/userspace/libcamera),
with SP11 integration informed by [karsies-wq](https://github.com/karsies-wq)
and [geocausa](https://github.com/geocausa).

- Paired kernel release: [@KERNEL_TAG@](@KERNEL_URL@)
- This libcamera release: [@RELEASE_TAG@](@RELEASE_URL@)
RELEASE_NOTES

notes_content="$(<"$notes_file")"
replace_notes_placeholder() {
	local placeholder="$1"
	local replacement="$2"
	notes_content="${notes_content//"$placeholder"/"$replacement"}"
}
replace_notes_placeholder '@KERNEL_TAG@' "$KERNEL_TAG"
replace_notes_placeholder '@KERNEL_URL@' "$kernel_url"
replace_notes_placeholder '@KERNEL_ABI@' "$KERNEL_ABI"
replace_notes_placeholder '@RELEASE_TAG@' "$TAG"
replace_notes_placeholder '@RELEASE_URL@' "$release_url"
replace_notes_placeholder '@ARTIFACT_0@' "${artifact_names[0]}"
replace_notes_placeholder '@ARTIFACT_1@' "${artifact_names[1]}"
replace_notes_placeholder '@ARTIFACT_2@' "${artifact_names[2]}"
replace_notes_placeholder '@ARTIFACT_3@' "${artifact_names[3]}"
replace_notes_placeholder '@ARTIFACT_4@' "${artifact_names[4]}"
replace_notes_placeholder '@CHANGES_NAME@' "$changes_name"
replace_notes_placeholder '@BUILDINFO_NAME@' "$buildinfo_name"
replace_notes_placeholder '@PACKAGE_VERSION@' "$package_version"
replace_notes_placeholder '@BUILD_SUPPORT_COMMIT@' "$build_support_commit"
replace_notes_placeholder '@SUPPORT_COMMIT@' "$support_commit"
replace_notes_placeholder '@SOURCE_VERSION@' "$(manifest_scalar 'Source version')"
replace_notes_placeholder '@SOURCE_URL@' "$source_url"
replace_notes_placeholder '@BUILDER_IMAGE@' "$(manifest_scalar 'Builder image ID')"
replace_notes_placeholder '@BUILD_JOBS@' "$(manifest_scalar 'Build jobs')"
replace_notes_placeholder '@SUPPORT_TREE_URL@' \
	"https://github.com/$GITHUB_REPO/tree/$TAG/userspace/camera/libcamera"
[[ ! "$notes_content" =~ @[A-Z0-9_]+@ ]] ||
	die "release-note placeholder expansion failed"
printf '%s\n' "$notes_content" >"$notes_file"

for public_text in \
	"$stage_dir/$changes_name" \
	"$stage_dir/$buildinfo_name" \
	"$stage_dir/sp11-imx681-libcamera-build-manifest.txt" \
	"$stage_dir/SHA256SUMS" \
	"$notes_file"; do
	if grep -E '/home/leon|/Users/leon|Workspace/repos|GH_TOKEN|GITHUB_TOKEN|API_TOKEN|password|secret' \
		"$public_text" >/dev/null; then
		die "private or local-only text found in staged release record: $public_text"
	fi
done

release_title="Surface Pro 11 IMX681 libcamera package set"
publish_assets=()
for artifact_name in "${artifact_names[@]}"; do
	publish_assets+=("$stage_dir/$artifact_name")
done
publish_assets+=("$stage_dir/SHA256SUMS")
publish_command=(
	gh release create "$TAG"
	--repo "$GITHUB_REPO"
	--target "$support_commit"
	--title "$release_title"
	--notes-file "$notes_file"
	--draft
	--prerelease
	--latest=false
	"${publish_assets[@]}"
)

printf 'Release tag:       %s\n' "$TAG"
printf 'Paired kernel tag: %s\n' "$KERNEL_TAG"
printf 'Package version:   %s\n' "$package_version"
printf 'Build support:     %s\n' "$build_support_commit"
printf 'Release target:    %s\n' "$support_commit"
printf 'Staged at:         %s\n' "${stage_dir#"$repo_dir/"}"
printf 'IPA verification:  %s\n' "$verify_output"
printf '\nPublish command:\n'
print_command "${publish_command[@]}"

if [[ "$MODE" == "dry-run" ]]; then
	printf '\nDry run complete; GitHub was not changed.\n'
	exit 0
fi

require_tool gh
remote_branch_commit="$(git ls-remote --exit-code origin "refs/heads/$current_branch" | awk 'NR == 1 { print $1 }')" ||
	die "could not resolve origin/$current_branch"
[[ "$remote_branch_commit" == "$support_commit" ]] ||
	die "support HEAD is not pushed to origin/$current_branch"

git show-ref --verify --quiet "refs/tags/$TAG" &&
	die "local tag already exists: $TAG"
remote_tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}" \
	>/dev/null 2>&1 || remote_tag_status=$?
case "$remote_tag_status" in
0) die "remote tag already exists: $TAG" ;;
2) ;;
*) die "could not verify remote tag absence: $TAG" ;;
esac

gh api "repos/$GITHUB_REPO" --silent >/dev/null ||
	die "GitHub repository is unavailable through gh: $GITHUB_REPO"

release_lookup_status=0
release_lookup_output="$(
	gh api "repos/$GITHUB_REPO/releases/tags/$TAG" 2>&1
)" || release_lookup_status=$?
if [[ "$release_lookup_status" -eq 0 ]]; then
	die "GitHub release already exists: $TAG"
fi
[[ "$release_lookup_output" == *"HTTP 404"* ]] ||
	die "could not prove GitHub release absence: $release_lookup_output"
existing_release_list_status=0
existing_release_id_output="$(
	gh api --paginate "repos/$GITHUB_REPO/releases?per_page=100" \
		--jq ".[] | select(.tag_name == \"$TAG\") | .id"
)" || existing_release_list_status=$?
[[ "$existing_release_list_status" -eq 0 ]] ||
	die "could not enumerate draft and published releases"
existing_release_ids=()
if [[ -n "$existing_release_id_output" ]]; then
	mapfile -t existing_release_ids <<<"$existing_release_id_output"
fi
[[ "${#existing_release_ids[@]}" -eq 0 ]] ||
	die "a draft or published GitHub release already uses tag $TAG"

kernel_release_draft="$(
	gh release view "$KERNEL_TAG" --repo "$GITHUB_REPO" --json isDraft --jq .isDraft
)" || die "paired kernel release is not available: $KERNEL_TAG"
[[ "$kernel_release_draft" == "false" ]] ||
	die "paired kernel release is still a draft: $KERNEL_TAG"
kernel_release_body="$(
	gh release view "$KERNEL_TAG" --repo "$GITHUB_REPO" --json body --jq .body
)"
[[ "$kernel_release_body" == *"$release_url"* ]] ||
	die "paired kernel release does not link back to $release_url"

expected_download_names=("${artifact_names[@]}" SHA256SUMS)
mapfile -t expected_sorted < <(printf '%s\n' "${expected_download_names[@]}" | sort)

validate_download_root() {
	local candidate_root="$1"
	local index download_name
	local -a downloaded_sorted=()

	[[ -d "$candidate_root" && ! -L "$candidate_root" ]] ||
		die "invalid release-download directory"
	[[ -z "$(find "$candidate_root" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] ||
		die "release download contains a non-file entry"
	mapfile -t downloaded_sorted < <(
		find "$candidate_root" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort
	)
	[[ "${#expected_sorted[@]}" -eq "${#downloaded_sorted[@]}" ]] ||
		die "release download has the wrong asset count"
	for index in "${!expected_sorted[@]}"; do
		[[ "${expected_sorted[$index]}" == "${downloaded_sorted[$index]}" ]] ||
			die "release-download asset membership differs from the staged release"
	done
	for download_name in "${expected_download_names[@]}"; do
		cmp -- "$stage_dir/$download_name" "$candidate_root/$download_name" ||
			die "release download differs from staged asset: $download_name"
	done
	(
		cd "$candidate_root"
		sha256sum --check --strict SHA256SUMS
	)
}

download_root=""
cleanup_download_root() {
	if [[ -n "${download_root:-}" && -d "$download_root" && ! -L "$download_root" ]]; then
		case "$(readlink -f -- "$download_root")" in
		"$repo_dir"/build/.libcamera-release-download.*)
			find "$download_root" -xdev -depth -delete
			;;
		esac
	fi
}
trap cleanup_download_root EXIT

"${publish_command[@]}"

mapfile -t draft_release_ids < <(
	gh api --paginate "repos/$GITHUB_REPO/releases?per_page=100" \
		--jq ".[] | select(.tag_name == \"$TAG\") | .id"
)
[[ "${#draft_release_ids[@]}" -eq 1 ]] ||
	die "could not resolve exactly one draft release for $TAG"
draft_release_id="${draft_release_ids[0]}"
[[ "$draft_release_id" =~ ^[0-9]+$ ]] || die "invalid draft release ID"

draft_state="$(gh api "repos/$GITHUB_REPO/releases/$draft_release_id" --jq .draft)"
draft_prerelease="$(gh api "repos/$GITHUB_REPO/releases/$draft_release_id" --jq .prerelease)"
draft_target="$(gh api "repos/$GITHUB_REPO/releases/$draft_release_id" --jq .target_commitish)"
draft_title="$(gh api "repos/$GITHUB_REPO/releases/$draft_release_id" --jq .name)"
draft_body="$(gh api "repos/$GITHUB_REPO/releases/$draft_release_id" --jq .body)"
[[ "$draft_state" == "true" && "$draft_prerelease" == "true" ]] ||
	die "new release is not the expected prerelease draft"
[[ "$draft_target" == "$support_commit" && "$draft_title" == "$release_title" ]] ||
	die "draft target or title differs from the staged release"
[[ "$draft_body" == "$notes_content" && "$draft_body" == *"$kernel_url"* ]] ||
	die "draft release body differs from the staged reciprocal notes"

declare -A draft_asset_ids=()
declare -A draft_asset_sizes=()
while IFS=$'\t' read -r asset_name asset_id asset_size asset_state; do
	[[ -n "${expected_artifacts[$asset_name]+x}" || "$asset_name" == "SHA256SUMS" ]] ||
		die "draft contains an unexpected asset: $asset_name"
	[[ -z "${draft_asset_ids[$asset_name]+x}" ]] ||
		die "draft contains a duplicate asset: $asset_name"
	[[ "$asset_id" =~ ^[0-9]+$ && "$asset_size" =~ ^[0-9]+$ && "$asset_state" == "uploaded" ]] ||
		die "draft asset metadata is invalid: $asset_name"
	draft_asset_ids["$asset_name"]="$asset_id"
	draft_asset_sizes["$asset_name"]="$asset_size"
done < <(
	gh api --paginate "repos/$GITHUB_REPO/releases/$draft_release_id/assets?per_page=100" \
		--jq '.[] | [.name, (.id | tostring), (.size | tostring), .state] | @tsv'
)
[[ "${#draft_asset_ids[@]}" -eq "${#expected_download_names[@]}" ]] ||
	die "draft has the wrong asset count"

download_root="$(mktemp -d "$build_root/.libcamera-release-download.XXXXXXXX")"
for download_name in "${expected_download_names[@]}"; do
	[[ -n "${draft_asset_ids[$download_name]+x}" ]] ||
		die "draft is missing asset: $download_name"
	[[ "${draft_asset_sizes[$download_name]}" == "$(file_size "$stage_dir/$download_name")" ]] ||
		die "draft asset has the wrong size: $download_name"
	gh api \
		--header 'Accept: application/octet-stream' \
		"repos/$GITHUB_REPO/releases/assets/${draft_asset_ids[$download_name]}" \
		>"$download_root/$download_name"
done
validate_download_root "$download_root"
cleanup_download_root
download_root=""

gh release edit "$TAG" \
	--repo "$GITHUB_REPO" \
	--draft=false \
	--prerelease \
	--latest=false

git fetch --no-tags origin "refs/tags/$TAG:refs/tags/$TAG"
local_tag_commit="$(git rev-parse --verify "refs/tags/$TAG^{commit}")"
remote_tag_output="$(git ls-remote --exit-code --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}")"
remote_tag_commit="$(printf '%s\n' "$remote_tag_output" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
if [[ -z "$remote_tag_commit" ]]; then
	remote_tag_commit="$(printf '%s\n' "$remote_tag_output" | awk 'NR == 1 { print $1 }')"
fi
[[ "$local_tag_commit" == "$support_commit" && "$remote_tag_commit" == "$support_commit" ]] ||
	die "published tag target does not match release support commit"

download_root="$(mktemp -d "$build_root/.libcamera-release-download.XXXXXXXX")"
gh release download "$TAG" --repo "$GITHUB_REPO" --dir "$download_root"
validate_download_root "$download_root"

release_draft="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json isDraft --jq .isDraft)"
release_prerelease="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json isPrerelease --jq .isPrerelease)"
release_target="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json targetCommitish --jq .targetCommitish)"
release_body="$(gh release view "$TAG" --repo "$GITHUB_REPO" --json body --jq .body)"
[[ "$release_draft" == "false" && "$release_prerelease" == "true" ]] ||
	die "published release has an unexpected draft or prerelease state"
[[ "$release_target" == "$support_commit" && "$release_body" == "$notes_content" ]] ||
	die "published release target or body differs from the verified draft"
kernel_release_body="$(
	gh release view "$KERNEL_TAG" --repo "$GITHUB_REPO" --json body --jq .body
)"
[[ "$release_body" == *"$kernel_url"* && "$kernel_release_body" == *"$release_url"* ]] ||
	die "published releases do not contain reciprocal links"

cleanup_download_root
download_root=""
trap - EXIT

printf '\nPublished and fresh-download verified:\n'
printf '  %s\n' "$release_url"
