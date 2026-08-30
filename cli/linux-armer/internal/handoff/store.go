package handoff

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
	"path/filepath"
	"sort"
	"strings"
)

const (
	// privateDirectoryMode is required for the store root, entries, staging, and
	// every payload directory.
	privateDirectoryMode fs.FileMode = 0o700
	// privateFileMode is required for manifests and all proprietary or identifying
	// payload files in the private store.
	privateFileMode fs.FileMode = 0o600
)

// ImportResult reports only the content address, private store path, redacted
// contract summary, and whether publication was already complete.
type ImportResult struct {
	// ID is the lowercase SHA-256 of the exact manifest bytes.
	ID string `json:"id"`
	// Path is the resolved private store entry path.
	Path string `json:"path"`
	// Existing reports that an identical, fully revalidated entry already existed.
	Existing bool `json:"existing"`
	// Summary is the deliberately redacted contract view.
	Summary Summary `json:"summary"`
}

// StoredSummary is the read-only, non-sensitive inventory returned by List.
type StoredSummary struct {
	// ID is the lowercase manifest content address.
	ID string `json:"id"`
	// Path is the resolved direct-child store path.
	Path string `json:"path"`
	// Summary is the deliberately redacted contract view.
	Summary Summary `json:"summary"`
}

// importHooks provides synchronous fault points for deterministic mutation and
// cancellation tests without becoming public storage API.
type importHooks struct {
	// afterSourceScan runs after the first complete closed-set snapshot.
	afterSourceScan func() error
	// afterPayloadOpen runs after a no-follow source file is opened and snapshotted.
	afterPayloadOpen func(relativePath string) error
	// beforePublish runs after private staging validation and before final source
	// revalidation and atomic publication.
	beforePublish func() error
}

// entryKind identifies one directory or regular file in a closed set.
type entryKind string

const (
	// entryKindDirectory identifies a directory node.
	entryKindDirectory entryKind = "directory"
	// entryKindFile identifies a regular file node.
	entryKindFile entryKind = "file"
)

// fileSnapshot records enough stable filesystem identity to detect replacement
// or metadata mutation between security-sensitive phases.
type fileSnapshot struct {
	// info retains the platform file identity used by os.SameFile.
	info fs.FileInfo
	// mode records type and permissions at snapshot time.
	mode fs.FileMode
	// size records byte length at snapshot time.
	size int64
	// modificationNanoseconds records the canonical modification timestamp.
	modificationNanoseconds int64
}

// closedEntry records one exact path, kind, and filesystem snapshot.
type closedEntry struct {
	// path is the canonical slash-separated relative path, or dot for the root.
	path string
	// kind distinguishes directories from regular files.
	kind entryKind
	// snapshot binds the entry to its scanned filesystem object.
	snapshot fileSnapshot
}

// closedScan is one complete, case-collision-free directory snapshot.
type closedScan struct {
	// entries maps every exact relative path, including the root dot entry.
	entries map[string]closedEntry
}

// expectedLayout is the complete directory and file allow-list derived from one
// already validated contract.
type expectedLayout struct {
	// directories contains the root and every required payload parent.
	directories map[string]bool
	// files contains the manifest and every required payload path.
	files map[string]bool
}

// storedArtifact records the current digest, size, and mode of one store file
// for published-copy checks and purge planning.
type storedArtifact struct {
	// Path is the canonical entry-relative file path.
	Path string
	// SHA256 is the lowercase digest of the current bytes.
	SHA256 string
	// Size is the current byte length.
	Size int64
	// Mode is the current permission mode.
	Mode fs.FileMode
}

// storedPayloadRecord contains only the identity fields needed to audit one
// declared payload without granting application authority to its contract.
type storedPayloadRecord struct {
	// ID is the stable policy identifier used in redacted errors.
	ID string
	// PayloadPath is the canonical entry-relative file path.
	PayloadPath string
	// SHA256 is the expected lowercase digest of the payload bytes.
	SHA256 string
	// Size is the expected positive payload length.
	Size int64
}

// auditedStoreEntry is the schema-neutral result of a complete private closed-
// set audit and is sufficient only for inventory and deletion.
type auditedStoreEntry struct {
	// summary is the only contract view exposed by public store APIs.
	summary Summary
	// scan is the final closed-set snapshot.
	scan closedScan
	// artifacts holds every verified file in canonical path order.
	artifacts []storedArtifact
}

// validatedStoreEntry is the private result of a complete current-schema audit
// and retains the version 2 contract required by application workflows.
type validatedStoreEntry struct {
	// contract is the strict decoded version 2 private contract.
	contract Contract
	// auditedStoreEntry contains the schema-neutral verified inventory.
	auditedStoreEntry
}

