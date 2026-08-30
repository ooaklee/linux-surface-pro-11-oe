package build

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	// transactionPrefix identifies private host-side container exchanges.
	transactionPrefix = ".linux-armer-kernel-build-"
	// buildLockDirectoryName serialises processes sharing one persistent volume.
	buildLockDirectoryName = ".linux-armer-kernel-build.lock"
	// containerCleanupTimeout bounds recovery independently of caller cancellation.
	containerCleanupTimeout = 30 * time.Second
)

// containerTokenExpression accepts only the random lowercase hexadecimal token.
var containerTokenExpression = regexp.MustCompile(`^[0-9a-f]{24}$`)

// prepare returns a complete plan without creating directories or invoking Docker.
func (manager *Manager) prepare(ctx context.Context, request Request) (Plan, error) {
	if manager == nil || manager.Runner == nil {
		return Plan{}, errors.New("kernel build runner is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return Plan{}, err
	}
	resolved, err := resolveRequest(request)
	if err != nil {
		return Plan{}, err
	}
	identity := workspaceIdentity(resolved.repositoryRoot, resolved.workDirectory)
	plan := Plan{
		SchemaVersion:     SchemaVersion,
		RepositoryRoot:    resolved.repositoryRoot,
		WorkDirectory:     resolved.workDirectory,
		OutputDirectory:   resolved.outputDirectory,
		GitURL:            resolved.gitURL,
		GitRef:            resolved.gitRef,
		Jobs:              resolved.jobs,
		ResetSource:       resolved.resetSource,
		SkipClean:         resolved.skipClean,
		DryRun:            resolved.dryRun,
		ContainerImage:    ContainerImage,
		BuildTarget:       containerBuildTarget,
		MinimumFreeGiB:    containerMinimumFreeGiB,
		WorkVolume:        volumeName(identity),
		WorkspaceIdentity: identity,
		RecipeSHA256:      compiledRecipeSHA256(),
	}
	plan.Commands = []Command{volumeCreateCommand(plan), volumeInspectCommand(plan), previewContainerCommand(plan)}
	for _, command := range plan.Commands {
		if err := validateCommand(command); err != nil {
			return Plan{}, fmt.Errorf("prepare kernel build command preview: %w", err)
		}
	}
	return plan, nil
}

// Run prepares and executes a native container build or returns its dry-run receipt.
func (manager *Manager) Run(ctx context.Context, request Request) (receipt Receipt, resultErr error) {
	receipt.StartedAt = managerTimestamp(manager)
	defer func() {
		receipt.CompletedAt = managerTimestamp(manager)
	}()

	plan, err := manager.prepare(ctx, request)
	if err != nil {
		return receipt, err
	}
	receipt.Plan = plan
	if plan.DryRun {
		return receipt, nil
	}
	if err := prepareWorkDirectory(plan); err != nil {
		return receipt, err
	}
	releaseLock, err := acquireBuildLock(plan.WorkDirectory)
	if err != nil {
		return receipt, err
	}
	defer func() {
		resultErr = errors.Join(resultErr, releaseLock())
	}()
	transaction, err := os.MkdirTemp(plan.WorkDirectory, transactionPrefix)
	if err != nil {
		return receipt, fmt.Errorf("create private kernel build transaction: %w", err)
	}
	transaction = filepath.Clean(transaction)
	transactionInfo, err := os.Lstat(transaction)
	if err != nil || transactionInfo.Mode()&os.ModeSymlink != 0 || !transactionInfo.IsDir() {
		return receipt, fmt.Errorf("inspect private kernel build transaction: %s", transaction)
	}
	cleanupTransaction := func() error {
		current, err := os.Lstat(transaction)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(transactionInfo, current) {
			return fmt.Errorf("refuse to remove changed kernel build transaction: %s", transaction)
		}
		if err := os.RemoveAll(transaction); err != nil {
			return fmt.Errorf("remove private kernel build transaction: %w", err)
		}
		return nil
	}
	if err := os.Chmod(transaction, 0o700); err != nil {
		return receipt, errors.Join(fmt.Errorf("protect private kernel build transaction: %w", err), cleanupTransaction())
	}
	if err := validateTransactionDirectory(plan.WorkDirectory, transaction); err != nil {
		return receipt, errors.Join(err, cleanupTransaction())
	}
	if err := writeContainerRecipe(transaction, plan.RecipeSHA256); err != nil {
		return receipt, errors.Join(err, cleanupTransaction())
	}
	if err := manager.ensureWorkVolume(ctx, &receipt); err != nil {
		return receipt, errors.Join(err, cleanupTransaction())
	}
	if manager.token == nil {
		return receipt, errors.Join(errors.New("kernel build container identifier source is unavailable"), cleanupTransaction())
	}
	containerToken, err := manager.token()
	if err != nil {
		return receipt, errors.Join(err, cleanupTransaction())
	}
	if !containerTokenExpression.MatchString(containerToken) {
		return receipt, errors.Join(errors.New("generated kernel build container identifier is malformed"), cleanupTransaction())
	}
	containerName := dockerContainerPrefix + containerToken
	if err := validateTransactionDirectory(plan.WorkDirectory, transaction); err != nil {
		return receipt, errors.Join(err, cleanupTransaction())
	}
	command := containerCommand(plan, transaction, containerName)
	if err := manager.runCommand(ctx, &receipt, command); err != nil {
		receipt.Interrupted = ctx.Err() != nil
		cleanupErr := manager.forceRemoveContainer(&receipt, containerName)
		return receipt, errors.Join(fmt.Errorf("Docker kernel build failed: %w", err), cleanupErr, cleanupTransaction())
	}
	if err := validateTransactionDirectory(plan.WorkDirectory, transaction); err != nil {
		return receipt, errors.Join(err, cleanupTransaction())
	}
	provenance, err := readProvenance(transaction, plan)
	if err != nil {
		return receipt, errors.Join(err, cleanupTransaction())
	}
	receipt.Provenance = &provenance
	bundle, artifacts, err := inspectArtifacts(ctx, transaction, plan, provenance)
	if err != nil {
		return receipt, errors.Join(err, cleanupTransaction())
	}
	published, didPublish, err := publishArtifacts(ctx, plan, provenance, bundle, artifacts)
	receipt.Artifacts = published
	receipt.Published = didPublish
	if err != nil {
		return receipt, errors.Join(err, cleanupTransaction())
	}
	receipt.PublicationDurable = true
	if err := cleanupTransaction(); err != nil {
		return receipt, err
	}
	return receipt, nil
}

// acquireBuildLock refuses concurrent processes that would otherwise mutate
// the same labelled Docker source volume.
func acquireBuildLock(workDirectory string) (func() error, error) {
	lockPath := filepath.Join(workDirectory, buildLockDirectoryName)
	if err := os.Mkdir(lockPath, 0o700); err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, fmt.Errorf("another kernel build is using this work directory, or a stale lock remains: %s", lockPath)
		}
		return nil, fmt.Errorf("create kernel build lock: %w", err)
	}
	if err := validateTransactionDirectory(workDirectory, lockPath); err != nil {
		_ = os.Remove(lockPath)
		return nil, fmt.Errorf("validate kernel build lock: %w", err)
	}
	lockInfo, err := os.Lstat(lockPath)
	if err != nil {
		_ = os.Remove(lockPath)
		return nil, fmt.Errorf("inspect kernel build lock: %w", err)
	}
	released := false
	return func() error {
		if released {
			return nil
		}
		released = true
		current, err := os.Lstat(lockPath)
		if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(lockInfo, current) {
			return fmt.Errorf("refuse to remove changed kernel build lock: %s", lockPath)
		}
		if err := os.Remove(lockPath); err != nil {
			return fmt.Errorf("remove kernel build lock: %w", err)
		}
		return nil
	}, nil
}

