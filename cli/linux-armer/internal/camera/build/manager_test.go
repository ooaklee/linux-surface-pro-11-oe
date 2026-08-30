package build

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

// testBase is the exact source authority used by isolated Git fixtures.
const testBase = `Upstream project: https://git.libcamera.org/libcamera/libcamera.git
Upstream tag: v0.7.0
Upstream commit: b7854fd07d42168f099b5ce30d1702e0e0875bf5
Ubuntu package validated on device: 0.7.0-1ubuntu2 (arm64, resolute)
Ubuntu DSC SHA-256: 27a10011fd5efe43564e94bb0328342ec11441963bed37db10a2d524553a02d8
Ubuntu orig tarball SHA-256: ebd90a3aa2ca87a39323ffb7a4f5bbf72090b43a2431133759620b63e982db87
Ubuntu Debian tarball SHA-256: 0ee3195d74ad85b089c62eb7b2904023f8556544b2d9dbcc67aa834ddde5a09e
Patch validation: dry-run applies after Ubuntu's 0.7.0-1ubuntu2 patch series
IPA validation: native package proof required
Turbine userspace source: repository b1f5237957b9, libcamera tip 72dc8cff6447
Validation date: 2026-08-29
`

// fakeCameraRunner simulates Docker and Debian inspection while delegating Git.
type fakeCameraRunner struct {
	commands      []platform.Command
	tuning        []byte
	packageFields map[string]string
	cancelRun     bool
}

// Run executes simulated mutation commands or delegates harmless Git commands.
func (runner *fakeCameraRunner) Run(ctx context.Context, command platform.Command) error {
	runner.commands = append(runner.commands, command)
	if command.Name == "docker" && len(command.Args) > 0 && command.Args[0] == "run" {
		if runner.cancelRun {
			return context.Canceled
		}
		return runner.materialiseExchange(command)
	}
	if command.Name == "dpkg-deb" && len(command.Args) == 3 && command.Args[0] == "--extract" {
		return runner.extractProof(command.Args[1], command.Args[2])
	}
	if command.Name == "dpkg-deb" && len(command.Args) == 3 && command.Args[0] == "--field" {
		if command.Stdout == nil {
			return errors.New("static package field inspection lacks an output stream")
		}
		_, err := io.WriteString(command.Stdout, runner.packageField(command.Args[1], command.Args[2])+"\n")
		return err
	}
	if command.Name == "dpkg-deb" && len(command.Args) == 2 && command.Args[0] == "--fsys-tarfile" {
		if command.Stdout == nil {
			return errors.New("static package inspection lacks an output stream")
		}
		archive := tar.NewWriter(command.Stdout)
		header := &tar.Header{
			Name: "./usr/share/libcamera/ipa/simple/imx681.yaml",
			Mode: 0o644,
			Size: int64(len(runner.tuning)),
		}
		if err := archive.WriteHeader(header); err != nil {
			return err
		}
		if _, err := archive.Write(runner.tuning); err != nil {
			return err
		}
		return archive.Close()
	}
	if command.Name == "git" {
		return platform.ExecRunner{}.Run(ctx, command)
	}
	return nil
}

// Capture returns deterministic engine, package, Git, and verifier evidence.
func (runner *fakeCameraRunner) Capture(ctx context.Context, command platform.Command) ([]byte, error) {
	runner.commands = append(runner.commands, command)
	if command.Name == "git" {
		return platform.ExecRunner{}.Capture(ctx, command)
	}
	if command.Name == "df" {
		return []byte("Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 999999999 1 999999998 1% /\n"), nil
	}
	if command.Name == "id" && len(command.Args) == 1 {
		return []byte("501\n"), nil
	}
	if command.Name == "docker" && len(command.Args) > 0 && command.Args[0] == "version" {
		return []byte("linux|arm64|29.0.0\n"), nil
	}
	if command.Name == "docker" && len(command.Args) > 1 && command.Args[0] == "image" && command.Args[1] == "inspect" {
		return []byte("sha256:" + strings.Repeat("a", 64) + "|linux|arm64\n"), nil
	}
	if command.Name == "dpkg-deb" && len(command.Args) == 3 && command.Args[0] == "--field" {
		return []byte(runner.packageField(command.Args[1], command.Args[2]) + "\n"), nil
	}
	if strings.HasSuffix(command.Name, string(filepath.Separator)+"ipa_verify") {
		return []byte("IPA module signature is valid\n"), nil
	}
	return nil, fmt.Errorf("unexpected captured command: %s %v", command.Name, command.Args)
}

