package catalog

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"strings"
	"unicode/utf8"
)

const (
	// maximumCatalogueBytes bounds memory use before any catalogue JSON is
	// decoded or retained for validation.
	maximumCatalogueBytes = 1 << 20
	// maximumCatalogueEntries keeps validation and user-facing output bounded.
	maximumCatalogueEntries = 256
)

// document mirrors the top-level JSON shape before architecture normalisation
// and semantic validation.
type document struct {
	// SchemaVersion selects the catalogue document contract.
	SchemaVersion int `json:"schema_version"`
	// Description gives maintainers a concise explanation of the catalogue.
	Description string `json:"description"`
	// Entries contains the installation artefacts in human-maintained order.
	Entries []documentEntry `json:"entries"`
}

// documentEntry preserves fields whose presence or spelling must be checked
// before constructing a public Entry.
type documentEntry struct {
	// ID is the stable command-line key.
	ID string `json:"id"`
	// Name is the artefact's human-readable name.
	Name string `json:"name"`
	// Distribution identifies the upstream operating-system family.
	Distribution string `json:"distribution"`
	// Release identifies the upstream version or channel.
	Release string `json:"release"`
	// Filename is the exact upstream artefact name expected at the URL.
	Filename string `json:"filename"`
	// Architecture retains the author's spelling until it can be normalised.
	Architecture string `json:"architecture"`
	// ArtifactKind describes the upstream file format.
	ArtifactKind ArtifactKind `json:"artifact_kind"`
	// URL is the upstream artefact location.
	URL string `json:"url"`
	// Homepage is the upstream information page.
	Homepage string `json:"homepage"`
	// Adapter selects the remastering implementation.
	Adapter Adapter `json:"adapter"`
	// SupportLevel records whether remastering is implemented.
	SupportLevel SupportLevel `json:"support_level"`
	// Experimental is a pointer so validation can distinguish false from a
	// missing required boolean.
	Experimental *bool `json:"experimental"`
	// Mutable is a pointer so validation can distinguish false from a missing
	// required boolean.
	Mutable *bool `json:"mutable"`
	// Checksum optionally pins the upstream bytes.
	Checksum *Checksum `json:"checksum,omitempty"`
	// CompatibilityNotes explain device-specific constraints.
	CompatibilityNotes []string `json:"compatibility_notes"`
	// LastVerified records when maintainers last checked the entry.
	LastVerified string `json:"last_verified"`
}

// Loader chooses an on-disk override when one is provided, otherwise it loads
// the catalogue bundled in Embedded. This keeps override policy in one place for
// both command-line and interactive callers.
type Loader struct {
	// Embedded is the read-only filesystem shipped in the executable.
	Embedded fs.FS
	// EmbeddedPath is the catalogue filename within Embedded.
	EmbeddedPath string
}

// NewLoader constructs a Loader for a bundled catalogue.
func NewLoader(embedded fs.FS, embeddedPath string) Loader {
	return Loader{Embedded: embedded, EmbeddedPath: embeddedPath}
}

// Load reads overridePath when non-empty, or the configured embedded catalogue.
func (l Loader) Load(overridePath string) (*Catalog, error) {
	if overridePath != "" {
		return LoadFile(overridePath)
	}
	if l.Embedded == nil {
		return nil, errors.New("load embedded catalog: filesystem is nil")
	}
	if l.EmbeddedPath == "" {
		return nil, errors.New("load embedded catalog: path is empty")
	}

	return LoadFS(l.Embedded, l.EmbeddedPath)
}

