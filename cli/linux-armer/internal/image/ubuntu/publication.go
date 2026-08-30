package ubuntu

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

// publicationStagingAttempts bounds collisions while allocating a random,
// descriptor-relative staging basename.
const publicationStagingAttempts = 128

// publicationIdentity records the exact digest and byte length required at a
// staged or published path.
type publicationIdentity struct {
	// digest is the canonical lowercase SHA-256 digest.
	digest string
	// size is the exact byte length.
	size int64
}

// stagedPublicationFile retains the descriptor and identity of one staging
// object until the complete publication set has been committed.
type stagedPublicationFile struct {
	// name is the random staging basename relative to the anchored directory.
	name string
	// path is the diagnostic absolute staging path.
	path string
	// file pins the exclusively created filesystem object.
	file *os.File
	// info identifies the exclusively created filesystem object.
	info os.FileInfo
	// identity records the complete staged bytes.
	identity publicationIdentity
}

// noReplacePublisher atomically moves one staging entry only when its final
// destination does not exist. Both names are relative to directory.
type noReplacePublisher func(directory *os.File, source, destination string) error

// identifyPublicationBytes returns the SHA-256 digest and length of an in-memory
// publication payload.
func identifyPublicationBytes(data []byte) publicationIdentity {
	digest := sha256.Sum256(data)
	return publicationIdentity{digest: hex.EncodeToString(digest[:]), size: int64(len(data))}
}

