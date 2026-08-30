package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/hardwaredoctor"
)

// hardwareDoctorStub returns a deterministic report while recording the
// delivery options supplied by the command.
type hardwareDoctorStub struct {
	// report is the typed, already-redacted result returned to the command.
	report hardwaredoctor.Report
	// err is an optional inspection failure returned before report delivery.
	err error
	// options records the most recent feature selection.
	options hardwaredoctor.Options
	// called records whether inspection was requested.
	called bool
}

// Inspect records the command options and returns the configured result.
func (stub *hardwareDoctorStub) Inspect(ctx context.Context, options hardwaredoctor.Options) (hardwaredoctor.Report, error) {
	if err := ctx.Err(); err != nil {
		return hardwaredoctor.Report{}, err
	}
	stub.called = true
	stub.options = options
	return stub.report, stub.err
}

// hardwareDoctorFactoryRecorder records root selection without opening the
// host filesystem or starting diagnostic processes.
type hardwareDoctorFactoryRecorder struct {
	// workflow is returned for each successful construction.
	workflow hardwareDoctorWorkflow
	// err is an optional construction failure.
	err error
	// root records the most recent requested runtime root.
	root string
	// calls records how many times construction was attempted.
	calls int
}

// New records root and returns the configured workflow or error.
func (factory *hardwareDoctorFactoryRecorder) New(root string) (hardwareDoctorWorkflow, error) {
	factory.calls++
	factory.root = root
	return factory.workflow, factory.err
}

// readyHardwareReport creates a safe fixture covering each evidence class and
// every supported feature without claiming physical qualification.
func readyHardwareReport() hardwaredoctor.Report {
	return hardwaredoctor.Report{
		Ready:             true,
		HardwareQualified: false,
		Features: []hardwaredoctor.Feature{
			hardwaredoctor.FeatureWiFi,
			hardwaredoctor.FeatureBluetooth,
			hardwaredoctor.FeatureAudio,
			hardwaredoctor.FeatureTouchscreen,
		},
		Checks: []hardwaredoctor.Check{
			{
				ID:       "platform-surface-pro-11",
				Evidence: hardwaredoctor.EvidenceStatic,
				State:    hardwaredoctor.StatePass,
				Required: true,
				Detail:   "the loaded device tree identifies the supported platform",
			},
			{
				ID:       "wifi-radio-block",
				Feature:  hardwaredoctor.FeatureWiFi,
				Evidence: hardwaredoctor.EvidenceRuntime,
				State:    hardwaredoctor.StatePass,
				Required: true,
				Detail:   "the wireless radio is not blocked",
			},
			{
				ID:          "bluetooth-service",
				Feature:     hardwaredoctor.FeatureBluetooth,
				Evidence:    hardwaredoctor.EvidenceRuntime,
				State:       hardwaredoctor.StateWarn,
				Detail:      "the service state needs review",
				Remediation: "inspect the service on the target system",
			},
			{
				ID:       "audio-physical-playback",
				Feature:  hardwaredoctor.FeatureAudio,
				Evidence: hardwaredoctor.EvidenceHardwareTest,
				State:    hardwaredoctor.StateNotProven,
				Detail:   "physical playback remains a manual test",
			},
			{
				ID:       "touchscreen-input-device",
				Feature:  hardwaredoctor.FeatureTouchscreen,
				Evidence: hardwaredoctor.EvidenceRuntime,
				State:    hardwaredoctor.StatePass,
				Required: true,
				Detail:   "the expected input device is registered",
			},
		},
	}
}

// failingHardwareReport creates a safe fixture with one required runtime
// failure and an explicit unproven physical test.
func failingHardwareReport() hardwaredoctor.Report {
	return hardwaredoctor.Report{
		Ready:             false,
		HardwareQualified: false,
		Features:          []hardwaredoctor.Feature{hardwaredoctor.FeatureWiFi},
		Checks: []hardwaredoctor.Check{
			{
				ID:          "wifi-radio-block",
				Feature:     hardwaredoctor.FeatureWiFi,
				Evidence:    hardwaredoctor.EvidenceRuntime,
				State:       hardwaredoctor.StateFail,
				Required:    true,
				Detail:      "the wireless radio is hard blocked",
				Remediation: "complete a cold boot before rerunning the diagnostic",
			},
			{
				ID:       "wifi-association-test",
				Feature:  hardwaredoctor.FeatureWiFi,
				Evidence: hardwaredoctor.EvidenceHardwareTest,
				State:    hardwaredoctor.StateNotProven,
				Detail:   "network association remains a manual test",
			},
		},
	}
}