// prepareWorkDirectory creates only the explicit private work directory and
// revalidates its route before Docker receives it.
func prepareWorkDirectory(plan Plan) error {
	if err := requireNewOutput(plan.OutputDirectory); err != nil {
		return err
	}
	if err := validateRoute(plan.RepositoryRoot, plan.WorkDirectory); err != nil {
		return fmt.Errorf("revalidate kernel build work directory: %w", err)
	}
	if err := os.MkdirAll(plan.WorkDirectory, 0o700); err != nil {
		return fmt.Errorf("create kernel build work directory: %w", err)
	}
	if err := validateRoute(plan.RepositoryRoot, plan.WorkDirectory); err != nil {
		return fmt.Errorf("revalidate created kernel build work directory: %w", err)
	}
	canonical, err := filepath.EvalSymlinks(plan.WorkDirectory)
	if err != nil || filepath.Clean(canonical) != filepath.Clean(plan.WorkDirectory) {
		return fmt.Errorf("kernel build work directory became symbolic or unavailable: %s", plan.WorkDirectory)
	}
	info, err := os.Lstat(plan.WorkDirectory)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("kernel build work directory is not a non-symbolic-link directory: %s", plan.WorkDirectory)
	}
	return nil
}

// validateTransactionDirectory proves that a private exchange remains a
// direct, canonical child of the reviewed work directory.
func validateTransactionDirectory(workDirectory, transaction string) error {
	workCanonical, err := filepath.EvalSymlinks(workDirectory)
	if err != nil || filepath.Clean(workCanonical) != filepath.Clean(workDirectory) {
		return fmt.Errorf("kernel build work directory changed before Docker invocation: %s", workDirectory)
	}
	transactionCanonical, err := filepath.EvalSymlinks(transaction)
	if err != nil || filepath.Clean(transactionCanonical) != filepath.Clean(transaction) {
		return fmt.Errorf("private kernel build transaction became symbolic or unavailable: %s", transaction)
	}
	relative, err := filepath.Rel(workCanonical, transactionCanonical)
	if err != nil || relative == "." || filepath.Dir(relative) != "." {
		return fmt.Errorf("private kernel build transaction escaped its reviewed work directory: %s", transaction)
	}
	info, err := os.Lstat(transaction)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("private kernel build transaction is not a non-symbolic-link directory: %s", transaction)
	}
	return nil
}

