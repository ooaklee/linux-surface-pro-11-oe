package releaseprep

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/build"
)

// validateDirectory verifies manifests, exact membership, checksums, and semantics.
func validateDirectory(ctx context.Context, path string) (Manifest, error) {
	directory, err := canonicalDirectory(path, "kernel release directory")
	if err != nil {
		return Manifest{}, err
	}
	var manifest Manifest
	if err := readBoundedJSON(ctx, filepath.Join(directory, ReleaseManifestFileName), "kernel release manifest", &manifest); err != nil {
		return Manifest{}, err
	}
	if err := validateManifest(manifest); err != nil {
		return Manifest{}, err
	}
	var recordedBundle kernel.Bundle
	if err := readBoundedJSON(ctx, filepath.Join(directory, BundleFileName), "kernel release bundle", &recordedBundle); err != nil {
		return Manifest{}, err
	}
	expected := map[string]struct{}{
		ChecksumFileName: {}, BundleFileName: {}, ReleaseManifestFileName: {}, ReleaseNotesFileName: {},
	}
	assetByName := make(map[string]Asset, len(manifest.Assets))
	packages := make([]kernel.Package, 0, 4)
	for _, asset := range manifest.Assets {
		expected[asset.Name] = struct{}{}
		assetByName[asset.Name] = asset
		if asset.Kind == AssetPackage {
			packages = append(packages, kernel.Package{
				Role: asset.Role, Name: asset.Name, SHA256: asset.SHA256,
				Size: asset.Size, Verified: true,
			})
		}
	}
	if err := requireExactDirectory(directory, expected); err != nil {
		return Manifest{}, err
	}
	checksums, err := checksumEntries(ctx, filepath.Join(directory, ChecksumFileName))
	if err != nil {
		return Manifest{}, err
	}
	if len(checksums) != len(expected)-1 {
		return Manifest{}, errors.New("release SHA256SUMS does not cover the exact non-checksum file set")
	}
	for name := range expected {
		if name == ChecksumFileName {
			continue
		}
		declared, ok := checksums[name]
		if !ok {
			return Manifest{}, fmt.Errorf("release SHA256SUMS does not cover %s", name)
		}
		identity, err := inspectRegular(ctx, filepath.Join(directory, name), "kernel release file", maximumAssetBytes)
		if err != nil {
			return Manifest{}, err
		}
		if identity.sha256 != declared {
			return Manifest{}, fmt.Errorf("release checksum mismatch for %s", name)
		}
		if asset, ok := assetByName[name]; ok && (asset.SHA256 != identity.sha256 || asset.Size != identity.size) {
			return Manifest{}, fmt.Errorf("release manifest identity mismatch for %s", name)
		}
		if asset, ok := assetByName[name]; ok && asset.Kind == AssetLicence {
			contents, readErr := readStableIdentity(identity, maximumTextBytes)
			if readErr != nil || !validLicenceText(contents) {
				return Manifest{}, fmt.Errorf("release licence asset is not bounded UTF-8 text: %s", name)
			}
		}
	}
	canonicalBundle, err := kernel.NewBundle(manifest.ReleaseName, manifest.Source.GitURL, packages)
	if err != nil {
		return Manifest{}, err
	}
	if canonicalBundle.ABI != manifest.ABI || canonicalBundle.Version != manifest.Version || !reflect.DeepEqual(recordedBundle, canonicalBundle) {
		return Manifest{}, errors.New("release kernel bundle differs from its public manifest")
	}
	notesIdentity, err := inspectRegular(ctx, filepath.Join(directory, ReleaseNotesFileName), "kernel release notes", maximumTextBytes)
	if err != nil {
		return Manifest{}, err
	}
	notes, err := readStableIdentity(notesIdentity, maximumTextBytes)
	if err != nil || string(notes) != renderReleaseNotes(Plan{Manifest: manifest}) {
		return Manifest{}, errors.New("release notes differ from the manifest-derived British-English contract")
	}
	return manifest, nil
}

