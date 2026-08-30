// Package companion stages the optional, manifest-tracked support bundle that
// accompanies a remastered installation image.
package companion

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	mediacatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
	userspacecatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
)

const (
	// ISOFilesystemRoot is the reserved portable directory used by every
	// companion bundle inside a remastered image.
	ISOFilesystemRoot = "sp11/companion"
	// OmissionReasonNotRequested is the machine-stable reason used when callers
	// deliberately omit the optional bundle.
	OmissionReasonNotRequested = "not-requested"
	// DevelopmentCommit is the explicit provenance sentinel for an intentional
	// working-tree snapshot that is not claimed to match a clean Git revision.
	DevelopmentCommit = "working-tree"
	// IPTSDOfflineComponentID is the sole component whose audited release may be
	// carried offline by this implementation.
	IPTSDOfflineComponentID = "iptsd-v1"
	// imageCatalogueName is the maintained installation-media catalogue copied
	// into every included companion bundle.
	imageCatalogueName = "supported-isos.json"
	// userspaceCatalogueName is the maintained userspace catalogue copied into
	// every included companion bundle.
	userspaceCatalogueName = "supported-userspace.json"
	// userspaceReceiptName is the portable receipt published by the verified
	// userspace release downloader.
	userspaceReceiptName = "linux-armer-userspace-bundle.json"
	// projectLicenceDeclared records that the source root contains a recognised
	// project-level redistribution document.
	projectLicenceDeclared = "declared"
	// projectLicenceNotDeclared records that no project-level redistribution
	// document was found without inventing terms on the project's behalf.
	projectLicenceNotDeclared = "not-declared"
	// executableMode is the extraction mode declared for the companion CLI.
	executableMode = "0755"
	// executableRelativePath is the stable path of the Linux ARM64 CLI beneath
	// ISOFilesystemRoot.
	executableRelativePath = "bin/linux-arm64/linux-armer"
	// buildPackage is the maintained Go command built for the companion bundle.
	buildPackage = "./cmd/linux-armer"
	// linkerVersionVariable is the fully qualified release-version variable set
	// in the companion executable.
	linkerVersionVariable = "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/version.Version"
	// linkerCommitVariable is the fully qualified source-revision variable set
	// in the companion executable.
	linkerCommitVariable = "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/version.Commit"
	// linkerDateVariable is the fully qualified build-time variable set in the
	// companion executable.
	linkerDateVariable = "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/version.Date"
)

// BuildRequest contains the explicit source, staging, identity, catalogue, and
// verified offline-release inputs for one companion bundle.
type BuildRequest struct {
	// SourceDirectory is the canonical absolute linux-armer source root.
	SourceDirectory string
	// DestinationDirectory is the canonical absolute host staging root beneath
	// which ISOFilesystemRoot will be created.
	DestinationDirectory string
	// Version is the release or development identity injected into the CLI.
	Version string
	// Commit is the source revision injected into the CLI. DevelopmentCommit
	// explicitly identifies an intentional working-tree snapshot.
	Commit string
	// BuildDate is the canonical UTC RFC3339 timestamp injected into the CLI.
	BuildDate string
	// UserspaceCatalog is the already validated policy source used to decide
	// which verified release bundles may be redistributed offline. It may be nil
	// only when UserspaceBundles is empty.
	UserspaceCatalog *userspacecatalog.Catalog
	// UserspaceBundles contains zero or more already verified release bundles.
	UserspaceBundles []userspacerelease.Bundle
}

// Builder stages a complete companion bundle while delegating only the Go
// cross-compilation process to an injectable command runner.
type Builder struct {
	// Runner executes the argument-separated Go build without a shell.
	Runner platform.Runner
}

// preparedRequest contains fully checked inputs that may safely be copied into
// the temporary staging directory.
type preparedRequest struct {
	request          BuildRequest
	sourceFiles      []sourceFile
	licenceFiles     []sourceFile
	projectLicence   string
	userspaceBundles []preparedUserspaceBundle
}

// sourceFile pairs a canonical absolute source path with its portable archive
// or destination filename.
type sourceFile struct {
	absolutePath string
	portablePath string
	sha256       string
	size         int64
}

// preparedUserspaceBundle retains a verified catalogue component, portable
// receipt bytes, and deterministically ordered source files.
type preparedUserspaceBundle struct {
	component      userspacecatalog.Component
	bundle         userspacerelease.Bundle
	files          []userspacerelease.File
	receiptPath    string
	receiptContent []byte
}

