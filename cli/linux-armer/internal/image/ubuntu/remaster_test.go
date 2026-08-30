package ubuntu

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

func TestUpdatePackageManifestPreservesLayeredDiffHeaders(t *testing.T) {
	path := filepath.Join(t.TempDir(), "minimal.manifest")
	input := "--- full.manifest\n+++ minimal.manifest\n+base-package\t1.0\n"
	if err := os.WriteFile(path, []byte(input), 0o644); err != nil {
		t.Fatal(err)
	}
	bundle := kernel.Bundle{
		Version: "7.2.0-jg-0sp11v19",
		Packages: []kernel.Package{
			{Role: kernel.RoleImage, Name: "linux-image-custom_7.2.0-jg-0sp11v19_arm64.deb"},
			{Role: kernel.RoleModules, Name: "linux-modules-custom_7.2.0-jg-0sp11v19_arm64.deb"},
		},
	}

	if err := updatePackageManifest(path, bundle); err != nil {
		t.Fatalf("updatePackageManifest() error = %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) < 2 || lines[0] != "--- full.manifest" || lines[1] != "+++ minimal.manifest" {
		t.Fatalf("manifest headers were not preserved: %q", string(data))
	}
	for _, want := range []string{
		"+linux-image-custom\t7.2.0-jg-0sp11v19",
		"+linux-modules-custom\t7.2.0-jg-0sp11v19",
	} {
		if !strings.Contains(string(data), want) {
			t.Errorf("manifest does not contain %q:\n%s", want, data)
		}
	}
}

func TestValidateSourceLayout(t *testing.T) {
	workspace := t.TempDir()
	configuration := `kernel:
  default: linux-qcom-x1e
sources:
- path: minimal.squashfs
  type: fsimage-layered
- path: minimal.standard.squashfs
  type: fsimage-layered
`
	if err := os.WriteFile(filepath.Join(workspace, "install-sources.yaml"), []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{
		"minimal.squashfs",
		"minimal.standard.squashfs",
		"minimal.standard.live.squashfs",
	} {
		if err := os.WriteFile(filepath.Join(workspace, name), []byte("squashfs"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if err := validateSourceLayout(workspace); err != nil {
		t.Fatalf("validateSourceLayout() error = %v", err)
	}
}

func TestValidateSourceLayoutRejectsNonLayeredSource(t *testing.T) {
	workspace := t.TempDir()
	configuration := "kernel:\n  default: linux-qcom-x1e\nsources:\n- path: minimal.squashfs\n  type: fsimage\n- path: minimal.standard.squashfs\n  type: fsimage\n"
	if err := os.WriteFile(filepath.Join(workspace, "install-sources.yaml"), []byte(configuration), 0o644); err != nil {
		t.Fatal(err)
	}

	err := validateSourceLayout(workspace)
	if err == nil || !strings.Contains(err.Error(), "fsimage-layered") {
		t.Fatalf("validateSourceLayout() error = %v, want layered-layout error", err)
	}
}

func TestStageFileDereferencesSourceSymlink(t *testing.T) {
	directory := t.TempDir()
	source := filepath.Join(directory, "source.iso")
	link := filepath.Join(directory, "latest.iso")
	destination := filepath.Join(directory, "workspace", "source.iso")
	if err := os.WriteFile(source, []byte("image bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(source, link); err != nil {
		t.Fatal(err)
	}
	if err := stageFile(link, destination); err != nil {
		t.Fatalf("stageFile() error = %v", err)
	}
	if info, err := os.Lstat(destination); err != nil {
		t.Fatal(err)
	} else if info.Mode()&os.ModeSymlink != 0 {
		t.Fatal("stageFile() preserved a source symlink instead of copying its target")
	}
	if err := os.Remove(source); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(destination)
	if err != nil {
		t.Fatalf("staged file no longer works after removing symlink target: %v", err)
	}
	if string(data) != "image bytes" {
		t.Fatalf("staged contents = %q", data)
	}
}

func TestAppendedESPOffset(t *testing.T) {
	report := "GPT start and size :   2  7817736  12288\n"
	offset, err := appendedESPOffset(report)
	if err != nil {
		t.Fatalf("appendedESPOffset() error = %v", err)
	}
	if want := int64(7817736 * 512); offset != want {
		t.Fatalf("appendedESPOffset() = %d, want %d", offset, want)
	}
}

func TestAppendedESPOffsetRejectsInvalidPartition(t *testing.T) {
	for _, report := range []string{
		"System area summary: GPT\n",
		"GPT start and size : 2 100 0\n",
		"GPT start and size : 2 18014398509481984 1\n",
	} {
		if _, err := appendedESPOffset(report); err == nil {
			t.Fatalf("appendedESPOffset(%q) succeeded, want error", report)
		}
	}
}

func TestGrubConfigPairsDeviceTreesWithBootEntries(t *testing.T) {
	config := grubConfig("test-abi")
	for _, want := range []string{
		"Ubuntu for Surface Pro 11 X1E/OLED (test-abi)",
		"Ubuntu for Surface Pro 11 X1P/LCD (test-abi, hardware qualification pending)",
		"devicetree /sp11/dtb/x1e80100-microsoft-denali-oled.dtb",
		"devicetree /sp11/dtb/x1p64100-microsoft-denali.dtb",
		"modprobe.blacklist=qcom_q6v5_pas",
		"insmod part_gpt",
		"insmod iso9660",
		"insmod search_fs_file",
		"insmod smbios",
		"insmod regexp",
		"insmod fdt",
		"search --no-floppy --file --set=iso_root /casper/vmlinuz",
		"set root=$iso_root",
	} {
		if !strings.Contains(config, want) {
			t.Errorf("grubConfig() does not contain %q", want)
		}
	}
}

func TestSafeKernelABI(t *testing.T) {
	for _, test := range []struct {
		abi  string
		want bool
	}{
		{abi: "7.2.0-jg-0sp11v19-qcom-x1e", want: true},
		{abi: "../escape", want: false},
		{abi: "contains/slash", want: false},
		{abi: "contains space", want: false},
		{abi: "", want: false},
	} {
		if got := safeKernelABI(test.abi); got != test.want {
			t.Errorf("safeKernelABI(%q) = %v, want %v", test.abi, got, test.want)
		}
	}
}
