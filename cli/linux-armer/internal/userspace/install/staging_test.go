package install

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCreatePrivateInstallStagingAtRequiresStickyWritableParent verifies a
// writable shared parent cannot expose a privileged staging child to rename.
func TestCreatePrivateInstallStagingAtRequiresStickyWritableParent(t *testing.T) {
	t.Parallel()
	parent := filepath.Join(t.TempDir(), "shared")
	if err := os.Mkdir(parent, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(parent, 0o777); err != nil {
		t.Fatal(err)
	}
	parent = canonicalStagingTestPath(t, parent)
	if _, err := createPrivateInstallStagingAt(parent, "fixture-*", uint32(os.Geteuid())); err == nil || !strings.Contains(err.Error(), "sticky bit") {
		t.Fatalf("unsafe shared-parent error = %v", err)
	}
}

// TestCreatePrivateInstallStagingAtProtectsRandomChild verifies a trusted
// sticky parent produces one real mode-0700 directory with the expected owner.
func TestCreatePrivateInstallStagingAtProtectsRandomChild(t *testing.T) {
	t.Parallel()
	parent := filepath.Join(t.TempDir(), "shared")
	if err := os.Mkdir(parent, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(parent, os.ModeSticky|0o777); err != nil {
		t.Fatal(err)
	}
	parent = canonicalStagingTestPath(t, parent)
	directory, err := createPrivateInstallStagingAt(parent, "fixture-*", uint32(os.Geteuid()))
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	info, err := os.Lstat(directory)
	if err != nil {
		t.Fatal(err)
	}
	uid, err := stagingOwner(info)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || info.Mode().Perm() != 0o700 || uid != uint32(os.Geteuid()) {
		t.Fatalf("private staging metadata = mode %v uid %d", info.Mode(), uid)
	}
}

// canonicalStagingTestPath resolves operating-system temporary-directory
// aliases so tests exercise the helper's deliberate canonical-route contract.
func canonicalStagingTestPath(t *testing.T, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Clean(resolved)
}

// TestCreatePrivateInstallStagingAtRejectsSymbolicParent verifies a convenient
// alias cannot redirect package staging to a caller-controlled route.
func TestCreatePrivateInstallStagingAtRejectsSymbolicParent(t *testing.T) {
	t.Parallel()
	base := t.TempDir()
	realParent := filepath.Join(base, "real")
	if err := os.Mkdir(realParent, 0o700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(base, "alias")
	if err := os.Symlink(realParent, alias); err != nil {
		t.Fatal(err)
	}
	if _, err := createPrivateInstallStagingAt(alias, "fixture-*", uint32(os.Geteuid())); err == nil || !strings.Contains(err.Error(), "not a real directory") {
		t.Fatalf("symbolic-parent error = %v", err)
	}
}
