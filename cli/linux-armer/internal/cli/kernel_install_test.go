package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"

	kernelinstall "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/install"
)

const (
	// kernelCLITargetABI is the coherent bundle ABI used by delivery tests.
	kernelCLITargetABI = "7.2.0-sp11v19-qcom-x1e"
	// kernelCLIFallbackABI is the distinct retained ABI used by delivery tests.
	kernelCLIFallbackABI = "6.18.0-sp11v18-qcom-x1e"
	// kernelCLIPackageVersion is the shared Debian version encoded in fixture names.
	kernelCLIPackageVersion = "7.2.0-sp11v19"
)

// stubKernelInstallationManager records delivery requests without running
// package-manager or bootloader commands.
type stubKernelInstallationManager struct {
	// preflightPlan is returned by Preflight.
	preflightPlan kernelinstall.Plan
	// preflightErr is returned by Preflight.
	preflightErr error
	// installReceipt is returned by Install.
	installReceipt kernelinstall.Receipt
	// installErr is returned by Install.
	installErr error
	// preflightRequests records every read-only request.
	preflightRequests []kernelinstall.Request
	// installRequests records every dry-run or mutating request.
	installRequests []kernelinstall.Request
}

// Preflight records request and returns the configured plan and error.
func (stub *stubKernelInstallationManager) Preflight(_ context.Context, request kernelinstall.Request) (kernelinstall.Plan, error) {
	stub.preflightRequests = append(stub.preflightRequests, request)
	return stub.preflightPlan, stub.preflightErr
}

// Install records request and returns the configured receipt and error.
func (stub *stubKernelInstallationManager) Install(_ context.Context, request kernelinstall.Request) (kernelinstall.Receipt, error) {
	stub.installRequests = append(stub.installRequests, request)
	return stub.installReceipt, stub.installErr
}

// TestKernelPreflightCommandPassesExplicitSafetyInputs verifies all delivery
// flags reach the native manager and its plan remains machine-readable.
func TestKernelPreflightCommandPassesExplicitSafetyInputs(t *testing.T) {
	bundleDirectory := kernelCLIBundleDirectory(t)
	root := t.TempDir()
	stub := &stubKernelInstallationManager{preflightPlan: kernelCLIPlan(root, true)}
	app, output := newKernelCLIApplication(stub)

	err := executeKernelCLICommand(t, app.newKernelCommand(),
		"preflight", bundleDirectory,
		"--root", root,
		"--fallback-abi", kernelCLIFallbackABI,
		"--running-abi", kernelCLIFallbackABI,
		"--allow-unverified",
		"--json",
	)
	if err != nil {
		t.Fatalf("kernel preflight error = %v", err)
	}
	if len(stub.preflightRequests) != 1 {
		t.Fatalf("preflight request count = %d, want 1", len(stub.preflightRequests))
	}
	request := stub.preflightRequests[0]
	if request.Bundle.ABI != kernelCLITargetABI || request.Root != root ||
		request.FallbackABI != kernelCLIFallbackABI || request.RunningABI != kernelCLIFallbackABI ||
		!request.DryRun || !request.AllowUnverified {
		t.Fatalf("preflight request = %#v", request)
	}
	var plan kernelinstall.Plan
	if err := json.Unmarshal(output.Bytes(), &plan); err != nil {
		t.Fatalf("preflight JSON cannot be decoded: %v\n%s", err, output.String())
	}
	if plan.TargetABI != kernelCLITargetABI || !plan.DryRun || plan.Root != root {
		t.Fatalf("preflight JSON plan = %#v", plan)
	}
}

// TestKernelCommandsRequireExplicitRootAndFallback verifies Cobra rejects
// incomplete requests before bundle discovery or manager invocation.
func TestKernelCommandsRequireExplicitRootAndFallback(t *testing.T) {
	bundleDirectory := kernelCLIBundleDirectory(t)
	for _, subcommand := range []string{"preflight", "install"} {
		t.Run(subcommand, func(t *testing.T) {
			stub := &stubKernelInstallationManager{}
			app, _ := newKernelCLIApplication(stub)
			err := executeKernelCLICommand(t, app.newKernelCommand(), subcommand, bundleDirectory)
			if err == nil || !strings.Contains(err.Error(), "required flag") ||
				!strings.Contains(err.Error(), "fallback-abi") || !strings.Contains(err.Error(), "root") {
				t.Fatalf("missing required flags error = %v", err)
			}
			if len(stub.preflightRequests) != 0 || len(stub.installRequests) != 0 {
				t.Fatalf("manager was called for incomplete request: %#v / %#v", stub.preflightRequests, stub.installRequests)
			}
		})
	}
}

