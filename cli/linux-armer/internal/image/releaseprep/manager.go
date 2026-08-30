package releaseprep

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"syscall"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/plan"
)

// expectedImageSteps is the exact successful native image-creation journal order.
var expectedImageSteps = []string{
	"verify-source", "verify-kernel", "stage-companion", "prepare-tools",
	"extract-live-root", "install-kernel", "assemble-initramfs-root", "build-initramfs",
	"bind-live-media", "pair-device-trees", "repack-live-root", "replay-hybrid-boot",
	"validate-output", "publish-output",
}

// sourceContracts contains strict sidecar values needed after public planning.
type sourceContracts struct {
	// manifest is the decoded single image contract.
	manifest imagecontract.Manifest
	// journal is the decoded successful creation journal.
	journal plan.Journal
}

// Plan validates and measures all source inputs without external validation or writes.
func (manager *Manager) Plan(ctx context.Context, request Request) (Plan, error) {
	operationPlan, _, err := manager.plan(ctx, request)
	return operationPlan, err
}

// plan validates containment, sidecar contracts, and the immutable image identity.
func (manager *Manager) plan(ctx context.Context, request Request) (Plan, sourceContracts, error) {
	if manager == nil || manager.Validator == nil || manager.Compressor == nil {
		return Plan{}, sourceContracts{}, errors.New("image release manager dependencies are incomplete")
	}
	if err := ctx.Err(); err != nil {
		return Plan{}, sourceContracts{}, err
	}
	root, err := canonicalDirectory(request.RepositoryRoot, "repository root")
	if err != nil {
		return Plan{}, sourceContracts{}, err
	}
	imagePath := request.ImagePath
	if !filepath.IsAbs(imagePath) {
		imagePath = filepath.Join(root, imagePath)
	}
	imagePath, err = filepath.Abs(imagePath)
	if err != nil {
		return Plan{}, sourceContracts{}, fmt.Errorf("resolve source ISO: %w", err)
	}
	imagePath = filepath.Clean(imagePath)
	if !containedBy(root, imagePath) {
		return Plan{}, sourceContracts{}, errors.New("source ISO must remain beneath the repository root")
	}
	if err := rejectSymbolicRoute(root, imagePath); err != nil {
		return Plan{}, sourceContracts{}, err
	}
	imageName := filepath.Base(imagePath)
	if !safePortableName(imageName) || len(imageName) > 200 || !strings.HasSuffix(strings.ToLower(imageName), ".iso") {
		return Plan{}, sourceContracts{}, errors.New("source image must have a bounded portable .iso filename")
	}
	imageIdentity, err := inspectRegular(ctx, imagePath, "source ISO", maximumImageBytes)
	if err != nil {
		return Plan{}, sourceContracts{}, err
	}
	manifestIdentity, err := inspectRegular(ctx, imagePath+".manifest.json", "image manifest sidecar", maximumJSONBytes)
	if err != nil {
		return Plan{}, sourceContracts{}, err
	}
	journalIdentity, err := inspectRegular(ctx, imagePath+".journal.json", "image creation journal", maximumJSONBytes)
	if err != nil {
		return Plan{}, sourceContracts{}, err
	}
	manifestData, err := readIdentity(ctx, manifestIdentity, maximumJSONBytes)
	if err != nil {
		return Plan{}, sourceContracts{}, fmt.Errorf("read image manifest sidecar: %w", err)
	}
	manifest, err := imagecontract.DecodeManifest(strings.NewReader(string(manifestData)))
	if err != nil {
		return Plan{}, sourceContracts{}, err
	}
	if err := validateImageContract(manifest); err != nil {
		return Plan{}, sourceContracts{}, err
	}
	journalData, err := readIdentity(ctx, journalIdentity, maximumJSONBytes)
	if err != nil {
		return Plan{}, sourceContracts{}, fmt.Errorf("read image creation journal: %w", err)
	}
	var journal plan.Journal
	if err := decodeStrictJSON(journalData, &journal); err != nil {
		return Plan{}, sourceContracts{}, fmt.Errorf("decode image creation journal: %w", err)
	}
	if err := validateImageJournal(journal, imageIdentity.record); err != nil {
		return Plan{}, sourceContracts{}, err
	}
	releaseName := request.ReleaseName
	if releaseName == "" {
		releaseName = strings.TrimSuffix(imageName, filepath.Ext(imageName))
	}
	if !safeReleaseName(releaseName) {
		return Plan{}, sourceContracts{}, errors.New("release name must be a portable non-path value")
	}
	releaseRoot := filepath.Join(root, "build", "release")
	output := request.OutputDirectory
	if output == "" {
		output = filepath.Join(releaseRoot, releaseName)
	} else if !filepath.IsAbs(output) {
		output = filepath.Join(root, output)
	}
	output, err = filepath.Abs(output)
	if err != nil {
		return Plan{}, sourceContracts{}, fmt.Errorf("resolve release output: %w", err)
	}
	output = filepath.Clean(output)
	if filepath.Dir(output) != releaseRoot || filepath.Base(output) != releaseName {
		return Plan{}, sourceContracts{}, errors.New("release output must be build/release/<release-name>")
	}
	if containedBy(output, imagePath) || containedBy(imagePath, output) {
		return Plan{}, sourceContracts{}, errors.New("release output and source ISO must not contain one another")
	}
	if err := rejectSymbolicRoute(root, output); err != nil {
		return Plan{}, sourceContracts{}, err
	}
	if _, err := os.Lstat(output); !errors.Is(err, os.ErrNotExist) {
		if err == nil {
			return Plan{}, sourceContracts{}, fmt.Errorf("release output already exists: %s", output)
		}
		return Plan{}, sourceContracts{}, fmt.Errorf("inspect release output: %w", err)
	}
	partSize := request.PartSizeBytes
	if partSize == 0 {
		partSize = DefaultPartSizeBytes
	}
	if partSize <= 0 || partSize >= HostedAssetLimitBytes {
		return Plan{}, sourceContracts{}, fmt.Errorf("part size must be greater than zero and less than %d", HostedAssetLimitBytes)
	}
	minimumParts := imageIdentity.record.Size / partSize
	if imageIdentity.record.Size%partSize != 0 {
		minimumParts++
	}
	if minimumParts > maximumPartCount {
		return Plan{}, sourceContracts{}, fmt.Errorf("part size could exceed the %d-part safety limit", maximumPartCount)
	}
	return Plan{
		RepositoryRoot: root, ImagePath: imagePath,
		ImageManifestPath: manifestIdentity.path, ImageJournalPath: journalIdentity.path,
		OutputDirectory: output, ReleaseName: releaseName, PartSizeBytes: partSize,
		Image: imageIdentity.record, ImageManifest: manifestIdentity.record,
		ImageJournal: journalIdentity.record, DryRun: request.DryRun, MutatesRemote: false,
	}, sourceContracts{manifest: manifest, journal: journal}, nil
}

