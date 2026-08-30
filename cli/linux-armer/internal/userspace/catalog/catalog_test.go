package catalog

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"testing/fstest"

	linuxarmer "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer"
)

// validUserspaceCatalogJSON is the smallest representative document used as a
// baseline before individual validation cases introduce one invalid property.
const validUserspaceCatalogJSON = `{
  "schema_version": 2,
  "description": "Test userspace catalog.",
  "components": [
    {
      "id": "zulu-component",
      "name": "Zulu Component",
      "level": "supported",
      "capability": "audio",
      "redistribution": "allowed",
      "support_actions": {
        "status": true,
        "pull": true,
        "build": false,
        "install": true
      },
      "release": {
        "url": "https://github.com/example/project/releases/tag/component-v1",
        "tag": "component-v1",
        "asset_allowlist": [
          "component-arm64.deb",
          "SHA256SUMS"
        ]
      },
      "compatibility_evidence": "exact_pair",
      "kernel_compatibility": {
        "minimum_sp11_generation": 12,
        "tested_through_sp11_generation": 19,
        "summary": "This component requires sp11v12 and is tested through sp11v19."
      },
      "notes": ["The release and its kernel form one tested pair."],
      "remediation": "Replace the complete component set when validation fails."
    },
    {
      "id": "alpha-component",
      "name": "Alpha Component",
      "level": "obsolete",
      "capability": "touchscreen",
      "redistribution": "not-applicable",
      "support_actions": {
        "status": true,
        "pull": false,
        "build": false,
        "install": false
      },
      "compatibility_evidence": "source_integrated_prior_validation",
      "notes": ["Current kernels carry this capability in source."],
      "remediation": "Remove the superseded integration through reversible cleanup."
    }
  ]
}`

// TestLoadProvidesDeterministicDefensiveHelpers verifies sorted lookup helpers
// and proves callers cannot mutate the catalogue's stored slices through copies.
func TestLoadProvidesDeterministicDefensiveHelpers(t *testing.T) {
	t.Parallel()

	loaded, err := LoadBytes([]byte(validUserspaceCatalogJSON))
	if err != nil {
		t.Fatalf("LoadBytes() error = %v", err)
	}
	if loaded.SchemaVersion != CurrentSchemaVersion || loaded.Description != "Test userspace catalog." {
		t.Fatalf("catalog metadata = %d/%q", loaded.SchemaVersion, loaded.Description)
	}
	if loaded.Len() != 2 {
		t.Fatalf("Len() = %d, want 2", loaded.Len())
	}
	components := loaded.List()
	if got, want := []string{components[0].ID, components[1].ID}, []string{"alpha-component", "zulu-component"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("List() IDs = %v, want %v", got, want)
	}

	zulu, ok := loaded.Get("zulu-component")
	if !ok {
		t.Fatal("Get(zulu-component) did not find the component")
	}
	zulu.Notes[0] = "changed"
	zulu.Release.AssetAllowlist[0] = "changed.deb"
	zulu.KernelCompatibility.MinimumSP11Generation = 1
	zuluAgain, ok := loaded.Get("zulu-component")
	if !ok {
		t.Fatal("second Get(zulu-component) did not find the component")
	}
	if zuluAgain.Notes[0] != "The release and its kernel form one tested pair." {
		t.Fatalf("Get() exposed mutable notes: %q", zuluAgain.Notes[0])
	}
	if zuluAgain.Release.AssetAllowlist[0] != "component-arm64.deb" {
		t.Fatalf("Get() exposed mutable release assets: %q", zuluAgain.Release.AssetAllowlist[0])
	}
	if zuluAgain.KernelCompatibility.MinimumSP11Generation != 12 {
		t.Fatalf("Get() exposed mutable kernel compatibility: %#v", zuluAgain.KernelCompatibility)
	}
	components[1].Release.AssetAllowlist[0] = "also-changed.deb"
	if got := loaded.List()[1].Release.AssetAllowlist[0]; got != "component-arm64.deb" {
		t.Fatalf("List() exposed mutable release assets: %q", got)
	}
	if _, ok := loaded.Get("missing"); ok {
		t.Fatal("Get(missing) unexpectedly found a component")
	}
}

