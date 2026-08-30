package hardwaredoctor

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// ErrReadLimit identifies a file or directory that exceeded its compiled cap.
var ErrReadLimit = errors.New("hardware diagnostic read limit exceeded")

// PathKind classifies an inspected filesystem object without exposing metadata.
type PathKind string

const (
	// PathRegular identifies a regular file.
	PathRegular PathKind = "regular"
	// PathDirectory identifies a directory.
	PathDirectory PathKind = "directory"
	// PathSymlink identifies a symbolic link.
	PathSymlink PathKind = "symlink"
	// PathOther identifies a special or otherwise unsupported object.
	PathOther PathKind = "other"
)

// PathInfo is the bounded metadata needed by live diagnostic traversal.
type PathInfo struct {
	// Name is the single directory-entry name, never an absolute host path.
	Name string
	// Kind identifies whether the object is a file, directory, link, or special file.
	Kind PathKind
}

// FileSystem is the read-only boundary for procfs, sysfs, and device-tree data.
type FileSystem interface {
	// ReadFile reads no more than maxBytes from one absolute Linux-style path.
	ReadFile(context.Context, string, int64) ([]byte, error)
	// ReadDir returns at most maxEntries deterministically sorted children.
	ReadDir(context.Context, string, int) ([]PathInfo, error)
	// ReadLink reads one symbolic-link target without following it.
	ReadLink(context.Context, string) (string, error)
	// Stat reports one object while following symbolic links.
	Stat(context.Context, string) (PathInfo, error)
}

// OSFileSystem implements bounded reads beneath one local root.
type OSFileSystem struct {
	// root is a descriptor-relative boundary corresponding to Linux path "/".
	root *os.Root
}

// NewOSFileSystem constructs a read-only filesystem rooted at root.
func NewOSFileSystem(root string) (*OSFileSystem, error) {
	if strings.TrimSpace(root) == "" {
		root = string(filepath.Separator)
	}
	absolute, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("resolve hardware diagnostic root: %w", err)
	}
	absolute, err = filepath.EvalSymlinks(absolute)
	if err != nil {
		return nil, fmt.Errorf("resolve hardware diagnostic root links: %w", err)
	}
	rootHandle, err := os.OpenRoot(absolute)
	if err != nil {
		return nil, fmt.Errorf("open hardware diagnostic root: %w", err)
	}
	return &OSFileSystem{root: rootHandle}, nil
}

// ReadFile returns a bounded file body and rejects oversized virtual files.
func (filesystem *OSFileSystem) ReadFile(ctx context.Context, logicalPath string, maxBytes int64) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if maxBytes < 1 {
		return nil, fmt.Errorf("read %s: invalid byte limit", logicalPath)
	}
	relativePath, err := filesystem.resolve(logicalPath)
	if err != nil {
		return nil, err
	}
	file, err := openDiagnosticFile(filesystem.root, relativePath)
	if err != nil {
		return nil, err
	}
	content, readErr := io.ReadAll(io.LimitReader(file, maxBytes+1))
	closeErr := file.Close()
	if err := errors.Join(readErr, closeErr); err != nil {
		return nil, err
	}
	if int64(len(content)) > maxBytes {
		return nil, ErrReadLimit
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return content, nil
}

// ReadDir returns bounded, sorted entry metadata without following children.
func (filesystem *OSFileSystem) ReadDir(ctx context.Context, logicalPath string, maxEntries int) ([]PathInfo, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if maxEntries < 1 {
		return nil, fmt.Errorf("read %s: invalid entry limit", logicalPath)
	}
	relativePath, err := filesystem.resolve(logicalPath)
	if err != nil {
		return nil, err
	}
	directory, err := filesystem.root.Open(relativePath)
	if err != nil {
		return nil, err
	}
	info, statErr := directory.Stat()
	if statErr != nil || !info.IsDir() {
		closeErr := directory.Close()
		if statErr != nil {
			return nil, errors.Join(statErr, closeErr)
		}
		if closeErr != nil {
			return nil, closeErr
		}
		return nil, fmt.Errorf("hardware diagnostic directory is not a directory")
	}
	entries, readErr := directory.Readdir(maxEntries + 1)
	if errors.Is(readErr, io.EOF) {
		readErr = nil
	}
	closeErr := directory.Close()
	if err := errors.Join(readErr, closeErr); err != nil {
		return nil, err
	}
	if len(entries) > maxEntries {
		return nil, ErrReadLimit
	}
	result := make([]PathInfo, 0, len(entries))
	for _, entry := range entries {
		result = append(result, PathInfo{Name: entry.Name(), Kind: pathKind(entry.Mode())})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

// ReadLink returns one bounded symbolic-link target.
func (filesystem *OSFileSystem) ReadLink(ctx context.Context, logicalPath string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	relativePath, err := filesystem.resolve(logicalPath)
	if err != nil {
		return "", err
	}
	target, err := filesystem.root.Readlink(relativePath)
	if err != nil {
		return "", err
	}
	if len(target) > 4096 {
		return "", ErrReadLimit
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	return target, nil
}

// Stat reports bounded object metadata while following symbolic links.
func (filesystem *OSFileSystem) Stat(ctx context.Context, logicalPath string) (PathInfo, error) {
	if err := ctx.Err(); err != nil {
		return PathInfo{}, err
	}
	relativePath, err := filesystem.resolve(logicalPath)
	if err != nil {
		return PathInfo{}, err
	}
	info, err := filesystem.root.Stat(relativePath)
	if err != nil {
		return PathInfo{}, err
	}
	if err := ctx.Err(); err != nil {
		return PathInfo{}, err
	}
	return PathInfo{Name: info.Name(), Kind: pathKind(info.Mode())}, nil
}

// resolve maps a fixed absolute Linux-style path to a descriptor-relative name.
func (filesystem *OSFileSystem) resolve(logicalPath string) (string, error) {
	if filesystem == nil || filesystem.root == nil {
		return "", errors.New("hardware diagnostic filesystem is not initialised")
	}
	if logicalPath == "" || !strings.HasPrefix(logicalPath, "/") || strings.ContainsRune(logicalPath, '\x00') {
		return "", fmt.Errorf("invalid hardware diagnostic path")
	}
	for _, segment := range strings.Split(strings.TrimPrefix(logicalPath, "/"), "/") {
		if segment == ".." {
			return "", fmt.Errorf("invalid hardware diagnostic path")
		}
	}
	cleaned := path.Clean(logicalPath)
	relative := strings.TrimPrefix(cleaned, "/")
	if relative == "" {
		return ".", nil
	}
	return filepath.FromSlash(relative), nil
}

// pathKind maps native file modes to the portable diagnostic vocabulary.
func pathKind(mode fs.FileMode) PathKind {
	switch {
	case mode&os.ModeSymlink != 0:
		return PathSymlink
	case mode.IsDir():
		return PathDirectory
	case mode.IsRegular():
		return PathRegular
	default:
		return PathOther
	}
}

// safeLeaf accepts only bounded child names returned beneath allow-listed roots.
func safeLeaf(name string) bool {
	if name == "" || len(name) > 255 || name == "." || name == ".." || strings.ContainsAny(name, "/\\") {
		return false
	}
	for _, character := range name {
		if character < 0x20 || character == 0x7f {
			return false
		}
	}
	return true
}
