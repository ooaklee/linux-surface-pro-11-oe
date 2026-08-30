//go:build !linux && !darwin

package build

import "errors"

// publishNoReplace reports that strict camera publication is unavailable.
func publishNoReplace(_, _ string) error {
	return errors.New("atomic no-replace camera publication is unsupported on this platform")
}
