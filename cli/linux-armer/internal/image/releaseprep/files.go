package releaseprep

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const (
	// maximumImageBytes bounds one source or reconstructed ISO at 64 GiB.
	maximumImageBytes int64 = 64 << 30
	// maximumJSONBytes bounds each structured sidecar at four MiB.
	maximumJSONBytes int64 = 4 << 20
	// maximumTextBytes bounds generated notes and checksum records at sixteen MiB.
	maximumTextBytes int64 = 16 << 20
	// maximumPartCount prevents hostile part-size choices from exhausting files.
	maximumPartCount = 4096
	// copyBufferBytes bounds memory used by every streaming file operation.
	copyBufferBytes = 256 * 1024
	// maximumJSONDepth prevents attacker-controlled recursive stack exhaustion.
	maximumJSONDepth = 128
)

// portableNameExpression accepts conservative hosted-release basenames.
var portableNameExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+~%-]{0,254}$`)

// releaseNameExpression accepts conservative Git-tag-compatible names.
var releaseNameExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// digestExpression recognises one canonical lowercase SHA-256 digest.
var digestExpression = regexp.MustCompile(`^[0-9a-f]{64}$`)

// regularIdentity binds a path to the regular object and bytes inspected there.
type regularIdentity struct {
	// path is the canonical local file path.
	path string
	// info identifies the exact filesystem object.
	info os.FileInfo
	// record is the portable digest and length.
	record FileRecord
}

// countingHashWriter counts and hashes all bytes accepted by Write.
type countingHashWriter struct {
	// hash receives the complete stream.
	hash io.Writer
	// size counts complete accepted bytes.
	size int64
	// maximum rejects output beyond an exact or policy byte limit when positive.
	maximum int64
}

// Write hashes bytes and reports their complete length.
func (writer *countingHashWriter) Write(data []byte) (int, error) {
	if writer.maximum > 0 && int64(len(data)) > writer.maximum-writer.size {
		return 0, fmt.Errorf("stream exceeds its %d-byte limit", writer.maximum)
	}
	count, err := writer.hash.Write(data)
	writer.size += int64(count)
	return count, err
}

// safePortableName rejects paths, controls, ambiguous dots, and unsupported bytes.
func safePortableName(value string) bool {
	return portableNameExpression.MatchString(value) && value != "." && value != ".." &&
		filepath.Base(value) == value && !strings.ContainsAny(value, `/\`)
}

// safePortablePath accepts a bounded slash-separated journal artefact path.
func safePortablePath(value string) bool {
	if value == "" || len(value) > 1024 || strings.Contains(value, "\\") || strings.HasPrefix(value, "/") ||
		path.Clean(value) != value || value == "." || strings.HasPrefix(value, "../") {
		return false
	}
	for _, component := range strings.Split(value, "/") {
		if !safePortableName(component) {
			return false
		}
	}
	return true
}

// safeReleaseName reports whether value is a portable, non-ambiguous release name.
func safeReleaseName(value string) bool {
	return releaseNameExpression.MatchString(value) && !strings.Contains(value, "..")
}

// canonicalDirectory resolves one existing directory without symbolic links.
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

// containedBy reports equality or component-aware descent beneath parent.
func containedBy(parent, candidate string) bool {
	relative, err := filepath.Rel(parent, candidate)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// rejectSymbolicRoute proves an existing path stays beneath root without links.
func rejectSymbolicRoute(root, path string) error {
	if !containedBy(root, path) {
		return fmt.Errorf("path escapes repository root: %s", path)
	}
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return err
	}
	current := root
	if relative == "." {
		return nil
	}
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect path route: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("path route contains a symbolic link: %s", current)
		}
	}
	return nil
}

// ensureDirectory creates one contained directory tree without following links.
func ensureDirectory(root, path string, mode os.FileMode) error {
	if !containedBy(root, path) {
		return fmt.Errorf("directory escapes repository root: %s", path)
	}
	relative, err := filepath.Rel(root, path)
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
			return fmt.Errorf("create directory %s: %w", current, err)
		}
	}
	return nil
}

// inspectRegular hashes one stable, bounded, non-symbolic-link file.
func inspectRegular(ctx context.Context, path, label string, maximum int64) (regularIdentity, error) {
	if err := ctx.Err(); err != nil {
		return regularIdentity{}, err
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return regularIdentity{}, fmt.Errorf("resolve %s: %w", label, err)
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
	return regularIdentity{
		path: absolute, info: info,
		record: FileRecord{Name: filepath.Base(absolute), SHA256: hex.EncodeToString(hasher.Sum(nil)), Size: written},
	}, nil
}

// copyContext copies a bounded stream while honouring caller cancellation.
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
				return total, errors.New("input exceeds its size limit")
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
		return nil, errors.New("file identity changed while opening")
	}
	var output bytes.Buffer
	written, copyErr := copyContext(ctx, &output, file, maximum)
	closeErr := file.Close()
	current, currentErr := os.Lstat(identity.path)
	if err := errors.Join(copyErr, closeErr, currentErr); err != nil {
		return nil, err
	}
	digest := sha256.Sum256(output.Bytes())
	if written != identity.record.Size || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(identity.info, current) ||
		hex.EncodeToString(digest[:]) != identity.record.SHA256 {
		return nil, errors.New("file identity changed while reading")
	}
	return output.Bytes(), nil
}

// copyIdentity writes a previously inspected file exclusively and revalidates it.
func copyIdentity(ctx context.Context, identity regularIdentity, destination string, maximum int64) error {
	source, err := os.Open(identity.path)
	if err != nil {
		return err
	}
	opened, statErr := source.Stat()
	if statErr != nil || !opened.Mode().IsRegular() || !os.SameFile(identity.info, opened) {
		_ = source.Close()
		return errors.New("file identity changed before copying")
	}
	target, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		_ = source.Close()
		return err
	}
	hasher := sha256.New()
	written, copyErr := copyContext(ctx, io.MultiWriter(target, hasher), source, maximum)
	syncErr := target.Sync()
	closeTargetErr := target.Close()
	closeSourceErr := source.Close()
	current, currentErr := os.Lstat(identity.path)
	digest := hex.EncodeToString(hasher.Sum(nil))
	if err := errors.Join(copyErr, syncErr, closeTargetErr, closeSourceErr, currentErr); err != nil {
		return err
	}
	if written != identity.record.Size || digest != identity.record.SHA256 || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(identity.info, current) {
		return errors.New("file identity changed while copying")
	}
	return os.Chmod(destination, 0o644)
}

// decodeStrictJSON rejects unknown fields, trailing values, and overlong data.
func decodeStrictJSON(data []byte, destination any) error {
	if err := rejectDuplicateJSONNames(data); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values are not allowed")
		}
		return err
	}
	return nil
}

// rejectDuplicateJSONNames rejects ambiguous repeated object fields at every depth.
func rejectDuplicateJSONNames(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := walkJSONValue(decoder, "document", 0); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values are not allowed")
		}
		return err
	}
	return nil
}

// walkJSONValue consumes one JSON value while tracking names within each object.
func walkJSONValue(decoder *json.Decoder, location string, depth int) error {
	if depth > maximumJSONDepth {
		return fmt.Errorf("decode %s: JSON nesting exceeds %d levels", location, maximumJSONDepth)
	}
	token, err := decoder.Token()
	if err != nil {
		return fmt.Errorf("decode %s: %w", location, err)
	}
	delimiter, compound := token.(json.Delim)
	if !compound {
		return nil
	}
	switch delimiter {
	case '{':
		seen := make(map[string]struct{})
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return fmt.Errorf("decode %s: object key is not a string", location)
			}
			if _, exists := seen[key]; exists {
				return fmt.Errorf("decode %s: duplicate field %q", location, key)
			}
			seen[key] = struct{}{}
			if err := walkJSONValue(decoder, location+"."+key, depth+1); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim('}') {
			return errors.Join(errors.New("decode JSON object end"), err)
		}
		return nil
	case '[':
		index := 0
		for decoder.More() {
			if err := walkJSONValue(decoder, fmt.Sprintf("%s[%d]", location, index), depth+1); err != nil {
				return err
			}
			index++
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim(']') {
			return errors.Join(errors.New("decode JSON array end"), err)
		}
		return nil
	default:
		return fmt.Errorf("decode %s: unexpected delimiter %q", location, delimiter)
	}
}

// encodeJSON returns deterministic indented JSON with a final newline.
func encodeJSON(value any) ([]byte, error) {
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

// writeExclusive writes and syncs one new private file before applying its final mode.
func writeExclusive(path string, contents []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	written, writeErr := file.Write(contents)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		return err
	}
	if written != len(contents) {
		return io.ErrShortWrite
	}
	return os.Chmod(path, mode)
}

// requireExactDirectory rejects missing, extra, linked, or nested release entries.
func requireExactDirectory(directory string, expected map[string]struct{}) error {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	seen := make(map[string]struct{}, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if !safePortableName(name) {
			return fmt.Errorf("release directory contains an unsafe name: %q", name)
		}
		info, err := os.Lstat(filepath.Join(directory, name))
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("release entry is not a regular file: %s", name)
		}
		if _, ok := expected[name]; !ok {
			return fmt.Errorf("release directory contains an undeclared file: %s", name)
		}
		seen[name] = struct{}{}
	}
	if len(seen) != len(expected) {
		var missing []string
		for name := range expected {
			if _, ok := seen[name]; !ok {
				missing = append(missing, name)
			}
		}
		sort.Strings(missing)
		return fmt.Errorf("release directory is missing files: %s", strings.Join(missing, ", "))
	}
	return nil
}

// renderChecksums returns sorted GNU-compatible SHA-256 records.
func renderChecksums(records []FileRecord) []byte {
	ordered := append([]FileRecord(nil), records...)
	sort.Slice(ordered, func(left, right int) bool { return ordered[left].Name < ordered[right].Name })
	var output strings.Builder
	for _, record := range ordered {
		_, _ = fmt.Fprintf(&output, "%s  %s\n", record.SHA256, record.Name)
	}
	return []byte(output.String())
}

// parseChecksums reads exact already-bounded checksum bytes without path syntax.
func parseChecksums(contents []byte) (map[string]string, error) {
	result := make(map[string]string)
	scanner := bufio.NewScanner(bytes.NewReader(contents))
	buffer := make([]byte, 1024)
	scanner.Buffer(buffer, 4096)
	for scanner.Scan() {
		line := scanner.Text()
		if len(line) < 67 || line[64:66] != "  " {
			return nil, fmt.Errorf("invalid SHA256SUMS line: %q", line)
		}
		digest, name := line[:64], line[66:]
		if !digestExpression.MatchString(digest) || !safePortableName(name) {
			return nil, fmt.Errorf("invalid SHA256SUMS entry: %q", line)
		}
		if _, exists := result[name]; exists {
			return nil, fmt.Errorf("duplicate SHA256SUMS entry: %s", name)
		}
		result[name] = digest
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(result) == 0 {
		return nil, errors.New("SHA256SUMS is empty")
	}
	return result, nil
}
