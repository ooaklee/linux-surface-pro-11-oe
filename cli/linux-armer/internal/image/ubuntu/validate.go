package ubuntu

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// Validator inspects a completed Ubuntu image with isolated tooling and produces
// a digest-bound report covering its boot layout and embedded kernel payload.
type Validator struct {
	// Docker provides xorriso, SquashFS, initramfs, and FAT inspection tools.
	Docker *platform.Docker
}

// NewValidator creates a structural image validator and supplies the standard
// Docker runner when none is injected.
func NewValidator(docker *platform.Docker) *Validator {
	if docker == nil {
		docker = platform.NewDocker(nil)
	}
	return &Validator{Docker: docker}
}

// Validate checks that isoPath is a regular hybrid ARM64 image whose manifest,
// live and installed kernels, initramfs images, device trees, and GRUB paths
// agree. It returns accumulated evidence alongside an error on any failure.
func (v *Validator) Validate(ctx context.Context, isoPath string) (imagecontract.ValidationReport, error) {
	absolute, err := filepath.Abs(isoPath)
	if err != nil {
		return imagecontract.ValidationReport{}, err
	}
	info, err := os.Stat(absolute)
	if err != nil {
		return imagecontract.ValidationReport{}, fmt.Errorf("stat ISO: %w", err)
	}
	if !info.Mode().IsRegular() {
		return imagecontract.ValidationReport{}, fmt.Errorf("ISO path %q is not a regular file", absolute)
	}
	digest, err := artifact.HashFile(absolute)
	if err != nil {
		return imagecontract.ValidationReport{}, err
	}
	report := imagecontract.ValidationReport{
		Path: absolute, SHA256: digest, Size: info.Size(), Layout: "hybrid-iso", Adapter: AdapterID,
	}
	addCheck := func(name string, passed bool, details string) {
		report.Checks = append(report.Checks, imagecontract.ValidationCheck{Name: name, Passed: passed, Details: details})
	}
	if err := v.Docker.Check(ctx); err != nil {
		return report, err
	}
	toolsImage, err := v.Docker.EnsureToolsImage(ctx)
	if err != nil {
		return report, err
	}
	workspace, err := os.MkdirTemp(filepath.Dir(absolute), ".linux-armer-validate-")
	if err != nil {
		return report, err
	}
	defer os.RemoveAll(workspace)
	if err := stageFile(absolute, filepath.Join(workspace, "image.iso")); err != nil {
		return report, err
	}

	systemArea, systemErr := v.Docker.CaptureInWorkspace(ctx, toolsImage, workspace,
		"xorriso", "-indev", "/work/image.iso", "-report_system_area", "plain")
	if systemErr != nil {
		addCheck("hybrid-system-area", false, systemErr.Error())
	} else {
		details := string(systemArea)
		_, offsetErr := appendedESPOffset(details)
		passed := strings.Contains(details, "GPT") && offsetErr == nil
		checkDetails := firstMatchingLine(details, "System area summary")
		if offsetErr != nil {
			checkDetails = offsetErr.Error()
		}
		addCheck("hybrid-system-area", passed, checkDetails)
	}
	elTorito, elToritoErr := v.Docker.CaptureInWorkspace(ctx, toolsImage, workspace,
		"xorriso", "-indev", "/work/image.iso", "-report_el_torito", "plain")
	if elToritoErr != nil {
		addCheck("arm64-efi-boot-catalog", false, elToritoErr.Error())
	} else {
		details := string(elTorito)
		passed := strings.Contains(strings.ToLower(details), "uefi") || strings.Contains(strings.ToLower(details), "efi")
		addCheck("arm64-efi-boot-catalog", passed, strings.TrimSpace(details))
	}

	extractErr := v.Docker.RunInWorkspace(ctx, toolsImage, workspace,
		"xorriso", "-osirrox", "on", "-indev", "/work/image.iso",
		"-extract", "/sp11/linux-armer-manifest.json", "/work/manifest.json",
		"-extract", "/casper/vmlinuz", "/work/vmlinuz",
		"-extract", "/casper/initrd", "/work/initrd",
		"-extract", "/casper/minimal.squashfs", "/work/minimal.squashfs",
		"-extract", "/sp11/dtb/x1e80100-microsoft-denali-oled.dtb", "/work/x1e.dtb",
		"-extract", "/sp11/dtb/x1p64100-microsoft-denali.dtb", "/work/x1p.dtb",
		"-extract", "/EFI/boot/bootaa64.efi", "/work/iso-bootaa64.efi",
		"-extract", "/EFI/boot/grubaa64.efi", "/work/iso-grubaa64.efi",
		"-extract", "/boot/grub/grub.cfg", "/work/grub.cfg")
	if extractErr != nil {
		addCheck("required-iso-members", false, extractErr.Error())
		report.Valid = false
		return report, fmt.Errorf("ISO validation failed: required members cannot be extracted")
	}
	addCheck("required-iso-members", true, "kernel, initramfs, live root, paired DTBs, manifest, and GRUB files are present")

	manifestBytes, err := os.ReadFile(filepath.Join(workspace, "manifest.json"))
	if err != nil {
		return report, err
	}
	var manifest imagecontract.Manifest
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		addCheck("embedded-manifest", false, err.Error())
		return report, fmt.Errorf("decode embedded manifest: %w", err)
	}
	report.KernelABI = manifest.KernelBundle.ABI
	for _, dtb := range manifest.KernelBundle.DeviceTrees {
		report.DeviceTrees = append(report.DeviceTrees, dtb.Device)
	}
	abiSafe := safeKernelABI(manifest.KernelBundle.ABI)
	manifestOK := manifest.SchemaVersion == imagecontract.ManifestSchemaVersion &&
		manifest.Adapter == AdapterID &&
		manifest.KernelBundle.SchemaVersion == kernel.BundleSchemaVersion &&
		abiSafe
	addCheck("embedded-manifest", manifestOK, fmt.Sprintf("schema=%d adapter=%s abi=%s", manifest.SchemaVersion, manifest.Adapter, manifest.KernelBundle.ABI))
	if !abiSafe {
		report.Valid = false
		return report, errors.New("ISO validation failed: embedded kernel ABI is not a safe path component")
	}

	for _, expected := range []struct {
		name   string
		path   string
		record imagecontract.ArtifactRecord
	}{
		{"live-kernel-digest", "vmlinuz", manifest.BootArtifacts.Kernel},
		{"live-initramfs-digest", "initrd", manifest.BootArtifacts.Initrd},
		{"x1e-dtb-digest", "x1e.dtb", findArtifact(manifest.BootArtifacts.DTBs, "x1e80100-microsoft-denali-oled.dtb")},
		{"x1p-dtb-digest", "x1p.dtb", findArtifact(manifest.BootArtifacts.DTBs, "x1p64100-microsoft-denali.dtb")},
	} {
		actual, hashErr := artifact.HashFile(filepath.Join(workspace, expected.path))
		passed := hashErr == nil && expected.record.SHA256 != "" && actual == expected.record.SHA256
		details := fmt.Sprintf("expected=%s actual=%s", expected.record.SHA256, actual)
		if hashErr != nil {
			details = hashErr.Error()
		}
		addCheck(expected.name, passed, details)
	}

	initrdListing, initrdErr := v.Docker.CaptureInWorkspace(ctx, toolsImage, workspace, "lsinitramfs", "/work/initrd")
	if initrdErr != nil {
		addCheck("matching-initramfs-modules", false, initrdErr.Error())
		addCheck("casper-live-initramfs", false, initrdErr.Error())
	} else {
		listing := string(initrdListing)
		needle := "usr/lib/modules/" + manifest.KernelBundle.ABI + "/"
		passed := strings.Contains(listing, needle)
		addCheck("matching-initramfs-modules", passed, "expected "+needle)
		casperPassed := strings.Contains(listing, "scripts/casper") && strings.Contains(listing, "scripts/casper-bottom/")
		addCheck("casper-live-initramfs", casperPassed, "expected Casper boot and live-session scripts")
	}

	moduleProbe := "usr/lib/modules/" + manifest.KernelBundle.ABI + "/modules.dep"
	moduleErr := v.Docker.RunInWorkspace(ctx, toolsImage, workspace,
		"unsquashfs", "-no-xattrs", "-no-progress", "-d", "/work/module-probe", "/work/minimal.squashfs", moduleProbe)
	_, statErr := os.Stat(filepath.Join(workspace, "module-probe", filepath.FromSlash(moduleProbe)))
	addCheck("live-root-kernel-modules", moduleErr == nil && statErr == nil, moduleProbe)
	report.Checks = append(report.Checks, v.validateInstalledSystemSupport(ctx, toolsImage, workspace, manifest)...)

	for _, dtb := range []string{"x1e.dtb", "x1p.dtb"} {
		fileOutput, fileErr := v.Docker.CaptureInWorkspace(ctx, toolsImage, workspace, "file", "/work/"+dtb)
		passed := fileErr == nil && strings.Contains(string(fileOutput), "Device Tree Blob")
		details := strings.TrimSpace(string(fileOutput))
		if fileErr != nil {
			details = fileErr.Error()
		}
		addCheck("device-tree-format-"+strings.TrimSuffix(dtb, ".dtb"), passed, details)
	}

	grubBytes, err := os.ReadFile(filepath.Join(workspace, "grub.cfg"))
	if err != nil {
		return report, err
	}
	grubText := string(grubBytes)
	grubPassed := strings.Contains(grubText, "devicetree /sp11/dtb/x1e80100-microsoft-denali-oled.dtb") &&
		strings.Contains(grubText, "devicetree /sp11/dtb/x1p64100-microsoft-denali.dtb") &&
		strings.Contains(grubText, "modprobe.blacklist=qcom_q6v5_pas") &&
		strings.Contains(grubText, "soundwire_qcom.sp11_feedback_active_offset2_zero=1")
	addCheck("surface-grub-menu", grubPassed, "X1E/X1P DTBs, the audio argument, and USB-safe live entries")
	selfLocationPassed := strings.Contains(grubText, "insmod part_gpt") &&
		strings.Contains(grubText, "insmod iso9660") &&
		strings.Contains(grubText, "insmod search") &&
		strings.Contains(grubText, "insmod search_fs_file") &&
		strings.Contains(grubText, "search --no-floppy --file --set=iso_root /casper/vmlinuz") &&
		strings.Contains(grubText, "set root=$iso_root")
	addCheck("grub-iso-self-location", selfLocationPassed, "partition, ISO 9660, and file-search modules select the ISO containing /casper/vmlinuz")

	directISO, directErr := sameDigest(filepath.Join(workspace, "iso-bootaa64.efi"), filepath.Join(workspace, "iso-grubaa64.efi"))
	addCheck("direct-grub-iso-path", directErr == nil && directISO, "EFI/boot/bootaa64.efi matches grubaa64.efi")
	if systemErr == nil {
		offset, offsetErr := appendedESPOffset(string(systemArea))
		if offsetErr != nil {
			addCheck("direct-grub-appended-esp", false, offsetErr.Error())
		} else {
			spec := fmt.Sprintf("/work/image.iso@@%d", offset)
			copyErr := v.Docker.RunInWorkspace(ctx, toolsImage, workspace,
				"mcopy", "-o", "-i", spec, "::/EFI/BOOT/BOOTAA64.EFI", "/work/esp-bootaa64.efi")
			same, compareErr := sameDigest(filepath.Join(workspace, "esp-bootaa64.efi"), filepath.Join(workspace, "iso-grubaa64.efi"))
			passed := copyErr == nil && compareErr == nil && same
			details := "appended ESP BOOTAA64.EFI matches direct GRUB"
			if copyErr != nil {
				details = copyErr.Error()
			} else if compareErr != nil {
				details = compareErr.Error()
			}
			addCheck("direct-grub-appended-esp", passed, details)
			listing, listingErr := v.Docker.CaptureInWorkspace(ctx, toolsImage, workspace,
				"mdir", "-b", "-i", spec, "::/EFI/BOOT")
			noRedundantGRUB := listingErr == nil && !strings.Contains(strings.ToUpper(string(listing)), "GRUBAA64.EFI")
			listingDetails := "redundant GRUBAA64.EFI was removed before installing direct GRUB"
			if listingErr != nil {
				listingDetails = listingErr.Error()
			}
			addCheck("appended-esp-space-reclaimed", noRedundantGRUB, listingDetails)
		}
	}

	report.Valid = !slices.ContainsFunc(report.Checks, func(check imagecontract.ValidationCheck) bool { return !check.Passed })
	if !report.Valid {
		return report, errors.New("ISO validation failed")
	}
	return report, nil
}

