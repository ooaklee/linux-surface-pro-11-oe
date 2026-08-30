package build

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// maximumPatchBytes bounds the downstream patch staged into Docker.
	maximumPatchBytes = int64(4 << 20)
	// maximumTuningBytes bounds the reviewed IMX681 tuning data.
	maximumTuningBytes = int64(2 << 20)
	// privateTransactionPrefix identifies disposable camera exchanges.
	privateTransactionPrefix = ".linux-armer-camera-build-"
	// publicationPrefix identifies fresh, immutable package-set directories.
	publicationPrefix = "build."
	// containerPrefix identifies containers eligible for bounded cleanup.
	containerPrefix = "linux-armer-camera-build-"
)

// imageIdentityExpression accepts an immutable Docker image object.
var imageIdentityExpression = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// gitCommitExpression accepts the full support commit identity.
var gitCommitExpression = regexp.MustCompile(`^[0-9a-f]{40}$`)

// preparedInputs contains HEAD-authenticated bytes and source authority.
type preparedInputs struct {
	commit     string
	commitTime time.Time
	base       Base
	inputs     []InputProvenance
}

// dockerIdentity contains independently observed native engine and image data.
type dockerIdentity struct {
	serverOS      string
	serverArch    string
	serverVersion string
	imageID       string
}

