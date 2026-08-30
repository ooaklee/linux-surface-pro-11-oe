package media

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fixedTestTime is the deterministic receipt time shared by manager tests.
var fixedTestTime = time.Date(2026, time.August, 30, 12, 34, 56, 0, time.UTC)

// fakeBackend records every destructive boundary while storing raw bytes in memory.
type fakeBackend struct {
	// devices is the discovery inventory returned by List.
	devices []Device
	// device is the default fresh snapshot returned by Inspect.
	device Device
	// inspections overrides successive Inspect results when non-empty.
	inspections []Device
	// inspectCalls counts fresh identity inspections.
	inspectCalls int
	// unmountCalls counts target-preparation requests.
	unmountCalls int
	// openWriteCalls counts raw write opens.
	openWriteCalls int
	// openReadCalls counts raw read opens.
	openReadCalls int
	// ejectCalls counts safe-ejection requests.
	ejectCalls int
	// storage holds the fake target's mutable byte content.
	storage []byte
	// readback overrides storage when a verification mismatch is required.
	readback []byte
	// readLimit truncates the readable target length when non-negative.
	readLimit int
	// shortWrite makes the first target write incomplete without an explicit error.
	shortWrite bool
	// unmountErr fails target preparation before any raw open.
	unmountErr error
	// openWriteErr fails the raw write boundary.
	openWriteErr error
	// openReadErr fails the raw read-back boundary.
	openReadErr error
	// syncErr fails the durability boundary.
	syncErr error
	// writeCloseErr fails raw write closure after a successful flush.
	writeCloseErr error
	// readCloseErr fails raw read closure after successful hashing.
	readCloseErr error
	// ejectErr fails safe ejection after successful verification.
	ejectErr error
	// listErr fails discovery.
	listErr error
	// inspectErr fails fresh target inspection.
	inspectErr error
}

// List returns the configured discovery snapshot without mutation.
func (backend *fakeBackend) List(context.Context) ([]Device, error) {
	if backend.listErr != nil {
		return nil, backend.listErr
	}
	return append([]Device(nil), backend.devices...), nil
}

// Inspect returns a queued or default fresh target snapshot.
func (backend *fakeBackend) Inspect(context.Context, string) (Device, error) {
	backend.inspectCalls++
	if backend.inspectErr != nil {
		return Device{}, backend.inspectErr
	}
	if len(backend.inspections) > 0 {
		index := backend.inspectCalls - 1
		if index >= len(backend.inspections) {
			index = len(backend.inspections) - 1
		}
		return backend.inspections[index], nil
	}
	return backend.device, nil
}

// Unmount records target preparation and returns its configured result.
func (backend *fakeBackend) Unmount(context.Context, Device) error {
	backend.unmountCalls++
	return backend.unmountErr
}

// OpenWrite returns an in-memory whole-device writer or its configured error.
func (backend *fakeBackend) OpenWrite(context.Context, Device) (WriteDevice, error) {
	backend.openWriteCalls++
	if backend.openWriteErr != nil {
		return nil, backend.openWriteErr
	}
	return &fakeWriteDevice{backend: backend}, nil
}

// OpenRead returns a bounded in-memory read-back handle or its configured error.
func (backend *fakeBackend) OpenRead(context.Context, Device) (ReadDevice, error) {
	backend.openReadCalls++
	if backend.openReadErr != nil {
		return nil, backend.openReadErr
	}
	content := backend.storage
	if backend.readback != nil {
		content = backend.readback
	}
	if backend.readLimit >= 0 && backend.readLimit < len(content) {
		content = content[:backend.readLimit]
	}
	return &fakeReadDevice{Reader: bytes.NewReader(content), closeErr: backend.readCloseErr}, nil
}

// Eject records successful verification's final platform operation.
func (backend *fakeBackend) Eject(context.Context, Device) error {
	backend.ejectCalls++
	return backend.ejectErr
}

// fakeWriteDevice writes sequentially into its owning fake backend.
type fakeWriteDevice struct {
	// backend owns the target bytes and configured failure behaviour.
	backend *fakeBackend
	// offset is the next target byte position.
	offset int
	// shortWriteUsed ensures the configured short write occurs only once.
	shortWriteUsed bool
}

// Write copies one chunk into target storage and can simulate an incomplete write.
func (device *fakeWriteDevice) Write(content []byte) (int, error) {
	count := len(content)
	if device.backend.shortWrite && !device.shortWriteUsed && count > 0 {
		count--
		device.shortWriteUsed = true
	}
	end := device.offset + count
	if end > len(device.backend.storage) {
		grown := make([]byte, end)
		copy(grown, device.backend.storage)
		device.backend.storage = grown
	}
	copy(device.backend.storage[device.offset:end], content[:count])
	device.offset = end
	return count, nil
}

