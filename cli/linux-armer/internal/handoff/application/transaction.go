package application

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff"
)

const (
	// maximumBackupBytes rejects unexpectedly large pre-existing target files.
	maximumBackupBytes int64 = 1 << 30
	// rollbackTimeout bounds recovery without inheriting caller cancellation.
	rollbackTimeout = 2 * time.Minute
)

// transactionHooks supplies deterministic package-test failures.
type transactionHooks struct {
	// afterApplied runs after one action and its journal update are durable.
	afterApplied func(identifier string) error
}

// Apply re-plans immediately before a confirmed transaction, requires effective
// root only when changes remain, and rolls back every completed operation on error.
func (manager *Manager) Apply(ctx context.Context, reviewed Plan, exactConfirmation string) (result Result, resultErr error) {
	if manager == nil {
		return Result{}, errors.New("hand-off application manager is not initialised")
	}
	if ctx == nil {
		return Result{}, errors.New("apply private hand-off: context is nil")
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	if reviewed.Confirmation == "" || exactConfirmation != reviewed.Confirmation {
		return Result{}, errors.New("hand-off application requires the exact ID-, plan-, and target-root-bound confirmation")
	}
	current, err := manager.Plan(ctx, Request{
		StoreRoot: reviewed.storeRoot, ID: reviewed.ID,
		IdentityRoot: reviewed.IdentityRoot, TargetRoot: reviewed.TargetRoot,
		Features: cloneFeatures(reviewed.Features), ADSPPolicy: reviewed.ADSPPolicy,
	})
	if err != nil {
		return Result{}, err
	}
	if !samePlan(reviewed, current) {
		return Result{}, errors.New("hand-off application plan no longer matches private material, identity, binary, or target state")
	}
	result = Result{
		ID: current.ID, PlanSHA256: current.PlanSHA256, TargetRoot: current.TargetRoot,
		Features: cloneFeatures(current.Features),
	}
	if current.RequiredChanges == 0 {
		result.Applied = true
		result.AlreadyApplied = true
		return result, nil
	}
	if containsFeature(current.Features, FeatureBluetooth) && !current.HostBinaryCompatible {
		return Result{}, errors.New("Bluetooth application requires the current linux-armer executable to be a Linux ARM64 ELF binary")
	}
	if manager.effectiveUID == nil || manager.effectiveUID() != 0 {
		return Result{}, errors.New("hand-off application mutation requires effective root")
	}
	result.ReceiptID = current.PlanSHA256
	target, err := os.OpenRoot(current.TargetRoot)
	if err != nil {
		return Result{}, fmt.Errorf("open target root for application: %w", err)
	}
	defer target.Close()
	if err := ensureReceiptDirectory(target); err != nil {
		return Result{}, err
	}
	if err := ensureNoOverlappingActiveReceipt(ctx, target, current); err != nil {
		return Result{}, err
	}
	if existing, readErr := readReceipt(ctx, target, current.PlanSHA256); readErr == nil {
		if existing.State != receiptRolledBack {
			return Result{}, errors.New("a private receipt already records this transaction; restore or inspect it before retrying")
		}
	} else if !errors.Is(readErr, fs.ErrNotExist) {
		return Result{}, readErr
	}
	receipt, err := manager.prepareReceipt(ctx, target, current)
	if err != nil {
		return Result{}, err
	}
	if err := writeReceipt(target, receipt); err != nil {
		return Result{}, err
	}
	receipt.State = receiptApplying
	if err := writeReceipt(target, receipt); err != nil {
		return Result{}, err
	}
	rollbackNeeded := true
	defer func() {
		if resultErr == nil || !rollbackNeeded {
			return
		}
		rollbackContext, cancel := context.WithTimeout(context.Background(), rollbackTimeout)
		defer cancel()
		if rollbackErr := rollbackTransaction(rollbackContext, target, &receipt); rollbackErr != nil {
			resultErr = errors.Join(resultErr, fmt.Errorf("hand-off application rollback incomplete: %w", rollbackErr))
		}
	}()
	for index := range current.desired {
		if !current.desired[index].change.Required {
			continue
		}
		if err := ctx.Err(); err != nil {
			return Result{}, err
		}
		if err := manager.applyAction(ctx, target, current, current.desired[index], &receipt, index); err != nil {
			return Result{}, err
		}
		result.Changed++
		if manager.hooks.afterApplied != nil {
			if err := manager.hooks.afterApplied(current.desired[index].change.ID); err != nil {
				return Result{}, err
			}
		}
	}
	revalidated, err := handoff.RevalidateForApplication(ctx, current.storeRoot, current.ID)
	if err != nil || revalidated.ClosedSetSHA256() != current.material.ClosedSetSHA256() {
		return Result{}, errors.New("private Windows hand-off changed during application")
	}
	for _, action := range current.desired {
		matches, inspectErr := targetMatches(ctx, target, action)
		if inspectErr != nil || !matches {
			return Result{}, fmt.Errorf("post-transaction verification failed for %s", action.change.ID)
		}
	}
	receipt.State = receiptCommitted
	if err := writeReceipt(target, receipt); err != nil {
		return Result{}, err
	}
	rollbackNeeded = false
	result.Applied = true
	return result, nil
}

// ensureNoOverlappingActiveReceipt prevents receipt chains whose rollback order
// could become ambiguous while still allowing disjoint feature transactions.
func ensureNoOverlappingActiveReceipt(ctx context.Context, root *os.Root, plan Plan) error {
	directory, err := root.Open(ReceiptDirectory)
	if err != nil {
		return fmt.Errorf("open private hand-off receipt directory: %w", err)
	}
	names, readErr := directory.Readdirnames(-1)
	closeErr := directory.Close()
	if readErr != nil || closeErr != nil {
		return fmt.Errorf("read private hand-off receipt directory: %w", errors.Join(readErr, closeErr))
	}
	sort.Strings(names)
	desiredPaths := make(map[string]bool, len(plan.desired))
	for _, action := range plan.desired {
		desiredPaths[action.change.Path] = true
	}
	for _, name := range names {
		if isReceiptTemporaryName(name) {
			info, err := root.Lstat(path.Join(ReceiptDirectory, name))
			if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > maximumReceiptBytes {
				return errors.New("private hand-off receipt directory contains an invalid staging entry")
			}
			continue
		}
		if !strings.HasSuffix(name, ".json") {
			return errors.New("private hand-off receipt directory contains an unrecognised entry")
		}
		receiptID := strings.TrimSuffix(name, ".json")
		if !validLowerHexDigest(receiptID) {
			return errors.New("private hand-off receipt directory contains an invalid entry")
		}
		receipt, err := readReceipt(ctx, root, receiptID)
		if err != nil {
			return err
		}
		if receipt.State == receiptRolledBack {
			continue
		}
		for _, action := range receipt.Actions {
			if desiredPaths[action.Path] {
				return errors.New("an overlapping private hand-off receipt must be restored before applying another transaction")
			}
		}
	}
	return nil
}

// isReceiptTemporaryName recognises only the fixed random journal-staging name
// shape so a power-loss remnant cannot permanently block later application.
func isReceiptTemporaryName(name string) bool {
	const prefix = ".receipt-"
	const suffix = ".tmp"
	if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, suffix) {
		return false
	}
	randomHex := strings.TrimSuffix(strings.TrimPrefix(name, prefix), suffix)
	if len(randomHex) != 16 || strings.ToLower(randomHex) != randomHex {
		return false
	}
	decoded, err := hex.DecodeString(randomHex)
	return err == nil && len(decoded) == 8
}

