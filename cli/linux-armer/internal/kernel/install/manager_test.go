package install

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// fixtureTargetABI is the current integration release used by installation tests.
	fixtureTargetABI = "7.2.0-jg-0sp11v19-qcom-x1e"
	// fixtureFallbackABI is a distinct earlier Surface ABI kept bootable in fixtures.
	fixtureFallbackABI = "7.2.0-jg-0sp11v18-qcom-x1e"
	// fixtureVersion is the Debian package version shared by the target pair.
	fixtureVersion = "7.2.0-jg-0sp11v19"
)

// fakeRunner records direct commands and supplies deterministic Debian metadata.
type fakeRunner struct {
	mu             sync.Mutex
	runs           []platform.Command
	captures       []platform.Command
	root           string
	mutateAfter    string
	mutatePath     string
	runHook        func(context.Context, platform.Command) error
	metadataHook   func(string, string) (string, bool)
	captureFailure error
}

// Run records one mutating command and delegates fixture changes to runHook.
func (runner *fakeRunner) Run(ctx context.Context, command platform.Command) error {
	if command.Name == unameCommand || command.Name == dpkgDebCommand {
		runner.mu.Lock()
		runner.captures = append(runner.captures, clonePlatformCommand(command))
		runner.mu.Unlock()
		output, err := runner.fixtureCapture(command)
		if err != nil {
			return err
		}
		if command.Stdout == nil {
			return errors.New("bounded capture did not provide stdout")
		}
		_, err = command.Stdout.Write(output)
		return err
	}
	runner.mu.Lock()
	runner.runs = append(runner.runs, clonePlatformCommand(command))
	runner.mu.Unlock()
	if runner.runHook != nil {
		return runner.runHook(ctx, command)
	}
	return nil
}

// Capture returns uname or dpkg-deb fixture output without executing a process.
func (runner *fakeRunner) Capture(_ context.Context, command platform.Command) ([]byte, error) {
	runner.mu.Lock()
	runner.captures = append(runner.captures, clonePlatformCommand(command))
	runner.mu.Unlock()
	return runner.fixtureCapture(command)
}

// fixtureCapture supplies the bytes for one recorded read-only test command.
func (runner *fakeRunner) fixtureCapture(command platform.Command) ([]byte, error) {
	if runner.captureFailure != nil {
		return nil, runner.captureFailure
	}
	if command.Name == unameCommand {
		return []byte(fixtureFallbackABI + "\n"), nil
	}
	if command.Name != dpkgDebCommand || len(command.Args) != 3 {
		return nil, fmt.Errorf("unexpected capture: %s %v", command.Name, command.Args)
	}
	name := filepath.Base(command.Args[1])
	field := command.Args[2]
	if runner.metadataHook != nil {
		if value, handled := runner.metadataHook(name, field); handled {
			return []byte(value + "\n"), nil
		}
	}
	value, err := fixtureMetadata(name, field)
	if err != nil {
		return nil, err
	}
	if runner.mutateAfter == field && runner.mutatePath != "" {
		if err := os.WriteFile(runner.mutatePath, []byte("changed after metadata inspection"), 0o600); err != nil {
			return nil, err
		}
		runner.mutateAfter = ""
	}
	return []byte(value + "\n"), nil
}

// clonePlatformCommand copies argument slices before a test can mutate them.
func clonePlatformCommand(command platform.Command) platform.Command {
	command.Args = append([]string(nil), command.Args...)
	return command
}

