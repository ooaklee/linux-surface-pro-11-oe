package capture

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf8"
)

const (
	// maximumEvidenceLogBytes caps each retained command or kernel log.
	maximumEvidenceLogBytes int64 = 4 << 20
	// maximumOutputPathBytes rejects unreasonable host paths before mutation.
	maximumOutputPathBytes = 4096
)

// preparedEvidence owns the closed private output set reserved before capture.
type preparedEvidence struct {
	// paths are the public result paths for the reserved files.
	paths Evidence
	// created lists every file reserved by this invocation for bounded cleanup.
	created []string
	// temporaryDirectory is removed only if preparation fails before returning.
	temporaryDirectory string
}

// limitedWriter stops a child whose retained diagnostic would exceed the cap.
type limitedWriter struct {
	// mutex serialises concurrent stdout and stderr writes from one child.
	mutex sync.Mutex
	// destination receives accepted bytes.
	destination io.Writer
	// remaining is the number of bytes still accepted.
	remaining int64
	// exceeded records that at least one byte crossed the cap.
	exceeded bool
}

// Write forwards content until the compiled evidence limit is reached.
func (writer *limitedWriter) Write(content []byte) (int, error) {
	writer.mutex.Lock()
	defer writer.mutex.Unlock()
	if int64(len(content)) > writer.remaining {
		writer.exceeded = true
		return 0, fmt.Errorf("camera evidence log exceeded %d bytes", maximumEvidenceLogBytes)
	}
	count, err := writer.destination.Write(content)
	writer.remaining -= int64(count)
	return count, err
}

// prepareEvidence resolves a private parent and atomically reserves the exact
// output closed set without overwriting any existing object.
func prepareEvidence(outputPath string) (preparedEvidence, error) {
	prepared := preparedEvidence{}
	ready := false
	defer func() {
		if !ready && prepared.temporaryDirectory != "" {
			prepared.removeReservations()
		}
	}()
	if strings.TrimSpace(outputPath) == "" {
		directory, err := os.MkdirTemp("", "linux-armer-imx681-")
		if err != nil {
			return preparedEvidence{}, fmt.Errorf("create private camera output directory: %w", err)
		}
		if err := os.Chmod(directory, 0o700); err != nil {
			_ = os.Remove(directory)
			return preparedEvidence{}, fmt.Errorf("protect private camera output directory: %w", err)
		}
		prepared.temporaryDirectory = directory
		outputPath = filepath.Join(directory, "capture.raw")
	}
	if len(outputPath) > maximumOutputPathBytes || !utf8.ValidString(outputPath) || strings.ContainsRune(outputPath, 0) {
		return preparedEvidence{}, fmt.Errorf("camera output path is invalid")
	}
	base := filepath.Base(outputPath)
	if base == "." || base == string(filepath.Separator) || base == "" || containsControlCharacter(base) {
		return preparedEvidence{}, fmt.Errorf("camera output must name a new regular file")
	}
	parent, err := filepath.Abs(filepath.Dir(outputPath))
	if err != nil {
		return preparedEvidence{}, fmt.Errorf("resolve camera output parent: %w", err)
	}
	parentInfo, err := os.Lstat(parent)
	if err != nil {
		return preparedEvidence{}, fmt.Errorf("inspect camera output parent: %w", err)
	}
	if parentInfo.Mode()&os.ModeSymlink != 0 || !parentInfo.IsDir() {
		return preparedEvidence{}, fmt.Errorf("camera output parent must be a real directory")
	}
	resolvedParent, err := filepath.EvalSymlinks(parent)
	if err != nil {
		return preparedEvidence{}, fmt.Errorf("resolve camera output parent links: %w", err)
	}
	resolvedInfo, err := os.Stat(resolvedParent)
	if err != nil {
		return preparedEvidence{}, fmt.Errorf("inspect resolved camera output parent: %w", err)
	}
	if err := validatePrivateDirectory(resolvedInfo); err != nil {
		return preparedEvidence{}, err
	}
	outputPath = filepath.Join(resolvedParent, base)
	prepared.paths = Evidence{
		Raw:         outputPath,
		MediaBefore: outputPath + ".media-before.txt",
		MediaAfter:  outputPath + ".media-after.txt",
		V4L2Log:     outputPath + ".v4l2.log",
		KernelLog:   outputPath + ".kernel.log",
		Statistics:  outputPath + ".stats.json",
	}
	paths := []string{
		prepared.paths.Raw, prepared.paths.MediaBefore, prepared.paths.MediaAfter,
		prepared.paths.V4L2Log, prepared.paths.KernelLog, prepared.paths.Statistics,
	}
	for _, path := range paths {
		file, createErr := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if createErr != nil {
			prepared.removeReservations()
			return preparedEvidence{}, fmt.Errorf("reserve private camera evidence: %w", createErr)
		}
		closeErr := file.Close()
		prepared.created = append(prepared.created, path)
		if closeErr != nil {
			prepared.removeReservations()
			return preparedEvidence{}, fmt.Errorf("reserve private camera evidence: %w", closeErr)
		}
	}
	ready = true
	return prepared, nil
}

// validatePrivateDirectory rejects a parent controlled by another user or a
// writable shared directory without the sticky bit.
func validatePrivateDirectory(info os.FileInfo) error {
	if !info.IsDir() {
		return fmt.Errorf("camera output parent is not a directory")
	}
	mode := info.Mode().Perm()
	sticky := info.Mode()&os.ModeSticky != 0
	if mode&0o022 != 0 && !sticky {
		return fmt.Errorf("camera output parent is group/world-writable without the sticky bit")
	}
	if !ownedByCurrentUserOrRoot(info) && !sticky {
		return fmt.Errorf("camera output parent is controlled by another user")
	}
	return nil
}

// removeReservations removes only the exact files this preparation created.
func (prepared *preparedEvidence) removeReservations() {
	for _, path := range prepared.created {
		_ = os.Remove(path)
	}
	if prepared.temporaryDirectory != "" {
		_ = os.Remove(prepared.temporaryDirectory)
	}
}

// openEvidenceLog reopens one reserved regular file without following a final
// symbolic link and returns a capped private writer.
func openEvidenceLog(path string) (*os.File, *limitedWriter, error) {
	file, err := openRegularTruncateNoFollow(path)
	if err != nil {
		return nil, nil, fmt.Errorf("open private camera evidence: %w", err)
	}
	return file, &limitedWriter{destination: file, remaining: maximumEvidenceLogBytes}, nil
}

// writeEvidence replaces one reserved empty file with bounded private content
// and flushes it before returning.
func writeEvidence(path string, content []byte) error {
	if int64(len(content)) > maximumEvidenceLogBytes {
		return fmt.Errorf("camera evidence exceeds the compiled limit")
	}
	file, _, err := openEvidenceLog(path)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(content)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		return fmt.Errorf("write private camera evidence: %w", err)
	}
	return nil
}

// writeStatistics stores one indented private JSON report in its reserved file.
func writeStatistics(path string, statistics Statistics) error {
	content, err := json.MarshalIndent(statistics, "", "  ")
	if err != nil {
		return fmt.Errorf("encode camera statistics: %w", err)
	}
	content = append(content, '\n')
	return writeEvidence(path, content)
}
