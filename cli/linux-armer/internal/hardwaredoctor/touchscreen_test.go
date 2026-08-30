package hardwaredoctor

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

// TestInspectTouchscreenHealthyInTreeEvidence verifies every maintained
// touchscreen layer while excluding the retired override-module contract.
func TestInspectTouchscreenHealthyInTreeEvidence(t *testing.T) {
	runner := healthyTestRunner()
	doctor, err := New(healthyTestFileSystem(), runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureTouchscreen}})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Ready || !reflect.DeepEqual(report.Features, []Feature{FeatureTouchscreen}) {
		t.Fatalf("touchscreen report = %#v", report)
	}
	for _, id := range []string{
		"touchscreen-qup-firmware",
		"touchscreen-device-tree-controller",
		"touchscreen-device-tree-client",
		"touchscreen-spi-client",
		"touchscreen-input-device",
		"touchscreen-kernel-runtime",
	} {
		if check := findCheck(t, report, id); check.State != StatePass {
			t.Errorf("%s = %#v", id, check)
		}
	}
	limitation := findCheck(t, report, "touchscreen-hardware-test")
	if limitation.State != StateNotProven || limitation.Required {
		t.Fatalf("touchscreen hardware limitation = %#v", limitation)
	}
	runner.mu.Lock()
	calls := append([]Probe(nil), runner.calls...)
	runner.mu.Unlock()
	if want := []Probe{ProbeKernelLogDmesg}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("touchscreen probe calls = %#v, want %#v", calls, want)
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	for _, retiredCriterion := range []string{"updates/", "vermagic", "srcversion", "sp11_windows_se_init", "initramfs"} {
		if strings.Contains(string(encoded), retiredCriterion) {
			t.Errorf("touchscreen report retained obsolete criterion %q: %s", retiredCriterion, encoded)
		}
	}
}

// TestTouchscreenStaticAndRuntimeFailuresStayTyped verifies missing, malformed,
// and oversized evidence cannot become a false pass.
func TestTouchscreenStaticAndRuntimeFailuresStayTyped(t *testing.T) {
	tests := []struct {
		// name identifies the evidence mutation.
		name string
		// mutate changes one otherwise healthy fixture.
		mutate func(*testFileSystem)
		// checkID identifies the expected conclusion.
		checkID string
		// wantState is the expected normalised state.
		wantState State
	}{
		{
			name: "firmware absent",
			mutate: func(filesystem *testFileSystem) {
				delete(filesystem.stats, "/lib/firmware/qcom/x1e80100/qupv3fw.elf.zst")
			},
			checkID:   "touchscreen-qup-firmware",
			wantState: StateFail,
		},
		{
			name: "controller disabled",
			mutate: func(filesystem *testFileSystem) {
				filesystem.files["/sys/firmware/devicetree/base/soc@0/geniqup@ac0000/spi@a88000/status"] = []byte("disabled\x00")
			},
			checkID:   "touchscreen-device-tree-controller",
			wantState: StateFail,
		},
		{
			name: "compatible substring rejected",
			mutate: func(filesystem *testFileSystem) {
				filesystem.files["/sys/firmware/devicetree/base/soc@0/geniqup@ac0000/spi@a88000/touchscreen@0/compatible"] = []byte("microsoft,mshw04850\x00")
			},
			checkID:   "touchscreen-device-tree-client",
			wantState: StateFail,
		},
		{
			name: "SPI client absent",
			mutate: func(filesystem *testFileSystem) {
				delete(filesystem.files, "/sys/bus/spi/devices/spi10.0/modalias")
			},
			checkID:   "touchscreen-spi-client",
			wantState: StateFail,
		},
		{
			name: "SPI identity substring rejected",
			mutate: func(filesystem *testFileSystem) {
				filesystem.files["/sys/bus/spi/devices/spi10.0/modalias"] = []byte("of:NtouchscreenT(null)Cmicrosoft,mshw04850\n")
			},
			checkID:   "touchscreen-spi-client",
			wantState: StateFail,
		},
		{
			name: "unsafe SPI entry is unavailable",
			mutate: func(filesystem *testFileSystem) {
				filesystem.directories["/sys/bus/spi/devices"] = []PathInfo{{Name: "../private-device", Kind: PathSymlink}}
			},
			checkID:   "touchscreen-spi-client",
			wantState: StateUnavailable,
		},
		{
			name: "input device absent",
			mutate: func(filesystem *testFileSystem) {
				filesystem.files["/proc/bus/input/devices"] = []byte("N: Name=\"Unrelated Device\"\n")
			},
			checkID:   "touchscreen-input-device",
			wantState: StateFail,
		},
		{
			name: "input inventory oversized",
			mutate: func(filesystem *testFileSystem) {
				filesystem.files["/proc/bus/input/devices"] = []byte(strings.Repeat("private input record\n", int(maximumInputDevicesBytes)))
			},
			checkID:   "touchscreen-input-device",
			wantState: StateUnavailable,
		},
		{
			name: "device tree breadth oversized",
			mutate: func(filesystem *testFileSystem) {
				entries := make([]PathInfo, maximumDeviceTreeChildren+1)
				for index := range entries {
					entries[index] = PathInfo{Name: "node" + strings.Repeat("x", index%8), Kind: PathDirectory}
				}
				filesystem.directories["/sys/firmware/devicetree/base"] = entries
			},
			checkID:   "touchscreen-device-tree-controller",
			wantState: StateUnavailable,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			filesystem := healthyTestFileSystem()
			test.mutate(filesystem)
			doctor, err := New(filesystem, healthyTestRunner())
			if err != nil {
				t.Fatal(err)
			}
			report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureTouchscreen}})
			if err != nil {
				t.Fatal(err)
			}
			check := findCheck(t, report, test.checkID)
			if check.State != test.wantState || !check.Required || report.Ready {
				t.Fatalf("check = %#v; ready = %t", check, report.Ready)
			}
		})
	}
}

