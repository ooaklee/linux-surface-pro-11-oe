package cli

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	kernelbuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/build"
	kernelinstall "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/install"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/release"
)

// kernelInstallationManager is the delivery-layer boundary for native kernel
// preflight and installation operations.
type kernelInstallationManager interface {
	// Preflight validates an exact installation request without changing its root.
	Preflight(context.Context, kernelinstall.Request) (kernelinstall.Plan, error)
	// Install performs a dry run or the explicitly confirmed native transaction.
	Install(context.Context, kernelinstall.Request) (kernelinstall.Receipt, error)
}

// newKernelCommand groups custom kernel build, release, and inspection workflows.
func (a *application) newKernelCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "kernel",
		Short: "Build, download, and inspect Surface Pro 11 kernels",
		Args:  cobra.NoArgs,
	}
	releaseCommand := &cobra.Command{Use: "release", Short: "Use versioned kernel release bundles", Args: cobra.NoArgs}
	releaseCommand.AddCommand(a.newKernelReleaseListCommand(), a.newKernelReleaseDownloadCommand())
	command.AddCommand(
		releaseCommand,
		a.newKernelInspectCommand(),
		a.newKernelPreflightCommand(),
		a.newKernelInstallCommand(),
		a.newKernelBuildCommand(),
	)
	return command
}

// newKernelPreflightCommand creates the read-only delivery command for checking
// a local kernel bundle, preserved fallback, target root, and planned commands.
func (a *application) newKernelPreflightCommand() *cobra.Command {
	var root string
	var fallbackABI string
	var runningABI string
	var allowUnverified bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "preflight <bundle-directory>",
		Short: "Validate a native kernel installation without changing the target",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			request, err := kernelInstallationRequest(args[0], root, fallbackABI, runningABI, true, allowUnverified)
			if err != nil {
				return err
			}
			plan, err := a.kernelInstallerForCommand().Preflight(command.Context(), request)
			if err != nil {
				return err
			}
			return a.writeKernelPreflight(plan, asJSON)
		},
	}
	command.Flags().StringVar(&root, "root", "", "explicit absolute target Linux root filesystem")
	command.Flags().StringVar(&fallbackABI, "fallback-abi", "", "currently running Surface kernel ABI to preserve")
	command.Flags().StringVar(&runningABI, "running-abi", "", "running ABI evidence for an alternate-root fixture only")
	command.Flags().BoolVar(&allowUnverified, "allow-unverified", false, "accept a locally hashed bundle without an authoritative checksum manifest")
	command.Flags().BoolVar(&asJSON, "json", false, "write the machine-readable installation plan")
	_ = command.MarkFlagRequired("root")
	_ = command.MarkFlagRequired("fallback-abi")
	return command
}

// newKernelInstallCommand creates the guarded native package installation
// command while keeping confirmation outside the privileged domain manager.
func (a *application) newKernelInstallCommand() *cobra.Command {
	var root string
	var fallbackABI string
	var runningABI string
	var allowUnverified bool
	var dryRun bool
	var yes bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "install <bundle-directory>",
		Short: "Install a preflighted Surface kernel and retain its fallback",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			if !dryRun && !yes {
				return errors.New("kernel install requires --yes for target filesystem changes; run kernel preflight or kernel install --dry-run first")
			}
			request, err := kernelInstallationRequest(args[0], root, fallbackABI, runningABI, dryRun, allowUnverified)
			if err != nil {
				return err
			}
			receipt, installErr := a.kernelInstallerForCommand().Install(command.Context(), request)
			return a.writeKernelInstallReceipt(receipt, asJSON, installErr)
		},
	}
	command.Flags().StringVar(&root, "root", "", "explicit absolute target Linux root filesystem")
	command.Flags().StringVar(&fallbackABI, "fallback-abi", "", "currently running Surface kernel ABI to preserve")
	command.Flags().StringVar(&runningABI, "running-abi", "", "running ABI evidence for an alternate-root fixture only")
	command.Flags().BoolVar(&allowUnverified, "allow-unverified", false, "accept a locally hashed bundle without an authoritative checksum manifest")
	command.Flags().BoolVar(&dryRun, "dry-run", false, "perform complete preflight without privileged changes")
	command.Flags().BoolVar(&yes, "yes", false, "confirm the reviewed target filesystem changes")
	command.Flags().BoolVar(&asJSON, "json", false, "write the machine-readable installation receipt")
	_ = command.MarkFlagRequired("root")
	_ = command.MarkFlagRequired("fallback-abi")
	return command
}

