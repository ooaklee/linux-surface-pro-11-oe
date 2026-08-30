// Package iptsd owns the native build and installation contract for the
// pinned Surface Pro 11 IPTSD integration.
package iptsd

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	// ArchiveRoot is the sole top-level directory accepted from the pinned
	// source-bearing release archive.
	ArchiveRoot = "sp11-iptsd-v1"
	// PayloadRelative is the archive-relative verified build payload directory.
	PayloadRelative = "payload/iptsd-sp11"
	// IntegrationRelative is the archive-relative configuration and template
	// directory used by the native installer.
	IntegrationRelative = "userspace/iptsd-sp11"
	// Version is the exact upstream IPTSD version represented by the contract.
	Version = "3.1.0"
	// SourceRepository is the exact upstream source repository.
	SourceRepository = "https://github.com/linux-surface/iptsd.git"
	// SourceCommit is the exact upstream commit built into the payload.
	SourceCommit = "a83bc1232f7096f8b33b50fdbda249cd640de670"
	// SourceTree is the exact upstream tree object built into the payload.
	SourceTree = "06c6e812873e117930eca60b8a32cec40fd13281"
	// DefaultBuildImage is the reviewed ARM64 container image tag.
	DefaultBuildImage = "ubuntu:26.04"
	// DefaultWorkVolume is the stable Linux-native Docker build volume.
	DefaultWorkVolume = "sp11-iptsd-v3-1-0-build"
	// DefaultJobs is the bounded parallelism used when the caller supplies zero.
	DefaultJobs = 8
	// payloadManifestDigest pins the complete payload file names and digests.
	payloadManifestDigest = "cb5deea2432d3bee698309067a381edf3e1268fdd98ad6f61911e2acfd4556b4"
	// payloadManifestSize is the exact byte length of the pinned manifest.
	payloadManifestSize = int64(4002)
	// maximumPayloadFiles bounds recursive validation work.
	maximumPayloadFiles = 64
	// maximumPayloadBytes bounds the complete extracted payload.
	maximumPayloadBytes = int64(64 << 20)
	// maximumMetadataBytes bounds individual textual provenance files.
	maximumMetadataBytes = int64(1 << 20)
)

// fileSpec pins one archive-relative regular file by size and digest.
type fileSpec struct {
	path   string
	sha256 string
	size   int64
}

// integrationFiles is the exact checked-in and released integration file set.
var integrationFiles = []fileSpec{
	{path: "LICENSE.integration", sha256: "f8126478d63d42239b27e3364ac188d56b5abb0716c021271c1265c556ceed65", size: 1067},
	{path: "PAYLOAD.sha256", sha256: payloadManifestDigest, size: payloadManifestSize},
	{path: "README.md", sha256: "81276a49753bc6c2f548c5593d752d2f9ef02b7201232f86962012f91e0eb626", size: 3575},
	{path: "SOURCE.env", sha256: "1ff7395738b95a0ef4ffd780a9b6415733e7003040ae0b56b4b984c3bcd25278", size: 336},
	{path: "config/surface-pro-11-0c80.conf", sha256: "e629f67248df412d69952accc874b848e3e45ad3d8b31cbec4626f85c12c8c34", size: 98},
	{path: "config/surface-pro-11-0c83.conf", sha256: "358953d2171b36879043dc46084cc9344ea2c28cc718ff75690acd479214bf59", size: 98},
	{path: "packaging/70-sp11-iptsd.rules.in", sha256: "256c30e4b8b931ea04dc235e132d005645e1cb70e4a56f330e8c29e25289d95b", size: 685},
	{path: "packaging/sp11-iptsd-restart.in", sha256: "12ce4e484da438fd3b1aa842488764bec27242c50bb081cbce6236b07b9d6382", size: 2779},
	{path: "packaging/sp11-iptsd@.service.in", sha256: "7c30ee0d7aba247fc96cda0289da5385f0a876c5a7974ed0df3f314b2edbecaa", size: 340},
}

// payloadTopLevelFiles is the exact non-directory payload root file set.
var payloadTopLevelFiles = []string{
	"APT.sources.txt", "BUILD.env", "FILE.txt", "LDD.check-device.txt",
	"LDD.iptsd.txt", "SBOM.dpkg.tsv", "SHA256SUMS", "SOURCE.env",
}

