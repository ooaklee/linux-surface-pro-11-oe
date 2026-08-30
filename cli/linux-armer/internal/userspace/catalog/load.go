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
	// maximumCatalogueBytes bounds memory use before any userspace catalogue
	// JSON is decoded or retained for validation.
	maximumCatalogueBytes = 1 << 20
	// maximumCatalogueComponents keeps policy validation and user-facing output
	// bounded when an operator supplies a catalogue override.
	maximumCatalogueComponents = 256
	// maximumComponentNotes bounds each component's human-facing note list.
	maximumComponentNotes = 64
	// maximumReleaseAssets bounds each release's closed asset allow-list.
	maximumReleaseAssets = 256
)

// document mirrors the top-level JSON shape before semantic validation turns it
// into an immutable Catalog.
type document struct {
	// SchemaVersion selects the document contract understood by this binary.
	SchemaVersion int `json:"schema_version"`
	// Description gives maintainers and users a plain-language catalogue summary.
	Description string `json:"description"`
	// Components contains the untrusted component records to validate.
	Components []documentComponent `json:"components"`
}

// documentComponent retains the JSON representation, including pointer-backed
// booleans needed to distinguish an explicit false value from a missing field.
type documentComponent struct {
	ID                    string                 `json:"id"`
	Name                  string                 `json:"name"`
	Level                 Level                  `json:"level"`
	Capability            Capability             `json:"capability"`
	Redistribution        Redistribution         `json:"redistribution"`
	SupportActions        documentSupportActions `json:"support_actions"`
	Release               *Release               `json:"release,omitempty"`
	CompatibilityEvidence CompatibilityEvidence  `json:"compatibility_evidence"`
	KernelCompatibility   *KernelCompatibility   `json:"kernel_compatibility,omitempty"`
	Notes                 []string               `json:"notes"`
	Remediation           string                 `json:"remediation"`
}

// documentSupportActions preserves whether every required action flag appeared
// in JSON; the public SupportActions model intentionally contains plain booleans.
type documentSupportActions struct {
	Status  *bool `json:"status"`
	Pull    *bool `json:"pull"`
	Build   *bool `json:"build"`
	Install *bool `json:"install"`
}

// Loader selects an on-disk override when one is supplied, otherwise it loads
// a catalogue from its configured embedded filesystem.
type Loader struct {
	// Embedded is the read-only filesystem containing the bundled catalogue.
	Embedded fs.FS
	// EmbeddedPath locates the catalogue document inside Embedded.
	EmbeddedPath string
}

// NewLoader constructs a userspace catalogue Loader.
func NewLoader(embedded fs.FS, embeddedPath string) Loader {
	return Loader{Embedded: embedded, EmbeddedPath: embeddedPath}
}

// Load reads overridePath when non-empty, or the configured embedded catalogue.
func (l Loader) Load(overridePath string) (*Catalog, error) {
	if overridePath != "" {
		return LoadFile(overridePath)
	}
	if l.Embedded == nil {
		return nil, errors.New("load embedded userspace catalog: filesystem is nil")
	}
	if l.EmbeddedPath == "" {
		return nil, errors.New("load embedded userspace catalog: path is empty")
	}
	return LoadFS(l.Embedded, l.EmbeddedPath)
}