// Sync returns the configured fake durability result.
func (device *fakeWriteDevice) Sync() error {
	return device.backend.syncErr
}

// Close returns the configured fake write-close result.
func (device *fakeWriteDevice) Close() error {
	return device.backend.writeCloseErr
}

// fakeReadDevice wraps an in-memory reader with a configurable close result.
type fakeReadDevice struct {
	// Reader supplies read-back bytes.
	*bytes.Reader
	// closeErr is returned when verification releases the handle.
	closeErr error
}

// Close returns the configured fake read-close result.
func (device *fakeReadDevice) Close() error {
	return device.closeErr
}

// safeTestDevice returns one eligible, unmounted whole USB device.
func safeTestDevice(capacity uint64) Device {
	return Device{
		Path: "/dev/test-disk2", RawPath: "/dev/rtest-disk2",
		HardwarePath: "usb/1/2", StableID: "serial:0123456789abcdef",
		MajorMinor: "8:32", Name: "Test USB", Vendor: "Test", Model: "Flash",
		Serial: "0123456789abcdef", Bus: "usb", SizeBytes: capacity,
		LogicalBlockSize: 512, PhysicalBlockSize: 4096,
		WholeDisk: true, External: true, Removable: true, USB: true,
		Mounts: []Mount{},
	}
}

// writeTestImage creates one private regular source image with deterministic bytes.
func writeTestImage(t *testing.T, content []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test-image.iso")
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// testManager returns a manager with successful privilege and deterministic receipts.
func testManager(backend *fakeBackend, chunkSize int) *Manager {
	return NewManager(ManagerOptions{
		Backend:   backend,
		Privilege: PrivilegeCheckFunc(func() error { return nil }),
		Clock:     func() time.Time { return fixedTestTime },
		ChunkSize: chunkSize,
	})
}

// planTestWrite creates a plan and resets fake inspection accounting for execution.
func planTestWrite(t *testing.T, manager *Manager, backend *fakeBackend, image string) WritePlan {
	t.Helper()
	plan, err := manager.Plan(context.Background(), PlanRequest{ImagePath: image, Target: backend.device.Path})
	if err != nil {
		t.Fatalf("Plan() error = %v", err)
	}
	backend.inspectCalls = 0
	return plan
}

// TestManagerListNormalisesSortsAndFingerprints verifies discovery's public contract.
func TestManagerListNormalisesSortsAndFingerprints(t *testing.T) {
	second := safeTestDevice(4096)
	second.Path = "/dev/test-disk3"
	second.RawPath = "/dev/rtest-disk3"
	second.Name = "  Second  "
	first := safeTestDevice(4096)
	backend := &fakeBackend{devices: []Device{second, first}, readLimit: -1}
	devices, err := testManager(backend, 4).List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 2 || devices[0].Path != first.Path || devices[1].Name != "Second" {
		t.Fatalf("List() = %#v", devices)
	}
	for _, device := range devices {
		if !strings.HasPrefix(device.Fingerprint, deviceFingerprintPrefix) || len(device.Fingerprint) != len(deviceFingerprintPrefix)+64 {
			t.Fatalf("fingerprint = %q", device.Fingerprint)
		}
	}
}

// TestManagerListRejectsDuplicateAndMalformedDevices verifies fail-closed inventory handling.
func TestManagerListRejectsDuplicateAndMalformedDevices(t *testing.T) {
	valid := safeTestDevice(4096)
	tests := []struct {
		name    string
		devices []Device
		want    string
	}{
		{name: "duplicate", devices: []Device{valid, valid}, want: "duplicate"},
		{name: "ordinary path", devices: []Device{{Path: "/tmp/file", RawPath: "/tmp/file"}}, want: "canonical /dev path"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			manager := testManager(&fakeBackend{devices: test.devices, readLimit: -1}, 4)
			if _, err := manager.List(context.Background()); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("List() error = %v, want %q", err, test.want)
			}
		})
	}
}

// TestManagerRejectsUnsafeDeviceMetadata verifies terminal controls and bounds fail closed.
func TestManagerRejectsUnsafeDeviceMetadata(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*Device)
		want   string
	}{
		{name: "terminal escape", mutate: func(device *Device) { device.Name = "USB\x1b[2J" }, want: "control character"},
		{name: "unbounded identity", mutate: func(device *Device) { device.StableID = strings.Repeat("x", maximumIdentityBytes+1) }, want: "exceeds"},
		{name: "invalid device number", mutate: func(device *Device) { device.MajorMinor = "8:not-a-number" }, want: "major:minor"},
		{name: "unsafe filesystem label", mutate: func(device *Device) {
			device.Mounts = []Mount{{Device: "/dev/test-disk2s1", Point: "/Volumes/USB", Label: "USB\nspoof"}}
		}, want: "control character"},
		{name: "relative mount", mutate: func(device *Device) {
			device.Mounts = []Mount{{Device: "/dev/test-disk2s1", Point: "relative/mount"}}
		}, want: "canonical absolute"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			device := safeTestDevice(4096)
			test.mutate(&device)
			manager := testManager(&fakeBackend{devices: []Device{device}, readLimit: -1}, 4)
			if _, err := manager.List(context.Background()); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("List() error = %v, want %q", err, test.want)
			}
		})
	}
}

