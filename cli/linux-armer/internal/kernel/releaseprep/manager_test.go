package releaseprep

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel/build"
)

const (
	// fixtureABI is the in-tree touchscreen ABI used by native release tests.
	fixtureABI = "7.2.0-jg-0sp11v19-qcom-x1e"
	// fixtureVersion is the Debian version encoded by every fixture package.
	fixtureVersion = "7.2.0-jg-0sp11v19"
	// fixtureRelease is the public tag-like identity selected by the fixture.
	fixtureRelease = "sp11-qcom-x1e-7.2.0-jg-0sp11v19"
	// fixtureGitURL is the credential-free source remote used by the fixture.
	fixtureGitURL = "https://example.invalid/owner/kernel"
)

// releaseFixture contains one exact native build and its explicit public inputs.
type releaseFixture struct {
	// Root is the isolated test filesystem root.
	Root string
	// Build is the exact native builder output directory.
	Build string
	// Output is the initially absent release publication path.
	Output string
	// Source is the corresponding-source archive.
	Source string
	// Licence is the explicit licence text.
	Licence string
	// Request is the complete preparation request.
	Request Request
}

// TestPreparePublishesAndRevalidatesClosedRelease proves successful native
// preparation, durability, exact membership, path redaction, and revalidation.
func TestPreparePublishesAndRevalidatesClosedRelease(t *testing.T) {
	fixture := newReleaseFixture(t, false)
	manager := New()
	manager.now = func() time.Time { return time.Date(2026, time.August, 30, 12, 0, 0, 0, time.UTC) }
	receipt, err := manager.Prepare(context.Background(), fixture.Request)
	if err != nil {
		t.Fatalf("Prepare() error = %v", err)
	}
	if !receipt.Published || !receipt.Durable || receipt.Plan.DryRun {
		t.Fatalf("Prepare() receipt = %#v", receipt)
	}
	manifest, err := manager.Validate(context.Background(), fixture.Output)
	if err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	if manifest.ABI != fixtureABI || manifest.Version != fixtureVersion || manifest.HardwareQualified || !manifest.Experimental {
		t.Fatalf("validated manifest = %#v", manifest)
	}
	entries, err := os.ReadDir(fixture.Output)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := len(entries), 8; got != want {
		t.Fatalf("release entry count = %d, want %d", got, want)
	}
	encoded, err := json.Marshal(receipt)
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{fixture.Root, "linux-armer-kernel-build-0123456789abcdef", "source_path", "output_directory", "build_directory"} {
		if strings.Contains(string(encoded), private) {
			t.Errorf("public receipt leaked %q: %s", private, encoded)
		}
	}
	notes, err := os.ReadFile(filepath.Join(fixture.Output, ReleaseNotesFileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"licence evidence", "hardware-qualified", "does not make it"} {
		if !strings.Contains(string(notes), expected) {
			t.Errorf("release notes do not contain %q:\n%s", expected, notes)
		}
	}
}

// TestPrepareDryRunIsTruthfulAndReadOnly proves the dry run performs complete
// validation while leaving both missing parents and output absent.
func TestPrepareDryRunIsTruthfulAndReadOnly(t *testing.T) {
	fixture := newReleaseFixture(t, false)
	fixture.Output = filepath.Join(fixture.Root, "missing", "nested", "release")
	fixture.Request.OutputDirectory = fixture.Output
	fixture.Request.DryRun = true
	receipt, err := New().Prepare(context.Background(), fixture.Request)
	if err != nil {
		t.Fatalf("Prepare(dry run) error = %v", err)
	}
	if !receipt.Plan.DryRun || receipt.Published || receipt.Durable || receipt.Plan.Manifest.ABI != fixtureABI {
		t.Fatalf("dry-run receipt = %#v", receipt)
	}
	if _, err := os.Lstat(filepath.Join(fixture.Root, "missing")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("dry run created a parent: %v", err)
	}
}

// TestPrepareRejectsMutationCancellationAndCollision exercises the operation's
// final byte check, caller cancellation, and fresh-output publication guard.
func TestPrepareRejectsMutationCancellationAndCollision(t *testing.T) {
	t.Run("mutation", func(t *testing.T) {
		fixture := newReleaseFixture(t, false)
		manager := New()
		mutated := false
		manager.beforeCopy = func(asset PlannedAsset) {
			if mutated || asset.Asset.Kind != AssetSource {
				return
			}
			mutated = true
			contents, err := os.ReadFile(asset.SourcePath)
			if err != nil {
				t.Fatal(err)
			}
			contents[0] ^= 0xff
			if err := os.WriteFile(asset.SourcePath, contents, 0o600); err != nil {
				t.Fatal(err)
			}
		}
		_, err := manager.Prepare(context.Background(), fixture.Request)
		if err == nil || !strings.Contains(err.Error(), "identity changed") {
			t.Fatalf("mutated input error = %v", err)
		}
		assertAbsent(t, fixture.Output)
		assertNoStaging(t, filepath.Dir(fixture.Output))
	})

	t.Run("cancellation", func(t *testing.T) {
		fixture := newReleaseFixture(t, false)
		ctx, cancel := context.WithCancel(context.Background())
		manager := New()
		manager.beforeCopy = func(PlannedAsset) { cancel() }
		_, err := manager.Prepare(ctx, fixture.Request)
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled preparation error = %v", err)
		}
		assertAbsent(t, fixture.Output)
		assertNoStaging(t, filepath.Dir(fixture.Output))
	})

	t.Run("cancellation at publication", func(t *testing.T) {
		fixture := newReleaseFixture(t, false)
		ctx, cancel := context.WithCancel(context.Background())
		manager := New()
		manager.beforePublish = cancel
		receipt, err := manager.Prepare(ctx, fixture.Request)
		if !errors.Is(err, context.Canceled) || receipt.Published {
			t.Fatalf("late-cancel receipt/error = %#v / %v", receipt, err)
		}
		assertAbsent(t, fixture.Output)
		assertNoStaging(t, filepath.Dir(fixture.Output))
	})

	t.Run("publication collision", func(t *testing.T) {
		fixture := newReleaseFixture(t, false)
		manager := New()
		manager.beforePublish = func() {
			if err := os.Mkdir(fixture.Output, 0o700); err != nil {
				t.Fatal(err)
			}
		}
		receipt, err := manager.Prepare(context.Background(), fixture.Request)
		if err == nil || !strings.Contains(err.Error(), "publish kernel release directory") || receipt.Published {
			t.Fatalf("collision receipt/error = %#v / %v", receipt, err)
		}
		entries, readErr := os.ReadDir(fixture.Output)
		if readErr != nil || len(entries) != 0 {
			t.Fatalf("colliding directory changed: %v / %#v", readErr, entries)
		}
		assertNoStaging(t, filepath.Dir(fixture.Output))
	})
}