// publishImageOutputs durably stages and exclusively publishes one exact
// manifest, journal, and ISO set. The ISO is published last as the commit marker.
func publishImageOutputs(
	sourceISO string,
	destinationISO string,
	manifestBytes []byte,
	journalBytes []byte,
	expectedISO publicationIdentity,
	expectedManifest publicationIdentity,
	expectedJournal publicationIdentity,
	publisher noReplacePublisher,
) (manifestPath string, journalPath string, returnErr error) {
	if publisher == nil {
		publisher = publishOutputNoReplace
	}
	if !expectedISO.valid() || !expectedManifest.valid() || !expectedJournal.valid() {
		return "", "", errors.New("publication identities must contain a canonical SHA-256 digest and positive byte length")
	}
	if identifyPublicationBytes(manifestBytes) != expectedManifest {
		return "", "", errors.New("manifest publication bytes differ from their expected identity")
	}
	if identifyPublicationBytes(journalBytes) != expectedJournal {
		return "", "", errors.New("journal publication bytes differ from their expected identity")
	}

	destinationISO, err := filepath.Abs(destinationISO)
	if err != nil {
		return "", "", fmt.Errorf("resolve image publication path: %w", err)
	}
	destinationISO = filepath.Clean(destinationISO)
	manifestPath = destinationISO + ".manifest.json"
	journalPath = destinationISO + ".journal.json"
	parent := filepath.Dir(destinationISO)
	directory, directoryInfo, err := openPublicationDirectory(parent)
	if err != nil {
		return "", "", fmt.Errorf("open image publication directory: %w", err)
	}
	defer func() {
		if closeErr := directory.Close(); closeErr != nil {
			returnErr = errors.Join(returnErr, fmt.Errorf("close image publication directory: %w", closeErr))
		}
	}()

	isoName := filepath.Base(destinationISO)
	manifestName := filepath.Base(manifestPath)
	journalName := filepath.Base(journalPath)
	for _, destination := range []struct {
		name  string
		label string
	}{
		{name: isoName, label: "output ISO"},
		{name: manifestName, label: "manifest sidecar"},
		{name: journalName, label: "execution journal"},
	} {
		if err := requireAbsentPublicationEntry(directory, destination.name, destination.label); err != nil {
			return "", "", err
		}
	}

	base := filepath.Base(destinationISO)
	stagedISO, err := stagePublicationSource(sourceISO, directory, "."+base+".image-", expectedISO)
	if err != nil {
		return "", "", fmt.Errorf("stage output ISO for publication: %w", err)
	}
	stagedFiles := []*stagedPublicationFile{&stagedISO}
	defer func() {
		if closeErr := closeStagedPublicationFiles(stagedFiles); closeErr != nil {
			returnErr = errors.Join(returnErr, closeErr)
		}
	}()

	stagedManifest, err := stagePublicationBytes(manifestBytes, directory, "."+base+".manifest-", expectedManifest)
	if err != nil {
		return "", "", errors.Join(
			fmt.Errorf("stage manifest sidecar for publication: %w", err),
			publicationResidueError(parent, stagedFiles),
		)
	}
	stagedFiles = append(stagedFiles, &stagedManifest)

	stagedJournal, err := stagePublicationBytes(journalBytes, directory, "."+base+".journal-", expectedJournal)
	if err != nil {
		return "", "", errors.Join(
			fmt.Errorf("stage execution journal for publication: %w", err),
			publicationResidueError(parent, stagedFiles),
		)
	}
	stagedFiles = append(stagedFiles, &stagedJournal)

	if err := syncPublicationDirectory(directory); err != nil {
		return "", "", errors.Join(
			fmt.Errorf("sync staged image publication outputs: %w", err),
			publicationResidueError(parent, stagedFiles),
		)
	}
	for _, destination := range []struct {
		name  string
		label string
	}{
		{name: isoName, label: "output ISO"},
		{name: manifestName, label: "manifest sidecar"},
		{name: journalName, label: "execution journal"},
	} {
		if err := requireAbsentPublicationEntry(directory, destination.name, destination.label); err != nil {
			return "", "", errors.Join(
				fmt.Errorf("destination changed before image publication: %w", err),
				publicationResidueError(parent, stagedFiles),
			)
		}
	}

	// Metadata is made durable first. The ISO is the natural commit marker: an
	// interrupted publication never exposes a usable ISO without its evidence.
	publicationOrder := []struct {
		staged      stagedPublicationFile
		destination string
		label       string
	}{
		{staged: stagedManifest, destination: manifestName, label: "manifest sidecar"},
		{staged: stagedJournal, destination: journalName, label: "execution journal"},
		{staged: stagedISO, destination: isoName, label: "output ISO"},
	}
	for _, output := range publicationOrder {
		if err := publishAndVerifyOutput(directory, output.staged, output.destination, output.label, publisher); err != nil {
			return "", "", errors.Join(err, publicationResidueError(parent, stagedFiles))
		}
		if err := syncPublicationDirectory(directory); err != nil {
			return "", "", errors.Join(
				fmt.Errorf("sync published %s: %w", output.label, err),
				publicationResidueError(parent, stagedFiles),
			)
		}
		if err := verifyPublicationEntry(directory, output.destination, output.staged); err != nil {
			return "", "", errors.Join(
				fmt.Errorf("reverify published %s after directory sync: %w", output.label, err),
				publicationResidueError(parent, stagedFiles),
			)
		}
	}

	for _, output := range publicationOrder {
		if err := verifyPublicationEntry(directory, output.destination, output.staged); err != nil {
			return "", "", errors.Join(
				fmt.Errorf("verify complete image publication set at %s: %w", output.label, err),
				publicationResidueError(parent, stagedFiles),
			)
		}
	}
	if err := verifyPublicationDirectoryPath(parent, directoryInfo); err != nil {
		return "", "", errors.Join(err, publicationResidueError(parent, stagedFiles))
	}
	return manifestPath, journalPath, nil
}

// valid reports whether an identity is canonical and describes a non-empty
// publication payload.
func (identity publicationIdentity) valid() bool {
	if identity.size <= 0 || len(identity.digest) != sha256.Size*2 {
		return false
	}
	for _, character := range identity.digest {
		if character < '0' || character > '9' && character < 'a' || character > 'f' {
			return false
		}
	}
	return true
}

// openPublicationDirectory opens and pins a non-symbolic-link directory before
// any destination checks, staging creation, renames, or durability barriers.
func openPublicationDirectory(path string) (*os.File, os.FileInfo, error) {
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if pathInfo.Mode()&os.ModeSymlink != 0 || !pathInfo.IsDir() {
		return nil, nil, fmt.Errorf("image publication parent is not a non-symbolic-link directory: %s", path)
	}
	directory, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	openedInfo, statErr := directory.Stat()
	if statErr != nil || !openedInfo.IsDir() || !os.SameFile(pathInfo, openedInfo) {
		closeErr := directory.Close()
		return nil, nil, errors.Join(errors.New("image publication directory changed while it was opened"), statErr, closeErr)
	}
	return directory, openedInfo, nil
}