// Prepare structurally validates, compresses, and atomically installs one local release.
func (manager *Manager) Prepare(ctx context.Context, request Request) (receipt Receipt, resultErr error) {
	operationPlan, contracts, err := manager.plan(ctx, request)
	if err != nil {
		return receipt, err
	}
	receipt.Plan = operationPlan
	if operationPlan.DryRun {
		return receipt, nil
	}
	report, err := manager.Validator.Validate(ctx, operationPlan.ImagePath)
	if err != nil {
		return receipt, fmt.Errorf("structurally validate release image: %w", err)
	}
	validation, err := projectValidation(report, operationPlan.Image, contracts.manifest)
	if err != nil {
		return receipt, err
	}
	releaseRoot := filepath.Dir(operationPlan.OutputDirectory)
	if err := ensureDirectory(operationPlan.RepositoryRoot, releaseRoot, 0o755); err != nil {
		return receipt, err
	}
	if err := rejectSymbolicRoute(operationPlan.RepositoryRoot, releaseRoot); err != nil {
		return receipt, err
	}
	staging, err := os.MkdirTemp(releaseRoot, ".image-release-"+operationPlan.ReleaseName+"-")
	if err != nil {
		return receipt, fmt.Errorf("create private release transaction: %w", err)
	}
	if err := os.Chmod(staging, 0o700); err != nil {
		_ = os.RemoveAll(staging)
		return receipt, err
	}
	stagingIdentity, err := os.Lstat(staging)
	if err != nil {
		_ = os.RemoveAll(staging)
		return receipt, err
	}
	cleanup := true
	defer func() {
		if !cleanup {
			return
		}
		current, statErr := os.Lstat(staging)
		if statErr == nil && current.Mode()&os.ModeSymlink == 0 && os.SameFile(stagingIdentity, current) {
			resultErr = errors.Join(resultErr, os.RemoveAll(staging))
		} else if !errors.Is(statErr, os.ErrNotExist) {
			resultErr = errors.Join(resultErr, errors.New("refuse to remove a changed image-release transaction"))
		}
	}()
	manifestIdentity, err := inspectRegular(ctx, operationPlan.ImageManifestPath, "image manifest sidecar", maximumJSONBytes)
	if err != nil || !reflect.DeepEqual(manifestIdentity.record, operationPlan.ImageManifest) {
		return receipt, errors.Join(errors.New("image manifest sidecar changed after planning"), err)
	}
	if err := copyIdentity(ctx, manifestIdentity, filepath.Join(staging, manifestIdentity.record.Name), maximumJSONBytes); err != nil {
		return receipt, fmt.Errorf("copy image manifest sidecar: %w", err)
	}
	parts, archive, compression, err := manager.compressImage(ctx, operationPlan, staging)
	if err != nil {
		return receipt, err
	}
	manifest := Manifest{
		SchemaVersion: SchemaVersion, ReleaseName: operationPlan.ReleaseName,
		Image: operationPlan.Image, ImageManifest: operationPlan.ImageManifest,
		ImageContract: contracts.manifest, ImageCreation: projectJournal(contracts.journal),
		StructuralValidation: validation, Compression: compression,
		CompressedArchive: archive, PartSizeBytes: operationPlan.PartSizeBytes,
		Parts: parts, RemoteMutation: false,
	}
	manifestData, err := encodeJSON(manifest)
	if err != nil {
		return receipt, fmt.Errorf("serialise image release manifest: %w", err)
	}
	if err := writeExclusive(filepath.Join(staging, ReleaseManifestName), manifestData, 0o644); err != nil {
		return receipt, err
	}
	notes := renderNotes(manifest)
	if err := writeExclusive(filepath.Join(staging, NotesName), notes, 0o644); err != nil {
		return receipt, err
	}
	checksumRecords := append([]FileRecord(nil), parts...)
	checksumRecords = append(checksumRecords, operationPlan.ImageManifest)
	for _, name := range []string{ReleaseManifestName, NotesName} {
		identity, err := inspectRegular(ctx, filepath.Join(staging, name), name, maximumTextBytes)
		if err != nil {
			return receipt, err
		}
		checksumRecords = append(checksumRecords, identity.record)
	}
	if err := writeExclusive(filepath.Join(staging, ChecksumName), renderChecksums(checksumRecords), 0o644); err != nil {
		return receipt, err
	}
	if _, err := manager.validateDirectory(ctx, staging); err != nil {
		return receipt, fmt.Errorf("validate prepared image release before publication: %w", err)
	}
	if err := os.Chmod(staging, 0o755); err != nil {
		return receipt, fmt.Errorf("set final image release directory mode: %w", err)
	}
	if err := publishDirectoryNoReplace(staging, operationPlan.OutputDirectory); err != nil {
		return receipt, fmt.Errorf("atomically publish image release directory: %w", err)
	}
	cleanup = false
	receipt.Manifest = &manifest
	receipt.Published = true
	if err := syncDirectory(releaseRoot); err != nil {
		return receipt, fmt.Errorf("synchronise published image release root: %w", err)
	}
	return receipt, nil
}

