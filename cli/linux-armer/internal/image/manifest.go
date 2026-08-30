// Package image coordinates boot-image creation across distro adapters.
package image

import (
	"encoding/json"
	"io"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

// ManifestSchemaVersion identifies the on-media manifest contract understood by
// this version of linux-armer.
const ManifestSchemaVersion = 1

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
	// BootArguments lists device-specific kernel arguments added by the adapter.
	BootArguments []string `json:"boot_arguments"`
	// SecureBoot states the media's Secure Boot requirement for the operator.
	SecureBoot string `json:"secure_boot"`
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
