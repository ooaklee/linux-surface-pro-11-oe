package hardwaredoctor

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// testFileSystem is a deterministic in-memory implementation of the read boundary.
type testFileSystem struct {
	// files maps absolute logical paths to private test content.
	files map[string][]byte
	// directories maps absolute logical paths to bounded child inventories.
	directories map[string][]PathInfo
	// links maps absolute logical paths to link targets.
	links map[string]string
	// stats maps absolute logical paths to followed object metadata.
	stats map[string]PathInfo
	// failures inject read failures without exposing them to the report.
	failures map[string]error
}

// testProbeResponse controls one deterministic fake process result.
type testProbeResponse struct {
	// result is returned when the probe is not configured to wait.
	result ProbeResult
	// err is the private runner failure returned to the doctor.
	err error
	// waitForContext makes the fake honour the probe deadline before returning.
	waitForContext bool
}

// testProbeRunner records fixed probes and returns configured results safely.
type testProbeRunner struct {
	// mu protects calls when tests exercise the race detector.
	mu sync.Mutex
	// responses maps fixed probe identifiers to deterministic results.
	responses map[Probe]testProbeResponse
	// calls records only probe identifiers, not raw process output.
	calls []Probe
	// deadlines records whether every call received a deadline.
	deadlines []bool
}

// ReadFile returns one bounded in-memory file.
func (filesystem *testFileSystem) ReadFile(ctx context.Context, path string, maxBytes int64) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := filesystem.failures[path]; err != nil {
		return nil, err
	}
	content, ok := filesystem.files[path]
	if !ok {
		return nil, fs.ErrNotExist
	}
	if int64(len(content)) > maxBytes {
		return nil, ErrReadLimit
	}
	return append([]byte(nil), content...), nil
}

// ReadDir returns one bounded copy of an in-memory directory.
func (filesystem *testFileSystem) ReadDir(ctx context.Context, path string, maxEntries int) ([]PathInfo, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := filesystem.failures[path]; err != nil {
		return nil, err
	}
	entries, ok := filesystem.directories[path]
	if !ok {
		return nil, fs.ErrNotExist
	}
	if len(entries) > maxEntries {
		return nil, ErrReadLimit
	}
	return append([]PathInfo(nil), entries...), nil
}

// ReadLink returns one in-memory link target.
func (filesystem *testFileSystem) ReadLink(ctx context.Context, path string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if err := filesystem.failures[path]; err != nil {
		return "", err
	}
	target, ok := filesystem.links[path]
	if !ok {
		return "", fs.ErrNotExist
	}
	return target, nil
}

// Stat returns one followed in-memory object record.
func (filesystem *testFileSystem) Stat(ctx context.Context, path string) (PathInfo, error) {
	if err := ctx.Err(); err != nil {
		return PathInfo{}, err
	}
	if err := filesystem.failures[path]; err != nil {
		return PathInfo{}, err
	}
	info, ok := filesystem.stats[path]
	if !ok {
		return PathInfo{}, fs.ErrNotExist
	}
	return info, nil
}

// Run honours cancellation and records that callers supplied a deadline.
func (runner *testProbeRunner) Run(ctx context.Context, probe Probe, _ int64) (ProbeResult, error) {
	_, hasDeadline := ctx.Deadline()
	runner.mu.Lock()
	runner.calls = append(runner.calls, probe)
	runner.deadlines = append(runner.deadlines, hasDeadline)
	response, ok := runner.responses[probe]
	runner.mu.Unlock()
	if !ok {
		return ProbeResult{}, fmt.Errorf("unexpected probe %q", probe)
	}
	if response.waitForContext {
		<-ctx.Done()
		return ProbeResult{}, ctx.Err()
	}
	return response.result, response.err
}

