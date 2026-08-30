//go:build !aix && !darwin && !dragonfly && !freebsd && !linux && !netbsd && !openbsd && !solaris

package application

// effectiveUserID returns a non-root sentinel on unsupported mutation hosts.
func effectiveUserID() int {
	return -1
}