// NewBuilder returns a companion builder backed by runner, or by direct
// argument-separated process execution when runner is nil.
func NewBuilder(runner platform.Runner) *Builder {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Builder{Runner: runner}
}

// Build validates every source before mutation, stages the companion tree
// atomically beneath the caller's destination, and returns its manifest record.
func (b *Builder) Build(ctx context.Context, request BuildRequest) (imagecontract.CompanionBundleRecord, error) {
	if b == nil || b.Runner == nil {
		return imagecontract.CompanionBundleRecord{}, errors.New("build companion bundle: command runner is required")
	}
	if ctx == nil {
		return imagecontract.CompanionBundleRecord{}, errors.New("build companion bundle: context is required")
	}
	prepared, err := prepare(ctx, b.Runner, request)
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	if err := os.MkdirAll(request.DestinationDirectory, 0o755); err != nil {
		return imagecontract.CompanionBundleRecord{}, fmt.Errorf("create companion staging destination: %w", err)
	}
	if err := validateDirectory(request.DestinationDirectory, "companion staging destination"); err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	parent, err := prepareStagingParent(request.DestinationDirectory)
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	finalRoot := filepath.Join(request.DestinationDirectory, filepath.FromSlash(ISOFilesystemRoot))
	if _, err := os.Lstat(finalRoot); err == nil {
		return imagecontract.CompanionBundleRecord{}, fmt.Errorf("companion staging root already exists: %s", finalRoot)
	} else if !errors.Is(err, os.ErrNotExist) {
		return imagecontract.CompanionBundleRecord{}, fmt.Errorf("inspect companion staging root: %w", err)
	}
	temporaryRoot, err := os.MkdirTemp(parent, ".linux-armer-companion-")
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, fmt.Errorf("create temporary companion staging root: %w", err)
	}
	if err := validateDirectChild(parent, temporaryRoot, "temporary companion staging root"); err != nil {
		_ = os.RemoveAll(temporaryRoot)
		return imagecontract.CompanionBundleRecord{}, err
	}
	published := false
	defer func() {
		if !published {
			_ = os.RemoveAll(temporaryRoot)
		}
	}()
	snapshotRoot, snapshotPrepared, err := snapshotPreparedSource(parent, prepared)
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	snapshotRemoved := false
	defer func() {
		if !snapshotRemoved {
			_ = removeSnapshot(snapshotRoot)
		}
	}()
	if err := verifySourceRevision(ctx, b.Runner, request); err != nil {
		return imagecontract.CompanionBundleRecord{}, fmt.Errorf("verify source after snapshot: %w", err)
	}
	if err := validateSnapshotCatalogues(snapshotPrepared); err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}

	record, err := b.stage(ctx, snapshotPrepared, temporaryRoot)
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	if err := setPublishedDirectoryModes(temporaryRoot); err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	if err := removeSnapshot(snapshotRoot); err != nil {
		return imagecontract.CompanionBundleRecord{}, fmt.Errorf("remove private companion source snapshot: %w", err)
	}
	snapshotRemoved = true
	if err := ValidateRecord(record); err != nil {
		return imagecontract.CompanionBundleRecord{}, fmt.Errorf("validate staged companion manifest record: %w", err)
	}
	if err := ValidateDirectory(record, temporaryRoot); err != nil {
		return imagecontract.CompanionBundleRecord{}, fmt.Errorf("validate staged companion directory: %w", err)
	}
	if err := validateStagingParent(request.DestinationDirectory, parent); err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	if err := os.Rename(temporaryRoot, finalRoot); err != nil {
		return imagecontract.CompanionBundleRecord{}, fmt.Errorf("publish companion staging root: %w", err)
	}
	published = true
	return record, nil
}

// prepareStagingParent creates or validates the fixed sp11 directory without
// following a caller-controlled symbolic link before changing its mode.
func prepareStagingParent(destinationDirectory string) (string, error) {
	parent := filepath.Join(destinationDirectory, "sp11")
	info, err := os.Lstat(parent)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.Mkdir(parent, 0o755); err != nil {
			return "", fmt.Errorf("create companion staging parent: %w", err)
		}
		info, err = os.Lstat(parent)
	}
	if err != nil {
		return "", fmt.Errorf("inspect companion staging parent: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("companion staging parent is not a non-symlink directory: %s", parent)
	}
	if err := validateStagingParent(destinationDirectory, parent); err != nil {
		return "", err
	}
	if err := os.Chmod(parent, 0o755); err != nil {
		return "", fmt.Errorf("set companion staging parent mode: %w", err)
	}
	return parent, nil
}

