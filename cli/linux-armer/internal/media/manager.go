package media

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	// defaultChunkSize bounds ordinary write and verification allocations at four MiB.
	defaultChunkSize = 4 << 20
	// maximumChunkSize prevents an injected configuration from defeating bounded I/O.
	maximumChunkSize = 16 << 20
	// deviceFingerprintPrefix distinguishes opaque media identities from device paths.
	deviceFingerprintPrefix = "media:v1:"
	// maximumPathBytes bounds untrusted filesystem and device paths presented to users.
	maximumPathBytes = 4096
	// maximumIdentityBytes bounds topology and stable identity metadata.
	maximumIdentityBytes = 512
	// maximumDisplayBytes bounds human-readable device and filesystem metadata.
	maximumDisplayBytes = 256
	// maximumClassificationBytes bounds short transport and filesystem classifications.
	maximumClassificationBytes = 64
)

// ManagerOptions supplies replaceable boundaries without weakening media policy.
type ManagerOptions struct {
	// Backend discovers devices and performs approved raw-device operations.
	Backend Backend
	// Privilege verifies elevated authority immediately before the first mutation.
	Privilege PrivilegeChecker
	// Clock timestamps receipts after execution reaches its final state.
	Clock func() time.Time
	// ChunkSize selects a testable I/O size up to the package's fixed maximum.
	ChunkSize int
}

// Manager orchestrates removable-media discovery, planning, writing, and verification.
type Manager struct {
	// backend owns platform discovery and raw-device boundaries.
	backend Backend
	// privilege protects the first mutating operation.
	privilege PrivilegeChecker
	// clock records receipt completion without coupling tests to wall time.
	clock func() time.Time
	// chunkSize bounds every source, target, and read-back transfer.
	chunkSize int
}

// NewManager constructs a media manager with safe defaults for optional boundaries.
func NewManager(options ManagerOptions) *Manager {
	privilege := options.Privilege
	if privilege == nil {
		privilege = defaultPrivilegeChecker()
	}
	clock := options.Clock
	if clock == nil {
		clock = time.Now
	}
	chunkSize := options.ChunkSize
	if chunkSize <= 0 || chunkSize > maximumChunkSize {
		chunkSize = defaultChunkSize
	}
	return &Manager{
		backend: options.Backend, privilege: privilege, clock: clock, chunkSize: chunkSize,
	}
}

// List returns normalised whole-device snapshots with opaque fingerprints.
func (manager *Manager) List(ctx context.Context) ([]Device, error) {
	if err := manager.validate(); err != nil {
		return nil, err
	}
	devices, err := manager.backend.List(ctx)
	if err != nil {
		return nil, fmt.Errorf("list removable-media candidates: %w", err)
	}
	seen := make(map[string]bool, len(devices))
	result := make([]Device, 0, len(devices))
	for _, candidate := range devices {
		device, normaliseErr := normaliseDevice(candidate)
		if normaliseErr != nil {
			return nil, fmt.Errorf("normalise discovered device: %w", normaliseErr)
		}
		if !device.WholeDisk {
			return nil, fmt.Errorf("platform returned non-whole device %s in whole-device inventory", device.Path)
		}
		if seen[device.Path] {
			return nil, fmt.Errorf("platform returned duplicate device path %s", device.Path)
		}
		seen[device.Path] = true
		result = append(result, device)
	}
	sort.Slice(result, func(left, right int) bool { return result[left].Path < result[right].Path })
	return result, nil
}

// Plan resolves and hashes an image, then binds it to one currently safe device.
func (manager *Manager) Plan(ctx context.Context, request PlanRequest) (WritePlan, error) {
	if err := manager.validate(); err != nil {
		return WritePlan{}, err
	}
	image, err := resolveImage(request.ImagePath)
	if err != nil {
		return WritePlan{}, err
	}
	device, err := manager.resolveTarget(ctx, request.Target)
	if err != nil {
		return WritePlan{}, err
	}
	if err := validateWriteTarget(image, device, true); err != nil {
		return WritePlan{}, err
	}
	plan := WritePlan{
		SchemaVersion:      PlanSchemaVersion,
		Image:              image,
		Device:             device,
		ConfirmationPhrase: confirmationPhrase(device, image),
	}
	plan.ID, err = calculatePlanID(plan)
	if err != nil {
		return WritePlan{}, fmt.Errorf("identify media write plan: %w", err)
	}
	return plan, nil
}

