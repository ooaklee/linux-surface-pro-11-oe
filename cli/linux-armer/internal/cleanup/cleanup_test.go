package cleanup

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

// TestApplyBacksUpOnlyRecognisedLegacyFiles verifies clean-up moves a known
// workaround to its backup while leaving unrelated user configuration intact.
func TestApplyBacksUpOnlyRecognisedLegacyFiles(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	recognised := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	unrecognised := filepath.Join(root, "etc", "pipewire", "pipewire.conf.d", "50-sp11-speakers.conf")
	if err := os.MkdirAll(filepath.Dir(recognised), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(recognised, []byte("softdep mshw0485_touch pre: spi_geni_qcom\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(unrecognised), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(unrecognised, []byte("user managed config\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(receipt.Changes) != 1 {
		t.Fatalf("changes = %d, want 1", len(receipt.Changes))
	}
	if _, err := os.Stat(recognised); !os.IsNotExist(err) {
		t.Fatalf("recognised path still exists: %v", err)
	}
	if _, err := os.Stat(unrecognised); err != nil {
		t.Fatalf("unrecognised path was removed: %v", err)
	}
	backupInfo, err := os.Stat(receipt.Changes[0].BackupPath)
	if err != nil {
		t.Fatalf("backup missing: %v", err)
	}
	if got, want := backupInfo.Mode().Perm(), os.FileMode(0o640); got != want {
		t.Fatalf("backup mode = %#o, want %#o", got, want)
	}
	backupData, err := os.ReadFile(receipt.Changes[0].BackupPath)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(backupData), "softdep mshw0485_touch pre: spi_geni_qcom\n"; got != want {
		t.Fatalf("backup content = %q, want %q", got, want)
	}
	if receipt.State != "complete" {
		t.Fatalf("receipt state = %q, want complete", receipt.State)
	}
	receiptData, err := os.ReadFile(filepath.Join(receipt.Backup, "receipt.json"))
	if err != nil {
		t.Fatalf("read completed receipt: %v", err)
	}
	var persisted Receipt
	if err := json.Unmarshal(receiptData, &persisted); err != nil {
		t.Fatalf("decode completed receipt: %v", err)
	}
	if persisted.State != "complete" || len(persisted.Changes) != 1 {
		t.Fatalf("persisted receipt = %#v, want one completed change", persisted)
	}
	if _, err := os.Stat(filepath.Join(receipt.Backup, "receipt.pending.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("pending receipt remains after success: %v", err)
	}
}

// TestApplyPersistsRecoveryReceiptBeforeRemoval verifies an interrupted
// transaction retains both backups and a prepared receipt describing every
// target, including an entry not yet removed.
func TestApplyPersistsRecoveryReceiptBeforeRemoval(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	targets := []string{
		filepath.Join(root, "etc", "initramfs-tools", "hooks", "sp11-touchscreen"),
		filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf"),
	}
	for _, target := range targets {
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte("mshw0485_touch\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	wantInterruption := errors.New("simulated interruption")
	removeCalls := 0
	receiptSeenBeforeRename := false
	receipt, err := apply(report, true, applyOperations{
		rename: func(sourceDirectory *os.File, source string, destinationDirectory *os.File, destination string) error {
			matches, globErr := filepath.Glob(filepath.Join(root, "var", "lib", "linux-armer", "backups", "*", "receipt.pending.json"))
			if globErr != nil || len(matches) != 1 {
				return fmt.Errorf("pending receipt before rename: matches=%v error=%w", matches, globErr)
			}
			receiptSeenBeforeRename = true
			return renameAnchoredDirectories(sourceDirectory, source, destinationDirectory, destination)
		},
		remove: func(operationRoot *os.Root, path string) error {
			removeCalls++
			if removeCalls == 3 {
				return wantInterruption
			}
			return operationRoot.Remove(path)
		},
	})
	if !errors.Is(err, wantInterruption) {
		t.Fatalf("apply() error = %v, want simulated interruption", err)
	}
	if !receiptSeenBeforeRename {
		t.Fatal("prepared receipt was not observed before the first atomic rename")
	}
	if receipt.State != "prepared" || len(receipt.Changes) != 2 {
		t.Fatalf("interrupted receipt = %#v, want two prepared changes", receipt)
	}
	pendingPath := filepath.Join(receipt.Backup, "receipt.pending.json")
	pendingData, readErr := os.ReadFile(pendingPath)
	if readErr != nil {
		t.Fatalf("read pending receipt: %v", readErr)
	}
	var pending Receipt
	if err := json.Unmarshal(pendingData, &pending); err != nil {
		t.Fatalf("decode pending receipt: %v", err)
	}
	if pending.State != "prepared" || len(pending.Changes) != 2 {
		t.Fatalf("pending receipt = %#v, want two prepared changes", pending)
	}
	for _, change := range pending.Changes {
		if _, err := os.Stat(change.BackupPath); err != nil {
			t.Fatalf("backup %s missing after interruption: %v", change.BackupPath, err)
		}
	}
	removed := 0
	for _, target := range targets {
		_, statErr := os.Stat(target)
		switch {
		case errors.Is(statErr, os.ErrNotExist):
			removed++
		case statErr == nil:
			t.Fatalf("interrupted target was not atomically quarantined: %s", target)
		default:
			t.Fatalf("inspect interrupted target %s: %v", target, statErr)
		}
	}
	if removed != 2 {
		t.Fatalf("interrupted targets removed=%d, want 2 quarantined originals", removed)
	}
	quarantined := 0
	for _, change := range pending.Changes {
		if _, err := os.Lstat(change.QuarantinePath); err == nil {
			quarantined++
		} else if !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("inspect quarantine %s: %v", change.QuarantinePath, err)
		}
	}
	if quarantined != 1 {
		t.Fatalf("quarantined entries = %d, want 1 retained beside its backup", quarantined)
	}
}

// TestScanRecognisesOnlyExpectedEnablementSymlink verifies service enablement
// rules accept the known symbolic-link destination while preserving links to
// any other unit for manual review.
func TestScanRecognisesOnlyExpectedEnablementSymlink(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		target     string
		recognised bool
	}{
		{name: "known relative unit", target: "../sp11-wsa-routing.service", recognised: true},
		{name: "known absolute unit", target: "/etc/systemd/system/sp11-wsa-routing.service", recognised: true},
		{name: "unexpected unit", target: "../user-managed.service", recognised: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			link := filepath.Join(root, "etc", "systemd", "system", "multi-user.target.wants", "sp11-wsa-routing.service")
			if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(test.target, link); err != nil {
				t.Fatal(err)
			}
			report, err := Scan(root)
			if err != nil {
				t.Fatal(err)
			}
			if len(report.Findings) != 1 || report.Findings[0].Recognized != test.recognised {
				t.Fatalf("findings = %#v, want recognised=%t", report.Findings, test.recognised)
			}
			if !test.recognised {
				return
			}
			receipt, err := Apply(report, true)
			if err != nil {
				t.Fatal(err)
			}
			gotTarget, err := os.Readlink(receipt.Changes[0].BackupPath)
			if err != nil {
				t.Fatalf("read backed-up symbolic link: %v", err)
			}
			if gotTarget != test.target {
				t.Fatalf("backed-up symbolic-link target = %q, want %q", gotTarget, test.target)
			}
		})
	}
}

// TestScanRecognisesRetiredPipeWireRestartIntegration verifies clean-up owns
// both the exact system-wide user unit and its expected enablement link.
func TestScanRecognisesRetiredPipeWireRestartIntegration(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	unit := filepath.Join(root, "etc", "systemd", "user", "sp11-pipewire-restart.service")
	enablement := filepath.Join(root, "etc", "systemd", "user", "default.target.wants", "sp11-pipewire-restart.service")
	if err := os.MkdirAll(filepath.Dir(unit), 0o755); err != nil {
		t.Fatal(err)
	}
	contents := "ExecStart=/bin/sh -c 'test -f /run/sp11-wsa-routing-done; systemctl --user restart wireplumber pipewire'\n"
	if err := os.WriteFile(unit, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(enablement), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../sp11-pipewire-restart.service", enablement); err != nil {
		t.Fatal(err)
	}
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Findings) != 2 {
		t.Fatalf("findings = %#v, want unit and enablement", report.Findings)
	}
	for _, finding := range report.Findings {
		if !finding.Recognized {
			t.Fatalf("retired PipeWire integration was not recognised: %#v", finding)
		}
	}
}

// TestScanRequiresMarkersForRegularEnablementFile verifies a regular file at a
// symlink-only enablement path is never accepted solely because its path is
// known.
func TestScanRequiresMarkersForRegularEnablementFile(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	target := filepath.Join(root, "etc", "systemd", "system", "multi-user.target.wants", "g6-pen.service")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("user-managed unit\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Findings) != 1 || report.Findings[0].Recognized {
		t.Fatalf("findings = %#v, want one manual-review finding", report.Findings)
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(receipt.Changes) != 0 {
		t.Fatalf("changes = %#v, want none", receipt.Changes)
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("manual-review file was changed: %v", err)
	}
}

// TestReadScanReportRejectsUnknownAndTrailingContent verifies persisted plans
// cannot silently carry misspelt fields or a second JSON value.
func TestReadScanReportRejectsUnknownAndTrailingContent(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		data string
	}{
		{name: "unknown field", data: `{"root":"/","findings":[],"extra":true}`},
		{name: "second value", data: `{"root":"/","findings":[]} {"root":"/tmp","findings":[]}`},
		{name: "missing root", data: `{"findings":[]}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := ReadScanReport(strings.NewReader(test.data)); err == nil {
				t.Fatalf("ReadScanReport(%s) error = nil", test.data)
			}
		})
	}
}

// TestRestoreRecreatesVerifiedFileAndSymlink verifies completed receipts
// recover both supported object kinds while preserving their backup copies.
func TestRestoreRecreatesVerifiedFileAndSymlink(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	regular := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	link := filepath.Join(root, "etc", "systemd", "system", "multi-user.target.wants", "sp11-wsa-routing.service")
	if err := os.MkdirAll(filepath.Dir(regular), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(regular, []byte("mshw0485_touch\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../sp11-wsa-routing.service", link); err != nil {
		t.Fatal(err)
	}
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	receiptPath := filepath.Join(receipt.Backup, "receipt.json")
	restored, err := Restore(receipt, receiptPath, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(restored.Restored) != 2 || len(restored.AlreadyPresent) != 0 {
		t.Fatalf("restore report = %#v, want two restored entries", restored)
	}
	regularData, err := os.ReadFile(regular)
	if err != nil || string(regularData) != "mshw0485_touch\n" {
		t.Fatalf("restored regular file = %q, error %v", regularData, err)
	}
	regularInfo, err := os.Stat(regular)
	if err != nil || regularInfo.Mode().Perm() != 0o640 {
		t.Fatalf("restored regular mode = %v, error %v", regularInfo, err)
	}
	linkTarget, err := os.Readlink(link)
	if err != nil || linkTarget != "../sp11-wsa-routing.service" {
		t.Fatalf("restored symbolic link = %q, error %v", linkTarget, err)
	}
	for _, change := range receipt.Changes {
		if _, err := os.Lstat(change.BackupPath); err != nil {
			t.Fatalf("recovery copy was consumed: %v", err)
		}
	}
	again, err := Restore(receipt, receiptPath, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(again.Restored) != 0 || len(again.AlreadyPresent) != 2 {
		t.Fatalf("second restore report = %#v, want two already-present entries", again)
	}
}

// TestRestoreRejectsTamperedBackup verifies restoration cannot publish bytes
// whose digest differs from the completed receipt.
func TestRestoreRejectsTamperedBackup(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	target := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("mshw0485_touch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(receipt.Changes[0].BackupPath, []byte("tampered\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true); err == nil || !strings.Contains(err.Error(), "verify recovery copy") {
		t.Fatalf("Restore() error = %v, want recovery verification failure", err)
	}
	if _, err := os.Lstat(target); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("tampered recovery copy recreated target: %v", err)
	}
}

// TestApplyRejectsTargetChangedAfterScan verifies clean-up refuses to mutate a
// file whose contents changed after the user reviewed the scan report.
func TestApplyRejectsTargetChangedAfterScan(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	target := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("mshw0485_touch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("mshw0485_touch\nchanged after review\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Apply(report, true); err == nil || !strings.Contains(err.Error(), "changed after planning") {
		t.Fatalf("Apply() error = %v, want changed-after-planning error", err)
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("changed target was removed: %v", err)
	}
}

// TestScanRejectsParentSymlinkOutsideRoot verifies a target-root scan cannot
// follow a parent symlink into an unrelated filesystem tree.
func TestScanRejectsParentSymlinkOutsideRoot(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "etc")); err != nil {
		t.Fatal(err)
	}
	if _, err := Scan(root); err == nil || !strings.Contains(err.Error(), "path escapes") {
		t.Fatalf("Scan() error = %v, want parent escape error", err)
	}
}

// TestSafeJoinSupportsFilesystemRoot verifies safe path resolution works when
// the selected target is the operating system's filesystem root.
func TestSafeJoinSupportsFilesystemRoot(t *testing.T) {
	t.Parallel()
	got, err := safeJoin(string(filepath.Separator), "etc/example")
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(string(filepath.Separator), "etc", "example")
	if got != want {
		t.Fatalf("safeJoin() = %q, want %q", got, want)
	}
}

// TestBluetoothCleanupIsPrivateReversibleAndNativeSafe verifies the exact
// retired Bluetooth objects are removed transactionally without exposing the
// legacy address or touching native hand-off integration.
func TestBluetoothCleanupIsPrivateReversibleAndNativeSafe(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	secret := "12:34:56:78:9A:BC"
	legacy := map[string]struct {
		mode    os.FileMode
		content string
	}{
		"etc/default/sp11-bluetooth-mac":                         {mode: 0o600, content: "# Surface Pro 11 Bluetooth MAC address.\nSP11_BLUETOOTH_MAC=\"" + secret + "\"\nSP11_BLUETOOTH_HCI=\"hci0\"\nSP11_BLUETOOTH_ATTEMPTS=\"5\"\nSP11_BLUETOOTH_SETTLE_SECONDS=\"5\"\nSP11_BLUETOOTH_BTMGMT_TIMEOUT=\"8\"\nSP11_BLUETOOTH_RESTART_BLUETOOTH_BEFORE=\"false\"\nSP11_BLUETOOTH_NO_BATCH=\"false\"\n"},
		"usr/local/sbin/sp11-bluetooth-mac":                      {mode: 0o755, content: "#!/bin/sh\nCONFIG=\"${CONFIG:-/etc/default/sp11-bluetooth-mac}\"\n# Configures a Surface Pro 11 Bluetooth public address with btmgmt.\n# sp11-bluetooth-mac@.service 99-surface-pro-11-bluetooth-mac.rules sp11-bt-set-addr\n"},
		"usr/local/sbin/sp11-bt-set-addr":                        {mode: 0o755, content: "\x7fELF set-public-address  status hci%u not found after 120s Success: public address set Error: failed after 60 attempts"},
		"etc/systemd/system/sp11-bluetooth-mac@.service":         {mode: 0o644, content: "Description=Set Surface Pro 11 Bluetooth public address on %I\nConditionPathExists=/etc/default/sp11-bluetooth-mac\nConditionPathExists=/usr/local/sbin/sp11-bt-set-addr\nBefore=bluetooth.service\nExecStart=/usr/local/sbin/sp11-bt-set-addr 0 ${SP11_BLUETOOTH_MAC}\n"},
		"etc/udev/rules.d/99-surface-pro-11-bluetooth-mac.rules": {mode: 0o644, content: "SUBSYSTEM==\"bluetooth\", ENV{DEVTYPE}==\"host\", KERNEL==\"hci[0-9]*\", ENV{SYSTEMD_WANTS}=\"sp11-bluetooth-mac@%k.service\"\n"},
	}
	for logical, fixture := range legacy {
		writeCleanupFixture(t, root, logical, fixture.mode, fixture.content)
	}
	nativeFiles := []string{
		"etc/linux-armer/private/bluetooth-address.json",
		"usr/libexec/linux-armer/linux-armer",
		"etc/systemd/system/linux-armer-sp11-bluetooth-address.service",
	}
	for _, logical := range nativeFiles {
		writeCleanupFixture(t, root, logical, 0o600, "native hand-off material")
	}
	nativeLink := filepath.Join(root, "etc/systemd/system/bluetooth.service.wants/linux-armer-sp11-bluetooth-address.service")
	if err := os.MkdirAll(filepath.Dir(nativeLink), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../linux-armer-sp11-bluetooth-address.service", nativeLink); err != nil {
		t.Fatal(err)
	}

	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Findings) != len(legacy) {
		t.Fatalf("Bluetooth findings = %#v, want %d legacy objects", report.Findings, len(legacy))
	}
	for _, finding := range report.Findings {
		if !finding.Recognized || finding.Rule.Feature != "bluetooth" {
			t.Fatalf("unexpected Bluetooth finding: %#v", finding)
		}
		if finding.Rule.ID == "bluetooth-legacy-config" && finding.SHA256 != "" {
			t.Fatalf("private Bluetooth configuration exposed a content digest: %#v", finding)
		}
	}
	planJSON, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(planJSON), secret) {
		t.Fatalf("cleanup plan exposed the private Bluetooth address: %s", planJSON)
	}

	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(receipt.Changes) != len(legacy) {
		t.Fatalf("receipt changes = %#v", receipt.Changes)
	}
	privateChange := findReceiptChange(t, receipt, "bluetooth-legacy-config")
	if privateChange.SHA256 != "" || privateChange.HMACSHA256 == "" {
		t.Fatalf("private receipt integrity = %#v, want HMAC only", privateChange)
	}
	receiptJSON, err := json.Marshal(receipt)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(receiptJSON), secret) {
		t.Fatalf("cleanup receipt exposed the private Bluetooth address: %s", receiptJSON)
	}
	keyInfo, err := os.Stat(filepath.Join(receipt.Backup, privateIntegrityKeyName))
	if err != nil || keyInfo.Mode().Perm() != 0o600 {
		t.Fatalf("private integrity key metadata = %v, %v", keyInfo, err)
	}
	for logical := range legacy {
		if _, err := os.Lstat(filepath.Join(root, filepath.FromSlash(logical))); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("legacy Bluetooth path remains: %s (%v)", logical, err)
		}
	}
	for _, logical := range nativeFiles {
		if _, err := os.Lstat(filepath.Join(root, filepath.FromSlash(logical))); err != nil {
			t.Fatalf("native hand-off path was changed: %s (%v)", logical, err)
		}
	}
	if target, err := os.Readlink(nativeLink); err != nil || target != "../linux-armer-sp11-bluetooth-address.service" {
		t.Fatalf("native hand-off link = %q, %v", target, err)
	}

	if _, err := Restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true); err != nil {
		t.Fatal(err)
	}
	restoredConfig, err := os.ReadFile(filepath.Join(root, "etc/default/sp11-bluetooth-mac"))
	if err != nil || !strings.Contains(string(restoredConfig), secret) {
		t.Fatalf("private Bluetooth configuration was not restored exactly: %v", err)
	}
}

// TestApplyRejectsAnUnsafePrivateBackupHierarchy verifies clean-up never places
// recovery data beneath an existing application directory readable by others.
func TestApplyRejectsAnUnsafePrivateBackupHierarchy(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	target := filepath.Join(root, "etc/modprobe.d/sp11-touchscreen.conf")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("mshw0485_touch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	applicationDirectory := filepath.Join(root, "var/lib/linux-armer")
	if err := os.MkdirAll(filepath.Join(applicationDirectory, "backups"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(applicationDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Apply(report, true); err == nil || !strings.Contains(err.Error(), "mode 0700") {
		t.Fatalf("Apply() error = %v, want unsafe private-directory rejection", err)
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("unsafe backup hierarchy changed the clean-up target: %v", err)
	}
}

// TestRestoreRejectsAWeakenedPrivateBackup verifies recovery stops before
// reading a key or copy after the transaction directory loses mode 0700.
func TestRestoreRejectsAWeakenedPrivateBackup(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	writeCleanupFixture(t, root, "etc/default/sp11-bluetooth-mac", 0o600, "# Surface Pro 11 Bluetooth MAC address.\nSP11_BLUETOOTH_MAC=\"12:34:56:78:9A:BC\"\nSP11_BLUETOOTH_HCI=\"hci0\"\n")
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(receipt.Backup, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true); err == nil || !strings.Contains(err.Error(), "mode 0700") {
		t.Fatalf("Restore() error = %v, want weakened-backup rejection", err)
	}
	original := filepath.Join(root, "etc/default/sp11-bluetooth-mac")
	if _, err := os.Lstat(original); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("rejected restore recreated private target: %v", err)
	}
}

// TestBluetoothRecognitionCoversHistoricalFormats verifies the initial shell
// unit and two-field private configuration remain removable while executable
// configuration content fails closed.
func TestBluetoothRecognitionCoversHistoricalFormats(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	writeCleanupFixture(t, root, "etc/default/sp11-bluetooth-mac", 0o644, "# Surface Pro 11 Bluetooth MAC address.\n# Use the address reported by Windows or another trusted source.\nSP11_BLUETOOTH_MAC=\"12:34:56:78:9A:BC\"\nSP11_BLUETOOTH_HCI=\"hci0\"\n")
	writeCleanupFixture(t, root, "etc/systemd/system/sp11-bluetooth-mac@.service", 0o644, "Description=Set Surface Pro 11 Bluetooth public address on %I\nConditionPathExists=/etc/default/sp11-bluetooth-mac\nAfter=bluetooth.service\nExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I\n")
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Findings) != 2 {
		t.Fatalf("historical Bluetooth findings = %#v", report.Findings)
	}
	for _, finding := range report.Findings {
		if !finding.Recognized {
			t.Fatalf("historical Bluetooth artefact was not recognised: %#v", finding)
		}
	}

	hostileRoot := t.TempDir()
	writeCleanupFixture(t, hostileRoot, "etc/default/sp11-bluetooth-mac", 0o600, "# Surface Pro 11 Bluetooth MAC address.\nSP11_BLUETOOTH_MAC=\"12:34:56:78:9A:BC\"\nSP11_BLUETOOTH_HCI=\"hci0\"\nRUN_ME=\"$(id)\"\n")
	hostile, err := Scan(hostileRoot)
	if err != nil {
		t.Fatal(err)
	}
	if len(hostile.Findings) != 1 || hostile.Findings[0].Recognized || hostile.Findings[0].SHA256 != "" {
		t.Fatalf("hostile private configuration finding = %#v", hostile.Findings)
	}
}

// TestPerUserCleanupRequiresAnExplicitCanonicalHome verifies no account is
// inferred and exact per-user audio artefacts can be removed and restored only
// beneath the selected target-visible home.
func TestPerUserCleanupRequiresAnExplicitCanonicalHome(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	home := filepath.Join(root, "home", "alice")
	otherHome := filepath.Join(root, "home", "bob")
	if err := os.MkdirAll(home, 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(otherHome, 0o750); err != nil {
		t.Fatal(err)
	}
	fixtures := map[string]string{
		".config/pipewire/pipewire.conf.d/50-sp11-speakers.conf":                  "# Surface Pro 11 manual speaker sink.\nfactory.name = api.alsa.pcm.sink\nnode.name = \"alsa_output.sp11_speakers\"\nchannelmix.mix-matrix = \"fixture\"\n",
		".config/wireplumber/wireplumber.conf.d/51-sp11-no-duplicate-output.conf": "# The manual Surface sink owns the PCM\nalsa_output.platform-sound.pro-output-1.*\nnode.disabled = true\n",
		".config/systemd/user/sp11-pipewire-restart.service":                      "ExecStart=/bin/sh -c 'test /run/sp11-wsa-routing-done; systemctl --user restart wireplumber pipewire'\n",
	}
	for relative, content := range fixtures {
		writeCleanupFixture(t, home, relative, 0o640, content)
	}
	unitLink := filepath.Join(home, ".config/systemd/user/default.target.wants/sp11-pipewire-restart.service")
	if err := os.MkdirAll(filepath.Dir(unitLink), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../sp11-pipewire-restart.service", unitLink); err != nil {
		t.Fatal(err)
	}
	writeCleanupFixture(t, otherHome, ".config/pipewire/pipewire.conf.d/50-sp11-speakers.conf", 0o644, fixtures[".config/pipewire/pipewire.conf.d/50-sp11-speakers.conf"])

	systemOnly, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(systemOnly.Findings) != 0 {
		t.Fatalf("system-only scan inferred a user home: %#v", systemOnly.Findings)
	}
	report, err := ScanWithOptions(ScanOptions{Root: root, UserHome: "/home/alice"})
	if err != nil {
		t.Fatal(err)
	}
	if report.UserHome != "/home/alice" || len(report.Findings) != 4 {
		t.Fatalf("per-user report = %#v", report)
	}
	for _, finding := range report.Findings {
		if !finding.Recognized {
			t.Fatalf("per-user artefact was not recognised: %#v", finding)
		}
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.UserHome != "/home/alice" || len(receipt.Changes) != 4 {
		t.Fatalf("per-user receipt = %#v", receipt)
	}
	if _, err := os.Stat(filepath.Join(otherHome, ".config/pipewire/pipewire.conf.d/50-sp11-speakers.conf")); err != nil {
		t.Fatalf("unselected user home was changed: %v", err)
	}
	if _, err := Restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true); err != nil {
		t.Fatal(err)
	}
	for relative := range fixtures {
		info, err := os.Stat(filepath.Join(home, filepath.FromSlash(relative)))
		if err != nil || info.Mode().Perm() != 0o640 {
			t.Fatalf("restored per-user file %s = %v, %v", relative, info, err)
		}
	}
}

// TestResolveUserHomeRejectsUnsafeInputs verifies relative, root, non-canonical,
// absent, and symbolic-link homes all fail closed.
func TestResolveUserHomeRejectsUnsafeInputs(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "home", "alice"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("alice", filepath.Join(root, "home", "linked")); err != nil {
		t.Fatal(err)
	}
	for _, input := range []string{"home/alice", "/", "/home/../home/alice", "/home/missing", "/home/linked"} {
		if _, err := ResolveUserHome(root, input); err == nil {
			t.Fatalf("ResolveUserHome(%q) unexpectedly succeeded", input)
		}
	}
	if got, err := ResolveUserHome(root, "/home/alice"); err != nil || got != "/home/alice" {
		t.Fatalf("ResolveUserHome(valid) = %q, %v", got, err)
	}
}

// TestALSAMasksRequireExactDevNullLinks verifies only the historical exact
// distribution-service masks are eligible for reversible removal.
func TestALSAMasksRequireExactDevNullLinks(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name       string
		target     string
		recognised bool
	}{
		{name: "exact mask", target: "/dev/null", recognised: true},
		{name: "unexpected mask", target: "/tmp/null", recognised: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			path := filepath.Join(root, "etc/systemd/system/alsa-restore.service")
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(test.target, path); err != nil {
				t.Fatal(err)
			}
			report, err := Scan(root)
			if err != nil {
				t.Fatal(err)
			}
			if len(report.Findings) != 1 || report.Findings[0].Recognized != test.recognised {
				t.Fatalf("ALSA mask finding = %#v", report.Findings)
			}
			receipt, err := Apply(report, true)
			if err != nil {
				t.Fatal(err)
			}
			if !test.recognised {
				if _, err := os.Lstat(path); err != nil {
					t.Fatalf("unexpected mask was changed: %v", err)
				}
				return
			}
			if _, err := Restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true); err != nil {
				t.Fatal(err)
			}
			if got, err := os.Readlink(path); err != nil || got != "/dev/null" {
				t.Fatalf("restored ALSA mask = %q, %v", got, err)
			}
		})
	}
}

// TestApplyKeepsUserMutationInsideTheOpenedHome verifies replacing the visible
// home route during Apply cannot redirect clean-up into another in-root tree.
func TestApplyKeepsUserMutationInsideTheOpenedHome(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	home := filepath.Join(root, "home", "alice")
	oldHomeParent := filepath.Join(root, "home-opened")
	logical := ".config/pipewire/pipewire.conf.d/50-sp11-speakers.conf"
	content := "# Surface Pro 11 manual speaker sink.\nfactory.name = api.alsa.pcm.sink\nnode.name = \"alsa_output.sp11_speakers\"\nchannelmix.mix-matrix = \"fixture\"\n"
	writeCleanupFixture(t, home, logical, 0o640, content)
	redirected := filepath.Join(root, "etc", "alice", filepath.FromSlash(logical))
	writeCleanupFixture(t, filepath.Join(root, "etc", "alice"), logical, 0o640, "redirected user content\n")
	report, err := ScanWithOptions(ScanOptions{Root: root, UserHome: "/home/alice"})
	if err != nil {
		t.Fatal(err)
	}
	swapped := false
	receipt, err := apply(report, true, applyOperations{
		rename: func(sourceDirectory *os.File, source string, destinationDirectory *os.File, destination string) error {
			if !swapped {
				swapped = true
				if err := os.Rename(filepath.Join(root, "home"), oldHomeParent); err != nil {
					return err
				}
				if err := os.Symlink("etc", filepath.Join(root, "home")); err != nil {
					return err
				}
			}
			return renameAnchoredDirectories(sourceDirectory, source, destinationDirectory, destination)
		},
		remove: func(operationRoot *os.Root, name string) error { return operationRoot.Remove(name) },
	})
	if err != nil {
		t.Fatal(err)
	}
	if !swapped || receipt.State != "complete" || len(receipt.Changes) != 1 {
		t.Fatalf("Apply() = %#v, swapped=%t", receipt, swapped)
	}
	redirectedData, err := os.ReadFile(redirected)
	if err != nil || string(redirectedData) != "redirected user content\n" {
		t.Fatalf("redirected tree changed: %q, %v", redirectedData, err)
	}
	openedTarget := filepath.Join(oldHomeParent, "alice", filepath.FromSlash(logical))
	if _, err := os.Lstat(openedTarget); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("opened-home target remains after clean-up: %v", err)
	}
	backup, err := os.ReadFile(receipt.Changes[0].BackupPath)
	if err != nil || string(backup) != content {
		t.Fatalf("durable recovery copy = %q, %v", backup, err)
	}
}

// TestApplyUsesTheOpenedQuarantineDirectory verifies a swapped visible
// workspace cannot receive reviewed content and the durable backup can restore
// the target after the route-change failure.
func TestApplyUsesTheOpenedQuarantineDirectory(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	target := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	writeCleanupFixture(t, root, "etc/modprobe.d/sp11-touchscreen.conf", 0o640, "mshw0485_touch\n")
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	parent := filepath.Dir(target)
	var replacement string
	receipt, err := apply(report, true, applyOperations{
		rename: func(sourceDirectory *os.File, source string, destinationDirectory *os.File, destination string) error {
			workspace := findSinglePrefixedDirectory(t, parent, ".linux-armer-cleanup-")
			moved := workspace + ".opened"
			if err := os.Rename(workspace, moved); err != nil {
				return err
			}
			if err := os.Mkdir(workspace, 0o700); err != nil {
				return err
			}
			replacement = filepath.Join(workspace, "sentinel")
			if err := os.WriteFile(replacement, []byte("attacker-owned\n"), 0o600); err != nil {
				return err
			}
			return renameAnchoredDirectories(sourceDirectory, source, destinationDirectory, destination)
		},
		remove: func(operationRoot *os.Root, name string) error { return operationRoot.Remove(name) },
	})
	if err == nil || !strings.Contains(err.Error(), "quarantine route changed") {
		t.Fatalf("apply() error = %v, want quarantine-route rejection", err)
	}
	if receipt.State != "prepared" || len(receipt.Changes) != 1 {
		t.Fatalf("prepared recovery receipt = %#v", receipt)
	}
	data, err := os.ReadFile(replacement)
	if err != nil || string(data) != "attacker-owned\n" {
		t.Fatalf("replacement workspace changed: %q, %v", data, err)
	}
	if _, err := os.Lstat(filepath.Join(filepath.Dir(replacement), filepath.Base(target))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("reviewed content entered replacement workspace: %v", err)
	}
	if _, err := Restore(receipt, filepath.Join(receipt.Backup, "receipt.pending.json"), true); err != nil {
		t.Fatal(err)
	}
	restored, err := os.ReadFile(target)
	if err != nil || string(restored) != "mshw0485_touch\n" {
		t.Fatalf("restored target = %q, %v", restored, err)
	}
}

// TestRestoreKeepsUserMutationInsideTheOpenedHome verifies an ancestor swap in
// the publication hook cannot redirect a recovered file into another tree.
func TestRestoreKeepsUserMutationInsideTheOpenedHome(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	home := filepath.Join(root, "home", "alice")
	oldHomeParent := filepath.Join(root, "home-opened")
	logical := ".config/pipewire/pipewire.conf.d/50-sp11-speakers.conf"
	content := "# Surface Pro 11 manual speaker sink.\nfactory.name = api.alsa.pcm.sink\nnode.name = \"alsa_output.sp11_speakers\"\nchannelmix.mix-matrix = \"fixture\"\n"
	writeCleanupFixture(t, home, logical, 0o640, content)
	report, err := ScanWithOptions(ScanOptions{Root: root, UserHome: "/home/alice"})
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	redirectedParent := filepath.Join(root, "etc", "alice", filepath.Dir(filepath.FromSlash(logical)))
	if err := os.MkdirAll(redirectedParent, 0o755); err != nil {
		t.Fatal(err)
	}
	swapped := false
	_, err = restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true, restoreOperations{
		link: func(sourceDirectory *os.File, source string, destinationDirectory *os.File, destination string) error {
			if !swapped {
				swapped = true
				if err := os.Rename(filepath.Join(root, "home"), oldHomeParent); err != nil {
					return err
				}
				if err := os.Symlink("etc", filepath.Join(root, "home")); err != nil {
					return err
				}
			}
			return linkAnchoredDirectories(sourceDirectory, source, destinationDirectory, destination)
		},
		symlink: func(operationRoot *os.Root, target, name string) error { return operationRoot.Symlink(target, name) },
	})
	if err != nil {
		t.Fatal(err)
	}
	redirected := filepath.Join(root, "etc", "alice", filepath.FromSlash(logical))
	if _, err := os.Lstat(redirected); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("restoration escaped into redirected home: %v", err)
	}
	restored, err := os.ReadFile(filepath.Join(oldHomeParent, "alice", filepath.FromSlash(logical)))
	if err != nil || string(restored) != content {
		t.Fatalf("opened-home restoration = %q, %v", restored, err)
	}
}

// TestRestoreUsesTheOpenedWorkspace verifies a replacement workspace cannot
// substitute its bytes for the exact recovery copy during hard-link publication.
func TestRestoreUsesTheOpenedWorkspace(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	target := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	writeCleanupFixture(t, root, "etc/modprobe.d/sp11-touchscreen.conf", 0o640, "mshw0485_touch\n")
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	parent := filepath.Dir(target)
	var replacement string
	_, err = restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true, restoreOperations{
		link: func(sourceDirectory *os.File, source string, destinationDirectory *os.File, destination string) error {
			workspace := findSinglePrefixedDirectory(t, parent, ".linux-armer-restore-")
			if err := os.Rename(workspace, workspace+".opened"); err != nil {
				return err
			}
			if err := os.Mkdir(workspace, 0o700); err != nil {
				return err
			}
			replacement = filepath.Join(workspace, source)
			if err := os.WriteFile(replacement, []byte("wrong recovery bytes\n"), 0o600); err != nil {
				return err
			}
			return linkAnchoredDirectories(sourceDirectory, source, destinationDirectory, destination)
		},
		symlink: func(operationRoot *os.Root, target, name string) error { return operationRoot.Symlink(target, name) },
	})
	if err == nil || !strings.Contains(err.Error(), "workspace route changed") {
		t.Fatalf("restore() error = %v, want workspace-route rejection", err)
	}
	restored, err := os.ReadFile(target)
	if err != nil || string(restored) != "mshw0485_touch\n" {
		t.Fatalf("published recovery bytes = %q, %v", restored, err)
	}
	wrong, err := os.ReadFile(replacement)
	if err != nil || string(wrong) != "wrong recovery bytes\n" {
		t.Fatalf("replacement workspace changed: %q, %v", wrong, err)
	}
	second, err := Restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true)
	if err != nil || len(second.AlreadyPresent) != 1 {
		t.Fatalf("second Restore() = %#v, %v", second, err)
	}
}

// TestRestoreFallsBackToVerifiedQuarantine verifies a corrupt partial backup
// cannot hide the still-valid same-filesystem recovery copy in a prepared transaction.
func TestRestoreFallsBackToVerifiedQuarantine(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	target := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	writeCleanupFixture(t, root, "etc/modprobe.d/sp11-touchscreen.conf", 0o640, "mshw0485_touch\n")
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	interrupted := errors.New("leave verified quarantine in place")
	receipt, err := apply(report, true, applyOperations{
		rename: renameAnchoredDirectories,
		remove: func(_ *os.Root, _ string) error { return interrupted },
	})
	if !errors.Is(err, interrupted) || receipt.State != "prepared" {
		t.Fatalf("apply() = %#v, %v", receipt, err)
	}
	if err := os.WriteFile(receipt.Changes[0].BackupPath, []byte("corrupt\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(receipt, filepath.Join(receipt.Backup, "receipt.pending.json"), true); err != nil {
		t.Fatal(err)
	}
	restored, err := os.ReadFile(target)
	if err != nil || string(restored) != "mshw0485_touch\n" {
		t.Fatalf("quarantine restoration = %q, %v", restored, err)
	}
}

// TestRestoreLeavesAConcurrentSymlinkReplacementUntouched verifies ownership
// restoration never follows or removes an entry substituted after publication.
func TestRestoreLeavesAConcurrentSymlinkReplacementUntouched(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	target := filepath.Join(root, "etc", "systemd", "system", "alsa-restore.service")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/dev/null", target); err != nil {
		t.Fatal(err)
	}
	report, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	_, err = restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true, restoreOperations{
		link: linkAnchoredDirectories,
		symlink: func(operationRoot *os.Root, linkTarget, name string) error {
			if err := operationRoot.Symlink(linkTarget, name); err != nil {
				return err
			}
			if err := operationRoot.Remove(name); err != nil {
				return err
			}
			return operationRoot.WriteFile(name, []byte("concurrent replacement\n"), 0o600)
		},
	})
	if err == nil || !strings.Contains(err.Error(), "changed during publication") {
		t.Fatalf("restore() error = %v, want concurrent-replacement rejection", err)
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "concurrent replacement\n" {
		t.Fatalf("concurrent replacement changed: %q, %v", data, err)
	}
}

// TestRestoreRejectsAReplacedUserHomeIdentity verifies a receipt cannot be
// replayed against a different real directory at the same visible home path.
func TestRestoreRejectsAReplacedUserHomeIdentity(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	home := filepath.Join(root, "home", "alice")
	logical := ".config/pipewire/pipewire.conf.d/50-sp11-speakers.conf"
	writeCleanupFixture(t, home, logical, 0o640, "# Surface Pro 11 manual speaker sink.\nfactory.name = api.alsa.pcm.sink\nnode.name = \"alsa_output.sp11_speakers\"\nchannelmix.mix-matrix = \"fixture\"\n")
	report, err := ScanWithOptions(ScanOptions{Root: root, UserHome: "/home/alice"})
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := Apply(report, true)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(home, home+".reviewed"); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(home, 0o750); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(receipt, filepath.Join(receipt.Backup, "receipt.json"), true); err == nil || !strings.Contains(err.Error(), "identity differs") {
		t.Fatalf("Restore() error = %v, want user-home identity rejection", err)
	}
	if _, err := os.Lstat(filepath.Join(home, filepath.FromSlash(logical))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("replacement home was changed: %v", err)
	}
}

// TestOpenStableNestedRootRejectsIntermediateLinks verifies a stable target
// root never follows an intermediate user-home route, even when it stays in-root.
func TestOpenStableNestedRootRejectsIntermediateLinks(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "real", "alice"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real", filepath.Join(root, "home")); err != nil {
		t.Fatal(err)
	}
	target, err := os.OpenRoot(root)
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	if _, _, err := openStableNestedRoot(target, filepath.Join("home", "alice")); err == nil || !strings.Contains(err.Error(), "real directory") {
		t.Fatalf("openStableNestedRoot() error = %v, want intermediate-link rejection", err)
	}
}

// TestScanRejectsUnsupportedRecoveryMetadata verifies automatic removal fails
// closed when exact hard-link, special-mode, or extended metadata recovery is unavailable.
func TestScanRejectsUnsupportedRecoveryMetadata(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name  string
		alter func(*testing.T, string)
	}{
		{name: "hard link", alter: func(t *testing.T, target string) {
			if err := os.Link(target, target+".peer"); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "set-user-ID bit", alter: func(t *testing.T, target string) {
			if err := os.Chmod(target, 0o644|os.ModeSetuid); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "extended attribute", alter: func(t *testing.T, target string) {
			if err := unix.Setxattr(target, "user.linux-armer-test", []byte("value"), 0); errors.Is(err, unix.ENOTSUP) {
				t.Skip("test filesystem does not support extended attributes")
			} else if err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			target := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
			writeCleanupFixture(t, root, "etc/modprobe.d/sp11-touchscreen.conf", 0o644, "mshw0485_touch\n")
			test.alter(t, target)
			report, err := Scan(root)
			if err != nil {
				t.Fatal(err)
			}
			if len(report.Findings) != 1 || report.Findings[0].Recognized {
				t.Fatalf("unsupported-metadata finding = %#v", report.Findings)
			}
			receipt, err := Apply(report, true)
			if err != nil || len(receipt.Changes) != 0 {
				t.Fatalf("Apply() = %#v, %v", receipt, err)
			}
			if _, err := os.Lstat(target); err != nil {
				t.Fatalf("unsupported target changed: %v", err)
			}
		})
	}
}

// findSinglePrefixedDirectory returns the sole directory with a fixed prefix
// beneath parent, failing the test if the transaction boundary is ambiguous.
func findSinglePrefixedDirectory(t *testing.T, parent, prefix string) string {
	t.Helper()
	entries, err := os.ReadDir(parent)
	if err != nil {
		t.Fatal(err)
	}
	var match string
	for _, entry := range entries {
		if entry.IsDir() && strings.HasPrefix(entry.Name(), prefix) {
			if match != "" {
				t.Fatalf("multiple %s workspaces below %s", prefix, parent)
			}
			match = filepath.Join(parent, entry.Name())
		}
	}
	if match == "" {
		t.Fatalf("no %s workspace below %s", prefix, parent)
	}
	return match
}

// writeCleanupFixture creates one regular test object beneath a selected root.
func writeCleanupFixture(t *testing.T, root, logical string, mode os.FileMode, content string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(logical))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

// findReceiptChange returns one stable receipt entry by compiled rule ID.
func findReceiptChange(t *testing.T, receipt Receipt, ruleID string) ReceiptItem {
	t.Helper()
	for _, change := range receipt.Changes {
		if change.RuleID == ruleID {
			return change
		}
	}
	t.Fatalf("receipt has no change for %s: %#v", ruleID, receipt.Changes)
	return ReceiptItem{}
}
