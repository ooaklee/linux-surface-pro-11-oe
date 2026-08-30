package application

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strconv"
)

const (
	// restorePlanDomain separates private receipt recovery from application plans.
	restorePlanDomain = "linux-armer.windows-handoff/restore-plan/v1\x00"
	// restoreConfirmationPrefix prevents a generic affirmative from restoring data.
	restoreConfirmationPrefix = "restore "
)

// restoreObservation retains transient target evidence outside public output.
type restoreObservation struct {
	// stagePresent records whether a validated unpublished object remains.
	stagePresent []bool
	// actionChanges counts payload actions requiring recovery independently of the journal.
	actionChanges int
}

// PlanRestore validates one private receipt, confines it to its original
// explicit target root, and reconciles crash-window filesystem observations.
func (manager *Manager) PlanRestore(ctx context.Context, targetRoot, receiptID string) (RestorePlan, error) {
	if manager == nil {
		return RestorePlan{}, errors.New("hand-off application manager is not initialised")
	}
	if ctx == nil {
		return RestorePlan{}, errors.New("plan private hand-off restoration: context is nil")
	}
	if err := ctx.Err(); err != nil {
		return RestorePlan{}, err
	}
	if !validLowerHexDigest(receiptID) {
		return RestorePlan{}, errors.New("private hand-off receipt ID is not a canonical SHA-256 digest")
	}
	resolvedTarget, err := resolveExplicitRoot(targetRoot, "target root", false)
	if err != nil {
		return RestorePlan{}, err
	}
	root, err := os.OpenRoot(resolvedTarget)
	if err != nil {
		return RestorePlan{}, fmt.Errorf("open target root for restoration: %w", err)
	}
	defer root.Close()
	receipt, err := readReceipt(ctx, root, receiptID)
	if err != nil {
		return RestorePlan{}, err
	}
	if receipt.TargetRoot != resolvedTarget {
		return RestorePlan{}, errors.New("private hand-off receipt is bound to a different target root")
	}
	reconciled, observation, err := reconcileReceipt(ctx, root, receipt)
	if err != nil {
		return RestorePlan{}, err
	}
	required := observation.actionChanges
	if reconciled.State != receiptRolledBack {
		required++
	}
	plan := RestorePlan{
		ReceiptID: receiptID, TargetRoot: resolvedTarget,
		ReceiptState: string(receipt.State), RequiredChanges: required,
		receipt: reconciled,
	}
	plan.RecoverySHA256 = digestRestorePlan(plan, observation)
	plan.Confirmation = restoreConfirmationPrefix + plan.ReceiptID + " recovery " + plan.RecoverySHA256 + " from " + plan.TargetRoot
	return plan, nil
}

// Restore re-plans immediately before mutation and rolls the exact private
// receipt back only after an exact recovery- and target-bound confirmation.
func (manager *Manager) Restore(ctx context.Context, reviewed RestorePlan, exactConfirmation string) (RestoreResult, error) {
	if manager == nil {
		return RestoreResult{}, errors.New("hand-off application manager is not initialised")
	}
	if ctx == nil {
		return RestoreResult{}, errors.New("restore private hand-off receipt: context is nil")
	}
	if reviewed.Confirmation == "" || exactConfirmation != reviewed.Confirmation {
		return RestoreResult{}, errors.New("hand-off restoration requires the exact receipt-, recovery-, and target-root-bound confirmation")
	}
	current, err := manager.PlanRestore(ctx, reviewed.TargetRoot, reviewed.ReceiptID)
	if err != nil {
		return RestoreResult{}, err
	}
	if reviewed.ReceiptID != current.ReceiptID || reviewed.TargetRoot != current.TargetRoot ||
		reviewed.RecoverySHA256 != current.RecoverySHA256 || reviewed.Confirmation != current.Confirmation ||
		reviewed.RequiredChanges != current.RequiredChanges {
		return RestoreResult{}, errors.New("hand-off restoration plan no longer matches the private receipt or target state")
	}
	result := RestoreResult{ReceiptID: current.ReceiptID, TargetRoot: current.TargetRoot}
	if current.RequiredChanges == 0 {
		result.Restored = true
		result.AlreadyRestored = true
		return result, nil
	}
	if manager.effectiveUID == nil || manager.effectiveUID() != 0 {
		return RestoreResult{}, errors.New("hand-off restoration mutation requires effective root")
	}
	root, err := os.OpenRoot(current.TargetRoot)
	if err != nil {
		return RestoreResult{}, fmt.Errorf("open target root for restoration: %w", err)
	}
	defer root.Close()
	for _, action := range current.receipt.Actions {
		if action.Applied || action.BackupCreated {
			result.Changed++
			continue
		}
		if action.StagePath != "" {
			if _, err := root.Lstat(action.StagePath); err == nil {
				result.Changed++
			}
		}
	}
	if err := rollbackTransaction(ctx, root, &current.receipt); err != nil {
		return RestoreResult{}, err
	}
	result.Restored = true
	return result, nil
}