// payloadBinaryNames is the exact executable payload set.
var payloadBinaryNames = []string{"sp11-iptsd", "sp11-iptsd-check-device"}

// payloadLicenceNames is the exact redistributed licence and notice set.
var payloadLicenceNames = []string{
	"COPYING.Eigen.APACHE", "COPYING.Eigen.BSD", "COPYING.Eigen.MINPACK",
	"COPYING.Eigen.MPL2", "COPYING.Eigen.README", "LICENSE.CLI11",
	"LICENSE.Eigen", "LICENSE.Eigen.build", "LICENSE.Microsoft-GSL",
	"LICENSE.Microsoft-GSL.build", "LICENSE.fmt", "LICENSE.fmt.build",
	"LICENSE.inih", "LICENSE.integration", "LICENSE.iptsd", "LICENSE.spdlog",
	"LICENSE.spdlog.build",
}

// payloadSourceNames is the exact corresponding-source and fallback-source set.
var payloadSourceNames = []string{
	"CLI11-2.6.1.tar.gz", "GSL-4.2.0.zip", "cli11.wrap",
	"eigen-5.0.1.tar.bz2", "eigen.wrap", "eigen_5.0.1-1_patch.zip",
	"fmt-12.0.0.tar.gz", "fmt.wrap", "fmt_12.0.0-1_patch.zip",
	"inih-r62.tar.gz", "inih.wrap", "iptsd-" + SourceCommit + ".tar.gz",
	"microsoft-gsl.wrap", "microsoft-gsl_4.2.0-1_patch.zip",
	"spdlog-1.15.3.tar.gz", "spdlog.wrap", "spdlog_1.15.3-5_patch.zip",
}

// renderedSpecs pins the three deterministic integration outputs expected by
// installed-system status checks and the published release.
var renderedSpecs = map[string]fileSpec{
	"70-sp11-iptsd.rules": {
		path: "etc/udev/rules.d/70-sp11-iptsd.rules", sha256: "2723ddfa7afb431368fce31419cb77b97853286ac37fd824d418e5c3bc8e2327", size: 725,
	},
	"sp11-iptsd-restart": {
		path: "usr/lib/systemd/system-sleep/sp11-iptsd-restart", sha256: "9a81548cef754a1ed933ad2c6f540ca916e6101848c1616402bbe355232ac102", size: 2848,
	},
	"sp11-iptsd@.service": {
		path: "etc/systemd/system/sp11-iptsd@.service", sha256: "74add71ef414c09547434db92e3f3faeee5909a8181dd28317d9d54cd77f2e4a", size: 362,
	},
}

// InstallFile is one fully validated source or rendered byte sequence destined
// for a fixed system path.
type InstallFile struct {
	// Source is the regular extracted file path, empty for rendered content.
	Source string
	// SourceLabel is an archive-relative provenance label safe for receipts.
	SourceLabel string
	// Data contains deterministic rendered content when Source is empty.
	Data []byte
	// Target is the target-root-relative system path.
	Target string
	// Mode is the exact installed permission mode.
	Mode fs.FileMode
	// SHA256 pins the source or rendered bytes through publication.
	SHA256 string
	// Size pins the exact source or rendered length.
	Size int64
}

// Release is a completely validated extracted release ready for planning or
// atomic installation.
type Release struct {
	// PayloadRoot is the validated extracted payload directory.
	PayloadRoot string
	// IntegrationRoot is the validated extracted integration directory.
	IntegrationRoot string
	// Files is the complete fixed installation file set.
	Files []InstallFile
}