// compressImage feeds the stable source through deterministic zstd and split files.
func (manager *Manager) compressImage(ctx context.Context, operationPlan Plan, staging string) ([]FileRecord, FileRecord, CompressionTool, error) {
	identity, err := inspectRegular(ctx, operationPlan.ImagePath, "source ISO", maximumImageBytes)
	if err != nil || !reflect.DeepEqual(identity.record, operationPlan.Image) {
		return nil, FileRecord{}, CompressionTool{}, errors.Join(errors.New("source ISO changed after planning"), err)
	}
	file, err := os.Open(identity.path)
	if err != nil {
		return nil, FileRecord{}, CompressionTool{}, err
	}
	opened, statErr := file.Stat()
	if statErr != nil || !opened.Mode().IsRegular() || !os.SameFile(identity.info, opened) {
		_ = file.Close()
		return nil, FileRecord{}, CompressionTool{}, errors.New("source ISO identity changed before compression")
	}
	rawHasher := sha256.New()
	rawCounter := &countingHashWriter{hash: rawHasher, maximum: identity.record.Size}
	compressedName := operationPlan.Image.Name + ".zst"
	writer := newPartWriter(staging, compressedName, operationPlan.PartSizeBytes)
	compression, compressErr := manager.Compressor.Compress(ctx, io.TeeReader(file, rawCounter), writer)
	parts, archive, finaliseErr := writer.Close()
	closeErr := file.Close()
	current, currentErr := os.Lstat(identity.path)
	if err := errors.Join(compressErr, finaliseErr, closeErr, currentErr); err != nil {
		_ = writer.Abort()
		return nil, FileRecord{}, CompressionTool{}, err
	}
	if rawCounter.size != identity.record.Size || hex.EncodeToString(rawHasher.Sum(nil)) != identity.record.SHA256 ||
		current.Mode()&os.ModeSymlink != 0 || !os.SameFile(identity.info, current) {
		return nil, FileRecord{}, CompressionTool{}, errors.New("source ISO changed while it was compressed")
	}
	if err := validateCompression(compression); err != nil {
		return nil, FileRecord{}, CompressionTool{}, err
	}
	return parts, archive, compression, nil
}

