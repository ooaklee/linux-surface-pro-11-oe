package cli

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/bluetoothmgmt"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff"
	handoffapplication "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff/application"
)

// handoffApplyResult is the stable redacted envelope for a reviewed plan or
// completed application transaction.
type handoffApplyResult struct {
	// Plan is the immutable ID-, identity-, target-, and policy-bound checkpoint.
	Plan handoffapplication.Plan `json:"plan"`
	// Result is present only after successful application.
	Result *handoffapplication.Result `json:"result,omitempty"`
	// Error is fixed prose and never contains private boundary values.
	Error string `json:"error,omitempty"`
}

// handoffRestoreResult is the stable redacted envelope for receipt recovery.
type handoffRestoreResult struct {
	// Plan is the immutable receipt-, recovery-, and target-bound checkpoint.
	Plan handoffapplication.RestorePlan `json:"plan"`
	// Result is present only after successful restoration.
	Result *handoffapplication.RestoreResult `json:"result,omitempty"`
	// Error is fixed prose and never contains private receipt fields.
	Error string `json:"error,omitempty"`
}

// bluetoothAddressSetter is the hidden command's injectable raw management boundary.
type bluetoothAddressSetter func(context.Context, bluetoothmgmt.Address, bluetoothmgmt.Options) error

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
		a.newHandoffApplyCommand(nil),
		a.newHandoffRestoreCommand(nil),
		a.newHandoffPurgeCommand(),
		a.newHandoffInternalBluetoothCommand(nil),
	)
	return command
}

// newHandoffRestoreCommand plans and optionally rolls back one durable private
// application receipt through an injected recovery workflow.
func (a *application) newHandoffRestoreCommand(workflow handoffapplication.RestoreWorkflow) *cobra.Command {
	var targetRoot string
	var confirmation string
	var dryRun bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "restore <receipt-id>",
		Short: "Plan or restore one private application receipt",
		Args:  cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			if strings.TrimSpace(targetRoot) == "" {
				return errors.New("handoff restore requires an explicit --target-root")
			}
			selectedWorkflow := workflow
			if selectedWorkflow == nil {
				selectedWorkflow = handoffapplication.New(nil)
			}
			operationPlan, err := selectedWorkflow.PlanRestore(command.Context(), targetRoot, args[0])
			if err != nil {
				return err
			}
			if dryRun {
				return a.writeHandoffRestoreResult(handoffRestoreResult{Plan: operationPlan}, asJSON, nil)
			}
			if confirmation == "" {
				confirmation, err = a.readHandoffRestoreConfirmation(operationPlan)
				if err != nil {
					return a.writeHandoffRestoreResult(handoffRestoreResult{Plan: operationPlan, Error: "exact restoration confirmation is required"}, asJSON, err)
				}
			}
			restored, restoreErr := selectedWorkflow.Restore(command.Context(), operationPlan, confirmation)
			envelope := handoffRestoreResult{Plan: operationPlan}
			deliveryErr := restoreErr
			if restoreErr != nil {
				envelope.Error = "private hand-off restoration did not complete; the private receipt remains available for inspection"
				deliveryErr = errors.New(envelope.Error)
			} else {
				envelope.Result = &restored
			}
			return a.writeHandoffRestoreResult(envelope, asJSON, deliveryErr)
		},
	}
	command.Flags().StringVar(&targetRoot, "target-root", "", "explicit installed-system or live-USB root containing the private receipt")
	command.Flags().StringVar(&confirmation, "confirm", "", "exact receipt-, recovery-, and target-root-bound phrase shown by a dry run")
	command.Flags().BoolVar(&dryRun, "dry-run", false, "validate and print the immutable restoration plan without changing the target")
	command.Flags().BoolVar(&asJSON, "json", false, "write one redacted machine-readable result envelope")
	return command
}

