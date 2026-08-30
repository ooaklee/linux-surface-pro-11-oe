// Package build owns bounded userspace component build workflows.
package build

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	camerabuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/build"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
	userspaceiptsd "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/iptsd"
)

// Component identifies a buildable userspace component.
type Component string

// Supported userspace build components map stable CLI values to audited
// workflows.
const (
	// ComponentIPTSD selects the maintained container workflow for the pen and
	// touchscreen daemon.
	ComponentIPTSD Component = "iptsd"
	// ComponentCamera selects the native ARM64 workflow for the IMX681 camera
	// package set.
	ComponentCamera Component = "camera"
)

// Request describes one bounded invocation of a maintained userspace build.
// Fields that do not apply to the selected component are rejected
// instead of being silently ignored.
type Request struct {
	// Component selects the supported userspace source build to run.
	Component Component
	// RepositoryRoot optionally identifies the checkout containing source data; an
	// empty value searches upward from the current directory.
	RepositoryRoot string
	// OutputDirectory overrides the selected component's publication directory.
	OutputDirectory string
	// Image optionally overrides the pinned builder container image.
	Image string
	// WorkVolume names the case-sensitive Docker volume used by the IPTSD build.
	WorkVolume string
	// Jobs limits parallel build work; zero preserves the workflow default.
	Jobs int
	// MinimumFreeGiB sets the camera helper's host-space safety threshold.
	MinimumFreeGiB int
	// NoPull asks the camera helper to use its locally available image only.
	NoPull bool
	// DryRun returns the camera build plan without Docker or filesystem mutation.
	DryRun bool
}

// Result records component-specific native build output for delivery layers.
type Result struct {
	// Component is the exact compiled userspace workflow which ran.
	Component Component `json:"component"`
	// Camera contains the native camera plan and receipt when selected.
	Camera *camerabuild.ExecutionReceipt `json:"camera,omitempty"`
}

// cameraBuildManager is the native camera capability required by this orchestrator.
type cameraBuildManager interface {
	// Run executes or previews one authenticated native camera build.
	Run(context.Context, camerabuild.Request) (camerabuild.ExecutionReceipt, error)
}

// Manager validates build requests before crossing compiled Docker process
// boundaries, keeping workflow policy out of the CLI layer.
type Manager struct {
	// Runner executes fixed, argument-separated host commands.
	Runner platform.Runner
	// validateIPTSDIntegration is injectable for command-orchestration tests.
	validateIPTSDIntegration func(string) error
	// validateIPTSDPayload is injectable for command-orchestration tests.
	validateIPTSDPayload func(string, string) error
	// cameraBuilder owns the authenticated native camera package workflow.
	cameraBuilder cameraBuildManager
}

// New returns a userspace build manager, using the host command runner when no
// test or integration runner is supplied.
func New(runner platform.Runner) *Manager {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Manager{
		Runner:                   runner,
		validateIPTSDIntegration: userspaceiptsd.ValidateIntegration,
		validateIPTSDPayload: func(payload, integration string) error {
			_, err := userspaceiptsd.ValidatePayload(payload, integration)
			return err
		},
		cameraBuilder: camerabuild.New(runner),
	}
}

// Run validates request and executes only the selected compiled workflow.
func (m *Manager) Run(ctx context.Context, request Request) error {
	_, err := m.RunWithResult(ctx, request)
	return err
}

// RunWithResult executes one compiled workflow and returns its structured result.
func (m *Manager) RunWithResult(ctx context.Context, request Request) (Result, error) {
	if m == nil || m.Runner == nil {
		return Result{}, errors.New("userspace build runner is unavailable")
	}
	if request.Jobs < 0 || request.Jobs > 64 {
		return Result{}, errors.New("jobs must be between 1 and 64, or zero to use the workflow default")
	}
	root, err := resolveRepositoryRoot(request.RepositoryRoot, request.Component)
	if err != nil {
		return Result{}, err
	}

	switch request.Component {
	case ComponentIPTSD:
		if m.validateIPTSDIntegration == nil || m.validateIPTSDPayload == nil {
			return Result{}, errors.New("IPTSD build validators are unavailable")
		}
		if err := m.runIPTSD(ctx, root, request); err != nil {
			return Result{}, err
		}
		return Result{Component: ComponentIPTSD}, nil
	case ComponentCamera:
		if m.cameraBuilder == nil {
			return Result{}, errors.New("native camera build manager is unavailable")
		}
		if request.Image != "" || request.WorkVolume != "" {
			return Result{}, errors.New("image and work-volume apply only to the iptsd builder; the camera image is immutable compiled policy")
		}
		if request.MinimumFreeGiB < 0 {
			return Result{}, errors.New("minimum-free-gib cannot be negative")
		}
		cameraReceipt, err := m.cameraBuilder.Run(ctx, camerabuild.Request{
			RepositoryRoot:  root,
			OutputDirectory: request.OutputDirectory,
			Jobs:            request.Jobs,
			MinimumFreeGiB:  request.MinimumFreeGiB,
			NoPull:          request.NoPull,
			DryRun:          request.DryRun,
		})
		result := Result{Component: ComponentCamera, Camera: &cameraReceipt}
		if err != nil {
			return result, err
		}
		return result, nil
	default:
		return Result{}, fmt.Errorf("component %q does not have a supported source build", request.Component)
	}
}

// resolveRepositoryRoot finds the checkout that owns the maintained workflow.
// An explicit root must match immediately; an implicit root is found by walking
// upward without leaving the filesystem hierarchy.
func resolveRepositoryRoot(configured string, component Component) (string, error) {
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
		candidate := filepath.Join(absolute, "userspace", "iptsd-sp11", "SOURCE.env")
		if component == ComponentCamera {
			candidate = filepath.Join(absolute, filepath.FromSlash(camerabuild.TrackedInputPaths()[0]))
		}
		if info, statErr := os.Lstat(candidate); statErr == nil && info.Mode().IsRegular() {
			return absolute, nil
		}
		if configured != "" {
			return "", fmt.Errorf("configured repository root does not contain the maintained userspace workflow: %s", absolute)
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
