package build

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/kernel"
	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// testKernelABI is the coherent Surface ABI emitted by the fake container.
	testKernelABI = "7.2.0-jg-0sp11v19-qcom-x1e"
	// testKernelVersion is the Debian package version emitted by the fake container.
	testKernelVersion = "7.2.0-jg-0sp11v19"
)

// fakeBuildRunner emulates only the compiled Docker command forms.
type fakeBuildRunner struct {
	// commands records every host command in execution order.
	commands []Command
	// workspaceIdentity remembers the label supplied during volume creation.
	workspaceIdentity string
	// volumeMismatch makes inspection return an unrelated ownership identity.
	volumeMismatch bool
	// container optionally replaces successful fake container output.
	container func(context.Context, platform.Command, string) error
	// cleanupCalled records forced container removal.
	cleanupCalled bool
	// cleanupInheritedCancellation reports an invalid recovery context.
	cleanupInheritedCancellation bool
}

// Run records and emulates one Docker command without invoking a host shell.
func (runner *fakeBuildRunner) Run(ctx context.Context, command platform.Command) error {
	runner.commands = append(runner.commands, Command{Name: command.Name, Args: append([]string(nil), command.Args...)})
	if command.Name != dockerCommand || len(command.Args) == 0 {
		return errors.New("unexpected fake build command")
	}
	switch command.Args[0] {
	case "volume":
		if len(command.Args) > 1 && command.Args[1] == "create" {
			runner.workspaceIdentity = valueFollowing(command.Args, "--label", dockerWorkspaceLabel+"=")
			return writeRunnerOutput(command.Stdout, command.Args[len(command.Args)-1]+"\n")
		}
		if len(command.Args) > 1 && command.Args[1] == "inspect" {
			volume := command.Args[len(command.Args)-1]
			identity := runner.workspaceIdentity
			if runner.volumeMismatch {
				identity = strings.Repeat("0", 64)
			}
			return writeRunnerOutput(command.Stdout, volume+"|local|true|"+identity+"\n")
		}
	case "run":
		transaction, err := transactionFromDockerArgs(command.Args)
		if err != nil {
			return err
		}
		if runner.container != nil {
			return runner.container(ctx, command, transaction)
		}
		return writeFakeContainerOutput(command, transaction)
	case "rm":
		runner.cleanupCalled = true
		runner.cleanupInheritedCancellation = ctx.Err() != nil
		return nil
	}
	return errors.New("unsupported fake Docker command")
}

// Capture is unused because production volume output is explicitly bounded.
func (runner *fakeBuildRunner) Capture(context.Context, platform.Command) ([]byte, error) {
	return nil, errors.New("unexpected unbounded capture")
}

// TestDryRunPlanIsCompleteAndReadOnly verifies planning neither writes nor invokes Docker.
func TestDryRunPlanIsCompleteAndReadOnly(t *testing.T) {
	root := t.TempDir()
	runner := &fakeBuildRunner{}
	manager := newTestBuildManager(runner)
	request := Request{
		RepositoryRoot:  root,
		GitURL:          "https://example.invalid/owner/kernel;literal",
		GitBranch:       "sp11/test-v19",
		WorkDirectory:   "private/work",
		OutputDirectory: "packages/new-v19",
		Jobs:            12,
		ResetSource:     true,
		SkipClean:       true,
		DryRun:          true,
	}
	receipt, err := manager.Run(context.Background(), request)
	if err != nil {
		t.Fatalf("Run(dry-run) error = %v", err)
	}
	if len(runner.commands) != 0 || len(receipt.Executed) != 0 || receipt.Published {
		t.Fatalf("dry-run performed work: runner=%#v receipt=%#v", runner.commands, receipt)
	}
	if _, err := os.Lstat(filepath.Join(root, "private")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("dry-run created work state: %v", err)
	}
	if receipt.Plan.SchemaVersion != SchemaVersion || len(receipt.Plan.Commands) != 3 ||
		receipt.Plan.GitURL != request.GitURL || receipt.Plan.GitRef != request.GitBranch ||
		receipt.Plan.Jobs != request.Jobs || !receipt.Plan.ResetSource || !receipt.Plan.SkipClean ||
		receipt.Plan.BuildTarget != containerBuildTarget || receipt.Plan.MinimumFreeGiB != containerMinimumFreeGiB {
		t.Fatalf("dry-run plan = %#v", receipt.Plan)
	}
	if !strings.Contains(receipt.Plan.ContainerImage, "@sha256:") {
		t.Fatalf("dry-run image is not immutable: %q", receipt.Plan.ContainerImage)
	}
	joined := strings.Join(receipt.Plan.Commands[2].Args, "\n")
	if !strings.Contains(joined, "\n"+request.GitURL+"\n") || !strings.Contains(joined, "\n"+request.GitBranch+"\n") {
		t.Fatalf("source inputs are not distinct Docker arguments: %q", joined)
	}
	second, err := manager.Plan(context.Background(), request)
	if err != nil || !reflect.DeepEqual(receipt.Plan, second) {
		t.Fatalf("plan is not deterministic: error=%v\nfirst=%#v\nsecond=%#v", err, receipt.Plan, second)
	}
}