// contextReader stops a streaming read promptly after cancellation.
type contextReader struct {
	// context controls cancellation of the current read.
	context context.Context
	// reader supplies the underlying bytes.
	reader io.Reader
}

// Read implements io.Reader with a cancellation check before every underlying
// read operation.
func (reader contextReader) Read(buffer []byte) (int, error) {
	if err := reader.context.Err(); err != nil {
		return 0, err
	}
	return reader.reader.Read(buffer)
}

// Import verifies and atomically publishes one closed Windows hand-off source
// into a private content-addressed store.
func Import(ctx context.Context, sourceDirectory, storeRoot string) (ImportResult, error) {
	return importWithHooks(ctx, sourceDirectory, storeRoot, importHooks{})
}

// importWithHooks implements Import with deterministic test-only fault points.
func importWithHooks(ctx context.Context, sourceDirectory, storeRoot string, hooks importHooks) (ImportResult, error) {
	if ctx == nil {
		return ImportResult{}, errors.New("import Windows hand-off: context is nil")
	}
	if err := ctx.Err(); err != nil {
		return ImportResult{}, err
	}
	sourceRoot, err := resolveExistingDirectory(sourceDirectory, "Windows hand-off source")
	if err != nil {
		return ImportResult{}, err
	}
	resolvedStoreRoot, storeExists, err := inspectStoreRoot(storeRoot)
	if err != nil {
		return ImportResult{}, err
	}
	if pathsOverlap(sourceRoot, resolvedStoreRoot) {
		return ImportResult{}, errors.New("Windows hand-off source and private store must not overlap")
	}
	if !storeExists {
		if err := createPrivateStoreRoot(resolvedStoreRoot); err != nil {
			return ImportResult{}, err
		}
	}

	manifestBytes, manifestSnapshot, err := readManifest(ctx, sourceRoot)
	if err != nil {
		return ImportResult{}, err
	}
	contract, err := Decode(bytes.NewReader(manifestBytes))
	if err != nil {
		return ImportResult{}, err
	}
	identifier := digestBytes(manifestBytes)
	layout := buildExpectedLayout(contract)
	initialScan, err := scanClosedDirectory(ctx, sourceRoot, layout, false)
	if err != nil {
		return ImportResult{}, err
	}
	if err := requireSameSnapshot(manifestSnapshot, initialScan.entries[ManifestFilename].snapshot, "source manifest changed before closed-set scan"); err != nil {
		return ImportResult{}, err
	}
	if hooks.afterSourceScan != nil {
		if err := hooks.afterSourceScan(); err != nil {
			return ImportResult{}, err
		}
	}
	if err := verifySourcePayloads(ctx, sourceRoot, contract, initialScan, hooks); err != nil {
		return ImportResult{}, err
	}
	verifiedScan, err := scanClosedDirectory(ctx, sourceRoot, layout, false)
	if err != nil {
		return ImportResult{}, err
	}
	if err := compareClosedScans(initialScan, verifiedScan, "source changed during verification"); err != nil {
		return ImportResult{}, err
	}

	finalPath, err := directStoreChild(resolvedStoreRoot, identifier)
	if err != nil {
		return ImportResult{}, err
	}
	if _, err := os.Lstat(finalPath); err == nil {
		validated, validateErr := validateStoredEntry(ctx, finalPath, identifier)
		if validateErr != nil {
			return ImportResult{}, fmt.Errorf("existing Windows hand-off store entry is corrupt or conflicting: %w", validateErr)
		}
		return ImportResult{ID: identifier, Path: finalPath, Existing: true, Summary: validated.summary}, nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return ImportResult{}, fmt.Errorf("inspect Windows hand-off store destination: %w", err)
	}

	staging, err := os.MkdirTemp(resolvedStoreRoot, ".import-"+identifier[:12]+"-")
	if err != nil {
		return ImportResult{}, fmt.Errorf("create private Windows hand-off staging directory: %w", err)
	}
	if err := os.Chmod(staging, privateDirectoryMode); err != nil {
		_ = os.RemoveAll(staging)
		return ImportResult{}, fmt.Errorf("protect Windows hand-off staging directory: %w", err)
	}
	stagingActive := true
	defer func() {
		if stagingActive {
			_ = os.RemoveAll(staging)
		}
	}()

	if err := createStagingLayout(staging, layout); err != nil {
		return ImportResult{}, err
	}
	if err := writePrivateFile(filepath.Join(staging, ManifestFilename), manifestBytes); err != nil {
		return ImportResult{}, err
	}
	if err := copySourcePayloads(ctx, sourceRoot, staging, contract, initialScan, hooks); err != nil {
		return ImportResult{}, err
	}
	if err := syncTreeDirectories(staging, layout); err != nil {
		return ImportResult{}, err
	}
	if _, err := validateStoredEntry(ctx, staging, identifier); err != nil {
		return ImportResult{}, fmt.Errorf("validate staged Windows hand-off: %w", err)
	}
	if hooks.beforePublish != nil {
		if err := hooks.beforePublish(); err != nil {
			return ImportResult{}, err
		}
	}
	if err := ctx.Err(); err != nil {
		return ImportResult{}, err
	}
	finalSourceScan, err := scanClosedDirectory(ctx, sourceRoot, layout, false)
	if err != nil {
		return ImportResult{}, err
	}
	if err := compareClosedScans(initialScan, finalSourceScan, "source changed before publication"); err != nil {
		return ImportResult{}, err
	}

	if err := publishNoReplace(staging, finalPath); err != nil {
		if _, inspectErr := os.Lstat(finalPath); inspectErr == nil {
			validated, validateErr := validateStoredEntry(ctx, finalPath, identifier)
			if validateErr != nil {
				return ImportResult{}, fmt.Errorf("concurrent Windows hand-off store entry is corrupt or conflicting: %w", validateErr)
			}
			return ImportResult{ID: identifier, Path: finalPath, Existing: true, Summary: validated.summary}, nil
		}
		return ImportResult{}, fmt.Errorf("publish Windows hand-off without replacement: %w", err)
	}
	stagingActive = false
	if err := syncDirectory(resolvedStoreRoot); err != nil {
		return ImportResult{}, err
	}
	validated, err := validateStoredEntry(ctx, finalPath, identifier)
	if err != nil {
		return ImportResult{}, fmt.Errorf("rehash published Windows hand-off: %w", err)
	}
	return ImportResult{ID: identifier, Path: finalPath, Existing: false, Summary: validated.summary}, nil
}

