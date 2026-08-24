#!/usr/bin/env bash
set -euo pipefail

CANONICAL_TPLG_SHA256="1b0c7217fc67bb11da002b06563dd8c411b0f0e35ac40778bff3d65093061c9d"
TPLG_NAME="X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
FW_PATH="/lib/firmware/qcom/x1e80100"
UCM_DIR="/usr/share/alsa/ucm2/Qualcomm/x1e80100"
CONF_D_DIR="/usr/share/alsa/ucm2/conf.d"
TPLG_SRC="${TPLG_SRC:-/home/leon/Workspace/repos/SP11X1e-audio/deploy/render-parity/X1E80100-Microsoft-Surface-Pro-11-Render-Parity-tplg.bin}"
UCM_SRC_DIR="${UCM_SRC_DIR:-/home/leon/Workspace/repos/SP11X1e-audio/deploy/ucm2/Qualcomm/x1e80100}"
KERNEL_ALLOWLIST=(
	"7.2.0-jg-0sp11v9-qcom-x1e"
	"7.2.0-jg-0sp11v10-qcom-x1e"
)
ACTION="install"
DRY_RUN="false"
FORCE="false"
RESTART="true"
BACKUP_DIR=""
BACKUP_DIR_SET="false"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Migrate Surface Pro 11 audio from the legacy OE workaround stack to the
native Golden v32 topology, geocausa UCM, and native PipeWire sink used by
the 7.2.0-jg-0sp11v9/v10 kernel line.

Options:
  --install          Install the native audio pairing (default).
  --rollback         Restore the newest migration backup.
  --dry-run          Print what would change without writing anything.
  --tplg PATH        Override topology source (default: ${TPLG_SRC}).
  --ucm-dir PATH     Override UCM source directory (default: ${UCM_SRC_DIR}).
  --backup-dir DIR   Override the backup or restore directory.
  --force            Bypass the kernel release allowlist gate.
  --no-restart       Do not restart user PipeWire/WirePlumber services.
  -h, --help         Show this help.

Backups are stored under:
  /var/backups/sp11-audio-native-migration-<YYYYmmdd-HHMMSS>

Known limitation:
  DMIC capture is not available on this kernel line because the canonical
  topology defines no VA/DMIC capture graph. See
  docs/adr/adr-0062-sp11-7-2-0-jg-0sp11v9-golden-v32-audio-line.md and
  linux-surface-pro-11-oe issue #48.
EOF
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

have() {
	command -v "$1" >/dev/null 2>&1
}

root_cmd() {
	if [ "${EUID}" -eq 0 ]; then
		"$@"
	else
		sudo "$@"
	fi
}

require_system_access() {
	if [ "${EUID}" -ne 0 ] && ! have sudo; then
		log "ERROR: sudo or root access is required for system audio paths."
		exit 1
	fi
	if [ "$DRY_RUN" != "true" ] && [ "${EUID}" -ne 0 ]; then
		sudo -v
	fi
}

kernel_allowed() {
	local release="$1" allowed
	for allowed in "${KERNEL_ALLOWLIST[@]}"; do
		if [ "$release" = "$allowed" ]; then
			return 0
		fi
	done
	return 1
}

check_kernel() {
	local release
	release="$(uname -r)"
	if kernel_allowed "$release"; then
		return
	fi
	if [ "$FORCE" = "true" ]; then
		log "WARNING: forcing migration on non-allowlisted kernel ${release}."
		return
	fi

	log "ERROR: kernel ${release} is not a native SP11 audio kernel."
	cat >&2 <<EOF
Build and install one of these releases first:
  ${KERNEL_ALLOWLIST[0]}
  ${KERNEL_ALLOWLIST[1]}

See:
  ${repo_dir}/scripts/build-sp11-qcom-x1e-kernel.sh
  ${repo_dir}/docs/how-to/how-to-build-patched-qcom-x1e-kernel.md

Rerun with --force only if you have independently verified kernel compatibility.
EOF
	exit 1
}

