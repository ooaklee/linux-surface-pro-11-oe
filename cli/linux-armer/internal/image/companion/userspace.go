package companion

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/artifact"
	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	userspacecatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
)

// maximumUserspaceReceiptSize bounds a portable receipt before strict JSON
// decoding so malformed cache state cannot consume unbounded memory.
const maximumUserspaceReceiptSize = 1 << 20

// prepareUserspaceBundles validates catalogue redistribution policy, exact
// source identities, portable receipts, and deterministic bundle ordering.
func prepareUserspaceBundles(componentCatalog *userspacecatalog.Catalog, bundles []userspacerelease.Bundle) ([]preparedUserspaceBundle, error) {
	if len(bundles) == 0 {
		return []preparedUserspaceBundle{}, nil
	}
	if componentCatalog == nil {
		return nil, errors.New("validated userspace catalogue is required when offline bundles are supplied")
	}
	prepared := make([]preparedUserspaceBundle, 0, len(bundles))
	seenBundles := make(map[string]bool, len(bundles))
	for _, bundle := range bundles {
		if err := validateFlatName(bundle.Component, "userspace component"); err != nil {
			return nil, err
		}
		if err := validateFlatName(bundle.Release, "userspace release"); err != nil {
			return nil, err
		}
		if bundle.Component != IPTSDOfflineComponentID {
			return nil, fmt.Errorf("userspace component %q is not approved for offline companion inclusion", bundle.Component)
		}
		key := bundle.Component + "\x00" + bundle.Release
		if seenBundles[key] {
			return nil, fmt.Errorf("duplicate offline userspace bundle %s@%s", bundle.Component, bundle.Release)
		}
		seenBundles[key] = true
		component, found := componentCatalog.Get(bundle.Component)
		if !found {
			return nil, fmt.Errorf("offline userspace component %q is not in the validated catalogue", bundle.Component)
		}
		if component.Redistribution != userspacecatalog.RedistributionAllowed &&
			component.Redistribution != userspacecatalog.RedistributionSourceRequired {
			return nil, fmt.Errorf("userspace component %q has %s redistribution policy and cannot be included offline", bundle.Component, component.Redistribution)
		}
		if component.Release == nil || component.Release.Tag != bundle.Release {
			return nil, fmt.Errorf("userspace bundle %s@%s does not match the catalogue release", bundle.Component, bundle.Release)
		}
		if strings.TrimSpace(bundle.Repository) == "" || strings.TrimSpace(bundle.Repository) != bundle.Repository || strings.ContainsAny(bundle.Repository, "\r\n") {
			return nil, fmt.Errorf("userspace bundle %s@%s has an invalid repository identity", bundle.Component, bundle.Release)
		}
		if err := validateOfflineBundleIdentity(bundle); err != nil {
			return nil, fmt.Errorf("validate immutable userspace release identity: %w", err)
		}
		if err := validateDirectory(bundle.Directory, "userspace bundle directory"); err != nil {
			return nil, err
		}
		files, err := validateUserspaceFiles(bundle, component.Release.AssetAllowlist)
		if err != nil {
			return nil, fmt.Errorf("validate userspace bundle %s@%s: %w", bundle.Component, bundle.Release, err)
		}
		if err := validateOfflineBundleArtifacts(files); err != nil {
			return nil, fmt.Errorf("validate immutable userspace release artifacts: %w", err)
		}
		receiptPath := filepath.Join(bundle.Directory, userspaceReceiptName)
		receiptContent, err := validatePortableReceipt(receiptPath, bundle, files)
		if err != nil {
			return nil, fmt.Errorf("validate userspace bundle %s@%s: %w", bundle.Component, bundle.Release, err)
		}
		if err := validateOfflineBundleReceipt(receiptContent); err != nil {
			return nil, fmt.Errorf("validate userspace bundle %s@%s: %w", bundle.Component, bundle.Release, err)
		}
		if err := validateUserspaceDirectoryMembership(bundle.Directory, files); err != nil {
			return nil, fmt.Errorf("validate userspace bundle %s@%s: %w", bundle.Component, bundle.Release, err)
		}
		prepared = append(prepared, preparedUserspaceBundle{
			component: component, bundle: bundle, files: files,
			receiptPath: receiptPath, receiptContent: receiptContent,
		})
	}
	sort.Slice(prepared, func(left, right int) bool {
		if prepared[left].bundle.Component == prepared[right].bundle.Component {
			return prepared[left].bundle.Release < prepared[right].bundle.Release
		}
		return prepared[left].bundle.Component < prepared[right].bundle.Component
	})
	return prepared, nil
}