// packageField derives fixed package metadata from a selected artefact basename.
func (runner *fakeCameraRunner) packageField(path, field string) string {
	if value, ok := runner.packageFields[field]; ok {
		return value
	}
	basename := filepath.Base(path)
	packageName := ""
	version := ""
	for _, candidate := range runtimePackages {
		prefix := candidate + "_"
		if strings.HasPrefix(basename, prefix) && strings.HasSuffix(basename, "_arm64.deb") {
			packageName = candidate
			version = strings.TrimSuffix(strings.TrimPrefix(basename, prefix), "_arm64.deb")
			break
		}
	}
	switch field {
	case "Package":
		return packageName
	case "Source":
		return SourcePackage
	case "Version":
		return version
	case "Architecture":
		return Architecture
	default:
		return ""
	}
}

// materialiseExchange creates one coherent fake seven-file container output.
func (runner *fakeCameraRunner) materialiseExchange(command platform.Command) error {
	exchange := ""
	buildID := ""
	for index := 0; index < len(command.Args); index++ {
		if command.Args[index] == "--mount" && index+1 < len(command.Args) {
			value := command.Args[index+1]
			if strings.Contains(value, "dst=/exchange") {
				for _, field := range strings.Split(value, ",") {
					if strings.HasPrefix(field, "src=") {
						exchange = strings.TrimPrefix(field, "src=")
					}
				}
			}
		}
		if command.Args[index] == "--env" && index+1 < len(command.Args) && strings.HasPrefix(command.Args[index+1], "BUILD_ID=") {
			buildID = strings.TrimPrefix(command.Args[index+1], "BUILD_ID=")
		}
	}
	if exchange == "" || buildID == "" {
		return errors.New("fake Docker command lacks exchange or build identity")
	}
	version := expectedUbuntuVersion + "+sp11.2." + buildID
	artifactDirectory := filepath.Join(exchange, "artifacts")
	metadataDirectory := filepath.Join(exchange, "metadata")
	for _, packageName := range runtimePackages {
		name := packageName + "_" + version + "_arm64.deb"
		if err := os.WriteFile(filepath.Join(artifactDirectory, name), []byte("package:"+packageName+":"+version), 0o644); err != nil {
			return err
		}
	}
	buildinfoName := "libcamera_" + version + "_arm64.buildinfo"
	buildinfo := []byte("Source: libcamera\nVersion: " + version + "\nArchitecture: arm64\n")
	if err := os.WriteFile(filepath.Join(artifactDirectory, buildinfoName), buildinfo, 0o644); err != nil {
		return err
	}
	var checksumLines strings.Builder
	for _, packageName := range runtimePackages {
		name := packageName + "_" + version + "_arm64.deb"
		data, _ := os.ReadFile(filepath.Join(artifactDirectory, name))
		fmt.Fprintf(&checksumLines, " %s %d %s\n", digestBytes(data), len(data), name)
	}
	fmt.Fprintf(&checksumLines, " %s %d %s\n", digestBytes(buildinfo), len(buildinfo), buildinfoName)
	fmt.Fprintf(&checksumLines, " %s %d %s\n", strings.Repeat("b", 64), 17, "libcamera-dev_"+version+"_arm64.deb")
	changes := []byte("Source: libcamera\nVersion: " + version + "\nArchitecture: arm64\nChecksums-Sha256:\n" + checksumLines.String())
	if err := os.WriteFile(filepath.Join(artifactDirectory, "libcamera_"+version+"_arm64.changes"), changes, 0o644); err != nil {
		return err
	}
	metadata := map[string]string{
		"copyright-sha256":  strings.Repeat("c", 64) + "\n",
		"copyright-size":    "1234\n",
		"ipa-verification":  "IPA module signature is valid",
		"package-version":   version,
		"recipe-sha256":     recipeSHA256(),
		"source-url":        sourceURL(expectedUbuntuVersion),
		"support-head":      environmentValue(command.Args, "SUPPORT_HEAD"),
		"support-head-time": environmentValue(command.Args, "SUPPORT_HEAD_TIME"),
		"toolchain-sha256":  strings.Repeat("d", 64) + "\n",
	}
	for name, value := range metadata {
		if err := os.WriteFile(filepath.Join(metadataDirectory, name), []byte(value), 0o600); err != nil {
			return err
		}
	}
	return nil
}

