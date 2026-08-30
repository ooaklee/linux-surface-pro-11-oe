// Package install applies immutable, verified SP11 userspace release bundles.
//
// Every command and writable target is compiled into this package. Callers
// choose only the supported component, bundle directory, target root, and
// whether to produce a dry-run plan.
package install

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
	userspaceiptsd "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/iptsd"
)

// Supported component identifiers are stable CLI and result values.
const (
	// AudioComponent identifies the coherent FullIO audio release.
	AudioComponent = "audio-fullio-v19c"
	// IPTSDComponent identifies the native IPTSD integration release.
	IPTSDComponent = "iptsd-v1"
	// CameraComponent identifies the experimental IMX681 package release.
	CameraComponent = "imx681-libcamera-v1"
)

// Options selects the already-downloaded release bundle and explicit target
// root. DryRun verifies all immutable inputs and target paths but performs no
// target mutation and does not require root privileges.
type Options struct {
	// BundleDir is the exact verified release-bundle directory.
	BundleDir string
	// Root is the target filesystem root, defaulting to the live root.
	Root string
	// DryRun verifies immutable input and returns a plan without privilege.
	DryRun bool
}

// Command describes one bounded, argument-separated external command.
type Command struct {
	// Name is the fixed executable path or reviewed program name.
	Name string `json:"name"`
	// Args contains exact arguments without shell interpretation.
	Args []string `json:"args"`
}

// FileChange describes one atomic file replacement and any recoverable copy
// made before it.
type FileChange struct {
	// Source is a stable release or rendered-content provenance label.
	Source string `json:"source"`
	// Target is the fully resolved target path.
	Target string `json:"target"`
	// Backup is the private recovery copy for a replaced regular file.
	Backup string `json:"backup,omitempty"`
	// Replaced reports whether an existing target was observed.
	Replaced bool `json:"replaced"`
	// Action distinguishes file creation, replacement, and mask retention.
	Action string `json:"action,omitempty"`
}

// Result is suitable for both human and structured CLI output.
type Result struct {
	// Component is the stable installed component identifier.
	Component string `json:"component"`
	// Root is the fully resolved target filesystem root.
	Root string `json:"root"`
	// DryRun reports that no target mutation or privileged command occurred.
	DryRun bool `json:"dry_run"`
	// Files lists every exact planned or completed filesystem operation.
	Files []FileChange `json:"files,omitempty"`
	// BackupDirectory contains private recovery copies and the receipt.
	BackupDirectory string `json:"backup_directory,omitempty"`
	// Receipt is the durable native transaction receipt path.
	Receipt string `json:"receipt,omitempty"`
	// Command preserves the single-command schema used by camera installs.
	Command *Command `json:"command,omitempty"`
	// Commands lists the complete fixed post-publication command plan.
	Commands []Command `json:"commands,omitempty"`
	// FilesInstalled reports that every component filesystem change is durable.
	FilesInstalled bool `json:"files_installed"`
	// ActivationRequired reports whether the selected live root needs commands.
	ActivationRequired bool `json:"activation_required"`
	// ActivationComplete reports whether all required commands succeeded.
	ActivationComplete bool `json:"activation_complete"`
	// ActivationError preserves a bounded diagnostic without hiding file state.
	ActivationError string `json:"activation_error,omitempty"`
	// RebootRequired reports whether post-install validation requires a reboot.
	RebootRequired bool `json:"reboot_required"`
}

// ArchiveExtractor is injectable so command orchestration can be tested
// without invoking an external decompressor. SecureXZTarExtractor is used in
// production.
type ArchiveExtractor interface {
	// Validate streams an archive through every safety check without writing it.
	Validate(context.Context, string) error
	// Extract applies the same checks while writing into an empty directory.
	Extract(context.Context, string, string) error
}

// Installer owns the privileged process and filesystem boundary.
type Installer struct {
	// runner owns the fixed external-command boundary.
	runner platform.Runner
	// extractor owns bounded no-link XZ/TAR processing.
	extractor ArchiveExtractor
	// euid supplies privilege state and is injectable for tests.
	euid func() int
	// now supplies transaction timestamps and is injectable for tests.
	now func() time.Time
	// activationTimeout bounds each live service-management command.
	activationTimeout time.Duration
	// validateIPTSDRelease is injectable for hostile transaction tests.
	validateIPTSDRelease func(string) (userspaceiptsd.Release, error)
	// isLiveRoot is injectable so service-state reporting can be tested safely.
	isLiveRoot func(string) bool
	// beforeIPTSDPublish is an internal hostile-mutation test hook.
	beforeIPTSDPublish func(int, string) error
}

// New constructs an installer with the production command runner and secure
// xz/tar extraction boundary.
func New(runner platform.Runner) *Installer {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Installer{
		runner:               runner,
		extractor:            SecureXZTarExtractor{},
		euid:                 os.Geteuid,
		now:                  time.Now,
		activationTimeout:    15 * time.Second,
		validateIPTSDRelease: userspaceiptsd.ValidateRelease,
		isLiveRoot: func(root string) bool {
			return root == string(filepath.Separator)
		},
	}
}

// normalizeOptions resolves the explicit bundle and target root before any
// validation or mutation is attempted.
func normalizeOptions(options Options) (Options, error) {
	if options.BundleDir == "" {
		return Options{}, errors.New("userspace bundle directory is required")
	}
	bundle, err := filepath.Abs(options.BundleDir)
	if err != nil {
		return Options{}, fmt.Errorf("resolve userspace bundle directory: %w", err)
	}
	bundle, err = filepath.EvalSymlinks(bundle)
	if err != nil {
		return Options{}, fmt.Errorf("resolve userspace bundle directory: %w", err)
	}
	bundleInfo, err := os.Stat(bundle)
	if err != nil {
		return Options{}, fmt.Errorf("inspect userspace bundle directory: %w", err)
	}
	if !bundleInfo.IsDir() {
		return Options{}, fmt.Errorf("userspace bundle path is not a directory: %s", bundle)
	}

	root := options.Root
	if root == "" {
		root = "/"
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return Options{}, fmt.Errorf("resolve userspace target root: %w", err)
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return Options{}, fmt.Errorf("resolve userspace target root: %w", err)
	}
	rootInfo, err := os.Stat(root)
	if err != nil {
		return Options{}, fmt.Errorf("inspect userspace target root: %w", err)
	}
	if !rootInfo.IsDir() {
		return Options{}, fmt.Errorf("userspace target root is not a directory: %s", root)
	}
	options.BundleDir = filepath.Clean(bundle)
	options.Root = filepath.Clean(root)
	return options, nil
}

// requireRoot keeps planning unprivileged while protecting every install path.
func (installer *Installer) requireRoot(dryRun bool) error {
	if dryRun {
		return nil
	}
	if installer.euid == nil || installer.euid() != 0 {
		return errors.New("userspace installation requires effective UID 0; review a dry run, then rerun as root")
	}
	return nil
}
