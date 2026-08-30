//go:build !darwin && !linux

package media

import (
	"errors"
	"os"
)

// pathsShareFilesystem cannot establish filesystem identity on unsupported hosts.
func pathsShareFilesystem(_, _ string) (bool, error) {
	return false, errors.New("filesystem identity comparison is unsupported on this host")
}

// fileSharesFilesystem cannot establish descriptor identity on unsupported hosts.
func fileSharesFilesystem(_ *os.File, _ string) (bool, error) {
	return false, errors.New("filesystem descriptor comparison is unsupported on this host")
}

// openStableRawFile refuses raw-device access on unsupported hosts.
func openStableRawFile(_, _ string, _ int) (*os.File, error) {
	return nil, errors.New("stable raw-device access is unsupported on this host")
}