// List validates every current or exact retained version 1 direct store entry
// and returns only redacted summaries in content-address order.
func List(ctx context.Context, storeRoot string) ([]StoredSummary, error) {
	if ctx == nil {
		return nil, errors.New("list Windows hand-offs: context is nil")
	}
	resolvedStoreRoot, err := resolveStoreRoot(storeRoot)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(resolvedStoreRoot)
	if err != nil {
		return nil, fmt.Errorf("read Windows hand-off store: %w", err)
	}
	summaries := make([]StoredSummary, 0, len(entries))
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		identifier := entry.Name()
		if err := validateSHA256(identifier, "Windows hand-off store ID"); err != nil {
			return nil, fmt.Errorf("Windows hand-off store contains unexpected entry %q", identifier)
		}
		entryPath, err := directStoreChild(resolvedStoreRoot, identifier)
		if err != nil {
			return nil, err
		}
		validated, err := validateStoredEntryForMaintenance(ctx, entryPath, identifier)
		if err != nil {
			return nil, fmt.Errorf("validate stored Windows hand-off %s: %w", identifier, err)
		}
		summaries = append(summaries, StoredSummary{ID: identifier, Path: entryPath, Summary: validated.summary})
	}
	sort.Slice(summaries, func(left, right int) bool {
		return summaries[left].ID < summaries[right].ID
	})
	return summaries, nil
}

// readManifest reads the exact bounded manifest bytes through a component-wise
// no-follow descriptor and rejects mutation during the read.
func readManifest(ctx context.Context, root string) ([]byte, fileSnapshot, error) {
	file, err := openRegularNoFollow(root, ManifestFilename)
	if err != nil {
		return nil, fileSnapshot{}, fmt.Errorf("open Windows hand-off manifest: %w", err)
	}
	beforeInfo, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, fileSnapshot{}, fmt.Errorf("inspect Windows hand-off manifest: %w", err)
	}
	if !beforeInfo.Mode().IsRegular() {
		_ = file.Close()
		return nil, fileSnapshot{}, errors.New("Windows hand-off manifest is not a regular file")
	}
	before := snapshotFileInfo(beforeInfo)
	data, readErr := io.ReadAll(io.LimitReader(contextReader{context: ctx, reader: file}, MaximumDocumentSize+1))
	afterInfo, statErr := file.Stat()
	closeErr := file.Close()
	if readErr != nil || statErr != nil || closeErr != nil {
		return nil, fileSnapshot{}, fmt.Errorf("read Windows hand-off manifest: %w", errors.Join(readErr, statErr, closeErr))
	}
	if len(data) > MaximumDocumentSize {
		return nil, fileSnapshot{}, fmt.Errorf("Windows hand-off exceeds %d bytes", MaximumDocumentSize)
	}
	if err := requireSameSnapshot(before, snapshotFileInfo(afterInfo), "Windows hand-off manifest changed during read"); err != nil {
		return nil, fileSnapshot{}, err
	}
	return data, before, nil
}

