#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d"
CONFIG_FILE="$CONFIG_DIR/50-sp11-speakers.conf"
PCM="${SP11_PIPEWIRE_PCM:-hw:X1E80100Microso,1}"
CARD="${SP11_ALSA_CARD:-X1E80100Microso}"
RESTART="true"
ACTION="install"
ENABLE_ROUTE="false"

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
		systemctl --user restart pipewire wireplumber 2>/dev/null || \
			systemctl --user restart pipewire pipewire-pulse 2>/dev/null || true
	else
		log "systemctl not found; restart PipeWire manually."
	fi
}

enable_route() {
	if [ "$ENABLE_ROUTE" != "true" ]; then
		return
	fi
	if ! have amixer; then
		log "WARNING: amixer not found; cannot enable WSA route."
		return
	fi

	log "Enabling WSA speaker DMA route (MultiMedia2) on card ${CARD}."
	amixer -c "$CARD" cset name='WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' on 2>/dev/null || true

	log "Setting WSA macro RX routing on card ${CARD}."
	amixer -c "$CARD" cset name='WSA WSA RX0 MUX' AIF1_PB 2>/dev/null || true
	amixer -c "$CARD" cset name='WSA WSA RX1 MUX' AIF1_PB 2>/dev/null || true
	amixer -c "$CARD" cset name='WSA WSA_RX0 INP0' RX0 2>/dev/null || true
	amixer -c "$CARD" cset name='WSA WSA_RX1 INP0' RX1 2>/dev/null || true

	log "Enabling right speaker amplifier controls on card ${CARD}."
	amixer -c "$CARD" cset name='SpkrRight PBR Switch' on 2>/dev/null || true
	amixer -c "$CARD" cset name='SpkrRight PA Volume' 12 2>/dev/null || true
}

install_config() {
	mkdir -p "$CONFIG_DIR"
	cat > "$CONFIG_FILE" <<EOF
# Surface Pro 11 manual speaker sink.
#
# Uses the 4-channel speaker PCM (hw:X1E80100Microso,1).
# Only ch0+ch1 produce audio (left speaker). ch2+ch3 are silent at the
# kernel level (suspected topology/SoundWire port mapping or regmap issue).
# Mix-matrix sums stereo to left-mono on ch0+ch1, zeroes ch2+ch3.
# See docs/adr/adr-0034-wsa2-regcache-right-speaker.md.
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
            audio.position         = [ FL FR RL RR ]
            channelmix.normalize   = false
            channelmix.mix-matrix  = "[ 0.5 0.5, 0.5 0.5, 0.0 0.0, 0.0 0.0 ]"
            object.linger          = true
        }
    }
]
EOF
	log "Installed $CONFIG_FILE"
	enable_route
	restart_pipewire
}

remove_config() {
	if [ -f "$CONFIG_FILE" ]; then
		rm -f "$CONFIG_FILE"
		log "Removed $CONFIG_FILE"
	else
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
