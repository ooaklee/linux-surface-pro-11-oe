// Package image coordinates boot-image creation across distro adapters.
package image

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"reflect"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

// ManifestSchemaVersion identifies the on-media manifest contract understood by
// this version of linux-armer.
const ManifestSchemaVersion = 3

// MaximumManifestSize bounds untrusted on-media JSON before decoding it.
const MaximumManifestSize = 1 << 20

// ArtifactRecord describes one immutable file by its logical path, digest, and
// byte length so validators can prove the published media contains the expected
// content.
type ArtifactRecord struct {
	// Path is the artefact's portable path inside the image, not a host path.
	Path string `json:"path"`
	// SHA256 is the lowercase hexadecimal digest of the complete artefact.
	SHA256 string `json:"sha256"`
	// Size is the artefact length in bytes.
	Size int64 `json:"size_bytes"`
}

// BootArtifactRecord groups the kernel, initramfs, and matching device trees
// that form a bootable kernel set.
type BootArtifactRecord struct {
	// Kernel records the live-media kernel loaded by GRUB.
	Kernel ArtifactRecord `json:"kernel"`
	// Initrd records the initramfs paired with Kernel.
	Initrd ArtifactRecord `json:"initrd"`
	// DTBs records every hardware device tree shipped with the kernel set.
	DTBs []ArtifactRecord `json:"device_trees"`
}

// ToolIdentityRecord identifies the exact CLI build represented by a companion
// executable and its corresponding source archive.
type ToolIdentityRecord struct {
	// Version is the semantic release or development version of linux-armer.
	Version string `json:"version"`
	// Commit is the source revision reported by the build.
	Commit string `json:"commit"`
	// BuildDate is the UTC build timestamp reported by the build.
	BuildDate string `json:"build_date"`
}

// ExecutableArtifactRecord describes an executable artefact together with the
// platform and mode required to use it after mounting the image.
type ExecutableArtifactRecord struct {
	// Artifact records the immutable executable bytes and ISO-relative path.
	Artifact ArtifactRecord `json:"artifact"`
	// OperatingSystem is the Go target operating system expected by the binary.
	OperatingSystem string `json:"operating_system"`
	// Architecture is the Go target architecture expected by the binary.
	Architecture string `json:"architecture"`
	// Format identifies the executable container format, such as ELF.
	Format string `json:"format"`
	// Mode is the four-digit octal permission mode required on extracted media.
	Mode string `json:"mode"`
}

// OfflineUserspaceRecord groups one verified, relocatable userspace release
// that is deliberately available without network access from the image.
type OfflineUserspaceRecord struct {
	// Component is the stable userspace catalogue identifier.
	Component string `json:"component"`
	// Release is the exact immutable component release tag.
	Release string `json:"release"`
	// Redistribution records the catalogue policy permitting offline inclusion.
	Redistribution string `json:"redistribution"`
	// Root is the ISO-relative directory containing this complete release bundle.
	Root string `json:"root"`
	// Artifacts records the portable receipt and every release payload file.
	Artifacts []ArtifactRecord `json:"artifacts"`
}

// CompanionBundleRecord inventories the optional self-support payload carried
// under one reserved ISO directory and tracked by the outer image manifest.
type CompanionBundleRecord struct {
	// Included reports whether any companion files are present on this image.
	Included bool `json:"included"`
	// Root is the reserved ISO-relative companion directory.
	Root string `json:"root"`
	// Reason explains why the optional bundle was omitted.
	Reason string `json:"reason,omitempty"`
	// Tool identifies the CLI binary and source when the bundle is included.
	Tool *ToolIdentityRecord `json:"tool,omitempty"`
	// ProjectLicence states whether this repository declares redistribution terms.
	ProjectLicence string `json:"project_licence,omitempty"`
	// Executable is the Linux ARM64 companion CLI.
	Executable *ExecutableArtifactRecord `json:"executable,omitempty"`
	// SourceArchive contains the corresponding linux-armer source tree.
	SourceArchive *ArtifactRecord `json:"source_archive,omitempty"`
	// Catalogues contains the exact image and userspace catalogues used by the CLI.
	Catalogues []ArtifactRecord `json:"catalogues,omitempty"`
	// Licences records project and dependency notices when they are available.
	Licences []ArtifactRecord `json:"licences,omitempty"`
	// Userspace inventories redistribution-eligible offline component releases.
	Userspace []OfflineUserspaceRecord `json:"userspace"`
}