// verifyPublicationDirectoryPath confirms the diagnostic output paths still
// resolve through the directory pinned for the complete transaction.
func verifyPublicationDirectoryPath(path string, expected os.FileInfo) error {
	current, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("reinspect image publication directory: %w", err)
	}
	if current.Mode()&os.ModeSymlink != 0 || !current.IsDir() || !os.SameFile(current, expected) {
		return errors.New("image publication directory path changed during publication")
	}
	return nil
}

// requireAbsentPublicationEntry rejects every existing filesystem object at a
// final basename relative to the anchored publication directory.
func requireAbsentPublicationEntry(directory *os.File, name, label string) error {
	exists, err := publicationEntryExists(directory, name)
	if err != nil {
		return fmt.Errorf("inspect %s: %w", label, err)
	}
	if exists {
		return fmt.Errorf("%s already exists: %s", label, filepath.Join(directory.Name(), name))
	}
	return nil
}

// requireAbsentPublicationPath rejects every existing filesystem object during
// the early command preflight that runs before a publication directory is open.
func requireAbsentPublicationPath(path, label string) error {
	_, err := os.Lstat(path)
	if err == nil {
		return fmt.Errorf("%s already exists: %s", label, path)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect %s: %w", label, err)
	}
	return nil
}

// stagePublicationSource copies one regular source into a random, exclusive,
// durably flushed sibling and verifies every copied byte against expectation.
func stagePublicationSource(sourcePath string, directory *os.File, prefix string, expected publicationIdentity) (stagedPublicationFile, error) {
	sourceInfo, err := os.Lstat(sourcePath)
	if err != nil {
		return stagedPublicationFile{}, err
	}
	if sourceInfo.Mode()&os.ModeSymlink != 0 || !sourceInfo.Mode().IsRegular() {
		return stagedPublicationFile{}, fmt.Errorf("publication source is not a non-symbolic-link regular file: %s", sourcePath)
	}
	source, err := os.Open(sourcePath)
	if err != nil {
		return stagedPublicationFile{}, err
	}
	openedInfo, statErr := source.Stat()
	if statErr != nil || !os.SameFile(sourceInfo, openedInfo) {
		closeErr := source.Close()
		return stagedPublicationFile{}, errors.Join(errors.New("publication source changed while it was opened"), statErr, closeErr)
	}
	staged, stageErr := stagePublicationReader(source, directory, prefix, expected)
	closeErr := source.Close()
	if err := errors.Join(stageErr, closeErr); err != nil {
		if stageErr == nil {
			err = errors.Join(err, abandonStagedPublicationFile(staged))
		}
		return stagedPublicationFile{}, err
	}
	currentInfo, err := os.Lstat(sourcePath)
	if err != nil || !os.SameFile(sourceInfo, currentInfo) {
		return stagedPublicationFile{}, errors.Join(
			errors.New("publication source changed while it was staged"),
			err,
			abandonStagedPublicationFile(staged),
		)
	}
	return staged, nil
}

// stagePublicationBytes writes one in-memory payload into a random, exclusive,
// durably flushed sibling and verifies the complete staged identity.
func stagePublicationBytes(data []byte, directory *os.File, prefix string, expected publicationIdentity) (stagedPublicationFile, error) {
	return stagePublicationReader(bytes.NewReader(data), directory, prefix, expected)
}