// TestPlanRejectsNonNativeAndUnsafeInputs checks exact builder closure,
// collisions, source/licence policy, credentials, mutability, and v3 retirement.
func TestPlanRejectsNonNativeAndUnsafeInputs(t *testing.T) {
	tests := []struct {
		// name identifies the hostile condition.
		name string
		// mutate changes one otherwise valid fixture.
		mutate func(*testing.T, *releaseFixture)
		// want is the stable diagnostic fragment.
		want string
	}{
		{name: "extra builder file", mutate: func(t *testing.T, fixture *releaseFixture) {
			mustWriteFile(t, filepath.Join(fixture.Build, "unexpected"), []byte("stale"))
		}, want: "expected exactly"},
		{name: "package digest drift", mutate: func(t *testing.T, fixture *releaseFixture) {
			mustWriteFile(t, filepath.Join(fixture.Build, packageName(kernel.RoleImage)), []byte("mutated"))
		}, want: "digest contract failed"},
		{name: "bundle path drift", mutate: func(t *testing.T, fixture *releaseFixture) {
			bundle := readBundle(t, fixture.Build)
			bundle.Packages[0].Path = "/private/other.deb"
			mustWriteJSON(t, filepath.Join(fixture.Build, BundleFileName), bundle)
		}, want: "exact builder output contract"},
		{name: "credential URL", mutate: func(t *testing.T, fixture *releaseFixture) {
			provenance := readProvenance(t, fixture.Build)
			provenance.GitURL = "https://user:password@example.invalid/kernel"
			mustWriteJSON(t, filepath.Join(fixture.Build, BuildProvenanceFileName), provenance)
		}, want: "unsafe source URL"},
		{name: "URL without repository path", mutate: func(t *testing.T, fixture *releaseFixture) {
			provenance := readProvenance(t, fixture.Build)
			provenance.GitURL = "https://example.invalid/"
			mustWriteJSON(t, filepath.Join(fixture.Build, BuildProvenanceFileName), provenance)
		}, want: "unsafe source URL"},
		{name: "URL with backslash path", mutate: func(t *testing.T, fixture *releaseFixture) {
			provenance := readProvenance(t, fixture.Build)
			provenance.GitURL = `https://example.invalid/owner\kernel`
			mustWriteJSON(t, filepath.Join(fixture.Build, BuildProvenanceFileName), provenance)
		}, want: "unsafe source URL"},
		{name: "mutable image", mutate: func(t *testing.T, fixture *releaseFixture) {
			provenance := readProvenance(t, fixture.Build)
			provenance.ContainerImage = "ubuntu:latest"
			mustWriteJSON(t, filepath.Join(fixture.Build, BuildProvenanceFileName), provenance)
		}, want: "policy or toolchain"},
		{name: "invalid private volume", mutate: func(t *testing.T, fixture *releaseFixture) {
			provenance := readProvenance(t, fixture.Build)
			provenance.WorkVolume = "foreign-volume"
			mustWriteJSON(t, filepath.Join(fixture.Build, BuildProvenanceFileName), provenance)
		}, want: "private volume identity"},
		{name: "missing source", mutate: func(_ *testing.T, fixture *releaseFixture) {
			fixture.Request.SourceAssets = nil
		}, want: "corresponding-source"},
		{name: "missing licence", mutate: func(_ *testing.T, fixture *releaseFixture) {
			fixture.Request.LicenceAssets = nil
		}, want: "explicit licence"},
		{name: "unrecognised source", mutate: func(t *testing.T, fixture *releaseFixture) {
			fixture.Source = filepath.Join(fixture.Root, "source.txt")
			mustWriteFile(t, fixture.Source, []byte("not an archive"))
			fixture.Request.SourceAssets = []string{fixture.Source}
		}, want: "recognised archive"},
		{name: "source through symlink", mutate: func(t *testing.T, fixture *releaseFixture) {
			realDirectory := filepath.Join(fixture.Root, "real-source")
			linkedDirectory := filepath.Join(fixture.Root, "linked-source")
			if err := os.Mkdir(realDirectory, 0o700); err != nil {
				t.Fatal(err)
			}
			name := "linux-source-" + strings.Repeat("1", 40) + ".tar.xz"
			mustWriteFile(t, filepath.Join(realDirectory, name), []byte("source"))
			if err := os.Symlink(realDirectory, linkedDirectory); err != nil {
				t.Fatal(err)
			}
			fixture.Request.SourceAssets = []string{filepath.Join(linkedDirectory, name)}
		}, want: "symbolic link"},
		{name: "binary licence", mutate: func(t *testing.T, fixture *releaseFixture) {
			mustWriteFile(t, fixture.Licence, []byte{'l', 0, 'x'})
		}, want: "UTF-8 text"},
		{name: "supplementary collision", mutate: func(t *testing.T, fixture *releaseFixture) {
			first := filepath.Join(fixture.Root, "source", "LICENSE.tar.xz")
			second := filepath.Join(fixture.Root, "licence", "LICENSE.tar.xz")
			mustWriteFile(t, first, []byte("source"))
			mustWriteFile(t, second, []byte("licence"))
			fixture.Request.SourceAssets = []string{first}
			fixture.Request.LicenceAssets = []string{second}
		}, want: "collides"},
		{name: "case-folded supplementary collision", mutate: func(t *testing.T, fixture *releaseFixture) {
			first := filepath.Join(fixture.Root, "source", "LICENSE.tar.xz")
			second := filepath.Join(fixture.Root, "licence", "license.tar.xz")
			mustWriteFile(t, first, []byte("source"))
			mustWriteFile(t, second, []byte("licence"))
			fixture.Request.SourceAssets = []string{first}
			fixture.Request.LicenceAssets = []string{second}
		}, want: "collides"},
		{name: "legacy module", mutate: func(t *testing.T, fixture *releaseFixture) {
			legacy := filepath.Join(fixture.Root, "gpi.ko")
			mustWriteFile(t, legacy, []byte("legacy"))
			fixture.Request.SourceAssets = []string{legacy}
		}, want: "out-of-tree touchscreen"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newReleaseFixture(t, false)
			test.mutate(t, &fixture)
			_, err := New().Plan(context.Background(), fixture.Request)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Plan() error = %v, want fragment %q", err, test.want)
			}
			assertAbsent(t, fixture.Output)
		})
	}
}

