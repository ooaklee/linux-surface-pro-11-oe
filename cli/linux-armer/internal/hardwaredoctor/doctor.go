package hardwaredoctor

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	// maximumIdentityBytes bounds each non-sensitive platform identity file.
	maximumIdentityBytes int64 = 4096
)

// surfaceGenerationPattern extracts a bounded sp11vN marker from a kernel ABI.
var surfaceGenerationPattern = regexp.MustCompile(`sp11v([0-9]{1,3})(?:[-+._]|$)`)

// Doctor coordinates static and live hardware probes through read-only boundaries.
type Doctor struct {
	// filesystem supplies bounded procfs, sysfs, and device-tree reads.
	filesystem FileSystem
	// runner executes only the compiled external probe allow-list.
	runner ProbeRunner
}

// New constructs a live hardware doctor with injectable read-only boundaries.
func New(filesystem FileSystem, runner ProbeRunner) (*Doctor, error) {
	if filesystem == nil {
		var err error
		filesystem, err = NewOSFileSystem("")
		if err != nil {
			return nil, err
		}
	}
	if runner == nil {
		runner = ExecProbeRunner{}
	}
	return &Doctor{filesystem: filesystem, runner: runner}, nil
}

// Inspect collects redacted evidence without changing host or device state.
func (doctor *Doctor) Inspect(ctx context.Context, options Options) (Report, error) {
	if doctor == nil || doctor.filesystem == nil || doctor.runner == nil {
		return Report{}, errors.New("hardware doctor is not initialised")
	}
	if err := ctx.Err(); err != nil {
		return Report{}, err
	}
	features, err := selectedFeatures(options.Features)
	if err != nil {
		return Report{}, err
	}
	probeTimeout, err := normaliseProbeTimeout(options.ProbeTimeout)
	if err != nil {
		return Report{}, err
	}
	report := Report{Ready: true, Features: features}
	add := func(check Check) {
		report.Checks = append(report.Checks, check)
		if check.Required && (check.State == StateFail || check.State == StateUnavailable) {
			report.Ready = false
		}
	}
	platformCheck, platformMatched := doctor.inspectPlatform(ctx)
	add(platformCheck)
	if err := ctx.Err(); err != nil {
		return Report{}, err
	}
	kernelCheck, generation := doctor.inspectKernel(ctx)
	add(kernelCheck)
	if err := ctx.Err(); err != nil {
		return Report{}, err
	}
	if !platformMatched {
		for _, feature := range features {
			add(Check{
				ID:       string(feature) + "-runtime-applicability",
				Feature:  feature,
				Evidence: EvidenceRuntime,
				State:    StateUnavailable,
				Required: true,
				Detail:   "live Surface Pro 11 state was not inspected because platform identity is unavailable",
			})
			add(hardwareLimitation(feature))
		}
		return report, nil
	}
	for _, feature := range features {
		if err := ctx.Err(); err != nil {
			return Report{}, err
		}
		switch feature {
		case FeatureWiFi:
			for _, check := range doctor.inspectWiFi(ctx) {
				add(check)
			}
		case FeatureBluetooth:
			checks, inspectErr := doctor.inspectBluetooth(ctx, probeTimeout)
			if inspectErr != nil {
				return Report{}, inspectErr
			}
			for _, check := range checks {
				add(check)
			}
		case FeatureAudio:
			if generation > 0 && generation < 12 {
				add(Check{
					ID:          "audio-kernel-generation",
					Feature:     FeatureAudio,
					Evidence:    EvidenceStatic,
					State:       StateFail,
					Required:    true,
					Detail:      "the running Surface kernel predates the generation required by the maintained FullIO audio pairing",
					Remediation: "boot a maintained Surface kernel, then rerun both static userspace and live hardware diagnostics",
				})
			}
			checks, inspectErr := doctor.inspectAudio(ctx, probeTimeout)
			if inspectErr != nil {
				return Report{}, inspectErr
			}
			for _, check := range checks {
				add(check)
			}
		}
		if err := ctx.Err(); err != nil {
			return Report{}, err
		}
	}
	return report, nil
}

// inspectPlatform verifies the loaded device tree without returning its raw text.
func (doctor *Doctor) inspectPlatform(ctx context.Context) (Check, bool) {
	model, modelErr := doctor.filesystem.ReadFile(ctx, "/proc/device-tree/model", maximumIdentityBytes)
	compatible, compatibleErr := doctor.filesystem.ReadFile(ctx, "/proc/device-tree/compatible", maximumIdentityBytes)
	modelMatches := modelErr == nil && strings.Contains(strings.ToLower(string(model)), "surface pro 11")
	compatibleText := strings.ToLower(strings.ReplaceAll(string(compatible), "\x00", " "))
	compatibleMatches := compatibleErr == nil && strings.Contains(compatibleText, "microsoft,denali") && strings.Contains(compatibleText, "qcom,x1e80100")
	if modelMatches || compatibleMatches {
		return Check{
			ID:       "platform-surface-pro-11",
			Evidence: EvidenceStatic,
			State:    StatePass,
			Required: true,
			Detail:   "the loaded device tree identifies the Surface Pro 11 Qualcomm platform",
		}, true
	}
	state := StateFail
	detail := "the loaded device tree does not identify the Surface Pro 11 Qualcomm platform"
	if (modelErr != nil && !errors.Is(modelErr, fs.ErrNotExist)) || (compatibleErr != nil && !errors.Is(compatibleErr, fs.ErrNotExist)) {
		state = StateUnavailable
		detail = "the loaded Surface Pro 11 platform identity could not be read safely"
	}
	return Check{
		ID:          "platform-surface-pro-11",
		Evidence:    EvidenceStatic,
		State:       state,
		Required:    true,
		Detail:      detail,
		Remediation: "run live hardware diagnostics on the target Surface Pro 11 after booting Linux",
	}, false
}

