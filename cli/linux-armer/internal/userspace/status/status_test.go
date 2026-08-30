package status

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestInspectReadyRequiredSupport verifies that a complete pinned kernel,
// firmware, audio, and IPTSD fixture produces an entirely passing report.
func TestInspectReadyRequiredSupport(t *testing.T) {
	root := t.TempDir()
	mkdir(t, filepath.Join(root, "home", "fixture"))
	abi := "7.2.0-jg-0sp11v19-qcom-x1e"
	mkdir(t, filepath.Join(root, "lib/modules", abi))

	for _, requirement := range platformFirmware {
		writeRequirement(t, root, requirement)
	}
	linkPath := filepath.Join(root, filepath.FromSlash(denaliGPULink))
	mkdir(t, filepath.Dir(linkPath))
	if err := os.Symlink("../qcdxkmsuc8380.mbn", linkPath); err != nil {
		t.Fatal(err)
	}
	for _, requirement := range audioV19cFiles {
		writeRequirement(t, root, requirement)
	}
	writeFile(t, root, "etc/default/grub", 0o644, `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash `+audioFeedbackBootArgument+`"`)
	for _, requirement := range iptsdV1Files {
		writeRequirement(t, root, requirement)
	}
	maskPath := filepath.Join(root, filepath.FromSlash(genericIPTSDMask))
	mkdir(t, filepath.Dir(maskPath))
	if err := os.Symlink("/dev/null", maskPath); err != nil {
		t.Fatal(err)
	}

	inspector := New()
	inspector.hash = matchingFixtureHasher(t, root)
	inspector.inspectELF = func(_ *rootedFS, required bool) (Check, error) {
		return Check{ID: "iptsd-elf-runtime", Feature: FeatureIPTSD, State: StatePass, Required: required, Detail: "test ELF runtime is complete"}, nil
	}
	report, err := inspector.Inspect(Options{
		Root:     root,
		UserHome: "/home/fixture",
		Features: []Feature{FeatureKernel, FeatureFirmware, FeatureAudio, FeatureIPTSD},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Ready {
		t.Fatalf("expected ready report: %#v", report.Checks)
	}
	if report.KernelABI != abi {
		t.Fatalf("kernel ABI = %q, want %q", report.KernelABI, abi)
	}
	for _, check := range report.Checks {
		if check.State != StatePass {
			t.Fatalf("check %s = %s: %s", check.ID, check.State, check.Detail)
		}
	}
}

// TestPinnedAudioMismatchBlocksReadiness verifies that merely present audio
// files cannot satisfy the required coherent release without matching hashes.
func TestPinnedAudioMismatchBlocksReadiness(t *testing.T) {
	root := t.TempDir()
	for _, requirement := range audioV19cFiles {
		writeRequirement(t, root, requirement)
	}
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureAudio}})
	if err != nil {
		t.Fatal(err)
	}
	if report.Ready {
		t.Fatal("expected a pinned audio hash mismatch to block readiness")
	}
	check := findCheck(t, report, "audio-fullio-v19c")
	if check.State != StateFail || !strings.Contains(check.Detail, "SHA-256 mismatch") {
		t.Fatalf("unexpected audio check: %#v", check)
	}
}

// TestExplicitCameraProblemsBlockSelectedFeature verifies that explicitly
// requested experimental support produces an actionable failing exit status.
func TestExplicitCameraProblemsBlockSelectedFeature(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "var/lib/dpkg/status", 0o644, `Package: libcamera0.7
Status: install ok installed
Architecture: arm64
Version: 0.7.0-1ubuntu2

`)
	writeFile(t, root, cameraFiles[0].Path, 0o644, "partial camera installation")
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureCamera}})
	if err != nil {
		t.Fatal(err)
	}
	if report.Ready {
		t.Fatalf("explicit camera checks must block readiness: %#v", report.Checks)
	}
	if check := findCheck(t, report, "camera-imx681-packages"); check.State != StateFail || !check.Required {
		t.Fatalf("package check = %#v, want required failure", check)
	}
	if check := findCheck(t, report, "camera-imx681-files"); check.State != StateFail || !check.Required {
		t.Fatalf("file check = %#v, want required failure", check)
	}
}

