package catalog

import (
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var (
	stableIDPattern = regexp.MustCompile(`^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`)
	hexPattern      = regexp.MustCompile(`^[[:xdigit:]]+$`)
)

// Issue is one actionable catalog validation problem.
type Issue struct {
	Field   string
	Message string
}

// ValidationError reports every semantic problem found in a decoded catalog.
// Issues are ordered by document position and validation rule.
type ValidationError struct {
	Issues []Issue
}

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

func validate(raw document, entries []Entry) error {
	var issues []Issue
	add := func(field, format string, values ...any) {
		issues = append(issues, Issue{Field: field, Message: fmt.Sprintf(format, values...)})
	}

	if raw.SchemaVersion != CurrentSchemaVersion {
		add("schema_version", "must be %d, got %d", CurrentSchemaVersion, raw.SchemaVersion)
	}
	if strings.TrimSpace(raw.Description) == "" {
		add("description", "must not be empty")
	}
	if len(raw.Entries) == 0 {
		add("entries", "must contain at least one entry")
	}

	firstIDIndex := make(map[string]int, len(raw.Entries))
	for index, rawEntry := range raw.Entries {
		entry := entries[index]
		prefix := fmt.Sprintf("entries[%d]", index)

		if !stableIDPattern.MatchString(entry.ID) {
			add(prefix+".id", "must be a stable lowercase kebab-case identifier beginning with a letter")
		}
		if first, exists := firstIDIndex[entry.ID]; exists {
			add(prefix+".id", "must be unique; it is already used by entries[%d].id", first)
		} else {
			firstIDIndex[entry.ID] = index
		}

		requireText(add, prefix+".name", entry.Name)
		requireText(add, prefix+".distribution", entry.Distribution)
		requireText(add, prefix+".release", entry.Release)

		if _, err := NormalizeArchitecture(rawEntry.Architecture); err != nil {
			add(prefix+".architecture", "%v; got %q", err, rawEntry.Architecture)
		}

		switch entry.ArtifactKind {
		case ArtifactKindISO, ArtifactKindRawXZ:
		default:
			add(prefix+".artifact_kind", "must be %q or %q, got %q", ArtifactKindISO, ArtifactKindRawXZ, entry.ArtifactKind)
		}

		artifactURL := validateHTTPSURL(add, prefix+".url", entry.URL)
		validateHTTPSURL(add, prefix+".homepage", entry.Homepage)
		if artifactURL != nil {
			validateArtifactExtension(add, prefix+".url", entry.ArtifactKind, artifactURL.Path)
		}

		switch entry.Adapter {
		case AdapterNone, AdapterUbuntuCasper:
		default:
			add(prefix+".adapter", "must be %q or %q, got %q", AdapterNone, AdapterUbuntuCasper, entry.Adapter)
		}

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
		for noteIndex, note := range entry.CompatibilityNotes {
			if strings.TrimSpace(note) == "" {
				add(fmt.Sprintf("%s.compatibility_notes[%d]", prefix, noteIndex), "must not be empty")
			}
		}

		if _, err := time.Parse("2006-01-02", entry.LastVerified); err != nil {
			add(prefix+".last_verified", "must be a real calendar date in YYYY-MM-DD format, got %q", entry.LastVerified)
		}
	}

	if len(issues) > 0 {
		return &ValidationError{Issues: issues}
	}

	return nil
}

func requireText(add func(string, string, ...any), field, value string) {
	if strings.TrimSpace(value) == "" {
		add(field, "must not be empty")
	}
}

func validateHTTPSURL(add func(string, string, ...any), field, value string) *url.URL {
	if strings.TrimSpace(value) == "" {
		add(field, "must not be empty")
		return nil
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

func validateArtifactExtension(add func(string, string, ...any), field string, kind ArtifactKind, path string) {
	lowerPath := strings.ToLower(path)
	switch kind {
	case ArtifactKindISO:
		if !strings.HasSuffix(lowerPath, ".iso") {
			add(field, "must end in .iso when artifact_kind is %q", ArtifactKindISO)
		}
	case ArtifactKindRawXZ:
		if !strings.HasSuffix(lowerPath, ".raw.xz") {
			add(field, "must end in .raw.xz when artifact_kind is %q", ArtifactKindRawXZ)
		}
	}
}

func validateChecksum(add func(string, string, ...any), field string, checksum *Checksum) {
	if checksum == nil {
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
