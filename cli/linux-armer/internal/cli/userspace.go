package cli

import (
	"fmt"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	camerabuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/build"
	userspacebuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/build"
	userspacecatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspaceinstall "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/install"
	userspacemanager "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/manager"
	userspacestatus "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/status"
)

// userspaceInstallReport keeps human and JSON delivery aligned around the same
// component results and post-install guidance.
type userspaceInstallReport struct {
	// Results contains one verified plan or completed installation per component.
	Results []userspaceinstall.Result `json:"results"`
	// NextSteps tells the user how to safely continue after the reported operation.
	NextSteps []string `json:"next_steps"`
	// Error preserves a structured incomplete-install diagnostic after results.
	Error string `json:"error,omitempty"`
}

// newUserspaceCommand groups catalogue, status, pull, build, install, and
// camera-inspection workflows.
func (a *application) newUserspaceCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "userspace",
		Short: "Inspect and manage Surface Pro 11 userspace support",
		Args:  cobra.NoArgs,
	}
	catalogCommand := &cobra.Command{
		Use:   "catalog",
		Short: "Inspect the audited userspace component catalogue",
		Args:  cobra.NoArgs,
	}
	catalogCommand.AddCommand(a.newUserspaceCatalogValidateCommand())
	command.AddCommand(
		a.newUserspaceListCommand(),
		a.newUserspaceShowCommand(),
		catalogCommand,
		a.newUserspaceStatusCommand(),
		a.newUserspacePullCommand(),
		a.newUserspaceBuildCommand(),
		a.newUserspaceInstallCommand(),
		a.newUserspaceCameraCommand(nil),
	)
	return command
}

// newUserspaceStatusCommand builds the read-only userspace status command.
func (a *application) newUserspaceStatusCommand() *cobra.Command {
	return a.newUserspaceStatusDeliveryCommand("status", "Report installed Surface Pro 11 userspace support")
}

// newUserspaceStatusDeliveryCommand creates a shared status command for both
// `userspace status` and `doctor userspace`.
func (a *application) newUserspaceStatusDeliveryCommand(use, short string) *cobra.Command {
	var root string
	var kernelABI string
	var featureNames []string
	var asJSON bool
	command := &cobra.Command{
		Use:   use,
		Short: short,
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			features := make([]userspacestatus.Feature, 0, len(featureNames))
			for _, name := range featureNames {
				feature, err := userspacestatus.ParseFeature(name)
				if err != nil {
					return err
				}
				features = append(features, feature)
			}
			report, err := a.userspace.StatusWithCatalog(a.userspaceCatalogPath, userspacestatus.Options{
				Root: root, KernelABI: kernelABI, Features: features,
			})
			if err != nil {
				return err
			}
			if asJSON {
				if err := a.writeJSON(report); err != nil {
					return err
				}
			} else {
				writer := tabwriter.NewWriter(a.out, 0, 4, 2, ' ', 0)
				_, _ = fmt.Fprintln(writer, "STATE\tLEVEL\tCOMPONENT\tFEATURE\tCHECK\tDETAIL")
				for _, check := range report.Checks {
					_, _ = fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\n", check.State, check.SupportLevel, check.ComponentID, check.Feature, check.ID, check.Detail)
				}
				if err := writer.Flush(); err != nil {
					return err
				}
			}
			if !report.Ready {
				return fmt.Errorf("required userspace support checks failed")
			}
			return nil
		},
	}
	command.Flags().StringVar(&root, "root", "/", "target filesystem root to inspect")
	command.Flags().StringVar(&kernelABI, "kernel", "", "installed Surface qcom-x1e kernel ABI to inspect")
	command.Flags().StringSliceVar(&featureNames, "feature", nil, "limit checks to a feature (repeatable or comma-separated)")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newUserspaceListCommand displays audited components and only the actions the
