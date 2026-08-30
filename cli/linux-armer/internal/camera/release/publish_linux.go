//go:build linux

package release

import "golang.org/x/sys/unix"

// publishNoReplace atomically installs a directory only when its name is absent.
func publishNoReplace(staging, destination string) error {
	return unix.Renameat2(unix.AT_FDCWD, staging, unix.AT_FDCWD, destination, unix.RENAME_NOREPLACE)
}