// Execute revalidates an immutable plan before writing, flushing, reading back, and ejecting.
func (manager *Manager) Execute(ctx context.Context, request ExecuteRequest) (receipt Receipt, err error) {
	receipt = newReceipt(request.Plan, request.DryRun)
	if manager != nil && manager.clock != nil {
		defer func() { receipt.CompletedAt = manager.clock().UTC() }()
	}
	if err := manager.validate(); err != nil {
		return receipt, err
	}
	if err := validatePlan(request.Plan); err != nil {
		return receipt, err
	}
	if request.DryRun {
		receipt.State = ReceiptStateDryRun
		return receipt, nil
	}
	if request.Confirmation != request.Plan.ConfirmationPhrase {
		return receipt, ErrConfirmationMismatch
	}
	if err := ctx.Err(); err != nil {
		return receipt, fmt.Errorf("start removable-media write: %w", err)
	}

	imageFile, err := openVerifiedImage(request.Plan.Image)
	if err != nil {
		return receipt, err
	}
	defer imageFile.Close()

	firstInspection, err := manager.inspectPlannedTarget(ctx, request.Plan, true)
	if err != nil {
		return receipt, err
	}
	storedOnTarget, err := openedImageStoredOnDevice(imageFile, request.Plan.Image.Path, firstInspection)
	if err != nil {
		return receipt, fmt.Errorf("verify opened source-image separation from %s: %w", firstInspection.Path, err)
	}
	if storedOnTarget {
		return receipt, fmt.Errorf(
			"opened source image %s is stored on target device %s",
			request.Plan.Image.Path,
			firstInspection.Path,
		)
	}
	if err := manager.privilege.RequireElevated(); err != nil {
		return receipt, fmt.Errorf("authorise removable-media write: %w", err)
	}
	if err := manager.backend.Unmount(ctx, firstInspection); err != nil {
		return receipt, fmt.Errorf("prepare removable media for raw writing: %w", err)
	}

	finalInspection, err := manager.inspectPlannedTarget(ctx, request.Plan, false)
	if err != nil {
		return receipt, fmt.Errorf("final pre-write inspection: %w", err)
	}
	receipt.TargetPath = finalInspection.Path
	receipt.State = ReceiptStatePrepared

	writtenDigest, writtenBytes, err := manager.write(ctx, imageFile, finalInspection, request.Plan.Image, request.Progress)
	receipt.WrittenBytes = writtenBytes
	if writtenBytes == request.Plan.Image.SizeBytes {
		receipt.WrittenSHA256 = writtenDigest
	}
	if writtenBytes > 0 {
		receipt.State = ReceiptStateWriting
	}
	if err != nil {
		return receipt, err
	}
	receipt.State = ReceiptStateWritten

	readbackInspection, err := manager.inspectPlannedTarget(ctx, request.Plan, false)
	if err != nil {
		return receipt, fmt.Errorf("pre-read-back inspection: %w", err)
	}
	readbackDigest, readbackBytes, err := manager.readback(ctx, readbackInspection, request.Plan.Image)
	receipt.ReadbackBytes = readbackBytes
	if readbackBytes > 0 {
		receipt.State = ReceiptStateVerifying
	}
	if readbackBytes == request.Plan.Image.SizeBytes {
		receipt.ReadbackSHA256 = readbackDigest
	}
	if err != nil {
		return receipt, err
	}
	if readbackDigest != request.Plan.Image.SHA256 {
		return receipt, fmt.Errorf(
			"read-back SHA-256 mismatch: expected %s, got %s",
			request.Plan.Image.SHA256,
			readbackDigest,
		)
	}
	ejectInspection, err := manager.inspectPlannedTarget(ctx, request.Plan, false)
	if err != nil {
		return receipt, fmt.Errorf("pre-ejection inspection: %w", err)
	}
	receipt.Verified = true
	receipt.State = ReceiptStateVerified
	if err := manager.backend.Eject(ctx, ejectInspection); err != nil {
		return receipt, fmt.Errorf("eject verified removable media: %w", err)
	}
	receipt.Ejected = true
	receipt.State = ReceiptStateComplete
	return receipt, nil
}

// validate confirms that a manager has every required execution boundary.
func (manager *Manager) validate() error {
	if manager == nil || manager.backend == nil {
		return errors.New("removable-media backend is unavailable")
	}
	if manager.privilege == nil {
		return errors.New("removable-media privilege checker is unavailable")
	}
	if manager.clock == nil {
		return errors.New("removable-media receipt clock is unavailable")
	}
	if manager.chunkSize <= 0 || manager.chunkSize > maximumChunkSize {
		return errors.New("removable-media chunk size is outside the safe bound")
	}
	return nil
}