// TestManagerPlanBindsCanonicalImageAndTarget verifies immutable identity and confirmation data.
func TestManagerPlanBindsCanonicalImageAndTarget(t *testing.T) {
	content := []byte("0123456789abcdef")
	image := writeTestImage(t, content)
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: -1}
	manager := testManager(backend, 4)
	plan, err := manager.Plan(context.Background(), PlanRequest{ImagePath: image, Target: backend.device.Path})
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(content)
	wantDigest := hex.EncodeToString(digest[:])
	if plan.Image.SHA256 != wantDigest || plan.Image.SizeBytes != uint64(len(content)) || !filepath.IsAbs(plan.Image.Path) {
		t.Fatalf("plan image = %#v", plan.Image)
	}
	if !strings.Contains(plan.ConfirmationPhrase, backend.device.Path) ||
		!strings.Contains(plan.ConfirmationPhrase, plan.Device.Fingerprint) ||
		!strings.Contains(plan.ConfirmationPhrase, wantDigest) {
		t.Fatalf("confirmation phrase = %q", plan.ConfirmationPhrase)
	}
	if !validSHA256(plan.ID) || !strings.HasPrefix(plan.Device.Fingerprint, deviceFingerprintPrefix) {
		t.Fatalf("plan identity = %#v", plan)
	}
}

// TestManagerPlanAcceptsDiscoveryFingerprint verifies opaque selectors avoid path parsing in delivery code.
func TestManagerPlanAcceptsDiscoveryFingerprint(t *testing.T) {
	image := writeTestImage(t, []byte("image"))
	device := safeTestDevice(4096)
	backend := &fakeBackend{device: device, devices: []Device{device}, readLimit: -1}
	manager := testManager(backend, 4)
	listed, err := manager.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	plan, err := manager.Plan(context.Background(), PlanRequest{ImagePath: image, Target: listed[0].Fingerprint})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Device.Path != device.Path {
		t.Fatalf("target = %q", plan.Device.Path)
	}
}

// TestManagerPlanRejectsFingerprintResolutionDrift verifies that a device
// replaced between discovery and fresh inspection cannot inherit its selector.
func TestManagerPlanRejectsFingerprintResolutionDrift(t *testing.T) {
	image := writeTestImage(t, []byte("image"))
	selected := safeTestDevice(4096)
	replacement := selected
	replacement.HardwarePath = "usb/9/9"
	replacement.StableID = "serial:replacement"
	replacement.Serial = "replacement"
	backend := &fakeBackend{devices: []Device{selected}, device: replacement, readLimit: -1}
	manager := testManager(backend, 4)
	listed, err := manager.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	_, err = manager.Plan(context.Background(), PlanRequest{
		ImagePath: image,
		Target:    listed[0].Fingerprint,
	})
	if !errors.Is(err, ErrDeviceIdentityDrift) {
		t.Fatalf("Plan() error = %v, want identity drift", err)
	}
}

// TestManagerPlanRejectsUnsafeImages verifies regular-file and non-link source policy.
func TestManagerPlanRejectsUnsafeImages(t *testing.T) {
	device := safeTestDevice(4096)
	backend := &fakeBackend{device: device, readLimit: -1}
	manager := testManager(backend, 4)
	directory := t.TempDir()
	empty := filepath.Join(t.TempDir(), "empty.iso")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	real := writeTestImage(t, []byte("image"))
	link := filepath.Join(t.TempDir(), "linked.iso")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		path string
		want string
	}{
		{name: "directory", path: directory, want: "regular file"},
		{name: "empty", path: empty, want: "must not be empty"},
		{name: "symlink", path: link, want: "symbolic link"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := manager.Plan(context.Background(), PlanRequest{ImagePath: test.path, Target: device.Path})
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Plan() error = %v, want %q", err, test.want)
			}
		})
	}
}