// buildExpectedLayout derives the complete file and parent-directory allow-list
// from a semantically validated contract.
func buildExpectedLayout(contract Contract) expectedLayout {
	return buildExpectedPayloadLayout(storedPayloads(contract.PlatformFirmware.Files))
}

// buildExpectedPayloadLayout derives the complete private file and parent-
// directory allow-list from already validated payload records.
func buildExpectedPayloadLayout(payloads []storedPayloadRecord) expectedLayout {
	layout := expectedLayout{
		directories: map[string]bool{".": true},
		files:       map[string]bool{ManifestFilename: true},
	}
	for _, record := range payloads {
		layout.files[record.PayloadPath] = true
		for parent := filepath.ToSlash(filepath.Dir(record.PayloadPath)); parent != "."; parent = filepath.ToSlash(filepath.Dir(parent)) {
			layout.directories[parent] = true
		}
	}
	return layout
}

// storedPayloads projects current-schema firmware records into the smaller
// schema-neutral identity needed by private-store auditing.
func storedPayloads(records []FirmwareFileRecord) []storedPayloadRecord {
	payloads := make([]storedPayloadRecord, 0, len(records))
	for _, record := range records {
		payloads = append(payloads, storedPayloadRecord{
			ID: record.ID, PayloadPath: record.PayloadPath, SHA256: record.SHA256, Size: record.Size,
		})
	}
	return payloads
}

// scanClosedDirectory rejects every undeclared, missing, linked, special,
// alternate-separated, case-colliding, or incorrectly protected entry.
func scanClosedDirectory(ctx context.Context, root string, layout expectedLayout, requirePrivateModes bool) (closedScan, error) {
	scan := closedScan{entries: make(map[string]closedEntry)}
	caseFolded := make(map[string]string)
	err := filepath.WalkDir(root, func(itemPath string, directoryEntry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		relative, err := filepath.Rel(root, itemPath)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if relative != "." {
			if strings.Contains(directoryEntry.Name(), "\\") {
				return fmt.Errorf("Windows hand-off path %q uses an alternate separator", relative)
			}
			if err := validatePortablePath(relative, "Windows hand-off path"); err != nil {
				return err
			}
		}
		if err := recordCaseDistinctPath(caseFolded, relative); err != nil {
			return err
		}

		info, err := os.Lstat(itemPath)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("Windows hand-off path %q is a symbolic link", relative)
		}
		kind := entryKindFile
		if info.IsDir() {
			kind = entryKindDirectory
			if !layout.directories[relative] {
				return fmt.Errorf("Windows hand-off contains unexpected directory %q", relative)
			}
			if requirePrivateModes && info.Mode().Perm() != privateDirectoryMode {
				return fmt.Errorf("private Windows hand-off directory %q must have mode 0700", relative)
			}
		} else if info.Mode().IsRegular() {
			if _, expected := layout.files[relative]; !expected {
				return fmt.Errorf("Windows hand-off contains unexpected file %q", relative)
			}
			if requirePrivateModes && info.Mode().Perm() != privateFileMode {
				return fmt.Errorf("private Windows hand-off file %q must have mode 0600", relative)
			}
		} else {
			return fmt.Errorf("Windows hand-off path %q is not a directory or regular file", relative)
		}
		scan.entries[relative] = closedEntry{path: relative, kind: kind, snapshot: snapshotFileInfo(info)}
		return nil
	})
	if err != nil {
		return closedScan{}, fmt.Errorf("scan closed Windows hand-off directory: %w", err)
	}
	for directory := range layout.directories {
		entry, found := scan.entries[directory]
		if !found || entry.kind != entryKindDirectory {
			return closedScan{}, fmt.Errorf("Windows hand-off required directory %q is missing", directory)
		}
	}
	for filePath := range layout.files {
		entry, found := scan.entries[filePath]
		if !found || entry.kind != entryKindFile {
			return closedScan{}, fmt.Errorf("Windows hand-off required file %q is missing", filePath)
		}
	}
	return scan, nil
}

// recordCaseDistinctPath adds one canonical relative path while rejecting a
// differently cased spelling already present in the same closed set.
func recordCaseDistinctPath(seen map[string]string, relativePath string) error {
	folded := strings.ToLower(relativePath)
	if previous, duplicate := seen[folded]; duplicate && previous != relativePath {
		return fmt.Errorf("Windows hand-off paths %q and %q collide without case", previous, relativePath)
	}
	seen[folded] = relativePath
	return nil
}

