package install

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
	userspaceiptsd "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/iptsd"
)

const (
	// iptsdArchiveName is the sole source-bearing payload accepted for pen input.
	iptsdArchiveName = "sp11-iptsd-3.1.0-sp11.1-arm64.tar.xz"
	// iptsdMaskRelative is the sole intentional installed symbolic link.
	iptsdMaskRelative = "etc/systemd/system/iptsd@.service"
	// iptsdReceiptName is the private durable transaction record.
	iptsdReceiptName = "receipt.json"
	// maximumActivationOutput bounds retained output from each service command.
	maximumActivationOutput = 16 << 10
	// iptsdReceiptSchemaVersion identifies the native receipt shape.
	iptsdReceiptSchemaVersion = 1
)

// iptsdActivationCommands is the complete fixed live-root operation sequence.
var iptsdActivationCommands = []Command{
	{Name: "/usr/bin/systemctl", Args: []string{"disable", "--now", "g6-pen.service"}},
	{Name: "/usr/bin/systemctl", Args: []string{"stop", "iptsd@*.service"}},
	{Name: "/usr/bin/systemctl", Args: []string{"daemon-reload"}},
	{Name: "/usr/bin/udevadm", Args: []string{"control", "--reload-rules"}},
	{Name: "/usr/bin/udevadm", Args: []string{"trigger", "--subsystem-match=hidraw", "--action=change"}},
	{Name: "/usr/bin/udevadm", Args: []string{"settle", "--timeout=5"}},
}

// iptsdChangePlan retains verified source and original-target identities for
// publication and complete reverse-order rollback.
type iptsdChangePlan struct {
	change         FileChange
	source         string
	sourceDigest   string
	sourceSize     int64
	mode           os.FileMode
	originalMode   os.FileMode
	originalSize   int64
	originalDigest string
}

// iptsdMaskPlan records whether the exact generic /dev/null mask pre-existed.
type iptsdMaskPlan struct {
	path    string
	existed bool
}

// iptsdReceipt is the private durable account of one native transaction.
type iptsdReceipt struct {
	// SchemaVersion permits strict future receipt evolution.
	SchemaVersion int `json:"schema_version"`
	// Component identifies the exact installed contract.
	Component string `json:"component"`
	// InstalledAt records the UTC transaction instant.
	InstalledAt string `json:"installed_at"`
	// Root records the resolved target filesystem root.
	Root string `json:"root"`
	// Files records all fixed regular targets and the generic mask.
	Files []FileChange `json:"files"`
	// Commands records the exact live-root activation sequence.
	Commands []Command `json:"commands,omitempty"`
	// FilesInstalled reports that publication and directory synchronisation ended.
	FilesInstalled bool `json:"files_installed"`
	// ActivationRequired distinguishes live and alternate-root transactions.
	ActivationRequired bool `json:"activation_required"`
	// ActivationComplete reports successful completion of required operations.
	ActivationComplete bool `json:"activation_complete"`
	// ActivationError retains a bounded failure diagnostic when activation fails.
	ActivationError string `json:"activation_error,omitempty"`
}

// boundedActivationOutput retains a fixed prefix while acknowledging every
// write so noisy system tools cannot exhaust process memory or block.
type boundedActivationOutput struct {
	buffer bytes.Buffer
}

// Write implements io.Writer with a fixed retained-output ceiling.
func (output *boundedActivationOutput) Write(data []byte) (int, error) {
	remaining := maximumActivationOutput - output.buffer.Len()
	if remaining > 0 {
		_, _ = output.buffer.Write(data[:min(remaining, len(data))])
	}
	return len(data), nil
}

// String returns the trimmed retained command output.
func (output *boundedActivationOutput) String() string {
	return strings.TrimSpace(output.buffer.String())
}