// current CLI can safely perform for each one.
func (a *application) newUserspaceListCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "list",
		Short: "List audited userspace and firmware components",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			componentCatalog, err := a.userspace.LoadCatalog(a.userspaceCatalogPath)
			if err != nil {
				return err
			}
			components := componentCatalog.List()
			if asJSON {
				return a.writeJSON(components)
			}
			writer := tabwriter.NewWriter(a.out, 0, 4, 2, ' ', 0)
			_, _ = fmt.Fprintln(writer, "ID\tLEVEL\tCAPABILITY\tACTIONS")
			for _, component := range components {
				_, _ = fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n",
					component.ID, component.Level, component.Capability, formatUserspaceActions(component.SupportActions))
			}
			return writer.Flush()
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newUserspaceShowCommand explains support maturity, redistribution, and remediation.
func (a *application) newUserspaceShowCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "show <component>",
		Short: "Show one audited userspace component",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			componentCatalog, err := a.userspace.LoadCatalog(a.userspaceCatalogPath)
			if err != nil {
				return err
			}
			componentID, err := userspacemanager.ResolveComponentID(args[0])
			if err != nil {
				return err
			}
			component, ok := componentCatalog.Get(componentID)
			if !ok {
				return fmt.Errorf("userspace component %q is not in the catalog", componentID)
			}
			if asJSON {
				return a.writeJSON(component)
			}
			_, err = fmt.Fprintf(a.out,
				"%s\nID: %s\nlevel: %s\ncapability: %s\nredistribution: %s\nactions: %s\nevidence: %s\nremediation: %s\n",
				component.Name, component.ID, component.Level, component.Capability,
				component.Redistribution, formatUserspaceActions(component.SupportActions),
				component.CompatibilityEvidence, component.Remediation)
			if err != nil {
				return err
			}
			if component.KernelCompatibility != nil {
				_, err = fmt.Fprintf(a.out, "kernel compatibility: sp11v%d or newer; tested through sp11v%d\n%s\n",
					component.KernelCompatibility.MinimumSP11Generation,
					component.KernelCompatibility.TestedThroughSP11Generation,
					component.KernelCompatibility.Summary)
			}
			return err
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newUserspaceCatalogValidateCommand applies the dedicated strict component validator.
func (a *application) newUserspaceCatalogValidateCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "validate [path]",
		Short: "Strictly validate a userspace component catalogue",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			path := a.userspaceCatalogPath
			if len(args) == 1 {
				path = args[0]
			}
			componentCatalog, err := a.userspace.LoadCatalog(path)
			if err != nil {
				return err
			}
			_, err = fmt.Fprintf(a.out, "userspace catalog valid: schema %d, %d components\n",
				componentCatalog.SchemaVersion, componentCatalog.Len())
			return err
		},
	}
}

// newUserspacePullCommand downloads an immutable release only when its complete
// remote asset set and both checksum authorities agree.
func (a *application) newUserspacePullCommand() *cobra.Command {
	var cacheDirectory string
	var asJSON bool
	command := &cobra.Command{
		Use:   "pull <component|recommended>",
		Short: "Download an exact checksum-verified userspace release",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			bundles, err := a.userspace.Pull(command.Context(), a.userspaceCatalogPath, args[0], cacheDirectory)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(bundles)
			}
			for _, bundle := range bundles {
				_, _ = fmt.Fprintf(a.out, "pulled %s %s\ndirectory: %s\nverified files: %d\n",
					bundle.Component, bundle.Release, bundle.Directory, len(bundle.Files))
			}
			return nil
		},
	}
	command.Flags().StringVar(&cacheDirectory, "cache-dir", "", "verified userspace release cache (default: operating-system user cache)")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newUserspaceBuildCommand invokes only compiled, component-specific build helpers.
