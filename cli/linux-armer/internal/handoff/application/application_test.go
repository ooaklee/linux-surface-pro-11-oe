package application

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/bluetoothmgmt"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff"
)

const (
	// testProductUUID is the canonical non-real UUID used by the public fixture.
	testProductUUID = "12345678-1234-5678-9abc-def012345678"
	// testPrivateAddress is the fixture value used only to assert output redaction.
	testPrivateAddress = "10:20:30:40:50:60"
)

// applicationFixture contains one imported private store and independent roots.
type applicationFixture struct {
	// store is the protected imported hand-off store.
	store string
	// identifier is the public imported manifest content address.
	identifier string
	// entry is the protected imported store child.
	entry string
	// identityRoot contains only the fixture SMBIOS identity.
	identityRoot string
	// targetRoot is the independent installation destination.
	targetRoot string
	// payloads maps compiled firmware identifiers to their test bytes.
	payloads map[string][]byte
	// contract retains fixture-private values for redaction assertions only.
	contract handoff.Contract
}

// TestPlanRequiresExplicitIdentityTargetAndADSPPolicy verifies read-only plan
// gates, feature omission, and redaction without changing the target.
func TestPlanRequiresExplicitIdentityTargetAndADSPPolicy(t *testing.T) {
	t.Parallel()
	fixture := newApplicationFixture(t)
	manager := newTestManager(t, fixture, true, 0)

	if _, err := manager.Plan(context.Background(), Request{StoreRoot: fixture.store, ID: fixture.identifier, IdentityRoot: fixture.identityRoot}); err == nil || !strings.Contains(err.Error(), "target root is required") {
		t.Fatalf("Plan() without target root error = %v", err)
	}
	controlRoot := filepath.Join(t.TempDir(), "target\nspoof")
	if err := os.Mkdir(controlRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Plan(context.Background(), Request{StoreRoot: fixture.store, ID: fixture.identifier, IdentityRoot: fixture.identityRoot, TargetRoot: controlRoot, Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled}); err == nil || !strings.Contains(err.Error(), "control characters") {
		t.Fatalf("Plan() control-character root error = %v", err)
	}
	if _, err := manager.Plan(context.Background(), Request{StoreRoot: fixture.store, ID: fixture.identifier, IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot, Features: []Feature{FeatureFirmware}}); err == nil || !strings.Contains(err.Error(), "aDSP policy") {
		t.Fatalf("Plan() without aDSP policy error = %v", err)
	}

	plan, err := manager.Plan(context.Background(), Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPDisabled,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Features) != 1 || plan.Features[0] != FeatureFirmware || len(plan.Changes) != len(handoff.FirmwarePolicies())+2 {
		t.Fatalf("firmware-only plan = %#v", plan)
	}
	if plan.ADSPPolicy != ADSPDisabled || plan.RequiredChanges != len(handoff.FirmwarePolicies())+1 {
		t.Fatalf("firmware plan policy/changes = %s/%d", plan.ADSPPolicy, plan.RequiredChanges)
	}
	if _, err := os.Stat(filepath.Join(fixture.targetRoot, "lib")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("read-only Plan() changed target: %v", err)
	}
	assertApplicationJSONRedacted(t, plan, fixture)
	material, err := handoff.RevalidateForApplication(context.Background(), fixture.store, fixture.identifier)
	if err != nil {
		t.Fatal(err)
	}
	assertTextRedacted(t, fmt.Sprintf("%s %#v", material, material), fixture)

	bluetoothPlan, err := manager.Plan(context.Background(), Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureBluetooth},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(bluetoothPlan.Changes) != 4 || bluetoothPlan.ADSPPolicy != "" {
		t.Fatalf("Bluetooth-only plan = %#v", bluetoothPlan)
	}
}

// TestPlanRejectsDifferentDeviceWithoutDisclosingIdentity verifies salted
// same-device binding against a root separate from the target root.
func TestPlanRejectsDifferentDeviceWithoutDisclosingIdentity(t *testing.T) {
	t.Parallel()
	fixture := newApplicationFixture(t)
	wrongRoot := t.TempDir()
	writeTestFile(t, filepath.Join(wrongRoot, smbiosProductUUIDPath), []byte("87654321-4321-8765-cba9-876543210fed\n"), 0o644)
	manager := newTestManager(t, fixture, true, 0)
	_, err := manager.Plan(context.Background(), Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: wrongRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled,
	})
	if err == nil || !strings.Contains(err.Error(), "different physical device") {
		t.Fatalf("Plan() wrong-device error = %v", err)
	}
	assertTextRedacted(t, err.Error(), fixture)
}