// samePlan compares every public checkpoint and its private plan digest.
func samePlan(left, right Plan) bool {
	return left.ID == right.ID && left.IdentityRoot == right.IdentityRoot && left.TargetRoot == right.TargetRoot &&
		left.PlanSHA256 == right.PlanSHA256 && left.Confirmation == right.Confirmation &&
		left.RequiredChanges == right.RequiredChanges && left.HostBinaryCompatible == right.HostBinaryCompatible &&
		stringSlicesEqual(left.Features, right.Features) && changesEqual(left.Changes, right.Changes)
}

// stringSlicesEqual compares canonical feature slices without reflection.
func stringSlicesEqual(left, right []Feature) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

// changesEqual compares every redacted target decision in stable order.
func changesEqual(left, right []Change) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

// prepareReceipt snapshots every safe original and pre-allocates same-parent
// staging and backup names before the first payload path is changed.
func (manager *Manager) prepareReceipt(ctx context.Context, root *os.Root, plan Plan) (privateReceipt, error) {
	createdDirectories, err := missingParentDirectories(root, plan.desired)
	if err != nil {
		return privateReceipt{}, err
	}
	receipt := privateReceipt{
		SchemaVersion: receiptSchemaVersion, Kind: receiptKind,
		ReceiptID: plan.PlanSHA256, HandoffID: plan.ID, PlanSHA256: plan.PlanSHA256,
		TargetRoot: plan.TargetRoot, State: receiptPrepared,
		CreatedDirectories: createdDirectories,
	}
	receipt.Actions = make([]receiptAction, len(plan.desired))
	for index, action := range plan.desired {
		entry := receiptAction{
			ID: action.change.ID, Path: action.change.Path, DesiredKind: action.change.Kind,
			DesiredMode: uint32(action.mode.Perm()), DesiredSHA256: action.sha256,
			DesiredSize: action.size, DesiredLinkTarget: action.linkTarget,
			Required: action.change.Required,
		}
		if err := snapshotOriginal(ctx, root, &entry); err != nil {
			return privateReceipt{}, err
		}
		if !action.change.Required {
			receipt.Actions[index] = entry
			continue
		}
		entry.StagePath, entry.BackupPath = transactionSiblingPaths(action.change.Path, plan.PlanSHA256, index)
		if action.change.Kind == ChangeAbsent {
			entry.StagePath = ""
		}
		if entry.OriginalKind == originalAbsent {
			entry.BackupPath = ""
		}
		if _, err := root.Lstat(entry.StagePath); entry.StagePath != "" && !errors.Is(err, fs.ErrNotExist) {
			if err == nil {
				return privateReceipt{}, fmt.Errorf("transaction staging path already exists for %s", action.change.ID)
			}
			return privateReceipt{}, fmt.Errorf("inspect transaction staging path for %s: %w", action.change.ID, err)
		}
		if _, err := root.Lstat(entry.BackupPath); entry.BackupPath != "" && !errors.Is(err, fs.ErrNotExist) {
			if err == nil {
				return privateReceipt{}, fmt.Errorf("transaction backup path already exists for %s", action.change.ID)
			}
			return privateReceipt{}, fmt.Errorf("inspect transaction backup path for %s: %w", action.change.ID, err)
		}
		receipt.Actions[index] = entry
	}
	return receipt, nil
}

