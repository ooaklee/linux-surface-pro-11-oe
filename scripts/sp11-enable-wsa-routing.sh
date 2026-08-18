#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Configure and exercise the Surface Pro 11 WSA speaker path before the
# desktop sound server opens the PCM.
#
# AudioReach graphs are created lazily when a PCM is opened.  SoundWire
# "Attached" and the presence of topology mixer controls are prerequisites,
# not proof that either the MultiMedia2 or WSA graph opened.  This helper
# therefore applies the complete WSA route while PCM1 is closed and opens a
# short silent stream to exercise GRAPH_OPEN/PREPARE/START and the WSA DAPM
# path.  A failed probe is retried with a fresh PCM open; a machine-card
# rebind is reserved for repeated failures.
set -euo pipefail

CARD="${SP11_ALSA_CARD:-X1E80100Microso}"
PCM="hw:${CARD},1"
MAX_RETRIES="${SP11_MAX_RETRIES:-3}"
PA_VOLUME="${SP11_PA_VOLUME:-6}"
SOUND_DRIVER="${SP11_SOUND_DRIVER:-snd-x1e80100}"
SOUND_DEVICE="${SP11_SOUND_DEVICE:-sound}"
SOUND_DRIVER_DIR="/sys/bus/platform/drivers/${SOUND_DRIVER}"
FLAG="${SP11_ROUTING_FLAG:-/run/sp11-wsa-routing-done}"

slave0="/sys/bus/soundwire/devices/sdw:1:0:0217:0204:00:0/status"
slave1="/sys/bus/soundwire/devices/sdw:1:0:0217:0204:00:1/status"
slave0_power="/sys/bus/soundwire/devices/sdw:1:0:0217:0204:00:0/power/runtime_status"
slave1_power="/sys/bus/soundwire/devices/sdw:1:0:0217:0204:00:1/power/runtime_status"
pcm_status="/proc/asound/${CARD}/pcm1p/sub0/status"
wsa_dapm="/sys/devices/platform/sound/WSA Playback/dapm_widget"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

slaves_attached() {
	local s0="UNATTACHED" s1="UNATTACHED"
	[ -f "$slave0" ] && read -r s0 < "$slave0"
	[ -f "$slave1" ] && read -r s1 < "$slave1"
	[ "$s0" = "Attached" ] && [ "$s1" = "Attached" ]
}

wait_for_slaves() {
	local max_wait="${1:-30}" elapsed=0

	log "Waiting for both WSA884x SoundWire slaves (max ${max_wait}s) ..."
	while [ "$elapsed" -lt "$max_wait" ]; do
		if slaves_attached; then
			log "Both WSA884x slaves are Attached (bus prerequisite met)."
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	log "ERROR: both WSA884x slaves did not attach within ${max_wait}s."
	return 1
}

wait_for_card() {
	local i=0
	while [ "$i" -lt 30 ]; do
		# /proc/asound may outlive the usable control/PCM device nodes across
		# a rebind.  Require alsa-lib to enumerate the requested card.
		if aplay -l 2>/dev/null | grep -Fq "$CARD"; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	log "ERROR: ALSA card ${CARD} did not appear within 30s."
	return 1
}

wait_for_wsa_controls() {
	local i=0
	while [ "$i" -lt 30 ]; do
		if amixer -c "$CARD" cget \
			"name='WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2'" \
			>/dev/null 2>&1; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	log "ERROR: WSA mixer controls did not appear within 30s."
	return 1
}

wait_for_pcm_closed() {
	local i=0 state="closed"
	while [ "$i" -lt 50 ]; do
		if [ -r "$pcm_status" ]; then
			state="$(sed -n 's/^state:[[:space:]]*//p' "$pcm_status")"
			# ALSA prints the single word "closed" instead of a state field
			# when no substream owns the PCM.
			[ -n "$state" ] || state="closed"
		else
			state="closed"
		fi
		if [ "$state" = "closed" ]; then
			return 0
		fi
		sleep 0.1
		i=$((i + 1))
	done
	log "ERROR: ${PCM} is still ${state}; stop PipeWire/other PCM holders first."
	return 1
}

cset() {
	local name="$1" value="$2" output

	if ! output="$(amixer -c "$CARD" cset "name='${name}'" "$value" 2>&1)"; then
		log "ERROR: failed to set '${name}' to '${value}'."
		printf '%s\n' "$output" >&2
		return 1
	fi
}

