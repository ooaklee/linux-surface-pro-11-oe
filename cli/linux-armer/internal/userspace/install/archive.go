package install

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"

	userspaceiptsd "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/iptsd"
)

// Archive layout and resource limits bound the trusted iptsd extraction.
const (
	iptsdArchiveRoot = userspaceiptsd.ArchiveRoot
	maxArchiveFiles  = 10000
	maxArchiveBytes  = 512 << 20
	maxArchiveFile   = 256 << 20
)

// SecureXZTarExtractor streams xz through Go's tar reader. It rejects every
// non-directory/non-regular entry, including all links and device nodes, and
// never delegates path interpretation to a general-purpose archive extractor.
type SecureXZTarExtractor struct {
	XZPath string
}

// Validate streams one xz archive through the secure tar parser without writes.
func (extractor SecureXZTarExtractor) Validate(ctx context.Context, archive string) error {
	return extractor.process(ctx, archive, "")
}

// Extract writes validated regular entries into a caller-owned empty directory.
func (extractor SecureXZTarExtractor) Extract(ctx context.Context, archive, destination string) error {
	destination, err := filepath.Abs(destination)
	if err != nil {
		return fmt.Errorf("resolve iptsd extraction directory: %w", err)
	}
	info, err := os.Lstat(destination)
	if err != nil {
		return fmt.Errorf("inspect iptsd extraction directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("iptsd extraction target must be a regular directory: %s", destination)
	}
	entries, err := os.ReadDir(destination)
	if err != nil {
		return fmt.Errorf("inspect iptsd extraction directory: %w", err)
	}
	if len(entries) != 0 {
		return errors.New("iptsd extraction directory must be empty")
	}
	return extractor.process(ctx, archive, destination)
}

// process connects xz output directly to the constrained Go tar parser.
func (extractor SecureXZTarExtractor) process(ctx context.Context, archive, destination string) error {
	archiveFile, _, err := openRegularNoFollow(archive)
	if err != nil {
		return fmt.Errorf("open iptsd archive: %w", err)
	}
	defer archiveFile.Close()
	xz := extractor.XZPath
	if xz == "" {
		xz = "xz"
	}
	command := exec.CommandContext(ctx, xz, "--decompress", "--stdout")
	command.Stdin = archiveFile
	var stderr bytes.Buffer
	command.Stderr = &stderr
	stdout, err := command.StdoutPipe()
	if err != nil {
		return fmt.Errorf("open xz output: %w", err)
	}
	if err := command.Start(); err != nil {
		return fmt.Errorf("start xz decompressor: %w", err)
	}
	processErr := processTar(tar.NewReader(stdout), destination)
	if processErr != nil && command.Process != nil {
		_ = command.Process.Kill()
	}
	waitErr := command.Wait()
	if processErr != nil {
		return processErr
	}
	if waitErr != nil {
		message := strings.TrimSpace(stderr.String())
		if message != "" {
			return fmt.Errorf("decompress iptsd archive: %w: %s", waitErr, message)
		}
		return fmt.Errorf("decompress iptsd archive: %w", waitErr)
	}
	return nil
}

// processTar validates every header and optionally extracts its bounded data.
func processTar(reader *tar.Reader, destination string) error {
	seen := map[string]bool{}
	var total int64
	entries := 0
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("read iptsd tar archive: %w", err)
		}
		entries++
		if entries > maxArchiveFiles {
			return fmt.Errorf("iptsd archive exceeds %d entries", maxArchiveFiles)
		}
		name, err := validateArchiveName(header.Name, header.Typeflag)
		if err != nil {
			return err
		}
		if seen[name] {
			return fmt.Errorf("iptsd archive contains duplicate entry %q", name)
		}
		seen[name] = true
		if header.Linkname != "" {
			return fmt.Errorf("iptsd archive entry %q has a forbidden link target", name)
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if destination != "" {
				if err := makeArchiveDirectory(destination, name, os.FileMode(header.Mode)); err != nil {
					return err
				}
			}
		case tar.TypeReg, tar.TypeRegA:
			if header.Size < 0 || header.Size > maxArchiveFile || total > maxArchiveBytes-header.Size {
				return fmt.Errorf("iptsd archive entry %q exceeds extraction limits", name)
			}
			total += header.Size
			if destination == "" {
				written, err := io.Copy(io.Discard, reader)
				if err != nil || written != header.Size {
					return fmt.Errorf("validate iptsd archive entry %q: expected %d bytes, read %d: %w", name, header.Size, written, err)
				}
				continue
			}
			if err := extractArchiveFile(reader, destination, name, header); err != nil {
				return err
			}
		default:
			return fmt.Errorf("iptsd archive entry %q uses forbidden tar type %d", name, header.Typeflag)
		}
	}
	if !seen[iptsdArchiveRoot] {
		return fmt.Errorf("iptsd archive does not contain root directory %q", iptsdArchiveRoot)
	}
	return nil
}

// validateArchiveName permits only canonical paths beneath the pinned root.
func validateArchiveName(name string, typeflag byte) (string, error) {
	if name == "" || strings.ContainsRune(name, '\x00') || strings.Contains(name, `\`) || strings.HasPrefix(name, "/") {
		return "", fmt.Errorf("iptsd archive contains unsafe path %q", name)
	}
	clean := path.Clean(name)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("iptsd archive contains unsafe path %q", name)
	}
	if name != clean && !(typeflag == tar.TypeDir && name == clean+"/") {
		return "", fmt.Errorf("iptsd archive contains non-canonical path %q", name)
	}
	if clean != iptsdArchiveRoot && !strings.HasPrefix(clean, iptsdArchiveRoot+"/") {
		return "", fmt.Errorf("iptsd archive path is outside %q: %q", iptsdArchiveRoot, name)
	}
	return clean, nil
}

// makeArchiveDirectory creates a validated archive directory with owner access.
func makeArchiveDirectory(destination, name string, mode os.FileMode) error {
	target, err := archiveTarget(destination, name)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(target, archiveMode(mode, true)); err != nil {
		return fmt.Errorf("create iptsd archive directory %s: %w", target, err)
	}
	return nil
}

// extractArchiveFile exclusively creates one bounded regular archive member.
func extractArchiveFile(reader *tar.Reader, destination, name string, header *tar.Header) error {
	target, err := archiveTarget(destination, name)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return fmt.Errorf("create iptsd archive parent: %w", err)
	}
	file, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, archiveMode(os.FileMode(header.Mode), false))
	if err != nil {
		return fmt.Errorf("create iptsd archive file %s: %w", target, err)
	}
	written, copyErr := io.Copy(file, reader)
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || written != header.Size {
		_ = os.Remove(target)
		return fmt.Errorf("extract iptsd archive entry %q: expected %d bytes, wrote %d: %w", name, header.Size, written, errors.Join(copyErr, closeErr))
	}
	return nil
}

// archiveTarget maps a canonical slash path into the empty extraction root.
func archiveTarget(destination, name string) (string, error) {
	target := filepath.Join(destination, filepath.FromSlash(name))
	if !withinRoot(destination, target) || target == destination {
		return "", fmt.Errorf("iptsd archive entry escapes extraction root: %q", name)
	}
	return target, nil
}

// archiveMode strips special bits while retaining executable payload scripts.
func archiveMode(mode os.FileMode, directory bool) os.FileMode {
	permissions := mode.Perm()
	if directory {
		if permissions == 0 {
			return 0o755
		}
		return permissions | 0o700
	}
	if permissions == 0 {
		return 0o600
	}
	return permissions
}
