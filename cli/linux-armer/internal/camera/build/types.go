// Package build owns the native, containerised Surface Pro 11 IMX681
// libcamera package build and its closed output contract.
package build

import (
	"context"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// SchemaVersion identifies the public structured build receipt contract.
	SchemaVersion = 1
	// ReceiptName is the sole structured provenance record in a package bundle.
	ReceiptName = "sp11-imx681-libcamera-build.json"
	// ContainerImage is the immutable Ubuntu 26.04 builder selected by policy.
	ContainerImage = "docker.io/library/ubuntu@sha256:61b65dc6bddff5e68c552f22126fe77496395f956ff2e983e05d8a52efd63e55"
	// DefaultWorkDirectory stores private, disposable camera build exchanges.
	DefaultWorkDirectory = "build/linux-armer/camera/work"
	// DefaultOutputDirectory stores new immutable camera package-set directories.
	DefaultOutputDirectory = "build/linux-armer/camera/packages"
	// DefaultMinimumFreeGiB preserves the established camera build space guard.
	DefaultMinimumFreeGiB = 20
	// DefaultJobs bounds default package-build parallelism.
	DefaultJobs = 8
	// SourcePackage is the only Debian source package accepted by this domain.
	SourcePackage = "libcamera"
	// Architecture is the only Debian package architecture accepted by this domain.
	Architecture = "arm64"
)

// inputPaths is the exact support-tree input set authenticated against HEAD.
var inputPaths = []string{
	"userspace/camera/libcamera/BASE.txt",
	"userspace/camera/libcamera/0001-libipa-add-imx681-simple-ipa-support.patch",
	"userspace/camera/libcamera/imx681.yaml",
}

// runtimePackages is the exact coherent runtime package allow-list.
var runtimePackages = []string{
	"libcamera0.7",
	"libcamera-ipa",
	"libcamera-tools",
	"libcamera-v4l2",
	"gstreamer1.0-libcamera",
}

// TrackedInputPaths returns a copy of the fixed support-tree input allow-list.
func TrackedInputPaths() []string {
	return append([]string(nil), inputPaths...)
}

// RuntimePackageNames returns a copy of the coherent runtime package allow-list.
func RuntimePackageNames() []string {
	return append([]string(nil), runtimePackages...)
}

// Request contains the complete caller-selected native camera build inputs.
type Request struct {
	// RepositoryRoot contains the authenticated support inputs and build roots.
	RepositoryRoot string
	// WorkDirectory selects a private path relative to RepositoryRoot.
	WorkDirectory string
	// OutputDirectory selects a publication root relative to RepositoryRoot.
	OutputDirectory string
	// Jobs limits compilation parallelism from one through 64.
	Jobs int
	// MinimumFreeGiB is the required free space in the container exchange.
	MinimumFreeGiB int
	// NoPull requires the immutable builder image to exist locally already.
	NoPull bool
	// DryRun returns a truthful plan without Docker or filesystem mutation.
	DryRun bool
}

// Command records one argument-separated host process invocation.
type Command struct {
	// Name is the fixed executable selected by compiled policy.
	Name string `json:"name"`
	// Args contains distinct arguments without host-shell interpretation.
	Args []string `json:"args"`
}

// Plan is the deterministic, read-only native camera build decision.
type Plan struct {
	// RepositoryRoot is the canonical support-tree containment boundary.
	RepositoryRoot string `json:"repository_root"`
	// WorkDirectory is the canonical private transaction root.
	WorkDirectory string `json:"work_directory"`
	// OutputDirectory is the canonical parent for a new package-set directory.
	OutputDirectory string `json:"output_directory"`
	// Jobs is the bounded container build parallelism.
	Jobs int `json:"jobs"`
	// MinimumFreeGiB is the bounded container free-space requirement.
	MinimumFreeGiB int `json:"minimum_free_gib"`
	// NoPull reports whether network-backed image acquisition is forbidden.
	NoPull bool `json:"no_pull"`
	// DryRun reports that no host or Docker mutation may occur.
	DryRun bool `json:"dry_run"`
	// Executable reports whether this host can run the native ARM64 proof.
	Executable bool `json:"executable"`
	// ExecutionBlocker explains why an otherwise valid dry-run cannot execute.
	ExecutionBlocker string `json:"execution_blocker,omitempty"`
	// ContainerImage is the immutable reviewed Ubuntu 26.04 image.
	ContainerImage string `json:"container_image"`
	// RecipeSHA256 identifies the complete embedded container policy.
	RecipeSHA256 string `json:"recipe_sha256"`
	// PublicationPattern describes the fresh child directory selected at run time.
	PublicationPattern string `json:"publication_pattern"`
	// Commands previews the argument-separated image and container operations.
	Commands []Command `json:"commands"`
}

