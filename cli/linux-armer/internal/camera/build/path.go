package build

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// safeBuildTokenExpression accepts the private random identifier used in names.
var safeBuildTokenExpression = regexp.MustCompile(`^[0-9a-f]{24}$`)

// safeBuildIDExpression accepts the public timestamp and random identifier tuple.
var safeBuildIDExpression = regexp.MustCompile(`^[0-9]{14}\.[0-9a-f]{24}$`)

// newManager supplies production host policy and entropy.
func newManager(runner platform.Runner) *Manager {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Manager{
		Runner:           runner,
		now:              time.Now,
		token:            randomToken,
		hostOS:           runtime.GOOS,
		hostArchitecture: runtime.GOARCH,
	}
}

// randomToken returns 96 bits of lowercase hexadecimal entropy.
func randomToken() (string, error) {
	buffer := make([]byte, 12)
	if _, err := rand.Read(buffer); err != nil {
		return "", fmt.Errorf("generate camera build identifier: %w", err)
	}
	return hex.EncodeToString(buffer), nil
}

// managerTime returns a stable UTC timestamp or the current time as a fallback.
func managerTime(manager *Manager) time.Time {
	if manager != nil && manager.now != nil {
		return manager.now().UTC()
	}
	return time.Now().UTC()
}

// resolveRoot returns a canonical, real repository root owned by the caller.
func resolveRoot(root string) (string, error) {
	if strings.TrimSpace(root) == "" {
		return "", errors.New("repository root is required")
	}
	absolute, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("make repository root absolute: %w", err)
	}
	absolute = filepath.Clean(absolute)
	info, err := os.Lstat(absolute)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("repository root must be a real directory: %s", absolute)
	}
	canonical, err := filepath.EvalSymlinks(absolute)
	if err != nil || filepath.Clean(canonical) != absolute {
		return "", fmt.Errorf("repository root must be canonical: %s", absolute)
	}
	return absolute, nil
}

// resolveContainedPath resolves a repository-relative route without following
// an existing symbolic-link component.
func resolveContainedPath(root, selected, fallback string) (string, error) {
	if selected == "" {
		selected = fallback
	}
	if filepath.IsAbs(selected) || filepath.Clean(selected) != selected || selected == "." {
		return "", fmt.Errorf("path must be a canonical repository-relative value: %q", selected)
	}
	target := filepath.Join(root, selected)
	relative, err := filepath.Rel(root, target)
	if err != nil || relative == "." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) || relative == ".." {
		return "", fmt.Errorf("path escapes repository root: %q", selected)
	}
	if err := rejectExistingSymlinkRoute(root, target); err != nil {
		return "", err
	}
	return target, nil
}

// rejectExistingSymlinkRoute checks every existing component beneath root.
func rejectExistingSymlinkRoute(root, target string) error {
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return err
	}
	current := root
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect camera build path %s: %w", current, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("camera build path contains a symbolic link: %s", current)
		}
	}
	return nil
}

// pathsOverlap reports equality or ancestor relationships between two paths.
func pathsOverlap(first, second string) bool {
	first = filepath.Clean(first)
	second = filepath.Clean(second)
	if first == second {
		return true
	}
	firstRelative, firstErr := filepath.Rel(first, second)
	secondRelative, secondErr := filepath.Rel(second, first)
	return (firstErr == nil && firstRelative != "." && !strings.HasPrefix(firstRelative, ".."+string(filepath.Separator)) && firstRelative != "..") ||
		(secondErr == nil && secondRelative != "." && !strings.HasPrefix(secondRelative, ".."+string(filepath.Separator)) && secondRelative != "..")
}

// validateRegularInput proves a support input is a bounded non-link regular file.
func validateRegularInput(path string, maximum int64) error {
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("camera input must be a regular non-symbolic-link file: %s", path)
	}
	if info.Size() <= 0 || info.Size() > maximum {
		return fmt.Errorf("camera input size is outside policy: %s", path)
	}
	return nil
}

// makeBuildID combines a UTC second with independently supplied entropy.
func makeBuildID(at time.Time, token string) (string, error) {
	if !safeBuildTokenExpression.MatchString(token) {
		return "", errors.New("camera build identifier source returned malformed entropy")
	}
	identifier := at.UTC().Format("20060102150405") + "." + token
	if !safeBuildIDExpression.MatchString(identifier) {
		return "", errors.New("camera build identifier is malformed")
	}
	return identifier, nil
}
