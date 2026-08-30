package install

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

const (
	// privilegedStagingParent is a fixed Linux temporary directory whose sticky
	// ownership contract prevents an unprivileged user replacing a root-owned
	// staging child. Privileged execution never honours TMPDIR.
	privilegedStagingParent = "/var/tmp"
)

// createPrivateInstallStaging creates one mode-0700 transaction directory. A
// privileged process uses a validated fixed parent; an unprivileged dry run may
// retain the operating system's per-user temporary-directory selection.
func createPrivateInstallStaging(prefix string) (string, error) {
	if os.Geteuid() == 0 {
		return createPrivateInstallStagingAt(privilegedStagingParent, prefix, 0)
	}
	directory, err := os.MkdirTemp("", prefix)
	if err != nil {
		return "", err
	}
	if err := protectPrivateInstallStaging(directory, uint32(os.Geteuid())); err != nil {
		_ = os.RemoveAll(directory)
		return "", err
	}
	return directory, nil
}

// createPrivateInstallStagingAt validates one real trusted parent before
// creating a private random child owned by expectedUID.
func createPrivateInstallStagingAt(parent, prefix string, expectedUID uint32) (string, error) {
	clean := filepath.Clean(parent)
	if !filepath.IsAbs(clean) || clean != parent {
		return "", fmt.Errorf("install staging parent must be a canonical absolute path: %s", parent)
	}
	info, err := os.Lstat(clean)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("install staging parent is not a real directory: %s", clean)
	}
	resolved, err := filepath.EvalSymlinks(clean)
	if err != nil || filepath.Clean(resolved) != clean {
		return "", fmt.Errorf("install staging parent route contains a symbolic link: %s", clean)
	}
	uid, err := stagingOwner(info)
	if err != nil {
		return "", err
	}
	if uid != 0 && uid != expectedUID {
		return "", fmt.Errorf("install staging parent is not owned by root or the invoking user: %s", clean)
	}
	if info.Mode().Perm()&0o022 != 0 && info.Mode()&os.ModeSticky == 0 {
		return "", fmt.Errorf("writable install staging parent lacks the sticky bit: %s", clean)
	}
	directory, err := os.MkdirTemp(clean, prefix)
	if err != nil {
		return "", err
	}
	if err := protectPrivateInstallStaging(directory, expectedUID); err != nil {
		_ = os.RemoveAll(directory)
		return "", err
	}
	return directory, nil
}

// protectPrivateInstallStaging applies mode 0700 through the opened directory
// descriptor and verifies its type and owner before package bytes enter it.
func protectPrivateInstallStaging(path string, expectedUID uint32) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	chmodErr := directory.Chmod(0o700)
	info, statErr := directory.Stat()
	closeErr := directory.Close()
	if err := errors.Join(chmodErr, statErr, closeErr); err != nil {
		return err
	}
	uid, err := stagingOwner(info)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 || uid != expectedUID {
		return errors.New("private install staging directory has unsafe metadata")
	}
	current, err := os.Lstat(path)
	if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(info, current) {
		return errors.New("private install staging directory changed while it was opened")
	}
	return nil
}

// stagingOwner returns the numeric Unix owner of one staging filesystem object.
func stagingOwner(info os.FileInfo) (uint32, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, errors.New("install staging metadata has no Unix owner")
	}
	return stat.Uid, nil
}