// TestExactCameraSetPasses verifies the pinned camera package versions and files
// are recognised as one complete installation.
func TestExactCameraSetPasses(t *testing.T) {
	root := t.TempDir()
	var records strings.Builder
	for _, name := range cameraPackages {
		records.WriteString("Package: " + name + "\n")
		records.WriteString("Status: install ok installed\n")
		records.WriteString("Architecture: arm64\n")
		records.WriteString("Version: " + cameraPackageVersion + "\n\n")
	}
	writeFile(t, root, "var/lib/dpkg/status", 0o644, records.String())
	for _, requirement := range cameraFiles {
		writeRequirement(t, root, requirement)
	}
	inspector := New()
	inspector.hash = matchingFixtureHasher(t, root)
	report, err := inspector.Inspect(Options{Root: root, Features: []Feature{FeatureCamera}})
	if err != nil {
		t.Fatal(err)
	}
	if check := findCheck(t, report, "camera-imx681-packages"); check.State != StatePass {
		t.Fatalf("package check = %#v", check)
	}
	if check := findCheck(t, report, "camera-imx681-files"); check.State != StatePass {
		t.Fatalf("file check = %#v", check)
	}
}

// TestBrokenCameraPackageStateIsReported verifies that a package record which
// exists but is unpacked or half-configured is not misreported as absent.
func TestBrokenCameraPackageStateIsReported(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "var/lib/dpkg/status", 0o644, `Package: libcamera0.7
Status: install ok half-configured
Architecture: arm64
Version: `+cameraPackageVersion+`

`)
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureCamera}})
	if err != nil {
		t.Fatal(err)
	}
	check := findCheck(t, report, "camera-imx681-packages")
	if check.State != StateFail || !strings.Contains(check.Detail, "not fully installed libcamera0.7 (install ok half-configured)") {
		t.Fatalf("broken package check = %#v", check)
	}
}

// TestCameraMissingPackageDependenciesAreReported verifies conservative direct
// dependency inspection from dpkg status without invoking dpkg or a solver.
func TestCameraMissingPackageDependenciesAreReported(t *testing.T) {
	var records strings.Builder
	for index, name := range cameraPackages {
		records.WriteString("Package: " + name + "\n")
		records.WriteString("Status: install ok installed\n")
		records.WriteString("Architecture: arm64\n")
		records.WriteString("Version: " + cameraPackageVersion + "\n")
		if index == 0 {
			records.WriteString("Depends: missing-camera-runtime (>= 1), missing-a | missing-b\n")
		}
		records.WriteString("\n")
	}
	packages, err := parseDpkgStatus(strings.NewReader(records.String()))
	if err != nil {
		t.Fatal(err)
	}
	check := inspectCameraPackages(dpkgDatabase{present: true, packages: packages}, false)
	if check.State != StateWarn || !strings.Contains(check.Detail, "missing-camera-runtime") || !strings.Contains(check.Detail, "missing-a | missing-b") {
		t.Fatalf("dependency check = %#v", check)
	}
}

// TestHeldInstalledPackageIsHealthy verifies that a deliberately held package
// with an otherwise healthy dpkg state remains fully installed.
func TestHeldInstalledPackageIsHealthy(t *testing.T) {
	pkg := dpkgPackage{Status: "hold ok installed"}
	if !pkg.installed() {
		t.Fatal("held, healthy package was not recognised as installed")
	}
}