// IPTSD verifies and extracts the pinned source-bearing release, validates its
// closed native contract, and applies one recoverable filesystem transaction.
func (installer *Installer) IPTSD(ctx context.Context, options Options) (Result, error) {
	options, err := normalizeOptions(options)
	if err != nil {
		return Result{}, err
	}
	bundle, err := verifyBundle(options.BundleDir, iptsdSpec)
	if err != nil {
		return Result{}, err
	}
	archive := bundle.paths[iptsdArchiveName]
	stage, err := createPrivateInstallStaging("linux-armer-iptsd-install-*")
	if err != nil {
		return Result{}, fmt.Errorf("create private IPTSD staging directory: %w", err)
	}
	defer os.RemoveAll(stage)
	stagedArchive := filepath.Join(stage, iptsdArchiveName)
	immutable := immutableByName(iptsdSpec, iptsdArchiveName)
	if err := atomicCopyVerified(archive, stagedArchive, 0o600, immutable.sha256, immutable.size); err != nil {
		return Result{}, fmt.Errorf("stage verified IPTSD archive: %w", err)
	}
	extractionRoot := filepath.Join(stage, "extracted")
	if err := os.Mkdir(extractionRoot, 0o700); err != nil {
		return Result{}, fmt.Errorf("create IPTSD extraction root: %w", err)
	}
	if err := installer.extractor.Extract(ctx, stagedArchive, extractionRoot); err != nil {
		return Result{}, fmt.Errorf("extract IPTSD release archive: %w", err)
	}
	if installer.validateIPTSDRelease == nil || installer.isLiveRoot == nil {
		return Result{}, errors.New("native IPTSD validation policy is unavailable")
	}
	release, err := installer.validateIPTSDRelease(filepath.Join(extractionRoot, userspaceiptsd.ArchiveRoot))
	if err != nil {
		return Result{}, fmt.Errorf("validate native IPTSD release: %w", err)
	}
	if err := materialiseIPTSDRendered(stage, &release); err != nil {
		return Result{}, err
	}
	stamp := installer.now().UTC().Format("20060102T150405.000000000Z")
	backupRelative := filepath.ToSlash(filepath.Join("var/lib/linux-armer/backups/userspace", stamp, IPTSDComponent))
	plans, mask, result, err := planIPTSDTransaction(options, release, backupRelative, installer.isLiveRoot(options.Root))
	if err != nil {
		return Result{}, err
	}
	if options.DryRun {
		return result, nil
	}
	if err := installer.requireRoot(false); err != nil {
		return Result{}, err
	}
	if err := installer.prepareIPTSDBackups(options.Root, backupRelative, result.BackupDirectory, plans); err != nil {
		return result, err
	}
	applied := make([]iptsdChangePlan, 0, len(plans))
	maskCreated := false
	for index, plan := range plans {
		if installer.beforeIPTSDPublish != nil {
			if err := installer.beforeIPTSDPublish(index, plan.change.Target); err != nil {
				return result, errors.Join(err, rollbackIPTSD(applied, mask, maskCreated))
			}
		}
		if err := revalidateIPTSDTarget(options.Root, plan); err != nil {
			return result, errors.Join(err, rollbackIPTSD(applied, mask, maskCreated))
		}
		if err := atomicCopyVerified(plan.source, plan.change.Target, plan.mode, plan.sourceDigest, plan.sourceSize); err != nil {
			if digest, info, hashErr := hashRegularNoFollow(plan.change.Target); hashErr == nil && digest == plan.sourceDigest {
				changed := !plan.change.Replaced || plan.originalDigest != plan.sourceDigest ||
					plan.originalMode.Perm() != plan.mode.Perm() && info.Mode().Perm() == plan.mode.Perm()
				if changed {
					applied = append(applied, plan)
				}
			}
			return result, errors.Join(err, rollbackIPTSD(applied, mask, maskCreated))
		}
		applied = append(applied, plan)
	}
	if installer.beforeIPTSDPublish != nil {
		if err := installer.beforeIPTSDPublish(len(plans), mask.path); err != nil {
			return result, errors.Join(err, rollbackIPTSD(applied, mask, maskCreated))
		}
	}
	if err := revalidateIPTSDMask(options.Root, mask); err != nil {
		return result, errors.Join(err, rollbackIPTSD(applied, mask, maskCreated))
	}
	if !mask.existed {
		if err := os.Symlink("/dev/null", mask.path); err != nil {
			return result, errors.Join(fmt.Errorf("create generic IPTSD mask: %w", err), rollbackIPTSD(applied, mask, maskCreated))
		}
		maskCreated = true
		if err := syncDirectory(filepath.Dir(mask.path)); err != nil {
			return result, errors.Join(err, rollbackIPTSD(applied, mask, maskCreated))
		}
	}
	result.FilesInstalled = true
	if !result.ActivationRequired {
		result.ActivationComplete = true
	}
	if err := writeIPTSDReceipt(result, installer.now()); err != nil {
		result.FilesInstalled = false
		return result, errors.Join(err, removeFailedIPTSDReceipt(result.Receipt), rollbackIPTSD(applied, mask, maskCreated))
	}
	if result.ActivationRequired {
		activationErr := installer.activateIPTSD(ctx, result.Commands)
		if activationErr != nil {
			result.ActivationError = activationErr.Error()
		} else {
			result.ActivationComplete = true
		}
		if receiptErr := writeIPTSDReceipt(result, installer.now()); receiptErr != nil {
			activationErr = errors.Join(activationErr, receiptErr)
		}
		if activationErr != nil {
			return result, fmt.Errorf("IPTSD files are installed but live activation is incomplete: %w", activationErr)
		}
	}
	return result, nil
}

