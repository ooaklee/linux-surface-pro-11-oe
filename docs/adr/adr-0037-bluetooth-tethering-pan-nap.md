---
id: adr-0037-bluetooth-tethering-pan-nap
title: "ADR0037: Bluetooth Tethering — PAN/NAP Profile Enablement"
# prettier-ignore
description: Architecture Decision Record (ADR) for enabling Bluetooth tethering (PAN/NAP) on the Surface Pro 11 with Qualcomm WCN7850.
---

# ADR0037: Bluetooth Tethering — PAN/NAP Profile Enablement

## Status

Accepted — Initial implementation (2026-06-19). Bluetooth PAN tethering
enabled via BlueZ `main.conf` profile configuration and `bluez-tools`
(`bt-pan`) for network interface creation.

## Context

The Surface Pro 11 Bluetooth stack was brought up in ADR-024 through
ADR-032, culminating in a raw mgmt-socket C helper that sets the public
Bluetooth address on cold boot before `bluetooth.service` starts. This
resolved the controller initialization problem — BlueZ reports a powered
public controller with the correct MAC address.

However, all profile-level functionality was explicitly listed as
unvalidated future work. The repo contained no tethering infrastructure:

- No `/etc/bluetooth/main.conf` configuration
- No PAN (Personal Area Network) / NAP (Network Access Point) profile
- No `bnep` (Bluetooth Network Encapsulation Protocol) interface setup
- No `bt-pan` or `bluez-tools` dependency
- No network bridge or DHCP configuration for the Bluetooth interface

### Problem

Bluetooth tethering fails with "connection failed" when attempting to
tether from a phone to the Surface Pro 11. The root causes are:

1. **PAN/NAP profiles not enabled** — BlueZ does not load the Network
   Access Point profile by default. The `main.conf` file either does not
   exist or does not enable the networking profiles.

2. **No `bnep0` interface creation** — Even when the Bluetooth connection
   is established, Linux needs the `bnep` kernel module and a network
   bridge to create the `bnep0` interface that carries IP traffic.

3. **NetworkManager conflicts** — NetworkManager may not automatically
   manage the `bnep0` interface, or may conflict with BlueZ's network
   management.

4. **JustWorksRepairing** — Some phone-to-PC tethering connections fail
   during pairing due to strict SSP (Secure Simple Pairing) defaults.
   Setting `JustWorksRepairing = always` in `main.conf` allows the
   connection to proceed without interactive confirmation.

## Decision

We will enable Bluetooth tethering through three layers:

### 1. BlueZ `main.conf` configuration

Create `/etc/bluetooth/main.conf` with:

```ini
[General]
JustWorksRepairing = always

[BlueZ]
# Enable PAN profiles
Experimental = true
```

The `JustWorksRepairing = always` setting allows tethering connections
to proceed without interactive pairing confirmation, which is needed
for automated tethering from phones that don't support the full SSP
interactive flow with PCs.

`Experimental = true` enables experimental profiles including the
Network Server (NAP) profile that BlueZ exposes via D-Bus.

### 2. `bluez-tools` for `bt-pan`

Install `bluez-tools` which provides the `bt-pan` command-line utility.
`bt-pan` creates the `bnep0` network interface by connecting to the
phone's NAP service via the PANU (Personal Area Networking User) role.

```bash
sudo apt install bluez-tools
sudo bt-pan client <phone-mac>
```

This creates a `bnep0` interface that can then be configured by
NetworkManager or systemd-networkd for DHCP.

### 3. NetworkManager integration

Ensure NetworkManager manages the `bnep0` interface by adding it to
the unmanaged-devices exception (if it's being ignored):

```bash
# Check if bnep0 is unmanaged
nmcli device status | grep bnep

# If unmanaged, ensure NetworkManager is allowed to manage it
# (bnep* interfaces are managed by default if no MAC-match blocklist exists)
```

## Implementation

### Script: `scripts/sp11-bluetooth-tethering.sh`

A helper script that:
1. Checks for and installs `bluez-tools` if missing
2. Configures `/etc/bluetooth/main.conf` with the required settings
3. Restarts `bluetooth.service`
4. Provides `--connect <mac>` to establish a PANU tethering connection
5. Provides `--status` to check tethering state

### Manual setup flow

```bash
# 1. Configure BlueZ
sudo ./scripts/sp11-bluetooth-tethering.sh --configure

# 2. Restart Bluetooth
sudo systemctl restart bluetooth

# 3. Pair and trust the phone
bluetoothctl
[bluetooth]# agent on
[bluetooth]# default-agent
[bluetooth]# scan on
[bluetooth]# pair <phone-mac>
[bluetooth]# trust <phone-mac>
[bluetooth]# connect <phone-mac>
[bluetooth]# quit

# 4. Establish the PAN tethering connection
sudo bt-pan client <phone-mac>

# 5. The bnep0 interface should appear
ip addr show bnep0

# 6. NetworkManager should get a DHCP lease automatically
# Or manually:
sudo dhclient bnep0
```

## Verification

| Check | Expected |
|---|---|
| `bt-pan` installed | `which bt-pan` returns `/usr/bin/bt-pan` |
| `main.conf` configured | `grep JustWorksRepairing /etc/bluetooth/main.conf` |
| Phone paired and trusted | `bluetoothctl info <mac>` shows `Trusted: yes` |
| `bt-pan client <mac>` succeeds | `bnep0` interface appears |
| DHCP lease obtained | `ip addr show bnep0` shows an IP address |
| Internet connectivity | `ping -I bnep0 8.8.8.8` succeeds |

## Consequences

### Positive

- Bluetooth tethering from a phone provides network access when Wi-Fi
  is unavailable or during kernel/firmware rebuilds
- The `main.conf` configuration is standard BlueZ and does not affect
  the cold-boot public address bring-up (ADR-032)
- `bt-pan` is a lightweight tool that creates the network interface
  without requiring a separate daemon

### Negative

- `JustWorksRepairing = always` reduces pairing security — any device
  can pair without confirmation. This is acceptable for a development
  device but not for production use
- The `bnep` kernel module must be loaded; if it's missing, `bt-pan`
  will fail with an obscure error
- NetworkManager may need manual intervention to manage `bnep0` on
  some Ubuntu versions

### Neutral

- Bluetooth tethering bandwidth is limited (~1-3 Mbps) compared to
  Wi-Fi or USB tethering
- The phone's Bluetooth tethering toggle must remain active
- This is independent of the audio boot race fix (ADR-0035) and the
  speaker workaround (ADR-0036)

## References

- [ADR-027](adr-0027-bluetooth-public-address.md) — Bluetooth public address
- [ADR-032](adr-0032-raw-mgmt-socket-bluetooth-cold-boot.md) — Cold-boot solution
- `scripts/sp11-bluetooth-tethering.sh` — tethering helper script
- BlueZ PAN profile: <https://wiki.archlinux.org/title/Bluetooth#PAN>
- `bluez-tools` / `bt-pan`: <https://github.com/khvzak/bt-pan-utils>