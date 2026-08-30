//go:build linux || darwin

package build

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// makeDirectoryRoute creates a contained directory route and returns the
// final directory opened without following any symbolic-link component.
func makeDirectoryRoute(root, target string, mode os.FileMode) (*os.File, error) {
	components, err := containedDirectoryComponents(root, target)
	if err != nil {
		return nil, err
	}
	rootDescriptor, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open camera directory authority: %w", err)
	}
	currentDescriptor := rootDescriptor
	for _, component := range components {
		if err := unix.Mkdirat(currentDescriptor, component, uint32(mode.Perm())); err != nil && !errors.Is(err, unix.EEXIST) {
			if currentDescriptor != rootDescriptor {
				_ = unix.Close(currentDescriptor)
			}
			_ = unix.Close(rootDescriptor)
			return nil, fmt.Errorf("create camera directory component %q: %w", component, err)
		}
		nextDescriptor, err := unix.Openat(currentDescriptor, component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
		if err != nil {
			if currentDescriptor != rootDescriptor {
				_ = unix.Close(currentDescriptor)
			}
			_ = unix.Close(rootDescriptor)
			return nil, fmt.Errorf("open camera directory component %q without following links: %w", component, err)
		}
		if currentDescriptor != rootDescriptor {
			_ = unix.Close(currentDescriptor)
		}
		currentDescriptor = nextDescriptor
	}
	if err := unix.Fchmod(currentDescriptor, uint32(mode.Perm())); err != nil {
		if currentDescriptor != rootDescriptor {
			_ = unix.Close(currentDescriptor)
		}
		_ = unix.Close(rootDescriptor)
		return nil, fmt.Errorf("protect camera directory: %w", err)
	}
	if currentDescriptor == rootDescriptor {
		return os.NewFile(uintptr(rootDescriptor), target), nil
	}
	_ = unix.Close(rootDescriptor)
	return os.NewFile(uintptr(currentDescriptor), target), nil
}

// openDirectoryRoute opens an existing contained directory without following
// any symbolic-link component between the authority and target.
func openDirectoryRoute(root, target string) (*os.File, error) {
	components, err := containedDirectoryComponents(root, target)
	if err != nil {
		return nil, err
	}
	rootDescriptor, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open camera directory authority: %w", err)
	}
	currentDescriptor := rootDescriptor
	for _, component := range components {
		nextDescriptor, err := unix.Openat(currentDescriptor, component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
		if err != nil {
			if currentDescriptor != rootDescriptor {
				_ = unix.Close(currentDescriptor)
			}
			_ = unix.Close(rootDescriptor)
			return nil, fmt.Errorf("open camera directory component %q without following links: %w", component, err)
		}
		if currentDescriptor != rootDescriptor {
			_ = unix.Close(currentDescriptor)
		}
		currentDescriptor = nextDescriptor
	}
	if currentDescriptor == rootDescriptor {
		return os.NewFile(uintptr(rootDescriptor), target), nil
	}
	_ = unix.Close(rootDescriptor)
	return os.NewFile(uintptr(currentDescriptor), target), nil
}

// containedDirectoryComponents returns the canonical child components beneath
// a directory authority without accepting an empty or escaping route.
func containedDirectoryComponents(root, target string) ([]string, error) {
	relative, err := filepath.Rel(root, target)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return nil, fmt.Errorf("camera directory escapes its authority: %s", target)
	}
	if filepath.Clean(relative) != relative {
		return nil, fmt.Errorf("camera directory route is not canonical: %s", target)
	}
	components := strings.Split(relative, string(filepath.Separator))
	for _, component := range components {
		if component == "" || component == "." || component == ".." {
			return nil, fmt.Errorf("camera directory component is invalid: %q", component)
		}
	}
	return components, nil
}
