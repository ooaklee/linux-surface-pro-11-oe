package companion

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"debug/elf"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	imagecontract "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/image"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
	userspacecatalog "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/catalog"
	userspacepolicy "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/policy"
	userspacerelease "github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/userspace/release"
)

// fakeRunner records argument-separated commands and emits a minimal synthetic
// ELF at the requested Go output path.
type fakeRunner struct {
	machine         elf.Machine
	revision        string
	status          string
	captureErr      error
	commands        []platform.Command
	captureCommands []platform.Command
	beforeBuild     func(platform.Command) error
}

// Run records command, invokes the optional mutation hook, and writes the
// configured synthetic executable without invoking a shell.
func (r *fakeRunner) Run(_ context.Context, command platform.Command) error {
	r.commands = append(r.commands, command)
	if r.beforeBuild != nil {
		if err := r.beforeBuild(command); err != nil {
			return err
		}
	}
	output := argumentAfter(command.Args, "-o")
	if output == "" {
		return errors.New("test Go build has no output path")
	}
	machine := r.machine
	if machine == 0 {
		machine = elf.EM_AARCH64
	}
	return writeSyntheticELF(output, machine)
}

// Capture returns deterministic Git revision and status output for provenance
// tests while retaining every command for assertion.
func (r *fakeRunner) Capture(_ context.Context, command platform.Command) ([]byte, error) {
	r.captureCommands = append(r.captureCommands, command)
	if r.captureErr != nil {
		return nil, r.captureErr
	}
	joined := strings.Join(command.Args, " ")
	if strings.Contains(joined, "rev-parse HEAD") {
		return []byte(r.revision + "\n"), nil
	}
	if strings.Contains(joined, "status --porcelain=v1") {
		return []byte(r.status), nil
	}
	return nil, errors.New("unexpected captured test command")
}

// TestBuilderBuildsCoreCompanion verifies core-only staging, the command
// contract, truthful absent project licence, and finished-tree validation.
func TestBuilderBuildsCoreCompanion(t *testing.T) {
	source := makeTestSource(t, false)
	destination := t.TempDir()
	runner := &fakeRunner{}
	record, err := NewBuilder(runner).Build(context.Background(), testBuildRequest(source, destination))
	if err != nil {
		t.Fatal(err)
	}
	if !record.Included || record.ProjectLicence != projectLicenceNotDeclared {
		t.Fatalf("record inclusion/licence = %v/%q", record.Included, record.ProjectLicence)
	}
	if len(record.Userspace) != 0 {
		t.Fatalf("core companion contains %d userspace bundles", len(record.Userspace))
	}
	if len(runner.commands) != 1 {
		t.Fatalf("Go build commands = %d, want 1", len(runner.commands))
	}
	command := runner.commands[0]
	if command.Name != "go" || command.Dir == source || !containsAll(command.Env,
		"GOOS=linux", "GOARCH=arm64", "CGO_ENABLED=0", "GOFLAGS=", "GOWORK=off", "GOENV=off", "GOTOOLCHAIN=local") {
		t.Fatalf("unexpected Go build command: %#v", command)
	}
	if _, err := os.Lstat(command.Dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("private source snapshot was not removed: %v", err)
	}
	joinedArgs := strings.Join(command.Args, " ")
	for _, required := range []string{"-mod=readonly", "-trimpath", "-buildvcs=false", buildPackage} {
		if !strings.Contains(joinedArgs, required) {
			t.Errorf("Go build arguments do not contain %q: %s", required, joinedArgs)
		}
	}
	root := filepath.Join(destination, filepath.FromSlash(ISOFilesystemRoot))
	if err := ValidateDirectory(record, root); err != nil {
		t.Fatalf("validate staged companion: %v", err)
	}
	assertPublishedDirectoryModes(t, root)
	if got := len(FlattenArtifacts(record)); got != 4 {
		t.Fatalf("core companion artefacts = %d, want executable, source, and two catalogues", got)
	}
}

