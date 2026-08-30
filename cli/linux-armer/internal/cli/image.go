package cli

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/ubuntu"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/release"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/manager"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/media"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/version"
)

// removableMediaWorkflow is the delivery layer's narrow view of removable-media
// discovery and execution, which keeps command tests independent of host devices.
type removableMediaWorkflow interface {
	// List returns a fresh read-only whole-device inventory.
	List(context.Context) ([]media.Device, error)
	// Plan binds one validated image to one freshly inspected removable device.
	Plan(context.Context, media.PlanRequest) (media.WritePlan, error)
	// Execute revalidates and performs an immutable write plan.
	Execute(context.Context, media.ExecuteRequest) (media.Receipt, error)
}

// removableMediaFactory creates a platform-specific workflow only when a media
// command runs, so ordinary help and non-media commands remain portable.
type removableMediaFactory func() (removableMediaWorkflow, error)

// imageValidationFunc is the adapter-owned structural validation boundary used
// before linux-armer permits a generated image to reach raw removable media.
type imageValidationFunc func(context.Context, string) (imagecontract.ValidationReport, error)

// mediaWriteResult is the stable machine-readable envelope for a planned,
// completed, or partially completed removable-media operation.
type mediaWriteResult struct {
	// Validation contains the adapter-owned structural evidence for the source ISO.
	Validation imagecontract.ValidationReport `json:"validation"`
	// Plan binds the validated source bytes to one exact removable device.
	Plan media.WritePlan `json:"plan"`
	// Receipt records the furthest durable execution state reached.
	Receipt media.Receipt `json:"receipt"`
	// Error contains a non-empty delivery error only when execution did not complete.
	Error string `json:"error,omitempty"`
}

// newImageCommand groups image creation and independent structural validation.
func (a *application) newImageCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "image",
		Short: "Create and validate Surface Pro 11 installation media",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(
		a.newImageCreateCommand(),
		a.newImageValidateCommand(),
		a.newImageDevicesCommand(),
		a.newImageWriteCommand(),
	)
	return command
}

// newImageDevicesCommand lists fresh whole-device evidence without opening,
// unmounting, writing, or ejecting any storage device.
func (a *application) newImageDevicesCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "devices",
		Short: "List whole storage devices for reviewed USB selection",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			workflow, err := a.newRemovableMediaWorkflow()
			if err != nil {
				return err
			}
			devices, err := workflow.List(command.Context())
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(devices)
			}
			writer := tabwriter.NewWriter(a.out, 0, 4, 2, ' ', 0)
			_, _ = fmt.Fprintln(writer, "PATH\tSIZE\tBUS\tEXTERNAL\tREMOVABLE\tSYSTEM\tIN-USE\tMOUNTS\tNAME")
			for _, device := range devices {
				_, _ = fmt.Fprintf(writer, "%s\t%s\t%s\t%t\t%t\t%t\t%t\t%d\t%s\n",
					device.Path, humanBytes(device.SizeBytes), device.Bus, device.External,
					device.Removable, device.System, device.InUse, len(device.Mounts), device.Name)
				_, _ = fmt.Fprintf(writer, "  fingerprint\t%s\n", device.Fingerprint)
			}
			return writer.Flush()
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newImageWriteCommand validates an ISO before creating and executing one
// immutable, exact-confirmation removable-media write plan.
func (a *application) newImageWriteCommand() *cobra.Command {
	var target string
	var confirmation string
	var dryRun bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "write <iso>",
		Short: "Write and read-back verify a generated ISO on removable USB media",
		Long:  "Structurally validate a linux-armer ISO, bind its complete SHA-256 to one freshly inspected external removable USB device, then require an exact destructive confirmation before writing. The target is read back and verified before ejection.",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			if strings.TrimSpace(target) == "" {
				return errors.New("image write requires --device with a reviewed whole-device path or fingerprint")
			}
			workflow, err := a.newRemovableMediaWorkflow()
			if err != nil {
				return err
			}
			validation, err := a.validateImageForMedia(command.Context(), args[0])
			if err != nil {
				return fmt.Errorf("refuse removable-media write because image validation failed: %w", err)
			}
			operationPlan, err := workflow.Plan(command.Context(), media.PlanRequest{
				ImagePath: args[0], Target: target,
			})
			if err != nil {
				return err
			}
			if err := validateMediaPlanAgreement(validation, operationPlan); err != nil {
				return fmt.Errorf("refuse removable-media write because validated image identity changed: %w", err)
			}

			if !dryRun && confirmation == "" {
				confirmation, err = a.readMediaConfirmation(operationPlan)
				if err != nil {
					result := mediaWriteResult{Validation: validation, Plan: operationPlan, Error: err.Error()}
					return a.writeMediaResult(result, asJSON, err)
				}
			}
			progress := media.ProgressCallback(nil)
			if !asJSON && !dryRun {
				progress = a.writeMediaProgress
			}
			receipt, executeErr := workflow.Execute(command.Context(), media.ExecuteRequest{
				Plan: operationPlan, Confirmation: confirmation, DryRun: dryRun, Progress: progress,
			})
			result := mediaWriteResult{Validation: validation, Plan: operationPlan, Receipt: receipt}
			if executeErr != nil {
				result.Error = executeErr.Error()
			}
			return a.writeMediaResult(result, asJSON, executeErr)
		},
	}
	command.Flags().StringVar(&target, "device", "", "reviewed whole-device path or opaque fingerprint from image devices")
	command.Flags().StringVar(&confirmation, "confirm", "", "exact target-and-image-bound phrase shown by a dry run or interactive prompt")
	command.Flags().BoolVar(&dryRun, "dry-run", false, "validate and print the immutable write plan without changing the target")
	command.Flags().BoolVar(&asJSON, "json", false, "write one machine-readable result envelope")
	return command
}

