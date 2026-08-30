//go:build !windows

package install

import "os"

// effectiveUserID returns the Unix effective user identifier.
func effectiveUserID() int {
	return os.Geteuid()
}
