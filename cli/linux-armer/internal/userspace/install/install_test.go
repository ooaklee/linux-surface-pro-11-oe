package install

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	linuxarmer "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
	userspacecatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
)

// fakeRunner records privileged commands and optionally inspects their staged
// inputs at execution time without invoking a system package manager or script.
type fakeRunner struct {
	commands []platform.Command
	err      error
	inspect  func(platform.Command) error
}

// Run records and validates one simulated command before returning its configured
// execution error.
func (runner *fakeRunner) Run(_ context.Context, command platform.Command) error {
	runner.commands = append(runner.commands, command)
	if runner.inspect != nil {
		if err := runner.inspect(command); err != nil {
			return err
		}
	}
	return runner.err
}

// Capture fails deliberately because userspace installers must not rely on an
// untested output-capturing command path.
func (runner *fakeRunner) Capture(context.Context, platform.Command) ([]byte, error) {
	return nil, errors.New("unexpected capture")
}

// TestShippedCatalogueMatchesCompiledInstallPolicy prevents release tags or
// asset names in human-readable metadata from drifting away from root-trusted
// component policy.
func TestShippedCatalogueMatchesCompiledInstallPolicy(t *testing.T) {
	componentCatalogue, err := userspacecatalog.NewLoader(
		linuxarmer.UserspaceCatalogFS(), "supported-userspace.json",
	).Load("")
	if err != nil {
		t.Fatal(err)
	}
	policies := map[string]struct {
		spec  releaseSpec
		extra []string
	}{
		AudioComponent:  {spec: audioSpec, extra: []string{"RELEASE-NOTES.md"}},
		IPTSDComponent:  {spec: iptsdSpec},
		CameraComponent: {spec: cameraSpec},
	}
	for componentID, policy := range policies {
		component, ok := componentCatalogue.Get(componentID)
		if !ok || component.Release == nil {
			t.Fatalf("shipped catalogue omits installable component %s", componentID)
		}
		if component.Release.Tag != policy.spec.tag {
			t.Errorf("%s release tag = %q, compiled policy = %q", componentID, component.Release.Tag, policy.spec.tag)
		}
		wantAssets := append([]string(nil), policy.extra...)
		for _, file := range policy.spec.files {
			wantAssets = append(wantAssets, file.name)
		}
		gotAssets := append([]string(nil), component.Release.AssetAllowlist...)
		sort.Strings(wantAssets)
		sort.Strings(gotAssets)
		if !slices.Equal(gotAssets, wantAssets) {
			t.Errorf("%s assets = %v, compiled policy = %v", componentID, gotAssets, wantAssets)
		}
	}
}

