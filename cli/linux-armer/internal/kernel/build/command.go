package build

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// dockerCommand is the sole host executable permitted by the native manager.
	dockerCommand = "docker"
	// dockerPlatform fixes every build container to the kernel target architecture.
	dockerPlatform = "linux/arm64"
	// dockerVolumePrefix distinguishes managed kernel source volumes.
	dockerVolumePrefix = "linux-armer-kernel-build-"
	// dockerContainerPrefix distinguishes transient managed build containers.
	dockerContainerPrefix = "linux-armer-kernel-build-run-"
	// dockerOwnershipLabel marks a reusable volume as CLI-owned.
	dockerOwnershipLabel = "io.linux-armer.kernel-build"
	// dockerWorkspaceLabel binds a volume to its canonical host work directory.
	dockerWorkspaceLabel = "io.linux-armer.workspace-sha256"
	// maximumCommandArguments bounds direct Docker invocations.
	maximumCommandArguments = 64
	// maximumCommandArgumentBytes bounds every individual Docker argument.
	maximumCommandArgumentBytes = 8192
	// maximumDockerCaptureBytes bounds volume identity output.
	maximumDockerCaptureBytes = 4096
)

// boundedWriter retains a fixed output prefix while reporting overflow.
type boundedWriter struct {
	// data is the retained prefix.
	data []byte
	// limit is the maximum retained byte count.
	limit int
	// exceeded reports that further output was discarded.
	exceeded bool
}

// Write implements io.Writer without allowing unbounded child-process output.
func (writer *boundedWriter) Write(data []byte) (int, error) {
	if writer == nil || writer.limit < 0 {
		return 0, errors.New("bounded Docker output is unavailable")
	}
	remaining := writer.limit - len(writer.data)
	if remaining > 0 {
		keep := len(data)
		if keep > remaining {
			keep = remaining
		}
		writer.data = append(writer.data, data[:keep]...)
	}
	if len(data) > remaining {
		writer.exceeded = true
	}
	return len(data), nil
}

// randomToken returns a lowercase identifier suitable for a Docker container name.
func randomToken() (string, error) {
	var value [12]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", fmt.Errorf("generate kernel build container identifier: %w", err)
	}
	return hex.EncodeToString(value[:]), nil
}

// validateCommand enforces the closed Docker boundary and control-free arguments.
func validateCommand(command Command) error {
	if command.Name != dockerCommand {
		return fmt.Errorf("refusing unrecognised kernel build executable %q", command.Name)
	}
	if len(command.Args) == 0 || len(command.Args) > maximumCommandArguments {
		return errors.New("kernel build Docker command has an invalid argument count")
	}
	for _, argument := range command.Args {
		if len(argument) > maximumCommandArgumentBytes || !utf8.ValidString(argument) || strings.IndexByte(argument, 0) >= 0 {
			return errors.New("kernel build Docker command contains an oversized or malformed argument")
		}
		for _, character := range argument {
			if character < 0x20 || character == 0x7f {
				return errors.New("kernel build Docker command contains a control character")
			}
		}
	}
	return nil
}

// runCommand executes one validated Docker command and records its exact arguments.
func (manager *Manager) runCommand(ctx context.Context, receipt *Receipt, command Command) error {
	if err := validateCommand(command); err != nil {
		return err
	}
	receipt.Executed = append(receipt.Executed, cloneCommand(command))
	return manager.Runner.Run(ctx, platform.Command{Name: command.Name, Args: append([]string(nil), command.Args...)})
}

// captureCommand executes one validated Docker command with bounded output.
func (manager *Manager) captureCommand(ctx context.Context, receipt *Receipt, command Command) (string, error) {
	if err := validateCommand(command); err != nil {
		return "", err
	}
	stdout := &boundedWriter{limit: maximumDockerCaptureBytes}
	stderr := &boundedWriter{limit: maximumDockerCaptureBytes}
	receipt.Executed = append(receipt.Executed, cloneCommand(command))
	err := manager.Runner.Run(ctx, platform.Command{
		Name: command.Name, Args: append([]string(nil), command.Args...), Stdout: stdout, Stderr: stderr,
	})
	if stdout.exceeded || stderr.exceeded {
		return "", errors.New("Docker volume command output exceeded its safety limit")
	}
	if err != nil {
		diagnostic := strings.TrimSpace(string(stderr.data))
		if diagnostic != "" {
			return "", fmt.Errorf("%w: %s", err, diagnostic)
		}
		return "", err
	}
	return strings.TrimSpace(string(stdout.data)), nil
}

// volumeName derives a stable bounded Docker volume name from workspace identity.
func volumeName(identity string) string {
	return dockerVolumePrefix + identity[:16]
}

// volumeCreateCommand constructs the labelled idempotent volume creation request.
func volumeCreateCommand(plan Plan) Command {
	return Command{Name: dockerCommand, Args: []string{
		"volume", "create", "--driver", "local",
		"--label", dockerOwnershipLabel + "=true",
		"--label", dockerWorkspaceLabel + "=" + plan.WorkspaceIdentity,
		plan.WorkVolume,
	}}
}

// volumeInspectCommand constructs the exact managed-volume identity check.
func volumeInspectCommand(plan Plan) Command {
	format := "{{.Name}}|{{.Driver}}|{{index .Labels \"" + dockerOwnershipLabel + "\"}}|{{index .Labels \"" + dockerWorkspaceLabel + "\"}}"
	return Command{Name: dockerCommand, Args: []string{"volume", "inspect", "--format", format, plan.WorkVolume}}
}

// containerCommand constructs the direct Docker run invocation for one private transaction.
func containerCommand(plan Plan, transactionDirectory, containerName string) Command {
	return Command{Name: dockerCommand, Args: []string{
		"run", "--rm", "--name", containerName,
		"--platform", dockerPlatform,
		"--mount", "type=volume,src=" + plan.WorkVolume + ",dst=/linux-work",
		"--mount", "type=bind,src=" + transactionDirectory + ",dst=/exchange",
		"--env", "LINUX_ARMER_RECIPE_SHA256=" + plan.RecipeSHA256,
		plan.ContainerImage,
		"/bin/bash", "/exchange/build-policy.sh",
		plan.GitURL, plan.GitRef, strconv.Itoa(plan.Jobs), strconv.FormatBool(plan.ResetSource), strconv.FormatBool(plan.SkipClean),
	}}
}

// previewContainerCommand replaces runtime-only names with stable explanatory markers.
func previewContainerCommand(plan Plan) Command {
	return containerCommand(plan, "<private-transaction-directory>", "<generated-container-name>")
}

// cleanupContainerCommand constructs bounded forced removal for an interrupted run.
func cleanupContainerCommand(containerName string) Command {
	return Command{Name: dockerCommand, Args: []string{"rm", "--force", containerName}}
}

// cloneCommand prevents later argument mutation from altering receipt evidence.
func cloneCommand(command Command) Command {
	command.Args = append([]string(nil), command.Args...)
	return command
}
