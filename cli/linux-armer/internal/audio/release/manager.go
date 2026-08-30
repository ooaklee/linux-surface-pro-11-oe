package release

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

// Plan validates all source bytes and returns a truthful local-only decision.
func (manager *Manager) Plan(ctx context.Context, request Request) (Plan, error) {
	plan, _, err := manager.plan(ctx, request)
	return plan, err
}

// plan resolves paths, validates pairing, and snapshots all pinned sources.
func (manager *Manager) plan(ctx context.Context, request Request) (Plan, sourceSnapshot, error) {
	if manager == nil || len(manager.policy.sources) != 4 || len(manager.policy.artefacts) != 4 {
		return Plan{}, sourceSnapshot{}, errors.New("audio release policy is unavailable or incomplete")
	}
	if err := ctx.Err(); err != nil {
		return Plan{}, sourceSnapshot{}, err
	}
	repositoryRoot, err := canonicalDirectory(request.RepositoryRoot, "repository root")
	if err != nil {
		return Plan{}, sourceSnapshot{}, err
	}
	sourceRoot, err := canonicalDirectory(request.SourceRoot, "audio source root")
	if err != nil {
		return Plan{}, sourceSnapshot{}, err
	}
	if request.Tag != manager.policy.tag || !safePortableName(request.Tag) {
		return Plan{}, sourceSnapshot{}, fmt.Errorf("audio release tag must be the reviewed %q identity", manager.policy.tag)
	}
	kernelGeneration, err := parseKernelPair(request.KernelTag, request.KernelABI)
	if err != nil {
		return Plan{}, sourceSnapshot{}, err
	}
	outputDirectory := filepath.Join(repositoryRoot, filepath.FromSlash(DefaultOutputDirectory))
	releaseDirectory := filepath.Join(outputDirectory, request.Tag)
	if !containedBy(repositoryRoot, outputDirectory) || outputDirectory == repositoryRoot {
		return Plan{}, sourceSnapshot{}, errors.New("audio release output escapes the repository root")
	}
	if containedBy(sourceRoot, outputDirectory) || containedBy(outputDirectory, sourceRoot) {
		return Plan{}, sourceSnapshot{}, errors.New("audio source and release output directories must not overlap")
	}
	if err := rejectSymbolicRoute(repositoryRoot, releaseDirectory); err != nil {
		return Plan{}, sourceSnapshot{}, err
	}
	if _, err := os.Lstat(releaseDirectory); err == nil {
		return Plan{}, sourceSnapshot{}, errors.New("audio release destination already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return Plan{}, sourceSnapshot{}, fmt.Errorf("inspect audio release destination: %w", err)
	}
	snapshot, err := snapshotSource(ctx, sourceRoot, manager.policy)
	if err != nil {
		return Plan{}, sourceSnapshot{}, fmt.Errorf("validate pinned FullIO v19c sources: %w", err)
	}
	executable := publicationSupported()
	blocker := ""
	if !executable {
		blocker = fmt.Sprintf("atomic no-replace audio release publication is unavailable on %s", runtime.GOOS)
	}
	return Plan{
		RepositoryRoot: repositoryRoot, SourceRoot: sourceRoot, ReleaseDirectory: releaseDirectory,
		Tag: request.Tag, KernelTag: request.KernelTag, KernelABI: request.KernelABI,
		KernelGeneration: kernelGeneration, Source: snapshot.provenance, DryRun: request.DryRun,
		Executable: executable, ExecutionBlocker: blocker, MutatesRemote: false,
	}, snapshot, nil
}

// Prepare validates and atomically installs one fresh local release directory.
func (manager *Manager) Prepare(ctx context.Context, request Request) (receipt Receipt, resultErr error) {
	plan, snapshot, err := manager.plan(ctx, request)
	if err != nil {
		return receipt, err
	}
	receipt.Plan = plan
	if plan.DryRun {
		return receipt, nil
	}
	if !plan.Executable {
		return receipt, errors.New(plan.ExecutionBlocker)
	}
	if err := ctx.Err(); err != nil {
		return receipt, err
	}
	if manager.afterPlan != nil {
		if err := manager.afterPlan(plan); err != nil {
			return receipt, err
		}
	}
	outputDirectory := filepath.Dir(plan.ReleaseDirectory)
	if err := ensureDirectory(plan.RepositoryRoot, outputDirectory, 0o755); err != nil {
		return receipt, err
	}
	if err := rejectSymbolicRoute(plan.RepositoryRoot, outputDirectory); err != nil {
		return receipt, err
	}
	parent, err := os.Open(outputDirectory)
	if err != nil {
		return receipt, fmt.Errorf("open audio release parent: %w", err)
	}
	defer func() { resultErr = errors.Join(resultErr, parent.Close()) }()
	parentInfo, err := parent.Stat()
	if err != nil || !parentInfo.IsDir() {
		return receipt, errors.Join(errors.New("audio release parent is not a directory"), err)
	}
	if err := proveDirectoryIdentity(outputDirectory, parentInfo); err != nil {
		return receipt, err
	}
	if _, err := os.Lstat(plan.ReleaseDirectory); err == nil {
		return receipt, errors.New("audio release destination appeared during preparation")
	} else if !errors.Is(err, os.ErrNotExist) {
		return receipt, err
	}
	staging, err := os.MkdirTemp(outputDirectory, ".linux-armer-audio-"+plan.Tag+"-")
	if err != nil {
		return receipt, fmt.Errorf("create private audio release transaction: %w", err)
	}
	if err := os.Chmod(staging, 0o700); err != nil {
		_ = os.Remove(staging)
		return receipt, err
	}
	stagingInfo, err := os.Lstat(staging)
	if err != nil || !stagingInfo.IsDir() || stagingInfo.Mode()&os.ModeSymlink != 0 {
		_ = os.Remove(staging)
		return receipt, errors.Join(errors.New("audio release transaction is not a real directory"), err)
	}
	cleanup := true
	defer func() {
		if cleanup {
			resultErr = errors.Join(resultErr, removeTransaction(staging, stagingInfo))
		}
	}()

	for index, spec := range manager.policy.sources[:3] {
		if err := copyIdentity(ctx, snapshot.inputs[index], filepath.Join(staging, spec.releaseName)); err != nil {
			return receipt, fmt.Errorf("copy pinned %s source: %w", spec.role, err)
		}
	}
	matcherBase, err := readIdentity(ctx, snapshot.inputs[3], maximumTextBytes)
	if err != nil {
		return receipt, fmt.Errorf("reread pinned matcher base: %w", err)
	}
	matcher, err := generateMatcher(matcherBase)
	if err != nil {
		return receipt, err
	}
	if matcherRecord := inspectData(MatcherName, matcher); matcherRecord.SHA256 != manager.policy.artefacts[3].sha256 || matcherRecord.Size != manager.policy.artefacts[3].size {
		return receipt, errors.New("generated DMI matcher differs from the reviewed v19c identity")
	}
	if err := writeExclusive(filepath.Join(staging, MatcherName), matcher); err != nil {
		return receipt, fmt.Errorf("write generated DMI matcher: %w", err)
	}
	artefacts, err := inspectPolicyArtefacts(ctx, staging, manager.policy)
	if err != nil {
		return receipt, err
	}
	checksumData, err := renderChecksums(artefacts)
	if err != nil {
		return receipt, err
	}
	checksumRecord := inspectData(ChecksumName, checksumData)
	if checksumRecord.SHA256 != manager.policy.checksum.sha256 || checksumRecord.Size != manager.policy.checksum.size {
		return receipt, errors.New("generated SHA256SUMS differs from the reviewed v19c contract")
	}
	if err := writeExclusive(filepath.Join(staging, ChecksumName), checksumData); err != nil {
		return receipt, fmt.Errorf("write audio release checksums: %w", err)
	}
	manifest := Manifest{
		SchemaVersion: SchemaVersion, Status: "verified-local-preparation", Tag: plan.Tag,
		KernelTag: plan.KernelTag, KernelABI: plan.KernelABI, KernelGeneration: plan.KernelGeneration,
		Source: plan.Source, Artefacts: artefacts, ProtectedVendorBytes: true, RemoteMutation: false,
	}
	notesData := renderNotes(manifest)
	if int64(len(notesData)) > maximumTextBytes {
		return receipt, errors.New("generated audio release notes exceed their size limit")
	}
	if err := writeExclusive(filepath.Join(staging, NotesName), notesData); err != nil {
		return receipt, fmt.Errorf("write audio release notes: %w", err)
	}
	manifest.GeneratedFiles = []FileRecord{checksumRecord, inspectData(NotesName, notesData)}
	manifestData, err := marshalManifest(manifest)
	if err != nil {
		return receipt, err
	}
	if err := writeExclusive(filepath.Join(staging, ManifestName), manifestData); err != nil {
		return receipt, fmt.Errorf("write audio release manifest: %w", err)
	}
	if err := validateDirectory(ctx, staging, manifest, manager.policy, false); err != nil {
		return receipt, fmt.Errorf("validate private audio release transaction: %w", err)
	}
	if err := os.Chmod(staging, 0o755); err != nil {
		return receipt, err
	}
	stagingDirectory, err := os.Open(staging)
	if err != nil {
		return receipt, err
	}
	if err := syncDirectory(stagingDirectory); err != nil {
		_ = stagingDirectory.Close()
		return receipt, err
	}
	if manager.beforePublish != nil {
		if err := manager.beforePublish(ctx, plan); err != nil {
			_ = stagingDirectory.Close()
			return receipt, err
		}
	}
	if err := ctx.Err(); err != nil {
		_ = stagingDirectory.Close()
		return receipt, err
	}
	if err := proveDirectoryIdentity(outputDirectory, parentInfo); err != nil {
		_ = stagingDirectory.Close()
		return receipt, err
	}
	if err := proveDirectoryIdentity(staging, stagingInfo); err != nil {
		_ = stagingDirectory.Close()
		return receipt, err
	}
	stagingName := filepath.Base(staging)
	if err := publishNoReplace(int(parent.Fd()), stagingName, plan.Tag); err != nil {
		_ = stagingDirectory.Close()
		return receipt, fmt.Errorf("atomically publish local audio release: %w", err)
	}
	cleanup = false
	receipt.Manifest = &manifest
	receipt.Published = true
	if err := stagingDirectory.Close(); err != nil {
		return receipt, err
	}
	if err := syncDirectory(parent); err != nil {
		return receipt, fmt.Errorf("make audio release publication durable: %w", err)
	}
	return receipt, nil
}

// marshalManifest emits the canonical indented structured release record.
func marshalManifest(manifest Manifest) ([]byte, error) {
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("serialise audio release manifest: %w", err)
	}
	return append(data, '\n'), nil
}

// proveDirectoryIdentity checks that an opened directory still owns its path.
func proveDirectoryIdentity(path string, expected os.FileInfo) error {
	current, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("reinspect directory identity: %w", err)
	}
	if current.Mode()&os.ModeSymlink != 0 || !current.IsDir() || !os.SameFile(expected, current) {
		return errors.New("directory identity changed during audio release preparation")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || filepath.Clean(resolved) != filepath.Clean(path) {
		return errors.New("directory route changed during audio release preparation")
	}
	return nil
}

// removeTransaction removes only the unchanged private transaction and its files.
func removeTransaction(path string, expected os.FileInfo) error {
	if err := proveDirectoryIdentity(path, expected); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("refuse to remove changed audio release transaction: %w", err)
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			return fmt.Errorf("refuse to remove unexpected transaction directory: %s", entry.Name())
		}
		if err := os.Remove(filepath.Join(path, entry.Name())); err != nil {
			return err
		}
	}
	return os.Remove(path)
}
