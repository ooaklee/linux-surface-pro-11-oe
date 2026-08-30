package iptsd

import (
	"encoding/hex"
	"os"
	"path/filepath"
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
