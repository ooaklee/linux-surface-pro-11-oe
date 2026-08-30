package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	handoffapplication "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/handoff/application"
)

// stubHandoffApplicationWorkflow records delivery-layer application calls.
type stubHandoffApplicationWorkflow struct {
	// plan is the redacted checkpoint returned by Plan.
	plan handoffapplication.Plan
	// planErr is an optional planning failure.
	planErr error
	// result is the successful application result.
	result handoffapplication.Result
	// applyErr is an optional mutation failure.
	applyErr error
	// request records parsed flags.
	request handoffapplication.Request
	// confirmation records exact user confirmation.
	confirmation string
	// applyCalls counts mutation requests.
	applyCalls int
}

// Plan records one parsed request and returns the configured checkpoint.
func (workflow *stubHandoffApplicationWorkflow) Plan(_ context.Context, request handoffapplication.Request) (handoffapplication.Plan, error) {
	workflow.request = request
	return workflow.plan, workflow.planErr
}

// Apply records the checkpoint confirmation and returns the configured result.
func (workflow *stubHandoffApplicationWorkflow) Apply(_ context.Context, _ handoffapplication.Plan, confirmation string) (handoffapplication.Result, error) {
	workflow.applyCalls++
	workflow.confirmation = confirmation
	return workflow.result, workflow.applyErr
}

// stubHandoffRestoreWorkflow records delivery-layer restoration calls.
type stubHandoffRestoreWorkflow struct {
	// plan is the redacted recovery checkpoint returned by PlanRestore.
	plan handoffapplication.RestorePlan
	// result is the configured recovery result.
	result handoffapplication.RestoreResult
	// restoreErr is an optional recovery failure.
	restoreErr error
	// targetRoot records the explicit target selection.
	targetRoot string
	// receiptID records the exact private receipt identifier.
	receiptID string
	// confirmation records exact user confirmation.
	confirmation string
	// restoreCalls counts mutation requests.
	restoreCalls int
}

// PlanRestore records explicit selectors and returns the configured checkpoint.
func (workflow *stubHandoffRestoreWorkflow) PlanRestore(_ context.Context, targetRoot, receiptID string) (handoffapplication.RestorePlan, error) {
	workflow.targetRoot = targetRoot
	workflow.receiptID = receiptID
	return workflow.plan, nil
}

// Restore records confirmation and returns the configured recovery result.
func (workflow *stubHandoffRestoreWorkflow) Restore(_ context.Context, _ handoffapplication.RestorePlan, confirmation string) (handoffapplication.RestoreResult, error) {
	workflow.restoreCalls++
	workflow.confirmation = confirmation
	return workflow.result, workflow.restoreErr
}

// TestHandoffApplyDryRunParsesSelectorsAndWritesRedactedJSON verifies the
// scriptable plan path never invokes mutation and returns one valid envelope.
func TestHandoffApplyDryRunParsesSelectorsAndWritesRedactedJSON(t *testing.T) {
	t.Parallel()
	plan := testHandoffApplicationPlan()
	workflow := &stubHandoffApplicationWorkflow{plan: plan}
	output := &bytes.Buffer{}
	app := &application{in: bytes.NewBuffer(nil), out: output, errOut: &bytes.Buffer{}}
	command := app.newHandoffApplyCommand(workflow)
	command.SetArgs([]string{
		strings.Repeat("a", 64), "--store", "/private/store",
		"--identity-root", "/identity", "--target-root", "/target",
		"--feature", "firmware", "--adsp-policy", "disabled", "--dry-run", "--json",
	})
	if err := command.ExecuteContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	if workflow.applyCalls != 0 {
		t.Fatal("dry-run invoked Apply()")
	}
	if workflow.request.StoreRoot != "/private/store" || workflow.request.IdentityRoot != "/identity" || workflow.request.TargetRoot != "/target" ||
		len(workflow.request.Features) != 1 || workflow.request.Features[0] != handoffapplication.FeatureFirmware || workflow.request.ADSPPolicy != handoffapplication.ADSPDisabled {
		t.Fatalf("parsed application request = %#v", workflow.request)
	}
	var envelope handoffApplyResult
	if err := json.Unmarshal(output.Bytes(), &envelope); err != nil {
		t.Fatalf("decode application envelope: %v\n%s", err, output.String())
	}
	if envelope.Plan.PlanSHA256 != plan.PlanSHA256 || envelope.Result != nil || envelope.Error != "" {
		t.Fatalf("dry-run envelope = %#v", envelope)
	}
}

