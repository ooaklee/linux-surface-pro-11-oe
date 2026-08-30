package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/manager"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/media"
)

// stubRemovableMedia records delivery-layer requests without exposing a host
// device to command tests.
type stubRemovableMedia struct {
	// devices is the read-only discovery result.
	devices []media.Device
	// plan is the immutable plan returned by Plan.
	plan media.WritePlan
	// receipt is the partial or completed result returned by Execute.
	receipt media.Receipt
	// listErr is the configured discovery failure.
	listErr error
	// planErr is the configured planning failure.
	planErr error
	// executeErr is the configured execution failure.
	executeErr error
	// planRequest records the most recent planning request.
	planRequest media.PlanRequest
	// executeRequest records the most recent execution request.
	executeRequest media.ExecuteRequest
}

// List returns the configured device inventory without touching host storage.
func (stub *stubRemovableMedia) List(context.Context) ([]media.Device, error) {
	return append([]media.Device(nil), stub.devices...), stub.listErr
}

// Plan records the request and returns the configured immutable plan.
func (stub *stubRemovableMedia) Plan(_ context.Context, request media.PlanRequest) (media.WritePlan, error) {
	stub.planRequest = request
	return stub.plan, stub.planErr
}

// Execute records the request and returns the configured receipt and error.
func (stub *stubRemovableMedia) Execute(_ context.Context, request media.ExecuteRequest) (media.Receipt, error) {
	stub.executeRequest = request
	return stub.receipt, stub.executeErr
}

// testMediaApplication creates an isolated application around one media stub.
func testMediaApplication(stub *stubRemovableMedia) (*application, *bytes.Buffer, *bytes.Buffer) {
	output := &bytes.Buffer{}
	errorOutput := &bytes.Buffer{}
	return &application{
		in: bytes.NewBuffer(nil), out: output, errOut: errorOutput,
		mediaFactory: func() (removableMediaWorkflow, error) { return stub, nil },
		imageValidator: func(_ context.Context, _ string) (imagecontract.ValidationReport, error) {
			return imagecontract.ValidationReport{
				Path: stub.plan.Image.Path, SHA256: stub.plan.Image.SHA256,
				Size: int64(stub.plan.Image.SizeBytes), Valid: true,
			}, nil
		},
	}, output, errorOutput
}

// TestImageWriteBindsStructuralValidationToPlan verifies a source changed after
// adapter validation cannot proceed to confirmation or removable-media execution.
func TestImageWriteBindsStructuralValidationToPlan(t *testing.T) {
	t.Parallel()
	stub := &stubRemovableMedia{plan: media.WritePlan{
		ID:                 strings.Repeat("3", 64),
		Image:              media.ImageIdentity{Path: "/tmp/test.iso", SHA256: strings.Repeat("4", 64), SizeBytes: 4096},
		Device:             media.Device{Path: "/dev/disk9", Fingerprint: "media:v1:" + strings.Repeat("5", 64), SizeBytes: 8192},
		ConfirmationPhrase: "exact phrase",
	}}
	app, _, _ := testMediaApplication(stub)
	app.imageValidator = func(_ context.Context, _ string) (imagecontract.ValidationReport, error) {
		return imagecontract.ValidationReport{
			Path: stub.plan.Image.Path, SHA256: strings.Repeat("6", 64), Size: 4096, Valid: true,
		}, nil
	}
	command := app.newImageWriteCommand()
	command.SetArgs([]string{"test.iso", "--device", "/dev/disk9", "--dry-run"})
	err := command.ExecuteContext(context.Background())
	if err == nil || !strings.Contains(err.Error(), "validated image identity changed") {
		t.Fatalf("image identity mismatch error = %v", err)
	}
	if stub.executeRequest.Plan.ID != "" {
		t.Fatal("media execution was reached with image bytes that did not pass structural validation")
	}
}

// TestImageWriteBindsValidatedPathToPlan verifies matching bytes reported for
// a different source path cannot authorise the planned removable-media write.
func TestImageWriteBindsValidatedPathToPlan(t *testing.T) {
	t.Parallel()
	stub := &stubRemovableMedia{plan: media.WritePlan{
		ID: strings.Repeat("3", 64),
		Image: media.ImageIdentity{
			Path: "/tmp/planned.iso", SHA256: strings.Repeat("4", 64), SizeBytes: 4096,
		},
		Device: media.Device{
			Path: "/dev/disk9", Fingerprint: "media:v1:" + strings.Repeat("5", 64), SizeBytes: 8192,
		},
		ConfirmationPhrase: "exact phrase",
	}}
	app, _, _ := testMediaApplication(stub)
	app.imageValidator = func(context.Context, string) (imagecontract.ValidationReport, error) {
		return imagecontract.ValidationReport{
			Path: "/tmp/different.iso", SHA256: stub.plan.Image.SHA256,
			Size: 4096, Valid: true,
		}, nil
	}
	command := app.newImageWriteCommand()
	command.SetArgs([]string{"planned.iso", "--device", "/dev/disk9", "--dry-run"})
	err := command.ExecuteContext(context.Background())
	if err == nil || !strings.Contains(err.Error(), "validated path") {
		t.Fatalf("image path mismatch error = %v", err)
	}
	if stub.executeRequest.Plan.ID != "" {
		t.Fatal("media execution was reached with mismatched validated and planned paths")
	}
}