// transactionSiblingPaths returns deterministic hidden names in the same parent.
func transactionSiblingPaths(targetPath, planSHA256 string, index int) (string, string) {
	parent := path.Dir(targetPath)
	base := path.Base(targetPath)
	prefix := fmt.Sprintf(".%s.linux-armer-%s-%02d", base, planSHA256[:16], index)
	return path.Join(parent, prefix+".new"), path.Join(parent, prefix+".backup")
}

// snapshotOriginal records only absent, bounded regular-file, or symbolic-link targets.
func snapshotOriginal(ctx context.Context, root *os.Root, entry *receiptAction) error {
	info, err := root.Lstat(entry.Path)
	if errors.Is(err, fs.ErrNotExist) {
		entry.OriginalKind = originalAbsent
		entry.BackupPath = ""
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect original target %s: %w", entry.ID, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := root.Readlink(entry.Path)
		if err != nil || len(target) > 4096 {
			return fmt.Errorf("inspect original target link %s", entry.ID)
		}
		entry.OriginalKind = originalSymlink
		entry.OriginalLinkTarget = target
		return nil
	}
	if !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > maximumBackupBytes {
		return fmt.Errorf("original target %s is not a bounded regular file or symbolic link", entry.ID)
	}
	digest, size, err := digestRootFile(ctx, root, entry.Path, maximumBackupBytes)
	if err != nil || size != info.Size() {
		return fmt.Errorf("snapshot original target %s", entry.ID)
	}
	entry.OriginalKind = originalFile
	entry.OriginalMode = uint32(info.Mode().Perm())
	entry.OriginalSHA256 = digest
	entry.OriginalSize = size
	return nil
}