enable_wsa_routing() {
	if ! [[ "$PA_VOLUME" =~ ^[0-6]$ ]]; then
		log "ERROR: SP11_PA_VOLUME must be an integer from 0 through 6."
		return 1
	fi

	log "Applying complete WSA macro and two-amplifier sequence ..."

	# Build graph_info from a known state.  This must happen while PCM1 is
	# closed because the FE-to-BE connection is serialized by GRAPH_OPEN.
	cset 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' 0
	cset 'WSA WSA RX0 MUX' AIF1_PB
	cset 'WSA WSA RX1 MUX' AIF1_PB
	cset 'WSA WSA_RX0 INP0' RX0
	cset 'WSA WSA_RX1 INP0' RX1
	cset 'WSA WSA_COMP1 Switch' 1
	cset 'WSA WSA_COMP2 Switch' 1
	cset 'WSA WSA_RX0 Digital Volume' 81
	cset 'WSA WSA_RX1 Digital Volume' 81
	cset 'WSA WSA_RX0 Digital Mute' 0
	cset 'WSA WSA_RX1 Digital Mute' 0

	for amp in SpkrLeft SpkrRight; do
		cset "${amp} COMP Switch" 1
		cset "${amp} BOOST Switch" 1
		cset "${amp} DAC Switch" 1
		cset "${amp} PBR Switch" 1
		cset "${amp} VISENSE Switch" 0
		cset "${amp} WSA MODE" Speaker
		# x1e80100.c caps this control at 6 (0 dB).  The old values 12
		# and 31 are rejected by the current kernel.
		cset "${amp} PA Volume" "$PA_VOLUME"
	done

	cset 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' 1
	log "WSA controls applied (PA=${PA_VOLUME}/6, digital gain=-3 dB)."
}

journal_cursor() {
	journalctl -k -b -n 0 --show-cursor --no-pager 2>/dev/null |
		sed -n 's/^-- cursor: //p'
}

probe_has_apm_error() {
	local cursor="$1" output
	[ -n "$cursor" ] || return 1

	output="$(journalctl -k -b --after-cursor="$cursor" --no-pager 2>/dev/null || true)"
	printf '%s\n' "$output" | grep -Eq \
		'CMD timeout for \[100100[0-6]\]|DSP returned error\[100100[0-6]\]|Error \([^)]+\) Processing 0x0?100100[0-6] cmd|Failed to (set media format|prepare Graph|Start Graph|stop APM port|start APM port)'
}

probe_graph() {
	local cursor probe_log pid rc=0 saw_running=0 saw_wsa=0 saw_slaves_active=0

	cursor="$(journal_cursor || true)"
	probe_log="$(mktemp /tmp/sp11-wsa-probe.XXXXXX)"
	log "Opening a two-second silent stream on ${PCM} to exercise AudioReach ..."

	timeout 15 aplay -q -D "$PCM" -t raw -f S16_LE -r 48000 -c 4 -d 2 \
		/dev/zero >"$probe_log" 2>&1 &
	pid=$!

	while kill -0 "$pid" 2>/dev/null; do
		if [ -r "$pcm_status" ] && grep -q '^state:[[:space:]]*RUNNING' "$pcm_status"; then
			saw_running=1
		fi
		if [ -r "$wsa_dapm" ] &&
			grep -q '^SpkrLeft SPKR: On' "$wsa_dapm" &&
			grep -q '^SpkrRight SPKR: On' "$wsa_dapm"; then
			saw_wsa=1
		fi
		if [ -r "$slave0_power" ] && [ -r "$slave1_power" ] &&
			[ "$(cat "$slave0_power")" = active ] &&
			[ "$(cat "$slave1_power")" = active ]; then
			saw_slaves_active=1
		fi
		sleep 0.05
	done

	wait "$pid" || rc=$?

	if [ "$rc" -ne 0 ]; then
		log "ERROR: silent PCM probe failed with status ${rc}."
		sed -n '1,80p' "$probe_log" >&2
		rm -f "$probe_log"
		return 1
	fi
	rm -f "$probe_log"
	# Teardown errors can be emitted after aplay exits and q6apm drops the
	# graph references.  Give journald a bounded moment to publish them.
	sleep 0.5

	if probe_has_apm_error "$cursor"; then
		log "ERROR: AudioReach reported a graph lifecycle/SET_CFG failure."
		journalctl -k -b --after-cursor="$cursor" --no-pager 2>/dev/null |
			grep -E 'qcom-apm|CMD timeout|DSP returned|Processing 0x0?100100|Failed to (set media format|prepare Graph|Start Graph|stop APM port|start APM port)' >&2 || true
		return 1
	fi

	if [ "$saw_running" -ne 1 ]; then
		log "ERROR: PCM1 was never observed in RUNNING state."
		return 1
	fi
	if [ -r "$wsa_dapm" ] && [ "$saw_wsa" -ne 1 ]; then
		log "ERROR: both WSA speaker DAPM endpoints were not observed On."
		return 1
	fi
	if [ -r "$slave0_power" ] && [ -r "$slave1_power" ] &&
		[ "$saw_slaves_active" -ne 1 ]; then
		log "WARNING: WSA DAPM powered, but both amp runtime states were not sampled active."
	fi

	log "PCM ran, both WSA endpoints powered, and no graph command failure was observed."
	log "This proves the digital/DAPM path, not acoustic output or amplifier health."
	return 0
}