// validateStagingParent proves that the fixed parent still resolves to the
// direct sp11 child of the validated destination directory.
func validateStagingParent(destinationDirectory, parent string) error {
	if err := validateDirectory(parent, "companion staging parent"); err != nil {
		return err
	}
	return validateDirectChild(destinationDirectory, parent, "companion staging parent")
}

// validateDirectChild resolves both existing paths and requires child to stay
// directly beneath parent, including when an ancestor contains a safe link.
func validateDirectChild(parent, child, label string) error {
	resolvedParent, err := filepath.EvalSymlinks(parent)
	if err != nil {
		return fmt.Errorf("resolve %s parent: %w", label, err)
	}
	resolvedChild, err := filepath.EvalSymlinks(child)
	if err != nil {
		return fmt.Errorf("resolve %s: %w", label, err)
	}
	if filepath.Dir(resolvedChild) != resolvedParent {
		return fmt.Errorf("%s escapes its parent directory", label)
	}
	return nil
}

// validateSnapshotCatalogues re-parses the exact immutable catalogue copies
// used by the binary and archive, closing the gap between policy checks and use.
func validateSnapshotCatalogues(prepared preparedRequest) error {
	imageCataloguePath := filepath.Join(prepared.request.SourceDirectory, imageCatalogueName)
	if _, err := mediacatalog.LoadFile(imageCataloguePath); err != nil {
		return fmt.Errorf("validate snapshotted supported image catalogue: %w", err)
	}
	userspaceCataloguePath := filepath.Join(prepared.request.SourceDirectory, userspaceCatalogueName)
	snapshotCatalog, err := userspacecatalog.LoadFile(userspaceCataloguePath)
	if err != nil {
		return fmt.Errorf("validate snapshotted supported userspace catalogue: %w", err)
	}
	if prepared.request.UserspaceCatalog != nil && !cataloguesEqual(snapshotCatalog, prepared.request.UserspaceCatalog) {
		return errors.New("snapshotted userspace catalogue does not match the validated policy source")
	}
	return nil
}

// prepare validates all immutable caller inputs and resolves deterministic
// source and userspace file lists before creating any companion output.
func prepare(ctx context.Context, runner platform.Runner, request BuildRequest) (preparedRequest, error) {
	if err := validateDirectory(request.SourceDirectory, "linux-armer source directory"); err != nil {
		return preparedRequest{}, err
	}
	if err := validateCanonicalAbsolutePath(request.DestinationDirectory, "companion staging destination"); err != nil {
		return preparedRequest{}, err
	}
	if err := validateToolIdentity(imagecontract.ToolIdentityRecord{
		Version: request.Version, Commit: request.Commit, BuildDate: request.BuildDate,
	}); err != nil {
		return preparedRequest{}, err
	}
	if sameOrDescendant(request.DestinationDirectory, request.SourceDirectory) {
		return preparedRequest{}, errors.New("companion staging destination must be outside the linux-armer source directory")
	}
	if err := verifySourceRevision(ctx, runner, request); err != nil {
		return preparedRequest{}, err
	}

	imageCataloguePath := filepath.Join(request.SourceDirectory, imageCatalogueName)
	if err := validateRegularFile(imageCataloguePath, "supported image catalogue"); err != nil {
		return preparedRequest{}, err
	}
	if _, err := mediacatalog.LoadFile(imageCataloguePath); err != nil {
		return preparedRequest{}, fmt.Errorf("validate supported image catalogue: %w", err)
	}
	userspaceCataloguePath := filepath.Join(request.SourceDirectory, userspaceCatalogueName)
	if err := validateRegularFile(userspaceCataloguePath, "supported userspace catalogue"); err != nil {
		return preparedRequest{}, err
	}
	sourceUserspaceCatalog, err := userspacecatalog.LoadFile(userspaceCataloguePath)
	if err != nil {
		return preparedRequest{}, fmt.Errorf("validate supported userspace catalogue: %w", err)
	}
	if request.UserspaceCatalog != nil && !cataloguesEqual(sourceUserspaceCatalog, request.UserspaceCatalog) {
		return preparedRequest{}, errors.New("validated userspace catalogue does not match the explicit source directory")
	}

	sourceFiles, err := collectSourceFiles(request.SourceDirectory)
	if err != nil {
		return preparedRequest{}, err
	}
	licenceFiles, projectLicence, err := discoverLicenceFiles(request.SourceDirectory)
	if err != nil {
		return preparedRequest{}, err
	}
	userspaceBundles, err := prepareUserspaceBundles(request.UserspaceCatalog, request.UserspaceBundles)
	if err != nil {
		return preparedRequest{}, err
	}
	return preparedRequest{
		request:          request,
		sourceFiles:      sourceFiles,
		licenceFiles:     licenceFiles,
		projectLicence:   projectLicence,
		userspaceBundles: userspaceBundles,
	}, nil
}