// newHandoffApplyCommand plans and optionally applies one same-device private
// hand-off through an injected transaction workflow.
func (a *application) newHandoffApplyCommand(workflow handoffapplication.Workflow) *cobra.Command {
	var storeRoot string
	var identityRoot string
	var targetRoot string
	var featureValues []string
	var adspPolicy string
	var confirmation string
	var dryRun bool
	var asJSON bool
	command := &cobra.Command{
		Use:   "apply <id>",
		Short: "Plan or apply private same-device Windows material",
		Long: "Revalidate one imported private hand-off, re-derive its same-device binding from an explicit identity root, and plan fixed target changes. " +
			"Mutation requires the exact dry-run confirmation and effective root.",
		Args: cobra.ExactArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			if strings.TrimSpace(targetRoot) == "" {
				return errors.New("handoff apply requires an explicit --target-root, including --target-root / for the running system")
			}
			features := make([]handoffapplication.Feature, 0, len(featureValues))
			for _, value := range featureValues {
				feature, err := handoffapplication.ParseFeature(value)
				if err != nil {
					return err
				}
				features = append(features, feature)
			}
			resolvedStore, err := resolveHandoffStoreFlag(storeRoot)
			if err != nil {
				return err
			}
			selectedWorkflow := workflow
			if selectedWorkflow == nil {
				selectedWorkflow = handoffapplication.New(nil)
			}
			operationPlan, err := selectedWorkflow.Plan(command.Context(), handoffapplication.Request{
				StoreRoot: resolvedStore, ID: args[0], IdentityRoot: identityRoot,
				TargetRoot: targetRoot, Features: features,
				ADSPPolicy: handoffapplication.ADSPPolicy(strings.ToLower(strings.TrimSpace(adspPolicy))),
			})
			if err != nil {
				return err
			}
			if dryRun {
				return a.writeHandoffApplyResult(handoffApplyResult{Plan: operationPlan}, asJSON, nil)
			}
			if confirmation == "" {
				confirmation, err = a.readHandoffApplyConfirmation(operationPlan)
				if err != nil {
					return a.writeHandoffApplyResult(handoffApplyResult{Plan: operationPlan, Error: "exact application confirmation is required"}, asJSON, err)
				}
			}
			applied, applyErr := selectedWorkflow.Apply(command.Context(), operationPlan, confirmation)
			envelope := handoffApplyResult{Plan: operationPlan}
			deliveryErr := applyErr
			if applyErr != nil {
				envelope.Error = "private hand-off application did not complete; any started mutation was rolled back or retained in its private receipt"
				deliveryErr = errors.New(envelope.Error)
			} else {
				envelope.Result = &applied
			}
			return a.writeHandoffApplyResult(envelope, asJSON, deliveryErr)
		},
	}
	command.Flags().StringVar(&storeRoot, "store", "", "private store root (defaults to a protected directory beneath the current user's home directory)")
	command.Flags().StringVar(&identityRoot, "identity-root", "/", "root containing the live same-device SMBIOS identity")
	command.Flags().StringVar(&targetRoot, "target-root", "", "explicit installed-system or live-USB root to inspect or modify")
	command.Flags().StringSliceVar(&featureValues, "feature", nil, "included feature to apply; repeat for firmware or bluetooth (default: every included feature)")
	command.Flags().StringVar(&adspPolicy, "adsp-policy", "", "required firmware policy: enabled for installed NVMe or disabled for live USB")
	command.Flags().StringVar(&confirmation, "confirm", "", "exact ID-, plan-, and target-root-bound phrase shown by a dry run")
	command.Flags().BoolVar(&dryRun, "dry-run", false, "revalidate and print the immutable application plan without changing the target")
	command.Flags().BoolVar(&asJSON, "json", false, "write one redacted machine-readable result envelope")
	return command
}