// InputProvenance binds one regular support-tree input to exact HEAD bytes.
type InputProvenance struct {
	// Path is the repository-relative fixed input path.
	Path string `json:"path"`
	// SHA256 is the digest shared by HEAD and the work tree.
	SHA256 string `json:"sha256"`
}

// SourceProvenance records the authenticated Ubuntu and upstream source identity.
type SourceProvenance struct {
	// UpstreamRepository is the canonical libcamera source repository.
	UpstreamRepository string `json:"upstream_repository"`
	// UpstreamTag is the recorded upstream release tag.
	UpstreamTag string `json:"upstream_tag"`
	// UpstreamCommit is the recorded upstream commit.
	UpstreamCommit string `json:"upstream_commit"`
	// UbuntuVersion is the exact source package version.
	UbuntuVersion string `json:"ubuntu_version"`
	// UbuntuSeries is the exact Ubuntu source series.
	UbuntuSeries string `json:"ubuntu_series"`
	// SourceURL is the fixed HTTPS directory used for source acquisition.
	SourceURL string `json:"source_url"`
	// DSC contains the authenticated Debian source control artefact.
	DSC SourceFile `json:"dsc"`
	// OrigTarball contains the authenticated upstream source tarball.
	OrigTarball SourceFile `json:"orig_tarball"`
	// DebianTarball contains the authenticated Debian packaging tarball.
	DebianTarball SourceFile `json:"debian_tarball"`
	// CopyrightFileSHA256 identifies debian/copyright from the extracted source.
	CopyrightFileSHA256 string `json:"copyright_file_sha256"`
	// CopyrightFileSize records the extracted debian/copyright byte length.
	CopyrightFileSize int64 `json:"copyright_file_size_bytes"`
	// LicenceEvidence explains where redistributed package terms are recorded.
	LicenceEvidence []string `json:"licence_evidence"`
}

// SourceFile records one authenticated downloaded source artefact.
type SourceFile struct {
	// Name is the fixed basename beneath SourceURL.
	Name string `json:"name"`
	// SHA256 is the lowercase digest authenticated before extraction.
	SHA256 string `json:"sha256"`
}

// BuilderProvenance records the fixed recipe and observed native builder.
type BuilderProvenance struct {
	// ContainerImage is the immutable requested builder image reference.
	ContainerImage string `json:"container_image"`
	// ImageID is the immutable locally observed image object.
	ImageID string `json:"image_id"`
	// DockerServerVersion is the observed engine version.
	DockerServerVersion string `json:"docker_server_version"`
	// Architecture is the independently checked Docker server architecture.
	Architecture string `json:"architecture"`
	// OperatingSystem is the independently checked Docker server operating system.
	OperatingSystem string `json:"operating_system"`
	// RecipeSHA256 identifies the reviewed embedded build policy.
	RecipeSHA256 string `json:"recipe_sha256"`
	// ToolchainSHA256 identifies sorted installed container package versions.
	ToolchainSHA256 string `json:"toolchain_sha256"`
	// Jobs is the bounded parallelism used by dpkg-buildpackage.
	Jobs int `json:"jobs"`
}

// Artifact records one selected Debian build output.
type Artifact struct {
	// Name is the validated package record basename.
	Name string `json:"name"`
	// SHA256 is the lowercase digest of the complete file.
	SHA256 string `json:"sha256"`
	// Size records the complete file length in bytes.
	Size int64 `json:"size_bytes"`
}

// ChangesEntry records complete accounting for one Checksums-Sha256 entry.
type ChangesEntry struct {
	// Artifact contains the Debian changes entry name, digest, and size.
	Artifact Artifact `json:"artifact"`
	// Delivered reports whether the bounded runtime bundle contains the file.
	Delivered bool `json:"delivered"`
}

