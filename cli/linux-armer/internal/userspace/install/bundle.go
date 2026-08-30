package install

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
)

// bundleManifestName is the receipt emitted by the bounded release downloader.
const bundleManifestName = "linux-armer-userspace-bundle.json"

// maxBundleManifestBytes bounds receipt memory use before strict decoding.
const maxBundleManifestBytes = 1 << 20

// verifiedBundle contains only paths checked against compiled release policy.
type verifiedBundle struct {
	directory string
	paths     map[string]string
}

// verifyBundle rehashes the manifest, size, digest, and checksum coverage of
// every permitted release artefact before it crosses a privileged boundary.
func verifyBundle(directory string, spec releaseSpec) (verifiedBundle, error) {
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return verifiedBundle{}, fmt.Errorf("resolve userspace bundle directory: %w", err)
	}
	directory, err = filepath.EvalSymlinks(absolute)
	if err != nil {
		return verifiedBundle{}, fmt.Errorf("resolve userspace bundle directory: %w", err)
	}
	directory = filepath.Clean(directory)
	manifestPath, err := requireRegularBundleFile(directory, bundleManifestName)
	if err != nil {
		return verifiedBundle{}, err
	}
	manifestFile, manifestInfo, err := openRegularNoFollow(manifestPath)
	if err != nil {
		return verifiedBundle{}, fmt.Errorf("open userspace bundle manifest: %w", err)
	}
	if manifestInfo.Size() > maxBundleManifestBytes {
		_ = manifestFile.Close()
		return verifiedBundle{}, errors.New("userspace bundle manifest exceeds 1 MiB")
	}
	manifestData, readErr := io.ReadAll(io.LimitReader(manifestFile, maxBundleManifestBytes+1))
	closeErr := manifestFile.Close()
	if readErr != nil || closeErr != nil {
		return verifiedBundle{}, fmt.Errorf("read userspace bundle manifest: %w", errors.Join(readErr, closeErr))
	}
	if len(manifestData) > maxBundleManifestBytes {
		return verifiedBundle{}, errors.New("userspace bundle manifest exceeds 1 MiB")
	}
	if err := validateReceiptJSONShape(manifestData); err != nil {
		return verifiedBundle{}, fmt.Errorf("decode userspace bundle manifest: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(manifestData))
	decoder.DisallowUnknownFields()
	var manifest userspacerelease.Bundle
	decodeErr := decoder.Decode(&manifest)
	if decodeErr == nil {
		var extra any
		if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
			decodeErr = errors.New("userspace bundle manifest contains trailing JSON")
		}
	}
	if decodeErr != nil {
		return verifiedBundle{}, fmt.Errorf("decode userspace bundle manifest: %w", decodeErr)
	}
	if manifest.Component != spec.component {
		return verifiedBundle{}, fmt.Errorf("bundle component is %q, expected %q", manifest.Component, spec.component)
	}
	if manifest.Repository != userspaceRepository {
		return verifiedBundle{}, fmt.Errorf("bundle repository is %q, expected %q", manifest.Repository, userspaceRepository)
	}
	if manifest.Release != spec.tag {
		return verifiedBundle{}, fmt.Errorf("bundle release is %q, expected %q", manifest.Release, spec.tag)
	}
	portable, err := validateReceiptDirectory(directory, manifest.Directory)
	if err != nil {
		return verifiedBundle{}, err
	}

	expected := make(map[string]immutableFile, len(spec.files))
	for _, file := range spec.files {
		expected[file.name] = file
	}
	if len(manifest.Files) != len(expected) {
		return verifiedBundle{}, fmt.Errorf("bundle manifest contains %d files, expected %d", len(manifest.Files), len(expected))
	}
	paths := make(map[string]string, len(expected))
	for _, recorded := range manifest.Files {
		immutable, ok := expected[recorded.Name]
		if !ok {
			return verifiedBundle{}, fmt.Errorf("bundle manifest contains unexpected file %q", recorded.Name)
		}
		if _, duplicate := paths[recorded.Name]; duplicate {
			return verifiedBundle{}, fmt.Errorf("bundle manifest contains duplicate file %q", recorded.Name)
		}
		if !recorded.Verified {
			return verifiedBundle{}, fmt.Errorf("bundle manifest marks %s as unverified", recorded.Name)
		}
		if recorded.SHA256 != immutable.sha256 || recorded.Size != immutable.size {
			return verifiedBundle{}, fmt.Errorf("bundle metadata disagrees with immutable release metadata for %s", recorded.Name)
		}
		path, err := requireRegularBundleFile(directory, recorded.Name)
		if err != nil {
			return verifiedBundle{}, err
		}
		if err := validateReceiptFilePath(directory, path, recorded, portable); err != nil {
			return verifiedBundle{}, err
		}
		digest, info, err := hashRegularNoFollow(path)
		if err != nil {
			return verifiedBundle{}, fmt.Errorf("hash userspace artifact %s: %w", recorded.Name, err)
		}
		if info.Size() != immutable.size {
			return verifiedBundle{}, fmt.Errorf("size mismatch for %s: expected %d, got %d", recorded.Name, immutable.size, info.Size())
		}
		if digest != immutable.sha256 {
			return verifiedBundle{}, fmt.Errorf("SHA-256 mismatch for %s: expected %s, got %s", recorded.Name, immutable.sha256, digest)
		}
		paths[recorded.Name] = path
	}
	if err := verifyChecksums(paths["SHA256SUMS"], spec); err != nil {
		return verifiedBundle{}, err
	}
	return verifiedBundle{directory: directory, paths: paths}, nil
}