// validateImageContract enforces the supported outer manifest identity.
func validateImageContract(manifest imagecontract.Manifest) error {
	if manifest.SchemaVersion != imagecontract.ManifestSchemaVersion || manifest.Layout != "hybrid-iso" || manifest.Adapter == "" {
		return errors.New("image manifest has an unsupported schema, layout, or adapter")
	}
	if manifest.CreatedAt.IsZero() || manifest.KernelBundle.ABI == "" || manifest.KernelBundle.Architecture != "arm64" {
		return errors.New("image manifest lacks ARM64 kernel provenance")
	}
	if manifest.MediaDiscovery.Strategy == "" || manifest.MediaDiscovery.Protocol == "" || len(manifest.BootArtifacts.DTBs) == 0 {
		return errors.New("image manifest lacks media-discovery or device-tree evidence")
	}
	seenDevices := make(map[string]struct{}, len(manifest.KernelBundle.DeviceTrees))
	for _, deviceTree := range manifest.KernelBundle.DeviceTrees {
		if !safeReleaseName(deviceTree.Device) {
			return errors.New("image manifest contains an unsafe device-tree identity")
		}
		if _, exists := seenDevices[deviceTree.Device]; exists {
			return fmt.Errorf("image manifest contains duplicate device-tree identity %q", deviceTree.Device)
		}
		seenDevices[deviceTree.Device] = struct{}{}
	}
	return nil
}