// TestCameraDependencyConstraintsFailClosed verifies that unresolved multiarch
// and build-profile relationships prevent a camera package-health pass.
func TestCameraDependencyConstraintsFailClosed(t *testing.T) {
	packages, err := parseDpkgStatus(strings.NewReader(`Package: camera-runtime
Status: install ok installed
Architecture: arm64
Version: 2.0

`))
	if err != nil {
		t.Fatal(err)
	}
	db := dpkgDatabase{present: true, packages: packages}
	for _, dependency := range []string{
		"camera-runtime:any (>= 1.0)",
		"camera-runtime (>= 1.0) <stage1>",
		"camera-runtime (>= 1.0) [linux-any]",
	} {
		health := db.dependencyHealth(dpkgPackage{Depends: dependency}, "arm64")
		if len(health.indeterminate) != 1 || len(health.missing) != 0 {
			t.Fatalf("dependency %q health = %#v", dependency, health)
		}
	}
}

// TestCameraDependencyVersionAndArchitectureProof verifies Debian version
// ordering and concrete architecture constraints without invoking dpkg.
func TestCameraDependencyVersionAndArchitectureProof(t *testing.T) {
	packages, err := parseDpkgStatus(strings.NewReader(`Package: camera-runtime
Status: install ok installed
Architecture: arm64
Multi-Arch: allowed
Version: 2:1.0~rc2-3

`))
	if err != nil {
		t.Fatal(err)
	}
	db := dpkgDatabase{present: true, packages: packages}
	tests := []struct {
		dependency    string
		wantMissing   bool
		wantUncertain bool
	}{
		{dependency: "camera-runtime:arm64 (>= 2:1.0~rc1-1)"},
		{dependency: "camera-runtime:any (= 2:1.0~rc2-3)"},
		{dependency: "camera-runtime (>> 2:1.0-1)", wantMissing: true},
		{dependency: "camera-runtime [amd64]"},
	}
	for _, test := range tests {
		health := db.dependencyHealth(dpkgPackage{Depends: test.dependency}, "arm64")
		if got := len(health.missing) != 0; got != test.wantMissing {
			t.Errorf("dependency %q missing = %t, want %t (%#v)", test.dependency, got, test.wantMissing, health)
		}
		if got := len(health.indeterminate) != 0; got != test.wantUncertain {
			t.Errorf("dependency %q indeterminate = %t, want %t (%#v)", test.dependency, got, test.wantUncertain, health)
		}
	}
}

// TestCameraDependencyAlternativesRespectArchitecture verifies that removing
// one inapplicable branch cannot conceal another applicable missing dependency.
func TestCameraDependencyAlternativesRespectArchitecture(t *testing.T) {
	db := dpkgDatabase{present: true, packages: make(map[string][]dpkgPackage)}
	tests := []struct {
		dependency  string
		wantMissing bool
	}{
		{dependency: "ignored-runtime [amd64] | missing-runtime [arm64]", wantMissing: true},
		{dependency: "missing-runtime [arm64] | ignored-runtime [amd64]", wantMissing: true},
		{dependency: "ignored-one [amd64] | ignored-two [ppc64el]"},
	}
	for _, test := range tests {
		health := db.dependencyHealth(dpkgPackage{Depends: test.dependency}, "arm64")
		if got := len(health.missing) != 0; got != test.wantMissing {
			t.Errorf("dependency %q missing = %t, want %t (%#v)", test.dependency, got, test.wantMissing, health)
		}
		if len(health.indeterminate) != 0 {
			t.Errorf("dependency %q was unexpectedly indeterminate: %#v", test.dependency, health)
		}
	}
}

// TestCompareDebianVersions covers epochs, revisions, numeric runs, and dpkg's
// special pre-release tilde ordering.
func TestCompareDebianVersions(t *testing.T) {
	tests := []struct {
		left  string
		right string
		want  int
	}{
		{left: "1.0~rc1", right: "1.0", want: -1},
		{left: "1:1.0", right: "2.0", want: 1},
		{left: "1.0-2", right: "1.0-1", want: 1},
		{left: "1.0", right: "1.0-0", want: 0},
		{left: "1.010", right: "1.10", want: 0},
	}
	for _, test := range tests {
		got, err := compareDebianVersions(test.left, test.right)
		if err != nil {
			t.Fatalf("compareDebianVersions(%q, %q): %v", test.left, test.right, err)
		}
		if got != test.want {
			t.Errorf("compareDebianVersions(%q, %q) = %d, want %d", test.left, test.right, got, test.want)
		}
	}
	for _, invalid := range []string{"", "version-without-leading-digit", "1.0?invalid", "1.0-1_invalid"} {
		if _, err := compareDebianVersions(invalid, "1.0"); err == nil {
			t.Errorf("compareDebianVersions(%q, %q) accepted an invalid version", invalid, "1.0")
		}
	}
}

