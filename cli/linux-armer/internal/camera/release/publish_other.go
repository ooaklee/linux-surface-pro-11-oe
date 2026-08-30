//go:build !linux && !darwin

package release

import "errors"

// publishNoReplace reports that strict camera publication is unavailable.
func publishNoReplace(_, _ string) error {
	return errors.New("atomic no-replace camera release publication is unsupported on this platform")
}
