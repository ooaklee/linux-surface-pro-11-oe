// Package kernel models a version-bound kernel, module, initramfs, and DTB set.
package kernel

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// BundleSchemaVersion identifies the kernel-bundle manifest format emitted by
// this version of the CLI.
const BundleSchemaVersion = 1

// PackageRole identifies how a Debian package contributes to a kernel bundle.
type PackageRole string

const (
	// RoleImage identifies the bootable kernel image package.
	RoleImage PackageRole = "image"
	// RoleModules identifies the matching kernel modules package.
	RoleModules PackageRole = "modules"
	// RoleHeaders identifies ABI-specific development headers.
	RoleHeaders PackageRole = "headers"
	// RoleCommonHeaders identifies architecture-independent common headers.
	RoleCommonHeaders PackageRole = "common-headers"
)

// Package describes one immutable Debian package included in a kernel bundle.
type Package struct {
	// Role states how the package is used during installation or development.
	Role PackageRole `json:"role"`
	// Name is the Debian package filename from which ABI and version are derived.
	Name string `json:"name"`
	// Path is the local package location when the bytes have been acquired.
	Path string `json:"path,omitempty"`
	// URL is the original remote package location when applicable.
	URL string `json:"url,omitempty"`
	// SHA256 is the lowercase digest of the complete package.
	SHA256 string `json:"sha256"`
	// Size is the package length in bytes.
	Size int64 `json:"size_bytes,omitempty"`
	// Verified reports whether SHA256 matched an authoritative manifest.
	Verified bool `json:"verified"`
}

// DeviceTree identifies one supported Surface Pro 11 hardware variant and the
// DTB path expected inside the modules package.
type DeviceTree struct {
	// Device is the stable, human-readable hardware variant identifier.
	Device string `json:"device"`
	// Path is relative to the kernel's device-tree installation directory.
	Path string `json:"path"`
}

// Bundle is a validated, version-bound set of kernel packages and device trees.
type Bundle struct {
	// SchemaVersion identifies the serialised bundle contract.
	SchemaVersion int `json:"schema_version"`
	// Release is the upstream release tag or a local ABI-derived identifier.
	Release string `json:"release"`
	// Repository identifies the release source when the bundle was downloaded.
	Repository string `json:"repository,omitempty"`
	// ABI is the exact Surface kernel ABI shared by image and modules packages.
	ABI string `json:"abi"`
	// Version is the Debian package version shared by every package.
	Version string `json:"version"`
	// Architecture is the target Debian architecture.
	Architecture string `json:"architecture"`
	// Packages contains the immutable inputs sorted by filename.
	Packages []Package `json:"packages"`
	// DeviceTrees lists the DTBs that must accompany the kernel.
	DeviceTrees []DeviceTree `json:"device_trees"`
}

// packagePatterns maps supported Debian package filename forms to their bundle
// roles and captures the ABI and package version.
var packagePatterns = []struct {
	// role is assigned when pattern matches a filename.
	role PackageRole
	// pattern captures ABI and Debian version from an exact package basename.
	pattern *regexp.Regexp
}{
	{RoleModules, regexp.MustCompile(`^linux-modules-(.+)_([^_]+)_arm64\.deb$`)},
	{RoleImage, regexp.MustCompile(`^linux-image-(.+)_([^_]+)_arm64\.deb$`)},
	{RoleHeaders, regexp.MustCompile(`^linux-headers-(.+)_([^_]+)_arm64\.deb$`)},
	{RoleCommonHeaders, regexp.MustCompile(`^linux-qcom-x1e-headers-(.+)_([^_]+)_all\.deb$`)},
}

// NewBundle derives and validates the ABI/version from Debian package filenames.
func NewBundle(release, repository string, packages []Package) (Bundle, error) {
	bundle := Bundle{
		SchemaVersion: BundleSchemaVersion,
		Release:       release,
		Repository:    repository,
		Architecture:  "arm64",
		Packages:      append([]Package(nil), packages...),
		DeviceTrees: []DeviceTree{
			{Device: "surface-pro-11-x1e-oled", Path: "qcom/x1e80100-microsoft-denali-oled.dtb"},
			{Device: "surface-pro-11-x1p-lcd", Path: "qcom/x1p64100-microsoft-denali.dtb"},
		},
	}
	var problems []error
	seen := map[PackageRole]bool{}
	for i := range bundle.Packages {
		pkg := &bundle.Packages[i]
		role, abi, version, err := ParsePackageName(pkg.Name)
		if err != nil {
			problems = append(problems, err)
			continue
		}
		if pkg.Role != "" && pkg.Role != role {
			problems = append(problems, fmt.Errorf("package %s has role %q but filename identifies %q", pkg.Name, pkg.Role, role))
			continue
		}
		pkg.Role = role
		if seen[role] {
			problems = append(problems, fmt.Errorf("duplicate %s package", role))
		}
		seen[role] = true
		if role != RoleCommonHeaders {
			if !strings.HasSuffix(abi, "-qcom-x1e") {
				problems = append(problems, fmt.Errorf("package %s uses non-Surface ABI %q", pkg.Name, abi))
			}
			if bundle.ABI == "" {
				bundle.ABI = abi
			} else if bundle.ABI != abi {
				problems = append(problems, fmt.Errorf("mixed kernel ABIs %q and %q", bundle.ABI, abi))
			}
		}
		if bundle.Version == "" {
			bundle.Version = version
		} else if bundle.Version != version {
			problems = append(problems, fmt.Errorf("mixed kernel versions %q and %q", bundle.Version, version))
		}
	}
	if !seen[RoleModules] {
		problems = append(problems, errors.New("kernel bundle requires a linux-modules package"))
	}
	if !seen[RoleImage] {
		problems = append(problems, errors.New("kernel bundle requires a linux-image package"))
	}
	for _, pkg := range bundle.Packages {
		if strings.TrimSpace(pkg.SHA256) == "" {
			problems = append(problems, fmt.Errorf("package %s has no SHA-256", pkg.Name))
		}
	}
	if err := errors.Join(problems...); err != nil {
		return Bundle{}, err
	}
	sort.Slice(bundle.Packages, func(i, j int) bool { return bundle.Packages[i].Name < bundle.Packages[j].Name })
	return bundle, nil
}

// ParsePackageName derives the role, ABI, and Debian version from a supported
// kernel package filename. Common headers intentionally return an empty ABI.
func ParsePackageName(name string) (PackageRole, string, string, error) {
	base := filepath.Base(name)
	for _, candidate := range packagePatterns {
		matches := candidate.pattern.FindStringSubmatch(base)
		if matches == nil {
			continue
		}
		abi := matches[1]
		version := matches[2]
		if candidate.role == RoleCommonHeaders {
			abi = ""
		}
		return candidate.role, abi, version, nil
	}
	return "", "", "", fmt.Errorf("unsupported kernel package filename %q", base)
}

// Package returns the first package with role from an already validated bundle.
func (b Bundle) Package(role PackageRole) (Package, bool) {
	for _, pkg := range b.Packages {
		if pkg.Role == role {
			return pkg, true
		}
	}
	return Package{}, false
}

// WriteJSON writes a stable, indented bundle manifest without HTML escaping.
func (b Bundle) WriteJSON(w io.Writer) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(b)
}