// resolveTarget resolves either an opaque fingerprint or an explicit device path.
func (manager *Manager) resolveTarget(ctx context.Context, selector string) (Device, error) {
	var err error
	selector, err = normaliseUntrustedText("target selector", selector, maximumPathBytes)
	if err != nil {
		return Device{}, err
	}
	if selector == "" {
		return Device{}, errors.New("target device is required")
	}
	path := selector
	selectedFingerprint := ""
	if strings.HasPrefix(selector, deviceFingerprintPrefix) {
		if !validDeviceFingerprint(selector) {
			return Device{}, errors.New("target device fingerprint is malformed")
		}
		devices, err := manager.List(ctx)
		if err != nil {
			return Device{}, err
		}
		path = ""
		for _, device := range devices {
			if device.Fingerprint == selector {
				if path != "" {
					return Device{}, fmt.Errorf("opaque device fingerprint %q is ambiguous", selector)
				}
				path = device.Path
			}
		}
		if path == "" {
			return Device{}, fmt.Errorf("opaque device fingerprint %q was not found", selector)
		}
		selectedFingerprint = selector
	}
	path = filepath.Clean(path)
	if !validDevicePath(path) {
		return Device{}, fmt.Errorf("target device path %q is not a canonical /dev path", path)
	}
	device, err := manager.backend.Inspect(ctx, path)
	if err != nil {
		return Device{}, fmt.Errorf("inspect target device %q: %w", path, err)
	}
	normalised, err := normaliseDevice(device)
	if err != nil {
		return Device{}, fmt.Errorf("normalise target device: %w", err)
	}
	if normalised.Path != path {
		return Device{}, fmt.Errorf("target inspection returned %s for requested path %s", normalised.Path, path)
	}
	if selectedFingerprint != "" && normalised.Fingerprint != selectedFingerprint {
		return Device{}, fmt.Errorf(
			"%w while resolving selector: selected %s, observed %s",
			ErrDeviceIdentityDrift,
			selectedFingerprint,
			normalised.Fingerprint,
		)
	}
	return normalised, nil
}

// inspectPlannedTarget takes a fresh snapshot and rejects drift or unsafe state.
func (manager *Manager) inspectPlannedTarget(ctx context.Context, plan WritePlan, allowMounted bool) (Device, error) {
	current, err := manager.backend.Inspect(ctx, plan.Device.Path)
	if err != nil {
		return Device{}, fmt.Errorf("re-inspect target device: %w", err)
	}
	current, err = normaliseDevice(current)
	if err != nil {
		return Device{}, fmt.Errorf("normalise re-inspected target: %w", err)
	}
	if current.Fingerprint != plan.Device.Fingerprint {
		return Device{}, fmt.Errorf(
			"%w: planned %s, observed %s",
			ErrDeviceIdentityDrift,
			plan.Device.Fingerprint,
			current.Fingerprint,
		)
	}
	if err := validateWriteTarget(plan.Image, current, allowMounted); err != nil {
		return Device{}, err
	}
	return current, nil
}

// write copies exactly the planned source length in bounded chunks and flushes it.
func (manager *Manager) write(
	ctx context.Context,
	image *os.File,
	device Device,
	identity ImageIdentity,
	progress ProgressCallback,
) (digest string, written uint64, err error) {
	if err := ctx.Err(); err != nil {
		return "", 0, fmt.Errorf("open removable media for writing: %w", err)
	}
	target, err := manager.backend.OpenWrite(ctx, device)
	if err != nil {
		return "", 0, fmt.Errorf("open approved removable media for writing: %w", err)
	}
	closed := false
	defer func() {
		if !closed {
			_ = target.Close()
		}
	}()
	openedInspection, err := manager.backend.Inspect(ctx, device.Path)
	if err != nil {
		return "", 0, fmt.Errorf("re-inspect opened removable media: %w", err)
	}
	openedInspection, err = normaliseDevice(openedInspection)
	if err != nil {
		return "", 0, fmt.Errorf("normalise opened removable media: %w", err)
	}
	if openedInspection.Fingerprint != device.Fingerprint {
		return "", 0, fmt.Errorf(
			"%w after opening: expected %s, observed %s",
			ErrDeviceIdentityDrift,
			device.Fingerprint,
			openedInspection.Fingerprint,
		)
	}
	if err := validateWriteTarget(identity, openedInspection, false); err != nil {
		return "", 0, fmt.Errorf("opened removable-media target is unsafe: %w", err)
	}

	hasher := sha256.New()
	buffer := make([]byte, manager.chunkSize)
	remaining := identity.SizeBytes
	for remaining > 0 {
		if err := ctx.Err(); err != nil {
			return hex.EncodeToString(hasher.Sum(nil)), written, fmt.Errorf("write removable media: %w", err)
		}
		chunk := uint64(len(buffer))
		if remaining < chunk {
			chunk = remaining
		}
		readCount, readErr := io.ReadFull(image, buffer[:int(chunk)])
		if readErr != nil {
			return hex.EncodeToString(hasher.Sum(nil)), written, fmt.Errorf("read planned image: %w", readErr)
		}
		writeCount, writeErr := target.Write(buffer[:readCount])
		if writeCount < 0 || writeCount > readCount {
			return hex.EncodeToString(hasher.Sum(nil)), written, fmt.Errorf(
				"write removable media: invalid write count %d for %d-byte chunk",
				writeCount,
				readCount,
			)
		}
		if writeCount > 0 {
			_, _ = hasher.Write(buffer[:writeCount])
			written += uint64(writeCount)
		}
		if writeErr != nil {
			return hex.EncodeToString(hasher.Sum(nil)), written, fmt.Errorf("write removable media: %w", writeErr)
		}
		if writeCount != readCount {
			return hex.EncodeToString(hasher.Sum(nil)), written, fmt.Errorf(
				"write removable media: %w: wrote %d of %d bytes",
				io.ErrShortWrite,
				writeCount,
				readCount,
			)
		}
		remaining -= uint64(writeCount)
		if progress != nil {
			if err := progress(Progress{WrittenBytes: written, TotalBytes: identity.SizeBytes}); err != nil {
				return hex.EncodeToString(hasher.Sum(nil)), written, fmt.Errorf("write progress cancelled execution: %w", err)
			}
		}
	}

	extra := make([]byte, 1)
	if count, readErr := image.Read(extra); count != 0 || readErr != io.EOF {
		if readErr == nil {
			readErr = errors.New("image grew after its identity was established")
		}
		return hex.EncodeToString(hasher.Sum(nil)), written, fmt.Errorf("revalidate image length: %w", readErr)
	}
	digest = hex.EncodeToString(hasher.Sum(nil))
	if digest != identity.SHA256 {
		return digest, written, fmt.Errorf(
			"image SHA-256 changed while writing: expected %s, got %s",
			identity.SHA256,
			digest,
		)
	}
	if err := target.Sync(); err != nil {
		return digest, written, fmt.Errorf("flush removable-media write: %w", err)
	}
	closeErr := target.Close()
	closed = true
	if closeErr != nil {
		return digest, written, fmt.Errorf("close removable-media write: %w", closeErr)
	}
	return digest, written, nil
}