// TestAudioInstallsCoherentSetAndBacksUpExistingFile verifies dry-run safety,
// target-root link handling, atomic replacement, and preservation of old audio.
func TestAudioInstallsCoherentSetAndBacksUpExistingFile(t *testing.T) {
	originalSpec := audioSpec
	t.Cleanup(func() { audioSpec = originalSpec })
	contents := map[string][]byte{
		"X1E80100-Microsoft-Surface-Pro-11-tplg.bin": []byte("topology"),
		"MICROSOFT-Surface-Pro-11in.conf":            []byte("card"),
		"SP11-HiFi.conf":                             []byte("verb"),
		"x1e80100.conf":                              []byte("lookup"),
	}
	bundle, spec := makeBundle(t, AudioComponent, "sp11-audio-v19c", contents)
	audioSpec = spec
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "usr/lib/firmware/qcom/x1e80100"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/usr/lib", filepath.Join(root, "lib")); err != nil {
		t.Fatal(err)
	}
	existing := filepath.Join(root, "usr/lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin")
	if err := os.WriteFile(existing, []byte("old-topology"), 0o600); err != nil {
		t.Fatal(err)
	}

	installer := New(&fakeRunner{})
	installer.euid = func() int { return 501 }
	installer.now = func() time.Time { return time.Date(2026, 8, 30, 12, 34, 56, 7, time.UTC) }
	dryRun, err := installer.Audio(context.Background(), Options{BundleDir: bundle, Root: root, DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(dryRun.Files) != 4 || dryRun.BackupDirectory == "" || !dryRun.Files[0].Replaced {
		t.Fatalf("unexpected dry-run result: %+v", dryRun)
	}
	resolvedExisting, err := filepath.EvalSymlinks(existing)
	if err != nil {
		t.Fatal(err)
	}
	if dryRun.Files[0].Target != resolvedExisting {
		t.Fatalf("/lib symlink did not resolve inside root: %s", dryRun.Files[0].Target)
	}
	if got, _ := os.ReadFile(existing); string(got) != "old-topology" {
		t.Fatalf("dry run changed target: %q", got)
	}

	installer.euid = func() int { return 0 }
	result, err := installer.Audio(context.Background(), Options{BundleDir: bundle, Root: root})
	if err != nil {
		t.Fatal(err)
	}
	if !result.RebootRequired || result.BackupDirectory == "" {
		t.Fatalf("unexpected result: %+v", result)
	}
	if got, _ := os.ReadFile(existing); string(got) != "topology" {
		t.Fatalf("installed topology = %q", got)
	}
	if got, _ := os.ReadFile(result.Files[0].Backup); string(got) != "old-topology" {
		t.Fatalf("backup = %q", got)
	}
	for index, target := range audioTargets {
		got, err := os.ReadFile(result.Files[index].Target)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != string(contents[target.source]) {
			t.Fatalf("target %s = %q", target.source, got)
		}
	}
}

// TestAudioRejectsTargetParentSymlinkEscape verifies that an audio target's
// parent link cannot redirect installation outside the selected root.
func TestAudioRejectsTargetParentSymlinkEscape(t *testing.T) {
	originalSpec := audioSpec
	t.Cleanup(func() { audioSpec = originalSpec })
	bundle, spec := makeBundle(t, AudioComponent, "sp11-audio-v19c", map[string][]byte{
		"X1E80100-Microsoft-Surface-Pro-11-tplg.bin": []byte("topology"),
		"MICROSOFT-Surface-Pro-11in.conf":            []byte("card"),
		"SP11-HiFi.conf":                             []byte("verb"),
		"x1e80100.conf":                              []byte("lookup"),
	})
	audioSpec = spec
	root := t.TempDir()
	outside := t.TempDir()
	escape, err := filepath.Rel(root, outside)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(escape, filepath.Join(root, "lib")); err != nil {
		t.Fatal(err)
	}
	installer := New(&fakeRunner{})
	installer.euid = func() int { return 501 }
	_, err = installer.Audio(context.Background(), Options{BundleDir: bundle, Root: root, DryRun: true})
	if err == nil || !strings.Contains(err.Error(), "escapes selected root") {
		t.Fatalf("error = %v", err)
	}
}

// TestBundleRejectsSymlinkedArtifact verifies that matching content reached via
// a symlink is never trusted as an immutable downloaded artefact.
func TestBundleRejectsSymlinkedArtifact(t *testing.T) {
	directory, spec := makeBundle(t, "test", "test-v1", map[string][]byte{"payload": []byte("payload")})
	payload := filepath.Join(directory, "payload")
	real := filepath.Join(directory, "real-payload")
	if err := os.Rename(payload, real); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, payload); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyBundle(directory, spec); err == nil || !strings.Contains(err.Error(), "non-symlink") {
		t.Fatalf("error = %v", err)
	}
}

// TestBundleRejectsSymlinkedReceipt verifies that strict receipt decoding never
// follows a replacement manifest symlink, even when its target has valid bytes.
func TestBundleRejectsSymlinkedReceipt(t *testing.T) {
	directory, spec := makeBundle(t, "test", "test-v1", map[string][]byte{"payload": []byte("payload")})
	manifestPath := filepath.Join(directory, bundleManifestName)
	realManifest := filepath.Join(directory, "saved-receipt.json")
	if err := os.Rename(manifestPath, realManifest); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realManifest, manifestPath); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyBundle(directory, spec); err == nil || !strings.Contains(err.Error(), "non-symlink") {
		t.Fatalf("error = %v", err)
	}
}

