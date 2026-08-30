package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/doctor"
)

// newDoctorCommand checks host image-building prerequisites and provides the
// nested userspace doctor for installed-system support checks.
func (a *application) newDoctorCommand() *cobra.Command {
	var workspace string
	var asJSON bool
	command := &cobra.Command{
		Use:   "doctor",
		Short: "Check whether this host can build and validate images",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			report := doctor.New(nil).Run(command.Context(), workspace)
			if asJSON {
				if err := a.writeJSON(report); err != nil {
					return err
				}
			} else {
				for _, check := range report.Checks {
					_, _ = fmt.Fprintf(a.out, "%-4s  %-20s %s\n", check.Status, check.Name, check.Details)
				}
			}
			if !report.Ready {
				return fmt.Errorf("required host checks failed")
			}
			return nil
		},
	}
	command.Flags().StringVar(&workspace, "workspace", ".", "directory that will hold temporary image data")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	command.AddCommand(a.newUserspaceStatusDeliveryCommand("userspace", "Report missing Surface Pro 11 userspace support"))
	return command
}