// fixtureMetadata returns coherent control fields for fixture package names.
func fixtureMetadata(name, field string) (string, error) {
	role, _, version, err := kernel.ParsePackageName(name)
	if err != nil {
		return "", err
	}
	packageName := strings.TrimSuffix(name, "_"+version+"_arm64.deb")
	if role == kernel.RoleCommonHeaders {
		packageName = strings.TrimSuffix(name, "_"+version+"_all.deb")
	}
	switch field {
	case "Package":
		return packageName, nil
	case "Version":
		return version, nil
	case "Architecture":
		if role == kernel.RoleCommonHeaders {
			return "all", nil
		}
		return "arm64", nil
	case "Depends":
		switch role {
		case kernel.RoleImage:
			return "kmod, linux-modules-" + fixtureTargetABI, nil
		case kernel.RoleHeaders:
			return "linux-qcom-x1e-headers-" + strings.TrimSuffix(fixtureTargetABI, "-qcom-x1e") + " (= " + fixtureVersion + ")", nil
		default:
			return "", nil
		}
	default:
		return "", fmt.Errorf("unexpected metadata field %s", field)
	}
}

// fixtureEnvironment creates a bootable fallback root and coherent package bundle.
func fixtureEnvironment(t *testing.T) (string, kernel.Bundle) {
	t.Helper()
	root := t.TempDir()
	writeFixtureFile(t, filepath.Join(root, "boot/vmlinuz-"+fixtureFallbackABI), "fallback kernel")
	writeFixtureFile(t, filepath.Join(root, "boot/initrd.img-"+fixtureFallbackABI), "fallback initramfs")
	writeFixtureFile(t, filepath.Join(root, "boot/System.map-"+fixtureFallbackABI), "fallback symbols")
	writeFixtureFile(t, filepath.Join(root, "boot/config-"+fixtureFallbackABI), "fallback config")
	writeFixtureFile(t, filepath.Join(root, "usr/lib/modules", fixtureFallbackABI, "modules.dep"), "kernel/fallback.ko.zst:\n")
	writeFixtureFile(t, filepath.Join(root, "usr/lib/modules", fixtureFallbackABI, "kernel/fallback.ko.zst"), "fallback module")
	writeFixtureFile(t, filepath.Join(root, "boot/grub/grub.cfg"), fixtureGRUB(false))
	if err := os.MkdirAll(filepath.Join(root, "var/tmp"), 0o1777); err != nil {
		t.Fatal(err)
	}

	packageDirectory := t.TempDir()
	packages := []kernel.Package{
		fixturePackage(t, packageDirectory, kernel.RoleImage, "image package"),
		fixturePackage(t, packageDirectory, kernel.RoleModules, "modules package"),
	}
	bundle, err := kernel.NewBundle("sp11-v19", "", packages)
	if err != nil {
		t.Fatal(err)
	}
	return root, bundle
}

// fixturePackage writes one package-shaped immutable fixture and records its digest.
func fixturePackage(t *testing.T, directory string, role kernel.PackageRole, content string) kernel.Package {
	t.Helper()
	var name string
	switch role {
	case kernel.RoleImage:
		name = "linux-image-" + fixtureTargetABI + "_" + fixtureVersion + "_arm64.deb"
	case kernel.RoleModules:
		name = "linux-modules-" + fixtureTargetABI + "_" + fixtureVersion + "_arm64.deb"
	case kernel.RoleHeaders:
		name = "linux-headers-" + fixtureTargetABI + "_" + fixtureVersion + "_arm64.deb"
	case kernel.RoleCommonHeaders:
		name = "linux-qcom-x1e-headers-" + strings.TrimSuffix(fixtureTargetABI, "-qcom-x1e") + "_" + fixtureVersion + "_all.deb"
	default:
		t.Fatalf("unsupported fixture role %s", role)
	}
	path := filepath.Join(directory, name)
	writeFixtureFile(t, path, content)
	digest := sha256.Sum256([]byte(content))
	return kernel.Package{
		Role:     role,
		Name:     name,
		Path:     path,
		SHA256:   hex.EncodeToString(digest[:]),
		Size:     int64(len(content)),
		Verified: true,
	}
}