// prepare validates request, paths, source authority, and deterministic policy.
func (manager *Manager) prepare(ctx context.Context, request Request) (Plan, error) {
	if manager == nil || manager.Runner == nil {
		return Plan{}, errors.New("camera build runner is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return Plan{}, err
	}
	root, err := resolveRoot(request.RepositoryRoot)
	if err != nil {
		return Plan{}, err
	}
	work, err := resolveContainedPath(root, request.WorkDirectory, DefaultWorkDirectory)
	if err != nil {
		return Plan{}, fmt.Errorf("resolve camera work directory: %w", err)
	}
	output, err := resolveContainedPath(root, request.OutputDirectory, DefaultOutputDirectory)
	if err != nil {
		return Plan{}, fmt.Errorf("resolve camera output directory: %w", err)
	}
	if pathsOverlap(work, output) {
		return Plan{}, errors.New("camera work and output directories must not overlap")
	}
	jobs := request.Jobs
	if jobs == 0 {
		jobs = DefaultJobs
	}
	if jobs < 1 || jobs > 64 {
		return Plan{}, errors.New("camera build jobs must be between 1 and 64")
	}
	minimumFree := request.MinimumFreeGiB
	if minimumFree == 0 {
		minimumFree = DefaultMinimumFreeGiB
	}
	if minimumFree < 1 || minimumFree > 1024 {
		return Plan{}, errors.New("camera minimum free space must be between 1 and 1024 GiB")
	}
	if _, err := authenticateInputs(ctx, manager.Runner, root); err != nil {
		return Plan{}, err
	}
	executable := manager.hostOS == "linux" && manager.hostArchitecture == "arm64"
	blocker := ""
	if !executable {
		blocker = fmt.Sprintf("native execution requires Linux arm64; this binary reports %s/%s", manager.hostOS, manager.hostArchitecture)
	}
	plan := Plan{
		RepositoryRoot:     root,
		WorkDirectory:      work,
		OutputDirectory:    output,
		Jobs:               jobs,
		MinimumFreeGiB:     minimumFree,
		NoPull:             request.NoPull,
		DryRun:             request.DryRun,
		Executable:         executable,
		ExecutionBlocker:   blocker,
		ContainerImage:     ContainerImage,
		RecipeSHA256:       recipeSHA256(),
		PublicationPattern: publicationPrefix + "<UTC-build-id>",
	}
	if request.NoPull {
		plan.Commands = append(plan.Commands, Command{Name: "docker", Args: []string{"image", "inspect", ContainerImage}})
	} else {
		plan.Commands = append(plan.Commands, Command{Name: "docker", Args: []string{"pull", "--platform", "linux/arm64", ContainerImage}})
	}
	plan.Commands = append(plan.Commands,
		Command{Name: "docker", Args: []string{"version", "--format", "<compiled-format>"}},
		Command{Name: "docker", Args: []string{"run", "--rm", "--name", "<private-container-id>", "--platform", "linux/arm64", ContainerImage, "/policy/build.sh"}},
	)
	return plan, nil
}

// Run executes a native build or returns its truthful, non-mutating dry-run.
func (manager *Manager) Run(ctx context.Context, request Request) (receipt ExecutionReceipt, resultErr error) {
	receipt.StartedAt = managerTime(manager)
	defer func() {
		receipt.CompletedAt = managerTime(manager)
	}()
	plan, err := manager.prepare(ctx, request)
	if err != nil {
		return receipt, err
	}
	receipt.Plan = plan
	if plan.DryRun {
		return receipt, nil
	}
	if !plan.Executable {
		return receipt, errors.New(plan.ExecutionBlocker)
	}
	inputs, err := authenticateInputs(ctx, manager.Runner, plan.RepositoryRoot)
	if err != nil {
		return receipt, err
	}
	if manager.token == nil {
		return receipt, errors.New("camera build identifier source is unavailable")
	}
	token, err := manager.token()
	if err != nil {
		return receipt, err
	}
	buildID, err := makeBuildID(receipt.StartedAt, token)
	if err != nil {
		return receipt, err
	}
	publication := filepath.Join(plan.OutputDirectory, publicationPrefix+buildID)
	if err := prepareRoots(plan, publication); err != nil {
		return receipt, err
	}
	if err := checkFreeSpace(ctx, manager.Runner, plan.WorkDirectory, plan.MinimumFreeGiB); err != nil {
		return receipt, err
	}
	transaction, cleanup, err := makeTransaction(plan.WorkDirectory, buildID)
	if err != nil {
		return receipt, err
	}
	defer func() {
		resultErr = errors.Join(resultErr, cleanup())
	}()
	if err := stagePolicyAndInputs(plan, transaction, inputs); err != nil {
		return receipt, err
	}
	identity, err := manager.prepareDocker(ctx, &receipt, plan)
	if err != nil {
		return receipt, err
	}
	uid, err := manager.capture(ctx, &receipt, Command{Name: "id", Args: []string{"-u"}})
	if err != nil {
		return receipt, fmt.Errorf("resolve invoking numeric user identity: %w", err)
	}
	if !decimalIdentity(uid) {
		return receipt, errors.New("invoking numeric user identity is malformed")
	}
	gid, err := manager.capture(ctx, &receipt, Command{Name: "id", Args: []string{"-g"}})
	if err != nil {
		return receipt, fmt.Errorf("resolve invoking numeric group identity: %w", err)
	}
	if !decimalIdentity(gid) {
		return receipt, errors.New("invoking numeric group identity is malformed")
	}
	containerName := containerPrefix + token
	command := containerCommand(plan, inputs, transaction, buildID, containerName, uid, gid)
	if err := manager.run(ctx, &receipt, command); err != nil {
		receipt.Interrupted = ctx.Err() != nil || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
		cleanupCommand := Command{Name: "docker", Args: []string{"rm", "--force", containerName}}
		receipt.Cleanup = &cleanupCommand
		cleanupContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		cleanupErr := manager.Runner.Run(cleanupContext, platformCommand(cleanupCommand))
		return receipt, errors.Join(fmt.Errorf("Docker camera build failed: %w", err), cleanupErr)
	}
	bundle, err := validateExchange(ctx, manager.Runner, plan, transaction, buildID, inputs, identity)
	if err != nil {
		return receipt, err
	}
	published, authoritySHA256, err := publishBundle(plan, transaction, publication, bundle, manager.beforeAuthorityCheck)
	if err != nil {
		return receipt, err
	}
	receipt.Bundle = &bundle
	receipt.OutputDirectory = published
	receipt.AuthoritySHA256 = authoritySHA256
	receipt.Published = true
	return receipt, nil
}

// authenticateInputs proves fixed work-tree inputs are byte-identical to HEAD.
func authenticateInputs(ctx context.Context, runner platform.Runner, root string) (preparedInputs, error) {
	top, err := captureDirect(ctx, runner, Command{Name: "git", Args: []string{"-C", root, "rev-parse", "--show-toplevel"}})
	if err != nil || filepath.Clean(top) != root {
		return preparedInputs{}, errors.New("repository root does not match Git's top level")
	}
	commit, err := captureDirect(ctx, runner, Command{Name: "git", Args: []string{"-C", root, "rev-parse", "--verify", "HEAD^{commit}"}})
	if err != nil || !gitCommitExpression.MatchString(commit) {
		return preparedInputs{}, errors.New("could not resolve a complete support HEAD commit")
	}
	commitTimeText, err := captureDirect(ctx, runner, Command{Name: "git", Args: []string{"-C", root, "show", "-s", "--format=%cI", commit}})
	if err != nil {
		return preparedInputs{}, fmt.Errorf("read support HEAD time: %w", err)
	}
	commitTime, err := time.Parse(time.RFC3339, commitTimeText)
	if err != nil {
		return preparedInputs{}, fmt.Errorf("parse support HEAD time: %w", err)
	}
	inputs := make([]InputProvenance, 0, len(inputPaths))
	var base Base
	for index, relative := range inputPaths {
		path := filepath.Join(root, filepath.FromSlash(relative))
		maximum := maximumPatchBytes
		if index == 0 {
			maximum = maximumBaseBytes
		} else if index == 2 {
			maximum = maximumTuningBytes
		}
		if err := validateRegularInput(path, maximum); err != nil {
			return preparedInputs{}, err
		}
		if _, err := captureDirect(ctx, runner, Command{Name: "git", Args: []string{"-C", root, "ls-files", "--error-unmatch", "--", relative}}); err != nil {
			return preparedInputs{}, fmt.Errorf("camera build input is not tracked: %s", relative)
		}
		headBytes, err := captureBoundedOutput(ctx, runner, platform.Command{Name: "git", Args: []string{"-C", root, "show", commit + ":" + relative}}, maximum)
		if err != nil {
			return preparedInputs{}, fmt.Errorf("read %s from support HEAD: %w", relative, err)
		}
		workBytes, err := os.ReadFile(path)
		if err != nil {
			return preparedInputs{}, fmt.Errorf("read camera input %s: %w", relative, err)
		}
		headDigest := sha256.Sum256(headBytes)
		workDigest := sha256.Sum256(workBytes)
		if headDigest != workDigest {
			return preparedInputs{}, fmt.Errorf("camera build input differs from support HEAD: %s", relative)
		}
		inputs = append(inputs, InputProvenance{Path: relative, SHA256: hex.EncodeToString(workDigest[:])})
		if index == 0 {
			base, err = ParseBase(workBytes)
			if err != nil {
				return preparedInputs{}, fmt.Errorf("parse authenticated BASE.txt: %w", err)
			}
		}
	}
	return preparedInputs{commit: commit, commitTime: commitTime.UTC(), base: base, inputs: inputs}, nil
}

// prepareRoots creates private build roots without changing a prior publication.
func prepareRoots(plan Plan, publication string) error {
	if _, err := os.Lstat(publication); !errors.Is(err, os.ErrNotExist) {
		if err == nil {
			return fmt.Errorf("camera package-set publication already exists: %s", publication)
		}
		return fmt.Errorf("inspect camera publication collision: %w", err)
	}
	for _, root := range []string{plan.WorkDirectory, plan.OutputDirectory} {
		directory, err := makeDirectoryRoute(plan.RepositoryRoot, root, 0o700)
		if err != nil {
			return fmt.Errorf("create camera build root %s: %w", root, err)
		}
		info, statErr := directory.Stat()
		closeErr := directory.Close()
		if statErr != nil || closeErr != nil || !info.IsDir() {
			return fmt.Errorf("camera build root is not a real directory: %s", root)
		}
	}
	return nil
}

// checkFreeSpace applies the host-side guard before image acquisition or build.
func checkFreeSpace(ctx context.Context, runner platform.Runner, path string, minimumGiB int) error {
	output, err := captureDirect(ctx, runner, Command{Name: "df", Args: []string{"-Pk", path}})
	if err != nil {
		return fmt.Errorf("inspect camera build free space: %w", err)
	}
	lines := strings.Split(output, "\n")
	if len(lines) < 2 {
		return errors.New("camera build free-space output is incomplete")
	}
	fields := strings.Fields(lines[len(lines)-1])
	if len(fields) < 4 {
		return errors.New("camera build free-space output is malformed")
	}
	available, err := strconv.ParseInt(fields[3], 10, 64)
	if err != nil || available < int64(minimumGiB)*1024*1024 {
		return fmt.Errorf("camera build requires at least %d GiB free", minimumGiB)
	}
	return nil
}

// makeTransaction creates and later removes one identity-checked private exchange.
func makeTransaction(workDirectory, buildID string) (string, func() error, error) {
	transaction, err := os.MkdirTemp(workDirectory, privateTransactionPrefix+buildID+"-")
	if err != nil {
		return "", nil, fmt.Errorf("create private camera build transaction: %w", err)
	}
	directory, err := openDirectoryRoute(workDirectory, transaction)
	if err != nil {
		_ = os.RemoveAll(transaction)
		return "", nil, fmt.Errorf("open private camera build transaction: %w", err)
	}
	original, err := directory.Stat()
	if err != nil || !original.IsDir() || original.Mode().Perm() != 0o700 {
		_ = directory.Close()
		_ = os.RemoveAll(transaction)
		return "", nil, errors.New("private camera build transaction is invalid")
	}
	cleaned := false
	cleanup := func() error {
		if cleaned {
			return nil
		}
		cleaned = true
		closeErr := directory.Close()
		current, err := os.Lstat(transaction)
		if errors.Is(err, os.ErrNotExist) {
			return closeErr
		}
		if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(original, current) {
			return errors.Join(closeErr, fmt.Errorf("refuse to remove changed camera build transaction: %s", transaction))
		}
		if err := os.RemoveAll(transaction); err != nil {
			return errors.Join(closeErr, fmt.Errorf("remove private camera build transaction: %w", err))
		}
		return closeErr
	}
	return transaction, cleanup, nil
}

// stagePolicyAndInputs copies only authenticated inputs and the compiled recipe.
func stagePolicyAndInputs(plan Plan, transaction string, inputs preparedInputs) error {
	inputDirectory := filepath.Join(transaction, "inputs")
	policyDirectory := filepath.Join(transaction, "policy")
	exchangeDirectory := filepath.Join(transaction, "exchange")
	for _, directory := range []string{inputDirectory, policyDirectory, filepath.Join(exchangeDirectory, "artifacts"), filepath.Join(exchangeDirectory, "metadata")} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return fmt.Errorf("create private camera build directory: %w", err)
		}
	}
	staged := []string{"BASE.txt", "imx681.patch", "imx681.yaml"}
	for index, relative := range inputPaths {
		maximum := maximumPatchBytes
		if index == 0 {
			maximum = maximumBaseBytes
		} else if index == 2 {
			maximum = maximumTuningBytes
		}
		data, err := readBoundedRegular(filepath.Join(plan.RepositoryRoot, filepath.FromSlash(relative)), maximum)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(data)
		if hex.EncodeToString(digest[:]) != inputs.inputs[index].SHA256 {
			return fmt.Errorf("camera build input changed before private staging: %s", relative)
		}
		if err := writeExclusive(filepath.Join(inputDirectory, staged[index]), data, 0o400); err != nil {
			return err
		}
	}
	return writeExclusive(filepath.Join(policyDirectory, "build.sh"), []byte(containerRecipe), 0o500)
}