// TestHandoffApplyFailureKeepsJSONValidAndErrorPrivate verifies a lower-layer
// private failure cannot leak through stdout, stderr, or the returned error.
func TestHandoffApplyFailureKeepsJSONValidAndErrorPrivate(t *testing.T) {
	t.Parallel()
	const privateFailure = "private address 10:20:30:40:50:60"
	plan := testHandoffApplicationPlan()
	workflow := &stubHandoffApplicationWorkflow{plan: plan, applyErr: errors.New(privateFailure)}
	output := &bytes.Buffer{}
	errorOutput := &bytes.Buffer{}
	app := &application{in: bytes.NewBuffer(nil), out: output, errOut: errorOutput}
	command := app.newHandoffApplyCommand(workflow)
	command.SetArgs([]string{
		plan.ID, "--store", "/private/store", "--identity-root", "/identity",
		"--target-root", "/target", "--feature", "firmware", "--adsp-policy", "disabled",
		"--confirm", plan.Confirmation, "--json",
	})
	err := command.ExecuteContext(context.Background())
	if err == nil || strings.Contains(err.Error(), privateFailure) {
		t.Fatalf("application delivery error = %v", err)
	}
	var envelope handoffApplyResult
	if decodeErr := json.Unmarshal(output.Bytes(), &envelope); decodeErr != nil {
		t.Fatalf("failure corrupted JSON: %v\n%s", decodeErr, output.String())
	}
	combined := output.String() + errorOutput.String() + err.Error()
	if strings.Contains(combined, privateFailure) || strings.Contains(combined, "10:20:30") {
		t.Fatalf("application failure disclosed private data: %s", combined)
	}
	if envelope.Error == "" || envelope.Result != nil || workflow.confirmation != plan.Confirmation {
		t.Fatalf("failure envelope/call = %#v / %q", envelope, workflow.confirmation)
	}
}

// TestHandoffRestoreDryRunAndSuccess verifies explicit target selection,
// deterministic recovery confirmation, and both machine-readable phases.
func TestHandoffRestoreDryRunAndSuccess(t *testing.T) {
	t.Parallel()
	receiptID := strings.Repeat("c", 64)
	plan := handoffapplication.RestorePlan{
		ReceiptID: receiptID, TargetRoot: "/target", ReceiptState: "committed",
		RequiredChanges: 3, RecoverySHA256: strings.Repeat("d", 64),
		Confirmation: "restore " + receiptID + " recovery " + strings.Repeat("d", 64) + " from /target",
	}
	workflow := &stubHandoffRestoreWorkflow{plan: plan, result: handoffapplication.RestoreResult{ReceiptID: receiptID, TargetRoot: "/target", Restored: true, Changed: 2}}
	dryOutput := &bytes.Buffer{}
	dryApp := &application{in: bytes.NewBuffer(nil), out: dryOutput, errOut: &bytes.Buffer{}}
	dryCommand := dryApp.newHandoffRestoreCommand(workflow)
	dryCommand.SetArgs([]string{receiptID, "--target-root", "/target", "--dry-run", "--json"})
	if err := dryCommand.ExecuteContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	if workflow.restoreCalls != 0 || workflow.targetRoot != "/target" || workflow.receiptID != receiptID {
		t.Fatalf("restore dry-run calls = %d, %q, %q", workflow.restoreCalls, workflow.targetRoot, workflow.receiptID)
	}
	var dryEnvelope handoffRestoreResult
	if err := json.Unmarshal(dryOutput.Bytes(), &dryEnvelope); err != nil || dryEnvelope.Plan.RecoverySHA256 != plan.RecoverySHA256 {
		t.Fatalf("restore dry-run envelope = %#v, %v", dryEnvelope, err)
	}

	output := &bytes.Buffer{}
	app := &application{in: bytes.NewBuffer(nil), out: output, errOut: &bytes.Buffer{}}
	command := app.newHandoffRestoreCommand(workflow)
	command.SetArgs([]string{receiptID, "--target-root", "/target", "--confirm", plan.Confirmation, "--json"})
	if err := command.ExecuteContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	var envelope handoffRestoreResult
	if err := json.Unmarshal(output.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.Result == nil || !envelope.Result.Restored || workflow.restoreCalls != 1 || workflow.confirmation != plan.Confirmation {
		t.Fatalf("restore result/call = %#v / %d / %q", envelope, workflow.restoreCalls, workflow.confirmation)
	}
}

// TestHandoffCommandRegistersPrivateWorkflows verifies public apply/restore and
// the fixed hidden boot-time command coexist with import, list, and purge.
func TestHandoffCommandRegistersPrivateWorkflows(t *testing.T) {
	t.Parallel()
	app := &application{in: bytes.NewBuffer(nil), out: &bytes.Buffer{}, errOut: &bytes.Buffer{}}
	command := app.newHandoffCommand()
	for _, arguments := range [][]string{{"apply"}, {"restore"}, {"import"}, {"list"}, {"purge"}} {
		if found, _, err := command.Find(arguments); err != nil || found == command {
			t.Fatalf("handoff subcommand %q is not registered: %v", arguments[0], err)
		}
	}
	hidden, _, err := command.Find([]string{"internal-bluetooth-address"})
	if err != nil || !hidden.Hidden {
		t.Fatalf("hidden Bluetooth command = %#v, %v", hidden, err)
	}
}

// testHandoffApplicationPlan returns one fully public stub checkpoint.
func testHandoffApplicationPlan() handoffapplication.Plan {
	identifier := strings.Repeat("a", 64)
	digest := strings.Repeat("b", 64)
	return handoffapplication.Plan{
		ID: identifier, IdentityRoot: "/identity", TargetRoot: "/target",
		Features:   []handoffapplication.Feature{handoffapplication.FeatureFirmware},
		ADSPPolicy: handoffapplication.ADSPDisabled,
		Changes: []handoffapplication.Change{{
			ID: "firmware-gpu-main", Feature: handoffapplication.FeatureFirmware,
			Path: "lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn",
			Kind: handoffapplication.ChangeFile, Required: true,
		}},
		RequiredChanges: 1, HostBinaryCompatible: true, PlanSHA256: digest,
		Confirmation: "apply " + identifier + " plan " + digest + " to /target",
	}
}
