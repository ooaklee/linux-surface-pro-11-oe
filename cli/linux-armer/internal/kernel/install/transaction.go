package install

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// stagingPrefix marks private temporary directories owned by this transaction.
	stagingPrefix = "linux-armer-kernel-install-"
	// backupPrefix marks host-private GRUB backup directories outside an alternate root.
	backupPrefix = "linux-armer-kernel-backup-"
	// rollbackTimeout bounds recovery after a cancelled or failed installation.
	rollbackTimeout = 2 * time.Minute
	// maximumReceiptErrorBytes bounds an external-tool diagnostic retained in JSON.
	maximumReceiptErrorBytes = 4096
)

// stagedPackages contains immutable private copies used across the privilege boundary.
type stagedPackages struct {
	// directory is the private transaction directory removed on return.
	directory string
	// paths follows the same dependency-friendly order as the plan packages.
	paths []string
	// commandPaths identifies the same files from the package manager's root.
	commandPaths []string
}

// grubBackup contains the pre-transaction GRUB bytes and metadata.
type grubBackup struct {
	// source is the original GRUB configuration path.
	source string
	// backup is the private verified copy used only for failure recovery.
	backup string
	// digest is the original configuration's complete SHA-256.
	digest string
	// size is the original configuration length.
	size int64
	// mode is the original configuration permission mode.
	mode os.FileMode
	// resolvedParent pins the GRUB parent-directory route across rollback.
	resolvedParent string
}

// stagePackages copies and rehashes all planned inputs into one private directory.
func (manager *Manager) stagePackages(ctx context.Context, root string, packages []Package) (stagedPackages, func(), error) {
	base := ""
	if root != string(filepath.Separator) {
		var err error
		base, err = rootPath(root, "var/tmp")
		if err != nil {
			return stagedPackages{}, func() {}, err
		}
		if err := validateTargetRoute(root, base, false); err != nil {
			return stagedPackages{}, func() {}, err
		}
		info, err := os.Lstat(base)
		if err != nil {
			return stagedPackages{}, func() {}, fmt.Errorf("inspect alternate-root var/tmp directory %s: %w", base, err)
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return stagedPackages{}, func() {}, fmt.Errorf("alternate target root requires a non-symlink var/tmp directory: %s", base)
		}
	}
	directory, err := os.MkdirTemp(base, stagingPrefix)
	if err != nil {
		return stagedPackages{}, func() {}, fmt.Errorf("create private kernel package staging directory: %w", err)
	}
	cleanup := func() {
		_ = os.RemoveAll(directory)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		cleanup()
		return stagedPackages{}, func() {}, fmt.Errorf("protect private kernel package staging directory: %w", err)
	}
	staged := stagedPackages{
		directory:    directory,
		paths:        make([]string, 0, len(packages)),
		commandPaths: make([]string, 0, len(packages)),
	}
	for _, item := range packages {
		if err := ctx.Err(); err != nil {
			cleanup()
			return stagedPackages{}, func() {}, err
		}
		info, err := packageSourceInfo(item)
		if err != nil {
			cleanup()
			return stagedPackages{}, func() {}, err
		}
		source, opened, err := openUnchangedRegular(item.Path, info)
		if err != nil {
			cleanup()
			return stagedPackages{}, func() {}, fmt.Errorf("pin package %s: %w", item.Name, err)
		}
		destinationPath := filepath.Join(directory, item.Name)
		destination, err := os.OpenFile(destinationPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			_ = source.Close()
			cleanup()
			return stagedPackages{}, func() {}, fmt.Errorf("create staged package %s: %w", item.Name, err)
		}
		digest, size, copyErr := digestReader(ctx, source, destination, maximumPackageBytes)
		syncErr := destination.Sync()
		destinationCloseErr := destination.Close()
		sourceCloseErr := source.Close()
		current, statErr := os.Lstat(item.Path)
		if copyErr != nil || syncErr != nil || destinationCloseErr != nil || sourceCloseErr != nil || statErr != nil {
			cleanup()
			return stagedPackages{}, func() {}, fmt.Errorf("stage package %s: %w", item.Name, errors.Join(copyErr, syncErr, destinationCloseErr, sourceCloseErr, statErr))
		}
		if current.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, current) || current.Size() != item.Size || size != item.Size || digest != item.SHA256 {
			cleanup()
			return stagedPackages{}, func() {}, fmt.Errorf("package %s changed after preflight", item.Name)
		}
		staged.paths = append(staged.paths, destinationPath)
		commandPath := destinationPath
		if root != string(filepath.Separator) {
			relative, err := filepath.Rel(root, destinationPath)
			if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
				cleanup()
				return stagedPackages{}, func() {}, fmt.Errorf("staged package escaped alternate root: %s", destinationPath)
			}
			commandPath = "/" + filepath.ToSlash(relative)
		}
		staged.commandPaths = append(staged.commandPaths, commandPath)
	}
	return staged, cleanup, nil
}