// validateMediaPlanAgreement binds adapter-owned structural evidence to the
// exact bytes selected by the distribution-neutral removable-media plan.
func validateMediaPlanAgreement(validation imagecontract.ValidationReport, operationPlan media.WritePlan) error {
	if !validation.Valid {
		return errors.New("structural validation report is not valid")
	}
	validatedPath, err := filepath.Abs(validation.Path)
	if err != nil {
		return fmt.Errorf("resolve validated image path: %w", err)
	}
	validatedPath = filepath.Clean(validatedPath)
	if validatedPath != operationPlan.Image.Path {
		return fmt.Errorf("validated path %s does not match planned path %s", validatedPath, operationPlan.Image.Path)
	}
	if validation.Size < 0 || uint64(validation.Size) != operationPlan.Image.SizeBytes {
		return fmt.Errorf("validated size %d does not match planned size %d",
			validation.Size, operationPlan.Image.SizeBytes)
	}
	if validation.SHA256 != operationPlan.Image.SHA256 {
		return fmt.Errorf("validated SHA-256 %s does not match planned SHA-256 %s",
			validation.SHA256, operationPlan.Image.SHA256)
	}
	return nil
}

// newRemovableMediaWorkflow resolves an injected workflow or constructs the
// current host's Darwin or Linux implementation lazily.
func (a *application) newRemovableMediaWorkflow() (removableMediaWorkflow, error) {
	if a.mediaFactory != nil {
		return a.mediaFactory()
	}
	backend, err := media.NewSystemBackend(media.SystemBackendOptions{})
	if err != nil {
		return nil, err
	}
	return media.NewManager(media.ManagerOptions{Backend: backend}), nil
}

// validateImageForMedia invokes the injected validation boundary or the
// implemented Ubuntu Casper adapter's complete structural validator.
func (a *application) validateImageForMedia(ctx context.Context, path string) (imagecontract.ValidationReport, error) {
	if a.imageValidator != nil {
		return a.imageValidator(ctx, path)
	}
	return ubuntu.NewValidator(nil).Validate(ctx, path)
}

