// Package hardwaredoctor inspects live Surface Pro 11 hardware state without
// changing devices, services, radio blocks, network connections, or audio
// routing.
package hardwaredoctor

import (
	"fmt"
	"strings"
	"time"
)

// Feature identifies one live hardware area that can be inspected alone.
type Feature string

const (
	// FeatureWiFi selects WCN7850 PCI, device-tree, rfkill, and interface state.
	FeatureWiFi Feature = "wifi"
	// FeatureBluetooth selects controller, address-quality, rfkill, and BlueZ state.
	FeatureBluetooth Feature = "bluetooth"
	// FeatureAudio selects ALSA endpoint and desktop audio-session state.
	FeatureAudio Feature = "audio"
	// FeatureTouchscreen selects loaded device-tree, SPI, input, firmware, and kernel-log state.
	FeatureTouchscreen Feature = "touchscreen"
)

// orderedFeatures fixes both combined-report and help-text ordering.
var orderedFeatures = []Feature{
	FeatureWiFi,
	FeatureBluetooth,
	FeatureAudio,
	FeatureTouchscreen,
}

// EvidenceKind identifies what one check can establish.
type EvidenceKind string

const (
	// EvidenceStatic describes configuration loaded for the current boot.
	EvidenceStatic EvidenceKind = "static-evidence"
	// EvidenceRuntime describes live device or service state observed read-only.
	EvidenceRuntime EvidenceKind = "runtime-state"
	// EvidenceHardwareTest describes a physical or end-to-end test left to the user.
	EvidenceHardwareTest EvidenceKind = "hardware-test"
)

// State is the normalised outcome of one hardware diagnostic check.
type State string

const (
	// StatePass means the observed evidence satisfies the check.
	StatePass State = "pass"
	// StateWarn means the evidence is usable but needs attention or more context.
	StateWarn State = "warn"
	// StateFail means the observed live state does not satisfy a required check.
	StateFail State = "fail"
	// StateUnavailable means a bounded read or probe could not establish the state.
	StateUnavailable State = "unavailable"
	// StateNotProven means the doctor deliberately did not exercise physical hardware.
	StateNotProven State = "not-proven"
)

const (
	// defaultProbeTimeout bounds each external process started by the doctor.
	defaultProbeTimeout = 2 * time.Second
	// maximumProbeTimeout prevents callers from turning a diagnostic into a long wait.
	maximumProbeTimeout = 10 * time.Second
	// maximumProbeOutput bounds ordinary output accepted from either a real or injected runner.
	maximumProbeOutput int64 = 32 << 10
	// maximumKernelLogProbeOutput accommodates a bounded current-boot kernel log.
	maximumKernelLogProbeOutput int64 = 512 << 10
	// maximumRunnerProbeOutput is the largest output cap accepted by the process boundary.
	maximumRunnerProbeOutput = maximumKernelLogProbeOutput
)

// Check is one deterministic, redacted hardware diagnostic result.
type Check struct {
	// ID is a stable identifier suitable for automation and tests.
	ID string `json:"id"`
	// Feature groups feature-specific results; platform checks leave it empty.
	Feature Feature `json:"feature,omitempty"`
	// Evidence states whether the check is static, runtime, or a manual hardware test.
	Evidence EvidenceKind `json:"evidence"`
	// State is the normalised result without raw command or device output.
	State State `json:"state"`
	// Required marks failures and unavailable results that make the report unready.
	Required bool `json:"required"`
	// Detail explains the conclusion using only non-identifying, bounded prose.
	Detail string `json:"detail"`
	// Remediation gives a safe next diagnostic action without performing it.
	Remediation string `json:"remediation,omitempty"`
}

// Options controls one read-only live hardware inspection.
type Options struct {
	// Features limits the report; an empty slice selects every maintained hardware check.
	Features []Feature
	// ProbeTimeout bounds each external command; zero selects the safe default.
	ProbeTimeout time.Duration
}

// Report combines redacted checks into a live-readiness result.
type Report struct {
	// Ready is false when a required check fails or cannot be observed.
	Ready bool `json:"ready"`
	// HardwareQualified is always false because this doctor performs no physical tests.
	HardwareQualified bool `json:"hardware_qualified"`
	// Features records the deterministic feature selection used for this report.
	Features []Feature `json:"features"`
	// Checks contains platform checks followed by feature checks in stable order.
	Checks []Check `json:"checks"`
}

// ChecksFor returns a copy of the checks belonging to one feature.
func (r Report) ChecksFor(feature Feature) []Check {
	checks := make([]Check, 0)
	for _, check := range r.Checks {
		if check.Feature == feature {
			checks = append(checks, check)
		}
	}
	return checks
}

// Features returns the accepted selectors in combined-report order.
func Features() []Feature {
	return append([]Feature(nil), orderedFeatures...)
}

// ParseFeature validates one human-supplied hardware feature selector.
func ParseFeature(value string) (Feature, error) {
	feature := Feature(strings.ToLower(strings.TrimSpace(value)))
	for _, candidate := range orderedFeatures {
		if feature == candidate {
			return feature, nil
		}
	}
	return "", fmt.Errorf("unsupported hardware feature %q; expected one of %s", value, featureNames())
}

// selectedFeatures validates and de-duplicates a requested feature subset.
func selectedFeatures(requested []Feature) ([]Feature, error) {
	if len(requested) == 0 {
		return Features(), nil
	}
	selected := make(map[Feature]bool, len(requested))
	for _, feature := range requested {
		valid := false
		for _, candidate := range orderedFeatures {
			if feature == candidate {
				valid = true
				break
			}
		}
		if !valid {
			return nil, fmt.Errorf("unsupported hardware feature %q; expected one of %s", feature, featureNames())
		}
		selected[feature] = true
	}
	features := make([]Feature, 0, len(selected))
	for _, feature := range orderedFeatures {
		if selected[feature] {
			features = append(features, feature)
		}
	}
	return features, nil
}

// featureNames formats the closed selector vocabulary for validation errors.
func featureNames() string {
	names := make([]string, 0, len(orderedFeatures))
	for _, feature := range orderedFeatures {
		names = append(names, string(feature))
	}
	return strings.Join(names, ", ")
}

// normaliseProbeTimeout validates or supplies the per-process timeout.
func normaliseProbeTimeout(value time.Duration) (time.Duration, error) {
	if value == 0 {
		return defaultProbeTimeout, nil
	}
	if value < 0 || value > maximumProbeTimeout {
		return 0, fmt.Errorf("hardware probe timeout must be greater than zero and no more than %s", maximumProbeTimeout)
	}
	return value, nil
}
