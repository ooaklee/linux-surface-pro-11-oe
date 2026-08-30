// Package media provides distribution-neutral removable-media discovery,
// planning, writing, and read-back verification.
package media

import "time"

const (
	// PlanSchemaVersion identifies the current immutable write-plan contract.
	PlanSchemaVersion = 1
	// ReceiptSchemaVersion identifies the current media-write receipt contract.
	ReceiptSchemaVersion = 1
)

const (
	// ReceiptStateNotStarted reports that target preparation has not completed.
	ReceiptStateNotStarted = "not-started"
	// ReceiptStateDryRun reports that execution stopped after validating a preview.
	ReceiptStateDryRun = "dry-run"
	// ReceiptStatePrepared reports that target preparation completed without writing bytes.
	ReceiptStatePrepared = "prepared"
	// ReceiptStateWriting reports that target mutation began but did not complete.
	ReceiptStateWriting = "writing"
	// ReceiptStateWritten reports that the complete write was flushed and closed.
	ReceiptStateWritten = "written"
	// ReceiptStateVerifying reports that read-back began but did not prove the image.
	ReceiptStateVerifying = "verifying"
	// ReceiptStateVerified reports that exact read-back succeeded but ejection did not.
	ReceiptStateVerified = "verified"
	// ReceiptStateComplete reports that write, verification, and ejection succeeded.
	ReceiptStateComplete = "complete"
)

// Mount describes one filesystem mounted from a device or one of its children.
type Mount struct {
	// Device is the operating-system node that supplies the mounted filesystem.
	Device string `json:"device"`
	// Point is the absolute directory at which the filesystem is mounted.
	Point string `json:"point"`
	// Filesystem is the reported filesystem type when one is available.
	Filesystem string `json:"filesystem,omitempty"`
	// Label is the filesystem's human-readable label when one is available.
	Label string `json:"label,omitempty"`
	// ReadOnly reports whether the mounted filesystem is read-only.
	ReadOnly bool `json:"read_only"`
}

// Device describes one whole storage device and the evidence used to assess it.
type Device struct {
	// Fingerprint is an opaque SHA-256 identity issued from normalised device evidence.
	Fingerprint string `json:"fingerprint"`
	// Path is the canonical operating-system path for the whole device.
	Path string `json:"path"`
	// RawPath is the path opened for unbuffered or direct whole-device access.
	RawPath string `json:"raw_path"`
	// HardwarePath is the strongest topology path exposed by the operating system.
	HardwarePath string `json:"hardware_path,omitempty"`
	// StableID is an operating-system or media identifier when one is available.
	StableID string `json:"stable_id,omitempty"`
	// MajorMinor is the Linux kernel major-and-minor device identity when available.
	MajorMinor string `json:"major_minor,omitempty"`
	// Name is a concise human-readable name for the device.
	Name string `json:"name"`
	// Vendor is the device vendor reported by the operating system.
	Vendor string `json:"vendor,omitempty"`
	// Model is the device model reported by the operating system.
	Model string `json:"model,omitempty"`
	// Serial is the device serial number when the platform exposes it.
	Serial string `json:"serial,omitempty"`
	// WWN is the device world-wide name when the platform exposes it.
	WWN string `json:"wwn,omitempty"`
	// Bus is the lower-case transport name reported for the device.
	Bus string `json:"bus"`
	// SizeBytes is the complete device capacity in bytes.
	SizeBytes uint64 `json:"size_bytes"`
	// LogicalBlockSize is the device's logical block size in bytes when known.
	LogicalBlockSize uint64 `json:"logical_block_size,omitempty"`
	// PhysicalBlockSize is the device's physical block size in bytes when known.
	PhysicalBlockSize uint64 `json:"physical_block_size,omitempty"`
	// WholeDisk reports whether Path represents a whole device rather than a partition.
	WholeDisk bool `json:"whole_disk"`
	// External reports whether the platform classifies the device as external.
	External bool `json:"external"`
	// Removable reports whether the platform classifies the media as removable.
	Removable bool `json:"removable"`
	// USB reports whether the device uses the USB transport.
	USB bool `json:"usb"`
	// ReadOnly reports whether the whole device refuses writes.
	ReadOnly bool `json:"read_only"`
	// System reports whether the running system is backed by this device.
	System bool `json:"system"`
	// InUse reports whether swap, mapped storage, RAID, or another non-mount
	// consumer is active below this device.
	InUse bool `json:"in_use"`
	// Mounts lists mounted filesystems backed by the device or its children.
	Mounts []Mount `json:"mounts"`
}