// immutableByName returns one compiled artefact record from a release policy.
func immutableByName(spec releaseSpec, name string) immutableFile {
	for _, immutable := range spec.files {
		if immutable.name == name {
			return immutable
		}
	}
	return immutableFile{}
}

// materialiseIPTSDRendered writes validated in-memory template outputs into the
// private stage so every publication uses the same verified-copy primitive.
func materialiseIPTSDRendered(stage string, release *userspaceiptsd.Release) error {
	renderedRoot := filepath.Join(stage, "rendered")
	if err := os.Mkdir(renderedRoot, 0o700); err != nil {
		return fmt.Errorf("create rendered IPTSD staging directory: %w", err)
	}
	for index := range release.Files {
		file := &release.Files[index]
		if file.Source != "" {
			continue
		}
		path := filepath.Join(renderedRoot, fmt.Sprintf("%02d", index))
		if err := writePrivateFile(path, file.Data, file.SHA256, file.Size); err != nil {
			return fmt.Errorf("stage rendered IPTSD file %s: %w", file.Target, err)
		}
		file.Source = path
		file.Data = nil
	}
	return nil
}

// planIPTSDTransaction resolves every target and private backup before target
// mutation while rejecting links, special files, and a non-standard mask.
func planIPTSDTransaction(options Options, release userspaceiptsd.Release, backupRelative string, liveRoot bool) ([]iptsdChangePlan, iptsdMaskPlan, Result, error) {
	backupSentinel, err := resolveTarget(options.Root, filepath.ToSlash(filepath.Join(backupRelative, ".sentinel")))
	if err != nil {
		return nil, iptsdMaskPlan{}, Result{}, err
	}
	backupDirectory := filepath.Dir(backupSentinel)
	receipt, err := resolveTarget(options.Root, filepath.ToSlash(filepath.Join(backupRelative, iptsdReceiptName)))
	if err != nil {
		return nil, iptsdMaskPlan{}, Result{}, err
	}
	result := Result{
		Component: IPTSDComponent, Root: options.Root, DryRun: options.DryRun,
		BackupDirectory: backupDirectory, Receipt: receipt,
		ActivationRequired: liveRoot, ActivationComplete: !liveRoot,
	}
	if result.ActivationRequired {
		result.Commands = cloneInstallCommands(iptsdActivationCommands)
	}
	plans := make([]iptsdChangePlan, 0, len(release.Files))
	for _, file := range release.Files {
		destination, err := resolveTarget(options.Root, file.Target)
		if err != nil {
			return nil, iptsdMaskPlan{}, Result{}, err
		}
		plan := iptsdChangePlan{
			change: FileChange{Source: file.SourceLabel, Target: destination, Action: "create"},
			source: file.Source, sourceDigest: file.SHA256, sourceSize: file.Size, mode: file.Mode,
		}
		if info, inspectErr := os.Lstat(destination); inspectErr == nil {
			if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
				return nil, iptsdMaskPlan{}, Result{}, fmt.Errorf("refusing to replace non-regular IPTSD target %s", destination)
			}
			plan.change.Replaced = true
			plan.change.Action = "replace"
			plan.originalMode = info.Mode().Perm()
			plan.originalSize = info.Size()
			plan.originalDigest, _, err = hashRegularNoFollow(destination)
			if err != nil {
				return nil, iptsdMaskPlan{}, Result{}, fmt.Errorf("hash existing IPTSD target %s: %w", destination, err)
			}
			plan.change.Backup, err = resolveTarget(options.Root, filepath.ToSlash(filepath.Join(backupRelative, file.Target)))
			if err != nil {
				return nil, iptsdMaskPlan{}, Result{}, err
			}
		} else if !errors.Is(inspectErr, os.ErrNotExist) {
			return nil, iptsdMaskPlan{}, Result{}, fmt.Errorf("inspect IPTSD target %s: %w", destination, inspectErr)
		}
		plans = append(plans, plan)
		result.Files = append(result.Files, plan.change)
	}
	mask, err := inspectIPTSDMask(options.Root)
	if err != nil {
		return nil, iptsdMaskPlan{}, Result{}, err
	}
	maskAction := "create-mask"
	if mask.existed {
		maskAction = "retain-mask"
	}
	result.Files = append(result.Files, FileChange{Source: "mask:/dev/null", Target: mask.path, Replaced: mask.existed, Action: maskAction})
	return plans, mask, result, nil
}

