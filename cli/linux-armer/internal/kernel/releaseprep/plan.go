package releaseprep

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/build"
)

// gitObjectExpression accepts exact SHA-1 or SHA-256 object identifiers.
var gitObjectExpression = regexp.MustCompile(`^(?:[0-9a-f]{40}|[0-9a-f]{64})$`)

// immutableImageExpression requires an algorithm-pinned container image.
var immutableImageExpression = regexp.MustCompile(`^[^[:space:]@]+@sha256:[0-9a-f]{64}$`)

// gitRefExpression mirrors the native builder's conservative branch and tag alphabet.
var gitRefExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$`)

// sourceArchiveExpression accepts conventional corresponding-source archive names.
var sourceArchiveExpression = regexp.MustCompile(`(?i)\.(?:tar|tar\.gz|tgz|tar\.xz|tar\.zst|zip)$`)

// licenceNameExpression accepts explicit redistribution and source-licence evidence.
var licenceNameExpression = regexp.MustCompile(`(?i)^(?:licen[cs]e|copying|copyright|notice)(?:[._-].*)?$`)

// retiredTouchscreenNames identifies the out-of-tree v3 payload that current
// kernels carry in-tree and release preparation must never reintroduce.
var retiredTouchscreenNames = map[string]struct{}{
	"gpi.ko": {}, "spi-geni-qcom.ko": {}, "mshw0485_touch.ko": {},
	"sp11-touchscreen-modules-manifest.txt": {},
}

// plan validates native build output and every supplementary release asset.
func (manager *Manager) plan(ctx context.Context, request Request) (Plan, error) {
	if manager == nil || manager.now == nil {
		return Plan{}, errors.New("kernel release manager is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return Plan{}, err
	}
	if !safeReleaseName(request.ReleaseName) {
		return Plan{}, fmt.Errorf("release name contains unsupported or path-like bytes: %q", request.ReleaseName)
	}
	buildDirectory, err := canonicalDirectory(request.BuildDirectory, "native kernel build directory")
	if err != nil {
		return Plan{}, err
	}
	outputDirectory, err := canonicalNewOutput(request.OutputDirectory)
	if err != nil {
		return Plan{}, err
	}
	if pathWithin(buildDirectory, outputDirectory) || pathWithin(outputDirectory, buildDirectory) {
		return Plan{}, errors.New("release output and native build directory must not contain one another")
	}
	bundle, provenance, packages, err := inspectNativeBuild(ctx, buildDirectory, request.ReleaseName)
	if err != nil {
		return Plan{}, err
	}
	inputs := append([]PlannedAsset(nil), packages...)
	claimed := make(map[string]string, len(inputs)+8)
	for _, reserved := range []string{ChecksumFileName, BundleFileName, BuildProvenanceFileName, ReleaseManifestFileName, ReleaseNotesFileName} {
		claimed[portableCollisionKey(reserved)] = "generated release contract"
	}
	for _, planned := range inputs {
		claimed[portableCollisionKey(planned.Asset.Name)] = "kernel package"
	}
	supplementary, err := inspectSupplementary(ctx, request.SourceAssets, request.LicenceAssets, claimed)
	if err != nil {
		return Plan{}, err
	}
	inputs = append(inputs, supplementary...)
	sort.Slice(inputs, func(left, right int) bool { return inputs[left].Asset.Name < inputs[right].Asset.Name })
	assets := make([]Asset, len(inputs))
	for index, planned := range inputs {
		assets[index] = planned.Asset
	}
	manifest := Manifest{
		SchemaVersion: SchemaVersion, ReleaseName: request.ReleaseName,
		GeneratedAt: manager.now().UTC(), Experimental: true, HardwareQualified: false,
		ABI: bundle.ABI, Version: bundle.Version, Architecture: bundle.Architecture,
		Source: publicProvenance(provenance), Assets: assets,
		BundleFile: BundleFileName, ChecksumFile: ChecksumFileName, NotesFile: ReleaseNotesFileName,
	}
	return Plan{
		BuildDirectory: buildDirectory, OutputDirectory: outputDirectory,
		DryRun: request.DryRun, Bundle: bundle, Manifest: manifest, Inputs: inputs,
		BuildProvenance: provenance,
	}, nil
}

// revalidatePlan proves the native build and supplementary inputs still match
// the reviewed byte identities immediately before staging begins.
func revalidatePlan(ctx context.Context, plan Plan) error {
	bundle, provenance, packages, err := inspectNativeBuild(ctx, plan.BuildDirectory, plan.Manifest.ReleaseName)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(bundle, plan.Bundle) || !reflect.DeepEqual(provenance, plan.BuildProvenance) ||
		!reflect.DeepEqual(publicProvenance(provenance), plan.Manifest.Source) {
		return errors.New("native kernel build identity changed after planning")
	}
	packageByName := make(map[string]PlannedAsset, len(packages))
	for _, item := range packages {
		packageByName[item.Asset.Name] = item
	}
	for _, input := range plan.Inputs {
		if input.Asset.Kind == AssetPackage {
			current, ok := packageByName[input.Asset.Name]
			if !ok || !reflect.DeepEqual(current.Asset, input.Asset) || current.SourcePath != input.SourcePath {
				return fmt.Errorf("native kernel package changed after planning: %s", input.Asset.Name)
			}
			continue
		}
		identity, err := inspectRegular(ctx, input.SourcePath, string(input.Asset.Kind)+" asset", maximumAssetBytes)
		if err != nil {
			return err
		}
		if identity.sha256 != input.Asset.SHA256 || identity.size != input.Asset.Size {
			return fmt.Errorf("%s asset changed after planning: %s", input.Asset.Kind, input.Asset.Name)
		}
	}
	return nil
}

// inspectNativeBuild verifies the exact fresh output emitted by the native builder.
func inspectNativeBuild(ctx context.Context, directory, releaseName string) (kernel.Bundle, build.Provenance, []PlannedAsset, error) {
	var recorded kernel.Bundle
	if err := readBoundedJSON(ctx, filepath.Join(directory, BundleFileName), "native kernel bundle manifest", &recorded); err != nil {
		return kernel.Bundle{}, build.Provenance{}, nil, err
	}
	var provenance build.Provenance
	if err := readBoundedJSON(ctx, filepath.Join(directory, BuildProvenanceFileName), "native kernel build provenance", &provenance); err != nil {
		return kernel.Bundle{}, build.Provenance{}, nil, err
	}
	if err := validateBuildProvenance(provenance); err != nil {
		return kernel.Bundle{}, build.Provenance{}, nil, err
	}
	if recorded.SchemaVersion != kernel.BundleSchemaVersion || recorded.Architecture != "arm64" {
		return kernel.Bundle{}, build.Provenance{}, nil, errors.New("native kernel bundle has an unsupported schema or architecture")
	}
	if len(recorded.Packages) < 2 || len(recorded.Packages) > 4 {
		return kernel.Bundle{}, build.Provenance{}, nil, fmt.Errorf("native kernel bundle contains %d packages; expected two or four", len(recorded.Packages))
	}
	checksums, err := checksumEntries(ctx, filepath.Join(directory, ChecksumFileName))
	if err != nil {
		return kernel.Bundle{}, build.Provenance{}, nil, err
	}
	expectedEntries := map[string]struct{}{
		ChecksumFileName: {}, BundleFileName: {}, BuildProvenanceFileName: {},
	}
	packages := make([]kernel.Package, 0, len(recorded.Packages))
	planned := make([]PlannedAsset, 0, len(recorded.Packages))
	roles := make(map[kernel.PackageRole]bool, len(recorded.Packages))
	for _, item := range recorded.Packages {
		if !safePortableName(item.Name) || item.Role == "" || roles[item.Role] {
			return kernel.Bundle{}, build.Provenance{}, nil, fmt.Errorf("native kernel bundle has a duplicate or unsafe package: %q", item.Name)
		}
		role, abi, version, err := kernel.ParsePackageName(item.Name)
		if err != nil || role != item.Role || (role != kernel.RoleCommonHeaders && abi != recorded.ABI) || version != recorded.Version {
			return kernel.Bundle{}, build.Provenance{}, nil, fmt.Errorf("native kernel package identity is inconsistent: %s", item.Name)
		}
		roles[role] = true
		identity, err := inspectRegular(ctx, filepath.Join(directory, item.Name), "native kernel package", maximumAssetBytes)
		if err != nil {
			return kernel.Bundle{}, build.Provenance{}, nil, err
		}
		declared, covered := checksums[item.Name]
		if !covered || declared != identity.sha256 || item.SHA256 != identity.sha256 || item.Size != identity.size || !item.Verified {
			return kernel.Bundle{}, build.Provenance{}, nil, fmt.Errorf("native kernel package digest contract failed: %s", item.Name)
		}
		public := kernel.Package{Role: role, Name: item.Name, SHA256: identity.sha256, Size: identity.size, Verified: true}
		packages = append(packages, public)
		planned = append(planned, PlannedAsset{
			Asset:      Asset{Name: item.Name, Kind: AssetPackage, Role: role, SHA256: identity.sha256, Size: identity.size},
			SourcePath: identity.path,
		})
		expectedEntries[item.Name] = struct{}{}
	}
	if roles[kernel.RoleHeaders] != roles[kernel.RoleCommonHeaders] {
		return kernel.Bundle{}, build.Provenance{}, nil, errors.New("native kernel header packages must be present together")
	}
	if len(checksums) != len(packages) {
		return kernel.Bundle{}, build.Provenance{}, nil, errors.New("native build SHA256SUMS must cover exactly its kernel packages")
	}
	if err := requireExactDirectory(directory, expectedEntries); err != nil {
		return kernel.Bundle{}, build.Provenance{}, nil, err
	}
	publicBundle, err := kernel.NewBundle(releaseName, provenance.GitURL, packages)
	if err != nil {
		return kernel.Bundle{}, build.Provenance{}, nil, err
	}
	if publicBundle.ABI != recorded.ABI || publicBundle.Version != recorded.Version {
		return kernel.Bundle{}, build.Provenance{}, nil, errors.New("native kernel bundle identity changed during public projection")
	}
	expectedPackages := make([]kernel.Package, 0, len(publicBundle.Packages))
	for _, item := range publicBundle.Packages {
		item.Path = filepath.Join(directory, item.Name)
		expectedPackages = append(expectedPackages, item)
	}
	expectedRecorded, err := kernel.NewBundle("build:"+provenance.Revision, provenance.GitURL, expectedPackages)
	if err != nil || !reflect.DeepEqual(recorded, expectedRecorded) {
		return kernel.Bundle{}, build.Provenance{}, nil, errors.New("native kernel bundle differs from the exact builder output contract")
	}
	if strings.Contains(recorded.ABI, "sp11v3") {
		return kernel.Bundle{}, build.Provenance{}, nil, errors.New("legacy sp11v3 out-of-tree touchscreen kernel bundles are retired")
	}
	return publicBundle, provenance, planned, nil
}

// inspectSupplementary verifies required source and licence inputs and collisions.
func inspectSupplementary(ctx context.Context, sourcePaths, licencePaths []string, claimed map[string]string) ([]PlannedAsset, error) {
	if len(sourcePaths) == 0 {
		return nil, errors.New("at least one corresponding-source asset is required")
	}
	if len(licencePaths) == 0 {
		return nil, errors.New("at least one explicit licence asset is required")
	}
	if len(sourcePaths)+len(licencePaths) > maximumSupplementaryAssets {
		return nil, fmt.Errorf("source and licence inputs exceed the %d-file limit", maximumSupplementaryAssets)
	}
	var result []PlannedAsset
	for _, group := range []struct {
		// kind is recorded in the public manifest.
		kind AssetKind
		// label identifies diagnostics and collision owners.
		label string
		// paths are the caller-selected local files.
		paths []string
		// maximum bounds each accepted file.
		maximum int64
	}{
		{kind: AssetSource, label: "corresponding-source asset", paths: sourcePaths, maximum: maximumAssetBytes},
		{kind: AssetLicence, label: "licence asset", paths: licencePaths, maximum: maximumTextBytes},
	} {
		for _, path := range group.paths {
			name := filepath.Base(path)
			if !safePortableName(name) {
				return nil, fmt.Errorf("%s has unsafe filename %q", group.label, name)
			}
			collisionKey := portableCollisionKey(name)
			if owner, collision := claimed[collisionKey]; collision {
				return nil, fmt.Errorf("release filename %q from %s collides with %s", name, group.label, owner)
			}
			if retiredTouchscreenAsset(name) {
				return nil, fmt.Errorf("legacy out-of-tree touchscreen asset is retired: %s", name)
			}
			if group.kind == AssetSource && !sourceArchiveExpression.MatchString(name) {
				return nil, fmt.Errorf("corresponding-source asset must be a recognised archive: %s", name)
			}
			if group.kind == AssetLicence && !licenceNameExpression.MatchString(name) {
				return nil, fmt.Errorf("licence asset must have an explicit licence, copying, copyright, or notice filename: %s", name)
			}
			identity, err := inspectRegular(ctx, path, group.label, group.maximum)
			if err != nil {
				return nil, err
			}
			if group.kind == AssetLicence {
				contents, err := readStableIdentity(identity, maximumTextBytes)
				if err != nil || !validLicenceText(contents) {
					return nil, fmt.Errorf("licence asset is not bounded UTF-8 text: %s", name)
				}
			}
			claimed[collisionKey] = group.label
			result = append(result, PlannedAsset{
				Asset:      Asset{Name: name, Kind: group.kind, SHA256: identity.sha256, Size: identity.size},
				SourcePath: identity.path,
			})
		}
	}
	return result, nil
}

// retiredTouchscreenAsset reports whether a filename belongs to the obsolete
// out-of-tree v3 module delivery contract.
func retiredTouchscreenAsset(name string) bool {
	lower := strings.ToLower(name)
	if _, retired := retiredTouchscreenNames[lower]; retired {
		return true
	}
	return strings.HasSuffix(lower, ".ko") || strings.Contains(lower, "touchscreen-modules") || strings.Contains(lower, "sp11v3")
}

// validLicenceText accepts readable UTF-8 licence evidence without NUL bytes.
func validLicenceText(contents []byte) bool {
	return len(contents) != 0 && strings.IndexByte(string(contents), 0) < 0 && utf8.Valid(contents)
}

// validateBuildProvenance checks the public and omitted private fields before projection.
func validateBuildProvenance(provenance build.Provenance) error {
	if len(provenance.GitURL) == 0 || len(provenance.GitURL) > maximumGitURLBytes || !utf8.ValidString(provenance.GitURL) {
		return errors.New("native build provenance contains an unsafe source URL")
	}
	parsed, err := url.Parse(provenance.GitURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("native build provenance contains an unsafe source URL")
	}
	if parsed.Path == "" || parsed.Path == "/" || strings.Contains(parsed.Path, "\\") {
		return errors.New("native build provenance contains an unsafe source URL")
	}
	for _, character := range provenance.GitURL {
		if character < 0x20 || character == 0x7f {
			return errors.New("native build provenance contains an unsafe source URL")
		}
	}
	if provenance.RefKind != "branch" && provenance.RefKind != "tag" {
		return errors.New("native build provenance contains an unsupported ref kind")
	}
	if !validGitRef(provenance.GitRef) || !gitObjectExpression.MatchString(provenance.Revision) || !gitObjectExpression.MatchString(provenance.Tree) {
		return errors.New("native build provenance contains an invalid source identity")
	}
	if provenance.CommitTime.IsZero() || !digestExpression.MatchString(provenance.RecipeSHA256) ||
		!digestExpression.MatchString(provenance.ToolchainSHA256) || !immutableImageExpression.MatchString(provenance.ContainerImage) {
		return errors.New("native build provenance contains invalid policy or toolchain identity")
	}
	if !regexp.MustCompile(`^linux-armer-kernel-build-[0-9a-f]{16}$`).MatchString(provenance.WorkVolume) {
		return errors.New("native build provenance contains invalid private volume identity")
	}
	return nil
}

// validGitRef mirrors the native builder's rejection of ambiguous Git syntax.
func validGitRef(value string) bool {
	if !gitRefExpression.MatchString(value) || strings.Contains(value, "..") || strings.Contains(value, "//") ||
		strings.Contains(value, "@{") || strings.HasSuffix(value, "/") || strings.HasSuffix(value, ".") || strings.HasSuffix(value, ".lock") {
		return false
	}
	for _, component := range strings.Split(value, "/") {
		if component == "" || strings.HasPrefix(component, ".") || strings.HasSuffix(component, ".lock") {
			return false
		}
	}
	return true
}

// requireExactDirectory rejects symlinks, subdirectories, and unrecognised files.
func requireExactDirectory(directory string, expected map[string]struct{}) error {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	if len(entries) != len(expected) {
		return fmt.Errorf("directory contains %d entries; expected exactly %d", len(entries), len(expected))
	}
	for _, entry := range entries {
		if _, ok := expected[entry.Name()]; !ok {
			return fmt.Errorf("directory contains unexpected entry %q", entry.Name())
		}
		if entry.Type()&os.ModeSymlink != 0 || entry.IsDir() {
			return fmt.Errorf("directory entry is not a regular file: %s", entry.Name())
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("directory entry is not a regular file: %s", entry.Name())
		}
	}
	return nil
}