// validateImageJournal proves complete successful publication of the exact ISO.
func validateImageJournal(journal plan.Journal, image FileRecord) error {
	if journal.SchemaVersion != plan.SchemaVersion || journal.Operation != "image.create" || journal.Output == nil {
		return errors.New("image creation journal has an unsupported or incomplete contract")
	}
	if filepath.Base(journal.Output.Path) != image.Name || journal.Output.SHA256 != image.SHA256 || journal.Output.Size != image.Size {
		return errors.New("image creation journal output does not match the source ISO")
	}
	if len(journal.Records) != len(expectedImageSteps) {
		return errors.New("image creation journal does not contain the complete native workflow")
	}
	for index, record := range journal.Records {
		if record.StepID != expectedImageSteps[index] || record.CompletedAt.IsZero() {
			return fmt.Errorf("image creation journal step %d is incomplete or out of order", index+1)
		}
		for name, digest := range record.Digests {
			if !safePortablePath(name) || !digestExpression.MatchString(digest) {
				return fmt.Errorf("image creation journal contains unsafe digest evidence at step %s", record.StepID)
			}
		}
	}
	for _, index := range []int{len(expectedImageSteps) - 2, len(expectedImageSteps) - 1} {
		if journal.Records[index].Digests["output.iso"] != image.SHA256 {
			return fmt.Errorf("image creation journal step %s lacks the exact output digest", journal.Records[index].StepID)
		}
	}
	return nil
}

// projectJournal removes host paths and map ordering from one validated journal.
func projectJournal(journal plan.Journal) ImageCreationRecord {
	records := make([]JournalRecord, 0, len(journal.Records))
	for _, record := range journal.Records {
		keys := make([]string, 0, len(record.Digests))
		for name := range record.Digests {
			keys = append(keys, name)
		}
		sort.Strings(keys)
		digests := make([]DigestRecord, 0, len(keys))
		for _, name := range keys {
			digests = append(digests, DigestRecord{Name: name, SHA256: record.Digests[name]})
		}
		records = append(records, JournalRecord{StepID: record.StepID, CompletedAt: record.CompletedAt, Digests: digests})
	}
	return ImageCreationRecord{
		SchemaVersion: journal.SchemaVersion, Operation: journal.Operation, Records: records,
		Output: FileRecord{Name: filepath.Base(journal.Output.Path), SHA256: journal.Output.SHA256, Size: journal.Output.Size},
	}
}

// projectValidation checks exact image agreement and removes local diagnostic paths.
func projectValidation(report imagecontract.ValidationReport, image FileRecord, manifest imagecontract.Manifest) (ValidationRecord, error) {
	if !report.Valid || report.SHA256 != image.SHA256 || report.Size != image.Size ||
		report.Layout != manifest.Layout || report.Adapter != manifest.Adapter || report.KernelABI != manifest.KernelBundle.ABI {
		return ValidationRecord{}, errors.New("structural validation evidence does not match the release image contract")
	}
	if len(report.Checks) == 0 || len(report.Checks) > 256 {
		return ValidationRecord{}, errors.New("structural validation returned an invalid check count")
	}
	checks := make([]ValidationCheck, 0, len(report.Checks))
	seen := make(map[string]struct{}, len(report.Checks))
	for _, check := range report.Checks {
		if !safeReleaseName(check.Name) || !check.Passed {
			return ValidationRecord{}, fmt.Errorf("structural validation check failed or has an unsafe name: %q", check.Name)
		}
		if _, exists := seen[check.Name]; exists {
			return ValidationRecord{}, fmt.Errorf("structural validation returned duplicate check %q", check.Name)
		}
		seen[check.Name] = struct{}{}
		checks = append(checks, ValidationCheck{Name: check.Name, Passed: true})
	}
	deviceTrees := append([]string(nil), report.DeviceTrees...)
	sort.Strings(deviceTrees)
	expectedDeviceTrees := make([]string, 0, len(manifest.KernelBundle.DeviceTrees))
	for _, deviceTree := range manifest.KernelBundle.DeviceTrees {
		if !safeReleaseName(deviceTree.Device) {
			return ValidationRecord{}, errors.New("image manifest contains an unsafe device-tree identity")
		}
		expectedDeviceTrees = append(expectedDeviceTrees, deviceTree.Device)
	}
	sort.Strings(expectedDeviceTrees)
	if !reflect.DeepEqual(deviceTrees, expectedDeviceTrees) {
		return ValidationRecord{}, errors.New("structural validation device trees differ from the image manifest")
	}
	return ValidationRecord{
		Valid: true, Layout: report.Layout, Adapter: report.Adapter, KernelABI: report.KernelABI,
		DeviceTrees: deviceTrees, Checks: checks,
	}, nil
}

