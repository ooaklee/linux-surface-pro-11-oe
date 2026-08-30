package release

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	// maximumSourceBytes bounds every reviewed audio source input at 64 MiB.
	maximumSourceBytes int64 = 64 << 20
	// maximumManifestBytes bounds structured release input at two MiB.
	maximumManifestBytes int64 = 2 << 20
	// maximumTextBytes bounds checksum and notes files at one MiB.
	maximumTextBytes int64 = 1 << 20
	// maximumSourceChecksumEntries bounds source-manifest work and file handles.
	maximumSourceChecksumEntries = 64
	// copyBufferBytes bounds memory used by streaming file operations.
	copyBufferBytes = 128 * 1024
	// maximumJSONDepth prevents recursive JSON resource exhaustion.
	maximumJSONDepth = 64
)

// releaseNameExpression accepts conservative portable release names.
var releaseNameExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// digestExpression recognises one canonical lowercase SHA-256 digest.
var digestExpression = regexp.MustCompile(`^[0-9a-f]{64}$`)

// kernelABIExpression extracts one exact qcom-x1e Surface kernel generation.
var kernelABIExpression = regexp.MustCompile(`^([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.+]+)*-0sp11v([0-9]+))-qcom-x1e$`)

// regularIdentity binds a path to the regular object and bytes inspected there.
type regularIdentity struct {
	// path is the absolute local file path used only during this invocation.
	path string
	// info identifies the exact filesystem object inspected at path.
	info os.FileInfo
	// record is the portable digest and byte length.
	record FileRecord
}

// sourceSnapshot retains stable local identities alongside public provenance.
type sourceSnapshot struct {
	// provenance is the path-free validated source record.
	provenance SourceProvenance
	// inputs contains the role-specific source identities in policy order.
	inputs []regularIdentity
}

// canonicalDirectory resolves one existing directory without symbolic links.
func canonicalDirectory(selected, label string) (string, error) {
	if strings.TrimSpace(selected) == "" {
		return "", fmt.Errorf("%s is required", label)
	}
	absolute, err := filepath.Abs(selected)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", label, err)
	}
	absolute = filepath.Clean(absolute)
	info, err := os.Lstat(absolute)
	if err != nil {
		return "", fmt.Errorf("inspect %s: %w", label, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("%s must be a real non-symbolic-link directory", label)
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil || filepath.Clean(resolved) != absolute {
		return "", fmt.Errorf("%s route contains a symbolic link", label)
	}
	return absolute, nil
}

// containedBy reports equality or component-aware descent beneath parent.
func containedBy(parent, candidate string) bool {
	relative, err := filepath.Rel(filepath.Clean(parent), filepath.Clean(candidate))
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// rejectSymbolicRoute proves every existing path component beneath root is real.
func rejectSymbolicRoute(root, target string) error {
	if !containedBy(root, target) {
		return fmt.Errorf("path escapes its trusted root: %s", target)
	}
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return err
	}
	current := root
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		if component == "." || component == "" {
			continue
		}
		current = filepath.Join(current, component)
		info, statErr := os.Lstat(current)
		if errors.Is(statErr, os.ErrNotExist) {
			return nil
		}
		if statErr != nil {
			return fmt.Errorf("inspect path route: %w", statErr)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("path route contains a symbolic link: %s", current)
		}
	}
	return nil
}

// ensureDirectory creates one contained directory tree without following links.
func ensureDirectory(root, target string, mode os.FileMode) error {
	if !containedBy(root, target) {
		return fmt.Errorf("directory escapes repository root: %s", target)
	}
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return err
	}
	current := root
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		if component == "." || component == "" {
			continue
		}
		current = filepath.Join(current, component)
		info, statErr := os.Lstat(current)
		switch {
		case statErr == nil && info.Mode()&os.ModeSymlink != 0:
			return fmt.Errorf("directory route contains a symbolic link: %s", current)
		case statErr == nil && !info.IsDir():
			return fmt.Errorf("directory route contains a non-directory: %s", current)
		case statErr == nil:
			continue
		case !errors.Is(statErr, os.ErrNotExist):
			return fmt.Errorf("inspect directory route: %w", statErr)
		}
		if err := os.Mkdir(current, mode); err != nil {
			return fmt.Errorf("create release directory route: %w", err)
		}
	}
	return nil
}

