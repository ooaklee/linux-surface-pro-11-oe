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
	userspacecatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspacemanager "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/manager"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/version"
)

// application holds delivery-layer dependencies shared by the command tree.
// Feature behaviour remains in domain packages so commands only parse and
// render user input and output.
type application struct {
	in                   io.Reader
	out                  io.Writer
	errOut               io.Writer
	catalogPath          string
	userspaceCatalogPath string
	loader               catalog.Loader
	images               *manager.ImageManager
	releases             *release.Client
	userspace            *userspacemanager.Manager
}

// NewRootCommand assembles a fully isolated command tree around the supplied
// streams, which keeps both terminal use and automated tests deterministic.
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
	app.userspace = userspacemanager.New(
		userspacecatalog.NewLoader(linuxarmer.UserspaceCatalogFS(), "supported-userspace.json"),
		userspacerelease.NewClient(nil), nil,
	)
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
	root.PersistentFlags().StringVar(&app.catalogPath, "catalog", "", "path to a supported image catalogue override")
	root.PersistentFlags().StringVar(&app.userspaceCatalogPath, "userspace-catalog", "", "path to a supported userspace catalogue override")
	root.AddCommand(
		app.newCatalogCommand(),
		app.newKernelCommand(),
		app.newImageCommand(),
		app.newUserspaceCommand(),
		app.newDoctorCommand(),
		app.newCleanCommand(),
		app.newWizardCommand(),
		app.newVersionCommand(),
	)
	return root
}

// ExecuteContext runs a fresh root command with cancellation and explicit I/O.
func ExecuteContext(ctx context.Context, input io.Reader, output, errorOutput io.Writer) error {
	return NewRootCommand(input, output, errorOutput).ExecuteContext(ctx)
}

// loadCatalog selects the embedded image catalogue or the requested strict override.
func (a *application) loadCatalog() (*catalog.Catalog, error) {
	return a.loader.Load(a.catalogPath)
}

// writeJSON emits stable, indented output without HTML escaping URLs or operators.
func (a *application) writeJSON(value any) error {
	encoder := json.NewEncoder(a.out)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}

// newVersionCommand reports the version metadata injected into release builds.
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

// isTerminalReader distinguishes an interactive launch from piped automation
// so the no-argument command never starts a TUI on a non-terminal stream.
func isTerminalReader(reader io.Reader) bool {
	file, ok := reader.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