// TestValidateRejectsHostileFilesystemAndJSON verifies the public validator
// fails closed for unknown/trailing JSON, links, special files, and set drift.
func TestValidateRejectsHostileFilesystemAndJSON(t *testing.T) {
	tests := []struct {
		// name identifies the hostile directory mutation.
		name string
		// mutate changes one successfully prepared directory.
		mutate func(*testing.T, releaseFixture)
		// want is the expected diagnostic fragment.
		want string
	}{
		{name: "unknown JSON field", mutate: func(t *testing.T, fixture releaseFixture) {
			path := filepath.Join(fixture.Output, ReleaseManifestFileName)
			contents, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			contents = []byte(strings.Replace(string(contents), "{", "{\n  \"unknown\": true,", 1))
			mustWriteFile(t, path, contents)
		}, want: "unknown field"},
		{name: "trailing JSON", mutate: func(t *testing.T, fixture releaseFixture) {
			path := filepath.Join(fixture.Output, ReleaseManifestFileName)
			file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := file.WriteString("{}\n"); err != nil {
				t.Fatal(err)
			}
			if err := file.Close(); err != nil {
				t.Fatal(err)
			}
		}, want: "more than one value"},
		{name: "extra file", mutate: func(t *testing.T, fixture releaseFixture) {
			mustWriteFile(t, filepath.Join(fixture.Output, "extra"), []byte("extra"))
		}, want: "expected exactly"},
		{name: "missing file", mutate: func(t *testing.T, fixture releaseFixture) {
			if err := os.Remove(filepath.Join(fixture.Output, filepath.Base(fixture.Source))); err != nil {
				t.Fatal(err)
			}
		}, want: "expected exactly"},
		{name: "symlink", mutate: func(t *testing.T, fixture releaseFixture) {
			path := filepath.Join(fixture.Output, filepath.Base(fixture.Source))
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(filepath.Base(fixture.Licence), path); err != nil {
				t.Fatal(err)
			}
		}, want: "not a regular file"},
		{name: "special file", mutate: func(t *testing.T, fixture releaseFixture) {
			path := filepath.Join(fixture.Output, filepath.Base(fixture.Source))
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if err := unix.Mkfifo(path, 0o600); err != nil {
				t.Fatal(err)
			}
		}, want: "not a regular file"},
		{name: "digest drift", mutate: func(t *testing.T, fixture releaseFixture) {
			mustWriteFile(t, filepath.Join(fixture.Output, filepath.Base(fixture.Source)), []byte("changed source"))
		}, want: "checksum mismatch"},
		{name: "release notes drift", mutate: func(t *testing.T, fixture releaseFixture) {
			path := filepath.Join(fixture.Output, ReleaseNotesFileName)
			mustWriteFile(t, path, []byte("different notes\n"))
			rewriteChecksums(t, fixture.Output)
		}, want: "release notes differ"},
		{name: "oversized release notes", mutate: func(t *testing.T, fixture releaseFixture) {
			path := filepath.Join(fixture.Output, ReleaseNotesFileName)
			mustWriteFile(t, path, bytes.Repeat([]byte{'x'}, int(maximumTextBytes)+1))
			rewriteChecksums(t, fixture.Output)
		}, want: "bounded non-empty regular file"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newReleaseFixture(t, false)
			if _, err := New().Prepare(context.Background(), fixture.Request); err != nil {
				t.Fatal(err)
			}
			test.mutate(t, fixture)
			_, err := New().Validate(context.Background(), fixture.Output)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Validate() error = %v, want fragment %q", err, test.want)
			}
		})
	}
}