func (a *application) newUserspaceBuildCommand() *cobra.Command {
	request := userspacebuild.Request{}
	var asJSON bool
	command := &cobra.Command{
		Use:   "build <iptsd|camera>",
		Short: "Build a pinned userspace component with its maintained workflow",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			componentID, err := userspacemanager.ResolveComponentID(args[0])
			if err != nil {
				return err
			}
			componentCatalog, err := a.userspace.LoadCatalog(a.userspaceCatalogPath)
			if err != nil {
				return err
			}
			component, ok := componentCatalog.Get(componentID)
			if !ok || !component.SupportActions.Build {
				return fmt.Errorf("userspace component %q does not support a source build", componentID)
			}
			switch componentID {
			case userspacemanager.IPTSDComponent:
				request.Component = userspacebuild.ComponentIPTSD
			case userspacemanager.CameraComponent:
				request.Component = userspacebuild.ComponentCamera
			default:
				return fmt.Errorf("userspace component %q has no compiled build workflow", componentID)
			}
			result, err := a.userspace.BuildWithResult(command.Context(), request)
			if asJSON {
				if writeErr := a.writeJSON(result); writeErr != nil {
					return writeErr
				}
				return err
			}
			if writeErr := a.writeUserspaceBuildResult(result); writeErr != nil {
				return writeErr
			}
			return err
		},
	}
	command.Flags().StringVar(&request.RepositoryRoot, "repository-root", "", "OE repository root (auto-detected from the current directory)")
	command.Flags().StringVar(&request.OutputDirectory, "output-dir", "", "component build output directory (camera paths are repository-relative)")
	command.Flags().StringVar(&request.Image, "image", "", "iptsd ARM64 builder image (camera uses immutable compiled policy)")
	command.Flags().StringVar(&request.WorkVolume, "work-volume", "", "iptsd case-sensitive Docker work volume")
	command.Flags().IntVar(&request.Jobs, "jobs", 0, "parallel build jobs (zero uses the compiled workflow default)")
	command.Flags().IntVar(&request.MinimumFreeGiB, "minimum-free-gib", 0, "camera builder minimum free space in GiB")
	command.Flags().BoolVar(&request.NoPull, "no-pull", false, "camera builder: require an already-present image")
	command.Flags().BoolVar(&request.DryRun, "dry-run", false, "camera builder: authenticate inputs and show policy without mutation")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// writeUserspaceBuildResult renders concise native build output and dry-run truth.
func (a *application) writeUserspaceBuildResult(result userspacebuild.Result) error {
	if result.Component == userspacebuild.ComponentIPTSD {
		_, err := fmt.Fprintln(a.out, "built and validated the pinned IPTSD payload")
		return err
	}
	if result.Component != userspacebuild.ComponentCamera || result.Camera == nil {
		return fmt.Errorf("userspace build returned no recognised component result")
	}
	camera := result.Camera
	if camera.Plan.DryRun {
		if _, err := fmt.Fprintf(a.out, "camera build dry run\nimage: %s\nrecipe SHA-256: %s\n", camera.Plan.ContainerImage, camera.Plan.RecipeSHA256); err != nil {
			return err
		}
		if !camera.Plan.Executable {
			_, err := fmt.Fprintf(a.out, "execution unavailable: %s\n", camera.Plan.ExecutionBlocker)
			return err
		}
		_, err := fmt.Fprintln(a.out, "native Linux ARM64 execution is available")
		return err
	}
	if camera.Published && camera.Bundle != nil {
		_, err := fmt.Fprintf(a.out, "built and validated coherent camera packages\nversion: %s\noutput: %s\nreceipt: %s\n", camera.Bundle.PackageVersion, camera.OutputDirectory, camerabuild.ReceiptName)
		return err
	}
	_, err := fmt.Fprintln(a.out, "camera build did not publish a package set")
	return err
}

// newUserspaceInstallCommand verifies and applies only compiled userspace
// workflows, with an explicit confirmation gate for every mutation.
func (a *application) newUserspaceInstallCommand() *cobra.Command {
	var from string
	var root string
	var dryRun bool
	var confirmed bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "install <audio|iptsd|camera|recommended>",
		Short: "Install a checksum-verified userspace release",
		Long: "Install a checksum-verified userspace release through compiled policy. " +
			"The recommended set contains audio and IPTSD; experimental camera support must be selected explicitly.",
		Args: cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			if strings.TrimSpace(from) == "" {
				return fmt.Errorf("verified userspace release directory is required; pass --from")
			}
			if !dryRun && !confirmed {
				return fmt.Errorf("userspace installation changes the target filesystem; review --dry-run first, then pass --yes")
			}
			results, err := a.userspace.Install(command.Context(), userspacemanager.InstallRequest{
				CatalogPath: a.userspaceCatalogPath,
				Selector:    args[0],
				From:        from,
				Root:        root,
				DryRun:      dryRun,
			})
			report := makeUserspaceInstallReport(results, dryRun)
			if err != nil {
				report.Error = err.Error()
			}
			if asJSON {
				if writeErr := a.writeJSON(report); writeErr != nil {
					return writeErr
				}
				return err
			}
			if writeErr := a.writeUserspaceInstallReport(report); writeErr != nil {
				return writeErr
			}
			return err
		},
	}
	command.Flags().StringVar(&from, "from", "", "exact verified release directory (userspace cache root for recommended)")
	command.Flags().StringVar(&root, "root", "/", "target filesystem root")
	command.Flags().BoolVar(&dryRun, "dry-run", false, "verify immutable inputs and show the plan without changing the target")
	command.Flags().BoolVar(&confirmed, "yes", false, "confirm target filesystem changes")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// makeUserspaceInstallReport adds concise next actions to installer results