// validateReceiptJSONShape rejects duplicate, mis-cased, and unknown receipt
// keys before Go's case-insensitive typed JSON decoder sees the document.
func validateReceiptJSONShape(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return errors.New("userspace bundle manifest must be a JSON object")
	}
	allowed := map[string]bool{
		"component":  false,
		"repository": false,
		"release":    false,
		"directory":  false,
		"files":      false,
	}
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return err
		}
		key, ok := keyToken.(string)
		if !ok {
			return errors.New("userspace bundle manifest contains a non-string object key")
		}
		seen, known := allowed[key]
		if !known {
			return fmt.Errorf("unknown field %q", key)
		}
		if seen {
			return fmt.Errorf("duplicate field %q", key)
		}
		allowed[key] = true
		if key == "files" {
			if err := validateReceiptFilesJSON(decoder); err != nil {
				return err
			}
			continue
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return err
		}
	}
	if _, err := decoder.Token(); err != nil {
		return err
	}
	if token, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err != nil {
			return err
		}
		return fmt.Errorf("userspace bundle manifest contains trailing JSON value %v", token)
	}
	return nil
}

// validateReceiptFilesJSON applies exact and duplicate-key checks to every
// file record while leaving value type checks to the typed decoder.
func validateReceiptFilesJSON(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '[' {
		return errors.New("userspace bundle manifest files must be a JSON array")
	}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
			return errors.New("userspace bundle manifest file must be a JSON object")
		}
		allowed := map[string]bool{
			"name":     false,
			"path":     false,
			"sha256":   false,
			"size":     false,
			"verified": false,
		}
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return errors.New("userspace bundle manifest file contains a non-string object key")
			}
			seen, known := allowed[key]
			if !known {
				return fmt.Errorf("unknown file field %q", key)
			}
			if seen {
				return fmt.Errorf("duplicate file field %q", key)
			}
			allowed[key] = true
			var value json.RawMessage
			if err := decoder.Decode(&value); err != nil {
				return err
			}
		}
		if _, err := decoder.Token(); err != nil {
			return err
		}
	}
	_, err = decoder.Token()
	return err
}