// TestNativeBuildPublishesVerifiedBundle verifies source provenance, command
// separation, exact package validation, and atomic new-directory publication.
func TestNativeBuildPublishesVerifiedBundle(t *testing.T) {
	root := t.TempDir()
	runner := &fakeBuildRunner{}
	manager := newTestBuildManager(runner)
	request := Request{
		RepositoryRoot:  root,
		GitURL:          "https://example.invalid/owner/kernel",
		GitBranch:       "sp11/integration-7.2.x",
		WorkDirectory:   "state/kernel",
		OutputDirectory: "output/v19",
		Jobs:            8,
	}
	receipt, err := manager.Run(context.Background(), request)
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	if !receipt.Published || !receipt.PublicationDurable || receipt.Provenance == nil ||
		receipt.Provenance.Revision != strings.Repeat("a", 40) || receipt.Provenance.ToolchainSHA256 != strings.Repeat("c", 64) || len(receipt.Artifacts) != 2 {
		t.Fatalf("build receipt = %#v", receipt)
	}
	if len(receipt.Executed) != 3 {
		t.Fatalf("executed commands = %d, want 3: %#v", len(receipt.Executed), receipt.Executed)
	}
	for _, command := range receipt.Executed {
		if command.Name != dockerCommand {
			t.Errorf("host executable = %q, want docker", command.Name)
		}
		joined := strings.Join(command.Args, " ")
		if strings.Contains(joined, "scripts/") || strings.Contains(joined, "build-sp11-qcom-x1e-kernel") {
			t.Errorf("repository helper leaked into native command: %s", joined)
		}
	}
	bundle, err := kernel.DiscoverLocalBundle(filepath.Join(root, "output", "v19"))
	if err != nil {
		t.Fatalf("published bundle cannot be rediscovered: %v", err)
	}
	if bundle.ABI != testKernelABI || len(bundle.Packages) != 2 || !bundle.Packages[0].Verified || !bundle.Packages[1].Verified {
		t.Fatalf("published bundle = %#v", bundle)
	}
	for _, name := range []string{checksumManifestName, provenanceManifestName, bundleManifestName} {
		info, err := os.Lstat(filepath.Join(root, "output", "v19", name))
		if err != nil || !info.Mode().IsRegular() {
			t.Errorf("published manifest %s is unavailable: %v", name, err)
		}
	}
	if _, err := os.Lstat(filepath.Join(root, "state", "kernel", buildLockDirectoryName)); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("successful build retained its process lock: %v", err)
	}
}

// TestExistingBuildLockPreventsDocker verifies concurrent processes cannot
// share and mutate one persistent source volume.
func TestExistingBuildLockPreventsDocker(t *testing.T) {
	root := t.TempDir()
	work := filepath.Join(root, "work")
	if err := os.MkdirAll(filepath.Join(work, buildLockDirectoryName), 0o700); err != nil {
		t.Fatal(err)
	}
	runner := &fakeBuildRunner{}
	receipt, err := newTestBuildManager(runner).Run(context.Background(), Request{
		RepositoryRoot: root, WorkDirectory: "work", OutputDirectory: "output",
	})
	if err == nil || !strings.Contains(err.Error(), "another kernel build") {
		t.Fatalf("concurrent build error = %v", err)
	}
	if len(runner.commands) != 0 || len(receipt.Executed) != 0 {
		t.Fatalf("concurrent build reached Docker: %#v", receipt.Executed)
	}
}