// readMediaConfirmation prompts only an interactive terminal and otherwise
// directs automation to the deterministic dry-run plan or --confirm flag.
func (a *application) readMediaConfirmation(operationPlan media.WritePlan) (string, error) {
	if !isTerminalReader(a.in) {
		return "", fmt.Errorf("non-interactive image write requires --confirm %q; obtain it from --dry-run", operationPlan.ConfirmationPhrase)
	}
	if _, err := fmt.Fprintf(a.errOut,
		"WARNING: every byte on %s will be overwritten.\nImage SHA-256: %s\nType this exact phrase to continue:\n%s\n> ",
		operationPlan.Device.Path, operationPlan.Image.SHA256, operationPlan.ConfirmationPhrase); err != nil {
		return "", err
	}
	line, err := bufio.NewReader(a.in).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("read removable-media confirmation: %w", err)
	}
	line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
	return line, nil
}

// writeMediaProgress renders bounded progress on stderr while leaving stdout
// available for stable command results.
func (a *application) writeMediaProgress(progress media.Progress) error {
	percentage := float64(0)
	if progress.TotalBytes != 0 {
		percentage = float64(progress.WrittenBytes) * 100 / float64(progress.TotalBytes)
	}
	_, err := fmt.Fprintf(a.errOut, "\rwriting: %s / %s (%.0f%%)",
		humanBytes(progress.WrittenBytes), humanBytes(progress.TotalBytes), percentage)
	if err == nil && progress.WrittenBytes == progress.TotalBytes {
		_, err = fmt.Fprintln(a.errOut)
	}
	return err
}

// writeMediaResult emits one JSON envelope or a concise human-readable plan,
// partial receipt, or verified completion before preserving any execution error.
func (a *application) writeMediaResult(result mediaWriteResult, asJSON bool, operationErr error) error {
	if asJSON {
		if err := a.writeJSON(result); err != nil {
			return errors.Join(operationErr, err)
		}
		return operationErr
	}
	if result.Receipt.DryRun {
		_, err := fmt.Fprintf(a.out,
			"removable-media write plan validated; no device changes made\nimage: %s\nSHA-256: %s\ntarget: %s\ncapacity: %s\nconfirmation: %s\n",
			result.Plan.Image.Path, result.Plan.Image.SHA256, result.Plan.Device.Path,
			humanBytes(result.Plan.Device.SizeBytes), result.Plan.ConfirmationPhrase)
		return errors.Join(operationErr, err)
	}
	if operationErr != nil {
		_, writeErr := fmt.Fprintf(a.errOut,
			"removable-media operation stopped\nstate: %s\ntarget: %s\nwritten: %s\nverified: %t\nejected: %t\n",
			result.Receipt.State, result.Plan.Device.Path, humanBytes(result.Receipt.WrittenBytes),
			result.Receipt.Verified, result.Receipt.Ejected)
		return errors.Join(operationErr, writeErr)
	}
	_, err := fmt.Fprintf(a.out,
		"removable media written, read back, verified, and ejected\ntarget: %s\nimage SHA-256: %s\nwritten: %s\nreceipt state: %s\n",
		result.Receipt.TargetPath, result.Receipt.Image.SHA256,
		humanBytes(result.Receipt.WrittenBytes), result.Receipt.State)
	return err
}

// humanBytes formats a byte count using compact binary units without losing the
// exact count from JSON plans and receipts.
func humanBytes(value uint64) string {
	const unit = uint64(1024)
	if value < unit {
		return fmt.Sprintf("%d B", value)
	}
	divisor, exponent := unit, 0
	for quotient := value / unit; quotient >= unit && exponent < 5; quotient /= unit {
		divisor *= unit
		exponent++
	}
	return fmt.Sprintf("%.1f %ciB", float64(value)/float64(divisor), "KMGTPE"[exponent])
}

