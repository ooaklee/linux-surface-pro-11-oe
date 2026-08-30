//go:build aix || darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package application

import "os"

// effectiveUserID returns the Unix effective user identifier for mutation gates.
func effectiveUserID() int {
	return os.Geteuid()
}
