package hardwaredoctor

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

// TestCommandForProbeUsesFixedReadOnlyArguments verifies the complete process allow-list.
func TestCommandForProbeUsesFixedReadOnlyArguments(t *testing.T) {
	tests := []struct {
		// name identifies the subtest.
		name string
		// probe is the compiled diagnostic operation.
		probe Probe
		// want is the exact executable and argument vector.
		want probeCommand
	}{
		{name: "service", probe: ProbeBluetoothService, want: probeCommand{name: "systemctl", args: []string{"--quiet", "is-active", "bluetooth.service"}}},
		{name: "controllers", probe: ProbeBlueZControllers, want: probeCommand{name: "bluetoothctl", args: []string{"list"}, captureOutput: true}},
		{name: "audio session", probe: ProbeAudioSession, want: probeCommand{name: "pactl", args: []string{"info"}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := commandForProbe(test.probe)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("commandForProbe() = %#v, want %#v", got, test.want)
			}
		})
	}
	if _, err := commandForProbe(Probe("private-command")); err == nil {
		t.Fatal("commandForProbe(unknown) succeeded")
	}
}

// TestCappedWriterDrainsAndRetainsOnlyPrefix verifies output memory stays bounded.
func TestCappedWriterDrainsAndRetainsOnlyPrefix(t *testing.T) {
	writer := &cappedWriter{limit: 4, retain: true}
	written, err := writer.Write([]byte("private-value"))
	if err != nil || written != len("private-value") {
		t.Fatalf("Write() = %d, %v", written, err)
	}
	if got := writer.buffer.String(); got != "priv" {
		t.Fatalf("retained output = %q", got)
	}
	if !writer.exceeded {
		t.Fatal("writer.exceeded = false")
	}
	written, err = writer.Write([]byte("more"))
	if err != nil || written != len("more") || writer.buffer.String() != "priv" {
		t.Fatalf("second Write() = %d, %v, %q", written, err, writer.buffer.String())
	}
}

// TestCappedWriterCanDiscardPrivateOutput verifies exit-only probes retain no bytes.
func TestCappedWriterCanDiscardPrivateOutput(t *testing.T) {
	writer := &cappedWriter{limit: 64, retain: false}
	privateValue := []byte("private-user private-host")
	written, err := writer.Write(privateValue)
	if err != nil || written != len(privateValue) {
		t.Fatalf("Write() = %d, %v", written, err)
	}
	if writer.buffer.Len() != 0 || writer.observed != int64(len(privateValue)) || writer.exceeded {
		t.Fatalf("discarding writer = %#v", writer)
	}
}

// TestExecProbeRunnerRejectsUnknownProbeAndUnsafeLimit verifies validation occurs before execution.
func TestExecProbeRunnerRejectsUnknownProbeAndUnsafeLimit(t *testing.T) {
	runner := ExecProbeRunner{}
	if _, err := runner.Run(context.Background(), Probe("unknown"), maximumProbeOutput); err == nil {
		t.Fatal("unknown probe unexpectedly ran")
	}
	if _, err := runner.Run(context.Background(), ProbeAudioSession, maximumProbeOutput+1); err == nil {
		t.Fatal("oversized output limit unexpectedly ran")
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := runner.Run(cancelled, ProbeAudioSession, maximumProbeOutput); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled Run() error = %v", err)
	}
}

// TestNormaliseProbeTimeoutEnforcesMaximum verifies callers cannot request unbounded waits.
func TestNormaliseProbeTimeoutEnforcesMaximum(t *testing.T) {
	if got, err := normaliseProbeTimeout(0); err != nil || got != defaultProbeTimeout {
		t.Fatalf("normaliseProbeTimeout(0) = %s, %v", got, err)
	}
	if _, err := normaliseProbeTimeout(maximumProbeTimeout + 1); err == nil {
		t.Fatal("timeout above maximum was accepted")
	}
	if _, err := normaliseProbeTimeout(-1); err == nil {
		t.Fatal("negative timeout was accepted")
	}
}
