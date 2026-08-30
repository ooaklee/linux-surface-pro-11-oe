// Package releaseprep prepares and validates local, publication-ready Surface
// Pro 11 kernel release directories without changing a remote service.
package releaseprep

import (
	"context"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/build"
)

const (
	// SchemaVersion identifies the native kernel release manifest contract.
	SchemaVersion = 1
	// ChecksumFileName is the sole checksum authority in a prepared directory.
	ChecksumFileName = "SHA256SUMS"
	// BundleFileName is the path-independent kernel bundle manifest.
	BundleFileName = "linux-armer-kernel-bundle.json"
	// BuildProvenanceFileName is the private native-build provenance input.
	BuildProvenanceFileName = "linux-armer-kernel-build-provenance.json"
	// ReleaseManifestFileName records public source and asset provenance.
	ReleaseManifestFileName = "linux-armer-kernel-release-manifest.json"
	// ReleaseNotesFileName contains the human-readable installation and safety notes.
	ReleaseNotesFileName = "RELEASE-NOTES.md"
)

// AssetKind identifies how one immutable release file satisfies the contract.
type AssetKind string

// Supported asset kinds distinguish executable packages from their required source.
const (
	AssetPackage AssetKind = "package"
	AssetSource  AssetKind = "source"
	AssetLicence AssetKind = "licence"
)

// Request contains every caller-selected local release-preparation input.
type Request struct {
	// BuildDirectory is one completed native kernel build output.
	BuildDirectory string
	// OutputDirectory is a new release directory that must not already exist.
	OutputDirectory string
	// ReleaseName is the intended tag-like public release identity.
	ReleaseName string
	// SourceAssets are corresponding-source archives or records for the exact revision.
	SourceAssets []string
	// LicenceAssets are explicit redistribution and source-licence files.
	LicenceAssets []string
	// DryRun validates and reports the complete decision without writing output.
	DryRun bool
}

// Asset records one immutable file included in the public release directory.
type Asset struct {
	// Name is a portable top-level release filename.
	Name string `json:"name"`
	// Kind explains whether the file is a package, source, or licence asset.
	Kind AssetKind `json:"kind"`
	// Role is present only for one kernel package.
	Role kernel.PackageRole `json:"role,omitempty"`
	// SHA256 is the lowercase digest of the complete file.
	SHA256 string `json:"sha256"`
	// Size is the complete file length in bytes.
	Size int64 `json:"size_bytes"`
}

// PlannedAsset binds a public asset record to its private, prevalidated source path.
type PlannedAsset struct {
	// Asset is the path-independent public identity.
	Asset Asset `json:"asset"`
	// SourcePath is the canonical local input copied during preparation.
	SourcePath string `json:"-"`
}

// SourceProvenance is the public subset of native build provenance. It omits
// the local Docker volume name and every host path.
type SourceProvenance struct {
	// GitURL is the credential-free HTTPS source repository.
	GitURL string `json:"git_url"`
	// GitRef is the branch or tag selected for the build.
	GitRef string `json:"git_ref"`
	// RefKind distinguishes a fetched branch from a fetched tag.
	RefKind string `json:"ref_kind"`
	// Revision is the exact source commit that was built.
	Revision string `json:"revision"`
	// Tree is the exact Git tree identity that was built.
	Tree string `json:"tree"`
	// CommitTime is the recorded upstream commit time.
	CommitTime time.Time `json:"commit_time"`
	// RecipeSHA256 identifies the compiled build policy.
	RecipeSHA256 string `json:"recipe_sha256"`
	// ContainerImage is the immutable ARM64 builder image reference.
	ContainerImage string `json:"container_image"`
	// ToolchainSHA256 identifies the installed builder-package set.
	ToolchainSHA256 string `json:"toolchain_sha256"`
}