// TestPinnedFileHashingIsSizeBound verifies oversized pinned content is rejected
// before hashing and that the hasher still enforces its own read ceiling.
func TestPinnedFileHashingIsSizeBound(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "pinned.bin", 0o644, "12345")
	fs, err := newRootedFS(root)
	if err != nil {
		t.Fatal(err)
	}
	called := false
	inspector := New()
	inspector.hash = func(_ string, _ int64) (string, error) {
		called = true
		return "", nil
	}
	ok, issue, err := inspector.checkFile(fs, fileRequirement{Path: "pinned.bin", SHA256: strings.Repeat("0", 64), MaximumSize: 4})
	if err != nil {
		t.Fatal(err)
	}
	if ok || called || !strings.Contains(issue, "oversized") {
		t.Fatalf("bounded pinned check = ok %t, called %t, issue %q", ok, called, issue)
	}
	if _, err := hashFile(filepath.Join(root, "pinned.bin"), 4); err == nil || !strings.Contains(err.Error(), "hash limit") {
		t.Fatalf("bounded hash error = %v", err)
	}
}

// TestDiagnosticAndObsoleteComponentsHaveTruthfulChecks verifies status-enabled
// catalogue entries expose their own IDs while never blocking readiness.
func TestDiagnosticAndObsoleteComponentsHaveTruthfulChecks(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "usr/sbin/g6-pen", 0o755, "diagnostic")
	writeFile(t, root, "etc/systemd/system/g6-pen.service", 0o644, "diagnostic service")
	enabled := filepath.Join(root, filepath.FromSlash(g6PenEnabledPath))
	mkdir(t, filepath.Dir(enabled))
	if err := os.Symlink("../g6-pen.service", enabled); err != nil {
		t.Fatal(err)
	}
	writeFile(t, root, obsoleteTouchscreenPaths[0], 0o644, "legacy touchscreen")
	abi := "6.12.0-jg-0sp11v3-qcom-x1e"
	writeFile(t, root, filepath.Join("lib/modules", abi, obsoleteTouchscreenModulePaths[2]), 0o644, "legacy module")
	writeFile(t, root, filepath.Join("etc/sp11-touchscreen/releases", abi), 0o644, "legacy release")
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureG6Pen, FeatureTouch}})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Ready {
		t.Fatalf("diagnostic and obsolete findings blocked readiness: %#v", report.Checks)
	}
	g6 := findCheck(t, report, "g6-pen-diagnostic")
	if g6.ComponentID != g6PenComponent || g6.SupportLevel != SupportDiagnosticOnly || g6.State != StateWarn || g6.Required {
		t.Fatalf("g6-pen check = %#v", g6)
	}
	touch := findCheck(t, report, "oot-touchscreen-remnants")
	if touch.ComponentID != ootTouchComponent || touch.SupportLevel != SupportObsolete || touch.State != StateWarn || touch.Required {
		t.Fatalf("obsolete touchscreen check = %#v", touch)
	}
	for _, expected := range []string{obsoleteTouchscreenPaths[0], obsoleteTouchscreenModulePaths[2], "etc/sp11-touchscreen/releases/" + abi} {
		if !strings.Contains(touch.Detail, expected) {
			t.Fatalf("touchscreen detail %q does not contain %q", touch.Detail, expected)
		}
	}
}

