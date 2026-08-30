package capture

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// ExecRunner executes camera utilities directly without invoking a shell.
type ExecRunner struct{}

// boundedBuffer retains no more than its configured byte limit.
type boundedBuffer struct {
	// mutex serialises concurrent child stdout and stderr writes.
	mutex sync.Mutex
	// data stores the retained prefix.
	data bytes.Buffer
	// limit is the maximum accepted byte count.
	limit int64
	// seen records the complete number of bytes offered by the child.
	seen int64
}

// Write retains a bounded prefix while allowing the child process to finish.
func (buffer *boundedBuffer) Write(content []byte) (int, error) {
	buffer.mutex.Lock()
	defer buffer.mutex.Unlock()
	length := len(content)
	buffer.seen += int64(length)
	remaining := buffer.limit - int64(buffer.data.Len())
	if remaining > 0 {
		if int64(len(content)) > remaining {
			content = content[:remaining]
		}
		_, _ = buffer.data.Write(content)
	}
	return length, nil
}

// Capture runs one direct command and rejects output that exceeds limit.
func (ExecRunner) Capture(ctx context.Context, command Command, limit int64) ([]byte, error) {
	if err := validateCommand(command); err != nil {
		return nil, err
	}
	if limit < 1 || limit > maximumMetadataBytes {
		return nil, fmt.Errorf("camera command output limit is invalid")
	}
	stdout := &boundedBuffer{limit: limit}
	stderr := &boundedBuffer{limit: limit}
	process := exec.CommandContext(ctx, command.Name, command.Args...)
	process.Stdin = nil
	process.Stdout = stdout
	process.Stderr = stderr
	process.Env = append(os.Environ(), "LC_ALL=C", "LANG=C")
	process.WaitDelay = 500 * time.Millisecond
	err := process.Run()
	if stdout.seen > limit || stderr.seen > limit {
		return nil, fmt.Errorf("camera command output exceeded the compiled limit")
	}
	if err != nil {
		message := bytes.TrimSpace(stderr.data.Bytes())
		if len(message) != 0 {
			return nil, fmt.Errorf("run %s: %w: %s", command.Name, err, message)
		}
		return nil, fmt.Errorf("run %s: %w", command.Name, err)
	}
	return append([]byte(nil), stdout.data.Bytes()...), nil
}

// Run executes one direct command and streams its output to bounded writers.
func (ExecRunner) Run(ctx context.Context, command Command, stdout, stderr io.Writer) error {
	if err := validateCommand(command); err != nil {
		return err
	}
	if stdout == nil {
		stdout = io.Discard
	}
	if stderr == nil {
		stderr = io.Discard
	}
	process := exec.CommandContext(ctx, command.Name, command.Args...)
	process.Stdin = nil
	process.Stdout = stdout
	process.Stderr = stderr
	process.Env = append(os.Environ(), "LC_ALL=C", "LANG=C")
	process.WaitDelay = 500 * time.Millisecond
	if err := process.Run(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("run %s: camera operation timed out: %w", command.Name, ctx.Err())
		}
		return fmt.Errorf("run %s: %w", command.Name, err)
	}
	return nil
}

// validateCommand limits execution to the reviewed camera utility vocabulary
// and rejects control characters or unreasonable argument vectors.
func validateCommand(command Command) error {
	switch command.Name {
	case "media-ctl", "v4l2-ctl", "journalctl", "dmesg", "uname", "fuser":
	default:
		return fmt.Errorf("refusing unrecognised camera executable %q", command.Name)
	}
	if len(command.Args) > 32 {
		return fmt.Errorf("camera command has too many arguments")
	}
	for _, argument := range command.Args {
		if len(argument) > 8192 || !utf8.ValidString(argument) || containsControlCharacter(argument) {
			return fmt.Errorf("camera command contains an invalid argument")
		}
	}
	return nil
}

// containsControlCharacter rejects terminal, log, and utility mini-language
// control characters while retaining ordinary Unicode path text.
func containsControlCharacter(value string) bool {
	for _, character := range value {
		if unicode.IsControl(character) {
			return true
		}
	}
	return false
}