// ValidateRelease validates the exact payload, configurations, templates,
// licences, checksums, binaries, and provenance in an extracted pinned archive.
func ValidateRelease(archiveRoot string) (Release, error) {
	archiveRoot, err := cleanRegularDirectory(archiveRoot)
	if err != nil {
		return Release{}, fmt.Errorf("validate IPTSD archive root: %w", err)
	}
	payloadRoot := filepath.Join(archiveRoot, filepath.FromSlash(PayloadRelative))
	integrationRoot := filepath.Join(archiveRoot, filepath.FromSlash(IntegrationRelative))
	if err := ValidateIntegration(integrationRoot); err != nil {
		return Release{}, err
	}
	manifest, err := ValidatePayload(payloadRoot, integrationRoot)
	if err != nil {
		return Release{}, err
	}
	rendered, err := RenderIntegration(integrationRoot)
	if err != nil {
		return Release{}, err
	}
	files := installFiles(payloadRoot, integrationRoot, manifest, rendered)
	return Release{PayloadRoot: payloadRoot, IntegrationRoot: integrationRoot, Files: files}, nil
}

// ValidateIntegration checks the exact fixed configuration and template tree
// against the published sp11-iptsd-v1 release contract.
func ValidateIntegration(root string) error {
	root, err := cleanRegularDirectory(root)
	if err != nil {
		return fmt.Errorf("validate IPTSD integration: %w", err)
	}
	expected := make(map[string]fileSpec, len(integrationFiles))
	for _, spec := range integrationFiles {
		expected[spec.path] = spec
	}
	actual, err := exactRegularFiles(root, len(expected), maximumMetadataBytes)
	if err != nil {
		return fmt.Errorf("validate IPTSD integration: %w", err)
	}
	if err := validateExactSet(actual, expected); err != nil {
		return fmt.Errorf("validate IPTSD integration: %w", err)
	}
	for relative, spec := range expected {
		if err := validateFile(filepath.Join(root, filepath.FromSlash(relative)), spec); err != nil {
			return fmt.Errorf("validate IPTSD integration %s: %w", relative, err)
		}
	}
	return validateSourceIdentity(filepath.Join(root, "SOURCE.env"))
}

// ValidatePayload checks the exact closed payload file set, all recorded
// digests, AArch64 binaries, build provenance, sources, and licences.
func ValidatePayload(payloadRoot, integrationRoot string) (map[string]fileSpec, error) {
	payloadRoot, err := cleanRegularDirectory(payloadRoot)
	if err != nil {
		return nil, fmt.Errorf("validate IPTSD payload: %w", err)
	}
	manifestPath := filepath.Join(payloadRoot, "SHA256SUMS")
	manifestSpec := fileSpec{path: "SHA256SUMS", sha256: payloadManifestDigest, size: payloadManifestSize}
	if err := validateFile(manifestPath, manifestSpec); err != nil {
		return nil, fmt.Errorf("validate IPTSD payload manifest: %w", err)
	}
	manifestData, err := readRegularBounded(manifestPath, payloadManifestSize)
	if err != nil {
		return nil, fmt.Errorf("read IPTSD payload manifest: %w", err)
	}
	manifest, err := parsePayloadManifest(manifestData)
	if err != nil {
		return nil, err
	}
	manifest["SHA256SUMS"] = manifestSpec
	actual, err := exactRegularFiles(payloadRoot, maximumPayloadFiles, maximumPayloadBytes)
	if err != nil {
		return nil, fmt.Errorf("validate IPTSD payload: %w", err)
	}
	if err := validateExactSet(actual, manifest); err != nil {
		return nil, fmt.Errorf("validate IPTSD payload: %w", err)
	}
	for relative, spec := range manifest {
		if err := validateFile(filepath.Join(payloadRoot, filepath.FromSlash(relative)), spec); err != nil {
			return nil, fmt.Errorf("validate IPTSD payload %s: %w", relative, err)
		}
		info, err := os.Lstat(filepath.Join(payloadRoot, filepath.FromSlash(relative)))
		if err != nil {
			return nil, fmt.Errorf("restat IPTSD payload %s: %w", relative, err)
		}
		spec.size = info.Size()
		manifest[relative] = spec
	}
	if err := validatePayloadNames(manifest); err != nil {
		return nil, err
	}
	for _, name := range payloadBinaryNames {
		if err := validateAArch64ELF(filepath.Join(payloadRoot, "bin", name)); err != nil {
			return nil, err
		}
	}
	if err := validateBuildProvenance(filepath.Join(payloadRoot, "BUILD.env")); err != nil {
		return nil, err
	}
	if err := equalRegularFiles(filepath.Join(payloadRoot, "SOURCE.env"), filepath.Join(integrationRoot, "SOURCE.env")); err != nil {
		return nil, fmt.Errorf("payload source identity differs from integration pin: %w", err)
	}
	if err := equalRegularFiles(manifestPath, filepath.Join(integrationRoot, "PAYLOAD.sha256")); err != nil {
		return nil, fmt.Errorf("payload checksum manifest differs from integration pin: %w", err)
	}
	return manifest, nil
}

