package kernel

import (
	"strings"
	"testing"
)

func TestNewBundleRequiresMatchingRuntimePackages(t *testing.T) {
	t.Parallel()
	packages := []Package{
		{Name: "linux-image-7.2.0-sp11-qcom-x1e_7.2.0-sp11_arm64.deb", SHA256: strings.Repeat("a", 64)},
		{Name: "linux-modules-7.2.1-sp11-qcom-x1e_7.2.1-sp11_arm64.deb", SHA256: strings.Repeat("b", 64)},
	}
	_, err := NewBundle("v1", "example/repo", packages)
	if err == nil || !strings.Contains(err.Error(), "mixed kernel") {
		t.Fatalf("expected mixed kernel error, got %v", err)
	}
}

func TestNewBundleRejectsGenericARM64Kernel(t *testing.T) {
	packages := []Package{
		{Role: RoleImage, Name: "linux-image-7.2.0-generic_7.2.0_arm64.deb", SHA256: "image"},
		{Role: RoleModules, Name: "linux-modules-7.2.0-generic_7.2.0_arm64.deb", SHA256: "modules"},
	}
	if _, err := NewBundle("test", "", packages); err == nil {
		t.Fatal("NewBundle() accepted a generic ARM64 kernel")
	}
}

func TestNewBundleParsesReleasePackageSet(t *testing.T) {
	t.Parallel()
	packages := []Package{
		{Name: "linux-image-7.2.0-jg-0sp11v19-qcom-x1e_7.2.0-jg-0sp11v19_arm64.deb", SHA256: strings.Repeat("a", 64), Verified: true},
		{Name: "linux-modules-7.2.0-jg-0sp11v19-qcom-x1e_7.2.0-jg-0sp11v19_arm64.deb", SHA256: strings.Repeat("b", 64), Verified: true},
	}
	bundle, err := NewBundle("sp11-v19", "ooaklee/linux-surface-pro-11-oe", packages)
	if err != nil {
		t.Fatal(err)
	}
	if bundle.ABI != "7.2.0-jg-0sp11v19-qcom-x1e" {
		t.Fatalf("unexpected ABI %q", bundle.ABI)
	}
}
