package releaseprep

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/companion"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/plan"
)

// fakeValidator returns deterministic structural evidence for one fixture image.
type fakeValidator struct {
	// report is returned unchanged.
	report imagecontract.ValidationReport
	// err optionally simulates adapter failure.
	err error
	// hook optionally changes fixture state after planning and before compression.
	hook func() error
}

// Validate returns the configured structural evidence.
func (validator fakeValidator) Validate(context.Context, string) (imagecontract.ValidationReport, error) {
	if validator.hook != nil {
		if err := validator.hook(); err != nil {
			return imagecontract.ValidationReport{}, err
		}
	}
	return validator.report, validator.err
}

// fakeCompressor uses identity coding while reporting the fixed production policy.
type fakeCompressor struct {
	// fail optionally stops compression before publication.
	fail bool
	// extra makes decompression exceed the declared source length.
	extra bool
}

// Compress copies fixture bytes so tests exercise splitting without external zstd.
func (compressor fakeCompressor) Compress(ctx context.Context, input io.Reader, output io.Writer) (CompressionTool, error) {
	if compressor.fail {
		return CompressionTool{}, errors.New("fixture compression failed")
	}
	if _, err := copyContext(ctx, output, input, maximumImageBytes); err != nil {
		return CompressionTool{}, err
	}
	return CompressionTool{
		Format: "zstd", Implementation: "zstd-cli", Version: "fixture-zstd 1",
		Level: zstdCompressionLevel, Threads: zstdThreadCount, ContentChecksum: true,
	}, nil
}

// Decompress copies fixture identity-coded bytes and can append hostile output.
func (compressor fakeCompressor) Decompress(ctx context.Context, input io.Reader, output io.Writer) error {
	if _, err := copyContext(ctx, output, input, maximumImageBytes); err != nil {
		return err
	}
	if compressor.extra {
		_, err := output.Write([]byte("unexpected"))
		return err
	}
	return nil
}

// fixture records one complete native image output and expected validation report.
type fixture struct {
	// root is the canonical repository fixture root.
	root string
	// image is the fixture ISO path.
	image string
	// report is the matching adapter evidence.
	report imagecontract.ValidationReport
}

