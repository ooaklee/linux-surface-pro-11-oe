package install

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

const (
	// maximumCommandArguments bounds every direct process invocation.
	maximumCommandArguments = 32
	// maximumCommandArgumentBytes bounds each individual process argument.
	maximumCommandArgumentBytes = 4096
	// aptGetCommand is the trusted live-root Debian dependency resolver.
	aptGetCommand = "/usr/bin/apt-get"
	// chrootCommand is the trusted alternate-root process boundary.
	chrootCommand = "/usr/sbin/chroot"
	// dpkgCommand is the trusted exact-package rollback tool.
	dpkgCommand = "/usr/bin/dpkg"
	// dpkgDebCommand is the trusted Debian archive metadata reader.
	dpkgDebCommand = "/usr/bin/dpkg-deb"
	// unameCommand is the trusted live-kernel ABI reader.
	unameCommand = "/usr/bin/uname"
	// updateGRUBCommand is the trusted live-root GRUB generator.
	updateGRUBCommand = "/usr/sbin/update-grub"
	// updateInitramfsCommand is the trusted live-root initramfs generator.
	updateInitramfsCommand = "/usr/sbin/update-initramfs"
)

// errCommandOutputLimit marks a child process that exceeded its capture budget.
var errCommandOutputLimit = errors.New("command output exceeded its safety limit")

// boundedOutput retains at most limit bytes while allowing a child process to finish.
type boundedOutput struct {
	// bytes contains the retained prefix.
	bytes []byte
	// limit is the maximum retained length.
	limit int
	// exceeded reports that later bytes were deliberately discarded.
	exceeded bool
}

// permittedCommands is the closed executable set used by planning and recovery.
var permittedCommands = map[string]bool{
	aptGetCommand:          true,
	chrootCommand:          true,
	dpkgCommand:            true,
	dpkgDebCommand:         true,
	unameCommand:           true,
	updateGRUBCommand:      true,
	updateInitramfsCommand: true,
}

// validateCommand enforces the closed executable set and bounded, control-free arguments.
func validateCommand(command Command) error {
	if !permittedCommands[command.Name] {
		return fmt.Errorf("refusing unrecognised kernel command %q", command.Name)
	}
	if len(command.Args) > maximumCommandArguments {
		return fmt.Errorf("kernel command %s has too many arguments", command.Name)
	}
	for _, argument := range command.Args {
		if len(argument) > maximumCommandArgumentBytes || !utf8.ValidString(argument) || strings.IndexByte(argument, 0) >= 0 {
			return fmt.Errorf("kernel command %s contains an oversized or malformed argument", command.Name)
		}
		for _, character := range argument {
			if character < 0x20 || character == 0x7f {
				return fmt.Errorf("kernel command %s contains a control character", command.Name)
			}
		}
	}
	return nil
}

// Write implements io.Writer while bounding retained command output.
func (output *boundedOutput) Write(data []byte) (int, error) {
	if output == nil || output.limit < 0 {
		return 0, errors.New("bounded command output is unavailable")
	}
	remaining := output.limit - len(output.bytes)
	if remaining > 0 {
		keep := len(data)
		if keep > remaining {
			keep = remaining
		}
		output.bytes = append(output.bytes, data[:keep]...)
	}
	if len(data) > remaining {
		output.exceeded = true
	}
	return len(data), nil
}

// captureCommand runs one read-only command with bounded stdout and stderr.
func (manager *Manager) captureCommand(ctx context.Context, command Command, maximum int) ([]byte, error) {
	if err := validateCommand(command); err != nil {
		return nil, err
	}
	stdout := &boundedOutput{limit: maximum}
	stderr := &boundedOutput{limit: maximumReceiptErrorBytes}
	err := manager.runner.Run(ctx, platform.Command{
		Name:   command.Name,
		Args:   append([]string(nil), command.Args...),
		Stdout: stdout,
		Stderr: stderr,
	})
	if stdout.exceeded {
		return nil, errCommandOutputLimit
	}
	if err != nil {
		message := strings.TrimSpace(string(stderr.bytes))
		if message != "" {
			return nil, fmt.Errorf("%w: %s", err, message)
		}
		return nil, err
	}
	return append([]byte(nil), stdout.bytes...), nil
}

// installationCommands constructs the fixed package, initramfs, and GRUB sequence.
func installationCommands(root, abi string, packagePaths []string) ([]Command, error) {
	commands := make([]Command, 0, 3)
	if root == string(filepath.Separator) {
		args := []string{"--assume-yes", "--no-install-recommends", "--no-remove", "--reinstall", "install"}
		args = append(args, packagePaths...)
		commands = append(commands, Command{Operation: OperationInstallPackages, Name: aptGetCommand, Args: args})
		commands = append(commands,
			Command{Operation: OperationUpdateInitramfs, Name: updateInitramfsCommand, Args: []string{"-u", "-k", abi}},
			Command{Operation: OperationUpdateGRUB, Name: updateGRUBCommand},
		)
	} else {
		args := []string{root, dpkgCommand, "--install"}
		args = append(args, packagePaths...)
		commands = append(commands, Command{Operation: OperationInstallPackages, Name: chrootCommand, Args: args})
		commands = append(commands,
			Command{Operation: OperationUpdateInitramfs, Name: chrootCommand, Args: []string{root, updateInitramfsCommand, "-u", "-k", abi}},
			Command{Operation: OperationUpdateGRUB, Name: chrootCommand, Args: []string{root, updateGRUBCommand}},
		)
	}
	for _, command := range commands {
		if err := validateCommand(command); err != nil {
			return nil, err
		}
	}
	return commands, nil
}

// rollbackCommands constructs the exact target-package purge operation.
func rollbackCommands(root string, packageNames []string) ([]Command, error) {
	var commands []Command
	if root == string(filepath.Separator) {
		args := append([]string{"--purge"}, packageNames...)
		commands = []Command{{Operation: OperationRollbackPackages, Name: dpkgCommand, Args: args}}
	} else {
		args := []string{root, dpkgCommand, "--purge"}
		args = append(args, packageNames...)
		commands = []Command{{Operation: OperationRollbackPackages, Name: chrootCommand, Args: args}}
	}
	for _, command := range commands {
		if err := validateCommand(command); err != nil {
			return nil, err
		}
	}
	return commands, nil
}