// Manifest is the sole public kernel release contract emitted by this domain.
type Manifest struct {
	// SchemaVersion identifies the serialised contract.
	SchemaVersion int `json:"schema_version"`
	// ReleaseName is the intended public release identity.
	ReleaseName string `json:"release_name"`
	// GeneratedAt records when local preparation completed.
	GeneratedAt time.Time `json:"generated_at"`
	// Experimental prevents structural validation being mistaken for qualification.
	Experimental bool `json:"experimental"`
	// HardwareQualified remains false until separately recorded hardware testing exists.
	HardwareQualified bool `json:"hardware_qualified"`
	// ABI is the exact Surface qcom-x1e kernel ABI.
	ABI string `json:"abi"`
	// Version is the coherent Debian package version.
	Version string `json:"version"`
	// Architecture is the package architecture.
	Architecture string `json:"architecture"`
	// Source contains sanitised native build provenance.
	Source SourceProvenance `json:"source"`
	// Assets lists every package, corresponding-source, and licence file.
	Assets []Asset `json:"assets"`
	// BundleFile names the path-independent kernel bundle manifest.
	BundleFile string `json:"bundle_file"`
	// ChecksumFile names the exact checksum authority.
	ChecksumFile string `json:"checksum_file"`
	// NotesFile names the human-readable release notes.
	NotesFile string `json:"notes_file"`
}

// Plan is the complete read-only preparation decision.
type Plan struct {
	// BuildDirectory is the canonical native build input.
	BuildDirectory string `json:"-"`
	// OutputDirectory is the canonical new publication directory.
	OutputDirectory string `json:"-"`
	// DryRun reports whether no filesystem changes may occur.
	DryRun bool `json:"dry_run"`
	// Bundle is the path-independent package contract written on success.
	Bundle kernel.Bundle `json:"bundle"`
	// Manifest is the public release contract written on success.
	Manifest Manifest `json:"manifest"`
	// Inputs bind public identities to canonical local paths.
	Inputs []PlannedAsset `json:"-"`
	// BuildProvenance retains the complete private native-build identity for revalidation.
	BuildProvenance build.Provenance `json:"-"`
}

// Receipt records local publication and durability without implying remote release.
type Receipt struct {
	// Plan is the exact reviewed decision.
	Plan Plan `json:"plan"`
	// Published reports that the new output directory was atomically installed.
	Published bool `json:"published"`
	// Durable reports that the installed directory and parent were flushed.
	Durable bool `json:"durable"`
}

// Manager owns native planning, local publication, and closed-directory validation.
type Manager struct {
	// now supplies deterministic manifest times in tests.
	now func() time.Time
	// beforeCopy is an internal test seam run immediately before each verified copy.
	beforeCopy func(PlannedAsset)
	// beforePublish is an internal test seam run immediately before atomic publication.
	beforePublish func()
}

// New constructs a kernel release-preparation manager.
func New() *Manager {
	return &Manager{now: time.Now}
}

// Plan validates every input and returns a path-safe, non-mutating decision.
func (manager *Manager) Plan(ctx context.Context, request Request) (Plan, error) {
	return manager.plan(ctx, request)
}

// Prepare validates and atomically publishes one new local release directory.
func (manager *Manager) Prepare(ctx context.Context, request Request) (Receipt, error) {
	return manager.prepare(ctx, request)
}

// Validate proves that directory is one exact, closed native release contract.
func (manager *Manager) Validate(ctx context.Context, directory string) (Manifest, error) {
	return validateDirectory(ctx, directory)
}

// publicProvenance removes local build-volume identity from a validated receipt.
func publicProvenance(provenance build.Provenance) SourceProvenance {
	return SourceProvenance{
		GitURL: provenance.GitURL, GitRef: provenance.GitRef, RefKind: provenance.RefKind,
		Revision: provenance.Revision, Tree: provenance.Tree, CommitTime: provenance.CommitTime,
		RecipeSHA256: provenance.RecipeSHA256, ContainerImage: provenance.ContainerImage,
		ToolchainSHA256: provenance.ToolchainSHA256,
	}
}
