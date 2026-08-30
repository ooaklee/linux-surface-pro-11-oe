package release

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// releaseFixture contains one complete small source tree and matching policy.
type releaseFixture struct {
	// repositoryRoot is the isolated local publication boundary.
	repositoryRoot string
	// sourceRoot is the isolated pinned-source checkout.
	sourceRoot string
	// request is the complete valid preparation request.
	request Request
	// policy is the fixture-specific immutable release contract.
	policy policy
}

// TestPrepareValidateAndDeterminism verifies the closed seven-file happy path.
func TestPrepareValidateAndDeterminism(t *testing.T) {
	t.Parallel()
	first := newReleaseFixture(t)
	firstManager := newManagerWithPolicy(first.policy)
	firstReceipt, err := firstManager.Prepare(context.Background(), first.request)
	if err != nil {
		t.Fatalf("Prepare() error = %v", err)
	}
	if !firstReceipt.Published || firstReceipt.Manifest == nil || firstReceipt.Plan.MutatesRemote {
		t.Fatalf("Prepare() receipt = %+v", firstReceipt)
	}
	entries, err := os.ReadDir(firstReceipt.Plan.ReleaseDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 7 {
		t.Fatalf("release entries = %d, want 7", len(entries))
	}
	validated, err := firstManager.Validate(context.Background(), ValidationRequest{
		RepositoryRoot: first.repositoryRoot, Directory: firstReceipt.Plan.ReleaseDirectory,
	})
	if err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	if !validated.Valid || !reflect.DeepEqual(validated.Manifest, *firstReceipt.Manifest) {
		t.Fatalf("Validate() receipt = %+v", validated)
	}
	manifestData, err := os.ReadFile(filepath.Join(firstReceipt.Plan.ReleaseDirectory, ManifestName))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(manifestData, []byte(first.repositoryRoot)) || bytes.Contains(manifestData, []byte(first.sourceRoot)) {
		t.Fatalf("manifest contains a host path:\n%s", manifestData)
	}

	second := newReleaseFixture(t)
	secondManager := newManagerWithPolicy(second.policy)
	secondReceipt, err := secondManager.Prepare(context.Background(), second.request)
	if err != nil {
		t.Fatalf("second Prepare() error = %v", err)
	}
	for _, name := range []string{ChecksumName, NotesName, ManifestName} {
		firstData, readErr := os.ReadFile(filepath.Join(firstReceipt.Plan.ReleaseDirectory, name))
		if readErr != nil {
			t.Fatal(readErr)
		}
		secondData, readErr := os.ReadFile(filepath.Join(secondReceipt.Plan.ReleaseDirectory, name))
		if readErr != nil {
			t.Fatal(readErr)
		}
		if !bytes.Equal(firstData, secondData) {
			t.Errorf("%s differs across host roots", name)
		}
	}
}

// TestPlanRejectsUntrustedSourceAndPathInputs verifies strict source boundaries.
func TestPlanRejectsUntrustedSourceAndPathInputs(t *testing.T) {
	t.Parallel()
	t.Run("checksum mismatch", func(t *testing.T) {
		t.Parallel()
		fixture := newReleaseFixture(t)
		checksumPath := filepath.Join(fixture.sourceRoot, filepath.FromSlash(fixture.policy.checksumRelativePath))
		data, err := os.ReadFile(checksumPath)
		if err != nil {
			t.Fatal(err)
		}
		data[0] = alternateHex(data[0])
		if err := os.WriteFile(checksumPath, data, 0o644); err != nil {
			t.Fatal(err)
		}
		_, err = newManagerWithPolicy(fixture.policy).Plan(context.Background(), fixture.request)
		if err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
			t.Fatalf("Plan() error = %v", err)
		}
	})
	t.Run("checksum traversal", func(t *testing.T) {
		t.Parallel()
		fixture := newReleaseFixture(t)
		checksumPath := filepath.Join(fixture.sourceRoot, filepath.FromSlash(fixture.policy.checksumRelativePath))
		line := strings.Repeat("0", 64) + "  ../escape\n"
		if err := os.WriteFile(checksumPath, []byte(line), 0o644); err != nil {
			t.Fatal(err)
		}
		_, err := newManagerWithPolicy(fixture.policy).Plan(context.Background(), fixture.request)
		if err == nil || !strings.Contains(err.Error(), "unsafe name") {
			t.Fatalf("Plan() error = %v", err)
		}
	})
	t.Run("symbolic source", func(t *testing.T) {
		t.Parallel()
		fixture := newReleaseFixture(t)
		hifi := filepath.Join(fixture.sourceRoot, filepath.FromSlash(fixture.policy.sources[2].relativePath))
		real := hifi + ".real"
		if err := os.Rename(hifi, real); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(real, hifi); err != nil {
			t.Skipf("symbolic links unavailable: %v", err)
		}
		_, err := newManagerWithPolicy(fixture.policy).Plan(context.Background(), fixture.request)
		if err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Fatalf("Plan() error = %v", err)
		}
	})
	t.Run("symbolic output route", func(t *testing.T) {
		t.Parallel()
		fixture := newReleaseFixture(t)
		outside := t.TempDir()
		if err := os.Symlink(outside, filepath.Join(fixture.repositoryRoot, "build")); err != nil {
			t.Skipf("symbolic links unavailable: %v", err)
		}
		_, err := newManagerWithPolicy(fixture.policy).Plan(context.Background(), fixture.request)
		if err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Fatalf("Plan() error = %v", err)
		}
	})
}

