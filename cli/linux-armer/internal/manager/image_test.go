package manager

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	linuxarmer "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/catalog"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/release"
)

// TestImageManagerPlanDefaultsAndDeterminism verifies default source and kernel
// inputs produce the same ordered, serialisable execution plan on every call.
func TestImageManagerPlanDefaultsAndDeterminism(t *testing.T) {
	t.Parallel()

	manager := &ImageManager{}
	request := CreateImageRequest{Output: "/output/linux-armer.iso"}
	first, err := manager.Plan(request)
	if err != nil {
		t.Fatalf("first Plan() error = %v", err)
	}
	second, err := manager.Plan(request)
	if err != nil {
		t.Fatalf("second Plan() error = %v", err)
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("Plan() is not deterministic:\nfirst: %#v\nsecond: %#v", first, second)
	}

	var firstJSON bytes.Buffer
	if err := first.WriteJSON(&firstJSON); err != nil {
		t.Fatalf("first WriteJSON() error = %v", err)
	}
	var secondJSON bytes.Buffer
	if err := second.WriteJSON(&secondJSON); err != nil {
		t.Fatalf("second WriteJSON() error = %v", err)
	}
	if firstJSON.String() != secondJSON.String() {
		t.Fatalf("serialized plans differ:\nfirst:\n%s\nsecond:\n%s", firstJSON.String(), secondJSON.String())
	}

	wantStepIDs := []string{
		"verify-source", "verify-kernel", "prepare-tools", "extract-live-root", "install-kernel",
		"assemble-initramfs-root", "build-initramfs", "bind-live-media", "pair-device-trees", "repack-live-root",
		"replay-hybrid-boot", "validate-output", "publish-output",
	}
	gotStepIDs := make([]string, 0, len(first.Steps))
	for _, step := range first.Steps {
		gotStepIDs = append(gotStepIDs, step.ID)
	}
	if !reflect.DeepEqual(gotStepIDs, wantStepIDs) {
		t.Fatalf("Plan() step IDs = %v, want %v", gotStepIDs, wantStepIDs)
	}
	if want := "catalog:" + DefaultCatalogID; first.Steps[0].Inputs["path"] != want {
		t.Errorf("source input = %q, want %q", first.Steps[0].Inputs["path"], want)
	}
	if want := release.DefaultRepository + "@latest"; first.Steps[1].Inputs["release"] != want {
		t.Errorf("kernel input = %q, want %q", first.Steps[1].Inputs["release"], want)
	}
	if first.Steps[len(first.Steps)-1].Inputs["path"] != request.Output {
		t.Errorf("publish path = %q, want %q", first.Steps[len(first.Steps)-1].Inputs["path"], request.Output)
	}
}

// TestImageManagerPlanUsesExplicitLocalInputs verifies user-provided source,
// kernel directory, catalogue identifier, and output replace all plan defaults.
func TestImageManagerPlanUsesExplicitLocalInputs(t *testing.T) {
	t.Parallel()

	operationPlan, err := (&ImageManager{}).Plan(CreateImageRequest{
		CatalogID:       "custom-catalog-id",
		Source:          "/inputs/source.iso",
		KernelDirectory: "/inputs/kernel",
		Output:          "/output/result.iso",
	})
	if err != nil {
		t.Fatalf("Plan() error = %v", err)
	}
	if operationPlan.Steps[0].Inputs["path"] != "/inputs/source.iso" ||
		operationPlan.Steps[1].Inputs["release"] != "/inputs/kernel" ||
		operationPlan.Steps[len(operationPlan.Steps)-1].Inputs["path"] != "/output/result.iso" {
		t.Fatalf("Plan() explicit inputs = %#v", operationPlan.Steps)
	}
}

// TestImageManagerPlanRequiresOutput verifies image planning rejects blank output
// paths before constructing any execution steps.
func TestImageManagerPlanRequiresOutput(t *testing.T) {
	t.Parallel()

	for _, output := range []string{"", " \t\n"} {
		_, err := (&ImageManager{}).Plan(CreateImageRequest{Output: output})
		if err == nil || !strings.Contains(err.Error(), "output ISO path is required") {
			t.Errorf("Plan(Output=%q) error = %v", output, err)
		}
	}
}

// TestImageManagerCreateRejectsCatalogOnlyEntryBeforeExecution verifies an image
// listed for discovery alone cannot reach download or remaster execution.
func TestImageManagerCreateRejectsCatalogOnlyEntryBeforeExecution(t *testing.T) {
	t.Parallel()

	loader := catalog.NewLoader(linuxarmer.CatalogFS(), "supported-isos.json")
	manager := NewImageManager(loader, io.Discard)
	_, err := manager.Create(context.Background(), CreateImageRequest{
		CatalogID: "debian-13-6-0-dvd-1",
		Output:    filepath.Join(t.TempDir(), "output.iso"),
	})
	if err == nil || !strings.Contains(err.Error(), "catalog-only and cannot yet be created") {
		t.Fatalf("Create(catalog-only) error = %v", err)
	}
}

