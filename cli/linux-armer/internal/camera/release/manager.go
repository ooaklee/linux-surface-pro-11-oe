package release

import (
	"bytes"
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
	"unicode"
	"unicode/utf8"

	camerabuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/build"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// maximumReleaseFileBytes bounds every copied or inspected release member.
const maximumReleaseFileBytes = int64(256 << 20)

// releaseNameExpression accepts portable release and paired-kernel tags.
var releaseNameExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// kernelABIExpression accepts one explicit qcom-x1e installed ABI.
var kernelABIExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.+_-]{0,191}-qcom-x1e$`)

// sha256Expression accepts one canonical independent authority digest.
var sha256Expression = regexp.MustCompile(`^[0-9a-f]{64}$`)

// newManager supplies production static inspection and timestamps.
func newManager(runner platform.Runner) *Manager {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Manager{Runner: runner, now: time.Now, validate: camerabuild.ValidateBundleStatic}
}

// managerTime returns a stable UTC timestamp or the current time as fallback.
func managerTime(manager *Manager) time.Time {
	if manager != nil && manager.now != nil {
		return manager.now().UTC()
	}
	return time.Now().UTC()
}

// prepare validates safe names and canonical local directory boundaries.
func (manager *Manager) prepare(ctx context.Context, request Request) (Plan, error) {
	if manager == nil || manager.Runner == nil {
		return Plan{}, errors.New("camera release runner is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return Plan{}, err
	}
	root, err := canonicalDirectory(request.RepositoryRoot)
	if err != nil {
		return Plan{}, fmt.Errorf("resolve camera release repository root: %w", err)
	}
	artifacts, err := canonicalDirectory(request.ArtifactsDirectory)
	if err != nil {
		return Plan{}, fmt.Errorf("resolve camera build artefacts: %w", err)
	}
	if !containedBy(root, artifacts) {
		return Plan{}, errors.New("camera build artefacts must remain beneath the repository root")
	}
	output, err := relativeTarget(root, request.OutputDirectory, DefaultOutputDirectory)
	if err != nil {
		return Plan{}, err
	}
	if !releaseNameExpression.MatchString(request.Tag) || unsafeText(request.Tag) {
		return Plan{}, errors.New("camera release tag is required and must be a portable safe name")
	}
	if !releaseNameExpression.MatchString(request.KernelTag) || unsafeText(request.KernelTag) {
		return Plan{}, errors.New("an explicit portable paired kernel tag is required")
	}
	if !kernelABIExpression.MatchString(request.KernelABI) || unsafeText(request.KernelABI) {
		return Plan{}, errors.New("an explicit paired qcom-x1e kernel ABI is required")
	}
	if !sha256Expression.MatchString(request.ExpectedBuildAuthoritySHA256) {
		return Plan{}, errors.New("an expected camera build authority SHA-256 is required")
	}
	kernelVersion := strings.TrimSuffix(request.KernelABI, "-qcom-x1e")
	if !strings.Contains(request.KernelTag, kernelVersion) {
		return Plan{}, errors.New("paired kernel tag and ABI do not identify the same version")
	}
	releaseDirectory := filepath.Join(output, request.Tag)
	if containedBy(artifacts, output) || containedBy(output, artifacts) {
		return Plan{}, errors.New("camera build and release directories must not overlap")
	}
	return Plan{
		RepositoryRoot:               root,
		ArtifactsDirectory:           artifacts,
		OutputDirectory:              output,
		ReleaseDirectory:             releaseDirectory,
		Tag:                          request.Tag,
		KernelTag:                    request.KernelTag,
		KernelABI:                    request.KernelABI,
		ExpectedBuildAuthoritySHA256: request.ExpectedBuildAuthoritySHA256,
		DryRun:                       request.DryRun,
		Executable:                   true,
		MutatesRemote:                false,
	}, nil
}

// Prepare validates and atomically installs one new local release directory.
func (manager *Manager) Prepare(ctx context.Context, request Request) (receipt Receipt, resultErr error) {
	receipt.StartedAt = managerTime(manager)
	defer func() {
		receipt.CompletedAt = managerTime(manager)
	}()
	plan, err := manager.prepare(ctx, request)
	if err != nil {
		return receipt, err
	}
	receipt.Plan = plan
	if plan.DryRun {
		return receipt, nil
	}
	if !plan.Executable {
		return receipt, errors.New(plan.ExecutionBlocker)
	}
	if manager.validate == nil {
		return receipt, errors.New("camera build-bundle validator is unavailable")
	}
	if err := os.MkdirAll(plan.OutputDirectory, 0o755); err != nil {
		return receipt, fmt.Errorf("create camera release root: %w", err)
	}
	if err := rejectSymbolicRoute(plan.RepositoryRoot, plan.OutputDirectory); err != nil {
		return receipt, err
	}
	staging, err := os.MkdirTemp(plan.OutputDirectory, ".prepare-"+plan.Tag+"-")
	if err != nil {
		return receipt, fmt.Errorf("create private camera release transaction: %w", err)
	}
	if err := os.Chmod(staging, 0o700); err != nil {
		_ = os.RemoveAll(staging)
		return receipt, err
	}
	original, err := os.Lstat(staging)
	if err != nil {
		_ = os.RemoveAll(staging)
		return receipt, err
	}
	cleanup := true
	defer func() {
		if !cleanup {
			return
		}
		current, err := os.Lstat(staging)
		if err == nil && current.Mode()&os.ModeSymlink == 0 && os.SameFile(original, current) {
			resultErr = errors.Join(resultErr, os.RemoveAll(staging))
		} else if !errors.Is(err, os.ErrNotExist) {
			resultErr = errors.Join(resultErr, errors.New("refuse to remove changed camera release transaction"))
		}
	}()

	if err := copyUnvalidatedBundle(plan.ArtifactsDirectory, staging); err != nil {
		return receipt, err
	}
	bundle, err := manager.validate(ctx, manager.Runner, camerabuild.ValidationRequest{
		RepositoryRoot:          plan.RepositoryRoot,
		Directory:               staging,
		ExpectedAuthoritySHA256: plan.ExpectedBuildAuthoritySHA256,
	})
	if err != nil {
		return receipt, fmt.Errorf("validate private camera build bundle: %w", err)
	}
	buildFiles, err := inspectBuildBundle(staging, bundle)
	if err != nil {
		return receipt, err
	}
	checksums := renderChecksums(buildFiles)
	if err := writeExclusive(filepath.Join(staging, ChecksumName), checksums, 0o644); err != nil {
		return receipt, err
	}
	notes := renderNotes(plan, bundle, buildFiles)
	if err := writeExclusive(filepath.Join(staging, NotesName), notes, 0o644); err != nil {
		return receipt, err
	}
	checksumFile, err := inspectFile(filepath.Join(staging, ChecksumName))
	if err != nil {
		return receipt, err
	}
	notesFile, err := inspectFile(filepath.Join(staging, NotesName))
	if err != nil {
		return receipt, err
	}
	manifest := Manifest{
		SchemaVersion:    SchemaVersion,
		Status:           "verified-local-preparation",
		Tag:              plan.Tag,
		PreparedAt:       receipt.StartedAt,
		KernelTag:        plan.KernelTag,
		KernelABI:        plan.KernelABI,
		BuildReceiptName: camerabuild.ReceiptName,
		Build:            bundle,
		BuildArtifacts:   buildFiles,
		GeneratedFiles:   []GeneratedFile{checksumFile, notesFile},
		SourceAndLicenceProvenance: SourceAndLicenceProvenance{
			UbuntuSourceURL: bundle.Source.SourceURL,
			UbuntuSourceSHA256: map[string]string{
				bundle.Source.DSC.Name:           bundle.Source.DSC.SHA256,
				bundle.Source.OrigTarball.Name:   bundle.Source.OrigTarball.SHA256,
				bundle.Source.DebianTarball.Name: bundle.Source.DebianTarball.SHA256,
			},
			DebianCopyrightSHA256: bundle.Source.CopyrightFileSHA256,
			Evidence:              append([]string(nil), bundle.Source.LicenceEvidence...),
		},
		RemoteMutation: false,
	}
	manifestData, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return receipt, fmt.Errorf("serialise camera release manifest: %w", err)
	}
	manifestData = append(manifestData, '\n')
	if err := writeExclusive(filepath.Join(staging, ManifestName), manifestData, 0o644); err != nil {
		return receipt, err
	}
	if err := validatePreparedDirectory(staging, manifest); err != nil {
		return receipt, err
	}
	if err := syncDirectory(staging); err != nil {
		return receipt, err
	}
	if err := publishNoReplace(staging, plan.ReleaseDirectory); err != nil {
		return receipt, fmt.Errorf("atomically publish local camera release: %w", err)
	}
	cleanup = false
	if err := syncDirectory(plan.OutputDirectory); err != nil {
		return receipt, err
	}
	authority, err := inspectFile(filepath.Join(plan.ReleaseDirectory, ManifestName))
	if err != nil {
		return receipt, fmt.Errorf("inspect published camera release authority: %w", err)
	}
	receipt.Manifest = &manifest
	receipt.AuthoritySHA256 = authority.SHA256
	receipt.Published = true
	return receipt, nil
}

// canonicalDirectory resolves one existing real directory without links.
func canonicalDirectory(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", errors.New("directory path is required")
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	absolute = filepath.Clean(absolute)
	info, err := os.Lstat(absolute)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("directory must be real and non-symbolic: %s", absolute)
	}
	canonical, err := filepath.EvalSymlinks(absolute)
	if err != nil || filepath.Clean(canonical) != absolute {
		return "", fmt.Errorf("directory route contains a symbolic link: %s", absolute)
	}
	return absolute, nil
}

// relativeTarget resolves a canonical repository-relative directory route.
func relativeTarget(root, selected, fallback string) (string, error) {
	if selected == "" {
		selected = fallback
	}
	if filepath.IsAbs(selected) || filepath.Clean(selected) != selected || selected == "." {
		return "", errors.New("camera release output must be a canonical repository-relative path")
	}
	target := filepath.Join(root, selected)
	if !containedBy(root, target) || target == root {
		return "", errors.New("camera release output escapes the repository root")
	}
	if err := rejectSymbolicRoute(root, target); err != nil {
		return "", err
	}
	return target, nil
}

// containedBy reports equality or strict descent beneath a directory.
func containedBy(root, target string) bool {
	relative, err := filepath.Rel(filepath.Clean(root), filepath.Clean(target))
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// rejectSymbolicRoute checks every existing component beneath a trusted root.
func rejectSymbolicRoute(root, target string) error {
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return err
	}
	current := root
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("camera release route contains a symbolic link: %s", current)
		}
	}
	return nil
}

// unsafeText rejects control, invalid UTF-8, and bidirectional tag text.
func unsafeText(value string) bool {
	if !utf8.ValidString(value) {
		return true
	}
	for _, character := range value {
		if unicode.IsControl(character) || character == '\u061c' || character == '\u200e' || character == '\u200f' || (character >= '\u202a' && character <= '\u202e') || (character >= '\u2066' && character <= '\u2069') {
			return true
		}
	}
	return false
}

// copyUnvalidatedBundle snapshots exactly eight regular build files privately
// before any external package inspection can observe them.
func copyUnvalidatedBundle(source, destination string) error {
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	if len(entries) != 8 {
		return fmt.Errorf("camera build bundle contains %d entries, want 8", len(entries))
	}
	foundReceipt := false
	for _, entry := range entries {
		name := entry.Name()
		if filepath.Base(name) != name || strings.HasPrefix(name, ".") || strings.ContainsAny(name, "\x00\r\n\\") {
			return fmt.Errorf("unsafe camera build artefact name: %q", name)
		}
		if name == camerabuild.ReceiptName {
			foundReceipt = true
		}
		if err := copyRegular(filepath.Join(source, name), filepath.Join(destination, name)); err != nil {
			return err
		}
	}
	if !foundReceipt {
		return errors.New("camera build bundle lacks its structured receipt")
	}
	return nil
}

// inspectBuildBundle records exactly seven build outputs and their receipt.
func inspectBuildBundle(directory string, bundle camerabuild.BundleReceipt) ([]GeneratedFile, error) {
	names := make([]string, 0, 8)
	for _, artifact := range bundle.Artifacts {
		names = append(names, artifact.Name)
	}
	names = append(names, camerabuild.ReceiptName)
	sort.Strings(names)
	files := make([]GeneratedFile, 0, len(names))
	for _, name := range names {
		if filepath.Base(name) != name || strings.HasPrefix(name, ".") {
			return nil, fmt.Errorf("unsafe camera build artefact name: %q", name)
		}
		file, err := inspectFile(filepath.Join(directory, name))
		if err != nil {
			return nil, err
		}
		files = append(files, file)
	}
	return files, nil
}

// copyRegular copies one new non-link artefact without preserving host metadata.
func copyRegular(source, destination string) error {
	before, err := os.Lstat(source)
	if err != nil || before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() || before.Size() <= 0 || before.Size() > maximumReleaseFileBytes {
		return fmt.Errorf("camera build artefact is not regular: %s", source)
	}
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	opened, err := input.Stat()
	if err != nil {
		return err
	}
	current, err := os.Lstat(source)
	if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(before, opened) || !os.SameFile(opened, current) {
		return fmt.Errorf("camera build artefact changed while it was opened: %s", source)
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	written, copyErr := io.Copy(output, io.LimitReader(input, maximumReleaseFileBytes+1))
	if copyErr == nil && written != opened.Size() {
		copyErr = errors.New("camera build artefact changed while it was copied")
	}
	syncErr := output.Sync()
	closeErr := output.Close()
	if err := errors.Join(copyErr, syncErr, closeErr); err != nil {
		return fmt.Errorf("copy camera build artefact %s: %w", filepath.Base(source), err)
	}
	after, err := os.Lstat(source)
	if err != nil || after.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, after) || after.Size() != opened.Size() {
		return fmt.Errorf("camera build artefact changed during private snapshot: %s", source)
	}
	return nil
}

// inspectFile records the complete digest and length of one regular file.
func inspectFile(path string) (GeneratedFile, error) {
	before, err := os.Lstat(path)
	if err != nil || before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() || before.Size() <= 0 || before.Size() > maximumReleaseFileBytes {
		return GeneratedFile{}, fmt.Errorf("camera release file is invalid: %s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return GeneratedFile{}, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return GeneratedFile{}, err
	}
	current, err := os.Lstat(path)
	if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(before, opened) || !os.SameFile(opened, current) {
		return GeneratedFile{}, fmt.Errorf("camera release file changed while it was opened: %s", path)
	}
	digest := sha256.New()
	written, err := io.Copy(digest, io.LimitReader(file, maximumReleaseFileBytes+1))
	if err != nil || written != opened.Size() {
		return GeneratedFile{}, fmt.Errorf("read complete camera release file %s", path)
	}
	after, err := os.Lstat(path)
	if err != nil || after.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, after) || after.Size() != opened.Size() {
		return GeneratedFile{}, fmt.Errorf("camera release file changed after it was read: %s", path)
	}
	return GeneratedFile{Name: filepath.Base(path), SHA256: hex.EncodeToString(digest.Sum(nil)), Size: written}, nil
}

// renderChecksums returns deterministic GNU-compatible entries for eight files.
func renderChecksums(files []GeneratedFile) []byte {
	var output strings.Builder
	for _, file := range files {
		fmt.Fprintf(&output, "%s  %s\n", file.SHA256, file.Name)
	}
	return []byte(output.String())
}

// renderNotes returns path-free British-English release guidance.
func renderNotes(plan Plan, bundle camerabuild.BundleReceipt, files []GeneratedFile) []byte {
	var output strings.Builder
	fmt.Fprintf(&output, "# Surface Pro 11 IMX681 libcamera package set\n\n")
	fmt.Fprintf(&output, "This local release preparation contains one coherent, ARM64 libcamera runtime set for the Surface Pro 11. It is paired explicitly with kernel `%s` and installed ABI `%s`; no older camera-kernel generation is assumed.\n\n", plan.KernelTag, plan.KernelABI)
	fmt.Fprintf(&output, "## Closed artefact set\n\n")
	for _, file := range files {
		fmt.Fprintf(&output, "- `%s`\n", file.Name)
	}
	fmt.Fprintf(&output, "\n`%s` covers those eight build artefacts exactly once. `%s` records this local preparation without publishing it.\n\n", ChecksumName, ManifestName)
	fmt.Fprintf(&output, "## Verify and install\n\n```bash\nsha256sum --check --strict SHA256SUMS\n\nsudo apt install -- \\\n")
	runtimePackages := camerabuild.RuntimePackageNames()
	for index, name := range runtimePackages {
		suffix := " \\\n"
		if index == len(runtimePackages)-1 {
			suffix = "\n"
		}
		fmt.Fprintf(&output, "  ./%s_%s_arm64.deb%s", name, bundle.PackageVersion, suffix)
	}
	fmt.Fprintf(&output, "```\n\nReboot after installing the paired kernel and all five userspace packages so clients load one package generation. Hardware camera operation, privacy indication and suspend behaviour remain explicit device tests; local preparation does not claim those results.\n\n")
	fmt.Fprintf(&output, "## Source and licence provenance\n\n- Ubuntu source: %s\n- Source version: `%s`\n- Upstream commit: `%s`\n- Support commit: `%s`\n- Authenticated `debian/copyright`: `%s`\n- Package copyright records are retained under `/usr/share/doc` in the Debian packages.\n- Exact source, input, image, recipe and output digests are in `%s` and `%s`.\n\n", bundle.Source.SourceURL, bundle.Source.UbuntuVersion, bundle.Source.UpstreamCommit, bundle.SupportCommit, bundle.Source.CopyrightFileSHA256, camerabuild.ReceiptName, ManifestName)
	fmt.Fprintf(&output, "Prepared tag: `%s`\n", plan.Tag)
	return []byte(output.String())
}

