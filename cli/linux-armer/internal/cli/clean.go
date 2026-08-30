package cli

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/cleanup"
)

// newCleanCommand groups detection and reversible removal of recognised legacy workarounds.
func (a *application) newCleanCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "clean",
		Short: "Detect and reversibly remove obsolete SP11 workarounds",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(a.newCleanScanCommand(), a.newCleanPlanCommand(), a.newCleanApplyCommand(), a.newCleanRestoreCommand())
	return command
}

// newCleanScanCommand reports current findings without creating a reviewed plan
// or changing the selected target root.
func (a *application) newCleanScanCommand() *cobra.Command {
	var root string
	var asJSON bool
	command := &cobra.Command{
		Use:   "scan",
		Short: "Detect obsolete workarounds without changing the target system",
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
				status := "recognised"
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

// newCleanPlanCommand records an immutable JSON snapshot that clean apply can
// revalidate later without silently adding newly discovered targets.
func (a *application) newCleanPlanCommand() *cobra.Command {
	var root string
	var output string
	command := &cobra.Command{
		Use:   "plan",
		Short: "Write a reviewed JSON plan without changing the target system",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			report, err := cleanup.Scan(root)
			if err != nil {
				return err
			}
			if output == "-" {
				return a.writeJSON(report)
			}
			if err := writeCleanupPlan(output, report); err != nil {
				return err
			}
			_, err = fmt.Fprintf(a.out, "cleanup plan written: %s\nfindings: %d\n", output, len(report.Findings))
			return err
		},
	}
	command.Flags().StringVar(&root, "root", "/", "target Linux root filesystem")
	command.Flags().StringVarP(&output, "output", "o", "linux-armer-cleanup-plan.json", "new plan path, or - for standard output")
	return command
}

// newCleanApplyCommand requires explicit confirmation before backing up and
// removing only entries from the compiled clean-up allow-list.
func (a *application) newCleanApplyCommand() *cobra.Command {
	var root string
	var planPath string
	var yes bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "apply",
		Short: "Apply an exact reviewed plan with recoverable backups",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			if planPath == "" {
				return errors.New("clean apply requires --plan with a reviewed JSON plan")
			}
			report, err := readCleanupPlan(planPath)
			if err != nil {
				return err
			}
			resolvedRoot, err := cleanup.ResolveRoot(root)
			if err != nil {
				return err
			}
			if report.Root != resolvedRoot {
				return fmt.Errorf("cleanup plan root is %s, but --root resolves to %s", report.Root, resolvedRoot)
			}
			receipt, err := cleanup.Apply(report, yes)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(receipt)
			}
			if len(receipt.Changes) == 0 {
				_, err = fmt.Fprintln(a.out, "no recognised workarounds were removed")
				return err
			}
			_, err = fmt.Fprintf(a.out, "removed %d recognised workarounds\nbackup: %s\nreceipt: %s\n",
				len(receipt.Changes), receipt.Backup, filepath.Join(receipt.Backup, "receipt.json"))
			return err
		},
	}
	command.Flags().StringVar(&root, "root", "/", "target Linux root filesystem")
	command.Flags().StringVar(&planPath, "plan", "", "reviewed plan produced by clean plan")
	command.Flags().BoolVar(&yes, "yes", false, "confirm backup and removal of recognised files")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// newCleanRestoreCommand recreates entries from a verified prepared or
// completed receipt while refusing to overwrite changed local content.
func (a *application) newCleanRestoreCommand() *cobra.Command {
	var root string
	var yes bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "restore <receipt>",
		Short: "Restore verified entries from a cleanup receipt",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			receipt, err := readCleanupReceipt(args[0])
			if err != nil {
				return err
			}
			resolvedRoot, err := cleanup.ResolveRoot(root)
			if err != nil {
				return err
			}
			if receipt.Root != resolvedRoot {
				return fmt.Errorf("cleanup receipt root is %s, but --root resolves to %s", receipt.Root, resolvedRoot)
			}
			report, err := cleanup.Restore(receipt, args[0], yes)
			if asJSON {
				if writeErr := a.writeJSON(report); writeErr != nil {
					return writeErr
				}
				return err
			}
			if err != nil {
				return err
			}
			_, err = fmt.Fprintf(a.out, "restored %d workarounds\nalready present: %d\nreceipt: %s\n",
				len(report.Restored), len(report.AlreadyPresent), args[0])
			return err
		},
	}
	command.Flags().StringVar(&root, "root", "/", "target Linux root filesystem")
	command.Flags().BoolVar(&yes, "yes", false, "confirm restoration of receipt entries")
	command.Flags().BoolVar(&asJSON, "json", false, "write machine-readable JSON")
	return command
}

// writeCleanupPlan creates a private plan exactly once so an existing reviewed
// file cannot be replaced accidentally.
func writeCleanupPlan(path string, report cleanup.ScanReport) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("create cleanup plan: %w", err)
	}
	writeErr := cleanup.WriteJSON(file, report)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		_ = os.Remove(path)
		return fmt.Errorf("write cleanup plan: %w", err)
	}
	return nil
}

// readCleanupPlan opens and strictly decodes one reviewed plan while joining
// read and close failures.
func readCleanupPlan(path string) (cleanup.ScanReport, error) {
	file, err := os.Open(path)
	if err != nil {
		return cleanup.ScanReport{}, fmt.Errorf("open cleanup plan: %w", err)
	}
	report, readErr := cleanup.ReadScanReport(file)
	closeErr := file.Close()
	if err := errors.Join(readErr, closeErr); err != nil {
		return cleanup.ScanReport{}, err
	}
	return report, nil
}

// readCleanupReceipt opens and strictly decodes one recovery receipt while
// joining read and close failures.
func readCleanupReceipt(path string) (cleanup.Receipt, error) {
	file, err := os.Open(path)
	if err != nil {
		return cleanup.Receipt{}, fmt.Errorf("open cleanup receipt: %w", err)
	}
	receipt, readErr := cleanup.ReadReceipt(file)
	closeErr := file.Close()
	if err := errors.Join(readErr, closeErr); err != nil {
		return cleanup.Receipt{}, err
	}
	return receipt, nil
}