// TestCatalogueMaturityControlsDefaultReadiness verifies that only a
// catalogue-required component blocks an unfiltered report by default.
func TestCatalogueMaturityControlsDefaultReadiness(t *testing.T) {
	root := t.TempDir()
	for _, requirement := range platformFirmware {
		writeRequirement(t, root, requirement)
	}
	linkPath := filepath.Join(root, filepath.FromSlash(denaliGPULink))
	mkdir(t, filepath.Dir(linkPath))
	if err := os.Symlink("../qcdxkmsuc8380.mbn", linkPath); err != nil {
		t.Fatal(err)
	}
	report, err := Inspect(Options{Root: root})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Ready {
		t.Fatalf("optional component findings blocked default readiness: %#v", report.Checks)
	}
	for _, componentID := range []string{audioComponent, iptsdComponent, cameraComponent} {
		found := false
		for _, check := range report.Checks {
			if check.ComponentID != componentID {
				continue
			}
			found = true
			if check.Required {
				t.Fatalf("default check for %s is unexpectedly required: %#v", componentID, check)
			}
		}
		if !found {
			t.Fatalf("no check reported component %s", componentID)
		}
	}
}

// TestSupportLevelReadinessPolicy verifies explicit selection semantics for
// every catalogue maturity, including non-blocking diagnostic and obsolete data.
func TestSupportLevelReadinessPolicy(t *testing.T) {
	tests := []struct {
		level    SupportLevel
		explicit bool
		want     bool
	}{
		{level: SupportRequired, explicit: false, want: true},
		{level: SupportRequired, explicit: true, want: true},
		{level: SupportSupported, explicit: false, want: false},
		{level: SupportSupported, explicit: true, want: true},
		{level: SupportExperimental, explicit: false, want: false},
		{level: SupportExperimental, explicit: true, want: true},
		{level: SupportDiagnosticOnly, explicit: false, want: false},
		{level: SupportDiagnosticOnly, explicit: true, want: false},
		{level: SupportObsolete, explicit: false, want: false},
		{level: SupportObsolete, explicit: true, want: false},
	}
	for _, test := range tests {
		if got := supportLevelBlocksReadiness(test.level, test.explicit); got != test.want {
			t.Errorf("supportLevelBlocksReadiness(%q, %t) = %t, want %t", test.level, test.explicit, got, test.want)
		}
	}
}

// TestKernelCompatibilityBoundaries verifies the minimum generations for audio,
// camera, and IPTSD and confirms FullIO audio remains valid with sp11v19.
func TestKernelCompatibilityBoundaries(t *testing.T) {
	root := t.TempDir()
	for _, abi := range []string{
		"6.12.0-jg-0sp11v11-qcom-x1e",
		"7.2.0-jg-0sp11v19-qcom-x1e",
	} {
		mkdir(t, filepath.Join(root, "lib/modules", abi))
	}
	tests := []struct {
		name      string
		feature   Feature
		abi       string
		component string
		want      State
	}{
		{name: "audio rejects v11", feature: FeatureAudio, abi: "6.12.0-jg-0sp11v11-qcom-x1e", component: audioComponent, want: StateFail},
		{name: "audio accepts v19", feature: FeatureAudio, abi: "7.2.0-jg-0sp11v19-qcom-x1e", component: audioComponent, want: StatePass},
		{name: "camera accepts v19", feature: FeatureCamera, abi: "7.2.0-jg-0sp11v19-qcom-x1e", component: cameraComponent, want: StatePass},
		{name: "iptsd accepts v19", feature: FeatureIPTSD, abi: "7.2.0-jg-0sp11v19-qcom-x1e", component: iptsdComponent, want: StatePass},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			report, err := Inspect(Options{Root: root, KernelABI: test.abi, Features: []Feature{test.feature}})
			if err != nil {
				t.Fatal(err)
			}
			check := findCheck(t, report, "kernel-compatibility-"+test.component)
			if check.State != test.want || check.ComponentID != test.component || check.SupportLevel == "" {
				t.Fatalf("compatibility check = %#v", check)
			}
		})
	}
}

