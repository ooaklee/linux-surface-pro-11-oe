#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Enable WSA speaker routing on the Surface Pro 11 after the AudioReach DSP
# graph has loaded. This runs as a systemd service after the sound card
# appears, avoiding the boot race where alsactl restores WSA mixer state
# before the DSP finishes loading the audio graph.
#
# The APM CMD timeout (APM_CMD_GRAPH_OPEN) is a kernel-level race between
# ADSP firmware boot and the topology loader. It happens on every boot but
# the DSP sometimes recovers and sometimes doesn't. This script:
#   1. Waits for the SoundWire slaves to reach Attached state
#   2. If they don't (graph failed), unbinds and rebinds the sound card
#      with a delay to give the DSP more time
#   3. Retries up to 3 times
#   4. Once the graph is loaded, enables WSA routing
#
# See docs/adr/adr-0035-audio-boot-race-alsactl.md for the full diagnosis.
set -euo pipefail

CARD="${SP11_ALSA_CARD:-X1E80100Microso}"
SPEAKER_VOLUME="${SP11_SPEAKER_VOLUME:-100}"
MAX_RETRIES="${SP11_MAX_RETRIES:-3}"
SOUND_DRIVER="snd-x1e80100"
SOUND_DEVICE="sound"

slave0="/sys/bus/soundwire/devices/sdw:1:0:0217:0204:00:0/status"
slave1="/sys/bus/soundwire/devices/sdw:1:0:0217:0204:00:1/status"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Check if both WSA884x amps are Attached (graph loaded successfully)
slaves_attached() {
	local s0="UNATTACHED" s1="UNATTACHED"
	[ -f "$slave0" ] && s0="$(cat "$slave0" 2>/dev/null || echo UNATTACHED)"
	[ -f "$slave1" ] && s1="$(cat "$slave1" 2>/dev/null || echo UNATTACHED)"
	s0="$(echo "$s0" | tr -d '[:space:]')"
	s1="$(echo "$s1" | tr -d '[:space:]')"
	[ "$s0" = "Attached" ] && [ "$s1" = "Attached" ]
}

# Check for bus clash (graph failed, bus is broken)
bus_clash_detected() {
	dmesg 2>/dev/null | tail -100 | grep -q 'Bus clash'
}

# Wait for the ALSA card to appear (up to 30 seconds)
wait_for_card() {
	local i=0
	while [ "$i" -lt 30 ]; do
		if [ -e "/proc/asound/${CARD}" ] || aplay -l 2>/dev/null | grep -q "$CARD"; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	log "ERROR: ALSA card ${CARD} did not appear within 30s."
	return 1
}

# Wait for the WSA mixer controls to be available (card instantiated)
wait_for_wsa_controls() {
	local i=0
	while [ "$i" -lt 30 ]; do
		if amixer -c "$CARD" sget 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	log "ERROR: WSA mixer controls not available within 30s."
	return 1
}

# Wait for SoundWire slaves to reach Attached, with timeout
wait_for_slaves() {
	local max_wait="${1:-30}"
	local elapsed=0
	log "Waiting for SoundWire slaves to reach Attached (max ${max_wait}s) ..."
	while [ "$elapsed" -lt "$max_wait" ]; do
		if slaves_attached; then
			log "Both WSA884x amps Attached (${elapsed}s)."
			sleep 2
			return 0
		fi
		if bus_clash_detected; then
			log "Bus clash detected at ${elapsed}s — graph failed."
			return 1
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	log "Slaves did not reach Attached within ${max_wait}s."
	return 1
}

# Unbind and rebind the sound card to force a fresh topology load.
# The extra delay before rebind gives the DSP time to fully initialize.
rebind_sound_card() {
	local delay="${1:-10}"

	log "Unbinding sound card driver ..."
	if echo "$SOUND_DEVICE" | tee /sys/bus/platform/drivers/$SOUND_DRIVER/unbind 2>/dev/null; then
		log "Sound card unbound."
	else
		log "WARNING: unbind failed — device may already be unbound."
	fi

	log "Waiting ${delay}s before rebind to let DSP settle ..."
	sleep "$delay"

	log "Rebinding sound card driver ..."
	if echo "$SOUND_DEVICE" | tee /sys/bus/platform/drivers/$SOUND_DRIVER/bind 2>/dev/null; then
		log "Sound card rebound."
		# Wait for the card to fully initialize
		sleep 5
		wait_for_card 2>/dev/null || true
		wait_for_wsa_controls 2>/dev/null || true
		return 0
	else
		log "ERROR: rebind failed."
		return 1
	fi
}