// verifySourcePayloads hashes every declared source payload through no-follow
// descriptors and checks it against the manifest identity.
func verifySourcePayloads(ctx context.Context, sourceRoot string, contract Contract, scan closedScan, hooks importHooks) error {
	for _, record := range contract.PlatformFirmware.Files {
		if _, err := inspectVerifiedFile(ctx, sourceRoot, record, scan.entries[record.PayloadPath].snapshot, hooks); err != nil {
			return err
		}
	}
	return nil
}

// inspectVerifiedFile checks one no-follow regular source file, optional fault
// hook, fixed byte length, digest, and before/after filesystem identity.
func inspectVerifiedFile(ctx context.Context, sourceRoot string, record FirmwareFileRecord, expected fileSnapshot, hooks importHooks) (storedArtifact, error) {
	return inspectVerifiedPayload(ctx, sourceRoot, storedPayloadRecord{
		ID: record.ID, PayloadPath: record.PayloadPath, SHA256: record.SHA256, Size: record.Size,
	}, expected, hooks)
}

// inspectVerifiedPayload checks one schema-neutral payload through a no-follow
// descriptor, fixed identity, optional fault hook, and before/after snapshots.
func inspectVerifiedPayload(ctx context.Context, sourceRoot string, record storedPayloadRecord, expected fileSnapshot, hooks importHooks) (storedArtifact, error) {
	file, err := openRegularNoFollow(sourceRoot, record.PayloadPath)
	if err != nil {
		return storedArtifact{}, fmt.Errorf("open hand-off payload %s: %w", record.ID, err)
	}
	beforeInfo, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return storedArtifact{}, fmt.Errorf("inspect hand-off payload %s: %w", record.ID, err)
	}
	before := snapshotFileInfo(beforeInfo)
	if !beforeInfo.Mode().IsRegular() {
		_ = file.Close()
		return storedArtifact{}, fmt.Errorf("hand-off payload %s is not a regular file", record.ID)
	}
	if err := requireSameSnapshot(expected, before, "hand-off payload "+record.ID+" changed before read"); err != nil {
		_ = file.Close()
		return storedArtifact{}, err
	}
	if hooks.afterPayloadOpen != nil {
		if err := hooks.afterPayloadOpen(record.PayloadPath); err != nil {
			_ = file.Close()
			return storedArtifact{}, err
		}
	}
	digest := sha256.New()
	written, readErr := io.Copy(digest, io.LimitReader(contextReader{context: ctx, reader: file}, record.Size+1))
	afterInfo, statErr := file.Stat()
	closeErr := file.Close()
	if readErr != nil || statErr != nil || closeErr != nil {
		return storedArtifact{}, fmt.Errorf("read hand-off payload %s: %w", record.ID, errors.Join(readErr, statErr, closeErr))
	}
	if err := requireSameSnapshot(before, snapshotFileInfo(afterInfo), "hand-off payload "+record.ID+" changed during read"); err != nil {
		return storedArtifact{}, err
	}
	actualDigest := hex.EncodeToString(digest.Sum(nil))
	if written != record.Size {
		return storedArtifact{}, fmt.Errorf("hand-off payload %s size does not match manifest", record.ID)
	}
	if actualDigest != record.SHA256 {
		return storedArtifact{}, fmt.Errorf("hand-off payload %s digest does not match manifest", record.ID)
	}
	return storedArtifact{Path: record.PayloadPath, SHA256: actualDigest, Size: written, Mode: beforeInfo.Mode().Perm()}, nil
}

// createStagingLayout creates every declared payload parent with private mode in
// deterministic shallowest-first order.
func createStagingLayout(staging string, layout expectedLayout) error {
	directories := make([]string, 0, len(layout.directories)-1)
	for directory := range layout.directories {
		if directory != "." {
			directories = append(directories, directory)
		}
	}
	sort.Slice(directories, func(left, right int) bool {
		leftDepth := strings.Count(directories[left], "/")
		rightDepth := strings.Count(directories[right], "/")
		if leftDepth != rightDepth {
			return leftDepth < rightDepth
		}
		return directories[left] < directories[right]
	})
	for _, directory := range directories {
		path := filepath.Join(staging, filepath.FromSlash(directory))
		if err := os.Mkdir(path, privateDirectoryMode); err != nil {
			return fmt.Errorf("create private Windows hand-off directory %s: %w", directory, err)
		}
		if err := os.Chmod(path, privateDirectoryMode); err != nil {
			return fmt.Errorf("protect private Windows hand-off directory %s: %w", directory, err)
		}
	}
	return nil
}