// TestImageManagerCreateRejectsUnknownCatalogEntryBeforeExecution verifies an
// unknown catalogue selector fails before any external image-building work begins.
func TestImageManagerCreateRejectsUnknownCatalogEntryBeforeExecution(t *testing.T) {
	t.Parallel()

	loader := catalog.NewLoader(linuxarmer.CatalogFS(), "supported-isos.json")
	manager := NewImageManager(loader, io.Discard)
	_, err := manager.Create(context.Background(), CreateImageRequest{
		CatalogID: "missing-image",
		Output:    filepath.Join(t.TempDir(), "output.iso"),
	})
	if err == nil || !strings.Contains(err.Error(), `catalog entry "missing-image" was not found`) {
		t.Fatalf("Create(missing catalog entry) error = %v", err)
	}
}

// TestImageManagerCreateChecksDependenciesBeforeExternalWork verifies an
// incompletely wired manager reports its missing dependencies without side effects.
func TestImageManagerCreateChecksDependenciesBeforeExternalWork(t *testing.T) {
	t.Parallel()

	_, err := (&ImageManager{}).Create(context.Background(), CreateImageRequest{Output: "output.iso"})
	if err == nil || !strings.Contains(err.Error(), "dependencies are incomplete") {
		t.Fatalf("Create(incomplete manager) error = %v", err)
	}
}

// TestImageManagerResolveLocalSource verifies a local ISO is accepted with a
// case-insensitive matching digest and rejected when its checksum differs.
func TestImageManagerResolveLocalSource(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	source := filepath.Join(directory, "source.iso")
	content := []byte("local source image")
	if err := os.WriteFile(source, content, 0o600); err != nil {
		t.Fatalf("os.WriteFile(source) error = %v", err)
	}
	digestBytes := sha256.Sum256(content)
	digest := hex.EncodeToString(digestBytes[:])

	manager := &ImageManager{}
	path, gotDigest, err := manager.resolveSource(context.Background(), CreateImageRequest{
		Source:       source,
		SourceSHA256: strings.ToUpper(digest),
	}, catalog.Entry{ID: "local-source"}, directory)
	if err != nil {
		t.Fatalf("resolveSource() error = %v", err)
	}
	if path != source || gotDigest != digest {
		t.Fatalf("resolveSource() path/digest = %q/%q, want %q/%q", path, gotDigest, source, digest)
	}

	_, _, err = manager.resolveSource(context.Background(), CreateImageRequest{
		Source:       source,
		SourceSHA256: strings.Repeat("0", 64),
	}, catalog.Entry{ID: "local-source"}, directory)
	if err == nil || !strings.Contains(err.Error(), "source ISO SHA-256 mismatch") {
		t.Fatalf("resolveSource(checksum mismatch) error = %v", err)
	}
}

// TestImageManagerResolveLocalKernelBundle verifies the image manager discovers
// and hashes a complete Surface runtime package pair from an explicit directory.
func TestImageManagerResolveLocalKernelBundle(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	abi := "7.2.0-jg-0sp11v19-qcom-x1e"
	version := "7.2.0-jg-0sp11v19"
	for _, name := range []string{
		"linux-image-" + abi + "_" + version + "_arm64.deb",
		"linux-modules-" + abi + "_" + version + "_arm64.deb",
	} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(name), 0o600); err != nil {
			t.Fatalf("os.WriteFile(%s) error = %v", name, err)
		}
	}

	bundle, err := (&ImageManager{}).resolveBundle(context.Background(), CreateImageRequest{
		KernelDirectory: directory,
	}, "unused-cache")
	if err != nil {
		t.Fatalf("resolveBundle(local) error = %v", err)
	}
	if bundle.ABI != abi || len(bundle.Packages) != 2 {
		t.Fatalf("resolveBundle(local) = ABI %q, packages %#v", bundle.ABI, bundle.Packages)
	}
	for _, role := range []kernel.PackageRole{kernel.RoleImage, kernel.RoleModules} {
		pkg, ok := bundle.Package(role)
		if !ok || pkg.SHA256 == "" || pkg.Path == "" {
			t.Errorf("resolved local package %q = %#v, found %v", role, pkg, ok)
		}
	}
}

// TestSafePathComponent verifies release references become bounded cache path
// components and traversal-like or empty inputs fall back to a safe default.
func TestSafePathComponent(t *testing.T) {
	t.Parallel()

	tests := []struct {
		input string
		want  string
	}{
		{input: "latest", want: "latest"},
		{input: "refs/tags/sp11-v1", want: "refs-tags-sp11-v1"},
		{input: "feature\\kernel", want: "feature-kernel"},
		{input: "../../", want: "latest"},
		{input: "", want: "latest"},
	}
	for _, test := range tests {
		if got := safePathComponent(test.input); got != test.want {
			t.Errorf("safePathComponent(%q) = %q, want %q", test.input, got, test.want)
		}
	}
}
