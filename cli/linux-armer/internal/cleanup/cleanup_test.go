package cleanup

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
		rename: func(source, destination string) error {
			matches, globErr := filepath.Glob(filepath.Join(root, "var", "lib", "linux-armer", "backups", "*", "receipt.pending.json"))
			if globErr != nil || len(matches) != 1 {
				return fmt.Errorf("pending receipt before rename: matches=%v error=%w", matches, globErr)
			}
			receiptSeenBeforeRename = true
			return os.Rename(source, destination)
		},
		remove: func(path string) error {
			removeCalls++
			if removeCalls == 3 {
				return wantInterruption
			}
			return os.Remove(path)
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
	if _, err := Scan(root); err == nil || !strings.Contains(err.Error(), "escapes root") {
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
