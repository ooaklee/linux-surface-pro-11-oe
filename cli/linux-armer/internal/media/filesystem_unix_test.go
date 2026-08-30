//go:build darwin || linux

package media

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestOpenStableRawFileRejectsOrdinaryFilesAndLinks verifies the production
// raw opener cannot be redirected through a regular file or symbolic link.
func TestOpenStableRawFileRejectsOrdinaryFilesAndLinks(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	ordinary := filepath.Join(directory, "ordinary")
	if err := os.WriteFile(ordinary, []byte("do not overwrite"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "link")
	if err := os.Symlink(ordinary, link); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{ordinary, link} {
		file, err := openStableRawFile(path, path, os.O_RDONLY)
		if file != nil {
			_ = file.Close()
			t.Fatalf("openStableRawFile(%q) returned a file", path)
		}
		if err == nil || !strings.Contains(err.Error(), "not a device node") {
			t.Fatalf("openStableRawFile(%q) error = %v", path, err)
		}
	}
}

// TestOpenStableRawFileBindsOrdinaryAndRawNodes verifies two device nodes must
// expose the same kernel device number before the raw descriptor is returned.
func TestOpenStableRawFileBindsOrdinaryAndRawNodes(t *testing.T) {
	t.Parallel()
	file, err := openStableRawFile("/dev/null", "/dev/null", os.O_RDONLY)
	if err != nil {
		t.Fatalf("open identical device nodes: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	file, err = openStableRawFile("/dev/null", "/dev/zero", os.O_RDONLY)
	if file != nil {
		_ = file.Close()
		t.Fatal("mismatched ordinary and raw nodes returned a descriptor")
	}
	if err == nil || !strings.Contains(err.Error(), "different kernel devices") {
		t.Fatalf("mismatched-node error = %v", err)
	}
}