// TestNilCatalogHelpers verifies that read-only helpers remain safe and empty on
// a nil catalogue receiver.
func TestNilCatalogHelpers(t *testing.T) {
	t.Parallel()

	var loaded *Catalog
	if loaded.Len() != 0 || loaded.List() != nil {
		t.Fatalf("nil catalog Len/List = %d/%#v", loaded.Len(), loaded.List())
	}
	if _, ok := loaded.Get("anything"); ok {
		t.Fatal("nil catalog Get() found a component")
	}
}

// TestSemanticValidationRules exercises each catalogue invariant that keeps
// component metadata declarative, bounded, and safe to consume.
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
				document["description"] = " "
			},
			wantField: "description",
			wantText:  "must not be empty",
		},
		{
			name: "components",
			mutate: func(document map[string]any) {
				document["components"] = []any{}
			},
			wantField: "components",
			wantText:  "at least one",
		},
		{
			name: "stable ID",
			mutate: func(document map[string]any) {
				firstComponent(document)["id"] = "Not Safe"
			},
			wantField: "components[0].id",
			wantText:  "lowercase kebab-case",
		},
		{
			name: "duplicate ID",
			mutate: func(document map[string]any) {
				components := document["components"].([]any)
				components[1].(map[string]any)["id"] = components[0].(map[string]any)["id"]
			},
			wantField: "components[1].id",
			wantText:  "components[0].id",
		},
		{
			name: "name",
			mutate: func(document map[string]any) {
				firstComponent(document)["name"] = ""
			},
			wantField: "components[0].name",
			wantText:  "must not be empty",
		},
		{
			name: "level",
			mutate: func(document map[string]any) {
				firstComponent(document)["level"] = "production"
			},
			wantField: "components[0].level",
			wantText:  "diagnostic-only",
		},
		{
			name: "capability",
			mutate: func(document map[string]any) {
				firstComponent(document)["capability"] = "telepathy"
			},
			wantField: "components[0].capability",
			wantText:  "unsupported capability",
		},
		{
			name: "redistribution",
			mutate: func(document map[string]any) {
				firstComponent(document)["redistribution"] = "unknown"
			},
			wantField: "components[0].redistribution",
			wantText:  "source-required",
		},
		{
			name: "compatibility evidence",
			mutate: func(document map[string]any) {
				firstComponent(document)["compatibility_evidence"] = "assumed"
			},
			wantField: "components[0].compatibility_evidence",
			wantText:  "exact_pair",
		},
		{
			name: "exact pair compatibility required",
			mutate: func(document map[string]any) {
				delete(firstComponent(document), "kernel_compatibility")
			},
			wantField: "components[0].kernel_compatibility",
			wantText:  "required for exact_pair",
		},
		{
			name: "minimum kernel generation",
			mutate: func(document map[string]any) {
				firstComponent(document)["kernel_compatibility"].(map[string]any)["minimum_sp11_generation"] = float64(0)
			},
			wantField: "components[0].kernel_compatibility.minimum_sp11_generation",
			wantText:  "between 1 and 999",
		},
		{
			name: "tested kernel generation",
			mutate: func(document map[string]any) {
				firstComponent(document)["kernel_compatibility"].(map[string]any)["tested_through_sp11_generation"] = float64(11)
			},
			wantField: "components[0].kernel_compatibility.tested_through_sp11_generation",
			wantText:  "between the minimum generation",
		},
		{
			name: "action presence",
			mutate: func(document map[string]any) {
				delete(firstActions(document), "status")
			},
			wantField: "components[0].support_actions.status",
			wantText:  "is required",
		},
		{
			name: "at least one action",
			mutate: func(document map[string]any) {
				actions := firstActions(document)
				for _, key := range []string{"status", "pull", "build", "install"} {
					actions[key] = false
				}
				delete(firstComponent(document), "release")
			},
			wantField: "components[0].support_actions",
			wantText:  "at least one action",
		},
		{
			name: "pull requires release",
			mutate: func(document map[string]any) {
				delete(firstComponent(document), "release")
			},
			wantField: "components[0].support_actions.pull",
			wantText:  "without release metadata",
		},
		{
			name: "release requires pull",
			mutate: func(document map[string]any) {
				firstActions(document)["pull"] = false
			},
			wantField: "components[0].support_actions.pull",
			wantText:  "must be true",
		},
		{
			name: "obsolete actions",
			mutate: func(document map[string]any) {
				components := document["components"].([]any)
				components[1].(map[string]any)["support_actions"].(map[string]any)["build"] = true
			},
			wantField: "components[1].support_actions",
			wantText:  "only expose status",
		},
		{
			name: "unsafe release tag",
			mutate: func(document map[string]any) {
				firstRelease(document)["tag"] = "refs/tags/v1"
			},
			wantField: "components[0].release.tag",
			wantText:  "safe release tag",
		},
		{
			name: "release URL HTTPS",
			mutate: func(document map[string]any) {
				firstRelease(document)["url"] = "http://github.com/example/project/releases/tag/component-v1"
			},
			wantField: "components[0].release.url",
			wantText:  "must use https",
		},
		{
			name: "release URL credentials",
			mutate: func(document map[string]any) {
				firstRelease(document)["url"] = "https://user:pass@github.com/example/project/releases/tag/component-v1"
			},
			wantField: "components[0].release.url",
			wantText:  "user credentials",
		},
		{
			name: "release URL query",
			mutate: func(document map[string]any) {
				firstRelease(document)["url"] = "https://github.com/example/project/releases/tag/component-v1?download=1"
			},
			wantField: "components[0].release.url",
			wantText:  "query or fragment",
		},
		{
			name: "release URL tag agreement",
			mutate: func(document map[string]any) {
				firstRelease(document)["url"] = "https://github.com/example/project/releases/tag/different-v1"
			},
			wantField: "components[0].release.url",
			wantText:  "path must be",
		},
		{
			name: "release assets required",
			mutate: func(document map[string]any) {
				firstRelease(document)["asset_allowlist"] = []any{}
			},
			wantField: "components[0].release.asset_allowlist",
			wantText:  "exact release asset set",
		},
		{
			name: "release asset is flat",
			mutate: func(document map[string]any) {
				firstRelease(document)["asset_allowlist"] = []any{"../component.deb", "SHA256SUMS"}
			},
			wantField: "components[0].release.asset_allowlist[0]",
			wantText:  "safe flat asset filename",
		},
		{
			name: "release asset unique",
			mutate: func(document map[string]any) {
				firstRelease(document)["asset_allowlist"] = []any{"SHA256SUMS", "SHA256SUMS"}
			},
			wantField: "components[0].release.asset_allowlist[1]",
			wantText:  "must be unique",
		},
		{
			name: "release checksum manifest required",
			mutate: func(document map[string]any) {
				firstRelease(document)["asset_allowlist"] = []any{"component.deb"}
			},
			wantField: "components[0].release.asset_allowlist",
			wantText:  "include SHA256SUMS",
		},
		{
			name: "notes required",
			mutate: func(document map[string]any) {
				firstComponent(document)["notes"] = []any{}
			},
			wantField: "components[0].notes",
			wantText:  "at least one note",
		},
		{
			name: "note content",
			mutate: func(document map[string]any) {
				firstComponent(document)["notes"] = []any{" "}
			},
			wantField: "components[0].notes[0]",
			wantText:  "must not be empty",
		},
		{
			name: "remediation required",
			mutate: func(document map[string]any) {
				firstComponent(document)["remediation"] = ""
			},
			wantField: "components[0].remediation",
			wantText:  "must not be empty",
		},
		{
			name: "executable command markup",
			mutate: func(document map[string]any) {
				firstComponent(document)["remediation"] = "Run `sudo installer` now."
			},
			wantField: "components[0].remediation",
			wantText:  "executable command markup",
		},
		{
			name: "executable command chain",
			mutate: func(document map[string]any) {
				firstComponent(document)["notes"] = []any{"Fetch data && install it."}
			},
			wantField: "components[0].notes[0]",
			wantText:  "executable commands",
		},
		{
			name: "writable path",
			mutate: func(document map[string]any) {
				firstComponent(document)["remediation"] = "Replace files under /etc/example."
			},
			wantField: "components[0].remediation",
			wantText:  "writable or host-specific paths",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			document := decodeUserspaceDocument(t, validUserspaceCatalogJSON)
			test.mutate(document)
			data, err := json.Marshal(document)
			if err != nil {
				t.Fatalf("json.Marshal() error = %v", err)
			}
			_, err = LoadBytes(data)
			if err == nil {
				t.Fatal("LoadBytes() error = nil, want validation error")
			}
			var validationError *ValidationError
			if !errors.As(err, &validationError) {
				t.Fatalf("LoadBytes() error type = %T, want *ValidationError: %v", err, err)
			}
			if !hasUserspaceIssue(validationError, test.wantField, test.wantText) {
				t.Fatalf("issues = %#v, want field %q containing %q", validationError.Issues, test.wantField, test.wantText)
			}
		})
	}
}