// TestChangedBuildLockIsNotRemoved verifies cleanup cannot delete another
// process's replacement at the deterministic lock path.
func TestChangedBuildLockIsNotRemoved(t *testing.T) {
	work, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	release, err := acquireBuildLock(work)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(work, buildLockDirectoryName)
	if err := os.RemoveAll(path); err != nil {
		t.Fatal(err)
	}
	releaseReplacement, err := acquireBuildLock(work)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = releaseReplacement() })
	if err := release(); err == nil || !strings.Contains(err.Error(), "changed kernel build lock") {
		t.Fatalf("changed build lock release error = %v", err)
	}
	if info, err := os.Lstat(path); err != nil || !info.IsDir() {
		t.Fatalf("replacement build lock was removed: %v", err)
	}
	if err := releaseReplacement(); err != nil {
		t.Fatalf("replacement build lock release error = %v", err)
	}
}

// TestChangedBuildLockOwnerIsNotRemoved verifies cleanup retains a lock whose
// ownership proof changed without changing its directory identity.
func TestChangedBuildLockOwnerIsNotRemoved(t *testing.T) {
	work, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	release, err := acquireBuildLock(work)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(work, buildLockDirectoryName)
	entries, err := os.ReadDir(path)
	if err != nil || len(entries) != 1 {
		t.Fatalf("build lock owner entries = %d, error = %v", len(entries), err)
	}
	ownerPath := filepath.Join(path, entries[0].Name())
	owner, err := os.ReadFile(ownerPath)
	if err != nil || len(owner) != buildLockOwnerBytes {
		t.Fatalf("read build lock owner length = %d, error = %v", len(owner), err)
	}
	owner[0] ^= 0xff
	if err := os.WriteFile(ownerPath, owner, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := release(); err == nil || !strings.Contains(err.Error(), "changed kernel build lock") {
		t.Fatalf("changed build lock owner release error = %v", err)
	}
	if info, err := os.Lstat(path); err != nil || !info.IsDir() {
		t.Fatalf("changed-owner build lock was removed: %v", err)
	}
}

// TestMismatchedVolumeOwnershipFailsBeforeContainer verifies reset permission
// never reaches an unlabelled or differently bound persistent volume.
func TestMismatchedVolumeOwnershipFailsBeforeContainer(t *testing.T) {
	root := t.TempDir()
	runner := &fakeBuildRunner{volumeMismatch: true}
	manager := newTestBuildManager(runner)
	request := Request{RepositoryRoot: root, WorkDirectory: "work", OutputDirectory: "output", ResetSource: true}
	receipt, err := manager.Run(context.Background(), request)
	if err == nil || !strings.Contains(err.Error(), "mismatched ownership") {
		t.Fatalf("volume ownership error = %v", err)
	}
	if len(receipt.Executed) != 2 {
		t.Fatalf("commands reached unsafe container boundary: %#v", receipt.Executed)
	}
	if _, statErr := os.Lstat(filepath.Join(root, "output")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("output appeared after volume refusal: %v", statErr)
	}
}

// TestCancellationForcesContainerRemovalWithIndependentContext verifies an
// interrupted build cannot leave its named container running unnoticed.
func TestCancellationForcesContainerRemovalWithIndependentContext(t *testing.T) {
	root := t.TempDir()
	runner := &fakeBuildRunner{}
	runner.container = func(ctx context.Context, _ platform.Command, _ string) error {
		<-ctx.Done()
		return ctx.Err()
	}
	manager := newTestBuildManager(runner)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	// Planning observes cancellation before Docker, so use a runner-triggered
	// cancellation to exercise the post-start recovery boundary.
	ctx, cancel = context.WithCancel(context.Background())
	runner.container = func(_ context.Context, _ platform.Command, _ string) error {
		cancel()
		return context.Canceled
	}
	receipt, err := manager.Run(ctx, Request{
		RepositoryRoot: root, WorkDirectory: "work", OutputDirectory: "output",
	})
	if err == nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled build error = %v", err)
	}
	if !receipt.Interrupted || receipt.Cleanup == nil || !receipt.Cleanup.Attempted || !runner.cleanupCalled {
		t.Fatalf("cancelled build receipt = %#v", receipt)
	}
	if runner.cleanupInheritedCancellation {
		t.Fatal("container cleanup inherited the cancelled caller context")
	}
	if _, statErr := os.Lstat(filepath.Join(root, "output")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("cancelled build published output: %v", statErr)
	}
}