// extractProof creates the files required by the independent host IPA proof.
func (runner *fakeCameraRunner) extractProof(packagePath, root string) error {
	basename := filepath.Base(packagePath)
	if strings.HasPrefix(basename, "libcamera-ipa_") {
		module := filepath.Join(root, "usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so")
		if err := os.MkdirAll(filepath.Dir(module), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(module, []byte("module"), 0o644); err != nil {
			return err
		}
		if err := os.WriteFile(module+".sign", []byte("signature"), 0o644); err != nil {
			return err
		}
		tuning := filepath.Join(root, "usr/share/libcamera/ipa/simple/imx681.yaml")
		if err := os.MkdirAll(filepath.Dir(tuning), 0o755); err != nil {
			return err
		}
		return os.WriteFile(tuning, runner.tuning, 0o644)
	}
	if strings.HasPrefix(basename, "libcamera-tools_") {
		verifier := filepath.Join(root, "usr/bin/ipa_verify")
		if err := os.MkdirAll(filepath.Dir(verifier), 0o755); err != nil {
			return err
		}
		return os.WriteFile(verifier, []byte("verifier"), 0o755)
	}
	return nil
}

// environmentValue returns one exact Docker environment scalar.
func environmentValue(args []string, name string) string {
	prefix := name + "="
	for index := 0; index+1 < len(args); index++ {
		if args[index] == "--env" && strings.HasPrefix(args[index+1], prefix) {
			return strings.TrimPrefix(args[index+1], prefix)
		}
	}
	return ""
}

// digestBytes returns a lowercase SHA-256 digest for a test artefact.
func digestBytes(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

// makeCameraRepository creates a clean tracked support-input fixture.
func makeCameraRepository(t *testing.T) (string, []byte) {
	t.Helper()
	root := t.TempDir()
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	inputRoot := filepath.Join(root, "userspace/camera/libcamera")
	if err := os.MkdirAll(inputRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	tuning := []byte("version: 1\nalgorithms: []\n")
	files := map[string][]byte{
		"BASE.txt": []byte(testBase),
		"0001-libipa-add-imx681-simple-ipa-support.patch": []byte("diff --git a/a b/a\n"),
		"imx681.yaml": tuning,
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(inputRoot, name), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	commands := [][]string{
		{"git", "init", "-q", root},
		{"git", "-C", root, "config", "user.name", "Camera test"},
		{"git", "-C", root, "config", "user.email", "camera-test@example.invalid"},
		{"git", "-C", root, "add", "userspace/camera/libcamera"},
		{"git", "-C", root, "commit", "-q", "-m", "Add camera inputs"},
	}
	for _, command := range commands {
		if err := (platform.ExecRunner{}).Run(context.Background(), platform.Command{Name: command[0], Args: command[1:]}); err != nil {
			t.Fatal(err)
		}
	}
	return root, tuning
}

// newExecutableTestManager constructs a deterministic Linux ARM64 test manager.
func newExecutableTestManager(runner platform.Runner) *Manager {
	manager := New(runner)
	manager.hostOS = "linux"
	manager.hostArchitecture = "arm64"
	manager.now = func() time.Time { return time.Date(2026, 8, 30, 12, 34, 56, 0, time.UTC) }
	manager.token = func() (string, error) { return strings.Repeat("1", 24), nil }
	return manager
}

// TestPlanIsDeterministicAndTruthful verifies stable policy and host blocking.
func TestPlanIsDeterministicAndTruthful(t *testing.T) {
	root, tuning := makeCameraRepository(t)
	runner := &fakeCameraRunner{tuning: tuning}
	manager := New(runner)
	request := Request{RepositoryRoot: root, DryRun: true, NoPull: true}
	first, err := manager.Plan(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := manager.Plan(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("plans differ:\n%+v\n%+v", first, second)
	}
	if first.ContainerImage != ContainerImage || first.RecipeSHA256 != recipeSHA256() || first.PublicationPattern == "" {
		t.Fatalf("incomplete plan: %+v", first)
	}
	if manager.hostOS != "linux" || manager.hostArchitecture != "arm64" {
		if first.Executable || first.ExecutionBlocker == "" {
			t.Fatalf("non-native dry-run was not truthful: %+v", first)
		}
	}
	dryReceipt, err := manager.Run(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if dryReceipt.Published || dryReceipt.AuthoritySHA256 != "" {
		t.Fatalf("dry-run published an authority: %+v", dryReceipt)
	}
}

// TestFakeRunnerEndToEndBuild verifies the closed native publication contract.
func TestFakeRunnerEndToEndBuild(t *testing.T) {
	root, tuning := makeCameraRepository(t)
	runner := &fakeCameraRunner{tuning: tuning}
	manager := newExecutableTestManager(runner)
	receipt, err := manager.Run(context.Background(), Request{RepositoryRoot: root, Jobs: 4, MinimumFreeGiB: 1, NoPull: true})
	if err != nil {
		t.Fatal(err)
	}
	if !receipt.Published || receipt.Bundle == nil || len(receipt.Bundle.Artifacts) != 7 || len(receipt.Bundle.ChangesEntries) != 7 {
		t.Fatalf("incomplete build receipt: %+v", receipt)
	}
	authority, err := os.ReadFile(filepath.Join(receipt.OutputDirectory, ReceiptName))
	if err != nil {
		t.Fatal(err)
	}
	if receipt.AuthoritySHA256 != digestBytes(authority) || !baseHashExpression.MatchString(receipt.AuthoritySHA256) {
		t.Fatalf("build authority digest = %q", receipt.AuthoritySHA256)
	}
	if bytes.Contains(authority, []byte("authority_sha256")) {
		t.Fatal("build authority contains a self-digest")
	}
	entries, err := os.ReadDir(receipt.OutputDirectory)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 8 {
		t.Fatalf("published entries = %d, want 8", len(entries))
	}
	validated, err := ValidateBundle(context.Background(), runner, ValidationRequest{RepositoryRoot: root, Directory: receipt.OutputDirectory})
	if err != nil {
		t.Fatal(err)
	}
	if validated.PackageVersion != receipt.Bundle.PackageVersion || !validated.Verification.SameBuildIPAVerified {
		t.Fatalf("validated bundle = %+v", validated)
	}
	for _, command := range runner.commands {
		if command.Name == "bash" || command.Name == "sh" {
			t.Fatalf("host shell invocation escaped compiled policy: %+v", command)
		}
	}
}

// TestBuildRejectsPublishedAuthorityReplacement verifies the returned digest
// always describes private pre-publication bytes rather than a raced final file.
func TestBuildRejectsPublishedAuthorityReplacement(t *testing.T) {
	root, tuning := makeCameraRepository(t)
	runner := &fakeCameraRunner{tuning: tuning}
	manager := newExecutableTestManager(runner)
	manager.beforeAuthorityCheck = func(directory string) error {
		return os.WriteFile(filepath.Join(directory, ReceiptName), []byte("{}\n"), 0o644)
	}
	receipt, err := manager.Run(context.Background(), Request{RepositoryRoot: root, MinimumFreeGiB: 1})
	if err == nil || !strings.Contains(err.Error(), "differs from its private pre-publication bytes") {
		t.Fatalf("raced build authority error = %v", err)
	}
	if receipt.Published || receipt.AuthoritySHA256 != "" {
		t.Fatalf("raced build authority was endorsed: %+v", receipt)
	}
}

// TestValidateBundleStaticNeverExecutesPayload verifies the read-only proof and
// independently supplied authority digest on every supported host architecture.
func TestValidateBundleStaticNeverExecutesPayload(t *testing.T) {
	root, tuning := makeCameraRepository(t)
	runner := &fakeCameraRunner{tuning: tuning}
	receipt, err := newExecutableTestManager(runner).Run(context.Background(), Request{RepositoryRoot: root, MinimumFreeGiB: 1})
	if err != nil {
		t.Fatal(err)
	}
	runner.commands = nil
	validated, err := ValidateBundleStatic(context.Background(), runner, ValidationRequest{
		RepositoryRoot:          root,
		Directory:               receipt.OutputDirectory,
		ExpectedAuthoritySHA256: receipt.AuthoritySHA256,
	})
	if err != nil {
		t.Fatal(err)
	}
	if validated.PackageVersion != receipt.Bundle.PackageVersion {
		t.Fatalf("static bundle = %+v", validated)
	}
	for _, command := range runner.commands {
		if command.Name == "git" {
			continue
		}
		if command.Name != "dpkg-deb" || len(command.Args) == 0 || (command.Args[0] != "--field" && command.Args[0] != "--fsys-tarfile") {
			t.Fatalf("static validation executed an unsafe command: %+v", command)
		}
	}
}

// TestValidateBundleStaticRejectsAuthorityAndTuningMismatch verifies both
// independent hand-off authority and streamed package-data identity.
func TestValidateBundleStaticRejectsAuthorityAndTuningMismatch(t *testing.T) {
	root, tuning := makeCameraRepository(t)
	runner := &fakeCameraRunner{tuning: tuning}
	receipt, err := newExecutableTestManager(runner).Run(context.Background(), Request{RepositoryRoot: root, MinimumFreeGiB: 1})
	if err != nil {
		t.Fatal(err)
	}
	request := ValidationRequest{RepositoryRoot: root, Directory: receipt.OutputDirectory}
	if _, err := ValidateBundleStatic(context.Background(), runner, request); err == nil {
		t.Fatal("static validation accepted a missing independent authority digest")
	}
	request.ExpectedAuthoritySHA256 = strings.Repeat("0", 64)
	if _, err := ValidateBundleStatic(context.Background(), runner, request); err == nil {
		t.Fatal("static validation accepted a mismatched independent authority digest")
	}
	request.ExpectedAuthoritySHA256 = receipt.AuthoritySHA256
	runner.tuning = []byte("version: hostile\n")
	if _, err := ValidateBundleStatic(context.Background(), runner, request); err == nil || !strings.Contains(err.Error(), "tuning differs") {
		t.Fatalf("static tuning mismatch error = %v", err)
	}
	runner.tuning = tuning
	runner.packageFields = map[string]string{"Architecture": "amd64"}
	if _, err := ValidateBundleStatic(context.Background(), runner, request); err == nil || !strings.Contains(err.Error(), "Architecture") {
		t.Fatalf("static package-architecture error = %v", err)
	}
}

// TestStaticTuningTarRejectsAmbiguousMembers verifies no link or duplicate can
// stand in for the one bounded regular tuning authority.
func TestStaticTuningTarRejectsAmbiguousMembers(t *testing.T) {
	tuning := []byte("version: 1\nalgorithms: []\n")
	digest := digestBytes(tuning)
	if err := inspectTuningTar(bytes.NewReader(makeTuningTar(t, []tarTestEntry{{name: "./usr/share/libcamera/ipa/simple/imx681.yaml", data: tuning}})), digest); err != nil {
		t.Fatal(err)
	}
	for name, entries := range map[string][]tarTestEntry{
		"missing":   {{name: "./usr/share/libcamera/ipa/simple/other.yaml", data: tuning}},
		"duplicate": {{name: "usr/share/libcamera/ipa/simple/imx681.yaml", data: tuning}, {name: "./usr/share/libcamera/ipa/simple/imx681.yaml", data: tuning}},
		"link":      {{name: "usr/share/libcamera/ipa/simple/imx681.yaml", typeflag: tar.TypeSymlink}},
		"oversized": {{name: "usr/share/libcamera/ipa/simple/imx681.yaml", data: make([]byte, maximumTuningBytes+1)}},
	} {
		t.Run(name, func(t *testing.T) {
			if err := inspectTuningTar(bytes.NewReader(makeTuningTar(t, entries)), digest); err == nil {
				t.Fatal("ambiguous tuning archive passed")
			}
		})
	}
}

// tarTestEntry describes one package-payload member for static validation tests.
type tarTestEntry struct {
	name     string
	data     []byte
	typeflag byte
}

// makeTuningTar returns one complete in-memory package filesystem tar stream.
func makeTuningTar(t *testing.T, entries []tarTestEntry) []byte {
	t.Helper()
	var output bytes.Buffer
	archive := tar.NewWriter(&output)
	for _, entry := range entries {
		typeflag := entry.typeflag
		if typeflag == 0 {
			typeflag = tar.TypeReg
		}
		header := &tar.Header{Name: entry.name, Mode: 0o644, Typeflag: typeflag}
		if typeflag == tar.TypeReg || typeflag == tar.TypeRegA {
			header.Size = int64(len(entry.data))
		}
		if err := archive.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if len(entry.data) != 0 {
			if _, err := archive.Write(entry.data); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

// TestBuildRejectsMutationLinksAndCollisions verifies hostile output boundaries.
func TestBuildRejectsMutationLinksAndCollisions(t *testing.T) {
	root, tuning := makeCameraRepository(t)
	runner := &fakeCameraRunner{tuning: tuning}
	manager := newExecutableTestManager(runner)
	receipt, err := manager.Run(context.Background(), Request{RepositoryRoot: root, MinimumFreeGiB: 1})
	if err != nil {
		t.Fatal(err)
	}
	packagePath := filepath.Join(receipt.OutputDirectory, receipt.Bundle.Artifacts[0].Name)
	if err := os.WriteFile(packagePath, []byte("stale mixed package"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateBundle(context.Background(), runner, ValidationRequest{RepositoryRoot: root, Directory: receipt.OutputDirectory}); err == nil {
		t.Fatal("mutated package passed validation")
	}
	if err := os.Remove(packagePath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(ReceiptName, packagePath); err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateBundle(context.Background(), runner, ValidationRequest{RepositoryRoot: root, Directory: receipt.OutputDirectory}); err == nil {
		t.Fatal("symbolic-link package passed validation")
	}
	collision := filepath.Join(root, DefaultOutputDirectory, "build.20260830123456."+strings.Repeat("1", 24))
	if err := os.MkdirAll(collision, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Run(context.Background(), Request{RepositoryRoot: root, MinimumFreeGiB: 1}); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("collision error = %v", err)
	}
}

// TestCancellationRemovesContainerAndWithholdsPublication verifies recovery.
func TestCancellationRemovesContainerAndWithholdsPublication(t *testing.T) {
	root, tuning := makeCameraRepository(t)
	runner := &fakeCameraRunner{tuning: tuning, cancelRun: true}
	manager := newExecutableTestManager(runner)
	receipt, err := manager.Run(context.Background(), Request{RepositoryRoot: root, MinimumFreeGiB: 1})
	if err == nil || !receipt.Interrupted || receipt.Cleanup == nil || receipt.Published {
		t.Fatalf("cancellation receipt = %+v, error = %v", receipt, err)
	}
	if len(receipt.Cleanup.Args) < 3 || receipt.Cleanup.Args[0] != "rm" || receipt.Cleanup.Args[1] != "--force" {
		t.Fatalf("cleanup command = %+v", receipt.Cleanup)
	}
}

// TestBASEParserRejectsHostileAndAmbiguousText verifies the strict authority.
func TestBASEParserRejectsHostileAndAmbiguousText(t *testing.T) {
	cases := map[string]string{
		"duplicate": testBase + "Validation date: 2026-08-29\n",
		"reordered": strings.Replace(testBase, "Upstream project: https://git.libcamera.org/libcamera/libcamera.git\nUpstream tag: v0.7.0", "Upstream tag: v0.7.0\nUpstream project: https://git.libcamera.org/libcamera/libcamera.git", 1),
		"bidi":      strings.Replace(testBase, "v0.7.0", "v0.7.0\u202e", 1),
		"bad hash":  strings.Replace(testBase, strings.Repeat("0", 0)+"27a10011", "XYZ10011", 1),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseBase([]byte(data)); err == nil {
				t.Fatal("hostile BASE.txt passed")
			}
		})
	}
}

// TestDebianChangesRejectsDuplicateHostileAndHiddenEntries protects accounting.
func TestDebianChangesRejectsDuplicateHostileAndHiddenEntries(t *testing.T) {
	digest := strings.Repeat("a", 64)
	prefix := "Source: libcamera\nVersion: fixture\nArchitecture: arm64\nChecksums-Sha256:\n"
	for name, data := range map[string]string{
		"duplicate": prefix + " " + digest + " 1 one.deb\n " + digest + " 1 one.deb\n",
		"traversal": prefix + " " + digest + " 1 ../escape.deb\n",
		"bidi":      prefix + " " + digest + " 1 camera\u202e.deb\n",
		"hidden":    prefix + " " + digest + " 1 one.deb\n\n " + digest + " 1 two.deb\n",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseDebianRecord([]byte(data), true); err == nil {
				t.Fatal("hostile Debian changes record passed")
			}
		})
	}
}

// TestStructuredReceiptRejectsDuplicateAndUnknownMembers verifies strict JSON.
func TestStructuredReceiptRejectsDuplicateAndUnknownMembers(t *testing.T) {
	for name, data := range map[string]string{
		"duplicate": `{"schema_version":1,"schema_version":1}`,
		"unknown":   `{"unexpected":true}`,
		"trailing":  `{} {}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeBundleReceipt([]byte(data)); err == nil {
				t.Fatal("hostile structured receipt passed")
			}
		})
	}
}

// TestCompiledAllowListsReturnDefensiveCopies prevents caller policy mutation.
func TestCompiledAllowListsReturnDefensiveCopies(t *testing.T) {
	inputs := TrackedInputPaths()
	packages := RuntimePackageNames()
	inputs[0] = "hostile"
	packages[0] = "hostile"
	if TrackedInputPaths()[0] == "hostile" || RuntimePackageNames()[0] == "hostile" {
		t.Fatal("caller mutated compiled camera policy")
	}
}
