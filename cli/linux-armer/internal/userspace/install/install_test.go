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
	userspaceiptsd "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/iptsd"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
)

// fakeRunner records privileged commands and optionally inspects their staged
// inputs at execution time without invoking a system package manager or script.
type fakeRunner struct {
	commands []platform.Command
	err      error
	inspect  func(platform.Command) error
}

// blockingActivationRunner waits for cancellation to prove per-command timeout
// enforcement without starting a host process.
type blockingActivationRunner struct {
	runs int
}

// Run blocks until the supplied command context is cancelled.
func (runner *blockingActivationRunner) Run(ctx context.Context, _ platform.Command) error {
	runner.runs++
	<-ctx.Done()
	return ctx.Err()
}

// Capture is unavailable because native activation uses only bounded Run I/O.
func (*blockingActivationRunner) Capture(context.Context, platform.Command) ([]byte, error) {
	return nil, errors.New("unexpected capture")
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

// nativeIPTSDExtractor creates a tiny private tree for transaction tests; the
// production contract validator is replaced only inside these tests.
type nativeIPTSDExtractor struct {
	extractions int
}

// Validate is deliberately unused because native dry-runs fully extract and
// validate immutable input.
func (*nativeIPTSDExtractor) Validate(context.Context, string) error {
	return errors.New("unexpected validate-only IPTSD path")
}

// Extract creates one regular source beneath the expected archive root.
func (extractor *nativeIPTSDExtractor) Extract(_ context.Context, _ string, destination string) error {
	extractor.extractions++
	root := filepath.Join(destination, userspaceiptsd.ArchiveRoot)
	if err := os.Mkdir(root, 0o700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(root, "fixture-binary"), []byte("new-binary"), 0o755)
}

// TestIPTSDNativeDryRunAndInstall verifies full dry-run extraction, exact file
// planning, native rendering, private backup/receipt state, and mask creation.
func TestIPTSDNativeDryRunAndInstall(t *testing.T) {
	bundle := makeTestIPTSDBundle(t)
	root := t.TempDir()
	existing := filepath.Join(root, "usr/local/libexec/sp11-iptsd")
	if err := os.MkdirAll(filepath.Dir(existing), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(existing, []byte("old-binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{}
	installer, extractor := configureTestIPTSDInstaller(t, runner)
	installer.euid = func() int { return 501 }
	dryRun, err := installer.IPTSD(context.Background(), Options{BundleDir: bundle, Root: root, DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if extractor.extractions != 1 || len(dryRun.Files) != 3 || !dryRun.Files[0].Replaced || dryRun.FilesInstalled {
		t.Fatalf("unexpected native dry-run: result=%+v extractor=%+v", dryRun, extractor)
	}
	if len(runner.commands) != 0 || len(dryRun.Commands) != 0 {
		t.Fatalf("alternate-root dry-run commands = %+v", dryRun.Commands)
	}
	if got, _ := os.ReadFile(existing); string(got) != "old-binary" {
		t.Fatalf("dry-run changed target: %q", got)
	}
	installer.euid = func() int { return 0 }
	result, err := installer.IPTSD(context.Background(), Options{BundleDir: bundle, Root: root})
	if err != nil {
		t.Fatal(err)
	}
	if !result.FilesInstalled || !result.ActivationComplete || result.Receipt == "" || result.BackupDirectory == "" {
		t.Fatalf("unexpected install result: %+v", result)
	}
	if got, _ := os.ReadFile(existing); string(got) != "new-binary" {
		t.Fatalf("installed binary = %q", got)
	}
	if got, _ := os.ReadFile(result.Files[0].Backup); string(got) != "old-binary" {
		t.Fatalf("backup = %q", got)
	}
	if got, _ := os.ReadFile(filepath.Join(root, "etc/systemd/system/sp11-iptsd@.service")); string(got) != "rendered-unit\n" {
		t.Fatalf("rendered unit = %q", got)
	}
	mask := filepath.Join(root, filepath.FromSlash(iptsdMaskRelative))
	if target, err := os.Readlink(mask); err != nil || target != "/dev/null" {
		t.Fatalf("mask target = %q, error = %v", target, err)
	}
	if info, err := os.Stat(result.BackupDirectory); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("backup permissions = %v, error = %v", info, err)
	}
	if info, err := os.Stat(result.Receipt); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("receipt permissions = %v, error = %v", info, err)
	}
}

// TestIPTSDRejectsSymlinkedTarget verifies that native publication never
// follows or replaces an attacker-controlled final target link.
func TestIPTSDRejectsSymlinkedTarget(t *testing.T) {
	bundle := makeTestIPTSDBundle(t)
	root := t.TempDir()
	target := filepath.Join(root, "usr/local/libexec/sp11-iptsd")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(t.TempDir(), "escape"), target); err != nil {
		t.Fatal(err)
	}
	installer, _ := configureTestIPTSDInstaller(t, &fakeRunner{})
	installer.euid = func() int { return 501 }
	_, err := installer.IPTSD(context.Background(), Options{BundleDir: bundle, Root: root, DryRun: true})
	if err == nil || !strings.Contains(err.Error(), "symlinked userspace target") {
		t.Fatalf("error = %v", err)
	}
}

// TestIPTSDMaskRevalidationRejectsParentSwap verifies that the intentional mask
// cannot be redirected after planning by replacing its systemd parent.
func TestIPTSDMaskRevalidationRejectsParentSwap(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "etc/systemd/system")
	if err := os.MkdirAll(parent, 0o755); err != nil {
		t.Fatal(err)
	}
	mask, err := inspectIPTSDMask(root)
	if err != nil {
		t.Fatal(err)
	}
	saved := filepath.Join(root, "saved-systemd")
	if err := os.Rename(parent, saved); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, parent); err != nil {
		t.Fatal(err)
	}
	if err := revalidateIPTSDMask(root, mask); err == nil || !strings.Contains(err.Error(), "parent changed") {
		t.Fatalf("error = %v", err)
	}
}

// TestIPTSDMutationRollsBackPublishedFiles verifies that a target appearing
// between planning and publication aborts and restores every earlier member.
func TestIPTSDMutationRollsBackPublishedFiles(t *testing.T) {
	bundle := makeTestIPTSDBundle(t)
	root := t.TempDir()
	first := filepath.Join(root, "usr/local/libexec/sp11-iptsd")
	if err := os.MkdirAll(filepath.Dir(first), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(first, []byte("old-binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	installer, _ := configureTestIPTSDInstaller(t, &fakeRunner{})
	installer.euid = func() int { return 0 }
	installer.beforeIPTSDPublish = func(index int, target string) error {
		if index != 1 {
			return nil
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return os.WriteFile(target, []byte("attacker"), 0o644)
	}
	result, err := installer.IPTSD(context.Background(), Options{BundleDir: bundle, Root: root})
	if err == nil || !strings.Contains(err.Error(), "appeared after planning") {
		t.Fatalf("result=%+v error=%v", result, err)
	}
	if got, _ := os.ReadFile(first); string(got) != "old-binary" {
		t.Fatalf("rollback restored %q", got)
	}
	if _, err := os.Lstat(filepath.Join(root, filepath.FromSlash(iptsdMaskRelative))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("mask survived rollback: %v", err)
	}
}

// TestIPTSDActivationFailurePreservesInstalledState verifies that live command
// failure is reported after durable files and receipt state remain visible.
func TestIPTSDActivationFailurePreservesInstalledState(t *testing.T) {
	bundle := makeTestIPTSDBundle(t)
	runner := &fakeRunner{err: errors.New("service unavailable")}
	installer, _ := configureTestIPTSDInstaller(t, runner)
	installer.euid = func() int { return 0 }
	installer.isLiveRoot = func(string) bool { return true }
	result, err := installer.IPTSD(context.Background(), Options{BundleDir: bundle, Root: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "files are installed") {
		t.Fatalf("result=%+v error=%v", result, err)
	}
	if !result.FilesInstalled || result.ActivationComplete || result.ActivationError == "" || len(runner.commands) != len(iptsdActivationCommands) {
		t.Fatalf("incomplete activation state = %+v, commands=%+v", result, runner.commands)
	}
	for _, command := range runner.commands {
		if command.Name != "/usr/bin/systemctl" && command.Name != "/usr/bin/udevadm" {
			t.Fatalf("unexpected activation executable: %+v", command)
		}
	}
	data, readErr := os.ReadFile(result.Receipt)
	if readErr != nil || !bytes.Contains(data, []byte(`"files_installed": true`)) || !bytes.Contains(data, []byte(`"activation_complete": false`)) {
		t.Fatalf("receipt=%s error=%v", data, readErr)
	}
}

// TestIPTSDActivationCommandsAreTimeoutBound verifies that an unresponsive
// fixed system operation cannot block the installer indefinitely.
func TestIPTSDActivationCommandsAreTimeoutBound(t *testing.T) {
	runner := &blockingActivationRunner{}
	installer := New(runner)
	installer.activationTimeout = time.Millisecond
	err := installer.activateIPTSD(context.Background(), []Command{{Name: "/usr/bin/systemctl", Args: []string{"daemon-reload"}}})
	if err == nil || runner.runs != 1 || !strings.Contains(err.Error(), "deadline exceeded") {
		t.Fatalf("runs=%d error=%v", runner.runs, err)
	}
}

// makeTestIPTSDBundle creates one outer verified bundle for native transaction
// tests and temporarily installs its matching compiled test policy.
func makeTestIPTSDBundle(t *testing.T) string {
	t.Helper()
	originalSpec := iptsdSpec
	t.Cleanup(func() { iptsdSpec = originalSpec })
	bundle, spec := makeBundle(t, IPTSDComponent, "sp11-iptsd-v1", map[string][]byte{
		iptsdArchiveName:                  []byte("archive"),
		"sp11-iptsd-release-manifest.txt": []byte("manifest"),
	})
	iptsdSpec = spec
	return bundle
}

// configureTestIPTSDInstaller supplies a two-file release contract while
// retaining the production planner, publisher, mask, receipt, and rollback.
func configureTestIPTSDInstaller(t *testing.T, runner platform.Runner) (*Installer, *nativeIPTSDExtractor) {
	t.Helper()
	extractor := &nativeIPTSDExtractor{}
	installer := New(runner)
	installer.extractor = extractor
	installer.now = func() time.Time { return time.Date(2026, 8, 30, 12, 34, 56, 7, time.UTC) }
	installer.validateIPTSDRelease = func(root string) (userspaceiptsd.Release, error) {
		source := filepath.Join(root, "fixture-binary")
		return userspaceiptsd.Release{Files: []userspaceiptsd.InstallFile{
			{Source: source, SourceLabel: "archive:payload/fixture-binary", Target: "usr/local/libexec/sp11-iptsd", Mode: 0o755, SHA256: testDigest([]byte("new-binary")), Size: 10},
			{SourceLabel: "rendered:sp11-iptsd@.service", Data: []byte("rendered-unit\n"), Target: "etc/systemd/system/sp11-iptsd@.service", Mode: 0o644, SHA256: testDigest([]byte("rendered-unit\n")), Size: 14},
		}}, nil
	}
	return installer, extractor
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

// TestPinnedIPTSDArchiveFixture optionally validates an actual downloaded IPTSD
// release through both secure extraction and the complete native contract.
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
	release, err := userspaceiptsd.ValidateRelease(filepath.Join(destination, userspaceiptsd.ArchiveRoot))
	if err != nil {
		t.Fatal(err)
	}
	if len(release.Files) != 28 {
		t.Fatalf("native install files = %d, want 28", len(release.Files))
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
