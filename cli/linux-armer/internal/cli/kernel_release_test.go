package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/build"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/releaseprep"
)

// stubKernelReleasePreparationManager records delivery requests and returns
// deterministic path-free public contracts.
type stubKernelReleasePreparationManager struct {
	// receipt is returned by Prepare.
	receipt releaseprep.Receipt
	// prepareErr is returned beside receipt.
	prepareErr error
	// manifest is returned by Validate.
	manifest releaseprep.Manifest
	// validateErr is returned by Validate.
	validateErr error
	// requests records preparation calls.
	requests []releaseprep.Request
	// directories records validation calls.
	directories []string
}

// Prepare records request and returns the configured receipt and error.
func (stub *stubKernelReleasePreparationManager) Prepare(_ context.Context, request releaseprep.Request) (releaseprep.Receipt, error) {
	stub.requests = append(stub.requests, request)
	return stub.receipt, stub.prepareErr
}

// Validate records directory and returns the configured manifest and error.
func (stub *stubKernelReleasePreparationManager) Validate(_ context.Context, directory string) (releaseprep.Manifest, error) {
	stub.directories = append(stub.directories, directory)
	return stub.manifest, stub.validateErr
}

// TestKernelReleasePreparePassesExplicitInputsAndRedactsJSON verifies repeated
// source/licence flags reach the manager without private paths entering output.
func TestKernelReleasePreparePassesExplicitInputsAndRedactsJSON(t *testing.T) {
	privateRoot := "/private/workstation/kernel-release"
	manifest := kernelReleaseCLIManifest()
	stub := &stubKernelReleasePreparationManager{receipt: releaseprep.Receipt{
		Plan: releaseprep.Plan{
			BuildDirectory: privateRoot + "/build", OutputDirectory: privateRoot + "/output",
			DryRun: true, Manifest: manifest,
			Bundle:          kernel.Bundle{SchemaVersion: 1, ABI: manifest.ABI, Version: manifest.Version, Architecture: "arm64"},
			BuildProvenance: build.Provenance{WorkVolume: "linux-armer-kernel-build-deadbeefdeadbeef"},
		},
	}}
	app, output := newKernelReleaseCLIApplication(stub)
	err := executeKernelCLICommand(t, app.newKernelCommand(),
		"release", "prepare",
		"--build-dir", privateRoot+"/build",
		"--output-dir", privateRoot+"/output",
		"--release-name", manifest.ReleaseName,
		"--source", privateRoot+"/source-one.tar.xz",
		"--source", privateRoot+"/source-two.tar.zst",
		"--licence", privateRoot+"/LICENSE.txt",
		"--dry-run", "--json",
	)
	if err != nil {
		t.Fatalf("kernel release prepare error = %v", err)
	}
	if len(stub.requests) != 1 {
		t.Fatalf("prepare request count = %d", len(stub.requests))
	}
	request := stub.requests[0]
	if request.BuildDirectory != privateRoot+"/build" || request.OutputDirectory != privateRoot+"/output" ||
		request.ReleaseName != manifest.ReleaseName || !request.DryRun || len(request.SourceAssets) != 2 || len(request.LicenceAssets) != 1 {
		t.Fatalf("prepare request = %#v", request)
	}
	for _, forbidden := range []string{privateRoot, "source_path", "work_volume", "deadbeefdeadbeef"} {
		if strings.Contains(output.String(), forbidden) {
			t.Errorf("JSON output leaked %q:\n%s", forbidden, output.String())
		}
	}
	var decoded releaseprep.Receipt
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("decode preparation receipt: %v\n%s", err, output.String())
	}
	if !decoded.Plan.DryRun || decoded.Plan.Manifest.ReleaseName != manifest.ReleaseName {
		t.Fatalf("decoded receipt = %#v", decoded)
	}
}

// TestKernelReleasePrepareHumanOutputIsPathFree verifies successful local
// publication reports identity and durability without echoing host paths.
func TestKernelReleasePrepareHumanOutputIsPathFree(t *testing.T) {
	privateRoot := "/private/workstation/kernel-release"
	manifest := kernelReleaseCLIManifest()
	stub := &stubKernelReleasePreparationManager{receipt: releaseprep.Receipt{
		Plan: releaseprep.Plan{
			BuildDirectory: privateRoot + "/build", OutputDirectory: privateRoot + "/output",
			Manifest: manifest,
		},
		Published: true, Durable: true,
	}}
	app, output := newKernelReleaseCLIApplication(stub)
	err := executeKernelCLICommand(t, app.newKernelCommand(),
		"release", "prepare",
		"--build-dir", privateRoot+"/build",
		"--output-dir", privateRoot+"/output",
		"--release-name", manifest.ReleaseName,
		"--source", privateRoot+"/source.tar.xz",
		"--licence", privateRoot+"/LICENSE.txt",
	)
	if err != nil {
		t.Fatalf("kernel release prepare error = %v", err)
	}
	for _, expected := range []string{"kernel release prepared", manifest.ReleaseName, "published atomically: true", "durable: true", "hardware-qualified: false"} {
		if !strings.Contains(output.String(), expected) {
			t.Errorf("human output does not contain %q:\n%s", expected, output.String())
		}
	}
	if strings.Contains(output.String(), privateRoot) {
		t.Fatalf("human output leaked a local path:\n%s", output.String())
	}
}

