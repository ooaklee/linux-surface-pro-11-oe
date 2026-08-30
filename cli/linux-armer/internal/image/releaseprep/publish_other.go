//go:build !linux && !darwin

package releaseprep

import (
	"errors"
	"runtime"
)

// publishDirectoryNoReplace refuses publication where atomic no-replace is unavailable.
func publishDirectoryNoReplace(_, _ string) error {
	return errors.New("atomic no-replace directory publication is unsupported on " + runtime.GOOS)
}