// missingParentDirectories returns canonical absent parents shallowest-first.
func missingParentDirectories(root *os.Root, actions []desiredAction) ([]string, error) {
	missing := make(map[string]bool)
	for _, action := range actions {
		parent := path.Dir(action.change.Path)
		components := strings.Split(parent, "/")
		current := ""
		for _, component := range components {
			if component == "." || component == "" {
				continue
			}
			current = path.Join(current, component)
			info, err := root.Stat(current)
			if errors.Is(err, fs.ErrNotExist) {
				missing[current] = true
				continue
			}
			if err != nil || !info.IsDir() {
				return nil, fmt.Errorf("compiled target parent is not a safe directory: %s", current)
			}
		}
	}
	directories := make([]string, 0, len(missing))
	for directory := range missing {
		directories = append(directories, directory)
	}
	sort.Slice(directories, func(left, right int) bool {
		leftDepth := strings.Count(directories[left], "/")
		rightDepth := strings.Count(directories[right], "/")
		if leftDepth != rightDepth {
			return leftDepth < rightDepth
		}
		return directories[left] < directories[right]
	})
	return directories, nil
}

// applyAction stages, isolates, publishes, verifies, and journals one operation.
func (manager *Manager) applyAction(ctx context.Context, root *os.Root, plan Plan, action desiredAction, receipt *privateReceipt, index int) error {
	entry := &receipt.Actions[index]
	if err := verifyObservedTarget(ctx, root, action); err != nil {
		return err
	}
	parent := path.Dir(action.change.Path)
	if err := root.MkdirAll(parent, 0o755); err != nil {
		return fmt.Errorf("create compiled target parent for %s: %w", action.change.ID, err)
	}
	if err := manager.stageDesired(ctx, root, plan, action, entry.StagePath); err != nil {
		return err
	}
	if err := verifyObservedTarget(ctx, root, action); err != nil {
		return err
	}
	if entry.OriginalKind != originalAbsent {
		if err := root.Rename(entry.Path, entry.BackupPath); err != nil {
			return fmt.Errorf("quarantine original target %s: %w", action.change.ID, err)
		}
		if err := syncRootDirectory(root, parent); err != nil {
			return err
		}
		entry.BackupCreated = true
		if err := writeReceipt(root, *receipt); err != nil {
			return err
		}
	}
	if _, err := root.Lstat(entry.Path); !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("compiled target %s was recreated during transaction", action.change.ID)
	}
	if action.change.Kind != ChangeAbsent {
		if err := root.Rename(entry.StagePath, entry.Path); err != nil {
			return fmt.Errorf("publish compiled target %s: %w", action.change.ID, err)
		}
	}
	if err := syncRootDirectory(root, parent); err != nil {
		return err
	}
	entry.Applied = true
	if err := writeReceipt(root, *receipt); err != nil {
		return err
	}
	matches, err := targetMatches(ctx, root, action)
	if err != nil || !matches {
		return fmt.Errorf("verify applied target %s", action.change.ID)
	}
	return nil
}

// verifyObservedTarget rejects a replacement after the reviewed plan and
// before the transaction isolates the current target object.
func verifyObservedTarget(ctx context.Context, root *os.Root, action desiredAction) error {
	_, observation, err := inspectTarget(ctx, root, action)
	if err != nil {
		return err
	}
	if observation != action.observedSHA256 {
		return fmt.Errorf("compiled target changed after planning for %s", action.change.ID)
	}
	return nil
}

// stageDesired writes and flushes one unpublished desired file or link.
func (manager *Manager) stageDesired(ctx context.Context, root *os.Root, plan Plan, action desiredAction, stagingPath string) error {
	if action.change.Kind == ChangeAbsent {
		return nil
	}
	if action.change.Kind == ChangeSymlink {
		if err := root.Symlink(action.linkTarget, stagingPath); err != nil {
			return fmt.Errorf("stage compiled target link %s: %w", action.change.ID, err)
		}
		return syncRootDirectory(root, path.Dir(stagingPath))
	}
	destination, err := root.OpenFile(stagingPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, action.mode.Perm())
	if err != nil {
		return fmt.Errorf("stage compiled target file %s: %w", action.change.ID, err)
	}
	if err := destination.Chmod(action.mode.Perm()); err != nil {
		_ = destination.Close()
		_ = root.Remove(stagingPath)
		return fmt.Errorf("set compiled target mode for %s: %w", action.change.ID, err)
	}
	source, closeSource, err := manager.openDesiredSource(ctx, plan, action)
	if err != nil {
		_ = destination.Close()
		_ = root.Remove(stagingPath)
		return err
	}
	digest := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(destination, digest), io.LimitReader(contextReader{context: ctx, reader: source}, action.size+1))
	sourceCloseErr := closeSource()
	syncErr := destination.Sync()
	closeErr := destination.Close()
	if copyErr != nil || sourceCloseErr != nil || syncErr != nil || closeErr != nil {
		_ = root.Remove(stagingPath)
		return fmt.Errorf("stage compiled target bytes for %s: %w", action.change.ID, errors.Join(copyErr, sourceCloseErr, syncErr, closeErr))
	}
	if written != action.size || hex.EncodeToString(digest.Sum(nil)) != action.sha256 {
		_ = root.Remove(stagingPath)
		return fmt.Errorf("compiled source bytes changed for %s", action.change.ID)
	}
	return syncRootDirectory(root, path.Dir(stagingPath))
}

