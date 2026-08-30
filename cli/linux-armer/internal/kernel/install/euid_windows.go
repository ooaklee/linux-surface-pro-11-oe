//go:build windows

package install

// effectiveUserID reports an unprivileged identity on unsupported Windows hosts.
func effectiveUserID() int {
	return -1
}