// ImageIdentity binds a canonical regular image file to its exact byte identity.
type ImageIdentity struct {
	// Path is the canonical absolute image path with parent links resolved.
	Path string `json:"path"`
	// Name is the final filename presented in plans and confirmations.
	Name string `json:"name"`
	// SizeBytes is the exact image length in bytes.
	SizeBytes uint64 `json:"size_bytes"`
	// SHA256 is the lower-case hexadecimal SHA-256 digest of the complete image.
	SHA256 string `json:"sha256"`
}

// WritePlan is an immutable snapshot binding an image to one removable device.
type WritePlan struct {
	// SchemaVersion identifies the serialised plan contract.
	SchemaVersion int `json:"schema_version"`
	// ID is the SHA-256 digest of every safety-relevant plan field.
	ID string `json:"id"`
	// Image records the canonical source identity established during planning.
	Image ImageIdentity `json:"image"`
	// Device records the complete inspected target snapshot established during planning.
	Device Device `json:"device"`
	// ConfirmationPhrase is the exact path-, device-identity-, and image-bound
	// phrase execution requires.
	ConfirmationPhrase string `json:"confirmation_phrase"`
}

// PlanRequest contains the two explicit inputs needed to create a write plan.
type PlanRequest struct {
	// ImagePath selects the source image without permitting a symbolic-link leaf.
	ImagePath string `json:"image_path"`
	// Target selects a whole device by canonical path or opaque fingerprint.
	Target string `json:"target"`
}

// Progress reports verified forward movement through the bounded write loop.
type Progress struct {
	// WrittenBytes is the number of complete source bytes written so far.
	WrittenBytes uint64 `json:"written_bytes"`
	// TotalBytes is the immutable image length from the write plan.
	TotalBytes uint64 `json:"total_bytes"`
}

// ExecuteRequest supplies one immutable plan and its interactive confirmation.
type ExecuteRequest struct {
	// Plan is the write plan whose internal digest and current inputs are revalidated.
	Plan WritePlan `json:"plan"`
	// Confirmation must exactly equal Plan.ConfirmationPhrase for real execution.
	Confirmation string `json:"confirmation,omitempty"`
	// DryRun returns a receipt without unmounting, opening, writing, or ejecting media.
	DryRun bool `json:"dry_run"`
	// Progress receives bounded write progress and may stop execution by returning an error.
	Progress ProgressCallback `json:"-"`
}

// Receipt records the evidence produced by one dry-run or destructive execution.
type Receipt struct {
	// SchemaVersion identifies the serialised receipt contract.
	SchemaVersion int `json:"schema_version"`
	// PlanID identifies the exact immutable plan that was executed.
	PlanID string `json:"plan_id"`
	// State records the furthest durable phase reached by execution.
	State string `json:"state"`
	// Image records the exact source identity used for the operation.
	Image ImageIdentity `json:"image"`
	// DeviceFingerprint records the opaque target identity revalidated before writing.
	DeviceFingerprint string `json:"device_fingerprint"`
	// TargetPath records the canonical whole-device path that was opened.
	TargetPath string `json:"target_path"`
	// WrittenBytes records how many source bytes were completely written.
	WrittenBytes uint64 `json:"written_bytes"`
	// WrittenSHA256 records the digest observed while source bytes were written.
	WrittenSHA256 string `json:"written_sha256,omitempty"`
	// ReadbackBytes records how many target bytes were completely read back.
	ReadbackBytes uint64 `json:"readback_bytes"`
	// ReadbackSHA256 records the digest read back over exactly the source length.
	ReadbackSHA256 string `json:"readback_sha256,omitempty"`
	// Verified reports whether written and read-back digests matched the plan.
	Verified bool `json:"verified"`
	// Ejected reports whether the platform completed its safe-ejection operation.
	Ejected bool `json:"ejected"`
	// DryRun reports whether the operation intentionally performed no target mutation.
	DryRun bool `json:"dry_run"`
	// CompletedAt records when the returned receipt was finalised.
	CompletedAt time.Time `json:"completed_at"`
}
