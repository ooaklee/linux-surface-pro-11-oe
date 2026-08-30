package ubuntu

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image/companion"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
)

// testJournalBytes is the complete execution evidence used by focused
// publication tests that do not need to inspect journal semantics.
var testJournalBytes = []byte("{\n  \"operation\": \"image.create\"\n}\n")

// publishTestImageOutputs supplies stable journal evidence around tests whose
// primary concern is ISO or manifest publication behaviour.
func publishTestImageOutputs(
	sourceISO string,
	destinationISO string,
	manifestBytes []byte,
	expectedISO publicationIdentity,
	expectedManifest publicationIdentity,
	publisher noReplacePublisher,
) (string, error) {
	manifestPath, _, err := publishImageOutputs(
		sourceISO,
		destinationISO,
		manifestBytes,
		testJournalBytes,
		expectedISO,
		expectedManifest,
		identifyPublicationBytes(testJournalBytes),
		publisher,
	)
	return manifestPath, err
}

// TestUbuntuBuildPlanRejectsNonPortableISOOutput verifies the adapter's direct
// planning boundary rejects output names outside the image-release contract.
func TestUbuntuBuildPlanRejectsNonPortableISOOutput(t *testing.T) {
	t.Parallel()

	for _, output := range []string{
		"output.img",
		"not portable.iso",
		".hidden.iso",
		"output.iso.partial",
		strings.Repeat("a", 197) + ".iso",
	} {
		_, err := BuildPlan(Request{
			SourceISO: "source.iso",
			OutputISO: output,
			Bundle:    kernel.Bundle{ABI: "test-abi"},
		})
		if err == nil || !strings.Contains(err.Error(), "portable .iso filename") {
			t.Errorf("BuildPlan(OutputISO=%q) error = %v", output, err)
		}
	}
}

