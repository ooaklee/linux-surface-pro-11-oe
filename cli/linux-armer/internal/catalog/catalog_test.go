package catalog

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"testing/fstest"
)

// validCatalogJSON is a complete two-entry fixture used to exercise catalogue
// decoding, normalisation, validation, and defensive-copy behaviour.
const validCatalogJSON = `{
  "schema_version": 2,
  "description": "Test catalogue",
  "entries": [
    {
      "id": "zulu-image",
      "name": "Zulu Image",
      "distribution": "Ubuntu",
      "release": "Test",
      "filename": "zulu.iso",
      "architecture": "aarch64",
      "artifact_kind": "iso",
      "url": "https://downloads.example.test/zulu.iso",
      "homepage": "https://example.test/zulu/",
      "adapter": "ubuntu-casper",
      "support_level": "implemented",
      "experimental": true,
      "mutable": false,
      "checksum": {
        "algorithm": "sha256",
        "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      "compatibility_notes": ["Test note"],
      "last_verified": "2026-08-30"
    },
    {
      "id": "alpha-image",
      "name": "Alpha Image",
      "distribution": "Fedora",
      "release": "Test",
      "filename": "alpha.raw.xz",
      "architecture": "arm64",
      "artifact_kind": "raw-xz",
      "url": "https://downloads.example.test/alpha.raw.xz",
      "homepage": "https://example.test/alpha/",
      "adapter": "none",
      "support_level": "catalog-only",
      "experimental": false,
      "mutable": true,
      "compatibility_notes": ["Test note"],
      "last_verified": "2024-02-29"
    }
  ]
}`

// TestLoadNormalizesAndProvidesDeterministicDefensiveHelpers verifies that a
// valid catalogue is normalised, sorted, and exposed without leaking mutable data.
func TestLoadNormalizesAndProvidesDeterministicDefensiveHelpers(t *testing.T) {
	t.Parallel()

	loaded, err := LoadBytes([]byte(validCatalogJSON))
	if err != nil {
		t.Fatalf("LoadBytes() error = %v", err)
	}

	if loaded.SchemaVersion != CurrentSchemaVersion {
		t.Fatalf("SchemaVersion = %d, want %d", loaded.SchemaVersion, CurrentSchemaVersion)
	}
	if loaded.Description != "Test catalogue" {
		t.Fatalf("Description = %q, want %q", loaded.Description, "Test catalogue")
	}
	if loaded.Len() != 2 {
		t.Fatalf("Len() = %d, want 2", loaded.Len())
	}

	entries := loaded.List()
	ids := []string{entries[0].ID, entries[1].ID}
	if want := []string{"alpha-image", "zulu-image"}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("List() IDs = %v, want %v", ids, want)
	}
	if entries[1].Architecture != ArchitectureARM64 {
		t.Fatalf("normalized architecture = %q, want %q", entries[1].Architecture, ArchitectureARM64)
	}

	zulu, ok := loaded.Get("zulu-image")
	if !ok {
		t.Fatal("Get(zulu-image) did not find the entry")
	}
	zulu.CompatibilityNotes[0] = "changed"
	zulu.Checksum.Value = strings.Repeat("b", 64)

	zuluAgain, ok := loaded.Get("zulu-image")
	if !ok {
		t.Fatal("second Get(zulu-image) did not find the entry")
	}
	if zuluAgain.CompatibilityNotes[0] != "Test note" {
		t.Fatalf("Get() exposed mutable notes: %q", zuluAgain.CompatibilityNotes[0])
	}
	if zuluAgain.Checksum.Value != strings.Repeat("a", 64) {
		t.Fatalf("Get() exposed mutable checksum: %q", zuluAgain.Checksum.Value)
	}
	if _, ok := loaded.Get("missing"); ok {
		t.Fatal("Get(missing) found an entry")
	}

	entries[0].CompatibilityNotes[0] = "also changed"
	if got := loaded.List()[0].CompatibilityNotes[0]; got != "Test note" {
		t.Fatalf("List() exposed mutable notes: %q", got)
	}
}