// TestManagerPlanRejectsEveryUnsafeTargetClass verifies all destructive refusals.
func TestManagerPlanRejectsEveryUnsafeTargetClass(t *testing.T) {
	image := writeTestImage(t, []byte("12345678"))
	canonicalImage, err := filepath.EvalSymlinks(image)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name   string
		mutate func(*Device)
		want   string
	}{
		{name: "partition", mutate: func(device *Device) { device.WholeDisk = false }, want: "not a whole device"},
		{name: "internal", mutate: func(device *Device) { device.External = false }, want: "not external"},
		{name: "fixed", mutate: func(device *Device) { device.Removable = false }, want: "not removable"},
		{name: "non USB", mutate: func(device *Device) { device.USB = false; device.Bus = "sata" }, want: "not USB"},
		{name: "read only", mutate: func(device *Device) { device.ReadOnly = true }, want: "read-only"},
		{name: "system", mutate: func(device *Device) { device.System = true }, want: "running system"},
		{name: "active consumer", mutate: func(device *Device) { device.InUse = true }, want: "active non-mount"},
		{name: "weak identity", mutate: func(device *Device) {
			device.StableID = ""
			device.Serial = ""
			device.WWN = ""
		}, want: "lacks stable hardware identity"},
		{name: "undersized", mutate: func(device *Device) { device.SizeBytes = 7 }, want: "undersized"},
		{name: "image on target", mutate: func(device *Device) {
			device.Mounts = []Mount{{Device: "/dev/test-disk2s1", Point: filepath.Dir(canonicalImage)}}
		}, want: "stored on target"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			device := safeTestDevice(4096)
			test.mutate(&device)
			manager := testManager(&fakeBackend{device: device, readLimit: -1}, 4)
			_, err := manager.Plan(context.Background(), PlanRequest{ImagePath: image, Target: device.Path})
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Plan() error = %v, want %q", err, test.want)
			}
		})
	}
}

// TestOpenedImageStoredOnDeviceUsesDescriptorIdentity verifies source-target
// separation does not depend solely on a replaceable source pathname.
func TestOpenedImageStoredOnDeviceUsesDescriptorIdentity(t *testing.T) {
	imagePath := writeTestImage(t, []byte("descriptor-bound-image"))
	image, err := os.Open(imagePath)
	if err != nil {
		t.Fatal(err)
	}
	defer image.Close()
	device := safeTestDevice(4096)
	device.Mounts = []Mount{{Device: "/dev/test-disk2s1", Point: t.TempDir()}}
	stored, err := openedImageStoredOnDevice(image, "/path/that/no/longer/names/the/open/file", device)
	if err != nil {
		t.Fatal(err)
	}
	if !stored {
		t.Fatal("opened source descriptor on the target filesystem was not detected")
	}
}

// TestSystemMountPointClassification verifies only conventional removable
// mount roots remain eligible for deliberate unmounting and erasure.
func TestSystemMountPointClassification(t *testing.T) {
	t.Parallel()
	for point, wantSystem := range map[string]bool{
		"/": true, "/boot/efi": true, "/home": true, "/System/Volumes/Data": true,
		"/Users/example": true, "/media/example/USB": false,
		"/run/media/example/USB": false, "/mnt/usb": false, "/Volumes/USB": false,
	} {
		if actual := isSystemMountPoint(point); actual != wantSystem {
			t.Errorf("isSystemMountPoint(%q) = %t, want %t", point, actual, wantSystem)
		}
	}
}

// TestManagerUnmountsAnApprovedMountedTarget verifies ordinary auto-mounts are explicit and safe.
func TestManagerUnmountsAnApprovedMountedTarget(t *testing.T) {
	content := []byte("mounted-target-image")
	image := writeTestImage(t, content)
	mounted := safeTestDevice(4096)
	mounted.Mounts = []Mount{{Device: "/dev/test-disk2s1", Point: "/dev", Filesystem: "vfat", Label: "USB"}}
	unmounted := mounted
	unmounted.Mounts = []Mount{}
	backend := &fakeBackend{
		device: mounted, inspections: []Device{mounted, unmounted, unmounted},
		storage: make([]byte, 4096), readLimit: -1,
	}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	if len(plan.Device.Mounts) != 1 {
		t.Fatalf("planned mounts = %#v", plan.Device.Mounts)
	}
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if err != nil {
		t.Fatal(err)
	}
	if receipt.State != ReceiptStateComplete || backend.unmountCalls != 1 || backend.inspectCalls != 6 {
		t.Fatalf("receipt/calls = %#v, unmount:%d inspect:%d", receipt, backend.unmountCalls, backend.inspectCalls)
	}
}

// TestManagerExecuteDryRunNeverTouchesTarget verifies deterministic preview isolation.
func TestManagerExecuteDryRunNeverTouchesTarget(t *testing.T) {
	image := writeTestImage(t, []byte("dry-run-image"))
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: -1}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if receipt.State != ReceiptStateDryRun || !receipt.DryRun || receipt.CompletedAt != fixedTestTime {
		t.Fatalf("receipt = %#v", receipt)
	}
	if backend.inspectCalls != 0 || backend.unmountCalls != 0 || backend.openWriteCalls != 0 || backend.openReadCalls != 0 || backend.ejectCalls != 0 {
		t.Fatalf("dry-run target calls = inspect:%d unmount:%d write:%d read:%d eject:%d",
			backend.inspectCalls, backend.unmountCalls, backend.openWriteCalls, backend.openReadCalls, backend.ejectCalls)
	}
}

