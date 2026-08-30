// Package handoff defines the private, device-bound interchange contract used
// to move authorised Windows evidence into linux-armer without making it an ISO
// inventory or a redistributable userspace release.
package handoff

import (
	"encoding/json"
	"fmt"
	"io"
)

const (
	// SchemaVersion identifies the only current Windows hand-off contract
	// accepted for import and application by this implementation.
	SchemaVersion = 2
	// ContractKind distinguishes this private interchange document from image
	// manifests, userspace receipts, and diagnostic archives.
	ContractKind = "linux-armer.windows-handoff"
	// PrivacyClassification marks the entire document and its payloads as private,
	// device-bound material unsuitable for logs, ISO inclusion, or redistribution.
	PrivacyClassification = "private-device-bound"
	// DeviceBindingDomain is prepended to every salted SMBIOS UUID binding. The
	// terminating NUL prevents concatenation with any future textual domain.
	DeviceBindingDomain = "linux-armer.windows-handoff/device-binding/v1\x00"
	// CollectorName identifies the canonical PowerShell exporter permitted to
	// claim this contract shape.
	CollectorName = "collect-sp11-windows-handoff.ps1"
	// CollectorVersion identifies the sole exporter release permitted to claim
	// the current schema's exact collection and provenance semantics.
	CollectorVersion = "2.0.0"
	// PlatformID identifies the hardware family to which the compiled mappings
	// and Bluetooth policy apply.
	PlatformID = "microsoft-surface-pro-11"
	// Architecture identifies the processor architecture required by this
	// device-bound contract.
	Architecture = "arm64"
	// WiFiPCIID identifies the audited WCN7850 PCI function without claiming
	// that Windows Wi-Fi firmware belongs in this hand-off.
	WiFiPCIID = "17cb:1107"
	// MaximumDocumentSize bounds untrusted JSON before structural decoding.
	MaximumDocumentSize = 1 << 20
	// ManifestFilename is the sole canonical JSON filename at the root of a
	// Windows hand-off source or private store entry.
	ManifestFilename = "linux-armer-windows-handoff.json"
)

// AbsentReason is a stable explanation for deliberately omitted or unavailable
// private data.
type AbsentReason string

const (
	// AbsentReasonNotRequested records that the operator deliberately excluded a
	// section while collecting another one.
	AbsentReasonNotRequested AbsentReason = "not-requested"
	// AbsentReasonUnavailable records that Windows could not provide a complete,
	// unambiguous section.
	AbsentReasonUnavailable AbsentReason = "unavailable"
)

// BluetoothSource identifies the trusted Windows evidence used to select a
// same-device public controller address.
type BluetoothSource string

const (
	// BluetoothSourcePermanentAddress records a Windows network-adapter
	// PermanentAddress selected without deriving it from Wi-Fi.
	BluetoothSourcePermanentAddress BluetoothSource = "net-adapter-permanent-address"
	// BluetoothSourceBTHPORT records a BTHPORT registry candidate explicitly
	// confirmed by the operator against the Bluetooth device.
	BluetoothSourceBTHPORT BluetoothSource = "bthport-registry-operator-confirmed"
)

// BluetoothAddress is a private controller address whose string forms are
// deliberately redacted from ordinary and diagnostic formatting.
type BluetoothAddress string

// String returns a fixed redaction so formatted summaries cannot disclose the
// private controller address accidentally.
func (BluetoothAddress) String() string {
	return "<redacted>"
}

// GoString returns a fixed redaction for detailed Go diagnostic formatting.
func (BluetoothAddress) GoString() string {
	return "handoff.BluetoothAddress(<redacted>)"
}

// Contract is the complete private Windows-to-Linux interchange document.
type Contract struct {
	// SchemaVersion selects the exact decoding and validation contract.
	SchemaVersion int `json:"schema_version"`
	// Kind distinguishes this document from every other linux-armer JSON shape.
	Kind string `json:"kind"`
	// PrivacyClassification requires private handling of the complete document
	// and every payload it identifies.
	PrivacyClassification string `json:"privacy_classification"`
	// CreatedAt is the canonical second-precision UTC collection timestamp.
	CreatedAt string `json:"created_at"`
	// Collector records the exporter that assembled the immutable snapshot.
	Collector CollectorRecord `json:"collector"`
	// Device binds the private material to the audited hardware family and one
	// physical machine.
	Device DeviceRecord `json:"device"`
	// PlatformFirmware carries either the complete eleven-file platform set or
	// an explicit reason for its absence.
	PlatformFirmware PlatformFirmwareSection `json:"platform_firmware"`
	// BluetoothPublicAddress carries either a same-device address or an explicit
	// reason for its absence.
	BluetoothPublicAddress BluetoothPublicAddressSection `json:"bluetooth_public_address"`
}

// CollectorRecord identifies the Windows exporter without treating its claims
// as a Linux-side cryptographic attestation.
type CollectorRecord struct {
	// Name is the canonical PowerShell collector filename.
	Name string `json:"name"`
	// Version is the exact collector release compiled for this schema.
	Version string `json:"version"`
}

// DeviceRecord contains the minimum non-raw hardware identity needed to reject
// accidental cross-device application.
type DeviceRecord struct {
	// PlatformID is the compiled Surface Pro 11 family identifier.
	PlatformID string `json:"platform_id"`
	// Architecture is the canonical Linux architecture name.
	Architecture string `json:"architecture"`
	// BindingSalt is a fresh random 32-byte value encoded as lowercase hexadecimal;
	// a new value makes bindings from separate hand-offs unlinkable.
	BindingSalt string `json:"binding_salt"`
	// SMBIOSProductUUIDBindingSHA256 is the domain-separated SHA-256 over the salt
	// bytes and canonical UUID text, never the raw UUID or its bare digest.
	SMBIOSProductUUIDBindingSHA256 string `json:"smbios_product_uuid_binding_sha256"`
	// WiFiPCIID is applicability evidence for the audited WCN7850 function; it
	// does not authorise importing Windows Wi-Fi payloads.
	WiFiPCIID string `json:"wifi_pci_id"`
}

