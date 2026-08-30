//go:build !linux && !darwin

package build

import (
	"errors"
	"fmt"
	"os"
)

// makeDirectoryRoute creates and opens a contained directory on a planning-only
// platform which cannot execute the native Linux ARM64 camera build.
func makeDirectoryRoute(root, target string, mode os.FileMode) (*os.File, error) {
	if err := rejectExistingSymlinkRoute(root, target); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(target, mode); err != nil {
		return nil, fmt.Errorf("create camera directory route: %w", err)
	}
	if err := rejectExistingSymlinkRoute(root, target); err != nil {
		return nil, err
	}
	return openDirectoryRoute(root, target)
}

// openDirectoryRoute opens a contained non-symbolic-link directory on a
// planning-only platform.
func openDirectoryRoute(root, target string) (*os.File, error) {
	if err := rejectExistingSymlinkRoute(root, target); err != nil {
		return nil, err
	}
	before, err := os.Lstat(target)
	if err != nil || before.Mode()&os.ModeSymlink != 0 || !before.IsDir() {
		return nil, fmt.Errorf("camera directory is not a real directory: %s", target)
	}
	directory, err := os.Open(target)
	if err != nil {
		return nil, err
	}
	opened, statErr := directory.Stat()
	current, currentErr := os.Lstat(target)
	if statErr != nil || currentErr != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(before, opened) || !os.SameFile(opened, current) {
		return nil, errors.Join(errors.New("camera directory changed while it was opened"), directory.Close())
	}
	if err := directory.Chmod(0o700); err != nil {
		return nil, errors.Join(err, directory.Close())
	}
	return directory, nil
}