// TestApplyFirmwareUsesCompiledPolicyAndIsIdempotent verifies all eleven
// payloads, mutually exclusive aDSP paths, the Denali link, modes, and reapply.
func TestApplyFirmwareUsesCompiledPolicyAndIsIdempotent(t *testing.T) {
	fixture := newApplicationFixture(t)
	manager := newTestManager(t, fixture, true, 0)
	request := Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled,
	}
	plan, err := manager.Plan(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Apply(context.Background(), plan, "yes"); err == nil {
		t.Fatal("Apply() accepted a generic confirmation")
	}
	result, err := manager.Apply(context.Background(), plan, plan.Confirmation)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Applied || result.AlreadyApplied || result.Changed != len(handoff.FirmwarePolicies())+1 || result.ReceiptID == "" {
		t.Fatalf("Apply() result = %#v", result)
	}
	for _, policy := range handoff.FirmwarePolicies() {
		content, readErr := os.ReadFile(filepath.Join(fixture.targetRoot, filepath.FromSlash(policy.Destination)))
		if readErr != nil {
			t.Fatalf("read installed %s: %v", policy.ID, readErr)
		}
		if !bytes.Equal(content, fixture.payloads[policy.ID]) {
			t.Fatalf("installed %s bytes differ", policy.ID)
		}
		assertMode(t, filepath.Join(fixture.targetRoot, filepath.FromSlash(policy.Destination)), 0o644)
	}
	if _, err := os.Lstat(filepath.Join(fixture.targetRoot, filepath.FromSlash(DisabledADSPPath))); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("disabled aDSP path exists after enabled policy: %v", err)
	}
	linkTarget, err := os.Readlink(filepath.Join(fixture.targetRoot, filepath.FromSlash(DenaliGPULinkPath)))
	if err != nil || linkTarget != denaliGPULinkTarget {
		t.Fatalf("Denali GPU link = %q, %v", linkTarget, err)
	}
	assertCommittedReceipt(t, fixture.targetRoot, result.ReceiptID)

	nonRoot := newTestManager(t, fixture, true, 1000)
	reapplyPlan, err := nonRoot.Plan(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if reapplyPlan.RequiredChanges != 0 {
		t.Fatalf("idempotent plan requires %d changes", reapplyPlan.RequiredChanges)
	}
	reapplied, err := nonRoot.Apply(context.Background(), reapplyPlan, reapplyPlan.Confirmation)
	if err != nil {
		t.Fatal(err)
	}
	if !reapplied.AlreadyApplied || reapplied.Changed != 0 || reapplied.ReceiptID != "" {
		t.Fatalf("idempotent Apply() result = %#v", reapplied)
	}
}