// TestWriteImageCreateResultWarnsAboutUndeclaredCompanionLicence verifies the
// human-readable result warns only when an included bundle lacks licence terms.
func TestWriteImageCreateResultWarnsAboutUndeclaredCompanionLicence(t *testing.T) {
	t.Parallel()

	for _, testCase := range []struct {
		name          string
		companion     imagecontract.CompanionBundleRecord
		warningWanted bool
	}{
		{
			name: "included without declared licence",
			companion: imagecontract.CompanionBundleRecord{
				Included: true, ProjectLicence: "not-declared",
			},
			warningWanted: true,
		},
		{
			name: "included with declared licence",
			companion: imagecontract.CompanionBundleRecord{
				Included: true, ProjectLicence: "declared",
			},
		},
		{
			name: "absent bundle",
			companion: imagecontract.CompanionBundleRecord{
				Included: false, ProjectLicence: "not-declared",
			},
		},
	} {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			var output bytes.Buffer
			app := &application{out: &output}
			result := manager.CreateImageResult{}
			result.Image.CompanionBundle = testCase.companion

			if err := app.writeImageCreateResult(result); err != nil {
				t.Fatalf("writeImageCreateResult() error = %v", err)
			}
			warningPresent := strings.Contains(output.String(), "project licence is not declared")
			if warningPresent != testCase.warningWanted {
				t.Fatalf("licence warning present = %v, want %v\n%s", warningPresent, testCase.warningWanted, output.String())
			}
		})
	}
}

// TestImageDevicesDelivery verifies human and JSON discovery remain read-only
// delivery operations over the removable-media workflow.
func TestImageDevicesDelivery(t *testing.T) {
	t.Parallel()
	device := media.Device{
		Fingerprint: "media:v1:" + strings.Repeat("b", 64), Path: "/dev/disk9",
		SizeBytes: 8 << 30, Bus: "usb", External: true, Removable: true,
		Name: "Reviewed USB", Mounts: []media.Mount{},
	}

	for _, testCase := range []struct {
		name string
		args []string
		json bool
	}{
		{name: "human", args: nil},
		{name: "JSON", args: []string{"--json"}, json: true},
	} {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			app, output, _ := testMediaApplication(&stubRemovableMedia{devices: []media.Device{device}})
			command := app.newImageDevicesCommand()
			command.SetArgs(testCase.args)
			if err := command.ExecuteContext(context.Background()); err != nil {
				t.Fatal(err)
			}
			if testCase.json {
				var decoded []media.Device
				if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
					t.Fatalf("decode devices JSON: %v\n%s", err, output.String())
				}
				if len(decoded) != 1 || decoded[0].Fingerprint != device.Fingerprint {
					t.Fatalf("decoded devices = %#v", decoded)
				}
				return
			}
			for _, expected := range []string{"/dev/disk9", "8.0 GiB", "Reviewed USB", device.Fingerprint} {
				if !strings.Contains(output.String(), expected) {
					t.Errorf("device output does not contain %q:\n%s", expected, output.String())
				}
			}
		})
	}
}

