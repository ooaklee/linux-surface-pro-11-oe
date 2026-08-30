package install

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// TestKnownHeaderSymlinksAreIgnoredWithoutFollowing verifies developer headers
// do not make an otherwise bootable fallback fail preflight.
func TestKnownHeaderSymlinksAreIgnoredWithoutFollowing(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symbolic link creation is not reliably available on Windows")
	}
	root, bundle := fixtureEnvironment(t)
	moduleTree := filepath.Join(root, "usr/lib/modules", fixtureFallbackABI)
	if err := os.Symlink("/usr/src/linux-headers-"+fixtureFallbackABI, filepath.Join(moduleTree, "build")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("build", filepath.Join(moduleTree, "source")); err != nil {
		t.Fatal(err)
	}
	if _, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), fixtureRequest(root, bundle, true)); err != nil {
		t.Fatal(err)
	}
}

// TestUnverifiedLocalBundleRequiresExplicitAcceptance verifies the trust boundary.
func TestUnverifiedLocalBundleRequiresExplicitAcceptance(t *testing.T) {
	t.Parallel()
	root, bundle := fixtureEnvironment(t)
	for index := range bundle.Packages {
		bundle.Packages[index].Verified = false
	}
	manager := fixtureManager(&fakeRunner{root: root})
	request := fixtureRequest(root, bundle, true)
	_, err := manager.Preflight(context.Background(), request)
	if err == nil || !strings.Contains(err.Error(), "explicitly allow") {
		t.Fatalf("error = %v", err)
	}
	request.AllowUnverified = true
	plan, err := manager.Preflight(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if !plan.UnverifiedAccepted {
		t.Fatalf("unverified acceptance was not recorded: %+v", plan)
	}
}

// TestLiveRootCommandsUseAptWithoutACommandShell covers the live-system branch.
func TestLiveRootCommandsUseAptWithoutACommandShell(t *testing.T) {
	t.Parallel()
	packages := []string{"/tmp/linux-modules-test.deb", "/tmp/linux-image-test.deb"}
	commands, err := installationCommands(string(filepath.Separator), fixtureTargetABI, packages)
	if err != nil {
		t.Fatal(err)
	}
	if len(commands) != 3 || filepath.Base(commands[0].Name) != "apt-get" || filepath.Base(commands[1].Name) != "update-initramfs" || filepath.Base(commands[2].Name) != "update-grub" {
		t.Fatalf("unexpected live-root commands: %+v", commands)
	}
	for _, command := range commands {
		if filepath.Base(command.Name) == "sh" || filepath.Base(command.Name) == "bash" || slicesContain(command.Args, "-c") {
			t.Fatalf("command uses a shell: %+v", command)
		}
	}
}

// TestStaleTargetRecoveryEntryFailsPreflight preserves the legacy safety parity.
func TestStaleTargetRecoveryEntryFailsPreflight(t *testing.T) {
	t.Parallel()
	root, bundle := fixtureEnvironment(t)
	grub := fixtureGRUB(false) + "menuentry 'Ubuntu recovery " + fixtureTargetABI + "' {\n" +
		" linux /boot/vmlinuz-" + fixtureTargetABI + "\n" +
		" initrd /boot/initrd.img-" + fixtureTargetABI + "\n}\n"
	writeFixtureFile(t, filepath.Join(root, "boot/grub/grub.cfg"), grub)
	_, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), fixtureRequest(root, bundle, true))
	if err == nil || !strings.Contains(err.Error(), "already has 1 GRUB entries") {
		t.Fatalf("error = %v", err)
	}
}

// TestGRUBTitleParsingIgnoresRecoveryInFlags verifies recovery classification
// uses the title rather than unrelated menuentry options.
func TestGRUBTitleParsingIgnoresRecoveryInFlags(t *testing.T) {
	t.Parallel()
	root, _ := fixtureEnvironment(t)
	grub := "menuentry 'Ubuntu " + fixtureFallbackABI + "' --class recovery-tools {\n" +
		" linux /boot/vmlinuz-" + fixtureFallbackABI + "\n" +
		" initrd /boot/initrd.img-" + fixtureFallbackABI + "\n}\n"
	path := filepath.Join(root, "boot/grub/grub.cfg")
	writeFixtureFile(t, path, grub)
	count, err := countGRUBEntries(context.Background(), path, fixtureFallbackABI, true, false)
	if err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("entry count = %d, want 1", count)
	}
}

