package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	camerarelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/release"
)

// fakeCameraReleaseManager records delivery requests and supplies fixed receipts.
type fakeCameraReleaseManager struct {
	prepareRequests  []camerarelease.Request
	validateRequests []camerarelease.ValidationRequest
	prepareReceipt   camerarelease.Receipt
	validateReceipt  camerarelease.ValidationReceipt
	err              error
}

// Prepare records one local release request and returns the configured receipt.
func (manager *fakeCameraReleaseManager) Prepare(_ context.Context, request camerarelease.Request) (camerarelease.Receipt, error) {
	manager.prepareRequests = append(manager.prepareRequests, request)
	return manager.prepareReceipt, manager.err
}

// Validate records one release-validation request and returns the configured receipt.
func (manager *fakeCameraReleaseManager) Validate(_ context.Context, request camerarelease.ValidationRequest) (camerarelease.ValidationReceipt, error) {
	manager.validateRequests = append(manager.validateRequests, request)
	return manager.validateReceipt, manager.err
}

// TestCameraReleasePrepareMapsExplicitPairingAndJSON verifies delivery mapping.
func TestCameraReleasePrepareMapsExplicitPairingAndJSON(t *testing.T) {
	manager := &fakeCameraReleaseManager{prepareReceipt: camerarelease.Receipt{
		Plan: camerarelease.Plan{
			RepositoryRoot: "/fixture/repo", ArtifactsDirectory: "/fixture/build",
			Tag: "camera-v2", KernelTag: "kernel-sp11v19", KernelABI: "kernel-sp11v19-qcom-x1e",
			DryRun: true, Executable: false, ExecutionBlocker: "fixture blocker",
		},
	}}
	var output bytes.Buffer
	app := &application{out: &output}
	command := app.newUserspaceCameraReleasePrepareCommand(manager)
	command.SetArgs([]string{
		"--repository-root", "/fixture/repo", "--from", "/fixture/build",
		"--tag", "camera-v2", "--kernel-tag", "kernel-sp11v19",
		"--kernel-abi", "kernel-sp11v19-qcom-x1e", "--dry-run", "--json",
	})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if len(manager.prepareRequests) != 1 {
		t.Fatalf("prepare requests = %d", len(manager.prepareRequests))
	}
	request := manager.prepareRequests[0]
	if request.RepositoryRoot != "/fixture/repo" || request.ArtifactsDirectory != "/fixture/build" || request.Tag != "camera-v2" || !request.DryRun {
		t.Fatalf("prepare request = %+v", request)
	}
	var receipt camerarelease.Receipt
	if err := json.Unmarshal(output.Bytes(), &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Plan.ExecutionBlocker != "fixture blocker" {
		t.Fatalf("JSON receipt = %+v", receipt)
	}
}

// TestCameraReleaseValidateDeliversHumanResult verifies the validation command.
func TestCameraReleaseValidateDeliversHumanResult(t *testing.T) {
	manager := &fakeCameraReleaseManager{validateReceipt: camerarelease.ValidationReceipt{
		Directory:   "/fixture/release/camera-v2",
		ValidatedAt: time.Date(2026, 8, 30, 16, 0, 0, 0, time.UTC),
		Manifest:    camerarelease.Manifest{Tag: "camera-v2"},
	}}
	var output bytes.Buffer
	app := &application{out: &output}
	command := app.newUserspaceCameraReleaseValidateCommand(manager)
	command.SetArgs([]string{"/fixture/release/camera-v2", "--repository-root", "/fixture/repo"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if len(manager.validateRequests) != 1 || manager.validateRequests[0].Directory != "/fixture/release/camera-v2" || manager.validateRequests[0].RepositoryRoot != "/fixture/repo" {
		t.Fatalf("validate requests = %+v", manager.validateRequests)
	}
	if text := output.String(); !strings.Contains(text, "camera release valid") || !strings.Contains(text, "remote mutation: false") {
		t.Fatalf("validation output = %s", text)
	}
}

// TestCameraReleaseDeliveryRejectsMissingInputsAndDomainErrors checks failures.
func TestCameraReleaseDeliveryRejectsMissingInputsAndDomainErrors(t *testing.T) {
	manager := &fakeCameraReleaseManager{}
	app := &application{out: &bytes.Buffer{}}
	missing := app.newUserspaceCameraReleasePrepareCommand(manager)
	if err := missing.Execute(); err == nil || !strings.Contains(err.Error(), "--from") {
		t.Fatalf("missing-input error = %v", err)
	}
	manager.err = errors.New("fixture validation failure")
	validate := app.newUserspaceCameraReleaseValidateCommand(manager)
	validate.SetArgs([]string{"/fixture/release"})
	if err := validate.Execute(); err == nil || !strings.Contains(err.Error(), "fixture validation failure") {
		t.Fatalf("domain error = %v", err)
	}
}

// TestRootRegistersCameraReleasePreparationAndValidation protects discovery.
func TestRootRegistersCameraReleasePreparationAndValidation(t *testing.T) {
	root := NewRootCommand(strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	for _, path := range [][]string{
		{"userspace", "camera", "release", "prepare"},
		{"userspace", "camera", "release", "validate"},
	} {
		command, remaining, err := root.Find(path)
		if err != nil {
			t.Fatal(err)
		}
		if command.CommandPath() != "linux-armer "+strings.Join(path, " ") || len(remaining) != 0 {
			t.Fatalf("unexpected command resolution: %s %#v", command.CommandPath(), remaining)
		}
	}
}
