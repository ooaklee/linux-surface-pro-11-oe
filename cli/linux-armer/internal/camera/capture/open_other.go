//go:build !aix && !darwin && !dragonfly && !freebsd && !linux && !netbsd && !openbsd && !solaris

package capture

import (
	"errors"
	"fmt"
	"io"
	"os"
)

// openRegularReadNoFollow performs the strongest portable identity check on
// platforms where native capture cannot execute.
func openRegularReadNoFollow(path string) (*os.File, error) {
	return openRegularPortable(path, os.O_RDONLY)
}

// openRegularTruncateNoFollow performs the strongest portable identity check
// on platforms where native capture cannot execute.
func openRegularTruncateNoFollow(path string) (*os.File, error) {
	return openRegularPortable(path, os.O_WRONLY|os.O_TRUNC)
}

// openRegularPortable compares pre-open and opened identities around one
// no-create operation; production Linux execution uses O_NOFOLLOW instead.
func openRegularPortable(path string, flags int) (*os.File, error) {
	before, err := os.Lstat(path)
	if err != nil || before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() {
		return nil, fmt.Errorf("private camera evidence is not a direct regular file")
	}
	file, err := os.OpenFile(path, flags, 0)
	if err != nil {
		return nil, err
	}
	after, err := file.Stat()
	if err != nil || !after.Mode().IsRegular() || !os.SameFile(before, after) {
		_ = file.Close()
		return nil, fmt.Errorf("private camera evidence identity changed while opening")
	}
	return file, nil
}

// readRegularNoFollow reads one bounded portable regular file.
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
