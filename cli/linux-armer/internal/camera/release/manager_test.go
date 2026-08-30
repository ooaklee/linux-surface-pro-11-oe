package release

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	camerabuild "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/camera/build"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// rejectingRunner proves local release generation invokes no unexpected command.
type rejectingRunner struct{}

// Run rejects every command because tests inject the already validated bundle.
func (rejectingRunner) Run(context.Context, platform.Command) error {
	return errors.New("unexpected release command")
}

// Capture rejects every command because tests inject the already validated bundle.
func (rejectingRunner) Capture(context.Context, platform.Command) ([]byte, error) {
	return nil, errors.New("unexpected release command")
}

// releaseFixture contains one path-free bundle and its local directories.
type releaseFixture struct {
	root         string
	artifacts    string
	bundle       camerabuild.BundleReceipt
	authoritySHA string
}

// makeReleaseFixture creates exactly eight regular build artefacts beneath a repo.
func makeReleaseFixture(t *testing.T) releaseFixture {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	artifacts := filepath.Join(root, "build/linux-armer/camera/packages/build.fixture")
	if err := os.MkdirAll(artifacts, 0o700); err != nil {
		t.Fatal(err)
	}
	version := "0.7.0-1ubuntu2+sp11.2.20260830123456." + strings.Repeat("1", 24)
	bundle := camerabuild.BundleReceipt{
		SchemaVersion:     camerabuild.SchemaVersion,
		Status:            "verified",
		BuildID:           "20260830123456." + strings.Repeat("1", 24),
		PackageVersion:    version,
		BuiltAt:           time.Date(2026, 8, 30, 12, 34, 56, 0, time.UTC),
		SupportCommit:     strings.Repeat("a", 40),
		SupportCommitTime: time.Date(2026, 8, 30, 11, 0, 0, 0, time.UTC),
		Source: camerabuild.SourceProvenance{
			UpstreamRepository:  "https://git.libcamera.org/libcamera/libcamera.git",
			UpstreamTag:         "v0.7.0",
			UpstreamCommit:      strings.Repeat("b", 40),
			UbuntuVersion:       "0.7.0-1ubuntu2",
			UbuntuSeries:        "resolute",
			SourceURL:           "https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/libcamera/0.7.0-1ubuntu2",
			DSC:                 camerabuild.SourceFile{Name: "libcamera_0.7.0-1ubuntu2.dsc", SHA256: strings.Repeat("1", 64)},
			OrigTarball:         camerabuild.SourceFile{Name: "libcamera_0.7.0.orig.tar.gz", SHA256: strings.Repeat("2", 64)},
			DebianTarball:       camerabuild.SourceFile{Name: "libcamera_0.7.0-1ubuntu2.debian.tar.xz", SHA256: strings.Repeat("3", 64)},
			CopyrightFileSHA256: strings.Repeat("4", 64),
			CopyrightFileSize:   4096,
			LicenceEvidence:     []string{"Authenticated Ubuntu source debian/copyright", "Runtime package copyright records"},
		},
		Verification: camerabuild.Verification{
			ChangesClosedSet:         true,
			DeliveredChangesVerified: true,
			TuningIdentityVerified:   true,
			SameBuildIPAVerified:     true,
		},
	}
	for _, packageName := range camerabuild.RuntimePackageNames() {
		name := packageName + "_" + version + "_arm64.deb"
		bundle.Artifacts = append(bundle.Artifacts, writeFixtureFile(t, artifacts, name, []byte("package:"+packageName)))
	}
	bundle.Artifacts = append(bundle.Artifacts,
		writeFixtureFile(t, artifacts, "libcamera_"+version+"_arm64.changes", []byte("changes")),
		writeFixtureFile(t, artifacts, "libcamera_"+version+"_arm64.buildinfo", []byte("buildinfo")),
	)
	receipt, err := json.MarshalIndent(bundle, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(artifacts, camerabuild.ReceiptName), append(receipt, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	authority := sha256.Sum256(append(receipt, '\n'))
	return releaseFixture{root: root, artifacts: artifacts, bundle: bundle, authoritySHA: hex.EncodeToString(authority[:])}
}

// writeFixtureFile creates one artefact and returns matching receipt metadata.
func writeFixtureFile(t *testing.T, directory, name string, data []byte) camerabuild.Artifact {
	t.Helper()
	if err := os.WriteFile(filepath.Join(directory, name), data, 0o644); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	return camerabuild.Artifact{Name: name, SHA256: hex.EncodeToString(digest[:]), Size: int64(len(data))}
}

// fixtureRequest returns the explicit current-generation release pairing.
func fixtureRequest(fixture releaseFixture) Request {
	return Request{
		RepositoryRoot:               fixture.root,
		ArtifactsDirectory:           fixture.artifacts,
		Tag:                          "sp11-imx681-libcamera-v2",
		KernelTag:                    "sp11-qcom-x1e-7.2.0-jg-0sp11v19",
		KernelABI:                    "7.2.0-jg-0sp11v19-qcom-x1e",
		ExpectedBuildAuthoritySHA256: fixture.authoritySHA,
	}
}

// executableReleaseManager returns a deterministic manager with injected proof.
func executableReleaseManager(bundle camerabuild.BundleReceipt) *Manager {
	manager := New(rejectingRunner{})
	manager.now = func() time.Time { return time.Date(2026, 8, 30, 15, 0, 0, 0, time.UTC) }
	manager.validate = func(context.Context, platform.Runner, camerabuild.ValidationRequest) (camerabuild.BundleReceipt, error) {
		return bundle, nil
	}
	return manager
}

// TestPlanIsDeterministicLocalAndExplicit verifies release policy has no v14 default.
func TestPlanIsDeterministicLocalAndExplicit(t *testing.T) {
	fixture := makeReleaseFixture(t)
	manager := executableReleaseManager(fixture.bundle)
	request := fixtureRequest(fixture)
	request.DryRun = true
	first, err := manager.Plan(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := manager.Plan(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(first, second) || first.MutatesRemote || !first.Executable {
		t.Fatalf("unexpected release plan: %+v", first)
	}
	if first.ExpectedBuildAuthoritySHA256 != fixture.authoritySHA {
		t.Fatalf("release plan omitted build authority: %+v", first)
	}
	dryReceipt, err := manager.Prepare(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if dryReceipt.Published || dryReceipt.AuthoritySHA256 != "" {
		t.Fatalf("dry-run published an authority: %+v", dryReceipt)
	}
	emptyPairing := request
	emptyPairing.KernelTag = ""
	if _, err := manager.Plan(context.Background(), emptyPairing); err == nil {
		t.Fatal("missing explicit kernel pairing passed")
	}
}

// TestPrepareCreatesClosedElevenFileRelease verifies local atomic preparation.
func TestPrepareCreatesClosedElevenFileRelease(t *testing.T) {
	fixture := makeReleaseFixture(t)
	manager := executableReleaseManager(fixture.bundle)
	var validationRequests []camerabuild.ValidationRequest
	manager.validate = func(_ context.Context, _ platform.Runner, request camerabuild.ValidationRequest) (camerabuild.BundleReceipt, error) {
		request.AdditionalFiles = append([]string(nil), request.AdditionalFiles...)
		validationRequests = append(validationRequests, request)
		return fixture.bundle, nil
	}
	receipt, err := manager.Prepare(context.Background(), fixtureRequest(fixture))
	if err != nil {
		t.Fatal(err)
	}
	if !receipt.Published || receipt.Manifest == nil || receipt.Manifest.RemoteMutation {
		t.Fatalf("incomplete local release receipt: %+v", receipt)
	}
	if len(validationRequests) != 1 || validationRequests[0].ExpectedAuthoritySHA256 != fixture.authoritySHA || len(validationRequests[0].AdditionalFiles) != 0 {
		t.Fatalf("release preparation build authority hand-off = %+v", validationRequests)
	}
	manifestAuthority, err := os.ReadFile(filepath.Join(receipt.Plan.ReleaseDirectory, ManifestName))
	if err != nil {
		t.Fatal(err)
	}
	manifestDigest := sha256.Sum256(manifestAuthority)
	if receipt.AuthoritySHA256 != hex.EncodeToString(manifestDigest[:]) {
		t.Fatalf("release authority digest = %q", receipt.AuthoritySHA256)
	}
	entries, err := os.ReadDir(receipt.Plan.ReleaseDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 11 || len(receipt.Manifest.BuildArtifacts) != 8 || len(receipt.Manifest.GeneratedFiles) != 2 {
		t.Fatalf("release shape entries=%d manifest=%+v", len(entries), receipt.Manifest)
	}
	checksums, err := os.ReadFile(filepath.Join(receipt.Plan.ReleaseDirectory, ChecksumName))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(checksums), "\n") != 8 {
		t.Fatalf("checksum entries = %q", checksums)
	}
	notes, err := os.ReadFile(filepath.Join(receipt.Plan.ReleaseDirectory, NotesName))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(notes), "sp11v14") || !strings.Contains(string(notes), "sp11v19") || !strings.Contains(string(notes), "licence provenance") {
		t.Fatalf("release notes do not express current explicit provenance:\n%s", notes)
	}
	manifestData, err := os.ReadFile(filepath.Join(receipt.Plan.ReleaseDirectory, ManifestName))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(manifestData), fixture.root) || !strings.Contains(string(manifestData), fixture.bundle.Source.CopyrightFileSHA256) {
		t.Fatal("structured manifest leaked a local path or omitted copyright evidence")
	}
	if strings.Contains(string(manifestData), "authority_sha256") {
		t.Fatal("release manifest contains a self-digest")
	}
	validated, err := manager.Validate(context.Background(), ValidationRequest{
		RepositoryRoot:          fixture.root,
		Directory:               receipt.Plan.ReleaseDirectory,
		ExpectedAuthoritySHA256: receipt.AuthoritySHA256,
	})
	if err != nil {
		t.Fatal(err)
	}
	if validated.Manifest.Tag != receipt.Manifest.Tag || validated.Directory != receipt.Plan.ReleaseDirectory {
		t.Fatalf("validation receipt = %+v", validated)
	}
	if len(validationRequests) != 2 || validationRequests[1].ExpectedAuthoritySHA256 != fixture.authoritySHA || !reflect.DeepEqual(validationRequests[1].AdditionalFiles, []string{ChecksumName, NotesName, ManifestName}) {
		t.Fatalf("release validation build authority hand-off = %+v", validationRequests)
	}
}

// TestValidateStaticIsReadOnlyAndRequiresAuthority verifies host-independent
// validation, the enclosing closed set, and the independent manifest hand-off.
func TestValidateStaticIsReadOnlyAndRequiresAuthority(t *testing.T) {
	fixture := makeReleaseFixture(t)
	manager := executableReleaseManager(fixture.bundle)
	receipt, err := manager.Prepare(context.Background(), fixtureRequest(fixture))
	if err != nil {
		t.Fatal(err)
	}
	before := snapshotReleaseDirectory(t, receipt.Plan.ReleaseDirectory)
	validated, err := manager.ValidateStatic(context.Background(), ValidationRequest{
		RepositoryRoot:          fixture.root,
		Directory:               receipt.Plan.ReleaseDirectory,
		ExpectedAuthoritySHA256: receipt.AuthoritySHA256,
	})
	if err != nil {
		t.Fatal(err)
	}
	if validated.Manifest.Tag != receipt.Manifest.Tag {
		t.Fatalf("static validation receipt = %+v", validated)
	}
	after := snapshotReleaseDirectory(t, receipt.Plan.ReleaseDirectory)
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("static validation changed release files:\nbefore=%v\nafter=%v", before, after)
	}
	request := ValidationRequest{RepositoryRoot: fixture.root, Directory: receipt.Plan.ReleaseDirectory}
	if _, err := manager.ValidateStatic(context.Background(), request); err == nil {
		t.Fatal("static release validation accepted a missing manifest authority")
	}
	request.ExpectedAuthoritySHA256 = strings.Repeat("0", 64)
	if _, err := manager.Validate(context.Background(), request); err == nil {
		t.Fatal("release validation accepted a mismatched manifest authority")
	}
}

// snapshotReleaseDirectory records names and digests without changing a fixture.
func snapshotReleaseDirectory(t *testing.T, directory string) map[string]string {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	snapshot := make(map[string]string, len(entries))
	for _, entry := range entries {
		data, err := os.ReadFile(filepath.Join(directory, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(data)
		snapshot[entry.Name()] = hex.EncodeToString(digest[:])
	}
	return snapshot
}

// TestPrepareRejectsLinksAndCollision verifies no prior release is overwritten.
func TestPrepareRejectsLinksAndCollision(t *testing.T) {
	fixture := makeReleaseFixture(t)
	request := fixtureRequest(fixture)
	packagePath := filepath.Join(fixture.artifacts, fixture.bundle.Artifacts[0].Name)
	if err := os.Remove(packagePath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(camerabuild.ReceiptName, packagePath); err != nil {
		t.Fatal(err)
	}
	if _, err := executableReleaseManager(fixture.bundle).Prepare(context.Background(), request); err == nil {
		t.Fatal("symbolic-link build artefact passed release preparation")
	}
	fixture = makeReleaseFixture(t)
	request = fixtureRequest(fixture)
	releaseDirectory := filepath.Join(fixture.root, DefaultOutputDirectory, request.Tag)
	if err := os.MkdirAll(releaseDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := executableReleaseManager(fixture.bundle).Prepare(context.Background(), request); err == nil || !strings.Contains(err.Error(), "atomically publish") {
		t.Fatalf("collision error = %v", err)
	}
}

// TestPrepareCancellationWithholdsOutput verifies validator interruption is safe.
func TestPrepareCancellationWithholdsOutput(t *testing.T) {
	fixture := makeReleaseFixture(t)
	manager := executableReleaseManager(fixture.bundle)
	manager.validate = func(context.Context, platform.Runner, camerabuild.ValidationRequest) (camerabuild.BundleReceipt, error) {
		return camerabuild.BundleReceipt{}, context.Canceled
	}
	receipt, err := manager.Prepare(context.Background(), fixtureRequest(fixture))
	if !errors.Is(err, context.Canceled) || receipt.Published {
		t.Fatalf("cancelled release receipt = %+v, error = %v", receipt, err)
	}
	if _, statErr := os.Lstat(receipt.Plan.ReleaseDirectory); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("cancelled release left output: %v", statErr)
	}
}

// TestValidateRejectsGeneratedFileMutation verifies release records are bound.
func TestValidateRejectsGeneratedFileMutation(t *testing.T) {
	fixture := makeReleaseFixture(t)
	manager := executableReleaseManager(fixture.bundle)
	receipt, err := manager.Prepare(context.Background(), fixtureRequest(fixture))
	if err != nil {
		t.Fatal(err)
	}
	notes := filepath.Join(receipt.Plan.ReleaseDirectory, NotesName)
	if err := os.WriteFile(notes, []byte("altered notes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Validate(context.Background(), ValidationRequest{RepositoryRoot: fixture.root, Directory: receipt.Plan.ReleaseDirectory, ExpectedAuthoritySHA256: receipt.AuthoritySHA256}); err == nil {
		t.Fatal("mutated release notes passed validation")
	}
}

// TestHostileReleaseNamesAndRoutesFail verifies terminal and traversal input rejection.
func TestHostileReleaseNamesAndRoutesFail(t *testing.T) {
	fixture := makeReleaseFixture(t)
	manager := executableReleaseManager(fixture.bundle)
	for name, mutate := range map[string]func(*Request){
		"bidirectional tag": func(request *Request) { request.Tag = "release\u202evil" },
		"output traversal":  func(request *Request) { request.OutputDirectory = "../release" },
		"mismatched kernel": func(request *Request) { request.KernelTag = "sp11-qcom-x1e-other" },
		"missing authority": func(request *Request) { request.ExpectedBuildAuthoritySHA256 = "" },
	} {
		t.Run(name, func(t *testing.T) {
			request := fixtureRequest(fixture)
			mutate(&request)
			if _, err := manager.Plan(context.Background(), request); err == nil {
				t.Fatal("hostile release request passed")
			}
		})
	}
}
