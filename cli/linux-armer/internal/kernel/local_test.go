package kernel

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const (
	testLocalABI     = "7.2.0-jg-0sp11v19-qcom-x1e"
	testLocalVersion = "7.2.0-jg-0sp11v19"
)

func TestDiscoverLocalBundleWithoutChecksumManifest(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	imageName, modulesName := writeLocalPair(t, directory, testLocalABI, testLocalVersion)
	writeLocalFile(t, filepath.Join(directory, "README.txt"), "ignored")
	writeLocalFile(t, filepath.Join(directory, "linux-headers-"+testLocalABI+"_"+testLocalVersion+"_arm64.deb"), "headers")
	writeLocalFile(t, filepath.Join(directory, "linux-image-6.8.0-generic_6.8.0_arm64.deb"), "generic")

	bundle, err := DiscoverLocalBundle(directory)
	if err != nil {
		t.Fatalf("DiscoverLocalBundle() error = %v", err)
	}

	if bundle.SchemaVersion != BundleSchemaVersion {
		t.Fatalf("SchemaVersion = %d, want %d", bundle.SchemaVersion, BundleSchemaVersion)
	}
	if bundle.Release != localReleasePrefix+testLocalABI {
		t.Fatalf("Release = %q, want %q", bundle.Release, localReleasePrefix+testLocalABI)
	}
	if bundle.Repository != "" {
		t.Fatalf("Repository = %q, want empty for local bundle", bundle.Repository)
	}
	if bundle.ABI != testLocalABI || bundle.Version != testLocalVersion || bundle.Architecture != "arm64" {
		t.Fatalf("derived ABI/version/architecture = %q/%q/%q", bundle.ABI, bundle.Version, bundle.Architecture)
	}
	if len(bundle.DeviceTrees) != 2 {
		t.Fatalf("DeviceTrees length = %d, want the validated Surface Pro 11 set", len(bundle.DeviceTrees))
	}
	if len(bundle.Packages) != 2 {
		t.Fatalf("Packages length = %d, want 2", len(bundle.Packages))
	}

	for _, expectation := range []struct {
		role PackageRole
		name string
		data string
	}{
		{role: RoleImage, name: imageName, data: "image package"},
		{role: RoleModules, name: modulesName, data: "modules package"},
	} {
		pkg, ok := bundle.Package(expectation.role)
		if !ok {
			t.Errorf("Package(%q) not found", expectation.role)
			continue
		}
		if pkg.Name != expectation.name {
			t.Errorf("Package(%q).Name = %q, want %q", expectation.role, pkg.Name, expectation.name)
		}
		if !filepath.IsAbs(pkg.Path) || pkg.Path != filepath.Join(directory, expectation.name) {
			t.Errorf("Package(%q).Path = %q, want absolute discovered path", expectation.role, pkg.Path)
		}
		if pkg.SHA256 != localDigest(expectation.data) {
			t.Errorf("Package(%q).SHA256 = %q, want calculated digest", expectation.role, pkg.SHA256)
		}
		if pkg.Size != int64(len(expectation.data)) {
			t.Errorf("Package(%q).Size = %d, want %d", expectation.role, pkg.Size, len(expectation.data))
		}
		if pkg.Verified {
			t.Errorf("Package(%q).Verified = true without %s", expectation.role, localChecksumManifest)
		}
	}
}

func TestDiscoverLocalBundleVerifiesChecksumManifest(t *testing.T) {
	t.Parallel()

	directory := t.TempDir()
	imageName, modulesName := writeLocalPair(t, directory, testLocalABI, testLocalVersion)
	manifest := fmt.Sprintf(
		"%s  %s\n%s *%s\n%s  unrelated-release-note.txt\n",
		strings.ToUpper(localDigest("image package")),
		imageName,
		localDigest("modules package"),
		modulesName,
		strings.Repeat("c", 64),
	)
	writeLocalFile(t, filepath.Join(directory, localChecksumManifest), manifest)

	bundle, err := DiscoverLocalBundle(directory)
	if err != nil {
		t.Fatalf("DiscoverLocalBundle() error = %v", err)
	}
	for _, role := range []PackageRole{RoleImage, RoleModules} {
		pkg, ok := bundle.Package(role)
		if !ok {
			t.Fatalf("Package(%q) not found", role)
		}
		if !pkg.Verified {
			t.Errorf("Package(%q).Verified = false with matching %s", role, localChecksumManifest)
		}
	}
}