// stagePublicationReader creates one descriptor-relative exclusive sibling,
// flushes its bytes, and retains its descriptor for publication verification.
func stagePublicationReader(reader io.Reader, directory *os.File, prefix string, expected publicationIdentity) (result stagedPublicationFile, returnErr error) {
	if !expected.valid() {
		return stagedPublicationFile{}, errors.New("staged publication identity is invalid")
	}
	file, name, err := createRandomPublicationStagingFile(directory, prefix)
	if err != nil {
		return stagedPublicationFile{}, err
	}
	path := filepath.Join(directory.Name(), name)
	createdInfo, err := file.Stat()
	if err != nil {
		closeErr := file.Close()
		return stagedPublicationFile{}, errors.Join(
			err,
			closeErr,
			fmt.Errorf("publication staging residue retained after an unsafe-to-remove failure: %s", path),
		)
	}
	result = stagedPublicationFile{name: name, path: path, file: file, info: createdInfo, identity: expected}
	defer func() {
		if returnErr == nil {
			return
		}
		closeErr := file.Close()
		result.file = nil
		returnErr = errors.Join(
			returnErr,
			closeErr,
			fmt.Errorf("publication staging residue retained after an unsafe-to-remove failure: %s", path),
		)
	}()

	hasher := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(file, hasher), io.LimitReader(reader, expected.size+1))
	modeErr := file.Chmod(0o644)
	syncErr := file.Sync()
	if err := errors.Join(copyErr, modeErr, syncErr); err != nil {
		return stagedPublicationFile{}, err
	}
	actual := publicationIdentity{digest: hex.EncodeToString(hasher.Sum(nil)), size: written}
	if actual != expected {
		return stagedPublicationFile{}, fmt.Errorf(
			"staged publication identity mismatch: expected %s/%d, got %s/%d",
			expected.digest,
			expected.size,
			actual.digest,
			actual.size,
		)
	}
	result.identity = actual
	if err := verifyPublicationEntry(directory, name, result); err != nil {
		return stagedPublicationFile{}, fmt.Errorf("publication staging entry changed before use: %w", err)
	}
	return result, nil
}

// createRandomPublicationStagingFile creates one unpredictable exclusive entry
// relative to the anchored directory and returns its retained descriptor.
func createRandomPublicationStagingFile(directory *os.File, prefix string) (*os.File, string, error) {
	if prefix == "" || filepath.Base(prefix) != prefix || strings.ContainsAny(prefix, `/\\`) {
		return nil, "", errors.New("publication staging prefix must be a non-empty basename")
	}
	for attempt := 0; attempt < publicationStagingAttempts; attempt++ {
		var random [16]byte
		if _, err := rand.Read(random[:]); err != nil {
			return nil, "", fmt.Errorf("generate publication staging name: %w", err)
		}
		name := prefix + hex.EncodeToString(random[:])
		file, err := openExclusivePublicationEntry(directory, name)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return nil, "", err
		}
		return file, name, nil
	}
	return nil, "", errors.New("could not allocate an exclusive publication staging entry")
}

// publishAndVerifyOutput performs one no-replace rename and proves the final
// entry is still the retained staged object with the exact expected bytes.
func publishAndVerifyOutput(
	directory *os.File,
	staged stagedPublicationFile,
	destination string,
	label string,
	publisher noReplacePublisher,
) error {
	publishErr := publisher(directory, staged.name, destination)
	verifyErr := verifyPublicationEntry(directory, destination, staged)
	stagingExists, stagingStateErr := publicationEntryExists(directory, staged.name)
	if publishErr == nil && verifyErr == nil && stagingStateErr == nil && !stagingExists {
		return nil
	}
	return errors.Join(
		wrapPublicationPublishError(label, publishErr),
		wrapPublicationVerificationError(label, verifyErr),
		wrapPublicationStagingStateError(staged.path, stagingExists, stagingStateErr),
	)
}

// verifyPublicationEntry opens one destination relative to the anchored
// directory and compares its object and bounded bytes with the retained stage.
func verifyPublicationEntry(directory *os.File, name string, expected stagedPublicationFile) error {
	entry, err := openPublicationEntry(directory, name)
	if err != nil {
		return err
	}
	entryInfo, statErr := entry.Stat()
	if statErr != nil || !entryInfo.Mode().IsRegular() || !os.SameFile(entryInfo, expected.info) {
		closeErr := entry.Close()
		return errors.Join(errors.New("published entry is not the retained staging object"), statErr, closeErr)
	}
	actual, identityErr := identifyPublicationFile(entry, expected.identity.size)
	closeErr := entry.Close()
	if err := errors.Join(identityErr, closeErr); err != nil {
		return err
	}
	if actual != expected.identity {
		return fmt.Errorf(
			"published entry identity mismatch: expected %s/%d, got %s/%d",
			expected.identity.digest,
			expected.identity.size,
			actual.digest,
			actual.size,
		)
	}
	retainedInfo, err := expected.file.Stat()
	if err != nil {
		return fmt.Errorf("inspect retained staging descriptor: %w", err)
	}
	if !os.SameFile(entryInfo, retainedInfo) {
		return errors.New("published entry differs from the retained staging descriptor")
	}
	latest, err := openPublicationEntry(directory, name)
	if err != nil {
		return fmt.Errorf("reopen published entry after identity verification: %w", err)
	}
	latestInfo, latestStatErr := latest.Stat()
	latestCloseErr := latest.Close()
	if latestStatErr != nil || !os.SameFile(latestInfo, entryInfo) || !os.SameFile(latestInfo, retainedInfo) {
		return errors.Join(
			errors.New("published entry name changed during identity verification"),
			latestStatErr,
			latestCloseErr,
		)
	}
	if latestCloseErr != nil {
		return latestCloseErr
	}
	return nil
}