verify_sources() {
	local file actual_sha
	for file in \
		"$TPLG_SRC" \
		"${UCM_SRC_DIR}/SP11-HiFi.conf" \
		"${UCM_SRC_DIR}/MICROSOFT-Surface-Pro-11.conf"; do
		if [ ! -f "$file" ]; then
			log "ERROR: required source artifact not found: $file"
			exit 1
		fi
	done
	if ! have sha256sum; then
		log "ERROR: sha256sum is required to verify the canonical topology."
		exit 1
	fi
	actual_sha="$(sha256sum "$TPLG_SRC" | awk '{print $1}')"
	if [ "$actual_sha" != "$CANONICAL_TPLG_SHA256" ]; then
		log "ERROR: topology sha256 mismatch."
		log "Expected: ${CANONICAL_TPLG_SHA256}"
		log "Actual:   ${actual_sha}"
		exit 1
	fi
	log "Verified canonical topology sha256: ${actual_sha}"
}

default_install_backup_dir() {
	printf '/var/backups/sp11-audio-native-migration-%s\n' "$(date '+%Y%m%d-%H%M%S')"
}

newest_backup_dir() {
	local entries=()
	mapfile -t entries < <(
		find /var/backups -maxdepth 1 -type d \
			-name 'sp11-audio-native-migration-*' \
			-printf '%T@\t%p\n' 2>/dev/null | sort -nr
	)
	if [ "${#entries[@]}" -eq 0 ]; then
		return 1
	fi
	printf '%s\n' "${entries[0]#*$'\t'}"
}

record_state() {
	local status="$1" path="$2"
	printf '%s\t%s\n' "$status" "$path" | \
		root_cmd tee -a "${BACKUP_DIR}/.migration-state.tsv" >/dev/null
}

record_original_state() {
	local path="$1"
	if [ -e "$path" ] || [ -L "$path" ]; then
		record_state "PRESENT" "$path"
	else
		record_state "ABSENT" "$path"
	fi
}

backup_file() {
	local path="$1" destination="${BACKUP_DIR}${1}"
	if [ ! -e "$path" ] && [ ! -L "$path" ]; then
		return
	fi
	if [ "$DRY_RUN" = "true" ]; then
		log "Would back up ${path} to ${destination}"
		return
	fi
	root_cmd mkdir -p "$(dirname "$destination")"
	root_cmd cp -a "$path" "$destination"
	record_state "BACKUP" "$path"
	log "Backed up ${path}"
}

collect_user_workarounds() {
	local pipewire_dir wireplumber_dir
	pipewire_dir="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d"
	wireplumber_dir="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
	USER_WORKAROUNDS=()
	shopt -s nullglob
	USER_WORKAROUNDS+=("${pipewire_dir}"/50-sp11-*.conf)
	USER_WORKAROUNDS+=("${wireplumber_dir}"/51-sp11-*.conf)
	shopt -u nullglob
}

prepare_backup() {
	local topology="${FW_PATH}/${TPLG_NAME}" path topology_sha=""
	local system_candidates=(
		"$topology"
		"${UCM_DIR}/Surface11-HiFi.conf"
		"${UCM_DIR}/SP11-HiFi.conf"
		"${UCM_DIR}/MICROSOFT-Surface-Pro-11.conf"
		"${UCM_DIR}/x1e80100.conf"
		"${CONF_D_DIR}/x1e80100.conf"
	)

	if [ "$DRY_RUN" = "true" ]; then
		log "Would create backup directory ${BACKUP_DIR}"
	else
		if root_cmd test -e "$BACKUP_DIR"; then
			log "ERROR: backup path already exists: ${BACKUP_DIR}"
			exit 1
		fi
		root_cmd mkdir -p "$BACKUP_DIR"
		root_cmd touch "${BACKUP_DIR}/.sp11-audio-native-migration"
		root_cmd touch "${BACKUP_DIR}/.migration-state.tsv"
	fi

	for path in "${system_candidates[@]}"; do
		if [ "$DRY_RUN" != "true" ]; then
			record_original_state "$path"
		fi
	done
	for path in "${USER_WORKAROUNDS[@]}"; do
		if [ "$DRY_RUN" != "true" ]; then
			record_original_state "$path"
		fi
	done

	if [ -f "$topology" ]; then
		topology_sha="$(sha256sum "$topology" | awk '{print $1}')"
	fi
	if [ "$topology_sha" = "$CANONICAL_TPLG_SHA256" ]; then
		log "Existing topology is already canonical; no topology backup needed."
	else
		backup_file "$topology"
	fi

	for path in \
		"${UCM_DIR}/Surface11-HiFi.conf" \
		"${UCM_DIR}/SP11-HiFi.conf" \
		"${UCM_DIR}/MICROSOFT-Surface-Pro-11.conf" \
		"${UCM_DIR}/x1e80100.conf" \
		"${CONF_D_DIR}/x1e80100.conf"; do
		backup_file "$path"
	done
	for path in "${USER_WORKAROUNDS[@]}"; do
		backup_file "$path"
	done
}