// writePrivateFile creates, writes, flushes, and closes one new mode-0600 file.
func writePrivateFile(destination string, data []byte) error {
	file, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, privateFileMode)
	if err != nil {
		return fmt.Errorf("create private Windows hand-off file: %w", err)
	}
	if err := file.Chmod(privateFileMode); err != nil {
		_ = file.Close()
		return fmt.Errorf("protect private Windows hand-off file: %w", err)
	}
	_, writeErr := file.Write(data)
	syncErr := file.Sync()
	closeErr := file.Close()
	if writeErr != nil || syncErr != nil || closeErr != nil {
		return fmt.Errorf("write private Windows hand-off file: %w", errors.Join(writeErr, syncErr, closeErr))
	}
	return nil
}

// copySourcePayloads copies every verified payload into private staging while
// rechecking its source snapshot, bytes, and digest.
func copySourcePayloads(ctx context.Context, sourceRoot, staging string, contract Contract, scan closedScan, hooks importHooks) error {
	for _, record := range contract.PlatformFirmware.Files {
		if err := copyVerifiedPayload(ctx, sourceRoot, staging, record, scan.entries[record.PayloadPath].snapshot, hooks); err != nil {
			return err
		}
	}
	return nil
}

// copyVerifiedPayload streams one no-follow source into a new private file,
// flushes it, and rejects any identity, size, or digest drift.
func copyVerifiedPayload(ctx context.Context, sourceRoot, staging string, record FirmwareFileRecord, expected fileSnapshot, hooks importHooks) error {
	source, err := openRegularNoFollow(sourceRoot, record.PayloadPath)
	if err != nil {
		return fmt.Errorf("open hand-off payload %s for copy: %w", record.ID, err)
	}
	beforeInfo, err := source.Stat()
	if err != nil {
		_ = source.Close()
		return fmt.Errorf("inspect hand-off payload %s for copy: %w", record.ID, err)
	}
	before := snapshotFileInfo(beforeInfo)
	if !beforeInfo.Mode().IsRegular() {
		_ = source.Close()
		return fmt.Errorf("hand-off payload %s is not a regular file", record.ID)
	}
	if err := requireSameSnapshot(expected, before, "hand-off payload "+record.ID+" changed before copy"); err != nil {
		_ = source.Close()
		return err
	}
	if hooks.afterPayloadOpen != nil {
		if err := hooks.afterPayloadOpen(record.PayloadPath); err != nil {
			_ = source.Close()
			return err
		}
	}
	destinationPath := filepath.Join(staging, filepath.FromSlash(record.PayloadPath))
	destination, err := os.OpenFile(destinationPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, privateFileMode)
	if err != nil {
		_ = source.Close()
		return fmt.Errorf("create private hand-off payload %s: %w", record.ID, err)
	}
	if err := destination.Chmod(privateFileMode); err != nil {
		_ = source.Close()
		_ = destination.Close()
		return fmt.Errorf("protect private hand-off payload %s: %w", record.ID, err)
	}
	digest := sha256.New()
	reader := io.LimitReader(contextReader{context: ctx, reader: source}, record.Size+1)
	written, copyErr := io.Copy(io.MultiWriter(destination, digest), reader)
	sourceAfterInfo, sourceStatErr := source.Stat()
	sourceCloseErr := source.Close()
	destinationSyncErr := destination.Sync()
	destinationCloseErr := destination.Close()
	if copyErr != nil || sourceStatErr != nil || sourceCloseErr != nil || destinationSyncErr != nil || destinationCloseErr != nil {
		return fmt.Errorf("copy private hand-off payload %s: %w", record.ID,
			errors.Join(copyErr, sourceStatErr, sourceCloseErr, destinationSyncErr, destinationCloseErr))
	}
	if err := requireSameSnapshot(before, snapshotFileInfo(sourceAfterInfo), "hand-off payload "+record.ID+" changed during copy"); err != nil {
		return err
	}
	if written != record.Size {
		return fmt.Errorf("hand-off payload %s size changed during copy", record.ID)
	}
	if actual := hex.EncodeToString(digest.Sum(nil)); actual != record.SHA256 {
		return fmt.Errorf("hand-off payload %s digest changed during copy", record.ID)
	}
	return nil
}

// validateStoredEntry re-decodes the exact stored manifest, enforces its closed
// private layout, rehashes every payload, and detects concurrent drift.
func validateStoredEntry(ctx context.Context, entryPath, expectedID string) (validatedStoreEntry, error) {
	if err := ctx.Err(); err != nil {
		return validatedStoreEntry{}, err
	}
	manifestBytes, manifestSnapshot, err := readManifest(ctx, entryPath)
	if err != nil {
		return validatedStoreEntry{}, err
	}
	if digestBytes(manifestBytes) != expectedID {
		return validatedStoreEntry{}, errors.New("stored manifest digest does not match store ID")
	}
	contract, err := Decode(bytes.NewReader(manifestBytes))
	if err != nil {
		return validatedStoreEntry{}, err
	}
	audited, err := auditStoredEntry(ctx, entryPath, expectedID, manifestBytes, manifestSnapshot, contract.Summary(), storedPayloads(contract.PlatformFirmware.Files))
	if err != nil {
		return validatedStoreEntry{}, err
	}
	return validatedStoreEntry{contract: contract, auditedStoreEntry: audited}, nil
}

