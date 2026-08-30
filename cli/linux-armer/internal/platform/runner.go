// Package platform owns host capability and external-process boundaries.
package platform

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
)

// Command describes one external process without coupling callers to os/exec.
type Command struct {
	// Name is the executable resolved using the host's normal search rules.
	Name string
	// Args are passed as distinct arguments without shell interpretation.
	Args []string
	// Dir optionally selects the child process working directory.
	Dir string
	// Env adds or replaces variables in the inherited process environment.
	Env []string
	// Stdin optionally supplies the child process standard input.
	Stdin io.Reader
	// Stdout optionally receives standard output; nil streams to the parent.
	Stdout io.Writer
	// Stderr optionally receives standard error; nil streams to the parent.
	Stderr io.Writer
}

// Runner is the boundary for executing external tools. Implementations may
// stream output or capture standard output for programmatic inspection.
type Runner interface {
	// Run executes command and returns after it exits or the context is cancelled.
	Run(context.Context, Command) error
	// Capture executes command and returns its standard output.
	Capture(context.Context, Command) ([]byte, error)
}

// ExecRunner executes commands directly as child processes without invoking a
// shell.
type ExecRunner struct{}

// Run executes command, inheriting process output streams when none are
// supplied, and annotates failures with the executable name.
func (ExecRunner) Run(ctx context.Context, command Command) error {
	cmd := exec.CommandContext(ctx, command.Name, command.Args...)
	cmd.Dir = command.Dir
	cmd.Stdin = command.Stdin
	cmd.Stdout = command.Stdout
	cmd.Stderr = command.Stderr
	if cmd.Stdout == nil {
		cmd.Stdout = os.Stdout
	}
	if cmd.Stderr == nil {
		cmd.Stderr = os.Stderr
	}
	if command.Env != nil {
		cmd.Env = append(os.Environ(), command.Env...)
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("run %s: %w", command.Name, err)
	}
	return nil
}

// Capture returns standard output and includes captured standard error in a
// failed command's diagnostic.
func (r ExecRunner) Capture(ctx context.Context, command Command) ([]byte, error) {
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := r.Run(ctx, command); err != nil {
		if stderr.Len() > 0 {
			return nil, fmt.Errorf("%w: %s", err, stderr.String())
		}
		return nil, err
	}
	return stdout.Bytes(), nil
}