// TestUbuntuCreatePreservesExistingJournal verifies destination preflight runs
// before dependency checks or private checkpoint creation and never overwrites
// execution evidence belonging to an earlier image.
func TestUbuntuCreatePreservesExistingJournal(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	output := filepath.Join(directory, "output.iso")
	journalPath := output + ".journal.json"
	existingBytes := []byte("earlier execution evidence\n")
	if err := os.WriteFile(journalPath, existingBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := (&Remasterer{}).Create(context.Background(), Request{
		SourceISO: filepath.Join(directory, "source.iso"),
		OutputISO: output,
		Bundle:    kernel.Bundle{ABI: "test-abi"},
	})
	if err == nil || !strings.Contains(err.Error(), "execution journal already exists") {
		t.Fatalf("Create() error = %v, want existing-journal rejection", err)
	}
	actual, readErr := os.ReadFile(journalPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Equal(actual, existingBytes) {
		t.Fatalf("existing journal bytes = %q, want %q", actual, existingBytes)
	}
}

// TestPublishImageOutputsPreserveExactManifestBytes verifies one serialised
// manifest supplies both the embedded support member and its final sidecar.
func TestPublishImageOutputsPreserveExactManifestBytes(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	manifest := imagecontract.Manifest{
		SchemaVersion:   imagecontract.ManifestSchemaVersion,
		Layout:          "hybrid-iso",
		Adapter:         AdapterID,
		KernelBundle:    kernel.Bundle{ABI: "test-abi"},
		CompanionBundle: companion.Absent(companion.OmissionReasonNotRequested),
	}
	manifestBytes, err := serialiseManifest(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeSupportFiles(directory, manifest, manifestBytes, "test-abi"); err != nil {
		t.Fatal(err)
	}

	imageBytes := []byte("complete image bytes\x00with a binary suffix")
	source := filepath.Join(directory, "partial.iso")
	destination := filepath.Join(directory, "output.iso")
	if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	manifestPath, err := publishTestImageOutputs(
		source,
		destination,
		manifestBytes,
		identifyPublicationBytes(imageBytes),
		identifyPublicationBytes(manifestBytes),
		nil,
	)
	if err != nil {
		t.Fatalf("publishImageOutputs() error = %v", err)
	}

	embeddedBytes, err := os.ReadFile(filepath.Join(directory, "sp11", "linux-armer-manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	sidecarBytes, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(embeddedBytes, manifestBytes) || !bytes.Equal(sidecarBytes, manifestBytes) {
		t.Fatalf("manifest bytes differ: embedded=%q sidecar=%q expected=%q", embeddedBytes, sidecarBytes, manifestBytes)
	}
	publishedImage, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(publishedImage, imageBytes) {
		t.Fatalf("published image bytes = %q, want %q", publishedImage, imageBytes)
	}
	publishedJournal, err := os.ReadFile(destination + ".journal.json")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(publishedJournal, testJournalBytes) {
		t.Fatalf("published journal bytes = %q, want %q", publishedJournal, testJournalBytes)
	}
	assertNoPublicationStagingFiles(t, directory, filepath.Base(destination))
}

// TestWriteSupportFilesRejectsDifferentManifestBytes verifies support staging
// cannot embed bytes that do not represent the supplied manifest value.
func TestWriteSupportFilesRejectsDifferentManifestBytes(t *testing.T) {
	t.Parallel()

	manifest := imagecontract.Manifest{
		SchemaVersion: imagecontract.ManifestSchemaVersion,
		Layout:        "hybrid-iso",
		Adapter:       AdapterID,
		KernelBundle:  kernel.Bundle{ABI: "test-abi"},
	}
	err := writeSupportFiles(t.TempDir(), manifest, []byte("{}\n"), "test-abi")
	if err == nil || !strings.Contains(err.Error(), "differ from their manifest value") {
		t.Fatalf("writeSupportFiles() error = %v, want byte-identity rejection", err)
	}
}

// TestPublishImageOutputsRetainUncommittedPrefixOnFailure verifies a failed
// no-replace rename never triggers path-based deletion and never exposes an ISO.
func TestPublishImageOutputsRetainUncommittedPrefixOnFailure(t *testing.T) {
	t.Parallel()

	for _, failure := range []struct {
		name              string
		call              int
		manifestPublished bool
		journalPublished  bool
	}{
		{name: "manifest", call: 1},
		{name: "journal", call: 2, manifestPublished: true},
		{name: "iso", call: 3, manifestPublished: true, journalPublished: true},
	} {
		failure := failure
		t.Run(failure.name, func(t *testing.T) {
			t.Parallel()

			directory := t.TempDir()
			imageBytes := []byte("image")
			manifestBytes := []byte("{\n  \"manifest\": true\n}\n")
			source := filepath.Join(directory, "partial.iso")
			destination := filepath.Join(directory, "output.iso")
			if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
				t.Fatal(err)
			}
			injectedErr := errors.New("injected " + failure.name + " publication failure")
			calls := 0
			publisher := func(directory *os.File, sourceName, destinationName string) error {
				calls++
				if calls == failure.call {
					return injectedErr
				}
				return publishOutputNoReplace(directory, sourceName, destinationName)
			}

			_, err := publishTestImageOutputs(
				source,
				destination,
				manifestBytes,
				identifyPublicationBytes(imageBytes),
				identifyPublicationBytes(manifestBytes),
				publisher,
			)
			if !errors.Is(err, injectedErr) || !strings.Contains(err.Error(), "without path-based rollback") {
				t.Fatalf("publishImageOutputs() error = %v, want injected failure and recovery guidance", err)
			}
			assertPublicationPathAbsent(t, destination)
			assertPublicationPresence(t, destination+".manifest.json", failure.manifestPublished)
			assertPublicationPresence(t, destination+".journal.json", failure.journalPublished)
			if countPublicationStagingFiles(t, directory, filepath.Base(destination)) == 0 {
				t.Fatal("publication failure removed every retained staging entry")
			}
		})
	}
}

// TestPublishImageOutputsPreserveVerifiedRenameOnReportedFailure verifies an
// error after a completed rename leaves the exact member in place for recovery.
func TestPublishImageOutputsPreserveVerifiedRenameOnReportedFailure(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	imageBytes := []byte("image")
	manifestBytes := []byte("manifest\n")
	source := filepath.Join(directory, "partial.iso")
	destination := filepath.Join(directory, "output.iso")
	if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	injectedErr := errors.New("ambiguous error after rename")
	publisher := func(directory *os.File, sourceName, destinationName string) error {
		if err := publishOutputNoReplace(directory, sourceName, destinationName); err != nil {
			return err
		}
		return injectedErr
	}

	_, err := publishTestImageOutputs(
		source,
		destination,
		manifestBytes,
		identifyPublicationBytes(imageBytes),
		identifyPublicationBytes(manifestBytes),
		publisher,
	)
	if !errors.Is(err, injectedErr) || !strings.Contains(err.Error(), "without path-based rollback") {
		t.Fatalf("publishImageOutputs() error = %v, want reported failure and recovery guidance", err)
	}
	assertExactPublicationBytes(t, destination+".manifest.json", manifestBytes)
	assertPublicationPathAbsent(t, destination)
	assertPublicationPathAbsent(t, destination+".journal.json")
	if countPublicationStagingFiles(t, directory, filepath.Base(destination)) == 0 {
		t.Fatal("reported publisher failure removed every retained staging entry")
	}
}

// TestPublishImageOutputsPreservePreExistingDestinations verifies the fresh-set
// requirement never changes an existing ISO, manifest sidecar, or journal.
func TestPublishImageOutputsPreservePreExistingDestinations(t *testing.T) {
	t.Parallel()

	for _, existing := range []string{"iso", "manifest", "journal"} {
		existing := existing
		t.Run(existing, func(t *testing.T) {
			t.Parallel()

			directory := t.TempDir()
			imageBytes := []byte("new image")
			manifestBytes := []byte("new manifest\n")
			source := filepath.Join(directory, "partial.iso")
			destination := filepath.Join(directory, "output.iso")
			manifestPath := destination + ".manifest.json"
			journalPath := destination + ".journal.json"
			if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
				t.Fatal(err)
			}
			existingPath := map[string]string{
				"iso": destination, "manifest": manifestPath, "journal": journalPath,
			}[existing]
			if existingPath == "" {
				t.Fatalf("test has no path for %q", existing)
			}
			existingBytes := []byte("preserve existing " + existing)
			if err := os.WriteFile(existingPath, existingBytes, 0o600); err != nil {
				t.Fatal(err)
			}

			_, err := publishTestImageOutputs(
				source,
				destination,
				manifestBytes,
				identifyPublicationBytes(imageBytes),
				identifyPublicationBytes(manifestBytes),
				nil,
			)
			if err == nil || !strings.Contains(err.Error(), "already exists") {
				t.Fatalf("publishImageOutputs() error = %v, want existing-destination rejection", err)
			}
			actual, err := os.ReadFile(existingPath)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(actual, existingBytes) {
				t.Fatalf("existing %s bytes = %q, want %q", existing, actual, existingBytes)
			}
			for _, candidate := range []string{destination, manifestPath, journalPath} {
				if candidate != existingPath {
					assertPublicationPathAbsent(t, candidate)
				}
			}
			assertNoPublicationStagingFiles(t, directory, filepath.Base(destination))
		})
	}
}

// TestPublishImageOutputsPreserveConcurrentDestinations verifies atomic
// no-replace publication rejects races without deleting the winning object.
func TestPublishImageOutputsPreserveConcurrentDestinations(t *testing.T) {
	t.Parallel()

	for _, target := range []struct {
		name   string
		suffix string
	}{
		{name: "manifest", suffix: ".manifest.json"},
		{name: "journal", suffix: ".journal.json"},
		{name: "iso"},
	} {
		target := target
		t.Run(target.name, func(t *testing.T) {
			t.Parallel()

			directory := t.TempDir()
			imageBytes := []byte("new image")
			manifestBytes := []byte("new manifest\n")
			source := filepath.Join(directory, "partial.iso")
			destination := filepath.Join(directory, "output.iso")
			targetPath := destination + target.suffix
			if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
				t.Fatal(err)
			}
			concurrentBytes := []byte("concurrent " + target.name)
			publisher := func(publicationDirectory *os.File, sourceName, destinationName string) error {
				if filepath.Join(publicationDirectory.Name(), destinationName) == targetPath {
					if err := os.WriteFile(targetPath, concurrentBytes, 0o600); err != nil {
						return err
					}
				}
				return publishOutputNoReplace(publicationDirectory, sourceName, destinationName)
			}

			_, err := publishTestImageOutputs(
				source,
				destination,
				manifestBytes,
				identifyPublicationBytes(imageBytes),
				identifyPublicationBytes(manifestBytes),
				publisher,
			)
			if err == nil {
				t.Fatalf("publishImageOutputs() unexpectedly accepted a concurrent %s", target.name)
			}
			assertExactPublicationBytes(t, targetPath, concurrentBytes)
			if target.name != "iso" {
				assertPublicationPathAbsent(t, destination)
			}
			if countPublicationStagingFiles(t, directory, filepath.Base(destination)) == 0 {
				t.Fatal("concurrent destination failure removed every transaction entry")
			}
		})
	}
}

// TestPublishImageOutputsPreserveSwapBeforeCleanup verifies a staging basename
// replaced immediately before failure is never removed by a close-only unwind.
func TestPublishImageOutputsPreserveSwapBeforeCleanup(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	imageBytes := []byte("new image")
	manifestBytes := []byte("new manifest\n")
	source := filepath.Join(directory, "partial.iso")
	destination := filepath.Join(directory, "output.iso")
	if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	replacementBytes := []byte("replacement staging entry")
	injectedErr := errors.New("injected failure before cleanup")
	var swappedPath string
	var retainedPath string
	publisher := func(publicationDirectory *os.File, sourceName, _ string) error {
		swappedPath = filepath.Join(publicationDirectory.Name(), sourceName)
		retainedPath = swappedPath + ".transaction-owned"
		if err := os.Rename(swappedPath, retainedPath); err != nil {
			return err
		}
		if err := os.WriteFile(swappedPath, replacementBytes, 0o600); err != nil {
			return err
		}
		return injectedErr
	}

	_, err := publishTestImageOutputs(
		source,
		destination,
		manifestBytes,
		identifyPublicationBytes(imageBytes),
		identifyPublicationBytes(manifestBytes),
		publisher,
	)
	if !errors.Is(err, injectedErr) || !strings.Contains(err.Error(), "without path-based rollback") {
		t.Fatalf("publishImageOutputs() error = %v, want injected failure and close-only recovery", err)
	}
	assertExactPublicationBytes(t, swappedPath, replacementBytes)
	if _, err := os.Stat(retainedPath); err != nil {
		t.Fatalf("transaction-owned staging object was not retained: %v", err)
	}
	assertPublicationPathAbsent(t, destination)
}

// TestPublishImageOutputsDetectSwapBeforePublish verifies a staged pathname
// swap cannot publish attacker-controlled bytes as a successful output member.
func TestPublishImageOutputsDetectSwapBeforePublish(t *testing.T) {
	t.Parallel()

	for _, target := range []struct {
		name   string
		suffix string
	}{
		{name: "manifest", suffix: ".manifest.json"},
		{name: "journal", suffix: ".journal.json"},
		{name: "iso"},
	} {
		target := target
		t.Run(target.name, func(t *testing.T) {
			t.Parallel()

			directory := t.TempDir()
			imageBytes := []byte("expected image")
			manifestBytes := []byte("expected manifest\n")
			source := filepath.Join(directory, "partial.iso")
			destination := filepath.Join(directory, "output.iso")
			targetPath := destination + target.suffix
			if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
				t.Fatal(err)
			}
			attackerBytes := []byte("attacker-controlled " + target.name)
			var originalPath string
			publisher := func(publicationDirectory *os.File, sourceName, destinationName string) error {
				finalPath := filepath.Join(publicationDirectory.Name(), destinationName)
				if finalPath == targetPath {
					stagingPath := filepath.Join(publicationDirectory.Name(), sourceName)
					originalPath = stagingPath + ".transaction-owned"
					if err := os.Rename(stagingPath, originalPath); err != nil {
						return err
					}
					if err := os.WriteFile(stagingPath, attackerBytes, 0o600); err != nil {
						return err
					}
				}
				return publishOutputNoReplace(publicationDirectory, sourceName, destinationName)
			}

			_, err := publishTestImageOutputs(
				source,
				destination,
				manifestBytes,
				identifyPublicationBytes(imageBytes),
				identifyPublicationBytes(manifestBytes),
				publisher,
			)
			if err == nil || !strings.Contains(err.Error(), "not the retained staging object") {
				t.Fatalf("publishImageOutputs() error = %v, want retained-descriptor mismatch", err)
			}
			assertExactPublicationBytes(t, targetPath, attackerBytes)
			if _, err := os.Stat(originalPath); err != nil {
				t.Fatalf("transaction-owned object was not preserved: %v", err)
			}
			if target.name != "iso" {
				assertPublicationPathAbsent(t, destination)
			}
		})
	}
}

