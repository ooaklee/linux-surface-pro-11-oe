package iptsd

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestPinnedReleaseFixture validates the complete published release when its
// securely extracted root is supplied by an integration test environment.
func TestPinnedReleaseFixture(t *testing.T) {
	root := os.Getenv("LINUX_ARMER_TEST_IPTSD_RELEASE_ROOT")
	if root == "" {
		t.Skip("set LINUX_ARMER_TEST_IPTSD_RELEASE_ROOT to an extracted sp11-iptsd-v1 root")
	}
	release, err := ValidateRelease(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(release.Files) != 28 {
		t.Fatalf("install files = %d, want 28", len(release.Files))
	}
	for _, file := range release.Files {
		if file.Size <= 0 || len(file.SHA256) != 64 || filepath.IsAbs(file.Target) {
			t.Fatalf("invalid install file: %+v", file)
		}
	}
}

// TestPublishedV1DocumentationAlternativeRemainsInstallable proves that the
// immutable release's historical README identity is accepted, propagated into
// the copy plan, and does not weaken rejection of any unreviewed third variant.
func TestPublishedV1DocumentationAlternativeRemainsInstallable(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate IPTSD contract test source")
	}
	repositoryRoot := filepath.Clean(filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "..", ".."))
	integrationRoot := copyTree(t, filepath.Join(repositoryRoot, "userspace", "iptsd-sp11"))
	legacyREADME, err := os.ReadFile(filepath.Join(filepath.Dir(sourceFile), "testdata", "sp11-iptsd-v1-readme.fixture"))
	if err != nil {
		t.Fatal(err)
	}
	readmePath := filepath.Join(integrationRoot, "README.md")
	if err := os.WriteFile(readmePath, legacyREADME, 0o644); err != nil {
		t.Fatal(err)
	}

	manifest, err := validateIntegration(integrationRoot)
	if err != nil {
		t.Fatalf("validate published v1 integration: %v", err)
	}
	matched := manifest["README.md"]
	if matched.sha256 != "69a92f448f64f3d16b59770869bb7a5411470dd153770765fce97f68c41bd687" || matched.size != 3204 {
		t.Fatalf("matched README identity = %+v", matched)
	}
	planned := integrationInstallFile(integrationRoot, manifest, "README.md", "usr/local/share/doc/sp11-iptsd/README.md", 0o644)
	if planned.SHA256 != matched.sha256 || planned.Size != matched.size {
		t.Fatalf("planned README identity = %s/%d, want %s/%d", planned.SHA256, planned.Size, matched.sha256, matched.size)
	}

	if err := os.WriteFile(readmePath, append(legacyREADME, '!'), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := ValidateIntegration(integrationRoot); err == nil || !strings.Contains(err.Error(), "approved contract") {
		t.Fatalf("unreviewed README error = %v", err)
	}
}

// TestPayloadRejectsMutationAndUnexpectedShape verifies that binary changes,
// extra files, and payload links cannot survive the fixed checksum authority.
func TestPayloadRejectsMutationAndUnexpectedShape(t *testing.T) {
	fixture := os.Getenv("LINUX_ARMER_TEST_IPTSD_RELEASE_ROOT")
	if fixture == "" {
		t.Skip("set LINUX_ARMER_TEST_IPTSD_RELEASE_ROOT to exercise payload mutations")
	}
	source := filepath.Join(fixture, filepath.FromSlash(PayloadRelative))
	integration := filepath.Join(fixture, filepath.FromSlash(IntegrationRelative))
	t.Run("mutated binary", func(t *testing.T) {
		root := copyTree(t, source)
		path := filepath.Join(root, "bin", "sp11-iptsd")
		file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.Write([]byte{0}); err != nil {
			_ = file.Close()
			t.Fatal(err)
		}
		if err := file.Close(); err != nil {
			t.Fatal(err)
		}
		if _, err := ValidatePayload(root, integration); err == nil {
			t.Fatal("mutated binary passed validation")
		}
	})
	t.Run("unexpected file", func(t *testing.T) {
		root := copyTree(t, source)
		if err := os.WriteFile(filepath.Join(root, "unexpected"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := ValidatePayload(root, integration); err == nil || !strings.Contains(err.Error(), "unexpected") {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("symlinked licence", func(t *testing.T) {
		root := copyTree(t, source)
		path := filepath.Join(root, "licenses", "LICENSE.iptsd")
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink("LICENSE.integration", path); err != nil {
			t.Fatal(err)
		}
		if _, err := ValidatePayload(root, integration); err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Fatalf("error = %v", err)
		}
	})
}

// TestPayloadManifestRejectsHostilePathsAndDuplicates verifies the parser's
// canonical relative-path and unique-entry boundaries independently of hashes.
func TestPayloadManifestRejectsHostilePathsAndDuplicates(t *testing.T) {
	digest := hex.EncodeToString(make([]byte, 32))
	for name, data := range map[string]string{
		"traversal": digest + "  ./../escape\n",
		"absolute":  digest + "  .//escape\n",
		"duplicate": digest + "  ./one\n" + digest + "  ./one\n",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parsePayloadManifest([]byte(data)); err == nil {
				t.Fatal("hostile payload manifest passed")
			}
		})
	}
}

// TestAArch64ELFRejectsWrongMachineAndLinks verifies architecture and no-link
// executable validation before binaries can enter an installation plan.
func TestAArch64ELFRejectsWrongMachineAndLinks(t *testing.T) {
	header := make([]byte, 20)
	copy(header, []byte{0x7f, 'E', 'L', 'F', 2, 1})
	header[18] = 62
	path := filepath.Join(t.TempDir(), "binary")
	if err := os.WriteFile(path, header, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := validateAArch64ELF(path); err == nil || !strings.Contains(err.Error(), "AArch64") {
		t.Fatalf("error = %v", err)
	}
	link := filepath.Join(filepath.Dir(path), "link")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if err := validateAArch64ELF(link); err == nil || !strings.Contains(err.Error(), "non-symlink") {
		t.Fatalf("error = %v", err)
	}
}

// TestIntegrationRejectsLinksAndMutation verifies that released human text and
// templates cannot be substituted after the compiled contract is reviewed.
func TestIntegrationRejectsLinksAndMutation(t *testing.T) {
	fixture := os.Getenv("LINUX_ARMER_TEST_IPTSD_RELEASE_ROOT")
	if fixture == "" {
		t.Skip("set LINUX_ARMER_TEST_IPTSD_RELEASE_ROOT to exercise release mutations")
	}
	source := filepath.Join(fixture, filepath.FromSlash(IntegrationRelative))
	t.Run("mutated template", func(t *testing.T) {
		root := copyTree(t, source)
		path := filepath.Join(root, "packaging", "sp11-iptsd@.service.in")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, append(data, '#'), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := ValidateIntegration(root); err == nil || !strings.Contains(err.Error(), "size") {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("symlinked config", func(t *testing.T) {
		root := copyTree(t, source)
		path := filepath.Join(root, "config", "surface-pro-11-0c80.conf")
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink("surface-pro-11-0c83.conf", path); err != nil {
			t.Fatal(err)
		}
		if err := ValidateIntegration(root); err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Fatalf("error = %v", err)
		}
	})
}

// copyTree copies a private test fixture without retaining symbolic links.
func copyTree(t *testing.T, source string) string {
	t.Helper()
	destination := t.TempDir()
	err := filepath.WalkDir(source, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(source, path)
		if err != nil || relative == "." {
			return err
		}
		target := filepath.Join(destination, relative)
		if entry.IsDir() {
			return os.Mkdir(target, 0o755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	return destination
}
