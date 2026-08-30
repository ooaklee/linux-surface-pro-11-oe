package cli

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff"
)

// handoffPurgeResult is the stable machine-readable envelope for a reviewed or
// completed private hand-off purge.
type handoffPurgeResult struct {
	// Plan binds deletion to one exact validated private closed set.
	Plan handoff.PurgePlan `json:"plan"`
	// Purged reports whether the planned private entry was removed.
	Purged bool `json:"purged"`
	// Error contains a non-empty delivery error when deletion did not complete.
	Error string `json:"error,omitempty"`
}

// newHandoffCommand groups private, device-bound Windows evidence operations
// separately from redistributable userspace release management.
func (a *application) newHandoffCommand() *cobra.Command {
	command := &cobra.Command{
		Use:   "handoff",
		Short: "Manage private device-bound Windows evidence",
		Long:  "Import and manage strictly validated private Windows hand-offs. Hand-off documents and payloads must never be included in an ISO or redistributed.",
		Args:  cobra.NoArgs,
	}
	command.AddCommand(
		a.newHandoffImportCommand(),
		a.newHandoffListCommand(),
		a.newHandoffPurgeCommand(),
	)
	return command
}

// newHandoffImportCommand validates and atomically publishes one exact source
// directory into the private content-addressed store.
func (a *application) newHandoffImportCommand() *cobra.Command {
	var storeRoot string
	var asJSON bool
	command := &cobra.Command{
		Use:   "import <directory>",
		Short: "Import a strict private Windows hand-off",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			resolvedStore, err := resolveHandoffStoreFlag(storeRoot)
			if err != nil {
				return err
			}
			result, err := handoff.Import(command.Context(), args[0], resolvedStore)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(result)
			}
			state := "imported"
			if result.Existing {
				state = "already present and fully revalidated"
			}
			_, err = fmt.Fprintf(a.out,
				"private Windows hand-off %s\nID: %s\nstore: %s\nplatform firmware: %t (%d files)\nBluetooth evidence: %t\n\nKeep this device-bound material private; it is not an ISO companion or redistributable release.\n",
				state, result.ID, result.Path, result.Summary.FirmwareIncluded,
				result.Summary.FirmwareFiles, result.Summary.BluetoothIncluded)
			return err
		},
	}
	command.Flags().StringVar(&storeRoot, "store", "", "private store root (defaults to a protected directory beneath the current user's home directory)")
	command.Flags().BoolVar(&asJSON, "json", false, "write a redacted machine-readable result")
	return command
}

// newHandoffListCommand validates every stored entry before returning only its
// deliberately redacted summary.
func (a *application) newHandoffListCommand() *cobra.Command {
	var storeRoot string
	var asJSON bool
	command := &cobra.Command{
		Use:   "list",
		Short: "List and revalidate private Windows hand-offs",
		Args:  cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			resolvedStore, err := resolveHandoffStoreFlag(storeRoot)
			if err != nil {
				return err
			}
			summaries, err := handoff.List(command.Context(), resolvedStore)
			if err != nil {
				return err
			}
			if asJSON {
				return a.writeJSON(summaries)
			}
			if len(summaries) == 0 {
				_, err = fmt.Fprintln(a.out, "no private Windows hand-offs are stored")
				return err
			}
			writer := tabwriter.NewWriter(a.out, 0, 4, 2, ' ', 0)
			_, _ = fmt.Fprintln(writer, "ID\tFIRMWARE\tBLUETOOTH")
			for _, stored := range summaries {
				_, _ = fmt.Fprintf(writer, "%s\t%d files\t%t\n",
					stored.ID, stored.Summary.FirmwareFiles,
					stored.Summary.BluetoothIncluded)
			}
			return writer.Flush()
		},
	}
	command.Flags().StringVar(&storeRoot, "store", "", "private store root (defaults to a protected directory beneath the current user's home directory)")
	command.Flags().BoolVar(&asJSON, "json", false, "write redacted machine-readable summaries")
	return command
}

