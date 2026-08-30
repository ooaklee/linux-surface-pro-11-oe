//go:build aix || darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package capture

import (
	"errors"
	"fmt"
	"io"
	"os"

	"golang.org/x/sys/unix"
)

// openRegularReadNoFollow opens one existing regular file without following a
// final symbolic link or waiting on a substituted special file.
func openRegularReadNoFollow(path string) (*os.File, error) {
	return openRegularNoFollow(path, unix.O_RDONLY)
}

// openRegularTruncateNoFollow truncates one existing regular file without
// following a final symbolic link or creating a replacement.
func openRegularTruncateNoFollow(path string) (*os.File, error) {
	return openRegularNoFollow(path, unix.O_WRONLY|unix.O_TRUNC)
}

// openRegularNoFollow applies the common no-link regular-file gate.
func openRegularNoFollow(path string, flags int) (*os.File, error) {
	descriptor, err := unix.Open(path, flags|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(descriptor), path)
	if file == nil {
		_ = unix.Close(descriptor)
		return nil, fmt.Errorf("wrap private camera evidence descriptor")
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		_ = file.Close()
		return nil, fmt.Errorf("private camera evidence is not a regular file")
	}
	return file, nil
}

// readRegularNoFollow reads one bounded regular file without following a final
// symbolic link and rejects content beyond the stated limit.
func readRegularNoFollow(path string, limit int64) ([]byte, error) {
	file, err := openRegularReadNoFollow(path)
	if err != nil {
		return nil, err
	}
	content, readErr := io.ReadAll(io.LimitReader(file, limit+1))
	closeErr := file.Close()
	if err := errors.Join(readErr, closeErr); err != nil {
		return nil, err
	}
	if int64(len(content)) > limit {
		return nil, fmt.Errorf("private camera evidence exceeds its compiled limit")
	}
	return content, nil
}
