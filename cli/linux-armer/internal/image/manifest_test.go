package image

import (
	"strings"
	"testing"
)

// TestDecodeManifestRejectsSchemaExpansion verifies untrusted on-media JSON
// cannot add unknown fields or append another JSON value silently.
func TestDecodeManifestRejectsSchemaExpansion(t *testing.T) {
	t.Parallel()

	for _, document := range []string{
		`{"schema_version":2,"unknown":true}`,
		`{"schema_version":2} {"schema_version":2}`,
	} {
		if _, err := DecodeManifest(strings.NewReader(document)); err == nil {
			t.Errorf("DecodeManifest(%q) succeeded, want error", document)
		}
	}
}

// TestDecodeManifestRejectsOversizedInput verifies manifest decoding has a
// fixed memory and input boundary before JSON is trusted.
func TestDecodeManifestRejectsOversizedInput(t *testing.T) {
	t.Parallel()

	input := strings.Repeat(" ", MaximumManifestSize+1)
	if _, err := DecodeManifest(strings.NewReader(input)); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("DecodeManifest() error = %v, want size error", err)
	}
}

// TestValidateArtifactRecords verifies portable paths, canonical digests, byte
// lengths, and uniqueness are enforced through one shared contract.
func TestValidateArtifactRecords(t *testing.T) {
	t.Parallel()

	valid := ArtifactRecord{Path: "sp11/companion/file", SHA256: strings.Repeat("a", 64), Size: 10}
	if err := ValidateArtifactRecords([]ArtifactRecord{valid}); err != nil {
		t.Fatalf("ValidateArtifactRecords() error = %v", err)
	}
	for _, record := range []ArtifactRecord{
		{Path: "../escape", SHA256: valid.SHA256, Size: 1},
		{Path: valid.Path, SHA256: strings.Repeat("A", 64), Size: 1},
		{Path: valid.Path, SHA256: strings.Repeat("z", 64), Size: 1},
		{Path: valid.Path, SHA256: valid.SHA256, Size: -1},
	} {
		if err := ValidateArtifactRecord(record); err == nil {
			t.Errorf("ValidateArtifactRecord(%#v) succeeded, want error", record)
		}
	}
	if err := ValidateArtifactRecords([]ArtifactRecord{valid, valid}); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("ValidateArtifactRecords() duplicate error = %v", err)
	}
}
