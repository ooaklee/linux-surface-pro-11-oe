package capture

import (
	"os"
	"path/filepath"
	"testing"
)

// TestPrepareEvidenceReservesAClosedPrivateSet verifies no existing output is
// overwritten and every sidecar is created as a private regular file.
func TestPrepareEvidenceReservesAClosedPrivateSet(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(directory, "capture.raw")
	prepared, err := prepareEvidence(output)
	if err != nil {
		t.Fatal(err)
	}
	paths := []string{
		prepared.paths.Raw, prepared.paths.MediaBefore, prepared.paths.MediaAfter,
		prepared.paths.V4L2Log, prepared.paths.KernelLog, prepared.paths.Statistics,
	}
	for _, path := range paths {
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
			t.Fatalf("reserved evidence %s: info=%v error=%v", path, info, err)
		}
	}
	if _, err := prepareEvidence(output); err == nil {
		t.Fatal("existing camera evidence was accepted")
	}
}

// TestPrepareEvidenceRejectsWritableSharedParent verifies a non-sticky shared
// directory cannot be used for private raw-camera evidence.
func TestPrepareEvidenceRejectsWritableSharedParent(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0o777); err != nil {
		t.Fatal(err)
	}
	if _, err := prepareEvidence(filepath.Join(directory, "capture.raw")); err == nil {
		t.Fatal("world-writable non-sticky camera output parent was accepted")
	}
}

// TestEvidenceReopenRejectsASubstitutedLink verifies a reserved path cannot be
// redirected to another private or public file before retained-log writes.
func TestEvidenceReopenRejectsASubstitutedLink(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	prepared, err := prepareEvidence(filepath.Join(directory, "capture.raw"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(prepared.paths.V4L2Log); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(prepared.paths.Raw, prepared.paths.V4L2Log); err != nil {
		t.Fatal(err)
	}
	if _, _, err := openEvidenceLog(prepared.paths.V4L2Log); err == nil {
		t.Fatal("substituted camera evidence link was followed")
	}
}