// TestImageWriteDryRunReturnsBoundPlan verifies the non-mutating path validates
// the source and returns the exact destructive phrase without requiring it.
func TestImageWriteDryRunReturnsBoundPlan(t *testing.T) {
	t.Parallel()
	operationPlan := media.WritePlan{
		ID: strings.Repeat("c", 64), Image: media.ImageIdentity{
			Path: "/tmp/test.iso", SHA256: strings.Repeat("d", 64), SizeBytes: 4096,
		},
		Device: media.Device{
			Path: "/dev/disk9", Fingerprint: "media:v1:" + strings.Repeat("9", 64), SizeBytes: 8192,
		},
		ConfirmationPhrase: "ERASE /dev/disk9 DEVICE media:v1:" + strings.Repeat("9", 64) +
			" AND WRITE SHA256 " + strings.Repeat("d", 64),
	}
	stub := &stubRemovableMedia{
		plan:    operationPlan,
		receipt: media.Receipt{State: media.ReceiptStateDryRun, DryRun: true},
	}
	app, output, _ := testMediaApplication(stub)
	command := app.newImageWriteCommand()
	command.SetArgs([]string{"test.iso", "--device", "/dev/disk9", "--dry-run"})
	if err := command.ExecuteContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	if stub.planRequest.ImagePath != "test.iso" || stub.planRequest.Target != "/dev/disk9" {
		t.Fatalf("plan request = %#v", stub.planRequest)
	}
	if !stub.executeRequest.DryRun || stub.executeRequest.Confirmation != "" {
		t.Fatalf("execute request = %#v", stub.executeRequest)
	}
	for _, expected := range []string{"no device changes made", operationPlan.ConfirmationPhrase} {
		if !strings.Contains(output.String(), expected) {
			t.Errorf("dry-run output does not contain %q:\n%s", expected, output.String())
		}
	}
}

// TestImageWriteRequiresExactNonInteractiveConfirmation verifies automation is
// never allowed to degrade the target-bound phrase to a blanket affirmative.
func TestImageWriteRequiresExactNonInteractiveConfirmation(t *testing.T) {
	t.Parallel()
	fingerprint := "media:v1:" + strings.Repeat("8", 64)
	phrase := "ERASE /dev/disk9 DEVICE " + fingerprint + " AND WRITE SHA256 " + strings.Repeat("e", 64)
	stub := &stubRemovableMedia{plan: media.WritePlan{
		ID:     strings.Repeat("f", 64),
		Image:  media.ImageIdentity{Path: "/tmp/test.iso", SHA256: strings.Repeat("e", 64), SizeBytes: 4096},
		Device: media.Device{Path: "/dev/disk9", Fingerprint: fingerprint, SizeBytes: 8192}, ConfirmationPhrase: phrase,
	}}
	app, _, errorOutput := testMediaApplication(stub)
	command := app.newImageWriteCommand()
	command.SetArgs([]string{"test.iso", "--device", "/dev/disk9"})
	err := command.ExecuteContext(context.Background())
	if err == nil || !strings.Contains(err.Error(), "requires --confirm") || !strings.Contains(err.Error(), phrase) {
		t.Fatalf("image write error = %v", err)
	}
	if stub.executeRequest.Plan.ID != "" {
		t.Fatal("media execution was reached without an exact confirmation")
	}
	if !strings.Contains(errorOutput.String(), "operation stopped") {
		t.Fatalf("partial result missing from stderr: %s", errorOutput.String())
	}
}

// TestImageWriteJSONPreservesPartialReceipt verifies a non-zero command still
// emits one decodable result envelope with the furthest durable state.
func TestImageWriteJSONPreservesPartialReceipt(t *testing.T) {
	t.Parallel()
	operationErr := errors.New("simulated read-back failure")
	stub := &stubRemovableMedia{
		plan: media.WritePlan{
			ID:     strings.Repeat("1", 64),
			Image:  media.ImageIdentity{Path: "/tmp/test.iso", SHA256: strings.Repeat("2", 64), SizeBytes: 4096},
			Device: media.Device{Path: "/dev/disk9", SizeBytes: 8192}, ConfirmationPhrase: "exact phrase",
		},
		receipt:    media.Receipt{State: media.ReceiptStateVerifying, WrittenBytes: 4096},
		executeErr: operationErr,
	}
	app, output, _ := testMediaApplication(stub)
	command := app.newImageWriteCommand()
	command.SetArgs([]string{"test.iso", "--device", "/dev/disk9", "--confirm", "exact phrase", "--json"})
	err := command.ExecuteContext(context.Background())
	if !errors.Is(err, operationErr) {
		t.Fatalf("image write error = %v", err)
	}
	var result mediaWriteResult
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatalf("decode partial result: %v\n%s", err, output.String())
	}
	if result.Receipt.State != media.ReceiptStateVerifying || result.Error != operationErr.Error() {
		t.Fatalf("partial result = %#v", result)
	}
}

// TestHumanBytes verifies compact binary-unit rendering at important boundaries.
func TestHumanBytes(t *testing.T) {
	t.Parallel()
	for value, expected := range map[uint64]string{
		0: "0 B", 1023: "1023 B", 1024: "1.0 KiB", 8 << 30: "8.0 GiB",
	} {
		if actual := humanBytes(value); actual != expected {
			t.Errorf("humanBytes(%d) = %q, want %q", value, actual, expected)
		}
	}
}