// TestKernelRunningABIOverrideIsAlternateRootOnly verifies live-root callers
// cannot replace trusted uname evidence with a flag value.
func TestKernelRunningABIOverrideIsAlternateRootOnly(t *testing.T) {
	stub := &stubKernelInstallationManager{}
	app, _ := newKernelCLIApplication(stub)
	err := executeKernelCLICommand(t, app.newKernelCommand(),
		"preflight", kernelCLIBundleDirectory(t),
		"--root", string(filepath.Separator),
		"--fallback-abi", kernelCLIFallbackABI,
		"--running-abi", kernelCLIFallbackABI,
	)
	if err == nil || !strings.Contains(err.Error(), "alternate target root") {
		t.Fatalf("live-root running ABI error = %v", err)
	}
	if len(stub.preflightRequests) != 0 {
		t.Fatalf("manager received rejected live-root override: %#v", stub.preflightRequests)
	}
}

// TestKernelInstallRequiresConfirmationBeforeManagerCall verifies a mutating
// request cannot cross the delivery boundary without --yes.
func TestKernelInstallRequiresConfirmationBeforeManagerCall(t *testing.T) {
	stub := &stubKernelInstallationManager{}
	app, _ := newKernelCLIApplication(stub)
	err := executeKernelCLICommand(t, app.newKernelCommand(),
		"install", kernelCLIBundleDirectory(t),
		"--root", t.TempDir(),
		"--fallback-abi", kernelCLIFallbackABI,
		"--running-abi", kernelCLIFallbackABI,
	)
	if err == nil || !strings.Contains(err.Error(), "requires --yes") {
		t.Fatalf("unconfirmed install error = %v", err)
	}
	if len(stub.installRequests) != 0 {
		t.Fatalf("manager received unconfirmed install: %#v", stub.installRequests)
	}
}

// TestKernelInstallDryRunNeedsNoConfirmation verifies --dry-run reaches the
// manager without --yes and returns an unmodified receipt as JSON.
func TestKernelInstallDryRunNeedsNoConfirmation(t *testing.T) {
	root := t.TempDir()
	receipt := kernelinstall.Receipt{Plan: kernelCLIPlan(root, true)}
	stub := &stubKernelInstallationManager{installReceipt: receipt}
	app, output := newKernelCLIApplication(stub)
	err := executeKernelCLICommand(t, app.newKernelCommand(),
		"install", kernelCLIBundleDirectory(t),
		"--root", root,
		"--fallback-abi", kernelCLIFallbackABI,
		"--running-abi", kernelCLIFallbackABI,
		"--allow-unverified",
		"--dry-run",
		"--json",
	)
	if err != nil {
		t.Fatalf("kernel install --dry-run error = %v", err)
	}
	if len(stub.installRequests) != 1 || !stub.installRequests[0].DryRun || !stub.installRequests[0].AllowUnverified {
		t.Fatalf("dry-run requests = %#v", stub.installRequests)
	}
	var decoded kernelinstall.Receipt
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("dry-run receipt JSON cannot be decoded: %v\n%s", err, output.String())
	}
	if !decoded.Plan.DryRun || decoded.RebootRequired || len(decoded.Executed) != 0 {
		t.Fatalf("dry-run receipt = %#v", decoded)
	}
}

