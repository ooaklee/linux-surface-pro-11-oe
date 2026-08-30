package catalog

import (
	"fmt"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
)

// Catalogue token patterns constrain identifiers, tags, and asset names to flat,
// portable values before they are used in URLs or filesystem destinations.
var (
	stableIDPattern   = regexp.MustCompile(`^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`)
	releaseTagPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
	assetNamePattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+~:-]*$`)
)

// Issue is one actionable userspace catalogue validation problem.
type Issue struct {
	// Field is the JSON path of the invalid value.
	Field string
	// Message explains the correction a catalogue maintainer must make.
	Message string
}

// ValidationError reports every semantic problem found in a decoded catalogue.
type ValidationError struct {
	// Issues contains every semantic problem found in one validation pass.
	Issues []Issue
}

// Error formats all catalogue issues into a deterministic, readable diagnostic.
func (e *ValidationError) Error() string {
	if e == nil || len(e.Issues) == 0 {
		return "userspace catalogue validation failed"
	}
	var message strings.Builder
	message.WriteString("userspace catalogue validation failed:")
	for _, issue := range e.Issues {
		message.WriteString("\n - ")
		message.WriteString(issue.Field)
		message.WriteString(": ")
		message.WriteString(issue.Message)
	}
	return message.String()
}

// validate applies schema-wide and component-level invariants, collecting every
// issue so maintainers can repair the catalogue in a single editing pass.
func validate(raw document, components []Component) error {
	var issues []Issue
	add := func(field, format string, values ...any) {
		issues = append(issues, Issue{Field: field, Message: fmt.Sprintf(format, values...)})
	}

	if raw.SchemaVersion != CurrentSchemaVersion {
		add("schema_version", "must be %d, got %d", CurrentSchemaVersion, raw.SchemaVersion)
	}
	validateNarrative(add, "description", raw.Description)
	if len(raw.Components) == 0 {
		add("components", "must contain at least one component")
	}

	firstIDIndex := make(map[string]int, len(components))
	for index, component := range components {
		rawComponent := raw.Components[index]
		prefix := fmt.Sprintf("components[%d]", index)

		if !stableIDPattern.MatchString(component.ID) {
			add(prefix+".id", "must be a stable lowercase kebab-case identifier beginning with a letter")
		}
		if first, exists := firstIDIndex[component.ID]; exists {
			add(prefix+".id", "must be unique; it is already used by components[%d].id", first)
		} else {
			firstIDIndex[component.ID] = index
		}
		validateNarrative(add, prefix+".name", component.Name)

		validateLevel(add, prefix+".level", component.Level)
		validateCapability(add, prefix+".capability", component.Capability)
		validateRedistribution(add, prefix+".redistribution", component.Redistribution)
		validateEvidence(add, prefix+".compatibility_evidence", component.CompatibilityEvidence)
		validateKernelCompatibility(add, prefix, component)
		validateActions(add, prefix, rawComponent.SupportActions, component)
		validateRelease(add, prefix, component)

		if len(component.Notes) == 0 {
			add(prefix+".notes", "must contain at least one note")
		}
		for noteIndex, note := range component.Notes {
			validateNarrative(add, fmt.Sprintf("%s.notes[%d]", prefix, noteIndex), note)
		}
		validateNarrative(add, prefix+".remediation", component.Remediation)
	}

	if len(issues) != 0 {
		return &ValidationError{Issues: issues}
	}
	return nil
}

// validateKernelCompatibility requires every exact tested pairing to state a
// sensible, human-readable kernel generation boundary.
func validateKernelCompatibility(add func(string, string, ...any), prefix string, component Component) {
	compatibility := component.KernelCompatibility
	if compatibility == nil {
		if component.CompatibilityEvidence == EvidenceExactPair {
			add(prefix+".kernel_compatibility", "is required for exact_pair evidence")
		}
		return
	}
	if component.CompatibilityEvidence != EvidenceExactPair {
		add(prefix+".kernel_compatibility", "must only be supplied with exact_pair evidence")
	}
	if compatibility.MinimumSP11Generation < 1 || compatibility.MinimumSP11Generation > 999 {
		add(prefix+".kernel_compatibility.minimum_sp11_generation", "must be between 1 and 999")
	}
	if compatibility.TestedThroughSP11Generation < compatibility.MinimumSP11Generation || compatibility.TestedThroughSP11Generation > 999 {
		add(prefix+".kernel_compatibility.tested_through_sp11_generation", "must be between the minimum generation and 999")
	}
	validateNarrative(add, prefix+".kernel_compatibility.summary", compatibility.Summary)
}

// validateLevel checks a lifecycle value against the catalogue's closed support
// vocabulary.
func validateLevel(add func(string, string, ...any), field string, value Level) {
	switch value {
	case LevelRequired, LevelSupported, LevelExperimental, LevelDiagnosticOnly, LevelObsolete:
	default:
		add(field, "must be required, supported, experimental, diagnostic-only, or obsolete; got %q", value)
	}
}

// validateCapability checks that a component belongs to a hardware capability
// understood by the companion workflows.
func validateCapability(add func(string, string, ...any), field string, value Capability) {
	switch value {
	case CapabilityFirmware, CapabilityNetworking, CapabilityBluetooth, CapabilityAudio,
		CapabilityPen, CapabilityCamera, CapabilityPower, CapabilityTouchscreen:
	default:
		add(field, "has unsupported capability %q", value)
	}
}

// validateRedistribution enforces the reviewed artefact-sharing policy values.
func validateRedistribution(add func(string, string, ...any), field string, value Redistribution) {
	switch value {
	case RedistributionAllowed, RedistributionRestricted, RedistributionSourceRequired, RedistributionNotApplicable:
	default:
		add(field, "must be allowed, restricted, source-required, or not-applicable; got %q", value)
	}
}

// validateEvidence requires compatibility claims to use one of the two audited
// evidence categories.
func validateEvidence(add func(string, string, ...any), field string, value CompatibilityEvidence) {
	switch value {
	case EvidenceExactPair, EvidenceSourceIntegratedPriorValidation:
	default:
		add(field, "must be exact_pair or source_integrated_prior_validation; got %q", value)
	}
}

// validateActions requires every action flag to be explicit and prevents
// obsolete components from exposing mutating workflows.
func validateActions(
	add func(string, string, ...any),
	prefix string,
	raw documentSupportActions,
	component Component,
) {
	for _, required := range []struct {
		name  string
		value *bool
	}{
		{name: "status", value: raw.Status},
		{name: "pull", value: raw.Pull},
		{name: "build", value: raw.Build},
		{name: "install", value: raw.Install},
	} {
		if required.value == nil {
			add(prefix+".support_actions."+required.name, "is required and must be a boolean")
		}
	}
	actions := component.SupportActions
	if !actions.Status && !actions.Pull && !actions.Build && !actions.Install {
		add(prefix+".support_actions", "must enable at least one action")
	}
	if component.Level == LevelObsolete && (actions.Pull || actions.Build || actions.Install) {
		add(prefix+".support_actions", "obsolete components may only expose status")
	}
}

// validateRelease binds pull-enabled components to HTTPS release metadata and a
// complete, safe, duplicate-free asset allowlist containing SHA256SUMS.
func validateRelease(add func(string, string, ...any), prefix string, component Component) {
	if component.Release == nil {
		if component.SupportActions.Pull {
			add(prefix+".support_actions.pull", "cannot be true without release metadata")
		}
		return
	}
	release := component.Release
	if !component.SupportActions.Pull {
		add(prefix+".support_actions.pull", "must be true when release metadata is present")
	}
	if component.Level == LevelObsolete {
		add(prefix+".release", "must be omitted for obsolete components")
	}

	if !releaseTagPattern.MatchString(release.Tag) {
		add(prefix+".release.tag", "must be a safe release tag containing only letters, digits, dots, underscores, and hyphens")
	}
	parsed, err := url.Parse(release.URL)
	if err != nil {
		add(prefix+".release.url", "must be a valid absolute URL: %v", err)
	} else {
		if parsed.Scheme != "https" {
			add(prefix+".release.url", "must use https, got scheme %q", parsed.Scheme)
		}
		if parsed.Host != "github.com" {
			add(prefix+".release.url", "must identify a release on github.com")
		}
		if parsed.User != nil {
			add(prefix+".release.url", "must not include user credentials")
		}
		if parsed.RawQuery != "" || parsed.Fragment != "" {
			add(prefix+".release.url", "must not include a query or fragment")
		}
		segments := strings.Split(strings.Trim(parsed.Path, "/"), "/")
		if len(segments) != 5 || segments[0] == "" || segments[1] == "" ||
			segments[2] != "releases" || segments[3] != "tag" || segments[4] != release.Tag {
			add(prefix+".release.url", "path must be /OWNER/REPOSITORY/releases/tag/%s", release.Tag)
		}
	}

	if len(release.AssetAllowlist) == 0 {
		add(prefix+".release.asset_allowlist", "must contain the exact release asset set")
	}
	seen := make(map[string]int, len(release.AssetAllowlist))
	hasChecksums := false
	for assetIndex, asset := range release.AssetAllowlist {
		field := fmt.Sprintf("%s.release.asset_allowlist[%d]", prefix, assetIndex)
		if !safeAssetName(asset) {
			add(field, "must be a safe flat asset filename, got %q", asset)
		}
		if first, duplicate := seen[asset]; duplicate {
			add(field, "must be unique; it is already used by asset_allowlist[%d]", first)
		} else {
			seen[asset] = assetIndex
		}
		if asset == "SHA256SUMS" {
			hasChecksums = true
		}
	}
	if len(release.AssetAllowlist) > 0 && !hasChecksums {
		add(prefix+".release.asset_allowlist", "must include SHA256SUMS")
	}
}

// safeAssetName reports whether a release asset is a portable flat filename
// with no path separators, whitespace padding, or control characters.
func safeAssetName(name string) bool {
	if name == "" || name == "." || name == ".." || strings.TrimSpace(name) != name {
		return false
	}
	if filepath.Base(name) != name || strings.ContainsAny(name, `/\`) || !assetNamePattern.MatchString(name) {
		return false
	}
	return !strings.ContainsFunc(name, unicode.IsControl)
}

// validateNarrative keeps descriptive catalogue fields readable and declarative;
// executable commands and host-specific writable paths belong in compiled code.
func validateNarrative(add func(string, string, ...any), field, value string) {
	if strings.TrimSpace(value) == "" {
		add(field, "must not be empty")
		return
	}
	for _, token := range []struct {
		value  string
		reason string
	}{
		{value: "\n", reason: "must be a single line"},
		{value: "\r", reason: "must be a single line"},
		{value: "`", reason: "must not contain executable command markup"},
		{value: "$(", reason: "must not contain executable commands"},
		{value: "&&", reason: "must not contain executable commands"},
		{value: "||", reason: "must not contain executable commands"},
		{value: "./", reason: "must not contain executable paths"},
	} {
		if strings.Contains(value, token.value) {
			add(field, token.reason)
			return
		}
	}
	lower := strings.ToLower(value)
	if strings.Contains(lower, "sudo ") {
		add(field, "must not contain executable commands")
		return
	}
	for _, pathPrefix := range []string{"/dev/", "/etc/", "/home/", "/lib/", "/opt/", "/tmp/", "/usr/", "/var/", "~/"} {
		if strings.Contains(lower, pathPrefix) {
			add(field, "must not contain writable or host-specific paths")
			return
		}
	}
}
