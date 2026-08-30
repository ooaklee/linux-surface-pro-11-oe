package build

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

const (
	// maximumProvenanceBytes bounds every container-produced identity field.
	maximumProvenanceBytes int64 = 4096
	// maximumPackageBytes bounds each generated Debian package at four GiB.
	maximumPackageBytes int64 = 4 << 30
	// maximumGeneratedPackages bounds the exact runtime and header set.
	maximumGeneratedPackages = 4
	// maximumPackageNameBytes preserves portable package and manifest names.
	maximumPackageNameBytes = 255
	// checksumManifestName is the downstream local bundle trust manifest.
	checksumManifestName = "SHA256SUMS"
	// provenanceManifestName stores source and recipe identity beside packages.
	provenanceManifestName = "linux-armer-kernel-build-provenance.json"
	// bundleManifestName stores the normal validated kernel bundle contract.
	bundleManifestName = "linux-armer-kernel-bundle.json"
)

// gitObjectExpression accepts SHA-1 or SHA-256 Git object identifiers.
var gitObjectExpression = regexp.MustCompile(`^(?:[0-9a-f]{40}|[0-9a-f]{64})$`)

// packageFileNameExpression accepts only portable Debian package filename bytes.
var packageFileNameExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.+_~%-]*\.deb$`)

// readProvenance validates the fixed container-produced source identity files.
func readProvenance(transaction string, plan Plan) (Provenance, error) {
	directory := filepath.Join(transaction, "provenance")
	fields := map[string]*string{}
	var gitURL, gitRef, refKind, revision, tree, commitTime, recipe, toolchain string
	fields["git-url"] = &gitURL
	fields["git-ref"] = &gitRef
	fields["ref-kind"] = &refKind
	fields["revision"] = &revision
	fields["tree"] = &tree
	fields["commit-time"] = &commitTime
	fields["recipe-sha256"] = &recipe
	fields["toolchain-sha256"] = &toolchain
	for name, destination := range fields {
		value, err := readIdentityFile(filepath.Join(directory, name))
		if err != nil {
			return Provenance{}, fmt.Errorf("read kernel build provenance %s: %w", name, err)
		}
		*destination = value
	}
	if gitURL != plan.GitURL || gitRef != plan.GitRef {
		return Provenance{}, errors.New("container source remote or ref differs from the reviewed plan")
	}
	if refKind != "branch" && refKind != "tag" {
		return Provenance{}, fmt.Errorf("container returned unsupported Git ref kind %q", refKind)
	}
	if !gitObjectExpression.MatchString(revision) || !gitObjectExpression.MatchString(tree) {
		return Provenance{}, errors.New("container returned malformed Git revision or tree identity")
	}
	if recipe != plan.RecipeSHA256 {
		return Provenance{}, errors.New("container recipe identity differs from the reviewed plan")
	}
	if !gitObjectExpression.MatchString(toolchain) {
		return Provenance{}, errors.New("container returned malformed toolchain identity")
	}
	committed, err := time.Parse(time.RFC3339, commitTime)
	if err != nil {
		return Provenance{}, fmt.Errorf("parse kernel source commit time: %w", err)
	}
	return Provenance{
		GitURL: gitURL, GitRef: gitRef, RefKind: refKind, Revision: revision, Tree: tree,
		CommitTime: committed.UTC(), RecipeSHA256: recipe,
		ContainerImage: plan.ContainerImage, WorkVolume: plan.WorkVolume, ToolchainSHA256: toolchain,
	}, nil
}

// readIdentityFile reads one non-empty, bounded, regular provenance field.
func readIdentityFile(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximumProvenanceBytes {
		return "", fmt.Errorf("identity is not a bounded non-empty regular file: %s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	data, readErr := io.ReadAll(io.LimitReader(file, maximumProvenanceBytes+1))
	closeErr := file.Close()
	if err := errors.Join(readErr, closeErr); err != nil {
		return "", err
	}
	current, err := os.Lstat(path)
	if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(info, current) || current.Size() != info.Size() || int64(len(data)) != info.Size() {
		return "", fmt.Errorf("identity changed while it was read: %s", path)
	}
	value := string(data)
	if strings.TrimSpace(value) != value || strings.ContainsAny(value, "\r\n\x00") {
		return "", fmt.Errorf("identity contains whitespace or control delimiters: %s", path)
	}
	return value, nil
}

// inspectArtifacts validates the exact coherent Surface package set emitted by Docker.
func inspectArtifacts(ctx context.Context, transaction string, plan Plan, provenance Provenance) (kernel.Bundle, []Artifact, error) {
	directory := filepath.Join(transaction, "artifacts")
	info, err := os.Lstat(directory)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return kernel.Bundle{}, nil, fmt.Errorf("container artefact path is not a non-symbolic-link directory: %s", directory)
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return kernel.Bundle{}, nil, fmt.Errorf("read generated kernel packages: %w", err)
	}
	if len(entries) == 0 || len(entries) > maximumGeneratedPackages {
		return kernel.Bundle{}, nil, fmt.Errorf("container generated %d supported packages; expected between 2 and %d", len(entries), maximumGeneratedPackages)
	}
	packages := make([]kernel.Package, 0, len(entries))
	artifacts := make([]Artifact, 0, len(entries))
	roles := make(map[kernel.PackageRole]bool, len(entries))
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return kernel.Bundle{}, nil, err
		}
		if entry.Type()&os.ModeSymlink != 0 || entry.IsDir() {
			return kernel.Bundle{}, nil, fmt.Errorf("generated package entry is not a regular file: %s", entry.Name())
		}
		if len(entry.Name()) > maximumPackageNameBytes || !packageFileNameExpression.MatchString(entry.Name()) {
			return kernel.Bundle{}, nil, fmt.Errorf("generated package name contains unsupported bytes: %q", entry.Name())
		}
		role, _, _, err := kernel.ParsePackageName(entry.Name())
		if err != nil {
			return kernel.Bundle{}, nil, fmt.Errorf("reject unexpected generated artefact: %w", err)
		}
		if roles[role] {
			return kernel.Bundle{}, nil, fmt.Errorf("container generated duplicate %s package", role)
		}
		roles[role] = true
		path := filepath.Join(directory, entry.Name())
		digest, size, err := hashRegularPackage(ctx, path)
		if err != nil {
			return kernel.Bundle{}, nil, err
		}
		packages = append(packages, kernel.Package{
			Role: role, Name: entry.Name(), Path: path, SHA256: digest, Size: size,
		})
		artifacts = append(artifacts, Artifact{Role: role, Name: entry.Name(), Path: path, SHA256: digest, Size: size})
	}
	if roles[kernel.RoleHeaders] != roles[kernel.RoleCommonHeaders] {
		return kernel.Bundle{}, nil, errors.New("generated ABI headers and common headers must be present together")
	}
	bundle, err := kernel.NewBundle("build:"+provenance.Revision, plan.GitURL, packages)
	if err != nil {
		return kernel.Bundle{}, nil, fmt.Errorf("validate generated kernel bundle: %w", err)
	}
	sort.Slice(artifacts, func(left, right int) bool { return artifacts[left].Name < artifacts[right].Name })
	return bundle, artifacts, nil
}

// hashRegularPackage returns the stable identity of one unchanged generated package.
func hashRegularPackage(ctx context.Context, path string) (string, int64, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", 0, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximumPackageBytes {
		return "", 0, fmt.Errorf("generated package is not a bounded non-empty regular file: %s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	hasher := sha256.New()
	written, copyErr := copyWithContext(ctx, hasher, file, maximumPackageBytes)
	closeErr := file.Close()
	current, statErr := os.Lstat(path)
	if err := errors.Join(copyErr, closeErr, statErr); err != nil {
		return "", 0, fmt.Errorf("hash generated package %s: %w", filepath.Base(path), err)
	}
	if current.Mode()&os.ModeSymlink != 0 || !os.SameFile(info, current) || written != info.Size() {
		return "", 0, fmt.Errorf("generated package changed while it was hashed: %s", path)
	}
	return hex.EncodeToString(hasher.Sum(nil)), written, nil
}

// copyWithContext copies a bounded stream while honouring caller cancellation.
func copyWithContext(ctx context.Context, destination io.Writer, source io.Reader, maximum int64) (int64, error) {
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
				return total, errors.New("generated package exceeds its size limit")
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

// publishArtifacts atomically installs a new output directory on its filesystem.
func publishArtifacts(ctx context.Context, plan Plan, provenance Provenance, bundle kernel.Bundle, artifacts []Artifact) ([]Artifact, bool, error) {
	if err := requireNewOutput(plan.OutputDirectory); err != nil {
		return nil, false, fmt.Errorf("output changed during kernel build: %w", err)
	}
	parent := filepath.Dir(plan.OutputDirectory)
	if err := validateRoute(plan.RepositoryRoot, parent); err != nil {
		return nil, false, fmt.Errorf("revalidate kernel output parent: %w", err)
	}
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return nil, false, fmt.Errorf("create kernel output parent: %w", err)
	}
	resolvedParent, err := filepath.EvalSymlinks(parent)
	if err != nil || filepath.Clean(resolvedParent) != filepath.Clean(parent) {
		return nil, false, fmt.Errorf("kernel output parent became symbolic or unavailable: %s", parent)
	}
	staging, err := os.MkdirTemp(parent, ".linux-armer-kernel-output-")
	if err != nil {
		return nil, false, fmt.Errorf("create private kernel output staging directory: %w", err)
	}
	removeStaging := true
	defer func() {
		if removeStaging {
			_ = os.RemoveAll(staging)
		}
	}()
	if err := os.Chmod(staging, 0o755); err != nil {
		return nil, false, err
	}
	published := make([]Artifact, 0, len(artifacts))
	packageByName := make(map[string]kernel.Package, len(bundle.Packages))
	for _, item := range bundle.Packages {
		packageByName[item.Name] = item
	}
	for _, artifact := range artifacts {
		if err := ctx.Err(); err != nil {
			return nil, false, err
		}
		destination := filepath.Join(staging, artifact.Name)
		digest, size, err := copyVerifiedPackage(ctx, artifact.Path, destination, artifact)
		if err != nil {
			return nil, false, err
		}
		finalPath := filepath.Join(plan.OutputDirectory, artifact.Name)
		published = append(published, Artifact{
			Role: artifact.Role, Name: artifact.Name, Path: finalPath, SHA256: digest, Size: size,
		})
		item := packageByName[artifact.Name]
		item.Path = finalPath
		item.SHA256 = digest
		item.Size = size
		item.Verified = true
		packageByName[artifact.Name] = item
	}
	finalPackages := make([]kernel.Package, 0, len(bundle.Packages))
	for _, item := range bundle.Packages {
		finalPackages = append(finalPackages, packageByName[item.Name])
	}
	finalBundle, err := kernel.NewBundle(bundle.Release, bundle.Repository, finalPackages)
	if err != nil {
		return nil, false, err
	}
	if err := writeChecksumManifest(filepath.Join(staging, checksumManifestName), published); err != nil {
		return nil, false, err
	}
	if err := writeJSONFile(filepath.Join(staging, provenanceManifestName), provenance); err != nil {
		return nil, false, err
	}
	if err := writeBundleFile(filepath.Join(staging, bundleManifestName), finalBundle); err != nil {
		return nil, false, err
	}
	if err := syncDirectory(staging); err != nil {
		return nil, false, fmt.Errorf("sync staged kernel output: %w", err)
	}
	if err := requireNewOutput(plan.OutputDirectory); err != nil {
		return nil, false, fmt.Errorf("output changed before kernel publication: %w", err)
	}
	resolvedParent, err = filepath.EvalSymlinks(parent)
	if err != nil || filepath.Clean(resolvedParent) != filepath.Clean(parent) {
		return nil, false, fmt.Errorf("kernel output parent changed before publication: %s", parent)
	}
	if err := os.Rename(staging, plan.OutputDirectory); err != nil {
		return nil, false, fmt.Errorf("publish kernel output directory: %w", err)
	}
	removeStaging = false
	if err := syncDirectory(parent); err != nil {
		return published, true, fmt.Errorf("sync kernel output parent: %w", err)
	}
	return published, true, nil
}

// copyVerifiedPackage copies one pre-inspected package and proves its identity again.
func copyVerifiedPackage(ctx context.Context, sourcePath, destinationPath string, expected Artifact) (string, int64, error) {
	sourceInfo, err := os.Lstat(sourcePath)
	if err != nil || sourceInfo.Mode()&os.ModeSymlink != 0 || !sourceInfo.Mode().IsRegular() {
		return "", 0, fmt.Errorf("reinspect generated package before publication: %s", sourcePath)
	}
	source, err := os.Open(sourcePath)
	if err != nil {
		return "", 0, err
	}
	destination, err := os.OpenFile(destinationPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		_ = source.Close()
		return "", 0, err
	}
	hasher := sha256.New()
	written, copyErr := copyWithContext(ctx, io.MultiWriter(destination, hasher), source, maximumPackageBytes)
	syncErr := destination.Sync()
	destinationCloseErr := destination.Close()
	sourceCloseErr := source.Close()
	current, statErr := os.Lstat(sourcePath)
	if err := errors.Join(copyErr, syncErr, destinationCloseErr, sourceCloseErr, statErr); err != nil {
		return "", 0, fmt.Errorf("copy generated package %s: %w", expected.Name, err)
	}
	digest := hex.EncodeToString(hasher.Sum(nil))
	if current.Mode()&os.ModeSymlink != 0 || !os.SameFile(sourceInfo, current) || written != expected.Size || digest != expected.SHA256 {
		return "", 0, fmt.Errorf("generated package %s changed before publication", expected.Name)
	}
	return digest, written, nil
}

// writeChecksumManifest writes deterministic SHA-256 coverage for every package.
func writeChecksumManifest(path string, artifacts []Artifact) error {
	var builder strings.Builder
	for _, artifact := range artifacts {
		_, _ = fmt.Fprintf(&builder, "%s  %s\n", artifact.SHA256, artifact.Name)
	}
	return writeSyncedFile(path, []byte(builder.String()), 0o644)
}

// writeJSONFile writes one stable indented JSON document exactly once.
func writeJSONFile(path string, value any) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	writeErr := encoder.Encode(value)
	syncErr := file.Sync()
	closeErr := file.Close()
	return errors.Join(writeErr, syncErr, closeErr)
}

// writeBundleFile writes the normal kernel bundle manifest exactly once.
func writeBundleFile(path string, bundle kernel.Bundle) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	writeErr := bundle.WriteJSON(file)
	syncErr := file.Sync()
	closeErr := file.Close()
	return errors.Join(writeErr, syncErr, closeErr)
}

// writeSyncedFile writes and flushes one new ordinary file.
func writeSyncedFile(path string, content []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(content)
	syncErr := file.Sync()
	closeErr := file.Close()
	return errors.Join(writeErr, syncErr, closeErr)
}

// syncDirectory flushes directory entry changes before success is reported.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	return errors.Join(syncErr, closeErr)
}
