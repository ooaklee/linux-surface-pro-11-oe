// Package status inspects the userspace support installed for Surface Pro 11.
//
// Inspection is deliberately static: it reads files beneath a selected root
// and never invokes services or host tools. This makes the same API safe for a
// live system, a mounted target root, and an extracted image filesystem.
// Path containment assumes the inspected root is offline or otherwise
// quiescent; a privileged process mutating links concurrently is outside this
// portable resolver's trust boundary.
package status

import (
	"fmt"
	"sort"
	"strings"
)

// State is the outcome of one diagnostic check.
type State string

// Diagnostic states distinguish healthy support, actionable degradation,
// readiness-blocking failures, and checks that do not apply.
const (
	// StatePass means the expected support is present and valid.
	StatePass State = "pass"
	// StateWarn means support is incomplete or conflicting but not required.
	StateWarn State = "warn"
	// StateFail means a required support contract is not satisfied.
	StateFail State = "fail"
	// StateSkip means a check was unavailable or an optional feature is absent.
	StateSkip State = "skip"
)

// Feature identifies a userspace support area that can be inspected alone.
type Feature string

// Supported inspection features define the stable CLI and JSON vocabulary for
// selecting one userspace support area.
const (
	FeatureKernel    Feature = "kernel"
	FeatureFirmware  Feature = "firmware"
	FeatureWiFi      Feature = "wifi"
	FeatureBluetooth Feature = "bluetooth"
	FeatureAudio     Feature = "audio"
	FeatureIPTSD     Feature = "iptsd"
	FeatureG6Pen     Feature = "g6-pen"
	FeatureTouch     Feature = "touchscreen"
	FeatureCamera    Feature = "camera"
	FeaturePower     Feature = "power"
)

// orderedFeatures controls deterministic report and help-text ordering.
var orderedFeatures = []Feature{
	FeatureKernel,
	FeatureFirmware,
	FeatureWiFi,
	FeatureBluetooth,
	FeatureAudio,
	FeatureIPTSD,
	FeatureG6Pen,
	FeatureTouch,
	FeatureCamera,
	FeaturePower,
}

// SupportLevel mirrors the catalogue maturity values that affect diagnostic
// severity without making this static inspector depend on catalogue loading.
type SupportLevel string

// Diagnostic support levels distinguish readiness requirements from optional,
// experimental, diagnostic-only, and retired support.
const (
	// SupportRequired means an absent component blocks default system readiness.
	SupportRequired SupportLevel = "required"
	// SupportSupported means the component is maintained but not universally required.
	SupportSupported SupportLevel = "supported"
	// SupportExperimental means the component still has provisional qualification.
	SupportExperimental SupportLevel = "experimental"
	// SupportDiagnosticOnly means the component is intended only for controlled diagnosis.
	SupportDiagnosticOnly SupportLevel = "diagnostic-only"
	// SupportObsolete means the component should be detected or removed, not installed.
	SupportObsolete SupportLevel = "obsolete"
)

// ComponentPolicy binds one compiled diagnostic feature to its catalogue
// identity, maturity, and optional Surface kernel generation boundary.
type ComponentPolicy struct {
	// ID is the stable userspace catalogue component identifier.
	ID string
	// Feature is the diagnostic feature implemented for the component.
	Feature Feature
	// SupportLevel is the maturity declared by the validated catalogue.
	SupportLevel SupportLevel
	// MinimumSP11Generation is the earliest compatible sp11vN kernel generation.
	MinimumSP11Generation int
	// TestedThroughSP11Generation is the newest generation covered by evidence.
	TestedThroughSP11Generation int
}

// Features returns the accepted feature names in report order.
func Features() []Feature {
	return append([]Feature(nil), orderedFeatures...)
}

// ParseFeature validates a feature supplied by a CLI flag.
func ParseFeature(value string) (Feature, error) {
	feature := Feature(strings.ToLower(strings.TrimSpace(value)))
	for _, candidate := range orderedFeatures {
		if feature == candidate {
			return feature, nil
		}
	}
	return "", fmt.Errorf("unsupported userspace feature %q; expected one of %s", value, featureNames())
}

// featureNames formats the closed feature vocabulary for actionable validation
// errors.
func featureNames() string {
	names := make([]string, 0, len(orderedFeatures))
	for _, feature := range orderedFeatures {
		names = append(names, string(feature))
	}
	return strings.Join(names, ", ")
}

// Check is one stable, machine-readable diagnostic result.
type Check struct {
	// ID is a stable identifier suitable for automation and tests.
	ID string `json:"id"`
	// Feature groups the result under one userspace support area.
	Feature Feature `json:"feature"`
	// ComponentID identifies the catalogue component assessed by this check.
	ComponentID string `json:"component_id,omitempty"`
	// SupportLevel reports the component maturity used to derive severity.
	SupportLevel SupportLevel `json:"support_level,omitempty"`
	// State is the normalised outcome of the inspection.
	State State `json:"state"`
	// Required marks failures that make the overall report unready.
	Required bool `json:"required"`
	// Detail explains the observed state without exposing private device data.
	Detail string `json:"detail"`
	// Remediation gives a safe next action when attention is needed.
	Remediation string `json:"remediation,omitempty"`
}

// Options controls a read-only inspection.
type Options struct {
	// Root is the target filesystem root. It defaults to "/".
	Root string
	// UserHome is one explicit canonical target-visible Linux home inspected for
	// per-user legacy support. It is never inferred from the host environment.
	UserHome string
	// KernelABI selects one installed qcom-x1e ABI. When empty, the newest
	// candidate is selected deterministically.
	KernelABI string
	// Features limits the report. An empty slice inspects every feature.
	Features []Feature
	// ComponentPolicies supplies catalogue-validated policy. When omitted,
	// built-in production policy is used for direct package callers.
	ComponentPolicies []ComponentPolicy
}

// Report is shared by the userspace status and doctor userspace commands.
type Report struct {
	// Root is the resolved target filesystem that was inspected.
	Root string `json:"root"`
	// UserHome is the explicit target-visible user home included in the report.
	UserHome string `json:"user_home,omitempty"`
	// KernelABI is the explicit or deterministically selected Surface kernel ABI.
	KernelABI string `json:"kernel_abi,omitempty"`
	// Ready is false when any required check fails.
	Ready bool `json:"ready"`
	// Checks contains stable diagnostic records in feature order.
	Checks []Check `json:"checks"`
}

// ChecksFor returns a copy of the checks for one feature.
func (r Report) ChecksFor(feature Feature) []Check {
	checks := make([]Check, 0)
	for _, check := range r.Checks {
		if check.Feature == feature {
			checks = append(checks, check)
		}
	}
	return checks
}

// selectedFeatures validates the requested subset and returns a membership map;
// an empty request deliberately selects every supported feature.
func selectedFeatures(requested []Feature) (map[Feature]bool, error) {
	selected := make(map[Feature]bool, len(orderedFeatures))
	if len(requested) == 0 {
		for _, feature := range orderedFeatures {
			selected[feature] = true
		}
		return selected, nil
	}
	for _, feature := range requested {
		valid := false
		for _, candidate := range orderedFeatures {
			if feature == candidate {
				valid = true
				break
			}
		}
		if !valid {
			return nil, fmt.Errorf("unsupported userspace feature %q; expected one of %s", feature, featureNames())
		}
		selected[feature] = true
	}
	return selected, nil
}

// sortedKeys returns deterministic lexical ordering for map-backed diagnostic
// details.
func sortedKeys(values map[string]bool) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