// writeExclusive writes one new file durably without following links.
func writeExclusive(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return fmt.Errorf("create private camera build file %s: %w", path, err)
	}
	_, writeErr := file.Write(data)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		return fmt.Errorf("write private camera build file %s: %w", path, err)
	}
	return nil
}

// prepareDocker enforces the native Linux ARM64 engine and immutable image.
func (manager *Manager) prepareDocker(ctx context.Context, receipt *ExecutionReceipt, plan Plan) (dockerIdentity, error) {
	server, err := manager.capture(ctx, receipt, Command{Name: "docker", Args: []string{"version", "--format", "{{.Server.Os}}|{{.Server.Arch}}|{{.Server.Version}}"}})
	if err != nil {
		return dockerIdentity{}, err
	}
	parts := strings.Split(server, "|")
	if len(parts) != 3 || parts[0] != "linux" || (parts[1] != "arm64" && parts[1] != "aarch64") || parts[2] == "" {
		return dockerIdentity{}, fmt.Errorf("Docker server must be native Linux ARM64, got %q", server)
	}
	if plan.NoPull {
		if err := manager.run(ctx, receipt, Command{Name: "docker", Args: []string{"image", "inspect", ContainerImage}}); err != nil {
			return dockerIdentity{}, fmt.Errorf("immutable camera builder image is not present locally: %w", err)
		}
	} else if err := manager.run(ctx, receipt, Command{Name: "docker", Args: []string{"pull", "--platform", "linux/arm64", ContainerImage}}); err != nil {
		return dockerIdentity{}, fmt.Errorf("acquire immutable camera builder image: %w", err)
	}
	image, err := manager.capture(ctx, receipt, Command{Name: "docker", Args: []string{"image", "inspect", "--format", "{{.Id}}|{{.Os}}|{{.Architecture}}", ContainerImage}})
	if err != nil {
		return dockerIdentity{}, err
	}
	imageParts := strings.Split(image, "|")
	if len(imageParts) != 3 || !imageIdentityExpression.MatchString(imageParts[0]) || imageParts[1] != "linux" || (imageParts[2] != "arm64" && imageParts[2] != "aarch64") {
		return dockerIdentity{}, fmt.Errorf("camera builder image identity is invalid: %q", image)
	}
	return dockerIdentity{serverOS: parts[0], serverArch: parts[1], serverVersion: parts[2], imageID: imageParts[0]}, nil
}

