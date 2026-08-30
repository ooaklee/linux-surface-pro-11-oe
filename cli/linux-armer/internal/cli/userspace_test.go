package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	linuxarmer "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer"
	userspacecatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspaceinstall "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/install"
	userspacemanager "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/manager"
)

// cliFakeInstaller records install options while returning deterministic results
// so command tests can exercise orchestration without changing the host system.
type cliFakeInstaller struct {
	calls []userspaceinstall.Options
}

// Audio records a simulated audio installation that requires a reboot.
func (f *cliFakeInstaller) Audio(_ context.Context, options userspaceinstall.Options) (userspaceinstall.Result, error) {
	return f.record(userspacemanager.AudioComponent, options, true), nil
}

// IPTSD records a simulated touchscreen userspace installation.
func (f *cliFakeInstaller) IPTSD(_ context.Context, options userspaceinstall.Options) (userspaceinstall.Result, error) {
	return f.record(userspacemanager.IPTSDComponent, options, false), nil
}

// Camera records a simulated camera userspace installation.
func (f *cliFakeInstaller) Camera(_ context.Context, options userspaceinstall.Options) (userspaceinstall.Result, error) {
	return f.record(userspacemanager.CameraComponent, options, false), nil
}

// record appends one simulated invocation and constructs its command-facing result.
func (f *cliFakeInstaller) record(component string, options userspaceinstall.Options, reboot bool) userspaceinstall.Result {
	f.calls = append(f.calls, options)
	return userspaceinstall.Result{
		Component: component, Root: options.Root, DryRun: options.DryRun,
		RebootRequired: reboot,
	}
}

// TestUserspaceInstallRequiresConfirmationBeforeMutation verifies that a real
// userspace install is rejected before the installer runs unless --yes is set.
func TestUserspaceInstallRequiresConfirmationBeforeMutation(t *testing.T) {
	installer := &cliFakeInstaller{}
	app, _ := newUserspaceInstallTestApplication(installer)
	command := app.newUserspaceInstallCommand()
	command.SetArgs([]string{"audio", "--from", t.TempDir()})
	command.SilenceUsage = true
	command.SilenceErrors = true

	err := command.ExecuteContext(context.Background())
	if err == nil || !strings.Contains(err.Error(), "pass --yes") {
		t.Fatalf("error = %v, want explicit confirmation guidance", err)
	}
	if len(installer.calls) != 0 {
		t.Fatalf("installer was called before confirmation: %#v", installer.calls)
	}
}

// TestUserspaceInstallRecommendedDryRunEmitsStructuredReport verifies that the
// recommended dry run plans audio and IPTSD and emits actionable JSON guidance.
func TestUserspaceInstallRecommendedDryRunEmitsStructuredReport(t *testing.T) {
	installer := &cliFakeInstaller{}
	app, output := newUserspaceInstallTestApplication(installer)
	command := app.newUserspaceInstallCommand()
	command.SetArgs([]string{"recommended", "--from", t.TempDir(), "--dry-run", "--json"})
	command.SilenceUsage = true
	command.SilenceErrors = true

	if err := command.ExecuteContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	var report userspaceInstallReport
	if err := json.Unmarshal(output.Bytes(), &report); err != nil {
		t.Fatalf("decode install report: %v\n%s", err, output.String())
	}
	if len(report.Results) != 2 || report.Results[0].Component != userspacemanager.AudioComponent || report.Results[1].Component != userspacemanager.IPTSDComponent {
		t.Fatalf("results = %#v", report.Results)
	}
	if len(installer.calls) != 2 || !installer.calls[0].DryRun || !installer.calls[1].DryRun {
		t.Fatalf("dry-run calls = %#v", installer.calls)
	}
	if len(report.NextSteps) != 1 || !strings.Contains(report.NextSteps[0], "--yes") {
		t.Fatalf("next steps = %#v", report.NextSteps)
	}
}

// TestUserspaceInstallHumanReportIncludesRebootAndDoctorGuidance verifies that
// interactive output explains changed files, reboot needs, and follow-up checks.
func TestUserspaceInstallHumanReportIncludesRebootAndDoctorGuidance(t *testing.T) {
	var output bytes.Buffer
	app := &application{out: &output}
	report := makeUserspaceInstallReport([]userspaceinstall.Result{{
		Component:      userspacemanager.AudioComponent,
		Root:           "/",
		Files:          []userspaceinstall.FileChange{{Source: "bundle", Target: "target"}},
		RebootRequired: true,
	}}, false)
	if err := app.writeUserspaceInstallReport(report); err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"installed audio-fullio-v19c", "file changes: 1", "Reboot", "doctor userspace"} {
		if !strings.Contains(output.String(), expected) {
			t.Errorf("human report does not contain %q:\n%s", expected, output.String())
		}
	}
}

// newUserspaceInstallTestApplication builds a command application around a
// supplied fake installer and returns its captured output buffer.
func newUserspaceInstallTestApplication(installer userspacemanager.Installer) (*application, *bytes.Buffer) {
	loader := userspacecatalog.NewLoader(linuxarmer.UserspaceCatalogFS(), "supported-userspace.json")
	userspace := userspacemanager.New(loader, nil, nil)
	userspace.Installer = installer
	output := &bytes.Buffer{}
	return &application{out: output, userspace: userspace}, output
}
