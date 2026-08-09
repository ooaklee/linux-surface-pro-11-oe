#!/usr/bin/env bash
set -euo pipefail
umask 077

sanitize_git_environment() {
	local variable_name

	unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
	unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
	unset GIT_CONFIG_GLOBAL GIT_DIR GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXEC_PATH
	unset GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_PREFIX
	unset GIT_SHALLOW_FILE GIT_WORK_TREE
	for variable_name in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
		unset "$variable_name"
	done
	export GIT_CONFIG_NOSYSTEM=1
	export GIT_CONFIG_SYSTEM=/dev/null
	export GIT_CONFIG_GLOBAL=/dev/null
	export GIT_ATTR_NOSYSTEM=1
	export GIT_NO_REPLACE_OBJECTS=1
}

sanitize_git_environment

DRY_RUN="false"
INSTALL="false"
WORK_DIR="${HOME:-}/sp11-audio-topology-build"
SOURCE_DIR=""
REPO_URL="https://github.com/linux-msm/audioreach-topology.git"
REPO_REF="d7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677"
INPUT_TEMPLATE="X1E80100-CRD.m4"
OUTPUT_NAME="X1E80100-Microsoft-Surface-Pro-11"
FW_PATH="/lib/firmware/qcom/x1e80100"
UCM_QUALCOMM_DIR="/usr/share/alsa/ucm2/Qualcomm/x1e80100"
UCM_CONFD_DIR="/usr/share/alsa/ucm2/conf.d/x1e80100"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_STAGE=""
INSTALL_TEMP_PATHS=()
CREATED_INSTALL_DIRS=()
TX_SOURCES=()
TX_DESTINATIONS=()
TX_BACKUP_DIRS=()
TX_HAD_OLD=()
TX_INSTALLED=()
TX_INSTALLED_IDENTITIES=()
TX_ACTIVE="false"
PREDICTED_INSTALL_DIRECTORY=""
STAGED_INSTALL_FILE=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build and optionally install the AudioReach topology for the Microsoft Surface Pro 11.

Options:
  --dry-run       Only build the topology, do not install
  --install       Build and install the topology + UCM config to system paths
  --work-dir DIR  Absolute, canonical private working directory (default: ${WORK_DIR})
  -h, --help      Show this help

Requirements:
  - git, m4, alsatplg (from alsa-utils)

Output files (in work dir):
  - build/qcom/x1e80100/${OUTPUT_NAME}-tplg.bin   (topology binary)
  - build/ucm/                                     (UCM config files)

The immutable upstream checkout is managed separately under source/ in the
work directory. Generated files are never used as m4 include inputs.

When installed:
  - ${FW_PATH}/${OUTPUT_NAME}-tplg.bin
  - ${UCM_QUALCOMM_DIR}/MICROSOFT-Surface-Pro-11.conf
  - ${UCM_QUALCOMM_DIR}/Surface11-HiFi.conf
  - ${UCM_CONFD_DIR}/x1e80100.conf  (updated with SP11 regex match)

EOF
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

die() {
	log "ERROR: $*"
	exit 1
}

canonical_git_url() {
	local url="${1%/}"
	printf '%s\n' "${url%.git}"
}

path_has_control_characters() {
	case "$1" in
		*$'\n'*|*$'\r'*) return 0 ;;
	esac
	LC_ALL=C printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

