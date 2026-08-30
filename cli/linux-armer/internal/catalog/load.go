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

type document struct {
	SchemaVersion int             `json:"schema_version"`
	Description   string          `json:"description"`
	Entries       []documentEntry `json:"entries"`
}

type documentEntry struct {
	ID                 string       `json:"id"`
	Name               string       `json:"name"`
	Distribution       string       `json:"distribution"`
	Release            string       `json:"release"`
	Architecture       string       `json:"architecture"`
	ArtifactKind       ArtifactKind `json:"artifact_kind"`
	URL                string       `json:"url"`
	Homepage           string       `json:"homepage"`
	Adapter            Adapter      `json:"adapter"`
	SupportLevel       SupportLevel `json:"support_level"`
	Experimental       *bool        `json:"experimental"`
	Mutable            *bool        `json:"mutable"`
	Checksum           *Checksum    `json:"checksum,omitempty"`
	CompatibilityNotes []string     `json:"compatibility_notes"`
	LastVerified       string       `json:"last_verified"`
}

// Loader chooses an on-disk override when one is provided, otherwise it loads
// the catalog bundled in Embedded. This keeps override policy in one place for
// both command-line and interactive callers.
type Loader struct {
	Embedded     fs.FS
	EmbeddedPath string
}

// NewLoader constructs a Loader for a bundled catalog.
func NewLoader(embedded fs.FS, embeddedPath string) Loader {
	return Loader{Embedded: embedded, EmbeddedPath: embeddedPath}
}

// Load reads overridePath when non-empty, or the configured embedded catalog.
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

// Load decodes and validates a catalog from reader.
func Load(reader io.Reader) (*Catalog, error) {
	if reader == nil {
		return nil, errors.New("decode catalog: reader is nil")
	}

	decoder := json.NewDecoder(reader)
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

// LoadBytes decodes and validates a catalog from data.
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

// LoadFile decodes and validates a catalog override from the host filesystem.
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

func build(raw document) (*Catalog, error) {
	entries := make([]Entry, len(raw.Entries))
	for i, rawEntry := range raw.Entries {
		architecture, _ := NormalizeArchitecture(rawEntry.Architecture)
		entries[i] = Entry{
			ID:                 rawEntry.ID,
			Name:               rawEntry.Name,
			Distribution:       rawEntry.Distribution,
			Release:            rawEntry.Release,
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
