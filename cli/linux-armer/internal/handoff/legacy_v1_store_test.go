package handoff

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	// legacyTestAdapterBinding is private fixture material used to prove that
	// maintenance output never exposes the retired adapter digest.
	legacyTestAdapterBinding = "45cf6ef73487f756b500d61d3bdc68eb0b1cd32050559c91de1595d4b2294910"
)

// legacyStoreFixture contains one exact version 1 private-store child and the
// sensitive values that must never appear in list or purge output.
type legacyStoreFixture struct {
	// Store is the protected private content-addressed store root.
	Store string
	// Entry is the exact direct child containing the historical closed set.
	Entry string
	// ID is the SHA-256 of the exact historical manifest bytes.
	ID string
	// Contract is the historical typed fixture used to locate payloads.
	Contract legacyStoreContractV1
	// Manifest is the exact byte sequence stored under ManifestFilename.
	Manifest []byte
	// PrivateValues contains every reusable value forbidden from public output.
	PrivateValues []string
}

// TestLegacyStoreCanBeListedAndPurgedSafely proves a valid historical entry is
// redacted, cannot be imported or applied, and uses the ordinary reviewed purge
// transaction without changing a current-schema sibling.
func TestLegacyStoreCanBeListedAndPurgedSafely(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store := filepath.Join(root, "store")
	legacy := newLegacyStoreFixtureAt(t, store, nil, nil)
	currentSource := filepath.Join(root, "current-source")
	current := newStoreFixtureAt(t, currentSource, store, func(contract *Contract) {
		contract.CreatedAt = "2026-08-30T12:36:58Z"
	})
	currentResult, err := Import(context.Background(), current.Source, store)
	if err != nil {
		t.Fatal(err)
	}

	listed, err := List(context.Background(), store)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 2 {
		t.Fatalf("List() returned %d entries, want one version 1 and one version 2 entry", len(listed))
	}
	var legacyListed, currentListed *StoredSummary
	for index := range listed {
		switch listed[index].ID {
		case legacy.ID:
			legacyListed = &listed[index]
		case currentResult.ID:
			currentListed = &listed[index]
		}
	}
	if legacyListed == nil || legacyListed.Summary.SchemaVersion != legacyStoreSchemaVersion || legacyListed.Summary.FirmwareFiles != len(firmwarePolicyTable) {
		t.Fatalf("legacy List() summary = %#v, want a redacted version 1 inventory", legacyListed)
	}
	if currentListed == nil || currentListed.Summary.SchemaVersion != SchemaVersion {
		t.Fatalf("current List() summary = %#v, want unaffected version 2 inventory", currentListed)
	}
	assertLegacyMaintenanceRedacted(t, listed, legacy.PrivateValues)

	if _, err := Import(context.Background(), legacy.Entry, filepath.Join(root, "new-store")); err == nil {
		t.Fatal("Import() accepted a retired version 1 store entry as a source")
	}
	if _, err := RevalidateForApplication(context.Background(), store, legacy.ID); err == nil {
		t.Fatal("RevalidateForApplication() accepted a retired version 1 entry")
	}

	plan, err := PlanPurge(context.Background(), store, legacy.ID)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Summary.SchemaVersion != legacyStoreSchemaVersion || plan.Confirmation != purgeConfirmationPrefix+legacy.ID {
		t.Fatalf("legacy PlanPurge() = %#v, want version 1 and exact content-addressed confirmation", plan)
	}
	assertLegacyMaintenanceRedacted(t, plan, legacy.PrivateValues)
	if err := Purge(context.Background(), plan, "yes"); err == nil {
		t.Fatal("Purge() accepted a blanket confirmation for a version 1 entry")
	}
	assertPathExists(t, legacy.Entry)
	if err := Purge(context.Background(), plan, plan.Confirmation); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(legacy.Entry); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("legacy store entry remained after purge: %v", err)
	}
	assertPathExists(t, currentResult.Path)
	after, err := List(context.Background(), store)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 1 || after[0].ID != currentResult.ID || after[0].Summary.SchemaVersion != SchemaVersion {
		t.Fatalf("List() after legacy purge = %#v, want the untouched version 2 sibling", after)
	}
}