// reconcileReceipt converts possible journal-write crash windows into a safe
// in-memory rollback state after verifying every current object and backup.
func reconcileReceipt(ctx context.Context, root *os.Root, receipt privateReceipt) (privateReceipt, restoreObservation, error) {
	observation := restoreObservation{stagePresent: make([]bool, len(receipt.Actions))}
	for index := range receipt.Actions {
		entry := &receipt.Actions[index]
		if !entry.Required {
			matches, err := receiptOriginalTargetMatches(ctx, root, *entry)
			if err != nil || !matches {
				return privateReceipt{}, restoreObservation{}, fmt.Errorf("unchanged receipt target no longer matches compiled action %s", entry.ID)
			}
			continue
		}
		if entry.StagePath != "" {
			present, err := receiptStageMatches(ctx, root, *entry)
			if err != nil {
				return privateReceipt{}, restoreObservation{}, fmt.Errorf("validate receipt staging object for %s: %w", entry.ID, err)
			}
			observation.stagePresent[index] = present
		}
		backupPresent := false
		if entry.OriginalKind != originalAbsent {
			var err error
			backupPresent, err = optionalReceiptBackupMatches(ctx, root, *entry)
			if err != nil {
				return privateReceipt{}, restoreObservation{}, fmt.Errorf("validate receipt backup for %s: %w", entry.ID, err)
			}
		}
		desiredMatches, desiredErr := receiptDesiredMatches(ctx, root, *entry)
		originalMatches, originalErr := receiptOriginalTargetMatches(ctx, root, *entry)
		if desiredErr != nil || originalErr != nil {
			return privateReceipt{}, restoreObservation{}, fmt.Errorf("validate current receipt target for %s", entry.ID)
		}
		switch {
		case backupPresent && desiredMatches:
			entry.BackupCreated = true
			entry.Applied = true
		case backupPresent && entry.DesiredKind != ChangeAbsent && targetPathAbsent(root, entry.Path):
			entry.BackupCreated = true
			entry.Applied = false
		case !backupPresent && originalMatches:
			entry.BackupCreated = false
			entry.Applied = false
		case entry.OriginalKind == originalAbsent && desiredMatches:
			entry.BackupCreated = false
			entry.Applied = true
		default:
			return privateReceipt{}, restoreObservation{}, fmt.Errorf("current target cannot be restored safely for compiled action %s", entry.ID)
		}
		if entry.Applied || entry.BackupCreated || observation.stagePresent[index] {
			observation.actionChanges++
		}
	}
	return receipt, observation, nil
}

// receiptStageMatches checks an optional staging object against desired metadata.
func receiptStageMatches(ctx context.Context, root *os.Root, entry receiptAction) (bool, error) {
	if _, err := root.Lstat(entry.StagePath); errors.Is(err, fs.ErrNotExist) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	staged := entry
	staged.Path = entry.StagePath
	return receiptDesiredMatches(ctx, root, staged)
}

// optionalReceiptBackupMatches distinguishes an absent backup from a corrupt one.
func optionalReceiptBackupMatches(ctx context.Context, root *os.Root, entry receiptAction) (bool, error) {
	if _, err := root.Lstat(entry.BackupPath); errors.Is(err, fs.ErrNotExist) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	matches, err := receiptBackupMatches(ctx, root, entry)
	if err != nil {
		return false, err
	}
	if !matches {
		return false, errors.New("same-filesystem backup does not match its private receipt")
	}
	return true, nil
}

// receiptOriginalTargetMatches checks the current target against its recorded
// pre-transaction absence, regular file, or symbolic link.
func receiptOriginalTargetMatches(ctx context.Context, root *os.Root, entry receiptAction) (bool, error) {
	if entry.OriginalKind == originalAbsent {
		return targetPathAbsent(root, entry.Path), nil
	}
	if _, err := root.Lstat(entry.Path); errors.Is(err, fs.ErrNotExist) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	copy := entry
	copy.BackupPath = entry.Path
	return receiptBackupMatches(ctx, root, copy)
}

// targetPathAbsent reports only a confirmed missing descriptor-confined path.
func targetPathAbsent(root *os.Root, relativePath string) bool {
	_, err := root.Lstat(relativePath)
	return errors.Is(err, fs.ErrNotExist)
}

// digestRestorePlan binds private receipt state and crash-window observations
// without exposing their reusable contents.
func digestRestorePlan(plan RestorePlan, observation restoreObservation) string {
	digest := sha256.New()
	writeDigestField(digest, restorePlanDomain)
	writeDigestField(digest, plan.ReceiptID)
	writeDigestField(digest, plan.TargetRoot)
	encoded, err := json.Marshal(plan.receipt)
	if err == nil {
		writeDigestField(digest, string(encoded))
	}
	for _, present := range observation.stagePresent {
		writeDigestField(digest, strconv.FormatBool(present))
	}
	return hex.EncodeToString(digest.Sum(nil))
}