// validateInstalledSystemSupport extracts and checks the minimal root assets
// that Ubuntu's installer is expected to copy into the target filesystem.
func (v *Validator) validateInstalledSystemSupport(ctx context.Context, toolsImage, workspace string, manifest imagecontract.Manifest) []imagecontract.ValidationCheck {
	checks := make([]imagecontract.ValidationCheck, 0, 7)
	addCheck := func(name string, passed bool, details string) {
		checks = append(checks, imagecontract.ValidationCheck{Name: name, Passed: passed, Details: details})
	}
	abi := manifest.KernelBundle.ABI
	paths := installedSupportPaths(abi)
	arguments := []string{
		"unsquashfs", "-no-xattrs", "-no-progress", "-d", "/work/installed-root", "/work/minimal.squashfs",
	}
	arguments = append(arguments, paths...)
	if err := v.Docker.RunInWorkspace(ctx, toolsImage, workspace, arguments...); err != nil {
		addCheck("installed-system-support-members", false, err.Error())
		return checks
	}
	addCheck("installed-system-support-members", true, "dpkg records, installed initramfs, paired DTBs, GRUB configuration, and kernel hooks are present")

	root := filepath.Join(workspace, "installed-root")
	statusBytes, statusErr := os.ReadFile(filepath.Join(root, "var/lib/dpkg/status"))
	packagesInstalled := statusErr == nil
	for _, packageName := range installedPackageNames(abi) {
		packagesInstalled = packagesInstalled && installedPackageStatus(string(statusBytes), packageName, manifest.KernelBundle.Version)
		if info, err := os.Stat(filepath.Join(root, "var/lib/dpkg/info", packageName+".list")); err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			packagesInstalled = false
		}
	}
	packageDetails := "exact ARM64 image and modules packages are registered as installed"
	if statusErr != nil {
		packageDetails = statusErr.Error()
	}
	addCheck("installed-system-kernel-packages", packagesInstalled, packageDetails)
	installedKernelDigest, installedKernelErr := artifact.HashFile(filepath.Join(root, "boot", "vmlinuz-"+abi))
	installedKernelPassed := installedKernelErr == nil &&
		manifest.BootArtifacts.Kernel.SHA256 != "" &&
		installedKernelDigest == manifest.BootArtifacts.Kernel.SHA256
	installedKernelDetails := fmt.Sprintf("expected=%s actual=%s", manifest.BootArtifacts.Kernel.SHA256, installedKernelDigest)
	if installedKernelErr != nil {
		installedKernelDetails = installedKernelErr.Error()
	}
	addCheck("installed-system-kernel-digest", installedKernelPassed, installedKernelDetails)

	installedInitrd := filepath.Join(root, "boot", "initrd.img-"+abi)
	initrdListing, initrdErr := v.Docker.CaptureInWorkspace(ctx, toolsImage, workspace,
		"lsinitramfs", "/work/installed-root/boot/initrd.img-"+abi)
	initrdText := string(initrdListing)
	installedInitrdPassed := initrdErr == nil &&
		strings.Contains(initrdText, "usr/lib/modules/"+abi+"/") &&
		!strings.Contains(initrdText, "scripts/casper")
	initrdDetails := "non-Casper initramfs contains modules for " + abi
	if initrdErr != nil {
		initrdDetails = initrdErr.Error()
	} else if info, err := os.Stat(installedInitrd); err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
		installedInitrdPassed = false
		if err != nil {
			initrdDetails = err.Error()
		} else {
			initrdDetails = "installed initramfs is empty"
		}
	}
	addCheck("installed-system-initramfs", installedInitrdPassed, initrdDetails)

	dtbPassed := true
	for _, name := range []string{"x1e80100-microsoft-denali-oled.dtb", "x1p64100-microsoft-denali.dtb"} {
		record := findArtifact(manifest.BootArtifacts.DTBs, name)
		for _, path := range []string{
			filepath.Join(root, "boot", "dtbs", abi, "qcom", name),
			filepath.Join(root, "usr", "lib", "linux-armer", "sp11", "dtb", name),
		} {
			actual, err := artifact.HashFile(path)
			if err != nil || record.SHA256 == "" || actual != record.SHA256 {
				dtbPassed = false
			}
		}
	}
	seedABI, seedABIErr := os.ReadFile(filepath.Join(root, "usr", "lib", "linux-armer", "sp11", "kernel-abi"))
	dtbPassed = dtbPassed && seedABIErr == nil && strings.TrimSpace(string(seedABI)) == abi
	addCheck("installed-system-device-trees", dtbPassed, "versioned and refresh-seed X1E/X1P DTBs match the exact kernel ABI")

	grubDefaults, defaultsErr := os.ReadFile(filepath.Join(root, "etc/default/grub.d/99-surface-pro-11.cfg"))
	grubGenerator, generatorErr := os.ReadFile(filepath.Join(root, "etc/grub.d/09_linux_armer_sp11"))
	installedGrubText := string(grubDefaults) + string(grubGenerator)
	grubSupportPassed := defaultsErr == nil && generatorErr == nil
	for _, required := range []string{
		"clk_ignore_unused",
		"pd_ignore_unused",
		"arm64.nopauth",
		"systemd.tpm2_wait=0",
		"soundwire_qcom.sp11_feedback_active_offset2_zero=1",
		"Linux Armer Surface Pro 11 X1E/OLED",
		"Linux Armer Surface Pro 11 X1P/LCD",
		"x1e80100-microsoft-denali-oled.dtb",
		"x1p64100-microsoft-denali.dtb",
	} {
		grubSupportPassed = grubSupportPassed && strings.Contains(installedGrubText, required)
	}
	grubSupportPassed = grubSupportPassed && !strings.Contains(installedGrubText, "qcom_q6v5_pas")
	addCheck("installed-system-grub-support", grubSupportPassed, "explicit X1E/X1P entries use installed-system arguments without the live USB blacklist")

	refresh, refreshErr := os.ReadFile(filepath.Join(root, "usr/local/sbin/linux-armer-refresh-sp11-boot"))
	postInstall, postInstallErr := os.ReadFile(filepath.Join(root, "etc/kernel/postinst.d/05-linux-armer-sp11-dtb"))
	postRemove, postRemoveErr := os.ReadFile(filepath.Join(root, "etc/kernel/postrm.d/05-linux-armer-sp11-dtb"))
	refreshText := string(refresh)
	refreshPassed := refreshErr == nil && postInstallErr == nil && postRemoveErr == nil &&
		strings.Contains(refreshText, "is_safe_abi") &&
		strings.Contains(refreshText, "/usr/lib/firmware/$abi/device-tree/qcom/$name") &&
		strings.Contains(refreshText, "/usr/lib/linux-image-$abi/qcom/$name") &&
		strings.Contains(string(postInstall), "/usr/local/sbin/linux-armer-refresh-sp11-boot") &&
		strings.Contains(string(postRemove), `*[!A-Za-z0-9.+_~-]*`) &&
		strings.Contains(string(postRemove), `rm -rf -- "/boot/dtbs/$abi"`) &&
		!strings.Contains(string(postRemove), "/usr/local/sbin/linux-armer-refresh-sp11-boot") &&
		!strings.Contains(refreshText+string(postInstall)+string(postRemove), "qcom_q6v5_pas")
	addCheck("installed-system-kernel-refresh", refreshPassed, "bounded hooks refresh new ABI-paired DTBs and remove only the retired ABI directory")
	return checks
}