// TestValidateManifestRejectsSemanticDrift checks role, ABI, version, headers,
// public provenance, source/licence, and retired touchscreen policy directly.
func TestValidateManifestRejectsSemanticDrift(t *testing.T) {
	fixture := newReleaseFixture(t, false)
	receipt, err := New().Prepare(context.Background(), fixture.Request)
	if err != nil {
		t.Fatal(err)
	}
	base := receipt.Plan.Manifest
	tests := []struct {
		// name identifies the semantic mutation.
		name string
		// mutate changes an independent manifest copy.
		mutate func(*Manifest)
	}{
		{name: "role drift", mutate: func(manifest *Manifest) { manifest.Assets[0].Role = kernel.RoleHeaders }},
		{name: "ABI drift", mutate: func(manifest *Manifest) { manifest.ABI = "7.2.0-other-qcom-x1e" }},
		{name: "version drift", mutate: func(manifest *Manifest) { manifest.Version = "7.2.0-other" }},
		{name: "unpaired headers", mutate: func(manifest *Manifest) {
			manifest.Assets = append(manifest.Assets, Asset{
				Name: "linux-headers-" + fixtureABI + "_" + fixtureVersion + "_arm64.deb",
				Kind: AssetPackage, Role: kernel.RoleHeaders, SHA256: strings.Repeat("a", 64), Size: 1,
			})
			sort.Slice(manifest.Assets, func(i, j int) bool { return manifest.Assets[i].Name < manifest.Assets[j].Name })
		}},
		{name: "credential URL", mutate: func(manifest *Manifest) { manifest.Source.GitURL = "https://token@example.invalid/kernel" }},
		{name: "mutable image", mutate: func(manifest *Manifest) { manifest.Source.ContainerImage = "ubuntu:latest" }},
		{name: "missing source", mutate: func(manifest *Manifest) { manifest.Assets = withoutKind(manifest.Assets, AssetSource) }},
		{name: "missing licence", mutate: func(manifest *Manifest) { manifest.Assets = withoutKind(manifest.Assets, AssetLicence) }},
		{name: "case-folded asset collision", mutate: func(manifest *Manifest) {
			duplicate := manifest.Assets[0]
			duplicate.Name = strings.ToLower(duplicate.Name)
			manifest.Assets = append(manifest.Assets, duplicate)
			sort.Slice(manifest.Assets, func(i, j int) bool { return manifest.Assets[i].Name < manifest.Assets[j].Name })
		}},
		{name: "legacy v3 source", mutate: func(manifest *Manifest) {
			for index := range manifest.Assets {
				if manifest.Assets[index].Kind == AssetSource {
					manifest.Assets[index].Name = "sp11v3-source.tar.xz"
				}
			}
			sort.Slice(manifest.Assets, func(i, j int) bool { return manifest.Assets[i].Name < manifest.Assets[j].Name })
		}},
		{name: "hardware claim", mutate: func(manifest *Manifest) { manifest.HardwareQualified = true }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			manifest := base
			manifest.Assets = append([]Asset(nil), base.Assets...)
			test.mutate(&manifest)
			if err := validateManifest(manifest); err == nil {
				t.Fatalf("validateManifest() accepted %#v", manifest)
			}
		})
	}
}