validate_canonical_absolute_path() {
	local path="$1"
	local description="$2"

	case "$path" in
		/*) ;;
		*) die "$description must be an absolute path: $path" ;;
	esac
	case "$path" in
		/|*/|*//* ) die "$description must use canonical path spelling: $path" ;;
	esac
	case "/${path#/}/" in
		*/./*|*/../*) die "$description must not contain dot or dot-dot components: $path" ;;
	esac
	if path_has_control_characters "$path"; then
		die "$description must not contain control characters"
	fi
}

validate_work_path() {
	local parent physical_parent

	validate_canonical_absolute_path "$WORK_DIR" "work directory"
	case "$WORK_DIR" in
		/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*)
			die "work directory must not be a protected system path: $WORK_DIR"
			;;
	esac
	if [ "$WORK_DIR" = "$repo_dir" ]; then
		die "work directory must not be the repository root: $WORK_DIR"
	fi
	case "$repo_dir/" in
		"$WORK_DIR/"*) die "work directory must not contain the repository: $WORK_DIR" ;;
	esac

	parent="${WORK_DIR%/*}"
	[ -n "$parent" ] || parent="/"
	[ ! -L "$parent" ] || die "work-directory parent must not be a symlink: $parent"
	[ -d "$parent" ] || die "work-directory parent must already be a directory: $parent"
	physical_parent="$(cd "$parent" && pwd -P)"
	[ "$physical_parent" = "$parent" ] ||
		die "work-directory parent must be a canonical physical path: $parent"

	if [ -L "$WORK_DIR" ]; then
		die "work directory must not be a symlink: $WORK_DIR"
	elif [ -e "$WORK_DIR" ]; then
		[ -d "$WORK_DIR" ] || die "work path exists but is not a directory: $WORK_DIR"
		[ "$(cd "$WORK_DIR" && pwd -P)" = "$WORK_DIR" ] ||
			die "work directory must be a canonical physical path: $WORK_DIR"
	else
		mkdir "$WORK_DIR" || die "cannot create work directory: $WORK_DIR"
		chmod 0700 "$WORK_DIR" || die "cannot secure work directory: $WORK_DIR"
	fi
}

validate_managed_directory_if_present() {
	local path="$1"
	local description="$2"

	case "$path" in
		"$WORK_DIR"/*) ;;
		*) die "$description escapes the managed work directory: $path" ;;
	esac
	if [ -L "$path" ]; then
		die "$description must not be a symlink: $path"
	elif [ -e "$path" ]; then
		[ -d "$path" ] || die "$description is not a directory: $path"
		[ "$(cd "$path" && pwd -P)" = "$path" ] ||
			die "$description must be a physical child of the work directory: $path"
	fi
}

validate_source_git_directory() {
	local git_metadata="${SOURCE_DIR}/.git"

	[ ! -L "$git_metadata" ] ||
		die "source Git metadata must not be a symlink: $git_metadata"
	[ -d "$git_metadata" ] ||
		die "source Git metadata must be a directory: $git_metadata"
	[ "$(cd "$git_metadata" && pwd -P)" = "$git_metadata" ] ||
		die "source Git metadata escapes the managed checkout: $git_metadata"
}

ensure_managed_directory() {
	local path="$1"
	local description="$2"
	local parent

	validate_managed_directory_if_present "$path" "$description"
	if [ ! -e "$path" ]; then
		parent="${path%/*}"
		[ -d "$parent" ] && [ ! -L "$parent" ] ||
			die "cannot create $description below an unsafe parent: $parent"
		[ "$(cd "$parent" && pwd -P)" = "$parent" ] ||
			die "cannot create $description below a non-physical parent: $parent"
		mkdir "$path" || die "cannot create $description: $path"
		chmod 0700 "$path" || die "cannot secure $description: $path"
	fi
	validate_managed_directory_if_present "$path" "$description"
}

preflight_leaf() {
	local path="$1"
	local description="$2"

	if [ -L "$path" ]; then
		die "$description must not be a symlink: $path"
	elif [ -e "$path" ] && [ ! -f "$path" ]; then
		die "$description must be absent or a regular file: $path"
	fi
}

require_regular_file() {
	local path="$1"
	local description="$2"

	[ ! -L "$path" ] && [ -f "$path" ] && [ -s "$path" ] ||
		die "$description must be a nonempty regular file: $path"
}

publication_file_identity() {
	local path="$1"
	local metadata checksum checksum_output

	[ -f "$path" ] && [ ! -L "$path" ] || return 1
	if metadata="$(stat -c '%d:%i:%a:%u:%g:%s' -- "$path" 2>/dev/null)"; then
		:
	elif metadata="$(stat -f '%d:%i:%Lp:%u:%g:%z' "$path" 2>/dev/null)"; then
		:
	else
		return 1
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		checksum_output="$(sha256sum < "$path")" || return 1
	elif command -v shasum >/dev/null 2>&1; then
		checksum_output="$(shasum -a 256 < "$path")" || return 1
	else
		return 1
	fi
	checksum="${checksum_output%% *}"
	[ -n "$checksum" ] || return 1
	printf '%s:%s\n' "$metadata" "$checksum"
}

validate_build_layout() {
	local build_dir="${WORK_DIR}/build"
	local qcom_dir="${build_dir}/qcom"
	local topology_dir="${qcom_dir}/x1e80100"
	local ucm_dir="${build_dir}/ucm"

	validate_managed_directory_if_present "$SOURCE_DIR" "source directory"
	validate_managed_directory_if_present "$build_dir" "build directory"
	validate_managed_directory_if_present "$qcom_dir" "QCOM output directory"
	validate_managed_directory_if_present "$topology_dir" "topology output directory"
	validate_managed_directory_if_present "$ucm_dir" "UCM output directory"

	preflight_leaf "${topology_dir}/${OUTPUT_NAME}.conf" "topology configuration output"
	preflight_leaf "${topology_dir}/${OUTPUT_NAME}-tplg.bin" "topology binary output"
	preflight_leaf "${ucm_dir}/MICROSOFT-Surface-Pro-11.conf" "UCM card output"
	preflight_leaf "${ucm_dir}/Surface11-HiFi.conf" "UCM HiFi output"
	preflight_leaf "${ucm_dir}/x1e80100.conf" "UCM machine output"
}

create_build_directories() {
	ensure_managed_directory "${WORK_DIR}/build" "build directory"
	ensure_managed_directory "${WORK_DIR}/build/qcom" "QCOM output directory"
	ensure_managed_directory "${WORK_DIR}/build/qcom/x1e80100" "topology output directory"
	ensure_managed_directory "${WORK_DIR}/build/ucm" "UCM output directory"
}

check_deps() {
	local deps=(git m4 alsatplg stat)
	local missing=()
	local d
	for d in "${deps[@]}"; do
		if ! command -v "$d" >/dev/null 2>&1; then
			missing+=("$d")
		fi
	done
	if ! command -v sha256sum >/dev/null 2>&1 &&
	   ! command -v shasum >/dev/null 2>&1; then
		missing+=("sha256sum-or-shasum")
	fi
	if [ ${#missing[@]} -gt 0 ]; then
		log "ERROR: Missing dependencies: ${missing[*]}"
		log "Install with: sudo apt install git m4 alsa-utils"
		exit 1
	fi
}

verify_source_checkout() {
	local actual_head actual_origin expected_origin status source_build source_template
	local git_directory source_toplevel

	validate_managed_directory_if_present "$SOURCE_DIR" "source directory"
	validate_source_git_directory
	[ "$(git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] ||
		die "source directory is not an audioreach-topology Git checkout: $SOURCE_DIR"
	source_toplevel="$(git -C "$SOURCE_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
		die "cannot resolve the source checkout top level: $SOURCE_DIR"
	[ "$source_toplevel" = "$SOURCE_DIR" ] ||
		die "source checkout top level escapes the managed source directory: $source_toplevel"
	git_directory="$(git -C "$SOURCE_DIR" rev-parse --absolute-git-dir 2>/dev/null)" ||
		die "cannot resolve source Git metadata: $SOURCE_DIR"
	[ "$git_directory" = "${SOURCE_DIR}/.git" ] ||
		die "source Git metadata escapes the managed source directory: $git_directory"

	actual_origin="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null)" ||
		die "cannot read the origin URL from $SOURCE_DIR"
	expected_origin="$(canonical_git_url "$REPO_URL")"
	if [ "$(canonical_git_url "$actual_origin")" != "$expected_origin" ]; then
		die "source origin mismatch in $SOURCE_DIR (expected $REPO_URL, found $actual_origin)"
	fi

	actual_head="$(git -C "$SOURCE_DIR" rev-parse --verify HEAD 2>/dev/null)" ||
		die "cannot resolve HEAD in $SOURCE_DIR"
	if [ "$actual_head" != "$REPO_REF" ]; then
		die "source revision mismatch in $SOURCE_DIR (expected $REPO_REF, found $actual_head)"
	fi

	status="$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all --ignored=matching)" ||
		die "cannot inspect source changes in $SOURCE_DIR"
	if [ -n "$status" ]; then
		die "source checkout contains modified, untracked, or ignored files in $SOURCE_DIR; use a clean checkout at $REPO_REF"
	fi

	source_template="${SOURCE_DIR}/${INPUT_TEMPLATE}"
	require_regular_file "$source_template" "pinned topology template"
	source_build="${SOURCE_DIR}/build"
	if [ -L "$source_build" ]; then
		die "pinned source build include directory must not be a symlink: $source_build"
	elif [ -e "$source_build" ]; then
		[ -d "$source_build" ] ||
			die "pinned source build include path is not a directory: $source_build"
		[ "$(cd "$source_build" && pwd -P)" = "$source_build" ] ||
			die "pinned source build include directory escapes the checkout: $source_build"
	fi
}

prepare_source_checkout() {
	if [ ! -e "$SOURCE_DIR" ] && [ ! -L "$SOURCE_DIR" ]; then
		log "Cloning audioreach-topology repo at immutable revision $REPO_REF..."
		validate_managed_directory_if_present "$SOURCE_DIR" "source directory"
		git clone --no-checkout "$REPO_URL" "$SOURCE_DIR"
		validate_managed_directory_if_present "$SOURCE_DIR" "source directory"
		validate_source_git_directory
		git -C "$SOURCE_DIR" checkout --detach "$REPO_REF"
	elif [ -L "$SOURCE_DIR" ]; then
		die "source directory must not be a symlink: $SOURCE_DIR"
	else
		validate_source_git_directory
	fi

	verify_source_checkout
}

create_build_stage() {
	BUILD_STAGE="$(mktemp -d "${WORK_DIR}/.sp11-audio-output.XXXXXX")" ||
		die "cannot create private audio output stage below $WORK_DIR"
	case "$BUILD_STAGE" in
		"$WORK_DIR"/.sp11-audio-output.*) ;;
		*) die "temporary output stage escaped the work directory: $BUILD_STAGE" ;;
	esac
	[ ! -L "$BUILD_STAGE" ] && [ -d "$BUILD_STAGE" ] ||
		die "temporary output stage is not a private directory: $BUILD_STAGE"
	chmod 0700 "$BUILD_STAGE" || die "cannot secure temporary output stage: $BUILD_STAGE"
	mkdir "${BUILD_STAGE}/qcom" "${BUILD_STAGE}/ucm"
	chmod 0700 "${BUILD_STAGE}/qcom" "${BUILD_STAGE}/ucm"
}

build_topology_in_stage() {
	local src="${SOURCE_DIR}/${INPUT_TEMPLATE}"
	local conf="${BUILD_STAGE}/qcom/${OUTPUT_NAME}.conf"
	local tplg="${BUILD_STAGE}/qcom/${OUTPUT_NAME}-tplg.bin"

	log "Running m4 to expand topology template..."
	m4 -I "${SOURCE_DIR}/build" -I "$SOURCE_DIR" "$src" > "$conf"

	log "Compiling topology with alsatplg..."
	alsatplg -c "$conf" -o "$tplg"
}

prepare_ucm_files_in_stage() {
	local ucm_dir="${BUILD_STAGE}/ucm"
	local repo_audio="${repo_dir}/payload/audio"
	local repo_file
	local repo_files=(
		"${repo_audio}/MICROSOFT-Surface-Pro-11.conf"
		"${repo_audio}/Surface11-HiFi.conf"
		"${repo_audio}/x1e80100.conf"
	)
	local repo_any="false"
	local repo_all="true"

	if [ -L "$repo_audio" ]; then
		die "repository UCM input directory must not be a symlink: $repo_audio"
	elif [ -e "$repo_audio" ]; then
		[ -d "$repo_audio" ] || die "repository UCM input path is not a directory: $repo_audio"
		[ "$(cd "$repo_audio" && pwd -P)" = "$repo_audio" ] ||
			die "repository UCM input directory escapes the checkout: $repo_audio"
	fi

	for repo_file in "${repo_files[@]}"; do
		if [ -e "$repo_file" ] || [ -L "$repo_file" ]; then
			repo_any="true"
		fi
		if [ -L "$repo_file" ] || [ ! -f "$repo_file" ]; then
			repo_all="false"
		fi
	done

	if [ "$repo_all" = "true" ]; then
		log "Using UCM files from repo payload/audio/"
		for repo_file in "${repo_files[@]}"; do
			require_regular_file "$repo_file" "repository UCM input"
		done
		cp "${repo_files[0]}" "${ucm_dir}/MICROSOFT-Surface-Pro-11.conf"
		cp "${repo_files[1]}" "${ucm_dir}/Surface11-HiFi.conf"
		cp "${repo_files[2]}" "${ucm_dir}/x1e80100.conf"
		return
	elif [ "$repo_any" = "true" ]; then
		die "payload/audio must contain all three regular, non-symlink UCM inputs"
	fi

	log "Preparing self-contained UCM profile files..."

	cat > "${ucm_dir}/MICROSOFT-Surface-Pro-11.conf" <<'UCMEOF'
Syntax 4

SectionUseCase."HiFi" {
	File "/Qualcomm/x1e80100/Surface11-HiFi.conf"
	Comment "HiFi quality Music."
}

Include.card-init.File "/lib/card-init.conf"
Include.ctl-remap.File "/lib/ctl-remap.conf"
Include.wsa-init.File "/codecs/wsa884x/two-speakers/init.conf"
Include.wsam-init.File "/codecs/qcom-lpass/wsa-macro/init.conf"
UCMEOF

	cat > "${ucm_dir}/Surface11-HiFi.conf" <<'HIFIEOF'
SectionVerb {
	EnableSequence [
		cset "name='WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' 1"
		cset "name='MultiMedia4 Mixer VA_CODEC_DMA_TX_0' 1"
	]

	Include.wsae.File "/codecs/wsa884x/two-speakers/DefaultEnableSeq.conf"
	Include.wsm1e.File "/codecs/qcom-lpass/wsa-macro/Wsa1SpeakerEnableSeq.conf"

	Value {
		TQ "HiFi"
	}
}

SectionDevice."Speaker" {
	Comment "Speaker playback"

	Include.wsmspk1e.File "/codecs/qcom-lpass/wsa-macro/Wsa1SpeakerEnableSeq.conf"
	Include.wsmspk1d.File "/codecs/qcom-lpass/wsa-macro/Wsa1SpeakerDisableSeq.conf"
	Include.wsaspk.File "/codecs/wsa884x/two-speakers/SpeakerSeq.conf"

	Value {
		PlaybackChannels 4
		PlaybackPriority 100
		PlaybackPCM "hw:${CardId},1"
		PlaybackMixer "default:${CardId}"
		PlaybackMixerElem "Speakers"
	}
}

SectionDevice."Mic" {
	Comment "Internal microphones"

	Include.vadm0d.File "/codecs/qcom-lpass/va-macro/DMIC0DisableSeq.conf"
	Include.vadm1d.File "/codecs/qcom-lpass/va-macro/DMIC1DisableSeq.conf"

	# The shared enable sequences select 100 (+16 dB), which clips the Surface
	# microphones. Keep their routing but use unity gain (84 = 0 dB).
	EnableSequence [
		cset "name='VA DEC0 MUX' VA_DMIC"
		cset "name='VA DMIC MUX0' DMIC0"
		cset "name='VA_AIF1_CAP Mixer DEC0' 1"
		cset "name='VA_DEC0 Volume' 84"
		cset "name='VA DEC1 MUX' VA_DMIC"
		cset "name='VA DMIC MUX1' DMIC1"
		cset "name='VA_AIF1_CAP Mixer DEC1' 1"
		cset "name='VA_DEC1 Volume' 84"
	]

	Value {
		CaptureChannels 2
		CapturePriority 100
		CapturePCM "hw:${CardId},3"
	}
}
HIFIEOF

	cat > "${ucm_dir}/x1e80100.conf" <<'CONFEOF'
Syntax 4

Define.DMI_info "${sys:devices/virtual/dmi/id/board_vendor}-${sys:devices/virtual/dmi/id/product_family}-${sys:devices/virtual/dmi/id/board_name}"

If.SURFACEPro11 {
	Condition {
		Type RegexMatch
		String "${var:DMI_info}"
		Regex "Microsoft Corporation.*Surface.*Microsoft Surface Pro, 11th Edition"
	}
	True.Include.11.File "/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11.conf"
}

Include.x1e80100-main.File "/Qualcomm/x1e80100/x1e80100.conf"
CONFEOF
}

clear_transaction_state() {
	TX_SOURCES=()
	TX_DESTINATIONS=()
	TX_BACKUP_DIRS=()
	TX_HAD_OLD=()
	TX_INSTALLED=()
	TX_INSTALLED_IDENTITIES=()
	TX_ACTIVE="false"
}

remove_transaction_backups() {
	local removal_mode="${1:-all}"
	local backup_dir i
	for ((i=0; i<${#TX_BACKUP_DIRS[@]}; i++)); do
		backup_dir="${TX_BACKUP_DIRS[$i]}"
		case "$backup_dir" in
			*/.sp11-audio-backup.*)
				if [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ]; then
					if [ "$removal_mode" = "all" ] ||
					   { [ ! -e "${backup_dir}/original" ] && [ ! -L "${backup_dir}/original" ]; }; then
						rm -rf -- "$backup_dir"
					else
						log "WARNING: preserving recoverable audio backup after an occupied-destination race: ${backup_dir}/original"
					fi
				fi
				;;
		esac
	done
}

