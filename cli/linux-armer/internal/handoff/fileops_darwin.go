//go:build darwin

package handoff

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// openRegularNoFollow opens one root-relative file while rejecting symbolic
// links in the root, every parent component, and the final component.
func openRegularNoFollow(rootPath, relativePath string) (*os.File, error) {
	components := strings.Split(filepath.ToSlash(relativePath), "/")
	directoryFD, err := unix.Open(rootPath, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open no-follow root: %w", err)
	}
	for _, component := range components[:len(components)-1] {
		nextFD, openErr := unix.Openat(directoryFD, component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
		closeErr := unix.Close(directoryFD)
		if openErr != nil {
			return nil, fmt.Errorf("open no-follow parent: %w", openErr)
		}
		if closeErr != nil {
			_ = unix.Close(nextFD)
			return nil, fmt.Errorf("close no-follow parent: %w", closeErr)
		}
		directoryFD = nextFD
	}
	leaf := components[len(components)-1]
	var status unix.Stat_t
	if statErr := unix.Fstatat(directoryFD, leaf, &status, unix.AT_SYMLINK_NOFOLLOW); statErr != nil {
		_ = unix.Close(directoryFD)
		return nil, fmt.Errorf("inspect no-follow file: %w", statErr)
	}
	if status.Mode&unix.S_IFMT != unix.S_IFREG {
		_ = unix.Close(directoryFD)
		return nil, errors.New("inspect no-follow file: path is not a regular file")
	}
	fileFD, openErr := unix.Openat(directoryFD, leaf, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	closeErr := unix.Close(directoryFD)
	if openErr != nil {
		return nil, fmt.Errorf("open no-follow file: %w", openErr)
	}
	if closeErr != nil {
		_ = unix.Close(fileFD)
		return nil, fmt.Errorf("close no-follow parent: %w", closeErr)
	}
	file := os.NewFile(uintptr(fileFD), filepath.Join(rootPath, filepath.FromSlash(relativePath)))
	if file == nil {
		_ = unix.Close(fileFD)
		return nil, fmt.Errorf("open no-follow file: invalid file descriptor")
	}
	return file, nil
}

// publishNoReplace atomically renames staging to destination only when no
// filesystem object already occupies the destination name.
func publishNoReplace(staging, destination string) error {
	return unix.RenameatxNp(unix.AT_FDCWD, staging, unix.AT_FDCWD, destination, unix.RENAME_EXCL)
}

// removeRelativeNoFollow removes one root-relative regular file or empty
// directory while rejecting symbolic links in every parent component.
func removeRelativeNoFollow(rootPath, relativePath string, directory bool) error {
	components := strings.Split(filepath.ToSlash(relativePath), "/")
	directoryFD, err := unix.Open(rootPath, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("open no-follow removal root: %w", err)
	}
	for _, component := range components[:len(components)-1] {
		nextFD, openErr := unix.Openat(directoryFD, component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
		closeErr := unix.Close(directoryFD)
		if openErr != nil {
			return fmt.Errorf("open no-follow removal parent: %w", openErr)
		}
		if closeErr != nil {
			_ = unix.Close(nextFD)
			return fmt.Errorf("close no-follow removal parent: %w", closeErr)
		}
		directoryFD = nextFD
	}
	flags := 0
	if directory {
		flags = unix.AT_REMOVEDIR
	}
	removeErr := unix.Unlinkat(directoryFD, components[len(components)-1], flags)
	closeErr := unix.Close(directoryFD)
	if removeErr != nil || closeErr != nil {
		return fmt.Errorf("remove no-follow Windows hand-off path: %w", errors.Join(removeErr, closeErr))
	}
	return nil
}