// safePortableName accepts one conservative non-hidden release basename.
func safePortableName(value string) bool {
	return value != "" && value != "." && value != ".." && filepath.Base(value) == value &&
		releaseNameExpression.MatchString(value) && !strings.Contains(value, "..")
}

// parseKernelPair proves an exact kernel-tag and installed-ABI relationship.
func parseKernelPair(kernelTag, kernelABI string) (int, error) {
	if !safePortableName(kernelTag) || strings.TrimSpace(kernelABI) != kernelABI {
		return 0, errors.New("paired kernel tag and ABI must be portable explicit values")
	}
	matches := kernelABIExpression.FindStringSubmatch(kernelABI)
	if len(matches) != 3 || kernelTag != "sp11-qcom-x1e-"+matches[1] {
		return 0, errors.New("paired kernel tag and ABI must identify the same exact qcom-x1e version")
	}
	generation, err := strconv.Atoi(matches[2])
	if err != nil || generation < 12 || generation > 19 {
		return 0, errors.New("FullIO v19c supports explicit Surface kernel generations sp11v12 through sp11v19")
	}
	return generation, nil
}

// inspectRegular hashes one stable, bounded, non-symbolic-link regular file.
func inspectRegular(ctx context.Context, selected, label string, maximum int64) (regularIdentity, error) {
	if err := ctx.Err(); err != nil {
		return regularIdentity{}, err
	}
	absolute, err := filepath.Abs(selected)
	if err != nil {
		return regularIdentity{}, fmt.Errorf("resolve %s: %w", label, err)
	}
	info, err := os.Lstat(absolute)
	if err != nil {
		return regularIdentity{}, fmt.Errorf("inspect %s: %w", label, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximum {
		return regularIdentity{}, fmt.Errorf("%s must be a bounded non-empty regular file", label)
	}
	file, err := os.Open(absolute)
	if err != nil {
		return regularIdentity{}, fmt.Errorf("open %s: %w", label, err)
	}
	hasher := sha256.New()
	written, copyErr := copyContext(ctx, hasher, file, maximum)
	closeErr := file.Close()
	current, statErr := os.Lstat(absolute)
	if err := errors.Join(copyErr, closeErr, statErr); err != nil {
		return regularIdentity{}, fmt.Errorf("hash %s: %w", label, err)
	}
	if current.Mode()&os.ModeSymlink != 0 || !os.SameFile(info, current) || written != info.Size() {
		return regularIdentity{}, fmt.Errorf("%s changed while it was inspected", label)
	}
	return regularIdentity{
		path: absolute,
		info: info,
		record: FileRecord{
			Name: filepath.Base(absolute), SHA256: hex.EncodeToString(hasher.Sum(nil)), Size: written,
		},
	}, nil
}

// copyContext copies a bounded stream while honouring cancellation.
func copyContext(ctx context.Context, destination io.Writer, source io.Reader, maximum int64) (int64, error) {
	buffer := make([]byte, copyBufferBytes)
	var total int64
	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		count, readErr := source.Read(buffer)
		if count > 0 {
			total += int64(count)
			if total > maximum {
				return total, fmt.Errorf("input exceeds its %d-byte limit", maximum)
			}
			written, writeErr := destination.Write(buffer[:count])
			if writeErr != nil {
				return total, writeErr
			}
			if written != count {
				return total, io.ErrShortWrite
			}
		}
		if errors.Is(readErr, io.EOF) {
			return total, nil
		}
		if readErr != nil {
			return total, readErr
		}
	}
}

// readIdentity rereads a bounded file and proves its object and bytes stayed stable.
func readIdentity(ctx context.Context, identity regularIdentity, maximum int64) ([]byte, error) {
	file, err := os.Open(identity.path)
	if err != nil {
		return nil, err
	}
	opened, statErr := file.Stat()
	if statErr != nil || !opened.Mode().IsRegular() || !os.SameFile(identity.info, opened) {
		_ = file.Close()
		return nil, errors.New("file identity changed before it was read")
	}
	var output bytes.Buffer
	written, copyErr := copyContext(ctx, &output, file, maximum)
	closeErr := file.Close()
	current, currentErr := os.Lstat(identity.path)
	if err := errors.Join(copyErr, closeErr, currentErr); err != nil {
		return nil, err
	}
	digest := sha256.Sum256(output.Bytes())
	if written != identity.record.Size || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(identity.info, current) || hex.EncodeToString(digest[:]) != identity.record.SHA256 {
		return nil, errors.New("file identity or bytes changed while they were read")
	}
	return output.Bytes(), nil
}

// copyIdentity writes one inspected source exclusively and repeats its proof.
func copyIdentity(ctx context.Context, identity regularIdentity, destination string) error {
	source, err := os.Open(identity.path)
	if err != nil {
		return err
	}
	opened, statErr := source.Stat()
	if statErr != nil || !opened.Mode().IsRegular() || !os.SameFile(identity.info, opened) {
		_ = source.Close()
		return errors.New("source identity changed before copying")
	}
	target, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		_ = source.Close()
		return err
	}
	hasher := sha256.New()
	written, copyErr := copyContext(ctx, io.MultiWriter(target, hasher), source, maximumSourceBytes)
	syncErr := target.Sync()
	closeTargetErr := target.Close()
	closeSourceErr := source.Close()
	current, currentErr := os.Lstat(identity.path)
	if err := errors.Join(copyErr, syncErr, closeTargetErr, closeSourceErr, currentErr); err != nil {
		return err
	}
	if written != identity.record.Size || hex.EncodeToString(hasher.Sum(nil)) != identity.record.SHA256 || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(identity.info, current) {
		return errors.New("source identity or bytes changed while copying")
	}
	return os.Chmod(destination, 0o644)
}

