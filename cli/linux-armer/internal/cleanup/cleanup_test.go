package cleanup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestApplyBacksUpOnlyRecognizedLegacyFiles(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	recognized := filepath.Join(root, "etc", "modprobe.d", "sp11-touchscreen.conf")
	unrecognized := filepath.Join(root, "etc", "pipewire", "pipewire.conf.d", "50-sp11-speakers.conf")
	if err := os.MkdirAll(filepath.Dir(recognized), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(recognized, []byte("softdep mshw0485_touch pre: spi_geni_qcom\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(unrecognized), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(unrecognized, []byte("user managed config\n"), 0o644); err != nil {
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
	if _, err := os.Stat(recognized); !os.IsNotExist(err) {
		t.Fatalf("recognized path still exists: %v", err)
	}
	if _, err := os.Stat(unrecognized); err != nil {
		t.Fatalf("unrecognized path was removed: %v", err)
	}
	if _, err := os.Stat(receipt.Changes[0].BackupPath); err != nil {
		t.Fatalf("backup missing: %v", err)
	}
}

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