// inspectIPTSDMask accepts only an absent leaf or the exact /dev/null link.
func inspectIPTSDMask(root string) (iptsdMaskPlan, error) {
	parentSentinel, err := resolveTarget(root, "etc/systemd/system/.linux-armer-iptsd-sentinel")
	if err != nil {
		return iptsdMaskPlan{}, err
	}
	mask := filepath.Join(filepath.Dir(parentSentinel), filepath.Base(iptsdMaskRelative))
	info, err := os.Lstat(mask)
	if errors.Is(err, os.ErrNotExist) {
		return iptsdMaskPlan{path: mask}, nil
	}
	if err != nil {
		return iptsdMaskPlan{}, fmt.Errorf("inspect generic IPTSD mask: %w", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return iptsdMaskPlan{}, fmt.Errorf("refusing to replace custom generic IPTSD unit: %s", mask)
	}
	target, err := os.Readlink(mask)
	if err != nil {
		return iptsdMaskPlan{}, fmt.Errorf("read generic IPTSD mask: %w", err)
	}
	if target != "/dev/null" {
		return iptsdMaskPlan{}, fmt.Errorf("generic IPTSD mask has unexpected target %q", target)
	}
	return iptsdMaskPlan{path: mask, existed: true}, nil
}

// prepareIPTSDBackups creates one private transaction directory and copies all
// observed original regular files before any replacement is published.
func (installer *Installer) prepareIPTSDBackups(root, backupRelative, backupDirectory string, plans []iptsdChangePlan) error {
	revalidated, err := resolveTarget(root, filepath.ToSlash(filepath.Join(backupRelative, ".sentinel")))
	if err != nil || filepath.Dir(revalidated) != backupDirectory {
		return errors.New("IPTSD backup path changed after planning")
	}
	if err := os.MkdirAll(filepath.Dir(backupDirectory), 0o700); err != nil {
		return fmt.Errorf("create IPTSD backup parent: %w", err)
	}
	if err := os.Mkdir(backupDirectory, 0o700); err != nil {
		return fmt.Errorf("create unique IPTSD backup directory: %w", err)
	}
	for _, plan := range plans {
		if !plan.change.Replaced {
			continue
		}
		if err := atomicCopyVerified(plan.change.Target, plan.change.Backup, plan.originalMode, plan.originalDigest, plan.originalSize); err != nil {
			return fmt.Errorf("back up IPTSD target %s: %w", plan.change.Target, err)
		}
	}
	return syncDirectory(backupDirectory)
}

// revalidateIPTSDTarget detects target or parent mutation after planning and
// before each atomic publication.
func revalidateIPTSDTarget(root string, plan iptsdChangePlan) error {
	resolved, err := resolveTarget(root, relativeToRoot(root, plan.change.Target))
	if err != nil || resolved != plan.change.Target {
		return fmt.Errorf("IPTSD target changed after planning: %s", plan.change.Target)
	}
	if !plan.change.Replaced {
		if _, err := os.Lstat(plan.change.Target); errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("new IPTSD target appeared after planning: %s", plan.change.Target)
	}
	digest, info, err := hashRegularNoFollow(plan.change.Target)
	if err != nil || digest != plan.originalDigest || info.Size() != plan.originalSize || info.Mode().Perm() != plan.originalMode.Perm() {
		return fmt.Errorf("existing IPTSD target changed after backup: %s", plan.change.Target)
	}
	return nil
}

// revalidateIPTSDMask detects a mask mutation after planning.
func revalidateIPTSDMask(root string, mask iptsdMaskPlan) error {
	parentSentinel, err := resolveTarget(root, "etc/systemd/system/.linux-armer-iptsd-sentinel")
	if err != nil || filepath.Dir(parentSentinel) != filepath.Dir(mask.path) {
		return fmt.Errorf("generic IPTSD mask parent changed after planning: %s", mask.path)
	}
	info, err := os.Lstat(mask.path)
	if !mask.existed {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("generic IPTSD mask appeared after planning: %s", mask.path)
	}
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		return fmt.Errorf("generic IPTSD mask changed after planning: %s", mask.path)
	}
	target, readErr := os.Readlink(mask.path)
	if readErr != nil || target != "/dev/null" {
		return fmt.Errorf("generic IPTSD mask changed after planning: %s", mask.path)
	}
	return nil
}

