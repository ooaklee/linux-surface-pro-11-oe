package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	audiorelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/audio/release"
)

// fakeAudioReleaseManager records delivery requests and returns fixed receipts.
type fakeAudioReleaseManager struct {
	// prepareRequests contains every mapped preparation request.
	prepareRequests []audiorelease.Request
	// validateRequests contains every mapped validation request.
	validateRequests []audiorelease.ValidationRequest
	// prepareReceipt is the configured preparation result.
	prepareReceipt audiorelease.Receipt
	// validateReceipt is the configured validation result.
	validateReceipt audiorelease.ValidationReceipt
	// err is the configured domain failure.
	err error
}

// Prepare records one mapped preparation request and returns the fixture result.
func (manager *fakeAudioReleaseManager) Prepare(_ context.Context, request audiorelease.Request) (audiorelease.Receipt, error) {
	manager.prepareRequests = append(manager.prepareRequests, request)
	return manager.prepareReceipt, manager.err
}

// Validate records one mapped validation request and returns the fixture result.
func (manager *fakeAudioReleaseManager) Validate(_ context.Context, request audiorelease.ValidationRequest) (audiorelease.ValidationReceipt, error) {
	manager.validateRequests = append(manager.validateRequests, request)
	return manager.validateReceipt, manager.err
}