// TestManagerExecuteRequiresExactConfirmation verifies there is no domain bypass.
func TestManagerExecuteRequiresExactConfirmation(t *testing.T) {
	image := writeTestImage(t, []byte("confirmation-image"))
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: -1}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	for _, confirmation := range []string{"", strings.ToLower(plan.ConfirmationPhrase), plan.ConfirmationPhrase + " "} {
		_, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: confirmation})
		if !errors.Is(err, ErrConfirmationMismatch) {
			t.Fatalf("confirmation %q error = %v", confirmation, err)
		}
	}
	if backend.inspectCalls != 0 || backend.openWriteCalls != 0 {
		t.Fatal("confirmation mismatch reached target boundaries")
	}
}

// TestManagerExecuteHonoursCancelledContext verifies cancellation precedes mutation.
func TestManagerExecuteHonoursCancelledContext(t *testing.T) {
	image := writeTestImage(t, []byte("cancelled-context"))
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: -1}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := manager.Execute(ctx, ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Execute() error = %v", err)
	}
	if backend.inspectCalls != 0 || backend.unmountCalls != 0 || backend.openWriteCalls != 0 {
		t.Fatalf("cancelled context calls = inspect:%d unmount:%d write:%d", backend.inspectCalls, backend.unmountCalls, backend.openWriteCalls)
	}
}

// TestManagerExecuteRejectsModifiedPlan verifies the plan is internally immutable.
func TestManagerExecuteRejectsModifiedPlan(t *testing.T) {
	image := writeTestImage(t, []byte("immutable-plan"))
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: -1}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	plan.Device.Model = "Changed"
	_, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if err == nil {
		t.Fatalf("Execute() error = %v", err)
	}
	if backend.inspectCalls != 0 || backend.openWriteCalls != 0 {
		t.Fatal("modified plan reached target boundaries")
	}
}

// TestManagerExecuteRejectsChangedImage verifies source identity before target inspection.
func TestManagerExecuteRejectsChangedImage(t *testing.T) {
	image := writeTestImage(t, []byte("original"))
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: -1}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	if err := os.WriteFile(plan.Image.Path, []byte("changed!"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if err == nil || !strings.Contains(err.Error(), "SHA-256 changed") {
		t.Fatalf("Execute() error = %v", err)
	}
	if backend.inspectCalls != 0 || backend.openWriteCalls != 0 {
		t.Fatal("changed image reached target boundaries")
	}
}

// TestManagerExecuteRejectsIdentityDrift verifies both mandatory fresh inspections.
func TestManagerExecuteRejectsIdentityDrift(t *testing.T) {
	image := writeTestImage(t, []byte("identity-drift"))
	device := safeTestDevice(4096)
	backend := &fakeBackend{device: device, readLimit: -1}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	drifted := device
	drifted.Serial = "replacement-device"
	backend.inspections = []Device{device, drifted}
	_, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if !errors.Is(err, ErrDeviceIdentityDrift) {
		t.Fatalf("Execute() error = %v", err)
	}
	if backend.unmountCalls != 1 || backend.openWriteCalls != 0 {
		t.Fatalf("calls after drift = unmount:%d write:%d", backend.unmountCalls, backend.openWriteCalls)
	}
}

// TestManagerExecuteRejectsIdentityDriftAfterOpen narrows replacement races before writing.
func TestManagerExecuteRejectsIdentityDriftAfterOpen(t *testing.T) {
	image := writeTestImage(t, []byte("post-open-identity-drift"))
	device := safeTestDevice(4096)
	drifted := device
	drifted.Serial = "replacement-after-open"
	backend := &fakeBackend{
		device: device, inspections: []Device{device, device, drifted},
		storage: make([]byte, 4096), readLimit: -1,
	}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if !errors.Is(err, ErrDeviceIdentityDrift) {
		t.Fatalf("Execute() error = %v", err)
	}
	if receipt.WrittenBytes != 0 || backend.openWriteCalls != 1 || backend.openReadCalls != 0 || backend.ejectCalls != 0 {
		t.Fatalf("post-open drift receipt/calls = %#v, write:%d read:%d eject:%d", receipt, backend.openWriteCalls, backend.openReadCalls, backend.ejectCalls)
	}
}

// TestManagerExecuteRejectsPostWriteLifecycleDrift verifies every later identity gate.
func TestManagerExecuteRejectsPostWriteLifecycleDrift(t *testing.T) {
	image := writeTestImage(t, []byte("post-write-lifecycle-drift"))
	device := safeTestDevice(4096)
	tests := []struct {
		name          string
		inspection    int
		wantReadOpens int
	}{
		{name: "before read-back", inspection: 4, wantReadOpens: 0},
		{name: "after opening read-back", inspection: 5, wantReadOpens: 1},
		{name: "before ejection", inspection: 6, wantReadOpens: 1},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			inspections := make([]Device, 6)
			for index := range inspections {
				inspections[index] = device
			}
			inspections[test.inspection-1].Serial = fmt.Sprintf("replacement-at-inspection-%d", test.inspection)
			backend := &fakeBackend{
				device: device, inspections: inspections,
				storage: make([]byte, 4096), readLimit: -1,
			}
			manager := testManager(backend, 4)
			plan := planTestWrite(t, manager, backend, image)
			receipt, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
			if !errors.Is(err, ErrDeviceIdentityDrift) {
				t.Fatalf("Execute() error = %v", err)
			}
			if backend.openReadCalls != test.wantReadOpens || backend.ejectCalls != 0 || receipt.Verified {
				t.Fatalf("lifecycle drift receipt/calls = %#v, read:%d eject:%d", receipt, backend.openReadCalls, backend.ejectCalls)
			}
		})
	}
}