// identifyPublicationFile hashes no more than one byte beyond the expected
// length without changing the retained descriptor's shared file offset.
func identifyPublicationFile(file *os.File, expectedSize int64) (publicationIdentity, error) {
	if expectedSize < 0 {
		return publicationIdentity{}, errors.New("expected publication byte length must not be negative")
	}
	hasher := sha256.New()
	read, err := io.Copy(hasher, io.NewSectionReader(file, 0, expectedSize+1))
	return publicationIdentity{digest: hex.EncodeToString(hasher.Sum(nil)), size: read}, err
}

// publicationResidueError explains why transaction entries are deliberately
// retained when POSIX cannot conditionally unlink a particular inode.
func publicationResidueError(parent string, stagedFiles []*stagedPublicationFile) error {
	paths := make([]string, 0, len(stagedFiles))
	for _, staged := range stagedFiles {
		if staged != nil && staged.path != "" {
			paths = append(paths, staged.path)
		}
	}
	return fmt.Errorf(
		"publication stopped without path-based rollback; inspect the final paths and retained transaction entries before removing anything: directory %s, staging %s",
		parent,
		strings.Join(paths, ", "),
	)
}

// abandonStagedPublicationFile closes one retained descriptor and reports the
// intentionally preserved staging path without unlinking by a mutable name.
func abandonStagedPublicationFile(staged stagedPublicationFile) error {
	var closeErr error
	if staged.file != nil {
		closeErr = staged.file.Close()
	}
	return errors.Join(
		closeErr,
		fmt.Errorf("publication staging residue retained after an unsafe-to-remove failure: %s", staged.path),
	)
}

// closeStagedPublicationFiles closes every retained descriptor without using a
// mutable filesystem name for cleanup.
func closeStagedPublicationFiles(stagedFiles []*stagedPublicationFile) error {
	var result error
	for _, staged := range stagedFiles {
		if staged == nil || staged.file == nil {
			continue
		}
		if err := staged.file.Close(); err != nil {
			result = errors.Join(result, fmt.Errorf("close retained publication descriptor %s: %w", staged.path, err))
		}
		staged.file = nil
	}
	return result
}

// wrapPublicationPublishError adds stable context only when the no-replace
// publisher itself reported a failure.
func wrapPublicationPublishError(label string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("publish %s without replacement: %w", label, err)
}

// wrapPublicationVerificationError adds stable context only when one final
// entry could not be verified.
func wrapPublicationVerificationError(label string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("verify published %s: %w", label, err)
}

// wrapPublicationStagingStateError reports a staging entry that remains or
// could not be inspected after its no-replace rename.
func wrapPublicationStagingStateError(path string, exists bool, err error) error {
	if err != nil {
		return fmt.Errorf("inspect staging entry after publication: %w", err)
	}
	if exists {
		return fmt.Errorf("staging entry remains after publication: %s", path)
	}
	return nil
}

// syncPublicationDirectory flushes changes through the already anchored
// directory descriptor; Darwin's EINVAL response is unsupported advice.
func syncPublicationDirectory(directory *os.File) error {
	syncErr := directory.Sync()
	if runtime.GOOS == "darwin" && errors.Is(syncErr, syscall.EINVAL) {
		return nil
	}
	return syncErr
}
