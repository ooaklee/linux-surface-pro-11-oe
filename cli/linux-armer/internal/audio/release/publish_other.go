//go:build !linux && !darwin

package release

import (
	"errors"
	"os"
)

// publicationSupported reports that fail-closed publication is unsupported.
func publicationSupported() bool {
	return false
}

// publishNoReplace refuses platforms without a native no-replace primitive.
func publishNoReplace(_ int, _, _ string) error {
	return errors.New("atomic no-replace audio release publication is unsupported on this platform")
}

// syncDirectory is unreachable because unsupported platforms fail before writes.
func syncDirectory(_ *os.File) error {
	return errors.New("audio release directory synchronisation is unsupported on this platform")
}