// TestAudioBootArgumentIsIndependentOfFileIdentity verifies that a coherent
// FullIO file set is still unready until the persistent kernel argument exists.
func TestAudioBootArgumentIsIndependentOfFileIdentity(t *testing.T) {
	root := t.TempDir()
	abi := "7.2.0-jg-0sp11v19-qcom-x1e"
	mkdir(t, filepath.Join(root, "lib/modules", abi))
	for _, requirement := range audioV19cFiles {
		writeRequirement(t, root, requirement)
	}
	inspector := New()
	inspector.hash = matchingFixtureHasher(t, root)
	report, err := inspector.Inspect(Options{Root: root, KernelABI: abi, Features: []Feature{FeatureAudio}})
	if err != nil {
		t.Fatal(err)
	}
	if check := findCheck(t, report, "audio-fullio-v19c"); check.State != StatePass {
		t.Fatalf("file identity check = %#v", check)
	}
	if check := findCheck(t, report, "audio-fullio-boot-argument"); check.State != StateFail || !strings.Contains(check.Detail, audioFeedbackBootArgument) {
		t.Fatalf("boot argument check = %#v", check)
	}
	writeFile(t, root, "etc/default/grub.d/60-sp11-audio.cfg", 0o644, `GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT `+audioFeedbackBootArgument+`"`)
	report, err = inspector.Inspect(Options{Root: root, KernelABI: abi, Features: []Feature{FeatureAudio}})
	if err != nil {
		t.Fatal(err)
	}
	if check := findCheck(t, report, "audio-fullio-boot-argument"); check.State != StatePass {
		t.Fatalf("boot argument check after configuration = %#v", check)
	}
}

// TestAudioBootArgumentRejectsCommentsAndWrongValues verifies that only an exact
// argument on a recognised GRUB command-line setting satisfies the check.
func TestAudioBootArgumentRejectsCommentsAndWrongValues(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "etc/default/grub", 0o644, "# GRUB_CMDLINE_LINUX=\""+audioFeedbackBootArgument+"\"\nGRUB_CMDLINE_LINUX_DEFAULT=\"quiet "+audioFeedbackBootPrefix+"0\"\n")
	fs, err := newRootedFS(root)
	if err != nil {
		t.Fatal(err)
	}
	check, err := inspectAudioBootArgument(fs, true)
	if err != nil {
		t.Fatal(err)
	}
	if check.State != StateFail || !strings.Contains(check.Detail, "different value") {
		t.Fatalf("boot argument check = %#v", check)
	}
}

// TestKernelABISelectionUsesNaturalVersionOrder verifies that automatic kernel
// selection compares numeric version segments instead of lexical strings.
func TestKernelABISelectionUsesNaturalVersionOrder(t *testing.T) {
	root := t.TempDir()
	for _, abi := range []string{
		"7.9.0-jg-0sp11v2-qcom-x1e",
		"7.10.0-jg-0sp11v1-qcom-x1e",
	} {
		mkdir(t, filepath.Join(root, "lib/modules", abi))
	}
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureKernel}})
	if err != nil {
		t.Fatal(err)
	}
	if report.KernelABI != "7.10.0-jg-0sp11v1-qcom-x1e" {
		t.Fatalf("selected %q", report.KernelABI)
	}
	check := findCheck(t, report, "kernel-abi")
	if check.State != StateWarn || !report.Ready {
		t.Fatalf("unexpected multi-kernel result: %#v", check)
	}
}

// TestExplicitKernelABIIsValidated verifies that an explicit ABI cannot contain
// traversal components or masquerade as an unrelated kernel.
func TestExplicitKernelABIIsValidated(t *testing.T) {
	root := t.TempDir()
	_, err := Inspect(Options{
		Root:      root,
		KernelABI: "../../host-qcom-x1e",
		Features:  []Feature{FeatureKernel},
	})
	if err == nil || !strings.Contains(err.Error(), "invalid Surface kernel ABI") {
		t.Fatalf("expected ABI validation error, got %v", err)
	}
}

