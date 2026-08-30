package cli

import (
	"context"
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/manager"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/tui"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/version"
)

// newWizardCommand starts the guided Bubble Tea image workflow explicitly.
func (a *application) newWizardCommand() *cobra.Command {
	request := manager.CreateImageRequest{}
	command := &cobra.Command{
		Use:   "wizard",
		Short: "Interactively choose and create an installation image",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			request.CatalogPath = a.catalogPath
			return a.runWizardWithRequest(command.Context(), request)
		},
	}
	command.Flags().StringVarP(&request.Output, "output", "o", "linux-armer-sp11.iso", "output ISO path")
	command.Flags().StringVar(&request.Source, "source", "", "source ISO path or HTTPS URL")
	command.Flags().StringVar(&request.SourceSHA256, "source-sha256", "", "expected source ISO SHA-256")
	command.Flags().StringVar(&request.KernelDirectory, "kernel-dir", "", "directory containing local kernel packages")
	command.Flags().StringVar(&request.KernelRelease, "kernel-release", "latest", "kernel release tag, or latest")
	command.Flags().StringVar(&request.CacheDirectory, "cache-dir", "", "download cache directory")
	return command
}

// runWizard collects a request interactively and returns cleanly when the user cancels.
func (a *application) runWizard(ctx context.Context) error {
	return a.runWizardWithRequest(ctx, manager.CreateImageRequest{
		CatalogPath: a.catalogPath,
		Output:      "linux-armer-sp11.iso",
	})
}

// runWizardWithRequest renders the wizard, then executes its confirmed request
// through the same manager used by non-interactive commands.
func (a *application) runWizardWithRequest(ctx context.Context, request manager.CreateImageRequest) error {
	if !isTerminalReader(a.in) {
		return errors.New("the wizard requires an interactive terminal; use image create for scripts")
	}
	mediaCatalog, err := a.loader.Load(request.CatalogPath)
	if err != nil {
		return err
	}
	selection, selected, err := tui.Run(mediaCatalog.List(), request.Output, describeWizardKernel(request), a.in, a.out)
	if err != nil {
		return err
	}
	if !selected {
		return nil
	}
	request.CatalogID = selection.CatalogID
	request.Output = selection.Output
	request.ToolVersion, _, _ = version.Info()
	result, err := a.images.Create(ctx, request)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(a.out, "\nimage created and validated\npath: %s\nSHA-256: %s\nkernel ABI: %s\nmanifest: %s\n\nSecure Boot must be disabled.\n",
		result.Image.OutputISO, result.Image.SHA256, result.KernelBundle.ABI, result.Image.ManifestPath)
	return err
}

// describeWizardKernel states which kernel input the wizard will resolve while
// making clear that validation happens only after the operator confirms.
func describeWizardKernel(request manager.CreateImageRequest) string {
	if request.KernelDirectory != "" {
		return fmt.Sprintf("local bundle %s (validated before building)", request.KernelDirectory)
	}
	if request.KernelRelease == "" || request.KernelRelease == "latest" {
		return "latest linux-armer release (verified before building)"
	}
	return fmt.Sprintf("release %s (verified before building)", request.KernelRelease)
}
