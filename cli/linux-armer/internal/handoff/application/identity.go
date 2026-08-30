package application

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff"
)

const (
	// smbiosProductUUIDPath is the only identity value read from the identity root.
	smbiosProductUUIDPath = "sys/class/dmi/id/product_uuid"
	// maximumSMBIOSProductUUIDBytes bounds the private identity read.
	maximumSMBIOSProductUUIDBytes int64 = 128
)

// resolveExplicitRoot returns one physical non-symlink directory without
// conflating the identity and target roots.
func resolveExplicitRoot(value, label string, defaultToSystemRoot bool) (string, error) {
	if strings.TrimSpace(value) == "" {
		if !defaultToSystemRoot {
			return "", fmt.Errorf("%s is required", label)
		}
		value = string(filepath.Separator)
	}
	if strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return "", fmt.Errorf("%s contains control characters", label)
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
	if strings.IndexFunc(resolved, unicode.IsControl) >= 0 {
		return "", fmt.Errorf("resolved %s contains control characters", label)
	}
	return filepath.Clean(resolved), nil
}

// verifyDeviceBinding re-derives the salted SMBIOS binding without returning,
// formatting, or retaining the raw UUID beyond this call.
func verifyDeviceBinding(ctx context.Context, identityRoot string, contract handoff.Contract) error {
	root, err := os.OpenRoot(identityRoot)
	if err != nil {
		return fmt.Errorf("open identity root: %w", err)
	}
	defer root.Close()
	file, err := root.Open(smbiosProductUUIDPath)
	if err != nil {
		return errors.New("read SMBIOS product identity from the explicit identity root")
	}
	content, readErr := io.ReadAll(io.LimitReader(contextReader{context: ctx, reader: file}, maximumSMBIOSProductUUIDBytes+1))
	closeErr := file.Close()
	if readErr != nil || closeErr != nil {
		return errors.New("read SMBIOS product identity from the explicit identity root")
	}
	if int64(len(content)) > maximumSMBIOSProductUUIDBytes {
		return errors.New("SMBIOS product identity exceeds its compiled bound")
	}
	canonicalUUID := strings.ToLower(strings.TrimSpace(string(content)))
	derived, err := handoff.DeriveDeviceBinding(contract.Device.BindingSalt, canonicalUUID)
	if err != nil {
		return errors.New("SMBIOS product identity is not canonical")
	}
	if subtle.ConstantTimeCompare([]byte(derived), []byte(contract.Device.SMBIOSProductUUIDBindingSHA256)) != 1 {
		return errors.New("private Windows hand-off belongs to a different physical device")
	}
	return nil
}

// contextReader stops private or target reads after caller cancellation.
type contextReader struct {
	// context controls the current bounded read.
	context context.Context
	// reader supplies bytes without becoming report data.
	reader io.Reader
}

// Read checks cancellation before reading from the underlying source.
func (reader contextReader) Read(buffer []byte) (int, error) {
	if err := reader.context.Err(); err != nil {
		return 0, err
	}
	return reader.reader.Read(buffer)
}