// PlatformFirmwareSection is a strict union between one complete firmware set
// and an explicit absence record.
type PlatformFirmwareSection struct {
	// Included reports whether the complete compiled firmware set is present.
	Included bool `json:"included"`
	// Reason is required only when Included is false and must use a compiled
	// absence reason.
	Reason *AbsentReason `json:"reason,omitempty"`
	// Files is required only when Included is true and must match the complete
	// compiled set in canonical order.
	Files []FirmwareFileRecord `json:"files,omitempty"`
}

// FirmwareFileRecord describes one copied Windows firmware file, its immutable
// bytes, and the compiled Linux destination it claims to satisfy.
type FirmwareFileRecord struct {
	// ID is the stable identifier from the compiled eleven-file policy.
	ID string `json:"id"`
	// SourceName is the exact filename copied from the Windows DriverStore.
	SourceName string `json:"source_name"`
	// PayloadPath is the canonical relative path beneath the hand-off directory.
	PayloadPath string `json:"payload_path"`
	// Destination is the canonical root-relative Linux installation path and is
	// cross-checked rather than trusted as an instruction.
	Destination string `json:"destination"`
	// Size is the positive byte length of the copied payload.
	Size int64 `json:"size_bytes"`
	// SHA256 is the lowercase hexadecimal digest of the copied payload.
	SHA256 string `json:"sha256"`
	// WindowsSource records the active signed DriverStore evidence selected by
	// the Windows collector.
	WindowsSource WindowsSourceRecord `json:"windows_source"`
}

// WindowsSourceRecord records Windows-side DriverStore provenance while making
// clear that Linux only validates the claim's shape and copied-byte identities.
type WindowsSourceRecord struct {
	// DriverStorePath is a canonical drive-independent path to the selected file
	// beneath Windows/System32/DriverStore/FileRepository.
	DriverStorePath string `json:"driver_store_path"`
	// PublishedINF is the active Windows published driver name, such as oem42.inf.
	PublishedINF string `json:"published_inf"`
	// OriginalINF is the canonical original INF basename compiled into the
	// firmware policy, independent of Windows' mutable oemN.inf alias.
	OriginalINF string `json:"original_inf"`
	// DriverVersion is the bounded numeric Windows driver version.
	DriverVersion string `json:"driver_version"`
	// CatalogueSHA256 is the lowercase digest of the associated Windows driver
	// catalogue observed by the collector.
	CatalogueSHA256 string `json:"catalogue_sha256"`
	// CatalogueSignature is the Windows collector's claimed signature state.
	// Validation requires "valid" but does not independently verify Authenticode.
	CatalogueSignature string `json:"catalogue_signature"`
}

// BluetoothPublicAddressSection is a strict union between one private address
// with provenance and an explicit absence record.
type BluetoothPublicAddressSection struct {
	// Included reports whether a same-device public address is present.
	Included bool `json:"included"`
	// Reason is required only when Included is false and must use a compiled
	// absence reason.
	Reason *AbsentReason `json:"reason,omitempty"`
	// Address is required only when Included is true and remains private even in
	// diagnostic formatting.
	Address *BluetoothAddress `json:"address,omitempty"`
	// Source is required only when Included is true and identifies the Windows
	// evidence selected without deriving an address from Wi-Fi.
	Source *BluetoothSource `json:"source,omitempty"`
}

// Summary is the deliberately non-sensitive view suitable for command output
// and logs.
type Summary struct {
	// SchemaVersion identifies the validated interchange contract.
	SchemaVersion int `json:"schema_version"`
	// Kind identifies the validated hand-off document.
	Kind string `json:"kind"`
	// PrivacyClassification reminds every output consumer that the source
	// contract and payload must remain private.
	PrivacyClassification string `json:"privacy_classification"`
	// PlatformID identifies the validated hardware family.
	PlatformID string `json:"platform_id"`
	// FirmwareIncluded reports whether all compiled firmware files are present.
	FirmwareIncluded bool `json:"firmware_included"`
	// FirmwareFiles is the number of validated firmware payload records.
	FirmwareFiles int `json:"firmware_files"`
	// BluetoothIncluded reports only the presence of private address material.
	BluetoothIncluded bool `json:"bluetooth_included"`
}

// Summary returns a non-sensitive view that never contains the Bluetooth
// address, adapter identity, or device UUID digest.
func (contract Contract) Summary() Summary {
	return Summary{
		SchemaVersion:         contract.SchemaVersion,
		Kind:                  contract.Kind,
		PrivacyClassification: contract.PrivacyClassification,
		PlatformID:            contract.Device.PlatformID,
		FirmwareIncluded:      contract.PlatformFirmware.Included,
		FirmwareFiles:         len(contract.PlatformFirmware.Files),
		BluetoothIncluded:     contract.BluetoothPublicAddress.Included,
	}
}

// WriteJSON validates the complete contract and writes stable, indented JSON
// without HTML escaping.
func (contract Contract) WriteJSON(writer io.Writer) error {
	if writer == nil {
		return fmt.Errorf("write Windows hand-off JSON: writer is nil")
	}
	if err := Validate(contract); err != nil {
		return err
	}
	encoder := json.NewEncoder(writer)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(contract); err != nil {
		return fmt.Errorf("write Windows hand-off JSON: %w", err)
	}
	return nil
}