// healthyTestFileSystem creates a current sp11v19 live-state fixture.
func healthyTestFileSystem() *testFileSystem {
	filesystem := &testFileSystem{
		files: map[string][]byte{
			"/proc/device-tree/model":                       []byte("Microsoft Surface Pro 11th Edition (OLED)\x00"),
			"/proc/device-tree/compatible":                  []byte("microsoft,denali-oled\x00microsoft,denali\x00qcom,x1e80100\x00"),
			"/proc/sys/kernel/osrelease":                    []byte("7.2.0-jg-0sp11v19-qcom-x1e\n"),
			"/sys/bus/pci/devices/0004:01:00.0/vendor":      []byte("0x17cb\n"),
			"/sys/bus/pci/devices/0004:01:00.0/device":      []byte("0x1107\n"),
			"/sys/class/rfkill/rfkill0/type":                []byte("wlan\n"),
			"/sys/class/rfkill/rfkill0/soft":                []byte("0\n"),
			"/sys/class/rfkill/rfkill0/hard":                []byte("0\n"),
			"/sys/class/rfkill/rfkill1/type":                []byte("bluetooth\n"),
			"/sys/class/rfkill/rfkill1/soft":                []byte("0\n"),
			"/sys/class/rfkill/rfkill1/hard":                []byte("0\n"),
			"/sys/class/net/wl-private-interface/operstate": []byte("up\n"),
			"/sys/class/bluetooth/hci0/address":             []byte("20:11:22:33:44:55\n"),
			"/proc/asound/cards":                            []byte(" 0 [X1E80100Microso ]: qcom - X1E80100-Microsoft-Surface\n"),
			"/proc/asound/pcm":                              []byte("00-00: Playback : playback 1\n00-01: Capture : capture 1\n"),
		},
		directories: map[string][]PathInfo{
			"/sys/bus/pci/devices":                                          {{Name: "0004:01:00.0", Kind: PathSymlink}},
			"/sys/firmware/devicetree/base":                                 {{Name: "soc@0", Kind: PathDirectory}},
			"/sys/firmware/devicetree/base/soc@0":                           {{Name: "pci@1c08000", Kind: PathDirectory}},
			"/sys/firmware/devicetree/base/soc@0/pci@1c08000":               {{Name: "pcie@0", Kind: PathDirectory}},
			"/sys/firmware/devicetree/base/soc@0/pci@1c08000/pcie@0":        {{Name: "wifi@0", Kind: PathDirectory}},
			"/sys/firmware/devicetree/base/soc@0/pci@1c08000/pcie@0/wifi@0": {},
			"/sys/class/rfkill":                                             {{Name: "rfkill0", Kind: PathSymlink}, {Name: "rfkill1", Kind: PathSymlink}},
			"/sys/class/net":                                                {{Name: "wl-private-interface", Kind: PathSymlink}},
			"/sys/class/bluetooth":                                          {{Name: "hci0", Kind: PathSymlink}},
		},
		links: map[string]string{
			"/sys/bus/pci/devices/0004:01:00.0/driver": "../../../../bus/pci/drivers/ath12k_wifi7_pci",
		},
		stats: map[string]PathInfo{
			"/sys/firmware/devicetree/base/soc@0/pci@1c08000/pcie@0/wifi@0/disable-rfkill": {Name: "disable-rfkill", Kind: PathRegular},
			"/sys/class/net/wl-private-interface/wireless":                                 {Name: "wireless", Kind: PathDirectory},
		},
		failures: map[string]error{},
	}
	addHealthyTouchscreenFixture(filesystem)
	return filesystem
}

// addHealthyTouchscreenFixture adds maintained in-tree touchscreen evidence to
// the shared healthy live-state fixture without obscuring its other features.
func addHealthyTouchscreenFixture(filesystem *testFileSystem) {
	filesystem.files["/proc/bus/input/devices"] = []byte("I: Bus=001c Vendor=045e Product=0001 Version=0001\nN: Name=\"Microsoft Surface G6 Touch\"\n")
	filesystem.files["/sys/bus/spi/devices/spi10.0/modalias"] = []byte("of:NtouchscreenT(null)Cmicrosoft,mshw0485\n")
	filesystem.files["/sys/firmware/devicetree/base/soc@0/geniqup@ac0000/spi@a88000/status"] = []byte("okay\x00")
	filesystem.files["/sys/firmware/devicetree/base/soc@0/geniqup@ac0000/spi@a88000/touchscreen@0/compatible"] = []byte("microsoft,mshw0485\x00")
	filesystem.directories["/sys/firmware/devicetree/base/soc@0"] = []PathInfo{{Name: "geniqup@ac0000", Kind: PathDirectory}, {Name: "pci@1c08000", Kind: PathDirectory}}
	filesystem.directories["/sys/firmware/devicetree/base/soc@0/geniqup@ac0000"] = []PathInfo{{Name: "spi@a88000", Kind: PathDirectory}}
	filesystem.directories["/sys/firmware/devicetree/base/soc@0/geniqup@ac0000/spi@a88000"] = []PathInfo{{Name: "status", Kind: PathRegular}, {Name: "touchscreen@0", Kind: PathDirectory}}
	filesystem.directories["/sys/firmware/devicetree/base/soc@0/geniqup@ac0000/spi@a88000/touchscreen@0"] = []PathInfo{{Name: "compatible", Kind: PathRegular}}
	filesystem.directories["/sys/bus/spi/devices"] = []PathInfo{{Name: "spi10.0", Kind: PathSymlink}}
	filesystem.stats["/lib/firmware/qcom/x1e80100/qupv3fw.elf.zst"] = PathInfo{Name: "qupv3fw.elf.zst", Kind: PathRegular}
}