// TestBuilderSnapshotsBeforeBuild proves both the compiler and source archive
// consume the same private snapshot even when the original changes afterwards.
func TestBuilderSnapshotsBeforeBuild(t *testing.T) {
	source := makeTestSource(t, false)
	originalReadme := []byte("snapshot content\n")
	if err := os.WriteFile(filepath.Join(source, "README.md"), originalReadme, 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{beforeBuild: func(command platform.Command) error {
		fromSnapshot, err := os.ReadFile(filepath.Join(command.Dir, "README.md"))
		if err != nil {
			return err
		}
		if string(fromSnapshot) != string(originalReadme) {
			return errors.New("compiler did not receive the original source snapshot")
		}
		return os.WriteFile(filepath.Join(source, "README.md"), []byte("changed original\n"), 0o644)
	}}
	destination := t.TempDir()
	record, err := NewBuilder(runner).Build(context.Background(), testBuildRequest(source, destination))
	if err != nil {
		t.Fatal(err)
	}
	archivePath := filepath.Join(destination, filepath.FromSlash(record.SourceArchive.Path))
	files := readSourceArchive(t, archivePath)
	if got := string(files["linux-armer/README.md"]); got != string(originalReadme) {
		t.Fatalf("archived README = %q, want immutable snapshot", got)
	}
}

// TestBuilderRejectsMutatedSnapshot proves a same-user runner cannot alter the
// compiler snapshot and publish different source bytes in the archive.
func TestBuilderRejectsMutatedSnapshot(t *testing.T) {
	source := makeTestSource(t, false)
	destination := t.TempDir()
	runner := &fakeRunner{beforeBuild: func(command platform.Command) error {
		readmePath := filepath.Join(command.Dir, "README.md")
		content, err := os.ReadFile(readmePath)
		if err != nil {
			return err
		}
		content[0] ^= 0xff
		if err := os.Chmod(readmePath, 0o644); err != nil {
			return err
		}
		return os.WriteFile(readmePath, content, 0o644)
	}}
	_, err := NewBuilder(runner).Build(context.Background(), testBuildRequest(source, destination))
	if err == nil || !strings.Contains(err.Error(), "changed content") {
		t.Fatalf("error = %v, want changed snapshot content rejection", err)
	}
	if _, err := os.Lstat(filepath.Join(destination, filepath.FromSlash(ISOFilesystemRoot))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("mutated snapshot published a companion directory: %v", err)
	}
}

// TestBuilderRejectsRedirectedStagingParent proves a caller-controlled sp11
// link is rejected before its target is changed or receives temporary output.
func TestBuilderRejectsRedirectedStagingParent(t *testing.T) {
	t.Run("symbolic link", func(t *testing.T) {
		source := makeTestSource(t, false)
		destination := t.TempDir()
		redirectTarget := t.TempDir()
		if err := os.Chmod(redirectTarget, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(redirectTarget, filepath.Join(destination, "sp11")); err != nil {
			t.Fatal(err)
		}
		_, err := NewBuilder(&fakeRunner{}).Build(context.Background(), testBuildRequest(source, destination))
		if err == nil || !strings.Contains(err.Error(), "staging parent is not a non-symlink directory") {
			t.Fatalf("error = %v, want redirected staging parent rejection", err)
		}
		info, err := os.Lstat(redirectTarget)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o700 {
			t.Fatalf("redirect target mode = %04o, want unchanged 0700", info.Mode().Perm())
		}
		entries, err := os.ReadDir(redirectTarget)
		if err != nil {
			t.Fatal(err)
		}
		if len(entries) != 0 {
			t.Fatalf("redirect target received %d staging entries", len(entries))
		}
	})
	t.Run("regular file", func(t *testing.T) {
		source := makeTestSource(t, false)
		destination := t.TempDir()
		parentPath := filepath.Join(destination, "sp11")
		if err := os.WriteFile(parentPath, []byte("occupied\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := NewBuilder(&fakeRunner{}).Build(context.Background(), testBuildRequest(source, destination))
		if err == nil || !strings.Contains(err.Error(), "staging parent is not a non-symlink directory") {
			t.Fatalf("error = %v, want non-directory staging parent rejection", err)
		}
		info, err := os.Lstat(parentPath)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("staging parent file mode = %04o, want unchanged 0600", info.Mode().Perm())
		}
	})
}

// TestBuilderSourceArchiveIsDeterministic proves archive bytes and membership
// remain stable across independent destination directories.
func TestBuilderSourceArchiveIsDeterministic(t *testing.T) {
	source := makeTestSource(t, true)
	if err := os.MkdirAll(filepath.Join(source, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{
		filepath.Join("bin", "linux-armer"): "ignored binary",
		"linux-armer":                       "ignored root binary",
		"output.iso":                        "ignored image",
	} {
		if err := os.WriteFile(filepath.Join(source, name), []byte(content), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	var archiveBytes [][]byte
	for iteration := 0; iteration < 2; iteration++ {
		destination := t.TempDir()
		record, err := NewBuilder(&fakeRunner{}).Build(context.Background(), testBuildRequest(source, destination))
		if err != nil {
			t.Fatal(err)
		}
		content, err := os.ReadFile(filepath.Join(destination, filepath.FromSlash(record.SourceArchive.Path)))
		if err != nil {
			t.Fatal(err)
		}
		archiveBytes = append(archiveBytes, content)
	}
	if string(archiveBytes[0]) != string(archiveBytes[1]) {
		t.Fatal("identical source trees produced different source archive bytes")
	}
	files := readSourceArchive(t, writeTemporaryArchive(t, archiveBytes[0]))
	for _, forbidden := range []string{
		"linux-armer/bin/linux-armer", "linux-armer/linux-armer", "linux-armer/output.iso",
	} {
		if _, found := files[forbidden]; found {
			t.Errorf("source archive contains ignored output %q", forbidden)
		}
	}
	if _, found := files["linux-armer/LICENSE"]; !found {
		t.Error("source archive omits discovered project licence")
	}
	if _, found := files["linux-armer/tools/collect-sp11-windows-handoff.ps1"]; !found {
		t.Error("source archive omits the strict Windows hand-off collector")
	}
}

// TestBuilderStagesEligiblePortableUserspace verifies source-required bundle
// staging, portable receipt preservation, and complete manifest inventory.
func TestBuilderStagesEligiblePortableUserspace(t *testing.T) {
	source := makeTestSource(t, false)
	componentCatalog, err := userspacecatalog.LoadFile(filepath.Join(source, userspaceCatalogueName))
	if err != nil {
		t.Fatal(err)
	}
	bundle := makeVerifiedBundle(t, componentCatalog, "iptsd-v1")
	destination := t.TempDir()
	request := testBuildRequest(source, destination)
	request.UserspaceCatalog = componentCatalog
	request.UserspaceBundles = []userspacerelease.Bundle{bundle}
	record, err := NewBuilder(&fakeRunner{}).Build(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if len(record.Userspace) != 1 || record.Userspace[0].Redistribution != string(userspacecatalog.RedistributionSourceRequired) {
		t.Fatalf("offline userspace record = %#v", record.Userspace)
	}
	root := filepath.Join(destination, filepath.FromSlash(ISOFilesystemRoot))
	if err := ValidateDirectory(record, root); err != nil {
		t.Fatal(err)
	}
	receiptPath := filepath.Join(root, "userspace", bundle.Component, bundle.Release, userspaceReceiptName)
	content, err := os.ReadFile(receiptPath)
	if err != nil {
		t.Fatal(err)
	}
	var receipt userspacerelease.Bundle
	if err := json.Unmarshal(content, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Directory != "." {
		t.Fatalf("portable receipt directory = %q", receipt.Directory)
	}
	for _, file := range receipt.Files {
		if file.Path != file.Name || filepath.IsAbs(file.Path) {
			t.Fatalf("portable receipt file path = %q for %q", file.Path, file.Name)
		}
	}
}

// TestValidateRecordRejectsAlteredOfflineReleaseContract verifies that the
// outer ISO manifest cannot retain the approved identifier while changing its
// release or any compiled artefact identity.
func TestValidateRecordRejectsAlteredOfflineReleaseContract(t *testing.T) {
	source := makeTestSource(t, false)
	componentCatalog, err := userspacecatalog.LoadFile(filepath.Join(source, userspaceCatalogueName))
	if err != nil {
		t.Fatal(err)
	}
	bundle := makeVerifiedBundle(t, componentCatalog, IPTSDOfflineComponentID)
	request := testBuildRequest(source, t.TempDir())
	request.UserspaceCatalog = componentCatalog
	request.UserspaceBundles = []userspacerelease.Bundle{bundle}
	record, err := NewBuilder(&fakeRunner{}).Build(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}

	wrongRelease := record
	wrongRelease.Userspace = append([]imagecontract.OfflineUserspaceRecord(nil), record.Userspace...)
	wrongRelease.Userspace[0].Release = "sp11-iptsd-v2"
	wrongRelease.Userspace[0].Root = path.Join(
		ISOFilesystemRoot, "userspace", IPTSDOfflineComponentID, "sp11-iptsd-v2",
	)
	if err := ValidateRecord(wrongRelease); err == nil || !strings.Contains(err.Error(), "expected immutable release") {
		t.Fatalf("same-ID different-release error = %v", err)
	}

	wrongDigest := record
	wrongDigest.Userspace = append([]imagecontract.OfflineUserspaceRecord(nil), record.Userspace...)
	wrongDigest.Userspace[0].Artifacts = append(
		[]imagecontract.ArtifactRecord(nil), record.Userspace[0].Artifacts...,
	)
	wrongDigest.Userspace[0].Artifacts[0].SHA256 = strings.Repeat("0", 64)
	if err := ValidateRecord(wrongDigest); err == nil || !strings.Contains(err.Error(), "immutable release metadata") {
		t.Fatalf("altered artefact error = %v", err)
	}
}

// TestBuilderRejectsUserspaceOutsideCompiledPolicy verifies the builder cannot
// be widened beyond the compiled IPTSD-only policy by catalogue contents.
func TestBuilderRejectsUserspaceOutsideCompiledPolicy(t *testing.T) {
	source := makeTestSource(t, false)
	componentCatalog, err := userspacecatalog.LoadFile(filepath.Join(source, userspaceCatalogueName))
	if err != nil {
		t.Fatal(err)
	}
	for _, testCase := range []struct {
		name      string
		component string
		release   string
	}{
		{name: "restricted catalogue component", component: "audio-fullio-v19c", release: "sp11-audio-v19c"},
		{name: "not-applicable catalogue component", component: "power-profiles", release: "none"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			request := testBuildRequest(source, t.TempDir())
			request.UserspaceCatalog = componentCatalog
			request.UserspaceBundles = []userspacerelease.Bundle{{
				Component: testCase.component, Release: testCase.release,
			}}
			_, err := NewBuilder(&fakeRunner{}).Build(context.Background(), request)
			if err == nil || !strings.Contains(err.Error(), "offline companion inclusion") {
				t.Fatalf("error = %v, want offline inclusion rejection", err)
			}
		})
	}
}

// TestBuilderRejectsIneligibleIPTSDRedistribution verifies the compiled
// component remains subject to the catalogue's explicit redistribution policy.
func TestBuilderRejectsIneligibleIPTSDRedistribution(t *testing.T) {
	source := makeTestSource(t, false)
	catalogueData, err := os.ReadFile(filepath.Join(source, userspaceCatalogueName))
	if err != nil {
		t.Fatal(err)
	}
	modified := strings.Replace(
		string(catalogueData),
		`"redistribution": "source-required"`,
		`"redistribution": "restricted"`,
		1,
	)
	if modified == string(catalogueData) {
		t.Fatal("test catalogue does not contain the expected IPTSD redistribution policy")
	}
	if err := os.WriteFile(filepath.Join(source, userspaceCatalogueName), []byte(modified), 0o644); err != nil {
		t.Fatal(err)
	}
	componentCatalog, err := userspacecatalog.LoadBytes([]byte(modified))
	if err != nil {
		t.Fatal(err)
	}
	request := testBuildRequest(source, t.TempDir())
	request.UserspaceCatalog = componentCatalog
	request.UserspaceBundles = []userspacerelease.Bundle{{
		Component: IPTSDOfflineComponentID,
		Release:   "sp11-iptsd-v1",
	}}
	_, err = NewBuilder(&fakeRunner{}).Build(context.Background(), request)
	if err == nil || !strings.Contains(err.Error(), "redistribution policy") {
		t.Fatalf("error = %v, want redistribution-policy rejection", err)
	}
}

// TestBuilderRejectsCatalogueRedirectOfApprovedIPTSD verifies that retaining
// the approved identifier cannot redirect the companion to another release.
func TestBuilderRejectsCatalogueRedirectOfApprovedIPTSD(t *testing.T) {
	source := makeTestSource(t, false)
	cataloguePath := filepath.Join(source, userspaceCatalogueName)
	catalogueData, err := os.ReadFile(cataloguePath)
	if err != nil {
		t.Fatal(err)
	}
	modified := strings.ReplaceAll(string(catalogueData), "sp11-iptsd-v1", "sp11-iptsd-v2")
	if modified == string(catalogueData) {
		t.Fatal("test catalogue does not contain the expected IPTSD release")
	}
	if err := os.WriteFile(cataloguePath, []byte(modified), 0o644); err != nil {
		t.Fatal(err)
	}
	componentCatalog, err := userspacecatalog.LoadFile(cataloguePath)
	if err != nil {
		t.Fatal(err)
	}
	request := testBuildRequest(source, t.TempDir())
	request.UserspaceCatalog = componentCatalog
	request.UserspaceBundles = []userspacerelease.Bundle{{
		Component: IPTSDOfflineComponentID, Repository: userspacepolicy.IPTSDRepository,
		Release: "sp11-iptsd-v2", Directory: t.TempDir(),
	}}
	_, err = NewBuilder(&fakeRunner{}).Build(context.Background(), request)
	if err == nil || !strings.Contains(err.Error(), "expected \"sp11-iptsd-v1\"") {
		t.Fatalf("error = %v, want immutable release rejection", err)
	}
}

// TestBuilderRejectsAmbiguousPortableReceiptJSON verifies that the companion
// applies the installer's exact duplicate and case-sensitive key contract.
func TestBuilderRejectsAmbiguousPortableReceiptJSON(t *testing.T) {
	for _, testCase := range []struct {
		name    string
		mutate  func(string) string
		message string
	}{
		{
			name: "duplicate field",
			mutate: func(content string) string {
				return strings.Replace(content, `"component": "iptsd-v1"`, `"component": "iptsd-v1", "component": "iptsd-v1"`, 1)
			},
			message: "duplicate field",
		},
		{
			name: "mis-cased field",
			mutate: func(content string) string {
				return strings.Replace(content, `"component"`, `"Component"`, 1)
			},
			message: "unknown field",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			source := makeTestSource(t, false)
			componentCatalog, err := userspacecatalog.LoadFile(filepath.Join(source, userspaceCatalogueName))
			if err != nil {
				t.Fatal(err)
			}
			bundle := makeVerifiedBundle(t, componentCatalog, IPTSDOfflineComponentID)
			receiptPath := filepath.Join(bundle.Directory, userspaceReceiptName)
			content, err := os.ReadFile(receiptPath)
			if err != nil {
				t.Fatal(err)
			}
			mutated := testCase.mutate(string(content))
			if mutated == string(content) {
				t.Fatal("receipt mutation did not change the fixture")
			}
			if err := os.WriteFile(receiptPath, []byte(mutated), 0o644); err != nil {
				t.Fatal(err)
			}
			request := testBuildRequest(source, t.TempDir())
			request.UserspaceCatalog = componentCatalog
			request.UserspaceBundles = []userspacerelease.Bundle{bundle}
			_, err = NewBuilder(&fakeRunner{}).Build(context.Background(), request)
			if err == nil || !strings.Contains(err.Error(), testCase.message) {
				t.Fatalf("error = %v, want %q rejection", err, testCase.message)
			}
		})
	}
}

// TestBuilderRejectsTraversalAndSymlinks checks source and release boundaries
// against traversal names, final symlinks, and non-exact absolute paths.
func TestBuilderRejectsTraversalAndSymlinks(t *testing.T) {
	t.Run("maintained source symlink", func(t *testing.T) {
		source := makeTestSource(t, false)
		target := filepath.Join(source, "internal", "target.go")
		if err := os.WriteFile(target, []byte("package internal\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, filepath.Join(source, "internal", "linked.go")); err != nil {
			t.Fatal(err)
		}
		_, err := NewBuilder(&fakeRunner{}).Build(context.Background(), testBuildRequest(source, t.TempDir()))
		if err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Fatalf("error = %v, want source symlink rejection", err)
		}
	})
	t.Run("release traversal", func(t *testing.T) {
		source := makeTestSource(t, false)
		componentCatalog, err := userspacecatalog.LoadFile(filepath.Join(source, userspaceCatalogueName))
		if err != nil {
			t.Fatal(err)
		}
		request := testBuildRequest(source, t.TempDir())
		request.UserspaceCatalog = componentCatalog
		request.UserspaceBundles = []userspacerelease.Bundle{{
			Component: "iptsd-v1", Release: "sp11-iptsd-v1", Repository: userspacepolicy.IPTSDRepository,
			Directory: t.TempDir(),
			Files:     []userspacerelease.File{{Name: "../escape", Verified: true}},
		}}
		_, err = NewBuilder(&fakeRunner{}).Build(context.Background(), request)
		if err == nil || !strings.Contains(err.Error(), "safe flat name") {
			t.Fatalf("error = %v, want traversal rejection", err)
		}
	})
	t.Run("non-exact release path", func(t *testing.T) {
		source := makeTestSource(t, false)
		componentCatalog, err := userspacecatalog.LoadFile(filepath.Join(source, userspaceCatalogueName))
		if err != nil {
			t.Fatal(err)
		}
		bundle := makeVerifiedBundle(t, componentCatalog, "iptsd-v1")
		bundle.Files[0].Path = filepath.Join(bundle.Directory, ".", bundle.Files[0].Name) + string(filepath.Separator) + ".."
		request := testBuildRequest(source, t.TempDir())
		request.UserspaceCatalog = componentCatalog
		request.UserspaceBundles = []userspacerelease.Bundle{bundle}
		_, err = NewBuilder(&fakeRunner{}).Build(context.Background(), request)
		if err == nil || !strings.Contains(err.Error(), "must be exactly") {
			t.Fatalf("error = %v, want exact absolute-path rejection", err)
		}
	})
	t.Run("release file symlink", func(t *testing.T) {
		source := makeTestSource(t, false)
		componentCatalog, err := userspacecatalog.LoadFile(filepath.Join(source, userspaceCatalogueName))
		if err != nil {
			t.Fatal(err)
		}
		bundle := makeVerifiedBundle(t, componentCatalog, "iptsd-v1")
		target := filepath.Join(t.TempDir(), bundle.Files[0].Name)
		if err := os.Rename(bundle.Files[0].Path, target); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, bundle.Files[0].Path); err != nil {
			t.Fatal(err)
		}
		request := testBuildRequest(source, t.TempDir())
		request.UserspaceCatalog = componentCatalog
		request.UserspaceBundles = []userspacerelease.Bundle{bundle}
		_, err = NewBuilder(&fakeRunner{}).Build(context.Background(), request)
		if err == nil || !strings.Contains(err.Error(), "regular non-symlink file") {
			t.Fatalf("error = %v, want release symlink rejection", err)
		}
	})
	t.Run("non-portable receipt", func(t *testing.T) {
		source := makeTestSource(t, false)
		componentCatalog, err := userspacecatalog.LoadFile(filepath.Join(source, userspaceCatalogueName))
		if err != nil {
			t.Fatal(err)
		}
		bundle := makeVerifiedBundle(t, componentCatalog, "iptsd-v1")
		receiptPath := filepath.Join(bundle.Directory, userspaceReceiptName)
		content, err := os.ReadFile(receiptPath)
		if err != nil {
			t.Fatal(err)
		}
		var receipt userspacerelease.Bundle
		if err := json.Unmarshal(content, &receipt); err != nil {
			t.Fatal(err)
		}
		receipt.Directory = bundle.Directory
		content, err = json.Marshal(receipt)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(receiptPath, content, 0o644); err != nil {
			t.Fatal(err)
		}
		request := testBuildRequest(source, t.TempDir())
		request.UserspaceCatalog = componentCatalog
		request.UserspaceBundles = []userspacerelease.Bundle{bundle}
		_, err = NewBuilder(&fakeRunner{}).Build(context.Background(), request)
		if err == nil || !strings.Contains(err.Error(), "current directory") {
			t.Fatalf("error = %v, want portable receipt rejection", err)
		}
	})
}

// TestBuilderRejectsNonAArch64Executable proves the runner boundary cannot
// smuggle an executable for a different architecture into the image.
func TestBuilderRejectsNonAArch64Executable(t *testing.T) {
	_, err := NewBuilder(&fakeRunner{machine: elf.EM_X86_64}).Build(
		context.Background(), testBuildRequest(makeTestSource(t, false), t.TempDir()),
	)
	if err == nil || !strings.Contains(err.Error(), "AArch64 ELF") {
		t.Fatalf("error = %v, want AArch64 ELF rejection", err)
	}
}

// TestBuilderChecksGitProvenance verifies exact revision and clean-tree checks,
// and confirms the development sentinel bypasses untruthful revision claims.
func TestBuilderChecksGitProvenance(t *testing.T) {
	source := makeTestSource(t, false)
	uncontrolled := testBuildRequest(source, t.TempDir())
	uncontrolled.Commit = strings.Repeat("a", 40)
	if _, err := NewBuilder(&fakeRunner{}).Build(context.Background(), uncontrolled); err == nil ||
		!strings.Contains(err.Error(), "explicit working-tree") {
		t.Fatalf("non-Git provenance error = %v", err)
	}
	if err := os.Mkdir(filepath.Join(source, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	request := testBuildRequest(source, t.TempDir())
	request.Commit = strings.Repeat("a", 40)
	runner := &fakeRunner{revision: strings.Repeat("b", 40)}
	if _, err := NewBuilder(runner).Build(context.Background(), request); err == nil || !strings.Contains(err.Error(), "source revision") {
		t.Fatalf("revision mismatch error = %v", err)
	}
	runner = &fakeRunner{revision: request.Commit, status: " M README.md\n"}
	if _, err := NewBuilder(runner).Build(context.Background(), request); err == nil || !strings.Contains(err.Error(), "source is dirty") {
		t.Fatalf("dirty source error = %v", err)
	}
	request.Commit = DevelopmentCommit
	runner = &fakeRunner{captureErr: errors.New("Git should not be called")}
	if _, err := NewBuilder(runner).Build(context.Background(), request); err != nil {
		t.Fatalf("explicit development snapshot failed: %v", err)
	}
	if len(runner.captureCommands) != 0 {
		t.Fatalf("development snapshot issued %d Git commands", len(runner.captureCommands))
	}
}

// TestValidateRecordRejectsInvalidArtefacts checks malformed and duplicate
// manifest paths after all companion-specific shape checks pass.
func TestValidateRecordRejectsInvalidArtefacts(t *testing.T) {
	source := makeTestSource(t, false)
	record, err := NewBuilder(&fakeRunner{}).Build(context.Background(), testBuildRequest(source, t.TempDir()))
	if err != nil {
		t.Fatal(err)
	}
	invalidDigest := record
	invalidDigest.SourceArchive = cloneArtifact(record.SourceArchive)
	invalidDigest.SourceArchive.SHA256 = "INVALID"
	if err := ValidateRecord(invalidDigest); err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("invalid digest error = %v", err)
	}
	duplicate := record
	duplicate.Catalogues = append([]imagecontract.ArtifactRecord(nil), record.Catalogues...)
	duplicate.Catalogues[1] = duplicate.Catalogues[0]
	if err := ValidateRecord(duplicate); err == nil {
		t.Fatal("duplicate companion artefact path was accepted")
	}
	absent := Absent("")
	if absent.Reason != OmissionReasonNotRequested || ValidateRecord(absent) != nil {
		t.Fatalf("default absent record is invalid: %#v", absent)
	}
	absent.Userspace = nil
	if err := ValidateRecord(absent); err == nil || !strings.Contains(err.Error(), "explicit JSON array") {
		t.Fatalf("nil userspace array error = %v", err)
	}
	absent = Absent("operator-choice")
	if err := ValidateRecord(absent); err == nil || !strings.Contains(err.Error(), OmissionReasonNotRequested) {
		t.Fatalf("unknown omission reason error = %v", err)
	}
	policyBypass := record
	policyBypass.Userspace = []imagecontract.OfflineUserspaceRecord{{
		Component: "audio-fullio-v19c", Release: "sp11-audio-v19c",
		Redistribution: string(userspacecatalog.RedistributionAllowed),
		Root:           ISOFilesystemRoot + "/userspace/audio-fullio-v19c/sp11-audio-v19c",
		Artifacts: []imagecontract.ArtifactRecord{{
			Path:   ISOFilesystemRoot + "/userspace/audio-fullio-v19c/sp11-audio-v19c/" + userspaceReceiptName,
			SHA256: strings.Repeat("a", 64), Size: 1,
		}},
	}}
	if err := ValidateRecord(policyBypass); err == nil || !strings.Contains(err.Error(), "compiled companion policy") {
		t.Fatalf("compiled allow-list bypass error = %v", err)
	}
}

// TestValidateDirectoryRejectsClosedSetViolations checks undeclared files,
// symlinks, and incorrect executable permissions in an extracted host tree.
func TestValidateDirectoryRejectsClosedSetViolations(t *testing.T) {
	for _, testCase := range []struct {
		name   string
		mutate func(*testing.T, string)
		match  string
	}{
		{name: "undeclared file", match: "undeclared file", mutate: func(t *testing.T, root string) {
			if err := os.WriteFile(filepath.Join(root, "unexpected"), []byte("no"), 0o644); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "symlink", match: "symbolic link", mutate: func(t *testing.T, root string) {
			target := filepath.Join(root, "catalogues", imageCatalogueName)
			if err := os.Remove(target); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(filepath.Join(root, "catalogues", userspaceCatalogueName), target); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "executable mode", match: "mode", mutate: func(t *testing.T, root string) {
			if err := os.Chmod(filepath.Join(root, filepath.FromSlash(executableRelativePath)), 0o644); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "root directory mode", match: "directory \".\" mode", mutate: func(t *testing.T, root string) {
			if err := os.Chmod(root, 0o700); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "nested directory mode", match: "directory \"catalogues\" mode", mutate: func(t *testing.T, root string) {
			if err := os.Chmod(filepath.Join(root, "catalogues"), 0o777); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			destination := t.TempDir()
			record, err := NewBuilder(&fakeRunner{}).Build(
				context.Background(), testBuildRequest(makeTestSource(t, false), destination),
			)
			if err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(destination, filepath.FromSlash(ISOFilesystemRoot))
			testCase.mutate(t, root)
			if err := ValidateDirectory(record, root); err == nil || !strings.Contains(err.Error(), testCase.match) {
				t.Fatalf("validation error = %v, want %q", err, testCase.match)
			}
		})
	}
}

// assertPublishedDirectoryModes checks that the builder explicitly publishes
// its complete directory tree with deterministic 0755 traversal permissions.
func assertPublishedDirectoryModes(t *testing.T, root string) {
	t.Helper()
	parentInfo, err := os.Lstat(filepath.Dir(root))
	if err != nil {
		t.Fatal(err)
	}
	if parentInfo.Mode().Perm() != 0o755 || parentInfo.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		t.Fatalf("published companion parent mode = %04o, want 0755", parentInfo.Mode().Perm())
	}
	if err := filepath.WalkDir(root, func(itemPath string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Mode().Perm() != 0o755 || info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
			return errors.New("published companion directory does not have mode 0755")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

// makeTestSource creates the smallest maintained CLI-shaped source tree backed
// by the repository's real validated catalogues.
func makeTestSource(t *testing.T, withLicence bool) string {
	t.Helper()
	root := t.TempDir()
	for _, directory := range []string{filepath.Join("cmd", "linux-armer"), "docs", "internal", "tools"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	files := map[string]string{
		"go.mod":     "module example.invalid/linux-armer\n\ngo 1.26\n",
		"go.sum":     "",
		"catalog.go": "package linuxarmer\n",
		filepath.Join("cmd", "linux-armer", "main.go"):             "package main\nfunc main() {}\n",
		filepath.Join("internal", "logic.go"):                      "package internal\n",
		filepath.Join("docs", "README.md"):                         "# Documentation\n",
		filepath.Join("tools", "collect-sp11-windows-handoff.ps1"): "# Strict Windows hand-off collector\n",
		"README.md":    "# linux-armer\n",
		"CHANGELOG.md": "# Changelog\n",
		".gitignore":   "/bin/\n/linux-armer\n/*.iso\n",
	}
	if withLicence {
		files["LICENSE"] = "test redistribution terms\n"
		files["NOTICE.md"] = "test notice\n"
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	moduleRoot, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{imageCatalogueName, userspaceCatalogueName} {
		content, err := os.ReadFile(filepath.Join(moduleRoot, name))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, name), content, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// testBuildRequest returns one deterministic core-only development request.
func testBuildRequest(source, destination string) BuildRequest {
	return BuildRequest{
		SourceDirectory: source, DestinationDirectory: destination,
		Version: "v0.1.0-test", Commit: DevelopmentCommit,
		BuildDate: "2026-08-30T12:00:00Z",
	}
}

// makeVerifiedBundle creates one exact catalogue-backed bundle and its portable
// receipt using locally computed immutable identities.
func makeVerifiedBundle(t *testing.T, componentCatalog *userspacecatalog.Catalog, componentID string) userspacerelease.Bundle {
	t.Helper()
	component, found := componentCatalog.Get(componentID)
	if !found || component.Release == nil {
		t.Fatalf("test catalogue has no release for %s", componentID)
	}
	directory := t.TempDir()
	names := append([]string(nil), component.Release.AssetAllowlist...)
	sort.Strings(names)
	files := make([]userspacerelease.File, 0, len(names))
	for _, name := range names {
		content := []byte("verified " + name + "\n")
		hash := sha256.Sum256(content)
		filePath := filepath.Join(directory, name)
		if err := os.WriteFile(filePath, content, 0o644); err != nil {
			t.Fatal(err)
		}
		files = append(files, userspacerelease.File{
			Name: name, Path: filePath, SHA256: hex.EncodeToString(hash[:]),
			Size: int64(len(content)), Verified: true,
		})
	}
	bundle := userspacerelease.Bundle{
		Component: component.ID, Repository: "owner/repository",
		Release: component.Release.Tag, Directory: directory, Files: files,
	}
	originalContract := iptsdOfflineReleaseContract
	iptsdOfflineReleaseContract = userspacepolicy.Release{
		Component: bundle.Component, Repository: bundle.Repository, Tag: bundle.Release,
		Artifacts: make([]userspacepolicy.Artifact, len(bundle.Files)),
	}
	for index, file := range bundle.Files {
		iptsdOfflineReleaseContract.Artifacts[index] = userspacepolicy.Artifact{
			Name: file.Name, SHA256: file.SHA256, Size: file.Size,
		}
	}
	t.Cleanup(func() { iptsdOfflineReleaseContract = originalContract })
	receipt := bundle
	receipt.Directory = "."
	receipt.Files = append([]userspacerelease.File(nil), files...)
	for index := range receipt.Files {
		receipt.Files[index].Path = receipt.Files[index].Name
	}
	content, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	content = append(content, '\n')
	if err := os.WriteFile(filepath.Join(directory, userspaceReceiptName), content, 0o644); err != nil {
		t.Fatal(err)
	}
	return bundle
}

// writeSyntheticELF writes a minimal little-endian 64-bit executable header
// accepted by debug/elf for the requested machine architecture.
func writeSyntheticELF(destination string, machine elf.Machine) error {
	header := make([]byte, 64)
	copy(header[0:4], []byte{0x7f, 'E', 'L', 'F'})
	header[4] = byte(elf.ELFCLASS64)
	header[5] = byte(elf.ELFDATA2LSB)
	header[6] = byte(elf.EV_CURRENT)
	binary.LittleEndian.PutUint16(header[16:18], uint16(elf.ET_EXEC))
	binary.LittleEndian.PutUint16(header[18:20], uint16(machine))
	binary.LittleEndian.PutUint32(header[20:24], uint32(elf.EV_CURRENT))
	binary.LittleEndian.PutUint16(header[52:54], 64)
	binary.LittleEndian.PutUint16(header[54:56], 56)
	binary.LittleEndian.PutUint16(header[58:60], 64)
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	return os.WriteFile(destination, header, 0o755)
}

// argumentAfter returns the argument immediately following name, or an empty
// string when the command does not contain the requested pair.
func argumentAfter(arguments []string, name string) string {
	for index := 0; index+1 < len(arguments); index++ {
		if arguments[index] == name {
			return arguments[index+1]
		}
	}
	return ""
}

// containsAll reports whether values contains every requested string.
func containsAll(values []string, requested ...string) bool {
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		seen[value] = true
	}
	for _, value := range requested {
		if !seen[value] {
			return false
		}
	}
	return true
}

// readSourceArchive returns every regular source member by its tar path.
func readSourceArchive(t *testing.T, archivePath string) map[string][]byte {
	t.Helper()
	file, err := os.Open(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		t.Fatal(err)
	}
	defer gzipReader.Close()
	reader := tar.NewReader(gzipReader)
	files := make(map[string][]byte)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		content, err := io.ReadAll(reader)
		if err != nil {
			t.Fatal(err)
		}
		files[header.Name] = content
	}
	return files
}

// writeTemporaryArchive publishes archive bytes for reuse by the tar reader
// helper and returns its canonical absolute path.
func writeTemporaryArchive(t *testing.T, content []byte) string {
	t.Helper()
	archivePath := filepath.Join(t.TempDir(), "source.tar.gz")
	if err := os.WriteFile(archivePath, content, 0o644); err != nil {
		t.Fatal(err)
	}
	return archivePath
}

// cloneArtifact returns a writable copy of one optional artefact pointer.
func cloneArtifact(record *imagecontract.ArtifactRecord) *imagecontract.ArtifactRecord {
	if record == nil {
		return nil
	}
	clone := *record
	return &clone
}
