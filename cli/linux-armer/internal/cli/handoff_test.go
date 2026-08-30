package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff"
)

// TestHandoffCommandLifecycle verifies import, redacted listing, reviewed purge,
// exact confirmation, and private store removal through the delivery layer.
func TestHandoffCommandLifecycle(t *testing.T) {
	t.Parallel()
	source, privateValues := writeBluetoothOnlyHandoffSource(t)
	store := filepath.Join(t.TempDir(), "private-store")

	importOutput := &bytes.Buffer{}
	importApp := &application{in: bytes.NewBuffer(nil), out: importOutput, errOut: &bytes.Buffer{}}
	importCommand := importApp.newHandoffImportCommand()
	importCommand.SetArgs([]string{source, "--store", store, "--json"})
	if err := importCommand.ExecuteContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	var imported handoff.ImportResult
	if err := json.Unmarshal(importOutput.Bytes(), &imported); err != nil {
		t.Fatalf("decode hand-off import JSON: %v\n%s", err, importOutput.String())
	}
	if imported.Existing || !imported.Summary.BluetoothIncluded || imported.Summary.FirmwareIncluded {
		t.Fatalf("import result = %#v", imported)
	}
	assertNoPrivateHandoffValues(t, importOutput.String(), privateValues)

	listOutput := &bytes.Buffer{}
	listApp := &application{in: bytes.NewBuffer(nil), out: listOutput, errOut: &bytes.Buffer{}}
	listCommand := listApp.newHandoffListCommand()
	listCommand.SetArgs([]string{"--store", store, "--json"})
	if err := listCommand.ExecuteContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	var listed []handoff.StoredSummary
	if err := json.Unmarshal(listOutput.Bytes(), &listed); err != nil {
		t.Fatalf("decode hand-off list JSON: %v\n%s", err, listOutput.String())
	}
	if len(listed) != 1 || listed[0].ID != imported.ID {
		t.Fatalf("listed hand-offs = %#v", listed)
	}
	assertNoPrivateHandoffValues(t, listOutput.String(), privateValues)

	planOutput := &bytes.Buffer{}
	planApp := &application{in: bytes.NewBuffer(nil), out: planOutput, errOut: &bytes.Buffer{}}
	planCommand := planApp.newHandoffPurgeCommand()
	planCommand.SetArgs([]string{imported.ID, "--store", store, "--dry-run", "--json"})
	if err := planCommand.ExecuteContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	var planned handoffPurgeResult
	if err := json.Unmarshal(planOutput.Bytes(), &planned); err != nil {
		t.Fatalf("decode hand-off purge plan: %v\n%s", err, planOutput.String())
	}
	if planned.Purged || planned.Plan.Confirmation != "purge "+imported.ID {
		t.Fatalf("purge plan = %#v", planned)
	}
	if _, err := os.Stat(imported.Path); err != nil {
		t.Fatalf("dry-run changed stored entry: %v", err)
	}
	assertNoPrivateHandoffValues(t, planOutput.String(), privateValues)

	wrongApp := &application{in: bytes.NewBuffer(nil), out: &bytes.Buffer{}, errOut: &bytes.Buffer{}}
	wrongCommand := wrongApp.newHandoffPurgeCommand()
	wrongCommand.SetArgs([]string{imported.ID, "--store", store, "--confirm", "yes"})
	if err := wrongCommand.ExecuteContext(context.Background()); err == nil || !strings.Contains(err.Error(), "exact content-addressed confirmation") {
		t.Fatalf("wrong purge confirmation error = %v", err)
	}
	if _, err := os.Stat(imported.Path); err != nil {
		t.Fatalf("wrong confirmation changed stored entry: %v", err)
	}

	purgeOutput := &bytes.Buffer{}
	purgeApp := &application{in: bytes.NewBuffer(nil), out: purgeOutput, errOut: &bytes.Buffer{}}
	purgeCommand := purgeApp.newHandoffPurgeCommand()
	purgeCommand.SetArgs([]string{imported.ID, "--store", store, "--confirm", planned.Plan.Confirmation, "--json"})
	if err := purgeCommand.ExecuteContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	var purged handoffPurgeResult
	if err := json.Unmarshal(purgeOutput.Bytes(), &purged); err != nil {
		t.Fatalf("decode completed hand-off purge: %v\n%s", err, purgeOutput.String())
	}
	if !purged.Purged {
		t.Fatalf("completed purge = %#v", purged)
	}
	if _, err := os.Stat(imported.Path); !os.IsNotExist(err) {
		t.Fatalf("purged store entry still exists or cannot be inspected: %v", err)
	}
}

// writeBluetoothOnlyHandoffSource creates one valid closed source directory and
// returns raw private values that delivery output must never disclose.
func writeBluetoothOnlyHandoffSource(t *testing.T) (string, []string) {
	t.Helper()
	salt := strings.Repeat("01", 32)
	uuid := "123e4567-e89b-12d3-a456-426614174000"
	address := handoff.BluetoothAddress("20:11:22:33:44:55")
	sourceType := handoff.BluetoothSourcePermanentAddress
	absentReason := handoff.AbsentReasonNotRequested
	deviceBinding, err := handoff.DeriveDeviceBinding(salt, uuid)
	if err != nil {
		t.Fatal(err)
	}
	contract := handoff.Contract{
		SchemaVersion:         handoff.SchemaVersion,
		Kind:                  handoff.ContractKind,
		PrivacyClassification: handoff.PrivacyClassification,
		CreatedAt:             "2026-08-30T12:34:56Z",
		Collector: handoff.CollectorRecord{
			Name: handoff.CollectorName, Version: "2.0.0",
		},
		Device: handoff.DeviceRecord{
			PlatformID: handoff.PlatformID, Architecture: handoff.Architecture,
			BindingSalt: salt, SMBIOSProductUUIDBindingSHA256: deviceBinding,
			WiFiPCIID: handoff.WiFiPCIID,
		},
		PlatformFirmware: handoff.PlatformFirmwareSection{
			Included: false, Reason: &absentReason,
		},
		BluetoothPublicAddress: handoff.BluetoothPublicAddressSection{
			Included: true, Address: &address, Source: &sourceType,
		},
	}
	source := filepath.Join(t.TempDir(), "windows-handoff")
	if err := os.Mkdir(source, 0o700); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(source, handoff.ManifestFilename)
	manifest, err := os.OpenFile(manifestPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	writeErr := contract.WriteJSON(manifest)
	closeErr := manifest.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		t.Fatal(err)
	}
	return source, []string{uuid, string(address), deviceBinding, salt}
}

// assertNoPrivateHandoffValues fails when redacted delivery output contains any
// reusable device, address, binding, or salt value.
func assertNoPrivateHandoffValues(t *testing.T, output string, privateValues []string) {
	t.Helper()
	for _, privateValue := range privateValues {
		if strings.Contains(output, privateValue) {
			t.Fatalf("delivery output disclosed a private hand-off value: %s", output)
		}
	}
}