// TestLegacyModuleTreeIsAccepted verifies non-usr-merged target roots retain parity.
func TestLegacyModuleTreeIsAccepted(t *testing.T) {
	t.Parallel()
	root, bundle := fixtureEnvironment(t)
	usrTree := filepath.Join(root, "usr/lib/modules", fixtureFallbackABI)
	legacyTree := filepath.Join(root, "lib/modules", fixtureFallbackABI)
	if err := os.MkdirAll(filepath.Dir(legacyTree), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(usrTree, legacyTree); err != nil {
		t.Fatal(err)
	}
	if _, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), fixtureRequest(root, bundle, true)); err != nil {
		t.Fatal(err)
	}
}

// TestRollbackReportsFallbackDamage verifies recovery never claims success when
// a failed maintainer script has damaged the known-good kernel.
func TestRollbackReportsFallbackDamage(t *testing.T) {
	root, bundle := fixtureEnvironment(t)
	runner := &fakeRunner{root: root}
	runner.runHook = func(_ context.Context, command platform.Command) error {
		if slicesContain(command.Args, "--install") {
			writeFixtureFile(t, filepath.Join(root, "boot/vmlinuz-"+fixtureFallbackABI), "damaged fallback")
			return errors.New("fixture package failure")
		}
		return nil
	}
	manager := fixtureManager(runner)
	manager.effectiveUID = func() int { return 0 }
	receipt, err := manager.Install(context.Background(), fixtureRequest(root, bundle, false))
	if err == nil || !strings.Contains(err.Error(), "rollback incomplete") {
		t.Fatalf("error = %v", err)
	}
	if receipt.Rollback == nil || !strings.Contains(receipt.Rollback.Error, "fallback") {
		t.Fatalf("rollback did not report fallback damage: %+v", receipt.Rollback)
	}
	if len(receipt.Rollback.Commands) != 1 || receipt.Rollback.Commands[0].Operation != OperationRollbackPackages {
		t.Fatalf("rollback included redundant commands: %+v", receipt.Rollback.Commands)
	}
}

// TestBoundedCaptureRejectsOversizedMetadata verifies output memory stays bounded.
func TestBoundedCaptureRejectsOversizedMetadata(t *testing.T) {
	t.Parallel()
	root, bundle := fixtureEnvironment(t)
	runner := &fakeRunner{root: root}
	runner.metadataHook = func(name, field string) (string, bool) {
		if strings.HasPrefix(name, "linux-image-") && field == "Depends" {
			return strings.Repeat("a", maximumDependencyBytes+20), true
		}
		return "", false
	}
	_, err := fixtureManager(runner).Preflight(context.Background(), fixtureRequest(root, bundle, true))
	if !errors.Is(err, errCommandOutputLimit) {
		t.Fatalf("error = %v", err)
	}
}

// TestBoundedErrorPreservesUTF8 verifies receipt diagnostics stay valid JSON text.
func TestBoundedErrorPreservesUTF8(t *testing.T) {
	t.Parallel()
	message := strings.Repeat("€", maximumReceiptErrorBytes)
	bounded := boundedError(errors.New(message))
	if len(bounded) > maximumReceiptErrorBytes || !utf8.ValidString(bounded) {
		t.Fatalf("bounded diagnostic is oversized or invalid UTF-8")
	}
}

// TestHeaderPairDependencyRemainsExact verifies constrained local dependencies.
func TestHeaderPairDependencyRemainsExact(t *testing.T) {
	t.Parallel()
	root, bundle := fixtureEnvironment(t)
	directory := filepath.Dir(bundle.Packages[0].Path)
	bundle.Packages = append(bundle.Packages,
		fixturePackage(t, directory, kernel.RoleHeaders, "flavour headers"),
		fixturePackage(t, directory, kernel.RoleCommonHeaders, "common headers"),
	)
	runner := &fakeRunner{root: root}
	runner.metadataHook = func(name, field string) (string, bool) {
		if strings.HasPrefix(name, "linux-headers-") && field == "Depends" {
			return "linux-qcom-x1e-headers-" + strings.TrimSuffix(fixtureTargetABI, "-qcom-x1e") + " (>= " + fixtureVersion + ")", true
		}
		return "", false
	}
	_, err := fixtureManager(runner).Preflight(context.Background(), fixtureRequest(root, bundle, true))
	if err == nil || !strings.Contains(err.Error(), "non-exact or mismatched") {
		t.Fatalf("error = %v", err)
	}
}
