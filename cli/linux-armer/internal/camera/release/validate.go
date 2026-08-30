package release

import (
	"bytes"
	"context"
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

// Validate repeats closed-directory, digest, provenance, package, and IPA proof.
func (manager *Manager) Validate(ctx context.Context, request ValidationRequest) (receipt ValidationReceipt, resultErr error) {
	if manager == nil || manager.Runner == nil || manager.validate == nil {
		return receipt, errors.New("camera release validator is unavailable")
	}
	if manager.hostOS != "linux" || manager.hostArchitecture != "arm64" {
		return receipt, fmt.Errorf("camera release validation requires Linux arm64; this binary reports %s/%s", manager.hostOS, manager.hostArchitecture)
	}
	root, err := canonicalDirectory(request.RepositoryRoot)
	if err != nil {
		return receipt, err
	}
	directory, err := canonicalDirectory(request.Directory)
	if err != nil {
		return receipt, err
	}
	manifestData, err := os.ReadFile(filepath.Join(directory, ManifestName))
	if err != nil || len(manifestData) == 0 || len(manifestData) > 8<<20 {
		return receipt, errors.New("camera release manifest is missing or outside its size limit")
	}
	manifest, err := decodeManifest(manifestData)
	if err != nil {
		return receipt, err
	}
	if err := validateManifestContract(directory, manifest); err != nil {
		return receipt, err
	}
	transaction, err := os.MkdirTemp("", ".linux-armer-camera-release-validate-")
	if err != nil {
		return receipt, err
	}
	if err := os.Chmod(transaction, 0o700); err != nil {
		_ = os.RemoveAll(transaction)
		return receipt, err
	}
	original, err := os.Lstat(transaction)
	if err != nil {
		_ = os.RemoveAll(transaction)
		return receipt, err
	}
	defer func() {
		current, err := os.Lstat(transaction)
		if err == nil && current.Mode()&os.ModeSymlink == 0 && os.SameFile(original, current) {
			resultErr = errors.Join(resultErr, os.RemoveAll(transaction))
		} else if !errors.Is(err, os.ErrNotExist) {
			resultErr = errors.Join(resultErr, errors.New("refuse to remove changed camera release validation transaction"))
		}
	}()
	for _, artifact := range manifest.BuildArtifacts {
		if err := copyRegular(filepath.Join(directory, artifact.Name), filepath.Join(transaction, artifact.Name)); err != nil {
			return receipt, err
		}
	}
	bundle, err := manager.validate(ctx, manager.Runner, camerabuild.ValidationRequest{RepositoryRoot: root, Directory: transaction})
	if err != nil {
		return receipt, fmt.Errorf("repeat native camera bundle proof: %w", err)
	}
	if !reflect.DeepEqual(bundle, manifest.Build) {
		return receipt, errors.New("camera release manifest embeds a different build receipt")
	}
	return ValidationReceipt{Directory: directory, ValidatedAt: managerTime(manager), Manifest: manifest}, nil
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