// TestNilCatalogHelpers verifies that read-only helpers treat a nil catalogue as
// an empty collection instead of panicking.
func TestNilCatalogHelpers(t *testing.T) {
	t.Parallel()

	var loaded *Catalog
	if loaded.Len() != 0 {
		t.Fatalf("nil Catalog Len() = %d, want 0", loaded.Len())
	}
	if loaded.List() != nil {
		t.Fatalf("nil Catalog List() = %#v, want nil", loaded.List())
	}
	if _, ok := loaded.Get("anything"); ok {
		t.Fatal("nil Catalog Get() found an entry")
	}
}

// TestNormalizeArchitecture verifies accepted ARM64 spellings and rejects
// unsupported or empty architecture values.
func TestNormalizeArchitecture(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		input   string
		want    Architecture
		wantErr bool
	}{
		{name: "canonical", input: "arm64", want: ArchitectureARM64},
		{name: "alias", input: "aarch64", want: ArchitectureARM64},
		{name: "case and surrounding whitespace", input: " AARCH64\t", want: ArchitectureARM64},
		{name: "unsupported", input: "x86_64", wantErr: true},
		{name: "empty", input: "", wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			got, err := NormalizeArchitecture(test.input)
			if (err != nil) != test.wantErr {
				t.Fatalf("NormalizeArchitecture(%q) error = %v, wantErr %v", test.input, err, test.wantErr)
			}
			if got != test.want {
				t.Fatalf("NormalizeArchitecture(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}

// TestSemanticValidationRules exercises each catalogue field constraint and
// confirms validation errors identify the offending field and corrective rule.
func TestSemanticValidationRules(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		mutate    func(map[string]any)
		wantField string
		wantText  string
	}{
		{
			name: "schema version",
			mutate: func(document map[string]any) {
				document["schema_version"] = float64(3)
			},
			wantField: "schema_version",
			wantText:  "must be 2",
		},
		{
			name: "description",
			mutate: func(document map[string]any) {
				document["description"] = "  "
			},
			wantField: "description",
			wantText:  "must not be empty",
		},
		{
			name: "entries",
			mutate: func(document map[string]any) {
				document["entries"] = []any{}
			},
			wantField: "entries",
			wantText:  "at least one",
		},
		{
			name: "stable ID",
			mutate: func(document map[string]any) {
				firstEntry(document)["id"] = "Not Stable"
			},
			wantField: "entries[0].id",
			wantText:  "lowercase kebab-case",
		},
		{
			name: "duplicate ID",
			mutate: func(document map[string]any) {
				entries := document["entries"].([]any)
				entries[1].(map[string]any)["id"] = entries[0].(map[string]any)["id"]
			},
			wantField: "entries[1].id",
			wantText:  "already used by entries[0].id",
		},
		{
			name: "name",
			mutate: func(document map[string]any) {
				firstEntry(document)["name"] = ""
			},
			wantField: "entries[0].name",
			wantText:  "must not be empty",
		},
		{
			name: "distribution",
			mutate: func(document map[string]any) {
				firstEntry(document)["distribution"] = "\n"
			},
			wantField: "entries[0].distribution",
			wantText:  "must not be empty",
		},
		{
			name: "release",
			mutate: func(document map[string]any) {
				firstEntry(document)["release"] = ""
			},
			wantField: "entries[0].release",
			wantText:  "must not be empty",
		},
		{
			name: "filename required",
			mutate: func(document map[string]any) {
				delete(firstEntry(document), "filename")
			},
			wantField: "entries[0].filename",
			wantText:  "must not be empty",
		},
		{
			name: "portable filename",
			mutate: func(document map[string]any) {
				firstEntry(document)["filename"] = "nested/zulu.iso"
			},
			wantField: "entries[0].filename",
			wantText:  "no path separators",
		},
		{
			name: "architecture",
			mutate: func(document map[string]any) {
				firstEntry(document)["architecture"] = "x86_64"
			},
			wantField: "entries[0].architecture",
			wantText:  "aarch64",
		},
		{
			name: "artifact kind",
			mutate: func(document map[string]any) {
				firstEntry(document)["artifact_kind"] = "zip"
			},
			wantField: "entries[0].artifact_kind",
			wantText:  "raw-xz",
		},
		{
			name: "artifact URL HTTPS",
			mutate: func(document map[string]any) {
				firstEntry(document)["url"] = "http://downloads.example.test/zulu.iso"
			},
			wantField: "entries[0].url",
			wantText:  "must use https",
		},
		{
			name: "homepage hostname",
			mutate: func(document map[string]any) {
				firstEntry(document)["homepage"] = "https:///missing-host"
			},
			wantField: "entries[0].homepage",
			wantText:  "must include a hostname",
		},
		{
			name: "URL credentials",
			mutate: func(document map[string]any) {
				firstEntry(document)["url"] = "https://user:pass@downloads.example.test/zulu.iso"
			},
			wantField: "entries[0].url",
			wantText:  "must not include user credentials",
		},
		{
			name: "URL fragment",
			mutate: func(document map[string]any) {
				firstEntry(document)["homepage"] = "https://example.test/#fragment"
			},
			wantField: "entries[0].homepage",
			wantText:  "must not include a fragment",
		},
		{
			name: "URL filename agreement",
			mutate: func(document map[string]any) {
				firstEntry(document)["url"] = "https://downloads.example.test/renamed.iso"
			},
			wantField: "entries[0].url",
			wantText:  "must equal filename \"zulu.iso\"",
		},
		{
			name: "ISO extension",
			mutate: func(document map[string]any) {
				entry := firstEntry(document)
				entry["filename"] = "zulu.raw.xz"
				entry["url"] = "https://downloads.example.test/zulu.raw.xz"
			},
			wantField: "entries[0].filename",
			wantText:  "must end in .iso",
		},
		{
			name: "raw xz extension",
			mutate: func(document map[string]any) {
				entry := firstEntry(document)
				entry["artifact_kind"] = "raw-xz"
				entry["filename"] = "zulu.iso"
				entry["url"] = "https://downloads.example.test/zulu.iso"
			},
			wantField: "entries[0].filename",
			wantText:  "must end in .raw.xz",
		},
		{
			name: "adapter enum",
			mutate: func(document map[string]any) {
				firstEntry(document)["adapter"] = "future-adapter"
			},
			wantField: "entries[0].adapter",
			wantText:  "ubuntu-casper",
		},
		{
			name: "support level enum",
			mutate: func(document map[string]any) {
				firstEntry(document)["support_level"] = "ready"
			},
			wantField: "entries[0].support_level",
			wantText:  "catalog-only",
		},
		{
			name: "implemented requires adapter",
			mutate: func(document map[string]any) {
				firstEntry(document)["adapter"] = "none"
			},
			wantField: "entries[0].adapter",
			wantText:  "must name an implemented adapter",
		},
		{
			name: "catalog only forbids adapter",
			mutate: func(document map[string]any) {
				firstEntry(document)["support_level"] = "catalog-only"
			},
			wantField: "entries[0].adapter",
			wantText:  "must be \"none\"",
		},
		{
			name: "experimental required",
			mutate: func(document map[string]any) {
				delete(firstEntry(document), "experimental")
			},
			wantField: "entries[0].experimental",
			wantText:  "is required",
		},
		{
			name: "mutable required",
			mutate: func(document map[string]any) {
				delete(firstEntry(document), "mutable")
			},
			wantField: "entries[0].mutable",
			wantText:  "is required",
		},
		{
			name: "checksum algorithm",
			mutate: func(document map[string]any) {
				firstEntry(document)["checksum"].(map[string]any)["algorithm"] = "md5"
			},
			wantField: "entries[0].checksum.algorithm",
			wantText:  "sha512",
		},
		{
			name: "checksum length",
			mutate: func(document map[string]any) {
				firstEntry(document)["checksum"].(map[string]any)["value"] = "abcd"
			},
			wantField: "entries[0].checksum.value",
			wantText:  "exactly 64",
		},
		{
			name: "checksum hexadecimal",
			mutate: func(document map[string]any) {
				firstEntry(document)["checksum"].(map[string]any)["value"] = strings.Repeat("z", 64)
			},
			wantField: "entries[0].checksum.value",
			wantText:  "hexadecimal digits only",
		},
		{
			name: "compatibility notes required",
			mutate: func(document map[string]any) {
				firstEntry(document)["compatibility_notes"] = []any{}
			},
			wantField: "entries[0].compatibility_notes",
			wantText:  "at least one note",
		},
		{
			name: "compatibility note content",
			mutate: func(document map[string]any) {
				firstEntry(document)["compatibility_notes"] = []any{" "}
			},
			wantField: "entries[0].compatibility_notes[0]",
			wantText:  "must not be empty",
		},
		{
			name: "last verified date",
			mutate: func(document map[string]any) {
				firstEntry(document)["last_verified"] = "2025-02-29"
			},
			wantField: "entries[0].last_verified",
			wantText:  "real calendar date",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			document := decodeDocument(t, validCatalogJSON)
			test.mutate(document)
			encoded, err := json.Marshal(document)
			if err != nil {
				t.Fatalf("json.Marshal() error = %v", err)
			}

			_, err = LoadBytes(encoded)
			if err == nil {
				t.Fatal("LoadBytes() error = nil, want validation failure")
			}

			var validationError *ValidationError
			if !errors.As(err, &validationError) {
				t.Fatalf("LoadBytes() error type = %T, want *ValidationError: %v", err, err)
			}
			if !hasIssue(validationError, test.wantField, test.wantText) {
				t.Fatalf("validation issues = %#v, want field %q containing %q", validationError.Issues, test.wantField, test.wantText)
			}
		})
	}
}

// TestValidationAggregatesIssues verifies that validation reports every
// independent problem in one actionable error instead of stopping at the first.
func TestValidationAggregatesIssues(t *testing.T) {
	t.Parallel()

	document := decodeDocument(t, validCatalogJSON)
	document["schema_version"] = float64(99)
	document["description"] = ""
	entry := firstEntry(document)
	entry["id"] = "BAD ID"
	entry["architecture"] = "mips"
	entry["url"] = "http://example.test/not-an-iso"
	entry["last_verified"] = "yesterday"
	encoded, err := json.Marshal(document)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}

	_, err = LoadBytes(encoded)
	var validationError *ValidationError
	if !errors.As(err, &validationError) {
		t.Fatalf("LoadBytes() error = %v, want *ValidationError", err)
	}
	if len(validationError.Issues) < 7 {
		t.Fatalf("aggregated issue count = %d, want at least 7: %v", len(validationError.Issues), err)
	}
	for _, field := range []string{
		"schema_version",
		"description",
		"entries[0].id",
		"entries[0].architecture",
		"entries[0].url",
		"entries[0].last_verified",
	} {
		if !strings.Contains(err.Error(), "\n - "+field+":") {
			t.Errorf("Error() = %q, want actionable line for %s", err, field)
		}
	}
}

// TestDecodeFailures verifies malformed, ambiguous, unknown-field, and nil
// inputs are rejected with useful decoding errors.
func TestDecodeFailures(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "empty", input: "", want: "EOF"},
		{name: "malformed", input: `{`, want: "unexpected EOF"},
		{name: "unknown field", input: strings.Replace(validCatalogJSON, `"description": "Test catalogue",`, `"description": "Test catalogue", "unexpected": true,`, 1), want: "unknown field \"unexpected\""},
		{name: "multiple documents", input: validCatalogJSON + `{}`, want: "multiple JSON values"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			_, err := LoadBytes([]byte(test.input))
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("LoadBytes() error = %v, want text %q", err, test.want)
			}
		})
	}

	if _, err := Load(nil); err == nil || !strings.Contains(err.Error(), "reader is nil") {
		t.Fatalf("Load(nil) error = %v, want nil reader error", err)
	}
}