// healthyTestRunner creates successful probes containing deliberately private text.
func healthyTestRunner() *testProbeRunner {
	return &testProbeRunner{responses: map[Probe]testProbeResponse{
		ProbeBluetoothService: {result: ProbeResult{ExitCode: 0}},
		ProbeBlueZControllers: {result: ProbeResult{ExitCode: 0, Output: []byte("Controller 20:11:22:33:44:55 Private Headset Host\n")}},
		ProbeAudioSession:     {result: ProbeResult{ExitCode: 0, Output: []byte("User Name: private-user\nServer Name: private-host\n")}},
		ProbeKernelLogDmesg:   {result: ProbeResult{ExitCode: 0, Output: []byte("private serial: SECRET-DEVICE-ID\ntouch controller initialized path=hardware recoveries=1 resets=0\n")}},
	}}
}

// findCheck locates one stable report check for concise assertions.
func findCheck(t *testing.T, report Report, id string) Check {
	t.Helper()
	for _, check := range report.Checks {
		if check.ID == id {
			return check
		}
	}
	t.Fatalf("check %q was not reported", id)
	return Check{}
}

// TestParseFeatureAndSelection verifies the closed feature vocabulary and order.
func TestParseFeatureAndSelection(t *testing.T) {
	feature, err := ParseFeature(" Bluetooth ")
	if err != nil || feature != FeatureBluetooth {
		t.Fatalf("ParseFeature() = %q, %v", feature, err)
	}
	if _, err := ParseFeature("camera"); err == nil || !strings.Contains(err.Error(), "wifi, bluetooth, audio, touchscreen") {
		t.Fatalf("ParseFeature(camera) error = %v", err)
	}
	selected, err := selectedFeatures([]Feature{FeatureAudio, FeatureWiFi, FeatureAudio})
	if err != nil {
		t.Fatal(err)
	}
	if want := []Feature{FeatureWiFi, FeatureAudio}; !reflect.DeepEqual(selected, want) {
		t.Fatalf("selectedFeatures() = %#v, want %#v", selected, want)
	}
}

// TestInspectHealthyCombinedReport verifies current v19 live evidence and limits.
func TestInspectHealthyCombinedReport(t *testing.T) {
	runner := healthyTestRunner()
	doctor, err := New(healthyTestFileSystem(), runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Ready {
		t.Fatalf("report.Ready = false; checks = %#v", report.Checks)
	}
	if report.HardwareQualified {
		t.Fatal("report.HardwareQualified = true for a read-only inspection")
	}
	if !reflect.DeepEqual(report.Features, Features()) {
		t.Fatalf("features = %#v, want %#v", report.Features, Features())
	}
	for _, id := range []string{
		"platform-surface-pro-11", "kernel-surface-family", "wifi-wcn7850-pci",
		"wifi-device-tree-rfkill-policy", "wifi-rfkill-state", "wifi-network-interface",
		"bluetooth-hci-controller", "bluetooth-address-quality", "bluetooth-bluez-controller",
		"audio-alsa-surface-card", "audio-alsa-playback", "audio-session-server",
		"touchscreen-qup-firmware", "touchscreen-device-tree-controller",
		"touchscreen-device-tree-client", "touchscreen-spi-client",
		"touchscreen-input-device", "touchscreen-kernel-runtime",
	} {
		if check := findCheck(t, report, id); check.State != StatePass {
			t.Errorf("%s state = %s, detail = %s", id, check.State, check.Detail)
		}
	}
	for _, feature := range Features() {
		check := findCheck(t, report, string(feature)+"-hardware-test")
		if check.State != StateNotProven || check.Evidence != EvidenceHardwareTest || check.Required {
			t.Errorf("%s limitation = %#v", feature, check)
		}
	}
	runner.mu.Lock()
	calls := append([]Probe(nil), runner.calls...)
	deadlines := append([]bool(nil), runner.deadlines...)
	runner.mu.Unlock()
	wantCalls := []Probe{ProbeBluetoothService, ProbeBlueZControllers, ProbeAudioSession, ProbeKernelLogDmesg}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("probe calls = %#v, want %#v", calls, wantCalls)
	}
	for index, hasDeadline := range deadlines {
		if !hasDeadline {
			t.Errorf("probe %d had no context deadline", index)
		}
	}
}

