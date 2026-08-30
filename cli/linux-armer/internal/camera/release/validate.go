package release

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	camerabuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/build"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/jsonstrict"
)

// Validate retains the release-validation entry point using static proof only.
func (manager *Manager) Validate(ctx context.Context, request ValidationRequest) (ValidationReceipt, error) {
	return manager.ValidateStatic(ctx, request)
}

// ValidateStatic repeats the closed-directory, digest, provenance, package, and
// tuning proofs without writing files or executing package payload.
func (manager *Manager) ValidateStatic(ctx context.Context, request ValidationRequest) (ValidationReceipt, error) {
	var receipt ValidationReceipt
	if manager == nil || manager.Runner == nil || manager.validate == nil {
		return receipt, errors.New("camera release validator is unavailable")
	}
	if !sha256Expression.MatchString(request.ExpectedAuthoritySHA256) {
		return receipt, errors.New("an expected camera release authority SHA-256 is required")
	}
	root, err := canonicalDirectory(request.RepositoryRoot)
	if err != nil {
		return receipt, err
	}
	directory, err := canonicalDirectory(request.Directory)
	if err != nil {
		return receipt, err
	}
	manifestData, err := readBoundedReleaseRegular(filepath.Join(directory, ManifestName), 8<<20)
	if err != nil {
		return receipt, errors.New("camera release manifest is missing or outside its size limit")
	}
	digest := sha256.Sum256(manifestData)
	if hex.EncodeToString(digest[:]) != request.ExpectedAuthoritySHA256 {
		return receipt, errors.New("camera release authority SHA-256 does not match the independent hand-off value")
	}
	manifest, err := decodeManifest(manifestData)
	if err != nil {
		return receipt, err
	}
	if err := validateManifestContract(directory, manifest); err != nil {
		return receipt, err
	}
	buildAuthority, err := manifestBuildAuthority(manifest)
	if err != nil {
		return receipt, err
	}
	bundle, err := manager.validate(ctx, manager.Runner, camerabuild.ValidationRequest{
		RepositoryRoot:          root,
		Directory:               directory,
		ExpectedAuthoritySHA256: buildAuthority,
		AdditionalFiles:         []string{ChecksumName, NotesName, ManifestName},
	})
	if err != nil {
		return receipt, fmt.Errorf("repeat static camera bundle proof: %w", err)
	}
	if !reflect.DeepEqual(bundle, manifest.Build) {
		return receipt, errors.New("camera release manifest embeds a different build receipt")
	}
	return ValidationReceipt{Directory: directory, ValidatedAt: managerTime(manager), Manifest: manifest}, nil
}

// manifestBuildAuthority returns the receipt digest bound by the release manifest.
func manifestBuildAuthority(manifest Manifest) (string, error) {
	for _, artifact := range manifest.BuildArtifacts {
		if artifact.Name == camerabuild.ReceiptName && sha256Expression.MatchString(artifact.SHA256) {
			return artifact.SHA256, nil
		}
	}
	return "", errors.New("camera release manifest omits its build authority digest")
}

