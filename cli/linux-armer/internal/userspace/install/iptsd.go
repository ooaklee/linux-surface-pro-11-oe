package install

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// iptsdArchiveName is the sole source-bearing payload accepted for pen input.
const iptsdArchiveName = "sp11-iptsd-3.1.0-sp11.1-arm64.tar.xz"

// iptsdWritableTargets enumerates every regular file installed by the pinned
// integration script so alternate-root parent links can be checked first.
var iptsdWritableTargets = []string{
	"usr/local/libexec/sp11-iptsd",
	"usr/local/libexec/sp11-iptsd-check-device",
	"usr/local/share/iptsd/surface-pro-11-0c80.conf",
	"usr/local/share/iptsd/surface-pro-11-0c83.conf",
	"usr/local/share/doc/sp11-iptsd/README.md",
	"usr/local/share/doc/sp11-iptsd/SOURCE.env",
	"usr/local/share/doc/sp11-iptsd/BUILD.env",
	"usr/local/share/doc/sp11-iptsd/SHA256SUMS",
	"usr/local/share/doc/sp11-iptsd/COPYING.Eigen.APACHE",
	"usr/local/share/doc/sp11-iptsd/COPYING.Eigen.BSD",
	"usr/local/share/doc/sp11-iptsd/COPYING.Eigen.MINPACK",
	"usr/local/share/doc/sp11-iptsd/COPYING.Eigen.MPL2",
	"usr/local/share/doc/sp11-iptsd/COPYING.Eigen.README",
	"usr/local/share/doc/sp11-iptsd/LICENSE.CLI11",
	"usr/local/share/doc/sp11-iptsd/LICENSE.Eigen",
	"usr/local/share/doc/sp11-iptsd/LICENSE.Eigen.build",
	"usr/local/share/doc/sp11-iptsd/LICENSE.Microsoft-GSL",
	"usr/local/share/doc/sp11-iptsd/LICENSE.Microsoft-GSL.build",
	"usr/local/share/doc/sp11-iptsd/LICENSE.fmt",
	"usr/local/share/doc/sp11-iptsd/LICENSE.fmt.build",
	"usr/local/share/doc/sp11-iptsd/LICENSE.inih",
	"usr/local/share/doc/sp11-iptsd/LICENSE.integration",
	"usr/local/share/doc/sp11-iptsd/LICENSE.iptsd",
	"usr/local/share/doc/sp11-iptsd/LICENSE.spdlog",
	"usr/local/share/doc/sp11-iptsd/LICENSE.spdlog.build",
	"etc/systemd/system/sp11-iptsd@.service",
	"etc/udev/rules.d/70-sp11-iptsd.rules",
	"usr/lib/systemd/system-sleep/sp11-iptsd-restart",
}

