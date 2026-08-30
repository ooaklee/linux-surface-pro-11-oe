package handoff

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"reflect"
	"strings"
	"unicode/utf8"
)

const (
	// legacyStoreSchemaVersion is the retired pre-release schema accepted only
	// for redacted inventory and verified purge of an existing private entry.
	legacyStoreSchemaVersion = 1
	// legacyStoreCollectorVersion identifies the sole historical exporter release
	// whose entries may be listed and purged through the maintenance decoder.
	legacyStoreCollectorVersion = "1.0.0"
)

// legacyStoreContractV1 is the exact retired schema retained solely so an
// operator can inspect and safely purge an already imported private entry.
type legacyStoreContractV1 struct {
	// SchemaVersion must identify the retired version 1 contract.
	SchemaVersion int `json:"schema_version"`
	// Kind must retain the canonical Windows hand-off kind.
	Kind string `json:"kind"`
	// PrivacyClassification must mark every byte as private device material.
	PrivacyClassification string `json:"privacy_classification"`
	// CreatedAt is the canonical second-precision UTC collection time.
	CreatedAt string `json:"created_at"`
	// Collector records the bounded historical collector identity.
	Collector CollectorRecord `json:"collector"`
	// Device retains the salted same-device binding used by the retired contract.
	Device DeviceRecord `json:"device"`
	// PlatformFirmware is the exact historical all-or-absent firmware union.
	PlatformFirmware legacyStorePlatformFirmwareSection `json:"platform_firmware"`
	// BluetoothPublicAddress is the exact historical private address union.
	BluetoothPublicAddress legacyStoreBluetoothSection `json:"bluetooth_public_address"`
}

// legacyStorePlatformFirmwareSection is the retired strict union between a
// complete eleven-file payload and one compiled absence reason.
type legacyStorePlatformFirmwareSection struct {
	// Included reports whether the complete historical payload is present.
	Included bool `json:"included"`
	// Reason is present only for an absent payload.
	Reason *AbsentReason `json:"reason,omitempty"`
	// Files contains the canonical historical records only when included.
	Files []legacyStoreFirmwareFileRecord `json:"files,omitempty"`
}

// legacyStoreFirmwareFileRecord describes one historical payload and the exact
// byte identity needed for closed-set verification before deletion.
type legacyStoreFirmwareFileRecord struct {
	// ID is the compiled firmware policy identifier.
	ID string `json:"id"`
	// SourceName is the historical DriverStore source filename.
	SourceName string `json:"source_name"`
	// PayloadPath is the canonical entry-relative stored path.
	PayloadPath string `json:"payload_path"`
	// Destination is the compiled root-relative Linux destination.
	Destination string `json:"destination"`
	// Size is the expected positive payload length.
	Size int64 `json:"size_bytes"`
	// SHA256 is the expected lowercase payload digest.
	SHA256 string `json:"sha256"`
	// WindowsSource is the exact retired provenance shape without original-INF
	// authority.
	WindowsSource legacyStoreWindowsSourceRecord `json:"windows_source"`
}

// legacyStoreWindowsSourceRecord is the exact version 1 DriverStore evidence
// retained for validation only and never treated as current selection authority.
type legacyStoreWindowsSourceRecord struct {
	// DriverStorePath is the canonical drive-independent historical source path.
	DriverStorePath string `json:"driver_store_path"`
	// PublishedINF is the bounded mutable Windows driver alias.
	PublishedINF string `json:"published_inf"`
	// DriverVersion is the bounded numeric Windows driver version.
	DriverVersion string `json:"driver_version"`
	// CatalogueSHA256 is the recorded lowercase catalogue digest.
	CatalogueSHA256 string `json:"catalogue_sha256"`
	// CatalogueSignature is the collector's historical signature claim.
	CatalogueSignature string `json:"catalogue_signature"`
}

// legacyStoreBluetoothSection is the exact version 1 private Bluetooth union,
// including the retired adapter-instance binding that is never returned.
type legacyStoreBluetoothSection struct {
	// Included reports whether historical private address evidence is present.
	Included bool `json:"included"`
	// Reason is present only when the address evidence is absent.
	Reason *AbsentReason `json:"reason,omitempty"`
	// Address is the private public-controller address and is never exposed.
	Address *BluetoothAddress `json:"address,omitempty"`
	// Source records the historical bounded Windows evidence type.
	Source *BluetoothSource `json:"source,omitempty"`
	// AdapterInstanceIDBindingSHA256 is the retired salted adapter binding and is
	// validated but never returned, applied, or migrated.
	AdapterInstanceIDBindingSHA256 *string `json:"adapter_instance_id_binding_sha256,omitempty"`
}