// snapshotPreparedSource copies the complete allow-listed source set into a
// private read-only tree and remaps every later build and archive input to it.
func snapshotPreparedSource(parent string, prepared preparedRequest) (string, preparedRequest, error) {
	snapshotRoot, err := os.MkdirTemp(parent, ".linux-armer-source-")
	if err != nil {
		return "", preparedRequest{}, fmt.Errorf("create private companion source snapshot: %w", err)
	}
	cleanUp := func(returnErr error) (string, preparedRequest, error) {
		_ = removeSnapshot(snapshotRoot)
		return "", preparedRequest{}, returnErr
	}
	snapshotFiles := make([]sourceFile, 0, len(prepared.sourceFiles))
	byPortablePath := make(map[string]sourceFile, len(prepared.sourceFiles))
	for _, source := range prepared.sourceFiles {
		destination := filepath.Join(snapshotRoot, filepath.FromSlash(source.portablePath))
		record, err := copyAndRecord(source.absolutePath, destination, source.portablePath, 0o444)
		if err != nil {
			return cleanUp(fmt.Errorf("snapshot linux-armer source %s: %w", source.portablePath, err))
		}
		if record.SHA256 != source.sha256 || record.Size != source.size {
			return cleanUp(fmt.Errorf("linux-armer source changed while snapshotting: %s", source.absolutePath))
		}
		snapshot := sourceFile{
			absolutePath: destination, portablePath: source.portablePath,
			sha256: record.SHA256, size: record.Size,
		}
		snapshotFiles = append(snapshotFiles, snapshot)
		byPortablePath[snapshot.portablePath] = snapshot
	}
	if err := makeSnapshotReadOnly(snapshotRoot); err != nil {
		return cleanUp(err)
	}
	snapshotLicences := make([]sourceFile, 0, len(prepared.licenceFiles))
	for _, licence := range prepared.licenceFiles {
		snapshot, found := byPortablePath[licence.portablePath]
		if !found {
			return cleanUp(fmt.Errorf("project licence or notice %s is absent from the source snapshot", licence.portablePath))
		}
		snapshotLicences = append(snapshotLicences, snapshot)
	}
	prepared.request.SourceDirectory = snapshotRoot
	prepared.sourceFiles = snapshotFiles
	prepared.licenceFiles = snapshotLicences
	return snapshotRoot, prepared, nil
}

// makeSnapshotReadOnly removes write permission from every private source file
// and directory after copying, walking children before their parents.
func makeSnapshotReadOnly(snapshotRoot string) error {
	var directories []string
	err := filepath.WalkDir(snapshotRoot, func(itemPath string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			directories = append(directories, itemPath)
			return nil
		}
		return os.Chmod(itemPath, 0o444)
	})
	if err != nil {
		return fmt.Errorf("protect private companion source snapshot: %w", err)
	}
	sort.Slice(directories, func(left, right int) bool {
		return len(directories[left]) > len(directories[right])
	})
	for _, directory := range directories {
		if err := os.Chmod(directory, 0o555); err != nil {
			return fmt.Errorf("protect private companion source directory: %w", err)
		}
	}
	return nil
}

// removeSnapshot restores owner permissions on the private read-only snapshot
// before recursively removing its exact generated directory.
func removeSnapshot(snapshotRoot string) error {
	if err := filepath.WalkDir(snapshotRoot, func(itemPath string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return os.Chmod(itemPath, 0o700)
		}
		return os.Chmod(itemPath, 0o600)
	}); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return os.RemoveAll(snapshotRoot)
}