// revalidateStagedMetadata proves the package manager will read the same
// control identity that was reviewed before privilege escalation.
func (manager *Manager) revalidateStagedMetadata(ctx context.Context, planned []Package, staged stagedPackages) error {
	if len(planned) != len(staged.paths) {
		return errors.New("staged kernel package count changed")
	}
	for index, item := range planned {
		metadata, err := manager.inspectPackageMetadata(ctx, staged.paths[index])
		if err != nil {
			return fmt.Errorf("reinspect staged package %s: %w", item.Name, err)
		}
		if metadata.DebianPackage != item.DebianPackage || metadata.Version != item.Version ||
			metadata.Architecture != item.Architecture || metadata.Depends != item.Depends {
			return fmt.Errorf("staged package %s metadata changed after preflight", item.Name)
		}
	}
	return nil
}

// createGRUBBackup makes a private byte-exact backup before package scripts run.
func createGRUBBackup(ctx context.Context, root string) (grubBackup, func(), error) {
	directory, err := os.MkdirTemp("", backupPrefix)
	if err != nil {
		return grubBackup{}, func() {}, fmt.Errorf("create private GRUB backup directory: %w", err)
	}
	cleanup := func() {
		_ = os.RemoveAll(directory)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		cleanup()
		return grubBackup{}, func() {}, fmt.Errorf("protect private GRUB backup directory: %w", err)
	}
	target, err := rootPath(root, "boot/grub/grub.cfg")
	if err != nil {
		cleanup()
		return grubBackup{}, func() {}, err
	}
	if err := validateTargetRoute(root, target, false); err != nil {
		cleanup()
		return grubBackup{}, func() {}, err
	}
	info, err := os.Lstat(target)
	if err != nil {
		cleanup()
		return grubBackup{}, func() {}, fmt.Errorf("inspect GRUB configuration for backup: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() <= 0 {
		cleanup()
		return grubBackup{}, func() {}, fmt.Errorf("GRUB configuration is not a non-empty regular file: %s", target)
	}
	resolvedParent, err := filepath.EvalSymlinks(filepath.Dir(target))
	if err != nil {
		cleanup()
		return grubBackup{}, func() {}, fmt.Errorf("resolve GRUB configuration parent: %w", err)
	}
	source, opened, err := openUnchangedRegular(target, info)
	if err != nil {
		cleanup()
		return grubBackup{}, func() {}, fmt.Errorf("pin GRUB configuration for backup: %w", err)
	}
	backupPath := filepath.Join(directory, "grub.cfg.backup")
	destination, err := os.OpenFile(backupPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		_ = source.Close()
		cleanup()
		return grubBackup{}, func() {}, fmt.Errorf("create GRUB backup: %w", err)
	}
	digest, size, copyErr := digestReader(ctx, source, destination, maximumGRUBBytes)
	syncErr := destination.Sync()
	destinationCloseErr := destination.Close()
	sourceCloseErr := source.Close()
	current, statErr := os.Lstat(target)
	if copyErr != nil || syncErr != nil || destinationCloseErr != nil || sourceCloseErr != nil || statErr != nil {
		cleanup()
		return grubBackup{}, func() {}, fmt.Errorf("back up GRUB configuration: %w", errors.Join(copyErr, syncErr, destinationCloseErr, sourceCloseErr, statErr))
	}
	if current.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, current) || current.Size() != size {
		cleanup()
		return grubBackup{}, func() {}, errors.New("GRUB configuration changed while it was being backed up")
	}
	return grubBackup{
		source:         target,
		backup:         backupPath,
		digest:         digest,
		size:           size,
		mode:           info.Mode().Perm(),
		resolvedParent: filepath.Clean(resolvedParent),
	}, cleanup, nil
}

