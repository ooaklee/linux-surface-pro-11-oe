#!/usr/bin/env bash
set -euo pipefail

DRY_RUN="false"
INSTALL="false"
WORK_DIR="${HOME}/sp11-audio-topology-build"
SOURCE_DIR=""
REPO_URL="https://github.com/linux-msm/audioreach-topology.git"
REPO_REF="d7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677"
INPUT_TEMPLATE="X1E80100-CRD.m4"
OUTPUT_NAME="X1E80100-Microsoft-Surface-Pro-11"
FW_PATH="/lib/firmware/qcom/x1e80100"
UCM_QUALCOMM_DIR="/usr/share/alsa/ucm2/Qualcomm/x1e80100"
UCM_CONFD_DIR="/usr/share/alsa/ucm2/conf.d/x1e80100"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build and optionally install the AudioReach topology for the Microsoft Surface Pro 11.

Options:
  --dry-run       Only build the topology, do not install
  --install       Build and install the topology + UCM config to system paths
  --work-dir DIR  Working directory (default: ${WORK_DIR})
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

check_deps() {
	local deps=(git m4 alsatplg)
	local missing=()
	for d in "${deps[@]}"; do
		if ! command -v "$d" >/dev/null 2>&1; then
			missing+=("$d")
		fi
	done
	if [ ${#missing[@]} -gt 0 ]; then
		log "ERROR: Missing dependencies: ${missing[*]}"
		log "Install with: sudo apt install git m4 alsa-utils"
		exit 1
	fi
}

verify_source_checkout() {
	local actual_head actual_origin expected_origin status

	[ "$(git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] ||
		die "source directory is not an audioreach-topology Git checkout: $SOURCE_DIR"

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
}

prepare_source_checkout() {
	if [ ! -e "$SOURCE_DIR" ]; then
		log "Cloning audioreach-topology repo at immutable revision $REPO_REF..."
		mkdir -p "$WORK_DIR"
		git clone --no-checkout "$REPO_URL" "$SOURCE_DIR"
		git -C "$SOURCE_DIR" checkout --detach "$REPO_REF"
	elif [ "$(git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
		die "source directory already exists but is not a Git checkout: $SOURCE_DIR"
	fi

	verify_source_checkout
	[ -f "${SOURCE_DIR}/${INPUT_TEMPLATE}" ] ||
		die "pinned source checkout does not contain ${INPUT_TEMPLATE}: $SOURCE_DIR"
}

build_topology() {
	local src="${SOURCE_DIR}/${INPUT_TEMPLATE}"
	local out_dir="${WORK_DIR}/build/qcom/x1e80100"
	local conf="${out_dir}/${OUTPUT_NAME}.conf"
	local tplg="${out_dir}/${OUTPUT_NAME}-tplg.bin"

	prepare_source_checkout

	mkdir -p "$out_dir"

	log "Running m4 to expand topology template..."
	m4 -I "${SOURCE_DIR}/build" -I "$SOURCE_DIR" "$src" > "$conf"

	log "Compiling topology with alsatplg..."
	alsatplg -c "$conf" -o "$tplg"

	log "Topology built: $tplg ($(du -h "$tplg" | cut -f1))"
}

prepare_ucm_files() {
	local ucm_dir="${WORK_DIR}/build/ucm"
	local repo_audio="${repo_dir}/payload/audio"
	mkdir -p "$ucm_dir"

	if [ -f "${repo_audio}/MICROSOFT-Surface-Pro-11.conf" ] && \
	   [ -f "${repo_audio}/Surface11-HiFi.conf" ] && \
	   [ -f "${repo_audio}/x1e80100.conf" ]; then
		log "Using UCM files from repo payload/audio/"
		cp "${repo_audio}/MICROSOFT-Surface-Pro-11.conf" "${ucm_dir}/" && \
		cp "${repo_audio}/Surface11-HiFi.conf" "${ucm_dir}/" && \
		cp "${repo_audio}/x1e80100.conf" "${ucm_dir}/"
		return
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

install_files() {
	if [ "$(id -u)" -ne 0 ]; then
		log "ERROR: --install must be run as root (sudo)"
		exit 1
	fi

	local tplg="${WORK_DIR}/build/qcom/x1e80100/${OUTPUT_NAME}-tplg.bin"
	local ucm_dir="${WORK_DIR}/build/ucm"

	if [ ! -f "$tplg" ]; then
		log "ERROR: Topology not built, run without --install first"
		exit 1
	fi

	log "Installing topology to ${FW_PATH}/"
	mkdir -p "$FW_PATH"
	cp "$tplg" "${FW_PATH}/${OUTPUT_NAME}-tplg.bin"

	log "Installing UCM files..."
	mkdir -p "$UCM_QUALCOMM_DIR"
	cp "${ucm_dir}/MICROSOFT-Surface-Pro-11.conf" "$UCM_QUALCOMM_DIR/"
	cp "${ucm_dir}/Surface11-HiFi.conf" "$UCM_QUALCOMM_DIR/"

	mkdir -p "$UCM_CONFD_DIR"
	if [ -f "${ucm_dir}/x1e80100.conf" ]; then
		cp "${ucm_dir}/x1e80100.conf" "${UCM_CONFD_DIR}/x1e80100.conf"
		log "Updated ${UCM_CONFD_DIR}/x1e80100.conf"
	fi

	log "Install complete. Reboot for topology to take effect."
	log "After reboot, restart PipeWire with: systemctl --user restart pipewire wireplumber"
	log ""
	log "SAFETY: Keep volume at 10% for first speaker test."
	log "  speaker-test -D hw:0,1 -c 4 -t sine -f 440 -l 3"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN="true"; shift ;;
		--install) INSTALL="true"; shift ;;
		--work-dir) WORK_DIR="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) log "Unknown option: $1"; usage; exit 1 ;;
	esac
done

if [ "$DRY_RUN" = "true" ] && [ "$INSTALL" = "true" ]; then
	die "--dry-run and --install cannot be used together"
fi

SOURCE_DIR="${WORK_DIR%/}/source"

check_deps
build_topology
prepare_ucm_files

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