install_native_pairing() {
	local legacy_ucm="${UCM_DIR}/Surface11-HiFi.conf" path
	if [ "$DRY_RUN" = "true" ]; then
		log "Would install ${TPLG_SRC} as ${FW_PATH}/${TPLG_NAME}"
		log "Would install ${UCM_SRC_DIR}/SP11-HiFi.conf in ${UCM_DIR}"
		log "Would install ${UCM_SRC_DIR}/MICROSOFT-Surface-Pro-11.conf in ${UCM_DIR}"
		if [ -e "$legacy_ucm" ] || [ -L "$legacy_ucm" ]; then
			log "Would overwrite legacy ${legacy_ucm} with the native SP11-HiFi.conf content"
		fi
		for path in "${USER_WORKAROUNDS[@]}"; do
			log "Would remove workaround config ${path}"
		done
		return
	fi

	root_cmd install -D -m 0644 "$TPLG_SRC" "${FW_PATH}/${TPLG_NAME}"
	root_cmd install -D -m 0644 "${UCM_SRC_DIR}/SP11-HiFi.conf" \
		"${UCM_DIR}/SP11-HiFi.conf"
	root_cmd install -D -m 0644 "${UCM_SRC_DIR}/MICROSOFT-Surface-Pro-11.conf" \
		"${UCM_DIR}/MICROSOFT-Surface-Pro-11.conf"
	if [ -e "$legacy_ucm" ] || [ -L "$legacy_ucm" ]; then
		root_cmd install -m 0644 "${UCM_SRC_DIR}/SP11-HiFi.conf" "$legacy_ucm"
	fi
	for path in "${USER_WORKAROUNDS[@]}"; do
		rm -f -- "$path"
		log "Removed workaround config ${path}"
	done
}

restart_user_audio() {
	local service
	if [ "$RESTART" != "true" ]; then
		log "Skipping PipeWire/WirePlumber restart (--no-restart)."
		return
	fi
	if [ "$DRY_RUN" = "true" ]; then
		log "Would reset failures and restart user pipewire, pipewire-pulse, and wireplumber services"
		return
	fi
	if ! have systemctl || ! systemctl --user show-environment >/dev/null 2>&1; then
		log "No systemd user session detected. Log out and back in to restart audio services."
		return
	fi

	systemctl --user reset-failed pipewire pipewire-pulse wireplumber || true
	for service in pipewire pipewire-pulse wireplumber; do
		if ! systemctl --user restart "$service"; then
			log "WARNING: failed to restart user service ${service}; log out and back in."
		fi
	done
}

print_verification() {
	cat <<'EOF'

Post-reboot verification:
  uname -r
    Shows 7.2.0-jg-0sp11v9-qcom-x1e or 7.2.0-jg-0sp11v10-qcom-x1e.

  wpctl status | grep -A6 Sinks
    Shows "Built-in Audio Pro" and no "Surface Pro 11 Speakers" workaround sink.

  speaker-test -D default -c 2 -t sine -f 440 -s 1 -l 1
  speaker-test -D default -c 2 -t sine -f 440 -s 2 -l 1
    Plays the left and right speakers respectively.

  sudo dmesg | grep -Ei 'SP11 stage|SPVI|no backend' | tail -15
    Shows "SP11 stage SP/SPVI enabled with VI+CPS feedback accepted" and no
    "no backend DAIs" messages.
EOF
}