// IPTSD validates the complete pinned archive, securely extracts it, and
// invokes only its exact bundled installer and payload. Confirmation is a CLI
// concern; this method never escalates privileges itself.
func (installer *Installer) IPTSD(ctx context.Context, options Options) (Result, error) {
	options, err := normalizeOptions(options)
	if err != nil {
		return Result{}, err
	}
	bundle, err := verifyBundle(options.BundleDir, iptsdSpec)
	if err != nil {
		return Result{}, err
	}
	archive := bundle.paths[iptsdArchiveName]
	if err := validateIPTSDRoot(options.Root); err != nil {
		return Result{}, err
	}
	result := Result{
		Component: IPTSDComponent,
		Root:      options.Root,
		DryRun:    options.DryRun,
		Command: &Command{
			Name: "/bin/bash",
			Args: []string{
				"sp11-iptsd-v1/scripts/install-sp11-iptsd.sh",
				"--root", options.Root,
				"--payload", "sp11-iptsd-v1/payload/iptsd-sp11",
			},
		},
		RebootRequired: false,
	}
	if options.DryRun {
		if err := installer.extractor.Validate(ctx, archive); err != nil {
			return Result{}, fmt.Errorf("validate iptsd release archive: %w", err)
		}
		return result, nil
	}
	if err := installer.requireRoot(false); err != nil {
		return Result{}, err
	}
	stage, err := os.MkdirTemp("", "linux-armer-iptsd-install-*")
	if err != nil {
		return Result{}, fmt.Errorf("create private iptsd staging directory: %w", err)
	}
	if err := os.Chmod(stage, 0o700); err != nil {
		_ = os.RemoveAll(stage)
		return Result{}, fmt.Errorf("protect iptsd staging directory: %w", err)
	}
	defer os.RemoveAll(stage)
	stagedArchive := filepath.Join(stage, iptsdArchiveName)
	immutable := immutableByName(iptsdSpec, iptsdArchiveName)
	if err := atomicCopyVerified(archive, stagedArchive, 0o600, immutable.sha256, immutable.size); err != nil {
		return Result{}, fmt.Errorf("stage verified iptsd archive: %w", err)
	}
	extractionRoot := filepath.Join(stage, "extracted")
	if err := os.Mkdir(extractionRoot, 0o700); err != nil {
		return Result{}, fmt.Errorf("create iptsd extraction root: %w", err)
	}
	if err := installer.extractor.Extract(ctx, stagedArchive, extractionRoot); err != nil {
		return Result{}, fmt.Errorf("extract iptsd release archive: %w", err)
	}
	archiveRoot := filepath.Join(extractionRoot, iptsdArchiveRoot)
	script, err := requireContainedRegular(archiveRoot, "scripts/install-sp11-iptsd.sh")
	if err != nil {
		return Result{}, err
	}
	if _, err := requireContainedRegular(archiveRoot, "scripts/validate-sp11-iptsd-payload.sh"); err != nil {
		return Result{}, err
	}
	payload, err := requireContainedDirectory(archiveRoot, "payload/iptsd-sp11")
	if err != nil {
		return Result{}, err
	}
	if _, err := requireContainedDirectory(archiveRoot, "userspace/iptsd-sp11/packaging"); err != nil {
		return Result{}, err
	}
	if err := installer.runner.Run(ctx, platform.Command{
		Name: "/bin/bash",
		Args: []string{script, "--root", options.Root, "--payload", payload},
	}); err != nil {
		return Result{}, fmt.Errorf("install pinned iptsd integration: %w", err)
	}
	return result, nil
}

// validateIPTSDRoot preflights all script targets and the one intentional mask.
func validateIPTSDRoot(root string) error {
	for _, target := range iptsdWritableTargets {
		if _, err := resolveTarget(root, target); err != nil {
			return err
		}
	}
	// The generic service mask is the only intentional final symlink. The
	// bundled script accepts only an existing /dev/null mask and refuses every
	// custom file or alternate link.
	parentSentinel, err := resolveTarget(root, "etc/systemd/system/.linux-armer-sentinel")
	if err != nil {
		return err
	}
	mask := filepath.Join(filepath.Dir(parentSentinel), "iptsd@.service")
	info, err := os.Lstat(mask)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect generic iptsd mask: %w", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return fmt.Errorf("refusing to replace custom generic iptsd unit: %s", mask)
	}
	target, err := os.Readlink(mask)
	if err != nil {
		return fmt.Errorf("read generic iptsd mask: %w", err)
	}
	if target != "/dev/null" {
		return fmt.Errorf("generic iptsd mask has unexpected target %q", target)
	}
	return nil
}

// immutableByName returns one compiled artefact record from a release policy.
func immutableByName(spec releaseSpec, name string) immutableFile {
	for _, immutable := range spec.files {
		if immutable.name == name {
			return immutable
		}
	}
	return immutableFile{}
}

// requireContainedRegular rejects extracted links and special files before use.
func requireContainedRegular(root, relative string) (string, error) {
	path, err := containedPath(root, relative)
	if err != nil {
		return "", err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("inspect pinned iptsd file %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", fmt.Errorf("pinned iptsd path must be a regular non-symlink file: %s", path)
	}
	return path, nil
}

// requireContainedDirectory rejects link-substituted extracted directories.
func requireContainedDirectory(root, relative string) (string, error) {
	path, err := containedPath(root, relative)
	if err != nil {
		return "", err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("inspect pinned iptsd directory %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("pinned iptsd path must be a regular non-symlink directory: %s", path)
	}
	return path, nil
}

// containedPath maps one archive-relative path without permitting traversal.
func containedPath(root, relative string) (string, error) {
	if filepath.IsAbs(relative) || filepath.Clean(relative) == ".." {
		return "", fmt.Errorf("unsafe pinned iptsd path %q", relative)
	}
	path := filepath.Join(root, filepath.FromSlash(relative))
	if !withinRoot(root, path) || path == root {
		return "", fmt.Errorf("pinned iptsd path escapes archive root: %q", relative)
	}
	return path, nil
}