// containerCommand compiles the sole Docker run invocation from validated data.
func containerCommand(plan Plan, inputs preparedInputs, transaction, buildID, containerName, uid, gid string) Command {
	inputDirectory := filepath.Join(transaction, "inputs")
	policyDirectory := filepath.Join(transaction, "policy")
	exchangeDirectory := filepath.Join(transaction, "exchange")
	environment := []string{
		"BASE_VERSION=" + inputs.base.UbuntuVersion,
		"DSC_SHA=" + inputs.base.DSCSHA256,
		"ORIG_SHA=" + inputs.base.OrigSHA256,
		"DEBIAN_SHA=" + inputs.base.DebianSHA256,
		"BASE_INPUT_SHA=" + inputs.inputs[0].SHA256,
		"PATCH_INPUT_SHA=" + inputs.inputs[1].SHA256,
		"YAML_INPUT_SHA=" + inputs.inputs[2].SHA256,
		"BUILD_ID=" + buildID,
		"BUILD_JOBS=" + strconv.Itoa(plan.Jobs),
		"SUPPORT_HEAD=" + inputs.commit,
		"SUPPORT_HEAD_TIME=" + inputs.commitTime.Format(time.RFC3339),
		"BUILDER_IMAGE=" + ContainerImage,
		"RECIPE_SHA256=" + plan.RecipeSHA256,
		"HOST_UID=" + uid,
		"HOST_GID=" + gid,
		"MINIMUM_FREE_GIB=" + strconv.Itoa(plan.MinimumFreeGiB),
	}
	args := []string{
		"run", "--rm", "--interactive", "--name", containerName,
		"--platform", "linux/arm64", "--hostname", "linux-armer-camera-builder",
		"--network", "bridge", "--pids-limit", "4096",
		"--security-opt", "no-new-privileges:true",
		"--mount", "type=bind,src=" + inputDirectory + ",dst=/inputs,readonly",
		"--mount", "type=bind,src=" + policyDirectory + ",dst=/policy,readonly",
		"--mount", "type=bind,src=" + exchangeDirectory + ",dst=/exchange",
	}
	for _, value := range environment {
		args = append(args, "--env", value)
	}
	args = append(args, ContainerImage, "/policy/build.sh")
	return Command{Name: "docker", Args: args}
}