// TestTouchscreenSPIIdentityUsesClosedVocabulary verifies expected kernel
// modalias forms while rejecting embedded and suffixed lookalikes.
func TestTouchscreenSPIIdentityUsesClosedVocabulary(t *testing.T) {
	tests := []struct {
		// value is one private modalias or uevent body.
		value string
		// want records whether it identifies the supported client.
		want bool
	}{
		{value: "MODALIAS=of:NtouchscreenT(null)Cmicrosoft,mshw0485\n", want: true},
		{value: "spi:mshw0485\n", want: true},
		{value: "MODALIAS=acpi:MSHW0485:\n", want: true},
		{value: "of:NtouchscreenT(null)Cnotmicrosoft,mshw0485\n", want: false},
		{value: "of:NtouchscreenT(null)Cmicrosoft,mshw04850\n", want: false},
	}
	for _, test := range tests {
		if got := containsTouchscreenSPIIdentity([]byte(test.value)); got != test.want {
			t.Errorf("containsTouchscreenSPIIdentity(%q) = %t, want %t", test.value, got, test.want)
		}
	}
}

// TestTouchscreenKernelLogClassification verifies fixed success, failure, and
// inconclusive markers without exposing arbitrary log text.
func TestTouchscreenKernelLogClassification(t *testing.T) {
	tests := []struct {
		// name identifies the current-boot marker case.
		name string
		// log is the private bounded kernel-log content.
		log string
		// wantState is the expected redacted conclusion.
		wantState State
		// wantRequired records whether the conclusion affects readiness.
		wantRequired bool
	}{
		{name: "protocol rejected", log: "geni_spi a88000.spi: Invalid proto 9\n", wantState: StateFail, wantRequired: true},
		{name: "dependency blocked", log: "sync_state() pending due to a88000.spi\n", wantState: StateFail, wantRequired: true},
		{name: "firmware failed", log: "a88000.spi: spi master firmware load failed ret: -2\n", wantState: StateFail, wantRequired: true},
		{name: "latest initialisation failed", log: "touch controller initialized path=hardware\ntouch controller initialization failed path=software\n", wantState: StateFail, wantRequired: true},
		{name: "latest initialisation succeeded", log: "touch controller initialization failed path=hardware\ntouch controller initialized path=hardware\n", wantState: StatePass, wantRequired: true},
		{name: "recovered after timeout", log: "CH START completion timeout\ntouch controller initialized path=hardware\n", wantState: StateWarn, wantRequired: false},
		{name: "unattributed timeout", log: "CH START completion timeout\n", wantState: StateWarn, wantRequired: false},
		{name: "input registration only", log: "Microsoft Surface G6 Touch\n", wantState: StateWarn, wantRequired: false},
		{name: "no marker", log: "private serial SECRET-KERNEL-VALUE\n", wantState: StateWarn, wantRequired: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			check := classifyTouchscreenKernelLog([]byte(test.log))
			if check.State != test.wantState || check.Required != test.wantRequired {
				t.Fatalf("classification = %#v", check)
			}
			encoded, err := json.Marshal(check)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(encoded), "SECRET-KERNEL-VALUE") {
				t.Fatalf("classification exposed private kernel text: %s", encoded)
			}
		})
	}
}