// validateStoredEntryForMaintenance accepts a current entry or an exact retired
// version 1 entry only for redacted listing and the existing verified purge
// transaction. Import and application deliberately use validateStoredEntry.
func validateStoredEntryForMaintenance(ctx context.Context, entryPath, expectedID string) (auditedStoreEntry, error) {
	if err := ctx.Err(); err != nil {
		return auditedStoreEntry{}, err
	}
	manifestBytes, manifestSnapshot, err := readManifest(ctx, entryPath)
	if err != nil {
		return auditedStoreEntry{}, err
	}
	if digestBytes(manifestBytes) != expectedID {
		return auditedStoreEntry{}, errors.New("stored manifest digest does not match store ID")
	}
	version, err := decodeStoredSchemaVersion(manifestBytes)
	if err != nil {
		return auditedStoreEntry{}, err
	}

	var summary Summary
	var payloads []storedPayloadRecord
	switch version {
	case SchemaVersion:
		contract, decodeErr := Decode(bytes.NewReader(manifestBytes))
		if decodeErr != nil {
			return auditedStoreEntry{}, decodeErr
		}
		summary = contract.Summary()
		payloads = storedPayloads(contract.PlatformFirmware.Files)
	case legacyStoreSchemaVersion:
		contract, decodeErr := decodeLegacyStoreContract(manifestBytes)
		if decodeErr != nil {
			return auditedStoreEntry{}, decodeErr
		}
		summary = legacyStoreSummary(contract)
		payloads = legacyStoredPayloads(contract.PlatformFirmware.Files)
	default:
		return auditedStoreEntry{}, fmt.Errorf("stored Windows hand-off schema_version must be %d or retired maintenance-only version %d", SchemaVersion, legacyStoreSchemaVersion)
	}
	return auditStoredEntry(ctx, entryPath, expectedID, manifestBytes, manifestSnapshot, summary, payloads)
}