// TestLegacyStoreRejectsMalformedClosedSets proves maintenance compatibility is
// an exact historical validator rather than a permissive directory-deletion path.
func TestLegacyStoreRejectsMalformedClosedSets(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name             string
		mutateContract   func(*legacyStoreContractV1)
		mutateDocument   func([]byte) []byte
		expectedFragment string
	}{
		{
			name: "unknown field",
			mutateDocument: func(document []byte) []byte {
				return bytes.Replace(document, []byte(`"created_at":`), []byte(`"unexpected": true, "created_at":`), 1)
			},
			expectedFragment: "unknown or mis-cased",
		},
		{
			name: "different historical collector version",
			mutateContract: func(contract *legacyStoreContractV1) {
				contract.Collector.Version = "1.0.1"
			},
			expectedFragment: legacyStoreCollectorVersion,
		},
		{
			name: "missing retired adapter digest",
			mutateContract: func(contract *legacyStoreContractV1) {
				contract.BluetoothPublicAddress.AdapterInstanceIDBindingSHA256 = nil
			},
			expectedFragment: "adapter instance digest",
		},
		{
			name: "forged source mapping",
			mutateContract: func(contract *legacyStoreContractV1) {
				contract.PlatformFirmware.Files[0].PayloadPath = "payload/platform-firmware/other.mbn"
			},
			expectedFragment: "payload_path",
		},
		{
			name: "version 2 original INF field",
			mutateDocument: func(document []byte) []byte {
				return bytes.Replace(document, []byte(`"published_inf": "oem1.inf",`), []byte(`"published_inf": "oem1.inf", "original_inf": "qcdx8380.inf",`), 1)
			},
			expectedFragment: "unknown or mis-cased",
		},
		{
			name: "duplicate schema field",
			mutateDocument: func(document []byte) []byte {
				return bytes.Replace(document, []byte(`"schema_version": 1`), []byte(`"schema_version": 1, "schema_version": 1`), 1)
			},
			expectedFragment: "duplicate field",
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := newLegacyStoreFixtureAt(t, filepath.Join(t.TempDir(), "store"), test.mutateContract, test.mutateDocument)
			if _, err := List(context.Background(), fixture.Store); err == nil || !strings.Contains(err.Error(), test.expectedFragment) {
				t.Fatalf("List() error = %v, want %q", err, test.expectedFragment)
			}
			if _, err := PlanPurge(context.Background(), fixture.Store, fixture.ID); err == nil || !strings.Contains(err.Error(), test.expectedFragment) {
				t.Fatalf("PlanPurge() error = %v, want %q", err, test.expectedFragment)
			}
			assertPathExists(t, fixture.Entry)
		})
	}
}