// writeFixtureFile creates all parents and writes one regular test file.
func writeFixtureFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// fixtureGRUB renders one fallback entry and, optionally, one target entry.
func fixtureGRUB(includeTarget bool) string {
	text := "menuentry 'Ubuntu " + fixtureFallbackABI + "' {\n" +
		" linux /boot/vmlinuz-" + fixtureFallbackABI + " root=fixture\n" +
		" initrd /boot/initrd.img-" + fixtureFallbackABI + "\n}\n"
	if includeTarget {
		text += "menuentry 'Ubuntu " + fixtureTargetABI + "' {\n" +
			" linux /boot/vmlinuz-" + fixtureTargetABI + " root=fixture\n" +
			" initrd /boot/initrd.img-" + fixtureTargetABI + "\n}\n"
	}
	return text
}

// fixtureRequest returns the explicit alternate-root request used by most tests.
func fixtureRequest(root string, bundle kernel.Bundle, dryRun bool) Request {
	return Request{
		Bundle:      bundle,
		Root:        root,
		FallbackABI: fixtureFallbackABI,
		RunningABI:  fixtureFallbackABI,
		DryRun:      dryRun,
	}
}

// fixtureManager constructs a non-root test manager with deterministic time.
func fixtureManager(runner *fakeRunner) *Manager {
	manager := New(runner)
	manager.effectiveUID = func() int { return 501 }
	manager.now = func() time.Time { return time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC) }
	return manager
}

// installFixtureTarget simulates Debian maintainer scripts for the target ABI.
func installFixtureTarget(root string) error {
	files := map[string]string{
		filepath.Join(root, "boot/vmlinuz-"+fixtureTargetABI):                                                            "target kernel",
		filepath.Join(root, "boot/System.map-"+fixtureTargetABI):                                                         "target symbols",
		filepath.Join(root, "boot/config-"+fixtureTargetABI):                                                             "target config",
		filepath.Join(root, "usr/lib/modules", fixtureTargetABI, "modules.dep"):                                          "kernel/target.ko.zst:\n",
		filepath.Join(root, "usr/lib/modules", fixtureTargetABI, "kernel/target.ko.zst"):                                 "target module",
		filepath.Join(root, "usr/lib/firmware", fixtureTargetABI, "device-tree/qcom/x1e80100-microsoft-denali-oled.dtb"): "oled dtb",
		filepath.Join(root, "usr/lib/firmware", fixtureTargetABI, "device-tree/qcom/x1p64100-microsoft-denali.dtb"):      "lcd dtb",
	}
	for path, content := range files {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			return err
		}
	}
	return nil
}

// removeFixtureTarget simulates purging only the failed target ABI packages.
func removeFixtureTarget(root string) error {
	paths := []string{
		filepath.Join(root, "boot/vmlinuz-"+fixtureTargetABI),
		filepath.Join(root, "boot/initrd.img-"+fixtureTargetABI),
		filepath.Join(root, "boot/System.map-"+fixtureTargetABI),
		filepath.Join(root, "boot/config-"+fixtureTargetABI),
		filepath.Join(root, "usr/lib/modules", fixtureTargetABI),
		filepath.Join(root, "usr/lib/firmware", fixtureTargetABI),
	}
	for _, path := range paths {
		if err := os.RemoveAll(path); err != nil {
			return err
		}
	}
	return nil
}

// TestPreflightProducesExactDryRunPlan verifies current v19 runtime-only policy.
func TestPreflightProducesExactDryRunPlan(t *testing.T) {
	t.Parallel()
	root, bundle := fixtureEnvironment(t)
	runner := &fakeRunner{root: root}
	manager := fixtureManager(runner)
	plan, err := manager.Preflight(context.Background(), fixtureRequest(root, bundle, true))
	if err != nil {
		t.Fatal(err)
	}
	if plan.TargetABI != fixtureTargetABI || plan.FallbackABI != fixtureFallbackABI || !plan.DryRun {
		t.Fatalf("unexpected plan identity: %+v", plan)
	}
	if len(plan.Packages) != 2 || plan.Packages[0].Role != kernel.RoleModules || plan.Packages[1].Role != kernel.RoleImage {
		t.Fatalf("unexpected package order: %+v", plan.Packages)
	}
	if len(plan.DeviceTrees) != 2 || len(plan.Commands) != 3 {
		t.Fatalf("unexpected plan coverage: %+v", plan)
	}
	if filepath.Base(plan.Commands[0].Name) != "chroot" || filepath.Base(plan.Commands[1].Name) != "chroot" || filepath.Base(plan.Commands[2].Name) != "chroot" {
		t.Fatalf("alternate-root commands = %+v", plan.Commands)
	}
	if len(plan.Commands[0].Args) < 3 || plan.Commands[0].Args[1] != "/usr/bin/dpkg" || plan.Commands[0].Args[2] != "--install" {
		t.Fatalf("alternate-root package command is not chroot-isolated: %+v", plan.Commands[0])
	}
	serialised := fmt.Sprintf("%+v", plan.Commands)
	for _, retired := range []string{"mshw0485_touch", "spi-geni-qcom.ko", "install-sp11-support", "bash", "sh -c"} {
		if strings.Contains(serialised, retired) {
			t.Fatalf("plan contains retired workaround %q: %s", retired, serialised)
		}
	}
}