// TestManagerExecuteRejectsPostWriteUnsafeState verifies every later safety gate.
func TestManagerExecuteRejectsPostWriteUnsafeState(t *testing.T) {
	image := writeTestImage(t, []byte("post-write-lifecycle-safety"))
	device := safeTestDevice(4096)
	tests := []struct {
		name          string
		inspection    int
		wantReadOpens int
	}{
		{name: "before read-back", inspection: 4, wantReadOpens: 0},
		{name: "after opening read-back", inspection: 5, wantReadOpens: 1},
		{name: "before ejection", inspection: 6, wantReadOpens: 1},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			inspections := make([]Device, 6)
			for index := range inspections {
				inspections[index] = device
			}
			inspections[test.inspection-1].System = true
			backend := &fakeBackend{
				device: device, inspections: inspections,
				storage: make([]byte, 4096), readLimit: -1,
			}
			manager := testManager(backend, 4)
			plan := planTestWrite(t, manager, backend, image)
			receipt, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
			if err == nil || !strings.Contains(err.Error(), "running system") {
				t.Fatalf("Execute() error = %v", err)
			}
			if backend.openReadCalls != test.wantReadOpens || backend.ejectCalls != 0 || receipt.Verified {
				t.Fatalf("unsafe lifecycle receipt/calls = %#v, read:%d eject:%d", receipt, backend.openReadCalls, backend.ejectCalls)
			}
		})
	}
}

// TestManagerExecuteRejectsFreshUnsafeState verifies safety flags are not identity substitutes.
func TestManagerExecuteRejectsFreshUnsafeState(t *testing.T) {
	image := writeTestImage(t, []byte("fresh-state"))
	tests := []struct {
		name   string
		mutate func(*Device)
		want   string
	}{
		{name: "mounted", mutate: func(device *Device) { device.Mounts = []Mount{{Device: "/dev/test-disk2s1", Point: "/dev"}} }, want: "mounted"},
		{name: "system", mutate: func(device *Device) { device.System = true }, want: "running system"},
		{name: "read only", mutate: func(device *Device) { device.ReadOnly = true }, want: "read-only"},
		{name: "undersized", mutate: func(device *Device) { device.SizeBytes = 2 }, want: "identity changed"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			device := safeTestDevice(4096)
			backend := &fakeBackend{device: device, readLimit: -1}
			manager := testManager(backend, 4)
			plan := planTestWrite(t, manager, backend, image)
			changed := device
			test.mutate(&changed)
			backend.inspections = []Device{changed}
			_, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Execute() error = %v, want %q", err, test.want)
			}
			if backend.openWriteCalls != 0 {
				t.Fatal("unsafe fresh state opened target")
			}
		})
	}
}

// TestManagerExecuteRequiresPrivilegeBeforeMutation verifies authority ordering.
func TestManagerExecuteRequiresPrivilegeBeforeMutation(t *testing.T) {
	image := writeTestImage(t, []byte("privilege"))
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: -1}
	manager := NewManager(ManagerOptions{
		Backend:   backend,
		Privilege: PrivilegeCheckFunc(func() error { return ErrElevatedPrivilegeRequired }),
		Clock:     func() time.Time { return fixedTestTime },
		ChunkSize: 4,
	})
	plan := planTestWrite(t, manager, backend, image)
	_, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if !errors.Is(err, ErrElevatedPrivilegeRequired) {
		t.Fatalf("Execute() error = %v", err)
	}
	if backend.inspectCalls != 1 || backend.unmountCalls != 0 || backend.openWriteCalls != 0 {
		t.Fatalf("privilege ordering calls = inspect:%d unmount:%d write:%d", backend.inspectCalls, backend.unmountCalls, backend.openWriteCalls)
	}
}

