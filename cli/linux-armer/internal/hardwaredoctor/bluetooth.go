package hardwaredoctor

import (
	"context"
	"errors"
	"io/fs"
	"path"
	"regexp"
	"strings"
	"time"
)

const (
	// maximumBluetoothControllers bounds the live HCI controller inventory.
	maximumBluetoothControllers = 32
	// maximumBluetoothAddressBytes bounds the private address read before classification.
	maximumBluetoothAddressBytes int64 = 64
)

// hciEntryPattern admits only canonical kernel HCI controller names.
var hciEntryPattern = regexp.MustCompile(`^hci[0-9]{1,4}$`)

// bluetoothAddressPattern validates a controller address without preserving it.
var bluetoothAddressPattern = regexp.MustCompile(`(?i)^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$`)

// bluetoothControllerState aggregates controller and address quality privately.
type bluetoothControllerState struct {
	// controllers is the bounded HCI controller count.
	controllers int
	// nonPlaceholderAddresses counts addresses outside the known invalid patterns.
	nonPlaceholderAddresses int
	// suspiciousAddresses counts known placeholder address patterns.
	suspiciousAddresses int
	// unavailableAddresses counts controller addresses that could not be classified.
	unavailableAddresses int
	// unavailable records whether controller discovery itself failed.
	unavailable bool
}

// inspectBluetooth reports controller and BlueZ readiness without exposing identities.
func (doctor *Doctor) inspectBluetooth(ctx context.Context, probeTimeout time.Duration) ([]Check, error) {
	checks := make([]Check, 0, 7)
	controllers := doctor.readBluetoothControllers(ctx)
	switch {
	case controllers.unavailable:
		checks = append(checks, Check{ID: "bluetooth-hci-controller", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, State: StateUnavailable, Required: true, Detail: "Bluetooth controller presence could not be inspected safely"})
	case controllers.controllers == 0:
		checks = append(checks, Check{ID: "bluetooth-hci-controller", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "the kernel exposes no Bluetooth HCI controller"})
	default:
		checks = append(checks, Check{ID: "bluetooth-hci-controller", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, State: StatePass, Required: true, Detail: "the kernel exposes a Bluetooth HCI controller"})
	}
	switch {
	case controllers.unavailable || controllers.controllers == 0:
		checks = append(checks, Check{ID: "bluetooth-address-quality", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, State: StateUnavailable, Required: true, Detail: "Bluetooth controller address quality could not be established"})
	case controllers.suspiciousAddresses > 0 && controllers.nonPlaceholderAddresses == 0:
		checks = append(checks, Check{ID: "bluetooth-address-quality", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, State: StateFail, Required: true, Detail: "the controller exposes a known placeholder-like public address", Remediation: "use same-device private Windows evidence through the reviewed Bluetooth address workflow; the doctor never reveals or changes an address"})
	case controllers.nonPlaceholderAddresses > 0 && controllers.suspiciousAddresses > 0:
		checks = append(checks, Check{ID: "bluetooth-address-quality", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, State: StateWarn, Required: false, Detail: "a non-placeholder-like controller address is present alongside another placeholder-like controller"})
	case controllers.nonPlaceholderAddresses > 0 && controllers.unavailableAddresses == 0:
		checks = append(checks, Check{ID: "bluetooth-address-quality", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, State: StatePass, Required: true, Detail: "the controller address does not match a known invalid placeholder pattern"})
	case controllers.nonPlaceholderAddresses > 0:
		checks = append(checks, Check{ID: "bluetooth-address-quality", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, State: StateWarn, Required: false, Detail: "a non-placeholder-like controller address is present, but another controller address was not observable"})
	default:
		checks = append(checks, Check{ID: "bluetooth-address-quality", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, State: StateUnavailable, Required: true, Detail: "Bluetooth controller address quality could not be classified safely"})
	}
	checks = append(checks, doctor.inspectRadioBlock(ctx, FeatureBluetooth, "bluetooth", "bluetooth-rfkill-state"))
	serviceResult, serviceOutcome, err := doctor.runProbe(ctx, ProbeBluetoothService, probeTimeout)
	if err != nil {
		return nil, err
	}
	checks = append(checks, bluetoothServiceCheck(serviceResult, serviceOutcome))
	blueZResult, blueZOutcome, err := doctor.runProbe(ctx, ProbeBlueZControllers, probeTimeout)
	if err != nil {
		return nil, err
	}
	checks = append(checks, blueZControllerCheck(blueZResult, blueZOutcome))
	checks = append(checks, hardwareLimitation(FeatureBluetooth))
	return checks, nil
}

