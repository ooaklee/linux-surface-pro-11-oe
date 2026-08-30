package ubuntu

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestStageInstalledSupportFiles verifies every hand-off helper is staged with
// the expected permissions and exact kernel ABI before container installation.
func TestStageInstalledSupportFiles(t *testing.T) {
	workspace := t.TempDir()
	abi := "7.2.0-jg-0sp11v19-qcom-x1e"
	if err := stageInstalledSupportFiles(workspace, abi); err != nil {
		t.Fatalf("stageInstalledSupportFiles() error = %v", err)
	}
	for _, expected := range []struct {
		name string
		mode os.FileMode
	}{
		{name: "99-surface-pro-11.cfg", mode: 0o644},
		{name: "09_linux_armer_sp11", mode: 0o755},
		{name: "linux-armer-refresh-sp11-boot", mode: 0o755},
		{name: "05-linux-armer-sp11-dtb", mode: 0o755},
		{name: "05-linux-armer-sp11-dtb-remove", mode: 0o755},
		{name: "kernel-abi", mode: 0o644},
	} {
		info, err := os.Stat(filepath.Join(workspace, "installed-support", expected.name))
		if err != nil {
			t.Errorf("staged support file %s: %v", expected.name, err)
			continue
		}
		if got := info.Mode().Perm(); got != expected.mode {
			t.Errorf("staged support file %s mode = %#o, want %#o", expected.name, got, expected.mode)
		}
		if expected.mode&0o111 != 0 {
			path := filepath.Join(workspace, "installed-support", expected.name)
			if output, err := exec.Command("sh", "-n", path).CombinedOutput(); err != nil {
				t.Errorf("staged support file %s has invalid shell syntax: %v\n%s", expected.name, err, output)
			}
		}
	}
	abiBytes, err := os.ReadFile(filepath.Join(workspace, "installed-support", "kernel-abi"))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(abiBytes); got != abi+"\n" {
		t.Fatalf("staged kernel ABI = %q, want %q", got, abi+"\n")
	}
}

// TestStageInstalledSupportFilesRejectsUnsafeABI verifies an ABI cannot escape
// the bounded installed-system paths through support-file generation.
func TestStageInstalledSupportFilesRejectsUnsafeABI(t *testing.T) {
	err := stageInstalledSupportFiles(t.TempDir(), "../unsafe")
	if err == nil || !strings.Contains(err.Error(), "not safe") {
		t.Fatalf("stageInstalledSupportFiles() error = %v, want unsafe-ABI error", err)
	}
}

// TestInstalledSupportSeparatesLiveAndInstalledArguments verifies installed
// boot entries receive current platform arguments but never the USB blacklist.
func TestInstalledSupportSeparatesLiveAndInstalledArguments(t *testing.T) {
	defaults := installedGrubDefaults()
	for _, argument := range []string{
		"clk_ignore_unused",
		"pd_ignore_unused",
		"arm64.nopauth",
		"systemd.tpm2_wait=0",
		"soundwire_qcom.sp11_feedback_active_offset2_zero=1",
	} {
		if !strings.Contains(defaults, argument) {
			t.Errorf("installed GRUB defaults do not contain %q", argument)
		}
	}
	allInstalledSupport := defaults + installedGrubGenerator() + installedBootRefresh() +
		installedKernelPostInstallHook() + installedKernelPostRemoveHook()
	if strings.Contains(allInstalledSupport, "qcom_q6v5_pas") {
		t.Fatal("installed-system support contains the live USB qcom_q6v5_pas blacklist")
	}
}

// TestInstalledGrubGeneratorProvidesExplicitModels verifies first installed
// boot offers deterministic X1E and X1P choices with their respective DTBs.
func TestInstalledGrubGeneratorProvidesExplicitModels(t *testing.T) {
	generator := installedGrubGenerator()
	for _, required := range []string{
		"Linux Armer Surface Pro 11 X1E/OLED",
		"Linux Armer Surface Pro 11 X1P/LCD",
		"x1e80100-microsoft-denali-oled.dtb",
		"x1p64100-microsoft-denali.dtb",
		"initrd.img-$abi",
		"prepare_grub_to_access_device",
		"relative_boot=$(make_system_path_relative_to_its_root /boot)",
		"boot_device=${GRUB_DEVICE_BOOT:-${GRUB_DEVICE:-}}",
		"root_argument=\"root=UUID=${GRUB_DEVICE_UUID}\"",
		"root_argument=\"root=${GRUB_DEVICE}\"",
	} {
		if !strings.Contains(generator, required) {
			t.Errorf("installed GRUB generator does not contain %q", required)
		}
	}
}

// TestInstalledKernelHooksSeparateInstallAndRemoval verifies package removal
// cannot regenerate another kernel's DTBs or leave the removed ABI directory.
func TestInstalledKernelHooksSeparateInstallAndRemoval(t *testing.T) {
	postInstall := installedKernelPostInstallHook()
	postRemove := installedKernelPostRemoveHook()
	if !strings.Contains(postInstall, "linux-armer-refresh-sp11-boot") {
		t.Fatal("post-install hook does not refresh the installed kernel's DTBs")
	}
	for _, required := range []string{
		`*[!A-Za-z0-9.+_~-]*`,
		`rm -rf -- "/boot/dtbs/$abi"`,
	} {
		if !strings.Contains(postRemove, required) {
			t.Errorf("post-remove hook does not contain %q", required)
		}
	}
	if strings.Contains(postRemove, "linux-armer-refresh-sp11-boot") {
		t.Fatal("post-remove hook unexpectedly refreshes another kernel")
	}
}

// TestInstalledBootRefreshIsABIBounded verifies future-kernel refreshes inspect
// only exact ABI paths and require both model-specific device trees.
func TestInstalledBootRefreshIsABIBounded(t *testing.T) {
	refresh := installedBootRefresh()
	for _, required := range []string{
		"is_safe_abi",
		"/usr/lib/firmware/$abi/device-tree/qcom/$name",
		"/usr/lib/linux-image-$abi/qcom/$name",
		"x1e80100-microsoft-denali-oled.dtb",
		"x1p64100-microsoft-denali.dtb",
		`[ "$abi" = "$seed_abi" ]`,
	} {
		if !strings.Contains(refresh, required) {
			t.Errorf("installed boot refresh does not contain %q", required)
		}
	}
	for _, forbidden := range []string{"/usr/lib/firmware/*", "/usr/lib/linux-image-*"} {
		if strings.Contains(refresh, forbidden) {
			t.Errorf("installed boot refresh contains unbounded path %q", forbidden)
		}
	}
}

// TestInstalledPackageStatusRequiresExactInstalledRecord verifies dpkg status
// matching rejects a wrong version, architecture, or half-configured package.
func TestInstalledPackageStatusRequiresExactInstalledRecord(t *testing.T) {
	status := `Package: linux-modules-test
Status: install ok installed
Architecture: arm64
Version: 1.2.3

Package: linux-image-test
Status: install ok half-configured
Architecture: arm64
Version: 1.2.3
`
	if !installedPackageStatus(status, "linux-modules-test", "1.2.3") {
		t.Fatal("installedPackageStatus() rejected an exact installed package")
	}
	for _, test := range []struct {
		name    string
		version string
	}{
		{name: "linux-image-test", version: "1.2.3"},
		{name: "linux-modules-test", version: "9.9.9"},
		{name: "missing", version: "1.2.3"},
	} {
		if installedPackageStatus(status, test.name, test.version) {
			t.Errorf("installedPackageStatus(%q, %q) accepted a non-installed record", test.name, test.version)
		}
	}
}