// TestPortableBundleSurvivesDirectoryMove verifies that a receipt continues to
// validate after the complete verified bundle is moved onto different media.
func TestPortableBundleSurvivesDirectoryMove(t *testing.T) {
	directory, spec := makeBundle(t, "test", "test-v1", map[string][]byte{"payload": []byte("payload")})
	destination := filepath.Join(t.TempDir(), "copied-bundle")
	if err := os.Rename(directory, destination); err != nil {
		t.Fatal(err)
	}
	verified, err := verifyBundle(destination, spec)
	if err != nil {
		t.Fatal(err)
	}
	resolvedDestination, err := filepath.EvalSymlinks(destination)
	if err != nil {
		t.Fatal(err)
	}
	if verified.paths["payload"] != filepath.Join(resolvedDestination, "payload") {
		t.Fatalf("verified payload path = %q", verified.paths["payload"])
	}
}

// TestBundleAcceptsSafeLegacyAbsoluteReceipt verifies that receipts written by
// earlier releases remain usable while they still identify the selected cache.
func TestBundleAcceptsSafeLegacyAbsoluteReceipt(t *testing.T) {
	directory, spec := makeBundle(t, "test", "test-v1", map[string][]byte{"payload": []byte("payload")})
	rewriteBundleReceipt(t, directory, func(receipt *userspacerelease.Bundle) {
		receipt.Directory = directory
		for index := range receipt.Files {
			receipt.Files[index].Path = filepath.Join(directory, receipt.Files[index].Name)
		}
	})
	if _, err := verifyBundle(directory, spec); err != nil {
		t.Fatal(err)
	}
}

// TestBundleRejectsUnsafePortableReceiptPaths verifies that relative directory
// traversal and non-flat asset paths cannot escape the selected bundle.
func TestBundleRejectsUnsafePortableReceiptPaths(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*userspacerelease.Bundle)
	}{
		{
			name: "directory traversal",
			mutate: func(receipt *userspacerelease.Bundle) {
				receipt.Directory = "../bundle"
			},
		},
		{
			name: "file traversal",
			mutate: func(receipt *userspacerelease.Bundle) {
				receipt.Files[1].Path = "../payload"
			},
		},
		{
			name: "non-canonical file",
			mutate: func(receipt *userspacerelease.Bundle) {
				receipt.Files[1].Path = "./payload"
			},
		},
		{
			name: "host absolute file",
			mutate: func(receipt *userspacerelease.Bundle) {
				receipt.Files[1].Path = filepath.Join(string(filepath.Separator), "host", "payload")
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			directory, spec := makeBundle(t, "test", "test-v1", map[string][]byte{"payload": []byte("payload")})
			rewriteBundleReceipt(t, directory, test.mutate)
			if _, err := verifyBundle(directory, spec); err == nil {
				t.Fatal("expected unsafe portable receipt to fail")
			}
		})
	}
}