// TestLegacyStoreRejectsLinks proves manifest and payload substitutions are
// rejected without following or modifying their external targets.
func TestLegacyStoreRejectsLinks(t *testing.T) {
	t.Parallel()
	t.Run("manifest leaf", func(t *testing.T) {
		t.Parallel()
		fixture := newLegacyStoreFixtureAt(t, filepath.Join(t.TempDir(), "store"), nil, nil)
		external := filepath.Join(t.TempDir(), "external-manifest")
		writeTestFile(t, external, fixture.Manifest, privateFileMode)
		manifestPath := filepath.Join(fixture.Entry, ManifestFilename)
		if err := os.Remove(manifestPath); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(external, manifestPath); err != nil {
			t.Fatal(err)
		}
		if _, err := List(context.Background(), fixture.Store); err == nil {
			t.Fatal("List() followed a version 1 manifest symbolic link")
		}
		if _, err := PlanPurge(context.Background(), fixture.Store, fixture.ID); err == nil {
			t.Fatal("PlanPurge() followed a version 1 manifest symbolic link")
		}
		assertPathExists(t, external)
	})

	t.Run("payload parent", func(t *testing.T) {
		t.Parallel()
		fixture := newLegacyStoreFixtureAt(t, filepath.Join(t.TempDir(), "store"), nil, nil)
		payloadRoot := filepath.Join(fixture.Entry, "payload")
		external := filepath.Join(t.TempDir(), "external-payload")
		if err := os.Rename(payloadRoot, external); err != nil {
			t.Fatal(err)
		}
		sentinel := filepath.Join(external, "sentinel")
		writeTestFile(t, sentinel, []byte("keep"), privateFileMode)
		if err := os.Symlink(external, payloadRoot); err != nil {
			t.Fatal(err)
		}
		if _, err := PlanPurge(context.Background(), fixture.Store, fixture.ID); err == nil {
			t.Fatal("PlanPurge() followed a version 1 payload-parent symbolic link")
		}
		contents, err := os.ReadFile(sentinel)
		if err != nil || string(contents) != "keep" {
			t.Fatalf("external sentinel changed: contents=%q error=%v", contents, err)
		}
	})
}

// TestLegacyPurgeRejectsPostPlanDrift proves version 1 deletion retains the
// same byte-, mode-, path-, and no-follow checkpoint as current-schema purge.
func TestLegacyPurgeRejectsPostPlanDrift(t *testing.T) {
	t.Parallel()
	t.Run("payload bytes", func(t *testing.T) {
		t.Parallel()
		fixture := newLegacyStoreFixtureAt(t, filepath.Join(t.TempDir(), "store"), nil, nil)
		plan, err := PlanPurge(context.Background(), fixture.Store, fixture.ID)
		if err != nil {
			t.Fatal(err)
		}
		record := fixture.Contract.PlatformFirmware.Files[0]
		payloadPath := filepath.Join(fixture.Entry, filepath.FromSlash(record.PayloadPath))
		writeTestFile(t, payloadPath, bytes.Repeat([]byte{'x'}, int(record.Size)), privateFileMode)
		if err := Purge(context.Background(), plan, plan.Confirmation); err == nil {
			t.Fatal("Purge() accepted version 1 payload drift")
		}
		assertPathExists(t, fixture.Entry)
	})

	t.Run("payload parent link", func(t *testing.T) {
		t.Parallel()
		fixture := newLegacyStoreFixtureAt(t, filepath.Join(t.TempDir(), "store"), nil, nil)
		plan, err := PlanPurge(context.Background(), fixture.Store, fixture.ID)
		if err != nil {
			t.Fatal(err)
		}
		payloadRoot := filepath.Join(fixture.Entry, "payload")
		external := filepath.Join(t.TempDir(), "external-payload")
		if err := os.Rename(payloadRoot, external); err != nil {
			t.Fatal(err)
		}
		sentinel := filepath.Join(external, "sentinel")
		writeTestFile(t, sentinel, []byte("keep"), privateFileMode)
		if err := os.Symlink(external, payloadRoot); err != nil {
			t.Fatal(err)
		}
		if err := Purge(context.Background(), plan, plan.Confirmation); err == nil {
			t.Fatal("Purge() accepted a linked version 1 payload parent after planning")
		}
		contents, err := os.ReadFile(sentinel)
		if err != nil || string(contents) != "keep" {
			t.Fatalf("external sentinel changed: contents=%q error=%v", contents, err)
		}
	})
}