// TestKernelInstallConfirmationAndFailureReceipt verifies --yes permits the
// manager call while structured rollback evidence survives an operation error.
func TestKernelInstallConfirmationAndFailureReceipt(t *testing.T) {
	root := t.TempDir()
	operationErr := errors.New("package installation failed")
	receipt := kernelinstall.Receipt{
		Plan: kernelCLIPlan(root, false),
		Rollback: &kernelinstall.RollbackReceipt{
			Attempted:    true,
			GRUBRestored: true,
		},
	}
	stub := &stubKernelInstallationManager{installReceipt: receipt, installErr: operationErr}
	app, output := newKernelCLIApplication(stub)
	err := executeKernelCLICommand(t, app.newKernelCommand(),
		"install", kernelCLIBundleDirectory(t),
		"--root", root,
		"--fallback-abi", kernelCLIFallbackABI,
		"--running-abi", kernelCLIFallbackABI,
		"--allow-unverified",
		"--yes",
		"--json",
	)
	if !errors.Is(err, operationErr) {
		t.Fatalf("confirmed install error = %v, want %v", err, operationErr)
	}
	if len(stub.installRequests) != 1 || stub.installRequests[0].DryRun {
		t.Fatalf("confirmed install requests = %#v", stub.installRequests)
	}
	var decoded kernelinstall.Receipt
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("failure receipt JSON cannot be decoded: %v\n%s", err, output.String())
	}
	if decoded.Rollback == nil || !decoded.Rollback.Attempted || !decoded.Rollback.GRUBRestored {
		t.Fatalf("failure receipt lost rollback evidence: %#v", decoded)
	}
}

// TestKernelHelpIncludesNativeCommands verifies the completed native workflows
// are discoverable from the root command without adding implicit actions.
func TestKernelHelpIncludesNativeCommands(t *testing.T) {
	var output bytes.Buffer
	command := NewRootCommand(strings.NewReader(""), &output, &bytes.Buffer{})
	command.SetArgs([]string{"kernel", "--help"})
	if err := command.ExecuteContext(context.Background()); err != nil {
		t.Fatalf("kernel --help error = %v", err)
	}
	for _, text := range []string{"preflight", "install", "--help"} {
		if !strings.Contains(output.String(), text) {
			t.Errorf("kernel help does not contain %q:\n%s", text, output.String())
		}
	}
}

// kernelCLIBundleDirectory creates the smallest coherent local package pair
// needed to exercise delivery-layer discovery without invoking dpkg.
func kernelCLIBundleDirectory(t *testing.T) string {
	t.Helper()
	directory := t.TempDir()
	packages := map[string]string{
		"linux-image-" + kernelCLITargetABI + "_" + kernelCLIPackageVersion + "_arm64.deb":   "image fixture",
		"linux-modules-" + kernelCLITargetABI + "_" + kernelCLIPackageVersion + "_arm64.deb": "modules fixture",
	}
	for name, content := range packages {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(content), 0o600); err != nil {
			t.Fatalf("write package fixture %s: %v", name, err)
		}
	}
	return directory
}

// kernelCLIPlan returns a stable plan suitable for JSON and human-output tests.
func kernelCLIPlan(root string, dryRun bool) kernelinstall.Plan {
	return kernelinstall.Plan{
		Root:               root,
		TargetABI:          kernelCLITargetABI,
		FallbackABI:        kernelCLIFallbackABI,
		RunningABI:         kernelCLIFallbackABI,
		Version:            kernelCLIPackageVersion,
		DryRun:             dryRun,
		UnverifiedAccepted: true,
		Packages: []kernelinstall.Package{
			{Name: "linux-image-" + kernelCLITargetABI + "_" + kernelCLIPackageVersion + "_arm64.deb"},
			{Name: "linux-modules-" + kernelCLITargetABI + "_" + kernelCLIPackageVersion + "_arm64.deb"},
		},
		DeviceTrees: []kernelinstall.DeviceTree{
			{Device: "surface-pro-11-x1e-oled"},
			{Device: "surface-pro-11-x1p-lcd"},
		},
		Commands: []kernelinstall.Command{{Operation: kernelinstall.OperationInstallPackages}},
	}
}

// newKernelCLIApplication constructs an isolated delivery application around
// one injected native manager and captured standard output.
func newKernelCLIApplication(installer kernelInstallationManager) (*application, *bytes.Buffer) {
	output := &bytes.Buffer{}
	return &application{out: output, errOut: &bytes.Buffer{}, kernelInstaller: installer}, output
}

// executeKernelCLICommand runs one isolated kernel command with deterministic
// context and without Cobra printing usage or diagnostics during assertions.
func executeKernelCLICommand(t *testing.T, command *cobra.Command, arguments ...string) error {
	t.Helper()
	command.SilenceUsage = true
	command.SilenceErrors = true
	command.SetArgs(arguments)
	return command.ExecuteContext(context.Background())
}