// TestHostileInputsFailBeforeMutation exercises containment, symbolic-link,
// Git argument, output freshness, job-bound, and cancellation guards.
func TestHostileInputsFailBeforeMutation(t *testing.T) {
	baseRoot := t.TempDir()
	outside := t.TempDir()
	symlinkRoot := filepath.Join(baseRoot, "symlink-root")
	if err := os.Mkdir(symlinkRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(symlinkRoot, "linked")); err != nil {
		t.Fatal(err)
	}
	existingRoot := filepath.Join(baseRoot, "existing-root")
	if err := os.Mkdir(existingRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(existingRoot, "output"), 0o700); err != nil {
		t.Fatal(err)
	}

	tests := map[string]Request{
		"absolute work":      {RepositoryRoot: baseRoot, WorkDirectory: outside, OutputDirectory: "out-a"},
		"escaping work":      {RepositoryRoot: baseRoot, WorkDirectory: "../escape", OutputDirectory: "out-b"},
		"overlapping paths":  {RepositoryRoot: baseRoot, WorkDirectory: "state", OutputDirectory: "state/output"},
		"mount comma":        {RepositoryRoot: baseRoot, WorkDirectory: "bad,work", OutputDirectory: "out-c"},
		"symbolic route":     {RepositoryRoot: symlinkRoot, WorkDirectory: "linked/work", OutputDirectory: "out-d"},
		"existing output":    {RepositoryRoot: existingRoot, WorkDirectory: "work", OutputDirectory: "output"},
		"filesystem root":    {RepositoryRoot: string(filepath.Separator), WorkDirectory: "work", OutputDirectory: "output"},
		"local Git URL":      {RepositoryRoot: baseRoot, GitURL: "file:///tmp/kernel", WorkDirectory: "work-e", OutputDirectory: "out-e"},
		"credential Git URL": {RepositoryRoot: baseRoot, GitURL: "https://user@example.invalid/kernel", WorkDirectory: "work-f", OutputDirectory: "out-f"},
		"query Git URL":      {RepositoryRoot: baseRoot, GitURL: "https://example.invalid/kernel?ref=x", WorkDirectory: "work-g", OutputDirectory: "out-g"},
		"control Git URL":    {RepositoryRoot: baseRoot, GitURL: "https://example.invalid/kernel\nnext", WorkDirectory: "work-h", OutputDirectory: "out-h"},
		"option Git ref":     {RepositoryRoot: baseRoot, GitBranch: "-malicious", WorkDirectory: "work-i", OutputDirectory: "out-i"},
		"ambiguous Git ref":  {RepositoryRoot: baseRoot, GitBranch: "sp11/../main", WorkDirectory: "work-j", OutputDirectory: "out-j"},
		"control Git ref":    {RepositoryRoot: baseRoot, GitBranch: "sp11/main\nnext", WorkDirectory: "work-k", OutputDirectory: "out-k"},
		"negative jobs":      {RepositoryRoot: baseRoot, Jobs: -1, WorkDirectory: "work-l", OutputDirectory: "out-l"},
		"excessive jobs":     {RepositoryRoot: baseRoot, Jobs: maximumBuildJobs + 1, WorkDirectory: "work-m", OutputDirectory: "out-m"},
	}
	for name, request := range tests {
		t.Run(name, func(t *testing.T) {
			runner := &fakeBuildRunner{}
			manager := newTestBuildManager(runner)
			if _, err := manager.Run(context.Background(), request); err == nil {
				t.Fatal("hostile request unexpectedly succeeded")
			}
			if len(runner.commands) != 0 {
				t.Fatalf("hostile request reached Docker: %#v", runner.commands)
			}
		})
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	runner := &fakeBuildRunner{}
	if _, err := newTestBuildManager(runner).Run(cancelled, Request{RepositoryRoot: baseRoot, WorkDirectory: "work-n", OutputDirectory: "out-n"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("pre-cancelled request error = %v", err)
	}
	if len(runner.commands) != 0 {
		t.Fatalf("pre-cancelled request reached Docker: %#v", runner.commands)
	}
}

// TestOutputMutationDuringBuildIsPreservedAndRefused verifies an external file
// cannot be overwritten when the reviewed output path changes before publication.
func TestOutputMutationDuringBuildIsPreservedAndRefused(t *testing.T) {
	root := t.TempDir()
	output := filepath.Join(root, "output")
	runner := &fakeBuildRunner{}
	runner.container = func(_ context.Context, command platform.Command, transaction string) error {
		if err := writeFakeContainerOutput(command, transaction); err != nil {
			return err
		}
		if err := os.Mkdir(output, 0o700); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(output, "user-file"), []byte("preserve"), 0o600)
	}
	receipt, err := newTestBuildManager(runner).Run(context.Background(), Request{
		RepositoryRoot: root, WorkDirectory: "work", OutputDirectory: "output",
	})
	if err == nil || !strings.Contains(err.Error(), "output changed") {
		t.Fatalf("output mutation error = %v", err)
	}
	if receipt.Published {
		t.Fatalf("mutated output was reported published: %#v", receipt)
	}
	content, readErr := os.ReadFile(filepath.Join(output, "user-file"))
	if readErr != nil || string(content) != "preserve" {
		t.Fatalf("external output content changed: %q, %v", content, readErr)
	}
}

// TestMalformedContainerProvenancePreventsPublication verifies untrusted
// container identity fields cannot become a successful receipt.
func TestMalformedContainerProvenancePreventsPublication(t *testing.T) {
	root := t.TempDir()
	runner := &fakeBuildRunner{}
	runner.container = func(_ context.Context, command platform.Command, transaction string) error {
		if err := writeFakeContainerOutput(command, transaction); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(transaction, "provenance", "revision"), []byte("not-a-revision"), 0o644)
	}
	receipt, err := newTestBuildManager(runner).Run(context.Background(), Request{
		RepositoryRoot: root, WorkDirectory: "work", OutputDirectory: "output",
	})
	if err == nil || !strings.Contains(err.Error(), "malformed Git revision") {
		t.Fatalf("malformed provenance error = %v", err)
	}
	if receipt.Published {
		t.Fatalf("malformed provenance was published: %#v", receipt)
	}
}