// rollbackIPTSD removes newly published files, restores private backups, and
// removes only a mask created by this transaction.
func rollbackIPTSD(applied []iptsdChangePlan, mask iptsdMaskPlan, maskCreated bool) error {
	var rollbackErr error
	if maskCreated {
		if err := removeOwnedIPTSDMask(mask.path); err != nil {
			rollbackErr = errors.Join(rollbackErr, err)
		}
	}
	for index := len(applied) - 1; index >= 0; index-- {
		plan := applied[index]
		if plan.change.Replaced {
			digest, _, err := hashRegularNoFollow(plan.change.Target)
			if err != nil || digest != plan.sourceDigest {
				rollbackErr = errors.Join(rollbackErr, fmt.Errorf("refusing to replace changed rollback target %s", plan.change.Target))
				continue
			}
			if err := atomicCopyVerified(plan.change.Backup, plan.change.Target, plan.originalMode, plan.originalDigest, plan.originalSize); err != nil {
				rollbackErr = errors.Join(rollbackErr, fmt.Errorf("restore %s: %w", plan.change.Target, err))
			}
			continue
		}
		digest, _, err := hashRegularNoFollow(plan.change.Target)
		if err != nil || digest != plan.sourceDigest {
			rollbackErr = errors.Join(rollbackErr, fmt.Errorf("refusing to remove changed rollback target %s", plan.change.Target))
			continue
		}
		if err := os.Remove(plan.change.Target); err != nil && !errors.Is(err, os.ErrNotExist) {
			rollbackErr = errors.Join(rollbackErr, fmt.Errorf("remove new IPTSD target %s: %w", plan.change.Target, err))
		} else if err == nil {
			rollbackErr = errors.Join(rollbackErr, syncDirectory(filepath.Dir(plan.change.Target)))
		}
	}
	return rollbackErr
}