// TestReportDoesNotExposePrivateRuntimeValues verifies ordinary and JSON fields are redacted.
func TestReportDoesNotExposePrivateRuntimeValues(t *testing.T) {
	doctor, err := New(healthyTestFileSystem(), healthyTestRunner())
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{})
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	ordinary := fmt.Sprintf("%+v", report)
	combined := ordinary + string(encoded)
	for _, privateValue := range []string{
		"20:11:22:33:44:55", "Private Headset Host", "private-user", "private-host",
		"wl-private-interface", "0004:01:00.0",
		"SECRET-DEVICE-ID",
	} {
		if strings.Contains(combined, privateValue) {
			t.Errorf("report exposed private value %q", privateValue)
		}
	}
}

// TestFeatureSelectionAvoidsUnselectedProbes verifies Wi-Fi inspection is self-contained.
func TestFeatureSelectionAvoidsUnselectedProbes(t *testing.T) {
	runner := &testProbeRunner{responses: map[Probe]testProbeResponse{}}
	doctor, err := New(healthyTestFileSystem(), runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureWiFi}})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Ready || !reflect.DeepEqual(report.Features, []Feature{FeatureWiFi}) {
		t.Fatalf("Wi-Fi report = %#v", report)
	}
	if len(report.ChecksFor(FeatureBluetooth)) != 0 || len(report.ChecksFor(FeatureAudio)) != 0 || len(report.ChecksFor(FeatureTouchscreen)) != 0 {
		t.Fatalf("unselected checks were included: %#v", report.Checks)
	}
	if len(runner.calls) != 0 {
		t.Fatalf("Wi-Fi-only report executed probes: %#v", runner.calls)
	}
}

// TestInspectClassifiesBlockedAndIncompleteState verifies failure conclusions remain typed.
func TestInspectClassifiesBlockedAndIncompleteState(t *testing.T) {
	filesystem := healthyTestFileSystem()
	filesystem.files["/sys/class/rfkill/rfkill0/hard"] = []byte("1\n")
	filesystem.files["/sys/class/bluetooth/hci0/address"] = []byte("00:00:00:00:5A:AD\n")
	filesystem.files["/proc/asound/cards"] = []byte(" 0 [Generic ]: generic - Generic sound\n")
	runner := healthyTestRunner()
	doctor, err := New(filesystem, runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{})
	if err != nil {
		t.Fatal(err)
	}
	if report.Ready {
		t.Fatal("report.Ready = true, want false")
	}
	for _, id := range []string{"wifi-rfkill-state", "bluetooth-address-quality", "audio-alsa-surface-card"} {
		if check := findCheck(t, report, id); check.State != StateFail || !check.Required {
			t.Errorf("%s = %#v", id, check)
		}
	}
}

// TestUnreadablePCIInventoryIsUnavailable verifies partial PCI discovery never
// claims that the audited WCN7850 function is absent.
func TestUnreadablePCIInventoryIsUnavailable(t *testing.T) {
	filesystem := healthyTestFileSystem()
	filesystem.failures["/sys/bus/pci/devices/0004:01:00.0/vendor"] = errors.New("private PCI read failure")
	doctor, err := New(filesystem, healthyTestRunner())
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureWiFi}})
	if err != nil {
		t.Fatal(err)
	}
	check := findCheck(t, report, "wifi-wcn7850-pci")
	if check.State != StateUnavailable || report.Ready {
		t.Fatalf("partial PCI check = %#v; ready = %t", check, report.Ready)
	}
}

