package status

import (
	debugelf "debug/elf"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	handoffapplication "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff/application"
)

const (
	// maximumNativeBluetoothConfigBytes bounds metadata for the protected local
	// address configuration without reading its private contents.
	maximumNativeBluetoothConfigBytes int64 = 512
	// maximumNativeBluetoothUnitBytes bounds the fixed systemd unit inspection.
	maximumNativeBluetoothUnitBytes int64 = 16 << 10
	// maximumNativeBluetoothBinaryBytes rejects implausibly large helper copies
	// before parsing their ELF metadata.
	maximumNativeBluetoothBinaryBytes int64 = 128 << 20
)

// nativeBluetoothPaths lists every fixed object installed by native hand-off
// application without including the private address value.
var nativeBluetoothPaths = []string{
	handoffapplication.BluetoothConfigPath,
	handoffapplication.InstalledBinaryPath,
	handoffapplication.BluetoothUnitPath,
	handoffapplication.BluetoothWantsPath,
}

// nativeBluetoothUnitMarkers identify the compiled service contract without
// coupling status to harmless description or timeout wording changes.
var nativeBluetoothUnitMarkers = []string{
	"ConditionPathExists=/etc/linux-armer/private/bluetooth-address.json",
	"Before=bluetooth.service",
	"ExecStart=/usr/libexec/linux-armer/linux-armer handoff internal-bluetooth-address",
	"NoNewPrivileges=true",
	"PrivateTmp=true",
	"ProtectHome=true",
}

// inspectNativeBluetoothIntegration validates the four-object native hand-off
// integration while deliberately leaving the protected address bytes unread.
func inspectNativeBluetoothIntegration(fs *rootedFS, required bool) (Check, error) {
	present := 0
	for _, logical := range nativeBluetoothPaths {
		_, _, err := fs.lstat(logical)
		if missing(err) {
			continue
		}
		if err != nil {
			return Check{}, err
		}
		present++
	}
	check := Check{
		ID:          "bluetooth-native-handoff-integration",
		Feature:     FeatureBluetooth,
		Required:    required,
		Remediation: "apply trusted same-device hand-off material with linux-armer handoff apply",
	}
	if present == 0 {
		check.State = StateSkip
		check.Detail = "native private hand-off Bluetooth integration is not installed; the protected address value was not read"
		return check, nil
	}

	issues := make([]string, 0)
	issues = append(issues, inspectNativeBluetoothConfig(fs)...)
	issues = append(issues, inspectNativeBluetoothBinary(fs)...)
	unitIssues, err := inspectNativeBluetoothUnit(fs)
	if err != nil {
		return Check{}, err
	}
	issues = append(issues, unitIssues...)
	linkIssues, err := inspectNativeBluetoothWantsLink(fs)
	if err != nil {
		return Check{}, err
	}
	issues = append(issues, linkIssues...)
	if len(issues) == 0 {
		check.State = StatePass
		check.Detail = "native private hand-off Bluetooth integration is complete; the protected address value was not read"
		check.Remediation = ""
		return check, nil
	}
	check.State = optionalState(required)
	check.Detail = "native private hand-off Bluetooth integration is incomplete or invalid: " + strings.Join(issues, "; ") + "; the protected address value was not read"
	return check, nil
}