// newHandoffPurgeCommand plans and optionally removes one exact store child
// without accepting a blanket affirmative or recursively deleting an unchecked path.
func (a *application) newHandoffPurgeCommand() *cobra.Command {
	var storeRoot string
	var confirmation string
	var dryRun bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "purge <id>",
		Short: "Purge one reviewed private Windows hand-off",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			resolvedStore, err := resolveHandoffStoreFlag(storeRoot)
			if err != nil {
				return err
			}
			operationPlan, err := handoff.PlanPurge(command.Context(), resolvedStore, args[0])
			if err != nil {
				return err
			}
			if dryRun {
				return a.writeHandoffPurgeResult(handoffPurgeResult{Plan: operationPlan}, asJSON, nil)
			}
			if confirmation == "" {
				confirmation, err = a.readHandoffPurgeConfirmation(operationPlan)
				if err != nil {
					result := handoffPurgeResult{Plan: operationPlan, Error: err.Error()}
					return a.writeHandoffPurgeResult(result, asJSON, err)
				}
			}
			purgeErr := handoff.Purge(command.Context(), operationPlan, confirmation)
			result := handoffPurgeResult{Plan: operationPlan, Purged: purgeErr == nil}
			if purgeErr != nil {
				result.Error = purgeErr.Error()
			}
			return a.writeHandoffPurgeResult(result, asJSON, purgeErr)
		},
	}
	command.Flags().StringVar(&storeRoot, "store", "", "private store root (defaults to a protected directory beneath the current user's home directory)")
	command.Flags().StringVar(&confirmation, "confirm", "", "exact content-addressed confirmation shown by a dry run or interactive prompt")
	command.Flags().BoolVar(&dryRun, "dry-run", false, "validate and print the purge plan without removing anything")
	command.Flags().BoolVar(&asJSON, "json", false, "write one redacted machine-readable result envelope")
	return command
}

// resolveHandoffStoreFlag selects an explicit store or a stable private path
// whose direct parent is guaranteed to exist on ordinary user accounts.
func resolveHandoffStoreFlag(value string) (string, error) {
	if strings.TrimSpace(value) != "" {
		return value, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve default Windows hand-off store: %w", err)
	}
	if strings.TrimSpace(home) == "" {
		return "", errors.New("resolve default Windows hand-off store: user home directory is empty")
	}
	return filepath.Join(home, ".linux-armer-handoffs"), nil
}

// readHandoffPurgeConfirmation prompts only an interactive terminal and keeps
// automation on the deterministic --dry-run and --confirm path.
func (a *application) readHandoffPurgeConfirmation(operationPlan handoff.PurgePlan) (string, error) {
	if !isTerminalReader(a.in) {
		return "", fmt.Errorf("non-interactive hand-off purge requires --confirm %q; obtain it from --dry-run", operationPlan.Confirmation)
	}
	if _, err := fmt.Fprintf(a.errOut,
		"This permanently removes one validated private hand-off.\nID: %s\nType this exact phrase to continue:\n%s\n> ",
		operationPlan.ID, operationPlan.Confirmation); err != nil {
		return "", err
	}
	line, err := bufio.NewReader(a.in).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("read hand-off purge confirmation: %w", err)
	}
	line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
	return line, nil
}

// writeHandoffPurgeResult emits one redacted JSON envelope or a concise reviewed
// plan/completion before preserving any purge error.
func (a *application) writeHandoffPurgeResult(result handoffPurgeResult, asJSON bool, operationErr error) error {
	if asJSON {
		if err := a.writeJSON(result); err != nil {
			return errors.Join(operationErr, err)
		}
		return operationErr
	}
	if result.Purged {
		_, err := fmt.Fprintf(a.out, "private Windows hand-off purged\nID: %s\n", result.Plan.ID)
		return err
	}
	if operationErr != nil {
		_, writeErr := fmt.Fprintf(a.errOut,
			"private Windows hand-off was not purged\nID: %s\nclosed-set SHA-256: %s\n",
			result.Plan.ID, result.Plan.ClosedSetSHA256)
		return errors.Join(operationErr, writeErr)
	}
	_, err := fmt.Fprintf(a.out,
		"private Windows hand-off purge plan validated; nothing removed\nID: %s\nclosed-set SHA-256: %s\nconfirmation: %s\n",
		result.Plan.ID, result.Plan.ClosedSetSHA256, result.Plan.Confirmation)
	return err
}
