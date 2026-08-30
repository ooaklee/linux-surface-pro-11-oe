package releaseprep

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// prepare executes a validated plan through one fresh atomic local publication.
func (manager *Manager) prepare(ctx context.Context, request Request) (Receipt, error) {
	plan, err := manager.plan(ctx, request)
	receipt := Receipt{Plan: plan}
	if err != nil {
		return receipt, err
	}
	if plan.DryRun {
		return receipt, nil
	}
	if err := ctx.Err(); err != nil {
		return receipt, err
	}
	if err := revalidatePlan(ctx, plan); err != nil {
		return receipt, fmt.Errorf("revalidate kernel release inputs: %w", err)
	}
	if err := prepareOutputParent(plan.OutputDirectory); err != nil {
		return receipt, err
	}
	if _, err := canonicalNewOutput(plan.OutputDirectory); err != nil {
		return receipt, fmt.Errorf("revalidate new release output: %w", err)
	}
	parent := filepath.Dir(plan.OutputDirectory)
	staging, err := os.MkdirTemp(parent, ".linux-armer-kernel-release-")
	if err != nil {
		return receipt, fmt.Errorf("create kernel release staging directory: %w", err)
	}
	staging = filepath.Clean(staging)
	stagingInfo, err := os.Lstat(staging)
	if err != nil || stagingInfo.Mode()&os.ModeSymlink != 0 || !stagingInfo.IsDir() {
		return receipt, fmt.Errorf("inspect kernel release staging directory: %s", staging)
	}
	removeStaging := true
	defer func() {
		if removeStaging {
			_ = removeSameDirectory(staging, stagingInfo)
		}
	}()
	for _, input := range plan.Inputs {
		if manager.beforeCopy != nil {
			manager.beforeCopy(input)
		}
		if err := copyPlannedAsset(ctx, input, filepath.Join(staging, input.Asset.Name)); err != nil {
			return receipt, err
		}
	}
	if err := writeJSONExclusive(filepath.Join(staging, BundleFileName), plan.Bundle); err != nil {
		return receipt, err
	}
	if err := writeJSONExclusive(filepath.Join(staging, ReleaseManifestFileName), plan.Manifest); err != nil {
		return receipt, err
	}
	if err := writeTextExclusive(filepath.Join(staging, ReleaseNotesFileName), renderReleaseNotes(plan)); err != nil {
		return receipt, err
	}
	if err := writeChecksums(ctx, staging); err != nil {
		return receipt, err
	}
	if _, err := validateDirectory(ctx, staging); err != nil {
		return receipt, fmt.Errorf("validate staged kernel release: %w", err)
	}
	if err := os.Chmod(staging, 0o755); err != nil {
		return receipt, fmt.Errorf("set published kernel release permissions: %w", err)
	}
	if err := syncDirectory(staging); err != nil {
		return receipt, fmt.Errorf("flush staged kernel release: %w", err)
	}
	if _, err := canonicalNewOutput(plan.OutputDirectory); err != nil {
		return receipt, fmt.Errorf("release output changed before publication: %w", err)
	}
	if canonical, err := canonicalDirectory(parent, "release output parent"); err != nil || canonical != parent {
		return receipt, fmt.Errorf("release output parent changed before publication: %s", parent)
	}
	if manager.beforePublish != nil {
		manager.beforePublish()
	}
	if err := ctx.Err(); err != nil {
		return receipt, err
	}
	if err := publishDirectoryNoReplace(staging, plan.OutputDirectory); err != nil {
		return receipt, fmt.Errorf("publish kernel release directory: %w", err)
	}
	removeStaging = false
	receipt.Published = true
	if err := syncDirectory(parent); err != nil {
		return receipt, fmt.Errorf("flush kernel release parent: %w", err)
	}
	receipt.Durable = true
	return receipt, nil
}

// prepareOutputParent creates a missing output parent beneath its nearest safe ancestor.
func prepareOutputParent(output string) error {
	parent := filepath.Dir(output)
	ancestor := parent
	for {
		_, err := os.Lstat(ancestor)
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect prospective release parent: %w", err)
		}
		next := filepath.Dir(ancestor)
		if next == ancestor {
			return errors.New("could not locate an existing release-output ancestor")
		}
		ancestor = next
	}
	canonicalAncestor, err := canonicalDirectory(ancestor, "release output ancestor")
	if err != nil || canonicalAncestor != ancestor {
		return fmt.Errorf("release output ancestor is unsafe: %s", ancestor)
	}
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return fmt.Errorf("create release output parent: %w", err)
	}
	canonicalParent, err := canonicalDirectory(parent, "release output parent")
	if err != nil || canonicalParent != parent {
		return fmt.Errorf("created release output parent is unsafe: %s", parent)
	}
	return nil
}