// inspectKernel classifies only the supported family and generation marker.
func (doctor *Doctor) inspectKernel(ctx context.Context) (Check, int) {
	content, err := doctor.filesystem.ReadFile(ctx, "/proc/sys/kernel/osrelease", maximumIdentityBytes)
	if err != nil {
		return Check{
			ID:          "kernel-surface-family",
			Evidence:    EvidenceStatic,
			State:       StateUnavailable,
			Required:    true,
			Detail:      "the running kernel family could not be established",
			Remediation: "boot a maintained Surface qcom-x1e kernel and rerun the diagnostic",
		}, 0
	}
	release := strings.TrimSpace(string(content))
	if len(release) > 200 || strings.ContainsRune(release, '\x00') || !strings.Contains(strings.ToLower(release), "qcom-x1e") {
		return Check{
			ID:          "kernel-surface-family",
			Evidence:    EvidenceStatic,
			State:       StateFail,
			Required:    true,
			Detail:      "the running kernel does not identify the maintained Surface qcom-x1e family",
			Remediation: "boot a maintained Surface qcom-x1e kernel and rerun the diagnostic",
		}, 0
	}
	matches := surfaceGenerationPattern.FindAllStringSubmatch(strings.ToLower(release), -1)
	if len(matches) != 1 || len(matches[0]) != 2 {
		return Check{
			ID:          "kernel-surface-family",
			Evidence:    EvidenceStatic,
			State:       StateWarn,
			Required:    true,
			Detail:      "the running qcom-x1e kernel does not expose a bounded sp11 generation marker",
			Remediation: "compare the installed ABI with the supported kernel release before interpreting live results",
		}, 0
	}
	generation, conversionErr := strconv.Atoi(matches[0][1])
	if conversionErr != nil || generation < 1 {
		return Check{
			ID:       "kernel-surface-family",
			Evidence: EvidenceStatic,
			State:    StateWarn,
			Required: true,
			Detail:   "the running qcom-x1e kernel generation could not be classified",
		}, 0
	}
	state := StatePass
	detail := fmt.Sprintf("the running kernel is Surface qcom-x1e generation sp11v%d", generation)
	remediation := ""
	if generation > 19 {
		state = StateWarn
		detail = "the running Surface kernel is newer than the current sp11v19 compatibility evidence"
		remediation = "qualify this kernel generation before treating the live report as release evidence"
	}
	return Check{
		ID:          "kernel-surface-family",
		Evidence:    EvidenceStatic,
		State:       state,
		Required:    true,
		Detail:      detail,
		Remediation: remediation,
	}, generation
}

// runProbe executes one fixed process with a fresh per-probe deadline.
func (doctor *Doctor) runProbe(ctx context.Context, probe Probe, timeout time.Duration) (ProbeResult, probeOutcome, error) {
	probeContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	result, err := doctor.runner.Run(probeContext, probe, maximumProbeOutput)
	if ctx.Err() != nil {
		return ProbeResult{}, probeCancelled, ctx.Err()
	}
	if errors.Is(probeContext.Err(), context.DeadlineExceeded) {
		return ProbeResult{}, probeTimedOut, nil
	}
	if err != nil {
		return ProbeResult{}, probeUnavailable, nil
	}
	if int64(len(result.Output)) > maximumProbeOutput {
		return ProbeResult{}, probeOversized, nil
	}
	return result, probeCompleted, nil
}

// probeOutcome classifies runner failures without exposing raw process output.
type probeOutcome string

const (
	// probeCompleted means the process exited within its bound.
	probeCompleted probeOutcome = "completed"
	// probeTimedOut means the per-probe deadline expired.
	probeTimedOut probeOutcome = "timed-out"
	// probeUnavailable means the executable could not be run safely.
	probeUnavailable probeOutcome = "unavailable"
	// probeOversized means an injected runner exceeded the output contract.
	probeOversized probeOutcome = "oversized"
	// probeCancelled means the parent operation was cancelled.
	probeCancelled probeOutcome = "cancelled"
)

// hardwareLimitation records the physical test that a read-only doctor omits.
func hardwareLimitation(feature Feature) Check {
	detail := "the read-only doctor cannot prove this hardware works end to end"
	switch feature {
	case FeatureWiFi:
		detail = "network scanning, association, reconnection, throughput, cold-boot behaviour, and suspend behaviour were not exercised"
	case FeatureBluetooth:
		detail = "discovery, pairing, profiles, peripherals, audio, cold-boot behaviour, and suspend behaviour were not exercised"
	case FeatureAudio:
		detail = "speaker playback, left/right channel routing, clipping or crackle, microphone recording quality, and suspend behaviour were not exercised"
	}
	return Check{
		ID:       string(feature) + "-hardware-test",
		Feature:  feature,
		Evidence: EvidenceHardwareTest,
		State:    StateNotProven,
		Required: false,
		Detail:   detail,
	}
}
