package catalog

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
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
	decoder := json.NewDecoder(reader)
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
