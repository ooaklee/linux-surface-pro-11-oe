// Package catalog loads and validates linux-armer's supported installation
// media catalog.
package catalog

import "sort"

// CurrentSchemaVersion is the only catalog schema understood by this build.
const CurrentSchemaVersion = 1

// Architecture is a canonical CPU architecture name.
type Architecture string

const (
	// ArchitectureARM64 is the canonical form used by linux-armer. The common
	// aarch64 spelling is normalized to this value while loading a catalog.
	ArchitectureARM64 Architecture = "arm64"
)

// ArtifactKind describes the on-disk format supplied by a catalog entry.
type ArtifactKind string

const (
	ArtifactKindISO   ArtifactKind = "iso"
	ArtifactKindRawXZ ArtifactKind = "raw-xz"
)

// Adapter identifies the image-specific implementation used to prepare media.
type Adapter string

const (
	AdapterNone         Adapter = "none"
	AdapterUbuntuCasper Adapter = "ubuntu-casper"
)

// SupportLevel describes whether linux-armer can currently prepare an entry.
type SupportLevel string

const (
	SupportLevelImplemented SupportLevel = "implemented"
	SupportLevelCatalogOnly SupportLevel = "catalog-only"
)

// Checksum is an optional publisher-supplied digest. Value contains hexadecimal
// digits only; the algorithm is not repeated as a value prefix.
type Checksum struct {
	Algorithm string `json:"algorithm"`
	Value     string `json:"value"`
}

// Entry describes one upstream ARM installation artifact.
type Entry struct {
	ID                 string       `json:"id"`
	Name               string       `json:"name"`
	Distribution       string       `json:"distribution"`
	Release            string       `json:"release"`
	Architecture       Architecture `json:"architecture"`
	ArtifactKind       ArtifactKind `json:"artifact_kind"`
	URL                string       `json:"url"`
	Homepage           string       `json:"homepage"`
	Adapter            Adapter      `json:"adapter"`
	SupportLevel       SupportLevel `json:"support_level"`
	Experimental       bool         `json:"experimental"`
	Mutable            bool         `json:"mutable"`
	Checksum           *Checksum    `json:"checksum,omitempty"`
	CompatibilityNotes []string     `json:"compatibility_notes"`
	LastVerified       string       `json:"last_verified"`
}

// Catalog is an immutable, validated view of a catalog document.
type Catalog struct {
	SchemaVersion int
	Description   string

	entries []Entry
	byID    map[string]Entry
}

// Len returns the number of entries in the catalog.
func (c *Catalog) Len() int {
	if c == nil {
		return 0
	}

	return len(c.entries)
}

// List returns defensive copies of all entries, sorted by stable ID.
func (c *Catalog) List() []Entry {
	if c == nil {
		return nil
	}

	entries := make([]Entry, 0, len(c.entries))
	for _, entry := range c.entries {
		entries = append(entries, cloneEntry(entry))
	}
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].ID < entries[j].ID
	})

	return entries
}

// Get returns a defensive copy of the entry with id.
func (c *Catalog) Get(id string) (Entry, bool) {
	if c == nil {
		return Entry{}, false
	}

	entry, ok := c.byID[id]
	if !ok {
		return Entry{}, false
	}

	return cloneEntry(entry), true
}

func cloneEntry(entry Entry) Entry {
	if entry.Checksum != nil {
		checksum := *entry.Checksum
		entry.Checksum = &checksum
	}
	entry.CompatibilityNotes = append([]string(nil), entry.CompatibilityNotes...)

	return entry
}