// TestApplyBluetoothInstallsPrivateRuntimeIntegration verifies private config,
// the compatible helper, fixed unit, dependency link, and redacted results.
func TestApplyBluetoothInstallsPrivateRuntimeIntegration(t *testing.T) {
	fixture := newApplicationFixture(t)
	manager := newTestManager(t, fixture, true, 0)
	request := Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureBluetooth},
	}
	plan, err := manager.Plan(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	result, err := manager.Apply(context.Background(), plan, plan.Confirmation)
	if err != nil {
		t.Fatal(err)
	}
	if result.Changed != 4 {
		t.Fatalf("Bluetooth changed objects = %d, want 4", result.Changed)
	}
	assertMode(t, filepath.Join(fixture.targetRoot, filepath.FromSlash(BluetoothConfigPath)), 0o600)
	assertMode(t, filepath.Join(fixture.targetRoot, filepath.FromSlash(InstalledBinaryPath)), 0o755)
	assertMode(t, filepath.Join(fixture.targetRoot, filepath.FromSlash(BluetoothUnitPath)), 0o644)
	installed, err := os.ReadFile(filepath.Join(fixture.targetRoot, filepath.FromSlash(InstalledBinaryPath)))
	if err != nil {
		t.Fatal(err)
	}
	wantBinary, err := os.ReadFile(manager.executablePath)
	if err != nil || !bytes.Equal(installed, wantBinary) {
		t.Fatal("installed helper differs from reviewed Linux ARM64 executable")
	}
	unit, err := os.ReadFile(filepath.Join(fixture.targetRoot, filepath.FromSlash(BluetoothUnitPath)))
	if err != nil || !bytes.Contains(unit, []byte("handoff internal-bluetooth-address")) || !bytes.Contains(unit, []byte("TimeoutStartSec=9min")) || bytes.Contains(unit, []byte(testPrivateAddress)) {
		t.Fatalf("installed unit is not fixed and private-safe: %v", err)
	}
	link, err := os.Readlink(filepath.Join(fixture.targetRoot, filepath.FromSlash(BluetoothWantsPath)))
	if err != nil || link != bluetoothWantsTarget {
		t.Fatalf("Bluetooth dependency link = %q, %v", link, err)
	}
	address, selector, err := ReadBluetoothRuntimeConfig(context.Background(), fixture.targetRoot)
	if err != nil || selector != bluetoothmgmt.SurfacePro11WCN7850UART || address.String() != "<redacted>" {
		t.Fatalf("ReadBluetoothRuntimeConfig() = %s, %q, %v", address, selector, err)
	}
	assertApplicationJSONRedacted(t, plan, fixture)
	assertApplicationJSONRedacted(t, result, fixture)
}