enable_wsa_routing() {
	log "Enabling WSA speaker DMA route (MultiMedia2) ..."
	amixer -c "$CARD" sset 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' on >/dev/null 2>&1 || \
		log "  WARNING: could not set MultiMedia2 route"

	log "Setting WSA macro RX routing ..."
	amixer -c "$CARD" sset 'WSA WSA RX0 MUX' AIF1_PB >/dev/null 2>&1 || true
	amixer -c "$CARD" sset 'WSA WSA RX1 MUX' AIF1_PB >/dev/null 2>&1 || true
	amixer -c "$CARD" sset 'WSA WSA_RX0 INP0' RX0 >/dev/null 2>&1 || true
	amixer -c "$CARD" sset 'WSA WSA_RX1 INP0' RX1 >/dev/null 2>&1 || true

	log "Setting speaker hardware volume to ${SPEAKER_VOLUME}% ..."
	amixer -c "$CARD" sset 'Speakers' "${SPEAKER_VOLUME}%" >/dev/null 2>&1 || true

	if [ "$SPEAKER_VOLUME" -eq 100 ]; then
		log "Hardware volume at 100% — PipeWire/GNOME slider is the sole volume control."
	fi

	# Boost the right speaker PA Volume to match the left.
	# The right amp defaults to a lower PA volume (12/31) than the left
	# (31/31), causing a significant volume imbalance. Match them.
	log "Balancing right speaker PA Volume ..."
	amixer -c "$CARD" sset 'SpkrRight PA' 31 >/dev/null 2>&1 || true

	log "WSA speaker routing enabled."
}

# Restart PipeWire/WirePlubber user services so they connect to the sink
# cleanly after WSA routing is enabled. PipeWire may have started before the
# DSP graph was ready, leaving the sink in a broken state.
#
# Since this service runs at multi-user.target (before user login), we can't
# restart PipeWire directly. Instead, we write a flag file that a user-level
# systemd path will pick up. We also try to restart PipeWire for any already
# logged-in user.
restart_pipewire() {
	# Write a flag file for the user-level service to detect
	local flag="/run/sp11-wsa-routing-done"
	touch "$flag" 2>/dev/null || true
	chmod 0644 "$flag" 2>/dev/null || true
	log "Wrote flag file $flag for user-level PipeWire restart."

	# Also try to restart PipeWire for any already-logged-in user
	local uid user
	uid="$(loginctl list-users --no-legend 2>/dev/null | awk '{print $1; exit}')"
	if [ -n "$uid" ]; then
		user="$(getent passwd "$uid" | cut -d: -f1)"
		if [ -n "$user" ]; then
			log "Restarting PipeWire/WirePlumber for user ${user} (uid=${uid}) ..."
			systemctl --user -M "${user}@" restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
			log "PipeWire restarted."
			return 0
		fi
	fi

	log "No logged-in user yet — flag file written for later PipeWire restart."
}

main() {
	log "Waiting for ALSA card ${CARD} ..."
	wait_for_card || exit 1

	log "Waiting for WSA mixer controls (card instantiated) ..."
	wait_for_wsa_controls || exit 1

	# Try to get a working DSP graph, with retries via rebind
	local attempt=0
	while [ "$attempt" -lt "$MAX_RETRIES" ]; do
		attempt=$((attempt + 1))
		log "Attempt ${attempt}/${MAX_RETRIES}: checking DSP graph state ..."

		if wait_for_slaves 15; then
			log "DSP graph loaded successfully."
			enable_wsa_routing
			restart_pipewire
			log "Done."
			exit 0
		fi

		log "DSP graph failed on attempt ${attempt}."

		if [ "$attempt" -lt "$MAX_RETRIES" ]; then
			local rebind_delay=$((10 + attempt * 5))
			log "Retrying with ${rebind_delay}s DSP settle delay ..."
			rebind_sound_card "$rebind_delay" || true
		fi
	done

	log "ERROR: DSP graph failed to load after ${MAX_RETRIES} attempts."
	log "  Audio will not work. Check: sudo journalctl -b -k | grep -E 'qcom-apm|CMD timeout'"
	log "  Try a full cold shutdown (not reboot) and power on again."
	exit 1
}

main "$@"