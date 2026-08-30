package companion

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"time"
)

// archiveTimestamp is the fixed timestamp used for every gzip and tar header
// so identical maintained sources produce byte-identical source archives.
var archiveTimestamp = time.Unix(0, 0).UTC()

// writeSourceArchive creates a deterministic gzip-compressed tar containing
// only the prevalidated, allow-listed linux-armer source files.
func writeSourceArchive(destination string, files []sourceFile) error {
	if len(files) == 0 {
		return errors.New("create companion source archive: maintained source set is empty")
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return fmt.Errorf("create companion source archive directory: %w", err)
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("create companion source archive: %w", err)
	}
	gzipWriter, err := gzip.NewWriterLevel(output, gzip.BestCompression)
	if err != nil {
		_ = output.Close()
		_ = os.Remove(destination)
		return fmt.Errorf("create companion source gzip stream: %w", err)
	}
	gzipWriter.Header.ModTime = archiveTimestamp
	gzipWriter.Header.OS = 255
	tarWriter := tar.NewWriter(gzipWriter)
	writeErr := writeArchiveFiles(tarWriter, files)
	tarCloseErr := tarWriter.Close()
	gzipCloseErr := gzipWriter.Close()
	outputCloseErr := output.Close()
	if writeErr != nil || tarCloseErr != nil || gzipCloseErr != nil || outputCloseErr != nil {
		_ = os.Remove(destination)
		return fmt.Errorf("write companion source archive: %w", errors.Join(writeErr, tarCloseErr, gzipCloseErr, outputCloseErr))
	}
	if err := os.Chmod(destination, 0o644); err != nil {
		_ = os.Remove(destination)
		return fmt.Errorf("set companion source archive mode: %w", err)
	}
	return nil
}

// writeArchiveFiles appends deterministic regular-file headers and exact bytes
// for the already sorted maintained source set.
func writeArchiveFiles(writer *tar.Writer, files []sourceFile) error {
	for _, file := range files {
		if err := validateRegularFile(file.absolutePath, "companion archive source file"); err != nil {
			return err
		}
		input, err := os.Open(file.absolutePath)
		if err != nil {
			return fmt.Errorf("open source archive input %s: %w", file.portablePath, err)
		}
		info, err := input.Stat()
		if err != nil {
			_ = input.Close()
			return fmt.Errorf("inspect source archive input %s: %w", file.portablePath, err)
		}
		if !info.Mode().IsRegular() {
			_ = input.Close()
			return fmt.Errorf("source archive input %s is not a regular file", file.portablePath)
		}
		if info.Size() != file.size {
			_ = input.Close()
			return fmt.Errorf(
				"source archive input %s changed size: got %d, expected %d",
				file.portablePath, info.Size(), file.size,
			)
		}
		header := &tar.Header{
			Name:       path.Join("linux-armer", file.portablePath),
			Mode:       0o644,
			Size:       file.size,
			ModTime:    archiveTimestamp,
			AccessTime: archiveTimestamp,
			ChangeTime: archiveTimestamp,
			Typeflag:   tar.TypeReg,
			Format:     tar.FormatPAX,
		}
		if err := writer.WriteHeader(header); err != nil {
			_ = input.Close()
			return fmt.Errorf("write source archive header for %s: %w", file.portablePath, err)
		}
		digest := sha256.New()
		written, copyErr := io.CopyN(io.MultiWriter(writer, digest), input, file.size)
		var trailing [1]byte
		trailingBytes, trailingErr := input.Read(trailing[:])
		closeErr := input.Close()
		if copyErr != nil || closeErr != nil {
			return fmt.Errorf("write source archive input %s: %w", file.portablePath, errors.Join(copyErr, closeErr))
		}
		if written != file.size {
			return fmt.Errorf("source archive input %s changed size while reading", file.portablePath)
		}
		if trailingBytes != 0 || !errors.Is(trailingErr, io.EOF) {
			if trailingErr != nil && !errors.Is(trailingErr, io.EOF) {
				return fmt.Errorf("check source archive input %s length: %w", file.portablePath, trailingErr)
			}
			return fmt.Errorf("source archive input %s changed size while reading", file.portablePath)
		}
		actualDigest := hex.EncodeToString(digest.Sum(nil))
		if actualDigest != file.sha256 {
			return fmt.Errorf(
				"source archive input %s changed content: SHA-256 %s, expected %s",
				file.portablePath, actualDigest, file.sha256,
			)
		}
	}
	return nil
}