// validateManifest checks public policy, source provenance, ordering, and asset roles.
func validateManifest(manifest Manifest) error {
	if manifest.SchemaVersion != SchemaVersion || !safeReleaseName(manifest.ReleaseName) || manifest.GeneratedAt.IsZero() {
		return errors.New("kernel release manifest has invalid schema, name, or generation time")
	}
	if !manifest.Experimental || manifest.HardwareQualified {
		return errors.New("kernel release manifest must remain experimental and structurally unqualified")
	}
	if manifest.Architecture != "arm64" || manifest.ABI == "" || manifest.Version == "" ||
		manifest.BundleFile != BundleFileName || manifest.ChecksumFile != ChecksumFileName || manifest.NotesFile != ReleaseNotesFileName {
		return errors.New("kernel release manifest has an unsupported kernel or generated-file contract")
	}
	if strings.Contains(manifest.ABI, "sp11v3") {
		return errors.New("legacy sp11v3 out-of-tree touchscreen kernel bundles are retired")
	}
	if err := validatePublicProvenance(manifest.Source); err != nil {
		return err
	}
	if len(manifest.Assets) < 4 || len(manifest.Assets) > maximumSupplementaryAssets+4 {
		return errors.New("kernel release manifest has an invalid asset count")
	}
	seen := make(map[string]bool, len(manifest.Assets))
	roles := make(map[kernel.PackageRole]bool, 4)
	sourceCount, licenceCount := 0, 0
	previous := ""
	for _, asset := range manifest.Assets {
		collisionKey := portableCollisionKey(asset.Name)
		if !safePortableName(asset.Name) || seen[collisionKey] || !digestExpression.MatchString(asset.SHA256) || asset.Size <= 0 || asset.Size > maximumAssetBytes {
			return fmt.Errorf("kernel release manifest contains an invalid asset: %q", asset.Name)
		}
		if asset.Name == ChecksumFileName || asset.Name == BundleFileName || asset.Name == BuildProvenanceFileName ||
			asset.Name == ReleaseManifestFileName || asset.Name == ReleaseNotesFileName {
			return fmt.Errorf("kernel release asset collides with generated contract file %q", asset.Name)
		}
		if previous != "" && asset.Name <= previous {
			return errors.New("kernel release manifest assets are not strictly sorted")
		}
		previous = asset.Name
		seen[collisionKey] = true
		switch asset.Kind {
		case AssetPackage:
			role, abi, version, err := kernel.ParsePackageName(asset.Name)
			if err != nil || role != asset.Role || roles[role] || (role != kernel.RoleCommonHeaders && abi != manifest.ABI) || version != manifest.Version {
				return fmt.Errorf("kernel release manifest contains an inconsistent package: %s", asset.Name)
			}
			roles[role] = true
		case AssetSource:
			if asset.Role != "" || !sourceArchiveExpression.MatchString(asset.Name) || retiredTouchscreenAsset(asset.Name) {
				return errors.New("source assets must not carry a package role")
			}
			sourceCount++
		case AssetLicence:
			if asset.Role != "" || asset.Size > maximumTextBytes || !licenceNameExpression.MatchString(asset.Name) || retiredTouchscreenAsset(asset.Name) {
				return errors.New("licence assets must be bounded non-package files")
			}
			licenceCount++
		default:
			return fmt.Errorf("kernel release manifest contains unsupported asset kind %q", asset.Kind)
		}
	}
	if !roles[kernel.RoleImage] || !roles[kernel.RoleModules] || roles[kernel.RoleHeaders] != roles[kernel.RoleCommonHeaders] {
		return errors.New("kernel release manifest lacks one coherent runtime pair or paired headers")
	}
	if sourceCount == 0 || licenceCount == 0 {
		return errors.New("kernel release manifest requires corresponding source and explicit licence evidence")
	}
	return nil
}

// validatePublicProvenance rejects local paths, credentials, mutable images, and malformed identities.
func validatePublicProvenance(provenance SourceProvenance) error {
	private := build.Provenance{
		GitURL: provenance.GitURL, GitRef: provenance.GitRef, RefKind: provenance.RefKind,
		Revision: provenance.Revision, Tree: provenance.Tree, CommitTime: provenance.CommitTime,
		RecipeSHA256: provenance.RecipeSHA256, ContainerImage: provenance.ContainerImage,
		ToolchainSHA256: provenance.ToolchainSHA256, WorkVolume: "linux-armer-kernel-build-0000000000000000",
	}
	return validateBuildProvenance(private)
}