// decimalIdentity accepts a non-empty numeric user or group identifier.
func decimalIdentity(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

// run records and executes one fixed host command.
func (manager *Manager) run(ctx context.Context, receipt *ExecutionReceipt, command Command) error {
	receipt.Executed = append(receipt.Executed, command)
	return manager.Runner.Run(ctx, platformCommand(command))
}

// capture records and captures one fixed host command.
func (manager *Manager) capture(ctx context.Context, receipt *ExecutionReceipt, command Command) (string, error) {
	receipt.Executed = append(receipt.Executed, command)
	return captureDirect(ctx, manager.Runner, command)
}

// captureDirect captures one command and rejects NUL-bearing or multiline scalars.
func captureDirect(ctx context.Context, runner platform.Runner, command Command) (string, error) {
	data, err := runner.Capture(ctx, platformCommand(command))
	if err != nil {
		return "", err
	}
	if bytes.IndexByte(data, 0) >= 0 {
		return "", errors.New("external command returned NUL-bearing output")
	}
	return strings.TrimSpace(string(data)), nil
}

// platformCommand converts a receipt-safe command into the process boundary.
func platformCommand(command Command) platform.Command {
	return platform.Command{Name: command.Name, Args: append([]string(nil), command.Args...)}
}

// publishBundle writes the public receipt, derives its authority before
// publication, and atomically renames a closed directory.
func publishBundle(plan Plan, transaction, publication string, bundle BundleReceipt, beforeAuthorityCheck func(string) error) (string, string, error) {
	artifacts := filepath.Join(transaction, "exchange", "artifacts")
	staging := filepath.Join(plan.OutputDirectory, ".publish-"+bundle.BuildID)
	if err := os.Mkdir(staging, 0o700); err != nil {
		return "", "", fmt.Errorf("create private camera publication: %w", err)
	}
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.RemoveAll(staging)
		}
	}()
	for _, artifact := range bundle.Artifacts {
		if err := copyRegularFile(filepath.Join(artifacts, artifact.Name), filepath.Join(staging, artifact.Name), 0o644); err != nil {
			return "", "", err
		}
	}
	receiptData, err := json.MarshalIndent(bundle, "", "  ")
	if err != nil {
		return "", "", fmt.Errorf("serialise camera build receipt: %w", err)
	}
	receiptData = append(receiptData, '\n')
	authorityDigest := sha256.Sum256(receiptData)
	authoritySHA256 := hex.EncodeToString(authorityDigest[:])
	if err := writeExclusive(filepath.Join(staging, ReceiptName), receiptData, 0o644); err != nil {
		return "", "", err
	}
	if err := syncDirectory(staging); err != nil {
		return "", "", err
	}
	if _, err := os.Lstat(publication); !errors.Is(err, os.ErrNotExist) {
		return "", "", fmt.Errorf("camera package-set publication collided before commit: %s", publication)
	}
	if err := publishNoReplace(staging, publication); err != nil {
		return "", "", fmt.Errorf("atomically publish camera package set: %w", err)
	}
	cleanup = false
	if err := syncDirectory(plan.OutputDirectory); err != nil {
		return publication, "", fmt.Errorf("flush camera package publication: %w", err)
	}
	if beforeAuthorityCheck != nil {
		if err := beforeAuthorityCheck(publication); err != nil {
			return publication, "", fmt.Errorf("camera build authority test hook: %w", err)
		}
	}
	publishedAuthority, err := inspectArtifact(filepath.Join(publication, ReceiptName), maximumBuildRecordBytes)
	if err != nil || publishedAuthority.SHA256 != authoritySHA256 || publishedAuthority.Size != int64(len(receiptData)) {
		return publication, "", errors.New("published camera build authority differs from its private pre-publication bytes")
	}
	return publication, authoritySHA256, nil
}

