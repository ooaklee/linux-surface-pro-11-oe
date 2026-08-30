package hardwaredoctor

import (
	"context"
	"errors"
	"io/fs"
	"path"
	"regexp"
	"strings"
)

const (
	// maximumPCIDevices bounds PCI-function discovery.
	maximumPCIDevices = 512
	// maximumNetworkInterfaces bounds network-interface discovery.
	maximumNetworkInterfaces = 128
	// maximumDeviceTreeEntries bounds the full breadth-first device-tree walk.
	maximumDeviceTreeEntries = 2048
	// maximumDeviceTreeChildren bounds any one device-tree directory.
	maximumDeviceTreeChildren = 256
	// maximumDeviceTreeDepth prevents unexpected recursive traversal.
	maximumDeviceTreeDepth = 12
	// maximumSysfsValueBytes bounds small sysfs values such as vendor and state.
	maximumSysfsValueBytes int64 = 256
)

// pciFunctionPattern admits only canonical sysfs PCI function names.
var pciFunctionPattern = regexp.MustCompile(`^[0-9A-Fa-f]{4,8}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$`)

// wifiPCIState is the redacted result of WCN7850 PCI discovery.
type wifiPCIState struct {
	// present records whether the audited vendor and device identifiers were found.
	present bool
	// ath12kBound records whether a recognised ath12k driver owns the function.
	ath12kBound bool
	// unavailable records whether discovery could not be completed safely.
	unavailable bool
}

// wifiDeviceTreeState is the redacted loaded-device-tree result.
type wifiDeviceTreeState struct {
	// nodePresent records whether at least one wifi@0 node was found.
	nodePresent bool
	// disableRFKill records whether a matching node carries the integrated property.
	disableRFKill bool
	// unavailable records whether bounded traversal failed.
	unavailable bool
}

// networkInterfaceState aggregates wireless interfaces without retaining names.
type networkInterfaceState struct {
	// present is the number of wireless interfaces observed within the cap.
	present int
	// operational is the number whose kernel operational state is up.
	operational int
	// incomplete records unreadable or invalid interface state.
	incomplete bool
}

// deviceTreeDirectory tracks one bounded breadth-first traversal item.
type deviceTreeDirectory struct {
	// path is the fixed-root logical path under inspection.
	path string
	// depth is the number of directory levels below the device-tree root.
	depth int
}

// inspectWiFi reports WCN7850 presence and readiness without scanning networks.
func (doctor *Doctor) inspectWiFi(ctx context.Context) []Check {
	checks := make([]Check, 0, 7)
	pci := doctor.inspectWiFiPCI(ctx)
	switch {
	case pci.unavailable:
		checks = append(checks, Check{ID: "wifi-wcn7850-pci", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StateUnavailable, Required: true, Detail: "WCN7850 PCI presence could not be established safely"})
	case !pci.present:
		checks = append(checks, Check{ID: "wifi-wcn7850-pci", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "the WCN7850 PCI function is not present"})
	default:
		checks = append(checks, Check{ID: "wifi-wcn7850-pci", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StatePass, Required: true, Detail: "the audited WCN7850 PCI function is present"})
	}
	switch {
	case pci.unavailable:
		checks = append(checks, Check{ID: "wifi-ath12k-driver", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StateUnavailable, Required: true, Detail: "the WCN7850 driver binding could not be established safely"})
	case !pci.present || !pci.ath12kBound:
		checks = append(checks, Check{ID: "wifi-ath12k-driver", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "the WCN7850 function is not bound to a recognised ath12k driver", Remediation: "review the running Surface kernel and firmware with the static userspace doctor"})
	default:
		checks = append(checks, Check{ID: "wifi-ath12k-driver", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StatePass, Required: true, Detail: "the WCN7850 function is bound to a recognised ath12k driver"})
	}
	deviceTree := doctor.inspectWiFiDeviceTree(ctx)
	switch {
	case deviceTree.unavailable:
		checks = append(checks, Check{ID: "wifi-device-tree-rfkill-policy", Feature: FeatureWiFi, Evidence: EvidenceStatic, State: StateUnavailable, Required: true, Detail: "the loaded Wi-Fi device-tree policy could not be inspected safely"})
	case !deviceTree.nodePresent:
		checks = append(checks, Check{ID: "wifi-device-tree-rfkill-policy", Feature: FeatureWiFi, Evidence: EvidenceStatic, State: StateFail, Required: true, Detail: "the loaded device tree does not expose the Surface Wi-Fi node"})
	case !deviceTree.disableRFKill:
		checks = append(checks, Check{ID: "wifi-device-tree-rfkill-policy", Feature: FeatureWiFi, Evidence: EvidenceStatic, State: StateFail, Required: true, Detail: "the loaded Surface Wi-Fi node lacks the integrated disable-rfkill policy", Remediation: "boot the maintained Surface device tree paired with the running kernel"})
	default:
		checks = append(checks, Check{ID: "wifi-device-tree-rfkill-policy", Feature: FeatureWiFi, Evidence: EvidenceStatic, State: StatePass, Required: true, Detail: "the loaded Surface Wi-Fi node carries the integrated disable-rfkill policy"})
	}
	checks = append(checks, doctor.inspectRadioBlock(ctx, FeatureWiFi, "wlan", "wifi-rfkill-state"))
	interfaces := doctor.inspectWirelessInterfaces(ctx)
	switch {
	case interfaces.incomplete && interfaces.present == 0:
		checks = append(checks, Check{ID: "wifi-network-interface", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StateUnavailable, Required: true, Detail: "wireless network-interface state could not be inspected safely"})
	case interfaces.present == 0:
		checks = append(checks, Check{ID: "wifi-network-interface", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "the kernel has not created a wireless network interface"})
	case interfaces.operational == 0:
		checks = append(checks, Check{ID: "wifi-network-interface", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StateWarn, Required: false, Detail: "a wireless network interface is present but is not currently operational"})
	default:
		checks = append(checks, Check{ID: "wifi-network-interface", Feature: FeatureWiFi, Evidence: EvidenceRuntime, State: StatePass, Required: true, Detail: "a wireless network interface is present and operational"})
	}
	checks = append(checks, hardwareLimitation(FeatureWiFi))
	return checks
}

