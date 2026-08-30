// Package build delegates custom kernel compilation to the repository's
// maintained, containerised kernel build workflow.
package build

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// DefaultGitURL is the maintained Surface Pro 11 kernel source used when no
	// repository URL is supplied.
	DefaultGitURL = "https://github.com/ooaklee/linux_ms_dev_kit-sp11"
	// DefaultGitBranch is the integration branch used for a default kernel build.
	DefaultGitBranch = "sp11/integration-7.2.x"
)

// Request contains the explicit inputs passed to the maintained kernel build
// helper.
type Request struct {
	// RepositoryRoot locates the OE checkout containing the delegated script.
	RepositoryRoot string
	// GitURL selects the kernel source repository.
	GitURL string
	// GitBranch selects the kernel source branch or ref.
	GitBranch string
	// WorkDirectory stores reusable source and intermediate build data.
	WorkDirectory string
	// OutputDirectory receives completed packages and manifests.
	OutputDirectory string
	// Jobs limits the build helper's parallel compilation jobs when positive.
	Jobs int
	// ResetSource permits the delegated helper to reset its managed source tree.
	ResetSource bool
	// SkipClean asks the delegated helper to reuse existing build products.
	SkipClean bool
	// DryRun prints the delegated operation without executing the build.
	DryRun bool
}

// Manager validates build inputs and delegates compilation through a command
// runner rather than reproducing the maintained shell workflow.
type Manager struct {
	// Runner executes the repository build helper.
	Runner platform.Runner
}

// New constructs a kernel build manager, using direct process execution when
// runner is nil.
func New(runner platform.Runner) *Manager {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Manager{Runner: runner}
}

// Run locates the allow-listed kernel build helper and invokes it with distinct,
// shell-safe arguments derived from request.
func (m *Manager) Run(ctx context.Context, request Request) error {
	if m == nil || m.Runner == nil {
		return errors.New("kernel build runner is unavailable")
	}
	root, err := resolveRepositoryRoot(request.RepositoryRoot)
	if err != nil {
		return err
	}
	script := filepath.Join(root, "scripts", "build-sp11-qcom-x1e-kernel-docker.sh")
	if info, err := os.Stat(script); err != nil || !info.Mode().IsRegular() {
		if err == nil {
			err = errors.New("not a regular file")
		}
		return fmt.Errorf("locate kernel build helper: %w", err)
	}
	if request.GitURL == "" {
		request.GitURL = DefaultGitURL
	}
	if request.GitBranch == "" {
		request.GitBranch = DefaultGitBranch
	}
	if request.WorkDirectory == "" {
		request.WorkDirectory = "build/linux-armer/kernel-build"
	}
	if request.OutputDirectory == "" {
		request.OutputDirectory = "build/linux-armer/kernel"
	}
	args := []string{
		script,
		"--source", "git",
		"--git-url", request.GitURL,
		"--git-branch", request.GitBranch,
		"--work-dir", request.WorkDirectory,
		"--payload-dir", request.OutputDirectory,
	}
	if request.Jobs > 0 {
		args = append(args, "--jobs", fmt.Sprintf("%d", request.Jobs))
	}
	if request.ResetSource {
		args = append(args, "--reset-source")
	}
	if request.SkipClean {
		args = append(args, "--skip-clean")
	}
	if request.DryRun {
		args = append(args, "--dry-run")
	}
	return m.Runner.Run(ctx, platform.Command{Name: "bash", Args: args, Dir: root})
}

// resolveRepositoryRoot returns an explicitly configured checkout or walks up
// from the working directory until it finds the maintained build helper.
func resolveRepositoryRoot(configured string) (string, error) {
	if configured != "" {
		absolute, err := filepath.Abs(configured)
		if err != nil {
			return "", err
		}
		return absolute, nil
	}
	current, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		candidate := filepath.Join(current, "scripts", "build-sp11-qcom-x1e-kernel-docker.sh")
		if info, statErr := os.Stat(candidate); statErr == nil && info.Mode().IsRegular() {
			return current, nil
		}
		parent := filepath.Dir(current)
		if parent == current || strings.TrimSpace(parent) == "" {
			return "", errors.New("could not find the OE repository; pass --repository-root")
		}
		current = parent
	}
}