// writeContainerRecipe materialises only the compiled recipe in the private transaction.
func writeContainerRecipe(transaction, expectedDigest string) error {
	if compiledRecipeSHA256() != expectedDigest {
		return errors.New("compiled kernel build recipe identity changed after planning")
	}
	path := filepath.Join(transaction, "build-policy.sh")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o500)
	if err != nil {
		return fmt.Errorf("create private kernel build recipe: %w", err)
	}
	_, writeErr := file.WriteString(containerRecipe)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		return fmt.Errorf("write private kernel build recipe: %w", err)
	}
	return nil
}

// ensureWorkVolume creates or reuses only a correctly labelled local Docker volume.
func (manager *Manager) ensureWorkVolume(ctx context.Context, receipt *Receipt) error {
	created, err := manager.captureCommand(ctx, receipt, volumeCreateCommand(receipt.Plan))
	if err != nil {
		return fmt.Errorf("create labelled kernel build volume: %w", err)
	}
	if created != receipt.Plan.WorkVolume {
		return fmt.Errorf("Docker returned unexpected kernel build volume %q", created)
	}
	identity, err := manager.captureCommand(ctx, receipt, volumeInspectCommand(receipt.Plan))
	if err != nil {
		return fmt.Errorf("inspect labelled kernel build volume: %w", err)
	}
	expected := receipt.Plan.WorkVolume + "|local|true|" + receipt.Plan.WorkspaceIdentity
	if identity != expected {
		return fmt.Errorf("refuse kernel build volume with mismatched ownership: got %q", identity)
	}
	return nil
}

// forceRemoveContainer attempts bounded recovery without inheriting cancellation.
func (manager *Manager) forceRemoveContainer(receipt *Receipt, containerName string) error {
	cleanup := &CleanupReceipt{Attempted: true}
	receipt.Cleanup = cleanup
	command := cleanupContainerCommand(containerName)
	cleanup.Command = commandPointer(command)
	cleanupContext, cancel := context.WithTimeout(context.Background(), containerCleanupTimeout)
	defer cancel()
	if err := manager.runCommand(cleanupContext, receipt, command); err != nil {
		cleanup.Error = boundedDiagnostic(err)
		return fmt.Errorf("force-remove failed kernel build container: %w", err)
	}
	return nil
}

// commandPointer returns an independently owned command for a receipt field.
func commandPointer(command Command) *Command {
	copy := cloneCommand(command)
	return &copy
}

// managerTimestamp safely obtains a UTC receipt timestamp.
func managerTimestamp(manager *Manager) time.Time {
	if manager == nil || manager.now == nil {
		return time.Time{}
	}
	return manager.now().UTC()
}

// boundedDiagnostic removes controls and limits retained recovery diagnostics.
func boundedDiagnostic(err error) string {
	if err == nil {
		return ""
	}
	value := strings.Map(func(character rune) rune {
		if character < 0x20 && character != '\n' && character != '\t' || character == 0x7f {
			return -1
		}
		return character
	}, err.Error())
	if len(value) > maximumDockerCaptureBytes {
		value = value[:maximumDockerCaptureBytes]
		for len(value) > 0 && !utf8.ValidString(value) {
			value = value[:len(value)-1]
		}
	}
	return value
}