rebind_sound_card() {
	local delay="${1:-3}"

	[ -w "${SOUND_DRIVER_DIR}/unbind" ] && [ -w "${SOUND_DRIVER_DIR}/bind" ] || {
		log "ERROR: cannot write ${SOUND_DRIVER_DIR}/{unbind,bind}."
		return 1
	}

	log "Rebinding the machine sound card after repeated PCM probe failures ..."
	log "This reloads host topology/graph state; it does not reset either WSA PA."
	printf '%s\n' "$SOUND_DEVICE" > "${SOUND_DRIVER_DIR}/unbind"
	sleep "$delay"
	printf '%s\n' "$SOUND_DEVICE" > "${SOUND_DRIVER_DIR}/bind"
	wait_for_card
	wait_for_wsa_controls
	wait_for_slaves 15
}

write_pipewire_flag() {
	if touch "$FLAG" 2>/dev/null; then
		chmod 0644 "$FLAG" 2>/dev/null || true
		log "Wrote ${FLAG} for the compatibility user restart unit."
	else
		log "WARNING: cannot write ${FLAG}; route validation still succeeded."
	fi
}

main() {
	local attempt=1

	rm -f "$FLAG" 2>/dev/null || true
	command -v amixer >/dev/null || { log 'ERROR: amixer is required.'; exit 1; }
	command -v aplay >/dev/null || { log 'ERROR: aplay is required.'; exit 1; }
	if ! [[ "$MAX_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
		log 'ERROR: SP11_MAX_RETRIES must be a positive integer.'
		exit 1
	fi

	log "Waiting for ALSA card ${CARD} ..."
	wait_for_card
	wait_for_wsa_controls
	if ! wait_for_slaves 30; then
		# Attachment is only a bus prerequisite, but an old card instance can
		# still prevent a usable DAI link from being assembled.  Try this once;
		# it is not a codec/PA reset.
		log 'Retrying SoundWire/card assembly with one machine-card rebind.'
		rebind_sound_card 3
	fi

	while [ "$attempt" -le "$MAX_RETRIES" ]; do
		log "WSA graph probe attempt ${attempt}/${MAX_RETRIES}."
		wait_for_pcm_closed
		enable_wsa_routing

		if probe_graph; then
			write_pipewire_flag
			log 'Surface Pro 11 WSA route is ready.'
			exit 0
		fi

		if [ "$attempt" -eq 1 ] && [ "$MAX_RETRIES" -gt 1 ]; then
			# Closing the failed PCM drops q6apm graph references.  A fresh
			# open is the least invasive and normally sufficient retry.
			log 'Fresh PCM retry in 3 seconds (no card rebind yet).'
			sleep 3
		elif [ "$attempt" -lt "$MAX_RETRIES" ]; then
			rebind_sound_card 3
		fi

		attempt=$((attempt + 1))
	done

	log "ERROR: WSA graph/path validation failed after ${MAX_RETRIES} attempts."
	log "Inspect: journalctl -k -b | grep -E '100100[0-6]|qcom-apm|soundwire|wsa'"
	exit 1
}

main "$@"