// TestPublishImageOutputsDetectSwapAfterRename verifies replacing a final name
// before the publisher returns cannot pass post-rename verification or cleanup.
func TestPublishImageOutputsDetectSwapAfterRename(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	imageBytes := []byte("expected image")
	manifestBytes := []byte("expected manifest\n")
	source := filepath.Join(directory, "partial.iso")
	destination := filepath.Join(directory, "output.iso")
	manifestPath := destination + ".manifest.json"
	replacementBytes := []byte("replacement manifest")
	if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	publisher := func(publicationDirectory *os.File, sourceName, destinationName string) error {
		if err := publishOutputNoReplace(publicationDirectory, sourceName, destinationName); err != nil {
			return err
		}
		if filepath.Join(publicationDirectory.Name(), destinationName) != manifestPath {
			return nil
		}
		if err := os.Rename(manifestPath, manifestPath+".transaction-owned"); err != nil {
			return err
		}
		return os.WriteFile(manifestPath, replacementBytes, 0o600)
	}

	_, err := publishTestImageOutputs(
		source,
		destination,
		manifestBytes,
		identifyPublicationBytes(imageBytes),
		identifyPublicationBytes(manifestBytes),
		publisher,
	)
	if err == nil || !strings.Contains(err.Error(), "not the retained staging object") {
		t.Fatalf("publishImageOutputs() error = %v, want post-rename identity mismatch", err)
	}
	assertExactPublicationBytes(t, manifestPath, replacementBytes)
	assertPublicationPathAbsent(t, destination)
}