// RenderIntegration substitutes only the four fixed executable paths in the
// three pinned templates and revalidates each deterministic output digest.
func RenderIntegration(root string) (map[string][]byte, error) {
	templates := map[string]string{
		"70-sp11-iptsd.rules": "packaging/70-sp11-iptsd.rules.in",
		"sp11-iptsd-restart":  "packaging/sp11-iptsd-restart.in",
		"sp11-iptsd@.service": "packaging/sp11-iptsd@.service.in",
	}
	replacer := strings.NewReplacer(
		"@IPTSD@", "/usr/local/libexec/sp11-iptsd",
		"@CHECKER@", "/usr/local/libexec/sp11-iptsd-check-device",
		"@SYSTEMCTL@", "/usr/bin/systemctl",
		"@SYSTEMD_ESCAPE@", "/usr/bin/systemd-escape",
	)
	rendered := make(map[string][]byte, len(templates))
	for name, relative := range templates {
		data, err := readRegularBounded(filepath.Join(root, filepath.FromSlash(relative)), maximumMetadataBytes)
		if err != nil {
			return nil, fmt.Errorf("read IPTSD template %s: %w", relative, err)
		}
		output := []byte(replacer.Replace(string(data)))
		if bytes.Contains(output, []byte("@IPTSD@")) || bytes.Contains(output, []byte("@CHECKER@")) ||
			bytes.Contains(output, []byte("@SYSTEMCTL@")) || bytes.Contains(output, []byte("@SYSTEMD_ESCAPE@")) {
			return nil, fmt.Errorf("IPTSD template %s retains an unresolved placeholder", relative)
		}
		spec := renderedSpecs[name]
		if int64(len(output)) != spec.size || digestBytes(output) != spec.sha256 {
			return nil, fmt.Errorf("rendered IPTSD integration %s disagrees with the pinned release", name)
		}
		rendered[name] = output
	}
	return rendered, nil
}

// installFiles projects validated sources and rendered integration into the
// exact writable system topology.
func installFiles(payloadRoot, integrationRoot string, manifest map[string]fileSpec, rendered map[string][]byte) []InstallFile {
	files := []InstallFile{
		payloadInstallFile(payloadRoot, manifest, "bin/sp11-iptsd", "usr/local/libexec/sp11-iptsd", 0o755),
		payloadInstallFile(payloadRoot, manifest, "bin/sp11-iptsd-check-device", "usr/local/libexec/sp11-iptsd-check-device", 0o755),
		integrationInstallFile(integrationRoot, "config/surface-pro-11-0c80.conf", "usr/local/share/iptsd/surface-pro-11-0c80.conf", 0o644),
		integrationInstallFile(integrationRoot, "config/surface-pro-11-0c83.conf", "usr/local/share/iptsd/surface-pro-11-0c83.conf", 0o644),
		integrationInstallFile(integrationRoot, "README.md", "usr/local/share/doc/sp11-iptsd/README.md", 0o644),
		payloadInstallFile(payloadRoot, manifest, "SOURCE.env", "usr/local/share/doc/sp11-iptsd/SOURCE.env", 0o644),
		payloadInstallFile(payloadRoot, manifest, "BUILD.env", "usr/local/share/doc/sp11-iptsd/BUILD.env", 0o644),
		payloadInstallFile(payloadRoot, manifest, "SHA256SUMS", "usr/local/share/doc/sp11-iptsd/SHA256SUMS", 0o644),
	}
	for _, name := range payloadLicenceNames {
		files = append(files, payloadInstallFile(payloadRoot, manifest, "licenses/"+name, "usr/local/share/doc/sp11-iptsd/"+name, 0o644))
	}
	renderedNames := []string{"sp11-iptsd@.service", "70-sp11-iptsd.rules", "sp11-iptsd-restart"}
	for _, name := range renderedNames {
		spec := renderedSpecs[name]
		mode := fs.FileMode(0o644)
		if name == "sp11-iptsd-restart" {
			mode = 0o755
		}
		files = append(files, InstallFile{
			SourceLabel: "rendered:" + name, Data: append([]byte(nil), rendered[name]...),
			Target: spec.path, Mode: mode, SHA256: spec.sha256, Size: spec.size,
		})
	}
	return files
}

