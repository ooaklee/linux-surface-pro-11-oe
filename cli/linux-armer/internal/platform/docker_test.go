package platform

import (
	"context"
	"errors"
	"os"
	"slices"
	"strings"
	"testing"
)

// volumeRunner records Docker volume commands while allowing tests to inject
// inspect output and removal failures without contacting a daemon.
type volumeRunner struct {
	commands      []Command
	inspectResult string
	removeErr     error
}

// Run records a Docker command and returns the configured failure for volume
// removal operations.
func (r *volumeRunner) Run(_ context.Context, command Command) error {
	r.commands = append(r.commands, command)
	if len(command.Args) >= 2 && command.Args[0] == "volume" && command.Args[1] == "rm" {
		return r.removeErr
	}
	return nil
}

// Capture simulates Docker volume creation and identity inspection using either
// a valid default response or an explicitly configured result.
func (r *volumeRunner) Capture(_ context.Context, command Command) ([]byte, error) {
	r.commands = append(r.commands, command)
	if len(command.Args) < 2 || command.Args[0] != "volume" {
		return nil, errors.New("unexpected capture command")
	}
	name := command.Args[len(command.Args)-1]
	switch command.Args[1] {
	case "create":
		return []byte(name + "\n"), nil
	case "inspect":
		if r.inspectResult != "" {
			return []byte(r.inspectResult), nil
		}
		return []byte(name + " local true\n"), nil
	default:
		return nil, errors.New("unexpected Docker volume operation")
	}
}

// TestDockerWorkVolumeLifecycle verifies generated work-volume names pass their
// safety predicate and the same exact volume is removed after use.
func TestDockerWorkVolumeLifecycle(t *testing.T) {
	runner := &volumeRunner{}
	docker := NewDocker(runner)

	name, err := docker.CreateWorkVolume(context.Background())
	if err != nil {
		t.Fatalf("CreateWorkVolume() error = %v", err)
	}
	if !validWorkVolumeName(name) {
		t.Fatalf("CreateWorkVolume() returned invalid name %q", name)
	}
	if err := docker.RemoveWorkVolume(context.Background(), name); err != nil {
		t.Fatalf("RemoveWorkVolume() error = %v", err)
	}
	last := runner.commands[len(runner.commands)-1]
	if !slices.Equal(last.Args, []string{"volume", "rm", name}) {
		t.Fatalf("remove args = %q", last.Args)
	}
}

// TestCreateWorkVolumeRetainsFailedIdentity verifies a newly created volume with
// unexpected metadata is reported and retained instead of being blindly removed.
func TestCreateWorkVolumeRetainsFailedIdentity(t *testing.T) {
	runner := &volumeRunner{inspectResult: "wrong local true\n"}
	docker := NewDocker(runner)

	name, err := docker.CreateWorkVolume(context.Background())
	if err == nil || !strings.Contains(err.Error(), "retained") || !strings.Contains(err.Error(), workVolumePrefix) {
		t.Fatalf("CreateWorkVolume() = %q, %v; want identity error", name, err)
	}
	last := runner.commands[len(runner.commands)-1]
	if len(last.Args) < 2 || last.Args[0] != "volume" || last.Args[1] != "inspect" {
		t.Fatalf("identity failure performed an unexpected command: %#v", last)
	}
}

// TestRemoveWorkVolumeRejectsUnrecognisedName verifies deletion is refused before
// invoking Docker when a volume lacks the tool-owned random naming pattern.
func TestRemoveWorkVolumeRejectsUnrecognisedName(t *testing.T) {
	runner := &volumeRunner{}
	docker := NewDocker(runner)

	err := docker.RemoveWorkVolume(context.Background(), "user-data")
	if err == nil || !strings.Contains(err.Error(), "refuse") {
		t.Fatalf("RemoveWorkVolume() error = %v, want refusal", err)
	}
	if len(runner.commands) != 0 {
		t.Fatalf("runner received destructive command: %#v", runner.commands)
	}
}

// TestRemoveWorkVolumeRefusesIdentityMismatch verifies deletion cannot proceed
// when Docker inspection does not match the exact owned name, driver, and label.
func TestRemoveWorkVolumeRefusesIdentityMismatch(t *testing.T) {
	runner := &volumeRunner{inspectResult: "someone-elses-volume local false\n"}
	docker := NewDocker(runner)
	name := workVolumePrefix + "0123456789abcdef01234567"

	err := docker.RemoveWorkVolume(context.Background(), name)
	if err == nil || !strings.Contains(err.Error(), "refuse") || !strings.Contains(err.Error(), "identity mismatch") {
		t.Fatalf("RemoveWorkVolume() error = %v, want identity refusal", err)
	}
	if slices.ContainsFunc(runner.commands, func(command Command) bool {
		return len(command.Args) >= 2 && command.Args[0] == "volume" && command.Args[1] == "rm"
	}) {
		t.Fatalf("identity mismatch invoked volume rm: %#v", runner.commands)
	}
}

// TestWorkspaceVolumeArgsMountsLinuxWorkVolume verifies remaster containers use
// the named Linux volume and receive only the device-node capabilities they need.
func TestWorkspaceVolumeArgsMountsLinuxWorkVolume(t *testing.T) {
	name := workVolumePrefix + "0123456789abcdef01234567"
	arguments, err := workspaceVolumeArgs("builder:test", t.TempDir(), name)
	if err != nil {
		t.Fatalf("workspaceVolumeArgs() error = %v", err)
	}
	joined := strings.Join(arguments, "\n")
	for _, required := range []string{
		"MKNOD",
		"c *:* m",
		"b *:* m",
		name + ":/linux-work",
		"builder:test",
	} {
		if !strings.Contains(joined, required) {
			t.Errorf("Docker arguments do not contain %q: %q", required, arguments)
		}
	}
}

// TestDockerWorkVolumeIntegration optionally exercises creation, inspection, and
// exact removal against a real Docker daemon when explicitly enabled.
func TestDockerWorkVolumeIntegration(t *testing.T) {
	if os.Getenv("LINUX_ARMER_DOCKER_INTEGRATION") != "1" {
		t.Skip("set LINUX_ARMER_DOCKER_INTEGRATION=1 to exercise the Docker daemon")
	}
	docker := NewDocker(nil)
	ctx := context.Background()
	if err := docker.Check(ctx); err != nil {
		t.Fatal(err)
	}
	name, err := docker.CreateWorkVolume(ctx)
	if err != nil {
		t.Fatalf("CreateWorkVolume() error = %v", err)
	}
	removed := false
	t.Cleanup(func() {
		if !removed {
			_ = docker.RemoveWorkVolume(context.Background(), name)
		}
	})
	if err := docker.RemoveWorkVolume(ctx, name); err != nil {
		t.Fatalf("RemoveWorkVolume() error = %v", err)
	}
	removed = true
}
