package releaseprep

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// partWriter splits one compressed stream into fixed-size exclusive files.
type partWriter struct {
	// directory is the private transaction directory.
	directory string
	// base is the portable compressed archive name.
	base string
	// limit is the maximum bytes in each part.
	limit int64
	// current is the active exclusive part file.
	current *os.File
	// currentHash receives the active part bytes.
	currentHash hashState
	// currentSize counts the active part bytes.
	currentSize int64
	// completeHash receives the complete compressed stream.
	completeHash hashState
	// completeSize counts the complete compressed stream.
	completeSize int64
	// records contains finalised parts in stream order.
	records []FileRecord
}

// hashState is the subset of hash.Hash needed by partWriter.
type hashState interface {
	// Write adds bytes to the digest state.
	Write([]byte) (int, error)
	// Sum appends the current digest to prefix.
	Sum([]byte) []byte
}

// newPartWriter constructs a bounded streaming split writer.
func newPartWriter(directory, base string, limit int64) *partWriter {
	return &partWriter{directory: directory, base: base, limit: limit, completeHash: sha256.New()}
}

// Write splits data exactly at the configured byte boundary.
func (writer *partWriter) Write(data []byte) (int, error) {
	if writer == nil || writer.limit <= 0 {
		return 0, errors.New("compressed part writer is unavailable")
	}
	total := 0
	for len(data) > 0 {
		if writer.current == nil {
			if err := writer.openPart(); err != nil {
				return total, err
			}
		}
		available := writer.limit - writer.currentSize
		chunk := int64(len(data))
		if chunk > available {
			chunk = available
		}
		portion := data[:int(chunk)]
		written, fileErr := writer.current.Write(portion)
		if written > 0 {
			if _, err := writer.currentHash.Write(portion[:written]); err != nil {
				return total, err
			}
			if _, err := writer.completeHash.Write(portion[:written]); err != nil {
				return total, err
			}
			writer.currentSize += int64(written)
			writer.completeSize += int64(written)
			total += written
			data = data[written:]
		}
		if fileErr != nil {
			return total, fileErr
		}
		if written != len(portion) {
			return total, io.ErrShortWrite
		}
		if writer.currentSize == writer.limit {
			if err := writer.closePart(); err != nil {
				return total, err
			}
		}
	}
	return total, nil
}

// Close finalises the active part and returns immutable part and archive records.
func (writer *partWriter) Close() ([]FileRecord, FileRecord, error) {
	if writer == nil {
		return nil, FileRecord{}, errors.New("compressed part writer is unavailable")
	}
	if writer.current != nil {
		if err := writer.closePart(); err != nil {
			return nil, FileRecord{}, err
		}
	}
	if len(writer.records) == 0 || writer.completeSize <= 0 {
		return nil, FileRecord{}, errors.New("compression produced no parts")
	}
	parts := append([]FileRecord(nil), writer.records...)
	archive := FileRecord{
		Name: writer.base, SHA256: hex.EncodeToString(writer.completeHash.Sum(nil)), Size: writer.completeSize,
	}
	return parts, archive, nil
}

// Abort closes the active file after a failed transaction; its directory remains private.
func (writer *partWriter) Abort() error {
	if writer == nil || writer.current == nil {
		return nil
	}
	err := writer.current.Close()
	writer.current = nil
	return err
}

// openPart creates the next zero-padded part exclusively.
func (writer *partWriter) openPart() error {
	if len(writer.records) >= maximumPartCount {
		return fmt.Errorf("compressed image exceeds the %d-part limit", maximumPartCount)
	}
	name := fmt.Sprintf("%s.part-%04d", writer.base, len(writer.records))
	file, err := os.OpenFile(filepath.Join(writer.directory, name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	writer.current = file
	writer.currentHash = sha256.New()
	writer.currentSize = 0
	return nil
}

// closePart syncs, closes, and records the active part.
func (writer *partWriter) closePart() error {
	name := filepath.Base(writer.current.Name())
	syncErr := writer.current.Sync()
	closeErr := writer.current.Close()
	writer.current = nil
	if err := errors.Join(syncErr, closeErr); err != nil {
		return err
	}
	if writer.currentSize <= 0 || writer.currentSize >= HostedAssetLimitBytes {
		return fmt.Errorf("compressed part has an invalid hosted-release size: %s", name)
	}
	if err := os.Chmod(filepath.Join(writer.directory, name), 0o644); err != nil {
		return err
	}
	writer.records = append(writer.records, FileRecord{
		Name: name, SHA256: hex.EncodeToString(writer.currentHash.Sum(nil)), Size: writer.currentSize,
	})
	writer.currentHash = nil
	writer.currentSize = 0
	return nil
}
