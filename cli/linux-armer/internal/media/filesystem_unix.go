//go:build darwin || linux

package media

import (
	"errors"
	"fmt"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// pathsShareFilesystem compares kernel filesystem identities for two existing paths.
func pathsShareFilesystem(first, second string) (bool, error) {
	firstInfo, err := os.Stat(first)
	if err != nil {
		return false, fmt.Errorf("inspect %s: %w", first, err)
	}
	secondInfo, err := os.Stat(second)
	if err != nil {
		return false, fmt.Errorf("inspect %s: %w", second, err)
	}
	firstStat, firstOK := firstInfo.Sys().(*syscall.Stat_t)
	secondStat, secondOK := secondInfo.Sys().(*syscall.Stat_t)
	if !firstOK || !secondOK {
		return false, errors.New("filesystem device identity is unavailable")
	}
	return firstStat.Dev == secondStat.Dev, nil
}

// fileSharesFilesystem compares an already-open source descriptor with one
// existing path using kernel filesystem identities.
func fileSharesFilesystem(file *os.File, path string) (bool, error) {
	if file == nil {
		return false, errors.New("source file descriptor is unavailable")
	}
	fileInfo, err := file.Stat()
	if err != nil {
		return false, fmt.Errorf("inspect opened source file: %w", err)
	}
	pathInfo, err := os.Stat(path)
	if err != nil {
		return false, fmt.Errorf("inspect %s: %w", path, err)
	}
	fileStat, fileOK := fileInfo.Sys().(*syscall.Stat_t)
	pathStat, pathOK := pathInfo.Sys().(*syscall.Stat_t)
	if !fileOK || !pathOK {
		return false, errors.New("filesystem device identity is unavailable")
	}
	return fileStat.Dev == pathStat.Dev, nil
}

// openStableRawFile proves the ordinary and raw nodes address the same kernel
// device, opens the raw node with O_NOFOLLOW, and rechecks its descriptor.
func openStableRawFile(devicePath, rawPath string, flag int) (*os.File, error) {
	deviceInfo, err := os.Lstat(devicePath)
	if err != nil {
		return nil, fmt.Errorf("inspect device node %s: %w", devicePath, err)
	}
	rawInfo, err := os.Lstat(rawPath)
	if err != nil {
		return nil, fmt.Errorf("inspect raw device node %s: %w", rawPath, err)
	}
	deviceNumber, err := deviceNodeNumber(deviceInfo, devicePath)
	if err != nil {
		return nil, err
	}
	rawNumber, err := deviceNodeNumber(rawInfo, rawPath)
	if err != nil {
		return nil, err
	}
	if deviceNumber != rawNumber {
		return nil, fmt.Errorf("device node %s and raw node %s address different kernel devices", devicePath, rawPath)
	}
	descriptor, err := unix.Open(rawPath, flag|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open raw device %s without following links: %w", rawPath, err)
	}
	file := os.NewFile(uintptr(descriptor), rawPath)
	if file == nil {
		_ = unix.Close(descriptor)
		return nil, fmt.Errorf("adopt raw device descriptor for %s", rawPath)
	}
	opened, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("inspect opened raw device %s: %w", rawPath, err)
	}
	openedNumber, err := deviceNodeNumber(opened, rawPath)
	if err != nil {
		_ = file.Close()
		return nil, err
	}
	if openedNumber != deviceNumber || !os.SameFile(rawInfo, opened) {
		_ = file.Close()
		return nil, fmt.Errorf("raw device %s changed while it was opened", rawPath)
	}
	return file, nil
}

// deviceNodeNumber returns the kernel identity stored in a non-symbolic-link
// device node's stat record.
func deviceNodeNumber(info os.FileInfo, path string) (uint64, error) {
	if info == nil || info.Mode()&os.ModeSymlink != 0 || info.Mode()&os.ModeDevice == 0 {
		return 0, fmt.Errorf("raw path %s is not a device node", path)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, fmt.Errorf("kernel device identity is unavailable for %s", path)
	}
	return uint64(stat.Rdev), nil
}
