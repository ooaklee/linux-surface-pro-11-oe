//go:build darwin

package releaseprep

import "golang.org/x/sys/unix"

// publishDirectoryNoReplace atomically publishes a directory only when its destination is absent.
func publishDirectoryNoReplace(staging, destination string) error {
	return unix.RenameatxNp(unix.AT_FDCWD, staging, unix.AT_FDCWD, destination, unix.RENAME_EXCL)
}
