package status

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// surfaceABI accepts a single flat modules-directory name for the supported
// Qualcomm X1E kernel flavour.
var surfaceABI = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+~-]*-qcom-x1e$`)

// fileHasher abstracts content identity calculation so inspection tests can
// verify behaviour without hashing large fixtures.
type fileHasher func(string, int64) (string, error)

// elfInspector abstracts the static IPTSD runtime assessment so coherent-set
// tests can isolate hash policy from handcrafted ELF fixtures.
type elfInspector func(*rootedFS, bool) (Check, error)

// Inspector performs static target-root inspection. It is safe to reuse for
// multiple reports.
type Inspector struct {
	// hash calculates the lowercase SHA-256 identity of pinned support files.
	hash fileHasher
	// inspectELF validates installed IPTSD architecture and runtime dependencies.
	inspectELF elfInspector
}

// New returns an inspector using SHA-256 for pinned asset identities.
func New() *Inspector {
	return &Inspector{hash: hashFile, inspectELF: inspectIPTSDELF}
}

// Inspect runs a report with the default inspector.
func Inspect(options Options) (Report, error) {
	return New().Inspect(options)
}

// Inspect reads only files below options.Root. No service, device, network, or
// subprocess operation is performed, including when Root is "/".
func (inspector *Inspector) Inspect(options Options) (Report, error) {
	if inspector == nil || inspector.hash == nil || inspector.inspectELF == nil {
		return Report{}, errors.New("userspace status inspector is not initialised")
	}
	features, err := selectedFeatures(options.Features)
	if err != nil {
		return Report{}, err
	}
	policies, err := newPolicySet(options.ComponentPolicies, len(options.Features) != 0)
	if err != nil {
		return Report{}, err
	}
	fs, err := newRootedFS(options.Root)
	if err != nil {
		return Report{}, err
	}
	userHome, err := resolveExplicitUserHome(fs, options.UserHome)
	if err != nil {
		return Report{}, err
	}
	report := Report{Root: fs.root, UserHome: userHome.logical, Ready: true}
	add := func(check Check) {
		report.Checks = append(report.Checks, check)
		if check.Required && check.State == StateFail {
			report.Ready = false
		}
	}

	compatibilitySelected := features[FeatureAudio] || features[FeatureIPTSD] || features[FeatureCamera]
	if features[FeatureKernel] || compatibilitySelected {
		check, abi, checkErr := inspectKernelABI(fs, options.KernelABI)
		if checkErr != nil {
			return Report{}, checkErr
		}
		report.KernelABI = abi
		kernelRequired := len(options.Features) != 0
		add(withRequiredState(check, kernelRequired))
	} else if strings.TrimSpace(options.KernelABI) != "" {
		if err := validateABI(options.KernelABI); err != nil {
			return Report{}, err
		}
		report.KernelABI = options.KernelABI
	}

	var dpkg dpkgDatabase
	if features[FeatureWiFi] || features[FeatureBluetooth] || features[FeatureCamera] || features[FeaturePower] {
		dpkg, err = loadDpkgDatabase(fs)
		if err != nil {
			return Report{}, err
		}
	}

	if features[FeatureFirmware] {
		required := policies.required(firmwareComponent)
		check, checkErr := inspector.checkFileSet(fs, "platform-firmware", FeatureFirmware, required, platformFirmware, false)
		if checkErr != nil {
			return Report{}, checkErr
		}
		if check.State == StateFail {
			disabled, _, disabledErr := fs.regular("lib/firmware/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn.disabled", false)
			if disabledErr == nil && disabled != "" {
				check.Detail += "; aDSP DTB is present only in USB-safe disabled form"
			}
		}
		check.Remediation = "gather the Surface firmware from a trusted local Windows installation, then enable the aDSP DTB on an installed NVMe system"
		add(policies.decorate(check, firmwareComponent))

		linkCheck, checkErr := inspectDenaliLink(fs)
		if checkErr != nil {
			return Report{}, checkErr
		}
		add(policies.decorate(withRequiredState(linkCheck, required), firmwareComponent))
	}

	if features[FeatureWiFi] {
		required := policies.required(wifiComponent)
		add(policies.decorate(inspectPackage(dpkg, "linux-firmware-package", FeatureWiFi, "linux-firmware", "", required), wifiComponent))
		check, checkErr := inspector.checkAlternativeSets(fs, "wifi-wcn7850-firmware", FeatureWiFi, required, wcn7850Firmware, false)
		if checkErr != nil {
			return Report{}, checkErr
		}
		check.Remediation = "install a current linux-firmware package containing WCN7850 hw2.0 firmware"
		add(policies.decorate(check, wifiComponent))

		board, checkErr := inspector.checkAnyFile(fs, wifiBoardData)
		if checkErr != nil {
			return Report{}, checkErr
		}
		if board {
			add(policies.decorate(Check{ID: "wifi-board-data", Feature: FeatureWiFi, State: StatePass, Detail: "conditional WCN7850 board.bin fallback is installed"}, wifiComponent))
		} else {
			add(policies.decorate(Check{ID: "wifi-board-data", Feature: FeatureWiFi, State: StateSkip, Detail: "conditional board.bin fallback is not installed; board-2.bin is preferred when it matches this device", Remediation: "only install a board.bin extracted for this device after confirming the driver requests it"}, wifiComponent))
		}
	}

	if features[FeatureBluetooth] {
		required := policies.required(bluetoothComponent)
		check, checkErr := inspector.checkAlternativeSets(fs, "bluetooth-qca-firmware", FeatureBluetooth, required, bluetoothFirmware, false)
		if checkErr != nil {
			return Report{}, checkErr
		}
		check.Remediation = "install QCA WCN7850 hmtbtfw20.tlv and hmtnv20.bin firmware"
		add(policies.decorate(check, bluetoothComponent))

		bluezPackage := inspectPackage(dpkg, "bluetooth-bluez-package", FeatureBluetooth, "bluez", "", required)
		add(policies.decorate(bluezPackage, bluetoothComponent))
		bluezFiles, checkErr := inspector.checkAlternativeSets(fs, "bluetooth-bluez-files", FeatureBluetooth, required, bluetoothBlueZFiles, true)
		if checkErr != nil {
			return Report{}, checkErr
		}
		bluezFiles.Remediation = "install BlueZ and its bluetooth.service unit"
		add(policies.decorate(bluezFiles, bluetoothComponent))

		nativeIntegration, checkErr := inspectNativeBluetoothIntegration(fs, required)
		if checkErr != nil {
			return Report{}, checkErr
		}
		add(policies.decorate(nativeIntegration, bluetoothComponent))

		legacyIntegration, checkErr := inspectLegacyBluetoothIntegration(fs, required, nativeIntegration.State != StateSkip)
		if checkErr != nil {
			return Report{}, checkErr
		}
		add(policies.decorate(legacyIntegration, bluetoothComponent))
	}

	if features[FeatureAudio] {
		required := policies.required(audioComponent)
		add(policies.inspectKernelCompatibility(audioComponent, report.KernelABI))
		check, checkErr := inspector.checkFileSet(fs, "audio-fullio-v19c", FeatureAudio, required, audioV19cFiles, false)
		if checkErr != nil {
			return Report{}, checkErr
		}
		check.Remediation = "install the complete verified sp11-audio-v19c topology and UCM asset set"
		add(policies.decorate(check, audioComponent))

		bootArgument, checkErr := inspectAudioBootArgument(fs, required)
		if checkErr != nil {
			return Report{}, checkErr
		}
		add(policies.decorate(bootArgument, audioComponent))

		legacy, checkErr := inspectConflicts(fs, "audio-legacy-conflicts", FeatureAudio, required, legacyAudioPaths)
		if checkErr != nil {
			return Report{}, checkErr
		}
		legacy.Remediation = "review linux-armer clean plan and remove recognised legacy audio workarounds through its reversible cleanup flow"
		add(policies.decorate(legacy, audioComponent))

		userLegacy, checkErr := inspectUserAudioConflicts(fs, userHome, required)
		if checkErr != nil {
			return Report{}, checkErr
		}
		userLegacy.Remediation = "pass the same explicit --user-home to linux-armer clean plan, then review its reversible per-user cleanup"
		add(policies.decorate(userLegacy, audioComponent))
	}

	if features[FeatureIPTSD] {
		required := policies.required(iptsdComponent)
		add(policies.inspectKernelCompatibility(iptsdComponent, report.KernelABI))
		check, checkErr := inspector.checkFileSet(fs, "iptsd-v1-integration", FeatureIPTSD, required, iptsdV1Files, false)
		if checkErr != nil {
			return Report{}, checkErr
		}
		check.Remediation = "install the complete verified sp11-iptsd-v1 payload and integration files"
		add(policies.decorate(check, iptsdComponent))

		elfCheck, checkErr := inspector.inspectELF(fs, required)
		if checkErr != nil {
			return Report{}, checkErr
		}
		add(policies.decorate(elfCheck, iptsdComponent))

		mask, checkErr := inspectMask(fs, required)
		if checkErr != nil {
			return Report{}, checkErr
		}
		add(policies.decorate(mask, iptsdComponent))

		conflict, checkErr := inspectG6Pen(fs, required)
		if checkErr != nil {
			return Report{}, checkErr
		}
		add(policies.decorate(conflict, iptsdComponent))
	}

	if features[FeatureG6Pen] {
		check, checkErr := inspectG6PenStatus(fs)
		if checkErr != nil {
			return Report{}, checkErr
		}
		add(policies.decorate(check, g6PenComponent))
	}

	if features[FeatureTouch] {
		check, checkErr := inspectObsoleteTouchscreen(fs)
		if checkErr != nil {
			return Report{}, checkErr
		}
		add(policies.decorate(check, ootTouchComponent))
	}

	if features[FeatureCamera] {
		required := policies.required(cameraComponent)
		add(policies.inspectKernelCompatibility(cameraComponent, report.KernelABI))
		packages := inspectCameraPackages(dpkg, required)
		add(policies.decorate(packages, cameraComponent))
		files, checkErr := inspector.checkFileSet(fs, "camera-imx681-files", FeatureCamera, required, cameraFiles, true)
		if checkErr != nil {
			return Report{}, checkErr
		}
		files.Remediation = "install all five exact sp11-imx681-libcamera-v1 packages in one transaction"
		add(policies.decorate(files, cameraComponent))
	}

	if features[FeaturePower] {
		required := policies.required(powerComponent)
		add(policies.decorate(inspectPackage(dpkg, "power-profiles-package", FeaturePower, "power-profiles-daemon", "", required), powerComponent))
		files, checkErr := inspector.checkAlternativeSets(fs, "power-profiles-files", FeaturePower, required, powerProfileFiles, true)
		if checkErr != nil {
			return Report{}, checkErr
		}
		files.Remediation = "install power-profiles-daemon to expose the kernel platform profile through the desktop"
		add(policies.decorate(files, powerComponent))
	}

	return report, nil
}

// inspectKernelABI validates an explicit ABI or deterministically selects the
// newest safe Surface modules directory, reporting ambiguous or unsafe choices.
func inspectKernelABI(fs *rootedFS, explicit string) (Check, string, error) {
	if strings.TrimSpace(explicit) != "" {
		if err := validateABI(explicit); err != nil {
			return Check{}, "", err
		}
		path, info, err := fs.lstat(filepath.Join("lib/modules", explicit))
		if missing(err) {
			return Check{ID: "kernel-abi", Feature: FeatureKernel, State: StateFail, Required: true, Detail: fmt.Sprintf("requested kernel ABI %s is not installed", explicit), Remediation: "install the matching Surface qcom-x1e kernel image and modules packages"}, explicit, nil
		}
		if err != nil {
			return Check{}, "", err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return Check{ID: "kernel-abi", Feature: FeatureKernel, State: StateFail, Required: true, Detail: fmt.Sprintf("requested kernel ABI %s does not have a regular modules directory", explicit), Remediation: "reinstall the matching Surface kernel modules package"}, explicit, nil
		}
		_ = path
		return Check{ID: "kernel-abi", Feature: FeatureKernel, State: StatePass, Required: true, Detail: "selected installed Surface kernel ABI " + explicit}, explicit, nil
	}

	modulesPath, err := fs.resolve("lib/modules", true)
	if err != nil {
		return Check{}, "", err
	}
	entries, err := os.ReadDir(modulesPath)
	if errors.Is(err, os.ErrNotExist) {
		return Check{ID: "kernel-abi", Feature: FeatureKernel, State: StateFail, Required: true, Detail: "no installed Surface qcom-x1e kernel modules were found", Remediation: "install a Surface qcom-x1e kernel image and modules package pair"}, "", nil
	}
	if err != nil {
		return Check{}, "", fmt.Errorf("read target-root kernel modules: %w", err)
	}
	candidates := make([]string, 0)
	unsafeCandidates := make([]string, 0)
	for _, entry := range entries {
		if !surfaceABI.MatchString(entry.Name()) {
			continue
		}
		if validateABI(entry.Name()) != nil {
			unsafeCandidates = append(unsafeCandidates, entry.Name())
			continue
		}
		if entry.Type()&os.ModeSymlink != 0 {
			unsafeCandidates = append(unsafeCandidates, entry.Name())
			continue
		}
		info, infoErr := entry.Info()
		if infoErr != nil {
			return Check{}, "", fmt.Errorf("inspect kernel ABI %s: %w", entry.Name(), infoErr)
		}
		if !info.IsDir() {
			unsafeCandidates = append(unsafeCandidates, entry.Name())
			continue
		}
		candidates = append(candidates, entry.Name())
	}
	sort.Slice(candidates, func(i, j int) bool { return naturalLess(candidates[i], candidates[j]) })
	sort.Strings(unsafeCandidates)
	if len(candidates) == 0 {
		detail := "no installed Surface qcom-x1e kernel modules were found"
		if len(unsafeCandidates) > 0 {
			detail += "; rejected non-directory or symbolic-link candidates: " + strings.Join(unsafeCandidates, ", ")
		}
		return Check{ID: "kernel-abi", Feature: FeatureKernel, State: StateFail, Required: true, Detail: detail, Remediation: "install a Surface qcom-x1e kernel image and modules package pair"}, "", nil
	}
	selected := candidates[len(candidates)-1]
	if len(candidates) == 1 && len(unsafeCandidates) == 0 {
		return Check{ID: "kernel-abi", Feature: FeatureKernel, State: StatePass, Required: true, Detail: "selected installed Surface kernel ABI " + selected}, selected, nil
	}
	detail := fmt.Sprintf("selected newest installed ABI %s from %s", selected, strings.Join(candidates, ", "))
	if len(unsafeCandidates) > 0 {
		detail += "; ignored unsafe candidates: " + strings.Join(unsafeCandidates, ", ")
	}
	return Check{ID: "kernel-abi", Feature: FeatureKernel, State: StateWarn, Required: true, Detail: detail, Remediation: "pass --kernel explicitly when diagnosing a non-default installed kernel"}, selected, nil
}

// validateABI requires a bounded, flat Qualcomm X1E modules-directory name.
func validateABI(abi string) error {
	if !surfaceABI.MatchString(abi) || len(abi) > 160 {
		return fmt.Errorf("invalid Surface kernel ABI %q; expected a single *-qcom-x1e directory name", abi)
	}
	if _, validGeneration := parseSP11Generation(abi); !validGeneration {
		return fmt.Errorf("invalid Surface kernel ABI %q; expected exactly one bounded sp11vN generation marker", abi)
	}
	return nil
}

// naturalLess compares version-like ABI strings numerically across digit runs so
// deterministic selection does not treat version 10 as older than version 9.
func naturalLess(left, right string) bool {
	for li, ri := 0, 0; li < len(left) && ri < len(right); {
		ldigit := left[li] >= '0' && left[li] <= '9'
		rdigit := right[ri] >= '0' && right[ri] <= '9'
		if ldigit && rdigit {
			lend, rend := li, ri
			for lend < len(left) && left[lend] >= '0' && left[lend] <= '9' {
				lend++
			}
			for rend < len(right) && right[rend] >= '0' && right[rend] <= '9' {
				rend++
			}
			lnum := strings.TrimLeft(left[li:lend], "0")
			rnum := strings.TrimLeft(right[ri:rend], "0")
			if lnum == "" {
				lnum = "0"
			}
			if rnum == "" {
				rnum = "0"
			}
			if len(lnum) != len(rnum) {
				return len(lnum) < len(rnum)
			}
			if lnum != rnum {
				return lnum < rnum
			}
			li, ri = lend, rend
			continue
		}
		if left[li] != right[ri] {
			return left[li] < right[ri]
		}
		li++
		ri++
	}
	return len(left) < len(right) || (len(left) == len(right) && left < right)
}

// checkFileSet verifies every requirement in one component contract and derives
// pass, warn, fail, or skip state from presence and requiredness.
func (inspector *Inspector) checkFileSet(fs *rootedFS, id string, feature Feature, required bool, requirements []fileRequirement, skipWhenAbsent bool) (Check, error) {
	issues := make([]string, 0)
	present := 0
	for _, requirement := range requirements {
		ok, issue, err := inspector.checkFile(fs, requirement)
		if err != nil {
			return Check{}, err
		}
		if ok {
			present++
		} else {
			issues = append(issues, issue)
		}
	}
	if len(issues) == 0 {
		return Check{ID: id, Feature: feature, State: StatePass, Required: required, Detail: fmt.Sprintf("all %d expected files are installed and valid", len(requirements))}, nil
	}
	state := StateWarn
	if required {
		state = StateFail
	} else if skipWhenAbsent && present == 0 {
		state = StateSkip
	}
	return Check{ID: id, Feature: feature, State: state, Required: required, Detail: strings.Join(issues, "; ")}, nil
}

// checkAlternativeSets requires at least one accepted file from each group,
// allowing distribution-specific locations or compression formats.
func (inspector *Inspector) checkAlternativeSets(fs *rootedFS, id string, feature Feature, required bool, sets [][]fileRequirement, skipWhenAbsent bool) (Check, error) {
	missingSets := make([]string, 0)
	present := 0
	for _, alternatives := range sets {
		found, err := inspector.checkAnyFile(fs, alternatives)
		if err != nil {
			return Check{}, err
		}
		if found {
			present++
			continue
		}
		missingSets = append(missingSets, "/"+filepath.ToSlash(alternatives[0].Path)+" (compressed variants accepted)")
	}
	if len(missingSets) == 0 {
		return Check{ID: id, Feature: feature, State: StatePass, Required: required, Detail: fmt.Sprintf("all %d expected file groups are installed", len(sets))}, nil
	}
	state := StateWarn
	if required {
		state = StateFail
	} else if skipWhenAbsent && present == 0 {
		state = StateSkip
	}
	return Check{ID: id, Feature: feature, State: state, Required: required, Detail: "missing " + strings.Join(missingSets, ", ")}, nil
}

// checkAnyFile reports whether any safe, valid file requirement in an alternative
// group is satisfied.
func (inspector *Inspector) checkAnyFile(fs *rootedFS, alternatives []fileRequirement) (bool, error) {
	for _, requirement := range alternatives {
		ok, _, err := inspector.checkFile(fs, requirement)
		if err != nil {
			return false, err
		}
		if ok {
			return true, nil
		}
	}
	return false, nil
}

// checkFile validates one target-root file's containment, type, non-empty size,
// executable mode, and optional pinned SHA-256 identity.
func (inspector *Inspector) checkFile(fs *rootedFS, requirement fileRequirement) (bool, string, error) {
	path, info, err := fs.regular(requirement.Path, requirement.AllowSymlink)
	logical := "/" + filepath.ToSlash(requirement.Path)
	if missing(err) {
		return false, "missing " + logical, nil
	}
	if err != nil {
		if strings.Contains(err.Error(), "target-root link") {
			return false, "", err
		}
		return false, "invalid " + logical, nil
	}
	if info.Size() == 0 {
		return false, "empty " + logical, nil
	}
	if requirement.Executable && info.Mode().Perm()&0o111 == 0 {
		return false, "not executable " + logical, nil
	}
	if requirement.SHA256 != "" {
		maximum := requirement.MaximumSize
		if maximum <= 0 {
			maximum = maxPinnedFileBytes
		}
		if requirement.ExpectedSize > 0 && info.Size() != requirement.ExpectedSize {
			return false, fmt.Sprintf("size mismatch %s (expected %d bytes, found %d)", logical, requirement.ExpectedSize, info.Size()), nil
		}
		if info.Size() > maximum {
			return false, fmt.Sprintf("oversized %s (maximum %d bytes, found %d)", logical, maximum, info.Size()), nil
		}
		digest, hashErr := inspector.hash(path, maximum)
		if hashErr != nil {
			return false, "", fmt.Errorf("hash target-root file %s: %w", logical, hashErr)
		}
		if digest != requirement.SHA256 {
			return false, "SHA-256 mismatch " + logical, nil
		}
	}
	return true, "", nil
}

// inspectDenaliLink requires the GPU firmware alias to be the exact relative
// link expected by the device while confirming its target stays inside the root.
func inspectDenaliLink(fs *rootedFS) (Check, error) {
	path, info, err := fs.lstat(denaliGPULink)
	if missing(err) {
		return Check{ID: "platform-firmware-denali-gpu-link", Feature: FeatureFirmware, State: StateFail, Required: true, Detail: "missing /" + denaliGPULink, Remediation: "create the Denali firmware lookup link to ../qcdxkmsuc8380.mbn"}, nil
	}
	if err != nil {
		return Check{}, err
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return Check{ID: "platform-firmware-denali-gpu-link", Feature: FeatureFirmware, State: StateFail, Required: true, Detail: "/" + denaliGPULink + " is not the expected symbolic link", Remediation: "replace it with a relative link to ../qcdxkmsuc8380.mbn"}, nil
	}
	target, err := os.Readlink(path)
	if err != nil {
		return Check{}, err
	}
	if target != "../qcdxkmsuc8380.mbn" {
		return Check{ID: "platform-firmware-denali-gpu-link", Feature: FeatureFirmware, State: StateFail, Required: true, Detail: "/" + denaliGPULink + " has an unexpected target", Remediation: "replace it with a relative link to ../qcdxkmsuc8380.mbn"}, nil
	}
	if _, err := fs.resolve(denaliGPULink, true); err != nil {
		return Check{}, err
	}
	return Check{ID: "platform-firmware-denali-gpu-link", Feature: FeatureFirmware, State: StatePass, Required: true, Detail: "Denali GPU firmware lookup link is correct"}, nil
}

// inspectPackage reports whether dpkg contains an installed package and,
// optionally, whether its exact version matches the requested companion build.
func inspectPackage(db dpkgDatabase, id string, feature Feature, name, version string, required bool) Check {
	if !db.present {
		return Check{ID: id, Feature: feature, State: StateSkip, Required: required, Detail: "dpkg status is unavailable in the selected root"}
	}
	pkg, installed := db.installed(name, "")
	if !installed {
		return Check{ID: id, Feature: feature, State: optionalState(required), Required: required, Detail: name + " is not installed"}
	}
	if version != "" && pkg.Version != version {
		return Check{ID: id, Feature: feature, State: optionalState(required), Required: required, Detail: fmt.Sprintf("%s:%s has version %s; expected %s", name, pkg.Architecture, pkg.Version, version)}
	}
	architecture := pkg.Architecture
	if architecture == "" {
		architecture = "unknown architecture"
	}
	return Check{ID: id, Feature: feature, State: StatePass, Required: required, Detail: fmt.Sprintf("%s:%s %s is installed", name, architecture, pkg.Version)}
}

// inspectConflicts detects known retired paths and returns their names in stable
// order without changing the target filesystem.
func inspectConflicts(fs *rootedFS, id string, feature Feature, required bool, paths []string) (Check, error) {
	found := make(map[string]bool)
	for _, logical := range paths {
		_, _, err := fs.lstat(logical)
		if missing(err) {
			continue
		}
		if err != nil {
			return Check{}, err
		}
		found["/"+filepath.ToSlash(logical)] = true
	}
	if len(found) == 0 {
		return Check{ID: id, Feature: feature, State: StatePass, Required: required, Detail: "no known legacy conflicts were detected"}, nil
	}
	return Check{ID: id, Feature: feature, State: optionalState(required), Required: required, Detail: "legacy conflicts detected: " + strings.Join(sortedKeys(found), ", ")}, nil
}

// inspectUserAudioConflicts checks exact per-user legacy files only beneath the
// explicitly selected target-visible home and never enumerates accounts or
// guesses a home from the process environment.
func inspectUserAudioConflicts(fs *rootedFS, userHome resolvedUserHome, required bool) (Check, error) {
	check := Check{ID: "audio-user-legacy-conflicts", Feature: FeatureAudio, Required: required}
	if userHome.logical == "" {
		check.State = StateSkip
		check.Detail = "per-user legacy audio paths were not inspected because no explicit --user-home was selected"
		return check, nil
	}
	paths := make([]string, 0, len(legacyUserAudioPaths))
	for _, relative := range legacyUserAudioPaths {
		paths = append(paths, filepath.Join(userHome.relative, filepath.FromSlash(relative)))
	}
	result, err := inspectConflicts(fs, check.ID, FeatureAudio, required, paths)
	if err != nil {
		return Check{}, err
	}
	if result.State == StatePass {
		result.Detail = "no known per-user legacy audio conflicts were detected beneath " + userHome.logical
	} else {
		result.Detail = "per-user legacy audio conflicts detected beneath " + userHome.logical + ": " + strings.TrimPrefix(result.Detail, "legacy conflicts detected: ")
	}
	return result, nil
}

// inspectMask confirms that the generic IPTSD systemd unit is masked by an exact
// symbolic link to /dev/null.
func inspectMask(fs *rootedFS, required bool) (Check, error) {
	path, info, err := fs.lstat(genericIPTSDMask)
	if missing(err) {
		return Check{ID: "iptsd-generic-service-mask", Feature: FeatureIPTSD, State: optionalState(required), Required: required, Detail: "generic iptsd@.service is not masked", Remediation: "mask the generic service so it cannot compete for the SP11 HIDRAW bridge"}, nil
	}
	if err != nil {
		return Check{}, err
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return Check{ID: "iptsd-generic-service-mask", Feature: FeatureIPTSD, State: optionalState(required), Required: required, Detail: "generic iptsd@.service mask is not a symbolic link to /dev/null", Remediation: "review the custom unit, then mask the generic iptsd service"}, nil
	}
	target, err := os.Readlink(path)
	if err != nil {
		return Check{}, err
	}
	if target != "/dev/null" {
		return Check{ID: "iptsd-generic-service-mask", Feature: FeatureIPTSD, State: optionalState(required), Required: required, Detail: "generic iptsd@.service mask has an unexpected target", Remediation: "replace the mask with a /dev/null symbolic link"}, nil
	}
	return Check{ID: "iptsd-generic-service-mask", Feature: FeatureIPTSD, State: StatePass, Required: required, Detail: "generic iptsd@.service is masked"}, nil
}

// inspectG6Pen detects enabled or installed diagnostic pen tooling that can
// contend with the supported IPTSD device owner.
func inspectG6Pen(fs *rootedFS, required bool) (Check, error) {
	_, _, enabledErr := fs.lstat(g6PenEnabledPath)
	if enabledErr == nil {
		return Check{ID: "iptsd-g6-pen-conflict", Feature: FeatureIPTSD, State: optionalState(required), Required: required, Detail: "g6-pen.service is enabled and can compete with iptsd", Remediation: "disable g6-pen.service; keep g6-pen only for controlled diagnostics"}, nil
	}
	if !missing(enabledErr) {
		return Check{}, enabledErr
	}
	found := make(map[string]bool)
	for _, logical := range g6PenPaths {
		_, _, err := fs.lstat(logical)
		if missing(err) {
			continue
		}
		if err != nil {
			return Check{}, err
		}
		found["/"+filepath.ToSlash(logical)] = true
	}
	if len(found) > 0 {
		return Check{ID: "iptsd-g6-pen-conflict", Feature: FeatureIPTSD, State: StateWarn, Required: required, Detail: "diagnostic g6-pen files are installed but not statically enabled: " + strings.Join(sortedKeys(found), ", "), Remediation: "never run g6-pen while an sp11-iptsd service owns the device"}, nil
	}
	return Check{ID: "iptsd-g6-pen-conflict", Feature: FeatureIPTSD, State: StatePass, Required: required, Detail: "no enabled g6-pen conflict was detected"}, nil
}

// inspectCameraPackages checks that the optional IMX681 support is either absent
// or installed as the complete, exact-version five-package arm64 set.
func inspectCameraPackages(db dpkgDatabase, required bool) Check {
	check := Check{ID: "camera-imx681-packages", Feature: FeatureCamera, Required: required, Detail: "dpkg status is unavailable in the selected root", State: StateSkip}
	if !db.present {
		if required {
			check.State = StateFail
		}
		return check
	}
	missingPackages := make([]string, 0)
	brokenPackages := make([]string, 0)
	wrongArchitectures := make([]string, 0)
	wrongVersions := make([]string, 0)
	missingDependencies := make([]string, 0)
	indeterminateDependencies := make([]string, 0)
	present := 0
	for _, name := range cameraPackages {
		allRecords := db.matching(name, "")
		records := db.matching(name, "arm64")
		if len(records) == 0 {
			if len(allRecords) == 0 {
				missingPackages = append(missingPackages, name)
			} else {
				architectures := make([]string, 0, len(allRecords))
				for _, record := range allRecords {
					architectures = append(architectures, record.Architecture)
				}
				wrongArchitectures = append(wrongArchitectures, name+"="+strings.Join(uniqueSortedStrings(architectures), ","))
				present++
			}
			continue
		}
		present++
		pkg, installed := db.installed(name, "arm64")
		if !installed {
			states := make([]string, 0, len(records))
			for _, record := range records {
				state := strings.TrimSpace(record.Status)
				if state == "" {
					state = "missing Status field"
				}
				states = append(states, state)
			}
			brokenPackages = append(brokenPackages, name+" ("+strings.Join(states, ", ")+")")
			continue
		}
		if pkg.Version != cameraPackageVersion {
			wrongVersions = append(wrongVersions, name+"="+pkg.Version)
		}
		dependencyStatus := db.dependencyHealth(pkg, "arm64")
		if len(dependencyStatus.missing) != 0 {
			missingDependencies = append(missingDependencies, name+" -> "+strings.Join(dependencyStatus.missing, ", "))
		}
		if len(dependencyStatus.indeterminate) != 0 {
			indeterminateDependencies = append(indeterminateDependencies, name+" -> "+strings.Join(dependencyStatus.indeterminate, ", "))
		}
	}
	if present == 0 {
		check.Detail = "the optional SP11 IMX681 libcamera package set is not installed"
		if required {
			check.State = StateFail
		}
		return check
	}
	if len(missingPackages) > 0 || len(brokenPackages) > 0 || len(wrongArchitectures) > 0 || len(wrongVersions) > 0 || len(missingDependencies) > 0 || len(indeterminateDependencies) > 0 {
		parts := make([]string, 0, 6)
		if len(missingPackages) > 0 {
			parts = append(parts, "missing "+strings.Join(missingPackages, ", "))
		}
		if len(brokenPackages) > 0 {
			parts = append(parts, "not fully installed "+strings.Join(brokenPackages, ", "))
		}
		if len(wrongArchitectures) > 0 {
			parts = append(parts, "unexpected architectures "+strings.Join(wrongArchitectures, ", "))
		}
		if len(wrongVersions) > 0 {
			parts = append(parts, "unexpected versions "+strings.Join(wrongVersions, ", "))
		}
		if len(missingDependencies) > 0 {
			parts = append(parts, "missing package dependencies "+strings.Join(missingDependencies, "; "))
		}
		if len(indeterminateDependencies) > 0 {
			parts = append(parts, "indeterminate package dependencies "+strings.Join(indeterminateDependencies, "; "))
		}
		check.State = optionalState(required)
		check.Detail = strings.Join(parts, "; ")
		check.Remediation = "install all five exact sp11-imx681-libcamera-v1 arm64 packages in one transaction"
		return check
	}
	check.State = StatePass
	check.Detail = "all five exact SP11 IMX681 libcamera packages are installed at " + cameraPackageVersion
	return check
}

// withRequiredState changes a check's readiness role and keeps warning and
// failure severity consistent with that role.
func withRequiredState(check Check, required bool) Check {
	check.Required = required
	if !required && check.State == StateFail {
		check.State = StateWarn
	}
	return check
}

// optionalState maps a missing or invalid check to failure when required and to
// a warning otherwise.
func optionalState(required bool) State {
	if required {
		return StateFail
	}
	return StateWarn
}

// hashFile streams one file into SHA-256 and returns its lowercase hexadecimal
// digest.
func hashFile(path string, maximumBytes int64) (string, error) {
	if maximumBytes < 1 {
		return "", errors.New("hash byte limit must be positive")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	written, err := io.Copy(hash, io.LimitReader(file, maximumBytes+1))
	if err != nil {
		return "", err
	}
	if written > maximumBytes {
		return "", fmt.Errorf("file exceeds %d-byte hash limit", maximumBytes)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
