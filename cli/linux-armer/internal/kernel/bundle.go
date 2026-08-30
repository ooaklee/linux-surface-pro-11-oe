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

const BundleSchemaVersion = 1

type PackageRole string

const (
	RoleImage         PackageRole = "image"
	RoleModules       PackageRole = "modules"
	RoleHeaders       PackageRole = "headers"
	RoleCommonHeaders PackageRole = "common-headers"
)

type Package struct {
	Role     PackageRole `json:"role"`
	Name     string      `json:"name"`
	Path     string      `json:"path,omitempty"`
	URL      string      `json:"url,omitempty"`
	SHA256   string      `json:"sha256"`
	Size     int64       `json:"size_bytes,omitempty"`
	Verified bool        `json:"verified"`
}

type DeviceTree struct {
	Device string `json:"device"`
	Path   string `json:"path"`
}

type Bundle struct {
	SchemaVersion int          `json:"schema_version"`
	Release       string       `json:"release"`
	Repository    string       `json:"repository,omitempty"`
	ABI           string       `json:"abi"`
	Version       string       `json:"version"`
	Architecture  string       `json:"architecture"`
	Packages      []Package    `json:"packages"`
	DeviceTrees   []DeviceTree `json:"device_trees"`
}

var packagePatterns = []struct {
	role    PackageRole
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

func (b Bundle) Package(role PackageRole) (Package, bool) {
	for _, pkg := range b.Packages {
		if pkg.Role == role {
			return pkg, true
		}
	}
	return Package{}, false
}

func (b Bundle) WriteJSON(w io.Writer) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(b)
}