// removeOwnedIPTSDMask removes only the exact link created by this transaction.
func removeOwnedIPTSDMask(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		return fmt.Errorf("refusing to remove changed IPTSD mask %s", path)
	}
	target, err := os.Readlink(path)
	if err != nil || target != "/dev/null" {
		return fmt.Errorf("refusing to remove changed IPTSD mask %s", path)
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

// writePrivateFile writes immutable private staging content and revalidates its
// digest and exact length before returning.
func writePrivateFile(path string, data []byte, digest string, size int64) error {
	if int64(len(data)) != size {
		return errors.New("private IPTSD staging content has an unexpected size")
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	if got, info, err := hashRegularNoFollow(path); err != nil || got != digest || info.Size() != size {
		return errors.New("private IPTSD staging content failed digest validation")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	err = file.Sync()
	return errors.Join(err, file.Close())
}

// writeIPTSDReceipt atomically records installed-file durability and activation
// state in the private transaction directory.
func writeIPTSDReceipt(result Result, installedAt time.Time) error {
	receipt := iptsdReceipt{
		SchemaVersion: iptsdReceiptSchemaVersion, Component: result.Component,
		InstalledAt: installedAt.UTC().Format(time.RFC3339Nano), Root: result.Root,
		Files: result.Files, Commands: result.Commands, FilesInstalled: result.FilesInstalled,
		ActivationRequired: result.ActivationRequired, ActivationComplete: result.ActivationComplete,
		ActivationError: result.ActivationError,
	}
	data, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return fmt.Errorf("encode IPTSD receipt: %w", err)
	}
	data = append(data, '\n')
	directory := filepath.Dir(result.Receipt)
	temporary, err := os.CreateTemp(directory, ".receipt-*")
	if err != nil {
		return fmt.Errorf("create atomic IPTSD receipt: %w", err)
	}
	name := temporary.Name()
	remove := true
	defer func() {
		_ = temporary.Close()
		if remove {
			_ = os.Remove(name)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if info, err := os.Lstat(result.Receipt); err == nil && (info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular()) {
		return errors.New("refusing non-regular IPTSD receipt target")
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.Rename(name, result.Receipt); err != nil {
		return fmt.Errorf("publish IPTSD receipt: %w", err)
	}
	remove = false
	return syncDirectory(directory)
}

// removeFailedIPTSDReceipt removes only a regular receipt in the transaction's
// private directory when initial receipt durability failed before activation.
func removeFailedIPTSDReceipt(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("refusing to remove a changed failed IPTSD receipt")
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

// activateIPTSD executes every fixed live-root command with a per-command
// timeout and bounded combined output, collecting all failures.
func (installer *Installer) activateIPTSD(ctx context.Context, commands []Command) error {
	timeout := installer.activationTimeout
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	var activationErr error
	for _, command := range commands {
		commandContext, cancel := context.WithTimeout(ctx, timeout)
		output := &boundedActivationOutput{}
		err := installer.runner.Run(commandContext, platform.Command{
			Name: command.Name, Args: append([]string(nil), command.Args...), Stdout: io.Writer(output), Stderr: io.Writer(output),
		})
		cancel()
		if err == nil {
			continue
		}
		detail := output.String()
		if detail == "" {
			detail = err.Error()
		}
		activationErr = errors.Join(activationErr, fmt.Errorf("%s %s: %s", command.Name, strings.Join(command.Args, " "), detail))
	}
	return activationErr
}

// cloneInstallCommands prevents result consumers from mutating compiled policy.
func cloneInstallCommands(commands []Command) []Command {
	cloned := make([]Command, len(commands))
	for index, command := range commands {
		cloned[index] = Command{Name: command.Name, Args: append([]string(nil), command.Args...)}
	}
	return cloned
}