// kernelInstallationRequest discovers the caller-selected local bundle and
// enforces the alternate-root boundary for supplied running-ABI evidence.
func kernelInstallationRequest(bundleDirectory, root, fallbackABI, runningABI string, dryRun, allowUnverified bool) (kernelinstall.Request, error) {
	if filepath.Clean(root) == string(filepath.Separator) && strings.TrimSpace(runningABI) != "" {
		return kernelinstall.Request{}, errors.New("--running-abi is permitted only with an alternate target root")
	}
	bundle, err := kernel.DiscoverLocalBundle(bundleDirectory)
	if err != nil {
		return kernelinstall.Request{}, err
	}
	return kernelinstall.Request{
		Bundle:          bundle,
		Root:            root,
		FallbackABI:     fallbackABI,
		RunningABI:      runningABI,
		DryRun:          dryRun,
		AllowUnverified: allowUnverified,
	}, nil
}

// kernelInstallerForCommand returns the injected manager or a safe native
// default for narrowly constructed application values in delivery tests.
func (a *application) kernelInstallerForCommand() kernelInstallationManager {
	if a != nil && a.kernelInstaller != nil {
		return a.kernelInstaller
	}
	return kernelinstall.New(nil)
}

// writeKernelPreflight renders one successful read-only plan without changing
// its machine-readable representation.
func (a *application) writeKernelPreflight(plan kernelinstall.Plan, asJSON bool) error {
	if asJSON {
		return a.writeJSON(plan)
	}
	verification := "authoritative checksums"
	if plan.UnverifiedAccepted {
		verification = "explicitly accepted local hashes"
	}
	_, err := fmt.Fprintf(a.out,
		"kernel installation preflight passed\nroot: %s\ntarget ABI: %s\nfallback ABI: %s\nversion: %s\npackages: %d\ndevice trees: %d\nverification: %s\nplanned commands: %d\nno changes were made\n",
		plan.Root, plan.TargetABI, plan.FallbackABI, plan.Version, len(plan.Packages), len(plan.DeviceTrees), verification, len(plan.Commands))
	return err
}

// writeKernelInstallReceipt preserves a structured partial receipt on failure
// and otherwise renders concise dry-run or reboot guidance.
func (a *application) writeKernelInstallReceipt(receipt kernelinstall.Receipt, asJSON bool, installErr error) error {
	if asJSON {
		return errors.Join(installErr, a.writeJSON(receipt))
	}
	if installErr != nil {
		return installErr
	}
	if receipt.Plan.DryRun {
		_, err := fmt.Fprintf(a.out,
			"kernel installation dry run passed\nroot: %s\ntarget ABI: %s\nfallback ABI: %s\npackages: %d\nplanned commands: %d\nno changes were made\n",
			receipt.Plan.Root, receipt.Plan.TargetABI, receipt.Plan.FallbackABI, len(receipt.Plan.Packages), len(receipt.Plan.Commands))
		return err
	}
	_, err := fmt.Fprintf(a.out,
		"kernel installed\nroot: %s\ntarget ABI: %s\nfallback ABI retained: %s\ndevice trees verified: %d\nreboot required: %t\nReboot manually when ready; retain the fallback kernel until the new kernel has been tested.\n",
		receipt.Plan.Root, receipt.Plan.TargetABI, receipt.Plan.FallbackABI, len(receipt.DeviceTrees), receipt.RebootRequired)
	return err
}