// writeExclusive creates, syncs, and closes one fresh generated regular file.
func writeExclusive(destination string, data []byte) error {
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	written, writeErr := file.Write(data)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		return err
	}
	if written != len(data) {
		return io.ErrShortWrite
	}
	return os.Chmod(destination, 0o644)
}

// parseSourceChecksums strictly decodes bounded GNU SHA-256 records.
func parseSourceChecksums(data []byte) ([]FileRecord, error) {
	if len(data) == 0 || int64(len(data)) > maximumTextBytes || data[len(data)-1] != '\n' {
		return nil, errors.New("source SHA256SUMS must be non-empty, bounded, and newline-terminated")
	}
	seen := make(map[string]struct{})
	records := make([]FileRecord, 0)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 1024), 4096)
	for scanner.Scan() {
		line := scanner.Text()
		if len(line) < 67 || !digestExpression.MatchString(line[:64]) || (line[64:66] != "  " && line[64:66] != " *") {
			return nil, errors.New("source SHA256SUMS contains a malformed record")
		}
		name := line[66:]
		if !safePortableName(name) {
			return nil, fmt.Errorf("source SHA256SUMS contains an unsafe name: %q", name)
		}
		if _, exists := seen[name]; exists {
			return nil, fmt.Errorf("source SHA256SUMS repeats %q", name)
		}
		seen[name] = struct{}{}
		records = append(records, FileRecord{Name: name, SHA256: line[:64]})
		if len(records) > maximumSourceChecksumEntries {
			return nil, errors.New("source SHA256SUMS contains too many records")
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read source SHA256SUMS: %w", err)
	}
	if len(records) == 0 {
		return nil, errors.New("source SHA256SUMS contains no records")
	}
	sort.Slice(records, func(first, second int) bool { return records[first].Name < records[second].Name })
	return records, nil
}

