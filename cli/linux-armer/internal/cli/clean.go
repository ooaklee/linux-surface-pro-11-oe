package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/cleanup"
)

func (a *application) newCleanCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "clean",
		Short: "Detect and reversibly remove obsolete SP11 workarounds",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(a.newCleanScanCommand("scan"), a.newCleanScanCommand("plan"), a.newCleanApplyCommand())
	return command
}

func (a *application) newCleanScanCommand(use string) *cobra.Command {
	var root string
	var asJSON bool
	short := "Detect obsolete workarounds without changing the target system"
	if use == "plan" {
		short = "Plan the recognized cleanup changes without applying them"
	}
	command := &cobra.Command{
		Use:   use,
		Short: short,
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			report, err := cleanup.Scan(root)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(report)
			}
			if len(report.Findings) == 0 {
				_, err = fmt.Fprintln(a.out, "no known obsolete workarounds detected")
				return err
			}
			for _, finding := range report.Findings {
				status := "recognized"
				if !finding.Recognized {
					status = "manual-review"
				}
				_, _ = fmt.Fprintf(a.out, "%-13s %-22s %s\n", status, finding.Rule.ID, finding.Path)
				_, _ = fmt.Fprintln(a.out, " ", finding.Details)
			}
			return nil
		},
	}
	command.Flags().StringVar(&root, "root", "/", "target Linux root filesystem")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

func (a *application) newCleanApplyCommand() *cobra.Command {
	var root string
	var yes bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "apply",
		Short: "Back up and remove recognized obsolete workarounds",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			report, err := cleanup.Scan(root)
			if err != nil {
				return err
			}
			receipt, err := cleanup.Apply(report, yes)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(receipt)
			}
			if len(receipt.Changes) == 0 {
				_, err = fmt.Fprintln(a.out, "no recognized workarounds were removed")
				return err
			}
			_, err = fmt.Fprintf(a.out, "removed %d recognized workarounds\nbackup: %s\n", len(receipt.Changes), receipt.Backup)
			return err
		},
	}
	command.Flags().StringVar(&root, "root", "/", "target Linux root filesystem")
	command.Flags().BoolVar(&yes, "yes", false, "confirm backup and removal of recognized files")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}