// TestPublishImageOutputsReverifyCompleteSet verifies an earlier metadata member
// changed during the ISO rename cannot survive the final complete-set check.
func TestPublishImageOutputsReverifyCompleteSet(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	imageBytes := []byte("expected image")
	manifestBytes := []byte("expected manifest\n")
	source := filepath.Join(directory, "partial.iso")
	destination := filepath.Join(directory, "output.iso")
	manifestPath := destination + ".manifest.json"
	replacementBytes := []byte("late replacement manifest")
	if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	publisher := func(publicationDirectory *os.File, sourceName, destinationName string) error {
		if destinationName == filepath.Base(destination) {
			if err := os.Rename(manifestPath, manifestPath+".transaction-owned"); err != nil {
				return err
			}
			if err := os.WriteFile(manifestPath, replacementBytes, 0o600); err != nil {
				return err
			}
		}
		return publishOutputNoReplace(publicationDirectory, sourceName, destinationName)
	}

	_, err := publishTestImageOutputs(
		source,
		destination,
		manifestBytes,
		identifyPublicationBytes(imageBytes),
		identifyPublicationBytes(manifestBytes),
		publisher,
	)
	if err == nil || !strings.Contains(err.Error(), "verify complete image publication set") {
		t.Fatalf("publishImageOutputs() error = %v, want complete-set verification failure", err)
	}
	assertExactPublicationBytes(t, manifestPath, replacementBytes)
	assertExactPublicationBytes(t, destination, imageBytes)
}

