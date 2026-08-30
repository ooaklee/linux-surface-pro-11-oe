package install

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// Camera installs the exact five-package ARM64 runtime set in one apt-get
// transaction. Package-manager installation into an offline alternate root is
// intentionally unsupported.
func (installer *Installer) Camera(ctx context.Context, options Options) (Result, error) {
	options, err := normalizeOptions(options)
	if err != nil {
		return Result{}, err
	}
	if options.Root != string(filepath.Separator) {
		return Result{}, errors.New("camera package installation is supported only for target root /")
	}
	bundle, err := installer.verifyCameraInput(ctx, options)
	if err != nil {
		return Result{}, err
	}
	args := []string{"install", "--yes", "--no-install-recommends", "--"}
	for _, immutable := range bundle.runtimeFiles {
		path, ok := bundle.paths[immutable.name]
		if !ok {
			return Result{}, fmt.Errorf("verified camera bundle is missing %s", immutable.name)
		}
		args = append(args, path)
	}
	result := Result{
		Component: CameraComponent,
		Root:      options.Root,
		DryRun:    options.DryRun,
		Command:   &Command{Name: "apt-get", Args: append([]string(nil), args...)},
	}
	if options.DryRun {
		return result, nil
	}
	if err := installer.requireRoot(false); err != nil {
		return Result{}, err
	}
	stage, err := createPrivateInstallStaging("linux-armer-camera-install-*")
	if err != nil {
		return Result{}, fmt.Errorf("create private camera staging directory: %w", err)
	}
	defer os.RemoveAll(stage)
	executionArgs := []string{"install", "--yes", "--no-install-recommends", "--"}
	for _, immutable := range bundle.runtimeFiles {
		staged := filepath.Join(stage, immutable.name)
		if err := atomicCopyVerified(bundle.paths[immutable.name], staged, 0o600, immutable.sha256, immutable.size); err != nil {
			return Result{}, fmt.Errorf("stage verified camera package %s: %w", immutable.name, err)
		}
		executionArgs = append(executionArgs, staged)
	}
	if err := installer.runner.Run(ctx, platform.Command{Name: "apt-get", Args: executionArgs}); err != nil {
		return Result{}, fmt.Errorf("install exact IMX681 libcamera package set: %w", err)
	}
	return result, nil
}
