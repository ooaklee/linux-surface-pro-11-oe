package install

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// resolveTarget interprets absolute links as target-root-relative and rejects
// every path whose resolved parent leaves the selected root.
func resolveTarget(root, relative string) (string, error) {
	return resolveTargetDepth(root, relative, 0)
}

// resolveTargetDepth bounds recursive parent-link resolution.
func resolveTargetDepth(root, relative string, depth int) (string, error) {
	if depth > 40 {
		return "", errors.New("too many symlinks in userspace target path")
	}
	if relative == "" || filepath.IsAbs(relative) || strings.Contains(relative, `\`) {
		return "", fmt.Errorf("unsafe userspace target path %q", relative)
	}
	clean := filepath.Clean(filepath.FromSlash(relative))
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("unsafe userspace target path %q", relative)
	}
	current := root
	parts := strings.Split(clean, string(filepath.Separator))
	for index, part := range parts {
		candidate := filepath.Join(current, part)
		info, err := os.Lstat(candidate)
		if errors.Is(err, os.ErrNotExist) {
			current = candidate
			continue
		}
		if err != nil {
			return "", fmt.Errorf("inspect userspace target path %s: %w", candidate, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			if index == len(parts)-1 {
				return "", fmt.Errorf("refusing symlinked userspace target %s", candidate)
			}
			link, err := os.Readlink(candidate)
			if err != nil {
				return "", fmt.Errorf("read userspace target parent %s: %w", candidate, err)
			}
			rechecked, recheckErr := os.Lstat(candidate)
			recheckedLink, rereadErr := os.Readlink(candidate)
			if recheckErr != nil || rereadErr != nil || !os.SameFile(info, rechecked) || recheckedLink != link {
				return "", fmt.Errorf("userspace target parent changed while resolving: %s", candidate)
			}
			var linkDestination string
			if filepath.IsAbs(link) {
				linkDestination = filepath.Join(root, strings.TrimLeft(filepath.Clean(link), string(filepath.Separator)))
			} else {
				linkDestination = filepath.Clean(filepath.Join(filepath.Dir(candidate), link))
			}
			if !withinRoot(root, linkDestination) {
				return "", fmt.Errorf("userspace target parent escapes selected root: %s", candidate)
			}
			linkRelative, err := filepath.Rel(root, linkDestination)
			if err != nil {
				return "", fmt.Errorf("resolve userspace target parent %s: %w", candidate, err)
			}
			resolvedSentinel, err := resolveTargetDepth(root, filepath.ToSlash(filepath.Join(linkRelative, ".linux-armer-link-sentinel")), depth+1)
			if err != nil {
				return "", err
			}
			current = filepath.Dir(resolvedSentinel)
			continue
		}
		if index < len(parts)-1 && !info.IsDir() {
			return "", fmt.Errorf("userspace target parent is not a directory: %s", candidate)
		}
		if index == len(parts)-1 && !info.Mode().IsRegular() {
			return "", fmt.Errorf("userspace target is not a regular file: %s", candidate)
		}
		current = candidate
	}
	if !withinRoot(root, current) || current == root {
		return "", fmt.Errorf("userspace target escapes selected root: %s", relative)
	}
	return filepath.Clean(current), nil
}

// withinRoot performs component-aware containment rather than prefix matching.
func withinRoot(root, candidate string) bool {
	relative, err := filepath.Rel(root, candidate)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// openRegularNoFollow pins a regular inode without following a final symlink.
func openRegularNoFollow(path string) (*os.File, os.FileInfo, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, nil, err
	}
	if !info.Mode().IsRegular() {
		_ = file.Close()
		return nil, nil, fmt.Errorf("source is not a regular file: %s", path)
	}
	return file, info, nil
}

// hashRegularNoFollow hashes the same no-follow descriptor returned by stat.
func hashRegularNoFollow(path string) (string, os.FileInfo, error) {
	file, info, err := openRegularNoFollow(path)
	if err != nil {
		return "", nil, err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", nil, err
	}
	return hex.EncodeToString(hash.Sum(nil)), info, nil
}

// atomicCopyVerified hashes bytes while copying them, rereads the temporary
// file, and only then publishes the verified inode at the destination.
func atomicCopyVerified(source, destination string, mode os.FileMode, expectedDigest string, expectedSize int64) error {
	sourceFile, sourceInfo, err := openRegularNoFollow(source)
	if err != nil {
		return fmt.Errorf("open source %s: %w", source, err)
	}
	defer sourceFile.Close()
	if expectedSize >= 0 && sourceInfo.Size() != expectedSize {
		return fmt.Errorf("source size changed for %s", source)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return fmt.Errorf("create target directory: %w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(destination), ".linux-armer-install-*")
	if err != nil {
		return fmt.Errorf("create atomic install file: %w", err)
	}
	temporaryName := temporary.Name()
	removeTemporary := true
	defer func() {
		_ = temporary.Close()
		if removeTemporary {
			_ = os.Remove(temporaryName)
		}
	}()
	if err := temporary.Chmod(mode.Perm()); err != nil {
		return fmt.Errorf("set atomic install mode: %w", err)
	}
	copiedHash := sha256.New()
	written, err := io.Copy(io.MultiWriter(temporary, copiedHash), sourceFile)
	if err != nil {
		return fmt.Errorf("copy atomic install file: %w", err)
	}
	if written != sourceInfo.Size() || expectedSize >= 0 && written != expectedSize {
		return fmt.Errorf("source size changed while copying %s", source)
	}
	copiedDigest := hex.EncodeToString(copiedHash.Sum(nil))
	if expectedDigest != "" && copiedDigest != expectedDigest {
		return fmt.Errorf("source digest changed for %s", source)
	}
	currentSourceInfo, err := sourceFile.Stat()
	if err != nil || currentSourceInfo.Size() != sourceInfo.Size() {
		return fmt.Errorf("source metadata changed while copying %s", source)
	}
	if err := temporary.Sync(); err != nil {
		return fmt.Errorf("sync atomic install file: %w", err)
	}
	if _, err := temporary.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("rewind atomic install file: %w", err)
	}
	publishedHash := sha256.New()
	if _, err := io.Copy(publishedHash, temporary); err != nil {
		return fmt.Errorf("reverify atomic install file: %w", err)
	}
	if hex.EncodeToString(publishedHash.Sum(nil)) != copiedDigest {
		return fmt.Errorf("atomic install file changed before publication: %s", destination)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close atomic install file: %w", err)
	}
	if targetInfo, err := os.Lstat(destination); err == nil && targetInfo.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing symlinked userspace target %s", destination)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("revalidate userspace target %s: %w", destination, err)
	}
	if err := os.Rename(temporaryName, destination); err != nil {
		return fmt.Errorf("publish userspace target %s: %w", destination, err)
	}
	removeTemporary = false
	return syncDirectory(filepath.Dir(destination))
}

// syncDirectory makes a preceding atomic publication durable before the
// installer advances to service activation or another transaction member.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open userspace target directory for sync: %w", err)
	}
	return errors.Join(directory.Sync(), directory.Close())
}
