package handoff

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	// maximumPortablePathLength bounds every untrusted relative path retained by
	// the contract.
	maximumPortablePathLength = 512
	// maximumFirmwareFileSize bounds one declared firmware payload before later
	// import code attempts to copy or hash it.
	maximumFirmwareFileSize int64 = 512 << 20
	// maximumFirmwareTotalSize bounds the complete eleven-file payload set.
	maximumFirmwareTotalSize int64 = 1 << 30
	// maximumWindowsInstanceIDLength bounds the private derivation input before
	// hashing without storing or reporting it.
	maximumWindowsInstanceIDLength = 512
)

var (
	// collectorVersionPattern accepts a deterministic three-component numeric
	// collector release.
	collectorVersionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	// driverVersionPattern accepts the numeric Windows driver versions observed
	// in signed DriverStore packages.
	driverVersionPattern = regexp.MustCompile(`^[0-9]+(?:\.[0-9]+){1,3}$`)
	// publishedINFPattern accepts only canonical Windows published-driver names.
	publishedINFPattern = regexp.MustCompile(`^oem[0-9]+\.inf$`)
	// portableSegmentPattern keeps hand-off paths usable across Windows and Linux
	// without quoting or alternate path semantics.
	portableSegmentPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+~-]*$`)
	// canonicalBluetoothAddressPattern requires uppercase colon-separated octets.
	canonicalBluetoothAddressPattern = regexp.MustCompile(`^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$`)
	// canonicalSMBIOSUUIDPattern accepts the lowercase, hyphenated UUID text used
	// as input to the device-binding derivation.
	canonicalSMBIOSUUIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

// Validate checks the exact v1 envelope, device binding, strict union states,
// compiled firmware mappings, provenance shapes, and private address policy.
func Validate(contract Contract) error {
	if contract.SchemaVersion != SchemaVersion {
		return fmt.Errorf("Windows hand-off schema_version must be %d", SchemaVersion)
	}
	if contract.Kind != ContractKind {
		return fmt.Errorf("Windows hand-off kind must be %q", ContractKind)
	}
	if contract.PrivacyClassification != PrivacyClassification {
		return fmt.Errorf("Windows hand-off privacy_classification must be %q", PrivacyClassification)
	}
	if err := validateCreatedAt(contract.CreatedAt); err != nil {
		return err
	}
	if err := validateCollector(contract.Collector); err != nil {
		return err
	}
	if err := validateDevice(contract.Device); err != nil {
		return err
	}
	if err := validatePlatformFirmware(contract.PlatformFirmware); err != nil {
		return err
	}
	if err := validateBluetoothPublicAddress(contract.BluetoothPublicAddress); err != nil {
		return err
	}
	if !contract.PlatformFirmware.Included && !contract.BluetoothPublicAddress.Included {
		return errors.New("Windows hand-off must include platform firmware, a Bluetooth public address, or both")
	}
	return nil
}

// validateCreatedAt requires a canonical second-precision UTC RFC3339 value.
func validateCreatedAt(value string) error {
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil || parsed.UTC().Format(time.RFC3339) != value {
		return errors.New("Windows hand-off created_at must be canonical second-precision UTC RFC3339")
	}
	return nil
}

// validateCollector checks the canonical exporter name and bounded release
// version without elevating either field into an authenticity claim.
func validateCollector(record CollectorRecord) error {
	if record.Name != CollectorName {
		return fmt.Errorf("Windows hand-off collector name must be %q", CollectorName)
	}
	if len(record.Version) > 32 || !collectorVersionPattern.MatchString(record.Version) {
		return errors.New("Windows hand-off collector version must contain three numeric components")
	}
	return nil
}

// validateDevice checks the compiled platform contract and hashed per-device
// binding without accepting raw hardware identifiers or linkable bare hashes.
func validateDevice(record DeviceRecord) error {
	if record.PlatformID != PlatformID {
		return fmt.Errorf("Windows hand-off device platform_id must be %q", PlatformID)
	}
	if record.Architecture != Architecture {
		return fmt.Errorf("Windows hand-off device architecture must be %q", Architecture)
	}
	if _, err := decodeBindingSalt(record.BindingSalt); err != nil {
		return err
	}
	if err := validateSHA256(record.SMBIOSProductUUIDBindingSHA256, "device SMBIOS product UUID binding"); err != nil {
		return err
	}
	if record.WiFiPCIID != WiFiPCIID {
		return fmt.Errorf("Windows hand-off device wifi_pci_id must be %q", WiFiPCIID)
	}
	return nil
}

// DeriveDeviceBinding returns lowercase SHA-256 over DeviceBindingDomain,
// followed by the raw 32-byte salt, followed by the ASCII bytes of a lowercase
// hyphenated SMBIOS UUID. The domain includes its terminating NUL separator.
func DeriveDeviceBinding(bindingSalt, canonicalSMBIOSUUID string) (string, error) {
	salt, err := decodeBindingSalt(bindingSalt)
	if err != nil {
		return "", err
	}
	if !canonicalSMBIOSUUIDPattern.MatchString(canonicalSMBIOSUUID) {
		return "", errors.New("SMBIOS product UUID must be canonical lowercase hyphenated hexadecimal")
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte(DeviceBindingDomain))
	_, _ = digest.Write(salt)
	_, _ = digest.Write([]byte(canonicalSMBIOSUUID))
	return hex.EncodeToString(digest.Sum(nil)), nil
}

// DeriveBluetoothAdapterBinding returns lowercase SHA-256 over
// BluetoothAdapterBindingDomain, followed by the raw 32-byte device salt,
// followed by the canonical Windows instance-ID ASCII bytes. PowerShell must
// trim the identifier, convert ASCII letters to uppercase, retain backslash
// separators, and reject non-ASCII or empty path components before calling it.
func DeriveBluetoothAdapterBinding(bindingSalt, canonicalInstanceID string) (string, error) {
	salt, err := decodeBindingSalt(bindingSalt)
	if err != nil {
		return "", err
	}
	if err := validateCanonicalWindowsInstanceID(canonicalInstanceID); err != nil {
		return "", err
	}
	digest := sha256.New()
	_, _ = digest.Write([]byte(BluetoothAdapterBindingDomain))
	_, _ = digest.Write(salt)
	_, _ = digest.Write([]byte(canonicalInstanceID))
	return hex.EncodeToString(digest.Sum(nil)), nil
}

// validateCanonicalWindowsInstanceID requires trimmed, printable ASCII,
// uppercase Windows instance-ID text with two or more non-empty backslash-
// separated components and never includes the private value in an error.
func validateCanonicalWindowsInstanceID(value string) error {
	if len(value) < 3 || len(value) > maximumWindowsInstanceIDLength || strings.TrimSpace(value) != value ||
		strings.ToUpper(value) != value || strings.Contains(value, "/") {
		return errors.New("Windows adapter instance ID is not canonical trimmed uppercase ASCII")
	}
	for _, character := range []byte(value) {
		if character < 0x21 || character > 0x7e {
			return errors.New("Windows adapter instance ID is not canonical trimmed uppercase ASCII")
		}
	}
	components := strings.Split(value, "\\")
	if len(components) < 2 {
		return errors.New("Windows adapter instance ID requires backslash-separated components")
	}
	for _, component := range components {
		if component == "" {
			return errors.New("Windows adapter instance ID requires non-empty components")
		}
	}
	return nil
}

// decodeBindingSalt validates and decodes one fresh lowercase 32-byte salt
// without including the private value in any error.
func decodeBindingSalt(value string) ([]byte, error) {
	if len(value) != 64 || strings.ToLower(value) != value {
		return nil, errors.New("device binding_salt must encode 32 bytes as lowercase hexadecimal")
	}
	decoded, err := hex.DecodeString(value)
	if err != nil || len(decoded) != 32 {
		return nil, errors.New("device binding_salt must encode 32 bytes as lowercase hexadecimal")
	}
	allZero := true
	for _, item := range decoded {
		allZero = allZero && item == 0
	}
	if allZero {
		return nil, errors.New("device binding_salt must not be all zero")
	}
	return decoded, nil
}

// validatePlatformFirmware enforces the exact union between explicit absence
// and the complete, canonically ordered eleven-file set.
func validatePlatformFirmware(section PlatformFirmwareSection) error {
	if !section.Included {
		if section.Reason == nil {
			return errors.New("absent platform_firmware requires reason")
		}
		if section.Files != nil {
			return errors.New("absent platform_firmware must not contain files")
		}
		return validateAbsentReason(*section.Reason, "platform_firmware")
	}
	if section.Reason != nil {
		return errors.New("included platform_firmware must not contain reason")
	}
	if section.Files == nil {
		return errors.New("included platform_firmware requires files")
	}
	if len(section.Files) != len(firmwarePolicyTable) {
		return fmt.Errorf("included platform_firmware must contain exactly %d files", len(firmwarePolicyTable))
	}

	var totalSize int64
	for index, policy := range firmwarePolicyTable {
		record := section.Files[index]
		if err := validateFirmwareFile(record, policy, index); err != nil {
			return err
		}
		totalSize += record.Size
		if totalSize > maximumFirmwareTotalSize {
			return fmt.Errorf("platform_firmware exceeds %d bytes", maximumFirmwareTotalSize)
		}
	}
	return nil
}

// validateFirmwareFile checks one record against its exact compiled mapping and
// then validates its copied-byte and Windows provenance evidence.
func validateFirmwareFile(record FirmwareFileRecord, policy FirmwarePolicy, index int) error {
	if record.ID != policy.ID {
		return fmt.Errorf("platform_firmware file %d id must be %q", index, policy.ID)
	}
	if record.SourceName != policy.SourceName {
		return fmt.Errorf("platform_firmware file %s source_name must be %q", policy.ID, policy.SourceName)
	}
	if record.PayloadPath != policy.PayloadPath {
		return fmt.Errorf("platform_firmware file %s payload_path must match compiled policy", policy.ID)
	}
	if record.Destination != policy.Destination {
		return fmt.Errorf("platform_firmware file %s destination must match compiled policy", policy.ID)
	}
	if err := validatePortablePath(record.PayloadPath, "platform_firmware payload_path"); err != nil {
		return err
	}
	if err := validatePortablePath(record.Destination, "platform_firmware destination"); err != nil {
		return err
	}
	if record.Size <= 0 || record.Size > maximumFirmwareFileSize {
		return fmt.Errorf("platform_firmware file %s size_bytes must be between 1 and %d", policy.ID, maximumFirmwareFileSize)
	}
	if err := validateSHA256(record.SHA256, "platform_firmware file "+policy.ID); err != nil {
		return err
	}
	return validateWindowsSource(record.WindowsSource, policy)
}

// validateWindowsSource checks bounded DriverStore evidence while deliberately
// treating the signature state as a Windows-side claim rather than verification.
func validateWindowsSource(record WindowsSourceRecord, policy FirmwarePolicy) error {
	if err := validatePortablePath(record.DriverStorePath, "Windows DriverStore path"); err != nil {
		return err
	}
	const prefix = "Windows/System32/DriverStore/FileRepository/"
	if !strings.HasPrefix(record.DriverStorePath, prefix) {
		return errors.New("Windows DriverStore path must be beneath Windows/System32/DriverStore/FileRepository")
	}
	relative := strings.TrimPrefix(record.DriverStorePath, prefix)
	if strings.Count(relative, "/") < 1 || path.Base(relative) != policy.SourceName {
		return fmt.Errorf("Windows DriverStore path for %s must end with its compiled source filename", policy.ID)
	}
	if len(record.PublishedINF) > 32 || !publishedINFPattern.MatchString(record.PublishedINF) {
		return fmt.Errorf("Windows source for %s has a non-canonical published_inf", policy.ID)
	}
	if len(record.DriverVersion) > 64 || !driverVersionPattern.MatchString(record.DriverVersion) {
		return fmt.Errorf("Windows source for %s has a non-canonical driver_version", policy.ID)
	}
	if err := validateSHA256(record.CatalogueSHA256, "Windows driver catalogue for "+policy.ID); err != nil {
		return err
	}
	if record.CatalogueSignature != "valid" {
		return fmt.Errorf("Windows source for %s must claim a valid catalogue signature", policy.ID)
	}
	return nil
}

// validateBluetoothPublicAddress enforces the exact union between explicit
// absence and complete private address provenance.
func validateBluetoothPublicAddress(section BluetoothPublicAddressSection) error {
	if !section.Included {
		if section.Reason == nil {
			return errors.New("absent bluetooth_public_address requires reason")
		}
		if section.Address != nil || section.Source != nil || section.AdapterInstanceIDBindingSHA256 != nil {
			return errors.New("absent bluetooth_public_address must not contain private address evidence")
		}
		return validateAbsentReason(*section.Reason, "bluetooth_public_address")
	}
	if section.Reason != nil {
		return errors.New("included bluetooth_public_address must not contain reason")
	}
	if section.Address == nil || section.Source == nil || section.AdapterInstanceIDBindingSHA256 == nil {
		return errors.New("included bluetooth_public_address requires address, source, and adapter instance digest")
	}
	if err := validateBluetoothAddress(*section.Address); err != nil {
		return err
	}
	if *section.Source != BluetoothSourcePermanentAddress && *section.Source != BluetoothSourceBTHPORT {
		return errors.New("Bluetooth public address source is not an allowed Windows evidence type")
	}
	return validateSHA256(*section.AdapterInstanceIDBindingSHA256, "Bluetooth adapter instance binding")
}

// validateBluetoothAddress checks canonical formatting, unicast semantics, and
// known invalid or illustrative values without echoing the private address.
func validateBluetoothAddress(address BluetoothAddress) error {
	value := string(address)
	if !canonicalBluetoothAddressPattern.MatchString(value) {
		return errors.New("Bluetooth public address is not canonical uppercase colon-separated hexadecimal")
	}
	parts := strings.Split(value, ":")
	octets := make([]byte, len(parts))
	for index, part := range parts {
		parsed, err := strconv.ParseUint(part, 16, 8)
		if err != nil {
			return errors.New("Bluetooth public address is not valid hexadecimal")
		}
		octets[index] = byte(parsed)
	}
	if octets[0]&1 != 0 {
		return errors.New("Bluetooth public address must be unicast")
	}
	allZero := true
	allBroadcast := true
	for _, octet := range octets {
		allZero = allZero && octet == 0
		allBroadcast = allBroadcast && octet == 0xff
	}
	if allZero || allBroadcast || strings.HasPrefix(value, "00:00:00:00:") ||
		value == "AA:AA:AA:AA:AA:AA" || value == "AA:BB:CC:DD:EE:FF" {
		return errors.New("Bluetooth public address is a zero, broadcast, or known placeholder value")
	}
	return nil
}

// validateAbsentReason permits only the two explicit v1 absence explanations.
func validateAbsentReason(reason AbsentReason, section string) error {
	if reason != AbsentReasonNotRequested && reason != AbsentReasonUnavailable {
		return fmt.Errorf("%s reason is not allowed", section)
	}
	return nil
}

// validateSHA256 checks one lowercase, fixed-width hexadecimal digest without
// including its potentially identifying value in an error.
func validateSHA256(value, label string) error {
	if len(value) != 64 || strings.ToLower(value) != value {
		return fmt.Errorf("%s SHA-256 digest is not canonical lowercase hexadecimal", label)
	}
	for _, character := range value {
		if character < '0' || character > '9' && character < 'a' || character > 'f' {
			return fmt.Errorf("%s SHA-256 digest is not canonical lowercase hexadecimal", label)
		}
	}
	return nil
}

// validatePortablePath rejects absolute, traversing, Windows-separated,
// control-bearing, non-portable, or overlong relative paths.
func validatePortablePath(value, label string) error {
	if value == "" || len(value) > maximumPortablePathLength || !utf8.ValidString(value) ||
		strings.Contains(value, "\\") || strings.Contains(value, ":") || strings.HasPrefix(value, "/") ||
		path.Clean(value) != value || value == "." || strings.HasPrefix(value, "../") {
		return fmt.Errorf("%s is not a canonical portable relative path", label)
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return fmt.Errorf("%s is not a canonical portable relative path", label)
		}
	}
	for _, segment := range strings.Split(value, "/") {
		if !portableSegmentPattern.MatchString(segment) {
			return fmt.Errorf("%s is not a canonical portable relative path", label)
		}
	}
	return nil
}
