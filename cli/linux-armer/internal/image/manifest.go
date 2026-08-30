// Package image coordinates boot-image creation across distro adapters.
package image

import (
	"encoding/json"
	"io"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

const ManifestSchemaVersion = 1

type ArtifactRecord struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size_bytes"`
}

type BootArtifactRecord struct {
	Kernel ArtifactRecord   `json:"kernel"`
	Initrd ArtifactRecord   `json:"initrd"`
	DTBs   []ArtifactRecord `json:"device_trees"`
}

type Manifest struct {
	SchemaVersion int                `json:"schema_version"`
	CreatedAt     time.Time          `json:"created_at"`
	ToolVersion   string             `json:"tool_version"`
	Layout        string             `json:"layout"`
	Adapter       string             `json:"adapter"`
	SourceImage   ArtifactRecord     `json:"source_image"`
	KernelBundle  kernel.Bundle      `json:"kernel_bundle"`
	BootArtifacts BootArtifactRecord `json:"boot_artifacts"`
	BootArguments []string           `json:"boot_arguments"`
	SecureBoot    string             `json:"secure_boot"`
}

func (m Manifest) WriteJSON(w io.Writer) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(m)
}

type ValidationReport struct {
	Valid         bool             `json:"valid"`
	Path          string           `json:"path"`
	SHA256        string           `json:"sha256"`
	Size          int64            `json:"size_bytes"`
	Layout        string           `json:"layout"`
	Adapter       string           `json:"adapter"`
	KernelABI     string           `json:"kernel_abi"`
	DeviceTrees   []string         `json:"device_trees"`
	Checks        []ValidationCheck `json:"checks"`
}

type ValidationCheck struct {
	Name    string `json:"name"`
	Passed  bool   `json:"passed"`
	Details string `json:"details"`
}
