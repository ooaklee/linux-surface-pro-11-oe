#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Enable and manage Bluetooth tethering (PAN/NAP) on the Surface Pro 11.
#
# This script:
#   1. Configures /etc/bluetooth/main.conf with JustWorksRepairing and
#      experimental profiles (needed for PAN/NAP)
#   2. Installs bluez-tools (provides bt-pan) if missing
#   3. Ensures the bnep kernel module is loaded
#   4. Provides --connect <mac> to establish a PANU tethering connection
#   5. Provides --status to check tethering state
#
# See docs/adr/adr-0037-bluetooth-tethering-pan-nap.md for the full decision.
set -euo pipefail

ACTION="status"
PHONE_MAC=""
RESTART_BT="true"

usage() {
	cat <<EOF
Usage: $(basename "$0") [OPTIONS] [ACTION]

Enable and manage Bluetooth tethering (PAN/NAP) on the Surface Pro 11.

Actions:
  configure    Configure /etc/bluetooth/main.conf, install bluez-tools,
               load bnep module, restart bluetooth.service. (requires sudo)
  connect      Connect to a phone for tethering. Requires --mac.
               (requires sudo)
  disconnect   Disconnect the tethering interface.
  status       Show current tethering state. (default)

Options:
  --mac MAC    Phone Bluetooth MAC address (AA:BB:CC:DD:EE:FF format)
  --no-restart Do not restart bluetooth.service after configuration
  -h, --help   Show this help.

Setup flow:
  1. sudo $0 configure
  2. Pair and trust your phone via bluetoothctl or GNOME Bluetooth settings
  3. sudo $0 connect --mac <phone-mac>
  4. Internet should work via bnep0

Prerequisites:
  - Bluetooth public address must be set (see ADR-032)
  - Phone must have Bluetooth tethering enabled in its settings
EOF
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

need_root() {
	if [ "$(id -u)" -ne 0 ]; then
		log "ERROR: this action requires root (sudo)."
		exit 1
	fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ── Configure: set up main.conf, bluez-tools, bnep ───────────────────────

do_configure() {
	need_root

	# 1. Configure /etc/bluetooth/main.conf
	local main_conf="/etc/bluetooth/main.conf"
	local need_justworks=true
	local need_experimental=true

	log "Configuring $main_conf ..."

	if [ -f "$main_conf" ]; then
		if grep -q 'JustWorksRepairing' "$main_conf"; then
			need_justworks=false
		fi
		if grep -qi 'Experimental' "$main_conf"; then
			need_experimental=false
		fi
	fi

	if [ "$need_justworks" = true ] || [ "$need_experimental" = true ]; then
		cp "$main_conf" "${main_conf}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

		# Ensure [General] section exists
		if ! grep -q '^\[General\]' "$main_conf" 2>/dev/null; then
			echo "[General]" >> "$main_conf"
		fi

		if [ "$need_justworks" = true ]; then
			log "  Adding JustWorksRepairing = always"
			sed -i '/^\[General\]/a JustWorksRepairing = always' "$main_conf"
		fi

		if [ "$need_experimental" = true ]; then
			log "  Adding Experimental = true"
			if ! grep -q '^\[BlueZ\]' "$main_conf"; then
				echo "" >> "$main_conf"
				echo "[BlueZ]" >> "$main_conf"
			fi
			echo "Experimental = true" >> "$main_conf"
		fi

		log "  $main_conf configured."
	else
		log "  $main_conf already configured."
	fi

	# 2. Install bluez-tools if missing
	if ! have bt-pan; then
		log "Installing bluez-tools ..."
		if have apt; then
			apt update -qq && apt install -y bluez-tools
		elif have dnf; then
			dnf install -y bluez-tools
		elif have pacman; then
			pacman -S --noconfirm bluez-tools
		else
			log "WARNING: Could not install bluez-tools — package manager not found."
			log "  Install bluez-tools manually, then re-run."
		fi
	else
		log "bluez-tools (bt-pan) already installed."
	fi

	# 3. Load bnep kernel module
	log "Loading bnep kernel module ..."
	modprobe bnep 2>/dev/null || log "  WARNING: could not load bnep module (may be built-in)"

	# Ensure bnep loads on boot
	local modules_file="/etc/modules-load.d/bnep.conf"
	if [ ! -f "$modules_file" ]; then
		echo "bnep" > "$modules_file"
		log "  Added bnep to $modules_file for boot-time loading."
	fi

	# 4. Restart Bluetooth if requested
	if [ "$RESTART_BT" = true ]; then
		log "Restarting bluetooth.service ..."
		systemctl restart bluetooth
		sleep 2
		log "Bluetooth restarted."
	fi

	log ""
	log "Configuration complete."
	log "  - JustWorksRepairing = always"
	log "  - Experimental = true (enables PAN/NAP profiles)"
	log "  - bluez-tools installed"
	log "  - bnep module loaded"
	log ""
	log "Next steps:"
	log "  1. Pair and trust your phone via Bluetooth settings or bluetoothctl"
	log "  2. Enable Bluetooth tethering on your phone"
	log "  3. Run: sudo $0 connect --mac <phone-mac>"
}

# ── Connect: establish PANU tethering ────────────────────────────────────

do_connect() {
	need_root

	if [ -z "$PHONE_MAC" ]; then
		log "ERROR: --mac is required for connect."
		exit 2
	fi

	if ! have bt-pan; then
		log "ERROR: bt-pan not found. Run '$0 configure' first."
		exit 1
	fi

	# Verify bnep is loaded
	if ! lsmod 2>/dev/null | grep -q bnep; then
		log "Loading bnep module ..."
		modprobe bnep 2>/dev/null || true
	fi

	# Ensure the phone is paired and trusted
	log "Checking pairing status for $PHONE_MAC ..."
	if have bluetoothctl; then
		local trusted
		trusted="$(bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep 'Trusted:' || echo 'Trusted: no')"
		if echo "$trusted" | grep -qi 'no'; then
			log "  Phone is not trusted. Pairing and trusting ..."
			bluetoothctl pair "$PHONE_MAC" 2>/dev/null || true
			bluetoothctl trust "$PHONE_MAC" 2>/dev/null || true
			bluetoothctl connect "$PHONE_MAC" 2>/dev/null || true
		else
			log "  Phone is already trusted."
		fi
	fi

	# Connect via bt-pan
	log "Establishing PAN tethering connection to $PHONE_MAC ..."
	bt-pan client "$PHONE_MAC" &

	# Wait for bnep0 to appear
	log "Waiting for bnep0 interface ..."
	local i=0
	while [ "$i" -lt 15 ]; do
		if ip link show bnep0 >/dev/null 2>&1; then
			log "bnep0 interface is up."
			break
		fi
		sleep 1
		i=$((i + 1))
	done

	if ! ip link show bnep0 >/dev/null 2>&1; then
		log "ERROR: bnep0 did not appear within 15s."
		log "  Check: bluetoothctl info $PHONE_MAC"
		log "  Check: dmesg | grep -i bnep"
		exit 1
	fi

	# Bring the interface up and get a DHCP lease
	log "Bringing bnep0 up ..."
	ip link set bnep0 up

	# Try NetworkManager first, fall back to dhclient
	if have nmcli && nmcli device status 2>/dev/null | grep -q bnep0; then
		log "Requesting DHCP via NetworkManager ..."
		nmcli device connect bnep0 2>/dev/null || true
	elif have dhclient; then
		log "Requesting DHCP via dhclient ..."
		dhclient bnep0 2>/dev/null || true
	fi

	sleep 2

	# Show the result
	log ""
	log "Tethering connection established."
	ip addr show bnep0 2>/dev/null | grep 'inet ' || log "  WARNING: no IP address on bnep0"

	# Test connectivity
	if ip addr show bnep0 2>/dev/null | grep -q 'inet '; then
		log "Testing connectivity ..."
		if ping -I bnep0 -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
			log "  Internet connectivity: OK"
		else
			log "  WARNING: no internet connectivity via bnep0"
		fi
	fi
}

# ── Disconnect: tear down tethering ──────────────────────────────────────

do_disconnect() {
	need_root

	if ip link show bnep0 >/dev/null 2>&1; then
		log "Disconnecting bnep0 ..."
		ip link set bnep0 down 2>/dev/null || true

		# Kill bt-pan if running
		pkill -f 'bt-pan client' 2>/dev/null || true

		log "bnep0 disconnected."
	else
		log "bnep0 is not present — nothing to disconnect."
	fi
}

# ── Status: show current tethering state ─────────────────────────────────

do_status() {
	echo "=== Bluetooth Tethering Status ==="
	echo ""

	# BlueZ config
	echo "--- BlueZ main.conf ---"
	if [ -f /etc/bluetooth/main.conf ]; then
		grep -E 'JustWorksRepairing|Experimental|Network' /etc/bluetooth/main.conf 2>/dev/null || echo "(no relevant settings found)"
	else
		echo "MISSING: /etc/bluetooth/main.conf"
	fi
	echo ""

	# bt-pan
	echo "--- bluez-tools ---"
	if have bt-pan; then
		echo "bt-pan: $(which bt-pan)"
	else
		echo "bt-pan: NOT INSTALLED (run: sudo $0 configure)"
	fi
	echo ""

	# bnep module
	echo "--- bnep module ---"
	if lsmod 2>/dev/null | grep -q bnep; then
		echo "bnep: loaded"
	else
		echo "bnep: NOT loaded (run: sudo modprobe bnep)"
	fi
	echo ""

	# bnep0 interface
	echo "--- bnep0 interface ---"
	if ip link show bnep0 >/dev/null 2>&1; then
		ip addr show bnep0
	else
		echo "bnep0: not present"
	fi
	echo ""

	# Bluetooth controller
	echo "--- Bluetooth controller ---"
	if have bluetoothctl; then
		bluetoothctl show 2>/dev/null | head -10 || echo "(bluetoothctl failed)"
	else
		echo "bluetoothctl not available"
	fi
}

# ── Argument parsing ─────────────────────────────────────────────────────

while [ "$#" -gt 0 ]; do
	case "$1" in
		--mac)
			[ "$#" -ge 2 ] || { echo "--mac requires a value" >&2; exit 2; }
			PHONE_MAC="$2"
			shift 2
			;;
		--no-restart) RESTART_BT="false"; shift ;;
		-h|--help) usage; exit 0 ;;
		configure|connect|disconnect|status) ACTION="$1"; shift ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$ACTION" in
	configure) do_configure ;;
	connect) do_connect ;;
	disconnect) do_disconnect ;;
	status) do_status ;;
esac