// stage writes every prepared item into temporaryRoot and constructs the exact
// record later embedded in the outer image manifest.
func (b *Builder) stage(ctx context.Context, prepared preparedRequest, temporaryRoot string) (imagecontract.CompanionBundleRecord, error) {
	tool := imagecontract.ToolIdentityRecord{
		Version:   prepared.request.Version,
		Commit:    prepared.request.Commit,
		BuildDate: prepared.request.BuildDate,
	}
	binaryRecord, err := b.stageExecutable(ctx, prepared.request, temporaryRoot)
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	sourceArchiveRecord, err := stageSourceArchive(prepared, temporaryRoot)
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	catalogueRecords, err := stageCatalogues(prepared.request.SourceDirectory, temporaryRoot)
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	licenceRecords, err := stageLicences(prepared.licenceFiles, temporaryRoot)
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	userspaceRecords, err := stageUserspace(prepared.userspaceBundles, temporaryRoot)
	if err != nil {
		return imagecontract.CompanionBundleRecord{}, err
	}
	return imagecontract.CompanionBundleRecord{
		Included:       true,
		Root:           ISOFilesystemRoot,
		Tool:           &tool,
		ProjectLicence: prepared.projectLicence,
		Executable:     &binaryRecord,
		SourceArchive:  &sourceArchiveRecord,
		Catalogues:     catalogueRecords,
		Licences:       licenceRecords,
		Userspace:      userspaceRecords,
	}, nil
}

// stageExecutable cross-builds the CLI with immutable identity flags, checks
// its static AArch64 ELF contract, and returns its artefact record.
func (b *Builder) stageExecutable(ctx context.Context, request BuildRequest, temporaryRoot string) (imagecontract.ExecutableArtifactRecord, error) {
	destination := filepath.Join(temporaryRoot, filepath.FromSlash(executableRelativePath))
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return imagecontract.ExecutableArtifactRecord{}, fmt.Errorf("create companion executable directory: %w", err)
	}
	linkerFlags := strings.Join([]string{
		"-s", "-w", "-buildid=",
		"-X", linkerVersionVariable + "=" + request.Version,
		"-X", linkerCommitVariable + "=" + request.Commit,
		"-X", linkerDateVariable + "=" + request.BuildDate,
	}, " ")
	command := platform.Command{
		Name: "go",
		Args: []string{
			"build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-ldflags", linkerFlags,
			"-o", destination, buildPackage,
		},
		Dir: request.SourceDirectory,
		Env: []string{
			"GOOS=linux", "GOARCH=arm64", "CGO_ENABLED=0",
			"GOFLAGS=", "GOWORK=off", "GOENV=off", "GOTOOLCHAIN=local",
		},
	}
	if err := b.Runner.Run(ctx, command); err != nil {
		return imagecontract.ExecutableArtifactRecord{}, fmt.Errorf("cross-build Linux ARM64 companion CLI: %w", err)
	}
	if err := validateRegularFile(destination, "companion executable"); err != nil {
		return imagecontract.ExecutableArtifactRecord{}, err
	}
	if err := validateAArch64ELF(destination); err != nil {
		return imagecontract.ExecutableArtifactRecord{}, err
	}
	if err := os.Chmod(destination, 0o755); err != nil {
		return imagecontract.ExecutableArtifactRecord{}, fmt.Errorf("set companion executable mode: %w", err)
	}
	artifactRecord, err := recordFile(destination, path.Join(ISOFilesystemRoot, executableRelativePath))
	if err != nil {
		return imagecontract.ExecutableArtifactRecord{}, err
	}
	return imagecontract.ExecutableArtifactRecord{
		Artifact: artifactRecord, OperatingSystem: "linux", Architecture: "arm64",
		Format: "ELF", Mode: executableMode,
	}, nil
}

// stageSourceArchive creates the deterministic gzip-compressed tar archive and
// returns its immutable artefact record.
func stageSourceArchive(prepared preparedRequest, temporaryRoot string) (imagecontract.ArtifactRecord, error) {
	name := fmt.Sprintf("linux-armer_%s_source.tar.gz", prepared.request.Version)
	relative := path.Join("source", name)
	destination := filepath.Join(temporaryRoot, filepath.FromSlash(relative))
	if err := writeSourceArchive(destination, prepared.sourceFiles); err != nil {
		return imagecontract.ArtifactRecord{}, err
	}
	return recordFile(destination, path.Join(ISOFilesystemRoot, relative))
}

