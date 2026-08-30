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

type Command struct {
	Name   string
	Args   []string
	Dir    string
	Env    []string
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

type Runner interface {
	Run(context.Context, Command) error
	Capture(context.Context, Command) ([]byte, error)
}

type ExecRunner struct{}

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
