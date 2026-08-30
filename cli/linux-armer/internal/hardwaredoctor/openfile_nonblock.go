//go:build linux || darwin

package hardwaredoctor

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// openDiagnosticFile opens a descriptor-relative regular file without waiting
// for a FIFO or similar special file supplied by an untrusted alternate root.
func openDiagnosticFile(root *os.Root, relativePath string) (*os.File, error) {
	file, err := root.OpenFile(relativePath, os.O_RDONLY|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	info, statErr := file.Stat()
	if statErr == nil && info.Mode().IsRegular() {
		return file, nil
	}
	closeErr := file.Close()
	if statErr != nil {
		return nil, errors.Join(statErr, closeErr)
	}
	if closeErr != nil {
		return nil, closeErr
	}
	return nil, fmt.Errorf("hardware diagnostic file is not a regular file")
}