// payloadInstallFile constructs one payload-backed installation record.
func payloadInstallFile(root string, manifest map[string]fileSpec, source, target string, mode fs.FileMode) InstallFile {
	spec := manifest[source]
	return InstallFile{
		Source: filepath.Join(root, filepath.FromSlash(source)), SourceLabel: "archive:" + PayloadRelative + "/" + source,
		Target: target, Mode: mode, SHA256: spec.sha256, Size: spec.size,
	}
}

// integrationInstallFile constructs one pinned integration-backed record.
func integrationInstallFile(root, source, target string, mode fs.FileMode) InstallFile {
	var selected fileSpec
	for _, spec := range integrationFiles {
		if spec.path == source {
			selected = spec
			break
		}
	}
	return InstallFile{
		Source: filepath.Join(root, filepath.FromSlash(source)), SourceLabel: "archive:" + IntegrationRelative + "/" + source,
		Target: target, Mode: mode, SHA256: selected.sha256, Size: selected.size,
	}
}

// validatePayloadNames requires exact file sets at each meaningful payload
// level instead of accepting an altered manifest with plausible content.
func validatePayloadNames(manifest map[string]fileSpec) error {
	groups := map[string][]string{
		"":         payloadTopLevelFiles,
		"bin":      payloadBinaryNames,
		"licenses": payloadLicenceNames,
		"sources":  payloadSourceNames,
	}
	for directory, expectedNames := range groups {
		actualNames := make([]string, 0)
		for relative := range manifest {
			if filepath.ToSlash(filepath.Dir(relative)) == directory || directory == "" && filepath.Dir(relative) == "." {
				actualNames = append(actualNames, filepath.Base(relative))
			}
		}
		sort.Strings(actualNames)
		expected := append([]string(nil), expectedNames...)
		sort.Strings(expected)
		if !equalStrings(actualNames, expected) {
			return fmt.Errorf("IPTSD payload has an unexpected file set under %q", directory)
		}
	}
	return nil
}

// parsePayloadManifest decodes the pinned sha256sum form with canonical,
// unique, bounded relative paths.
func parsePayloadManifest(data []byte) (map[string]fileSpec, error) {
	manifest := make(map[string]fileSpec)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), 16<<10)
	for scanner.Scan() {
		line := scanner.Text()
		if len(line) < 68 || line[64:68] != "  ./" {
			return nil, errors.New("IPTSD payload SHA256SUMS contains a malformed line")
		}
		digest := line[:64]
		if _, err := hex.DecodeString(digest); err != nil || strings.ToLower(digest) != digest {
			return nil, errors.New("IPTSD payload SHA256SUMS contains an invalid digest")
		}
		relative := line[68:]
		if err := validateRelative(relative); err != nil {
			return nil, fmt.Errorf("IPTSD payload SHA256SUMS: %w", err)
		}
		if _, duplicate := manifest[relative]; duplicate {
			return nil, fmt.Errorf("IPTSD payload SHA256SUMS repeats %q", relative)
		}
		manifest[relative] = fileSpec{path: relative, sha256: digest, size: -1}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read IPTSD payload SHA256SUMS: %w", err)
	}
	if len(manifest) != 43 {
		return nil, fmt.Errorf("IPTSD payload SHA256SUMS contains %d files, expected 43", len(manifest))
	}
	return manifest, nil
}

