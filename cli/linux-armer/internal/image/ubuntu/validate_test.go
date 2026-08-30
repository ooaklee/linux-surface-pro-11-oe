package ubuntu

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/companion"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// companionISOValidationRunner simulates only the xorriso listing and
// extraction calls made by the focused companion validation boundary.
type companionISOValidationRunner struct {
	listing    []byte
	captureErr error
	runErr     error
	commands   []platform.Command
}

// Run records a simulated companion extraction and returns its configured
// result without changing the pre-staged validation fixture.
func (runner *companionISOValidationRunner) Run(_ context.Context, command platform.Command) error {
	runner.commands = append(runner.commands, command)
	return runner.runErr
}

// Capture records a simulated /sp11 directory listing and returns the
// configured xorriso output.
func (runner *companionISOValidationRunner) Capture(_ context.Context, command platform.Command) ([]byte, error) {
	runner.commands = append(runner.commands, command)
	return runner.listing, runner.captureErr
}

// TestValidateCompanionBundleAcceptsExplicitAbsence verifies an omitted
// companion passes only when the reserved media directory is genuinely absent.
func TestValidateCompanionBundleAcceptsExplicitAbsence(t *testing.T) {
	runner := &companionISOValidationRunner{listing: []byte("'README.txt'\n'dtb'\n'kernel'\n")}
	validator := NewValidator(platform.NewDocker(runner))
	record := companion.Absent(companion.OmissionReasonNotRequested)

	checks := validator.validateCompanionBundle(
		context.Background(), "tools:test", t.TempDir(), record, companion.ValidateRecord(record),
	)

	assertValidationCheck(t, checks, "companion-bundle-record", true)
	assertValidationCheck(t, checks, "companion-bundle-presence", true)
	if len(runner.commands) != 1 {
		t.Fatalf("runner command count = %d, want listing only", len(runner.commands))
	}
	if !containsArgumentSequence(runner.commands[0].Args, "-ls", "/sp11") {
		t.Fatalf("listing command arguments = %q", runner.commands[0].Args)
	}
}

// TestValidateCompanionBundleRejectsStrayDirectory verifies a manifest cannot
// mark the payload absent while leaving an untracked companion tree on media.
func TestValidateCompanionBundleRejectsStrayDirectory(t *testing.T) {
	runner := &companionISOValidationRunner{listing: []byte("'README.txt'\n'companion'\n")}
	validator := NewValidator(platform.NewDocker(runner))
	record := companion.Absent(companion.OmissionReasonNotRequested)

	checks := validator.validateCompanionBundle(
		context.Background(), "tools:test", t.TempDir(), record, companion.ValidateRecord(record),
	)

	check := assertValidationCheck(t, checks, "companion-bundle-presence", false)
	if !strings.Contains(check.Details, companion.ISOFilesystemRoot) {
		t.Fatalf("presence details = %q, want reserved path", check.Details)
	}
}

// TestValidateCompanionBundleVerifiesIncludedContents proves an included
// record triggers extraction followed by closed-set digest and format checks.
func TestValidateCompanionBundleVerifiesIncludedContents(t *testing.T) {
	workspace := t.TempDir()
	record := writeCompanionValidationFixture(t, filepath.Join(workspace, "companion"))
	runner := &companionISOValidationRunner{listing: []byte("'README.txt'\n'companion'\n")}
	validator := NewValidator(platform.NewDocker(runner))

	checks := validator.validateCompanionBundle(
		context.Background(), "tools:test", workspace, record, companion.ValidateRecord(record),
	)

	assertValidationCheck(t, checks, "companion-bundle-record", true)
	assertValidationCheck(t, checks, "companion-bundle-presence", true)
	assertValidationCheck(t, checks, "companion-bundle-contents", true)
	if len(runner.commands) != 2 ||
		!containsArgumentSequence(runner.commands[1].Args, "-extract", "/"+companion.ISOFilesystemRoot, "/work/companion") {
		t.Fatalf("extraction commands = %#v", runner.commands)
	}
}

