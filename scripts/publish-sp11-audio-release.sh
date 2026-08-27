#!/usr/bin/env bash
set -euo pipefail
umask 022

DEFAULT_TAG="sp11-audio-v19c"
DEFAULT_KERNEL_TAG="sp11-qcom-x1e-7.2.0-jg-0sp11v12"
DEFAULT_SOURCE_ROOT="/home/leon/Workspace/repos/SP11X1e-audio"

TAG="$DEFAULT_TAG"
KERNEL_TAG="$DEFAULT_KERNEL_TAG"
SOURCE_ROOT="$DEFAULT_SOURCE_ROOT"
MODE=""

TPLG_SOURCE_SHA256="e7bb06a03e7bd9b869825a51775355a6743477d1579d78eb09fad5881cfb20f0"
CARD_UCM_SOURCE_SHA256="225976f925624f156d9fab84e15a5126a60a236783cfcb82d43d2a2aec028d7b"
HIFI_UCM_SOURCE_SHA256="9d36df8570b85f1dcecc385a8f85fa2d1e1058ef8efedee6ae2ce49dc259a06a"
UCM_MATCHER_BASE_SHA256="cb2e60f2b95b5d7841de5f0c914091422b2a3ecff02430ad1cc0c1d468896505"

TPLG_RELEASE_NAME="X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
CARD_UCM_NAME="MICROSOFT-Surface-Pro-11in.conf"
HIFI_UCM_NAME="SP11-HiFi.conf"
UCM_MATCHER_NAME="x1e80100.conf"

usage() {
	cat <<EOF
Usage: $(basename "$0") (--dry-run | --publish) [options]

Stage and optionally publish the Surface Pro 11 FullIO v19c topology and UCM
release. Source payloads are copied from the SP11X1e-audio deployment tree and
must match their pinned SHA-256 identities.

Modes:
  --dry-run             Stage and verify files, then print the gh command only.
  --publish             Stage and verify files, then create the GitHub release.

Options:
  --tag TAG             Audio release tag (default: $DEFAULT_TAG).
  --kernel-tag TAG      Supported kernel release tag
                        (default: $DEFAULT_KERNEL_TAG).
  --source-root DIR     SP11X1e-audio checkout
                        (default: $DEFAULT_SOURCE_ROOT).
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
	if [[ -z "${2:-}" ]]; then
		printf 'ERROR: %s requires a value.\n' "$1" >&2
		usage >&2
		exit 2
	fi
}