// readback revalidates an opened target and hashes exactly the planned image
// length while reporting only bytes actually consumed from the target.
func (manager *Manager) readback(ctx context.Context, device Device, identity ImageIdentity) (string, uint64, error) {
	if err := ctx.Err(); err != nil {
		return "", 0, fmt.Errorf("open removable media for read-back: %w", err)
	}
	target, err := manager.backend.OpenRead(ctx, device)
	if err != nil {
		return "", 0, fmt.Errorf("open removable media for read-back: %w", err)
	}
	closed := false
	defer func() {
		if !closed {
			_ = target.Close()
		}
	}()
	openedInspection, err := manager.backend.Inspect(ctx, device.Path)
	if err != nil {
		return "", 0, fmt.Errorf("re-inspect opened read-back device: %w", err)
	}
	openedInspection, err = normaliseDevice(openedInspection)
	if err != nil {
		return "", 0, fmt.Errorf("normalise opened read-back device: %w", err)
	}
	if openedInspection.Fingerprint != device.Fingerprint {
		return "", 0, fmt.Errorf(
			"%w after opening for read-back: expected %s, observed %s",
			ErrDeviceIdentityDrift,
			device.Fingerprint,
			openedInspection.Fingerprint,
		)
	}
	if err := validateWriteTarget(identity, openedInspection, false); err != nil {
		return "", 0, fmt.Errorf("opened read-back target is unsafe: %w", err)
	}

	hasher := sha256.New()
	buffer := make([]byte, manager.chunkSize)
	remaining := identity.SizeBytes
	readBytes := uint64(0)
	for remaining > 0 {
		if err := ctx.Err(); err != nil {
			return "", readBytes, fmt.Errorf("read back removable media: %w", err)
		}
		chunk := uint64(len(buffer))
		if remaining < chunk {
			chunk = remaining
		}
		readCount, readErr := io.ReadFull(target, buffer[:int(chunk)])
		if readCount > 0 {
			_, _ = hasher.Write(buffer[:readCount])
			readBytes += uint64(readCount)
			remaining -= uint64(readCount)
		}
		if readErr != nil {
			return "", readBytes, fmt.Errorf("read back removable media: %w", readErr)
		}
	}
	digest := hex.EncodeToString(hasher.Sum(nil))
	closeErr := target.Close()
	closed = true
	if closeErr != nil {
		return digest, readBytes, fmt.Errorf("close removable-media read-back: %w", closeErr)
	}
	return digest, readBytes, nil
}

