package cli

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestKernelBuildDryRunRendersNativePolicy verifies the existing command flags
// now produce a read-only native plan without requiring repository scripts.
func TestKernelBuildDryRunRendersNativePolicy(t *testing.T) {
	root := t.TempDir()
	var output bytes.Buffer
	app := &application{out: &output, errOut: &bytes.Buffer{}}
	command := app.newKernelCommand()
	command.SetArgs([]string{
		"build",
		"--repository-root", root,
		"--git-url", "https://example.invalid/owner/kernel",
		"--git-branch", "sp11/test-v19",
		"--work-dir", "private/kernel-work",
		"--output-dir", "packages/v19",
		"--jobs", "6",
		"--reset-source",
		"--skip-clean",
		"--dry-run",
	})
	if err := command.ExecuteContext(context.Background()); err != nil {
		t.Fatalf("kernel build --dry-run error = %v", err)
	}
	for _, expected := range []string{
		"kernel build dry run",
		"source: https://example.invalid/owner/kernel",
		"ref: sp11/test-v19",
		"container: docker.io/library/ubuntu@sha256:",
		"recipe SHA-256:",
		"jobs: 6",
		"reset source: true",
		"skip clean: true",
		"no changes were made",
	} {
		if !strings.Contains(output.String(), expected) {
			t.Errorf("native dry-run output does not contain %q:\n%s", expected, output.String())
		}
	}
	for _, forbidden := range []string{"build-sp11-qcom-x1e-kernel-docker.sh", "delegated", "helper"} {
		if strings.Contains(output.String(), forbidden) {
			t.Errorf("native dry-run output contains retired wording %q", forbidden)
		}
	}
	if _, err := os.Lstat(filepath.Join(root, "private")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("CLI dry-run created its work path: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(root, "packages")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("CLI dry-run created its output path: %v", err)
	}
}