// TestBlueZControllerParserRejectsMalformedRecords verifies private free-form
// output cannot be mistaken for a valid controller inventory marker.
func TestBlueZControllerParserRejectsMalformedRecords(t *testing.T) {
	output := []byte("Controller malformed private-name\nController 20:11:22:33:44:55 private-name\n")
	if count := countBlueZControllers(output); count != 1 {
		t.Fatalf("countBlueZControllers() = %d, want 1", count)
	}
}

// TestProbeTimeoutIsBoundedAndRedacted verifies a child deadline becomes safe evidence.
func TestProbeTimeoutIsBoundedAndRedacted(t *testing.T) {
	runner := healthyTestRunner()
	runner.responses[ProbeBluetoothService] = testProbeResponse{waitForContext: true, err: errors.New("secret SSID and 20:11:22:33:44:55")}
	doctor, err := New(healthyTestFileSystem(), runner)
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureBluetooth}, ProbeTimeout: 20 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("timed probe took %s", elapsed)
	}
	check := findCheck(t, report, "bluetooth-bluez-service")
	if check.State != StateUnavailable || !strings.Contains(check.Detail, "timed out") {
		t.Fatalf("timeout check = %#v", check)
	}
	encoded, marshalErr := json.Marshal(report)
	if marshalErr != nil {
		t.Fatal(marshalErr)
	}
	if strings.Contains(string(encoded), "secret SSID") || strings.Contains(string(encoded), "20:11:22:33:44:55") {
		t.Fatalf("timeout report exposed private runner error: %s", encoded)
	}
}

// TestOversizedInjectedOutputIsRejected verifies runner implementations cannot bypass the cap.
func TestOversizedInjectedOutputIsRejected(t *testing.T) {
	runner := healthyTestRunner()
	runner.responses[ProbeAudioSession] = testProbeResponse{result: ProbeResult{ExitCode: 0, Output: []byte(strings.Repeat("private-host ", int(maximumProbeOutput)))}}
	doctor, err := New(healthyTestFileSystem(), runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureAudio}})
	if err != nil {
		t.Fatal(err)
	}
	check := findCheck(t, report, "audio-session-server")
	if check.State != StateUnavailable || strings.Contains(check.Detail, "private-host") {
		t.Fatalf("oversized output check = %#v", check)
	}
}

// TestInspectHonoursParentCancellation verifies cancellation is not hidden as evidence.
func TestInspectHonoursParentCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	doctor, err := New(healthyTestFileSystem(), healthyTestRunner())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := doctor.Inspect(ctx, Options{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("Inspect() error = %v, want context cancellation", err)
	}
}

// TestUnknownPlatformSkipsLiveProbes verifies a non-target host is never interrogated further.
func TestUnknownPlatformSkipsLiveProbes(t *testing.T) {
	filesystem := healthyTestFileSystem()
	filesystem.files["/proc/device-tree/model"] = []byte("unrelated device\n")
	filesystem.files["/proc/device-tree/compatible"] = []byte("vendor,other\x00")
	runner := healthyTestRunner()
	doctor, err := New(filesystem, runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{})
	if err != nil {
		t.Fatal(err)
	}
	if report.Ready || len(runner.calls) != 0 {
		t.Fatalf("non-target report = %#v; calls = %#v", report, runner.calls)
	}
	for _, feature := range Features() {
		if check := findCheck(t, report, string(feature)+"-runtime-applicability"); check.State != StateUnavailable {
			t.Errorf("%s applicability = %#v", feature, check)
		}
	}
}

