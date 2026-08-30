// Package catalog loads and validates linux-armer's audited userspace
// component catalogue.
package catalog

import "sort"

// CurrentSchemaVersion is the only userspace catalogue schema understood by
// this build.
const CurrentSchemaVersion = 2

// Level describes the lifecycle and support maturity of a component.
type Level string

// Supported lifecycle levels distinguish required integrations from optional,
// diagnostic, experimental, and explicitly retired components.
const (
	// LevelRequired marks support that must be present for the relevant hardware.
	LevelRequired Level = "required"
	// LevelSupported marks optional support maintained for normal use.
	LevelSupported Level = "supported"
	// LevelExperimental marks support whose compatibility is still provisional.
	LevelExperimental Level = "experimental"
	// LevelDiagnosticOnly marks tooling that must not run as a daily-use service.
	LevelDiagnosticOnly Level = "diagnostic-only"
	// LevelObsolete marks retired support that should only be detected or removed.
	LevelObsolete Level = "obsolete"
)

// Capability identifies the user-visible hardware area a component supports.
type Capability string

// Supported capability values provide a fixed vocabulary for grouping
// components by the hardware or system facility they enable.
const (
	CapabilityFirmware    Capability = "firmware"
	CapabilityNetworking  Capability = "networking"
	CapabilityBluetooth   Capability = "bluetooth"
	CapabilityAudio       Capability = "audio"
	CapabilityPen         Capability = "pen"
	CapabilityCamera      Capability = "camera"
	CapabilityPower       Capability = "power"
	CapabilityTouchscreen Capability = "touchscreen"
)

// Redistribution records the review boundary for distributing a component.
type Redistribution string

// Supported redistribution policies record whether linux-armer may fetch or
// distribute an artefact, or must instead direct the user to its source.
const (
	RedistributionAllowed        Redistribution = "allowed"
	RedistributionRestricted     Redistribution = "restricted"
	RedistributionSourceRequired Redistribution = "source-required"
	RedistributionNotApplicable  Redistribution = "not-applicable"
)

// CompatibilityEvidence describes how compatibility was established.
type CompatibilityEvidence string

// Supported compatibility evidence values distinguish an exact tested release
// pair from a component inherited from a previously validated kernel source.
const (
	EvidenceExactPair                       CompatibilityEvidence = "exact_pair"
	EvidenceSourceIntegratedPriorValidation CompatibilityEvidence = "source_integrated_prior_validation"
)

// SupportActions declares the bounded operations linux-armer may expose for a
// component. These flags are capabilities, not commands.
type SupportActions struct {
	// Status permits read-only detection and health reporting.
	Status bool `json:"status"`
	// Pull permits fetching an immutable, checksum-bound release bundle.
	Pull bool `json:"pull"`
	// Build permits delegating to the component's maintained source workflow.
	Build bool `json:"build"`
	// Install permits applying a verified payload through compiled install policy.
	Install bool `json:"install"`
}

// Release identifies an immutable release and its complete expected asset set.
type Release struct {
	// URL is the human-facing HTTPS page for the immutable release.
	URL string `json:"url"`
	// Tag is the exact release tag requested from the release API.
	Tag string `json:"tag"`
	// AssetAllowlist is the complete set of filenames accepted for the release.
	AssetAllowlist []string `json:"asset_allowlist"`
}

// KernelCompatibility records the explicit Surface kernel generation boundary
// against which a userspace component has been assessed.
type KernelCompatibility struct {
	// MinimumSP11Generation is the earliest sp11vN kernel generation that
	// provides the interfaces required by this component.
	MinimumSP11Generation int `json:"minimum_sp11_generation"`
	// TestedThroughSP11Generation is the newest sp11vN generation covered by
	// the catalogue evidence. Newer generations are reported as unverified.
	TestedThroughSP11Generation int `json:"tested_through_sp11_generation"`
	// Summary explains the boundary in plain language for catalogue readers.
	Summary string `json:"summary"`
}

// Component is one audited userspace, firmware, or superseded support unit.
type Component struct {
	// ID is the stable, lowercase identifier accepted by programmatic callers.
	ID string `json:"id"`
	// Name is the concise human-readable component label.
	Name string `json:"name"`
	// Level records the component's current support lifecycle.
	Level Level `json:"level"`
	// Capability identifies the hardware or system area the component supports.
	Capability Capability `json:"capability"`
	// Redistribution records the artefact-sharing boundary for this component.
	Redistribution Redistribution `json:"redistribution"`
	// SupportActions declares which bounded workflows may be exposed.
	SupportActions SupportActions `json:"support_actions"`
	// Release describes the exact downloadable bundle, when pulling is supported.
	Release *Release `json:"release,omitempty"`
	// CompatibilityEvidence records how this component was paired with the kernel.
	CompatibilityEvidence CompatibilityEvidence `json:"compatibility_evidence"`
	// KernelCompatibility states the kernel boundary for an exact tested pairing.
	KernelCompatibility *KernelCompatibility `json:"kernel_compatibility,omitempty"`
	// Notes explain limitations and context without embedding executable guidance.
	Notes []string `json:"notes"`
	// Remediation gives a safe next action when status inspection finds a problem.
	Remediation string `json:"remediation"`
}

// Catalog is an immutable, validated view of a userspace catalogue document.
type Catalog struct {
	// SchemaVersion identifies the validated document format.
	SchemaVersion int
	// Description explains the purpose and scope of the catalogue.
	Description string

	// components preserves validated entries for defensive-copy iteration.
	components []Component
	// byID provides immutable lookup by stable component identifier.
	byID map[string]Component
}

// Len returns the number of components in the catalogue.
func (c *Catalog) Len() int {
	if c == nil {
		return 0
	}
	return len(c.components)
}

// List returns defensive copies of all components sorted by stable ID.
func (c *Catalog) List() []Component {
	if c == nil {
		return nil
	}
	components := make([]Component, 0, len(c.components))
	for _, component := range c.components {
		components = append(components, cloneComponent(component))
	}
	sort.Slice(components, func(i, j int) bool {
		return components[i].ID < components[j].ID
	})
	return components
}

// Get returns a defensive copy of the component with id.
func (c *Catalog) Get(id string) (Component, bool) {
	if c == nil {
		return Component{}, false
	}
	component, ok := c.byID[id]
	if !ok {
		return Component{}, false
	}
	return cloneComponent(component), true
}

// cloneComponent makes a deep-enough copy of slice and pointer fields so callers
// cannot mutate the catalogue's validated internal state.
func cloneComponent(component Component) Component {
	component.Notes = append([]string(nil), component.Notes...)
	if component.Release != nil {
		release := *component.Release
		release.AssetAllowlist = append([]string(nil), component.Release.AssetAllowlist...)
		component.Release = &release
	}
	if component.KernelCompatibility != nil {
		compatibility := *component.KernelCompatibility
		component.KernelCompatibility = &compatibility
	}
	return component
}