// TestHostilePackageNamePreventsPublication verifies a container cannot forge
// checksum-manifest records with filename control characters.
func TestHostilePackageNamePreventsPublication(t *testing.T) {
	root := t.TempDir()
	runner := &fakeBuildRunner{}
	runner.container = func(_ context.Context, command platform.Command, transaction string) error {
		if err := writeFakeContainerOutput(command, transaction); err != nil {
			return err
		}
		name := "linux-image-" + testKernelABI + "_" + testKernelVersion + "_arm64.deb\n" + strings.Repeat("0", 64) + "  forged.deb"
		return os.WriteFile(filepath.Join(transaction, "artifacts", name), []byte("hostile"), 0o644)
	}
	receipt, err := newTestBuildManager(runner).Run(context.Background(), Request{
		RepositoryRoot: root, WorkDirectory: "work", OutputDirectory: "output",
	})
	if err == nil || !strings.Contains(err.Error(), "unsupported bytes") {
		t.Fatalf("hostile package name error = %v", err)
	}
	if receipt.Published {
		t.Fatalf("hostile package name was published: %#v", receipt)
	}
}

// TestCompiledRecipeContainsOnlyNativeBuildPolicy verifies the released CLI no
// longer calls repository helpers or carries retired install workarounds.
func TestCompiledRecipeContainsOnlyNativeBuildPolicy(t *testing.T) {
	for _, forbidden := range []string{
		"/repo/", "scripts/", "build-sp11-qcom-x1e-kernel", "install-sp11", "touchscreen", "sudo", "reboot", "chmod -R a+rwX /exchange",
	} {
		if strings.Contains(containerRecipe, forbidden) {
			t.Errorf("compiled recipe contains forbidden helper or host action %q", forbidden)
		}
	}
	for _, required := range []string{
		containerBuildTarget, "apt-get install -y --no-install-recommends", "mk-build-deps", "git ls-remote", "40 GiB",
		`chmod -R a+rwX "$artifact_dir" "$provenance_dir"`,
	} {
		if !strings.Contains(containerRecipe, required) {
			t.Errorf("compiled recipe is missing retained policy %q", required)
		}
	}
	if strings.Count(containerRecipe, "rm -rf") != 1 || !strings.Contains(containerRecipe, `rm -rf -- "$source_dir"`) {
		t.Errorf("compiled recipe has an unexpected reset boundary")
	}
	if !strings.Contains(containerRecipe, `find "$source_parent" -mindepth 1 -maxdepth 1`) || strings.Contains(containerRecipe, `find "$work_root"`) {
		t.Errorf("compiled recipe does not isolate freshly generated packages")
	}
}

