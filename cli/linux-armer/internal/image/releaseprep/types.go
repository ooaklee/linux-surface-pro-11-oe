// Package releaseprep prepares and validates closed, local-only release
// directories for linux-armer installation images.
package releaseprep

import (
	"context"
	"io"
	"time"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
)

const (
	// SchemaVersion identifies the release-directory manifest contract.
	SchemaVersion = 1
	// DefaultPartSizeBytes stays below the common two-GiB hosted-release limit.
	DefaultPartSizeBytes int64 = 2_000_000_000
	// HostedAssetLimitBytes is the exclusive maximum for every compressed part.
	HostedAssetLimitBytes int64 = 2_147_483_648
	// ReleaseManifestName is the path-free structured release authority.
	ReleaseManifestName = "image-release-manifest.json"
	// ChecksumName is the exact digest authority for every published file except itself.
	ChecksumName = "SHA256SUMS"
	// NotesName is the deterministic human-readable release guidance.
	NotesName = "RELEASE-NOTES.md"
)

// Validator performs the adapter-owned structural inspection of one complete ISO.
type Validator interface {
	// Validate returns the structural evidence and immutable image identity.
	Validate(context.Context, string) (imagecontract.ValidationReport, error)
}

// Compressor is the narrow deterministic compression boundary used by the
// release workflow and its tests.
type Compressor interface {
	// Compress writes one complete compressed frame and reports the encoder identity.
	Compress(context.Context, io.Reader, io.Writer) (CompressionTool, error)
	// Decompress writes the complete uncompressed stream for identity validation.
	Decompress(context.Context, io.Reader, io.Writer) error
}

// Request contains the complete local image-release preparation decision.
type Request struct {
	// RepositoryRoot bounds source and generated paths to the support repository.
	RepositoryRoot string `json:"repository_root"`
	// ImagePath selects one previously validated linux-armer hybrid ISO.
	ImagePath string `json:"image_path"`
	// OutputDirectory selects a fresh direct child beneath build/release.
	OutputDirectory string `json:"output_directory,omitempty"`
	// ReleaseName supplies the portable local and eventual remote release identity.
	ReleaseName string `json:"release_name,omitempty"`
	// PartSizeBytes is the exclusive upper bound for each compressed part.
	PartSizeBytes int64 `json:"part_size_bytes,omitempty"`
	// DryRun returns a verified plan without structural validation or filesystem writes.
	DryRun bool `json:"dry_run"`
}

// Plan is the immutable, path-bounded preparation decision.
type Plan struct {
	// RepositoryRoot is the canonical source and output security boundary.
	RepositoryRoot string `json:"repository_root"`
	// ImagePath is the canonical, regular source ISO.
	ImagePath string `json:"image_path"`
	// ImageManifestPath is the exact adjacent image-manifest sidecar.
	ImageManifestPath string `json:"image_manifest_path"`
	// ImageJournalPath is the exact adjacent image-creation journal.
	ImageJournalPath string `json:"image_journal_path"`
	// OutputDirectory is the absent final local release directory.
	OutputDirectory string `json:"output_directory"`
	// ReleaseName is the portable release identity.
	ReleaseName string `json:"release_name"`
	// PartSizeBytes bounds every generated compressed part.
	PartSizeBytes int64 `json:"part_size_bytes"`
	// Image identifies the exact source bytes measured during planning.
	Image FileRecord `json:"image"`
	// ImageManifest identifies the exact portable sidecar bytes.
	ImageManifest FileRecord `json:"image_manifest"`
	// ImageJournal identifies the exact creation-journal bytes used as provenance.
	ImageJournal FileRecord `json:"image_journal"`
	// DryRun reports that no external validation, compression, or write will occur.
	DryRun bool `json:"dry_run"`
	// MutatesRemote is always false because this feature never publishes.
	MutatesRemote bool `json:"mutates_remote"`
}

// FileRecord identifies one portable regular file by name, digest, and byte length.
type FileRecord struct {
	// Name is a portable basename without host-directory information.
	Name string `json:"name"`
	// SHA256 is the lowercase digest of the complete file.
	SHA256 string `json:"sha256"`
	// Size is the complete file length in bytes.
	Size int64 `json:"size_bytes"`
}

// CompressionTool records the deterministic encoder settings that created the parts.
type CompressionTool struct {
	// Format is the portable compression format name.
	Format string `json:"format"`
	// Implementation identifies the encoder implementation.
	Implementation string `json:"implementation"`
	// Version is the bounded single-line encoder version.
	Version string `json:"version"`
	// Level is the fixed compression level.
	Level int `json:"level"`
	// Threads is the fixed worker count used for deterministic output.
	Threads int `json:"threads"`
	// ContentChecksum reports whether the compressed frame checks its content.
	ContentChecksum bool `json:"content_checksum"`
}

