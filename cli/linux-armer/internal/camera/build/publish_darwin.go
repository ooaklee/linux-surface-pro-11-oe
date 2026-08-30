//go:build darwin

package build

import "golang.org/x/sys/unix"

// publishNoReplace atomically installs a directory only when its name is absent.
func publishNoReplace(staging, destination string) error {
	return unix.RenameatxNp(unix.AT_FDCWD, staging, unix.AT_FDCWD, destination, unix.RENAME_EXCL)
}
