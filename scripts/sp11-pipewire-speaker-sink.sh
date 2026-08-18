#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d"
CONFIG_FILE="$CONFIG_DIR/50-sp11-speakers.conf"
WP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
WP_CONFIG_FILE="$WP_CONFIG_DIR/51-sp11-no-duplicate-output.conf"
PCM="${SP11_PIPEWIRE_PCM:-hw:X1E80100Microso,1}"
CARD="${SP11_ALSA_CARD:-X1E80100Microso}"
RESTART="true"
ACTION="install"
ENABLE_ROUTE="false"
PIPEWIRE_STOPPED="false"

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install or remove a user-level PipeWire speaker sink for Surface Pro 11 audio.

This is a stop-gap for the current UCM/ACP state where PipeWire sees the
X1E80100 card but does not automatically create a speaker sink. It writes only
to the current user's ~/.config/pipewire directory and does not require sudo.

Options:
  --install          Install the manual sink config (default).
  --remove           Remove the manual sink config.
  --pcm PCM          ALSA PCM to wrap, default: ${PCM}
  --card CARD        ALSA card used for route setup, default: ${CARD}
  --enable-route     Enable the WSA speaker DSP route with amixer.
  --no-restart       Do not restart user PipeWire/WirePlumber services.
  -h, --help         Show this help.

After install, select "Surface Pro 11 Speakers" in GNOME or wpctl.
Keep volume low while testing; this does not add speaker protection.
EOF
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

have() {
	command -v "$1" >/dev/null 2>&1
}

restart_pipewire() {
	if [ "$RESTART" != "true" ]; then
		return
	fi

	if have systemctl; then
		if ! systemctl --user restart pipewire.service pipewire-pulse.service \
			wireplumber.service 2>/dev/null && \
			! systemctl --user restart pipewire.service wireplumber.service \
			2>/dev/null; then
			log "ERROR: could not restart PipeWire/WirePlumber."
			return 1
		fi
		PIPEWIRE_STOPPED="false"
	else
		log "systemctl not found; restart PipeWire manually."
	fi
}

stop_pipewire() {
	if [ "$RESTART" != "true" ]; then
		log "--no-restart selected; PCM1 must already be closed before route setup."
		return
	fi
	if have systemctl; then
		# Stop the activation sockets too: leaving them listening can reopen
		# PCM1 between the service stop and the route update.
		systemctl --user stop wireplumber.service pipewire-pulse.service \
			pipewire-pulse.socket pipewire.service pipewire.socket \
			2>/dev/null || true
		PIPEWIRE_STOPPED="true"
	fi
}

restore_pipewire_on_exit() {
	if [ "$PIPEWIRE_STOPPED" = "true" ]; then
		restart_pipewire
	fi
}

require_pcm_closed() {
	local status="/proc/asound/${CARD}/pcm1p/sub0/status" state="closed"

	if [ -r "$status" ]; then
		state="$(sed -n 's/^state:[[:space:]]*//p' "$status")"
		[ -n "$state" ] || state="closed"
	fi
	if [ "$state" != "closed" ]; then
		log "ERROR: PCM1 is ${state}; stop every ALSA/PipeWire holder first."
		return 1
	fi
}

cset() {
	local name="$1" value="$2"
	amixer -c "$CARD" cset "name='${name}'" "$value" >/dev/null
}

enable_route() {
	if [ "$ENABLE_ROUTE" != "true" ]; then
		return
	fi
	if ! have amixer; then
		log "WARNING: amixer not found; cannot enable WSA route."
		return
	fi

	# The FE-to-BE connection is serialized when AudioReach opens the graph.
	# Stop existing holders and apply the route before a fresh PCM open.
	stop_pipewire
	trap restore_pipewire_on_exit EXIT
	require_pcm_closed
	log "Applying the complete WSA route on card ${CARD}."
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
		cset "${amp} PA Volume" 6
	done

	cset 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' 1
}

install_config() {
	mkdir -p "$CONFIG_DIR"
	cat > "$CONFIG_FILE" <<EOF
# Surface Pro 11 manual speaker sink.
#
# Uses the 4-channel speaker PCM (hw:X1E80100Microso,1).
# Channel mapping (verified 2026-06-19):
#   ch0 = Left physical speaker
#   ch1 = unused
#   ch2 = Right physical speaker
#   ch3 = unused
#
# The audio.position labels [ FL RL FR RR ] are intentionally reordered so
# that PipeWire's channelmix routes the summed mono signal to both ch0
# (left speaker) and ch2 (right speaker). With the default [ FL FR RL RR ]
# ordering, PipeWire sends front-right content to physical slot ch1 rather
# than the right speaker on ch2.  This is channel-slot mapping, not a DAPM
# bypass.
#
# Mix-matrix sums stereo L+R to both speakers for mono output on each.
#
# IMPORTANT: The WSA route must be set while PCM1 is closed, before the next
# lazy AudioReach graph open.  sp11-wsa-routing.service configures and probes
# it before the display manager starts.  Otherwise use --enable-route with no
# audio clients running.
context.objects = [
    { factory = adapter
        args = {
            factory.name           = api.alsa.pcm.sink
            node.name              = "alsa_output.sp11_speakers"
            node.description       = "Surface Pro 11 Speakers"
            media.class            = "Audio/Sink"
            api.alsa.path          = "${PCM}"
            api.alsa.disable-mmap  = true
            api.alsa.period-size   = 1024
            api.alsa.headroom      = 1024
            audio.channels         = 4
            audio.position         = [ FL RL FR RR ]
            channelmix.normalize   = false
            channelmix.mix-matrix  = "[ 0.5 0.5, 0.0 0.0, 0.5 0.5, 0.0 0.0 ]"
            object.linger          = true
        }
    }
]
EOF
	log "Installed $CONFIG_FILE"

	mkdir -p "$WP_CONFIG_DIR"
	cat > "$WP_CONFIG_FILE" <<'EOF'
# The manual Surface sink owns hw:0,1.  Disable WirePlumber's duplicate
# Pro Audio node for the same PCM to avoid exclusive-open EBUSY failures.
monitor.alsa.rules = [
    {
        matches = [
            { node.name = "~alsa_output.platform-sound.pro-output-1.*" }
        ]
        actions = {
            update-props = {
                node.disabled = true
            }
        }
    }
]
EOF
	log "Installed $WP_CONFIG_FILE"
	enable_route
	restart_pipewire
	trap - EXIT
}

remove_config() {
	local removed="false"
	if [ -f "$CONFIG_FILE" ]; then
		rm -f "$CONFIG_FILE"
		log "Removed $CONFIG_FILE"
		removed="true"
	fi
	if [ -f "$WP_CONFIG_FILE" ]; then
		rm -f "$WP_CONFIG_FILE"
		log "Removed $WP_CONFIG_FILE"
		removed="true"
	fi
	if [ "$removed" = "false" ]; then
		log "No config to remove: $CONFIG_FILE"
	fi
	restart_pipewire
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--install) ACTION="install"; shift ;;
		--remove) ACTION="remove"; shift ;;
		--pcm)
			[ "$#" -ge 2 ] || { echo "--pcm requires a value" >&2; exit 2; }
			PCM="$2"
			shift 2
			;;
		--card)
			[ "$#" -ge 2 ] || { echo "--card requires a value" >&2; exit 2; }
			CARD="$2"
			shift 2
			;;
		--enable-route) ENABLE_ROUTE="true"; shift ;;
		--no-restart) RESTART="false"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$ACTION" in
	install) install_config ;;
	remove) remove_config ;;
esac
