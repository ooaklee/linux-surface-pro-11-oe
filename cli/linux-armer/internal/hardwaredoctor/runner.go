package hardwaredoctor

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"
)

// Probe identifies one compiled, read-only external command.
type Probe string

const (
	// ProbeBluetoothService asks systemd whether bluetooth.service is active.
	ProbeBluetoothService Probe = "bluetooth-service"
	// ProbeBlueZControllers asks BlueZ for its controller list.
	ProbeBlueZControllers Probe = "bluez-controllers"
	// ProbeAudioSession asks whether the PulseAudio-compatible session is reachable.
	ProbeAudioSession Probe = "audio-session"
)

// ProbeResult is the bounded process result retained for private parsing.
type ProbeResult struct {
	// ExitCode is zero for success and the process exit status otherwise.
	ExitCode int
	// Output is bounded standard output; it must never be copied into a report.
	Output []byte
}

// ProbeRunner is the injected boundary for the doctor's fixed read-only probes.
type ProbeRunner interface {
	// Run executes one recognised probe, honours ctx, and caps standard output.
	Run(context.Context, Probe, int64) (ProbeResult, error)
}

// ExecProbeRunner executes the compiled command allow-list without a shell.
type ExecProbeRunner struct{}

// probeCommand is one immutable executable and argument vector.
type probeCommand struct {
	// name is resolved through the process search path.
	name string
	// args are passed separately and never interpreted by a shell.
	args []string
	// captureOutput retains bounded standard output only when a parser needs it.
	captureOutput bool
}

// cappedWriter retains a prefix while draining all remaining process output.
type cappedWriter struct {
	// buffer stores at most limit bytes.
	buffer bytes.Buffer
	// limit is the maximum accepted byte count.
	limit int64
	// observed is the bounded number of bytes accepted before overflow.
	observed int64
	// retain records whether the bounded prefix is needed by a private parser.
	retain bool
	// exceeded records whether any bytes were discarded.
	exceeded bool
}

// Run executes a fixed probe with bounded output and no standard input.
func (ExecProbeRunner) Run(ctx context.Context, probe Probe, outputLimit int64) (ProbeResult, error) {
	if err := ctx.Err(); err != nil {
		return ProbeResult{}, err
	}
	if outputLimit < 1 || outputLimit > maximumProbeOutput {
		return ProbeResult{}, fmt.Errorf("invalid hardware probe output limit")
	}
	command, err := commandForProbe(probe)
	if err != nil {
		return ProbeResult{}, err
	}
	output := &cappedWriter{limit: outputLimit, retain: command.captureOutput}
	process := exec.CommandContext(ctx, command.name, command.args...)
	process.Stdin = nil
	process.Stdout = output
	process.Stderr = io.Discard
	process.Env = append(os.Environ(), "LC_ALL=C", "LANG=C")
	process.WaitDelay = 250 * time.Millisecond
	err = process.Run()
	result := ProbeResult{ExitCode: 0}
	if command.captureOutput {
		result.Output = append([]byte(nil), output.buffer.Bytes()...)
	}
	if output.exceeded {
		return result, ErrReadLimit
	}
	if err == nil {
		return result, nil
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		result.ExitCode = exitError.ExitCode()
		return result, nil
	}
	return ProbeResult{}, err
}

// Write retains only the configured prefix while allowing the child to finish.
func (writer *cappedWriter) Write(content []byte) (int, error) {
	originalLength := len(content)
	remaining := writer.limit - writer.observed
	if remaining <= 0 {
		writer.exceeded = writer.exceeded || originalLength != 0
		return originalLength, nil
	}
	if int64(len(content)) > remaining {
		content = content[:remaining]
		writer.exceeded = true
	}
	writer.observed += int64(len(content))
	if writer.retain {
		_, _ = writer.buffer.Write(content)
	}
	return originalLength, nil
}

// commandForProbe resolves only the three reviewed, non-mutating commands.
func commandForProbe(probe Probe) (probeCommand, error) {
	switch probe {
	case ProbeBluetoothService:
		return probeCommand{name: "systemctl", args: []string{"--quiet", "is-active", "bluetooth.service"}}, nil
	case ProbeBlueZControllers:
		return probeCommand{name: "bluetoothctl", args: []string{"list"}, captureOutput: true}, nil
	case ProbeAudioSession:
		return probeCommand{name: "pactl", args: []string{"info"}}, nil
	default:
		return probeCommand{}, fmt.Errorf("unsupported hardware probe %q", probe)
	}
}