// TestLoaderEmbeddedAndOverride verifies that the loader uses its embedded
// catalogue by default and gives an explicit file override precedence.
func TestLoaderEmbeddedAndOverride(t *testing.T) {
	t.Parallel()

	embedded := fstest.MapFS{
		"supported-isos.json": &fstest.MapFile{Data: []byte(validCatalogJSON)},
	}
	loader := NewLoader(embedded, "supported-isos.json")

	fromEmbedded, err := loader.Load("")
	if err != nil {
		t.Fatalf("Loader.Load(embedded) error = %v", err)
	}
	if _, ok := fromEmbedded.Get("zulu-image"); !ok {
		t.Fatal("Loader.Load(embedded) did not load embedded entry")
	}

	overrideDocument := decodeDocument(t, validCatalogJSON)
	firstEntry(overrideDocument)["id"] = "override-image"
	overrideData, err := json.Marshal(overrideDocument)
	if err != nil {
		t.Fatalf("json.Marshal(override) error = %v", err)
	}
	overridePath := filepath.Join(t.TempDir(), "override.json")
	if err := os.WriteFile(overridePath, overrideData, 0o600); err != nil {
		t.Fatalf("os.WriteFile() error = %v", err)
	}

	fromOverride, err := loader.Load(overridePath)
	if err != nil {
		t.Fatalf("Loader.Load(override) error = %v", err)
	}
	if _, ok := fromOverride.Get("override-image"); !ok {
		t.Fatal("Loader.Load(override) did not prefer override entry")
	}
	if _, ok := fromOverride.Get("zulu-image"); ok {
		t.Fatal("Loader.Load(override) unexpectedly used embedded entry")
	}
}