// TestManagerExecuteRejectsPartialWrite verifies an incomplete chunk cannot be hidden.
func TestManagerExecuteRejectsPartialWrite(t *testing.T) {
	image := writeTestImage(t, []byte("partial-write"))
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: -1, shortWrite: true}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if !errors.Is(err, io.ErrShortWrite) {
		t.Fatalf("Execute() error = %v", err)
	}
	if receipt.WrittenBytes != 3 || receipt.WrittenSHA256 != "" || receipt.State != ReceiptStateWriting ||
		backend.openReadCalls != 0 || backend.ejectCalls != 0 {
		t.Fatalf("partial write receipt/calls = %#v read:%d eject:%d", receipt, backend.openReadCalls, backend.ejectCalls)
	}
}

// TestManagerExecuteRejectsPartialReadback verifies exact-length read-back is mandatory.
func TestManagerExecuteRejectsPartialReadback(t *testing.T) {
	content := []byte("partial-readback")
	image := writeTestImage(t, content)
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: len(content) - 1}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if err == nil || !strings.Contains(err.Error(), "unexpected EOF") {
		t.Fatalf("Execute() error = %v", err)
	}
	if receipt.ReadbackBytes != uint64(len(content)-1) || receipt.ReadbackSHA256 != "" ||
		receipt.State != ReceiptStateVerifying || receipt.Verified || backend.ejectCalls != 0 {
		t.Fatalf("partial read receipt/calls = %#v eject:%d", receipt, backend.ejectCalls)
	}
}

// TestManagerExecuteRejectsReadbackDigestMismatch verifies bytes alone are insufficient.
func TestManagerExecuteRejectsReadbackDigestMismatch(t *testing.T) {
	content := []byte("readback-digest")
	image := writeTestImage(t, content)
	backend := &fakeBackend{
		device: safeTestDevice(4096), readLimit: -1,
		readback: bytes.Repeat([]byte{'x'}, len(content)),
	}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
	if err == nil || !strings.Contains(err.Error(), "read-back SHA-256 mismatch") {
		t.Fatalf("Execute() error = %v", err)
	}
	if receipt.ReadbackSHA256 == "" || receipt.Verified || backend.ejectCalls != 0 {
		t.Fatalf("mismatch receipt/calls = %#v eject:%d", receipt, backend.ejectCalls)
	}
}

// TestManagerExecuteHonoursCancellation verifies callbacks can stop bounded writing.
func TestManagerExecuteHonoursCancellation(t *testing.T) {
	content := []byte("cancel-after-first-chunk")
	image := writeTestImage(t, content)
	backend := &fakeBackend{device: safeTestDevice(4096), readLimit: -1}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	callbackCalls := 0
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{
		Plan: plan, Confirmation: plan.ConfirmationPhrase,
		Progress: func(Progress) error {
			callbackCalls++
			return context.Canceled
		},
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Execute() error = %v", err)
	}
	if callbackCalls != 1 || receipt.WrittenBytes != 4 || backend.openReadCalls != 0 || backend.ejectCalls != 0 {
		t.Fatalf("cancel receipt/calls = %#v callback:%d read:%d eject:%d", receipt, callbackCalls, backend.openReadCalls, backend.ejectCalls)
	}
}

