//go:build darwin || linux

package media

import "os"

// defaultPrivilegeChecker requires the root effective user on supported Unix hosts.
func defaultPrivilegeChecker() PrivilegeChecker {
	return PrivilegeCheckFunc(func() error {
		if os.Geteuid() != 0 {
			return ErrElevatedPrivilegeRequired
		}
		return nil
	})
}