// TestDryRunNeedsNoPrivilegeAndPerformsNoMutation verifies the privilege boundary.
func TestDryRunNeedsNoPrivilegeAndPerformsNoMutation(t *testing.T) {
	t.Parallel()
	root, bundle := fixtureEnvironment(t)
	runner := &fakeRunner{root: root}
	manager := fixtureManager(runner)
	receipt, err := manager.Install(context.Background(), fixtureRequest(root, bundle, true))
	if err != nil {
		t.Fatal(err)
	}
	if len(receipt.Executed) != 0 || receipt.RebootRequired {
		t.Fatalf("dry-run receipt executed mutations: %+v", receipt)
	}
	if len(runner.runs) != 0 {
		t.Fatalf("dry run invoked runner.Run: %+v", runner.runs)
	}
	if _, err := os.Lstat(filepath.Join(root, "boot/vmlinuz-"+fixtureTargetABI)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("dry run created target kernel: %v", err)
	}
}

// TestInstallRequiresRootAfterPreflight verifies no mutating command runs unprivileged.
func TestInstallRequiresRootAfterPreflight(t *testing.T) {
	t.Parallel()
	root, bundle := fixtureEnvironment(t)
	runner := &fakeRunner{root: root}
	manager := fixtureManager(runner)
	_, err := manager.Install(context.Background(), fixtureRequest(root, bundle, false))
	if err == nil || !strings.Contains(err.Error(), "effective UID 0") {
		t.Fatalf("error = %v", err)
	}
	if len(runner.runs) != 0 {
		t.Fatalf("unprivileged install invoked mutation: %+v", runner.runs)
	}
}

// TestInstallStagesPackagesAndVerifiesBootEvidence exercises the complete happy path.
func TestInstallStagesPackagesAndVerifiesBootEvidence(t *testing.T) {
	root, bundle := fixtureEnvironment(t)
	runner := &fakeRunner{root: root}
	runner.runHook = func(_ context.Context, command platform.Command) error {
		switch {
		case slicesContain(command.Args, "--install"):
			for _, argument := range command.Args {
				if strings.HasSuffix(argument, ".deb") && !strings.Contains(argument, stagingPrefix) {
					return fmt.Errorf("package was not staged: %s", argument)
				}
			}
			return installFixtureTarget(root)
		case command.Name == chrootCommand && slicesContain(command.Args, updateInitramfsCommand):
			writeFixtureFile(t, filepath.Join(root, "boot/initrd.img-"+fixtureTargetABI), "target initramfs")
		case command.Name == chrootCommand && slicesContain(command.Args, updateGRUBCommand):
			writeFixtureFile(t, filepath.Join(root, "boot/grub/grub.cfg"), fixtureGRUB(true))
		}
		return nil
	}
	manager := fixtureManager(runner)
	manager.effectiveUID = func() int { return 0 }
	receipt, err := manager.Install(context.Background(), fixtureRequest(root, bundle, false))
	if err != nil {
		t.Fatal(err)
	}
	if receipt.Installed == nil || receipt.Installed.ABI != fixtureTargetABI || len(receipt.DeviceTrees) != 2 || !receipt.RebootRequired {
		t.Fatalf("unexpected install receipt: %+v", receipt)
	}
	if len(receipt.Executed) != 3 || receipt.Rollback != nil {
		t.Fatalf("unexpected command receipt: %+v", receipt)
	}
}