// executeHardwareDoctorCommand runs the isolated child beneath a silent root
// and returns its separately captured standard streams.
func executeHardwareDoctorCommand(t *testing.T, factory hardwareDoctorFactory, args ...string) (string, string, error) {
	t.Helper()
	var output bytes.Buffer
	var errorOutput bytes.Buffer
	app := &application{in: strings.NewReader(""), out: &output, errOut: &errorOutput}
	root := &cobra.Command{
		Use:           "test",
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	root.SetIn(app.in)
	root.SetOut(app.out)
	root.SetErr(app.errOut)
	root.AddCommand(app.newHardwareDoctorCommand(factory))
	root.SetArgs(append([]string{"hardware"}, args...))
	err := root.ExecuteContext(context.Background())
	return output.String(), errorOutput.String(), err
}

// writeAlternateHardwareFile creates one regular fixture file below a
// temporary alternate Linux runtime root.
func writeAlternateHardwareFile(t *testing.T, root, logicalPath, content string) {
	t.Helper()
	target := filepath.Join(root, filepath.FromSlash(strings.TrimPrefix(logicalPath, "/")))
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestHardwareDoctorHumanCombinedDelivery verifies the empty selector uses the
// domain's combined default and labels static, runtime, and unproven evidence.
func TestHardwareDoctorHumanCombinedDelivery(t *testing.T) {
	stub := &hardwareDoctorStub{report: readyHardwareReport()}
	factory := &hardwareDoctorFactoryRecorder{workflow: stub}
	output, errorOutput, err := executeHardwareDoctorCommand(t, factory.New)
	if err != nil {
		t.Fatalf("hardware doctor error = %v", err)
	}
	if errorOutput != "" {
		t.Fatalf("stderr = %q, want empty", errorOutput)
	}
	if factory.calls != 1 || factory.root != "/" {
		t.Fatalf("factory calls = %d, root = %q", factory.calls, factory.root)
	}
	if !stub.called || len(stub.options.Features) != 0 {
		t.Fatalf("combined options = %#v, want empty feature selection", stub.options)
	}
	for _, expected := range []string{
		"STATE", "EVIDENCE", "FEATURE", "REQUIRED", "CHECK", "DETAIL",
		"static-evidence", "runtime-state", "hardware-test", "platform",
		"not-proven", "observed readiness:", "ready",
		"hardware qualification:", "not proven by this read-only command",
	} {
		if !strings.Contains(output, expected) {
			t.Errorf("human report does not contain %q:\n%s", expected, output)
		}
	}
}

// TestHardwareDoctorJSONFailureRemainsMachineReadable verifies required
// failures return non-zero only after emitting one complete JSON document.
func TestHardwareDoctorJSONFailureRemainsMachineReadable(t *testing.T) {
	stub := &hardwareDoctorStub{report: failingHardwareReport()}
	factory := &hardwareDoctorFactoryRecorder{workflow: stub}
	alternateRoot := t.TempDir()
	output, errorOutput, err := executeHardwareDoctorCommand(
		t, factory.New, "wifi", "bluetooth", "--root", alternateRoot, "--json",
	)
	if err == nil || !strings.Contains(err.Error(), "required live hardware checks failed") {
		t.Fatalf("error = %v, want required-check failure", err)
	}
	if errorOutput != "" {
		t.Fatalf("stderr = %q, want empty", errorOutput)
	}
	if factory.calls != 1 || factory.root != alternateRoot {
		t.Fatalf("factory calls = %d, root = %q, want %q", factory.calls, factory.root, alternateRoot)
	}
	wantFeatures := []hardwaredoctor.Feature{hardwaredoctor.FeatureWiFi, hardwaredoctor.FeatureBluetooth}
	if !reflect.DeepEqual(stub.options.Features, wantFeatures) {
		t.Fatalf("selected features = %#v, want %#v", stub.options.Features, wantFeatures)
	}
	var report hardwaredoctor.Report
	if decodeErr := json.Unmarshal([]byte(output), &report); decodeErr != nil {
		t.Fatalf("JSON report cannot be decoded: %v\n%s", decodeErr, output)
	}
	if report.Ready || len(report.Checks) != 2 {
		t.Fatalf("decoded report = %#v", report)
	}
	if strings.Contains(output, "required live hardware checks failed") {
		t.Fatalf("JSON stdout was corrupted by the command error:\n%s", output)
	}
}

// TestHardwareDoctorHumanFailureWritesCompleteReport verifies human delivery
// remains actionable before the command returns its readiness error.
func TestHardwareDoctorHumanFailureWritesCompleteReport(t *testing.T) {
	stub := &hardwareDoctorStub{report: failingHardwareReport()}
	factory := &hardwareDoctorFactoryRecorder{workflow: stub}
	output, errorOutput, err := executeHardwareDoctorCommand(t, factory.New, "wifi")
	if err == nil {
		t.Fatal("hardware doctor unexpectedly accepted a required failure")
	}
	if errorOutput != "" {
		t.Fatalf("stderr = %q, want empty", errorOutput)
	}
	for _, expected := range []string{
		"fail", "runtime-state", "wifi-radio-block", "remediation",
		"not ready", "hardware qualification:", "not proven",
	} {
		if !strings.Contains(output, expected) {
			t.Errorf("failing human report does not contain %q:\n%s", expected, output)
		}
	}
}

// TestHardwareDoctorTouchscreenSelection verifies the dedicated selector is
// delivered without implicitly selecting unrelated hardware features.
func TestHardwareDoctorTouchscreenSelection(t *testing.T) {
	report := readyHardwareReport()
	report.Features = []hardwaredoctor.Feature{hardwaredoctor.FeatureTouchscreen}
	report.Checks = []hardwaredoctor.Check{
		{
			ID:       "touchscreen-input-device",
			Feature:  hardwaredoctor.FeatureTouchscreen,
			Evidence: hardwaredoctor.EvidenceRuntime,
			State:    hardwaredoctor.StatePass,
			Required: true,
			Detail:   "the expected input device is registered",
		},
	}
	stub := &hardwareDoctorStub{report: report}
	factory := &hardwareDoctorFactoryRecorder{workflow: stub}
	output, errorOutput, err := executeHardwareDoctorCommand(t, factory.New, "touchscreen")
	if err != nil {
		t.Fatalf("touchscreen doctor error = %v", err)
	}
	if errorOutput != "" {
		t.Fatalf("stderr = %q, want empty", errorOutput)
	}
	if want := []hardwaredoctor.Feature{hardwaredoctor.FeatureTouchscreen}; !reflect.DeepEqual(stub.options.Features, want) {
		t.Fatalf("selected features = %#v, want %#v", stub.options.Features, want)
	}
	if !strings.Contains(output, "touchscreen-input-device") || strings.Contains(output, "wifi-radio-block") {
		t.Fatalf("touchscreen-only output is incorrect:\n%s", output)
	}
}

// TestHardwareDoctorHelpAdvertisesTouchscreen verifies discovery and shell
// completion expose the maintained touchscreen selector.
func TestHardwareDoctorHelpAdvertisesTouchscreen(t *testing.T) {
	command := (&application{out: &bytes.Buffer{}}).newHardwareDoctorCommand(nil)
	if !strings.Contains(command.Use, "touchscreen") {
		t.Fatalf("hardware command use = %q", command.Use)
	}
	if !reflect.DeepEqual(command.ValidArgs, []string{"wifi", "bluetooth", "audio", "touchscreen"}) {
		t.Fatalf("hardware command valid arguments = %#v", command.ValidArgs)
	}
}

// TestHardwareDoctorRejectsUnknownFeatureBeforeConstruction verifies invalid
// positional selectors never open files or start probes.
func TestHardwareDoctorRejectsUnknownFeatureBeforeConstruction(t *testing.T) {
	stub := &hardwareDoctorStub{report: readyHardwareReport()}
	factory := &hardwareDoctorFactoryRecorder{workflow: stub}
	output, errorOutput, err := executeHardwareDoctorCommand(t, factory.New, "camera")
	if err == nil || !strings.Contains(err.Error(), "wifi, bluetooth, audio, touchscreen") {
		t.Fatalf("error = %v, want closed feature vocabulary", err)
	}
	if factory.calls != 0 || stub.called {
		t.Fatalf("invalid selector reached workflow: factory calls = %d, inspected = %t", factory.calls, stub.called)
	}
	if output != "" || errorOutput != "" {
		t.Fatalf("unexpected output for invalid selector: stdout=%q stderr=%q", output, errorOutput)
	}
}

// TestHardwareDoctorInspectionErrorProducesNoJSON verifies an incomplete
// inspection never emits a partial machine-readable document.
func TestHardwareDoctorInspectionErrorProducesNoJSON(t *testing.T) {
	stub := &hardwareDoctorStub{err: errors.New("inspection unavailable")}
	factory := &hardwareDoctorFactoryRecorder{workflow: stub}
	output, errorOutput, err := executeHardwareDoctorCommand(t, factory.New, "audio", "--json")
	if err == nil || !strings.Contains(err.Error(), "inspection unavailable") {
		t.Fatalf("error = %v, want inspection failure", err)
	}
	if output != "" || errorOutput != "" {
		t.Fatalf("failed inspection emitted output: stdout=%q stderr=%q", output, errorOutput)
	}
}

// TestDoctorCommandPreservesNestedCommands verifies the hardware addition does
// not replace the established userspace doctor alias.
func TestDoctorCommandPreservesNestedCommands(t *testing.T) {
	app := &application{out: &bytes.Buffer{}}
	command := app.newDoctorCommand()
	seen := make(map[string]bool)
	for _, child := range command.Commands() {
		seen[child.Name()] = true
	}
	if !seen["userspace"] || !seen["hardware"] {
		t.Fatalf("doctor subcommands = %#v, want userspace and hardware", seen)
	}
}

// TestAlternateRootProbeRunnerNeverQueriesHost verifies process-derived state
// is unavailable for an offline procfs or sysfs snapshot and honours cancellation.
func TestAlternateRootProbeRunnerNeverQueriesHost(t *testing.T) {
	runner := alternateRootProbeRunner{}
	for _, probe := range []hardwaredoctor.Probe{
		hardwaredoctor.ProbeAudioSession,
		hardwaredoctor.ProbeKernelLogDmesg,
		hardwaredoctor.ProbeKernelLogJournal,
	} {
		if _, err := runner.Run(context.Background(), probe, 1024); err == nil || !strings.Contains(err.Error(), "alternate root") {
			t.Fatalf("alternate-root probe %q error = %v", probe, err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := runner.Run(ctx, hardwaredoctor.ProbeAudioSession, 1024); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled alternate-root probe error = %v", err)
	}
}

// TestAlternateRootTouchscreenInspectionDoesNotStartHostProbes verifies the
// factory couples an offline filesystem snapshot only to the rejecting runner.
func TestAlternateRootTouchscreenInspectionDoesNotStartHostProbes(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fixed fake executable uses a POSIX test script")
	}
	root := t.TempDir()
	writeAlternateHardwareFile(t, root, "/proc/device-tree/model", "Microsoft Surface Pro 11th Edition (OLED)\x00")
	writeAlternateHardwareFile(t, root, "/proc/device-tree/compatible", "microsoft,denali\x00qcom,x1e80100\x00")
	writeAlternateHardwareFile(t, root, "/proc/sys/kernel/osrelease", "7.2.0-jg-0sp11v19-qcom-x1e\n")
	writeAlternateHardwareFile(t, root, "/lib/firmware/qcom/x1e80100/qupv3fw.elf.zst", "bounded firmware fixture")
	writeAlternateHardwareFile(t, root, "/sys/firmware/devicetree/base/soc@0/geniqup@ac0000/spi@a88000/status", "okay\x00")
	writeAlternateHardwareFile(t, root, "/sys/firmware/devicetree/base/soc@0/geniqup@ac0000/spi@a88000/touchscreen@0/compatible", "microsoft,mshw0485\x00")
	writeAlternateHardwareFile(t, root, "/sys/bus/spi/devices/spi10.0/modalias", "of:NtouchscreenT(null)Cmicrosoft,mshw0485\n")
	writeAlternateHardwareFile(t, root, "/proc/bus/input/devices", "N: Name=\"Microsoft Surface G6 Touch\"\n")
	bin := t.TempDir()
	marker := filepath.Join(t.TempDir(), "host-probe-ran")
	probeScript := "#!/bin/sh\nprintf invoked > \"$TOUCH_PROBE_MARKER\"\n"
	for _, name := range []string{"dmesg", "journalctl"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(probeScript), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
	t.Setenv("TOUCH_PROBE_MARKER", marker)
	workflow, err := newHardwareDoctorWorkflow(root)
	if err != nil {
		t.Fatal(err)
	}
	report, err := workflow.Inspect(context.Background(), hardwaredoctor.Options{Features: []hardwaredoctor.Feature{hardwaredoctor.FeatureTouchscreen}})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Ready {
		t.Fatalf("alternate-root touchscreen report = %#v", report)
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("alternate-root inspection started a current-host probe: %v", err)
	}
	var kernelCheck *hardwaredoctor.Check
	for index := range report.Checks {
		if report.Checks[index].ID == "touchscreen-kernel-runtime" {
			kernelCheck = &report.Checks[index]
			break
		}
	}
	if kernelCheck == nil || kernelCheck.State != hardwaredoctor.StateUnavailable || kernelCheck.Required {
		t.Fatalf("alternate-root kernel-log check = %#v", kernelCheck)
	}
}

// TestIsLiveHardwareRoot distinguishes the running system root from an offline
// snapshot without relying on lexical path comparison alone.
func TestIsLiveHardwareRoot(t *testing.T) {
	if !isLiveHardwareRoot("") || !isLiveHardwareRoot("/") {
		t.Fatal("the system root was not recognised as live")
	}
	if isLiveHardwareRoot(t.TempDir()) {
		t.Fatal("an alternate diagnostic root was classified as live")
	}
}
