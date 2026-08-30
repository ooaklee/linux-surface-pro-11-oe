package platform

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const toolsDockerfile = `FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      binutils ca-certificates coreutils cpio dosfstools dpkg e2fsprogs \
      file initramfs-tools kmod libarchive-tools md5deep mtools parted \
      squashfs-tools xorriso xz-utils zstd \
 && rm -rf /var/lib/apt/lists/*
`

type Docker struct {
	Runner Runner
}

func NewDocker(runner Runner) *Docker {
	if runner == nil {
		runner = ExecRunner{}
	}
	return &Docker{Runner: runner}
}

func (d *Docker) Check(ctx context.Context) error {
	_, err := d.Runner.Capture(ctx, Command{Name: "docker", Args: []string{"info", "--format", "{{.ServerVersion}}"}})
	if err != nil {
		return fmt.Errorf("Docker is required and its daemon must be running: %w", err)
	}
	return nil
}

func (d *Docker) EnsureToolsImage(ctx context.Context) (string, error) {
	digest := sha256.Sum256([]byte(toolsDockerfile))
	name := fmt.Sprintf("linux-armer-builder:%x", digest[:6])
	if _, err := d.Runner.Capture(ctx, Command{Name: "docker", Args: []string{"image", "inspect", name}}); err == nil {
		return name, nil
	}
	contextDir, err := os.MkdirTemp("", "linux-armer-docker-context-")
	if err != nil {
		return "", fmt.Errorf("create Docker build context: %w", err)
	}
	defer os.RemoveAll(contextDir)
	err = d.Runner.Run(ctx, Command{
		Name:  "docker",
		Args:  []string{"build", "--platform", "linux/arm64", "--tag", name, "--file", "-", contextDir},
		Stdin: strings.NewReader(toolsDockerfile),
	})
	if err != nil {
		return "", fmt.Errorf("build image tooling container: %w", err)
	}
	return name, nil
}

func (d *Docker) RunInWorkspace(ctx context.Context, image, workspace string, args ...string) error {
	absolute, err := filepath.Abs(workspace)
	if err != nil {
		return fmt.Errorf("resolve workspace: %w", err)
	}
	dockerArgs := []string{
		"run", "--rm", "--platform", "linux/arm64",
		"--volume", absolute + ":/work",
		"--workdir", "/work",
		image,
	}
	dockerArgs = append(dockerArgs, args...)
	return d.Runner.Run(ctx, Command{Name: "docker", Args: dockerArgs})
}

func (d *Docker) CaptureInWorkspace(ctx context.Context, image, workspace string, args ...string) ([]byte, error) {
	absolute, err := filepath.Abs(workspace)
	if err != nil {
		return nil, fmt.Errorf("resolve workspace: %w", err)
	}
	dockerArgs := []string{
		"run", "--rm", "--platform", "linux/arm64",
		"--volume", absolute + ":/work",
		"--workdir", "/work",
		image,
	}
	dockerArgs = append(dockerArgs, args...)
	return d.Runner.Capture(ctx, Command{Name: "docker", Args: dockerArgs})
}