// exactRegularFiles walks one private tree while rejecting links, special
// files, excessive file counts, and excessive aggregate bytes.
func exactRegularFiles(root string, maximumFiles int, maximumBytes int64) (map[string]fileSpec, error) {
	actual := make(map[string]fileSpec)
	var total int64
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == root {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("tree contains symbolic link %s", path)
		}
		if info.IsDir() {
			return nil
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("tree contains non-regular file %s", path)
		}
		if len(actual) == maximumFiles || info.Size() < 0 || total > maximumBytes-info.Size() {
			return errors.New("tree exceeds validation limits")
		}
		total += info.Size()
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if err := validateRelative(relative); err != nil {
			return err
		}
		actual[relative] = fileSpec{path: relative, size: info.Size()}
		return nil
	})
	return actual, err
}

// validateExactSet reports missing or unexpected regular files deterministically.
func validateExactSet(actual, expected map[string]fileSpec) error {
	var missing, unexpected []string
	for name := range expected {
		if _, ok := actual[name]; !ok {
			missing = append(missing, name)
		}
	}
	for name := range actual {
		if _, ok := expected[name]; !ok {
			unexpected = append(unexpected, name)
		}
	}
	sort.Strings(missing)
	sort.Strings(unexpected)
	if len(missing) != 0 || len(unexpected) != 0 {
		return fmt.Errorf("file set mismatch: missing=%v unexpected=%v", missing, unexpected)
	}
	return nil
}

// validateFile checks one final non-link regular file against its expected
// digest and optional exact size.
func validateFile(path string, spec fileSpec) error {
	file, info, err := openRegular(path)
	if err != nil {
		return err
	}
	defer file.Close()
	if spec.size >= 0 && info.Size() != spec.size {
		return fmt.Errorf("size is %d, expected %d", info.Size(), spec.size)
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, io.LimitReader(file, maximumPayloadBytes+1)); err != nil {
		return err
	}
	if got := hex.EncodeToString(hash.Sum(nil)); got != spec.sha256 {
		return fmt.Errorf("SHA-256 is %s, expected %s", got, spec.sha256)
	}
	return nil
}

// validateAArch64ELF checks the exact executable mode and ELF identity needed
// by the target ARM64 userspace.
func validateAArch64ELF(path string) error {
	file, info, err := openRegular(path)
	if err != nil {
		return fmt.Errorf("validate IPTSD binary: %w", err)
	}
	defer file.Close()
	if info.Mode().Perm()&0o111 == 0 {
		return fmt.Errorf("IPTSD binary is not executable: %s", path)
	}
	header := make([]byte, 20)
	if _, err := io.ReadFull(file, header); err != nil {
		return fmt.Errorf("read IPTSD ELF header: %w", err)
	}
	if !bytes.Equal(header[:6], []byte{0x7f, 'E', 'L', 'F', 2, 1}) || binary.LittleEndian.Uint16(header[18:20]) != 183 {
		return fmt.Errorf("IPTSD binary is not a 64-bit little-endian AArch64 ELF: %s", path)
	}
	return nil
}

// validateBuildProvenance checks fixed architecture, image, and access-control
// declarations without sourcing the untrusted environment file.
func validateBuildProvenance(path string) error {
	data, err := readRegularBounded(path, maximumMetadataBytes)
	if err != nil {
		return fmt.Errorf("read IPTSD build provenance: %w", err)
	}
	values := make(map[string]string)
	seen := make(map[string]struct{})
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		key, value, found := strings.Cut(line, "=")
		_, duplicate := seen[key]
		if !found || key == "" || duplicate {
			return errors.New("IPTSD BUILD.env is malformed or repeats a key")
		}
		seen[key] = struct{}{}
		values[key] = value
	}
	if values["BUILD_ARCH"] != "aarch64" {
		return errors.New("IPTSD BUILD.env does not identify an AArch64 build")
	}
	if !validSHAIdentity(values["BUILD_IMAGE_ID"]) {
		return errors.New("IPTSD BUILD.env does not pin the container image ID")
	}
	digestIndex := strings.Index(values["BUILD_IMAGE_DIGEST"], "@sha256:")
	if digestIndex < 1 || !validHex(values["BUILD_IMAGE_DIGEST"][digestIndex+8:], 64) {
		return errors.New("IPTSD BUILD.env does not pin the container repository digest")
	}
	if !strings.Contains(values["MESON_OPTIONS"], "-Dforce_access_checks=true") {
		return errors.New("IPTSD BUILD.env omits forced access checks")
	}
	return nil
}