func TestDiscoverLocalBundleRejectsPackageSelectionProblems(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		setup func(*testing.T, string)
		want  []string
	}{
		{
			name: "missing image",
			setup: func(t *testing.T, directory string) {
				writeLocalRuntimePackage(t, directory, RoleModules, testLocalABI, testLocalVersion, "modules")
			},
			want: []string{"exactly one", "linux-image", "found none"},
		},
		{
			name: "missing modules",
			setup: func(t *testing.T, directory string) {
				writeLocalRuntimePackage(t, directory, RoleImage, testLocalABI, testLocalVersion, "image")
			},
			want: []string{"exactly one", "linux-modules", "found none"},
		},
		{
			name: "generic ARM packages are not Surface packages",
			setup: func(t *testing.T, directory string) {
				writeLocalRuntimePackage(t, directory, RoleImage, "6.8.0-generic", "6.8.0", "image")
				writeLocalRuntimePackage(t, directory, RoleModules, "6.8.0-generic", "6.8.0", "modules")
			},
			want: []string{"Surface Pro 11", "linux-image", "found none"},
		},
		{
			name: "ambiguous images",
			setup: func(t *testing.T, directory string) {
				writeLocalPair(t, directory, testLocalABI, testLocalVersion)
				writeLocalRuntimePackage(t, directory, RoleImage, "7.3.0-sp11-qcom-x1e", "7.3.0-sp11", "second image")
			},
			want: []string{"ambiguous", "linux-image", "7.2.0", "7.3.0"},
		},
		{
			name: "ambiguous modules",
			setup: func(t *testing.T, directory string) {
				writeLocalPair(t, directory, testLocalABI, testLocalVersion)
				writeLocalRuntimePackage(t, directory, RoleModules, "7.3.0-sp11-qcom-x1e", "7.3.0-sp11", "second modules")
			},
			want: []string{"ambiguous", "linux-modules", "7.2.0", "7.3.0"},
		},
		{
			name: "ABI mismatch",
			setup: func(t *testing.T, directory string) {
				writeLocalRuntimePackage(t, directory, RoleImage, testLocalABI, testLocalVersion, "image")
				writeLocalRuntimePackage(t, directory, RoleModules, "7.2.1-jg-0sp11v20-qcom-x1e", testLocalVersion, "modules")
			},
			want: []string{"ABI mismatch", testLocalABI, "7.2.1-jg-0sp11v20-qcom-x1e"},
		},
		{
			name: "package version mismatch",
			setup: func(t *testing.T, directory string) {
				writeLocalRuntimePackage(t, directory, RoleImage, testLocalABI, testLocalVersion, "image")
				writeLocalRuntimePackage(t, directory, RoleModules, testLocalABI, testLocalVersion+".1", "modules")
			},
			want: []string{"package version mismatch", testLocalVersion, testLocalVersion + ".1"},
		},
		{
			name: "candidate directory is not a package",
			setup: func(t *testing.T, directory string) {
				imageName, _ := localPackageNames(testLocalABI, testLocalVersion)
				if err := os.Mkdir(filepath.Join(directory, imageName), 0o755); err != nil {
					t.Fatalf("os.Mkdir(candidate) error = %v", err)
				}
				writeLocalRuntimePackage(t, directory, RoleModules, testLocalABI, testLocalVersion, "modules")
			},
			want: []string{"kernel package", "is not a regular file"},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			directory := t.TempDir()
			test.setup(t, directory)
			_, err := DiscoverLocalBundle(directory)
			assertLocalErrorContains(t, err, test.want...)
		})
	}
}

func TestDiscoverLocalBundleRejectsSymbolicLinkPackage(t *testing.T) {
	t.Parallel()
	if runtime.GOOS == "windows" {
		t.Skip("symbolic link creation is not reliably available on Windows")
	}

	directory := t.TempDir()
	imageName, _ := localPackageNames(testLocalABI, testLocalVersion)
	target := filepath.Join(directory, "image-target")
	writeLocalFile(t, target, "image")
	if err := os.Symlink(target, filepath.Join(directory, imageName)); err != nil {
		t.Fatalf("os.Symlink(package) error = %v", err)
	}
	writeLocalRuntimePackage(t, directory, RoleModules, testLocalABI, testLocalVersion, "modules")

	_, err := DiscoverLocalBundle(directory)
	assertLocalErrorContains(t, err, imageName, "symbolic link")
}