run_install() {
	check_kernel
	verify_sources
	collect_user_workarounds
	if [ "$BACKUP_DIR_SET" != "true" ]; then
		BACKUP_DIR="$(default_install_backup_dir)"
	fi
	prepare_backup
	install_native_pairing
	restart_user_audio

	if [ "$DRY_RUN" = "true" ]; then
		log "Dry run complete; no files or services were changed."
		return
	fi
	cat <<EOF

Native SP11 audio migration complete.
  Installed topology: ${FW_PATH}/${TPLG_NAME}
  Installed UCM:      ${UCM_DIR}/SP11-HiFi.conf
  Installed card UCM: ${UCM_DIR}/MICROSOFT-Surface-Pro-11.conf
  Removed workaround configs: ${#USER_WORKAROUNDS[@]}
  Backup: ${BACKUP_DIR}

*** REBOOT REQUIRED ***
The topology is loaded at card probe: audioreach_tplg_init reads
qcom/<card>-tplg.bin at boot. Reboot before validating the native sink.
EOF
	print_verification
}

validate_rollback_backup() {
	if ! root_cmd test -d "$BACKUP_DIR" || \
		! root_cmd test -f "${BACKUP_DIR}/.sp11-audio-native-migration" || \
		! root_cmd test -f "${BACKUP_DIR}/.migration-state.tsv"; then
		log "ERROR: not a valid SP11 native-audio migration backup: ${BACKUP_DIR}"
		exit 1
	fi
}

restore_backup_files() {
	local status path source
	while IFS=$'\t' read -r status path; do
		[ "$status" = "BACKUP" ] || continue
		source="${BACKUP_DIR}${path}"
		if [ "$DRY_RUN" = "true" ]; then
			log "Would restore ${source} to ${path}"
			continue
		fi
		if ! root_cmd test -e "$source" && ! root_cmd test -L "$source"; then
			log "ERROR: recorded backup file is missing: ${source}"
			exit 1
		fi
		root_cmd mkdir -p "$(dirname "$path")"
		root_cmd cp -a "$source" "$path"
		log "Restored ${path}"
	done < <(root_cmd cat "${BACKUP_DIR}/.migration-state.tsv")
}

remove_migration_created_files() {
	local status path
	while IFS=$'\t' read -r status path; do
		[ "$status" = "ABSENT" ] || continue
		case "$path" in
			"${FW_PATH}/${TPLG_NAME}"|\
			"${UCM_DIR}/SP11-HiFi.conf"|\
			"${UCM_DIR}/MICROSOFT-Surface-Pro-11.conf")
				if [ "$DRY_RUN" = "true" ]; then
					log "Would remove migration-created file ${path}"
				elif [ -e "$path" ] || [ -L "$path" ]; then
					root_cmd rm -f -- "$path"
					log "Removed migration-created file ${path}"
				fi
				;;
		esac
	done < <(root_cmd cat "${BACKUP_DIR}/.migration-state.tsv")
}

run_rollback() {
	if [ "$BACKUP_DIR_SET" != "true" ]; then
		if ! BACKUP_DIR="$(newest_backup_dir)"; then
			log "ERROR: no migration backup found under /var/backups."
			exit 1
		fi
	fi
	validate_rollback_backup
	restore_backup_files
	remove_migration_created_files
	restart_user_audio

	if [ "$DRY_RUN" = "true" ]; then
		log "Dry run complete; no files or services were changed."
		return
	fi
	cat <<EOF

SP11 audio rollback complete from:
  ${BACKUP_DIR}

*** REBOOT REQUIRED ***
Reboot so audioreach_tplg_init reloads the restored topology at card probe.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--install) ACTION="install"; shift ;;
		--rollback) ACTION="rollback"; shift ;;
		--dry-run) DRY_RUN="true"; shift ;;
		--tplg)
			[ "$#" -ge 2 ] || { echo "--tplg requires a value" >&2; exit 2; }
			TPLG_SRC="$2"
			shift 2
			;;
		--ucm-dir)
			[ "$#" -ge 2 ] || { echo "--ucm-dir requires a value" >&2; exit 2; }
			UCM_SRC_DIR="$2"
			shift 2
			;;
		--backup-dir)
			[ "$#" -ge 2 ] || { echo "--backup-dir requires a value" >&2; exit 2; }
			BACKUP_DIR="$2"
			BACKUP_DIR_SET="true"
			shift 2
			;;
		--force) FORCE="true"; shift ;;
		--no-restart) RESTART="false"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

require_system_access

case "$ACTION" in
	install) run_install ;;
	rollback) run_rollback ;;
esac
