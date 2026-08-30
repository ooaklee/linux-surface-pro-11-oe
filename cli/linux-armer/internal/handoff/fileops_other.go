//go:build !linux && !darwin

package handoff

import (
	"errors"
	"os"
)

// openRegularNoFollow reports that strict component-wise no-follow reads are
// unavailable on this build platform.
func openRegularNoFollow(_, _ string) (*os.File, error) {
	return nil, errors.New("strict Windows hand-off storage is unsupported on this platform")
}

// publishNoReplace reports that atomic no-replace directory publication is
// unavailable on this build platform.
func publishNoReplace(_, _ string) error {
	return errors.New("strict Windows hand-off storage is unsupported on this platform")
}

// removeRelativeNoFollow reports that secure component-relative removal is not
// available on this build platform.
func removeRelativeNoFollow(_, _ string, _ bool) error {
	return errors.New("strict Windows hand-off storage is unsupported on this platform")
}