// TestAudioReleasePrepareMapsEveryExplicitInputAndJSON verifies delivery mapping.
func TestAudioReleasePrepareMapsEveryExplicitInputAndJSON(t *testing.T) {
	t.Parallel()
	manager := &fakeAudioReleaseManager{prepareReceipt: audiorelease.Receipt{Plan: audiorelease.Plan{
		RepositoryRoot: "/fixture/repo", SourceRoot: "/fixture/audio", ReleaseDirectory: "/fixture/repo/build/release/sp11-audio-v19c",
		Tag: audiorelease.SupportedTag, KernelTag: "sp11-qcom-x1e-7.2.0-jg-0sp11v19",
		KernelABI: "7.2.0-jg-0sp11v19-qcom-x1e", KernelGeneration: 19,
		Source: audiorelease.SourceProvenance{Release: audiorelease.SourceRelease}, DryRun: true,
	}}}
	var output bytes.Buffer
	command := (&application{out: &output}).newUserspaceAudioReleasePrepareCommand(manager)
	command.SetArgs([]string{
		"--repository-root", "/fixture/repo", "--source-root", "/fixture/audio",
		"--tag", audiorelease.SupportedTag, "--kernel-tag", "sp11-qcom-x1e-7.2.0-jg-0sp11v19",
		"--kernel-abi", "7.2.0-jg-0sp11v19-qcom-x1e", "--dry-run", "--json",
	})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if len(manager.prepareRequests) != 1 {
		t.Fatalf("prepare requests = %d, want 1", len(manager.prepareRequests))
	}
	request := manager.prepareRequests[0]
	if request.RepositoryRoot != "/fixture/repo" || request.SourceRoot != "/fixture/audio" || request.Tag != audiorelease.SupportedTag || !request.DryRun || request.KernelABI != "7.2.0-jg-0sp11v19-qcom-x1e" {
		t.Fatalf("prepare request = %+v", request)
	}
	var receipt audiorelease.Receipt
	if err := json.Unmarshal(output.Bytes(), &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Plan.Source.Release != audiorelease.SourceRelease {
		t.Fatalf("JSON receipt = %+v", receipt)
	}
}

// TestAudioReleasePreparationRendersLocalOnlyHumanResults verifies safe output.
func TestAudioReleasePreparationRendersLocalOnlyHumanResults(t *testing.T) {
	t.Parallel()
	var output bytes.Buffer
	app := &application{out: &output}
	if err := app.writeAudioReleasePreparation(audiorelease.Receipt{Plan: audiorelease.Plan{
		Tag: audiorelease.SupportedTag, KernelTag: "kernel", KernelABI: "abi", DryRun: true,
		Source: audiorelease.SourceProvenance{Release: audiorelease.SourceRelease},
	}}); err != nil {
		t.Fatal(err)
	}
	if text := output.String(); !strings.Contains(text, "audio release dry run") || !strings.Contains(text, "remote mutation: false") {
		t.Fatalf("dry-run output = %s", text)
	}
	output.Reset()
	manifest := &audiorelease.Manifest{Tag: audiorelease.SupportedTag}
	if err := app.writeAudioReleasePreparation(audiorelease.Receipt{
		Plan: audiorelease.Plan{ReleaseDirectory: "/fixture/release"}, Manifest: manifest, Published: true,
	}); err != nil {
		t.Fatal(err)
	}
	if text := output.String(); !strings.Contains(text, "artefacts: 7") || !strings.Contains(text, audiorelease.ManifestName) {
		t.Fatalf("preparation output = %s", text)
	}
}

// TestAudioReleaseValidateMapsRepositoryAndRendersResult verifies validation delivery.
func TestAudioReleaseValidateMapsRepositoryAndRendersResult(t *testing.T) {
	t.Parallel()
	manager := &fakeAudioReleaseManager{validateReceipt: audiorelease.ValidationReceipt{
		Directory: "/fixture/repo/build/release/sp11-audio-v19c", Valid: true,
		Manifest: audiorelease.Manifest{Tag: audiorelease.SupportedTag},
	}}
	var output bytes.Buffer
	command := (&application{out: &output}).newUserspaceAudioReleaseValidateCommand(manager)
	command.SetArgs([]string{"/fixture/repo/build/release/sp11-audio-v19c", "--repository-root", "/fixture/repo"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if len(manager.validateRequests) != 1 || manager.validateRequests[0].RepositoryRoot != "/fixture/repo" || manager.validateRequests[0].Directory != "/fixture/repo/build/release/sp11-audio-v19c" {
		t.Fatalf("validate requests = %+v", manager.validateRequests)
	}
	if text := output.String(); !strings.Contains(text, "audio release valid") || !strings.Contains(text, "remote mutation: false") {
		t.Fatalf("validation output = %s", text)
	}
}

// TestAudioReleaseCommandsRejectMissingInputsAndReturnDomainErrors checks failures.
func TestAudioReleaseCommandsRejectMissingInputsAndReturnDomainErrors(t *testing.T) {
	t.Parallel()
	manager := &fakeAudioReleaseManager{}
	app := &application{out: &bytes.Buffer{}}
	missing := app.newUserspaceAudioReleasePrepareCommand(manager)
	if err := missing.Execute(); err == nil || !strings.Contains(err.Error(), "--source-root") {
		t.Fatalf("missing-input error = %v", err)
	}
	manager.err = errors.New("fixture audio validation failure")
	validate := app.newUserspaceAudioReleaseValidateCommand(manager)
	validate.SetArgs([]string{"/fixture/release"})
	if err := validate.Execute(); err == nil || !strings.Contains(err.Error(), "fixture audio validation failure") {
		t.Fatalf("domain error = %v", err)
	}
}

// TestAudioReleaseCommandHierarchyExposesPrepareAndValidate verifies discovery.
func TestAudioReleaseCommandHierarchyExposesPrepareAndValidate(t *testing.T) {
	t.Parallel()
	command := (&application{out: &bytes.Buffer{}}).newUserspaceAudioCommand(&fakeAudioReleaseManager{})
	for _, path := range [][]string{{"release", "prepare"}, {"release", "validate"}} {
		found, remaining, err := command.Find(path)
		if err != nil {
			t.Fatal(err)
		}
		if found.CommandPath() != "audio "+strings.Join(path, " ") || len(remaining) != 0 {
			t.Fatalf("unexpected command resolution: %s %#v", found.CommandPath(), remaining)
		}
	}
}