rollback_transaction() {
	local i destination backup_dir expected_identity current_identity

	for ((i=${#TX_INSTALLED[@]}-1; i>=0; i--)); do
		destination="${TX_INSTALLED[$i]}"
		expected_identity="${TX_INSTALLED_IDENTITIES[$i]:-}"
		if [ -f "$destination" ] && [ ! -L "$destination" ]; then
			current_identity="$(publication_file_identity "$destination" 2>/dev/null || true)"
			if [ -z "$expected_identity" ] || [ "$current_identity" != "$expected_identity" ]; then
				log "WARNING: failed audio destination was replaced during rollback; leaving it untouched: $destination"
			elif ! rm -f -- "$destination"; then
				log "WARNING: cannot remove a failed audio publication; recoverable backups will be preserved: $destination"
			fi
		elif [ -e "$destination" ] || [ -L "$destination" ]; then
			log "WARNING: failed audio destination was replaced during rollback; leaving it untouched: $destination"
		fi
	done
	for ((i=${#TX_DESTINATIONS[@]}-1; i>=0; i--)); do
		if [ "${TX_HAD_OLD[$i]:-false}" = "true" ]; then
			destination="${TX_DESTINATIONS[$i]}"
			backup_dir="${TX_BACKUP_DIRS[$i]}"
			if [ -f "${backup_dir}/original" ] && [ ! -L "${backup_dir}/original" ]; then
				if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
					if ! mv "${backup_dir}/original" "$destination"; then
						log "WARNING: cannot restore audio destination; preserving recoverable backup: ${backup_dir}/original"
					fi
				else
					log "WARNING: audio destination is occupied during rollback; preserving recoverable backup: ${backup_dir}/original"
				fi
			fi
		fi
	done
	remove_transaction_backups empty
	clear_transaction_state
}

publish_files_transaction() {
	local source destination parent backup_dir i source_identity destination_identity

	[ $(( $# % 2 )) -eq 0 ] || die "internal error: unpaired publication paths"
	clear_transaction_state
	while [ $# -gt 0 ]; do
		source="$1"
		destination="$2"
		shift 2
		require_regular_file "$source" "staged audio output"
		preflight_leaf "$destination" "audio destination"
		parent="${destination%/*}"
		[ -d "$parent" ] && [ ! -L "$parent" ] ||
			die "audio destination parent is unsafe: $parent"
		[ "$(cd "$parent" && pwd -P)" = "$parent" ] ||
			die "audio destination parent is not a physical path: $parent"
		backup_dir="$(mktemp -d "${parent}/.sp11-audio-backup.XXXXXX")" ||
			die "cannot reserve an audio destination backup in $parent"
		chmod 0700 "$backup_dir" || die "cannot secure audio destination backup: $backup_dir"
		TX_SOURCES+=("$source")
		TX_DESTINATIONS+=("$destination")
		TX_BACKUP_DIRS+=("$backup_dir")
		TX_HAD_OLD+=("false")
	done

	TX_ACTIVE="true"
	for ((i=0; i<${#TX_DESTINATIONS[@]}; i++)); do
		destination="${TX_DESTINATIONS[$i]}"
		backup_dir="${TX_BACKUP_DIRS[$i]}"
		preflight_leaf "$destination" "audio destination"
		if [ -f "$destination" ]; then
			if ! mv "$destination" "${backup_dir}/original"; then
				rollback_transaction
				die "cannot stage existing audio destination for replacement: $destination"
			fi
			TX_HAD_OLD[$i]="true"
		fi
	done

	for ((i=0; i<${#TX_SOURCES[@]}; i++)); do
		source="${TX_SOURCES[$i]}"
		destination="${TX_DESTINATIONS[$i]}"
		require_regular_file "$source" "staged audio output"
		source_identity="$(publication_file_identity "$source")" ||
			die "cannot identify staged audio output before publication: $source"
		if [ -e "$destination" ] || [ -L "$destination" ] || ! ln "$source" "$destination"; then
			rollback_transaction
			die "cannot publish audio output atomically: $destination"
		fi
		TX_INSTALLED+=("$destination")
		TX_INSTALLED_IDENTITIES+=("$source_identity")
		destination_identity="$(publication_file_identity "$destination" 2>/dev/null || true)"
		if [ "$destination_identity" != "$source_identity" ]; then
			rollback_transaction
			die "published audio output changed before it could be verified: $destination"
		fi
		if ! rm -f -- "$source"; then
			rollback_transaction
			die "cannot retire staged audio output after publication: $source"
		fi
	done

	remove_transaction_backups all
	clear_transaction_state
}

validate_staged_build_outputs() {
	local staged_file
	local staged_files=(
		"${BUILD_STAGE}/qcom/${OUTPUT_NAME}.conf"
		"${BUILD_STAGE}/qcom/${OUTPUT_NAME}-tplg.bin"
		"${BUILD_STAGE}/ucm/MICROSOFT-Surface-Pro-11.conf"
		"${BUILD_STAGE}/ucm/Surface11-HiFi.conf"
		"${BUILD_STAGE}/ucm/x1e80100.conf"
	)

	for staged_file in "${staged_files[@]}"; do
		require_regular_file "$staged_file" "generated audio output"
		chmod 0644 "$staged_file" || die "cannot set generated output mode: $staged_file"
	done
}

publish_build_outputs() {
	validate_build_layout
	create_build_directories
	publish_files_transaction \
		"${BUILD_STAGE}/qcom/${OUTPUT_NAME}.conf" \
		"${WORK_DIR}/build/qcom/x1e80100/${OUTPUT_NAME}.conf" \
		"${BUILD_STAGE}/qcom/${OUTPUT_NAME}-tplg.bin" \
		"${WORK_DIR}/build/qcom/x1e80100/${OUTPUT_NAME}-tplg.bin" \
		"${BUILD_STAGE}/ucm/MICROSOFT-Surface-Pro-11.conf" \
		"${WORK_DIR}/build/ucm/MICROSOFT-Surface-Pro-11.conf" \
		"${BUILD_STAGE}/ucm/Surface11-HiFi.conf" \
		"${WORK_DIR}/build/ucm/Surface11-HiFi.conf" \
		"${BUILD_STAGE}/ucm/x1e80100.conf" \
		"${WORK_DIR}/build/ucm/x1e80100.conf"
	log "Topology built: ${WORK_DIR}/build/qcom/x1e80100/${OUTPUT_NAME}-tplg.bin ($(du -h "${WORK_DIR}/build/qcom/x1e80100/${OUTPUT_NAME}-tplg.bin" | cut -f1))"
}

predict_physical_install_directory() {
	local logical="$1"
	shift
	local cursor="$logical"
	local suffix=""
	local component physical candidate
	PREDICTED_INSTALL_DIRECTORY=""

	validate_canonical_absolute_path "$logical" "installation directory"
	while [ ! -e "$cursor" ] && [ ! -L "$cursor" ]; do
		component="${cursor##*/}"
		suffix="/${component}${suffix}"
		cursor="${cursor%/*}"
		[ -n "$cursor" ] || cursor="/"
	done
	[ -d "$cursor" ] || die "installation ancestor is not a directory: $cursor"
	physical="$(cd "$cursor" && pwd -P)"
	candidate="${physical%/}${suffix}"
	for physical in "$@"; do
		if [ "$candidate" = "$physical" ]; then
			PREDICTED_INSTALL_DIRECTORY="$candidate"
			return
		fi
	done
	die "installation directory resolves outside its allowed physical path: $logical -> $candidate"
}

validate_physical_directory_chain() {
	local path="$1"
	local remaining="${path#/}"
	local current=""
	local component

	validate_canonical_absolute_path "$path" "physical installation directory"
	while [ -n "$remaining" ]; do
		case "$remaining" in
			*/*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
			*) component="$remaining"; remaining="" ;;
		esac
		current="${current}/${component}"
		if [ -L "$current" ]; then
			die "physical installation path must not contain symlinks: $current"
		elif [ -e "$current" ] && [ ! -d "$current" ]; then
			die "physical installation path contains a non-directory: $current"
		fi
	done
}

ensure_physical_install_directory() {
	local path="$1"
	local remaining="${path#/}"
	local current=""
	local component

	validate_physical_directory_chain "$path"
	while [ -n "$remaining" ]; do
		case "$remaining" in
			*/*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
			*) component="$remaining"; remaining="" ;;
		esac
		current="${current}/${component}"
		if [ ! -e "$current" ]; then
			mkdir "$current" || die "cannot create installation directory: $current"
			CREATED_INSTALL_DIRS+=("$current")
			chmod 0755 "$current" || die "cannot set installation directory mode: $current"
		fi
		[ -d "$current" ] && [ ! -L "$current" ] ||
			die "installation directory changed during creation: $current"
	done
}

stage_install_file() {
	local source="$1"
	local destination_dir="$2"
	local temporary
	STAGED_INSTALL_FILE=""

	require_regular_file "$source" "install source"
	temporary="$(mktemp "${destination_dir}/.sp11-audio-install.XXXXXX")" ||
		die "cannot stage audio installation below $destination_dir"
	INSTALL_TEMP_PATHS+=("$temporary")
	cp "$source" "$temporary" || die "cannot copy audio install source into private stage: $source"
	chmod 0644 "$temporary" || die "cannot set staged install mode: $temporary"
	require_regular_file "$temporary" "staged install output"
	STAGED_INSTALL_FILE="$temporary"
}

install_files() {
	local tplg="${WORK_DIR}/build/qcom/x1e80100/${OUTPUT_NAME}-tplg.bin"
	local ucm_dir="${WORK_DIR}/build/ucm"
	local fw_alt="$FW_PATH"
	local fw_physical ucm_qualcomm_physical ucm_confd_physical
	local fw_destination card_destination hifi_destination machine_destination
	local fw_stage card_stage hifi_stage machine_stage

	if [ "$(id -u)" -ne 0 ]; then
		die "--install must be run as root (sudo)"
	fi

	case "$FW_PATH" in
		/lib/*) fw_alt="/usr/lib/${FW_PATH#/lib/}" ;;
	esac
	predict_physical_install_directory "$FW_PATH" "$FW_PATH" "$fw_alt"
	fw_physical="$PREDICTED_INSTALL_DIRECTORY"
	predict_physical_install_directory "$UCM_QUALCOMM_DIR" "$UCM_QUALCOMM_DIR"
	ucm_qualcomm_physical="$PREDICTED_INSTALL_DIRECTORY"
	predict_physical_install_directory "$UCM_CONFD_DIR" "$UCM_CONFD_DIR"
	ucm_confd_physical="$PREDICTED_INSTALL_DIRECTORY"
	validate_physical_directory_chain "$fw_physical"
	validate_physical_directory_chain "$ucm_qualcomm_physical"
	validate_physical_directory_chain "$ucm_confd_physical"

	fw_destination="${fw_physical}/${OUTPUT_NAME}-tplg.bin"
	card_destination="${ucm_qualcomm_physical}/MICROSOFT-Surface-Pro-11.conf"
	hifi_destination="${ucm_qualcomm_physical}/Surface11-HiFi.conf"
	machine_destination="${ucm_confd_physical}/x1e80100.conf"

	require_regular_file "$tplg" "built topology"
	require_regular_file "${ucm_dir}/MICROSOFT-Surface-Pro-11.conf" "built UCM card profile"
	require_regular_file "${ucm_dir}/Surface11-HiFi.conf" "built UCM HiFi profile"
	require_regular_file "${ucm_dir}/x1e80100.conf" "built UCM machine profile"
	preflight_leaf "$fw_destination" "installed topology destination"
	preflight_leaf "$card_destination" "installed UCM card destination"
	preflight_leaf "$hifi_destination" "installed UCM HiFi destination"
	preflight_leaf "$machine_destination" "installed UCM machine destination"

	ensure_physical_install_directory "$fw_physical"
	ensure_physical_install_directory "$ucm_qualcomm_physical"
	ensure_physical_install_directory "$ucm_confd_physical"

	stage_install_file "$tplg" "$fw_physical"
	fw_stage="$STAGED_INSTALL_FILE"
	stage_install_file "${ucm_dir}/MICROSOFT-Surface-Pro-11.conf" "$ucm_qualcomm_physical"
	card_stage="$STAGED_INSTALL_FILE"
	stage_install_file "${ucm_dir}/Surface11-HiFi.conf" "$ucm_qualcomm_physical"
	hifi_stage="$STAGED_INSTALL_FILE"
	stage_install_file "${ucm_dir}/x1e80100.conf" "$ucm_confd_physical"
	machine_stage="$STAGED_INSTALL_FILE"

	log "Installing topology and UCM files as one preflighted transaction..."
	publish_files_transaction \
		"$fw_stage" "$fw_destination" \
		"$card_stage" "$card_destination" \
		"$hifi_stage" "$hifi_destination" \
		"$machine_stage" "$machine_destination"
	INSTALL_TEMP_PATHS=()
	CREATED_INSTALL_DIRS=()

	log "Install complete. Reboot for topology to take effect."
	log "After reboot, restart PipeWire with: systemctl --user restart pipewire wireplumber"
	log ""
	log "SAFETY: Keep volume at 10% for first speaker test."
	log "  speaker-test -D hw:0,1 -c 4 -t sine -f 440 -l 3"
}

cleanup() {
	local path i

	if [ "$TX_ACTIVE" = "true" ]; then
		rollback_transaction || true
	else
		remove_transaction_backups empty || true
		clear_transaction_state
	fi
	for ((i=0; i<${#INSTALL_TEMP_PATHS[@]}; i++)); do
		path="${INSTALL_TEMP_PATHS[$i]}"
		case "$path" in
			*/.sp11-audio-install.*) rm -f -- "$path" 2>/dev/null || true ;;
		esac
	done
	for ((i=${#CREATED_INSTALL_DIRS[@]}-1; i>=0; i--)); do
		rmdir "${CREATED_INSTALL_DIRS[$i]}" 2>/dev/null || true
	done
	if [ -n "$BUILD_STAGE" ]; then
		case "$BUILD_STAGE" in
			"$WORK_DIR"/.sp11-audio-output.*)
				if [ -d "$BUILD_STAGE" ] && [ ! -L "$BUILD_STAGE" ]; then
					rm -rf -- "$BUILD_STAGE"
				fi
				;;
		esac
	fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN="true"; shift ;;
		--install) INSTALL="true"; shift ;;
		--work-dir)
			[ $# -ge 2 ] || die "--work-dir requires an argument"
			WORK_DIR="$2"
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		*) log "Unknown option: $1"; usage; exit 1 ;;
	esac
done

if [ "$DRY_RUN" = "true" ] && [ "$INSTALL" = "true" ]; then
	die "--dry-run and --install cannot be used together"
fi

validate_work_path
SOURCE_DIR="${WORK_DIR}/source"
validate_build_layout
check_deps
prepare_source_checkout
validate_build_layout
create_build_stage
build_topology_in_stage
prepare_ucm_files_in_stage
validate_staged_build_outputs
publish_build_outputs

if [ "$INSTALL" = "true" ]; then
	install_files
else
	log "Build complete (dry-run). To install, re-run with: sudo $0 --install"
	log ""
	log "Manual install:"
	log "  sudo cp ${WORK_DIR}/build/qcom/x1e80100/${OUTPUT_NAME}-tplg.bin ${FW_PATH}/"
	log "  sudo cp ${WORK_DIR}/build/ucm/MICROSOFT-Surface-Pro-11.conf ${UCM_QUALCOMM_DIR}/"
	log "  sudo cp ${WORK_DIR}/build/ucm/Surface11-HiFi.conf ${UCM_QUALCOMM_DIR}/"
	log "  sudo cp ${WORK_DIR}/build/ucm/x1e80100.conf ${UCM_CONFD_DIR}/x1e80100.conf"
fi