// resolveImage canonicalises, validates, and hashes one regular non-link source image.
func resolveImage(path string) (ImageIdentity, error) {
	var err error
	path, err = normaliseUntrustedText("image path", path, maximumPathBytes)
	if err != nil {
		return ImageIdentity{}, err
	}
	if path == "" {
		return ImageIdentity{}, errors.New("image path is required")
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return ImageIdentity{}, fmt.Errorf("resolve image path: %w", err)
	}
	leaf, err := os.Lstat(absolute)
	if err != nil {
		return ImageIdentity{}, fmt.Errorf("inspect image path: %w", err)
	}
	if leaf.Mode()&os.ModeSymlink != 0 {
		return ImageIdentity{}, errors.New("image must be a regular file, not a symbolic link")
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return ImageIdentity{}, fmt.Errorf("canonicalise image path: %w", err)
	}
	file, err := os.Open(resolved)
	if err != nil {
		return ImageIdentity{}, fmt.Errorf("open image: %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return ImageIdentity{}, fmt.Errorf("inspect opened image: %w", err)
	}
	if !info.Mode().IsRegular() || !os.SameFile(leaf, info) {
		return ImageIdentity{}, errors.New("image must resolve to the inspected regular file")
	}
	if info.Size() <= 0 {
		return ImageIdentity{}, errors.New("image must not be empty")
	}
	hasher := sha256.New()
	hashedBytes, err := io.Copy(hasher, file)
	if err != nil {
		return ImageIdentity{}, fmt.Errorf("hash image: %w", err)
	}
	if hashedBytes != info.Size() {
		return ImageIdentity{}, fmt.Errorf("image size changed while hashing: expected %d bytes, read %d", info.Size(), hashedBytes)
	}
	name, err := normaliseUntrustedText("image name", filepath.Base(resolved), maximumDisplayBytes)
	if err != nil {
		return ImageIdentity{}, err
	}
	return ImageIdentity{
		Path:      resolved,
		Name:      name,
		SizeBytes: uint64(info.Size()),
		SHA256:    hex.EncodeToString(hasher.Sum(nil)),
	}, nil
}

// openVerifiedImage opens the planned file once, verifies it, and rewinds that handle.
func openVerifiedImage(identity ImageIdentity) (*os.File, error) {
	leaf, err := os.Lstat(identity.Path)
	if err != nil {
		return nil, fmt.Errorf("re-inspect planned image: %w", err)
	}
	if leaf.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("planned image became a symbolic link")
	}
	file, err := os.Open(identity.Path)
	if err != nil {
		return nil, fmt.Errorf("reopen planned image: %w", err)
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, fmt.Errorf("inspect reopened image: %w", err)
	}
	if !info.Mode().IsRegular() || !os.SameFile(leaf, info) || uint64(info.Size()) != identity.SizeBytes {
		file.Close()
		return nil, errors.New("planned image identity changed before execution")
	}
	hasher := sha256.New()
	hashedBytes, err := io.Copy(hasher, file)
	if err != nil {
		file.Close()
		return nil, fmt.Errorf("rehash planned image: %w", err)
	}
	if uint64(hashedBytes) != identity.SizeBytes {
		file.Close()
		return nil, errors.New("planned image length changed while rehashing")
	}
	if digest := hex.EncodeToString(hasher.Sum(nil)); digest != identity.SHA256 {
		file.Close()
		return nil, fmt.Errorf("planned image SHA-256 changed: expected %s, got %s", identity.SHA256, digest)
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		file.Close()
		return nil, fmt.Errorf("rewind planned image: %w", err)
	}
	return file, nil
}

