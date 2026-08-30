package install

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

const (
	// maximumABIBytes bounds ABI use in paths, GRUB parsing, and command arguments.
	maximumABIBytes = 128
	// maximumPackageNameBytes bounds package-manager names and staged filenames.
	maximumPackageNameBytes = 255
	// maximumVersionBytes bounds Debian metadata retained in plans and receipts.
	maximumVersionBytes = 256
	// maximumDependencyBytes bounds dependency metadata captured from dpkg-deb.
	maximumDependencyBytes = 64 << 10
)

// surfaceABIExpression accepts only the path-safe qcom-x1e ABI convention.
var surfaceABIExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+~-]*-qcom-x1e$`)

// packageNameExpression accepts Debian binary package names without qualifiers.
var packageNameExpression = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]*$`)

// dependencyAtomExpression decodes one bounded Debian dependency alternative.
var dependencyAtomExpression = regexp.MustCompile(`^([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9-]+)?(?:\s*\(([^()]*)\))?(?:\s*\[[^\]]+\])?(?:\s*<[^>]+>)?$`)

// requiredDeviceTrees is the complete current Surface Pro 11 DTB contract.
var requiredDeviceTrees = []kernel.DeviceTree{
	{Device: "surface-pro-11-x1e-oled", Path: "qcom/x1e80100-microsoft-denali-oled.dtb"},
	{Device: "surface-pro-11-x1p-lcd", Path: "qcom/x1p64100-microsoft-denali.dtb"},
}

// dependency identifies one parsed Debian dependency alternative.
type dependency struct {
	// name is the unqualified binary package name.
	name string
	// constraint retains the optional version relation without parentheses.
	constraint string
}

// validateABI rejects ambiguous, oversized, or non-Surface kernel identifiers.
func validateABI(label, abi string) error {
	if len(abi) == 0 || len(abi) > maximumABIBytes || !utf8.ValidString(abi) || !surfaceABIExpression.MatchString(abi) {
		return fmt.Errorf("%s ABI must be a path-safe value ending in -qcom-x1e: %q", label, abi)
	}
	return nil
}

// validateDigest requires a canonical lowercase SHA-256 value.
func validateDigest(label, digest string) error {
	if len(digest) != sha256.Size*2 || strings.ToLower(digest) != digest {
		return fmt.Errorf("%s SHA-256 must be 64 lowercase hexadecimal characters", label)
	}
	if _, err := hex.DecodeString(digest); err != nil {
		return fmt.Errorf("%s SHA-256 is invalid: %w", label, err)
	}
	return nil
}

// validateText bounds one printable single-line metadata field.
func validateText(label, value string, maximum int, allowEmpty bool) error {
	if (!allowEmpty && value == "") || len(value) > maximum || !utf8.ValidString(value) {
		return fmt.Errorf("%s is empty, oversized, or malformed", label)
	}
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return fmt.Errorf("%s contains control characters", label)
		}
	}
	return nil
}

// expectedPackageNames returns the only Debian package names this installer accepts.
func expectedPackageNames(abi string) map[kernel.PackageRole]string {
	base := strings.TrimSuffix(abi, "-qcom-x1e")
	return map[kernel.PackageRole]string{
		kernel.RoleImage:         "linux-image-" + abi,
		kernel.RoleModules:       "linux-modules-" + abi,
		kernel.RoleHeaders:       "linux-headers-" + abi,
		kernel.RoleCommonHeaders: "linux-qcom-x1e-headers-" + base,
	}
}

// validateDeviceTrees requires the exact compiled current-hardware DTB set.
func validateDeviceTrees(bundle kernel.Bundle) error {
	if len(bundle.DeviceTrees) != len(requiredDeviceTrees) {
		return fmt.Errorf("kernel bundle contains %d device trees; expected %d", len(bundle.DeviceTrees), len(requiredDeviceTrees))
	}
	seen := make(map[string]string, len(bundle.DeviceTrees))
	for _, tree := range bundle.DeviceTrees {
		if _, duplicate := seen[tree.Device]; duplicate {
			return fmt.Errorf("kernel bundle contains duplicate device tree %q", tree.Device)
		}
		seen[tree.Device] = tree.Path
	}
	for _, required := range requiredDeviceTrees {
		if seen[required.Device] != required.Path {
			return fmt.Errorf("kernel bundle must contain device tree %s at %s", required.Device, required.Path)
		}
	}
	return nil
}

// parseDependencies converts a Debian Depends field into bounded alternatives.
func parseDependencies(value string) ([]dependency, error) {
	if err := validateText("Depends metadata", value, maximumDependencyBytes, true); err != nil {
		return nil, err
	}
	if strings.TrimSpace(value) == "" {
		return nil, nil
	}
	parts := strings.FieldsFunc(value, func(character rune) bool {
		return character == ',' || character == '|'
	})
	dependencies := make([]dependency, 0, len(parts))
	if len(parts) > 256 {
		return nil, errors.New("Depends metadata contains too many alternatives")
	}
	for _, part := range parts {
		atom := strings.TrimSpace(part)
		matches := dependencyAtomExpression.FindStringSubmatch(atom)
		if matches == nil {
			return nil, fmt.Errorf("unsupported Debian dependency expression %q", atom)
		}
		dependencies = append(dependencies, dependency{name: matches[1], constraint: strings.TrimSpace(matches[2])})
	}
	return dependencies, nil
}

// validateLocalDependencies rejects cross-ABI kernel package dependencies and
// requires an exact version whenever a selected local dependency is constrained.
func validateLocalDependencies(owner Package, allowed map[string]bool, version string) ([]dependency, error) {
	dependencies, err := parseDependencies(owner.Depends)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", owner.Name, err)
	}
	for _, item := range dependencies {
		if allowed[item.name] {
			if item.constraint != "" && item.constraint != "= "+version {
				return nil, fmt.Errorf("%s has non-exact or mismatched local dependency %s (%s)", owner.Name, item.name, item.constraint)
			}
			continue
		}
		if strings.HasPrefix(item.name, "linux-image-") || strings.HasPrefix(item.name, "linux-modules-") ||
			strings.HasPrefix(item.name, "linux-headers-") || strings.HasPrefix(item.name, "linux-qcom-x1e-headers-") {
			return nil, fmt.Errorf("%s depends on a kernel package outside the selected ABI set: %s", owner.Name, item.name)
		}
	}
	return dependencies, nil
}

// hasDependency reports whether one parsed alternative names the expected package.
func hasDependency(dependencies []dependency, expected string) bool {
	for _, item := range dependencies {
		if item.name == expected {
			return true
		}
	}
	return false
}
