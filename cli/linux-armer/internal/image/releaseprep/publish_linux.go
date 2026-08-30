//go:build linux

package releaseprep

import "golang.org/x/sys/unix"

// publishDirectoryNoReplace atomically installs a directory only when absent.
func publishDirectoryNoReplace(source, destination string) error {
	return unix.Renameat2(unix.AT_FDCWD, source, unix.AT_FDCWD, destination, unix.RENAME_NOREPLACE)
}