// newReleaseFixture writes the exact closed output emitted by the native
// builder plus corresponding source and explicit licence inputs.
func newReleaseFixture(t *testing.T, headers bool) releaseFixture {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	buildDirectory := filepath.Join(root, "native-build")
	if err := os.Mkdir(buildDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	names := []string{packageName(kernel.RoleImage), packageName(kernel.RoleModules)}
	if headers {
		names = append(names, packageName(kernel.RoleHeaders), packageName(kernel.RoleCommonHeaders))
	}
	packages := make([]kernel.Package, 0, len(names))
	checksums := make(map[string]string, len(names))
	for _, name := range names {
		contents := []byte("Debian package fixture for " + name)
		path := filepath.Join(buildDirectory, name)
		mustWriteFile(t, path, contents)
		digest := digestBytes(contents)
		role, _, _, err := kernel.ParsePackageName(name)
		if err != nil {
			t.Fatal(err)
		}
		packages = append(packages, kernel.Package{
			Role: role, Name: name, Path: path, SHA256: digest, Size: int64(len(contents)), Verified: true,
		})
		checksums[name] = digest
	}
	revision := strings.Repeat("1", 40)
	bundle, err := kernel.NewBundle("build:"+revision, fixtureGitURL, packages)
	if err != nil {
		t.Fatal(err)
	}
	mustWriteJSON(t, filepath.Join(buildDirectory, BundleFileName), bundle)
	mustWriteJSON(t, filepath.Join(buildDirectory, BuildProvenanceFileName), build.Provenance{
		GitURL: fixtureGitURL, GitRef: "sp11/integration-7.2.x", RefKind: "branch",
		Revision: revision, Tree: strings.Repeat("2", 40),
		CommitTime:     time.Date(2026, time.August, 29, 10, 0, 0, 0, time.UTC),
		RecipeSHA256:   strings.Repeat("3", 64),
		ContainerImage: "docker.io/library/ubuntu@sha256:" + strings.Repeat("4", 64),
		WorkVolume:     "linux-armer-kernel-build-0123456789abcdef", ToolchainSHA256: strings.Repeat("5", 64),
	})
	writeChecksumMap(t, filepath.Join(buildDirectory, ChecksumFileName), checksums)
	source := filepath.Join(root, "linux-source-"+revision+".tar.xz")
	licence := filepath.Join(root, "LICENSE.txt")
	mustWriteFile(t, source, []byte("corresponding source archive fixture"))
	mustWriteFile(t, licence, []byte("Example redistribution licence evidence.\n"))
	output := filepath.Join(root, "release", fixtureRelease)
	return releaseFixture{
		Root: root, Build: buildDirectory, Output: output, Source: source, Licence: licence,
		Request: Request{
			BuildDirectory: buildDirectory, OutputDirectory: output, ReleaseName: fixtureRelease,
			SourceAssets: []string{source}, LicenceAssets: []string{licence},
		},
	}
}

// packageName returns one filename satisfying the normal kernel bundle parser.
func packageName(role kernel.PackageRole) string {
	switch role {
	case kernel.RoleImage:
		return "linux-image-" + fixtureABI + "_" + fixtureVersion + "_arm64.deb"
	case kernel.RoleModules:
		return "linux-modules-" + fixtureABI + "_" + fixtureVersion + "_arm64.deb"
	case kernel.RoleHeaders:
		return "linux-headers-" + fixtureABI + "_" + fixtureVersion + "_arm64.deb"
	case kernel.RoleCommonHeaders:
		return "linux-qcom-x1e-headers-" + strings.TrimSuffix(fixtureABI, "-qcom-x1e") + "_" + fixtureVersion + "_all.deb"
	default:
		return "unsupported"
	}
}

// mustWriteFile writes one fixture file and fails the current test on error.
func mustWriteFile(t *testing.T, path string, contents []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
}

// mustWriteJSON writes one stable fixture JSON document.
func mustWriteJSON(t *testing.T, path string, value any) {
	t.Helper()
	contents, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	contents = append(contents, '\n')
	mustWriteFile(t, path, contents)
}

// digestBytes returns the lowercase SHA-256 identity of fixture bytes.
func digestBytes(contents []byte) string {
	digest := sha256.Sum256(contents)
	return hex.EncodeToString(digest[:])
}

// writeChecksumMap writes deterministic checksum lines for fixture files.
func writeChecksumMap(t *testing.T, path string, checksums map[string]string) {
	t.Helper()
	var builder strings.Builder
	for _, name := range sortedKeys(checksums) {
		_, _ = builder.WriteString(checksums[name] + "  " + name + "\n")
	}
	mustWriteFile(t, path, []byte(builder.String()))
}

// rewriteChecksums recalculates coverage for every non-checksum release file.
func rewriteChecksums(t *testing.T, directory string) {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	checksums := make(map[string]string, len(entries)-1)
	for _, entry := range entries {
		if entry.Name() == ChecksumFileName {
			continue
		}
		contents, err := os.ReadFile(filepath.Join(directory, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		checksums[entry.Name()] = digestBytes(contents)
	}
	writeChecksumMap(t, filepath.Join(directory, ChecksumFileName), checksums)
}

// readBundle decodes one fixture native bundle.
func readBundle(t *testing.T, directory string) kernel.Bundle {
	t.Helper()
	var bundle kernel.Bundle
	readFixtureJSON(t, filepath.Join(directory, BundleFileName), &bundle)
	return bundle
}

// readProvenance decodes one fixture native build provenance document.
func readProvenance(t *testing.T, directory string) build.Provenance {
	t.Helper()
	var provenance build.Provenance
	readFixtureJSON(t, filepath.Join(directory, BuildProvenanceFileName), &provenance)
	return provenance
}

// readFixtureJSON decodes one trusted fixture document for mutation.
func readFixtureJSON(t *testing.T, path string, destination any) {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(contents, destination); err != nil {
		t.Fatal(err)
	}
}

// withoutKind copies assets except those of the selected kind.
func withoutKind(assets []Asset, omitted AssetKind) []Asset {
	result := make([]Asset, 0, len(assets))
	for _, asset := range assets {
		if asset.Kind != omitted {
			result = append(result, asset)
		}
	}
	return result
}

// assertAbsent requires one fixture output path to remain absent.
func assertAbsent(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("path unexpectedly exists: %s (%v)", path, err)
	}
}

// assertNoStaging requires all private release staging directories to be gone.
func assertNoStaging(t *testing.T, parent string) {
	t.Helper()
	entries, err := os.ReadDir(parent)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".linux-armer-kernel-release-") {
			t.Fatalf("private staging directory remains: %s", entry.Name())
		}
	}
}

// TestFixtureBundleIsStable guards the helper's exact recorded-builder shape.
func TestFixtureBundleIsStable(t *testing.T) {
	fixture := newReleaseFixture(t, true)
	bundle := readBundle(t, fixture.Build)
	if len(bundle.Packages) != 4 || bundle.ABI != fixtureABI || bundle.Version != fixtureVersion {
		t.Fatalf("fixture bundle = %#v", bundle)
	}
	copy := append([]kernel.Package(nil), bundle.Packages...)
	sort.Slice(copy, func(i, j int) bool { return copy[i].Name < copy[j].Name })
	if !reflect.DeepEqual(copy, bundle.Packages) {
		t.Fatal("fixture packages are not sorted")
	}
}
