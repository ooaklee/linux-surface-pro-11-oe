package manager

import (
	"context"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"

	linuxarmer "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspaceinstall "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/install"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
	userspacestatus "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/status"
)

// fakeDownloader records resolved release specifications and destination paths
// while simulating a successful bundle download.
type fakeDownloader struct {
	specs []userspacerelease.Spec
	dirs  []string
}

// installCall captures one component-specific installer invocation.
type installCall struct {
	component string
	options   userspaceinstall.Options
}

// fakeInstaller records preflight and mutation requests without touching a root
// filesystem.
type fakeInstaller struct {
	calls []installCall
}

// Audio records installation of the supported audio component.
func (f *fakeInstaller) Audio(_ context.Context, options userspaceinstall.Options) (userspaceinstall.Result, error) {
	return f.record(AudioComponent, options), nil
}

// IPTSD records installation of the supported touchscreen component.
func (f *fakeInstaller) IPTSD(_ context.Context, options userspaceinstall.Options) (userspaceinstall.Result, error) {
	return f.record(IPTSDComponent, options), nil
}

// Camera records installation of the explicitly selected camera component.
func (f *fakeInstaller) Camera(_ context.Context, options userspaceinstall.Options) (userspaceinstall.Result, error) {
	return f.record(CameraComponent, options), nil
}

// record appends an installer call and returns a deterministic component result.
func (f *fakeInstaller) record(component string, options userspaceinstall.Options) userspaceinstall.Result {
	f.calls = append(f.calls, installCall{component: component, options: options})
	return userspaceinstall.Result{
		Component: component, Root: options.Root, DryRun: options.DryRun,
		RebootRequired: component == AudioComponent,
	}
}

// Download records a resolved release and returns a bundle rooted at its planned
// cache directory.
func (f *fakeDownloader) Download(_ context.Context, spec userspacerelease.Spec, directory string) (userspacerelease.Bundle, error) {
	f.specs = append(f.specs, spec)
	f.dirs = append(f.dirs, directory)
	return userspacerelease.Bundle{Component: spec.Component, Release: spec.Tag, Directory: directory}, nil
}

// TestPullRecommendedUsesAuditedPair verifies that the recommended selector
// resolves only the pinned audio and IPTSD releases into deterministic paths.
func TestPullRecommendedUsesAuditedPair(t *testing.T) {
	downloader := &fakeDownloader{}
	manager := New(catalog.NewLoader(testCatalogFS(), "supported-userspace.json"), downloader, nil)
	cache := t.TempDir()
	bundles, err := manager.Pull(context.Background(), "", "recommended", cache)
	if err != nil {
		t.Fatal(err)
	}
	if len(bundles) != 2 || downloader.specs[0].Component != AudioComponent || downloader.specs[1].Component != IPTSDComponent {
		t.Fatalf("bundles = %#v, specs = %#v", bundles, downloader.specs)
	}
	if got := downloader.dirs[0]; got != filepath.Join(cache, AudioComponent, "sp11-audio-v19c") {
		t.Fatalf("directory = %q", got)
	}
	if len(downloader.specs[0].UnchecksummedAssets) != 1 || downloader.specs[0].UnchecksummedAssets[0] != "RELEASE-NOTES.md" {
		t.Fatalf("audio unchecksummed assets = %#v", downloader.specs[0].UnchecksummedAssets)
	}
	if downloader.specs[0].Repository != "ooaklee/linux-surface-pro-11-oe" {
		t.Fatalf("release repository = %q", downloader.specs[0].Repository)
	}
}

// TestPullRejectsComponentWithoutRelease verifies that status-only catalogue
// entries cannot be treated as remotely downloadable bundles.
func TestPullRejectsComponentWithoutRelease(t *testing.T) {
	manager := New(catalog.NewLoader(testCatalogFS(), "supported-userspace.json"), &fakeDownloader{}, nil)
	_, err := manager.Pull(context.Background(), "", "firmware", t.TempDir())
	if err == nil {
		t.Fatal("expected unsupported pull to fail")
	}
}

// TestResolveAliases verifies the stable human-friendly component shortcuts.
func TestResolveAliases(t *testing.T) {
	for input, want := range map[string]string{"audio": AudioComponent, "pen": IPTSDComponent, "camera": CameraComponent} {
		got, err := ResolveComponentID(input)
		if err != nil || got != want {
			t.Fatalf("ResolveComponentID(%q) = %q, %v; want %q", input, got, err, want)
		}
	}
}