// TestLoadFSAndLoaderErrorsIncludeSource verifies invalid filesystem and path
// inputs retain enough source context to diagnose catalogue-loading failures.
func TestLoadFSAndLoaderErrorsIncludeSource(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		load func() error
		want string
	}{
		{
			name: "nil filesystem",
			load: func() error {
				_, err := LoadFS(nil, "catalog.json")
				return err
			},
			want: "filesystem is nil",
		},
		{
			name: "empty path",
			load: func() error {
				_, err := LoadFS(fstest.MapFS{}, "")
				return err
			},
			want: "path is empty",
		},
		{
			name: "missing embedded file",
			load: func() error {
				_, err := NewLoader(fstest.MapFS{}, "missing.json").Load("")
				return err
			},
			want: `open catalog "missing.json"`,
		},
		{
			name: "nil embedded filesystem",
			load: func() error {
				_, err := NewLoader(nil, "catalog.json").Load("")
				return err
			},
			want: "filesystem is nil",
		},
		{
			name: "empty embedded path",
			load: func() error {
				_, err := NewLoader(fstest.MapFS{}, "").Load("")
				return err
			},
			want: "path is empty",
		},
		{
			name: "empty override path direct",
			load: func() error {
				_, err := LoadFile("")
				return err
			},
			want: "path is empty",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			err := test.load()
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want text %q", err, test.want)
			}
		})
	}
}