// TestPublishImageOutputsAnchorParentDirectory verifies a pathname replacement
// cannot redirect staging or publication away from the directory opened first.
func TestPublishImageOutputsAnchorParentDirectory(t *testing.T) {
	t.Parallel()

	workspace := t.TempDir()
	parent := filepath.Join(workspace, "published")
	if err := os.Mkdir(parent, 0o700); err != nil {
		t.Fatal(err)
	}
	imageBytes := []byte("expected image")
	manifestBytes := []byte("expected manifest\n")
	source := filepath.Join(workspace, "partial.iso")
	destination := filepath.Join(parent, "output.iso")
	if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	movedParent := parent + ".transaction-owned"
	swapped := false
	publisher := func(publicationDirectory *os.File, sourceName, destinationName string) error {
		if !swapped {
			swapped = true
			if err := os.Rename(parent, movedParent); err != nil {
				return err
			}
			if err := os.Mkdir(parent, 0o700); err != nil {
				return err
			}
		}
		return publishOutputNoReplace(publicationDirectory, sourceName, destinationName)
	}

	_, err := publishTestImageOutputs(
		source,
		destination,
		manifestBytes,
		identifyPublicationBytes(imageBytes),
		identifyPublicationBytes(manifestBytes),
		publisher,
	)
	if err == nil || !strings.Contains(err.Error(), "directory path changed") {
		t.Fatalf("publishImageOutputs() error = %v, want parent identity failure", err)
	}
	assertPublicationPathAbsent(t, destination)
	assertExactPublicationBytes(t, filepath.Join(movedParent, "output.iso"), imageBytes)
}