// validateUserspaceFiles proves every in-memory identity against its exact
// canonical absolute source path and the catalogue's complete asset allow-list.
func validateUserspaceFiles(bundle userspacerelease.Bundle, allowlist []string) ([]userspacerelease.File, error) {
	if len(bundle.Files) == 0 {
		return nil, errors.New("verified userspace bundle contains no files")
	}
	files := append([]userspacerelease.File(nil), bundle.Files...)
	sort.Slice(files, func(left, right int) bool { return files[left].Name < files[right].Name })
	want := make(map[string]bool, len(allowlist))
	for _, name := range allowlist {
		if err := validateFlatName(name, "userspace catalogue asset"); err != nil {
			return nil, err
		}
		if want[name] {
			return nil, fmt.Errorf("duplicate userspace catalogue asset %q", name)
		}
		want[name] = true
	}
	seen := make(map[string]bool, len(files))
	for _, file := range files {
		if err := validateFlatName(file.Name, "userspace bundle filename"); err != nil {
			return nil, err
		}
		if seen[file.Name] {
			return nil, fmt.Errorf("duplicate userspace bundle file %q", file.Name)
		}
		seen[file.Name] = true
		if !want[file.Name] {
			return nil, fmt.Errorf("userspace bundle file %q is not in the catalogue allow-list", file.Name)
		}
		expectedPath := filepath.Join(bundle.Directory, file.Name)
		if !filepath.IsAbs(file.Path) || filepath.Clean(file.Path) != file.Path || file.Path != expectedPath {
			return nil, fmt.Errorf("userspace bundle path for %q must be exactly %s", file.Name, expectedPath)
		}
		if !file.Verified {
			return nil, fmt.Errorf("userspace bundle file %q is not verified", file.Name)
		}
		if err := validateRegularFile(file.Path, "verified userspace bundle file"); err != nil {
			return nil, err
		}
		manifestRecord := imagecontract.ArtifactRecord{Path: file.Name, SHA256: file.SHA256, Size: file.Size}
		if err := imagecontract.ValidateArtifactRecord(manifestRecord); err != nil {
			return nil, err
		}
		info, err := os.Lstat(file.Path)
		if err != nil {
			return nil, err
		}
		if info.Size() != file.Size {
			return nil, fmt.Errorf("userspace bundle file %q is %d bytes, expected %d", file.Name, info.Size(), file.Size)
		}
		digest, err := artifact.HashFile(file.Path)
		if err != nil {
			return nil, err
		}
		if digest != file.SHA256 {
			return nil, fmt.Errorf("userspace bundle file %q SHA-256 is %s, expected %s", file.Name, digest, file.SHA256)
		}
	}
	if len(seen) != len(want) {
		missing := make([]string, 0)
		for name := range want {
			if !seen[name] {
				missing = append(missing, name)
			}
		}
		sort.Strings(missing)
		return nil, fmt.Errorf("userspace bundle is missing catalogue assets: %s", strings.Join(missing, ", "))
	}
	return files, nil
}

// validatePortableReceipt strictly decodes one bounded receipt and proves that
// it contains only flat relative paths matching the verified in-memory bundle.
func validatePortableReceipt(receiptPath string, bundle userspacerelease.Bundle, files []userspacerelease.File) ([]byte, error) {
	if err := validateRegularFile(receiptPath, "portable userspace receipt"); err != nil {
		return nil, err
	}
	info, err := os.Lstat(receiptPath)
	if err != nil {
		return nil, err
	}
	if info.Size() > maximumUserspaceReceiptSize {
		return nil, fmt.Errorf("portable userspace receipt exceeds %d bytes", maximumUserspaceReceiptSize)
	}
	content, err := os.ReadFile(receiptPath)
	if err != nil {
		return nil, fmt.Errorf("read portable userspace receipt: %w", err)
	}
	if err := userspacerelease.ValidateReceiptJSONShape(content); err != nil {
		return nil, fmt.Errorf("decode portable userspace receipt: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.DisallowUnknownFields()
	var receipt userspacerelease.Bundle
	if err := decoder.Decode(&receipt); err != nil {
		return nil, fmt.Errorf("decode portable userspace receipt: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return nil, errors.New("portable userspace receipt contains multiple JSON values")
		}
		return nil, fmt.Errorf("decode portable userspace receipt after first value: %w", err)
	}
	if receipt.Component != bundle.Component || receipt.Repository != bundle.Repository || receipt.Release != bundle.Release {
		return nil, errors.New("portable userspace receipt identity does not match the verified bundle")
	}
	if receipt.Directory != "." {
		return nil, errors.New("portable userspace receipt directory must be the current directory")
	}
	expected := make(map[string]userspacerelease.File, len(files))
	for _, file := range files {
		expected[file.Name] = file
	}
	seen := make(map[string]bool, len(receipt.Files))
	for _, file := range receipt.Files {
		if err := validateFlatName(file.Name, "portable userspace receipt filename"); err != nil {
			return nil, err
		}
		if seen[file.Name] {
			return nil, fmt.Errorf("portable userspace receipt repeats %q", file.Name)
		}
		seen[file.Name] = true
		want, found := expected[file.Name]
		if !found {
			return nil, fmt.Errorf("portable userspace receipt declares unexpected file %q", file.Name)
		}
		if file.Path != file.Name {
			return nil, fmt.Errorf("portable userspace receipt path for %q is not flat and relative", file.Name)
		}
		if file.SHA256 != want.SHA256 || file.Size != want.Size || !file.Verified {
			return nil, fmt.Errorf("portable userspace receipt identity for %q does not match verified bytes", file.Name)
		}
	}
	if len(seen) != len(expected) {
		return nil, errors.New("portable userspace receipt omits verified bundle files")
	}
	return content, nil
}

// validateUserspaceDirectoryMembership rejects cache debris and nested entries
// so the copied offline release is a closed, reviewable file set.
func validateUserspaceDirectoryMembership(directory string, files []userspacerelease.File) error {
	want := map[string]bool{userspaceReceiptName: true}
	for _, file := range files {
		want[file.Name] = true
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !want[entry.Name()] {
			return fmt.Errorf("userspace bundle directory contains undeclared path %q", entry.Name())
		}
		if err := validateRegularFile(filepath.Join(directory, entry.Name()), "userspace bundle directory member"); err != nil {
			return err
		}
		delete(want, entry.Name())
	}
	if len(want) != 0 {
		missing := make([]string, 0, len(want))
		for name := range want {
			missing = append(missing, name)
		}
		sort.Strings(missing)
		return fmt.Errorf("userspace bundle directory is missing: %s", strings.Join(missing, ", "))
	}
	return nil
}