// TestShippedCatalogContract protects the supported-image inventory, exact
// download URLs, normalised architecture, and intentionally implemented subset.
func TestShippedCatalogContract(t *testing.T) {
	t.Parallel()

	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller() did not return this test file")
	}
	catalogPath := filepath.Join(filepath.Dir(thisFile), "..", "..", "supported-isos.json")
	loaded, err := LoadFile(catalogPath)
	if err != nil {
		t.Fatalf("LoadFile(%q) error = %v", catalogPath, err)
	}

	wantURLs := map[string]string{
		"debian-13-6-0-dvd-1":          "https://cdimage.debian.org/debian-cd/13.6.0/arm64/iso-dvd/debian-13.6.0-arm64-DVD-1.iso",
		"elementary-os-8-1-20260219":   "https://ams3.dl.elementary.io/download/MTc4ODA3NzI1Mg==/elementaryos-8.1-stable-arm64.20260219.iso",
		"fedora-workstation-44-raw":    "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/images/Fedora-Workstation-Disk-44-1.7.aarch64.raw.xz",
		"fedora-workstation-live-44":   "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/Fedora-Workstation-Live-44-1.7.aarch64.iso",
		"pop-os-24-04-arm64-generic-3": "https://iso.pop-os.org/24.04/arm64/generic/3/pop-os_24.04_arm64_generic_3.iso",
		"ubuntu-concept-resolute-x1e":  "https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e-20260326.iso",
	}
	wantFilenames := map[string]string{
		"debian-13-6-0-dvd-1":          "debian-13.6.0-arm64-DVD-1.iso",
		"elementary-os-8-1-20260219":   "elementaryos-8.1-stable-arm64.20260219.iso",
		"fedora-workstation-44-raw":    "Fedora-Workstation-Disk-44-1.7.aarch64.raw.xz",
		"fedora-workstation-live-44":   "Fedora-Workstation-Live-44-1.7.aarch64.iso",
		"pop-os-24-04-arm64-generic-3": "pop-os_24.04_arm64_generic_3.iso",
		"ubuntu-concept-resolute-x1e":  "resolute-desktop-arm64+x1e-20260326.iso",
	}
	wantChecksums := map[string]string{
		"debian-13-6-0-dvd-1":          "0e170d9ff0c53f7b59c8d35793b8ce308ceffd519f8370b949995634e22f5b09",
		"elementary-os-8-1-20260219":   "",
		"fedora-workstation-44-raw":    "0361c13141e6f57e24d6ee5227066c33a45f7f92a95f41d0bbd343e4fd05da18",
		"fedora-workstation-live-44":   "162ba3c552a2d241c7c63ec26777af0255ee1b5a135adc0be986ceed999933ef",
		"pop-os-24-04-arm64-generic-3": "7b4cce0e92dc5c903464e7e7c33760c4417f1400165e9ecfcd064fbceb68ef22",
		"ubuntu-concept-resolute-x1e":  "",
	}
	if loaded.Len() != len(wantURLs) {
		t.Fatalf("shipped catalog Len() = %d, want %d", loaded.Len(), len(wantURLs))
	}

	implementedIDs := make([]string, 0, 1)
	for _, entry := range loaded.List() {
		wantURL, exists := wantURLs[entry.ID]
		if !exists {
			t.Errorf("unexpected shipped catalog ID %q", entry.ID)
			continue
		}
		if entry.URL != wantURL {
			t.Errorf("entry %q URL = %q, want %q", entry.ID, entry.URL, wantURL)
		}
		if entry.Filename != wantFilenames[entry.ID] {
			t.Errorf("entry %q filename = %q, want %q", entry.ID, entry.Filename, wantFilenames[entry.ID])
		}
		wantChecksum := wantChecksums[entry.ID]
		if wantChecksum == "" && entry.Checksum != nil {
			t.Errorf("entry %q checksum = %#v, want none", entry.ID, entry.Checksum)
		}
		if wantChecksum != "" && (entry.Checksum == nil || entry.Checksum.Algorithm != "sha256" || entry.Checksum.Value != wantChecksum) {
			t.Errorf("entry %q checksum = %#v, want SHA-256 %q", entry.ID, entry.Checksum, wantChecksum)
		}
		if entry.Mutable {
			t.Errorf("entry %q is unexpectedly marked mutable", entry.ID)
		}
		if entry.Architecture != ArchitectureARM64 {
			t.Errorf("entry %q architecture = %q, want normalized %q", entry.ID, entry.Architecture, ArchitectureARM64)
		}
		if entry.SupportLevel == SupportLevelImplemented {
			implementedIDs = append(implementedIDs, entry.ID)
		} else if entry.Adapter != AdapterNone || entry.SupportLevel != SupportLevelCatalogOnly {
			t.Errorf("entry %q adapter/support = %q/%q, want none/catalog-only", entry.ID, entry.Adapter, entry.SupportLevel)
		}
	}

	if want := []string{"ubuntu-concept-resolute-x1e"}; !reflect.DeepEqual(implementedIDs, want) {
		t.Fatalf("implemented IDs = %v, want %v", implementedIDs, want)
	}
	ubuntu, ok := loaded.Get("ubuntu-concept-resolute-x1e")
	if !ok {
		t.Fatal("shipped catalog is missing Ubuntu Concept entry")
	}
	if ubuntu.Adapter != AdapterUbuntuCasper || !ubuntu.Experimental {
		t.Fatalf("Ubuntu adapter/experimental = %q/%v, want %q/true", ubuntu.Adapter, ubuntu.Experimental, AdapterUbuntuCasper)
	}
}

// decodeDocument converts a JSON fixture into a mutable document so an
// individual validation test can alter one field without hand-writing JSON.
func decodeDocument(t *testing.T, value string) map[string]any {
	t.Helper()

	var document map[string]any
	if err := json.Unmarshal([]byte(value), &document); err != nil {
		t.Fatalf("json.Unmarshal(test document) error = %v", err)
	}

	return document
}

// firstEntry returns the first mutable entry from a decoded catalogue fixture.
func firstEntry(document map[string]any) map[string]any {
	return document["entries"].([]any)[0].(map[string]any)
}

// hasIssue reports whether a validation result contains the expected field and
// explanatory message fragment.
func hasIssue(validationError *ValidationError, field, text string) bool {
	for _, issue := range validationError.Issues {
		if issue.Field == field && strings.Contains(issue.Message, text) {
			return true
		}
	}

	return false
}