// readBluetoothControllers classifies addresses in memory and never returns them.
func (doctor *Doctor) readBluetoothControllers(ctx context.Context) bluetoothControllerState {
	entries, err := doctor.filesystem.ReadDir(ctx, "/sys/class/bluetooth", maximumBluetoothControllers)
	if errors.Is(err, fs.ErrNotExist) {
		return bluetoothControllerState{}
	}
	if err != nil {
		return bluetoothControllerState{unavailable: true}
	}
	state := bluetoothControllerState{}
	for _, entry := range entries {
		if !hciEntryPattern.MatchString(entry.Name) {
			continue
		}
		state.controllers++
		content, readErr := doctor.filesystem.ReadFile(ctx, path.Join("/sys/class/bluetooth", entry.Name, "address"), maximumBluetoothAddressBytes)
		if readErr != nil {
			state.unavailableAddresses++
			continue
		}
		address := strings.ToUpper(strings.TrimSpace(string(content)))
		if !bluetoothAddressPattern.MatchString(address) {
			state.unavailableAddresses++
			continue
		}
		if suspiciousBluetoothAddress(address) {
			state.suspiciousAddresses++
			continue
		}
		state.nonPlaceholderAddresses++
	}
	return state
}

// suspiciousBluetoothAddress recognises only established invalid placeholders.
func suspiciousBluetoothAddress(address string) bool {
	return strings.HasPrefix(address, "00:00:00:00:") ||
		address == "AA:AA:AA:AA:AA:AA" ||
		address == "AA:BB:CC:DD:EE:FF" ||
		address == "FF:FF:FF:FF:FF:FF"
}

// bluetoothServiceCheck maps systemd exit state to fixed, redacted prose.
func bluetoothServiceCheck(result ProbeResult, outcome probeOutcome) Check {
	check := Check{ID: "bluetooth-bluez-service", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, Required: true}
	switch {
	case outcome == probeTimedOut:
		check.State = StateUnavailable
		check.Detail = "the bounded Bluetooth service-state probe timed out"
	case outcome != probeCompleted:
		check.State = StateUnavailable
		check.Detail = "Bluetooth service state could not be inspected with the fixed probe"
	case result.ExitCode == 0:
		check.State = StatePass
		check.Detail = "the Bluetooth service is active"
	case result.ExitCode == 3:
		check.State = StateFail
		check.Detail = "the Bluetooth service is not active"
		check.Remediation = "review the static BlueZ installation and service journal without publishing device identities"
	default:
		check.State = StateUnavailable
		check.Detail = "the Bluetooth service probe returned an unclassified state"
	}
	return check
}

// blueZControllerCheck reports only whether BlueZ exposes at least one controller.
func blueZControllerCheck(result ProbeResult, outcome probeOutcome) Check {
	check := Check{ID: "bluetooth-bluez-controller", Feature: FeatureBluetooth, Evidence: EvidenceRuntime, Required: true}
	switch {
	case outcome == probeTimedOut:
		check.State = StateUnavailable
		check.Detail = "the bounded BlueZ controller probe timed out"
	case outcome != probeCompleted:
		check.State = StateUnavailable
		check.Detail = "BlueZ controller state could not be inspected with the fixed probe"
	case result.ExitCode != 0:
		check.State = StateFail
		check.Detail = "BlueZ did not return a controller inventory"
	case countBlueZControllers(result.Output) == 0:
		check.State = StateFail
		check.Detail = "BlueZ exposes no controller"
		check.Remediation = "review controller address quality and Bluetooth service ordering"
	default:
		check.State = StatePass
		check.Detail = "BlueZ exposes a controller"
	}
	return check
}

// countBlueZControllers counts inventory markers and discards all identifying text.
func countBlueZControllers(output []byte) int {
	count := 0
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "Controller" && bluetoothAddressPattern.MatchString(fields[1]) {
			count++
		}
	}
	return count
}
