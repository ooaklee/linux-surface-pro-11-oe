// Package doctor reports whether the host can execute linux-armer workflows.
package doctor

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"github.com/ooaklee/linux-surface-pro-11-oe/cli/linux-armer/internal/platform"
)

type Status string

const (
	StatusPass Status = "pass"
	StatusWarn Status = "warn"
	StatusFail Status = "fail"
)

type Check struct {
	Name     string `json:"name"`
	Status   Status `json:"status"`
	Details  string `json:"details"`
	Required bool   `json:"required"`
}

type Report struct {
	Ready  bool    `json:"ready"`
	Checks []Check `json:"checks"`
}

type Doctor struct {
	Runner platform.Runner
}

func New(runner platform.Runner) *Doctor {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Doctor{Runner: runner}
}

func (d *Doctor) Run(ctx context.Context, workspace string) Report {
	if workspace == "" {
		workspace = "."
	}
	report := Report{Ready: true}
	add := func(check Check) {
		report.Checks = append(report.Checks, check)
		if check.Required && check.Status == StatusFail {
			report.Ready = false
		}
	}
	add(Check{Name: "host-architecture", Status: StatusPass, Details: runtime.GOOS + "/" + runtime.GOARCH, Required: false})
	if path, err := exec.LookPath("docker"); err != nil {
		add(Check{Name: "docker-cli", Status: StatusFail, Details: "docker executable was not found", Required: true})
	} else {
		add(Check{Name: "docker-cli", Status: StatusPass, Details: path, Required: true})
		output, dockerErr := d.Runner.Capture(ctx, platform.Command{Name: "docker", Args: []string{"info", "--format", "{{.ServerVersion}} {{.Architecture}}"}})
		if dockerErr != nil {
			add(Check{Name: "docker-daemon", Status: StatusFail, Details: dockerErr.Error(), Required: true})
		} else {
			add(Check{Name: "docker-daemon", Status: StatusPass, Details: strings.TrimSpace(string(output)), Required: true})
		}
	}
	absolute, err := filepathAbs(workspace)
	if err != nil {
		add(Check{Name: "workspace", Status: StatusFail, Details: err.Error(), Required: true})
	} else {
		add(Check{Name: "workspace", Status: StatusPass, Details: absolute, Required: true})
		if available, diskErr := availableBytes(absolute); diskErr != nil {
			add(Check{Name: "free-space", Status: StatusWarn, Details: diskErr.Error(), Required: false})
		} else {
			const recommended = uint64(24) * 1024 * 1024 * 1024
			status := StatusPass
			if available < recommended {
				status = StatusFail
			}
			add(Check{Name: "free-space", Status: status, Details: formatBytes(available) + " available; 24 GiB recommended", Required: true})
		}
	}
	if os.Geteuid() == 0 {
		add(Check{Name: "privilege", Status: StatusWarn, Details: "run the CLI as a regular user; Docker isolates image operations", Required: false})
	} else {
		add(Check{Name: "privilege", Status: StatusPass, Details: "running as a regular user", Required: false})
	}
	return report
}

func availableBytes(path string) (uint64, error) {
	var stats syscall.Statfs_t
	if err := syscall.Statfs(path, &stats); err != nil {
		return 0, err
	}
	return stats.Bavail * uint64(stats.Bsize), nil
}

func filepathAbs(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve workspace: %w", err)
	}
	info, err := os.Stat(absolute)
	if err != nil {
		return "", fmt.Errorf("inspect workspace: %w", err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("workspace %q is not a directory", absolute)
	}
	return absolute, nil
}

func formatBytes(value uint64) string {
	return strconv.FormatFloat(float64(value)/(1024*1024*1024), 'f', 1, 64) + " GiB"
}
