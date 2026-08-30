//go:build !darwin && !linux

package media

// defaultPrivilegeChecker refuses destructive media access on unsupported hosts.
func defaultPrivilegeChecker() PrivilegeChecker {
	return PrivilegeCheckFunc(func() error { return ErrElevatedPrivilegeRequired })
}