// newFixture writes one strict image, manifest, and complete journal contract.
func newFixture(t *testing.T) fixture {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	outputRoot := filepath.Join(root, "build", "linux-armer")
	if err := os.MkdirAll(outputRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	imagePath := filepath.Join(outputRoot, "linux-armer-test.iso")
	imageBytes := bytes.Repeat([]byte("surface-pro-11-image\n"), 13)
	if err := os.WriteFile(imagePath, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	imageDigest := sha256.Sum256(imageBytes)
	digest := hex.EncodeToString(imageDigest[:])
	fixedTime := time.Date(2026, time.August, 30, 12, 0, 0, 0, time.UTC)
	manifest := imagecontract.Manifest{
		SchemaVersion: imagecontract.ManifestSchemaVersion, CreatedAt: fixedTime,
		ToolVersion: "test", Layout: "hybrid-iso", Adapter: "ubuntu-casper",
		SourceImage: imagecontract.ArtifactRecord{Path: "source.iso", SHA256: strings.Repeat("1", 64), Size: 1},
		KernelBundle: kernel.Bundle{
			SchemaVersion: kernel.BundleSchemaVersion, Release: "test", ABI: "1.0-test-qcom-x1e",
			Version: "1.0-test", Architecture: "arm64", Packages: []kernel.Package{},
			DeviceTrees: []kernel.DeviceTree{{Device: "surface-pro-11-x1e-oled", Path: "qcom/test.dtb"}},
		},
		BootArtifacts: imagecontract.BootArtifactRecord{
			Kernel: imagecontract.ArtifactRecord{Path: "casper/vmlinuz", SHA256: strings.Repeat("2", 64), Size: 1},
			Initrd: imagecontract.ArtifactRecord{Path: "casper/initrd", SHA256: strings.Repeat("3", 64), Size: 1},
			DTBs:   []imagecontract.ArtifactRecord{{Path: "sp11/dtb/test.dtb", SHA256: strings.Repeat("4", 64), Size: 1}},
		},
		MediaDiscovery: imagecontract.MediaDiscoveryRecord{
			Strategy: "direct-hybrid", Protocol: "casper", Evidence: []imagecontract.MediaDiscoveryEvidence{},
		},
		CompanionBundle: companion.Absent(companion.OmissionReasonNotRequested),
		BootArguments:   []string{"clk_ignore_unused"}, SecureBoot: "unsupported",
	}
	manifestFile, err := os.Create(imagePath + ".manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := manifest.WriteJSON(manifestFile); err != nil {
		t.Fatal(err)
	}
	if err := manifestFile.Close(); err != nil {
		t.Fatal(err)
	}
	manifestData, err := os.ReadFile(imagePath + ".manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	manifestDigest := sha256.Sum256(manifestData)
	journal := plan.NewJournal("image.create")
	for _, step := range expectedImageSteps {
		digests := map[string]string(nil)
		if step == "validate-output" || step == "publish-output" {
			digests = map[string]string{"output.iso": digest}
		}
		journal.Records = append(journal.Records, plan.StepRecord{StepID: step, CompletedAt: fixedTime, Digests: digests})
	}
	journal.Output = &plan.OutputRecord{Path: imagePath, SHA256: digest, Size: int64(len(imageBytes))}
	journalData, err := json.MarshalIndent(journal, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(imagePath+".journal.json", append(journalData, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	return fixture{
		root: root, image: imagePath,
		report: imagecontract.ValidationReport{
			Valid: true, Path: imagePath, SHA256: digest, Size: int64(len(imageBytes)),
			Layout: "hybrid-iso", Adapter: "ubuntu-casper", KernelABI: "1.0-test-qcom-x1e",
			ManifestSHA256: hex.EncodeToString(manifestDigest[:]), ManifestSize: int64(len(manifestData)),
			DeviceTrees: []string{"surface-pro-11-x1e-oled"},
			Checks:      []imagecontract.ValidationCheck{{Name: "hybrid-layout", Passed: true, Details: imagePath}},
		},
	}
}

// includedCompanionFixture returns one semantically valid companion record
// whose source digest can differ from the manifest embedded in a fixture ISO.
func includedCompanionFixture() imagecontract.CompanionBundleRecord {
	return imagecontract.CompanionBundleRecord{
		Included: true,
		Root:     companion.ISOFilesystemRoot,
		Tool: &imagecontract.ToolIdentityRecord{
			Version: "v0.1.0-test", Commit: "working-tree", BuildDate: "2026-08-30T12:00:00Z",
		},
		ProjectLicence: "not-declared",
		Executable: &imagecontract.ExecutableArtifactRecord{
			Artifact: imagecontract.ArtifactRecord{
				Path: "sp11/companion/bin/linux-arm64/linux-armer", SHA256: strings.Repeat("5", 64), Size: 1,
			},
			OperatingSystem: "linux", Architecture: "arm64", Format: "ELF", Mode: "0755",
		},
		SourceArchive: &imagecontract.ArtifactRecord{
			Path:   "sp11/companion/source/linux-armer_v0.1.0-test_source.tar.gz",
			SHA256: strings.Repeat("6", 64), Size: 1,
		},
		Catalogues: []imagecontract.ArtifactRecord{
			{Path: "sp11/companion/catalogues/supported-isos.json", SHA256: strings.Repeat("7", 64), Size: 1},
			{Path: "sp11/companion/catalogues/supported-userspace.json", SHA256: strings.Repeat("8", 64), Size: 1},
		},
		Userspace: []imagecontract.OfflineUserspaceRecord{},
	}
}

// rewriteFixtureManifest replaces one fixture sidecar with canonical bytes.
func rewriteFixtureManifest(t *testing.T, imagePath string, manifest imagecontract.Manifest) {
	t.Helper()
	file, err := os.OpenFile(imagePath+".manifest.json", os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	writeErr := manifest.WriteJSON(file)
	closeErr := file.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		t.Fatal(err)
	}
}

// readFixtureManifest decodes one fixture sidecar through the production
// bounded, strict manifest decoder.
func readFixtureManifest(t *testing.T, imagePath string) imagecontract.Manifest {
	t.Helper()
	file, err := os.Open(imagePath + ".manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	manifest, decodeErr := imagecontract.DecodeManifest(file)
	closeErr := file.Close()
	if err := errors.Join(decodeErr, closeErr); err != nil {
		t.Fatal(err)
	}
	return manifest
}

// TestPrepareAndValidatePublishesExactRelease exercises the complete local transaction.
func TestPrepareAndValidatePublishesExactRelease(t *testing.T) {
	fixture := newFixture(t)
	manager := New(fakeValidator{report: fixture.report}, fakeCompressor{})
	receipt, err := manager.Prepare(context.Background(), Request{
		RepositoryRoot: fixture.root, ImagePath: fixture.image,
		ReleaseName: "test-release", PartSizeBytes: 31,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !receipt.Published || receipt.Manifest == nil || len(receipt.Manifest.Parts) < 2 {
		t.Fatalf("Prepare() receipt = %#v", receipt)
	}
	result, err := manager.Validate(context.Background(), receipt.Plan.OutputDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Valid || result.Manifest.Image.SHA256 != fixture.report.SHA256 {
		t.Fatalf("Validate() result = %#v", result)
	}
	entries, err := os.ReadDir(receipt.Plan.OutputDirectory)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".journal.json") {
			t.Fatalf("private path-bearing journal was published: %s", entry.Name())
		}
	}
}

// TestPrepareRejectsSidecarEmbeddedCompanionMismatch proves release
// preparation binds the complete adjacent manifest to the bytes extracted from
// the ISO, including a valid but different companion inventory.
func TestPrepareRejectsSidecarEmbeddedCompanionMismatch(t *testing.T) {
	fixture := newFixture(t)
	manifest := readFixtureManifest(t, fixture.image)
	manifest.CompanionBundle = includedCompanionFixture()
	rewriteFixtureManifest(t, fixture.image, manifest)

	manager := New(fakeValidator{report: fixture.report}, fakeCompressor{})
	_, err := manager.Prepare(context.Background(), Request{
		RepositoryRoot: fixture.root, ImagePath: fixture.image,
		ReleaseName: "mismatched-companion", PartSizeBytes: 31,
	})
	if err == nil || !strings.Contains(err.Error(), "embedded image manifest differs") {
		t.Fatalf("Prepare() sidecar mismatch error = %v", err)
	}
	if _, statErr := os.Lstat(filepath.Join(fixture.root, "build", "release", "mismatched-companion")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("mismatched release output exists: %v", statErr)
	}
}

// TestPlanRejectsMalformedCompanionRecord proves release planning applies the
// same mandatory companion schema as image creation and validation.
func TestPlanRejectsMalformedCompanionRecord(t *testing.T) {
	fixture := newFixture(t)
	manifest := readFixtureManifest(t, fixture.image)
	manifest.CompanionBundle.Reason = "not requested"
	rewriteFixtureManifest(t, fixture.image, manifest)

	manager := New(fakeValidator{report: fixture.report}, fakeCompressor{})
	_, err := manager.Plan(context.Background(), Request{
		RepositoryRoot: fixture.root, ImagePath: fixture.image,
		ReleaseName: "malformed-companion", PartSizeBytes: 31,
	})
	if err == nil || !strings.Contains(err.Error(), companion.OmissionReasonNotRequested) {
		t.Fatalf("Plan() malformed companion error = %v", err)
	}
}

// TestPreparationIsDeterministicAcrossRepositoryPaths proves host paths are omitted.
func TestPreparationIsDeterministicAcrossRepositoryPaths(t *testing.T) {
	first := newFixture(t)
	second := newFixture(t)
	firstManager := New(fakeValidator{report: first.report}, fakeCompressor{})
	secondManager := New(fakeValidator{report: second.report}, fakeCompressor{})
	firstReceipt, err := firstManager.Prepare(context.Background(), Request{
		RepositoryRoot: first.root, ImagePath: first.image, ReleaseName: "stable", PartSizeBytes: 29,
	})
	if err != nil {
		t.Fatal(err)
	}
	secondReceipt, err := secondManager.Prepare(context.Background(), Request{
		RepositoryRoot: second.root, ImagePath: second.image, ReleaseName: "stable", PartSizeBytes: 29,
	})
	if err != nil {
		t.Fatal(err)
	}
	firstFiles := directoryBytes(t, firstReceipt.Plan.OutputDirectory)
	secondFiles := directoryBytes(t, secondReceipt.Plan.OutputDirectory)
	if !reflect.DeepEqual(firstFiles, secondFiles) {
		t.Fatal("identical image contracts produced different release bytes")
	}
	for name, contents := range firstFiles {
		if bytes.Contains(contents, []byte(first.root)) || bytes.Contains(contents, []byte(second.root)) {
			t.Fatalf("release file %s contains a host repository path", name)
		}
	}
}

// TestPrepareFailureLeavesNoReleaseOrTransaction proves atomic cleanup.
func TestPrepareFailureLeavesNoReleaseOrTransaction(t *testing.T) {
	fixture := newFixture(t)
	manager := New(fakeValidator{report: fixture.report}, fakeCompressor{fail: true})
	request := Request{
		RepositoryRoot: fixture.root, ImagePath: fixture.image,
		ReleaseName: "failed", PartSizeBytes: 31,
	}
	if _, err := manager.Prepare(context.Background(), request); err == nil {
		t.Fatal("Prepare() succeeded with a failing compressor")
	}
	releaseRoot := filepath.Join(fixture.root, "build", "release")
	entries, err := os.ReadDir(releaseRoot)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("failed preparation left entries: %v", entries)
	}
}

// TestPlanRejectsHostilePathsAndCancellation covers containment and context policy.
func TestPlanRejectsHostilePathsAndCancellation(t *testing.T) {
	fixture := newFixture(t)
	manager := New(fakeValidator{report: fixture.report}, fakeCompressor{})
	contextValue, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := manager.Plan(contextValue, Request{RepositoryRoot: fixture.root, ImagePath: fixture.image}); !errors.Is(err, context.Canceled) {
		t.Fatalf("Plan(cancelled) error = %v", err)
	}
	if _, err := manager.Plan(context.Background(), Request{
		RepositoryRoot: fixture.root, ImagePath: fixture.image,
		ReleaseName: "escape", OutputDirectory: filepath.Join(fixture.root, "escape"),
	}); err == nil {
		t.Fatal("Plan() accepted output outside build/release")
	}
	link := filepath.Join(fixture.root, "linked.iso")
	if err := os.Symlink(fixture.image, link); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Plan(context.Background(), Request{RepositoryRoot: fixture.root, ImagePath: link}); err == nil {
		t.Fatal("Plan() accepted a symbolic-link image")
	}
}

// TestValidateRejectsExtraAndChangedFiles proves the directory is a closed set.
func TestValidateRejectsExtraAndChangedFiles(t *testing.T) {
	fixture := newFixture(t)
	manager := New(fakeValidator{report: fixture.report}, fakeCompressor{})
	receipt, err := manager.Prepare(context.Background(), Request{
		RepositoryRoot: fixture.root, ImagePath: fixture.image,
		ReleaseName: "closed", PartSizeBytes: 31,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(receipt.Plan.OutputDirectory, "undeclared.txt"), []byte("no"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Validate(context.Background(), receipt.Plan.OutputDirectory); err == nil {
		t.Fatal("Validate() accepted an undeclared file")
	}
}

// TestPrepareNeverReplacesConcurrentDestination closes the publication race.
func TestPrepareNeverReplacesConcurrentDestination(t *testing.T) {
	fixture := newFixture(t)
	destination := filepath.Join(fixture.root, "build", "release", "contended")
	validator := fakeValidator{report: fixture.report, hook: func() error {
		if err := os.MkdirAll(destination, 0o755); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(destination, "sentinel"), []byte("preserve"), 0o644)
	}}
	manager := New(validator, fakeCompressor{})
	_, err := manager.Prepare(context.Background(), Request{
		RepositoryRoot: fixture.root, ImagePath: fixture.image,
		ReleaseName: "contended", PartSizeBytes: 31,
	})
	if err == nil {
		t.Fatal("Prepare() replaced a destination created after planning")
	}
	contents, readErr := os.ReadFile(filepath.Join(destination, "sentinel"))
	if readErr != nil || string(contents) != "preserve" {
		t.Fatalf("concurrent destination changed: contents=%q error=%v", contents, readErr)
	}
}

// TestValidateBoundsChecksumsAndDecompression rejects resource-exhaustion inputs.
func TestValidateBoundsChecksumsAndDecompression(t *testing.T) {
	fixture := newFixture(t)
	manager := New(fakeValidator{report: fixture.report}, fakeCompressor{})
	receipt, err := manager.Prepare(context.Background(), Request{
		RepositoryRoot: fixture.root, ImagePath: fixture.image,
		ReleaseName: "bounded", PartSizeBytes: 31,
	})
	if err != nil {
		t.Fatal(err)
	}
	overlongManager := New(fakeValidator{report: fixture.report}, fakeCompressor{extra: true})
	if _, err := overlongManager.Validate(context.Background(), receipt.Plan.OutputDirectory); err == nil {
		t.Fatal("Validate() accepted decompression beyond the declared ISO size")
	}
	checksumPath := filepath.Join(receipt.Plan.OutputDirectory, ChecksumName)
	checksumFile, err := os.OpenFile(checksumPath, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	truncateErr := checksumFile.Truncate(maximumTextBytes + 1)
	closeErr := checksumFile.Close()
	if err := errors.Join(truncateErr, closeErr); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Validate(context.Background(), receipt.Plan.OutputDirectory); err == nil {
		t.Fatal("Validate() accepted an overlong SHA256SUMS file")
	}
}

// TestStrictJSONRejectsDuplicatesAndExcessiveDepth covers parser ambiguity bounds.
func TestStrictJSONRejectsDuplicatesAndExcessiveDepth(t *testing.T) {
	var target map[string]any
	if err := decodeStrictJSON([]byte(`{"value":1,"value":2}`), &target); err == nil {
		t.Fatal("decodeStrictJSON() accepted a duplicate field")
	}
	deep := strings.Repeat("[", maximumJSONDepth+2) + "0" + strings.Repeat("]", maximumJSONDepth+2)
	if err := decodeStrictJSON([]byte(deep), &target); err == nil {
		t.Fatal("decodeStrictJSON() accepted excessive nesting")
	}
}

// directoryBytes returns lexical regular-file contents for deterministic comparison.
func directoryBytes(t *testing.T, directory string) map[string][]byte {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	result := make(map[string][]byte, len(names))
	for _, name := range names {
		contents, err := os.ReadFile(filepath.Join(directory, name))
		if err != nil {
			t.Fatal(err)
		}
		result[name] = contents
	}
	return result
}