// TestPrepareFailsClosedOnCancellationCollisionAndSourceChange verifies races.
func TestPrepareFailsClosedOnCancellationCollisionAndSourceChange(t *testing.T) {
	t.Parallel()
	t.Run("cancellation before publication", func(t *testing.T) {
		t.Parallel()
		fixture := newReleaseFixture(t)
		ctx, cancel := context.WithCancel(context.Background())
		manager := newManagerWithPolicy(fixture.policy)
		manager.beforePublish = func(_ context.Context, _ Plan) error {
			cancel()
			return nil
		}
		_, err := manager.Prepare(ctx, fixture.request)
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Prepare() error = %v", err)
		}
		assertNoReleaseOrTransaction(t, fixture)
	})
	t.Run("destination collision", func(t *testing.T) {
		t.Parallel()
		fixture := newReleaseFixture(t)
		manager := newManagerWithPolicy(fixture.policy)
		manager.beforePublish = func(_ context.Context, plan Plan) error {
			if err := os.Mkdir(plan.ReleaseDirectory, 0o755); err != nil {
				return err
			}
			return os.WriteFile(filepath.Join(plan.ReleaseDirectory, "sentinel"), []byte("owned\n"), 0o644)
		}
		_, err := manager.Prepare(context.Background(), fixture.request)
		if err == nil || !strings.Contains(err.Error(), "atomically publish") {
			t.Fatalf("Prepare() error = %v", err)
		}
		data, readErr := os.ReadFile(filepath.Join(fixture.repositoryRoot, filepath.FromSlash(DefaultOutputDirectory), fixture.policy.tag, "sentinel"))
		if readErr != nil || string(data) != "owned\n" {
			t.Fatalf("collision sentinel = %q, %v", data, readErr)
		}
	})
	t.Run("source changes after planning", func(t *testing.T) {
		t.Parallel()
		fixture := newReleaseFixture(t)
		manager := newManagerWithPolicy(fixture.policy)
		manager.afterPlan = func(_ Plan) error {
			path := filepath.Join(fixture.sourceRoot, filepath.FromSlash(fixture.policy.sources[0].relativePath))
			return os.WriteFile(path, []byte("changed after validation\n"), 0o644)
		}
		_, err := manager.Prepare(context.Background(), fixture.request)
		if err == nil || !strings.Contains(err.Error(), "changed") {
			t.Fatalf("Prepare() error = %v", err)
		}
		assertNoReleaseOrTransaction(t, fixture)
	})
}

