package build

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// recordingRunner captures delegated platform commands without executing the
// repository build scripts they reference.
type recordingRunner struct {
	commands []platform.Command
}

// Run records a command as a successful simulated execution.
func (r *recordingRunner) Run(_ context.Context, command platform.Command) error {
	r.commands = append(r.commands, command)
	return nil
}

// Capture satisfies the platform runner contract for tests that do not require
// command output.
func (*recordingRunner) Capture(context.Context, platform.Command) ([]byte, error) {
	return nil, nil
}

// TestIPTSDDelegatesOnlySupportedFlags verifies that IPTSD builds invoke the
// audited helper with only the component's bounded command-line options.
func TestIPTSDDelegatesOnlySupportedFlags(t *testing.T) {
	root := fakeRepository(t)
	runner := &recordingRunner{}
	err := New(runner).Run(context.Background(), Request{
		Component: ComponentIPTSD, RepositoryRoot: root,
		OutputDirectory: "build/pen", Image: "ubuntu:26.04",
		WorkVolume: "linux-armer-iptsd", Jobs: 8,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(runner.commands) != 1 {
		t.Fatalf("commands = %d, want 1", len(runner.commands))
	}
	want := []string{
		filepath.Join(root, "scripts", "build-sp11-iptsd-docker.sh"),
		"--out-dir", "build/pen", "--image", "ubuntu:26.04",
		"--linux-work-volume", "linux-armer-iptsd", "--jobs", "8",
	}
	if !reflect.DeepEqual(runner.commands[0].Args, want) {
		t.Fatalf("args = %#v, want %#v", runner.commands[0].Args, want)
	}
}

// TestRejectsUnsafeDockerVolume verifies that traversal-like volume names never
// reach a delegated build helper.
func TestRejectsUnsafeDockerVolume(t *testing.T) {
	err := New(&recordingRunner{}).Run(context.Background(), Request{
		Component: ComponentIPTSD, RepositoryRoot: fakeRepository(t), WorkVolume: "../escape",
	})
	if err == nil {
		t.Fatal("expected unsafe volume name to fail")
	}
}

// TestRejectsCrossComponentFlags verifies that camera-only options cannot be
// silently passed to an IPTSD build.
func TestRejectsCrossComponentFlags(t *testing.T) {
	err := New(&recordingRunner{}).Run(context.Background(), Request{
		Component: ComponentIPTSD, RepositoryRoot: fakeRepository(t), NoPull: true,
	})
	if err == nil {
		t.Fatal("expected camera-only flag to fail")
	}
}

// TestCameraRequiresNativeARM64Linux verifies that the camera builder refuses a
// host that cannot produce its architecture-specific native packages.
func TestCameraRequiresNativeARM64Linux(t *testing.T) {
	if runtime.GOOS == "linux" && (runtime.GOARCH == "arm64" || runtime.GOARCH == "aarch64") {
		t.Skip("host satisfies the native camera builder constraint")
	}
	err := New(&recordingRunner{}).Run(context.Background(), Request{
		Component: ComponentCamera, RepositoryRoot: fakeRepository(t),
	})
	if err == nil {
		t.Fatal("expected native ARM64 Linux constraint to fail")
	}
}

// TestRejectsSymlinkedHelper verifies that build delegation cannot be redirected
// through a symlink in place of the expected repository script.
func TestRejectsSymlinkedHelper(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "target")
	if err := os.WriteFile(target, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, "scripts", "build-sp11-iptsd-docker.sh")); err != nil {
		t.Fatal(err)
	}
	err := New(&recordingRunner{}).Run(context.Background(), Request{
		Component: ComponentIPTSD, RepositoryRoot: root,
	})
	if err == nil {
		t.Fatal("expected symlinked helper to fail")
	}
}

// fakeRepository creates regular executable helper files in an isolated tree so
// build validation can run without the real repository scripts.
func fakeRepository(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	scripts := filepath.Join(root, "scripts")
	if err := os.MkdirAll(scripts, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"build-sp11-iptsd-docker.sh", "build-sp11-imx681-libcamera-docker.sh"} {
		if err := os.WriteFile(filepath.Join(scripts, name), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root
}