// TestReleaseRepositoryRequiresExactGitHubReleaseURL proves that the human
// release page and API download repository cannot silently diverge.
func TestReleaseRepositoryRequiresExactGitHubReleaseURL(t *testing.T) {
	repository, err := releaseRepository("https://github.com/owner/project/releases/tag/component-v1")
	if err != nil || repository != "owner/project" {
		t.Fatalf("releaseRepository() = %q, %v", repository, err)
	}
	for _, rawURL := range []string{
		"http://github.com/owner/project/releases/tag/component-v1",
		"https://example.com/owner/project/releases/tag/component-v1",
		"https://github.com/extra/owner/project/releases/tag/component-v1",
	} {
		if _, err := releaseRepository(rawURL); err == nil {
			t.Errorf("releaseRepository(%q) accepted a divergent URL", rawURL)
		}
	}
}

// TestInstallRecommendedResolvesCacheAndPreflightsBeforeMutation verifies exact
// cache paths and an all-component dry-run phase before any real installation.
func TestInstallRecommendedResolvesCacheAndPreflightsBeforeMutation(t *testing.T) {
	installer := &fakeInstaller{}
	manager := New(catalog.NewLoader(testCatalogFS(), "supported-userspace.json"), &fakeDownloader{}, nil)
	manager.Installer = installer
	cache := t.TempDir()
	results, err := manager.Install(context.Background(), InstallRequest{
		Selector: "recommended", From: cache, Root: "/target",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 || results[0].Component != AudioComponent || results[1].Component != IPTSDComponent {
		t.Fatalf("results = %#v", results)
	}
	if len(installer.calls) != 4 {
		t.Fatalf("calls = %#v, want two preflight and two mutation calls", installer.calls)
	}
	wantComponents := []string{AudioComponent, IPTSDComponent, AudioComponent, IPTSDComponent}
	wantDryRun := []bool{true, true, false, false}
	for index, call := range installer.calls {
		if call.component != wantComponents[index] || call.options.DryRun != wantDryRun[index] {
			t.Fatalf("call[%d] = %#v", index, call)
		}
		component := wantComponents[index]
		tag := "sp11-audio-v19c"
		if component == IPTSDComponent {
			tag = "sp11-iptsd-v1"
		}
		if want := filepath.Join(cache, component, tag); call.options.BundleDir != want {
			t.Fatalf("call[%d] bundle = %q, want %q", index, call.options.BundleDir, want)
		}
	}
}

// TestInstallCameraUsesExactReleaseDirectoryOnlyOnExplicitSelection verifies
// that experimental camera installation remains opt-in and uses the given bundle.
func TestInstallCameraUsesExactReleaseDirectoryOnlyOnExplicitSelection(t *testing.T) {
	installer := &fakeInstaller{}
	manager := New(catalog.NewLoader(testCatalogFS(), "supported-userspace.json"), &fakeDownloader{}, nil)
	manager.Installer = installer
	bundle := t.TempDir()
	results, err := manager.Install(context.Background(), InstallRequest{
		Selector: "camera", From: bundle, Root: "/", DryRun: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || len(installer.calls) != 1 {
		t.Fatalf("results = %#v, calls = %#v", results, installer.calls)
	}
	if call := installer.calls[0]; call.component != CameraComponent || call.options.BundleDir != bundle || !call.options.DryRun {
		t.Fatalf("camera call = %#v", call)
	}
}

// TestInstallRejectsUnknownCompiledWorkflow verifies that catalogue metadata alone
// cannot authorise an installer implementation that is not compiled into the CLI.
func TestInstallRejectsUnknownCompiledWorkflow(t *testing.T) {
	manager := New(catalog.NewLoader(testCatalogFS(), "supported-userspace.json"), &fakeDownloader{}, nil)
	manager.Installer = &fakeInstaller{}
	_, err := manager.Install(context.Background(), InstallRequest{
		Selector: "firmware", From: t.TempDir(), DryRun: true,
	})
	if err == nil {
		t.Fatal("expected unsupported install selector to fail")
	}
}

// TestStatusProjectsCataloguePolicy verifies that status checks expose the
// catalogue identity and maturity used to derive explicit feature severity.
func TestStatusProjectsCataloguePolicy(t *testing.T) {
	loader := catalog.NewLoader(linuxarmer.UserspaceCatalogFS(), "supported-userspace.json")
	manager := New(loader, &fakeDownloader{}, nil)
	report, err := manager.Status(userspacestatus.Options{Root: t.TempDir(), Features: []userspacestatus.Feature{userspacestatus.FeaturePower}})
	if err != nil {
		t.Fatal(err)
	}
	if report.Ready {
		t.Fatal("explicitly selected missing power support unexpectedly reported ready")
	}
	for _, check := range report.Checks {
		if check.ComponentID != "power-profiles" || check.SupportLevel != userspacestatus.SupportSupported || !check.Required {
			t.Fatalf("projected power check = %#v", check)
		}
	}
}

// TestStatusRejectsWeakenedCatalogueCompatibility verifies that a strict
// catalogue override cannot lower a compiled minimum kernel generation.
func TestStatusRejectsWeakenedCatalogueCompatibility(t *testing.T) {
	data, err := fs.ReadFile(linuxarmer.UserspaceCatalogFS(), "supported-userspace.json")
	if err != nil {
		t.Fatal(err)
	}
	weakened := strings.Replace(string(data), `"minimum_sp11_generation": 12`, `"minimum_sp11_generation": 11`, 1)
	loader := catalog.NewLoader(fstest.MapFS{
		"supported-userspace.json": {Data: []byte(weakened)},
	}, "supported-userspace.json")
	manager := New(loader, &fakeDownloader{}, nil)
	_, err = manager.Status(userspacestatus.Options{Root: t.TempDir(), Features: []userspacestatus.Feature{userspacestatus.FeatureAudio}})
	if err == nil || !strings.Contains(err.Error(), `"audio-fullio-v19c" kernel compatibility disagrees`) {
		t.Fatalf("expected compiled compatibility disagreement, got %v", err)
	}
}

// testCatalogFS returns a minimal valid component catalogue covering pull, install,
// experimental, and status-only manager paths.
func testCatalogFS() fs.FS {
	return fstest.MapFS{
		"supported-userspace.json": {Data: []byte(`{
  "schema_version": 2,
  "description": "Test userspace component catalog.",
  "components": [
    {
      "id": "audio-fullio-v19c", "name": "Audio", "level": "supported", "capability": "audio",
      "redistribution": "restricted", "support_actions": {"status": true, "pull": true, "build": false, "install": true},
      "release": {"url": "https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-audio-v19c", "tag": "sp11-audio-v19c", "asset_allowlist": ["SHA256SUMS", "RELEASE-NOTES.md", "audio.bin"]},
      "compatibility_evidence": "exact_pair", "kernel_compatibility": {"minimum_sp11_generation": 12, "tested_through_sp11_generation": 19, "summary": "Audio requires sp11v12 and is tested through sp11v19."}, "notes": ["Test coherent audio set."], "remediation": "Install the coherent set."
    },
    {
      "id": "iptsd-v1", "name": "Pen", "level": "supported", "capability": "pen",
      "redistribution": "source-required", "support_actions": {"status": true, "pull": true, "build": true, "install": true},
      "release": {"url": "https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-iptsd-v1", "tag": "sp11-iptsd-v1", "asset_allowlist": ["SHA256SUMS", "pen.tar.xz"]},
      "compatibility_evidence": "exact_pair", "kernel_compatibility": {"minimum_sp11_generation": 19, "tested_through_sp11_generation": 19, "summary": "IPTSD requires and is tested with sp11v19."}, "notes": ["Test pinned pen set."], "remediation": "Install the pinned set."
    },
	{
	  "id": "imx681-libcamera-v1", "name": "Camera", "level": "experimental", "capability": "camera",
	  "redistribution": "allowed", "support_actions": {"status": true, "pull": true, "build": true, "install": true},
	  "release": {"url": "https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-imx681-libcamera-v1", "tag": "sp11-imx681-libcamera-v1", "asset_allowlist": ["SHA256SUMS", "camera.deb"]},
	  "compatibility_evidence": "exact_pair", "kernel_compatibility": {"minimum_sp11_generation": 14, "tested_through_sp11_generation": 19, "summary": "Camera requires sp11v14 and is tested through sp11v19."}, "notes": ["Test exact camera set."], "remediation": "Install the exact camera set."
	},
    {
      "id": "firmware", "name": "Firmware", "level": "required", "capability": "firmware",
      "redistribution": "restricted", "support_actions": {"status": true, "pull": false, "build": false, "install": false},
      "compatibility_evidence": "source_integrated_prior_validation", "notes": ["Test local firmware."], "remediation": "Acquire authorized firmware."
    }
  ]
}`)},
	}
}