// appendedESPOffset parses xorriso's GPT report and returns the byte offset of
// the appended EFI system partition, rejecting absent, empty, or overflowing data.
func appendedESPOffset(report string) (int64, error) {
	pattern := regexp.MustCompile(`GPT start and size\s*:\s*2\s+(\d+)\s+(\d+)`)
	matches := pattern.FindStringSubmatch(report)
	if matches == nil {
		return 0, errors.New("no appended ESP partition found")
	}
	start, err := strconv.ParseInt(matches[1], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse appended ESP start sector: %w", err)
	}
	size, err := strconv.ParseInt(matches[2], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse appended ESP size: %w", err)
	}
	if size <= 0 {
		return 0, errors.New("appended ESP has no sectors")
	}
	if start > (1<<63-1)/512 {
		return 0, errors.New("appended ESP byte offset overflows int64")
	}
	return start * 512, nil
}

// sameDigest reports whether two regular artefacts have identical SHA-256
// content without relying on their filenames or metadata.
func sameDigest(first, second string) (bool, error) {
	firstDigest, err := artifact.HashFile(first)
	if err != nil {
		return false, err
	}
	secondDigest, err := artifact.HashFile(second)
	if err != nil {
		return false, err
	}
	return firstDigest == secondDigest, nil
}

// findArtifact returns the first manifest record whose portable path ends with
// suffix, or a zero record when the required artefact is absent.
func findArtifact(records []imagecontract.ArtifactRecord, suffix string) imagecontract.ArtifactRecord {
	for _, record := range records {
		if strings.HasSuffix(record.Path, suffix) {
			return record
		}
	}
	return imagecontract.ArtifactRecord{}
}

// firstMatchingLine extracts a concise diagnostic line containing prefix and
// falls back to the trimmed full value when the report uses an unknown format.
func firstMatchingLine(value, prefix string) string {
	for _, line := range strings.Split(value, "\n") {
		if strings.Contains(line, prefix) {
			return strings.TrimSpace(line)
		}
	}
	return strings.TrimSpace(value)
}
