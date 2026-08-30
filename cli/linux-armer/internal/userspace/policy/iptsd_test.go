package policy

import (
	"strings"
	"testing"

	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
)

// TestIPTSDReleaseRejectsCatalogueStyleOverrides verifies that retaining the
// component identifier cannot change any security-relevant release identity.
func TestIPTSDReleaseRejectsCatalogueStyleOverrides(t *testing.T) {
	contract := IPTSDRelease()
	bundle := bundleForContract(contract)
	if err := contract.ValidateBundle(bundle); err != nil {
		t.Fatalf("valid compiled bundle: %v", err)
	}
	for _, testCase := range []struct {
		name    string
		mutate  func(*userspacerelease.Bundle)
		message string
	}{
		{
			name: "repository",
			mutate: func(bundle *userspacerelease.Bundle) {
				bundle.Repository = "another/publisher"
			},
			message: "repository",
		},
		{
			name: "release",
			mutate: func(bundle *userspacerelease.Bundle) {
				bundle.Release = "sp11-iptsd-v2"
			},
			message: "release",
		},
		{
			name: "filename",
			mutate: func(bundle *userspacerelease.Bundle) {
				bundle.Files[0].Name = "OTHER"
			},
			message: "unexpected file",
		},
		{
			name: "size",
			mutate: func(bundle *userspacerelease.Bundle) {
				bundle.Files[0].Size++
			},
			message: "immutable release metadata",
		},
		{
			name: "digest",
			mutate: func(bundle *userspacerelease.Bundle) {
				bundle.Files[0].SHA256 = strings.Repeat("0", 64)
			},
			message: "immutable release metadata",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			candidate := bundleForContract(contract)
			testCase.mutate(&candidate)
			err := contract.ValidateBundle(candidate)
			if err == nil || !strings.Contains(err.Error(), testCase.message) {
				t.Fatalf("error = %v, want %q rejection", err, testCase.message)
			}
		})
	}
}

// TestIPTSDReleaseReturnsDefensiveCopy verifies that one caller cannot mutate
// the compiled contract observed by another caller.
func TestIPTSDReleaseReturnsDefensiveCopy(t *testing.T) {
	first := IPTSDRelease()
	first.Artifacts[0].Name = "changed"
	second := IPTSDRelease()
	if second.Artifacts[0].Name != "SHA256SUMS" {
		t.Fatalf("compiled contract was mutated to %q", second.Artifacts[0].Name)
	}
}

// bundleForContract projects one immutable contract into a verified in-memory
// release bundle for policy-only tests.
func bundleForContract(contract Release) userspacerelease.Bundle {
	bundle := userspacerelease.Bundle{
		Component: contract.Component, Repository: contract.Repository,
		Release: contract.Tag, Directory: "/verified/userspace",
		Files: make([]userspacerelease.File, len(contract.Artifacts)),
	}
	for index, artifact := range contract.Artifacts {
		bundle.Files[index] = userspacerelease.File{
			Name: artifact.Name, Path: "/verified/userspace/" + artifact.Name,
			SHA256: artifact.SHA256, Size: artifact.Size, Verified: true,
		}
	}
	return bundle
}