// TestFailurePurgesOnlyTargetAndRestoresGRUB verifies bounded best-effort rollback.
func TestFailurePurgesOnlyTargetAndRestoresGRUB(t *testing.T) {
	root, bundle := fixtureEnvironment(t)
	originalGRUB, err := os.ReadFile(filepath.Join(root, "boot/grub/grub.cfg"))
	if err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{root: root}
	runner.runHook = func(ctx context.Context, command platform.Command) error {
		switch {
		case slicesContain(command.Args, "--install"):
			if err := installFixtureTarget(root); err != nil {
				return err
			}
			writeFixtureFile(t, filepath.Join(root, "boot/grub/grub.cfg"), "damaged by failed transaction")
		case command.Name == chrootCommand && slicesContain(command.Args, updateInitramfsCommand):
			return errors.New("fixture initramfs failure")
		case slicesContain(command.Args, "--purge"):
			if ctx.Err() != nil {
				return fmt.Errorf("rollback inherited cancellation: %w", ctx.Err())
			}
			return removeFixtureTarget(root)
		}
		return nil
	}
	manager := fixtureManager(runner)
	manager.effectiveUID = func() int { return 0 }
	receipt, err := manager.Install(context.Background(), fixtureRequest(root, bundle, false))
	if err == nil || !strings.Contains(err.Error(), "fixture initramfs failure") {
		t.Fatalf("error = %v", err)
	}
	if receipt.Rollback == nil || !receipt.Rollback.Attempted || !receipt.Rollback.GRUBRestored || receipt.Rollback.Error != "" {
		t.Fatalf("unexpected rollback receipt: %+v", receipt.Rollback)
	}
	restored, readErr := os.ReadFile(filepath.Join(root, "boot/grub/grub.cfg"))
	if readErr != nil || string(restored) != string(originalGRUB) {
		t.Fatalf("GRUB was not restored: %q, %v", restored, readErr)
	}
	if _, statErr := os.Lstat(filepath.Join(root, "boot/vmlinuz-"+fixtureFallbackABI)); statErr != nil {
		t.Fatalf("fallback kernel was removed: %v", statErr)
	}
	if _, statErr := os.Lstat(filepath.Join(root, "boot/vmlinuz-"+fixtureTargetABI)); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("target kernel remained after rollback: %v", statErr)
	}
}

// TestCancelledInstallUsesIndependentRollbackContext verifies cancellation recovery.
func TestCancelledInstallUsesIndependentRollbackContext(t *testing.T) {
	root, bundle := fixtureEnvironment(t)
	runner := &fakeRunner{root: root}
	runner.runHook = func(ctx context.Context, command platform.Command) error {
		if slicesContain(command.Args, "--install") {
			if err := installFixtureTarget(root); err != nil {
				return err
			}
			return context.Canceled
		}
		if slicesContain(command.Args, "--purge") {
			if ctx.Err() != nil {
				return errors.New("rollback context was already cancelled")
			}
			return removeFixtureTarget(root)
		}
		return nil
	}
	manager := fixtureManager(runner)
	manager.effectiveUID = func() int { return 0 }
	receipt, err := manager.Install(context.Background(), fixtureRequest(root, bundle, false))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v", err)
	}
	if receipt.Rollback == nil || !receipt.Rollback.GRUBRestored || receipt.Rollback.Error != "" {
		t.Fatalf("unexpected cancellation rollback: %+v", receipt.Rollback)
	}
}