// auditStoredEntry enforces the private closed layout, rehashes every declared
// payload, and detects concurrent drift without retaining executable contract
// authority.
func auditStoredEntry(
	ctx context.Context,
	entryPath string,
	expectedID string,
	manifestBytes []byte,
	manifestSnapshot fileSnapshot,
	summary Summary,
	payloads []storedPayloadRecord,
) (auditedStoreEntry, error) {
	layout := buildExpectedPayloadLayout(payloads)
	initialScan, err := scanClosedDirectory(ctx, entryPath, layout, true)
	if err != nil {
		return auditedStoreEntry{}, err
	}
	if err := requireSameSnapshot(manifestSnapshot, initialScan.entries[ManifestFilename].snapshot, "stored manifest changed before closed-set scan"); err != nil {
		return auditedStoreEntry{}, err
	}
	artifacts := []storedArtifact{{
		Path: ManifestFilename, SHA256: expectedID, Size: int64(len(manifestBytes)), Mode: privateFileMode,
	}}
	for _, record := range payloads {
		artifact, err := inspectVerifiedPayload(ctx, entryPath, record, initialScan.entries[record.PayloadPath].snapshot, importHooks{})
		if err != nil {
			return auditedStoreEntry{}, err
		}
		if artifact.Mode != privateFileMode {
			return auditedStoreEntry{}, fmt.Errorf("private Windows hand-off file %q must have mode 0600", artifact.Path)
		}
		artifacts = append(artifacts, artifact)
	}
	finalScan, err := scanClosedDirectory(ctx, entryPath, layout, true)
	if err != nil {
		return auditedStoreEntry{}, err
	}
	if err := compareClosedScans(initialScan, finalScan, "stored entry changed during validation"); err != nil {
		return auditedStoreEntry{}, err
	}
	sort.Slice(artifacts, func(left, right int) bool {
		return artifacts[left].Path < artifacts[right].Path
	})
	return auditedStoreEntry{summary: summary, scan: finalScan, artifacts: artifacts}, nil
}

// snapshotFileInfo converts a filesystem observation into a comparable security
// snapshot.
func snapshotFileInfo(info fs.FileInfo) fileSnapshot {
	return fileSnapshot{
		info: info, mode: info.Mode(), size: info.Size(), modificationNanoseconds: info.ModTime().UnixNano(),
	}
}

// requireSameSnapshot rejects replacement or relevant metadata mutation between
// two observations without reporting private content.
func requireSameSnapshot(expected, actual fileSnapshot, message string) error {
	if expected.info == nil || actual.info == nil || !os.SameFile(expected.info, actual.info) ||
		expected.mode != actual.mode || expected.size != actual.size ||
		expected.modificationNanoseconds != actual.modificationNanoseconds {
		return errors.New(message)
	}
	return nil
}

// compareClosedScans rejects any path, kind, identity, mode, size, or timestamp
// drift between two complete snapshots.
func compareClosedScans(expected, actual closedScan, message string) error {
	if len(expected.entries) != len(actual.entries) {
		return errors.New(message)
	}
	for path, expectedEntry := range expected.entries {
		actualEntry, found := actual.entries[path]
		if !found || expectedEntry.kind != actualEntry.kind {
			return errors.New(message)
		}
		if err := requireSameSnapshot(expectedEntry.snapshot, actualEntry.snapshot, message); err != nil {
			return err
		}
	}
	return nil
}

// digestBytes returns the lowercase SHA-256 identity of exact in-memory bytes.
func digestBytes(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

// syncTreeDirectories flushes every staging directory deepest-first, including
// the staging root.
func syncTreeDirectories(root string, layout expectedLayout) error {
	directories := make([]string, 0, len(layout.directories))
	for directory := range layout.directories {
		directories = append(directories, directory)
	}
	sort.Slice(directories, func(left, right int) bool {
		leftDepth := strings.Count(directories[left], "/")
		rightDepth := strings.Count(directories[right], "/")
		if leftDepth != rightDepth {
			return leftDepth > rightDepth
		}
		return directories[left] > directories[right]
	})
	for _, directory := range directories {
		path := root
		if directory != "." {
			path = filepath.Join(root, filepath.FromSlash(directory))
		}
		if err := syncDirectory(path); err != nil {
			return err
		}
	}
	return nil
}

// syncDirectory flushes one directory's metadata before or after publication.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open directory for sync: %w", err)
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	if syncErr != nil || closeErr != nil {
		return fmt.Errorf("sync directory: %w", errors.Join(syncErr, closeErr))
	}
	return nil
}

