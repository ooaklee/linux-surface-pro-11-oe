package cli

import (
	"fmt"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
)

// newCatalogCommand groups read-only operations for the supported image catalogue.
func (a *application) newCatalogCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "catalog",
		Short: "Inspect and validate ARM64 source images",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(a.newCatalogListCommand(), a.newCatalogShowCommand(), a.newCatalogValidateCommand())
	return command
}

// newCatalogListCommand renders every image entry in stable catalogue order.
func (a *application) newCatalogListCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "list",
		Short: "List known ARM64 installation images",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			mediaCatalog, err := a.loadCatalog()
			if err != nil {
				return err
			}
			entries := mediaCatalog.List()
			if asJSON {
				return a.writeJSON(entries)
			}
			writer := tabwriter.NewWriter(a.out, 0, 4, 2, ' ', 0)
			_, _ = fmt.Fprintln(writer, "ID\tIMAGE\tFORMAT\tSUPPORT")
			for _, entry := range entries {
				_, _ = fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", entry.ID, entry.Name, entry.ArtifactKind, entry.SupportLevel)
			}
			return writer.Flush()
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newCatalogShowCommand explains one image's format, support level, and caveats.
func (a *application) newCatalogShowCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "show <id>",
		Short: "Show one catalogue entry",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			mediaCatalog, err := a.loadCatalog()
			if err != nil {
				return err
			}
			entry, ok := mediaCatalog.Get(args[0])
			if !ok {
				return fmt.Errorf("catalog entry %q was not found", args[0])
			}
			if asJSON {
				return a.writeJSON(entry)
			}
			_, err = fmt.Fprintf(a.out, "%s\n\nID: %s\nDistribution: %s\nRelease: %s\nFilename: %s\nArchitecture: %s\nFormat: %s\nSupport: %s\nAdapter: %s\nDownload: %s\nWebsite: %s\nLast verified: %s\n",
				entry.Name, entry.ID, entry.Distribution, entry.Release, entry.Filename, entry.Architecture, entry.ArtifactKind,
				entry.SupportLevel, entry.Adapter, entry.URL, entry.Homepage, entry.LastVerified)
			if err != nil {
				return err
			}
			if len(entry.CompatibilityNotes) > 0 {
				_, _ = fmt.Fprintln(a.out, "Notes:")
				for _, note := range entry.CompatibilityNotes {
					_, _ = fmt.Fprintln(a.out, " -", note)
				}
			}
			return nil
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newCatalogValidateCommand applies strict schema and semantic validation to
// either the shipped catalogue or a user-selected candidate file.
func (a *application) newCatalogValidateCommand() *cobra.Command {
	var asJSON bool
	command := &cobra.Command{
		Use:   "validate [path]",
		Short: "Strictly validate a supported image catalogue",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			var (
				mediaCatalog *catalog.Catalog
				err          error
			)
			if len(args) == 1 {
				mediaCatalog, err = catalog.LoadFile(args[0])
			} else {
				mediaCatalog, err = a.loadCatalog()
			}
			if err != nil {
				return err
			}
			result := struct {
				Valid         bool   `json:"valid"`
				SchemaVersion int    `json:"schema_version"`
				Entries       int    `json:"entries"`
				Description   string `json:"description"`
			}{true, mediaCatalog.SchemaVersion, mediaCatalog.Len(), mediaCatalog.Description}
			if asJSON {
				return a.writeJSON(result)
			}
			_, err = fmt.Fprintf(a.out, "catalog valid: schema %d, %d entries\n", result.SchemaVersion, result.Entries)
			return err
		},
	}
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}