// restoreGRUB atomically republishes the byte-exact pre-transaction configuration.
func restoreGRUB(ctx context.Context, backup grubBackup) error {
	parent := filepath.Dir(backup.source)
	resolvedParent, err := filepath.EvalSymlinks(parent)
	if err != nil || filepath.Clean(resolvedParent) != backup.resolvedParent {
		return fmt.Errorf("refuse to restore GRUB through a changed or symbolic-link parent: %s", parent)
	}
	if info, err := os.Lstat(backup.source); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refuse to replace symbolic-link GRUB configuration: %s", backup.source)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect GRUB restore target: %w", err)
	}
	sourceInfo, err := os.Lstat(backup.backup)
	if err != nil {
		return fmt.Errorf("inspect GRUB backup: %w", err)
	}
	source, _, err := openUnchangedRegular(backup.backup, sourceInfo)
	if err != nil {
		return fmt.Errorf("open GRUB backup: %w", err)
	}
	temporary, err := os.CreateTemp(parent, ".linux-armer-grub-restore-")
	if err != nil {
		_ = source.Close()
		return fmt.Errorf("create atomic GRUB restore file: %w", err)
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		_ = temporary.Close()
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(backup.mode.Perm()); err != nil {
		_ = source.Close()
		return err
	}
	digest, size, copyErr := digestReader(ctx, source, temporary, maximumGRUBBytes)
	syncErr := temporary.Sync()
	temporaryCloseErr := temporary.Close()
	sourceCloseErr := source.Close()
	if copyErr != nil || syncErr != nil || temporaryCloseErr != nil || sourceCloseErr != nil {
		return fmt.Errorf("prepare GRUB restore: %w", errors.Join(copyErr, syncErr, temporaryCloseErr, sourceCloseErr))
	}
	if digest != backup.digest || size != backup.size {
		return errors.New("GRUB backup changed before restore")
	}
	if info, err := os.Lstat(backup.source); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refuse to replace symbolic-link GRUB configuration: %s", backup.source)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("reinspect GRUB restore target: %w", err)
	}
	if err := os.Rename(temporaryPath, backup.source); err != nil {
		return fmt.Errorf("publish restored GRUB configuration: %w", err)
	}
	removeTemporary = false
	if err := syncDirectory(parent); err != nil {
		return fmt.Errorf("sync restored GRUB directory: %w", err)
	}
	verified, err := requireRegularEvidence(ctx, "restored-grub", backup.source)
	if err != nil {
		return err
	}
	if verified.SHA256 != backup.digest || verified.Size != backup.size {
		return errors.New("restored GRUB configuration does not match its backup")
	}
	return nil
}

// syncDirectory makes an atomic rename durable before rollback reports success.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	return errors.Join(syncErr, closeErr)
}

// failAndRollback attempts bounded recovery without inheriting caller cancellation.
func (manager *Manager) failAndRollback(plan Plan, backup grubBackup, receipt Receipt, installErr error) (Receipt, error) {
	recovery := &RollbackReceipt{Attempted: true}
	receipt.Rollback = recovery
	rollbackContext, cancel := context.WithTimeout(context.Background(), rollbackTimeout)
	defer cancel()
	packageNames := make([]string, 0, len(plan.Packages))
	for _, item := range plan.Packages {
		packageNames = append(packageNames, item.DebianPackage)
	}
	commands, commandErr := rollbackCommands(plan.Root, packageNames)
	var rollbackErr error
	if commandErr != nil {
		rollbackErr = commandErr
	} else {
		for _, command := range commands {
			recovery.Commands = append(recovery.Commands, cloneCommand(command))
			if err := manager.runner.Run(rollbackContext, platform.Command{Name: command.Name, Args: append([]string(nil), command.Args...)}); err != nil {
				rollbackErr = errors.Join(rollbackErr, fmt.Errorf("%s: %w", command.Operation, err))
			}
		}
	}
	if err := restoreGRUB(rollbackContext, backup); err != nil {
		rollbackErr = errors.Join(rollbackErr, err)
	} else {
		recovery.GRUBRestored = true
	}
	recoveredFallback, verificationErr := verifyFallback(rollbackContext, plan.Root, plan.FallbackABI)
	if verificationErr == nil {
		verificationErr = fallbackUnchanged(plan.Fallback, recoveredFallback)
	}
	if verificationErr != nil {
		rollbackErr = errors.Join(rollbackErr, fmt.Errorf("verify fallback after rollback: %w", verificationErr))
	}
	if err := verifyTargetAbsent(rollbackContext, plan.Root, plan.TargetABI); err != nil {
		rollbackErr = errors.Join(rollbackErr, fmt.Errorf("verify target removal after rollback: %w", err))
	}
	if rollbackErr != nil {
		recovery.Error = boundedError(rollbackErr)
		return receipt, errors.Join(installErr, fmt.Errorf("kernel rollback incomplete: %w", rollbackErr))
	}
	return receipt, installErr
}

// boundedError removes control characters and truncates diagnostics retained in receipts.
func boundedError(err error) string {
	if err == nil {
		return ""
	}
	text := strings.Map(func(character rune) rune {
		if character < 0x20 && character != '\n' && character != '\t' {
			return -1
		}
		if character == 0x7f {
			return -1
		}
		return character
	}, err.Error())
	if len(text) > maximumReceiptErrorBytes {
		text = text[:maximumReceiptErrorBytes]
		for len(text) > 0 && !utf8.ValidString(text) {
			text = text[:len(text)-1]
		}
	}
	return text
}
