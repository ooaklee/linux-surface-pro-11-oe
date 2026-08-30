package releaseprep

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
	"strings"
)

const (
	// maximumAssetBytes bounds every individual release input at eight GiB.
	maximumAssetBytes int64 = 8 << 30
	// maximumJSONBytes bounds each structured manifest at four MiB.
	maximumJSONBytes int64 = 4 << 20
	// maximumTextBytes bounds generated and licence text at sixteen MiB.
	maximumTextBytes int64 = 16 << 20
	// maximumSupplementaryAssets bounds source and licence list cardinality.
	maximumSupplementaryAssets = 16
	// maximumGitURLBytes mirrors the native builder's source-URL bound.
	maximumGitURLBytes = 2048
)

// portableNameExpression accepts a conservative release-asset filename subset.
var portableNameExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+~%-]{0,254}$`)

// digestExpression recognises a lowercase SHA-256 digest.
var digestExpression = regexp.MustCompile(`^[0-9a-f]{64}$`)

// releaseNameExpression accepts a conservative Git-tag-compatible subset.
var releaseNameExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// regularIdentity records one stable input before a later verified copy.
type regularIdentity struct {
	// path is the canonical local file path.
	path string
	// info binds the inspected filesystem object.
	info os.FileInfo
	// sha256 is the measured lowercase digest.
	sha256 string
	// size is the measured file length.
	size int64
}

// safeReleaseName rejects path-like, ambiguous, or unsupported release values.
func safeReleaseName(value string) bool {
	return releaseNameExpression.MatchString(value) && !strings.Contains(value, "..")
}

// safePortableName rejects paths, dot entries, controls, and reserved separators.
func safePortableName(value string) bool {
	return portableNameExpression.MatchString(value) && value != "." && value != ".." &&
		filepath.Base(value) == value && !strings.ContainsAny(value, `/\`)
}

// portableCollisionKey provides a cross-platform release filename identity.
func portableCollisionKey(value string) string {
	return strings.ToLower(value)
}

// canonicalDirectory resolves one existing, non-symbolic-link directory.
func canonicalDirectory(path, label string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", fmt.Errorf("%s is required", label)
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", label, err)
	}
	info, err := os.Lstat(absolute)
	if err != nil {
		return "", fmt.Errorf("inspect %s: %w", label, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("%s is not a non-symbolic-link directory: %s", label, absolute)
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil || filepath.Clean(resolved) != filepath.Clean(absolute) {
		return "", fmt.Errorf("%s resolves through a symbolic link: %s", label, absolute)
	}
	return filepath.Clean(absolute), nil
}

// canonicalNewOutput resolves an absent output and verifies its existing parent route.
func canonicalNewOutput(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", errors.New("output directory is required")
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve output directory: %w", err)
	}
	if _, err := os.Lstat(absolute); !errors.Is(err, os.ErrNotExist) {
		if err == nil {
			return "", fmt.Errorf("output directory already exists: %s", absolute)
		}
		return "", fmt.Errorf("inspect output directory: %w", err)
	}
	parent := filepath.Dir(absolute)
	ancestor := parent
	for {
		_, statErr := os.Lstat(ancestor)
		if statErr == nil {
			break
		}
		if !errors.Is(statErr, os.ErrNotExist) {
			return "", fmt.Errorf("inspect output ancestor: %w", statErr)
		}
		next := filepath.Dir(ancestor)
		if next == ancestor {
			return "", errors.New("could not locate an existing output ancestor")
		}
		ancestor = next
	}
	if _, err := canonicalDirectory(ancestor, "output ancestor"); err != nil {
		return "", err
	}
	return filepath.Clean(absolute), nil
}

// pathWithin reports whether candidate is equal to or beneath parent.
func pathWithin(parent, candidate string) bool {
	relative, err := filepath.Rel(parent, candidate)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// inspectRegular hashes one stable, bounded, non-symbolic-link input.
func inspectRegular(ctx context.Context, path, label string, maximum int64) (regularIdentity, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return regularIdentity{}, fmt.Errorf("resolve %s: %w", label, err)
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil || filepath.Clean(resolved) != filepath.Clean(absolute) {
		return regularIdentity{}, fmt.Errorf("%s resolves through a symbolic link: %s", label, absolute)
	}
	info, err := os.Lstat(absolute)
	if err != nil {
		return regularIdentity{}, fmt.Errorf("inspect %s: %w", label, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximum {
		return regularIdentity{}, fmt.Errorf("%s is not a bounded non-empty regular file: %s", label, absolute)
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
		return regularIdentity{}, fmt.Errorf("%s changed while it was read: %s", label, absolute)
	}
	return regularIdentity{path: filepath.Clean(absolute), info: info, sha256: hex.EncodeToString(hasher.Sum(nil)), size: written}, nil
}

// copyContext copies a bounded stream while honouring caller cancellation.
func copyContext(ctx context.Context, destination io.Writer, source io.Reader, maximum int64) (int64, error) {
	buffer := make([]byte, 128*1024)
	var total int64
	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		count, readErr := source.Read(buffer)
		if count > 0 {
			total += int64(count)
			if total > maximum {
				return total, errors.New("input exceeds its size limit")
			}
			if _, err := destination.Write(buffer[:count]); err != nil {
				return total, err
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

// readBoundedJSON decodes one stable JSON file and rejects unknown or trailing fields.
func readBoundedJSON(ctx context.Context, path, label string, destination any) error {
	identity, err := inspectRegular(ctx, path, label, maximumJSONBytes)
	if err != nil {
		return err
	}
	contents, err := readStableIdentity(identity, maximumJSONBytes)
	if err != nil {
		return fmt.Errorf("read %s: %w", label, err)
	}
	decoder := newStrictJSONDecoder(bytes.NewReader(contents))
	decodeErr := decoder.Decode(destination)
	trailingErr := requireJSONEOF(decoder)
	if err := errors.Join(decodeErr, trailingErr); err != nil {
		return fmt.Errorf("decode %s: %w", label, err)
	}
	return nil
}

// readStableIdentity rereads an inspected file and proves that both identity
// and digest stayed unchanged.
func readStableIdentity(identity regularIdentity, maximum int64) ([]byte, error) {
	file, err := os.Open(identity.path)
	if err != nil {
		return nil, err
	}
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(identity.info, opened) {
		_ = file.Close()
		return nil, errors.New("file identity changed while opening")
	}
	contents, readErr := io.ReadAll(io.LimitReader(file, maximum+1))
	closeErr := file.Close()
	current, statErr := os.Lstat(identity.path)
	if err := errors.Join(readErr, closeErr, statErr); err != nil {
		return nil, err
	}
	if int64(len(contents)) != identity.size || int64(len(contents)) > maximum ||
		current.Mode()&os.ModeSymlink != 0 || !os.SameFile(identity.info, current) {
		return nil, errors.New("file identity changed while reading")
	}
	digest := sha256.Sum256(contents)
	if hex.EncodeToString(digest[:]) != identity.sha256 {
		return nil, errors.New("file digest changed while reading")
	}
	return contents, nil
}

// checksumEntries parses an exact, bounded SHA256SUMS file.
func checksumEntries(ctx context.Context, path string) (map[string]string, error) {
	identity, err := inspectRegular(ctx, path, ChecksumFileName, maximumTextBytes)
	if err != nil {
		return nil, err
	}
	contents, err := readStableIdentity(identity, maximumTextBytes)
	if err != nil {
		return nil, err
	}
	entries := make(map[string]string)
	scanner := bufio.NewScanner(bytes.NewReader(contents))
	scanner.Buffer(make([]byte, 4096), int(maximumTextBytes))
	for line := 1; scanner.Scan(); line++ {
		fields := strings.Fields(scanner.Text())
		if len(fields) != 2 || !digestExpression.MatchString(fields[0]) {
			return nil, fmt.Errorf("%s:%d is malformed", ChecksumFileName, line)
		}
		name := strings.TrimPrefix(fields[1], "*")
		if !safePortableName(name) {
			return nil, fmt.Errorf("%s:%d contains unsafe filename %q", ChecksumFileName, line, name)
		}
		if _, duplicate := entries[name]; duplicate {
			return nil, fmt.Errorf("%s contains duplicate filename %q", ChecksumFileName, name)
		}
		entries[name] = fields[0]
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, fmt.Errorf("%s is empty", ChecksumFileName)
	}
	return entries, nil
}

// sortedKeys returns deterministic map keys.
func sortedKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
