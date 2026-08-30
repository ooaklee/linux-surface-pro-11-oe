// Package cli assembles Cobra commands without leaking delivery concerns into
// the feature packages.
package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	linuxarmer "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/release"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/manager"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/version"
)

type application struct {
	in          io.Reader
	out         io.Writer
	errOut      io.Writer
	catalogPath string
	loader      catalog.Loader
	images      *manager.ImageManager
	releases    *release.Client
}

func NewRootCommand(input io.Reader, output, errorOutput io.Writer) *cobra.Command {
	if input == nil {
		input = os.Stdin
	}
	if output == nil {
		output = os.Stdout
	}
	if errorOutput == nil {
		errorOutput = os.Stderr
	}
	loader := catalog.NewLoader(linuxarmer.CatalogFS(), "supported-isos.json")
	app := &application{
		in: input, out: output, errOut: errorOutput, loader: loader,
		releases: release.NewClient(nil),
	}
	app.images = manager.NewImageManager(loader, errorOutput)
	buildVersion, _, _ := version.Info()
	root := &cobra.Command{
		Use:           "linux-armer",
		Short:         "Build Surface Pro 11 ARM64 installation media",
		Long:          "linux-armer builds and validates experimental ARM64 installation media with an ABI-matched Surface Pro 11 kernel and device trees.",
		Version:       buildVersion,
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			if !isTerminalReader(input) {
				return command.Help()
			}
			return app.runWizard(command.Context())
		},
	}
	root.SetIn(input)
	root.SetOut(output)
	root.SetErr(errorOutput)
	root.Flags().SortFlags = false
	root.PersistentFlags().StringVar(&app.catalogPath, "catalog", "", "path to a supported image catalog override")
	root.AddCommand(
		app.newCatalogCommand(),
		app.newKernelCommand(),
		app.newImageCommand(),
		app.newDoctorCommand(),
		app.newCleanCommand(),
		app.newWizardCommand(),
		app.newVersionCommand(),
	)
	return root
}

func ExecuteContext(ctx context.Context, input io.Reader, output, errorOutput io.Writer) error {
	return NewRootCommand(input, output, errorOutput).ExecuteContext(ctx)
}

func (a *application) loadCatalog() (*catalog.Catalog, error) {
	return a.loader.Load(a.catalogPath)
}

func (a *application) writeJSON(value any) error {
	encoder := json.NewEncoder(a.out)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}

func (a *application) newVersionCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print build version information",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			buildVersion, commit, date := version.Info()
			_, err := fmt.Fprintf(a.out, "linux-armer %s\ncommit: %s\nbuilt: %s\n", buildVersion, commit, date)
			return err
		},
	}
}

func isTerminalReader(reader io.Reader) bool {
	file, ok := reader.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
