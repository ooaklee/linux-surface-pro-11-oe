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
)

// Supported component identifiers are stable CLI and result values.
const (
	AudioComponent  = "audio-fullio-v19c"
	IPTSDComponent  = "iptsd-v1"
	CameraComponent = "imx681-libcamera-v1"
)

// Options selects the already-downloaded release bundle and explicit target
// root. DryRun verifies all immutable inputs and target paths but performs no
// target mutation and does not require root privileges.
type Options struct {
	BundleDir string
	Root      string
	DryRun    bool
}

// Command describes the one bounded external command used by an install.
type Command struct {
	Name string   `json:"name"`
	Args []string `json:"args"`
}

// FileChange describes one atomic file replacement and any recoverable copy
// made before it.
type FileChange struct {
	Source   string `json:"source"`
	Target   string `json:"target"`
	Backup   string `json:"backup,omitempty"`
	Replaced bool   `json:"replaced"`
}

// Result is suitable for both human and structured CLI output.
type Result struct {
	Component       string       `json:"component"`
	Root            string       `json:"root"`
	DryRun          bool         `json:"dry_run"`
	Files           []FileChange `json:"files,omitempty"`
	BackupDirectory string       `json:"backup_directory,omitempty"`
	Command         *Command     `json:"command,omitempty"`
	RebootRequired  bool         `json:"reboot_required"`
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
	runner    platform.Runner
	extractor ArchiveExtractor
	euid      func() int
	now       func() time.Time
}

// New constructs an installer with the production command runner and secure
// xz/tar extraction boundary.
func New(runner platform.Runner) *Installer {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Installer{
		runner:    runner,
		extractor: SecureXZTarExtractor{},
		euid:      os.Geteuid,
		now:       time.Now,
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
