//go:build darwin

package releaseprep

import "golang.org/x/sys/unix"

// publishDirectoryNoReplace atomically installs a directory only when absent.
func publishDirectoryNoReplace(source, destination string) error {
	return unix.RenamexNp(source, destination, unix.RENAME_EXCL)
}