// inspectNativeBluetoothConfig checks only protected file metadata so a status
// report never parses, hashes, or returns the private controller address.
func inspectNativeBluetoothConfig(fs *rootedFS) []string {
	logical := handoffapplication.BluetoothConfigPath
	_, info, err := fs.lstat(logical)
	if missing(err) {
		return []string{"missing /" + filepath.ToSlash(logical)}
	}
	if err != nil {
		return []string{"invalid /" + filepath.ToSlash(logical)}
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() <= 0 || info.Size() > maximumNativeBluetoothConfigBytes {
		return []string{"private Bluetooth configuration is not a protected bounded regular file"}
	}
	return nil
}

// inspectNativeBluetoothBinary checks the installed helper copy is the exact
// executable class supported by the hand-off runtime.
func inspectNativeBluetoothBinary(fs *rootedFS) []string {
	logical := handoffapplication.InstalledBinaryPath
	path, info, err := fs.regular(logical, false)
	if missing(err) {
		return []string{"missing /" + filepath.ToSlash(logical)}
	}
	if err != nil || info.Mode().Perm() != 0o755 || info.Size() <= 0 || info.Size() > maximumNativeBluetoothBinaryBytes {
		return []string{"native Bluetooth helper is not a bounded 0755 regular file"}
	}
	file, err := debugelf.Open(path)
	if err != nil {
		return []string{"native Bluetooth helper is not a readable ELF file"}
	}
	defer file.Close()
	if file.Class != debugelf.ELFCLASS64 || file.Data != debugelf.ELFDATA2LSB || file.Machine != debugelf.EM_AARCH64 {
		return []string{"native Bluetooth helper is not ELF64 little-endian AArch64"}
	}
	return nil
}

// inspectNativeBluetoothUnit validates a bounded regular service unit using
// stable contract markers that cannot contain the private address.
func inspectNativeBluetoothUnit(fs *rootedFS) ([]string, error) {
	logical := handoffapplication.BluetoothUnitPath
	path, info, err := fs.regular(logical, false)
	if missing(err) {
		return []string{"missing /" + filepath.ToSlash(logical)}, nil
	}
	if err != nil || info.Mode().Perm() != 0o644 || info.Size() <= 0 || info.Size() > maximumNativeBluetoothUnitBytes {
		return []string{"native Bluetooth systemd unit is not a bounded 0644 regular file"}, nil
	}
	content, err := readBoundedStatusFile(path, maximumNativeBluetoothUnitBytes)
	if err != nil {
		return nil, fmt.Errorf("read native Bluetooth systemd unit: %w", err)
	}
	for _, marker := range nativeBluetoothUnitMarkers {
		if !strings.Contains(string(content), marker) {
			return []string{"native Bluetooth systemd unit does not match the hand-off contract"}, nil
		}
	}
	return nil, nil
}

// inspectNativeBluetoothWantsLink requires the exact relative dependency link
// installed by hand-off application.
func inspectNativeBluetoothWantsLink(fs *rootedFS) ([]string, error) {
	logical := handoffapplication.BluetoothWantsPath
	path, info, err := fs.lstat(logical)
	if missing(err) {
		return []string{"missing /" + filepath.ToSlash(logical)}, nil
	}
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return []string{"native Bluetooth dependency path is not a symbolic link"}, nil
	}
	target, err := os.Readlink(path)
	if err != nil {
		return nil, err
	}
	if target != "../linux-armer-sp11-bluetooth-address.service" {
		return []string{"native Bluetooth dependency link has an unexpected target"}, nil
	}
	if _, err := fs.resolve(logical, true); err != nil {
		return nil, err
	}
	return nil, nil
}

// inspectLegacyBluetoothIntegration reports retired configuration, helpers,
// unit, and udev objects separately from the native hand-off contract.
func inspectLegacyBluetoothIntegration(fs *rootedFS, required, nativePresent bool) (Check, error) {
	found := make(map[string]bool)
	for _, logical := range legacyBluetoothPaths {
		_, _, err := fs.lstat(logical)
		if missing(err) {
			continue
		}
		if err != nil {
			return Check{}, err
		}
		found["/"+filepath.ToSlash(logical)] = true
	}
	check := Check{ID: "bluetooth-legacy-coexistence", Feature: FeatureBluetooth, Required: required}
	if len(found) == 0 {
		check.State = StatePass
		check.Detail = "no legacy Bluetooth public-address configuration, helper, unit, or udev rule was detected"
		return check, nil
	}
	check.State = optionalState(required)
	coexistence := "detected"
	if nativePresent {
		coexistence = "coexists with native hand-off integration"
	}
	check.Detail = "legacy Bluetooth public-address configuration, helper, unit, or udev rule " + coexistence + ": " + strings.Join(sortedKeys(found), ", ")
	check.Remediation = "review linux-armer clean plan and remove only recognised legacy Bluetooth artefacts through its reversible cleanup flow"
	return check, nil
}

// readBoundedStatusFile reads one regular file through an exact ceiling and
// rejects growth between metadata inspection and the read.
func readBoundedStatusFile(path string, maximum int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	content, readErr := io.ReadAll(io.LimitReader(file, maximum+1))
	closeErr := file.Close()
	if err := errors.Join(readErr, closeErr); err != nil {
		return nil, err
	}
	if int64(len(content)) > maximum {
		return nil, fmt.Errorf("file exceeds the %d-byte inspection limit", maximum)
	}
	return content, nil
}
