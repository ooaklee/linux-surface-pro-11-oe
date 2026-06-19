#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Fix Surface Pro 11 audio boot race: alsactl restores WSA mixer state at boot
# before the AudioReach DSP finishes loading the audio graph, causing an APM
# CMD timeout, SoundWire bus clash, and no audio (only pops).
#
# This script:
#   1. Backs up and clears the WSA controls from /var/lib/alsa/asound.state
#   2. Masks alsa-restore.service so it doesn't race the DSP at boot
#   3. Optionally reboots so the DSP graph loads cleanly
#
# After reboot, run with --post-boot to re-enable WSA routing and verify.
# Use --install for a permanent fix that sets up a systemd service to
# enable WSA routing automatically after every boot.
set -euo pipefail

ACTION="pre-boot"
REBOOT="false"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS] [pre-boot|post-boot|install|restore]

Fix the Surface Pro 11 audio boot race caused by alsactl restoring WSA mixer
state before the AudioReach DSP graph finishes loading.

Modes:
  pre-boot    Back up asound.state, clear WSA controls, mask alsa-restore.
              Run this before rebooting. (default)
  post-boot   Re-enable WSA routing after a clean DSP boot, then run a
              speaker-test. Run this after rebooting with pre-boot.
  install     Apply the pre-boot fix AND install a permanent systemd service
              that enables WSA routing automatically after every boot.
              Run this once, then reboot.
  restore     Undo the fix: unmask alsa-restore, restore the backup state,
              and remove the systemd service.

Options:
  --reboot          Reboot after pre-boot/install fix (requires sudo).
  --no-reboot       Do not reboot after pre-boot fix (default).
  -h, --help        Show this help.

Pre-boot flow (diagnostic):
  1. sudo $0 pre-boot
  2. sudo reboot
  3. $0 post-boot

Permanent fix:
  1. sudo $0 install
  2. sudo reboot
  3. Audio should work automatically after boot.
EOF
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

need_root() {
	if [ "$(id -u)" -ne 0 ]; then
		log "ERROR: this action requires root (sudo)."
		exit 1
	fi
}

# ── Pre-boot: clear WSA state and mask alsa-restore ──────────────────────

pre_boot() {
	need_root

	local state_file="/var/lib/alsa/asound.state"
	local backup="${state_file}.bak.$(date +%Y%m%d%H%M%S)"
	local tmp="$(mktemp)"

	if [ ! -f "$state_file" ]; then
		log "No $state_file — nothing to clear."
	else
		log "Backing up $state_file to $backup"
		cp "$state_file" "$backup"
	fi

	# Write a clean asound.state with WSA controls disabled.
	# We only touch WSA/Spkr controls; leave other controls (VA mic, etc.) as-is
	# by removing WSA/Spkr control blocks and re-storing current non-WSA state.
	log "Clearing WSA mixer state from $state_file ..."

	if [ -f "$state_file" ]; then
		# Use awk to remove control blocks that contain WSA or Spkr in their name.
		# Each control block is: control.N { ... }
		awk '
			BEGIN { skip=0 }
			/^[[:space:]]*control\.[0-9]+[[:space:]]*\{/ {
				block=""
				skip=0
				collecting=1
			}
			collecting==1 {
				block = block $0 "\n"
				if ($0 ~ /^[[:space:]]*name[[:space:]]/) {
					if ($0 ~ /WSA|Spkr/) {
						skip=1
					}
				}
				if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) {
					collecting=0
					if (skip==0) {
						printf "%s", block
					}
				}
				next
			}
			# Print non-control-block lines (state header)
			{ print }
		' "$state_file" > "$tmp"

		# If awk removed everything, fall back to a minimal empty state
		if [ ! -s "$tmp" ]; then
			log "WARNING: awk produced empty file — writing minimal state."
			echo "" > "$tmp"
		fi

		cp "$tmp" "$state_file"
		rm -f "$tmp"
		log "Cleared WSA controls from $state_file."
	fi

	# Mask alsa-restore.service so it doesn't run at boot and race the DSP.
	log "Masking alsa-restore.service ..."
	systemctl mask alsa-restore.service 2>/dev/null || true
	systemctl mask alsa-state.service 2>/dev/null || true

	log ""
	log "Pre-boot fix applied."
	log "  - WSA controls cleared from $state_file"
	log "  - alsa-restore.service masked (will not restore mixer at boot)"
	log "  - Backup: $backup"
	log ""

	if [ "$REBOOT" = "true" ]; then
		log "Rebooting in 3 seconds ..."
		sleep 3
		reboot
	else
		log "Reboot now, then run: $0 post-boot"
	fi
}

# ── Post-boot: re-enable WSA routing and test ────────────────────────────