// openDesiredSource returns one private, binary, or fixed source and a closer.
func (manager *Manager) openDesiredSource(ctx context.Context, plan Plan, action desiredAction) (io.Reader, func() error, error) {
	switch action.source {
	case sourceStatic:
		return bytes.NewReader(action.data), func() error { return nil }, nil
	case sourceFirmware:
		file, record, err := plan.material.OpenFirmware(ctx, action.sourceID)
		if err != nil {
			return nil, func() error { return nil }, err
		}
		if record.SHA256 != action.sha256 || record.Size != action.size {
			_ = file.Close()
			return nil, func() error { return nil }, fmt.Errorf("private firmware plan changed for %s", action.change.ID)
		}
		return file, file.Close, nil
	case sourceBinary:
		info, err := os.Lstat(plan.binary.path)
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() != plan.binary.size {
			return nil, func() error { return nil }, errors.New("current linux-armer executable changed after planning")
		}
		file, err := os.Open(plan.binary.path)
		if err != nil {
			return nil, func() error { return nil }, errors.New("open current linux-armer executable for application")
		}
		opened, err := file.Stat()
		if err != nil || !os.SameFile(info, opened) {
			_ = file.Close()
			return nil, func() error { return nil }, errors.New("current linux-armer executable changed while opening")
		}
		return file, file.Close, nil
	default:
		return nil, func() error { return nil }, errors.New("compiled application source is unsupported")
	}
}

// rollbackTransaction restores backups or absence in reverse application order.
func rollbackTransaction(ctx context.Context, root *os.Root, receipt *privateReceipt) error {
	receipt.State = receiptRollingBack
	var rollbackErr error
	if err := writeReceipt(root, *receipt); err != nil {
		rollbackErr = errors.Join(rollbackErr, err)
	}
	for index := len(receipt.Actions) - 1; index >= 0; index-- {
		entry := &receipt.Actions[index]
		if !entry.Applied && !entry.BackupCreated {
			if err := removeReceiptStage(ctx, root, *entry); err != nil {
				rollbackErr = errors.Join(rollbackErr, fmt.Errorf("remove staging object for %s: %w", entry.ID, err))
			}
			continue
		}
		if err := restoreReceiptAction(ctx, root, entry); err != nil {
			rollbackErr = errors.Join(rollbackErr, fmt.Errorf("restore %s: %w", entry.ID, err))
			continue
		}
		entry.Applied = false
		entry.BackupCreated = false
		if err := writeReceipt(root, *receipt); err != nil {
			rollbackErr = errors.Join(rollbackErr, err)
		}
	}
	if err := removeEmptyCreatedDirectories(root, receipt.CreatedDirectories); err != nil {
		rollbackErr = errors.Join(rollbackErr, err)
	}
	if rollbackErr != nil {
		return rollbackErr
	}
	receipt.State = receiptRolledBack
	return writeReceipt(root, *receipt)
}

// removeEmptyCreatedDirectories removes only still-empty transaction-created
// parents in deepest-first order and preserves any concurrently added content.
func removeEmptyCreatedDirectories(root *os.Root, directories []string) error {
	var removeErr error
	for index := len(directories) - 1; index >= 0; index-- {
		directory, err := root.Open(directories[index])
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			removeErr = errors.Join(removeErr, fmt.Errorf("inspect transaction-created directory: %w", err))
			continue
		}
		_, readErr := directory.Readdirnames(1)
		closeErr := directory.Close()
		if readErr == nil {
			if closeErr != nil {
				removeErr = errors.Join(removeErr, fmt.Errorf("close transaction-created directory: %w", closeErr))
			}
			continue
		}
		if !errors.Is(readErr, io.EOF) || closeErr != nil {
			removeErr = errors.Join(removeErr, fmt.Errorf("inspect transaction-created directory: %w", errors.Join(readErr, closeErr)))
			continue
		}
		if err := root.Remove(directories[index]); err != nil && !errors.Is(err, fs.ErrNotExist) {
			removeErr = errors.Join(removeErr, fmt.Errorf("remove empty transaction-created directory: %w", err))
		}
	}
	return removeErr
}