// stageCatalogues copies both validated catalogues into their stable portable
// locations and returns records in lexical path order.
func stageCatalogues(sourceRoot, temporaryRoot string) ([]imagecontract.ArtifactRecord, error) {
	names := []string{imageCatalogueName, userspaceCatalogueName}
	records := make([]imagecontract.ArtifactRecord, 0, len(names))
	for _, name := range names {
		relative := path.Join("catalogues", name)
		record, err := copyAndRecord(
			filepath.Join(sourceRoot, name),
			filepath.Join(temporaryRoot, filepath.FromSlash(relative)),
			path.Join(ISOFilesystemRoot, relative),
			0o644,
		)
		if err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	sortArtifactRecords(records)
	return records, nil
}

// stageLicences copies discovered project redistribution and notice documents
// into the companion inventory in lexical path order.
func stageLicences(files []sourceFile, temporaryRoot string) ([]imagecontract.ArtifactRecord, error) {
	records := make([]imagecontract.ArtifactRecord, 0, len(files))
	for _, file := range files {
		relative := path.Join("licences", file.portablePath)
		record, err := copyAndRecord(
			file.absolutePath,
			filepath.Join(temporaryRoot, filepath.FromSlash(relative)),
			path.Join(ISOFilesystemRoot, relative),
			0o644,
		)
		if err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	sortArtifactRecords(records)
	return records, nil
}

// stageUserspace copies portable receipts and verified payload files for every
// redistribution-eligible release into deterministic component order.
func stageUserspace(bundles []preparedUserspaceBundle, temporaryRoot string) ([]imagecontract.OfflineUserspaceRecord, error) {
	records := make([]imagecontract.OfflineUserspaceRecord, 0, len(bundles))
	for _, prepared := range bundles {
		relativeRoot := path.Join("userspace", prepared.bundle.Component, prepared.bundle.Release)
		hostRoot := filepath.Join(temporaryRoot, filepath.FromSlash(relativeRoot))
		if err := os.MkdirAll(hostRoot, 0o755); err != nil {
			return nil, fmt.Errorf("create offline userspace directory: %w", err)
		}
		artifacts := make([]imagecontract.ArtifactRecord, 0, len(prepared.files)+1)
		for _, file := range prepared.files {
			relative := path.Join(relativeRoot, file.Name)
			record, err := copyAndRecord(
				file.Path,
				filepath.Join(hostRoot, file.Name),
				path.Join(ISOFilesystemRoot, relative),
				0o644,
			)
			if err != nil {
				return nil, err
			}
			if record.SHA256 != file.SHA256 || record.Size != file.Size {
				return nil, fmt.Errorf("verified userspace file changed while staging: %s", file.Path)
			}
			artifacts = append(artifacts, record)
		}
		receiptRelative := path.Join(relativeRoot, userspaceReceiptName)
		receiptRecord, err := copyAndRecord(
			prepared.receiptPath,
			filepath.Join(hostRoot, userspaceReceiptName),
			path.Join(ISOFilesystemRoot, receiptRelative),
			0o644,
		)
		if err != nil {
			return nil, err
		}
		stagedReceipt, err := os.ReadFile(filepath.Join(hostRoot, userspaceReceiptName))
		if err != nil {
			return nil, fmt.Errorf("read staged portable userspace receipt: %w", err)
		}
		if !bytes.Equal(stagedReceipt, prepared.receiptContent) {
			return nil, errors.New("portable userspace receipt changed while staging")
		}
		artifacts = append(artifacts, receiptRecord)
		sortArtifactRecords(artifacts)
		records = append(records, imagecontract.OfflineUserspaceRecord{
			Component:      prepared.bundle.Component,
			Release:        prepared.bundle.Release,
			Redistribution: string(prepared.component.Redistribution),
			Root:           path.Join(ISOFilesystemRoot, relativeRoot),
			Artifacts:      artifacts,
		})
	}
	return records, nil
}

// cataloguesEqual compares immutable public catalogue projections so a caller
// cannot authorise bundles with policy from a different source tree.
func cataloguesEqual(left, right *userspacecatalog.Catalog) bool {
	if left == nil || right == nil {
		return left == right
	}
	return left.SchemaVersion == right.SchemaVersion &&
		left.Description == right.Description &&
		reflect.DeepEqual(left.List(), right.List())
}

// sameOrDescendant reports whether candidate is source or is lexically beneath
// source after both have already passed canonical absolute-path checks.
func sameOrDescendant(candidate, source string) bool {
	relative, err := filepath.Rel(source, candidate)
	if err != nil {
		return false
	}
	return relative == "." || relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

// sortArtifactRecords orders artefacts by their portable manifest paths.
func sortArtifactRecords(records []imagecontract.ArtifactRecord) {
	sort.Slice(records, func(left, right int) bool {
		return records[left].Path < records[right].Path
	})
}