// normaliseDevice canonicalises platform evidence and issues its opaque fingerprint.
func normaliseDevice(device Device) (Device, error) {
	var err error
	device.Fingerprint = ""
	if device.Path, err = normaliseUntrustedText("device path", device.Path, maximumPathBytes); err != nil {
		return Device{}, err
	}
	if device.RawPath, err = normaliseUntrustedText("raw device path", device.RawPath, maximumPathBytes); err != nil {
		return Device{}, err
	}
	device.Path = filepath.Clean(device.Path)
	device.RawPath = filepath.Clean(device.RawPath)
	textFields := []struct {
		name  string
		value *string
		limit int
	}{
		{name: "device hardware path", value: &device.HardwarePath, limit: maximumIdentityBytes},
		{name: "device stable ID", value: &device.StableID, limit: maximumIdentityBytes},
		{name: "device major:minor", value: &device.MajorMinor, limit: maximumClassificationBytes},
		{name: "device name", value: &device.Name, limit: maximumDisplayBytes},
		{name: "device vendor", value: &device.Vendor, limit: maximumDisplayBytes},
		{name: "device model", value: &device.Model, limit: maximumDisplayBytes},
		{name: "device serial", value: &device.Serial, limit: maximumDisplayBytes},
		{name: "device WWN", value: &device.WWN, limit: maximumDisplayBytes},
		{name: "device bus", value: &device.Bus, limit: maximumClassificationBytes},
	}
	for _, field := range textFields {
		*field.value, err = normaliseUntrustedText(field.name, *field.value, field.limit)
		if err != nil {
			return Device{}, err
		}
	}
	device.Bus = strings.ToLower(device.Bus)
	if device.MajorMinor != "" && !validMajorMinor(device.MajorMinor) {
		return Device{}, fmt.Errorf("device major:minor %q is malformed", device.MajorMinor)
	}
	if err := validateDevicePaths(device); err != nil {
		return Device{}, err
	}
	if device.SizeBytes == 0 {
		return Device{}, errors.New("device capacity must be positive")
	}
	device.Mounts = append([]Mount(nil), device.Mounts...)
	for index := range device.Mounts {
		mount := &device.Mounts[index]
		if mount.Device, err = normaliseUntrustedText("mounted device path", mount.Device, maximumPathBytes); err != nil {
			return Device{}, err
		}
		if mount.Point, err = normaliseUntrustedText("mount point", mount.Point, maximumPathBytes); err != nil {
			return Device{}, err
		}
		if mount.Filesystem, err = normaliseUntrustedText("filesystem type", mount.Filesystem, maximumClassificationBytes); err != nil {
			return Device{}, err
		}
		if mount.Label, err = normaliseUntrustedText("filesystem label", mount.Label, maximumDisplayBytes); err != nil {
			return Device{}, err
		}
		mount.Device = filepath.Clean(mount.Device)
		mount.Point = filepath.Clean(mount.Point)
		if !validDevicePath(mount.Device) {
			return Device{}, fmt.Errorf("mounted device path %q is not a canonical /dev path", mount.Device)
		}
		if !filepath.IsAbs(mount.Point) || filepath.Clean(mount.Point) != mount.Point {
			return Device{}, fmt.Errorf("mount point %q is not a canonical absolute path", mount.Point)
		}
	}
	sort.Slice(device.Mounts, func(left, right int) bool {
		if device.Mounts[left].Point == device.Mounts[right].Point {
			return device.Mounts[left].Device < device.Mounts[right].Device
		}
		return device.Mounts[left].Point < device.Mounts[right].Point
	})
	if device.Mounts == nil {
		device.Mounts = []Mount{}
	}
	fingerprint, err := calculateDeviceFingerprint(device)
	if err != nil {
		return Device{}, err
	}
	device.Fingerprint = fingerprint
	return device, nil
}

// validateDevicePaths rejects backend identities that could address ordinary files.
func validateDevicePaths(device Device) error {
	if !validDevicePath(device.Path) {
		return fmt.Errorf("device path %q is not a canonical /dev path", device.Path)
	}
	if !validDevicePath(device.RawPath) {
		return fmt.Errorf("raw device path %q is not a canonical /dev path", device.RawPath)
	}
	return nil
}

// validDevicePath reports whether path is a cleaned absolute descendant of /dev.
func validDevicePath(path string) bool {
	return filepath.IsAbs(path) && path != "/dev" && strings.HasPrefix(path, "/dev/") && filepath.Clean(path) == path
}

// validateWriteTarget applies every non-negotiable removable-media refusal.
func validateWriteTarget(image ImageIdentity, device Device, allowMounted bool) error {
	if err := validateDevicePaths(device); err != nil {
		return err
	}
	storedOnTarget, err := imageStoredOnDevice(image.Path, device)
	if err != nil {
		return fmt.Errorf("verify source-image separation from %s: %w", device.Path, err)
	}
	if storedOnTarget {
		return fmt.Errorf("source image %s is stored on target device %s", image.Path, device.Path)
	}
	if !device.WholeDisk {
		return fmt.Errorf("target %s is not a whole device", device.Path)
	}
	if !device.External {
		return fmt.Errorf("target %s is not external media", device.Path)
	}
	if !device.Removable {
		return fmt.Errorf("target %s is not removable media", device.Path)
	}
	if !device.USB || device.Bus != "usb" {
		return fmt.Errorf("target %s is not USB media", device.Path)
	}
	if device.ReadOnly {
		return fmt.Errorf("target %s is read-only", device.Path)
	}
	if device.System {
		return fmt.Errorf("target %s backs the running system", device.Path)
	}
	if device.InUse {
		return fmt.Errorf("target %s has active non-mount storage consumers", device.Path)
	}
	if device.StableID == "" && device.Serial == "" && device.WWN == "" {
		return fmt.Errorf("target %s lacks stable hardware identity evidence", device.Path)
	}
	if !allowMounted && len(device.Mounts) != 0 {
		return fmt.Errorf("target %s still has %d mounted filesystem(s)", device.Path, len(device.Mounts))
	}
	if device.SizeBytes < image.SizeBytes {
		return fmt.Errorf(
			"target %s is undersized: capacity %d bytes, image %d bytes",
			device.Path,
			device.SizeBytes,
			image.SizeBytes,
		)
	}
	return nil
}