// without changing their machine-readable component detail.
func makeUserspaceInstallReport(results []userspaceinstall.Result, dryRun bool) userspaceInstallReport {
	report := userspaceInstallReport{Results: results}
	if dryRun {
		report.NextSteps = append(report.NextSteps,
			"Review the verified plan, then rerun without --dry-run and pass --yes to install.")
		return report
	}
	for _, result := range results {
		if result.ActivationRequired && !result.ActivationComplete && result.FilesInstalled {
			report.NextSteps = append(report.NextSteps,
				"The IPTSD files are durable; resolve the reported service activation failure, then rerun userspace status.")
		}
		if result.RebootRequired {
			report.NextSteps = append(report.NextSteps,
				"Reboot before validating userspace support so the updated audio integration is active.")
			break
		}
	}
	report.NextSteps = append(report.NextSteps,
		"Run linux-armer doctor userspace after installation to identify any remaining support gaps.")
	return report
}

// writeUserspaceInstallReport renders the structured install report as a
// readable terminal summary while preserving every important result field.
func (a *application) writeUserspaceInstallReport(report userspaceInstallReport) error {
	for _, result := range report.Results {
		operation := "installed"
		if result.DryRun {
			operation = "verified plan for"
		} else if !result.FilesInstalled && result.Component == userspacemanager.IPTSDComponent {
			operation = "incomplete install for"
		}
		if _, err := fmt.Fprintf(a.out, "%s %s\nroot: %s\n", operation, result.Component, result.Root); err != nil {
			return err
		}
		for _, change := range result.Files {
			if _, err := fmt.Fprintf(a.out, "file: %s %s <- %s", change.Action, change.Target, change.Source); err != nil {
				return err
			}
			if change.Backup != "" {
				if _, err := fmt.Fprintf(a.out, " (backup %s)", change.Backup); err != nil {
					return err
				}
			}
			if _, err := fmt.Fprintln(a.out); err != nil {
				return err
			}
		}
		if result.BackupDirectory != "" {
			if _, err := fmt.Fprintf(a.out, "backup: %s\n", result.BackupDirectory); err != nil {
				return err
			}
		}
		if result.Command != nil {
			if _, err := fmt.Fprintf(a.out, "command: %s %s\n", result.Command.Name, strings.Join(result.Command.Args, " ")); err != nil {
				return err
			}
		}
		for _, command := range result.Commands {
			if _, err := fmt.Fprintf(a.out, "command: %s %s\n", command.Name, strings.Join(command.Args, " ")); err != nil {
				return err
			}
		}
		if result.Receipt != "" {
			if _, err := fmt.Fprintf(a.out, "receipt: %s\n", result.Receipt); err != nil {
				return err
			}
		}
		if result.FilesInstalled {
			if _, err := fmt.Fprintln(a.out, "installed files: durable"); err != nil {
				return err
			}
		}
		if result.ActivationError != "" {
			if _, err := fmt.Fprintf(a.out, "activation: incomplete: %s\n", result.ActivationError); err != nil {
				return err
			}
		}
	}
	if report.Error != "" {
		if _, err := fmt.Fprintf(a.out, "error: %s\n", report.Error); err != nil {
			return err
		}
	}
	if len(report.NextSteps) != 0 {
		if _, err := fmt.Fprintln(a.out, "next steps:"); err != nil {
			return err
		}
	}
	for _, nextStep := range report.NextSteps {
		if _, err := fmt.Fprintf(a.out, "- %s\n", nextStep); err != nil {
			return err
		}
	}
	return nil
}

// formatUserspaceActions renders declarative capabilities without interpreting
// any catalogue text as commands or writable paths.
func formatUserspaceActions(actions userspacecatalog.SupportActions) string {
	var enabled []string
	if actions.Status {
		enabled = append(enabled, "status")
	}
	if actions.Pull {
		enabled = append(enabled, "pull")
	}
	if actions.Build {
		enabled = append(enabled, "build")
	}
	if actions.Install {
		enabled = append(enabled, "install")
	}
	return strings.Join(enabled, ",")
}