// TestValidationAggregatesIssues verifies that one load reports all actionable
// semantic problems instead of stopping at the first invalid field.
func TestValidationAggregatesIssues(t *testing.T) {
	t.Parallel()

	document := decodeUserspaceDocument(t, validUserspaceCatalogJSON)
	document["schema_version"] = float64(9)
	document["description"] = ""
	component := firstComponent(document)
	component["id"] = "BAD ID"
	component["level"] = "unknown"
	component["notes"] = []any{}
	component["remediation"] = "sudo bad-command"
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	_, err = LoadBytes(data)
	var validationError *ValidationError
	if !errors.As(err, &validationError) {
		t.Fatalf("LoadBytes() error = %v, want *ValidationError", err)
	}
	if len(validationError.Issues) < 6 {
		t.Fatalf("aggregated issues = %#v, want at least 6", validationError.Issues)
	}
	for _, field := range []string{"schema_version", "description", "components[0].id", "components[0].level", "components[0].notes", "components[0].remediation"} {
		if !strings.Contains(err.Error(), "\n - "+field+":") {
			t.Errorf("Error() = %q, want line for %s", err, field)
		}
	}
}

// TestStrictDecodeFailures verifies rejection of malformed, ambiguous, empty,
// and schema-expanding JSON documents.
func TestStrictDecodeFailures(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "empty", input: "", want: "EOF"},
		{name: "malformed", input: `{`, want: "unexpected EOF"},
		{name: "unknown top-level field", input: strings.Replace(validUserspaceCatalogJSON, `"description": "Test userspace catalog.",`, `"description": "Test userspace catalog.", "unexpected": true,`, 1), want: `unknown field "unexpected"`},
		{name: "unknown component field", input: strings.Replace(validUserspaceCatalogJSON, `"name": "Zulu Component",`, `"name": "Zulu Component", "command": "unsafe",`, 1), want: `unknown field "command"`},
		{name: "unknown action field", input: strings.Replace(validUserspaceCatalogJSON, `"status": true,`, `"status": true, "remove": true,`, 1), want: `unknown field "remove"`},
		{name: "unknown release field", input: strings.Replace(validUserspaceCatalogJSON, `"tag": "component-v1",`, `"tag": "component-v1", "repository": "unexpected",`, 1), want: `unknown field "repository"`},
		{name: "multiple documents", input: validUserspaceCatalogJSON + `{}`, want: "multiple JSON values"},
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
		t.Fatalf("Load(nil) error = %v", err)
	}
}