post_boot() {
	local card="${SP11_ALSA_CARD:-X1E80100Microso}"

	log "Checking DSP graph load status ..."
	if ! dmesg 2>/dev/null | grep -q 'CMD timeout'; then
		log "GOOD: No APM CMD timeout in current boot dmesg."
	else
		log "WARNING: APM CMD timeout still present — the race may not be fully fixed."
		log "  The DSP graph may still have failed to load. Check:"
		log "  sudo journalctl -b -k | grep -E 'qcom-apm|CMD timeout'"
	fi

	log ""
	log "Checking SoundWire bus state ..."
	if dmesg 2>/dev/null | grep -q 'Bus clash'; then
		log "WARNING: Bus clash still detected — DSP graph may not have loaded."
		log "  Try: sudo journalctl -b -k | grep -v 'Bus clash' | grep -iE 'soundwire|wsa'"
	else
		log "GOOD: No Bus clash detected in current boot."
	fi

	log ""
	log "Enabling WSA speaker routing ..."

	# Enable the WSA DMA route for MultiMedia2 (4ch speaker PCM)
	amixer -c "$card" sset 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' on 2>/dev/null || \
		log "  (could not set MultiMedia2 route)"

	# Set WSA macro routing
	amixer -c "$card" sset 'WSA WSA RX0 MUX' AIF1_PB 2>/dev/null || true
	amixer -c "$card" sset 'WSA WSA RX1 MUX' AIF1_PB 2>/dev/null || true
	amixer -c "$card" sset 'WSA WSA_RX0 INP0' RX0 2>/dev/null || true
	amixer -c "$card" sset 'WSA WSA_RX1 INP0' RX1 2>/dev/null || true

	# Set hardware volume to 100% (pass-through) — PipeWire/GNOME controls volume
	amixer -c "$card" sset 'Speakers' 100% 2>/dev/null || true

	log ""
	log "Running speaker-test (4ch sine, 440Hz, 1 loop) ..."
	log "Keep volume LOW. Listen for the tone from the left speaker."
	log ""

	speaker-test -D "hw:${card},1" -c 4 -t sine -f 440 -l 1 2>&1 | tail -15

	log ""
	log "If you heard a tone from the left speaker, the boot race fix worked."
	log "Next steps:"
	log "  1. Install the PipeWire manual sink: ./scripts/sp11-pipewire-speaker-sink.sh --install --enable-route"
	log "  2. Test with desktop audio"
	log "  3. If stable across reboots, make the fix permanent (TODO: integrate into support installer)"
}

# ── Install: permanent fix with systemd service ──────────────────────────

install_permanent() {
	need_root

	# Apply the pre-boot fix first (clears state, masks alsa-restore)
	pre_boot_no_log_reboot

	# Install the WSA routing enable script
	local routing_script="${repo_dir}/scripts/sp11-enable-wsa-routing.sh"
	local service_file="${repo_dir}/scripts/systemd/sp11-wsa-routing.service"

	if [ ! -f "$routing_script" ]; then
		log "ERROR: $routing_script not found."
		exit 1
	fi
	if [ ! -f "$service_file" ]; then
		log "ERROR: $service_file not found."
		exit 1
	fi

	log "Installing sp11-enable-wsa-routing.sh to /usr/local/sbin/ ..."
	install -m 0755 "$routing_script" /usr/local/sbin/sp11-enable-wsa-routing.sh

	log "Installing sp11-wsa-routing.service to /etc/systemd/system/ ..."
	install -m 0644 "$service_file" /etc/systemd/system/sp11-wsa-routing.service

	log "Enabling sp11-wsa-routing.service ..."
	systemctl daemon-reload
	systemctl enable sp11-wsa-routing.service

	# Install user-level PipeWire restart service
	local pw_service="${repo_dir}/scripts/systemd/sp11-pipewire-restart.service"
	if [ -f "$pw_service" ]; then
		local user_home="${HOME:-/root}"
		local user_uid="${SUDO_UID:-$(id -u)}"
		local real_user="${SUDO_USER:-$(whoami)}"
		local user_config_dir

		# Find the real user's config directory (not root)
		if [ -n "$SUDO_USER" ] && [ -n "$SUDO_UID" ]; then
			user_home="$(getent passwd "$SUDO_UID" | cut -d: -f6)"
			real_user="$SUDO_USER"
			user_uid="$SUDO_UID"
		fi

		user_config_dir="$user_home/.config/systemd/user"
		install -d "$user_config_dir"
		install -m 0644 "$pw_service" "$user_config_dir/sp11-pipewire-restart.service"

		log "Installed sp11-pipewire-restart.service to $user_config_dir/"
		log "  (user: $real_user, uid: $user_uid)"

		# Enable it for the user
		if [ -n "$SUDO_USER" ]; then
			su - "$SUDO_USER" -c 'systemctl --user daemon-reload && systemctl --user enable sp11-pipewire-restart.service' 2>/dev/null || true
		else
			systemctl --user daemon-reload 2>/dev/null || true
			systemctl --user enable sp11-pipewire-restart.service 2>/dev/null || true
		fi
	fi

	log ""
	log "Permanent fix installed."
	log "  - WSA controls cleared from asound.state"
	log "  - alsa-restore.service masked (won't race DSP at boot)"
	log "  - sp11-wsa-routing.service enabled (enables WSA routing after DSP loads)"
	log "  - sp11-pipewire-restart.service enabled (restarts PipeWire after routing is ready)"
	log ""

	if [ "$REBOOT" = "true" ]; then
		log "Rebooting in 3 seconds ..."
		sleep 3
		reboot
	else
		log "Reboot now. After boot, audio should work automatically."
		log "Verify with: systemctl status sp11-wsa-routing.service"
	fi
}