// TestCompiledRecipeParsesWithBash verifies the embedded policy remains a
// syntactically valid Bash program when Bash is available to the test host.
func TestCompiledRecipeParsesWithBash(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("Bash is not available on this test host")
	}
	path := filepath.Join(t.TempDir(), "build-policy.sh")
	if err := os.WriteFile(path, []byte(containerRecipe), 0o600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command(bash, "-n", path).CombinedOutput(); err != nil {
		t.Fatalf("embedded recipe has invalid Bash syntax: %v\n%s", err, output)
	}
}

// newTestBuildManager constructs a deterministic manager around a fake runner.
func newTestBuildManager(runner platform.Runner) *Manager {
	manager := New(runner)
	manager.token = func() (string, error) { return strings.Repeat("a", 24), nil }
	return manager
}

// writeRunnerOutput writes fake Docker standard output when a capture is configured.
func writeRunnerOutput(writer io.Writer, value string) error {
	if writer == nil {
		return errors.New("fake Docker capture has no output writer")
	}
	_, err := io.WriteString(writer, value)
	return err
}

// valueFollowing returns a label suffix from a repeated flag sequence.
func valueFollowing(arguments []string, flag, prefix string) string {
	for index := 0; index+1 < len(arguments); index++ {
		if arguments[index] == flag && strings.HasPrefix(arguments[index+1], prefix) {
			return strings.TrimPrefix(arguments[index+1], prefix)
		}
	}
	return ""
}

// transactionFromDockerArgs extracts the already validated bind-mount source.
func transactionFromDockerArgs(arguments []string) (string, error) {
	const prefix = "type=bind,src="
	const suffix = ",dst=/exchange"
	for _, argument := range arguments {
		if strings.HasPrefix(argument, prefix) && strings.HasSuffix(argument, suffix) {
			return strings.TrimSuffix(strings.TrimPrefix(argument, prefix), suffix), nil
		}
	}
	return "", errors.New("fake Docker command has no exchange mount")
}

// writeFakeContainerOutput emits bounded provenance and a coherent runtime pair.
func writeFakeContainerOutput(command platform.Command, transaction string) error {
	arguments := command.Args
	scriptIndex := -1
	for index, argument := range arguments {
		if argument == "/exchange/build-policy.sh" {
			scriptIndex = index
			break
		}
	}
	if scriptIndex < 0 || scriptIndex+5 >= len(arguments) {
		return errors.New("fake Docker command has incomplete recipe arguments")
	}
	gitURL := arguments[scriptIndex+1]
	gitRef := arguments[scriptIndex+2]
	recipe := valueFollowing(arguments, "--env", "LINUX_ARMER_RECIPE_SHA256=")
	provenance := filepath.Join(transaction, "provenance")
	artifacts := filepath.Join(transaction, "artifacts")
	if err := os.MkdirAll(provenance, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(artifacts, 0o755); err != nil {
		return err
	}
	fields := map[string]string{
		"git-url":          gitURL,
		"git-ref":          gitRef,
		"ref-kind":         "branch",
		"revision":         strings.Repeat("a", 40),
		"tree":             strings.Repeat("b", 40),
		"commit-time":      "2026-08-30T10:00:00+00:00",
		"recipe-sha256":    recipe,
		"toolchain-sha256": strings.Repeat("c", 64),
	}
	for name, value := range fields {
		if err := os.WriteFile(filepath.Join(provenance, name), []byte(value), 0o644); err != nil {
			return err
		}
	}
	packages := map[string][]byte{
		"linux-image-" + testKernelABI + "_" + testKernelVersion + "_arm64.deb":   bytes.Repeat([]byte("image"), 128),
		"linux-modules-" + testKernelABI + "_" + testKernelVersion + "_arm64.deb": bytes.Repeat([]byte("modules"), 128),
	}
	for name, content := range packages {
		if err := os.WriteFile(filepath.Join(artifacts, name), content, 0o644); err != nil {
			return err
		}
	}
	return nil
}