// TestLoaderEmbeddedAndOverride verifies that the loader uses bundled data by
// default and an explicitly supplied filesystem path when requested.
func TestLoaderEmbeddedAndOverride(t *testing.T) {
	t.Parallel()

	embedded := fstest.MapFS{
		"supported-userspace.json": &fstest.MapFile{Data: []byte(validUserspaceCatalogJSON)},
	}
	loader := NewLoader(embedded, "supported-userspace.json")
	fromEmbedded, err := loader.Load("")
	if err != nil {
		t.Fatalf("Loader.Load(embedded) error = %v", err)
	}
	if _, ok := fromEmbedded.Get("zulu-component"); !ok {
		t.Fatal("embedded catalog does not contain zulu-component")
	}

	overrideDocument := decodeUserspaceDocument(t, validUserspaceCatalogJSON)
	firstComponent(overrideDocument)["id"] = "override-component"
	overrideData, err := json.Marshal(overrideDocument)
	if err != nil {
		t.Fatalf("json.Marshal(override) error = %v", err)
	}
	overridePath := filepath.Join(t.TempDir(), "override.json")
	if err := os.WriteFile(overridePath, overrideData, 0o600); err != nil {
		t.Fatalf("os.WriteFile(override) error = %v", err)
	}
	fromOverride, err := loader.Load(overridePath)
	if err != nil {
		t.Fatalf("Loader.Load(override) error = %v", err)
	}
	if _, ok := fromOverride.Get("override-component"); !ok {
		t.Fatal("override catalog does not contain override-component")
	}
	if _, ok := fromOverride.Get("zulu-component"); ok {
		t.Fatal("override load unexpectedly used embedded first component")
	}
}

