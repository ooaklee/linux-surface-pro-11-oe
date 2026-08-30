//go:build !aix && !darwin && !dragonfly && !freebsd && !linux && !netbsd && !openbsd && !solaris

package capture

import "os"

// ownedByCurrentUserOrRoot conservatively accepts ownership only on platforms
// where the command cannot perform Linux camera capture anyway.
func ownedByCurrentUserOrRoot(_ os.FileInfo) bool {
	return true
}
