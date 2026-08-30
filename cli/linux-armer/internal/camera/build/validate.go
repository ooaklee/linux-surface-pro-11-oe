package build

import (
	"bufio"
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
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/jsonstrict"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// maximumBuildRecordBytes bounds changes, buildinfo, and structured receipts.
	maximumBuildRecordBytes = int64(4 << 20)
	// maximumPackageBytes bounds each selected binary package.
	maximumPackageBytes = int64(256 << 20)
	// maximumChangesEntryBytes bounds explicitly accounted omitted build outputs.
	maximumChangesEntryBytes = int64(4) << 30
)

// metadataNames is the exact private container-to-host provenance exchange.
var metadataNames = []string{
	"copyright-sha256",
	"copyright-size",
	"ipa-verification",
	"package-version",
	"recipe-sha256",
	"source-url",
	"support-head",
	"support-head-time",
	"toolchain-sha256",
}

// dockerVersionExpression accepts a bounded path-free engine version scalar.
var dockerVersionExpression = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$`)

// ValidationRequest selects one published bundle and its support-tree authority.
type ValidationRequest struct {
	// RepositoryRoot supplies the current HEAD-authenticated camera inputs.
	RepositoryRoot string
	// Directory is the exact eight-file package-set directory.
	Directory string
}

// debianRecord contains strict scalar fields and changes checksum entries.
type debianRecord struct {
	fields  map[string]string
	changes []Artifact
}

// validateExchange verifies private container output and creates a public receipt.
func validateExchange(ctx context.Context, runner platform.Runner, plan Plan, transaction, buildID string, inputs preparedInputs, identity dockerIdentity) (BundleReceipt, error) {
	artifactDirectory := filepath.Join(transaction, "exchange", "artifacts")
	metadataDirectory := filepath.Join(transaction, "exchange", "metadata")
	metadata, err := readMetadataDirectory(metadataDirectory)
	if err != nil {
		return BundleReceipt{}, err
	}
	expectedVersion := inputs.base.UbuntuVersion + "+sp11.2." + buildID
	if metadata["package-version"] != expectedVersion || metadata["support-head"] != inputs.commit || metadata["support-head-time"] != inputs.commitTime.Format(time.RFC3339) {
		return BundleReceipt{}, errors.New("container provenance does not match authenticated build inputs")
	}
	if metadata["recipe-sha256"] != recipeSHA256() || metadata["ipa-verification"] != "IPA module signature is valid" {
		return BundleReceipt{}, errors.New("container recipe or IPA proof is invalid")
	}
	if !baseHashExpression.MatchString(metadata["toolchain-sha256"]) || !baseHashExpression.MatchString(metadata["copyright-sha256"]) {
		return BundleReceipt{}, errors.New("container toolchain or copyright identity is malformed")
	}
	copyrightSize, err := strconv.ParseInt(metadata["copyright-size"], 10, 64)
	if err != nil || copyrightSize <= 0 || copyrightSize > maximumBuildRecordBytes {
		return BundleReceipt{}, errors.New("container copyright-file size is invalid")
	}
	sourceURL := sourceURL(inputs.base.UbuntuVersion)
	if metadata["source-url"] != sourceURL {
		return BundleReceipt{}, errors.New("container source URL differs from compiled policy")
	}
	artifacts, changes, err := validateArtifactSet(ctx, runner, artifactDirectory, expectedVersion, inputs.inputs[2].SHA256)
	if err != nil {
		return BundleReceipt{}, err
	}
	builtAt, err := time.Parse("20060102150405", strings.Split(buildID, ".")[0])
	if err != nil {
		return BundleReceipt{}, fmt.Errorf("parse camera build time: %w", err)
	}
	return BundleReceipt{
		SchemaVersion:     SchemaVersion,
		Status:            "verified",
		BuildID:           buildID,
		PackageVersion:    expectedVersion,
		BuiltAt:           builtAt.UTC(),
		SupportCommit:     inputs.commit,
		SupportCommitTime: inputs.commitTime,
		Inputs:            append([]InputProvenance(nil), inputs.inputs...),
		Source: SourceProvenance{
			UpstreamRepository:  inputs.base.UpstreamProject,
			UpstreamTag:         inputs.base.UpstreamTag,
			UpstreamCommit:      inputs.base.UpstreamCommit,
			UbuntuVersion:       inputs.base.UbuntuVersion,
			UbuntuSeries:        inputs.base.UbuntuSeries,
			SourceURL:           sourceURL,
			DSC:                 SourceFile{Name: "libcamera_" + inputs.base.UbuntuVersion + ".dsc", SHA256: inputs.base.DSCSHA256},
			OrigTarball:         SourceFile{Name: "libcamera_" + upstreamVersion(inputs.base.UbuntuVersion) + ".orig.tar.gz", SHA256: inputs.base.OrigSHA256},
			DebianTarball:       SourceFile{Name: "libcamera_" + inputs.base.UbuntuVersion + ".debian.tar.xz", SHA256: inputs.base.DebianSHA256},
			CopyrightFileSHA256: metadata["copyright-sha256"],
			CopyrightFileSize:   copyrightSize,
			LicenceEvidence:     licenceEvidence(),
		},
		Builder: BuilderProvenance{
			ContainerImage:      ContainerImage,
			ImageID:             identity.imageID,
			DockerServerVersion: identity.serverVersion,
			Architecture:        identity.serverArch,
			OperatingSystem:     identity.serverOS,
			RecipeSHA256:        recipeSHA256(),
			ToolchainSHA256:     metadata["toolchain-sha256"],
			Jobs:                plan.Jobs,
		},
		Artifacts:      artifacts,
		ChangesEntries: changes,
		Verification: Verification{
			ChangesClosedSet:         true,
			DeliveredChangesVerified: true,
			TuningIdentityVerified:   true,
			SameBuildIPAVerified:     true,
		},
	}, nil
}

// ValidateBundle revalidates a complete published bundle against current HEAD.
func ValidateBundle(ctx context.Context, runner platform.Runner, request ValidationRequest) (BundleReceipt, error) {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	root, err := resolveRoot(request.RepositoryRoot)
	if err != nil {
		return BundleReceipt{}, err
	}
	directory, err := filepath.Abs(request.Directory)
	if err != nil {
		return BundleReceipt{}, fmt.Errorf("make camera bundle path absolute: %w", err)
	}
	directory = filepath.Clean(directory)
	info, err := os.Lstat(directory)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return BundleReceipt{}, fmt.Errorf("camera bundle must be a real directory: %s", directory)
	}
	inputs, err := authenticateInputs(ctx, runner, root)
	if err != nil {
		return BundleReceipt{}, err
	}
	receiptData, err := readBoundedRegular(filepath.Join(directory, ReceiptName), maximumBuildRecordBytes)
	if err != nil {
		return BundleReceipt{}, err
	}
	receipt, err := decodeBundleReceipt(receiptData)
	if err != nil {
		return BundleReceipt{}, err
	}
	if err := validateReceiptCommit(ctx, runner, root, receipt, inputs); err != nil {
		return BundleReceipt{}, err
	}
	if err := validateReceiptAuthority(receipt, inputs); err != nil {
		return BundleReceipt{}, err
	}
	expectedNames := make(map[string]struct{}, len(receipt.Artifacts)+1)
	expectedNames[ReceiptName] = struct{}{}
	for _, artifact := range receipt.Artifacts {
		expectedNames[artifact.Name] = struct{}{}
	}
	if err := validateClosedDirectory(directory, expectedNames); err != nil {
		return BundleReceipt{}, err
	}
	validated, changes, err := validateArtifactSet(ctx, runner, directory, receipt.PackageVersion, inputs.inputs[2].SHA256)
	if err != nil {
		return BundleReceipt{}, err
	}
	if !equalArtifacts(receipt.Artifacts, validated) || !equalChanges(receipt.ChangesEntries, changes) {
		return BundleReceipt{}, errors.New("camera bundle artefacts differ from the structured receipt")
	}
	return receipt, nil
}

// readMetadataDirectory reads an exact, bounded, non-link metadata file set.
func readMetadataDirectory(directory string) (map[string]string, error) {
	expected := make(map[string]struct{}, len(metadataNames))
	for _, name := range metadataNames {
		expected[name] = struct{}{}
	}
	if err := validateClosedDirectory(directory, expected); err != nil {
		return nil, fmt.Errorf("validate camera build metadata: %w", err)
	}
	values := make(map[string]string, len(expected))
	for _, name := range metadataNames {
		data, err := readBoundedRegular(filepath.Join(directory, name), 4096)
		if err != nil {
			return nil, err
		}
		value := strings.TrimSuffix(string(data), "\n")
		if strings.TrimSpace(value) != value || value == "" || strings.ContainsAny(value, "\x00\r\n") {
			return nil, fmt.Errorf("camera metadata %s is not a canonical scalar", name)
		}
		values[name] = value
	}
	return values, nil
}

// validateArtifactSet verifies exact files, package identity, changes, and IPA proof.
func validateArtifactSet(ctx context.Context, runner platform.Runner, directory, version, tuningSHA string) ([]Artifact, []ChangesEntry, error) {
	expected := make(map[string]struct{}, 7)
	packageFiles := make([]string, 0, len(runtimePackages))
	for _, name := range runtimePackages {
		file := name + "_" + version + "_arm64.deb"
		expected[file] = struct{}{}
		packageFiles = append(packageFiles, file)
	}
	changesName := "libcamera_" + version + "_arm64.changes"
	buildinfoName := "libcamera_" + version + "_arm64.buildinfo"
	expected[changesName] = struct{}{}
	expected[buildinfoName] = struct{}{}
	if info, err := os.Lstat(filepath.Join(directory, ReceiptName)); err == nil && info.Mode()&os.ModeSymlink == 0 && info.Mode().IsRegular() {
		expected[ReceiptName] = struct{}{}
	}
	if err := validateClosedDirectory(directory, expected); err != nil {
		return nil, nil, err
	}
	artifacts := make([]Artifact, 0, 7)
	for index, name := range packageFiles {
		path := filepath.Join(directory, name)
		fields := []struct {
			label string
			want  string
		}{
			{label: "Package", want: runtimePackages[index]},
			{label: "Source", want: SourcePackage},
			{label: "Version", want: version},
			{label: "Architecture", want: Architecture},
		}
		for _, field := range fields {
			value, err := captureDirect(ctx, runner, Command{Name: "dpkg-deb", Args: []string{"--field", path, field.label}})
			if err != nil || value != field.want {
				return nil, nil, fmt.Errorf("camera package %s has unexpected %s %q", name, field.label, value)
			}
		}
		artifact, err := inspectArtifact(path, maximumPackageBytes)
		if err != nil {
			return nil, nil, err
		}
		artifacts = append(artifacts, artifact)
	}
	changesData, err := readBoundedRegular(filepath.Join(directory, changesName), maximumBuildRecordBytes)
	if err != nil {
		return nil, nil, err
	}
	changesRecord, err := parseDebianRecord(changesData, true)
	if err != nil {
		return nil, nil, fmt.Errorf("parse camera changes record: %w", err)
	}
	if err := validateRecordIdentity(changesRecord, version, "changes"); err != nil {
		return nil, nil, err
	}
	buildinfoData, err := readBoundedRegular(filepath.Join(directory, buildinfoName), maximumBuildRecordBytes)
	if err != nil {
		return nil, nil, err
	}
	buildinfoRecord, err := parseDebianRecord(buildinfoData, false)
	if err != nil {
		return nil, nil, fmt.Errorf("parse camera buildinfo record: %w", err)
	}
	if err := validateRecordIdentity(buildinfoRecord, version, "buildinfo"); err != nil {
		return nil, nil, err
	}
	changesArtifact, err := inspectArtifact(filepath.Join(directory, changesName), maximumBuildRecordBytes)
	if err != nil {
		return nil, nil, err
	}
	buildinfoArtifact, err := inspectArtifact(filepath.Join(directory, buildinfoName), maximumBuildRecordBytes)
	if err != nil {
		return nil, nil, err
	}
	artifacts = append(artifacts, changesArtifact, buildinfoArtifact)
	delivered := make(map[string]Artifact, 6)
	for _, artifact := range append(append([]Artifact(nil), artifacts[:5]...), buildinfoArtifact) {
		delivered[artifact.Name] = artifact
	}
	changes := make([]ChangesEntry, 0, len(changesRecord.changes))
	seenDelivered := make(map[string]bool, len(delivered))
	for _, entry := range changesRecord.changes {
		selected, ok := delivered[entry.Name]
		if ok {
			if selected.SHA256 != entry.SHA256 || selected.Size != entry.Size {
				return nil, nil, fmt.Errorf("camera changes entry differs from delivered file: %s", entry.Name)
			}
			seenDelivered[entry.Name] = true
		}
		if _, exists := expected[entry.Name]; exists && !ok {
			return nil, nil, fmt.Errorf("changes record unexpectedly identifies %s", entry.Name)
		}
		changes = append(changes, ChangesEntry{Artifact: entry, Delivered: ok})
	}
	if len(seenDelivered) != len(delivered) {
		return nil, nil, errors.New("changes record does not bind all five packages and buildinfo")
	}
	if err := verifyIPA(ctx, runner, directory, packageFiles, tuningSHA); err != nil {
		return nil, nil, err
	}
	return artifacts, changes, nil
}

// verifyIPA extracts the coherent core, IPA, and verifier into a private root.
func verifyIPA(ctx context.Context, runner platform.Runner, directory string, packageFiles []string, tuningSHA string) (resultErr error) {
	root, err := os.MkdirTemp("", ".linux-armer-camera-verify-")
	if err != nil {
		return fmt.Errorf("create private camera verification root: %w", err)
	}
	rootHandle, err := openDirectoryRoute(filepath.Dir(root), root)
	if err != nil {
		_ = os.RemoveAll(root)
		return fmt.Errorf("open private camera verification root: %w", err)
	}
	original, err := rootHandle.Stat()
	if err != nil || !original.IsDir() || original.Mode().Perm() != 0o700 {
		_ = rootHandle.Close()
		_ = os.RemoveAll(root)
		return errors.New("private camera verification root is invalid")
	}
	defer func() {
		closeErr := rootHandle.Close()
		current, err := os.Lstat(root)
		if err == nil && current.Mode()&os.ModeSymlink == 0 && os.SameFile(original, current) {
			resultErr = errors.Join(resultErr, closeErr, os.RemoveAll(root))
		} else if !errors.Is(err, os.ErrNotExist) {
			resultErr = errors.Join(resultErr, closeErr, errors.New("refuse to remove changed camera verification root"))
		} else {
			resultErr = errors.Join(resultErr, closeErr)
		}
	}()
	for _, index := range []int{0, 1, 2} {
		if err := runner.Run(ctx, platform.Command{Name: "dpkg-deb", Args: []string{"--extract", filepath.Join(directory, packageFiles[index]), root}}); err != nil {
			return fmt.Errorf("extract camera verification package %s: %w", packageFiles[index], err)
		}
	}
	module := filepath.Join(root, "usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so")
	signature := module + ".sign"
	tuning := filepath.Join(root, "usr/share/libcamera/ipa/simple/imx681.yaml")
	verifier := filepath.Join(root, "usr/bin/ipa_verify")
	for _, path := range []string{module, signature, tuning, verifier} {
		if err := validateRegularInput(path, maximumPackageBytes); err != nil {
			return fmt.Errorf("validate extracted camera proof: %w", err)
		}
	}
	tuningArtifact, err := inspectArtifact(tuning, maximumTuningBytes)
	if err != nil || tuningArtifact.SHA256 != tuningSHA {
		return errors.New("packaged IMX681 tuning differs from authenticated support input")
	}
	output, err := runner.Capture(ctx, platform.Command{
		Name: verifier,
		Args: []string{module},
		Env:  []string{"LD_LIBRARY_PATH=" + filepath.Join(root, "usr/lib/aarch64-linux-gnu")},
	})
	if err != nil || strings.TrimSpace(string(output)) != "IPA module signature is valid" {
		return fmt.Errorf("same-build IPA signature verification failed: %w", err)
	}
	return nil
}

// parseDebianRecord parses unique scalar fields and one strict SHA-256 section.
func parseDebianRecord(data []byte, requireChanges bool) (debianRecord, error) {
	if len(data) == 0 || int64(len(data)) > maximumBuildRecordBytes || !bytes.Equal(bytes.ToValidUTF8(data, nil), data) {
		return debianRecord{}, errors.New("Debian record is empty, oversized, or invalid UTF-8")
	}
	record := debianRecord{fields: make(map[string]string)}
	seenChangesHeader := 0
	activeChanges := false
	recordEnded := false
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), int(maximumBuildRecordBytes))
	for scanner.Scan() {
		line := scanner.Text()
		if recordEnded {
			if line != "" {
				return debianRecord{}, errors.New("Debian record contains data after its terminating blank line")
			}
			continue
		}
		if line == "Checksums-Sha256:" {
			seenChangesHeader++
			activeChanges = true
			continue
		}
		if activeChanges && line == "" {
			activeChanges = false
			recordEnded = true
			continue
		}
		if activeChanges && strings.HasPrefix(line, " ") {
			fields := strings.Fields(line)
			if len(fields) != 3 || !baseHashExpression.MatchString(fields[0]) || !safeBasename(fields[2]) {
				return debianRecord{}, errors.New("Debian changes SHA-256 entry is malformed")
			}
			size, err := strconv.ParseInt(fields[1], 10, 64)
			if err != nil || size <= 0 || size > maximumChangesEntryBytes {
				return debianRecord{}, errors.New("Debian changes size is invalid")
			}
			for _, prior := range record.changes {
				if prior.Name == fields[2] {
					return debianRecord{}, fmt.Errorf("Debian changes repeats %s", fields[2])
				}
			}
			record.changes = append(record.changes, Artifact{Name: fields[2], SHA256: fields[0], Size: size})
			continue
		}
		if activeChanges && line != "" && !strings.HasPrefix(line, " ") {
			activeChanges = false
		}
		separator := strings.Index(line, ": ")
		if separator > 0 && !strings.HasPrefix(line, " ") {
			label, value := line[:separator], line[separator+2:]
			if _, duplicate := record.fields[label]; duplicate {
				return debianRecord{}, fmt.Errorf("Debian record repeats %s", label)
			}
			record.fields[label] = value
		}
	}
	if err := scanner.Err(); err != nil {
		return debianRecord{}, err
	}
	if requireChanges && (seenChangesHeader != 1 || len(record.changes) == 0) {
		return debianRecord{}, errors.New("Debian changes must contain one non-empty Checksums-Sha256 section")
	}
	if !requireChanges && seenChangesHeader > 1 {
		return debianRecord{}, errors.New("Debian buildinfo repeats Checksums-Sha256")
	}
	return record, nil
}

// validateRecordIdentity checks the source, version, and architecture tuple.
func validateRecordIdentity(record debianRecord, version, kind string) error {
	if record.fields["Source"] != SourcePackage || record.fields["Version"] != version || record.fields["Architecture"] != Architecture {
		return fmt.Errorf("camera %s source, version, or architecture is inconsistent", kind)
	}
	return nil
}

// inspectArtifact hashes and sizes one bounded regular non-link file.
func inspectArtifact(path string, maximum int64) (Artifact, error) {
	data, err := readBoundedRegular(path, maximum)
	if err != nil {
		return Artifact{}, err
	}
	digest := sha256.Sum256(data)
	return Artifact{Name: filepath.Base(path), SHA256: hex.EncodeToString(digest[:]), Size: int64(len(data))}, nil
}

// readBoundedRegular reads one non-empty regular file without following links.
func readBoundedRegular(path string, maximum int64) ([]byte, error) {
	before, err := os.Lstat(path)
	if err != nil || before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() {
		return nil, fmt.Errorf("required camera file is not regular: %s", path)
	}
	if before.Size() <= 0 || before.Size() > maximum {
		return nil, fmt.Errorf("camera file size is outside policy: %s", path)
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
		return nil, fmt.Errorf("camera file changed while it was opened: %s", path)
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil {
		return nil, fmt.Errorf("read complete camera file %s: %w", path, err)
	}
	if int64(len(data)) != opened.Size() {
		return nil, fmt.Errorf("camera file changed while it was read: %s", path)
	}
	after, err := os.Lstat(path)
	if err != nil || after.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, after) || after.Size() != opened.Size() {
		return nil, fmt.Errorf("camera file changed after it was read: %s", path)
	}
	return data, nil
}

// validateClosedDirectory accepts exactly the named direct regular children.
func validateClosedDirectory(directory string, expected map[string]struct{}) error {
	info, err := os.Lstat(directory)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("camera directory must be real and non-symbolic: %s", directory)
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	if len(entries) != len(expected) {
		return fmt.Errorf("camera directory contains %d entries, want %d", len(entries), len(expected))
	}
	for _, entry := range entries {
		if _, ok := expected[entry.Name()]; !ok {
			return fmt.Errorf("unexpected camera directory entry: %s", entry.Name())
		}
		path := filepath.Join(directory, entry.Name())
		child, err := os.Lstat(path)
		if err != nil || child.Mode()&os.ModeSymlink != 0 || !child.Mode().IsRegular() {
			return fmt.Errorf("camera directory entry is not a regular file: %s", path)
		}
	}
	return nil
}

// decodeBundleReceipt strictly decodes one path-free structured build receipt.
func decodeBundleReceipt(data []byte) (BundleReceipt, error) {
	if err := jsonstrict.RejectDuplicateNames(data); err != nil {
		return BundleReceipt{}, fmt.Errorf("validate camera build receipt JSON: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var receipt BundleReceipt
	if err := decoder.Decode(&receipt); err != nil {
		return BundleReceipt{}, fmt.Errorf("decode camera build receipt: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return BundleReceipt{}, errors.New("camera build receipt has trailing JSON data")
	}
	return receipt, nil
}

// validateReceiptAuthority binds a public receipt to the current support HEAD.
func validateReceiptAuthority(receipt BundleReceipt, inputs preparedInputs) error {
	if receipt.SchemaVersion != SchemaVersion || receipt.Status != "verified" || !safeBuildIDExpression.MatchString(receipt.BuildID) {
		return errors.New("camera build receipt header is unsupported or unverified")
	}
	if !gitCommitExpression.MatchString(receipt.SupportCommit) || !equalInputs(receipt.Inputs, inputs.inputs) {
		return errors.New("camera build receipt is not bound to the current support inputs")
	}
	expectedVersion := inputs.base.UbuntuVersion + "+sp11.2." + receipt.BuildID
	if receipt.PackageVersion != expectedVersion || receipt.Builder.ContainerImage != ContainerImage || receipt.Builder.RecipeSHA256 != recipeSHA256() {
		return errors.New("camera build receipt package or builder policy is inconsistent")
	}
	builtAt, err := time.Parse("20060102150405", strings.Split(receipt.BuildID, ".")[0])
	if err != nil || !receipt.BuiltAt.Equal(builtAt.UTC()) {
		return errors.New("camera build receipt time does not match its build identity")
	}
	expectedSource := SourceProvenance{
		UpstreamRepository: inputs.base.UpstreamProject,
		UpstreamTag:        inputs.base.UpstreamTag,
		UpstreamCommit:     inputs.base.UpstreamCommit,
		UbuntuVersion:      inputs.base.UbuntuVersion,
		UbuntuSeries:       inputs.base.UbuntuSeries,
		SourceURL:          sourceURL(inputs.base.UbuntuVersion),
		DSC:                SourceFile{Name: "libcamera_" + inputs.base.UbuntuVersion + ".dsc", SHA256: inputs.base.DSCSHA256},
		OrigTarball:        SourceFile{Name: "libcamera_" + upstreamVersion(inputs.base.UbuntuVersion) + ".orig.tar.gz", SHA256: inputs.base.OrigSHA256},
		DebianTarball:      SourceFile{Name: "libcamera_" + inputs.base.UbuntuVersion + ".debian.tar.xz", SHA256: inputs.base.DebianSHA256},
	}
	if receipt.Source.UpstreamRepository != expectedSource.UpstreamRepository || receipt.Source.UpstreamTag != expectedSource.UpstreamTag || receipt.Source.UpstreamCommit != expectedSource.UpstreamCommit || receipt.Source.UbuntuVersion != expectedSource.UbuntuVersion || receipt.Source.UbuntuSeries != expectedSource.UbuntuSeries || receipt.Source.SourceURL != expectedSource.SourceURL || receipt.Source.DSC != expectedSource.DSC || receipt.Source.OrigTarball != expectedSource.OrigTarball || receipt.Source.DebianTarball != expectedSource.DebianTarball {
		return errors.New("camera build receipt source provenance is inconsistent")
	}
	if !baseHashExpression.MatchString(receipt.Source.CopyrightFileSHA256) || receipt.Source.CopyrightFileSize <= 0 || receipt.Source.CopyrightFileSize > maximumBuildRecordBytes || !equalStrings(receipt.Source.LicenceEvidence, licenceEvidence()) {
		return errors.New("camera build receipt copyright or licence evidence is inconsistent")
	}
	if !imageIdentityExpression.MatchString(receipt.Builder.ImageID) || receipt.Builder.OperatingSystem != "linux" || (receipt.Builder.Architecture != "arm64" && receipt.Builder.Architecture != "aarch64") || !dockerVersionExpression.MatchString(receipt.Builder.DockerServerVersion) || !baseHashExpression.MatchString(receipt.Builder.ToolchainSHA256) || receipt.Builder.Jobs < 1 || receipt.Builder.Jobs > 64 {
		return errors.New("camera build receipt observed builder provenance is inconsistent")
	}
	if !receipt.Verification.ChangesClosedSet || !receipt.Verification.DeliveredChangesVerified || !receipt.Verification.TuningIdentityVerified || !receipt.Verification.SameBuildIPAVerified {
		return errors.New("camera build receipt does not record every required proof")
	}
	if len(receipt.Artifacts) != 7 || len(receipt.ChangesEntries) < 6 || len(receipt.Source.LicenceEvidence) == 0 {
		return errors.New("camera build receipt output or licence evidence is incomplete")
	}
	return nil
}

// licenceEvidence returns the fixed public terms-evidence statements.
func licenceEvidence() []string {
	return []string{
		"Authenticated Ubuntu source debian/copyright",
		"Runtime package copyright files under /usr/share/doc",
	}
}

// equalStrings compares ordered provenance statements exactly.
func equalStrings(first, second []string) bool {
	if len(first) != len(second) {
		return false
	}
	for index := range first {
		if first[index] != second[index] {
			return false
		}
	}
	return true
}

// validateReceiptCommit proves the build commit is available, ancestral, and
// contains the exact input bytes recorded by both the receipt and current HEAD.
func validateReceiptCommit(ctx context.Context, runner platform.Runner, root string, receipt BundleReceipt, current preparedInputs) error {
	if !gitCommitExpression.MatchString(receipt.SupportCommit) {
		return errors.New("camera build receipt support commit is malformed")
	}
	if _, err := captureDirect(ctx, runner, Command{Name: "git", Args: []string{"-C", root, "cat-file", "-e", receipt.SupportCommit + "^{commit}"}}); err != nil {
		return fmt.Errorf("camera build support commit is unavailable: %w", err)
	}
	if _, err := captureDirect(ctx, runner, Command{Name: "git", Args: []string{"-C", root, "merge-base", "--is-ancestor", receipt.SupportCommit, current.commit}}); err != nil {
		return errors.New("camera build support commit is not an ancestor of current HEAD")
	}
	commitTimeText, err := captureDirect(ctx, runner, Command{Name: "git", Args: []string{"-C", root, "show", "-s", "--format=%cI", receipt.SupportCommit}})
	if err != nil {
		return fmt.Errorf("read camera build support commit time: %w", err)
	}
	commitTime, err := time.Parse(time.RFC3339, commitTimeText)
	if err != nil || !receipt.SupportCommitTime.Equal(commitTime.UTC()) {
		return errors.New("camera build support commit time differs from its receipt")
	}
	if len(receipt.Inputs) != len(inputPaths) {
		return errors.New("camera build receipt has an incomplete input set")
	}
	for index, relative := range inputPaths {
		data, err := runner.Capture(ctx, platform.Command{Name: "git", Args: []string{"-C", root, "show", receipt.SupportCommit + ":" + relative}})
		if err != nil {
			return fmt.Errorf("read camera build input %s: %w", relative, err)
		}
		digest := sha256.Sum256(data)
		if receipt.Inputs[index].Path != relative || receipt.Inputs[index].SHA256 != hex.EncodeToString(digest[:]) {
			return fmt.Errorf("camera build input differs from recorded support commit: %s", relative)
		}
	}
	return nil
}

// equalInputs compares ordered, exact HEAD input provenance.
func equalInputs(first, second []InputProvenance) bool {
	if len(first) != len(second) {
		return false
	}
	for index := range first {
		if first[index] != second[index] {
			return false
		}
	}
	return true
}

// equalArtifacts compares ordered names, digests, and sizes.
func equalArtifacts(first, second []Artifact) bool {
	if len(first) != len(second) {
		return false
	}
	for index := range first {
		if first[index] != second[index] {
			return false
		}
	}
	return true
}

// equalChanges compares complete ordered changes accounting.
func equalChanges(first, second []ChangesEntry) bool {
	if len(first) != len(second) {
		return false
	}
	for index := range first {
		if first[index] != second[index] {
			return false
		}
	}
	return true
}

// safeBasename accepts only one portable non-hidden artefact basename.
func safeBasename(name string) bool {
	if name == "" || name == "." || name == ".." || filepath.Base(name) != name || strings.HasPrefix(name, ".") {
		return false
	}
	for _, character := range name {
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || strings.ContainsRune("+._~-", character) {
			continue
		}
		return false
	}
	return true
}

// sourceURL returns the sole HTTPS source directory for a reviewed version.
func sourceURL(version string) string {
	return "https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/libcamera/" + version
}

// upstreamVersion extracts the upstream version from a validated Debian version.
func upstreamVersion(version string) string {
	if separator := strings.IndexByte(version, '-'); separator > 0 {
		return version[:separator]
	}
	return version
}