// Load decodes and validates a catalogue from reader.
func Load(reader io.Reader) (*Catalog, error) {
	if reader == nil {
		return nil, errors.New("decode catalog: reader is nil")
	}

	data, err := io.ReadAll(io.LimitReader(reader, maximumCatalogueBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read catalog JSON: %w", err)
	}
	if len(data) > maximumCatalogueBytes {
		return nil, fmt.Errorf("decode catalog JSON: document exceeds %d bytes", maximumCatalogueBytes)
	}
	if !utf8.Valid(data) {
		return nil, errors.New("decode catalog JSON: document is not valid UTF-8")
	}
	if err := validateDocumentShape(data); err != nil {
		return nil, fmt.Errorf("decode catalog JSON: %w", err)
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()

	var raw document
	if err := decoder.Decode(&raw); err != nil {
		return nil, fmt.Errorf("decode catalog JSON: %w", err)
	}

	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return nil, errors.New("decode catalog JSON: multiple JSON values are not allowed")
		}
		return nil, fmt.Errorf("decode catalog JSON after first value: %w", err)
	}

	return build(raw)
}

// validateDocumentShape rejects ambiguous object keys and excessive entry
// counts before the document is decoded into Go structs.
func validateDocumentShape(data []byte) error {
	documentFields, err := decodeExactObject(data, "catalog", []string{
		"schema_version", "description", "entries",
	})
	if err != nil {
		return err
	}

	entriesData, ok := documentFields["entries"]
	if !ok {
		return nil
	}
	entries, err := decodeBoundedArray(entriesData, "entries", maximumCatalogueEntries)
	if err != nil {
		return err
	}
	for index, entryData := range entries {
		entryPath := fmt.Sprintf("entries[%d]", index)
		entryFields, err := decodeExactObject(entryData, entryPath, []string{
			"id", "name", "distribution", "release", "filename", "architecture",
			"artifact_kind", "url", "homepage", "adapter", "support_level",
			"experimental", "mutable", "checksum", "compatibility_notes", "last_verified",
		})
		if err != nil {
			return err
		}
		checksumData, ok := entryFields["checksum"]
		if !ok || bytes.Equal(bytes.TrimSpace(checksumData), []byte("null")) {
			continue
		}
		if _, err := decodeExactObject(checksumData, entryPath+".checksum", []string{"algorithm", "value"}); err != nil {
			return err
		}
	}
	return nil
}

// decodeExactObject returns raw field values after requiring one JSON object
// with exact, uniquely spelt keys from the supplied allow-list.
func decodeExactObject(data []byte, objectPath string, allowed []string) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	opening, ok := token.(json.Delim)
	if !ok || opening != '{' {
		return nil, fmt.Errorf("%s must be a JSON object", objectPath)
	}

	fields := make(map[string]json.RawMessage, len(allowed))
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		key, ok := keyToken.(string)
		if !ok {
			return nil, fmt.Errorf("%s contains a non-string field name", objectPath)
		}
		canonical, err := exactFieldName(key, allowed)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", objectPath, err)
		}
		if _, exists := fields[canonical]; exists {
			return nil, fmt.Errorf("%s: duplicate field %q", objectPath, canonical)
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, err
		}
		fields[canonical] = value
	}
	closing, err := decoder.Token()
	if err != nil {
		if errors.Is(err, io.EOF) {
			return nil, io.ErrUnexpectedEOF
		}
		return nil, err
	}
	if delimiter, ok := closing.(json.Delim); !ok || delimiter != '}' {
		return nil, fmt.Errorf("%s has an invalid object terminator", objectPath)
	}
	if err := requireJSONEnd(decoder); err != nil {
		return nil, err
	}
	return fields, nil
}

// exactFieldName accepts a field only when its spelling exactly matches the
// allow-list and gives a targeted diagnostic for case-only mistakes.
func exactFieldName(field string, allowed []string) (string, error) {
	for _, candidate := range allowed {
		if field == candidate {
			return candidate, nil
		}
	}
	for _, candidate := range allowed {
		if strings.EqualFold(field, candidate) {
			return "", fmt.Errorf("field %q must be spelt %q", field, candidate)
		}
	}
	return "", fmt.Errorf("unknown field %q", field)
}