// newHandoffInternalBluetoothCommand creates the fixed hidden boot-time entry
// point installed by Bluetooth application transactions.
func (a *application) newHandoffInternalBluetoothCommand(setter bluetoothAddressSetter) *cobra.Command {
	command := &cobra.Command{
		Use:    "internal-bluetooth-address",
		Hidden: true,
		Args:   cobra.NoArgs,
		RunE: func(command *cobra.Command, _ []string) error {
			address, controllerSelector, err := handoffapplication.ReadBluetoothRuntimeConfig(command.Context(), "/")
			if err != nil {
				return err
			}
			selectedSetter := setter
			if selectedSetter == nil {
				selectedSetter = bluetoothmgmt.Set
			}
			if err := selectedSetter(command.Context(), address, bluetoothmgmt.Options{ControllerSelector: controllerSelector}); err != nil {
				return err
			}
			return nil
		},
	}
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
			_, _ = fmt.Fprintln(writer, "SCHEMA\tID\tFIRMWARE\tBLUETOOTH")
			for _, stored := range summaries {
				_, _ = fmt.Fprintf(writer, "%d\t%s\t%d files\t%t\n",
					stored.Summary.SchemaVersion, stored.ID, stored.Summary.FirmwareFiles,
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

// readHandoffApplyConfirmation prompts only an interactive terminal and keeps
// automation on the deterministic --dry-run and --confirm path.
func (a *application) readHandoffApplyConfirmation(operationPlan handoffapplication.Plan) (string, error) {
	if !isTerminalReader(a.in) {
		return "", fmt.Errorf("non-interactive hand-off application requires --confirm %q; obtain it from --dry-run", operationPlan.Confirmation)
	}
	if _, err := fmt.Fprintf(a.errOut,
		"This applies one same-device private hand-off to the reviewed target root.\nID: %s\nRequired changes: %d\nType this exact phrase to continue:\n%s\n> ",
		operationPlan.ID, operationPlan.RequiredChanges, operationPlan.Confirmation); err != nil {
		return "", err
	}
	line, err := bufio.NewReader(a.in).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("read hand-off application confirmation: %w", err)
	}
	line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
	return line, nil
}

// writeHandoffApplyResult emits one redacted JSON envelope or a concise plan
// and preserves an application error after the complete envelope is written.
func (a *application) writeHandoffApplyResult(result handoffApplyResult, asJSON bool, operationErr error) error {
	if asJSON {
		if err := a.writeJSON(result); err != nil {
			return errors.Join(operationErr, err)
		}
		return operationErr
	}
	if result.Result != nil {
		state := "applied"
		if result.Result.AlreadyApplied {
			state = "already applied"
		}
		_, writeErr := fmt.Fprintf(a.out,
			"private Windows hand-off %s\nID: %s\nplan SHA-256: %s\ntarget root: %s\nchanged objects: %d\nreceipt ID: %s\n",
			state, result.Result.ID, result.Result.PlanSHA256, result.Result.TargetRoot,
			result.Result.Changed, result.Result.ReceiptID)
		return errors.Join(operationErr, writeErr)
	}
	if operationErr != nil {
		_, writeErr := fmt.Fprintf(a.errOut,
			"private Windows hand-off application did not complete\nID: %s\nplan SHA-256: %s\ntarget root: %s\n",
			result.Plan.ID, result.Plan.PlanSHA256, result.Plan.TargetRoot)
		return errors.Join(operationErr, writeErr)
	}
	writer := tabwriter.NewWriter(a.out, 0, 4, 2, ' ', 0)
	_, _ = fmt.Fprintln(writer, "FEATURE\tPATH\tKIND\tCHANGE")
	for _, change := range result.Plan.Changes {
		state := "unchanged"
		if change.Required {
			state = "required"
		}
		_, _ = fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", change.Feature, change.Path, change.Kind, state)
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	_, err := fmt.Fprintf(a.out,
		"\nprivate Windows hand-off application plan validated; nothing changed\nID: %s\nplan SHA-256: %s\ntarget root: %s\nrequired changes: %d\nLinux ARM64 helper compatible: %t\nconfirmation: %s\n",
		result.Plan.ID, result.Plan.PlanSHA256, result.Plan.TargetRoot,
		result.Plan.RequiredChanges, result.Plan.HostBinaryCompatible, result.Plan.Confirmation)
	return err
}

// readHandoffRestoreConfirmation prompts only an interactive terminal and keeps
// automation on the deterministic --dry-run and --confirm path.
func (a *application) readHandoffRestoreConfirmation(operationPlan handoffapplication.RestorePlan) (string, error) {
	if !isTerminalReader(a.in) {
		return "", fmt.Errorf("non-interactive hand-off restoration requires --confirm %q; obtain it from --dry-run", operationPlan.Confirmation)
	}
	if _, err := fmt.Fprintf(a.errOut,
		"This restores the original target state recorded by one private receipt.\nReceipt ID: %s\nRequired recovery changes: %d\nType this exact phrase to continue:\n%s\n> ",
		operationPlan.ReceiptID, operationPlan.RequiredChanges, operationPlan.Confirmation); err != nil {
		return "", err
	}
	line, err := bufio.NewReader(a.in).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", fmt.Errorf("read hand-off restoration confirmation: %w", err)
	}
	line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
	return line, nil
}

// writeHandoffRestoreResult emits one redacted JSON envelope or concise
// recovery state before preserving any restoration error.
func (a *application) writeHandoffRestoreResult(result handoffRestoreResult, asJSON bool, operationErr error) error {
	if asJSON {
		if err := a.writeJSON(result); err != nil {
			return errors.Join(operationErr, err)
		}
		return operationErr
	}
	if result.Result != nil {
		state := "restored"
		if result.Result.AlreadyRestored {
			state = "already restored"
		}
		_, writeErr := fmt.Fprintf(a.out,
			"private Windows hand-off receipt %s\nreceipt ID: %s\ntarget root: %s\nchanged actions: %d\n",
			state, result.Result.ReceiptID, result.Result.TargetRoot, result.Result.Changed)
		return errors.Join(operationErr, writeErr)
	}
	if operationErr != nil {
		_, writeErr := fmt.Fprintf(a.errOut,
			"private Windows hand-off restoration did not complete\nreceipt ID: %s\nrecovery SHA-256: %s\ntarget root: %s\n",
			result.Plan.ReceiptID, result.Plan.RecoverySHA256, result.Plan.TargetRoot)
		return errors.Join(operationErr, writeErr)
	}
	_, err := fmt.Fprintf(a.out,
		"private Windows hand-off restoration plan validated; nothing changed\nreceipt ID: %s\nreceipt state: %s\nrecovery SHA-256: %s\ntarget root: %s\nrequired recovery changes: %d\nconfirmation: %s\n",
		result.Plan.ReceiptID, result.Plan.ReceiptState, result.Plan.RecoverySHA256,
		result.Plan.TargetRoot, result.Plan.RequiredChanges, result.Plan.Confirmation)
	return err
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
