package image

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

// TestManifestSerialisesExplicitCompanionAbsence verifies the sole image
// manifest always carries a machine-readable companion attribute and array.
func TestManifestSerialisesExplicitCompanionAbsence(t *testing.T) {
	t.Parallel()

	manifest := manifestWithExplicitCompanionAbsence()
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"companion_bundle"`) ||
		!strings.Contains(string(data), `"userspace":[]`) {
		t.Fatalf("serialised manifest has no explicit companion absence: %s", data)
	}
	decoded, err := DecodeManifest(strings.NewReader(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	if decoded.CompanionBundle.Root != manifest.CompanionBundle.Root || decoded.CompanionBundle.Userspace == nil {
		t.Fatalf("decoded companion bundle = %#v", decoded.CompanionBundle)
	}
}

// TestDecodeManifestRejectsAmbiguousCompanionShape verifies critical nested
// fields cannot be duplicated, mis-cased, omitted, or represented as null.
func TestDecodeManifestRejectsAmbiguousCompanionShape(t *testing.T) {
	t.Parallel()

	data, err := json.Marshal(manifestWithExplicitCompanionAbsence())
	if err != nil {
		t.Fatal(err)
	}
	valid := string(data)
	for name, document := range map[string]string{
		"duplicate included": strings.Replace(valid, `"included":false`, `"included":false,"included":true`, 1),
		"mis-cased included": strings.Replace(valid, `"included":false`, `"Included":false`, 1),
		"null userspace":     strings.Replace(valid, `"userspace":[]`, `"userspace":null`, 1),
		"missing userspace":  strings.Replace(valid, `,"userspace":[]`, ``, 1),
	} {
		document := document
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := DecodeManifest(strings.NewReader(document)); err == nil {
				t.Fatalf("DecodeManifest() accepted ambiguous companion JSON: %s", document)
			}
		})
	}
}

// TestDecodeManifestRejectsRecursiveShapeAmbiguity verifies strict decoding
// reaches nested pointers, array members, and structures outside the companion.
func TestDecodeManifestRejectsRecursiveShapeAmbiguity(t *testing.T) {
	t.Parallel()

	data, err := json.Marshal(manifestWithIncludedCompanion())
	if err != nil {
		t.Fatal(err)
	}
	valid := string(data)
	testCases := []struct {
		name        string
		old         string
		replacement string
		location    string
	}{
		{
			name:        "duplicate nested executable field",
			old:         `"operating_system":"linux"`,
			replacement: `"operating_system":"linux","operating_system":"other"`,
			location:    "image manifest.companion_bundle.executable",
		},
		{
			name:        "mis-cased nested source artefact field",
			old:         `"source_archive":{"path":`,
			replacement: `"source_archive":{"Path":`,
			location:    "image manifest.companion_bundle.source_archive",
		},
		{
			name:        "missing userspace array-member field",
			old:         `,"release":"sp11-iptsd-v1"`,
			replacement: ``,
			location:    "image manifest.companion_bundle.userspace[0]",
		},
		{
			name:        "null userspace artefact array",
			old:         `"artifacts":[{"path":"sp11/companion/userspace/iptsd-v1/sp11-iptsd-v1/receipt.json","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size_bytes":1}]`,
			replacement: `"artifacts":null`,
			location:    "image manifest.companion_bundle.userspace[0].artifacts",
		},
		{
			name:        "unknown kernel package field",
			old:         `"verified":true`,
			replacement: `"verified":true,"unexpected":true`,
			location:    "image manifest.kernel_bundle.packages[0]",
		},
	}
	for _, testCase := range testCases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			document := strings.Replace(valid, testCase.old, testCase.replacement, 1)
			if document == valid {
				t.Fatalf("test mutation %q did not match the valid manifest", testCase.old)
			}
			_, err := DecodeManifest(strings.NewReader(document))
			if err == nil || !strings.Contains(err.Error(), testCase.location) {
				t.Fatalf("DecodeManifest() error = %v, want location %q", err, testCase.location)
			}
		})
	}
}

// manifestWithExplicitCompanionAbsence returns a shape-complete manifest whose
// semantic payload is deliberately minimal for strict decoder tests.
func manifestWithExplicitCompanionAbsence() Manifest {
	return Manifest{
		SchemaVersion: ManifestSchemaVersion,
		KernelBundle: kernel.Bundle{
			Packages:    []kernel.Package{},
			DeviceTrees: []kernel.DeviceTree{},
		},
		BootArtifacts:  BootArtifactRecord{DTBs: []ArtifactRecord{}},
		MediaDiscovery: MediaDiscoveryRecord{Evidence: []MediaDiscoveryEvidence{}},
		CompanionBundle: CompanionBundleRecord{
			Included:  false,
			Root:      "sp11/companion",
			Reason:    "not-requested",
			Userspace: []OfflineUserspaceRecord{},
		},
		BootArguments: []string{},
	}
}

// manifestWithIncludedCompanion returns a shape-complete manifest containing
// representative nested records for recursive decoder tests.
func manifestWithIncludedCompanion() Manifest {
	manifest := manifestWithExplicitCompanionAbsence()
	manifest.KernelBundle.Packages = []kernel.Package{{
		Role: kernel.RoleImage, Name: "linux-image-test_arm64.deb",
		SHA256: strings.Repeat("b", 64), Size: 1, Verified: true,
	}}
	manifest.CompanionBundle = CompanionBundleRecord{
		Included: true,
		Root:     "sp11/companion",
		Tool: &ToolIdentityRecord{
			Version: "v0.1.0-test", Commit: "working-tree", BuildDate: "2026-08-30T12:00:00Z",
		},
		ProjectLicence: "declared",
		Executable: &ExecutableArtifactRecord{
			Artifact:        testManifestArtifact("sp11/companion/bin/linux-armer"),
			OperatingSystem: "linux",
			Architecture:    "arm64",
			Format:          "ELF",
			Mode:            "0755",
		},
		SourceArchive: &ArtifactRecord{
			Path: "sp11/companion/source/linux-armer.tar.gz", SHA256: strings.Repeat("a", 64), Size: 1,
		},
		Catalogues: []ArtifactRecord{testManifestArtifact("sp11/companion/catalogues/supported-isos.json")},
		Licences:   []ArtifactRecord{testManifestArtifact("sp11/companion/licences/LICENSE")},
		Userspace: []OfflineUserspaceRecord{{
			Component:      "iptsd-v1",
			Release:        "sp11-iptsd-v1",
			Redistribution: "source-required",
			Root:           "sp11/companion/userspace/iptsd-v1/sp11-iptsd-v1",
			Artifacts: []ArtifactRecord{
				testManifestArtifact("sp11/companion/userspace/iptsd-v1/sp11-iptsd-v1/receipt.json"),
			},
		}},
	}
	return manifest
}

// testManifestArtifact returns one canonical immutable identity for manifest
// decoder tests that do not inspect real filesystem bytes.
func testManifestArtifact(artifactPath string) ArtifactRecord {
	return ArtifactRecord{Path: artifactPath, SHA256: strings.Repeat("a", 64), Size: 1}
}

// TestDecodeManifestRejectsSchemaExpansion verifies untrusted on-media JSON
// cannot add unknown fields or append another JSON value silently.
func TestDecodeManifestRejectsSchemaExpansion(t *testing.T) {
	t.Parallel()

	for _, document := range []string{
		`{"schema_version":3,"companion_bundle":{},"unknown":true}`,
		`{"schema_version":3,"companion_bundle":{}} {"schema_version":3,"companion_bundle":{}}`,
		`{"schema_version":3}`,
		`{"schema_version":3,"companion_bundle":{},"companion_bundle":{}}`,
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