// TestBundleReceiptUsesStrictJSON verifies that unknown, mis-cased, duplicate,
// and trailing JSON fields fail closed before privileged installation.
func TestBundleReceiptUsesStrictJSON(t *testing.T) {
	t.Run("unknown field", func(t *testing.T) {
		directory, spec := makeBundle(t, "test", "test-v1", map[string][]byte{"payload": []byte("payload")})
		manifestPath := filepath.Join(directory, bundleManifestName)
		data, err := os.ReadFile(manifestPath)
		if err != nil {
			t.Fatal(err)
		}
		var fields map[string]any
		if err := json.Unmarshal(data, &fields); err != nil {
			t.Fatal(err)
		}
		fields["unexpected"] = true
		data, err = json.Marshal(fields)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(manifestPath, data, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := verifyBundle(directory, spec); err == nil || !strings.Contains(err.Error(), "unknown field") {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("mis-cased field", func(t *testing.T) {
		directory, spec := makeBundle(t, "test", "test-v1", map[string][]byte{"payload": []byte("payload")})
		manifestPath := filepath.Join(directory, bundleManifestName)
		data, err := os.ReadFile(manifestPath)
		if err != nil {
			t.Fatal(err)
		}
		data = []byte(strings.Replace(string(data), `"component"`, `"Component"`, 1))
		if err := os.WriteFile(manifestPath, data, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := verifyBundle(directory, spec); err == nil || !strings.Contains(err.Error(), "unknown field") {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("duplicate field", func(t *testing.T) {
		directory, spec := makeBundle(t, "test", "test-v1", map[string][]byte{"payload": []byte("payload")})
		manifestPath := filepath.Join(directory, bundleManifestName)
		data, err := os.ReadFile(manifestPath)
		if err != nil {
			t.Fatal(err)
		}
		data = []byte(strings.Replace(string(data), `"component": "test"`, `"component": "other", "component": "test"`, 1))
		if err := os.WriteFile(manifestPath, data, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := verifyBundle(directory, spec); err == nil || !strings.Contains(err.Error(), "duplicate field") {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("trailing value", func(t *testing.T) {
		directory, spec := makeBundle(t, "test", "test-v1", map[string][]byte{"payload": []byte("payload")})
		manifestPath := filepath.Join(directory, bundleManifestName)
		file, err := os.OpenFile(manifestPath, os.O_APPEND|os.O_WRONLY, 0)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.WriteString("{}\n"); err != nil {
			_ = file.Close()
			t.Fatal(err)
		}
		if err := file.Close(); err != nil {
			t.Fatal(err)
		}
		if _, err := verifyBundle(directory, spec); err == nil || !strings.Contains(err.Error(), "trailing JSON") {
			t.Fatalf("error = %v", err)
		}
	})
}

// TestCameraUsesOneExactAptGetTransaction verifies that all five pinned camera
// packages are staged as regular files and installed in one bounded transaction.
func TestCameraUsesOneExactAptGetTransaction(t *testing.T) {
	originalSpec := cameraSpec
	originalRuntime := cameraRuntimeFiles
	t.Cleanup(func() {
		cameraSpec = originalSpec
		cameraRuntimeFiles = originalRuntime
	})
	contents := map[string][]byte{
		"one_arm64.deb":   []byte("one"),
		"two_arm64.deb":   []byte("two"),
		"three_arm64.deb": []byte("three"),
		"four_arm64.deb":  []byte("four"),
		"five_arm64.deb":  []byte("five"),
	}
	bundle, spec := makeBundle(t, CameraComponent, "sp11-imx681-libcamera-v1", contents)
	cameraSpec = spec
	cameraRuntimeFiles = append([]immutableFile(nil), spec.files[1:]...)
	runner := &fakeRunner{inspect: func(command platform.Command) error {
		for _, path := range command.Args[4:] {
			info, err := os.Lstat(path)
			if err != nil || !info.Mode().IsRegular() {
				return errors.New("camera package was not staged as a regular file")
			}
		}
		return nil
	}}
	installer := New(runner)
	installer.euid = func() int { return 501 }
	dryRun, err := installer.Camera(context.Background(), Options{BundleDir: bundle, Root: "/", DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if dryRun.Command == nil || dryRun.Command.Name != "apt-get" || len(dryRun.Command.Args) != 9 ||
		dryRun.Command.Args[2] != "--no-install-recommends" {
		t.Fatalf("unexpected camera command: %+v", dryRun.Command)
	}
	if len(runner.commands) != 0 {
		t.Fatal("dry run executed package manager")
	}
	installer.euid = func() int { return 0 }
	if _, err := installer.Camera(context.Background(), Options{BundleDir: bundle, Root: "/"}); err != nil {
		t.Fatal(err)
	}
	if len(runner.commands) != 1 || runner.commands[0].Name != "apt-get" {
		t.Fatalf("commands = %+v", runner.commands)
	}
	if got := runner.commands[0].Args[:4]; strings.Join(got, " ") != "install --yes --no-install-recommends --" {
		t.Fatalf("apt-get prefix = %v", got)
	}
	if _, err := installer.Camera(context.Background(), Options{BundleDir: bundle, Root: t.TempDir(), DryRun: true}); err == nil {
		t.Fatal("expected alternate-root camera install to fail")
	}
}

// fakeExtractor records validation and extraction phases while creating the
// minimum IPTSD payload tree needed by delegation tests.
type fakeExtractor struct {
	validations int
	extractions int
	malicious   bool
}

// Validate records a successful archive preflight without reading the fixture.
func (extractor *fakeExtractor) Validate(context.Context, string) error {
	extractor.validations++
	return nil
}

// Extract creates a bounded IPTSD fixture and can substitute a malicious
// installer symlink to exercise post-extraction containment checks.
func (extractor *fakeExtractor) Extract(_ context.Context, _ string, destination string) error {
	extractor.extractions++
	root := filepath.Join(destination, iptsdArchiveRoot)
	for _, directory := range []string{
		"scripts", "payload/iptsd-sp11", "userspace/iptsd-sp11/packaging",
	} {
		if err := os.MkdirAll(filepath.Join(root, filepath.FromSlash(directory)), 0o755); err != nil {
			return err
		}
	}
	validator := filepath.Join(root, "scripts/validate-sp11-iptsd-payload.sh")
	if err := os.WriteFile(validator, []byte("validator"), 0o755); err != nil {
		return err
	}
	script := filepath.Join(root, "scripts/install-sp11-iptsd.sh")
	if extractor.malicious {
		return os.Symlink(validator, script)
	}
	return os.WriteFile(script, []byte("installer"), 0o755)
}

// TestIPTSDDelegatesOnlyContainedPinnedInstaller verifies that preflight does not
// extract and mutation delegates only to regular files inside the pinned bundle.
func TestIPTSDDelegatesOnlyContainedPinnedInstaller(t *testing.T) {
	originalSpec := iptsdSpec
	t.Cleanup(func() { iptsdSpec = originalSpec })
	bundle, spec := makeBundle(t, IPTSDComponent, "sp11-iptsd-v1", map[string][]byte{
		iptsdArchiveName:                  []byte("archive"),
		"sp11-iptsd-release-manifest.txt": []byte("manifest"),
	})
	iptsdSpec = spec
	extractor := &fakeExtractor{}
	runner := &fakeRunner{inspect: func(command platform.Command) error {
		if command.Name != "/bin/bash" || len(command.Args) != 5 {
			return errors.New("unexpected iptsd command")
		}
		for _, index := range []int{0, 4} {
			if _, err := os.Lstat(command.Args[index]); err != nil {
				return err
			}
		}
		return nil
	}}
	installer := New(runner)
	installer.extractor = extractor
	installer.euid = func() int { return 501 }
	root := t.TempDir()
	if result, err := installer.IPTSD(context.Background(), Options{BundleDir: bundle, Root: root, DryRun: true}); err != nil {
		t.Fatal(err)
	} else if result.Command == nil || extractor.validations != 1 || extractor.extractions != 0 {
		t.Fatalf("unexpected dry run: result=%+v extractor=%+v", result, extractor)
	}
	installer.euid = func() int { return 0 }
	if _, err := installer.IPTSD(context.Background(), Options{BundleDir: bundle, Root: root}); err != nil {
		t.Fatal(err)
	}
	if extractor.validations != 1 || extractor.extractions != 1 || len(runner.commands) != 1 {
		t.Fatalf("unexpected execution: extractor=%+v commands=%+v", extractor, runner.commands)
	}
}

// TestIPTSDRejectsSymlinkedExtractedInstaller verifies that archive extraction
// cannot redirect the delegated installer through a symlink.
func TestIPTSDRejectsSymlinkedExtractedInstaller(t *testing.T) {
	originalSpec := iptsdSpec
	t.Cleanup(func() { iptsdSpec = originalSpec })
	bundle, spec := makeBundle(t, IPTSDComponent, "sp11-iptsd-v1", map[string][]byte{
		iptsdArchiveName:                  []byte("archive"),
		"sp11-iptsd-release-manifest.txt": []byte("manifest"),
	})
	iptsdSpec = spec
	runner := &fakeRunner{}
	installer := New(runner)
	installer.extractor = &fakeExtractor{malicious: true}
	installer.euid = func() int { return 0 }
	_, err := installer.IPTSD(context.Background(), Options{BundleDir: bundle, Root: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "non-symlink") {
		t.Fatalf("error = %v", err)
	}
	if len(runner.commands) != 0 {
		t.Fatal("symlinked installer was executed")
	}
}

// TestProcessTarRejectsUnsafeEntryTypesAndPaths verifies that traversal,
// absolute paths, links, and device nodes are rejected before extraction.
func TestProcessTarRejectsUnsafeEntryTypesAndPaths(t *testing.T) {
	tests := []struct {
		name   string
		header tar.Header
		body   []byte
	}{
		{name: "traversal", header: tar.Header{Name: "../escape", Typeflag: tar.TypeReg, Size: 1}, body: []byte("x")},
		{name: "absolute", header: tar.Header{Name: "/escape", Typeflag: tar.TypeReg, Size: 1}, body: []byte("x")},
		{name: "symlink", header: tar.Header{Name: iptsdArchiveRoot + "/link", Typeflag: tar.TypeSymlink, Linkname: "target"}},
		{name: "hardlink", header: tar.Header{Name: iptsdArchiveRoot + "/hard", Typeflag: tar.TypeLink, Linkname: iptsdArchiveRoot + "/file"}},
		{name: "device", header: tar.Header{Name: iptsdArchiveRoot + "/device", Typeflag: tar.TypeChar}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			archive := tarBytes(t, []tarRecord{
				{header: tar.Header{Name: iptsdArchiveRoot + "/", Typeflag: tar.TypeDir, Mode: 0o755}},
				{header: test.header, body: test.body},
			})
			if err := processTar(tar.NewReader(bytes.NewReader(archive)), t.TempDir()); err == nil {
				t.Fatal("expected unsafe archive entry to fail")
			}
		})
	}
}

// TestProcessTarExtractsOnlyRegularFiles verifies the permitted directory and
// regular-file archive subset and preserves the fixture contents.
func TestProcessTarExtractsOnlyRegularFiles(t *testing.T) {
	archive := tarBytes(t, []tarRecord{
		{header: tar.Header{Name: iptsdArchiveRoot + "/", Typeflag: tar.TypeDir, Mode: 0o755}},
		{header: tar.Header{Name: iptsdArchiveRoot + "/scripts/", Typeflag: tar.TypeDir, Mode: 0o755}},
		{header: tar.Header{Name: iptsdArchiveRoot + "/scripts/install", Typeflag: tar.TypeReg, Mode: 0o755, Size: 6}, body: []byte("script")},
	})
	destination := t.TempDir()
	if err := processTar(tar.NewReader(bytes.NewReader(archive)), destination); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(filepath.Join(destination, iptsdArchiveRoot, "scripts/install"))
	if err != nil || string(contents) != "script" {
		t.Fatalf("contents=%q error=%v", contents, err)
	}
}

// TestSecureXZTarExtractorStreamsValidatedArchive verifies the real xz streaming
// path for both preflight validation and bounded extraction.
func TestSecureXZTarExtractorStreamsValidatedArchive(t *testing.T) {
	xz, err := exec.LookPath("xz")
	if err != nil {
		t.Skip("xz is not installed")
	}
	archive := tarBytes(t, []tarRecord{
		{header: tar.Header{Name: iptsdArchiveRoot + "/", Typeflag: tar.TypeDir, Mode: 0o755}},
		{header: tar.Header{Name: iptsdArchiveRoot + "/payload", Typeflag: tar.TypeReg, Mode: 0o644, Size: 7}, body: []byte("payload")},
	})
	command := exec.Command(xz, "--compress", "--stdout")
	command.Stdin = bytes.NewReader(archive)
	compressed, err := command.Output()
	if err != nil {
		t.Fatal(err)
	}
	archivePath := filepath.Join(t.TempDir(), "payload.tar.xz")
	if err := os.WriteFile(archivePath, compressed, 0o600); err != nil {
		t.Fatal(err)
	}
	extractor := SecureXZTarExtractor{XZPath: xz}
	if err := extractor.Validate(context.Background(), archivePath); err != nil {
		t.Fatal(err)
	}
	destination := t.TempDir()
	if err := extractor.Extract(context.Background(), archivePath, destination); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(destination, iptsdArchiveRoot, "payload")); err != nil || string(got) != "payload" {
		t.Fatalf("payload=%q error=%v", got, err)
	}
}

// TestPinnedIPTSDArchiveFixture optionally validates and inspects an actual
// downloaded IPTSD release archive supplied by the integration environment.
func TestPinnedIPTSDArchiveFixture(t *testing.T) {
	archivePath := os.Getenv("LINUX_ARMER_TEST_IPTSD_ARCHIVE")
	if archivePath == "" {
		t.Skip("set LINUX_ARMER_TEST_IPTSD_ARCHIVE to exercise a downloaded release archive")
	}
	extractor := SecureXZTarExtractor{}
	if err := extractor.Validate(context.Background(), archivePath); err != nil {
		t.Fatal(err)
	}
	destination := t.TempDir()
	if err := extractor.Extract(context.Background(), archivePath, destination); err != nil {
		t.Fatal(err)
	}
	for _, relative := range []string{
		"scripts/install-sp11-iptsd.sh",
		"scripts/validate-sp11-iptsd-payload.sh",
		"payload/iptsd-sp11/SHA256SUMS",
		"userspace/iptsd-sp11/packaging/sp11-iptsd@.service.in",
	} {
		if _, err := requireContainedRegular(filepath.Join(destination, iptsdArchiveRoot), relative); err != nil {
			t.Fatal(err)
		}
	}
}

// tarRecord pairs one archive header with the bytes written for that entry.
type tarRecord struct {
	header tar.Header
	body   []byte
}

// tarBytes serialises explicit records into an in-memory tar archive fixture.
func tarBytes(t *testing.T, records []tarRecord) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := tar.NewWriter(&buffer)
	for _, record := range records {
		header := record.header
		if header.Size == 0 && len(record.body) != 0 {
			header.Size = int64(len(record.body))
		}
		if err := writer.WriteHeader(&header); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(record.body); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// makeBundle writes a self-consistent release directory, checksum manifest, and
// trusted bundle manifest while returning the matching immutable specification.
func makeBundle(t *testing.T, component, tag string, contents map[string][]byte) (string, releaseSpec) {
	t.Helper()
	directory := t.TempDir()
	names := make([]string, 0, len(contents))
	for name := range contents {
		names = append(names, name)
	}
	sort.Strings(names)
	var checksum bytes.Buffer
	files := make([]immutableFile, 0, len(names)+1)
	for _, name := range names {
		digest := testDigest(contents[name])
		_, _ = checksum.WriteString(digest + "  " + name + "\n")
		files = append(files, immutableFile{name: name, sha256: digest, size: int64(len(contents[name]))})
	}
	checksumContents := checksum.Bytes()
	files = append([]immutableFile{{
		name: "SHA256SUMS", sha256: testDigest(checksumContents), size: int64(len(checksumContents)),
	}}, files...)
	allContents := make(map[string][]byte, len(contents)+1)
	for name, data := range contents {
		allContents[name] = data
	}
	allContents["SHA256SUMS"] = checksumContents
	manifest := userspacerelease.Bundle{
		Component: component, Repository: userspaceRepository, Release: tag, Directory: ".",
	}
	for _, immutable := range files {
		path := filepath.Join(directory, immutable.name)
		if err := os.WriteFile(path, allContents[immutable.name], 0o644); err != nil {
			t.Fatal(err)
		}
		manifest.Files = append(manifest.Files, userspacerelease.File{
			Name: immutable.name, Path: immutable.name, SHA256: immutable.sha256,
			Size: immutable.size, Verified: true,
		})
	}
	manifestData, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	manifestData = append(manifestData, '\n')
	if err := os.WriteFile(filepath.Join(directory, bundleManifestName), manifestData, 0o644); err != nil {
		t.Fatal(err)
	}
	return directory, releaseSpec{component: component, tag: tag, files: files}
}

// rewriteBundleReceipt applies one test mutation and rewrites the receipt with
// stable indentation so individual validation boundaries can be exercised.
func rewriteBundleReceipt(t *testing.T, directory string, mutate func(*userspacerelease.Bundle)) {
	t.Helper()
	manifestPath := filepath.Join(directory, bundleManifestName)
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	var receipt userspacerelease.Bundle
	if err := json.Unmarshal(data, &receipt); err != nil {
		t.Fatal(err)
	}
	mutate(&receipt)
	data, err = json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(manifestPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// testDigest returns the lowercase SHA-256 encoding used by bundle fixtures.
func testDigest(contents []byte) string {
	sum := sha256.Sum256(contents)
	return hex.EncodeToString(sum[:])
}

// Compile-time interface coverage keeps the bytes fixture reader tied to the
// streaming archive contract exercised by this test file.
var _ io.Reader = (*bytes.Reader)(nil)