# Internal: pre-boot fix without the reboot prompt (used by install_permanent)
pre_boot_no_log_reboot() {
	local state_file="/var/lib/alsa/asound.state"
	local backup="${state_file}.bak.$(date +%Y%m%d%H%M%S)"
	local tmp="$(mktemp)"

	if [ -f "$state_file" ]; then
		log "Backing up $state_file to $backup"
		cp "$state_file" "$backup"
	else
		log "No $state_file — nothing to clear."
	fi

	if [ -f "$state_file" ]; then
		log "Clearing WSA mixer state from $state_file ..."

		awk '
			BEGIN { skip=0 }
			/^[[:space:]]*control\.[0-9]+[[:space:]]*\{/ {
				block=""
				skip=0
				collecting=1
			}
			collecting==1 {
				block = block $0 "\n"
				if ($0 ~ /^[[:space:]]*name[[:space:]]/) {
					if ($0 ~ /WSA|Spkr/) {
						skip=1
					}
				}
				if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) {
					collecting=0
					if (skip==0) {
						printf "%s", block
					}
				}
				next
			}
			{ print }
		' "$state_file" > "$tmp"

		if [ ! -s "$tmp" ]; then
			log "WARNING: awk produced empty file — writing minimal state."
			echo "" > "$tmp"
		fi

		cp "$tmp" "$state_file"
		rm -f "$tmp"
		log "Cleared WSA controls from $state_file."
	fi

	log "Masking alsa-restore.service ..."
	systemctl mask alsa-restore.service 2>/dev/null || true
	systemctl mask alsa-state.service 2>/dev/null || true
}

# ── Restore: undo the fix ────────────────────────────────────────────────

restore_fix() {
	need_root

	log "Removing sp11-wsa-routing.service ..."
	systemctl disable sp11-wsa-routing.service 2>/dev/null || true
	rm -f /etc/systemd/system/sp11-wsa-routing.service

	log "Removing sp11-pipewire-restart.service ..."
	if [ -n "$SUDO_USER" ]; then
		su - "$SUDO_USER" -c 'systemctl --user disable sp11-pipewire-restart.service 2>/dev/null; rm -f ~/.config/systemd/user/sp11-pipewire-restart.service; systemctl --user daemon-reload' 2>/dev/null || true
	fi
	rm -f "$HOME/.config/systemd/user/sp11-pipewire-restart.service" 2>/dev/null || true

	systemctl daemon-reload

	log "Removing sp11-enable-wsa-routing.sh ..."
	rm -f /usr/local/sbin/sp11-enable-wsa-routing.sh

	log "Unmasking alsa-restore.service ..."
	systemctl unmask alsa-restore.service 2>/dev/null || true
	systemctl unmask alsa-state.service 2>/dev/null || true

	log "Looking for most recent asound.state backup ..."
	local backup="$(ls -t /var/lib/alsa/asound.state.bak.* 2>/dev/null | head -1)"
	if [ -n "$backup" ] && [ -f "$backup" ]; then
		log "Restoring $backup -> /var/lib/alsa/asound.state"
		cp "$backup" /var/lib/alsa/asound.state
	else
		log "No backup found. Run alsactl store to create a fresh state."
	fi

	log "Restore complete. Reboot for changes to take effect."
}

# ── Argument parsing ─────────────────────────────────────────────────────

while [ "$#" -gt 0 ]; do
	case "$1" in
		--reboot) REBOOT="true"; shift ;;
		--no-reboot) REBOOT="false"; shift ;;
		-h|--help) usage; exit 0 ;;
		pre-boot|post-boot|install|restore) ACTION="$1"; shift ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$ACTION" in
	pre-boot) pre_boot ;;
	post-boot) post_boot ;;
	install) install_permanent ;;
	restore) restore_fix ;;
esac