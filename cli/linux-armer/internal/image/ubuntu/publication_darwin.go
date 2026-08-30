//go:build darwin

package ubuntu

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// publishOutputNoReplace atomically publishes one descriptor-relative entry
// only when its final destination is absent.
func publishOutputNoReplace(directory *os.File, source, destination string) error {
	directoryFD := int(directory.Fd())
	return unix.RenameatxNp(directoryFD, source, directoryFD, destination, unix.RENAME_EXCL)
}

// openExclusivePublicationEntry creates one non-symbolic-link regular entry
// relative to the already anchored directory.
func openExclusivePublicationEntry(directory *os.File, name string) (*os.File, error) {
	fileDescriptor, err := unix.Openat(
		int(directory.Fd()),
		name,
		unix.O_RDWR|unix.O_CREAT|unix.O_EXCL|unix.O_CLOEXEC|unix.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fileDescriptor), filepath.Join(directory.Name(), name)), nil
}

// openPublicationEntry opens one non-symbolic-link entry relative to the
// already anchored directory for post-publication identity verification.
func openPublicationEntry(directory *os.File, name string) (*os.File, error) {
	fileDescriptor, err := unix.Openat(
		int(directory.Fd()),
		name,
		unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW,
		0,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fileDescriptor), filepath.Join(directory.Name(), name)), nil
}

// publicationEntryExists reports whether any object, including a symbolic
// link, occupies one name relative to the anchored directory.
func publicationEntryExists(directory *os.File, name string) (bool, error) {
	var status unix.Stat_t
	err := unix.Fstatat(int(directory.Fd()), name, &status, unix.AT_SYMLINK_NOFOLLOW)
	if err == nil {
		return true, nil
	}
	if err == unix.ENOENT {
		return false, nil
	}
	return false, err
}