// DigestRecord expresses one named digest without relying on JSON map ordering.
type DigestRecord struct {
	// Name is the portable journal-local artefact name.
	Name string `json:"name"`
	// SHA256 is its lowercase digest.
	SHA256 string `json:"sha256"`
}

// JournalRecord is a path-free projection of one successful image-creation step.
type JournalRecord struct {
	// StepID identifies the completed operation-plan step.
	StepID string `json:"step_id"`
	// CompletedAt preserves the original UTC checkpoint time.
	CompletedAt time.Time `json:"completed_at"`
	// Digests contains sorted immutable evidence for this step.
	Digests []DigestRecord `json:"digests,omitempty"`
}

// ImageCreationRecord is the public, path-free projection of the private build journal.
type ImageCreationRecord struct {
	// SchemaVersion is the source journal schema.
	SchemaVersion int `json:"schema_version"`
	// Operation is the exact image-creation operation identifier.
	Operation string `json:"operation"`
	// Records contains the original successful checkpoints in order.
	Records []JournalRecord `json:"records"`
	// Output identifies the complete ISO without retaining a host path.
	Output FileRecord `json:"output"`
}

// ValidationCheck records path-free structural evidence safe for publication.
type ValidationCheck struct {
	// Name is the stable adapter-owned check identity.
	Name string `json:"name"`
	// Passed reports whether the invariant held.
	Passed bool `json:"passed"`
}

// ValidationRecord is the deterministic public projection of adapter validation.
type ValidationRecord struct {
	// Valid reports that every adapter-owned check passed.
	Valid bool `json:"valid"`
	// Layout identifies the validated outer media form.
	Layout string `json:"layout"`
	// Adapter identifies the distribution-specific validator.
	Adapter string `json:"adapter"`
	// KernelABI identifies the exact custom kernel used by the image.
	KernelABI string `json:"kernel_abi"`
	// DeviceTrees lists the declared supported device-tree identities.
	DeviceTrees []string `json:"device_trees"`
	// Checks contains ordered, path-free pass evidence.
	Checks []ValidationCheck `json:"checks"`
}

// Manifest is the deterministic, path-free release and provenance authority.
type Manifest struct {
	// SchemaVersion selects this strict release contract.
	SchemaVersion int `json:"schema_version"`
	// ReleaseName is the portable release identity.
	ReleaseName string `json:"release_name"`
	// Image records the original ISO identity.
	Image FileRecord `json:"image"`
	// ImageManifest records the copied single image-manifest sidecar.
	ImageManifest FileRecord `json:"image_manifest"`
	// ImageContract contains the sidecar's decoded, strict image contract.
	ImageContract imagecontract.Manifest `json:"image_contract"`
	// ImageCreation contains the path-free build-journal projection.
	ImageCreation ImageCreationRecord `json:"image_creation"`
	// StructuralValidation contains the path-free adapter evidence.
	StructuralValidation ValidationRecord `json:"structural_validation"`
	// Compression records the exact deterministic encoding policy.
	Compression CompressionTool `json:"compression"`
	// CompressedArchive identifies the recombined compressed frame.
	CompressedArchive FileRecord `json:"compressed_archive"`
	// PartSizeBytes is the requested maximum part size.
	PartSizeBytes int64 `json:"part_size_bytes"`
	// Parts contains every compressed part in lexical and stream order.
	Parts []FileRecord `json:"parts"`
	// RemoteMutation is always false because preparation is local-only.
	RemoteMutation bool `json:"remote_mutation"`
}

// Receipt records one completed local preparation or truthful dry run.
type Receipt struct {
	// Plan is the exact preparation decision.
	Plan Plan `json:"plan"`
	// Manifest is present after successful compression and validation.
	Manifest *Manifest `json:"manifest,omitempty"`
	// Published reports atomic installation of the new local directory.
	Published bool `json:"published"`
}

// ValidationResult records a closed release-directory validation.
type ValidationResult struct {
	// Directory is the canonical validated directory.
	Directory string `json:"directory"`
	// Manifest is the strict release authority read from Directory.
	Manifest Manifest `json:"manifest"`
	// Valid reports that the exact directory, checksums, and decompressed ISO agree.
	Valid bool `json:"valid"`
}

// Manager owns path containment, adapter validation, compression, and publication.
type Manager struct {
	// Validator supplies distribution-owned structural evidence.
	Validator Validator
	// Compressor supplies deterministic compression and streaming decompression.
	Compressor Compressor
}

// New constructs a local image-release manager from explicit boundaries.
func New(validator Validator, compressor Compressor) *Manager {
	return &Manager{Validator: validator, Compressor: compressor}
}