// TestKernelGenerationClassificationRejectsAmbiguityAndFlagsNewerEvidence verifies ABI claims stay conservative.
func TestKernelGenerationClassificationRejectsAmbiguityAndFlagsNewerEvidence(t *testing.T) {
	tests := []struct {
		// name identifies the kernel-classification case.
		name string
		// release is the private procfs value to classify.
		release string
		// wantState is the expected static-evidence conclusion.
		wantState State
		// wantDetail is a safe report fragment.
		wantDetail string
	}{
		{name: "ambiguous", release: "7.2.0-sp11v12-sp11v19-qcom-x1e", wantState: StateWarn, wantDetail: "does not expose"},
		{name: "newer", release: "7.3.0-jg-0sp11v20-qcom-x1e", wantState: StateWarn, wantDetail: "newer than"},
		{name: "unrelated", release: "7.2.0-generic", wantState: StateFail, wantDetail: "does not identify"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			filesystem := healthyTestFileSystem()
			filesystem.files["/proc/sys/kernel/osrelease"] = []byte(test.release)
			doctor, err := New(filesystem, healthyTestRunner())
			if err != nil {
				t.Fatal(err)
			}
			report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureWiFi}})
			if err != nil {
				t.Fatal(err)
			}
			check := findCheck(t, report, "kernel-surface-family")
			if check.State != test.wantState || !strings.Contains(check.Detail, test.wantDetail) {
				t.Fatalf("kernel check = %#v", check)
			}
			if strings.Contains(check.Detail, test.release) {
				t.Fatalf("kernel check exposed raw release %q", test.release)
			}
		})
	}
}

// TestSoftwareRadioBlockWarnsWithoutClaimingHardwareFailure verifies intentional policy is distinguished.
func TestSoftwareRadioBlockWarnsWithoutClaimingHardwareFailure(t *testing.T) {
	filesystem := healthyTestFileSystem()
	filesystem.files["/sys/class/rfkill/rfkill0/soft"] = []byte("1\n")
	doctor, err := New(filesystem, healthyTestRunner())
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureWiFi}})
	if err != nil {
		t.Fatal(err)
	}
	check := findCheck(t, report, "wifi-rfkill-state")
	if check.State != StateWarn || check.Required || !report.Ready {
		t.Fatalf("software-block check = %#v; ready = %t", check, report.Ready)
	}
}

// TestFixedProbeChecksUseOnlyCompiledConclusions verifies every error branch remains redacted.
func TestFixedProbeChecksUseOnlyCompiledConclusions(t *testing.T) {
	privateOutput := ProbeResult{ExitCode: 4, Output: []byte("20:11:22:33:44:55 private-device private-ssid")}
	checks := []Check{
		bluetoothServiceCheck(privateOutput, probeTimedOut),
		bluetoothServiceCheck(privateOutput, probeUnavailable),
		bluetoothServiceCheck(ProbeResult{ExitCode: 3}, probeCompleted),
		bluetoothServiceCheck(privateOutput, probeCompleted),
		blueZControllerCheck(privateOutput, probeTimedOut),
		blueZControllerCheck(privateOutput, probeUnavailable),
		blueZControllerCheck(ProbeResult{ExitCode: 1}, probeCompleted),
		blueZControllerCheck(ProbeResult{ExitCode: 0}, probeCompleted),
		audioSessionCheck(privateOutput, probeTimedOut),
		audioSessionCheck(privateOutput, probeUnavailable),
		audioSessionCheck(ProbeResult{ExitCode: 1}, probeCompleted),
	}
	for _, check := range checks {
		encoded, err := json.Marshal(check)
		if err != nil {
			t.Fatal(err)
		}
		for _, privateValue := range []string{"20:11:22:33:44:55", "private-device", "private-ssid"} {
			if strings.Contains(string(encoded), privateValue) {
				t.Errorf("%s exposed %q: %s", check.ID, privateValue, encoded)
			}
		}
	}
}

// TestPrivateBoundaryErrorsAreRedacted verifies filesystem and runner errors never enter reports.
func TestPrivateBoundaryErrorsAreRedacted(t *testing.T) {
	filesystem := healthyTestFileSystem()
	filesystem.failures["/sys/class/bluetooth/hci0/address"] = errors.New("private adapter 20:11:22:33:44:55")
	runner := healthyTestRunner()
	runner.responses[ProbeBluetoothService] = testProbeResponse{err: errors.New("private paired device and private-ssid")}
	doctor, err := New(filesystem, runner)
	if err != nil {
		t.Fatal(err)
	}
	report, err := doctor.Inspect(context.Background(), Options{Features: []Feature{FeatureBluetooth}})
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	for _, privateValue := range []string{"20:11:22:33:44:55", "private paired device", "private-ssid"} {
		if strings.Contains(string(encoded), privateValue) {
			t.Errorf("report exposed private boundary error %q: %s", privateValue, encoded)
		}
	}
}
