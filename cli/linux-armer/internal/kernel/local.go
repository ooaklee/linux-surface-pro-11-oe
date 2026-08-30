package kernel

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	localChecksumManifest = "SHA256SUMS"
	localReleasePrefix    = "local:"
	surfaceABISuffix      = "-qcom-x1e"
)

type localCandidate struct {
	name    string
	path    string
	role    PackageRole
	abi     string
	version string
}

// DiscoverLocalBundle finds one version-bound Surface Pro 11 linux-image and
// linux-modules package pair in directory. If SHA256SUMS is present, both
// packages must be covered by it and match their declared digests. Without a
// manifest the packages are still hashed, but are marked as unverified.
func DiscoverLocalBundle(directory string) (Bundle, error) {
	if strings.TrimSpace(directory) == "" {
		return Bundle{}, errors.New("discover local kernel bundle: directory is required")
	}

	absoluteDirectory, err := filepath.Abs(directory)
	if err != nil {
		return Bundle{}, fmt.Errorf("discover local kernel bundle: resolve directory: %w", err)
	}
	info, err := os.Stat(absoluteDirectory)
	if err != nil {
		return Bundle{}, fmt.Errorf("discover local kernel bundle: inspect directory %q: %w", absoluteDirectory, err)
	}
	if !info.IsDir() {
		return Bundle{}, fmt.Errorf("discover local kernel bundle: %q is not a directory", absoluteDirectory)
	}

	entries, err := os.ReadDir(absoluteDirectory)
	if err != nil {
		return Bundle{}, fmt.Errorf("discover local kernel bundle: read directory %q: %w", absoluteDirectory, err)
	}
	candidates := map[PackageRole][]localCandidate{
		RoleImage:   nil,
		RoleModules: nil,
	}
	for _, entry := range entries {
		candidate, applicable, candidateErr := inspectLocalCandidate(absoluteDirectory, entry)
		if candidateErr != nil {
			return Bundle{}, fmt.Errorf("discover local kernel bundle: %w", candidateErr)
		}
		if applicable {
			candidates[candidate.role] = append(candidates[candidate.role], candidate)
		}
	}

	image, err := selectLocalCandidate(RoleImage, candidates[RoleImage])
	if err != nil {
		return Bundle{}, fmt.Errorf("discover local kernel bundle: %w", err)
	}
	modules, err := selectLocalCandidate(RoleModules, candidates[RoleModules])
	if err != nil {
		return Bundle{}, fmt.Errorf("discover local kernel bundle: %w", err)
	}
	if image.abi != modules.abi {
		return Bundle{}, fmt.Errorf(
			"discover local kernel bundle: image and modules ABI mismatch: %s has %q, %s has %q",
			image.name,
			image.abi,
			modules.name,
			modules.abi,
		)
	}
	if image.version != modules.version {
		return Bundle{}, fmt.Errorf(
			"discover local kernel bundle: image and modules package version mismatch: %s has %q, %s has %q",
			image.name,
			image.version,
			modules.name,
			modules.version,
		)
	}

	checksums, manifestPresent, err := loadLocalChecksums(absoluteDirectory)
	if err != nil {
		return Bundle{}, fmt.Errorf("discover local kernel bundle: %w", err)
	}

	selected := []localCandidate{image, modules}
	packages := make([]Package, 0, len(selected))
	for _, candidate := range selected {
		digest, size, hashErr := hashLocalPackage(candidate.path)
		if hashErr != nil {
			return Bundle{}, fmt.Errorf("discover local kernel bundle: %w", hashErr)
		}
		if manifestPresent {
			expected, covered := checksums[candidate.name]
			if !covered {
				return Bundle{}, fmt.Errorf("discover local kernel bundle: %s does not cover %s", localChecksumManifest, candidate.name)
			}
			if !strings.EqualFold(expected, digest) {
				return Bundle{}, fmt.Errorf(
					"discover local kernel bundle: SHA-256 mismatch for %s: expected %s, got %s",
					candidate.name,
					expected,
					digest,
				)
			}
		}
		packages = append(packages, Package{
			Role:     candidate.role,
			Name:     candidate.name,
			Path:     candidate.path,
			SHA256:   digest,
			Size:     size,
			Verified: manifestPresent,
		})
	}

	bundle, err := NewBundle(localReleasePrefix+image.abi, "", packages)
	if err != nil {
		return Bundle{}, fmt.Errorf("discover local kernel bundle: validate package pair: %w", err)
	}
	if bundle.ABI != image.abi {
		return Bundle{}, fmt.Errorf("discover local kernel bundle: derived ABI %q changed to %q during validation", image.abi, bundle.ABI)
	}

	return bundle, nil
}