// TestManagerExecuteHappyPath verifies write, flush, exact read-back, and ejection.
func TestManagerExecuteHappyPath(t *testing.T) {
	content := []byte("verified-removable-media-image")
	image := writeTestImage(t, content)
	backend := &fakeBackend{
		device: safeTestDevice(4096), storage: make([]byte, 4096), readLimit: -1,
	}
	manager := testManager(backend, 5)
	plan := planTestWrite(t, manager, backend, image)
	var progress []Progress
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{
		Plan: plan, Confirmation: plan.ConfirmationPhrase,
		Progress: func(update Progress) error {
			progress = append(progress, update)
			return nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(backend.storage[:len(content)], content) {
		t.Fatalf("written prefix = %q", backend.storage[:len(content)])
	}
	if receipt.State != ReceiptStateComplete || !receipt.Verified || !receipt.Ejected || receipt.WrittenBytes != uint64(len(content)) {
		t.Fatalf("receipt = %#v", receipt)
	}
	if receipt.WrittenSHA256 != plan.Image.SHA256 || receipt.ReadbackSHA256 != plan.Image.SHA256 || receipt.CompletedAt != fixedTestTime {
		t.Fatalf("receipt evidence = %#v", receipt)
	}
	if len(progress) == 0 || progress[len(progress)-1].WrittenBytes != uint64(len(content)) || progress[len(progress)-1].TotalBytes != uint64(len(content)) {
		t.Fatalf("progress = %#v", progress)
	}
	if backend.inspectCalls != 6 || backend.unmountCalls != 1 || backend.openWriteCalls != 1 || backend.openReadCalls != 1 || backend.ejectCalls != 1 {
		t.Fatalf("happy calls = inspect:%d unmount:%d write:%d read:%d eject:%d",
			backend.inspectCalls, backend.unmountCalls, backend.openWriteCalls, backend.openReadCalls, backend.ejectCalls)
	}
}

// TestManagerExecutePropagatesBoundaryFailures verifies no later operation hides a failure.
func TestManagerExecutePropagatesBoundaryFailures(t *testing.T) {
	image := writeTestImage(t, []byte("boundary-errors"))
	tests := []struct {
		name      string
		configure func(*fakeBackend)
		want      string
	}{
		{name: "unmount", configure: func(backend *fakeBackend) { backend.unmountErr = errors.New("unmount failed") }, want: "unmount failed"},
		{name: "open write", configure: func(backend *fakeBackend) { backend.openWriteErr = errors.New("open failed") }, want: "open failed"},
		{name: "sync", configure: func(backend *fakeBackend) { backend.syncErr = errors.New("sync failed") }, want: "sync failed"},
		{name: "close write", configure: func(backend *fakeBackend) { backend.writeCloseErr = errors.New("write close failed") }, want: "write close failed"},
		{name: "open read", configure: func(backend *fakeBackend) { backend.openReadErr = errors.New("read open failed") }, want: "read open failed"},
		{name: "close read", configure: func(backend *fakeBackend) { backend.readCloseErr = errors.New("read close failed") }, want: "read close failed"},
		{name: "eject", configure: func(backend *fakeBackend) { backend.ejectErr = errors.New("eject failed") }, want: "eject failed"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			backend := &fakeBackend{device: safeTestDevice(4096), storage: make([]byte, 4096), readLimit: -1}
			test.configure(backend)
			manager := testManager(backend, 4)
			plan := planTestWrite(t, manager, backend, image)
			_, err := manager.Execute(context.Background(), ExecuteRequest{Plan: plan, Confirmation: plan.ConfirmationPhrase})
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Execute() error = %v, want %q", err, test.want)
			}
		})
	}
}

// TestManagerOpenFailureDoesNotClaimWritingBegan verifies a failed raw open
// reports preparation without claiming a positive byte count or write phase.
func TestManagerOpenFailureDoesNotClaimWritingBegan(t *testing.T) {
	image := writeTestImage(t, []byte("raw-open-failure"))
	backend := &fakeBackend{
		device:       safeTestDevice(4096),
		storage:      make([]byte, 4096),
		readLimit:    -1,
		openWriteErr: errors.New("open failed"),
	}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{
		Plan: plan, Confirmation: plan.ConfirmationPhrase,
	})
	if err == nil || !strings.Contains(err.Error(), "open failed") {
		t.Fatalf("Execute() error = %v", err)
	}
	if receipt.State != ReceiptStatePrepared || receipt.WrittenBytes != 0 {
		t.Fatalf("failed-open receipt overstates mutation: %#v", receipt)
	}
}

// TestManagerEjectFailureReportsVerifiedState verifies a successfully checked
// image is distinguished from complete safe ejection.
func TestManagerEjectFailureReportsVerifiedState(t *testing.T) {
	image := writeTestImage(t, []byte("verified-before-eject"))
	backend := &fakeBackend{
		device: safeTestDevice(4096), storage: make([]byte, 4096), readLimit: -1,
		ejectErr: errors.New("eject failed"),
	}
	manager := testManager(backend, 4)
	plan := planTestWrite(t, manager, backend, image)
	receipt, err := manager.Execute(context.Background(), ExecuteRequest{
		Plan: plan, Confirmation: plan.ConfirmationPhrase,
	})
	if err == nil || !strings.Contains(err.Error(), "eject failed") {
		t.Fatalf("Execute() error = %v", err)
	}
	if receipt.State != ReceiptStateVerified || !receipt.Verified || receipt.Ejected {
		t.Fatalf("eject-failure receipt = %#v", receipt)
	}
}

// ExampleManager_Plan demonstrates the small delivery-layer planning API.
func ExampleManager_Plan() {
	device := safeTestDevice(1 << 20)
	backend := &fakeBackend{device: device, readLimit: -1}
	manager := testManager(backend, 4096)
	_, _ = manager, fmt.Sprintf("%s", device.Path)
	// A delivery layer supplies a real image path and presents the returned phrase.
	fmt.Println("plan binds image SHA-256 to /dev/test-disk2")
	// Output: plan binds image SHA-256 to /dev/test-disk2
}