// restoreReceiptAction removes only the exact desired object and republishes a
// verified same-filesystem original backup when one existed.
func restoreReceiptAction(ctx context.Context, root *os.Root, entry *receiptAction) error {
	parent := path.Dir(entry.Path)
	if entry.Applied {
		matches, err := receiptDesiredMatches(ctx, root, *entry)
		if err != nil || !matches {
			return errors.New("current target no longer matches the transaction receipt")
		}
		if entry.DesiredKind != ChangeAbsent {
			if err := root.Remove(entry.Path); err != nil {
				return err
			}
		}
	}
	if entry.OriginalKind != originalAbsent {
		matches, err := receiptBackupMatches(ctx, root, *entry)
		if err != nil || !matches {
			return errors.New("original same-filesystem backup no longer matches its receipt")
		}
		if _, err := root.Lstat(entry.Path); !errors.Is(err, fs.ErrNotExist) {
			return errors.New("restore target is unexpectedly occupied")
		}
		if err := root.Rename(entry.BackupPath, entry.Path); err != nil {
			return err
		}
	}
	if err := removeReceiptStage(ctx, root, *entry); err != nil {
		return err
	}
	return syncRootDirectory(root, parent)
}

// removeReceiptStage removes only an exact desired staging object recorded by
// the private receipt and refuses a replacement of a different type or content.
func removeReceiptStage(ctx context.Context, root *os.Root, entry receiptAction) error {
	if entry.StagePath == "" {
		return nil
	}
	matches, err := receiptStageMatches(ctx, root, entry)
	if err != nil {
		return err
	}
	if !matches {
		if _, err := root.Lstat(entry.StagePath); errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return errors.New("transaction staging object no longer matches its private receipt")
	}
	return root.Remove(entry.StagePath)
}

// receiptDesiredMatches checks a current desired object from private journal data.
func receiptDesiredMatches(ctx context.Context, root *os.Root, entry receiptAction) (bool, error) {
	action := desiredAction{
		change: Change{ID: entry.ID, Path: entry.Path, Kind: entry.DesiredKind},
		mode:   fs.FileMode(entry.DesiredMode), sha256: entry.DesiredSHA256,
		size: entry.DesiredSize, linkTarget: entry.DesiredLinkTarget,
	}
	return targetMatches(ctx, root, action)
}

// receiptBackupMatches checks one quarantined original without following links.
func receiptBackupMatches(ctx context.Context, root *os.Root, entry receiptAction) (bool, error) {
	info, err := root.Lstat(entry.BackupPath)
	if err != nil {
		return false, err
	}
	if entry.OriginalKind == originalSymlink {
		if info.Mode()&os.ModeSymlink == 0 {
			return false, nil
		}
		target, err := root.Readlink(entry.BackupPath)
		return err == nil && target == entry.OriginalLinkTarget, err
	}
	if entry.OriginalKind != originalFile || !info.Mode().IsRegular() || info.Mode().Perm() != fs.FileMode(entry.OriginalMode).Perm() || info.Size() != entry.OriginalSize {
		return false, nil
	}
	digest, size, err := digestRootFile(ctx, root, entry.BackupPath, maximumBackupBytes)
	return err == nil && size == entry.OriginalSize && digest == entry.OriginalSHA256, err
}

// digestRootFile hashes one descriptor-confined regular file within a bound.
func digestRootFile(ctx context.Context, root *os.Root, relativePath string, maximum int64) (string, int64, error) {
	file, err := root.Open(relativePath)
	if err != nil {
		return "", 0, err
	}
	digest := sha256.New()
	written, copyErr := io.Copy(digest, io.LimitReader(contextReader{context: ctx, reader: file}, maximum+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil || written > maximum {
		return "", 0, errors.Join(copyErr, closeErr)
	}
	return hex.EncodeToString(digest.Sum(nil)), written, nil
}
