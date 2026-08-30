//go:build darwin

package release

import (
	"errors"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// publicationSupported reports native atomic no-replace directory support.
func publicationSupported() bool {
	return true
}

// publishNoReplace atomically renames one sibling directory without replacement.
func publishNoReplace(parentFD int, stagingName, destinationName string) error {
	return unix.RenameatxNp(parentFD, stagingName, parentFD, destinationName, unix.RENAME_EXCL)
}

// syncDirectory makes entries durable where supported by the Darwin filesystem.
func syncDirectory(directory *os.File) error {
	err := directory.Sync()
	if errors.Is(err, syscall.EINVAL) {
		return nil
	}
	return err
}