// TestKernelReleasePrepareRequiresCompleteInputs verifies Cobra rejects an
// incomplete preparation request before it reaches the manager.
func TestKernelReleasePrepareRequiresCompleteInputs(t *testing.T) {
	stub := &stubKernelReleasePreparationManager{}
	app, _ := newKernelReleaseCLIApplication(stub)
	err := executeKernelCLICommand(t, app.newKernelCommand(), "release", "prepare")
	if err == nil || !strings.Contains(err.Error(), "required flag") {
		t.Fatalf("missing flags error = %v", err)
	}
	if len(stub.requests) != 0 {
		t.Fatalf("manager received incomplete request: %#v", stub.requests)
	}
}

// TestKernelReleasePrepareJSONPreservesFailureReceipt verifies a late
// publication failure can retain non-private structured evidence.
func TestKernelReleasePrepareJSONPreservesFailureReceipt(t *testing.T) {
	operationErr := errors.New("durability flush failed")
	manifest := kernelReleaseCLIManifest()
	stub := &stubKernelReleasePreparationManager{
		receipt:    releaseprep.Receipt{Plan: releaseprep.Plan{Manifest: manifest}, Published: true},
		prepareErr: operationErr,
	}
	app, output := newKernelReleaseCLIApplication(stub)
	err := executeKernelCLICommand(t, app.newKernelCommand(),
		"release", "prepare", "--build-dir", "/private/build", "--output-dir", "/private/output",
		"--release-name", manifest.ReleaseName, "--source", "/private/source.tar.xz", "--licence", "/private/LICENSE.txt", "--json",
	)
	if !errors.Is(err, operationErr) {
		t.Fatalf("prepare failure = %v, want %v", err, operationErr)
	}
	var receipt releaseprep.Receipt
	if decodeErr := json.Unmarshal(output.Bytes(), &receipt); decodeErr != nil {
		t.Fatalf("decode failure receipt: %v\n%s", decodeErr, output.String())
	}
	if !receipt.Published || receipt.Durable {
		t.Fatalf("failure receipt = %#v", receipt)
	}
}

// TestKernelReleaseValidateSupportsHumanAndJSONOutput verifies validation is
// read-only, path-free, and preserves the public manifest in JSON mode.
func TestKernelReleaseValidateSupportsHumanAndJSONOutput(t *testing.T) {
	manifest := kernelReleaseCLIManifest()
	for _, asJSON := range []bool{false, true} {
		t.Run(map[bool]string{false: "human", true: "JSON"}[asJSON], func(t *testing.T) {
			stub := &stubKernelReleasePreparationManager{manifest: manifest}
			app, output := newKernelReleaseCLIApplication(stub)
			arguments := []string{"release", "validate", "/private/downloads/release"}
			if asJSON {
				arguments = append(arguments, "--json")
			}
			if err := executeKernelCLICommand(t, app.newKernelCommand(), arguments...); err != nil {
				t.Fatalf("kernel release validate error = %v", err)
			}
			if len(stub.directories) != 1 || stub.directories[0] != "/private/downloads/release" {
				t.Fatalf("validation directories = %#v", stub.directories)
			}
			if strings.Contains(output.String(), "/private/downloads") {
				t.Fatalf("validation output leaked the directory:\n%s", output.String())
			}
			if asJSON {
				var decoded releaseprep.Manifest
				if err := json.Unmarshal(output.Bytes(), &decoded); err != nil || decoded.ReleaseName != manifest.ReleaseName {
					t.Fatalf("validation JSON = %#v / %v", decoded, err)
				}
			} else if !strings.Contains(output.String(), "kernel release valid") || !strings.Contains(output.String(), manifest.ABI) {
				t.Fatalf("validation human output:\n%s", output.String())
			}
		})
	}
}

// kernelReleaseCLIManifest returns one concise path-free public fixture.
func kernelReleaseCLIManifest() releaseprep.Manifest {
	return releaseprep.Manifest{
		SchemaVersion: releaseprep.SchemaVersion,
		ReleaseName:   "sp11-qcom-x1e-7.2.0-jg-0sp11v19",
		Experimental:  true, HardwareQualified: false,
		ABI: "7.2.0-jg-0sp11v19-qcom-x1e", Version: "7.2.0-jg-0sp11v19", Architecture: "arm64",
		Assets: []releaseprep.Asset{
			{Name: "LICENSE.txt", Kind: releaseprep.AssetLicence, SHA256: strings.Repeat("1", 64), Size: 10},
			{Name: "linux-image.deb", Kind: releaseprep.AssetPackage, Role: kernel.RoleImage, SHA256: strings.Repeat("2", 64), Size: 20},
			{Name: "linux-modules.deb", Kind: releaseprep.AssetPackage, Role: kernel.RoleModules, SHA256: strings.Repeat("3", 64), Size: 30},
			{Name: "source.tar.xz", Kind: releaseprep.AssetSource, SHA256: strings.Repeat("4", 64), Size: 40},
		},
		BundleFile: releaseprep.BundleFileName, ChecksumFile: releaseprep.ChecksumFileName, NotesFile: releaseprep.ReleaseNotesFileName,
	}
}

// newKernelReleaseCLIApplication constructs one isolated delivery application
// with captured standard output and an injected native release manager.
func newKernelReleaseCLIApplication(manager kernelReleasePreparationManager) (*application, *bytes.Buffer) {
	output := &bytes.Buffer{}
	return &application{out: output, errOut: &bytes.Buffer{}, kernelReleasePrep: manager}, output
}
