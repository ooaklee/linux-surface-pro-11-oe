package status

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// maxSymlinkDepth bounds target-root link traversal to prevent cycles and
// adversarial chains from consuming unbounded inspection work.
const maxSymlinkDepth = 40

// rootedFS resolves absolute links as if root were a chroot. It never allows
// a relative link to walk above root and it never asks EvalSymlinks to resolve
// a target-root absolute link against the host filesystem.
type rootedFS struct {
	// root is an absolute, symlink-resolved directory that contains every path
	// returned by this resolver.
	root string
}

// resolvedUserHome retains both the target-visible path used in reports and
// its root-relative form used by the contained filesystem resolver.
type resolvedUserHome struct {
	// logical is the canonical absolute Linux path visible inside the target.
	logical string
	// relative is the same path without its leading separator.
	relative string
}

// newRootedFS validates and canonicalises the selected target root before any
// diagnostic path is resolved beneath it.
func newRootedFS(root string) (*rootedFS, error) {
	if strings.TrimSpace(root) == "" {
		root = "/"
	}
	absolute, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("resolve userspace root: %w", err)
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return nil, fmt.Errorf("resolve userspace root %q: %w", absolute, err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return nil, fmt.Errorf("inspect userspace root %q: %w", resolved, err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("userspace root %q is not a directory", resolved)
	}
	return &rootedFS{root: filepath.Clean(resolved)}, nil
}

// resolveExplicitUserHome validates one opt-in target-visible Linux home.
// Empty input deliberately selects no home; environment and account discovery
// are never consulted.
func resolveExplicitUserHome(fs *rootedFS, input string) (resolvedUserHome, error) {
	if input == "" {
		return resolvedUserHome{}, nil
	}
	if fs == nil {
		return resolvedUserHome{}, errors.New("userspace target root is unavailable")
	}
	if strings.TrimSpace(input) != input || strings.Contains(input, "\\") || !filepath.IsAbs(input) {
		return resolvedUserHome{}, fmt.Errorf("userspace user home must be an explicit absolute Linux path: %q", input)
	}
	clean := filepath.Clean(input)
	if clean != input || clean == string(filepath.Separator) {
		return resolvedUserHome{}, fmt.Errorf("userspace user home must be canonical and cannot be /: %q", input)
	}
	relative := strings.TrimPrefix(clean, string(filepath.Separator))
	resolved, err := fs.resolve(relative, false)
	if err != nil {
		return resolvedUserHome{}, fmt.Errorf("resolve userspace user home %q: %w", clean, err)
	}
	expected := filepath.Join(fs.root, relative)
	if resolved != expected {
		return resolvedUserHome{}, fmt.Errorf("userspace user home is not canonical within the selected root: %q", clean)
	}
	info, err := os.Lstat(resolved)
	if err != nil {
		return resolvedUserHome{}, fmt.Errorf("inspect userspace user home %q: %w", clean, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return resolvedUserHome{}, fmt.Errorf("userspace user home must be a real directory: %q", clean)
	}
	return resolvedUserHome{logical: filepath.ToSlash(clean), relative: filepath.ToSlash(relative)}, nil
}

// cleanRelative normalises a logical target-root path and rejects empty-root or
// parent traversal results.
func cleanRelative(path string) (string, error) {
	path = filepath.FromSlash(strings.TrimSpace(path))
	if filepath.IsAbs(path) {
		path = strings.TrimLeft(path, string(filepath.Separator))
	}
	clean := filepath.Clean(path)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("unsafe target-root path %q", path)
	}
	return clean, nil
}

// resolve walks a logical path component by component, interpreting absolute
// links inside the target root and rejecting any relative link that escapes it.
func (fs *rootedFS) resolve(path string, followLeaf bool) (string, error) {
	relative, err := cleanRelative(path)
	if err != nil {
		return "", err
	}
	queue := splitPath(relative)
	resolved := make([]string, 0, len(queue))
	symlinks := 0

	for len(queue) > 0 {
		part := queue[0]
		queue = queue[1:]
		candidate := filepath.Join(append([]string{fs.root}, append(resolved, part)...)...)
		info, lstatErr := os.Lstat(candidate)
		if errors.Is(lstatErr, os.ErrNotExist) {
			return filepath.Join(append([]string{candidate}, queue...)...), nil
		}
		if lstatErr != nil {
			return "", fmt.Errorf("inspect target-root path /%s: %w", filepath.ToSlash(filepath.Join(append(resolved, part)...)), lstatErr)
		}
		leaf := len(queue) == 0
		if info.Mode()&os.ModeSymlink != 0 && (!leaf || followLeaf) {
			symlinks++
			if symlinks > maxSymlinkDepth {
				return "", fmt.Errorf("too many symbolic links while resolving /%s", filepath.ToSlash(relative))
			}
			target, readErr := os.Readlink(candidate)
			if readErr != nil {
				return "", fmt.Errorf("read target-root link /%s: %w", filepath.ToSlash(filepath.Join(append(resolved, part)...)), readErr)
			}
			var targetRelative string
			if filepath.IsAbs(target) {
				targetRelative = strings.TrimLeft(filepath.Clean(target), string(filepath.Separator))
			} else {
				targetRelative = filepath.Clean(filepath.Join(filepath.Join(resolved...), target))
			}
			if targetRelative == "." {
				return "", fmt.Errorf("target-root link /%s resolves to the root", filepath.ToSlash(filepath.Join(append(resolved, part)...)))
			}
			if targetRelative == ".." || strings.HasPrefix(targetRelative, ".."+string(filepath.Separator)) {
				return "", fmt.Errorf("target-root link /%s escapes root", filepath.ToSlash(filepath.Join(append(resolved, part)...)))
			}
			queue = append(splitPath(targetRelative), queue...)
			resolved = resolved[:0]
			continue
		}
		if !leaf && !info.IsDir() {
			return "", fmt.Errorf("target-root path parent /%s is not a directory", filepath.ToSlash(filepath.Join(append(resolved, part)...)))
		}
		resolved = append(resolved, part)
	}
	return filepath.Join(append([]string{fs.root}, resolved...)...), nil
}

// splitPath divides a clean platform path into non-empty traversal components.
func splitPath(path string) []string {
	parts := strings.Split(filepath.Clean(path), string(filepath.Separator))
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" && part != "." {
			result = append(result, part)
		}
	}
	return result
}

// lstat resolves a logical path without following its leaf link and returns the
// host path plus link-aware metadata.
func (fs *rootedFS) lstat(path string) (string, os.FileInfo, error) {
	resolved, err := fs.resolve(path, false)
	if err != nil {
		return "", nil, err
	}
	info, err := os.Lstat(resolved)
	return resolved, info, err
}

// regular resolves a logical path according to the caller's leaf-link policy
// and requires the final target to be a regular file.
func (fs *rootedFS) regular(path string, allowSymlink bool) (string, os.FileInfo, error) {
	resolved, err := fs.resolve(path, allowSymlink)
	if err != nil {
		return "", nil, err
	}
	info, err := os.Lstat(resolved)
	if err != nil {
		return resolved, nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return resolved, info, fmt.Errorf("/%s is not a regular file", strings.TrimLeft(filepath.ToSlash(path), "/"))
	}
	return resolved, info, nil
}

// missing reports whether an inspection error means the target does not exist.
func missing(err error) bool {
	return errors.Is(err, os.ErrNotExist)
}
