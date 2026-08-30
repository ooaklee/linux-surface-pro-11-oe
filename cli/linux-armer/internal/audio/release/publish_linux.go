//go:build linux

package release

import (
	"os"

	"golang.org/x/sys/unix"
)

// publicationSupported reports native atomic no-replace directory support.
func publicationSupported() bool {
	return true
}

// publishNoReplace atomically renames one sibling directory without replacement.
func publishNoReplace(parentFD int, stagingName, destinationName string) error {
	return unix.Renameat2(parentFD, stagingName, parentFD, destinationName, unix.RENAME_NOREPLACE)
}

// syncDirectory makes completed directory entries durable on Linux.
func syncDirectory(directory *os.File) error {
	return directory.Sync()
}