// TestSourceMutationAfterPreflightIsRejectedBeforeMutation verifies TOCTOU defence.
func TestSourceMutationAfterPreflightIsRejectedBeforeMutation(t *testing.T) {
	root, bundle := fixtureEnvironment(t)
	image, ok := bundle.Package(kernel.RoleImage)
	if !ok {
		t.Fatal("fixture image package missing")
	}
	runner := &fakeRunner{root: root, mutateAfter: "Depends", mutatePath: image.Path}
	manager := fixtureManager(runner)
	manager.effectiveUID = func() int { return 0 }
	_, err := manager.Install(context.Background(), fixtureRequest(root, bundle, false))
	if err == nil || !strings.Contains(err.Error(), "changed after preflight") {
		t.Fatalf("error = %v", err)
	}
	if len(runner.runs) != 0 {
		t.Fatalf("mutated input crossed privilege boundary: %+v", runner.runs)
	}
}

// TestPackageSymlinkAndTargetArtefactAreRejected exercises hostile path inputs.
func TestPackageSymlinkAndTargetArtefactAreRejected(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symbolic link creation is not reliably available on Windows")
	}
	t.Run("package symlink", func(t *testing.T) {
		root, bundle := fixtureEnvironment(t)
		image, _ := bundle.Package(kernel.RoleImage)
		realPath := image.Path + ".real"
		if err := os.Rename(image.Path, realPath); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(realPath, image.Path); err != nil {
			t.Fatal(err)
		}
		_, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), fixtureRequest(root, bundle, true))
		if err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("pre-existing target symlink", func(t *testing.T) {
		root, bundle := fixtureEnvironment(t)
		outside := filepath.Join(t.TempDir(), "outside")
		writeFixtureFile(t, outside, "outside")
		if err := os.Symlink(outside, filepath.Join(root, "boot/vmlinuz-"+fixtureTargetABI)); err != nil {
			t.Fatal(err)
		}
		_, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), fixtureRequest(root, bundle, true))
		if err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("target parent symlink escape", func(t *testing.T) {
		root, bundle := fixtureEnvironment(t)
		outside := t.TempDir()
		if err := os.Rename(filepath.Join(root, "boot"), filepath.Join(outside, "boot")); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(outside, "boot"), filepath.Join(root, "boot")); err != nil {
			t.Fatal(err)
		}
		_, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), fixtureRequest(root, bundle, true))
		if err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Fatalf("error = %v", err)
		}
	})
}

// TestPackagePolicyRejectsUnexpectedSetsAndMetadata exercises the closed allow-list.
func TestPackagePolicyRejectsUnexpectedSetsAndMetadata(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*testing.T, *kernel.Bundle, *fakeRunner)
		want   string
	}{
		{
			name: "headers without common headers",
			mutate: func(t *testing.T, bundle *kernel.Bundle, _ *fakeRunner) {
				bundle.Packages = append(bundle.Packages, fixturePackage(t, filepath.Dir(bundle.Packages[0].Path), kernel.RoleHeaders, "headers"))
			},
			want: "exactly the runtime pair or runtime and header pairs",
		},
		{
			name: "wrong control package",
			mutate: func(_ *testing.T, _ *kernel.Bundle, runner *fakeRunner) {
				runner.metadataHook = func(name, field string) (string, bool) {
					if strings.HasPrefix(name, "linux-image-") && field == "Package" {
						return "linux-image-hostile-qcom-x1e", true
					}
					return "", false
				}
			},
			want: "control name",
		},
		{
			name: "cross ABI dependency",
			mutate: func(_ *testing.T, _ *kernel.Bundle, runner *fakeRunner) {
				runner.metadataHook = func(name, field string) (string, bool) {
					if strings.HasPrefix(name, "linux-image-") && field == "Depends" {
						return "linux-modules-7.3.0-hostile-qcom-x1e", true
					}
					return "", false
				}
			},
			want: "outside the selected ABI set",
		},
		{
			name: "control character",
			mutate: func(_ *testing.T, _ *kernel.Bundle, runner *fakeRunner) {
				runner.metadataHook = func(name, field string) (string, bool) {
					if strings.HasPrefix(name, "linux-image-") && field == "Depends" {
						return "kmod\x00hostile", true
					}
					return "", false
				}
			},
			want: "control characters",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			root, bundle := fixtureEnvironment(t)
			runner := &fakeRunner{root: root}
			test.mutate(t, &bundle, runner)
			_, err := fixtureManager(runner).Preflight(context.Background(), fixtureRequest(root, bundle, true))
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want %q", err, test.want)
			}
		})
	}
}