require_tool() {
	command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

verify_hash() {
	local path="$1" expected="$2" actual
	[[ -f "$path" ]] || die "missing source file: $path"
	actual="$(sha256sum -- "$path" | awk '{print $1}')"
	if [[ "$actual" != "$expected" ]]; then
		die "SHA-256 mismatch for $path (expected $expected, got $actual)"
	fi
}

print_command() {
	printf '  '
	printf '%q ' "$@"
	printf '\n'
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
		--source-root)
			require_arg "$1" "${2:-}"
			SOURCE_ROOT="$2"
			shift 2
			;;
		-h|--help)
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
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "unsafe release tag: $TAG"
[[ "$KERNEL_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "unsafe kernel tag: $KERNEL_TAG"

require_tool awk
require_tool find
require_tool git
require_tool grep
require_tool install
require_tool sha256sum

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"

[[ -d "$SOURCE_ROOT" ]] || die "SP11X1e-audio source root not found: $SOURCE_ROOT"
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)"

native_dir="$SOURCE_ROOT/deploy/native-audio-v19c"
ucm_source_dir="$SOURCE_ROOT/deploy/ucm2/Qualcomm/x1e80100"
tplg_source="$native_dir/X1E80100-Microsoft-Surface-Pro-11-FullIO-v19c0-tplg.bin"
card_ucm_source="$ucm_source_dir/$CARD_UCM_NAME"
hifi_ucm_source="$ucm_source_dir/$HIFI_UCM_NAME"
ucm_matcher_base="$ucm_source_dir/x1e80100.conf.upstream-1.2.15.3-1ubuntu1.4"
source_sums="$native_dir/SHA256SUMS"

verify_hash "$tplg_source" "$TPLG_SOURCE_SHA256"
verify_hash "$card_ucm_source" "$CARD_UCM_SOURCE_SHA256"
verify_hash "$hifi_ucm_source" "$HIFI_UCM_SOURCE_SHA256"
verify_hash "$ucm_matcher_base" "$UCM_MATCHER_BASE_SHA256"
[[ -f "$source_sums" ]] || die "missing source checksum manifest: $source_sums"
(
	cd "$native_dir"
	sha256sum --check --strict SHA256SUMS >/dev/null
) || die "source checksum manifest validation failed: $source_sums"

release_root="$repo_dir/build/release"
stage_dir="$release_root/$TAG"
[[ ! -L "$repo_dir/build" ]] || die "refusing symlinked build directory"
[[ ! -L "$release_root" ]] || die "refusing symlinked release root"
[[ ! -L "$stage_dir" ]] || die "refusing symlinked staging directory: $stage_dir"
install -d -m 0755 -- "$stage_dir"

allowed_stage_files=(
	"$TPLG_RELEASE_NAME"
	"$CARD_UCM_NAME"
	"$HIFI_UCM_NAME"
	"$UCM_MATCHER_NAME"
	"SHA256SUMS"
	"RELEASE-NOTES.md"
)

while IFS= read -r existing; do
	base="$(basename "$existing")"
	allowed="false"
	for candidate in "${allowed_stage_files[@]}"; do
		if [[ "$base" == "$candidate" ]]; then
			allowed="true"
			break
		fi
	done
	[[ "$allowed" == "true" && -f "$existing" && ! -L "$existing" ]] || \
		die "refusing unknown or unsafe existing staging entry: $existing"
done < <(find "$stage_dir" -mindepth 1 -maxdepth 1 -print | sort)

rm -f -- "${allowed_stage_files[@]/#/$stage_dir/}"

install -m 0644 -- "$tplg_source" "$stage_dir/$TPLG_RELEASE_NAME"
install -m 0644 -- "$card_ucm_source" "$stage_dir/$CARD_UCM_NAME"
install -m 0644 -- "$hifi_ucm_source" "$stage_dir/$HIFI_UCM_NAME"

anchor_count="$(grep -Fc 'Define.DMI_info' "$ucm_matcher_base")"
[[ "$anchor_count" == "1" ]] || die "expected one Define.DMI_info anchor in $ucm_matcher_base"
if grep -Fq 'If.SURFACEPro11' "$ucm_matcher_base"; then
	die "matcher base already contains an SP11 branch: $ucm_matcher_base"
fi

awk '
	{ print }
	/Define.DMI_info/ && !inserted {
		print ""
		print "If.SURFACEPro11in {"
		print "\tCondition {"
		print "\t\tType RegexMatch"
		print "\t\tString \"${var:DMI_info}\""
		print "\t\tRegex \"Microsoft Corporation.*Surface.*Microsoft Surface Pro, 11th Edition\""
		print "\t}"
		print "\tTrue.Include.sp11.File \"/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11in.conf\""
		print "}"
		inserted = 1
	}
	END { if (!inserted) exit 1 }
' "$ucm_matcher_base" >"$stage_dir/$UCM_MATCHER_NAME" || \
	die "failed to generate the SP11 UCM matcher"

grep -Fq 'If.SURFACEPro11in {' "$stage_dir/$UCM_MATCHER_NAME" || \
	die "generated UCM matcher has no SP11 branch"
grep -Fq 'MICROSOFT-Surface-Pro-11in.conf' "$stage_dir/$UCM_MATCHER_NAME" || \
	die "generated UCM matcher does not reference $CARD_UCM_NAME"

release_assets=(
	"$stage_dir/$TPLG_RELEASE_NAME"
	"$stage_dir/$CARD_UCM_NAME"
	"$stage_dir/$HIFI_UCM_NAME"
	"$stage_dir/$UCM_MATCHER_NAME"
	"$stage_dir/SHA256SUMS"
	"$stage_dir/RELEASE-NOTES.md"
)

(
	cd "$stage_dir"
	sha256sum -- \
		"$TPLG_RELEASE_NAME" \
		"$CARD_UCM_NAME" \
		"$HIFI_UCM_NAME" \
		"$UCM_MATCHER_NAME" >SHA256SUMS
)

support_commit="$(git rev-parse HEAD)"
notes_file="$stage_dir/RELEASE-NOTES.md"
cat >"$notes_file" <<EOF
# Surface Pro 11 FullIO v19c audio

AudioReach FullIO v19c topology and matching ALSA UCM for the Microsoft Surface
Pro 11 (X1E80100). This release is paired with the geocausa v12 kernel release
[$KERNEL_TAG](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/$KERNEL_TAG)
(installed ABI: \`7.2.0-jg-0sp11v12-qcom-x1e\`).

## Artifact set

- \`$TPLG_RELEASE_NAME\` — FullIO v19c topology, installed at
  \`/lib/firmware/qcom/x1e80100/$TPLG_RELEASE_NAME\`.
- \`$CARD_UCM_NAME\` — SP11 UCM card profile, installed under
  \`/usr/share/alsa/ucm2/Qualcomm/x1e80100/\`.
- \`$HIFI_UCM_NAME\` — HiFi speaker and microphone verb, installed under
  \`/usr/share/alsa/ucm2/Qualcomm/x1e80100/\`.
- \`$UCM_MATCHER_NAME\` — DMI matcher selecting the SP11 card profile,
  installed at \`/usr/share/alsa/ucm2/conf.d/x1e80100/$UCM_MATCHER_NAME\`.
- \`SHA256SUMS\` — hashes for the four installable artifacts.

## Verify and install

Run from the directory containing the downloaded release assets:

\`\`\`bash
sha256sum -c SHA256SUMS
sudo install -Dm0644 $TPLG_RELEASE_NAME /lib/firmware/qcom/x1e80100/$TPLG_RELEASE_NAME && sudo install -Dm0644 $CARD_UCM_NAME /usr/share/alsa/ucm2/Qualcomm/x1e80100/$CARD_UCM_NAME && sudo install -Dm0644 $HIFI_UCM_NAME /usr/share/alsa/ucm2/Qualcomm/x1e80100/$HIFI_UCM_NAME && sudo install -Dm0644 $UCM_MATCHER_NAME /usr/share/alsa/ucm2/conf.d/x1e80100/$UCM_MATCHER_NAME
\`\`\`

Reboot after installation: q6apm requests the topology while the ASoC component
probes, before PipeWire or WirePlumber applies the UCM \`HiFi\` verb.

## Provenance

- SP11X1e-audio release: \`native-audio-fullio-v19c-20260826\`
- SP11X1e-audio commit: \`7af8f21e9966f6f6adb40c102653b6acb5d81742\`
- OE support commit: \`$support_commit\`
- Topology SHA-256: \`$TPLG_SOURCE_SHA256\`
- Card UCM SHA-256: \`$CARD_UCM_SOURCE_SHA256\`
- HiFi UCM SHA-256: \`$HIFI_UCM_SOURCE_SHA256\`

The topology contains protected vendor-derived bytes. Keep it outside kernel
packages and preserve this dedicated, explicitly reviewed redistribution
boundary.
EOF

(
	cd "$stage_dir"
	sha256sum --check --strict SHA256SUMS
)

publish_command=(
	gh release create "$TAG"
	"${release_assets[@]}"
	--notes-file "$notes_file"
	--target "$support_commit"
	--title "Surface Pro 11 FullIO v19c audio"
)

printf 'Release tag: %s\n' "$TAG"
printf 'Kernel tag:  %s\n' "$KERNEL_TAG"
printf 'Staged at:   %s\n' "${stage_dir#"$repo_dir/"}"
printf 'Source root: %s\n' "$SOURCE_ROOT"
printf '\nPublish command:\n'
print_command "${publish_command[@]}"

if [[ "$MODE" == "dry-run" ]]; then
	printf '\nDry run complete; gh was not called.\n'
	exit 0
fi

require_tool gh
if ! git diff --cached --quiet; then
	die "--publish requires a clean support repository index"
fi

"${publish_command[@]}"
