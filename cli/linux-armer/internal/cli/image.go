package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/ubuntu"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/release"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/manager"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/version"
)

// newImageCommand groups image creation and independent structural validation.
func (a *application) newImageCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "image",
		Short: "Create and validate Surface Pro 11 installation media",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(a.newImageCreateCommand(), a.newImageValidateCommand())
	return command
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