// TestAmbiguousKernelGenerationIsRejected verifies that multiple sp11vN markers
// cannot be selected or interpreted as one compatibility generation.
func TestAmbiguousKernelGenerationIsRejected(t *testing.T) {
	root := t.TempDir()
	abi := "7.2.0-sp11v12-sp11v19-qcom-x1e"
	mkdir(t, filepath.Join(root, "lib/modules", abi))
	_, err := Inspect(Options{Root: root, KernelABI: abi, Features: []Feature{FeatureKernel}})
	if err == nil || !strings.Contains(err.Error(), "exactly one bounded sp11vN") {
		t.Fatalf("expected ambiguous generation error, got %v", err)
	}
	if _, valid := parseSP11Generation(abi); valid {
		t.Fatalf("parseSP11Generation(%q) accepted multiple markers", abi)
	}
}

// TestParentSymlinkCannotEscapeTargetRoot verifies that status inspection refuses
// a target-root parent symlink that resolves onto the host filesystem.
func TestParentSymlinkCannotEscapeTargetRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.Symlink("../../outside", filepath.Join(root, "lib")); err != nil {
		t.Fatal(err)
	}
	_, err := Inspect(Options{Root: root, Features: []Feature{FeatureKernel}})
	if err == nil || !strings.Contains(err.Error(), "escapes root") {
		t.Fatalf("expected containment error, got %v", err)
	}
}

// TestAbsoluteSymlinkIsResolvedInsideTargetRoot verifies that absolute links in
// an inspected installation use chroot semantics rather than host semantics.
func TestAbsoluteSymlinkIsResolvedInsideTargetRoot(t *testing.T) {
	root := t.TempDir()
	abi := "7.2.0-jg-0sp11v19-qcom-x1e"
	mkdir(t, filepath.Join(root, "usr/lib/modules", abi))
	if err := os.Symlink("/usr/lib", filepath.Join(root, "lib")); err != nil {
		t.Fatal(err)
	}
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureKernel}})
	if err != nil {
		t.Fatal(err)
	}
	if report.KernelABI != abi || !report.Ready {
		t.Fatalf("unexpected report: %#v", report)
	}
}

// TestLegacyBluetoothAddressConfigurationIsNeverReadOrReported verifies static
// coexistence reporting never leaks device-specific address data.
func TestLegacyBluetoothAddressConfigurationIsNeverReadOrReported(t *testing.T) {
	root := t.TempDir()
	secret := "12:34:56:78:9A:BC"
	for _, logical := range legacyBluetoothPaths {
		content := "fixture"
		if logical == "etc/default/sp11-bluetooth-mac" {
			content = `SP11_BLUETOOTH_MAC="` + secret + `"`
		}
		writeFile(t, root, logical, 0o644, content)
	}
	report, err := Inspect(Options{Root: root, Features: []Feature{FeatureBluetooth}})
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), secret) {
		t.Fatalf("report leaked Bluetooth address: %s", encoded)
	}
	if check := findCheck(t, report, "bluetooth-native-handoff-integration"); check.State != StateSkip {
		t.Fatalf("native hand-off check = %#v", check)
	}
	if check := findCheck(t, report, "bluetooth-legacy-coexistence"); check.State != StateFail {
		t.Fatalf("legacy coexistence check = %#v", check)
	}
}

// TestLegacyAudioConflictBlocksReadiness verifies that old workaround files fail
// an otherwise complete pinned audio assessment.
func TestLegacyAudioConflictBlocksReadiness(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, legacyAudioPaths[0], 0o644, "legacy")
	inspector := New()
	inspector.hash = matchingFixtureHasher(t, root)
	for _, requirement := range audioV19cFiles {
		writeRequirement(t, root, requirement)
	}
	report, err := inspector.Inspect(Options{Root: root, Features: []Feature{FeatureAudio}})
	if err != nil {
		t.Fatal(err)
	}
	if report.Ready {
		t.Fatal("legacy conflict should block audio readiness")
	}
	if check := findCheck(t, report, "audio-legacy-conflicts"); check.State != StateFail {
		t.Fatalf("legacy check = %#v", check)
	}
}