// Load decodes and validates a userspace catalogue from reader.
func Load(reader io.Reader) (*Catalog, error) {
	if reader == nil {
		return nil, errors.New("decode userspace catalog: reader is nil")
	}
	data, err := io.ReadAll(io.LimitReader(reader, maximumCatalogueBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read userspace catalog JSON: %w", err)
	}
	if len(data) > maximumCatalogueBytes {
		return nil, fmt.Errorf("decode userspace catalog JSON: document exceeds %d bytes", maximumCatalogueBytes)
	}
	if !utf8.Valid(data) {
		return nil, errors.New("decode userspace catalog JSON: document is not valid UTF-8")
	}
	if err := validateDocumentShape(data); err != nil {
		return nil, fmt.Errorf("decode userspace catalog JSON: %w", err)
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()

	var raw document
	if err := decoder.Decode(&raw); err != nil {
		return nil, fmt.Errorf("decode userspace catalog JSON: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return nil, errors.New("decode userspace catalog JSON: multiple JSON values are not allowed")
		}
		return nil, fmt.Errorf("decode userspace catalog JSON after first value: %w", err)
	}
	return build(raw)
}

// validateDocumentShape rejects ambiguous object keys and excessive component
// or nested-list counts before decoding into Go structures.
func validateDocumentShape(data []byte) error {
	documentFields, err := decodeExactObject(data, "userspace catalog", []string{
		"schema_version", "description", "components",
	})
	if err != nil {
		return err
	}
	componentsData, found := documentFields["components"]
	if !found {
		return nil
	}
	components, err := decodeBoundedArray(componentsData, "components", maximumCatalogueComponents)
	if err != nil {
		return err
	}
	for index, componentData := range components {
		componentPath := fmt.Sprintf("components[%d]", index)
		componentFields, err := decodeExactObject(componentData, componentPath, []string{
			"id", "name", "level", "capability", "redistribution", "support_actions",
			"release", "compatibility_evidence", "kernel_compatibility", "notes", "remediation",
		})
		if err != nil {
			return err
		}

		if actionsData, ok := componentFields["support_actions"]; ok {
			if _, err := decodeExactObject(actionsData, componentPath+".support_actions", []string{
				"status", "pull", "build", "install",
			}); err != nil {
				return err
			}
		}
		if releaseData, ok := componentFields["release"]; ok && !isJSONNull(releaseData) {
			releaseFields, err := decodeExactObject(releaseData, componentPath+".release", []string{
				"url", "tag", "asset_allowlist",
			})
			if err != nil {
				return err
			}
			if assetsData, ok := releaseFields["asset_allowlist"]; ok {
				if _, err := decodeBoundedArray(assetsData, componentPath+".release.asset_allowlist", maximumReleaseAssets); err != nil {
					return err
				}
			}
		}
		if compatibilityData, ok := componentFields["kernel_compatibility"]; ok && !isJSONNull(compatibilityData) {
			if _, err := decodeExactObject(compatibilityData, componentPath+".kernel_compatibility", []string{
				"minimum_sp11_generation", "tested_through_sp11_generation", "summary",
			}); err != nil {
				return err
			}
		}
		if notesData, ok := componentFields["notes"]; ok {
			if _, err := decodeBoundedArray(notesData, componentPath+".notes", maximumComponentNotes); err != nil {
				return err
			}
		}
	}
	return nil
}

// isJSONNull reports whether one raw field explicitly contains JSON null.
func isJSONNull(data []byte) bool {
	return bytes.Equal(bytes.TrimSpace(data), []byte("null"))
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

// decodeBoundedArray decodes one raw JSON array while rejecting an item count
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

// LoadBytes decodes and validates a userspace catalogue from data.
func LoadBytes(data []byte) (*Catalog, error) {
	return Load(bytes.NewReader(data))
}

// LoadFS decodes and validates path from filesystem.
func LoadFS(filesystem fs.FS, path string) (*Catalog, error) {
	if filesystem == nil {
		return nil, errors.New("load userspace catalog from filesystem: filesystem is nil")
	}
	if path == "" {
		return nil, errors.New("load userspace catalog from filesystem: path is empty")
	}
	file, err := filesystem.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open userspace catalog %q: %w", path, err)
	}
	defer file.Close()
	catalog, err := Load(file)
	if err != nil {
		return nil, fmt.Errorf("load userspace catalog %q: %w", path, err)
	}
	return catalog, nil
}

// LoadFile decodes and validates an on-disk userspace catalogue.
func LoadFile(path string) (*Catalog, error) {
	if path == "" {
		return nil, errors.New("load userspace catalog file: path is empty")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open userspace catalog override %q: %w", path, err)
	}
	defer file.Close()
	catalog, err := Load(file)
	if err != nil {
		return nil, fmt.Errorf("load userspace catalog override %q: %w", path, err)
	}
	return catalog, nil
}

// build converts a decoded document into defensive public models, validates the
// complete result, and only then constructs the catalogue lookup index.
func build(raw document) (*Catalog, error) {
	components := make([]Component, len(raw.Components))
	for index, rawComponent := range raw.Components {
		component := Component{
			ID:                    rawComponent.ID,
			Name:                  rawComponent.Name,
			Level:                 rawComponent.Level,
			Capability:            rawComponent.Capability,
			Redistribution:        rawComponent.Redistribution,
			Release:               rawComponent.Release,
			CompatibilityEvidence: rawComponent.CompatibilityEvidence,
			KernelCompatibility:   rawComponent.KernelCompatibility,
			Notes:                 rawComponent.Notes,
			Remediation:           rawComponent.Remediation,
		}
		if rawComponent.SupportActions.Status != nil {
			component.SupportActions.Status = *rawComponent.SupportActions.Status
		}
		if rawComponent.SupportActions.Pull != nil {
			component.SupportActions.Pull = *rawComponent.SupportActions.Pull
		}
		if rawComponent.SupportActions.Build != nil {
			component.SupportActions.Build = *rawComponent.SupportActions.Build
		}
		if rawComponent.SupportActions.Install != nil {
			component.SupportActions.Install = *rawComponent.SupportActions.Install
		}
		components[index] = component
	}
	if err := validate(raw, components); err != nil {
		return nil, err
	}
	byID := make(map[string]Component, len(components))
	for _, component := range components {
		byID[component.ID] = cloneComponent(component)
	}
	return &Catalog{
		SchemaVersion: raw.SchemaVersion,
		Description:   raw.Description,
		components:    components,
		byID:          byID,
	}, nil
}
