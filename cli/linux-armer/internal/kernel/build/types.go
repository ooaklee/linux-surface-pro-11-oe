// Package build owns the compiled container policy for compiling Surface
// Pro 11 kernel packages without relying on repository helper scripts.
package build

import (
	"context"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// SchemaVersion identifies the native kernel build plan and receipt contract.
	SchemaVersion = 1
	// DefaultGitURL is the maintained Surface Pro 11 kernel source.
	DefaultGitURL = "https://github.com/ooaklee/linux_ms_dev_kit-sp11"
	// DefaultGitBranch is the maintained integration branch used by default.
	DefaultGitBranch = "sp11/integration-7.2.x"
	// DefaultWorkDirectory stores private host-side build transactions.
	DefaultWorkDirectory = "build/linux-armer/kernel-build"
	// DefaultOutputDirectory receives one newly published package set.
	DefaultOutputDirectory = "build/linux-armer/kernel"
	// ContainerImage is the immutable Ubuntu 26.04 ARM64 userspace selected for builds.
	ContainerImage = "docker.io/library/ubuntu@sha256:61b65dc6bddff5e68c552f22126fe77496395f956ff2e983e05d8a52efd63e55"
)

// Request contains the complete caller-selected native kernel build inputs.
type Request struct {
	// RepositoryRoot contains both the private work and new output directories.
	RepositoryRoot string
	// GitURL selects an HTTPS kernel source repository.
	GitURL string
	// GitBranch selects one branch or tag from the source repository.
	GitBranch string
	// WorkDirectory stores private transactions relative to RepositoryRoot.
	WorkDirectory string
	// OutputDirectory names a new publication directory relative to RepositoryRoot.
	OutputDirectory string
	// Jobs limits parallel compilation; zero lets the container select its CPU count.
	Jobs int
	// ResetSource permits cleanup only inside the labelled Docker work volume.
	ResetSource bool
	// SkipClean reuses build products in the owned Docker work volume.
	SkipClean bool
	// DryRun returns the complete read-only plan without invoking Docker or writing files.
	DryRun bool
}

// Command records one argument-separated host process invocation.
type Command struct {
	// Name is the fixed executable selected by compiled policy.
	Name string `json:"name"`
	// Args contains distinct, bounded arguments without host-shell interpretation.
	Args []string `json:"args"`
}

// Plan is the complete read-only native container build decision.
type Plan struct {
	// SchemaVersion identifies the serialised plan contract.
	SchemaVersion int `json:"schema_version"`
	// RepositoryRoot is the canonical containment boundary.
	RepositoryRoot string `json:"repository_root"`
	// WorkDirectory is the canonical private host work directory.
	WorkDirectory string `json:"work_directory"`
	// OutputDirectory is the canonical, initially absent publication directory.
	OutputDirectory string `json:"output_directory"`
	// GitURL is the validated HTTPS source repository.
	GitURL string `json:"git_url"`
	// GitRef is the validated requested branch or tag.
	GitRef string `json:"git_ref"`
	// Jobs is the requested parallelism, or zero for container auto-detection.
	Jobs int `json:"jobs"`
	// ResetSource permits cleanup only inside the labelled work volume.
	ResetSource bool `json:"reset_source"`
	// SkipClean omits the Debian clean target before compilation.
	SkipClean bool `json:"skip_clean"`
	// DryRun reports that no host or Docker mutation may occur.
	DryRun bool `json:"dry_run"`
	// ContainerImage is the compiled ARM64 build image reference.
	ContainerImage string `json:"container_image"`
	// BuildTarget is the only Debian rules target selected by compiled policy.
	BuildTarget string `json:"build_target"`
	// MinimumFreeGiB is the managed-volume free-space guard in gibibytes.
	MinimumFreeGiB int `json:"minimum_free_gib"`
	// WorkVolume is the deterministic, labelled Docker volume holding source data.
	WorkVolume string `json:"work_volume"`
	// WorkspaceIdentity binds the volume label to the canonical work boundary.
	WorkspaceIdentity string `json:"workspace_identity"`
	// RecipeSHA256 identifies the complete embedded container policy.
	RecipeSHA256 string `json:"recipe_sha256"`
	// Commands previews volume ownership checks and the Docker run invocation;
	// private runtime names are marked rather than guessed.
	Commands []Command `json:"commands"`
}

