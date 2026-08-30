package media

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
)

// ErrConfirmationMismatch reports that destructive execution lacked its exact phrase.
var ErrConfirmationMismatch = errors.New("media write confirmation does not match the immutable plan")

// ErrDeviceIdentityDrift reports that fresh device evidence differs from the plan.
var ErrDeviceIdentityDrift = errors.New("removable-media device identity changed after planning")

// ErrElevatedPrivilegeRequired reports that raw-device mutation is not authorised.
var ErrElevatedPrivilegeRequired = errors.New("elevated privilege is required to write removable media")

// Backend separates platform discovery and raw-device operations from media policy.
type Backend interface {
	// List returns a fresh snapshot of every whole storage device the platform exposes.
	List(context.Context) ([]Device, error)
	// Inspect returns fresh evidence for one canonical whole-device path.
	Inspect(context.Context, string) (Device, error)
	// Unmount prepares an already-approved whole device for exclusive raw access.
	Unmount(context.Context, Device) error
	// OpenWrite opens the approved raw whole-device path without truncating it.
	OpenWrite(context.Context, Device) (WriteDevice, error)
	// OpenRead reopens the approved raw whole-device path for read-back verification.
	OpenRead(context.Context, Device) (ReadDevice, error)
	// Eject asks the operating system to make the verified device safe to remove.
	Eject(context.Context, Device) error
}

// WriteDevice is the minimum raw-device contract needed for bounded writing.
type WriteDevice interface {
	io.Writer
	// Sync flushes buffered writes through the operating-system boundary.
	Sync() error
	// Close releases the raw write handle.
	Close() error
}

// ReadDevice is the minimum raw-device contract needed for bounded verification.
type ReadDevice interface {
	io.Reader
	// Close releases the raw read handle.
	Close() error
}

// ProgressCallback observes bounded progress and may cancel by returning an error.
type ProgressCallback func(Progress) error

// PrivilegeChecker verifies elevated authority immediately before target mutation.
type PrivilegeChecker interface {
	// RequireElevated returns nil only when the caller may mutate a raw device.
	RequireElevated() error
}

// PrivilegeCheckFunc adapts a function to the PrivilegeChecker boundary.
type PrivilegeCheckFunc func() error

// RequireElevated invokes the adapted privilege check.
func (check PrivilegeCheckFunc) RequireElevated() error {
	if check == nil {
		return ErrElevatedPrivilegeRequired
	}
	return check()
}

// fileWriteDevice wraps an operating-system file as a raw write boundary.
type fileWriteDevice struct {
	// File is the opened raw device delegated to the standard library.
	*os.File
}

// openRawWrite opens the paired raw path for writing without creating or
// truncating a device node.
func openRawWrite(device Device) (WriteDevice, error) {
	file, err := openStableRawFile(device.Path, device.RawPath, os.O_WRONLY)
	if err != nil {
		return nil, fmt.Errorf("open raw device for writing: %w", err)
	}
	return &fileWriteDevice{File: file}, nil
}

// openRawRead opens the paired raw path for read-back without changing the device.
func openRawRead(device Device) (ReadDevice, error) {
	file, err := openStableRawFile(device.Path, device.RawPath, os.O_RDONLY)
	if err != nil {
		return nil, fmt.Errorf("open raw device for verification: %w", err)
	}
	return file, nil
}