// copyPlannedAsset remeasures one unchanged input while copying it to a new file.
func copyPlannedAsset(ctx context.Context, planned PlannedAsset, destination string) (returnErr error) {
	info, err := os.Lstat(planned.SourcePath)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() != planned.Asset.Size {
		return fmt.Errorf("release input changed before copy: %s", planned.SourcePath)
	}
	source, err := os.Open(planned.SourcePath)
	if err != nil {
		return err
	}
	opened, err := source.Stat()
	if err != nil || !os.SameFile(info, opened) {
		_ = source.Close()
		return fmt.Errorf("release input changed while opening: %s", planned.SourcePath)
	}
	target, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		_ = source.Close()
		return err
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.Remove(destination)
		}
	}()
	hasher := sha256.New()
	written, copyErr := copyContext(ctx, io.MultiWriter(target, hasher), source, maximumAssetBytes)
	sourceCloseErr := source.Close()
	targetSyncErr := target.Sync()
	targetCloseErr := target.Close()
	current, statErr := os.Lstat(planned.SourcePath)
	if err := errors.Join(copyErr, sourceCloseErr, targetSyncErr, targetCloseErr, statErr); err != nil {
		return err
	}
	if current.Mode()&os.ModeSymlink != 0 || !os.SameFile(info, current) || current.Size() != info.Size() {
		return fmt.Errorf("release input changed during copy: %s", planned.SourcePath)
	}
	digest := hex.EncodeToString(hasher.Sum(nil))
	if written != planned.Asset.Size || digest != planned.Asset.SHA256 {
		return fmt.Errorf("release input identity changed during copy: %s", planned.SourcePath)
	}
	complete = true
	return nil
}

// writeJSONExclusive writes one indented public contract without replacing a file.
func writeJSONExclusive(path string, value any) error {
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
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		_ = os.Remove(path)
		return err
	}
	return nil
}

// writeTextExclusive writes one bounded generated text file without replacement.
func writeTextExclusive(path, value string) error {
	if value == "" || int64(len(value)) > maximumTextBytes {
		return errors.New("generated release text is empty or exceeds its limit")
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, writeErr := io.WriteString(file, value)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		_ = os.Remove(path)
		return err
	}
	return nil
}

// writeChecksums covers every prepared release file except the checksum file itself.
func writeChecksums(ctx context.Context, directory string) error {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	digests := make(map[string]string, len(entries))
	for _, entry := range entries {
		if entry.Name() == ChecksumFileName {
			return fmt.Errorf("staging already contains %s", ChecksumFileName)
		}
		identity, err := inspectRegular(ctx, filepath.Join(directory, entry.Name()), "prepared release file", maximumAssetBytes)
		if err != nil {
			return err
		}
		digests[entry.Name()] = identity.sha256
	}
	file, err := os.OpenFile(filepath.Join(directory, ChecksumFileName), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	writer := bufio.NewWriter(file)
	for _, name := range sortedKeys(digests) {
		if _, err := fmt.Fprintf(writer, "%s  %s\n", digests[name], name); err != nil {
			_ = file.Close()
			return err
		}
	}
	flushErr := writer.Flush()
	syncErr := file.Sync()
	closeErr := file.Close()
	return errors.Join(flushErr, syncErr, closeErr)
}

// renderReleaseNotes produces public, path-free British-English guidance.
func renderReleaseNotes(plan Plan) string {
	var sourceNames, licenceNames []string
	for _, asset := range plan.Manifest.Assets {
		switch asset.Kind {
		case AssetSource:
			sourceNames = append(sourceNames, asset.Name)
		case AssetLicence:
			licenceNames = append(licenceNames, asset.Name)
		}
	}
	sort.Strings(sourceNames)
	sort.Strings(licenceNames)
	return fmt.Sprintf(`# Surface Pro 11 qcom-x1e kernel packages

This is an experimental, unsigned Surface Pro 11 kernel bundle. Structural
validation does not make it hardware-qualified. Keep a known-good fallback
qcom-x1e kernel installed and keep recovery media available.

## Identity

- Release: %s
- ABI: %s
- Package version: %s
- Source revision: %s
- Source tree: %s
- Corresponding source: %s
- Licence evidence: %s

## Verify

Run:

~~~sh
linux-armer kernel release validate <downloaded-release-directory>
~~~

The command requires exact checksum coverage, one coherent image/modules pair,
paired headers when present, corresponding source, explicit licence evidence,
and no additional files.

## Install

Review the installation preflight first, naming the known-good fallback ABI:

~~~sh
linux-armer kernel preflight <downloaded-release-directory> --root / --fallback-abi <running-fallback-abi>
sudo linux-armer kernel install <downloaded-release-directory> --root / --fallback-abi <running-fallback-abi> --yes
~~~

Reboot manually only when ready. Retain the fallback kernel until the new
kernel, device trees and required hardware have been tested on the Surface.
`, plan.Manifest.ReleaseName, plan.Manifest.ABI, plan.Manifest.Version,
		plan.Manifest.Source.Revision, plan.Manifest.Source.Tree,
		strings.Join(sourceNames, ", "), strings.Join(licenceNames, ", "))
}

// removeSameDirectory removes only the unchanged staging directory identity.
func removeSameDirectory(path string, expected os.FileInfo) error {
	current, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(current, expected) {
		return fmt.Errorf("refuse to remove changed release staging directory: %s", path)
	}
	return os.RemoveAll(path)
}

// syncDirectory flushes directory metadata before publication is reported durable.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	return errors.Join(syncErr, closeErr)
}