// Provenance records the exact source object and compiled policy used by Docker.
type Provenance struct {
	// GitURL is the source remote verified inside the container.
	GitURL string `json:"git_url"`
	// GitRef is the caller-selected branch or tag.
	GitRef string `json:"git_ref"`
	// RefKind distinguishes a fetched branch from a fetched tag.
	RefKind string `json:"ref_kind"`
	// Revision is the exact fetched commit object.
	Revision string `json:"revision"`
	// Tree is the exact Git tree compiled by the Debian package rules.
	Tree string `json:"tree"`
	// CommitTime is the upstream commit timestamp.
	CommitTime time.Time `json:"commit_time"`
	// RecipeSHA256 identifies the embedded container recipe.
	RecipeSHA256 string `json:"recipe_sha256"`
	// ContainerImage records the selected ARM64 userspace image reference.
	ContainerImage string `json:"container_image"`
	// WorkVolume identifies the labelled persistent Docker source volume.
	WorkVolume string `json:"work_volume"`
	// ToolchainSHA256 identifies the exact installed container package versions.
	ToolchainSHA256 string `json:"toolchain_sha256"`
}

// Artifact records one validated and atomically published Debian package.
type Artifact struct {
	// Role states how the package contributes to the kernel bundle.
	Role kernel.PackageRole `json:"role"`
	// Name is the validated package basename.
	Name string `json:"name"`
	// Path is the final absolute path beneath the selected output directory.
	Path string `json:"path"`
	// SHA256 is the lowercase digest of the complete package bytes.
	SHA256 string `json:"sha256"`
	// Size is the complete package length in bytes.
	Size int64 `json:"size_bytes"`
}

// CleanupReceipt records bounded container recovery after a failed or cancelled run.
type CleanupReceipt struct {
	// Attempted reports whether forced container removal was requested.
	Attempted bool `json:"attempted"`
	// Command is the exact direct Docker cleanup invocation.
	Command *Command `json:"command,omitempty"`
	// Error is a bounded diagnostic when Docker cleanup did not succeed.
	Error string `json:"error,omitempty"`
}

// Receipt records the reviewed plan, exact commands, source provenance, and outputs.
type Receipt struct {
	// Plan is the immutable decision used for this build.
	Plan Plan `json:"plan"`
	// StartedAt records when build handling began.
	StartedAt time.Time `json:"started_at"`
	// CompletedAt records when all work and recovery handling ended.
	CompletedAt time.Time `json:"completed_at"`
	// Executed contains only commands handed to the process runner.
	Executed []Command `json:"executed,omitempty"`
	// Provenance is present after the container reports a valid source identity.
	Provenance *Provenance `json:"provenance,omitempty"`
	// Artifacts contains the exact packages published on success.
	Artifacts []Artifact `json:"artifacts,omitempty"`
	// Cleanup records forced container removal after a failed invocation.
	Cleanup *CleanupReceipt `json:"cleanup,omitempty"`
	// Interrupted reports cancellation of the caller context.
	Interrupted bool `json:"interrupted"`
	// Published reports that the complete new output directory was atomically installed.
	Published bool `json:"published"`
	// PublicationDurable reports that the installed output directory was flushed successfully.
	PublicationDurable bool `json:"publication_durable"`
}

// Manager owns native planning, Docker execution, and atomic local publication.
type Manager struct {
	// Runner executes only compiled, argument-separated Docker commands.
	Runner platform.Runner
	// now supplies deterministic receipt timestamps in tests.
	now func() time.Time
	// token supplies a collision-resistant container identifier.
	token func() (string, error)
}

// New constructs a native kernel build manager with direct process execution by default.
func New(runner platform.Runner) *Manager {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Manager{Runner: runner, now: time.Now, token: randomToken}
}

// Plan validates request and returns a read-only build decision.
func (manager *Manager) Plan(ctx context.Context, request Request) (Plan, error) {
	return manager.prepare(ctx, request)
}
