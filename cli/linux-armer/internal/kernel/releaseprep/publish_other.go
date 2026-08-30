//go:build !linux && !darwin

package releaseprep

import "errors"

// publishDirectoryNoReplace reports when strict publication is unavailable on the host.
func publishDirectoryNoReplace(_, _ string) error {
	return errors.New("atomic no-replace kernel release publication is unsupported on this platform")
}
