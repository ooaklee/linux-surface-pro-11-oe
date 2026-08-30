// Package catalog loads and validates linux-armer's supported installation
// media catalogue.
package catalog

import "sort"

// CurrentSchemaVersion is the only catalogue schema understood by this build.
const CurrentSchemaVersion = 2

// Architecture is a canonical CPU architecture name.
type Architecture string

const (
	// ArchitectureARM64 is the canonical form used by linux-armer. The common
	// aarch64 spelling is normalised to this value while loading a catalogue.
	ArchitectureARM64 Architecture = "arm64"
)

// ArtifactKind describes the on-disk format supplied by a catalogue entry.
type ArtifactKind string

const (
	// ArtifactKindISO denotes optical-media-style ISO 9660 installation media.
	ArtifactKindISO ArtifactKind = "iso"
	// ArtifactKindRawXZ denotes an xz-compressed raw disk image.
	ArtifactKindRawXZ ArtifactKind = "raw-xz"
)

// Adapter identifies the image-specific implementation used to prepare media.
type Adapter string

const (
	// AdapterNone marks media that can be listed but cannot yet be remastered.
	AdapterNone Adapter = "none"
	// AdapterUbuntuCasper selects the Ubuntu Casper live-media remasterer.
	AdapterUbuntuCasper Adapter = "ubuntu-casper"
)

// SupportLevel describes whether linux-armer can currently prepare an entry.
type SupportLevel string

const (
	// SupportLevelImplemented means the CLI has an adapter for the artefact.
	SupportLevelImplemented SupportLevel = "implemented"
	// SupportLevelCatalogOnly means the artefact is discoverable but cannot yet
	// be transformed by this version of the CLI.
	SupportLevelCatalogOnly SupportLevel = "catalog-only"
)

// Checksum is an optional publisher-supplied digest. Value contains hexadecimal
// digits only; the algorithm is not repeated as a value prefix.
type Checksum struct {
	// Algorithm names the digest algorithm used for Value.
	Algorithm string `json:"algorithm"`
	// Value contains only the hexadecimal digest, without an algorithm prefix.
	Value string `json:"value"`
}

// Entry describes one upstream ARM installation artefact.
type Entry struct {
	// ID is the stable, human-editable key used by CLI commands.
	ID string `json:"id"`
	// Name is the distribution-provided display name.
	Name string `json:"name"`
	// Distribution identifies the upstream operating-system family.
	Distribution string `json:"distribution"`
	// Release identifies the upstream version or release channel.
	Release string `json:"release"`
	// Filename is the exact upstream artefact name expected at the URL.
	Filename string `json:"filename"`
	// Architecture is the normalised target CPU architecture.
	Architecture Architecture `json:"architecture"`
	// ArtifactKind describes how the downloaded bytes are packaged.
	ArtifactKind ArtifactKind `json:"artifact_kind"`
	// URL is the HTTPS location of the upstream installation artefact.
	URL string `json:"url"`
	// Homepage is an upstream page where users can learn about the artefact.
	Homepage string `json:"homepage"`
	// Adapter selects the implementation capable of preparing this media.
	Adapter Adapter `json:"adapter"`
	// SupportLevel states whether this CLI version can prepare the artefact.
	SupportLevel SupportLevel `json:"support_level"`
	// Experimental warns that the workflow has not reached stable support.
	Experimental bool `json:"experimental"`
	// Mutable warns that URL contents may change without the URL changing.
	Mutable bool `json:"mutable"`
	// Checksum optionally pins the publisher's artefact bytes.
	Checksum *Checksum `json:"checksum,omitempty"`
	// CompatibilityNotes explain device-specific constraints to users.
	CompatibilityNotes []string `json:"compatibility_notes"`
	// LastVerified is the calendar date on which maintainers checked the entry.
	LastVerified string `json:"last_verified"`
}

// Catalog is an immutable, validated view of a catalogue document.
type Catalog struct {
	// SchemaVersion identifies the validated JSON document contract.
	SchemaVersion int
	// Description explains the catalogue's purpose to maintainers and users.
	Description string

	// entries retains validated entries in document order.
	entries []Entry
	// byID provides stable-ID lookup without exposing mutable internal state.
	byID map[string]Entry
}

// Len returns the number of entries in the catalogue.
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

// cloneEntry copies reference-valued fields so callers cannot mutate catalogue
// state through a returned entry.
func cloneEntry(entry Entry) Entry {
	if entry.Checksum != nil {
		checksum := *entry.Checksum
		entry.Checksum = &checksum
	}
	entry.CompatibilityNotes = append([]string(nil), entry.CompatibilityNotes...)

	return entry
}