// validateReceiptDirectory identifies the portable receipt form and otherwise
// accepts only a canonical legacy absolute directory matching the selected bundle.
func validateReceiptDirectory(directory, recorded string) (bool, error) {
	if recorded == "." {
		return true, nil
	}
	if !filepath.IsAbs(recorded) || filepath.Clean(recorded) != recorded {
		return false, errors.New("bundle manifest directory must be '.' or a canonical legacy absolute path")
	}
	resolved, err := filepath.EvalSymlinks(recorded)
	if err != nil || filepath.Clean(resolved) != directory {
		return false, errors.New("bundle manifest directory does not identify the selected bundle")
	}
	return false, nil
}

// validateReceiptFilePath requires a portable flat filename or, for a legacy
// receipt, a canonical absolute path to the same regular file in the bundle.
func validateReceiptFilePath(directory, actual string, recorded userspacerelease.File, portable bool) error {
	if portable {
		if recorded.Path != recorded.Name {
			return fmt.Errorf("portable bundle manifest path for %s must be its flat filename", recorded.Name)
		}
		return nil
	}
	if !filepath.IsAbs(recorded.Path) || filepath.Clean(recorded.Path) != recorded.Path {
		return fmt.Errorf("legacy bundle manifest path for %s must be canonical and absolute", recorded.Name)
	}
	resolved, err := filepath.EvalSymlinks(recorded.Path)
	if err != nil || filepath.Clean(resolved) != actual || !withinRoot(directory, resolved) {
		return fmt.Errorf("bundle manifest path does not identify %s in the selected bundle", recorded.Name)
	}
	return nil
}

// requireRegularBundleFile rejects flat-name violations, links, and special
// files in a downloaded bundle.
func requireRegularBundleFile(directory, name string) (string, error) {
	if name == "" || name == "." || name == ".." || filepath.Base(name) != name || strings.ContainsAny(name, `/\\`) {
		return "", fmt.Errorf("unsafe userspace bundle filename %q", name)
	}
	path := filepath.Join(directory, name)
	info, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("inspect userspace artifact %s: %w", name, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", fmt.Errorf("userspace artifact must be a regular, non-symlink file: %s", path)
	}
	return filepath.Clean(path), nil
}

// verifyChecksums requires SHA256SUMS to cover exactly the compiled file set.
func verifyChecksums(path string, spec releaseSpec) error {
	file, _, err := openRegularNoFollow(path)
	if err != nil {
		return fmt.Errorf("open SHA256SUMS: %w", err)
	}
	defer file.Close()
	want := make(map[string]string, len(spec.files)-1)
	for _, immutable := range spec.files {
		if immutable.name != "SHA256SUMS" {
			want[immutable.name] = immutable.sha256
		}
	}
	seen := make(map[string]bool, len(want))
	scanner := bufio.NewScanner(io.LimitReader(file, 1<<20))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) != 2 || len(fields[0]) != 64 {
			return fmt.Errorf("malformed SHA256SUMS line %q", scanner.Text())
		}
		if _, err := hex.DecodeString(fields[0]); err != nil {
			return fmt.Errorf("malformed SHA256SUMS digest %q", fields[0])
		}
		name := strings.TrimPrefix(fields[1], "*")
		expected, ok := want[name]
		if !ok || seen[name] {
			return fmt.Errorf("SHA256SUMS contains unexpected or duplicate file %q", name)
		}
		if strings.ToLower(fields[0]) != expected {
			return fmt.Errorf("SHA256SUMS digest disagrees with immutable release metadata for %s", name)
		}
		seen[name] = true
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("read SHA256SUMS: %w", err)
	}
	if len(seen) != len(want) {
		missing := make([]string, 0)
		for name := range want {
			if !seen[name] {
				missing = append(missing, name)
			}
		}
		return fmt.Errorf("SHA256SUMS does not cover every immutable release file: %s", strings.Join(missing, ", "))
	}
	return nil
}