// writeExclusive writes one deterministic generated file durably.
func writeExclusive(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(data)
	syncErr := file.Sync()
	closeErr := file.Close()
	return errors.Join(writeErr, syncErr, closeErr)
}

// validatePreparedDirectory proves the exact eleven-file local release shape.
func validatePreparedDirectory(directory string, manifest Manifest) error {
	expected := map[string]struct{}{ChecksumName: {}, NotesName: {}, ManifestName: {}}
	for _, file := range manifest.BuildArtifacts {
		expected[file.Name] = struct{}{}
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	if len(entries) != 11 || len(expected) != 11 {
		return fmt.Errorf("camera release contains %d entries, want 11", len(entries))
	}
	for _, entry := range entries {
		if _, ok := expected[entry.Name()]; !ok {
			return fmt.Errorf("unexpected camera release entry: %s", entry.Name())
		}
		info, err := os.Lstat(filepath.Join(directory, entry.Name()))
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("camera release entry is not regular: %s", entry.Name())
		}
	}
	checksumData, err := os.ReadFile(filepath.Join(directory, ChecksumName))
	if err != nil || !bytes.Equal(checksumData, renderChecksums(manifest.BuildArtifacts)) {
		return errors.New("camera release checksum authority changed during preparation")
	}
	return nil
}

// syncDirectory flushes generated directory entries before reporting success.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	return errors.Join(syncErr, closeErr)
}