// imageStoredOnDevice checks lexical containment and mounted-filesystem identity.
func imageStoredOnDevice(imagePath string, device Device) (bool, error) {
	for _, mount := range device.Mounts {
		if mount.Point == "" || !filepath.IsAbs(mount.Point) {
			continue
		}
		relative, err := filepath.Rel(mount.Point, imagePath)
		if err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return true, nil
		}
		sameFilesystem, err := pathsShareFilesystem(imagePath, mount.Point)
		if err != nil {
			return false, fmt.Errorf("compare image with mount %s: %w", mount.Point, err)
		}
		if sameFilesystem {
			return true, nil
		}
	}
	return false, nil
}

// isSystemMountPoint treats only conventional removable-media mount roots as
// operator-wipeable; every other live mount fails closed as host storage.
func isSystemMountPoint(point string) bool {
	point = filepath.Clean(point)
	for _, removableRoot := range []string{"/media", "/run/media", "/mnt", "/Volumes"} {
		relative, err := filepath.Rel(removableRoot, point)
		if err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return false
		}
	}
	return true
}

// openedImageStoredOnDevice compares the already-open source descriptor with
// each target mount so a path replacement cannot redirect the safety check.
func openedImageStoredOnDevice(image *os.File, imagePath string, device Device) (bool, error) {
	if image == nil {
		return false, errors.New("opened source image is unavailable")
	}
	for _, mount := range device.Mounts {
		if mount.Point == "" || !filepath.IsAbs(mount.Point) {
			continue
		}
		relative, err := filepath.Rel(mount.Point, imagePath)
		if err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return true, nil
		}
		sameFilesystem, err := fileSharesFilesystem(image, mount.Point)
		if err != nil {
			return false, fmt.Errorf("compare opened image with mount %s: %w", mount.Point, err)
		}
		if sameFilesystem {
			return true, nil
		}
	}
	return false, nil
}

// normaliseUntrustedText trims safe text while rejecting controls and excessive input.
func normaliseUntrustedText(field, value string, maximumBytes int) (string, error) {
	if !utf8.ValidString(value) {
		return "", fmt.Errorf("%s is not valid UTF-8", field)
	}
	if len(value) > maximumBytes {
		return "", fmt.Errorf("%s exceeds %d bytes", field, maximumBytes)
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return "", fmt.Errorf("%s contains a control character", field)
		}
	}
	return strings.TrimSpace(value), nil
}

// validMajorMinor reports whether value contains two bounded decimal device numbers.
func validMajorMinor(value string) bool {
	parts := strings.Split(value, ":")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return false
	}
	for _, part := range parts {
		for _, character := range part {
			if character < '0' || character > '9' {
				return false
			}
		}
		if _, err := strconv.ParseUint(part, 10, 32); err != nil {
			return false
		}
	}
	return true
}

// validDeviceFingerprint reports whether value is one canonical opaque identity.
func validDeviceFingerprint(value string) bool {
	return strings.HasPrefix(value, deviceFingerprintPrefix) && validSHA256(strings.TrimPrefix(value, deviceFingerprintPrefix))
}

// deviceFingerprintFields is the canonical subset used to detect exposed identity drift.
type deviceFingerprintFields struct {
	// Path is the canonical whole-device node.
	Path string `json:"path"`
	// RawPath is the canonical raw whole-device node.
	RawPath string `json:"raw_path"`
	// HardwarePath is the platform topology identity.
	HardwarePath string `json:"hardware_path"`
	// StableID is the strongest stable platform identifier.
	StableID string `json:"stable_id"`
	// MajorMinor is the Linux kernel device-number identity.
	MajorMinor string `json:"major_minor"`
	// Name is the platform's human-readable media identity.
	Name string `json:"name"`
	// Vendor is the reported device vendor.
	Vendor string `json:"vendor"`
	// Model is the reported device model.
	Model string `json:"model"`
	// Serial is the reported device serial number.
	Serial string `json:"serial"`
	// WWN is the reported world-wide name.
	WWN string `json:"wwn"`
	// Bus is the reported lower-case transport.
	Bus string `json:"bus"`
	// SizeBytes is the complete capacity in bytes.
	SizeBytes uint64 `json:"size_bytes"`
	// LogicalBlockSize is the exposed logical block size.
	LogicalBlockSize uint64 `json:"logical_block_size"`
	// PhysicalBlockSize is the exposed physical block size.
	PhysicalBlockSize uint64 `json:"physical_block_size"`
	// WholeDisk records the whole-device classification.
	WholeDisk bool `json:"whole_disk"`
	// External records the external-media classification.
	External bool `json:"external"`
	// Removable records the removable-media classification.
	Removable bool `json:"removable"`
	// USB records the USB-transport classification.
	USB bool `json:"usb"`
}

