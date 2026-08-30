//go:build aix || darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package capture

import (
	"os"
	"syscall"
)

// ownedByCurrentUserOrRoot reports whether Unix metadata names the invoking
// user or root as the directory owner.
func ownedByCurrentUserOrRoot(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && (stat.Uid == uint32(os.Geteuid()) || stat.Uid == 0)
}