// newImageCreateCommand collects immutable source and kernel inputs before
// handing the complete workflow to the image manager.
func (a *application) newImageCreateCommand() *cobra.Command {
	request := manager.CreateImageRequest{}
	var dryRun bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "create",
		Short: "Create a custom-kernel hybrid ARM64 ISO",
		Long:  "Create and structurally validate an experimental Surface Pro 11 ISO. The Ubuntu Concept Casper adapter is currently the only implemented image adapter.",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			request.CatalogPath = a.catalogPath
			request.UserspaceCatalogPath = a.userspaceCatalogPath
			request.ToolVersion, request.ToolCommit, request.ToolBuildDate = version.Info()
			if dryRun {
				operationPlan, err := a.images.Plan(request)
				if err != nil {
					return err
				}
				return operationPlan.WriteJSON(a.out)
			}
			result, err := a.images.Create(command.Context(), request)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(result)
			}
			return a.writeImageCreateResult(result)
		},
	}
	command.Flags().StringVar(&request.CatalogID, "catalog-id", manager.DefaultCatalogID, "source image catalogue ID")
	command.Flags().StringVar(&request.Source, "source", "", "source ISO path or HTTPS URL (defaults to the catalogue URL)")
	command.Flags().StringVar(&request.SourceSHA256, "source-sha256", "", "expected SHA-256 for the source ISO")
	command.Flags().BoolVar(&request.RefreshSource, "refresh-source", false, "replace the cached copy of a remote mutable source")
	command.Flags().StringVar(&request.KernelDirectory, "kernel-dir", "", "directory containing a local image/modules .deb pair")
	command.Flags().StringVar(&request.KernelRepository, "kernel-repository", release.DefaultRepository, "GitHub owner/repository containing kernel releases")
	command.Flags().StringVar(&request.KernelRelease, "kernel-release", "latest", "kernel release tag, or latest")
	command.Flags().StringVar(&request.CacheDirectory, "cache-dir", "", "download cache (defaults to the user cache directory)")
	command.Flags().StringVar(&request.WorkspaceRoot, "workspace-dir", "", "parent directory for temporary remaster work")
	command.Flags().StringVar(&request.CompanionSourceDirectory, "companion-source-dir", "", "complete linux-armer source directory to archive and cross-build with the host Go toolchain")
	command.Flags().StringSliceVar(&request.CompanionUserspace, "companion-userspace", nil, "redistribution-eligible userspace component to include for offline installation (repeatable)")
	command.Flags().StringVarP(&request.Output, "output", "o", "linux-armer-sp11.iso", "output ISO path")
	command.Flags().BoolVar(&request.KeepWorkspace, "keep-workspace", false, "keep temporary remaster files for debugging")
	command.Flags().BoolVar(&dryRun, "dry-run", false, "print the deterministic workflow plan without downloading or building")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable result JSON")
	return command
}

// writeImageCreateResult reports the validated output and makes an undeclared
// companion licence impossible to overlook in human-readable delivery.
func (a *application) writeImageCreateResult(result manager.CreateImageResult) error {
	_, err := fmt.Fprintf(a.out, "image created and validated\npath: %s\nSHA-256: %s\nsize: %d bytes\nkernel ABI: %s\nmanifest: %s\njournal: %s\n\nSecure Boot must be disabled for the unsigned custom kernel.\n",
		result.Image.OutputISO, result.Image.SHA256, result.Image.Size, result.KernelBundle.ABI,
		result.Image.ManifestPath, result.Image.JournalPath)
	if err == nil && result.Image.CompanionBundle.Included && result.Image.CompanionBundle.ProjectLicence == "not-declared" {
		_, err = fmt.Fprintln(a.out, "The local companion bundle records that the project licence is not declared; do not redistribute it until the copyright holder publishes suitable terms and required notices.")
	}
	return err
}

// newImageValidateCommand rechecks a generated image without modifying it.
func (a *application) newImageValidateCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "validate <iso>",
		Short: "Validate a generated ISO and all version-bound boot artefacts",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			report, err := ubuntu.NewValidator(nil).Validate(command.Context(), args[0])
			if asJSON {
				if writeErr := a.writeJSON(report); writeErr != nil {
					return writeErr
				}
				return err
			}
			for _, check := range report.Checks {
				status := "PASS"
				if !check.Passed {
					status = "FAIL"
				}
				_, _ = fmt.Fprintf(a.out, "%-4s  %-30s %s\n", status, check.Name, check.Details)
			}
			if err != nil {
				return err
			}
			_, err = fmt.Fprintf(a.out, "\nvalid hybrid ISO\nSHA-256: %s\nkernel ABI: %s\n", report.SHA256, report.KernelABI)
			return err
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}
