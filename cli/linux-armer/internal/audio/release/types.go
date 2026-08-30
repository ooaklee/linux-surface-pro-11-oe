// Package release prepares and validates closed, local-only Surface Pro 11
// FullIO audio release directories without changing a remote service.
package release

import "context"

const (
	// SchemaVersion identifies the strict structured audio release contract.
	SchemaVersion = 1
	// DefaultOutputDirectory is the fixed repository-relative release parent.
	DefaultOutputDirectory = "build/release"
	// ManifestName is the path-free structured release authority.
	ManifestName = "audio-release-manifest.json"
	// ChecksumName is the checksum authority for the four installable artefacts.
	ChecksumName = "SHA256SUMS"
	// NotesName is the deterministic British-English release guide.
	NotesName = "RELEASE-NOTES.md"
)

// Request contains the complete local audio release preparation decision.
type Request struct {
	// RepositoryRoot bounds the fixed build/release destination.
	RepositoryRoot string `json:"repository_root"`
	// SourceRoot selects the explicit SP11X1e-audio checkout.
	SourceRoot string `json:"source_root"`
	// Tag supplies the new local release identity.
	Tag string `json:"tag"`
	// KernelTag identifies the explicitly paired kernel release.
	KernelTag string `json:"kernel_tag"`
	// KernelABI identifies the explicitly paired installed qcom-x1e ABI.
	KernelABI string `json:"kernel_abi"`
	// DryRun validates inputs and returns the plan without writing output.
	DryRun bool `json:"dry_run"`
}

// Plan is the immutable, path-bounded local preparation decision.
type Plan struct {
	// RepositoryRoot is the canonical local support-repository boundary.
	RepositoryRoot string `json:"repository_root"`
	// SourceRoot is the canonical, explicit audio source checkout.
	SourceRoot string `json:"source_root"`
	// ReleaseDirectory is the absent fixed local release destination.
	ReleaseDirectory string `json:"release_directory"`
	// Tag is the portable release identity.
	Tag string `json:"tag"`
	// KernelTag is the explicitly paired kernel release.
	KernelTag string `json:"kernel_tag"`
	// KernelABI is the explicitly paired installed ABI.
	KernelABI string `json:"kernel_abi"`
	// KernelGeneration is the matching sp11v generation number.
	KernelGeneration int `json:"kernel_generation"`
	// Source records path-free validation of the pinned checkout inputs.
	Source SourceProvenance `json:"source"`
	// DryRun reports that no filesystem publication will occur.
	DryRun bool `json:"dry_run"`
	// Executable reports whether this build supports atomic no-replace publication.
	Executable bool `json:"executable"`
	// ExecutionBlocker explains why publication is unavailable when applicable.
	ExecutionBlocker string `json:"execution_blocker,omitempty"`
	// MutatesRemote is always false because this workflow is local-only.
	MutatesRemote bool `json:"mutates_remote"`
}

// FileRecord identifies one portable regular file by digest and byte length.
type FileRecord struct {
	// Name is a portable basename without host-directory information.
	Name string `json:"name"`
	// SHA256 is the lowercase digest of the complete file.
	SHA256 string `json:"sha256"`
	// Size is the complete byte length.
	Size int64 `json:"size_bytes"`
}

// SourceInput records one role-specific, pinned source identity.
type SourceInput struct {
	// Role is the stable semantic purpose of the source file.
	Role string `json:"role"`
	// File contains only the portable source basename and immutable identity.
	File FileRecord `json:"file"`
}

// SourceProvenance is the path-free validation record for the source checkout.
type SourceProvenance struct {
	// Release identifies the reviewed upstream audio release.
	Release string `json:"release"`
	// Revision identifies the reviewed upstream source commit.
	Revision string `json:"revision"`
	// ChecksumManifest identifies the validated source SHA256SUMS bytes.
	ChecksumManifest FileRecord `json:"checksum_manifest"`
	// ValidatedChecksums records every bounded source-manifest entry in name order.
	ValidatedChecksums []FileRecord `json:"validated_checksums"`
	// Inputs records the four role-specific pinned inputs in deterministic order.
	Inputs []SourceInput `json:"inputs"`
}

// Manifest is the deterministic, path-free local audio release authority.
type Manifest struct {
	// SchemaVersion selects this strict release contract.
	SchemaVersion int `json:"schema_version"`
	// Status reports successful local preparation and validation.
	Status string `json:"status"`
	// Tag is the intended release identity and directory basename.
	Tag string `json:"tag"`
	// KernelTag is the explicitly paired kernel release.
	KernelTag string `json:"kernel_tag"`
	// KernelABI is the explicitly paired installed ABI.
	KernelABI string `json:"kernel_abi"`
	// KernelGeneration is the matching sp11v generation number.
	KernelGeneration int `json:"kernel_generation"`
	// Source records the validated, path-free source provenance.
	Source SourceProvenance `json:"source"`
	// Artefacts identifies the exact four installable release payloads.
	Artefacts []FileRecord `json:"artefacts"`
	// GeneratedFiles identifies SHA256SUMS and the release notes.
	GeneratedFiles []FileRecord `json:"generated_files"`
	// ProtectedVendorBytes records the explicit redistribution boundary.
	ProtectedVendorBytes bool `json:"protected_vendor_bytes"`
	// RemoteMutation is always false because preparation never publishes remotely.
	RemoteMutation bool `json:"remote_mutation"`
}

// Receipt records one completed local preparation or truthful dry run.
type Receipt struct {
	// Plan is the exact preparation decision and validated source authority.
	Plan Plan `json:"plan"`
	// Manifest is present after successful local publication.
	Manifest *Manifest `json:"manifest,omitempty"`
	// Published reports atomic installation of the fresh release directory.
	Published bool `json:"published"`
}

// ValidationRequest selects one local release directory beneath a repository.
type ValidationRequest struct {
	// RepositoryRoot bounds the fixed build/release destination.
	RepositoryRoot string `json:"repository_root"`
	// Directory is the exact local release directory to inspect.
	Directory string `json:"directory"`
}

// ValidationReceipt records successful repetition of every local proof.
type ValidationReceipt struct {
	// Directory is the canonical validated local release directory.
	Directory string `json:"directory"`
	// Manifest is the exact strict structured authority from Directory.
	Manifest Manifest `json:"manifest"`
	// Valid reports that the closed file set and every digest agree.
	Valid bool `json:"valid"`
}

// Manager owns bounded source validation, generation, and local publication.
type Manager struct {
	// policy is the compiled release contract selected at construction.
	policy policy
	// afterPlan is a test seam before any snapshotted source is copied.
	afterPlan func(Plan) error
	// beforePublish is a test seam immediately before cancellation and publication.
	beforePublish func(context.Context, Plan) error
}

// New constructs a manager using the reviewed FullIO v19c release contract.
func New() *Manager {
	return newManagerWithPolicy(productionPolicy())
}

// newManagerWithPolicy constructs a manager around a complete immutable policy.
func newManagerWithPolicy(selected policy) *Manager {
	return &Manager{policy: selected}
}