func inspectLocalCandidate(directory string, entry os.DirEntry) (localCandidate, bool, error) {
	name := entry.Name()
	if name == localChecksumManifest || !strings.HasSuffix(name, ".deb") {
		return localCandidate{}, false, nil
	}

	role, abi, version, err := ParsePackageName(name)
	if err != nil || (role != RoleImage && role != RoleModules) || !isSurfaceABI(abi) {
		return localCandidate{}, false, nil
	}
	if entry.Type()&os.ModeSymlink != 0 {
		return localCandidate{}, false, fmt.Errorf("kernel package %s must be a regular file, not a symbolic link", name)
	}
	info, err := entry.Info()
	if err != nil {
		return localCandidate{}, false, fmt.Errorf("inspect kernel package %s: %w", name, err)
	}
	if !info.Mode().IsRegular() {
		return localCandidate{}, false, fmt.Errorf("kernel package %s is not a regular file", name)
	}

	return localCandidate{
		name:    name,
		path:    filepath.Join(directory, name),
		role:    role,
		abi:     abi,
		version: version,
	}, true, nil
}

func isSurfaceABI(abi string) bool {
	prefix := strings.TrimSuffix(abi, surfaceABISuffix)
	return prefix != abi && prefix != ""
}

func selectLocalCandidate(role PackageRole, candidates []localCandidate) (localCandidate, error) {
	label := string(role)
	if len(candidates) == 0 {
		return localCandidate{}, fmt.Errorf("expected exactly one Surface Pro 11 linux-%s package, found none", label)
	}
	if len(candidates) == 1 {
		return candidates[0], nil
	}

	names := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		names = append(names, candidate.name)
	}
	sort.Strings(names)
	return localCandidate{}, fmt.Errorf("ambiguous Surface Pro 11 linux-%s packages: %s", label, strings.Join(names, ", "))
}

func loadLocalChecksums(directory string) (map[string]string, bool, error) {
	manifestPath := filepath.Join(directory, localChecksumManifest)
	info, err := os.Lstat(manifestPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("inspect %s: %w", localChecksumManifest, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return nil, false, fmt.Errorf("%s must be a regular file, not a symbolic link", localChecksumManifest)
	}
	if !info.Mode().IsRegular() {
		return nil, false, fmt.Errorf("%s is not a regular file", localChecksumManifest)
	}

	checksums, err := parseLocalChecksums(manifestPath)
	if err != nil {
		return nil, false, err
	}
	return checksums, true, nil
}

func parseLocalChecksums(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", localChecksumManifest, err)
	}
	defer file.Close()

	checksums := make(map[string]string)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := scanner.Text()
		fields := strings.Fields(line)
		if len(fields) != 2 {
			return nil, fmt.Errorf("%s:%d: expected '<sha256>  <filename>'", localChecksumManifest, lineNumber)
		}

		digest := strings.ToLower(fields[0])
		if len(digest) != sha256.Size*2 {
			return nil, fmt.Errorf("%s:%d: SHA-256 must contain 64 hexadecimal characters", localChecksumManifest, lineNumber)
		}
		if _, err := hex.DecodeString(digest); err != nil {
			return nil, fmt.Errorf("%s:%d: invalid SHA-256: %w", localChecksumManifest, lineNumber, err)
		}

		name := strings.TrimPrefix(fields[1], "*")
		if !safeLocalChecksumName(name) {
			return nil, fmt.Errorf("%s:%d: unsafe filename %q", localChecksumManifest, lineNumber, name)
		}
		if _, duplicate := checksums[name]; duplicate {
			return nil, fmt.Errorf("%s:%d: duplicate entry for %q", localChecksumManifest, lineNumber, name)
		}
		checksums[name] = digest
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read %s: %w", localChecksumManifest, err)
	}
	if len(checksums) == 0 {
		return nil, fmt.Errorf("%s is empty", localChecksumManifest)
	}

	return checksums, nil
}

func safeLocalChecksumName(name string) bool {
	return name != "" &&
		name != "." &&
		name != ".." &&
		filepath.Base(name) == name &&
		!strings.ContainsAny(name, `/\`)
}

func hashLocalPackage(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, fmt.Errorf("open kernel package %s: %w", filepath.Base(path), err)
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return "", 0, fmt.Errorf("inspect kernel package %s: %w", filepath.Base(path), err)
	}
	if !info.Mode().IsRegular() {
		return "", 0, fmt.Errorf("kernel package %s is not a regular file", filepath.Base(path))
	}

	hasher := sha256.New()
	if _, err := io.Copy(hasher, file); err != nil {
		return "", 0, fmt.Errorf("hash kernel package %s: %w", filepath.Base(path), err)
	}

	return hex.EncodeToString(hasher.Sum(nil)), info.Size(), nil
}