// Verification records the independently repeated host checks.
type Verification struct {
	// ChangesClosedSet reports that every changes entry was accounted for.
	ChangesClosedSet bool `json:"changes_closed_set"`
	// DeliveredChangesVerified reports that every selected file matched changes.
	DeliveredChangesVerified bool `json:"delivered_changes_verified"`
	// TuningIdentityVerified reports that packaged tuning matched the HEAD input.
	TuningIdentityVerified bool `json:"tuning_identity_verified"`
	// SameBuildIPAVerified reports that the paired core accepted the IPA signature.
	SameBuildIPAVerified bool `json:"same_build_ipa_verified"`
}

// BundleReceipt is the public, path-free provenance record stored with packages.
type BundleReceipt struct {
	// SchemaVersion identifies this structured contract.
	SchemaVersion int `json:"schema_version"`
	// Status is verified only after every independent host check passes.
	Status string `json:"status"`
	// BuildID uniquely identifies this fresh build without identifying the host.
	BuildID string `json:"build_id"`
	// PackageVersion is shared by all five selected runtime packages.
	PackageVersion string `json:"package_version"`
	// BuiltAt is the UTC start time selected before Docker execution.
	BuiltAt time.Time `json:"built_at"`
	// SupportCommit is the exact support-tree HEAD supplying all three inputs.
	SupportCommit string `json:"support_commit"`
	// SupportCommitTime is the recorded timestamp of SupportCommit.
	SupportCommitTime time.Time `json:"support_commit_time"`
	// Inputs contains exactly the three HEAD-authenticated support assets.
	Inputs []InputProvenance `json:"inputs"`
	// Source records downloaded-source identity and licence evidence.
	Source SourceProvenance `json:"source"`
	// Builder records the immutable policy and observed native Docker engine.
	Builder BuilderProvenance `json:"builder"`
	// Artifacts contains the five packages plus changes and buildinfo records.
	Artifacts []Artifact `json:"artifacts"`
	// ChangesEntries accounts for every entry in the unmodified changes record.
	ChangesEntries []ChangesEntry `json:"changes_entries"`
	// Verification records the four independent closed-set proofs.
	Verification Verification `json:"verification"`
}

// ExecutionReceipt records local planning, execution, cleanup, and publication.
type ExecutionReceipt struct {
	// Plan is the immutable decision used for this invocation.
	Plan Plan `json:"plan"`
	// StartedAt records when build handling began.
	StartedAt time.Time `json:"started_at"`
	// CompletedAt records when build handling finished.
	CompletedAt time.Time `json:"completed_at"`
	// Executed contains only host commands handed to the process runner.
	Executed []Command `json:"executed,omitempty"`
	// Bundle is present after successful closed-set validation.
	Bundle *BundleReceipt `json:"bundle,omitempty"`
	// OutputDirectory is the newly published package-set directory.
	OutputDirectory string `json:"output_directory,omitempty"`
	// AuthoritySHA256 identifies the final path-free structured bundle receipt.
	AuthoritySHA256 string `json:"authority_sha256,omitempty"`
	// Cleanup records bounded forced container removal after a failed run.
	Cleanup *Command `json:"cleanup,omitempty"`
	// Interrupted reports cancellation of the caller context.
	Interrupted bool `json:"interrupted"`
	// Published reports successful atomic local publication.
	Published bool `json:"published"`
}

// Manager owns planning, Docker execution, validation, and atomic publication.
type Manager struct {
	// Runner executes only compiled, argument-separated host commands.
	Runner platform.Runner
	// now supplies deterministic build and receipt times in tests.
	now func() time.Time
	// token supplies a collision-resistant build and container identifier.
	token func() (string, error)
	// hostOS identifies the host operating system for native execution policy.
	hostOS string
	// hostArchitecture identifies the host architecture for native execution policy.
	hostArchitecture string
	// beforeAuthorityCheck is an internal hostile-mutation test hook invoked
	// after publication but before the precomputed receipt digest is endorsed.
	beforeAuthorityCheck func(string) error
}

// New constructs a native camera build manager with direct execution by default.
func New(runner platform.Runner) *Manager {
	return newManager(runner)
}

// Plan validates request and returns a deterministic read-only build decision.
func (manager *Manager) Plan(ctx context.Context, request Request) (Plan, error) {
	return manager.prepare(ctx, request)
}