// newKernelReleaseListCommand shows releases containing a candidate runtime
// pair whose integrity is checked only when it is downloaded.
func (a *application) newKernelReleaseListCommand() *cobra.Command {
	var repository string
	var limit int
	var asJSON bool
	command := &cobra.Command{
		Use:   "list",
		Short: "List candidate runtime kernel releases",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			releases, err := a.releases.List(command.Context(), repository, limit)
			if err != nil {
				return err
			}
			release.SortByPublished(releases)
			if asJSON {
				return a.writeJSON(releases)
			}
			writer := tabwriter.NewWriter(a.out, 0, 4, 2, ' ', 0)
			_, _ = fmt.Fprintln(writer, "TAG\tPUBLISHED\tASSETS")
			for _, item := range releases {
				_, _ = fmt.Fprintf(writer, "%s\t%s\t%d\n", item.TagName, item.PublishedAt.Format(time.RFC3339), len(item.Assets))
			}
			return writer.Flush()
		},
	}
	command.Flags().StringVar(&repository, "repository", release.DefaultRepository, "GitHub owner/repository containing kernel releases")
	command.Flags().IntVar(&limit, "limit", 20, "maximum releases to return")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newKernelReleaseDownloadCommand acquires and verifies one ABI-bound package set.
func (a *application) newKernelReleaseDownloadCommand() *cobra.Command {
	var repository string
	var outputDirectory string
	var includeHeaders bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "download [ref]",
		Short: "Download and verify one ABI-bound kernel release",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			ref := "latest"
			if len(args) == 1 {
				ref = args[0]
			}
			bundle, err := a.releases.DownloadBundle(command.Context(), repository, ref, outputDirectory, includeHeaders)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(bundle)
			}
			_, err = fmt.Fprintf(a.out, "downloaded %s\nABI: %s\npackages: %d\ndirectory: %s\n", bundle.Release, bundle.ABI, len(bundle.Packages), outputDirectory)
			return err
		},
	}
	command.Flags().StringVar(&repository, "repository", release.DefaultRepository, "GitHub owner/repository containing kernel releases")
	command.Flags().StringVar(&outputDirectory, "output-dir", "kernel-bundle", "directory for verified packages and manifest")
	command.Flags().BoolVar(&includeHeaders, "headers", false, "also download matching header packages")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newKernelInspectCommand proves that local packages form one coherent Surface ABI.
func (a *application) newKernelInspectCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "inspect <directory>",
		Short: "Validate local kernel packages as one ABI-bound bundle",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			bundle, err := kernel.DiscoverLocalBundle(args[0])
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(bundle)
			}
			_, err = fmt.Fprintf(a.out, "kernel bundle valid\nrelease: %s\nABI: %s\nversion: %s\npackages: %d\n", bundle.Release, bundle.ABI, bundle.Version, len(bundle.Packages))
			return err
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newKernelBuildCommand delegates compilation to the repository's pinned Docker workflow.
func (a *application) newKernelBuildCommand() *cobra.Command {
	request := kernelbuild.Request{}
	command := &cobra.Command{
		Use:   "build",
		Short: "Build the custom SP11 kernel in the maintained Docker workflow",
		Long:  "Build the custom SP11 kernel using the OE repository's maintained ARM64 Docker workflow. Build and output directories must be inside that repository.",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			return kernelbuild.New(nil).Run(command.Context(), request)
		},
	}
	command.Flags().StringVar(&request.RepositoryRoot, "repository-root", "", "OE repository root (auto-detected from the current directory)")
	command.Flags().StringVar(&request.GitURL, "git-url", kernelbuild.DefaultGitURL, "kernel source repository")
	command.Flags().StringVar(&request.GitBranch, "git-branch", kernelbuild.DefaultGitBranch, "kernel source branch or tag")
	command.Flags().StringVar(&request.WorkDirectory, "work-dir", "build/linux-armer/kernel-build", "repository-relative kernel build directory")
	command.Flags().StringVar(&request.OutputDirectory, "output-dir", "build/linux-armer/kernel", "repository-relative package output directory")
	command.Flags().IntVar(&request.Jobs, "jobs", 0, "parallel build jobs (zero lets the helper choose)")
	command.Flags().BoolVar(&request.ResetSource, "reset-source", false, "discard and recreate the helper's kernel source tree")
	command.Flags().BoolVar(&request.SkipClean, "skip-clean", false, "skip the Debian package clean step")
	command.Flags().BoolVar(&request.DryRun, "dry-run", false, "print the delegated Docker build without running it")
	return command
}