// resolveExistingDirectory returns an absolute physical directory path while
// rejecting a symbolic-link final component.
func resolveExistingDirectory(value, label string) (string, error) {
	if strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("%s is required", label)
	}
	absolute, err := filepath.Abs(value)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", label, err)
	}
	absolute = filepath.Clean(absolute)
	info, err := os.Lstat(absolute)
	if err != nil {
		return "", fmt.Errorf("inspect %s: %w", label, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("%s must be a non-symlink directory", label)
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", fmt.Errorf("resolve physical %s: %w", label, err)
	}
	resolved, err = filepath.Abs(resolved)
	if err != nil {
		return "", fmt.Errorf("resolve absolute %s: %w", label, err)
	}
	return filepath.Clean(resolved), nil
}

// inspectStoreRoot resolves a present private store or its physical prospective
// path without creating it, and enforces mode 0700 when it already exists.
func inspectStoreRoot(value string) (string, bool, error) {
	if strings.TrimSpace(value) == "" {
		return "", false, errors.New("Windows hand-off store root is required")
	}
	absolute, err := filepath.Abs(value)
	if err != nil {
		return "", false, fmt.Errorf("resolve Windows hand-off store root: %w", err)
	}
	absolute = filepath.Clean(absolute)
	info, err := os.Lstat(absolute)
	if errors.Is(err, fs.ErrNotExist) {
		parent, parentErr := resolveExistingDirectory(filepath.Dir(absolute), "Windows hand-off store parent")
		if parentErr != nil {
			return "", false, parentErr
		}
		return filepath.Join(parent, filepath.Base(absolute)), false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("inspect Windows hand-off store root: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", false, errors.New("Windows hand-off store root must be a non-symlink directory")
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", false, fmt.Errorf("resolve physical Windows hand-off store root: %w", err)
	}
	resolved = filepath.Clean(resolved)
	resolvedInfo, err := os.Lstat(resolved)
	if err != nil {
		return "", false, fmt.Errorf("inspect resolved Windows hand-off store root: %w", err)
	}
	if resolvedInfo.Mode().Perm() != privateDirectoryMode {
		return "", false, errors.New("Windows hand-off store root must have mode 0700")
	}
	return resolved, true, nil
}

// createPrivateStoreRoot creates one already resolved prospective store root,
// accepts a concurrent creator, and verifies the final private directory.
func createPrivateStoreRoot(resolved string) error {
	created := false
	if err := os.Mkdir(resolved, privateDirectoryMode); err == nil {
		created = true
	} else if !errors.Is(err, fs.ErrExist) {
		return fmt.Errorf("create Windows hand-off store root: %w", err)
	}
	if created {
		if err := os.Chmod(resolved, privateDirectoryMode); err != nil {
			return fmt.Errorf("protect Windows hand-off store root: %w", err)
		}
	}
	inspected, exists, err := inspectStoreRoot(resolved)
	if err != nil {
		return err
	}
	if !exists || inspected != resolved {
		return errors.New("created Windows hand-off store root did not retain its resolved identity")
	}
	return syncDirectory(filepath.Dir(resolved))
}

// resolveStoreRoot resolves an existing mode-0700 private store root without
// accepting a symbolic-link final component.
func resolveStoreRoot(value string) (string, error) {
	resolved, exists, err := inspectStoreRoot(value)
	if err != nil {
		return "", err
	}
	if exists {
		return resolved, nil
	}
	return "", fmt.Errorf("inspect Windows hand-off store root: %w", fs.ErrNotExist)
}

// directStoreChild returns one canonical content-addressed child and rejects any
// value that could select the root, a sibling, or a descendant path.
func directStoreChild(storeRoot, identifier string) (string, error) {
	if err := validateSHA256(identifier, "Windows hand-off store ID"); err != nil {
		return "", err
	}
	child := filepath.Join(storeRoot, identifier)
	if filepath.Dir(child) != storeRoot || filepath.Base(child) != identifier {
		return "", errors.New("Windows hand-off store entry must be a direct child")
	}
	return child, nil
}

// pathsOverlap reports whether either resolved path contains the other.
func pathsOverlap(left, right string) bool {
	return pathContains(left, right) || pathContains(right, left)
}

// pathContains reports whether candidate is the same path as root or lies
// beneath it without using a string-prefix comparison.
func pathContains(root, candidate string) bool {
	relative, err := filepath.Rel(root, candidate)
	if err != nil {
		return false
	}
	return relative == "." || relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}