// validateCompression enforces the fixed zstd policy and bounded provenance text.
func validateCompression(compression CompressionTool) error {
	if compression.Format != "zstd" || compression.Implementation != "zstd-cli" ||
		compression.Level != zstdCompressionLevel || compression.Threads != zstdThreadCount || !compression.ContentChecksum ||
		strings.TrimSpace(compression.Version) == "" || len(compression.Version) > maximumToolVersionBytes || strings.ContainsAny(compression.Version, "\r\n") {
		return errors.New("compressor did not honour the deterministic zstd contract")
	}
	for _, character := range compression.Version {
		if character < 0x20 || character == 0x7f {
			return errors.New("compressor version contains control bytes")
		}
	}
	return nil
}

// renderNotes returns deterministic path-free release guidance.
func renderNotes(manifest Manifest) []byte {
	var output strings.Builder
	_, _ = fmt.Fprintf(&output, "# Surface Pro 11 ARM64 installation image\n\n")
	_, _ = fmt.Fprintf(&output, "This local release contains an experimental, unsigned `%s` hybrid ISO for the Surface Pro 11. It is not hardware-qualified merely because structural validation passed. Disable Secure Boot before using its unsigned custom kernel.\n\n", manifest.StructuralValidation.Adapter)
	_, _ = fmt.Fprintf(&output, "Kernel ABI: `%s`\n\n", manifest.StructuralValidation.KernelABI)
	_, _ = fmt.Fprintf(&output, "## Verify the release directory\n\n```bash\nlinux-armer image release validate .\n```\n\n")
	_, _ = fmt.Fprintf(&output, "`SHA256SUMS` covers the copied image manifest, this note, the release manifest, and every compressed part. `%s` records the path-free image, build, validation, companion-bundle, compression, and part provenance.\n\n", ReleaseManifestName)
	_, _ = fmt.Fprintf(&output, "## Reconstruct the ISO\n\n```bash\ncat %s.part-* | zstd --decompress --stdout > %s\nprintf '%%s  %%s\\n' '%s' '%s' | sha256sum --check -\n```\n\n", manifest.CompressedArchive.Name, manifest.Image.Name, manifest.Image.SHA256, manifest.Image.Name)
	_, _ = fmt.Fprintf(&output, "Use `linux-armer image write %s --device <reviewed-device>` for identity-bound removable-media writing. The release preparation command performs no remote publication.\n", manifest.Image.Name)
	return []byte(output.String())
}

// syncDirectory requests durable publication of one renamed release directory.
// Darwin filesystems which reject directory fsync with EINVAL already provide
// atomic rename semantics, so that platform-specific response is tolerated.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	syncErr := directory.Sync()
	if runtime.GOOS == "darwin" && errors.Is(syncErr, syscall.EINVAL) {
		syncErr = nil
	}
	closeErr := directory.Close()
	return errors.Join(syncErr, closeErr)
}
