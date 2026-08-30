package cli

import (
	"errors"
	"fmt"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
)

// catalogValidationResult is the stable machine-readable result for both valid
// catalogues and rejected candidate documents.
type catalogValidationResult struct {
	// Valid reports whether loading and every semantic validation rule succeeded.
	Valid bool `json:"valid"`
	// SchemaVersion identifies a successfully loaded catalogue contract.
	SchemaVersion int `json:"schema_version,omitempty"`
	// Entries is the number of entries in a successfully loaded catalogue.
	Entries int `json:"entries,omitempty"`
	// Description is the validated human-readable catalogue description.
	Description string `json:"description,omitempty"`
	// Issues contains structured field diagnostics for semantic failures.
	Issues []catalog.Issue `json:"issues,omitempty"`
	// Error retains a bounded decoding or source error when field issues are not
	// available, and supplies context alongside semantic issues.
	Error string `json:"error,omitempty"`
}

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
		Long:  "List known ARM64 installation images with format, support, experimental, mutability, and checksum-pin status.",
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
			_, _ = fmt.Fprintln(writer, "ID\tIMAGE\tFORMAT\tSUPPORT\tEXPERIMENTAL\tMUTABLE\tCHECKSUM")
			for _, entry := range entries {
				_, _ = fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%t\t%t\t%s\n",
					entry.ID, entry.Name, entry.ArtifactKind, entry.SupportLevel,
					entry.Experimental, entry.Mutable, catalogChecksumStatus(entry.Checksum))
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
		Long:  "Show one catalogue entry, including experimental, mutability, checksum-pin, adapter, and compatibility safety metadata.",
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
			_, err = fmt.Fprintf(a.out, "%s\n\nID: %s\nDistribution: %s\nRelease: %s\nFilename: %s\nArchitecture: %s\nFormat: %s\nSupport: %s\nAdapter: %s\nExperimental: %t\nMutable: %t\nChecksum: %s\nDownload: %s\nWebsite: %s\nLast verified: %s\n",
				entry.Name, entry.ID, entry.Distribution, entry.Release, entry.Filename, entry.Architecture, entry.ArtifactKind,
				entry.SupportLevel, entry.Adapter, entry.Experimental, entry.Mutable, catalogChecksumDescription(entry.Checksum),
				entry.URL, entry.Homepage, entry.LastVerified)
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
		Long:  "Strictly validate a supported image catalogue. With --json, invalid input emits a structured valid:false result and still exits unsuccessfully.",
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
				if asJSON {
					result := catalogValidationResult{Valid: false, Error: err.Error()}
					var validationError *catalog.ValidationError
					if errors.As(err, &validationError) {
						result.Issues = append([]catalog.Issue(nil), validationError.Issues...)
					}
					return errors.Join(err, a.writeJSON(result))
				}
				return err
			}
			result := catalogValidationResult{
				Valid: true, SchemaVersion: mediaCatalog.SchemaVersion,
				Entries: mediaCatalog.Len(), Description: mediaCatalog.Description,
			}
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

// catalogChecksumStatus renders a compact publisher-pin state for catalogue
// table rows without overwhelming the other safety columns.
func catalogChecksumStatus(checksum *catalog.Checksum) string {
	if checksum == nil {
		return "none"
	}
	return checksum.Algorithm
}

// catalogChecksumDescription renders the complete validated publisher digest,
// or makes the absence of any pin explicit in detailed human output.
func catalogChecksumDescription(checksum *catalog.Checksum) string {
	if checksum == nil {
		return "none (source bytes are not publisher-pinned)"
	}
	return checksum.Algorithm + ":" + checksum.Value
}