// newLegacyStoreFixtureAt writes one exact content-addressed version 1 entry
// directly into an existing or new private store, matching what an older CLI
// would already have imported before the cut-over.
func newLegacyStoreFixtureAt(
	t *testing.T,
	store string,
	mutateContract func(*legacyStoreContractV1),
	mutateDocument func([]byte) []byte,
) legacyStoreFixture {
	t.Helper()
	mustMkdirAll(t, store, privateDirectoryMode)
	contract := legacyStoreContractFromCurrentFixture(t)
	for index := range contract.PlatformFirmware.Files {
		record := &contract.PlatformFirmware.Files[index]
		payload := testPayloadBytes(index, record.ID)
		record.Size = int64(len(payload))
		record.SHA256 = digestBytes(payload)
	}
	if mutateContract != nil {
		mutateContract(&contract)
	}
	document, err := json.MarshalIndent(contract, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	document = append(document, '\n')
	if mutateDocument != nil {
		document = mutateDocument(document)
	}
	identifier := digestBytes(document)
	entry := filepath.Join(store, identifier)
	mustMkdirAll(t, entry, privateDirectoryMode)
	for index, record := range contract.PlatformFirmware.Files {
		payloadPath := filepath.Join(entry, filepath.FromSlash(record.PayloadPath))
		mustMkdirAll(t, filepath.Dir(payloadPath), privateDirectoryMode)
		writeTestFile(t, payloadPath, testPayloadBytes(index, record.ID), privateFileMode)
	}
	writeTestFile(t, filepath.Join(entry, ManifestFilename), document, privateFileMode)
	privateValues := []string{
		contract.Device.BindingSalt,
		contract.Device.SMBIOSProductUUIDBindingSHA256,
		legacyTestAdapterBinding,
	}
	if contract.BluetoothPublicAddress.Address != nil {
		privateValues = append(privateValues, string(*contract.BluetoothPublicAddress.Address))
	}
	return legacyStoreFixture{
		Store: store, Entry: entry, ID: identifier, Contract: contract,
		Manifest: append([]byte(nil), document...), PrivateValues: privateValues,
	}
}

// legacyStoreContractFromCurrentFixture converts the current golden contract
// into the exact earlier shape without using any production migration path.
func legacyStoreContractFromCurrentFixture(t *testing.T) legacyStoreContractV1 {
	t.Helper()
	current := decodeGoldenContract(t)
	files := make([]legacyStoreFirmwareFileRecord, 0, len(current.PlatformFirmware.Files))
	for _, record := range current.PlatformFirmware.Files {
		files = append(files, legacyStoreFirmwareFileRecord{
			ID: record.ID, SourceName: record.SourceName, PayloadPath: record.PayloadPath,
			Destination: record.Destination, Size: record.Size, SHA256: record.SHA256,
			WindowsSource: legacyStoreWindowsSourceRecord{
				DriverStorePath:    record.WindowsSource.DriverStorePath,
				PublishedINF:       record.WindowsSource.PublishedINF,
				DriverVersion:      record.WindowsSource.DriverVersion,
				CatalogueSHA256:    record.WindowsSource.CatalogueSHA256,
				CatalogueSignature: record.WindowsSource.CatalogueSignature,
			},
		})
	}
	address := *current.BluetoothPublicAddress.Address
	source := *current.BluetoothPublicAddress.Source
	adapterBinding := legacyTestAdapterBinding
	return legacyStoreContractV1{
		SchemaVersion: legacyStoreSchemaVersion, Kind: current.Kind,
		PrivacyClassification: current.PrivacyClassification,
		CreatedAt:             current.CreatedAt,
		Collector: CollectorRecord{
			Name: current.Collector.Name, Version: legacyStoreCollectorVersion,
		},
		Device: current.Device,
		PlatformFirmware: legacyStorePlatformFirmwareSection{
			Included: true, Files: files,
		},
		BluetoothPublicAddress: legacyStoreBluetoothSection{
			Included: true, Address: &address, Source: &source,
			AdapterInstanceIDBindingSHA256: &adapterBinding,
		},
	}
}

// assertLegacyMaintenanceRedacted requires list and purge values to omit every
// reusable historical address, salt, and hardware-binding value.
func assertLegacyMaintenanceRedacted(t *testing.T, value any, privateValues []string) {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	for _, privateValue := range privateValues {
		if bytes.Contains(encoded, []byte(privateValue)) {
			t.Fatalf("maintenance output disclosed private version 1 material: %s", encoded)
		}
	}
}