// TestValidateRejectsTamperingAndAmbiguousJSON verifies closed-set validation.
func TestValidateRejectsTamperingAndAmbiguousJSON(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		mutate func(*testing.T, string)
		match  string
	}{
		{name: "extra file", mutate: func(t *testing.T, directory string) {
			t.Helper()
			if err := os.WriteFile(filepath.Join(directory, "extra"), []byte("extra\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}, match: "8 entries"},
		{name: "changed topology", mutate: func(t *testing.T, directory string) {
			t.Helper()
			if err := os.WriteFile(filepath.Join(directory, TopologyName), []byte("changed\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}, match: "differs"},
		{name: "symbolic notes", mutate: func(t *testing.T, directory string) {
			t.Helper()
			notes := filepath.Join(directory, NotesName)
			if err := os.Remove(notes); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(ChecksumName, notes); err != nil {
				t.Skipf("symbolic links unavailable: %v", err)
			}
		}, match: "not a real regular file"},
		{name: "duplicate manifest member", mutate: func(t *testing.T, directory string) {
			t.Helper()
			path := filepath.Join(directory, ManifestName)
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			data = bytes.Replace(data, []byte("{\n"), []byte("{\n  \"schema_version\": 1,\n"), 1)
			if err := os.WriteFile(path, data, 0o644); err != nil {
				t.Fatal(err)
			}
		}, match: "duplicate JSON member"},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := newReleaseFixture(t)
			manager := newManagerWithPolicy(fixture.policy)
			receipt, err := manager.Prepare(context.Background(), fixture.request)
			if err != nil {
				t.Fatal(err)
			}
			test.mutate(t, receipt.Plan.ReleaseDirectory)
			_, err = manager.Validate(context.Background(), ValidationRequest{RepositoryRoot: fixture.repositoryRoot, Directory: receipt.Plan.ReleaseDirectory})
			if err == nil || !strings.Contains(err.Error(), test.match) {
				t.Fatalf("Validate() error = %v, want %q", err, test.match)
			}
		})
	}
}

// TestMatcherAndProductionChecksumContracts verifies exact deterministic rendering.
func TestMatcherAndProductionChecksumContracts(t *testing.T) {
	t.Parallel()
	base := []byte("Syntax 6\nDefine.DMI_info \"${sys:devices/virtual/dmi/id/sys_vendor}\"\nSectionUseCase.0 {}\n")
	matcher, err := generateMatcher(base)
	if err != nil {
		t.Fatal(err)
	}
	want := "Syntax 6\nDefine.DMI_info \"${sys:devices/virtual/dmi/id/sys_vendor}\"\n" + matcherBranch + "SectionUseCase.0 {}\n"
	if string(matcher) != want {
		t.Fatalf("matcher =\n%s\nwant:\n%s", matcher, want)
	}
	selected := productionPolicy()
	records := make([]FileRecord, 0, len(selected.artefacts))
	for _, artefact := range selected.artefacts {
		records = append(records, FileRecord{Name: artefact.name, SHA256: artefact.sha256, Size: artefact.size})
	}
	checksums, err := renderChecksums(records)
	if err != nil {
		t.Fatal(err)
	}
	if actual := inspectData(ChecksumName, checksums); actual.SHA256 != "e490d2ca28278442f12d376b579db13b2b46060b28c7e040b67370161c8588f2" || actual.Size != 368 {
		t.Fatalf("production SHA256SUMS identity = %+v", actual)
	}
}

// TestStrictParsersRejectDuplicatesAndDepth verifies bounded ambiguous input handling.
func TestStrictParsersRejectDuplicatesAndDepth(t *testing.T) {
	t.Parallel()
	if _, err := parseSourceChecksums([]byte(strings.Repeat("0", 64) + "  payload\n" + strings.Repeat("1", 64) + "  payload\n")); err == nil || !strings.Contains(err.Error(), "repeats") {
		t.Fatalf("duplicate checksum error = %v", err)
	}
	deep := strings.Repeat("[", maximumJSONDepth+2) + "0" + strings.Repeat("]", maximumJSONDepth+2)
	if err := rejectDuplicateJSONNames([]byte(deep)); err == nil || !strings.Contains(err.Error(), "nesting") {
		t.Fatalf("deep JSON error = %v", err)
	}
}

// newReleaseFixture creates a complete small source tree and matching pins.
func newReleaseFixture(t *testing.T) releaseFixture {
	t.Helper()
	repositoryRoot := canonicalTemporaryDirectory(t)
	sourceRoot := canonicalTemporaryDirectory(t)
	topology := []byte("fixture topology\n")
	card := []byte("fixture card UCM\n")
	hifi := []byte("fixture HiFi UCM\n")
	base := []byte("Syntax 6\nDefine.DMI_info \"${sys:devices/virtual/dmi/id/sys_vendor}\"\nSectionUseCase.0 {}\n")
	matcher, err := generateMatcher(base)
	if err != nil {
		t.Fatal(err)
	}
	sources := []sourceSpec{
		{role: "topology", relativePath: "deploy/native-audio-v19c/X1E80100-Microsoft-Surface-Pro-11-FullIO-v19c0-tplg.bin", releaseName: TopologyName, sha256: digestBytes(topology), expectedSize: int64(len(topology))},
		{role: "card-ucm", relativePath: "deploy/ucm2/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11in.conf", releaseName: CardUCMName, sha256: digestBytes(card), expectedSize: int64(len(card))},
		{role: "hifi-ucm", relativePath: "deploy/ucm2/Qualcomm/x1e80100/SP11-HiFi.conf", releaseName: HiFiUCMName, sha256: digestBytes(hifi), expectedSize: int64(len(hifi))},
		{role: "matcher-base", relativePath: "deploy/ucm2/Qualcomm/x1e80100/x1e80100.conf.upstream-1.2.15.3-1ubuntu1.4", sha256: digestBytes(base)},
	}
	for index, data := range [][]byte{topology, card, hifi, base} {
		path := filepath.Join(sourceRoot, filepath.FromSlash(sources[index].relativePath))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	nativeDirectory := filepath.Join(sourceRoot, "deploy", "native-audio-v19c")
	extra := []byte("bounded source evidence\n")
	if err := os.WriteFile(filepath.Join(nativeDirectory, "evidence.txt"), extra, 0o644); err != nil {
		t.Fatal(err)
	}
	checksumData := []byte(sources[0].sha256 + "  " + filepath.Base(sources[0].relativePath) + "\n" + digestBytes(extra) + "  evidence.txt\n")
	if err := os.WriteFile(filepath.Join(nativeDirectory, ChecksumName), checksumData, 0o644); err != nil {
		t.Fatal(err)
	}
	artefacts := []artefactSpec{
		{name: TopologyName, sha256: digestBytes(topology), size: int64(len(topology))},
		{name: CardUCMName, sha256: digestBytes(card), size: int64(len(card))},
		{name: HiFiUCMName, sha256: digestBytes(hifi), size: int64(len(hifi))},
		{name: MatcherName, sha256: digestBytes(matcher), size: int64(len(matcher))},
	}
	records := make([]FileRecord, 0, len(artefacts))
	for _, artefact := range artefacts {
		records = append(records, FileRecord{Name: artefact.name, SHA256: artefact.sha256, Size: artefact.size})
	}
	releaseChecksums, err := renderChecksums(records)
	if err != nil {
		t.Fatal(err)
	}
	selected := policy{
		tag: "sp11-audio-v19c-test", sourceRelease: "fixture-v19c", sourceRevision: strings.Repeat("a", 40),
		checksumRelativePath: "deploy/native-audio-v19c/SHA256SUMS", sources: sources, artefacts: artefacts,
		checksum: artefactSpec{name: ChecksumName, sha256: digestBytes(releaseChecksums), size: int64(len(releaseChecksums))},
	}
	return releaseFixture{
		repositoryRoot: repositoryRoot, sourceRoot: sourceRoot, policy: selected,
		request: Request{
			RepositoryRoot: repositoryRoot, SourceRoot: sourceRoot, Tag: selected.tag,
			KernelTag: "sp11-qcom-x1e-7.2.0-jg-0sp11v19", KernelABI: "7.2.0-jg-0sp11v19-qcom-x1e",
		},
	}
}

// canonicalTemporaryDirectory resolves the operating system's temporary alias.
func canonicalTemporaryDirectory(t *testing.T) string {
	t.Helper()
	directory, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return directory
}

// digestBytes returns the lowercase SHA-256 identity for test bytes.
func digestBytes(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

// alternateHex changes one valid hexadecimal byte without making it malformed.
func alternateHex(value byte) byte {
	if value == '0' {
		return '1'
	}
	return '0'
}

// assertNoReleaseOrTransaction checks cleanup after failed preparation.
func assertNoReleaseOrTransaction(t *testing.T, fixture releaseFixture) {
	t.Helper()
	releaseRoot := filepath.Join(fixture.repositoryRoot, filepath.FromSlash(DefaultOutputDirectory))
	if _, err := os.Lstat(filepath.Join(releaseRoot, fixture.policy.tag)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("final release exists after failure: %v", err)
	}
	entries, err := os.ReadDir(releaseRoot)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".linux-armer-audio-") {
			t.Fatalf("private transaction remains after failure: %s", entry.Name())
		}
	}
}