// TestCoherentOptionalHeaderPairIsAccepted verifies exact four-package support.
func TestCoherentOptionalHeaderPairIsAccepted(t *testing.T) {
	t.Parallel()
	root, bundle := fixtureEnvironment(t)
	directory := filepath.Dir(bundle.Packages[0].Path)
	bundle.Packages = append(bundle.Packages,
		fixturePackage(t, directory, kernel.RoleHeaders, "flavour headers"),
		fixturePackage(t, directory, kernel.RoleCommonHeaders, "common headers"),
	)
	plan, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), fixtureRequest(root, bundle, true))
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Packages) != 4 || plan.Packages[2].Role != kernel.RoleCommonHeaders || plan.Packages[3].Role != kernel.RoleHeaders {
		t.Fatalf("unexpected header package order: %+v", plan.Packages)
	}
}

// TestFallbackMustBeRunningAndBootable verifies the recovery-kernel invariant.
func TestFallbackMustBeRunningAndBootable(t *testing.T) {
	t.Run("not running", func(t *testing.T) {
		root, bundle := fixtureEnvironment(t)
		request := fixtureRequest(root, bundle, true)
		request.RunningABI = "7.2.0-jg-0sp11v17-qcom-x1e"
		_, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), request)
		if err == nil || !strings.Contains(err.Error(), "exactly match") {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("missing initramfs", func(t *testing.T) {
		root, bundle := fixtureEnvironment(t)
		if err := os.Remove(filepath.Join(root, "boot/initrd.img-"+fixtureFallbackABI)); err != nil {
			t.Fatal(err)
		}
		_, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), fixtureRequest(root, bundle, true))
		if err == nil || !strings.Contains(err.Error(), "initramfs") {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("recovery only", func(t *testing.T) {
		root, bundle := fixtureEnvironment(t)
		grub := "menuentry 'Ubuntu recovery " + fixtureFallbackABI + "' {\n linux /boot/vmlinuz-" + fixtureFallbackABI + "\n initrd /boot/initrd.img-" + fixtureFallbackABI + "\n}\n"
		writeFixtureFile(t, filepath.Join(root, "boot/grub/grub.cfg"), grub)
		_, err := fixtureManager(&fakeRunner{root: root}).Preflight(context.Background(), fixtureRequest(root, bundle, true))
		if err == nil || !strings.Contains(err.Error(), "exactly one") {
			t.Fatalf("error = %v", err)
		}
	})
}

// TestRequestAndCancellationValidationRejectsBeforeInspection exercises early checks.
func TestRequestAndCancellationValidationRejectsBeforeInspection(t *testing.T) {
	root, bundle := fixtureEnvironment(t)
	runner := &fakeRunner{root: root}
	manager := fixtureManager(runner)
	tests := []struct {
		name    string
		request Request
		context context.Context
		want    string
	}{
		{name: "missing root", request: fixtureRequest(root, bundle, true), context: context.Background(), want: "root is required"},
		{name: "relative root", request: fixtureRequest(root, bundle, true), context: context.Background(), want: "canonical and absolute"},
		{name: "same fallback", request: fixtureRequest(root, bundle, true), context: context.Background(), want: "must differ"},
	}
	tests[0].request.Root = ""
	tests[1].request.Root = "relative"
	tests[2].request.FallbackABI = fixtureTargetABI
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := manager.Preflight(test.context, test.request)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want %q", err, test.want)
			}
		})
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := manager.Preflight(cancelled, fixtureRequest(root, bundle, true))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled error = %v", err)
	}
}

// slicesContain reports whether a command argument list contains an exact value.
func slicesContain(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}