// TestValidateCompanionBundleRejectsMutatedContents verifies the finished ISO
// check rehashes extracted bytes instead of trusting manifest metadata alone.
func TestValidateCompanionBundleRejectsMutatedContents(t *testing.T) {
	workspace := t.TempDir()
	companionRoot := filepath.Join(workspace, "companion")
	record := writeCompanionValidationFixture(t, companionRoot)
	sourcePath := filepath.Join(companionRoot, "source", "linux-armer_v1.2.3_source.tar.gz")
	if err := os.WriteFile(sourcePath, []byte("mutated source"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &companionISOValidationRunner{listing: []byte("'companion'\n")}
	validator := NewValidator(platform.NewDocker(runner))

	checks := validator.validateCompanionBundle(
		context.Background(), "tools:test", workspace, record, companion.ValidateRecord(record),
	)

	check := assertValidationCheck(t, checks, "companion-bundle-contents", false)
	if !strings.Contains(check.Details, "source/linux-armer_v1.2.3_source.tar.gz") {
		t.Fatalf("contents details = %q, want mutated path", check.Details)
	}
}

// TestValidateCompanionBundleRejectsListingFailure verifies an xorriso failure
// cannot be misreported as proof that an omitted directory is absent.
func TestValidateCompanionBundleRejectsListingFailure(t *testing.T) {
	runner := &companionISOValidationRunner{captureErr: errors.New("cannot inspect image")}
	validator := NewValidator(platform.NewDocker(runner))
	record := companion.Absent(companion.OmissionReasonNotRequested)

	checks := validator.validateCompanionBundle(
		context.Background(), "tools:test", t.TempDir(), record, companion.ValidateRecord(record),
	)

	check := assertValidationCheck(t, checks, "companion-bundle-presence", false)
	if !strings.Contains(check.Details, "cannot inspect image") {
		t.Fatalf("presence details = %q, want xorriso failure", check.Details)
	}
}

// TestISODirectoryListingContainsRequiresExactName verifies similarly prefixed
// ISO members cannot masquerade as the reserved companion entry.
func TestISODirectoryListingContainsRequiresExactName(t *testing.T) {
	listing := []byte("'companion-old'\n'not-companion'\ncompanion-data\n")
	if isoDirectoryListingContains(listing, "companion") {
		t.Fatal("isoDirectoryListingContains() accepted a prefixed child name")
	}
	if !isoDirectoryListingContains([]byte("'companion'\n"), "companion") {
		t.Fatal("isoDirectoryListingContains() rejected xorriso's exact quoted child name")
	}
}

// TestSnapshotValidationImagePinsOneSourceIdentity proves a pathname exchange
// between inspection and opening cannot pair one ISO digest with another ISO's
// embedded manifest.
func TestSnapshotValidationImagePinsOneSourceIdentity(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source.iso")
	replacement := filepath.Join(root, "replacement.iso")
	destination := filepath.Join(root, "snapshot.iso")
	if err := os.WriteFile(source, []byte("first image"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(replacement, []byte("second image"), 0o644); err != nil {
		t.Fatal(err)
	}
	hook := func() error {
		if err := os.Rename(source, source+".original"); err != nil {
			return err
		}
		return os.Rename(replacement, source)
	}
	if _, _, err := snapshotValidationImageAfterInspection(context.Background(), source, destination, hook); err == nil || !strings.Contains(err.Error(), "identity changed") {
		t.Fatalf("snapshot source-swap error = %v", err)
	}
	if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed snapshot destination exists: %v", err)
	}
}

// TestSnapshotValidationImageRejectsSameInodeGrowth proves the absolute ISO
// bound is repeated on the opened descriptor rather than trusted from Lstat.
func TestSnapshotValidationImageRejectsSameInodeGrowth(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source.iso")
	destination := filepath.Join(root, "snapshot.iso")
	if err := os.WriteFile(source, []byte("small image"), 0o644); err != nil {
		t.Fatal(err)
	}
	hook := func() error {
		return os.Truncate(source, maximumValidationImageBytes+1)
	}
	if _, _, err := snapshotValidationImageAfterInspection(context.Background(), source, destination, hook); err == nil || !strings.Contains(err.Error(), "identity changed") {
		t.Fatalf("snapshot same-inode growth error = %v", err)
	}
	if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed snapshot destination exists: %v", err)
	}
}

// TestSnapshotValidationImageHashesThePrivateCopy verifies successful
// snapshots report the exact bytes later supplied to all structural tools.
func TestSnapshotValidationImageHashesThePrivateCopy(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source.iso")
	destination := filepath.Join(root, "snapshot.iso")
	contents := []byte("one coherent image snapshot")
	if err := os.WriteFile(source, contents, 0o644); err != nil {
		t.Fatal(err)
	}
	digest, size, err := snapshotValidationImage(context.Background(), source, destination)
	if err != nil {
		t.Fatal(err)
	}
	wantDigest := sha256.Sum256(contents)
	copied, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if digest != fmt.Sprintf("%x", wantDigest) || size != int64(len(contents)) || string(copied) != string(contents) {
		t.Fatalf("snapshot digest=%s size=%d contents=%q", digest, size, copied)
	}
}

// TestReadValidationManifestRejectsPathSwapAndOversize proves the manifest
// bound and regular-file identity survive hostile pathname changes.
func TestReadValidationManifestRejectsPathSwapAndOversize(t *testing.T) {
	root := t.TempDir()
	manifest := filepath.Join(root, "manifest.json")
	replacement := filepath.Join(root, "replacement.json")
	if err := os.WriteFile(manifest, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(replacement, []byte("{\"different\":true}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	hook := func() error {
		if err := os.Rename(manifest, manifest+".original"); err != nil {
			return err
		}
		return os.Rename(replacement, manifest)
	}
	if _, err := readValidationManifestAfterInspection(manifest, hook); err == nil || !strings.Contains(err.Error(), "identity changed") {
		t.Fatalf("manifest source-swap error = %v", err)
	}
	overlong := filepath.Join(root, "overlong.json")
	file, err := os.Create(overlong)
	if err != nil {
		t.Fatal(err)
	}
	truncateErr := file.Truncate(imagecontract.MaximumManifestSize + 1)
	closeErr := file.Close()
	if err := errors.Join(truncateErr, closeErr); err != nil {
		t.Fatal(err)
	}
	if _, err := readValidationManifest(overlong); err == nil || !strings.Contains(err.Error(), "bounded") {
		t.Fatalf("overlong manifest error = %v", err)
	}
}

// TestReadValidationManifestRejectsSameInodeGrowth proves the manifest size
// observed before opening must still match the descriptor-bound file.
func TestReadValidationManifestRejectsSameInodeGrowth(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	manifest := filepath.Join(root, "manifest.json")
	if err := os.WriteFile(manifest, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	hook := func() error {
		return os.Truncate(manifest, 32)
	}
	if _, err := readValidationManifestAfterInspection(manifest, hook); err == nil || !strings.Contains(err.Error(), "identity changed") {
		t.Fatalf("manifest same-inode growth error = %v", err)
	}
}

// writeCompanionValidationFixture stages the smallest valid companion closed
// set and returns matching immutable records for validator tests.
func writeCompanionValidationFixture(t *testing.T, root string) imagecontract.CompanionBundleRecord {
	t.Helper()
	files := []struct {
		relative string
		content  []byte
		mode     os.FileMode
	}{
		{relative: "bin/linux-arm64/linux-armer", content: minimalAArch64ELF(), mode: 0o755},
		{relative: "catalogues/supported-isos.json", content: []byte("{}\n"), mode: 0o644},
		{relative: "catalogues/supported-userspace.json", content: []byte("{}\n"), mode: 0o644},
		{relative: "source/linux-armer_v1.2.3_source.tar.gz", content: []byte("source snapshot"), mode: 0o644},
	}
	records := make(map[string]imagecontract.ArtifactRecord, len(files))
	for _, file := range files {
		hostPath := filepath.Join(root, filepath.FromSlash(file.relative))
		if err := os.MkdirAll(filepath.Dir(hostPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(hostPath, file.content, file.mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(hostPath, file.mode); err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(file.content)
		records[file.relative] = imagecontract.ArtifactRecord{
			Path:   companion.ISOFilesystemRoot + "/" + file.relative,
			SHA256: fmt.Sprintf("%x", digest),
			Size:   int64(len(file.content)),
		}
	}
	executable := records["bin/linux-arm64/linux-armer"]
	sourceArchive := records["source/linux-armer_v1.2.3_source.tar.gz"]
	return imagecontract.CompanionBundleRecord{
		Included: true,
		Root:     companion.ISOFilesystemRoot,
		Tool: &imagecontract.ToolIdentityRecord{
			Version:   "v1.2.3",
			Commit:    "abc123",
			BuildDate: "2026-08-30T00:00:00Z",
		},
		ProjectLicence: "not-declared",
		Executable: &imagecontract.ExecutableArtifactRecord{
			Artifact:        executable,
			OperatingSystem: "linux",
			Architecture:    "arm64",
			Format:          "ELF",
			Mode:            "0755",
		},
		SourceArchive: &sourceArchive,
		Catalogues: []imagecontract.ArtifactRecord{
			records["catalogues/supported-isos.json"],
			records["catalogues/supported-userspace.json"],
		},
		Userspace: []imagecontract.OfflineUserspaceRecord{},
	}
}

// minimalAArch64ELF returns a header-only, statically linked AArch64 ELF that
// is sufficient for the companion format and interpreter checks.
func minimalAArch64ELF() []byte {
	contents := make([]byte, 64)
	copy(contents[:4], []byte{0x7f, 'E', 'L', 'F'})
	contents[4] = 2
	contents[5] = 1
	contents[6] = 1
	binary.LittleEndian.PutUint16(contents[16:18], 2)
	binary.LittleEndian.PutUint16(contents[18:20], 183)
	binary.LittleEndian.PutUint32(contents[20:24], 1)
	binary.LittleEndian.PutUint16(contents[52:54], 64)
	binary.LittleEndian.PutUint16(contents[54:56], 56)
	binary.LittleEndian.PutUint16(contents[58:60], 64)
	return contents
}

// assertValidationCheck returns the named validation check after asserting its
// expected result, failing the test when the report omits it.
func assertValidationCheck(
	t *testing.T,
	checks []imagecontract.ValidationCheck,
	name string,
	wantPassed bool,
) imagecontract.ValidationCheck {
	t.Helper()
	for _, check := range checks {
		if check.Name == name {
			if check.Passed != wantPassed {
				t.Fatalf("validation check %q passed = %t, want %t; details: %s", name, check.Passed, wantPassed, check.Details)
			}
			return check
		}
	}
	t.Fatalf("validation check %q is missing from %#v", name, checks)
	return imagecontract.ValidationCheck{}
}

// containsArgumentSequence reports whether arguments contain the exact
// consecutive values, preserving command-boundary assertions in tests.
func containsArgumentSequence(arguments []string, values ...string) bool {
	if len(values) == 0 || len(arguments) < len(values) {
		return false
	}
	for start := 0; start <= len(arguments)-len(values); start++ {
		matched := true
		for offset := range values {
			if arguments[start+offset] != values[offset] {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}