// TestTouchscreenKernelLogFallsBackWithinBounds verifies a failed dmesg read
// uses the fixed journal probe and never requires custom success markers.
func TestTouchscreenKernelLogFallsBackWithinBounds(t *testing.T) {
	runner := healthyTestRunner()
	runner.responses[ProbeKernelLogDmesg] = testProbeResponse{result: ProbeResult{ExitCode: 1}}
	runner.responses[ProbeKernelLogJournal] = testProbeResponse{result: ProbeResult{ExitCode: 0, Output: []byte("touch controller initialized path=software\n")}}
	doctor, err := New(healthyTestFileSystem(), runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureTouchscreen}})
	if err != nil {
		t.Fatal(err)
	}
	if check := findCheck(t, report, "touchscreen-kernel-runtime"); check.State != StatePass {
		t.Fatalf("fallback kernel-log check = %#v", check)
	}
	runner.mu.Lock()
	calls := append([]Probe(nil), runner.calls...)
	deadlines := append([]bool(nil), runner.deadlines...)
	runner.mu.Unlock()
	if want := []Probe{ProbeKernelLogDmesg, ProbeKernelLogJournal}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("fallback calls = %#v, want %#v", calls, want)
	}
	for index, hasDeadline := range deadlines {
		if !hasDeadline {
			t.Errorf("fallback probe %d had no deadline", index)
		}
	}
}

// TestTouchscreenKernelLogUnavailabilityDoesNotFabricateFailure verifies an
// unprivileged user still receives the independently observed live evidence.
func TestTouchscreenKernelLogUnavailabilityDoesNotFabricateFailure(t *testing.T) {
	runner := healthyTestRunner()
	runner.responses[ProbeKernelLogDmesg] = testProbeResponse{result: ProbeResult{ExitCode: 1}}
	runner.responses[ProbeKernelLogJournal] = testProbeResponse{err: errors.New("private journal permission and SECRET-HOST")}
	doctor, err := New(healthyTestFileSystem(), runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureTouchscreen}})
	if err != nil {
		t.Fatal(err)
	}
	check := findCheck(t, report, "touchscreen-kernel-runtime")
	if check.State != StateUnavailable || check.Required || !report.Ready {
		t.Fatalf("unavailable kernel-log check = %#v; ready = %t", check, report.Ready)
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "SECRET-HOST") {
		t.Fatalf("unavailable kernel-log report exposed a private error: %s", encoded)
	}
}

// TestTouchscreenProbeCancellationEscapesImmediately verifies parent
// cancellation is not converted into an unavailable diagnostic result.
func TestTouchscreenProbeCancellationEscapesImmediately(t *testing.T) {
	runner := healthyTestRunner()
	runner.responses[ProbeKernelLogDmesg] = testProbeResponse{waitForContext: true}
	doctor, err := New(healthyTestFileSystem(), runner)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancelled := make(chan struct{})
	go func() {
		time.Sleep(10 * time.Millisecond)
		cancel()
		close(cancelled)
	}()
	started := time.Now()
	_, err = doctor.Inspect(ctx, Options{Features: []Feature{FeatureTouchscreen}, ProbeTimeout: time.Second})
	<-cancelled
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled touchscreen inspection error = %v", err)
	}
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Fatalf("cancelled touchscreen inspection took %s", elapsed)
	}
	runner.mu.Lock()
	calls := append([]Probe(nil), runner.calls...)
	runner.mu.Unlock()
	if want := []Probe{ProbeKernelLogDmesg}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("cancelled probe calls = %#v, want %#v", calls, want)
	}
}

// TestOversizedTouchscreenKernelLogUsesFallback verifies injected runners
// cannot bypass the feature-specific kernel-log cap.
func TestOversizedTouchscreenKernelLogUsesFallback(t *testing.T) {
	runner := healthyTestRunner()
	runner.responses[ProbeKernelLogDmesg] = testProbeResponse{result: ProbeResult{
		ExitCode: 0,
		Output:   []byte(strings.Repeat("private-kernel-value", int(maximumKernelLogProbeOutput/4))),
	}}
	runner.responses[ProbeKernelLogJournal] = testProbeResponse{result: ProbeResult{ExitCode: 0, Output: []byte("touch controller initialized path=hardware\n")}}
	doctor, err := New(healthyTestFileSystem(), runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureTouchscreen}})
	if err != nil {
		t.Fatal(err)
	}
	if check := findCheck(t, report, "touchscreen-kernel-runtime"); check.State != StatePass {
		t.Fatalf("oversized fallback check = %#v", check)
	}
	runner.mu.Lock()
	calls := append([]Probe(nil), runner.calls...)
	runner.mu.Unlock()
	if want := []Probe{ProbeKernelLogDmesg, ProbeKernelLogJournal}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("oversized fallback calls = %#v, want %#v", calls, want)
	}
}