// validateSourceIdentity checks the fixed source environment as plain data.
func validateSourceIdentity(path string) error {
	data, err := readRegularBounded(path, maximumMetadataBytes)
	if err != nil {
		return err
	}
	want := map[string]string{
		"IPTSD_VERSION": Version, "IPTSD_REPOSITORY": SourceRepository,
		"IPTSD_COMMIT": SourceCommit, "IPTSD_TREE": SourceTree,
		"IPTSD_INTEGRATION_REPOSITORY": "https://github.com/turbineBMW/surface-pro-11-linux.git",
		"IPTSD_INTEGRATION_COMMIT":     "05e5335bc72476d44390336701cf03efa5fd0165",
	}
	got := make(map[string]string)
	seen := make(map[string]struct{})
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		key, value, found := strings.Cut(line, "=")
		_, duplicate := seen[key]
		if !found || key == "" || duplicate {
			return errors.New("IPTSD SOURCE.env is malformed or repeats a key")
		}
		seen[key] = struct{}{}
		got[key] = value
	}
	if len(got) != len(want) {
		return errors.New("IPTSD SOURCE.env has an unexpected key set")
	}
	for key, value := range want {
		if got[key] != value {
			return fmt.Errorf("IPTSD SOURCE.env %s differs from the compiled pin", key)
		}
	}
	return nil
}

// readRegularBounded reads one final non-link regular file through an explicit
// limit and rejects size changes around the read.
func readRegularBounded(path string, maximum int64) ([]byte, error) {
	file, info, err := openRegular(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	if info.Size() < 0 || info.Size() > maximum {
		return nil, fmt.Errorf("file exceeds %d bytes", maximum)
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != info.Size() {
		return nil, errors.New("file changed while it was read")
	}
	return data, nil
}

// openRegular rejects final links and non-regular files before opening bytes.
func openRegular(path string) (*os.File, fs.FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, nil, fmt.Errorf("path is not a regular non-symlink file: %s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		_ = file.Close()
		return nil, nil, errors.New("file identity changed while it was opened")
	}
	return file, opened, nil
}

// cleanRegularDirectory resolves one directory and rejects a link at its final
// component before recursive validation.
func cleanRegularDirectory(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	info, err := os.Lstat(absolute)
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("path is not a regular directory: %s", absolute)
	}
	return filepath.Clean(absolute), nil
}

// equalRegularFiles compares two bounded regular files without following final
// symbolic links.
func equalRegularFiles(left, right string) error {
	leftData, err := readRegularBounded(left, maximumMetadataBytes)
	if err != nil {
		return err
	}
	rightData, err := readRegularBounded(right, maximumMetadataBytes)
	if err != nil {
		return err
	}
	if !bytes.Equal(leftData, rightData) {
		return errors.New("file contents differ")
	}
	return nil
}

// validateRelative requires a canonical non-empty slash path beneath a root.
func validateRelative(relative string) error {
	if relative == "" || strings.Contains(relative, `\`) || filepath.IsAbs(relative) || filepath.ToSlash(filepath.Clean(relative)) != relative ||
		relative == "." || relative == ".." || strings.HasPrefix(relative, "../") {
		return fmt.Errorf("unsafe relative path %q", relative)
	}
	return nil
}

// validSHAIdentity recognises the exact sha256:<hex> image-ID form.
func validSHAIdentity(value string) bool {
	return strings.HasPrefix(value, "sha256:") && validHex(strings.TrimPrefix(value, "sha256:"), 64)
}

// validHex recognises one lowercase hexadecimal string of an exact length.
func validHex(value string, length int) bool {
	if len(value) != length {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' && character < 'a' || character > 'f' {
			return false
		}
	}
	return true
}

// digestBytes returns the lowercase SHA-256 digest of in-memory content.
func digestBytes(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

// equalStrings compares already sorted string slices without another package
// dependency.
func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