// calculateDeviceFingerprint hashes all stable identity evidence into an opaque token.
func calculateDeviceFingerprint(device Device) (string, error) {
	fields := deviceFingerprintFields{
		Path: device.Path, RawPath: device.RawPath, HardwarePath: device.HardwarePath,
		StableID: device.StableID, MajorMinor: device.MajorMinor, Vendor: device.Vendor,
		Name: device.Name, Model: device.Model, Serial: device.Serial, WWN: device.WWN, Bus: device.Bus,
		SizeBytes: device.SizeBytes, LogicalBlockSize: device.LogicalBlockSize,
		PhysicalBlockSize: device.PhysicalBlockSize, WholeDisk: device.WholeDisk,
		External: device.External, Removable: device.Removable, USB: device.USB,
	}
	encoded, err := json.Marshal(fields)
	if err != nil {
		return "", fmt.Errorf("encode device identity: %w", err)
	}
	digest := sha256.Sum256(encoded)
	return deviceFingerprintPrefix + hex.EncodeToString(digest[:]), nil
}

// planDigestFields is the canonical plan representation excluding its own ID.
type planDigestFields struct {
	// SchemaVersion identifies the plan contract.
	SchemaVersion int `json:"schema_version"`
	// Image records the immutable source identity.
	Image ImageIdentity `json:"image"`
	// Device records the immutable target snapshot.
	Device Device `json:"device"`
	// ConfirmationPhrase records the exact destructive acknowledgement.
	ConfirmationPhrase string `json:"confirmation_phrase"`
}

// calculatePlanID hashes every safety-relevant plan field.
func calculatePlanID(plan WritePlan) (string, error) {
	encoded, err := json.Marshal(planDigestFields{
		SchemaVersion:      plan.SchemaVersion,
		Image:              plan.Image,
		Device:             plan.Device,
		ConfirmationPhrase: plan.ConfirmationPhrase,
	})
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:]), nil
}

// confirmationPhrase binds destructive acknowledgement to the whole-device
// path, opaque physical identity, and full image digest.
func confirmationPhrase(device Device, image ImageIdentity) string {
	return fmt.Sprintf("ERASE %s DEVICE %s AND WRITE SHA256 %s", device.Path, device.Fingerprint, image.SHA256)
}

// validatePlan rejects edited, malformed, stale-schema, or internally inconsistent plans.
func validatePlan(plan WritePlan) error {
	if plan.SchemaVersion != PlanSchemaVersion {
		return fmt.Errorf("unsupported media write plan schema %d", plan.SchemaVersion)
	}
	if !validSHA256(plan.ID) {
		return errors.New("media write plan ID is not a SHA-256 digest")
	}
	if err := validateImageIdentity(plan.Image); err != nil {
		return errors.New("media write plan contains an invalid image identity")
	}
	normalised, err := normaliseDevice(plan.Device)
	if err != nil {
		return fmt.Errorf("media write plan contains an invalid device: %w", err)
	}
	if !reflect.DeepEqual(normalised, plan.Device) {
		return errors.New("media write plan device is not in canonical form")
	}
	if plan.ConfirmationPhrase != confirmationPhrase(plan.Device, plan.Image) {
		return errors.New("media write plan confirmation phrase is inconsistent")
	}
	if err := validateWriteTarget(plan.Image, plan.Device, true); err != nil {
		return fmt.Errorf("media write plan target is unsafe: %w", err)
	}
	expectedID, err := calculatePlanID(plan)
	if err != nil {
		return fmt.Errorf("recalculate media write plan ID: %w", err)
	}
	if expectedID != plan.ID {
		return errors.New("media write plan was modified after creation")
	}
	return nil
}

// validateImageIdentity rejects unsafe display text and inconsistent canonical paths.
func validateImageIdentity(identity ImageIdentity) error {
	path, err := normaliseUntrustedText("image path", identity.Path, maximumPathBytes)
	if err != nil || path != identity.Path || !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return errors.New("image path is not canonical")
	}
	name, err := normaliseUntrustedText("image name", identity.Name, maximumDisplayBytes)
	if err != nil || name != identity.Name || name != filepath.Base(path) {
		return errors.New("image name is inconsistent")
	}
	if identity.SizeBytes == 0 || !validSHA256(identity.SHA256) {
		return errors.New("image size or SHA-256 is invalid")
	}
	return nil
}

// validSHA256 reports whether value is one lower-case hexadecimal SHA-256 digest.
func validSHA256(value string) bool {
	if len(value) != sha256.Size*2 || strings.ToLower(value) != value {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}

// newReceipt prepares a result that remains useful when execution fails part-way.
func newReceipt(plan WritePlan, dryRun bool) Receipt {
	return Receipt{
		SchemaVersion:     ReceiptSchemaVersion,
		PlanID:            plan.ID,
		Image:             plan.Image,
		DeviceFingerprint: plan.Device.Fingerprint,
		TargetPath:        plan.Device.Path,
		State:             ReceiptStateNotStarted,
		DryRun:            dryRun,
	}
}
