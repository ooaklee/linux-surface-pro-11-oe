// Package build delegates userspace component builds to the repository's
// maintained, pinned build workflows.
package build

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// Component identifies a buildable userspace component.
type Component string

// Supported userspace build components map stable CLI values to maintained,
// audited helper workflows.
const (
	// ComponentIPTSD selects the maintained container workflow for the pen and
	// touchscreen daemon.
	ComponentIPTSD Component = "iptsd"
	// ComponentCamera selects the native ARM64 workflow for the IMX681 camera
	// package set.
	ComponentCamera Component = "camera"
)

// Request describes one bounded invocation of a maintained userspace build
// helper. Fields that do not apply to the selected component are rejected
// instead of being silently ignored.
type Request struct {
	// Component selects the supported userspace source build to run.
	Component Component
	// RepositoryRoot optionally identifies the checkout containing scripts; an
	// empty value searches upward from the current directory.
	RepositoryRoot string
	// OutputDirectory overrides where the IPTSD helper publishes its payload.
	OutputDirectory string
	// Image optionally overrides the pinned builder container image.
	Image string
	// WorkVolume names the case-sensitive Docker volume used by the IPTSD build.
	WorkVolume string
	// Jobs limits parallel build work; zero preserves the helper's default.
	Jobs int
	// MinimumFreeGiB sets the camera helper's host-space safety threshold.
	MinimumFreeGiB int
	// NoPull asks the camera helper to use its locally available image only.
	NoPull bool
}

// Manager validates build requests before delegating them through a command
// runner, keeping helper selection and argument policy out of the CLI layer.
type Manager struct {
	// Runner executes the single validated Bash helper invocation.
	Runner platform.Runner
}

// New returns a userspace build manager, using the host command runner when no
// test or integration runner is supplied.
func New(runner platform.Runner) *Manager {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Manager{Runner: runner}
}

// Run validates request, selects the maintained component helper, and executes
// it from the repository root. It never constructs an arbitrary script path
// from user input.
func (m *Manager) Run(ctx context.Context, request Request) error {
	if m == nil || m.Runner == nil {
		return errors.New("userspace build runner is unavailable")
	}
	if request.Jobs < 0 || request.Jobs > 64 {
		return errors.New("jobs must be between 1 and 64, or zero to use the helper default")
	}
	root, err := resolveRepositoryRoot(request.RepositoryRoot)
	if err != nil {
		return err
	}

	var script string
	var args []string
	switch request.Component {
	case ComponentIPTSD:
		script = filepath.Join(root, "scripts", "build-sp11-iptsd-docker.sh")
		args, err = iptsdArgs(request)
	case ComponentCamera:
		if runtime.GOOS != "linux" || (runtime.GOARCH != "arm64" && runtime.GOARCH != "aarch64") {
			return errors.New("the camera package builder requires a native ARM64 Linux host")
		}
		script = filepath.Join(root, "scripts", "build-sp11-imx681-libcamera-docker.sh")
		args, err = cameraArgs(request)
	default:
		return fmt.Errorf("component %q does not have a supported source build", request.Component)
	}
	if err != nil {
		return err
	}
	if err := validateHelper(script); err != nil {
		return err
	}
	args = append([]string{script}, args...)
	return m.Runner.Run(ctx, platform.Command{Name: "bash", Args: args, Dir: root})
}

// iptsdArgs translates the IPTSD-specific request fields into the helper's
// bounded flag vocabulary and rejects camera-only settings.
func iptsdArgs(request Request) ([]string, error) {
	args := make([]string, 0, 10)
	if request.OutputDirectory != "" {
		args = append(args, "--out-dir", request.OutputDirectory)
	}
	if request.Image != "" {
		args = append(args, "--image", request.Image)
	}
	if request.WorkVolume != "" {
		if !safeDockerName(request.WorkVolume) {
			return nil, errors.New("work volume must be a safe Docker volume name")
		}
		args = append(args, "--linux-work-volume", request.WorkVolume)
	}
	if request.Jobs > 0 {
		args = append(args, "--jobs", fmt.Sprintf("%d", request.Jobs))
	}
	if request.MinimumFreeGiB != 0 || request.NoPull {
		return nil, errors.New("minimum-free-gib and no-pull apply only to the camera builder")
	}
	return args, nil
}

// cameraArgs translates the camera-specific request fields into helper flags
// and rejects settings that only the IPTSD workflow understands.
func cameraArgs(request Request) ([]string, error) {
	if request.OutputDirectory != "" || request.WorkVolume != "" {
		return nil, errors.New("output-dir and work-volume apply only to the iptsd builder")
	}
	if request.MinimumFreeGiB < 0 {
		return nil, errors.New("minimum-free-gib cannot be negative")
	}
	args := make([]string, 0, 8)
	if request.Image != "" {
		args = append(args, "--image", request.Image)
	}
	if request.Jobs > 0 {
		args = append(args, "--jobs", fmt.Sprintf("%d", request.Jobs))
	}
	if request.MinimumFreeGiB > 0 {
		args = append(args, "--min-free-gb", fmt.Sprintf("%d", request.MinimumFreeGiB))
	}
	if request.NoPull {
		args = append(args, "--no-pull")
	}
	return args, nil
}

// validateHelper requires the selected build helper to be a regular file and
// rejects symbolic links before it can be passed to Bash.
func validateHelper(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("locate userspace build helper: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("userspace build helper is not a regular file: %s", path)
	}
	return nil
}

// resolveRepositoryRoot finds the checkout that owns the maintained helpers.
// An explicit root must match immediately; an implicit root is found by walking
// upward without leaving the filesystem hierarchy.
func resolveRepositoryRoot(configured string) (string, error) {
	current := configured
	if current == "" {
		var err error
		current, err = os.Getwd()
		if err != nil {
			return "", err
		}
	}
	absolute, err := filepath.Abs(current)
	if err != nil {
		return "", err
	}
	for {
		candidate := filepath.Join(absolute, "scripts", "build-sp11-iptsd-docker.sh")
		if info, statErr := os.Lstat(candidate); statErr == nil && info.Mode().IsRegular() {
			return absolute, nil
		}
		if configured != "" {
			return "", fmt.Errorf("configured repository root does not contain the maintained userspace helpers: %s", absolute)
		}
		parent := filepath.Dir(absolute)
		if parent == absolute || strings.TrimSpace(parent) == "" {
			return "", errors.New("could not find the OE repository; pass --repository-root")
		}
		absolute = parent
	}
}

// safeDockerName accepts only Docker's flat, shell-safe volume-name subset so a
// work-volume option cannot be interpreted as a flag or path.
func safeDockerName(value string) bool {
	if value == "" {
		return false
	}
	for index, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			(index > 0 && (character == '_' || character == '.' || character == '-')) {
			continue
		}
		return false
	}
	return true
}
