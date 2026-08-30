//go:build linux || darwin

package hardwaredoctor

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// TestOSFileSystemRejectsFIFOWithoutBlocking verifies a hostile alternate root
// cannot make a bounded file read wait indefinitely for a FIFO writer.
func TestOSFileSystemRejectsFIFOWithoutBlocking(t *testing.T) {
	root := t.TempDir()
	fifoPath := filepath.Join(root, "blocking-value")
	if err := unix.Mkfifo(fifoPath, 0o600); err != nil {
		t.Fatal(err)
	}
	filesystem, err := NewOSFileSystem(root)
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		_, readErr := filesystem.ReadFile(context.Background(), "/blocking-value", 32)
		result <- readErr
	}()
	select {
	case readErr := <-result:
		if readErr == nil {
			t.Fatal("ReadFile() accepted a FIFO")
		}
	case <-time.After(time.Second):
		t.Fatal("ReadFile() blocked while opening a FIFO")
	}
}
