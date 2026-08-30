// Package release owns local-only preparation of closed Surface Pro 11 IMX681
// libcamera release directories without publishing or changing a host system.
package release

import (
	"context"
	"time"

	camerabuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/build"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// SchemaVersion identifies the structured local release manifest contract.
	SchemaVersion = 1
	// DefaultOutputDirectory stores fresh locally prepared camera releases.
	DefaultOutputDirectory = "build/linux-armer/camera/releases"
	// ChecksumName is the exact digest authority covering the eight build artefacts.
	ChecksumName = "SHA256SUMS"
	// NotesName is the exact British-English human release record.
	NotesName = "RELEASE-NOTES.md"
	// ManifestName is the exact path-free structured release record.
	ManifestName = "release-manifest.json"
)

// Request contains the complete local release-preparation decision.
type Request struct {
	// RepositoryRoot supplies current HEAD-authenticated camera inputs.
	RepositoryRoot string
	// ArtifactsDirectory is the exact eight-file native build output.
	ArtifactsDirectory string
	// OutputDirectory selects a release parent relative to RepositoryRoot.
	OutputDirectory string
	// Tag names the new local release directory and eventual release identity.
	Tag string
	// KernelTag records the explicitly paired kernel release.
	KernelTag string
	// KernelABI records the explicitly paired installed qcom-x1e ABI.
	KernelABI string
	// ExpectedBuildAuthoritySHA256 is the independent build-receipt hand-off.
	ExpectedBuildAuthoritySHA256 string
	// DryRun returns a truthful plan without validation commands or filesystem writes.
	DryRun bool
}

// Plan is the deterministic local release-preparation decision.
type Plan struct {
	// RepositoryRoot is the canonical support-tree boundary.
	RepositoryRoot string `json:"repository_root"`
	// ArtifactsDirectory is the canonical native build bundle.
	ArtifactsDirectory string `json:"artifacts_directory"`
	// OutputDirectory is the canonical release parent.
	OutputDirectory string `json:"output_directory"`
	// ReleaseDirectory is the fresh final directory selected by Tag.
	ReleaseDirectory string `json:"release_directory"`
	// Tag is the validated release identity.
	Tag string `json:"tag"`
	// KernelTag is the explicitly paired kernel release.
	KernelTag string `json:"kernel_tag"`
	// KernelABI is the explicitly paired installed ABI.
	KernelABI string `json:"kernel_abi"`
	// ExpectedBuildAuthoritySHA256 is the required build-receipt hand-off.
	ExpectedBuildAuthoritySHA256 string `json:"expected_build_authority_sha256"`
	// DryRun reports that no local mutation or package inspection may occur.
	DryRun bool `json:"dry_run"`
	// Executable reports whether static release preparation may proceed.
	Executable bool `json:"executable"`
	// ExecutionBlocker explains why a static preparation cannot proceed.
	ExecutionBlocker string `json:"execution_blocker,omitempty"`
	// MutatesRemote is always false because this domain never publishes.
	MutatesRemote bool `json:"mutates_remote"`
}

// GeneratedFile records one deterministic local release record.
type GeneratedFile struct {
	// Name is the fixed release-relative basename.
	Name string `json:"name"`
	// SHA256 is the complete lowercase file digest.
	SHA256 string `json:"sha256"`
	// Size is the complete byte length.
	Size int64 `json:"size_bytes"`
}

// Manifest is the path-free structured local release authority.
type Manifest struct {
	// SchemaVersion identifies this contract.
	SchemaVersion int `json:"schema_version"`
	// Status reports successful local verification and preparation.
	Status string `json:"status"`
	// Tag is the intended release identity.
	Tag string `json:"tag"`
	// PreparedAt is the UTC preparation time.
	PreparedAt time.Time `json:"prepared_at"`
	// KernelTag is the explicitly paired kernel release.
	KernelTag string `json:"kernel_tag"`
	// KernelABI is the explicitly paired installed ABI.
	KernelABI string `json:"kernel_abi"`
	// BuildReceiptName identifies the included native build provenance.
	BuildReceiptName string `json:"build_receipt_name"`
	// Build embeds the validated, path-free native build authority.
	Build camerabuild.BundleReceipt `json:"build"`
	// BuildArtifacts contains all eight copied build artefacts, including receipt.
	BuildArtifacts []GeneratedFile `json:"build_artifacts"`
	// GeneratedFiles contains SHA256SUMS and the human release notes.
	GeneratedFiles []GeneratedFile `json:"generated_files"`
	// SourceAndLicenceProvenance records the explicit source and terms authority.
	SourceAndLicenceProvenance SourceAndLicenceProvenance `json:"source_and_licence_provenance"`
	// RemoteMutation records the invariant that preparation changes no remote.
	RemoteMutation bool `json:"remote_mutation"`
}

// SourceAndLicenceProvenance summarises redistribution evidence for reviewers.
type SourceAndLicenceProvenance struct {
	// UbuntuSourceURL is the authenticated source package location.
	UbuntuSourceURL string `json:"ubuntu_source_url"`
	// UbuntuSourceSHA256 contains the DSC, orig, and Debian tarball digests.
	UbuntuSourceSHA256 map[string]string `json:"ubuntu_source_sha256"`
	// DebianCopyrightSHA256 identifies debian/copyright from authenticated source.
	DebianCopyrightSHA256 string `json:"debian_copyright_sha256"`
	// Evidence contains explicit, human-readable package terms locations.
	Evidence []string `json:"evidence"`
}

// Receipt records one local preparation attempt and its new closed directory.
type Receipt struct {
	// Plan is the immutable decision used for this invocation.
	Plan Plan `json:"plan"`
	// StartedAt records when preparation handling began.
	StartedAt time.Time `json:"started_at"`
	// CompletedAt records when preparation handling ended.
	CompletedAt time.Time `json:"completed_at"`
	// Manifest is present after complete validation.
	Manifest *Manifest `json:"manifest,omitempty"`
	// AuthoritySHA256 identifies the final path-free release manifest.
	AuthoritySHA256 string `json:"authority_sha256,omitempty"`
	// Published reports atomic installation of the new local directory.
	Published bool `json:"published"`
}

// ValidationRequest selects one locally prepared release and support authority.
type ValidationRequest struct {
	// RepositoryRoot supplies the current support-tree input authority.
	RepositoryRoot string
	// Directory is the exact eleven-file local release directory.
	Directory string
	// ExpectedAuthoritySHA256 is the independent release-manifest hand-off.
	ExpectedAuthoritySHA256 string
}

// ValidationReceipt records a successful repeat of every static release proof.
type ValidationReceipt struct {
	// Directory is the canonical validated release directory.
	Directory string `json:"directory"`
	// ValidatedAt is the UTC completion time.
	ValidatedAt time.Time `json:"validated_at"`
	// Manifest is the exact validated structured release record.
	Manifest Manifest `json:"manifest"`
}

// Manager owns local validation, record generation, and atomic publication.
type Manager struct {
	// Runner executes Git and read-only package inspection only.
	Runner platform.Runner
	// now supplies deterministic manifest times in tests.
	now func() time.Time
	// validate repeats the static build-bundle proof before local publication.
	validate func(context.Context, platform.Runner, camerabuild.ValidationRequest) (camerabuild.BundleReceipt, error)
}

// New constructs a local release manager with direct read-only inspection.
func New(runner platform.Runner) *Manager {
	return newManager(runner)
}

// Plan validates request without running package tools or writing files.
func (manager *Manager) Plan(ctx context.Context, request Request) (Plan, error) {
	return manager.prepare(ctx, request)
}
