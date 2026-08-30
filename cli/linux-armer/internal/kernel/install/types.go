// Package install performs a guarded, native Debian kernel installation.
//
// The package deliberately installs only a coherent Surface Pro 11 kernel
// package set. It does not install historical out-of-tree touchscreen modules,
// firmware copies, GRUB hooks, or other broad support workarounds.
package install

import (
	"context"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// Operation identifies one bounded stage in a kernel installation.
type Operation string

const (
	// OperationInspectPackage reads bounded Debian metadata without installation.
	OperationInspectPackage Operation = "inspect-package"
	// OperationInspectRunningABI reads the live system's exact running ABI.
	OperationInspectRunningABI Operation = "inspect-running-abi"
	// OperationInstallPackages installs only the verified local Debian packages.
	OperationInstallPackages Operation = "install-packages"
	// OperationUpdateInitramfs refreshes the initramfs for the exact target ABI.
	OperationUpdateInitramfs Operation = "update-initramfs"
	// OperationUpdateGRUB regenerates the target system's GRUB configuration.
	OperationUpdateGRUB Operation = "update-grub"
	// OperationRollbackPackages purges only target packages from a failed run.
	OperationRollbackPackages Operation = "rollback-packages"
)

// Request contains every caller-selected input used to prepare an installation.
type Request struct {
	// Bundle is the already acquired and hashed Surface kernel package set.
	Bundle kernel.Bundle
	// Root is the explicit absolute filesystem root that will receive the kernel.
	Root string
	// FallbackABI is the distinct, currently booted ABI that must remain usable.
	FallbackABI string
	// RunningABI supplies uname evidence only for an alternate-root fixture.
	// It must be empty when Root is the live system root.
	RunningABI string
	// DryRun performs the complete read-only preflight without privileged changes.
	DryRun bool
	// AllowUnverified explicitly accepts locally hashed packages that were not
	// covered by an authoritative checksum manifest.
	AllowUnverified bool
}

// Command describes one direct process invocation without shell interpretation.
type Command struct {
	// Operation states why the executable is needed.
	Operation Operation `json:"operation"`
	// Name is the fixed executable name selected by this package.
	Name string `json:"name"`
	// Args contains separately bounded arguments passed to the executable.
	Args []string `json:"args"`
}

// Package records immutable package bytes and inspected Debian metadata.
type Package struct {
	// Role states the package's exact place in the allow-listed transaction.
	Role kernel.PackageRole `json:"role"`
	// Name is the validated Debian package filename.
	Name string `json:"name"`
	// Path is the canonical, non-symlink source path reviewed by the caller.
	Path string `json:"path"`
	// SHA256 is the lowercase digest of the complete package bytes.
	SHA256 string `json:"sha256"`
	// Size is the complete package length in bytes.
	Size int64 `json:"size_bytes"`
	// DebianPackage is the Package field read with dpkg-deb.
	DebianPackage string `json:"debian_package"`
	// Version is the Debian package version shared by the transaction.
	Version string `json:"version"`
	// Architecture is arm64 for runtime/flavour headers and all for common headers.
	Architecture string `json:"architecture"`
	// Depends is the bounded dependency expression read from the package.
	Depends string `json:"depends,omitempty"`
	// PublisherVerified reports whether the input bundle had authoritative hashes.
	PublisherVerified bool `json:"publisher_verified"`
}

// DeviceTree records one exact DTB required after package installation.
type DeviceTree struct {
	// Device is the stable Surface Pro 11 hardware variant identifier.
	Device string `json:"device"`
	// RelativePath is the compiled device-tree path beneath the ABI directory.
	RelativePath string `json:"relative_path"`
	// TargetPath is the absolute target-root path checked after installation.
	TargetPath string `json:"target_path"`
}

// FileEvidence records the identity of one safety-critical regular file.
type FileEvidence struct {
	// Kind distinguishes kernel images, initramfs files, module indexes, and DTBs.
	Kind string `json:"kind"`
	// Path is the absolute path beneath the selected target root.
	Path string `json:"path"`
	// SHA256 is the lowercase digest of the complete file.
	SHA256 string `json:"sha256"`
	// Size is the complete file length in bytes.
	Size int64 `json:"size_bytes"`
}

// BootEvidence proves that an ABI has a usable boot and module baseline.
type BootEvidence struct {
	// ABI is the exact Surface kernel ABI represented by the evidence.
	ABI string `json:"abi"`
	// KernelImage identifies the non-empty kernel image.
	KernelImage FileEvidence `json:"kernel_image"`
	// Initramfs identifies the non-empty matching initramfs.
	Initramfs FileEvidence `json:"initramfs"`
	// SystemMap identifies the non-empty symbol map supplied for the ABI.
	SystemMap FileEvidence `json:"system_map"`
	// KernelConfig identifies the non-empty packaged kernel configuration.
	KernelConfig FileEvidence `json:"kernel_config"`
	// ModulesDependencyIndex identifies the non-empty modules.dep file.
	ModulesDependencyIndex FileEvidence `json:"modules_dependency_index"`
	// ModuleTree is the canonical directory containing at least one kernel module.
	ModuleTree string `json:"module_tree"`
	// ModuleFile identifies one non-empty regular module proving the tree is populated.
	ModuleFile FileEvidence `json:"module_file"`
	// GRUBEntryCount is the number of matching non-recovery boot entries.
	GRUBEntryCount int `json:"grub_entry_count"`
}

// Plan is the complete read-only result that must be reviewed before mutation.
type Plan struct {
	// Root is the canonical target filesystem root.
	Root string `json:"root"`
	// TargetABI is the distinct Surface kernel ABI selected for installation.
	TargetABI string `json:"target_abi"`
	// FallbackABI is the currently running, preserved Surface kernel ABI.
	FallbackABI string `json:"fallback_abi"`
	// RunningABI records the trusted live or fixture uname evidence.
	RunningABI string `json:"running_abi"`
	// Version is the coherent Debian version shared by all selected packages.
	Version string `json:"version"`
	// DryRun reports whether execution was intentionally disabled.
	DryRun bool `json:"dry_run"`
	// UnverifiedAccepted reports that the caller explicitly accepted local trust.
	UnverifiedAccepted bool `json:"unverified_accepted"`
	// Packages is the exact allow-listed, metadata-verified transaction.
	Packages []Package `json:"packages"`
	// DeviceTrees lists the exact DTBs that the installed modules must provide.
	DeviceTrees []DeviceTree `json:"device_trees"`
	// Fallback captures the bootable recovery kernel before any mutation.
	Fallback BootEvidence `json:"fallback"`
	// Commands previews the direct commands using reviewed source package paths.
	Commands []Command `json:"commands"`
}

// RollbackReceipt records best-effort recovery after a failed package operation.
type RollbackReceipt struct {
	// Attempted reports whether any potentially mutating command had started.
	Attempted bool `json:"attempted"`
	// Commands contains the exact direct recovery commands that were attempted.
	Commands []Command `json:"commands,omitempty"`
	// GRUBRestored reports whether the pre-transaction GRUB bytes were restored.
	GRUBRestored bool `json:"grub_restored"`
	// Error contains a bounded joined diagnostic when recovery was incomplete.
	Error string `json:"error,omitempty"`
}

// Receipt records the reviewed plan, executed commands, and final boot evidence.
type Receipt struct {
	// Plan is the immutable preflight result used by this execution.
	Plan Plan `json:"plan"`
	// StartedAt records when the manager began the requested operation.
	StartedAt time.Time `json:"started_at"`
	// CompletedAt records when the manager returned its final result.
	CompletedAt time.Time `json:"completed_at"`
	// Executed contains only commands that were actually handed to the runner.
	Executed []Command `json:"executed,omitempty"`
	// Installed captures the verified target ABI after successful installation.
	Installed *BootEvidence `json:"installed,omitempty"`
	// DeviceTrees contains verified installed DTB evidence.
	DeviceTrees []FileEvidence `json:"device_trees,omitempty"`
	// Rollback records recovery work after a failed mutating operation.
	Rollback *RollbackReceipt `json:"rollback,omitempty"`
	// RebootRequired is true only after a successful non-dry-run installation.
	RebootRequired bool `json:"reboot_required"`
}

// Manager owns package inspection, privilege enforcement, command execution,
// and post-install verification.
type Manager struct {
	// runner is the injectable direct-process boundary.
	runner platform.Runner
	// effectiveUID returns the process privilege identity.
	effectiveUID func() int
	// now supplies receipt timestamps.
	now func() time.Time
}

// New constructs a native kernel installation manager.
func New(runner platform.Runner) *Manager {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Manager{
		runner:       runner,
		effectiveUID: effectiveUserID,
		now:          time.Now,
	}
}

// Preflight performs every read-only package, fallback, path, and boot check.
func (manager *Manager) Preflight(ctx context.Context, request Request) (Plan, error) {
	return manager.prepare(ctx, request)
}