func TestDiscoverLocalBundleChecksumManifestValidation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		manifest func(string, string) string
		want     []string
	}{
		{
			name: "empty",
			manifest: func(_, _ string) string {
				return ""
			},
			want: []string{localChecksumManifest, "empty"},
		},
		{
			name: "malformed line",
			manifest: func(_, _ string) string {
				return "only-one-field\n"
			},
			want: []string{"SHA256SUMS:1", "expected '<sha256>  <filename>'"},
		},
		{
			name: "short digest",
			manifest: func(_, imageName string) string {
				return "abcd  " + imageName + "\n"
			},
			want: []string{"SHA256SUMS:1", "64 hexadecimal"},
		},
		{
			name: "non hexadecimal digest",
			manifest: func(_, imageName string) string {
				return strings.Repeat("z", 64) + "  " + imageName + "\n"
			},
			want: []string{"SHA256SUMS:1", "invalid SHA-256"},
		},
		{
			name: "unsafe parent path",
			manifest: func(_, _ string) string {
				return strings.Repeat("a", 64) + "  ../outside.deb\n"
			},
			want: []string{"SHA256SUMS:1", "unsafe filename"},
		},
		{
			name: "unsafe cross-platform path",
			manifest: func(_, _ string) string {
				return strings.Repeat("a", 64) + "  nested\\outside.deb\n"
			},
			want: []string{"SHA256SUMS:1", "unsafe filename"},
		},
		{
			name: "duplicate entry",
			manifest: func(_, imageName string) string {
				return strings.Repeat("a", 64) + "  " + imageName + "\n" +
					strings.Repeat("b", 64) + "  " + imageName + "\n"
			},
			want: []string{"SHA256SUMS:2", "duplicate entry"},
		},
		{
			name: "missing image coverage",
			manifest: func(modulesName, _ string) string {
				return localDigest("modules package") + "  " + modulesName + "\n"
			},
			want: []string{localChecksumManifest, "does not cover", "linux-image"},
		},
		{
			name: "image checksum mismatch",
			manifest: func(modulesName, imageName string) string {
				return strings.Repeat("0", 64) + "  " + imageName + "\n" +
					localDigest("modules package") + "  " + modulesName + "\n"
			},
			want: []string{"SHA-256 mismatch", "linux-image", "expected", "got"},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			directory := t.TempDir()
			imageName, modulesName := writeLocalPair(t, directory, testLocalABI, testLocalVersion)
			writeLocalFile(t, filepath.Join(directory, localChecksumManifest), test.manifest(modulesName, imageName))

			_, err := DiscoverLocalBundle(directory)
			assertLocalErrorContains(t, err, test.want...)
		})
	}
}

func TestDiscoverLocalBundleRejectsInvalidChecksumManifestFile(t *testing.T) {
	t.Parallel()

	t.Run("directory", func(t *testing.T) {
		t.Parallel()

		directory := t.TempDir()
		writeLocalPair(t, directory, testLocalABI, testLocalVersion)
		if err := os.Mkdir(filepath.Join(directory, localChecksumManifest), 0o755); err != nil {
			t.Fatalf("os.Mkdir(SHA256SUMS) error = %v", err)
		}
		_, err := DiscoverLocalBundle(directory)
		assertLocalErrorContains(t, err, localChecksumManifest, "not a regular file")
	})

	t.Run("symbolic link", func(t *testing.T) {
		t.Parallel()
		if runtime.GOOS == "windows" {
			t.Skip("symbolic link creation is not reliably available on Windows")
		}

		directory := t.TempDir()
		writeLocalPair(t, directory, testLocalABI, testLocalVersion)
		target := filepath.Join(directory, "checksums-target")
		writeLocalFile(t, target, "not trusted")
		if err := os.Symlink(target, filepath.Join(directory, localChecksumManifest)); err != nil {
			t.Fatalf("os.Symlink(SHA256SUMS) error = %v", err)
		}
		_, err := DiscoverLocalBundle(directory)
		assertLocalErrorContains(t, err, localChecksumManifest, "symbolic link")
	})
}

func TestDiscoverLocalBundleDirectoryErrors(t *testing.T) {
	t.Parallel()

	t.Run("empty", func(t *testing.T) {
		t.Parallel()
		_, err := DiscoverLocalBundle("\t")
		assertLocalErrorContains(t, err, "directory is required")
	})

	t.Run("missing", func(t *testing.T) {
		t.Parallel()
		path := filepath.Join(t.TempDir(), "missing")
		_, err := DiscoverLocalBundle(path)
		assertLocalErrorContains(t, err, "inspect directory", "missing")
	})

	t.Run("regular file", func(t *testing.T) {
		t.Parallel()
		path := filepath.Join(t.TempDir(), "kernel.deb")
		writeLocalFile(t, path, "not a directory")
		_, err := DiscoverLocalBundle(path)
		assertLocalErrorContains(t, err, "is not a directory")
	})
}

func writeLocalPair(t *testing.T, directory, abi, version string) (string, string) {
	t.Helper()

	imageName := writeLocalRuntimePackage(t, directory, RoleImage, abi, version, "image package")
	modulesName := writeLocalRuntimePackage(t, directory, RoleModules, abi, version, "modules package")
	return imageName, modulesName
}

func writeLocalRuntimePackage(t *testing.T, directory string, role PackageRole, abi, version, content string) string {
	t.Helper()

	imageName, modulesName := localPackageNames(abi, version)
	name := imageName
	if role == RoleModules {
		name = modulesName
	}
	writeLocalFile(t, filepath.Join(directory, name), content)
	return name
}

func localPackageNames(abi, version string) (string, string) {
	return "linux-image-" + abi + "_" + version + "_arm64.deb",
		"linux-modules-" + abi + "_" + version + "_arm64.deb"
}

func writeLocalFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("os.WriteFile(%q) error = %v", path, err)
	}
}

func localDigest(content string) string {
	digest := sha256.Sum256([]byte(content))
	return hex.EncodeToString(digest[:])
}

func assertLocalErrorContains(t *testing.T, err error, values ...string) {
	t.Helper()
	if err == nil {
		t.Fatalf("error = nil, want text %v", values)
	}
	for _, value := range values {
		if !strings.Contains(err.Error(), value) {
			t.Errorf("error = %q, want text %q", err, value)
		}
	}
}
