package capture

import (
	"context"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"
)

// captureRunnerFixture returns bounded metadata for a dry-run graph discovery.
type captureRunnerFixture struct {
	// commands records every command observed by the fake boundary.
	commands []Command
}

// fixtureExitError models one ordinary non-zero utility exit status.
type fixtureExitError int

// Error returns stable test-only process failure prose.
func (errorCode fixtureExitError) Error() string {
	return fmt.Sprintf("fixture exit %d", errorCode)
}

// ExitCode returns the injected child process status.
func (errorCode fixtureExitError) ExitCode() int {
	return int(errorCode)
}

// Capture records one query and returns its compiled fixture response.
func (runner *captureRunnerFixture) Capture(_ context.Context, command Command, _ int64) ([]byte, error) {
	runner.commands = append(runner.commands, command)
	if command.Name == "media-ctl" && len(command.Args) == 3 && command.Args[2] == "--print-topology" {
		return []byte(cameraTopologyFixture("SBGGR10_1X10")), nil
	}
	return nil, fmt.Errorf("unexpected capture command: %#v", command)
}

// Run allows only the read-only no-current-user fuser status in dry-run mode.
func (runner *captureRunnerFixture) Run(_ context.Context, command Command, _, _ io.Writer) error {
	runner.commands = append(runner.commands, command)
	if command.Name == "fuser" {
		return fixtureExitError(1)
	}
	return fmt.Errorf("dry-run unexpectedly executed %#v", command)
}

// TestManagerDryRunValidatesRouteWithoutConfiguringIt verifies the CLI's safe
// preflight boundary returns an exact plan without reserving or streaming files.
func TestManagerDryRunValidatesRouteWithoutConfiguringIt(t *testing.T) {
	t.Parallel()
	runner := &captureRunnerFixture{}
	manager := New(runner)
	manager.hostOS = "linux"
	manager.mediaDevices = func() ([]string, error) { return []string{"/dev/media0"}, nil }
	manager.runningRelease = func(context.Context) (string, error) {
		return "7.2.0-jg-0sp11v19-qcom-x1e", nil
	}
	manager.modulePresent = func(string) bool { return true }
	manager.validateDevice = func(string) error { return nil }
	manager.now = func() time.Time { return time.Unix(1, 0) }
	result, err := manager.Run(context.Background(), Options{DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if !result.DryRun || result.Frames != MinimumFrames || result.Bytes != int64(MinimumFrames*BytesPerFrame) || result.Pipeline.VideoDevice != "/dev/video12" {
		t.Fatalf("dry-run result = %#v", result)
	}
	if result.Evidence.Raw != "" || len(runner.commands) != 3 {
		t.Fatalf("dry-run produced evidence or extra commands: result=%#v commands=%#v", result, runner.commands)
	}
}

// TestValidateRunningReleaseRequiresIntegratedSurfaceABI verifies optional
// exact pinning does not weaken the minimum-generation gate.
func TestValidateRunningReleaseRequiresIntegratedSurfaceABI(t *testing.T) {
	t.Parallel()
	if err := validateRunningRelease("7.2.0-jg-0sp11v19-qcom-x1e", "7.2.0-jg-0sp11v19-qcom-x1e"); err != nil {
		t.Fatal(err)
	}
	for _, release := range []string{
		"7.2.0-generic", "7.2.0-jg-0sp11v13-qcom-x1e", "7.2.0-jg-0sp11v19-qcom-x1e\nother",
	} {
		if err := validateRunningRelease(release, ""); err == nil {
			t.Fatalf("unsupported release %q was accepted", release)
		}
	}
	if err := validateRunningRelease("7.2.0-jg-0sp11v19-qcom-x1e", "another"); err == nil || !strings.Contains(err.Error(), "expected") {
		t.Fatalf("exact release mismatch error = %v", err)
	}
}

// TestValidateCommandRejectsUnreviewedExecutables verifies topology text can
// never widen the host process allow-list.
func TestValidateCommandRejectsUnreviewedExecutables(t *testing.T) {
	t.Parallel()
	if err := validateCommand(Command{Name: "sh", Args: []string{"-c", "true"}}); err == nil {
		t.Fatal("shell command was accepted")
	}
	if err := validateCommand(Command{Name: "media-ctl", Args: []string{"--help"}}); err != nil {
		t.Fatalf("reviewed command rejected: %v", err)
	}
}