// inspectWiFiPCI finds the audited WCN7850 function and recognises its driver.
func (doctor *Doctor) inspectWiFiPCI(ctx context.Context) wifiPCIState {
	entries, err := doctor.filesystem.ReadDir(ctx, "/sys/bus/pci/devices", maximumPCIDevices)
	if err != nil {
		return wifiPCIState{unavailable: true}
	}
	state := wifiPCIState{}
	incomplete := false
	for _, entry := range entries {
		if !pciFunctionPattern.MatchString(entry.Name) {
			continue
		}
		base := path.Join("/sys/bus/pci/devices", entry.Name)
		vendor, vendorErr := doctor.filesystem.ReadFile(ctx, path.Join(base, "vendor"), maximumSysfsValueBytes)
		device, deviceErr := doctor.filesystem.ReadFile(ctx, path.Join(base, "device"), maximumSysfsValueBytes)
		if vendorErr != nil || deviceErr != nil {
			incomplete = true
			continue
		}
		if strings.ToLower(strings.TrimSpace(string(vendor))) != "0x17cb" || strings.ToLower(strings.TrimSpace(string(device))) != "0x1107" {
			continue
		}
		state.present = true
		target, linkErr := doctor.filesystem.ReadLink(ctx, path.Join(base, "driver"))
		if errors.Is(linkErr, fs.ErrNotExist) {
			continue
		}
		if linkErr != nil {
			state.unavailable = true
			continue
		}
		driver := strings.ToLower(path.Base(strings.ReplaceAll(target, "\\", "/")))
		if driver == "ath12k_pci" || driver == "ath12k_wifi7_pci" {
			state.ath12kBound = true
		}
	}
	if !state.present && incomplete {
		state.unavailable = true
	}
	return state
}

// inspectWiFiDeviceTree finds the loaded wifi@0 node and integrated rfkill policy.
func (doctor *Doctor) inspectWiFiDeviceTree(ctx context.Context) wifiDeviceTreeState {
	queue := []deviceTreeDirectory{{path: "/sys/firmware/devicetree/base", depth: 0}}
	visited := 0
	state := wifiDeviceTreeState{}
	for len(queue) != 0 {
		current := queue[0]
		queue = queue[1:]
		entries, err := doctor.filesystem.ReadDir(ctx, current.path, maximumDeviceTreeChildren)
		if err != nil {
			return wifiDeviceTreeState{unavailable: true}
		}
		visited += len(entries)
		if visited > maximumDeviceTreeEntries {
			return wifiDeviceTreeState{unavailable: true}
		}
		for _, entry := range entries {
			if !safeLeaf(entry.Name) || entry.Kind != PathDirectory {
				continue
			}
			child := path.Join(current.path, entry.Name)
			if entry.Name == "wifi@0" {
				state.nodePresent = true
				if _, statErr := doctor.filesystem.Stat(ctx, path.Join(child, "disable-rfkill")); statErr == nil {
					state.disableRFKill = true
					return state
				} else if !errors.Is(statErr, fs.ErrNotExist) {
					state.unavailable = true
				}
			}
			if current.depth < maximumDeviceTreeDepth {
				queue = append(queue, deviceTreeDirectory{path: child, depth: current.depth + 1})
			}
		}
	}
	return state
}

// inspectWirelessInterfaces aggregates only presence and operational state.
func (doctor *Doctor) inspectWirelessInterfaces(ctx context.Context) networkInterfaceState {
	entries, err := doctor.filesystem.ReadDir(ctx, "/sys/class/net", maximumNetworkInterfaces)
	if err != nil {
		return networkInterfaceState{incomplete: true}
	}
	state := networkInterfaceState{}
	for _, entry := range entries {
		if !safeLeaf(entry.Name) {
			state.incomplete = true
			continue
		}
		base := path.Join("/sys/class/net", entry.Name)
		info, statErr := doctor.filesystem.Stat(ctx, path.Join(base, "wireless"))
		if errors.Is(statErr, fs.ErrNotExist) {
			continue
		}
		if statErr != nil || info.Kind != PathDirectory {
			state.incomplete = true
			continue
		}
		state.present++
		operational, readErr := doctor.filesystem.ReadFile(ctx, path.Join(base, "operstate"), maximumSysfsValueBytes)
		if readErr != nil {
			state.incomplete = true
			continue
		}
		if strings.TrimSpace(string(operational)) == "up" {
			state.operational++
		}
	}
	return state
}