// copyRegularFile copies one non-link file into a newly created destination.
func copyRegularFile(source, destination string, mode os.FileMode) error {
	before, err := os.Lstat(source)
	if err != nil || before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() {
		return fmt.Errorf("camera artefact is not a regular file: %s", source)
	}
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	opened, err := input.Stat()
	if err != nil {
		return err
	}
	current, err := os.Lstat(source)
	if err != nil || current.Mode()&os.ModeSymlink != 0 || !os.SameFile(before, opened) || !os.SameFile(opened, current) {
		return fmt.Errorf("camera artefact changed while it was opened: %s", source)
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, input)
	syncErr := output.Sync()
	closeErr := output.Close()
	if err := errors.Join(copyErr, syncErr, closeErr); err != nil {
		return fmt.Errorf("copy camera artefact %s: %w", filepath.Base(source), err)
	}
	after, err := os.Lstat(source)
	if err != nil || after.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, after) || after.Size() != opened.Size() {
		return fmt.Errorf("camera artefact changed during copy: %s", source)
	}
	return nil
}

// syncDirectory flushes directory entry changes before success is reported.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open camera publication directory: %w", err)
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	if err := errors.Join(syncErr, closeErr); err != nil {
		return fmt.Errorf("flush camera publication directory: %w", err)
	}
	return nil
}