// snapshotSource validates every source-manifest entry and four compiled pins.
func snapshotSource(ctx context.Context, root string, selected policy) (sourceSnapshot, error) {
	checksumPath := filepath.Join(root, filepath.FromSlash(selected.checksumRelativePath))
	if err := rejectSymbolicRoute(root, checksumPath); err != nil {
		return sourceSnapshot{}, err
	}
	checksumIdentity, err := inspectRegular(ctx, checksumPath, "source checksum manifest", maximumTextBytes)
	if err != nil {
		return sourceSnapshot{}, err
	}
	checksumData, err := readIdentity(ctx, checksumIdentity, maximumTextBytes)
	if err != nil {
		return sourceSnapshot{}, fmt.Errorf("read source checksum manifest: %w", err)
	}
	checksumRecords, err := parseSourceChecksums(checksumData)
	if err != nil {
		return sourceSnapshot{}, err
	}
	nativeDirectory := filepath.Dir(checksumPath)
	validated := make([]FileRecord, 0, len(checksumRecords))
	validatedIdentities := make(map[string]regularIdentity, len(checksumRecords))
	for _, expected := range checksumRecords {
		candidate := filepath.Join(nativeDirectory, expected.Name)
		if err := rejectSymbolicRoute(nativeDirectory, candidate); err != nil {
			return sourceSnapshot{}, err
		}
		identity, inspectErr := inspectRegular(ctx, candidate, "source checksum entry "+expected.Name, maximumSourceBytes)
		if inspectErr != nil {
			return sourceSnapshot{}, inspectErr
		}
		if identity.record.SHA256 != expected.SHA256 {
			return sourceSnapshot{}, fmt.Errorf("source checksum mismatch for %s", expected.Name)
		}
		validated = append(validated, identity.record)
		validatedIdentities[expected.Name] = identity
	}
	inputs := make([]regularIdentity, 0, len(selected.sources))
	inputRecords := make([]SourceInput, 0, len(selected.sources))
	for _, spec := range selected.sources {
		candidate := filepath.Join(root, filepath.FromSlash(spec.relativePath))
		if err := rejectSymbolicRoute(root, candidate); err != nil {
			return sourceSnapshot{}, err
		}
		identity, present := validatedIdentities[filepath.Base(candidate)]
		if !present || filepath.Clean(identity.path) != filepath.Clean(candidate) {
			identity, err = inspectRegular(ctx, candidate, "pinned "+spec.role+" source", maximumSourceBytes)
			if err != nil {
				return sourceSnapshot{}, err
			}
		}
		if identity.record.SHA256 != spec.sha256 || (spec.expectedSize > 0 && identity.record.Size != spec.expectedSize) {
			return sourceSnapshot{}, fmt.Errorf("pinned %s source identity does not match the reviewed v19c contract", spec.role)
		}
		if spec.role == "topology" {
			manifestIdentity, exists := validatedIdentities[filepath.Base(candidate)]
			if !exists || manifestIdentity.record.SHA256 != spec.sha256 || !os.SameFile(identity.info, manifestIdentity.info) {
				return sourceSnapshot{}, errors.New("source SHA256SUMS does not authenticate the pinned FullIO topology")
			}
		}
		inputs = append(inputs, identity)
		inputRecords = append(inputRecords, SourceInput{Role: spec.role, File: identity.record})
	}
	return sourceSnapshot{provenance: SourceProvenance{
		Release: selected.sourceRelease, Revision: selected.sourceRevision,
		ChecksumManifest: checksumIdentity.record, ValidatedChecksums: validated, Inputs: inputRecords,
	}, inputs: inputs}, nil
}

// inspectData returns the portable identity for generated in-memory bytes.
func inspectData(name string, data []byte) FileRecord {
	digest := sha256.Sum256(data)
	return FileRecord{Name: name, SHA256: hex.EncodeToString(digest[:]), Size: int64(len(data))}
}