// decodeStoredSchemaVersion reads only enough of a bounded JSON document to
// route it to an exact schema decoder; the selected decoder still checks the
// complete duplicate-free closed shape.
func decodeStoredSchemaVersion(data []byte) (int, error) {
	if len(data) > MaximumDocumentSize {
		return 0, fmt.Errorf("Windows hand-off exceeds %d bytes", MaximumDocumentSize)
	}
	if bytes.HasPrefix(data, utf8ByteOrderMark) {
		return 0, errors.New("decode stored Windows hand-off JSON: UTF-8 byte-order mark is not allowed")
	}
	if !utf8.Valid(data) {
		return 0, errors.New("decode stored Windows hand-off JSON: input is not valid UTF-8")
	}
	var envelope struct {
		// SchemaVersion selects the exact decoder but grants no other authority.
		SchemaVersion int `json:"schema_version"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(&envelope); err != nil {
		return 0, fmt.Errorf("decode stored Windows hand-off schema: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return 0, errors.New("decode stored Windows hand-off schema: multiple JSON values are not allowed")
		}
		return 0, fmt.Errorf("decode stored Windows hand-off schema after first value: %w", err)
	}
	return envelope.SchemaVersion, nil
}

// decodeLegacyStoreContract applies the retired exact JSON shape and semantic
// policy without exporting a decoder that import or application could use.
func decodeLegacyStoreContract(data []byte) (legacyStoreContractV1, error) {
	if err := validateJSONValueShape(data, reflect.TypeOf(legacyStoreContractV1{}), "retired Windows hand-off"); err != nil {
		return legacyStoreContractV1{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var contract legacyStoreContractV1
	if err := decoder.Decode(&contract); err != nil {
		return legacyStoreContractV1{}, fmt.Errorf("decode retired Windows hand-off JSON: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return legacyStoreContractV1{}, errors.New("decode retired Windows hand-off JSON: multiple JSON values are not allowed")
		}
		return legacyStoreContractV1{}, fmt.Errorf("decode retired Windows hand-off JSON after first value: %w", err)
	}
	if err := validateLegacyStoreContract(contract); err != nil {
		return legacyStoreContractV1{}, err
	}
	return contract, nil
}

// validateLegacyStoreContract enforces the complete historical version 1
// contract solely to establish a trustworthy inventory for list and purge.
func validateLegacyStoreContract(contract legacyStoreContractV1) error {
	if contract.SchemaVersion != legacyStoreSchemaVersion {
		return fmt.Errorf("retired Windows hand-off schema_version must be %d", legacyStoreSchemaVersion)
	}
	if contract.Kind != ContractKind {
		return fmt.Errorf("retired Windows hand-off kind must be %q", ContractKind)
	}
	if contract.PrivacyClassification != PrivacyClassification {
		return fmt.Errorf("retired Windows hand-off privacy_classification must be %q", PrivacyClassification)
	}
	if err := validateCreatedAt(contract.CreatedAt); err != nil {
		return err
	}
	if err := validateLegacyStoreCollector(contract.Collector); err != nil {
		return err
	}
	if err := validateDevice(contract.Device); err != nil {
		return err
	}
	if err := validateLegacyStorePlatformFirmware(contract.PlatformFirmware); err != nil {
		return err
	}
	if err := validateLegacyStoreBluetooth(contract.BluetoothPublicAddress); err != nil {
		return err
	}
	if !contract.PlatformFirmware.Included && !contract.BluetoothPublicAddress.Included {
		return errors.New("retired Windows hand-off must include platform firmware, a Bluetooth public address, or both")
	}
	return nil
}

// validateLegacyStoreCollector checks the exact historical exporter identity
// without widening current import or application compatibility.
func validateLegacyStoreCollector(record CollectorRecord) error {
	if record.Name != CollectorName {
		return fmt.Errorf("retired Windows hand-off collector name must be %q", CollectorName)
	}
	if record.Version != legacyStoreCollectorVersion {
		return fmt.Errorf("retired Windows hand-off collector version must be %q", legacyStoreCollectorVersion)
	}
	return nil
}

// validateLegacyStorePlatformFirmware checks the historical exact union,
// canonical order, mappings, byte identities, and bounded provenance claims.
func validateLegacyStorePlatformFirmware(section legacyStorePlatformFirmwareSection) error {
	if !section.Included {
		if section.Reason == nil {
			return errors.New("absent retired platform_firmware requires reason")
		}
		if section.Files != nil {
			return errors.New("absent retired platform_firmware must not contain files")
		}
		return validateAbsentReason(*section.Reason, "retired platform_firmware")
	}
	if section.Reason != nil {
		return errors.New("included retired platform_firmware must not contain reason")
	}
	if section.Files == nil {
		return errors.New("included retired platform_firmware requires files")
	}
	if len(section.Files) != len(firmwarePolicyTable) {
		return fmt.Errorf("included retired platform_firmware must contain exactly %d files", len(firmwarePolicyTable))
	}
	var totalSize int64
	for index, policy := range firmwarePolicyTable {
		record := section.Files[index]
		if err := validateLegacyStoreFirmwareFile(record, policy, index); err != nil {
			return err
		}
		totalSize += record.Size
		if totalSize > maximumFirmwareTotalSize {
			return fmt.Errorf("retired platform_firmware exceeds %d bytes", maximumFirmwareTotalSize)
		}
	}
	return nil
}

// validateLegacyStoreFirmwareFile checks one historical mapping and copied-byte
// identity without inventing the original-INF authority introduced by version 2.
func validateLegacyStoreFirmwareFile(record legacyStoreFirmwareFileRecord, policy FirmwarePolicy, index int) error {
	if record.ID != policy.ID {
		return fmt.Errorf("retired platform_firmware file %d id must be %q", index, policy.ID)
	}
	if record.SourceName != policy.SourceName {
		return fmt.Errorf("retired platform_firmware file %s source_name must be %q", policy.ID, policy.SourceName)
	}
	if record.PayloadPath != policy.PayloadPath {
		return fmt.Errorf("retired platform_firmware file %s payload_path must match compiled policy", policy.ID)
	}
	if record.Destination != policy.Destination {
		return fmt.Errorf("retired platform_firmware file %s destination must match compiled policy", policy.ID)
	}
	if err := validatePortablePath(record.PayloadPath, "retired platform_firmware payload_path"); err != nil {
		return err
	}
	if err := validatePortablePath(record.Destination, "retired platform_firmware destination"); err != nil {
		return err
	}
	if record.Size <= 0 || record.Size > maximumFirmwareFileSize {
		return fmt.Errorf("retired platform_firmware file %s size_bytes must be between 1 and %d", policy.ID, maximumFirmwareFileSize)
	}
	if err := validateSHA256(record.SHA256, "retired platform_firmware file "+policy.ID); err != nil {
		return err
	}
	return validateLegacyStoreWindowsSource(record.WindowsSource, policy)
}

// validateLegacyStoreWindowsSource checks the exact bounded version 1
// DriverStore claim while deliberately withholding current selection authority.
func validateLegacyStoreWindowsSource(record legacyStoreWindowsSourceRecord, policy FirmwarePolicy) error {
	if err := validatePortablePath(record.DriverStorePath, "retired Windows DriverStore path"); err != nil {
		return err
	}
	const prefix = "Windows/System32/DriverStore/FileRepository/"
	if !strings.HasPrefix(record.DriverStorePath, prefix) {
		return errors.New("retired Windows DriverStore path must be beneath Windows/System32/DriverStore/FileRepository")
	}
	relative := strings.TrimPrefix(record.DriverStorePath, prefix)
	if strings.Count(relative, "/") < 1 || path.Base(relative) != policy.SourceName {
		return fmt.Errorf("retired Windows DriverStore path for %s must end with its compiled source filename", policy.ID)
	}
	if len(record.PublishedINF) > 32 || !publishedINFPattern.MatchString(record.PublishedINF) {
		return fmt.Errorf("retired Windows source for %s has a non-canonical published_inf", policy.ID)
	}
	if len(record.DriverVersion) > 64 || !driverVersionPattern.MatchString(record.DriverVersion) {
		return fmt.Errorf("retired Windows source for %s has a non-canonical driver_version", policy.ID)
	}
	if err := validateSHA256(record.CatalogueSHA256, "retired Windows driver catalogue for "+policy.ID); err != nil {
		return err
	}
	if record.CatalogueSignature != "valid" {
		return fmt.Errorf("retired Windows source for %s must claim a valid catalogue signature", policy.ID)
	}
	return nil
}

// validateLegacyStoreBluetooth checks the retired exact private-address union
// and validates, but never returns, its obsolete adapter-instance digest.
func validateLegacyStoreBluetooth(section legacyStoreBluetoothSection) error {
	if !section.Included {
		if section.Reason == nil {
			return errors.New("absent retired bluetooth_public_address requires reason")
		}
		if section.Address != nil || section.Source != nil || section.AdapterInstanceIDBindingSHA256 != nil {
			return errors.New("absent retired bluetooth_public_address must not contain private address evidence")
		}
		return validateAbsentReason(*section.Reason, "retired bluetooth_public_address")
	}
	if section.Reason != nil {
		return errors.New("included retired bluetooth_public_address must not contain reason")
	}
	if section.Address == nil || section.Source == nil || section.AdapterInstanceIDBindingSHA256 == nil {
		return errors.New("included retired bluetooth_public_address requires address, source, and adapter instance digest")
	}
	if err := validateBluetoothAddress(*section.Address); err != nil {
		return err
	}
	if *section.Source != BluetoothSourcePermanentAddress && *section.Source != BluetoothSourceBTHPORT {
		return errors.New("retired Bluetooth public address source is not an allowed Windows evidence type")
	}
	return validateSHA256(*section.AdapterInstanceIDBindingSHA256, "retired Bluetooth adapter instance binding")
}

// legacyStoreSummary creates the same deliberately redacted public view used
// for current entries while retaining schema version 1 as the cut-over signal.
func legacyStoreSummary(contract legacyStoreContractV1) Summary {
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

// legacyStoredPayloads projects historical records into the schema-neutral
// byte identities needed for no-follow closed-set verification.
func legacyStoredPayloads(records []legacyStoreFirmwareFileRecord) []storedPayloadRecord {
	payloads := make([]storedPayloadRecord, 0, len(records))
	for _, record := range records {
		payloads = append(payloads, storedPayloadRecord{
			ID: record.ID, PayloadPath: record.PayloadPath, SHA256: record.SHA256, Size: record.Size,
		})
	}
	return payloads
}