// readBoundedReleaseRegular reads one stable, non-link release authority file.
func readBoundedReleaseRegular(path string, maximum int64) ([]byte, error) {
	before, err := os.Lstat(path)
	if err != nil || before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() || before.Size() <= 0 || before.Size() > maximum {
		return nil, fmt.Errorf("camera release authority is not a bounded regular file: %s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	current, err := os.Lstat(path)
	if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(before, opened) || !os.SameFile(opened, current) {
		return nil, fmt.Errorf("camera release authority changed while it was opened: %s", path)
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil || int64(len(data)) != opened.Size() {
		return nil, fmt.Errorf("camera release authority changed while it was read: %s", path)
	}
	after, err := os.Lstat(path)
	if err != nil || after.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, after) || after.Size() != opened.Size() {
		return nil, fmt.Errorf("camera release authority changed after it was read: %s", path)
	}
	return data, nil
}

// decodeManifest strictly decodes one structured local release record.
func decodeManifest(data []byte) (Manifest, error) {
	if err := jsonstrict.RejectDuplicateNames(data); err != nil {
		return Manifest{}, fmt.Errorf("validate camera release manifest JSON: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var manifest Manifest
	if err := decoder.Decode(&manifest); err != nil {
		return Manifest{}, fmt.Errorf("decode camera release manifest: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return Manifest{}, errors.New("camera release manifest contains trailing JSON data")
	}
	return manifest, nil
}

// validateManifestContract verifies the exact eleven files and all local digests.
func validateManifestContract(directory string, manifest Manifest) error {
	if manifest.SchemaVersion != SchemaVersion || manifest.Status != "verified-local-preparation" || manifest.RemoteMutation || manifest.Tag != filepath.Base(directory) {
		return errors.New("camera release manifest header is inconsistent")
	}
	if !releaseNameExpression.MatchString(manifest.Tag) || !releaseNameExpression.MatchString(manifest.KernelTag) || !kernelABIExpression.MatchString(manifest.KernelABI) || unsafeText(manifest.Tag) || unsafeText(manifest.KernelTag) || unsafeText(manifest.KernelABI) || manifest.PreparedAt.IsZero() {
		return errors.New("camera release manifest identity or preparation time is invalid")
	}
	kernelVersion := strings.TrimSuffix(manifest.KernelABI, "-qcom-x1e")
	if !strings.Contains(manifest.KernelTag, kernelVersion) {
		return errors.New("camera release manifest kernel tag and ABI do not match")
	}
	if manifest.BuildReceiptName != camerabuild.ReceiptName || len(manifest.BuildArtifacts) != 8 || len(manifest.GeneratedFiles) != 2 {
		return errors.New("camera release manifest has an incomplete file set")
	}
	if manifest.SourceAndLicenceProvenance.UbuntuSourceURL != manifest.Build.Source.SourceURL || manifest.SourceAndLicenceProvenance.DebianCopyrightSHA256 != manifest.Build.Source.CopyrightFileSHA256 || !reflect.DeepEqual(manifest.SourceAndLicenceProvenance.Evidence, manifest.Build.Source.LicenceEvidence) {
		return errors.New("camera release source or licence provenance is inconsistent")
	}
	expectedSources := map[string]string{
		manifest.Build.Source.DSC.Name:           manifest.Build.Source.DSC.SHA256,
		manifest.Build.Source.OrigTarball.Name:   manifest.Build.Source.OrigTarball.SHA256,
		manifest.Build.Source.DebianTarball.Name: manifest.Build.Source.DebianTarball.SHA256,
	}
	if !reflect.DeepEqual(manifest.SourceAndLicenceProvenance.UbuntuSourceSHA256, expectedSources) {
		return errors.New("camera release source digest map is inconsistent")
	}
	buildNames := make(map[string]struct{}, 8)
	for index, artifact := range manifest.BuildArtifacts {
		if filepath.Base(artifact.Name) != artifact.Name || artifact.Name == "" || artifact.Size <= 0 || len(artifact.SHA256) != 64 {
			return errors.New("camera release build artefact record is malformed")
		}
		if index > 0 && manifest.BuildArtifacts[index-1].Name >= artifact.Name {
			return errors.New("camera release build artefacts are not uniquely sorted")
		}
		actual, err := inspectFile(filepath.Join(directory, artifact.Name))
		if err != nil || actual != artifact {
			return fmt.Errorf("camera release build artefact differs from manifest: %s", artifact.Name)
		}
		buildNames[artifact.Name] = struct{}{}
	}
	if _, ok := buildNames[camerabuild.ReceiptName]; !ok {
		return errors.New("camera release omits the structured build receipt")
	}
	generated := append([]GeneratedFile(nil), manifest.GeneratedFiles...)
	sort.Slice(generated, func(first, second int) bool { return generated[first].Name < generated[second].Name })
	if generated[0].Name != NotesName || generated[1].Name != ChecksumName {
		return errors.New("camera release generated-file set is invalid")
	}
	for _, file := range generated {
		actual, err := inspectFile(filepath.Join(directory, file.Name))
		if err != nil || actual != file {
			return fmt.Errorf("camera generated file differs from manifest: %s", file.Name)
		}
	}
	if err := validatePreparedDirectory(directory, manifest); err != nil {
		return err
	}
	return nil
}