// TestLoadSourceErrors verifies clear failures for invalid filesystem, path, and
// loader source configurations.
func TestLoadSourceErrors(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		load func() error
		want string
	}{
		{name: "nil filesystem", load: func() error { _, err := LoadFS(nil, "catalog.json"); return err }, want: "filesystem is nil"},
		{name: "empty filesystem path", load: func() error { _, err := LoadFS(fstest.MapFS{}, ""); return err }, want: "path is empty"},
		{name: "missing filesystem path", load: func() error { _, err := LoadFS(fstest.MapFS{}, "missing.json"); return err }, want: `open userspace catalog "missing.json"`},
		{name: "empty file path", load: func() error { _, err := LoadFile(""); return err }, want: "path is empty"},
		{name: "nil loader filesystem", load: func() error { _, err := NewLoader(nil, "catalog.json").Load(""); return err }, want: "filesystem is nil"},
		{name: "empty loader path", load: func() error { _, err := NewLoader(fstest.MapFS{}, "").Load(""); return err }, want: "path is empty"},
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

// TestShippedUserspaceCatalogContract pins the supported component inventory,
// exact release metadata, and important support-level distinctions.
func TestShippedUserspaceCatalogContract(t *testing.T) {
	t.Parallel()

	loaded, err := LoadFS(linuxarmer.UserspaceCatalogFS(), "supported-userspace.json")
	if err != nil {
		t.Fatalf("LoadFS(shipped userspace catalog) error = %v", err)
	}
	wantIDs := []string{
		"audio-fullio-v19c",
		"bluetooth",
		"firmware",
		"g6-pen",
		"imx681-libcamera-v1",
		"iptsd-v1",
		"oot-touchscreen",
		"power-profiles",
		"wifi",
	}
	components := loaded.List()
	gotIDs := make([]string, 0, len(components))
	for _, component := range components {
		gotIDs = append(gotIDs, component.ID)
	}
	if !reflect.DeepEqual(gotIDs, wantIDs) {
		t.Fatalf("shipped component IDs = %v, want %v", gotIDs, wantIDs)
	}

	releaseComponents := make(map[string]*Release)
	for _, component := range components {
		if component.Release != nil {
			releaseComponents[component.ID] = component.Release
		}
	}
	if len(releaseComponents) != 3 || releaseComponents["audio-fullio-v19c"] == nil || releaseComponents["imx681-libcamera-v1"] == nil || releaseComponents["iptsd-v1"] == nil {
		t.Fatalf("release-backed components = %#v", releaseComponents)
	}
	if got := releaseComponents["audio-fullio-v19c"].Tag; got != "sp11-audio-v19c" {
		t.Errorf("audio release tag = %q", got)
	}
	if got := len(releaseComponents["audio-fullio-v19c"].AssetAllowlist); got != 6 {
		t.Errorf("audio asset count = %d, want 6", got)
	}
	if got := releaseComponents["imx681-libcamera-v1"].Tag; got != "sp11-imx681-libcamera-v1" {
		t.Errorf("camera release tag = %q", got)
	}
	if got := len(releaseComponents["imx681-libcamera-v1"].AssetAllowlist); got != 9 {
		t.Errorf("camera asset count = %d, want 9", got)
	}
	if got := releaseComponents["iptsd-v1"].Tag; got != "sp11-iptsd-v1" {
		t.Errorf("iptsd release tag = %q", got)
	}
	if got := len(releaseComponents["iptsd-v1"].AssetAllowlist); got != 3 {
		t.Errorf("iptsd asset count = %d, want 3", got)
	}

	firmware, _ := loaded.Get("firmware")
	if firmware.Level != LevelRequired || firmware.Redistribution != RedistributionRestricted {
		t.Errorf("firmware level/redistribution = %q/%q", firmware.Level, firmware.Redistribution)
	}
	g6Pen, _ := loaded.Get("g6-pen")
	if g6Pen.Level != LevelDiagnosticOnly || g6Pen.SupportActions.Install {
		t.Errorf("g6-pen level/install = %q/%v", g6Pen.Level, g6Pen.SupportActions.Install)
	}
	ootTouchscreen, _ := loaded.Get("oot-touchscreen")
	if ootTouchscreen.Level != LevelObsolete || ootTouchscreen.SupportActions.Pull || ootTouchscreen.SupportActions.Build || ootTouchscreen.SupportActions.Install {
		t.Errorf("obsolete touchscreen contract = %#v", ootTouchscreen)
	}
}

// TestCatalogEmbeddingsAreSeparate verifies that image and userspace consumers
// receive only their respective embedded catalogue files.
func TestCatalogEmbeddingsAreSeparate(t *testing.T) {
	t.Parallel()

	if _, err := fs.ReadFile(linuxarmer.UserspaceCatalogFS(), "supported-userspace.json"); err != nil {
		t.Fatalf("UserspaceCatalogFS() cannot read supported-userspace.json: %v", err)
	}
	if _, err := fs.ReadFile(linuxarmer.UserspaceCatalogFS(), "supported-isos.json"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("UserspaceCatalogFS() unexpectedly contains supported-isos.json: %v", err)
	}
	if _, err := fs.ReadFile(linuxarmer.CatalogFS(), "supported-userspace.json"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("CatalogFS() unexpectedly contains supported-userspace.json: %v", err)
	}
}

// decodeUserspaceDocument turns a JSON fixture into a mutable document for one
// validation mutation and fails the owning test if the baseline is malformed.
func decodeUserspaceDocument(t *testing.T, input string) map[string]any {
	t.Helper()
	var document map[string]any
	if err := json.Unmarshal([]byte(input), &document); err != nil {
		t.Fatalf("json.Unmarshal(test document) error = %v", err)
	}
	return document
}

// firstComponent returns the first fixture component for concise table mutations.
func firstComponent(document map[string]any) map[string]any {
	return document["components"].([]any)[0].(map[string]any)
}

// firstActions returns the first fixture component's action map.
func firstActions(document map[string]any) map[string]any {
	return firstComponent(document)["support_actions"].(map[string]any)
}

// firstRelease returns the first fixture component's release metadata map.
func firstRelease(document map[string]any) map[string]any {
	return firstComponent(document)["release"].(map[string]any)
}

// hasUserspaceIssue reports whether validation produced the expected field and
// diagnostic fragment among its aggregated issues.
func hasUserspaceIssue(validationError *ValidationError, field, text string) bool {
	for _, issue := range validationError.Issues {
		if issue.Field == field && strings.Contains(issue.Message, text) {
			return true
		}
	}
	return false
}