// MediaDiscoveryEvidence records one adapter-defined fact used to prove that a
// distribution initramfs can rediscover its physical or logical boot medium.
type MediaDiscoveryEvidence struct {
	// Role is the adapter-owned semantic name of this discovery fact.
	Role string `json:"role"`
	// Scope identifies where the fact is observed, such as an ISO or initramfs.
	Scope string `json:"scope"`
	// Path is a portable path or adapter-defined locator within Scope.
	Path string `json:"path,omitempty"`
	// Value is the canonical identity, label, or argument asserted by the adapter.
	Value string `json:"value,omitempty"`
	// Artifact records immutable bytes when the evidence is a standalone file.
	Artifact *ArtifactRecord `json:"artifact,omitempty"`
}

// MediaDiscoveryRecord describes the adapter-owned strategy by which the
// distribution initramfs rediscovers its boot medium.
type MediaDiscoveryRecord struct {
	// Strategy identifies the outer layout, such as a directly written hybrid ISO.
	Strategy string `json:"strategy"`
	// Protocol identifies the distribution live-boot implementation.
	Protocol string `json:"protocol"`
	// Evidence contains the adapter-defined facts that prove this strategy.
	Evidence []MediaDiscoveryEvidence `json:"evidence"`
}

// Manifest is the self-contained provenance and boot contract embedded in a
// remastered image and published beside it.
type Manifest struct {
	// SchemaVersion selects the manifest decoding contract.
	SchemaVersion int `json:"schema_version"`
	// CreatedAt records when the image manifest was assembled in UTC.
	CreatedAt time.Time `json:"created_at"`
	// ToolVersion identifies the linux-armer build that produced the image.
	ToolVersion string `json:"tool_version"`
	// Layout describes the outer media format, such as a hybrid ISO.
	Layout string `json:"layout"`
	// Adapter identifies the distribution-specific remaster implementation.
	Adapter string `json:"adapter"`
	// SourceImage records the unmodified distribution image used as input.
	SourceImage ArtifactRecord `json:"source_image"`
	// KernelBundle records the version-bound kernel packages and device trees.
	KernelBundle kernel.Bundle `json:"kernel_bundle"`
	// BootArtifacts records the exact files placed on the boot path.
	BootArtifacts BootArtifactRecord `json:"boot_artifacts"`
	// MediaDiscovery records the live-initramfs and physical-media agreement.
	MediaDiscovery MediaDiscoveryRecord `json:"media_discovery"`
	// CompanionBundle inventories optional CLI, source, catalogue, and userspace files.
	CompanionBundle CompanionBundleRecord `json:"companion_bundle"`
	// BootArguments lists device-specific kernel arguments added by the adapter.
	BootArguments []string `json:"boot_arguments"`
	// SecureBoot states the media's Secure Boot requirement for the operator.
	SecureBoot string `json:"secure_boot"`
}

