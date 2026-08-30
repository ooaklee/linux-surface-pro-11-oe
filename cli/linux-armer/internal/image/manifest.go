// Package image coordinates boot-image creation across distro adapters.
package image

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

// ManifestSchemaVersion identifies the on-media manifest contract understood by
// this version of linux-armer.
const ManifestSchemaVersion = 2

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
