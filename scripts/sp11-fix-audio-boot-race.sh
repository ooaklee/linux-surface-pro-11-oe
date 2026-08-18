#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Compatibility installer/diagnostic for the Surface Pro 11 WSA routing
# service.  The historical name is retained for installed systems, but the
# original alsactl "boot race" diagnosis was incorrect: 0x01001021 is the
# AudioReach SPF readiness query, not APM_CMD_GRAPH_OPEN (0x01001000).
#
# This version never rewrites /var/lib/alsa/asound.state and never masks the
# distribution ALSA services.  The routing service runs after any restore,
# configures the complete WSA path while PCM1 is closed, and exercises it with
# a real PCM open before the display manager starts.
set -euo pipefail

ACTION="audit"
REBOOT="false"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS] [audit|pre-boot|post-boot|install|restore]

Surface Pro 11 AudioReach/WSA routing diagnostic and service installer.

Modes:
  audit       Report the current PCM, SoundWire, service, and APM state.
  pre-boot    Compatibility alias for audit; it makes no system changes.
  post-boot   Audit, then restart the installed routing service as root.
  install     Install and enable the corrected routing service (root).
  restore     Remove the routing service and undo masks made by old releases.

Options:
  --reboot    Reboot after install (root).
  --no-reboot Do not reboot after install (default).
  -h, --help  Show this help.

The manual PipeWire sink remains a per-user install:
  sp11-pipewire-speaker-sink --install
EOF
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

need_root() {
	if [ "$(id -u)" -ne 0 ]; then
		log 'ERROR: this action requires root.'
		exit 1
	fi
}

audit() {
	local pcm="/proc/asound/X1E80100Microso/pcm1p/sub0/status"

	log 'AudioReach command errors in this boot:'
	journalctl -k -b --no-pager 2>/dev/null |
		grep -E 'qcom-apm|CMD timeout|DSP returned|Processing 0x0?100100|Failed to (set media format|prepare Graph|Start Graph|stop APM port|start APM port)' ||
		log '  none found'

	log 'Opcode key: 1001021=GET_SPF_STATE; 1001000..1001006=GRAPH_OPEN through SET_CFG.'
	if [ -r "$pcm" ]; then
		log "PCM1 status: $(tr '\n' ' ' < "$pcm")"
	else
		log 'PCM1 status is unavailable.'
	fi

	for slave in /sys/bus/soundwire/devices/sdw:1:0:0217:0204:00:{0,1}; do
		if [ -r "$slave/status" ]; then
			log "$(basename "$slave"): status=$(cat "$slave/status"), runtime=$(cat "$slave/power/runtime_status" 2>/dev/null || echo unknown)"
		else
			log "$(basename "$slave"): unavailable"
		fi
	done

	if command -v systemctl >/dev/null 2>&1; then
		log "routing service: $(systemctl is-active sp11-wsa-routing.service 2>/dev/null || true)"
	fi
}

install_permanent() {
	local routing_script="$repo_dir/scripts/sp11-enable-wsa-routing.sh"
	local service_file="$repo_dir/scripts/systemd/sp11-wsa-routing.service"

	need_root
	[ -f "$routing_script" ] || { log "ERROR: missing $routing_script"; exit 1; }
	[ -f "$service_file" ] || { log "ERROR: missing $service_file"; exit 1; }

	install -m 0755 "$routing_script" /usr/local/sbin/sp11-enable-wsa-routing.sh
	rm -f /usr/local/sbin/sp11-enable-wsa-routing
	install -m 0644 "$service_file" /etc/systemd/system/sp11-wsa-routing.service

	# Old versions created these masks.  They are not part of the corrected
	# design; the routing unit is explicitly ordered after either service.
	systemctl unmask alsa-restore.service alsa-state.service 2>/dev/null || true
	systemctl daemon-reload
	systemctl enable sp11-wsa-routing.service

	log 'Installed corrected sp11-wsa-routing.service.'
	log 'No ALSA state file was modified.'
	log 'As the desktop user, also run: sp11-pipewire-speaker-sink --install'

	if [ "$REBOOT" = "true" ]; then
		log 'Rebooting in 3 seconds ...'
		sleep 3
		reboot
	else
		log 'Reboot, or start the service before starting the display manager.'
	fi
}

post_boot() {
	audit
	need_root
	log 'Restarting the corrected WSA routing service ...'
	systemctl restart sp11-wsa-routing.service
	systemctl --no-pager --full status sp11-wsa-routing.service
}

restore_fix() {
	need_root
	systemctl disable --now sp11-wsa-routing.service 2>/dev/null || true
	rm -f /etc/systemd/system/sp11-wsa-routing.service
	rm -f /usr/local/sbin/sp11-enable-wsa-routing.sh
	rm -f /usr/local/sbin/sp11-enable-wsa-routing
	systemctl unmask alsa-restore.service alsa-state.service 2>/dev/null || true
	systemctl daemon-reload
	log 'Removed the routing service and undid ALSA-service masks.'
	log 'Existing asound.state backups were left untouched for manual inspection.'
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--reboot) REBOOT="true"; shift ;;
		--no-reboot) REBOOT="false"; shift ;;
		-h|--help) usage; exit 0 ;;
		audit|pre-boot|post-boot|install|restore) ACTION="$1"; shift ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$ACTION" in
	audit|pre-boot) audit ;;
	post-boot) post_boot ;;
	install) install_permanent ;;
	restore) restore_fix ;;
esac