// DecodeManifest reads one bounded, strict JSON manifest and rejects unknown
// fields or additional JSON values before adapter-specific validation begins.
func DecodeManifest(reader io.Reader) (Manifest, error) {
	if reader == nil {
		return Manifest{}, errors.New("decode image manifest: reader is nil")
	}
	data, err := io.ReadAll(io.LimitReader(reader, MaximumManifestSize+1))
	if err != nil {
		return Manifest{}, fmt.Errorf("read image manifest: %w", err)
	}
	if len(data) > MaximumManifestSize {
		return Manifest{}, fmt.Errorf("image manifest exceeds %d bytes", MaximumManifestSize)
	}
	if err := validateManifestJSONShape(data); err != nil {
		return Manifest{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var manifest Manifest
	if err := decoder.Decode(&manifest); err != nil {
		return Manifest{}, fmt.Errorf("decode image manifest JSON: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return Manifest{}, errors.New("decode image manifest JSON: multiple JSON values are not allowed")
		}
		return Manifest{}, fmt.Errorf("decode image manifest JSON after first value: %w", err)
	}
	return manifest, nil
}

// validateManifestJSONShape requires exact, duplicate-free keys and every
// non-optional field throughout the complete image-manifest object graph.
func validateManifestJSONShape(data []byte) error {
	return validateJSONValueShape(data, reflect.TypeOf(Manifest{}), "image manifest")
}

// validateJSONValueShape recursively checks an untrusted JSON value against the
// exact field names and container shapes declared by target.
func validateJSONValueShape(data []byte, target reflect.Type, location string) error {
	trimmed := bytes.TrimSpace(data)
	for target.Kind() == reflect.Pointer {
		if bytes.Equal(trimmed, []byte("null")) {
			return nil
		}
		target = target.Elem()
	}
	if target.Kind() == reflect.Struct && implementsJSONMarshaler(target) {
		return nil
	}
	switch target.Kind() {
	case reflect.Struct:
		return validateJSONObjectShape(trimmed, target, location)
	case reflect.Slice, reflect.Array:
		return validateJSONArrayShape(trimmed, target.Elem(), location)
	case reflect.Map:
		return validateJSONMapShape(trimmed, target.Elem(), location)
	default:
		return nil
	}
}

// validateJSONObjectShape rejects unknown, mis-cased, duplicate, and missing
// fields while recursively checking every recognised field value.
func validateJSONObjectShape(data []byte, target reflect.Type, location string) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return fmt.Errorf("decode %s JSON object: %w", location, err)
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return fmt.Errorf("decode %s JSON: value must be an object", location)
	}
	fields := make(map[string]reflect.StructField)
	required := make(map[string]bool)
	for index := 0; index < target.NumField(); index++ {
		field := target.Field(index)
		if field.PkgPath != "" {
			continue
		}
		name, optional, ignored := jsonFieldContract(field)
		if ignored {
			continue
		}
		fields[name] = field
		if !optional {
			required[name] = true
		}
	}
	seen := make(map[string]bool)
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return fmt.Errorf("decode %s JSON field: %w", location, err)
		}
		key, ok := keyToken.(string)
		if !ok {
			return fmt.Errorf("decode %s JSON: object field name is not a string", location)
		}
		if seen[key] {
			return fmt.Errorf("decode %s JSON: duplicate field %q", location, key)
		}
		seen[key] = true
		field, found := fields[key]
		if !found {
			return fmt.Errorf("decode %s JSON: unknown or mis-cased field %q", location, key)
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return fmt.Errorf("decode %s JSON field %q: %w", location, key, err)
		}
		if err := validateJSONValueShape(value, field.Type, location+"."+key); err != nil {
			return err
		}
	}
	if _, err := decoder.Token(); err != nil {
		return fmt.Errorf("decode %s JSON object end: %w", location, err)
	}
	for name := range required {
		if !seen[name] {
			return fmt.Errorf("decode %s JSON: required field %q is missing", location, name)
		}
	}
	return nil
}

// validateJSONArrayShape checks that a field is an array and applies the exact
// element contract recursively to every member.
func validateJSONArrayShape(data []byte, element reflect.Type, location string) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return fmt.Errorf("decode %s JSON array: %w", location, err)
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '[' {
		return fmt.Errorf("decode %s JSON: value must be an array", location)
	}
	index := 0
	for decoder.More() {
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return fmt.Errorf("decode %s JSON array member: %w", location, err)
		}
		if err := validateJSONValueShape(value, element, fmt.Sprintf("%s[%d]", location, index)); err != nil {
			return err
		}
		index++
	}
	if _, err := decoder.Token(); err != nil {
		return fmt.Errorf("decode %s JSON array end: %w", location, err)
	}
	return nil
}

// validateJSONMapShape rejects duplicate map keys and recursively checks map
// values; the current manifest uses this only as a safe future extension path.
func validateJSONMapShape(data []byte, element reflect.Type, location string) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return fmt.Errorf("decode %s JSON map: %w", location, err)
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return fmt.Errorf("decode %s JSON: value must be an object", location)
	}
	seen := make(map[string]bool)
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return fmt.Errorf("decode %s JSON map key: %w", location, err)
		}
		key, ok := keyToken.(string)
		if !ok {
			return fmt.Errorf("decode %s JSON: map key is not a string", location)
		}
		if seen[key] {
			return fmt.Errorf("decode %s JSON: duplicate map key %q", location, key)
		}
		seen[key] = true
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return fmt.Errorf("decode %s JSON map value %q: %w", location, key, err)
		}
		if err := validateJSONValueShape(value, element, location+"."+key); err != nil {
			return err
		}
	}
	if _, err := decoder.Token(); err != nil {
		return fmt.Errorf("decode %s JSON map end: %w", location, err)
	}
	return nil
}

