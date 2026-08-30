package catalog

import (
	"fmt"
	"net/url"
	"path"
	"regexp"
	"strings"
	"time"
	"unicode"
)

const (
	// maximumHumanTextBytes bounds each human-facing catalogue string before it
	// can reach terminal or structured output.
	maximumHumanTextBytes = 4096
	// maximumIdentifierBytes bounds stable IDs and other short machine values.
	maximumIdentifierBytes = 128
	// maximumFilenameBytes matches the common portable filesystem component
	// limit while leaving room for release naming conventions.
	maximumFilenameBytes = 255
	// maximumURLBytes permits long signed publisher URLs without unbounded input.
	maximumURLBytes = 4096
	// maximumCompatibilityNotes bounds validation work and displayed caveats for
	// each catalogue entry.
	maximumCompatibilityNotes = 64
)

var (
	// stableIDPattern defines IDs that remain convenient in JSON and shells.
	stableIDPattern = regexp.MustCompile(`^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`)
	// hexPattern recognises a non-empty hexadecimal checksum value.
	hexPattern = regexp.MustCompile(`^[[:xdigit:]]+$`)
	// portableFilenamePattern accepts reviewable release filenames without path
	// separators, whitespace, shell metacharacters, or control characters.
	portableFilenamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]*$`)
)

// Issue is one actionable catalogue validation problem.
type Issue struct {
	// Field is the JSON-style path to the invalid value.
	Field string `json:"field"`
	// Message explains how the value violates the catalogue contract.
	Message string `json:"message"`
}

// ValidationError reports every semantic problem found in a decoded catalogue.
// Issues are ordered by document position and validation rule.
type ValidationError struct {
	// Issues contains all detected problems in deterministic document order.
	Issues []Issue
}

// Error formats all validation issues into one actionable diagnostic.
func (e *ValidationError) Error() string {
	if e == nil || len(e.Issues) == 0 {
		return "catalog validation failed"
	}

	var message strings.Builder
	message.WriteString("catalog validation failed:")
	for _, issue := range e.Issues {
		message.WriteString("\n - ")
		message.WriteString(issue.Field)
		message.WriteString(": ")
		message.WriteString(issue.Message)
	}

	return message.String()
}

// NormalizeArchitecture maps the accepted ARM64 spellings to linux-armer's
// canonical architecture value.
func NormalizeArchitecture(value string) (Architecture, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "arm64", "aarch64":
		return ArchitectureARM64, nil
	default:
		return "", fmt.Errorf("must be %q or its %q alias", ArchitectureARM64, "aarch64")
	}
}

// validate applies cross-field and per-entry semantic rules after JSON
// decoding, accumulating every problem so maintainers can fix a catalogue in one
// pass.
func validate(raw document, entries []Entry) error {
	var issues []Issue
	add := func(field, format string, values ...any) {
		issues = append(issues, Issue{Field: field, Message: fmt.Sprintf(format, values...)})
	}

	if raw.SchemaVersion != CurrentSchemaVersion {
		add("schema_version", "must be %d, got %d", CurrentSchemaVersion, raw.SchemaVersion)
	}
	validateHumanText(add, "description", raw.Description)
	if len(raw.Entries) == 0 {
		add("entries", "must contain at least one entry")
	}

	firstIDIndex := make(map[string]int, len(raw.Entries))
	for index, rawEntry := range raw.Entries {
		entry := entries[index]
		prefix := fmt.Sprintf("entries[%d]", index)

		idLengthOK := validateByteLength(add, prefix+".id", entry.ID, maximumIdentifierBytes)
		if idLengthOK && !stableIDPattern.MatchString(entry.ID) {
			add(prefix+".id", "must be a stable lowercase kebab-case identifier beginning with a letter")
		}
		if first, exists := firstIDIndex[entry.ID]; exists {
			add(prefix+".id", "must be unique; it is already used by entries[%d].id", first)
		} else {
			firstIDIndex[entry.ID] = index
		}

		validateHumanText(add, prefix+".name", entry.Name)
		validateHumanText(add, prefix+".distribution", entry.Distribution)
		validateHumanText(add, prefix+".release", entry.Release)
		validateFilename(add, prefix+".filename", entry.Filename, entry.ArtifactKind)

		architectureLengthOK := validateByteLength(add, prefix+".architecture", rawEntry.Architecture, maximumIdentifierBytes)
		if architectureLengthOK {
			if _, err := NormalizeArchitecture(rawEntry.Architecture); err != nil {
				add(prefix+".architecture", "%v; got %q", err, rawEntry.Architecture)
			}
		}

		artifactKindValid := false
		if validateByteLength(add, prefix+".artifact_kind", string(entry.ArtifactKind), maximumIdentifierBytes) {
			switch entry.ArtifactKind {
			case ArtifactKindISO, ArtifactKindRawXZ:
				artifactKindValid = true
			default:
				add(prefix+".artifact_kind", "must be %q or %q, got %q", ArtifactKindISO, ArtifactKindRawXZ, entry.ArtifactKind)
			}
		}

		artifactURL := validateHTTPSURL(add, prefix+".url", entry.URL)
		validateHTTPSURL(add, prefix+".homepage", entry.Homepage)
		if artifactURL != nil && len(entry.Filename) <= maximumFilenameBytes {
			if got := path.Base(artifactURL.Path); got != entry.Filename {
				add(prefix+".url", "final path segment %q must equal filename %q", got, entry.Filename)
			}
		}

		adapterValid := false
		if validateByteLength(add, prefix+".adapter", string(entry.Adapter), maximumIdentifierBytes) {
			switch entry.Adapter {
			case AdapterNone, AdapterUbuntuCasper:
				adapterValid = true
			default:
				add(prefix+".adapter", "must be %q or %q, got %q", AdapterNone, AdapterUbuntuCasper, entry.Adapter)
			}
		}
		if adapterValid && artifactKindValid && entry.Adapter != AdapterNone && !AdapterSupportsArtifact(entry.Adapter, entry.ArtifactKind) {
			add(prefix+".adapter", "does not support artifact_kind %q", entry.ArtifactKind)
		}

		if validateByteLength(add, prefix+".support_level", string(entry.SupportLevel), maximumIdentifierBytes) {
			switch entry.SupportLevel {
			case SupportLevelImplemented:
				if entry.Adapter == AdapterNone {
					add(prefix+".adapter", "must name an implemented adapter when support_level is %q", SupportLevelImplemented)
				}
			case SupportLevelCatalogOnly:
				if entry.Adapter != AdapterNone {
					add(prefix+".adapter", "must be %q when support_level is %q", AdapterNone, SupportLevelCatalogOnly)
				}
			default:
				add(prefix+".support_level", "must be %q or %q, got %q", SupportLevelImplemented, SupportLevelCatalogOnly, entry.SupportLevel)
			}
		}

		if rawEntry.Experimental == nil {
			add(prefix+".experimental", "is required and must be a boolean")
		}
		if rawEntry.Mutable == nil {
			add(prefix+".mutable", "is required and must be a boolean")
		}

		validateChecksum(add, prefix+".checksum", entry.Checksum)
		if len(entry.CompatibilityNotes) == 0 {
			add(prefix+".compatibility_notes", "must contain at least one note")
		}
		if len(entry.CompatibilityNotes) > maximumCompatibilityNotes {
			add(prefix+".compatibility_notes", "must contain at most %d notes", maximumCompatibilityNotes)
		}
		for noteIndex, note := range entry.CompatibilityNotes[:min(len(entry.CompatibilityNotes), maximumCompatibilityNotes)] {
			validateHumanText(add, fmt.Sprintf("%s.compatibility_notes[%d]", prefix, noteIndex), note)
		}

		if validateByteLength(add, prefix+".last_verified", entry.LastVerified, maximumIdentifierBytes); len(entry.LastVerified) <= maximumIdentifierBytes {
			if _, err := time.Parse("2006-01-02", entry.LastVerified); err != nil {
				add(prefix+".last_verified", "must be a real calendar date in YYYY-MM-DD format, got %q", entry.LastVerified)
			}
		}
	}

	if len(issues) > 0 {
		return &ValidationError{Issues: issues}
	}

	return nil
}

// validateHumanText requires bounded, single-line display text without terminal
// controls, invisible formatting controls, or surrounding whitespace.
func validateHumanText(add func(string, string, ...any), field, value string) {
	if !validateByteLength(add, field, value, maximumHumanTextBytes) {
		return
	}
	if strings.TrimSpace(value) == "" {
		add(field, "must not be empty")
		return
	}
	if value != strings.TrimSpace(value) {
		add(field, "must not have leading or trailing whitespace")
	}
	for _, character := range value {
		if unicode.IsControl(character) || unicode.Is(unicode.Cf, character) || character == '\u2028' || character == '\u2029' {
			add(field, "must not contain control or invisible formatting characters")
			return
		}
	}
}

// validateByteLength records an issue when a string exceeds its field-specific
// byte limit and reports whether further validation is safe.
func validateByteLength(add func(string, string, ...any), field, value string, maximum int) bool {
	if len(value) <= maximum {
		return true
	}
	add(field, "must contain at most %d bytes", maximum)
	return false
}

// validateHTTPSURL checks that a URL is absolute, credential-free HTTPS and
// returns the parsed value for additional format-specific validation.
func validateHTTPSURL(add func(string, string, ...any), field, value string) *url.URL {
	if !validateByteLength(add, field, value, maximumURLBytes) {
		return nil
	}
	if strings.TrimSpace(value) == "" {
		add(field, "must not be empty")
		return nil
	}
	if value != strings.TrimSpace(value) {
		add(field, "must not have leading or trailing whitespace")
		return nil
	}
	for _, character := range value {
		if unicode.IsControl(character) || unicode.Is(unicode.Cf, character) || character == '\u2028' || character == '\u2029' {
			add(field, "must not contain control or invisible formatting characters")
			return nil
		}
	}

	parsed, err := url.Parse(value)
	if err != nil {
		add(field, "must be a valid absolute URL: %v", err)
		return nil
	}
	if parsed.Scheme != "https" {
		add(field, "must use https, got scheme %q", parsed.Scheme)
	}
	if parsed.Hostname() == "" {
		add(field, "must include a hostname")
	}
	if parsed.User != nil {
		add(field, "must not include user credentials")
	}
	if parsed.Fragment != "" {
		add(field, "must not include a fragment")
	}

	return parsed
}

// validateFilename ensures the explicit upstream name is portable and agrees
// with the declared artefact format.
func validateFilename(add func(string, string, ...any), field, filename string, kind ArtifactKind) {
	if !validateByteLength(add, field, filename, maximumFilenameBytes) {
		return
	}
	if strings.TrimSpace(filename) == "" {
		add(field, "must not be empty")
		return
	}
	if !portableFilenamePattern.MatchString(filename) {
		add(field, "must be a portable filename containing no path separators or whitespace")
		return
	}
	lowerFilename := strings.ToLower(filename)
	switch kind {
	case ArtifactKindISO:
		if !strings.HasSuffix(lowerFilename, ".iso") {
			add(field, "must end in .iso when artifact_kind is %q", ArtifactKindISO)
		}
	case ArtifactKindRawXZ:
		if !strings.HasSuffix(lowerFilename, ".raw.xz") {
			add(field, "must end in .raw.xz when artifact_kind is %q", ArtifactKindRawXZ)
		}
	}
}

// validateChecksum checks the supported digest algorithms, exact digest
// lengths, and hexadecimal encoding.
func validateChecksum(add func(string, string, ...any), field string, checksum *Checksum) {
	if checksum == nil {
		return
	}

	if !validateByteLength(add, field+".algorithm", checksum.Algorithm, maximumIdentifierBytes) {
		return
	}
	if !validateByteLength(add, field+".value", checksum.Value, 128) {
		return
	}

	expectedLength := 0
	switch checksum.Algorithm {
	case "sha256":
		expectedLength = 64
	case "sha512":
		expectedLength = 128
	default:
		add(field+".algorithm", "must be %q or %q, got %q", "sha256", "sha512", checksum.Algorithm)
	}

	if expectedLength != 0 && len(checksum.Value) != expectedLength {
		add(field+".value", "must contain exactly %d hexadecimal digits for %s", expectedLength, checksum.Algorithm)
		return
	}
	if checksum.Value == "" || !hexPattern.MatchString(checksum.Value) {
		add(field+".value", "must contain hexadecimal digits only")
	}
}
