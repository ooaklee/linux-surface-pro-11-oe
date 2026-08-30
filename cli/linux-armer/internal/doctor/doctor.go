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

// Status is the severity assigned to one diagnostic check.
type Status string

const (
	// StatusPass means the checked capability is available.
	StatusPass Status = "pass"
	// StatusWarn means the condition is noteworthy but does not block a build.
	StatusWarn Status = "warn"
	// StatusFail means the checked capability does not meet its requirement.
	StatusFail Status = "fail"
)

// Check is one human-readable host diagnostic and its readiness impact.
type Check struct {
	// Name is the stable diagnostic identifier used in text and JSON output.
	Name string `json:"name"`
	// Status is the observed result severity.
	Status Status `json:"status"`
	// Details explains the observation or suggests a corrective action.
	Details string `json:"details"`
	// Required marks failures that make the overall report not ready.
	Required bool `json:"required"`
}

// Report combines diagnostic checks into an overall workflow-readiness result.
type Report struct {
	// Ready is false when any required check fails.
	Ready bool `json:"ready"`
	// Checks retains results in the order users should review them.
	Checks []Check `json:"checks"`
}

// Doctor evaluates the host through an injectable external-command boundary.
type Doctor struct {
	// Runner executes capability probes such as querying the Docker daemon.
	Runner platform.Runner
}

// New constructs a host doctor, using direct process execution when runner is
// nil.
func New(runner platform.Runner) *Doctor {
	if runner == nil {
		runner = platform.ExecRunner{}
	}
	return &Doctor{Runner: runner}
}

// Run checks the container runtime, workspace, free space, and privilege mode
// needed for image workflows without changing the host.
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

// availableBytes reports the filesystem space available to an unprivileged
// process at path.
func availableBytes(path string) (uint64, error) {
	var stats syscall.Statfs_t
	if err := syscall.Statfs(path, &stats); err != nil {
		return 0, err
	}
	return stats.Bavail * uint64(stats.Bsize), nil
}

// filepathAbs resolves path and requires it to identify an existing directory.
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

// formatBytes renders a byte count as a concise binary-gigabyte value.
func formatBytes(value uint64) string {
	return strconv.FormatFloat(float64(value)/(1024*1024*1024), 'f', 1, 64) + " GiB"
}