// jsonFieldContract derives the exact public name and optionality used by the
// standard encoder for one exported structure field.
func jsonFieldContract(field reflect.StructField) (name string, optional bool, ignored bool) {
	tag := field.Tag.Get("json")
	parts := strings.Split(tag, ",")
	if len(parts) > 0 && parts[0] == "-" {
		return "", false, true
	}
	name = field.Name
	if len(parts) > 0 && parts[0] != "" {
		name = parts[0]
	}
	for _, option := range parts[1:] {
		if option == "omitempty" {
			optional = true
		}
	}
	return name, optional, false
}

// implementsJSONMarshaler identifies structure types such as time.Time whose
// JSON representation is scalar rather than an object of exported fields.
func implementsJSONMarshaler(target reflect.Type) bool {
	marshaler := reflect.TypeOf((*json.Marshaler)(nil)).Elem()
	return target.Implements(marshaler) || reflect.PointerTo(target).Implements(marshaler)
}

// ValidateArtifactRecord checks that one manifest artefact has a canonical
// portable path, lowercase SHA-256 identity, and a possible byte length.
func ValidateArtifactRecord(record ArtifactRecord) error {
	if record.Path == "" || strings.Contains(record.Path, "\\") || strings.HasPrefix(record.Path, "/") ||
		path.Clean(record.Path) != record.Path || record.Path == "." || strings.HasPrefix(record.Path, "../") {
		return fmt.Errorf("artifact path %q is not a canonical relative path", record.Path)
	}
	if len(record.SHA256) != 64 || strings.ToLower(record.SHA256) != record.SHA256 {
		return fmt.Errorf("artifact %s has a non-canonical SHA-256 digest", record.Path)
	}
	for _, character := range record.SHA256 {
		if character < '0' || character > '9' && character < 'a' || character > 'f' {
			return fmt.Errorf("artifact %s has a non-hexadecimal SHA-256 digest", record.Path)
		}
	}
	if record.Size < 0 {
		return fmt.Errorf("artifact %s has a negative byte length", record.Path)
	}
	return nil
}

// ValidateArtifactRecords checks every artefact and rejects duplicate portable
// paths so one manifest identity cannot ambiguously describe two files.
func ValidateArtifactRecords(records []ArtifactRecord) error {
	seen := make(map[string]bool, len(records))
	for _, record := range records {
		if err := ValidateArtifactRecord(record); err != nil {
			return err
		}
		if seen[record.Path] {
			return fmt.Errorf("duplicate artifact path %q", record.Path)
		}
		seen[record.Path] = true
	}
	return nil
}

// WriteJSON validates no external state and writes the manifest as indented,
// non-HTML-escaped JSON suitable for both machines and people.
func (m Manifest) WriteJSON(w io.Writer) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(m)
}

// ValidationReport captures the identity of a checked image and the evidence
// produced by each structural bootability check.
type ValidationReport struct {
	// Valid is true only when every recorded check passes.
	Valid bool `json:"valid"`
	// Path is the absolute host path that was validated.
	Path string `json:"path"`
	// SHA256 identifies the complete image bytes that were checked.
	SHA256 string `json:"sha256"`
	// Size is the image length in bytes.
	Size int64 `json:"size_bytes"`
	// Layout names the validated media layout.
	Layout string `json:"layout"`
	// Adapter identifies the distribution-specific validator used.
	Adapter string `json:"adapter"`
	// ManifestSHA256 identifies the exact embedded image-manifest bytes.
	ManifestSHA256 string `json:"manifest_sha256"`
	// ManifestSize is the embedded image-manifest length in bytes.
	ManifestSize int64 `json:"manifest_size_bytes"`
	// KernelABI is the exact ABI read from the embedded manifest.
	KernelABI string `json:"kernel_abi"`
	// DeviceTrees lists the hardware identities declared by the kernel bundle.
	DeviceTrees []string `json:"device_trees"`
	// Checks contains the ordered validation evidence.
	Checks []ValidationCheck `json:"checks"`
}

// ValidationCheck records one named invariant and enough detail to diagnose a
// failure without rerunning the entire build.
type ValidationCheck struct {
	// Name is the stable machine-readable identifier for the invariant.
	Name string `json:"name"`
	// Passed reports whether the invariant held.
	Passed bool `json:"passed"`
	// Details provides concise human-readable evidence or an error message.
	Details string `json:"details"`
}
