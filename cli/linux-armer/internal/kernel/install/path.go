package install

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	// maximumPackageBytes bounds one accepted Debian package at four GiB.
	maximumPackageBytes int64 = 4 << 30
	// copyBufferBytes bounds memory used while hashing or staging large packages.
	copyBufferBytes = 1 << 20
)

// canonicalRoot validates an explicit absolute, non-symlink filesystem root.
func canonicalRoot(root string) (string, error) {
	if strings.TrimSpace(root) == "" {
		return "", errors.New("kernel target root is required")
	}
	if !filepath.IsAbs(root) || filepath.Clean(root) != root {
		return "", fmt.Errorf("kernel target root must be canonical and absolute: %q", root)
	}
	info, err := os.Lstat(root)
	if err != nil {
		return "", fmt.Errorf("inspect kernel target root %q: %w", root, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("kernel target root must be a non-symlink directory: %q", root)
	}
	return root, nil
}

// rootPath converts one compiled slash-separated path into the selected root.
func rootPath(root, relative string) (string, error) {
	if relative == "" || filepath.IsAbs(relative) || strings.Contains(relative, `\`) {
		return "", fmt.Errorf("unsafe kernel target path %q", relative)
	}
	cleanSlash := filepath.ToSlash(filepath.Clean(filepath.FromSlash(relative)))
	if cleanSlash != relative || relative == "." || relative == ".." || strings.HasPrefix(relative, "../") {
		return "", fmt.Errorf("unsafe kernel target path %q", relative)
	}
	target := filepath.Join(root, filepath.FromSlash(relative))
	within, err := filepath.Rel(root, target)
	if err != nil || within == ".." || strings.HasPrefix(within, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("kernel target path escapes selected root: %q", relative)
	}
	return target, nil
}

// validateTargetRoute rejects symbolic links and non-directory parents beneath
// the selected root while permitting a not-yet-created suffix when requested.
func validateTargetRoute(root, target string, allowMissing bool) error {
	relative, err := filepath.Rel(root, target)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return fmt.Errorf("kernel target path escapes selected root: %s", target)
	}
	current := root
	parts := strings.Split(relative, string(filepath.Separator))
	for index, part := range parts {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) && allowMissing {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect kernel target route %s: %w", current, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("kernel target route contains a symbolic link: %s", current)
		}
		if index < len(parts)-1 && !info.IsDir() {
			return fmt.Errorf("kernel target route contains a non-directory parent: %s", current)
		}
	}
	return nil
}

// canonicalPackagePath validates one immutable, regular, non-symlink package.
func canonicalPackagePath(path, expectedName string) (string, os.FileInfo, error) {
	if strings.TrimSpace(path) == "" || !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return "", nil, fmt.Errorf("package %s requires a canonical absolute path", expectedName)
	}
	if filepath.Base(path) != expectedName {
		return "", nil, fmt.Errorf("package path basename %q does not match manifest name %q", filepath.Base(path), expectedName)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", nil, fmt.Errorf("inspect package %s: %w", expectedName, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", nil, fmt.Errorf("package %s must be a regular file and must not be a symbolic link", expectedName)
	}
	if info.Size() <= 0 || info.Size() > maximumPackageBytes {
		return "", nil, fmt.Errorf("package %s size %d is outside the supported range", expectedName, info.Size())
	}
	return path, info, nil
}

// openUnchangedRegular pins a regular file and verifies its directory entry did
// not change between the caller's inspection and the open operation.
func openUnchangedRegular(path string, expected os.FileInfo) (*os.File, os.FileInfo, error) {
	entry, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if entry.Mode()&os.ModeSymlink != 0 || !entry.Mode().IsRegular() {
		return nil, nil, fmt.Errorf("path is not a regular, non-symlink file: %s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	opened, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, nil, err
	}
	if !os.SameFile(entry, opened) || (expected != nil && !os.SameFile(expected, opened)) {
		_ = file.Close()
		return nil, nil, fmt.Errorf("file identity changed before it could be pinned: %s", path)
	}
	return file, opened, nil
}

// digestReader hashes a bounded stream while honouring cancellation between chunks.
func digestReader(ctx context.Context, reader io.Reader, writer io.Writer, maximum int64) (string, int64, error) {
	hash := sha256.New()
	destination := io.Writer(hash)
	if writer != nil {
		destination = io.MultiWriter(hash, writer)
	}
	buffer := make([]byte, copyBufferBytes)
	var total int64
	for {
		if err := ctx.Err(); err != nil {
			return "", total, err
		}
		read, readErr := reader.Read(buffer)
		if read > 0 {
			if total > maximum-int64(read) {
				return "", total, fmt.Errorf("file exceeds the %d-byte safety limit", maximum)
			}
			written, writeErr := destination.Write(buffer[:read])
			total += int64(written)
			if writeErr != nil {
				return "", total, writeErr
			}
			if written != read {
				return "", total, io.ErrShortWrite
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return "", total, readErr
		}
		if read == 0 {
			return "", total, io.ErrNoProgress
		}
	}
	return hex.EncodeToString(hash.Sum(nil)), total, nil
}

// hashRegular hashes one pinned regular file and verifies its path identity
// once more after reading it.
func hashRegular(ctx context.Context, path string, expected os.FileInfo, maximum int64) (FileEvidence, error) {
	file, opened, err := openUnchangedRegular(path, expected)
	if err != nil {
		return FileEvidence{}, err
	}
	digest, size, readErr := digestReader(ctx, file, nil, maximum)
	closeErr := file.Close()
	entry, statErr := os.Lstat(path)
	if readErr != nil || closeErr != nil || statErr != nil {
		return FileEvidence{}, errors.Join(readErr, closeErr, statErr)
	}
	if entry.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, entry) || entry.Size() != size {
		return FileEvidence{}, fmt.Errorf("file changed while it was being inspected: %s", path)
	}
	return FileEvidence{Path: path, SHA256: digest, Size: size}, nil
}

// requireRegularEvidence verifies one non-empty, bounded regular boot file.
func requireRegularEvidence(ctx context.Context, kind, path string) (FileEvidence, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return FileEvidence{}, fmt.Errorf("inspect %s %s: %w", kind, path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() <= 0 {
		return FileEvidence{}, fmt.Errorf("%s must be a non-empty regular file: %s", kind, path)
	}
	evidence, err := hashRegular(ctx, path, info, maximumPackageBytes)
	if err != nil {
		return FileEvidence{}, fmt.Errorf("hash %s %s: %w", kind, path, err)
	}
	evidence.Kind = kind
	return evidence, nil
}