// decodeBoundedArray decodes one raw JSON array while rejecting an entry count
// above maximum before further object validation takes place.
func decodeBoundedArray(data []byte, arrayPath string, maximum int) ([]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	opening, ok := token.(json.Delim)
	if !ok || opening != '[' {
		return nil, fmt.Errorf("%s must be a JSON array", arrayPath)
	}

	values := make([]json.RawMessage, 0)
	for decoder.More() {
		if len(values) == maximum {
			return nil, fmt.Errorf("%s must contain at most %d entries", arrayPath, maximum)
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, err
		}
		values = append(values, value)
	}
	closing, err := decoder.Token()
	if err != nil {
		if errors.Is(err, io.EOF) {
			return nil, io.ErrUnexpectedEOF
		}
		return nil, err
	}
	if delimiter, ok := closing.(json.Delim); !ok || delimiter != ']' {
		return nil, fmt.Errorf("%s has an invalid array terminator", arrayPath)
	}
	if err := requireJSONEnd(decoder); err != nil {
		return nil, err
	}
	return values, nil
}

// requireJSONEnd rejects a second JSON value after an otherwise valid object
// or array while permitting trailing JSON whitespace.
func requireJSONEnd(decoder *json.Decoder) error {
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return errors.New("multiple JSON values are not allowed")
		}
		return fmt.Errorf("decode after first value: %w", err)
	}
	return nil
}

// LoadBytes decodes and validates a catalogue from data.
func LoadBytes(data []byte) (*Catalog, error) {
	return Load(bytes.NewReader(data))
}

// LoadFS decodes and validates path from filesystem.
func LoadFS(filesystem fs.FS, path string) (*Catalog, error) {
	if filesystem == nil {
		return nil, errors.New("load catalog from filesystem: filesystem is nil")
	}
	if path == "" {
		return nil, errors.New("load catalog from filesystem: path is empty")
	}

	file, err := filesystem.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open catalog %q: %w", path, err)
	}
	defer file.Close()

	catalog, err := Load(file)
	if err != nil {
		return nil, fmt.Errorf("load catalog %q: %w", path, err)
	}

	return catalog, nil
}

// LoadFile decodes and validates a catalogue override from the host filesystem.
func LoadFile(path string) (*Catalog, error) {
	if path == "" {
		return nil, errors.New("load catalog file: path is empty")
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open catalog override %q: %w", path, err)
	}
	defer file.Close()

	catalog, err := Load(file)
	if err != nil {
		return nil, fmt.Errorf("load catalog override %q: %w", path, err)
	}

	return catalog, nil
}

// build normalises a decoded document, validates it as a whole, and creates
// the immutable indexes exposed by Catalog.
func build(raw document) (*Catalog, error) {
	entries := make([]Entry, len(raw.Entries))
	for i, rawEntry := range raw.Entries {
		architecture, _ := NormalizeArchitecture(rawEntry.Architecture)
		entries[i] = Entry{
			ID:                 rawEntry.ID,
			Name:               rawEntry.Name,
			Distribution:       rawEntry.Distribution,
			Release:            rawEntry.Release,
			Filename:           rawEntry.Filename,
			Architecture:       architecture,
			ArtifactKind:       rawEntry.ArtifactKind,
			URL:                rawEntry.URL,
			Homepage:           rawEntry.Homepage,
			Adapter:            rawEntry.Adapter,
			SupportLevel:       rawEntry.SupportLevel,
			Checksum:           rawEntry.Checksum,
			CompatibilityNotes: rawEntry.CompatibilityNotes,
			LastVerified:       rawEntry.LastVerified,
		}
		if rawEntry.Experimental != nil {
			entries[i].Experimental = *rawEntry.Experimental
		}
		if rawEntry.Mutable != nil {
			entries[i].Mutable = *rawEntry.Mutable
		}
	}

	if err := validate(raw, entries); err != nil {
		return nil, err
	}

	byID := make(map[string]Entry, len(entries))
	for _, entry := range entries {
		byID[entry.ID] = cloneEntry(entry)
	}

	return &Catalog{
		SchemaVersion: raw.SchemaVersion,
		Description:   raw.Description,
		entries:       entries,
		byID:          byID,
	}, nil
}