// TestParseDpkgStatusRejectsMalformedRecord verifies that incomplete package
// database records are reported instead of being silently ignored.
func TestParseDpkgStatusRejectsMalformedRecord(t *testing.T) {
	_, err := parseDpkgStatus(strings.NewReader("Status: install ok installed\n\n"))
	if err == nil || !strings.Contains(err.Error(), "no Package") {
		t.Fatalf("expected malformed record error, got %v", err)
	}
}

// TestArchitectureAllPackageIsRecognised verifies that architecture-independent
// Debian packages satisfy checks that allow the all architecture.
func TestArchitectureAllPackageIsRecognised(t *testing.T) {
	packages, err := parseDpkgStatus(strings.NewReader(`Package: linux-firmware
Status: install ok installed
Architecture: all
Version: 20260801

`))
	if err != nil {
		t.Fatal(err)
	}
	check := inspectPackage(dpkgDatabase{present: true, packages: packages}, "linux-firmware-package", FeatureWiFi, "linux-firmware", "", false)
	if check.State != StatePass || !strings.Contains(check.Detail, "linux-firmware:all") {
		t.Fatalf("unexpected package check: %#v", check)
	}
}

// TestFeatureSelectionAndParsing verifies normalised feature parsing and proves
// that inspection can be restricted to one requested feature group.
func TestFeatureSelectionAndParsing(t *testing.T) {
	feature, err := ParseFeature(" AuDiO ")
	if err != nil || feature != FeatureAudio {
		t.Fatalf("ParseFeature = %q, %v", feature, err)
	}
	root := t.TempDir()
	report, err := Inspect(Options{Root: root, Features: []Feature{FeaturePower}})
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Checks) != 2 {
		t.Fatalf("got %d checks, want 2", len(report.Checks))
	}
	for _, check := range report.Checks {
		if check.Feature != FeaturePower {
			t.Fatalf("unexpected feature %s", check.Feature)
		}
	}
}

// matchingFixtureHasher maps known fixture paths to their pinned hashes so tests
// can exercise coherent-set logic without embedding binary release artefacts.
func matchingFixtureHasher(t *testing.T, root string) fileHasher {
	t.Helper()
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	return func(path string, _ int64) (string, error) {
		relative, err := filepath.Rel(resolvedRoot, path)
		if err != nil {
			return "", err
		}
		logical := filepath.ToSlash(relative)
		for _, requirements := range [][]fileRequirement{audioV19cFiles, iptsdV1Files, cameraFiles} {
			for _, requirement := range requirements {
				if requirement.Path == logical && requirement.SHA256 != "" {
					return requirement.SHA256, nil
				}
			}
		}
		return "", errors.New("unexpected fixture hash path " + logical)
	}
}

// writeRequirement materialises one required file with its expected executable
// mode and a deterministic placeholder body.
func writeRequirement(t *testing.T, root string, requirement fileRequirement) {
	t.Helper()
	mode := os.FileMode(0o644)
	if requirement.Executable {
		mode = 0o755
	}
	writeFile(t, root, requirement.Path, mode, "fixture for "+requirement.Path)
	if requirement.ExpectedSize > 0 {
		path := filepath.Join(root, filepath.FromSlash(requirement.Path))
		if err := os.Truncate(path, requirement.ExpectedSize); err != nil {
			t.Fatal(err)
		}
	}
}

// writeFile creates a root-relative test file and all of its parent directories.
func writeFile(t *testing.T, root, relative string, mode os.FileMode, content string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(relative))
	mkdir(t, filepath.Dir(path))
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

// mkdir creates a fixture directory tree or fails the current test immediately.
func mkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

// findCheck returns a report check by identifier or fails with the full report
// when the expected diagnostic is absent.
func findCheck(t *testing.T, report Report, id string) Check {
	t.Helper()
	for _, check := range report.Checks {
		if check.ID == id {
			return check
		}
	}
	t.Fatalf("check %q not found in %#v", id, report.Checks)
	return Check{}
}
