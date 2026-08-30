package install

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// prepare builds a complete immutable preflight plan without target mutation.
func (manager *Manager) prepare(ctx context.Context, request Request) (Plan, error) {
	if manager == nil || manager.runner == nil {
		return Plan{}, errors.New("kernel installation manager is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return Plan{}, err
	}
	root, err := canonicalRoot(request.Root)
	if err != nil {
		return Plan{}, err
	}
	if err := validateABI("target", request.Bundle.ABI); err != nil {
		return Plan{}, err
	}
	if err := validateABI("fallback", request.FallbackABI); err != nil {
		return Plan{}, err
	}
	if request.Bundle.ABI == request.FallbackABI {
		return Plan{}, fmt.Errorf("target ABI must differ from fallback ABI: %s", request.Bundle.ABI)
	}
	runningABI, err := manager.runningABI(ctx, root, request.RunningABI)
	if err != nil {
		return Plan{}, err
	}
	if runningABI != request.FallbackABI {
		return Plan{}, fmt.Errorf("running ABI must exactly match fallback ABI: running %s, fallback %s", runningABI, request.FallbackABI)
	}

	packages, err := manager.inspectBundle(ctx, request.Bundle)
	if err != nil {
		return Plan{}, err
	}
	unverified := false
	for _, item := range packages {
		unverified = unverified || !item.PublisherVerified
	}
	if unverified && !request.AllowUnverified {
		return Plan{}, errors.New("kernel bundle is not covered by an authoritative checksum manifest; explicitly allow an unverified local bundle to continue")
	}
	fallback, err := verifyFallback(ctx, root, request.FallbackABI)
	if err != nil {
		return Plan{}, err
	}
	if err := verifyTargetAbsent(ctx, root, request.Bundle.ABI); err != nil {
		return Plan{}, err
	}
	deviceTrees := make([]DeviceTree, 0, len(requiredDeviceTrees))
	for _, tree := range requiredDeviceTrees {
		relative := "usr/lib/firmware/" + request.Bundle.ABI + "/device-tree/" + tree.Path
		target, err := rootPath(root, relative)
		if err != nil {
			return Plan{}, err
		}
		deviceTrees = append(deviceTrees, DeviceTree{Device: tree.Device, RelativePath: tree.Path, TargetPath: target})
	}
	packagePaths := make([]string, 0, len(packages))
	for _, item := range packages {
		path := item.Path
		if root != string(filepath.Separator) {
			path = "/var/tmp/" + stagingPrefix + "verified/" + item.Name
		}
		packagePaths = append(packagePaths, path)
	}
	commands, err := installationCommands(root, request.Bundle.ABI, packagePaths)
	if err != nil {
		return Plan{}, err
	}
	return Plan{
		Root:               root,
		TargetABI:          request.Bundle.ABI,
		FallbackABI:        request.FallbackABI,
		RunningABI:         runningABI,
		Version:            request.Bundle.Version,
		DryRun:             request.DryRun,
		UnverifiedAccepted: unverified,
		Packages:           packages,
		DeviceTrees:        deviceTrees,
		Fallback:           fallback,
		Commands:           commands,
	}, nil
}

// runningABI obtains live uname evidence or validates an alternate-root fixture override.
func (manager *Manager) runningABI(ctx context.Context, root, override string) (string, error) {
	if root != string(filepath.Separator) {
		if strings.TrimSpace(override) == "" {
			return "", errors.New("alternate-root preflight requires an explicit running ABI fixture value")
		}
		if err := validateABI("running", override); err != nil {
			return "", err
		}
		return override, nil
	}
	if override != "" {
		return "", errors.New("running ABI override is permitted only with an alternate target root")
	}
	command := Command{Operation: OperationInspectRunningABI, Name: unameCommand, Args: []string{"-r"}}
	if err := validateCommand(command); err != nil {
		return "", err
	}
	output, err := manager.captureCommand(ctx, command, maximumABIBytes+2)
	if err != nil {
		return "", fmt.Errorf("read running kernel ABI: %w", err)
	}
	if len(output) > maximumABIBytes+2 {
		return "", errors.New("running kernel ABI output is oversized")
	}
	abi := strings.TrimSuffix(strings.TrimSuffix(string(output), "\n"), "\r")
	if err := validateABI("running", abi); err != nil {
		return "", err
	}
	return abi, nil
}

// Install preflights the request and either returns its dry-run receipt or
// performs the guarded privileged transaction followed by complete verification.
func (manager *Manager) Install(ctx context.Context, request Request) (receipt Receipt, resultErr error) {
	started := managerTimestamp(manager)
	receipt.StartedAt = started
	defer func() {
		receipt.CompletedAt = managerTimestamp(manager)
	}()

	plan, err := manager.prepare(ctx, request)
	if err != nil {
		return receipt, err
	}
	receipt.Plan = plan
	if request.DryRun {
		return receipt, nil
	}
	if manager.effectiveUID == nil || manager.effectiveUID() != 0 {
		return receipt, errors.New("kernel installation requires effective UID 0; review a dry run, then rerun as root")
	}

	staged, cleanup, err := manager.stagePackages(ctx, plan.Root, plan.Packages)
	if err != nil {
		return receipt, err
	}
	defer cleanup()
	if err := manager.revalidateStagedMetadata(ctx, plan.Packages, staged); err != nil {
		return receipt, err
	}
	if err := verifyTargetAbsent(ctx, plan.Root, plan.TargetABI); err != nil {
		return receipt, fmt.Errorf("target changed after preflight: %w", err)
	}
	currentFallback, err := verifyFallback(ctx, plan.Root, plan.FallbackABI)
	if err != nil {
		return receipt, fmt.Errorf("fallback changed after preflight: %w", err)
	}
	if err := fallbackUnchanged(plan.Fallback, currentFallback); err != nil {
		return receipt, err
	}

	backup, backupCleanup, err := createGRUBBackup(ctx, plan.Root)
	if err != nil {
		return receipt, err
	}
	defer backupCleanup()
	commands, err := installationCommands(plan.Root, plan.TargetABI, staged.commandPaths)
	if err != nil {
		return receipt, err
	}
	mutationStarted := false
	for _, command := range commands {
		if err := ctx.Err(); err != nil {
			if mutationStarted {
				return manager.failAndRollback(plan, backup, receipt, err)
			}
			return receipt, err
		}
		if err := validateCommand(command); err != nil {
			if mutationStarted {
				return manager.failAndRollback(plan, backup, receipt, err)
			}
			return receipt, err
		}
		receipt.Executed = append(receipt.Executed, cloneCommand(command))
		mutationStarted = true
		if err := manager.runner.Run(ctx, platform.Command{Name: command.Name, Args: append([]string(nil), command.Args...)}); err != nil {
			return manager.failAndRollback(plan, backup, receipt, fmt.Errorf("%s: %w", command.Operation, err))
		}
	}

	installed, trees, err := verifyInstalled(ctx, plan.Root, plan.TargetABI, plan.DeviceTrees)
	if err != nil {
		return manager.failAndRollback(plan, backup, receipt, err)
	}
	currentFallback, err = verifyFallback(ctx, plan.Root, plan.FallbackABI)
	if err != nil {
		return manager.failAndRollback(plan, backup, receipt, err)
	}
	if err := fallbackUnchanged(plan.Fallback, currentFallback); err != nil {
		return manager.failAndRollback(plan, backup, receipt, err)
	}
	receipt.Installed = &installed
	receipt.DeviceTrees = trees
	receipt.RebootRequired = true
	return receipt, nil
}

// managerTimestamp safely obtains a timestamp even from a nil or test manager.
func managerTimestamp(manager *Manager) time.Time {
	if manager == nil || manager.now == nil {
		return time.Time{}
	}
	return manager.now().UTC()
}

// cloneCommand prevents later slice mutation from altering receipt evidence.
func cloneCommand(command Command) Command {
	command.Args = append([]string(nil), command.Args...)
	return command
}
