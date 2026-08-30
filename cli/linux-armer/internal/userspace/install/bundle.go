package install

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
)

// bundleManifestName is the receipt emitted by the bounded release downloader.
const bundleManifestName = "linux-armer-userspace-bundle.json"

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
	manifestInfo, err := os.Stat(manifestPath)
	if err != nil {
		return verifiedBundle{}, err
	}
	if manifestInfo.Size() > 1<<20 {
		return verifiedBundle{}, errors.New("userspace bundle manifest exceeds 1 MiB")
	}
	manifestFile, err := os.Open(manifestPath)
	if err != nil {
		return verifiedBundle{}, fmt.Errorf("open userspace bundle manifest: %w", err)
	}
	decoder := json.NewDecoder(io.LimitReader(manifestFile, 1<<20))
	decoder.DisallowUnknownFields()
	var manifest userspacerelease.Bundle
	decodeErr := decoder.Decode(&manifest)
	if decodeErr == nil {
		var extra any
		if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
			decodeErr = errors.New("userspace bundle manifest contains trailing JSON")
		}
	}
	closeErr := manifestFile.Close()
	if decodeErr != nil || closeErr != nil {
		return verifiedBundle{}, fmt.Errorf("decode userspace bundle manifest: %w", errors.Join(decodeErr, closeErr))
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
	manifestDirectory, err := filepath.EvalSymlinks(manifest.Directory)
	if err != nil || filepath.Clean(manifestDirectory) != directory {
		return verifiedBundle{}, errors.New("bundle manifest directory does not identify the selected bundle")
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
		recordedPath, err := filepath.EvalSymlinks(recorded.Path)
		if err != nil || filepath.Clean(recordedPath) != path || filepath.Clean(recorded.Path) != recorded.Path {
			return verifiedBundle{}, fmt.Errorf("bundle manifest path does not identify %s in the selected bundle", recorded.Name)
		}
		info, err := os.Stat(path)
		if err != nil {
			return verifiedBundle{}, fmt.Errorf("inspect userspace artifact %s: %w", recorded.Name, err)
		}
		if info.Size() != immutable.size {
			return verifiedBundle{}, fmt.Errorf("size mismatch for %s: expected %d, got %d", recorded.Name, immutable.size, info.Size())
		}
		digest, err := artifact.HashFile(path)
		if err != nil {
			return verifiedBundle{}, err
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
	file, err := os.Open(path)
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