// TestPublishImageOutputsLeavePredictableSymlinkTrapsUntouched verifies random
// exclusive staging never follows or truncates the former temporary filenames.
func TestPublishImageOutputsLeavePredictableSymlinkTrapsUntouched(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	imageBytes := []byte("image")
	manifestBytes := []byte("manifest\n")
	source := filepath.Join(directory, "partial.iso")
	destination := filepath.Join(directory, "output.iso")
	manifestPath := destination + ".manifest.json"
	journalPath := destination + ".journal.json"
	victim := filepath.Join(directory, "victim")
	victimBytes := []byte("must remain unchanged")
	if err := os.WriteFile(source, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(victim, victimBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	traps := []string{destination + ".partial", manifestPath + ".tmp", journalPath + ".tmp"}
	for _, trap := range traps {
		if err := os.Symlink(victim, trap); err != nil {
			t.Fatal(err)
		}
	}

	if _, err := publishTestImageOutputs(
		source,
		destination,
		manifestBytes,
		identifyPublicationBytes(imageBytes),
		identifyPublicationBytes(manifestBytes),
		nil,
	); err != nil {
		t.Fatalf("publishImageOutputs() error = %v", err)
	}
	actualVictim, err := os.ReadFile(victim)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actualVictim, victimBytes) {
		t.Fatalf("symlink victim bytes = %q, want %q", actualVictim, victimBytes)
	}
	for _, trap := range traps {
		info, err := os.Lstat(trap)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode()&os.ModeSymlink == 0 {
			t.Fatalf("predictable trap is no longer a symbolic link: %s", trap)
		}
	}
	assertNoPublicationStagingFiles(t, directory, filepath.Base(destination))
}

// assertPublicationPathAbsent fails the test unless one publication path has no
// filesystem object of any kind.
func assertPublicationPathAbsent(t *testing.T, path string) {
	t.Helper()

	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("publication path %s exists or cannot be inspected: %v", path, err)
	}
}

// assertPublicationPresence verifies whether one final publication path exists
// without interpreting an unexpected object through symbolic-link traversal.
func assertPublicationPresence(t *testing.T, path string, expected bool) {
	t.Helper()

	_, err := os.Lstat(path)
	if expected && err != nil {
		t.Fatalf("publication path %s is absent or cannot be inspected: %v", path, err)
	}
	if !expected && !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("publication path %s exists or cannot be inspected: %v", path, err)
	}
}

// assertExactPublicationBytes verifies one regular publication or preserved
// transaction entry contains the exact expected bytes.
func assertExactPublicationBytes(t *testing.T, path string, expected []byte) {
	t.Helper()

	actual, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, expected) {
		t.Fatalf("publication bytes at %s = %q, want %q", path, actual, expected)
	}
}

// assertNoPublicationStagingFiles fails the test when a random transaction
// staging sibling remains in the requested directory.
func assertNoPublicationStagingFiles(t *testing.T, directory, base string) {
	t.Helper()

	if count := countPublicationStagingFiles(t, directory, base); count != 0 {
		t.Errorf("%d publication staging files remain", count)
	}
}

// countPublicationStagingFiles returns the number of random transaction entries
// still present for one requested ISO basename.
func countPublicationStagingFiles(t *testing.T, directory, base string) int {
	t.Helper()

	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "."+base+".image-") ||
			strings.HasPrefix(entry.Name(), "."+base+".manifest-") ||
			strings.HasPrefix(entry.Name(), "."+base+".journal-") {
			count++
		}
	}
	return count
}