// TestReadBluetoothRuntimeConfigRejectsIndexAndUnknownSelector verifies a
// private file cannot restore boot-order hci0 selection or choose a new radio.
func TestReadBluetoothRuntimeConfigRejectsIndexAndUnknownSelector(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name    string
		content string
	}{
		{name: "retired controller index", content: `{"schema_version":1,"controller_index":0,"address":"10:20:30:40:50:60"}`},
		{name: "unknown selector", content: `{"schema_version":2,"controller_selector":"external-radio","address":"10:20:30:40:50:60"}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			configPath := filepath.Join(root, filepath.FromSlash(BluetoothConfigPath))
			if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(configPath, []byte(test.content), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, _, err := ReadBluetoothRuntimeConfig(context.Background(), root); err == nil {
				t.Fatal("ReadBluetoothRuntimeConfig() accepted an unsafe controller selection")
			}
		})
	}
}

// TestApplyBluetoothRejectsIncompatibleHostExceptDuringPlanning verifies that
// development hosts may inspect plans but cannot publish an incompatible helper.
func TestApplyBluetoothRejectsIncompatibleHostExceptDuringPlanning(t *testing.T) {
	t.Parallel()
	fixture := newApplicationFixture(t)
	manager := newTestManager(t, fixture, false, 0)
	plan, err := manager.Plan(context.Background(), Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureBluetooth},
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.HostBinaryCompatible {
		t.Fatal("dry-run plan treated an incompatible host binary as compatible")
	}
	if _, err := manager.Apply(context.Background(), plan, plan.Confirmation); err == nil || !strings.Contains(err.Error(), "Linux ARM64 ELF") {
		t.Fatalf("Apply() incompatible-host error = %v", err)
	}
	if _, err := os.Stat(filepath.Join(fixture.targetRoot, "etc")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("incompatible Apply() changed target: %v", err)
	}
}

// TestApplyRevalidatesStoreBeforeMutation verifies a changed imported payload
// cannot be copied from a previously reviewed plan.
func TestApplyRevalidatesStoreBeforeMutation(t *testing.T) {
	t.Parallel()
	fixture := newApplicationFixture(t)
	manager := newTestManager(t, fixture, true, 0)
	plan, err := manager.Plan(context.Background(), Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled,
	})
	if err != nil {
		t.Fatal(err)
	}
	policy := handoff.FirmwarePolicies()[0]
	payloadPath := filepath.Join(fixture.entry, filepath.FromSlash(policy.PayloadPath))
	original := fixture.payloads[policy.ID]
	tampered := bytes.Repeat([]byte{'x'}, len(original))
	writeTestFile(t, payloadPath, tampered, 0o600)
	if _, err := manager.Apply(context.Background(), plan, plan.Confirmation); err == nil {
		t.Fatal("Apply() accepted changed private store material")
	}
	if _, err := os.Stat(filepath.Join(fixture.targetRoot, "lib")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("store-revalidation failure changed target: %v", err)
	}
}

// TestApplyRejectsUnreviewedTargetReplacement verifies the exact plan digest
// binds differing pre-existing bytes rather than only a coarse change flag.
func TestApplyRejectsUnreviewedTargetReplacement(t *testing.T) {
	t.Parallel()
	fixture := newApplicationFixture(t)
	manager := newTestManager(t, fixture, true, 0)
	policy := handoff.FirmwarePolicies()[0]
	targetPath := filepath.Join(fixture.targetRoot, filepath.FromSlash(policy.Destination))
	writeTestFile(t, targetPath, []byte("reviewed original\n"), 0o600)
	request := Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled,
	}
	plan, err := manager.Plan(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	replacement := []byte("unreviewed replacement\n")
	writeTestFile(t, targetPath, replacement, 0o600)
	if _, err := manager.Apply(context.Background(), plan, plan.Confirmation); err == nil || !strings.Contains(err.Error(), "plan no longer matches") {
		t.Fatalf("Apply() target-replacement error = %v", err)
	}
	content, err := os.ReadFile(targetPath)
	if err != nil || !bytes.Equal(content, replacement) {
		t.Fatalf("unreviewed replacement was modified: %v", err)
	}
}

// TestApplyToleratesOwnedReceiptStagingRemnant verifies a power loss before a
// journal rename does not permanently block a later confirmed transaction.
func TestApplyToleratesOwnedReceiptStagingRemnant(t *testing.T) {
	t.Parallel()
	fixture := newApplicationFixture(t)
	manager := newTestManager(t, fixture, true, 0)
	plan, err := manager.Plan(context.Background(), Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled,
	})
	if err != nil {
		t.Fatal(err)
	}
	stagingPath := filepath.Join(fixture.targetRoot, filepath.FromSlash(ReceiptDirectory), ".receipt-0123456789abcdef.tmp")
	writeTestFile(t, stagingPath, []byte("partial private journal"), 0o600)
	if _, err := manager.Apply(context.Background(), plan, plan.Confirmation); err != nil {
		t.Fatalf("Apply() with owned receipt staging remnant: %v", err)
	}
}

// TestApplyRollsBackInjectedFailure verifies same-filesystem quarantine restores
// original bytes and modes and leaves a durable rolled-back receipt.
func TestApplyRollsBackInjectedFailure(t *testing.T) {
	fixture := newApplicationFixture(t)
	manager := newTestManager(t, fixture, true, 0)
	first := handoff.FirmwarePolicies()[0]
	originalPath := filepath.Join(fixture.targetRoot, filepath.FromSlash(first.Destination))
	originalBytes := []byte("pre-existing firmware\n")
	writeTestFile(t, originalPath, originalBytes, 0o600)
	plan, err := manager.Plan(context.Background(), Request{
		StoreRoot: fixture.store, ID: fixture.identifier,
		IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot,
		Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled,
	})
	if err != nil {
		t.Fatal(err)
	}
	manager.hooks.afterApplied = func(string) error { return errors.New("injected application failure") }
	if _, err := manager.Apply(context.Background(), plan, plan.Confirmation); err == nil || !strings.Contains(err.Error(), "injected") {
		t.Fatalf("Apply() injected failure error = %v", err)
	}
	restored, err := os.ReadFile(originalPath)
	if err != nil || !bytes.Equal(restored, originalBytes) {
		t.Fatalf("original firmware was not restored: %v", err)
	}
	assertMode(t, originalPath, 0o600)
	root, err := os.OpenRoot(fixture.targetRoot)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := readReceipt(context.Background(), root, plan.PlanSHA256)
	_ = root.Close()
	if err != nil || receipt.State != receiptRolledBack {
		t.Fatalf("failure receipt state = %s, %v", receipt.State, err)
	}
}

// TestRestoreRecoversCommittedAndInterruptedTransactions verifies deliberate
// rollback and crash-window reconciliation through durable private receipts.
func TestRestoreRecoversCommittedAndInterruptedTransactions(t *testing.T) {
	t.Run("committed", func(t *testing.T) {
		fixture := newApplicationFixture(t)
		manager := newTestManager(t, fixture, true, 0)
		first := handoff.FirmwarePolicies()[0]
		originalPath := filepath.Join(fixture.targetRoot, filepath.FromSlash(first.Destination))
		originalBytes := []byte("original committed target\n")
		writeTestFile(t, originalPath, originalBytes, 0o640)
		request := Request{StoreRoot: fixture.store, ID: fixture.identifier, IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot, Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPDisabled}
		plan, err := manager.Plan(context.Background(), request)
		if err != nil {
			t.Fatal(err)
		}
		applied, err := manager.Apply(context.Background(), plan, plan.Confirmation)
		if err != nil {
			t.Fatal(err)
		}
		restorePlan, err := manager.PlanRestore(context.Background(), fixture.targetRoot, applied.ReceiptID)
		if err != nil {
			t.Fatal(err)
		}
		if restorePlan.RequiredChanges == 0 {
			t.Fatal("committed transaction produced an empty restore plan")
		}
		restored, err := manager.Restore(context.Background(), restorePlan, restorePlan.Confirmation)
		if err != nil {
			t.Fatal(err)
		}
		if !restored.Restored || restored.AlreadyRestored || restored.Changed == 0 {
			t.Fatalf("Restore() result = %#v", restored)
		}
		content, err := os.ReadFile(originalPath)
		if err != nil || !bytes.Equal(content, originalBytes) {
			t.Fatalf("committed original not restored: %v", err)
		}
		assertMode(t, originalPath, 0o640)
		secondPlan, err := manager.PlanRestore(context.Background(), fixture.targetRoot, applied.ReceiptID)
		if err != nil || secondPlan.RequiredChanges != 0 {
			t.Fatalf("second PlanRestore() = %#v, %v", secondPlan, err)
		}
		second, err := manager.Restore(context.Background(), secondPlan, secondPlan.Confirmation)
		if err != nil || !second.AlreadyRestored {
			t.Fatalf("idempotent Restore() = %#v, %v", second, err)
		}
	})

	t.Run("interrupted", func(t *testing.T) {
		fixture := newApplicationFixture(t)
		manager := newTestManager(t, fixture, true, 0)
		plan, err := manager.Plan(context.Background(), Request{StoreRoot: fixture.store, ID: fixture.identifier, IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot, Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled})
		if err != nil {
			t.Fatal(err)
		}
		root, err := os.OpenRoot(fixture.targetRoot)
		if err != nil {
			t.Fatal(err)
		}
		if err := ensureReceiptDirectory(root); err != nil {
			t.Fatal(err)
		}
		receipt, err := manager.prepareReceipt(context.Background(), root, plan)
		if err != nil {
			t.Fatal(err)
		}
		receipt.State = receiptApplying
		if err := writeReceipt(root, receipt); err != nil {
			t.Fatal(err)
		}
		if err := manager.applyAction(context.Background(), root, plan, plan.desired[0], &receipt, 0); err != nil {
			t.Fatal(err)
		}
		if err := root.Close(); err != nil {
			t.Fatal(err)
		}
		restorePlan, err := manager.PlanRestore(context.Background(), fixture.targetRoot, plan.PlanSHA256)
		if err != nil {
			t.Fatal(err)
		}
		if restorePlan.RequiredChanges < 2 {
			t.Fatalf("interrupted restore changes = %d", restorePlan.RequiredChanges)
		}
		if _, err := manager.Restore(context.Background(), restorePlan, restorePlan.Confirmation); err != nil {
			t.Fatal(err)
		}
		first := handoff.FirmwarePolicies()[0]
		if _, err := os.Lstat(filepath.Join(fixture.targetRoot, filepath.FromSlash(first.Destination))); !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("interrupted desired target remains: %v", err)
		}
	})
}

// TestTargetConfinementAndReceiptValidationRejectHostilePaths verifies neither
// intermediate symlinks nor a modified recovery journal gain path authority.
func TestTargetConfinementAndReceiptValidationRejectHostilePaths(t *testing.T) {
	t.Run("intermediate symlink", func(t *testing.T) {
		fixture := newApplicationFixture(t)
		outside := t.TempDir()
		if err := os.Symlink(outside, filepath.Join(fixture.targetRoot, "lib")); err != nil {
			t.Fatal(err)
		}
		manager := newTestManager(t, fixture, true, 0)
		_, err := manager.Plan(context.Background(), Request{StoreRoot: fixture.store, ID: fixture.identifier, IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot, Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled})
		if err == nil {
			t.Fatal("Plan() accepted an escaping intermediate symlink")
		}
		entries, readErr := os.ReadDir(outside)
		if readErr != nil || len(entries) != 0 {
			t.Fatalf("outside path was changed: %v, %v", entries, readErr)
		}
	})

	t.Run("modified receipt", func(t *testing.T) {
		fixture := newApplicationFixture(t)
		manager := newTestManager(t, fixture, true, 0)
		plan, err := manager.Plan(context.Background(), Request{StoreRoot: fixture.store, ID: fixture.identifier, IdentityRoot: fixture.identityRoot, TargetRoot: fixture.targetRoot, Features: []Feature{FeatureFirmware}, ADSPPolicy: ADSPEnabled})
		if err != nil {
			t.Fatal(err)
		}
		applied, err := manager.Apply(context.Background(), plan, plan.Confirmation)
		if err != nil {
			t.Fatal(err)
		}
		receiptFile := filepath.Join(fixture.targetRoot, filepath.FromSlash(receiptPath(applied.ReceiptID)))
		content, err := os.ReadFile(receiptFile)
		if err != nil {
			t.Fatal(err)
		}
		content = bytes.Replace(content, []byte(`"path": "lib/firmware/`), []byte(`"path": "../escape/`), 1)
		writeTestFile(t, receiptFile, content, 0o600)
		if _, err := manager.PlanRestore(context.Background(), fixture.targetRoot, applied.ReceiptID); err == nil {
			t.Fatal("PlanRestore() accepted a hostile receipt path")
		}
	})
}

// newApplicationFixture imports the canonical public test contract after
// replacing each firmware identity with deterministic private test bytes.
func newApplicationFixture(t *testing.T) applicationFixture {
	t.Helper()
	golden, err := os.Open(filepath.Join("..", "testdata", "windows-handoff-v2.golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	contract, decodeErr := handoff.Decode(golden)
	closeErr := golden.Close()
	if decodeErr != nil || closeErr != nil {
		t.Fatal(errors.Join(decodeErr, closeErr))
	}
	root := t.TempDir()
	source := filepath.Join(root, "source")
	store := filepath.Join(root, "store")
	if err := os.MkdirAll(source, 0o755); err != nil {
		t.Fatal(err)
	}
	payloads := make(map[string][]byte, len(contract.PlatformFirmware.Files))
	for index := range contract.PlatformFirmware.Files {
		record := &contract.PlatformFirmware.Files[index]
		payload := []byte("private application test payload for " + record.ID + "\n")
		payloads[record.ID] = append([]byte(nil), payload...)
		digest := sha256.Sum256(payload)
		record.Size = int64(len(payload))
		record.SHA256 = hex.EncodeToString(digest[:])
		writeTestFile(t, filepath.Join(source, filepath.FromSlash(record.PayloadPath)), payload, 0o644)
	}
	var manifest bytes.Buffer
	if err := contract.WriteJSON(&manifest); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(source, handoff.ManifestFilename), manifest.Bytes(), 0o644)
	imported, err := handoff.Import(context.Background(), source, store)
	if err != nil {
		t.Fatal(err)
	}
	identityRoot := filepath.Join(root, "identity")
	writeTestFile(t, filepath.Join(identityRoot, smbiosProductUUIDPath), []byte(testProductUUID+"\n"), 0o644)
	targetRoot := filepath.Join(root, "target")
	if err := os.MkdirAll(targetRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	return applicationFixture{
		store: store, identifier: imported.ID, entry: imported.Path,
		identityRoot: identityRoot, targetRoot: targetRoot,
		payloads: payloads, contract: contract,
	}
}

// newTestManager builds a manager around a minimal reviewed Linux ARM64 ELF.
func newTestManager(t *testing.T, fixture applicationFixture, compatible bool, effectiveUID int) *Manager {
	t.Helper()
	executable := filepath.Join(filepath.Dir(fixture.targetRoot), "linux-armer-test")
	writeMinimalARM64ELF(t, executable)
	goos := "linux"
	goarch := "arm64"
	if !compatible {
		goos = "darwin"
	}
	return New(&Configuration{
		ExecutablePath: executable, RuntimeGOOS: goos, RuntimeGOARCH: goarch,
		EffectiveUID: func() int { return effectiveUID },
	})
}

// writeMinimalARM64ELF writes the smallest header accepted by the ELF parser.
func writeMinimalARM64ELF(t *testing.T, path string) {
	t.Helper()
	header := make([]byte, 64)
	copy(header[:4], []byte{0x7f, 'E', 'L', 'F'})
	header[4] = 2
	header[5] = 1
	header[6] = 1
	binary.LittleEndian.PutUint16(header[16:18], 2)
	binary.LittleEndian.PutUint16(header[18:20], 183)
	binary.LittleEndian.PutUint32(header[20:24], 1)
	binary.LittleEndian.PutUint16(header[52:54], 64)
	writeTestFile(t, path, header, 0o755)
}

// writeTestFile creates parent directories, writes bytes, and fixes permissions.
func writeTestFile(t *testing.T, path string, content []byte, mode fs.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, content, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

// assertMode requires one exact permission mode without following assumptions.
func assertMode(t *testing.T, path string, expected fs.FileMode) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != expected {
		t.Fatalf("%s mode = %04o, want %04o", filepath.Base(path), info.Mode().Perm(), expected)
	}
}

// assertCommittedReceipt verifies the fixed protected receipt and committed state.
func assertCommittedReceipt(t *testing.T, targetRoot, receiptID string) {
	t.Helper()
	receiptFile := filepath.Join(targetRoot, filepath.FromSlash(receiptPath(receiptID)))
	assertMode(t, receiptFile, 0o600)
	root, err := os.OpenRoot(targetRoot)
	if err != nil {
		t.Fatal(err)
	}
	receipt, readErr := readReceipt(context.Background(), root, receiptID)
	closeErr := root.Close()
	if readErr != nil || closeErr != nil {
		t.Fatal(errors.Join(readErr, closeErr))
	}
	if receipt.State != receiptCommitted {
		t.Fatalf("receipt state = %s, want committed", receipt.State)
	}
}

// assertApplicationJSONRedacted verifies public values contain no reusable
// Bluetooth, SMBIOS, binding, or salt material.
func assertApplicationJSONRedacted(t *testing.T, value any, fixture applicationFixture) {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	assertTextRedacted(t, string(encoded), fixture)
}

// assertTextRedacted rejects every private fixture value from one output string.
func assertTextRedacted(t *testing.T, output string, fixture applicationFixture) {
	t.Helper()
	privateValues := []string{
		testProductUUID, testPrivateAddress, fixture.contract.Device.BindingSalt,
		fixture.contract.Device.SMBIOSProductUUIDBindingSHA256,
	}
	for _, privateValue := range privateValues {
		if strings.Contains(output, privateValue) {
			t.Fatalf("output disclosed private hand-off value: %s", output)
		}
	}
}
