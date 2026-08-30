//go:build !linux && !darwin

package ubuntu

import (
	"errors"
	"os"
	"runtime"
)

// publishOutputNoReplace refuses publication where the host cannot provide an
// atomic descriptor-relative no-replace rename primitive.
func publishOutputNoReplace(_ *os.File, _, _ string) error {
	return errors.New("atomic no-replace image publication is unsupported on " + runtime.GOOS)
}

// openExclusivePublicationEntry refuses staging where descriptor-relative
// exclusive creation is unsupported.
func openExclusivePublicationEntry(_ *os.File, _ string) (*os.File, error) {
	return nil, errors.New("descriptor-relative image staging is unsupported on " + runtime.GOOS)
}

// openPublicationEntry refuses verification where descriptor-relative opening
// is unsupported.
func openPublicationEntry(_ *os.File, _ string) (*os.File, error) {
	return nil, errors.New("descriptor-relative image verification is unsupported on " + runtime.GOOS)
}

// publicationEntryExists refuses destination checks where descriptor-relative
// metadata inspection is unsupported.
func publicationEntryExists(_ *os.File, _ string) (bool, error) {
	return false, errors.New("descriptor-relative image inspection is unsupported on " + runtime.GOOS)
}
